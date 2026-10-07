const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");
const fixture = @import("ts_fixture.zig");
const common = @import("commit_batch.zig");

const own_dir = emetgate.own_dir;
const shadow = emetgate.shadow;
const disk = emetgate.disk;
const receipts = emetgate.receipts;

const testing = std.testing;
const Plain = common.Plain;

const util_src = "export function add(a: number, b: number): number {\n  return a + b;\n}\n";
const new_body = "{\n  return b + a;\n}";
const files = [_]fixture.File{ .{ .rel = "src/util.ts", .text = util_src }, .{ .rel = ".gitignore", .text = ".emetgate/\n" } };

fn skipOffWindows() !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
}

test "own dir commit: recover leaves a file it did not write in the intents directory, whatever its ending" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    try case.repo.write(".emetgate/intents/notes.txt", "mine\n");
    try case.repo.write(".emetgate/intents/data.json", "{}\n");
    try case.repo.write(".emetgate/intents/data.ts", "export const data = 1;\n");
    try case.repo.write(".emetgate/intents/0123456789abcdef.7.new", "ours by name\n");

    const report = try disk.recover(testing.allocator, testing.io, case.repo.root_abs);
    try testing.expectEqual(@as(usize, 0), report.commits.failed + report.commits.pending);
    try testing.expect(case.repo.exists(".emetgate/intents/notes.txt"));
    try testing.expect(case.repo.exists(".emetgate/intents/data.json"));
    try testing.expect(case.repo.exists(".emetgate/intents/data.ts"));
    try testing.expect(!case.repo.exists(".emetgate/intents/0123456789abcdef.7.new"));
}

test "own dir commit: a commit call leaves a file it did not write in the commit work directory" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    try case.repo.write(".emetgate/commit/readme.txt", "kept\n");
    try case.repo.write(".emetgate/commit/blob-old", "kept too\n");
    try case.repo.write(".emetgate/commit/blob-7", "stale\n");
    const before = try env.head();

    const reply = try env.call("emetgate_try", .{ .file = try env.abs("src/util.ts"), .symbol = "add", .hash = try env.hashOf("src/util.ts", "add"), .body = new_body, .message = "fix: swap" }, common.green, true);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings(before, try env.git(&.{ "rev-parse", "HEAD^" }));
    try testing.expect(case.repo.exists(".emetgate/commit/readme.txt"));
    try testing.expect(case.repo.exists(".emetgate/commit/blob-old"));
    try testing.expect(!case.repo.exists(".emetgate/commit/blob-7"));
}
