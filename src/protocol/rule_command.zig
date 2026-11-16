const std = @import("std");
const checks = @import("../engine/checks.zig");
const text_checks = @import("../engine/text_checks.zig");
const query = @import("../engine/query.zig");
const lang = @import("../engine/lang/registry.zig");
const memory = @import("../platform/memory.zig");
const user_rules = @import("../platform/user_rules.zig");

const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

pub const Error = error{ EnforceWithoutCheck, MessageRuleWithScope };

pub const absent_field = "-";

pub const Voice = enum { terse, spoken };

const no_check = "no check";
const everywhere = "whole repository";
const every_repository = "every repository";
const nothing_kept = "no rules\n";
const columns = [_][]const u8{ "id", "state", "origin", "mode", "check", "where", "rule" };

pub const global_flag = "--global";

pub fn usage(comptime prefix: []const u8) []const u8 {
    return prefix ++ "add <text> [--check <spec>] [--in <where>] [--enforce] [--global]\n" ++
        prefix ++ "list [--all] [--json] [--global]\n" ++
        prefix ++ "supersede <id> <text> [--check <spec>] [--in <where>] [--enforce] [--global]\n" ++
        prefix ++ "forget <id> [--global]\n" ++
        prefix ++ "pick [<numbers> [in <path>]] [--global]   (pick rules from a catalog; pick alone lists it)\n" ++
        prefix ++ "show <number>   (what a catalog rule checks)\n";
}

pub const Origin = enum {
    repo,
    global,

    pub fn of(global: bool) Origin {
        return if (global) .global else .repo;
    }
};

pub const Decided = struct {
    text: []const u8,
    check: ?[]const u8 = null,
    where: ?[]const u8 = null,
    enforce: bool = false,
    global: bool = false,
};

pub const Listing = struct {
    all: bool = false,
    json: bool = false,
    global: bool = false,
};

pub const Target = struct {
    id: []const u8,
    global: bool = false,
};

pub const Request = union(enum) {
    add: Decided,
    list: Listing,
    supersede: struct { id: []const u8, decided: Decided },
    forget: Target,

    pub fn global(self: Request) bool {
        return switch (self) {
            .add => |decided| decided.global,
            .list => |listing| listing.global,
            .supersede => |target| target.decided.global,
            .forget => |target| target.global,
        };
    }
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
        if (rest.len == 1) return .{ .forget = .{ .id = rest[0] } };
        if (rest.len == 2 and std.mem.eql(u8, rest[1], global_flag)) return .{ .forget = .{ .id = rest[0], .global = true } };
        return null;
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
        } else if (std.mem.eql(u8, arg, global_flag)) {
            if (decided.global) return null;
            decided.global = true;
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
        } else if (std.mem.eql(u8, arg, global_flag)) {
            if (listing.global) return null;
            listing.global = true;
        } else return null;
    }
    return listing;
}

pub fn run(gpa: Allocator, io: std.Io, root_abs: anyerror![]const u8, request: Request, out: *Writer, err_out: *Writer) !void {
    return runAs(.terse, gpa, io, root_abs, request, out, err_out);
}

pub fn runAs(voice: Voice, gpa: Allocator, io: std.Io, root_abs: anyerror![]const u8, request: Request, out: *Writer, err_out: *Writer) !void {
    apply(voice, gpa, io, root_abs, request, out, err_out) catch |err| {
        switch (err) {
            error.UnknownCheck => try writeCheckNames(err_out),
            error.DecisionNotActive => try list(voice, gpa, io, root_abs, .{ .global = request.global() }, err_out),
            else => {},
        }
        return err;
    };
}

fn writeCheckNames(err_out: *Writer) !void {
    for (checks.registry) |check| try err_out.print("{s} ", .{check.name});
    try err_out.print("{s} {s} {s}", .{ checks.frozen_name, checks.command_prefix, checks.added_prefix });
    for (text_checks.registry) |check| try err_out.print(" {s}{s}", .{ text_checks.prefix, check.name });
    try err_out.writeByte('\n');
}

fn apply(voice: Voice, gpa: Allocator, io: std.Io, root_abs: anyerror![]const u8, request: Request, out: *Writer, err_out: *Writer) !void {
    switch (request) {
        .add => |decided| {
            try explainQuery(gpa, decided, err_out);
            try refuseUnwritable(gpa, decided);
            const id = if (decided.global)
                try user_rules.remember(gpa, io, decided.text, decided.enforce, decided.check, decided.where)
            else
                try memory.remember(gpa, io, try root_abs, .project, decided.text, decided.enforce, decided.check, decided.where);
            defer gpa.free(id);
            try writeDecided(voice, if (decided.global) "global rule added" else "rule added", id, decided, out);
        },
        .supersede => |target| {
            try explainQuery(gpa, target.decided, err_out);
            try refuseUnwritable(gpa, target.decided);
            const decided = target.decided;
            const id = if (decided.global)
                try user_rules.supersede(gpa, io, target.id, decided.text, decided.enforce, decided.check, decided.where)
            else
                memory.supersede(gpa, io, try root_abs, target.id, .project, decided.text, decided.enforce, decided.check, decided.where) catch |err| return heldGlobally(gpa, io, target.id, err);
            defer gpa.free(id);
            try writeDecided(voice, if (decided.global) "global rule replaced" else "rule replaced", id, decided, out);
        },
        .forget => |target| {
            const id = target.id;
            if (target.global) {
                try user_rules.forget(gpa, io, id);
            } else {
                memory.forget(gpa, io, try root_abs, id) catch |err| return heldGlobally(gpa, io, id, err);
            }
            if (voice == .spoken) try out.print("rule forgotten: {s}\n", .{id});
        },
        .list => |listing| try list(voice, gpa, io, root_abs, listing, out),
    }
}

fn heldGlobally(gpa: Allocator, io: std.Io, id: []const u8, err: anyerror) anyerror {
    if (err == error.DecisionNotActive and user_rules.holds(gpa, io, id)) return error.RuleIsGlobal;
    return err;
}

fn writeDecided(voice: Voice, what: []const u8, id: []const u8, decided: Decided, out: *Writer) !void {
    if (voice == .terse) return out.print("{s}\n", .{id});
    try out.print("{s}: {s}\n", .{ what, firstLine(decided.text) });
    try out.print("{s}  {s}  {s}  {s}\n", .{
        id,
        modeOf(decided.enforce),
        decided.check orelse no_check,
        decided.where orelse whereNone(Origin.of(decided.global)),
    });
}

fn whereNone(origin: Origin) []const u8 {
    return if (origin == .global) every_repository else everywhere;
}

fn modeOf(enforce: bool) []const u8 {
    return if (enforce) "enforce" else "advisory";
}

fn refuseUnwritable(gpa: Allocator, decided: Decided) !void {
    if (decided.enforce and decided.check == null) return error.EnforceWithoutCheck;
    if (decided.check) |spec| {
        try checks.validate(gpa, spec);
        if (text_checks.of(spec) != null and decided.where != null) return error.MessageRuleWithScope;
    }
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
    if (diag.what().len == 0) return err_out.print("{t}\n", .{err});
    try err_out.print("{t}: {s}: \"{s}\"\n", .{ err, diag.what(), diag.at() });
}

pub const Listed = struct {
    decision: memory.Decision,
    origin: Origin,
};

const Recalled = struct {
    repo: ?memory.Recall = null,
    global: ?memory.Recall = null,

    fn deinit(self: Recalled) void {
        if (self.repo) |r| r.deinit();
        if (self.global) |r| r.deinit();
    }
};

fn recallFor(gpa: Allocator, io: std.Io, root_abs: anyerror![]const u8, listing: Listing) !Recalled {
    var recalled: Recalled = .{};
    errdefer recalled.deinit();
    if (!listing.global) {
        const root = try root_abs;
        recalled.repo = if (listing.all) try memory.recallAll(gpa, io, root) else try memory.recall(gpa, io, root);
    }
    recalled.global = try user_rules.recall(gpa, io, listing.all);
    return recalled;
}

fn list(voice: Voice, gpa: Allocator, io: std.Io, root_abs: anyerror![]const u8, listing: Listing, out: *Writer) !void {
    const recalled = try recallFor(gpa, io, root_abs, listing);
    defer recalled.deinit();
    var rows: std.ArrayList(Listed) = .empty;
    defer rows.deinit(gpa);
    if (recalled.repo) |r| for (r.decisions) |decision| try rows.append(gpa, .{ .decision = decision, .origin = .repo });
    if (recalled.global) |r| for (r.decisions) |decision| try rows.append(gpa, .{ .decision = decision, .origin = .global });

    if (voice == .spoken and !listing.json) return table(rows.items, out);
    for (rows.items) |row| {
        const decision = row.decision;
        if (listing.json) {
            var js: std.json.Stringify = .{ .writer = out };
            try js.beginObject();
            try decision.writeFields(&js);
            try js.objectField("origin");
            try js.write(@tagName(row.origin));
            try js.endObject();
            try out.writeByte('\n');
        } else {
            try out.print("{s}\t{t}\t{t}\t{s}\t{s}\t{s}\t{s}\n", .{
                decision.id,
                decision.status,
                row.origin,
                modeOf(decision.enforce),
                decision.check orelse absent_field,
                decision.where orelse absent_field,
                firstLine(decision.text),
            });
        }
    }
}

fn table(rows: []const Listed, out: *Writer) !void {
    if (rows.len == 0) return out.writeAll(nothing_kept);
    var widths: [columns.len]usize = undefined;
    for (columns, &widths) |name, *width| width.* = name.len;
    for (rows) |row| {
        for (cellsOf(row), &widths) |cell, *width| width.* = @max(width.*, cell.len);
    }
    try writeRow(columns, widths, out);
    for (rows) |row| try writeRow(cellsOf(row), widths, out);
}

fn cellsOf(row: Listed) [columns.len][]const u8 {
    const decision = row.decision;
    return .{
        decision.id,
        @tagName(decision.status),
        @tagName(row.origin),
        modeOf(decision.enforce),
        decision.check orelse no_check,
        decision.where orelse whereNone(row.origin),
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
