const std = @import("std");

pub fn longestLiteralChunk(pattern: []const u8) []const u8 {
    var best_start: usize = 0;
    var best_len: usize = 0;
    var start: usize = 0;
    var in_class = false;
    var i: usize = 0;
    while (i < pattern.len) {
        const c = pattern[i];
        if (c == '\\' and i + 1 < pattern.len) {
            if (i - start > best_len) {
                best_len = i - start;
                best_start = start;
            }
            i += 2;
            start = i;
            continue;
        }
        if (in_class) {
            if (c == ']') in_class = false;
            i += 1;
            continue;
        }
        const is_meta = switch (c) {
            '.', '^', '$', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|' => true,
            else => false,
        };
        if (c == '[') in_class = true;
        if (is_meta) {
            if (i - start > best_len) {
                best_len = i - start;
                best_start = start;
            }
            start = i + 1;
        }
        i += 1;
    }
    if (pattern.len - start > best_len) {
        best_len = pattern.len - start;
        best_start = start;
    }
    return pattern[best_start .. best_start + best_len];
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
