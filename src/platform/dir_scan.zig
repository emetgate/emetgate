const std = @import("std");
const builtin = @import("builtin");

const windows = std.os.windows;
const Handle = windows.HANDLE;

pub const Id = [16]u8;
pub const buffer_bytes = 64 * 1024;
pub const max_name_units = 255;
pub const Buffer = [buffer_bytes]u8;

pub const Kind = enum { file, directory, link_file, link_directory };

pub const Entry = struct {
    name: []const u16,
    id: Id,
    kind: Kind,
};

pub const Error = error{ ScanFailed, ScanIsLink, ScanBusy, ScanDenied, NameTooLong, InvalidWtf8, Unsupported };

pub fn openRoot(dir_abs: []const u8) Error!?Handle {
    if (builtin.os.tag != .windows) return error.Unsupported;
    var wide: [std.fs.max_path_bytes:0]u16 = undefined;
    const prefix = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\");
    const use_prefix = std.fs.path.isAbsolute(dir_abs) and !std.mem.startsWith(u8, dir_abs, "\\\\");
    const offset: usize = if (use_prefix) prefix.len else 0;
    if (use_prefix) @memcpy(wide[0..prefix.len], prefix);
    const len = std.unicode.wtf8ToWtf16Le(wide[offset..], dir_abs) catch return error.InvalidWtf8;
    if (offset + len >= wide.len) return error.NameTooLong;
    for (wide[offset .. offset + len]) |*unit| {
        if (unit.* == '/') unit.* = '\\';
    }
    wide[offset + len] = 0;
    const handle = win.CreateFileW(&wide, dir_access, share_all, null, win.open_existing, win.flag_backup_semantics | win.flag_open_reparse_point, null);
    if (handle == windows.INVALID_HANDLE_VALUE) return switch (win.GetLastError()) {
        win.error_file_not_found, win.error_path_not_found => null,
        win.error_sharing_violation => error.ScanBusy,
        win.error_access_denied => error.ScanDenied,
        else => error.ScanFailed,
    };
    errdefer close(handle);
    if (!try plainDirectory(handle)) return error.ScanIsLink;
    return handle;
}

pub fn openChild(parent: Handle, name: []const u16) Error!?Handle {
    if (builtin.os.tag != .windows) return error.Unsupported;
    var handle: Handle = undefined;
    const status = openRelative(parent, name, dir_access, win.file_open, win.option_directory | win.option_open_reparse_point | win.option_sync, &handle);
    switch (status) {
        win.status_success => {},
        win.status_name_not_found, win.status_path_not_found => return null,
        win.status_not_a_directory => return error.ScanIsLink,
        win.status_sharing_violation => return error.ScanBusy,
        win.status_access_denied => return error.ScanDenied,
        else => return error.ScanFailed,
    }
    errdefer close(handle);
    if (!try plainDirectory(handle)) return error.ScanIsLink;
    return handle;
}

pub fn close(handle: Handle) void {
    windows.CloseHandle(handle);
}

pub fn openRelative(parent: Handle, name: []const u16, access: u32, disposition: u32, options: u32, out: *Handle) u32 {
    var unicode: win.UnicodeString = .{
        .length = @intCast(name.len * 2),
        .maximum_length = @intCast(name.len * 2),
        .buffer = name.ptr,
    };
    var attributes: win.ObjectAttributes = .{
        .length = @sizeOf(win.ObjectAttributes),
        .root_directory = parent,
        .object_name = &unicode,
        .attributes = win.obj_case_insensitive,
        .security_descriptor = null,
        .security_qos = null,
    };
    var iosb: win.IoStatusBlock = undefined;
    return win.NtCreateFile(out, access, &attributes, &iosb, null, win.file_attribute_normal, share_all, disposition, options, null, 0);
}

fn plainDirectory(handle: Handle) Error!bool {
    var info: win.ByHandleFileInformation = undefined;
    if (win.GetFileInformationByHandle(handle, &info) == .FALSE) return error.ScanFailed;
    if (info.file_attributes & win.file_attribute_reparse_point != 0) return false;
    return info.file_attributes & win.file_attribute_directory != 0;
}

pub fn idOf(handle: Handle) Error!Id {
    var info: win.FileIdInfo = undefined;
    if (win.GetFileInformationByHandleEx(handle, win.file_id_info, &info, @sizeOf(win.FileIdInfo)) == .FALSE) return error.ScanFailed;
    return info.file_id;
}

pub fn supportsHardLinks(handle: Handle) Error!bool {
    var flags: u32 = 0;
    if (win.GetVolumeInformationByHandleW(handle, null, 0, null, null, &flags, null, 0) == .FALSE) return error.ScanFailed;
    return flags & win.file_supports_hard_links != 0;
}

pub fn volumeOf(handle: Handle) Error!u64 {
    var info: win.FileIdInfo = undefined;
    if (win.GetFileInformationByHandleEx(handle, win.file_id_info, &info, @sizeOf(win.FileIdInfo)) == .FALSE) return error.ScanFailed;
    return info.volume_serial;
}

pub const Reader = struct {
    handle: Handle,
    buffer: *align(8) Buffer,
    offset: usize = 0,
    filled: bool = false,
    restart: bool = true,
    finished: bool = false,

    pub fn init(handle: Handle, buffer: *align(8) Buffer) Reader {
        return .{ .handle = handle, .buffer = buffer };
    }

    pub fn next(self: *Reader) Error!?Entry {
        while (true) {
            if (self.finished) return null;
            if (!self.filled) {
                var iosb: win.IoStatusBlock = undefined;
                const status = win.NtQueryDirectoryFile(self.handle, null, null, null, &iosb, self.buffer, buffer_bytes, win.class_id_extd_directory, 0, null, @intFromBool(self.restart));
                self.restart = false;
                switch (status) {
                    win.status_success => {},
                    win.status_no_more_files, win.status_no_such_file => {
                        self.finished = true;
                        return null;
                    },
                    else => return error.ScanFailed,
                }
                self.filled = true;
                self.offset = 0;
            }
            const base = self.buffer[self.offset..];
            const next_offset = std.mem.readInt(u32, base[0..4], .little);
            const attributes = std.mem.readInt(u32, base[56..60], .little);
            const name_bytes = std.mem.readInt(u32, base[60..64], .little);
            const name_ptr: [*]const u16 = @ptrCast(@alignCast(base[win.extd_name_offset..].ptr));
            const name = name_ptr[0 .. name_bytes / 2];
            var entry: Entry = .{ .name = name, .id = undefined, .kind = kindOf(attributes) };
            @memcpy(&entry.id, base[72..88]);
            if (next_offset == 0) self.filled = false else self.offset += next_offset;
            if (isDot(name)) continue;
            return entry;
        }
    }
};

pub fn kindOf(attributes: u32) Kind {
    const directory = attributes & win.file_attribute_directory != 0;
    if (attributes & win.file_attribute_reparse_point != 0) return if (directory) .link_directory else .link_file;
    return if (directory) .directory else .file;
}

fn isDot(name: []const u16) bool {
    if (name.len == 1) return name[0] == '.';
    if (name.len == 2) return name[0] == '.' and name[1] == '.';
    return false;
}

const dir_access: u32 = win.file_list_directory | win.file_read_attributes | win.synchronize;
const share_all: u32 = 0x7;

pub const win = struct {
    pub const file_list_directory: u32 = 0x0001;
    pub const file_add_file: u32 = 0x0002;
    pub const file_add_subdirectory: u32 = 0x0004;
    pub const file_traverse: u32 = 0x0020;
    pub const file_delete_child: u32 = 0x0040;
    pub const file_read_attributes: u32 = 0x0080;
    pub const file_write_attributes: u32 = 0x0100;
    pub const delete: u32 = 0x00010000;
    pub const read_control: u32 = 0x00020000;
    pub const synchronize: u32 = 0x00100000;
    pub const generic_read: u32 = 0x80000000;
    pub const generic_write: u32 = 0x40000000;

    pub const file_open: u32 = 1;
    pub const file_create: u32 = 2;
    pub const option_directory: u32 = 0x00000001;
    pub const option_sync: u32 = 0x00000020;
    pub const option_non_directory: u32 = 0x00000040;
    pub const option_open_reparse_point: u32 = 0x00200000;
    pub const obj_case_insensitive: u32 = 0x40;

    pub const file_attribute_directory: u32 = 0x10;
    pub const file_attribute_normal: u32 = 0x80;
    pub const file_attribute_reparse_point: u32 = 0x400;

    pub const status_success: u32 = 0;
    pub const status_no_more_files: u32 = 0x80000006;
    pub const status_no_such_file: u32 = 0xC000000F;
    pub const status_access_denied: u32 = 0xC0000022;
    pub const status_name_not_found: u32 = 0xC0000034;
    pub const status_name_collision: u32 = 0xC0000035;
    pub const status_path_not_found: u32 = 0xC000003A;
    pub const status_sharing_violation: u32 = 0xC0000043;
    pub const status_file_is_a_directory: u32 = 0xC00000BA;
    pub const status_not_same_device: u32 = 0xC00000D4;
    pub const status_directory_not_empty: u32 = 0xC0000101;
    pub const status_not_a_directory: u32 = 0xC0000103;
    pub const status_too_many_links: u32 = 0xC0000265;
    pub const status_not_supported: u32 = 0xC00000BB;
    pub const status_invalid_device_request: u32 = 0xC0000010;

    const class_id_extd_directory: u32 = 60;
    const file_supports_hard_links: u32 = 0x00400000;
    const extd_name_offset = 88;
    const file_id_info: u32 = 18;
    const open_existing: u32 = 3;
    const flag_backup_semantics: u32 = 0x02000000;
    const flag_open_reparse_point: u32 = 0x00200000;
    const error_file_not_found: u32 = 2;
    const error_path_not_found: u32 = 3;
    const error_access_denied: u32 = 5;
    const error_sharing_violation: u32 = 32;

    pub const UnicodeString = extern struct {
        length: u16,
        maximum_length: u16,
        buffer: [*]const u16,
    };

    pub const ObjectAttributes = extern struct {
        length: u32,
        root_directory: ?Handle,
        object_name: *UnicodeString,
        attributes: u32,
        security_descriptor: ?*anyopaque,
        security_qos: ?*anyopaque,
    };

    pub const IoStatusBlock = extern struct {
        status: usize,
        information: usize,
    };

    const ByHandleFileInformation = extern struct {
        file_attributes: u32,
        creation_time: u64 align(4),
        last_access_time: u64 align(4),
        last_write_time: u64 align(4),
        volume_serial: u32,
        size_high: u32,
        size_low: u32,
        links: u32,
        index_high: u32,
        index_low: u32,
    };

    const FileIdInfo = extern struct {
        volume_serial: u64,
        file_id: Id,
    };

    pub extern "ntdll" fn NtCreateFile(handle: *Handle, access: u32, attributes: *ObjectAttributes, iosb: *IoStatusBlock, allocation: ?*i64, file_attributes: u32, share: u32, disposition: u32, options: u32, ea: ?*anyopaque, ea_length: u32) callconv(.winapi) u32;
    extern "ntdll" fn NtQueryDirectoryFile(handle: Handle, event: ?Handle, apc: ?*anyopaque, apc_context: ?*anyopaque, iosb: *IoStatusBlock, info: *anyopaque, length: u32, class: u32, single: u8, name: ?*UnicodeString, restart: u8) callconv(.winapi) u32;
    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, disposition: u32, flags: u32, template: ?Handle) callconv(.winapi) Handle;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
    extern "kernel32" fn GetVolumeInformationByHandleW(handle: Handle, name: ?[*]u16, name_size: u32, serial: ?*u32, component: ?*u32, flags: ?*u32, system: ?[*]u16, system_size: u32) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetFileInformationByHandle(handle: Handle, info: *ByHandleFileInformation) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetFileInformationByHandleEx(handle: Handle, class: u32, info: *anyopaque, size: u32) callconv(.winapi) windows.BOOL;
};

const testing = std.testing;
const Dir = std.Io.Dir;

const test_win = struct {
    extern "kernel32" fn CreateHardLinkW(new_name: [*:0]const u16, existing: [*:0]const u16, security: ?*anyopaque) callconv(.winapi) windows.BOOL;
};

fn hardLinkAbsolute(existing_abs: []const u8, new_abs: []const u8) !void {
    var existing_w: [std.fs.max_path_bytes:0]u16 = undefined;
    var new_w: [std.fs.max_path_bytes:0]u16 = undefined;
    existing_w[try std.unicode.wtf8ToWtf16Le(&existing_w, existing_abs)] = 0;
    new_w[try std.unicode.wtf8ToWtf16Le(&new_w, new_abs)] = 0;
    if (test_win.CreateHardLinkW(&new_w, &existing_w, null) == .FALSE) return error.TestHardLinkFailed;
}

fn utf16(comptime text: []const u8) []const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(text);
}

const Seen = struct {
    names: [16][64]u8 = undefined,
    lens: [16]usize = undefined,
    kinds: [16]Kind = undefined,
    ids: [16]Id = undefined,
    count: usize = 0,

    fn collect(handle: Handle) !Seen {
        var seen: Seen = .{};
        var buffer: Buffer align(8) = undefined;
        var reader = Reader.init(handle, &buffer);
        while (try reader.next()) |entry| {
            seen.lens[seen.count] = std.unicode.wtf16LeToWtf8(&seen.names[seen.count], entry.name);
            seen.kinds[seen.count] = entry.kind;
            seen.ids[seen.count] = entry.id;
            seen.count += 1;
        }
        return seen;
    }

    fn find(self: *const Seen, name: []const u8) ?usize {
        for (0..self.count) |i| {
            if (std.mem.eql(u8, self.names[i][0..self.lens[i]], name)) return i;
        }
        return null;
    }
};

test "a directory scan reports every name with its kind and file id, and two hard links share one id" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const shadow = @import("shadow.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "root/sub");
    try tmp.dir.createDirPath(testing.io, "outside");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "root/a.txt", .data = "a\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "root/b.txt", .data = "b\n" });
    const top = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(top);
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    try hardLinkAbsolute(try std.fmt.bufPrint(&target_buf, "{s}\\root\\a.txt", .{top}), try std.fmt.bufPrint(&link_buf, "{s}\\root\\a2.txt", .{top}));
    try shadow.createJunction(testing.io, try std.fmt.bufPrint(&link_buf, "{s}\\root\\jump", .{top}), try std.fmt.bufPrint(&target_buf, "{s}\\outside", .{top}));

    const root = (try openRoot(try std.fmt.bufPrint(&root_buf, "{s}\\root", .{top}))).?;
    defer close(root);
    const seen = try Seen.collect(root);
    try testing.expectEqual(@as(usize, 5), seen.count);
    try testing.expectEqual(Kind.file, seen.kinds[seen.find("a.txt").?]);
    try testing.expectEqual(Kind.directory, seen.kinds[seen.find("sub").?]);
    try testing.expectEqual(Kind.link_directory, seen.kinds[seen.find("jump").?]);
    try testing.expectEqualSlices(u8, &seen.ids[seen.find("a.txt").?], &seen.ids[seen.find("a2.txt").?]);
    try testing.expect(!std.mem.eql(u8, &seen.ids[seen.find("a.txt").?], &seen.ids[seen.find("b.txt").?]));

    const sub = (try openChild(root, utf16("sub"))).?;
    defer close(sub);
    try testing.expectEqualSlices(u8, &seen.ids[seen.find("sub").?], &(try idOf(sub)));
    try testing.expectEqual(@as(usize, 0), (try Seen.collect(sub)).count);
}

test "a junction is never opened as a directory, at the root or below it" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const shadow = @import("shadow.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "root");
    try tmp.dir.createDirPath(testing.io, "outside");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "outside/secret.txt", .data = "secret\n" });
    const top = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(top);
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const outside = try std.fmt.bufPrint(&target_buf, "{s}\\outside", .{top});
    try shadow.createJunction(testing.io, try std.fmt.bufPrint(&link_buf, "{s}\\root\\jump", .{top}), outside);
    const root = (try openRoot(try std.fmt.bufPrint(&root_buf, "{s}\\root", .{top}))).?;
    defer close(root);
    try testing.expectError(error.ScanIsLink, openChild(root, utf16("jump")));
    try testing.expectError(error.ScanIsLink, openRoot(try std.fmt.bufPrint(&link_buf, "{s}\\root\\jump", .{top})));
    try testing.expectEqual(@as(?Handle, null), try openChild(root, utf16("missing")));
    try testing.expectEqual(@as(?Handle, null), try openRoot(try std.fmt.bufPrint(&link_buf, "{s}\\gone", .{top})));
}

test "a directory with more names than one buffer holds is read to the end" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "root");
    var name_buf: [160]u8 = undefined;
    const filler = "x" ** 120;
    const total = 900;
    for (0..total) |i| {
        try tmp.dir.writeFile(testing.io, .{ .sub_path = try std.fmt.bufPrint(&name_buf, "root/{d:0>5}-{s}.txt", .{ i, filler }), .data = "" });
    }
    const top = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(top);
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = (try openRoot(try std.fmt.bufPrint(&root_buf, "{s}\\root", .{top}))).?;
    defer close(root);
    var buffer: Buffer align(8) = undefined;
    var reader = Reader.init(root, &buffer);
    var count: usize = 0;
    while (try reader.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, total), count);
}
