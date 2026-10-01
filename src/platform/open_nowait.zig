const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

const Allocator = std.mem.Allocator;
const WidePath = [windows.PATH_MAX_WIDE:0]u16;

pub const Error = error{ FileNotFound, FileBusy, AccessDenied, NameTooLong, BadPathName, Unexpected };
pub const ReadError = Error || error{ IsDir, StreamTooLong, OutOfMemory, InputOutput };

pub const Kind = enum { file, directory, link };

pub const Stat = struct {
    size: u64,
    mtime_ns: i64,
    ctime_ns: i64,
    kind: Kind,
};

pub fn openAttributes(path: []const u8, follow_links: bool) Error!windows.HANDLE {
    var wide: WidePath = undefined;
    const flags = win.file_flag_backup_semantics | @as(windows.DWORD, if (follow_links) 0 else win.file_flag_open_reparse_point);
    return open(try toWide(&wide, path), win.file_read_attributes, flags);
}

pub fn stat(path: []const u8) Error!Stat {
    const handle = try openAttributes(path, false);
    defer windows.CloseHandle(handle);
    var basic: win.FileBasicInfo = undefined;
    if (win.GetFileInformationByHandleEx(handle, win.file_basic_info, &basic, @sizeOf(win.FileBasicInfo)) == .FALSE) return queryError(win.GetLastError());
    var standard: win.FileStandardInfo = undefined;
    if (win.GetFileInformationByHandleEx(handle, win.file_standard_info, &standard, @sizeOf(win.FileStandardInfo)) == .FALSE) return queryError(win.GetLastError());
    return .{
        .size = @intCast(@max(standard.end_of_file, 0)),
        .mtime_ns = toNs(basic.last_write_time),
        .ctime_ns = toNs(basic.change_time),
        .kind = try kindOf(handle, basic.file_attributes),
    };
}

pub fn readFileAlloc(gpa: Allocator, path: []const u8, max_bytes: usize) ReadError![]u8 {
    var wide: WidePath = undefined;
    const name = try toWide(&wide, path);
    const handle = open(name, win.generic_read, win.file_attribute_normal) catch |err| return if (err == error.AccessDenied and isDirectory(name)) error.IsDir else err;
    defer windows.CloseHandle(handle);
    var size: i64 = 0;
    if (win.GetFileSizeEx(handle, &size) == .FALSE) return error.InputOutput;
    const expected = std.math.cast(usize, @max(size, 0)) orelse return error.StreamTooLong;
    if (expected > max_bytes) return error.StreamTooLong;
    var bytes = try std.ArrayList(u8).initCapacity(gpa, expected +| 1);
    errdefer bytes.deinit(gpa);
    while (true) {
        if (bytes.items.len == bytes.capacity) try bytes.ensureUnusedCapacity(gpa, grow_bytes);
        const room = bytes.unusedCapacitySlice();
        const want: windows.DWORD = @intCast(@min(room.len, std.math.maxInt(windows.DWORD)));
        var got: windows.DWORD = 0;
        if (win.ReadFile(handle, room.ptr, want, &got, null) == .FALSE) return readError(win.GetLastError());
        if (got == 0) break;
        bytes.items.len += got;
        if (bytes.items.len > max_bytes) return error.StreamTooLong;
    }
    return bytes.toOwnedSlice(gpa);
}

const grow_bytes: usize = 64 * 1024;

fn open(path: [*:0]const u16, access: windows.DWORD, flags: windows.DWORD) Error!windows.HANDLE {
    const handle = win.CreateFileW(path, access, win.file_share_all, null, win.open_existing, flags, null);
    if (handle == windows.INVALID_HANDLE_VALUE) return openError(win.GetLastError());
    return handle;
}

fn isDirectory(name: [*:0]const u16) bool {
    const attributes = win.GetFileAttributesW(name);
    return attributes != win.invalid_file_attributes and attributes & win.file_attribute_directory != 0;
}

fn kindOf(handle: windows.HANDLE, attributes: windows.DWORD) Error!Kind {
    if (attributes & win.file_attribute_reparse_point != 0) {
        var tag: win.FileAttributeTagInfo = undefined;
        if (win.GetFileInformationByHandleEx(handle, win.file_attribute_tag_info, &tag, @sizeOf(win.FileAttributeTagInfo)) == .FALSE) return queryError(win.GetLastError());
        if (tag.reparse_tag & win.reparse_tag_name_surrogate != 0) return .link;
    }
    return if (attributes & win.file_attribute_directory != 0) .directory else .file;
}

fn openError(code: windows.DWORD) Error {
    return switch (code) {
        win.error_file_not_found, win.error_path_not_found => error.FileNotFound,
        win.error_sharing_violation, win.error_lock_violation => error.FileBusy,
        win.error_access_denied => error.AccessDenied,
        win.error_invalid_name, win.error_bad_pathname => error.BadPathName,
        win.error_filename_exced_range => error.NameTooLong,
        else => error.Unexpected,
    };
}

fn queryError(code: windows.DWORD) Error {
    return switch (code) {
        win.error_access_denied => error.AccessDenied,
        else => error.Unexpected,
    };
}

fn readError(code: windows.DWORD) ReadError {
    return switch (code) {
        win.error_sharing_violation, win.error_lock_violation => error.FileBusy,
        win.error_access_denied => error.AccessDenied,
        else => error.InputOutput,
    };
}

fn toNs(hns: i64) i64 {
    return @intCast(windows.fromSysTime(hns).nanoseconds);
}

fn toWide(buffer: *WidePath, path: []const u8) Error![*:0]const u16 {
    const prefix = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\");
    const long = path.len >= long_from and std.ascii.isAlphabetic(path[0]) and path[1] == ':';
    const offset: usize = if (long) prefix.len else 0;
    if (offset + path.len >= buffer.len) return error.NameTooLong;
    if (long) @memcpy(buffer[0..prefix.len], prefix);
    const len = std.unicode.wtf8ToWtf16Le(buffer[offset..], path) catch return error.BadPathName;
    for (buffer[offset .. offset + len]) |*unit| {
        if (unit.* == '/') unit.* = '\\';
    }
    buffer[offset + len] = 0;
    return buffer;
}

const long_from: usize = 240;

const win = struct {
    const generic_read: windows.DWORD = 0x80000000;
    const file_read_attributes: windows.DWORD = 0x0080;
    const file_share_all: windows.DWORD = 0x00000007;
    const open_existing: windows.DWORD = 3;
    const file_attribute_normal: windows.DWORD = 0x80;
    const file_flag_backup_semantics: windows.DWORD = 0x02000000;
    const file_flag_open_reparse_point: windows.DWORD = 0x00200000;
    const file_attribute_directory: windows.DWORD = 0x10;
    const file_attribute_reparse_point: windows.DWORD = 0x400;
    const reparse_tag_name_surrogate: windows.DWORD = 0x20000000;
    const invalid_file_attributes: windows.DWORD = 0xFFFFFFFF;
    const file_basic_info: c_int = 0;
    const file_standard_info: c_int = 1;
    const file_attribute_tag_info: c_int = 9;
    const error_file_not_found: windows.DWORD = 2;
    const error_path_not_found: windows.DWORD = 3;
    const error_access_denied: windows.DWORD = 5;
    const error_sharing_violation: windows.DWORD = 32;
    const error_lock_violation: windows.DWORD = 33;
    const error_invalid_name: windows.DWORD = 123;
    const error_bad_pathname: windows.DWORD = 161;
    const error_filename_exced_range: windows.DWORD = 206;

    const FileBasicInfo = extern struct {
        creation_time: i64,
        last_access_time: i64,
        last_write_time: i64,
        change_time: i64,
        file_attributes: windows.DWORD,
    };

    const FileStandardInfo = extern struct {
        allocation_size: i64,
        end_of_file: i64,
        number_of_links: windows.DWORD,
        delete_pending: u8,
        directory: u8,
    };

    const FileAttributeTagInfo = extern struct {
        file_attributes: windows.DWORD,
        reparse_tag: windows.DWORD,
    };

    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: windows.DWORD, share: windows.DWORD, security: ?*anyopaque, disposition: windows.DWORD, flags: windows.DWORD, template: ?windows.HANDLE) callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn GetFileInformationByHandleEx(file: windows.HANDLE, class: c_int, info: *anyopaque, size: windows.DWORD) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetFileSizeEx(file: windows.HANDLE, size: *i64) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn ReadFile(file: windows.HANDLE, buffer: [*]u8, len: windows.DWORD, read: *windows.DWORD, overlapped: ?*anyopaque) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetFileAttributesW(name: [*:0]const u16) callconv(.winapi) windows.DWORD;
    extern "kernel32" fn GetLastError() callconv(.winapi) windows.DWORD;
};

const testing = std.testing;

fn holdWithoutSharing(path: []const u8) !windows.HANDLE {
    var wide: WidePath = undefined;
    const handle = win.CreateFileW(try toWide(&wide, path), win.generic_read, 0, null, win.open_existing, win.file_attribute_normal, null);
    if (handle == windows.INVALID_HANDLE_VALUE) return openError(win.GetLastError());
    return handle;
}

fn awakeNs() i96 {
    return std.Io.Clock.awake.now(testing.io).nanoseconds;
}

test "open nowait: a file another handle holds without sharing is stat-ed and its read is refused as busy, both at once" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "held.txt", .data = "held bytes\n" });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "held.txt", testing.allocator);
    defer testing.allocator.free(path);
    const holder = try holdWithoutSharing(path);
    defer windows.CloseHandle(holder);

    const started = awakeNs();
    const seen = try stat(path);
    try testing.expectError(error.FileBusy, readFileAlloc(testing.allocator, path, 1 << 20));
    const elapsed = awakeNs() - started;
    try testing.expectEqual(@as(u64, 11), seen.size);
    try testing.expectEqual(Kind.file, seen.kind);
    try testing.expect(elapsed < 50 * std.time.ns_per_ms);
}

test "open nowait: stat agrees with std on size, write time and change time and tells a directory from a missing path" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "sub");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "sub/a.ts", .data = "export const a = 1;\n" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const file = try std.fmt.allocPrint(testing.allocator, "{s}/sub/a.ts", .{root});
    defer testing.allocator.free(file);
    const dir = try std.fmt.allocPrint(testing.allocator, "{s}\\sub", .{root});
    defer testing.allocator.free(dir);
    const gone = try std.fmt.allocPrint(testing.allocator, "{s}\\sub\\gone.ts", .{root});
    defer testing.allocator.free(gone);
    const no_parent = try std.fmt.allocPrint(testing.allocator, "{s}\\nodir\\a.ts", .{root});
    defer testing.allocator.free(no_parent);

    const mine = try stat(file);
    const theirs = try tmp.dir.statFile(testing.io, "sub/a.ts", .{});
    try testing.expectEqual(theirs.size, mine.size);
    try testing.expectEqual(@as(i64, @intCast(theirs.mtime.nanoseconds)), mine.mtime_ns);
    try testing.expectEqual(@as(i64, @intCast(theirs.ctime.nanoseconds)), mine.ctime_ns);
    try testing.expectEqual(Kind.file, mine.kind);
    try testing.expectEqual(Kind.directory, (try stat(dir)).kind);
    try testing.expectError(error.IsDir, readFileAlloc(testing.allocator, dir, 100));
    try testing.expectError(error.FileNotFound, stat(gone));
    try testing.expectError(error.FileNotFound, stat(no_parent));
    try testing.expectError(error.FileNotFound, readFileAlloc(testing.allocator, gone, 100));
}

test "open nowait: read returns the whole file, refuses one over the limit and calls a locked range busy" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "ten.txt", .data = "0123456789" });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "ten.txt", testing.allocator);
    defer testing.allocator.free(path);

    const bytes = try readFileAlloc(testing.allocator, path, 10);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("0123456789", bytes);
    try testing.expectError(error.StreamTooLong, readFileAlloc(testing.allocator, path, 9));
    const empty_path = try std.fmt.allocPrint(testing.allocator, "{s}.empty", .{path});
    defer testing.allocator.free(empty_path);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "ten.txt.empty", .data = "" });
    const empty = try readFileAlloc(testing.allocator, empty_path, 10);
    defer testing.allocator.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);

    const locked = try tmp.dir.openFile(testing.io, "ten.txt", .{ .mode = .read_write, .lock = .exclusive });
    defer locked.close(testing.io);
    try testing.expectError(error.FileBusy, readFileAlloc(testing.allocator, path, 10));
}

test "open nowait: a path past the old 260 character limit is stat-ed and read" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const segment = "d" ** 100;
    const sub = segment ++ "/" ++ segment ++ "/" ++ segment;
    try tmp.dir.createDirPath(testing.io, sub);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = sub ++ "/deep.ts", .data = "deep" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}\\{s}/deep.ts", .{ root, sub });
    defer testing.allocator.free(path);
    try testing.expect(path.len > 300);

    try testing.expectEqual(@as(u64, 4), (try stat(path)).size);
    const bytes = try readFileAlloc(testing.allocator, path, 100);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("deep", bytes);
}
