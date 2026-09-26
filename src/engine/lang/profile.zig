const std = @import("std");
const ts = @import("../tree_sitter.zig");
const Accessor = @import("../ref.zig").Accessor;

pub const FunctionKind = enum {
    declaration,
    generator_declaration,
    expression,
    generator_expression,
    arrow,
    method,
    static_block,
};

pub const FunctionNode = struct {
    node: []const u8,
    kind: FunctionKind,
};

pub const Binding = struct {
    parent: []const u8,
    value_field: []const u8,
    name_field: []const u8,
};

pub const NameSource = enum { field, field_or_binding, binding };

pub const Container = struct {
    node: []const u8,
    name: NameSource,
};

pub const Call = struct {
    node: []const u8,
    function_field: []const u8,
    arguments_field: []const u8,
    arguments: []const u8,
    optional_marker: ?[]const u8 = null,
};

pub const DynamicConstructor = struct {
    node: []const u8,
    field: []const u8,
    names: []const []const u8,
};

pub const LiteralValues = struct {
    pair: []const u8,
    key_field: []const u8,
    value_field: []const u8,
    quoted_key: []const u8,
    literals: []const []const u8,
    negation_operator_field: []const u8,
    negation_operator: []const u8,
    negation_argument_field: []const u8,
    negatable: []const []const u8,
    template: []const u8,
    substitution: []const u8,
};

pub const Namespace = enum {
    value,
    type,
    both,

    pub fn overlaps(self: Namespace, other: Namespace) bool {
        return self == .both or other == .both or self == other;
    }
};

pub const ScopeRule = enum { block, function, own, owner, pattern, declarator, program };

pub const BinderSite = struct {
    parent: []const u8,
    field: ?[]const u8,
    unless: ?[]const u8 = null,
    namespace: Namespace = .value,
    scope: ScopeRule = .block,
};

pub const ExternalSite = struct {
    parent: []const u8,
    field: []const u8,
    when: ?[]const u8 = null,
    statement_field: ?[]const u8 = null,
};

pub const Rename = struct {
    external_sites: []const ExternalSite,
    name_kinds: []const []const u8,
    free_kinds: []const []const u8,
    type_kinds: []const []const u8,
    property_kinds: []const []const u8,
    shorthand_kinds: []const []const u8,
    export_specifiers: []const []const u8,
    import_statements: []const []const u8,
    import_binders: []const []const u8,
    export_scope_stops: []const []const u8,
    binder_sites: []const BinderSite,
    block_scopes: []const []const u8,
    function_scoped_statements: []const []const u8,
    subscript: []const u8,
    subscript_index_field: []const u8,
    literal_index_kinds: []const []const u8,
    constructed_index_kinds: []const []const u8,
    eval_callees: []const []const u8,
    module_callees: []const []const u8,
    new_expression: []const u8,
    new_constructor_field: []const u8,
    constructor_callees: []const []const u8,
    literal_argument: []const u8,
    template_fragment: []const u8,
    quotes: []const u8,
};

pub const Modules = struct {
    import_statement: []const u8,
    export_statement: []const u8,
    source_field: []const u8,
    declaration_field: []const u8,
    import_clause: []const u8,
    named_imports: []const u8,
    import_specifier: []const u8,
    namespace_import: []const u8,
    export_clause: []const u8,
    export_specifier: []const u8,
    name_field: []const u8,
    alias_field: []const u8,
    type_keywords: []const []const u8,
    default_keyword: []const u8,
    star_token: []const u8,
};

pub const DeclarationKind = enum { class, variable, interface, type_alias, enumeration, field, enum_member };

pub const DeclarationShape = struct {
    node: []const u8,
    kind: DeclarationKind,
    name_field: []const u8,
};

pub const Declarations = struct {
    types: []const DeclarationShape = &.{},
    variable_statements: []const []const u8 = &.{},
    value_field: []const u8 = "value",
    fields: []const DeclarationShape = &.{},
    enum_body: ?[]const u8 = null,
    enum_members: []const DeclarationShape = &.{},
    enum_bare_member: ?[]const u8 = null,
    destructuring: []const []const u8 = &.{},
    static_keyword: ?[]const u8 = null,
};

pub const MemberTraits = struct {
    accessor: Accessor = .none,
    is_static: bool = false,
    is_constructor: bool = false,
};

pub const Profile = struct {
    name: []const u8,
    extensions: []const []const u8,
    grammar: *const fn () *const ts.Language,
    functions: []const FunctionNode,
    bindings: []const Binding,
    transparent_wrappers: []const []const u8,
    addressable_names: []const []const u8,
    dotted_name: ?[]const u8,
    name_segments: []const []const u8,
    containers: []const Container,
    declaration_statements: []const []const u8,
    declarator: []const u8,
    export_wrappers: []const []const u8,
    decorator: []const u8,
    comments: []const []const u8,
    block: []const u8,
    root: []const u8,
    identifier: []const u8,
    reference_names: []const []const u8,
    call: Call,
    reexport_specifier: ?[]const u8,
    namespace_exports: []const []const u8,
    star_token: ?[]const u8,
    dynamic_callees: []const []const u8,
    dynamic_constructors: []const DynamicConstructor,
    strings: []const []const u8,
    class_body: []const u8,
    bodyless_terminator: ?[]const u8,
    empty_body: []const u8,
    expression_statement: []const u8,
    prose_strings: []const []const u8,
    directives: []const []const u8,
    literal_values: LiteralValues,
    memberTraits: *const fn (profile: *const Profile, tree: ts.Tree, node: ts.Node, kind: FunctionKind) MemberTraits,
    visibility_keywords: []const []const u8 = &.{},
    rename: ?*const Rename = null,
    modules: ?*const Modules = null,
    declarations: Declarations = .{},

    pub fn hasVisibilityKeyword(self: *const Profile, node: ts.Node) bool {
        if (self.visibility_keywords.len == 0) return false;
        var i: u32 = 0;
        while (node.child(i)) |child| : (i += 1) {
            if (child.isNamed()) continue;
            for (self.visibility_keywords) |keyword| {
                if (std.mem.eql(u8, keyword, child.kind())) return true;
            }
        }
        return false;
    }

    pub fn handles(self: *const Profile, path: []const u8) bool {
        for (self.extensions) |extension| {
            if (std.ascii.endsWithIgnoreCase(path, extension)) return true;
        }
        return false;
    }

    pub fn functionKind(self: *const Profile, node_kind: []const u8) ?FunctionKind {
        for (self.functions) |entry| {
            if (std.mem.eql(u8, entry.node, node_kind)) return entry.kind;
        }
        return null;
    }

    pub fn isDottedName(self: *const Profile, node_kind: []const u8) bool {
        const dotted = self.dotted_name orelse return false;
        return std.mem.eql(u8, dotted, node_kind);
    }

    pub fn isComment(self: *const Profile, node_kind: []const u8) bool {
        for (self.comments) |kind| {
            if (std.mem.eql(u8, kind, node_kind)) return true;
        }
        return false;
    }

    pub fn containerName(self: *const Profile, node_kind: []const u8) ?NameSource {
        for (self.containers) |entry| {
            if (std.mem.eql(u8, entry.node, node_kind)) return entry.name;
        }
        return null;
    }
};
