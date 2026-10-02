const std = @import("std");
const facts = @import("facts.zig");
const facts_store = @import("facts_store.zig");
const facts_query = @import("facts_query.zig");
const facts_spine = @import("facts_spine.zig");
const facts_outline = @import("facts_outline.zig");
const facts_tests = @import("facts_tests.zig");
const facts_evidence = @import("facts_evidence.zig");
const symbol = @import("symbol.zig");
const answer = @import("answer.zig");
const shared = @import("evidence_request.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Range = facts_spine.Range;
const Subject = facts_query.Subject;
const Site = facts_query.Site;
const Unknown = facts_query.Unknown;

pub const Intent = shared.Intent;
pub const SymbolRef = shared.SymbolRef;
pub const Include = shared.Include;
pub const EvidenceRequest = shared.EvidenceRequest;

pub const default_budget: usize = 9_500;
pub const min_budget: usize = 1_000;
pub const max_line_chars: usize = 400;
pub const clipped_line_chars: usize = 300;
pub const status_reserve: usize = 300;
pub const reason_reserve: usize = 240;
pub const cut_reserve: usize = 120;
pub const max_call_lines: usize = 6;
pub const max_tests_chars: usize = 1_000;
pub const max_title_chars: usize = 200;
pub const max_tests_per_file: usize = 3;
pub const relation_floor_percent: usize = 50;

pub const open_note = "an edge not in this list does not mean there is none";
pub const vanished_note = "(not shown: the file no longer exists)";
pub const changed_note = "(not shown: the file changed after the snapshot)";
pub const large_note = "(not shown: the file is over the size limit)";
pub const unreadable_note = "(not shown: the file cannot be read)";

const target_weight: f64 = 2.0;
const call_weight: f64 = 0.5;

pub const FactStore = struct {
    arena: Allocator,
    store: *const facts_store.Store,
    source: facts_evidence.Source,
    snapshot: answer.Snapshot,
    max_file_bytes: u64,
    largest_file_bytes: u64,
};

pub const Elided = struct {
    path: []const u8,
    first: u32,
    last: u32,
};

pub const TestCertainty = enum { proven, typed, by_name };

pub const TestLine = struct {
    path: []const u8,
    line: u32,
    title: []const u8,
    target: []const u8,
    references: u32,
    certainty: TestCertainty,
};

pub const Sections = struct {
    callers: bool,
    callees: bool,
    tests: bool,
};

pub fn sectionsOf(request: EvidenceRequest) Sections {
    const relations = request.intent != .where_defined;
    return .{
        .callers = request.include.callers orelse relations,
        .callees = request.include.callees orelse relations,
        .tests = request.include.tests orelse relations,
    };
}

pub const EvidenceBlock = struct {
    text: []const u8 = "",
    intent: Intent,
    targets: []const Subject = &.{},
    not_found: []const SymbolRef = &.{},
    sites: []const Site = &.{},
    unresolved: []const Unknown = &.{},
    tests: []const TestLine = &.{},
    elided: []const Elided = &.{},
    cut: usize = 0,
};

pub const EvidenceAnswer = answer.Answer(EvidenceBlock);

pub fn evidence(store: *const FactStore, request: EvidenceRequest, budget: usize) EvidenceAnswer {
    return build(store, request, budget) catch |err| EvidenceAnswer.refuse(err, "the evidence could not be built");
}

const Term = struct {
    text: []const u8,
    joined: ?[]const u8,
};

const Opened = struct {
    file: facts_evidence.File,
    lines: facts_spine.Lines,
};

const Unit = struct {
    ranges: []const Range,
    weight: f64,
    line: u32,
};

const Mode = enum { whole, spine, unavailable, dropped };

const Plan = struct {
    subject: Subject,
    opened: ?Opened = null,
    note: []const u8 = "",
    first: u32 = 0,
    last: u32 = 0,
    whole: usize = 0,
    base: []const Range = &.{},
    units: []const Unit = &.{},
    chosen: []const Range = &.{},
    mode: Mode = .unavailable,
    used: usize = 0,
};

const Section = struct {
    lines: std.ArrayList([]const u8) = .empty,
    used: usize = 0,
    cap: usize,
    path: []const u8 = "",

    fn push(self: *Section, arena: Allocator, text: []const u8) !bool {
        if (self.used + text.len + 1 > self.cap) return false;
        try self.lines.append(arena, text);
        self.used += text.len + 1;
        return true;
    }

    fn pushIn(self: *Section, arena: Allocator, path: []const u8, text: []const u8) !bool {
        if (std.mem.eql(u8, path, self.path)) return self.push(arena, text);
        if (self.used + path.len + 1 + text.len + 1 > self.cap) return false;
        _ = try self.push(arena, path);
        self.path = path;
        return self.push(arena, text);
    }
};

const Clipped = struct {
    text: []const u8,
    more: usize,
};

fn clipCode(raw: []const u8) Clipped {
    const text = std.mem.trimEnd(u8, raw, " \t\r");
    if (text.len <= max_line_chars) return .{ .text = text, .more = 0 };
    var end = clipped_line_chars;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return .{ .text = text[0..end], .more = text.len - end };
}

fn clipTitle(title: []const u8) []const u8 {
    if (title.len <= max_title_chars) return title;
    var end = max_title_chars;
    while (end > 0 and (title[end] & 0xC0) == 0x80) end -= 1;
    return title[0..end];
}

fn containsFold(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

fn termsOf(arena: Allocator, raw: []const []const u8) ![]const Term {
    var out: std.ArrayList(Term) = .empty;
    for (raw) |item| {
        const text = std.mem.trim(u8, item, " \t");
        if (text.len == 0) continue;
        var joined: ?[]const u8 = null;
        if (std.mem.indexOfAny(u8, text, " -_") != null) {
            var buf: std.ArrayList(u8) = .empty;
            for (text) |c| {
                if (c != ' ' and c != '-' and c != '_') try buf.append(arena, c);
            }
            if (buf.items.len != 0) joined = buf.items;
        }
        try out.append(arena, .{ .text = text, .joined = joined });
    }
    return out.items;
}

fn matches(line: []const u8, term: Term) bool {
    if (containsFold(line, term.text)) return true;
    if (term.joined) |joined| return containsFold(line, joined);
    return false;
}

fn shortHash(hash: facts.Hash) [8]u8 {
    const hex = symbol.formatHash(hash);
    return hex[0..8].*;
}

fn ownerName(qname: []const u8) []const u8 {
    return if (qname.len == 0) "<module>" else qname;
}

fn sameDef(a: facts_store.DefId, b: facts_store.DefId) bool {
    return a.file == b.file and a.slot == b.slot;
}

fn unitBefore(_: void, a: Unit, b: Unit) bool {
    if (a.weight != b.weight) return a.weight > b.weight;
    return a.line < b.line;
}

fn listedFiles(store: *const facts_store.Store) u32 {
    var n: u32 = 0;
    for (store.files.items) |state| {
        if (state.status != .removed) n += 1;
    }
    return n;
}

const TestKey = struct {
    file: u32,
    block: u32,
    target: u32,
};

const Caps = struct {
    callers: usize,
    callees: usize,
    tests: usize,
};

fn capsOf(intent: Intent, sections: Sections, budget: usize) Caps {
    const callers: usize = if (!sections.callers) 0 else switch (intent) {
        .callers => budget * 55 / 100,
        .flow => budget * 33 / 100,
        .callees, .decides, .explain, .where_defined => budget * 20 / 100,
    };
    const callees: usize = if (!sections.callees) 0 else switch (intent) {
        .callees => budget * 35 / 100,
        .flow => budget * 22 / 100,
        .callers, .decides, .explain, .where_defined => budget * 15 / 100,
    };
    const tests: usize = if (!sections.tests) 0 else @min(budget * 10 / 100, max_tests_chars);
    return .{ .callers = callers, .callees = callees, .tests = tests };
}

fn fitCaps(caps: Caps, content: usize, need: usize) Caps {
    const relations = caps.callers + caps.callees;
    if (relations == 0) return caps;
    const floor = relations * relation_floor_percent / 100;
    const room = content -| (caps.tests + need);
    const allowed = @max(floor, @min(relations, room));
    if (allowed >= relations) return caps;
    return .{ .callers = caps.callers * allowed / relations, .callees = caps.callees * allowed / relations, .tests = caps.tests };
}

fn importsFile(store: *const facts_store.Store, from: facts_store.FileId, target: facts_store.FileId) bool {
    for (store.file(from).spec_targets) |spec| switch (spec) {
        .file => |f| if (f == target) return true,
        else => {},
    };
    return false;
}

fn certaintyLabel(certainty: TestCertainty) []const u8 {
    return switch (certainty) {
        .proven => "proven",
        .typed => "typed",
        .by_name => "by name only",
    };
}

const TestOrder = struct {
    file_best: TestCertainty,
    line: TestLine,
};

fn testLess(_: void, a: TestOrder, b: TestOrder) bool {
    if (a.file_best != b.file_best) return @intFromEnum(a.file_best) < @intFromEnum(b.file_best);
    const order = std.mem.order(u8, a.line.path, b.line.path);
    if (order != .eq) return order == .lt;
    if (a.line.line != b.line.line) return a.line.line < b.line.line;
    return @intFromEnum(a.line.certainty) < @intFromEnum(b.line.certainty);
}

fn calleeLess(_: void, a: Site, b: Site) bool {
    const order = std.mem.order(u8, a.target.path, b.target.path);
    if (order != .eq) return order == .lt;
    if (a.target.line != b.target.line) return a.target.line < b.target.line;
    return a.start < b.start;
}

fn calleeKey(site: Site) u64 {
    return site.target.id.key() ^ (std.hash.Wyhash.hash(0, site.owner.qname) << 1);
}

fn mergeRanges(arena: Allocator, a: []const Range, b: []const Range) ![]const Range {
    const all = try arena.alloc(Range, a.len + b.len);
    @memcpy(all[0..a.len], a);
    @memcpy(all[a.len..], b);
    return facts_spine.merged(arena, all);
}

fn tagLine(p: *const Plan) u32 {
    return if (p.subject.line >= p.first and p.subject.line <= p.last) p.subject.line else p.first;
}

fn tagLen(p: *const Plan) usize {
    return std.fmt.count("  [target {s} {s}]", .{ p.subject.qname, &shortHash(p.subject.hash) });
}

fn headingLen(p: *const Plan) usize {
    return p.subject.path.len + 1;
}

fn lineLen(p: *const Plan, n: u32) usize {
    const raw = p.opened.?.lines.text(n) orelse "";
    const clipped = clipCode(raw);
    var len = std.fmt.count("{d}  {s}", .{ n, clipped.text }) + 1;
    if (clipped.more != 0) len += std.fmt.count(" ... ({d} more characters on this line)", .{clipped.more});
    if (n == tagLine(p)) len += tagLen(p);
    return len;
}

fn elisionLen(first: u32, last: u32) usize {
    return std.fmt.count("{d}-{d}  ... {d} lines elided", .{ first, last, last - first + 1 }) + 1;
}

fn unavailableLen(p: *const Plan) usize {
    return headingLen(p) + std.fmt.count("{d}  {s}  [target {s} {s}]", .{ p.subject.line, p.note, p.subject.qname, &shortHash(p.subject.hash) }) + 1;
}

fn costOf(p: *const Plan, ranges: []const Range) usize {
    var total: usize = headingLen(p);
    var next = p.first;
    for (ranges) |r| {
        if (r.first > next) total += elisionLen(next, r.first - 1);
        var n = @max(r.first, next);
        while (n <= r.last) : (n += 1) total += lineLen(p, n);
        next = @max(next, r.last + 1);
    }
    if (next <= p.last) total += elisionLen(next, p.last);
    return total;
}

const Builder = struct {
    arena: Allocator,
    fs: *const FactStore,
    request: EvidenceRequest,
    limit: usize,
    terms: []const Term,
    files: std.StringHashMapUnmanaged(?Opened) = .empty,
    sections: Sections,
    subjects: std.ArrayList(Subject) = .empty,
    not_found: std.ArrayList(SymbolRef) = .empty,
    callers: std.ArrayList(Site) = .empty,
    callees: std.ArrayList(Site) = .empty,
    unknown: std.ArrayList(Unknown) = .empty,
    tests: std.ArrayList(TestLine) = .empty,
    test_index: std.AutoHashMapUnmanaged(TestKey, usize) = .empty,
    seen_unknown: std.AutoHashMapUnmanaged(u64, void) = .empty,
    unread: std.StringArrayHashMapUnmanaged(answer.Reason) = .empty,
    excluded: std.StringArrayHashMapUnmanaged(void) = .empty,
    drawn: std.StringArrayHashMapUnmanaged(void) = .empty,
    elided_files: std.StringArrayHashMapUnmanaged(void) = .empty,
    elided: std.ArrayList(Elided) = .empty,
    cut_sites: usize = 0,
    cut_unknown: usize = 0,
    cut_targets: usize = 0,
    cut_tests: usize = 0,
    too_large: bool = false,
    body_path: []const u8 = "",

    fn open(self: *Builder, path: []const u8) !?Opened {
        try self.drawn.put(self.arena, path, {});
        if (self.files.get(path)) |cached| return cached;
        const got = self.fs.source.file(path) catch |err| {
            try self.files.put(self.arena, path, null);
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Changed => try self.unread.put(self.arena, path, .changed_since_snapshot),
                error.Vanished => try self.unread.put(self.arena, path, .vanished),
                error.Unreadable => try self.unread.put(self.arena, path, .unreadable),
                error.TooLarge => try self.excluded.put(self.arena, path, {}),
            }
            return null;
        };
        const opened: Opened = .{ .file = got, .lines = try facts_spine.Lines.of(self.arena, got.bytes) };
        try self.files.put(self.arena, path, opened);
        return opened;
    }

    fn missingNote(self: *const Builder, path: []const u8) []const u8 {
        if (self.excluded.contains(path)) return large_note;
        const reason = self.unread.get(path) orelse return unreadable_note;
        return switch (reason) {
            .vanished => vanished_note,
            .changed_since_snapshot => changed_note,
            else => unreadable_note,
        };
    }

    fn markElided(self: *Builder, path: []const u8, first: u32, last: u32) !void {
        try self.elided.append(self.arena, .{ .path = path, .first = first, .last = last });
        try self.markCut(path);
    }

    fn markCut(self: *Builder, path: []const u8) !void {
        try self.elided_files.put(self.arena, path, {});
        try self.drawn.put(self.arena, path, {});
    }

    fn resolve(self: *Builder) !void {
        var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
        for (self.request.targets) |target| {
            const path: ?[]const u8 = if (target.path.len == 0) null else target.path;
            const found = try facts_query.findSubjects(self.arena, self.fs.store, target.qname, path);
            if (found.len == 0) {
                try self.not_found.append(self.arena, target);
                continue;
            }
            var exact = false;
            for (found) |s| {
                if (std.mem.eql(u8, s.qname, target.qname)) exact = true;
            }
            for (found) |s| {
                if (exact and !std.mem.eql(u8, s.qname, target.qname)) continue;
                const entry = try seen.getOrPut(self.arena, s.id.key());
                if (entry.found_existing) continue;
                try self.subjects.append(self.arena, s);
            }
        }
    }

    fn addUnknown(self: *Builder, u: Unknown) !void {
        var h = std.hash.Wyhash.init(u.start);
        h.update(u.path);
        const entry = try self.seen_unknown.getOrPut(self.arena, h.final());
        if (entry.found_existing) return;
        try self.unknown.append(self.arena, u);
    }

    fn relate(self: *Builder, s: Subject, relation: facts_query.Relation) !void {
        const result = try facts_query.run(self.arena, self.fs.store, .{
            .snapshot = self.fs.snapshot,
            .max_file_bytes = self.fs.max_file_bytes,
            .largest_file_bytes = self.fs.largest_file_bytes,
        }, .{ .relation = relation, .subject = s.qname, .path = s.path });
        const value = switch (result) {
            .complete => |c| c.value,
            .partial => |p| p.value,
            .refused => return error.RelationRefused,
        };
        for (value.unread) |f| {
            const reason: answer.Reason = switch (f.status) {
                .too_large => .too_large,
                .unreadable => .unreadable,
                .unindexed, .indexed => .unclassified,
                .removed => continue,
            };
            if (reason == .too_large) self.too_large = true;
            try self.unread.put(self.arena, f.path, reason);
        }
        for (value.unknown) |u| try self.addUnknown(u);
        for (value.sites) |site| {
            if (site.depth != 1) continue;
            switch (relation) {
                .callers => if (sameDef(site.target.id, s.id)) try self.callers.append(self.arena, site),
                .callees => try self.callees.append(self.arena, site),
                .defined_at, .refs => {},
            }
        }
    }

    fn code(self: *Builder, path: []const u8, line: u32) ![]const u8 {
        const opened = (try self.open(path)) orelse return self.missingNote(path);
        const raw = opened.lines.text(line) orelse return "(no such line)";
        const clipped = clipCode(std.mem.trimStart(u8, raw, " \t"));
        if (clipped.more == 0) return clipped.text;
        try self.markElided(path, line, line);
        return std.fmt.allocPrint(self.arena, "{s} ... ({d} more characters on this line)", .{ clipped.text, clipped.more });
    }

    fn header(self: *Builder) ![]const u8 {
        var w: Writer.Allocating = .init(self.arena);
        try w.writer.print("Evidence ({t}) for", .{self.request.intent});
        for (self.subjects.items, 0..) |s, i| {
            if (w.written().len + s.qname.len + s.path.len + 8 > 260) {
                try w.writer.print(" and {d} more", .{self.subjects.items.len - i});
                break;
            }
            try w.writer.print("{s} {s} ({s})", .{ if (i == 0) "" else ",", s.qname, s.path });
        }
        for (self.terms, 0..) |t, i| {
            if (w.written().len + t.text.len + 10 > 340) break;
            try w.writer.print("{s}{s}", .{ if (i == 0) "; terms: " else ", ", t.text });
        }
        for (self.not_found.items, 0..) |t, i| {
            if (w.written().len + t.path.len + t.qname.len + 16 > 370) {
                try w.writer.print(" and {d} more", .{self.not_found.items.len - i});
                break;
            }
            try w.writer.print("{s}{s}#{s}", .{ if (i == 0) "; not found: " else ", ", t.path, t.qname });
        }
        try w.writer.writeAll(". Each file is named once and its lines follow as line  code; every elided range is declared; the last line is the certificate.");
        return w.written();
    }

    fn cutSites(self: *Builder, rest: []const Site) !void {
        self.cut_sites += rest.len;
        for (rest) |site| try self.markCut(site.path);
    }

    fn callerLines(self: *Builder, sec: *Section) !void {
        const sites = self.callers.items;
        var i: usize = 0;
        while (i < sites.len) {
            const site = sites[i];
            var j = i + 1;
            while (j < sites.len and std.mem.eql(u8, sites[j].path, site.path) and std.mem.eql(u8, sites[j].owner.qname, site.owner.qname) and sites[j].owner.line == site.owner.line and sameDef(sites[j].target.id, site.target.id)) j += 1;
            if (site.owner.qname.len != 0) {
                const signature = try std.fmt.allocPrint(self.arena, "{d}  {s}  [caller of {s}: {s} {s}]", .{ site.owner.line, try self.code(site.path, site.owner.line), site.target.qname, site.owner.qname, &shortHash(site.owner.hash) });
                if (!try sec.pushIn(self.arena, site.path, signature)) return self.cutSites(sites[i..]);
            }
            for (sites[i..j], i..) |call, k| {
                const text = try std.fmt.allocPrint(self.arena, "{d}  {s}  [{t} {t}{s}]", .{ call.line, try self.code(call.path, call.line), call.kind, call.certainty, if (call.owner.qname.len == 0) " at module level" else "" });
                if (!try sec.pushIn(self.arena, call.path, text)) return self.cutSites(sites[k..]);
            }
            i = j;
        }
    }

    fn calleeLines(self: *Builder, sec: *Section) !void {
        const sites = try self.arena.dupe(Site, self.callees.items);
        std.mem.sort(Site, sites, {}, calleeLess);
        var done: std.AutoHashMapUnmanaged(u64, void) = .empty;
        for (sites, 0..) |site, i| {
            const key = calleeKey(site);
            if (done.contains(key)) continue;
            var calls: Writer.Allocating = .init(self.arena);
            var count: usize = 0;
            for (sites[i..]) |other| {
                if (calleeKey(other) != key) continue;
                if (count < max_call_lines) try calls.writer.print("{s}{d}", .{ if (count == 0) "" else ", ", other.line });
                count += 1;
            }
            if (count > max_call_lines) try calls.writer.print(" and {d} more", .{count - max_call_lines});
            const text = try std.fmt.allocPrint(self.arena, "{d}  {s}  [callee of {s}: {s} {s}, called at {s} {s}, {t}]", .{ site.target.line, try self.code(site.target.path, site.target.line), ownerName(site.owner.qname), site.target.qname, &shortHash(site.target.hash), if (count == 1) "line" else "lines", calls.written(), site.certainty });
            if (!try sec.pushIn(self.arena, site.target.path, text)) {
                for (sites[i..]) |other| {
                    if (done.contains(calleeKey(other))) continue;
                    self.cut_sites += 1;
                    try self.markCut(other.path);
                }
                return;
            }
            try done.put(self.arena, key, {});
        }
    }

    fn unknownLines(self: *Builder, sec: *Section) !void {
        for (self.unknown.items, 0..) |u, i| {
            const text = try std.fmt.allocPrint(self.arena, "{d}  {s}  [unresolved {t} in {s}]", .{ u.line, try self.code(u.path, u.line), u.reason, ownerName(u.owner.qname) });
            if (!try sec.pushIn(self.arena, u.path, text)) {
                self.cut_unknown += self.unknown.items.len - i;
                for (self.unknown.items[i..]) |rest| try self.markCut(rest.path);
                return;
            }
        }
    }

    fn addTestHit(self: *Builder, file: facts_store.FileId, start: u32, line: u32, target: usize, certainty: TestCertainty) !void {
        const state = self.fs.store.file(file);
        const profile = state.profile orelse return;
        const table = profile.facts orelse return;
        if (!facts_tests.isTestPath(table, state.path)) return;
        const block = facts_tests.innermost(state.facts.tests, start);
        const entry = try self.test_index.getOrPut(self.arena, .{ .file = file, .block = block orelse facts.none, .target = @intCast(target) });
        if (entry.found_existing) {
            const kept = &self.tests.items[entry.value_ptr.*];
            kept.references += 1;
            if (@intFromEnum(certainty) < @intFromEnum(kept.certainty)) kept.certainty = certainty;
            return;
        }
        entry.value_ptr.* = self.tests.items.len;
        const title: []const u8 = if (block) |b| try facts_tests.titleChain(self.arena, state.facts.tests, b) else "";
        try self.tests.append(self.arena, .{
            .path = state.path,
            .line = if (block) |b| state.facts.tests[b].line else line,
            .title = clipTitle(title),
            .target = self.subjects.items[target].qname,
            .references = 1,
            .certainty = certainty,
        });
    }

    fn collectTests(self: *Builder) !void {
        const store = self.fs.store;
        for (self.subjects.items, 0..) |s, target| {
            if (store.incoming.get(s.id.key())) |list| {
                for (list.items) |key| {
                    const found = store.refAt(key) orelse continue;
                    const link = switch (found.link) {
                        .def => |d| d,
                        .unresolved => continue,
                    };
                    if (!sameDef(link.id, s.id)) continue;
                    if (found.ref.kind == .import or found.ref.kind == .type) continue;
                    try self.addTestHit(key.file, found.ref.start, found.ref.line, target, if (link.certainty == .proven) .proven else .typed);
                }
            }
            if (store.unresolved_by_name.get(facts_query.simpleName(s.qname))) |list| {
                for (list.items) |key| {
                    const found = store.refAt(key) orelse continue;
                    const reason = switch (found.link) {
                        .unresolved => |why| why,
                        .def => continue,
                    };
                    if (!found.ref.kind.invokes() or !facts_query.bindable(reason)) continue;
                    if (!importsFile(store, key.file, s.id.file)) continue;
                    try self.addTestHit(key.file, found.ref.start, found.ref.line, target, .by_name);
                }
            }
        }
        var best: std.StringHashMapUnmanaged(TestCertainty) = .empty;
        for (self.tests.items) |t| {
            const entry = try best.getOrPut(self.arena, t.path);
            if (!entry.found_existing or @intFromEnum(t.certainty) < @intFromEnum(entry.value_ptr.*)) entry.value_ptr.* = t.certainty;
        }
        const keys = try self.arena.alloc(TestOrder, self.tests.items.len);
        for (self.tests.items, keys) |t, *k| k.* = .{ .file_best = best.get(t.path).?, .line = t };
        std.mem.sort(TestOrder, keys, {}, testLess);
        for (keys, self.tests.items) |k, *t| t.* = k.line;
    }

    fn testLines(self: *Builder, sec: *Section) !void {
        const tests = self.tests.items;
        var i: usize = 0;
        while (i < tests.len) {
            var end = i + 1;
            while (end < tests.len and std.mem.eql(u8, tests[end].path, tests[i].path)) end += 1;
            const shown = @min(end - i, max_tests_per_file);
            for (tests[i .. i + shown], i..) |t, k| {
                const title = if (t.title.len == 0) "(outside a test block)" else t.title;
                const text = try std.fmt.allocPrint(self.arena, "{d}  {s}  [test of {s}: {d} {s}, {s}]", .{ t.line, title, t.target, t.references, if (t.references == 1) "reference" else "references", certaintyLabel(t.certainty) });
                if (!try sec.pushIn(self.arena, t.path, text)) return self.cutTests(k);
            }
            if (end - i > shown) {
                const more = try std.fmt.allocPrint(self.arena, "...  {d} more tests in this file", .{end - i - shown});
                if (!try sec.pushIn(self.arena, tests[i].path, more)) return self.cutTests(i + shown);
            }
            i = end;
        }
    }

    fn cutTests(self: *Builder, from: usize) !void {
        self.cut_tests += self.tests.items.len - from;
        for (self.tests.items[from..]) |rest| try self.markCut(rest.path);
    }

    fn plan(self: *Builder, s: Subject) !Plan {
        var p: Plan = .{ .subject = s };
        const opened = (try self.open(s.path)) orelse {
            p.note = self.missingNote(s.path);
            return p;
        };
        p.opened = opened;
        p.first = opened.lines.lineAt(s.span.start);
        p.last = opened.lines.lineAt(if (s.span.end > s.span.start) s.span.end - 1 else s.span.start);
        p.whole = costOf(&p, &.{.{ .first = p.first, .last = p.last }});
        p.mode = .whole;
        return p;
    }

    fn relevantRefs(self: *Builder, p: *const Plan, weights: *std.AutoArrayHashMapUnmanaged(u32, f64)) !void {
        const state = self.fs.store.file(p.subject.id.file);
        const calls = self.request.intent == .callees or self.request.intent == .flow;
        for (state.facts.refs, state.links) |r, link| {
            if (r.start < p.subject.span.start or r.start >= p.subject.span.end) continue;
            var weight: f64 = 0;
            switch (link) {
                .def => |d| for (self.subjects.items) |other| {
                    if (!sameDef(other.id, p.subject.id) and sameDef(other.id, d.id)) weight = target_weight;
                },
                .unresolved => {},
            }
            if (weight == 0 and calls and r.kind.invokes()) weight = call_weight;
            if (weight == 0) continue;
            const entry = try weights.getOrPut(self.arena, r.line);
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* = @max(entry.value_ptr.*, weight);
        }
    }

    fn termWeights(self: *Builder, p: *const Plan, weights: *std.AutoArrayHashMapUnmanaged(u32, f64)) !void {
        if (self.terms.len == 0) return;
        const lines = p.opened.?.lines;
        const counts = try self.arena.alloc(usize, self.terms.len);
        @memset(counts, 0);
        var n = p.first;
        while (n <= p.last) : (n += 1) {
            const text = lines.text(n) orelse continue;
            for (self.terms, 0..) |t, k| {
                if (matches(text, t)) counts[k] += 1;
            }
        }
        n = p.first;
        while (n <= p.last) : (n += 1) {
            const text = lines.text(n) orelse continue;
            var weight: f64 = 0;
            for (self.terms, 0..) |t, k| {
                if (matches(text, t)) weight += 1.0 / @as(f64, @floatFromInt(counts[k]));
            }
            if (weight != 0) try weights.put(self.arena, n, weight);
        }
    }

    fn prepareSpine(self: *Builder, p: *Plan) !void {
        const lines = p.opened.?.lines;
        const def = self.fs.store.defOf(p.subject.id) orelse return error.SubjectNotFound;
        const outline = self.fs.store.file(p.subject.id.file).facts.outline;
        const frame = facts_outline.frameOf(lines, def.*);
        var base: std.ArrayList(Range) = .empty;
        try base.append(self.arena, .{ .first = frame.first, .last = @max(frame.first, frame.signature_last) });
        try base.append(self.arena, .{ .first = frame.last, .last = frame.last });
        const tag = tagLine(p);
        try base.append(self.arena, .{ .first = tag, .last = tag });
        p.base = try facts_spine.merged(self.arena, base.items);

        var weights: std.AutoArrayHashMapUnmanaged(u32, f64) = .empty;
        try self.termWeights(p, &weights);
        try self.relevantRefs(p, &weights);
        const branches = self.request.intent == .decides;
        var units: std.ArrayList(Unit) = .empty;
        for (weights.keys(), weights.values()) |line, weight| {
            const ranges = try facts_outline.unit(self.arena, outline, frame, lines, line, branches);
            if (ranges.len == 0) continue;
            try units.append(self.arena, .{ .ranges = ranges, .weight = weight, .line = line });
        }
        std.mem.sort(Unit, units.items, {}, unitBefore);
        p.units = units.items;
    }

    fn select(self: *Builder, p: *Plan, room: usize) !void {
        var chosen: []const Range = p.base;
        var cost = costOf(p, chosen);
        if (cost > room) {
            p.chosen = &.{};
            p.used = costOf(p, &.{});
            if (p.used > room) {
                p.mode = .dropped;
                p.used = 0;
            }
            return;
        }
        for (p.units) |u| {
            const candidate = try mergeRanges(self.arena, chosen, u.ranges);
            const c = costOf(p, candidate);
            if (c <= room) {
                chosen = candidate;
                cost = c;
            }
        }
        p.chosen = chosen;
        p.used = cost;
    }

    fn allocate(self: *Builder, plans: []Plan, budget: usize) !void {
        var remaining = budget;
        for (plans, 0..) |*p, i| {
            const share = remaining / (plans.len - i);
            switch (p.mode) {
                .unavailable => p.used = unavailableLen(p),
                .whole => if (p.whole > share) {
                    try self.prepareSpine(p);
                    p.mode = .spine;
                    try self.select(p, share);
                } else {
                    p.used = p.whole;
                },
                .spine, .dropped => unreachable,
            }
            remaining -|= p.used;
        }
        for (plans) |*p| {
            if (p.mode != .spine and p.mode != .dropped) continue;
            if (p.whole - p.used <= remaining) {
                remaining -= p.whole - p.used;
                p.mode = .whole;
                p.used = p.whole;
                continue;
            }
            p.mode = .spine;
            const before = p.used;
            try self.select(p, before + remaining);
            remaining = (before + remaining) -| p.used;
        }
    }

    fn lineText(self: *Builder, p: *const Plan, n: u32) ![]const u8 {
        const raw = p.opened.?.lines.text(n) orelse "";
        const clipped = clipCode(raw);
        var w: Writer.Allocating = .init(self.arena);
        try w.writer.print("{d}  {s}", .{ n, clipped.text });
        if (clipped.more != 0) {
            try w.writer.print(" ... ({d} more characters on this line)", .{clipped.more});
            try self.markElided(p.subject.path, n, n);
        }
        if (n == tagLine(p)) try w.writer.print("  [target {s} {s}]", .{ p.subject.qname, &shortHash(p.subject.hash) });
        return w.written();
    }

    fn elision(self: *Builder, p: *const Plan, first: u32, last: u32) ![]const u8 {
        try self.markElided(p.subject.path, first, last);
        return std.fmt.allocPrint(self.arena, "{d}-{d}  ... {d} lines elided", .{ first, last, last - first + 1 });
    }

    fn heading(self: *Builder, out: *std.ArrayList([]const u8), path: []const u8) !void {
        if (std.mem.eql(u8, path, self.body_path)) return;
        try out.append(self.arena, path);
        self.body_path = path;
    }

    fn render(self: *Builder, out: *std.ArrayList([]const u8), p: *const Plan) !void {
        if (p.mode != .dropped) try self.heading(out, p.subject.path);
        switch (p.mode) {
            .dropped => {
                self.cut_targets += 1;
                try self.markCut(p.subject.path);
            },
            .unavailable => try out.append(self.arena, try std.fmt.allocPrint(self.arena, "{d}  {s}  [target {s} {s}]", .{ p.subject.line, p.note, p.subject.qname, &shortHash(p.subject.hash) })),
            .whole => {
                var n = p.first;
                while (n <= p.last) : (n += 1) try out.append(self.arena, try self.lineText(p, n));
            },
            .spine => {
                var next = p.first;
                for (p.chosen) |r| {
                    if (r.first > next) try out.append(self.arena, try self.elision(p, next, r.first - 1));
                    var n = @max(r.first, next);
                    while (n <= r.last) : (n += 1) try out.append(self.arena, try self.lineText(p, n));
                    next = @max(next, r.last + 1);
                }
                if (next <= p.last) try out.append(self.arena, try self.elision(p, next, p.last));
            },
        }
    }

    fn cutNote(self: *Builder) !?[]const u8 {
        if (self.cut_sites == 0 and self.cut_unknown == 0 and self.cut_targets == 0 and self.cut_tests == 0) return null;
        var w: Writer.Allocating = .init(self.arena);
        try w.writer.print("... not shown within the budget of {d} characters:", .{self.limit});
        var first = true;
        if (self.cut_sites != 0) {
            try w.writer.print(" {d} call sites", .{self.cut_sites});
            first = false;
        }
        if (self.cut_unknown != 0) {
            try w.writer.print("{s} {d} unresolved references", .{ if (first) "" else ",", self.cut_unknown });
            first = false;
        }
        if (self.cut_targets != 0) {
            try w.writer.print("{s} {d} targets", .{ if (first) "" else ",", self.cut_targets });
            first = false;
        }
        if (self.cut_tests != 0) try w.writer.print("{s} {d} tests", .{ if (first) "" else ",", self.cut_tests });
        return w.written();
    }

    fn certify(self: *Builder, used: usize) !EvidenceAnswer {
        const intent = self.request.intent;
        for (self.unknown.items) |u| try self.drawn.put(self.arena, u.path, {});
        const listed: u32 = if (self.sections.callers) listedFiles(self.fs.store) else @intCast(self.drawn.count());
        var missing: std.ArrayList(answer.Missing) = .empty;
        var file_level: std.StringArrayHashMapUnmanaged(void) = .empty;
        for (self.excluded.keys()) |path| try file_level.put(self.arena, path, {});
        const excluded_files: u32 = @intCast(file_level.count());
        for (self.unread.keys(), self.unread.values()) |path, reason| {
            if (file_level.contains(path)) continue;
            try missing.append(self.arena, .{ .path = path, .reason = reason });
            try file_level.put(self.arena, path, {});
        }
        var listed_unknown: std.ArrayList(Unknown) = .empty;
        for (self.unknown.items) |u| {
            if (file_level.contains(u.path)) continue;
            try missing.append(self.arena, .{ .path = u.path, .reason = .unresolved, .line = u.line });
            try listed_unknown.append(self.arena, u);
        }
        var budget_files: u32 = 0;
        for (self.elided_files.keys()) |path| {
            if (!file_level.contains(path)) budget_files += 1;
        }
        var budgets: std.ArrayList(answer.Budget) = .empty;
        if (self.too_large) try budgets.append(self.arena, .{ .limit = .file_bytes, .max = self.fs.max_file_bytes, .used = @min(self.fs.largest_file_bytes, self.fs.max_file_bytes) });
        if (budget_files != 0) {
            try budgets.append(self.arena, .{ .limit = .steps, .max = self.limit, .used = @min(used, self.limit) });
            try missing.append(self.arena, .{ .path = null, .reason = .budget, .files = budget_files });
        }
        const file_missing: u32 = @intCast(file_level.count());
        var names: Writer.Allocating = .init(self.arena);
        for (self.subjects.items, 0..) |s, i| try names.writer.print("{s}{s}", .{ if (i == 0) "" else ",", s.qname });
        const resolved = self.statusCount();
        var excluded = answer.Exclusions.initFill(0);
        excluded.set(.too_large, excluded_files);
        const cert: answer.Certificate = .{
            .snapshot = self.fs.snapshot,
            .scope = .{ .listed = listed, .excluded = excluded, .evaluated = listed -| (file_missing + budget_files) },
            .semantics = .{ .facts = .{ .relation = @tagName(intent), .subject = names.written(), .resolved = @intCast(resolved), .unresolved = @intCast(listed_unknown.items.len) } },
            .budgets = budgets.items,
        };
        var sites: std.ArrayList(Site) = .empty;
        try sites.appendSlice(self.arena, self.callers.items);
        try sites.appendSlice(self.arena, self.callees.items);
        const block: EvidenceBlock = .{
            .intent = intent,
            .targets = self.subjects.items,
            .not_found = self.not_found.items,
            .sites = sites.items,
            .unresolved = listed_unknown.items,
            .tests = self.tests.items,
            .elided = self.elided.items,
            .cut = self.cut_sites + self.cut_unknown + self.cut_targets + self.cut_tests,
        };
        return EvidenceAnswer.finish(block, cert, missing.items);
    }

    fn exclusionLine(self: *Builder, result: EvidenceAnswer) !?[]const u8 {
        const cert = result.certificate() orelse return null;
        const large = cert.scope.excluded.get(.too_large);
        if (large == 0) return null;
        return try std.fmt.allocPrint(self.arena, "Excluded by rule: {d} files over the {d}-byte size limit are not read.", .{ large, self.fs.max_file_bytes });
    }

    fn reasonLine(self: *Builder, result: EvidenceAnswer, room: usize) !?[]const u8 {
        const partial = switch (result) {
            .partial => |p| p,
            .complete, .refused => return null,
        };
        var by_rule = std.EnumArray(facts_query.Rule, usize).initFill(0);
        for (partial.value.unresolved) |u| by_rule.set(u.rule, by_rule.get(u.rule) + 1);
        var by_reason = std.EnumArray(answer.Reason, u64).initFill(0);
        for (partial.missing) |m| {
            if (m.reason.fileLevel()) by_reason.set(m.reason, by_reason.get(m.reason) + m.files);
        }
        var parts: std.ArrayList([]const u8) = .empty;
        const verb: []const u8 = if (self.request.intent == .callees) "be called here" else "call it";
        if (by_rule.get(.dynamic_key) != 0) try parts.append(self.arena, try std.fmt.allocPrint(self.arena, "{d} dynamic-key calls in files that reach this module may also {s}", .{ by_rule.get(.dynamic_key), verb }));
        if (by_rule.get(.same_name) != 0) try parts.append(self.arena, try std.fmt.allocPrint(self.arena, "{d} references with the same name on receivers of unknown type may also be it", .{by_rule.get(.same_name)}));
        if (by_rule.get(.own_body) != 0) try parts.append(self.arena, try std.fmt.allocPrint(self.arena, "{d} calls in the target body could not be resolved", .{by_rule.get(.own_body)}));
        if (by_reason.get(.unclassified) != 0) try parts.append(self.arena, try std.fmt.allocPrint(self.arena, "{d} files that name it were not analyzed (another language or syntax errors)", .{by_reason.get(.unclassified)}));
        if (by_reason.get(.too_large) != 0) try parts.append(self.arena, try std.fmt.allocPrint(self.arena, "{d} files over the size limit were not read", .{by_reason.get(.too_large)}));
        if (by_reason.get(.unreadable) != 0) try parts.append(self.arena, try std.fmt.allocPrint(self.arena, "{d} files could not be read (locked or access denied)", .{by_reason.get(.unreadable)}));
        if (by_reason.get(.vanished) != 0) try parts.append(self.arena, try std.fmt.allocPrint(self.arena, "{d} files no longer exist", .{by_reason.get(.vanished)}));
        if (by_reason.get(.changed_since_snapshot) != 0) try parts.append(self.arena, try std.fmt.allocPrint(self.arena, "{d} files changed after the snapshot and could not be refreshed", .{by_reason.get(.changed_since_snapshot)}));
        if (by_reason.get(.budget) != 0) try parts.append(self.arena, try std.fmt.allocPrint(self.arena, "{d} files not shown in full within the budget, each gap marked", .{by_reason.get(.budget)}));
        var w: Writer.Allocating = .init(self.arena);
        try w.writer.writeAll("Partial because:");
        for (parts.items, 0..) |part, i| {
            if (w.written().len + part.len + 3 > room -| 12) {
                try w.writer.writeAll("; and more");
                break;
            }
            try w.writer.print("{s} {s}", .{ if (i == 0) "" else ";", part });
        }
        try w.writer.writeByte('.');
        return w.written();
    }

    fn statusCount(self: *const Builder) usize {
        return switch (self.request.intent) {
            .callers => self.callers.items.len,
            .callees => self.callees.items.len,
            .flow => self.callers.items.len + self.callees.items.len,
            .decides, .explain, .where_defined => self.subjects.items.len,
        };
    }

    fn statusNoun(self: *const Builder) []const u8 {
        return switch (self.request.intent) {
            .callers => "callers",
            .callees => "callees",
            .flow => "call edges",
            .decides, .explain, .where_defined => if (self.subjects.items.len == 1) "target" else "targets",
        };
    }
};

fn build(fs: *const FactStore, request: EvidenceRequest, budget: usize) !EvidenceAnswer {
    if (budget < min_budget) return EvidenceAnswer.refuse(error.BudgetTooSmall, "the budget must be at least 1000 characters");
    if (request.targets.len == 0) return EvidenceAnswer.refuse(error.NoTarget, "the request names no target");
    const arena = fs.arena;
    const sections = sectionsOf(request);
    var b: Builder = .{ .arena = arena, .fs = fs, .request = request, .limit = budget, .terms = try termsOf(arena, request.terms), .sections = sections };
    try b.resolve();
    if (b.subjects.items.len == 0) return EvidenceAnswer.refuse(error.SubjectNotFound, "no target is an indexed definition");
    for (b.subjects.items) |s| {
        if (sections.callers) try b.relate(s, .callers);
        if (sections.callees) try b.relate(s, .callees);
    }
    if (sections.tests) try b.collectTests();

    const head = try b.header();
    const content = budget -| (head.len + 1 + status_reserve + reason_reserve + cut_reserve);
    const plans = try arena.alloc(Plan, b.subjects.items.len);
    for (b.subjects.items, plans) |s, *p| p.* = try b.plan(s);
    var need: usize = 0;
    for (plans) |*p| need += if (p.mode == .unavailable) unavailableLen(p) else p.whole;
    const caps = fitCaps(capsOf(request.intent, sections, budget), content, need);
    var rel: Section = .{ .cap = @min(caps.callers, content) };
    if (sections.callers) try b.callerLines(&rel);
    rel.cap = @min(caps.callers + caps.callees, content);
    if (sections.callees) try b.calleeLines(&rel);
    try b.unknownLines(&rel);
    var tests: Section = .{ .cap = @min(caps.tests, content -| rel.used) };
    if (sections.tests) try b.testLines(&tests);

    const body_budget = content -| (rel.used + tests.used);
    try b.allocate(plans, body_budget);
    var body: std.ArrayList([]const u8) = .empty;
    var body_used: usize = 0;
    for (plans) |*p| {
        try b.render(&body, p);
        body_used += p.used;
    }
    const note = try b.cutNote();

    var result = try b.certify(head.len + 1 + body_used + rel.used + tests.used + status_reserve + reason_reserve + cut_reserve);
    const exclusion = try b.exclusionLine(result);
    const reason = try b.reasonLine(result, reason_reserve -| (if (exclusion) |line| line.len + 1 else 0));
    var status: Writer.Allocating = .init(arena);
    try result.writeStatus(&status.writer, b.statusCount(), b.statusNoun());
    if (result == .partial and (sections.callers or sections.callees)) try status.writer.print("; {s}", .{open_note});

    var text: Writer.Allocating = .init(arena);
    try text.writer.writeAll(head);
    try text.writer.writeByte('\n');
    for (body.items) |line| {
        try text.writer.writeAll(line);
        try text.writer.writeByte('\n');
    }
    for (rel.lines.items) |line| {
        try text.writer.writeAll(line);
        try text.writer.writeByte('\n');
    }
    for (tests.lines.items) |line| {
        try text.writer.writeAll(line);
        try text.writer.writeByte('\n');
    }
    if (note) |line| {
        try text.writer.writeAll(line);
        try text.writer.writeByte('\n');
    }
    if (reason) |line| {
        try text.writer.writeAll(line);
        try text.writer.writeByte('\n');
    }
    if (exclusion) |line| {
        try text.writer.writeAll(line);
        try text.writer.writeByte('\n');
    }
    try text.writer.writeAll(status.written());
    const written = text.written();
    if (written.len > budget) return EvidenceAnswer.refuse(error.OverBudget, "the evidence block would pass its budget");
    switch (result) {
        .complete => |*c| c.value.text = written,
        .partial => |*p| p.value.text = written,
        .refused => {},
    }
    return result;
}
