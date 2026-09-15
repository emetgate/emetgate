const std = @import("std");
const ts = @import("../tree_sitter.zig");

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

pub const Profile = struct {
    name: []const u8,
    extensions: []const []const u8,
    grammar: *const fn () *const ts.Language,
    functions: []const FunctionNode,
    bindings: []const Binding,
    transparent_wrappers: []const []const u8,

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
};
