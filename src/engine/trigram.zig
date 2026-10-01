const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn of(a: u8, b: u8, c: u8) u24 {
    return (@as(u24, a) << 16) | (@as(u24, b) << 8) | c;
}

pub fn setOfAlloc(gpa: Allocator, text: []const u8) ![]u24 {
    var set: std.AutoArrayHashMapUnmanaged(u24, void) = .empty;
    defer set.deinit(gpa);
    if (text.len >= 3) {
        var i: usize = 0;
        while (i + 3 <= text.len) : (i += 1) try set.put(gpa, of(text[i], text[i + 1], text[i + 2]), {});
    }
    const owned = try gpa.dupe(u24, set.keys());
    std.mem.sort(u24, owned, {}, std.sort.asc(u24));
    return owned;
}

pub fn isSupersetSorted(haystack: []const u24, needles: []const u24) bool {
    var hi: usize = 0;
    for (needles) |needle| {
        while (hi < haystack.len and haystack[hi] < needle) hi += 1;
        if (hi >= haystack.len or haystack[hi] != needle) return false;
    }
    return true;
}

const testing = std.testing;

test "isSupersetSorted matches a subset regardless of order in the query" {
    const haystack = [_]u24{ 1, 5, 9, 20 };
    try testing.expect(isSupersetSorted(&haystack, &.{ 5, 9 }));
    try testing.expect(!isSupersetSorted(&haystack, &.{ 5, 6 }));
    try testing.expect(isSupersetSorted(&haystack, &.{}));
}

test "trigramsOfAlloc is empty for text shorter than three bytes" {
    const empty = try setOfAlloc(testing.allocator, "ab");
    defer testing.allocator.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);

    const one = try setOfAlloc(testing.allocator, "abcabc");
    defer testing.allocator.free(one);
    try testing.expectEqual(@as(usize, 3), one.len);
}
