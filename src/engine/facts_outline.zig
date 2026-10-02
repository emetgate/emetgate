const std = @import("std");
const ts = @import("tree_sitter.zig");
const facts = @import("facts.zig");
const traversal = @import("traversal.zig");
const facts_spine = @import("facts_spine.zig");
const Profile = @import("lang/profile.zig").Profile;

const Allocator = std.mem.Allocator;
const Range = facts_spine.Range;
const Lines = facts_spine.Lines;
const Outline = facts.Outline;
const OutlineKind = facts.OutlineKind;
const none = facts.none;

pub const max_block_lines = facts_spine.max_block_lines;

fn oneOf(kind: []const u8, kinds: []const []const u8) bool {
    for (kinds) |candidate| {
        if (std.mem.eql(u8, candidate, kind)) return true;
    }
    return false;
}

const Interval = struct { start: u32, end: u32 };

fn defIntervals(arena: Allocator, defs: []const facts.Def) ![]const Interval {
    var out: std.ArrayList(Interval) = .empty;
    for (defs) |d| {
        if (d.kind == .module or d.span.end <= d.span.start) continue;
        if (out.items.len != 0) {
            const last = &out.items[out.items.len - 1];
            if (d.span.start < last.end) {
                last.end = @max(last.end, d.span.end);
                continue;
            }
        }
        try out.append(arena, .{ .start = d.span.start, .end = d.span.end });
    }
    return out.items;
}

pub fn collect(arena: Allocator, profile: *const Profile, tree: ts.Tree, lines: Lines, defs: []const facts.Def) ![]const Outline {
    const branches: []const []const u8 = if (profile.facts) |table| table.branch_statements else &.{};
    const covered = try defIntervals(arena, defs);
    var out: std.ArrayList(Outline) = .empty;
    var kinds: std.ArrayList([]const u8) = .empty;
    var open: std.ArrayList(u32) = .empty;
    var next_interval: usize = 0;
    var walker = traversal.Walker.init(tree.root());
    defer walker.deinit();
    while (walker.next()) |entry| {
        const depth: usize = entry.depth;
        kinds.shrinkRetainingCapacity(depth);
        const node = entry.node;
        const kind = node.kind();
        try kinds.append(arena, kind);
        const comment = profile.isComment(kind);
        if (comment) walker.skipChildren();
        const start = node.startByte();
        const end = node.endByte();
        if (end <= start) continue;
        while (next_interval < covered.len and covered[next_interval].end <= start) next_interval += 1;
        if (next_interval == covered.len) continue;
        const inside = covered[next_interval].start <= start and end <= covered[next_interval].end;
        if (!inside) continue;
        const flags: OutlineKind = .{
            .statement = depth != 0 and std.mem.eql(u8, kinds.items[depth - 1], profile.block),
            .branch = oneOf(kind, branches),
            .function = profile.functionKind(kind) != null,
            .comment = comment,
        };
        const multiline = lines.lineAt(start) != lines.lineAt(end - 1);
        const keep = flags.comment or flags.branch or ((flags.statement or flags.function) and multiline);
        if (!keep) continue;
        while (open.items.len != 0 and out.items[open.items[open.items.len - 1]].end <= start) _ = open.pop();
        const parent = if (open.items.len == 0) none else open.items[open.items.len - 1];
        const index: u32 = @intCast(out.items.len);
        try out.append(arena, .{ .start = start, .end = end, .parent = parent, .kind = flags });
        try open.append(arena, index);
    }
    return out.items;
}

pub const Frame = struct {
    first: u32,
    last: u32,
    signature_last: u32,
    start: u32,
    end: u32,
};

pub fn frameOf(lines: Lines, def: facts.Def) Frame {
    const first = lines.lineAt(def.span.start);
    const last = lines.lineAt(if (def.span.end > def.span.start) def.span.end - 1 else def.span.start);
    const body_line = if (def.body_start != none and def.body_start >= def.span.start and def.body_start < def.span.end) lines.lineAt(def.body_start) else first;
    return .{ .first = first, .last = last, .signature_last = @min(@max(body_line, first), last), .start = def.span.start, .end = def.span.end };
}

fn lineSpan(lines: Lines, node: Outline) Range {
    const first = lines.lineAt(node.start);
    return .{ .first = first, .last = @max(first, lines.lineAt(node.end -| 1)) };
}

fn add(arena: Allocator, keep: *std.ArrayList(Range), first: u32, last: u32) !void {
    try keep.append(arena, .{ .first = first, .last = @max(first, last) });
}

fn lastStartingAt(outline: []const Outline, offset: u32) ?u32 {
    var low: usize = 0;
    var high: usize = outline.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (outline[mid].start <= offset) low = mid + 1 else high = mid;
    }
    return if (low == 0) null else @intCast(low - 1);
}

fn deepestAt(outline: []const Outline, offset: u32) ?u32 {
    var node = lastStartingAt(outline, offset);
    while (node) |n| {
        if (outline[n].end > offset) return n;
        node = if (outline[n].parent == none) null else outline[n].parent;
    }
    return null;
}

fn chainAt(arena: Allocator, outline: []const Outline, frame: Frame, offset: u32) ![]const u32 {
    var chain: std.ArrayList(u32) = .empty;
    var node = deepestAt(outline, offset);
    while (node) |n| {
        const o = outline[n];
        if (o.start < frame.start or o.end > frame.end) break;
        if (o.start == frame.start and o.end == frame.end) break;
        try chain.append(arena, n);
        node = if (o.parent == none) null else o.parent;
    }
    return chain.items;
}

fn commentAt(outline: []const Outline, frame: Frame, offset: u32) bool {
    const n = deepestAt(outline, offset) orelse return false;
    const o = outline[n];
    if (o.start < frame.start or o.end > frame.end) return false;
    return o.kind.comment;
}

pub fn unit(arena: Allocator, outline: []const Outline, frame: Frame, lines: Lines, line: u32, branches: bool) ![]const Range {
    var keep: std.ArrayList(Range) = .empty;
    try unitInto(arena, &keep, outline, frame, lines, line, branches, true);
    return keep.items;
}

fn counts(kind: OutlineKind, branches: bool) bool {
    return kind.statement or (branches and kind.branch);
}

fn unitInto(arena: Allocator, keep: *std.ArrayList(Range), outline: []const Outline, frame: Frame, lines: Lines, line: u32, branches: bool, follow: bool) Allocator.Error!void {
    if (line < frame.first or line > frame.last) return;
    const offset = lines.firstCode(line) orelse return;
    const chain = try chainAt(arena, outline, frame, offset);
    var kept: ?usize = null;
    if (branches) {
        for (chain, 0..) |n, at| {
            if (outline[n].kind.branch) {
                kept = at;
                break;
            }
        }
    }
    const floor = kept orelse 0;
    var i = chain.len;
    while (i > floor) : (i -= 1) {
        const at = i - 1;
        if (!counts(outline[chain[at]].kind, branches)) continue;
        const span = lineSpan(lines, outline[chain[at]]);
        if (span.last - span.first + 1 <= max_block_lines) {
            kept = at;
            break;
        }
    }
    const outer_from = if (kept) |k| k + 1 else 0;
    if (kept) |k| {
        const whole = lineSpan(lines, outline[chain[k]]);
        try add(arena, keep, whole.first, whole.last);
    } else try add(arena, keep, line, line);
    for (chain[outer_from..]) |n| {
        const kind = outline[n].kind;
        if (!counts(kind, branches) and !kind.function) continue;
        const span = lineSpan(lines, outline[n]);
        try add(arena, keep, span.first, span.first);
        try add(arena, keep, span.last, span.last);
    }
    if (follow and chain.len != 0 and outline[chain[0]].kind.comment) {
        var next = lineSpan(lines, outline[chain[0]]).last + 1;
        while (next <= frame.last) : (next += 1) {
            const text = lines.text(next) orelse break;
            if (std.mem.trim(u8, text, " \t").len == 0) continue;
            const at = lines.firstCode(next) orelse break;
            if (commentAt(outline, frame, at)) continue;
            try unitInto(arena, keep, outline, frame, lines, next, branches, false);
            break;
        }
    }
}
