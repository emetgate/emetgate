const std = @import("std");

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

pub const active_global = "@import(\"root\").emetgate_mutant";

pub const excluded_files = [_][]const u8{ "build.zig", "test_root.zig", "tools/test_runner.zig", "tools/mutate/main.zig" };

pub const Refusal = enum {
    not_zig,
    excluded_file,
    own_optimize,
    not_a_test_kill,
    expects_compile_error,
    parse_error,
    no_hit,
    outside_function,
    several_functions,
    in_test_block,
    touches_signature,
    inline_extern_or_export,
    varargs,
    compile_error,
};

pub const Param = struct {
    name: []const u8,
    token_start: u32,
};

pub const Site = struct {
    fn_start: u32,
    fn_end: u32,
    body_open: u32,
    name: []const u8,
    name_start: u32,
    visib_start: ?u32,
    params: []const Param,
};

pub const Located = union(enum) {
    site: Site,
    refused: Refusal,
};

pub const File = struct {
    source: [:0]const u8,
    tree: Ast,

    pub fn parse(gpa: Allocator, source: []const u8) !File {
        const text = try gpa.dupeZ(u8, source);
        errdefer gpa.free(text);
        const tree = try Ast.parse(gpa, text, .zig);
        return .{ .source = text, .tree = tree };
    }

    pub fn deinit(file: *File, gpa: Allocator) void {
        file.tree.deinit(gpa);
        gpa.free(file.source);
    }

    fn range(file: *const File, node: Ast.Node.Index) [2]u32 {
        const tree = &file.tree;
        const last = tree.lastToken(node);
        return .{ tree.tokenStart(tree.firstToken(node)), tree.tokenStart(last) + @as(u32, @intCast(tree.tokenSlice(last).len)) };
    }

    fn innermost(file: *const File, start: usize, end: usize) ?Ast.Node.Index {
        const tree = &file.tree;
        var best: ?Ast.Node.Index = null;
        var best_len: usize = std.math.maxInt(usize);
        for (0..tree.nodes.len) |i| {
            const node: Ast.Node.Index = @enumFromInt(i);
            switch (tree.nodeTag(node)) {
                .fn_decl, .test_decl => {},
                else => continue,
            }
            const r = file.range(node);
            if (r[0] > start or r[1] < end) continue;
            if (r[1] - r[0] < best_len) {
                best = node;
                best_len = r[1] - r[0];
            }
        }
        return best;
    }

    pub fn locate(file: *const File, gpa: Allocator, from: []const u8) !Located {
        const tree = &file.tree;
        if (tree.errors.len != 0) return .{ .refused = .parse_error };
        if (from.len == 0) return .{ .refused = .no_hit };
        var chosen: ?Ast.Node.Index = null;
        var at: usize = 0;
        var hits: usize = 0;
        var first_hit: usize = 0;
        while (std.mem.indexOfPos(u8, file.source, at, from)) |hit| : (at = hit + 1) {
            if (hits == 0) first_hit = hit;
            hits += 1;
            const node = file.innermost(hit, hit + from.len) orelse return .{ .refused = .outside_function };
            if (tree.nodeTag(node) == .test_decl) return .{ .refused = .in_test_block };
            if (chosen) |c| {
                if (c != node) return .{ .refused = .several_functions };
            } else chosen = node;
        }
        const node = chosen orelse return .{ .refused = .no_hit };

        var buf: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buf, node) orelse return .{ .refused = .outside_function };
        if (proto.extern_export_inline_token) |tok| switch (tree.tokenTag(tok)) {
            .keyword_inline, .keyword_extern, .keyword_export => return .{ .refused = .inline_extern_or_export },
            else => {},
        };
        const name_token = proto.name_token orelse return .{ .refused = .outside_function };
        const body = tree.nodeData(node).node_and_node[1];
        const lbrace = tree.nodeMainToken(body);
        if (tree.tokenTag(lbrace) != .l_brace) return .{ .refused = .outside_function };
        const body_open = tree.tokenStart(lbrace) + 1;
        if (first_hit < body_open) return .{ .refused = .touches_signature };

        var params: std.ArrayList(Param) = .empty;
        errdefer params.deinit(gpa);
        var it = proto.iterate(tree);
        while (it.next()) |param| {
            if (param.anytype_ellipsis3) |tok| {
                if (tree.tokenTag(tok) == .ellipsis3) return .{ .refused = .varargs };
            }
            const tok = param.name_token orelse return .{ .refused = .touches_signature };
            try params.append(gpa, .{ .name = tree.tokenSlice(tok), .token_start = tree.tokenStart(tok) });
        }
        const r = file.range(node);
        return .{ .site = .{
            .fn_start = r[0],
            .fn_end = r[1],
            .body_open = body_open,
            .name = tree.tokenSlice(name_token),
            .name_start = tree.tokenStart(name_token),
            .visib_start = if (proto.visib_token) |tok| tree.tokenStart(tok) else null,
            .params = try params.toOwnedSlice(gpa),
        } };
    }
};

pub const Entry = struct {
    number: u32,
    site: Site,
    from: []const u8,
    to: []const u8,
    all: bool = false,
};

pub const Region = struct {
    number: u32,
    first_line: u32,
    last_line: u32,
    whole_function: bool = false,
};

pub const Transformed = struct {
    text: []u8,
    regions: []Region,

    pub fn deinit(t: Transformed, gpa: Allocator) void {
        gpa.free(t.text);
        gpa.free(t.regions);
    }

    pub fn mutantsAt(t: Transformed, line: u32, out: *std.ArrayList(u32), gpa: Allocator) !void {
        const before = out.items.len;
        inline for (.{ false, true }) |whole| {
            if (whole and out.items.len != before) return;
            for (t.regions) |r| {
                if (r.whole_function != whole) continue;
                if (line < r.first_line or line > r.last_line) continue;
                if (std.mem.indexOfScalar(u32, out.items, r.number) == null) try out.append(gpa, r.number);
            }
        }
    }
};

pub fn copyName(gpa: Allocator, name: []const u8, number: u32) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}__m{d}", .{ name, number });
}

fn argName(gpa: Allocator, param: Param, index: usize) ![]const u8 {
    if (std.mem.eql(u8, param.name, "_")) return std.fmt.allocPrint(gpa, "__emetgate_p{d}", .{index});
    return gpa.dupe(u8, param.name);
}

pub fn dispatchLine(gpa: Allocator, site: Site, number: u32) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.print(" if (" ++ active_global ++ " == {d}) return {s}__m{d}(", .{ number, site.name, number });
    for (site.params, 0..) |param, i| {
        const arg = try argName(gpa, param, i);
        defer gpa.free(arg);
        if (i != 0) try out.writer.writeAll(", ");
        try out.writer.writeAll(arg);
    }
    try out.writer.writeAll(");");
    return out.toOwnedSlice();
}

pub fn copyText(gpa: Allocator, source: []const u8, entry: Entry) ![]u8 {
    const site = entry.site;
    const original = source[site.fn_start..site.fn_end];
    if (std.mem.count(u8, original, entry.from) != std.mem.count(u8, source, entry.from)) return error.PatternOutsideFunction;
    if (!entry.all and std.mem.count(u8, original, entry.from) != 1) return error.PatternNotUnique;

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var at: usize = site.fn_start;
    if (site.visib_start) |v| {
        at = v + "pub".len;
        while (at < source.len and source[at] == ' ') at += 1;
    }
    try out.writer.writeAll(source[at..site.name_start]);
    try out.writer.print("{s}__m{d}", .{ site.name, entry.number });
    const rest = source[site.name_start + site.name.len .. site.fn_end];
    const mutated = try gpa.alloc(u8, std.mem.replacementSize(u8, rest, entry.from, entry.to));
    defer gpa.free(mutated);
    _ = std.mem.replace(u8, rest, entry.from, entry.to, mutated);
    try out.writer.writeAll(mutated);
    return out.toOwnedSlice();
}

const Discard = struct { start: u32, len: u32 };

pub fn discardsOf(gpa: Allocator, source: []const u8, from: usize, name: []const u8) ![]const Discard {
    var found: std.ArrayList(Discard) = .empty;
    const needle = try std.fmt.allocPrint(gpa, "_ = {s};", .{name});
    defer gpa.free(needle);
    var at = from;
    while (std.mem.indexOfPos(u8, source, at, needle)) |hit| : (at = hit + needle.len) {
        const before_ok = hit == 0 or std.mem.indexOfScalar(u8, " \t\n\r{;", source[hit - 1]) != null;
        if (!before_ok) continue;
        try found.append(gpa, .{ .start = @intCast(hit), .len = @intCast(needle.len) });
    }
    return found.toOwnedSlice(gpa);
}

const Edit = struct {
    offset: u32,
    remove: u32 = 0,
    text: []const u8,
    number: ?u32 = null,
};

fn editLess(_: void, a: Edit, b: Edit) bool {
    if (a.offset != b.offset) return a.offset < b.offset;
    const an = a.number orelse 0;
    const bn = b.number orelse 0;
    return an < bn;
}

fn mapOffset(edits: []const Edit, old: usize) usize {
    var new = old;
    for (edits) |edit| {
        if (edit.offset >= old) break;
        new = new + edit.text.len - edit.remove;
    }
    return new;
}

fn lineAt(text: []const u8, offset: usize) u32 {
    return @intCast(std.mem.count(u8, text[0..offset], "\n") + 1);
}

pub fn transform(gpa: Allocator, source: []const u8, entries: []const Entry) !Transformed {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var edits: std.ArrayList(Edit) = .empty;
    var renamed: std.ArrayList(u32) = .empty;
    for (entries) |entry| {
        const site = entry.site;
        const fresh = std.mem.indexOfScalar(u32, renamed.items, site.fn_start) == null;
        if (fresh) {
            try renamed.append(arena, site.fn_start);
            for (site.params, 0..) |param, i| {
                if (!std.mem.eql(u8, param.name, "_")) {
                    for (try discardsOf(arena, source[0..site.fn_end], site.body_open, param.name)) |at| {
                        try edits.append(arena, .{ .offset = at.start, .remove = at.len, .text = "" });
                    }
                    continue;
                }
                try edits.append(arena, .{ .offset = param.token_start, .remove = 1, .text = try argName(arena, param, i) });
            }
        }
        try edits.append(arena, .{ .offset = site.body_open, .text = try dispatchLine(arena, site, entry.number), .number = entry.number });
        const copy = try copyText(arena, source, entry);
        try edits.append(arena, .{ .offset = site.fn_end, .text = try std.mem.concat(arena, u8, &.{ "\n\n", copy }), .number = entry.number });
    }
    std.mem.sort(Edit, edits.items, {}, editLess);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const Span = struct { number: u32, start: usize, end: usize };
    var spans: std.ArrayList(Span) = .empty;
    var at: usize = 0;
    for (edits.items) |edit| {
        try out.appendSlice(gpa, source[at..edit.offset]);
        const start = out.items.len;
        try out.appendSlice(gpa, edit.text);
        if (edit.number) |n| try spans.append(arena, .{ .number = n, .start = start, .end = out.items.len });
        at = edit.offset + edit.remove;
    }
    try out.appendSlice(gpa, source[at..]);

    var regions: std.ArrayList(Region) = .empty;
    errdefer regions.deinit(gpa);
    for (spans.items) |span| {
        try regions.append(gpa, .{
            .number = span.number,
            .first_line = lineAt(out.items, span.start),
            .last_line = lineAt(out.items, @max(span.start, span.end - 1)),
        });
    }
    for (entries) |entry| {
        var last: usize = mapOffset(edits.items, entry.site.fn_end);
        for (entries) |other| {
            if (other.site.fn_start != entry.site.fn_start) continue;
            for (spans.items) |span| {
                if (span.number == other.number) last = @max(last, span.end);
            }
        }
        try regions.append(gpa, .{
            .number = entry.number,
            .first_line = lineAt(out.items, mapOffset(edits.items, entry.site.fn_start)),
            .last_line = lineAt(out.items, last - 1),
            .whole_function = true,
        });
    }
    return .{ .text = try out.toOwnedSlice(gpa), .regions = try regions.toOwnedSlice(gpa) };
}

pub const CompileError = struct {
    path: []const u8,
    line: u32,
    message: []const u8 = "",
};

pub fn compileErrors(gpa: Allocator, output: []const u8) ![]CompileError {
    var found: std.ArrayList(CompileError) = .empty;
    errdefer found.deinit(gpa);
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        const marker = std.mem.indexOf(u8, line, ": error: ") orelse continue;
        const head = line[0..marker];
        const col_colon = std.mem.lastIndexOfScalar(u8, head, ':') orelse continue;
        const line_colon = std.mem.lastIndexOfScalar(u8, head[0..col_colon], ':') orelse continue;
        _ = std.fmt.parseUnsigned(u32, head[col_colon + 1 ..], 10) catch continue;
        const number = std.fmt.parseUnsigned(u32, head[line_colon + 1 .. col_colon], 10) catch continue;
        try found.append(gpa, .{ .path = head[0..line_colon], .line = number, .message = line[marker + ": error: ".len ..] });
    }
    return found.toOwnedSlice(gpa);
}

pub fn samePath(reported: []const u8, file: []const u8) bool {
    if (reported.len < file.len) return false;
    const tail = reported[reported.len - file.len ..];
    for (tail, file) |a, b| {
        const x: u8 = if (a == '\\') '/' else a;
        if (x != b) return false;
    }
    return reported.len == file.len or reported[reported.len - file.len - 1] == '/' or reported[reported.len - file.len - 1] == '\\';
}
