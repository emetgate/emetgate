const std = @import("std");
const ts = @import("../../tree_sitter.zig");
const functions = @import("../../functions.zig");
const profile_mod = @import("../profile.zig");
const Accessor = @import("../../ref.zig").Accessor;

const Profile = profile_mod.Profile;
const FunctionKind = profile_mod.FunctionKind;
const MemberTraits = profile_mod.MemberTraits;

extern fn tree_sitter_typescript() callconv(.c) ?*const ts.Language;

fn grammar() *const ts.Language {
    return tree_sitter_typescript().?;
}

pub const profile: Profile = .{
    .name = "typescript",
    .extensions = &.{".ts"},
    .grammar = grammar,
    .functions = &.{
        .{ .node = "function_declaration", .kind = .declaration },
        .{ .node = "generator_function_declaration", .kind = .generator_declaration },
        .{ .node = "function_expression", .kind = .expression },
        .{ .node = "generator_function", .kind = .generator_expression },
        .{ .node = "arrow_function", .kind = .arrow },
        .{ .node = "method_definition", .kind = .method },
        .{ .node = "class_static_block", .kind = .static_block },
    },
    .bindings = &.{
        .{ .parent = "variable_declarator", .value_field = "value", .name_field = "name" },
        .{ .parent = "public_field_definition", .value_field = "value", .name_field = "name" },
        .{ .parent = "pair", .value_field = "value", .name_field = "key" },
        .{ .parent = "assignment_expression", .value_field = "right", .name_field = "left" },
        .{ .parent = "augmented_assignment_expression", .value_field = "right", .name_field = "left" },
    },
    .transparent_wrappers = &.{ "parenthesized_expression", "as_expression", "satisfies_expression", "non_null_expression" },
    .addressable_names = &.{ "identifier", "property_identifier", "private_property_identifier", "type_identifier" },
    .dotted_name = "nested_identifier",
    .name_segments = &.{ "identifier", "property_identifier", "type_identifier" },
    .containers = &.{
        .{ .node = "class_declaration", .name = .field },
        .{ .node = "abstract_class_declaration", .name = .field },
        .{ .node = "internal_module", .name = .field },
        .{ .node = "module", .name = .field },
        .{ .node = "class", .name = .field_or_binding },
        .{ .node = "object", .name = .binding },
    },
    .declaration_statements = &.{ "lexical_declaration", "variable_declaration", "expression_statement" },
    .declarator = "variable_declarator",
    .export_wrappers = &.{"export_statement"},
    .decorator = "decorator",
    .comments = &.{"comment"},
    .block = "statement_block",
    .root = "program",
    .identifier = "identifier",
    .reference_names = &.{ "identifier", "property_identifier", "shorthand_property_identifier", "shorthand_property_identifier_pattern" },
    .call = .{ .node = "call_expression", .function_field = "function", .arguments_field = "arguments", .arguments = "arguments", .optional_token = "?." },
    .reexport_specifier = "export_specifier",
    .namespace_exports = &.{"namespace_export"},
    .star_token = "*",
    .dynamic_callees = &.{ "eval", "import" },
    .dynamic_constructors = &.{.{ .node = "new_expression", .field = "constructor", .names = &.{"Function"} }},
    .strings = &.{"string"},
    .memberTraits = memberTraits,
};

fn memberTraits(self: *const Profile, tree: ts.Tree, node: ts.Node, kind: FunctionKind) MemberTraits {
    if (kind != .method) return .{ .is_static = isStaticField(self, node) };
    var accessor: Accessor = .none;
    if (keywordBeforeName(node, "get")) accessor = .get;
    if (keywordBeforeName(node, "set")) accessor = .set;
    return .{
        .accessor = accessor,
        .is_static = keywordBeforeName(node, "static"),
        .is_constructor = isConstructor(tree, node),
    };
}

fn isStaticField(self: *const Profile, node: ts.Node) bool {
    const site = functions.bindingSite(self, node) orelse return false;
    return std.mem.eql(u8, "public_field_definition", site.kind()) and keywordBeforeName(site, "static");
}

fn isConstructor(tree: ts.Tree, node: ts.Node) bool {
    const name = node.childByField("name") orelse return false;
    const parent = node.parent() orelse return false;
    return std.mem.eql(u8, "class_body", parent.kind()) and std.mem.eql(u8, "constructor", tree.text(name));
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
