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

pub const Field = enum(u3) { name, owner, path, body, file, doc };
pub const field_count = 6;

pub const Params = struct {
    k1: f64 = 1.2,
    weights: [field_count]f64 = .{ 3.0, 1.5, 1.0, 1.0, 0.5, 2.0 },
    b: [field_count]f64 = .{ 0.3, 0.3, 0.3, 0.75, 0.75, 0.3 },
    alpha: f64 = 0.3,
    proximity: f64 = 1.0,
    size: f64 = 0.25,
    tie: f64 = 0.1,
};

const PieceList = struct {
    arena: Allocator,
    items: std.ArrayList([]const u8) = .empty,

    pub fn piece(self: *PieceList, term: []const u8, kind: question_terms.PieceKind, raw: []const u8) !void {
        _ = kind;
        _ = raw;
        try self.items.append(self.arena, try self.arena.dupe(u8, term));
    }
};

pub const Terms = struct {
    lex: *const Lexicon,
    concepts: []const question_terms.Concept,
    group: []const u8 = &.{},
    groups: u32 = 0,
    by_stem: std.StringHashMapUnmanaged(u64) = .empty,

    pub fn ofQuestion(arena: Allocator, lex: *const Lexicon, question: []const u8) !Terms {
        const query = try question_terms.build(arena, lex, question, null, .{});
        const tokens = try question_terms.tokenize(arena, lex, question);
        var together: std.ArrayList([]const []const u8) = .empty;
        for (tokens) |t| {
            if (t.kind != .identifier and t.kind != .path) continue;
            var pieces: PieceList = .{ .arena = arena };
            try question_terms.eachPiece(lex, t.text, &pieces);
            var low: std.ArrayList(u8) = .empty;
            for (t.text) |c| try low.append(arena, std.ascii.toLower(c));
            var buf: [lexicon_mod.max_word]u8 = undefined;
            try pieces.items.append(arena, try arena.dupe(u8, lex.enStem(low.items, &buf)));
            try together.append(arena, pieces.items.items);
        }
        return ofConcepts(arena, lex, query.concepts, together.items);
    }

    pub fn ofConcepts(arena: Allocator, lex: *const Lexicon, concepts: []const question_terms.Concept, together: []const []const []const u8) !Terms {
        var terms: Terms = .{ .lex = lex, .concepts = concepts[0..@min(concepts.len, max_concepts)] };
        var parent: [max_concepts]u8 = undefined;
        for (&parent, 0..) |*p, i| p.* = @intCast(i);
        for (terms.concepts, 0..) |c, i| {
            for (c.alternatives) |alt| {
                const entry = try terms.by_stem.getOrPut(arena, alt);
                if (!entry.found_existing) entry.value_ptr.* = 0;
                entry.value_ptr.* |= bit(@intCast(i));
            }
        }
        var masks = terms.by_stem.valueIterator();
        while (masks.next()) |mask| unite(&parent, mask.*);
        for (together) |pieces| {
            var mask: u64 = 0;
            for (pieces) |piece| mask |= terms.by_stem.get(piece) orelse 0;
            unite(&parent, mask);
        }
        const group = try arena.alloc(u8, terms.concepts.len);
        var ids = [_]u8{0xff} ** max_concepts;
        for (group, 0..) |*g, i| {
            const root = find(&parent, @intCast(i));
            if (ids[root] == 0xff) {
                ids[root] = @intCast(terms.groups);
                terms.groups += 1;
            }
            g.* = ids[root];
        }
        terms.group = group;
        return terms;
    }
};

fn find(parent: *[max_concepts]u8, i: u8) u8 {
    var at = i;
    while (parent[at] != at) at = parent[at];
    return at;
}

fn unite(parent: *[max_concepts]u8, mask: u64) void {
    if (mask == 0) return;
    const first = find(parent, @intCast(@ctz(mask)));
    var rest = mask;
    while (rest != 0) {
        const other = find(parent, @intCast(@ctz(rest)));
        rest &= rest - 1;
        if (other != first) parent[other] = first;
    }
}

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

    pub fn piece(self: *Sink, term: []const u8, kind: question_terms.PieceKind, raw: []const u8) !void {
        _ = kind;
        _ = raw;
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

const Match = struct {
    mask: u64,
    pieces: u32,
};

const Counter = struct {
    arena: Allocator,
    index: *Index,
    ids: std.ArrayList(u32) = .empty,

    pub fn piece(self: *Counter, term: []const u8, kind: question_terms.PieceKind, raw: []const u8) !void {
        _ = kind;
        _ = raw;
        const entry = try self.index.stems.getOrPut(self.arena, term);
        if (!entry.found_existing) {
            entry.key_ptr.* = try self.arena.dupe(u8, term);
            entry.value_ptr.* = self.index.stem_count;
            self.index.stem_count += 1;
        }
        try self.ids.append(self.arena, entry.value_ptr.*);
    }
};

pub const FileIndex = struct {
    hash: facts.Hash,
    path: u32,
    names: []const u32,
    owners: []const u32,
    docs: []const u32,
    refs: []const u32,
    loose: []const u32,
};

pub const Index = struct {
    arena: Allocator,
    lex: *const Lexicon,
    stems: std.StringHashMapUnmanaged(u32) = .empty,
    stem_count: u32 = 0,
    texts: std.StringHashMapUnmanaged(u32) = .empty,
    text_stems: std.ArrayList([]const u32) = .empty,
    files: []?FileIndex = &.{},
    stem_mask: []u64 = &.{},
    memo: []u64 = &.{},
    memo_stamp: []u32 = &.{},
    stamp: u32 = 0,
    active: ?*const Terms = null,

    pub fn build(arena: Allocator, store: *const Store, m: *const map.Map, lex: *const Lexicon) !*Index {
        const self = try arena.create(Index);
        self.* = .{ .arena = arena, .lex = lex };
        self.files = try arena.alloc(?FileIndex, store.files.items.len);
        @memset(self.files, null);
        for (m.snapshot.files) |snap| {
            const region = &m.regions[snap.region];
            if (region.family != .code) continue;
            const id = store.fileId(snap.path) orelse continue;
            const state = store.file(id);
            if (state.status != .indexed) continue;
            const defs = state.facts.defs;
            const names = try arena.alloc(u32, defs.len);
            const owners = try arena.alloc(u32, defs.len);
            const docs = try arena.alloc(u32, defs.len);
            for (defs, names, owners, docs) |d, *n, *o, *c| {
                n.* = try self.intern(d.name);
                o.* = try self.intern(ownerOf(d.qname));
                c.* = try self.intern(d.doc);
            }
            const refs = try arena.alloc(u32, state.facts.refs.len);
            for (state.facts.refs, refs) |r, *slot| slot.* = try self.intern(r.name);
            const loose = try arena.alloc(u32, state.facts.loose.len);
            for (state.facts.loose, loose) |l, *slot| slot.* = try self.intern(l.name);
            const rel = if (std.mem.startsWith(u8, snap.path, region.dir)) snap.path[region.dir.len..] else snap.path;
            self.files[id] = .{ .hash = state.content_hash, .path = try self.intern(rel), .names = names, .owners = owners, .docs = docs, .refs = refs, .loose = loose };
        }
        self.stem_mask = try arena.alloc(u64, self.stem_count);
        @memset(self.stem_mask, 0);
        self.memo = try arena.alloc(u64, self.text_stems.items.len);
        self.memo_stamp = try arena.alloc(u32, self.text_stems.items.len);
        @memset(self.memo_stamp, 0);
        return self;
    }

    fn intern(self: *Index, text: []const u8) !u32 {
        const entry = try self.texts.getOrPut(self.arena, text);
        if (entry.found_existing) return entry.value_ptr.*;
        entry.key_ptr.* = try self.arena.dupe(u8, text);
        entry.value_ptr.* = @intCast(self.text_stems.items.len);
        var counter: Counter = .{ .arena = self.arena, .index = self };
        try question_terms.eachPiece(self.lex, text, &counter);
        try self.text_stems.append(self.arena, counter.ids.items);
        return entry.value_ptr.*;
    }

    pub fn fileOf(self: *const Index, id: FileId, state: *const FileState) ?*const FileIndex {
        if (id >= self.files.len) return null;
        if (self.files[id]) |*fi| {
            if (!std.mem.eql(u8, &fi.hash, &state.content_hash)) return null;
            return fi;
        }
        return null;
    }

    fn begin(self: *Index, terms: *const Terms) void {
        self.stamp +%= 1;
        if (self.stamp == 0) {
            @memset(self.memo_stamp, 0);
            self.stamp = 1;
        }
        var it = terms.by_stem.iterator();
        while (it.next()) |entry| {
            if (self.stems.get(entry.key_ptr.*)) |sid| self.stem_mask[sid] |= entry.value_ptr.*;
        }
        self.active = terms;
    }

    fn end(self: *Index, terms: *const Terms) void {
        var it = terms.by_stem.iterator();
        while (it.next()) |entry| {
            if (self.stems.get(entry.key_ptr.*)) |sid| self.stem_mask[sid] = 0;
        }
        self.active = null;
    }

    fn match(self: *Index, id: u32) Match {
        const stems = self.text_stems.items[id];
        if (self.memo_stamp[id] != self.stamp) {
            var mask: u64 = 0;
            for (stems) |sid| mask |= self.stem_mask[sid];
            self.memo[id] = mask;
            self.memo_stamp[id] = self.stamp;
        }
        return .{ .mask = self.memo[id], .pieces = @intCast(stems.len) };
    }
};

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
    len: [field_count]u32 = .{ 0, 0, 0, 0, 0, 0 },
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
    index: ?*Index = null,
    docs: std.ArrayList(Doc) = .empty,
    occs: std.ArrayList(Occ) = .empty,
    cache: std.StringHashMapUnmanaged(u64) = .empty,

    fn nameMask(self: *Collector, name: []const u8) !u64 {
        const entry = try self.cache.getOrPut(self.arena, name);
        if (!entry.found_existing) entry.value_ptr.* = (try match(self.terms, name)).mask;
        return entry.value_ptr.*;
    }

    fn text(self: *Collector, fi: ?*const FileIndex, id: u32, value: []const u8) !Match {
        if (fi != null) return self.index.?.match(id);
        const found = try match(self.terms, value);
        return .{ .mask = found.mask, .pieces = found.pieces };
    }

    fn word(self: *Collector, fi: ?*const FileIndex, id: u32, value: []const u8) !u64 {
        if (fi != null) return self.index.?.match(id).mask;
        return self.nameMask(value);
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
        const fi: ?*const FileIndex = if (self.index) |ix| ix.fileOf(rf.id, state) else null;
        const rel = if (std.mem.startsWith(u8, rf.path, self.region.dir)) rf.path[self.region.dir.len..] else rf.path;
        const path_match = try self.text(fi, if (fi) |x| x.path else 0, rel);
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
            const name = try self.text(fi, if (fi) |x| x.names[di] else 0, d.name);
            const owner = try self.text(fi, if (fi) |x| x.owners[di] else 0, ownerOf(d.qname));
            const comment = try self.text(fi, if (fi) |x| x.docs[di] else 0, d.doc);
            const slot = &self.docs.items[doc];
            slot.len = .{ name.pieces, owner.pieces, path_match.pieces, 0, 0, comment.pieces };
            try self.mark(doc, name.mask, .name, d.line);
            try self.mark(doc, owner.mask, .owner, none);
            try self.mark(doc, path_match.mask, .path, none);
            try self.mark(doc, comment.mask, .doc, d.line);
        }
        if (self.docs.items.len == first_doc) return;
        var file_counts = [_]u32{0} ** max_concepts;
        var file_mask: u64 = 0;
        var file_len: u32 = 0;
        for (state.facts.loose, 0..) |l, li| {
            file_len += l.count;
            const mask = try self.word(fi, if (fi) |x| x.loose[li] else 0, l.name);
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
            const mask = try self.word(fi, if (fi) |x| x.names[di] else 0, d.name);
            var steps: u32 = 0;
            while (doc != none and steps < max_depth) : (steps += 1) {
                self.docs.items[doc].len[@intFromEnum(Field.body)] += 1;
                if (mask != 0) try self.mark(doc, mask, .body, d.line);
                doc = self.docs.items[doc].up;
            }
        }
        for (state.facts.refs, 0..) |r, ri| {
            if (r.name.len == 0 or r.from >= defs.len) continue;
            var doc = nearest[r.from];
            if (doc == none) continue;
            const mask = try self.word(fi, if (fi) |x| x.refs[ri] else 0, r.name);
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

pub fn rankFiles(arena: Allocator, files: []const RegionFile, region: *const map.Region, terms: *const Terms, params: Params, index: ?*Index) !Ranking {
    var c: Collector = .{ .arena = arena, .terms = terms, .region = region, .index = index };
    if (index) |ix| ix.begin(terms);
    defer if (index) |ix| ix.end(terms);
    for (files) |rf| try c.file(rf);
    const docs = c.docs.items;
    const n: f64 = @floatFromInt(docs.len);
    var avg: [field_count]f64 = .{ 0, 0, 0, 0, 0, 0 };
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
    var best = [_]f64{0} ** max_concepts;
    var sum = [_]f64{0} ** max_concepts;
    var i: usize = 0;
    while (i < c.occs.items.len) {
        const doc = c.occs.items[i].doc;
        var end = i;
        while (end < c.occs.items.len and c.occs.items[end].doc == doc) end += 1;
        const d = docs[doc];
        spots.clearRetainingCapacity();
        @memset(best[0..terms.groups], 0);
        @memset(sum[0..terms.groups], 0);
        var j = i;
        while (j < end) {
            const concept = c.occs.items[j].concept;
            const g = terms.group[concept];
            var tf = [_]u32{0} ** field_count;
            var e = j;
            while (e < end and c.occs.items[e].concept == concept) : (e += 1) {
                const o = c.occs.items[e];
                tf[@intFromEnum(o.field)] += o.count;
                if (o.line != none) try spots.append(arena, .{ .line = o.line, .concept = g });
            }
            var pseudo: f64 = 0;
            for (0..field_count) |f| {
                if (tf[f] == 0) continue;
                const len: f64 = @floatFromInt(d.len[f]);
                const norm = 1 - params.b[f] + params.b[f] * len / avg[f];
                pseudo += params.weights[f] * @as(f64, @floatFromInt(tf[f])) / @max(norm, 1e-9);
            }
            const weight: f64 = terms.concepts[concept].weight;
            const part = weight * idf[concept] * pseudo / (params.k1 + pseudo);
            best[g] = @max(best[g], part);
            sum[g] += part;
            j = e;
        }
        var bm25: f64 = 0;
        for (best[0..terms.groups], sum[0..terms.groups]) |top, all| bm25 += top + params.tie * (all - top);
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

pub fn rankInRegion(arena: Allocator, store: *const Store, m: *const map.Map, region_id: map.RegionId, terms: *const Terms, params: Params, index: ?*Index) !Ranking {
    if (region_id >= m.regions.len) return error.UnknownRegion;
    const region = &m.regions[region_id];
    const files = try regionFiles(arena, store, m, region);
    return rankFiles(arena, files, region, terms, params, index);
}
