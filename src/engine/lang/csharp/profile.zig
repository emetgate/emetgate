const ts = @import("../../tree_sitter.zig");
const profile_mod = @import("../profile.zig");
const csharp_rename = @import("rename.zig");
const csharp_facts = @import("facts.zig");

const Profile = profile_mod.Profile;
const FunctionKind = profile_mod.FunctionKind;
const FunctionNode = profile_mod.FunctionNode;
const FunctionName = profile_mod.FunctionName;
const Accessor = @import("../../ref.zig").Accessor;
const MemberTraits = profile_mod.MemberTraits;
const Container = profile_mod.Container;
const LiteralValues = profile_mod.LiteralValues;
const Binding = profile_mod.Binding;

extern fn tree_sitter_c_sharp() callconv(.c) ?*const ts.Language;

fn grammar() *const ts.Language {
    return tree_sitter_c_sharp().?;
}

const function_nodes = [_]FunctionNode{
    .{ .node = "method_declaration", .kind = .method },
    .{ .node = "constructor_declaration", .kind = .method },
    .{ .node = "local_function_statement", .kind = .declaration },
    .{ .node = "accessor_declaration", .kind = .method },
    .{ .node = "operator_declaration", .kind = .method },
    .{ .node = "conversion_operator_declaration", .kind = .method },
    .{ .node = "destructor_declaration", .kind = .method },
    .{ .node = "lambda_expression", .kind = .arrow },
};

const function_names = [_]FunctionName{
    .{ .node = "accessor_declaration", .owner_depth = 2, .field = "name" },
    .{ .node = "operator_declaration", .field = null },
    .{ .node = "conversion_operator_declaration", .field = null },
    .{ .node = "destructor_declaration", .field = null },
};

const containers = [_]Container{
    .{ .node = "class_declaration", .name = .field },
    .{ .node = "struct_declaration", .name = .field },
    .{ .node = "interface_declaration", .name = .field },
    .{ .node = "enum_declaration", .name = .field },
    .{ .node = "record_declaration", .name = .field },
    .{ .node = "namespace_declaration", .name = .field },
    .{ .node = "file_scoped_namespace_declaration", .name = .field },
};

const bindings = [_]Binding{
    .{ .parent = "variable_declarator", .value_field = "", .name_field = "name" },
    .{ .parent = "assignment_expression", .value_field = "right", .name_field = "left" },
    .{ .parent = "property_declaration", .value_field = "value", .name_field = "name" },
};

const literal_values: LiteralValues = .{
    .pair = "assignment_expression",
    .key_field = "left",
    .value_field = "right",
    .quoted_key = "string_literal",
    .quoted_key_content = "string_literal_content",
    .literals = &.{ "integer_literal", "real_literal", "string_literal", "verbatim_string_literal", "raw_string_literal", "character_literal" },
    .negation_operator_field = "",
    .negation_operator = "-",
    .negation_argument_field = "",
    .negatable = &.{ "integer_literal", "real_literal" },
    .template = "interpolated_string_expression",
    .substitution = "interpolation",
    .named_arguments = &.{ "argument", "attribute_argument" },
    .named_argument_name_field = "name",
    .named_argument_value_field = "",
    .pair_parent = "initializer_expression",
    .equals_pairs = &.{ "anonymous_object_creation_expression", "with_initializer" },
    .entry_pair = "initializer_expression",
    .indexed_key = "element_binding_expression",
    .negation_unary = "prefix_unary_expression",
};

pub const profile: Profile = .{
    .name = "csharp",
    .extensions = &.{".cs"},
    .grammar = grammar,
    .functions = &function_nodes,
    .bindings = &bindings,
    .transparent_wrappers = &.{"parenthesized_expression"},
    .addressable_names = &.{"identifier"},
    .dotted_name = "qualified_name",
    .name_segments = &.{"identifier"},
    .containers = &containers,
    .declaration_statements = &.{ "variable_declaration", "local_declaration_statement", "field_declaration" },
    .declarator = "variable_declarator",
    .export_wrappers = &.{},
    .decorator = "attribute_list",
    .comments = &.{"comment"},
    .block = "block",
    .root = "compilation_unit",
    .identifier = "identifier",
    .reference_names = &.{"identifier"},
    .call = .{ .node = "invocation_expression", .function_field = "function", .arguments_field = "arguments", .arguments = "argument_list", .optional_marker = null },
    .reexport_specifier = null,
    .namespace_exports = &.{},
    .star_token = null,
    .dynamic_callees = &.{ "Activator.CreateInstance", ".Activator.CreateInstance", "Assembly.Load", ".Assembly.Load", "Assembly.LoadFrom", ".Assembly.LoadFrom", "Type.GetType", ".Type.GetType", ".GetMethod", ".GetProperty", ".GetField", ".GetMember", ".InvokeMember" },
    .dynamic_constructors = &.{},
    .strings = &.{ "string_literal", "verbatim_string_literal", "raw_string_literal", "interpolated_string_expression" },
    .string_holes = &.{"interpolation"},
    .class_body = "declaration_list",
    .bodyless_terminator = ";",
    .empty_body = "{}",
    .expression_statement = "expression_statement",
    .prose_strings = &.{ "string_literal", "verbatim_string_literal", "raw_string_literal" },
    .directives = &.{},
    .literal_values = literal_values,
    .memberTraits = memberTraits,
    .visibility_keywords = &.{ "public", "protected", "internal" },
    .modifier = "modifier",
    .function_names = &function_names,
    .file_scoped_containers = &.{"file_scoped_namespace_declaration"},
    .rename = &csharp_rename.grammar,
    .modules = &csharp_rename.modules,
    .declarations = csharp_rename.declarations(),
    .facts = &csharp_facts.csharp,
    .import_forms = .{ .calls = &.{ "Assembly.Load", ".Assembly.Load", "Assembly.LoadFrom", ".Assembly.LoadFrom", "Type.GetType", ".Type.GetType" }, .dotted = true, .directive = "using_directive" },
    .commented_definitions = &.{ "class_declaration", "struct_declaration", "interface_declaration", "enum_declaration", "record_declaration", "delegate_declaration" },
    .uncommented_definitions = &.{"accessor_declaration"},
};

fn memberTraits(self: *const Profile, tree: ts.Tree, node: ts.Node, kind: FunctionKind) MemberTraits {
    _ = self;
    _ = kind;
    if (isKind(node, "accessor_declaration")) {
        const owner = (node.parent() orelse return .{}).parent() orelse return .{};
        return .{ .accessor = accessorOf(node), .is_static = hasStaticModifier(tree, owner) };
    }
    return .{
        .is_constructor = isKind(node, "constructor_declaration"),
        .is_static = hasStaticModifier(tree, node),
    };
}

fn accessorOf(node: ts.Node) Accessor {
    const name = node.childByField("name") orelse return .none;
    if (isKind(name, "get")) return .get;
    if (isKind(name, "set") or isKind(name, "init")) return .set;
    return .none;
}

fn isKind(node: ts.Node, name: []const u8) bool {
    return std.mem.eql(u8, node.kind(), name);
}

fn hasStaticModifier(tree: ts.Tree, node: ts.Node) bool {
    var i: u32 = 0;
    while (node.child(i)) |child| : (i += 1) {
        if (!std.mem.eql(u8, child.kind(), "modifier")) continue;
        if (std.mem.eql(u8, tree.text(child), "static")) return true;
    }
    return false;
}

const std = @import("std");
const testing = std.testing;
const alloc_bridge = @import("../../alloc_bridge.zig");

const sample =
    \\using System;
    \\
    \\namespace Demo
    \\{
    \\    public class Greeter
    \\    {
    \\        // greet
    \\        public void Greet(string name)
    \\        {
    \\            Console.WriteLine("Hello " + name);
    \\        }
    \\    }
    \\}
;

test "csharp profile maps its node kinds onto a real tree" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();

    const parser = try ts.Parser.init(profile.grammar());
    defer parser.deinit();
    const tree = try parser.parse(sample);
    defer tree.deinit();

    const root = tree.root();
    try testing.expect(!root.hasError());
    try testing.expectEqualStrings(profile.root, root.kind());

    const class = find(root, "class_declaration").?;
    try testing.expect(profile.containerName(class.kind()) != null);
    try testing.expectEqualStrings("Greeter", tree.text(class.childByField("name").?));

    const method = find(root, "method_declaration").?;
    try testing.expectEqual(FunctionKind.method, profile.functionKind(method.kind()).?);
    try testing.expectEqualStrings("Greet", tree.text(method.childByField("name").?));
    try testing.expectEqualStrings(profile.block, method.childByField("body").?.kind());

    const call = find(root, profile.call.node).?;
    try testing.expectEqualStrings("Console.WriteLine", tree.text(call.childByField(profile.call.function_field).?));
    try testing.expectEqualStrings(profile.call.arguments, call.childByField(profile.call.arguments_field).?.kind());
}

fn find(node: ts.Node, kind: []const u8) ?ts.Node {
    if (std.mem.eql(u8, node.kind(), kind)) return node;
    var i: u32 = 0;
    while (node.child(i)) |child| : (i += 1) {
        if (find(child, kind)) |hit| return hit;
    }
    return null;
}

test "csharp profile recognises comments and string literals" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();

    const parser = try ts.Parser.init(profile.grammar());
    defer parser.deinit();
    const tree = try parser.parse(sample);
    defer tree.deinit();

    var saw_comment = false;
    var saw_string = false;
    var stack = std.ArrayList(ts.Node).empty;
    defer stack.deinit(testing.allocator);
    try stack.append(testing.allocator, tree.root());
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
