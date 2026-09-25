const std = @import("std");
const builtin = @import("builtin");
const symbol = @import("../engine/symbol.zig");
const shadow = @import("shadow.zig");
const commit_record = @import("commit_record.zig");
const journal = @import("journal.zig");
const git_repo = @import("repo.zig");
const shadow_root = @import("shadow_root.zig");

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
            win.file_share_read | win.file_share_delete,
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
        const bytes = try self.readAll(gpa, io);
        defer gpa.free(bytes);
        return symbol.hashOf(bytes);
    }

    fn readAll(self: Guard, gpa: Allocator, io: std.Io) ![]u8 {
        const file: std.Io.File = .{ .handle = self.handle, .flags = .{ .nonblocking = false } };
        const len = std.math.cast(usize, try file.length(io)) orelse return error.FileTooBig;
        const bytes = try gpa.alloc(u8, len);
        errdefer gpa.free(bytes);
        if (try file.readPositionalAll(io, bytes, 0) != len) return error.BaseChanged;
        return bytes;
    }

    fn deleteSelf(self: Guard) !void {
        var info: win.FILE_DISPOSITION_INFO_EX = .{ .flags = win.file_disposition_flag_delete | win.file_disposition_flag_posix_semantics };
        if (win.SetFileInformationByHandle(self.handle, win.file_disposition_info_ex, &info, @sizeOf(win.FILE_DISPOSITION_INFO_EX)) != .FALSE) return;
        return switch (win.GetLastError()) {
            win.error_sharing_violation, win.error_lock_violation => error.FileLocked,
            win.error_access_denied => error.AccessDenied,
            else => error.DeleteFailed,
        };
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

pub const Step = struct {
    context: *anyopaque,
    reached: *const fn (context: *anyopaque) bool,

    fn stops(step: ?*const Step) bool {
        const s = step orelse return false;
        return s.reached(s.context);
    }

    fn gap(step: ?*const Step) ?Hook {
        const s = step orelse return null;
        return .{ .context = @constCast(s), .run = runGap };
    }

    fn runGap(context: *anyopaque) anyerror!void {
        const s: *const Step = @ptrCast(@alignCast(context));
        if (s.reached(s.context)) return error.Crashed;
    }
};

pub const Batch = struct {
    gpa: Allocator,
    io: std.Io,
    journal_dir: []const u8,
    tag: commit_record.Tag,
    root: ?[]const u8 = null,

    pub fn init(gpa: Allocator, io: std.Io, journal_dir: []const u8) Batch {
        return .{ .gpa = gpa, .io = io, .journal_dir = journal_dir, .tag = commit_record.newTag(io) };
    }
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

const sidecar_suffix_max = ".emetgate-0123456789abcdef.tmp".len;

pub fn replaceAtomically(gpa: Allocator, io: std.Io, path_abs: []const u8, data: []const u8, expected_base: symbol.Hash) !void {
    return replaceInternal(gpa, io, path_abs, data, expected_base, null, null, null);
}

pub fn replaceReporting(gpa: Allocator, io: std.Io, path_abs: []const u8, data: []const u8, expected_base: symbol.Hash, leftover: ?*Leftover, journal_dir: ?[]const u8) !void {
    return replaceInternal(gpa, io, path_abs, data, expected_base, leftover, null, journal_dir);
}

pub fn create(gpa: Allocator, io: std.Io, path_abs: []const u8, data: []const u8) !void {
    if (builtin.os.tag != .windows) return error.Unsupported;
    if (path_abs.len + sidecar_suffix_max > std.fs.max_path_bytes) return error.NameTooLong;
    var random: [8]u8 = undefined;
    io.random(&random);
    const tag = std.fmt.bytesToHex(random, .lower);
    const temp = try std.fmt.allocPrint(gpa, "{s}.emetgate-{s}.tmp", .{ path_abs, &tag });
    defer gpa.free(temp);

    try writeDurably(io, temp, data);
    var placed = false;
    defer if (!placed) {
        _ = deleteWithRetry(io, temp);
    };
    const replacement = try Guard.open(temp);
    defer replacement.close();
    replacement.renameTo(gpa, path_abs) catch |err| switch (err) {
        error.PathAlreadyExists => return error.FileExists,
        else => |e| return e,
    };
    placed = true;
    const written = replacement.hash(gpa, io) catch return error.WrittenButUnverified;
    if (!std.mem.eql(u8, &written, &symbol.hashOf(data))) return error.WrittenButUnverified;
}

pub const Pending = struct {
    gpa: Allocator,
    io: std.Io,
    kind: Kind,
    guard: ?Guard,
    replacement: ?Guard = null,
    path: []u8,
    temp: []u8,
    backup: []u8,
    tag: [16]u8,
    data: []const u8,
    base_hash: ?symbol.Hash,
    saved_attributes: windows.DWORD,
    data_hash: symbol.Hash,
    state: State = .planned,
    freed: bool = false,

    pub const Kind = enum { modify, create, delete };
    const State = enum { planned, staged, backed_up, swapped };

    fn intent(self: *const Pending) journal.Intent {
        return switch (self.kind) {
            .modify => .{ .op = .modify, .target = self.path, .tag = &self.tag, .base_hash = self.base_hash, .new_hash = self.data_hash },
            .create => .{ .op = .create, .target = self.path, .tag = &self.tag, .new_hash = self.data_hash },
            .delete => .{ .op = .delete, .target = self.path, .base_hash = self.base_hash },
        };
    }

    fn stageTemp(self: *Pending) !void {
        if (self.kind == .delete) return;
        try writeDurably(self.io, self.temp, self.data);
        self.replacement = Guard.open(self.temp) catch |err| {
            _ = deleteWithRetry(self.io, self.temp);
            return err;
        };
        self.state = .staged;
    }

    pub fn swap(self: *Pending, in_gap: ?Hook) !void {
        switch (self.kind) {
            .modify => try self.replace(in_gap),
            .create => try self.place(in_gap),
            .delete => {},
        }
    }

    fn replace(self: *Pending, in_gap: ?Hook) !void {
        const guard = self.guard.?;
        const bytes = try guard.readAll(self.gpa, self.io);
        defer self.gpa.free(bytes);
        if (!std.mem.eql(u8, &symbol.hashOf(bytes), &self.base_hash.?)) return error.BaseChanged;
        try writeDurably(self.io, self.backup, bytes);
        self.state = .backed_up;
        if (in_gap) |hook| try hook.run(hook.context);
        try self.replacement.?.renameReplacing(self.gpa, self.path);
        applyAttributes(self.path, self.saved_attributes) catch {};
        self.state = .swapped;
    }

    fn place(self: *Pending, in_gap: ?Hook) !void {
        if (in_gap) |hook| try hook.run(hook.context);
        self.replacement.?.renameTo(self.gpa, self.path) catch |err| switch (err) {
            error.PathAlreadyExists => return error.Conflict,
            else => |e| return e,
        };
        self.state = .swapped;
    }

    pub fn verify(self: *Pending) !void {
        const handle = if (self.kind == .delete) self.guard.? else self.replacement.?;
        const expected = if (self.kind == .delete) self.base_hash.? else self.data_hash;
        const written = handle.hash(self.gpa, self.io) catch return error.WrittenButUnverified;
        if (!std.mem.eql(u8, &written, &expected)) return error.WrittenButUnverified;
    }

    fn finish(self: *Pending, leftover: ?*Leftover) !void {
        switch (self.kind) {
            .modify => {
                self.closeHandles();
                if (!deleteWithRetry(self.io, self.backup)) {
                    if (leftover) |out| out.record(self.backup);
                }
            },
            .delete => {
                defer self.closeHandles();
                try self.guard.?.deleteSelf();
            },
            .create => self.closeHandles(),
        }
    }

    pub fn finalize(self: *Pending, leftover: ?*Leftover) void {
        self.finish(leftover) catch {
            if (leftover) |out| out.record(self.path);
        };
        self.freePaths();
    }

    pub fn abandon(self: *Pending) void {
        self.closeHandles();
        self.freePaths();
    }

    fn closeReplacement(self: *Pending) void {
        if (self.replacement) |r| r.close();
        self.replacement = null;
    }

    fn closeHandles(self: *Pending) void {
        self.closeReplacement();
        if (self.guard) |g| g.close();
        self.guard = null;
    }

    pub fn discard(self: *Pending, leftover: ?*Leftover) void {
        switch (self.kind) {
            .modify => self.restoreBase(leftover),
            .create => self.removeCreated(leftover),
            .delete => {},
        }
        self.closeHandles();
        self.freePaths();
    }

    fn restoreBase(self: *Pending, leftover: ?*Leftover) void {
        self.closeReplacement();
        switch (self.state) {
            .planned => {},
            .staged => _ = deleteWithRetry(self.io, self.temp),
            .backed_up => {
                _ = deleteWithRetry(self.io, self.temp);
                _ = deleteWithRetry(self.io, self.backup);
            },
            .swapped => {
                const backup = Guard.open(self.backup) catch {
                    if (leftover) |out| out.record(self.backup);
                    return;
                };
                defer backup.close();
                backup.renameReplacing(self.gpa, self.path) catch {
                    if (leftover) |out| out.record(self.backup);
                };
            },
        }
    }

    fn removeCreated(self: *Pending, leftover: ?*Leftover) void {
        if (self.state == .swapped) {
            self.replacement.?.renameTo(self.gpa, self.temp) catch {
                if (leftover) |out| out.record(self.path);
                self.closeReplacement();
                return;
            };
        }
        self.closeReplacement();
        if (self.state != .planned) _ = deleteWithRetry(self.io, self.temp);
    }

    fn freePaths(self: *Pending) void {
        if (self.freed) return;
        self.freed = true;
        self.gpa.free(self.path);
        self.gpa.free(self.temp);
        self.gpa.free(self.backup);
    }
};

fn plan(gpa: Allocator, io: std.Io, kind: Pending.Kind, path_abs: []const u8, data: []const u8, guard: ?Guard, base_hash: ?symbol.Hash, saved_attributes: windows.DWORD) !Pending {
    var random: [8]u8 = undefined;
    io.random(&random);
    const tag = std.fmt.bytesToHex(random, .lower);
    const path = try gpa.dupe(u8, path_abs);
    errdefer gpa.free(path);
    const temp = try std.fmt.allocPrint(gpa, "{s}.emetgate-{s}.tmp", .{ path_abs, &tag });
    errdefer gpa.free(temp);
    const backup = try std.fmt.allocPrint(gpa, "{s}.emetgate-{s}.bak", .{ path_abs, &tag });
    return .{
        .gpa = gpa,
        .io = io,
        .kind = kind,
        .guard = guard,
        .path = path,
        .temp = temp,
        .backup = backup,
        .tag = tag,
        .data = data,
        .base_hash = base_hash,
        .saved_attributes = saved_attributes,
        .data_hash = symbol.hashOf(data),
    };
}

fn openBase(gpa: Allocator, io: std.Io, path_abs: []const u8, expected_base: symbol.Hash) !struct { guard: Guard, attributes: windows.DWORD } {
    if (builtin.os.tag != .windows) return error.Unsupported;
    if (path_abs.len + sidecar_suffix_max > std.fs.max_path_bytes) return error.NameTooLong;
    const guard = try Guard.open(path_abs);
    errdefer guard.close();
    if (!std.mem.eql(u8, &(try guard.hash(gpa, io)), &expected_base)) return error.BaseChanged;
    const attributes = try guard.attributes();
    if (attributes & win.file_attribute_readonly != 0) return error.ReadOnlyFile;
    return .{ .guard = guard, .attributes = attributes };
}

pub fn prepare(gpa: Allocator, io: std.Io, path_abs: []const u8, data: []const u8, expected_base: symbol.Hash) !Pending {
    const base = try openBase(gpa, io, path_abs, expected_base);
    errdefer base.guard.close();
    return plan(gpa, io, .modify, path_abs, data, base.guard, expected_base, base.attributes);
}

pub fn stageCreate(gpa: Allocator, io: std.Io, path_abs: []const u8, data: []const u8) !Pending {
    if (builtin.os.tag != .windows) return error.Unsupported;
    if (path_abs.len + sidecar_suffix_max > std.fs.max_path_bytes) return error.NameTooLong;
    if (try pathExists(io, path_abs)) return error.FileExists;
    return plan(gpa, io, .create, path_abs, data, null, null, 0);
}

pub fn stageDelete(gpa: Allocator, io: std.Io, path_abs: []const u8, expected_base: symbol.Hash) !Pending {
    if (shadow.isReparsePoint(path_abs) catch true) return error.ReparsePoint;
    const base = try openBase(gpa, io, path_abs, expected_base);
    errdefer base.guard.close();
    return plan(gpa, io, .delete, path_abs, "", base.guard, expected_base, base.attributes);
}

fn pathExists(io: std.Io, path_abs: []const u8) !bool {
    std.Io.Dir.cwd().access(io, path_abs, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    return true;
}

fn writeBatchJournal(b: *const Batch, pendings: []const Pending) ![]u8 {
    const intents = try b.gpa.alloc(journal.Intent, pendings.len);
    defer b.gpa.free(intents);
    for (pendings, intents) |*p, *slot| slot.* = p.intent();
    return journal.write(b.gpa, b.io, b.journal_dir, &b.tag, intents);
}

fn abort(pendings: []Pending, leftover: ?*Leftover, batch: ?*const Batch, journal_path: ?[]const u8) void {
    var k = pendings.len;
    while (k > 0) {
        k -= 1;
        pendings[k].discard(leftover);
    }
    const b = batch orelse return;
    if (journal_path) |jp| _ = deleteWithRetry(b.io, jp);
}

fn abandonAll(pendings: []Pending) error{Crashed} {
    for (pendings) |*p| p.abandon();
    return error.Crashed;
}

pub fn commitBatch(pendings: []Pending, leftover: ?*Leftover, fail_before: ?usize, batch: ?*const Batch, step: ?*const Step) !void {
    var journal_path: ?[]u8 = null;
    defer if (journal_path) |jp| batch.?.gpa.free(jp);
    if (batch) |b| {
        journal_path = writeBatchJournal(b, pendings) catch |err| {
            abort(pendings, leftover, null, null);
            return err;
        };
        if (Step.stops(step)) return abandonAll(pendings);
    }
    for (pendings) |*p| {
        if (p.kind == .delete) continue;
        p.stageTemp() catch |err| {
            abort(pendings, leftover, batch, journal_path);
            return err;
        };
        if (Step.stops(step)) return abandonAll(pendings);
    }
    for (pendings, 0..) |*p, k| {
        if (fail_before) |f| if (f == k) {
            abort(pendings, leftover, batch, journal_path);
            return error.BatchAborted;
        };
        p.swap(Step.gap(step)) catch |err| {
            if (err == error.Crashed) return abandonAll(pendings);
            abort(pendings, leftover, batch, journal_path);
            return err;
        };
        if (p.kind != .delete and Step.stops(step)) return abandonAll(pendings);
    }
    for (pendings) |*p| {
        p.verify() catch {
            abort(pendings, leftover, batch, journal_path);
            return error.WrittenButUnverified;
        };
    }
    if (batch) |b| commit_record.write(b.gpa, b.io, b.journal_dir, &b.tag) catch |err| {
        abort(pendings, leftover, batch, journal_path);
        return err;
    };
    if (Step.stops(step)) return abandonAll(pendings);
    for (pendings) |*p| {
        if (p.kind == .create) {
            p.closeHandles();
            continue;
        }
        p.finish(leftover) catch {
            if (leftover) |out| out.record(p.path);
        };
        if (Step.stops(step)) return abandonAll(pendings);
    }
    const indexed = syncBatchIndex(pendings, batch);
    if (needsIndex(pendings) and Step.stops(step)) return abandonAll(pendings);
    for (pendings) |*p| p.freePaths();
    if (batch) |b| {
        if (journal_path) |jp| _ = deleteWithRetry(b.io, jp);
        if (Step.stops(step)) return error.Crashed;
        commit_record.remove(b.gpa, b.io, b.journal_dir, &b.tag) catch {};
    }
    return indexed;
}

fn needsIndex(pendings: []const Pending) bool {
    for (pendings) |p| {
        if (p.kind != .modify) return true;
    }
    return false;
}

fn syncBatchIndex(pendings: []const Pending, batch: ?*const Batch) !void {
    if (!needsIndex(pendings)) return;
    const b = batch orelse return;
    const root = b.root orelse return;
    var added: std.ArrayList([]const u8) = .empty;
    defer added.deinit(b.gpa);
    var removed: std.ArrayList([]const u8) = .empty;
    defer removed.deinit(b.gpa);
    for (pendings) |p| switch (p.kind) {
        .create => try added.append(b.gpa, p.path),
        .delete => try removed.append(b.gpa, p.path),
        .modify => {},
    };
    try syncIndex(b.gpa, b.io, root, added.items, removed.items);
}

fn syncIndex(gpa: Allocator, io: std.Io, root: []const u8, added: []const []const u8, removed: []const []const u8) !void {
    if (added.len != 0) try git_repo.addAllToIndex(gpa, io, root, added);
    if (removed.len != 0) try git_repo.removeAllFromIndex(gpa, io, root, removed);
}

pub const RecoverReport = struct {
    restored: usize = 0,
    rolled_forward: usize = 0,
    removed_temps: usize = 0,
    skipped: usize = 0,
    failed: usize = 0,
    not_indexed: usize = 0,
};

const SidecarKind = enum { tmp, bak };

fn sidecarKind(name: []const u8) ?SidecarKind {
    if (name.len < sidecar_suffix_max) return null;
    const suffix = name[name.len - sidecar_suffix_max ..];
    if (!std.mem.startsWith(u8, suffix, ".emetgate-")) return null;
    for (suffix[10..26]) |c| if (!std.ascii.isHex(c)) return null;
    if (suffix[26] != '.') return null;
    const ext = suffix[27..30];
    if (std.mem.eql(u8, ext, "tmp")) return .tmp;
    if (std.mem.eql(u8, ext, "bak")) return .bak;
    return null;
}

fn skipDir(name: []const u8) bool {
    return std.mem.eql(u8, name, ".git") or std.mem.eql(u8, name, "node_modules") or std.mem.eql(u8, name, ".emetgate");
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

fn rollForward(gpa: Allocator, io: std.Io, bak_abs: []const u8, target_abs: []const u8, new_hash: symbol.Hash) !void {
    const guard = try Guard.open(target_abs);
    defer guard.close();
    if (!std.mem.eql(u8, &(try guard.hash(gpa, io)), &new_hash)) return error.TargetUnverified;
    if (!deleteWithRetry(io, bak_abs)) return error.BackupNotRemoved;
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

pub const recover_failed_exit_code: u8 = 16;

pub fn recoverWorkspace(gpa: Allocator, io: std.Io, root_abs: []const u8, shadow_root_dir: ?[]const u8, err_out: *std.Io.Writer) !u8 {
    const report = try recover(gpa, io, root_abs);
    const location = try shadow_root.locate(gpa, root_abs, shadow_root_dir);
    defer location.deinit(gpa);
    const removal = shadow.remove(io, location.base, location.shadow);

    try err_out.print("recovered {d} file(s), rolled forward {d}, removed {d} orphaned temp file(s), skipped {d}, failed {d}, not indexed {d}\n", .{ report.restored, report.rolled_forward, report.removed_temps, report.skipped, report.failed, report.not_indexed });
    if (removal) |_| {} else |err| {
        try err_out.print("could not remove shadow: {t}\n", .{err});
        return recover_failed_exit_code;
    }
    return if (report.failed > 0 or report.not_indexed > 0) recover_failed_exit_code else 0;
}

const Verified = enum { deleted, missing, mismatch };

fn deleteVerified(gpa: Allocator, io: std.Io, path_abs: []const u8, expected: symbol.Hash, in_gap: ?Hook) !Verified {
    const guard = Guard.open(path_abs) catch |err| switch (err) {
        error.BaseChanged => return .missing,
        else => |e| return e,
    };
    defer guard.close();
    if (!std.mem.eql(u8, &(try guard.hash(gpa, io)), &expected)) return .mismatch;
    if (in_gap) |hook| try hook.run(hook.context);
    try guard.deleteSelf();
    return .deleted;
}

fn hasHash(gpa: Allocator, io: std.Io, path_abs: []const u8, expected: symbol.Hash) bool {
    const guard = Guard.open(path_abs) catch return false;
    defer guard.close();
    const actual = guard.hash(gpa, io) catch return false;
    return std.mem.eql(u8, &actual, &expected);
}

const IndexQueue = struct {
    gpa: Allocator,
    added: std.ArrayList([]u8) = .empty,
    removed: std.ArrayList([]u8) = .empty,

    fn deinit(self: *IndexQueue) void {
        for (self.added.items) |p| self.gpa.free(p);
        for (self.removed.items) |p| self.gpa.free(p);
        self.added.deinit(self.gpa);
        self.removed.deinit(self.gpa);
    }

    fn add(self: *IndexQueue, path: []const u8) !void {
        try self.added.append(self.gpa, try self.gpa.dupe(u8, path));
    }

    fn remove(self: *IndexQueue, path: []const u8) !void {
        try self.removed.append(self.gpa, try self.gpa.dupe(u8, path));
    }

    fn len(self: *const IndexQueue) usize {
        return self.added.items.len + self.removed.items.len;
    }

    fn flush(self: *IndexQueue, io: std.Io, root_abs: []const u8, report: *RecoverReport) void {
        if (self.len() == 0) return;
        const added: []const []const u8 = self.added.items;
        const removed: []const []const u8 = self.removed.items;
        syncIndex(self.gpa, io, root_abs, added, removed) catch {
            report.not_indexed += self.len();
        };
    }
};

fn recoverCreated(gpa: Allocator, io: std.Io, target_abs: []const u8, new_hash: symbol.Hash, committed: bool, index: *IndexQueue, report: *RecoverReport) !void {
    if (committed) {
        if (!hasHash(gpa, io, target_abs, new_hash)) {
            report.skipped += 1;
            return;
        }
        try index.add(target_abs);
        report.rolled_forward += 1;
        return;
    }
    switch (try deleteVerified(gpa, io, target_abs, new_hash, null)) {
        .deleted => report.restored += 1,
        .missing, .mismatch => report.skipped += 1,
    }
}

fn recoverDeleted(gpa: Allocator, io: std.Io, target_abs: []const u8, base_hash: symbol.Hash, index: *IndexQueue, report: *RecoverReport) !void {
    switch (try deleteVerified(gpa, io, target_abs, base_hash, null)) {
        .deleted, .missing => {
            try index.remove(target_abs);
            report.rolled_forward += 1;
        },
        .mismatch => report.skipped += 1,
    }
}

fn recoverModified(gpa: Allocator, io: std.Io, target_abs: []const u8, tag: []const u8, base_hash: symbol.Hash, new_hash: ?symbol.Hash, committed: bool, report: *RecoverReport) !void {
    const bak = try std.fmt.allocPrint(gpa, "{s}.emetgate-{s}.bak", .{ target_abs, tag });
    defer gpa.free(bak);
    if (committed) {
        rollForward(gpa, io, bak, target_abs, new_hash orelse return error.MissingNewHash) catch {
            report.failed += 1;
            return;
        };
        report.rolled_forward += 1;
        return;
    }
    restoreVerified(gpa, io, bak, target_abs, base_hash) catch |err| switch (err) {
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

    var index: IndexQueue = .{ .gpa = gpa };
    defer index.deinit();
    var index_journals: std.ArrayList([]u8) = .empty;
    defer {
        for (index_journals.items) |j| gpa.free(j);
        index_journals.deinit(gpa);
    }
    var kept: std.ArrayList([]const u8) = .empty;
    defer kept.deinit(gpa);
    for (names.items) |name| {
        var jp_buf: [std.fs.max_path_bytes]u8 = undefined;
        const jp = std.fmt.bufPrint(&jp_buf, "{s}\\{s}", .{ journal_dir, name }) catch continue;
        const tag = name[0 .. name.len - ".json".len];
        const outcome = applyJournal(gpa, io, root_abs, journal_dir, jp, tag, &index, report) catch blk: {
            report.failed += 1;
            break :blk .delete;
        };
        switch (outcome) {
            .delete => _ = deleteWithRetry(io, jp),
            .after_index => try index_journals.append(gpa, try gpa.dupe(u8, jp)),
            .keep => try kept.append(gpa, tag),
        }
    }
    index.flush(io, root_abs, report);
    for (index_journals.items) |jp| _ = deleteWithRetry(io, jp);
    try commit_record.removeAll(gpa, io, journal_dir, kept.items);
    std.Io.Dir.cwd().deleteDir(io, journal_dir) catch {};
}

const JournalOutcome = enum { delete, after_index, keep };

fn applyJournal(gpa: Allocator, io: std.Io, root_abs: []const u8, journal_dir: []const u8, journal_path: []const u8, tag: []const u8, index: *IndexQueue, report: *RecoverReport) !JournalOutcome {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, journal_path, gpa, .limited(journal.max_bytes));
    defer gpa.free(bytes);
    const parsed = journal.parse(gpa, bytes) catch {
        report.failed += 1;
        return .delete;
    };
    defer parsed.deinit();
    return switch (parsed) {
        .batch => |b| applyBatchJournal(gpa, io, root_abs, journal_dir, tag, b.value, index, report),
        .legacy => |l| applyLegacyJournal(gpa, io, root_abs, journal_dir, tag, l.value, index, report),
    };
}

const CheckedIntent = struct {
    op: journal.Op,
    target: []const u8,
    tag: []const u8,
    base_hash: ?symbol.Hash,
    new_hash: ?symbol.Hash,
};

fn checkIntent(root_abs: []const u8, raw: journal.RawIntent) !CheckedIntent {
    const op = std.meta.stringToEnum(journal.Op, raw.op) orelse return error.CorruptJournal;
    if (raw.target.len == 0 or !isUnderRoot(root_abs, raw.target)) return error.CorruptJournal;
    if (try escapesViaReparse(root_abs, raw.target)) return error.CorruptJournal;
    const base_hash: ?symbol.Hash = if (raw.base_hash.len == 0) null else symbol.parseHash(raw.base_hash) catch return error.CorruptJournal;
    const new_hash: ?symbol.Hash = if (raw.new_hash.len == 0) null else symbol.parseHash(raw.new_hash) catch return error.CorruptJournal;
    switch (op) {
        .modify => if (!isValidTag(raw.tag) or base_hash == null or new_hash == null) return error.CorruptJournal,
        .create => if (!isValidTag(raw.tag) or new_hash == null) return error.CorruptJournal,
        .delete => if (base_hash == null) return error.CorruptJournal,
    }
    return .{ .op = op, .target = raw.target, .tag = raw.tag, .base_hash = base_hash, .new_hash = new_hash };
}

fn applyBatchJournal(gpa: Allocator, io: std.Io, root_abs: []const u8, journal_dir: []const u8, tag: []const u8, batch: journal.Batch, index: *IndexQueue, report: *RecoverReport) !JournalOutcome {
    if (!isValidTag(batch.batch) or !std.mem.eql(u8, batch.batch, tag)) {
        report.failed += 1;
        return .keep;
    }
    const checked = try gpa.alloc(CheckedIntent, batch.intents.len);
    defer gpa.free(checked);
    for (batch.intents, checked) |raw, *slot| {
        slot.* = checkIntent(root_abs, raw) catch {
            report.failed += 1;
            return .keep;
        };
    }
    const committed = try commit_record.exists(gpa, io, journal_dir, batch.batch);
    for (checked) |intent| switch (intent.op) {
        .modify => try recoverModified(gpa, io, intent.target, intent.tag, intent.base_hash.?, intent.new_hash, committed, report),
        .create => try recoverCreated(gpa, io, intent.target, intent.new_hash.?, committed, index, report),
        .delete => if (committed) try recoverDeleted(gpa, io, intent.target, intent.base_hash.?, index, report),
    };
    return if (committed) .after_index else .delete;
}

fn applyLegacyJournal(gpa: Allocator, io: std.Io, root_abs: []const u8, journal_dir: []const u8, tag: []const u8, entry: journal.Legacy, index: *IndexQueue, report: *RecoverReport) !JournalOutcome {
    const op = std.meta.stringToEnum(journal.Op, entry.op) orelse {
        report.failed += 1;
        return .delete;
    };
    const target = entry.target;
    if (target.len == 0 or op == .delete) {
        report.failed += 1;
        return .delete;
    }
    if (!isUnderRoot(root_abs, target) or try escapesViaReparse(root_abs, target)) {
        report.failed += 1;
        return .delete;
    }
    if (!isValidTag(tag)) {
        report.failed += 1;
        return .delete;
    }
    const batch = entry.batch;
    if (batch.len != 0 and !isValidTag(batch)) {
        report.failed += 1;
        return .delete;
    }
    const committed = batch.len != 0 and try commit_record.exists(gpa, io, journal_dir, batch);

    if (op == .create) {
        const new_hash = symbol.parseHash(entry.new_hash) catch {
            report.failed += 1;
            return .delete;
        };
        try recoverCreated(gpa, io, target, new_hash, committed, index, report);
        return if (committed) .after_index else .delete;
    }

    const base_hash = symbol.parseHash(entry.base_hash) catch {
        report.failed += 1;
        return .delete;
    };
    const new_hash: ?symbol.Hash = symbol.parseHash(entry.new_hash) catch null;
    if (committed and new_hash == null) {
        report.failed += 1;
        return .delete;
    }
    try recoverModified(gpa, io, target, tag, base_hash, new_hash, committed, report);
    return .delete;
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

fn replaceInternal(gpa: Allocator, io: std.Io, path_abs: []const u8, data: []const u8, expected_base: symbol.Hash, leftover: ?*Leftover, step: ?*const Step, journal_dir: ?[]const u8) !void {
    var pendings = [1]Pending{try prepare(gpa, io, path_abs, data, expected_base)};
    const batch: ?Batch = if (journal_dir) |dir| Batch.init(gpa, io, dir) else null;
    try commitBatch(&pendings, leftover, null, if (batch) |*b| b else null, step);
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

pub fn replaceByRename(gpa: Allocator, io: std.Io, path_abs: []const u8, data: []const u8, expected_base: symbol.Hash) !void {
    if (builtin.os.tag != .windows) return error.Unsupported;
    if (path_abs.len + sidecar_suffix_max > std.fs.max_path_bytes) return error.NameTooLong;
    var random: [8]u8 = undefined;
    io.random(&random);
    const tag = std.fmt.bytesToHex(random, .lower);
    const temp = try std.fmt.allocPrint(gpa, "{s}.emetgate-{s}.tmp", .{ path_abs, &tag });
    defer gpa.free(temp);
    try writeDurably(io, temp, data);
    var renamed = false;
    defer if (!renamed) {
        _ = deleteWithRetry(io, temp);
    };
    try verifyBase(gpa, io, path_abs, expected_base);
    const replacement = try Guard.open(temp);
    defer replacement.close();
    try replacement.renameReplacing(gpa, path_abs);
    renamed = true;
}

pub fn writeDurably(io: std.Io, path: []const u8, data: []const u8) !void {
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
    const file_disposition_info_ex: c_int = 21;
    const file_disposition_flag_delete: windows.DWORD = 0x00000001;
    const file_disposition_flag_posix_semantics: windows.DWORD = 0x00000002;

    const FILE_DISPOSITION_INFO_EX = extern struct {
        flags: windows.DWORD,
    };
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
    const deleter = try fixture.openRaw(win.delete, win.file_share_read | win.file_share_write | win.file_share_delete);
    windows.CloseHandle(deleter);
    guard.close();

    const writer = try fixture.openRaw(win.generic_write, win.file_share_read | win.file_share_write | win.file_share_delete);
    windows.CloseHandle(writer);
}

const external_save = "export function f() { return 42; } // saved by another tool\n";

const ExternalWriter = struct {
    fixture: *Fixture,
    at: usize,
    seen: usize = 0,
    refused: bool = false,

    fn reached(context: *anyopaque) bool {
        const self: *ExternalWriter = @ptrCast(@alignCast(context));
        self.seen += 1;
        if (self.seen != self.at) return false;
        self.fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "target.ts", .data = external_save }) catch {
            self.refused = true;
        };
        return false;
    }
};

test "a writer that tries to save between the backup copy and the replace is refused and the replace lands whole" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fixture = try Fixture.init(original);
    defer fixture.deinit();

    var writer: ExternalWriter = .{ .fixture = &fixture, .at = 2 };
    const step: Step = .{ .context = &writer, .reached = ExternalWriter.reached };
    try replaceInternal(testing.allocator, testing.io, fixture.path(), updated, symbol.hashOf(original), null, &step, null);

    try testing.expect(writer.refused);
    try fixture.expectContent(updated);
    try fixture.expectEntries(1);
}

const Relocate = struct {
    tmp: *testing.TmpDir,
    path: []const u8,
    moved: []const u8,

    fn run(context: *anyopaque) anyerror!void {
        const self: *Relocate = @ptrCast(@alignCast(context));
        const other = try Guard.open(self.path);
        defer other.close();
        try other.renameTo(testing.allocator, self.moved);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "f.ts", .data = external_save });
    }
};

test "a verified delete removes the file it hashed even when the path is taken over before the delete" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f.ts", .data = original });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}\\f.ts", .{root});
    defer testing.allocator.free(path);

    const moved = try std.fmt.allocPrint(testing.allocator, "{s}\\moved.ts", .{root});
    defer testing.allocator.free(moved);
    var relocate: Relocate = .{ .tmp = &tmp, .path = path, .moved = moved };
    const hook: Hook = .{ .context = &relocate, .run = Relocate.run };
    try testing.expectEqual(Verified.deleted, try deleteVerified(testing.allocator, testing.io, path, symbol.hashOf(original), hook));

    const kept = try tmp.dir.readFileAlloc(testing.io, "f.ts", testing.allocator, .unlimited);
    defer testing.allocator.free(kept);
    try testing.expectEqualStrings(external_save, kept);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "moved.ts", .{}));
    try testing.expectEqual(Verified.mismatch, try deleteVerified(testing.allocator, testing.io, path, symbol.hashOf(original), null));
    try testing.expectEqual(Verified.missing, try deleteVerified(testing.allocator, testing.io, path[0 .. path.len - 4], symbol.hashOf(original), null));
}

test "commitBatch writes every file when all swaps succeed and leaves no sidecars" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var a = try Fixture.init(original);
    defer a.deinit();
    var b = try Fixture.init(original);
    defer b.deinit();

    var pendings = [_]Pending{
        try prepare(testing.allocator, testing.io, a.path(), updated, symbol.hashOf(original)),
        try prepare(testing.allocator, testing.io, b.path(), updated, symbol.hashOf(original)),
    };
    try commitBatch(&pendings, null, null, null, null);

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
        try prepare(testing.allocator, testing.io, a.path(), updated, symbol.hashOf(original)),
        try prepare(testing.allocator, testing.io, b.path(), updated, symbol.hashOf(original)),
    };
    try testing.expectError(error.BatchAborted, commitBatch(&pendings, null, 1, null, null));

    try a.expectContent(original);
    try b.expectContent(original);
    try a.expectEntries(1);
    try b.expectEntries(1);
}

const recover_tag = "0123456789abcdef";

fn writeLegacyJournal(journal_dir: []const u8, tag: []const u8, target_abs: []const u8, base_hash: symbol.Hash) !void {
    std.Io.Dir.cwd().createDirPath(testing.io, journal_dir) catch {};
    const hex = symbol.formatHash(base_hash);
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    var js: std.json.Stringify = .{ .writer = &buffer.writer };
    try js.beginObject();
    try js.objectField("target");
    try js.write(target_abs);
    try js.objectField("base_hash");
    try js.write(hex[0..]);
    try js.endObject();
    const path = try std.fmt.allocPrint(testing.allocator, "{s}\\{s}.json", .{ journal_dir, tag });
    defer testing.allocator.free(path);
    try writeDurably(testing.io, path, buffer.written());
}

fn seedRecover(root_abs: []const u8, tmp: *testing.TmpDir, target_content: []const u8, bak_content: []const u8) !void {
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f.ts", .data = target_content });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f.ts.emetgate-" ++ recover_tag ++ ".bak", .data = bak_content });
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target_abs = try std.fmt.bufPrint(&target_buf, "{s}\\f.ts", .{root_abs});
    var jdir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const jdir = try std.fmt.bufPrint(&jdir_buf, "{s}\\.emetgate\\journal", .{root_abs});
    try writeLegacyJournal(jdir, recover_tag, target_abs, symbol.hashOf(original));
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
    try outside.dir.writeFile(testing.io, .{ .sub_path = "x.emetgate-" ++ recover_tag ++ ".tmp", .data = "outside temp\n" });
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
    try outside.dir.access(testing.io, "x.emetgate-" ++ recover_tag ++ ".tmp", .{});
}

test "recover refuses a journal target that escapes the repo via .. (A hardening)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "repo");
    const root = try tmp.dir.realPathFileAlloc(testing.io, "repo", testing.allocator);
    defer testing.allocator.free(root);

    const mal = "export const PWNED = 1;\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "pwned.ts.emetgate-" ++ recover_tag ++ ".bak", .data = mal });
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buf, "{s}\\..\\pwned.ts", .{root});
    var jdir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const jdir = try std.fmt.bufPrint(&jdir_buf, "{s}\\.emetgate\\journal", .{root});
    try writeLegacyJournal(jdir, recover_tag, target, symbol.hashOf(mal));

    const report = try recover(testing.allocator, testing.io, root);
    try testing.expectEqual(@as(usize, 0), report.restored);
    try testing.expect(report.failed >= 1);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "pwned.ts", .{}));
}

test "create writes a new file durably and leaves no temp behind" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fixture = try Fixture.init(original);
    defer fixture.deinit();
    const dir_abs = try fixture.tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir_abs);
    const fresh = try std.fmt.allocPrint(testing.allocator, "{s}\\fresh.ts", .{dir_abs});
    defer testing.allocator.free(fresh);

    try create(testing.allocator, testing.io, fresh, updated);

    const written = try fixture.tmp.dir.readFileAlloc(testing.io, "fresh.ts", testing.allocator, .unlimited);
    defer testing.allocator.free(written);
    try testing.expectEqualStrings(updated, written);
    var listing = try fixture.tmp.dir.openDir(testing.io, ".", .{ .iterate = true });
    defer listing.close(testing.io);
    var iterator = listing.iterate();
    var count: usize = 0;
    while (try iterator.next(testing.io)) |entry| {
        errdefer std.debug.print("unexpected entry: {s}\n", .{entry.name});
        try testing.expect(std.mem.eql(u8, entry.name, "target.ts") or std.mem.eql(u8, entry.name, "fresh.ts"));
        count += 1;
    }
    try testing.expectEqual(@as(usize, 2), count);
}

test "create never overwrites an existing file and cleans up its temp" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fixture = try Fixture.init(original);
    defer fixture.deinit();

    try testing.expectError(error.FileExists, create(testing.allocator, testing.io, fixture.path(), updated));
    try fixture.expectContent(original);
    try fixture.expectEntries(1);
}
