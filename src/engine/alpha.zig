const std = @import("std");
const symbol = @import("symbol.zig");
const traversal = @import("traversal.zig");
const scope = @import("scope.zig");
const name_list = @import("name_list.zig");
const Snapshot = @import("loader.zig").Snapshot;

const Allocator = std.mem.Allocator;
const Span = symbol.Span;
const Blake3 = std.crypto.hash.Blake3;

fn oneOf(kind: []const u8, kinds: []const []const u8) bool {
    for (kinds) |candidate| {
        if (std.mem.eql(u8, candidate, kind)) return true;
    }
    return false;
}

const NameKey = struct {
    namespace: u8,
    text: []const u8,
};

const NameContext = struct {
    pub fn hash(_: NameContext, key: NameKey) u64 {
        var h = std.hash.Wyhash.init(key.namespace);
        h.update(key.text);
        return h.final();
    }

    pub fn eql(_: NameContext, a: NameKey, b: NameKey) bool {
        return a.namespace == b.namespace and std.mem.eql(u8, a.text, b.text);
    }
};

pub fn hash(gpa: Allocator, snapshot: *const Snapshot, region: Span) !symbol.Hash {
    return hashDistinct(gpa, snapshot, region, &.{});
}

fn within(spans: []const Span, start: u32, end: u32) bool {
    for (spans) |span| {
        if (span.start <= start and end <= span.end) return true;
    }
    return false;
}

pub fn hashDistinct(gpa: Allocator, snapshot: *const Snapshot, region: Span, distinct: []const Span) !symbol.Hash {
    const g = snapshot.profile.rename orelse return error.UnsupportedLanguage;
    var names: std.HashMapUnmanaged(NameKey, u32, NameContext, std.hash_map.default_max_load_percentage) = .empty;
    defer names.deinit(gpa);
    var hasher = Blake3.init(.{});
    var walker = traversal.Walker.init(snapshot.tree.root());
    defer walker.deinit();
    while (walker.next()) |entry| {
        const node = entry.node;
        if (node.endByte() <= region.start or node.startByte() >= region.end) {
            walker.skipChildren();
            continue;
        }
        if (node.childCount() != 0) continue;
        const kind = node.kind();
        const text = snapshot.source[node.startByte()..node.endByte()];
        hasher.update(kind);
        hasher.update(&.{0});
        const listed = within(distinct, node.startByte(), node.endByte()) and name_list.holds(snapshot, node);
        if (listed or oneOf(kind, g.name_kinds)) {
            const member = oneOf(kind, g.property_kinds) or scope.isProperty(g, node) or scope.isExternal(g, node);
            const renamed = listed or (member and within(distinct, node.startByte(), node.endByte()));
            const key: NameKey = .{ .namespace = if (renamed) 'r' else if (oneOf(kind, g.type_kinds)) 't' else if (oneOf(kind, g.property_kinds)) 'p' else 'v', .text = text };
            const slot = try names.getOrPut(gpa, key);
            if (!slot.found_existing) slot.value_ptr.* = names.count() - 1;
            var index: [4]u8 = undefined;
            std.mem.writeInt(u32, &index, slot.value_ptr.*, .little);
            hasher.update(&.{ 1, key.namespace });
            hasher.update(&index);
        } else {
            hasher.update(&.{2});
            hasher.update(text);
        }
        hasher.update(&.{0});
    }
    var out: symbol.Hash = undefined;
    hasher.final(&out);
    return out;
}


pub const Changed = struct {
    before: []Span,
    after: []Span,
};

const Leaf = struct { span: Span, name: bool };

fn leaves(gpa: Allocator, snapshot: *const Snapshot) ![]Leaf {
    const g = snapshot.profile.rename orelse return error.UnsupportedLanguage;
    var out: std.ArrayList(Leaf) = .empty;
    errdefer out.deinit(gpa);
    var walker = traversal.Walker.init(snapshot.tree.root());
    defer walker.deinit();
    while (walker.next()) |entry| {
        const node = entry.node;
        if (node.childCount() != 0) continue;
        try out.append(gpa, .{ .span = .{ .start = node.startByte(), .end = node.endByte() }, .name = oneOf(node.kind(), g.name_kinds) });
    }
    return out.toOwnedSlice(gpa);
}

fn textAt(snapshot: *const Snapshot, span: Span) []const u8 {
    return snapshot.source[span.start..span.end];
}

fn renamesAName(before: *const Snapshot, after: *const Snapshot, a: []const Leaf, b: []const Leaf, x: Span, y: Span) bool {
    for (a, b) |p, q| {
        if (!p.name) continue;
        if (std.mem.eql(u8, textAt(before, p.span), textAt(before, x)) and std.mem.eql(u8, textAt(after, q.span), textAt(after, y))) return true;
    }
    return false;
}

pub fn changedLeaves(gpa: Allocator, before: *const Snapshot, after: *const Snapshot) !Changed {
    const a = try leaves(gpa, before);
    defer gpa.free(a);
    const b = try leaves(gpa, after);
    defer gpa.free(b);
    var from: std.ArrayList(Span) = .empty;
    errdefer from.deinit(gpa);
    var to: std.ArrayList(Span) = .empty;
    errdefer to.deinit(gpa);
    if (a.len == b.len) {
        for (a, b) |x, y| {
            if (std.mem.eql(u8, textAt(before, x.span), textAt(after, y.span))) continue;
            if (!x.name and !renamesAName(before, after, a, b, x.span, y.span)) continue;
            try from.append(gpa, x.span);
            try to.append(gpa, y.span);
        }
    }
    return .{ .before = try from.toOwnedSlice(gpa), .after = try to.toOwnedSlice(gpa) };
}
