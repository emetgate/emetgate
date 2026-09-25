const std = @import("std");
const core = @import("core.zig");
const job = @import("job.zig");
const schema = @import("schema.zig");
const changes = @import("changes.zig");

const Allocator = std.mem.Allocator;

const spec_path = "tests/mutations.json";
const work_dir = ".zig-cache/mutate";
const report_path = work_dir ++ "/report.json";
const tree_dir = work_dir ++ "/tree";
const tree_list = work_dir ++ "/tree.list";
const schema_dir = work_dir ++ "/schema";
const max_output = 16 * 1024 * 1024;
const default_timeout_s: u64 = 900;
const max_resumes = 32;

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
    schema_refusal: ?[]const u8 = null,
};

const Options = struct {
    include_e2e: bool = false,
    full: bool = false,
    list_only: bool = false,
    skip_survivors: bool = false,
    timeout_s: u64 = default_timeout_s,
    jobs: ?usize = null,
    single: bool = false,
    compare: bool = false,
    changed_since: ?[]const u8 = null,
    slice: ?[2]usize = null,
};

const Selected = struct {
    m: Mutation,
    kind: core.Kind,
};

const Run = struct {
    outcomes: []const Outcome,
    failures: usize,
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var options: Options = .{};
    var selected: std.ArrayList([]const u8) = .empty;
    var expect_ref = false;
    for (args[1..]) |arg| {
        if (expect_ref) {
            options.changed_since = arg;
            expect_ref = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--e2e")) {
            options.include_e2e = true;
        } else if (std.mem.eql(u8, arg, "--full")) {
            options.full = true;
        } else if (std.mem.eql(u8, arg, "--list")) {
            options.list_only = true;
        } else if (std.mem.eql(u8, arg, "--skip-survivors")) {
            options.skip_survivors = true;
        } else if (std.mem.eql(u8, arg, "--single")) {
            options.single = true;
        } else if (std.mem.eql(u8, arg, "--compare")) {
            options.compare = true;
        } else if (std.mem.eql(u8, arg, "--changed-since")) {
            expect_ref = true;
        } else if (std.mem.startsWith(u8, arg, "--slice=")) {
            const text = arg["--slice=".len..];
            const slash = std.mem.indexOfScalar(u8, text, '/') orelse return usage();
            const i = std.fmt.parseInt(usize, text[0..slash], 10) catch return usage();
            const n = std.fmt.parseInt(usize, text[slash + 1 ..], 10) catch return usage();
            if (n == 0 or i == 0 or i > n) return usage();
            options.slice = .{ i, n };
        } else if (std.mem.startsWith(u8, arg, "--changed-since=")) {
            options.changed_since = arg["--changed-since=".len..];
        } else if (std.mem.startsWith(u8, arg, "--jobs=")) {
            options.jobs = std.fmt.parseInt(usize, arg["--jobs=".len..], 10) catch return usage();
            if (options.jobs.? == 0) return usage();
        } else if (std.mem.startsWith(u8, arg, "--timeout-s=")) {
            options.timeout_s = std.fmt.parseInt(u64, arg["--timeout-s=".len..], 10) catch return usage();
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return usage();
        } else {
            try selected.append(arena, arg);
        }
    }

    if (expect_ref) return usage();
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

    var work = try cwd.openDir(io, work_dir, .{});
    defer work.close(io);
    if (try core.abandonLegacyRecord(arena, io, work)) |named| {
        for (named) |path| std.debug.print("ignored a recovery record for {s} left by an older emetgate-mutate; the working tree was not touched\n", .{path});
    }
    const tree = try prepareTree(arena, io, cwd);
    defer tree.close(io);

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

    const changed: ?[]const []const u8 = if (options.changed_since) |ref| try changedMutations(arena, io, cwd, ref, spec) else null;

    var chosen: std.ArrayList(Selected) = .empty;
    var skipped_e2e: usize = 0;
    var skipped_survivors: usize = 0;
    for (spec.mutations, 0..) |m, ordinal| {
        if (selected.items.len != 0 and !contains(selected.items, m.id)) continue;
        if (changed) |ids| if (!contains(ids, m.id)) continue;
        if (options.slice) |slice| if (ordinal % slice[1] != slice[0] - 1) continue;
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

    var compare_mismatch: usize = 0;
    const run = if (options.single) try runSerial(arena, io, tree, chosen.items, options) else schemata: {
        var stats: SchemaStats = .{};
        const schemata = try runSchemata(arena, io, tree, chosen.items, options, &stats) orelse return 4;
        printSchemaStats(stats, schemata.outcomes.len);
        if (options.compare) compare_mismatch = try compareWithSingle(arena, io, tree, chosen.items, schemata, options);
        break :schemata schemata;
    };

    var report: std.Io.Writer.Allocating = .init(arena);
    var js: std.json.Stringify = .{ .writer = &report.writer };
    try js.write(run.outcomes);
    try cwd.writeFile(io, .{ .sub_path = report_path, .data = report.written() });

    var summary: std.Io.Writer.Allocating = .init(arena);
    try core.writeSummary(&summary.writer, run.outcomes.len, run.failures, skipped_e2e, skipped_survivors);
    std.debug.print("\n{s}\nreport: {s}\n", .{ summary.written(), report_path });
    if (compare_mismatch != 0) return 5;
    return if (run.failures == 0) 0 else 1;
}

fn usage() u8 {
    std.debug.print("usage: emetgate-mutate [--e2e] [--full] [--list] [--skip-survivors] [--timeout-s=N] [--jobs=N] [--single] [--compare] [--changed-since REF] [--slice=I/N] [id...]\n", .{});
    return 2;
}

fn runSerial(arena: Allocator, io: std.Io, tree: std.Io.Dir, chosen: []const Selected, options: Options) !Run {
    var outcomes: std.ArrayList(Outcome) = .empty;
    var failures: usize = 0;
    for (chosen) |entry| {
        std.debug.print("running {s} on {s} ...\n", .{ entry.m.id, entry.m.file });
        const outcome = try runOne(arena, io, tree, entry.m, entry.kind, options, "single");
        printOutcome(outcome);
        if (!outcome.ok) failures += 1;
        try outcomes.append(arena, outcome);
    }
    return .{ .outcomes = try outcomes.toOwnedSlice(arena), .failures = failures };
}

fn restoreAll(arena: Allocator, io: std.Io, tree: std.Io.Dir, backups: []const core.Backup) !void {
    for (backups) |backup| {
        try tree.writeFile(io, .{ .sub_path = backup.path, .data = backup.original });
        const back = try tree.readFileAlloc(io, backup.path, arena, .limited(core.max_source_bytes));
        if (!std.mem.eql(u8, back, backup.original)) return error.RestoreMismatch;
    }
}

fn prepareTree(arena: Allocator, io: std.Io, cwd: std.Io.Dir) !std.Io.Dir {
    const listed = try std.process.run(arena, io, .{ .argv = &.{ "git", "ls-files", "-z", "--cached", "--others", "--exclude-standard" } });
    if (!exitedZero(listed.term)) return error.GitListFailed;
    var files: std.ArrayList([]const u8) = .empty;
    var names = std.mem.splitScalar(u8, listed.stdout, 0);
    while (names.next()) |name| {
        if (name.len == 0) continue;
        cwd.access(io, name, .{}) catch continue;
        try files.append(arena, name);
    }
    const previous_text = cwd.readFileAlloc(io, tree_list, arena, .limited(64 * 1024 * 1024)) catch "";
    var previous: std.ArrayList([]const u8) = .empty;
    var old_names = std.mem.splitScalar(u8, previous_text, '\n');
    while (old_names.next()) |name| {
        if (name.len != 0) try previous.append(arena, name);
    }

    try cwd.createDirPath(io, tree_dir);
    const tree = try cwd.openDir(io, tree_dir, .{});
    const written = try core.syncMirror(arena, io, cwd, tree, files.items, previous.items);
    const list = try std.mem.join(arena, "\n", files.items);
    try cwd.writeFile(io, .{ .sub_path = tree_list, .data = list });
    std.debug.print("mirror {s}: {d} file(s), {d} refreshed; mutations run there and never in the working tree\n", .{ tree_dir, files.items.len, written });
    return tree;
}

const Plan = union(enum) {
    schema: schema.Site,
    fallback: schema.Refusal,
};

const SchemaStats = struct {
    in_schema: usize = 0,
    refused: [@typeInfo(schema.Refusal).@"enum".fields.len]usize = @splat(0),
    rounds: usize = 0,
    build_seconds: u64 = 0,
    baseline_seconds: u64 = 0,
    baseline_red: usize = 0,
    run_seconds: u64 = 0,
    single_seconds: u64 = 0,
};

fn isExcluded(file: []const u8) bool {
    for (schema.excluded_files) |excluded| {
        if (std.mem.eql(u8, excluded, file)) return true;
    }
    return false;
}

fn precheck(m: Mutation, kind: core.Kind) ?schema.Refusal {
    if (kind != .unit) return .not_a_test_kill;
    if (!std.mem.endsWith(u8, m.file, ".zig")) return .not_zig;
    if (isExcluded(m.file)) return .excluded_file;
    if (m.optimize != null) return .own_optimize;
    if (std.mem.eql(u8, m.expect_status, "compile_error")) return .expects_compile_error;
    return null;
}

fn planSchemata(arena: Allocator, io: std.Io, tree: std.Io.Dir, chosen: []const Selected) ![]Plan {
    const plans = try arena.alloc(Plan, chosen.len);
    for (chosen, plans) |entry, *plan| {
        plan.* = if (precheck(entry.m, entry.kind)) |why| .{ .fallback = why } else .{ .fallback = .no_hit };
    }
    var done: std.ArrayList([]const u8) = .empty;
    for (chosen, 0..) |entry, i| {
        if (precheck(entry.m, entry.kind) != null) continue;
        if (contains(done.items, entry.m.file)) continue;
        try done.append(arena, entry.m.file);
        if (!try knownToGitAndClean(arena, io, entry.m.file)) continue;
        const original = try tree.readFileAlloc(io, entry.m.file, arena, .limited(core.max_source_bytes));
        var file = try schema.File.parse(arena, original);
        for (chosen[i..], plans[i..]) |other, *plan| {
            if (!std.mem.eql(u8, other.m.file, entry.m.file)) continue;
            if (precheck(other.m, other.kind) != null) continue;
            _ = core.applyMutation(arena, original, other.m.from, other.m.to, other.m.all) catch continue;
            plan.* = switch (try file.locate(arena, other.m.from)) {
                .site => |site| .{ .schema = site },
                .refused => |why| .{ .fallback = why },
            };
        }
    }
    return plans;
}

fn schemaNumber(i: usize) u32 {
    return @intCast(i + 1);
}

fn buildSchema(arena: Allocator, io: std.Io, tree: std.Io.Dir, chosen: []const Selected, plans: []Plan, options: Options, stats: *SchemaStats) !?[]const u8 {
    var files: std.ArrayList([]const u8) = .empty;
    for (chosen, plans) |entry, plan| {
        if (plan == .schema and !contains(files.items, entry.m.file)) try files.append(arena, entry.m.file);
    }
    if (files.items.len == 0) return null;

    var backups: std.ArrayList(core.Backup) = .empty;
    for (files.items) |path| {
        try backups.append(arena, .{ .path = path, .original = try tree.readFileAlloc(io, path, arena, .limited(core.max_source_bytes)) });
    }

    while (true) {
        stats.rounds += 1;
        var transformed: std.ArrayList(schema.Transformed) = .empty;
        var written: std.ArrayList(core.Backup) = .empty;
        errdefer restoreAll(arena, io, tree, backups.items) catch {};
        for (backups.items) |backup| {
            var entries: std.ArrayList(schema.Entry) = .empty;
            for (chosen, plans, 0..) |entry, plan, i| {
                if (plan != .schema or !std.mem.eql(u8, entry.m.file, backup.path)) continue;
                try entries.append(arena, .{ .number = schemaNumber(i), .site = plan.schema, .from = entry.m.from, .to = entry.m.to, .all = entry.m.all });
            }
            if (entries.items.len == 0) {
                try transformed.append(arena, .{ .text = @constCast(backup.original), .regions = &.{} });
                continue;
            }
            const t = try schema.transform(arena, backup.original, entries.items);
            try transformed.append(arena, t);
            try tree.writeFile(io, .{ .sub_path = backup.path, .data = t.text });
            try written.append(arena, backup);
        }

        std.debug.print("schema: building one test binary with {d} mutant(s) in {d} file(s), round {d} ...\n", .{ countSchema(plans), written.items.len, stats.rounds });
        const started = std.Io.Timestamp.now(io, .awake);
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ "zig", "build", "test-bin", "--summary", "none" });
        if (options.jobs) |n| try argv.append(arena, try std.fmt.allocPrint(arena, "-j{d}", .{n}));
        const built = job.run(arena, io, argv.items, tree_dir, max_output, options.timeout_s);
        try restoreAll(arena, io, tree, backups.items);
        stats.build_seconds += secondsSince(io, started);
        const result = try built;
        if (exitedZero(result.term)) break;

        const output = try std.mem.concat(arena, u8, &.{ result.stdout, result.stderr });
        var dropped: std.ArrayList(u32) = .empty;
        var reasons: std.ArrayList([]const u8) = .empty;
        for (try schema.compileErrors(arena, output)) |err| {
            for (backups.items, transformed.items) |backup, t| {
                if (!schema.samePath(err.path, backup.path)) continue;
                const before = dropped.items.len;
                try t.mutantsAt(err.line, &dropped, arena);
                for (dropped.items[before..]) |_| try reasons.append(arena, err.message);
            }
        }
        if (dropped.items.len == 0) {
            std.debug.print("schema: the build failed outside any mutant copy:\n{s}\n", .{firstErrorLine(output) orelse "no error line"});
            return error.SchemaBuildFailed;
        }
        for (dropped.items, reasons.items) |number, why| {
            const i = number - 1;
            std.debug.print("schema: {s} does not compile as a copy ({s}), it runs on its own\n", .{ chosen[i].m.id, why });
            plans[i] = .{ .fallback = .compile_error };
        }
        if (countSchema(plans) == 0) return null;
    }

    try std.Io.Dir.cwd().createDirPath(io, schema_dir);
    const exe_name = if (@import("builtin").os.tag == .windows) "test-all.exe" else "test-all";
    const from_path = try std.fmt.allocPrint(arena, "zig-out/bin/{s}", .{exe_name});
    const to_path = schema_dir ++ "/" ++ exe_name;
    try tree.copyFile(from_path, std.Io.Dir.cwd(), to_path, io, .{});
    return try std.Io.Dir.cwd().realPathFileAlloc(io, to_path, arena);
}

fn countSchema(plans: []const Plan) usize {
    var n: usize = 0;
    for (plans) |plan| {
        if (plan == .schema) n += 1;
    }
    return n;
}

fn secondsSince(io: std.Io, started: std.Io.Timestamp) u64 {
    const ns = started.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
    return @intCast(@divTrunc(@max(ns, 0), std.time.ns_per_s));
}

fn filtersOf(m: Mutation) []const []const u8 {
    return if (m.filter.len != 0) m.filter else m.kills;
}

fn schemaArgv(gpa: Allocator, exe: []const u8, number: u32, filters: []const []const u8, skips: []const []const u8, jobs: ?usize) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(gpa, &.{ exe, "--slow" });
    if (number != 0) {
        try argv.appendSlice(gpa, &.{ "--mutant", try std.fmt.allocPrint(gpa, "{d}", .{number}), "--verbose" });
    }
    if (jobs) |n| try argv.appendSlice(gpa, &.{ "--jobs", try std.fmt.allocPrint(gpa, "{d}", .{n}) });
    for (filters) |f| try argv.appendSlice(gpa, &.{ "--filter", f });
    for (skips) |name| try argv.appendSlice(gpa, &.{ "--skip", name });
    return argv.items;
}

fn schemaBaseline(arena: Allocator, io: std.Io, exe: []const u8, chosen: []const Selected, plans: []const Plan, options: Options) !?[]const []const u8 {
    var filters: std.ArrayList([]const u8) = .empty;
    var everything = false;
    for (chosen, plans) |entry, plan| {
        if (plan != .schema) continue;
        const own = filtersOf(entry.m);
        if (own.len == 0) everything = true;
        for (own) |f| {
            if (!contains(filters.items, f)) try filters.append(arena, f);
        }
    }
    if (everything) filters.clearRetainingCapacity();
    std.debug.print("schema: baseline, {d} filter(s) with no mutant active ...\n", .{filters.items.len});
    const argv = try schemaArgv(arena, exe, 0, filters.items, &.{}, options.jobs orelse 4);
    const result = job.run(arena, io, argv, tree_dir, max_output, options.timeout_s) catch |err| {
        std.debug.print("schema: baseline did not finish: {s}\n", .{@errorName(err)});
        return null;
    };
    if (exitedZero(result.term)) {
        std.debug.print("schema: baseline is green\n", .{});
        return &.{};
    }
    const output = try std.mem.concat(arena, u8, &.{ result.stdout, result.stderr });
    const red = try core.failedTests(arena, output);
    const summary = core.parseSummary(output);
    if (red.len == 0 or summary == null) {
        std.debug.print("schema: baseline did not run to the end, stopping\n{s}\n", .{firstErrorLine(output) orelse "no error line"});
        return null;
    }
    for (red) |name| std.debug.print("schema: red with no mutant active, left out of every mutant run: {s}\n", .{name});
    return red;
}


fn judge(gpa: Allocator, outcome: *Outcome, m: Mutation, code: u8, output: []const u8, crashed: []const []const u8) !void {
    var failed: std.ArrayList([]const u8) = .empty;
    try failed.appendSlice(gpa, try core.failedTests(gpa, output));
    var status = core.classify(.unit, code, output);
    for (crashed) |name| {
        if (!contains(failed.items, name)) try failed.append(gpa, name);
        if (status != .compile_error) status = .killed;
    }
    outcome.status = @tagName(status);
    outcome.failed_tests = failed.items;
    outcome.ok = std.mem.eql(u8, outcome.status, m.expect_status);
    if (outcome.ok and status == .killed) {
        if (core.missingKill(outcome.failed_tests, m.kills)) |missing| {
            outcome.ok = false;
            outcome.missing_kill = missing;
        }
    }
    if (outcome.ok and status == .killed and m.exact) {
        if (core.unexpectedKill(outcome.failed_tests, m.kills)) |extra| {
            outcome.ok = false;
            outcome.unexpected_kill = extra;
        }
    }
    if (!outcome.ok and status == .other_error) outcome.detail = firstErrorLine(output);
}

fn runSchemaMutant(gpa: Allocator, io: std.Io, exe: []const u8, m: Mutation, number: u32, red: []const []const u8, options: Options) !Outcome {
    var outcome: Outcome = .{
        .id = m.id,
        .file = m.file,
        .expect = m.expect,
        .expected_status = m.expect_status,
        .status = "refused",
        .ok = false,
        .origin = "schema",
    };
    var crashed: std.ArrayList([]const u8) = .empty;
    var skips: std.ArrayList([]const u8) = .empty;
    try skips.appendSlice(gpa, red);
    var output: std.ArrayList(u8) = .empty;
    var code: u8 = 0;
    const started = std.Io.Timestamp.now(io, .awake);
    while (true) {
        const argv = try schemaArgv(gpa, exe, number, filtersOf(m), skips.items, null);
        const result = job.run(gpa, io, argv, tree_dir, max_output, core.timeoutFor(m.timeout_s, options.timeout_s)) catch |err| switch (err) {
            error.Timeout => {
                outcome.status = "timeout";
                outcome.ok = std.mem.eql(u8, m.expect_status, "timeout");
                outcome.seconds = secondsSince(io, started);
                return outcome;
            },
            else => return err,
        };
        const this_output = try std.mem.concat(gpa, u8, &.{ result.stdout, result.stderr });
        try output.appendSlice(gpa, this_output);
        const this_code: u8 = switch (result.term) {
            .exited => |c| c,
            else => 255,
        };
        if (code == 0) code = this_code;
        if (this_code == 0 or this_code == 1 or this_code == 2) break;
        const name = core.unfinishedTest(this_output) orelse break;
        if (contains(crashed.items, name) or crashed.items.len >= max_resumes) break;
        try crashed.append(gpa, name);
        try skips.append(gpa, name);
    }
    outcome.seconds = secondsSince(io, started);
    try judge(gpa, &outcome, m, if (crashed.items.len != 0) 1 else code, output.items, crashed.items);
    return outcome;
}

const SchemaWork = struct {
    io: std.Io,
    exe: []const u8,
    chosen: []const Selected,
    items: []const usize,
    slots: []?Outcome,
    options: Options,
    red: []const []const u8 = &.{},
    next: std.atomic.Value(usize) = .init(0),
    mutex: std.Io.Mutex = .init,
    done: usize = 0,
};

fn schemaWorker(work: *SchemaWork) void {
    const gpa = std.heap.smp_allocator;
    while (true) {
        const k = work.next.fetchAdd(1, .monotonic);
        if (k >= work.items.len) return;
        const i = work.items[k];
        const m = work.chosen[i].m;
        const outcome = runSchemaMutant(gpa, work.io, work.exe, m, schemaNumber(i), work.red, work.options) catch |err| Outcome{
            .id = m.id,
            .file = m.file,
            .expect = m.expect,
            .expected_status = m.expect_status,
            .status = "harness_error",
            .ok = false,
            .origin = "schema",
            .detail = @errorName(err),
        };
        work.slots[i] = outcome;
        work.mutex.lockUncancelable(work.io);
        defer work.mutex.unlock(work.io);
        work.done += 1;
        std.debug.print("[{d}/{d}] ", .{ work.done, work.items.len });
        printOutcome(outcome);
    }
}

fn runSchemata(arena: Allocator, io: std.Io, tree: std.Io.Dir, chosen: []const Selected, options: Options, stats: *SchemaStats) !?Run {
    const plans = try planSchemata(arena, io, tree, chosen);
    const exe = try buildSchema(arena, io, tree, chosen, plans, options, stats);

    var items: std.ArrayList(usize) = .empty;
    for (plans, 0..) |plan, i| {
        switch (plan) {
            .schema => try items.append(arena, i),
            .fallback => |why| stats.refused[@intFromEnum(why)] += 1,
        }
    }
    stats.in_schema = items.items.len;
    const slots = try arena.alloc(?Outcome, chosen.len);
    @memset(slots, null);

    if (exe) |path| {
        const baseline_started = std.Io.Timestamp.now(io, .awake);
        const red = try schemaBaseline(arena, io, path, chosen, plans, options) orelse return null;
        stats.baseline_seconds = secondsSince(io, baseline_started);
        stats.baseline_red = red.len;
        var runnable: std.ArrayList(usize) = .empty;
        for (items.items) |i| {
            const m = chosen[i].m;
            if (red.len != 0 and core.missingKill(red, m.kills) == null and m.kills.len != 0) {
                slots[i] = .{ .id = m.id, .file = m.file, .expect = m.expect, .expected_status = m.expect_status, .status = "baseline_red", .ok = false, .origin = "schema", .detail = "every test it expects to kill is red with no mutant active" };
                continue;
            }
            try runnable.append(arena, i);
        }
        items.clearRetainingCapacity();
        try items.appendSlice(arena, runnable.items);

        const workers = @max(@as(usize, 1), @min(options.jobs orelse 4, items.items.len));
        std.debug.print("schema: {d} mutant(s), {d} at a time, each in its own process\n", .{ items.items.len, workers });
        var work: SchemaWork = .{ .io = io, .exe = path, .chosen = chosen, .items = items.items, .slots = slots, .options = options, .red = red };
        const started = std.Io.Timestamp.now(io, .awake);
        const threads = try arena.alloc(std.Thread, workers);
        for (threads) |*t| t.* = try std.Thread.spawn(.{}, schemaWorker, .{&work});
        for (threads) |t| t.join();
        stats.run_seconds = secondsSince(io, started);
    }

    const single_started = std.Io.Timestamp.now(io, .awake);
    var outcomes: std.ArrayList(Outcome) = .empty;
    var failures: usize = 0;
    for (chosen, plans, 0..) |entry, plan, i| {
        const outcome = slots[i] orelse blk: {
            std.debug.print("running {s} on {s} on its own ({t}) ...\n", .{ entry.m.id, entry.m.file, plan.fallback });
            var single = try runOne(arena, io, tree, entry.m, entry.kind, options, "single");
            single.schema_refusal = @tagName(plan.fallback);
            printOutcome(single);
            break :blk single;
        };
        if (!outcome.ok) failures += 1;
        try outcomes.append(arena, outcome);
    }
    stats.single_seconds = secondsSince(io, single_started);
    return .{ .outcomes = try outcomes.toOwnedSlice(arena), .failures = failures };
}

fn printSchemaStats(stats: SchemaStats, total: usize) void {
    std.debug.print("\nschema: {d} of {d} mutation(s) ran from one binary; build {d}s in {d} round(s), baseline {d}s ({d} red test(s) left out), mutants {d}s, on their own {d}s\n", .{
        stats.in_schema, total, stats.build_seconds, stats.rounds, stats.baseline_seconds, stats.baseline_red, stats.run_seconds, stats.single_seconds,
    });
    for (stats.refused, 0..) |count, i| {
        if (count == 0) continue;
        std.debug.print("  on their own, {t}: {d}\n", .{ @as(schema.Refusal, @enumFromInt(i)), count });
    }
}

fn compareWithSingle(arena: Allocator, io: std.Io, tree: std.Io.Dir, chosen: []const Selected, run: Run, options: Options) !usize {
    var mismatch: usize = 0;
    var compared: usize = 0;
    for (chosen, run.outcomes) |entry, outcome| {
        if (!std.mem.eql(u8, outcome.origin, "schema")) continue;
        compared += 1;
        std.debug.print("compare {d}: {s} on its own ...\n", .{ compared, entry.m.id });
        const single = try runOne(arena, io, tree, entry.m, entry.kind, options, "single");
        if (std.mem.eql(u8, single.status, outcome.status) and single.ok == outcome.ok) continue;
        mismatch += 1;
        std.debug.print("compare mismatch {s}: schema={s} (ok={}) single={s} (ok={})\n", .{ entry.m.id, outcome.status, outcome.ok, single.status, single.ok });
        printOutcome(single);
    }
    std.debug.print("compare: {d} mutation(s) compared, {d} disagree\n", .{ compared, mismatch });
    return mismatch;
}

fn gitOutput(arena: Allocator, io: std.Io, argv: []const []const u8) !?[]const u8 {
    const result = try std.process.run(arena, io, .{ .argv = argv, .stdout_limit = .limited(max_output), .stderr_limit = .limited(max_output) });
    if (!exitedZero(result.term)) return null;
    return result.stdout;
}

fn changedMutations(arena: Allocator, io: std.Io, cwd: std.Io.Dir, ref: []const u8, spec: Spec) ![]const []const u8 {
    const diff = try gitOutput(arena, io, &.{ "git", "diff", "--unified=0", "--no-color", "--no-ext-diff", "--no-renames", ref, "--", ".", ":(exclude)vendor" }) orelse {
        std.debug.print("git diff {s} failed; is {s} a commit?\n", .{ ref, ref });
        return error.BadRef;
    };
    const touched = try changes.parseDiff(arena, diff);

    var changed_tests: std.ArrayList([]const u8) = .empty;
    for (touched) |change| {
        if (!std.mem.endsWith(u8, change.path, ".zig")) continue;
        const source = cwd.readFileAlloc(io, change.path, arena, .limited(core.max_source_bytes)) catch continue;
        try changed_tests.appendSlice(arena, try changes.changedTests(arena, source, change.ranges));
    }

    const show = try std.fmt.allocPrint(arena, "{s}:" ++ spec_path, .{ref});
    const before_bytes = try gitOutput(arena, io, &.{ "git", "show", show });
    const before: []const Mutation = if (before_bytes) |bytes| blk: {
        const old = std.json.parseFromSliceLeaky(Spec, arena, bytes, .{ .ignore_unknown_fields = true }) catch break :blk &.{};
        break :blk old.mutations;
    } else &.{};

    var ids: std.ArrayList([]const u8) = .empty;
    var counts = [_]usize{0} ** @typeInfo(changes.Reason).@"enum".fields.len;
    for (spec.mutations) |m| {
        const reason: ?changes.Reason = reason: {
            const now = try std.json.Stringify.valueAlloc(arena, m, .{});
            var old: ?[]const u8 = null;
            for (before) |b| {
                if (std.mem.eql(u8, b.id, m.id)) old = try std.json.Stringify.valueAlloc(arena, b, .{});
            }
            if (changes.entryChanged(old, now)) break :reason .entry_changed;
            const source = cwd.readFileAlloc(io, m.file, arena, .limited(core.max_source_bytes)) catch break :reason .stale;
            switch (changes.fromState(source, m.from, changes.rangesOf(touched, m.file) orelse &.{})) {
                .stale => break :reason .stale,
                .touched => break :reason .from_changed,
                .untouched => {},
            }
            if (changes.namesATest(changed_tests.items, m.kills, m.filter) != null) break :reason .kill_test_changed;
            break :reason null;
        };
        const why = reason orelse continue;
        counts[@intFromEnum(why)] += 1;
        try ids.append(arena, m.id);
        std.debug.print("changed since {s}: {s} ({t})\n", .{ ref, m.id, why });
    }
    std.debug.print("changed since {s}: {d} of {d} mutation(s) selected", .{ ref, ids.items.len, spec.mutations.len });
    for (counts, 0..) |count, i| {
        if (count != 0) std.debug.print(", {t} {d}", .{ @as(changes.Reason, @enumFromInt(i)), count });
    }
    std.debug.print("\n", .{});
    if (counts[@intFromEnum(changes.Reason.stale)] != 0) std.debug.print("changed since {s}: a stale mutation's from text is no longer in its file\n", .{ref});
    return ids.toOwnedSlice(arena);
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

fn runOne(arena: Allocator, io: std.Io, tree: std.Io.Dir, m: Mutation, kind: core.Kind, options: Options, origin: []const u8) !Outcome {
    var outcome: Outcome = .{
        .id = m.id,
        .file = m.file,
        .expect = m.expect,
        .expected_status = m.expect_status,
        .status = "refused",
        .ok = false,
        .origin = origin,
    };
    if (!try knownToGitAndClean(arena, io, m.file)) {
        outcome.detail = "file is not known to git or has uncommitted changes";
        return outcome;
    }
    const original = try tree.readFileAlloc(io, m.file, arena, .limited(core.max_source_bytes));
    const mutated = core.applyMutation(arena, original, m.from, m.to, m.all) catch |err| {
        outcome.status = "bad_pattern";
        outcome.detail = @errorName(err);
        return outcome;
    };

    const backups = [_]core.Backup{.{ .path = m.file, .original = original }};
    errdefer restoreAll(arena, io, tree, &backups) catch {};
    try tree.writeFile(io, .{ .sub_path = m.file, .data = mutated });

    const started = std.Io.Timestamp.now(io, .awake);
    const run = runBuild(arena, io, kind, m, options);
    try restoreAll(arena, io, tree, &backups);
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
        if (options.jobs) |n| try argv.append(arena, try std.fmt.allocPrint(arena, "-j{d}", .{n}));
        return job.run(arena, io, argv.items, tree_dir, max_output, core.timeoutFor(m.timeout_s, options.timeout_s));
    }
    const filters = if (options.full) &.{} else if (m.filter.len != 0) m.filter else m.kills;
    return runFiltered(arena, io, filters, m.optimize, .{
        .full = options.full,
        .timeout_s = core.timeoutFor(m.timeout_s, options.timeout_s),
        .jobs = options.jobs,
    });
}

fn runFiltered(arena: Allocator, io: std.Io, filters: []const []const u8, optimize: ?[]const u8, options: Options) !std.process.RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "zig", "build", "test", "--summary", "all", "-Dslow=true" });
    if (optimize) |mode| try argv.append(arena, try std.fmt.allocPrint(arena, "-Doptimize={s}", .{mode}));
    if (options.jobs) |n| try argv.append(arena, try std.fmt.allocPrint(arena, "-j{d}", .{n}));
    if (!options.full) {
        for (filters) |f| try argv.append(arena, try std.fmt.allocPrint(arena, "-Dtest-filter={s}", .{f}));
    }
    return job.run(arena, io, argv.items, tree_dir, max_output, options.timeout_s);
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
