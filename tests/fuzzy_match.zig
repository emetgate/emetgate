const std = @import("std");
const emetgate = @import("emetgate");
const fuzzy_match = emetgate.fuzzy_match;
const file_edit = emetgate.file_edit;
const batch_merge = emetgate.batch_merge;
const wire = emetgate.wire;

const testing = std.testing;
const gpa = testing.allocator;

const source_ts =
    \\export function total(a: number, b: number) {
    \\    // add the two
    \\    const sum = a + b;
    \\
    \\    /* keep it */
    \\    return sum;
    \\}
    \\// trailing note
    \\export const x = 1;
    \\
;

test "fuzzy_match: an exact old_string is replaced as before and the fallback stays unused" {
    fuzzy_match.reset();
    var matches: usize = 0;
    const out = try file_edit.replaceUniqueIn(gpa, "a.ts", source_ts, "const sum = a + b;", "const sum = b + a;", false, &matches);
    defer gpa.free(out);
    const exact = try file_edit.replaceUnique(gpa, source_ts, "const sum = a + b;", "const sum = b + a;", false, &matches);
    defer gpa.free(exact);
    try testing.expectEqualStrings(exact, out);
    try testing.expectEqual(@as(usize, 1), matches);
    try testing.expect(!fuzzy_match.wasUsed());
}

test "fuzzy_match: a dense old_string matches the commented original once and comments outside the range stay" {
    fuzzy_match.reset();
    var matches: usize = 0;
    const out = try file_edit.replaceUniqueIn(gpa, "src/a.ts", source_ts, "const sum = a + b;\n  return sum;", "return a + b;", false, &matches);
    defer gpa.free(out);
    try testing.expectEqualStrings(
        \\export function total(a: number, b: number) {
        \\    // add the two
        \\    return a + b;
        \\}
        \\// trailing note
        \\export const x = 1;
        \\
    , out);
    try testing.expectEqual(@as(usize, 1), matches);
    try testing.expect(fuzzy_match.wasUsed());
}

test "fuzzy_match: two places that match once whitespace and comments are ignored are refused as not found" {
    fuzzy_match.reset();
    const source = "let a = 1;\n// one\nlet b = 2;\n\nlet a = 1;\n    let b = 2;\n";
    var matches: usize = 0;
    try testing.expectError(error.OldStringNotFound, file_edit.replaceUniqueIn(gpa, "a.js", source, "let a = 1; let b = 2;", "x", false, &matches));
    try testing.expect(!fuzzy_match.wasUsed());
    var count: usize = 0;
    try testing.expect((try fuzzy_match.locate(gpa, source, "let a = 1; let b = 2;", fuzzy_match.syntaxFor("a.js"), &count)) == null);
    try testing.expectEqual(@as(usize, 2), count);
}

test "fuzzy_match: several exact matches stay an ambiguity error and never reach the fallback" {
    fuzzy_match.reset();
    var matches: usize = 0;
    try testing.expectError(error.OldStringNotUnique, file_edit.replaceUniqueIn(gpa, "a.js", "f();\nf();\n", "f();", "g();", false, &matches));
    try testing.expectEqual(@as(usize, 2), matches);
    try testing.expect(!fuzzy_match.wasUsed());
}

test "fuzzy_match: a comment-like sequence inside a string literal is kept as text" {
    const syntax = fuzzy_match.syntaxFor("a.ts");
    const normal = try fuzzy_match.normalize(gpa, "const a = \"x // y /* z\";   // gone\nconst b = '#';", syntax);
    defer normal.deinit(gpa);
    try testing.expectEqualStrings("const a = \"x // y /* z\"; const b = '#';", normal.text);

    const source = "const a = \"x // y\";\n// note\nconst b = 1;\n";
    var matches: usize = 0;
    const out = try file_edit.replaceUniqueIn(gpa, "a.ts", source, "const a = \"x // y\";\nconst b = 1;", "const c = 2;", false, &matches);
    defer gpa.free(out);
    try testing.expectEqualStrings("const c = 2;\n", out);

    const py = try fuzzy_match.normalize(gpa, "s = \"a # b\"  # gone\nt = '''x\n  # kept'''\n", fuzzy_match.syntaxFor("m.py"));
    defer py.deinit(gpa);
    try testing.expectEqualStrings("s = \"a # b\" t = '''x\n  # kept'''", py.text);
}

test "fuzzy_match: a dense LF old_string in a CRLF file is replaced with CRLF lines" {
    const source = "fn main() void {\r\n    // say it\r\n    a();\r\n    b();\r\n}\r\n";
    var matches: usize = 0;
    const out = try file_edit.replaceUniqueIn(gpa, "main.zig", source, "a();\n b();", "a();\n    c();", false, &matches);
    defer gpa.free(out);
    try testing.expectEqualStrings("fn main() void {\r\n    // say it\r\n    a();\r\n    c();\r\n}\r\n", out);
}

test "fuzzy_match: the reply carries the matched note as its first field" {
    const noted = try fuzzy_match.annotate(gpa, "{\"status\":\"committed\"}\nnote");
    defer gpa.free(noted);
    try testing.expectEqualStrings("{\"matched\":\"ignoring whitespace and comments\",\"status\":\"committed\"}\nnote", noted);
    const empty = try fuzzy_match.annotate(gpa, "{}");
    defer gpa.free(empty);
    try testing.expectEqualStrings("{\"matched\":\"ignoring whitespace and comments\"}", empty);
}

test "fuzzy_match: a batch item with no single match says the insensitive search ran too" {
    const parts = [_]batch_merge.Part{
        .{ .index = 0, .expected = .absent, .text = .{ .replace = .{ .old = "a", .new = "b" } } },
        .{ .index = 1, .expected = .absent, .text = .{ .replace = .{ .old = "missing", .new = "c" } } },
    };
    try testing.expectError(error.OldStringNotFound, batch_merge.merge(gpa, "a\n", "f.txt", &parts));
    try testing.expect(std.mem.indexOf(u8, wire.takeFixForTest(), fuzzy_match.also_tried) != null);
}
