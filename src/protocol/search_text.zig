const std = @import("std");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const json_width: usize = 200;
pub const text_width: usize = 120;
pub const legend_min_chars: usize = 8;
pub const ellipsis = "\u{2026}";

pub fn snippet(gpa: Allocator, line: []const u8, col: usize, width: usize) ![]u8 {
    const body = std.mem.trim(u8, line, " \t\r");
    if (body.len <= width) return gpa.dupe(u8, body);
    const lead = @intFromPtr(body.ptr) - @intFromPtr(line.ptr);
    const at = @min(body.len, col -| lead);
    var start = at -| width / 3;
    var end = @min(body.len, start + width);
    if (end - start < width) start = end -| width;
    while (start > 0 and start < body.len and isContinuation(body[start])) start += 1;
    while (end < body.len and end > start and isContinuation(body[end])) end -= 1;
    const head: []const u8 = if (start > 0) ellipsis else "";
    const tail: []const u8 = if (end < body.len) ellipsis else "";
    return std.mem.concat(gpa, u8, &.{ head, body[start..end], tail });
}

fn isContinuation(byte: u8) bool {
    return byte & 0xC0 == 0x80;
}

pub const Line = struct {
    file: []const u8,
    line: u32,
    text: []const u8,
    definition: bool = false,
};

pub fn writeLines(gpa: Allocator, w: *Writer, lines: []const Line) !void {
    const order = try gpa.alloc(usize, lines.len);
    defer gpa.free(order);
    var first_seen: std.StringArrayHashMapUnmanaged(usize) = .empty;
    defer first_seen.deinit(gpa);
    for (lines) |l| {
        const got = try first_seen.getOrPut(gpa, l.file);
        if (!got.found_existing) got.value_ptr.* = first_seen.count() - 1;
    }
    for (order, 0..) |*o, i| o.* = i;
    const Ctx = struct {
        lines: []const Line,
        rank: *const std.StringArrayHashMapUnmanaged(usize),
        fn less(ctx: @This(), a: usize, b: usize) bool {
            const ra = ctx.rank.get(ctx.lines[a].file).?;
            const rb = ctx.rank.get(ctx.lines[b].file).?;
            if (ra != rb) return ra < rb;
            return ctx.lines[a].line < ctx.lines[b].line;
        }
    };
    std.mem.sort(usize, order, Ctx{ .lines = lines, .rank = &first_seen }, Ctx.less);

    var counts: std.StringHashMapUnmanaged(u32) = .empty;
    defer counts.deinit(gpa);
    for (lines) |l| {
        if (l.text.len < legend_min_chars) continue;
        const got = try counts.getOrPut(gpa, l.text);
        got.value_ptr.* = if (got.found_existing) got.value_ptr.* + 1 else 1;
    }
    var ids: std.StringHashMapUnmanaged(u32) = .empty;
    defer ids.deinit(gpa);
    var legend: std.ArrayList([]const u8) = .empty;
    defer legend.deinit(gpa);
    for (order) |i| {
        const text = lines[i].text;
        if ((counts.get(text) orelse 0) < 2 or ids.contains(text)) continue;
        try legend.append(gpa, text);
        try ids.put(gpa, text, @intCast(legend.items.len));
    }
    for (legend.items, 1..) |text, id| try w.print("|{d} {s}\n", .{ id, text });

    var current: ?[]const u8 = null;
    for (order) |i| {
        const l = lines[i];
        if (current == null or !std.mem.eql(u8, current.?, l.file)) {
            try w.print("{s}\n", .{l.file});
            current = l.file;
        }
        const mark: []const u8 = if (l.definition) "*" else "";
        if (ids.get(l.text)) |id| {
            try w.print("{d}{s}|{d}\n", .{ l.line, mark, id });
        } else {
            try w.print("{d}{s}:{s}\n", .{ l.line, mark, l.text });
        }
    }
}

pub fn lineCost(l: Line) usize {
    return digits(l.line) + @intFromBool(l.definition) + 2 + l.text.len;
}

pub fn digits(n: u32) usize {
    var count: usize = 1;
    var rest = n / 10;
    while (rest != 0) : (rest /= 10) count += 1;
    return count;
}

const testing = std.testing;

fn render(lines: []const Line) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try writeLines(testing.allocator, &out.writer, lines);
    return out.toOwnedSlice();
}

test "search text: files keep the order they first appear in, lines sort by number and a definition is starred" {
    const lines = [_]Line{
        .{ .file = "src/b.ts", .line = 9, .text = "use(b)" },
        .{ .file = "src/a.ts", .line = 3, .text = "export function a() {", .definition = true },
        .{ .file = "src/b.ts", .line = 2, .text = "x" },
    };
    const text = try render(&lines);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("src/b.ts\n2:x\n9:use(b)\nsrc/a.ts\n3*:export function a() {\n", text);
}

test "search text: a line text met twice or more is written once in a legend and referenced by number" {
    const lines = [_]Line{
        .{ .file = "a.js", .line = 1, .text = "var express = require('express');" },
        .{ .file = "a.js", .line = 4, .text = "short" },
        .{ .file = "b.js", .line = 2, .text = "var express = require('express');" },
        .{ .file = "c.js", .line = 7, .text = "short" },
        .{ .file = "c.js", .line = 9, .text = "var express = require('express');" },
    };
    const text = try render(&lines);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("|1 var express = require('express');\na.js\n1|1\n4:short\nb.js\n2|1\nc.js\n7:short\n9|1\n", text);
}

test "search text: a long line is cut to a window around the match and says so with an ellipsis at each cut end" {
    const long = "x" ** 300 ++ "needle" ++ "y" ** 300;
    const cut = try snippet(testing.allocator, "    " ++ long, 4 + 300, 60);
    defer testing.allocator.free(cut);
    try testing.expect(std.mem.startsWith(u8, cut, ellipsis));
    try testing.expect(std.mem.endsWith(u8, cut, ellipsis));
    try testing.expect(std.mem.indexOf(u8, cut, "needle") != null);
    try testing.expectEqual(@as(usize, 60 + 2 * ellipsis.len), cut.len);

    const short = try snippet(testing.allocator, "\t  return 1;\r", 4, 60);
    defer testing.allocator.free(short);
    try testing.expectEqualStrings("return 1;", short);
    const at_end = try snippet(testing.allocator, "a" ** 100 ++ "needle", 100, 40);
    defer testing.allocator.free(at_end);
    try testing.expect(std.mem.startsWith(u8, at_end, ellipsis));
    try testing.expect(std.mem.endsWith(u8, at_end, "needle"));
    const wide = try snippet(testing.allocator, "\u{00e7}" ** 80, 0, 41);
    defer testing.allocator.free(wide);
    try testing.expect(std.unicode.utf8ValidateSlice(wide));
}
