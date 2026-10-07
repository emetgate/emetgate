const std = @import("std");
const checks = @import("../engine/checks.zig");
const query = @import("../engine/query.zig");
const lang = @import("../engine/lang/registry.zig");
const memory = @import("../platform/memory.zig");

const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

pub const Error = error{EnforceWithoutCheck};

pub const absent_field = "-";

pub const Voice = enum { terse, spoken };

const no_check = "no check";
const everywhere = "whole repository";
const nothing_kept = "no rules\n";
const columns = [_][]const u8{ "id", "state", "mode", "check", "where", "rule" };

pub fn usage(comptime prefix: []const u8) []const u8 {
    return prefix ++ "add <text> [--check <spec>] [--in <where>] [--enforce]\n" ++
        prefix ++ "list [--all] [--json]\n" ++
        prefix ++ "supersede <id> <text> [--check <spec>] [--in <where>] [--enforce]\n" ++
        prefix ++ "forget <id>\n";
}

pub const Decided = struct {
    text: []const u8,
    check: ?[]const u8 = null,
    where: ?[]const u8 = null,
    enforce: bool = false,
};

pub const Listing = struct {
    all: bool = false,
    json: bool = false,
};

pub const Request = union(enum) {
    add: Decided,
    list: Listing,
    supersede: struct { id: []const u8, decided: Decided },
    forget: []const u8,
};

pub fn parse(args: []const [:0]const u8) ?Request {
    if (args.len == 0) return null;
    const verb = args[0];
    const rest = args[1..];
    if (std.mem.eql(u8, verb, "add")) {
        if (rest.len == 0) return null;
        return .{ .add = parseDecided(rest[0], rest[1..]) orelse return null };
    }
    if (std.mem.eql(u8, verb, "list")) {
        return .{ .list = parseListing(rest) orelse return null };
    }
    if (std.mem.eql(u8, verb, "supersede")) {
        if (rest.len < 2) return null;
        return .{ .supersede = .{
            .id = rest[0],
            .decided = parseDecided(rest[1], rest[2..]) orelse return null,
        } };
    }
    if (std.mem.eql(u8, verb, "forget")) {
        if (rest.len != 1) return null;
        return .{ .forget = rest[0] };
    }
    return null;
}

fn parseDecided(text: []const u8, args: []const [:0]const u8) ?Decided {
    var decided: Decided = .{ .text = text };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--enforce")) {
            if (decided.enforce) return null;
            decided.enforce = true;
        } else if (std.mem.eql(u8, arg, "--check")) {
            if (decided.check != null or i + 1 >= args.len) return null;
            i += 1;
            decided.check = args[i];
        } else if (std.mem.eql(u8, arg, "--in")) {
            if (decided.where != null or i + 1 >= args.len) return null;
            i += 1;
            decided.where = args[i];
        } else return null;
    }
    return decided;
}

fn parseListing(args: []const [:0]const u8) ?Listing {
    var listing: Listing = .{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--all")) {
            if (listing.all) return null;
            listing.all = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            if (listing.json) return null;
            listing.json = true;
        } else return null;
    }
    return listing;
}

pub fn run(gpa: Allocator, io: std.Io, root_abs: []const u8, request: Request, out: *Writer, err_out: *Writer) !void {
    return runAs(.terse, gpa, io, root_abs, request, out, err_out);
}

pub fn runAs(voice: Voice, gpa: Allocator, io: std.Io, root_abs: []const u8, request: Request, out: *Writer, err_out: *Writer) !void {
    apply(voice, gpa, io, root_abs, request, out, err_out) catch |err| {
        switch (err) {
            error.UnknownCheck => try writeCheckNames(err_out),
            error.DecisionNotActive => try list(voice, gpa, io, root_abs, .{}, err_out),
            else => {},
        }
        return err;
    };
}

fn writeCheckNames(err_out: *Writer) !void {
    for (checks.registry) |check| try err_out.print("{s} ", .{check.name});
    try err_out.print("{s} {s}", .{ checks.command_prefix, checks.added_prefix });
    try err_out.writeByte('\n');
}

fn apply(voice: Voice, gpa: Allocator, io: std.Io, root_abs: []const u8, request: Request, out: *Writer, err_out: *Writer) !void {
    switch (request) {
        .add => |decided| {
            try explainQuery(gpa, decided, err_out);
            try refuseUnwritable(gpa, decided);
            const id = try memory.remember(gpa, io, root_abs, .project, decided.text, decided.enforce, decided.check, decided.where);
            defer gpa.free(id);
            try writeDecided(voice, "rule added", id, decided, out);
        },
        .supersede => |target| {
            try explainQuery(gpa, target.decided, err_out);
            try refuseUnwritable(gpa, target.decided);
            const decided = target.decided;
            const id = try memory.supersede(gpa, io, root_abs, target.id, .project, decided.text, decided.enforce, decided.check, decided.where);
            defer gpa.free(id);
            try writeDecided(voice, "rule replaced", id, decided, out);
        },
        .forget => |id| {
            try memory.forget(gpa, io, root_abs, id);
            if (voice == .spoken) try out.print("rule forgotten: {s}\n", .{id});
        },
        .list => |listing| try list(voice, gpa, io, root_abs, listing, out),
    }
}

fn writeDecided(voice: Voice, what: []const u8, id: []const u8, decided: Decided, out: *Writer) !void {
    if (voice == .terse) return out.print("{s}\n", .{id});
    try out.print("{s}: {s}\n", .{ what, firstLine(decided.text) });
    try out.print("{s}  {s}  {s}  {s}\n", .{
        id,
        modeOf(decided.enforce),
        decided.check orelse no_check,
        decided.where orelse everywhere,
    });
}

fn modeOf(enforce: bool) []const u8 {
    return if (enforce) "enforce" else "advisory";
}

fn refuseUnwritable(gpa: Allocator, decided: Decided) !void {
    if (decided.enforce and decided.check == null) return error.EnforceWithoutCheck;
    if (decided.check) |spec| try checks.validate(gpa, spec);
}

fn explainQuery(gpa: Allocator, decided: Decided, err_out: *Writer) !void {
    const spec = decided.check orelse return;
    const invocation = checks.parse(spec);
    if (!std.mem.eql(u8, invocation.name, checks.query_name)) return;
    const text = invocation.arg orelse return;
    if (text.len == 0) return;
    var results: [lang.profiles.len]checks.Compiled = undefined;
    try checks.compileEverywhere(gpa, text, &results);
    for (results) |result| {
        const err = result.err orelse continue;
        if (query.dependsOnLanguage(err)) continue;
        try writeProblem(err_out, err, result.diag);
        return;
    }
    const kept = for (results) |result| {
        if (result.err == null) break true;
    } else false;
    for (results) |result| {
        const err = result.err orelse continue;
        if (kept) {
            try err_out.print("q: does not compile for {s}; files in that language fail the check by name: ", .{result.profile.name});
        } else {
            try err_out.print("q: does not compile for {s}: ", .{result.profile.name});
        }
        try writeProblem(err_out, err, result.diag);
    }
}

fn writeProblem(err_out: *Writer, err: query.CompileError, diag: query.Diagnostic) !void {
    if (diag.what.len == 0) return err_out.print("{t}\n", .{err});
    try err_out.print("{t}: {s}: \"{s}\"\n", .{ err, diag.what, diag.at() });
}

fn list(voice: Voice, gpa: Allocator, io: std.Io, root_abs: []const u8, listing: Listing, out: *Writer) !void {
    const recalled = if (listing.all)
        try memory.recallAll(gpa, io, root_abs)
    else
        try memory.recall(gpa, io, root_abs);
    defer recalled.deinit();

    if (voice == .spoken and !listing.json) return table(recalled.decisions, out);
    for (recalled.decisions) |decision| {
        if (listing.json) {
            var js: std.json.Stringify = .{ .writer = out };
            try js.write(decision);
            try out.writeByte('\n');
        } else {
            try out.print("{s}\t{t}\t{s}\t{s}\t{s}\t{s}\n", .{
                decision.id,
                decision.status,
                modeOf(decision.enforce),
                decision.check orelse absent_field,
                decision.where orelse absent_field,
                firstLine(decision.text),
            });
        }
    }
}

fn table(decisions: []const memory.Decision, out: *Writer) !void {
    if (decisions.len == 0) return out.writeAll(nothing_kept);
    var widths: [columns.len]usize = undefined;
    for (columns, &widths) |name, *width| width.* = name.len;
    for (decisions) |decision| {
        for (cellsOf(decision), &widths) |cell, *width| width.* = @max(width.*, cell.len);
    }
    try writeRow(columns, widths, out);
    for (decisions) |decision| try writeRow(cellsOf(decision), widths, out);
}

fn cellsOf(decision: memory.Decision) [columns.len][]const u8 {
    return .{
        decision.id,
        @tagName(decision.status),
        modeOf(decision.enforce),
        decision.check orelse no_check,
        decision.where orelse everywhere,
        firstLine(decision.text),
    };
}

fn writeRow(cells: [columns.len][]const u8, widths: [columns.len]usize, out: *Writer) !void {
    for (cells, widths, 0..) |cell, width, index| {
        try out.writeAll(cell);
        if (index + 1 == cells.len) break;
        try out.splatByteAll(' ', width - cell.len + 2);
    }
    try out.writeByte('\n');
}

fn firstLine(text: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    return text[0..end];
}
