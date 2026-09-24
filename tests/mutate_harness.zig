const std = @import("std");
const builtin = @import("builtin");
const core = @import("../tools/mutate/core.zig");
const job = @import("../tools/mutate/job.zig");
const zig_source = @import("zig_source.zig");

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
    try core.writeSummary(&w, 5, 1, 2, 9, 4);
    try testing.expectEqualStrings("5 mutation(s) run, 4 as expected, 1 not as expected, 2 e2e mutation(s) skipped (pass --e2e), 9 expected survivor(s) skipped (drop --skip-survivors), 4 mutation(s) verified one at a time this run", w.buffered());

    w = .fixed(&buf);
    try core.writeSummary(&w, 3, 0, 0, 0, 0);
    try testing.expectEqualStrings("3 mutation(s) run, 3 as expected, 0 not as expected", w.buffered());
}

fn candidate(index: usize, file: []const u8, kills: []const []const u8) core.Candidate {
    return .{ .index = index, .file = file, .kills = kills, .filter = &.{}, .from = "", .to = "" };
}

fn anchored(index: usize, file: []const u8, kills: []const []const u8, from: []const u8, to: []const u8) core.Candidate {
    return .{ .index = index, .file = file, .kills = kills, .filter = &.{}, .from = from, .to = to };
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

test "harness: mutations in one file share a pool so only one module changes" {
    const candidates = [_]core.Candidate{
        anchored(0, "a.zig", &.{"a1"}, "alpha", "ALPHA"),
        anchored(1, "b.zig", &.{"b1"}, "one", "ONE"),
        anchored(2, "a.zig", &.{"a2"}, "beta", "BETA"),
        anchored(3, "a.zig", &.{"a3"}, "gamma", "GAMMA"),
    };
    const sources = [_]core.Source{
        .{ .file = "a.zig", .text = "alpha beta gamma" },
        .{ .file = "b.zig", .text = "one" },
    };
    const pools = try core.buildPools(testing.allocator, &candidates, 16, &sources);
    defer freePools(testing.allocator, pools);

    const shape = try poolShape(testing.allocator, pools);
    defer testing.allocator.free(shape);
    try testing.expectEqualStrings("0,2,3,1,|", shape);
    try testing.expectEqual(@as(usize, 2), core.modulesIn(pools[0]));
}

test "harness: a member whose anchor is gone waits for the next pool" {
    const candidates = [_]core.Candidate{
        anchored(0, "a.zig", &.{"a1"}, "needle", "thread"),
        anchored(1, "a.zig", &.{"a2"}, "needle", "pin"),
        anchored(2, "a.zig", &.{"a3"}, "haystack", "barn"),
    };
    const sources = [_]core.Source{.{ .file = "a.zig", .text = "needle in a haystack" }};
    const pools = try core.buildPools(testing.allocator, &candidates, 16, &sources);
    defer freePools(testing.allocator, pools);

    const shape = try poolShape(testing.allocator, pools);
    defer testing.allocator.free(shape);
    try testing.expectEqualStrings("0,2,|1,|", shape);
}

test "harness: a member whose anchor is ambiguous is never pooled" {
    const candidates = [_]core.Candidate{
        anchored(0, "a.zig", &.{"a1"}, "twice", "once"),
        anchored(1, "a.zig", &.{"a2"}, "unique", "changed"),
    };
    const sources = [_]core.Source{.{ .file = "a.zig", .text = "twice twice unique" }};
    const pools = try core.buildPools(testing.allocator, &candidates, 16, &sources);
    defer freePools(testing.allocator, pools);

    const shape = try poolShape(testing.allocator, pools);
    defer testing.allocator.free(shape);
    try testing.expectEqualStrings("1,|", shape);
}

test "harness: members whose kills overlap land in different pools" {
    const candidates = [_]core.Candidate{
        anchored(0, "a.zig", &.{"shared"}, "alpha", "ALPHA"),
        anchored(1, "a.zig", &.{"shared"}, "beta", "BETA"),
    };
    const sources = [_]core.Source{.{ .file = "a.zig", .text = "alpha beta" }};
    const pools = try core.buildPools(testing.allocator, &candidates, 16, &sources);
    defer freePools(testing.allocator, pools);

    const shape = try poolShape(testing.allocator, pools);
    defer testing.allocator.free(shape);
    try testing.expectEqualStrings("0,|1,|", shape);
}

test "harness: pools from different files merge only while their kills stay apart" {
    const sources = [_]core.Source{
        .{ .file = "a.zig", .text = "alpha" },
        .{ .file = "b.zig", .text = "one" },
    };

    const apart = [_]core.Candidate{
        anchored(0, "a.zig", &.{"a"}, "alpha", "ALPHA"),
        anchored(1, "b.zig", &.{"b"}, "one", "ONE"),
    };
    const merged = try core.buildPools(testing.allocator, &apart, 16, &sources);
    defer freePools(testing.allocator, merged);
    try testing.expectEqual(@as(usize, 1), merged.len);
    try testing.expectEqual(@as(usize, 2), merged[0].len);

    const clashing = [_]core.Candidate{
        anchored(0, "a.zig", &.{"shared"}, "alpha", "ALPHA"),
        anchored(1, "b.zig", &.{"shared"}, "one", "ONE"),
    };
    const kept = try core.buildPools(testing.allocator, &clashing, 16, &sources);
    defer freePools(testing.allocator, kept);
    try testing.expectEqual(@as(usize, 2), kept.len);
}

test "harness: a pool never grows past its size" {
    const candidates = [_]core.Candidate{
        anchored(0, "a.zig", &.{"a"}, "alpha", "ALPHA"),
        anchored(1, "a.zig", &.{"b"}, "beta", "BETA"),
        anchored(2, "a.zig", &.{"c"}, "gamma", "GAMMA"),
    };
    const sources = [_]core.Source{.{ .file = "a.zig", .text = "alpha beta gamma" }};
    const pools = try core.buildPools(testing.allocator, &candidates, 2, &sources);
    defer freePools(testing.allocator, pools);

    const shape = try poolShape(testing.allocator, pools);
    defer testing.allocator.free(shape);
    try testing.expectEqualStrings("0,1,|2,|", shape);
}

test "harness: the same corpus always builds the same pools" {
    const candidates = [_]core.Candidate{
        anchored(0, "a.zig", &.{"a"}, "alpha", "ALPHA"),
        anchored(1, "a.zig", &.{"b"}, "beta", "BETA"),
        anchored(2, "b.zig", &.{"a"}, "one", "ONE"),
        anchored(3, "c.zig", &.{"c"}, "solo", "SOLO"),
        anchored(4, "d.zig", &.{"b"}, "four", "FOUR"),
    };
    const sources = [_]core.Source{
        .{ .file = "a.zig", .text = "alpha beta" },
        .{ .file = "b.zig", .text = "one" },
        .{ .file = "c.zig", .text = "solo" },
        .{ .file = "d.zig", .text = "four" },
    };
    const first = try core.buildPools(testing.allocator, &candidates, 3, &sources);
    defer freePools(testing.allocator, first);
    const second = try core.buildPools(testing.allocator, &candidates, 3, &sources);
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

test "harness: a tenth of the corpus is verified one at a time, and it rotates" {
    const buckets = core.rotationBuckets(10);
    try testing.expectEqual(@as(usize, 10), buckets);
    try testing.expectEqual(@as(usize, 4), core.rotationBuckets(25));
    try testing.expectEqual(@as(usize, 4), core.rotationBuckets(30));
    try testing.expectEqual(@as(usize, 1), core.rotationBuckets(100));
    try testing.expectEqual(@as(usize, 0), core.rotationBuckets(0));

    const first = core.rotationBucket(0, buckets);
    try testing.expectEqual(@as(usize, 0), first);
    const second = core.rotationBucket(1, buckets);
    try testing.expectEqual(@as(usize, 1), second);

    try testing.expect(core.inRotation(0, first, buckets));
    try testing.expect(!core.inRotation(1, first, buckets));
    try testing.expect(core.inRotation(1, second, buckets));

    var overlap: usize = 0;
    var picked_first: usize = 0;
    for (0..40) |ordinal| {
        const in_first = core.inRotation(ordinal, first, buckets);
        const in_second = core.inRotation(ordinal, second, buckets);
        if (in_first) picked_first += 1;
        if (in_first and in_second) overlap += 1;
    }
    try testing.expectEqual(@as(usize, 4), picked_first);
    try testing.expectEqual(@as(usize, 0), overlap);

    var covered = [_]bool{false} ** 10;
    for (0..buckets) |n| {
        const bucket = core.rotationBucket(n, buckets);
        for (0..10) |ordinal| {
            if (core.inRotation(ordinal, bucket, buckets)) covered[ordinal] = true;
        }
    }
    for (covered) |seen| try testing.expect(seen);
    try testing.expectEqual(first, core.rotationBucket(buckets, buckets));
}

test "harness: the same rotation number always picks the same slice" {
    const buckets = core.rotationBuckets(10);
    try testing.expectEqual(core.rotationBucket(7, buckets), core.rotationBucket(7, buckets));
    try testing.expectEqual(core.rotationBucket(7, buckets), core.rotationBucket(17, buckets));
    try testing.expectEqual(@as(usize, 7), core.rotationBucket(7, buckets));
}

test "harness: consecutive rotation numbers pick different slices" {
    const buckets = core.rotationBuckets(10);
    var previous = core.rotationBucket(0, buckets);
    for (1..buckets) |n| {
        const bucket = core.rotationBucket(n, buckets);
        try testing.expect(bucket != previous);
        previous = bucket;
    }
}

test "harness: no rotation number means the first slice, and no rotation at all means none" {
    const buckets = core.rotationBuckets(10);
    try testing.expectEqual(@as(usize, 0), core.rotationBucket(0, buckets));
    try testing.expect(core.inRotation(0, core.rotationBucket(0, buckets), buckets));
    try testing.expectEqual(@as(usize, 0), core.rotationBucket(9, 0));
    try testing.expect(!core.inRotation(0, core.rotationBucket(9, 0), 0));
}

test "harness: the rotating slice never enters a pool" {
    const all = [_]core.Candidate{
        anchored(0, "a.zig", &.{"a"}, "alpha", "ALPHA"),
        anchored(1, "a.zig", &.{"b"}, "beta", "BETA"),
        anchored(2, "a.zig", &.{"c"}, "gamma", "GAMMA"),
        anchored(3, "a.zig", &.{"d"}, "delta", "DELTA"),
    };
    const sources = [_]core.Source{.{ .file = "a.zig", .text = "alpha beta gamma delta" }};
    const buckets = core.rotationBuckets(25);
    const bucket = core.rotationBucket(0, buckets);

    var pooled: std.ArrayList(core.Candidate) = .empty;
    defer pooled.deinit(testing.allocator);
    var singles: usize = 0;
    for (all, 0..) |c, ordinal| {
        if (core.inRotation(ordinal, bucket, buckets)) {
            singles += 1;
            continue;
        }
        try pooled.append(testing.allocator, c);
    }
    try testing.expectEqual(@as(usize, 1), singles);
    try testing.expectEqual(@as(usize, 1), pooled.items[0].index);

    const pools = try core.buildPools(testing.allocator, pooled.items, 16, &sources);
    defer freePools(testing.allocator, pools);
    for (pools) |pool| {
        for (pool) |member| try testing.expect(!core.inRotation(member.index, bucket, buckets));
    }
    try testing.expectEqual(@as(usize, 3), pools[0].len);
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
    try testing.expectError(error.Timeout, job.run(testing.allocator, testing.io, &.{ "cmd", "/c", "start /b ping -n 100 127.0.0.77 & ping -n 100 127.0.0.1" }, null, 1024 * 1024, 1));
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

fn expectContent(dir: std.Io.Dir, path: []const u8, want: []const u8) !void {
    const content = try dir.readFileAlloc(testing.io, path, testing.allocator, .unlimited);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings(want, content);
}

test "harness: a mutation left in the mirror by a killed run never reaches the working tree and the next sync undoes it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "work/src");
    try tmp.dir.createDirPath(testing.io, "mirror");
    var work = try tmp.dir.openDir(testing.io, "work", .{});
    defer work.close(testing.io);
    var mirror = try tmp.dir.openDir(testing.io, "mirror", .{});
    defer mirror.close(testing.io);
    try work.writeFile(testing.io, .{ .sub_path = "src/target.zig", .data = "original" });
    try work.writeFile(testing.io, .{ .sub_path = "build.zig", .data = "build" });

    const files = [_][]const u8{ "src/target.zig", "build.zig" };
    try testing.expectEqual(@as(usize, 2), try core.syncMirror(testing.allocator, testing.io, work, mirror, &files, &.{}));
    try testing.expectEqual(@as(usize, 0), try core.syncMirror(testing.allocator, testing.io, work, mirror, &files, &files));

    try mirror.writeFile(testing.io, .{ .sub_path = "src/target.zig", .data = "mutated and never restored" });
    try expectContent(work, "src/target.zig", "original");

    try testing.expectEqual(@as(usize, 1), try core.syncMirror(testing.allocator, testing.io, work, mirror, &files, &files));
    try expectContent(mirror, "src/target.zig", "original");

    try testing.expectEqual(@as(usize, 0), try core.syncMirror(testing.allocator, testing.io, work, mirror, files[0..1], &files));
    try testing.expectError(error.FileNotFound, mirror.access(testing.io, "build.zig", .{}));
}

test "harness: a recovery record left by an older run on another branch is dropped without touching a file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "work");
    var work = try tmp.dir.openDir(testing.io, "work", .{});
    defer work.close(testing.io);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "runner.zig", .data = "branch B content" });
    try work.writeFile(testing.io, .{ .sub_path = "pending.0.orig", .data = "branch A content" });
    try work.writeFile(testing.io, .{ .sub_path = core.legacy_manifest, .data = "runner.zig\n" });

    const named = (try core.abandonLegacyRecord(testing.allocator, testing.io, work)).?;
    defer {
        for (named) |path| testing.allocator.free(path);
        testing.allocator.free(named);
    }
    try testing.expectEqual(@as(usize, 1), named.len);
    try testing.expectEqualStrings("runner.zig", named[0]);
    try expectContent(tmp.dir, "runner.zig", "branch B content");
    try testing.expectError(error.FileNotFound, work.access(testing.io, core.legacy_manifest, .{}));
    try testing.expectError(error.FileNotFound, work.access(testing.io, "pending.0.orig", .{}));
    try testing.expect((try core.abandonLegacyRecord(testing.allocator, testing.io, work)) == null);
}

test "harness: every mutation's from text occurs in its file as the harness would apply it" {
    const Entry = struct { id: []const u8, file: []const u8, from: []const u8, to: []const u8, all: bool = false };
    const Spec = struct { mutations: []const Entry };
    const cwd = std.Io.Dir.cwd();
    const spec_bytes = try cwd.readFileAlloc(testing.io, "tests/mutations.json", testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(spec_bytes);
    const spec = try std.json.parseFromSlice(Spec, testing.allocator, spec_bytes, .{ .ignore_unknown_fields = true });
    defer spec.deinit();
    try testing.expect(spec.value.mutations.len > 0);

    var stale: usize = 0;
    for (spec.value.mutations) |m| {
        const source = try cwd.readFileAlloc(testing.io, m.file, testing.allocator, .limited(core.max_source_bytes));
        defer testing.allocator.free(source);
        const mutated = core.applyMutation(testing.allocator, source, m.from, m.to, m.all) catch |err| {
            std.debug.print("stale mutation {s} in {s}: {s}\n", .{ m.id, m.file, @errorName(err) });
            stale += 1;
            continue;
        };
        testing.allocator.free(mutated);
    }
    try testing.expectEqual(@as(usize, 0), stale);
}

const test_roots = [_][]const u8{ "src/root.zig", "test_root.zig" };

fn namesReachedFrom(arena: std.mem.Allocator, dir: std.Io.Dir, roots: []const []const u8) !std.StringHashMapUnmanaged(void) {
    var names: std.StringHashMapUnmanaged(void) = .empty;
    for (try zig_source.reachable(arena, testing.io, dir, roots)) |path| {
        const source = try dir.readFileAlloc(testing.io, path, arena, .limited(8 * 1024 * 1024));
        for (try zig_source.testNames(arena, source)) |t| try names.put(arena, t.name, {});
    }
    return names;
}

test "harness: kill names come only from files a suite compiles, with escapes decoded and identifier tests included" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "sub");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "root.zig", .data = "const a = @import(\"sub/a.zig\");\n// const c = @import(\"c.zig\");\ntest \"root one\" {}\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "sub/a.zig", .data = "const b = @import(\"../b.zig\");\nconst S = struct {\n    test \"line\\none \\x41\" {}\n};\ntest named_decl {}\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.zig", .data = "test \"from b\" {}\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "c.zig", .data = "test \"only in an unimported file\" {}\n" });

    const names = try namesReachedFrom(arena, tmp.dir, &.{"root.zig"});
    try testing.expectEqual(@as(usize, 4), names.count());
    try testing.expect(names.contains("root one"));
    try testing.expect(names.contains("line\none A"));
    try testing.expect(names.contains("named_decl"));
    try testing.expect(names.contains("from b"));
    try testing.expect(!names.contains("only in an unimported file"));
}

test "harness: a failed decltest matches the identifier a mutation names" {
    const failed = [_][]const u8{"platform.rules.decltest.named_decl"};
    try testing.expect(core.missingKill(&failed, &.{"named_decl"}) == null);
    try testing.expect(core.unexpectedKill(&failed, &.{"named_decl"}) == null);
}

test "harness: every test a mutation expects to kill exists by that exact name in a file a suite compiles" {
    const Entry = struct { id: []const u8, expect: []const u8 = "test", kills: []const []const u8 = &.{} };
    const Spec = struct { mutations: []const Entry };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const spec_bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, "tests/mutations.json", arena, .limited(1024 * 1024));
    const spec = try std.json.parseFromSliceLeaky(Spec, arena, spec_bytes, .{ .ignore_unknown_fields = true });

    const names = try namesReachedFrom(arena, std.Io.Dir.cwd(), &test_roots);
    try testing.expect(names.count() > 500);

    var unknown: usize = 0;
    for (spec.mutations) |m| {
        if (!std.mem.eql(u8, m.expect, "test")) continue;
        for (m.kills) |kill| {
            if (names.contains(kill)) continue;
            std.debug.print("mutation {s} expects to kill a test that no suite compiles: {s}\n", .{ m.id, kill });
            unknown += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), unknown);
}
