const profile_mod = @import("../profile.zig");

const Rename = profile_mod.Rename;
const BinderSite = profile_mod.BinderSite;
const Declarations = profile_mod.Declarations;
const DeclarationShape = profile_mod.DeclarationShape;

const binder_sites = [_]BinderSite{
    .{ .parent = "variable_declarator", .field = "name", .scope = .declarator },
    .{ .parent = "function_declaration", .field = "name" },
    .{ .parent = "function_expression", .field = "name", .scope = .own },
    .{ .parent = "generator_function_declaration", .field = "name" },
    .{ .parent = "generator_function", .field = "name", .scope = .own },
    .{ .parent = "function_signature", .field = "name" },
    .{ .parent = "class_declaration", .field = "name", .namespace = .both },
    .{ .parent = "abstract_class_declaration", .field = "name", .namespace = .both },
    .{ .parent = "class", .field = "name", .namespace = .both, .scope = .own },
    .{ .parent = "type_alias_declaration", .field = "name", .namespace = .type },
    .{ .parent = "interface_declaration", .field = "name", .namespace = .type },
    .{ .parent = "enum_declaration", .field = "name", .namespace = .both },
    .{ .parent = "internal_module", .field = "name", .namespace = .both },
    .{ .parent = "type_parameter", .field = "name", .namespace = .type, .scope = .owner },
    .{ .parent = "required_parameter", .field = "pattern", .scope = .function },
    .{ .parent = "optional_parameter", .field = "pattern", .scope = .function },
    .{ .parent = "arrow_function", .field = "parameter", .scope = .own },
    .{ .parent = "catch_clause", .field = "parameter", .scope = .own },
    .{ .parent = "for_in_statement", .field = "left", .scope = .own },
    .{ .parent = "assignment_pattern", .field = "left", .scope = .pattern },
    .{ .parent = "pair_pattern", .field = "value", .scope = .pattern },
    .{ .parent = "import_specifier", .field = "alias", .namespace = .both, .scope = .program },
    .{ .parent = "import_specifier", .field = "name", .unless = "alias", .namespace = .both, .scope = .program },
    .{ .parent = "formal_parameters", .field = null, .scope = .function },
    .{ .parent = "array_pattern", .field = null, .scope = .pattern },
    .{ .parent = "rest_pattern", .field = null, .scope = .pattern },
    .{ .parent = "import_clause", .field = null, .namespace = .both, .scope = .program },
    .{ .parent = "namespace_import", .field = null, .namespace = .both, .scope = .program },
};

pub const grammar: Rename = .{
    .external_sites = &.{
        .{ .parent = "import_specifier", .field = "name", .when = "alias" },
        .{ .parent = "export_specifier", .field = "alias" },
        .{ .parent = "export_specifier", .field = "name", .statement_field = "source" },
    },
    .name_kinds = &.{
        "identifier",
        "property_identifier",
        "type_identifier",
        "shorthand_property_identifier",
        "shorthand_property_identifier_pattern",
        "private_property_identifier",
        "statement_identifier",
    },
    .free_kinds = &.{ "identifier", "type_identifier", "shorthand_property_identifier" },
    .type_kinds = &.{"type_identifier"},
    .property_kinds = &.{ "property_identifier", "private_property_identifier" },
    .shorthand_kinds = &.{ "shorthand_property_identifier", "shorthand_property_identifier_pattern" },
    .export_specifiers = &.{"export_specifier"},
    .import_statements = &.{"import_statement"},
    .import_binders = &.{ "import_specifier", "import_clause", "namespace_import" },
    .export_scope_stops = &.{ "statement_block", "class_body", "formal_parameters", "arrow_function", "function_expression", "object", "array", "arguments", "type_parameters", "object_pattern", "array_pattern" },
    .binder_sites = &binder_sites,
    .block_scopes = &.{ "program", "statement_block", "switch_body", "for_statement", "for_in_statement" },
    .function_scoped_statements = &.{"variable_declaration"},
    .subscript = "subscript_expression",
    .subscript_index_field = "index",
    .literal_index_kinds = &.{ "string", "number" },
    .constructed_index_kinds = &.{ "binary_expression", "template_string", "call_expression", "parenthesized_expression", "ternary_expression" },
    .eval_callees = &.{"eval"},
    .module_callees = &.{ "require", "import" },
    .new_expression = "new_expression",
    .new_constructor_field = "constructor",
    .constructor_callees = &.{"Function"},
    .literal_argument = "string",
    .template_fragment = "string_fragment",
    .quotes = "\"'`",
};

const type_declarations = [_]DeclarationShape{
    .{ .node = "class_declaration", .kind = .class, .name_field = "name" },
    .{ .node = "abstract_class_declaration", .kind = .class, .name_field = "name" },
    .{ .node = "interface_declaration", .kind = .interface, .name_field = "name" },
    .{ .node = "type_alias_declaration", .kind = .type_alias, .name_field = "name" },
    .{ .node = "enum_declaration", .kind = .enumeration, .name_field = "name" },
};

pub fn declarations(field: DeclarationShape) Declarations {
    return .{
        .types = &type_declarations,
        .variable_statements = &.{ "lexical_declaration", "variable_declaration" },
        .value_field = "value",
        .fields = &.{field},
        .enum_body = "enum_body",
        .enum_members = &.{.{ .node = "enum_assignment", .kind = .enum_member, .name_field = "name" }},
        .enum_bare_member = "property_identifier",
        .destructuring = &.{ "object_pattern", "array_pattern" },
        .static_keyword = "static",
    };
}
