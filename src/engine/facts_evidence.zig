const std = @import("std");
const ts = @import("tree_sitter.zig");
const facts = @import("facts.zig");
const facts_query = @import("facts_query.zig");
const facts_spine = @import("facts_spine.zig");
const symbol = @import("symbol.zig");
const answer = @import("answer.zig");
const Profile = @import("lang/profile.zig").Profile;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const FactsAnswer = facts_query.FactsAnswer;

pub const default_budget: usize = 9_500;
pub const min_budget: usize = 1_000;
pub const max_code_chars: usize = 160;
const reserve: usize = 520;

pub const SourceError = error{ OutOfMemory, Unavailable };

pub const File = struct {
    bytes: []const u8,
    profile: *const Profile,
};

pub const Source = struct {
    ctx: *anyopaque,
    fileFn: *const fn (ctx: *anyopaque, path: []const u8) SourceError!File,

    pub fn file(self: Source, path: []const u8) SourceError!File {
        return self.fileFn(self.ctx, path);
    }
};

pub const Rendered = struct {
    bytes: usize,
    shown: usize,
    cut: usize,
    elided: bool,
    status: answer.Status,
};

pub const open_footer = "An edge not in this list does not mean there is none; unresolved references: ";
pub const closed_footer = "No edge is missing from this list: every reference in scope is resolved; unresolved references: 0";
pub const callers_note = "Callers are shown by signature and call line; the rest of each caller is not shown (emetgate_read_symbol reads it).";

fn shortHash(hash: facts.Hash) [8]u8 {
    const hex = symbol.formatHash(hash);
    return hex[0..8].*;
}

fn ownerName(qname: []const u8) []const u8 {
    return if (qname.len == 0) "<module>" else qname;
}

fn clip(arena: Allocator, raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r");
    if (trimmed.len <= max_code_chars) return trimmed;
    var end = max_code_chars;
    while (end > 0 and (trimmed[end] & 0xC0) == 0x80) end -= 1;
    return std.fmt.allocPrint(arena, "{s}...", .{trimmed[0..end]});
}

const Opened = struct {
    file: File,
    lines: facts_spine.Lines,
};

const Renderer = struct {
    arena: Allocator,
    source: Source,
    limit: usize,
    body: std.ArrayList([]const u8) = .empty,
    used: usize = 0,
    files: std.StringHashMapUnmanaged(?Opened) = .empty,
    elided_files: std.StringArrayHashMapUnmanaged(void) = .empty,
    cut: usize = 0,
    body_elided: bool = false,
    parser: ?ts.Parser = null,

    fn deinit(self: *Renderer) void {
        if (self.parser) |p| p.deinit();
    }

    fn open(self: *Renderer, path: []const u8) !?Opened {
        if (self.files.get(path)) |cached| return cached;
        const got = self.source.file(path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unavailable => {
                try self.files.put(self.arena, path, null);
                return null;
            },
        };
        const opened: Opened = .{ .file = got, .lines = try facts_spine.Lines.of(self.arena, got.bytes) };
        try self.files.put(self.arena, path, opened);
        return opened;
    }

    fn code(self: *Renderer, path: []const u8, number: u32) ![]const u8 {
        const opened = (try self.open(path)) orelse return "(source unavailable: the file changed or cannot be read)";
        const text = opened.lines.text(number) orelse return "(no such line)";
        return clip(self.arena, text);
    }

    fn fits(self: *const Renderer, text: []const u8) bool {
        return self.used + text.len + 1 + reserve <= self.limit;
    }

    fn push(self: *Renderer, text: []const u8) !bool {
        if (!self.fits(text)) return false;
        try self.body.append(self.arena, text);
        self.used += text.len + 1;
        return true;
    }

    fn markElided(self: *Renderer, path: []const u8) !void {
        try self.elided_files.put(self.arena, path, {});
    }

    fn numbered(self: *Renderer, opened: Opened, number: u32) ![]const u8 {
        const text: []const u8 = opened.lines.text(number) orelse "";
        return std.fmt.allocPrint(self.arena, "{d:>6}  {s}", .{ number, std.mem.trimEnd(u8, text, " \t") });
    }

    fn elisionLine(self: *Renderer, first: u32, last: u32, path: []const u8, qname: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.arena, "        ... {d} lines elided ({d}-{d}); read them with emetgate_read_symbol {{\"file\":\"{s}\",\"symbol\":\"{s}\"}}", .{ last - first + 1, first, last, path, qname });
    }

    fn function(self: *Renderer, subject: facts_query.Subject, relevant: []const u32, allot: usize) !void {
        const opened = (try self.open(subject.path)) orelse {
            _ = try self.push("        (body not shown: the file changed or cannot be read)");
            self.body_elided = true;
            try self.markElided(subject.path);
            return;
        };
        const lines = opened.lines;
        const first = lines.lineAt(subject.span.start);
        const last = lines.lineAt(if (subject.span.end > subject.span.start) subject.span.end - 1 else subject.span.start);
        var whole: usize = 0;
        var n = first;
        while (n <= last) : (n += 1) whole += if (lines.text(n)) |line| line.len + 9 else 9;
        const room = @min(allot, self.limit -| (self.used + reserve));
        if (whole <= room) {
            n = first;
            while (n <= last) : (n += 1) _ = try self.push(try self.numbered(opened, n));
            return;
        }
        if (self.parser == null) self.parser = ts.Parser.create();
        const tree = try self.parser.?.parseIn(opened.file.profile.grammar(), opened.file.bytes);
        defer tree.deinit();
        const spine = try facts_spine.compute(self.arena, opened.file.profile, tree, lines, subject.span, relevant);
        self.body_elided = true;
        try self.markElided(subject.path);
        var next = first;
        var spent: usize = 0;
        for (spine.keep) |range| {
            if (range.first > next) _ = try self.push(try self.elisionLine(next, range.first - 1, subject.path, subject.qname));
            var line = @max(range.first, next);
            while (line <= range.last) : (line += 1) {
                const text = try self.numbered(opened, line);
                if (spent + text.len > room or !(try self.push(text))) {
                    _ = try self.push(try self.elisionLine(line, last, subject.path, subject.qname));
                    return;
                }
                spent += text.len + 1;
            }
            next = range.last + 1;
        }
        if (next <= last) _ = try self.push(try self.elisionLine(next, last, subject.path, subject.qname));
    }
};

fn relevantLines(arena: Allocator, value: facts_query.Edges, subject: facts_query.Subject) ![]const u32 {
    if (value.relation != .callees) return &.{};
    var out: std.ArrayList(u32) = .empty;
    for (value.sites) |s| {
        if (s.depth == 1 and std.mem.eql(u8, s.path, subject.path)) try out.append(arena, s.line);
    }
    for (value.unknown) |u| {
        if (std.mem.eql(u8, u.path, subject.path)) try out.append(arena, u.line);
    }
    return out.items;
}

fn countOf(value: facts_query.Edges) usize {
    return switch (value.relation) {
        .defined_at => value.subjects.len,
        else => value.sites.len,
    };
}

fn withElision(arena: Allocator, a: FactsAnswer, elided_files: u32, used: usize, limit: usize) !FactsAnswer {
    var value: facts_query.Edges = undefined;
    var cert: answer.Certificate = undefined;
    var prior: []const answer.Missing = &.{};
    switch (a) {
        .complete => |c| {
            value = c.value;
            cert = c.cert;
        },
        .partial => |p| {
            value = p.value;
            cert = p.cert;
            prior = p.missing;
        },
        .refused => return a,
    }
    const files = @min(elided_files, cert.scope.evaluated);
    if (files == 0) return a;
    cert.scope.evaluated -= files;
    var budgets: std.ArrayList(answer.Budget) = .empty;
    try budgets.appendSlice(arena, cert.budgets);
    try budgets.append(arena, .{ .limit = .steps, .max = limit, .used = @min(used, limit) });
    cert.budgets = budgets.items;
    var missing: std.ArrayList(answer.Missing) = .empty;
    try missing.appendSlice(arena, prior);
    try missing.append(arena, .{ .path = null, .reason = .budget, .files = files });
    return FactsAnswer.finish(value, cert, missing.items);
}

fn footer(arena: Allocator, a: FactsAnswer) ![]const u8 {
    return switch (a) {
        .complete => closed_footer,
        .partial => |p| blk: {
            var unresolved: usize = 0;
            var unread: usize = 0;
            for (p.missing) |m| {
                if (m.reason == .unresolved) unresolved += 1 else unread += m.files;
            }
            if (unread == 0) break :blk std.fmt.allocPrint(arena, "{s}{d}", .{ open_footer, unresolved });
            break :blk std.fmt.allocPrint(arena, "{s}{d}; files not analyzed or not fully shown: {d}", .{ open_footer, unresolved, unread });
        },
        .refused => std.fmt.allocPrint(arena, "{s}not computed", .{open_footer}),
    };
}

fn siteLines(r: *Renderer, arena: Allocator, value: facts_query.Edges) !usize {
    var shown: usize = 0;
    switch (value.relation) {
        .callers, .refs => {
            var i: usize = 0;
            while (i < value.sites.len) {
                const head = value.sites[i];
                var j = i;
                while (j < value.sites.len and std.mem.eql(u8, value.sites[j].path, head.path) and std.mem.eql(u8, value.sites[j].owner.qname, head.owner.qname) and value.sites[j].depth == head.depth) j += 1;
                const h = shortHash(head.owner.hash);
                const depth: []const u8 = if (head.depth > 1) try std.fmt.allocPrint(arena, " depth {d}", .{head.depth}) else "";
                const signature = if (head.owner.qname.len == 0) "" else try r.code(head.path, head.owner.line);
                if (!try r.push(try std.fmt.allocPrint(arena, "{s}:{d}  {s}  [{s} #{s}{s}]", .{ head.path, head.owner.line, signature, ownerName(head.owner.qname), &h, depth }))) return shown;
                for (value.sites[i..j]) |site| {
                    if (!try r.push(try std.fmt.allocPrint(arena, "  {s}:{d}  {s}  [{t} {s}]", .{ site.path, site.line, try r.code(site.path, site.line), site.kind, @tagName(site.certainty) }))) return shown;
                    shown += 1;
                }
                i = j;
            }
        },
        .callees => {
            var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
            for (value.sites) |site| {
                const entry = try seen.getOrPut(arena, site.target.id.key());
                if (!entry.found_existing) {
                    const h = shortHash(site.target.hash);
                    const line = try std.fmt.allocPrint(arena, "-> {s}  {s}:{d}  {s}  #{s} {s}  (called at line {d})", .{ site.target.qname, site.target.path, site.target.line, try r.code(site.target.path, site.target.line), &h, @tagName(site.certainty), site.line });
                    if (!try r.push(line)) return shown;
                }
                shown += 1;
            }
        },
        .defined_at => {},
    }
    return shown;
}

pub fn render(arena: Allocator, out: *Writer, a: FactsAnswer, source: Source, budget: usize) !Rendered {
    const limit = @max(budget, min_budget);
    const value = switch (a) {
        .complete => |c| c.value,
        .partial => |p| p.value,
        .refused => {
            var status: Writer.Allocating = .init(arena);
            try a.writeStatus(&status.writer, 0, "results");
            const last = try footer(arena, a);
            try out.print("{s}\n{s}", .{ status.written(), last });
            return .{ .bytes = status.written().len + 1 + last.len, .shown = 0, .cut = 0, .elided = false, .status = .refused };
        },
    };
    var r: Renderer = .{ .arena = arena, .source = source, .limit = limit };
    defer r.deinit();
    const body_share: usize = switch (value.relation) {
        .callees, .defined_at => 55,
        .callers, .refs => 30,
    };
    const per_subject = (limit * body_share / 100) / @max(value.subjects.len, 1);
    for (value.subjects) |s| {
        const h = shortHash(s.hash);
        const opened = try r.open(s.path);
        const first = if (opened) |o| o.lines.lineAt(s.span.start) else s.line;
        const last = if (opened) |o| o.lines.lineAt(if (s.span.end > s.span.start) s.span.end - 1 else s.span.start) else s.line;
        if (!try r.push(try std.fmt.allocPrint(arena, "{s} {s}:{d}-{d}  {s} #{s}", .{ @tagName(s.kind), s.path, first, last, s.qname, &h }))) {
            r.cut += 1;
            try r.markElided(s.path);
            continue;
        }
        try r.function(s, try relevantLines(arena, value, s), per_subject);
    }

    const shown_sites = try siteLines(&r, arena, value);
    if (shown_sites != 0 and (value.relation == .callers or value.relation == .refs)) _ = try r.push(callers_note);
    for (value.sites[shown_sites..]) |site| {
        r.cut += 1;
        try r.markElided(site.path);
    }

    var shown_unknown: usize = 0;
    for (value.unknown) |u| {
        const h = shortHash(u.owner.hash);
        const line = try std.fmt.allocPrint(arena, "{s}:{d}  {s}  [{s} #{s} unknown({s})]", .{ u.path, u.line, try r.code(u.path, u.line), ownerName(u.owner.qname), &h, @tagName(u.reason) });
        if (!try r.push(line)) break;
        shown_unknown += 1;
    }
    for (value.unknown[shown_unknown..]) |u| {
        r.cut += 1;
        try r.markElided(u.path);
    }
    for (value.unread) |f| {
        const why: []const u8 = switch (f.status) {
            .unindexed => "not parsed: unsupported language",
            .indexed => "parsed with syntax errors",
            .unreadable => "unreadable",
            .too_large => "over the file size limit",
            .removed => "removed",
        };
        if (!try r.push(try std.fmt.allocPrint(arena, "{s}  not analyzed: {s}", .{ f.path, why }))) r.cut += 1;
    }
    if (value.outside.len != 0) _ = try r.push(try std.fmt.allocPrint(arena, "{d} calls go outside the repository (globals or packages)", .{value.outside.len}));

    const elided_files: u32 = @intCast(r.elided_files.count());
    const final = if (elided_files != 0) try withElision(arena, a, elided_files, r.used + reserve, limit) else a;
    var status: Writer.Allocating = .init(arena);
    try final.writeStatus(&status.writer, countOf(value), value.relation.noun());
    const last = try footer(arena, final);
    var written: usize = 0;
    try out.writeAll(status.written());
    try out.writeByte('\n');
    written += status.written().len + 1;
    for (r.body.items) |line| {
        try out.writeAll(line);
        try out.writeByte('\n');
        written += line.len + 1;
    }
    if (r.cut != 0) {
        const note = try std.fmt.allocPrint(arena, "... {d} more lines not shown (budget {d} characters); the answer is partial for that reason\n", .{ r.cut, limit });
        try out.writeAll(note);
        written += note.len;
    }
    try out.writeAll(last);
    written += last.len;
    return .{ .bytes = written, .shown = r.body.items.len, .cut = r.cut, .elided = r.body_elided or r.cut != 0, .status = final.status() };
}
