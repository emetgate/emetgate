const std = @import("std");
const builtin = @import("builtin");
const symbol = @import("../engine/symbol.zig");
const shadow = @import("shadow.zig");

const Allocator = std.mem.Allocator;
const windows = std.os.windows;
const WidePath = [std.fs.max_path_bytes:0]u16;

pub fn hashFile(gpa: Allocator, io: std.Io, path: []const u8) !symbol.Hash {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(bytes);
    return symbol.hashOf(bytes);
}

pub fn verifyBase(gpa: Allocator, io: std.Io, path: []const u8, expected: symbol.Hash) !void {
    const current = hashFile(gpa, io, path) catch |err| switch (err) {
        error.FileNotFound => return error.BaseChanged,
        else => |e| return e,
    };
    if (!std.mem.eql(u8, &current, &expected)) return error.BaseChanged;
}

pub const Guard = struct {
    handle: windows.HANDLE,

    pub fn open(path_abs: []const u8) !Guard {
        var wide: WidePath = undefined;
        const handle = win.CreateFileW(
            try toWide(&wide, path_abs),
            win.generic_read | win.delete,
            win.file_share_read,
            null,
            win.open_existing,
            win.file_attribute_normal,
            null,
        );
        if (handle == windows.INVALID_HANDLE_VALUE) return switch (win.GetLastError()) {
            win.error_file_not_found, win.error_path_not_found => error.BaseChanged,
            win.error_sharing_violation, win.error_lock_violation => error.FileLocked,
            win.error_access_denied => error.AccessDenied,
            else => error.OpenFailed,
        };
        return .{ .handle = handle };
    }

    pub fn hash(self: Guard, gpa: Allocator, io: std.Io) !symbol.Hash {
        const file: std.Io.File = .{ .handle = self.handle, .flags = .{ .nonblocking = false } };
        const len = std.math.cast(usize, try file.length(io)) orelse return error.FileTooBig;
        const bytes = try gpa.alloc(u8, len);
        defer gpa.free(bytes);
        if (try file.readPositionalAll(io, bytes, 0) != len) return error.BaseChanged;
        return symbol.hashOf(bytes);
    }

    fn attributes(self: Guard) !windows.DWORD {
        var info: win.BY_HANDLE_FILE_INFORMATION = undefined;
        if (win.GetFileInformationByHandle(self.handle, &info) == .FALSE) return error.OpenFailed;
        return info.file_attributes;
    }

    fn renameTo(self: Guard, gpa: Allocator, path_abs: []const u8) !void {
        return renameByHandle(gpa, self.handle, path_abs, false);
    }

    fn renameReplacing(self: Guard, gpa: Allocator, path_abs: []const u8) !void {
        return renameByHandle(gpa, self.handle, path_abs, true);
    }

    pub fn close(self: Guard) void {
        windows.CloseHandle(self.handle);
    }
};

const Hook = struct {
    context: *anyopaque,
    run: *const fn (context: *anyopaque) anyerror!void,
};

pub const Paths = struct {
    temp: []const u8,
    backup: []const u8,
};

pub const Leftover = struct {
    buf: [std.fs.max_path_bytes]u8 = undefined,
    len: usize = 0,

    pub fn path(self: *const Leftover) ?[]const u8 {
        return if (self.len == 0) null else self.buf[0..self.len];
    }

    fn record(self: *Leftover, value: []const u8) void {
        const n = @min(value.len, self.buf.len);
        @memcpy(self.buf[0..n], value[0..n]);
        self.len = n;
    }
};

const sidecar_suffix_max = ".synapse-0123456789abcdef.tmp".len;

pub fn replaceAtomically(gpa: Allocator, io: std.Io, path_abs: []const u8, data: []const u8, expected_base: symbol.Hash) !void {
    return replaceInternal(gpa, io, path_abs, data, expected_base, null, null, null);
}

pub fn replaceReporting(gpa: Allocator, io: std.Io, path_abs: []const u8, data: []const u8, expected_base: symbol.Hash, leftover: ?*Leftover, journal_dir: ?[]const u8) !void {
    return replaceInternal(gpa, io, path_abs, data, expected_base, leftover, null, journal_dir);
}

pub const Pending = struct {
    gpa: Allocator,
    io: std.Io,
    guard: Guard,
    replacement: Guard,
    path: []u8,
    temp: []u8,
    backup: []u8,
    journal: ?[]u8,
    saved_attributes: windows.DWORD,
    data_hash: symbol.Hash,
    state: State = .staged,

    const State = enum { staged, backed_up, swapped };

    pub fn swap(self: *Pending, in_gap: ?Hook) !void {
        try self.guard.renameTo(self.gpa, self.backup);
        self.state = .backed_up;
        if (in_gap) |hook| try hook.run(hook.context);
        self.replacement.renameTo(self.gpa, self.path) catch |err| switch (err) {
            error.PathAlreadyExists => return error.Conflict,
            else => |e| return e,
        };
        applyAttributes(self.path, self.saved_attributes) catch {};
        self.state = .swapped;
    }

    pub fn verify(self: *Pending) !void {
        const written = self.replacement.hash(self.gpa, self.io) catch return error.WrittenButUnverified;
        if (!std.mem.eql(u8, &written, &self.data_hash)) return error.WrittenButUnverified;
    }

    pub fn finalize(self: *Pending, leftover: ?*Leftover) void {
        self.replacement.close();
        self.guard.close();
        if (!deleteWithRetry(self.io, self.backup)) {
            if (leftover) |out| out.record(self.backup);
        }
        self.freePaths();
    }

    pub fn discard(self: *Pending, leftover: ?*Leftover) void {
        self.replacement.close();
        switch (self.state) {
            .staged => _ = deleteWithRetry(self.io, self.temp),
            .backed_up => {
                self.guard.renameTo(self.gpa, self.path) catch {
                    if (leftover) |out| out.record(self.backup);
                };
                _ = deleteWithRetry(self.io, self.temp);
            },
            .swapped => self.guard.renameReplacing(self.gpa, self.path) catch {
                if (leftover) |out| out.record(self.backup);
            },
        }
        self.guard.close();
        self.freePaths();
    }

    fn freePaths(self: *Pending) void {
        if (self.journal) |j| {
            _ = deleteWithRetry(self.io, j);
            self.gpa.free(j);
        }
        self.gpa.free(self.path);
        self.gpa.free(self.temp);
        self.gpa.free(self.backup);
    }
};

pub fn prepare(gpa: Allocator, io: std.Io, path_abs: []const u8, data: []const u8, expected_base: symbol.Hash, journal_dir: ?[]const u8) !Pending {
    if (builtin.os.tag != .windows) return error.Unsupported;
    if (path_abs.len + sidecar_suffix_max > std.fs.max_path_bytes) return error.NameTooLong;

    const guard = try Guard.open(path_abs);
    errdefer guard.close();
    if (!std.mem.eql(u8, &(try guard.hash(gpa, io)), &expected_base)) return error.BaseChanged;
    const saved_attributes = try guard.attributes();
    if (saved_attributes & win.file_attribute_readonly != 0) return error.ReadOnlyFile;

    var random: [8]u8 = undefined;
    io.random(&random);
    const tag = std.fmt.bytesToHex(random, .lower);
    const path = try gpa.dupe(u8, path_abs);
    errdefer gpa.free(path);
    const temp = try std.fmt.allocPrint(gpa, "{s}.synapse-{s}.tmp", .{ path_abs, &tag });
    errdefer gpa.free(temp);
    const backup = try std.fmt.allocPrint(gpa, "{s}.synapse-{s}.bak", .{ path_abs, &tag });
    errdefer gpa.free(backup);

    const journal = if (journal_dir) |dir| try writeJournal(gpa, io, dir, &tag, path_abs, expected_base) else null;
    errdefer if (journal) |j| {
        _ = deleteWithRetry(io, j);
        gpa.free(j);
    };

    try writeDurably(io, temp, data);
    errdefer _ = deleteWithRetry(io, temp);
    const replacement = try Guard.open(temp);

    return .{
        .gpa = gpa,
        .io = io,
        .guard = guard,
        .replacement = replacement,
        .path = path,
        .temp = temp,
        .backup = backup,
        .journal = journal,
        .saved_attributes = saved_attributes,
        .data_hash = symbol.hashOf(data),
    };
}

fn writeJournal(gpa: Allocator, io: std.Io, journal_dir: []const u8, tag: []const u8, target_abs: []const u8, base_hash: symbol.Hash) ![]u8 {
    std.Io.Dir.cwd().createDirPath(io, journal_dir) catch {};
    const journal_path = try std.fmt.allocPrint(gpa, "{s}\\{s}.json", .{ journal_dir, tag });
    errdefer gpa.free(journal_path);

    const hex = symbol.formatHash(base_hash);
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    var js: std.json.Stringify = .{ .writer = &buffer.writer };
    try js.beginObject();
    try js.objectField("target");
    try js.write(target_abs);
    try js.objectField("base_hash");
    try js.write(hex[0..]);
    try js.endObject();

    try writeDurably(io, journal_path, buffer.written());
    return journal_path;
}

fn abortSwaps(pendings: []Pending, swapped: usize, leftover: ?*Leftover) void {
    var k = swapped;
    while (k > 0) {
        k -= 1;
        pendings[k].discard(leftover);
    }
    for (pendings[swapped..]) |*rest| rest.discard(leftover);
}

pub fn commitBatch(pendings: []Pending, leftover: ?*Leftover, fail_before: ?usize) !void {
    var swapped: usize = 0;
    while (swapped < pendings.len) : (swapped += 1) {
        if (fail_before) |k| if (k == swapped) {
            abortSwaps(pendings, swapped, leftover);
            return error.BatchAborted;
        };
        pendings[swapped].swap(null) catch |err| {
            abortSwaps(pendings, swapped, leftover);
            return err;
        };
    }
    for (pendings) |*p| {
        p.verify() catch {
            for (pendings) |*q| q.discard(leftover);
            return error.WrittenButUnverified;
        };
    }
    for (pendings) |*p| p.finalize(leftover);
}

pub const RecoverReport = struct {
    restored: usize = 0,
    removed_temps: usize = 0,
    skipped: usize = 0,
    failed: usize = 0,
};

const JournalEntry = struct {
    target: []const u8 = "",
    base_hash: []const u8 = "",
};

const max_journal_bytes = 64 * 1024;
const SidecarKind = enum { tmp, bak };

fn sidecarKind(name: []const u8) ?SidecarKind {
    if (name.len < sidecar_suffix_max) return null;
    const suffix = name[name.len - sidecar_suffix_max ..];
    if (!std.mem.startsWith(u8, suffix, ".synapse-")) return null;
    for (suffix[9..25]) |c| if (!std.ascii.isHex(c)) return null;
    if (suffix[25] != '.') return null;
    const ext = suffix[26..29];
    if (std.mem.eql(u8, ext, "tmp")) return .tmp;
    if (std.mem.eql(u8, ext, "bak")) return .bak;
    return null;
}

fn skipDir(name: []const u8) bool {
    return std.mem.eql(u8, name, ".git") or std.mem.eql(u8, name, "node_modules") or std.mem.eql(u8, name, ".synapse");
}

fn isValidTag(tag: []const u8) bool {
    if (tag.len != 16) return false;
    for (tag) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

fn isUnderRoot(root_abs: []const u8, target_abs: []const u8) bool {
    if (target_abs.len <= root_abs.len) return false;
    if (!std.ascii.startsWithIgnoreCase(target_abs, root_abs)) return false;
    const sep = target_abs[root_abs.len];
    if (sep != '\\' and sep != '/') return false;
    var it = std.mem.tokenizeAny(u8, target_abs, "/\\");
    while (it.next()) |segment| {
        if (std.mem.eql(u8, segment, "..") or std.mem.eql(u8, segment, ".")) return false;
    }
    return true;
}

fn escapesViaReparse(root_abs: []const u8, target_abs: []const u8) !bool {
    var current = std.fs.path.dirname(target_abs) orelse return true;
    while (current.len > root_abs.len) {
        if (try shadow.isReparsePoint(current)) return true;
        current = std.fs.path.dirname(current) orelse break;
    }
    return false;
}

fn clearReadonly(path_abs: []const u8) void {
    var wide: WidePath = undefined;
    const w = toWide(&wide, path_abs) catch return;
    _ = win.SetFileAttributesW(w, win.file_attribute_normal);
}

fn restoreVerified(gpa: Allocator, io: std.Io, bak_abs: []const u8, target_abs: []const u8, base_hash: symbol.Hash) !void {
    if (shadow.isReparsePoint(bak_abs) catch true) return error.BackupUnverified;
    const guard = try Guard.open(bak_abs);
    defer guard.close();
    if (!std.mem.eql(u8, &(try guard.hash(gpa, io)), &base_hash)) return error.BackupUnverified;
    clearReadonly(target_abs);
    try guard.renameReplacing(gpa, target_abs);
}

pub fn recover(gpa: Allocator, io: std.Io, root_abs: []const u8) !RecoverReport {
    if (builtin.os.tag != .windows) return error.Unsupported;
    var report: RecoverReport = .{};
    try recoverJournaled(gpa, io, root_abs, &report);
    try clearOrphanTemps(gpa, io, root_abs, &report);
    return report;
}

fn recoverJournaled(gpa: Allocator, io: std.Io, root_abs: []const u8, report: *RecoverReport) !void {
    var journal_buf: [std.fs.max_path_bytes]u8 = undefined;
    const journal_dir = std.fmt.bufPrint(&journal_buf, "{s}\\{s}\\journal", .{ root_abs, shadow.workspace_dir }) catch return;

    var dir = std.Io.Dir.openDirAbsolute(io, journal_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }

    for (names.items) |name| {
        var jp_buf: [std.fs.max_path_bytes]u8 = undefined;
        const jp = std.fmt.bufPrint(&jp_buf, "{s}\\{s}", .{ journal_dir, name }) catch continue;
        applyJournalEntry(gpa, io, root_abs, jp, name, report) catch {
            report.failed += 1;
        };
        _ = deleteWithRetry(io, jp);
    }
    std.Io.Dir.cwd().deleteDir(io, journal_dir) catch {};
}

fn applyJournalEntry(gpa: Allocator, io: std.Io, root_abs: []const u8, journal_path: []const u8, name: []const u8, report: *RecoverReport) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, journal_path, gpa, .limited(max_journal_bytes));
    defer gpa.free(bytes);

    const parsed = std.json.parseFromSlice(JournalEntry, gpa, bytes, .{ .ignore_unknown_fields = true }) catch {
        report.failed += 1;
        return;
    };
    defer parsed.deinit();
    const target = parsed.value.target;
    if (target.len == 0) {
        report.failed += 1;
        return;
    }
    const base_hash = symbol.parseHash(parsed.value.base_hash) catch {
        report.failed += 1;
        return;
    };
    if (!isUnderRoot(root_abs, target) or try escapesViaReparse(root_abs, target)) {
        report.failed += 1;
        return;
    }

    const tag = name[0 .. name.len - ".json".len];
    if (!isValidTag(tag)) {
        report.failed += 1;
        return;
    }
    const bak = try std.fmt.allocPrint(gpa, "{s}.synapse-{s}.bak", .{ target, tag });
    defer gpa.free(bak);

    restoreVerified(gpa, io, bak, target, base_hash) catch |err| switch (err) {
        error.BaseChanged, error.FileLocked => {
            report.skipped += 1;
            return;
        },
        else => {
            report.failed += 1;
            return;
        },
    };
    report.restored += 1;
}

fn clearOrphanTemps(gpa: Allocator, io: std.Io, root_abs: []const u8, report: *RecoverReport) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, root_abs, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var walker = try dir.walkSelectively(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        const abs = std.fmt.allocPrint(gpa, "{s}\\{s}", .{ root_abs, entry.path }) catch continue;
        defer gpa.free(abs);
        std.mem.replaceScalar(u8, abs, '/', '\\');
        if (entry.kind == .directory) {
            if (skipDir(entry.basename)) continue;
            const reparse = shadow.isReparsePoint(abs) catch true;
            if (!reparse) try walker.enter(io, entry);
            continue;
        }
        if (entry.kind != .file) continue;
        if (sidecarKind(entry.basename) != .tmp) continue;
        if (deleteWithRetry(io, abs)) report.removed_temps += 1;
    }
}

fn replaceInternal(gpa: Allocator, io: std.Io, path_abs: []const u8, data: []const u8, expected_base: symbol.Hash, leftover: ?*Leftover, in_gap: ?Hook, journal_dir: ?[]const u8) !void {
    var pending = try prepare(gpa, io, path_abs, data, expected_base, journal_dir);
    var done = false;
    defer if (!done) pending.discard(leftover);
    try pending.swap(in_gap);
    try pending.verify();
    pending.finalize(leftover);
    done = true;
}

fn renameByHandle(gpa: Allocator, handle: windows.HANDLE, target_abs: []const u8, replace_existing: bool) !void {
    var wide: WidePath = undefined;
    const name = try toWide(&wide, target_abs);
    const name_bytes = std.mem.sliceTo(name, 0).len * 2;

    const header = @offsetOf(win.FILE_RENAME_INFO, "file_name");
    const buffer = try gpa.alignedAlloc(u8, .of(win.FILE_RENAME_INFO), header + name_bytes + 2);
    defer gpa.free(buffer);
    @memset(buffer, 0);
    const info: *win.FILE_RENAME_INFO = @ptrCast(buffer.ptr);
    info.flags = win.file_rename_flag_posix_semantics | (if (replace_existing) win.file_rename_flag_replace_if_exists else 0);
    info.root_directory = null;
    info.file_name_length = @intCast(name_bytes);
    @memcpy(buffer[header..][0..name_bytes], std.mem.sliceAsBytes(std.mem.sliceTo(name, 0)));

    if (win.SetFileInformationByHandle(handle, win.file_rename_info_ex, buffer.ptr, @intCast(buffer.len)) != .FALSE) return;
    return switch (win.GetLastError()) {
        win.error_already_exists, win.error_file_exists => error.PathAlreadyExists,
        win.error_sharing_violation, win.error_lock_violation => error.FileLocked,
        win.error_access_denied => error.AccessDenied,
        else => error.RenameFailed,
    };
}

fn writeDurably(io: std.Io, path: []const u8, data: []const u8) !void {
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true });
    errdefer std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    defer file.close(io);
    try file.writeStreamingAll(io, data);
    try file.sync(io);
}

fn applyAttributes(path_abs: []const u8, attributes: windows.DWORD) !void {
    if (attributes == 0 or attributes == win.file_attribute_normal) return;
    var wide: WidePath = undefined;
    if (win.SetFileAttributesW(try toWide(&wide, path_abs), attributes & ~win.file_attribute_readonly) == .FALSE) return error.SetAttributesFailed;
}

const delete_retries = 5;
const delete_retry_ms: windows.DWORD = 40;

fn deleteWithRetry(io: std.Io, path: []const u8) bool {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        std.Io.Dir.deleteFileAbsolute(io, path) catch |err| switch (err) {
            error.FileNotFound => return true,
            else => {
                if (attempt + 1 >= delete_retries) return false;
                win.Sleep(delete_retry_ms);
                continue;
            },
        };
        return true;
    }
}

fn toWide(buffer: *WidePath, path: []const u8) ![*:0]const u16 {
    const len = std.unicode.wtf8ToWtf16Le(buffer, path) catch return error.InvalidWtf8;
    if (len >= buffer.len) return error.NameTooLong;
    buffer[len] = 0;
    return buffer;
}

const win = struct {
    const generic_read: windows.DWORD = 0x80000000;
    const generic_write: windows.DWORD = 0x40000000;
    const delete: windows.DWORD = 0x00010000;
    const file_share_read: windows.DWORD = 0x00000001;
    const file_share_write: windows.DWORD = 0x00000002;
    const file_share_delete: windows.DWORD = 0x00000004;
    const open_existing: windows.DWORD = 3;
    const file_attribute_readonly: windows.DWORD = 0x00000001;
    const file_attribute_hidden: windows.DWORD = 0x00000002;
    const file_attribute_normal: windows.DWORD = 0x00000080;
    const invalid_file_attributes: windows.DWORD = 0xFFFFFFFF;

    const file_rename_info_ex: c_int = 22;
    const file_rename_flag_replace_if_exists: windows.DWORD = 0x00000001;
    const file_rename_flag_posix_semantics: windows.DWORD = 0x00000002;

    const error_file_not_found: windows.DWORD = 2;
    const error_path_not_found: windows.DWORD = 3;
    const error_access_denied: windows.DWORD = 5;
    const error_file_exists: windows.DWORD = 80;
    const error_sharing_violation: windows.DWORD = 32;
    const error_lock_violation: windows.DWORD = 33;
    const error_already_exists: windows.DWORD = 183;

    const FILE_RENAME_INFO = extern struct {
        flags: windows.DWORD,
        root_directory: ?windows.HANDLE,
        file_name_length: windows.DWORD,
        file_name: [1]u16,
    };

    const BY_HANDLE_FILE_INFORMATION = extern struct {
        file_attributes: windows.DWORD,
        creation_time: windows.FILETIME,
        last_access_time: windows.FILETIME,
        last_write_time: windows.FILETIME,
        volume_serial_number: windows.DWORD,
        file_size_high: windows.DWORD,
        file_size_low: windows.DWORD,
        number_of_links: windows.DWORD,
        file_index_high: windows.DWORD,
        file_index_low: windows.DWORD,
    };

    extern "kernel32" fn CreateFileW(
        name: [*:0]const u16,
        access: windows.DWORD,
        share: windows.DWORD,
        security: ?*anyopaque,
        disposition: windows.DWORD,
        flags: windows.DWORD,
        template: ?windows.HANDLE,
    ) callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn SetFileInformationByHandle(handle: windows.HANDLE, class: c_int, info: *anyopaque, length: windows.DWORD) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetFileInformationByHandle(handle: windows.HANDLE, info: *BY_HANDLE_FILE_INFORMATION) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetFileAttributesW(name: [*:0]const u16) callconv(.winapi) windows.DWORD;
    extern "kernel32" fn SetFileAttributesW(name: [*:0]const u16, attributes: windows.DWORD) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetLastError() callconv(.winapi) windows.DWORD;
    extern "kernel32" fn Sleep(milliseconds: windows.DWORD) callconv(.winapi) void;
};

const testing = std.testing;

const original = "export function f() { return 1; }\n";
const updated = "export function f() { return 2; }\n";

const Fixture = struct {
    tmp: testing.TmpDir,
    path_buf: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize = 0,

    fn init(content: []const u8) !Fixture {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "target.ts", .data = content });
        var fixture: Fixture = .{ .tmp = tmp };
        const dir_abs = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        defer testing.allocator.free(dir_abs);
        fixture.path_len = (try std.fmt.bufPrint(&fixture.path_buf, "{s}\\target.ts", .{dir_abs})).len;
        return fixture;
    }

    fn path(self: *const Fixture) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    fn deinit(self: *Fixture) void {
        self.setAttributes(win.file_attribute_normal) catch {};
        self.tmp.cleanup();
    }

    fn setAttributes(self: *const Fixture, value: windows.DWORD) !void {
        var wide: WidePath = undefined;
        if (win.SetFileAttributesW(try toWide(&wide, self.path()), value) == .FALSE) return error.SetAttributesFailed;
    }

    fn attributes(self: *const Fixture) !windows.DWORD {
        var wide: WidePath = undefined;
        return win.GetFileAttributesW(try toWide(&wide, self.path()));
    }

    fn expectContent(self: *const Fixture, expected: []const u8) !void {
        const actual = try self.tmp.dir.readFileAlloc(testing.io, "target.ts", testing.allocator, .unlimited);
        defer testing.allocator.free(actual);
        try testing.expectEqualStrings(expected, actual);
    }

    fn expectEntries(self: *const Fixture, expected: usize) !void {
        var iterator = self.tmp.dir.iterate();
        var count: usize = 0;
        while (try iterator.next(testing.io)) |entry| {
            errdefer std.debug.print("unexpected entry: {s}\n", .{entry.name});
            if (!std.mem.eql(u8, entry.name, "target.ts")) return error.LeftoverFile;
            count += 1;
        }
        try testing.expectEqual(expected, count);
    }

    fn openRaw(self: *const Fixture, access: windows.DWORD, share: windows.DWORD) !windows.HANDLE {
        var wide: WidePath = undefined;
        const handle = win.CreateFileW(try toWide(&wide, self.path()), access, share, null, win.open_existing, win.file_attribute_normal, null);
        if (handle == windows.INVALID_HANDLE_VALUE) return error.OpenFailed;
        return handle;
    }

    fn createSibling(self: *const Fixture, name: []const u8, content: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = content });
    }
};

fn replace(fixture: *const Fixture, data: []const u8, base: symbol.Hash) !void {
    return replaceAtomically(testing.allocator, testing.io, fixture.path(), data, base);
}

test "an unchanged base is replaced atomically, keeps its attributes and leaves no temp or backup" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fixture = try Fixture.init(original);
    defer fixture.deinit();
    try fixture.setAttributes(win.file_attribute_hidden);

    try replace(&fixture, updated, symbol.hashOf(original));

    try fixture.expectContent(updated);
    try testing.expect(try fixture.attributes() & win.file_attribute_hidden != 0);
    try fixture.expectEntries(1);
}

test "an external edit since the session began is refused with BaseChanged" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fixture = try Fixture.init(original);
    defer fixture.deinit();
    const base = symbol.hashOf(original);

    const external = "export function f() { return 42; }\n";
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "target.ts", .data = external });

    try testing.expectError(error.BaseChanged, verifyBase(testing.allocator, testing.io, fixture.path(), base));
    try testing.expectError(error.BaseChanged, replace(&fixture, updated, base));
    try fixture.expectContent(external);
    try fixture.expectEntries(1);
}

test "a file deleted since the session began is refused with BaseChanged" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fixture = try Fixture.init(original);
    defer fixture.deinit();
    try fixture.tmp.dir.deleteFile(testing.io, "target.ts");

    try testing.expectError(error.BaseChanged, verifyBase(testing.allocator, testing.io, fixture.path(), symbol.hashOf(original)));
    try testing.expectError(error.BaseChanged, replace(&fixture, updated, symbol.hashOf(original)));
    try fixture.expectEntries(0);
}

test "a read-only file is refused and keeps both its content and its read-only flag" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fixture = try Fixture.init(original);
    defer fixture.deinit();
    try fixture.setAttributes(win.file_attribute_readonly);

    try testing.expectError(error.ReadOnlyFile, replace(&fixture, updated, symbol.hashOf(original)));
    try fixture.expectContent(original);
    try testing.expect(try fixture.attributes() & win.file_attribute_readonly != 0);
    try fixture.expectEntries(1);
}

test "a file held open for writing by another process is refused with FileLocked" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fixture = try Fixture.init(original);
    defer fixture.deinit();
    const base = symbol.hashOf(original);

    const writer = try fixture.openRaw(win.generic_write, win.file_share_read | win.file_share_write);
    try testing.expectError(error.FileLocked, replace(&fixture, updated, base));
    windows.CloseHandle(writer);
    try fixture.expectContent(original);
    try fixture.expectEntries(1);

    try replace(&fixture, updated, base);
    try fixture.expectContent(updated);
    try fixture.expectEntries(1);
}

test "while the guard is held no other handle can open the file for writing" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fixture = try Fixture.init(original);
    defer fixture.deinit();

    const guard = try Guard.open(fixture.path());
    try testing.expectEqual(symbol.hashOf(original), try guard.hash(testing.allocator, testing.io));
    try testing.expectError(error.OpenFailed, fixture.openRaw(win.generic_write, win.file_share_read | win.file_share_write | win.file_share_delete));
    try testing.expectError(error.OpenFailed, fixture.openRaw(win.delete, win.file_share_read | win.file_share_write | win.file_share_delete));
    guard.close();

    const writer = try fixture.openRaw(win.generic_write, win.file_share_read | win.file_share_write | win.file_share_delete);
    windows.CloseHandle(writer);
}

const external_save = "export function f() { return 42; } // saved by another tool\n";

const RecreateTarget = struct {
    fixture: *Fixture,

    fn run(context: *anyopaque) anyerror!void {
        const self: *RecreateTarget = @ptrCast(@alignCast(context));
        try self.fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "target.ts", .data = external_save });
    }
};

test "a concurrent save that lands in the rename gap is preserved as a Conflict, not overwritten" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fixture = try Fixture.init(original);
    defer fixture.deinit();

    var recreate: RecreateTarget = .{ .fixture = &fixture };
    const hook: Hook = .{ .context = &recreate, .run = RecreateTarget.run };
    var leftover: Leftover = .{};
    try testing.expectError(error.Conflict, replaceInternal(testing.allocator, testing.io, fixture.path(), updated, symbol.hashOf(original), &leftover, hook, null));

    try fixture.expectContent(external_save);

    const backup_path = leftover.path() orelse return error.NoLeftoverReported;
    const preserved = try std.Io.Dir.cwd().readFileAlloc(testing.io, backup_path, testing.allocator, .unlimited);
    defer testing.allocator.free(preserved);
    try testing.expectEqualStrings(original, preserved);
    std.Io.Dir.deleteFileAbsolute(testing.io, backup_path) catch {};
}

test "commitBatch writes every file when all swaps succeed and leaves no sidecars" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var a = try Fixture.init(original);
    defer a.deinit();
    var b = try Fixture.init(original);
    defer b.deinit();

    var pendings = [_]Pending{
        try prepare(testing.allocator, testing.io, a.path(), updated, symbol.hashOf(original), null),
        try prepare(testing.allocator, testing.io, b.path(), updated, symbol.hashOf(original), null),
    };
    try commitBatch(&pendings, null, null);

    try a.expectContent(updated);
    try b.expectContent(updated);
    try a.expectEntries(1);
    try b.expectEntries(1);
}

test "commitBatch rolls every committed file back when one swap fails midway" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var a = try Fixture.init(original);
    defer a.deinit();
    var b = try Fixture.init(original);
    defer b.deinit();

    var pendings = [_]Pending{
        try prepare(testing.allocator, testing.io, a.path(), updated, symbol.hashOf(original), null),
        try prepare(testing.allocator, testing.io, b.path(), updated, symbol.hashOf(original), null),
    };
    try testing.expectError(error.BatchAborted, commitBatch(&pendings, null, 1));

    try a.expectContent(original);
    try b.expectContent(original);
    try a.expectEntries(1);
    try b.expectEntries(1);
}

const recover_tag = "0123456789abcdef";

fn seedRecover(root_abs: []const u8, tmp: *testing.TmpDir, target_content: []const u8, bak_content: []const u8) !void {
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f.ts", .data = target_content });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f.ts.synapse-" ++ recover_tag ++ ".bak", .data = bak_content });
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target_abs = try std.fmt.bufPrint(&target_buf, "{s}\\f.ts", .{root_abs});
    var jdir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const jdir = try std.fmt.bufPrint(&jdir_buf, "{s}\\.synapse\\journal", .{root_abs});
    const jp = try writeJournal(testing.allocator, testing.io, jdir, recover_tag, target_abs, symbol.hashOf(original));
    testing.allocator.free(jp);
}

test "recover clears a read-only target and restores it, never fails open (ORTA-1)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try seedRecover(root, &tmp, updated, original);

    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target_abs = try std.fmt.bufPrint(&target_buf, "{s}\\f.ts", .{root});
    var wide: WidePath = undefined;
    const wide_target = try toWide(&wide, target_abs);
    _ = win.SetFileAttributesW(wide_target, win.file_attribute_readonly);
    defer _ = win.SetFileAttributesW(wide_target, win.file_attribute_normal);

    const report = try recover(testing.allocator, testing.io, root);
    try testing.expectEqual(@as(usize, 1), report.restored);
    try testing.expectEqual(@as(usize, 0), report.failed);
    const f = try tmp.dir.readFileAlloc(testing.io, "f.ts", testing.allocator, .unlimited);
    defer testing.allocator.free(f);
    try testing.expectEqualStrings(original, f);
}

test "recover never deletes temps through a junction (F, defense in depth)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var outside = testing.tmpDir(.{ .iterate = true });
    defer outside.cleanup();
    try outside.dir.writeFile(testing.io, .{ .sub_path = "x.synapse-" ++ recover_tag ++ ".tmp", .data = "outside temp\n" });
    const outside_abs = try outside.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(outside_abs);

    var repo = testing.tmpDir(.{ .iterate = true });
    defer repo.cleanup();
    const root = try repo.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const link_abs = try std.fmt.bufPrint(&link_buf, "{s}\\link", .{root});
    try shadow.createJunction(testing.io, link_abs, outside_abs);

    _ = try recover(testing.allocator, testing.io, root);
    try outside.dir.access(testing.io, "x.synapse-" ++ recover_tag ++ ".tmp", .{});
}

test "recover refuses a journal target that escapes the repo via .. (A hardening)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "repo");
    const root = try tmp.dir.realPathFileAlloc(testing.io, "repo", testing.allocator);
    defer testing.allocator.free(root);

    const mal = "export const PWNED = 1;\n";
    // the .bak lives in the repo's PARENT, named for the escaping target
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "pwned.ts.synapse-" ++ recover_tag ++ ".bak", .data = mal });
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buf, "{s}\\..\\pwned.ts", .{root});
    var jdir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const jdir = try std.fmt.bufPrint(&jdir_buf, "{s}\\.synapse\\journal", .{root});
    const jp = try writeJournal(testing.allocator, testing.io, jdir, recover_tag, target, symbol.hashOf(mal));
    testing.allocator.free(jp);

    const report = try recover(testing.allocator, testing.io, root);
    try testing.expectEqual(@as(usize, 0), report.restored);
    try testing.expect(report.failed >= 1);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "pwned.ts", .{}));
}
