const std = @import("std");
const server = @import("emetgate").server;
const Runtime = @import("emetgate").runtime.Runtime;

const testing = std.testing;

const seed_corpus = [_][]const u8{
    "",
    "{}",
    "[]",
    "null",
    "\"just a string\"",
    "{\"jsonrpc\":\"2.0\"}",
    "{\"jsonrpc\":\"2.0\",\"id\":1}",
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"\"}",
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}",
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"}",
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{}}",
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"\"}}",
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"emetgate_git\",\"arguments\":null}}",
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"emetgate_try\",\"arguments\":{\"file\":1,\"symbol\":2,\"hash\":3,\"body\":4}}}",
    "{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"initialize\",\"params\":[1,2,3]}",
    "{\"jsonrpc\":2.0,\"id\":1,\"method\":\"initialize\"}",
    "{\"id\":1e999,\"method\":\"initialize\"}",
    "{\"id\":-0,\"method\":\"initialize\"}",
    "{\"id\":1,\"method\":\"initialize\",\"params\":{\"a\":\"a\"",
    "\xff\xfe\x00\x01",
    "{\"id\":1,\"method\":\"\\u0000\\u0000\"}",
    "{" ++ "\"a\":" ** 200 ++ "1" ++ "}" ** 200,
};

fn testOne(_: void, smith: *testing.Smith) anyerror!void {
    const line = smith.in.?;
    const runtime = Runtime.create(testing.allocator) catch return;
    defer runtime.destroy() catch @panic("live snapshots");

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    _ = server.handleMessage(testing.allocator, testing.io, runtime, line, &out.writer) catch return;
}

test "fuzz: a JSON-RPC input line never crashes or leaks the server" {
    try testing.fuzz({}, testOne, .{ .corpus = &seed_corpus });
}
