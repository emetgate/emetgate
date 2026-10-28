const std = @import("std");
const builtin = @import("builtin");
const sandbox = @import("sandbox.zig");
const shadow_root = @import("shadow_root.zig");
const commit_record = @import("commit_record.zig");

const Allocator = std.mem.Allocator;
const windows = std.os.windows;

pub const leases_dir = "leases";
pub const data_dir_name = "emetgate";
pub const default_wait_ms: u32 = 30_000;
const poll_ms: u32 = 25;

pub const Error = error{ CacheBusy, LeaseFailed, NameTooLong, InvalidWtf8, Unsupported };

pub const test_data_dir_relative = "zig-out\\test-appdata\\emetgate-test";

pub fn defaultDataDir(gpa: Allocator) ![]u8 {
    if (builtin.is_test) return testDataDir(gpa);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const local = (try sandbox.environmentValue(arena, std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA"))) orelse return error.LocalAppDataUnavailable;
    return std.fmt.allocPrint(gpa, "{s}\\{s}", .{ try longForm(arena, local), data_dir_name });
}

pub fn testDataDir(gpa: Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    return std.fmt.allocPrint(gpa, "{s}\\{s}-p{d}", .{ try longForm(arena, try currentDir(arena)), test_data_dir_relative, processId() });
}

fn currentDir(arena: Allocator) ![]const u8 {
    var buf: [std.fs.max_path_bytes:0]u16 = undefined;
    const len = win.GetCurrentDirectoryW(buf.len, &buf);
    if (len == 0 or len >= buf.len) return error.CurrentDirUnavailable;
    return std.unicode.wtf16LeToWtf8Alloc(arena, buf[0..len]);
}

pub fn longForm(arena: Allocator, path: []const u8) ![]const u8 {
    if (builtin.os.tag != .windows) return path;
    const wide = try std.unicode.wtf8ToWtf16LeAllocZ(arena, path);
    const needed = win.GetLongPathNameW(wide.ptr, null, 0);
    if (needed == 0) return path;
    const long = try arena.alloc(u16, needed);
    const written = win.GetLongPathNameW(wide.ptr, long.ptr, needed);
    if (written == 0 or written >= needed) return path;
    return std.unicode.wtf16LeToWtf8Alloc(arena, long[0..written]);
}

pub fn processId() u32 {
    if (builtin.os.tag != .windows) return 0;
    return win.GetCurrentProcessId();
}

pub fn moveAside(from_abs: []const u8, to_abs: []const u8) error{ EntryInUse, TombstoneFailed, NameTooLong, InvalidWtf8, Unsupported }!void {
    if (builtin.os.tag != .windows) return error.Unsupported;
    var from_wide: commit_record.WidePath = undefined;
    var to_wide: commit_record.WidePath = undefined;
    const from = commit_record.toWide(&from_wide, from_abs) catch |err| return narrow(err);
    const to = commit_record.toWide(&to_wide, to_abs) catch |err| return narrow(err);
    if (win.MoveFileExW(from, to, 0) != .FALSE) return;
    return switch (win.GetLastError()) {
        win.error_sharing_violation, win.error_access_denied => error.EntryInUse,
        else => error.TombstoneFailed,
    };
}

pub fn makeDirAbsolute(dir_abs: []const u8) error{ LeaseFailed, NameTooLong, InvalidWtf8 }!void {
    return makeDir(dir_abs);
}

pub fn entryDir(gpa: Allocator, root_abs: []const u8, family: []const u8) ![]u8 {
    const data = try defaultDataDir(gpa);
    defer gpa.free(data);
    try holdForProcess(data, root_abs);
    const key = shadow_root.repoKey(root_abs);
    return std.fmt.allocPrint(gpa, "{s}\\{s}\\{s}", .{ data, family, &key });
}

pub fn holdDefault(gpa: Allocator, root_abs: []const u8) !void {
    const data = try defaultDataDir(gpa);
    defer gpa.free(data);
    try holdForProcess(data, root_abs);
}

pub fn dataDirOfBase(gpa: Allocator, base_abs: []const u8) !?[]u8 {
    const default_base = shadow_root.defaultBase(gpa) catch return null;
    defer gpa.free(default_base);
    if (!std.ascii.eqlIgnoreCase(default_base, base_abs)) return null;
    const parent = std.fs.path.dirname(base_abs) orelse return null;
    return try gpa.dupe(u8, parent);
}

pub fn leasePath(buffer: []u8, data_abs: []const u8, key: []const u8) ![]u8 {
    return std.fmt.bufPrint(buffer, "{s}\\{s}\\{s}", .{ data_abs, leases_dir, key });
}

pub const Lease = struct {
    handle: windows.HANDLE,

    pub fn release(self: Lease) void {
        windows.CloseHandle(self.handle);
    }
};

pub fn acquire(data_abs: []const u8, root_abs: []const u8, wait_ms: u32) Error!Lease {
    if (builtin.os.tag != .windows) return error.Unsupported;
    const key = shadow_root.repoKey(root_abs);
    try makeLeaseDir(data_abs);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = leasePath(&path_buf, data_abs, &key) catch return error.NameTooLong;
    var wide: commit_record.WidePath = undefined;
    const name = commit_record.toWide(&wide, path) catch |err| return narrow(err);
    var waited: u32 = 0;
    const handle = while (true) {
        const opened = win.CreateFileW(name, win.generic_read | win.generic_write, win.file_share_read | win.file_share_write, null, win.open_always, win.file_attribute_normal, null);
        if (opened != windows.INVALID_HANDLE_VALUE) break opened;
        switch (win.GetLastError()) {
            win.error_sharing_violation, win.error_access_denied => {},
            else => return error.LeaseFailed,
        }
        if (waited >= wait_ms) return error.CacheBusy;
        win.Sleep(poll_ms);
        waited += poll_ms;
    };
    errdefer windows.CloseHandle(handle);
    var written: windows.DWORD = 0;
    if (win.WriteFile(handle, root_abs.ptr, @intCast(root_abs.len), &written, null) == .FALSE or written != root_abs.len) return error.LeaseFailed;
    if (win.SetEndOfFile(handle) == .FALSE) return error.LeaseFailed;
    return .{ .handle = handle };
}

const Held = struct { key: [shadow_root.key_len]u8, lease: Lease };

var held_mutex: std.atomic.Mutex = .unlocked;
var held: std.ArrayList(Held) = .empty;

pub fn holdForProcess(data_abs: []const u8, root_abs: []const u8) Error!void {
    if (builtin.os.tag != .windows) return;
    const key = shadow_root.repoKey(root_abs);
    while (!held_mutex.tryLock()) std.atomic.spinLoopHint();
    defer held_mutex.unlock();
    for (held.items) |item| {
        if (std.mem.eql(u8, &item.key, &key)) return;
    }
    const lease = try acquire(data_abs, root_abs, default_wait_ms);
    held.append(std.heap.page_allocator, .{ .key = key, .lease = lease }) catch lease.release();
    if (builtin.is_test and @hasDecl(@import("root"), "emetgate_release_leases")) @import("root").emetgate_release_leases = releaseHeld;
}

pub fn releaseHeld() void {
    while (!held_mutex.tryLock()) std.atomic.spinLoopHint();
    defer held_mutex.unlock();
    for (held.items) |item| item.lease.release();
    held.clearAndFree(std.heap.page_allocator);
}

pub const Claim = struct {
    handle: windows.HANDLE,
    created: bool,

    pub fn file(self: Claim) std.Io.File {
        return .{ .handle = self.handle, .flags = .{ .nonblocking = false } };
    }

    pub fn readRoot(self: Claim, io: std.Io, buffer: []u8) ?[]const u8 {
        const len = self.file().readPositionalAll(io, buffer, 0) catch return null;
        if (len == 0 or len == buffer.len) return null;
        return buffer[0..len];
    }

    pub fn modifiedNs(self: Claim, io: std.Io) ?i96 {
        const stat = self.file().stat(io) catch return null;
        return stat.mtime.nanoseconds;
    }

    pub fn release(self: Claim, drop_marker: bool) void {
        if (drop_marker or self.created) {
            var disposition: win.FILE_DISPOSITION_INFO = .{ .delete_file = .TRUE };
            _ = win.SetFileInformationByHandle(self.handle, win.file_disposition_info, &disposition, @sizeOf(win.FILE_DISPOSITION_INFO));
        }
        windows.CloseHandle(self.handle);
    }
};

pub fn claim(data_abs: []const u8, key: []const u8) error{ Busy, LeaseFailed, NameTooLong, InvalidWtf8, Unsupported }!Claim {
    if (builtin.os.tag != .windows) return error.Unsupported;
    try makeLeaseDir(data_abs);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = leasePath(&path_buf, data_abs, key) catch return error.NameTooLong;
    var wide: commit_record.WidePath = undefined;
    const name = commit_record.toWide(&wide, path) catch |err| return narrow(err);
    const handle = win.CreateFileW(name, win.generic_read | win.delete, 0, null, win.open_always, win.file_attribute_normal, null);
    if (handle == windows.INVALID_HANDLE_VALUE) return switch (win.GetLastError()) {
        win.error_sharing_violation, win.error_access_denied => error.Busy,
        else => error.LeaseFailed,
    };
    return .{ .handle = handle, .created = win.GetLastError() != win.error_already_exists };
}

fn makeLeaseDir(data_abs: []const u8) error{ LeaseFailed, NameTooLong, InvalidWtf8 }!void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try makeDir(data_abs);
    try makeDir(std.fmt.bufPrint(&path_buf, "{s}\\{s}", .{ data_abs, leases_dir }) catch return error.NameTooLong);
}

fn makeDir(dir_abs: []const u8) error{ LeaseFailed, NameTooLong, InvalidWtf8 }!void {
    var wide: commit_record.WidePath = undefined;
    const name = commit_record.toWide(&wide, dir_abs) catch |err| return narrow(err);
    if (win.CreateDirectoryW(name, null) != .FALSE) return;
    if (win.GetLastError() != win.error_already_exists) return error.LeaseFailed;
}

fn narrow(err: anyerror) error{ NameTooLong, InvalidWtf8 } {
    return if (err == error.InvalidWtf8) error.InvalidWtf8 else error.NameTooLong;
}

const win = struct {
    const generic_read: windows.DWORD = 0x80000000;
    const generic_write: windows.DWORD = 0x40000000;
    const delete: windows.DWORD = 0x00010000;
    const file_share_read: windows.DWORD = 0x00000001;
    const file_share_write: windows.DWORD = 0x00000002;
    const open_always: windows.DWORD = 4;
    const file_attribute_normal: windows.DWORD = 0x00000080;
    const error_access_denied: windows.DWORD = 5;
    const error_sharing_violation: windows.DWORD = 32;
    const error_already_exists: windows.DWORD = 183;
    const file_disposition_info: c_int = 4;

    const FILE_DISPOSITION_INFO = extern struct {
        delete_file: windows.BOOL,
    };

    extern "kernel32" fn GetLastError() callconv(.winapi) windows.DWORD;
    extern "kernel32" fn GetCurrentDirectoryW(size: windows.DWORD, buffer: [*]u16) callconv(.winapi) windows.DWORD;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) windows.DWORD;
    extern "kernel32" fn GetLongPathNameW(short: [*:0]const u16, long: ?[*]u16, size: windows.DWORD) callconv(.winapi) windows.DWORD;
    extern "kernel32" fn MoveFileExW(from: [*:0]const u16, to: [*:0]const u16, flags: windows.DWORD) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn Sleep(ms: windows.DWORD) callconv(.winapi) void;
    extern "kernel32" fn CreateDirectoryW(name: [*:0]const u16, security: ?*anyopaque) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn WriteFile(handle: windows.HANDLE, data: [*]const u8, len: windows.DWORD, written: *windows.DWORD, overlapped: ?*anyopaque) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn SetEndOfFile(handle: windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn SetFileInformationByHandle(handle: windows.HANDLE, class: c_int, info: *const anyopaque, size: windows.DWORD) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn CreateFileW(
        name: [*:0]const u16,
        access: windows.DWORD,
        share: windows.DWORD,
        security: ?*anyopaque,
        disposition: windows.DWORD,
        flags: windows.DWORD,
        template: ?windows.HANDLE,
    ) callconv(.winapi) windows.HANDLE;
};

test "a test build resolves every cache path to a per-run dir under the working directory, outside the real data dir" {
    const gpa = std.testing.allocator;
    const isolated = try testDataDir(gpa);
    defer gpa.free(isolated);
    const data = try defaultDataDir(gpa);
    defer gpa.free(data);
    try std.testing.expectEqualStrings(isolated, data);
    const entry = try entryDir(gpa, "C:\\emetgate-test-missing\\repo", "find");
    defer gpa.free(entry);
    const base = try shadow_root.defaultBase(gpa);
    defer gpa.free(base);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "LOCALAPPDATA", "USERPROFILE" }, [_][]const u8{ "", "\\AppData\\Local" }) |name, suffix| {
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(arena, name);
        const value = (try sandbox.environmentValue(arena, wide)) orelse continue;
        const real = try std.fmt.allocPrint(arena, "{s}{s}\\{s}", .{ value, suffix, data_dir_name });
        for ([_][]const u8{ entry, base }) |path| {
            try std.testing.expect(std.ascii.startsWithIgnoreCase(path, isolated));
            try std.testing.expect(!std.ascii.startsWithIgnoreCase(path, real));
        }
    }
}

test "a data dir named through an 8.3 short path resolves to its long name, so the shadow root under it is accepted" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "a long folder name");
    const long = try tmp.dir.realPathFileAlloc(std.testing.io, "a long folder name", gpa);
    defer gpa.free(long);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const long_wide = try std.unicode.wtf8ToWtf16LeAllocZ(arena, long);
    var short_wide: [std.fs.max_path_bytes:0]u16 = undefined;
    const short_len = short_test_win.GetShortPathNameW(long_wide.ptr, &short_wide, short_wide.len);
    if (short_len == 0 or short_len >= short_wide.len) return error.SkipZigTest;
    const short = try std.unicode.wtf16LeToWtf8Alloc(arena, short_wide[0..short_len]);
    if (std.mem.indexOfScalar(u8, short, '~') == null) return error.SkipZigTest;

    try std.testing.expectEqualStrings(long, try longForm(arena, short));
    const base = try shadow_root.validBase(gpa, try std.fmt.allocPrint(arena, "{s}\\shadow", .{try longForm(arena, short)}));
    gpa.free(base);
    try std.testing.expectError(error.InvalidShadowRoot, shadow_root.validBase(gpa, try std.fmt.allocPrint(arena, "{s}\\shadow", .{short})));
}

const short_test_win = struct {
    extern "kernel32" fn GetShortPathNameW(long: [*:0]const u16, short: [*]u16, size: windows.DWORD) callconv(.winapi) windows.DWORD;
};
