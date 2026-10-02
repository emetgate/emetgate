const std = @import("std");
const facts = @import("facts.zig");
const facts_store = @import("facts_store.zig");
const symbol = @import("symbol.zig");
const answer = @import("answer.zig");
const evidence = @import("evidence.zig");
const map = @import("map.zig");
const rank = @import("map_region_rank.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Store = facts_store.Store;
const FileState = facts_store.FileState;
const none = facts.none;

pub const default_budget: usize = 12_000;
pub const min_budget: usize = 2_000;
pub const max_regions: usize = 3;
pub const min_term_len: usize = 3;
pub const max_doc_chars: usize = 100;
const reserve: usize = 360;

pub const Level = enum { names, files, dirs };

pub const Options = struct {
    k: u32 = 3,
    list: u32 = 8,
    budget: usize = default_budget,
    code_percent: u32 = 70,
    intent: evidence.Intent = .decides,
    index: ?*rank.Index = null,
    include: evidence.Include = .{ .callers = false, .callees = false, .tests = false },
    params: rank.Params = .{},
};

pub const Shown = struct {
    region: map.RegionId,
    rank: u32,
    qname: []const u8,
    path: []const u8,
};

pub const Exploration = struct {
    regions: []const map.RegionId,
    rankings: []const rank.Ranking,
    shown: []const Shown,
    level: Level,
    files: u32,
    text: []const u8,
};

pub const ExploreAnswer = answer.Answer(Exploration);

fn shortHash(hash: facts.Hash) [8]u8 {
    const hex = symbol.formatHash(hash);
    return hex[0..8].*;
}

fn relative(region: *const map.Region, path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, region.dir)) return path[region.dir.len..];
    return path;
}

fn dirOf(rel: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, rel, '/') orelse return "";
    return rel[0 .. slash + 1];
}

fn listedName(defs: []const facts.Def, di: usize) bool {
    const d = defs[di];
    if (d.name.len == 0) return false;
    switch (d.kind) {
        .module, .constructor, .field, .enum_member => return false,
        else => {},
    }
    if (d.parent == 0) return true;
    if (d.parent == none or d.parent >= defs.len) return false;
    const p = defs[d.parent];
    return p.parent == 0 and (p.kind == .class or p.kind == .interface or p.kind == .enumeration);
}

fn writeNames(w: *Writer, state: *const FileState) !void {
    const defs = state.facts.defs;
    var first = true;
    for (defs, 0..) |d, di| {
        if (d.parent != 0 or !listedName(defs, di)) continue;
        try w.writeAll(if (first) ": " else ", ");
        first = false;
        try w.writeAll(d.name);
        if (d.kind != .class and d.kind != .interface and d.kind != .enumeration) continue;
        var open = false;
        for (defs, 0..) |member, mi| {
            if (member.parent != di or !listedName(defs, mi)) continue;
            try w.writeAll(if (open) ", " else "{");
            open = true;
            try w.writeAll(member.name);
        }
        if (open) try w.writeByte('}');
    }
}

fn writeFile(w: *Writer, region: *const map.Region, f: rank.RegionFile) !void {
    try w.writeAll(relative(region, f.path));
    if (f.state.status == .indexed) try writeNames(w, f.state) else try w.print(" ({t})", .{f.state.status});
    try w.writeByte('\n');
}

const Listed = struct {
    text: []const u8,
    level: Level,
    cut: []const bool,
};

fn levelNote(level: Level) []const u8 {
    return switch (level) {
        .names => "every file with its top level names",
        .files => "names for files with ranked functions, file names for the rest",
        .dirs => "names for files with ranked functions, file counts for the rest",
    };
}

fn listing(arena: Allocator, region: *const map.Region, files: []const rank.RegionFile, hot: []const bool, level: Level, limit: usize) !?Listed {
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    var i: usize = 0;
    while (i < files.len) {
        const dir = dirOf(relative(region, files[i].path));
        var j = i;
        while (j < files.len and std.mem.eql(u8, dirOf(relative(region, files[j].path)), dir)) j += 1;
        var rest: u32 = 0;
        for (files[i..j], hot[i..j]) |f, is_hot| {
            if (level == .names or is_hot) try writeFile(w, region, f) else rest += 1;
        }
        if (rest != 0 and level == .files) {
            try w.writeAll(if (dir.len == 0) "./" else dir);
            var first = true;
            for (files[i..j], hot[i..j]) |f, is_hot| {
                if (is_hot) continue;
                try w.writeAll(if (first) " " else ", ");
                first = false;
                try w.writeAll(relative(region, f.path)[dir.len..]);
            }
            try w.writeByte('\n');
        } else if (rest != 0) {
            try w.print("{s} ({d} more files)\n", .{ if (dir.len == 0) "./" else dir, rest });
        }
        if (out.written().len > limit) return null;
        i = j;
    }
    const cut = try arena.alloc(bool, files.len);
    @memset(cut, false);
    return .{ .text = out.written(), .level = level, .cut = cut };
}

fn truncated(arena: Allocator, region: *const map.Region, files: []const rank.RegionFile, hot: []const bool, limit: usize) !Listed {
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    const cut = try arena.alloc(bool, files.len);
    @memset(cut, false);
    var i: usize = 0;
    var cut_dirs: usize = 0;
    var cut_files: usize = 0;
    while (i < files.len) {
        const dir = dirOf(relative(region, files[i].path));
        var j = i;
        while (j < files.len and std.mem.eql(u8, dirOf(relative(region, files[j].path)), dir)) j += 1;
        var chunk: Writer.Allocating = .init(arena);
        var rest: u32 = 0;
        for (files[i..j], hot[i..j]) |f, is_hot| {
            if (is_hot) try writeFile(&chunk.writer, region, f) else rest += 1;
        }
        if (rest != 0) try chunk.writer.print("{s} ({d} more files)\n", .{ if (dir.len == 0) "./" else dir, rest });
        if (out.written().len + chunk.written().len + 160 > limit) {
            cut_dirs += 1;
            cut_files += j - i;
            for (cut[i..j]) |*c| c.* = true;
        } else try w.writeAll(chunk.written());
        i = j;
    }
    if (cut_files != 0) try w.print("... {d} more directories with {d} files not listed (explore budget); emetgate_region r{d} lists every symbol\n", .{ cut_dirs, cut_files, region.id + 1 });
    return .{ .text = out.written(), .level = .dirs, .cut = cut };
}

fn clipped(text: []const u8, limit: usize) []const u8 {
    if (text.len <= limit) return text;
    var end = limit;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

fn writeList(w: *Writer, store: *const Store, m: *const map.Map, region_id: map.RegionId, ranking: rank.Ranking, list: u32, shown: []const Shown) !void {
    const region = &m.regions[region_id];
    const count = @min(list, ranking.hits.len);
    try w.print("r{d} {s}: {d} functions in {d} files, {d} match the terms; top {d}:\n", .{ region_id + 1, region.path, ranking.candidates, ranking.files, ranking.matched, count });
    for (ranking.hits[0..count], 0..) |hit, i| {
        try w.print("{d:>3} {s}  {s}:{d}", .{ i + 1, hit.qname, relative(region, hit.path), hit.line });
        const doc = store.file(hit.file).facts.defs[hit.def].doc;
        if (doc.len != 0) try w.print(" - {s}", .{clipped(doc, max_doc_chars)});
        for (shown) |s| {
            if (s.region == region_id and s.rank == i) {
                try w.writeAll(" *");
                break;
            }
        }
        try w.writeByte('\n');
    }
}

const Target = struct {
    slot: usize,
    rank: u32,
    hit: rank.Hit,
};

fn inside(a: rank.Hit, b: rank.Hit) bool {
    return a.file == b.file and a.span.start >= b.span.start and a.span.end <= b.span.end;
}

fn evidenceTerms(arena: Allocator, terms: *const rank.Terms) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (terms.concepts) |c| {
        for (c.alternatives) |alt| {
            if (alt.len < min_term_len) continue;
            for (out.items) |kept| {
                if (std.mem.eql(u8, kept, alt)) break;
            } else try out.append(arena, alt);
        }
    }
    return out.items;
}

fn codeLines(text: []const u8) []const u8 {
    const first_nl = std.mem.indexOfScalar(u8, text, '\n') orelse return "";
    var body = text[first_nl + 1 ..];
    const last_nl = std.mem.lastIndexOfScalar(u8, body, '\n') orelse return "";
    body = body[0 .. last_nl + 1];
    while (body.len != 0) {
        const start = if (std.mem.lastIndexOfScalar(u8, body[0 .. body.len - 1], '\n')) |nl| nl + 1 else 0;
        const line = body[start .. body.len - 1];
        if (!std.mem.startsWith(u8, line, "Partial because:") and !std.mem.startsWith(u8, line, "Excluded by rule:")) break;
        body = body[0..start];
    }
    return body;
}

pub fn explore(fs: *const evidence.FactStore, m: *const map.Map, wanted: []const map.RegionId, terms: *const rank.Terms, options: Options) !ExploreAnswer {
    const arena = fs.arena;
    const store = fs.store;
    if (wanted.len == 0) return ExploreAnswer.refuse(error.NoRegion, "name one to three regions of the map");
    var region_ids: std.ArrayList(map.RegionId) = .empty;
    for (wanted) |r| {
        if (r >= m.regions.len) return ExploreAnswer.refuse(error.UnknownRegion, try std.fmt.allocPrint(arena, "no region r{d}; the map has r1 to r{d}", .{ r + 1, m.regions.len }));
        if (std.mem.indexOfScalar(map.RegionId, region_ids.items, r) == null) try region_ids.append(arena, r);
    }
    if (region_ids.items.len > max_regions) return ExploreAnswer.refuse(error.TooManyRegions, "explore takes at most three regions");
    const budget = @max(options.budget, min_budget);
    const regions = region_ids.items;

    const rankings = try arena.alloc(rank.Ranking, regions.len);
    const files_of = try arena.alloc([]const rank.RegionFile, regions.len);
    for (regions, rankings, files_of) |r, *ranking, *files| {
        files.* = try rank.regionFiles(arena, store, m, &m.regions[r]);
        ranking.* = try rank.rankFiles(arena, files.*, &m.regions[r], terms, options.params, options.index);
    }

    var targets: std.ArrayList(Target) = .empty;
    var depth: u32 = 0;
    var steps: u32 = 0;
    const scan = options.k * 4 + 8;
    const taken = try arena.alloc(u32, regions.len);
    @memset(taken, 0);
    while (steps < scan) : (steps += 1) {
        var any = false;
        for (rankings, 0..) |ranking, slot| {
            if (taken[slot] >= options.k or depth >= ranking.hits.len) continue;
            any = true;
            const hit = ranking.hits[depth];
            const nested = for (targets.items) |t| {
                if (inside(hit, t.hit) or inside(t.hit, hit)) break true;
            } else false;
            if (nested) continue;
            try targets.append(arena, .{ .slot = slot, .rank = depth, .hit = hit });
            taken[slot] += 1;
        }
        if (!any) break;
        depth += 1;
    }

    var head: Writer.Allocating = .init(arena);
    const hw = &head.writer;
    try hw.writeAll("explore ");
    for (regions, 0..) |r, i| try hw.print("{s}r{d}", .{ if (i == 0) "" else ", ", r + 1 });
    try hw.writeAll(": functions of each region ranked by the question terms");
    for (terms.concepts, 0..) |c, ci| {
        try hw.writeAll(if (ci == 0) " (" else ", ");
        for (c.alternatives, 0..) |alt, ai| try hw.print("{s}{s}", .{ if (ai == 0) "" else "|", alt });
    }
    if (terms.concepts.len != 0) try hw.writeByte(')');
    try hw.writeAll("; * = code below, where each file is named once and its lines follow as line  code, every elided range is declared and the last line is the certificate\n");

    var lists_len: usize = 0;
    for (regions, rankings) |r, ranking| {
        var probe: Writer.Allocating = .init(arena);
        try writeList(&probe.writer, store, m, r, ranking, options.list, &.{});
        lists_len += probe.written().len;
    }
    const total = budget -| reserve;
    const fixed = head.written().len + lists_len + 2 * targets.items.len;
    const code_budget = (total -| fixed) * options.code_percent / 100;

    var shown: std.ArrayList(Shown) = .empty;
    var code_text: []const u8 = "";
    var code_note: []const u8 = "";
    var evidence_missing: []const answer.Missing = &.{};
    var elided_paths: std.StringArrayHashMapUnmanaged(void) = .empty;
    if (targets.items.len != 0 and code_budget >= evidence.min_budget) {
        const refs = try arena.alloc(evidence.SymbolRef, targets.items.len);
        for (targets.items, refs) |t, *ref| ref.* = .{ .path = t.hit.path, .qname = t.hit.qname };
        const proof = evidence.evidence(fs, .{ .targets = refs, .intent = options.intent, .terms = try evidenceTerms(arena, terms), .include = options.include }, code_budget);
        switch (proof) {
            .refused => |r| code_note = try std.fmt.allocPrint(arena, "code not shown: {s} ({s})\n", .{ @errorName(r.code), r.detail }),
            .complete, .partial => {
                const block = switch (proof) {
                    .complete => |c| c.value,
                    .partial => |p| p.value,
                    .refused => unreachable,
                };
                code_text = codeLines(block.text);
                evidence_missing = proof.missingList();
                for (block.elided) |el| try elided_paths.put(arena, el.path, {});
                for (targets.items) |t| {
                    const hash = shortHash(store.file(t.hit.file).facts.defs[t.hit.def].hash);
                    const tag = try std.fmt.allocPrint(arena, "[target {s} {s}]", .{ t.hit.qname, &hash });
                    if (std.mem.indexOf(u8, code_text, tag) == null) {
                        try elided_paths.put(arena, t.hit.path, {});
                        continue;
                    }
                    try shown.append(arena, .{ .region = regions[t.slot], .rank = t.rank, .qname = t.hit.qname, .path = t.hit.path });
                }
            },
        }
    } else if (targets.items.len != 0) {
        code_note = try std.fmt.allocPrint(arena, "code not shown: {d} characters left of the explore budget {d}; emetgate_evidence reads the ranked functions\n", .{ code_budget, budget });
        for (targets.items) |t| try elided_paths.put(arena, t.hit.path, {});
    }

    const listing_budget = total -| (fixed + code_text.len + code_note.len);
    var level: Level = .names;
    var listings: std.ArrayList([]const u8) = .empty;
    const cut_of = try arena.alloc([]const bool, regions.len);
    for (regions, rankings, files_of, cut_of) |r, ranking, files, *cut| {
        const region = &m.regions[r];
        const hot = try arena.alloc(bool, files.len);
        @memset(hot, false);
        for (ranking.hits[0..@min(options.list, ranking.hits.len)]) |hit| {
            for (files, hot) |f, *h| {
                if (f.id == hit.file) h.* = true;
            }
        }
        const share = (listing_budget / regions.len) -| (region.path.len + 120);
        var chosen: ?Listed = null;
        for ([_]Level{ .names, .files, .dirs }) |lv| {
            chosen = try listing(arena, region, files, hot, lv, share);
            if (chosen != null) break;
        }
        const done = chosen orelse try truncated(arena, region, files, hot, share);
        if (@intFromEnum(done.level) > @intFromEnum(level)) level = done.level;
        cut.* = done.cut;
        try listings.append(arena, try std.fmt.allocPrint(arena, "listing r{d} {s} ({d} files; {s}):\n{s}", .{ r + 1, region.path, files.len, levelNote(done.level), done.text }));
    }

    var missing: std.ArrayList(answer.Missing) = .empty;
    var evaluated: u32 = 0;
    var budget_files: u32 = 0;
    var too_large = false;
    var listed_scope: u32 = 0;
    for (files_of, cut_of) |files, cut| {
        listed_scope += @intCast(files.len);
        for (files, cut) |f, was_cut| {
            switch (f.state.status) {
                .indexed => {
                    const unread: ?answer.Reason = for (evidence_missing) |em| {
                        if (em.path) |p| {
                            if (em.reason.fileLevel() and em.reason != .budget and std.mem.eql(u8, p, f.path)) break em.reason;
                        }
                    } else null;
                    if (f.state.facts.parse_errors) {
                        try missing.append(arena, .{ .path = f.path, .reason = .unclassified });
                    } else if (unread) |reason| {
                        if (reason == .too_large) too_large = true;
                        try missing.append(arena, .{ .path = f.path, .reason = reason });
                    } else if (was_cut or elided_paths.contains(f.path)) {
                        budget_files += 1;
                    } else evaluated += 1;
                },
                .unindexed => try missing.append(arena, .{ .path = f.path, .reason = .unclassified }),
                .unreadable => try missing.append(arena, .{ .path = f.path, .reason = .unreadable }),
                .too_large => {
                    too_large = true;
                    try missing.append(arena, .{ .path = f.path, .reason = .too_large });
                },
                .removed => try missing.append(arena, .{ .path = f.path, .reason = .vanished }),
            }
        }
    }
    var budgets: std.ArrayList(answer.Budget) = .empty;
    if (too_large) try budgets.append(arena, .{ .limit = .file_bytes, .max = fs.max_file_bytes, .used = @min(fs.largest_file_bytes, fs.max_file_bytes) });
    if (budget_files != 0) {
        try missing.append(arena, .{ .path = null, .reason = .budget, .files = budget_files });
        try budgets.append(arena, .{ .limit = .steps, .max = budget, .used = budget });
    }
    const cert: answer.Certificate = .{
        .snapshot = fs.snapshot,
        .scope = .{ .prefix = if (regions.len == 1) m.regions[regions[0]].dir else "", .listed = listed_scope, .evaluated = evaluated },
        .semantics = .listing,
        .budgets = budgets.items,
    };
    const value: Exploration = .{ .regions = regions, .rankings = rankings, .shown = shown.items, .level = level, .files = listed_scope, .text = "" };
    var result = ExploreAnswer.finish(value, cert, missing.items);

    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll(head.written());
    for (regions, rankings) |r, ranking| try writeList(w, store, m, r, ranking, options.list, shown.items);
    try w.writeAll(code_text);
    try w.writeAll(code_note);
    for (listings.items) |text| try w.writeAll(text);
    try result.writeStatus(w, shown.items.len, "functions shown");
    try w.writeByte('\n');
    switch (result) {
        .complete => |*c| c.value.text = out.written(),
        .partial => |*p| p.value.text = out.written(),
        .refused => {},
    }
    return result;
}
