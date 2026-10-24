const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Shape = struct {
    count: u32,
    universe: u32,
    low: u6,
    bitmap: bool,

    pub fn of(count: u32, universe: u32) Shape {
        const low = lowBits(count, universe);
        const ef = efWords(count, universe, low);
        return .{ .count = count, .universe = universe, .low = low, .bitmap = bitmapWords(universe) <= ef };
    }

    pub fn words(self: Shape) usize {
        return if (self.bitmap) bitmapWords(self.universe) else efWords(self.count, self.universe, self.low);
    }

    fn lowWords(self: Shape) usize {
        return std.math.divCeil(usize, @as(usize, self.count) * self.low, 64) catch unreachable;
    }
};

fn lowBits(count: u32, universe: u32) u6 {
    if (count == 0 or universe <= count) return 0;
    return @intCast(std.math.log2_int(u32, universe / count));
}

fn efWords(count: u32, universe: u32, low: u6) usize {
    const low_words = std.math.divCeil(usize, @as(usize, count) * low, 64) catch unreachable;
    const high_bits = @as(usize, count) + (@as(usize, universe) >> low) + 1;
    return low_words + (std.math.divCeil(usize, high_bits, 64) catch unreachable);
}

fn bitmapWords(universe: u32) usize {
    return std.math.divCeil(usize, @max(universe, 1), 64) catch unreachable;
}

pub const Writer = struct {
    shape: Shape,
    words: []u64,
    next: u32 = 0,
    last: ?u32 = null,

    pub fn init(shape: Shape, words: []u64) Writer {
        std.debug.assert(words.len == shape.words());
        @memset(words, 0);
        return .{ .shape = shape, .words = words };
    }

    pub fn push(self: *Writer, id: u32) void {
        std.debug.assert(id < self.shape.universe);
        std.debug.assert(self.last == null or id > self.last.?);
        std.debug.assert(self.next < self.shape.count);
        self.last = id;
        defer self.next += 1;
        if (self.shape.bitmap) {
            self.words[id >> 6] |= @as(u64, 1) << @as(u6, @truncate(id));
            return;
        }
        const low = self.shape.low;
        if (low != 0) setBits(self.words[0..self.shape.lowWords()], @as(usize, self.next) * low, low, @intCast(@as(u64, id) & ((@as(u64, 1) << low) - 1)));
        const high_at = (@as(usize, id) >> low) + self.next;
        const high = self.words[self.shape.lowWords()..];
        high[high_at >> 6] |= @as(u64, 1) << @as(u6, @truncate(high_at));
    }

    pub fn done(self: Writer) bool {
        return self.next == self.shape.count;
    }
};

fn setBits(words: []u64, at: usize, width: u6, value: u32) void {
    const v: u64 = value;
    const word = at >> 6;
    const shift: u6 = @truncate(at);
    words[word] |= v << shift;
    const used: usize = 64 - @as(usize, shift);
    if (used < width) words[word + 1] |= v >> @as(u6, @intCast(used));
}

fn getBits(words: []const u64, at: usize, width: u6) u32 {
    const word = at >> 6;
    const shift: u6 = @truncate(at);
    var v = words[word] >> shift;
    const used: usize = 64 - @as(usize, shift);
    if (used < width) v |= words[word + 1] << @as(u6, @intCast(used));
    const mask = (@as(u64, 1) << width) - 1;
    return @intCast(v & mask);
}

pub const List = struct {
    shape: Shape,
    words: []const u64,

    pub fn iterator(self: List) Iterator {
        return .{ .list = self };
    }

    pub fn contains(self: List, id: u32) bool {
        if (id >= self.shape.universe) return false;
        if (self.shape.bitmap) return self.words[id >> 6] & (@as(u64, 1) << @as(u6, @truncate(id))) != 0;
        var it = self.iterator();
        return it.nextAtLeast(id) == id;
    }
};

pub const Iterator = struct {
    list: List,
    index: u32 = 0,
    high_pos: usize = 0,
    bit: u32 = 0,
    current: ?u32 = null,

    pub fn next(self: *Iterator) ?u32 {
        self.current = self.advance();
        return self.current;
    }

    pub fn nextAtLeast(self: *Iterator, target: u32) ?u32 {
        if (self.current) |c| {
            if (c >= target) return c;
        }
        if (self.list.shape.bitmap and target > self.bit) self.bit = target;
        while (self.next()) |v| {
            if (v >= target) return v;
        }
        return null;
    }

    fn advance(self: *Iterator) ?u32 {
        const shape = self.list.shape;
        if (shape.bitmap) {
            var i = self.bit;
            const words = self.list.words;
            while (i < shape.universe) {
                const w = words[i >> 6] >> @as(u6, @truncate(i));
                if (w != 0) {
                    const found = i + @ctz(w);
                    if (found >= shape.universe) return null;
                    self.bit = found + 1;
                    return found;
                }
                i = (i | 63) + 1;
            }
            self.bit = shape.universe;
            return null;
        }
        if (self.index >= shape.count) return null;
        const high = self.list.words[shape.lowWords()..];
        var pos = self.high_pos;
        while (true) {
            const w = high[pos >> 6] >> @as(u6, @truncate(pos));
            if (w != 0) {
                pos += @ctz(w);
                break;
            }
            pos = (pos | 63) + 1;
        }
        const high_value: u32 = @intCast(pos - self.index);
        const low = shape.low;
        const low_value: u32 = if (low == 0) 0 else getBits(self.list.words[0..shape.lowWords()], @as(usize, self.index) * low, low);
        self.index += 1;
        self.high_pos = pos + 1;
        return @intCast((@as(u64, high_value) << low) | low_value);
    }
};

pub fn intersect(gpa: Allocator, lists: []const List, lo: u32, hi: u32, out: *std.ArrayList(u32)) !void {
    if (lists.len == 0 or lo >= hi) return;
    const order = try gpa.alloc(usize, lists.len);
    defer gpa.free(order);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, lists, struct {
        fn less(l: []const List, a: usize, b: usize) bool {
            return l[a].shape.count < l[b].shape.count;
        }
    }.less);
    const iters = try gpa.alloc(Iterator, lists.len);
    defer gpa.free(iters);
    for (iters, order) |*it, o| it.* = lists[o].iterator();
    var candidate = iters[0].nextAtLeast(lo) orelse return;
    outer: while (candidate < hi) {
        for (iters[1..], order[1..]) |*it, o| {
            const list = lists[o];
            if (list.shape.bitmap) {
                if (!list.contains(candidate)) {
                    candidate = iters[0].next() orelse return;
                    continue :outer;
                }
                continue;
            }
            const at = it.nextAtLeast(candidate) orelse return;
            if (at != candidate) {
                candidate = iters[0].nextAtLeast(at) orelse return;
                continue :outer;
            }
        }
        try out.append(gpa, candidate);
        candidate = iters[0].next() orelse return;
    }
}

const testing = std.testing;

fn encode(gpa: Allocator, ids: []const u32, universe: u32) !struct { shape: Shape, words: []u64 } {
    const shape = Shape.of(@intCast(ids.len), universe);
    const words = try gpa.alloc(u64, shape.words());
    var w = Writer.init(shape, words);
    for (ids) |id| w.push(id);
    try testing.expect(w.done());
    return .{ .shape = shape, .words = words };
}

test "postings: an encoded list iterates back to the same ids for sparse and dense shapes" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    for ([_]u32{ 1, 2, 3, 7, 64, 200, 1000, 29000 }) |universe| {
        for ([_]u32{ 1, 2, 5, 50, 300, 900, 5000, 20000 }) |wanted| {
            if (wanted > universe) continue;
            var set: std.AutoArrayHashMapUnmanaged(u32, void) = .empty;
            defer set.deinit(testing.allocator);
            while (set.count() < wanted) try set.put(testing.allocator, random.uintLessThan(u32, universe), {});
            const ids = try testing.allocator.dupe(u32, set.keys());
            defer testing.allocator.free(ids);
            std.mem.sort(u32, ids, {}, std.sort.asc(u32));
            const enc = try encode(testing.allocator, ids, universe);
            defer testing.allocator.free(enc.words);
            const list: List = .{ .shape = enc.shape, .words = enc.words };
            var it = list.iterator();
            for (ids) |id| try testing.expectEqual(@as(?u32, id), it.next());
            try testing.expectEqual(@as(?u32, null), it.next());
            for (ids) |id| try testing.expect(list.contains(id));
            if (ids.len < universe) {
                var missing: u32 = 0;
                while (set.contains(missing)) missing += 1;
                try testing.expect(!list.contains(missing));
            }
        }
    }
}

test "postings: a dense list is stored as a bitmap and a sparse one as elias-fano" {
    try testing.expect(Shape.of(20000, 29000).bitmap);
    try testing.expect(!Shape.of(50, 29000).bitmap);
    try testing.expect(Shape.of(50, 29000).words() < Shape.of(20000, 29000).words());
}

test "postings: intersect returns exactly the ids every list holds inside the range" {
    const universe: u32 = 5000;
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    var sets: [4][]u32 = undefined;
    var encoded: [4]List = undefined;
    var owned: [4][]u64 = undefined;
    for (&sets, &encoded, &owned, [_]u32{ 300, 2500, 4500, 60 }) |*s, *l, *o, n| {
        var set: std.AutoArrayHashMapUnmanaged(u32, void) = .empty;
        defer set.deinit(testing.allocator);
        while (set.count() < n) try set.put(testing.allocator, random.uintLessThan(u32, universe), {});
        s.* = try testing.allocator.dupe(u32, set.keys());
        std.mem.sort(u32, s.*, {}, std.sort.asc(u32));
        const enc = try encode(testing.allocator, s.*, universe);
        o.* = enc.words;
        l.* = .{ .shape = enc.shape, .words = enc.words };
    }
    defer for (sets, owned) |s, o| {
        testing.allocator.free(s);
        testing.allocator.free(o);
    };
    for ([_][2]u32{ .{ 0, universe }, .{ 100, 900 }, .{ 4000, 4001 } }) |range| {
        for ([_]usize{ 1, 2, 3, 4 }) |k| {
            var got: std.ArrayList(u32) = .empty;
            defer got.deinit(testing.allocator);
            try intersect(testing.allocator, encoded[0..k], range[0], range[1], &got);
            var want: std.ArrayList(u32) = .empty;
            defer want.deinit(testing.allocator);
            for (sets[0]) |id| {
                if (id < range[0] or id >= range[1]) continue;
                var all = true;
                for (sets[1..k]) |other| {
                    if (std.mem.indexOfScalar(u32, other, id) == null) all = false;
                }
                if (all) try want.append(testing.allocator, id);
            }
            try testing.expectEqualSlices(u32, want.items, got.items);
        }
    }
}
