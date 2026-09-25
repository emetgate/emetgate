const std = @import("std");
const builtin = @import("builtin");
const diagnostics = @import("diagnostics.zig");
const runner = @import("emetgate").runner;
const disk = @import("emetgate").disk;
const Runtime = @import("emetgate").runtime.Runtime;

const support = @import("runner_support.zig");
const TwoFile = support.TwoFile;
const hashOfRef = support.hashOfRef;

const testing = std.testing;

const new_a = "export function add(a: number, b: number): number { return a - b; }\n";
const new_b = "export function twice(x: number): number { return x * 2; }\n";

const swap_steps = 4;
const record_step = 5;
const finalize_steps = [_]usize{ 6, 7, 8, 9 };

const StopAt = struct {
    target: usize,
    seen: usize = 0,

    fn reached(context: *anyopaque) bool {
        const self: *StopAt = @ptrCast(@alignCast(context));
        self.seen += 1;
        return self.seen == self.target;
    }
};

fn crashThenRecover(stop: usize, expected_a: []const u8, expected_b: []const u8) !void {
    errdefer std.debug.print("crash after step {d}\n", .{stop});
    var repo = try TwoFile.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    var buf_a: [std.fs.max_path_bytes]u8 = undefined;
    var buf_b: [std.fs.max_path_bytes]u8 = undefined;
    const file_a = try repo.pathA(&buf_a);
    const file_b = try repo.pathB(&buf_b);
    const edits = [_]runner.Edit{
        .{ .file_abs = file_a, .ref_text = "add", .expected_hash = try hashOfRef(testing.allocator, testing.io, runtime, file_a, "add"), .new_body = "{ return a - b; }" },
        .{ .file_abs = file_b, .ref_text = "twice", .expected_hash = try hashOfRef(testing.allocator, testing.io, runtime, file_b, "twice"), .new_body = "{ return x * 2; }" },
    };

    var at: StopAt = .{ .target = stop };
    const step: disk.Step = .{ .context = &at, .reached = StopAt.reached };
    const outcome = runner.tryMutateBatch(testing.allocator, testing.io, runtime, .{ .edits = &edits, .test_command = "cmd /c exit 0", .commit_step = &step });
    if (outcome) |result| {
        defer result.deinit(testing.allocator);
        diagnostics.printResult(result);
        return error.NoCrash;
    } else |err| try testing.expectEqual(error.Crashed, err);

    const report = try disk.recover(testing.allocator, testing.io, repo.root_abs);
    try testing.expectEqual(@as(usize, 0), report.failed);
    const a = try repo.readA();
    defer testing.allocator.free(a);
    const b = try repo.readB();
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(expected_a, a);
    try testing.expectEqualStrings(expected_b, b);
}

test "batch crash through the tool: a crash right after the commit record recovers every file new" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try crashThenRecover(record_step, new_a, new_b);
}

test "batch crash through the tool: a crash in the middle of the finalize loop recovers every file new" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    for (finalize_steps) |stop| try crashThenRecover(stop, new_a, new_b);
}

test "batch crash through the tool: a crash during the swaps recovers every file old" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    for (1..swap_steps + 1) |stop| try crashThenRecover(stop, TwoFile.a_src, TwoFile.b_src);
}
