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
pub const max_ranked_level: usize = 64;
pub const max_user_focus: usize = 2;
pub const max_kept_per_focus: usize = 12;
pub const max_block_lines: usize = 20;
pub const max_line_chars: usize = 160;
pub const max_entries_per_focus: usize = 3;
pub const max_entry_focus: usize = 3;
pub const entries_budget: usize = 1_500;
pub const writers_budget: usize = 3_000;
pub const max_writer_functions: usize = 8;
pub const max_read_fields: usize = 12;
pub const max_writes_per_field: usize = 3;
pub const max_loose_files: usize = 48;
pub const max_reader_extra: usize = 8;
pub const max_enclosing: usize = 3;
pub const max_filler_renders: usize = 60;
pub const min_filler_room: usize = 160;
pub const candidates_reserve: usize = 700;
pub const max_symbol_rank: usize = 64;
pub const extra_part_penalty: f64 = 0.25;
pub const max_statement_lines: u32 = 40;
pub const max_code_chars: usize = 1_000;
pub const setter_weight: f64 = 0.4;
pub const constructor_weight: f64 = 0.3;
pub const param_copy_weight: f64 = 0.3;
pub const shown_reader_weight: f64 = 1.5;
pub const question_field_boost: f64 = 3;
pub const min_site_share: f64 = 0.5;
pub const max_seeds: usize = 10;
pub const max_question_seeds: usize = 4;
pub const max_user_regions: usize = 2;
pub const user_region_depth: usize = 20;
pub const max_evidence_names: usize = 6;

pub const explore_description = "Returns the decision closure of a question: the code connected to the named or matching symbols through calls, field writes and metadata keys, as complete statements with file:line, and the names of connected functions left out.";
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
    lex: ?*question_lexicon.Lexicon = null,
    built: ?map.Map = null,
    index: ?*rank.Index = null,
    lines: ?map_lines.Index = null,
    names: std.StringHashMapUnmanaged([]const u8) = .empty,
    symbols: std.ArrayList(Symbol) = .empty,
    part_df: std.StringHashMapUnmanaged(u32) = .empty,
    store_override: ?[]const u8 = null,
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
        self.store_path = if (self.store_override) |p| try self.gpa.dupe(u8, p) else fact_store.defaultStorePath(self.gpa, self.root) catch null;
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
        var joined: Writer.Allocating = .init(arena);
        try joined.writer.writeAll(question);
        for (names) |n| try joined.writer.print(" {s}", .{n});
        const query = joined.written();
        const terms_words = try map_lines.words(arena, query);
        const terms = try rank.Terms.ofQuestion(arena, self.lex.?, query);
        var notes: Writer.Allocating = .init(arena);
        var focus: std.ArrayList(Fn) = .empty;
        var tokens: std.ArrayList([]const u8) = .empty;
        for (names) |n| try tokens.append(arena, n);
        for (try questionIdentifiers(arena, question)) |ident| {
            if (!contains(tokens.items, ident)) try tokens.append(arena, ident);
        }
        for (tokens.items) |token| {
            if (focus.items.len >= max_named_focus + max_question_seeds) break;
            if (try self.resolve(token)) |f| {
                _ = try appendFn(arena, &focus, f);
                continue;
            }
            const near = try self.symbolRank(arena, token);
            if (near.len == 0) {
                try notes.writer.print("No symbol matches {s}.\n", .{token});
                continue;
            }
            if (try appendFn(arena, &focus, near[0])) try notes.writer.print("{s} is not a symbol; the closest symbol {s} is used.\n", .{ token, near[0].qname });
        }
        const ranked_fns = try self.symbolRank(arena, query);
        var ranked_taken: usize = 0;
        for (ranked_fns) |f| {
            if (ranked_taken >= max_ranked_focus) break;
            if (try appendFn(arena, &focus, f)) ranked_taken += 1;
        }
        var seeds: std.ArrayList(map_usage.Seed) = .empty;
        for (focus.items) |f| try appendSeed(arena, &seeds, .{ .file = f.file, .def = f.def });
        if (seeds.items.len > max_seeds) seeds.shrinkRetainingCapacity(max_seeds);
        const users = try map_usage.users(arena, store, seeds.items, .{ .skip = &isTest });
        const ranked_users = try self.rankUsers(arena, users, &terms);
        var users_taken: usize = 0;
        for (ranked_users) |u| {
            if (users_taken >= max_user_focus or focus.items.len >= max_focus) break;
            if (u.score <= 0) continue;
            if (try appendFn(arena, &focus, .{ .file = u.user.file, .def = u.user.def, .path = u.user.path, .qname = u.user.qname })) users_taken += 1;
        }
        if (focus.items.len > max_focus) focus.shrinkRetainingCapacity(max_focus);

        var meets: std.AutoHashMapUnmanaged(u64, Meet) = .empty;
        var meet_order: std.ArrayList(u64) = .empty;
        for (focus.items) |anchor| {
            var near: std.ArrayList(Fn) = .empty;
            for (try self.callees(arena, anchor)) |c| _ = try appendFn(arena, &near, c);
            for (try self.callerRows(arena, anchor, &terms_words)) |row| {
                const f = self.fnAt(row.site.path, row.site.owner.qname, row.site.owner.line) orelse continue;
                _ = try appendFn(arena, &near, f);
            }
            for (near.items) |f| {
                const entry = try meets.getOrPut(arena, keyOf(f));
                if (!entry.found_existing) {
                    entry.value_ptr.* = .{ .f = f, .anchors = 0 };
                    try meet_order.append(arena, keyOf(f));
                }
                entry.value_ptr.anchors += 1;
            }
        }
        var bridges: std.ArrayList(Fn) = .empty;
        for (meet_order.items) |k| {
            const m = meets.get(k).?;
            if (m.anchors >= 2) _ = try appendFn(arena, &bridges, m.f);
        }

        var path_fns: std.ArrayList(Fn) = .empty;
        const paths = try arena.alloc([]const Fn, focus.items.len);
        for (focus.items, paths) |f, *p| p.* = try self.deepPath(arena, f, &terms);
        for (focus.items) |f| _ = try appendFn(arena, &path_fns, f);
        for (bridges.items) |f| _ = try appendFn(arena, &path_fns, f);
        for (paths) |p| {
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
        const reserve = writers_budget + entries_budget + 64;
        const path_limit = budget -| reserve;
        var taken: usize = 0;
        var used: usize = 0;
        while (taken < blocks.items.len and used + blocks.items[taken].text.len <= path_limit) : (taken += 1) used += blocks.items[taken].text.len;
        if (taken == 0 and blocks.items.len != 0) {
            taken = 1;
            used = blocks.items[0].text.len;
        }
        var shown: std.AutoHashMapUnmanaged(u64, void) = .empty;
        for (blocks.items[0..taken]) |b| try shown.put(arena, keyOf(b.f), {});

        var near_callees: std.ArrayList(Fn) = .empty;
        for (focus.items) |f| {
            for (try self.callees(arena, f)) |c| _ = try appendFn(arena, &near_callees, c);
        }
        var readers: std.ArrayList(Reader) = .empty;
        for (blocks.items[0..taken]) |b| try appendReader(arena, &readers, b.f, shown_reader_weight);
        for (path_fns.items) |f| try appendReader(arena, &readers, f, 1);
        for (ranked_fns[0..@min(ranked_fns.len, max_reader_extra)]) |f| try appendReader(arena, &readers, f, 1);
        for (near_callees.items[0..@min(near_callees.items.len, max_reader_extra)]) |f| try appendReader(arena, &readers, f, 1);
        const fields = try self.fieldsRead(arena, &texts, readers.items, &terms);
        const writers = try self.writerBlocks(arena, &texts, fields, blocks.items[0..taken]);
        var writers_text: Writer.Allocating = .init(arena);
        var written_fields: std.ArrayList([]const u8) = .empty;
        const writers_room = writers_budget + (path_limit -| used);
        for (writers) |w| {
            if (writers_text.written().len + w.block.text.len > writers_room) continue;
            try writers_text.writer.writeAll(w.block.text);
            try shown.put(arena, keyOf(w.block.f), {});
            for (w.fields) |name| {
                if (!contains(written_fields.items, name)) try written_fields.append(arena, name);
            }
        }
        var writers_head: Writer.Allocating = .init(arena);
        if (writers_text.written().len != 0) {
            try writers_head.writer.writeAll("Where the fields read above are written: ");
            for (written_fields.items, 0..) |name, i| try writers_head.writer.print("{s}{s}", .{ if (i == 0) "" else ", ", name });
            try writers_head.writer.writeByte('\n');
        }
        const writers_len = writers_head.written().len + writers_text.written().len;

        var entries_text: Writer.Allocating = .init(arena);
        var caller_sites: std.ArrayList(facts_query.Site) = .empty;
        for (focus.items, 0..) |f, fi| {
            const rows = try self.callerRows(arena, f, &terms_words);
            for (rows[0..@min(rows.len, max_entries_per_focus)]) |row| {
                try caller_sites.append(arena, row.site);
                if (fi >= max_entry_focus) continue;
                const s = row.site;
                try entries_text.writer.print("{s}:{d}  in {s}: {s}\n", .{ s.path, s.line, s.owner.qname, try self.lineText(arena, &texts, s.path, s.line) });
            }
        }
        const entries_head = "Callers of the top functions:\n";
        const entries_room = budget -| (used + writers_len + entries_head.len + 64);
        const entries_cut = lineCut(entries_text.written(), @min(entries_room, entries_budget + (writers_room -| writers_text.written().len)));
        const entries_len = if (entries_cut == 0) 0 else entries_head.len + entries_cut + 1;

        var fill: Filler = .{ .room = budget -| (used + notes.written().len + writers_len + entries_len + candidates_reserve + 64), .text = .init(arena) };
        for (blocks.items[taken..]) |b| try fill.take(arena, &shown, b);
        for (ranked_fns) |f| {
            if (fill.done()) break;
            if (shown.contains(keyOf(f))) continue;
            fill.renders += 1;
            try fill.take(arena, &shown, try self.renderBlock(arena, &texts, f, &terms, call_names.items, &.{}));
        }
        for (caller_sites.items) |site| {
            if (fill.done()) break;
            const f = self.fnAt(site.path, site.owner.qname, site.owner.line) orelse continue;
            if (shown.contains(keyOf(f))) continue;
            fill.renders += 1;
            try fill.take(arena, &shown, try self.renderBlock(arena, &texts, f, &terms, call_names.items, &.{site.line}));
        }
        for (near_callees.items) |f| {
            if (fill.done()) break;
            if (shown.contains(keyOf(f))) continue;
            fill.renders += 1;
            try fill.take(arena, &shown, try self.renderBlock(arena, &texts, f, &terms, call_names.items, &.{}));
        }
        for (blocks.items[0..taken]) |b| {
            if (fill.done()) break;
            for (try self.callees(arena, b.f)) |f| {
                if (fill.done()) break;
                if (shown.contains(keyOf(f))) continue;
                fill.renders += 1;
                try fill.take(arena, &shown, try self.renderBlock(arena, &texts, f, &terms, call_names.items, &.{}));
            }
        }

        var out: Writer.Allocating = .init(arena);
        try out.writer.writeAll(notes.written());
        if (blocks.items.len == 0 and fill.text.written().len == 0) try out.writer.writeAll("no function of the repository matched the phrase\n");
        for (blocks.items[0..taken]) |b| try out.writer.writeAll(b.text);
        try out.writer.writeAll(fill.text.written());
        try out.writer.writeAll(writers_head.written());
        try out.writer.writeAll(writers_text.written());
        if (entries_cut != 0) {
            try out.writer.writeAll(entries_head);
            try out.writer.writeAll(entries_text.written()[0..entries_cut]);
            if (entries_text.written()[entries_cut - 1] != '\n') try out.writer.writeByte('\n');
        }
        var left: Writer.Allocating = .init(arena);
        var left_keys: std.AutoHashMapUnmanaged(u64, void) = .empty;
        const groups = [_][]const Fn{ path_fns.items, bridges.items, near_callees.items, ranked_fns[0..@min(ranked_fns.len, max_candidates)] };
        for (groups) |group| {
            for (group) |f| {
                if (shown.contains(keyOf(f)) or left_keys.contains(keyOf(f))) continue;
                try left_keys.put(arena, keyOf(f), {});
                try left.writer.print("{s}:{d} {s}\n", .{ f.path, self.defLine(f), f.qname });
            }
        }
        for (caller_sites.items) |site| {
            const f = self.fnAt(site.path, site.owner.qname, site.owner.line) orelse continue;
            if (shown.contains(keyOf(f)) or left_keys.contains(keyOf(f))) continue;
            try left_keys.put(arena, keyOf(f), {});
            try left.writer.print("{s}:{d} {s}\n", .{ f.path, self.defLine(f), f.qname });
        }
        const left_head = "Connected functions not shown:\n";
        const room = budget -| (out.written().len + 8);
        if (left.written().len != 0 and room > left_head.len + 80) {
            try out.writer.writeAll(left_head);
            try out.writer.writeAll(left.written()[0..lineCut(left.written(), room - left_head.len)]);
        }
        return out.written();
    }

    fn symbolRank(self: *Session, arena: Allocator, text: []const u8) ![]const Fn {
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
        var out: std.ArrayList(Fn) = .empty;
        for (scored.items[0..@min(scored.items.len, max_symbol_rank)]) |sc| {
            const sym = self.symbols.items[sc.index];
            try out.append(arena, .{ .file = sym.file, .def = sym.def, .path = sym.path, .qname = sym.qname });
        }
        return out.items;
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
        const empty: Block = .{ .f = f, .text = "", .lines = &.{} };
        if (state.status != .indexed or f.def >= state.facts.defs.len) return empty;
        const d = state.facts.defs[f.def];
        const ft = (try self.fileText(arena, texts, f.path)) orelse return empty;
        const first_line = @max(d.line, 1);
        const last_line = @max(ft.lineOf(d.span.end), first_line);
        var w: Writer.Allocating = .init(arena);
        var lines: std.ArrayList(u32) = .empty;
        const base = indentOf(ft.line(first_line));
        try w.writer.print("{s}:{d} {s}\n", .{ f.path, first_line, f.qname });
        const head_end = statementEnd(ft, first_line, last_line);
        var h = first_line;
        while (h <= head_end) : (h += 1) {
            try writeCode(&w.writer, ft, h, base);
            try lines.append(arena, h);
        }
        var last_written = head_end;
        var kept: usize = 0;
        var n: u32 = head_end + 1;
        while (n <= last_line) : (n += 1) {
            const t = std.mem.trim(u8, ft.line(n), " \t\r");
            if (t.len == 0 or isComment(t)) continue;
            const forced = std.mem.indexOfScalar(u32, force, n) != null;
            const decision = isDecisionLine(t);
            const wanted = forced or decision or isFieldAssignment(t) or isMemberAlias(t) or callsAny(t, call_names, simpleName(f.qname)) or (try rank.maskOf(terms, t)) != 0;
            if (!wanted) continue;
            if (!forced and !decision and kept >= max_block_lines) continue;
            const end = statementEnd(ft, n, last_line);
            try writeGap(&w.writer, last_written, n);
            var k = n;
            while (k <= end) : (k += 1) {
                try writeCode(&w.writer, ft, k, base);
                try lines.append(arena, k);
            }
            last_written = end;
            n = end;
            kept += 1;
        }
        try writeGap(&w.writer, last_written, last_line + 1);
        return .{ .f = f, .text = w.written(), .lines = lines.items };
    }

    fn renderWrites(self: *Session, arena: Allocator, texts: *std.StringHashMapUnmanaged(FileText), f: Fn, write_lines: []const u32) !Block {
        const store = &self.repo.?.store;
        const state = store.file(f.file);
        const empty: Block = .{ .f = f, .text = "", .lines = &.{} };
        if (state.status != .indexed or f.def >= state.facts.defs.len) return empty;
        const d = state.facts.defs[f.def];
        const ft = (try self.fileText(arena, texts, f.path)) orelse return empty;
        const first_line = @max(d.line, 1);
        const last_line = @max(ft.lineOf(d.span.end), first_line);
        var picked: std.ArrayList(u32) = .empty;
        for (write_lines) |wl| {
            if (wl <= first_line or wl > last_line) continue;
            try addId(arena, &picked, wl);
            try enclosing(arena, ft, first_line, wl, &picked);
        }
        if (d.kind == .setter) {
            var n = first_line + 1;
            var kept: usize = 0;
            while (n <= last_line and kept < max_enclosing) : (n += 1) {
                if (!isFieldAssignment(std.mem.trim(u8, ft.line(n), " \t\r"))) continue;
                try addId(arena, &picked, n);
                kept += 1;
            }
        }
        std.mem.sort(u32, picked.items, {}, std.sort.asc(u32));
        var w: Writer.Allocating = .init(arena);
        const base = indentOf(ft.line(first_line));
        try w.writer.print("{s}:{d} {s}\n", .{ f.path, first_line, f.qname });
        try writeCode(&w.writer, ft, first_line, base);
        var last_written = first_line;
        for (picked.items) |n| {
            if (n <= last_written) continue;
            try writeGap(&w.writer, last_written, n);
            const end = statementEnd(ft, n, last_line);
            var k = n;
            while (k <= end) : (k += 1) try writeCode(&w.writer, ft, k, base);
            last_written = end;
        }
        try writeGap(&w.writer, last_written, last_line + 1);
        try picked.append(arena, first_line);
        return .{ .f = f, .text = w.written(), .lines = picked.items };
    }

    fn fieldsRead(self: *Session, arena: Allocator, texts: *std.StringHashMapUnmanaged(FileText), readers: []const Reader, terms: *const rank.Terms) ![]const FieldScore {
        const store = &self.repo.?.store;
        var scores: std.StringArrayHashMapUnmanaged(f64) = .empty;
        for (readers) |r| {
            const state = store.file(r.f.file);
            if (state.status != .indexed or r.f.def >= state.facts.defs.len) continue;
            const d = state.facts.defs[r.f.def];
            const ft = (try self.fileText(arena, texts, r.f.path)) orelse continue;
            const first_line = @max(d.line, 1);
            const last_line = @max(ft.lineOf(d.span.end), first_line);
            var n = first_line;
            while (n <= last_line) : (n += 1) {
                const t = std.mem.trim(u8, ft.line(n), " \t\r");
                if (t.len == 0 or isComment(t)) continue;
                const decision: f64 = if (isDecisionLine(t)) 2 else 1;
                for (try fieldReads(arena, t)) |fr| {
                    const receiver: f64 = if (fr.this_receiver) 0.5 else 1;
                    const entry = try scores.getOrPut(arena, fr.name);
                    if (!entry.found_existing) entry.value_ptr.* = 0;
                    entry.value_ptr.* += r.weight * decision * receiver;
                }
            }
        }
        var out: std.ArrayList(FieldScore) = .empty;
        for (scores.keys(), scores.values()) |name, score| {
            const boost: f64 = if ((try rank.maskOf(terms, name)) != 0) question_field_boost else 1;
            try out.append(arena, .{ .name = name, .score = score * boost });
        }
        std.mem.sort(FieldScore, out.items, {}, FieldScore.greater);
        if (out.items.len > max_read_fields) out.shrinkRetainingCapacity(max_read_fields);
        return out.items;
    }

    fn writerBlocks(self: *Session, arena: Allocator, texts: *std.StringHashMapUnmanaged(FileText), fields: []const FieldScore, visible: []const Block) ![]const WriterBlock {
        if (fields.len == 0) return &.{};
        const store = &self.repo.?.store;
        var index: std.StringHashMapUnmanaged(usize) = .empty;
        for (fields, 0..) |f, i| try index.put(arena, f.name, i);
        const files_of = try arena.alloc(std.ArrayList(u32), fields.len);
        for (files_of) |*l| l.* = .empty;
        for (store.files.items, 0..) |*state, id| {
            if (state.status != .indexed or isTest(state.path)) continue;
            for (state.facts.refs) |r| {
                if (r.kind != .write) continue;
                const i = index.get(r.name) orelse continue;
                try addId(arena, &files_of[i], @intCast(id));
            }
            for (state.facts.defs) |d| {
                if (d.kind != .setter) continue;
                const i = index.get(d.name) orelse continue;
                try addId(arena, &files_of[i], @intCast(id));
            }
        }
        for (fields, 0..) |f, i| {
            const list = store.loose_by_name.get(f.name) orelse continue;
            for (list.items) |k| {
                if (files_of[i].items.len > max_loose_files) break;
                const state = store.file(k.file);
                if (state.status != .indexed or isTest(state.path)) continue;
                try addId(arena, &files_of[i], k.file);
            }
        }
        var sites: std.ArrayList(WriteSite) = .empty;
        const crowd = try arena.alloc(usize, fields.len);
        @memset(crowd, 0);
        for (fields, 0..) |f, i| {
            if (files_of[i].items.len > max_loose_files) {
                crowd[i] = files_of[i].items.len;
                continue;
            }
            const needle = try std.mem.concat(arena, u8, &.{ ".", f.name });
            for (files_of[i].items) |fid| {
                const state = store.file(fid);
                const defs = state.facts.defs;
                for (defs, 0..) |d, di| {
                    if (d.kind != .setter or !std.mem.eql(u8, d.name, f.name)) continue;
                    try sites.append(arena, .{ .file = fid, .def = @intCast(di), .line = d.line, .field = i, .weight = setter_weight, .path = state.path });
                }
                const ft = (try self.fileText(arena, texts, state.path)) orelse continue;
                var at: usize = 0;
                var last: u32 = 0;
                while (std.mem.indexOfPos(u8, ft.bytes, at, needle)) |pos| {
                    at = pos + needle.len;
                    const line = ft.lineOf(@intCast(pos));
                    if (line == last) continue;
                    const t = std.mem.trim(u8, ft.line(line), " \t\r");
                    if (!writesField(t, f.name)) continue;
                    last = line;
                    const owner = ownerOf(defs, @intCast(pos)) orelse continue;
                    if (visibleLine(visible, fid, line)) continue;
                    try sites.append(arena, .{ .file = fid, .def = owner, .line = line, .field = i, .weight = siteWeight(defs[owner].kind, t, f.name), .path = state.path });
                }
            }
        }
        const count = try arena.alloc(usize, fields.len);
        @memset(count, 0);
        const best = try arena.alloc(f64, fields.len);
        @memset(best, 0);
        for (sites.items) |site| {
            count[site.field] += 1;
            best[site.field] = @max(best[site.field], site.weight);
        }
        var order: std.ArrayList(FieldOrder) = .empty;
        for (fields, 0..) |f, i| {
            if (count[i] == 0) continue;
            const spread = 1 + @log(@as(f64, @floatFromInt(1 + count[i] + crowd[i])));
            try order.append(arena, .{ .field = i, .value = f.score * best[i] / spread });
        }
        std.mem.sort(FieldOrder, order.items, {}, FieldOrder.greater);
        std.mem.sort(WriteSite, sites.items, {}, WriteSite.less);
        var groups: std.ArrayList(WriterGroup) = .empty;
        for (order.items) |o| {
            var picked: usize = 0;
            for (sites.items) |site| {
                if (site.field != o.field) continue;
                if (picked >= max_writes_per_field) break;
                if (site.weight < best[o.field] * min_site_share) continue;
                const state = store.file(site.file);
                const f: Fn = .{ .file = site.file, .def = site.def, .path = site.path, .qname = state.facts.defs[site.def].qname };
                var slot: ?usize = null;
                for (groups.items, 0..) |g, k| {
                    if (g.f.file == f.file and g.f.def == f.def) slot = k;
                }
                if (slot == null) {
                    if (groups.items.len >= max_writer_functions) continue;
                    slot = groups.items.len;
                    try groups.append(arena, .{ .f = f });
                }
                const g = &groups.items[slot.?];
                try addId(arena, &g.lines, site.line);
                if (!contains(g.fields.items, fields[o.field].name)) try g.fields.append(arena, fields[o.field].name);
                picked += 1;
            }
        }
        var out: std.ArrayList(WriterBlock) = .empty;
        for (groups.items) |g| {
            const b = try self.renderWrites(arena, texts, g.f, g.lines.items);
            if (b.text.len != 0) try out.append(arena, .{ .block = b, .fields = g.fields.items });
        }
        return out.items;
    }

    fn callerRows(self: *Session, arena: Allocator, f: Fn, terms: *const map_lines.WordSet) ![]const Row {
        const result = self.repo.?.query(arena, .{ .relation = .callers, .subject = f.qname, .path = f.path }) catch return &.{};
        const found = switch (result) {
            .complete => |c| c.value.sites,
            .partial => |p| p.value.sites,
            .refused => return &.{},
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
        return rows.items;
    }

    fn fnAt(self: *Session, path: []const u8, qname: []const u8, line: u32) ?Fn {
        const store = &self.repo.?.store;
        const id = store.fileId(path) orelse return null;
        const state = store.file(id);
        if (state.status != .indexed) return null;
        for (state.facts.defs, 0..) |d, di| {
            if (d.kind == .module or !d.kind.callable()) continue;
            if (d.line == line and std.mem.eql(u8, d.qname, qname)) return .{ .file = id, .def = @intCast(di), .path = state.path, .qname = d.qname };
        }
        return null;
    }

    fn defLine(self: *Session, f: Fn) u32 {
        const state = self.repo.?.store.file(f.file);
        if (f.def >= state.facts.defs.len) return 0;
        return state.facts.defs[f.def].line;
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
        const ft = try textOf(arena, bytes);
        try texts.put(arena, path, ft);
        return ft;
    }

    fn lineText(self: *Session, arena: Allocator, texts: *std.StringHashMapUnmanaged(FileText), path: []const u8, line: u32) ![]const u8 {
        const ft = (try self.fileText(arena, texts, path)) orelse return "";
        const trimmed = std.mem.trim(u8, ft.line(line), " \t\r");
        return trimmed[0..cutUtf8(trimmed, max_line_chars)];
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

const Symbol = struct {
    file: u32,
    def: u32,
    path: []const u8,
    qname: []const u8,
    parts: []const []const u8,
};

const Scored = struct {
    index: usize,
    score: f64,

    fn greater(_: void, a: Scored, b: Scored) bool {
        if (a.score != b.score) return a.score > b.score;
        return a.index < b.index;
    }
};

const Meet = struct {
    f: Fn,
    anchors: u32,
};

const Block = struct {
    f: Fn,
    text: []const u8,
    lines: []const u32,
};

const WriterBlock = struct {
    block: Block,
    fields: []const []const u8,
};

const WriterGroup = struct {
    f: Fn,
    lines: std.ArrayList(u32) = .empty,
    fields: std.ArrayList([]const u8) = .empty,
};

const Reader = struct {
    f: Fn,
    weight: f64,
};

const FieldScore = struct {
    name: []const u8,
    score: f64,

    fn greater(_: void, a: FieldScore, b: FieldScore) bool {
        if (a.score != b.score) return a.score > b.score;
        return std.mem.order(u8, a.name, b.name) == .lt;
    }
};

const FieldOrder = struct {
    field: usize,
    value: f64,

    fn greater(_: void, a: FieldOrder, b: FieldOrder) bool {
        if (a.value != b.value) return a.value > b.value;
        return a.field < b.field;
    }
};

const WriteSite = struct {
    file: u32,
    def: u32,
    line: u32,
    field: usize,
    weight: f64,
    path: []const u8,

    fn less(_: void, a: WriteSite, b: WriteSite) bool {
        if (a.field != b.field) return a.field < b.field;
        if (a.weight != b.weight) return a.weight > b.weight;
        const order = std.mem.order(u8, a.path, b.path);
        if (order != .eq) return order == .lt;
        return a.line < b.line;
    }
};

const Filler = struct {
    room: usize,
    text: Writer.Allocating,
    renders: usize = 0,

    fn done(self: *const Filler) bool {
        return self.room < min_filler_room or self.renders >= max_filler_renders;
    }

    fn take(self: *Filler, arena: Allocator, shown: *std.AutoHashMapUnmanaged(u64, void), b: Block) !void {
        if (b.text.len == 0 or b.text.len > self.room or shown.contains(keyOf(b.f))) return;
        try self.text.writer.writeAll(b.text);
        self.room -= b.text.len;
        try shown.put(arena, keyOf(b.f), {});
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

fn textOf(arena: Allocator, bytes: []const u8) !FileText {
    var starts: std.ArrayList(u32) = .empty;
    try starts.append(arena, 0);
    for (bytes, 0..) |b, i| {
        if (b == '\n') try starts.append(arena, @intCast(i + 1));
    }
    return .{ .bytes = bytes, .starts = starts.items };
}

fn rankedOrder(arena: Allocator, rankings: []const rank.Ranking) ![]const Fn {
    var out: std.ArrayList(Fn) = .empty;
    var level: usize = 0;
    while (level < max_ranked_level) : (level += 1) {
        var any = false;
        for (rankings) |ranked| {
            if (level >= ranked.hits.len) continue;
            any = true;
            const hit = ranked.hits[level];
            if (hit.score <= 0 or hit.matched == 0 or isTest(hit.path)) continue;
            _ = try appendFn(arena, &out, .{ .file = hit.file, .def = hit.def, .path = hit.path, .qname = hit.qname });
        }
        if (!any) break;
    }
    return out.items;
}

fn appendReader(arena: Allocator, list: *std.ArrayList(Reader), f: Fn, weight: f64) !void {
    for (list.items) |r| {
        if (r.f.file == f.file and r.f.def == f.def) return;
    }
    try list.append(arena, .{ .f = f, .weight = weight });
}

fn addId(arena: Allocator, list: *std.ArrayList(u32), id: u32) !void {
    if (std.mem.indexOfScalar(u32, list.items, id) != null) return;
    try list.append(arena, id);
}

fn visibleLine(visible: []const Block, file: u32, line: u32) bool {
    for (visible) |b| {
        if (b.f.file == file and std.mem.indexOfScalar(u32, b.lines, line) != null) return true;
    }
    return false;
}

fn ownerOf(defs: []const facts.Def, offset: u32) ?u32 {
    var best: ?u32 = null;
    for (defs, 0..) |d, i| {
        if (d.kind == .module or d.kind == .class or !d.kind.callable()) continue;
        if (offset < d.span.start or offset >= d.span.end) continue;
        if (best) |b| {
            if (d.span.start < defs[b].span.start) continue;
        }
        best = @intCast(i);
    }
    return best;
}

fn siteWeight(kind: facts.DefKind, t: []const u8, field: []const u8) f64 {
    var w: f64 = 1;
    if (kind == .constructor) w *= constructor_weight;
    if (isParamCopy(t, field)) w *= param_copy_weight;
    return w;
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

fn isComment(t: []const u8) bool {
    return std.mem.startsWith(u8, t, "//") or std.mem.startsWith(u8, t, "*") or std.mem.startsWith(u8, t, "/*");
}

fn enclosing(arena: Allocator, ft: FileText, first_line: u32, write_line: u32, picked: *std.ArrayList(u32)) !void {
    var limit = indentOf(ft.line(write_line));
    var n = write_line;
    var found: usize = 0;
    while (n > first_line + 1 and found < max_enclosing) {
        n -= 1;
        const raw = ft.line(n);
        const t = std.mem.trim(u8, raw, " \t\r");
        if (t.len == 0 or isComment(t)) continue;
        const ind = indentOf(raw);
        if (ind >= limit) continue;
        try addId(arena, picked, n);
        found += 1;
        if (t[0] == ')') {
            var extra: usize = 0;
            while (n > first_line + 1 and extra < max_enclosing + 1) {
                n -= 1;
                const inner = ft.line(n);
                if (std.mem.trim(u8, inner, " \t\r").len == 0) continue;
                try addId(arena, picked, n);
                extra += 1;
                if (indentOf(inner) <= ind) break;
            }
            limit = ind;
        } else {
            limit = if (t[0] == '}') ind + 1 else ind;
        }
    }
}

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

fn writeCode(w: *Writer, ft: FileText, n: u32, base: usize) !void {
    const raw = std.mem.trimEnd(u8, ft.line(n), " \t\r");
    var cut: usize = 0;
    while (cut < base and cut < raw.len and (raw[cut] == ' ' or raw[cut] == '\t')) cut += 1;
    const text = raw[cut..];
    try w.print("{d:>5}  {s}\n", .{ n, text[0..cutUtf8(text, max_code_chars)] });
}

fn writeGap(w: *Writer, from: u32, to: u32) !void {
    if (to <= from + 1) return;
    const skipped = to - from - 1;
    try w.print("       \u{2026} {d} {s}\n", .{ skipped, if (skipped == 1) "line" else "lines" });
}

fn bracketDelta(t: []const u8) i32 {
    var depth: i32 = 0;
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        const c = t[i];
        if (quote != 0) {
            if (c == '\\') {
                i += 1;
            } else if (c == quote) quote = 0;
            continue;
        }
        if (c == '/' and i + 1 < t.len and t[i + 1] == '/') break;
        switch (c) {
            '\'', '"', '`' => quote = c,
            '(', '[' => depth += 1,
            ')', ']' => depth -= 1,
            else => {},
        }
    }
    return depth;
}

fn statementEnd(ft: FileText, start: u32, last: u32) u32 {
    var depth: i32 = 0;
    var n = start;
    while (n <= last) : (n += 1) {
        depth += bracketDelta(ft.line(n));
        if (depth <= 0 or n - start + 1 >= max_statement_lines) return n;
    }
    return last;
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
    for ([_][]const u8{ ".sort(", ".reverse(", ".find(", "===", "!==", " < ", " > ", " <= ", " >= " }) |marker| {
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

pub const FieldRead = struct {
    name: []const u8,
    this_receiver: bool,
};

fn writeAfter(t: []const u8, end: usize) bool {
    var j = end;
    while (j < t.len and t[j] == ' ') j += 1;
    if (j >= t.len) return false;
    const c = t[j];
    const n1: u8 = if (j + 1 < t.len) t[j + 1] else 0;
    const n2: u8 = if (j + 2 < t.len) t[j + 2] else 0;
    if (c == '=') return n1 != '=' and n1 != '>';
    if ((c == '+' and n1 == '+') or (c == '-' and n1 == '-')) return true;
    if ((c == '+' or c == '-' or c == '*' or c == '/' or c == '%') and n1 == '=') return true;
    return n2 == '=' and ((c == '|' and n1 == '|') or (c == '&' and n1 == '&') or (c == '?' and n1 == '?'));
}

fn receiverIsThis(t: []const u8, dot: usize) bool {
    var start = dot;
    while (start > 0 and identByte(t[start - 1])) start -= 1;
    if (!std.mem.eql(u8, t[start..dot], "this")) return false;
    return start == 0 or !(identByte(t[start - 1]) or t[start - 1] == '.');
}

pub fn fieldReads(arena: Allocator, t: []const u8) ![]const FieldRead {
    var out: std.ArrayList(FieldRead) = .empty;
    var i: usize = 1;
    while (i < t.len) : (i += 1) {
        if (t[i] != '.') continue;
        const prev = t[i - 1];
        if (!(identByte(prev) or prev == ')' or prev == ']' or prev == '?')) continue;
        var end = i + 1;
        if (end >= t.len or !(std.ascii.isAlphabetic(t[end]) or t[end] == '_' or t[end] == '$')) continue;
        while (end < t.len and identByte(t[end])) end += 1;
        const field = t[i + 1 .. end];
        if (end < t.len and t[end] == '(') continue;
        if (writeAfter(t, end)) continue;
        if (field.len < 4 or isCommonField(field)) continue;
        const seen = for (out.items) |r| {
            if (std.mem.eql(u8, r.name, field)) break true;
        } else false;
        if (seen) continue;
        try out.append(arena, .{ .name = field, .this_receiver = receiverIsThis(t, i) });
    }
    return out.items;
}

pub fn writesField(t: []const u8, field: []const u8) bool {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, t, at, field)) |pos| {
        at = pos + field.len;
        if (pos < 2 or t[pos - 1] != '.') continue;
        const before = t[pos - 2];
        if (!(identByte(before) or before == ')' or before == ']')) continue;
        if (at < t.len and identByte(t[at])) continue;
        if (writeAfter(t, at)) return true;
    }
    return false;
}

pub fn isParamCopy(t: []const u8, field: []const u8) bool {
    const at = assignmentAt(t) orelse return false;
    const left = std.mem.trim(u8, t[0..at], " ");
    const right = std.mem.trim(u8, t[at + 1 ..], " ;");
    return std.mem.endsWith(u8, left, field) and std.mem.eql(u8, right, field);
}

pub fn isMemberAlias(t: []const u8) bool {
    var rest = t;
    for ([_][]const u8{ "const ", "let ", "var " }) |word| {
        if (std.mem.startsWith(u8, t, word)) rest = t[word.len..];
    }
    if (rest.len == t.len) return false;
    const at = assignmentAt(rest) orelse return false;
    const right = std.mem.trim(u8, rest[at + 1 ..], " ;");
    if (right.len == 0 or std.mem.indexOfScalar(u8, right, '.') == null) return false;
    for (right) |c| {
        if (!(identByte(c) or c == '.' or c == '?' or c == '!')) return false;
    }
    return true;
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

test "map tools: field reads skip calls, writes, short and common names and mark this receivers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sorted = try fieldReads(arena, "modules.sort((a, b) => b.distance - a.distance);");
    try testing.expectEqual(@as(usize, 1), sorted.len);
    try testing.expectEqualStrings("distance", sorted[0].name);
    try testing.expect(!sorted[0].this_receiver);
    const guarded = try fieldReads(arena, "if (wrapper.hierarchyLevel > x.length && this.isTreeStatic() && this.ready) {");
    try testing.expectEqual(@as(usize, 2), guarded.len);
    try testing.expectEqualStrings("hierarchyLevel", guarded[0].name);
    try testing.expectEqualStrings("ready", guarded[1].name);
    try testing.expect(guarded[1].this_receiver);
    try testing.expectEqual(@as(usize, 0), (try fieldReads(arena, "wrapper.level = depth + 1;")).len);
    try testing.expectEqualStrings("level", (try fieldReads(arena, "const level = wrapper.level;"))[0].name);
}

test "map tools: a field write assigns or updates that member and a local alias of a member is recognized" {
    try testing.expect(writesField("moduleRef.distance = depth;", "distance"));
    try testing.expect(writesField("wrapper.level = depth + 1;", "level"));
    try testing.expect(writesField("counter.total += 1;", "total"));
    try testing.expect(writesField("node.visits++;", "visits"));
    try testing.expect(!writesField("if (moduleRef.distance === depth) {", "distance"));
    try testing.expect(!writesField("const d = moduleRef.distance;", "distance"));
    try testing.expect(!writesField("moduleRef.distanceTo = 1;", "distance"));
    try testing.expect(!writesField("this._distance = value;", "distance"));
    try testing.expect(isParamCopy("this.level = level;", "level"));
    try testing.expect(!isParamCopy("this.level = options.level;", "level"));
    try testing.expect(isMemberAlias("const level = wrapper.level;"));
    try testing.expect(!isMemberAlias("const level = compute(wrapper);"));
    try testing.expect(!isMemberAlias("level = wrapper.level;"));
}

test "map tools: a write is shown with the lines that open the blocks around it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ft = try textOf(arena, "  calc() {\n    const tree = make();\n    tree.walk((moduleRef, depth) => {\n      if (moduleRef.isGlobal) {\n        return;\n      }\n      moduleRef.distance = depth;\n    });\n  }\n");
    var picked: std.ArrayList(u32) = .empty;
    try enclosing(arena, ft, 1, 7, &picked);
    try testing.expectEqualSlices(u32, &.{3}, picked.items);
    const guarded = try textOf(arena, "  add() {\n    if (\n      global &&\n      ready\n    ) {\n      moduleRef.distance = 1;\n    }\n  }\n");
    var lines: std.ArrayList(u32) = .empty;
    try enclosing(arena, guarded, 1, 6, &lines);
    std.mem.sort(u32, lines.items, {}, std.sort.asc(u32));
    try testing.expectEqualSlices(u32, &.{ 2, 3, 4, 5 }, lines.items);
}

test "map tools: test paths are recognized by folder and by the spec infix" {
    try testing.expect(isTest("packages/core/test/injector.spec.ts"));
    try testing.expect(isTest("src/__tests__/a.ts"));
    try testing.expect(!isTest("packages/core/injector/injector.ts"));
}
