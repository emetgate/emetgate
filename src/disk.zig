const std = @import("std");
const builtin = @import("builtin");
const symbol = @import("symbol.zig");

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
        return renameByHandle(gpa, self.handle, path_abs);
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

pub fn replaceAtomically(gpa: Allocator, io: std.Io, path_abs: []const u8, data: []const u8, expected_base: symbol.Hash) !void {
    return replaceWithHook(gpa, io, path_abs, data, expected_base, null);
}

fn replaceWithHook(gpa: Allocator, io: std.Io, path_abs: []const u8, data: []const u8, expected_base: symbol.Hash, in_gap: ?Hook) !void {
    if (builtin.os.tag != .windows) return error.Unsupported;

    const guard = try Guard.open(path_abs);
    var guard_open = true;
    defer if (guard_open) guard.close();
    if (!std.mem.eql(u8, &(try guard.hash(gpa, io)), &expected_base)) return error.BaseChanged;
    const saved_attributes = try guard.attributes();
    if (saved_attributes & win.file_attribute_readonly != 0) return error.ReadOnlyFile;

    var random: [8]u8 = undefined;
    io.random(&random);
    const tag = std.fmt.bytesToHex(random, .lower);
    const temp = try std.fmt.allocPrint(gpa, "{s}.synapse-{s}.tmp", .{ path_abs, &tag });
    defer gpa.free(temp);
    const backup = try std.fmt.allocPrint(gpa, "{s}.synapse-{s}.bak", .{ path_abs, &tag });
    defer gpa.free(backup);

    try writeDurably(io, temp, data);
    var temp_present = true;
    defer if (temp_present) deleteWithRetry(io, temp);

    const replacement = try Guard.open(temp);
    var replacement_open = true;
    defer if (replacement_open) replacement.close();

    try guard.renameTo(gpa, backup);
    var original_at_backup = true;
    errdefer if (original_at_backup) guard.renameTo(gpa, path_abs) catch {};

    if (in_gap) |hook| try hook.run(hook.context);

    replacement.renameTo(gpa, path_abs) catch |err| switch (err) {
        error.PathAlreadyExists => return error.Conflict,
        else => |e| return e,
    };
    temp_present = false;
    original_at_backup = false;
    applyAttributes(path_abs, saved_attributes) catch {};

    replacement.close();
    replacement_open = false;
    guard.close();
    guard_open = false;
    deleteWithRetry(io, backup);

    const written = hashFile(gpa, io, path_abs) catch return error.WrittenButUnverified;
    if (!std.mem.eql(u8, &written, &symbol.hashOf(data))) return error.WrittenButUnverified;
}

fn renameByHandle(gpa: Allocator, handle: windows.HANDLE, target_abs: []const u8) !void {
    var wide: WidePath = undefined;
    const name = try toWide(&wide, target_abs);
    const name_bytes = std.mem.sliceTo(name, 0).len * 2;

    const header = 20;
    const buffer = try gpa.alignedAlloc(u8, .of(u64), header + name_bytes);
    defer gpa.free(buffer);
    @memset(buffer, 0);
    std.mem.writeInt(u32, buffer[0..4], win.file_rename_flag_posix_semantics, .little);
    std.mem.writeInt(u32, buffer[16..20], @intCast(name_bytes), .little);
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

fn deleteWithRetry(io: std.Io, path: []const u8) void {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        std.Io.Dir.deleteFileAbsolute(io, path) catch |err| switch (err) {
            error.FileNotFound => return,
            else => {
                if (attempt + 1 >= delete_retries) return;
                win.Sleep(delete_retry_ms);
                continue;
            },
        };
        return;
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
    // A writer or a deleter cannot open the file while the guard is held.
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
    try testing.expectError(error.Conflict, replaceWithHook(testing.allocator, testing.io, fixture.path(), updated, symbol.hashOf(original), hook));

    try fixture.expectContent(external_save);
}
