const std = @import("std");
const builtin = @import("builtin");
const core = @import("../tools/mutate/core.zig");
const job = @import("../tools/mutate/job.zig");

const testing = std.testing;

test "harness: a pattern must occur exactly once unless all occurrences are requested" {
    const once = try core.applyMutation(testing.allocator, "aXa", "X", "Y", false);
    defer testing.allocator.free(once);
    try testing.expectEqualStrings("aYa", once);

    try testing.expectError(error.PatternNotUnique, core.applyMutation(testing.allocator, "XaX", "X", "Y", false));
    const both = try core.applyMutation(testing.allocator, "XaX", "X", "", true);
    defer testing.allocator.free(both);
    try testing.expectEqualStrings("a", both);

    try testing.expectError(error.PatternNotFound, core.applyMutation(testing.allocator, "abc", "z", "y", false));
    try testing.expectError(error.EmptyPattern, core.applyMutation(testing.allocator, "abc", "", "y", false));
}

test "harness: failed test names are read in both output spellings" {
    const output =
        \\error: 'tests.symbol.test.refs round-trip' failed:
        \\error: 'tests.lockdown.test.the user's prompt' failed
        \\error: 'tests.symbol.test.refs round-trip' failed:
        \\Build Summary: 32/34 steps succeeded (1 failed); 237/239 tests passed (2 failed)
    ;
    const names = try core.failedTests(testing.allocator, output);
    defer testing.allocator.free(names);
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("tests.symbol.test.refs round-trip", names[0]);
    try testing.expectEqualStrings("tests.lockdown.test.the user's prompt", names[1]);

    try testing.expect(core.missingKill(names, &.{ "refs round-trip", "the user's prompt" }) == null);
    try testing.expectEqualStrings("round-trip", core.missingKill(names, &.{"round-trip"}).?);
}

test "harness: a crashed test is named like a failed one" {
    const output =
        \\error: 'src.engine.cas.test.a body that parses but spills outside its slot is a BodyEscape' exited with code 3 with stderr:
        \\       thread 15264 panic: runtime closed with 1 live snapshots: LiveSnapshots
        \\Build Summary: 6/8 steps succeeded (1 failed); 4/5 tests passed (1 crashed)
    ;
    const names = try core.failedTests(testing.allocator, output);
    defer testing.allocator.free(names);
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("src.engine.cas.test.a body that parses but spills outside its slot is a BodyEscape", names[0]);
    try testing.expect(core.missingKill(names, &.{"a body that parses but spills outside its slot is a BodyEscape"}) == null);
    try testing.expectEqual(core.Status.killed, core.classify(.unit, 1, "error: 'tests.a.test.x' exited with code 3 with stderr:\n"));
}

test "harness: exact kills reject a test outside the expected set" {
    const failed = [_][]const u8{ "tests.memory.test.memory: a", "tests.memory.test.memory: b" };
    const extra = core.unexpectedKill(&failed, &.{"memory: a"}) orelse return error.UnexpectedKillNotReported;
    try testing.expectEqualStrings("tests.memory.test.memory: b", extra);
    try testing.expect(core.unexpectedKill(&failed, &.{ "memory: a", "memory: b" }) == null);
    try testing.expect(core.unexpectedKill(&.{}, &.{"memory: a"}) == null);
}

test "harness: a failing test run is killed and its summary is parsed" {
    const output = "error: 'tests.a.test.x' failed:\nBuild Summary: 32/34 steps succeeded (1 failed); 236/239 tests passed (2 skipped, 1 failed)\n";
    const summary = core.parseSummary(output).?;
    try testing.expectEqual(@as(u32, 236), summary.passed);
    try testing.expectEqual(@as(u32, 239), summary.total);
    try testing.expectEqual(@as(u32, 1), summary.failed);
    try testing.expectEqual(core.Status.killed, core.classify(.unit, 1, output));
}

test "harness: a run with only crashed tests is killed" {
    const output = "Build Summary: 32/34 steps succeeded (1 failed); 227/239 tests passed (12 crashed)\n";
    try testing.expectEqual(@as(u32, 12), core.parseSummary(output).?.crashed);
    try testing.expectEqual(core.Status.killed, core.classify(.unit, 1, output));
}

test "harness: a compile error is classified as compile_error, not killed" {
    const output = "src\\platform\\batch.zig:75:31: error: unused capture\nerror: 1 compilation errors\nBuild Summary: 5/34 steps succeeded (2 failed)\n";
    try testing.expectEqual(core.Status.compile_error, core.classify(.unit, 1, output));
    try testing.expectEqual(core.Status.compile_error, core.classify(.e2e, 1, output));
}

test "harness: a clean run is survived and a run with no matching tests is flagged" {
    try testing.expectEqual(core.Status.survived, core.classify(.unit, 0, "Build Summary: 34/34 steps succeeded; 2/2 tests passed\n"));
    try testing.expectEqual(core.Status.no_tests, core.classify(.unit, 0, "Build Summary: 3/3 steps succeeded\n"));
    try testing.expectEqual(core.Status.other_error, core.classify(.unit, 1, "error: FileNotFound\n"));
}

test "harness: e2e-lockdown failures are killed" {
    try testing.expectEqual(core.Status.killed, core.classify(.e2e, 1, "FAIL: tool outside the lockdown allow-list: Bash\ne2e-lockdown: 1 failure(s)\n"));
    try testing.expectEqual(core.Status.survived, core.classify(.e2e, 0, "e2e-lockdown: passed\n"));
}

test "harness: a mutation's own timeout_s replaces the global limit" {
    try testing.expectEqual(@as(u64, 30), core.timeoutFor(30, 900));
    try testing.expectEqual(@as(u64, 900), core.timeoutFor(null, 900));
}

test "harness: --skip-survivors skips expected survivors and nothing else" {
    try testing.expectEqual(core.Skip.survivor, core.skipReason(.unit, "survived", false, false, true).?);
    try testing.expect(core.skipReason(.unit, "survived", false, false, false) == null);
    try testing.expect(core.skipReason(.unit, "killed", false, false, true) == null);
    try testing.expect(core.skipReason(.unit, "timeout", false, false, true) == null);
    try testing.expectEqual(core.Skip.e2e, core.skipReason(.e2e, "killed", false, false, true).?);
}

test "harness: a selected id runs even when it is an expected survivor" {
    try testing.expect(core.skipReason(.unit, "survived", true, false, true) == null);
    try testing.expect(core.skipReason(.e2e, "survived", true, false, true) == null);
}

test "harness: the summary line counts skipped survivors" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try core.writeSummary(&w, 5, 1, 2, 9);
    try testing.expectEqualStrings("5 mutation(s) run, 4 as expected, 1 not as expected, 2 e2e mutation(s) skipped (pass --e2e), 9 expected survivor(s) skipped (drop --skip-survivors)", w.buffered());

    w = .fixed(&buf);
    try core.writeSummary(&w, 3, 0, 0, 0);
    try testing.expectEqualStrings("3 mutation(s) run, 3 as expected, 0 not as expected", w.buffered());
}

test "harness: a timeout kills the grandchildren a command leaves behind" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const started = std.Io.Timestamp.now(testing.io, .awake);
    try testing.expectError(error.Timeout, job.run(testing.allocator, testing.io, &.{ "cmd", "/c", "start /b ping -n 100 127.0.0.77 & ping -n 100 127.0.0.1" }, 1024 * 1024, 1));
    const elapsed_ns = started.durationTo(std.Io.Timestamp.now(testing.io, .awake)).nanoseconds;
    try testing.expect(elapsed_ns < 20 * std.time.ns_per_s);

    const probe = try std.process.run(testing.allocator, testing.io, .{ .argv = &.{
        "powershell", "-NoProfile", "-Command",
        "@(Get-CimInstance Win32_Process -Filter \"Name = 'PING.EXE'\" | Where-Object { $_.CommandLine -like '*127.0.0.77*' }).Count",
    } });
    defer testing.allocator.free(probe.stdout);
    defer testing.allocator.free(probe.stderr);
    try testing.expectEqualStrings("0", std.mem.trim(u8, probe.stdout, " \r\n"));
}

test "harness: an interrupted mutation is restored from the journal on the next start" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "target.zig", .data = "original" });
    const journal: core.Journal = .{ .dir = tmp.dir, .io = testing.io };

    try testing.expect((try journal.recover(testing.allocator, tmp.dir)) == null);

    try journal.record("target.zig", "original");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "target.zig", .data = "mutated" });

    const restored = (try journal.recover(testing.allocator, tmp.dir)).?;
    defer testing.allocator.free(restored);
    try testing.expectEqualStrings("target.zig", restored);
    const content = try tmp.dir.readFileAlloc(testing.io, "target.zig", testing.allocator, .unlimited);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("original", content);
    try testing.expect((try journal.recover(testing.allocator, tmp.dir)) == null);
}
