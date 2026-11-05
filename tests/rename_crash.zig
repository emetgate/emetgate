const std = @import("std");
const builtin = @import("builtin");
const disk = @import("emetgate").disk;
const tool = @import("rename_tool.zig");
const fixture = @import("ts_fixture.zig");
const crash_steps = @import("crash_steps.zig");

const testing = std.testing;

const State = enum { old, new };

const Spec = struct {
    files: []const []const u8,
    olds: []const []const u8,
    news: []const []const u8,
    locations: []const fixture.Loc,
};

const two: Spec = .{ .files = &.{ "src/a.ts", "src/b.ts" }, .olds = &.{ tool.a_src, tool.b_src }, .news = &.{ tool.a_new, tool.b_new }, .locations = tool.all_locations[0..3] };
const three: Spec = .{ .files = &.{ "src/a.ts", "src/b.ts", "src/c.ts" }, .olds = &.{ tool.a_src, tool.b_src, tool.c_src }, .news = &.{ tool.a_new, tool.b_new, tool.c_new }, .locations = &tool.all_locations };

const Rename = struct {
    case: tool.Case,
    spec: Spec,
    root: [1][]const u8,

    pub const Params = Spec;

    pub fn init(self: *Rename, spec: Spec) !void {
        self.spec = spec;
        if (spec.files.len == 3) try self.case.initThree() else try self.case.init(&.{ .{ .rel = "src/a.ts", .text = tool.a_src }, .{ .rel = "src/b.ts", .text = tool.b_src } }, true);
        errdefer self.case.deinit();
        try self.case.plan(spec.locations);
        self.root = .{self.case.repo.root_abs};
    }

    pub fn deinit(self: *Rename) void {
        self.case.deinit();
    }

    pub fn label(self: *Rename) []const u8 {
        return if (self.spec.files.len == 3) "three files" else "two files";
    }

    pub fn roots(self: *Rename) []const []const u8 {
        return &self.root;
    }

    pub fn write(self: *Rename, step: *const disk.Step) !bool {
        if (self.case.rename("src/a.ts", "add", "sum", true, step)) |outcome| {
            defer outcome.deinit(testing.allocator);
            try testing.expect(outcome.result == .committed);
            return false;
        } else |err| {
            try testing.expectEqual(error.Crashed, err);
            return true;
        }
    }

    pub fn recovered(self: *Rename) !bool {
        const report = try disk.recover(testing.allocator, testing.io, self.case.repo.root_abs);
        try testing.expectEqual(@as(usize, 0), report.failed);
        return self.settled();
    }

    pub fn settled(self: *Rename) !bool {
        return try self.state() == .new;
    }

    fn state(self: *Rename) !State {
        var old_count: usize = 0;
        var new_count: usize = 0;
        for (self.spec.files, self.spec.olds, self.spec.news) |rel, old, new| {
            const text = try self.case.repo.read(rel);
            defer testing.allocator.free(text);
            if (std.mem.eql(u8, text, old)) old_count += 1 else if (std.mem.eql(u8, text, new)) new_count += 1 else return error.TornFile;
        }
        if (old_count == self.spec.files.len) return .old;
        if (new_count == self.spec.files.len) return .new;
        return error.MixedBatch;
    }
};

fn expectNoWayBack(outcomes: []const bool) !void {
    const first_new = std.mem.indexOfScalar(bool, outcomes, true) orelse return error.NeverRecoveredToNew;
    for (outcomes[first_new..]) |landed| try testing.expect(landed);
}

test "rename crash: a two-file rename cut after every commit step recovers to all old or all new" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const outcomes = try crash_steps.everyStepOutcomes(Rename, two, 2 * two.files.len);
    defer testing.allocator.free(outcomes);
    try expectNoWayBack(outcomes);
}

test "rename crash: a three-file rename cut after every commit step recovers to all old or all new" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const outcomes = try crash_steps.everyStepOutcomes(Rename, three, 2 * three.files.len);
    defer testing.allocator.free(outcomes);
    try expectNoWayBack(outcomes);
}

test "rename crash: a rename cut for real at every commit step recovers to all old or all new" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try crash_steps.expectEveryCut(Rename, two, 2 * two.files.len);
    try crash_steps.expectEveryCut(Rename, three, 2 * three.files.len);
}
