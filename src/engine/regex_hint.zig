const std = @import("std");

pub const max_alternatives = 64;

const Kind = enum { char, escape, class, open, close, optional, repeat, alternation, meta };

const Token = struct { kind: Kind, start: usize, end: usize };

const Scanner = struct {
    pattern: []const u8,
    pos: usize = 0,

    fn next(self: *Scanner) ?Token {
        const p = self.pattern;
        const start = self.pos;
        if (start >= p.len) return null;
        const kind: Kind = switch (p[start]) {
            '\\' => blk: {
                self.pos = @min(p.len, start + 1);
                self.pos = charEnd(p, self.pos);
                break :blk .escape;
            },
            '[' => blk: {
                self.pos = classEnd(p, start);
                break :blk .class;
            },
            '(' => blk: {
                self.pos = start + 1;
                break :blk .open;
            },
            ')' => blk: {
                self.pos = start + 1;
                break :blk .close;
            },
            '?', '*' => blk: {
                self.pos = start + 1;
                break :blk .optional;
            },
            '{' => blk: {
                self.pos = if (std.mem.indexOfScalarPos(u8, p, start, '}')) |close| close + 1 else p.len;
                break :blk .optional;
            },
            '+' => blk: {
                self.pos = start + 1;
                break :blk .repeat;
            },
            '|' => blk: {
                self.pos = start + 1;
                break :blk .alternation;
            },
            '.', '^', '$', '}' => blk: {
                self.pos = start + 1;
                break :blk .meta;
            },
            else => blk: {
                self.pos = charEnd(p, start);
                break :blk .char;
            },
        };
        return .{ .kind = kind, .start = start, .end = self.pos };
    }
};

fn charEnd(p: []const u8, i: usize) usize {
    if (i >= p.len) return p.len;
    var end = i + 1;
    while (end < p.len and p[end] & 0xC0 == 0x80) end += 1;
    return end;
}

fn classEnd(p: []const u8, open: usize) usize {
    var i = open + 1;
    if (i < p.len and p[i] == '^') i += 1;
    if (i < p.len and p[i] == ']') i += 1;
    while (i < p.len) {
        switch (p[i]) {
            '\\' => i += 2,
            ']' => return i + 1,
            '[' => {
                if (i + 1 < p.len and (p[i + 1] == ':' or p[i + 1] == '.' or p[i + 1] == '=')) {
                    const close = [2]u8{ p[i + 1], ']' };
                    if (std.mem.indexOfPos(u8, p, i + 2, &close)) |end| {
                        i = end + 2;
                        continue;
                    }
                }
                i += 1;
            },
            else => i += 1,
        }
    }
    return p.len;
}

fn plain(pattern: []const u8) bool {
    var scanner: Scanner = .{ .pattern = pattern };
    while (scanner.next()) |t| switch (t.kind) {
        .escape => {
            if (t.end - t.start < 2) return false;
            const c = pattern[t.start + 1];
            if (std.ascii.isDigit(c)) return false;
            if (std.mem.indexOfScalar(u8, "xocNgkpPQ", c) != null) return false;
        },
        .open => {
            if (t.end >= pattern.len) continue;
            if (pattern[t.end] == '*') return false;
            if (pattern[t.end] != '?' or t.end + 1 >= pattern.len) continue;
            if (std.mem.indexOfScalar(u8, "imnsxJUar^-)", pattern[t.end + 1]) != null) return false;
        },
        else => {},
    };
    return true;
}

pub fn longestLiteralChunk(pattern: []const u8) []const u8 {
    if (!plain(pattern)) return pattern[0..0];
    return chunk(pattern);
}

fn chunk(pattern: []const u8) []const u8 {
    var best: []const u8 = pattern[0..0];
    var run: ?usize = null;
    var last: usize = 0;
    var depth: usize = 0;
    var scanner: Scanner = .{ .pattern = pattern };
    while (scanner.next()) |t| {
        switch (t.kind) {
            .char => {
                if (depth == 0 and run == null) run = t.start;
                last = t.start;
                continue;
            },
            .alternation => if (depth == 0) return pattern[0..0],
            .optional => if (run) |r| keep(&best, pattern[r..last]),
            .repeat => if (run) |r| keep(&best, pattern[r..t.start]),
            else => if (run) |r| keep(&best, pattern[r..t.start]),
        }
        run = null;
        switch (t.kind) {
            .open => depth += 1,
            .close => depth -|= 1,
            else => {},
        }
    }
    if (run) |r| keep(&best, pattern[r..]);
    return best;
}

fn keep(best: *[]const u8, candidate: []const u8) void {
    if (candidate.len > best.len) best.* = candidate;
}

pub fn requiredLiterals(pattern: []const u8, out: *[max_alternatives][]const u8) []const []const u8 {
    if (!plain(pattern)) return out[0..0];
    const body = unwrapGroup(pattern);
    var n: usize = 0;
    var start: usize = 0;
    var depth: usize = 0;
    var scanner: Scanner = .{ .pattern = body };
    while (true) {
        const t = scanner.next();
        if (t) |tok| {
            switch (tok.kind) {
                .open => depth += 1,
                .close => depth -|= 1,
                else => {},
            }
            if (tok.kind != .alternation or depth != 0) continue;
        }
        const end = if (t) |tok| tok.start else body.len;
        if (n == out.len) return out[0..0];
        const literal = chunk(body[start..end]);
        if (literal.len == 0) return out[0..0];
        out[n] = literal;
        n += 1;
        start = scanner.pos;
        if (t == null) return out[0..n];
    }
}

fn unwrapGroup(pattern: []const u8) []const u8 {
    if (pattern.len < 2 or pattern[0] != '(' or pattern[pattern.len - 1] != ')') return pattern;
    const noncapturing = std.mem.startsWith(u8, pattern, "(?:");
    if (!noncapturing and pattern.len > 1 and (pattern[1] == '?' or pattern[1] == '*')) return pattern;
    var depth: usize = 0;
    var scanner: Scanner = .{ .pattern = pattern };
    while (scanner.next()) |t| switch (t.kind) {
        .open => depth += 1,
        .close => {
            depth -|= 1;
            if (depth == 0 and t.end != pattern.len) return pattern;
        },
        else => {},
    };
    return pattern[if (noncapturing) 3 else 1 .. pattern.len - 1];
}

const testing = std.testing;

test "longestLiteralChunk returns the whole pattern when it has no metacharacters" {
    try testing.expectEqualStrings("hello", longestLiteralChunk("hello"));
}

test "longestLiteralChunk picks the longer side of an alternation-free pattern" {
    try testing.expectEqualStrings("loadPending", longestLiteralChunk("^loadPending\\("));
}

test "longestLiteralChunk returns an empty slice for a pattern with no literal run" {
    try testing.expectEqualStrings("", longestLiteralChunk(".*"));
}

test "longestLiteralChunk skips over a character class rather than splitting inside it" {
    try testing.expectEqualStrings("prefix", longestLiteralChunk("prefix[a-z]+suffix"));
    try testing.expectEqualStrings("suffix_", longestLiteralChunk("ab[]x]suffix_"));
    try testing.expectEqualStrings("suffix_", longestLiteralChunk("ab[^]x]suffix_"));
    try testing.expectEqualStrings("suffix_", longestLiteralChunk("ab[[:alpha:]]suffix_"));
}

test "longestLiteralChunk never returns text a match can do without" {
    try testing.expectEqualStrings("", longestLiteralChunk("foo|bar"));
    try testing.expectEqualStrings("colo", longestLiteralChunk("colou?r"));
    try testing.expectEqualStrings("def", longestLiteralChunk("(abcdef)?def"));
    try testing.expectEqualStrings("req", longestLiteralChunk("req\\.(params|query)"));
    try testing.expectEqualStrings("tail", longestLiteralChunk("x*tail"));
    try testing.expectEqualStrings("ab", longestLiteralChunk("abc{0,2}"));
    try testing.expectEqualStrings("abc", longestLiteralChunk("abc+"));
    try testing.expectEqualStrings("", longestLiteralChunk("(a|b)"));
    try testing.expectEqualStrings("end", longestLiteralChunk("[|]end"));
    try testing.expectEqualStrings("ab", longestLiteralChunk("abş?"));
    try testing.expectEqualStrings("tail", longestLiteralChunk("\\şx?tail"));
}

test "longestLiteralChunk gives nothing for constructs that change what a literal means" {
    for ([_][]const u8{ "(?i)hello", "a(?x) b c", "(?-i)abc", "(?^)abc", "(*UCP)abc", "a(*ACCEPT)bcd", "\\x41bcd", "\\x{41}bcd", "\\p{Lu}bcd", "\\pLbcd", "\\k<n>abc", "\\g{1}abc", "\\1abc", "\\Qa|b\\E", "\\N{U+41}bcd", "\\cAbcd", "\\o{101}bcd" }) |pattern| {
        errdefer std.debug.print("{s}\n", .{pattern});
        try testing.expectEqualStrings("", longestLiteralChunk(pattern));
    }
}

test "requiredLiterals gives one literal per top-level branch, also inside one enclosing group" {
    var buf: [max_alternatives][]const u8 = undefined;
    const Case = struct { pattern: []const u8, literals: []const []const u8 };
    const cases = [_]Case{
        .{ .pattern = "handleNodeExecutionError|continueExecution", .literals = &.{ "handleNodeExecutionError", "continueExecution" } },
        .{ .pattern = "continuesOnError\\(|onError ===|executionData\\.node\\.onError", .literals = &.{ "continuesOnError", "onError ===", "executionData" } },
        .{ .pattern = "(isPlaceholderString|PLACEHOLDER_VALUE)", .literals = &.{ "isPlaceholderString", "PLACEHOLDER_VALUE" } },
        .{ .pattern = "(?:ab|cd)", .literals = &.{ "ab", "cd" } },
        .{ .pattern = "req\\.(params|query)", .literals = &.{"req"} },
        .{ .pattern = "(a|b)?cde", .literals = &.{"cde"} },
        .{ .pattern = "[|]x|y", .literals = &.{ "x", "y" } },
        .{ .pattern = "\\.pruneData\\b|softDelete", .literals = &.{ "pruneData", "softDelete" } },
        .{ .pattern = "<button\\b", .literals = &.{"<button"} },
    };
    for (cases) |case| {
        const got = requiredLiterals(case.pattern, &buf);
        errdefer std.debug.print("{s}\n", .{case.pattern});
        try testing.expectEqual(case.literals.len, got.len);
        for (case.literals, got) |want, have| try testing.expectEqualStrings(want, have);
    }
}

test "requiredLiterals gives nothing when one branch can match without any literal" {
    var buf: [max_alternatives][]const u8 = undefined;
    for ([_][]const u8{ "foo|.*", "x|", "|x", "(foo|bar)?", "(?=ab|cd)", "(?<n>ab|cd)x?", "(?i:ab|cd)", "(?|ab|cd)" }) |pattern| {
        errdefer std.debug.print("{s}\n", .{pattern});
        try testing.expectEqual(@as(usize, 0), requiredLiterals(pattern, &buf).len);
    }
    try testing.expectEqual(@as(usize, 1), requiredLiterals("a.c", &buf).len);
}

test "every line a regex matches contains one of its required literals" {
    const regex = @import("regex.zig");
    var buf: [max_alternatives][]const u8 = undefined;
    const Case = struct { pattern: []const u8, lines: []const []const u8 };
    const cases = [_]Case{
        .{ .pattern = "handleNodeExecutionError|continueExecution", .lines = &.{ "a continueExecution b", "x.handleNodeExecutionError(" } },
        .{ .pattern = "continuesOnError\\(|onError ===", .lines = &.{ "continuesOnError(x)", "if (onError === 'y')" } },
        .{ .pattern = "(isPlaceholderString|PLACEHOLDER_VALUE)", .lines = &.{"PLACEHOLDER_VALUE = 1"} },
        .{ .pattern = "colou?r|hue", .lines = &.{ "color", "colour", "hue" } },
        .{ .pattern = "ab[]x]suffix", .lines = &.{ "ab]suffix", "abxsuffix" } },
        .{ .pattern = "ab[[:digit:]]+end", .lines = &.{"ab12end"} },
        .{ .pattern = "abş?c", .lines = &.{ "abc", "abşc" } },
        .{ .pattern = "(?i)hello", .lines = &.{"HELLO"} },
        .{ .pattern = "\\x41BC", .lines = &.{"ABC"} },
        .{ .pattern = "(?<=x)foo|bar(?=y)", .lines = &.{ "xfoo", "bary" } },
    };
    for (cases) |case| {
        const re = try regex.Regex.compileCounted(testing.allocator, case.pattern, null);
        defer re.deinit(testing.allocator);
        const literals = requiredLiterals(case.pattern, &buf);
        for (case.lines) |line| {
            var budget: u64 = 1_000_000;
            errdefer std.debug.print("{s} on {s}\n", .{ case.pattern, line });
            try testing.expect(try re.isMatch(testing.allocator, line, &budget));
            if (literals.len == 0) continue;
            var found = false;
            for (literals) |lit| {
                if (std.mem.indexOf(u8, line, lit) != null) found = true;
            }
            try testing.expect(found);
        }
    }
}
