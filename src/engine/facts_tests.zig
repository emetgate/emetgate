const std = @import("std");
const ts = @import("tree_sitter.zig");
const facts = @import("facts.zig");
const traversal = @import("traversal.zig");
const facts_spine = @import("facts_spine.zig");
const profile_mod = @import("lang/profile.zig");

const Allocator = std.mem.Allocator;
const Profile = profile_mod.Profile;
const Facts = profile_mod.Facts;
const TestBlock = facts.TestBlock;
const none = facts.none;

pub const max_title_chars: usize = 100;

fn oneOf(kind: []const u8, kinds: []const []const u8) bool {
    for (kinds) |candidate| {
        if (std.mem.eql(u8, candidate, kind)) return true;
    }
    return false;
}

fn identifierByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

pub fn mentionsCall(source: []const u8, names: []const []const u8) bool {
    for (names) |name| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, source, from, name)) |at| : (from = at + 1) {
            if (at != 0 and identifierByte(source[at - 1])) continue;
            const after = at + name.len;
            if (after < source.len and (source[after] == '(' or source[after] == '.')) return true;
        }
    }
    return false;
}

pub fn isTestPath(table: *const Facts, path: []const u8) bool {
    const name = std.fs.path.basenamePosix(path);
    for (table.test_file_infixes) |infix| {
        if (std.mem.indexOf(u8, name, infix) != null) return true;
    }
    for (table.test_dirs) |dir| {
        if (std.mem.startsWith(u8, path, dir) and path.len > dir.len and path[dir.len] == '/') return true;
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, path, from, dir)) |at| : (from = at + 1) {
            if (at == 0 or path[at - 1] != '/') continue;
            const after = at + dir.len;
            if (after < path.len and path[after] == '/') return true;
        }
    }
    return false;
}

fn rootName(profile: *const Profile, table: *const Facts, callee: ts.Node) ?ts.Node {
    var current = callee;
    while (true) {
        const kind = current.kind();
        if (std.mem.eql(u8, kind, profile.identifier)) return current;
        if (std.mem.eql(u8, kind, table.member)) {
            current = current.childByField(table.object_field) orelse return null;
            continue;
        }
        if (std.mem.eql(u8, kind, profile.call.node)) {
            current = current.childByField(profile.call.function_field) orelse return null;
            continue;
        }
        return null;
    }
}

fn titleOf(arena: Allocator, profile: *const Profile, source: []const u8, node: ts.Node) ![]const u8 {
    var raw = source[node.startByte()..node.endByte()];
    if (oneOf(node.kind(), profile.prose_strings) and raw.len >= 2) raw = raw[1 .. raw.len - 1];
    var out: std.ArrayList(u8) = .empty;
    var space = false;
    for (raw) |c| {
        if (out.items.len >= max_title_chars) break;
        if (c == '\n' or c == '\r' or c == '\t' or c == ' ') {
            space = out.items.len != 0;
            continue;
        }
        if (space) try out.append(arena, ' ');
        space = false;
        try out.append(arena, c);
    }
    var end = out.items.len;
    while (end > 0 and !std.unicode.utf8ValidateSlice(out.items[0..end])) end -= 1;
    return out.items[0..end];
}

pub fn collect(arena: Allocator, profile: *const Profile, tree: ts.Tree, lines: facts_spine.Lines) ![]const TestBlock {
    const table = profile.facts orelse return &.{};
    if (table.test_calls.len == 0 or !mentionsCall(lines.bytes, table.test_calls)) return &.{};
    var out: std.ArrayList(TestBlock) = .empty;
    var open: std.ArrayList(u32) = .empty;
    var kinds: std.ArrayList([]const u8) = .empty;
    var walker = traversal.Walker.init(tree.root());
    defer walker.deinit();
    while (walker.next()) |entry| {
        const depth: usize = entry.depth;
        kinds.shrinkRetainingCapacity(depth);
        const node = entry.node;
        const kind = node.kind();
        try kinds.append(arena, kind);
        if (profile.isComment(kind)) {
            walker.skipChildren();
            continue;
        }
        if (!std.mem.eql(u8, kind, profile.call.node)) continue;
        if (depth != 0 and std.mem.eql(u8, kinds.items[depth - 1], profile.call.node)) {
            if (entry.field) |field| if (std.mem.eql(u8, field, profile.call.function_field)) continue;
        }
        const callee = node.childByField(profile.call.function_field) orelse continue;
        const root = rootName(profile, table, callee) orelse continue;
        if (!oneOf(lines.bytes[root.startByte()..root.endByte()], table.test_calls)) continue;
        const arguments = node.childByField(profile.call.arguments_field) orelse continue;
        const first = arguments.namedChild(0) orelse continue;
        const start = node.startByte();
        const end = node.endByte();
        while (open.items.len != 0 and out.items[open.items[open.items.len - 1]].end <= start) _ = open.pop();
        const parent = if (open.items.len == 0) none else open.items[open.items.len - 1];
        const index: u32 = @intCast(out.items.len);
        try out.append(arena, .{ .title = try titleOf(arena, profile, lines.bytes, first), .start = start, .end = end, .line = lines.lineAt(start), .parent = parent });
        try open.append(arena, index);
    }
    return out.items;
}

pub fn innermost(blocks: []const TestBlock, offset: u32) ?u32 {
    var low: usize = 0;
    var high: usize = blocks.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (blocks[mid].start <= offset) low = mid + 1 else high = mid;
    }
    if (low == 0) return null;
    var node: ?u32 = @intCast(low - 1);
    while (node) |n| {
        if (blocks[n].end > offset) return n;
        node = if (blocks[n].parent == none) null else blocks[n].parent;
    }
    return null;
}

pub fn titleChain(arena: Allocator, blocks: []const TestBlock, index: u32) ![]const u8 {
    var chain: std.ArrayList(u32) = .empty;
    var node: ?u32 = index;
    while (node) |n| {
        try chain.append(arena, n);
        node = if (blocks[n].parent == none) null else blocks[n].parent;
    }
    var out: std.ArrayList(u8) = .empty;
    var i = chain.items.len;
    while (i > 0) : (i -= 1) {
        if (i != chain.items.len) try out.appendSlice(arena, " > ");
        try out.appendSlice(arena, blocks[chain.items[i - 1]].title);
    }
    return out.items;
}
