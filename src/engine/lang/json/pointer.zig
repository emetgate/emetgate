const std = @import("std");
const ts = @import("../../tree_sitter.zig");
const symbol = @import("../../symbol.zig");

const Allocator = std.mem.Allocator;

extern fn tree_sitter_json() callconv(.c) ?*const ts.Language;

pub fn grammar() *const ts.Language {
    return tree_sitter_json().?;
}

pub const ValueType = enum { object, array, string, number, true_, false_, null_ };

pub const Entry = struct {
    pointer: []const u8,
    ty: ValueType,
    hash: symbol.Hash,
    node: ts.Node,
};

pub const Error = error{ InvalidJson, PointerNotFound } || Allocator.Error;

fn valueTypeOf(node: ts.Node) ?ValueType {
    const kind = node.kind();
    if (std.mem.eql(u8, kind, "object")) return .object;
    if (std.mem.eql(u8, kind, "array")) return .array;
    if (std.mem.eql(u8, kind, "string")) return .string;
    if (std.mem.eql(u8, kind, "number")) return .number;
    if (std.mem.eql(u8, kind, "true")) return .true_;
    if (std.mem.eql(u8, kind, "false")) return .false_;
    if (std.mem.eql(u8, kind, "null")) return .null_;
    return null;
}

fn rootValue(tree: ts.Tree) Error!ts.Node {
    var node = tree.root();
    if (std.mem.eql(u8, node.kind(), "document")) {
        node = node.namedChild(0) orelse return error.InvalidJson;
    }
    return node;
}

fn escapeSegment(gpa: Allocator, segment: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (segment) |c| {
        if (c == '~') {
            try out.appendSlice(gpa, "~0");
        } else if (c == '/') {
            try out.appendSlice(gpa, "~1");
        } else {
            try out.append(gpa, c);
        }
    }
    return out.toOwnedSlice(gpa);
}

fn stringContent(tree: ts.Tree, string_node: ts.Node) []const u8 {
    var i: u32 = 0;
    while (string_node.namedChild(i)) |child| : (i += 1) {
        if (std.mem.eql(u8, child.kind(), "string_content")) return tree.text(child);
    }
    return "";
}

fn hashOfNode(tree: ts.Tree, node: ts.Node) symbol.Hash {
    return symbol.hashOf(tree.text(node));
}

pub fn keyTree(gpa: Allocator, tree: ts.Tree) Error![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    errdefer out.deinit(gpa);
    const root_value = try rootValue(tree);
    try walk(gpa, tree, root_value, "", &out);
    return out.toOwnedSlice(gpa);
}

fn walk(gpa: Allocator, tree: ts.Tree, node: ts.Node, prefix: []const u8, out: *std.ArrayList(Entry)) Error!void {
    const ty = valueTypeOf(node) orelse return error.InvalidJson;
    if (prefix.len != 0) {
        try out.append(gpa, .{ .pointer = try gpa.dupe(u8, prefix), .ty = ty, .hash = hashOfNode(tree, node), .node = node });
    }
    switch (ty) {
        .object => {
            var i: u32 = 0;
            while (node.namedChild(i)) |pair| : (i += 1) {
                if (!std.mem.eql(u8, pair.kind(), "pair")) continue;
                const key_node = pair.childByField("key") orelse continue;
                const value_node = pair.childByField("value") orelse continue;
                const raw_key = stringContent(tree, key_node);
                const escaped = try escapeSegment(gpa, raw_key);
                defer gpa.free(escaped);
                const child_pointer = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ prefix, escaped });
                defer gpa.free(child_pointer);
                try walk(gpa, tree, value_node, child_pointer, out);
            }
        },
        .array => {
            var i: u32 = 0;
            var index: usize = 0;
            while (node.namedChild(i)) |child| : (i += 1) {
                const child_pointer = try std.fmt.allocPrint(gpa, "{s}/{d}", .{ prefix, index });
                defer gpa.free(child_pointer);
                try walk(gpa, tree, child, child_pointer, out);
                index += 1;
            }
        },
        else => {},
    }
}

pub fn freeKeyTree(gpa: Allocator, entries: []Entry) void {
    for (entries) |entry| gpa.free(entry.pointer);
    gpa.free(entries);
}

pub const TopEntry = struct {
    pointer: []const u8,
    ty: ValueType,
    hash: symbol.Hash,
    child_count: ?usize,
};

fn directChildCount(node: ts.Node) ?usize {
    const ty = valueTypeOf(node) orelse return null;
    switch (ty) {
        .object => {
            var count: usize = 0;
            var i: u32 = 0;
            while (node.namedChild(i)) |pair| : (i += 1) {
                if (std.mem.eql(u8, pair.kind(), "pair")) count += 1;
            }
            return count;
        },
        .array => {
            var count: usize = 0;
            var i: u32 = 0;
            while (node.namedChild(i)) |_| : (i += 1) count += 1;
            return count;
        },
        else => return null,
    }
}

pub fn topLevel(gpa: Allocator, tree: ts.Tree) Error![]TopEntry {
    var out: std.ArrayList(TopEntry) = .empty;
    errdefer out.deinit(gpa);
    const root_value = try rootValue(tree);
    const ty = valueTypeOf(root_value) orelse return error.InvalidJson;
    switch (ty) {
        .object => {
            var i: u32 = 0;
            while (root_value.namedChild(i)) |pair| : (i += 1) {
                if (!std.mem.eql(u8, pair.kind(), "pair")) continue;
                const key_node = pair.childByField("key") orelse continue;
                const value_node = pair.childByField("value") orelse continue;
                const raw_key = stringContent(tree, key_node);
                const escaped = try escapeSegment(gpa, raw_key);
                defer gpa.free(escaped);
                const child_pointer = try std.fmt.allocPrint(gpa, "/{s}", .{escaped});
                try out.append(gpa, .{
                    .pointer = child_pointer,
                    .ty = valueTypeOf(value_node) orelse return error.InvalidJson,
                    .hash = hashOfNode(tree, value_node),
                    .child_count = directChildCount(value_node),
                });
            }
        },
        .array => {
            var i: u32 = 0;
            var index: usize = 0;
            while (root_value.namedChild(i)) |child| : (i += 1) {
                const child_pointer = try std.fmt.allocPrint(gpa, "/{d}", .{index});
                try out.append(gpa, .{
                    .pointer = child_pointer,
                    .ty = valueTypeOf(child) orelse return error.InvalidJson,
                    .hash = hashOfNode(tree, child),
                    .child_count = directChildCount(child),
                });
                index += 1;
            }
        },
        else => {},
    }
    return out.toOwnedSlice(gpa);
}

pub fn freeTopLevel(gpa: Allocator, entries: []TopEntry) void {
    for (entries) |entry| gpa.free(entry.pointer);
    gpa.free(entries);
}

pub fn resolve(gpa: Allocator, tree: ts.Tree, pointer: []const u8) Error!Entry {
    if (pointer.len == 0) {
        const root_value = try rootValue(tree);
        const ty = valueTypeOf(root_value) orelse return error.InvalidJson;
        return .{ .pointer = "", .ty = ty, .hash = hashOfNode(tree, root_value), .node = root_value };
    }
    const entries = try keyTree(gpa, tree);
    defer freeKeyTree(gpa, entries);
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.pointer, pointer)) {
            return .{ .pointer = try gpa.dupe(u8, entry.pointer), .ty = entry.ty, .hash = entry.hash, .node = entry.node };
        }
    }
    return error.PointerNotFound;
}

const testing = std.testing;
const test_util = @import("../../test_util.zig");
const alloc_bridge = @import("../../alloc_bridge.zig");

fn parseJson(parser: ts.Parser, source: []const u8) !ts.Tree {
    return parser.parseIn(grammar(), source);
}

test "topLevel lists only the root's direct children and does not recurse into nested keys" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try test_util.parser();
    defer parser.deinit();

    const source = "{\"name\": \"emetgate\", \"nested\": {\"a\": 1, \"b\": 2, \"c\": 3}}";
    const tree = try parseJson(parser, source);
    defer tree.deinit();

    const entries = try topLevel(testing.allocator, tree);
    defer freeTopLevel(testing.allocator, entries);

    try testing.expectEqual(@as(usize, 2), entries.len);
    for (entries) |entry| {
        try testing.expect(!std.mem.eql(u8, entry.pointer, "/nested/a"));
        if (std.mem.eql(u8, entry.pointer, "/nested")) {
            try testing.expectEqual(ValueType.object, entry.ty);
            try testing.expectEqual(@as(?usize, 3), entry.child_count);
        }
        if (std.mem.eql(u8, entry.pointer, "/name")) {
            try testing.expectEqual(@as(?usize, null), entry.child_count);
        }
    }
}

test "keyTree lists every pointer with its value type, and the root is excluded" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try test_util.parser();
    defer parser.deinit();

    const source = "{\"name\": \"emetgate\", \"count\": 3, \"tags\": [\"a\", \"b\"], \"nested\": {\"ok\": true}}";
    const tree = try parseJson(parser, source);
    defer tree.deinit();

    const entries = try keyTree(testing.allocator, tree);
    defer freeKeyTree(testing.allocator, entries);

    var found_name = false;
    var found_tag0 = false;
    var found_nested_ok = false;
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.pointer, "/name")) {
            try testing.expectEqual(ValueType.string, entry.ty);
            found_name = true;
        }
        if (std.mem.eql(u8, entry.pointer, "/tags/0")) {
            try testing.expectEqual(ValueType.string, entry.ty);
            found_tag0 = true;
        }
        if (std.mem.eql(u8, entry.pointer, "/nested/ok")) {
            try testing.expectEqual(ValueType.true_, entry.ty);
            found_nested_ok = true;
        }
    }
    try testing.expect(found_name);
    try testing.expect(found_tag0);
    try testing.expect(found_nested_ok);
}

test "resolve returns the subtree text and hash for a pointer" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try test_util.parser();
    defer parser.deinit();

    const source = "{\"dependencies\": {\"express\": \"^4.0.0\"}}";
    const tree = try parseJson(parser, source);
    defer tree.deinit();

    const entry = try resolve(testing.allocator, tree, "/dependencies/express");
    defer testing.allocator.free(entry.pointer);
    try testing.expectEqual(ValueType.string, entry.ty);
    try testing.expectEqualStrings("\"^4.0.0\"", tree.text(entry.node));
}

test "resolve on a missing pointer is an error, not a guess" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try test_util.parser();
    defer parser.deinit();

    const tree = try parseJson(parser, "{\"a\": 1}");
    defer tree.deinit();
    try testing.expectError(error.PointerNotFound, resolve(testing.allocator, tree, "/b"));
}

test "a key containing a slash or a tilde round-trips through RFC 6901 escaping" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try test_util.parser();
    defer parser.deinit();

    const tree = try parseJson(parser, "{\"a/b\": 1, \"c~d\": 2}");
    defer tree.deinit();

    const entries = try keyTree(testing.allocator, tree);
    defer freeKeyTree(testing.allocator, entries);
    var found_slash = false;
    var found_tilde = false;
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.pointer, "/a~1b")) found_slash = true;
        if (std.mem.eql(u8, entry.pointer, "/c~0d")) found_tilde = true;
    }
    try testing.expect(found_slash);
    try testing.expect(found_tilde);
}
