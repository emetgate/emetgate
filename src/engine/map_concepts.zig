const std = @import("std");
const facts = @import("facts.zig");
const map_terms = @import("map_terms.zig");

const Allocator = std.mem.Allocator;

pub const Options = struct {
    tf_power: f64 = 0.5,
    idf_power: f64 = 1,
    root_weight: f64 = 0,
    quota_power: f64 = 0,
    by_dirs: bool = true,
    terms: bool = true,
    plural_only: bool = true,
    min_term_chars: u32 = 4,
    min_term_count: u32 = 2,
    space_separated: bool = false,
    space_children: bool = false,
};

pub const File = struct {
    path: []const u8,
    region: u32,
    defs: []const facts.Def,
};

pub const Kind = enum { dir, root, term };

pub const RegionLine = struct {
    line: ?[]const u8,
    dir: []const u8 = "",
};

pub const Item = struct {
    region: u32,
    kind: Kind,
    text: []const u8,
    value: f64,
};

pub const Plan = struct {
    items: []const Item,
    candidates: []const map_terms.Candidate,
    weights: []const f64,
    base: []const f32,
    regions: u32,
    elements: u32,
    mass: []const f64 = &.{},
    quota_power: f64 = 0,
};

pub fn fileRoot(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const base = if (slash) |s| path[s + 1 ..] else path;
    if (base.len == 0 or base[0] == '.') return base;
    const dot = std.mem.indexOfScalar(u8, base, '.') orelse return base;
    return base[0..dot];
}

fn relativeDir(path: []const u8, dir: []const u8) []const u8 {
    const rel = if (std.mem.startsWith(u8, path, dir)) path[dir.len..] else path;
    const slash = std.mem.lastIndexOfScalar(u8, rel, '/') orelse return "";
    return rel[0 .. slash + 1];
}

fn parentDir(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "";
    return path[0 .. slash + 1];
}

fn callables(defs: []const facts.Def) u32 {
    var n: u32 = 0;
    for (defs) |d| {
        if (d.kind != .module and d.kind.callable()) n += 1;
    }
    return n;
}

const StemSink = struct {
    stems: *map_terms.Stems,
    out: *std.ArrayList(u32),
    arena: Allocator,

    pub fn part(self: *StemSink, text: []const u8) !void {
        if (map_terms.isStop(text)) return;
        const id = try self.stems.intern(text);
        if (std.mem.indexOfScalar(u32, self.out.items, id) != null) return;
        try self.out.append(self.arena, id);
    }
};

const Row = struct {
    region: u32,
    stem: u32,
};

fn rowLess(_: void, a: Row, b: Row) bool {
    if (a.region != b.region) return a.region < b.region;
    return a.stem < b.stem;
}

fn key(region: u32, stem: u32) u64 {
    return (@as(u64, region) << 32) | stem;
}

fn idfOf(regions: u32, df: u32) f64 {
    if (regions <= 1 or df == 0) return 1;
    const n: f64 = @floatFromInt(regions);
    const d: f64 = @floatFromInt(df);
    return @max(0, @log(n / d) / @log(n));
}

fn allIn(words: []const u32, shown: []const u32) bool {
    for (words) |w| {
        if (std.mem.indexOfScalar(u32, shown, w) == null) return false;
    }
    return true;
}

const Builder = struct {
    arena: Allocator,
    options: Options,
    lines: []const RegionLine,
    stems: map_terms.Stems,
    line_stems: []const []const u32 = &.{},
    element_of: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    weights: std.ArrayList(f64) = .empty,
    base: std.ArrayList(f32) = .empty,
    items: std.ArrayList(Item) = .empty,
    candidates: std.ArrayList(map_terms.Candidate) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    root_element: std.StringHashMapUnmanaged(u32) = .empty,
    dir_ids: std.StringHashMapUnmanaged(u32) = .empty,
    root_dirs: std.StringHashMapUnmanaged(u32) = .empty,
    root_dir_pairs: std.StringHashMapUnmanaged(void) = .empty,

    fn dirId(self: *Builder, path: []const u8) !u32 {
        const entry = try self.dir_ids.getOrPut(self.arena, parentDir(path));
        if (!entry.found_existing) entry.value_ptr.* = @intCast(self.dir_ids.count() - 1);
        return entry.value_ptr.*;
    }

    fn noteRootDir(self: *Builder, path: []const u8) !void {
        const pair = try std.fmt.allocPrint(self.arena, "{s}\x00{s}", .{ fileRoot(path), parentDir(path) });
        const entry = try self.root_dir_pairs.getOrPut(self.arena, pair);
        if (entry.found_existing) return;
        const count = try self.root_dirs.getOrPut(self.arena, fileRoot(path));
        if (!count.found_existing) count.value_ptr.* = 0;
        count.value_ptr.* += 1;
    }

    fn spread(self: *const Builder, regions: u32, region_df: u32, dir_df: u32) f64 {
        if (self.options.by_dirs) return idfOf(self.dir_ids.count(), dir_df);
        return idfOf(regions, region_df);
    }

    fn stemsOf(self: *Builder, text: []const u8) ![]u32 {
        var out: std.ArrayList(u32) = .empty;
        var sink: StemSink = .{ .stems = &self.stems, .out = &out, .arena = self.arena };
        try map_terms.eachPart(text, &sink);
        return out.items;
    }

    fn element(self: *Builder, weight: f64, shown: bool) !u32 {
        const e: u32 = @intCast(self.weights.items.len);
        try self.weights.append(self.arena, weight);
        try self.base.append(self.arena, if (shown) 1 else 0);
        return e;
    }

    fn regionKey(self: *Builder, region: u32, text: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.arena, "{d}\x00{s}", .{ region, text });
    }

    fn addRootElements(self: *Builder, files: []const File) !void {
        var counts: std.ArrayList(u32) = .empty;
        var owners: std.ArrayList(File) = .empty;
        var index: std.StringHashMapUnmanaged(u32) = .empty;
        for (files) |f| {
            if (f.region >= self.lines.len or self.lines[f.region].line == null) continue;
            const n = callables(f.defs);
            if (n == 0) continue;
            const entry = try index.getOrPut(self.arena, try self.regionKey(f.region, fileRoot(f.path)));
            if (!entry.found_existing) {
                entry.value_ptr.* = @intCast(counts.items.len);
                try counts.append(self.arena, 0);
                try owners.append(self.arena, f);
            }
            counts.items[entry.value_ptr.*] += n;
        }
        for (counts.items, owners.items) |n, f| {
            const root = fileRoot(f.path);
            const words = try self.stemsOf(root);
            const idf = if (self.options.by_dirs) idfOf(self.dir_ids.count(), self.root_dirs.get(root) orelse 1) else 1;
            const weight = std.math.pow(f64, @floatFromInt(n), self.options.tf_power) * self.options.root_weight * std.math.pow(f64, idf, self.options.idf_power);
            const e = try self.element(weight, allIn(words, self.line_stems[f.region]));
            try self.root_element.put(self.arena, try self.regionKey(f.region, root), e);
        }
    }

    fn addCandidate(self: *Builder, region: u32, kind: Kind, text: []const u8) !void {
        const seen_key = try self.regionKey(region, text);
        const entry = try self.seen.getOrPut(self.arena, seen_key);
        if (entry.found_existing) return;
        var covers: std.ArrayList(map_terms.Cover) = .empty;
        var value: f64 = 0;
        for (try self.stemsOf(text)) |s| {
            const e = self.element_of.get(key(region, s)) orelse continue;
            try covers.append(self.arena, .{ .element = e, .value = 1 });
            value += self.weights.items[e];
        }
        if (kind == .root) {
            if (self.root_element.get(seen_key)) |e| {
                try covers.append(self.arena, .{ .element = e, .value = 1 });
                value += self.weights.items[e];
            }
        }
        if (covers.items.len == 0) return;
        const separator: u32 = if (self.options.space_separated) 1 else 2;
        try self.candidates.append(self.arena, .{ .cost = @intCast(text.len + separator), .covers = covers.items });
        try self.items.append(self.arena, .{ .region = region, .kind = kind, .text = text, .value = value });
    }
};

pub fn plan(arena: Allocator, lines: []const RegionLine, files: []const File, options: Options) !Plan {
    var b: Builder = .{ .arena = arena, .options = options, .lines = lines, .stems = .{ .arena = arena, .plural_only = options.plural_only } };
    const line_stems = try arena.alloc([]const u32, lines.len);
    var regions: u32 = 0;
    for (lines, line_stems) |line, *slot| {
        slot.* = if (line.line) |text| try b.stemsOf(text) else &.{};
        if (line.line != null) regions += 1;
    }
    b.line_stems = line_stems;
    const mass = try arena.alloc(f64, lines.len);
    @memset(mass, 0);
    for (files) |f| {
        if (f.region >= lines.len or lines[f.region].line == null) continue;
        mass[f.region] += @floatFromInt(callables(f.defs));
    }
    const name_stems = try arena.alloc([]const u32, files.len);
    var rows: std.ArrayList(Row) = .empty;
    var scratch: std.ArrayList(u32) = .empty;
    var sink: StemSink = .{ .stems = &b.stems, .out = &scratch, .arena = arena };
    var stem_dirs: std.AutoHashMapUnmanaged(u64, void) = .empty;
    var dir_stems: std.ArrayList(Row) = .empty;
    var file_words: std.ArrayList(u32) = .empty;
    for (files, name_stems) |f, *slot| {
        slot.* = &.{};
        if (f.region >= lines.len or lines[f.region].line == null) continue;
        var names: std.ArrayList(u32) = .empty;
        var name_sink: StemSink = .{ .stems = &b.stems, .out = &names, .arena = arena };
        try map_terms.eachPart(fileRoot(f.path), &name_sink);
        try map_terms.eachPart(relativeDir(f.path, lines[f.region].dir), &name_sink);
        slot.* = names.items;
        const dir = try b.dirId(f.path);
        if (callables(f.defs) != 0) try b.noteRootDir(f.path);
        file_words.clearRetainingCapacity();
        for (f.defs) |d| {
            if (d.kind == .module or !d.kind.callable()) continue;
            scratch.clearRetainingCapacity();
            try map_terms.eachPart(d.qname, &sink);
            for (slot.*) |s| {
                if (std.mem.indexOfScalar(u32, scratch.items, s) == null) try scratch.append(arena, s);
            }
            for (scratch.items) |s| {
                try rows.append(arena, .{ .region = f.region, .stem = s });
                if (std.mem.indexOfScalar(u32, file_words.items, s) == null) try file_words.append(arena, s);
            }
        }
        for (file_words.items) |s| {
            const entry = try stem_dirs.getOrPut(arena, key(dir, s));
            if (!entry.found_existing) try dir_stems.append(arena, .{ .region = dir, .stem = s });
        }
    }
    std.mem.sort(Row, rows.items, {}, rowLess);
    const dir_df = try arena.alloc(u32, b.stems.names.items.len);
    @memset(dir_df, 0);
    for (dir_stems.items) |pair| dir_df[pair.stem] += 1;
    const df = try arena.alloc(u32, b.stems.names.items.len);
    @memset(df, 0);
    var i: usize = 0;
    while (i < rows.items.len) {
        var j = i;
        while (j < rows.items.len and rows.items[j].region == rows.items[i].region and rows.items[j].stem == rows.items[i].stem) j += 1;
        df[rows.items[i].stem] += 1;
        i = j;
    }
    var element_stem: std.ArrayList(u32) = .empty;
    var element_region: std.ArrayList(u32) = .empty;
    var element_count: std.ArrayList(u32) = .empty;
    var element_id: std.ArrayList(u32) = .empty;
    i = 0;
    while (i < rows.items.len) {
        var j = i;
        while (j < rows.items.len and rows.items[j].region == rows.items[i].region and rows.items[j].stem == rows.items[i].stem) j += 1;
        const row = rows.items[i];
        const count: f64 = @floatFromInt(j - i);
        const value = std.math.pow(f64, count, options.tf_power) * std.math.pow(f64, b.spread(regions, df[row.stem], dir_df[row.stem]), options.idf_power);
        if (value > 0) {
            const shown = std.mem.indexOfScalar(u32, line_stems[row.region], row.stem) != null;
            const e = try b.element(value, shown);
            try b.element_of.put(arena, key(row.region, row.stem), e);
            try element_stem.append(arena, row.stem);
            try element_region.append(arena, row.region);
            try element_count.append(arena, @intCast(j - i));
            try element_id.append(arena, e);
        }
        i = j;
    }
    if (options.root_weight > 0) try b.addRootElements(files);
    var in_names: std.AutoHashMapUnmanaged(u64, void) = .empty;
    for (files, name_stems) |f, ns| {
        if (ns.len == 0) continue;
        for (ns) |s| try in_names.put(arena, key(f.region, s), {});
        const rel = relativeDir(f.path, lines[f.region].dir);
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, rel, start, '/')) |slash| {
            try b.addCandidate(f.region, .dir, rel[start .. slash + 1]);
            start = slash + 1;
        }
        try b.addCandidate(f.region, .root, fileRoot(f.path));
    }
    if (options.terms) {
        for (element_stem.items, element_region.items, element_count.items, element_id.items) |s, r, count, e| {
            if (in_names.contains(key(r, s)) or count < options.min_term_count) continue;
            const text = b.stems.display(s);
            if (text.len < options.min_term_chars) continue;
            const covers = try arena.alloc(map_terms.Cover, 1);
            covers[0] = .{ .element = e, .value = 1 };
            try b.candidates.append(arena, .{ .cost = @intCast(text.len + 2), .covers = covers });
            try b.items.append(arena, .{ .region = r, .kind = .term, .text = text, .value = b.weights.items[e] });
        }
    }
    return .{
        .items = b.items.items,
        .candidates = b.candidates.items,
        .weights = b.weights.items,
        .base = b.base.items,
        .regions = @intCast(lines.len),
        .elements = @intCast(b.weights.items.len),
        .mass = mass,
        .quota_power = options.quota_power,
    };
}

fn gainOf(candidate: map_terms.Candidate, weights: []const f64, current: []const f32) f64 {
    var gain: f64 = 0;
    for (candidate.covers) |c| {
        const now = current[c.element];
        if (c.value > now) gain += weights[c.element] * @as(f64, c.value - now);
    }
    return gain;
}

fn ratioMore(r: []const f64, a: u32, b: u32) bool {
    if (r[a] != r[b]) return r[a] > r[b];
    return a < b;
}

pub fn select(arena: Allocator, p: *const Plan, budget: u64) ![]bool {
    const chosen = try arena.alloc(bool, p.items.len);
    @memset(chosen, false);
    const current = try arena.dupe(f32, p.base);
    const best = try arena.alloc(?u32, p.regions);
    @memset(best, null);
    const ratio = try arena.alloc(f64, p.items.len);
    for (p.candidates, p.items, ratio, 0..) |c, item, *slot, k| {
        slot.* = gainOf(c, p.weights, current) / @as(f64, @floatFromInt(@max(c.cost, 1)));
        if (slot.* <= 0) continue;
        if (best[item.region]) |b| {
            if (slot.* <= ratio[b]) continue;
        }
        best[item.region] = @intCast(k);
    }
    var forced: std.ArrayList(u32) = .empty;
    for (best) |b| {
        if (b) |k| try forced.append(arena, k);
    }
    std.mem.sort(u32, forced.items, ratio, ratioMore);
    var spent: u64 = 0;
    for (forced.items) |k| {
        const c = p.candidates[k];
        if (spent + c.cost > budget) continue;
        chosen[k] = true;
        spent += c.cost;
        for (c.covers) |cover| {
            if (cover.value > current[cover.element]) current[cover.element] = cover.value;
        }
    }
    if (spent >= budget) return chosen;
    if (p.quota_power > 0 and p.mass.len == p.regions) {
        const by_region = try arena.alloc(std.ArrayList(u32), p.regions);
        for (by_region) |*list| list.* = .empty;
        const region_spent = try arena.alloc(u64, p.regions);
        @memset(region_spent, 0);
        for (p.items, 0..) |item, k| {
            try by_region[item.region].append(arena, @intCast(k));
            if (chosen[k]) region_spent[item.region] += p.candidates[k].cost;
        }
        var total: f64 = 0;
        for (p.mass, by_region) |m, list| {
            if (list.items.len != 0) total += std.math.pow(f64, m, p.quota_power);
        }
        const pool: f64 = @floatFromInt(budget);
        for (by_region, 0..) |list, r| {
            if (list.items.len == 0 or total <= 0) continue;
            const share: u64 = @intFromFloat(@floor(pool * std.math.pow(f64, p.mass[r], p.quota_power) / total));
            if (share <= region_spent[r] or spent >= budget) continue;
            const quota = @min(share - region_spent[r], budget - spent);
            const sub = try arena.alloc(map_terms.Candidate, list.items.len);
            for (list.items, sub) |k, *c| c.* = p.candidates[k];
            const picked = try map_terms.greedy(arena, p.weights, current, sub, quota);
            for (picked.chosen) |j| {
                const k = list.items[j];
                if (chosen[k]) continue;
                chosen[k] = true;
                spent += p.candidates[k].cost;
                for (p.candidates[k].covers) |cover| {
                    if (cover.value > current[cover.element]) current[cover.element] = cover.value;
                }
            }
        }
        if (spent >= budget) return chosen;
    }
    const picked = try map_terms.greedy(arena, p.weights, current, p.candidates, budget - spent);
    for (picked.chosen) |k| chosen[k] = true;
    return chosen;
}

const testing = std.testing;

fn def(qname: []const u8, kind: facts.DefKind) facts.Def {
    const dot = std.mem.lastIndexOfScalar(u8, qname, '.');
    return .{
        .kind = kind,
        .name = if (dot) |d| qname[d + 1 ..] else qname,
        .qname = qname,
        .parent = 0,
        .span = .{ .start = 0, .end = 0 },
        .name_start = 0,
        .line = 1,
        .hash = std.mem.zeroes(facts.Hash),
        .alpha = std.mem.zeroes(facts.Hash),
    };
}

test "map concepts: the root of a file name stops at its first dot and keeps dot files whole" {
    try testing.expectEqualStrings("credentials-tester", fileRoot("packages/cli/src/services/credentials-tester.service.ts"));
    try testing.expectEqualStrings("Hubspot", fileRoot("nodes/Hubspot/Hubspot.node.ts"));
    try testing.expectEqualStrings(".eslintrc", fileRoot("a/.eslintrc"));
    try testing.expectEqualStrings("README", fileRoot("README"));
}

test "map concepts: a word every region holds weighs nothing and a word of one region weighs most" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lines = [_]RegionLine{ .{ .line = "a/", .dir = "a/" }, .{ .line = "b/", .dir = "b/" }, .{ .line = "c/", .dir = "c/" }, .{ .line = null, .dir = "t/" } };
    const files = [_]File{
        .{ .path = "a/credentials-tester.service.ts", .region = 0, .defs = &.{ def("CredentialsTester.runTest", .method), def("CredentialsTester.handle", .method) } },
        .{ .path = "b/workflow-diff.ts", .region = 1, .defs = &.{ def("compareWorkflows", .function), def("handleDiff", .function) } },
        .{ .path = "c/handler.ts", .region = 2, .defs = &.{ def("handleEvent", .function), def("Shape", .interface), def("ShapeKind", .type_alias) } },
        .{ .path = "t/test.ts", .region = 3, .defs = &.{def("handleTest", .function)} },
    };
    const p = try plan(arena, &lines, &files, .{});
    var tester: ?f64 = null;
    var handle_seen = false;
    for (p.items) |item| {
        if (item.kind == .root and std.mem.eql(u8, item.text, "credentials-tester")) tester = item.value;
        if (item.kind == .term and std.mem.eql(u8, item.text, "handle")) handle_seen = true;
        try testing.expect(item.region != 3);
    }
    try testing.expect(tester != null and tester.? > 0);
    try testing.expect(!handle_seen);
    for (p.items) |item| {
        try testing.expect(!(item.kind == .term and std.mem.eql(u8, item.text, "shape")));
    }
}

fn fns(comptime names: []const []const u8) [names.len]facts.Def {
    var out: [names.len]facts.Def = undefined;
    for (names, 0..) |n, k| out[k] = def(n, .function);
    return out;
}

fn itemIndex(p: Plan, kind: Kind, text: []const u8) ?usize {
    for (p.items, 0..) |item, k| {
        if (item.kind == kind and std.mem.eql(u8, item.text, text)) return k;
    }
    return null;
}

test "map concepts: a file root is a candidate only for the words it adds" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lines = [_]RegionLine{ .{ .line = "pkg/", .dir = "pkg/" }, .{ .line = "other/", .dir = "other/" } };
    const a = fns(&.{ "runTest", "testOne", "check" });
    const b = fns(&.{ "load", "save", "list" });
    const c = fns(&.{ "find", "drop", "keep" });
    const files = [_]File{
        .{ .path = "pkg/credentials-tester.ts", .region = 0, .defs = &a },
        .{ .path = "pkg/credentials.ts", .region = 0, .defs = &b },
        .{ .path = "other/credentials.ts", .region = 1, .defs = &c },
    };
    const p = try plan(arena, &lines, &files, .{});
    try testing.expect(itemIndex(p, .root, "credentials-tester") != null);
    try testing.expect(itemIndex(p, .root, "credentials") == null);
    try testing.expect(itemIndex(p, .term, "tester") == null);
}

test "map concepts: a folder below the region covers the words of its name and a second name with no new word is left out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lines = [_]RegionLine{ .{ .line = "pkg/", .dir = "pkg/" }, .{ .line = "other/", .dir = "other/" } };
    const d = fns(&.{ "contacts", "deals", "owners" });
    const c = fns(&.{ "find", "drop", "keep" });
    const files = [_]File{
        .{ .path = "pkg/Hubspot/V2/HubspotV2.ts", .region = 0, .defs = &d },
        .{ .path = "other/plain.ts", .region = 1, .defs = &c },
    };
    const p = try plan(arena, &lines, &files, .{});
    const folder = itemIndex(p, .dir, "Hubspot/") orelse return error.FolderNotACandidate;
    try testing.expect(p.items[folder].value > 0);
    const chosen = try select(arena, &p, 1000);
    const root = itemIndex(p, .root, "HubspotV2").?;
    try testing.expect(chosen[folder] != chosen[root]);
}

test "map concepts: every region with a candidate gets one item before any region gets a second, and the budget holds" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lines = [_]RegionLine{ .{ .line = "big/", .dir = "big/" }, .{ .line = "small/", .dir = "small/" }, .{ .line = "rest/", .dir = "rest/" } };
    const many = fns(&.{ "alphaRun", "alphaStop", "alphaWalk", "alphaJump", "alphaSing", "alphaPlay", "alphaRead", "alphaSend" });
    const more = fns(&.{ "gammaRun", "gammaStop", "gammaWalk", "gammaJump", "gammaSing", "gammaPlay", "gammaRead", "gammaSend" });
    const few = fns(&.{"zetaOnce"});
    const filler = fns(&.{"other"});
    const files = [_]File{
        .{ .path = "big/alpha.ts", .region = 0, .defs = &many },
        .{ .path = "big/gamma.ts", .region = 0, .defs = &more },
        .{ .path = "small/zeta.ts", .region = 1, .defs = &few },
        .{ .path = "rest/other.ts", .region = 2, .defs = &filler },
    };
    const p = try plan(arena, &lines, &files, .{});
    const small_cost = p.candidates[itemIndex(p, .root, "zeta").?].cost;
    const big_cost = p.candidates[itemIndex(p, .root, "alpha").?].cost;
    const chosen = try select(arena, &p, small_cost + big_cost);
    var per_region = [_]u32{ 0, 0, 0 };
    var spent: u64 = 0;
    for (chosen, p.items, p.candidates) |c, item, cand| {
        if (!c) continue;
        per_region[item.region] += 1;
        spent += cand.cost;
    }
    try testing.expectEqual(@as(u32, 1), per_region[0]);
    try testing.expectEqual(@as(u32, 1), per_region[1]);
    try testing.expect(spent <= small_cost + big_cost);
    for ([_]u64{ 0, 3, 7, 12, 40, 1000 }) |budget| {
        const again = try select(arena, &p, budget);
        var cost: u64 = 0;
        for (again, p.candidates) |c, cand| {
            if (c) cost += cand.cost;
        }
        try testing.expect(cost <= budget);
        try testing.expectEqualSlices(bool, again, try select(arena, &p, budget));
    }
}

test "map concepts: region quotas give a region with more functions more names than a smaller region with rarer words" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lines = [_]RegionLine{ .{ .line = "common/", .dir = "common/" }, .{ .line = "rare/", .dir = "rare/" }, .{ .line = "other/", .dir = "other/" } };
    const shared = fns(&.{ "nodeRun", "nodeStop", "nodeWalk", "nodeJump", "nodeSing", "nodePlay", "nodeRead", "nodeSend", "nodeOpen", "nodeShut", "nodeLoad", "nodeSave" });
    const unique = fns(&.{ "zephyrQuark", "zephyrGlyph" });
    const files = [_]File{
        .{ .path = "common/node-diff.ts", .region = 0, .defs = &shared },
        .{ .path = "common/node-proxy.ts", .region = 0, .defs = &shared },
        .{ .path = "common/node-helpers.ts", .region = 0, .defs = &shared },
        .{ .path = "rare/zephyr-quark.ts", .region = 1, .defs = &unique },
        .{ .path = "rare/zephyr-glyph.ts", .region = 1, .defs = &unique },
        .{ .path = "other/node-diff-proxy-helpers.ts", .region = 2, .defs = &shared },
    };
    var flat = try plan(arena, &lines, &files, .{ .tf_power = 0.5, .idf_power = 2 });
    var fair = flat;
    fair.quota_power = 1;
    flat.quota_power = 0;
    const budget: u64 = 40;
    const flat_chosen = try select(arena, &flat, budget);
    const fair_chosen = try select(arena, &fair, budget);
    var flat_common: u32 = 0;
    var fair_common: u32 = 0;
    var fair_spent: u64 = 0;
    for (flat.items, flat_chosen, fair_chosen, fair.candidates) |item, a, b, c| {
        if (item.region == 0 and a) flat_common += 1;
        if (item.region == 0 and b) fair_common += 1;
        if (b) fair_spent += c.cost;
    }
    try testing.expect(fair_common > flat_common);
    try testing.expect(fair_spent <= budget);
}
