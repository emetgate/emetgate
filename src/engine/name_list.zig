const std = @import("std");
const ts = @import("tree_sitter.zig");
const symbol = @import("symbol.zig");
const traversal = @import("traversal.zig");
const profile_mod = @import("lang/profile.zig");
const Snapshot = @import("loader.zig").Snapshot;

const Allocator = std.mem.Allocator;
const Span = symbol.Span;
const NameList = profile_mod.NameList;

fn oneOf(kind: []const u8, kinds: []const []const u8) bool {
    for (kinds) |candidate| {
        if (std.mem.eql(u8, candidate, kind)) return true;
    }
    return false;
}

fn textOf(snapshot: *const Snapshot, node: ts.Node) []const u8 {
    return snapshot.source[node.startByte()..node.endByte()];
}

fn listOf(snapshot: *const Snapshot) ?*const NameList {
    const g = snapshot.profile.rename orelse return null;
    return if (g.name_list) |*list| list else null;
}

pub fn holds(snapshot: *const Snapshot, content: ts.Node) bool {
    const list = listOf(snapshot) orelse return false;
    if (!std.mem.eql(u8, content.kind(), list.content) or content.childCount() != 0) return false;
    const string = content.parent() orelse return false;
    if (!std.mem.eql(u8, string.kind(), list.string) or string.namedChildCount() != 3) return false;
    const start = string.namedChild(0) orelse return false;
    if (!std.mem.eql(u8, start.kind(), list.quote_start)) return false;
    for (textOf(snapshot, start)) |byte| {
        if (byte != '"' and byte != '\'') return false;
    }
    var current = string;
    var holder = string.parent() orelse return false;
    while (oneOf(holder.kind(), list.containers)) {
        current = holder;
        holder = holder.parent() orelse return false;
    }
    for (list.holders) |shape| {
        if (!std.mem.eql(u8, holder.kind(), shape.node)) continue;
        const value = holder.childByField(shape.value_field) orelse continue;
        if (!value.eql(current)) continue;
        var target = holder.childByField(shape.target_field) orelse continue;
        if (shape.object_field) |field| target = target.childByField(field) orelse continue;
        if (!std.mem.eql(u8, textOf(snapshot, target), list.owner)) continue;
        var top = holder.parent() orelse continue;
        if (std.mem.eql(u8, top.kind(), list.statement)) top = top.parent() orelse continue;
        if (top.parent() == null) return true;
    }
    return false;
}

pub const Exposed = struct {
    list: *const NameList,
    open: bool,
    listed: bool,
    names: []const []const u8,

    pub fn isPrivate(self: Exposed, name: []const u8) bool {
        const prefix = self.list.private_prefix orelse return false;
        if (!std.mem.startsWith(u8, name, prefix)) return false;
        const wrapper = self.list.public_wrapper orelse return true;
        return !(std.mem.startsWith(u8, name, wrapper) and std.mem.endsWith(u8, name, wrapper));
    }

    pub fn covers(self: Exposed, name: []const u8) bool {
        if (self.open) return true;
        if (!self.listed) return !self.isPrivate(name);
        return oneOf(name, self.names);
    }
};

fn staticList(snapshot: *const Snapshot, list: *const NameList, use: ts.Node, names: *std.ArrayList([]const u8), gpa: Allocator) !bool {
    const holder = use.parent() orelse return false;
    const shape = list.holders[0];
    if (!std.mem.eql(u8, holder.kind(), shape.node)) return false;
    const target = holder.childByField(shape.target_field) orelse return false;
    if (!target.eql(use)) return false;
    const value = holder.childByField(shape.value_field) orelse return false;
    if (!oneOf(value.kind(), list.containers)) return false;
    var i: u32 = 0;
    while (value.namedChild(i)) |item| : (i += 1) {
        if (snapshot.profile.isComment(item.kind())) continue;
        const content = item.namedChild(1) orelse return false;
        if (!holds(snapshot, content)) return false;
        try names.append(gpa, textOf(snapshot, content));
    }
    return true;
}

pub fn exposed(gpa: Allocator, snapshot: *const Snapshot) !?Exposed {
    const list = listOf(snapshot) orelse return null;
    if (list.private_prefix == null) return null;
    var names: std.ArrayList([]const u8) = .empty;
    var uses: u32 = 0;
    var open = false;
    var walker = traversal.Walker.init(snapshot.tree.root());
    defer walker.deinit();
    while (walker.next()) |entry| {
        if (entry.node.childCount() != 0 or !std.mem.eql(u8, textOf(snapshot, entry.node), list.owner)) continue;
        uses += 1;
        if (!try staticList(snapshot, list, entry.node, &names, gpa)) open = true;
    }
    return .{ .list = list, .open = open or uses > 1, .listed = uses == 1, .names = names.items };
}

pub fn spans(gpa: Allocator, snapshot: *const Snapshot, name: []const u8) ![]Span {
    var out: std.ArrayList(Span) = .empty;
    errdefer out.deinit(gpa);
    const list = listOf(snapshot) orelse return out.toOwnedSlice(gpa);
    var walker = traversal.Walker.init(snapshot.tree.root());
    defer walker.deinit();
    while (walker.next()) |entry| {
        const node = entry.node;
        if (!std.mem.eql(u8, node.kind(), list.content)) continue;
        if (!std.mem.eql(u8, textOf(snapshot, node), name) or !holds(snapshot, node)) continue;
        try out.append(gpa, .{ .start = node.startByte(), .end = node.endByte() });
    }
    return out.toOwnedSlice(gpa);
}

pub fn contentNaming(snapshot: *const Snapshot, string: ts.Node, name: []const u8) ?ts.Node {
    const list = listOf(snapshot) orelse return null;
    if (!std.mem.eql(u8, string.kind(), list.string) or string.namedChildCount() != 3) return null;
    const content = string.namedChild(1) orelse return null;
    if (!std.mem.eql(u8, textOf(snapshot, content), name) or !holds(snapshot, content)) return null;
    return content;
}
