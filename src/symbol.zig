const std = @import("std");
const ts = @import("tree_sitter.zig");
const traversal = @import("traversal.zig");
const alloc_bridge = @import("alloc_bridge.zig");
const test_util = @import("test_util.zig");

const Allocator = std.mem.Allocator;

pub const FunctionKind = enum {
    function_declaration,
    generator_function_declaration,
    function_expression,
    generator_function,
    arrow_function,
    method_definition,
    class_static_block,
};

pub const Function = struct {
    node: ts.Node,
    kind: FunctionKind,
    body: ts.Node,
    name: ?ts.Node,
    nested: bool,
};

const Binding = struct {
    parent: []const u8,
    value_field: []const u8,
    name_field: []const u8,
};

const bindings = [_]Binding{
    .{ .parent = "variable_declarator", .value_field = "value", .name_field = "name" },
    .{ .parent = "public_field_definition", .value_field = "value", .name_field = "name" },
    .{ .parent = "pair", .value_field = "value", .name_field = "key" },
    .{ .parent = "assignment_expression", .value_field = "right", .name_field = "left" },
    .{ .parent = "augmented_assignment_expression", .value_field = "right", .name_field = "left" },
};

const transparent_wrappers = [_][]const u8{
    "parenthesized_expression",
    "as_expression",
    "satisfies_expression",
    "non_null_expression",
};

const addressable_name_kinds = [_][]const u8{
    "identifier",
    "property_identifier",
    "private_property_identifier",
    "type_identifier",
};

const container_name_kinds = addressable_name_kinds ++ [_][]const u8{"nested_identifier"};

const declared_containers = [_][]const u8{
    "class_declaration",
    "abstract_class_declaration",
    "internal_module",
    "module",
};

pub fn classify(node: ts.Node) ?Function {
    const kind = std.meta.stringToEnum(FunctionKind, node.kind()) orelse return null;
    const body = node.childByField("body") orelse return null;
    return .{
        .node = node,
        .kind = kind,
        .body = body,
        .name = resolveName(node, kind),
        .nested = false,
    };
}

fn resolveName(node: ts.Node, kind: FunctionKind) ?ts.Node {
    const own = node.childByField("name");
    return switch (kind) {
        .function_declaration, .generator_function_declaration, .method_definition => own,
        else => bindingName(node) orelse own,
    };
}

fn bindingSite(node: ts.Node) ?ts.Node {
    var value = node;
    var parent = node.parent() orelse return null;
    while (isOneOf(parent.kind(), &transparent_wrappers)) {
        value = parent;
        parent = parent.parent() orelse return null;
    }
    const binding = bindingFor(parent) orelse return null;
    const bound = parent.childByField(binding.value_field) orelse return null;
    return if (bound.eql(value)) parent else null;
}

fn bindingName(node: ts.Node) ?ts.Node {
    const site = bindingSite(node) orelse return null;
    return site.childByField(bindingFor(site).?.name_field);
}

fn bindingFor(node: ts.Node) ?Binding {
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.parent, node.kind())) return binding;
    }
    return null;
}

fn isOneOf(kind: []const u8, kinds: []const []const u8) bool {
    for (kinds) |candidate| {
        if (std.mem.eql(u8, candidate, kind)) return true;
    }
    return false;
}

const Span = struct { start: u32, end: u32 };

pub fn collectFunctions(gpa: Allocator, tree: ts.Tree) Allocator.Error![]Function {
    var found: std.ArrayList(Function) = .empty;
    errdefer found.deinit(gpa);
    var open_bodies: std.ArrayList(Span) = .empty;
    defer open_bodies.deinit(gpa);

    var walker = traversal.Walker.init(tree.root());
    defer walker.deinit();
    while (walker.next()) |entry| {
        if (!entry.node.isNamed()) continue;
        var function = classify(entry.node) orelse continue;
        const start = entry.node.startByte();
        while (open_bodies.getLastOrNull()) |body| {
            if (start < body.end) break;
            _ = open_bodies.pop();
        }
        function.nested = insideAny(open_bodies.items, start);
        try open_bodies.append(gpa, .{ .start = function.body.startByte(), .end = function.body.endByte() });
        try found.append(gpa, function);
    }
    return found.toOwnedSlice(gpa);
}

fn insideAny(bodies: []const Span, offset: u32) bool {
    for (bodies) |body| {
        if (offset >= body.start and offset < body.end) return true;
    }
    return false;
}

pub const Hash = [16]u8;
pub const hash_hex_len = @sizeOf(Hash) * 2;

pub fn hashOf(text: []const u8) Hash {
    var out: Hash = undefined;
    std.crypto.hash.Blake3.hash(text, &out, .{});
    return out;
}

pub fn formatHash(hash: Hash) [hash_hex_len]u8 {
    return std.fmt.bytesToHex(hash, .lower);
}

pub fn parseHash(hex: []const u8) error{InvalidHash}!Hash {
    if (hex.len != hash_hex_len) return error.InvalidHash;
    var out: Hash = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch return error.InvalidHash;
    return out;
}

pub const Kind = enum {
    function,
    generator,
    method,
    getter,
    setter,
    constructor,
    arrow,
    function_expression,
};

pub const Accessor = enum { none, get, set };

pub const Ref = struct {
    container: []const []const u8 = &.{},
    name: []const u8,
    accessor: Accessor = .none,
    is_static: bool = false,

    pub const ParseError = error{InvalidRef} || Allocator.Error;

    pub fn parse(gpa: Allocator, text: []const u8) ParseError!Ref {
        const qualifier_start = std.mem.indexOfScalar(u8, text, '@') orelse text.len;
        var ref: Ref = .{ .name = undefined };
        if (qualifier_start < text.len) try ref.applyQualifiers(text[qualifier_start + 1 ..]);

        const path = text[0..qualifier_start];
        const container = try gpa.alloc([]const u8, std.mem.count(u8, path, "."));
        errdefer gpa.free(container);
        var segments = std.mem.splitScalar(u8, path, '.');
        for (container) |*segment| segment.* = try nonEmpty(segments.next().?);
        ref.name = try nonEmpty(segments.next().?);
        ref.container = container;
        return ref;
    }

    pub fn deinit(self: Ref, gpa: Allocator) void {
        gpa.free(self.container);
    }

    fn applyQualifiers(self: *Ref, text: []const u8) error{InvalidRef}!void {
        var qualifiers = std.mem.splitScalar(u8, text, '@');
        while (qualifiers.next()) |qualifier| {
            if (std.mem.eql(u8, qualifier, "static")) {
                if (self.is_static) return error.InvalidRef;
                self.is_static = true;
                continue;
            }
            const accessor = std.meta.stringToEnum(Accessor, qualifier) orelse return error.InvalidRef;
            if (accessor == .none or self.accessor != .none) return error.InvalidRef;
            self.accessor = accessor;
        }
    }

    pub fn format(self: Ref, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.container) |segment| try writer.print("{s}.", .{segment});
        try writer.writeAll(self.name);
        if (self.is_static) try writer.writeAll("@static");
        if (self.accessor != .none) try writer.print("@{t}", .{self.accessor});
    }

    pub fn eql(a: Ref, b: Ref) bool {
        if (a.accessor != b.accessor or a.is_static != b.is_static) return false;
        if (!std.mem.eql(u8, a.name, b.name) or a.container.len != b.container.len) return false;
        for (a.container, b.container) |x, y| {
            if (!std.mem.eql(u8, x, y)) return false;
        }
        return true;
    }
};

fn nonEmpty(segment: []const u8) error{InvalidRef}![]const u8 {
    return if (segment.len == 0) error.InvalidRef else segment;
}

pub const Symbol = struct {
    ref: Ref,
    kind: Kind,
    node: ts.Node,
    body: ts.Node,
    hash: Hash,
    ambiguous: bool = false,
};

pub const Table = struct {
    arena: *std.heap.ArenaAllocator,
    symbols: []Symbol,

    pub const BuildError = error{SourceHasErrors} || Allocator.Error;
    pub const ResolveError = error{ SymbolNotFound, AmbiguousSymbol };

    pub fn build(gpa: Allocator, tree: ts.Tree) BuildError!Table {
        if (tree.root().hasError()) return error.SourceHasErrors;

        const arena = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena);
        arena.* = .init(gpa);
        errdefer arena.deinit();

        const functions = try collectFunctions(gpa, tree);
        defer gpa.free(functions);

        var symbols: std.ArrayList(Symbol) = .empty;
        for (functions) |function| {
            const symbol = try describe(arena.allocator(), tree, function) orelse continue;
            try symbols.append(arena.allocator(), symbol);
        }
        markAmbiguous(symbols.items);
        return .{ .arena = arena, .symbols = symbols.items };
    }

    pub fn deinit(self: Table) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self.arena);
    }

    pub fn resolve(self: Table, ref: Ref) ResolveError!*const Symbol {
        var found: ?*const Symbol = null;
        for (self.symbols) |*symbol| {
            if (!symbol.ref.eql(ref)) continue;
            if (found != null) return error.AmbiguousSymbol;
            found = symbol;
        }
        return found orelse error.SymbolNotFound;
    }
};

fn markAmbiguous(symbols: []Symbol) void {
    for (symbols, 0..) |*a, i| {
        for (symbols[i + 1 ..]) |*b| {
            if (!a.ref.eql(b.ref)) continue;
            a.ambiguous = true;
            b.ambiguous = true;
        }
    }
}

fn describe(arena: Allocator, tree: ts.Tree, function: Function) Allocator.Error!?Symbol {
    const kind = symbolKind(tree, function) orelse return null;
    const name = function.name orelse return null;
    if (!isOneOf(name.kind(), &addressable_name_kinds)) return null;
    const container = try containerPath(arena, tree, function.node) orelse return null;
    return .{
        .ref = .{
            .container = container,
            .name = tree.text(name),
            .accessor = accessorOf(function),
            .is_static = isStatic(function),
        },
        .kind = kind,
        .node = function.node,
        .body = function.body,
        .hash = hashOf(tree.text(function.node)),
    };
}

fn symbolKind(tree: ts.Tree, function: Function) ?Kind {
    return switch (function.kind) {
        .function_declaration => .function,
        .generator_function_declaration, .generator_function => .generator,
        .function_expression => .function_expression,
        .arrow_function => .arrow,
        .class_static_block => null,
        .method_definition => switch (accessorOf(function)) {
            .get => .getter,
            .set => .setter,
            .none => if (isConstructor(tree, function)) .constructor else .method,
        },
    };
}

fn isConstructor(tree: ts.Tree, function: Function) bool {
    const name = function.name orelse return false;
    const parent = function.node.parent() orelse return false;
    return std.mem.eql(u8, "class_body", parent.kind()) and std.mem.eql(u8, "constructor", tree.text(name));
}

fn accessorOf(function: Function) Accessor {
    if (function.kind != .method_definition) return .none;
    if (keywordBeforeName(function.node, "get")) return .get;
    if (keywordBeforeName(function.node, "set")) return .set;
    return .none;
}

fn isStatic(function: Function) bool {
    if (function.kind == .method_definition) return keywordBeforeName(function.node, "static");
    const site = bindingSite(function.node) orelse return false;
    return std.mem.eql(u8, "public_field_definition", site.kind()) and keywordBeforeName(site, "static");
}

fn keywordBeforeName(holder: ts.Node, keyword: []const u8) bool {
    const name = holder.childByField("name") orelse return false;
    var i: u32 = 0;
    while (holder.child(i)) |child| : (i += 1) {
        if (child.eql(name)) return false;
        if (!child.isNamed() and std.mem.eql(u8, keyword, child.kind())) return true;
    }
    return false;
}

const ContainerRole = union(enum) {
    transparent,
    unnamed,
    named: ts.Node,
};

fn containerRole(node: ts.Node) ContainerRole {
    const kind = node.kind();
    const name: ?ts.Node = if (classify(node)) |function|
        function.name
    else if (isOneOf(kind, &declared_containers))
        node.childByField("name")
    else if (std.mem.eql(u8, kind, "class"))
        node.childByField("name") orelse bindingName(node)
    else if (std.mem.eql(u8, kind, "object"))
        bindingName(node)
    else
        return .transparent;
    return if (name) |n| .{ .named = n } else .unnamed;
}

fn containerPath(arena: Allocator, tree: ts.Tree, node: ts.Node) Allocator.Error!?[]const []const u8 {
    var reversed: std.ArrayList([]const u8) = .empty;
    var current = node.parent();
    while (current) |ancestor| : (current = ancestor.parent()) {
        const name = switch (containerRole(ancestor)) {
            .transparent => continue,
            .unnamed => return null,
            .named => |name| name,
        };
        if (!isOneOf(name.kind(), &container_name_kinds)) return null;
        var segments = std.mem.splitBackwardsScalar(u8, tree.text(name), '.');
        while (segments.next()) |segment| try reversed.append(arena, segment);
    }
    std.mem.reverse([]const u8, reversed.items);
    return reversed.items;
}

const testing = std.testing;

const ExpectedFunction = struct {
    kind: FunctionKind,
    name: ?[]const u8,
    nested: bool = false,
};

fn expectFunctions(tree: ts.Tree, expected: []const ExpectedFunction) !void {
    const functions = try collectFunctions(testing.allocator, tree);
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
    const table = try Table.build(testing.allocator, tree);
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
    alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try ts.Parser.init(ts.typescript());
    defer parser.deinit();
    const doc = try test_util.openFixture(parser, "functions.ts");
    defer doc.deinit();

    try expectFunctions(doc.tree, &.{
        .{ .kind = .function_declaration, .name = "add" },
        .{ .kind = .generator_function_declaration, .name = "stream" },
        .{ .kind = .function_declaration, .name = "overloaded" },
        .{ .kind = .arrow_function, .name = "validateToken" },
        .{ .kind = .function_expression, .name = "helper", .nested = true },
        .{ .kind = .arrow_function, .name = "square" },
        .{ .kind = .function_expression, .name = null },
        .{ .kind = .arrow_function, .name = "handler" },
        .{ .kind = .class_static_block, .name = null },
        .{ .kind = .method_definition, .name = "constructor" },
        .{ .kind = .method_definition, .name = "label" },
        .{ .kind = .method_definition, .name = "label" },
        .{ .kind = .method_definition, .name = "now" },
        .{ .kind = .method_definition, .name = "ids" },
        .{ .kind = .method_definition, .name = "home" },
        .{ .kind = .arrow_function, .name = "about" },
        .{ .kind = .function_declaration, .name = "old" },
        .{ .kind = .arrow_function, .name = null },
        .{ .kind = .function_declaration, .name = "afterUnicode" },
    });
}

test "bodyless signatures are not function boundaries" {
    alloc_bridge.install(testing.allocator);
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
    alloc_bridge.install(testing.allocator);
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
        .{ .kind = .arrow_function, .name = "asserted" },
        .{ .kind = .function_expression, .name = "checked" },
        .{ .kind = .arrow_function, .name = "forced" },
        .{ .kind = .arrow_function, .name = "exports.lazy" },
        .{ .kind = .arrow_function, .name = null },
    });
}

test "arrow functions in default parameters are not nested in the body" {
    alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const t = try test_util.TestTree.init("function outer(cb = () => 1) { const run = () => cb(); }");
    defer t.deinit();

    try expectFunctions(t.tree, &.{
        .{ .kind = .function_declaration, .name = "outer" },
        .{ .kind = .arrow_function, .name = null },
        .{ .kind = .arrow_function, .name = "run", .nested = true },
    });
}

test "byte offsets stay exact after multi-byte UTF-8 text" {
    alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try ts.Parser.init(ts.typescript());
    defer parser.deinit();
    const doc = try test_util.openFixture(parser, "functions.ts");
    defer doc.deinit();

    const functions = try collectFunctions(testing.allocator, doc.tree);
    defer testing.allocator.free(functions);
    const last = functions[functions.len - 1];

    const marker = "function afterUnicode";
    const expected_start = std.mem.indexOf(u8, doc.source, marker) orelse return error.MarkerMissing;
    try testing.expectEqual(@as(u32, @intCast(expected_start)), last.node.startByte());
    try testing.expectEqualStrings("afterUnicode", doc.tree.text(last.name.?));
}

test "symbol table of the fixture names every addressable function with its container" {
    alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try ts.Parser.init(ts.typescript());
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
    alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try ts.Parser.init(ts.typescript());
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
    alloc_bridge.install(testing.allocator);
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

    const table = try Table.build(testing.allocator, t.tree);
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
    alloc_bridge.install(testing.allocator);
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

test "sources with syntax errors never produce a symbol table" {
    alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try ts.Parser.init(ts.typescript());
    defer parser.deinit();
    const doc = try test_util.openFixture(parser, "broken.ts");
    defer doc.deinit();

    try testing.expectError(error.SourceHasErrors, Table.build(testing.allocator, doc.tree));
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

    alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const original = try test_util.TestTree.init("function f(a: number) { return a; }\nfunction g() {}");
    defer original.deinit();
    const moved = try test_util.TestTree.init("// header\nconst x = 1;\nfunction f(a: number) { return a; }\nfunction g() { x; }");
    defer moved.deinit();
    const edited = try test_util.TestTree.init("function f(a: number) { return a + 1; }\nfunction g() {}");
    defer edited.deinit();

    const a = try Table.build(testing.allocator, original.tree);
    defer a.deinit();
    const b = try Table.build(testing.allocator, moved.tree);
    defer b.deinit();
    const c = try Table.build(testing.allocator, edited.tree);
    defer c.deinit();

    const f_original = try resolveText(a, "f");
    try testing.expectEqual(hashOf(original.tree.text(f_original.node)), f_original.hash);
    try testing.expectEqual(f_original.hash, (try resolveText(b, "f")).hash);
    try testing.expect(!std.mem.eql(u8, &f_original.hash, &(try resolveText(c, "f")).hash));
    try testing.expect(!std.mem.eql(u8, &(try resolveText(a, "g")).hash, &(try resolveText(b, "g")).hash));
}
