const std = @import("std");
const symbol = @import("../src/engine/symbol.zig");
const ts = @import("../src/engine/tree_sitter.zig");
const alloc_bridge = @import("../src/engine/alloc_bridge.zig");
const test_util = @import("../src/engine/test_util.zig");

const FunctionKind = symbol.FunctionKind;
const Kind = symbol.Kind;
const Ref = symbol.Ref;
const Symbol = symbol.Symbol;
const Table = symbol.Table;
const collectFunctions = symbol.collectFunctions;
const formatHash = symbol.formatHash;
const hashOf = symbol.hashOf;
const parseHash = symbol.parseHash;

const testing = std.testing;

const ExpectedFunction = struct {
    kind: FunctionKind,
    name: ?[]const u8,
    nested: bool = false,
};

fn expectFunctions(tree: ts.Tree, expected: []const ExpectedFunction) !void {
    const functions = try collectFunctions(testing.allocator, test_util.language, tree);
    defer testing.allocator.free(functions);

    for (expected, 0..) |want, i| {
        if (i >= functions.len) {
            std.debug.print("missing function #{d}: {t} {?s}\n", .{ i, want.kind, want.name });
            return error.TooFewFunctions;
        }
        const got = functions[i];
        const got_name = if (got.name) |n| tree.text(n) else null;
        errdefer std.debug.print("function #{d}: want {t} {?s} nested={}, got {t} {?s} nested={}\n", .{ i, want.kind, want.name, want.nested, got.kind, got_name, got.nested });
        try testing.expectEqual(want.kind, got.kind);
        try testing.expectEqual(want.nested, got.nested);
        if (want.name) |name| {
            try testing.expectEqualStrings(name, got_name orelse return error.MissingName);
        } else {
            try testing.expect(got_name == null);
        }
    }
    try testing.expectEqual(expected.len, functions.len);
}

const ExpectedSymbol = struct {
    ref: []const u8,
    kind: Kind,
    ambiguous: bool = false,
};

fn expectSymbols(tree: ts.Tree, expected: []const ExpectedSymbol) !void {
    const table = try Table.build(testing.allocator, test_util.language, tree);
    defer table.deinit();

    var buf: [256]u8 = undefined;
    for (expected, 0..) |want, i| {
        if (i >= table.symbols.len) {
            std.debug.print("missing symbol #{d}: {s}\n", .{ i, want.ref });
            return error.TooFewSymbols;
        }
        const got = table.symbols[i];
        const got_ref = try std.fmt.bufPrint(&buf, "{f}", .{got.ref});
        errdefer std.debug.print("symbol #{d}: want {s} {t} ambiguous={}, got {s} {t} ambiguous={}\n", .{ i, want.ref, want.kind, want.ambiguous, got_ref, got.kind, got.ambiguous });
        try testing.expectEqualStrings(want.ref, got_ref);
        try testing.expectEqual(want.kind, got.kind);
        try testing.expectEqual(want.ambiguous, got.ambiguous);
    }
    if (table.symbols.len > expected.len) {
        std.debug.print("unexpected symbol #{d}: {f}\n", .{ expected.len, table.symbols[expected.len].ref });
        return error.TooManySymbols;
    }
}

fn resolveText(table: Table, text: []const u8) !*const Symbol {
    const ref = try Ref.parse(testing.allocator, text);
    defer ref.deinit(testing.allocator);
    return table.resolve(ref);
}

test "collects every function-like boundary in the fixture, in source order" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try test_util.parser();
    defer parser.deinit();
    const doc = try test_util.openFixture(parser, "functions.ts");
    defer doc.deinit();

    try expectFunctions(doc.tree, &.{
        .{ .kind = .declaration, .name = "add" },
        .{ .kind = .generator_declaration, .name = "stream" },
        .{ .kind = .declaration, .name = "overloaded" },
        .{ .kind = .arrow, .name = "validateToken" },
        .{ .kind = .expression, .name = "helper", .nested = true },
        .{ .kind = .arrow, .name = "square" },
        .{ .kind = .expression, .name = null },
        .{ .kind = .arrow, .name = "handler" },
        .{ .kind = .static_block, .name = null },
        .{ .kind = .method, .name = "constructor" },
        .{ .kind = .method, .name = "label" },
        .{ .kind = .method, .name = "label" },
        .{ .kind = .method, .name = "now" },
        .{ .kind = .method, .name = "ids" },
        .{ .kind = .method, .name = "home" },
        .{ .kind = .arrow, .name = "about" },
        .{ .kind = .declaration, .name = "old" },
        .{ .kind = .arrow, .name = null },
        .{ .kind = .declaration, .name = "afterUnicode" },
    });
}

test "bodyless signatures are not function boundaries" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const t = try test_util.TestTree.init(
        \\interface Clock { now(): number; }
        \\declare function ambient(x: string): void;
        \\abstract class Base { abstract run(): void; }
        \\function over(a: string): string;
    );
    defer t.deinit();

    try expectFunctions(t.tree, &.{});
}

test "names resolve through type assertions, parentheses and compound assignment" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const t = try test_util.TestTree.init(
        \\const asserted = (() => {}) as Handler;
        \\const checked = (function () {}) satisfies Handler;
        \\const forced = (() => {})!;
        \\exports.lazy ||= () => {};
        \\const wrapped = memo(() => {});
    );
    defer t.deinit();

    try expectFunctions(t.tree, &.{
        .{ .kind = .arrow, .name = "asserted" },
        .{ .kind = .expression, .name = "checked" },
        .{ .kind = .arrow, .name = "forced" },
        .{ .kind = .arrow, .name = "exports.lazy" },
        .{ .kind = .arrow, .name = null },
    });
}

test "arrow functions in default parameters are not nested in the body" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const t = try test_util.TestTree.init("function outer(cb = () => 1) { const run = () => cb(); }");
    defer t.deinit();

    try expectFunctions(t.tree, &.{
        .{ .kind = .declaration, .name = "outer" },
        .{ .kind = .arrow, .name = null },
        .{ .kind = .arrow, .name = "run", .nested = true },
    });
}

test "byte offsets stay exact after multi-byte UTF-8 text" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try test_util.parser();
    defer parser.deinit();
    const doc = try test_util.openFixture(parser, "functions.ts");
    defer doc.deinit();

    const functions = try collectFunctions(testing.allocator, test_util.language, doc.tree);
    defer testing.allocator.free(functions);
    const last = functions[functions.len - 1];

    const marker = "function afterUnicode";
    const expected_start = std.mem.indexOf(u8, doc.source, marker) orelse return error.MarkerMissing;
    try testing.expectEqual(@as(u32, @intCast(expected_start)), last.node.startByte());
    try testing.expectEqualStrings("afterUnicode", doc.tree.text(last.name.?));
}

test "symbol table of the fixture names every addressable function with its container" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try test_util.parser();
    defer parser.deinit();
    const doc = try test_util.openFixture(parser, "functions.ts");
    defer doc.deinit();

    try expectSymbols(doc.tree, &.{
        .{ .ref = "add", .kind = .function },
        .{ .ref = "stream", .kind = .generator },
        .{ .ref = "overloaded", .kind = .function },
        .{ .ref = "validateToken", .kind = .arrow },
        .{ .ref = "validateToken.helper", .kind = .function_expression },
        .{ .ref = "square", .kind = .arrow },
        .{ .ref = "Repository.handler", .kind = .arrow },
        .{ .ref = "Repository.constructor", .kind = .constructor },
        .{ .ref = "Repository.label@get", .kind = .getter },
        .{ .ref = "Repository.label@set", .kind = .setter },
        .{ .ref = "Repository.now", .kind = .method },
        .{ .ref = "Repository.ids", .kind = .method },
        .{ .ref = "routes.home", .kind = .method },
        .{ .ref = "routes.about", .kind = .arrow },
        .{ .ref = "Legacy.old", .kind = .function },
        .{ .ref = "afterUnicode", .kind = .function },
    });
}

test "service fixture: private, static, decorated-class and parameter-property members" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try test_util.parser();
    defer parser.deinit();
    const doc = try test_util.openFixture(parser, "service.ts");
    defer doc.deinit();

    try expectSymbols(doc.tree, &.{
        .{ .ref = "HttpError.constructor", .kind = .constructor },
        .{ .ref = "injectable", .kind = .function },
        .{ .ref = "UserService.constructor", .kind = .constructor },
        .{ .ref = "UserService.findById", .kind = .method },
        .{ .ref = "UserService.#invalidate", .kind = .method },
        .{ .ref = "UserService.create@static", .kind = .method },
        .{ .ref = "handle", .kind = .function },
    });
}

test "static, instance, getter and setter collisions are distinct refs; true duplicates are ambiguous" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const t = try test_util.TestTree.init(
        \\class Box {
        \\  static make(): Box { return new Box(); }
        \\  make(): Box { return this; }
        \\  get size(): number { return 1; }
        \\  set size(v: number) {}
        \\  static get size(): number { return 2; }
        \\  static handler = () => {};
        \\  get() { return 0; }
        \\}
        \\function dup() {}
        \\function dup() {}
    );
    defer t.deinit();

    try expectSymbols(t.tree, &.{
        .{ .ref = "Box.make@static", .kind = .method },
        .{ .ref = "Box.make", .kind = .method },
        .{ .ref = "Box.size@get", .kind = .getter },
        .{ .ref = "Box.size@set", .kind = .setter },
        .{ .ref = "Box.size@static@get", .kind = .getter },
        .{ .ref = "Box.handler@static", .kind = .arrow },
        .{ .ref = "Box.get", .kind = .method },
        .{ .ref = "dup", .kind = .function, .ambiguous = true },
        .{ .ref = "dup", .kind = .function, .ambiguous = true },
    });

    const table = try Table.build(testing.allocator, test_util.language, t.tree);
    defer table.deinit();
    try testing.expectEqual(Kind.getter, (try resolveText(table, "Box.size@static@get")).kind);
    try testing.expectEqual(Kind.setter, (try resolveText(table, "Box.size@set")).kind);
    try testing.expect(!(try resolveText(table, "Box.make")).ref.is_static);
    try testing.expect((try resolveText(table, "Box.make@static")).ref.is_static);
    try testing.expectError(error.SymbolNotFound, resolveText(table, "Box.size"));
    try testing.expectError(error.SymbolNotFound, resolveText(table, "make@static"));
    try testing.expectError(error.SymbolNotFound, resolveText(table, "Box.nope"));
    try testing.expectError(error.AmbiguousSymbol, resolveText(table, "dup"));
}

test "containers: dotted namespaces, bound class expressions, nested objects and enclosing functions" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const t = try test_util.TestTree.init(
        \\namespace Outer.Inner {
        \\  export function deep(): void {}
        \\}
        \\const Widget = class {
        \\  render(): string { return ""; }
        \\};
        \\export const api = {
        \\  users: {
        \\    list() { return []; },
        \\  },
        \\};
        \\function outer() {
        \\  function inner() {}
        \\  return inner;
        \\}
        \\describe("suite", () => {
        \\  function hidden() {}
        \\});
        \\exports.handler = function () {};
        \\const obj = { "quoted-key"() {}, [computed]() {}, 42() {} };
        \\export default class { method() {} }
    );
    defer t.deinit();

    try expectSymbols(t.tree, &.{
        .{ .ref = "Outer.Inner.deep", .kind = .function },
        .{ .ref = "Widget.render", .kind = .method },
        .{ .ref = "api.users.list", .kind = .method },
        .{ .ref = "outer", .kind = .function },
        .{ .ref = "outer.inner", .kind = .function },
    });
}

test "a method named constructor in an object literal is a method, not a constructor" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const t = try test_util.TestTree.init(
        \\const o = { constructor() { return 1; } };
        \\class C { constructor() {} }
    );
    defer t.deinit();

    try expectSymbols(t.tree, &.{
        .{ .ref = "o.constructor", .kind = .method },
        .{ .ref = "C.constructor", .kind = .constructor },
    });
}

test "sources with syntax errors never produce a symbol table" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try test_util.parser();
    defer parser.deinit();
    const doc = try test_util.openFixture(parser, "broken.ts");
    defer doc.deinit();

    try testing.expectError(error.SourceHasErrors, Table.build(testing.allocator, test_util.language, doc.tree));
}

test "refs round-trip through the canonical text form and malformed refs are rejected" {
    const valid = [_]struct { input: []const u8, canonical: []const u8 }{
        .{ .input = "add", .canonical = "add" },
        .{ .input = "A.B.c@static@get", .canonical = "A.B.c@static@get" },
        .{ .input = "x@get@static", .canonical = "x@static@get" },
        .{ .input = "C.#priv", .canonical = "C.#priv" },
        .{ .input = "C.constructor", .canonical = "C.constructor" },
    };
    var buf: [128]u8 = undefined;
    for (valid) |case| {
        const ref = try Ref.parse(testing.allocator, case.input);
        defer ref.deinit(testing.allocator);
        try testing.expectEqualStrings(case.canonical, try std.fmt.bufPrint(&buf, "{f}", .{ref}));
    }

    const invalid = [_][]const u8{ "", ".a", "a.", "a..b", "a@", "@get", "a@foo", "a@none", "a@get@set", "a@static@static" };
    for (invalid) |input| {
        errdefer std.debug.print("accepted malformed ref: \"{s}\"\n", .{input});
        try testing.expectError(error.InvalidRef, Ref.parse(testing.allocator, input));
    }
}

test "hash is BLAKE3-128 of the function node and ignores edits elsewhere in the file" {
    try testing.expectEqualStrings("af1349b9f5f9a1a6a0404dea36dcc949", &formatHash(hashOf("")));

    const hex = formatHash(hashOf("function f() {}"));
    try testing.expectEqual(hashOf("function f() {}"), try parseHash(&hex));
    try testing.expectError(error.InvalidHash, parseHash("abc"));
    try testing.expectError(error.InvalidHash, parseHash("zz1349b9f5f9a1a6a0404dea36dcc949"));

    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const original = try test_util.TestTree.init("function f(a: number) { return a; }\nfunction g() {}");
    defer original.deinit();
    const moved = try test_util.TestTree.init("// header\nconst x = 1;\nfunction f(a: number) { return a; }\nfunction g() { x; }");
    defer moved.deinit();
    const edited = try test_util.TestTree.init("function f(a: number) { return a + 1; }\nfunction g() {}");
    defer edited.deinit();

    const a = try Table.build(testing.allocator, test_util.language, original.tree);
    defer a.deinit();
    const b = try Table.build(testing.allocator, test_util.language, moved.tree);
    defer b.deinit();
    const c = try Table.build(testing.allocator, test_util.language, edited.tree);
    defer c.deinit();

    const f_original = try resolveText(a, "f");
    try testing.expectEqual(hashOf(original.tree.text(f_original.node)), f_original.hash);
    try testing.expectEqual(f_original.hash, (try resolveText(b, "f")).hash);
    try testing.expect(!std.mem.eql(u8, &f_original.hash, &(try resolveText(c, "f")).hash));
    try testing.expect(!std.mem.eql(u8, &(try resolveText(a, "g")).hash, &(try resolveText(b, "g")).hash));
}

test "hash covers decorators, export, modifiers and the binding, not only the function node" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();

    const Pair = struct { ref: []const u8, plain: []const u8, changed: []const u8 };
    const pairs = [_]Pair{
        .{ .ref = "C.m", .plain = "class C { m() {} }", .changed = "class C { @memo m() {} }" },
        .{ .ref = "f", .plain = "function f() {}", .changed = "export function f() {}" },
        .{ .ref = "C.f", .plain = "class C { f = () => {}; }", .changed = "class C { private readonly f = () => {}; }" },
        .{ .ref = "f", .plain = "const f = () => {};", .changed = "const f: Handler = () => {};" },
        .{ .ref = "f", .plain = "let f = () => {};", .changed = "export const f = () => {};" },
    };
    for (pairs) |pair| {
        errdefer std.debug.print("pair: {s} | {s}\n", .{ pair.plain, pair.changed });
        const plain = try test_util.TestTree.init(pair.plain);
        defer plain.deinit();
        const changed = try test_util.TestTree.init(pair.changed);
        defer changed.deinit();
        const a = try Table.build(testing.allocator, test_util.language, plain.tree);
        defer a.deinit();
        const b = try Table.build(testing.allocator, test_util.language, changed.tree);
        defer b.deinit();
        try testing.expect(!std.mem.eql(u8, &(try resolveText(a, pair.ref)).hash, &(try resolveText(b, pair.ref)).hash));
    }
}

test "declarators sharing one statement get independent hashes that still cover the keyword" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const base = try test_util.TestTree.init("const a = () => 1, b = () => 2;\n");
    defer base.deinit();
    const a_edited = try test_util.TestTree.init("const a = () => 10, b = () => 2;\n");
    defer a_edited.deinit();
    const keyword_changed = try test_util.TestTree.init("let a = () => 1, b = () => 2;\n");
    defer keyword_changed.deinit();
    const exported = try test_util.TestTree.init("export const a = () => 1, b = () => 2;\n");
    defer exported.deinit();

    const t0 = try Table.build(testing.allocator, test_util.language, base.tree);
    defer t0.deinit();
    const t1 = try Table.build(testing.allocator, test_util.language, a_edited.tree);
    defer t1.deinit();
    const t2 = try Table.build(testing.allocator, test_util.language, keyword_changed.tree);
    defer t2.deinit();
    const t3 = try Table.build(testing.allocator, test_util.language, exported.tree);
    defer t3.deinit();

    const a0 = (try resolveText(t0, "a")).hash;
    const b0 = (try resolveText(t0, "b")).hash;
    try testing.expect(!std.mem.eql(u8, &a0, &b0));
    try testing.expectEqual(b0, (try resolveText(t1, "b")).hash);
    try testing.expect(!std.mem.eql(u8, &a0, &(try resolveText(t1, "a")).hash));
    try testing.expect(!std.mem.eql(u8, &b0, &(try resolveText(t2, "b")).hash));
    try testing.expect(!std.mem.eql(u8, &b0, &(try resolveText(t3, "b")).hash));
}

test "dotted namespace names are normalised from identifiers, ignoring spacing and comments" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const t = try test_util.TestTree.init(
        \\namespace A . B { export function f() {} }
        \\namespace A./* x.y@get */B { export function g() {} }
        \\namespace A.B { export function h() {} }
    );
    defer t.deinit();

    try expectSymbols(t.tree, &.{
        .{ .ref = "A.B.f", .kind = .function },
        .{ .ref = "A.B.g", .kind = .function },
        .{ .ref = "A.B.h", .kind = .function },
    });
}

test "every unambiguous symbol resolves back to itself through its canonical text" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try test_util.parser();
    defer parser.deinit();

    var buf: [256]u8 = undefined;
    for ([_][]const u8{ "functions.ts", "service.ts" }) |name| {
        const doc = try test_util.openFixture(parser, name);
        defer doc.deinit();
        const table = try Table.build(testing.allocator, test_util.language, doc.tree);
        defer table.deinit();

        for (table.symbols) |*entry| {
            if (entry.ambiguous) continue;
            const text = try std.fmt.bufPrint(&buf, "{f}", .{entry.ref});
            errdefer std.debug.print("round trip failed: {s} in {s}\n", .{ text, name });
            try testing.expectEqual(entry, try resolveText(table, text));
        }
    }
}

test "the hash field is a precondition: a hex hash, or absent, and nothing else" {
    const hex = formatHash(hashOf("add"));
    const present = try symbol.parseExpected(&hex);
    try testing.expectEqual(hashOf("add"), present.present);
    try testing.expectEqual(try parseHash(&hex), present.present);

    try testing.expect(try symbol.parseExpected("absent") == .absent);

    const invalid = [_][]const u8{ "", "Absent", "ABSENT", "absent ", " absent", "absent\n", "absen", "absentx", "00", hex[1..], "zz" ++ hex[2..] };
    for (invalid) |text| {
        errdefer std.debug.print("accepted hash field: \"{s}\"\n", .{text});
        try testing.expectError(error.InvalidHash, symbol.parseExpected(text));
    }
    try testing.expectError(error.InvalidHash, parseHash("absent"));

    var buffer: [symbol.hash_hex_len]u8 = undefined;
    try testing.expectEqualStrings(&hex, present.text(&buffer));
    const absent: symbol.Expected = .absent;
    try testing.expectEqualStrings("absent", absent.text(&buffer));
}
