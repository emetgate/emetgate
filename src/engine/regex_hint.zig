const std = @import("std");

pub fn longestLiteralChunk(pattern: []const u8) []const u8 {
    if (hasTopLevelAlternation(pattern)) return pattern[0..0];
    var best: Run = .{};
    var run: ?usize = null;
    var depth: usize = 0;
    var in_class = false;
    var i: usize = 0;
    while (i < pattern.len) {
        const c = pattern[i];
        if (in_class) {
            if (c == '\\') i += 1;
            if (c == ']') in_class = false;
            i += 1;
            continue;
        }
        switch (c) {
            '\\' => {
                best.close(run, i);
                run = null;
                i += 2;
            },
            '[' => {
                best.close(run, i);
                run = null;
                in_class = true;
                i += 1;
            },
            '(' => {
                best.close(run, i);
                run = null;
                depth += 1;
                i += 1;
            },
            ')' => {
                best.close(run, i);
                run = null;
                depth -|= 1;
                i += 1;
            },
            '?', '*', '{' => {
                if (run) |r| {
                    if (i > r) best.close(run, i - 1);
                }
                run = null;
                if (c == '{') {
                    i = if (std.mem.indexOfScalarPos(u8, pattern, i, '}')) |close| close + 1 else pattern.len;
                } else i += 1;
            },
            '.', '^', '$', '+', '}', '|' => {
                best.close(run, i);
                run = null;
                i += 1;
            },
            else => {
                if (run == null and depth == 0) run = i;
                i += 1;
            },
        }
    }
    best.close(run, pattern.len);
    return pattern[best.start .. best.start + best.len];
}

const Run = struct {
    start: usize = 0,
    len: usize = 0,

    fn close(self: *Run, run: ?usize, end: usize) void {
        const r = run orelse return;
        if (end > r and end - r > self.len) {
            self.start = r;
            self.len = end - r;
        }
    }
};

pub const max_alternatives = 64;

pub fn requiredLiterals(pattern: []const u8, out: *[max_alternatives][]const u8) []const []const u8 {
    const body = unwrapGroup(pattern);
    if (!hasTopLevelAlternation(body)) {
        const one = longestLiteralChunk(pattern);
        if (one.len == 0) return out[0..0];
        out[0] = one;
        return out[0..1];
    }
    var n: usize = 0;
    var start: usize = 0;
    var depth: usize = 0;
    var in_class = false;
    var i: usize = 0;
    while (i <= body.len) : (i += 1) {
        const at_end = i == body.len;
        if (!at_end) {
            const c = body[i];
            if (c == '\\') {
                i += 1;
                continue;
            }
            if (in_class) {
                if (c == ']') in_class = false;
                continue;
            }
            switch (c) {
                '[' => in_class = true,
                '(' => depth += 1,
                ')' => depth -|= 1,
                else => {},
            }
            if (c != '|' or depth != 0) continue;
        }
        if (n == out.len) return out[0..0];
        const chunk = longestLiteralChunk(body[start..i]);
        if (chunk.len == 0) return out[0..0];
        out[n] = chunk;
        n += 1;
        start = i + 1;
    }
    return out[0..n];
}

fn unwrapGroup(pattern: []const u8) []const u8 {
    if (pattern.len < 2 or pattern[0] != '(' or pattern[pattern.len - 1] != ')') return pattern;
    var depth: usize = 0;
    var in_class = false;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        const c = pattern[i];
        if (c == '\\') {
            i += 1;
            continue;
        }
        if (in_class) {
            if (c == ']') in_class = false;
            continue;
        }
        switch (c) {
            '[' => in_class = true,
            '(' => depth += 1,
            ')' => {
                depth -|= 1;
                if (depth == 0 and i != pattern.len - 1) return pattern;
            },
            else => {},
        }
    }
    const inner = pattern[1 .. pattern.len - 1];
    return if (std.mem.startsWith(u8, inner, "?:")) inner[2..] else inner;
}

fn hasTopLevelAlternation(pattern: []const u8) bool {
    var depth: usize = 0;
    var in_class = false;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        const c = pattern[i];
        if (c == '\\') {
            i += 1;
            continue;
        }
        if (in_class) {
            if (c == ']') in_class = false;
            continue;
        }
        switch (c) {
            '[' => in_class = true,
            '(' => depth += 1,
            ')' => depth -|= 1,
            '|' => if (depth == 0) return true,
            else => {},
        }
    }
    return false;
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
    for ([_][]const u8{ "foo|.*", "x|", "|x", "a.c", "(foo|bar)?" }) |pattern| {
        errdefer std.debug.print("{s}\n", .{pattern});
        const got = requiredLiterals(pattern, &buf);
        if (std.mem.eql(u8, pattern, "a.c")) {
            try testing.expectEqual(@as(usize, 1), got.len);
            continue;
        }
        try testing.expectEqual(@as(usize, 0), got.len);
    }
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
    };
    for (cases) |case| {
        const re = try regex.Regex.compile(testing.allocator, case.pattern, null);
        defer re.deinit(testing.allocator);
        const literals = requiredLiterals(case.pattern, &buf);
        try testing.expect(literals.len != 0);
        for (case.lines) |line| {
            var budget: u64 = 1_000_000;
            try testing.expect(try re.isMatch(testing.allocator, line, &budget));
            var found = false;
            for (literals) |lit| {
                if (std.mem.indexOf(u8, line, lit) != null) found = true;
            }
            errdefer std.debug.print("{s} on {s}\n", .{ case.pattern, line });
            try testing.expect(found);
        }
    }
}

test "every longestLiteralChunk hint occurs in every line the regex matches" {
    const regex = @import("regex.zig");
    const Case = struct { pattern: []const u8, lines: []const []const u8 };
    const cases = [_]Case{
        .{ .pattern = "colou?r", .lines = &.{ "color", "colour", "a colour b" } },
        .{ .pattern = "foo|bar", .lines = &.{ "bar", "foo" } },
        .{ .pattern = "(ab)?cd+e", .lines = &.{ "cde", "abcdde" } },
        .{ .pattern = "req\\.(params|query)", .lines = &.{ "req.params", "req.query.x" } },
    };
    for (cases) |case| {
        const re = try regex.Regex.compile(testing.allocator, case.pattern, null);
        defer re.deinit(testing.allocator);
        const hint = longestLiteralChunk(case.pattern);
        for (case.lines) |line| {
            var budget: u64 = 1_000_000;
            try testing.expect(try re.isMatch(testing.allocator, line, &budget));
            try testing.expect(std.mem.indexOf(u8, line, hint) != null);
        }
    }
}
