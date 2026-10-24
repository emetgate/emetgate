const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const disk = @import("disk.zig");
const index_file = @import("search_index_file.zig");

const Allocator = std.mem.Allocator;
const WidePath = [std.fs.max_path_bytes:0]u16;

pub const pointer_name = "index.v4";
pub const old_name = "index.v3";
const generation_prefix = "index.v4.";
const tag_len = 16;

pub const Failure = enum { missing, too_large, io, corrupt, version };

pub const Mapped = struct {
    file: windows.HANDLE,
    mapping: windows.HANDLE,
    bytes: []align(std.heap.page_size_min) const u8,

    pub fn close(self: Mapped) void {
        _ = win.UnmapViewOfFile(self.bytes.ptr);
        windows.CloseHandle(self.mapping);
        windows.CloseHandle(self.file);
    }
};

pub const Image = struct {
    view: index_file.View,
    backing: union(enum) { mapped: Mapped, heap: []align(index_file.alignment) u8 },
    generation: [tag_len]u8,

    pub fn deinit(self: Image, gpa: Allocator) void {
        switch (self.backing) {
            .mapped => |m| m.close(),
            .heap => |h| gpa.free(h),
        }
    }
};

pub const Opened = union(enum) { image: Image, failed: Failure };

pub fn open(gpa: Allocator, io: std.Io, dir: []const u8) Opened {
    const tag = readPointer(gpa, io, dir) catch |err| return .{ .failed = switch (err) {
        error.FileNotFound => if (exists(gpa, io, dir, old_name)) .version else .missing,
        error.BadPointer => .corrupt,
        else => .io,
    } };
    const path = generationPath(gpa, dir, &tag) catch return .{ .failed = .io };
    defer gpa.free(path);
    const mapped = mapFile(path) catch |err| return .{ .failed = switch (err) {
        error.FileNotFound, error.Empty => .corrupt,
        error.TooLarge => .too_large,
        else => .io,
    } };
    const bytes: []align(index_file.alignment) const u8 = @alignCast(mapped.bytes);
    const view = index_file.View.open(bytes) catch |err| {
        mapped.close();
        return .{ .failed = switch (err) {
            error.Version => .version,
            error.Corrupt => .corrupt,
        } };
    };
    return .{ .image = .{ .view = view, .backing = .{ .mapped = mapped }, .generation = tag } };
}

pub fn fromHeap(image: []align(index_file.alignment) u8, tag: [tag_len]u8) index_file.OpenError!Image {
    return .{ .view = try index_file.View.open(image), .backing = .{ .heap = image }, .generation = tag };
}

pub fn newTag(io: std.Io) [tag_len]u8 {
    var random: [tag_len / 2]u8 = undefined;
    io.random(&random);
    return std.fmt.bytesToHex(random, .lower);
}

pub fn publish(gpa: Allocator, io: std.Io, dir: []const u8, image: []const u8, tag: [tag_len]u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const final = try generationPath(gpa, dir, &tag);
    defer gpa.free(final);
    const temp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{final});
    defer gpa.free(temp);
    disk.writeDurably(io, temp, image) catch |err| {
        std.Io.Dir.deleteFileAbsolute(io, temp) catch {};
        return err;
    };
    replaceFile(temp, final) catch |err| {
        std.Io.Dir.deleteFileAbsolute(io, temp) catch {};
        return err;
    };
    const pointer = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ dir, pointer_name });
    defer gpa.free(pointer);
    const pointer_temp = try std.fmt.allocPrint(gpa, "{s}\\{s}{s}.tmp", .{ dir, generation_prefix, newTag(io) });
    defer gpa.free(pointer_temp);
    disk.writeDurably(io, pointer_temp, &tag) catch |err| {
        std.Io.Dir.deleteFileAbsolute(io, pointer_temp) catch {};
        return err;
    };
    replaceFile(pointer_temp, pointer) catch |err| {
        std.Io.Dir.deleteFileAbsolute(io, pointer_temp) catch {};
        return err;
    };
    sweep(gpa, io, dir, &tag);
}

pub const sweep_age_ns: i96 = 60 * std.time.ns_per_s;

pub fn sweep(gpa: Allocator, io: std.Io, dir: []const u8, keep: []const u8) void {
    var handle = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
    defer handle.close(io);
    const now = std.Io.Clock.real.now(io).nanoseconds;
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = handle.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const old_version = std.mem.eql(u8, entry.name, old_name);
        const other_generation = std.mem.startsWith(u8, entry.name, generation_prefix) and !std.mem.eql(u8, entry.name[generation_prefix.len..], keep);
        if (!old_version and !other_generation) continue;
        if (other_generation) {
            const stat = handle.statFile(io, entry.name, .{}) catch continue;
            if (now - stat.mtime.nanoseconds < sweep_age_ns) continue;
        }
        const copy = gpa.dupe(u8, entry.name) catch return;
        names.append(gpa, copy) catch {
            gpa.free(copy);
            return;
        };
    }
    for (names.items) |name| handle.deleteFile(io, name) catch {};
}

fn generationPath(gpa: Allocator, dir: []const u8, tag: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}\\{s}{s}", .{ dir, generation_prefix, tag });
}

fn exists(gpa: Allocator, io: std.Io, dir: []const u8, name: []const u8) bool {
    const path = std.fmt.allocPrint(gpa, "{s}\\{s}", .{ dir, name }) catch return false;
    defer gpa.free(path);
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn readPointer(gpa: Allocator, io: std.Io, dir: []const u8) ![tag_len]u8 {
    const path = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ dir, pointer_name });
    defer gpa.free(path);
    var buf: [tag_len + 1]u8 = undefined;
    const text = std.Io.Dir.cwd().readFile(io, path, &buf) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return error.Unreadable,
    };
    if (text.len != tag_len) return error.BadPointer;
    for (text) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return error.BadPointer;
    return text[0..tag_len].*;
}

pub fn mapFile(path: []const u8) !Mapped {
    if (builtin.os.tag != .windows) return error.Unsupported;
    var wide: WidePath = undefined;
    const w = try toWide(&wide, path);
    const file = win.CreateFileW(w, win.generic_read, win.file_share_read | win.file_share_delete, null, win.open_existing, win.file_attribute_normal, null);
    if (file == windows.INVALID_HANDLE_VALUE) {
        return switch (win.GetLastError()) {
            win.error_file_not_found, win.error_path_not_found => error.FileNotFound,
            else => error.Unreadable,
        };
    }
    errdefer windows.CloseHandle(file);
    var size: i64 = 0;
    if (win.GetFileSizeEx(file, &size) == .FALSE) return error.Unreadable;
    if (size <= 0) return error.Empty;
    if (@as(u64, @intCast(size)) > std.math.maxInt(usize)) return error.TooLarge;
    const mapping = win.CreateFileMappingW(file, null, win.page_readonly, 0, 0, null) orelse return error.TooLarge;
    errdefer windows.CloseHandle(mapping);
    const view = win.MapViewOfFile(mapping, win.file_map_read, 0, 0, 0) orelse return error.TooLarge;
    const base: [*]align(std.heap.page_size_min) const u8 = @ptrCast(@alignCast(view));
    return .{ .file = file, .mapping = mapping, .bytes = base[0..@intCast(size)] };
}

fn replaceFile(from: []const u8, to: []const u8) !void {
    var from_wide: WidePath = undefined;
    var to_wide: WidePath = undefined;
    const from_ptr = try toWide(&from_wide, from);
    const to_ptr = try toWide(&to_wide, to);
    if (win.MoveFileExW(from_ptr, to_ptr, win.movefile_replace_existing | win.movefile_write_through) == .FALSE) return error.RenameFailed;
}

fn toWide(buffer: *WidePath, path: []const u8) ![*:0]const u16 {
    const len = std.unicode.wtf8ToWtf16Le(buffer, path) catch return error.InvalidWtf8;
    if (len >= buffer.len) return error.NameTooLong;
    buffer[len] = 0;
    return buffer;
}

const win = struct {
    const generic_read: windows.DWORD = 0x80000000;
    const file_share_read: windows.DWORD = 0x00000001;
    const file_share_delete: windows.DWORD = 0x00000004;
    const open_existing: windows.DWORD = 3;
    const file_attribute_normal: windows.DWORD = 0x80;
    const page_readonly: windows.DWORD = 0x02;
    const file_map_read: windows.DWORD = 0x0004;
    const error_file_not_found: windows.DWORD = 2;
    const error_path_not_found: windows.DWORD = 3;
    const movefile_replace_existing: windows.DWORD = 0x00000001;
    const movefile_write_through: windows.DWORD = 0x00000008;

    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: windows.DWORD, share: windows.DWORD, security: ?*anyopaque, disposition: windows.DWORD, flags: windows.DWORD, template: ?windows.HANDLE) callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn GetFileSizeEx(file: windows.HANDLE, size: *i64) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn CreateFileMappingW(file: windows.HANDLE, security: ?*anyopaque, protect: windows.DWORD, size_high: windows.DWORD, size_low: windows.DWORD, name: ?[*:0]const u16) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn MapViewOfFile(mapping: windows.HANDLE, access: windows.DWORD, offset_high: windows.DWORD, offset_low: windows.DWORD, bytes: usize) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn UnmapViewOfFile(base: *const anyopaque) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn MoveFileExW(from: [*:0]const u16, to: [*:0]const u16, flags: windows.DWORD) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetLastError() callconv(.winapi) windows.DWORD;
};

const testing = std.testing;

test "index map: a published image maps back, the pointer moves to the newest generation and older ones are swept" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    try testing.expectEqual(Opened{ .failed = .missing }, open(testing.allocator, testing.io, dir));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = old_name, .data = "EMGIDX\x00\x03" });
    try testing.expectEqual(Opened{ .failed = .version }, open(testing.allocator, testing.io, dir));

    const inputs = [_]index_file.Input{.{ .path = "a.ts", .stamp = .{ .mtime_ns = 1, .ctime_ns = 1, .size = 3 }, .state = .indexed, .content = "abc" }};
    const first = try index_file.build(testing.allocator, &inputs, .{ .written_ns = 1, .git_stamp = null }, null);
    defer testing.allocator.free(first);
    const tag1 = newTag(testing.io);
    try publish(testing.allocator, testing.io, dir, first, tag1);
    const opened = open(testing.allocator, testing.io, dir);
    const image = switch (opened) {
        .image => |i| i,
        .failed => return error.TestUnexpectedResult,
    };
    try testing.expectEqualStrings("abc", image.view.contentOf(0));
    try testing.expect(!exists(testing.allocator, testing.io, dir, old_name));

    const tag2 = newTag(testing.io);
    try publish(testing.allocator, testing.io, dir, first, tag2);
    image.deinit(testing.allocator);
    const name1 = try std.fmt.allocPrint(testing.allocator, "{s}{s}", .{ generation_prefix, &tag1 });
    defer testing.allocator.free(name1);
    try testing.expect(exists(testing.allocator, testing.io, dir, name1));
    const aged = try tmp.dir.openFile(testing.io, name1, .{ .mode = .read_write });
    try aged.setTimestamps(testing.io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = std.Io.Clock.real.now(testing.io).nanoseconds - 2 * sweep_age_ns } } });
    aged.close(testing.io);
    sweep(testing.allocator, testing.io, dir, &tag2);
    try testing.expect(!exists(testing.allocator, testing.io, dir, name1));
    const reopened = open(testing.allocator, testing.io, dir);
    switch (reopened) {
        .image => |i| {
            defer i.deinit(testing.allocator);
            try testing.expectEqualSlices(u8, &tag2, &i.generation);
        },
        .failed => return error.TestUnexpectedResult,
    }

    try tmp.dir.writeFile(testing.io, .{ .sub_path = pointer_name, .data = "not a tag" });
    try testing.expectEqual(Opened{ .failed = .corrupt }, open(testing.allocator, testing.io, dir));
}
