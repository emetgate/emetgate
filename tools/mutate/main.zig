const std = @import("std");
const core = @import("core.zig");

const Allocator = std.mem.Allocator;

const spec_path = "tests/mutations.json";
const work_dir = ".zig-cache/mutate";
const report_path = work_dir ++ "/report.json";
const max_output = 16 * 1024 * 1024;
const default_timeout_s: u64 = 900;

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
    note: ?[]const u8 = null,
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
};

const Options = struct {
    include_e2e: bool = false,
    full: bool = false,
    list_only: bool = false,
    timeout_s: u64 = default_timeout_s,
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
        std.debug.print("restored {s} left mutated by an interrupted run\n", .{restored});
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

    var outcomes: std.ArrayList(Outcome) = .empty;
    var failures: usize = 0;
    var skipped_e2e: usize = 0;
    for (spec.mutations) |m| {
        if (selected.items.len != 0 and !contains(selected.items, m.id)) continue;
        const kind = kindOf(m.expect) orelse {
            std.debug.print("{s}: unknown expect \"{s}\"\n", .{ m.id, m.expect });
            return 2;
        };
        if (kind == .e2e and !options.include_e2e and selected.items.len == 0) {
            skipped_e2e += 1;
            continue;
        }
        if (options.list_only) {
            std.debug.print("{s}  {s}  expect={s} status={s}\n", .{ m.id, m.file, m.expect, m.expect_status });
            continue;
        }
        std.debug.print("running {s} on {s} ...\n", .{ m.id, m.file });
        const outcome = try runOne(arena, io, cwd, journal, m, kind, options);
        printOutcome(outcome);
        if (!outcome.ok) failures += 1;
        try outcomes.append(arena, outcome);
    }
    if (options.list_only) return 0;

    var report: std.Io.Writer.Allocating = .init(arena);
    var js: std.json.Stringify = .{ .writer = &report.writer };
    try js.write(outcomes.items);
    try cwd.writeFile(io, .{ .sub_path = report_path, .data = report.written() });

    std.debug.print("\n{d} mutation(s) run, {d} as expected, {d} not as expected", .{ outcomes.items.len, outcomes.items.len - failures, failures });
    if (skipped_e2e != 0) std.debug.print(", {d} e2e mutation(s) skipped (pass --e2e)", .{skipped_e2e});
    std.debug.print("\nreport: {s}\n", .{report_path});
    return if (failures == 0) 0 else 1;
}

fn usage() u8 {
    std.debug.print("usage: synapse-mutate [--e2e] [--full] [--list] [--timeout-s=N] [id...]\n", .{});
    return 2;
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

fn runOne(arena: Allocator, io: std.Io, cwd: std.Io.Dir, journal: core.Journal, m: Mutation, kind: core.Kind, options: Options) !Outcome {
    var outcome: Outcome = .{
        .id = m.id,
        .file = m.file,
        .expect = m.expect,
        .expected_status = m.expect_status,
        .status = "refused",
        .ok = false,
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

    try journal.record(m.file, original);
    errdefer restore(arena, io, cwd, journal, m.file, original) catch {};
    try cwd.writeFile(io, .{ .sub_path = m.file, .data = mutated });

    const started = std.Io.Timestamp.now(io, .awake);
    const run = runBuild(arena, io, kind, m, options);
    try restore(arena, io, cwd, journal, m.file, original);
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
    var argv: std.ArrayList([]const u8) = .empty;
    const step = if (kind == .unit) "test" else "e2e-lockdown";
    try argv.appendSlice(arena, &.{ "zig", "build", step, "--summary", "all" });
    if (kind == .unit and !options.full) {
        const filters = if (m.filter.len != 0) m.filter else m.kills;
        for (filters) |f| try argv.append(arena, try std.fmt.allocPrint(arena, "-Dtest-filter={s}", .{f}));
    }
    return std.process.run(arena, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = .{ .duration = .{
            .raw = .{ .nanoseconds = @as(i96, options.timeout_s) * std.time.ns_per_s },
            .clock = .awake,
        } },
    });
}

fn restore(arena: Allocator, io: std.Io, cwd: std.Io.Dir, journal: core.Journal, path: []const u8, original: []const u8) !void {
    try cwd.writeFile(io, .{ .sub_path = path, .data = original });
    const back = try cwd.readFileAlloc(io, path, arena, .limited(core.max_source_bytes));
    if (!std.mem.eql(u8, back, original)) return error.RestoreMismatch;
    journal.clear();
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
