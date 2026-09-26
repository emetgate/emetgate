const std = @import("std");
const disk = @import("disk.zig");

const Allocator = std.mem.Allocator;
const windows = std.os.windows;
const WidePath = [std.fs.max_path_bytes:0]u16;

pub const Tag = [16]u8;

const record_suffix = ".commit";
const staged_suffix = ".commit.tmp";
const staged_journal_suffix = ".json.tmp";

pub fn newTag(io: std.Io) Tag {
    var random: [8]u8 = undefined;
    io.random(&random);
    return std.fmt.bytesToHex(random, .lower);
}

pub fn write(gpa: Allocator, io: std.Io, journal_dir: []const u8, tag: []const u8) !void {
    const staged = try std.fmt.allocPrint(gpa, "{s}\\{s}" ++ staged_suffix, .{ journal_dir, tag });
    defer gpa.free(staged);
    const final = try recordPath(gpa, journal_dir, tag);
    defer gpa.free(final);

    const content = try std.fmt.allocPrint(gpa, "{{\"batch\":\"{s}\"}}", .{tag});
    defer gpa.free(content);
    try disk.writeDurably(io, staged, content);
    errdefer std.Io.Dir.deleteFileAbsolute(io, staged) catch {};
    try moveDurably(staged, final);
    flushDir(journal_dir) catch {};
}

pub fn exists(gpa: Allocator, io: std.Io, journal_dir: []const u8, tag: []const u8) !bool {
    const final = try recordPath(gpa, journal_dir, tag);
    defer gpa.free(final);
    std.Io.Dir.cwd().access(io, final, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    return true;
}

pub fn remove(gpa: Allocator, io: std.Io, journal_dir: []const u8, tag: []const u8) !void {
    const final = try recordPath(gpa, journal_dir, tag);
    defer gpa.free(final);
    std.Io.Dir.deleteFileAbsolute(io, final) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
    flushDir(journal_dir) catch {};
}

pub fn removeAll(gpa: Allocator, io: std.Io, journal_dir: []const u8, keep: []const []const u8) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, journal_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    defer dir.close(io);

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, record_suffix) and !std.mem.endsWith(u8, entry.name, staged_suffix) and !std.mem.endsWith(u8, entry.name, staged_journal_suffix)) continue;
        if (kept(entry.name, keep)) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    for (names.items) |name| dir.deleteFile(io, name) catch {};
    flushDir(journal_dir) catch {};
}

fn kept(name: []const u8, keep: []const []const u8) bool {
    for (keep) |tag| {
        if (std.mem.startsWith(u8, name, tag) and name.len > tag.len and name[tag.len] == '.') return true;
    }
    return false;
}

fn recordPath(gpa: Allocator, journal_dir: []const u8, tag: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}\\{s}" ++ record_suffix, .{ journal_dir, tag });
}

pub fn moveDurably(from: []const u8, to: []const u8) !void {
    var from_wide: WidePath = undefined;
    var to_wide: WidePath = undefined;
    if (win.MoveFileExW(try toWide(&from_wide, from), try toWide(&to_wide, to), win.movefile_write_through) == .FALSE) return error.RenameFailed;
}

pub fn flushDir(dir_abs: []const u8) !void {
    var wide: WidePath = undefined;
    const handle = win.CreateFileW(
        try toWide(&wide, dir_abs),
        win.generic_write,
        win.file_share_read | win.file_share_write | win.file_share_delete,
        null,
        win.open_existing,
        win.file_flag_backup_semantics,
        null,
    );
    if (handle == windows.INVALID_HANDLE_VALUE) return error.OpenFailed;
    defer windows.CloseHandle(handle);
    if (win.FlushFileBuffers(handle) == .FALSE) return error.FlushFailed;
}

pub const long_path_threshold = 240;

pub fn toWide(buffer: *WidePath, path: []const u8) ![*:0]const u16 {
    const prefix = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\");
    const long = path.len >= long_path_threshold and path.len > 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '\\' or path[2] == '/');
    const offset: usize = if (long) prefix.len else 0;
    if (long) @memcpy(buffer[0..prefix.len], prefix);
    const len = std.unicode.wtf8ToWtf16Le(buffer[offset..], path) catch return error.InvalidWtf8;
    if (offset + len >= buffer.len) return error.NameTooLong;
    if (long) {
        for (buffer[offset .. offset + len]) |*unit| {
            if (unit.* == '/') unit.* = '\\';
        }
    }
    buffer[offset + len] = 0;
    return buffer;
}

const win = struct {
    const generic_write: windows.DWORD = 0x40000000;
    const file_share_read: windows.DWORD = 0x00000001;
    const file_share_write: windows.DWORD = 0x00000002;
    const file_share_delete: windows.DWORD = 0x00000004;
    const open_existing: windows.DWORD = 3;
    const file_flag_backup_semantics: windows.DWORD = 0x02000000;
    const movefile_write_through: windows.DWORD = 0x00000008;

    extern "kernel32" fn CreateFileW(
        name: [*:0]const u16,
        access: windows.DWORD,
        share: windows.DWORD,
        security: ?*anyopaque,
        disposition: windows.DWORD,
        flags: windows.DWORD,
        template: ?windows.HANDLE,
    ) callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn MoveFileExW(from: [*:0]const u16, to: [*:0]const u16, flags: windows.DWORD) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn FlushFileBuffers(handle: windows.HANDLE) callconv(.winapi) windows.BOOL;
};
