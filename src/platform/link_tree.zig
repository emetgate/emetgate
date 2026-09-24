const std = @import("std");
const builtin = @import("builtin");

const Dir = std.Io.Dir;

pub const Stats = struct {
    dirs: usize = 0,
    linked: usize = 0,
    copied: usize = 0,
    skipped_links: usize = 0,
};

pub const Error = error{ LinkTreeFailed, LinkTreeUnsupported, NameTooLong, InvalidWtf8 };

pub fn build(io: std.Io, source_abs: []const u8, dest_abs: []const u8, stats: *Stats) !void {
    if (builtin.os.tag != .windows) return error.LinkTreeUnsupported;
    var source = Dir.openDirAbsolute(io, source_abs, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => return placeFile(io, source_abs, dest_abs, stats),
        else => |e| return e,
    };
    defer source.close(io);
    try Dir.cwd().createDirPath(io, dest_abs);
    stats.dirs += 1;

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var pending: std.ArrayList([]const u8) = .empty;
    try pending.append(arena, "");
    while (pending.pop()) |rel| {
        var dir = if (rel.len == 0) source else try source.openDir(io, rel, .{ .iterate = true, .follow_symlinks = false });
        defer if (rel.len != 0) dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            const child = if (rel.len == 0) try arena.dupe(u8, entry.name) else try std.fmt.allocPrint(arena, "{s}\\{s}", .{ rel, entry.name });
            switch (entry.kind) {
                .directory => {
                    const dest_child = try std.fmt.allocPrint(arena, "{s}\\{s}", .{ dest_abs, child });
                    try Dir.cwd().createDirPath(io, dest_child);
                    stats.dirs += 1;
                    try pending.append(arena, child);
                },
                .file => {
                    var source_buf: [std.fs.max_path_bytes]u8 = undefined;
                    var dest_buf: [std.fs.max_path_bytes]u8 = undefined;
                    const source_path = try std.fmt.bufPrint(&source_buf, "{s}\\{s}", .{ source_abs, child });
                    const dest_path = try std.fmt.bufPrint(&dest_buf, "{s}\\{s}", .{ dest_abs, child });
                    try placeFile(io, source_path, dest_path, stats);
                },
                else => stats.skipped_links += 1,
            }
        }
    }
}

fn placeFile(io: std.Io, source_path: []const u8, dest_path: []const u8, stats: *Stats) !void {
    var source_w: [std.fs.max_path_bytes:0]u16 = undefined;
    var dest_w: [std.fs.max_path_bytes:0]u16 = undefined;
    const source_wide = try toExtendedWide(&source_w, source_path);
    const dest_wide = try toExtendedWide(&dest_w, dest_path);

    if (try lowWriteBlocked(source_wide)) {
        if (win.CreateHardLinkW(dest_wide, source_wide, null) != .FALSE) {
            stats.linked += 1;
            return;
        }
        switch (win.GetLastError()) {
            win.error_not_same_device, win.error_too_many_links, win.error_invalid_function, win.error_not_supported => {},
            else => return error.LinkTreeFailed,
        }
    }
    Dir.copyFileAbsolute(source_path, dest_path, io, .{}) catch return error.LinkTreeFailed;
    stats.copied += 1;
}

pub fn lowWriteBlocked(path: [*:0]const u16) error{LinkTreeFailed}!bool {
    var buffer: [4096]u8 align(8) = undefined;
    var needed: std.os.windows.DWORD = 0;
    if (win.GetFileSecurityW(path, win.label_security_information, &buffer, buffer.len, &needed) == .FALSE) return error.LinkTreeFailed;

    var present: std.os.windows.BOOL = .FALSE;
    var defaulted: std.os.windows.BOOL = .FALSE;
    var sacl: ?[*]const u8 = null;
    if (win.GetSecurityDescriptorSacl(&buffer, &present, &sacl, &defaulted) == .FALSE) return error.LinkTreeFailed;
    const acl = sacl orelse return true;
    if (present == .FALSE) return true;
    return labelBlocksLowWrite(acl);
}

pub fn labelBlocksLowWrite(acl: [*]const u8) bool {
    const size = std.mem.readInt(u16, acl[2..4], .little);
    const count = std.mem.readInt(u16, acl[4..6], .little);
    var offset: usize = 8;
    var index: usize = 0;
    while (index < count and offset + 8 <= size) : (index += 1) {
        const ace = acl + offset;
        const ace_type = ace[0];
        const ace_flags = ace[1];
        const ace_size = std.mem.readInt(u16, ace[2..4], .little);
        if (ace_size < 8) return false;
        defer offset += ace_size;
        if (ace_type != system_mandatory_label_ace_type) continue;
        if (ace_flags & inherit_only_ace != 0) continue;
        const mask = std.mem.readInt(u32, ace[4..8], .little);
        const sid = ace + 8;
        const sub_count = sid[1];
        if (sub_count == 0 or 8 + 8 + @as(usize, sub_count) * 4 > ace_size) return false;
        const rid_at = 8 + (@as(usize, sub_count) - 1) * 4;
        const rid = std.mem.readInt(u32, sid[rid_at..][0..4], .little);
        return rid > low_integrity_rid and mask & no_write_up != 0;
    }
    return true;
}

const system_mandatory_label_ace_type: u8 = 0x11;
const inherit_only_ace: u8 = 0x08;
const no_write_up: u32 = 0x1;
const low_integrity_rid: u32 = 0x1000;

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

const win = struct {
    const windows = std.os.windows;
    const label_security_information: windows.DWORD = 0x00000010;
    const error_invalid_function: windows.DWORD = 1;
    const error_not_same_device: windows.DWORD = 17;
    const error_not_supported: windows.DWORD = 50;
    const error_too_many_links: windows.DWORD = 1142;

    extern "kernel32" fn CreateHardLinkW(new_name: [*:0]const u16, existing: [*:0]const u16, security: ?*anyopaque) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetLastError() callconv(.winapi) windows.DWORD;
    extern "advapi32" fn GetFileSecurityW(name: [*:0]const u16, info: windows.DWORD, descriptor: *anyopaque, length: windows.DWORD, needed: *windows.DWORD) callconv(.winapi) windows.BOOL;
    extern "advapi32" fn GetSecurityDescriptorSacl(descriptor: *anyopaque, present: *windows.BOOL, sacl: *?[*]const u8, defaulted: *windows.BOOL) callconv(.winapi) windows.BOOL;
};

const testing = std.testing;

fn labelAcl(comptime rid: u32, comptime mask: u32, comptime flags: u8) [28]u8 {
    var acl: [28]u8 = @splat(0);
    acl[0] = 2;
    std.mem.writeInt(u16, acl[2..4], acl.len, .little);
    std.mem.writeInt(u16, acl[4..6], 1, .little);
    acl[8] = system_mandatory_label_ace_type;
    acl[9] = flags;
    std.mem.writeInt(u16, acl[10..12], 20, .little);
    std.mem.writeInt(u32, acl[12..16], mask, .little);
    acl[16] = 1;
    acl[17] = 1;
    acl[23] = 16;
    std.mem.writeInt(u32, acl[24..28], rid, .little);
    return acl;
}

test "a mandatory label blocks low writes only at medium or above with no-write-up" {
    var empty: [8]u8 = @splat(0);
    empty[0] = 2;
    std.mem.writeInt(u16, empty[2..4], empty.len, .little);
    try testing.expect(labelBlocksLowWrite(&empty));
    try testing.expect(labelBlocksLowWrite(&labelAcl(0x2000, no_write_up, 0)));
    try testing.expect(labelBlocksLowWrite(&labelAcl(0x3000, no_write_up, 0)));
    try testing.expect(!labelBlocksLowWrite(&labelAcl(0x1000, no_write_up, 0)));
    try testing.expect(!labelBlocksLowWrite(&labelAcl(0x2000, 0, 0)));
    try testing.expect(labelBlocksLowWrite(&labelAcl(0x1000, no_write_up, inherit_only_ace)));
}

const Tree = struct {
    tmp: testing.TmpDir,
    top_abs: [:0]u8,
    source_abs: []u8,
    dest_abs: []u8,

    fn init() !Tree {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "source/sub");
        try tmp.dir.createDirPath(testing.io, "outside");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "source/a.txt", .data = "a\n" });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "source/sub/b.txt", .data = "b\n" });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "outside/secret.txt", .data = "secret\n" });
        const top_abs = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        errdefer testing.allocator.free(top_abs);
        const source_abs = try std.fmt.allocPrint(testing.allocator, "{s}\\source", .{top_abs});
        errdefer testing.allocator.free(source_abs);
        const dest_abs = try std.fmt.allocPrint(testing.allocator, "{s}\\dest", .{top_abs});
        return .{ .tmp = tmp, .top_abs = top_abs, .source_abs = source_abs, .dest_abs = dest_abs };
    }

    fn deinit(self: *Tree) void {
        testing.allocator.free(self.dest_abs);
        testing.allocator.free(self.source_abs);
        testing.allocator.free(self.top_abs);
        self.tmp.cleanup();
    }

    fn expectContent(self: *Tree, sub_path: []const u8, expected: []const u8) !void {
        const actual = try self.tmp.dir.readFileAlloc(testing.io, sub_path, testing.allocator, .unlimited);
        defer testing.allocator.free(actual);
        try testing.expectEqualStrings(expected, actual);
    }
};

test "build hardlinks every file, recreates every directory and never follows a reparse point" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const shadow = @import("shadow.zig");
    var tree = try Tree.init();
    defer tree.deinit();
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    try shadow.createJunction(testing.io, try std.fmt.bufPrint(&link_buf, "{s}\\escape", .{tree.source_abs}), try std.fmt.bufPrint(&target_buf, "{s}\\outside", .{tree.top_abs}));

    var stats: Stats = .{};
    try build(testing.io, tree.source_abs, tree.dest_abs, &stats);
    try testing.expectEqual(Stats{ .dirs = 2, .linked = 2, .skipped_links = 1 }, stats);
    try tree.expectContent("dest/a.txt", "a\n");
    try tree.expectContent("dest/sub/b.txt", "b\n");
    try testing.expectError(error.FileNotFound, tree.tmp.dir.access(testing.io, "dest/escape", .{}));

    try tree.tmp.dir.writeFile(testing.io, .{ .sub_path = "source/sub/b.txt", .data = "shared\n" });
    try tree.expectContent("dest/sub/b.txt", "shared\n");
}

test "a file whose label lets a low-integrity process write is copied, never linked" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const shadow = @import("shadow.zig");
    var tree = try Tree.init();
    defer tree.deinit();
    var weak_buf: [std.fs.max_path_bytes]u8 = undefined;
    try shadow.grantLowIntegrityWrite(try std.fmt.bufPrint(&weak_buf, "{s}\\a.txt", .{tree.source_abs}));

    var stats: Stats = .{};
    try build(testing.io, tree.source_abs, tree.dest_abs, &stats);
    try testing.expectEqual(Stats{ .dirs = 2, .linked = 1, .copied = 1 }, stats);
    try tree.tmp.dir.writeFile(testing.io, .{ .sub_path = "source/a.txt", .data = "changed\n" });
    try tree.expectContent("dest/a.txt", "a\n");
}
