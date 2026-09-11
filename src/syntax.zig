const std = @import("std");
const ts = @import("ts.zig");
const alloc_bridge = @import("alloc_bridge.zig");
const document = @import("document.zig");

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
};

pub fn classify(node: ts.Node) ?Function {
    const kind = std.meta.stringToEnum(FunctionKind, node.kind()) orelse return null;
    const body = node.childByField("body") orelse return null;
    return .{
        .node = node,
        .kind = kind,
        .body = body,
        .name = resolveName(node),
        .nested = false,
    };
}

fn resolveName(node: ts.Node) ?ts.Node {
    if (node.childByField("name")) |name| return name;
    const parent = node.parent() orelse return null;
    for (bindings) |binding| {
        if (!std.mem.eql(u8, binding.parent, parent.kind())) continue;
        const value = parent.childByField(binding.value_field) orelse return null;
        return if (value.eql(node)) parent.childByField(binding.name_field) else null;
    }
    return null;
}

const Span = struct { start: u32, end: u32 };

pub fn collectFunctions(gpa: std.mem.Allocator, tree: ts.Tree) std.mem.Allocator.Error![]Function {
    var found: std.ArrayList(Function) = .empty;
    errdefer found.deinit(gpa);
    var open_bodies: std.ArrayList(Span) = .empty;
    defer open_bodies.deinit(gpa);

    var walker = ts.Walker.init(tree.root());
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

const testing = std.testing;

const Expected = struct {
    kind: FunctionKind,
    name: ?[]const u8,
    nested: bool = false,
};

fn expectFunctions(tree: ts.Tree, expected: []const Expected) !void {
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

test "collects every function-like boundary in the fixture, in source order" {
    alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try ts.Parser.init(ts.typescript());
    defer parser.deinit();
    const doc = try document.openFixture(parser, "functions.ts");
    defer doc.deinit();

    try expectFunctions(doc.tree, &.{
        .{ .kind = .function_declaration, .name = "add" },
        .{ .kind = .generator_function_declaration, .name = "stream" },
        .{ .kind = .function_declaration, .name = "overloaded" },
        .{ .kind = .arrow_function, .name = "validateToken" },
        .{ .kind = .function_expression, .name = "inner", .nested = true },
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
    const parser = try ts.Parser.init(ts.typescript());
    defer parser.deinit();
    const tree = try parser.parse(
        \\interface Clock { now(): number; }
        \\declare function ambient(x: string): void;
        \\abstract class Base { abstract run(): void; }
        \\function over(a: string): string;
    );
    defer tree.deinit();

    try expectFunctions(tree, &.{});
}

test "arrow functions in default parameters are not nested in the body" {
    alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try ts.Parser.init(ts.typescript());
    defer parser.deinit();
    const tree = try parser.parse("function outer(cb = () => 1) { const run = () => cb(); }");
    defer tree.deinit();

    try expectFunctions(tree, &.{
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
    const doc = try document.openFixture(parser, "functions.ts");
    defer doc.deinit();

    const functions = try collectFunctions(testing.allocator, doc.tree);
    defer testing.allocator.free(functions);
    const last = functions[functions.len - 1];

    const marker = "function afterUnicode";
    const expected_start = std.mem.indexOf(u8, doc.source, marker) orelse return error.MarkerMissing;
    try testing.expectEqual(@as(u32, @intCast(expected_start)), last.node.startByte());
    try testing.expectEqualStrings("afterUnicode", doc.tree.text(last.name.?));
}
