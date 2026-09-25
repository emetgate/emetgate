const std = @import("std");
const symbol = @import("symbol.zig");

const Allocator = std.mem.Allocator;
const Table = symbol.Table;
const Symbol = symbol.Symbol;

pub const Error = error{ InvalidLineRange, LineOutOfRange, NoSymbolInRange } || Allocator.Error;

pub fn byteRangeForLines(source: []const u8, line_start: u32, line_end: u32) Error!symbol.Span {
    if (line_start == 0 or line_end == 0 or line_start > line_end) return error.InvalidLineRange;
    var line: u32 = 1;
    var start: ?u32 = null;
    var i: u32 = 0;
    while (i < source.len) : (i += 1) {
        if (line == line_start and start == null) start = i;
        if (line == line_end + 1) return .{ .start = start orelse return error.LineOutOfRange, .end = i };
        if (source[i] == '\n') line += 1;
    }
    if (start == null) return error.LineOutOfRange;
    return .{ .start = start.?, .end = @intCast(source.len) };
}

pub fn overlaps(a: symbol.Span, b: symbol.Span) bool {
    return a.start < b.end and b.start < a.end;
}

pub fn symbolsOverlapping(gpa: Allocator, table: Table, range: symbol.Span) Error![]const *const Symbol {
    var out: std.ArrayList(*const Symbol) = .empty;
    errdefer out.deinit(gpa);
    for (table.symbols) |*entry| {
        if (overlaps(entry.declaration, range)) try out.append(gpa, entry);
    }
    if (out.items.len == 0) return error.NoSymbolInRange;
    return try out.toOwnedSlice(gpa);
}

const testing = std.testing;

test "byteRangeForLines finds the byte span covering the requested inclusive line range" {
    const source = "aaa\nbbb\nccc\nddd\n";
    const range = try byteRangeForLines(source, 2, 3);
    try testing.expectEqualStrings("bbb\nccc\n", source[range.start..range.end]);
}

test "byteRangeForLines rejects an inverted or zero-based range" {
    const source = "aaa\nbbb\n";
    try testing.expectError(error.InvalidLineRange, byteRangeForLines(source, 0, 1));
    try testing.expectError(error.InvalidLineRange, byteRangeForLines(source, 3, 2));
}

test "byteRangeForLines rejects a start line past the end of the file" {
    const source = "aaa\nbbb\n";
    try testing.expectError(error.LineOutOfRange, byteRangeForLines(source, 10, 12));
}

test "overlaps rejects two spans that only touch at a shared boundary point" {
    try testing.expect(!overlaps(.{ .start = 0, .end = 5 }, .{ .start = 5, .end = 10 }));
    try testing.expect(!overlaps(.{ .start = 5, .end = 10 }, .{ .start = 0, .end = 5 }));
}

test "overlaps accepts two spans that share at least one byte" {
    try testing.expect(overlaps(.{ .start = 0, .end = 6 }, .{ .start = 5, .end = 10 }));
    try testing.expect(overlaps(.{ .start = 2, .end = 8 }, .{ .start = 2, .end = 8 }));
}

test "byteRangeForLines clamps the end of the last line to the end of the file" {
    const source = "aaa\nbbb";
    const range = try byteRangeForLines(source, 2, 5);
    try testing.expectEqualStrings("bbb", source[range.start..range.end]);
}
