const std = @import("std");
const sandbox = @import("sandbox.zig");
const shadow_root = @import("shadow_root.zig");
const symbol = @import("../engine/symbol.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

pub const max_indexed_file_bytes: usize = 1 * 1024 * 1024;
const max_index_file_bytes: usize = 64 * 1024 * 1024;

pub const Stamp = struct {
    mtime_ns: i96,
    size: u64,
};

pub const Entry = struct {
    path: []const u8,
    stamp: Stamp,
    trigrams: []const u24,
};

pub const Index = struct {
    arena: *std.heap.ArenaAllocator,
    entries: []Entry,

    pub fn deinit(self: Index) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self.arena);
    }

    pub fn find(self: Index, path: []const u8) ?*const Entry {
        for (self.entries) |*entry| {
            if (std.mem.eql(u8, entry.path, path)) return entry;
        }
        return null;
    }
};

pub fn indexPath(gpa: Allocator, root_abs: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const local = (try sandbox.environmentValue(arena_state.allocator(), std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA"))) orelse return error.LocalAppDataUnavailable;
    const key = shadow_root.repoKey(root_abs);
    return std.fmt.allocPrint(gpa, "{s}\\emetgate\\index\\{s}\\index.v1", .{ local, &key });
}

fn statOf(io: std.Io, abs_path: []const u8) ?Stamp {
    const stat = Dir.cwd().statFile(io, abs_path, .{}) catch return null;
    return .{ .mtime_ns = stat.mtime.nanoseconds, .size = stat.size };
}

fn looksBinary(bytes: []const u8) bool {
    return std.mem.indexOfScalar(u8, bytes, 0) != null;
}

pub fn trigramsOfAlloc(gpa: Allocator, text: []const u8) ![]u24 {
    var set: std.AutoArrayHashMapUnmanaged(u24, void) = .empty;
    defer set.deinit(gpa);
    if (text.len >= 3) {
        var i: usize = 0;
        while (i + 3 <= text.len) : (i += 1) {
            const t: u24 = (@as(u24, text[i]) << 16) | (@as(u24, text[i + 1]) << 8) | text[i + 2];
            try set.put(gpa, t, {});
        }
    }
    const owned = try gpa.dupe(u24, set.keys());
    std.mem.sort(u24, owned, {}, std.sort.asc(u24));
    return owned;
}

pub fn isSupersetSorted(haystack: []const u24, needles: []const u24) bool {
    var hi: usize = 0;
    for (needles) |needle| {
        while (hi < haystack.len and haystack[hi] < needle) hi += 1;
        if (hi >= haystack.len or haystack[hi] != needle) return false;
    }
    return true;
}

pub fn build(gpa: Allocator, io: std.Io, root_abs: []const u8, files: []const []const u8) !Index {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var entries: std.ArrayList(Entry) = .empty;
    for (files) |rel| {
        const abs = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ root_abs, rel });
        defer gpa.free(abs);
        const stamp = statOf(io, abs) orelse continue;
        if (stamp.size > max_indexed_file_bytes) continue;
        const bytes = Dir.cwd().readFileAlloc(io, abs, gpa, .limited(max_indexed_file_bytes)) catch continue;
        defer gpa.free(bytes);
        if (looksBinary(bytes)) continue;
        const trigrams = try trigramsOfAlloc(gpa, bytes);
        defer gpa.free(trigrams);
        try entries.append(a, .{
            .path = try a.dupe(u8, rel),
            .stamp = stamp,
            .trigrams = try a.dupe(u24, trigrams),
        });
    }
    return .{ .arena = arena, .entries = try entries.toOwnedSlice(a) };
}

pub fn refresh(gpa: Allocator, io: std.Io, root_abs: []const u8, files: []const []const u8, previous: ?Index) !Index {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var entries: std.ArrayList(Entry) = .empty;
    for (files) |rel| {
        const abs = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ root_abs, rel });
        defer gpa.free(abs);
        const stamp = statOf(io, abs) orelse continue;
        if (stamp.size > max_indexed_file_bytes) continue;

        if (previous) |p| {
            if (p.find(rel)) |old| {
                if (old.stamp.mtime_ns == stamp.mtime_ns and old.stamp.size == stamp.size) {
                    try entries.append(a, .{
                        .path = try a.dupe(u8, rel),
                        .stamp = stamp,
                        .trigrams = try a.dupe(u24, old.trigrams),
                    });
                    continue;
                }
            }
        }

        const bytes = Dir.cwd().readFileAlloc(io, abs, gpa, .limited(max_indexed_file_bytes)) catch continue;
        defer gpa.free(bytes);
        if (looksBinary(bytes)) continue;
        const trigrams = try trigramsOfAlloc(gpa, bytes);
        defer gpa.free(trigrams);
        try entries.append(a, .{
            .path = try a.dupe(u8, rel),
            .stamp = stamp,
            .trigrams = try a.dupe(u24, trigrams),
        });
    }
    return .{ .arena = arena, .entries = try entries.toOwnedSlice(a) };
}

pub fn save(gpa: Allocator, io: std.Io, path: []const u8, index: Index) !void {
    if (std.fs.path.dirname(path)) |dir| try Dir.cwd().createDirPath(io, dir);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("emetgate-search-index v1\n");
    for (index.entries) |entry| {
        try w.print("F {x} {d} ", .{ entry.stamp.mtime_ns, entry.stamp.size });
        for (entry.trigrams, 0..) |t, i| {
            if (i != 0) try w.writeByte(':');
            try w.print("{x:0>6}", .{t});
        }
        try w.print(" {s}\n", .{entry.path});
    }
    const hash = symbol.hashOf(out.written());
    try w.print("C {s}\n", .{&symbol.formatHash(hash)});

    try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() });
}

pub fn load(gpa: Allocator, io: std.Io, path: []const u8) !?Index {
    const bytes = Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_index_file_bytes)) catch return null;
    defer gpa.free(bytes);
    return parse(gpa, bytes) catch null;
}

fn parse(gpa: Allocator, bytes: []const u8) !?Index {
    const checksum_marker = "\nC ";
    const at = std.mem.lastIndexOf(u8, bytes, checksum_marker) orelse return null;
    const body = bytes[0 .. at + 1];
    const claimed_hex = std.mem.trimEnd(u8, bytes[at + checksum_marker.len ..], "\r\n");
    const claimed = symbol.parseHash(claimed_hex) catch return null;
    const actual = symbol.hashOf(body);
    if (!std.mem.eql(u8, &actual, &claimed)) return null;

    var lines = std.mem.splitScalar(u8, body, '\n');
    const header = lines.next() orelse return null;
    if (!std.mem.eql(u8, header, "emetgate-search-index v1")) return null;

    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var entries: std.ArrayList(Entry) = .empty;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (line[0] != 'F') return null;
        var fields = std.mem.splitScalar(u8, line[2..], ' ');
        const mtime_text = fields.next() orelse return null;
        const size_text = fields.next() orelse return null;
        const trigram_text = fields.next() orelse return null;
        const path = fields.rest();
        if (path.len == 0) return null;

        const mtime_ns = std.fmt.parseInt(i96, mtime_text, 16) catch return null;
        const size = std.fmt.parseInt(u64, size_text, 10) catch return null;

        var trigrams: std.ArrayList(u24) = .empty;
        if (!std.mem.eql(u8, trigram_text, "")) {
            var parts = std.mem.splitScalar(u8, trigram_text, ':');
            while (parts.next()) |part| {
                const t = std.fmt.parseInt(u24, part, 16) catch return null;
                try trigrams.append(a, t);
            }
        }
        try entries.append(a, .{
            .path = try a.dupe(u8, path),
            .stamp = .{ .mtime_ns = mtime_ns, .size = size },
            .trigrams = try trigrams.toOwnedSlice(a),
        });
    }
    return Index{ .arena = arena, .entries = try entries.toOwnedSlice(a) };
}

const testing = std.testing;

test "build then save then load round-trips the same entries" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export const value = 1;\n" });
    const root_abs = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root_abs);

    const built = try build(testing.allocator, testing.io, root_abs, &.{"a.ts"});
    defer built.deinit();
    try testing.expectEqual(@as(usize, 1), built.entries.len);

    const path = try std.fmt.allocPrint(testing.allocator, "{s}\\idx", .{root_abs});
    defer testing.allocator.free(path);
    try save(testing.allocator, testing.io, path, built);

    const loaded = (try load(testing.allocator, testing.io, path)) orelse return error.TestUnexpectedResult;
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 1), loaded.entries.len);
    try testing.expectEqualStrings("a.ts", loaded.entries[0].path);
    try testing.expectEqual(built.entries[0].stamp.size, loaded.entries[0].stamp.size);
    try testing.expectEqualSlices(u24, built.entries[0].trigrams, loaded.entries[0].trigrams);
}

test "a corrupted index file is rejected instead of trusted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export const value = 1;\n" });
    const root_abs = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root_abs);

    const built = try build(testing.allocator, testing.io, root_abs, &.{"a.ts"});
    defer built.deinit();

    const path = try std.fmt.allocPrint(testing.allocator, "{s}\\idx", .{root_abs});
    defer testing.allocator.free(path);
    try save(testing.allocator, testing.io, path, built);

    const original = try tmp.dir.readFileAlloc(testing.io, "idx", testing.allocator, .unlimited);
    defer testing.allocator.free(original);
    const tampered = try testing.allocator.dupe(u8, original);
    defer testing.allocator.free(tampered);
    tampered[10] = tampered[10] +% 1;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "idx", .data = tampered });

    const loaded = try load(testing.allocator, testing.io, path);
    try testing.expect(loaded == null);
}

test "isSupersetSorted matches a subset regardless of order in the query" {
    const haystack = [_]u24{ 1, 5, 9, 20 };
    try testing.expect(isSupersetSorted(&haystack, &.{ 5, 9 }));
    try testing.expect(!isSupersetSorted(&haystack, &.{ 5, 6 }));
    try testing.expect(isSupersetSorted(&haystack, &.{}));
}

test "trigramsOfAlloc is empty for text shorter than three bytes" {
    const empty = try trigramsOfAlloc(testing.allocator, "ab");
    defer testing.allocator.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);

    const one = try trigramsOfAlloc(testing.allocator, "abcabc");
    defer testing.allocator.free(one);
    try testing.expectEqual(@as(usize, 3), one.len);
}

test "refresh reuses unchanged entries and recomputes a file that changed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export const value = 1;\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.ts", .data = "export const other = 2;\n" });
    const root_abs = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root_abs);

    const first = try build(testing.allocator, testing.io, root_abs, &.{ "a.ts", "b.ts" });
    defer first.deinit();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export const value = 999999;\n" });

    const second = try refresh(testing.allocator, testing.io, root_abs, &.{ "a.ts", "b.ts" }, first);
    defer second.deinit();

    const a_entry = second.find("a.ts").?;
    const b_entry = second.find("b.ts").?;
    try testing.expect(!std.mem.eql(u24, a_entry.trigrams, first.find("a.ts").?.trigrams));
    try testing.expectEqualSlices(u24, first.find("b.ts").?.trigrams, b_entry.trigrams);
}
