const std = @import("std");
const builtin = @import("builtin");
const disk = @import("emetgate").disk;
const mf = @import("move_file_tool.zig");

const testing = std.testing;
const Case = mf.Case;

const StopAt = struct {
    target: usize,
    seen: usize = 0,

    fn reached(context: *anyopaque) bool {
        const self: *StopAt = @ptrCast(@alignCast(context));
        self.seen += 1;
        return self.seen == self.target;
    }
};

fn isOld(case: *Case) bool {
    mf.expectOld(case) catch return false;
    return true;
}

fn isNew(case: *Case) bool {
    mf.expectNew(case) catch return false;
    return true;
}

test "move file crash: the tool's move into new directories with two users cut after every step recovers to all old or all new" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var seen_new = false;
    var crashes: usize = 0;
    var stop: usize = 1;
    while (true) : (stop += 1) {
        errdefer std.debug.print("crash after step {d}\n", .{stop});
        var case: Case = undefined;
        try mf.initFiles(&case, &.{}, true);
        defer case.deinit();
        try mf.plan(&case, &mf.changes);
        var at: StopAt = .{ .target = stop };
        const step: disk.Step = .{ .context = &at, .reached = StopAt.reached };
        if (mf.moveFile(&case, .{ .step = &step })) |outcome| {
            defer outcome.deinit(testing.allocator);
            try testing.expect(outcome.result == .committed);
            try mf.expectNew(&case);
            break;
        } else |err| try testing.expectEqual(error.Crashed, err);
        crashes += 1;
        const report = try disk.recover(testing.allocator, testing.io, case.repo.root_abs);
        try testing.expectEqual(@as(usize, 0), report.failed);
        const old = isOld(&case);
        const new = isNew(&case);
        try testing.expect(old != new);
        if (new) seen_new = true;
        if (seen_new) try testing.expect(new);
    }
    try testing.expect(crashes >= 8);
    try testing.expect(seen_new);
}
