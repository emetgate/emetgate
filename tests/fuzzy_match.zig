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

test "fuzzy_match: a dense old_string that sends the comment inside the range matches once and comments outside it stay" {
    fuzzy_match.reset();
    var matches: usize = 0;
    const out = try file_edit.replaceUniqueIn(gpa, "src/a.ts", source_ts, "const sum = a + b;\n  /* keep it */ return sum;", "return a + b;", false, &matches);
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
    const out = try file_edit.replaceUniqueIn(gpa, "a.ts", source, "const a = \"x // y\"; // note\nconst b = 1;", "const c = 2;", false, &matches);
    defer gpa.free(out);
    try testing.expectEqualStrings("const c = 2;\n", out);

    const py = try fuzzy_match.normalize(gpa, "s = \"a # b\"  # gone\nt = '''x\n  # kept'''\n", fuzzy_match.syntaxFor("m.py"));
    defer py.deinit(gpa);
    try testing.expectEqualStrings("s = \"a # b\" t = '''x\n  # kept'''", py.text);
}

test "fuzzy_match: a dense LF old_string in a CRLF file is replaced with CRLF lines" {
    const source = "fn main() void {\r\n    // say it\r\n    a();\r\n    b();\r\n}\r\n";
    var matches: usize = 0;
    const out = try file_edit.replaceUniqueIn(gpa, "main.zig", source, "a();\nb();", "a();\nc();", false, &matches);
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

test "fuzzy_match: F02 a JavaScript comment inside the range that old_string leaves out is never deleted; the edit is refused" {
    fuzzy_match.reset();
    const source = "function a() {\n  first();\n  // IMPORTANT: keep this note\n  second();\n}\n";
    var matches: usize = 0;
    try testing.expectError(error.OldStringNotFound, file_edit.replaceUniqueIn(gpa, "a.js", source, "  first();\n  second();", "  first();\n  third();", false, &matches));
    try testing.expectEqual(fuzzy_match.Refusal.comments, fuzzy_match.refusal().?);
    try testing.expect(!fuzzy_match.wasUsed());
    const why = fuzzy_match.notFoundReason();
    try testing.expect(std.mem.indexOf(u8, why, "delete") != null);
    try testing.expect(std.mem.indexOf(u8, why, "emetgate_read_symbol") != null);

    const b_js = "function mul(a, b) {\n  // multiply\n  return a * b;\n}\n";
    try testing.expectError(error.OldStringNotFound, file_edit.replaceUniqueIn(gpa, "b.js", b_js, "function mul(a, b) {\n    return a * b;\n}", "function mul(a, b) {\n  return b * a;\n}", false, &matches));
    try testing.expectEqual(fuzzy_match.Refusal.comments, fuzzy_match.refusal().?);
}

test "fuzzy_match: F04 a YAML comment inside the range that old_string leaves out is never deleted; the edit is refused" {
    fuzzy_match.reset();
    const source = "alpha: 1\n# do not remove: license key below\nbeta: 2\n";
    var matches: usize = 0;
    try testing.expectError(error.OldStringNotFound, file_edit.replaceUniqueIn(gpa, "conf.yaml", source, "alpha: 1\nbeta: 2", "alpha: 1\nbeta: 3", false, &matches));
    try testing.expectEqual(fuzzy_match.Refusal.comments, fuzzy_match.refusal().?);
    try testing.expect(!fuzzy_match.wasUsed());
}

test "fuzzy_match: F06 Python lines whose nesting differs from old_string's are refused, never collapsed" {
    fuzzy_match.reset();
    const source = "def f(x):\n    if x:\n        a = 1\n    b = 2\n    return x\n";
    var matches: usize = 0;
    try testing.expectError(error.OldStringNotFound, file_edit.replaceUniqueIn(gpa, "p.py", source, "if x:\n    a = 1\n    b = 2", "if x:\n    a = 1\n    c = 3", false, &matches));
    try testing.expectEqual(fuzzy_match.Refusal.indentation, fuzzy_match.refusal().?);
    try testing.expect(!fuzzy_match.wasUsed());
    try testing.expect(std.mem.indexOf(u8, fuzzy_match.notFoundReason(), "indent") != null);
}

test "fuzzy_match: Python lines shifted by one uniform indentation are re-indented to the file's" {
    fuzzy_match.reset();
    const source = "def f(x):\n    if x:\n        a = 1\n        b = 2\n    return x\n";
    var matches: usize = 0;
    const out = try file_edit.replaceUniqueIn(gpa, "p.py", source, "if x:\n    a = 1\n    b = 2", "if x:\n    a = 1\n    c = 3", false, &matches);
    defer gpa.free(out);
    try testing.expectEqualStrings("def f(x):\n    if x:\n        a = 1\n        c = 3\n    return x\n", out);
    try testing.expect(fuzzy_match.wasUsed());

    const whole = try file_edit.replaceUniqueIn(gpa, "p.py", source, "if x:\n    a = 1\n    b = 2\n", "if x:\n    a = 1\n\n    c = 3\n", false, &matches);
    defer gpa.free(whole);
    try testing.expectEqualStrings("def f(x):\n    if x:\n        a = 1\n\n        c = 3\n    return x\n", whole);
}

test "fuzzy_match: an old_string indented deeper than the file is shifted back from the line's start" {
    fuzzy_match.reset();
    const source = "function a() {\n  first();\n  second();\n}\n";
    var matches: usize = 0;
    const out = try file_edit.replaceUniqueIn(gpa, "a.js", source, "    first();\n    second();", "    first();\n    third();", false, &matches);
    defer gpa.free(out);
    try testing.expectEqualStrings("function a() {\n  first();\n  third();\n}\n", out);

    try testing.expectError(error.OldStringNotFound, file_edit.replaceUniqueIn(gpa, "a.js", source, "    first();\n    second();", "first();\n  third();", false, &matches));
    try testing.expectEqual(fuzzy_match.Refusal.indentation, fuzzy_match.refusal().?);
}

test "fuzzy_match: a batch item the fallback refuses says why in its fix" {
    const parts = [_]batch_merge.Part{
        .{ .index = 0, .expected = .absent, .text = .{ .replace = .{ .old = "alpha: 1\nbeta: 2", .new = "beta: 3" } } },
    };
    try testing.expectError(error.OldStringNotFound, batch_merge.merge(gpa, "alpha: 1\n# keep\nbeta: 2\n", "c.yaml", &parts));
    const fix = wire.takeFixForTest();
    try testing.expect(std.mem.indexOf(u8, fix, "comments") != null);
    try testing.expect(std.mem.indexOf(u8, fix, fuzzy_match.also_tried) == null);
}
