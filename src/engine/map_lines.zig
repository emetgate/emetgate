const std = @import("std");
const map = @import("map.zig");

const Allocator = std.mem.Allocator;

pub const min_word = 3;

const stop_words = [_][]const u8{
    "the",     "and",   "for",  "with",  "from",     "that",  "this",  "what",   "which",  "when",  "where", "how",   "does",
    "are",     "is",    "was",  "not",   "but",      "into",  "than",  "then",   "there",  "their", "them",  "have",  "has",
    "had",     "will",  "would", "can",  "could",    "should", "over", "under",  "about",  "between", "each", "per", "its",
    "use",     "used",  "using", "code", "file",     "files", "function", "functions",
};

pub fn isStop(word: []const u8) bool {
    for (stop_words) |s| {
        if (std.mem.eql(u8, s, word)) return true;
    }
    return false;
}

fn isUpper(c: u8) bool {
    return c >= 'A' and c <= 'Z';
}

fn isLower(c: u8) bool {
    return c >= 'a' and c <= 'z';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isAlpha(c: u8) bool {
    return isUpper(c) or isLower(c);
}

pub const WordSet = struct {
    arena: Allocator,
    items: std.ArrayList([]const u8) = .empty,

    pub fn add(self: *WordSet, raw: []const u8) !void {
        if (raw.len < min_word) return;
        var buf: [256]u8 = undefined;
        if (raw.len > buf.len) return;
        for (raw, 0..) |c, i| buf[i] = std.ascii.toLower(c);
        const low = buf[0..raw.len];
        if (isStop(low)) return;
        for (self.items.items) |w| {
            if (std.mem.eql(u8, w, low)) return;
        }
        try self.items.append(self.arena, try self.arena.dupe(u8, low));
    }

    pub fn has(self: *const WordSet, word: []const u8) bool {
        for (self.items.items) |w| {
            if (std.mem.eql(u8, w, word)) return true;
        }
        return false;
    }
};

pub fn words(arena: Allocator, text: []const u8) !WordSet {
    var set: WordSet = .{ .arena = arena };
    var i: usize = 0;
    while (i < text.len) {
        if (!isAlpha(text[i])) {
            i += 1;
            continue;
        }
        var end = i + 1;
        while (end < text.len and (isAlpha(text[end]) or isDigit(text[end]))) end += 1;
        const run = text[i..end];
        try set.add(run);
        try parts(&set, run);
        i = end;
    }
    return set;
}

fn parts(set: *WordSet, run: []const u8) !void {
    var i: usize = 0;
    while (i < run.len) {
        const c = run[i];
        if (isUpper(c)) {
            var j = i;
            while (j < run.len and isUpper(run[j])) j += 1;
            if (j < run.len and isLower(run[j])) {
                if (j - i >= 2) {
                    try set.add(run[i .. j - 1]);
                    i = j - 1;
                }
                var k = i + 1;
                while (k < run.len and isLower(run[k])) k += 1;
                try set.add(run[i..k]);
                i = k;
            } else {
                try set.add(run[i..j]);
                i = j;
            }
        } else if (isLower(c)) {
            var k = i;
            while (k < run.len and isLower(run[k])) k += 1;
            try set.add(run[i..k]);
            i = k;
        } else {
            var k = i;
            while (k < run.len and isDigit(run[k])) k += 1;
            try set.add(run[i..k]);
            i = @max(k, i + 1);
        }
    }
}

pub const Line = struct {
    region: map.RegionId,
    words: WordSet,
};

pub const Index = struct {
    lines: []const Line,
    df: std.StringHashMapUnmanaged(u32),
    headings: []const []const u8,

    pub fn build(arena: Allocator, text: []const u8) !Index {
        var lines: std.ArrayList(Line) = .empty;
        var headings: std.ArrayList([]const u8) = .empty;
        var df: std.StringHashMapUnmanaged(u32) = .empty;
        var heading: []const u8 = "";
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (std.mem.startsWith(u8, line, "## ")) {
                heading = std.mem.trim(u8, line[3..], " ");
                const brace = std.mem.indexOfScalar(u8, heading, '{') orelse heading.len;
                const top = std.mem.trim(u8, heading[0..brace], " ");
                for (headings.items) |h| {
                    if (std.mem.eql(u8, h, top)) break;
                } else try headings.append(arena, top);
                continue;
            }
            if (line.len < 3 or line[0] != 'r' or !isDigit(line[1])) continue;
            const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const id = std.fmt.parseInt(u32, line[1..space], 10) catch continue;
            if (id == 0) continue;
            const joined = try std.mem.concat(arena, u8, &.{ heading, " ", line[space + 1 ..] });
            const set = try words(arena, joined);
            for (set.items.items) |w| {
                const entry = try df.getOrPut(arena, w);
                if (!entry.found_existing) entry.value_ptr.* = 0;
                entry.value_ptr.* += 1;
            }
            try lines.append(arena, .{ .region = id - 1, .words = set });
        }
        std.mem.sort([]const u8, headings.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);
        return .{ .lines = lines.items, .df = df, .headings = headings.items };
    }

    pub fn expandStems(self: *const Index, set: *WordSet, stems: []const []const u8) !void {
        for (stems) |stem| {
            if (stem.len < 4) continue;
            var it = self.df.keyIterator();
            while (it.next()) |key| {
                if (std.mem.startsWith(u8, key.*, stem)) try set.add(key.*);
            }
        }
    }

    pub fn pick(self: *const Index, arena: Allocator, terms: *const WordSet, max: usize) ![]const map.RegionId {
        const Scored = struct { region: map.RegionId, score: f64, order: usize };
        var scored: std.ArrayList(Scored) = .empty;
        const n: f64 = @floatFromInt(self.lines.len);
        for (self.lines, 0..) |line, order| {
            var score: f64 = 0;
            for (terms.items.items) |t| {
                if (!line.words.has(t)) continue;
                const d: f64 = @floatFromInt(self.df.get(t) orelse 1);
                score += @log(1 + n / d);
            }
            if (score > 0) try scored.append(arena, .{ .region = line.region, .score = score, .order = order });
        }
        std.mem.sort(Scored, scored.items, {}, struct {
            fn more(_: void, a: Scored, b: Scored) bool {
                if (a.score != b.score) return a.score > b.score;
                return a.order < b.order;
            }
        }.more);
        const count = @min(max, scored.items.len);
        const out = try arena.alloc(map.RegionId, count);
        for (scored.items[0..count], out) |s, *r| r.* = s.region;
        return out;
    }
};

const testing = std.testing;

fn has(set: WordSet, word: []const u8) bool {
    return set.has(word);
}

test "map lines: words keep the whole identifier and its camel case pieces in lower case and drop short and stop words" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const set = try words(arena_state.allocator(), "How does the HTTPServer use isTreeStatic in v2?");
    try testing.expect(has(set, "httpserver") and has(set, "http") and has(set, "server"));
    try testing.expect(has(set, "istreestatic") and has(set, "tree") and has(set, "static"));
    try testing.expect(!has(set, "how") and !has(set, "the") and !has(set, "use") and !has(set, "is") and !has(set, "v2"));
}

test "map lines: the region whose line shares the rarest words with the question comes first" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text =
        \\# Project map
        \\## packages/core/
        \\r1 injector/: Injector{loadPerContext}, isTreeStatic [instance-wrapper]
        \\r2 router/: RouterExplorer, routes [router-execution-context]
        \\## packages/common/
        \\r3 decorators/: Injectable, Controller [scope]
        \\
    ;
    const index = try Index.build(arena, text);
    try testing.expectEqual(@as(usize, 3), index.lines.len);
    try testing.expectEqualStrings("packages/common/", index.headings[0]);
    const terms = try words(arena, "is the controller static when a provider deep in the tree is request scoped");
    const picked = try index.pick(arena, &terms, 2);
    try testing.expectEqual(@as(map.RegionId, 0), picked[0]);
    try testing.expectEqual(@as(usize, 2), picked.len);
}
