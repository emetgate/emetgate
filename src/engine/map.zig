const std = @import("std");
const facts = @import("facts.zig");
const facts_store = @import("facts_store.zig");
const answer = @import("answer.zig");
const profile_mod = @import("lang/profile.zig");
const map_tree = @import("map_tree.zig");
const map_rank = @import("map_rank.zig");
const map_terms = @import("map_terms.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Store = facts_store.Store;
const FileId = facts_store.FileId;
const FileState = facts_store.FileState;
const MapTable = profile_mod.MapTable;
const none = facts.none;

pub const SymbolId = facts_store.DefId;
pub const RegionId = u32;
pub const EntryKind = profile_mod.MapEntryKind;

pub const Family = enum { code, tests };

pub const Entry = struct {
    symbol: SymbolId,
    kind: EntryKind,
    tag: []const u8,
};

pub const Region = struct {
    id: RegionId,
    family: Family,
    dir: []const u8,
    label: []const u8,
    path: []const u8,
    line_path: []const u8,
    files: []const u32,
    symbols: []const SymbolId,
    key_symbols: []const SymbolId,
    entry_points: []const Entry,
    concepts: []const []const u8,
    listing_chars: u64,
};

pub const SymbolSnap = struct {
    kind: facts.DefKind,
    qname: []const u8,
    hash: facts.Hash,
    line: u32,
    span: facts.Span = .{ .start = 0, .end = 0 },
};

pub const FileSnap = struct {
    path: []const u8,
    status: facts_store.Status,
    parse_errors: bool,
    content_hash: facts.Hash,
    region: RegionId,
    symbols: []const SymbolSnap,
};

pub const Snapshot = struct {
    store_root: facts.Hash,
    cert: answer.Snapshot,
    files: []const FileSnap,
    by_store_id: []const u32,
};

pub const Stats = struct {
    files: u32 = 0,
    indexed_files: u32 = 0,
    symbols: u32 = 0,
    code_symbols: u32 = 0,
    regions: u32 = 0,
    code_regions: u32 = 0,
    test_regions: u32 = 0,
    region_chars: u32 = 0,
    max_region_chars: u64 = 0,
    over_capacity_regions: u32 = 0,
    text_chars: u32 = 0,
    est_tokens: u32 = 0,
    budget_tokens: u32 = 0,
    names: u32 = 0,
    terms: u32 = 0,
    entries: u32 = 0,
    files_named: u32 = 0,
    children_chars: u32 = 0,
    complete: bool = false,
    pagerank_iterations: u32 = 0,
    fit_rounds: u32 = 0,
};

pub const Map = struct {
    snapshot: Snapshot,
    regions: []const Region,
    text: []const u8,
    stats: Stats,

    pub fn regionOfPath(self: *const Map, path: []const u8) ?RegionId {
        return regionByPath(self, path);
    }
};

pub const MapOptions = struct {
    budget_tokens: u32 = 16_000,
    region_chars: u32 = 8_000,
    chars_per_token: f64 = 2.02,
    term_value: f32 = 0.3,
    file_value: f32 = 0.5,
    terms_per_region: u32 = 40,
    heading_regions: u32 = 24,
    base_share: f64 = 0.35,
    damping: f64 = 0.3,
    list_children: bool = true,
    region_balance: f64 = 0,
    file_specificity: bool = false,
    cert: answer.Snapshot = .{ .barrier = 0, .root = std.mem.zeroes(answer.Digest) },
    fallback: ?*const MapTable = null,
};

pub fn kindTag(kind: facts.DefKind) []const u8 {
    return switch (kind) {
        .module => "module",
        .function, .arrow, .function_expression => "fn",
        .generator => "gen",
        .method => "method",
        .getter => "get",
        .setter => "set",
        .constructor => "ctor",
        .class => "class",
        .variable => "var",
        .interface => "interface",
        .type_alias => "type",
        .enumeration => "enum",
        .field => "field",
        .enum_member => "member",
    };
}

fn digits(value: u64) u32 {
    var n: u32 = 1;
    var v = value;
    while (v >= 10) : (v /= 10) n += 1;
    return n;
}

fn basename(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

pub fn isTestPath(table: ?*const MapTable, path: []const u8) bool {
    const t = table orelse return false;
    const base = basename(path);
    for (t.test_infixes) |infix| {
        if (std.mem.indexOf(u8, base, infix) != null) return true;
    }
    var it = std.mem.splitScalar(u8, path[0 .. path.len - base.len], '/');
    while (it.next()) |segment| {
        for (t.test_segments) |marker| {
            if (std.mem.eql(u8, segment, marker)) return true;
        }
    }
    return false;
}

fn tableOf(state: *const FileState, fallback: ?*const MapTable) ?*const MapTable {
    if (state.profile) |p| {
        if (p.map) |m| return m;
    }
    return fallback;
}

fn compactLine(line: u32, kind: facts.DefKind, qname: []const u8) u64 {
    return 2 + digits(line) + 1 + kindTag(kind).len + 1 + qname.len + 1;
}

const FileInfo = struct {
    id: FileId,
    state: *const FileState,
    family: Family,
    table: ?*const MapTable,
    weight: u32,
    region: RegionId = none,
    first_symbol: u32 = 0,
    symbol_count: u32 = 0,
};

const Sym = struct {
    file: u32,
    def: u32,
    node: u32,
};

fn fileLess(_: void, a: FileInfo, b: FileInfo) bool {
    return std.mem.order(u8, a.state.path, b.state.path) == .lt;
}

const Builder = struct {
    arena: Allocator,
    store: *const Store,
    options: MapOptions,
    files: []FileInfo = &.{},
    syms: std.ArrayList(Sym) = .empty,
    base: []u32 = &.{},
    nodes: u32 = 0,
    weight: []f64 = &.{},
    entry_of: []?Entry = &.{},
    regions: std.ArrayList(Region) = .empty,
    region_files: std.ArrayList(std.ArrayList(u32)) = .empty,
    capacity: u64 = 0,

    fn collectFiles(self: *Builder) !void {
        var list: std.ArrayList(FileInfo) = .empty;
        for (self.store.files.items, 0..) |*state, id| {
            if (state.status == .removed) continue;
            const table = tableOf(state, self.options.fallback);
            const family: Family = if (isTestPath(table, state.path)) .tests else .code;
            var weight: u64 = basename(state.path).len + 1;
            if (state.status == .indexed) {
                for (state.facts.defs) |d| {
                    if (d.kind == .module) continue;
                    weight += compactLine(d.line, d.kind, d.qname);
                }
            }
            try list.append(self.arena, .{ .id = @intCast(id), .state = state, .family = family, .table = table, .weight = @intCast(@min(weight, std.math.maxInt(u32))) });
        }
        std.mem.sort(FileInfo, list.items, {}, fileLess);
        self.files = list.items;
        for (self.files, 0..) |*f, k| {
            f.first_symbol = @intCast(self.syms.items.len);
            if (f.state.status == .indexed) {
                for (f.state.facts.defs, 0..) |d, di| {
                    if (d.kind == .module) continue;
                    try self.syms.append(self.arena, .{ .file = @intCast(k), .def = @intCast(di), .node = none });
                }
            }
            f.symbol_count = @as(u32, @intCast(self.syms.items.len)) - f.first_symbol;
        }
    }

    fn partitionFamily(self: *Builder, family: Family, capacity: u64) !void {
        var items: std.ArrayList(map_tree.Item) = .empty;
        var index: std.ArrayList(u32) = .empty;
        for (self.files, 0..) |f, k| {
            if (f.family != family) continue;
            try items.append(self.arena, .{ .path = f.state.path, .weight = f.weight });
            try index.append(self.arena, @intCast(k));
        }
        const ranges = try map_tree.partition(self.arena, items.items, capacity);
        for (ranges) |r| {
            const id: RegionId = @intCast(self.regions.items.len);
            var members: std.ArrayList(u32) = .empty;
            for (index.items[r.first .. r.first + r.count]) |k| {
                try members.append(self.arena, k);
                self.files[k].region = id;
            }
            const label = try regionLabel(self.arena, r);
            const shown = if (self.options.list_children and family == .code) try childrenLabel(self.arena, items.items, r) else label;
            try self.regions.append(self.arena, .{
                .id = id,
                .family = family,
                .dir = r.dir,
                .label = shown,
                .path = try std.mem.concat(self.arena, u8, &.{ r.dir, label }),
                .line_path = try std.mem.concat(self.arena, u8, &.{ r.dir, shown }),
                .files = members.items,
                .symbols = &.{},
                .key_symbols = &.{},
                .entry_points = &.{},
                .concepts = &.{},
                .listing_chars = r.weight,
            });
        }
    }

    fn baseCost(self: *const Builder) u64 {
        var cost: u64 = 0;
        for (self.regions.items) |r| cost += 6 + r.path.len + 4;
        return cost;
    }

    fn partition(self: *Builder) !void {
        const total_chars: f64 = @as(f64, @floatFromInt(self.options.budget_tokens)) * self.options.chars_per_token;
        var capacity: u64 = @max(self.options.region_chars, 64);
        while (true) {
            self.regions.clearRetainingCapacity();
            try self.partitionFamily(.code, capacity);
            try self.partitionFamily(.tests, capacity);
            const cost: f64 = @floatFromInt(self.baseCost());
            if (cost <= total_chars * self.options.base_share or capacity >= 1 << 40) break;
            capacity = capacity + capacity / 2;
        }
        self.capacity = capacity;
        for (self.regions.items) |*r| {
            var symbols: std.ArrayList(SymbolId) = .empty;
            for (r.files) |k| {
                const f = self.files[k];
                for (self.syms.items[f.first_symbol .. f.first_symbol + f.symbol_count]) |s| {
                    try symbols.append(self.arena, .{ .file = f.id, .slot = f.state.slots[s.def] });
                }
            }
            r.symbols = symbols.items;
        }
    }

    fn rank(self: *Builder, iterations: *u32) !void {
        const store_files = self.store.files.items;
        self.base = try self.arena.alloc(u32, store_files.len);
        var nodes: u32 = 0;
        for (store_files, 0..) |state, id| {
            self.base[id] = nodes;
            if (state.status == .indexed) nodes += @intCast(state.facts.defs.len);
        }
        self.nodes = nodes;
        const teleport = try self.arena.alloc(f64, nodes);
        @memset(teleport, 0);
        for (self.files) |f| {
            if (f.family != .code or f.state.status != .indexed) continue;
            const defs = f.state.facts.defs;
            const at = self.base[f.id];
            for (defs, 0..) |d, di| teleport[at + di] = @floatFromInt(d.span.end -| d.span.start);
            for (defs, 0..) |d, di| {
                if (d.parent == none or d.parent == di) continue;
                teleport[at + d.parent] -= @floatFromInt(d.span.end -| d.span.start);
            }
            for (defs, 0..) |_, di| teleport[at + di] = @max(teleport[at + di], 1);
        }
        var edges: std.ArrayList(map_rank.Edge) = .empty;
        for (store_files, 0..) |*state, id| {
            if (state.status != .indexed or state.links.len != state.facts.refs.len) continue;
            const from_base = self.base[id];
            for (state.facts.refs, state.links) |r, l| {
                if (!(r.kind.invokes() or r.kind == .import)) continue;
                const target = switch (l) {
                    .def => |d| d.id,
                    .unresolved => continue,
                };
                if (target.file >= store_files.len) continue;
                const t_state = &store_files[target.file];
                if (t_state.status != .indexed) continue;
                const di = t_state.defIndex(target.slot) orelse continue;
                const from = from_base + r.from;
                const to = self.base[target.file] + di;
                if (from == to) continue;
                try edges.append(self.arena, .{ .from = from, .to = to, .weight = 1 });
            }
        }
        const graph = try map_rank.Graph.build(self.arena, nodes, edges.items);
        const ranked = try map_rank.pagerank(self.arena, graph, teleport, .{ .damping = self.options.damping });
        iterations.* = ranked.iterations;
        self.weight = try self.arena.alloc(f64, self.syms.items.len);
        for (self.syms.items, self.weight) |*s, *w| {
            const f = self.files[s.file];
            s.node = self.base[f.id] + s.def;
            w.* = if (f.family == .code) ranked.rank[s.node] else 0;
        }
    }

    fn symIndex(self: *const Builder, file_k: u32, def: u32) ?u32 {
        const f = self.files[file_k];
        if (f.state.status != .indexed or def == 0 or def > f.symbol_count) return null;
        const at = f.first_symbol + def - 1;
        if (self.syms.items[at].def != def) return null;
        return at;
    }

    fn entries(self: *Builder) !void {
        self.entry_of = try self.arena.alloc(?Entry, self.syms.items.len);
        @memset(self.entry_of, null);
        for (self.files, 0..) |f, k| {
            if (f.family != .code or f.state.status != .indexed) continue;
            const table = f.table orelse continue;
            const defs = f.state.facts.defs;
            var routes_module: ?*const profile_mod.MapCallForm = null;
            for (table.call_forms) |*form| {
                for (f.state.facts.specs) |spec| {
                    for (form.modules) |m| {
                        if (std.mem.eql(u8, spec.text, m) or (std.mem.startsWith(u8, spec.text, m) and spec.text.len > m.len and spec.text[m.len] == '/')) routes_module = form;
                    }
                }
            }
            for (f.state.facts.refs) |r| {
                if (r.kind != .call or r.from == 0 or r.from >= defs.len) continue;
                const owner = defs[r.from];
                const s = self.symIndex(@intCast(k), r.from) orelse continue;
                if (r.start >= owner.span.start and r.start < owner.name_start) {
                    if (decoratorRule(table, r.name)) |rule| {
                        if (self.entry_of[s] == null) self.entry_of[s] = .{ .symbol = self.symbolId(s), .kind = rule.kind, .tag = rule.tag };
                    }
                    continue;
                }
                if (routes_module) |form| {
                    if (r.target != .unresolved) continue;
                    for (form.methods) |m| {
                        if (std.mem.eql(u8, m, r.name) and self.entry_of[s] == null) {
                            self.entry_of[s] = .{ .symbol = self.symbolId(s), .kind = form.kind, .tag = form.tag };
                        }
                    }
                }
            }
        }
    }

    fn symbolId(self: *const Builder, s: u32) SymbolId {
        const sym = self.syms.items[s];
        const f = self.files[sym.file];
        return .{ .file = f.id, .slot = f.state.slots[sym.def] };
    }

    fn apiEntries(self: *Builder) !void {
        const store_files = self.store.files.items;
        const region_of_store = try self.arena.alloc(u32, store_files.len);
        @memset(region_of_store, none);
        const file_k_of_store = try self.arena.alloc(u32, store_files.len);
        @memset(file_k_of_store, none);
        for (self.files, 0..) |f, k| {
            region_of_store[f.id] = f.region;
            file_k_of_store[f.id] = @intCast(k);
        }
        const fan_in = try self.arena.alloc(u32, self.syms.items.len);
        @memset(fan_in, 0);
        for (store_files, 0..) |*state, id| {
            if (state.status != .indexed or state.links.len != state.facts.refs.len) continue;
            const from_region = region_of_store[id];
            for (state.facts.refs, state.links) |r, l| {
                if (r.kind == .import) continue;
                const target = switch (l) {
                    .def => |d| d.id,
                    .unresolved => continue,
                };
                if (target.file >= store_files.len or region_of_store[target.file] == from_region) continue;
                const k = file_k_of_store[target.file];
                if (k == none) continue;
                const di = store_files[target.file].defIndex(target.slot) orelse continue;
                if (!store_files[target.file].facts.defs[di].exported) continue;
                const s = self.symIndex(k, di) orelse continue;
                fan_in[s] += 1;
            }
        }
        for (self.regions.items) |*region| {
            if (region.family != .code) continue;
            var picked: std.ArrayList(Entry) = .empty;
            var best: [3]?u32 = .{ null, null, null };
            for (region.files) |k| {
                const f = self.files[k];
                var s = f.first_symbol;
                while (s < f.first_symbol + f.symbol_count) : (s += 1) {
                    if (self.entry_of[s]) |e| try picked.append(self.arena, e);
                    if (fan_in[s] == 0) continue;
                    var slot: usize = 0;
                    while (slot < best.len) : (slot += 1) {
                        const current = best[slot] orelse {
                            best[slot] = s;
                            break;
                        };
                        if (fan_in[s] > fan_in[current]) {
                            var j = best.len - 1;
                            while (j > slot) : (j -= 1) best[j] = best[j - 1];
                            best[slot] = s;
                            break;
                        }
                    }
                }
            }
            for (best) |b| {
                const s = b orelse break;
                try picked.append(self.arena, .{ .symbol = self.symbolId(s), .kind = .api, .tag = "api" });
            }
            region.entry_points = picked.items;
        }
    }
};

fn decoratorRule(table: *const MapTable, name: []const u8) ?profile_mod.MapDecorator {
    for (table.decorators) |rule| {
        if (rule.prefix) {
            if (name.len > rule.name.len and std.mem.startsWith(u8, name, rule.name) and std.ascii.isUpper(name[rule.name.len])) return rule;
        } else if (std.mem.eql(u8, name, rule.name)) return rule;
    }
    return null;
}

fn regionLabel(arena: Allocator, r: map_tree.Range) ![]const u8 {
    if (r.whole) return "";
    if (r.children == 1) return r.first_child;
    if (r.children == 2) return std.fmt.allocPrint(arena, "{{{s}, {s}}}", .{ r.first_child, r.last_child });
    return std.fmt.allocPrint(arena, "{{{s} .. {s}}}", .{ r.first_child, r.last_child });
}

fn isDirSegment(segment: []const u8) bool {
    return segment.len != 0 and segment[segment.len - 1] == '/';
}

fn childrenLabel(arena: Allocator, items: []const map_tree.Item, r: map_tree.Range) ![]const u8 {
    if (r.whole or r.children <= 2) return regionLabel(arena, r);
    var segments: std.ArrayList([]const u8) = .empty;
    for (items[r.first .. r.first + r.count]) |item| {
        const rest = item.path[r.dir.len..];
        const segment = if (std.mem.indexOfScalar(u8, rest, '/')) |slash| rest[0 .. slash + 1] else rest;
        if (segments.items.len != 0 and std.mem.eql(u8, segments.items[segments.items.len - 1], segment)) continue;
        try segments.append(arena, segment);
    }
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '{');
    var i: usize = 0;
    while (i < segments.items.len) {
        if (i != 0) try out.appendSlice(arena, ", ");
        if (isDirSegment(segments.items[i])) {
            try out.appendSlice(arena, segments.items[i]);
            i += 1;
            continue;
        }
        var j = i;
        while (j < segments.items.len and !isDirSegment(segments.items[j])) j += 1;
        if (j - i > 2) {
            try out.appendSlice(arena, segments.items[i]);
            try out.appendSlice(arena, " .. ");
            try out.appendSlice(arena, segments.items[j - 1]);
        } else {
            for (segments.items[i..j], 0..) |segment, n| {
                if (n != 0) try out.appendSlice(arena, ", ");
                try out.appendSlice(arena, segment);
            }
        }
        i = j;
    }
    try out.append(arena, '}');
    return out.items;
}

fn eligibleName(defs: []const facts.Def, di: u32) bool {
    const d = defs[di];
    switch (d.kind) {
        .module, .constructor, .field, .enum_member => return false,
        .variable => return d.parent == 0,
        else => {},
    }
    if (d.parent == none or d.parent == 0) return true;
    return !defs[d.parent].kind.callable() or defs[d.parent].kind == .class;
}

const TermRow = struct {
    region: u32,
    stem: u32,
    sym: u32,
};

fn termRowLess(_: void, a: TermRow, b: TermRow) bool {
    if (a.region != b.region) return a.region < b.region;
    if (a.stem != b.stem) return a.stem < b.stem;
    return a.sym < b.sym;
}

const Stems = struct {
    arena: Allocator,
    ids: std.StringHashMapUnmanaged(u32) = .empty,
    names: std.ArrayList([]const u8) = .empty,
    surface: std.ArrayList(std.StringArrayHashMapUnmanaged(u32)) = .empty,

    fn intern(self: *Stems, raw: []const u8) !u32 {
        var buf: [map_terms.max_part]u8 = undefined;
        const key = map_terms.stem(raw, &buf);
        const entry = try self.ids.getOrPut(self.arena, key);
        if (!entry.found_existing) {
            entry.key_ptr.* = try self.arena.dupe(u8, key);
            entry.value_ptr.* = @intCast(self.names.items.len);
            try self.names.append(self.arena, entry.key_ptr.*);
            try self.surface.append(self.arena, .empty);
        }
        const id = entry.value_ptr.*;
        const forms = &self.surface.items[id];
        const form = try forms.getOrPut(self.arena, raw);
        if (!form.found_existing) {
            form.key_ptr.* = try self.arena.dupe(u8, raw);
            form.value_ptr.* = 0;
        }
        form.value_ptr.* += 1;
        return id;
    }

    fn display(self: *const Stems, id: u32) []const u8 {
        const forms = &self.surface.items[id];
        var best: []const u8 = self.names.items[id];
        var count: u32 = 0;
        for (forms.keys(), forms.values()) |k, v| {
            if (v > count or (v == count and (k.len < best.len or (k.len == best.len and std.mem.order(u8, k, best) == .lt)))) {
                best = k;
                count = v;
            }
        }
        return best;
    }
};

const PartSink = struct {
    stems: *Stems,
    out: *std.ArrayList(u32),
    arena: Allocator,

    pub fn part(self: *PartSink, text: []const u8) !void {
        if (map_terms.isStop(text)) return;
        const id = try self.stems.intern(text);
        for (self.out.items) |existing| {
            if (existing == id) return;
        }
        try self.out.append(self.arena, id);
    }
};

const TermCandidate = struct {
    region: u32,
    stem: u32,
    value: f32,
    covers: []const map_terms.Cover,
};

const Selection = struct {
    names: []bool,
    terms: []const TermCandidate,
    chosen_terms: []bool,
    files: []bool,
    forced: []bool,
};

const Planner = struct {
    b: *Builder,
    code_syms: []u32,
    element_of: []u32,
    stems: Stems,
    term_candidates: []TermCandidate = &.{},
    base_cover: []f32 = &.{},
    forced: []bool = &.{},
    file_shown: []bool = &.{},

    fn init(b: *Builder) !Planner {
        var code: std.ArrayList(u32) = .empty;
        const element_of = try b.arena.alloc(u32, b.syms.items.len);
        @memset(element_of, none);
        for (b.syms.items, 0..) |s, i| {
            if (b.files[s.file].family != .code) continue;
            element_of[i] = @intCast(code.items.len);
            try code.append(b.arena, @intCast(i));
        }
        return .{ .b = b, .code_syms = code.items, .element_of = element_of, .stems = .{ .arena = b.arena } };
    }

    fn terms(self: *Planner) !void {
        const b = self.b;
        var rows: std.ArrayList(TermRow) = .empty;
        var scratch: std.ArrayList(u32) = .empty;
        var sink: PartSink = .{ .stems = &self.stems, .out = &scratch, .arena = b.arena };
        for (self.code_syms) |s| {
            const sym = b.syms.items[s];
            const f = b.files[sym.file];
            const d = f.state.facts.defs[sym.def];
            scratch.clearRetainingCapacity();
            try map_terms.eachPart(d.qname, &sink);
            try map_terms.eachPart(basename(f.state.path), &sink);
            for (scratch.items) |stem_id| try rows.append(b.arena, .{ .region = f.region, .stem = stem_id, .sym = s });
        }
        std.mem.sort(TermRow, rows.items, {}, termRowLess);
        const stem_count = self.stems.names.items.len;
        const global = try b.arena.alloc(u32, stem_count);
        @memset(global, 0);
        const regions_with = try b.arena.alloc(u32, stem_count);
        @memset(regions_with, 0);
        var i: usize = 0;
        while (i < rows.items.len) {
            var j = i;
            while (j < rows.items.len and rows.items[j].region == rows.items[i].region and rows.items[j].stem == rows.items[i].stem) j += 1;
            global[rows.items[i].stem] += @intCast(j - i);
            regions_with[rows.items[i].stem] += 1;
            i = j;
        }
        const region_size = try b.arena.alloc(u32, b.regions.items.len);
        @memset(region_size, 0);
        var code_regions: u32 = 0;
        for (b.regions.items) |r| {
            if (r.family == .code) code_regions += 1;
        }
        for (self.code_syms) |s| region_size[b.files[b.syms.items[s].file].region] += 1;
        const n: f64 = @floatFromInt(self.code_syms.len);
        var candidates: std.ArrayList(TermCandidate) = .empty;
        var region_terms: std.ArrayList(TermCandidate) = .empty;
        i = 0;
        while (i < rows.items.len) {
            const region = rows.items[i].region;
            region_terms.clearRetainingCapacity();
            var r_end = i;
            while (r_end < rows.items.len and rows.items[r_end].region == region) r_end += 1;
            const size: f64 = @floatFromInt(region_size[region]);
            var k = i;
            while (k < r_end) {
                var m = k;
                while (m < r_end and rows.items[m].stem == rows.items[k].stem) m += 1;
                const stem_id = rows.items[k].stem;
                const n11: f64 = @floatFromInt(m - k);
                const n1_: f64 = @floatFromInt(global[stem_id]);
                const enough = (m - k) >= 2 or region_size[region] <= 2;
                if (enough and n11 / size > n1_ / n) {
                    const mi = map_terms.mutualInformation(n11, n1_ - n11, size - n11, n - n1_ - size + n11);
                    const idf = @log(@as(f64, @floatFromInt(@max(code_regions, 1))) / @as(f64, @floatFromInt(regions_with[stem_id])));
                    const value = mi * idf;
                    if (value > 0) {
                        const covers = try b.arena.alloc(map_terms.Cover, m - k);
                        for (rows.items[k..m], covers) |row, *c| c.* = .{ .element = self.element_of[row.sym], .value = 0 };
                        try region_terms.append(b.arena, .{ .region = region, .stem = stem_id, .value = @floatCast(value), .covers = covers });
                    }
                }
                k = m;
            }
            std.mem.sort(TermCandidate, region_terms.items, {}, termValueMore);
            const keep = @min(region_terms.items.len, b.options.terms_per_region);
            if (keep != 0) {
                const top = region_terms.items[0].value;
                for (region_terms.items[0..keep]) |*t| {
                    const scaled: f32 = b.options.term_value * (t.value / top);
                    for (@constCast(t.covers)) |*c| c.value = scaled;
                    try candidates.append(b.arena, t.*);
                }
            }
            i = r_end;
        }
        self.term_candidates = candidates.items;
    }

    fn pathCoverage(self: *Planner) !void {
        const b = self.b;
        self.base_cover = try b.arena.alloc(f32, self.code_syms.len);
        @memset(self.base_cover, 0);
        var scratch: std.ArrayList(u32) = .empty;
        var sink: PartSink = .{ .stems = &self.stems, .out = &scratch, .arena = b.arena };
        for (self.term_candidates) |t| {
            const region = b.regions.items[t.region];
            scratch.clearRetainingCapacity();
            try map_terms.eachPart(region.line_path, &sink);
            const shown = for (scratch.items) |id| {
                if (id == t.stem) break true;
            } else false;
            if (!shown) continue;
            for (t.covers) |c| {
                if (c.value > self.base_cover[c.element]) self.base_cover[c.element] = c.value;
            }
        }
        self.file_shown = try b.arena.alloc(bool, b.files.len);
        @memset(self.file_shown, false);
        for (b.regions.items) |region| {
            if (region.family != .code) continue;
            for (region.files) |k| {
                const f = b.files[k];
                const rel = f.state.path[region.dir.len..];
                const visible = region.files.len == 1 or (std.mem.indexOfScalar(u8, rel, '/') == null and std.mem.indexOf(u8, region.label, rel) != null);
                if (!visible) continue;
                self.file_shown[k] = true;
                var s = f.first_symbol;
                while (s < f.first_symbol + f.symbol_count) : (s += 1) {
                    const e = self.element_of[s];
                    if (e != none and b.options.file_value > self.base_cover[e]) self.base_cover[e] = b.options.file_value;
                }
            }
        }
    }

    fn forceEntries(self: *Planner) !void {
        const b = self.b;
        self.forced = try b.arena.alloc(bool, self.code_syms.len);
        @memset(self.forced, false);
        for (b.regions.items) |r| {
            if (r.family != .code) continue;
            var best: ?u32 = null;
            for (r.files) |k| {
                const f = b.files[k];
                var s = f.first_symbol;
                while (s < f.first_symbol + f.symbol_count) : (s += 1) {
                    const e = b.entry_of[s] orelse continue;
                    if (e.kind == .api) continue;
                    if (best == null or b.weight[s] > b.weight[best.?]) best = s;
                }
            }
            if (best) |s| {
                const e = self.element_of[s];
                self.forced[e] = true;
                self.base_cover[e] = 1;
            }
        }
    }

    fn stemSpecificity(self: *Planner) ![]f32 {
        const b = self.b;
        var df: std.StringHashMapUnmanaged(u32) = .empty;
        var words: std.ArrayList(std.ArrayList([]const u8)) = .empty;
        var code_files: u32 = 0;
        for (b.files) |f| {
            var list: std.ArrayList([]const u8) = .empty;
            if (f.family == .code) {
                code_files += 1;
                var collect: WordSink = .{ .arena = b.arena, .out = &list };
                try map_terms.eachPart(fileStem(f.state.path), &collect);
                for (list.items) |word| {
                    const entry = try df.getOrPut(b.arena, word);
                    if (!entry.found_existing) entry.value_ptr.* = 0;
                    entry.value_ptr.* += 1;
                }
            }
            try words.append(b.arena, list);
        }
        const top = @log(@as(f64, @floatFromInt(@max(code_files, 2))));
        const out = try b.arena.alloc(f32, b.files.len);
        for (words.items, out) |list, *slot| {
            var best: f64 = 0;
            for (list.items) |word| {
                const count: f64 = @floatFromInt(df.get(word) orelse 1);
                best = @max(best, @log(@as(f64, @floatFromInt(@max(code_files, 2))) / count));
            }
            slot.* = @floatCast(@max(0.05, @min(1.0, best / top)));
        }
        return out;
    }

    fn select(self: *Planner, item_budget: u64) !Selection {
        const b = self.b;
        const weights = try b.arena.alloc(f64, self.code_syms.len);
        for (self.code_syms, weights) |s, *w| w.* = b.weight[s];
        if (b.options.region_balance > 0) {
            const totals = try b.arena.alloc(f64, b.regions.items.len);
            @memset(totals, 0);
            for (self.code_syms, weights) |s, w| totals[b.files[b.syms.items[s].file].region] += w;
            for (self.code_syms, weights) |s, *w| {
                const total = totals[b.files[b.syms.items[s].file].region];
                if (total > 0) w.* /= std.math.pow(f64, total, b.options.region_balance);
            }
        }
        var candidates: std.ArrayList(map_terms.Candidate) = .empty;
        var groups: std.ArrayList(std.ArrayList(u32)) = .empty;
        var group_of: std.StringHashMapUnmanaged(u32) = .empty;
        var group_cost: std.ArrayList(u64) = .empty;
        for (self.code_syms, 0..) |s, e| {
            if (self.forced[e]) continue;
            const sym = b.syms.items[s];
            const f = b.files[sym.file];
            if (!eligibleName(f.state.facts.defs, sym.def)) continue;
            const d = f.state.facts.defs[sym.def];
            const key = try std.fmt.allocPrint(b.arena, "{d}\x00{s}", .{ f.region, d.qname });
            const entry = try group_of.getOrPut(b.arena, key);
            if (!entry.found_existing) {
                entry.value_ptr.* = @intCast(groups.items.len);
                try groups.append(b.arena, .empty);
                try group_cost.append(b.arena, nameCost(f.state.facts.defs, d));
            }
            try groups.items[entry.value_ptr.*].append(b.arena, @intCast(e));
        }
        for (groups.items, group_cost.items) |members, cost| {
            const covers = try b.arena.alloc(map_terms.Cover, members.items.len);
            for (members.items, covers) |e, *c| c.* = .{ .element = e, .value = 1 };
            try candidates.append(b.arena, .{ .cost = @intCast(cost), .covers = covers });
        }
        const names_end = candidates.items.len;
        for (self.term_candidates) |t| {
            try candidates.append(b.arena, .{ .cost = @intCast(self.stems.display(t.stem).len + 2), .covers = t.covers });
        }
        const terms_end = candidates.items.len;
        const specific = if (b.options.file_specificity) try self.stemSpecificity() else null;
        var file_of: std.ArrayList(u32) = .empty;
        for (b.files, 0..) |f, k| {
            if (f.family != .code or f.symbol_count == 0 or self.file_shown[k]) continue;
            const covers = try b.arena.alloc(map_terms.Cover, f.symbol_count);
            var n: usize = 0;
            var s = f.first_symbol;
            while (s < f.first_symbol + f.symbol_count) : (s += 1) {
                const e = self.element_of[s];
                if (e == none) continue;
                const factor: f32 = if (specific) |sp| sp[k] else 1;
                covers[n] = .{ .element = e, .value = b.options.file_value * factor };
                n += 1;
            }
            if (n == 0) continue;
            try candidates.append(b.arena, .{ .cost = @intCast(fileStem(f.state.path).len + 2), .covers = covers[0..n] });
            try file_of.append(b.arena, @intCast(k));
        }
        const picked = try map_terms.greedy(b.arena, weights, self.base_cover, candidates.items, item_budget);
        const names = try b.arena.alloc(bool, self.code_syms.len);
        @memcpy(names, self.forced);
        const chosen_terms = try b.arena.alloc(bool, self.term_candidates.len);
        @memset(chosen_terms, false);
        const chosen_files = try b.arena.alloc(bool, b.files.len);
        @memset(chosen_files, false);
        for (picked.chosen) |c| {
            if (c < names_end) {
                for (groups.items[c].items) |e| names[e] = true;
            } else if (c < terms_end) {
                chosen_terms[c - names_end] = true;
            } else {
                chosen_files[file_of.items[c - terms_end]] = true;
            }
        }
        return .{ .names = names, .terms = self.term_candidates, .chosen_terms = chosen_terms, .files = chosen_files, .forced = self.forced };
    }
};

const WordSink = struct {
    arena: Allocator,
    out: *std.ArrayList([]const u8),

    pub fn part(self: *WordSink, text: []const u8) !void {
        if (map_terms.isStop(text)) return;
        var buf: [map_terms.max_part]u8 = undefined;
        const word = map_terms.stem(text, &buf);
        for (self.out.items) |seen| {
            if (std.mem.eql(u8, seen, word)) return;
        }
        try self.out.append(self.arena, try self.arena.dupe(u8, word));
    }
};

fn stemKind(stem: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, stem, '.') orelse return "";
    return stem[dot + 1 ..];
}

fn stemBase(stem: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, stem, '.') orelse return stem;
    return stem[0..dot];
}

fn writeFolded(arena: Allocator, w: *Writer, stems: []const []const u8) !void {
    var kinds: std.ArrayList([]const u8) = .empty;
    for (stems) |stem| {
        const kind = stemKind(stem);
        for (kinds.items) |k| {
            if (std.mem.eql(u8, k, kind)) break;
        } else try kinds.append(arena, kind);
    }
    var first = true;
    for (kinds.items) |kind| {
        var members: usize = 0;
        for (stems) |stem| {
            if (std.mem.eql(u8, stemKind(stem), kind)) members += 1;
        }
        if (kind.len == 0 or members < 2) {
            for (stems) |stem| {
                if (!std.mem.eql(u8, stemKind(stem), kind)) continue;
                if (!first) try w.writeAll(", ");
                first = false;
                try w.writeAll(stem);
            }
            continue;
        }
        if (!first) try w.writeAll(", ");
        first = false;
        try w.print("{s}{{", .{kind});
        var n: usize = 0;
        for (stems) |stem| {
            if (!std.mem.eql(u8, stemKind(stem), kind)) continue;
            if (n != 0) try w.writeAll(", ");
            n += 1;
            try w.writeAll(stemBase(stem));
        }
        try w.writeByte('}');
    }
}

fn fileStem(path: []const u8) []const u8 {
    const base = basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return base;
    if (dot == 0) return base;
    return base[0..dot];
}

fn termValueMore(_: void, a: TermCandidate, b: TermCandidate) bool {
    if (a.value != b.value) return a.value > b.value;
    return a.stem < b.stem;
}

fn nameCost(defs: []const facts.Def, d: facts.Def) u64 {
    if (d.parent != none and d.parent != 0) {
        const parent = defs[d.parent];
        if (parent.kind == .class or parent.kind == .interface or parent.kind == .enumeration) return d.name.len + 2 + (parent.name.len + 2) / 2;
    }
    return d.qname.len + 2;
}

const Heading = struct {
    dir: []const u8,
    first: u32,
    count: u32,
};

fn headings(arena: Allocator, regions: []const Region, lo: u32, hi: u32, limit: u32, prefix: []const u8, out: *std.ArrayList(Heading)) Allocator.Error!void {
    if (lo >= hi) return;
    var common = regions[lo].dir;
    for (regions[lo + 1 .. hi]) |r| common = map_tree.commonDir(common, r.dir);
    if (common.len < prefix.len) common = prefix;
    if (hi - lo <= limit) {
        try out.append(arena, .{ .dir = common, .first = lo, .count = hi - lo });
        return;
    }
    var i = lo;
    while (i < hi) {
        const rest = regions[i].dir[common.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/');
        if (slash == null) {
            var j = i;
            while (j < hi and regions[j].dir.len == common.len) j += 1;
            try out.append(arena, .{ .dir = common, .first = i, .count = j - i });
            i = j;
            continue;
        }
        const child = regions[i].dir[0 .. common.len + slash.? + 1];
        var j = i + 1;
        while (j < hi and std.mem.startsWith(u8, regions[j].dir, child)) j += 1;
        if (j - i == hi - lo) {
            try out.append(arena, .{ .dir = common, .first = i, .count = j - i });
            return;
        }
        try headings(arena, regions, i, j, limit, child, out);
        i = j;
    }
}

const Group = struct {
    owner: ?u32,
    members: std.ArrayList(u32) = .empty,
    weight: f64 = 0,
};

fn groupLess(_: void, a: Group, b: Group) bool {
    if (a.weight != b.weight) return a.weight > b.weight;
    const ao = a.owner orelse a.members.items[0];
    const bo = b.owner orelse b.members.items[0];
    return ao < bo;
}

const Renderer = struct {
    b: *Builder,
    planner: *Planner,
    out: Writer.Allocating,

    fn tagOf(self: *const Renderer, s: u32) ?[]const u8 {
        const e = self.b.entry_of[s] orelse return null;
        if (e.kind == .api) return null;
        return e.tag;
    }

    fn writeName(self: *Renderer, s: u32, short: bool) !void {
        const w = &self.out.writer;
        const sym = self.b.syms.items[s];
        const d = self.b.files[sym.file].state.facts.defs[sym.def];
        if (self.tagOf(s)) |tag| try w.print("{s} ", .{tag});
        try w.writeAll(if (short) d.name else d.qname);
    }

    fn ownerOf(self: *const Renderer, s: u32) ?u32 {
        const sym = self.b.syms.items[s];
        const defs = self.b.files[sym.file].state.facts.defs;
        const d = defs[sym.def];
        if (d.parent == none or d.parent == 0) return null;
        const parent = defs[d.parent];
        if (parent.kind != .class and parent.kind != .interface and parent.kind != .enumeration and parent.kind != .variable) return null;
        return self.b.symIndex(sym.file, d.parent);
    }

    fn names(self: *Renderer, region: *Region, all: []const u32) !void {
        const arena = self.b.arena;
        var groups: std.ArrayList(Group) = .empty;
        var at: std.AutoHashMapUnmanaged(u32, usize) = .empty;
        var printed: std.StringHashMapUnmanaged(void) = .empty;
        var unique: std.ArrayList(u32) = .empty;
        for (all) |s| {
            const sym = self.b.syms.items[s];
            const qname = self.b.files[sym.file].state.facts.defs[sym.def].qname;
            const seen = try printed.getOrPut(arena, qname);
            if (seen.found_existing) continue;
            try unique.append(arena, s);
        }
        const selected = unique.items;
        for (selected) |s| {
            const owner = self.ownerOf(s);
            const key = owner orelse s;
            const entry = try at.getOrPut(arena, key);
            if (!entry.found_existing) {
                entry.value_ptr.* = groups.items.len;
                try groups.append(arena, .{ .owner = owner });
            }
            const g = &groups.items[entry.value_ptr.*];
            if (owner == null) {
                g.owner = s;
            } else {
                try g.members.append(arena, s);
            }
            g.weight = @max(g.weight, self.b.weight[s]);
        }
        for (groups.items) |*g| {
            std.mem.sort(u32, g.members.items, self.b, weightMore);
        }
        std.mem.sort(Group, groups.items, {}, groupLess);
        const w = &self.out.writer;
        var keys: std.ArrayList(SymbolId) = .empty;
        for (groups.items, 0..) |g, gi| {
            if (gi != 0) try w.writeAll(", ");
            if (g.owner) |o| {
                try self.writeName(o, false);
                if (selectedHas(selected, o)) try keys.append(arena, self.b.symbolId(o));
            }
            if (g.members.items.len != 0) {
                try w.writeByte('{');
                for (g.members.items, 0..) |m, mi| {
                    if (mi != 0) try w.writeAll(", ");
                    try self.writeName(m, true);
                    try keys.append(arena, self.b.symbolId(m));
                }
                try w.writeByte('}');
            }
        }
        region.key_symbols = try dedupeIds(arena, keys.items);
    }
};

fn selectedHas(selected: []const u32, s: u32) bool {
    for (selected) |x| {
        if (x == s) return true;
    }
    return false;
}

fn dedupeIds(arena: Allocator, ids: []const SymbolId) ![]const SymbolId {
    var out: std.ArrayList(SymbolId) = .empty;
    outer: for (ids) |id| {
        for (out.items) |seen| {
            if (seen.file == id.file and seen.slot == id.slot) continue :outer;
        }
        try out.append(arena, id);
    }
    return out.items;
}

fn weightMore(b: *Builder, x: u32, y: u32) bool {
    if (b.weight[x] != b.weight[y]) return b.weight[x] > b.weight[y];
    return x < y;
}

const FileMass = struct {
    b: *Builder,
    planner: *Planner,

    fn mass(self: FileMass, k: u32) f64 {
        const f = self.b.files[k];
        var total: f64 = 0;
        for (self.b.weight[f.first_symbol .. f.first_symbol + f.symbol_count]) |w| total += w;
        return total;
    }

    fn more(self: FileMass, x: u32, y: u32) bool {
        const a = self.mass(x);
        const c = self.mass(y);
        if (a != c) return a > c;
        return x < y;
    }
};

fn hexShort(root: []const u8) [16]u8 {
    var out: [16]u8 = undefined;
    const hex = "0123456789abcdef";
    for (root[0..8], 0..) |byte, i| {
        out[i * 2] = hex[byte >> 4];
        out[i * 2 + 1] = hex[byte & 15];
    }
    return out;
}

fn render(b: *Builder, planner: *Planner, selection: Selection, complete: bool, stats: *Stats) ![]const u8 {
    const arena = b.arena;
    var r: Renderer = .{ .b = b, .planner = planner, .out = .init(arena) };
    const w = &r.out.writer;
    const zero = std.mem.zeroes(answer.Digest);
    const root_bytes: []const u8 = if (std.mem.eql(u8, &b.options.cert.root, &zero)) &b.store.root else &b.options.cert.root;
    const short = hexShort(root_bytes);
    var code: u32 = 0;
    var tests: u32 = 0;
    for (b.regions.items) |reg| {
        if (reg.family == .code) code += 1 else tests += 1;
    }
    try w.print("# Project map\nsnapshot {s} | {d} files | {d} symbols | {d} regions ({d} code, {d} test){s}\n", .{ &short, b.files.len, b.syms.items.len, b.regions.items.len, code, tests, if (complete) " | every symbol is listed" else "" });
    try w.writeAll("Every symbol is in exactly one region; every region is listed. Line: id, path under the ## heading ({a/, b.ts} = these sibling entries; x .. y = sibling entries x to y), key symbols by weight (Class{member}; GET/POST/cmd/on = route, command, event handler), [more files; service{a, b} = a.service and b.service], #terms.\n");
    try w.writeAll("emetgate_region r1 lists every symbol of region r1 with line, kind, signature and doc; emetgate_evidence Class.method returns its code, callers, callees and tests.\n");
    var names_count: u32 = 0;
    var files_count: u32 = 0;
    var terms_count: u32 = 0;
    var entries_count: u32 = 0;
    const terms_of = try arena.alloc(std.ArrayList(u32), b.regions.items.len);
    for (terms_of) |*t| t.* = .empty;
    for (selection.terms, selection.chosen_terms, 0..) |t, chosen, ti| {
        if (chosen) try terms_of[t.region].append(arena, @intCast(ti));
    }
    for ([_]Family{ .code, .tests }) |family| {
        var lo: u32 = 0;
        while (lo < b.regions.items.len and b.regions.items[lo].family != family) lo += 1;
        var hi = lo;
        while (hi < b.regions.items.len and b.regions.items[hi].family == family) hi += 1;
        if (lo == hi) continue;
        if (family == .tests) try w.writeAll("\n# Tests\n");
        var heads: std.ArrayList(Heading) = .empty;
        try headings(arena, b.regions.items, lo, hi, b.options.heading_regions, "", &heads);
        for (heads.items) |h| {
            try w.print("## {s}\n", .{if (h.dir.len == 0) "./" else h.dir});
            for (b.regions.items[h.first .. h.first + h.count]) |*reg| {
                const rel = reg.line_path[h.dir.len..];
                try w.print("r{d} {s}", .{ reg.id + 1, if (rel.len == 0) "./" else rel });
                if (family == .code) {
                    var selected: std.ArrayList(u32) = .empty;
                    for (reg.files) |k| {
                        const f = b.files[k];
                        var s = f.first_symbol;
                        while (s < f.first_symbol + f.symbol_count) : (s += 1) {
                            const e = planner.element_of[s];
                            if (complete or (e != none and selection.names[e])) try selected.append(arena, s);
                        }
                    }
                    std.mem.sort(u32, selected.items, b, weightMore);
                    if (selected.items.len != 0) {
                        try w.writeAll(": ");
                        try r.names(reg, selected.items);
                        names_count += @intCast(selected.items.len);
                        for (selected.items) |s| {
                            if (r.tagOf(s) != null) entries_count += 1;
                        }
                    }
                    var shown_files: std.ArrayList(u32) = .empty;
                    for (reg.files) |k| {
                        if (selection.files[k]) try shown_files.append(arena, k);
                    }
                    if (shown_files.items.len != 0) {
                        std.mem.sort(u32, shown_files.items, FileMass{ .b = b, .planner = planner }, FileMass.more);
                        try w.writeAll(" [");
                        const stems = try arena.alloc([]const u8, shown_files.items.len);
                        for (shown_files.items, stems) |k, *stem| stem.* = fileStem(b.files[k].state.path);
                        try writeFolded(arena, w, stems);
                        try w.writeByte(']');
                        files_count += @intCast(shown_files.items.len);
                    }
                    var concepts: std.ArrayList([]const u8) = .empty;
                    for (terms_of[reg.id].items) |ti| {
                        const t = selection.terms[ti];
                        const display = planner.stems.display(t.stem);
                        try w.print(" #{s}", .{display});
                        try concepts.append(arena, display);
                        terms_count += 1;
                    }
                    reg.concepts = concepts.items;
                }
                try w.writeByte('\n');
            }
        }
    }
    stats.names = names_count;
    stats.files_named = files_count;
    stats.terms = terms_count;
    stats.entries = entries_count;
    return r.out.written();
}

fn snapshotOf(b: *Builder) !Snapshot {
    const arena = b.arena;
    const files = try arena.alloc(FileSnap, b.files.len);
    const by_store_id = try arena.alloc(u32, b.store.files.items.len);
    @memset(by_store_id, none);
    for (b.files, files, 0..) |f, *slot, k| {
        var symbols: []SymbolSnap = &.{};
        if (f.state.status == .indexed) {
            symbols = try arena.alloc(SymbolSnap, f.symbol_count);
            for (b.syms.items[f.first_symbol .. f.first_symbol + f.symbol_count], symbols) |s, *snap| {
                const d = f.state.facts.defs[s.def];
                snap.* = .{ .kind = d.kind, .qname = try arena.dupe(u8, d.qname), .hash = d.hash, .line = d.line, .span = d.span };
            }
        }
        slot.* = .{
            .path = try arena.dupe(u8, f.state.path),
            .status = f.state.status,
            .parse_errors = f.state.facts.parse_errors,
            .content_hash = f.state.content_hash,
            .region = f.region,
            .symbols = symbols,
        };
        by_store_id[f.id] = @intCast(k);
    }
    return .{ .store_root = b.store.root, .cert = b.options.cert, .files = files, .by_store_id = by_store_id };
}

fn ownRegions(arena: Allocator, b: *Builder, snapshot: Snapshot) ![]Region {
    const regions = try arena.dupe(Region, b.regions.items);
    for (regions) |*r| {
        r.dir = try arena.dupe(u8, r.dir);
        r.label = try arena.dupe(u8, r.label);
        r.path = try arena.dupe(u8, r.path);
        r.line_path = try arena.dupe(u8, r.line_path);
    }
    _ = snapshot;
    return regions;
}

pub fn buildMap(arena: Allocator, store: *const Store, options: MapOptions) !Map {
    var b: Builder = .{ .arena = arena, .store = store, .options = options };
    try b.collectFiles();
    try b.partition();
    var stats: Stats = .{};
    try b.rank(&stats.pagerank_iterations);
    try b.entries();
    try b.apiEntries();
    var planner = try Planner.init(&b);
    try planner.terms();
    try planner.pathCoverage();
    try planner.forceEntries();
    const total_chars: u64 = @intFromFloat(@as(f64, @floatFromInt(options.budget_tokens)) * options.chars_per_token);
    var complete_cost: u64 = 0;
    for (planner.code_syms) |s| {
        const sym = b.syms.items[s];
        complete_cost += nameCost(b.files[sym.file].state.facts.defs, b.files[sym.file].state.facts.defs[sym.def]);
    }
    const empty_selection = try planner.select(0);
    var text = try render(&b, &planner, empty_selection, false, &stats);
    const fixed: u64 = text.len;
    var complete = false;
    if (fixed + complete_cost <= total_chars) {
        const all = try render(&b, &planner, empty_selection, true, &stats);
        if (all.len <= total_chars) {
            text = all;
            complete = true;
        }
    }
    if (!complete and fixed < total_chars) {
        var item_budget: u64 = total_chars - fixed;
        var best: ?Selection = null;
        var best_len: usize = 0;
        var round: u32 = 0;
        while (round < 6) : (round += 1) {
            const selection = try planner.select(item_budget);
            var round_stats = stats;
            const candidate = try render(&b, &planner, selection, false, &round_stats);
            stats.fit_rounds = round + 1;
            if (candidate.len <= total_chars) {
                if (best == null or candidate.len > best_len) {
                    best = selection;
                    best_len = candidate.len;
                }
                const slack = total_chars - candidate.len;
                if (slack < total_chars / 200) break;
                item_budget += slack;
            } else {
                const over = candidate.len - total_chars;
                if (item_budget <= over) break;
                item_budget -= over + over / 4;
            }
        }
        const chosen = best orelse empty_selection;
        const rounds = stats.fit_rounds;
        text = try render(&b, &planner, chosen, false, &stats);
        stats.fit_rounds = rounds;
    }
    const snapshot = try snapshotOf(&b);
    stats.files = @intCast(b.files.len);
    for (b.files) |f| {
        if (f.state.status == .indexed) stats.indexed_files += 1;
    }
    stats.symbols = @intCast(b.syms.items.len);
    stats.code_symbols = @intCast(planner.code_syms.len);
    stats.regions = @intCast(b.regions.items.len);
    for (b.regions.items) |r| {
        stats.children_chars += @intCast(r.line_path.len - r.path.len);
        if (r.family == .code) stats.code_regions += 1 else stats.test_regions += 1;
        stats.max_region_chars = @max(stats.max_region_chars, r.listing_chars);
        if (r.listing_chars > b.capacity) stats.over_capacity_regions += 1;
    }
    stats.region_chars = @intCast(@min(b.capacity, std.math.maxInt(u32)));
    stats.text_chars = @intCast(text.len);
    stats.est_tokens = @intFromFloat(@ceil(@as(f64, @floatFromInt(text.len)) / options.chars_per_token));
    stats.budget_tokens = options.budget_tokens;
    stats.complete = complete;
    if (complete) {
        for (b.regions.items) |*r| r.key_symbols = r.symbols;
    }
    return .{ .snapshot = snapshot, .regions = try ownRegions(arena, &b, snapshot), .text = text, .stats = stats };
}

fn regionByPath(map: *const Map, path: []const u8) ?RegionId {
    const files = map.snapshot.files;
    var lo: usize = 0;
    var hi: usize = files.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, files[mid].path, path)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return files[mid].region,
        }
    }
    var best: ?RegionId = null;
    var best_len: usize = 0;
    for ([_]?usize{ if (lo > 0) lo - 1 else null, if (lo < files.len) lo else null }) |maybe| {
        const k = maybe orelse continue;
        const region = map.regions[files[k].region];
        if (!std.mem.startsWith(u8, path, region.dir)) continue;
        if (best == null or region.dir.len > best_len) {
            best = region.id;
            best_len = region.dir.len;
        }
    }
    return best;
}

const testing = std.testing;

test "map: file names that share a kind are folded under the kind and the rest stay whole" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var out: Writer.Allocating = .init(arena_state.allocator());
    try writeFolded(arena_state.allocator(), &out.writer, &.{ "import.service", "user.service", "gamma", "role.ee" });
    try testing.expectEqualStrings("service{import, user}, gamma, role.ee", out.written());
}
