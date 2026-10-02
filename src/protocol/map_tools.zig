const std = @import("std");
const fact_store = @import("../platform/fact_store.zig");
const io_seam = @import("../platform/io_seam.zig");
const map = @import("../engine/map.zig");
const map_explore = @import("../engine/map_explore.zig");
const map_lines = @import("../engine/map_lines.zig");
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
pub const explore_budget: usize = 24_000;
pub const body_budget: usize = 12_000;
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
    "already know them. One reply holds the best-matching functions with code and line numbers, the functions they call, and the " ++
    "lines where they are used, so a second call is rarely needed; call evidence only for a function whose code is still missing.\n" ++
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
        self.index = try rank.Index.build(arena, &repo.store, &self.built.?, self.lex.?);
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
        return self.repo != null and self.built != null and self.index != null and self.lines != null;
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
        const repo = self.repo.?;
        _ = repo.refresh() catch {};
        const names = try namesOf(arena, args);
        var joined: Writer.Allocating = .init(arena);
        try joined.writer.writeAll(question);
        for (names) |n| try joined.writer.print(" {s}", .{n});
        const query = joined.written();
        const terms_words = try map_lines.words(arena, query);
        const regions = try self.lines.?.pick(arena, &terms_words, max_regions);
        var text: []const u8 = "";
        if (regions.len != 0) {
            const terms = try rank.Terms.ofQuestion(arena, self.lex.?, query);
            const fs = try repo.factStore(arena);
            const explored = try map_explore.explore(&fs, &self.built.?, regions, &terms, .{ .k = explore_k, .budget = explore_budget, .index = self.index.? });
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
        const shown = try shownTargets(arena, text);
        var focus: std.ArrayList([]const u8) = .empty;
        for (names) |n| {
            if (focus.items.len >= max_focus_named) break;
            if (self.fileOf(n) != null) try focus.append(arena, n);
        }
        if (focus.items.len == 0) {
            for (shown) |n| {
                if (focus.items.len >= max_focus_shown) break;
                if (self.fileOf(n) != null) try focus.append(arena, n);
            }
        }
        var extra: std.ArrayList([]const u8) = .empty;
        for (names) |n| {
            if (!contains(shown, n) and !contains(extra.items, n)) try extra.append(arena, n);
        }
        for (focus.items) |n| {
            for (try self.sites(arena, .callees, n)) |s| {
                const t = s.target.qname;
                if (t.len == 0) continue;
                const path = self.fileOf(t) orelse continue;
                if (contains(shown, t) or contains(extra.items, t) or isTest(path)) continue;
                try extra.append(arena, t);
            }
        }
        var used: Writer.Allocating = .init(arena);
        for (focus.items) |n| try self.usedLines(arena, &used.writer, n, &terms_words);
        const body = if (extra.items.len != 0) try self.evidenceText(arena, extra.items[0..@min(extra.items.len, max_extra)], body_budget) else "";
        var out: Writer.Allocating = .init(arena);
        try out.writer.writeAll(if (text.len != 0) text else "no part of the repository matched the phrase");
        if (body.len != 0) try out.writer.print("\nFunctions they call and functions you named:\n{s}", .{body});
        if (used.written().len != 0) try out.writer.print("\nWhere the top functions are used:\n{s}", .{std.mem.trimEnd(u8, used.written(), "\n")});
        return plain(gpa, out.written(), false);
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
