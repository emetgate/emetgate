const std = @import("std");
const ts = @import("../../tree_sitter.zig");
const functions = @import("../../functions.zig");
const profile_mod = @import("../profile.zig");
const Accessor = @import("../../ref.zig").Accessor;

const Profile = profile_mod.Profile;
const FunctionKind = profile_mod.FunctionKind;
const FunctionNode = profile_mod.FunctionNode;
const Binding = profile_mod.Binding;
const Container = profile_mod.Container;
const MemberTraits = profile_mod.MemberTraits;
const DynamicConstructor = profile_mod.DynamicConstructor;
const Call = profile_mod.Call;

pub const function_nodes = [_]FunctionNode{
    .{ .node = "function_declaration", .kind = .declaration },
    .{ .node = "generator_function_declaration", .kind = .generator_declaration },
    .{ .node = "function_expression", .kind = .expression },
    .{ .node = "generator_function", .kind = .generator_expression },
    .{ .node = "arrow_function", .kind = .arrow },
    .{ .node = "method_definition", .kind = .method },
    .{ .node = "class_static_block", .kind = .static_block },
};

pub const value_bindings = [_]Binding{
    .{ .parent = "variable_declarator", .value_field = "value", .name_field = "name" },
    .{ .parent = "pair", .value_field = "value", .name_field = "key" },
    .{ .parent = "assignment_expression", .value_field = "right", .name_field = "left" },
    .{ .parent = "augmented_assignment_expression", .value_field = "right", .name_field = "left" },
};

pub const containers = [_]Container{
    .{ .node = "class_declaration", .name = .field },
    .{ .node = "class", .name = .field_or_binding },
    .{ .node = "object", .name = .binding },
};

pub const declaration_statements = [_][]const u8{ "lexical_declaration", "variable_declaration", "expression_statement" };
pub const reference_names = [_][]const u8{ "identifier", "property_identifier", "shorthand_property_identifier", "shorthand_property_identifier_pattern" };
pub const comments = [_][]const u8{"comment"};
pub const export_wrappers = [_][]const u8{"export_statement"};
pub const namespace_exports = [_][]const u8{"namespace_export"};
pub const dynamic_callees = [_][]const u8{ "eval", "import" };
pub const dynamic_constructors = [_]DynamicConstructor{.{ .node = "new_expression", .field = "constructor", .names = &.{"Function"} }};
pub const strings = [_][]const u8{"string"};
pub const prose_strings = [_][]const u8{ "string", "template_string" };
pub const directives = [_][]const u8{ "\"use strict\"", "'use strict'" };

pub fn call(optional_marker: []const u8) Call {
    return .{ .node = "call_expression", .function_field = "function", .arguments_field = "arguments", .arguments = "arguments", .optional_marker = optional_marker };
}

pub const FieldShape = struct {
    node: []const u8,
    name_field: []const u8,
};

pub fn memberTraits(self: *const Profile, tree: ts.Tree, node: ts.Node, kind: FunctionKind, field: FieldShape) MemberTraits {
    if (kind != .method) return .{ .is_static = isStaticField(self, node, field) };
    var accessor: Accessor = .none;
    if (keywordBeforeName(node, "name", "get")) accessor = .get;
    if (keywordBeforeName(node, "name", "set")) accessor = .set;
    return .{
        .accessor = accessor,
        .is_static = keywordBeforeName(node, "name", "static"),
        .is_constructor = isConstructor(tree, node),
    };
}

fn isStaticField(self: *const Profile, node: ts.Node, field: FieldShape) bool {
    const site = functions.bindingSite(self, node) orelse return false;
    return std.mem.eql(u8, field.node, site.kind()) and keywordBeforeName(site, field.name_field, "static");
}

fn isConstructor(tree: ts.Tree, node: ts.Node) bool {
    const name = node.childByField("name") orelse return false;
    const parent = node.parent() orelse return false;
    return std.mem.eql(u8, "class_body", parent.kind()) and std.mem.eql(u8, "constructor", tree.text(name));
}

fn keywordBeforeName(holder: ts.Node, name_field: []const u8, keyword: []const u8) bool {
    const name = holder.childByField(name_field) orelse return false;
    var i: u32 = 0;
    while (holder.child(i)) |child| : (i += 1) {
        if (child.eql(name)) return false;
        if (!child.isNamed() and std.mem.eql(u8, keyword, child.kind())) return true;
    }
    return false;
}
