const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const testing = std.testing;

pub const std_options: std.Options = .{ .logFn = log };

var log_err_count: usize = 0;
const rio: Io = Io.Threaded.global_single_threaded.io();

const Result = struct { name: []const u8, ns: u64, status: enum { pass, skip, fail } };

fn lessNs(_: void, a: Result, b: Result) bool {
    return a.ns > b.ns;
}

fn suiteOf(name: []const u8) []const u8 {
    if (std.mem.find(u8, name, ".test.")) |i| return name[0..i];
    if (std.mem.find(u8, name, ".decltest.")) |i| return name[0..i];
    return name;
}

pub fn main(init: std.process.Init.Minimal) void {
    const fns = builtin.test_functions;
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    const gpa = gpa_state.allocator();
    const results = gpa.alloc(Result, fns.len) catch @panic("oom");

    var ok: usize = 0;
    var skip: usize = 0;
    var fail: usize = 0;
    var leaks: usize = 0;
    const t_all = Io.Timestamp.now(rio, .awake);

    for (fns, 0..) |test_fn, i| {
        testing.allocator_instance = .{};
        testing.io_instance = .init(testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        testing.log_level = .warn;
        testing.environ = init.environ;

        std.debug.print("{d}/{d} {s}...", .{ i + 1, fns.len, test_fn.name });
        const t0 = Io.Timestamp.now(rio, .awake);
        const res = test_fn.func();
        const t1 = Io.Timestamp.now(rio, .awake);
        const ns: u64 = @intCast(@max(0, t0.durationTo(t1).nanoseconds));
        results[i] = .{ .name = test_fn.name, .ns = ns, .status = .pass };

        if (res) |_| {
            ok += 1;
            std.debug.print("OK ({d} ms)\n", .{ns / std.time.ns_per_ms});
        } else |err| switch (err) {
            error.SkipZigTest => {
                skip += 1;
                results[i].status = .skip;
                std.debug.print("SKIP\n", .{});
            },
            else => {
                fail += 1;
                results[i].status = .fail;
                std.debug.print("FAIL ({t})\n", .{err});
                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            },
        }
        testing.io_instance.deinit();
        if (testing.allocator_instance.deinit() == .leak) leaks += 1;
    }
    const total_ns: u64 = @intCast(Io.Timestamp.now(rio, .awake).nanoseconds - t_all.nanoseconds);

    const args = init.args.toSlice(gpa) catch @panic("oom");
    var top_n: usize = 40;
    if (args.len > 1) top_n = std.fmt.parseUnsigned(usize, args[1], 10) catch 40;
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
            switch (r.status) { .pass => "", .skip => "  [SKIP]", .fail => "  [FAIL]" },
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
    std.debug.print("\n==== Per-suite totals ====\n", .{});
    for (suites.items) |s| {
        std.debug.print("{d:>10.1} ms  {d:>4} tests  {s}\n", .{ @as(f64, @floatFromInt(s.ns)) / 1e6, s.count, s.name });
    }
    std.debug.print("\nsum of tests: {d:.1} ms; wall: {d:.1} ms; top20: {d:.1} ms ({d:.1}%)\n", .{
        @as(f64, @floatFromInt(sum_tests)) / 1e6,
        @as(f64, @floatFromInt(total_ns)) / 1e6,
        @as(f64, @floatFromInt(top20)) / 1e6,
        100.0 * @as(f64, @floatFromInt(top20)) / @as(f64, @floatFromInt(@max(sum_tests, 1))),
    });
    std.debug.print("{d} passed; {d} skipped; {d} failed; {d} leaked; {d} errors logged.\n", .{ ok, skip, fail, leaks, log_err_count });

    if (args.len > 2) if (@as(?[]const u8, args[2])) |path| writeTsv(path, results) catch |e| std.debug.print("tsv write failed: {t}\n", .{e});

    if (fail != 0 or leaks != 0 or log_err_count != 0) std.process.exit(1);
}

fn writeTsv(path: []const u8, results: []const Result) !void {
    const f = try Io.Dir.cwd().createFile(rio, path, .{});
    defer f.close(rio);
    var buf: [4096]u8 = undefined;
    var w = f.writer(rio, &buf);
    for (results) |r| try w.interface.print("{d}\t{t}\t{s}\n", .{ r.ns / std.time.ns_per_us, r.status, r.name });
    try w.interface.flush();
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
