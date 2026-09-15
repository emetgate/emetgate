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
    dotted_name: []const u8,
    name_segments: []const []const u8,
    containers: []const Container,
    declaration_statements: []const []const u8,
    declarator: []const u8,
    export_wrappers: []const []const u8,
    decorator: []const u8,
    comments: []const []const u8,
    memberTraits: *const fn (profile: *const Profile, tree: ts.Tree, node: ts.Node, kind: FunctionKind) MemberTraits,

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

    pub fn containerName(self: *const Profile, node_kind: []const u8) ?NameSource {
        for (self.containers) |entry| {
            if (std.mem.eql(u8, entry.node, node_kind)) return entry.name;
        }
        return null;
    }
};
