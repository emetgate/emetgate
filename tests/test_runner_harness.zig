const std = @import("std");
const builtin = @import("builtin");
const runner = @import("root");
const test_util = @import("emetgate").test_util;

const testing = std.testing;

const expect_mutant_env = "EMETGATE_EXPECT_MUTANT";
const mutant_probe = "runner: the active mutant is the one the runner was given";

const sample = [_][]const u8{ "a.test.one", "a.test.two", "b.test.three", "b.test.four", "c.test.five", "c.test.six", "c.test.seven" };

test "runner: a shard parses only as i/n with 1 <= i <= n" {
    try testing.expectEqual(runner.Shard{ .index = 2, .count = 4 }, try runner.parseShard("2/4"));
    try testing.expectEqual(runner.Shard{ .index = 1, .count = 1 }, try runner.parseShard("1/1"));
    for ([_][]const u8{ "0/4", "5/4", "1/0", "4", "/4", "1/", "a/4", "-1/4" }) |bad| {
        errdefer std.debug.print("accepted shard {s}\n", .{bad});
        try testing.expectError(error.InvalidShard, runner.parseShard(bad));
    }
}

test "runner: the shards of any count together select every matching test exactly once" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const filter_sets = [_][]const []const u8{ &.{}, &.{"c.test."}, &.{ "one", "six" } };
    for (filter_sets) |filters| {
        const whole = try runner.select(arena, &sample, filters, .{});
        for (1..sample.len + 2) |count| {
            var seen = [_]u32{0} ** sample.len;
            var total: usize = 0;
            for (1..count + 1) |index| {
                const part = try runner.select(arena, &sample, filters, .{ .index = index, .count = count });
                try testing.expectEqual(whole.matched, part.matched);
                for (part.indices) |i| seen[i] += 1;
                total += part.indices.len;
            }
            try testing.expectEqual(whole.indices.len, total);
            for (sample, seen) |name, times| {
                errdefer std.debug.print("{s} ran {d} times across {d} shards\n", .{ name, times, count });
                try testing.expectEqual(@as(u32, if (runner.matches(name, filters)) 1 else 0), times);
            }
        }
    }
}

test "runner: a filter keeps a test whose name contains any of its strings" {
    try testing.expect(runner.matches("x.test.abc", &.{}));
    try testing.expect(runner.matches("x.test.abc", &.{ "zzz", "b" }));
    try testing.expect(!runner.matches("x.test.abc", &.{ "zzz", "abcd" }));
    const none = try runner.select(testing.allocator, &sample, &.{"nothing"}, .{});
    defer testing.allocator.free(none.indices);
    try testing.expectEqual(@as(usize, 0), none.matched);
}

test "runner: shard coverage names a test no shard ran, one two shards ran and a stray index" {
    try testing.expectEqual(runner.Coverage{}, try runner.coverage(testing.allocator, &sample, &.{}, &.{ 6, 0, 1, 2, 3, 4, 5 }));
    try testing.expectEqual(runner.Coverage{ .missing = 3 }, try runner.coverage(testing.allocator, &sample, &.{}, &.{ 0, 1, 2, 4, 5, 6 }));
    try testing.expectEqual(runner.Coverage{ .repeated = 2 }, try runner.coverage(testing.allocator, &sample, &.{}, &.{ 0, 1, 2, 2, 3, 4, 5, 6 }));
    try testing.expectEqual(runner.Coverage{ .stray = 9 }, try runner.coverage(testing.allocator, &sample, &.{}, &.{ 0, 9 }));
    try testing.expectEqual(runner.Coverage{ .stray = 0 }, try runner.coverage(testing.allocator, &sample, &.{"c.test."}, &.{ 0, 4, 5, 6 }));
    try testing.expectEqual(runner.Coverage{}, try runner.coverage(testing.allocator, &sample, &.{"c.test."}, &.{ 4, 5, 6 }));
}

test "runner: arguments parse into filters, a shard, a mutant and the slow switch" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const options = try runner.parseArgs(arena, &.{ "--filter", "a b", "--shard", "3/5", "--mutant", "17", "--slow", "--filter", "c", "--record=x.txt" });
    try testing.expectEqual(@as(usize, 2), options.filters.len);
    try testing.expectEqualStrings("a b", options.filters[0]);
    try testing.expectEqualStrings("c", options.filters[1]);
    try testing.expectEqual(runner.Shard{ .index = 3, .count = 5 }, options.shard);
    try testing.expectEqual(@as(u32, 17), options.mutant);
    try testing.expect(options.slow);
    try testing.expectEqualStrings("x.txt", options.record.?);
    for ([_][]const []const u8{ &.{"--filter"}, &.{ "--filter", "" }, &.{ "--shard", "0/2" }, &.{ "--mutant", "x" }, &.{"--nope"}, &.{"loose"}, &.{ "--jobs", "0" }, &.{ "--jobs", "2", "--shard", "1/2" }, &.{ "--jobs", "2", "--record=x" } }) |bad| {
        try testing.expectError(error.InvalidArgs, runner.parseArgs(arena, bad));
    }
}

fn selfRun(gpa: std.mem.Allocator, args: []const []const u8, env: ?*const std.process.Environ.Map) !std.process.RunResult {
    const exe = try std.process.executablePathAlloc(testing.io, gpa);
    defer gpa.free(exe);
    var argv: std.ArrayList([]const u8) = .empty;
    defer {
        if (runner.emetgate_mutant != 0) gpa.free(argv.items[2]);
        argv.deinit(gpa);
    }
    try argv.append(gpa, exe);
    if (runner.emetgate_mutant != 0) try argv.appendSlice(gpa, &.{ "--mutant", try std.fmt.allocPrint(gpa, "{d}", .{runner.emetgate_mutant}) });
    try argv.appendSlice(gpa, args);
    return std.process.run(gpa, testing.io, .{
        .argv = argv.items,
        .environ_map = env,
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(16 * 1024 * 1024),
    });
}

fn exitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |code| code,
        else => null,
    };
}

test "runner: a filter that matches no test fails the run instead of passing it empty" {
    const result = try selfRun(testing.allocator, &.{ "--filter", "no test is named like this 7f3a" }, null);
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expectEqual(@as(?u8, 2), exitCode(result.term));
    try testing.expect(std.mem.indexOf(u8, result.stderr, "no test matches") != null);
}

test "runner: the shards of the test binary together list every test exactly once" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const whole = try selfRun(arena, &.{"--list"}, null);
    try testing.expectEqual(@as(?u8, 0), exitCode(whole.term));
    const expected = std.mem.count(u8, whole.stdout, "\n");
    try testing.expectEqual(builtin.test_functions.len, expected);

    var seen: std.StringHashMapUnmanaged(u32) = .empty;
    const shards = 4;
    for (1..shards + 1) |i| {
        const part = try selfRun(arena, &.{ "--list", "--shard", try std.fmt.allocPrint(arena, "{d}/{d}", .{ i, shards }) }, null);
        try testing.expectEqual(@as(?u8, 0), exitCode(part.term));
        var lines = std.mem.splitScalar(u8, part.stdout, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const slot = try seen.getOrPut(arena, line);
            slot.value_ptr.* = if (slot.found_existing) slot.value_ptr.* + 1 else 1;
        }
    }
    try testing.expectEqual(expected, seen.count());
    var it = seen.iterator();
    while (it.next()) |entry| {
        errdefer std.debug.print("{s} is listed by {d} shards\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        try testing.expectEqual(@as(u32, 1), entry.value_ptr.*);
    }
}

fn countMatching(filters: []const []const u8) usize {
    var n: usize = 0;
    for (builtin.test_functions) |t| {
        if (runner.matches(t.name, filters)) n += 1;
    }
    return n;
}

test "runner: --jobs runs every selected test once across its shards" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const filters = [_][]const u8{ "runner: a shard parses", "runner: a filter keeps", "runner: shard coverage", "runner: arguments parse", "runner: shard totals" };
    const wanted = countMatching(&filters);
    try testing.expectEqual(@as(usize, 5), wanted);
    for ([_][]const u8{ "2", "3", "40" }) |jobs| {
        const result = try selfRun(arena, &.{ "--jobs", jobs, "--filter", filters[0], "--filter", filters[1], "--filter", filters[2], "--filter", filters[3], "--filter", filters[4] }, null);
        errdefer std.debug.print("--jobs {s}:\n{s}\n", .{ jobs, result.stderr });
        try testing.expectEqual(@as(?u8, 0), exitCode(result.term));
        const line = try std.fmt.allocPrint(arena, "{d}/{d} tests passed; 0 skipped; 0 failed; 0 leaked; mutant 0; {s} shard(s)", .{ wanted, wanted, jobs });
        try testing.expect(std.mem.indexOf(u8, result.stderr, line) != null);
    }
}

test "runner: a failing test in one shard fails the --jobs run and the mutant reaches every shard" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env = try testing.environ.createMap(arena);
    try env.put(expect_mutant_env, "7");
    const right = try selfRun(arena, &.{ "--jobs", "3", "--mutant", "7", "--filter", mutant_probe }, &env);
    try testing.expectEqual(@as(?u8, 0), exitCode(right.term));
    try testing.expect(std.mem.indexOf(u8, right.stderr, "1/1 tests passed; 0 skipped; 0 failed") != null);
    const wrong = try selfRun(arena, &.{ "--jobs", "3", "--mutant", "8", "--filter", mutant_probe }, &env);
    try testing.expectEqual(@as(?u8, 1), exitCode(wrong.term));
    try testing.expect(std.mem.indexOf(u8, wrong.stderr, "0/1 tests passed; 0 skipped; 1 failed") != null);
    try testing.expect(std.mem.indexOf(u8, wrong.stderr, "error: 'tests.test_runner_harness.test." ++ mutant_probe ++ "' failed") != null);
}

test "runner: shard totals are read back from a shard's last summary line" {
    const text = "x\n3/4 tests passed; 1 skipped; 0 failed; 0 leaked; mutant 0; shard 1/2\n7/9 tests passed; 1 skipped; 1 failed; 2 leaked; mutant 5; shard 2/2\n";
    try testing.expectEqual(runner.Totals{ .passed = 7, .total = 9, .skipped = 1, .failed = 1, .leaked = 2 }, runner.parseTotals(text).?);
    try testing.expect(runner.parseTotals("no summary here\n") == null);
    try testing.expect(runner.parseTotals("3/4 tests passed; 1 skipped\n") == null);
}

test "runner: the active mutant is the one the runner was given" {
    const wanted = testing.environ.getAlloc(testing.allocator, expect_mutant_env) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return testing.expectEqual(@as(u32, 0), runner.emetgate_mutant),
        else => return err,
    };
    defer testing.allocator.free(wanted);
    try testing.expectEqual(try std.fmt.parseUnsigned(u32, wanted, 10), runner.emetgate_mutant);
}

test "runner: --mutant sets the global that the schemata dispatch reads" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env = try testing.environ.createMap(arena);
    try env.put(expect_mutant_env, "7");

    const right = try selfRun(arena, &.{ "--mutant", "7", "--filter", mutant_probe }, &env);
    errdefer std.debug.print("{s}\n", .{right.stderr});
    try testing.expectEqual(@as(?u8, 0), exitCode(right.term));
    try testing.expect(std.mem.indexOf(u8, right.stderr, "1/1 tests passed") != null);

    const wrong = try selfRun(arena, &.{ "--mutant", "8", "--filter", mutant_probe }, &env);
    try testing.expectEqual(@as(?u8, 1), exitCode(wrong.term));
    const none = try selfRun(arena, &.{ "--filter", mutant_probe }, &env);
    try testing.expectEqual(@as(?u8, 1), exitCode(none.term));
}

const log_probe_env = "EMETGATE_LOG_PROBE";
const log_probe = "runner: a probe logs an error only when asked to";

test "runner: a probe logs an error only when asked to" {
    const asked = testing.environ.getAlloc(testing.allocator, log_probe_env) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return,
        else => return err,
    };
    testing.allocator.free(asked);
    std.log.err("the log probe was asked to log an error", .{});
}

test "runner: a test that logs an error fails even when it returns normally" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env = try testing.environ.createMap(arena);
    try env.put(log_probe_env, "1");
    const result = try selfRun(arena, &.{ "--filter", log_probe }, &env);
    try testing.expectEqual(@as(?u8, 1), exitCode(result.term));
    try testing.expect(std.mem.indexOf(u8, result.stderr, "' failed: logged an error") != null);
}

const slow_probe = "runner: a probe marked slow runs only under --slow";

test "runner: a probe marked slow runs only under --slow" {
    try test_util.slow();
    try testing.expect(runner.emetgate_slow);
}

test "runner: a slow test is skipped unless --slow is given, and runs when it is" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const normal = try selfRun(arena, &.{ "--filter", slow_probe }, null);
    try testing.expectEqual(@as(?u8, 0), exitCode(normal.term));
    try testing.expect(std.mem.indexOf(u8, normal.stderr, "0/1 tests passed; 1 skipped; 0 failed") != null);
    const slow = try selfRun(arena, &.{ "--slow", "--filter", slow_probe }, null);
    try testing.expectEqual(@as(?u8, 0), exitCode(slow.term));
    try testing.expect(std.mem.indexOf(u8, slow.stderr, "1/1 tests passed; 0 skipped; 0 failed") != null);
    const sharded = try selfRun(arena, &.{ "--jobs", "2", "--slow", "--filter", slow_probe }, null);
    try testing.expectEqual(@as(?u8, 0), exitCode(sharded.term));
    try testing.expect(std.mem.indexOf(u8, sharded.stderr, "1/1 tests passed; 0 skipped; 0 failed") != null);
}

test "shards: every selected test runs in exactly one shard" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings(runner.shard_guard, "shards: every selected test runs in exactly one shard");
    const names = try arena.alloc([]const u8, builtin.test_functions.len);
    for (builtin.test_functions, names) |t, *name| name.* = t.name;
    for (1..6) |count| {
        var recorded: std.ArrayList(usize) = .empty;
        for (1..count + 1) |index| {
            const part = try runner.select(arena, names, &.{}, .{ .index = index, .count = count });
            try recorded.appendSlice(arena, part.indices);
        }
        try testing.expectEqual(runner.Coverage{}, try runner.coverage(arena, names, &.{}, recorded.items));
    }
}

test "runner: a skipped name leaves the selection and --jobs passes it to every shard" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const kept = try runner.withoutSkipped(arena, &sample, &.{ "b.test.three", "c.test.six" });
    const picked = try runner.select(arena, kept, &.{}, .{});
    try testing.expectEqual(@as(usize, 5), picked.matched);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 3, 4, 6 }, picked.indices);

    const skipped = "tests.test_runner_harness.test.runner: a filter keeps a test whose name contains any of its strings";
    for ([_][]const u8{ "1", "2" }) |jobs| {
        const result = try selfRun(arena, &.{ "--jobs", jobs, "--filter", "runner: a shard parses", "--filter", "runner: a filter keeps", "--skip", skipped }, null);
        try testing.expectEqual(@as(?u8, 0), exitCode(result.term));
        try testing.expect(std.mem.indexOf(u8, result.stderr, "1/1 tests passed; 0 skipped; 0 failed") != null);
    }
    const nothing_left = try selfRun(arena, &.{ "--filter", "runner: a filter keeps", "--skip", skipped }, null);
    try testing.expectEqual(@as(?u8, 2), exitCode(nothing_left.term));
}
