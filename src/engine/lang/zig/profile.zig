const ts = @import("../../tree_sitter.zig");
const profile_mod = @import("../profile.zig");

const Profile = profile_mod.Profile;
const FunctionKind = profile_mod.FunctionKind;
const FunctionNode = profile_mod.FunctionNode;
const MemberTraits = profile_mod.MemberTraits;
const Call = profile_mod.Call;
const LiteralValues = profile_mod.LiteralValues;

extern fn tree_sitter_zig() callconv(.c) ?*const ts.Language;

fn grammar() *const ts.Language {
    return tree_sitter_zig().?;
}

const function_nodes = [_]FunctionNode{
    .{ .node = "function_declaration", .kind = .declaration },
    .{ .node = "test_declaration", .kind = .expression },
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
    .name = "zig",
    .extensions = &.{".zig"},
    .grammar = grammar,
    .functions = &function_nodes,
    .bindings = &.{},
    .transparent_wrappers = &.{},
    .addressable_names = &.{"identifier"},
    .dotted_name = null,
    .name_segments = &.{"identifier"},
    .containers = &.{},
    .declaration_statements = &.{},
    .declarator = "",
    .export_wrappers = &.{},
    .decorator = "",
    .comments = &.{"comment"},
    .block = "block",
    .root = "source_file",
    .identifier = "identifier",
    .reference_names = &.{"identifier"},
    .call = .{ .node = "call_expression", .function_field = "function", .arguments_field = "arguments", .arguments = "arguments", .optional_marker = null },
    .reexport_specifier = null,
    .namespace_exports = &.{},
    .star_token = null,
    .dynamic_callees = &.{},
    .dynamic_constructors = &.{},
    .strings = &.{"string"},
    .class_body = "",
    .bodyless_terminator = ";",
    .empty_body = "{}",
    .expression_statement = "",
    .prose_strings = &.{ "string", "multiline_string" },
    .directives = &.{},
    .literal_values = never_matching_literal_values,
    .memberTraits = memberTraits,
    .visibility_keyword = "pub",
};

fn memberTraits(self: *const Profile, tree: ts.Tree, node: ts.Node, kind: FunctionKind) MemberTraits {
    _ = self;
    _ = tree;
    _ = node;
    _ = kind;
    return .{};
}
