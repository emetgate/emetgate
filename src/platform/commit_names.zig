const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

pub const Name = struct {
    path: []const u8,
    directory: bool = false,
};

pub const Clash = struct {
    first: []const u8,
    second: []const u8,
};

const Slot = struct {
    index: u32,
    directory: bool,
};

const slash: u16 = '/';

fn upper(unit: u16) u16 {
    if (builtin.os.tag == .windows) return RtlUpcaseUnicodeChar(unit);
    return if (unit < 128) std.ascii.toUpper(@intCast(unit)) else unit;
}

extern "ntdll" fn RtlUpcaseUnicodeChar(unit: u16) callconv(.winapi) u16;

fn folded(arena: Allocator, path: []const u8) Allocator.Error![]u16 {
    const units = std.unicode.utf8ToUtf16LeAlloc(arena, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidUtf8 => widened: {
            const raw = try arena.alloc(u16, path.len);
            for (path, raw) |byte, *unit| unit.* = byte;
            break :widened raw;
        },
    };
    for (units) |*unit| unit.* = upper(unit.*);
    return units;
}

fn sharedDirs(a: []const u16, b: []const u16) usize {
    const limit = @min(a.len, b.len);
    var same: usize = 0;
    var at: usize = 0;
    while (at < limit and a[at] == b[at]) : (at += 1) {
        if (a[at] == slash) same = at + 1;
    }
    return same;
}

pub fn clash(arena: Allocator, names: []const Name) Allocator.Error!?Clash {
    var seen: std.StringHashMapUnmanaged(Slot) = .empty;
    try seen.ensureTotalCapacity(arena, @intCast(names.len * 2));
    var previous: []const u16 = &.{};
    for (names, 0..) |name, index| {
        const key = try folded(arena, name.path);
        var at = sharedDirs(previous, key);
        while (std.mem.indexOfScalarPos(u16, key, at, slash)) |cut| : (at = cut + 1) {
            const entry = try seen.getOrPut(arena, std.mem.sliceAsBytes(key[0..cut]));
            if (!entry.found_existing) {
                entry.value_ptr.* = .{ .index = @intCast(index), .directory = true };
            } else if (!entry.value_ptr.directory) {
                return .{ .first = names[entry.value_ptr.index].path, .second = name.path };
            }
        }
        const entry = try seen.getOrPut(arena, std.mem.sliceAsBytes(key));
        if (!entry.found_existing) {
            entry.value_ptr.* = .{ .index = @intCast(index), .directory = name.directory };
        } else if (!(entry.value_ptr.directory and name.directory)) {
            return .{ .first = names[entry.value_ptr.index].path, .second = name.path };
        }
        previous = key;
    }
    return null;
}

const testing = std.testing;

fn found(names: []const Name) !?Clash {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const hit = (try clash(arena_state.allocator(), names)) orelse return null;
    return hit;
}

test "commit names: two files whose names differ only in letter case are named, in tree order" {
    const hit = (try found(&.{ .{ .path = "pkg/F0000.txt" }, .{ .path = "pkg/a.txt" }, .{ .path = "pkg/f0000.txt" } })).?;
    try testing.expectEqualStrings("pkg/F0000.txt", hit.first);
    try testing.expectEqualStrings("pkg/f0000.txt", hit.second);
}

test "commit names: a file and a directory that differ only in letter case are named" {
    const hit = (try found(&.{ .{ .path = "Docs" }, .{ .path = "docs/readme.md" } })).?;
    try testing.expectEqualStrings("Docs", hit.first);
    try testing.expectEqualStrings("docs/readme.md", hit.second);
    const other = (try found(&.{ .{ .path = "docs/readme.md" }, .{ .path = "src/x.ts" }, .{ .path = "DOCS" } })).?;
    try testing.expectEqualStrings("docs/readme.md", other.first);
    try testing.expectEqualStrings("DOCS", other.second);
}

test "commit names: names that differ in more than case, and two spellings of one directory, are not a clash" {
    try testing.expect((try found(&.{ .{ .path = "a/b.txt" }, .{ .path = "a/b.txt.bak" }, .{ .path = "a/c/b.txt" }, .{ .path = "ab.txt" } })) == null);
    try testing.expect((try found(&.{ .{ .path = "Pkg/one.txt" }, .{ .path = "pkg/two.txt" } })) == null);
    try testing.expect((try found(&.{ .{ .path = "mod", .directory = true }, .{ .path = "mode.txt" } })) == null);
}

test "commit names: letters outside ASCII fold the way the file system folds them" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const hit = (try found(&.{ .{ .path = "src/\xc3\x9cber.ts" }, .{ .path = "src/\xc3\xbcber.ts" } })).?;
    try testing.expectEqualStrings("src/\xc3\x9cber.ts", hit.first);
    try testing.expectEqualStrings("src/\xc3\xbcber.ts", hit.second);
}
