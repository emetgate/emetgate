const std = @import("std");
const ts = @import("tree_sitter.zig");
const traversal = @import("traversal.zig");

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

pub fn bindingSite(node: ts.Node) ?ts.Node {
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

pub fn bindingName(node: ts.Node) ?ts.Node {
    const site = bindingSite(node) orelse return null;
    return site.childByField(bindingFor(site).?.name_field);
}

fn bindingFor(node: ts.Node) ?Binding {
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.parent, node.kind())) return binding;
    }
    return null;
}

pub fn isOneOf(kind: []const u8, kinds: []const []const u8) bool {
    for (kinds) |candidate| {
        if (std.mem.eql(u8, candidate, kind)) return true;
    }
    return false;
}

pub const Span = struct { start: u32, end: u32 };

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
