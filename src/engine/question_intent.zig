const std = @import("std");
const lexicon_mod = @import("question_lexicon.zig");
const terms = @import("question_terms.zig");

const Lexicon = lexicon_mod.Lexicon;
pub const Intent = lexicon_mod.Intent;

pub const max_gap: usize = 4;

pub const priority = [_]Intent{ .callers, .callees, .where_defined, .decides, .flow, .explain };

pub const Match = struct {
    intent: Intent,
    pattern: ?usize,
    length: usize,
};

fn rank(intent: Intent) usize {
    for (priority, 0..) |p, i| if (p == intent) return i;
    return priority.len;
}

fn tokenMatches(pattern: lexicon_mod.PatternToken, word: []const u8) bool {
    for (pattern.alternatives) |alt| {
        if (alt.prefix) {
            if (std.mem.startsWith(u8, word, alt.text)) return true;
        } else if (std.mem.eql(u8, word, alt.text)) return true;
    }
    return false;
}

pub fn matches(pattern: lexicon_mod.Pattern, words: []const []const u8) bool {
    if (pattern.tokens.len == 0) return false;
    var start: usize = 0;
    while (start < words.len) : (start += 1) {
        if (!tokenMatches(pattern.tokens[0], words[start])) continue;
        var at = start;
        var ok = true;
        for (pattern.tokens[1..]) |token| {
            var next = at + 1;
            const limit = @min(words.len, at + 2 + max_gap);
            while (next < limit and !tokenMatches(token, words[next])) next += 1;
            if (next >= limit) {
                ok = false;
                break;
            }
            at = next;
        }
        if (ok) return true;
    }
    return false;
}

pub fn classifyWords(lex: *const Lexicon, words: []const []const u8) Match {
    var best: Match = .{ .intent = .explain, .pattern = null, .length = 0 };
    for (lex.patterns, 0..) |pattern, i| {
        if (!matches(pattern, words)) continue;
        const better = pattern.tokens.len > best.length or
            (pattern.tokens.len == best.length and rank(pattern.intent) < rank(best.intent));
        if (better) best = .{ .intent = pattern.intent, .pattern = i, .length = pattern.tokens.len };
    }
    return best;
}

pub fn classify(arena: std.mem.Allocator, lex: *const Lexicon, tokens: []const terms.Token) !Match {
    const words = try arena.alloc([]const u8, tokens.len);
    for (tokens, words) |t, *w| w.* = t.folded;
    return classifyWords(lex, words);
}

const testing = std.testing;

const english =
    \\suffix n s
    \\noun cat = feline
    \\intent callers who call*
    \\intent callers where is call*
    \\intent callees what does call
    \\intent where_defined where is defined
    \\intent decides decide*
    \\intent decides which code decide*
    \\intent decides whether
    \\intent flow how flow*
    \\intent flow what steps
    \\
;

fn intentOf(arena: std.mem.Allocator, lex: *const Lexicon, question: []const u8) !Intent {
    const tokens = try terms.tokenize(arena, lex, question);
    return (try classify(arena, lex, tokens)).intent;
}

test "question intent: english patterns pick callers, callees, definitions, decisions and flow, and the rest is explain" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lex = try Lexicon.parse(testing.allocator, english);
    defer lex.deinit();
    try testing.expectEqual(Intent.callers, try intentOf(arena, lex, "Who calls handleNodeExecutionError?"));
    try testing.expectEqual(Intent.callers, try intentOf(arena, lex, "Where is the retry helper called?"));
    try testing.expectEqual(Intent.callees, try intentOf(arena, lex, "What does runNode call?"));
    try testing.expectEqual(Intent.where_defined, try intentOf(arena, lex, "Where is the default timeout defined?"));
    try testing.expectEqual(Intent.decides, try intentOf(arena, lex, "Which code decides whether a failed node stops the workflow?"));
    try testing.expectEqual(Intent.flow, try intentOf(arena, lex, "How does an execution flow through the engine?"));
    try testing.expectEqual(Intent.explain, try intentOf(arena, lex, "What is the purpose of the credentials helper?"));
}

test "question intent: the longer pattern wins and a tie goes to the earlier intent in priority order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lex = try Lexicon.parse(testing.allocator, english);
    defer lex.deinit();
    try testing.expectEqual(Intent.decides, try intentOf(arena, lex, "Which code decides how steps flow?"));
    try testing.expectEqual(Intent.callers, try intentOf(arena, lex, "Who calls the code that decides?"));
    try testing.expectEqual(Intent.callers, try intentOf(arena, lex, "How does the data flow and who calls it?"));
    try testing.expectEqual(Intent.explain, try intentOf(arena, lex, "Who knows, it is a long way until we call it"));
}

test "question lexicon checks: every intent check sentence is classified to its listed intent" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lex = try Lexicon.parse(testing.allocator, lexicon_mod.default_text);
    defer lex.deinit();
    var checked: usize = 0;
    for (lex.checks) |check| {
        const c = switch (check) {
            .intent => |i| i,
            else => continue,
        };
        const got = try intentOf(arena, lex, c.sentence);
        if (got != c.intent) {
            std.debug.print("{s}: expected {t}, got {t}\n", .{ c.sentence, c.intent, got });
            return error.TestUnexpectedResult;
        }
        checked += 1;
    }
    try testing.expect(checked >= 10);
}
