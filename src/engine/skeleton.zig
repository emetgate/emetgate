const std = @import("std");
const ts = @import("tree_sitter.zig");
const traversal = @import("traversal.zig");
const symbol = @import("symbol.zig");
const Profile = @import("lang/profile.zig").Profile;
const alloc_bridge = @import("alloc_bridge.zig");
const test_util = @import("test_util.zig");

pub const Error = error{ SourceHasErrors, SkeletonInvalid } || std.mem.Allocator.Error || ts.Error;

const Terminator = enum {
    bodyless,
    empty_body,

    fn text(self: Terminator, profile: *const Profile) []const u8 {
        return switch (self) {
            .bodyless => profile.bodyless_terminator.?,
            .empty_body => profile.empty_body,
        };
    }
};

const Cut = struct {
    start: u32,
    end: u32,
    text: []const u8,
};

pub fn skeletonize(gpa: std.mem.Allocator, parser: ts.Parser, profile: *const Profile, tree: ts.Tree) Error![]u8 {
    if (tree.root().hasError()) return error.SourceHasErrors;

    const functions = try symbol.collectFunctions(gpa, profile, tree);
    defer gpa.free(functions);

    var out: std.ArrayList(u8) = try .initCapacity(gpa, tree.source.len);
    errdefer out.deinit(gpa);

    var copied: u32 = 0;
    for (functions) |function| {
        const cut = planCut(profile, tree.source, function) orelse continue;
        if (cut.start < copied) continue;
        try out.appendSlice(gpa, tree.source[copied..cut.start]);
        try out.appendSlice(gpa, cut.text);
        copied = cut.end;
    }
    try out.appendSlice(gpa, tree.source[copied..]);

    const skeleton = try out.toOwnedSlice(gpa);
    errdefer gpa.free(skeleton);
    try verify(parser, tree.language(), skeleton);
    return skeleton;
}

pub fn compact(gpa: std.mem.Allocator, parser: ts.Parser, profile: *const Profile, tree: ts.Tree) Error![]u8 {
    const skeleton = try skeletonize(gpa, parser, profile, tree);
    defer gpa.free(skeleton);
    return foldComments(gpa, parser, profile, tree.language(), skeleton);
}

const Span = struct { start: u32, end: u32 };

pub fn foldComments(gpa: std.mem.Allocator, parser: ts.Parser, profile: *const Profile, language: *const ts.Language, source: []const u8) Error![]u8 {
    const tree = try parser.parseIn(language, source);
    defer tree.deinit();
    var comments: std.ArrayList(Span) = .empty;
    defer comments.deinit(gpa);
    var walker = traversal.Walker.init(tree.root());
    defer walker.deinit();
    while (walker.next()) |entry| {
        if (!profile.isComment(entry.node.kind())) continue;
        walker.skipChildren();
        try comments.append(gpa, .{ .start = entry.node.startByte(), .end = entry.node.endByte() });
    }

    var out: std.ArrayList(u8) = try .initCapacity(gpa, source.len);
    errdefer out.deinit(gpa);
    var copied: u32 = 0;
    var i: usize = 0;
    while (i < comments.items.len) {
        const first = comments.items[i];
        var last = first;
        i += 1;
        while (i < comments.items.len and isBlank(source[last.end..comments.items[i].start])) : (i += 1) last = comments.items[i];
        if (first.start < copied) continue;
        const kept = foldOne(source[first.start..first.end]);
        if (kept.text.len == 0) {
            out.appendSliceAssumeCapacity(source[copied..lineStartIfBlank(source, first.start)]);
            copied = afterNewline(source, last.end);
            continue;
        }
        out.appendSliceAssumeCapacity(source[copied..first.start]);
        out.appendSliceAssumeCapacity(kept.open);
        out.appendSliceAssumeCapacity(kept.text);
        out.appendSliceAssumeCapacity(kept.close);
        copied = last.end;
    }
    out.appendSliceAssumeCapacity(source[copied..]);
    const folded = try out.toOwnedSlice(gpa);
    const check = try parser.parseIn(language, folded);
    defer check.deinit();
    if (!check.root().hasError()) return folded;
    gpa.free(folded);
    return gpa.dupe(u8, source);
}

const Folded = struct { open: []const u8 = "", text: []const u8, close: []const u8 = "" };

fn foldOne(comment: []const u8) Folded {
    const newline = std.mem.indexOfScalar(u8, comment, '\n') orelse return .{ .text = comment };
    if (!std.mem.startsWith(u8, comment, "/*")) return .{ .text = std.mem.trimEnd(u8, comment[0..newline], " \t\r") };
    const open = if (std.mem.startsWith(u8, comment, "/**")) "/** " else "/* ";
    const inner = if (std.mem.endsWith(u8, comment, "*/")) comment[0 .. comment.len - 2] else comment;
    var lines = std.mem.splitScalar(u8, inner, '\n');
    while (lines.next()) |line| {
        var text = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, text, "/*")) text = text[2..];
        text = std.mem.trim(u8, std.mem.trimStart(u8, text, "*!"), " \t\r");
        if (text.len != 0) return .{ .open = open, .text = text, .close = " */" };
    }
    return .{ .text = "" };
}

fn isBlank(bytes: []const u8) bool {
    for (bytes) |c| if (!std.ascii.isWhitespace(c)) return false;
    return true;
}

fn lineStartIfBlank(source: []const u8, at: u32) u32 {
    var i = at;
    while (i > 0 and (source[i - 1] == ' ' or source[i - 1] == '\t')) i -= 1;
    return if (i == 0 or source[i - 1] == '\n') i else at;
}

fn afterNewline(source: []const u8, at: u32) u32 {
    var i = at;
    while (i < source.len and (source[i] == ' ' or source[i] == '\t' or source[i] == '\r')) i += 1;
    return if (i < source.len and source[i] == '\n') i + 1 else at;
}

fn expressionCut(profile: *const Profile, source: []const u8, function: symbol.Function) ?Cut {
    const clause = profile.expression_body orelse return null;
    if (!std.mem.eql(u8, clause, function.body.kind())) return null;
    const body_start = function.body.startByte();
    const start = if (followsComment(profile, function.body)) body_start else trimTrailingWhitespace(source, body_start);
    const entry = profile.functionNode(function.node.kind()) orelse return null;
    const replacement = entry.skeleton orelse return .{ .start = start, .end = function.body.endByte(), .text = "" };
    return .{ .start = start, .end = function.node.endByte(), .text = replacement };
}

fn planCut(profile: *const Profile, source: []const u8, function: symbol.Function) ?Cut {
    if (expressionCut(profile, source, function)) |cut| return cut;
    if (!std.mem.eql(u8, profile.block, function.body.kind())) return null;
    const terminator: Terminator = if (followsComment(profile, function.body)) .empty_body else terminatorFor(profile, function);
    const body_start = function.body.startByte();
    return .{
        .start = if (terminator == .bodyless) trimTrailingWhitespace(source, body_start) else body_start,
        .end = function.body.endByte(),
        .text = terminator.text(profile),
    };
}

fn terminatorFor(profile: *const Profile, function: symbol.Function) Terminator {
    if (profile.bodyless_terminator == null) return .empty_body;
    return switch (function.kind) {
        .declaration => .bodyless,
        .method => if (isClassMember(profile, function.node) and !isDecorated(profile, function.node)) .bodyless else .empty_body,
        .generator_declaration,
        .expression,
        .generator_expression,
        .arrow,
        .static_block,
        => .empty_body,
    };
}

fn isClassMember(profile: *const Profile, node: ts.Node) bool {
    const parent = node.parent() orelse return false;
    return std.mem.eql(u8, profile.class_body, parent.kind());
}

fn isDecorated(profile: *const Profile, node: ts.Node) bool {
    if (node.namedChild(0)) |first| {
        if (isKind(first, profile.decorator)) return true;
    }
    var prev = node.prevNamedSibling();
    while (prev) |sibling| : (prev = sibling.prevNamedSibling()) {
        if (!profile.isComment(sibling.kind())) return isKind(sibling, profile.decorator);
    }
    return false;
}

fn followsComment(profile: *const Profile, body: ts.Node) bool {
    const prev = body.prevSibling() orelse return false;
    return profile.isComment(prev.kind());
}

fn isKind(node: ts.Node, kind: []const u8) bool {
    return std.mem.eql(u8, kind, node.kind());
}

fn trimTrailingWhitespace(source: []const u8, end: u32) u32 {
    var i = end;
    while (i > 0 and std.ascii.isWhitespace(source[i - 1])) i -= 1;
    return i;
}

fn verify(parser: ts.Parser, language: *const ts.Language, skeleton: []const u8) Error!void {
    const tree = try parser.parseIn(language, skeleton);
    defer tree.deinit();
    if (tree.root().hasError()) return error.SkeletonInvalid;
}

pub const Metrics = struct {
    bytes: usize,
    tokens: usize,
};

pub fn measure(tree: ts.Tree) Metrics {
    var tokens: usize = 0;
    var walker = traversal.Walker.init(tree.root());
    defer walker.deinit();
    while (walker.next()) |entry| {
        const node = entry.node;
        if (node.childCount() == 0 and node.endByte() > node.startByte()) tokens += 1;
    }
    return .{ .bytes = tree.source.len, .tokens = tokens };
}

const testing = std.testing;

const fixtures = [_][]const u8{ "functions.ts", "service.ts" };

fn skeletonOfSource(parser: ts.Parser, source: []const u8) ![]u8 {
    const tree = try parser.parse(source);
    defer tree.deinit();
    return skeletonize(testing.allocator, parser, test_util.language, tree);
}

fn expectSkeleton(source: []const u8, expected: []const u8) !void {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try test_util.parser();
    defer parser.deinit();

    const skeleton = try skeletonOfSource(parser, source);
    defer testing.allocator.free(skeleton);
    try testing.expectEqualStrings(expected, skeleton);

    const again = try skeletonOfSource(parser, skeleton);
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(skeleton, again);
}

test "functions.ts skeleton matches the golden file byte for byte" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try test_util.parser();
    defer parser.deinit();

    const doc = try test_util.openFixture(parser, "functions.ts");
    defer doc.deinit();
    const skeleton = try skeletonize(testing.allocator, parser, test_util.language, doc.tree);
    defer testing.allocator.free(skeleton);

    const golden = try std.Io.Dir.cwd().readFileAlloc(testing.io, test_util.fixture_dir ++ "functions.skeleton.ts", testing.allocator, .unlimited);
    defer testing.allocator.free(golden);
    try testing.expectEqualStrings(golden, skeleton);
}

test "every fixture skeleton is valid TypeScript, smaller, and a fixed point" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try test_util.parser();
    defer parser.deinit();

    for (fixtures) |name| {
        errdefer std.debug.print("fixture: {s}\n", .{name});
        const doc = try test_util.openFixture(parser, name);
        defer doc.deinit();

        const skeleton = try skeletonize(testing.allocator, parser, test_util.language, doc.tree);
        defer testing.allocator.free(skeleton);
        const reparsed = try parser.parse(skeleton);
        defer reparsed.deinit();
        try testing.expect(!reparsed.root().hasError());

        const before = measure(doc.tree);
        const after = measure(reparsed);
        try testing.expect(after.bytes < before.bytes);
        try testing.expect(after.tokens < before.tokens);

        const again = try skeletonize(testing.allocator, parser, test_util.language, reparsed);
        defer testing.allocator.free(again);
        try testing.expectEqualStrings(skeleton, again);
    }
}

test "sources with syntax errors are refused instead of guessed at" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try test_util.parser();
    defer parser.deinit();

    const doc = try test_util.openFixture(parser, "broken.ts");
    defer doc.deinit();
    try testing.expectError(error.SourceHasErrors, skeletonize(testing.allocator, parser, test_util.language, doc.tree));
}

test "expression bodies survive while block functions inside them are stripped" {
    try expectSkeleton(
        "export const load = (u: string) => fetch(u).then((r) => {\n  return r.json();\n});\n",
        "export const load = (u: string) => fetch(u).then((r) => {});\n",
    );
}

test "object methods keep an empty block, class methods and declarations end with a semicolon" {
    try expectSkeleton(
        \\const api = { *ids() { yield 1; }, async get() { return 1; } };
        \\class A { run(): void { go(); } }
        \\function* gen(): Generator<number> { yield 2; }
    ,
        \\const api = { *ids() {}, async get() {} };
        \\class A { run(): void; }
        \\function* gen(): Generator<number> {}
    );
}

test "decorated class methods keep an empty block because the grammar has no bodyless form" {
    try expectSkeleton(
        \\@Injectable()
        \\export class Users {
        \\  @Get(":id")
        \\  async find(@Param("id") id: string): Promise<string> { return id; }
        \\  @Cached() // hot path
        \\  get size(): number { return 1; }
        \\  plain(): void { go(); }
        \\}
    ,
        \\@Injectable()
        \\export class Users {
        \\  @Get(":id")
        \\  async find(@Param("id") id: string): Promise<string> {}
        \\  @Cached() // hot path
        \\  get size(): number {}
        \\  plain(): void;
        \\}
    );
}

test "a line comment before the body never swallows the terminator" {
    try expectSkeleton(
        "function f() // c\n{ return 1; }\nclass A {\n  m() // c\n  { }\n  *g() { yield 1; }\n}\nfunction h() /* c */ { return 1; }\n",
        "function f() // c\n{}\nclass A {\n  m() // c\n  {}\n  *g();\n}\nfunction h() /* c */ {}\n",
    );
}

test "CRLF line endings and a UTF-8 BOM are preserved around the cuts" {
    try expectSkeleton(
        "\xEF\xBB\xBFexport function a(): number {\r\n  return 1;\r\n}\r\nclass B {\r\n  m() {\r\n  }\r\n}\r\n",
        "\xEF\xBB\xBFexport function a(): number;\r\nclass B {\r\n  m();\r\n}\r\n",
    );
}

test "python defs and classes are collected and their bodies stubbed with ellipsis" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();

    const python = &@import("lang/python/profile.zig").profile;
    const parser = try ts.Parser.init(python.grammar());
    defer parser.deinit();

    const source =
        "import os\n\n\ndef greet(name):\n    # say hi\n    print(name)\n\n\nclass Greeter:\n    def run(self):\n        return 1\n";
    const tree = try parser.parse(source);
    defer tree.deinit();
    try testing.expect(!tree.root().hasError());

    const functions = try symbol.collectFunctions(testing.allocator, python, tree);
    defer testing.allocator.free(functions);
    try testing.expectEqual(@as(usize, 2), functions.len);
    try testing.expectEqualStrings("greet", tree.text(functions[0].name.?));
    try testing.expectEqualStrings("run", tree.text(functions[1].name.?));

    const skeleton = try skeletonize(testing.allocator, parser, python, tree);
    defer testing.allocator.free(skeleton);

    const reparsed = try parser.parse(skeleton);
    defer reparsed.deinit();
    try testing.expect(!reparsed.root().hasError());
    try testing.expect(std.mem.indexOf(u8, skeleton, "...") != null);
    try testing.expect(std.mem.indexOf(u8, skeleton, "print(name)") == null);
    try testing.expect(std.mem.indexOf(u8, skeleton, "return 1") == null);
    try testing.expect(skeleton.len < source.len);

    const again = try skeletonize(testing.allocator, parser, python, reparsed);
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(skeleton, again);
}

test "a source without functions is returned unchanged" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try test_util.parser();
    defer parser.deinit();

    const source = "export type Id = string;\nexport const limit = 10;\n";
    const skeleton = try skeletonOfSource(parser, source);
    defer testing.allocator.free(skeleton);
    try testing.expectEqualStrings(source, skeleton);

    const empty = try skeletonOfSource(parser, "");
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("", empty);
}

fn expectFolded(source: []const u8, expected: []const u8) !void {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try test_util.parser();
    defer parser.deinit();
    const folded = try foldComments(testing.allocator, parser, test_util.language, test_util.language.grammar(), source);
    defer testing.allocator.free(folded);
    try testing.expectEqualStrings(expected, folded);
}

test "a skeleton folds every doc block to its first line and keeps one-line comments" {
    try expectFolded(
        "/**\n * Adds two numbers.\n * @param a first\n * @returns sum\n */\nexport function add(a: number, b: number): number;\n// one line\nconst x = 1;\n",
        "/** Adds two numbers. */\nexport function add(a: number, b: number): number;\n// one line\nconst x = 1;\n",
    );
}

test "a skeleton keeps only the first of adjacent comments and drops a block with no text" {
    try expectFolded(
        "// first\n// second\n// third\nconst x = 1;\n  /*\n   *\n   */\nconst y = 2;\n",
        "// first\nconst x = 1;\nconst y = 2;\n",
    );
}

test "a compact skeleton of a fixture is smaller than the plain skeleton and still parses" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try test_util.parser();
    defer parser.deinit();
    const doc = try test_util.openFixture(parser, "service.ts");
    defer doc.deinit();
    const plain = try skeletonize(testing.allocator, parser, test_util.language, doc.tree);
    defer testing.allocator.free(plain);
    const folded = try compact(testing.allocator, parser, test_util.language, doc.tree);
    defer testing.allocator.free(folded);
    try testing.expect(folded.len <= plain.len);
    const reparsed = try parser.parse(folded);
    defer reparsed.deinit();
    try testing.expect(!reparsed.root().hasError());
}
