const std = @import("std");

const Allocator = std.mem.Allocator;

pub const replacement_hex = "FFFD";
const escape_len = 6;

pub fn parseLeaky(comptime T: type, arena: Allocator, input: []const u8, options: std.json.ParseOptions) !T {
    return std.json.parseFromSliceLeaky(T, arena, try withLoneSurrogatesReplaced(arena, input), options);
}

pub fn parse(comptime T: type, gpa: Allocator, input: []const u8, options: std.json.ParseOptions) !std.json.Parsed(T) {
    var parsed: std.json.Parsed(T) = .{ .arena = try gpa.create(std.heap.ArenaAllocator), .value = undefined };
    errdefer gpa.destroy(parsed.arena);
    parsed.arena.* = .init(gpa);
    errdefer parsed.arena.deinit();
    parsed.value = try parseLeaky(T, parsed.arena.allocator(), input, options);
    return parsed;
}

pub fn withLoneSurrogatesReplaced(arena: Allocator, input: []const u8) ![]const u8 {
    var copy: ?[]u8 = null;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] != '\\' or i + 1 >= input.len) {
            i += 1;
            continue;
        }
        const unit = escapedUnit(input, i) orelse {
            i += 2;
            continue;
        };
        if (isHigh(unit)) {
            if (escapedUnit(input, i + escape_len)) |next| {
                if (isLow(next)) {
                    i += 2 * escape_len;
                    continue;
                }
            }
        } else if (!isLow(unit)) {
            i += escape_len;
            continue;
        }
        if (copy == null) copy = try arena.dupe(u8, input);
        @memcpy(copy.?[i + 2 .. i + escape_len], replacement_hex);
        i += escape_len;
    }
    return copy orelse input;
}

fn escapedUnit(input: []const u8, at: usize) ?u16 {
    if (at + escape_len > input.len or input[at] != '\\' or input[at + 1] != 'u') return null;
    return std.fmt.parseInt(u16, input[at + 2 .. at + escape_len], 16) catch null;
}

fn isHigh(unit: u16) bool {
    return unit >= 0xD800 and unit <= 0xDBFF;
}

fn isLow(unit: u16) bool {
    return unit >= 0xDC00 and unit <= 0xDFFF;
}

const testing = std.testing;

fn decodeString(arena: Allocator, input: []const u8) ![]const u8 {
    const value = try parseLeaky(std.json.Value, arena, input, .{});
    return value.string;
}

test "a lone high surrogate escape decodes as U+FFFD and the text around it is kept" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("cut \u{FFFD} here", try decodeString(arena.allocator(), "\"cut \\uD83D here\""));
    try testing.expectEqualStrings("end\u{FFFD}", try decodeString(arena.allocator(), "\"end\\uD83D\""));
    try testing.expectEqualStrings("\u{FFFD}A", try decodeString(arena.allocator(), "\"\\uD83D\\u0041\""));
}

test "a lone low surrogate escape decodes as U+FFFD and the text around it is kept" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("cut \u{FFFD} here", try decodeString(arena.allocator(), "\"cut \\uDE00 here\""));
    try testing.expectEqualStrings("\u{FFFD}\u{FFFD}", try decodeString(arena.allocator(), "\"\\uDE00\\uD83D\""));
}

test "a valid surrogate pair escape still decodes as the one character it names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("smile \u{1F600}", try decodeString(arena.allocator(), "\"smile \\uD83D\\uDE00\""));
    try testing.expectEqualStrings("\\uD83D", try decodeString(arena.allocator(), "\"\\\\uD83D\""));
    const plain = "{\"a\":\"\\u00e9\"}";
    try testing.expectEqual(@as([*]const u8, plain.ptr), (try withLoneSurrogatesReplaced(arena.allocator(), plain)).ptr);
}

test "parse keeps the repaired text alive for as long as the parsed value" {
    const parsed = try parse(std.json.Value, testing.allocator, "{\"p\":\"x\\uD83D\"}", .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("x\u{FFFD}", parsed.value.object.get("p").?.string);
}
