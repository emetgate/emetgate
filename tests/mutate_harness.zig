const std = @import("std");
const builtin = @import("builtin");
const core = @import("../tools/mutate/core.zig");
const job = @import("../tools/mutate/job.zig");
const zig_source = @import("zig_source.zig");

const test_util = @import("emetgate").test_util;
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

test "harness: a filter that matches no test is no_tests, not a kill or an error" {
    const output = "error: no test matches the filter(s): \"gone\"\nerror: the following build command failed with exit code 1:\n";
    try testing.expectEqual(core.Status.no_tests, core.classify(.unit, 1, output));
    try testing.expectEqual(core.Status.no_tests, core.classify(.unit, 2, "error: no test matches the filter(s): \"gone\"\n"));
}

test "harness: a failed test line is a kill even when the run exits 0" {
    const output = "error: 'tests.symbol.test.refs round-trip' failed: TestUnexpectedResult\n1/2 tests passed; 0 skipped; 1 failed; 0 leaked; mutant 0; shard 1/1\n";
    try testing.expectEqual(core.Status.killed, core.classify(.unit, 0, output));
    try testing.expectEqual(core.Status.survived, core.classify(.unit, 0, "2/2 tests passed; 0 skipped; 0 failed; 0 leaked; mutant 0; shard 1/1\n"));
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
    try test_util.slow();
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

    try mirror.writeFile(testing.io, .{ .sub_path = "src/target.zig", .data = "0riginal" });
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
