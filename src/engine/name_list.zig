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
