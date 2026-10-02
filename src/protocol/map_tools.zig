const std = @import("std");
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
pub const explore_k: u32 = 10;
pub const total_budget: usize = 60_000;
pub const explore_budget: usize = 28_000;
pub const users_budget: usize = 12_000;
pub const callers_budget: usize = 4_000;
pub const writers_budget: usize = 8_000;
pub const max_focus_total: usize = 4;
pub const max_read_fields: usize = 12;
pub const max_write_lines: usize = 14;
pub const max_writes_per_field: usize = 3;
pub const max_writer_bodies: usize = 2;
pub const callee_budget: usize = 9_000;
pub const names_budget: usize = 5_000;
pub const max_users_shown: usize = 6;
pub const max_seeds: usize = 10;
pub const max_question_seeds: usize = 4;
pub const max_user_regions: usize = 2;
pub const user_region_depth: usize = 20;
pub const evidence_budget: usize = 16_000;
pub const max_regions: usize = 3;
pub const max_focus_named: usize = 3;
pub const max_focus_shown: usize = 2;
pub const max_extra: usize = 5;
pub const max_used: usize = 6;
pub const max_evidence_names: usize = 6;
pub const max_line_text: usize = 160;
pub const max_instructions: usize = 1_900;
pub const max_folders: usize = 40;

pub const explore_description = "Find the code that answers a question about this repository. Returns the best-matching functions with code and line numbers, the functions they call, and the lines where they are used. question: a short English search phrase with the concepts, identifiers and folders involved. names: optional function or class names (Class.method or function) you already know are central.";
pub const evidence_description = "Return the full code of up to 6 functions by qualified name (Class.method or function), as plain text.";

const instructions_head = "emetgate reads the code of this repository for you. For a question about the code, call explore once with a short English " ++
    "search phrase naming the concepts, identifiers and folders involved, plus the names of central functions or classes if you " ++
    "already know them. One reply is complete: the best-matching functions with code and line numbers, the code that uses the " ++
    "definitions they name, the functions they call, and the lines where they are used. Call explore or evidence again only when " ++
    "the code of a function you need is missing from it.\n" ++
    "Answer in at most 10 short lines: the conclusion first, then each deciding function as file:line with what it decides. " ++
    "No headings and no code blocks.\n" ++
    "Top folders: ";

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
        return plain(gpa, try self.answer(arena, question, names), false);
    }

    pub fn answer(self: *Session, arena: Allocator, question: []const u8, names: []const []const u8) ![]const u8 {
        const repo = self.repo.?;
        const store = &repo.store;
        const built = &self.built.?;
        var joined: Writer.Allocating = .init(arena);
        try joined.writer.writeAll(question);
        for (names) |n| try joined.writer.print(" {s}", .{n});
        const query = joined.written();
        const terms_words = try map_lines.words(arena, query);
        const terms = try rank.Terms.ofQuestion(arena, self.lex.?, query);
        var first = try self.lines.?.pick(arena, &terms_words, max_regions);
        if (first.len == 0) {
            var pick_words = try map_lines.words(arena, query);
            var stems: std.ArrayList([]const u8) = .empty;
            for (terms.concepts) |c| try stems.appendSlice(arena, c.alternatives);
            try self.lines.?.expandStems(&pick_words, stems.items);
            first = try self.lines.?.pick(arena, &pick_words, max_regions);
        }
        if (first.len == 0) first = (try map_pick.pick(arena, store, built, &terms, .{}, self.index, .{ .max_regions = max_regions })).regions;

        var seeds: std.ArrayList(map_usage.Seed) = .empty;
        for (names) |n| try self.addSeed(arena, &seeds, n);
        var questioned: usize = 0;
        for (try questionIdentifiers(arena, question)) |ident| {
            if (questioned >= max_question_seeds) break;
            const before = seeds.items.len;
            try self.addSeed(arena, &seeds, ident);
            if (seeds.items.len != before) questioned += 1;
        }
        for (first) |r| {
            const ranked = rank.rankInRegion(arena, store, built, r, &terms, .{}, self.index) catch continue;
            if (ranked.hits.len == 0 or ranked.hits[0].score <= 0 or ranked.hits[0].matched == 0) continue;
            try appendSeed(arena, &seeds, .{ .file = ranked.hits[0].file, .def = ranked.hits[0].def });
        }
        if (seeds.items.len > max_seeds) seeds.shrinkRetainingCapacity(max_seeds);

        const users = try map_usage.users(arena, store, seeds.items, .{ .skip = &isTest });
        const ranked_users = try self.rankUsers(arena, users, &terms);

        var regions: std.ArrayList(map.RegionId) = .empty;
        for (first[0..@min(first.len, 2)]) |r| try regions.append(arena, r);
        for (try self.userRegions(arena, ranked_users, first)) |r| {
            if (std.mem.indexOfScalar(map.RegionId, regions.items, r) == null) try regions.append(arena, r);
        }
        for (first) |r| {
            if (regions.items.len >= map_explore.max_merged_regions) break;
            if (std.mem.indexOfScalar(map.RegionId, regions.items, r) == null) try regions.append(arena, r);
        }

        var out: Writer.Allocating = .init(arena);
        var text: []const u8 = "";
        if (regions.items.len != 0) {
            const fs = try repo.factStore(arena);
            const explored = try map_explore.explore(&fs, built, regions.items, &terms, .{ .k = explore_k, .budget = explore_budget, .index = self.index, .region_limit = map_explore.max_merged_regions });
            text = switch (explored) {
                .complete => |c| c.value.text,
                .partial => |p| p.value.text,
                .refused => blk: {
                    var status: Writer.Allocating = .init(arena);
                    try explored.writeStatus(&status.writer, 0, "functions shown");
                    try status.writer.writeByte('\n');
                    break :blk status.written();
                },
            };
        }
        try out.writer.writeAll(if (text.len != 0) std.mem.trimEnd(u8, text, "\n") else "no part of the repository matched the phrase");
        const shown = try shownTargets(arena, text);
        var included: std.ArrayList([]const u8) = .empty;
        try included.appendSlice(arena, shown);

        var user_names: std.ArrayList([]const u8) = .empty;
        var user_targets: std.ArrayList(evidence.SymbolRef) = .empty;
        for (ranked_users) |u| {
            if (user_targets.items.len >= max_users_shown) break;
            if (u.score <= 0 or contains(included.items, u.user.qname)) continue;
            try user_targets.append(arena, .{ .path = u.user.path, .qname = u.user.qname });
            try user_names.append(arena, u.user.qname);
        }
        if (user_targets.items.len != 0) {
            const room = @min(users_budget, total_budget -| out.written().len);
            const body = try self.evidenceRefs(arena, user_targets.items, room);
            if (body.len != 0) {
                try out.writer.print("\nCode that uses the definitions above:\n{s}", .{std.mem.trimEnd(u8, body, "\n")});
                try included.appendSlice(arena, user_names.items);
            }
        }

        var focus: std.ArrayList([]const u8) = .empty;
        for (names) |n| {
            if (focus.items.len >= max_focus_named) break;
            if (self.fileOf(n) != null and !contains(focus.items, n)) try focus.append(arena, n);
        }
        for (shown) |n| {
            if (focus.items.len >= max_focus_total) break;
            if (self.fileOf(n) != null and !contains(focus.items, n)) try focus.append(arena, n);
        }

        var used: Writer.Allocating = .init(arena);
        for (focus.items) |n| try self.usedLines(arena, &used.writer, n, &terms_words);
        const used_text = std.mem.trimEnd(u8, used.written(), "\n");
        if (used_text.len != 0) {
            const room = @min(callers_budget, total_budget -| out.written().len);
            const header = "\nWhere the top functions are called:\n";
            if (room > header.len + 80) {
                try out.writer.writeAll(header);
                try out.writer.writeAll(used_text[0..lineCut(used_text, room - header.len)]);
            }
        }

        const writers = try self.fieldWriters(arena, out.written(), included.items);
        if (writers.lines.len != 0) {
            const room = @min(writers_budget, total_budget -| out.written().len);
            const header = "\nWhere the fields read above are written:\n";
            if (room > header.len + 80) {
                const lines_text = writers.lines[0..lineCut(writers.lines, room - header.len)];
                try out.writer.writeAll(header);
                try out.writer.writeAll(lines_text);
                const left = room -| (header.len + lines_text.len);
                if (writers.owners.len != 0 and left >= evidence.min_budget) {
                    const body = try self.evidenceRefs(arena, writers.owners, left);
                    if (body.len != 0) {
                        try out.writer.print("\n{s}", .{std.mem.trimEnd(u8, body, "\n")});
                        for (writers.owners) |o| try included.append(arena, o.qname);
                    }
                }
            }
        }

        var callees: std.ArrayList([]const u8) = .empty;
        for (focus.items[0..@min(focus.items.len, max_focus_shown)]) |n| {
            for (try self.sites(arena, .callees, n)) |s| {
                if (callees.items.len >= max_extra) break;
                const t = s.target.qname;
                if (t.len == 0) continue;
                const path = self.fileOf(t) orelse continue;
                if (contains(included.items, t) or contains(callees.items, t) or contains(names, t) or isTest(path)) continue;
                try callees.append(arena, t);
            }
        }
        if (callees.items.len != 0) {
            const room = @min(callee_budget, total_budget -| out.written().len);
            const body = if (room >= evidence.min_budget) try self.evidenceText(arena, callees.items, room) else "";
            if (body.len != 0) {
                try out.writer.print("\nFunctions they call:\n{s}", .{std.mem.trimEnd(u8, body, "\n")});
                try included.appendSlice(arena, callees.items);
            }
        }

        var named: std.ArrayList([]const u8) = .empty;
        for (names) |n| {
            if (!contains(included.items, n) and !contains(named.items, n)) try named.append(arena, n);
        }
        if (named.items.len != 0) {
            const room = @min(names_budget, total_budget -| out.written().len);
            const body = if (room >= evidence.min_budget) try self.evidenceText(arena, named.items[0..@min(named.items.len, max_extra)], room) else "";
            if (body.len != 0) try out.writer.print("\nFunctions you named:\n{s}", .{std.mem.trimEnd(u8, body, "\n")});
        }
        return out.written();
    }

    const Writers = struct {
        lines: []const u8,
        owners: []const evidence.SymbolRef,
    };

    const WriteSite = struct {
        path: []const u8,
        line: u32,
        owner: []const u8,
        file: u32,
        def: u32,
        field: usize,
        known: bool,
    };

    fn fieldWriters(self: *Session, arena: Allocator, reply: []const u8, included: []const []const u8) !Writers {
        const fields = try readFields(arena, reply);
        if (fields.len == 0) return .{ .lines = "", .owners = &.{} };
        var index: std.StringHashMapUnmanaged(usize) = .empty;
        for (fields, 0..) |f, i| try index.put(arena, f, i);
        const store = &self.repo.?.store;
        var sites_found: std.ArrayList(WriteSite) = .empty;
        for (store.files.items, 0..) |*state, id| {
            if (state.status != .indexed or isTest(state.path)) continue;
            const defs = state.facts.defs;
            const known = std.mem.indexOf(u8, reply, state.path) != null;
            for (state.facts.refs) |r| {
                if (r.kind != .write) continue;
                const i = index.get(r.name) orelse continue;
                if (r.from == 0 or r.from >= defs.len) continue;
                try sites_found.append(arena, .{ .path = state.path, .line = r.line, .owner = defs[r.from].qname, .file = @intCast(id), .def = r.from, .field = i, .known = known });
            }
            for (defs, 0..) |d, di| {
                if (d.kind != .setter) continue;
                const i = index.get(d.name) orelse continue;
                try sites_found.append(arena, .{ .path = state.path, .line = d.line, .owner = d.qname, .file = @intCast(id), .def = @intCast(di), .field = i, .known = known });
            }
        }
        std.mem.sort(WriteSite, sites_found.items, {}, struct {
            fn less(_: void, a: WriteSite, b: WriteSite) bool {
                if (a.field != b.field) return a.field < b.field;
                if (a.known != b.known) return a.known;
                const order = std.mem.order(u8, a.path, b.path);
                if (order != .eq) return order == .lt;
                return a.line < b.line;
            }
        }.less);
        var lines: Writer.Allocating = .init(arena);
        var owners: std.ArrayList(evidence.SymbolRef) = .empty;
        const per_field = try arena.alloc(usize, fields.len);
        @memset(per_field, 0);
        var written: usize = 0;
        var last_path: []const u8 = "";
        var last_line: u32 = 0;
        for (sites_found.items) |s| {
            if (written >= max_write_lines) break;
            if (per_field[s.field] >= max_writes_per_field) continue;
            if (std.mem.eql(u8, s.path, last_path) and s.line == last_line) continue;
            per_field[s.field] += 1;
            written += 1;
            last_path = s.path;
            last_line = s.line;
            try lines.writer.print("{s}:{d}  in {s}: {s}\n", .{ s.path, s.line, s.owner, try self.lineText(arena, s.path, s.line) });
            if (owners.items.len < max_writer_bodies and !contains(included, s.owner)) {
                for (owners.items) |o| {
                    if (std.mem.eql(u8, o.qname, s.owner) and std.mem.eql(u8, o.path, s.path)) break;
                } else try owners.append(arena, .{ .path = s.path, .qname = s.owner });
            }
        }
        return .{ .lines = lines.written(), .owners = owners.items };
    }

    pub fn slice(self: *Session, arena: Allocator, question: []const u8) ![]const u8 {
        const repo = self.repo.?;
        const store = &repo.store;
        const built = &self.built.?;
        const terms = try rank.Terms.ofQuestion(arena, self.lex.?, question);
        var pick_words = try map_lines.words(arena, question);
        var stems: std.ArrayList([]const u8) = .empty;
        for (terms.concepts) |c| try stems.appendSlice(arena, c.alternatives);
        try self.lines.?.expandStems(&pick_words, stems.items);
        var first = try self.lines.?.pick(arena, &pick_words, max_regions);
        if (first.len == 0) first = (try map_pick.pick(arena, store, built, &terms, .{}, self.index, .{ .max_regions = max_regions })).regions;

        var seeds: std.ArrayList(map_usage.Seed) = .empty;
        var questioned: usize = 0;
        for (try questionIdentifiers(arena, question)) |ident| {
            if (questioned >= max_question_seeds) break;
            const before = seeds.items.len;
            try self.addSeed(arena, &seeds, ident);
            if (seeds.items.len != before) questioned += 1;
        }
        var rankings: std.ArrayList(rank.Ranking) = .empty;
        for (first) |r| {
            const ranked = rank.rankInRegion(arena, store, built, r, &terms, .{}, self.index) catch continue;
            try rankings.append(arena, ranked);
            if (ranked.hits.len == 0 or ranked.hits[0].score <= 0 or ranked.hits[0].matched == 0) continue;
            try appendSeed(arena, &seeds, .{ .file = ranked.hits[0].file, .def = ranked.hits[0].def });
        }
        if (seeds.items.len > max_seeds) seeds.shrinkRetainingCapacity(max_seeds);
        const users = try map_usage.users(arena, store, seeds.items, .{ .skip = &isTest });
        const ranked_users = try self.rankUsers(arena, users, &terms);
        for (try self.userRegions(arena, ranked_users, first)) |r| {
            if (rankings.items.len >= map_explore.max_merged_regions) break;
            const ranked = rank.rankInRegion(arena, store, built, r, &terms, .{}, self.index) catch continue;
            try rankings.append(arena, ranked);
        }

        var chosen: std.ArrayList(Chosen) = .empty;
        var depth: usize = 0;
        while (chosen.items.len < max_slice_ranked and depth < max_slice_depth) : (depth += 1) {
            var any = false;
            for (rankings.items) |ranked| {
                if (depth >= ranked.hits.len) continue;
                any = true;
                const hit = ranked.hits[depth];
                if (hit.score <= 0 or hit.matched == 0 or isTest(hit.path)) continue;
                if (chosen.items.len >= max_slice_ranked) break;
                _ = try appendChosen(arena, &chosen, .{ .file = hit.file, .def = hit.def, .path = hit.path, .qname = hit.qname });
            }
            if (!any) break;
        }
        var users_taken: usize = 0;
        for (ranked_users) |u| {
            if (users_taken >= max_users_shown) break;
            if (u.score <= 0) continue;
            if (try appendChosen(arena, &chosen, .{ .file = u.user.file, .def = u.user.def, .path = u.user.path, .qname = u.user.qname })) users_taken += 1;
        }
        const focus_count = @min(chosen.items.len, max_focus_shown);
        var callees_taken: usize = 0;
        for (chosen.items[0..focus_count]) |c| {
            for (try self.sites(arena, .callees, c.qname)) |s| {
                if (callees_taken >= max_extra) break;
                const t = s.target;
                if (t.qname.len == 0 or isTest(t.path)) continue;
                const state = store.file(t.id.file);
                const di = state.defIndex(t.id.slot) orelse continue;
                if (try appendChosen(arena, &chosen, .{ .file = t.id.file, .def = di, .path = t.path, .qname = t.qname })) callees_taken += 1;
            }
        }

        var names: std.ArrayList([]const u8) = .empty;
        for (chosen.items) |c| {
            const simple = simpleName(c.qname);
            if (simple.len >= 4) try names.append(arena, simple);
        }
        var texts: std.StringHashMapUnmanaged(FileText) = .empty;
        var out: Writer.Allocating = .init(arena);
        const closing = "If more code is needed, call emetgate_explore with the question, or emetgate_evidence with function names.";
        const limit = slice_budget -| (closing.len + 1);
        for (chosen.items) |c| {
            var block: Writer.Allocating = .init(arena);
            try self.sliceOf(arena, &texts, &block.writer, c, &terms, names.items);
            if (block.written().len == 0) continue;
            if (out.written().len + block.written().len > limit) {
                const room = limit -| out.written().len;
                if (room < 200) break;
                try out.writer.writeAll(block.written()[0..lineCut(block.written(), room)]);
                if (out.written().len != 0 and out.written()[out.written().len - 1] != '\n') try out.writer.writeByte('\n');
                break;
            }
            try out.writer.writeAll(block.written());
        }
        try out.writer.writeAll(closing);
        try out.writer.writeByte('\n');
        return out.written();
    }

    fn sliceOf(self: *Session, arena: Allocator, texts: *std.StringHashMapUnmanaged(FileText), w: *Writer, c: Chosen, terms: *const rank.Terms, names: []const []const u8) !void {
        const state = self.repo.?.store.file(c.file);
        if (state.status != .indexed or c.def >= state.facts.defs.len) return;
        const d = state.facts.defs[c.def];
        const ft = (try self.fileText(arena, texts, c.path)) orelse return;
        const last_line = ft.lineOf(d.span.end);
        const first_line = @max(d.line, 1);
        try w.print("{s}:{d} {s}\n", .{ c.path, first_line, c.qname });
        try writeLine(w, ft, first_line);
        var kept: usize = 0;
        var n: u32 = first_line + 1;
        while (n <= last_line and kept < max_slice_lines) : (n += 1) {
            const raw = ft.line(n);
            const t = std.mem.trim(u8, raw, " \t\r");
            if (t.len == 0 or std.mem.startsWith(u8, t, "//") or std.mem.startsWith(u8, t, "*") or std.mem.startsWith(u8, t, "/*")) continue;
            const meta = isMetadata(t);
            const calls = callsAny(t, names, simpleName(c.qname));
            const shape = isCondition(t) or isReturn(t) or isAssignment(t);
            const concept = shape and (try rank.maskOf(terms, t)) != 0;
            if (!(meta or calls or concept)) continue;
            try writeLine(w, ft, n);
            kept += 1;
        }
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

    fn addSeed(self: *Session, arena: Allocator, seeds: *std.ArrayList(map_usage.Seed), name: []const u8) !void {
        const path = self.fileOf(name) orelse return;
        const store = &self.repo.?.store;
        const id = store.fileId(path) orelse return;
        const state = store.file(id);
        if (state.status != .indexed) return;
        var simple_match: ?u32 = null;
        for (state.facts.defs, 0..) |d, di| {
            if (d.kind == .module) continue;
            if (std.mem.eql(u8, d.qname, name)) return appendSeed(arena, seeds, .{ .file = id, .def = @intCast(di) });
            if (simple_match == null and std.mem.eql(u8, simpleName(d.qname), name)) simple_match = @intCast(di);
        }
        if (simple_match) |di| try appendSeed(arena, seeds, .{ .file = id, .def = di });
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

    fn userRegions(self: *Session, arena: Allocator, ranked: []const RankedUser, first: []const map.RegionId) ![]const map.RegionId {
        const built = &self.built.?;
        const totals = try arena.alloc(f64, built.regions.len);
        @memset(totals, 0);
        for (ranked[0..@min(ranked.len, user_region_depth)]) |u| {
            if (u.score <= 0) continue;
            const r = built.regionOfPath(u.user.path) orelse continue;
            if (r >= totals.len or built.regions[r].family != .code) continue;
            totals[r] += u.score;
        }
        var out: std.ArrayList(map.RegionId) = .empty;
        while (out.items.len < max_user_regions) {
            var best: ?usize = null;
            for (totals, 0..) |t, r| {
                if (t <= 0 or std.mem.indexOfScalar(map.RegionId, first, @intCast(r)) != null or std.mem.indexOfScalar(map.RegionId, out.items, @intCast(r)) != null) continue;
                if (best == null or t > totals[best.?]) best = r;
            }
            const r = best orelse break;
            try out.append(arena, @intCast(r));
        }
        return out.items;
    }

    fn evidenceRefs(self: *Session, arena: Allocator, targets: []const evidence.SymbolRef, budget: usize) ![]const u8 {
        if (targets.len == 0 or budget < evidence.min_budget) return "";
        const result = try self.repo.?.evidence(arena, .{ .targets = targets, .intent = .explain, .terms = &.{}, .include = .{ .callers = false, .callees = false, .tests = false } }, budget);
        return switch (result) {
            .complete => |c| c.value.text,
            .partial => |p| p.value.text,
            .refused => "",
        };
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

    fn sites(self: *Session, arena: Allocator, relation: facts_query.Relation, name: []const u8) ![]const facts_query.Site {
        const path = self.fileOf(name) orelse return &.{};
        const result = self.repo.?.query(arena, .{ .relation = relation, .subject = name, .path = path }) catch return &.{};
        return switch (result) {
            .complete => |c| c.value.sites,
            .partial => |p| p.value.sites,
            .refused => &.{},
        };
    }

    fn usedLines(self: *Session, arena: Allocator, w: *Writer, name: []const u8, terms: *const map_lines.WordSet) !void {
        const home = self.fileOf(name) orelse "";
        var rows: std.ArrayList(Row) = .empty;
        for (try self.sites(arena, .callers, name)) |s| {
            if (isTest(s.path)) continue;
            const ws = try map_lines.words(arena, try std.mem.concat(arena, u8, &.{ s.path, " ", s.owner.qname }));
            var overlap: usize = 0;
            for (ws.items.items) |word| {
                if (terms.has(word)) overlap += 1;
            }
            try rows.append(arena, .{ .site = s, .home = std.mem.eql(u8, s.path, home), .overlap = overlap, .order = rows.items.len });
        }
        std.mem.sort(Row, rows.items, {}, Row.less);
        for (rows.items[0..@min(rows.items.len, max_used)]) |row| {
            const s = row.site;
            try w.print("{s}:{d}  in {s}: {s}\n", .{ s.path, s.line, s.owner.qname, try self.lineText(arena, s.path, s.line) });
        }
    }

    fn lineText(self: *Session, arena: Allocator, path: []const u8, line: u32) ![]const u8 {
        const abs = try std.fs.path.join(arena, &.{ self.root, path });
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, abs, arena, .limited(16 * 1024 * 1024)) catch return "";
        var it = std.mem.splitScalar(u8, bytes, '\n');
        var n: u32 = 1;
        while (it.next()) |text| : (n += 1) {
            if (n != line) continue;
            const trimmed = std.mem.trim(u8, text, " \t\r");
            return trimmed[0..cutUtf8(trimmed, max_line_text)];
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

pub const slice_budget: usize = 9_500;
pub const max_slice_ranked: usize = 8;
pub const max_slice_depth: usize = 6;
pub const max_slice_lines: usize = 30;
pub const max_slice_line_chars: usize = 200;

const Chosen = struct {
    file: u32,
    def: u32,
    path: []const u8,
    qname: []const u8,
};

fn appendChosen(arena: Allocator, chosen: *std.ArrayList(Chosen), c: Chosen) !bool {
    for (chosen.items) |x| {
        if (x.file == c.file and x.def == c.def) return false;
    }
    try chosen.append(arena, c);
    return true;
}

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

fn writeLine(w: *Writer, ft: FileText, n: u32) !void {
    const text = std.mem.trimEnd(u8, ft.line(n), " \t");
    const shown = text[0..cutUtf8(text, max_slice_line_chars)];
    try w.print("{d:>6}  {s}\n", .{ n, shown });
}

pub fn isMetadata(t: []const u8) bool {
    return std.mem.indexOf(u8, t, "etadata") != null or std.mem.indexOf(u8, t, "Reflect.") != null or std.mem.indexOf(u8, t, "reflector.") != null;
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

pub fn isAssignment(t: []const u8) bool {
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
        return true;
    }
    return false;
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

pub fn isDecisionLine(t: []const u8) bool {
    if (isCondition(t) or isReturn(t)) return true;
    for ([_][]const u8{ ".sort(", "===", "!==", " < ", " > ", " <= ", " >= " }) |marker| {
        if (std.mem.indexOf(u8, t, marker) != null) return true;
    }
    return false;
}

fn codeOfLine(raw: []const u8) ?[]const u8 {
    const t = std.mem.trimStart(u8, raw, " ");
    var i: usize = 0;
    while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
    if (i == 0 or i + 2 > t.len or t[i] != ' ' or t[i + 1] != ' ') return null;
    return std.mem.trim(u8, t[i + 2 ..], " \t\r");
}

pub fn readFields(arena: Allocator, reply: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, reply, '\n');
    while (it.next()) |raw| {
        const t = codeOfLine(raw) orelse continue;
        if (!isDecisionLine(t)) continue;
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

fn appendSeed(arena: Allocator, seeds: *std.ArrayList(map_usage.Seed), seed: map_usage.Seed) !void {
    for (seeds.items) |s| {
        if (s.file == seed.file and s.def == seed.def) return;
    }
    try seeds.append(arena, seed);
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

fn lineCut(text: []const u8, limit: usize) usize {
    if (text.len <= limit) return text.len;
    return std.mem.lastIndexOfScalar(u8, text[0..limit], '\n') orelse 0;
}

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

pub fn shownTargets(arena: Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var at: usize = 0;
    const marker = "[target ";
    while (std.mem.indexOfPos(u8, text, at, marker)) |start| {
        const name_start = start + marker.len;
        const space = std.mem.indexOfScalarPos(u8, text, name_start, ' ') orelse break;
        const close = std.mem.indexOfScalarPos(u8, text, space, ']') orelse break;
        at = close + 1;
        const hash = text[space + 1 .. close];
        if (hash.len == 0 or !allHex(hash)) continue;
        const name = text[name_start..space];
        if (name.len == 0 or std.mem.indexOfAny(u8, name, " \t\n") != null) continue;
        try out.append(arena, name);
    }
    return out.items;
}

fn allHex(text: []const u8) bool {
    for (text) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

const testing = std.testing;

test "map tools: shown targets come out of the explore text in order and a malformed tag is skipped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const text = "12  if (x) {  [target Injector.loadPerContext 0a1b2c3d]\n40  [target isTreeStatic 99ff00aa]\n[target broken zz]\n";
    const shown = try shownTargets(arena_state.allocator(), text);
    try testing.expectEqual(@as(usize, 2), shown.len);
    try testing.expectEqualStrings("Injector.loadPerContext", shown[0]);
    try testing.expectEqualStrings("isTreeStatic", shown[1]);
}

test "map tools: test paths are recognized by folder and by the spec infix" {
    try testing.expect(isTest("packages/core/test/injector.spec.ts"));
    try testing.expect(isTest("src/__tests__/a.ts"));
    try testing.expect(isTest("src/a.spec.ts"));
    try testing.expect(!isTest("packages/core/injector/injector.ts"));
}
