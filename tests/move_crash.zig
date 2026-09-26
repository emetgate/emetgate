const std = @import("std");
const builtin = @import("builtin");
const disk = @import("emetgate").disk;
const mt = @import("move_tool.zig");

const testing = std.testing;
const Case = mt.Case;

const StopAt = struct {
    target: usize,
    seen: usize = 0,

    fn reached(context: *anyopaque) bool {
        const self: *StopAt = @ptrCast(@alignCast(context));
        self.seen += 1;
        return self.seen == self.target;
    }
};

const State = enum { old, new };

fn tracked(root: []const u8, rel: []const u8) !bool {
    const result = try std.process.run(testing.allocator, testing.io, .{ .argv = &.{ "git", "ls-files", "--", rel }, .cwd = .{ .path = root } });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    return std.mem.trim(u8, result.stdout, " \r\n").len != 0;
}

fn same(case: *Case, rel: []const u8, expected: []const u8) !bool {
    const text = try case.repo.read(rel);
    defer testing.allocator.free(text);
    return std.mem.eql(u8, text, expected);
}

fn stateOf(case: *Case) !State {
    if (!case.repo.exists("src/shapes.ts")) {
        if (!try same(case, "src/math.ts", mt.math_src) or !try same(case, "src/app.ts", mt.app_src)) return error.MixedBatch;
        if (try tracked(case.repo.root_abs, "src/shapes.ts")) return error.IndexAhead;
        return .old;
    }
    if (!try same(case, "src/shapes.ts", mt.shapes_new) or !try same(case, "src/math.ts", mt.math_new) or !try same(case, "src/app.ts", mt.app_new)) return error.MixedBatch;
    if (!try tracked(case.repo.root_abs, "src/shapes.ts")) return error.NotIndexed;
    return .new;
}

test "move crash: a three-file move to a new file cut after every commit step recovers to all old or all new" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var seen_new = false;
    var crashes: usize = 0;
    var stop: usize = 1;
    while (true) : (stop += 1) {
        errdefer std.debug.print("crash after step {d}\n", .{stop});
        var case: Case = undefined;
        try mt.initMath(&case, mt.math_src, mt.app_src, &.{}, true);
        defer case.deinit();
        try mt.plan(&case, &mt.area_refs);
        var at: StopAt = .{ .target = stop };
        const step: disk.Step = .{ .context = &at, .reached = StopAt.reached };
        if (mt.move(&case, "src/math.ts", "area", "src/shapes.ts", .{ .step = &step })) |outcome| {
            defer outcome.deinit(testing.allocator);
            try testing.expect(outcome.result == .committed);
            try testing.expectEqual(State.new, try stateOf(&case));
            break;
        } else |err| try testing.expectEqual(error.Crashed, err);
        crashes += 1;
        const report = try disk.recover(testing.allocator, testing.io, case.repo.root_abs);
        try testing.expectEqual(@as(usize, 0), report.failed);
        const state = try stateOf(&case);
        if (state == .new) seen_new = true;
        if (seen_new) try testing.expectEqual(State.new, state);
    }
    try testing.expect(crashes >= 6);
    try testing.expect(seen_new);
}
