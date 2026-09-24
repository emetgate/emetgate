const std = @import("std");

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

pub const TestName = struct {
    name: []const u8,
    decl: bool,
};

fn parse(arena: Allocator, source: []const u8) !Ast {
    return Ast.parse(arena, try arena.dupeZ(u8, source), .zig);
}

pub fn testNames(arena: Allocator, source: []const u8) ![]TestName {
    const tree = try parse(arena, source);
    var names: std.ArrayList(TestName) = .empty;
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @enumFromInt(i);
        if (tree.nodeTag(node) != .test_decl) continue;
        const token = tree.nodeData(node).opt_token_and_node[0].unwrap() orelse continue;
        const text = tree.tokenSlice(token);
        switch (tree.tokenTag(token)) {
            .string_literal => try names.append(arena, .{ .name = try std.zig.string_literal.parseAlloc(arena, text), .decl = false }),
            .identifier => try names.append(arena, .{ .name = text, .decl = true }),
            else => {},
        }
    }
    return names.items;
}

pub fn declaresTests(arena: Allocator, source: []const u8) !bool {
    const tree = try parse(arena, source);
    for (0..tree.nodes.len) |i| {
        if (tree.nodeTag(@enumFromInt(i)) == .test_decl) return true;
    }
    return false;
}

pub fn imports(arena: Allocator, source: []const u8) ![]const []const u8 {
    const tree = try parse(arena, source);
    var found: std.ArrayList([]const u8) = .empty;
    const tags = tree.tokens.items(.tag);
    for (tags, 0..) |tag, i| {
        if (tag != .builtin or i + 2 >= tags.len) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(@intCast(i)), "@import")) continue;
        if (tags[i + 1] != .l_paren or tags[i + 2] != .string_literal) continue;
        try found.append(arena, try std.zig.string_literal.parseAlloc(arena, tree.tokenSlice(@intCast(i + 2))));
    }
    return found.items;
}

pub fn reachable(arena: Allocator, io: std.Io, dir: std.Io.Dir, roots: []const []const u8) ![]const []const u8 {
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    var pending: std.ArrayList([]const u8) = .empty;
    for (roots) |root| try pending.append(arena, root);
    while (pending.pop()) |path| {
        if (seen.contains(path)) continue;
        const source = dir.readFileAlloc(io, path, arena, .limited(8 * 1024 * 1024)) catch continue;
        try seen.put(arena, path, {});
        const base = std.fs.path.dirnamePosix(path) orelse ".";
        for (try imports(arena, source)) |target| {
            if (!std.mem.endsWith(u8, target, ".zig")) continue;
            try pending.append(arena, try std.fs.path.resolvePosix(arena, &.{ base, target }));
        }
    }
    return seen.keys();
}
