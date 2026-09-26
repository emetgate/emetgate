const std = @import("std");
const regex = @import("emetgate").regex;

const testing = std.testing;

const seed_corpus = [_][]const u8{
    "",
    "a",
    "a*",
    "a+",
    "a?",
    "a{2,5}",
    "(a|b)",
    "[a-z]",
    "[^a-z]",
    "\\d\\w\\s",
    "\\p{L}",
    "^abc$",
    "a.b",
    ".",
    "(",
    ")",
    "[",
    "]",
    "\\",
    "**",
    "a{",
    "a{,}",
    "a{999999999999}",
    "(((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((a)))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))",
    "[z-a]",
    "\\x{110000}",
    "a\x00b",
    "\xff\xfe\xfd",
};

fn testOne(_: void, smith: *testing.Smith) anyerror!void {
    const pattern = smith.in.?;
    var diag: regex.Diagnostic = .{};
    var budget: u64 = 10_000;
    var compiled = regex.Regex.compile(testing.allocator, pattern, &diag) catch return;
    defer compiled.deinit(testing.allocator);
    _ = compiled.isMatch(testing.allocator, "the quick brown fox jumps over 12345", &budget) catch return;
}

test "fuzz: regex compile and match never crash or leak" {
    try testing.fuzz({}, testOne, .{ .corpus = &seed_corpus });
}
