const std = @import("std");
const ts = @import("tree_sitter.zig");
const facts = @import("facts.zig");
const Profile = @import("lang/profile.zig").Profile;

const Allocator = std.mem.Allocator;

pub const max_block_lines: u32 = 12;

pub const Range = struct {
    first: u32,
    last: u32,
};

pub const Spine = struct {
    first: u32,
    last: u32,
    keep: []const Range,

    pub fn whole(self: Spine) bool {
        return self.keep.len == 1 and self.keep[0].first == self.first and self.keep[0].last == self.last;
    }
};

pub const Lines = struct {
    starts: []const u32,
    bytes: []const u8,

    pub fn of(arena: Allocator, bytes: []const u8) !Lines {
        var starts: std.ArrayList(u32) = .empty;
        try starts.append(arena, 0);
        for (bytes, 0..) |byte, i| {
            if (byte == '\n') try starts.append(arena, @intCast(i + 1));
        }
        return .{ .starts = starts.items, .bytes = bytes };
    }

    pub fn count(self: Lines) u32 {
        return @intCast(self.starts.len);
    }

    pub fn lineAt(self: Lines, offset: u32) u32 {
        var low: usize = 0;
        var high: usize = self.starts.len;
        while (high - low > 1) {
            const mid = low + (high - low) / 2;
            if (self.starts[mid] <= offset) low = mid else high = mid;
        }
        return @intCast(low + 1);
    }

    pub fn text(self: Lines, number: u32) ?[]const u8 {
        if (number == 0 or number > self.starts.len) return null;
        const start = self.starts[number - 1];
        const end = if (number < self.starts.len) self.starts[number] - 1 else @as(u32, @intCast(self.bytes.len));
        const raw = self.bytes[start..@max(start, end)];
        return std.mem.trimEnd(u8, raw, "\r");
    }

    pub fn firstCode(self: Lines, number: u32) ?u32 {
        const line = self.text(number) orelse return null;
        const lead = line.len - std.mem.trimStart(u8, line, " \t").len;
        return self.starts[number - 1] + @as(u32, @intCast(lead));
    }
};

fn deepest(root: ts.Node, offset: u32) ts.Node {
    var node = root;
    outer: while (true) {
        var i: u32 = 0;
        while (node.child(i)) |child| : (i += 1) {
            if (child.startByte() <= offset and offset < child.endByte()) {
                node = child;
                continue :outer;
            }
        }
        return node;
    }
}

fn covering(root: ts.Node, span: facts.Span) ts.Node {
    var node = root;
    outer: while (true) {
        var i: u32 = 0;
        while (node.namedChild(i)) |child| : (i += 1) {
            if (child.startByte() <= span.start and span.end <= child.endByte()) {
                node = child;
                continue :outer;
            }
        }
        return node;
    }
}

fn add(arena: Allocator, keep: *std.ArrayList(Range), first: u32, last: u32) !void {
    try keep.append(arena, .{ .first = first, .last = @max(first, last) });
}

fn rangeLess(_: void, a: Range, b: Range) bool {
    if (a.first != b.first) return a.first < b.first;
    return a.last < b.last;
}

pub fn merged(arena: Allocator, ranges: []Range) ![]const Range {
    std.mem.sort(Range, ranges, {}, rangeLess);
    var out: std.ArrayList(Range) = .empty;
    for (ranges) |r| {
        if (out.items.len != 0 and r.first <= out.items[out.items.len - 1].last + 1) {
            const last = &out.items[out.items.len - 1];
            last.last = @max(last.last, r.last);
            continue;
        }
        try out.append(arena, r);
    }
    return out.items;
}

pub const Frame = struct {
    holder: ts.Node,
    first: u32,
    last: u32,
    signature_last: u32,
};

pub fn frameOf(tree: ts.Tree, lines: Lines, span: facts.Span) Frame {
    const first = lines.lineAt(span.start);
    const last = lines.lineAt(if (span.end > span.start) span.end - 1 else span.start);
    const holder = covering(tree.root(), span);
    const body = holder.childByField("body");
    const signature_end = if (body) |b| lines.lineAt(b.startByte()) else first;
    return .{ .holder = holder, .first = first, .last = last, .signature_last = @min(signature_end, last) };
}

fn oneOf(kind: []const u8, kinds: []const []const u8) bool {
    for (kinds) |candidate| {
        if (std.mem.eql(u8, candidate, kind)) return true;
    }
    return false;
}

fn statementAt(profile: *const Profile, frame: Frame, path: []const ts.Node, at: usize) bool {
    const parent = if (at + 1 < path.len) path[at + 1] else frame.holder;
    return std.mem.eql(u8, parent.kind(), profile.block);
}

fn lineSpan(lines: Lines, node: ts.Node) Range {
    const first = lines.lineAt(node.startByte());
    return .{ .first = first, .last = @max(first, lines.lineAt(node.endByte() -| 1)) };
}

pub fn unit(arena: Allocator, profile: *const Profile, frame: Frame, lines: Lines, line: u32, branches: []const []const u8) ![]const Range {
    var keep: std.ArrayList(Range) = .empty;
    try unitInto(arena, &keep, profile, frame, lines, line, branches, true);
    return keep.items;
}

fn unitInto(arena: Allocator, keep: *std.ArrayList(Range), profile: *const Profile, frame: Frame, lines: Lines, line: u32, branches: []const []const u8, follow: bool) Allocator.Error!void {
    if (line < frame.first or line > frame.last) return;
    const offset = lines.firstCode(line) orelse return;
    const leaf = deepest(frame.holder, offset);
    var path: std.ArrayList(ts.Node) = .empty;
    var node: ?ts.Node = leaf;
    while (node) |current| : (node = current.parent()) {
        if (current.eql(frame.holder)) break;
        try path.append(arena, current);
    }
    const items = path.items;
    var kept: ?usize = null;
    if (branches.len != 0) {
        for (items, 0..) |candidate, at| {
            if (oneOf(candidate.kind(), branches)) {
                kept = at;
                break;
            }
        }
    }
    const floor = kept orelse 0;
    var i = items.len;
    while (i > floor) : (i -= 1) {
        const at = i - 1;
        if (!statementAt(profile, frame, items, at) and !oneOf(items[at].kind(), branches)) continue;
        const statement = items[at];
        const s_first = lines.lineAt(statement.startByte());
        const s_last = lines.lineAt(statement.endByte() - 1);
        if (s_last - s_first + 1 <= max_block_lines) {
            kept = at;
            break;
        }
    }
    const outer_from = if (kept) |k| k + 1 else 0;
    if (kept) |k| {
        const whole = lineSpan(lines, items[k]);
        try add(arena, keep, whole.first, whole.last);
    } else try add(arena, keep, line, line);
    for (items[outer_from..], outer_from..) |outer, at| {
        if (!statementAt(profile, frame, items, at) and !oneOf(outer.kind(), branches) and profile.functionKind(outer.kind()) == null) continue;
        const span = lineSpan(lines, outer);
        try add(arena, keep, span.first, span.first);
        try add(arena, keep, span.last, span.last);
    }
    if (follow and oneOf(leaf.kind(), profile.comments)) {
        var next = lineSpan(lines, leaf).last + 1;
        while (next <= frame.last) : (next += 1) {
            const text = lines.text(next) orelse break;
            if (std.mem.trim(u8, text, " \t").len == 0) continue;
            const at = lines.firstCode(next) orelse break;
            if (oneOf(deepest(frame.holder, at).kind(), profile.comments)) continue;
            try unitInto(arena, keep, profile, frame, lines, next, branches, false);
            break;
        }
    }
}

pub fn compute(arena: Allocator, profile: *const Profile, tree: ts.Tree, lines: Lines, span: facts.Span, relevant: []const u32) !Spine {
    const frame = frameOf(tree, lines, span);
    var keep: std.ArrayList(Range) = .empty;
    try add(arena, &keep, frame.first, frame.signature_last);
    try add(arena, &keep, frame.last, frame.last);
    for (relevant) |line| try unitInto(arena, &keep, profile, frame, lines, line, &.{}, true);
    return .{ .first = frame.first, .last = frame.last, .keep = try merged(arena, keep.items) };
}

const testing = std.testing;
const test_util = @import("test_util.zig");

test "spine: the lines around a call keep its whole small if statement and the headers of the large blocks around it" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    try source.appendSlice(testing.allocator, "function big(x: number) {\n  for (let i = 0; i < x; i++) {\n");
    for (0..20) |_| try source.appendSlice(testing.allocator, "    noise();\n");
    try source.appendSlice(testing.allocator, "    if (i > 3) {\n      before();\n      target();\n      after();\n    }\n");
    for (0..20) |_| try source.appendSlice(testing.allocator, "    noise();\n");
    try source.appendSlice(testing.allocator, "  }\n  return x;\n}\n");
    const snapshot = try test_util.snapshotOf(runtime, source.items);
    defer snapshot.destroy();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lines = try Lines.of(arena, snapshot.source);
    const spine = try compute(arena, snapshot.profile, snapshot.tree, lines, .{ .start = 0, .end = @intCast(snapshot.source.len - 1) }, &.{25});
    try testing.expectEqual(@as(u32, 1), spine.first);
    try testing.expectEqual(@as(u32, 50), spine.last);
    try testing.expect(!spine.whole());
    const want = [_]Range{ .{ .first = 1, .last = 2 }, .{ .first = 23, .last = 27 }, .{ .first = 48, .last = 48 }, .{ .first = 50, .last = 50 } };
    try testing.expectEqualSlices(Range, &want, spine.keep);
}
