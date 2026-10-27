const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

pub const replacement = "\u{FFFD}";
const utf8_code_page: u32 = 65001;
const max_sequence = 4;

pub fn oemCodePage() u32 {
    if (builtin.os.tag != .windows) return utf8_code_page;
    return GetOEMCP();
}

pub fn validPrefix(bytes: []const u8) usize {
    var index: usize = 0;
    while (index < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[index]) catch return index;
        if (index + len > bytes.len) return index;
        _ = std.unicode.utf8Decode(bytes[index..][0..len]) catch return index;
        index += len;
    }
    return index;
}

pub fn replaceInvalid(gpa: Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var index: usize = 0;
    while (index < bytes.len) {
        const len = validPrefix(bytes[index..]);
        try out.appendSlice(gpa, bytes[index..][0..len]);
        index += len;
        if (index < bytes.len) {
            try out.appendSlice(gpa, replacement);
            index += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

pub fn toText(gpa: Allocator, bytes: []u8, code_page: u32) ![]u8 {
    const valid = validPrefix(bytes);
    if (valid == bytes.len) return bytes;
    defer gpa.free(bytes);
    if (bytes.len - valid >= max_sequence) {
        if (try decodeCodePage(gpa, bytes, code_page)) |text| return text;
    }
    return replaceInvalid(gpa, bytes);
}

fn decodeCodePage(gpa: Allocator, bytes: []const u8, code_page: u32) !?[]u8 {
    if (builtin.os.tag != .windows or code_page == 0 or code_page == utf8_code_page) return null;
    if (bytes.len > std.math.maxInt(c_int)) return null;
    const len: c_int = @intCast(bytes.len);
    const needed = MultiByteToWideChar(code_page, 0, bytes.ptr, len, null, 0);
    if (needed <= 0) return null;
    const wide = try gpa.alloc(u16, @intCast(needed));
    defer gpa.free(wide);
    const written = MultiByteToWideChar(code_page, 0, bytes.ptr, len, wide.ptr, needed);
    if (written <= 0) return null;
    const text = try std.unicode.wtf16LeToWtf8Alloc(gpa, wide[0..@intCast(written)]);
    if (validPrefix(text) == text.len) return text;
    defer gpa.free(text);
    return try replaceInvalid(gpa, text);
}

extern "kernel32" fn GetOEMCP() callconv(.winapi) u32;
extern "kernel32" fn MultiByteToWideChar(code_page: u32, flags: u32, source: [*]const u8, source_len: c_int, target: ?[*]u16, target_len: c_int) callconv(.winapi) c_int;

const testing = std.testing;

test "valid UTF-8 output is kept as it is" {
    const bytes = try testing.allocator.dupe(u8, "ok \u{e7}\u{131} done\n");
    const text = try toText(testing.allocator, bytes, 857);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("ok \u{e7}\u{131} done\n", text);
}

test "console code page output is decoded to UTF-8 text" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const bytes = try testing.allocator.dupe(u8, "  G\x87e\x87ti: Ba\x9far\x8d\x8dl\x8d\n");
    const text = try toText(testing.allocator, bytes, 857);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("  G\u{e7}e\u{e7}ti: Ba\u{15f}ar\u{131}\u{131}l\u{131}\n", text);
}

test "a sequence cut at the end of the output becomes a replacement character, not a re-decode" {
    const bytes = try testing.allocator.dupe(u8, "caf\xc3\xa9 \xe2\x9c");
    const text = try toText(testing.allocator, bytes, 857);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("caf\u{e9} \u{FFFD}\u{FFFD}", text);
}

test "invalid bytes are replaced so the result is always valid UTF-8" {
    const text = try replaceInvalid(testing.allocator, "a\xffb\xc0\x80c");
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("a\u{FFFD}b\u{FFFD}\u{FFFD}c", text);
    try testing.expect(std.unicode.utf8ValidateSlice(text));
}
