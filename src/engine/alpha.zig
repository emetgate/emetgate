const std = @import("std");
const symbol = @import("symbol.zig");
const traversal = @import("traversal.zig");
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
        if (oneOf(kind, g.name_kinds)) {
            const key: NameKey = .{ .namespace = if (oneOf(kind, g.type_kinds)) 't' else if (oneOf(kind, g.property_kinds)) 'p' else 'v', .text = text };
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

