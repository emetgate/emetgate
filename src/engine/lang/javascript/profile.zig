const ts = @import("../../tree_sitter.zig");
const ecma = @import("../ecma/common.zig");
const profile_mod = @import("../profile.zig");
const ecma_rename = @import("../ecma/rename.zig");

const Profile = profile_mod.Profile;
const FunctionKind = profile_mod.FunctionKind;
const MemberTraits = profile_mod.MemberTraits;
const Binding = profile_mod.Binding;

extern fn tree_sitter_javascript() callconv(.c) ?*const ts.Language;

fn grammar() *const ts.Language {
    return tree_sitter_javascript().?;
}

const field_shape: ecma.FieldShape = .{ .node = "field_definition", .name_field = "property" };

pub const profile: Profile = .{
    .name = "javascript",
    .extensions = &.{ ".js", ".mjs", ".cjs", ".jsx" },
    .grammar = grammar,
    .functions = &ecma.function_nodes,
    .bindings = &(ecma.value_bindings ++ [_]Binding{
        .{ .parent = field_shape.node, .value_field = "value", .name_field = field_shape.name_field },
    }),
    .transparent_wrappers = &.{"parenthesized_expression"},
    .addressable_names = &.{ "identifier", "property_identifier", "private_property_identifier" },
    .dotted_name = null,
    .name_segments = &.{ "identifier", "property_identifier" },
    .containers = &ecma.containers,
    .declaration_statements = &ecma.declaration_statements,
    .declarator = "variable_declarator",
    .export_wrappers = &ecma.export_wrappers,
    .decorator = "decorator",
    .comments = &ecma.comments,
    .block = "statement_block",
    .root = "program",
    .identifier = "identifier",
    .reference_names = &ecma.reference_names,
    .call = ecma.call("optional_chain"),
    .reexport_specifier = "export_specifier",
    .namespace_exports = &ecma.namespace_exports,
    .star_token = "*",
    .dynamic_callees = &ecma.dynamic_callees,
    .dynamic_constructors = &ecma.dynamic_constructors,
    .strings = &ecma.strings,
    .class_body = "class_body",
    .bodyless_terminator = null,
    .empty_body = "{}",
    .expression_statement = "expression_statement",
    .prose_strings = &ecma.prose_strings,
    .directives = &ecma.directives,
    .literal_values = ecma.literal_values,
    .memberTraits = memberTraits,
    .rename = &ecma_rename.grammar,
    .modules = &ecma_rename.modules,
    .declarations = ecma_rename.declarations(.{ .node = field_shape.node, .kind = .field, .name_field = field_shape.name_field }),
};

fn memberTraits(self: *const Profile, tree: ts.Tree, node: ts.Node, kind: FunctionKind) MemberTraits {
    return ecma.memberTraits(self, tree, node, kind, field_shape);
}
