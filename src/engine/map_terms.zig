const std = @import("std");

const Allocator = std.mem.Allocator;

pub const max_part = 48;

fn isUpper(c: u8) bool {
    return c >= 'A' and c <= 'Z';
}

fn isLower(c: u8) bool {
    return (c >= 'a' and c <= 'z') or c >= 0x80;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isWordByte(c: u8) bool {
    return isUpper(c) or isLower(c) or isDigit(c);
}

fn boundary(run: []const u8, i: usize) bool {
    const prev = run[i - 1];
    const cur = run[i];
    if ((isLower(prev) or isDigit(prev)) and isUpper(cur)) return true;
    if ((isUpper(prev) or isLower(prev)) and isDigit(cur)) return true;
    if (isDigit(prev) and (isUpper(cur) or isLower(cur))) return true;
    if (isUpper(prev) and isUpper(cur) and i + 1 < run.len and isLower(run[i + 1])) {
        const plural = run[i + 1] == 's' and (i + 2 == run.len or !isLower(run[i + 2]));
        return !plural;
    }
    return false;
}

pub fn eachPart(text: []const u8, ctx: anytype) !void {
    var lower: [max_part]u8 = undefined;
    var start: usize = 0;
    while (start < text.len) {
        while (start < text.len and !isWordByte(text[start])) start += 1;
        var end = start;
        while (end < text.len and isWordByte(text[end])) end += 1;
        if (end == start) break;
        const run = text[start..end];
        start = end;
        var part_start: usize = 0;
        var i: usize = 1;
        while (i <= run.len) : (i += 1) {
            if (i < run.len and !boundary(run, i)) continue;
            const part = run[part_start..i];
            part_start = i;
            if (part.len < 2 or part.len > max_part) continue;
            var digits = true;
            for (part, 0..) |c, k| {
                lower[k] = std.ascii.toLower(c);
                if (!isDigit(c)) digits = false;
            }
            if (digits) continue;
            try ctx.part(lower[0..part.len]);
        }
    }
}

const Rule = struct { suffix: []const u8, replacement: []const u8, min_stem: usize };

const rules = [_]Rule{
    .{ .suffix = "ies", .replacement = "y", .min_stem = 2 },
    .{ .suffix = "sses", .replacement = "ss", .min_stem = 2 },
    .{ .suffix = "ss", .replacement = "ss", .min_stem = 2 },
    .{ .suffix = "us", .replacement = "us", .min_stem = 2 },
    .{ .suffix = "is", .replacement = "is", .min_stem = 2 },
    .{ .suffix = "s", .replacement = "", .min_stem = 2 },
    .{ .suffix = "ing", .replacement = "", .min_stem = 3 },
    .{ .suffix = "ed", .replacement = "", .min_stem = 3 },
    .{ .suffix = "ions", .replacement = "", .min_stem = 3 },
    .{ .suffix = "ion", .replacement = "", .min_stem = 3 },
    .{ .suffix = "ers", .replacement = "", .min_stem = 3 },
    .{ .suffix = "er", .replacement = "", .min_stem = 3 },
    .{ .suffix = "ors", .replacement = "", .min_stem = 3 },
    .{ .suffix = "or", .replacement = "", .min_stem = 3 },
    .{ .suffix = "ments", .replacement = "", .min_stem = 3 },
    .{ .suffix = "ment", .replacement = "", .min_stem = 3 },
    .{ .suffix = "ly", .replacement = "", .min_stem = 3 },
    .{ .suffix = "e", .replacement = "", .min_stem = 3 },
};

fn longerFirst(_: void, a: Rule, b: Rule) bool {
    return a.suffix.len > b.suffix.len;
}

const ordered_rules = blk: {
    var copy = rules;
    std.mem.sort(Rule, &copy, {}, longerFirst);
    break :blk copy;
};

pub fn stem(word: []const u8, buf: []u8) []const u8 {
    if (word.len > buf.len) return word;
    @memcpy(buf[0..word.len], word);
    var len = word.len;
    var pass: usize = 0;
    while (pass < 3) : (pass += 1) {
        const current = buf[0..len];
        const rule = for (ordered_rules) |r| {
            if (current.len >= r.suffix.len + r.min_stem and std.mem.endsWith(u8, current, r.suffix)) break r;
        } else break;
        if (std.mem.eql(u8, rule.suffix, rule.replacement)) break;
        const base = len - rule.suffix.len;
        @memcpy(buf[base .. base + rule.replacement.len], rule.replacement);
        len = base + rule.replacement.len;
    }
    return buf[0..len];
}

const plural_rules = rules[0..6];

pub fn pluralStem(word: []const u8, buf: []u8) []const u8 {
    if (word.len > buf.len) return word;
    @memcpy(buf[0..word.len], word);
    for (plural_rules) |r| {
        if (word.len < r.suffix.len + r.min_stem or !std.mem.endsWith(u8, word, r.suffix)) continue;
        const base = word.len - r.suffix.len;
        @memcpy(buf[base .. base + r.replacement.len], r.replacement);
        return buf[0 .. base + r.replacement.len];
    }
    return buf[0..word.len];
}

const stop_words = [_][]const u8{
    "a",     "an",   "and",  "any",  "are",    "as",   "at",    "be",   "by",    "can",  "do",    "does",  "for",
    "from",  "get",  "has",  "have", "if",     "in",   "into",  "is",   "it",    "its",  "no",    "not",   "of",
    "on",    "or",   "set",  "so",   "than",   "that", "the",   "then", "this",  "to",   "too",   "up",    "was",
    "were",  "will", "with", "all",  "new",    "use",  "out",   "via",  "per",   "one",  "two",   "my",    "we",
    "our",   "you",  "your", "ts",   "js",     "tsx",  "jsx",   "mjs",  "cjs",   "src",  "lib",   "dist",  "index",
};

pub fn isStop(word: []const u8) bool {
    for (stop_words) |s| {
        if (std.mem.eql(u8, s, word)) return true;
    }
    return false;
}

pub const Stems = struct {
    arena: Allocator,
    plural_only: bool = false,
    ids: std.StringHashMapUnmanaged(u32) = .empty,
    names: std.ArrayList([]const u8) = .empty,
    surface: std.ArrayList(std.StringArrayHashMapUnmanaged(u32)) = .empty,

    pub fn intern(self: *Stems, raw: []const u8) !u32 {
        var buf: [max_part]u8 = undefined;
        const key = if (self.plural_only) pluralStem(raw, &buf) else stem(raw, &buf);
        const entry = try self.ids.getOrPut(self.arena, key);
        if (!entry.found_existing) {
            entry.key_ptr.* = try self.arena.dupe(u8, key);
            entry.value_ptr.* = @intCast(self.names.items.len);
            try self.names.append(self.arena, entry.key_ptr.*);
            try self.surface.append(self.arena, .empty);
        }
        const id = entry.value_ptr.*;
        const forms = &self.surface.items[id];
        const form = try forms.getOrPut(self.arena, raw);
        if (!form.found_existing) {
            form.key_ptr.* = try self.arena.dupe(u8, raw);
            form.value_ptr.* = 0;
        }
        form.value_ptr.* += 1;
        return id;
    }

    pub fn display(self: *const Stems, id: u32) []const u8 {
        const forms = &self.surface.items[id];
        var best: []const u8 = self.names.items[id];
        var count: u32 = 0;
        for (forms.keys(), forms.values()) |k, v| {
            if (v > count or (v == count and (k.len < best.len or (k.len == best.len and std.mem.order(u8, k, best) == .lt)))) {
                best = k;
                count = v;
            }
        }
        return best;
    }
};

pub fn mutualInformation(n11: f64, n10: f64, n01: f64, n00: f64) f64 {
    const n = n11 + n10 + n01 + n00;
    if (n <= 0) return 0;
    const n1_ = n11 + n10;
    const n0_ = n01 + n00;
    const n_1 = n11 + n01;
    const n_0 = n10 + n00;
    return cell(n, n11, n1_, n_1) + cell(n, n01, n0_, n_1) + cell(n, n10, n1_, n_0) + cell(n, n00, n0_, n_0);
}

fn cell(n: f64, joint: f64, row: f64, col: f64) f64 {
    if (joint <= 0 or row <= 0 or col <= 0) return 0;
    return (joint / n) * std.math.log2(n * joint / (row * col));
}

pub const Cover = struct {
    element: u32,
    value: f32,
};

pub const Candidate = struct {
    cost: u32,
    covers: []const Cover,
};

pub const Selection = struct {
    chosen: []u32,
    value: f64,
    spent: u64,
};

const Entry = struct {
    ratio: f64,
    index: u32,
};

fn entryOrder(_: void, a: Entry, b: Entry) std.math.Order {
    if (a.ratio != b.ratio) return if (a.ratio > b.ratio) .lt else .gt;
    return std.math.order(a.index, b.index);
}

fn gainOf(candidate: Candidate, weights: []const f64, current: []const f32) f64 {
    var gain: f64 = 0;
    for (candidate.covers) |c| {
        const now = current[c.element];
        if (c.value > now) gain += weights[c.element] * @as(f64, c.value - now);
    }
    return gain;
}

pub fn greedy(arena: Allocator, weights: []const f64, base: []const f32, candidates: []const Candidate, budget: u64) !Selection {
    if (base.len != weights.len) return error.WeightsAndBaseDiffer;
    const current = try arena.dupe(f32, base);
    var heap: std.PriorityQueue(Entry, void, entryOrder) = .empty;
    defer heap.deinit(arena);
    var best_single: ?u32 = null;
    var best_single_value: f64 = 0;
    for (candidates, 0..) |c, i| {
        for (c.covers) |cover| if (cover.element >= weights.len) return error.ElementOutOfRange;
        if (c.cost == 0 or c.cost > budget) continue;
        const gain = gainOf(c, weights, current);
        if (gain <= 0) continue;
        if (gain > best_single_value) {
            best_single_value = gain;
            best_single = @intCast(i);
        }
        try heap.push(arena, .{ .ratio = gain / @as(f64, @floatFromInt(c.cost)), .index = @intCast(i) });
    }
    var chosen: std.ArrayList(u32) = .empty;
    var spent: u64 = 0;
    var value: f64 = 0;
    while (heap.pop()) |top| {
        const c = candidates[top.index];
        if (spent + c.cost > budget) continue;
        const gain = gainOf(c, weights, current);
        if (gain <= 0) continue;
        const ratio = gain / @as(f64, @floatFromInt(c.cost));
        if (heap.peek()) |next| {
            if (entryOrder({}, .{ .ratio = ratio, .index = top.index }, next) == .gt) {
                try heap.push(arena, .{ .ratio = ratio, .index = top.index });
                continue;
            }
        }
        for (c.covers) |cover| {
            if (cover.value > current[cover.element]) current[cover.element] = cover.value;
        }
        try chosen.append(arena, top.index);
        spent += c.cost;
        value += gain;
    }
    if (best_single) |single| {
        if (best_single_value > value) {
            const only = try arena.alloc(u32, 1);
            only[0] = single;
            return .{ .chosen = only, .value = best_single_value, .spent = candidates[single].cost };
        }
    }
    return .{ .chosen = chosen.items, .value = value, .spent = spent };
}

const testing = std.testing;

const Collect = struct {
    arena: Allocator,
    parts: std.ArrayList([]const u8) = .empty,

    fn part(self: *Collect, text: []const u8) !void {
        try self.parts.append(self.arena, try self.arena.dupe(u8, text));
    }
};

fn partsOf(arena: Allocator, text: []const u8) ![]const []const u8 {
    var c: Collect = .{ .arena = arena };
    try eachPart(text, &c);
    return c.parts.items;
}

test "map terms: identifiers split at case, digit and separator boundaries into lower case parts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parts = try partsOf(arena, "handleNodeExecutionError");
    try testing.expectEqual(@as(usize, 4), parts.len);
    try testing.expectEqualStrings("handle", parts[0]);
    try testing.expectEqualStrings("error", parts[3]);
    const acronym = try partsOf(arena, "parseHTTPResponse_v2");
    try testing.expectEqualStrings("parse", acronym[0]);
    try testing.expectEqualStrings("http", acronym[1]);
    try testing.expectEqualStrings("response", acronym[2]);
    const plural = try partsOf(arena, "listURLs");
    try testing.expectEqualStrings("urls", plural[1]);
    const path = try partsOf(arena, "credentials-tester.service.ts");
    try testing.expectEqual(@as(usize, 4), path.len);
    try testing.expectEqualStrings("tester", path[1]);
    const short = try partsOf(arena, "x_1_id");
    try testing.expectEqual(@as(usize, 1), short.len);
}

test "map terms: english suffixes reduce related words to one stem" {
    var a: [max_part]u8 = undefined;
    var b: [max_part]u8 = undefined;
    try testing.expectEqualStrings(stem("connections", &a), stem("connection", &b));
    try testing.expectEqualStrings(stem("placeholders", &a), stem("placeholder", &b));
    try testing.expectEqualStrings("execut", stem("execution", &a));
    try testing.expectEqualStrings("class", stem("class", &a));
    try testing.expect(isStop("get") and !isStop("placeholder"));
}

test "map terms: the plural stem folds plurals only and keeps agent nouns apart from their verbs" {
    var a: [max_part]u8 = undefined;
    var b: [max_part]u8 = undefined;
    try testing.expectEqualStrings(pluralStem("connections", &a), pluralStem("connection", &b));
    try testing.expectEqualStrings("policy", pluralStem("policies", &a));
    try testing.expectEqualStrings("tester", pluralStem("testers", &a));
    try testing.expectEqualStrings("class", pluralStem("class", &a));
    try testing.expectEqualStrings("status", pluralStem("status", &a));
    try testing.expect(!std.mem.eql(u8, pluralStem("tester", &a), pluralStem("test", &b)));
}

test "map terms: mutual information is zero for an independent term and grows with association" {
    try testing.expectApproxEqAbs(@as(f64, 0), mutualInformation(10, 90, 10, 90), 1e-12);
    const weak = mutualInformation(6, 94, 14, 886);
    const strong = mutualInformation(19, 1, 1, 979);
    try testing.expect(strong > weak and weak > 0);
}

test "map terms: the budgeted greedy prefers value per cost, counts an element once, and never overspends" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const weights = [_]f64{ 1, 1, 1, 1 };
    const base = [_]f32{ 0, 0, 0, 0 };
    const candidates = [_]Candidate{
        .{ .cost = 4, .covers = &.{ .{ .element = 0, .value = 1 }, .{ .element = 1, .value = 1 }, .{ .element = 2, .value = 1 } } },
        .{ .cost = 1, .covers = &.{.{ .element = 0, .value = 1 }} },
        .{ .cost = 1, .covers = &.{.{ .element = 3, .value = 1 }} },
        .{ .cost = 2, .covers = &.{ .{ .element = 1, .value = 1 }, .{ .element = 2, .value = 1 } } },
    };
    const picked = try greedy(arena, &weights, &base, &candidates, 4);
    try testing.expect(picked.spent <= 4);
    try testing.expectApproxEqAbs(@as(f64, 4), picked.value, 1e-9);
    const again = try greedy(arena, &weights, &base, &candidates, 4);
    try testing.expectEqualSlices(u32, picked.chosen, again.chosen);
}

test "map terms: one large set beats a greedy choice of cheap small sets when it alone is worth more" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const weights = [_]f64{ 1, 10 };
    const base = [_]f32{ 0, 0 };
    const candidates = [_]Candidate{
        .{ .cost = 1, .covers = &.{.{ .element = 0, .value = 1 }} },
        .{ .cost = 10, .covers = &.{.{ .element = 1, .value = 1 }} },
    };
    const picked = try greedy(arena, &weights, &base, &candidates, 10);
    try testing.expectEqual(@as(usize, 1), picked.chosen.len);
    try testing.expectEqual(@as(u32, 1), picked.chosen[0]);
}
