const profile_mod = @import("../profile.zig");

const Facts = profile_mod.Facts;
const FieldSite = profile_mod.FieldSite;
const TypedBinder = profile_mod.TypedBinder;

const writes = [_]FieldSite{
    .{ .parent = "assignment_expression", .field = "left" },
};

const branch_statements = [_][]const u8{
    "if_statement",
    "else_clause",
    "switch_statement",
    "switch_section",
    "case_switch_label",
    "return_statement",
    "break_statement",
    "continue_statement",
    "throw_statement",
    "throw_expression",
    "catch_clause",
    "conditional_expression",
    "while_statement",
    "for_statement",
    "foreach_statement",
};

const doc_directives = [_][]const u8{ "#region", "#endregion", "#pragma", "#nullable" };

const typed_binders = [_]TypedBinder{
    .{ .node = "parameter", .name_field = "name", .type_field = "type" },
};

pub const csharp: Facts = .{
    .branch_statements = &branch_statements,
    .test_calls = &.{},
    .test_file_infixes = &.{ ".Tests.", ".Test." },
    .test_dirs = &.{},
    .doc_directives = &doc_directives,
    .member = "member_access_expression",
    .object_field = "expression",
    .property_field = "name",
    .qualified_type = null,
    .qualified_module_field = "qualifier",
    .qualified_name_field = "name",
    .generic_type = null,
    .generic_name_field = "name",
    .type_annotation = null,
    .this_keyword = "this",
    .super_keyword = "base",
    .classes = &.{ "class_declaration", "struct_declaration", "record_declaration" },
    .class_fields = &.{"property_declaration"},
    .heritage = "base_list",
    .extends_clause = null,
    .extends_value_field = "value",
    .typed_binders = &typed_binders,
    .parameter_properties = &.{},
    .property_markers = &.{},
    .writes = &writes,
    .call_like = &.{},
    .error_node = "ERROR",
    .export_value_field = "value",
    .export_declaration_field = "declaration",
    .global_types = true,
    .namespaces = &.{"namespace_declaration"},
    .using_directive = "using_directive",
    .constructions = &.{.{ .node = "variable_declarator", .name_field = "name", .parent_type_field = "type" }},
};
