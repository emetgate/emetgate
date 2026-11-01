const profile_mod = @import("../profile.zig");

const Facts = profile_mod.Facts;
const FieldSite = profile_mod.FieldSite;
const TestDefinition = profile_mod.TestDefinition;
const TypedBinder = profile_mod.TypedBinder;

const writes = [_]FieldSite{
    .{ .parent = "assignment", .field = "left" },
    .{ .parent = "augmented_assignment", .field = "left" },
};

const branch_statements = [_][]const u8{
    "if_statement",   "elif_clause",     "else_clause",     "for_statement",
    "while_statement", "with_statement", "try_statement",   "except_clause",
    "except_group_clause", "finally_clause", "case_clause", "match_statement",
    "return_statement", "break_statement", "continue_statement", "raise_statement",
    "conditional_expression", "assert_statement",
};

const test_definitions = [_]TestDefinition{
    .{ .node = "class_definition", .prefix = "Test" },
    .{ .node = "function_definition", .prefix = "test" },
};
const test_file_infixes = [_][]const u8{ "test_", "_test" };
const test_dirs = [_][]const u8{ "tests", "test" };
const doc_directives = [_][]const u8{ "type:", "noqa", "pragma:", "pylint:", "mypy:", "pyright:", "fmt:" };

const typed_binders = [_]TypedBinder{
    .{ .node = "typed_parameter", .name_field = "", .type_field = "type" },
    .{ .node = "typed_default_parameter", .name_field = "name", .type_field = "type" },
    .{ .node = "assignment", .name_field = "left", .type_field = "type" },
};

pub const python: Facts = .{
    .branch_statements = &branch_statements,
    .test_definitions = &test_definitions,
    .test_files = &.{"conftest.py"},
    .test_file_infixes = &test_file_infixes,
    .test_dirs = &test_dirs,
    .doc_directives = &doc_directives,
    .docstrings = true,
    .member = "attribute",
    .object_field = "object",
    .property_field = "attribute",
    .qualified_type = null,
    .qualified_module_field = "object",
    .qualified_name_field = "attribute",
    .generic_type = null,
    .generic_name_field = "name",
    .type_annotation = "type",
    .this_keyword = "",
    .super_keyword = "",
    .classes = &.{"class_definition"},
    .class_fields = &.{},
    .heritage = "argument_list",
    .extends_clause = null,
    .extends_value_field = "value",
    .typed_binders = &typed_binders,
    .parameter_properties = &.{},
    .property_markers = &.{},
    .writes = &writes,
    .call_like = &.{},
    .error_node = "ERROR",
    .export_value_field = "",
    .export_declaration_field = "",
    .receiver_parameter = "parameters",
    .member_wrappers = &.{"decorated_definition"},
    .constructions = &.{.{ .node = "assignment", .name_field = "left", .value_field = "right" }},
    .calls_construct = true,
    .sole_binder_types = true,
};
