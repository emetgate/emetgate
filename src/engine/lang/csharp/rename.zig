const profile_mod = @import("../profile.zig");

const Rename = profile_mod.Rename;
const BinderSite = profile_mod.BinderSite;
const Declarations = profile_mod.Declarations;
const DeclarationShape = profile_mod.DeclarationShape;

const binder_sites = [_]BinderSite{
    .{ .parent = "class_declaration", .field = "name", .namespace = .both, .scope = .program },
    .{ .parent = "struct_declaration", .field = "name", .namespace = .both, .scope = .program },
    .{ .parent = "record_declaration", .field = "name", .namespace = .both, .scope = .program },
    .{ .parent = "record_struct_declaration", .field = "name", .namespace = .both, .scope = .program },
    .{ .parent = "interface_declaration", .field = "name", .namespace = .both, .scope = .program },
    .{ .parent = "enum_declaration", .field = "name", .namespace = .both, .scope = .program },
    .{ .parent = "delegate_declaration", .field = "name", .namespace = .both, .scope = .program },
    .{ .parent = "method_declaration", .field = "name", .scope = .block },
    .{ .parent = "local_function_statement", .field = "name", .scope = .block },
    .{ .parent = "parameter", .field = "name", .scope = .function },
    .{ .parent = "variable_declarator", .field = "name", .scope = .declarator },
    .{ .parent = "declaration_expression", .field = "name", .scope = .block },
    .{ .parent = "foreach_statement", .field = "left", .scope = .own },
    .{ .parent = "catch_declaration", .field = "name", .scope = .own },
    .{ .parent = "type_parameter", .field = "name", .namespace = .type, .scope = .owner },
};

pub const modules: profile_mod.Modules = .{
    .import_statement = "__csharp_no_import__",
    .export_statement = "__csharp_no_export__",
    .source_field = "__csharp_no_source__",
    .declaration_field = "declaration",
    .import_clause = "__csharp_no_clause__",
    .named_imports = "__csharp_no_named__",
    .import_specifier = "__csharp_no_specifier__",
    .namespace_import = "__csharp_no_ns__",
    .export_clause = "__csharp_no_export_clause__",
    .export_specifier = "__csharp_no_export_specifier__",
    .name_field = "name",
    .alias_field = "alias",
    .type_keywords = &.{},
    .default_keyword = "__csharp_no_default__",
    .star_token = "*",
};

pub const grammar: Rename = .{
    .external_sites = &.{
        .{ .parent = "member_access_expression", .field = "name" },
        .{ .parent = "qualified_name", .field = "name" },
    },
    .name_kinds = &.{"identifier"},
    .free_kinds = &.{"identifier"},
    .type_kinds = &.{},
    .property_kinds = &.{},
    .shorthand_kinds = &.{},
    .export_specifiers = &.{},
    .import_statements = &.{},
    .import_binders = &.{},
    .export_scope_stops = &.{},
    .binder_sites = &binder_sites,
    .block_scopes = &.{ "compilation_unit", "declaration_list", "block", "switch_body" },
    .function_scoped_statements = &.{},
    .subscript = "__csharp_no_subscript__",
    .subscript_index_field = "__csharp_no_index__",
    .literal_index_kinds = &.{},
    .constructed_index_kinds = &.{},
    .eval_callees = &.{},
    .module_callees = &.{},
    .new_expression = "object_creation_expression",
    .new_constructor_field = "type",
    .constructor_callees = &.{},
    .literal_argument = "__csharp_no_literal_arg__",
    .template_fragment = "__csharp_no_fragment__",
    .quotes = "\"",
};

const type_declarations = [_]DeclarationShape{
    .{ .node = "class_declaration", .kind = .class, .name_field = "name" },
    .{ .node = "struct_declaration", .kind = .class, .name_field = "name" },
    .{ .node = "record_declaration", .kind = .class, .name_field = "name" },
    .{ .node = "record_struct_declaration", .kind = .class, .name_field = "name" },
    .{ .node = "interface_declaration", .kind = .interface, .name_field = "name" },
    .{ .node = "enum_declaration", .kind = .enumeration, .name_field = "name" },
};

const declaration_containers = [_][]const u8{
    "namespace_declaration",
    "file_scoped_namespace_declaration",
    "declaration_list",
    "class_declaration",
    "struct_declaration",
    "record_declaration",
    "record_struct_declaration",
    "interface_declaration",
};

pub fn declarations() Declarations {
    return .{
        .types = &type_declarations,
        .variable_statements = &.{},
        .value_field = "value",
        .fields = &.{},
        .enum_body = "enum_member_declaration_list",
        .enum_members = &.{.{ .node = "enum_member_declaration", .kind = .enum_member, .name_field = "name" }},
        .enum_bare_member = null,
        .destructuring = &.{},
        .static_keyword = "static",
        .containers = &declaration_containers,
    };
}
