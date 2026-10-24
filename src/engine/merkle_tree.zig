const std = @import("std");
const answer = @import("answer.zig");

const Allocator = std.mem.Allocator;

pub const Digest = answer.Digest;

pub const Tree = struct {
    levels: std.ArrayList(std.ArrayList(Digest)) = .empty,

    pub fn deinit(self: *Tree, gpa: Allocator) void {
        for (self.levels.items) |*level| level.deinit(gpa);
        self.levels.deinit(gpa);
        self.* = .{};
    }

    pub fn count(self: Tree) usize {
        if (self.levels.items.len == 0) return 0;
        return self.levels.items[0].items.len;
    }

    pub fn build(gpa: Allocator, leaf_hashes: []const Digest) !Tree {
        var tree: Tree = .{};
        errdefer tree.deinit(gpa);
        var first: std.ArrayList(Digest) = .empty;
        errdefer first.deinit(gpa);
        try first.appendSlice(gpa, leaf_hashes);
        try tree.levels.append(gpa, first);
        while (tree.levels.items[tree.levels.items.len - 1].items.len >= 2) {
            const below = tree.levels.items[tree.levels.items.len - 1].items;
            var next: std.ArrayList(Digest) = .empty;
            errdefer next.deinit(gpa);
            try next.ensureTotalCapacityPrecise(gpa, below.len / 2);
            var j: usize = 0;
            while (2 * j + 1 < below.len) : (j += 1) next.appendAssumeCapacity(answer.nodeHash(below[2 * j], below[2 * j + 1]));
            try tree.levels.append(gpa, next);
        }
        return tree;
    }

    pub fn root(self: Tree) Digest {
        const n = self.count();
        if (n == 0) return answer.emptyRoot();
        var blocks: [64]Digest = undefined;
        var m: usize = 0;
        var offset: usize = 0;
        var level: usize = std.math.log2_int(usize, n) + 1;
        while (level > 0) {
            level -= 1;
            if ((n >> @intCast(level)) & 1 == 0) continue;
            blocks[m] = self.levels.items[level].items[offset >> @intCast(level)];
            m += 1;
            offset += @as(usize, 1) << @intCast(level);
        }
        var acc = blocks[m - 1];
        var i = m - 1;
        while (i > 0) {
            i -= 1;
            acc = answer.nodeHash(blocks[i], acc);
        }
        return acc;
    }

    pub fn update(self: *Tree, index: usize, leaf_hash: Digest) void {
        self.levels.items[0].items[index] = leaf_hash;
        var at = index;
        var level: usize = 1;
        while (level < self.levels.items.len) : (level += 1) {
            at >>= 1;
            const here = self.levels.items[level].items;
            if (at >= here.len) break;
            const below = self.levels.items[level - 1].items;
            here[at] = answer.nodeHash(below[2 * at], below[2 * at + 1]);
        }
    }
};

const testing = std.testing;

fn sampleLeaf(i: usize) Digest {
    var name: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&name, "leaf {d}", .{i}) catch unreachable;
    return answer.leafHash(text);
}

test "merkle tree: the root of every size up to 70 matches the RFC 9162 tree hash" {
    var leaves: [70]Digest = undefined;
    for (&leaves, 0..) |*l, i| l.* = sampleLeaf(i);
    for (0..leaves.len + 1) |n| {
        var tree = try Tree.build(testing.allocator, leaves[0..n]);
        defer tree.deinit(testing.allocator);
        try testing.expectEqual(answer.rootOfLeafHashes(leaves[0..n]), tree.root());
    }
}

test "merkle tree: updating any leaf gives the root a fresh build gives" {
    var leaves: [37]Digest = undefined;
    for (&leaves, 0..) |*l, i| l.* = sampleLeaf(i);
    var tree = try Tree.build(testing.allocator, &leaves);
    defer tree.deinit(testing.allocator);
    for (0..leaves.len) |i| {
        leaves[i] = sampleLeaf(1000 + i);
        tree.update(i, leaves[i]);
        try testing.expectEqual(answer.rootOfLeafHashes(&leaves), tree.root());
    }
}
