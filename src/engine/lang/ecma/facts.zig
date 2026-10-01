const profile_mod = @import("../profile.zig");

const Facts = profile_mod.Facts;
const FieldSite = profile_mod.FieldSite;
const TypedBinder = profile_mod.TypedBinder;

const writes = [_]FieldSite{
    .{ .parent = "assignment_expression", .field = "left" },
    .{ .parent = "augmented_assignment_expression", .field = "left" },
    .{ .parent = "update_expression", .field = "argument" },
};

const call_like = [_]FieldSite{
    .{ .parent = "jsx_opening_element", .field = "name" },
    .{ .parent = "jsx_self_closing_element", .field = "name" },
};

const branch_statements = [_][]const u8{ "if_statement", "else_clause", "switch_statement", "switch_case", "switch_default", "return_statement", "break_statement", "continue_statement", "throw_statement", "catch_clause", "ternary_expression" };

const typed_binders = [_]TypedBinder{
    .{ .node = "variable_declarator", .name_field = "name", .type_field = "type" },
    .{ .node = "required_parameter", .name_field = "pattern", .type_field = "type" },
    .{ .node = "optional_parameter", .name_field = "pattern", .type_field = "type" },
};

pub const typescript: Facts = .{
    .branch_statements = &branch_statements,
    .member = "member_expression",
    .object_field = "object",
    .property_field = "property",
    .qualified_type = "nested_type_identifier",
    .qualified_module_field = "module",
    .qualified_name_field = "name",
    .generic_type = "generic_type",
    .generic_name_field = "name",
    .type_annotation = "type_annotation",
    .this_keyword = "this",
    .super_keyword = "super",
    .classes = &.{ "class_declaration", "class", "abstract_class_declaration" },
    .class_fields = &.{"public_field_definition"},
    .heritage = "class_heritage",
    .extends_clause = "extends_clause",
    .extends_value_field = "value",
    .typed_binders = &typed_binders,
    .parameter_properties = &.{ "required_parameter", "optional_parameter" },
    .property_markers = &.{ "accessibility_modifier", "readonly" },
    .writes = &writes,
    .call_like = &call_like,
    .error_node = "ERROR",
    .export_value_field = "value",
    .export_declaration_field = "declaration",
};

pub const javascript: Facts = .{
    .branch_statements = &branch_statements,
    .member = "member_expression",
    .object_field = "object",
    .property_field = "property",
    .qualified_type = null,
    .qualified_module_field = "module",
    .qualified_name_field = "name",
    .generic_type = null,
    .generic_name_field = "name",
    .type_annotation = null,
    .this_keyword = "this",
    .super_keyword = "super",
    .classes = &.{ "class_declaration", "class" },
    .class_fields = &.{"field_definition"},
    .heritage = "class_heritage",
    .extends_clause = null,
    .extends_value_field = "value",
    .typed_binders = &.{},
    .parameter_properties = &.{},
    .property_markers = &.{},
    .writes = &writes,
    .call_like = &call_like,
    .error_node = "ERROR",
    .export_value_field = "value",
    .export_declaration_field = "declaration",
};
