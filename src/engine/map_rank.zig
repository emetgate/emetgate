const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Edge = struct {
    from: u32,
    to: u32,
    weight: f32,
};

pub const Graph = struct {
    nodes: u32,
    offsets: []const u32,
    targets: []const u32,
    weights: []const f32,

    pub fn build(arena: Allocator, nodes: u32, edges: []const Edge) !Graph {
        const offsets = try arena.alloc(u32, @as(usize, nodes) + 1);
        @memset(offsets, 0);
        for (edges) |e| {
            if (e.from >= nodes or e.to >= nodes) return error.EdgeOutOfRange;
            offsets[e.from + 1] += 1;
        }
        for (1..offsets.len) |i| offsets[i] += offsets[i - 1];
        const fill = try arena.dupe(u32, offsets[0..nodes]);
        const targets = try arena.alloc(u32, edges.len);
        const weights = try arena.alloc(f32, edges.len);
        for (edges) |e| {
            const at = fill[e.from];
            targets[at] = e.to;
            weights[at] = e.weight;
            fill[e.from] += 1;
        }
        return .{ .nodes = nodes, .offsets = offsets, .targets = targets, .weights = weights };
    }
};

pub const Options = struct {
    damping: f64 = 0.85,
    max_iterations: u32 = 60,
    tolerance: f64 = 1e-9,
};

pub const Ranked = struct {
    rank: []f64,
    iterations: u32,
    delta: f64,
};

pub fn pagerank(arena: Allocator, graph: Graph, teleport: []const f64, options: Options) !Ranked {
    const n: usize = graph.nodes;
    if (teleport.len != n) return error.TeleportSize;
    var total: f64 = 0;
    for (teleport) |t| {
        if (!(t >= 0)) return error.NegativeTeleport;
        total += t;
    }
    const v = try arena.alloc(f64, n);
    if (total > 0) {
        for (v, teleport) |*slot, t| slot.* = t / total;
    } else {
        @memset(v, if (n == 0) 0 else 1.0 / @as(f64, @floatFromInt(n)));
    }
    const out = try arena.alloc(f64, n);
    for (0..n) |i| {
        var sum: f64 = 0;
        for (graph.weights[graph.offsets[i]..graph.offsets[i + 1]]) |w| sum += w;
        out[i] = sum;
    }
    var rank = try arena.dupe(f64, v);
    var next = try arena.alloc(f64, n);
    var iterations: u32 = 0;
    var delta: f64 = 0;
    while (iterations < options.max_iterations) {
        iterations += 1;
        @memset(next, 0);
        var dangling: f64 = 0;
        for (0..n) |i| {
            if (out[i] <= 0) {
                dangling += rank[i];
                continue;
            }
            const share = rank[i] / out[i];
            const lo = graph.offsets[i];
            const hi = graph.offsets[i + 1];
            for (graph.targets[lo..hi], graph.weights[lo..hi]) |t, w| next[t] += share * w;
        }
        delta = 0;
        for (0..n) |j| {
            const value = (1 - options.damping) * v[j] + options.damping * (next[j] + dangling * v[j]);
            delta += @abs(value - rank[j]);
            next[j] = value;
        }
        std.mem.swap([]f64, &rank, &next);
        if (delta < options.tolerance) break;
    }
    return .{ .rank = rank, .iterations = iterations, .delta = delta };
}

const testing = std.testing;

test "map rank: ranks sum to one and a node everyone calls outranks the callers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const graph = try Graph.build(arena, 4, &.{
        .{ .from = 0, .to = 3, .weight = 1 },
        .{ .from = 1, .to = 3, .weight = 1 },
        .{ .from = 2, .to = 3, .weight = 1 },
        .{ .from = 3, .to = 0, .weight = 1 },
    });
    const ranked = try pagerank(arena, graph, &.{ 1, 1, 1, 1 }, .{});
    var sum: f64 = 0;
    for (ranked.rank) |r| sum += r;
    try testing.expectApproxEqAbs(@as(f64, 1), sum, 1e-9);
    try testing.expect(ranked.rank[3] > ranked.rank[0] and ranked.rank[0] > ranked.rank[1]);
    try testing.expectApproxEqAbs(ranked.rank[1], ranked.rank[2], 1e-12);
}

test "map rank: the teleport vector moves rank toward heavy nodes and the result is the same on every run" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const graph = try Graph.build(arena, 3, &.{ .{ .from = 0, .to = 1, .weight = 1 }, .{ .from = 2, .to = 1, .weight = 0.5 } });
    const flat = try pagerank(arena, graph, &.{ 1, 1, 1 }, .{});
    const heavy = try pagerank(arena, graph, &.{ 10, 1, 1 }, .{});
    try testing.expect(heavy.rank[0] > flat.rank[0]);
    const again = try pagerank(arena, graph, &.{ 10, 1, 1 }, .{});
    try testing.expectEqualSlices(f64, heavy.rank, again.rank);
}

test "map rank: edges outside the graph and negative teleport weights are refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(error.EdgeOutOfRange, Graph.build(arena, 2, &.{.{ .from = 0, .to = 2, .weight = 1 }}));
    const graph = try Graph.build(arena, 2, &.{});
    try testing.expectError(error.NegativeTeleport, pagerank(arena, graph, &.{ 1, -1 }, .{}));
    try testing.expectError(error.TeleportSize, pagerank(arena, graph, &.{1}, .{}));
}
