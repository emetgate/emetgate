const std = @import("std");
const ts = @import("tree_sitter.zig");
const symbol = @import("symbol.zig");
const alloc_bridge = @import("alloc_bridge.zig");
const test_util = @import("test_util.zig");

const Allocator = std.mem.Allocator;
const Span = symbol.Span;

pub const Error = error{
    SourceHasErrors,
    SymbolNotFound,
    AmbiguousSymbol,
    HashMismatch,
    MutationSyntaxInvalid,
    BodyEscape,
} || Allocator.Error || ts.Error;

pub const Mutation = struct {
    ref: symbol.Ref,
    expected_hash: symbol.Hash,
    new_body: []const u8,
};

pub const Patched = struct {
    gpa: Allocator,
    source: []u8,
    tree: ts.Tree,
    hash: symbol.Hash,

    pub fn deinit(self: Patched) void {
        self.tree.deinit();
        self.gpa.free(self.source);
    }
};

pub fn apply(gpa: Allocator, parser: ts.Parser, tree: ts.Tree, mutation: Mutation) Error!Patched {
    const before = try symbol.Table.build(gpa, tree);
    defer before.deinit();
    const target = try before.resolve(mutation.ref);
    if (!std.mem.eql(u8, &target.hash, &mutation.expected_hash)) return error.HashMismatch;

    const cut: Span = .{ .start = target.body.startByte(), .end = target.body.endByte() };
    const source = try std.mem.concat(gpa, u8, &.{ tree.source[0..cut.start], mutation.new_body, tree.source[cut.end..] });
    errdefer gpa.free(source);

    const patched_tree = try parser.parse(source);
    errdefer patched_tree.deinit();
    if (patched_tree.root().hasError()) return error.MutationSyntaxInvalid;

    const after = symbol.Table.build(gpa, patched_tree) catch |err| switch (err) {
        error.SourceHasErrors => return error.MutationSyntaxInvalid,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer after.deinit();

    const slot: Span = .{ .start = cut.start, .end = cut.start + @as(u32, @intCast(mutation.new_body.len)) };
    const patched_target = after.resolve(mutation.ref) catch return error.BodyEscape;
    try expectExactSlot(patched_target.body, slot);
    try expectUntouchedOutside(before, after, cut, slot);

    return .{ .gpa = gpa, .source = source, .tree = patched_tree, .hash = patched_target.hash };
}

fn expectExactSlot(body: ts.Node, slot: Span) error{BodyEscape}!void {
    if (body.startByte() != slot.start or body.endByte() != slot.end) return error.BodyEscape;
    if (isComment(edgeToken(body, .first)) or isComment(edgeToken(body, .last))) return error.BodyEscape;
}

fn edgeToken(node: ts.Node, comptime side: enum { first, last }) ts.Node {
    var current = node;
    while (current.childCount() > 0) {
        current = current.child(if (side == .first) 0 else current.childCount() - 1).?;
    }
    return current;
}

fn isComment(node: ts.Node) bool {
    return std.mem.eql(u8, "comment", node.kind());
}

fn expectUntouchedOutside(before: symbol.Table, after: symbol.Table, cut: Span, slot: Span) error{BodyEscape}!void {
    var outside_before: usize = 0;
    for (before.symbols) |old| {
        if (!isOutside(old.declaration, cut)) continue;
        outside_before += 1;
        if (!hasTwinOutside(after, old, slot)) return error.BodyEscape;
    }
    var outside_after: usize = 0;
    for (after.symbols) |new| {
        if (isOutside(new.declaration, slot)) outside_after += 1;
    }
    if (outside_before != outside_after) return error.BodyEscape;
}

fn hasTwinOutside(table: symbol.Table, wanted: symbol.Symbol, slot: Span) bool {
    for (table.symbols) |candidate| {
        if (!isOutside(candidate.declaration, slot)) continue;
        if (candidate.ref.eql(wanted.ref) and std.mem.eql(u8, &candidate.hash, &wanted.hash)) return true;
    }
    return false;
}

fn isOutside(span: Span, region: Span) bool {
    return span.end <= region.start or span.start >= region.end;
}

const testing = std.testing;

const HashSource = enum { current, stale };

fn currentHash(tree: ts.Tree, ref: symbol.Ref) !symbol.Hash {
    const table = try symbol.Table.build(testing.allocator, tree);
    defer table.deinit();
    return (try table.resolve(ref)).hash;
}

fn mutate(parser: ts.Parser, tree: ts.Tree, ref_text: []const u8, new_body: []const u8, hash: HashSource) !Patched {
    const ref = try symbol.Ref.parse(testing.allocator, ref_text);
    defer ref.deinit(testing.allocator);
    const expected = switch (hash) {
        .current => currentHash(tree, ref) catch std.mem.zeroes(symbol.Hash),
        .stale => symbol.hashOf("stale view"),
    };
    return apply(testing.allocator, parser, tree, .{ .ref = ref, .expected_hash = expected, .new_body = new_body });
}

fn hashOfRef(tree: ts.Tree, ref_text: []const u8) !symbol.Hash {
    const ref = try symbol.Ref.parse(testing.allocator, ref_text);
    defer ref.deinit(testing.allocator);
    return currentHash(tree, ref);
}

test "replaces exactly one body in memory and leaves the file on disk untouched" {
    alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try ts.Parser.init(ts.typescript());
    defer parser.deinit();
    const doc = try test_util.openFixture(parser, "functions.ts");
    defer doc.deinit();

    const old_body = "{\n  return a + b;\n}";
    const new_body = "{\n  return a - b;\n}";
    const patched = try mutate(parser, doc.tree, "add", new_body, .current);
    defer patched.deinit();

    const at = std.mem.indexOf(u8, doc.source, old_body) orelse return error.FixtureChanged;
    try testing.expectEqualStrings(doc.source[0..at], patched.source[0..at]);
    try testing.expectEqualStrings(new_body, patched.source[at..][0..new_body.len]);
    try testing.expectEqualStrings(doc.source[at + old_body.len ..], patched.source[at + new_body.len ..]);
    try testing.expect(!patched.tree.root().hasError());
    try testing.expectEqual(try hashOfRef(patched.tree, "add"), patched.hash);

    const on_disk = try std.Io.Dir.cwd().readFileAlloc(testing.io, test_util.fixture_dir ++ "functions.ts", testing.allocator, .unlimited);
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(doc.source, on_disk);
}

test "a source with syntax errors is refused before resolution" {
    alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try ts.Parser.init(ts.typescript());
    defer parser.deinit();
    const doc = try test_util.openFixture(parser, "broken.ts");
    defer doc.deinit();

    try testing.expectError(error.SourceHasErrors, mutate(parser, doc.tree, "broken", "{ return a; }", .current));

    const broken_sources = [_][]const u8{
        "export function broken(a: number {\n  return a;\n}\nfunction ok() { return 1; }\n",
        "function ok() { return 1; }\nfunction open() {\n  return 2;\n",
        "function ok() { return 1; }\nconst s = `unterminated ${ok()}\n",
        "function ok() { return (1; }\n",
        "function ok() { return 1; }}\n",
    };
    for (broken_sources) |source| {
        errdefer std.debug.print("accepted broken source: \"{s}\"\n", .{source});
        const t = try test_util.TestTree.init(source);
        defer t.deinit();
        try testing.expectError(error.SourceHasErrors, mutate(t.parser, t.tree, "ok", "{ return 2; }", .current));
    }
}

test "error precedence: each check wins over every later one" {
    alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const broken = try test_util.TestTree.init("function ok() { return 1; }\nfunction bad( {\n");
    defer broken.deinit();
    const valid = try test_util.TestTree.init("function dup() {}\nfunction dup() {}\nfunction f() { return 1; }\nfunction g() { return 2; }\n");
    defer valid.deinit();

    try testing.expectError(error.SourceHasErrors, mutate(broken.parser, broken.tree, "missing", "{ oops", .stale));
    try testing.expectError(error.SymbolNotFound, mutate(valid.parser, valid.tree, "missing", "{ oops", .stale));
    try testing.expectError(error.AmbiguousSymbol, mutate(valid.parser, valid.tree, "dup", "{ oops", .stale));
    try testing.expectError(error.HashMismatch, mutate(valid.parser, valid.tree, "f", "{ oops", .stale));
    try testing.expectError(error.MutationSyntaxInvalid, mutate(valid.parser, valid.tree, "f", "{ } function evil() { oops", .current));
    try testing.expectError(error.BodyEscape, mutate(valid.parser, valid.tree, "f", "{ } function evil() {}", .current));
}

test "unknown, under-qualified and ambiguous targets are refused" {
    alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const t = try test_util.TestTree.init(
        \\function dup() {}
        \\function dup() {}
        \\class Box { get size(): number { return 1; } set size(v: number) {} }
    );
    defer t.deinit();

    try testing.expectError(error.AmbiguousSymbol, mutate(t.parser, t.tree, "dup", "{ return 1; }", .current));
    try testing.expectError(error.SymbolNotFound, mutate(t.parser, t.tree, "nope", "{}", .current));
    try testing.expectError(error.SymbolNotFound, mutate(t.parser, t.tree, "Box.size", "{ return 2; }", .current));
    try testing.expectError(error.SymbolNotFound, mutate(t.parser, t.tree, "Box.size@static@get", "{ return 2; }", .current));
}

test "a stale hash is refused, an unrelated edit elsewhere is not" {
    alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const original = try test_util.TestTree.init("function f() { return 1; }\nfunction g() { return 2; }\n");
    defer original.deinit();
    const elsewhere = try test_util.TestTree.init("function f() { return 1; }\nfunction g() { return 20; }\n");
    defer elsewhere.deinit();

    try testing.expectError(error.HashMismatch, mutate(original.parser, original.tree, "f", "{ return 3; }", .stale));

    const ref = try symbol.Ref.parse(testing.allocator, "f");
    defer ref.deinit(testing.allocator);
    const seen = try currentHash(original.tree, ref);
    const patched = try apply(testing.allocator, elsewhere.parser, elsewhere.tree, .{ .ref = ref, .expected_hash = seen, .new_body = "{ return 3; }" });
    defer patched.deinit();
    try testing.expectEqualStrings("function f() { return 3; }\nfunction g() { return 20; }\n", patched.source);
}

test "broken replacement bodies are refused and never spliced" {
    alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try ts.Parser.init(ts.typescript());
    defer parser.deinit();
    const doc = try test_util.openFixture(parser, "functions.ts");
    defer doc.deinit();

    const broken_bodies = [_][]const u8{
        "{ return a + ; }",
        "{\n  return a;\n",
        "return a;",
        "{ return a; }}",
        "{ return (a; }",
    };
    for (broken_bodies) |body| {
        errdefer std.debug.print("accepted broken body: \"{s}\"\n", .{body});
        try testing.expectError(error.MutationSyntaxInvalid, mutate(parser, doc.tree, "add", body, .current));
    }
}

test "a body that parses but spills outside its slot is a BodyEscape" {
    alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const t = try test_util.TestTree.init("function f() { return 1; }\nfunction g() { return 2; }\n");
    defer t.deinit();

    const escapes = [_][]const u8{
        "{ } function evil() { return 0; }",
        "{ return 1; } // trailing",
        "{ return 1; } /* trailing */",
        "/* leading */ { return 1; }",
        "{ return 1; }\nfunction f() { return 3; }",
        "",
    };
    for (escapes) |body| {
        errdefer std.debug.print("accepted escaping body: \"{s}\"\n", .{body});
        try testing.expectError(error.BodyEscape, mutate(t.parser, t.tree, "f", body, .current));
    }
}

test "only the addressed accessor changes when getter and setter share a name" {
    alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try ts.Parser.init(ts.typescript());
    defer parser.deinit();
    const doc = try test_util.openFixture(parser, "functions.ts");
    defer doc.deinit();

    const getter_before = try hashOfRef(doc.tree, "Repository.label@get");
    const setter_before = try hashOfRef(doc.tree, "Repository.label@set");

    const patched = try mutate(parser, doc.tree, "Repository.label@set", "{\n    console.info(value);\n  }", .current);
    defer patched.deinit();

    try testing.expectEqual(getter_before, try hashOfRef(patched.tree, "Repository.label@get"));
    try testing.expect(!std.mem.eql(u8, &setter_before, &patched.hash));
    try testing.expect(std.mem.indexOf(u8, patched.source, "set label(value: string) {\n    console.info(value);\n  }") != null);
}

test "an expression-bodied arrow accepts an expression or a block" {
    alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const t = try test_util.TestTree.init("export const square = (n: number) => n * n;\n");
    defer t.deinit();

    const as_expression = try mutate(t.parser, t.tree, "square", "n ** 2", .current);
    defer as_expression.deinit();
    try testing.expectEqualStrings("export const square = (n: number) => n ** 2;\n", as_expression.source);

    const as_block = try mutate(t.parser, t.tree, "square", "{ return n * n; }", .current);
    defer as_block.deinit();
    try testing.expectEqualStrings("export const square = (n: number) => { return n * n; };\n", as_block.source);
}

test "outside-symbol lock rejects a renamed, re-hashed, added or removed neighbour" {
    alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const before_tree = try test_util.TestTree.init("function f() { return 1; }\nfunction g() { return 2; }\n");
    defer before_tree.deinit();
    const before = try symbol.Table.build(testing.allocator, before_tree.tree);
    defer before.deinit();
    const f_body = (try before.resolve(.{ .name = "f" })).body;
    const cut: Span = .{ .start = f_body.startByte(), .end = f_body.endByte() };

    const same_shape = [_][]const u8{
        "function f() { return 1; }\nfunction h() { return 2; }\n",
        "function f() { return 1; }\nfunction g() { return 3; }\n",
        "function f() { return 1; }\nfunction g() { return 2; }\nfunction extra() {}\n",
        "function f() { return 1; }\n",
    };
    for (same_shape) |source| {
        errdefer std.debug.print("lock accepted: \"{s}\"\n", .{source});
        const after_tree = try test_util.TestTree.init(source);
        defer after_tree.deinit();
        const after = try symbol.Table.build(testing.allocator, after_tree.tree);
        defer after.deinit();
        try testing.expectError(error.BodyEscape, expectUntouchedOutside(before, after, cut, cut));
    }

    const after = try symbol.Table.build(testing.allocator, before_tree.tree);
    defer after.deinit();
    try expectUntouchedOutside(before, after, cut, cut);
}

test "chained mutations: the returned hash is the next expected hash" {
    alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const t = try test_util.TestTree.init("function f() { return 1; }\n");
    defer t.deinit();

    const first = try mutate(t.parser, t.tree, "f", "{ return 2; }", .current);
    defer first.deinit();

    const ref = try symbol.Ref.parse(testing.allocator, "f");
    defer ref.deinit(testing.allocator);
    const second = try apply(testing.allocator, t.parser, first.tree, .{ .ref = ref, .expected_hash = first.hash, .new_body = "{ return 3; }" });
    defer second.deinit();
    try testing.expectEqualStrings("function f() { return 3; }\n", second.source);

    try testing.expectError(error.HashMismatch, apply(testing.allocator, t.parser, second.tree, .{ .ref = ref, .expected_hash = first.hash, .new_body = "{ return 4; }" }));
}
