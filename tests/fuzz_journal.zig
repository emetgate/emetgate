const std = @import("std");
const journal = @import("emetgate").journal;

const testing = std.testing;

const seed_corpus = [_][]const u8{
    "",
    "{}",
    "{ not json",
    "null",
    "{\"version\":2,\"batch\":\"0123456789abcdef\",\"intents\":[]}",
    "{\"version\":2,\"batch\":\"0123456789abcdef\",\"intents\":[{\"op\":\"delete\",\"target\":\"C:\\\\r\\\\a.ts\",\"base_hash\":\"00\"}]}",
    "{\"version\":2,\"batch\":\"x\",\"intents\":[{\"op\":\"modify\",\"target\":\"a\",\"base_hash\":\"00\",\"new_hash\":\"11\"}]}",
    "{\"version\":3,\"batch\":\"x\",\"intents\":[]}",
    "{\"version\":1,\"target\":\"a\",\"base_hash\":\"00\"}",
    "{\"target\":\"C:\\\\r\\\\a.ts\",\"base_hash\":\"00\"}",
    "{\"version\":2}",
    "{\"version\":2,\"intents\":\"not an array\"}",
    "{\"version\":\"2\"}",
    "{\"version\":2.5}",
    "\xff\xfe\x00\x01",
    "{" ++ "\"a\":" ** 200 ++ "1" ++ "}" ** 200,
    "{\"version\":2,\"batch\":\"x\",\"intents\":[{}]}",
};

fn testOne(_: void, smith: *testing.Smith) anyerror!void {
    const bytes = smith.in.?;
    const parsed = journal.parse(testing.allocator, bytes) catch return;
    defer parsed.deinit();
    switch (parsed) {
        .batch => |b| try testing.expectEqual(@as(u32, journal.version), b.value.version),
        .legacy => |l| try testing.expect(l.value.op.len != 0),
    }
}

test "fuzz: journal.parse on malformed v2 and legacy bytes never crashes or leaks, and its variant matches the declared version" {
    try testing.fuzz({}, testOne, .{ .corpus = &seed_corpus });
}
