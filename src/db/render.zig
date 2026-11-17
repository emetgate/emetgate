const std = @import("std");
const engine = @import("engine.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Format = enum {
    json,
    csv,
    markdown,

    pub fn parse(text: []const u8) ?Format {
        if (std.ascii.eqlIgnoreCase(text, "md")) return .markdown;
        return std.meta.stringToEnum(Format, text);
    }
};

pub const max_blob_hex = 64;

pub const Rows = struct {
    gpa: Allocator,
    format: Format,
    max_cell_chars: u32,
    max_bytes: u32,
    columns: []const engine.ResultColumn = &.{},
    body: Writer.Allocating,
    line: Writer.Allocating,
    rows: usize = 0,
    cut_cells: usize = 0,

    pub fn init(gpa: Allocator, format: Format, limits: engine.Limits) Rows {
        return .{
            .gpa = gpa,
            .format = format,
            .max_cell_chars = limits.max_cell_chars,
            .max_bytes = limits.max_result_bytes,
            .body = .init(gpa),
            .line = .init(gpa),
        };
    }

    pub fn deinit(self: *Rows) void {
        self.body.deinit();
        self.line.deinit();
    }

    pub fn sink(self: *Rows) engine.Sink {
        return .{ .ptr = self, .begin = begin, .row = row };
    }

    pub fn written(self: *Rows) []const u8 {
        return self.body.written();
    }

    fn begin(ptr: *anyopaque, columns: []const engine.ResultColumn) anyerror!void {
        const self: *Rows = @ptrCast(@alignCast(ptr));
        self.columns = columns;
    }

    fn row(ptr: *anyopaque, values: []const engine.Value) anyerror!bool {
        const self: *Rows = @ptrCast(@alignCast(ptr));
        self.line.clearRetainingCapacity();
        var cut: usize = 0;
        const w = &self.line.writer;
        switch (self.format) {
            .json => {
                if (self.rows != 0) try w.writeByte(',');
                try w.writeByte('[');
                for (values, 0..) |value, i| {
                    if (i != 0) try w.writeByte(',');
                    cut += try self.jsonCell(w, value);
                }
                try w.writeByte(']');
            },
            .csv => {
                for (values, 0..) |value, i| {
                    if (i != 0) try w.writeByte(',');
                    cut += try self.textCell(w, value, .csv);
                }
                try w.writeByte('\n');
            },
            .markdown => {
                try w.writeAll("|");
                for (values) |value| {
                    try w.writeByte(' ');
                    cut += try self.textCell(w, value, .markdown);
                    try w.writeAll(" |");
                }
                try w.writeByte('\n');
            },
        }
        if (self.body.written().len + self.line.written().len > self.max_bytes) return false;
        try self.body.writer.writeAll(self.line.written());
        self.rows += 1;
        self.cut_cells += cut;
        return true;
    }

    fn clipped(self: *const Rows, text: []const u8) struct { kept: []const u8, left: usize } {
        var chars: usize = 0;
        var i: usize = 0;
        while (i < text.len) {
            if (chars == self.max_cell_chars) {
                var rest: usize = 0;
                for (text[i..]) |ch| {
                    if ((ch & 0xC0) != 0x80) rest += 1;
                }
                return .{ .kept = text[0..i], .left = rest };
            }
            i += std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            chars += 1;
        }
        return .{ .kept = text, .left = 0 };
    }

    fn jsonCell(self: *const Rows, w: *Writer, value: engine.Value) !usize {
        switch (value) {
            .null => try w.writeAll("null"),
            .integer => |n| try w.print("{d}", .{n}),
            .real => |f| {
                if (std.math.isFinite(f)) {
                    try w.print("{d}", .{f});
                } else {
                    try std.json.Stringify.value(if (std.math.isNan(f)) "NaN" else if (f > 0) "Infinity" else "-Infinity", .{}, w);
                }
            },
            .text => |text| {
                const part = self.clipped(text);
                try w.writeByte('"');
                try std.json.Stringify.encodeJsonStringChars(validUtf8Prefix(part.kept), .{}, w);
                if (part.left != 0) try w.print("\\u2026[+{d} chars]", .{part.left});
                try w.writeByte('"');
                return @intFromBool(part.left != 0);
            },
            .blob => |bytes| {
                try w.writeByte('"');
                try writeBlob(w, bytes);
                try w.writeByte('"');
            },
        }
        return 0;
    }

    const Plain = enum { csv, markdown };

    fn textCell(self: *const Rows, w: *Writer, value: engine.Value, how: Plain) !usize {
        var cell: Writer.Allocating = .init(self.gpa);
        defer cell.deinit();
        var cut: usize = 0;
        switch (value) {
            .null => if (how == .markdown) try cell.writer.writeAll("NULL"),
            .integer => |n| try cell.writer.print("{d}", .{n}),
            .real => |f| try cell.writer.print("{d}", .{f}),
            .text => |text| {
                const part = self.clipped(text);
                try cell.writer.writeAll(validUtf8Prefix(part.kept));
                if (part.left != 0) {
                    try cell.writer.print("\u{2026}[+{d} chars]", .{part.left});
                    cut = 1;
                }
            },
            .blob => |bytes| try writeBlob(&cell.writer, bytes),
        }
        const text = cell.written();
        switch (how) {
            .csv => {
                if (std.mem.indexOfAny(u8, text, ",\"\r\n") == null) {
                    try w.writeAll(text);
                    return cut;
                }
                try w.writeByte('"');
                for (text) |ch| {
                    if (ch == '"') try w.writeByte('"');
                    try w.writeByte(ch);
                }
                try w.writeByte('"');
            },
            .markdown => {
                for (text) |ch| switch (ch) {
                    '|' => try w.writeAll("\\|"),
                    '\n' => try w.writeAll("<br>"),
                    '\r' => {},
                    else => try w.writeByte(ch),
                };
            },
        }
        return cut;
    }
};

fn writeBlob(w: *Writer, bytes: []const u8) !void {
    if (bytes.len > max_blob_hex) return w.print("<blob {d} bytes>", .{bytes.len});
    try w.writeAll("x'");
    for (bytes) |b| try w.print("{x:0>2}", .{b});
    try w.writeByte('\'');
}

fn validUtf8Prefix(text: []const u8) []const u8 {
    if (std.unicode.utf8ValidateSlice(text)) return text;
    var end: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch break;
        if (i + len > text.len) break;
        _ = std.unicode.utf8Decode(text[i .. i + len]) catch break;
        i += len;
        end = i;
    }
    return text[0..end];
}

pub fn writeHeader(w: *Writer, format: Format, columns: []const engine.ResultColumn) !void {
    switch (format) {
        .json => {},
        .csv => {
            for (columns, 0..) |column, i| {
                if (i != 0) try w.writeByte(',');
                if (std.mem.indexOfAny(u8, column.name, ",\"\r\n") == null) {
                    try w.writeAll(column.name);
                } else {
                    try w.writeByte('"');
                    for (column.name) |ch| {
                        if (ch == '"') try w.writeByte('"');
                        try w.writeByte(ch);
                    }
                    try w.writeByte('"');
                }
            }
            try w.writeByte('\n');
        },
        .markdown => {
            try w.writeAll("|");
            for (columns) |column| try w.print(" {s} |", .{column.name});
            try w.writeAll("\n|");
            for (columns) |_| try w.writeAll(" --- |");
            try w.writeByte('\n');
        },
    }
}

const testing = std.testing;

fn feed(format: Format, limits: engine.Limits, rows: []const []const engine.Value) !struct { text: []u8, shown: usize, cut: usize } {
    var out: Rows = .init(testing.allocator, format, limits);
    defer out.deinit();
    const s = out.sink();
    try s.begin(s.ptr, &.{ .{ .name = "a" }, .{ .name = "b" } });
    for (rows) |values| {
        if (!try s.row(s.ptr, values)) break;
    }
    return .{ .text = try testing.allocator.dupe(u8, out.written()), .shown = out.rows, .cut = out.cut_cells };
}

test "db render: json rows carry typed cells, a long cell is cut with a count, and a blob is hex or its size" {
    const got = try feed(.json, .{ .max_cell_chars = 3 }, &.{
        &.{ .{ .integer = 7 }, .{ .text = "abcdef" } },
        &.{ .null, .{ .blob = "\x01\xff" } },
        &.{ .{ .real = 1.5 }, .{ .text = "a\"b" } },
    });
    defer testing.allocator.free(got.text);
    try testing.expectEqualStrings("[7,\"abc\\u2026[+3 chars]\"],[null,\"x'01ff'\"],[1.5,\"a\\\"b\"]", got.text);
    try testing.expectEqual(@as(usize, 1), got.cut);
}

test "db render: csv quotes what needs it and markdown escapes pipes and newlines" {
    const csv = try feed(.csv, .{}, &.{&.{ .{ .text = "x,y" }, .{ .text = "q\"" } }});
    defer testing.allocator.free(csv.text);
    try testing.expectEqualStrings("\"x,y\",\"q\"\"\"\n", csv.text);
    const md = try feed(.markdown, .{}, &.{&.{ .{ .text = "a|b" }, .{ .text = "l1\nl2" } }});
    defer testing.allocator.free(md.text);
    try testing.expectEqualStrings("| a\\|b | l1<br>l2 |\n", md.text);
}

test "db render: the byte cap stops at the first row that does not fit and keeps whole rows only" {
    const got = try feed(.csv, .{ .max_result_bytes = 10 }, &.{
        &.{ .{ .text = "aaa" }, .{ .text = "bb" } },
        &.{ .{ .text = "ccc" }, .{ .text = "dd" } },
    });
    defer testing.allocator.free(got.text);
    try testing.expectEqualStrings("aaa,bb\n", got.text);
    try testing.expectEqual(@as(usize, 1), got.shown);
}
