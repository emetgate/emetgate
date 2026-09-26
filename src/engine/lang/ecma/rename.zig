pub const languages = [_][]const u8{ "typescript", "tsx", "javascript" };

pub const name_kinds = [_][]const u8{
    "identifier",
    "property_identifier",
    "type_identifier",
    "shorthand_property_identifier",
    "shorthand_property_identifier_pattern",
    "private_property_identifier",
    "statement_identifier",
};

pub const free_kinds = [_][]const u8{ "identifier", "type_identifier", "shorthand_property_identifier" };

pub const shorthand_kinds = [_][]const u8{ "shorthand_property_identifier", "shorthand_property_identifier_pattern" };

pub const export_specifiers = [_][]const u8{"export_specifier"};

pub const import_statements = [_][]const u8{"import_statement"};

pub const scope_kinds = [_][]const u8{ "statement_block", "class_body", "formal_parameters", "arrow_function", "function_expression", "object", "array", "arguments", "type_parameters", "object_pattern", "array_pattern" };

pub const BinderSite = struct {
    parent: []const u8,
    field: ?[]const u8,
    unless: ?[]const u8 = null,
};

pub const binder_sites = [_]BinderSite{
    .{ .parent = "variable_declarator", .field = "name" },
    .{ .parent = "function_declaration", .field = "name" },
    .{ .parent = "function_expression", .field = "name" },
    .{ .parent = "generator_function_declaration", .field = "name" },
    .{ .parent = "generator_function", .field = "name" },
    .{ .parent = "function_signature", .field = "name" },
    .{ .parent = "class_declaration", .field = "name" },
    .{ .parent = "abstract_class_declaration", .field = "name" },
    .{ .parent = "class", .field = "name" },
    .{ .parent = "type_alias_declaration", .field = "name" },
    .{ .parent = "interface_declaration", .field = "name" },
    .{ .parent = "enum_declaration", .field = "name" },
    .{ .parent = "internal_module", .field = "name" },
    .{ .parent = "type_parameter", .field = "name" },
    .{ .parent = "required_parameter", .field = "pattern" },
    .{ .parent = "optional_parameter", .field = "pattern" },
    .{ .parent = "arrow_function", .field = "parameter" },
    .{ .parent = "catch_clause", .field = "parameter" },
    .{ .parent = "for_in_statement", .field = "left" },
    .{ .parent = "assignment_pattern", .field = "left" },
    .{ .parent = "pair_pattern", .field = "value" },
    .{ .parent = "import_specifier", .field = "alias" },
    .{ .parent = "import_specifier", .field = "name", .unless = "alias" },
    .{ .parent = "formal_parameters", .field = null },
    .{ .parent = "array_pattern", .field = null },
    .{ .parent = "rest_pattern", .field = null },
    .{ .parent = "import_clause", .field = null },
    .{ .parent = "namespace_import", .field = null },
};

pub const subscript = "subscript_expression";
pub const subscript_index_field = "index";
pub const literal_index_kinds = [_][]const u8{ "string", "number" };
pub const constructed_index_kinds = [_][]const u8{ "binary_expression", "template_string", "call_expression", "parenthesized_expression", "ternary_expression" };

pub const eval_callees = [_][]const u8{"eval"};
pub const module_callees = [_][]const u8{ "require", "import" };
pub const constructor_callees = [_][]const u8{"Function"};
pub const new_expression = "new_expression";
pub const new_constructor_field = "constructor";
pub const literal_argument = "string";
pub const template_fragment = "string_fragment";
pub const quotes = [_]u8{ '"', '\'', '`' };
