const std = @import("std");
const builtin = @import("builtin");
const disk = @import("emetgate").disk;
const mf = @import("move_file_tool.zig");
const crash_steps = @import("crash_steps.zig");

const testing = std.testing;

fn isOld(case: *mf.Case) bool {
    mf.expectOld(case) catch return false;
    return true;
}

fn isNew(case: *mf.Case) bool {
    mf.expectNew(case) catch return false;
    return true;
}

const MoveFile = struct {
    case: mf.Case,
    root: [1][]const u8,

    pub const Params = void;

    pub fn init(self: *MoveFile, _: void) !void {
        try mf.initFiles(&self.case, &.{}, true);
        errdefer self.case.deinit();
        try mf.plan(&self.case, &mf.changes);
        self.root = .{self.case.repo.root_abs};
    }

    pub fn deinit(self: *MoveFile) void {
        self.case.deinit();
    }

    pub fn label(_: *MoveFile) []const u8 {
        return "move file";
    }

    pub fn roots(self: *MoveFile) []const []const u8 {
        return &self.root;
    }

    pub fn write(self: *MoveFile, step: *const disk.Step) !bool {
        if (mf.moveFile(&self.case, .{ .step = step })) |outcome| {
            defer outcome.deinit(testing.allocator);
            try testing.expect(outcome.result == .committed);
            return false;
        } else |err| {
            try testing.expectEqual(error.Crashed, err);
            return true;
        }
    }

    pub fn recovered(self: *MoveFile) !bool {
        const report = try disk.recover(testing.allocator, testing.io, self.case.repo.root_abs);
        try testing.expectEqual(@as(usize, 0), report.failed);
        return self.settled();
    }

    pub fn settled(self: *MoveFile) !bool {
        const old = isOld(&self.case);
        const new = isNew(&self.case);
        try testing.expect(old != new);
        return new;
    }
};

test "move file crash: the tool's move into new directories with two users cut after every step recovers to all old or all new" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const outcomes = try crash_steps.everyStepOutcomes(MoveFile, {}, 8);
    defer testing.allocator.free(outcomes);
    try crash_steps.expectNoWayBack(outcomes);
}

test "move file crash: the tool's move cut for real at every step recovers to all old or all new" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try crash_steps.expectEveryCut(MoveFile, {}, 8);
}
