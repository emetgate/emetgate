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

pub fn defaultDataDir(gpa: Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const local = (try sandbox.environmentValue(arena_state.allocator(), std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA"))) orelse return error.LocalAppDataUnavailable;
    return std.fmt.allocPrint(gpa, "{s}\\{s}", .{ local, data_dir_name });
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
