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
    "(?<=a)b",
    "(a)\\1",
    "\\bfox\\b",
    "(?i)FOX",
    "^(a|aa)+$",
    "\\K",
    "(*ACCEPT)",
    "\\Uabc",
};

const subject = "the quick brown fox jumps over 12345";

fn testOne(_: void, smith: *testing.Smith) anyerror!void {
    const pattern = smith.in.?;
    var diag: regex.Diagnostic = .{};
    if (regex.Regex.compileCounted(testing.allocator, pattern, &diag)) |counted| {
        defer counted.deinit(testing.allocator);
        var budget: u64 = 10_000;
        _ = counted.isMatch(testing.allocator, subject, &budget) catch {};
    } else |_| {
        try testing.expect(std.unicode.utf8ValidateSlice(diag.at));
        try testing.expect(diag.offset <= pattern.len);
    }
    const searched = regex.Regex.compile(testing.allocator, pattern, null) catch return;
    defer searched.deinit(testing.allocator);
    const matcher = try regex.Matcher.init(testing.allocator, 10_000);
    defer matcher.deinit(testing.allocator);
    const span = (matcher.find(searched, subject) catch return) orelse return;
    try testing.expect(span.start <= span.end and span.end <= subject.len);
}

test "fuzz: regex compile and match never crash or leak, a refusal points inside the pattern and a match inside the text" {
    try testing.fuzz({}, testOne, .{ .corpus = &seed_corpus });
}
