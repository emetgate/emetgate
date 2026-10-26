const std = @import("std");
const repo_mod = @import("../platform/repo.zig");
const emet_file = @import("../platform/emet_file.zig");
const find_tools = @import("find_tools.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Timestamp = std.Io.Timestamp;

pub const Command = enum { search, build, bench };

pub const max_patterns = 16;
pub const bench_runs = 1000;

pub const usage =
    \\       emetgate find <pattern> [--root <dir>]
    \\       emetgate find build [--root <dir>]
    \\       emetgate find bench <pattern>... [--root <dir>]
    \\
;

pub const Options = struct {
    command: Command = .search,
    root: ?[]const u8 = null,
    patterns: [max_patterns][]const u8 = undefined,
    pattern_count: usize = 0,

    pub fn given(self: *const Options) []const []const u8 {
        return self.patterns[0..self.pattern_count];
    }
};

pub fn parse(args: []const [:0]const u8) ?Options {
    var options: Options = .{};
    var i: usize = 0;
    if (args.len != 0) {
        if (std.mem.eql(u8, args[0], "build")) options.command = .build;
        if (std.mem.eql(u8, args[0], "bench")) options.command = .bench;
        if (options.command != .search) i = 1;
    }
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.eql(u8, arg, "--root")) {
            i += 1;
            if (i >= args.len or options.root != null) return null;
            options.root = args[i];
            continue;
        }
        if (options.pattern_count == max_patterns) return null;
        options.patterns[options.pattern_count] = arg;
        options.pattern_count += 1;
    }
    const fits = switch (options.command) {
        .search => options.pattern_count == 1,
        .build => options.pattern_count == 0,
        .bench => options.pattern_count != 0,
    };
    return if (fits) options else null;
}

pub fn run(gpa: Allocator, io: std.Io, options: Options, out: *Writer) !u8 {
    const root = try repo_mod.servedRoot(gpa, io, options.root);
    defer gpa.free(root);
    const session = try find_tools.Session.create(gpa, io, root);
    defer session.destroy();
    const started = Timestamp.now(io, .awake);
    var bprof: emet_file.BuildProfile = .{ .io = io };
    if (options.command == .build) emet_file.build_profile = &bprof;
    try session.prepare(if (options.command == .build) .build else .load);
    emet_file.build_profile = null;
    const ix = session.current().?;
    switch (options.command) {
        .build => {
            try out.print("{d} files, {d} MB read, index {d} MB, ready in {d} ms\n", .{ ix.h.n_files, ix.h.n_orig >> 20, ix.h.size >> 20, since(io, started) / std.time.ns_per_ms });
            try out.print("  stages ms: read {d} | ends {d} | sais {d} | owner {d} | emit+write {d} (sections {d} + wavelets {d})\n", .{
                bprof.read_ns / std.time.ns_per_ms, bprof.ends_ns / std.time.ns_per_ms,
                bprof.sais_ns / std.time.ns_per_ms, bprof.owner_ns / std.time.ns_per_ms,
                bprof.emit_ns / std.time.ns_per_ms,
                bprof.sections_ns / std.time.ns_per_ms, bprof.wavelets_ns / std.time.ns_per_ms,
            });
        },
        .search => {
            const t0 = Timestamp.now(io, .awake);
            const answer = try session.search(options.given()[0]);
            const spent = since(io, t0);
            try out.writeAll(answer.text);
            try out.print("\n{d:.1} us\n", .{micros(spent)});
        },
        .bench => try bench(io, session, ix, options.given(), out),
    }
    return 0;
}

fn bench(io: std.Io, session: *find_tools.Session, ix: *const emet_file.Index, patterns: []const []const u8, out: *Writer) !void {
    try out.print("{d} files, {d} MB read, index {d} MB, {d} runs each\n\n{s:<24} {s:>9} {s:>6} {s:>9} {s:>9} {s:>9} {s:>9}  {s:>8} {s:>8} {s:>8} {s:>8}\n", .{
        ix.h.n_files, ix.h.n_orig >> 20, ix.h.size >> 20, bench_runs, "pattern", "hits", "files", "first us", "p50 us", "p99 us", "max us", "rng us", "coll us", "sort us", "fmt us",
    });
    var times: [bench_runs]u64 = undefined;
    for (patterns) |pattern| {
        var answer: emet_file.Answer = undefined;
        for (&times) |*t| {
            const t0 = Timestamp.now(io, .awake);
            answer = try session.search(pattern);
            t.* = since(io, t0);
        }
        const first = times[0];
        std.mem.sort(u64, &times, {}, std.sort.asc(u64));

        // A few profiled runs for the stage breakdown (median), separate from the
        // timed runs above so the profiler branches never touch the p50/p99 numbers.
        var prof: emet_file.Profile = .{ .io = io };
        emet_file.profile_sink = &prof;
        var rng: [32]u64 = undefined;
        var coll: [32]u64 = undefined;
        var srt: [32]u64 = undefined;
        var fmt: [32]u64 = undefined;
        for (0..32) |k| {
            prof = .{ .io = io };
            _ = try session.search(pattern);
            rng[k] = prof.range_ns;
            coll[k] = prof.collect_ns;
            srt[k] = prof.sort_ns;
            fmt[k] = prof.format_ns;
        }
        emet_file.profile_sink = null;
        std.mem.sort(u64, &rng, {}, std.sort.asc(u64));
        std.mem.sort(u64, &coll, {}, std.sort.asc(u64));
        std.mem.sort(u64, &srt, {}, std.sort.asc(u64));
        std.mem.sort(u64, &fmt, {}, std.sort.asc(u64));

        try out.print("{s:<24} {d:>9} {d:>6} {d:>9.1} {d:>9.1} {d:>9.1} {d:>9.1}  {d:>8.1} {d:>8.1} {d:>8.1} {d:>8.1}\n", .{
            pattern,                       answer.hits,                          answer.files,                  micros(first),
            micros(times[bench_runs / 2]), micros(times[bench_runs * 99 / 100]), micros(times[bench_runs - 1]),
            micros(rng[16]),               micros(coll[16]),                     micros(srt[16]),               micros(fmt[16]),
        });
    }
}

fn since(io: std.Io, t0: Timestamp) u64 {
    return @intCast(t0.durationTo(Timestamp.now(io, .awake)).nanoseconds);
}

fn micros(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_us;
}
