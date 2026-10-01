const std = @import("std");

const Allocator = std.mem.Allocator;

pub const max_index_bytes = 256 * 1024 * 1024;

pub fn readTracked(gpa: Allocator, io: std.Io, index_path: []const u8) !?[][]u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, index_path, gpa, .limited(max_index_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer gpa.free(bytes);
    return parse(gpa, bytes);
}

pub fn parse(gpa: Allocator, bytes: []const u8) !?[][]u8 {
    const hash_len = trailerLen(bytes) orelse return null;
    const body = bytes[0 .. bytes.len - hash_len];
    if (body.len < 12 or !std.mem.eql(u8, body[0..4], "DIRC")) return null;
    const version = std.mem.readInt(u32, body[4..8], .big);
    if (version < 2 or version > 4) return null;
    const count = std.mem.readInt(u32, body[8..12], .big);

    var names: std.ArrayList([]u8) = .empty;
    var handed_over = false;
    defer if (!handed_over) {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    };
    var previous: std.ArrayList(u8) = .empty;
    defer previous.deinit(gpa);
    var pos: usize = 12;
    const fixed = 40 + hash_len;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const start = pos;
        if (body.len < pos + fixed + 2) return null;
        const mode = std.mem.readInt(u32, body[pos + 24 ..][0..4], .big);
        pos += fixed;
        const flags = std.mem.readInt(u16, body[pos..][0..2], .big);
        pos += 2;
        if (flags & 0x4000 != 0) {
            if (version < 3 or body.len < pos + 2) return null;
            pos += 2;
        }
        var name: []const u8 = undefined;
        if (version == 4) {
            var strip: usize = 0;
            if (pos >= body.len) return null;
            var byte = body[pos];
            pos += 1;
            strip = byte & 0x7f;
            while (byte & 0x80 != 0) {
                if (pos >= body.len) return null;
                byte = body[pos];
                pos += 1;
                strip = ((strip + 1) << 7) | (byte & 0x7f);
                if (strip > body.len) return null;
            }
            if (strip > previous.items.len) return null;
            const end = std.mem.indexOfScalarPos(u8, body, pos, 0) orelse return null;
            previous.shrinkRetainingCapacity(previous.items.len - strip);
            try previous.appendSlice(gpa, body[pos..end]);
            pos = end + 1;
            name = previous.items;
        } else {
            const end = std.mem.indexOfScalarPos(u8, body, pos, 0) orelse return null;
            name = body[pos..end];
            const entry_len = (end - start + 8) & ~@as(usize, 7);
            pos = start + entry_len;
            if (pos > body.len) return null;
        }
        if (name.len == 0 or name[name.len - 1] == '/') return null;
        if (mode & 0o170000 == 0o160000) continue;
        if (names.items.len != 0 and std.mem.eql(u8, names.items[names.items.len - 1], name)) continue;
        try names.append(gpa, try gpa.dupe(u8, name));
    }
    while (pos < body.len) {
        if (body.len < pos + 8) return null;
        const signature = body[pos..][0..4];
        const size = std.mem.readInt(u32, body[pos + 4 ..][0..4], .big);
        if (std.mem.eql(u8, signature, "link") or std.mem.eql(u8, signature, "sdir")) return null;
        if (body.len - pos - 8 < size) return null;
        pos += 8 + size;
    }
    const out = try names.toOwnedSlice(gpa);
    handed_over = true;
    return out;
}

fn trailerLen(bytes: []const u8) ?usize {
    if (bytes.len > 20) {
        var sha1: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(bytes[0 .. bytes.len - 20], &sha1, .{});
        if (std.mem.eql(u8, &sha1, bytes[bytes.len - 20 ..])) return 20;
    }
    if (bytes.len > 32) {
        var sha256: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes[0 .. bytes.len - 32], &sha256, .{});
        if (std.mem.eql(u8, &sha256, bytes[bytes.len - 32 ..])) return 32;
    }
    return null;
}

pub fn freeList(gpa: Allocator, names: [][]u8) void {
    for (names) |n| gpa.free(n);
    gpa.free(names);
}

const testing = std.testing;

fn buildIndex(gpa: Allocator, name: []const u8, extension: ?[]const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "DIRC");
    try out.appendSlice(gpa, &.{ 0, 0, 0, 2, 0, 0, 0, 1 });
    const start = out.items.len;
    try out.appendNTimes(gpa, 0, 40 + 20);
    try out.appendSlice(gpa, &.{ 0, @intCast(name.len) });
    try out.appendSlice(gpa, name);
    const entry_len = (out.items.len - start + 8) & ~@as(usize, 7);
    try out.appendNTimes(gpa, 0, start + entry_len - out.items.len);
    if (extension) |sig| {
        try out.appendSlice(gpa, sig);
        try out.appendSlice(gpa, &.{ 0, 0, 0, 20 });
        try out.appendNTimes(gpa, 0, 20);
    }
    var sum: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(out.items, &sum, .{});
    try out.appendSlice(gpa, &sum);
    return out.toOwnedSlice(gpa);
}

const Entry = struct { name: []const u8, mode: u32 = 0o100644, stage: u16 = 0 };

fn buildEntries(gpa: Allocator, entries: []const Entry) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "DIRC");
    var header: [8]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], 2, .big);
    std.mem.writeInt(u32, header[4..8], @intCast(entries.len), .big);
    try out.appendSlice(gpa, &header);
    for (entries) |e| {
        const start = out.items.len;
        try out.appendNTimes(gpa, 0, 40 + 20);
        std.mem.writeInt(u32, out.items[start + 24 ..][0..4], e.mode, .big);
        var flags: [2]u8 = undefined;
        std.mem.writeInt(u16, &flags, (e.stage << 12) | @as(u16, @intCast(e.name.len)), .big);
        try out.appendSlice(gpa, &flags);
        try out.appendSlice(gpa, e.name);
        const entry_len = (out.items.len - start + 8) & ~@as(usize, 7);
        try out.appendNTimes(gpa, 0, start + entry_len - out.items.len);
    }
    var sum: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(out.items, &sum, .{});
    try out.appendSlice(gpa, &sum);
    return out.toOwnedSlice(gpa);
}

test "a conflicted path is listed once and a submodule entry is not listed as a file" {
    const bytes = try buildEntries(testing.allocator, &.{
        .{ .name = "a.ts", .stage = 1 },
        .{ .name = "a.ts", .stage = 2 },
        .{ .name = "a.ts", .stage = 3 },
        .{ .name = "lib", .mode = 0o160000 },
        .{ .name = "link", .mode = 0o120000 },
        .{ .name = "z.ts", .mode = 0o100755 },
    });
    defer testing.allocator.free(bytes);
    const names = (try parse(testing.allocator, bytes)) orelse return error.NotRead;
    defer freeList(testing.allocator, names);
    try testing.expectEqual(@as(usize, 3), names.len);
    try testing.expectEqualStrings("a.ts", names[0]);
    try testing.expectEqualStrings("link", names[1]);
    try testing.expectEqualStrings("z.ts", names[2]);
}

test "an index whose entries live partly in a shared index is not read as the whole list" {
    const plain = try buildIndex(testing.allocator, "a.ts", null);
    defer testing.allocator.free(plain);
    const names = (try parse(testing.allocator, plain)) orelse return error.NotRead;
    defer freeList(testing.allocator, names);
    try testing.expectEqualStrings("a.ts", names[0]);

    for ([_][]const u8{ "link", "sdir" }) |sig| {
        const split = try buildIndex(testing.allocator, "a.ts", sig);
        defer testing.allocator.free(split);
        try testing.expect((try parse(testing.allocator, split)) == null);
    }
    const other = try buildIndex(testing.allocator, "a.ts", "TREE");
    defer testing.allocator.free(other);
    const kept = (try parse(testing.allocator, other)) orelse return error.NotRead;
    defer freeList(testing.allocator, kept);
    try testing.expectEqual(@as(usize, 1), kept.len);
}
