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

fn candidate(index: usize, file: []const u8, kills: []const []const u8) core.Candidate {
    return .{ .index = index, .file = file, .kills = kills, .filter = &.{} };
}

fn poolShape(gpa: std.mem.Allocator, pools: []const []const core.Candidate) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (pools) |pool| {
        for (pool) |member| try out.writer.print("{d},", .{member.index});
        try out.writer.print("|", .{});
    }
    return out.toOwnedSlice();
}

fn freePools(gpa: std.mem.Allocator, pools: []const []const core.Candidate) void {
    for (pools) |pool| gpa.free(pool);
    gpa.free(pools);
}

test "harness: a pool holds distinct files whose kills do not overlap" {
    const candidates = [_]core.Candidate{
        candidate(0, "a.zig", &.{"kills a"}),
        candidate(1, "a.zig", &.{"kills a again"}),
        candidate(2, "b.zig", &.{"kills a"}),
        candidate(3, "c.zig", &.{"kills c"}),
    };
    const pools = try core.buildPools(testing.allocator, &candidates, 16);
    defer freePools(testing.allocator, pools);

    const shape = try poolShape(testing.allocator, pools);
    defer testing.allocator.free(shape);
    try testing.expectEqualStrings("0,3,|1,2,|", shape);
}

test "harness: a pool never grows past its size" {
    const candidates = [_]core.Candidate{
        candidate(0, "a.zig", &.{"a"}),
        candidate(1, "b.zig", &.{"b"}),
        candidate(2, "c.zig", &.{"c"}),
    };
    const pools = try core.buildPools(testing.allocator, &candidates, 2);
    defer freePools(testing.allocator, pools);

    const shape = try poolShape(testing.allocator, pools);
    defer testing.allocator.free(shape);
    try testing.expectEqualStrings("0,1,|2,|", shape);
}

test "harness: the same corpus always builds the same pools" {
    const candidates = [_]core.Candidate{
        candidate(0, "a.zig", &.{"a"}),
        candidate(1, "a.zig", &.{"b"}),
        candidate(2, "b.zig", &.{"a"}),
        candidate(3, "c.zig", &.{"c"}),
        candidate(4, "d.zig", &.{"b"}),
    };
    const first = try core.buildPools(testing.allocator, &candidates, 3);
    defer freePools(testing.allocator, first);
    const second = try core.buildPools(testing.allocator, &candidates, 3);
    defer freePools(testing.allocator, second);

    const a = try poolShape(testing.allocator, first);
    defer testing.allocator.free(a);
    const b = try poolShape(testing.allocator, second);
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(a, b);
}

test "harness: only a plain expected kill may be pooled" {
    try testing.expect(core.poolable(.unit, "killed", false, false, 1));
    try testing.expect(!core.poolable(.unit, "survived", false, false, 1));
    try testing.expect(!core.poolable(.unit, "timeout", false, false, 1));
    try testing.expect(!core.poolable(.unit, "compile_error", false, false, 1));
    try testing.expect(!core.poolable(.unit, "no_tests", false, false, 1));
    try testing.expect(!core.poolable(.e2e, "killed", false, false, 1));
    try testing.expect(!core.poolable(.unit, "killed", true, false, 1));
    try testing.expect(!core.poolable(.unit, "killed", false, true, 1));
    try testing.expect(!core.poolable(.unit, "killed", false, false, 0));
}

test "harness: a pool is killed only when the failures are exactly the expected kills" {
    const expected = [_][]const u8{ "kills a", "kills b" };

    const exact = [_][]const u8{ "tests.a.test.kills a", "tests.b.test.kills b" };
    try testing.expectEqual(core.PoolVerdict.killed, core.poolVerdict(.killed, &exact, &expected));

    const missing = [_][]const u8{"tests.a.test.kills a"};
    try testing.expectEqual(core.PoolVerdict.inconclusive, core.poolVerdict(.killed, &missing, &expected));

    const extra = [_][]const u8{ "tests.a.test.kills a", "tests.b.test.kills b", "tests.c.test.kills c" };
    try testing.expectEqual(core.PoolVerdict.inconclusive, core.poolVerdict(.killed, &extra, &expected));

    try testing.expectEqual(core.PoolVerdict.inconclusive, core.poolVerdict(.compile_error, &exact, &expected));
    try testing.expectEqual(core.PoolVerdict.inconclusive, core.poolVerdict(.other_error, &exact, &expected));
    try testing.expectEqual(core.PoolVerdict.inconclusive, core.poolVerdict(.survived, &.{}, &expected));
}

test "harness: an inconclusive pool halves until a single mutation is left" {
    var pool = [_]core.Candidate{
        candidate(0, "a.zig", &.{"a"}),
        candidate(1, "b.zig", &.{"b"}),
        candidate(2, "c.zig", &.{"c"}),
        candidate(3, "d.zig", &.{"d"}),
        candidate(4, "e.zig", &.{"e"}),
    };
    var queue: std.ArrayList([]const core.Candidate) = .empty;
    defer queue.deinit(testing.allocator);
    try queue.append(testing.allocator, &pool);

    var singles: usize = 0;
    var at: usize = 0;
    while (at < queue.items.len) : (at += 1) {
        const current = queue.items[at];
        if (current.len == 1) {
            singles += 1;
            continue;
        }
        const cut = core.splitAt(current);
        try testing.expect(cut != 0 and cut != current.len);
        try queue.append(testing.allocator, current[0..cut]);
        try queue.append(testing.allocator, current[cut..]);
    }
    try testing.expectEqual(@as(usize, 5), singles);
}

test "harness: a pool run is compared against the union of its members" {
    const pool = [_]core.Candidate{
        .{ .index = 0, .file = "a.zig", .kills = &.{ "a1", "a2" }, .filter = &.{"prefix: "} },
        .{ .index = 1, .file = "b.zig", .kills = &.{"a1"}, .filter = &.{} },
    };
    const kills = try core.unionNames(testing.allocator, &pool, "kills");
    defer testing.allocator.free(kills);
    try testing.expectEqual(@as(usize, 2), kills.len);
    try testing.expectEqualStrings("a1", kills[0]);
    try testing.expectEqualStrings("a2", kills[1]);

    const filters = try core.poolFilter(testing.allocator, &pool);
    defer testing.allocator.free(filters);
    try testing.expectEqual(@as(usize, 2), filters.len);
    try testing.expectEqualStrings("prefix: ", filters[0]);
    try testing.expectEqualStrings("a1", filters[1]);
}

test "harness: pooling refuses to start unless the unmutated tree is green" {
    try testing.expect(core.baselineIsGreen(0, "Build Summary: 34/34 steps succeeded; 12/12 tests passed\n"));
    try testing.expect(!core.baselineIsGreen(1, "Build Summary: 34/34 steps succeeded; 12/12 tests passed\n"));
    try testing.expect(!core.baselineIsGreen(0, "Build Summary: 3/3 steps succeeded\n"));
    try testing.expect(!core.baselineIsGreen(0, "Build Summary: 32/34 steps succeeded (1 failed); 11/12 tests passed (1 failed)\n"));
    try testing.expect(!core.baselineIsGreen(0, "Build Summary: 32/34 steps succeeded; 11/12 tests passed (1 crashed)\n"));
    try testing.expect(!core.baselineIsGreen(0, "Build Summary: 34/34 steps succeeded; 0/0 tests passed\n"));
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
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "other.zig", .data = "other original" });
    const journal: core.Journal = .{ .dir = tmp.dir, .io = testing.io };

    try testing.expect((try journal.recover(testing.allocator, tmp.dir)) == null);

    try journal.record(testing.allocator, &.{
        .{ .path = "target.zig", .original = "original" },
        .{ .path = "other.zig", .original = "other original" },
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "target.zig", .data = "mutated" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "other.zig", .data = "other mutated" });

    const restored = (try journal.recover(testing.allocator, tmp.dir)).?;
    defer {
        for (restored) |path| testing.allocator.free(path);
        testing.allocator.free(restored);
    }
    try testing.expectEqual(@as(usize, 2), restored.len);
    try testing.expectEqualStrings("target.zig", restored[0]);
    try testing.expectEqualStrings("other.zig", restored[1]);
    for ([_][]const u8{ "target.zig", "other.zig" }, [_][]const u8{ "original", "other original" }) |path, want| {
        const content = try tmp.dir.readFileAlloc(testing.io, path, testing.allocator, .unlimited);
        defer testing.allocator.free(content);
        try testing.expectEqualStrings(want, content);
    }
    try testing.expect((try journal.recover(testing.allocator, tmp.dir)) == null);
}
