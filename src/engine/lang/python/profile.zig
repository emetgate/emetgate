const ts = @import("../../tree_sitter.zig");
const profile_mod = @import("../profile.zig");

const Profile = profile_mod.Profile;
const FunctionKind = profile_mod.FunctionKind;
const FunctionNode = profile_mod.FunctionNode;
const MemberTraits = profile_mod.MemberTraits;
const Call = profile_mod.Call;
const Container = profile_mod.Container;
const LiteralValues = profile_mod.LiteralValues;

extern fn tree_sitter_python() callconv(.c) ?*const ts.Language;

fn grammar() *const ts.Language {
    return tree_sitter_python().?;
}

const function_nodes = [_]FunctionNode{
    .{ .node = "function_definition", .kind = .declaration },
};

const containers = [_]Container{
    .{ .node = "class_definition", .name = .field },
};

const never_matching_literal_values: LiteralValues = .{
    .pair = "",
    .key_field = "",
    .value_field = "",
    .quoted_key = "",
    .literals = &.{},
    .negation_operator_field = "",
    .negation_operator = "",
    .negation_argument_field = "",
    .negatable = &.{},
    .template = "",
    .substitution = "",
};

pub const profile: Profile = .{
    .name = "python",
    .extensions = &.{ ".py", ".pyi" },
    .grammar = grammar,
    .functions = &function_nodes,
    .bindings = &.{},
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
    .class_body = "block",
    .bodyless_terminator = null,
    .empty_body = "...",
    .expression_statement = "expression_statement",
    .prose_strings = &.{},
    .directives = &.{},
    .literal_values = never_matching_literal_values,
    .memberTraits = memberTraits,
    .visibility_keywords = &.{},
};

fn memberTraits(self: *const Profile, tree: ts.Tree, node: ts.Node, kind: FunctionKind) MemberTraits {
    _ = self;
    _ = tree;
    _ = node;
    _ = kind;
    return .{};
}
