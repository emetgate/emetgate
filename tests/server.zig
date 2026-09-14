const std = @import("std");
const server = @import("../src/protocol/server.zig");
const Runtime = @import("../src/engine/runtime.zig").Runtime;

const testing = std.testing;
const Allocator = std.mem.Allocator;

fn respond(gpa: Allocator, io: std.Io, runtime: *Runtime, line: []const u8) !?[]u8 {
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    const wrote = try server.handleMessage(gpa, io, runtime, line, &buffer.writer);
    if (!wrote) return null;
    return try gpa.dupe(u8, buffer.written());
}

test "initialize reflects the client protocol version and advertises tools" {
    const response = (try respond(testing.allocator, testing.io, undefined,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}
    )).?;
    defer testing.allocator.free(response);

    try testing.expect(std.mem.indexOf(u8, response, "\"protocolVersion\":\"2024-11-05\"") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"name\":\"emetgate\"") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"capabilities\":{\"tools\":{}}") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"id\":1") != null);
}

test "a notification produces no response" {
    try testing.expect((try respond(testing.allocator, testing.io, undefined,
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    )) == null);
}

test "tools/list names the three tools and marks hash required" {
    const response = (try respond(testing.allocator, testing.io, undefined,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
    )).?;
    defer testing.allocator.free(response);

    try testing.expect(std.mem.indexOf(u8, response, "emetgate_symbols") != null);
    try testing.expect(std.mem.indexOf(u8, response, "emetgate_skeleton") != null);
    try testing.expect(std.mem.indexOf(u8, response, "emetgate_read_symbol") != null);
    try testing.expect(std.mem.indexOf(u8, response, "emetgate_try") != null);
    try testing.expect(std.mem.indexOf(u8, response, "emetgate_mutate") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"required\":[\"file\",\"symbol\",\"hash\",\"body\"]") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"required\":[\"file\",\"symbol\",\"hash\",\"body\",\"test_cmd\"]") == null);
}

test "serve policy comes only from the command line emetgate was started with" {
    const empty = server.parsePolicy(&[_][]const u8{}).?;
    try testing.expect(empty.test_command == null);
    try testing.expect(!empty.allow_repo_config);

    const full = server.parsePolicy(&[_][]const u8{ "--test", "npm test", "--allow-repo-config" }).?;
    try testing.expectEqualStrings("npm test", full.test_command.?);
    try testing.expect(full.allow_repo_config);

    try testing.expect(server.parsePolicy(&[_][]const u8{"--test"}) == null);
    try testing.expect(server.parsePolicy(&[_][]const u8{ "--test", "" }) == null);
    try testing.expect(server.parsePolicy(&[_][]const u8{ "--test", "a", "--test", "b" }) == null);
    try testing.expect(server.parsePolicy(&[_][]const u8{ "--allow-repo-config", "--allow-repo-config" }) == null);
    try testing.expect(server.parsePolicy(&[_][]const u8{"--bogus"}) == null);
}

test "ping returns an empty result" {
    const response = (try respond(testing.allocator, testing.io, undefined,
        \\{"jsonrpc":"2.0","id":3,"method":"ping"}
    )).?;
    defer testing.allocator.free(response);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{}}", response);
}

test "malformed json is a parse error with a null id" {
    const response = (try respond(testing.allocator, testing.io, undefined, "{not json")).?;
    defer testing.allocator.free(response);
    try testing.expect(std.mem.indexOf(u8, response, "\"code\":-32700") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"id\":null") != null);
}

test "an unknown method is method not found" {
    const response = (try respond(testing.allocator, testing.io, undefined,
        \\{"jsonrpc":"2.0","id":4,"method":"does/not/exist"}
    )).?;
    defer testing.allocator.free(response);
    try testing.expect(std.mem.indexOf(u8, response, "\"code\":-32601") != null);
}

test "an unknown tool is invalid params" {
    const response = (try respond(testing.allocator, testing.io, undefined,
        \\{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"nope","arguments":{}}}
    )).?;
    defer testing.allocator.free(response);
    try testing.expect(std.mem.indexOf(u8, response, "\"code\":-32602") != null);
}

test "a tool call missing a required argument is invalid params" {
    const response = (try respond(testing.allocator, testing.io, undefined,
        \\{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"emetgate_symbols","arguments":{}}}
    )).?;
    defer testing.allocator.free(response);
    try testing.expect(std.mem.indexOf(u8, response, "\"code\":-32602") != null);
}

test "emetgate_symbols call returns a text content block with the symbols NDJSON" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    const response = (try respond(testing.allocator, testing.io, runtime,
        \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"emetgate_symbols","arguments":{"file":"tests/fixtures/functions.ts"}}}
    )).?;
    defer testing.allocator.free(response);

    try testing.expect(std.mem.indexOf(u8, response, "\"isError\":false") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"type\":\"text\"") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\\\"ref\\\":\\\"add\\\"") != null);
}

test "a broken source is a tool error carrying the typed payload" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    const response = (try respond(testing.allocator, testing.io, runtime,
        \\{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"emetgate_symbols","arguments":{"file":"tests/fixtures/broken.ts"}}}
    )).?;
    defer testing.allocator.free(response);

    try testing.expect(std.mem.indexOf(u8, response, "\"isError\":true") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\\\"error\\\":\\\"SourceHasErrors\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\\\"exit_code\\\":3") != null);
}

test "emetgate_skeleton call returns the outline with bodies elided" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    const response = (try respond(testing.allocator, testing.io, runtime,
        \\{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"emetgate_skeleton","arguments":{"file":"tests/fixtures/functions.ts"}}}
    )).?;
    defer testing.allocator.free(response);

    try testing.expect(std.mem.indexOf(u8, response, "\"isError\":false") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\\\"skeleton\\\":\\\"") != null);
}

test "emetgate_read_symbol returns one body and its hash" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    const response = (try respond(testing.allocator, testing.io, runtime,
        \\{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"emetgate_read_symbol","arguments":{"file":"tests/fixtures/functions.ts","symbol":"add"}}}
    )).?;
    defer testing.allocator.free(response);

    try testing.expect(std.mem.indexOf(u8, response, "\"isError\":false") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\\\"symbol\\\":\\\"add\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\\\"hash\\\":\\\"35b462b8e42e39e0fe66ae0dae747ab7\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\\\"body\\\":\\\"") != null);
}

test "emetgate_read_symbol on an unknown symbol is a tool error" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    const response = (try respond(testing.allocator, testing.io, runtime,
        \\{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"emetgate_read_symbol","arguments":{"file":"tests/fixtures/functions.ts","symbol":"nope"}}}
    )).?;
    defer testing.allocator.free(response);

    try testing.expect(std.mem.indexOf(u8, response, "\"isError\":true") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\\\"error\\\":\\\"SymbolNotFound\\\"") != null);
}

test "emetgate_mutate call returns the transformed source without touching disk" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    const response = (try respond(testing.allocator, testing.io, runtime,
        \\{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"emetgate_mutate","arguments":{"file":"tests/fixtures/functions.ts","symbol":"add","hash":"35b462b8e42e39e0fe66ae0dae747ab7","body":"{ return 0; }"}}}
    )).?;
    defer testing.allocator.free(response);

    try testing.expect(std.mem.indexOf(u8, response, "\"isError\":false") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\\\"status\\\":\\\"mutated\\\"") != null);
}

test "emetgate_mutate with a stale hash is a tool error, not a protocol error" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    const response = (try respond(testing.allocator, testing.io, runtime,
        \\{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"emetgate_mutate","arguments":{"file":"tests/fixtures/functions.ts","symbol":"add","hash":"00000000000000000000000000000000","body":"{ return 0; }"}}}
    )).?;
    defer testing.allocator.free(response);

    try testing.expect(std.mem.indexOf(u8, response, "\"isError\":true") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\\\"error\\\":\\\"HashMismatch\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"code\":-320") == null);
}
