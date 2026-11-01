const std = @import("std");
const ts = @import("../../tree_sitter.zig");
const profile_mod = @import("../profile.zig");
const python_rename = @import("rename.zig");
const python_facts = @import("facts.zig");

const Profile = profile_mod.Profile;
const FunctionKind = profile_mod.FunctionKind;
const FunctionNode = profile_mod.FunctionNode;
const MemberTraits = profile_mod.MemberTraits;
const Call = profile_mod.Call;
const Container = profile_mod.Container;
const LiteralValues = profile_mod.LiteralValues;
const Binding = profile_mod.Binding;

extern fn tree_sitter_python() callconv(.c) ?*const ts.Language;

fn grammar() *const ts.Language {
    return tree_sitter_python().?;
}

const function_nodes = [_]FunctionNode{
    .{ .node = "function_definition", .kind = .declaration },
    .{ .node = "lambda", .kind = .arrow },
};

const bindings = [_]Binding{
    .{ .parent = "assignment", .value_field = "right", .name_field = "left" },
};

const containers = [_]Container{
    .{ .node = "class_definition", .name = .field },
};

const literal_values: LiteralValues = .{
    .pair = "pair",
    .key_field = "key",
    .value_field = "value",
    .quoted_key = "string",
    .quoted_key_content = "string_content",
    .bare_pair_key = false,
    .literals = &.{ "integer", "float" },
    .negation_operator_field = "operator",
    .negation_operator = "-",
    .negation_argument_field = "argument",
    .negatable = &.{ "integer", "float" },
    .template = "string",
    .substitution = "interpolation",
    .named_arguments = &.{"keyword_argument"},
    .named_argument_name_field = "name",
    .named_argument_value_field = "value",
};

pub const profile: Profile = .{
    .name = "python",
    .extensions = &.{ ".py", ".pyi" },
    .grammar = grammar,
    .functions = &function_nodes,
    .bindings = &bindings,
    .transparent_wrappers = &.{"parenthesized_expression"},
    .addressable_names = &.{"identifier"},
    .dotted_name = "dotted_name",
    .name_segments = &.{"identifier"},
    .containers = &containers,
    .declaration_statements = &.{},
    .declarator = "",
    .export_wrappers = &.{},
    .decorator = "decorator",
    .comments = &.{"comment"},
    .block = "block",
    .root = "module",
    .identifier = "identifier",
    .reference_names = &.{"identifier"},
    .call = .{ .node = "call", .function_field = "function", .arguments_field = "arguments", .arguments = "argument_list", .optional_marker = null },
    .reexport_specifier = null,
    .namespace_exports = &.{"wildcard_import"},
    .star_token = "*",
    .dynamic_callees = &.{ "eval", "exec", "__import__", "import_module", ".import_module", "globals", "locals", "vars", "getattr", ".__getattribute__" },
    .dynamic_constructors = &.{},
    .strings = &.{"string"},
    .string_holes = &.{"interpolation"},
    .class_body = "block",
    .bodyless_terminator = null,
    .empty_body = "...",
    .expression_statement = "expression_statement",
    .prose_strings = &.{ "string", "concatenated_string" },
    .directives = &.{},
    .literal_values = literal_values,
    .memberTraits = memberTraits,
    .visibility_keywords = &.{},
    .body_wording = "its indented statements, without the def line",
    .braces = false,
    .short_refs = true,
    .parameterKey = parameterKey,
    .rename = &python_rename.grammar,
    .modules = &python_rename.modules,
    .declarations = python_rename.declarations,
    .facts = &python_facts.python,
    .import_forms = .{ .calls = &.{ "__import__", ".__import__", "import_module", ".import_module" }, .dotted = true },
    .docstrings = true,
    .definition_wrappers = &.{"decorated_definition"},
};

const Decorated = enum { staticmethod, classmethod, property, setter, deleter, getter, overload };

fn memberTraits(self: *const Profile, tree: ts.Tree, node: ts.Node, kind: FunctionKind) MemberTraits {
    _ = self;
    _ = kind;
    const wrapper = node.parent() orelse return .{};
    const decorated = std.mem.eql(u8, wrapper.kind(), "decorated_definition");
    const owner = if (decorated) wrapper.parent() else wrapper;
    const class = if (owner) |o| o.parent() else null;
    const in_class = if (class) |c| std.mem.eql(u8, owner.?.kind(), "block") and std.mem.eql(u8, c.kind(), "class_definition") else false;
    var traits: MemberTraits = .{ .is_member = in_class };
    if (in_class) if (node.childByField("name")) |name| {
        traits.is_constructor = std.mem.eql(u8, tree.text(name), "__init__");
    };
    if (!decorated) return traits;
    var i: u32 = 0;
    while (wrapper.namedChild(i)) |decorator| : (i += 1) {
        if (!std.mem.eql(u8, decorator.kind(), "decorator")) continue;
        const expression = decorator.namedChild(0) orelse continue;
        const decoration = decoratedAs(tree, expression) orelse continue;
        if (decoration == .overload) {
            traits.overload_stub = true;
            continue;
        }
        if (!in_class) continue;
        switch (decoration) {
            .staticmethod => {
                traits.is_static = true;
                traits.receiver = false;
            },
            .classmethod => traits.is_static = true,
            .property, .getter => traits.accessor = .get,
            .setter => traits.accessor = .set,
            .deleter => traits.accessor = .delete,
            .overload => unreachable,
        }
    }
    return traits;
}

fn decoratedAs(tree: ts.Tree, expression: ts.Node) ?Decorated {
    if (std.mem.eql(u8, expression.kind(), "identifier")) {
        const name = tree.text(expression);
        if (std.mem.eql(u8, name, "staticmethod")) return .staticmethod;
        if (std.mem.eql(u8, name, "classmethod")) return .classmethod;
        if (std.mem.eql(u8, name, "property")) return .property;
        if (std.mem.eql(u8, name, "overload")) return .overload;
        return null;
    }
    const attribute = expression.childByField("attribute") orelse return null;
    const name = tree.text(attribute);
    if (std.mem.eql(u8, name, "setter")) return .setter;
    if (std.mem.eql(u8, name, "deleter")) return .deleter;
    if (std.mem.eql(u8, name, "getter")) return .getter;
    if (std.mem.eql(u8, name, "overload")) return .overload;
    return null;
}

fn parameterKey(arena: std.mem.Allocator, tree: ts.Tree, node: ts.Node, full: bool) std.mem.Allocator.Error!?[]const u8 {
    if (!std.mem.eql(u8, node.kind(), "function_definition")) return null;
    const parameters = node.childByField("parameters") orelse return null;
    var key: std.ArrayList(u8) = .empty;
    try key.append(arena, '(');
    var first = true;
    var i: u32 = 0;
    while (parameters.namedChild(i)) |parameter| : (i += 1) {
        if (std.mem.eql(u8, parameter.kind(), "comment")) continue;
        if (i == 0 and isReceiver(tree, parameter)) continue;
        if (!first) try key.append(arena, ',');
        first = false;
        try key.appendSlice(arena, try profile_mod.compactSpelling(arena, tree.text(if (full) parameter else parameterIdentity(parameter))));
    }
    try key.append(arena, ')');
    return key.items;
}

fn isReceiver(tree: ts.Tree, parameter: ts.Node) bool {
    if (!std.mem.eql(u8, parameter.kind(), "identifier")) return false;
    const name = tree.text(parameter);
    return std.mem.eql(u8, name, "self") or std.mem.eql(u8, name, "cls");
}

fn parameterIdentity(parameter: ts.Node) ts.Node {
    if (parameter.childByField("type")) |annotation| return annotation;
    if (std.mem.eql(u8, parameter.kind(), "default_parameter")) return parameter.childByField("name") orelse parameter;
    return parameter;
}

const testing = std.testing;
const alloc_bridge = @import("../../alloc_bridge.zig");
const functions = @import("../../functions.zig");

const sample =
    \\import os
    \\
    \\# greet
    \\class Greeter:
    \\    def greet(self, name):
    \\        print("Hello " + name)
    \\
    \\    @staticmethod
    \\    def make():
    \\        return Greeter()
    \\
    \\    @classmethod
    \\    def build(cls):
    \\        return cls()
    \\
    \\    @property
    \\    def size(self):
    \\        return 1
    \\
    \\    @size.setter
    \\    def resize(self, value):
    \\        pass
    \\
    \\def outer():
    \\    @staticmethod
    \\    def loose():
    \\        pass
    \\
    \\handler = lambda event: event
    \\
;

fn find(tree: ts.Tree, node: ts.Node, kind: []const u8, name: []const u8) ?ts.Node {
    if (std.mem.eql(u8, node.kind(), kind)) {
        if (name.len == 0) return node;
        if (node.childByField("name")) |n| if (std.mem.eql(u8, tree.text(n), name)) return node;
    }
    var i: u32 = 0;
    while (node.child(i)) |child| : (i += 1) {
        if (find(tree, child, kind, name)) |hit| return hit;
    }
    return null;
}

fn traitsOf(tree: ts.Tree, name: []const u8) !MemberTraits {
    const node = find(tree, tree.root(), "function_definition", name) orelse return error.NotFound;
    return profile.memberTraits(&profile, tree, node, profile.functionKind(node.kind()).?);
}

test "python profile maps its node kinds onto a real tree" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();

    const parser = try ts.Parser.init(profile.grammar());
    defer parser.deinit();
    const tree = try parser.parse(sample);
    defer tree.deinit();

    const root = tree.root();
    try testing.expect(!root.hasError());
    try testing.expectEqualStrings(profile.root, root.kind());

    const class = find(tree, root, "class_definition", "Greeter").?;
    try testing.expect(profile.containerName(class.kind()) != null);
    try testing.expectEqualStrings(profile.class_body, class.childByField("body").?.kind());

    const method = find(tree, root, "function_definition", "greet").?;
    try testing.expectEqual(FunctionKind.declaration, profile.functionKind(method.kind()).?);
    try testing.expectEqualStrings(profile.block, method.childByField("body").?.kind());

    const call = find(tree, root, profile.call.node, "").?;
    try testing.expectEqualStrings("print", tree.text(call.childByField(profile.call.function_field).?));
    try testing.expectEqualStrings(profile.call.arguments, call.childByField(profile.call.arguments_field).?.kind());

    var saw_comment = false;
    var saw_string = false;
    var stack = std.ArrayList(ts.Node).empty;
    defer stack.deinit(testing.allocator);
    try stack.append(testing.allocator, root);
    while (stack.pop()) |node| {
        if (profile.isComment(node.kind())) saw_comment = true;
        for (profile.strings) |s| {
            if (std.mem.eql(u8, s, node.kind())) saw_string = true;
        }
        var i: u32 = 0;
        while (node.child(i)) |child| : (i += 1) try stack.append(testing.allocator, child);
    }
    try testing.expect(saw_comment);
    try testing.expect(saw_string);
}

test "python profile reads staticmethod, classmethod, property and setter decorators of a class member only" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();

    const parser = try ts.Parser.init(profile.grammar());
    defer parser.deinit();
    const tree = try parser.parse(sample);
    defer tree.deinit();

    try testing.expectEqual(MemberTraits{ .is_member = true }, try traitsOf(tree, "greet"));
    try testing.expectEqual(MemberTraits{ .is_static = true, .receiver = false, .is_member = true }, try traitsOf(tree, "make"));
    try testing.expectEqual(MemberTraits{ .is_static = true, .is_member = true }, try traitsOf(tree, "build"));
    try testing.expectEqual(MemberTraits{ .accessor = .get, .is_member = true }, try traitsOf(tree, "size"));
    try testing.expectEqual(MemberTraits{ .accessor = .set, .is_member = true }, try traitsOf(tree, "resize"));
    try testing.expectEqual(MemberTraits{}, try traitsOf(tree, "loose"));
}

test "python profile treats a lambda as a function named by the assignment that holds it" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();

    const parser = try ts.Parser.init(profile.grammar());
    defer parser.deinit();
    const tree = try parser.parse(sample);
    defer tree.deinit();

    const found = try functions.collectFunctions(testing.allocator, &profile, tree);
    defer testing.allocator.free(found);
    var lambda: ?functions.Function = null;
    for (found) |f| {
        if (std.mem.eql(u8, f.node.kind(), "lambda")) lambda = f;
    }
    try testing.expectEqual(FunctionKind.arrow, lambda.?.kind);
    try testing.expectEqualStrings("handler", tree.text(lambda.?.name.?));
}
