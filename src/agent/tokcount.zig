const std = @import("std");

pub const Kind = enum { code, prose, json };

pub const code_divisor_x100: usize = 320;
pub const prose_divisor_x100: usize = 380;

pub fn divisorX100(kind: Kind) usize {
    return switch (kind) {
        .code => code_divisor_x100,
        .prose, .json => prose_divisor_x100,
    };
}

pub fn estimateKind(text: []const u8, kind: Kind) usize {
    if (text.len == 0) return 0;
    const chars: usize = text.len;
    const scaled = chars * 100 + (divisorX100(kind) - 1);
    return scaled / divisorX100(kind);
}

pub fn estimate(text: []const u8) usize {
    return estimateKind(text, classify(text));
}

pub fn classify(text: []const u8) Kind {
    const head = trimLeadingSpace(text);
    if (head.len != 0 and (head[0] == '{' or head[0] == '[') and std.mem.indexOfScalar(u8, text, ':') != null) return .json;

    var symbols: usize = 0;
    var alpha: usize = 0;
    var spaces: usize = 0;
    for (text) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z' => alpha += 1,
            ' ', '\t', '\n', '\r' => spaces += 1,
            '{', '}', '(', ')', '[', ']', ';', '=', '<', '>', '/', '|', '&', '*', '_', '.', ':' => symbols += 1,
            else => {},
        }
    }
    const nonspace = text.len - spaces;
    if (nonspace == 0) return .prose;
    if (symbols * 100 >= nonspace * 18) return .code;
    return .prose;
}

fn trimLeadingSpace(text: []const u8) []const u8 {
    var i: usize = 0;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n' or text[i] == '\r')) i += 1;
    return text[i..];
}

const testing = std.testing;

test "empty text is zero tokens" {
    try testing.expectEqual(@as(usize, 0), estimate(""));
}

test "code is counted at the code ratio, prose at the prose ratio" {
    const code = "fn add(a: u32, b: u32) u32 { return a + b; }";
    const prose = "the quick brown fox jumps over the lazy dog again and again today";
    try testing.expectEqual(Kind.code, classify(code));
    try testing.expectEqual(Kind.prose, classify(prose));
    try testing.expectEqual(estimateKind(code, .code), estimate(code));
    try testing.expectEqual(estimateKind(prose, .prose), estimate(prose));
}

test "json-looking text classifies as json" {
    try testing.expectEqual(Kind.json, classify("{\n  \"model\": \"x\",\n  \"max_tokens\": 10\n}"));
    try testing.expectEqual(Kind.json, classify("[{ \"a\": 1 }]"));
}

test "estimate rounds up and scales with length" {
    try testing.expectEqual(@as(usize, 1), estimateKind("x", .code));
    const a = estimateKind("a" ** 320, .code);
    const b = estimateKind("a" ** 640, .code);
    try testing.expectEqual(@as(usize, 100), a);
    try testing.expectEqual(@as(usize, 200), b);
}

test "a dense symbol run reads as code, flowing words as prose" {
    try testing.expectEqual(Kind.code, classify("a[i]=b[j]+c[k]*(d-e)/f;{g}<h>|i&j"));
    try testing.expectEqual(Kind.prose, classify("this is a plain sentence with ordinary words and little punctuation"));
}
