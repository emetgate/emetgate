const std = @import("std");
const ts = @import("../engine/tree_sitter.zig");

const Allocator = std.mem.Allocator;

pub const default_budget: usize = 8 * 1024;
pub const min_fold_lines: u32 = 3;
pub const min_fold_bytes: u32 = 200;
pub const outline_depth: u32 = 2;
pub const max_outline: usize = 40;
pub const max_header_bytes: usize = 120;
const tail_reserve: usize = 160;
const ellipsis = "\u{2026}";

pub const Block = struct {
    kind: []const u8,
    header: []const u8,
    line_start: u32,
    line_end: u32,
    depth: u32,
};

pub const Range = struct {
    line_start: u32,
    line_end: u32,
};

pub const View = struct {
    text: []u8,
    elided: []Range,
    outline: []Block,
    outline_total: usize,
    first_line: u32,
    last_line: u32,
    full_chars: usize,

    pub fn deinit(self: View, gpa: Allocator) void {
        gpa.free(self.text);
        gpa.free(self.elided);
        gpa.free(self.outline);
    }
};

pub const Lines = struct {
    starts: []u32,

    pub fn init(gpa: Allocator, source: []const u8) !Lines {
        var starts: std.ArrayList(u32) = .empty;
        errdefer starts.deinit(gpa);
        try starts.append(gpa, 0);
        for (source, 0..) |c, i| {
            if (c == '\n') try starts.append(gpa, @intCast(i + 1));
        }
        return .{ .starts = try starts.toOwnedSlice(gpa) };
    }

    pub fn deinit(self: Lines, gpa: Allocator) void {
        gpa.free(self.starts);
    }

    pub fn lineOf(self: Lines, byte: u32) u32 {
        var lo: usize = 0;
        var hi: usize = self.starts.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (self.starts[mid] <= byte) lo = mid + 1 else hi = mid;
        }
        return @intCast(lo);
    }

    pub fn startOf(self: Lines, line: u32) u32 {
        return self.starts[line - 1];
    }

    pub fn endOf(self: Lines, source: []const u8, line: u32) u32 {
        return if (line < self.starts.len) self.starts[line] else @intCast(source.len);
    }

    pub fn text(self: Lines, source: []const u8, line: u32) []const u8 {
        return source[self.startOf(line)..self.endOf(source, line)];
    }
};

pub const Detail = enum { budgeted, full };

pub fn parseDetail(value: ?[]const u8) error{UnknownDetail}!Detail {
    const text = value orelse return .budgeted;
    if (std.mem.eql(u8, text, "full")) return .full;
    if (std.mem.eql(u8, text, "budgeted")) return .budgeted;
    return error.UnknownDetail;
}

pub fn fold(gpa: Allocator, source: []const u8, lines: Lines, body: ts.Node, budget: usize) !?View {
    const start: u32 = body.startByte();
    const end: u32 = body.endByte();
    if (end - start <= budget) return null;
    var blocks: std.ArrayList(Block) = .empty;
    defer blocks.deinit(gpa);
    try collect(gpa, &blocks, source, lines, body, 0);

    const first_line = lines.lineOf(start);
    const last_line = lines.lineOf(end - 1);
    var max_depth: u32 = 0;
    for (blocks.items) |block| max_depth = @max(max_depth, block.depth);

    var folds: std.ArrayList(Range) = .empty;
    defer folds.deinit(gpa);
    var level: u32 = max_depth;
    var result = try renderLevel(gpa, source, lines, start, end, first_line, last_line, blocks.items, level, &folds);
    defer result.deinit(gpa);
    while (result.size > budget and level > 0) {
        level -= 1;
        const next = try renderLevel(gpa, source, lines, start, end, first_line, last_line, blocks.items, level, &folds);
        result.deinit(gpa);
        result = next;
    }
    if (result.size > budget) try cutTail(gpa, &result, source, lines, last_line, budget);

    var outline: std.ArrayList(Block) = .empty;
    errdefer outline.deinit(gpa);
    for (blocks.items) |block| {
        if (block.depth > outline_depth) continue;
        if (outline.items.len == max_outline) break;
        try outline.append(gpa, block);
    }
    var outline_total: usize = 0;
    for (blocks.items) |block| {
        if (block.depth <= outline_depth) outline_total += 1;
    }
    const text = try joinSegments(gpa, result.segments.items);
    errdefer gpa.free(text);
    const elided = try elidedRanges(gpa, result.segments.items);
    errdefer gpa.free(elided);
    return .{
        .text = text,
        .elided = elided,
        .outline = try outline.toOwnedSlice(gpa),
        .outline_total = outline_total,
        .first_line = first_line,
        .last_line = last_line,
        .full_chars = end - start,
    };
}

pub fn focus(gpa: Allocator, source: []const u8, lines: Lines, start: u32, end: u32, line_start: u32, line_end: u32) !View {
    const first_line = lines.lineOf(start);
    const last_line = lines.lineOf(end - 1);
    const shown_start = @max(line_start, first_line);
    const shown_end = @min(line_end, last_line);
    var folds: std.ArrayList(Range) = .empty;
    defer folds.deinit(gpa);
    if (shown_start > first_line + 1) try folds.append(gpa, .{ .line_start = first_line + 1, .line_end = shown_start - 1 });
    if (shown_end + 1 < last_line) try folds.append(gpa, .{ .line_start = shown_end + 1, .line_end = last_line - 1 });
    var result = try render(gpa, source, lines, start, end, first_line, last_line, folds.items);
    defer result.deinit(gpa);
    const text = try joinSegments(gpa, result.segments.items);
    errdefer gpa.free(text);
    return .{
        .text = text,
        .elided = try elidedRanges(gpa, result.segments.items),
        .outline = &.{},
        .outline_total = 0,
        .first_line = first_line,
        .last_line = last_line,
        .full_chars = end - start,
    };
}

pub fn elisionLine(gpa: Allocator, source: []const u8, lines: Lines, range: Range) ![]u8 {
    const first = lines.text(source, range.line_start);
    const last = lines.text(source, range.line_end);
    var indent_len: usize = 0;
    while (indent_len < first.len and (first[indent_len] == ' ' or first[indent_len] == '\t')) indent_len += 1;
    const eol: []const u8 = if (std.mem.endsWith(u8, last, "\r\n")) "\r\n" else "\n";
    return std.fmt.allocPrint(gpa, "{s}" ++ ellipsis ++ " lines {d}-{d} elided ({d} lines); read them with line_start/line_end{s}", .{ first[0..indent_len], range.line_start, range.line_end, range.line_end - range.line_start + 1, eol });
}

const Segment = struct {
    text: []const u8,
    owned: bool,
    line_start: u32,
    line_end: u32,
};

const Rendered = struct {
    segments: std.ArrayList(Segment),
    size: usize,

    fn deinit(self: Rendered, gpa: Allocator) void {
        for (self.segments.items) |segment| {
            if (segment.owned) gpa.free(segment.text);
        }
        var list = self.segments;
        list.deinit(gpa);
    }
};

fn renderLevel(gpa: Allocator, source: []const u8, lines: Lines, start: u32, end: u32, first_line: u32, last_line: u32, blocks: []const Block, level: u32, folds: *std.ArrayList(Range)) !Rendered {
    folds.clearRetainingCapacity();
    for (blocks) |block| {
        if (block.depth == level) try folds.append(gpa, .{ .line_start = block.line_start + 1, .line_end = block.line_end - 1 });
    }
    return render(gpa, source, lines, start, end, first_line, last_line, folds.items);
}

fn render(gpa: Allocator, source: []const u8, lines: Lines, start: u32, end: u32, first_line: u32, last_line: u32, folds: []const Range) !Rendered {
    var out: Rendered = .{ .segments = .empty, .size = 0 };
    errdefer out.deinit(gpa);
    var line = first_line;
    var next_fold: usize = 0;
    while (line <= last_line) {
        if (next_fold < folds.len and folds[next_fold].line_start == line) {
            const range = folds[next_fold];
            const text = try elisionLine(gpa, source, lines, range);
            errdefer gpa.free(text);
            try out.segments.append(gpa, .{ .text = text, .owned = true, .line_start = range.line_start, .line_end = range.line_end });
            out.size += text.len;
            line = range.line_end + 1;
            next_fold += 1;
            continue;
        }
        const from = @max(lines.startOf(line), start);
        const to = @min(lines.endOf(source, line), end);
        try out.segments.append(gpa, .{ .text = source[from..to], .owned = false, .line_start = line, .line_end = line });
        out.size += to - from;
        line += 1;
    }
    return out;
}

fn cutTail(gpa: Allocator, rendered: *Rendered, source: []const u8, lines: Lines, last_line: u32, budget: usize) !void {
    const segments = rendered.segments.items;
    if (segments.len < 3) return;
    const keep_budget = if (budget > tail_reserve) budget - tail_reserve else 0;
    var kept: usize = 0;
    var size: usize = 0;
    while (kept < segments.len - 1) : (kept += 1) {
        if (size + segments[kept].text.len > keep_budget) break;
        size += segments[kept].text.len;
    }
    if (kept == 0) kept = 1;
    if (kept >= segments.len - 1) return;
    const cut: Range = .{ .line_start = segments[kept].line_start, .line_end = segments[segments.len - 2].line_end };
    if (cut.line_end >= last_line) return;
    const text = try elisionLine(gpa, source, lines, cut);
    errdefer gpa.free(text);
    for (segments[kept .. segments.len - 1]) |segment| {
        if (segment.owned) gpa.free(segment.text);
    }
    const tail = segments[segments.len - 1];
    rendered.segments.shrinkRetainingCapacity(kept);
    try rendered.segments.append(gpa, .{ .text = text, .owned = true, .line_start = cut.line_start, .line_end = cut.line_end });
    try rendered.segments.append(gpa, tail);
    rendered.size = 0;
    for (rendered.segments.items) |segment| rendered.size += segment.text.len;
}

fn joinSegments(gpa: Allocator, segments: []const Segment) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (segments) |segment| try out.appendSlice(gpa, segment.text);
    return out.toOwnedSlice(gpa);
}

fn elidedRanges(gpa: Allocator, segments: []const Segment) ![]Range {
    var out: std.ArrayList(Range) = .empty;
    errdefer out.deinit(gpa);
    for (segments) |segment| {
        if (segment.owned) try out.append(gpa, .{ .line_start = segment.line_start, .line_end = segment.line_end });
    }
    return out.toOwnedSlice(gpa);
}

fn collect(gpa: Allocator, blocks: *std.ArrayList(Block), source: []const u8, lines: Lines, node: ts.Node, depth: u32) !void {
    var i: u32 = 0;
    while (node.child(i)) |child| : (i += 1) {
        var child_depth = depth;
        if (isBraceBlock(child)) {
            const line_start = lines.lineOf(child.startByte());
            const line_end = lines.lineOf(child.endByte() - 1);
            const foldable = line_end >= line_start + min_fold_lines + 1 and lines.startOf(line_end) - lines.startOf(line_start + 1) >= min_fold_bytes;
            if (foldable) {
                try blocks.append(gpa, .{
                    .kind = kindOf(child),
                    .header = header(lines.text(source, line_start)),
                    .line_start = line_start,
                    .line_end = line_end,
                    .depth = depth,
                });
                child_depth = depth + 1;
            }
        }
        try collect(gpa, blocks, source, lines, child, child_depth);
    }
}

fn isBraceBlock(node: ts.Node) bool {
    if (!node.isNamed()) return false;
    const count = node.childCount();
    if (count < 2) return false;
    const open = node.child(0) orelse return false;
    const close = node.child(count - 1) orelse return false;
    return std.mem.eql(u8, open.kind(), "{") and std.mem.eql(u8, close.kind(), "}");
}

fn kindOf(node: ts.Node) []const u8 {
    const own = node.kind();
    if (std.mem.endsWith(u8, own, "block") or std.mem.endsWith(u8, own, "body") or std.mem.endsWith(u8, own, "Block")) {
        if (node.parent()) |parent| return parent.kind();
    }
    return own;
}

fn header(line: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len <= max_header_bytes) return trimmed;
    var cut = max_header_bytes;
    while (cut > 0 and (trimmed[cut] & 0xC0) == 0x80) cut -= 1;
    return trimmed[0..cut];
}
