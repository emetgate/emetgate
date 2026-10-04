const std = @import("std");
const emetgate = @import("emetgate");
const evidence = emetgate.evidence;
const map = emetgate.map;
const rank = emetgate.map_region_rank;
const map_explore = emetgate.map_explore;
const fixture = @import("map_fixture.zig");
const Fixture = fixture.Fixture;

const testing = std.testing;

fn explore(f: *Fixture, regions: []const map.RegionId, question: []const u8, options: map_explore.Options) !map_explore.ExploreAnswer {
    const t = try f.arena().create(rank.Terms);
    t.* = try f.terms(question);
    const fs = try f.arena().create(evidence.FactStore);
    fs.* = f.view();
    return map_explore.explore(fs, &f.built, regions, t, options);
}

fn textOf(a: map_explore.ExploreAnswer) ![]const u8 {
    return switch (a) {
        .complete => |c| c.value.text,
        .partial => |p| p.value.text,
        .refused => |r| {
            std.debug.print("refused: {t} {s}\n", .{ r.code, r.detail });
            return error.Refused;
        },
    };
}

test "map explore: the answer ranks the region, shows the code of the best functions, lists the region and ends with one certificate line" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.load();
    const region = try f.region();
    const result = try explore(&f, &.{region}, "Which code decides whether the workflow continues when a node error happens?", .{});
    const text = try textOf(result);
    try testing.expect(std.mem.startsWith(u8, text, "explore r"));
    try testing.expect(std.mem.indexOf(u8, text, "  1 WorkflowRunner.handleNodeError  ") != null);
    try testing.expect(std.mem.indexOf(u8, text, "[target WorkflowRunner.handleNodeError ") != null);
    try testing.expect(std.mem.indexOf(u8, text, "if (node.continueOnFail) return { continueExecution: true };") != null);
    try testing.expect(std.mem.indexOf(u8, text, "listing r") != null);
    try testing.expect(std.mem.indexOf(u8, text, "workflow.ts: WorkflowRunner{handleNodeError, runNode, formatOutput}") != null);
    const value = switch (result) {
        .complete => |c| c.value,
        .partial => |p| p.value,
        .refused => unreachable,
    };
    try testing.expect(value.shown.len >= 1);
    try testing.expectEqualStrings("WorkflowRunner.handleNodeError", value.shown[0].qname);
    var status_lines: usize = 0;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    var last: []const u8 = "";
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "\u{2713} ") or std.mem.startsWith(u8, line, "partial: ")) status_lines += 1;
        last = line;
    }
    try testing.expectEqual(@as(usize, 1), status_lines);
    try testing.expect(std.mem.startsWith(u8, last, "\u{2713} ") or std.mem.startsWith(u8, last, "partial: "));
    try testing.expect(std.mem.indexOf(u8, text, "Evidence (") == null);
}

test "map explore: the text stays inside the budget and a cut is declared and certified as partial" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    for (0..12) |i| {
        var source: std.ArrayList(u8) = .empty;
        defer source.deinit(testing.allocator);
        try source.print(testing.allocator, "export function retryStep{d}(attempt: number) {{\n", .{i});
        for (0..30) |n| try source.print(testing.allocator, "  const retryValue{d} = attempt + {d};\n", .{ n, n });
        try source.appendSlice(testing.allocator, "  return attempt;\n}\n");
        const path = try std.fmt.allocPrint(f.arena(), "src/big/step{d}.ts", .{i});
        _ = try f.repo.put(path, source.items);
    }
    try f.repo.linkAll();
    f.built = try map.buildMap(f.arena(), &f.repo.store, .{});
    const region = f.built.regionOfPath("src/big/step0.ts").?;
    for ([_]usize{ 2_000, 4_000, 12_000 }) |budget| {
        const result = try explore(&f, &.{region}, "retry attempt value", .{ .k = 5, .budget = budget });
        const text = try textOf(result);
        try testing.expect(text.len <= budget);
        if (budget == 2_000) {
            try testing.expect(result == .partial);
            try testing.expect(std.mem.indexOf(u8, text, "elided") != null or std.mem.indexOf(u8, text, "not shown") != null or std.mem.indexOf(u8, text, "not listed") != null);
        }
    }
}

test "map explore: no region, an unknown region and more than three regions are refused, and a repeated region is explored once" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.load();
    const region = try f.region();
    try testing.expect((try explore(&f, &.{}, "node error", .{})) == .refused);
    try testing.expect((try explore(&f, &.{@intCast(f.built.regions.len)}, "node error", .{})) == .refused);
    const twice = try explore(&f, &.{ region, region }, "node error", .{});
    const value = switch (twice) {
        .complete => |c| c.value,
        .partial => |p| p.value,
        .refused => return error.Refused,
    };
    try testing.expectEqual(@as(usize, 1), value.regions.len);
    f.built = try map.buildMap(f.arena(), &f.repo.store, .{ .region_chars = 64, .budget_tokens = 100_000 });
    try testing.expect(f.built.regions.len >= 4);
    try testing.expect((try explore(&f, &.{ 0, 1, 2 }, "node error", .{})) != .refused);
    try testing.expect((try explore(&f, &.{ 0, 1, 2, 3 }, "node error", .{})) == .refused);
}

test "map explore: a function inside another shown function is not shown twice" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.load();
    const region = try f.region();
    const result = try explore(&f, &.{region}, "planner step measure", .{ .k = 4 });
    const value = switch (result) {
        .complete => |c| c.value,
        .partial => |p| p.value,
        .refused => return error.Refused,
    };
    var outer = false;
    var inner = false;
    for (value.shown) |s| {
        if (std.mem.eql(u8, s.qname, "outerPlanner")) outer = true;
        if (std.mem.endsWith(u8, s.qname, "plannerStep")) inner = true;
    }
    try testing.expect(!(outer and inner));
}
