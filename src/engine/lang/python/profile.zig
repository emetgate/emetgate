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
    .named_argument = "keyword_argument",
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
    .namespace_exports = &.{},
    .star_token = null,
    .dynamic_callees = &.{},
    .dynamic_constructors = &.{},
    .strings = &.{"string"},
    .string_holes = &.{"interpolation"},
    .class_body = "block",
    .bodyless_terminator = null,
    .empty_body = "...",
    .expression_statement = "expression_statement",
    .prose_strings = &.{},
    .directives = &.{},
    .literal_values = literal_values,
    .memberTraits = memberTraits,
    .visibility_keywords = &.{},
    .rename = &python_rename.grammar,
    .modules = &python_rename.modules,
    .declarations = python_rename.declarations,
    .facts = &python_facts.python,
};

const Decorated = enum { staticmethod, classmethod, property, setter };

fn memberTraits(self: *const Profile, tree: ts.Tree, node: ts.Node, kind: FunctionKind) MemberTraits {
    _ = self;
    _ = kind;
    const wrapper = node.parent() orelse return .{};
    const owner = wrapper.parent() orelse return .{};
    const class = owner.parent() orelse return .{};
    if (!std.mem.eql(u8, owner.kind(), "block") or !std.mem.eql(u8, class.kind(), "class_definition")) return .{};
    var traits: MemberTraits = .{};
    var i: u32 = 0;
    while (wrapper.namedChild(i)) |decorator| : (i += 1) {
        if (!std.mem.eql(u8, decorator.kind(), "decorator")) continue;
        const expression = decorator.namedChild(0) orelse continue;
        switch (decoratedAs(tree, expression) orelse continue) {
            .staticmethod => {
                traits.is_static = true;
                traits.receiver = false;
            },
            .classmethod => traits.is_static = true,
            .property => traits.accessor = .get,
            .setter => traits.accessor = .set,
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
        return null;
    }
    const attribute = expression.childByField("attribute") orelse return null;
    const name = tree.text(attribute);
    return if (std.mem.eql(u8, name, "setter")) .setter else null;
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

    try testing.expectEqual(MemberTraits{}, try traitsOf(tree, "greet"));
    try testing.expectEqual(MemberTraits{ .is_static = true, .receiver = false }, try traitsOf(tree, "make"));
    try testing.expectEqual(MemberTraits{ .is_static = true }, try traitsOf(tree, "build"));
    try testing.expectEqual(MemberTraits{ .accessor = .get }, try traitsOf(tree, "size"));
    try testing.expectEqual(MemberTraits{ .accessor = .set }, try traitsOf(tree, "resize"));
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
