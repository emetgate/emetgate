const profile_mod = @import("../profile.zig");
const map = @import("map.zig");

const Facts = profile_mod.Facts;
const FieldSite = profile_mod.FieldSite;
const TypedBinder = profile_mod.TypedBinder;
const TestDefinition = profile_mod.TestDefinition;
const Initializer = profile_mod.Initializer;

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

const initializers = [_]Initializer{
    .{ .entry = "assignment_expression", .name_field = "left", .list = "initializer_expression", .owner = "object_creation_expression", .owner_list_field = "initializer", .object_is_owner = true },
    .{ .entry = "with_initializer", .owner = "with_expression", .object_is_owner = false },
};

const test_definitions = [_]TestDefinition{
    .{ .node = "class_declaration", .attribute = map.isTestAttribute },
    .{ .node = "method_declaration", .attribute = map.isTestAttribute },
};

pub const csharp: Facts = .{
    .branch_statements = &branch_statements,
    .test_calls = &.{},
    .test_definitions = &test_definitions,
    .public_modifier = "public",
    .hidden_modifiers = &.{ "private", "protected", "internal" },
    .test_file_infixes = &.{ ".Tests.", ".Test." },
    .test_dirs = map.table.test_segments,
    .test_name = map.isTestName,
    .test_segment = map.isTestSegment,
    .doc_directives = &doc_directives,
    .xml_docs = true,
    .member = "member_access_expression",
    .object_field = "expression",
    .property_field = "name",
    .qualified_type = "qualified_name",
    .qualified_module_field = "qualifier",
    .qualified_name_field = "name",
    .generic_type = "generic_name",
    .generic_name_field = "",
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
    .initializers = &initializers,
    .calls_construct = true,
    .inherited_overloads = true,
    .type_parameter_list = "type_parameter_list",
    .nullable_type = "nullable_type",
    .return_sites = &.{
        .{ .parent = "method_declaration", .field = "returns" },
        .{ .parent = "local_function_statement", .field = "type" },
    },
};
