const profile_mod = @import("../profile.zig");

const Rename = profile_mod.Rename;
const Modules = profile_mod.Modules;
const BinderSite = profile_mod.BinderSite;
const FieldSite = profile_mod.FieldSite;
const Declarations = profile_mod.Declarations;
const DeclarationShape = profile_mod.DeclarationShape;

const binder_sites = [_]BinderSite{
    .{ .parent = "function_definition", .field = "name" },
    .{ .parent = "class_definition", .field = "name", .namespace = .both },
    .{ .parent = "parameters", .field = null, .scope = .function },
    .{ .parent = "lambda_parameters", .field = null, .scope = .function },
    .{ .parent = "default_parameter", .field = "name", .scope = .function },
    .{ .parent = "typed_parameter", .field = null, .scope = .function },
    .{ .parent = "typed_default_parameter", .field = "name", .scope = .function },
    .{ .parent = "list_splat_pattern", .field = null, .grandparent = "pattern_list", .scope = .pattern },
    .{ .parent = "list_splat_pattern", .field = null, .grandparent = "tuple_pattern", .scope = .pattern },
    .{ .parent = "list_splat_pattern", .field = null, .grandparent = "list_pattern", .scope = .pattern },
    .{ .parent = "list_splat_pattern", .field = null, .scope = .function },
    .{ .parent = "dictionary_splat_pattern", .field = null, .scope = .function },
    .{ .parent = "assignment", .field = "left" },
    .{ .parent = "for_statement", .field = "left" },
    .{ .parent = "for_in_clause", .field = "left" },
    .{ .parent = "pattern_list", .field = null, .scope = .pattern },
    .{ .parent = "tuple_pattern", .field = null, .scope = .pattern },
    .{ .parent = "list_pattern", .field = null, .scope = .pattern },
    .{ .parent = "as_pattern_target", .field = null },
    .{ .parent = "as_pattern", .field = null, .grandparent = "case_pattern" },
    .{ .parent = "named_expression", .field = "name", .scope = .function },
    .{ .parent = "dotted_name", .field = null, .grandparent = "case_pattern", .position = .sole },
    .{ .parent = "dotted_name", .field = null, .grandparent = "keyword_pattern", .position = .sole },
    .{ .parent = "splat_pattern", .field = null },
    .{ .parent = "aliased_import", .field = "alias", .namespace = .both },
    .{ .parent = "dotted_name", .field = null, .parent_field = "name", .grandparent = "import_from_statement", .namespace = .both },
    .{ .parent = "dotted_name", .field = null, .parent_field = "name", .grandparent = "import_statement", .namespace = .both, .position = .first },
};

const inert_sites = [_]BinderSite{
    .{ .parent = "dotted_name", .field = null, .parent_field = "name", .grandparent = "import_statement", .position = .rest },
    .{ .parent = "dotted_name", .field = null, .parent_field = "name", .grandparent = "aliased_import" },
    .{ .parent = "dotted_name", .field = null, .parent_field = "module_name", .grandparent = "import_from_statement" },
    .{ .parent = "dotted_name", .field = null, .grandparent = "relative_import" },
    .{ .parent = "dotted_name", .field = null, .grandparent = "case_pattern", .position = .rest },
    .{ .parent = "dotted_name", .field = null, .grandparent = "class_pattern", .position = .rest },
    .{ .parent = "dotted_name", .field = null, .grandparent = "keyword_pattern", .position = .rest },
    .{ .parent = "keyword_pattern", .field = null, .position = .first },
};

const property_sites = [_]FieldSite{
    .{ .parent = "attribute", .field = "attribute" },
    .{ .parent = "keyword_argument", .field = "name" },
};

const scope_bodies = [_]FieldSite{
    .{ .parent = "function_definition", .field = "body" },
    .{ .parent = "lambda", .field = "body" },
    .{ .parent = "class_definition", .field = "body" },
};

pub const modules: Modules = .{
    .import_statement = "import_statement",
    .export_statement = "",
    .source_field = "",
    .declaration_field = "",
    .import_clause = "",
    .named_imports = "",
    .import_specifier = "",
    .namespace_import = "",
    .export_clause = "",
    .export_specifier = "",
    .name_field = "name",
    .alias_field = "alias",
    .type_keywords = &.{},
    .default_keyword = "default",
    .star_token = "*",
    .from_statement = "import_from_statement",
    .submodule_imports = true,
    .package_init = "__init__.py",
    .exports_bindings = true,
    .module_name_field = "module_name",
    .aliased_import = "aliased_import",
    .wildcard_import = "wildcard_import",
    .dotted_name = "dotted_name",
};

pub const grammar: Rename = .{
    .external_sites = &.{},
    .name_kinds = &.{"identifier"},
    .free_kinds = &.{"identifier"},
    .type_kinds = &.{},
    .property_kinds = &.{},
    .shorthand_kinds = &.{},
    .export_specifiers = &.{},
    .import_statements = &.{ "import_statement", "import_from_statement" },
    .import_binders = &.{ "aliased_import", "dotted_name" },
    .export_scope_stops = &.{},
    .binder_sites = &binder_sites,
    .block_scopes = &.{ "module", "function_definition", "class_definition", "lambda", "list_comprehension", "set_comprehension", "dictionary_comprehension", "generator_expression" },
    .function_scoped_statements = &.{},
    .subscript = "subscript",
    .subscript_index_field = "subscript",
    .literal_index_kinds = &.{ "string", "integer", "float" },
    .constructed_index_kinds = &.{ "binary_operator", "call", "parenthesized_expression", "conditional_expression" },
    .eval_callees = &.{ "eval", "exec" },
    .module_callees = &.{"__import__"},
    .new_expression = "",
    .new_constructor_field = "",
    .constructor_callees = &.{},
    .literal_argument = "string",
    .template_fragment = "",
    .quotes = "\"'",
    .type_string_parents = &.{"type"},
    .property_sites = &property_sites,
    .inert_sites = &inert_sites,
    .class_scopes = &.{"class_definition"},
    .scope_bodies = &scope_bodies,
    .rebinding_statements = &.{ "global_statement", "nonlocal_statement" },
    .name_list = .{
        .owner = "__all__",
        .string = "string",
        .content = "string_content",
        .quote_start = "string_start",
        .containers = &.{ "list", "tuple", "expression_list", "parenthesized_expression", "argument_list" },
        .holders = &.{
            .{ .node = "assignment", .target_field = "left", .value_field = "right" },
            .{ .node = "augmented_assignment", .target_field = "left", .value_field = "right" },
            .{ .node = "call", .target_field = "function", .object_field = "object", .value_field = "arguments" },
        },
        .statement = "expression_statement",
    },
};

const type_declarations = [_]DeclarationShape{
    .{ .node = "class_definition", .kind = .class, .name_field = "name" },
};

const field_declarations = [_]DeclarationShape{
    .{ .node = "assignment", .kind = .field, .name_field = "left" },
};

pub const declarations: Declarations = .{
    .types = &type_declarations,
    .wrappers = &.{"decorated_definition"},
    .variable_statements = &.{"assignment"},
    .value_field = "right",
    .fields = &field_declarations,
    .destructuring = &.{ "pattern_list", "tuple_pattern", "list_pattern", "list_splat_pattern", "attribute", "subscript" },
    .variable_declarator = "assignment",
    .variable_name_field = "left",
};
