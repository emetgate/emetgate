const std = @import("std");
const c = @import("c");
const alloc_bridge = @import("alloc_bridge.zig");

pub const Language = c.TSLanguage;

pub const Error = error{
    IncompatibleLanguage,
    SourceTooLarge,
    ParseFailed,
};

pub fn typescript() *const Language {
    return c.tree_sitter_typescript().?;
}

pub const Parser = struct {
    raw: *c.TSParser,

    pub fn init(language: *const Language) Error!Parser {
        const raw = c.ts_parser_new().?;
        errdefer c.ts_parser_delete(raw);
        if (!c.ts_parser_set_language(raw, language)) return error.IncompatibleLanguage;
        return .{ .raw = raw };
    }

    pub fn deinit(self: Parser) void {
        c.ts_parser_delete(self.raw);
    }

    pub fn parse(self: Parser, source: []const u8) Error!Tree {
        const len = std.math.cast(u32, source.len) orelse return error.SourceTooLarge;
        const raw = c.ts_parser_parse_string(self.raw, null, source.ptr, len) orelse return error.ParseFailed;
        return .{ .raw = raw, .source = source };
    }
};

pub const Tree = struct {
    raw: *c.TSTree,
    source: []const u8,

    pub fn deinit(self: Tree) void {
        c.ts_tree_delete(self.raw);
    }

    pub fn root(self: Tree) Node {
        return .{ .raw = c.ts_tree_root_node(self.raw) };
    }

    pub fn text(self: Tree, node: Node) []const u8 {
        return self.source[node.startByte()..node.endByte()];
    }
};

pub const Node = struct {
    raw: c.TSNode,

    pub fn kind(self: Node) [:0]const u8 {
        return std.mem.span(@as([*:0]const u8, c.ts_node_type(self.raw)));
    }

    pub fn startByte(self: Node) u32 {
        return c.ts_node_start_byte(self.raw);
    }

    pub fn endByte(self: Node) u32 {
        return c.ts_node_end_byte(self.raw);
    }

    pub fn isNamed(self: Node) bool {
        return c.ts_node_is_named(self.raw);
    }

    pub fn hasError(self: Node) bool {
        return c.ts_node_has_error(self.raw);
    }

    pub fn childCount(self: Node) u32 {
        return c.ts_node_child_count(self.raw);
    }

    pub fn namedChildCount(self: Node) u32 {
        return c.ts_node_named_child_count(self.raw);
    }

    pub fn namedChild(self: Node, index: u32) ?Node {
        return wrap(c.ts_node_named_child(self.raw, index));
    }

    pub fn childByField(self: Node, field: []const u8) ?Node {
        const len = std.math.cast(u32, field.len) orelse return null;
        return wrap(c.ts_node_child_by_field_name(self.raw, field.ptr, len));
    }

    pub fn parent(self: Node) ?Node {
        return wrap(c.ts_node_parent(self.raw));
    }

    pub fn eql(self: Node, other: Node) bool {
        return c.ts_node_eq(self.raw, other.raw);
    }

    fn wrap(raw: c.TSNode) ?Node {
        return if (c.ts_node_is_null(raw)) null else .{ .raw = raw };
    }
};

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

const TestTree = struct {
    parser: Parser,
    tree: Tree,

    fn init(source: []const u8) !TestTree {
        const parser = try Parser.init(typescript());
        errdefer parser.deinit();
        return .{ .parser = parser, .tree = try parser.parse(source) };
    }

    fn deinit(self: TestTree) void {
        self.tree.deinit();
        self.parser.deinit();
    }
};

test "typescript grammar is ABI compatible with the core" {
    alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();

    try testing.expectEqual(@as(u32, 14), c.ts_language_abi_version(typescript()));
    const parser = try Parser.init(typescript());
    parser.deinit();
}

test "parses a function declaration into named, field-addressable nodes" {
    alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();

    const t = try TestTree.init("function add(a: number, b: number): number { return a + b; }");
    defer t.deinit();

    const program = t.tree.root();
    try testing.expectEqualStrings("program", program.kind());
    try testing.expect(!program.hasError());
    try testing.expectEqual(@as(u32, 1), program.namedChildCount());

    const function = program.namedChild(0).?;
    try testing.expectEqualStrings("function_declaration", function.kind());
    try testing.expectEqualStrings("add", t.tree.text(function.childByField("name").?));
    try testing.expectEqualStrings("statement_block", function.childByField("body").?.kind());
    try testing.expectEqualStrings("(a: number, b: number)", t.tree.text(function.childByField("parameters").?));
    try testing.expect(function.childByField("no_such_field") == null);
    try testing.expect(program.namedChild(1) == null);
}

test "broken syntax is flagged on the root" {
    alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();

    const t = try TestTree.init("function broken( {");
    defer t.deinit();

    try testing.expect(t.tree.root().hasError());
}

test "bridge accounts a tree that outlives its parser as live memory until deleted" {
    alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();

    const parser = try Parser.init(typescript());
    const tree = tree: {
        defer parser.deinit();
        break :tree try parser.parse("const answer: number = 42;");
    };

    const retained = alloc_bridge.stats();
    tree.deinit();
    try testing.expect(retained.blocks > 0);
    try testing.expect(retained.bytes > 0);
    try testing.expectEqual(alloc_bridge.Stats{ .blocks = 0, .bytes = 0 }, alloc_bridge.stats());
}

test "walker visits every node in pre-order with depth and field names" {
    alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();

    const t = try TestTree.init("let x = f(1);");
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

    const t = try TestTree.init("function a() { inner(); }\nfunction b() {}");
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

    const t = try TestTree.init("x;");
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
