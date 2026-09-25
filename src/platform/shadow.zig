const std = @import("std");
const builtin = @import("builtin");
const link_tree = @import("link_tree.zig");
const shadow_root = @import("shadow_root.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

pub const workspace_dir = ".emetgate";

const max_git_listing = 64 * 1024 * 1024;

pub fn trackedFiles(gpa: Allocator, io: std.Io, root_abs: []const u8) ![][]u8 {
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "git", "ls-files", "-z" },
        .cwd = .{ .path = root_abs },
        .stdout_limit = .limited(max_git_listing),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitFailed,
        else => return error.GitFailed,
    }

    var files: std.ArrayList([]u8) = .empty;
    errdefer freeFileList(gpa, files.items);
    errdefer files.deinit(gpa);
    var names = std.mem.tokenizeScalar(u8, result.stdout, 0);
    while (names.next()) |name| {
        const copy = try gpa.dupe(u8, name);
        errdefer gpa.free(copy);
        try files.append(gpa, copy);
    }
    return files.toOwnedSlice(gpa);
}

pub fn freeFileList(gpa: Allocator, files: []const []u8) void {
    for (files) |file| gpa.free(file);
}

pub const Lock = struct {
    handle: ?std.os.windows.HANDLE,
    io: std.Io,
    root_abs: []const u8,

    pub fn acquire(io: std.Io, root_abs: []const u8) !Lock {
        if (builtin.os.tag != .windows) return .{ .handle = null, .io = io, .root_abs = root_abs };
        var ws_buf: [std.fs.max_path_bytes]u8 = undefined;
        const workspace = try std.fmt.bufPrint(&ws_buf, "{s}\\{s}", .{ root_abs, workspace_dir });
        Dir.cwd().createDirPath(io, workspace) catch {};
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const lock_path = try std.fmt.bufPrint(&path_buf, "{s}\\.lock", .{workspace});
        var wide: [std.fs.max_path_bytes:0]u16 = undefined;
        const handle = win.CreateFileW(
            try toExtendedWide(&wide, lock_path),
            win.generic_write,
            0,
            null,
            win.open_always,
            win.file_attribute_normal | win.flag_delete_on_close,
            null,
        );
        if (handle == std.os.windows.INVALID_HANDLE_VALUE) {
            return switch (win.GetLastError()) {
                win.error_sharing_violation => error.WorkspaceBusy,
                else => error.WorkspaceLockFailed,
            };
        }
        return .{ .handle = handle, .io = io, .root_abs = root_abs };
    }

    pub fn release(self: Lock) void {
        const handle = self.handle orelse return;
        std.os.windows.CloseHandle(handle);
        var ws_buf: [std.fs.max_path_bytes]u8 = undefined;
        const workspace = std.fmt.bufPrint(&ws_buf, "{s}\\{s}", .{ self.root_abs, workspace_dir }) catch return;
        var journal_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.fmt.bufPrint(&journal_buf, "{s}\\journal", .{workspace})) |journal| {
            Dir.cwd().deleteDir(self.io, journal) catch {};
        } else |_| {}
        Dir.cwd().deleteDir(self.io, workspace) catch {};
    }
};

pub const FileLock = struct {
    handle: ?std.os.windows.HANDLE,

    pub fn acquire(path_abs: []const u8) error{ Busy, LockFailed, NameTooLong, InvalidWtf8, Unsupported }!FileLock {
        if (builtin.os.tag != .windows) return error.Unsupported;
        var wide: [std.fs.max_path_bytes:0]u16 = undefined;
        const handle = win.CreateFileW(
            try toExtendedWide(&wide, path_abs),
            win.generic_write,
            0,
            null,
            win.open_always,
            win.file_attribute_normal | win.flag_delete_on_close,
            null,
        );
        if (handle == std.os.windows.INVALID_HANDLE_VALUE) {
            return switch (win.GetLastError()) {
                win.error_sharing_violation, win.error_access_denied => error.Busy,
                else => error.LockFailed,
            };
        }
        return .{ .handle = handle };
    }

    pub fn release(self: FileLock) void {
        if (self.handle) |handle| std.os.windows.CloseHandle(handle);
    }
};

pub const Shadow = struct {
    io: std.Io,
    dir: Dir,
    linked: []const []const u8,
    link_stats: link_tree.Stats = .{},

    pub const Options = struct {
        root_abs: []const u8,
        base_abs: []const u8,
        shadow_abs: []const u8,
        files: []const []const u8,
        linked: []const []const u8 = &.{},
    };

    pub fn prepare(io: std.Io, options: Options) !Shadow {
        for (options.files) |file| try validateRelative(file);
        for (options.linked) |link| try validateRelative(link);
        try remove(io, options.base_abs, options.shadow_abs);

        var root = try Dir.openDirAbsolute(io, options.root_abs, .{});
        defer root.close(io);
        try Dir.cwd().createDirPath(io, options.shadow_abs);
        try ensureNoLinks(options.base_abs, options.shadow_abs);
        try writeRootMarker(io, options.shadow_abs, options.root_abs);
        try grantLowIntegrityWrite(options.shadow_abs);
        var dir = try Dir.openDirAbsolute(io, options.shadow_abs, .{});
        errdefer dir.close(io);

        for (options.files) |file| {
            if (isUnderAny(file, options.linked)) continue;
            if (std.fs.path.dirname(file)) |parent| try dir.createDirPath(io, parent);
            try root.copyFile(file, dir, file, io, .{});
        }

        var stats: link_tree.Stats = .{};
        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        var target_buf: [std.fs.max_path_bytes]u8 = undefined;
        for (options.linked) |link| {
            root.access(io, link, .{}) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => |e| return e,
            };
            const target = try joinWindows(&target_buf, options.root_abs, link);
            const link_path = try joinWindows(&link_buf, options.shadow_abs, link);
            try link_tree.build(io, target, link_path, &stats);
        }
        return .{ .io = io, .dir = dir, .linked = options.linked, .link_stats = stats };
    }

    pub fn writeFile(self: Shadow, sub_path: []const u8, data: []const u8) !void {
        try validateRelative(sub_path);
        if (isUnderAny(sub_path, self.linked)) return error.UnsafePath;
        if (std.fs.path.dirname(sub_path)) |parent| {
            try self.dir.createDirPath(self.io, parent);
            try self.assertResolvesInside(parent);
        }
        try self.dir.writeFile(self.io, .{ .sub_path = sub_path, .data = data });
    }

    pub fn deleteFile(self: Shadow, sub_path: []const u8) !void {
        try validateRelative(sub_path);
        if (isUnderAny(sub_path, self.linked)) return error.UnsafePath;
        self.dir.deleteFile(self.io, sub_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
    }

    fn assertResolvesInside(self: Shadow, parent: []const u8) !void {
        if (builtin.os.tag != .windows) return;
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        var parent_buf: [std.fs.max_path_bytes]u8 = undefined;
        const root_final = try finalPath(self.dir, &root_buf);

        var parent_dir = self.dir.openDir(self.io, parent, .{}) catch return error.UnsafePath;
        defer parent_dir.close(self.io);
        const parent_final = try finalPath(parent_dir, &parent_buf);

        if (!std.ascii.startsWithIgnoreCase(parent_final, root_final)) return error.UnsafePath;
        const rest = parent_final[root_final.len..];
        if (rest.len != 0 and !isSeparator(rest[0])) return error.UnsafePath;
    }

    pub fn close(self: *Shadow) void {
        self.dir.close(self.io);
        self.* = undefined;
    }
};

pub fn remove(io: std.Io, base_abs: []const u8, shadow_abs: []const u8) !void {
    try ensureInsideWorkspace(base_abs, shadow_abs);
    try ensureNoLinks(base_abs, shadow_abs);
    try Dir.cwd().deleteTree(io, shadow_abs);

    const workspace = std.fs.path.dirname(shadow_abs) orelse return;
    var marker_buf: [std.fs.max_path_bytes]u8 = undefined;
    const marker = std.fmt.bufPrint(&marker_buf, "{s}\\{s}", .{ workspace, shadow_root.marker_name }) catch return;
    Dir.cwd().deleteFile(io, marker) catch {};
    Dir.cwd().deleteDir(io, workspace) catch {};
}

fn writeRootMarker(io: std.Io, shadow_abs: []const u8, root_abs: []const u8) !void {
    const workspace = std.fs.path.dirname(shadow_abs) orelse return error.ShadowOutsideWorkspace;
    var marker_buf: [std.fs.max_path_bytes]u8 = undefined;
    const marker = try std.fmt.bufPrint(&marker_buf, "{s}\\{s}", .{ workspace, shadow_root.marker_name });
    try Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = root_abs });
}

pub fn ensureInsideWorkspace(base_abs: []const u8, shadow_abs: []const u8) error{ShadowOutsideWorkspace}!void {
    if (base_abs.len < 3 or !std.ascii.startsWithIgnoreCase(shadow_abs, base_abs)) return error.ShadowOutsideWorkspace;
    const rest = shadow_abs[base_abs.len..];
    if (rest.len < 2 or !isSeparator(rest[0])) return error.ShadowOutsideWorkspace;
    const inside = rest[1..];
    validateRelative(inside) catch return error.ShadowOutsideWorkspace;
    var segments = std.mem.tokenizeAny(u8, inside, "/\\");
    const first = segments.next() orelse return error.ShadowOutsideWorkspace;
    if (!shadow_root.isKey(first)) return error.ShadowOutsideWorkspace;
    if (segments.next() == null) return error.ShadowOutsideWorkspace;
}

const reserved_devices = [_][]const u8{
    "CON",  "PRN",  "AUX",  "NUL",  "CONIN$", "CONOUT$",
    "COM1", "COM2", "COM3", "COM4", "COM5",   "COM6",
    "COM7", "COM8", "COM9", "LPT1", "LPT2",   "LPT3",
    "LPT4", "LPT5", "LPT6", "LPT7", "LPT8",   "LPT9",
};

pub fn validateRelative(path: []const u8) error{UnsafePath}!void {
    if (path.len == 0 or isSeparator(path[0])) return error.UnsafePath;
    if (std.mem.indexOfScalar(u8, path, ':') != null) return error.UnsafePath;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.UnsafePath;
    var segments = std.mem.tokenizeAny(u8, path, "/\\");
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.UnsafePath;
        if (std.mem.indexOfScalar(u8, segment, '~') != null) return error.UnsafePath;
        const last = segment[segment.len - 1];
        if (last == '.' or last == ' ') return error.UnsafePath;
        if (isReservedDevice(segment)) return error.UnsafePath;
    }
}

fn isReservedDevice(segment: []const u8) bool {
    var base = segment;
    if (std.mem.indexOfScalar(u8, base, '.')) |dot| base = base[0..dot];
    while (base.len > 0 and base[base.len - 1] == ' ') base = base[0 .. base.len - 1];
    for (reserved_devices) |device| {
        if (std.ascii.eqlIgnoreCase(base, device)) return true;
    }
    return false;
}

fn ensureNoLinks(base_abs: []const u8, shadow_abs: []const u8) error{ WorkspaceIsLink, AttributeCheckFailed, NameTooLong, InvalidWtf8 }!void {
    if (builtin.os.tag != .windows) return;
    var index = base_abs.len;
    while (index <= shadow_abs.len) : (index += 1) {
        if (index != shadow_abs.len and !isSeparator(shadow_abs[index])) continue;
        if (try isReparsePoint(shadow_abs[0..index])) return error.WorkspaceIsLink;
    }
}

pub fn grantLowIntegrityWrite(dir_abs: []const u8) error{ LabelFailed, NameTooLong, InvalidWtf8 }!void {
    if (builtin.os.tag != .windows) return;
    var path_w: [std.fs.max_path_bytes:0]u16 = undefined;
    const handle = win.CreateFileW(
        try toExtendedWide(&path_w, dir_abs),
        win.read_control | win.write_owner,
        win.file_share_all,
        null,
        win.open_existing,
        win.flag_backup_semantics | win.flag_open_reparse_point,
        null,
    );
    if (handle == std.os.windows.INVALID_HANDLE_VALUE) return error.LabelFailed;
    defer std.os.windows.CloseHandle(handle);

    var descriptor: ?*anyopaque = null;
    const sddl = std.unicode.utf8ToUtf16LeStringLiteral("S:(ML;OICI;NW;;;LW)");
    if (win.ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, win.sddl_revision_1, &descriptor, null) == .FALSE) return error.LabelFailed;
    defer _ = win.LocalFree(descriptor);

    var present: std.os.windows.BOOL = .FALSE;
    var defaulted: std.os.windows.BOOL = .FALSE;
    var sacl: ?*anyopaque = null;
    if (win.GetSecurityDescriptorSacl(descriptor.?, &present, &sacl, &defaulted) == .FALSE or present == .FALSE) return error.LabelFailed;
    if (win.SetSecurityInfo(handle, win.se_file_object, win.label_security_information, null, null, null, sacl) != 0) return error.LabelFailed;
}

pub fn isReparsePoint(path: []const u8) error{ AttributeCheckFailed, NameTooLong, InvalidWtf8 }!bool {
    var path_w: [std.fs.max_path_bytes:0]u16 = undefined;
    const wide = try toExtendedWide(&path_w, path);
    const attributes = win.GetFileAttributesW(wide);
    if (attributes == win.invalid_file_attributes) return switch (win.GetLastError()) {
        win.error_file_not_found, win.error_path_not_found => false,
        else => error.AttributeCheckFailed,
    };
    return attributes & win.file_attribute_reparse_point != 0;
}

fn toExtendedWide(buffer: *[std.fs.max_path_bytes:0]u16, path: []const u8) error{ NameTooLong, InvalidWtf8 }![*:0]const u16 {
    const prefix = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\");
    const use_prefix = std.fs.path.isAbsolute(path) and !std.mem.startsWith(u8, path, "\\\\");
    const offset = if (use_prefix) prefix.len else 0;
    if (use_prefix) @memcpy(buffer[0..prefix.len], prefix);
    const len = std.unicode.wtf8ToWtf16Le(buffer[offset..], path) catch return error.InvalidWtf8;
    if (offset + len >= buffer.len) return error.NameTooLong;
    buffer[offset + len] = 0;
    return buffer;
}

fn finalPath(dir: Dir, buffer: []u8) error{UnsafePath}![]const u8 {
    var wide: [std.fs.max_path_bytes]u16 = undefined;
    const len = win.GetFinalPathNameByHandleW(dir.handle, &wide, wide.len, 0);
    if (len == 0 or len >= wide.len) return error.UnsafePath;
    const written = std.unicode.wtf16LeToWtf8(buffer, wide[0..len]);
    return buffer[0..written];
}

fn isSeparator(byte: u8) bool {
    return byte == '\\' or byte == '/';
}

fn isUnderAny(file: []const u8, dirs: []const []const u8) bool {
    for (dirs) |dir| {
        if (!std.ascii.startsWithIgnoreCase(file, dir)) continue;
        if (file.len == dir.len or isSeparator(file[dir.len])) return true;
    }
    return false;
}

fn joinWindows(buf: []u8, base: []const u8, relative: []const u8) ![]u8 {
    const joined = try std.fmt.bufPrint(buf, "{s}\\{s}", .{ base, relative });
    std.mem.replaceScalar(u8, joined, '/', '\\');
    return joined;
}

const win = struct {
    const windows = std.os.windows;
    const generic_write: windows.DWORD = 0x40000000;
    const open_existing: windows.DWORD = 3;
    const flag_backup_semantics: windows.DWORD = 0x02000000;
    const flag_open_reparse_point: windows.DWORD = 0x00200000;
    const fsctl_set_reparse_point: windows.DWORD = 0x000900A4;
    const reparse_tag_mount_point: u32 = 0xA0000003;
    const reparse_header_len = 8;
    const mount_point_header_len = 8;
    const invalid_file_attributes: windows.DWORD = 0xFFFFFFFF;
    const file_attribute_reparse_point: windows.DWORD = 0x00000400;
    const file_attribute_normal: windows.DWORD = 0x00000080;
    const flag_delete_on_close: windows.DWORD = 0x04000000;
    const open_always: windows.DWORD = 4;
    const error_file_not_found: windows.DWORD = 2;
    const error_path_not_found: windows.DWORD = 3;
    const error_sharing_violation: windows.DWORD = 32;
    const error_access_denied: windows.DWORD = 5;
    const read_control: windows.DWORD = 0x00020000;
    const write_owner: windows.DWORD = 0x00080000;
    const file_share_all: windows.DWORD = 0x7;
    const sddl_revision_1: windows.DWORD = 1;
    const se_file_object: c_int = 1;
    const label_security_information: windows.DWORD = 0x00000010;

    extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl: [*:0]const u16, revision: windows.DWORD, descriptor: *?*anyopaque, size: ?*windows.DWORD) callconv(.winapi) windows.BOOL;
    extern "advapi32" fn GetSecurityDescriptorSacl(descriptor: *anyopaque, present: *windows.BOOL, sacl: *?*anyopaque, defaulted: *windows.BOOL) callconv(.winapi) windows.BOOL;
    extern "advapi32" fn SetSecurityInfo(handle: windows.HANDLE, object_type: c_int, info: windows.DWORD, owner: ?*anyopaque, group: ?*anyopaque, dacl: ?*anyopaque, sacl: ?*anyopaque) callconv(.winapi) windows.DWORD;
    extern "kernel32" fn LocalFree(memory: ?*anyopaque) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetFileAttributesW(name: [*:0]const u16) callconv(.winapi) windows.DWORD;
    extern "kernel32" fn GetLastError() callconv(.winapi) windows.DWORD;
    extern "kernel32" fn GetFinalPathNameByHandleW(handle: windows.HANDLE, path: [*]u16, count: windows.DWORD, flags: windows.DWORD) callconv(.winapi) windows.DWORD;

    extern "kernel32" fn CreateFileW(
        name: [*:0]const u16,
        access: windows.DWORD,
        share: windows.DWORD,
        security: ?*anyopaque,
        disposition: windows.DWORD,
        flags: windows.DWORD,
        template: ?windows.HANDLE,
    ) callconv(.winapi) windows.HANDLE;

    extern "kernel32" fn DeviceIoControl(
        device: windows.HANDLE,
        code: windows.DWORD,
        in_buffer: ?*const anyopaque,
        in_size: windows.DWORD,
        out_buffer: ?*anyopaque,
        out_size: windows.DWORD,
        returned: ?*windows.DWORD,
        overlapped: ?*anyopaque,
    ) callconv(.winapi) windows.BOOL;
};

pub fn createJunction(io: std.Io, link_abs: []const u8, target_abs: []const u8) !void {
    if (builtin.os.tag != .windows) return error.JunctionUnsupported;

    var link_w: [std.fs.max_path_bytes:0]u16 = undefined;
    const link_len = try std.unicode.wtf8ToWtf16Le(&link_w, link_abs);
    link_w[link_len] = 0;

    const prefix = std.unicode.utf8ToUtf16LeStringLiteral("\\??\\");
    var target_w: [std.fs.max_path_bytes]u16 = undefined;
    const target_len = try std.unicode.wtf8ToWtf16Le(&target_w, target_abs);
    const target = target_w[0..target_len];

    const substitute_bytes = (prefix.len + target.len) * 2;
    const print_bytes = target.len * 2;
    const path_bytes = substitute_bytes + 2 + print_bytes + 2;
    const data_len = win.mount_point_header_len + path_bytes;
    const total_len = win.reparse_header_len + data_len;

    var buffer: [std.os.windows.MAXIMUM_REPARSE_DATA_BUFFER_SIZE]u8 align(4) = @splat(0);
    if (total_len > buffer.len) return error.NameTooLong;
    std.mem.writeInt(u32, buffer[0..4], win.reparse_tag_mount_point, .little);
    std.mem.writeInt(u16, buffer[4..6], @intCast(data_len), .little);
    std.mem.writeInt(u16, buffer[8..10], 0, .little);
    std.mem.writeInt(u16, buffer[10..12], @intCast(substitute_bytes), .little);
    std.mem.writeInt(u16, buffer[12..14], @intCast(substitute_bytes + 2), .little);
    std.mem.writeInt(u16, buffer[14..16], @intCast(print_bytes), .little);
    const paths = buffer[16..][0..path_bytes];
    @memcpy(paths[0 .. prefix.len * 2], std.mem.sliceAsBytes(prefix));
    @memcpy(paths[prefix.len * 2 ..][0 .. target.len * 2], std.mem.sliceAsBytes(target));
    @memcpy(paths[substitute_bytes + 2 ..][0..print_bytes], std.mem.sliceAsBytes(target));

    try Dir.cwd().createDirPath(io, link_abs);
    errdefer Dir.cwd().deleteDir(io, link_abs) catch {};

    const handle = win.CreateFileW(&link_w, win.generic_write, 0, null, win.open_existing, win.flag_backup_semantics | win.flag_open_reparse_point, null);
    if (handle == std.os.windows.INVALID_HANDLE_VALUE) return error.JunctionFailed;
    defer std.os.windows.CloseHandle(handle);

    var returned: std.os.windows.DWORD = 0;
    if (win.DeviceIoControl(handle, win.fsctl_set_reparse_point, &buffer, @intCast(total_len), null, 0, &returned, null) == .FALSE) {
        return error.JunctionFailed;
    }
}

const testing = std.testing;

const Project = struct {
    tmp: testing.TmpDir,
    root_abs: [:0]u8,
    base_abs: []u8,
    shadow_buf: [std.fs.max_path_bytes]u8 = undefined,

    fn init() !Project {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const files = [_]struct { path: []const u8, data: []const u8 }{
            .{ .path = "project/a.ts", .data = "export const a = 1;\n" },
            .{ .path = "project/src/b.ts", .data = "export function b() { return 2; }\n" },
            .{ .path = "project/node_modules/pkg/index.js", .data = "module.exports = 42;\n" },
            .{ .path = "project/untracked.log", .data = "not listed by git\n" },
        };
        for (files) |file| {
            try tmp.dir.createDirPath(testing.io, std.fs.path.dirname(file.path).?);
            try tmp.dir.writeFile(testing.io, .{ .sub_path = file.path, .data = file.data });
        }
        const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "project", testing.allocator);
        errdefer testing.allocator.free(root_abs);
        const top_abs = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        defer testing.allocator.free(top_abs);
        const base_abs = try std.fmt.allocPrint(testing.allocator, "{s}\\shadows", .{top_abs});
        return .{ .tmp = tmp, .root_abs = root_abs, .base_abs = base_abs };
    }

    fn deinit(self: *Project) void {
        testing.allocator.free(self.base_abs);
        testing.allocator.free(self.root_abs);
        self.tmp.cleanup();
    }

    fn shadowPath(self: *Project) ![]const u8 {
        const key = shadow_root.repoKey(self.root_abs);
        return std.fmt.bufPrint(&self.shadow_buf, "{s}\\{s}\\shadow", .{ self.base_abs, &key });
    }

    fn options(self: *Project) !Shadow.Options {
        return .{
            .root_abs = self.root_abs,
            .base_abs = self.base_abs,
            .shadow_abs = try self.shadowPath(),
            .files = &.{ "a.ts", "src/b.ts", "node_modules/pkg/index.js" },
            .linked = &.{ "node_modules", "vendor_missing" },
        };
    }

    fn read(self: *Project, sub_path: []const u8) ![]u8 {
        var root = try Dir.openDirAbsolute(testing.io, self.root_abs, .{});
        defer root.close(testing.io);
        return root.readFileAlloc(testing.io, sub_path, testing.allocator, .unlimited);
    }
};

fn expectFileContent(dir: Dir, sub_path: []const u8, expected: []const u8) !void {
    const actual = try dir.readFileAlloc(testing.io, sub_path, testing.allocator, .unlimited);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

test "prepare copies tracked files, rebuilds heavy directories as hardlink trees and skips missing links" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var project = try Project.init();
    defer project.deinit();

    var shadow = try Shadow.prepare(testing.io, try project.options());
    defer shadow.close();

    try expectFileContent(shadow.dir, "a.ts", "export const a = 1;\n");
    try expectFileContent(shadow.dir, "src/b.ts", "export function b() { return 2; }\n");
    try expectFileContent(shadow.dir, "node_modules/pkg/index.js", "module.exports = 42;\n");
    try testing.expectError(error.FileNotFound, shadow.dir.access(testing.io, "untracked.log", .{}));
    try testing.expectError(error.FileNotFound, shadow.dir.access(testing.io, "vendor_missing", .{}));

    var listing = try shadow.dir.openDir(testing.io, ".", .{ .iterate = true });
    defer listing.close(testing.io);
    var iterator = listing.iterate();
    var saw_tree = false;
    while (try iterator.next(testing.io)) |entry| {
        if (std.mem.eql(u8, entry.name, "node_modules")) {
            try testing.expectEqual(std.Io.File.Kind.directory, entry.kind);
            saw_tree = true;
        }
    }
    try testing.expect(saw_tree);
    try testing.expectEqual(link_tree.Stats{ .dirs = 2, .linked = 1 }, shadow.link_stats);
}

test "writing into the shadow never touches the project" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var project = try Project.init();
    defer project.deinit();

    var shadow = try Shadow.prepare(testing.io, try project.options());
    defer shadow.close();
    try shadow.writeFile("a.ts", "export const a = 999;\n");
    try shadow.writeFile("src/new/c.ts", "export const c = 3;\n");

    try expectFileContent(shadow.dir, "a.ts", "export const a = 999;\n");
    const original = try project.read("a.ts");
    defer testing.allocator.free(original);
    try testing.expectEqualStrings("export const a = 1;\n", original);
    try testing.expectError(error.FileNotFound, project.read("src/new/c.ts"));
}

test "removing the shadow deletes the hardlink tree, never the files it shares" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var project = try Project.init();
    defer project.deinit();

    const options = try project.options();
    var shadow = try Shadow.prepare(testing.io, options);
    shadow.close();
    try remove(testing.io, options.base_abs, options.shadow_abs);

    const survivor = try project.read("node_modules/pkg/index.js");
    defer testing.allocator.free(survivor);
    try testing.expectEqualStrings("module.exports = 42;\n", survivor);
    try testing.expectError(error.FileNotFound, Dir.cwd().access(testing.io, options.shadow_abs, .{}));
}

test "re-preparing replaces a stale shadow completely" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var project = try Project.init();
    defer project.deinit();

    var first = try Shadow.prepare(testing.io, try project.options());
    try first.writeFile("stale.ts", "left over\n");
    try first.writeFile("a.ts", "changed\n");
    first.close();

    var second = try Shadow.prepare(testing.io, try project.options());
    defer second.close();
    try testing.expectError(error.FileNotFound, second.dir.access(testing.io, "stale.ts", .{}));
    try expectFileContent(second.dir, "a.ts", "export const a = 1;\n");
    try expectFileContent(second.dir, "node_modules/pkg/index.js", "module.exports = 42;\n");
}

test "prepare fails instead of carrying on when a stale shadow cannot be removed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var project = try Project.init();
    defer project.deinit();

    const options = try project.options();
    var first = try Shadow.prepare(testing.io, options);
    try first.writeFile("held.ts", "held open\n");
    first.close();
    var held_buf: [std.fs.max_path_bytes]u8 = undefined;
    const held = try FileLock.acquire(try std.fmt.bufPrint(&held_buf, "{s}\\held.ts", .{options.shadow_abs}));

    const direct = remove(testing.io, options.base_abs, options.shadow_abs);
    const second = Shadow.prepare(testing.io, options);
    held.release();
    if (second) |prepared| {
        var leaked = prepared;
        leaked.close();
        return error.TestUnexpectedResult;
    } else |err| {
        const expected = if (direct) |_| return error.TestUnexpectedResult else |e| e;
        try testing.expectEqual(expected, err);
    }
}

test "shadow paths outside <shadow root>\\<repo key>\\ are refused before anything is deleted" {
    const base = "C:\\shadows";
    const key = "0123456789abcdef0123456789abcdef";
    const refused = [_][]const u8{
        "C:\\shadows",
        "C:\\shadows\\",
        "C:\\shadows\\" ++ key,
        "C:\\shadows\\" ++ key ++ "\\",
        "C:\\shadows\\src\\shadow",
        "C:\\shadows\\0123456789ABCDEF0123456789ABCDEF\\shadow",
        "C:\\shadows\\0123456789abcdef0123456789abcde\\shadow",
        "C:\\shadows\\" ++ key ++ "\\..\\..\\work",
        "C:\\shadowsX\\" ++ key ++ "\\shadow",
        "C:\\work\\project\\.emetgate\\shadow",
        "D:\\",
        "C:\\shadows\\" ++ key ++ "\\.",
        "C:\\shadows\\" ++ key ++ "\\ .",
        "C:\\shadows\\" ++ key ++ "\\x::$INDEX_ALLOCATION",
        "C:\\shadows\\" ++ key ++ "\\C:\\x",
        "C:\\shadows\\" ++ key ++ "\\shadow.",
    };
    for (refused) |candidate| {
        errdefer std.debug.print("accepted shadow path: {s}\n", .{candidate});
        try testing.expectError(error.ShadowOutsideWorkspace, ensureInsideWorkspace(base, candidate));
    }
    try ensureInsideWorkspace(base, "C:\\shadows\\" ++ key ++ "\\shadow");
    try ensureInsideWorkspace(base, "c:\\SHADOWS/" ++ key ++ "/shadow/run-1");
}

test "a shadow root or repo workspace that is a junction is refused and the directory it points to is untouched" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    for ([_]bool{ true, false }) |whole_root| {
        var project = try Project.init();
        defer project.deinit();

        try project.tmp.dir.createDirPath(testing.io, "victim/shadow");
        try project.tmp.dir.writeFile(testing.io, .{ .sub_path = "victim/shadow/precious.txt", .data = "keep me\n" });
        const victim_abs = try project.tmp.dir.realPathFileAlloc(testing.io, "victim", testing.allocator);
        defer testing.allocator.free(victim_abs);
        const shadow_abs = try project.shadowPath();
        const link = if (whole_root) project.base_abs else std.fs.path.dirname(shadow_abs).?;
        if (!whole_root) try Dir.cwd().createDirPath(testing.io, project.base_abs);
        try createJunction(testing.io, link, victim_abs);

        try testing.expectError(error.WorkspaceIsLink, Shadow.prepare(testing.io, try project.options()));
        try testing.expectError(error.WorkspaceIsLink, remove(testing.io, project.base_abs, try project.shadowPath()));

        try expectFileContent(project.tmp.dir, "victim/shadow/precious.txt", "keep me\n");
        try testing.expectError(error.FileNotFound, project.tmp.dir.access(testing.io, "victim/shadow/a.ts", .{}));
    }
}

test "writeFile refuses paths that leave the shadow or go through a junction" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var project = try Project.init();
    defer project.deinit();

    var shadow = try Shadow.prepare(testing.io, try project.options());
    defer shadow.close();

    var absolute_buf: [std.fs.max_path_bytes]u8 = undefined;
    const absolute = try std.fmt.bufPrint(&absolute_buf, "{s}\\abs.txt", .{project.root_abs});
    const escapes = [_][]const u8{
        "../../escape.txt",
        "..\\escape.txt",
        "src/../../escape.txt",
        absolute,
        "\\rooted.txt",
        "a.ts:stream",
        "node_modules/pkg/index.js",
        "node_modules",
        "Node_modules/pkg/evil.js",
        "NODE_MODULES/pkg/evil.js",
        "NODE_M~1/pkg/evil.js",
        "src/PROGRA~1/x.ts",
        "nul.ts",
        "CON",
        "src/NUL/x.ts",
        "aux.js",
        "a\x00b.ts",
        "trailing.",
        "",
    };
    for (escapes) |path| {
        errdefer std.debug.print("writeFile accepted: \"{s}\"\n", .{path});
        try testing.expectError(error.UnsafePath, shadow.writeFile(path, "PWNED"));
    }

    const real_dependency = try project.read("node_modules/pkg/index.js");
    defer testing.allocator.free(real_dependency);
    try testing.expectEqualStrings("module.exports = 42;\n", real_dependency);
    try testing.expectError(error.FileNotFound, project.read("abs.txt"));
    try testing.expectError(error.FileNotFound, project.tmp.dir.access(testing.io, "escape.txt", .{}));
    try testing.expectError(error.FileNotFound, project.read("node_modules/pkg/evil.js"));
}

test "prepare refuses unsafe tracked names and link entries before touching the disk" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var project = try Project.init();
    defer project.deinit();

    var options = try project.options();
    options.files = &.{ "a.ts", "../outside.ts" };
    try testing.expectError(error.UnsafePath, Shadow.prepare(testing.io, options));

    options = try project.options();
    options.linked = &.{"..\\..\\outside"};
    try testing.expectError(error.UnsafePath, Shadow.prepare(testing.io, options));

    try testing.expectError(error.FileNotFound, Dir.cwd().access(testing.io, options.shadow_abs, .{}));
}

test "git lists this repository's tracked files" {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try Dir.cwd().realPath(testing.io, &cwd_buf);
    const files = try trackedFiles(testing.allocator, testing.io, cwd_buf[0..cwd_len]);
    defer testing.allocator.free(files);
    defer freeFileList(testing.allocator, files);

    var saw_build = false;
    var saw_root = false;
    for (files) |file| {
        if (std.mem.eql(u8, file, "build.zig")) saw_build = true;
        if (std.mem.eql(u8, file, "src/root.zig")) saw_root = true;
        try testing.expect(!std.mem.startsWith(u8, file, ".zig-cache"));
    }
    try testing.expect(saw_build and saw_root);
}
