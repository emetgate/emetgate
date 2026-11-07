const std = @import("std");
const builtin = @import("builtin");
const disk = @import("emetgate").disk;
const tool = @import("rename_tool.zig");
const Snapshots = @import("crash_snapshot.zig").Snapshots;

const testing = std.testing;
const Case = tool.Case;

const State = enum { old, new };

fn stateOf(case: *Case, files: []const []const u8, olds: []const []const u8, news: []const []const u8) !State {
    var old_count: usize = 0;
    var new_count: usize = 0;
    for (files, olds, news) |rel, old, new| {
        const text = try case.repo.read(rel);
        defer testing.allocator.free(text);
        if (std.mem.eql(u8, text, old)) old_count += 1 else if (std.mem.eql(u8, text, new)) new_count += 1 else return error.TornFile;
    }
    if (old_count == files.len) return .old;
    if (new_count == files.len) return .new;
    return error.MixedBatch;
}

fn crashEveryStep(files: []const []const u8, olds: []const []const u8, news: []const []const u8, locations: []const @import("ts_fixture.zig").Loc) !void {
    var case: Case = undefined;
    if (files.len == 3) try case.initThree() else try case.init(&.{ .{ .rel = "src/a.ts", .text = tool.a_src }, .{ .rel = "src/b.ts", .text = tool.b_src } }, true);
    defer case.deinit();
    try case.plan(locations);
    var snapshots = try Snapshots.init(case.repo.root_abs);
    defer snapshots.deinit();
    const step = snapshots.step();
    const outcome = try case.rename("src/a.ts", "add", "sum", true, &step);
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try testing.expectEqual(State.new, try stateOf(&case, files, olds, news));
    const steps = try snapshots.taken();
    try testing.expect(steps >= 2 * files.len);
    case.session.deinit();
    var seen_new = false;
    for (1..steps + 1) |stop| {
        errdefer std.debug.print("crash after step {d}\n", .{stop});
        try snapshots.restore(stop);
        const report = try disk.recover(testing.allocator, testing.io, case.repo.root_abs);
        try testing.expectEqual(@as(usize, 0), report.failed);
        const state = try stateOf(&case, files, olds, news);
        if (state == .new) seen_new = true;
        if (seen_new) try testing.expectEqual(State.new, state);
    }
    try testing.expect(seen_new);
}

test "rename crash: a two-file rename cut after every commit step recovers to all old or all new" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try crashEveryStep(&.{ "src/a.ts", "src/b.ts" }, &.{ tool.a_src, tool.b_src }, &.{ tool.a_new, tool.b_new }, tool.all_locations[0..3]);
}

test "rename crash: a three-file rename cut after every commit step recovers to all old or all new" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try crashEveryStep(&.{ "src/a.ts", "src/b.ts", "src/c.ts" }, &.{ tool.a_src, tool.b_src, tool.c_src }, &.{ tool.a_new, tool.b_new, tool.c_new }, &tool.all_locations);
}
