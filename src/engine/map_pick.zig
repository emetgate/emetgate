const std = @import("std");
const facts_store = @import("facts_store.zig");
const map = @import("map.zig");
const rank = @import("map_region_rank.zig");

const Allocator = std.mem.Allocator;
const Store = facts_store.Store;

pub const whole_repo: map.RegionId = std.math.maxInt(map.RegionId);

pub const Options = struct {
    max_regions: u32 = 3,
    depth: u32 = 30,
};

pub const Scored = struct {
    region: map.RegionId,
    score: f64,
};

pub const Pick = struct {
    regions: []const map.RegionId,
    scored: []const Scored,
    ranking: rank.Ranking,
};

pub fn codeFiles(arena: Allocator, store: *const Store, m: *const map.Map) ![]rank.RegionFile {
    var out: std.ArrayList(rank.RegionFile) = .empty;
    for (m.regions) |*region| {
        if (region.family != .code) continue;
        try out.appendSlice(arena, try rank.regionFiles(arena, store, m, region));
    }
    return out.items;
}

pub fn globalRanking(arena: Allocator, store: *const Store, m: *const map.Map, terms: *const rank.Terms, params: rank.Params, index: ?*rank.Index) !rank.Ranking {
    return rankAcross(arena, try codeFiles(arena, store, m), terms, params, index);
}

pub fn rankAcross(arena: Allocator, files: []const rank.RegionFile, terms: *const rank.Terms, params: rank.Params, index: ?*rank.Index) !rank.Ranking {
    const whole: map.Region = .{
        .id = whole_repo,
        .family = .code,
        .dir = "",
        .label = "",
        .path = "",
        .line_path = "",
        .files = &.{},
        .symbols = &.{},
        .key_symbols = &.{},
        .entry_points = &.{},
        .concepts = &.{},
        .listing_chars = 0,
    };
    return rank.rankFiles(arena, files, &whole, terms, params, index);
}

fn scoredMore(_: void, a: Scored, b: Scored) bool {
    if (a.score != b.score) return a.score > b.score;
    return a.region < b.region;
}

pub fn scoreRegions(arena: Allocator, m: *const map.Map, ranking: rank.Ranking, depth: u32) ![]Scored {
    const totals = try arena.alloc(f64, m.regions.len);
    @memset(totals, 0);
    const top = @min(depth, ranking.hits.len);
    for (ranking.hits[0..top], 0..) |hit, i| {
        if (hit.score <= 0 or hit.matched == 0) continue;
        const region = m.regionOfPath(hit.path) orelse continue;
        if (region >= totals.len) continue;
        totals[region] += hit.score / @as(f64, @floatFromInt(i + 1));
    }
    var out: std.ArrayList(Scored) = .empty;
    for (totals, 0..) |t, r| {
        if (t > 0) try out.append(arena, .{ .region = @intCast(r), .score = t });
    }
    std.mem.sort(Scored, out.items, {}, scoredMore);
    return out.items;
}

pub fn pick(arena: Allocator, store: *const Store, m: *const map.Map, terms: *const rank.Terms, params: rank.Params, index: ?*rank.Index, options: Options) !Pick {
    const ranking = try globalRanking(arena, store, m, terms, params, index);
    const scored = try scoreRegions(arena, m, ranking, options.depth);
    const count = @min(scored.len, options.max_regions);
    const regions = try arena.alloc(map.RegionId, count);
    for (scored[0..count], regions) |s, *r| r.* = s.region;
    return .{ .regions = regions, .scored = scored, .ranking = ranking };
}

pub fn merge(arena: Allocator, chosen: []const map.RegionId, kernel: []const map.RegionId, extra: usize) ![]const map.RegionId {
    var out: std.ArrayList(map.RegionId) = .empty;
    for (chosen) |r| {
        if (std.mem.indexOfScalar(map.RegionId, out.items, r) == null) try out.append(arena, r);
    }
    var added: usize = 0;
    for (kernel) |r| {
        if (added >= extra) break;
        if (std.mem.indexOfScalar(map.RegionId, out.items, r) != null) continue;
        try out.append(arena, r);
        added += 1;
    }
    return out.items;
}

const testing = std.testing;

test "map pick: the kernel region is added once after the regions the model chose" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualSlices(map.RegionId, &.{ 4, 2, 7 }, try merge(arena, &.{ 4, 2 }, &.{ 2, 7, 9 }, 1));
    try testing.expectEqualSlices(map.RegionId, &.{ 4, 2 }, try merge(arena, &.{ 4, 2 }, &.{ 2, 4 }, 1));
    try testing.expectEqualSlices(map.RegionId, &.{ 5, 6, 8 }, try merge(arena, &.{}, &.{ 5, 6, 8, 9 }, 3));
}
