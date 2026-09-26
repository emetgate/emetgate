const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const testing = std.testing;

pub const std_options: std.Options = .{ .logFn = log };
pub const panic = std.debug.FullPanic(onPanic);

pub var emetgate_mutant: u32 = 0;
pub var emetgate_slow: bool = false;

var log_err_count: usize = 0;
var current_test: ?[]const u8 = null;
const rio: Io = Io.Threaded.global_single_threaded.io();

pub const Shard = struct {
    index: usize = 1,
    count: usize = 1,
};

pub const Options = struct {
    filters: []const []const u8 = &.{},
    skips: []const []const u8 = &.{},
    shard: Shard = .{},
    slow: bool = false,
    mutant: u32 = 0,
    list: bool = false,
    verbose: bool = false,
    timing: ?usize = null,
    tsv: ?[]const u8 = null,
    record: ?[]const u8 = null,
    jobs: usize = 1,
};

pub const usage_text = "usage: test-all [--filter NAME]... [--skip FULL_NAME]... [--jobs N | --shard I/N] [--slow] [--mutant ID] [--list] [--verbose] [--timing[=TOP]] [--tsv=PATH] [--record=PATH]\n";

pub fn parseShard(text: []const u8) error{InvalidShard}!Shard {
    const slash = std.mem.indexOfScalar(u8, text, '/') orelse return error.InvalidShard;
    const index = std.fmt.parseUnsigned(usize, text[0..slash], 10) catch return error.InvalidShard;
    const count = std.fmt.parseUnsigned(usize, text[slash + 1 ..], 10) catch return error.InvalidShard;
    if (count == 0 or index == 0 or index > count) return error.InvalidShard;
    return .{ .index = index, .count = count };
}

pub fn parseArgs(gpa: std.mem.Allocator, args: []const []const u8) !Options {
    var options: Options = .{};
    var filters: std.ArrayList([]const u8) = .empty;
    var skips: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--filter")) {
            i += 1;
            if (i == args.len or args[i].len == 0) return error.InvalidArgs;
            try filters.append(gpa, args[i]);
        } else if (std.mem.eql(u8, arg, "--skip")) {
            i += 1;
            if (i == args.len or args[i].len == 0) return error.InvalidArgs;
            try skips.append(gpa, args[i]);
        } else if (std.mem.eql(u8, arg, "--shard")) {
            i += 1;
            if (i == args.len) return error.InvalidArgs;
            options.shard = parseShard(args[i]) catch return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--jobs")) {
            i += 1;
            if (i == args.len) return error.InvalidArgs;
            options.jobs = std.fmt.parseUnsigned(usize, args[i], 10) catch return error.InvalidArgs;
            if (options.jobs == 0) return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--mutant")) {
            i += 1;
            if (i == args.len) return error.InvalidArgs;
            options.mutant = std.fmt.parseUnsigned(u32, args[i], 10) catch return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--slow")) {
            options.slow = true;
        } else if (std.mem.eql(u8, arg, "--list")) {
            options.list = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            options.verbose = true;
        } else if (std.mem.eql(u8, arg, "--timing")) {
            options.timing = 40;
        } else if (std.mem.startsWith(u8, arg, "--timing=")) {
            options.timing = std.fmt.parseUnsigned(usize, arg["--timing=".len..], 10) catch return error.InvalidArgs;
        } else if (std.mem.startsWith(u8, arg, "--tsv=")) {
            options.tsv = arg["--tsv=".len..];
        } else if (std.mem.startsWith(u8, arg, "--record=")) {
            options.record = arg["--record=".len..];
        } else {
            return error.InvalidArgs;
        }
    }
    if (options.jobs > 1 and (options.shard.count != 1 or options.record != null)) return error.InvalidArgs;
    options.filters = try filters.toOwnedSlice(gpa);
    options.skips = try skips.toOwnedSlice(gpa);
    return options;
}

pub fn matches(name: []const u8, filters: []const []const u8) bool {
    if (name.len == 0) return false;
    if (filters.len == 0) return true;
    for (filters) |filter| {
        if (std.mem.indexOf(u8, name, filter) != null) return true;
    }
    return false;
}

pub fn inShard(ordinal: usize, shard: Shard) bool {
    return ordinal % shard.count == shard.index - 1;
}

pub const Selection = struct {
    indices: []const usize,
    matched: usize,
};

pub fn select(gpa: std.mem.Allocator, names: []const []const u8, filters: []const []const u8, shard: Shard) !Selection {
    var picked: std.ArrayList(usize) = .empty;
    var ordinal: usize = 0;
    for (names, 0..) |name, i| {
        if (!matches(name, filters)) continue;
        defer ordinal += 1;
        if (inShard(ordinal, shard)) try picked.append(gpa, i);
    }
    return .{ .indices = try picked.toOwnedSlice(gpa), .matched = ordinal };
}

pub const Coverage = struct {
    missing: ?usize = null,
    repeated: ?usize = null,
    stray: ?usize = null,
};

pub fn coverage(gpa: std.mem.Allocator, names: []const []const u8, filters: []const []const u8, recorded: []const usize) !Coverage {
    const seen = try gpa.alloc(u32, names.len);
    defer gpa.free(seen);
    @memset(seen, 0);
    for (recorded) |index| {
        if (index >= names.len or !matches(names[index], filters)) return .{ .stray = index };
        seen[index] += 1;
    }
    for (names, 0..) |name, i| {
        if (!matches(name, filters)) continue;
        if (seen[i] == 0) return .{ .missing = i };
        if (seen[i] > 1) return .{ .repeated = i };
    }
    return .{};
}

pub fn parseRecord(gpa: std.mem.Allocator, text: []const u8, out: *std.ArrayList(usize)) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (line.len == 0) continue;
        try out.append(gpa, std.fmt.parseUnsigned(usize, line, 10) catch return error.BadRecord);
    }
}

pub const shard_guard = "shards: every selected test runs in exactly one shard";

pub fn withoutSkipped(gpa: std.mem.Allocator, names: []const []const u8, skips: []const []const u8) ![]const []const u8 {
    if (skips.len == 0) return names;
    const kept = try gpa.dupe([]const u8, names);
    for (kept) |*name| {
        for (skips) |skip| {
            if (std.mem.eql(u8, name.*, skip)) name.* = "";
        }
    }
    return kept;
}

fn testNames(gpa: std.mem.Allocator) ![]const []const u8 {
    const names = try gpa.alloc([]const u8, builtin.test_functions.len);
    for (builtin.test_functions, names) |t, *name| name.* = t.name;
    return names;
}

pub const Totals = struct {
    passed: usize = 0,
    total: usize = 0,
    skipped: usize = 0,
    failed: usize = 0,
    leaked: usize = 0,
};

pub fn parseTotals(text: []const u8) ?Totals {
    const marker = " tests passed; ";
    const at = std.mem.lastIndexOf(u8, text, marker) orelse return null;
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..at], '\n')) |nl| nl + 1 else 0;
    const ratio = text[line_start..at];
    const slash = std.mem.indexOfScalar(u8, ratio, '/') orelse return null;
    var totals: Totals = .{
        .passed = std.fmt.parseUnsigned(usize, ratio[0..slash], 10) catch return null,
        .total = std.fmt.parseUnsigned(usize, ratio[slash + 1 ..], 10) catch return null,
    };
    const line_end = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
    var parts = std.mem.splitSequence(u8, text[at + marker.len .. line_end], "; ");
    inline for (.{ "skipped", "failed", "leaked" }) |field| {
        const part = parts.next() orelse return null;
        const space = std.mem.indexOfScalar(u8, part, ' ') orelse return null;
        if (!std.mem.eql(u8, part[space + 1 ..], field)) return null;
        @field(totals, field) = std.fmt.parseUnsigned(usize, part[0..space], 10) catch return null;
    }
    return totals;
}

fn oom() noreturn {
    @panic("oom");
}

fn shardArgs(gpa: std.mem.Allocator, exe: []const u8, i: usize, record: []const u8, options: Options) []const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(gpa, &.{ exe, "--shard", std.fmt.allocPrint(gpa, "{d}/{d}", .{ i, options.jobs }) catch oom() }) catch oom();
    argv.append(gpa, std.fmt.allocPrint(gpa, "--record={s}", .{record}) catch oom()) catch oom();
    for (options.filters) |filter| argv.appendSlice(gpa, &.{ "--filter", filter }) catch oom();
    for (options.skips) |skip| argv.appendSlice(gpa, &.{ "--skip", skip }) catch oom();
    if (options.slow) argv.append(gpa, "--slow") catch oom();
    argv.append(gpa, "--verbose") catch oom();
    if (options.mutant != 0) argv.appendSlice(gpa, &.{ "--mutant", std.fmt.allocPrint(gpa, "{d}", .{options.mutant}) catch oom() }) catch oom();
    return argv.items;
}

fn progressLine(line: []const u8) ?struct { name: []const u8, rest: []const u8 } {
    const slash = std.mem.indexOfScalar(u8, line, '/') orelse return null;
    const space = std.mem.indexOfScalarPos(u8, line, slash, ' ') orelse return null;
    if (slash == 0 or space == slash + 1) return null;
    for (line[0..slash]) |c| if (!std.ascii.isDigit(c)) return null;
    for (line[slash + 1 .. space]) |c| if (!std.ascii.isDigit(c)) return null;
    const dots = std.mem.indexOfPos(u8, line, space, "...") orelse return null;
    return .{ .name = line[space + 1 .. dots], .rest = line[dots + 3 ..] };
}

fn finishedStatus(rest: []const u8) bool {
    return std.mem.startsWith(u8, rest, "OK") or std.mem.startsWith(u8, rest, "SKIP") or std.mem.startsWith(u8, rest, "FAIL");
}

pub fn unfinishedTest(log_text: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, log_text, '\n');
    while (lines.next()) |raw| {
        const p = progressLine(std.mem.trimEnd(u8, raw, " \r")) orelse continue;
        found = if (finishedStatus(p.rest)) null else p.name;
    }
    return found;
}

fn printShardLog(log_text: []const u8, verbose: bool) void {
    var lines = std.mem.splitScalar(u8, log_text, '\n');
    while (lines.next()) |raw| {
        if (lines.peek() == null and raw.len == 0) break;
        if (!verbose) {
            if (progressLine(std.mem.trimEnd(u8, raw, " \r"))) |p| {
                if (std.mem.startsWith(u8, p.rest, "OK") or std.mem.startsWith(u8, p.rest, "SKIP")) continue;
            }
        }
        std.debug.print("{s}\n", .{raw});
    }
}

fn runSharded(gpa: std.mem.Allocator, init: std.process.Init.Minimal, names: []const []const u8, options: Options) u8 {
    var threaded: Io.Threaded = .init(gpa, .{ .argv0 = .init(init.args), .environ = init.environ });
    defer threaded.deinit();
    const io = threaded.io();
    const exe = std.process.executablePathAlloc(io, gpa) catch |err| {
        std.debug.print("error: cannot find the test binary: {t}\n", .{err});
        return 1;
    };
    const stamp: u96 = @bitCast(Io.Timestamp.now(io, .real).nanoseconds);
    const dir_path = std.fmt.allocPrint(gpa, ".zig-cache/test-all/{x}", .{stamp}) catch oom();
    const cwd = Io.Dir.cwd();
    cwd.createDirPath(io, dir_path) catch |err| {
        std.debug.print("error: cannot create {s}: {t}\n", .{ dir_path, err });
        return 1;
    };
    defer cwd.deleteTree(io, dir_path) catch {};

    const ShardRun = struct { process: std.process.Child, log: []const u8, record: []const u8 };
    const shards = gpa.alloc(ShardRun, options.jobs) catch oom();
    var started: usize = 0;
    defer for (shards[0..started]) |*shard| shard.process.kill(io);
    for (shards, 1..) |*shard, i| {
        shard.log = std.fmt.allocPrint(gpa, "{s}/shard-{d}.log", .{ dir_path, i }) catch oom();
        shard.record = std.fmt.allocPrint(gpa, "{s}/shard-{d}.txt", .{ dir_path, i }) catch oom();
        const log_file = cwd.createFile(io, shard.log, .{}) catch |err| {
            std.debug.print("error: cannot create {s}: {t}\n", .{ shard.log, err });
            return 1;
        };
        defer log_file.close(io);
        shard.process = std.process.spawn(io, .{
            .argv = shardArgs(gpa, exe, i, shard.record, options),
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .{ .file = log_file },
        }) catch |err| {
            std.debug.print("error: cannot start shard {d}: {t}\n", .{ i, err });
            return 1;
        };
        started += 1;
    }

    var sum: Totals = .{};
    var broken: usize = 0;
    var recorded: std.ArrayList(usize) = .empty;
    for (shards, 1..) |*shard, i| {
        const term = shard.process.wait(io) catch |err| {
            std.debug.print("error: shard {d} could not be waited for: {t}\n", .{ i, err });
            broken += 1;
            continue;
        };
        const log_text = cwd.readFileAlloc(io, shard.log, gpa, .limited(256 * 1024 * 1024)) catch "";
        printShardLog(log_text, options.verbose);
        const finished = switch (term) {
            .exited => |code| code == 0 or code == 1,
            else => false,
        };
        const totals = parseTotals(log_text);
        if (!finished or totals == null) {
            if (unfinishedTest(log_text)) |name| std.debug.print("error: '{s}' failed: crashed in shard {d}/{d}\n", .{ name, i, options.jobs });
            std.debug.print("error: shard {d}/{d} did not finish ({any})\n", .{ i, options.jobs, term });
            broken += 1;
        }
        if (totals) |t| {
            sum.passed += t.passed;
            sum.total += t.total;
            sum.skipped += t.skipped;
            sum.failed += t.failed;
            sum.leaked += t.leaked;
        }
        const record_text = cwd.readFileAlloc(io, shard.record, gpa, .limited(16 * 1024 * 1024)) catch "";
        parseRecord(gpa, record_text, &recorded) catch {
            std.debug.print("error: shard {d} wrote a malformed record\n", .{i});
            broken += 1;
        };
    }
    started = 0;

    var uncovered = true;
    const result = coverage(gpa, names, options.filters, recorded.items) catch oom();
    if (result.missing) |i| {
        std.debug.print("error: '{s}' failed: no shard ran {s}\n", .{ shard_guard, names[i] });
    } else if (result.repeated) |i| {
        std.debug.print("error: '{s}' failed: more than one shard ran {s}\n", .{ shard_guard, names[i] });
    } else if (result.stray) |i| {
        std.debug.print("error: '{s}' failed: a shard ran test #{d}, which the filters do not select\n", .{ shard_guard, i });
    } else uncovered = false;
    std.debug.print("{d}/{d} tests passed; {d} skipped; {d} failed; {d} leaked; mutant {d}; {d} shard(s)\n", .{
        sum.passed, sum.total, sum.skipped, sum.failed, sum.leaked, options.mutant, options.jobs,
    });
    return if (broken != 0 or uncovered or sum.failed != 0 or sum.leaked != 0) 1 else 0;
}

const Result = struct { name: []const u8, ns: u64, status: enum { pass, skip, fail } };

fn lessNs(_: void, a: Result, b: Result) bool {
    return a.ns > b.ns;
}

pub fn fuzz(
    context: anytype,
    comptime testOne: fn (context: @TypeOf(context), smith: *testing.Smith) anyerror!void,
    options: testing.FuzzInputOptions,
) anyerror!void {
    for (options.corpus) |input| {
        var smith: testing.Smith = .{ .in = input };
        try testOne(context, &smith);
    }
    var empty: testing.Smith = .{ .in = "" };
    try testOne(context, &empty);
}

fn suiteOf(name: []const u8) []const u8 {
    if (std.mem.find(u8, name, ".test.")) |i| return name[0..i];
    if (std.mem.find(u8, name, ".decltest.")) |i| return name[0..i];
    return name;
}

pub fn main(init: std.process.Init.Minimal) void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    const gpa = gpa_state.allocator();
    const argv = init.args.toSlice(gpa) catch @panic("oom");
    const options = parseArgs(gpa, argv[1..]) catch {
        std.debug.print("{s}", .{usage_text});
        std.process.exit(2);
    };
    emetgate_mutant = options.mutant;
    std.process.exit(run(gpa, init, options));
}

fn run(gpa: std.mem.Allocator, init: std.process.Init.Minimal, options: Options) u8 {
    emetgate_slow = options.slow;

    const names = withoutSkipped(gpa, testNames(gpa) catch @panic("oom"), options.skips) catch @panic("oom");

    const selection = select(gpa, names, options.filters, options.shard) catch @panic("oom");
    if (options.filters.len != 0 and selection.matched == 0) {
        std.debug.print("error: no test matches the filter(s):", .{});
        for (options.filters) |f| std.debug.print(" \"{s}\"", .{f});
        std.debug.print("\n", .{});
        return 2;
    }
    if (options.shard.count == 1 and selection.indices.len != selection.matched) {
        std.debug.print("error: '{s}' failed: one shard selected {d} of {d} matching tests\n", .{ shard_guard, selection.indices.len, selection.matched });
        return 1;
    }
    if (options.list) {
        var buf: [4096]u8 = undefined;
        var out = Io.File.stdout().writer(rio, &buf);
        for (selection.indices) |i| out.interface.print("{s}\n", .{names[i]}) catch {};
        out.interface.flush() catch {};
        return 0;
    }
    if (options.jobs > 1) return runSharded(gpa, init, names, options);
    if (options.record) |path| writeRecord(path, selection.indices) catch |err| {
        std.debug.print("error: cannot write shard record {s}: {t}\n", .{ path, err });
        return 1;
    };
    return runTests(gpa, init, selection.indices, options);
}

fn writeRecord(path: []const u8, indices: []const usize) !void {
    const f = try Io.Dir.cwd().createFile(rio, path, .{});
    defer f.close(rio);
    var buf: [4096]u8 = undefined;
    var w = f.writer(rio, &buf);
    for (indices) |i| try w.interface.print("{d}\n", .{i});
    try w.interface.flush();
}

fn runTests(gpa: std.mem.Allocator, init: std.process.Init.Minimal, indices: []const usize, options: Options) u8 {
    const results = gpa.alloc(Result, indices.len) catch @panic("oom");
    var failed: std.ArrayList([]const u8) = .empty;
    var ok: usize = 0;
    var skip: usize = 0;
    var leaks: usize = 0;
    const t_all = Io.Timestamp.now(rio, .awake);

    for (indices, 0..) |index, n| {
        const test_fn = builtin.test_functions[index];
        testing.allocator_instance = .{};
        testing.io_instance = .init(testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        testing.log_level = .warn;
        testing.environ = init.environ;
        log_err_count = 0;
        current_test = test_fn.name;

        if (options.verbose) std.debug.print("{d}/{d} {s}...", .{ n + 1, indices.len, test_fn.name });
        const t0 = Io.Timestamp.now(rio, .awake);
        const res = test_fn.func();
        const ns: u64 = @intCast(@max(0, t0.durationTo(Io.Timestamp.now(rio, .awake)).nanoseconds));
        current_test = null;
        results[n] = .{ .name = test_fn.name, .ns = ns, .status = .pass };

        var why: ?[]const u8 = null;
        if (res) |_| {} else |err| switch (err) {
            error.SkipZigTest => results[n].status = .skip,
            else => {
                why = @errorName(err);
                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            },
        }
        testing.io_instance.deinit();
        if (testing.allocator_instance.deinit() == .leak) {
            leaks += 1;
            why = why orelse "leaked memory";
        }
        if (why == null and log_err_count != 0) why = "logged an error";

        if (why) |reason| {
            results[n].status = .fail;
            failed.append(gpa, test_fn.name) catch @panic("oom");
            if (options.verbose) std.debug.print("FAIL ({s})\n", .{reason});
            std.debug.print("error: '{s}' failed: {s}\n", .{ test_fn.name, reason });
        } else if (results[n].status == .skip) {
            skip += 1;
            if (options.verbose) std.debug.print("SKIP\n", .{});
        } else {
            ok += 1;
            if (options.verbose) std.debug.print("OK ({d} ms)\n", .{ns / std.time.ns_per_ms});
        }
    }
    const total_ns: u64 = @intCast(@max(0, t_all.durationTo(Io.Timestamp.now(rio, .awake)).nanoseconds));

    if (options.timing) |top_n| printTiming(gpa, results, top_n, total_ns);
    if (options.tsv) |path| writeTsv(path, results) catch |e| std.debug.print("tsv write failed: {t}\n", .{e});

    for (failed.items) |name| std.debug.print("error: '{s}' failed\n", .{name});
    std.debug.print("{d}/{d} tests passed; {d} skipped; {d} failed; {d} leaked; mutant {d}; shard {d}/{d}\n", .{
        ok, indices.len, skip, failed.items.len, leaks, options.mutant, options.shard.index, options.shard.count,
    });
    return if (failed.items.len != 0) 1 else 0;
}

fn printTiming(gpa: std.mem.Allocator, results: []const Result, top_n: usize, total_ns: u64) void {
    const sorted = gpa.dupe(Result, results) catch @panic("oom");
    std.mem.sort(Result, sorted, {}, lessNs);
    var sum_tests: u64 = 0;
    for (sorted) |r| sum_tests += r.ns;
    std.debug.print("\n==== Slowest {d} tests ====\n", .{@min(top_n, sorted.len)});
    var top20: u64 = 0;
    for (sorted[0..@min(top_n, sorted.len)], 0..) |r, i| {
        if (i < 20) top20 += r.ns;
        std.debug.print("{d:>3} {d:>9.1} ms  {s}{s}\n", .{
            i + 1, @as(f64, @floatFromInt(r.ns)) / 1e6, r.name,
            switch (r.status) {
                .pass => "",
                .skip => "  [SKIP]",
                .fail => "  [FAIL]",
            },
        });
    }

    const Suite = struct { name: []const u8, ns: u64, count: usize };
    var suites: std.ArrayList(Suite) = .empty;
    for (results) |r| {
        const s = suiteOf(r.name);
        for (suites.items) |*e| {
            if (std.mem.eql(u8, e.name, s)) {
                e.ns += r.ns;
                e.count += 1;
                break;
            }
        } else suites.append(gpa, .{ .name = s, .ns = r.ns, .count = 1 }) catch @panic("oom");
    }
    std.mem.sort(Suite, suites.items, {}, struct {
        fn f(_: void, a: Suite, b: Suite) bool {
            return a.ns > b.ns;
        }
    }.f);
    std.debug.print("\n==== Per-file totals ====\n", .{});
    for (suites.items) |s| {
        std.debug.print("{d:>10.1} ms  {d:>4} tests  {s}\n", .{ @as(f64, @floatFromInt(s.ns)) / 1e6, s.count, s.name });
    }
    std.debug.print("\nsum of tests: {d:.1} ms; wall: {d:.1} ms; top20: {d:.1} ms ({d:.1}%)\n", .{
        @as(f64, @floatFromInt(sum_tests)) / 1e6,
        @as(f64, @floatFromInt(total_ns)) / 1e6,
        @as(f64, @floatFromInt(top20)) / 1e6,
        100.0 * @as(f64, @floatFromInt(top20)) / @as(f64, @floatFromInt(@max(sum_tests, 1))),
    });
}

fn writeTsv(path: []const u8, results: []const Result) !void {
    const f = try Io.Dir.cwd().createFile(rio, path, .{});
    defer f.close(rio);
    var buf: [4096]u8 = undefined;
    var w = f.writer(rio, &buf);
    for (results) |r| try w.interface.print("{d}\t{t}\t{s}\n", .{ r.ns / std.time.ns_per_us, r.status, r.name });
    try w.interface.flush();
}

fn onPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    if (current_test) |name| std.debug.print("\nerror: '{s}' failed: crashed: {s}\n", .{ name, msg });
    std.debug.defaultPanic(msg, first_trace_addr);
}

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(level) <= @intFromEnum(std.log.Level.err)) log_err_count +|= 1;
    if (@intFromEnum(level) <= @intFromEnum(testing.log_level)) {
        std.debug.print("[" ++ @tagName(scope) ++ "] (" ++ @tagName(level) ++ "): " ++ format ++ "\n", args);
    }
}
