const std = @import("std");
const c = @import("c");
const ts = @import("tree_sitter.zig");
const alloc_bridge = @import("alloc_bridge.zig");
const test_util = @import("test_util.zig");

const Node = ts.Node;

pub const TreeCursor = struct {
    raw: c.TSTreeCursor,

    pub fn init(start: Node) TreeCursor {
        return .{ .raw = c.ts_tree_cursor_new(start.raw) };
    }

    pub fn deinit(self: *TreeCursor) void {
        c.ts_tree_cursor_delete(&self.raw);
    }

    pub fn node(self: *const TreeCursor) Node {
        return .{ .raw = c.ts_tree_cursor_current_node(&self.raw) };
    }

    pub fn fieldName(self: *const TreeCursor) ?[:0]const u8 {
        const name: ?[*:0]const u8 = c.ts_tree_cursor_current_field_name(&self.raw);
        return if (name) |n| std.mem.span(n) else null;
    }

    pub fn depth(self: *const TreeCursor) u32 {
        return c.ts_tree_cursor_current_depth(&self.raw);
    }

    pub fn gotoFirstChild(self: *TreeCursor) bool {
        return c.ts_tree_cursor_goto_first_child(&self.raw);
    }

    pub fn gotoNextSibling(self: *TreeCursor) bool {
        return c.ts_tree_cursor_goto_next_sibling(&self.raw);
    }

    pub fn gotoParent(self: *TreeCursor) bool {
        return c.ts_tree_cursor_goto_parent(&self.raw);
    }
};

pub const Walker = struct {
    cursor: TreeCursor,
    state: enum { fresh, walking, done } = .fresh,
    skip_children: bool = false,

    pub const Entry = struct {
        node: Node,
        depth: u32,
        field: ?[:0]const u8,
    };

    pub fn init(root: Node) Walker {
        return .{ .cursor = .init(root) };
    }

    pub fn deinit(self: *Walker) void {
        self.cursor.deinit();
    }

    pub fn skipChildren(self: *Walker) void {
        self.skip_children = true;
    }

    pub fn next(self: *Walker) ?Entry {
        switch (self.state) {
            .done => return null,
            .fresh => {
                self.state = .walking;
                self.skip_children = false;
            },
            .walking => if (!self.advance()) {
                self.state = .done;
                return null;
            },
        }
        return .{
            .node = self.cursor.node(),
            .depth = self.cursor.depth(),
            .field = self.cursor.fieldName(),
        };
    }

    fn advance(self: *Walker) bool {
        const descend = !self.skip_children;
        self.skip_children = false;
        if (descend and self.cursor.gotoFirstChild()) return true;
        while (!self.cursor.gotoNextSibling()) {
            if (!self.cursor.gotoParent()) return false;
        }
        return true;
    }
};

const testing = std.testing;

test "walker visits every node in pre-order with depth and field names" {
    alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();

    const t = try test_util.TestTree.init("let x = f(1);");
    defer t.deinit();

    const Visit = struct { kind: []const u8, depth: u32, field: ?[]const u8 };
    const expected = [_]Visit{
        .{ .kind = "program", .depth = 0, .field = null },
        .{ .kind = "lexical_declaration", .depth = 1, .field = null },
        .{ .kind = "let", .depth = 2, .field = "kind" },
        .{ .kind = "variable_declarator", .depth = 2, .field = null },
        .{ .kind = "identifier", .depth = 3, .field = "name" },
        .{ .kind = "=", .depth = 3, .field = null },
        .{ .kind = "call_expression", .depth = 3, .field = "value" },
        .{ .kind = "identifier", .depth = 4, .field = "function" },
        .{ .kind = "arguments", .depth = 4, .field = "arguments" },
        .{ .kind = "(", .depth = 5, .field = null },
        .{ .kind = "number", .depth = 5, .field = null },
        .{ .kind = ")", .depth = 5, .field = null },
        .{ .kind = ";", .depth = 2, .field = null },
    };

    var walker = Walker.init(t.tree.root());
    defer walker.deinit();
    for (expected) |want| {
        const got = walker.next() orelse return error.WalkEndedEarly;
        try testing.expectEqualStrings(want.kind, got.node.kind());
        try testing.expectEqual(want.depth, got.depth);
        if (want.field) |field| {
            try testing.expectEqualStrings(field, got.field orelse return error.MissingField);
        } else {
            try testing.expect(got.field == null);
        }
    }
    try testing.expect(walker.next() == null);
    try testing.expect(walker.next() == null);
}

test "walker honours skipChildren and never escapes a subtree root" {
    alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();

    const t = try test_util.TestTree.init("function a() { inner(); }\nfunction b() {}");
    defer t.deinit();

    const first = t.tree.root().namedChild(0).?;
    var walker = Walker.init(first);
    defer walker.deinit();

    var visited: usize = 0;
    while (walker.next()) |entry| : (visited += 1) {
        try testing.expect(entry.node.startByte() >= first.startByte());
        try testing.expect(entry.node.endByte() <= first.endByte());
        try testing.expect(!std.mem.eql(u8, "call_expression", entry.node.kind()));
        if (std.mem.eql(u8, "statement_block", entry.node.kind())) walker.skipChildren();
    }
    try testing.expectEqual(@as(usize, 7), visited);
}

test "walker on a leaf yields only the leaf, and an early skipChildren is ignored" {
    alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();

    const t = try test_util.TestTree.init("x;");
    defer t.deinit();

    const statement = t.tree.root().namedChild(0).?;
    const leaf = statement.namedChild(0).?;
    try testing.expectEqual(@as(u32, 0), leaf.childCount());

    var leaf_walker = Walker.init(leaf);
    defer leaf_walker.deinit();
    try testing.expect(leaf_walker.next().?.node.eql(leaf));
    try testing.expect(leaf_walker.next() == null);

    var early = Walker.init(statement);
    defer early.deinit();
    early.skipChildren();
    try testing.expect(early.next().?.node.eql(statement));
    try testing.expect(early.next().?.node.eql(leaf));
}
