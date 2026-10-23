const std = @import("std");
const regex_mod = @import("regex.zig");
const regex_hint = @import("regex_hint.zig");
const trigram = @import("trigram.zig");

const Allocator = std.mem.Allocator;

pub const line_budget: u64 = 2_000_000;

pub const Mode = enum { literal, alternatives, regex };

pub const Hit = struct { col: u32, text: []const u8 };

pub const Match = union(enum) {
    none,
    hit: Hit,
    over_budget,
};

pub const Scratch = struct {
    matcher: ?regex_mod.Matcher = null,

    pub fn deinit(self: Scratch, gpa: Allocator) void {
        if (self.matcher) |m| m.deinit(gpa);
    }
};

pub const Query = struct {
    mode: Mode,
    pattern: []const u8,
    re: ?regex_mod.Regex = null,
    literals: []const []const u8,
    grams: []const []const u24,

    pub fn literal(gpa: Allocator, pattern: []const u8) !Query {
        return withLiterals(gpa, .literal, pattern, null, &.{pattern});
    }

    pub fn regex(gpa: Allocator, pattern: []const u8, diag: ?*regex_mod.Diagnostic) !Query {
        const re = try regex_mod.Regex.compile(gpa, pattern, diag);
        errdefer re.deinit(gpa);
        var buf: [regex_hint.max_alternatives][]const u8 = undefined;
        return withLiterals(gpa, .regex, pattern, re, regex_hint.requiredLiterals(pattern, &buf));
    }

    pub fn alternatives(gpa: Allocator, pattern: []const u8) !?Query {
        var buf: [regex_hint.max_alternatives][]const u8 = undefined;
        var n: usize = 0;
        var parts = std.mem.splitScalar(u8, pattern, '|');
        while (parts.next()) |part| {
            if (part.len == 0 or n == buf.len) return null;
            buf[n] = part;
            n += 1;
        }
        if (n < 2) return null;
        return try withLiterals(gpa, .alternatives, pattern, null, buf[0..n]);
    }

    fn withLiterals(gpa: Allocator, mode: Mode, pattern: []const u8, re: ?regex_mod.Regex, literals: []const []const u8) !Query {
        const owned = try gpa.dupe([]const u8, literals);
        errdefer gpa.free(owned);
        const grams = try gpa.alloc([]const u24, literals.len);
        var made: usize = 0;
        errdefer {
            for (grams[0..made]) |g| gpa.free(g);
            gpa.free(grams);
        }
        for (literals, grams) |lit, *g| {
            g.* = try trigram.setOfAlloc(gpa, lit);
            made += 1;
        }
        return .{ .mode = mode, .pattern = pattern, .re = re, .literals = owned, .grams = grams };
    }

    pub fn deinit(self: Query, gpa: Allocator) void {
        if (self.re) |re| re.deinit(gpa);
        for (self.grams) |g| gpa.free(g);
        gpa.free(self.grams);
        gpa.free(self.literals);
    }

    pub fn scratch(self: Query, gpa: Allocator) Allocator.Error!Scratch {
        if (self.re == null) return .{};
        return .{ .matcher = try regex_mod.Matcher.init(gpa, line_budget) };
    }

    pub fn mayMatchFile(self: Query, file_trigrams: []const u24) bool {
        if (self.literals.len == 0) return true;
        for (self.literals, self.grams) |lit, g| {
            if (lit.len < 3) return true;
            if (trigram.isSupersetSorted(file_trigrams, g)) return true;
        }
        return false;
    }

    pub fn mayMatchText(self: Query, bytes: []const u8) bool {
        if (self.literals.len == 0) return true;
        for (self.literals) |lit| {
            if (std.mem.indexOf(u8, bytes, lit) != null) return true;
        }
        return false;
    }

    pub fn matchLine(self: Query, work: *const Scratch, line: []const u8) Allocator.Error!Match {
        const re = self.re orelse return if (self.earliestLiteral(line)) |hit| .{ .hit = hit } else .none;
        if (!self.mayMatchText(line)) return .none;
        const span = work.matcher.?.find(re, line) catch |err| switch (err) {
            error.BudgetExceeded => return .over_budget,
            error.OutOfMemory => |e| return e,
        } orelse return .none;
        return .{ .hit = .{ .col = @intCast(span.start), .text = line[span.start..span.end] } };
    }

    fn earliestLiteral(self: Query, line: []const u8) ?Hit {
        var best: ?Hit = null;
        for (self.literals) |lit| {
            const at = std.mem.indexOf(u8, line, lit) orelse continue;
            if (best == null or at < best.?.col) best = .{ .col = @intCast(at), .text = lit };
        }
        return best;
    }
};

pub fn regexSyntax(pattern: []const u8) ?[]const u8 {
    const tokens = [_][]const u8{ "|", "\\(", "\\)", "\\.", "\\b", "\\s", "\\w", "\\d", ".*", ".+", "[", "(?" };
    for (tokens) |t| {
        if (std.mem.indexOf(u8, pattern, t) != null) return t;
    }
    return null;
}

const testing = std.testing;

test "a literal query finds the text at its column and nothing else" {
    const q = try Query.literal(testing.allocator, "continueOnFail");
    defer q.deinit(testing.allocator);
    try testing.expectEqual(Match{ .hit = .{ .col = 7, .text = "continueOnFail" } }, try q.matchLine(&.{}, "  this.continueOnFail()"));
    try testing.expectEqual(Match.none, try q.matchLine(&.{}, "continuesOnError"));
}

test "literal alternatives split on every bar and refuse an empty part" {
    const q = (try Query.alternatives(testing.allocator, "handleNodeExecutionError(|continueExecution")).?;
    defer q.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), q.literals.len);
    try testing.expectEqualStrings("continueExecution", (try q.matchLine(&.{}, "if (!continueExecution) {")).hit.text);
    try testing.expectEqualStrings("handleNodeExecutionError(", (try q.matchLine(&.{}, "x = handleNodeExecutionError(a)")).hit.text);
    try testing.expectEqual(Match.none, try q.matchLine(&.{}, "handleNodeExecutionError;"));
    try testing.expect(try Query.alternatives(testing.allocator, "a || b") == null);
    try testing.expect(try Query.alternatives(testing.allocator, "plain") == null);
}

test "a regex line match reports where the match starts and the text it matched" {
    const q = try Query.regex(testing.allocator, "continuesOnError\\(|node\\.\\w+ ===", null);
    defer q.deinit(testing.allocator);
    const work = try q.scratch(testing.allocator);
    defer work.deinit(testing.allocator);
    const got = try q.matchLine(&work, "    if (node.onError === 'stop') {");
    try testing.expectEqual(@as(u32, 8), got.hit.col);
    try testing.expectEqualStrings("node.onError ===", got.hit.text);
    try testing.expectEqual(Match.none, try q.matchLine(&work, "    continuesOnError = 1;"));
}

test "a regex with flags has no required literal and still matches at the real column" {
    const q = try Query.regex(testing.allocator, "\\bfoo\\d{2}\\b", null);
    defer q.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), q.literals.len);
    const work = try q.scratch(testing.allocator);
    defer work.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 4), (try q.matchLine(&work, "x = foo42;")).hit.col);
    try testing.expectEqual(Match.none, try q.matchLine(&work, "x = foo4;"));
    const flags = try Query.regex(testing.allocator, "(?i)FOO", null);
    defer flags.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), flags.literals.len);
    const flag_work = try flags.scratch(testing.allocator);
    defer flag_work.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 2), (try flags.matchLine(&flag_work, "a foo")).hit.col);
}

test "a line that exhausts the regex step budget is reported, never read as no match" {
    const q = try Query.regex(testing.allocator, "^(a|aa)+z", null);
    defer q.deinit(testing.allocator);
    const work = try q.scratch(testing.allocator);
    defer work.deinit(testing.allocator);
    const line = "a" ** 200 ++ "!z";
    try testing.expectEqual(Match.over_budget, try q.matchLine(&work, line));
}

test "the trigram filter keeps a file that holds any one of the alternatives" {
    const q = try Query.regex(testing.allocator, "handleNodeExecutionError|continueExecution", null);
    defer q.deinit(testing.allocator);
    const only_second = try trigram.setOfAlloc(testing.allocator, "let continueExecution = true;");
    defer testing.allocator.free(only_second);
    const neither = try trigram.setOfAlloc(testing.allocator, "let stopExecution = true;");
    defer testing.allocator.free(neither);
    try testing.expect(q.mayMatchFile(only_second));
    try testing.expect(!q.mayMatchFile(neither));
}

test "regexSyntax names the first regex construct in a literal" {
    try testing.expectEqualStrings("|", regexSyntax("a|b(").?);
    try testing.expectEqualStrings("\\(", regexSyntax("continuesOnError\\(").?);
    try testing.expect(regexSyntax("continuesOnError(") == null);
}
