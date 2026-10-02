const std = @import("std");
const facts = @import("facts.zig");
const facts_store = @import("facts_store.zig");
const map = @import("map.zig");
const lexicon_mod = @import("question_lexicon.zig");
const question_terms = @import("question_terms.zig");

const Allocator = std.mem.Allocator;
const Store = facts_store.Store;
const FileState = facts_store.FileState;
const FileId = facts_store.FileId;
const Lexicon = lexicon_mod.Lexicon;
const none = facts.none;

pub const max_concepts = 64;
pub const max_depth = 64;

pub const Field = enum(u3) { name, owner, path, body, file };
pub const field_count = 5;

pub const Params = struct {
    k1: f64 = 1.2,
    weights: [field_count]f64 = .{ 3.0, 1.5, 1.0, 1.0, 0.5 },
    b: [field_count]f64 = .{ 0.3, 0.3, 0.3, 0.75, 0.75 },
    alpha: f64 = 0.3,
    proximity: f64 = 1.0,
    size: f64 = 0.25,
};

pub const Terms = struct {
    lex: *const Lexicon,
    concepts: []const question_terms.Concept,
    by_stem: std.StringHashMapUnmanaged(u64) = .empty,

    pub fn ofQuestion(arena: Allocator, lex: *const Lexicon, question: []const u8) !Terms {
        const query = try question_terms.build(arena, lex, question, null, .{});
        return ofConcepts(arena, lex, query.concepts);
    }

    pub fn ofConcepts(arena: Allocator, lex: *const Lexicon, concepts: []const question_terms.Concept) !Terms {
        var terms: Terms = .{ .lex = lex, .concepts = concepts[0..@min(concepts.len, max_concepts)] };
        for (terms.concepts, 0..) |c, i| {
            for (c.alternatives) |alt| {
                const entry = try terms.by_stem.getOrPut(arena, alt);
                if (!entry.found_existing) entry.value_ptr.* = 0;
                entry.value_ptr.* |= bit(@intCast(i));
            }
        }
        return terms;
    }
};

pub const Hit = struct {
    symbol: map.SymbolId,
    file: FileId,
    def: u32,
    path: []const u8,
    qname: []const u8,
    kind: facts.DefKind,
    line: u32,
    span: facts.Span,
    score: f64,
    matched: u64,
};

pub const Ranking = struct {
    region: map.RegionId,
    candidates: u32,
    matched: u32,
    files: u32,
    hits: []const Hit,
};

fn bit(i: u6) u64 {
    return @as(u64, 1) << i;
}

pub fn candidate(d: facts.Def) bool {
    if (d.name.len == 0) return false;
    return switch (d.kind) {
        .function, .generator, .method, .getter, .setter, .constructor, .arrow, .function_expression => true,
        else => false,
    };
}

const Sink = struct {
    terms: *const Terms,
    mask: u64 = 0,
    pieces: u32 = 0,

    pub fn piece(self: *Sink, term: []const u8, kind: question_terms.PieceKind) !void {
        _ = kind;
        self.pieces += 1;
        if (self.terms.by_stem.get(term)) |bits| self.mask |= bits;
    }
};

fn match(terms: *const Terms, text: []const u8) !Sink {
    var sink: Sink = .{ .terms = terms };
    try question_terms.eachPiece(terms.lex, text, &sink);
    return sink;
}

pub fn maskOf(terms: *const Terms, text: []const u8) !u64 {
    return (try match(terms, text)).mask;
}

fn ownerOf(qname: []const u8) []const u8 {
    const plain = qname[0 .. std.mem.indexOfScalar(u8, qname, '@') orelse qname.len];
    const dot = std.mem.lastIndexOfScalar(u8, plain, '.') orelse return "";
    return plain[0..dot];
}

const Doc = struct {
    file: FileId,
    state: *const FileState,
    def: u32,
    path: []const u8,
    len: [field_count]u32 = .{ 0, 0, 0, 0, 0 },
    mask: u64 = 0,
    up: u32 = none,
};

const Occ = struct {
    doc: u32,
    concept: u8,
    field: Field,
    line: u32,
    count: u32 = 1,
};

fn occLess(_: void, a: Occ, b: Occ) bool {
    if (a.doc != b.doc) return a.doc < b.doc;
    if (a.concept != b.concept) return a.concept < b.concept;
    if (@intFromEnum(a.field) != @intFromEnum(b.field)) return @intFromEnum(a.field) < @intFromEnum(b.field);
    return a.line < b.line;
}

const Spot = struct {
    line: u32,
    concept: u8,
};

fn spotLess(_: void, a: Spot, b: Spot) bool {
    if (a.line != b.line) return a.line < b.line;
    return a.concept < b.concept;
}

pub const RegionFile = struct {
    path: []const u8,
    id: FileId,
    state: *const FileState,
};

fn regionFileLess(_: void, a: RegionFile, b: RegionFile) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

pub fn regionFiles(arena: Allocator, store: *const Store, m: *const map.Map, region: *const map.Region) ![]RegionFile {
    var out: std.ArrayList(RegionFile) = .empty;
    for (region.files) |k| {
        const snap = m.snapshot.files[k];
        const id = store.fileId(snap.path) orelse continue;
        const state = store.file(id);
        if (state.status == .removed) continue;
        try out.append(arena, .{ .path = snap.path, .id = id, .state = state });
    }
    for (store.files.items, 0..) |*state, id| {
        if (state.status == .removed) continue;
        if (id < m.snapshot.by_store_id.len and m.snapshot.by_store_id[id] != none) continue;
        const owner = m.regionOfPath(state.path) orelse continue;
        if (owner != region.id) continue;
        try out.append(arena, .{ .path = state.path, .id = @intCast(id), .state = state });
    }
    std.mem.sort(RegionFile, out.items, {}, regionFileLess);
    return out.items;
}

const Collector = struct {
    arena: Allocator,
    terms: *const Terms,
    region: *const map.Region,
    docs: std.ArrayList(Doc) = .empty,
    occs: std.ArrayList(Occ) = .empty,
    cache: std.StringHashMapUnmanaged(u64) = .empty,

    fn nameMask(self: *Collector, name: []const u8) !u64 {
        const entry = try self.cache.getOrPut(self.arena, name);
        if (!entry.found_existing) entry.value_ptr.* = (try match(self.terms, name)).mask;
        return entry.value_ptr.*;
    }

    fn mark(self: *Collector, doc: u32, mask: u64, field: Field, line: u32) !void {
        var rest = mask;
        while (rest != 0) {
            const c: u6 = @intCast(@ctz(rest));
            rest &= rest - 1;
            try self.occs.append(self.arena, .{ .doc = doc, .concept = c, .field = field, .line = line });
            self.docs.items[doc].mask |= bit(c);
        }
    }

    fn markCounts(self: *Collector, doc: u32, mask: u64, counts: []const u32) !void {
        var rest = mask;
        while (rest != 0) {
            const c: u6 = @intCast(@ctz(rest));
            rest &= rest - 1;
            try self.occs.append(self.arena, .{ .doc = doc, .concept = c, .field = .file, .line = none, .count = counts[c] });
            self.docs.items[doc].mask |= bit(c);
        }
    }

    fn file(self: *Collector, rf: RegionFile) !void {
        const state = rf.state;
        if (state.status != .indexed) return;
        const defs = state.facts.defs;
        if (defs.len == 0) return;
        const rel = if (std.mem.startsWith(u8, rf.path, self.region.dir)) rf.path[self.region.dir.len..] else rf.path;
        const path_match = try match(self.terms, rel);
        const nearest = try self.arena.alloc(u32, defs.len);
        @memset(nearest, none);
        const first_doc: u32 = @intCast(self.docs.items.len);
        for (defs, 0..) |d, di| {
            if (di == 0 or d.kind == .module) continue;
            var up: u32 = none;
            if (d.parent != none and d.parent < di) up = nearest[d.parent];
            if (!candidate(d)) {
                nearest[di] = up;
                continue;
            }
            const doc: u32 = @intCast(self.docs.items.len);
            nearest[di] = doc;
            try self.docs.append(self.arena, .{ .file = rf.id, .state = state, .def = @intCast(di), .path = rf.path, .up = up });
            const name = try match(self.terms, d.name);
            const owner = try match(self.terms, ownerOf(d.qname));
            const slot = &self.docs.items[doc];
            slot.len = .{ name.pieces, owner.pieces, path_match.pieces, 0, 0 };
            try self.mark(doc, name.mask, .name, d.line);
            try self.mark(doc, owner.mask, .owner, none);
            try self.mark(doc, path_match.mask, .path, none);
        }
        if (self.docs.items.len == first_doc) return;
        var file_counts = [_]u32{0} ** max_concepts;
        var file_mask: u64 = 0;
        var file_len: u32 = 0;
        for (state.facts.loose) |l| {
            file_len += l.count;
            const mask = try self.nameMask(l.name);
            file_mask |= mask;
            var rest = mask;
            while (rest != 0) {
                file_counts[@ctz(rest)] += l.count;
                rest &= rest - 1;
            }
        }
        for (self.docs.items[first_doc..], first_doc..) |*d, doc| {
            d.len[@intFromEnum(Field.file)] = file_len;
            try self.markCounts(@intCast(doc), file_mask, &file_counts);
        }
        for (defs, 0..) |d, di| {
            if (di == 0 or d.kind == .module or d.parent == none or d.parent >= di) continue;
            var doc = nearest[d.parent];
            if (doc == none) continue;
            const mask = try self.nameMask(d.name);
            var steps: u32 = 0;
            while (doc != none and steps < max_depth) : (steps += 1) {
                self.docs.items[doc].len[@intFromEnum(Field.body)] += 1;
                if (mask != 0) try self.mark(doc, mask, .body, d.line);
                doc = self.docs.items[doc].up;
            }
        }
        for (state.facts.refs) |r| {
            if (r.name.len == 0 or r.from >= defs.len) continue;
            var doc = nearest[r.from];
            if (doc == none) continue;
            const mask = try self.nameMask(r.name);
            var steps: u32 = 0;
            while (doc != none and steps < max_depth) : (steps += 1) {
                self.docs.items[doc].len[@intFromEnum(Field.body)] += 1;
                if (mask != 0) try self.mark(doc, mask, .body, r.line);
                doc = self.docs.items[doc].up;
            }
        }
    }
};

fn hitLess(_: void, a: Hit, b: Hit) bool {
    if (a.score != b.score) return a.score > b.score;
    switch (std.mem.order(u8, a.path, b.path)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    if (a.line != b.line) return a.line < b.line;
    return a.def < b.def;
}

pub fn rankFiles(arena: Allocator, files: []const RegionFile, region: *const map.Region, terms: *const Terms, params: Params) !Ranking {
    var c: Collector = .{ .arena = arena, .terms = terms, .region = region };
    for (files) |rf| try c.file(rf);
    const docs = c.docs.items;
    const n: f64 = @floatFromInt(docs.len);
    var avg: [field_count]f64 = .{ 0, 0, 0, 0, 0 };
    for (docs) |d| {
        for (0..field_count) |f| avg[f] += @floatFromInt(d.len[f]);
    }
    for (&avg) |*a| a.* = if (docs.len == 0) 1 else @max(a.* / n, 1e-9);
    var df = [_]u32{0} ** max_concepts;
    var matched: u32 = 0;
    for (docs) |d| {
        if (d.mask != 0) matched += 1;
        var rest = d.mask;
        while (rest != 0) {
            df[@ctz(rest)] += 1;
            rest &= rest - 1;
        }
    }
    var idf = [_]f64{0} ** max_concepts;
    for (terms.concepts, 0..) |_, i| {
        const d: f64 = @floatFromInt(df[i]);
        idf[i] = @log((n - d + 0.5) / (d + 0.5) + 1);
    }
    const scores = try arena.alloc(f64, docs.len);
    for (docs, scores) |d, *s| {
        const span = d.state.facts.defs[d.def].span;
        s.* = params.size * @log(1 + @as(f64, @floatFromInt(span.end -| span.start)));
    }
    std.mem.sort(Occ, c.occs.items, {}, occLess);
    var spots: std.ArrayList(Spot) = .empty;
    var i: usize = 0;
    while (i < c.occs.items.len) {
        const doc = c.occs.items[i].doc;
        var end = i;
        while (end < c.occs.items.len and c.occs.items[end].doc == doc) end += 1;
        const d = docs[doc];
        var bm25: f64 = 0;
        spots.clearRetainingCapacity();
        var j = i;
        while (j < end) {
            const concept = c.occs.items[j].concept;
            var tf = [_]u32{0} ** field_count;
            var e = j;
            while (e < end and c.occs.items[e].concept == concept) : (e += 1) {
                const o = c.occs.items[e];
                tf[@intFromEnum(o.field)] += o.count;
                if (o.line != none) try spots.append(arena, .{ .line = o.line, .concept = concept });
            }
            var pseudo: f64 = 0;
            for (0..field_count) |f| {
                if (tf[f] == 0) continue;
                const len: f64 = @floatFromInt(d.len[f]);
                const norm = 1 - params.b[f] + params.b[f] * len / avg[f];
                pseudo += params.weights[f] * @as(f64, @floatFromInt(tf[f])) / @max(norm, 1e-9);
            }
            const weight: f64 = terms.concepts[concept].weight;
            bm25 += weight * idf[concept] * pseudo / (params.k1 + pseudo);
            j = e;
        }
        var proximity: f64 = 0;
        if (spots.items.len > 1) {
            std.mem.sort(Spot, spots.items, {}, spotLess);
            var gap: ?u32 = null;
            for (spots.items[1..], spots.items[0 .. spots.items.len - 1]) |b, a| {
                if (a.concept == b.concept) continue;
                const dist = b.line - a.line;
                if (gap == null or dist < gap.?) gap = dist;
            }
            if (gap) |g| proximity = @log(params.alpha + @exp(-@as(f64, @floatFromInt(g)))) - @log(params.alpha);
        }
        scores[doc] += bm25 + params.proximity * proximity;
        i = end;
    }
    const hits = try arena.alloc(Hit, docs.len);
    for (docs, scores, hits) |d, s, *h| {
        const def = d.state.facts.defs[d.def];
        h.* = .{
            .symbol = .{ .file = d.file, .slot = d.state.slots[d.def] },
            .file = d.file,
            .def = d.def,
            .path = d.path,
            .qname = def.qname,
            .kind = def.kind,
            .line = def.line,
            .span = def.span,
            .score = s,
            .matched = d.mask,
        };
    }
    std.mem.sort(Hit, hits, {}, hitLess);
    return .{ .region = region.id, .candidates = @intCast(docs.len), .matched = matched, .files = @intCast(files.len), .hits = hits };
}

pub fn rankInRegion(arena: Allocator, store: *const Store, m: *const map.Map, region_id: map.RegionId, terms: *const Terms, params: Params) !Ranking {
    if (region_id >= m.regions.len) return error.UnknownRegion;
    const region = &m.regions[region_id];
    const files = try regionFiles(arena, store, m, region);
    return rankFiles(arena, files, region, terms, params);
}
