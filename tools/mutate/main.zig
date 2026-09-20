const std = @import("std");
const core = @import("core.zig");
const job = @import("job.zig");

const Allocator = std.mem.Allocator;

const spec_path = "tests/mutations.json";
const work_dir = ".zig-cache/mutate";
const report_path = work_dir ++ "/report.json";
const max_output = 16 * 1024 * 1024;
const default_timeout_s: u64 = 900;
const default_pool_size: usize = 16;

const Mutation = struct {
    id: []const u8,
    file: []const u8,
    from: []const u8,
    to: []const u8,
    expect: []const u8 = "test",
    expect_status: []const u8 = "killed",
    kills: []const []const u8 = &.{},
    filter: []const []const u8 = &.{},
    all: bool = false,
    exact: bool = false,
    optimize: ?[]const u8 = null,
    note: ?[]const u8 = null,
    timeout_s: ?u64 = null,
};

const Spec = struct { mutations: []const Mutation };

const Outcome = struct {
    id: []const u8,
    file: []const u8,
    expect: []const u8,
    expected_status: []const u8,
    status: []const u8,
    ok: bool,
    seconds: u64 = 0,
    failed_tests: []const []const u8 = &.{},
    missing_kill: ?[]const u8 = null,
    unexpected_kill: ?[]const u8 = null,
    detail: ?[]const u8 = null,
    origin: []const u8 = "single",
    pool: ?[]const u8 = null,
    pooled_status: ?[]const u8 = null,
    pooled_origin: ?[]const u8 = null,
    pooled_pool: ?[]const u8 = null,
};

const Options = struct {
    include_e2e: bool = false,
    full: bool = false,
    list_only: bool = false,
    skip_survivors: bool = false,
    pool: bool = false,
    shadow: bool = false,
    pool_size: usize = default_pool_size,
    timeout_s: u64 = default_timeout_s,
};

const Selected = struct {
    m: Mutation,
    kind: core.Kind,
};

const Run = struct {
    outcomes: []const Outcome,
    failures: usize,
    pools: usize = 0,
    inconclusive: usize = 0,
    splits: usize = 0,
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var options: Options = .{};
    var selected: std.ArrayList([]const u8) = .empty;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--e2e")) {
            options.include_e2e = true;
        } else if (std.mem.eql(u8, arg, "--full")) {
            options.full = true;
        } else if (std.mem.eql(u8, arg, "--list")) {
            options.list_only = true;
        } else if (std.mem.eql(u8, arg, "--skip-survivors")) {
            options.skip_survivors = true;
        } else if (std.mem.eql(u8, arg, "--pool")) {
            options.pool = true;
        } else if (std.mem.eql(u8, arg, "--shadow")) {
            options.shadow = true;
        } else if (std.mem.startsWith(u8, arg, "--pool-size=")) {
            options.pool_size = std.fmt.parseInt(usize, arg["--pool-size=".len..], 10) catch return usage();
            if (options.pool_size == 0 or options.pool_size > core.max_pool_members) return usage();
        } else if (std.mem.startsWith(u8, arg, "--timeout-s=")) {
            options.timeout_s = std.fmt.parseInt(u64, arg["--timeout-s=".len..], 10) catch return usage();
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return usage();
        } else {
            try selected.append(arena, arg);
        }
    }

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, work_dir);
    const lock = cwd.createFile(io, work_dir ++ "/lock", .{ .lock = .exclusive, .lock_nonblocking = true }) catch |err| switch (err) {
        error.WouldBlock => {
            std.debug.print("another mutation run holds {s}/lock\n", .{work_dir});
            return 3;
        },
        else => return err,
    };
    defer lock.close(io);

    var journal_dir = try cwd.openDir(io, work_dir, .{});
    defer journal_dir.close(io);
    const journal: core.Journal = .{ .dir = journal_dir, .io = io };
    if (try journal.recover(arena, cwd)) |restored| {
        for (restored) |path| std.debug.print("restored {s} left mutated by an interrupted run\n", .{path});
    }

    const spec_bytes = try cwd.readFileAlloc(io, spec_path, arena, .limited(1024 * 1024));
    const spec = try std.json.parseFromSliceLeaky(Spec, arena, spec_bytes, .{});

    for (selected.items) |id| {
        for (spec.mutations) |m| {
            if (std.mem.eql(u8, m.id, id)) break;
        } else {
            std.debug.print("unknown mutation id: {s}\n", .{id});
            return 2;
        }
    }

    var chosen: std.ArrayList(Selected) = .empty;
    var skipped_e2e: usize = 0;
    var skipped_survivors: usize = 0;
    for (spec.mutations) |m| {
        if (selected.items.len != 0 and !contains(selected.items, m.id)) continue;
        const kind = kindOf(m.expect) orelse {
            std.debug.print("{s}: unknown expect \"{s}\"\n", .{ m.id, m.expect });
            return 2;
        };
        if (core.skipReason(kind, m.expect_status, selected.items.len != 0, options.include_e2e, options.skip_survivors)) |reason| {
            switch (reason) {
                .e2e => skipped_e2e += 1,
                .survivor => skipped_survivors += 1,
            }
            continue;
        }
        if (options.list_only) {
            std.debug.print("{s}  {s}  expect={s} status={s}\n", .{ m.id, m.file, m.expect, m.expect_status });
            continue;
        }
        try chosen.append(arena, .{ .m = m, .kind = kind });
    }
    if (options.list_only) return 0;

    var shadow_mismatch: usize = 0;
    const run = if (options.pool or options.shadow) pooled: {
        const pooled = try runPooled(arena, io, cwd, journal, chosen.items, options) orelse return 4;
        std.debug.print("\npools: {d}, inconclusive: {d}, splits: {d}\n", .{ pooled.pools, pooled.inconclusive, pooled.splits });
        if (!options.shadow) break :pooled pooled;
        std.debug.print("\nshadow: running the same corpus one at a time\n", .{});
        const serial = try runSerial(arena, io, cwd, journal, chosen.items, options);
        shadow_mismatch = reportShadow(pooled.outcomes, serial.outcomes);
        const merged: Run = .{
            .outcomes = try withShadow(arena, serial.outcomes, pooled.outcomes),
            .failures = serial.failures,
            .pools = pooled.pools,
            .inconclusive = pooled.inconclusive,
            .splits = pooled.splits,
        };
        break :pooled merged;
    } else try runSerial(arena, io, cwd, journal, chosen.items, options);

    var report: std.Io.Writer.Allocating = .init(arena);
    var js: std.json.Stringify = .{ .writer = &report.writer };
    try js.write(run.outcomes);
    try cwd.writeFile(io, .{ .sub_path = report_path, .data = report.written() });

    var summary: std.Io.Writer.Allocating = .init(arena);
    try core.writeSummary(&summary.writer, run.outcomes.len, run.failures, skipped_e2e, skipped_survivors);
    std.debug.print("\n{s}\nreport: {s}\n", .{ summary.written(), report_path });
    if (shadow_mismatch != 0) return 5;
    return if (run.failures == 0) 0 else 1;
}

fn usage() u8 {
    std.debug.print("usage: emetgate-mutate [--e2e] [--full] [--list] [--skip-survivors] [--pool] [--pool-size=N] [--shadow] [--timeout-s=N] [id...]\n", .{});
    return 2;
}

fn runSerial(arena: Allocator, io: std.Io, cwd: std.Io.Dir, journal: core.Journal, chosen: []const Selected, options: Options) !Run {
    var outcomes: std.ArrayList(Outcome) = .empty;
    var failures: usize = 0;
    for (chosen) |entry| {
        std.debug.print("running {s} on {s} ...\n", .{ entry.m.id, entry.m.file });
        const outcome = try runOne(arena, io, cwd, journal, entry.m, entry.kind, options, "single", null);
        printOutcome(outcome);
        if (!outcome.ok) failures += 1;
        try outcomes.append(arena, outcome);
    }
    return .{ .outcomes = try outcomes.toOwnedSlice(arena), .failures = failures };
}

fn runPooled(arena: Allocator, io: std.Io, cwd: std.Io.Dir, journal: core.Journal, chosen: []const Selected, options: Options) !?Run {
    var candidates: std.ArrayList(core.Candidate) = .empty;
    for (chosen, 0..) |entry, i| {
        const m = entry.m;
        if (!core.poolable(entry.kind, m.expect_status, m.timeout_s != null, m.optimize != null, m.kills.len)) continue;
        try candidates.append(arena, .{
            .index = i,
            .file = m.file,
            .kills = m.kills,
            .filter = m.filter,
            .from = m.from,
            .to = m.to,
            .all = m.all,
        });
    }
    const sources = try readSources(arena, io, cwd, candidates.items);
    const pools = try core.buildPools(arena, candidates.items, options.pool_size, sources);

    if (pools.len != 0 and !try baselineIsGreen(arena, io, pools, options)) return null;

    const slots = try arena.alloc(?Outcome, chosen.len);
    @memset(slots, null);
    var state: PoolState = .{};
    var queue: std.ArrayList([]const core.Candidate) = .empty;
    try queue.appendSlice(arena, pools);
    state.pools = pools.len;
    var at: usize = 0;
    while (at < queue.items.len) : (at += 1) {
        const pool = queue.items[at];
        const label = try std.fmt.allocPrint(arena, "pool-{d}", .{at + 1});
        if (try runPool(arena, io, cwd, journal, chosen, pool, options, slots, &state, label)) {
            state.splits += 1;
            const cut = core.splitAt(pool);
            try queue.append(arena, pool[0..cut]);
            try queue.append(arena, pool[cut..]);
        }
    }

    var outcomes: std.ArrayList(Outcome) = .empty;
    var failures: usize = 0;
    for (chosen, 0..) |entry, i| {
        const outcome = slots[i] orelse blk: {
            std.debug.print("running {s} on {s} ...\n", .{ entry.m.id, entry.m.file });
            const single = try runOne(arena, io, cwd, journal, entry.m, entry.kind, options, "single", null);
            printOutcome(single);
            break :blk single;
        };
        if (!outcome.ok) failures += 1;
        try outcomes.append(arena, outcome);
    }
    return .{
        .outcomes = try outcomes.toOwnedSlice(arena),
        .failures = failures,
        .pools = state.pools,
        .inconclusive = state.inconclusive,
        .splits = state.splits,
    };
}

const PoolState = struct {
    pools: usize = 0,
    inconclusive: usize = 0,
    splits: usize = 0,
};

fn runPool(
    arena: Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    journal: core.Journal,
    chosen: []const Selected,
    pool: []const core.Candidate,
    options: Options,
    slots: []?Outcome,
    state: *PoolState,
    label: []const u8,
) !bool {
    if (pool.len == 1) {
        const entry = chosen[pool[0].index];
        std.debug.print("running {s} on {s} (bisected from {s}) ...\n", .{ entry.m.id, entry.m.file, label });
        const outcome = try runOne(arena, io, cwd, journal, entry.m, entry.kind, options, "bisected", label);
        printOutcome(outcome);
        slots[pool[0].index] = outcome;
        return false;
    }

    const modules = core.modulesIn(pool);
    std.debug.print("running {s} with {d} mutation(s) in {d} module(s) ...\n", .{ label, pool.len, modules });
    const expected = try core.unionNames(arena, pool, "kills");
    const filters = try core.poolFilter(arena, pool);

    var backups: std.ArrayList(core.Backup) = .empty;
    var working: std.ArrayList([]const u8) = .empty;
    for (pool) |member| {
        const m = chosen[member.index].m;
        for (backups.items) |seen| {
            if (std.mem.eql(u8, seen.path, m.file)) break;
        } else {
            if (!try knownToGitAndClean(arena, io, m.file)) {
                std.debug.print("{s}: {s} is not known to git or has uncommitted changes\n", .{ label, m.file });
                return error.DirtyTree;
            }
            const original = try cwd.readFileAlloc(io, m.file, arena, .limited(core.max_source_bytes));
            try backups.append(arena, .{ .path = m.file, .original = original });
            try working.append(arena, original);
        }
    }

    for (pool) |member| {
        const m = chosen[member.index].m;
        const at = indexOfPath(backups.items, m.file).?;
        const text = core.applyMutation(arena, working.items[at], m.from, m.to, m.all) catch {
            state.inconclusive += 1;
            std.debug.print("{s}: {s} did not apply, splitting\n", .{ label, m.id });
            return true;
        };
        working.items[at] = text;
    }

    try journal.record(arena, backups.items);
    errdefer restoreAll(arena, io, cwd, journal, backups.items) catch {};
    for (backups.items, working.items) |backup, text| {
        try cwd.writeFile(io, .{ .sub_path = backup.path, .data = text });
    }

    const started = std.Io.Timestamp.now(io, .awake);
    const result = runFiltered(arena, io, filters, null, options);
    try restoreAll(arena, io, cwd, journal, backups.items);
    const elapsed_ns: i96 = started.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
    const seconds: u64 = @intCast(@divTrunc(elapsed_ns, std.time.ns_per_s));

    const verdict = verdictOf(arena, result, expected) catch |err| switch (err) {
        error.Timeout => core.PoolVerdict.inconclusive,
        else => return err,
    };
    if (verdict == .inconclusive) {
        state.inconclusive += 1;
        std.debug.print("{s} inconclusive after {d}s, splitting\n", .{ label, seconds });
        return true;
    }

    std.debug.print("{s} killed {d} mutation(s) in {d}s\n", .{ label, pool.len, seconds });
    for (pool) |member| {
        const entry = chosen[member.index];
        slots[member.index] = .{
            .id = entry.m.id,
            .file = entry.m.file,
            .expect = entry.m.expect,
            .expected_status = entry.m.expect_status,
            .status = "killed",
            .ok = true,
            .seconds = seconds,
            .failed_tests = member.kills,
            .origin = "pooled",
            .pool = label,
        };
    }
    return false;
}

fn verdictOf(arena: Allocator, run: anyerror!std.process.RunResult, expected: []const []const u8) !core.PoolVerdict {
    const result = try run;
    const output = try std.mem.concat(arena, u8, &.{ result.stdout, result.stderr });
    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => 255,
    };
    const failed = try core.failedTests(arena, output);
    return core.poolVerdict(core.classify(.unit, code, output), failed, expected);
}

fn baselineIsGreen(arena: Allocator, io: std.Io, pools: []const []const core.Candidate, options: Options) !bool {
    var all: std.ArrayList(core.Candidate) = .empty;
    for (pools) |pool| try all.appendSlice(arena, pool);
    const filters = try core.poolFilter(arena, all.items);
    std.debug.print("baseline: {d} filter(s) on the unmutated tree ...\n", .{filters.len});
    const result = runFiltered(arena, io, filters, null, options) catch |err| {
        std.debug.print("baseline did not finish: {s}\n", .{@errorName(err)});
        return false;
    };
    const output = try std.mem.concat(arena, u8, &.{ result.stdout, result.stderr });
    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => 255,
    };
    if (!core.baselineIsGreen(code, output)) {
        std.debug.print("baseline is not green, stopping\n{s}\n", .{firstErrorLine(output) orelse "no error line"});
        return false;
    }
    std.debug.print("baseline is green\n", .{});
    return true;
}

fn indexOfPath(backups: []const core.Backup, path: []const u8) ?usize {
    for (backups, 0..) |backup, i| {
        if (std.mem.eql(u8, backup.path, path)) return i;
    }
    return null;
}

fn readSources(arena: Allocator, io: std.Io, cwd: std.Io.Dir, candidates: []const core.Candidate) ![]const core.Source {
    var sources: std.ArrayList(core.Source) = .empty;
    for (candidates) |c| {
        for (sources.items) |seen| {
            if (std.mem.eql(u8, seen.file, c.file)) break;
        } else {
            const text = try cwd.readFileAlloc(io, c.file, arena, .limited(core.max_source_bytes));
            try sources.append(arena, .{ .file = c.file, .text = text });
        }
    }
    return sources.toOwnedSlice(arena);
}

fn restoreAll(arena: Allocator, io: std.Io, cwd: std.Io.Dir, journal: core.Journal, backups: []const core.Backup) !void {
    for (backups) |backup| {
        try cwd.writeFile(io, .{ .sub_path = backup.path, .data = backup.original });
        const back = try cwd.readFileAlloc(io, backup.path, arena, .limited(core.max_source_bytes));
        if (!std.mem.eql(u8, back, backup.original)) return error.RestoreMismatch;
    }
    journal.clear();
}

fn withShadow(arena: Allocator, serial: []const Outcome, pooled: []const Outcome) ![]const Outcome {
    const merged = try arena.dupe(Outcome, serial);
    for (merged, pooled) |*outcome, shadow| {
        outcome.pooled_status = shadow.status;
        outcome.pooled_origin = shadow.origin;
        outcome.pooled_pool = shadow.pool;
    }
    return merged;
}

fn reportShadow(pooled: []const Outcome, serial: []const Outcome) usize {
    var mismatch: usize = 0;
    for (pooled, serial) |a, b| {
        if (std.mem.eql(u8, a.status, b.status) and a.ok == b.ok) continue;
        mismatch += 1;
        std.debug.print("shadow mismatch {s}: pooled={s} (ok={}) serial={s} (ok={})\n", .{ a.id, a.status, a.ok, b.status, b.ok });
    }
    if (mismatch == 0) {
        std.debug.print("shadow: {d} mutation(s) agree\n", .{pooled.len});
    } else {
        std.debug.print("shadow: {d} mutation(s) disagree\n", .{mismatch});
    }
    return mismatch;
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |entry| {
        if (std.mem.eql(u8, entry, item)) return true;
    }
    return false;
}

fn kindOf(expect: []const u8) ?core.Kind {
    if (std.mem.eql(u8, expect, "test")) return .unit;
    if (std.mem.eql(u8, expect, "e2e-lockdown")) return .e2e;
    return null;
}

fn runOne(arena: Allocator, io: std.Io, cwd: std.Io.Dir, journal: core.Journal, m: Mutation, kind: core.Kind, options: Options, origin: []const u8, pool: ?[]const u8) !Outcome {
    var outcome: Outcome = .{
        .id = m.id,
        .file = m.file,
        .expect = m.expect,
        .expected_status = m.expect_status,
        .status = "refused",
        .ok = false,
        .origin = origin,
        .pool = pool,
    };
    if (!try knownToGitAndClean(arena, io, m.file)) {
        outcome.detail = "file is not known to git or has uncommitted changes";
        return outcome;
    }
    const original = try cwd.readFileAlloc(io, m.file, arena, .limited(core.max_source_bytes));
    const mutated = core.applyMutation(arena, original, m.from, m.to, m.all) catch |err| {
        outcome.status = "bad_pattern";
        outcome.detail = @errorName(err);
        return outcome;
    };

    const backups = [_]core.Backup{.{ .path = m.file, .original = original }};
    try journal.record(arena, &backups);
    errdefer restoreAll(arena, io, cwd, journal, &backups) catch {};
    try cwd.writeFile(io, .{ .sub_path = m.file, .data = mutated });

    const started = std.Io.Timestamp.now(io, .awake);
    const run = runBuild(arena, io, kind, m, options);
    try restoreAll(arena, io, cwd, journal, &backups);
    const elapsed_ns: i96 = started.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
    outcome.seconds = @intCast(@divTrunc(elapsed_ns, std.time.ns_per_s));

    const result = run catch |err| switch (err) {
        error.Timeout => {
            outcome.status = "timeout";
            outcome.ok = std.mem.eql(u8, m.expect_status, "timeout");
            return outcome;
        },
        else => return err,
    };
    const output = try std.mem.concat(arena, u8, &.{ result.stdout, result.stderr });
    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => 255,
    };
    const status = core.classify(kind, code, output);
    outcome.status = @tagName(status);
    outcome.failed_tests = try core.failedTests(arena, output);
    outcome.ok = std.mem.eql(u8, outcome.status, m.expect_status);
    if (outcome.ok and status == .killed and kind == .unit) {
        if (core.missingKill(outcome.failed_tests, m.kills)) |missing| {
            outcome.ok = false;
            outcome.missing_kill = missing;
        }
    }
    if (outcome.ok and status == .killed and kind == .unit and m.exact) {
        if (core.unexpectedKill(outcome.failed_tests, m.kills)) |extra| {
            outcome.ok = false;
            outcome.unexpected_kill = extra;
        }
    }
    if (!outcome.ok and (status == .other_error or status == .compile_error)) outcome.detail = firstErrorLine(output);
    return outcome;
}

fn runBuild(arena: Allocator, io: std.Io, kind: core.Kind, m: Mutation, options: Options) !std.process.RunResult {
    if (kind == .e2e) {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ "zig", "build", "e2e-lockdown", "--summary", "all" });
        if (m.optimize) |mode| try argv.append(arena, try std.fmt.allocPrint(arena, "-Doptimize={s}", .{mode}));
        return job.run(arena, io, argv.items, max_output, core.timeoutFor(m.timeout_s, options.timeout_s));
    }
    const filters = if (options.full) &.{} else if (m.filter.len != 0) m.filter else m.kills;
    return runFiltered(arena, io, filters, m.optimize, .{
        .full = options.full,
        .timeout_s = core.timeoutFor(m.timeout_s, options.timeout_s),
    });
}

fn runFiltered(arena: Allocator, io: std.Io, filters: []const []const u8, optimize: ?[]const u8, options: Options) !std.process.RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "zig", "build", "test", "--summary", "all" });
    if (optimize) |mode| try argv.append(arena, try std.fmt.allocPrint(arena, "-Doptimize={s}", .{mode}));
    if (!options.full) {
        for (filters) |f| try argv.append(arena, try std.fmt.allocPrint(arena, "-Dtest-filter={s}", .{f}));
    }
    return job.run(arena, io, argv.items, max_output, options.timeout_s);
}

fn knownToGitAndClean(arena: Allocator, io: std.Io, path: []const u8) !bool {
    const listed = try std.process.run(arena, io, .{ .argv = &.{ "git", "ls-files", "--error-unmatch", "--", path } });
    if (!exitedZero(listed.term)) return false;
    const diff = try std.process.run(arena, io, .{ .argv = &.{ "git", "diff", "--quiet", "--", path } });
    return exitedZero(diff.term);
}

fn exitedZero(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn firstErrorLine(output: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (std.mem.indexOf(u8, line, "error:") != null) return line;
    }
    return null;
}

fn printOutcome(o: Outcome) void {
    const verdict = if (o.ok) "ok  " else "FAIL";
    std.debug.print("{s} {s}  {s}  expect={s}  status={s} (wanted {s})  {d}s\n", .{ verdict, o.id, o.file, o.expect, o.status, o.expected_status, o.seconds });
    for (o.failed_tests) |name| std.debug.print("       failed: {s}\n", .{name});
    if (o.missing_kill) |name| std.debug.print("       expected to fail but did not: {s}\n", .{name});
    if (o.unexpected_kill) |name| std.debug.print("       failed but was not expected to: {s}\n", .{name});
    if (o.detail) |detail| std.debug.print("       {s}\n", .{detail});
}
