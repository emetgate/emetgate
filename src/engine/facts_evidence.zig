const std = @import("std");
const facts = @import("facts.zig");
const facts_query = @import("facts_query.zig");
const symbol = @import("symbol.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const FactsAnswer = facts_query.FactsAnswer;

pub const default_budget: usize = 9_500;
pub const min_budget: usize = 400;
pub const max_code_chars: usize = 160;

pub const LineError = error{ OutOfMemory, Unavailable };

pub const LineSource = struct {
    ctx: *anyopaque,
    lineFn: *const fn (ctx: *anyopaque, path: []const u8, line: u32) LineError![]const u8,

    pub fn line(self: LineSource, path: []const u8, number: u32) LineError![]const u8 {
        return self.lineFn(self.ctx, path, number);
    }
};

pub const Rendered = struct {
    bytes: usize,
    shown: usize,
    cut: usize,
};

pub const open_footer = "An edge not in this list does not mean there is none; unresolved references: ";
pub const closed_footer = "No edge is missing from this list: every reference in scope is resolved; unresolved references: 0";

fn shortHash(hash: facts.Hash) [8]u8 {
    const hex = symbol.formatHash(hash);
    return hex[0..8].*;
}

fn ownerName(qname: []const u8) []const u8 {
    return if (qname.len == 0) "<module>" else qname;
}

fn codeOf(arena: Allocator, source: LineSource, path: []const u8, number: u32) ![]const u8 {
    const raw = source.line(path, number) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unavailable => return "(source line unavailable: the file changed or cannot be read)",
    };
    const trimmed = std.mem.trim(u8, raw, " \t\r");
    if (trimmed.len <= max_code_chars) return arena.dupe(u8, trimmed);
    var end = max_code_chars;
    while (end > 0 and (trimmed[end] & 0xC0) == 0x80) end -= 1;
    return std.fmt.allocPrint(arena, "{s}...", .{trimmed[0..end]});
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
            break :blk std.fmt.allocPrint(arena, "{s}{d}; files not analyzed: {d}", .{ open_footer, unresolved, unread });
        },
        .refused => std.fmt.allocPrint(arena, "{s}not computed", .{open_footer}),
    };
}

pub fn bodyLines(arena: Allocator, a: FactsAnswer, source: LineSource) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    const value = switch (a) {
        .complete => |c| c.value,
        .partial => |p| p.value,
        .refused => return out,
    };
    for (value.subjects) |s| {
        const h = shortHash(s.hash);
        try out.append(arena, try std.fmt.allocPrint(arena, "{s} {s}:{d}  {s} #{s}", .{ @tagName(s.kind), s.path, s.line, s.qname, &h }));
    }
    for (value.sites) |site| {
        const code = try codeOf(arena, source, site.path, site.line);
        const h = shortHash(if (value.relation == .callees) site.target.hash else site.owner.hash);
        const via = if (value.relation == .callees) site.target.qname else ownerName(site.owner.qname);
        const depth: []const u8 = if (site.depth > 1) try std.fmt.allocPrint(arena, " depth {d}", .{site.depth}) else "";
        try out.append(arena, try std.fmt.allocPrint(arena, "{s}:{d}  {s}  [{s} #{s} {s}{s}]", .{ site.path, site.line, code, via, &h, @tagName(site.certainty), depth }));
    }
    for (value.unknown) |u| {
        const code = try codeOf(arena, source, u.path, u.line);
        const h = shortHash(u.owner.hash);
        try out.append(arena, try std.fmt.allocPrint(arena, "{s}:{d}  {s}  [{s} #{s} unknown({s})]", .{ u.path, u.line, code, ownerName(u.owner.qname), &h, @tagName(u.reason) }));
    }
    for (value.unread) |f| {
        const why: []const u8 = switch (f.status) {
            .unindexed => "not parsed: unsupported language",
            .indexed => "parsed with syntax errors",
            .unreadable => "unreadable",
            .too_large => "over the file size limit",
            .removed => "removed",
        };
        try out.append(arena, try std.fmt.allocPrint(arena, "{s}  not analyzed: {s}", .{ f.path, why }));
    }
    if (value.outside.len != 0) {
        try out.append(arena, try std.fmt.allocPrint(arena, "{d} calls go outside the repository (globals or packages)", .{value.outside.len}));
    }
    return out;
}

pub fn render(arena: Allocator, out: *Writer, a: FactsAnswer, source: LineSource, budget: usize) !Rendered {
    const limit = @max(budget, min_budget);
    var status: Writer.Allocating = .init(arena);
    const count: usize = switch (a) {
        .complete => |c| countOf(c.value),
        .partial => |p| countOf(p.value),
        .refused => 0,
    };
    const noun: []const u8 = switch (a) {
        .complete => |c| c.value.relation.noun(),
        .partial => |p| p.value.relation.noun(),
        .refused => "results",
    };
    try a.writeStatus(&status.writer, count, noun);
    const head = status.written();
    const last = try footer(arena, a);
    const body = try bodyLines(arena, a, source);

    var used = head.len + 1 + last.len;
    var shown: usize = 0;
    const note_reserve: usize = 80;
    for (body.items) |line| {
        const needed = line.len + 1;
        const room = if (shown + 1 < body.items.len) note_reserve else 0;
        if (used + needed + room > limit) break;
        used += needed;
        shown += 1;
    }
    const cut = body.items.len - shown;
    var written: usize = 0;
    try out.writeAll(head);
    try out.writeByte('\n');
    written += head.len + 1;
    for (body.items[0..shown]) |line| {
        try out.writeAll(line);
        try out.writeByte('\n');
        written += line.len + 1;
    }
    if (cut != 0) {
        const note = try std.fmt.allocPrint(arena, "... {d} more lines not shown (budget {d} characters)\n", .{ cut, limit });
        try out.writeAll(note);
        written += note.len;
    }
    try out.writeAll(last);
    written += last.len;
    return .{ .bytes = written, .shown = shown, .cut = cut };
}

fn countOf(value: facts_query.Edges) usize {
    return switch (value.relation) {
        .defined_at => value.subjects.len,
        else => value.sites.len,
    };
}
