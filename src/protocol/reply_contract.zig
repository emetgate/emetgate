//! The reply contract of the read tools: no read reply is unbounded, and
//! whatever a reply leaves out is named in one trailer line that gives the
//! exact call returning the rest.
//!
//! A tool renders its payload, cuts it with `cut` against `room(tool)`, and
//! when the cut kept less than everything ends its reply with `writeTrailer`:
//!
//!     [left out: lines 5001-400000 (20537812 bytes); continue with emetgate_read_file {"file":"huge.log","line_start":5001,"line_end":400000}]
//!
//! The trailer is the last line of the reply, after the JSON (or raw) payload,
//! so a client that parses the first line still parses it. `cut` keeps whole
//! lines; only a single line longer than the room is cut inside, on a UTF-8
//! boundary, and the trailer then states the byte offset to resume from.
//!
//! API:
//!   budget(tool) usize              chars (bytes) one reply of the tool may hold
//!   room(tool) usize                budget minus `reserve`: what the payload may use
//!   cut(text, limit, encoding) Cut  the longest prefix that fits, at a line end
//!   encodedLen(text, encoding)      the size of text once written (JSON escapes count)
//!   writeTrailer(w, left_fmt, left_args, tool, call_args)
//!   findTrailer(reply) ?[]const u8  the trailer line of a reply, if any
//!   within(tool, reply) bool        the reply fits its tool's budget
const std = @import("std");

const Writer = std.Io.Writer;

/// Every tool that reads; each has one entry in `table`.
pub const Tool = enum {
    read_file,
    read_file_many,
    list,
    read_symbol,
    skeleton,
    symbols,
    expand,
    search,
    find,
    explore,
    evidence,
    git,
    scan,
    mutate,
};

/// The one budget table, in chars (bytes of UTF-8) per reply.
pub const table = std.enums.EnumArray(Tool, usize).init(.{
    .read_file = 24_000,
    .read_file_many = 64 * 1024,
    .list = 16_000,
    .read_symbol = 24_000,
    .skeleton = 24_000,
    .symbols = 16_000,
    .expand = 24_000,
    .search = 24_000,
    .find = 16_000,
    .explore = 24_000,
    .evidence = 24_000,
    .git = 24_000,
    .scan = 16_000,
    .mutate = 24_000,
});

pub const default_budget: usize = 24_000;

/// Room kept free in every reply for the header fields and the trailer.
pub const reserve: usize = 1536;

pub fn budget(tool: Tool) usize {
    return table.get(tool);
}

pub fn room(tool: Tool) usize {
    return budget(tool) - reserve;
}

pub const Encoding = enum {
    /// The text goes into the reply as it is.
    plain,
    /// The text goes into a JSON string: quotes, backslashes and control
    /// characters cost their escape.
    json,
};

fn cost(byte: u8, encoding: Encoding) usize {
    if (encoding == .plain) return 1;
    return switch (byte) {
        '"', '\\', '\n', '\r', '\t', 0x08, 0x0C => 2,
        0...0x07, 0x0B, 0x0E...0x1F => 6,
        else => 1,
    };
}

pub fn encodedLen(text: []const u8, encoding: Encoding) usize {
    if (encoding == .plain) return text.len;
    var n: usize = 0;
    for (text) |c| n += cost(c, encoding);
    return n;
}

pub const Cut = struct {
    /// The prefix of the text that fits.
    kept: []const u8,
    /// Whole lines in `kept` (a line ends with '\n'; a last line without one
    /// counts when the whole text was kept).
    lines: usize,
    /// Everything was kept.
    whole: bool,
    /// `kept` ends inside a line: the first line alone was over the limit.
    split_line: bool,

    /// Bytes left out.
    pub fn rest(self: Cut, text: []const u8) usize {
        return text.len - self.kept.len;
    }
};

/// The longest prefix of `text` whose encoded size is at most `limit` and that
/// ends at a line end. When not even the first line fits, the first line is
/// cut on a UTF-8 boundary and `split_line` is set. Stops reading at the
/// limit, so a 20 MB text costs no more than the room it fills.
pub fn cut(text: []const u8, limit: usize, encoding: Encoding) Cut {
    var used: usize = 0;
    var newlines: usize = 0;
    var line_end: ?usize = null;
    var line_count: usize = 0;
    for (text, 0..) |c, i| {
        used += cost(c, encoding);
        if (used > limit) {
            if (line_end) |end| return .{ .kept = text[0..end], .lines = line_count, .whole = false, .split_line = false };
            var end = i;
            while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
            return .{ .kept = text[0..end], .lines = 0, .whole = false, .split_line = true };
        }
        if (c == '\n') {
            newlines += 1;
            line_end = i + 1;
            line_count = newlines;
        }
    }
    const trailing: usize = @intFromBool(text.len != 0 and text[text.len - 1] != '\n');
    return .{ .kept = text, .lines = newlines + trailing, .whole = true, .split_line = false };
}

/// Moves `offset` forward to the next UTF-8 character start, clamped to the text.
pub fn charStart(text: []const u8, offset: usize) usize {
    var at = @min(offset, text.len);
    while (at < text.len and (text[at] & 0xC0) == 0x80) at += 1;
    return at;
}

pub const trailer_open = "[left out: ";
pub const trailer_join = "; continue with ";

/// Writes the trailer line: `[left out: <left>; continue with <tool> <args as JSON>]`.
/// `call_args` is a struct whose fields are the exact arguments of the call
/// that returns what was left out; null optional fields are not written.
pub fn writeTrailer(w: *Writer, comptime left_fmt: []const u8, left_args: anytype, tool: []const u8, call_args: anytype) Writer.Error!void {
    try w.writeAll(trailer_open);
    try w.print(left_fmt, left_args);
    try w.writeAll(trailer_join);
    try w.writeAll(tool);
    try w.writeByte(' ');
    var js: std.json.Stringify = .{ .writer = w, .options = .{ .emit_null_optional_fields = false } };
    try js.write(call_args);
    try w.writeAll("]\n");
}

/// The trailer line of a reply (without its newline), or null when the reply
/// has none. Only a line that starts with `trailer_open` counts.
pub fn findTrailer(reply: []const u8) ?[]const u8 {
    const body = std.mem.trimEnd(u8, reply, "\n");
    const start = if (std.mem.lastIndexOfScalar(u8, body, '\n')) |nl| nl + 1 else 0;
    const line = body[start..];
    if (!std.mem.startsWith(u8, line, trailer_open)) return null;
    if (std.mem.indexOf(u8, line, trailer_join) == null) return null;
    if (!std.mem.endsWith(u8, line, "]")) return null;
    return line;
}

pub fn within(tool: Tool, reply: []const u8) bool {
    return reply.len <= budget(tool);
}

const testing = std.testing;

test "reply contract: cut keeps whole lines that fit, or splits a first line that alone is over" {
    const text = "aaaa\nbbbb\ncccc\n";
    const two = cut(text, 11, .plain);
    try testing.expectEqualStrings("aaaa\nbbbb\n", two.kept);
    try testing.expectEqual(@as(usize, 2), two.lines);
    try testing.expect(!two.whole and !two.split_line);
    const all = cut(text, 100, .plain);
    try testing.expect(all.whole);
    try testing.expectEqual(@as(usize, 3), all.lines);
    const split = cut("abcdef", 4, .plain);
    try testing.expectEqualStrings("abcd", split.kept);
    try testing.expect(split.split_line);
    try testing.expectEqual(@as(usize, 1), cut("abc", 10, .plain).lines);
}

test "reply contract: JSON escapes count against the limit and a split never lands inside a character" {
    try testing.expectEqual(@as(usize, 4), encodedLen("a\nb", .json));
    try testing.expectEqualStrings("a\n", cut("a\nbb\n", 4, .json).kept);
    const s = cut("\u{00e9}\u{00e9}\u{00e9}", 3, .plain);
    try testing.expectEqualStrings("\u{00e9}", s.kept);
    try testing.expectEqual(@as(usize, 2), charStart("\u{00e9}x", 1));
}

test "reply contract: the trailer is one line with the call as JSON, and findTrailer finds only it" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"file\":\"a\"}\n");
    try writeTrailer(&out.writer, "lines {d}-{d}", .{ 3, 9 }, "emetgate_read_file", .{ .file = "a", .line_start = @as(usize, 3), .offset = @as(?usize, null) });
    try testing.expectEqualStrings("{\"file\":\"a\"}\n[left out: lines 3-9; continue with emetgate_read_file {\"file\":\"a\",\"line_start\":3}]\n", out.written());
    try testing.expectEqualStrings("[left out: lines 3-9; continue with emetgate_read_file {\"file\":\"a\",\"line_start\":3}]", findTrailer(out.written()).?);
    try testing.expect(findTrailer("{\"file\":\"a\"}\n") == null);
    for (std.enums.values(Tool)) |tool| try testing.expect(budget(tool) > reserve);
}
