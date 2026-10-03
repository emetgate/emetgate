const std = @import("std");
const facts = @import("../engine/facts.zig");
const fact_store = @import("../platform/fact_store.zig");
const io_seam = @import("../platform/io_seam.zig");
const map_lines = @import("../engine/map_lines.zig");
const rank = @import("../engine/map_region_rank.zig");
const term_index = @import("../engine/term_index.zig");
const evidence = @import("../engine/evidence.zig");
const tool_result = @import("tool_result.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;
const ToolResult = tool_result.ToolResult;

pub const reply_budget: usize = 63_000;
pub const pointer_budget: usize = 3_000;
pub const evidence_budget: usize = 16_000;
pub const header_chars: usize = 16;
pub const max_code_chars: usize = 1_000;
pub const max_term_file: usize = 4 * 1024 * 1024;
pub const max_ranked: usize = 1_024;
pub const max_symbol_rank: usize = 64;
pub const extra_part_penalty: f64 = 0.25;
pub const max_evidence_names: usize = 6;
pub const max_closest: usize = 3;
pub const call_output_tokens: f64 = 501;
pub const call_written_tokens: f64 = 1_008;
pub const call_read_tokens: f64 = 15_000;
pub const cache_write_price: f64 = 2;
pub const cache_read_price: f64 = 0.1;
pub const output_price: f64 = 5;
pub const call_cost: f64 = output_price * call_output_tokens + cache_write_price * call_written_tokens + cache_read_price * call_read_tokens;
pub const char_cost: f64 = (cache_write_price + cache_read_price) / chars_per_token;
pub const chars_per_token: f64 = 2.67;
pub const call_chars: f64 = call_cost / char_cost;
pub const call_share: f64 = 0.5;
pub const pointer_chance: f64 = 0.05;
pub const useful_ratio = [_]f64{ 0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.40, 0.50, 0.60, 0.80 };
pub const useful_chance = [_]f64{ 0.001, 0.005, 0.017, 0.051, 0.056, 0.114, 0.138, 0.281, 0.411, 0.554, 0.686 };

pub const explore_description = "Returns the code that matches a question: every definition of each named symbol, then the functions and top-level constants ranked by term statistics over names, paths and bodies, each one whole with a number on every line, and the addresses of named or matching ones left out.";
pub const evidence_description = "Returns the full code of up to 6 functions by qualified name (Class.method or function), as plain text.";

pub const Session = struct {
    gpa: Allocator,
    io: std.Io,
    runtime: *Runtime,
    root: []const u8,
    arena_state: std.heap.ArenaAllocator,
    real: io_seam.Real,
    store_path: ?[]u8 = null,
    repo: ?*fact_store.Repo = null,
    names: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty,
    symbols: std.ArrayList(Symbol) = .empty,
    part_df: std.StringHashMapUnmanaged(u32) = .empty,
    terms: ?term_index.Index = null,
    term_docs: std.ArrayList(Fn) = .empty,
    term_files: std.ArrayList(TermFile) = .empty,
    store_override: ?[]const u8 = null,

    pub fn create(gpa: Allocator, io: std.Io, runtime: *Runtime, root: []const u8) !*Session {
        const self = try gpa.create(Session);
        self.* = .{ .gpa = gpa, .io = io, .runtime = runtime, .root = root, .arena_state = .init(std.heap.page_allocator), .real = .init(gpa, io) };
        return self;
    }

    pub fn destroy(self: *Session) void {
        if (self.repo) |r| r.deinit();
        if (self.store_path) |p| self.gpa.free(p);
        self.real.deinit();
        self.arena_state.deinit();
        self.gpa.destroy(self);
    }

    pub fn build(self: *Session) !void {
        const arena = self.arena_state.allocator();
        self.store_path = if (self.store_override) |p| try self.gpa.dupe(u8, p) else fact_store.defaultStorePath(self.gpa, self.root) catch null;
        const repo = try fact_store.Repo.open(self.gpa, self.real.seam(), self.runtime, .{ .root_abs = self.root, .store_path = self.store_path });
        self.repo = repo;
        _ = try repo.refresh();
        for (repo.store.files.items) |state| {
            if (state.status != .indexed) continue;
            const path = try arena.dupe(u8, state.path);
            for (state.facts.defs) |d| {
                if (d.kind == .module) continue;
                try self.addName(arena, d.qname, path);
                try self.addName(arena, simpleName(d.qname), path);
                if (std.mem.indexOfScalar(u8, d.qname, '@') != null) {
                    try self.addName(arena, bareName(d.qname), path);
                    try self.addName(arena, bareName(simpleName(d.qname)), path);
                }
            }
        }
        for (repo.store.files.items, 0..) |state, id| {
            if (state.status != .indexed or isTest(state.path)) continue;
            const path = try arena.dupe(u8, state.path);
            for (state.facts.defs, 0..) |d, di| {
                if (!rank.candidate(d)) continue;
                const ws = try map_lines.words(arena, d.name);
                const parts = try arena.alloc([]const u8, ws.items.items.len);
                for (ws.items.items, parts) |word, *part| {
                    part.* = try arena.dupe(u8, stem(word));
                    const entry = try self.part_df.getOrPut(arena, part.*);
                    if (!entry.found_existing) entry.value_ptr.* = 0;
                    entry.value_ptr.* += 1;
                }
                try self.symbols.append(arena, .{ .file = @intCast(id), .def = @intCast(di), .path = path, .qname = try arena.dupe(u8, d.qname), .parts = parts });
            }
        }
    }

    fn buildTerms(self: *Session) !void {
        const arena = self.arena_state.allocator();
        const store = &self.repo.?.store;
        var index = term_index.Index.init(arena);
        self.term_docs = .empty;
        self.term_files = .empty;
        for (store.files.items, 0..) |*state, id| {
            if (state.status != .indexed) continue;
            try self.term_files.append(arena, .{ .file = @intCast(id), .hash = state.content_hash });
            if (isTest(state.path)) continue;
            const abs = try std.fs.path.join(self.gpa, &.{ self.root, state.path });
            defer self.gpa.free(abs);
            const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, abs, self.gpa, .limited(max_term_file)) catch continue;
            defer self.gpa.free(bytes);
            const path = try arena.dupe(u8, state.path);
            for (state.facts.defs, 0..) |d, di| {
                if (!rank.candidate(d) and !rank.topVariable(d)) continue;
                if (d.span.start >= d.span.end or d.span.end > bytes.len) continue;
                _ = try index.add(d.qname, state.path, bytes[d.span.start..d.span.end]);
                try self.term_docs.append(arena, .{ .file = @intCast(id), .def = @intCast(di), .path = path, .qname = try arena.dupe(u8, d.qname) });
            }
        }
        self.terms = index;
    }

    fn freshTerms(self: *Session) !void {
        const store = &self.repo.?.store;
        var indexed: usize = 0;
        for (store.files.items) |state| {
            if (state.status == .indexed) indexed += 1;
        }
        var same = self.terms != null and indexed == self.term_files.items.len;
        if (same) {
            for (self.term_files.items) |tf| {
                const state = store.file(tf.file);
                if (state.status != .indexed or !std.mem.eql(u8, &state.content_hash, &tf.hash)) {
                    same = false;
                    break;
                }
            }
        }
        if (!same) try self.buildTerms();
    }

    fn ready(self: *Session) bool {
        return self.repo != null;
    }

    fn addName(self: *Session, arena: Allocator, name: []const u8, path: []const u8) !void {
        const entry = try self.names.getOrPut(arena, name);
        if (!entry.found_existing) {
            entry.key_ptr.* = try arena.dupe(u8, name);
            entry.value_ptr.* = .empty;
        }
        for (entry.value_ptr.items) |p| {
            if (std.mem.eql(u8, p, path)) return;
        }
        try entry.value_ptr.append(arena, path);
    }

    fn definitions(self: *Session, arena: Allocator, name: []const u8) ![]const Fn {
        var out: std.ArrayList(Fn) = .empty;
        const paths = self.names.get(name) orelse return out.items;
        const store = &self.repo.?.store;
        for (paths.items) |path| {
            const id = store.fileId(path) orelse continue;
            const state = store.file(id);
            if (state.status != .indexed) continue;
            for (state.facts.defs, 0..) |d, di| {
                if (d.kind == .module) continue;
                const simple = simpleName(d.qname);
                if (!std.mem.eql(u8, d.qname, name) and !std.mem.eql(u8, simple, name) and !std.mem.eql(u8, bareName(d.qname), name) and !std.mem.eql(u8, bareName(simple), name)) continue;
                try out.append(arena, .{ .file = id, .def = @intCast(di), .path = state.path, .qname = d.qname });
            }
        }
        return out.items;
    }

    fn named(self: *Session, arena: Allocator, raw: []const u8) ![]const Fn {
        const open = std.mem.indexOfScalar(u8, raw, '(') orelse raw.len;
        const text = std.mem.trim(u8, raw[0..open], " \t");
        if (text.len == 0) return &.{};
        const direct = try self.definitions(arena, text);
        if (direct.len != 0) return direct;
        var qualifiers: std.ArrayList([]const u8) = .empty;
        var words = std.mem.tokenizeAny(u8, text, " \t");
        var last: []const u8 = text;
        while (words.next()) |word| {
            if (words.peek() == null) last = word else try qualifiers.append(arena, word);
        }
        var found = try self.definitions(arena, last);
        if (found.len == 0) {
            const dot = std.mem.lastIndexOfScalar(u8, last, '.') orelse return &.{};
            if (dot == 0 or dot + 1 >= last.len) return &.{};
            try qualifiers.append(arena, last[0..dot]);
            found = try self.definitions(arena, last[dot + 1 ..]);
        }
        if (qualifiers.items.len == 0) return found;
        var out: std.ArrayList(Fn) = .empty;
        for (found) |f| {
            const all = for (qualifiers.items) |q| {
                if (std.mem.indexOf(u8, f.path, q) == null) break false;
            } else true;
            if (all) try out.append(arena, f);
        }
        return out.items;
    }

    fn unknown(self: *Session, arena: Allocator, w: *Writer, name: []const u8) !void {
        try w.print("No symbol named {s}.", .{name});
        const near = try self.symbolScores(arena, name);
        for (near[0..@min(near.len, max_closest)], 0..) |r, i| {
            try w.print("{s}{s} {s}:{d}", .{ if (i == 0) " Closest: " else "; ", r.f.qname, r.f.path, self.defLine(r.f) });
        }
        try w.writeByte('\n');
    }

    pub fn explore(self: *Session, gpa: Allocator, args: ?Value) !ToolResult {
        const question = try tool_result.requireString(args, "question");
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        if (!self.ready()) return plain(gpa, "explore is unavailable: the repository could not be read", true);
        _ = self.repo.?.refresh() catch {};
        const names = try namesOf(arena, args);
        return plain(gpa, try self.dense(arena, question, names, reply_budget), false);
    }

    pub fn answer(self: *Session, arena: Allocator, question: []const u8, names: []const []const u8) ![]const u8 {
        return self.dense(arena, question, names, reply_budget);
    }

    pub fn evidenceTool(self: *Session, gpa: Allocator, args: ?Value) !ToolResult {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        if (!self.ready()) return plain(gpa, "evidence is unavailable: the repository could not be read", true);
        _ = self.repo.?.refresh() catch {};
        const names = try namesOf(arena, args);
        if (names.len == 0) return plain(gpa, "no names were given", false);
        const wanted = names[0..@min(names.len, max_evidence_names)];
        var out: Writer.Allocating = .init(arena);
        try out.writer.writeAll(try self.evidenceText(arena, wanted, evidence_budget));
        if (names.len > wanted.len) {
            try out.writer.print("Not read, the limit is {d} names per call: ", .{max_evidence_names});
            for (names[wanted.len..], 0..) |n, i| try out.writer.print("{s}{s}", .{ if (i == 0) "" else ", ", n });
            try out.writer.writeByte('\n');
        }
        return plain(gpa, out.written(), false);
    }

    pub fn dense(self: *Session, arena: Allocator, question: []const u8, names: []const []const u8, budget: usize) ![]const u8 {
        var joined: Writer.Allocating = .init(arena);
        try joined.writer.writeAll(question);
        for (names) |n| try joined.writer.print(" {s}", .{n});
        const store = &self.repo.?.store;

        var notes: Writer.Allocating = .init(arena);
        var containers: Writer.Allocating = .init(arena);
        var picks: std.ArrayList(Picked) = .empty;
        var at: std.AutoHashMapUnmanaged(u64, void) = .empty;
        for (names) |n| {
            var any = false;
            for (try self.named(arena, n)) |f| {
                if (isTest(f.path)) continue;
                any = true;
                if (self.container(f)) {
                    try containers.writer.print("{s}:{d} {s}\n", .{ f.path, self.defLine(f), f.qname });
                    continue;
                }
                try addPicked(arena, &picks, &at, f, 1, true);
            }
            if (!any) try self.unknown(arena, &notes.writer, n);
        }
        for (try questionIdentifiers(arena, question)) |ident| {
            for (try self.named(arena, ident)) |f| {
                if (isTest(f.path) or self.container(f)) continue;
                try addPicked(arena, &picks, &at, f, 1, true);
            }
        }
        try self.freshTerms();
        const hits = try self.terms.?.rank(arena, joined.written(), max_ranked);
        const top: f64 = if (hits.len != 0) hits[0].score else 1;
        for (hits) |hit| {
            const f = self.term_docs.items[hit.doc];
            const state = store.file(f.file);
            if (state.status != .indexed or f.def >= state.facts.defs.len) continue;
            try addPicked(arena, &picks, &at, .{ .file = f.file, .def = f.def, .path = state.path, .qname = state.facts.defs[f.def].qname }, hit.score / top, false);
        }

        var out: Writer.Allocating = .init(arena);
        try out.writer.writeAll(notes.written());
        if (containers.written().len != 0) {
            try out.writer.writeAll("Named classes, shown through their matching members:\n");
            try out.writer.writeAll(containers.written());
        }
        if (picks.items.len == 0) {
            try out.writer.writeAll("no function of the repository matched the phrase\n");
            return out.written();
        }
        var texts: std.StringHashMapUnmanaged(FileText) = .empty;
        var shown: std.ArrayList(Shown) = .empty;
        var cut: Writer.Allocating = .init(arena);
        var pointers: Writer.Allocating = .init(arena);
        const limit = budget -| pointer_budget;
        var used: usize = out.written().len;
        for (picks.items) |pk| {
            const state = store.file(pk.f.file);
            if (state.status != .indexed or pk.f.def >= state.facts.defs.len) continue;
            const d = state.facts.defs[pk.f.def];
            const ft = (try self.fileText(arena, &texts, pk.f.path)) orelse continue;
            const first = @max(d.line, 1);
            const last = @max(ft.lineOf(d.span.end), first);
            if (inside(shown.items, pk.f.file, first, last)) continue;
            const base = indentOf(ft.line(first));
            const size = blockChars(ft, first, last, base) + pk.f.path.len + pk.f.qname.len + header_chars;
            const chance: f64 = if (pk.whole) 1 else call_share * usefulAt(pk.score);
            const worth = pk.whole or @as(f64, @floatFromInt(size)) * (1 - chance) < call_chars * chance;
            if (worth and used + size <= limit) {
                try out.writer.print("{s}:{d} {s}\n", .{ pk.f.path, first, pk.f.qname });
                var k = first;
                while (k <= last) : (k += 1) try writeLine(&out.writer, ft, k, base);
                used += size;
                try shown.append(arena, .{ .file = pk.f.file, .first = first, .last = last });
                continue;
            }
            const line = try std.fmt.allocPrint(arena, "{s}:{d} {s} ({d} lines)\n", .{ pk.f.path, first, pk.f.qname, last - first + 1 });
            if (pk.whole) {
                try cut.writer.writeAll(line);
            } else if (usefulAt(pk.score) >= pointer_chance and pointers.written().len + line.len <= pointer_budget) {
                try pointers.writer.writeAll(line);
            }
        }
        if (cut.written().len != 0) {
            try out.writer.writeAll("Named definitions not shown, the reply limit was reached:\n");
            try out.writer.writeAll(cut.written());
        }
        if (pointers.written().len != 0) {
            try out.writer.writeAll("Matching functions not shown:\n");
            try out.writer.writeAll(pointers.written());
        }
        return out.written();
    }

    fn container(self: *Session, f: Fn) bool {
        const state = self.repo.?.store.file(f.file);
        if (state.status != .indexed or f.def >= state.facts.defs.len) return false;
        return switch (state.facts.defs[f.def].kind) {
            .class, .interface, .enumeration => true,
            else => false,
        };
    }

    fn symbolScores(self: *Session, arena: Allocator, text: []const u8) ![]const RankedFn {
        const ws = try map_lines.words(arena, text);
        var wanted: std.StringHashMapUnmanaged(void) = .empty;
        for (ws.items.items) |word| try wanted.put(arena, stem(word), {});
        if (wanted.count() == 0 or self.symbols.items.len == 0) return &.{};
        const total: f64 = @floatFromInt(self.symbols.items.len);
        var scored: std.ArrayList(Scored) = .empty;
        for (self.symbols.items, 0..) |sym, i| {
            var score: f64 = 0;
            var hits: usize = 0;
            for (sym.parts) |part| {
                if (!wanted.contains(part)) continue;
                const df: f64 = @floatFromInt(self.part_df.get(part) orelse 1);
                score += @log(1 + total / df);
                hits += 1;
            }
            if (hits == 0) continue;
            const extra: f64 = @floatFromInt(sym.parts.len - hits);
            try scored.append(arena, .{ .index = i, .score = score / (1 + extra_part_penalty * extra) });
        }
        std.mem.sort(Scored, scored.items, {}, Scored.greater);
        var out: std.ArrayList(RankedFn) = .empty;
        for (scored.items[0..@min(scored.items.len, max_symbol_rank)]) |sc| {
            const sym = self.symbols.items[sc.index];
            try out.append(arena, .{ .f = .{ .file = sym.file, .def = sym.def, .path = sym.path, .qname = sym.qname }, .score = sc.score });
        }
        return out.items;
    }

    fn defLine(self: *Session, f: Fn) u32 {
        const state = self.repo.?.store.file(f.file);
        if (f.def >= state.facts.defs.len) return 0;
        return state.facts.defs[f.def].line;
    }

    fn fileText(self: *Session, arena: Allocator, texts: *std.StringHashMapUnmanaged(FileText), path: []const u8) !?FileText {
        if (texts.get(path)) |t| return t;
        const abs = try std.fs.path.join(arena, &.{ self.root, path });
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, abs, arena, .limited(16 * 1024 * 1024)) catch return null;
        const ft = try textOf(arena, bytes);
        try texts.put(arena, path, ft);
        return ft;
    }

    pub fn evidenceText(self: *Session, arena: Allocator, names: []const []const u8, budget: usize) ![]const u8 {
        var targets: std.ArrayList(evidence.SymbolRef) = .empty;
        var notes: Writer.Allocating = .init(arena);
        for (names) |n| {
            const defs = try self.named(arena, n);
            if (defs.len == 0) {
                try self.unknown(arena, &notes.writer, n);
                continue;
            }
            for (defs) |f| {
                for (targets.items) |t| {
                    if (std.mem.eql(u8, t.path, f.path) and std.mem.eql(u8, t.qname, f.qname)) break;
                } else try targets.append(arena, .{ .path = f.path, .qname = f.qname });
            }
        }
        var out: Writer.Allocating = .init(arena);
        if (targets.items.len != 0) {
            const result = try self.repo.?.evidence(arena, .{ .targets = targets.items, .intent = .explain, .terms = &.{}, .include = .{ .callers = false, .callees = false, .tests = false } }, budget);
            switch (result) {
                .complete => |c| try out.writer.writeAll(c.value.text),
                .partial => |p| try out.writer.writeAll(p.value.text),
                .refused => try result.writeStatus(&out.writer, 0, "targets"),
            }
            const written = out.written();
            if (written.len != 0 and written[written.len - 1] != '\n') try out.writer.writeByte('\n');
        }
        try out.writer.writeAll(notes.written());
        return out.written();
    }
};

const Fn = struct {
    file: u32,
    def: u32,
    path: []const u8,
    qname: []const u8,
};

const Symbol = struct {
    file: u32,
    def: u32,
    path: []const u8,
    qname: []const u8,
    parts: []const []const u8,
};

const Shown = struct {
    file: u32,
    first: u32,
    last: u32,
};

fn inside(shown: []const Shown, file: u32, first: u32, last: u32) bool {
    for (shown) |s| {
        if (s.file == file and s.first <= first and last <= s.last) return true;
    }
    return false;
}

pub fn usefulAt(ratio: f64) f64 {
    var i: usize = 0;
    while (i < useful_ratio.len and ratio >= useful_ratio[i]) i += 1;
    return useful_chance[i];
}

fn digits(n: u32) usize {
    var count: usize = 1;
    var rest = n / 10;
    while (rest != 0) : (rest /= 10) count += 1;
    return count;
}

fn lineBody(ft: FileText, n: u32, base: usize) []const u8 {
    const raw = std.mem.trimEnd(u8, ft.line(n), " \t\r");
    var skip: usize = 0;
    while (skip < base and skip < raw.len and (raw[skip] == ' ' or raw[skip] == '\t')) skip += 1;
    const text = raw[skip..];
    return text[0..cutUtf8(text, max_code_chars)];
}

fn blockChars(ft: FileText, first: u32, last: u32, base: usize) usize {
    var total: usize = 0;
    var k = first;
    while (k <= last) : (k += 1) {
        const text = lineBody(ft, k, base);
        if (text.len != 0) total += digits(k) + 2 + text.len;
    }
    return total;
}

fn writeLine(w: *Writer, ft: FileText, n: u32, base: usize) !void {
    const text = lineBody(ft, n, base);
    if (text.len == 0) return;
    try w.print("{d} {s}\n", .{ n, text });
}

const TermFile = struct {
    file: u32,
    hash: facts.Hash,
};

const Picked = struct {
    f: Fn,
    score: f64,
    whole: bool,
};

fn addPicked(arena: Allocator, list: *std.ArrayList(Picked), at: *std.AutoHashMapUnmanaged(u64, void), f: Fn, score: f64, whole: bool) !void {
    const entry = try at.getOrPut(arena, keyOf(f));
    if (entry.found_existing) return;
    try list.append(arena, .{ .f = f, .score = score, .whole = whole });
}

const Scored = struct {
    index: usize,
    score: f64,

    fn greater(_: void, a: Scored, b: Scored) bool {
        if (a.score != b.score) return a.score > b.score;
        return a.index < b.index;
    }
};

const RankedFn = struct {
    f: Fn,
    score: f64,
};

const FileText = struct {
    bytes: []const u8,
    starts: []const u32,

    fn lineOf(self: FileText, offset: u32) u32 {
        var lo: usize = 0;
        var hi: usize = self.starts.len;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.starts[mid] <= offset) lo = mid else hi = mid;
        }
        return @intCast(lo + 1);
    }

    fn line(self: FileText, n: u32) []const u8 {
        if (n == 0 or n > self.starts.len) return "";
        const start = self.starts[n - 1];
        const end = if (n < self.starts.len) self.starts[n] else @as(u32, @intCast(self.bytes.len));
        return std.mem.trimEnd(u8, self.bytes[start..end], "\r\n");
    }
};

fn textOf(arena: Allocator, bytes: []const u8) !FileText {
    var starts: std.ArrayList(u32) = .empty;
    try starts.append(arena, 0);
    for (bytes, 0..) |b, i| {
        if (b == '\n') try starts.append(arena, @intCast(i + 1));
    }
    return .{ .bytes = bytes, .starts = starts.items };
}

fn indentOf(raw: []const u8) usize {
    var n: usize = 0;
    for (raw) |c| {
        if (c == ' ') {
            n += 1;
        } else if (c == '\t') {
            n += 4;
        } else break;
    }
    return n;
}

fn keyOf(f: Fn) u64 {
    return (@as(u64, f.file) << 32) | f.def;
}

fn stem(word: []const u8) []const u8 {
    if (word.len > 4 and word[word.len - 1] == 's' and word[word.len - 2] != 's') return word[0 .. word.len - 1];
    return word;
}

fn identByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

pub fn questionIdentifiers(arena: Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (!(std.ascii.isAlphabetic(c) or c == '_' or c == '$')) {
            i += 1;
            continue;
        }
        var end = i + 1;
        while (end < text.len and (identByte(text[end]) or (text[end] == '.' and end + 1 < text.len and identByte(text[end + 1])))) end += 1;
        const token = text[i..end];
        i = end;
        if (token.len < 3) continue;
        var inner_upper = false;
        for (token[1..]) |ch| {
            if (std.ascii.isUpper(ch)) inner_upper = true;
        }
        const marked = std.mem.indexOfAny(u8, token, "_.") != null;
        if (!inner_upper and !marked) continue;
        if (!contains(out.items, token)) try out.append(arena, token);
    }
    return out.items;
}

fn plain(gpa: Allocator, text: []const u8, is_error: bool) !ToolResult {
    return .{ .text = try tool_result.dupTrim(gpa, text), .is_error = is_error };
}

fn simpleName(qname: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, qname, '.') orelse return qname;
    return qname[dot + 1 ..];
}

fn bareName(qname: []const u8) []const u8 {
    return qname[0 .. std.mem.indexOfScalar(u8, qname, '@') orelse qname.len];
}

fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, name)) return true;
    }
    return false;
}

pub fn isTest(path: []const u8) bool {
    return std.mem.indexOf(u8, path, "/test/") != null or std.mem.indexOf(u8, path, ".spec.") != null or std.mem.indexOf(u8, path, "/__tests__/") != null;
}

fn cutUtf8(text: []const u8, limit: usize) usize {
    if (text.len <= limit) return text.len;
    var end = limit;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return end;
}

fn namesOf(arena: Allocator, args: ?Value) ![]const []const u8 {
    const object = args orelse return &.{};
    const items = tool_result.getStringArray(object, "names") orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (items) |item| {
        switch (item) {
            .string => |s| if (s.len != 0) try out.append(arena, s),
            else => {},
        }
    }
    return out.items;
}

const testing = std.testing;

test "map tools: test paths are recognized by folder and by the spec infix" {
    try testing.expect(isTest("packages/core/test/injector.spec.ts"));
    try testing.expect(isTest("src/__tests__/a.ts"));
    try testing.expect(!isTest("packages/core/injector/injector.ts"));
}
