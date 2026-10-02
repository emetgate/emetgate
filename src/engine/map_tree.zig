const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Item = struct {
    path: []const u8,
    weight: u32,
};

pub const Range = struct {
    first: u32,
    count: u32,
    weight: u64,
    dir: []const u8,
    whole: bool,
    first_child: []const u8,
    last_child: []const u8,
    children: u32,
};

pub const Error = Allocator.Error || error{UnsortedItems};

const Child = struct {
    lo: u32,
    hi: u32,
    segment: []const u8,
    is_dir: bool,
};

const Partitioner = struct {
    arena: Allocator,
    items: []const Item,
    prefix: []const u64,
    capacity: u64,
    out: std.ArrayList(Range) = .empty,

    fn weightOf(self: *const Partitioner, lo: u32, hi: u32) u64 {
        return self.prefix[hi] - self.prefix[lo];
    }

    fn childrenOf(self: *Partitioner, dir: []const u8, lo: u32, hi: u32) ![]Child {
        var list: std.ArrayList(Child) = .empty;
        var i = lo;
        while (i < hi) {
            const rest = self.items[i].path[dir.len..];
            const slash = std.mem.indexOfScalar(u8, rest, '/');
            if (slash == null) {
                try list.append(self.arena, .{ .lo = i, .hi = i + 1, .segment = rest, .is_dir = false });
                i += 1;
                continue;
            }
            const segment = rest[0 .. slash.? + 1];
            var j = i + 1;
            while (j < hi and std.mem.startsWith(u8, self.items[j].path[dir.len..], segment)) j += 1;
            try list.append(self.arena, .{ .lo = i, .hi = j, .segment = segment, .is_dir = true });
            i = j;
        }
        return list.items;
    }

    fn emit(self: *Partitioner, dir: []const u8, run: []const Child, whole: bool) !void {
        const lo = run[0].lo;
        const hi = run[run.len - 1].hi;
        try self.out.append(self.arena, .{
            .first = lo,
            .count = hi - lo,
            .weight = self.weightOf(lo, hi),
            .dir = dir,
            .whole = whole,
            .first_child = run[0].segment,
            .last_child = run[run.len - 1].segment,
            .children = @intCast(run.len),
        });
    }

    fn groupsWithin(self: *const Partitioner, run: []const Child, limit: u64) u64 {
        var groups: u64 = 1;
        var weight: u64 = 0;
        for (run) |c| {
            const w = self.weightOf(c.lo, c.hi);
            if (weight != 0 and weight + w > limit) {
                groups += 1;
                weight = 0;
            }
            weight += w;
        }
        return groups;
    }

    fn balancedLimit(self: *const Partitioner, run: []const Child) u64 {
        var total: u64 = 0;
        var largest: u64 = 0;
        for (run) |c| {
            const w = self.weightOf(c.lo, c.hi);
            total += w;
            largest = @max(largest, w);
        }
        const groups = self.groupsWithin(run, self.capacity);
        var low = @max(largest, std.math.divCeil(u64, total, groups) catch unreachable);
        var high = self.capacity;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (self.groupsWithin(run, mid) <= groups) high = mid else low = mid + 1;
        }
        return low;
    }

    fn flush(self: *Partitioner, dir: []const u8, run: []const Child, all: usize) !void {
        if (run.len == 0) return;
        const limit = self.balancedLimit(run);
        var start: usize = 0;
        var weight: u64 = 0;
        var made: usize = 0;
        for (run, 0..) |c, i| {
            const w = self.weightOf(c.lo, c.hi);
            if (i > start and weight + w > limit) {
                try self.emit(dir, run[start..i], false);
                made += 1;
                start = i;
                weight = 0;
            }
            weight += w;
        }
        try self.emit(dir, run[start..], made == 0 and run.len == all);
    }

    fn split(self: *Partitioner, dir: []const u8, lo: u32, hi: u32) Error!void {
        const children = try self.childrenOf(dir, lo, hi);
        var run: std.ArrayList(Child) = .empty;
        for (children) |c| {
            if (self.weightOf(c.lo, c.hi) <= self.capacity) {
                try run.append(self.arena, c);
                continue;
            }
            try self.flush(dir, run.items, children.len);
            run.clearRetainingCapacity();
            if (c.is_dir) {
                try self.node(try std.mem.concat(self.arena, u8, &.{ dir, c.segment }), c.lo, c.hi);
            } else {
                try self.emit(dir, &.{c}, false);
            }
        }
        try self.flush(dir, run.items, children.len);
    }

    fn node(self: *Partitioner, dir: []const u8, lo: u32, hi: u32) Error!void {
        if (self.weightOf(lo, hi) <= self.capacity) {
            const children = try self.childrenOf(dir, lo, hi);
            try self.emit(dir, children, true);
            return;
        }
        const children = try self.childrenOf(dir, lo, hi);
        if (children.len == 1 and children[0].is_dir) {
            const sub = try std.mem.concat(self.arena, u8, &.{ dir, children[0].segment });
            return self.node(sub, lo, hi);
        }
        return self.split(dir, lo, hi);
    }
};

pub fn partition(arena: Allocator, items: []const Item, capacity: u64) Error![]Range {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        if (std.mem.order(u8, items[i - 1].path, items[i].path) != .lt) return error.UnsortedItems;
    }
    if (items.len == 0) return &.{};
    const prefix = try arena.alloc(u64, items.len + 1);
    prefix[0] = 0;
    for (items, 0..) |item, k| prefix[k + 1] = prefix[k] + item.weight;
    var p: Partitioner = .{ .arena = arena, .items = items, .prefix = prefix, .capacity = @max(capacity, 1) };
    try p.node("", 0, @intCast(items.len));
    return p.out.items;
}

pub fn commonDir(a: []const u8, b: []const u8) []const u8 {
    const n = @min(a.len, b.len);
    var last: usize = 0;
    var k: usize = 0;
    while (k < n and a[k] == b[k]) : (k += 1) {
        if (a[k] == '/') last = k + 1;
    }
    return a[0..last];
}

const testing = std.testing;

fn itemsOf(comptime spec: []const struct { []const u8, u32 }) [spec.len]Item {
    var out: [spec.len]Item = undefined;
    for (spec, 0..) |s, k| out[k] = .{ .path = s[0], .weight = s[1] };
    return out;
}

fn expectCovers(items: []const Item, ranges: []const Range) !void {
    var next: u32 = 0;
    for (ranges) |r| {
        try testing.expectEqual(next, r.first);
        try testing.expect(r.count > 0);
        next = r.first + r.count;
    }
    try testing.expectEqual(@as(u32, @intCast(items.len)), next);
}

test "map tree: a tree that fits the capacity is one region over every item" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const items = itemsOf(&.{ .{ "a/x.ts", 10 }, .{ "a/y.ts", 10 }, .{ "b.ts", 5 } });
    const ranges = try partition(arena_state.allocator(), &items, 100);
    try testing.expectEqual(@as(usize, 1), ranges.len);
    try testing.expect(ranges[0].whole);
    try testing.expectEqualStrings("", ranges[0].dir);
    try expectCovers(&items, ranges);
}

test "map tree: every item lands in exactly one contiguous region and no region over capacity holds more than one item" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const items = itemsOf(&.{
        .{ "pkg/a/one.ts", 40 },  .{ "pkg/a/two.ts", 40 },   .{ "pkg/a/z/deep.ts", 30 }, .{ "pkg/b.ts", 10 },
        .{ "pkg/big.ts", 500 },   .{ "pkg/c/one.ts", 20 },   .{ "pkg/c/two.ts", 20 },    .{ "pkg/d.ts", 5 },
        .{ "pkg/e/f/g/h.ts", 90 }, .{ "pkg/e/f/g/i.ts", 90 }, .{ "top.ts", 1 },
    });
    const ranges = try partition(arena_state.allocator(), &items, 100);
    try expectCovers(&items, ranges);
    for (ranges) |r| {
        if (r.weight > 100) try testing.expectEqual(@as(u32, 1), r.count);
        for (items[r.first .. r.first + r.count]) |item| try testing.expect(std.mem.startsWith(u8, item.path, r.dir));
    }
}

test "map tree: a lone chain of directories is entered without making empty levels" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const items = itemsOf(&.{ .{ "a/b/c/x.ts", 60 }, .{ "a/b/c/y.ts", 60 } });
    const ranges = try partition(arena_state.allocator(), &items, 100);
    try testing.expectEqual(@as(usize, 2), ranges.len);
    try testing.expectEqualStrings("a/b/c/", ranges[0].dir);
    try testing.expectEqualStrings("a/b/c/", ranges[1].dir);
    try expectCovers(&items, ranges);
}

test "map tree: small siblings are packed into balanced groups instead of one full group and a tiny tail" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const items = itemsOf(&.{ .{ "d/a.ts", 30 }, .{ "d/b.ts", 30 }, .{ "d/c.ts", 30 }, .{ "d/e.ts", 30 }, .{ "d/f.ts", 10 } });
    const ranges = try partition(arena_state.allocator(), &items, 100);
    try testing.expectEqual(@as(usize, 2), ranges.len);
    try testing.expect(ranges[0].weight >= 60 and ranges[1].weight >= 60);
    try expectCovers(&items, ranges);
}

test "map tree: the partition is a pure function of the sorted items" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng = std.Random.DefaultPrng.init(42);
    var paths: std.ArrayList([]const u8) = .empty;
    for (0..300) |k| {
        const r = prng.random();
        try paths.append(arena, try std.fmt.allocPrint(arena, "p{d}/d{d}/f{d}_{d}.ts", .{ r.uintLessThan(u8, 4), r.uintLessThan(u8, 9), r.uintLessThan(u16, 50), k }));
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    const items = try arena.alloc(Item, paths.items.len);
    for (paths.items, items, 0..) |p, *item, k| item.* = .{ .path = p, .weight = @intCast(5 + (k * 37) % 60) };
    const one = try partition(arena, items, 400);
    const two = try partition(arena, items, 400);
    try testing.expectEqual(one.len, two.len);
    for (one, two) |a, b| {
        try testing.expectEqual(a.first, b.first);
        try testing.expectEqual(a.count, b.count);
        try testing.expectEqualStrings(a.dir, b.dir);
    }
    try expectCovers(items, one);
    for (one) |r| try testing.expect(r.weight <= 400 or r.count == 1);
}

test "map tree: unsorted or repeated paths are refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const unsorted = itemsOf(&.{ .{ "b.ts", 1 }, .{ "a.ts", 1 } });
    try testing.expectError(error.UnsortedItems, partition(arena_state.allocator(), &unsorted, 10));
    const repeated = itemsOf(&.{ .{ "a.ts", 1 }, .{ "a.ts", 1 } });
    try testing.expectError(error.UnsortedItems, partition(arena_state.allocator(), &repeated, 10));
}

test "map tree: the common directory of two paths ends at a slash" {
    try testing.expectEqualStrings("a/b/", commonDir("a/b/c.ts", "a/b/d/e.ts"));
    try testing.expectEqualStrings("", commonDir("ab.ts", "ac.ts"));
    try testing.expectEqualStrings("a/", commonDir("a/bc.ts", "a/bd.ts"));
}
