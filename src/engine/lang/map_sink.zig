const std = @import("std");
const ts = @import("../tree_sitter.zig");
const facts = @import("../facts.zig");

const Allocator = std.mem.Allocator;
const none = facts.none;

const max_shown: usize = 40;

pub const Span = struct {
    start: u32,
    end: u32,
};

pub const Sink = struct {
    arena: Allocator,
    tree: ts.Tree,
    defs: []const facts.Def,
    test_content: bool = false,
    entries: std.ArrayList(facts.MapEntry) = .empty,
    groups: std.ArrayList(facts.MapGroup) = .empty,
    group_at: std.ArrayList(u32) = .empty,
    group_scope: std.ArrayList(Span) = .empty,
    mounts: std.ArrayList(facts.MapMount) = .empty,

    pub fn text(self: *const Sink, node: ts.Node) []const u8 {
        return self.tree.text(node);
    }

    pub fn dynamic(self: *const Sink, node: ts.Node) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(self.arena, "<{s}>", .{try self.shown(node)});
    }

    pub fn wrapped(self: *const Sink, raw: []const u8) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(self.arena, "<{s}>", .{try collapse(self.arena, raw)});
    }

    pub fn shown(self: *const Sink, node: ts.Node) Allocator.Error![]const u8 {
        return collapse(self.arena, self.text(node));
    }

    pub fn defAt(self: *const Sink, name_start: u32) u32 {
        for (self.defs, 0..) |d, i| {
            if (d.kind != .module and d.name_start == name_start) return @intCast(i);
        }
        return none;
    }

    pub fn addGroup(self: *Sink, group: facts.MapGroup, at: u32, scope: Span) Allocator.Error!u32 {
        const index: u32 = @intCast(self.groups.items.len);
        try self.groups.append(self.arena, group);
        try self.group_at.append(self.arena, at);
        try self.group_scope.append(self.arena, scope);
        return index;
    }

    pub fn findGroup(self: *const Sink, name: []const u8, at: u32) u32 {
        var found: u32 = none;
        var found_at: u32 = 0;
        var later: u32 = none;
        var later_at: u32 = std.math.maxInt(u32);
        var best_scope: u32 = 0;
        for (self.groups.items, 0..) |g, i| {
            if (g.class_like or !std.mem.eql(u8, g.name, name)) continue;
            const scope = self.group_scope.items[i];
            if (at < scope.start or at >= scope.end) continue;
            const where = self.group_at.items[i];
            if (where <= at) {
                if (found == none or scope.start > best_scope or (scope.start == best_scope and where >= found_at)) {
                    found = @intCast(i);
                    found_at = where;
                    best_scope = scope.start;
                }
            } else if (where < later_at) {
                later = @intCast(i);
                later_at = where;
            }
        }
        return if (found != none) found else later;
    }

    pub fn finish(self: *const Sink) facts.MapFacts {
        return .{ .test_content = self.test_content, .entries = self.entries.items, .groups = self.groups.items, .mounts = self.mounts.items };
    }
};

pub fn collapse(arena: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var pending = false;
    for (raw) |c| {
        if (std.ascii.isWhitespace(c)) {
            pending = out.items.len != 0;
            continue;
        }
        if (pending) try out.append(arena, ' ');
        pending = false;
        try out.append(arena, c);
    }
    if (out.items.len <= max_shown) return out.items;
    var end = max_shown;
    while (end > 0 and (out.items[end] & 0xC0) == 0x80) end -= 1;
    return std.fmt.allocPrint(arena, "{s}...", .{out.items[0..end]});
}

pub fn lineOf(node: ts.Node) u32 {
    return node.startPoint().row + 1;
}

pub fn oneOf(name: []const u8, list: []const []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, name)) return true;
    }
    return false;
}

pub fn dottedIs(spec: []const u8, module: []const u8) bool {
    if (!std.mem.startsWith(u8, spec, module)) return false;
    return spec.len == module.len or spec[module.len] == '.';
}

pub fn lastSegment(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    return name[dot + 1 ..];
}

const testing = std.testing;

test "map sink: a shown source is one line and clipped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("a + b", try collapse(arena, "a\n   + b "));
    const clipped = try collapse(arena, "x" ** 60);
    try testing.expectEqualStrings("x" ** 40 ++ "...", clipped);
}

test "map sink: a dotted module matches itself and what is under it, not a longer name" {
    try testing.expect(dottedIs("django.urls", "django"));
    try testing.expect(dottedIs("django", "django"));
    try testing.expect(!dottedIs("djangorestframework", "django"));
}
