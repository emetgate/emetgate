const std = @import("std");
const builtin = @import("builtin");
const disk = @import("emetgate").disk;
const mt = @import("move_tool.zig");
const git_fixture = @import("git_fixture.zig");
const crash_steps = @import("crash_steps.zig");

const testing = std.testing;
const Case = mt.Case;

const State = enum { old, new };

fn tracked(root: []const u8, rel: []const u8) !bool {
    const result = try @import("emetgate").bounded_run.run(testing.allocator, testing.io, .{ .argv = &.{ try git_fixture.git(), "ls-files", "--", rel }, .cwd = .{ .path = root } });
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

const Move = struct {
    case: Case,
    root: [1][]const u8,

    pub const Params = void;

    pub fn init(self: *Move, _: void) !void {
        try mt.initMath(&self.case, mt.math_src, mt.app_src, &.{}, true);
        errdefer self.case.deinit();
        try mt.plan(&self.case, &mt.area_refs);
        self.root = .{self.case.repo.root_abs};
    }

    pub fn deinit(self: *Move) void {
        self.case.deinit();
    }

    pub fn label(_: *Move) []const u8 {
        return "move";
    }

    pub fn roots(self: *Move) []const []const u8 {
        return &self.root;
    }

    pub fn write(self: *Move, step: *const disk.Step) !bool {
        if (mt.move(&self.case, "src/math.ts", "area", "src/shapes.ts", .{ .step = step })) |outcome| {
            defer outcome.deinit(testing.allocator);
            try testing.expect(outcome.result == .committed);
            return false;
        } else |err| {
            try testing.expectEqual(error.Crashed, err);
            return true;
        }
    }

    pub fn recovered(self: *Move) !bool {
        const report = try disk.recover(testing.allocator, testing.io, self.case.repo.root_abs);
        try testing.expectEqual(@as(usize, 0), report.failed);
        return self.settled();
    }

    pub fn settled(self: *Move) !bool {
        return try stateOf(&self.case) == .new;
    }
};

test "move crash: a three-file move to a new file cut after every commit step recovers to all old or all new" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const outcomes = try crash_steps.everyStepOutcomes(Move, {}, 6);
    defer testing.allocator.free(outcomes);
    try crash_steps.expectNoWayBack(outcomes);
}

test "move crash: a three-file move cut for real at every commit step recovers to all old or all new" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try crash_steps.expectEveryCut(Move, {}, 6);
}
