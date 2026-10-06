const std = @import("std");

pub const max_bytes = 16 * 1024;

pub const Error = error{
    CommitMessageEmpty,
    CommitMessageTooLong,
    CommitMessageNotUtf8,
    CommitMessageNul,
};

pub fn check(message: []const u8) Error!void {
    if (std.mem.trim(u8, message, " \t\r\n").len == 0) return error.CommitMessageEmpty;
    if (message.len > max_bytes) return error.CommitMessageTooLong;
    if (std.mem.indexOfScalar(u8, message, 0) != null) return error.CommitMessageNul;
    if (!std.unicode.utf8ValidateSlice(message)) return error.CommitMessageNotUtf8;
}

const testing = std.testing;

test "commit message: any text git can store passes, whatever its shape" {
    try check("fix(gate): refuse a stale hash before the tests start");
    try check("docs: türkçe karakterli başlık");
    try check("subject\n\nA body paragraph.\n\nSigned-off-by: A Developer <a@example.com>");
    try check("WIP");
    try check("tab\tinside and trailing space ");
}

test "commit message: an empty or blank message is refused" {
    try testing.expectError(error.CommitMessageEmpty, check(""));
    try testing.expectError(error.CommitMessageEmpty, check(" \t\r\n\n"));
}

test "commit message: a message over the byte limit is refused and one at the limit passes" {
    const at_limit = "a" ** max_bytes;
    try check(at_limit);
    try testing.expectError(error.CommitMessageTooLong, check(at_limit ++ "a"));
}

test "commit message: a NUL byte is refused" {
    try testing.expectError(error.CommitMessageNul, check("fix: nul\x00here"));
}

test "commit message: bytes that are not UTF-8 are refused" {
    try testing.expectError(error.CommitMessageNotUtf8, check("fix: \xff\xfe"));
}
