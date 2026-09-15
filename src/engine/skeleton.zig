const std = @import("std");
const ts = @import("tree_sitter.zig");
const traversal = @import("traversal.zig");
const symbol = @import("symbol.zig");
const alloc_bridge = @import("alloc_bridge.zig");
const test_util = @import("test_util.zig");

pub const Error = error{ SourceHasErrors, SkeletonInvalid } || std.mem.Allocator.Error || ts.Error;

const Terminator = enum {
    semicolon,
    empty_block,

    fn text(self: Terminator) []const u8 {
        return switch (self) {
            .semicolon => ";",
            .empty_block => "{}",
        };
    }
};

const Cut = struct {
    start: u32,
    end: u32,
    terminator: Terminator,
};

pub fn skeletonize(gpa: std.mem.Allocator, parser: ts.Parser, tree: ts.Tree) Error![]u8 {
    if (tree.root().hasError()) return error.SourceHasErrors;

    const functions = try symbol.collectFunctions(gpa, tree);
    defer gpa.free(functions);

    var out: std.ArrayList(u8) = try .initCapacity(gpa, tree.source.len);
    errdefer out.deinit(gpa);

    var copied: u32 = 0;
    for (functions) |function| {
        const cut = planCut(tree.source, function) orelse continue;
        if (cut.start < copied) continue;
        out.appendSliceAssumeCapacity(tree.source[copied..cut.start]);
        out.appendSliceAssumeCapacity(cut.terminator.text());
        copied = cut.end;
    }
    out.appendSliceAssumeCapacity(tree.source[copied..]);

    const skeleton = try out.toOwnedSlice(gpa);
    errdefer gpa.free(skeleton);
    try verify(parser, tree.language(), skeleton);
    return skeleton;
}

fn planCut(source: []const u8, function: symbol.Function) ?Cut {
    if (!std.mem.eql(u8, "statement_block", function.body.kind())) return null;
    const terminator: Terminator = if (followsComment(function.body)) .empty_block else terminatorFor(function);
    const body_start = function.body.startByte();
    return .{
        .start = if (terminator == .semicolon) trimTrailingWhitespace(source, body_start) else body_start,
        .end = function.body.endByte(),
        .terminator = terminator,
    };
}

fn terminatorFor(function: symbol.Function) Terminator {
    return switch (function.kind) {
        .function_declaration => .semicolon,
        .method_definition => if (isClassMember(function.node) and !isDecorated(function.node)) .semicolon else .empty_block,
        .generator_function_declaration,
        .function_expression,
        .generator_function,
        .arrow_function,
        .class_static_block,
        => .empty_block,
    };
}

fn isClassMember(node: ts.Node) bool {
    const parent = node.parent() orelse return false;
    return std.mem.eql(u8, "class_body", parent.kind());
}

fn isDecorated(node: ts.Node) bool {
    if (node.namedChild(0)) |first| {
        if (isKind(first, "decorator")) return true;
    }
    var prev = node.prevNamedSibling();
    while (prev) |sibling| : (prev = sibling.prevNamedSibling()) {
        if (!isKind(sibling, "comment")) return isKind(sibling, "decorator");
    }
    return false;
}

fn followsComment(body: ts.Node) bool {
    const prev = body.prevSibling() orelse return false;
    return isKind(prev, "comment");
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
    return skeletonize(testing.allocator, parser, tree);
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
    const skeleton = try skeletonize(testing.allocator, parser, doc.tree);
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

        const skeleton = try skeletonize(testing.allocator, parser, doc.tree);
        defer testing.allocator.free(skeleton);
        const reparsed = try parser.parse(skeleton);
        defer reparsed.deinit();
        try testing.expect(!reparsed.root().hasError());

        const before = measure(doc.tree);
        const after = measure(reparsed);
        try testing.expect(after.bytes < before.bytes);
        try testing.expect(after.tokens < before.tokens);

        const again = try skeletonize(testing.allocator, parser, reparsed);
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
    try testing.expectError(error.SourceHasErrors, skeletonize(testing.allocator, parser, doc.tree));
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
