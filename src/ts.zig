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
        return .{ .raw = raw };
    }
};

pub const Tree = struct {
    raw: *c.TSTree,

    pub fn deinit(self: Tree) void {
        c.ts_tree_delete(self.raw);
    }

    pub fn root(self: Tree) Node {
        return .{ .raw = c.ts_tree_root_node(self.raw) };
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

    pub fn text(self: Node, source: []const u8) []const u8 {
        return source[self.startByte()..self.endByte()];
    }

    pub fn isNamed(self: Node) bool {
        return c.ts_node_is_named(self.raw);
    }

    pub fn hasError(self: Node) bool {
        return c.ts_node_has_error(self.raw);
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

    fn wrap(raw: c.TSNode) ?Node {
        return if (c.ts_node_is_null(raw)) null else .{ .raw = raw };
    }
};

const testing = std.testing;

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

    const source = "function add(a: number, b: number): number { return a + b; }";
    const parser = try Parser.init(typescript());
    defer parser.deinit();
    const tree = try parser.parse(source);
    defer tree.deinit();

    const program = tree.root();
    try testing.expectEqualStrings("program", program.kind());
    try testing.expect(!program.hasError());
    try testing.expectEqual(@as(u32, 1), program.namedChildCount());

    const function = program.namedChild(0).?;
    try testing.expectEqualStrings("function_declaration", function.kind());
    try testing.expectEqualStrings("add", function.childByField("name").?.text(source));
    try testing.expectEqualStrings("statement_block", function.childByField("body").?.kind());
    try testing.expectEqualStrings("(a: number, b: number)", function.childByField("parameters").?.text(source));
    try testing.expect(function.childByField("no_such_field") == null);
    try testing.expect(program.namedChild(1) == null);
}

test "broken syntax is flagged on the root" {
    alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();

    const parser = try Parser.init(typescript());
    defer parser.deinit();
    const tree = try parser.parse("function broken( {");
    defer tree.deinit();

    try testing.expect(tree.root().hasError());
}

test "bridge accounts a tree that outlives its parser as live memory until deleted" {
    alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();

    const parser = try Parser.init(typescript());
    const tree = try parser.parse("const answer: number = 42;");
    parser.deinit();

    const retained = alloc_bridge.stats();
    try testing.expect(retained.blocks > 0);
    try testing.expect(retained.bytes > 0);

    tree.deinit();
    try testing.expectEqual(alloc_bridge.Stats{ .blocks = 0, .bytes = 0 }, alloc_bridge.stats());
}
