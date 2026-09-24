const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Range = struct {
    first: u32,
    last: u32,

    pub fn meets(a: Range, b: Range) bool {
        return a.first <= b.last and b.first <= a.last;
    }
};

pub const FileChange = struct {
    path: []const u8,
    ranges: []const Range,
};

pub fn parseDiff(gpa: Allocator, text: []const u8) ![]FileChange {
    var files: std.ArrayList(FileChange) = .empty;
    var ranges: std.ArrayList(Range) = .empty;
    var path: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            if (path) |p| try files.append(gpa, .{ .path = p, .ranges = try ranges.toOwnedSlice(gpa) });
            ranges.clearRetainingCapacity();
            path = null;
            continue;
        }
        if (std.mem.startsWith(u8, line, "+++ ")) {
            const target = line["+++ ".len..];
            path = if (std.mem.startsWith(u8, target, "b/")) target[2..] else null;
            continue;
        }
        if (!std.mem.startsWith(u8, line, "@@ ")) continue;
        const plus = std.mem.indexOfScalar(u8, line, '+') orelse continue;
        const end = std.mem.indexOfScalarPos(u8, line, plus, ' ') orelse continue;
        const spec = line[plus + 1 .. end];
        const comma = std.mem.indexOfScalar(u8, spec, ',');
        const start = std.fmt.parseUnsigned(u32, spec[0 .. comma orelse spec.len], 10) catch continue;
        const count = if (comma) |c| std.fmt.parseUnsigned(u32, spec[c + 1 ..], 10) catch continue else 1;
        try ranges.append(gpa, if (count == 0) .{ .first = start, .last = start + 1 } else .{ .first = start, .last = start + count - 1 });
    }
    if (path) |p| try files.append(gpa, .{ .path = p, .ranges = try ranges.toOwnedSlice(gpa) });
    return files.toOwnedSlice(gpa);
}

pub fn rangesOf(changes: []const FileChange, path: []const u8) ?[]const Range {
    for (changes) |change| {
        if (std.mem.eql(u8, change.path, path)) return change.ranges;
    }
    return null;
}

pub fn lineRange(source: []const u8, start: usize, len: usize) Range {
    const first: u32 = @intCast(std.mem.count(u8, source[0..start], "\n") + 1);
    const tail = source[start..@min(source.len, start + @max(len, 1))];
    var inner = tail;
    if (inner.len != 0 and inner[inner.len - 1] == '\n') inner = inner[0 .. inner.len - 1];
    return .{ .first = first, .last = first + @as(u32, @intCast(std.mem.count(u8, inner, "\n"))) };
}

pub fn touches(ranges: []const Range, r: Range) bool {
    for (ranges) |changed| {
        if (changed.meets(r)) return true;
    }
    return false;
}

pub const FromState = enum { untouched, touched, stale };

pub fn fromState(source: []const u8, from: []const u8, ranges: []const Range) FromState {
    if (from.len == 0) return .stale;
    var at: usize = 0;
    var found = false;
    while (std.mem.indexOfPos(u8, source, at, from)) |hit| : (at = hit + 1) {
        found = true;
        if (touches(ranges, lineRange(source, hit, from.len))) return .touched;
    }
    return if (found) .untouched else .stale;
}

pub fn changedTests(gpa: Allocator, source: []const u8, ranges: []const Range) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    const text = try gpa.dupeZ(u8, source);
    var tree = try std.zig.Ast.parse(gpa, text, .zig);
    defer tree.deinit(gpa);
    for (0..tree.nodes.len) |i| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(i);
        if (tree.nodeTag(node) != .test_decl) continue;
        const name_token = tree.nodeData(node).opt_token_and_node[0].unwrap() orelse continue;
        const first = tree.tokenStart(tree.firstToken(node));
        const last_token = tree.lastToken(node);
        const stop = tree.tokenStart(last_token) + tree.tokenSlice(last_token).len;
        if (!touches(ranges, lineRange(source, first, stop - first))) continue;
        const raw = tree.tokenSlice(name_token);
        const name = switch (tree.tokenTag(name_token)) {
            .string_literal => std.zig.string_literal.parseAlloc(gpa, raw) catch continue,
            else => try gpa.dupe(u8, raw),
        };
        try names.append(gpa, name);
    }
    return names.toOwnedSlice(gpa);
}

pub fn namesATest(changed: []const []const u8, kills: []const []const u8, filters: []const []const u8) ?[]const u8 {
    for (changed) |name| {
        for (kills) |kill| {
            if (std.mem.eql(u8, name, kill)) return name;
        }
        for (filters) |filter| {
            if (std.mem.indexOf(u8, name, filter) != null) return name;
        }
    }
    return null;
}

pub const Reason = enum { from_changed, stale, entry_changed, kill_test_changed };

pub fn entryChanged(before: ?[]const u8, now: []const u8) bool {
    const old = before orelse return true;
    return !std.mem.eql(u8, old, now);
}
