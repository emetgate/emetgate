const std = @import("std");
const display_path = @import("../platform/display_path.zig");

pub const no_function_matched = "no function of the repository matched the phrase";
const facts = @import("../engine/facts.zig");
const fact_store = @import("../platform/fact_store.zig");
const io_seam = @import("../platform/io_seam.zig");
const map = @import("../engine/map.zig");
const map_lines = @import("../engine/map_lines.zig");
const registry = @import("../engine/lang/registry.zig");
const rank = @import("../engine/map_region_rank.zig");
const term_index = @import("../engine/term_index.zig");
const evidence = @import("../engine/evidence.zig");
const facts_query = @import("../engine/facts_query.zig");
const facts_store = @import("../engine/facts_store.zig");
const test_reach = @import("../engine/test_reach.zig");
const tool_result = @import("tool_result.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;
const ToolResult = tool_result.ToolResult;

pub const reply_budget: usize = 63_000;
pub const closure_budget: usize = 2_500;
pub const closure_max_defs: usize = 2;
pub const closure_signature: usize = 140;
/// Room kept in a dense reply for the closure's fixed lines around its rows.
pub const closure_reserve: usize = 360;
pub const closure_footer = "This is everything the index matched. Answer from it now. Call evidence once, with the names you need, only if a body listed here by signature or address decides the answer; otherwise write that it is not in the evidence.";
pub const pointer_budget: usize = 6_000;
pub const evidence_budget: usize = 16_000;
pub const header_chars: usize = 16;
pub const max_code_chars: usize = 1_000;
pub const max_term_file: usize = 4 * 1024 * 1024;
pub const max_ranked: usize = 1_024;
pub const max_symbol_rank: usize = 64;
pub const extra_part_penalty: f64 = 0.25;
pub const max_evidence_names: usize = 6;
pub const max_closest: usize = 3;
pub const max_graph_subjects: usize = 3;
pub const max_graph_items: usize = 8;
pub const max_impact_files: usize = 6;
pub const impact_depth: u32 = 3;
pub const graph_words = [_][]const u8{ "call", "caller", "callee", "impact", "break", "blast", "depend", "affect", "uses", "used" };
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
pub const fetch_yield: f64 = 2.7;
pub const fetch_chars: f64 = call_chars / fetch_yield;
pub const pointer_chars: f64 = 80;
pub const pointer_chance: f64 = pointer_chars / fetch_chars;
pub const min_mention: usize = 3;
pub const mention_count = [_]u32{ 2, 4 };
pub const mention_chance = [_]f64{ 0.013, 0.029, 0.044 };
pub const useful_ratio = [_]f64{ 0.02, 0.04, 0.06, 0.08, 0.10, 0.15, 0.20, 0.30 };
pub const useful_chance = [_]f64{ 0.009, 0.012, 0.031, 0.045, 0.094, 0.110, 0.199, 0.482, 0.589 };

/// How explore and evidence fill their replies: `full` sends whole, verbatim code within one
/// large budget; `dense` uses the smaller budgets below and compresses the code it was not asked for.
pub const ExploreMode = enum { full, dense };
pub const explore_mode_flag = "--explore-mode";
pub const dense_first_budget: usize = 20_000;
pub const dense_later_budget: usize = 8_000;
pub const dense_evidence_budget: usize = 20_000;
pub const dense_closure_budget: usize = 1_200;
pub const dense_pointer_budget: usize = 1_200;
pub const dense_marker = " [dense]";
pub const dense_note = "Code marked [dense] has its blank lines and body comments removed and one space per indent level; read the exact text by its path and line before editing it.\n";
pub const already_shown = "(already shown, unchanged)";

/// Says whether the model already holds this definition's body unchanged: path relative to the
/// root with '/', first and last line of the body, and the definition's content hash. When it
/// answers true the reply names the definition in one line instead of sending the body again.
pub const SeenFn = *const fn (path: []const u8, start: u32, end: u32, hash: facts.Hash) bool;

pub const ServeArgs = struct { mode: ExploreMode, rest: []const []const u8 };

/// Takes `--explore-mode (full | dense)` out of the server arguments and returns the others in
/// order. Null when the value is missing or unknown or the flag is given twice.
pub fn splitExploreMode(arena: Allocator, args: anytype) !?ServeArgs {
    var rest: std.ArrayList([]const u8) = .empty;
    var mode: ?ExploreMode = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (!std.mem.eql(u8, arg, explore_mode_flag)) {
            try rest.append(arena, arg);
            continue;
        }
        if (mode != null or i + 1 >= args.len) return null;
        i += 1;
        mode = std.meta.stringToEnum(ExploreMode, args[i]) orelse return null;
    }
    return .{ .mode = mode orelse .full, .rest = rest.items };
}

pub const explore_description = "Answers a code question: named symbols' definitions, callers, callees and impact, then best-matching code.";
pub const evidence_description = "Full code of up to 6 functions by qualified name.";

pub const Phase = enum(u8) { idle, building, ready, failed };

/// A written byte range of a repository file, path relative to the root with '/'.
pub const Edited = struct { path: []const u8, start: u32, end: u32 };

pub const Unreached = struct { qname: []const u8, path: []const u8, line: u32 };

pub const waited_note = "waited for the fact store build";

pub const Session = struct {
    gpa: Allocator,
    io: std.Io,
    runtime: *Runtime,
    root: []const u8,
    arena_state: std.heap.ArenaAllocator,
    tables_state: std.heap.ArenaAllocator,
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
    seam_override: ?io_seam.Seam = null,
    phase: std.atomic.Value(Phase) = .init(.idle),
    cancel: std.atomic.Value(bool) = .init(false),
    worker: ?std.Thread = null,
    failure: ?anyerror = null,
    waited: bool = false,
    tables_stale: bool = false,
    names_builds: u32 = 0,
    explore_mode: ExploreMode = .full,
    explore_calls: u32 = 0,
    seen: ?SeenFn = null,

    pub fn create(gpa: Allocator, io: std.Io, runtime: *Runtime, root: []const u8) !*Session {
        const self = try gpa.create(Session);
        self.* = .{ .gpa = gpa, .io = io, .runtime = runtime, .root = root, .arena_state = .init(std.heap.page_allocator), .tables_state = .init(std.heap.page_allocator), .real = .init(gpa, io) };
        return self;
    }

    pub fn destroy(self: *Session) void {
        self.cancel.store(true, .release);
        _ = self.settle();
        if (self.repo) |r| r.deinit();
        if (self.store_path) |p| self.gpa.free(p);
        self.real.deinit();
        self.tables_state.deinit();
        self.arena_state.deinit();
        self.gpa.destroy(self);
    }

    pub fn build(self: *Session) !void {
        self.phase.store(.building, .release);
        run(self);
        if (self.failure) |err| return err;
    }

    pub fn start(self: *Session) void {
        self.phase.store(.building, .release);
        self.worker = std.Thread.spawn(.{}, run, .{self}) catch return run(self);
    }

    pub fn settle(self: *Session) bool {
        const worker = self.worker orelse return false;
        const building = self.phase.load(.acquire) == .building;
        worker.join();
        self.worker = null;
        return building;
    }

    pub fn takeNote(self: *Session) ?[]const u8 {
        defer self.waited = false;
        if (self.phase.load(.acquire) == .failed) return @errorName(self.failure orelse error.Unexpected);
        return if (self.waited) waited_note else null;
    }

    fn run(self: *Session) void {
        self.load() catch |err| {
            self.failure = err;
            self.phase.store(.failed, .release);
            return;
        };
        self.phase.store(.ready, .release);
    }

    fn load(self: *Session) !void {
        self.store_path = if (self.store_override) |p| try self.gpa.dupe(u8, p) else fact_store.defaultStorePath(self.gpa, self.root) catch null;
        const repo = try fact_store.Repo.open(self.gpa, self.seam_override orelse self.real.seam(), self.runtime, .{ .root_abs = self.root, .store_path = self.store_path, .cancel = &self.cancel });
        self.repo = repo;
        _ = try repo.refresh();
        try self.indexNames();
    }

    fn indexNames(self: *Session) !void {
        _ = self.tables_state.reset(.retain_capacity);
        self.names = .empty;
        self.symbols = .empty;
        self.part_df = .empty;
        const arena = self.tables_state.allocator();
        const repo = self.repo.?;
        self.names_builds += 1;
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
            if (state.status != .indexed or map.isTestFile(&state, null)) continue;
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
            if (map.isTestFile(state, null)) continue;
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
        if (self.settle()) self.waited = true;
        if (self.phase.load(.acquire) == .failed) self.retry();
        return self.phase.load(.acquire) == .ready;
    }

    fn retry(self: *Session) void {
        if (self.repo) |r| r.deinit();
        self.repo = null;
        if (self.store_path) |p| self.gpa.free(p);
        self.store_path = null;
        _ = self.arena_state.reset(.free_all);
        _ = self.tables_state.reset(.free_all);
        self.names = .empty;
        self.symbols = .empty;
        self.part_df = .empty;
        self.terms = null;
        self.term_docs = .empty;
        self.term_files = .empty;
        self.failure = null;
        self.phase.store(.building, .release);
        run(self);
    }

    fn sync(self: *Session) void {
        if (self.repo.?.refresh()) |report| {
            if (report.extracted != 0 or report.removed != 0 or report.full_link) self.tables_stale = true;
        } else |_| self.tables_stale = true;
        if (!self.tables_stale) return;
        self.indexNames() catch return;
        self.tables_stale = false;
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

    fn isTestPick(self: *const Session, path: []const u8) bool {
        const store = &self.repo.?.store;
        const id = store.fileId(path) orelse return isTest(path);
        return map.isTestFile(&store.files.items[id], null);
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
            try w.print("{s}{s} {s}{s}:{d}", .{ if (i == 0) " Closest: " else "; ", r.f.qname, display_path.prefix, r.f.path, self.defLine(r.f) });
        }
        try w.writeByte('\n');
    }

    pub fn explore(self: *Session, gpa: Allocator, args: ?Value) !ToolResult {
        const question = try tool_result.requireString(args, "question");
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        if (!self.ready()) return plain(gpa, "explore is unavailable: the repository could not be read", true);
        self.sync();
        const names = try namesOf(arena, args);
        return plain(gpa, try self.answer(arena, question, names), false);
    }

    pub fn answer(self: *Session, arena: Allocator, question: []const u8, names: []const []const u8) ![]const u8 {
        const budget = self.replyBudget();
        self.explore_calls +|= 1;
        return self.dense(arena, question, names, budget);
    }

    /// The reply budget of the next explore call: one budget in full mode; in dense mode a larger
    /// first reply of the session and smaller later ones.
    pub fn replyBudget(self: *const Session) usize {
        return switch (self.explore_mode) {
            .full => reply_budget,
            .dense => if (self.explore_calls == 0) dense_first_budget else dense_later_budget,
        };
    }

    fn closureBudget(self: *const Session) usize {
        return if (self.explore_mode == .dense) dense_closure_budget else closure_budget;
    }

    fn pointerBudget(self: *const Session) usize {
        return if (self.explore_mode == .dense) dense_pointer_budget else pointer_budget;
    }

    fn evidenceBudget(self: *const Session) usize {
        return if (self.explore_mode == .dense) dense_evidence_budget else evidence_budget;
    }

    fn seenBefore(self: *const Session, path: []const u8, first: u32, last: u32, hash: facts.Hash) bool {
        const check = self.seen orelse return false;
        return check(path, first, last, hash);
    }

    /// Changed callables that no test reaches through the static reference graph.
    /// Null while the fact store is still building: a write never waits for it.
    pub fn untested(self: *Session, arena: Allocator, edited: []const Edited) !?[]const Unreached {
        if (self.phase.load(.acquire) != .ready) return null;
        _ = self.settle();
        self.sync();
        const store = &self.repo.?.store;
        var out: std.ArrayList(Unreached) = .empty;
        for (edited) |e| {
            const id = store.fileId(e.path) orelse continue;
            const state = store.file(id);
            if (state.status != .indexed or test_reach.isTestFile(state)) continue;
            for (try test_reach.changedDefs(arena, state, e.start, e.end)) |index| {
                if (index >= state.slots.len) continue;
                const def = state.facts.defs[index];
                const def_id: facts_store.DefId = .{ .file = id, .slot = state.slots[index] };
                if (try test_reach.reach(arena, store, def_id) != .untested) continue;
                try out.append(arena, .{ .qname = def.qname, .path = state.path, .line = def.line });
            }
        }
        return out.items;
    }

    pub fn evidenceTool(self: *Session, gpa: Allocator, args: ?Value) !ToolResult {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        if (!self.ready()) return plain(gpa, "evidence is unavailable: the repository could not be read", true);
        self.sync();
        const names = try namesOf(arena, args);
        if (names.len == 0) return plain(gpa, "no names were given", false);
        const wanted = names[0..@min(names.len, max_evidence_names)];
        var out: Writer.Allocating = .init(arena);
        try out.writer.writeAll(try self.evidenceText(arena, wanted, self.evidenceBudget()));
        if (names.len > wanted.len) {
            try out.writer.print("Not read, the limit is {d} names per call: ", .{max_evidence_names});
            for (names[wanted.len..], 0..) |n, i| try out.writer.print("{s}{s}", .{ if (i == 0) "" else ", ", n });
            try out.writer.writeByte('\n');
        }
        var texts: std.StringHashMapUnmanaged(FileText) = .empty;
        var shown: std.ArrayList(Shown) = .empty;
        for (wanted) |n| {
            for (try self.named(arena, n)) |f| {
                const d = self.repo.?.store.file(f.file).facts.defs[f.def];
                const ft = (try self.fileText(arena, &texts, f.path)) orelse continue;
                const first = @max(d.line, 1);
                try shown.append(arena, .{ .file = f.file, .first = first, .last = @max(ft.lineOf(d.span.end), first) });
            }
        }
        const none: std.AutoHashMapUnmanaged(u64, void) = .empty;
        try self.closure(arena, &out.writer, &texts, shown.items, &none);
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
        var graphed: std.ArrayList(Fn) = .empty;
        for (names) |n| {
            var any = false;
            for (try self.named(arena, n)) |f| {
                if (self.isTestPick(f.path)) continue;
                any = true;
                if (self.container(f)) {
                    try containers.writer.print("{s}{s}:{d} {s}\n", .{ display_path.prefix, f.path, self.defLine(f), f.qname });
                    continue;
                }
                try addPicked(arena, &picks, &at, f, 1, true);
                try graphed.append(arena, f);
            }
            if (!any) try self.unknown(arena, &notes.writer, n);
        }
        const graph_asked = asksGraph(question);
        for (try questionIdentifiers(arena, question)) |ident| {
            for (try self.named(arena, ident)) |f| {
                if (self.isTestPick(f.path) or self.container(f)) continue;
                try addPicked(arena, &picks, &at, f, 1, true);
                if (graph_asked) try graphed.append(arena, f);
            }
        }
        try self.freshTerms();
        const hits = try self.terms.?.rank(arena, joined.written(), max_ranked);
        const top: f64 = @max(try self.terms.?.ceiling(arena, joined.written()), 1e-9);
        for (hits) |hit| {
            const f = self.term_docs.items[hit.doc];
            const state = store.file(f.file);
            if (state.status != .indexed or f.def >= state.facts.defs.len) continue;
            try addPicked(arena, &picks, &at, .{ .file = f.file, .def = f.def, .path = state.path, .qname = state.facts.defs[f.def].qname }, hit.score / top, false);
        }

        var out: Writer.Allocating = .init(arena);
        try out.writer.writeAll(notes.written());
        var drawn: std.AutoHashMapUnmanaged(u64, void) = .empty;
        for (graphed.items) |f| {
            if (drawn.count() >= max_graph_subjects) break;
            const entry = try drawn.getOrPut(arena, keyOf(f));
            if (entry.found_existing) continue;
            try self.graph(arena, &out.writer, f);
        }
        if (containers.written().len != 0) {
            try out.writer.writeAll("Named classes, shown through their matching members:\n");
            try out.writer.writeAll(containers.written());
        }
        if (picks.items.len == 0) {
            try out.writer.print("{s}\n", .{no_function_matched});
            return out.written();
        }
        var texts: std.StringHashMapUnmanaged(FileText) = .empty;
        var shown: std.ArrayList(Shown) = .empty;
        var addressed: std.AutoHashMapUnmanaged(u64, void) = .empty;
        var cut: Writer.Allocating = .init(arena);
        var pointers: Writer.Allocating = .init(arena);
        const compact = self.explore_mode == .dense;
        const pointer_room = self.pointerBudget();
        const limit = if (compact) budget -| (pointer_room + self.closureBudget() + closure_reserve + dense_note.len) else budget -| pointer_room;
        var used: usize = out.written().len;
        var densified = false;
        for (picks.items) |pk| {
            const state = store.file(pk.f.file);
            if (state.status != .indexed or pk.f.def >= state.facts.defs.len) continue;
            const d = state.facts.defs[pk.f.def];
            const ft = (try self.fileText(arena, &texts, pk.f.path)) orelse continue;
            const first = @max(d.line, 1);
            const last = @max(ft.lineOf(d.span.end), first);
            if (inside(shown.items, pk.f.file, first, last)) continue;
            const base = indentOf(ft.line(first));
            // A definition the model named is sent verbatim: it is the code it is likely to edit.
            const block: ?[]const u8 = if (compact and !pk.whole and used < limit) try denseBlock(arena, ft, state.facts.defs, pk.f.path, first, last) else null;
            const size = if (block) |b| b.len + pk.f.path.len + pk.f.qname.len + header_chars + dense_marker.len else blockChars(ft, first, last, base) + pk.f.path.len + pk.f.qname.len + header_chars;
            const chance: f64 = if (pk.whole) 1 else usefulAt(pk.score);
            const worth = pk.whole or worthSending(size, chance, fetch_chars);
            if (worth and self.seenBefore(pk.f.path, first, last, d.hash)) {
                const line = try std.fmt.allocPrint(arena, "{s}{s}:{d} {s} {s}\n", .{ display_path.prefix, pk.f.path, first, pk.f.qname, already_shown });
                try out.writer.writeAll(line);
                used += line.len;
                try shown.append(arena, .{ .file = pk.f.file, .first = first, .last = last });
                continue;
            }
            if (worth and used + size <= limit) {
                if (block) |b| {
                    try out.writer.print("{s}{s}:{d} {s}{s}\n{s}", .{ display_path.prefix, pk.f.path, first, pk.f.qname, dense_marker, b });
                    densified = true;
                } else {
                    try out.writer.print("{s}{s}:{d} {s}\n", .{ display_path.prefix, pk.f.path, first, pk.f.qname });
                    var k = first;
                    while (k <= last) : (k += 1) try writeLine(&out.writer, ft, k, base);
                }
                used += size;
                try shown.append(arena, .{ .file = pk.f.file, .first = first, .last = last });
                continue;
            }
            const line = try std.fmt.allocPrint(arena, "{s}{s}:{d} {s} ({d} lines)\n", .{ display_path.prefix, pk.f.path, first, pk.f.qname, last - first + 1 });
            if (pk.whole) {
                try cut.writer.writeAll(line);
                try addressed.put(arena, keyOf(pk.f), {});
            } else if (usefulAt(pk.score) >= pointer_chance and pointers.written().len + line.len + (if (compact) cut.written().len else 0) <= pointer_room) {
                try pointers.writer.writeAll(line);
                try addressed.put(arena, keyOf(pk.f), {});
            }
        }
        var mentions: std.AutoArrayHashMapUnmanaged(u64, Mention) = .empty;
        for (shown.items) |s| {
            const ft = (try self.fileText(arena, &texts, store.file(s.file).path)) orelse continue;
            var words: std.StringArrayHashMapUnmanaged(u32) = .empty;
            var k = s.first;
            while (k <= s.last) : (k += 1) try countIdentifiers(arena, &words, ft.line(k));
            var wi = words.iterator();
            while (wi.next()) |word| {
                var only: ?Fn = null;
                var many = false;
                for (try self.definitions(arena, word.key_ptr.*)) |f| {
                    if (f.file != s.file) continue;
                    if (only != null) many = true;
                    only = f;
                }
                const f = only orelse continue;
                if (many) continue;
                const entry = try mentions.getOrPut(arena, keyOf(f));
                if (!entry.found_existing) entry.value_ptr.* = .{ .f = f, .count = 0 };
                entry.value_ptr.count += word.value_ptr.*;
            }
        }
        var bound: Writer.Allocating = .init(arena);
        for (mentions.values()) |m| {
            const f = m.f;
            if (self.container(f)) continue;
            const state = store.file(f.file);
            const d = state.facts.defs[f.def];
            const ft = (try self.fileText(arena, &texts, f.path)) orelse continue;
            const first = @max(d.line, 1);
            const last = @max(ft.lineOf(d.span.end), first);
            if (inside(shown.items, f.file, first, last)) continue;
            const base = indentOf(ft.line(first));
            const block: ?[]const u8 = if (compact and used < limit) try denseBlock(arena, ft, state.facts.defs, f.path, first, last) else null;
            const size = if (block) |b| b.len + f.path.len + f.qname.len + header_chars + dense_marker.len else blockChars(ft, first, last, base) + f.path.len + f.qname.len + header_chars;
            if (!worthSending(size, mentionChance(m.count), call_chars) or used + size > limit) continue;
            if (self.seenBefore(f.path, first, last, d.hash)) {
                const line = try std.fmt.allocPrint(arena, "{s}{s}:{d} {s} {s}\n", .{ display_path.prefix, f.path, first, f.qname, already_shown });
                try bound.writer.writeAll(line);
                used += line.len;
                try shown.append(arena, .{ .file = f.file, .first = first, .last = last });
                continue;
            }
            if (block) |b| {
                try bound.writer.print("{s}{s}:{d} {s}{s}\n{s}", .{ display_path.prefix, f.path, first, f.qname, dense_marker, b });
                densified = true;
            } else {
                try bound.writer.print("{s}{s}:{d} {s}\n", .{ display_path.prefix, f.path, first, f.qname });
                var k = first;
                while (k <= last) : (k += 1) try writeLine(&bound.writer, ft, k, base);
            }
            used += size;
            try shown.append(arena, .{ .file = f.file, .first = first, .last = last });
        }
        if (bound.written().len != 0) {
            try out.writer.writeAll("Definitions of names used above:\n");
            try out.writer.writeAll(bound.written());
        }
        if (cut.written().len != 0) {
            try out.writer.writeAll("Named definitions not shown, the reply limit was reached:\n");
            try out.writer.writeAll(cut.written());
        }
        if (pointers.written().len != 0) {
            try out.writer.writeAll("Matching functions not shown:\n");
            try out.writer.writeAll(pointers.written());
        }
        try self.closure(arena, &out.writer, &texts, shown.items, &addressed);
        if (densified) return std.mem.concat(arena, u8, &.{ dense_note, out.written() });
        return out.written();
    }

    fn closure(self: *Session, arena: Allocator, w: *Writer, texts: *std.StringHashMapUnmanaged(FileText), shown: []const Shown, addressed: *const std.AutoHashMapUnmanaged(u64, void)) !void {
        if (shown.len == 0) return;
        const store = &self.repo.?.store;
        var names: std.StringArrayHashMapUnmanaged(void) = .empty;
        for (shown) |s| {
            const ft = (try self.fileText(arena, texts, store.file(s.file).path)) orelse continue;
            var k = s.first;
            while (k <= s.last) : (k += 1) try closureNames(arena, &names, ft.line(k));
        }
        var rows: Writer.Allocating = .init(arena);
        var listed: std.AutoHashMapUnmanaged(u64, void) = .empty;
        var more: usize = 0;
        for (names.keys()) |name| {
            var kept: std.ArrayList(Fn) = .empty;
            for (try self.definitions(arena, name)) |f| {
                if (self.isTestPick(f.path)) continue;
                try kept.append(arena, f);
            }
            if (kept.items.len == 0 or kept.items.len > closure_max_defs) continue;
            for (kept.items) |f| {
                const key = keyOf(f);
                if (addressed.contains(key) or listed.contains(key)) continue;
                const d = store.file(f.file).facts.defs[f.def];
                const ft = (try self.fileText(arena, texts, f.path)) orelse continue;
                const first = @max(d.line, 1);
                if (inside(shown, f.file, first, @max(ft.lineOf(d.span.end), first))) continue;
                try listed.put(arena, key, {});
                const row = try std.fmt.allocPrint(arena, "  {s}  {s}{s}:{d}  {s}\n", .{ f.qname, display_path.prefix, f.path, first, signatureOf(d) });
                if (rows.written().len + row.len > self.closureBudget()) {
                    more += 1;
                    continue;
                }
                try rows.writer.writeAll(row);
            }
        }
        try w.print("-- closure\nWhole above: {d} functions. By address above: {d}.\n", .{ shown.len, addressed.count() });
        if (rows.written().len != 0) {
            try w.writeAll("Named in the code above and defined in this repository, not shown (signature only):\n");
            try w.writeAll(rows.written());
        }
        if (more != 0) try w.print("  +{d} more named definitions, not listed\n", .{more});
        try w.print("{s}\n", .{closure_footer});
    }

    pub fn graph(self: *Session, arena: Allocator, w: *Writer, f: Fn) !void {
        const repo = self.repo.?;
        try w.print("Graph of {s} {s}:{d}\n", .{ f.qname, f.path, self.defLine(f) });
        const callers = edgesOf(try repo.query(arena, .{ .relation = .callers, .subject = f.qname, .path = f.path }));
        const callees = edgesOf(try repo.query(arena, .{ .relation = .callees, .subject = f.qname, .path = f.path }));
        const impact = edgesOf(try repo.query(arena, .{ .relation = .callers, .subject = f.qname, .path = f.path, .depth = impact_depth }));

        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var listed: usize = 0;
        var more: usize = 0;
        try w.writeAll("callers:");
        if (callers) |e| for (e.sites) |site| {
            const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ site.path, site.owner.qname });
            if ((try seen.getOrPut(arena, key)).found_existing) continue;
            if (listed == max_graph_items) {
                more += 1;
                continue;
            }
            try w.print(" {s}:{d} {s};", .{ site.path, site.line, site.owner.qname });
            listed += 1;
        };
        try endList(w, listed, more);

        seen.clearRetainingCapacity();
        listed = 0;
        more = 0;
        try w.writeAll("callees:");
        if (callees) |e| for (e.sites) |site| {
            const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ site.target.path, site.target.qname });
            if ((try seen.getOrPut(arena, key)).found_existing) continue;
            if (listed == max_graph_items) {
                more += 1;
                continue;
            }
            try w.print(" {s} {s}:{d};", .{ site.target.qname, site.target.path, site.target.line });
            listed += 1;
        };
        try endList(w, listed, more);

        seen.clearRetainingCapacity();
        var files: std.StringArrayHashMapUnmanaged(void) = .empty;
        if (impact) |e| for (e.sites) |site| {
            const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ site.path, site.owner.qname });
            _ = try seen.getOrPut(arena, key);
            _ = try files.getOrPut(arena, site.path);
        };
        try w.print("impact: {d} functions in {d} files reach it within {d} calls", .{ seen.count(), files.count(), impact_depth });
        for (files.keys()[0..@min(files.count(), max_impact_files)], 0..) |path, i| try w.print("{s}{s}", .{ if (i == 0) ": " else ", ", path });
        if (files.count() > max_impact_files) try w.print(" (+{d} more)", .{files.count() - max_impact_files});
        try w.writeByte('\n');
        const unbound = if (callers) |e| e.unknown.len else 0;
        if (unbound != 0) try w.print("unresolved: {d} call sites of the same name could not be bound\n", .{unbound});
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

const Mention = struct {
    f: Fn,
    count: u32,
};

const Shown = struct {
    file: u32,
    first: u32,
    last: u32,
};

fn edgesOf(result: facts_query.FactsAnswer) ?facts_query.Edges {
    return switch (result) {
        .complete => |c| c.value,
        .partial => |p| p.value,
        .refused => null,
    };
}

fn endList(w: *Writer, listed: usize, more: usize) !void {
    if (listed == 0) try w.writeAll(" none");
    if (more != 0) try w.print(" (+{d} more)", .{more});
    try w.writeByte('\n');
}

pub fn asksGraph(question: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, question, " \t\r\n,.?!:;()'\"");
    while (words.next()) |word| {
        for (graph_words) |g| {
            if (word.len >= g.len and std.ascii.eqlIgnoreCase(word[0..g.len], g) and isGraphSuffix(word[g.len..])) return true;
        }
    }
    return false;
}

const graph_suffixes = [_][]const u8{ "", "s", "es", "ed", "ing", "er", "ers", "ee", "ees", "ent", "ents", "ency", "encies", "ence", "ences" };

fn isGraphSuffix(rest: []const u8) bool {
    for (graph_suffixes) |suffix| {
        if (std.ascii.eqlIgnoreCase(rest, suffix)) return true;
    }
    return false;
}

fn inside(shown: []const Shown, file: u32, first: u32, last: u32) bool {
    for (shown) |s| {
        if (s.file == file and s.first <= first and last <= s.last) return true;
    }
    return false;
}

pub fn worthSending(size: usize, chance: f64, saved: f64) bool {
    return @as(f64, @floatFromInt(size)) * (1 - chance) < saved * chance;
}

pub fn mentionChance(count: u32) f64 {
    var i: usize = 0;
    while (i < mention_count.len and count >= mention_count[i]) i += 1;
    return mention_chance[i];
}

const closure_skip = [_][]const u8{ "if", "for", "while", "switch", "catch", "return", "function", "super", "typeof", "await", "require", "import" };

fn closureSkipped(word: []const u8) bool {
    for (closure_skip) |s| {
        if (std.mem.eql(u8, word, s)) return true;
    }
    return false;
}

fn isConstantName(word: []const u8) bool {
    if (word.len < 3 or !std.ascii.isUpper(word[0])) return false;
    for (word) |c| {
        if (!std.ascii.isUpper(c) and !std.ascii.isDigit(c) and c != '_') return false;
    }
    return true;
}

fn opensCall(text: []const u8, end: usize) bool {
    var j = end;
    while (j < text.len and (text[j] == ' ' or text[j] == '\t')) j += 1;
    if (j < text.len and text[j] == '<') {
        j += 1;
        while (j < text.len and text[j] != '>') : (j += 1) {
            if (text[j] == '(' or text[j] == ')') return false;
        }
        if (j == text.len) return false;
        j += 1;
        while (j < text.len and (text[j] == ' ' or text[j] == '\t')) j += 1;
    }
    return j < text.len and text[j] == '(';
}

fn afterNew(text: []const u8, start: usize) bool {
    var j = start;
    while (j > 0 and (text[j - 1] == ' ' or text[j - 1] == '\t')) j -= 1;
    if (j == start or j < 3 or !std.mem.eql(u8, text[j - 3 .. j], "new")) return false;
    return j == 3 or !(identifierStart(text[j - 4]) or std.ascii.isDigit(text[j - 4]));
}

pub fn closureNames(arena: Allocator, names: *std.StringArrayHashMapUnmanaged(void), text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        if (!identifierStart(text[i])) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < text.len and (identifierStart(text[i]) or std.ascii.isDigit(text[i]))) i += 1;
        if (start != 0 and std.ascii.isDigit(text[start - 1])) continue;
        const word = text[start..i];
        if (word.len < 3 or closureSkipped(word)) continue;
        if (opensCall(text, i) or afterNew(text, start) or isConstantName(word)) try names.put(arena, word, {});
    }
}

fn signatureOf(d: facts.Def) []const u8 {
    const sig = if (d.signature.len != 0) d.signature else d.qname;
    if (sig.len <= closure_signature) return sig;
    var cut: usize = closure_signature;
    while (cut > 0 and (sig[cut] & 0xC0) == 0x80) cut -= 1;
    return sig[0..cut];
}

fn identifierStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$';
}

pub fn countIdentifiers(arena: Allocator, counts: *std.StringArrayHashMapUnmanaged(u32), text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        if (!identifierStart(text[i])) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < text.len and (identifierStart(text[i]) or std.ascii.isDigit(text[i]))) i += 1;
        if (start != 0 and std.ascii.isDigit(text[start - 1])) continue;
        const word = text[start..i];
        if (word.len < min_mention) continue;
        const entry = try counts.getOrPut(arena, word);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
    }
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

const CommentStyle = enum { slash, hash };

const hash_comment_extensions = [_][]const u8{ ".py", ".pyi", ".rb", ".sh", ".bash", ".ps1", ".r", ".pl", ".yaml", ".yml", ".toml" };

fn commentStyle(path: []const u8) CommentStyle {
    const ext = std.fs.path.extension(path);
    for (hash_comment_extensions) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return .hash;
    }
    return .slash;
}

const LineKind = enum { code, blank, comment, kept_comment };

/// A comment a tool or type checker reads: JSDoc tags, `@ts-` directives, lint switches,
/// Python type comments.
fn annotates(text: []const u8, style: CommentStyle) bool {
    if (std.mem.indexOfScalar(u8, text, '@') != null) return true;
    if (std.mem.indexOf(u8, text, "eslint") != null or std.mem.indexOf(u8, text, "noqa") != null or std.mem.indexOf(u8, text, "pragma") != null) return true;
    return style == .hash and std.mem.indexOf(u8, text, "type:") != null;
}

fn lineKind(text: []const u8, style: CommentStyle) LineKind {
    if (text.len == 0) return .blank;
    switch (style) {
        .slash => {
            if (std.mem.startsWith(u8, text, "///") or std.mem.startsWith(u8, text, "//!") or std.mem.startsWith(u8, text, "/**")) return .kept_comment;
            if (std.mem.startsWith(u8, text, "//") or std.mem.startsWith(u8, text, "/*")) return if (annotates(text, style)) .kept_comment else .comment;
        },
        .hash => {
            if (std.mem.startsWith(u8, text, "#!")) return .kept_comment;
            if (text[0] == '#') return if (annotates(text, style)) .kept_comment else .comment;
        },
    }
    return .code;
}

fn startsDefinition(defs: []const facts.Def, line: u32) bool {
    for (defs) |d| {
        if (d.kind != .module and d.line == line) return true;
    }
    return false;
}

/// Lines first..last of a definition, numbered, with blank lines and body comments dropped and
/// one space per indent level. A comment directly above a definition inside the range, doc
/// comments, JSDoc and annotation comments are kept with their text unchanged.
fn denseBlock(arena: Allocator, ft: FileText, defs: []const facts.Def, path: []const u8, first: u32, last: u32) ![]const u8 {
    const style = commentStyle(path);
    const count: usize = last - first + 1;
    const kinds = try arena.alloc(LineKind, count);
    var open_block: ?LineKind = null;
    for (kinds, 0..) |*kind, i| {
        const k: u32 = first + @as(u32, @intCast(i));
        const text = std.mem.trim(u8, ft.line(k), " \t\r");
        if (open_block) |held| {
            kind.* = held;
            if (std.mem.indexOf(u8, text, "*/") != null) open_block = null;
            continue;
        }
        kind.* = if (k == first) .code else lineKind(text, style);
        if (kind.* != .code and kind.* != .blank and style == .slash and std.mem.startsWith(u8, text, "/*") and std.mem.indexOf(u8, text[2..], "*/") == null) open_block = kind.*;
    }
    var above = false;
    var back = count;
    while (back > 0) {
        back -= 1;
        switch (kinds[back]) {
            .code => above = startsDefinition(defs, first + @as(u32, @intCast(back))),
            .blank => above = false,
            .comment => if (above) {
                kinds[back] = .kept_comment;
            },
            .kept_comment => {},
        }
    }
    const base = indentOf(ft.line(first));
    var unit: usize = 0;
    for (kinds, 0..) |kind, i| {
        if (kind != .code) continue;
        const raw = ft.line(first + @as(u32, @intCast(i)));
        const rel = indentOf(raw) -| base;
        if (rel != 0 and (unit == 0 or rel < unit)) unit = rel;
    }
    if (unit == 0) unit = 1;
    var out: Writer.Allocating = .init(arena);
    for (kinds, 0..) |kind, i| {
        if (kind == .blank or kind == .comment) continue;
        const k: u32 = first + @as(u32, @intCast(i));
        const raw = std.mem.trimEnd(u8, ft.line(k), " \t\r");
        const text = std.mem.trimStart(u8, raw, " \t");
        if (text.len == 0) continue;
        const levels = (indentOf(raw) -| base) / unit;
        try out.writer.print("{d} ", .{k});
        try out.writer.splatByteAll(' ', levels);
        if (kind == .kept_comment and text[0] == '*') try out.writer.writeByte(' ');
        try out.writer.print("{s}\n", .{text[0..cutUtf8(text, max_code_chars)]});
    }
    return out.written();
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
    const profile = registry.forPath(path) orelse return false;
    return map.isTestPath(profile.map, path);
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

test "map tools: the chance that a definition is useful rises with its score ratio along the measured table" {
    try testing.expectEqual(@as(f64, 0.009), usefulAt(0));
    try testing.expectEqual(@as(f64, 0.012), usefulAt(0.02));
    try testing.expectEqual(@as(f64, 0.199), usefulAt(0.17));
    try testing.expectEqual(@as(f64, 0.589), usefulAt(0.3));
    try testing.expectEqual(@as(f64, 0.589), usefulAt(1));
}

test "map tools: a definition is sent whole only while its size costs less than the model call it may save" {
    try testing.expect(worthSending(100, 0.25, call_chars));
    try testing.expect(!worthSending(40_000, 0.25, call_chars));
    try testing.expect(worthSending(40_000, 1, call_chars));
    try testing.expect(!worthSending(100, 0, call_chars));
    try testing.expect(worthSending(900, 0.25, fetch_chars));
    try testing.expect(!worthSending(1_000, 0.25, fetch_chars));
    try testing.expect(fetch_chars < call_chars / 2);
    try testing.expect(call_chars > 7_000 and call_chars < 8_500);
}

test "map tools: identifiers of three or more characters are counted and a name used more often has a higher chance of being asked for" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var counts: std.StringArrayHashMapUnmanaged(u32) = .empty;
    try countIdentifiers(arena_state.allocator(), &counts, "if (active >= maxDevices) return maxDevices - 12ab + $x1 + ok;");
    try testing.expectEqual(@as(u32, 2), counts.get("maxDevices").?);
    try testing.expectEqual(@as(u32, 1), counts.get("active").?);
    try testing.expectEqual(@as(u32, 1), counts.get("$x1").?);
    try testing.expect(counts.get("ok") == null);
    try testing.expect(counts.get("ab") == null);
    try testing.expectEqual(@as(f64, 0.013), mentionChance(1));
    try testing.expectEqual(@as(f64, 0.029), mentionChance(2));
    try testing.expectEqual(@as(f64, 0.029), mentionChance(3));
    try testing.expectEqual(@as(f64, 0.044), mentionChance(4));
}

test "map tools: test paths are recognized by the folder and file name table of the language profile" {
    try testing.expect(isTest("packages/core/test/injector.spec.ts"));
    try testing.expect(isTest("src/__tests__/a.ts"));
    try testing.expect(isTest("server/tests/approvals-policy.test.ts"));
    try testing.expect(isTest("server/src/approvals/policy.test.ts"));
    try testing.expect(isTest("packages/desktop-client/e2e/page-models/budget-page.ts"));
    try testing.expect(!isTest("server/src/approvals/policy.ts"));
    try testing.expect(!isTest("packages/core/contest/latest.ts"));
    try testing.expect(!isTest("packages/core/injector/injector.ts"));
}
