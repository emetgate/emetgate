const std = @import("std");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Writer = std.Io.Writer;

pub const Error = error{ UnsupportedNumber, InvalidUtf8 } || Writer.Error || Allocator.Error;

const max_safe_integer: i64 = 9007199254740991;

pub fn parse(gpa: Allocator, bytes: []const u8) !std.json.Parsed(Value) {
    return std.json.parseFromSlice(Value, gpa, bytes, .{ .duplicate_field_behavior = .@"error", .allocate = .alloc_always });
}

pub fn canonicalize(gpa: Allocator, value: Value) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try write(gpa, value, &out.writer);
    return out.toOwnedSlice();
}

pub fn write(gpa: Allocator, value: Value, w: *Writer) Error!void {
    switch (value) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |n| {
            if (n > max_safe_integer or n < -max_safe_integer) return error.UnsupportedNumber;
            try w.print("{d}", .{n});
        },
        .float, .number_string => return error.UnsupportedNumber,
        .string => |s| try writeString(s, w),
        .array => |list| {
            try w.writeByte('[');
            for (list.items, 0..) |item, i| {
                if (i != 0) try w.writeByte(',');
                try write(gpa, item, w);
            }
            try w.writeByte(']');
        },
        .object => |object| {
            const keys = try gpa.dupe([]const u8, object.keys());
            defer gpa.free(keys);
            for (keys) |k| if (!std.unicode.utf8ValidateSlice(k)) return error.InvalidUtf8;
            std.mem.sort([]const u8, keys, {}, lessUtf16);
            try w.writeByte('{');
            for (keys, 0..) |key, i| {
                if (i != 0) try w.writeByte(',');
                try writeString(key, w);
                try w.writeByte(':');
                try write(gpa, object.get(key).?, w);
            }
            try w.writeByte('}');
        },
    }
}

fn writeString(s: []const u8, w: *Writer) Error!void {
    if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidUtf8;
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        0x08 => try w.writeAll("\\b"),
        0x0c => try w.writeAll("\\f"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...0x07, 0x0b, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

const Units = struct {
    view: std.unicode.Utf8Iterator,
    low: ?u16 = null,

    fn next(self: *Units) ?u16 {
        if (self.low) |low| {
            self.low = null;
            return low;
        }
        const cp = self.view.nextCodepoint() orelse return null;
        if (cp < 0x10000) return @intCast(cp);
        const v = cp - 0x10000;
        self.low = @intCast(0xDC00 + (v & 0x3FF));
        return @intCast(0xD800 + (v >> 10));
    }
};

fn lessUtf16(_: void, a: []const u8, b: []const u8) bool {
    var x: Units = .{ .view = (std.unicode.Utf8View.initUnchecked(a)).iterator() };
    var y: Units = .{ .view = (std.unicode.Utf8View.initUnchecked(b)).iterator() };
    while (true) {
        const p = x.next();
        const q = y.next();
        if (p == null) return q != null;
        if (q == null) return false;
        if (p.? != q.?) return p.? < q.?;
    }
}

const testing = std.testing;

fn roundTrip(input: []const u8) ![]u8 {
    const parsed = try parse(testing.allocator, input);
    defer parsed.deinit();
    return canonicalize(testing.allocator, parsed.value);
}

test "jcs: members are sorted, whitespace dropped and nested values kept" {
    const out = try roundTrip("{ \"b\": 1, \"a\": [true, null, \"x\", {\"z\": false, \"y\": -3}] }");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"a\":[true,null,\"x\",{\"y\":-3,\"z\":false}],\"b\":1}", out);
}

test "jcs: keys sort by UTF-16 code units, so an emoji comes before U+FB33 (RFC 8785 section 3.2.3)" {
    const out = try roundTrip("{\"\\u20ac\":1,\"\\r\":2,\"\\ufb33\":3,\"1\":4,\"\\ud83d\\ude00\":5,\"\\u0080\":6,\"\\u00f6\":7}");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"\\r\":2,\"1\":4,\"\u{80}\":6,\"\u{f6}\":7,\"\u{20ac}\":1,\"\u{1f600}\":5,\"\u{fb33}\":3}", out);
}

test "jcs: strings escape only quote, backslash and control characters, with lowercase hex" {
    const out = try roundTrip("[\"a\\\"b\\\\c\\u0001\\u001f\\n\\t\\u00e9\\u2028\"]");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[\"a\\\"b\\\\c\\u0001\\u001f\\n\\t\u{e9}\u{2028}\"]", out);
}

test "jcs: a fraction, an exponent, an unsafe integer and a duplicate key are refused" {
    for ([_][]const u8{ "[1.5]", "[1e3]", "[9007199254740993]" }) |input| {
        const parsed = try parse(testing.allocator, input);
        defer parsed.deinit();
        try testing.expectError(error.UnsupportedNumber, canonicalize(testing.allocator, parsed.value));
    }
    try testing.expectError(error.DuplicateField, parse(testing.allocator, "{\"a\":1,\"a\":2}"));
}
