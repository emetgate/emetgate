const std = @import("std");
const answer = @import("answer.zig");

const Allocator = std.mem.Allocator;
const Digest = answer.Digest;

fn splitPoint(count: usize) usize {
    var k: usize = 1;
    while (k * 2 < count) k *= 2;
    return k;
}

fn rangeKey(lo: usize, hi: usize) u64 {
    return (@as(u64, @intCast(lo)) << 32) | @as(u64, @intCast(hi));
}

pub const Tree = struct {
    gpa: Allocator,
    paths: []const []const u8,
    leaves: []Digest,
    at: std.StringHashMapUnmanaged(u32) = .empty,
    nodes: std.AutoHashMapUnmanaged(u64, Digest) = .empty,

    pub fn build(gpa: Allocator, leaves: []const answer.Leaf) !Tree {
        var i: usize = 1;
        while (i < leaves.len) : (i += 1) {
            if (std.mem.order(u8, leaves[i - 1].path, leaves[i].path) != .lt) return error.UnsortedLeaves;
        }
        const paths = try gpa.alloc([]const u8, leaves.len);
        errdefer gpa.free(paths);
        const hashes = try gpa.alloc(Digest, leaves.len);
        errdefer gpa.free(hashes);
        var tree: Tree = .{ .gpa = gpa, .paths = paths, .leaves = hashes };
        errdefer tree.at.deinit(gpa);
        for (leaves, 0..) |leaf, j| {
            paths[j] = leaf.path;
            hashes[j] = answer.pathLeafHash(leaf);
            try tree.at.put(gpa, leaf.path, @intCast(j));
        }
        return tree;
    }

    pub fn deinit(self: *Tree) void {
        self.gpa.free(self.paths);
        self.gpa.free(self.leaves);
        self.at.deinit(self.gpa);
        self.nodes.deinit(self.gpa);
    }

    fn range(self: *Tree, lo: usize, hi: usize) Allocator.Error!Digest {
        if (hi - lo == 1) return self.leaves[lo];
        const key = rangeKey(lo, hi);
        if (self.nodes.get(key)) |cached| return cached;
        const k = splitPoint(hi - lo);
        const digest = answer.nodeHash(try self.range(lo, lo + k), try self.range(lo + k, hi));
        try self.nodes.put(self.gpa, key, digest);
        return digest;
    }

    pub fn root(self: *Tree) Allocator.Error!Digest {
        if (self.leaves.len == 0) return answer.emptyRoot();
        return self.range(0, self.leaves.len);
    }

    pub fn update(self: *Tree, path: []const u8, digest: Digest) error{NotALeaf}!void {
        const i = self.at.get(path) orelse return error.NotALeaf;
        self.leaves[i] = answer.pathLeafHash(.{ .path = self.paths[i], .digest = digest });
        var lo: usize = 0;
        var hi: usize = self.leaves.len;
        while (hi - lo > 1) {
            _ = self.nodes.remove(rangeKey(lo, hi));
            const k = splitPoint(hi - lo);
            if (i < lo + k) hi = lo + k else lo += k;
        }
    }
};

const testing = std.testing;

test "merkle: a cached tree updated one leaf at a time has the same root as the tree hashed from scratch" {
    var names: [37][8]u8 = undefined;
    var leaves: [37]answer.Leaf = undefined;
    for (&names, &leaves, 0..) |*name, *leaf, i| {
        name.* = .{ 'f', '0' + @as(u8, @intCast(i / 10)), '0' + @as(u8, @intCast(i % 10)), '.', 't', 's', ' ', ' ' };
        leaf.* = .{ .path = name[0..6], .digest = answer.contentDigest(name[0..3]) };
    }
    var tree = try Tree.build(testing.allocator, &leaves);
    defer tree.deinit();
    try testing.expectEqualSlices(u8, &(try answer.merkleRoot(&leaves)), &(try tree.root()));
    var prng = std.Random.DefaultPrng.init(7);
    for (0..50) |round| {
        const i = prng.random().uintLessThan(usize, leaves.len);
        var seed: [8]u8 = undefined;
        std.mem.writeInt(u64, &seed, round, .little);
        leaves[i].digest = answer.contentDigest(&seed);
        try tree.update(leaves[i].path, leaves[i].digest);
        try testing.expectEqualSlices(u8, &(try answer.merkleRoot(&leaves)), &(try tree.root()));
    }
    try testing.expectError(error.NotALeaf, tree.update("missing.ts", leaves[0].digest));
}
