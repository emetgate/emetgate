const std = @import("std");
const builtin = @import("builtin");
const commit_record = @import("commit_record.zig");

const Dir = std.Io.Dir;
const windows = std.os.windows;
const WidePath = [std.fs.max_path_bytes:0]u16;

pub const tag_len = 16;

pub const Mode = enum { existing, create };

pub const Error = error{
    WorkspaceIsLink,
    WorkspaceBusy,
    WorkspaceOpenFailed,
    NameTooLong,
    InvalidWtf8,
    Unsupported,
};

pub const Held = struct {
    parent: windows.HANDLE,
    dir: Dir,

    pub fn close(self: Held) void {
        windows.CloseHandle(self.dir.handle);
        windows.CloseHandle(self.parent);
    }
};

pub fn hold(io: std.Io, dir_abs: []const u8, mode: Mode) Error!?Held {
    if (builtin.os.tag != .windows) return error.Unsupported;
    const parent_abs = std.fs.path.dirname(dir_abs) orelse return error.WorkspaceOpenFailed;
    const parent = (try frozen(parent_abs)) orelse made: {
        if (mode == .existing) return null;
        make(io, parent_abs);
        break :made (try frozen(parent_abs)) orelse return error.WorkspaceOpenFailed;
    };
    errdefer windows.CloseHandle(parent);
    const handle = (try frozen(dir_abs)) orelse made: {
        if (mode == .existing) {
            windows.CloseHandle(parent);
            return null;
        }
        make(io, dir_abs);
        break :made (try frozen(dir_abs)) orelse return error.WorkspaceOpenFailed;
    };
    return .{ .parent = parent, .dir = .{ .handle = handle } };
}

fn make(io: std.Io, dir_abs: []const u8) void {
    Dir.cwd().createDir(io, dir_abs, .default_dir) catch {};
}

fn frozen(dir_abs: []const u8) Error!?windows.HANDLE {
    var wide: WidePath = undefined;
    const name = commit_record.toWide(&wide, dir_abs) catch |err| switch (err) {
        error.InvalidWtf8 => return error.InvalidWtf8,
        error.NameTooLong => return error.NameTooLong,
    };
    const handle = win.CreateFileW(
        name,
        win.generic_read | win.generic_write | win.file_traverse | win.file_delete_child,
        win.file_share_read | win.file_share_write,
        null,
        win.open_existing,
        win.file_flag_backup_semantics | win.file_flag_open_reparse_point,
        null,
    );
    if (handle == windows.INVALID_HANDLE_VALUE) return switch (win.GetLastError()) {
        win.error_file_not_found, win.error_path_not_found => null,
        win.error_sharing_violation => error.WorkspaceBusy,
        else => error.WorkspaceOpenFailed,
    };
    errdefer windows.CloseHandle(handle);
    if (!try plainDirectory(handle)) return error.WorkspaceIsLink;
    return handle;
}

fn plainDirectory(handle: windows.HANDLE) Error!bool {
    var info: win.BY_HANDLE_FILE_INFORMATION = undefined;
    if (win.GetFileInformationByHandle(handle, &info) == .FALSE) return error.WorkspaceOpenFailed;
    if (info.file_attributes & win.file_attribute_reparse_point != 0) return false;
    return info.file_attributes & win.file_attribute_directory != 0;
}

pub fn removeEmpty(dir_abs: []const u8) bool {
    if (builtin.os.tag != .windows) return false;
    var wide: WidePath = undefined;
    const name = commit_record.toWide(&wide, dir_abs) catch return false;
    const handle = win.CreateFileW(
        name,
        win.delete | win.file_read_attributes,
        win.file_share_read | win.file_share_write | win.file_share_delete,
        null,
        win.open_existing,
        win.file_flag_backup_semantics | win.file_flag_open_reparse_point,
        null,
    );
    if (handle == windows.INVALID_HANDLE_VALUE) return false;
    defer windows.CloseHandle(handle);
    if (!(plainDirectory(handle) catch false)) return false;
    var disposition: win.FILE_DISPOSITION_INFO = .{ .delete_file = .TRUE };
    return win.SetFileInformationByHandle(handle, win.file_disposition_info, &disposition, @sizeOf(win.FILE_DISPOSITION_INFO)) != .FALSE;
}

pub fn isTag(text: []const u8) bool {
    if (text.len != tag_len) return false;
    for (text) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    }
    return true;
}

pub fn tagOf(name: []const u8, suffixes: []const []const u8) ?[]const u8 {
    if (name.len <= tag_len or !isTag(name[0..tag_len])) return null;
    const rest = name[tag_len..];
    for (suffixes) |suffix| {
        if (std.mem.eql(u8, rest, suffix)) return name[0..tag_len];
    }
    return null;
}

pub fn numbered(name: []const u8, prefix: []const u8, suffix: []const u8) bool {
    if (name.len <= prefix.len + suffix.len) return false;
    if (!std.mem.startsWith(u8, name, prefix) or !std.mem.endsWith(u8, name, suffix)) return false;
    for (name[prefix.len .. name.len - suffix.len]) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

const win = struct {
    const generic_read: windows.DWORD = 0x80000000;
    const generic_write: windows.DWORD = 0x40000000;
    const delete: windows.DWORD = 0x00010000;
    const file_traverse: windows.DWORD = 0x00000020;
    const file_delete_child: windows.DWORD = 0x00000040;
    const file_read_attributes: windows.DWORD = 0x00000080;
    const file_share_read: windows.DWORD = 0x00000001;
    const file_share_write: windows.DWORD = 0x00000002;
    const file_share_delete: windows.DWORD = 0x00000004;
    const open_existing: windows.DWORD = 3;
    const file_flag_backup_semantics: windows.DWORD = 0x02000000;
    const file_flag_open_reparse_point: windows.DWORD = 0x00200000;
    const file_attribute_directory: windows.DWORD = 0x00000010;
    const file_attribute_reparse_point: windows.DWORD = 0x00000400;
    const error_file_not_found: windows.DWORD = 2;
    const error_path_not_found: windows.DWORD = 3;
    const error_sharing_violation: windows.DWORD = 32;
    const file_disposition_info: c_int = 4;

    const FILE_DISPOSITION_INFO = extern struct {
        delete_file: windows.BOOL,
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

    extern "kernel32" fn GetLastError() callconv(.winapi) windows.DWORD;
    extern "kernel32" fn GetFileInformationByHandle(handle: windows.HANDLE, info: *BY_HANDLE_FILE_INFORMATION) callconv(.winapi) windows.BOOL;
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
