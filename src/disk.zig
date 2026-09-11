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
            win.generic_read,
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
            else => error.ReplaceFailed,
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

    pub fn close(self: Guard) void {
        windows.CloseHandle(self.handle);
    }
};

pub fn replaceAtomically(gpa: Allocator, io: std.Io, path_abs: []const u8, data: []const u8, expected_base: symbol.Hash) !void {
    if (builtin.os.tag != .windows) return error.Unsupported;

    const guard = try Guard.open(path_abs);
    var guard_open = true;
    defer if (guard_open) guard.close();
    if (!std.mem.eql(u8, &(try guard.hash(gpa, io)), &expected_base)) return error.BaseChanged;
    if (try hasAttribute(path_abs, win.file_attribute_readonly)) return error.ReadOnlyFile;

    var random: [8]u8 = undefined;
    io.random(&random);
    const tag = std.fmt.bytesToHex(random, .lower);
    var temp_buf: [std.fs.max_path_bytes]u8 = undefined;
    var backup_buf: [std.fs.max_path_bytes]u8 = undefined;
    const temp = try std.fmt.bufPrint(&temp_buf, "{s}.synapse-{s}.tmp", .{ path_abs, &tag });
    const backup = try std.fmt.bufPrint(&backup_buf, "{s}.synapse-{s}.bak", .{ path_abs, &tag });

    try writeDurably(io, temp, data);
    errdefer std.Io.Dir.deleteFileAbsolute(io, temp) catch {};

    try replace(path_abs, temp, backup);
    guard.close();
    guard_open = false;
    std.Io.Dir.deleteFileAbsolute(io, backup) catch {};

    const written = try hashFile(gpa, io, path_abs);
    if (!std.mem.eql(u8, &written, &symbol.hashOf(data))) return error.CommitVerifyFailed;
}

fn writeDurably(io: std.Io, path: []const u8, data: []const u8) !void {
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true });
    errdefer std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    defer file.close(io);
    try file.writeStreamingAll(io, data);
    try file.sync(io);
}

fn replace(path_abs: []const u8, temp: []const u8, backup: []const u8) !void {
    var path_w: WidePath = undefined;
    var temp_w: WidePath = undefined;
    var backup_w: WidePath = undefined;
    const replaced = try toWide(&path_w, path_abs);
    const replacement = try toWide(&temp_w, temp);
    const backup_name = try toWide(&backup_w, backup);

    if (win.ReplaceFileW(replaced, replacement, backup_name, 0, null, null) != .FALSE) return;
    switch (win.GetLastError()) {
        win.error_sharing_violation, win.error_lock_violation => return error.FileLocked,
        win.error_access_denied => return error.AccessDenied,
        win.error_unable_to_move_replacement_2 => {
            if (win.MoveFileExW(backup_name, replaced, win.movefile_replace_existing | win.movefile_write_through) == .FALSE) {
                return error.RestoreFailed;
            }
            return error.ReplaceFailed;
        },
        else => return error.ReplaceFailed,
    }
}

fn hasAttribute(path_abs: []const u8, attribute: windows.DWORD) !bool {
    var wide: WidePath = undefined;
    const attributes = win.GetFileAttributesW(try toWide(&wide, path_abs));
    if (attributes == win.invalid_file_attributes) return error.BaseChanged;
    return attributes & attribute != 0;
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
    const file_share_read: windows.DWORD = 0x00000001;
    const file_share_write: windows.DWORD = 0x00000002;
    const file_share_delete: windows.DWORD = 0x00000004;
    const open_existing: windows.DWORD = 3;
    const file_attribute_readonly: windows.DWORD = 0x00000001;
    const file_attribute_hidden: windows.DWORD = 0x00000002;
    const file_attribute_normal: windows.DWORD = 0x00000080;
    const invalid_file_attributes: windows.DWORD = 0xFFFFFFFF;
    const movefile_replace_existing: windows.DWORD = 0x00000001;
    const movefile_write_through: windows.DWORD = 0x00000008;

    const error_file_not_found: windows.DWORD = 2;
    const error_path_not_found: windows.DWORD = 3;
    const error_access_denied: windows.DWORD = 5;
    const error_sharing_violation: windows.DWORD = 32;
    const error_lock_violation: windows.DWORD = 33;
    const error_unable_to_move_replacement_2: windows.DWORD = 1177;

    extern "kernel32" fn CreateFileW(
        name: [*:0]const u16,
        access: windows.DWORD,
        share: windows.DWORD,
        security: ?*anyopaque,
        disposition: windows.DWORD,
        flags: windows.DWORD,
        template: ?windows.HANDLE,
    ) callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn ReplaceFileW(
        replaced: [*:0]const u16,
        replacement: [*:0]const u16,
        backup: ?[*:0]const u16,
        flags: windows.DWORD,
        exclude: ?*anyopaque,
        reserved: ?*anyopaque,
    ) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn MoveFileExW(existing: [*:0]const u16, new: [*:0]const u16, flags: windows.DWORD) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetFileAttributesW(name: [*:0]const u16) callconv(.winapi) windows.DWORD;
    extern "kernel32" fn SetFileAttributesW(name: [*:0]const u16, attributes: windows.DWORD) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetLastError() callconv(.winapi) windows.DWORD;
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
};

test "an unchanged base is replaced atomically, keeps its attributes and leaves no temp or backup" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fixture = try Fixture.init(original);
    defer fixture.deinit();
    try fixture.setAttributes(win.file_attribute_hidden);

    try replaceAtomically(testing.allocator, testing.io, fixture.path(), updated, symbol.hashOf(original));

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
    try testing.expectError(error.BaseChanged, replaceAtomically(testing.allocator, testing.io, fixture.path(), updated, base));
    try fixture.expectContent(external);
    try fixture.expectEntries(1);
}

test "a file deleted since the session began is refused with BaseChanged" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fixture = try Fixture.init(original);
    defer fixture.deinit();
    try fixture.tmp.dir.deleteFile(testing.io, "target.ts");

    try testing.expectError(error.BaseChanged, verifyBase(testing.allocator, testing.io, fixture.path(), symbol.hashOf(original)));
    try testing.expectError(error.BaseChanged, replaceAtomically(testing.allocator, testing.io, fixture.path(), updated, symbol.hashOf(original)));
    try fixture.expectEntries(0);
}

test "a read-only file is refused and keeps both its content and its read-only flag" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fixture = try Fixture.init(original);
    defer fixture.deinit();
    try fixture.setAttributes(win.file_attribute_readonly);

    try testing.expectError(error.ReadOnlyFile, replaceAtomically(testing.allocator, testing.io, fixture.path(), updated, symbol.hashOf(original)));
    try fixture.expectContent(original);
    try testing.expect(try fixture.attributes() & win.file_attribute_readonly != 0);
    try fixture.expectEntries(1);
}

test "a file held open by another process is refused with FileLocked and succeeds once released" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fixture = try Fixture.init(original);
    defer fixture.deinit();
    const base = symbol.hashOf(original);

    const reader_without_delete_share = try fixture.openRaw(win.generic_read, win.file_share_read);
    try testing.expectError(error.FileLocked, replaceAtomically(testing.allocator, testing.io, fixture.path(), updated, base));
    windows.CloseHandle(reader_without_delete_share);
    try fixture.expectContent(original);
    try fixture.expectEntries(1);

    const active_writer = try fixture.openRaw(win.generic_write, win.file_share_read | win.file_share_write);
    try testing.expectError(error.FileLocked, replaceAtomically(testing.allocator, testing.io, fixture.path(), updated, base));
    windows.CloseHandle(active_writer);
    try fixture.expectContent(original);
    try fixture.expectEntries(1);

    try replaceAtomically(testing.allocator, testing.io, fixture.path(), updated, base);
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
    try testing.expectEqual(win.error_sharing_violation, win.GetLastError());
    guard.close();

    const writer = try fixture.openRaw(win.generic_write, win.file_share_read | win.file_share_write | win.file_share_delete);
    windows.CloseHandle(writer);
}
