const std = @import("std");
const repo_mod = @import("../platform/repo.zig");
const io_seam = @import("../platform/io_seam.zig");
const fact_store = @import("../platform/fact_store.zig");
const worker_pool = @import("../platform/worker_pool.zig");
const facts_command = @import("facts_command.zig");
const map = @import("../engine/map.zig");
const map_listing = @import("../engine/map_listing.zig");
const map_delta = @import("../engine/map_delta.zig");
const map_region_rank = @import("../engine/map_region_rank.zig");
const map_explore = @import("../engine/map_explore.zig");
const question_lexicon = @import("../engine/question_lexicon.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Command = enum { build, region, files, bench, rank, explore, eval };

pub const Options = struct {
    command: Command,
    region: ?u32 = null,
    offset: u32 = 0,
    budget: usize = map_listing.default_budget,
    map: map.MapOptions = .{},
    out: ?[]const u8 = null,
    persist: bool = true,
    threads: usize = worker_pool.max_threads,
    seed: u64 = 1,
    samples: usize = 200,
    builds: usize = 15,
    updates: usize = 50,
    regions: [map_explore.max_regions]u32 = .{ 0, 0, 0 },
    region_count: usize = 0,
    question: ?[]const u8 = null,
    set: ?[]const u8 = null,
    limit: usize = 20,
    k: u32 = 3,
    list: u32 = 8,
    explore_budget: usize = map_explore.default_budget,
    with_text: bool = false,
};

fn number(comptime T: type, text: []const u8) ?T {
    return std.fmt.parseInt(T, text, 10) catch |err| switch (err) {
        error.Overflow, error.InvalidCharacter => return null,
    };
}

fn real(text: []const u8) ?f64 {
    return std.fmt.parseFloat(f64, text) catch |err| switch (err) {
        error.InvalidCharacter => return null,
    };
}

pub fn regionId(text: []const u8) ?u32 {
    const digits = if (text.len > 1 and (text[0] == 'r' or text[0] == 'R')) text[1..] else text;
    const n = number(u32, digits) orelse return null;
    if (n == 0) return null;
    return n - 1;
}

fn regionList(text: []const u8, options: *Options) bool {
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |piece| {
        if (options.region_count == options.regions.len) return false;
        options.regions[options.region_count] = regionId(std.mem.trim(u8, piece, " ")) orelse return false;
        options.region_count += 1;
    }
    return options.region_count != 0;
}

pub fn parse(args: []const [:0]const u8) ?Options {
    if (args.len == 0) return null;
    var options: Options = .{ .command = std.meta.stringToEnum(Command, args[0]) orelse return null };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.eql(u8, arg, "--no-store")) {
            options.persist = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-children")) {
            options.map.list_children = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--with-text")) {
            options.with_text = true;
            continue;
        }
        if (!std.mem.startsWith(u8, arg, "--")) {
            switch (options.command) {
                .region => {
                    if (options.region != null) return null;
                    options.region = regionId(arg) orelse return null;
                },
                .rank, .explore => {
                    if (options.region_count != 0) return null;
                    if (!regionList(arg, &options)) return null;
                },
                else => return null,
            }
            continue;
        }
        i += 1;
        if (i >= args.len) return null;
        const value: []const u8 = args[i];
        if (std.mem.eql(u8, arg, "--budget-tokens")) {
            options.map.budget_tokens = number(u32, value) orelse return null;
        } else if (std.mem.eql(u8, arg, "--region-chars")) {
            options.map.region_chars = number(u32, value) orelse return null;
        } else if (std.mem.eql(u8, arg, "--term-value")) {
            options.map.term_value = @floatCast(real(value) orelse return null);
        } else if (std.mem.eql(u8, arg, "--damping")) {
            options.map.damping = real(value) orelse return null;
            if (!(options.map.damping >= 0 and options.map.damping < 1)) return null;
        } else if (std.mem.eql(u8, arg, "--file-value")) {
            options.map.file_value = @floatCast(real(value) orelse return null);
        } else if (std.mem.eql(u8, arg, "--chars-per-token")) {
            options.map.chars_per_token = real(value) orelse return null;
            if (!(options.map.chars_per_token > 0)) return null;
        } else if (std.mem.eql(u8, arg, "--offset")) {
            options.offset = number(u32, value) orelse return null;
        } else if (std.mem.eql(u8, arg, "--budget")) {
            options.budget = number(usize, value) orelse return null;
            if (options.budget < map_listing.min_budget) return null;
        } else if (std.mem.eql(u8, arg, "--out")) {
            options.out = value;
        } else if (std.mem.eql(u8, arg, "--threads")) {
            options.threads = number(usize, value) orelse return null;
            if (options.threads == 0) return null;
        } else if (std.mem.eql(u8, arg, "--seed")) {
            options.seed = number(u64, value) orelse return null;
        } else if (std.mem.eql(u8, arg, "--samples")) {
            options.samples = number(usize, value) orelse return null;
        } else if (std.mem.eql(u8, arg, "--builds")) {
            options.builds = number(usize, value) orelse return null;
            if (options.builds == 0) return null;
        } else if (std.mem.eql(u8, arg, "--updates")) {
            options.updates = number(usize, value) orelse return null;
        } else if (std.mem.eql(u8, arg, "--question")) {
            options.question = value;
        } else if (std.mem.eql(u8, arg, "--set")) {
            options.set = value;
        } else if (std.mem.eql(u8, arg, "--limit")) {
            options.limit = number(usize, value) orelse return null;
            if (options.limit == 0) return null;
        } else if (std.mem.eql(u8, arg, "--k")) {
            options.k = number(u32, value) orelse return null;
        } else if (std.mem.eql(u8, arg, "--list")) {
            options.list = number(u32, value) orelse return null;
        } else if (std.mem.eql(u8, arg, "--explore-budget")) {
            options.explore_budget = number(usize, value) orelse return null;
            if (options.explore_budget < map_explore.min_budget) return null;
        } else return null;
    }
    switch (options.command) {
        .region => if (options.region == null) return null,
        .rank => if (options.region_count != 1 or options.question == null) return null,
        .explore => if (options.region_count == 0 or options.question == null) return null,
        .eval => if (options.set == null) return null,
        .build, .files, .bench => {},
    }
    return options;
}

fn nanosSince(clock: io_seam.Clock, from: i96) u64 {
    return @intCast(@max(clock.monotonic() - from, 0));
}

pub fn run(gpa: Allocator, io: std.Io, runtime: *Runtime, options: Options, out: *Writer) !u8 {
    const root = try repo_mod.repoRoot(gpa, io);
    defer gpa.free(root);
    const store_path: ?[]u8 = if (options.persist) try fact_store.defaultStorePath(gpa, root) else null;
    defer if (store_path) |p| gpa.free(p);
    var real_seam = io_seam.Real.init(gpa, io);
    defer real_seam.deinit();
    const seam = real_seam.seam();
    const repo = try fact_store.Repo.open(gpa, seam, runtime, .{ .root_abs = root, .store_path = store_path, .threads = options.threads });
    defer repo.deinit();
    const refreshed = seam.clock.monotonic();
    _ = try repo.refresh();
    const refresh_ns = nanosSince(seam.clock, refreshed);
    var map_options = options.map;
    map_options.cert = repo.snapshot();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (options.command == .bench) return bench(gpa, seam.clock, repo, map_options, options, out);
    const started = seam.clock.monotonic();
    const built = try map.buildMap(arena, &repo.store, map_options);
    const build_ns = nanosSince(seam.clock, started);
    switch (options.command) {
        .build => {
            if (options.out) |path| {
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = built.text });
            } else {
                try out.writeAll(built.text);
                return 0;
            }
            try writeStats(out, built, refresh_ns, build_ns);
            return 0;
        },
        .region => {
            const listed = try map_listing.regionListing(arena, &repo.store, &built, options.region.?, .{
                .snapshot = repo.snapshot(),
                .max_file_bytes = repo.options.max_file_bytes,
                .largest_file_bytes = repo.largestFile(),
            }, .{ .budget = options.budget, .offset = options.offset });
            switch (listed) {
                .complete => |c| try out.writeAll(c.value.text),
                .partial => |p| try out.writeAll(p.value.text),
                .refused => {
                    try listed.writeStatus(out, 0, "symbols");
                    try out.writeByte('\n');
                    return 2;
                },
            }
            return 0;
        },
        .files => {
            try writeFiles(arena, out, built);
            return 0;
        },
        .rank => {
            const lex = try question_lexicon.Lexicon.parse(gpa, question_lexicon.default_text);
            defer lex.deinit();
            const terms = try map_region_rank.Terms.ofQuestion(arena, lex, options.question.?);
            const region = options.regions[0];
            if (region >= built.regions.len) {
                try out.print("refused: UnknownRegion (no region r{d}; the map has r1 to r{d})\n", .{ region + 1, built.regions.len });
                return 2;
            }
            const index = try map_region_rank.Index.build(arena, &repo.store, &built, lex);
            const ranked = try map_region_rank.rankInRegion(arena, &repo.store, &built, region, &terms, .{}, index);
            try out.print("r{d} {s}: {d} functions in {d} files, {d} match\n", .{ region + 1, built.regions[region].path, ranked.candidates, ranked.files, ranked.matched });
            for (ranked.hits[0..@min(options.limit, ranked.hits.len)], 0..) |hit, i| {
                try out.print("{d:>3} {d:.3} {s}  {s}:{d}\n", .{ i + 1, hit.score, hit.qname, hit.path, hit.line });
            }
            return 0;
        },
        .explore => {
            const lex = try question_lexicon.Lexicon.parse(gpa, question_lexicon.default_text);
            defer lex.deinit();
            const terms = try map_region_rank.Terms.ofQuestion(arena, lex, options.question.?);
            const fs = try repo.factStore(arena);
            const index = try map_region_rank.Index.build(arena, &repo.store, &built, lex);
            const explored = try map_explore.explore(&fs, &built, options.regions[0..options.region_count], &terms, .{ .k = options.k, .list = options.list, .budget = options.explore_budget, .index = index });
            switch (explored) {
                .complete => |c| try out.writeAll(c.value.text),
                .partial => |p| try out.writeAll(p.value.text),
                .refused => {
                    try explored.writeStatus(out, 0, "functions shown");
                    try out.writeByte('\n');
                    return 2;
                },
            }
            return 0;
        },
        .eval => return evaluate(gpa, io, seam.clock, repo, &built, options, out),
        .bench => unreachable,
    }
}

const EvalItem = struct {
    id: []const u8,
    text: []const u8,
    regions: []const []const u8 = &.{},
};

const EvalSet = struct {
    questions: []const EvalItem,
};

fn writeExplored(js: *std.json.Stringify, arena: Allocator, explored: map_explore.ExploreAnswer, with_text: bool) !void {
    try js.objectField("explore_status");
    try js.write(@tagName(explored.status()));
    const value = switch (explored) {
        .complete => |c| c.value,
        .partial => |p| p.value,
        .refused => return,
    };
    try js.objectField("explore_chars");
    try js.write(value.text.len);
    try js.objectField("explore_level");
    try js.write(@tagName(value.level));
    try js.objectField("shown");
    try js.beginArray();
    for (value.shown) |s| {
        try js.beginArray();
        try js.write(try std.fmt.allocPrint(arena, "r{d}", .{s.region + 1}));
        try js.write(s.rank + 1);
        try js.write(s.qname);
        try js.endArray();
    }
    try js.endArray();
    if (with_text) {
        try js.objectField("explore_text");
        try js.write(value.text);
    }
}

fn evaluate(gpa: Allocator, io: std.Io, clock: io_seam.Clock, repo: *fact_store.Repo, built: *const map.Map, options: Options, out: *Writer) !u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, options.set.?, gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(bytes);
    const parsed = try std.json.parseFromSlice(EvalSet, gpa, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const lex = try question_lexicon.Lexicon.parse(gpa, question_lexicon.default_text);
    defer lex.deinit();
    var index_arena = std.heap.ArenaAllocator.init(gpa);
    defer index_arena.deinit();
    const index_started = clock.monotonic();
    const index = try map_region_rank.Index.build(index_arena.allocator(), &repo.store, built, lex);
    const index_ns = nanosSince(clock, index_started);
    for (parsed.value.questions) |item| {
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const terms = try map_region_rank.Terms.ofQuestion(arena, lex, item.text);
        var ids: std.ArrayList(map.RegionId) = .empty;
        for (item.regions) |text| {
            const id = regionId(text) orelse continue;
            if (id < built.regions.len) try ids.append(arena, id);
        }
        var js: std.json.Stringify = .{ .writer = out };
        try js.beginObject();
        try js.objectField("id");
        try js.write(item.id);
        try js.objectField("index_ms");
        try js.write(@as(f64, @floatFromInt(index_ns)) / 1e6);
        try js.objectField("concepts");
        try js.beginArray();
        for (terms.concepts) |c| {
            try js.beginArray();
            for (c.alternatives) |alt| try js.write(alt);
            try js.endArray();
        }
        try js.endArray();
        try js.objectField("rankings");
        try js.beginArray();
        for (ids.items) |id| {
            const started = clock.monotonic();
            const ranked = try map_region_rank.rankInRegion(arena, &repo.store, built, id, &terms, .{}, index);
            const spent = nanosSince(clock, started);
            try js.beginObject();
            try js.objectField("region");
            try js.write(try std.fmt.allocPrint(arena, "r{d}", .{id + 1}));
            try js.objectField("candidates");
            try js.write(ranked.candidates);
            try js.objectField("matched");
            try js.write(ranked.matched);
            try js.objectField("files");
            try js.write(ranked.files);
            try js.objectField("rank_ms");
            try js.write(@as(f64, @floatFromInt(spent)) / 1e6);
            try js.objectField("hits");
            try js.beginArray();
            for (ranked.hits[0..@min(options.limit, ranked.hits.len)]) |hit| {
                try js.beginArray();
                try js.write(hit.qname);
                try js.write(hit.path);
                try js.write(hit.line);
                try js.write(hit.score);
                try js.endArray();
            }
            try js.endArray();
            try js.endObject();
        }
        try js.endArray();
        if (ids.items.len != 0 and ids.items.len <= map_explore.max_regions) {
            const fs = try repo.factStore(arena);
            const started = clock.monotonic();
            const explored = try map_explore.explore(&fs, built, ids.items, &terms, .{ .k = options.k, .list = options.list, .budget = options.explore_budget, .index = index });
            const spent = nanosSince(clock, started);
            try js.objectField("explore_ms");
            try js.write(@as(f64, @floatFromInt(spent)) / 1e6);
            try writeExplored(&js, arena, explored, options.with_text);
        }
        try js.endObject();
        try out.writeByte('\n');
    }
    return 0;
}

fn writeStats(out: *Writer, built: map.Map, refresh_ns: u64, build_ns: u64) !void {
    var js: std.json.Stringify = .{ .writer = out };
    try js.beginObject();
    inline for (@typeInfo(map.Stats).@"struct".fields) |field| {
        try js.objectField(field.name);
        try js.write(@field(built.stats, field.name));
    }
    try js.objectField("refresh_ms");
    try js.write(@as(f64, @floatFromInt(refresh_ns)) / 1e6);
    try js.objectField("build_ms");
    try js.write(@as(f64, @floatFromInt(build_ns)) / 1e6);
    try js.objectField("text_sha256");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(built.text, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try js.write(hex[0..]);
    try js.endObject();
    try out.writeByte('\n');
}

fn writeFiles(arena: Allocator, out: *Writer, built: map.Map) !void {
    for (built.regions) |r| {
        var js: std.json.Stringify = .{ .writer = out };
        try js.beginObject();
        try js.objectField("region");
        try js.write(try std.fmt.allocPrint(arena, "r{d}", .{r.id + 1}));
        try js.objectField("path");
        try js.write(r.path);
        try js.objectField("family");
        try js.write(@tagName(r.family));
        try js.objectField("files");
        try js.write(r.files.len);
        try js.objectField("symbols");
        try js.write(r.symbols.len);
        try js.objectField("listing_chars");
        try js.write(r.listing_chars);
        try js.endObject();
        try out.writeByte('\n');
    }
    for (built.snapshot.files) |f| {
        var js: std.json.Stringify = .{ .writer = out };
        try js.beginObject();
        try js.objectField("file");
        try js.write(f.path);
        try js.objectField("region");
        try js.write(try std.fmt.allocPrint(arena, "r{d}", .{f.region + 1}));
        try js.objectField("symbols");
        try js.beginArray();
        for (f.symbols) |s| try js.write(s.qname);
        try js.endArray();
        try js.objectField("lines");
        try js.beginArray();
        for (f.symbols) |s| try js.write(s.line);
        try js.endArray();
        try js.objectField("spans");
        try js.beginArray();
        for (f.symbols) |s| {
            try js.beginArray();
            try js.write(s.span.start);
            try js.write(s.span.end);
            try js.endArray();
        }
        try js.endArray();
        try js.endObject();
        try out.writeByte('\n');
    }
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

fn writeTimes(js: *std.json.Stringify, name: []const u8, samples: []u64) !void {
    const p = Percentiles.of(samples);
    try js.objectField(name);
    try js.beginObject();
    try js.objectField("count");
    try js.write(samples.len);
    try js.objectField("p50_ms");
    try js.write(@as(f64, @floatFromInt(p.p50)) / 1e6);
    try js.objectField("p99_ms");
    try js.write(@as(f64, @floatFromInt(p.p99)) / 1e6);
    try js.objectField("max_ms");
    try js.write(@as(f64, @floatFromInt(p.max)) / 1e6);
    try js.endObject();
}

fn bench(gpa: Allocator, clock: io_seam.Clock, repo: *fact_store.Repo, map_options: map.MapOptions, options: Options, out: *Writer) !u8 {
    var keep = std.heap.ArenaAllocator.init(gpa);
    defer keep.deinit();
    const build_ns = try keep.allocator().alloc(u64, options.builds);
    var built: map.Map = undefined;
    for (build_ns, 0..) |*slot, i| {
        var scratch = std.heap.ArenaAllocator.init(gpa);
        const started = clock.monotonic();
        const candidate = map.buildMap(if (i + 1 == options.builds) keep.allocator() else scratch.allocator(), &repo.store, map_options) catch |err| {
            scratch.deinit();
            return err;
        };
        slot.* = nanosSince(clock, started);
        if (i + 1 == options.builds) built = candidate;
        scratch.deinit();
    }
    var prng = std.Random.DefaultPrng.init(options.seed);
    const random = prng.random();
    const listing_ns = try keep.allocator().alloc(u64, @min(options.samples, built.regions.len * 4));
    var listed_chars: u64 = 0;
    var partial: usize = 0;
    for (listing_ns) |*slot| {
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        const region: map.RegionId = random.uintLessThan(u32, @intCast(built.regions.len));
        const started = clock.monotonic();
        const listed = try map_listing.regionListing(scratch.allocator(), &repo.store, &built, region, .{ .snapshot = repo.snapshot(), .max_file_bytes = repo.options.max_file_bytes, .largest_file_bytes = repo.largestFile() }, .{ .budget = options.budget });
        slot.* = nanosSince(clock, started);
        switch (listed) {
            .complete => |c| listed_chars += c.value.text.len,
            .partial => |p| {
                listed_chars += p.value.text.len;
                partial += 1;
            },
            .refused => return error.ListingRefused,
        }
    }
    var indexed: std.ArrayList(u32) = .empty;
    for (repo.store.files.items, 0..) |state, id| {
        if (state.status == .indexed) try indexed.append(keep.allocator(), @intCast(id));
    }
    const delta_ns = try keep.allocator().alloc(u64, options.updates);
    const unchanged_ns = try keep.allocator().alloc(u64, options.updates + 1);
    var delta_chars: u64 = 0;
    var summarized: usize = 0;
    {
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        const started = clock.monotonic();
        _ = try map_delta.mapDelta(scratch.allocator(), &repo.store, &built);
        unchanged_ns[0] = nanosSince(clock, started);
    }
    var u: usize = 0;
    while (u < options.updates and indexed.items.len != 0) : (u += 1) {
        const id = indexed.items[random.uintLessThan(usize, indexed.items.len)];
        const path = try keep.allocator().dupe(u8, repo.store.file(id).path);
        const abs = try std.fmt.allocPrint(keep.allocator(), "{s}\\{s}", .{ repo.options.root_abs, path });
        const original = try repo.fs.readFile(abs, gpa, repo.options.max_file_bytes);
        defer gpa.free(original);
        const edited = try std.fmt.allocPrint(gpa, "{s}\nexport function benchAddedSymbol{d}() {{ return {d}; }}\n", .{ original, u, u });
        defer gpa.free(edited);
        for ([_][]const u8{ edited, original }, 0..) |bytes, phase| {
            _ = try repo.updateSource(path, bytes);
            var scratch = std.heap.ArenaAllocator.init(gpa);
            defer scratch.deinit();
            const started = clock.monotonic();
            const delta = try map_delta.mapDelta(scratch.allocator(), &repo.store, &built);
            const spent = nanosSince(clock, started);
            if (phase == 0) {
                delta_ns[u] = spent;
                delta_chars = @max(delta_chars, delta.text.len);
                if (delta.summarized) summarized += 1;
                if (delta.added == 0) return error.DeltaMissedAnEdit;
            } else {
                unchanged_ns[u + 1] = spent;
                if (!delta.unchanged) return error.DeltaAfterRestore;
            }
        }
    }
    var sizes: std.ArrayList(u64) = .empty;
    var files_per_region: std.ArrayList(u64) = .empty;
    for (built.regions) |r| {
        try sizes.append(keep.allocator(), r.listing_chars);
        try files_per_region.append(keep.allocator(), r.files.len);
    }
    var js: std.json.Stringify = .{ .writer = out, .options = .{ .whitespace = .indent_2 } };
    try js.beginObject();
    inline for (@typeInfo(map.Stats).@"struct".fields) |field| {
        try js.objectField(field.name);
        try js.write(@field(built.stats, field.name));
    }
    try writeTimes(&js, "build", build_ns);
    try writeTimes(&js, "listing", listing_ns);
    try writeTimes(&js, "delta", delta_ns[0..u]);
    try writeTimes(&js, "delta_unchanged", unchanged_ns[0 .. u + 1]);
    try js.objectField("listing_partial");
    try js.write(partial);
    try js.objectField("listing_mean_chars");
    try js.write(if (listing_ns.len == 0) 0 else listed_chars / listing_ns.len);
    try js.objectField("delta_max_chars");
    try js.write(delta_chars);
    try js.objectField("delta_summarized");
    try js.write(summarized);
    const size_p = Percentiles.of(sizes.items);
    try js.objectField("region_listing_chars");
    try js.beginObject();
    try js.objectField("p50");
    try js.write(size_p.p50);
    try js.objectField("p99");
    try js.write(size_p.p99);
    try js.objectField("max");
    try js.write(size_p.max);
    try js.endObject();
    const files_p = Percentiles.of(files_per_region.items);
    try js.objectField("region_files");
    try js.beginObject();
    try js.objectField("p50");
    try js.write(files_p.p50);
    try js.objectField("p99");
    try js.write(files_p.p99);
    try js.objectField("max");
    try js.write(files_p.max);
    try js.endObject();
    try js.objectField("peak_working_set_bytes");
    try js.write(facts_command.peakWorkingSetBytes());
    try js.endObject();
    try out.writeByte('\n');
    return 0;
}
