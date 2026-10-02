const std = @import("std");
const facts = @import("../engine/facts.zig");
const fact_store = @import("../platform/fact_store.zig");
const io_seam = @import("../platform/io_seam.zig");
const map = @import("../engine/map.zig");
const map_explore = @import("../engine/map_explore.zig");
const map_lines = @import("../engine/map_lines.zig");
const map_pick = @import("../engine/map_pick.zig");
const map_usage = @import("../engine/map_usage.zig");
const rank = @import("../engine/map_region_rank.zig");
const question_lexicon = @import("../engine/question_lexicon.zig");
const facts_query = @import("../engine/facts_query.zig");
const evidence = @import("../engine/evidence.zig");
const tool_result = @import("tool_result.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;
const ToolResult = tool_result.ToolResult;

pub const map_budget_tokens: u32 = 8_000;
pub const reply_budget: usize = 16_000;
pub const slice_budget: usize = 9_500;
pub const evidence_budget: usize = 16_000;
pub const max_regions: usize = 3;
pub const max_depth: u32 = 4;
pub const max_fanout: usize = 16;
pub const max_nodes: usize = 400;
pub const max_focus: usize = 8;
pub const max_named_focus: usize = 3;
pub const max_ranked_focus: usize = 6;
pub const first_round_path: usize = 3;
pub const max_candidates: usize = 10;
pub const max_user_focus: usize = 2;
pub const max_kept_per_focus: usize = 12;
pub const max_block_lines: usize = 20;
pub const max_line_chars: usize = 160;
pub const max_entries_per_focus: usize = 3;
pub const max_entry_focus: usize = 3;
pub const entries_budget: usize = 1_500;
pub const writers_budget: usize = 3_000;
pub const max_writer_functions: usize = 4;
pub const max_read_fields: usize = 12;
pub const max_writes_per_field: usize = 3;
pub const max_seeds: usize = 10;
pub const max_question_seeds: usize = 4;
pub const max_user_regions: usize = 2;
pub const user_region_depth: usize = 20;
pub const max_evidence_names: usize = 6;
pub const max_instructions: usize = 1_900;
pub const max_folders: usize = 40;

pub const explore_description = "Return the decision path for a question about this repository in one reply: the deciding functions as file:line with their signature, condition, return, call and assignment lines, the functions they call down to four levels, where the fields they read are written, and the lines that call them. question: a short English search phrase with the concepts and identifiers involved. names: optional function or class names (Class.method or function) you already know are central.";
pub const evidence_description = "Return the full code of up to 6 functions by qualified name (Class.method or function), as plain text.";

const instructions_head = "emetgate reads the code of this repository for you. For a question about the code, call explore once with a short English " ++
    "search phrase naming the concepts and identifiers involved, plus central function or class names if you know them. The reply " ++
    "holds the full decision path: answer from it, and call again only if a function you need is missing.\n" ++
    "Answer in at most 10 short lines: the conclusion first, then each deciding function as file:line with what it decides. " ++
    "No headings and no code blocks.\n" ++
    "Top folders: ";

const closing_line = "This reply holds the decision path; answer from it. Call emetgate_explore again only if a function you need is missing, or emetgate_evidence for full bodies.";

pub const Session = struct {
    gpa: Allocator,
    io: std.Io,
    runtime: *Runtime,
    root: []const u8,
    arena_state: std.heap.ArenaAllocator,
    real: io_seam.Real,
    store_path: ?[]u8 = null,
    repo: ?*fact_store.Repo = null,
    lex: ?*question_lexicon.Lexicon = null,
    built: ?map.Map = null,
    index: ?*rank.Index = null,
    lines: ?map_lines.Index = null,
    names: std.StringHashMapUnmanaged([]const u8) = .empty,
    instructions: []const u8 = instructions_head,
    with_index: bool = true,

    pub fn create(gpa: Allocator, io: std.Io, runtime: *Runtime, root: []const u8) !*Session {
        const self = try gpa.create(Session);
        self.* = .{ .gpa = gpa, .io = io, .runtime = runtime, .root = root, .arena_state = .init(std.heap.page_allocator), .real = .init(gpa, io) };
        return self;
    }

    pub fn destroy(self: *Session) void {
        if (self.repo) |r| r.deinit();
        if (self.lex) |l| l.deinit();
        if (self.store_path) |p| self.gpa.free(p);
        self.real.deinit();
        self.arena_state.deinit();
        self.gpa.destroy(self);
    }

    pub fn build(self: *Session) !void {
        const arena = self.arena_state.allocator();
        self.store_path = fact_store.defaultStorePath(self.gpa, self.root) catch null;
        const repo = try fact_store.Repo.open(self.gpa, self.real.seam(), self.runtime, .{ .root_abs = self.root, .store_path = self.store_path });
        self.repo = repo;
        _ = try repo.refresh();
        self.lex = try question_lexicon.Lexicon.parse(self.gpa, question_lexicon.default_text);
        const built = try map.buildMap(arena, &repo.store, .{ .budget_tokens = map_budget_tokens, .cert = repo.snapshot() });
        self.built = built;
        if (self.with_index) self.index = try rank.Index.build(arena, &repo.store, &self.built.?, self.lex.?);
        self.lines = try map_lines.Index.build(arena, built.text);
        for (repo.store.files.items) |state| {
            if (state.status != .indexed) continue;
            for (state.facts.defs) |d| {
                if (d.kind == .module) continue;
                const path = try arena.dupe(u8, state.path);
                const full = try self.names.getOrPut(arena, try arena.dupe(u8, d.qname));
                if (!full.found_existing) full.value_ptr.* = path;
                const simple = try self.names.getOrPut(arena, try arena.dupe(u8, simpleName(d.qname)));
                if (!simple.found_existing) simple.value_ptr.* = path;
            }
        }
        var text: Writer.Allocating = .init(arena);
        try text.writer.writeAll(instructions_head);
        for (self.lines.?.headings[0..@min(self.lines.?.headings.len, max_folders)], 0..) |h, i| {
            if (i != 0) try text.writer.writeAll(", ");
            try text.writer.writeAll(h);
        }
        const all = text.written();
        self.instructions = all[0..cutUtf8(all, max_instructions)];
    }

    fn ready(self: *Session) bool {
        return self.repo != null and self.built != null and self.lines != null and (self.index != null or !self.with_index);
    }

    fn fileOf(self: *const Session, name: []const u8) ?[]const u8 {
        return self.names.get(name);
    }

    pub fn explore(self: *Session, gpa: Allocator, args: ?Value) !ToolResult {
        const question = try tool_result.requireString(args, "question");
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        if (!self.ready()) return plain(gpa, "explore is unavailable: the project map could not be built", true);
        _ = self.repo.?.refresh() catch {};
        const names = try namesOf(arena, args);
        return plain(gpa, try self.dense(arena, question, names, reply_budget), false);
    }

    pub fn answer(self: *Session, arena: Allocator, question: []const u8, names: []const []const u8) ![]const u8 {
        return self.dense(arena, question, names, reply_budget);
    }

    pub fn slice(self: *Session, arena: Allocator, question: []const u8) ![]const u8 {
        return self.dense(arena, question, &.{}, slice_budget);
    }

    pub fn evidenceTool(self: *Session, gpa: Allocator, args: ?Value) !ToolResult {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        if (!self.ready()) return plain(gpa, "evidence is unavailable: the project map could not be built", true);
        _ = self.repo.?.refresh() catch {};
        const names = try namesOf(arena, args);
        const wanted = names[0..@min(names.len, max_evidence_names)];
        const text = try self.evidenceText(arena, wanted, evidence_budget);
        if (text.len != 0) return plain(gpa, text, false);
        var out: Writer.Allocating = .init(arena);
        try out.writer.writeAll("none of these names is a known function: ");
        for (wanted, 0..) |n, i| try out.writer.print("{s}{s}", .{ if (i == 0) "" else ", ", n });
        return plain(gpa, out.written(), false);
    }

    pub fn dense(self: *Session, arena: Allocator, question: []const u8, names: []const []const u8, budget: usize) ![]const u8 {
        const repo = self.repo.?;
        const store = &repo.store;
        const built = &self.built.?;
        var joined: Writer.Allocating = .init(arena);
        try joined.writer.writeAll(question);
        for (names) |n| try joined.writer.print(" {s}", .{n});
        const query = joined.written();
        const terms_words = try map_lines.words(arena, query);
        const terms = try rank.Terms.ofQuestion(arena, self.lex.?, query);
        const first = try self.pickRegions(arena, query, &terms_words, &terms);

        var rankings: std.ArrayList(rank.Ranking) = .empty;
        for (first) |r| {
            const ranked = rank.rankInRegion(arena, store, built, r, &terms, .{}, self.index) catch continue;
            try rankings.append(arena, ranked);
        }
        var seeds: std.ArrayList(map_usage.Seed) = .empty;
        for (names) |n| {
            if (try self.resolve(n)) |f| try appendSeed(arena, &seeds, .{ .file = f.file, .def = f.def });
        }
        var questioned: usize = 0;
        for (try questionIdentifiers(arena, question)) |ident| {
            if (questioned >= max_question_seeds) break;
            if (try self.resolve(ident)) |f| {
                const before = seeds.items.len;
                try appendSeed(arena, &seeds, .{ .file = f.file, .def = f.def });
                if (seeds.items.len != before) questioned += 1;
            }
        }
        for (rankings.items) |ranked| {
            if (ranked.hits.len == 0 or ranked.hits[0].score <= 0 or ranked.hits[0].matched == 0) continue;
            try appendSeed(arena, &seeds, .{ .file = ranked.hits[0].file, .def = ranked.hits[0].def });
        }
        if (seeds.items.len > max_seeds) seeds.shrinkRetainingCapacity(max_seeds);
        const users = try map_usage.users(arena, store, seeds.items, .{ .skip = &isTest });
        const ranked_users = try self.rankUsers(arena, users, &terms);

        var focus: std.ArrayList(Fn) = .empty;
        for (names) |n| {
            if (focus.items.len >= max_named_focus) break;
            if (try self.resolve(n)) |f| _ = try appendFn(arena, &focus, f);
        }
        var ranked_taken: usize = 0;
        var depth: usize = 0;
        while (ranked_taken < max_ranked_focus and depth < 8) : (depth += 1) {
            var any = false;
            for (rankings.items) |ranked| {
                if (depth >= ranked.hits.len) continue;
                any = true;
                if (ranked_taken >= max_ranked_focus) break;
                const hit = ranked.hits[depth];
                if (hit.score <= 0 or hit.matched == 0 or isTest(hit.path)) continue;
                if (try appendFn(arena, &focus, .{ .file = hit.file, .def = hit.def, .path = hit.path, .qname = hit.qname })) ranked_taken += 1;
            }
            if (!any) break;
        }
        var users_taken: usize = 0;
        for (ranked_users) |u| {
            if (users_taken >= max_user_focus or focus.items.len >= max_focus) break;
            if (u.score <= 0) continue;
            if (try appendFn(arena, &focus, .{ .file = u.user.file, .def = u.user.def, .path = u.user.path, .qname = u.user.qname })) users_taken += 1;
        }
        if (focus.items.len > max_focus) focus.shrinkRetainingCapacity(max_focus);

        var path_fns: std.ArrayList(Fn) = .empty;
        const paths = try arena.alloc([]const Fn, focus.items.len);
        for (focus.items, paths) |f, *p| p.* = try self.deepPath(arena, f, &terms);
        for (focus.items, paths) |f, p| {
            _ = try appendFn(arena, &path_fns, f);
            for (p[0..@min(p.len, first_round_path)]) |node| _ = try appendFn(arena, &path_fns, node);
        }
        for (paths) |p| {
            if (p.len <= first_round_path) continue;
            for (p[first_round_path..]) |node| _ = try appendFn(arena, &path_fns, node);
        }
        var call_names: std.ArrayList([]const u8) = .empty;
        for (path_fns.items) |f| {
            const simple = simpleName(f.qname);
            if (simple.len >= 4 and !contains(call_names.items, simple)) try call_names.append(arena, simple);
        }

        var texts: std.StringHashMapUnmanaged(FileText) = .empty;
        var blocks: std.ArrayList(Block) = .empty;
        for (path_fns.items) |f| {
            const b = try self.renderBlock(arena, &texts, f, &terms, call_names.items, &.{});
            if (b.text.len != 0) try blocks.append(arena, b);
        }
        const reserve = writers_budget + entries_budget + closing_line.len + 64;
        const path_limit = budget -| reserve;
        var taken: usize = 0;
        var used: usize = 0;
        while (taken < blocks.items.len and used + blocks.items[taken].text.len <= path_limit) : (taken += 1) used += blocks.items[taken].text.len;
        if (taken == 0 and blocks.items.len != 0) {
            taken = 1;
            used = blocks.items[0].text.len;
        }

        var included: std.ArrayList(Fn) = .empty;
        for (blocks.items[0..taken]) |b| try included.append(arena, b.f);
        var decision_lines: std.ArrayList([]const u8) = .empty;
        for (blocks.items[0..taken]) |b| try decision_lines.appendSlice(arena, b.decisions);
        const fields = try readFields(arena, decision_lines.items);
        const writers = try self.writerBlocks(arena, &texts, fields, included.items, &terms, call_names.items);
        var writers_text: Writer.Allocating = .init(arena);
        const writers_room = writers_budget + (path_limit -| used);
        for (writers) |b| {
            if (writers_text.written().len + b.text.len > writers_room) break;
            try writers_text.writer.writeAll(b.text);
        }
        var entries_text: Writer.Allocating = .init(arena);
        for (focus.items[0..@min(focus.items.len, max_entry_focus)]) |f| try self.entryLines(arena, &entries_text.writer, f, &terms_words);
        const entries_room = budget -| (used + writers_text.written().len + closing_line.len + 64);
        const entries_cut = lineCut(entries_text.written(), @min(entries_room, entries_budget + (writers_room -| writers_text.written().len)));

        var leftover = budget -| (used + writers_text.written().len + entries_cut + closing_line.len + 64);
        var extra_end = taken;
        while (extra_end < blocks.items.len and blocks.items[extra_end].text.len <= leftover) : (extra_end += 1) leftover -= blocks.items[extra_end].text.len;

        var out: Writer.Allocating = .init(arena);
        if (blocks.items.len == 0) try out.writer.writeAll("no function of the repository matched the phrase\n");
        for (blocks.items[0..extra_end]) |b| try out.writer.writeAll(b.text);
        if (writers_text.written().len != 0) {
            try out.writer.writeAll("Where the fields read above are written:\n");
            try out.writer.writeAll(writers_text.written());
        }
        if (entries_cut != 0) {
            try out.writer.writeAll("Callers of the top functions:\n");
            try out.writer.writeAll(entries_text.written()[0..entries_cut]);
            if (entries_text.written()[entries_cut - 1] != '\n') try out.writer.writeByte('\n');
        }
        var candidates: Writer.Allocating = .init(arena);
        var listed: usize = 0;
        var level: usize = 0;
        while (listed < max_candidates and level < 16) : (level += 1) {
            var any = false;
            for (rankings.items) |ranked| {
                if (level >= ranked.hits.len) continue;
                any = true;
                if (listed >= max_candidates) break;
                const hit = ranked.hits[level];
                if (hit.score <= 0 or hit.matched == 0 or isTest(hit.path)) continue;
                const shown = for (blocks.items[0..extra_end]) |b| {
                    if (b.f.file == hit.file and b.f.def == hit.def) break true;
                } else false;
                if (shown) continue;
                try candidates.writer.print("{s}:{d} {s}\n", .{ hit.path, hit.line, hit.qname });
                listed += 1;
            }
            if (!any) break;
        }
        const room = budget -| (out.written().len + closing_line.len + 64);
        const header = "Other candidates (call emetgate_explore with their names for their code):\n";
        if (candidates.written().len != 0 and room > header.len + 80) {
            try out.writer.writeAll(header);
            try out.writer.writeAll(candidates.written()[0..lineCut(candidates.written(), room - header.len)]);
        }
        try out.writer.writeAll(closing_line);
        try out.writer.writeByte('\n');
        return out.written();
    }

    fn pickRegions(self: *Session, arena: Allocator, query: []const u8, terms_words: *const map_lines.WordSet, terms: *const rank.Terms) ![]const map.RegionId {
        var first = try self.lines.?.pick(arena, terms_words, max_regions);
        if (first.len == 0) {
            var pick_words = try map_lines.words(arena, query);
            var stems: std.ArrayList([]const u8) = .empty;
            for (terms.concepts) |c| try stems.appendSlice(arena, c.alternatives);
            try self.lines.?.expandStems(&pick_words, stems.items);
            first = try self.lines.?.pick(arena, &pick_words, max_regions);
        }
        if (first.len == 0) first = (try map_pick.pick(arena, &self.repo.?.store, &self.built.?, terms, .{}, self.index, .{ .max_regions = max_regions })).regions;
        return first;
    }

    fn resolve(self: *Session, name: []const u8) !?Fn {
        const path = self.fileOf(name) orelse return null;
        const store = &self.repo.?.store;
        const id = store.fileId(path) orelse return null;
        const state = store.file(id);
        if (state.status != .indexed) return null;
        var simple_match: ?u32 = null;
        for (state.facts.defs, 0..) |d, di| {
            if (d.kind == .module) continue;
            if (std.mem.eql(u8, d.qname, name)) return .{ .file = id, .def = @intCast(di), .path = state.path, .qname = d.qname };
            if (simple_match == null and std.mem.eql(u8, simpleName(d.qname), name)) simple_match = @intCast(di);
        }
        const di = simple_match orelse return null;
        return .{ .file = id, .def = di, .path = state.path, .qname = state.facts.defs[di].qname };
    }

    fn callees(self: *Session, arena: Allocator, f: Fn) ![]const Fn {
        const store = &self.repo.?.store;
        const state = store.file(f.file);
        if (state.status != .indexed or state.links.len != state.facts.refs.len or f.def >= state.facts.defs.len) return &.{};
        const defs = state.facts.defs;
        var out: std.ArrayList(Fn) = .empty;
        for (state.facts.refs, state.links) |r, l| {
            if (out.items.len >= max_fanout) break;
            if (!r.kind.invokes() or !within(defs, f.def, r.from)) continue;
            const target = switch (l) {
                .def => |d| d.id,
                .unresolved => continue,
            };
            const t_state = store.file(target.file);
            if (t_state.status != .indexed or isTest(t_state.path)) continue;
            const di = t_state.defIndex(target.slot) orelse continue;
            if (target.file == f.file and di == f.def) continue;
            _ = try appendFn(arena, &out, .{ .file = target.file, .def = di, .path = t_state.path, .qname = t_state.facts.defs[di].qname });
        }
        return out.items;
    }

    fn deepPath(self: *Session, arena: Allocator, root: Fn, terms: *const rank.Terms) ![]const Fn {
        var nodes: std.ArrayList(Node) = .empty;
        var at: std.AutoHashMapUnmanaged(u64, usize) = .empty;
        try nodes.append(arena, .{ .f = root, .parent = null, .depth = 0, .matched = false });
        try at.put(arena, keyOf(root), 0);
        var i: usize = 0;
        while (i < nodes.items.len and nodes.items.len < max_nodes) : (i += 1) {
            const n = nodes.items[i];
            if (n.depth >= max_depth) continue;
            for (try self.callees(arena, n.f)) |c| {
                if (nodes.items.len >= max_nodes) break;
                const entry = try at.getOrPut(arena, keyOf(c));
                if (entry.found_existing) continue;
                entry.value_ptr.* = nodes.items.len;
                const matched = (try rank.maskOf(terms, c.qname)) != 0;
                try nodes.append(arena, .{ .f = c, .parent = i, .depth = n.depth + 1, .matched = matched });
            }
        }
        const keep = try arena.alloc(bool, nodes.items.len);
        @memset(keep, false);
        for (nodes.items, 0..) |n, j| {
            if (!n.matched) continue;
            var cur: ?usize = j;
            while (cur) |c| {
                if (c == 0 or keep[c]) break;
                keep[c] = true;
                cur = nodes.items[c].parent;
            }
        }
        const children = try arena.alloc(std.ArrayList(usize), nodes.items.len);
        for (children) |*c| c.* = .empty;
        for (nodes.items, 0..) |n, j| {
            if (j == 0 or !keep[j]) continue;
            try children[n.parent.?].append(arena, j);
        }
        var out: std.ArrayList(Fn) = .empty;
        var stack: std.ArrayList(usize) = .empty;
        var c0 = children[0].items.len;
        while (c0 > 0) : (c0 -= 1) try stack.append(arena, children[0].items[c0 - 1]);
        while (stack.pop()) |j| {
            if (out.items.len >= max_kept_per_focus) break;
            try out.append(arena, nodes.items[j].f);
            var k = children[j].items.len;
            while (k > 0) : (k -= 1) try stack.append(arena, children[j].items[k - 1]);
        }
        return out.items;
    }

    fn renderBlock(self: *Session, arena: Allocator, texts: *std.StringHashMapUnmanaged(FileText), f: Fn, terms: *const rank.Terms, call_names: []const []const u8, force: []const u32) !Block {
        const store = &self.repo.?.store;
        const state = store.file(f.file);
        if (state.status != .indexed or f.def >= state.facts.defs.len) return .{ .f = f, .text = "", .decisions = &.{} };
        const d = state.facts.defs[f.def];
        const ft = (try self.fileText(arena, texts, f.path)) orelse return .{ .f = f, .text = "", .decisions = &.{} };
        const first_line = @max(d.line, 1);
        const last_line = @max(ft.lineOf(d.span.end), first_line);
        var w: Writer.Allocating = .init(arena);
        var decisions: std.ArrayList([]const u8) = .empty;
        try w.writer.print("{s}:{d} {s}\n", .{ f.path, first_line, f.qname });
        try writeCode(&w.writer, ft, first_line);
        var last_written = first_line;
        var kept: usize = 0;
        var n: u32 = first_line + 1;
        while (n <= last_line) : (n += 1) {
            const t = std.mem.trim(u8, ft.line(n), " \t\r");
            if (t.len == 0 or std.mem.startsWith(u8, t, "//") or std.mem.startsWith(u8, t, "*") or std.mem.startsWith(u8, t, "/*")) continue;
            const forced = std.mem.indexOfScalar(u32, force, n) != null;
            const decision = isDecisionLine(t);
            const wanted = forced or decision or isFieldAssignment(t) or callsAny(t, call_names, simpleName(f.qname)) or (try rank.maskOf(terms, t)) != 0;
            if (!wanted) continue;
            if (decision) try decisions.append(arena, t);
            if (kept >= max_block_lines) {
                if (!forced) continue;
            }
            if (n > last_written + 1) try w.writer.writeAll("     \u{2026}\n");
            try writeCode(&w.writer, ft, n);
            last_written = n;
            kept += 1;
        }
        if (last_written < last_line) try w.writer.writeAll("     \u{2026}\n");
        return .{ .f = f, .text = w.written(), .decisions = decisions.items };
    }

    fn writerBlocks(self: *Session, arena: Allocator, texts: *std.StringHashMapUnmanaged(FileText), fields: []const []const u8, included: []const Fn, terms: *const rank.Terms, call_names: []const []const u8) ![]const Block {
        if (fields.len == 0) return &.{};
        var index: std.StringHashMapUnmanaged(usize) = .empty;
        for (fields, 0..) |f, i| try index.put(arena, f, i);
        const store = &self.repo.?.store;
        var found: std.ArrayList(WriteSite) = .empty;
        for (store.files.items, 0..) |*state, id| {
            if (state.status != .indexed or isTest(state.path)) continue;
            const defs = state.facts.defs;
            var known = false;
            for (included) |f| {
                if (f.file == id) known = true;
            }
            for (state.facts.refs) |r| {
                if (r.kind != .write) continue;
                const i = index.get(r.name) orelse continue;
                if (r.from == 0 or r.from >= defs.len) continue;
                try found.append(arena, .{ .file = @intCast(id), .def = r.from, .line = r.line, .field = i, .known = known, .path = state.path });
            }
            for (defs, 0..) |d, di| {
                if (d.kind != .setter) continue;
                const i = index.get(d.name) orelse continue;
                try found.append(arena, .{ .file = @intCast(id), .def = @intCast(di), .line = d.line, .field = i, .known = known, .path = state.path });
            }
        }
        std.mem.sort(WriteSite, found.items, {}, WriteSite.less);
        const per_field = try arena.alloc(usize, fields.len);
        @memset(per_field, 0);
        var owners: std.ArrayList(Fn) = .empty;
        var lines_of: std.ArrayList(std.ArrayList(u32)) = .empty;
        for (found.items) |s| {
            if (per_field[s.field] >= max_writes_per_field) continue;
            const state = store.file(s.file);
            var owner = s.def;
            while (owner != 0 and owner < state.facts.defs.len and !state.facts.defs[owner].kind.callable()) owner = state.facts.defs[owner].parent;
            if (owner == 0 or owner >= state.facts.defs.len) continue;
            const f: Fn = .{ .file = s.file, .def = owner, .path = s.path, .qname = state.facts.defs[owner].qname };
            var slot: ?usize = null;
            for (owners.items, 0..) |o, k| {
                if (o.file == f.file and o.def == f.def) slot = k;
            }
            if (slot == null) {
                if (owners.items.len >= max_writer_functions) continue;
                slot = owners.items.len;
                try owners.append(arena, f);
                try lines_of.append(arena, .empty);
            }
            try lines_of.items[slot.?].append(arena, s.line);
            per_field[s.field] += 1;
        }
        var out: std.ArrayList(Block) = .empty;
        for (owners.items, lines_of.items) |o, ls| {
            const b = try self.renderBlock(arena, texts, o, terms, call_names, ls.items);
            if (b.text.len != 0) try out.append(arena, b);
        }
        return out.items;
    }

    fn entryLines(self: *Session, arena: Allocator, w: *Writer, f: Fn, terms: *const map_lines.WordSet) !void {
        const result = self.repo.?.query(arena, .{ .relation = .callers, .subject = f.qname, .path = f.path }) catch return;
        const found = switch (result) {
            .complete => |c| c.value.sites,
            .partial => |p| p.value.sites,
            .refused => return,
        };
        var rows: std.ArrayList(Row) = .empty;
        for (found) |s| {
            if (isTest(s.path)) continue;
            const ws = try map_lines.words(arena, try std.mem.concat(arena, u8, &.{ s.path, " ", s.owner.qname }));
            var overlap: usize = 0;
            for (ws.items.items) |word| {
                if (terms.has(word)) overlap += 1;
            }
            try rows.append(arena, .{ .site = s, .home = std.mem.eql(u8, s.path, f.path), .overlap = overlap, .order = rows.items.len });
        }
        std.mem.sort(Row, rows.items, {}, Row.less);
        for (rows.items[0..@min(rows.items.len, max_entries_per_focus)]) |row| {
            const s = row.site;
            try w.print("{s}:{d}  in {s}: {s}\n", .{ s.path, s.line, s.owner.qname, try self.lineText(arena, s.path, s.line) });
        }
    }

    const RankedUser = struct {
        user: map_usage.User,
        score: f64,
    };

    fn rankUsers(self: *Session, arena: Allocator, users: []const map_usage.User, terms: *const rank.Terms) ![]const RankedUser {
        if (users.len == 0) return &.{};
        const store = &self.repo.?.store;
        var files: std.ArrayList(rank.RegionFile) = .empty;
        var file_seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
        var by_def: std.AutoHashMapUnmanaged(u64, usize) = .empty;
        for (users, 0..) |u, i| {
            try by_def.put(arena, (@as(u64, u.file) << 32) | u.def, i);
            const entry = try file_seen.getOrPut(arena, u.file);
            if (entry.found_existing) continue;
            try files.append(arena, .{ .path = u.path, .id = u.file, .state = store.file(u.file) });
        }
        std.mem.sort(rank.RegionFile, files.items, {}, struct {
            fn less(_: void, a: rank.RegionFile, b: rank.RegionFile) bool {
                return std.mem.order(u8, a.path, b.path) == .lt;
            }
        }.less);
        const ranking = try map_pick.rankAcross(arena, files.items, terms, .{}, self.index);
        var out: std.ArrayList(RankedUser) = .empty;
        for (ranking.hits) |hit| {
            const i = by_def.get((@as(u64, hit.file) << 32) | hit.def) orelse continue;
            try out.append(arena, .{ .user = users[i], .score = hit.score });
        }
        return out.items;
    }

    fn fileText(self: *Session, arena: Allocator, texts: *std.StringHashMapUnmanaged(FileText), path: []const u8) !?FileText {
        if (texts.get(path)) |t| return t;
        const abs = try std.fs.path.join(arena, &.{ self.root, path });
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, abs, arena, .limited(16 * 1024 * 1024)) catch return null;
        var starts: std.ArrayList(u32) = .empty;
        try starts.append(arena, 0);
        for (bytes, 0..) |b, i| {
            if (b == '\n') try starts.append(arena, @intCast(i + 1));
        }
        const ft: FileText = .{ .bytes = bytes, .starts = starts.items };
        try texts.put(arena, path, ft);
        return ft;
    }

    fn lineText(self: *Session, arena: Allocator, path: []const u8, line: u32) ![]const u8 {
        const abs = try std.fs.path.join(arena, &.{ self.root, path });
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, abs, arena, .limited(16 * 1024 * 1024)) catch return "";
        var it = std.mem.splitScalar(u8, bytes, '\n');
        var n: u32 = 1;
        while (it.next()) |text| : (n += 1) {
            if (n != line) continue;
            const trimmed = std.mem.trim(u8, text, " \t\r");
            return trimmed[0..cutUtf8(trimmed, max_line_chars)];
        }
        return "";
    }

    fn evidenceText(self: *Session, arena: Allocator, names: []const []const u8, budget: usize) ![]const u8 {
        var targets: std.ArrayList(evidence.SymbolRef) = .empty;
        for (names) |n| {
            const path = self.fileOf(n) orelse continue;
            for (targets.items) |t| {
                if (std.mem.eql(u8, t.path, path) and std.mem.eql(u8, t.qname, n)) break;
            } else try targets.append(arena, .{ .path = path, .qname = n });
        }
        if (targets.items.len == 0) return "";
        const result = try self.repo.?.evidence(arena, .{ .targets = targets.items, .intent = .explain, .terms = &.{}, .include = .{ .callers = false, .callees = false, .tests = false } }, budget);
        return switch (result) {
            .complete => |c| c.value.text,
            .partial => |p| p.value.text,
            .refused => blk: {
                var status: Writer.Allocating = .init(arena);
                try result.writeStatus(&status.writer, 0, "targets");
                break :blk status.written();
            },
        };
    }
};

const Fn = struct {
    file: u32,
    def: u32,
    path: []const u8,
    qname: []const u8,
};

const Node = struct {
    f: Fn,
    parent: ?usize,
    depth: u32,
    matched: bool,
};

const Block = struct {
    f: Fn,
    text: []const u8,
    decisions: []const []const u8,
};

const WriteSite = struct {
    file: u32,
    def: u32,
    line: u32,
    field: usize,
    known: bool,
    path: []const u8,

    fn less(_: void, a: WriteSite, b: WriteSite) bool {
        if (a.field != b.field) return a.field < b.field;
        if (a.known != b.known) return a.known;
        const order = std.mem.order(u8, a.path, b.path);
        if (order != .eq) return order == .lt;
        return a.line < b.line;
    }
};

const Row = struct {
    site: facts_query.Site,
    home: bool,
    overlap: usize,
    order: usize,

    fn less(_: void, a: Row, b: Row) bool {
        if (a.home != b.home) return !a.home;
        if (a.overlap != b.overlap) return a.overlap > b.overlap;
        return a.order < b.order;
    }
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

fn keyOf(f: Fn) u64 {
    return (@as(u64, f.file) << 32) | f.def;
}

fn appendFn(arena: Allocator, list: *std.ArrayList(Fn), f: Fn) !bool {
    for (list.items) |x| {
        if (x.file == f.file and x.def == f.def) return false;
    }
    try list.append(arena, f);
    return true;
}

fn appendSeed(arena: Allocator, seeds: *std.ArrayList(map_usage.Seed), seed: map_usage.Seed) !void {
    for (seeds.items) |s| {
        if (s.file == seed.file and s.def == seed.def) return;
    }
    try seeds.append(arena, seed);
}

fn within(defs: []const facts.Def, outer: u32, inner: u32) bool {
    if (outer >= defs.len or inner >= defs.len) return false;
    const a = defs[outer].span;
    const b = defs[inner].span;
    return b.start >= a.start and b.end <= a.end;
}

fn writeCode(w: *Writer, ft: FileText, n: u32) !void {
    const text = std.mem.trim(u8, ft.line(n), " \t\r");
    try w.print("{d:>5}  {s}\n", .{ n, text[0..cutUtf8(text, max_line_chars)] });
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

fn startsWithWord(t: []const u8, word: []const u8) bool {
    if (!std.mem.startsWith(u8, t, word)) return false;
    return t.len == word.len or !(std.ascii.isAlphanumeric(t[word.len]) or t[word.len] == '_');
}

pub fn isCondition(t: []const u8) bool {
    const body = if (std.mem.startsWith(u8, t, "} ")) t[2..] else t;
    for ([_][]const u8{ "if", "else", "switch", "case", "while", "for", "catch" }) |word| {
        if (startsWithWord(body, word)) return true;
    }
    return std.mem.indexOf(u8, t, " ? ") != null or std.mem.indexOf(u8, t, "&&") != null or std.mem.indexOf(u8, t, "||") != null;
}

pub fn isReturn(t: []const u8) bool {
    return startsWithWord(t, "return") or startsWithWord(t, "throw") or std.mem.indexOf(u8, t, " return ") != null;
}

pub fn isDecisionLine(t: []const u8) bool {
    if (isCondition(t) or isReturn(t)) return true;
    for ([_][]const u8{ ".sort(", "===", "!==", " < ", " > ", " <= ", " >= " }) |marker| {
        if (std.mem.indexOf(u8, t, marker) != null) return true;
    }
    return std.mem.indexOf(u8, t, "=> ") != null and std.mem.indexOf(u8, t, " - ") != null;
}

fn assignmentAt(t: []const u8) ?usize {
    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        if (t[i] != '=') continue;
        const next: u8 = if (i + 1 < t.len) t[i + 1] else 0;
        const prev: u8 = if (i > 0) t[i - 1] else 0;
        if (next == '=' or next == '>') {
            i += 1;
            continue;
        }
        if (prev == '=' or prev == '!' or prev == '<' or prev == '>') continue;
        return i;
    }
    return null;
}

pub fn isFieldAssignment(t: []const u8) bool {
    const at = assignmentAt(t) orelse return false;
    return std.mem.indexOfScalar(u8, t[0..at], '.') != null;
}

fn callsAny(t: []const u8, names: []const []const u8, self_name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, self_name)) continue;
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, t, at, n)) |pos| {
            at = pos + n.len;
            const before_ok = pos == 0 or !(std.ascii.isAlphanumeric(t[pos - 1]) or t[pos - 1] == '_');
            const after_ok = at < t.len and t[at] == '(';
            if (before_ok and after_ok) return true;
        }
    }
    return false;
}

const common_fields = [_][]const u8{ "length", "name", "type", "data", "keys", "values", "value", "prototype", "constructor", "push", "then", "size", "items", "toString", "message" };

fn isCommonField(field: []const u8) bool {
    for (common_fields) |c| {
        if (std.mem.eql(u8, c, field)) return true;
    }
    return false;
}

pub fn readFields(arena: Allocator, decision_lines: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (decision_lines) |t| {
        var i: usize = 1;
        while (i < t.len) : (i += 1) {
            if (t[i] != '.') continue;
            const prev = t[i - 1];
            if (!(std.ascii.isAlphanumeric(prev) or prev == '_' or prev == ')' or prev == ']' or prev == '$')) continue;
            var end = i + 1;
            if (end >= t.len or !(std.ascii.isAlphabetic(t[end]) or t[end] == '_' or t[end] == '$')) continue;
            while (end < t.len and (std.ascii.isAlphanumeric(t[end]) or t[end] == '_' or t[end] == '$')) end += 1;
            const field = t[i + 1 .. end];
            if (end < t.len and t[end] == '(') continue;
            if (field.len < 4 or isCommonField(field) or contains(out.items, field)) continue;
            if (out.items.len >= max_read_fields) return out.items;
            try out.append(arena, field);
        }
    }
    return out.items;
}

fn lineCut(text: []const u8, limit: usize) usize {
    if (text.len <= limit) return text.len;
    const nl = std.mem.lastIndexOfScalar(u8, text[0..limit], '\n') orelse return 0;
    return nl + 1;
}

fn plain(gpa: Allocator, text: []const u8, is_error: bool) !ToolResult {
    return .{ .text = try tool_result.dupTrim(gpa, text), .is_error = is_error };
}

fn simpleName(qname: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, qname, '.') orelse return qname;
    return qname[dot + 1 ..];
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

test "map tools: decision lines include sort comparators and field writes need a member on the left" {
    try testing.expect(isDecisionLine("const compareFn = (a, b) => b.distance - a.distance;"));
    try testing.expect(isDecisionLine("if (scope === Scope.REQUEST) {"));
    try testing.expect(!isDecisionLine("const x = load();"));
    try testing.expect(isFieldAssignment("moduleRef.distance = depth;"));
    try testing.expect(isFieldAssignment("this._distance = value;"));
    try testing.expect(!isFieldAssignment("const depth = 1;"));
    try testing.expect(!isFieldAssignment("if (a.b === c) {"));
}

test "map tools: read fields skip method calls, short and common names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const fields = try readFields(arena_state.allocator(), &.{ "modules.sort((a, b) => b.distance - a.distance);", "if (wrapper.hierarchyLevel > x.length && this.isTreeStatic()) {" });
    try testing.expectEqual(@as(usize, 2), fields.len);
    try testing.expectEqualStrings("distance", fields[0]);
    try testing.expectEqualStrings("hierarchyLevel", fields[1]);
}

test "map tools: test paths are recognized by folder and by the spec infix" {
    try testing.expect(isTest("packages/core/test/injector.spec.ts"));
    try testing.expect(isTest("src/__tests__/a.ts"));
    try testing.expect(!isTest("packages/core/injector/injector.ts"));
}
