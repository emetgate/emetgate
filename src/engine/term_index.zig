const std = @import("std");

const Allocator = std.mem.Allocator;

pub const k1: f64 = 1.2;
pub const b: f64 = 0.75;
pub const name_weight: u32 = 3;
pub const min_term: usize = 2;
pub const max_term: usize = 64;

pub const Posting = struct {
    doc: u32,
    count: u32,
};

pub const Hit = struct {
    doc: u32,
    score: f64,

    fn greater(_: void, x: Hit, y: Hit) bool {
        if (x.score != y.score) return x.score > y.score;
        return x.doc < y.doc;
    }
};

fn wordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

fn splitsBefore(word: []const u8, i: usize) bool {
    const c = word[i];
    const p = word[i - 1];
    if (std.ascii.isUpper(c) and (std.ascii.isLower(p) or std.ascii.isDigit(p))) return true;
    if (std.ascii.isUpper(c) and std.ascii.isUpper(p) and i + 1 < word.len and std.ascii.isLower(word[i + 1])) return true;
    return std.ascii.isDigit(c) != std.ascii.isDigit(p);
}

pub fn eachTerm(text: []const u8, ctx: anytype) !void {
    var i: usize = 0;
    while (i < text.len) {
        if (!wordByte(text[i])) {
            i += 1;
            continue;
        }
        var end = i + 1;
        while (end < text.len and wordByte(text[end])) end += 1;
        const word = text[i..end];
        i = end;
        if (std.ascii.isDigit(word[0])) continue;
        try ctx.term(word);
        var start: usize = 0;
        var k: usize = 0;
        while (k <= word.len) : (k += 1) {
            const sep = k < word.len and (word[k] == '_' or word[k] == '$');
            const cut = k == word.len or sep or (k > start and splitsBefore(word, k));
            if (!cut) continue;
            if (k > start) {
                if (start != 0 or k != word.len) try ctx.term(word[start..k]);
            }
            start = if (sep) k + 1 else k;
        }
    }
}

fn lower(buf: *[max_term]u8, raw: []const u8) ?[]const u8 {
    if (raw.len < min_term or raw.len > max_term) return null;
    for (raw, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..raw.len];
}

pub const Index = struct {
    arena: Allocator,
    ids: std.StringHashMapUnmanaged(u32) = .empty,
    postings: std.ArrayList(std.ArrayList(Posting)) = .empty,
    lengths: std.ArrayList(u32) = .empty,
    total: u64 = 0,
    counts: std.AutoArrayHashMapUnmanaged(u32, u32) = .empty,
    fed: u32 = 0,

    pub fn init(arena: Allocator) Index {
        return .{ .arena = arena };
    }

    pub fn term(self: *Index, raw: []const u8) !void {
        var buf: [max_term]u8 = undefined;
        const low = lower(&buf, raw) orelse return;
        const entry = try self.ids.getOrPut(self.arena, low);
        if (!entry.found_existing) {
            entry.key_ptr.* = try self.arena.dupe(u8, low);
            entry.value_ptr.* = @intCast(self.postings.items.len);
            try self.postings.append(self.arena, .empty);
        }
        const slot = try self.counts.getOrPut(self.arena, entry.value_ptr.*);
        if (!slot.found_existing) slot.value_ptr.* = 0;
        slot.value_ptr.* += 1;
        self.fed += 1;
    }

    pub fn add(self: *Index, name: []const u8, path: []const u8, body: []const u8) !u32 {
        self.counts.clearRetainingCapacity();
        self.fed = 0;
        var i: u32 = 0;
        while (i < name_weight) : (i += 1) try eachTerm(name, self);
        try eachTerm(path, self);
        try eachTerm(body, self);
        const doc: u32 = @intCast(self.lengths.items.len);
        for (self.counts.keys(), self.counts.values()) |id, count| try self.postings.items[id].append(self.arena, .{ .doc = doc, .count = count });
        try self.lengths.append(self.arena, self.fed);
        self.total += self.fed;
        return doc;
    }

    pub fn rank(self: *const Index, arena: Allocator, query: []const u8, limit: usize) ![]const Hit {
        const n = self.lengths.items.len;
        if (n == 0) return &.{};
        var wanted: Wanted = .{ .arena = arena, .index = self };
        try eachTerm(query, &wanted);
        const scores = try arena.alloc(f64, n);
        @memset(scores, 0);
        const docs: f64 = @floatFromInt(n);
        const avg: f64 = @max(@as(f64, @floatFromInt(self.total)) / docs, 1);
        for (wanted.ids.keys()) |id| {
            const list = self.postings.items[id].items;
            const df: f64 = @floatFromInt(list.len);
            const idf = @log(1 + (docs - df + 0.5) / (df + 0.5));
            for (list) |p| {
                const tf: f64 = @floatFromInt(p.count);
                const len: f64 = @floatFromInt(self.lengths.items[p.doc]);
                scores[p.doc] += idf * tf * (k1 + 1) / (tf + k1 * (1 - b + b * len / avg));
            }
        }
        var hits: std.ArrayList(Hit) = .empty;
        for (scores, 0..) |s, doc| {
            if (s > 0) try hits.append(arena, .{ .doc = @intCast(doc), .score = s });
        }
        std.mem.sort(Hit, hits.items, {}, Hit.greater);
        return hits.items[0..@min(hits.items.len, limit)];
    }
};

const Wanted = struct {
    arena: Allocator,
    index: *const Index,
    ids: std.AutoArrayHashMapUnmanaged(u32, void) = .empty,

    pub fn term(self: *Wanted, raw: []const u8) !void {
        var buf: [max_term]u8 = undefined;
        const low = lower(&buf, raw) orelse return;
        const id = self.index.ids.get(low) orelse return;
        try self.ids.put(self.arena, id, {});
    }
};

const testing = std.testing;

const Collected = struct {
    items: std.ArrayList([]const u8) = .empty,

    pub fn term(self: *Collected, raw: []const u8) !void {
        try self.items.append(testing.allocator, raw);
    }
};

test "term index: an identifier yields itself and its camel, underscore and digit parts" {
    var got: Collected = .{};
    defer got.items.deinit(testing.allocator);
    try eachTerm("getHTTPResponse2 leftover-pos MAX_VALUE 9lives", &got);
    const want = [_][]const u8{ "getHTTPResponse2", "get", "HTTP", "Response", "2", "leftover", "pos", "MAX_VALUE", "MAX", "VALUE" };
    try testing.expectEqual(want.len, got.items.items.len);
    for (want, got.items.items) |w, g| try testing.expectEqualStrings(w, g);
}

test "term index: a body that holds the rare query word outranks a body that holds only the common one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var index = Index.init(arena);
    const first = try index.add("createCategory", "budget/envelope.ts", "createDynamic(sheetName, 'leftover-pos-' + cat.id)");
    const second = try index.add("BalanceMenu", "components/BalanceMenu.tsx", "return <Menu budget={budget} />");
    _ = try index.add("openMenu", "components/Menu.tsx", "budget.open()");
    const hits = try index.rank(arena, "budget leftover", 10);
    try testing.expectEqual(@as(usize, 3), hits.len);
    try testing.expectEqual(first, hits[0].doc);
    try testing.expect(hits[0].score > hits[1].score);
    try testing.expect(second == hits[1].doc or second == hits[2].doc);
    try testing.expectEqual(@as(usize, 0), (try index.rank(arena, "nothing here matches", 10)).len);
    try testing.expectEqual(@as(usize, 1), (try index.rank(arena, "budget", 1)).len);
}
