const std = @import("std");
const server = @import("emetgate").server;
const Runtime = @import("emetgate").runtime.Runtime;

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
    try testing.expect(!empty.allow_repo_memory);

    const full = server.parsePolicy(&[_][]const u8{ "--test", "npm test", "--allow-repo-config" }).?;
    try testing.expectEqualStrings("npm test", full.test_command.?);
    try testing.expect(full.allow_repo_config);
    try testing.expect(!full.allow_repo_memory);

    const memory = server.parsePolicy(&[_][]const u8{ "--test", "npm test", "--allow-repo-memory" }).?;
    try testing.expect(memory.allow_repo_memory);
    try testing.expect(!memory.allow_repo_config);

    try testing.expect(server.parsePolicy(&[_][]const u8{"--test"}) == null);
    try testing.expect(server.parsePolicy(&[_][]const u8{ "--test", "" }) == null);
    try testing.expect(server.parsePolicy(&[_][]const u8{ "--test", "a", "--test", "b" }) == null);
    try testing.expect(server.parsePolicy(&[_][]const u8{ "--allow-repo-config", "--allow-repo-config" }) == null);
    try testing.expect(server.parsePolicy(&[_][]const u8{ "--allow-repo-memory", "--allow-repo-memory" }) == null);
    try testing.expect(server.parsePolicy(&[_][]const u8{"--bogus"}) == null);
}

test "policy: --typecheck is parsed once, never empty, and absent by default" {
    try testing.expect(server.parsePolicy(&[_][]const u8{}).?.typecheck_command == null);

    const both = server.parsePolicy(&[_][]const u8{ "--test", "npm test", "--typecheck", "npx tsc --noEmit" }).?;
    try testing.expectEqualStrings("npm test", both.test_command.?);
    try testing.expectEqualStrings("npx tsc --noEmit", both.typecheck_command.?);

    try testing.expect(server.parsePolicy(&[_][]const u8{"--typecheck"}) == null);
    try testing.expect(server.parsePolicy(&[_][]const u8{ "--typecheck", "" }) == null);
    try testing.expect(server.parsePolicy(&[_][]const u8{ "--typecheck", "a", "--typecheck", "b" }) == null);
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

test "emetgate_read_symbol with symbols reads several bodies at once" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    const response = (try respond(testing.allocator, testing.io, runtime,
        \\{"jsonrpc":"2.0","id":23,"method":"tools/call","params":{"name":"emetgate_read_symbol","arguments":{"file":"tests/fixtures/functions.ts","symbols":["add","square"]}}}
    )).?;
    defer testing.allocator.free(response);

    try testing.expect(std.mem.indexOf(u8, response, "\"isError\":false") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\\\"symbol\\\":\\\"add\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\\\"symbol\\\":\\\"square\\\"") != null);
}

test "emetgate_read_symbol with a line range widens to the symbol boundary" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    const response = (try respond(testing.allocator, testing.io, runtime,
        \\{"jsonrpc":"2.0","id":24,"method":"tools/call","params":{"name":"emetgate_read_symbol","arguments":{"file":"tests/fixtures/functions.ts","line_start":10,"line_end":10}}}
    )).?;
    defer testing.allocator.free(response);

    try testing.expect(std.mem.indexOf(u8, response, "\"isError\":false") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\\\"symbol\\\":\\\"add\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\\\"start_line\\\":9") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\\\"end_line\\\":11") != null);
}

test "emetgate_read_symbol with a line range hitting no symbol is a tool error" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    const response = (try respond(testing.allocator, testing.io, runtime,
        \\{"jsonrpc":"2.0","id":25,"method":"tools/call","params":{"name":"emetgate_read_symbol","arguments":{"file":"tests/fixtures/functions.ts","line_start":1,"line_end":1}}}
    )).?;
    defer testing.allocator.free(response);

    try testing.expect(std.mem.indexOf(u8, response, "\"isError\":true") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\\\"error\\\":\\\"NoSymbolInRange\\\"") != null);
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

const handlers = @import("emetgate").handlers;
const telemetry = @import("emetgate").telemetry;

const served_tools = [_][]const u8{
    "emetgate_symbols",
    "emetgate_skeleton",
    "emetgate_read_symbol",
    "emetgate_try",
    "emetgate_mutate",
    "emetgate_read_file",
    "emetgate_list",
    "emetgate_search",
    "emetgate_scan",
};

test "red line: the served tool surface is exactly this list, so a new tool cannot slip in unnoticed" {
    try testing.expectEqual(served_tools.len, server.tool_defs.len);
    for (server.tool_defs, served_tools) |tool, expected| {
        try testing.expectEqualStrings(expected, tool.name);
    }
    for (server.tool_defs) |tool| {
        for (tool.props) |prop| {
            try testing.expect(std.mem.indexOf(u8, prop.name, "rule") == null);
            try testing.expect(std.mem.indexOf(u8, prop.name, "enforce") == null);
            try testing.expect(std.mem.indexOf(u8, prop.name, "advisory") == null);
        }
    }
}

test "red line: no tool on the model side can adopt, change or forget a rule" {
    const writers = [_][]const u8{
        "emetgate_rule",
        "emetgate_rule_add",
        "emetgate_rule_supersede",
        "emetgate_rule_forget",
        "emetgate_rules_write",
        "emetgate_remember",
        "emetgate_forget",
        "emetgate_enforce",
        "rule",
        "rule_add",
    };
    for (writers) |name| {
        var event: telemetry.Event = .{ .tool = name };
        try testing.expectError(error.UnknownTool, handlers.callTool(testing.allocator, testing.io, undefined, name, null, &event, .{}));
        for (server.tool_defs) |tool| try testing.expect(!std.mem.eql(u8, tool.name, name));
    }
}
