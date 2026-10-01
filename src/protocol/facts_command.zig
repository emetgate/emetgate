const std = @import("std");
const repo_mod = @import("../platform/repo.zig");
const io_seam = @import("../platform/io_seam.zig");
const fact_store = @import("../platform/fact_store.zig");
const worker_pool = @import("../platform/worker_pool.zig");
const facts_query = @import("../engine/facts_query.zig");
const facts_evidence = @import("../engine/facts_evidence.zig");
const symbol = @import("../engine/symbol.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Command = enum { build, callers, callees, defined_at, refs, bench, modules, defs };

pub const Options = struct {
    command: Command,
    subject: []const u8 = "",
    file: ?[]const u8 = null,
    depth: u32 = 1,
    budget: usize = facts_evidence.default_budget,
    threads: usize = worker_pool.max_threads,
    persist: bool = true,
    json: bool = false,
    seed: u64 = 1,
    samples: usize = 200,
    updates: usize = 50,
};

fn number(comptime T: type, text: []const u8) ?T {
    return std.fmt.parseInt(T, text, 10) catch |err| switch (err) {
        error.Overflow, error.InvalidCharacter => return null,
    };
}

pub fn parse(args: []const [:0]const u8) ?Options {
    if (args.len == 0) return null;
    var options: Options = .{ .command = std.meta.stringToEnum(Command, args[0]) orelse return null };
    var positional: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            options.json = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-store")) {
            options.persist = false;
            continue;
        }
        if (!std.mem.startsWith(u8, arg, "--")) {
            if (positional != null) return null;
            positional = arg;
            continue;
        }
        i += 1;
        if (i >= args.len) return null;
        const value: []const u8 = args[i];
        if (std.mem.eql(u8, arg, "--threads")) {
            options.threads = number(usize, value) orelse return null;
            if (options.threads == 0) return null;
        } else if (std.mem.eql(u8, arg, "--file")) {
            options.file = value;
        } else if (std.mem.eql(u8, arg, "--depth")) {
            options.depth = number(u32, value) orelse return null;
        } else if (std.mem.eql(u8, arg, "--budget")) {
            options.budget = number(usize, value) orelse return null;
            if (options.budget < facts_evidence.min_budget) return null;
        } else if (std.mem.eql(u8, arg, "--seed")) {
            options.seed = number(u64, value) orelse return null;
        } else if (std.mem.eql(u8, arg, "--samples")) {
            options.samples = number(usize, value) orelse return null;
        } else if (std.mem.eql(u8, arg, "--updates")) {
            options.updates = number(usize, value) orelse return null;
        } else return null;
    }
    switch (options.command) {
        .build, .bench, .modules, .defs => if (positional != null) return null,
        else => options.subject = positional orelse return null,
    }
    return options;
}

pub fn run(gpa: Allocator, io: std.Io, runtime: *Runtime, options: Options, out: *Writer) !u8 {
    const root = try repo_mod.repoRoot(gpa, io);
    defer gpa.free(root);
    const store_path: ?[]u8 = if (options.persist) try fact_store.defaultStorePath(gpa, root) else null;
    defer if (store_path) |p| gpa.free(p);
    var real = io_seam.Real.init(gpa, io);
    defer real.deinit();
    const seam = real.seam();
    const repo = try fact_store.Repo.open(gpa, seam, runtime, .{ .root_abs = root, .store_path = store_path, .threads = options.threads });
    defer repo.deinit();
    const refreshed = seam.clock.monotonic();
    const report = try repo.refresh();
    const refresh_us = microsSince(seam.clock, refreshed);
    switch (options.command) {
        .build => {
            try writeReport(out, repo, report, options.json);
            return 0;
        },
        .bench => return bench(gpa, seam.clock, repo, options, out),
        .modules => return modules(repo, options, out),
        .defs => return defs(repo, options, out),
        else => return query(gpa, seam.clock, repo, options, refresh_us, out),
    }
}

fn microsSince(clock: io_seam.Clock, from: i96) u64 {
    return @intCast(@divTrunc(@max(clock.monotonic() - from, 0), std.time.ns_per_us));
}

fn relationOf(command: Command) facts_query.Relation {
    return switch (command) {
        .callers => .callers,
        .callees => .callees,
        .defined_at => .defined_at,
        .refs => .refs,
        .build, .bench, .modules, .defs => unreachable,
    };
}

fn query(gpa: Allocator, clock: io_seam.Clock, repo: *fact_store.Repo, options: Options, refresh_us: u64, out: *Writer) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const request: facts_query.Request = .{ .relation = relationOf(options.command), .subject = options.subject, .path = options.file, .depth = options.depth };
    const started = clock.monotonic();
    const result = try repo.query(arena, request);
    const query_ns = clock.monotonic() - started;
    if (options.json) {
        try writeJson(out, result, refresh_us, query_ns);
        return exitCode(result);
    }
    var lines: fact_store.SourceLines = .{ .repo = repo, .arena = arena };
    _ = try facts_evidence.render(arena, out, result, lines.source(), options.budget);
    try out.writeByte('\n');
    return exitCode(result);
}

fn modules(repo: *fact_store.Repo, options: Options, out: *Writer) !u8 {
    const prefix = options.file orelse "";
    for (repo.store.files.items) |state| {
        if (state.status != .indexed or !std.mem.startsWith(u8, state.path, prefix)) continue;
        for (state.facts.specs, state.spec_targets) |spec, target| {
            var js: std.json.Stringify = .{ .writer = out };
            try js.beginObject();
            try js.objectField("file");
            try js.write(state.path);
            try js.objectField("spec");
            try js.write(spec.text);
            try js.objectField("target");
            switch (target) {
                .file => |id| try js.write(repo.store.file(id).path),
                else => try js.write(null),
            }
            try js.objectField("status");
            try js.write(@tagName(target));
            try js.endObject();
            try out.writeByte('\n');
        }
    }
    return 0;
}

fn defs(repo: *fact_store.Repo, options: Options, out: *Writer) !u8 {
    const prefix = options.file orelse "";
    for (repo.store.files.items) |state| {
        if (state.status != .indexed or !std.mem.startsWith(u8, state.path, prefix)) continue;
        for (state.facts.defs) |d| {
            if (d.kind == .module) continue;
            var js: std.json.Stringify = .{ .writer = out };
            try js.beginObject();
            try js.objectField("path");
            try js.write(state.path);
            try js.objectField("qname");
            try js.write(d.qname);
            try js.objectField("name");
            try js.write(d.name);
            try js.objectField("kind");
            try js.write(@tagName(d.kind));
            try js.objectField("line");
            try js.write(d.line);
            try js.objectField("name_start");
            try js.write(d.name_start);
            try js.objectField("exported");
            try js.write(d.exported);
            try js.objectField("parse_errors");
            try js.write(state.facts.parse_errors);
            try js.endObject();
            try out.writeByte('\n');
        }
    }
    return 0;
}

fn exitCode(result: facts_query.FactsAnswer) u8 {
    return switch (result) {
        .complete, .partial => 0,
        .refused => 2,
    };
}

fn writeOwner(js: *std.json.Stringify, owner: facts_query.Owner) !void {
    try js.beginObject();
    try js.objectField("qname");
    try js.write(owner.qname);
    try js.objectField("kind");
    try js.write(@tagName(owner.kind));
    try js.objectField("hash");
    const hex = symbol.formatHash(owner.hash);
    try js.write(hex[0..]);
    try js.objectField("line");
    try js.write(owner.line);
    try js.endObject();
}

fn writeJson(out: *Writer, result: facts_query.FactsAnswer, refresh_us: u64, query_ns: i96) !void {
    var js: std.json.Stringify = .{ .writer = out };
    try js.beginObject();
    try js.objectField("certificate");
    try result.writeCertificate(&js);
    try js.objectField("refresh_us");
    try js.write(refresh_us);
    try js.objectField("query_ns");
    try js.write(@as(i64, @intCast(query_ns)));
    const value: ?facts_query.Edges = switch (result) {
        .complete => |c| c.value,
        .partial => |p| p.value,
        .refused => null,
    };
    if (value) |v| {
        try js.objectField("subjects");
        try js.beginArray();
        for (v.subjects) |s| {
            try js.beginObject();
            try js.objectField("path");
            try js.write(s.path);
            try js.objectField("qname");
            try js.write(s.qname);
            try js.objectField("kind");
            try js.write(@tagName(s.kind));
            try js.objectField("line");
            try js.write(s.line);
            try js.objectField("hash");
            const hex = symbol.formatHash(s.hash);
            try js.write(hex[0..]);
            try js.endObject();
        }
        try js.endArray();
        try js.objectField("sites");
        try js.beginArray();
        for (v.sites) |site| {
            try js.beginObject();
            try js.objectField("path");
            try js.write(site.path);
            try js.objectField("line");
            try js.write(site.line);
            try js.objectField("start");
            try js.write(site.start);
            try js.objectField("kind");
            try js.write(@tagName(site.kind));
            try js.objectField("name");
            try js.write(site.name);
            try js.objectField("certainty");
            try js.write(@tagName(site.certainty));
            try js.objectField("depth");
            try js.write(site.depth);
            try js.objectField("target");
            try js.write(site.target.qname);
            try js.objectField("owner");
            try writeOwner(&js, site.owner);
            try js.endObject();
        }
        try js.endArray();
        try js.objectField("unknown");
        try js.beginArray();
        for (v.unknown) |u| {
            try js.beginObject();
            try js.objectField("path");
            try js.write(u.path);
            try js.objectField("line");
            try js.write(u.line);
            try js.objectField("start");
            try js.write(u.start);
            try js.objectField("kind");
            try js.write(@tagName(u.kind));
            try js.objectField("name");
            try js.write(u.name);
            try js.objectField("reason");
            try js.write(@tagName(u.reason));
            try js.objectField("rule");
            try js.write(@tagName(u.rule));
            try js.objectField("owner");
            try writeOwner(&js, u.owner);
            try js.endObject();
        }
        try js.endArray();
        try js.objectField("unread");
        try js.beginArray();
        for (v.unread) |f| {
            try js.beginObject();
            try js.objectField("path");
            try js.write(f.path);
            try js.objectField("status");
            try js.write(@tagName(f.status));
            try js.objectField("parse_errors");
            try js.write(f.parse_errors);
            try js.endObject();
        }
        try js.endArray();
        try js.objectField("outside");
        try js.write(v.outside.len);
    }
    try js.endObject();
    try out.writeByte('\n');
}

const Percentiles = struct {
    p50: u64,
    p99: u64,
    max: u64,

    fn of(samples: []u64) Percentiles {
        if (samples.len == 0) return .{ .p50 = 0, .p99 = 0, .max = 0 };
        std.mem.sort(u64, samples, {}, std.sort.asc(u64));
        return .{ .p50 = samples[samples.len / 2], .p99 = samples[@min(samples.len - 1, samples.len * 99 / 100)], .max = samples[samples.len - 1] };
    }
};

const Tally = struct { complete: usize = 0, partial: usize = 0, refused: usize = 0 };

fn tally(t: *Tally, result: facts_query.FactsAnswer) void {
    switch (result) {
        .complete => t.complete += 1,
        .partial => t.partial += 1,
        .refused => t.refused += 1,
    }
}

const Sampled = struct { qname: []const u8, name: []const u8, path: []const u8 };

fn sampleSubjects(arena: Allocator, repo: *fact_store.Repo, seed: u64, count: usize) ![]Sampled {
    var pool: std.ArrayList(Sampled) = .empty;
    for (repo.store.files.items) |state| {
        if (state.status != .indexed) continue;
        for (state.facts.defs) |d| {
            if (!d.kind.callable() or d.qname.len == 0) continue;
            try pool.append(arena, .{ .qname = d.qname, .name = d.name, .path = state.path });
        }
    }
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const picked = try arena.alloc(Sampled, @min(count, pool.items.len));
    for (picked) |*slot| slot.* = pool.items[random.uintLessThan(usize, pool.items.len)];
    return picked;
}

pub fn peakWorkingSetBytes() u64 {
    var counters: win.ProcessMemoryCounters = std.mem.zeroes(win.ProcessMemoryCounters);
    counters.cb = @sizeOf(win.ProcessMemoryCounters);
    if (win.K32GetProcessMemoryInfo(win.GetCurrentProcess(), &counters, counters.cb) == .FALSE) return 0;
    return counters.peak_working_set;
}

const win = struct {
    const windows = std.os.windows;
    const ProcessMemoryCounters = extern struct {
        cb: u32,
        page_fault_count: u32,
        peak_working_set: usize,
        working_set: usize,
        quota_peak_paged_pool: usize,
        quota_paged_pool: usize,
        quota_peak_non_paged_pool: usize,
        quota_non_paged_pool: usize,
        pagefile_usage: usize,
        peak_pagefile_usage: usize,
    };
    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn K32GetProcessMemoryInfo(process: windows.HANDLE, counters: *ProcessMemoryCounters, cb: u32) callconv(.winapi) windows.BOOL;
};

fn writeMicros(js: *std.json.Stringify, field: []const u8, ns: u64) !void {
    try js.objectField(field);
    try js.write(@as(f64, @floatFromInt(ns)) / 1000.0);
}

fn bench(gpa: Allocator, clock: io_seam.Clock, repo: *fact_store.Repo, options: Options, out: *Writer) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const subjects = try sampleSubjects(arena, repo, options.seed, options.samples);
    const relations = [_]facts_query.Relation{ .callers, .callees, .defined_at, .refs };
    var timings: [relations.len][]u64 = undefined;
    var tallies: [relations.len]Tally = @splat(.{});
    for (relations, 0..) |relation, r| {
        timings[r] = try arena.alloc(u64, subjects.len);
        for (subjects, timings[r]) |s, *slot| {
            var scratch = std.heap.ArenaAllocator.init(gpa);
            defer scratch.deinit();
            const request: facts_query.Request = if (relation == .defined_at)
                .{ .relation = relation, .subject = s.name }
            else
                .{ .relation = relation, .subject = s.qname, .path = s.path };
            const started = clock.monotonic();
            const result = try repo.query(scratch.allocator(), request);
            slot.* = @intCast(clock.monotonic() - started);
            tally(&tallies[r], result);
        }
    }
    const render_ns = try arena.alloc(u64, subjects.len);
    for (subjects, render_ns) |s, *slot| {
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        const result = try repo.query(scratch.allocator(), .{ .relation = .callers, .subject = s.qname, .path = s.path });
        var lines: fact_store.SourceLines = .{ .repo = repo, .arena = scratch.allocator() };
        var sink: Writer.Allocating = .init(scratch.allocator());
        const started = clock.monotonic();
        _ = try facts_evidence.render(scratch.allocator(), &sink.writer, result, lines.source(), facts_evidence.default_budget);
        slot.* = @intCast(clock.monotonic() - started);
    }
    var update_ns: std.ArrayList(u64) = .empty;
    var reshaped: usize = 0;
    var relinked: usize = 0;
    var prng = std.Random.DefaultPrng.init(options.seed ^ 0x9e3779b97f4a7c15);
    const random = prng.random();
    var indexed: std.ArrayList(u32) = .empty;
    for (repo.store.files.items, 0..) |state, id| {
        if (state.status == .indexed) try indexed.append(arena, @intCast(id));
    }
    var u: usize = 0;
    while (u < options.updates and indexed.items.len != 0) : (u += 1) {
        const id = indexed.items[random.uintLessThan(usize, indexed.items.len)];
        const path = try arena.dupe(u8, repo.store.file(id).path);
        const abs = try std.fmt.allocPrint(arena, "{s}\\{s}", .{ repo.options.root_abs, path });
        const original = try repo.fs.readFile(abs, gpa, repo.options.max_file_bytes);
        defer gpa.free(original);
        const edited = try std.fmt.allocPrint(gpa, "\n{s}", .{original});
        defer gpa.free(edited);
        for ([_][]const u8{ edited, original }) |bytes| {
            const started = clock.monotonic();
            const update = try repo.updateSource(path, bytes);
            try update_ns.append(arena, @intCast(clock.monotonic() - started));
            if (update.reshaped) reshaped += 1;
            relinked += update.relinked;
        }
    }
    const s = repo.store.stats();
    var js: std.json.Stringify = .{ .writer = out, .options = .{ .whitespace = if (options.json) .minified else .indent_2 } };
    try js.beginObject();
    try js.objectField("files");
    try js.write(s.files);
    try js.objectField("defs");
    try js.write(s.defs);
    try js.objectField("refs");
    try js.write(s.refs);
    try js.objectField("samples");
    try js.write(subjects.len);
    try js.objectField("seed");
    try js.write(options.seed);
    for (relations, 0..) |relation, r| {
        const p = Percentiles.of(timings[r]);
        try js.objectField(@tagName(relation));
        try js.beginObject();
        try writeMicros(&js, "p50_us", p.p50);
        try writeMicros(&js, "p99_us", p.p99);
        try writeMicros(&js, "max_us", p.max);
        try js.objectField("complete");
        try js.write(tallies[r].complete);
        try js.objectField("partial");
        try js.write(tallies[r].partial);
        try js.objectField("refused");
        try js.write(tallies[r].refused);
        try js.endObject();
    }
    const rp = Percentiles.of(render_ns);
    try js.objectField("evidence_render");
    try js.beginObject();
    try writeMicros(&js, "p50_us", rp.p50);
    try writeMicros(&js, "p99_us", rp.p99);
    try js.endObject();
    const up = Percentiles.of(update_ns.items);
    try js.objectField("update");
    try js.beginObject();
    try js.objectField("count");
    try js.write(update_ns.items.len);
    try writeMicros(&js, "p50_us", up.p50);
    try writeMicros(&js, "p99_us", up.p99);
    try writeMicros(&js, "max_us", up.max);
    try js.objectField("reshaped");
    try js.write(reshaped);
    try js.objectField("relinked_files");
    try js.write(relinked);
    try js.endObject();
    try js.objectField("peak_working_set_bytes");
    try js.write(peakWorkingSetBytes());
    try js.endObject();
    try out.writeByte('\n');
    return 0;
}

fn loadText(load: fact_store.Load) []const u8 {
    return switch (load) {
        .absent => "absent",
        .loaded => "loaded",
        .rebuilt => |why| why,
    };
}

pub fn writeReport(out: *Writer, repo: *fact_store.Repo, report: fact_store.Report, json: bool) !void {
    const s = repo.store.stats();
    if (json) {
        var js: std.json.Stringify = .{ .writer = out };
        try js.beginObject();
        inline for (.{ "listed", "in_scope", "extracted", "reused", "rehashed", "removed", "relinked", "stat_failures", "config_notes", "load_ms", "list_ms", "stat_ms", "extract_ms", "link_ms", "save_ms", "store_bytes", "read_cpu_ms", "parse_cpu_ms", "extract_cpu_ms", "clone_cpu_ms" }) |field| {
            try js.objectField(field);
            try js.write(@field(report, field));
        }
        try js.objectField("full_link");
        try js.write(report.full_link);
        try js.objectField("saved");
        try js.write(report.saved);
        try js.objectField("load");
        try js.write(loadText(report.load));
        inline for (.{ "files", "indexed", "unindexed", "unreadable", "parse_errors", "defs", "refs", "resolved", "typed", "unresolved" }) |field| {
            try js.objectField(field);
            try js.write(@field(s, field));
        }
        try js.objectField("barrier");
        try js.write(repo.barrier);
        try js.objectField("peak_working_set_bytes");
        try js.write(peakWorkingSetBytes());
        try js.endObject();
        try out.writeByte('\n');
        return;
    }
    try out.print("files {d} in scope of {d} tracked: {d} indexed, {d} unindexed, {d} unreadable, {d} with parse errors\n", .{ report.in_scope, report.listed, s.indexed, s.unindexed, s.unreadable, s.parse_errors });
    try out.print("defs {d}, refs {d}: {d} resolved ({d} typed), {d} unresolved\n", .{ s.defs, s.refs, s.resolved, s.typed, s.unresolved });
    try out.print("refresh: {d} extracted, {d} reused, {d} rehashed, {d} removed, {d} relinked{s}; store {s}\n", .{ report.extracted, report.reused, report.rehashed, report.removed, report.relinked, if (report.full_link) " (full link)" else "", loadText(report.load) });
    try out.print("ms: load {d}, list {d}, stat {d}, extract {d}, link {d}, save {d}; store bytes {d}\n", .{ report.load_ms, report.list_ms, report.stat_ms, report.extract_ms, report.link_ms, report.save_ms, report.store_bytes });
    try out.print("cpu ms across workers: read {d}, parse {d}, extract {d}, clone {d}\n", .{ report.read_cpu_ms, report.parse_cpu_ms, report.extract_cpu_ms, report.clone_cpu_ms });
    try out.print("peak working set {d} MiB\n", .{peakWorkingSetBytes() / (1024 * 1024)});
    if (report.stat_failures != 0) try out.print("warning: {d} directories could not be listed; their files were read again\n", .{report.stat_failures});
    if (report.config_notes != 0) try out.print("warning: {d} package or tsconfig files could not be read\n", .{report.config_notes});
}
