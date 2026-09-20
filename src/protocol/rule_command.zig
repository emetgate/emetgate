const std = @import("std");
const checks = @import("../engine/checks.zig");
const memory = @import("../platform/memory.zig");

const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

pub const Error = error{EnforceWithoutCheck};

pub const absent_field = "-";

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

pub fn run(gpa: Allocator, io: std.Io, root_abs: []const u8, request: Request, out: *Writer) !void {
    switch (request) {
        .add => |decided| {
            try refuseUnwritable(decided);
            const id = try memory.remember(gpa, io, root_abs, .project, decided.text, decided.enforce, decided.check, decided.where);
            defer gpa.free(id);
            try out.print("{s}\n", .{id});
        },
        .supersede => |target| {
            try refuseUnwritable(target.decided);
            const decided = target.decided;
            const id = try memory.supersede(gpa, io, root_abs, target.id, .project, decided.text, decided.enforce, decided.check, decided.where);
            defer gpa.free(id);
            try out.print("{s}\n", .{id});
        },
        .forget => |id| try memory.forget(gpa, io, root_abs, id),
        .list => |listing| try list(gpa, io, root_abs, listing, out),
    }
}

fn refuseUnwritable(decided: Decided) !void {
    if (decided.enforce and decided.check == null) return error.EnforceWithoutCheck;
    if (decided.check) |spec| try checks.validate(spec);
}

fn list(gpa: Allocator, io: std.Io, root_abs: []const u8, listing: Listing, out: *Writer) !void {
    const recalled = if (listing.all)
        try memory.recallAll(gpa, io, root_abs)
    else
        try memory.recall(gpa, io, root_abs);
    defer recalled.deinit();

    for (recalled.decisions) |decision| {
        if (listing.json) {
            var js: std.json.Stringify = .{ .writer = out };
            try js.write(decision);
            try out.writeByte('\n');
        } else {
            try out.print("{s}\t{t}\t{s}\t{s}\t{s}\t{s}\n", .{
                decision.id,
                decision.status,
                if (decision.enforce) "enforce" else "advisory",
                decision.check orelse absent_field,
                decision.where orelse absent_field,
                firstLine(decision.text),
            });
        }
    }
}

fn firstLine(text: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    return text[0..end];
}
