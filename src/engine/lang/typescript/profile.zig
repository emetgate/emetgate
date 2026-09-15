const ts = @import("../../tree_sitter.zig");
const Profile = @import("../profile.zig").Profile;

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
};
