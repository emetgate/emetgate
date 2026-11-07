const std = @import("std");
const builtin = @import("builtin");
const disk = @import("emetgate").disk;
const mf = @import("move_file_tool.zig");
const Snapshots = @import("crash_snapshot.zig").Snapshots;

const testing = std.testing;
const Case = mf.Case;

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
    var case: Case = undefined;
    try mf.initFiles(&case, &.{}, true);
    defer case.deinit();
    try mf.plan(&case, &mf.changes);
    var snapshots = try Snapshots.init(case.repo.root_abs);
    defer snapshots.deinit();
    const step = snapshots.step();
    const outcome = try mf.moveFile(&case, .{ .step = &step });
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try mf.expectNew(&case);
    const steps = try snapshots.taken();
    try testing.expect(steps >= 8);
    case.session.deinit();
    var seen_new = false;
    for (1..steps + 1) |stop| {
        errdefer std.debug.print("crash after step {d}\n", .{stop});
        try snapshots.restore(stop);
        const report = try disk.recover(testing.allocator, testing.io, case.repo.root_abs);
        try testing.expectEqual(@as(usize, 0), report.failed);
        const old = isOld(&case);
        const new = isNew(&case);
        try testing.expect(old != new);
        if (new) seen_new = true;
        if (seen_new) try testing.expect(new);
    }
    try testing.expect(seen_new);
}
