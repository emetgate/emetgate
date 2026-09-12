const std = @import("std");
const symbol = @import("symbol.zig");
const cas = @import("cas.zig");
const skeleton = @import("skeleton.zig");
const wire = @import("wire.zig");
const runner = @import("runner.zig");
const stdio = @import("stdio.zig");
const Runtime = @import("runtime.zig").Runtime;
const Snapshot = @import("loader.zig").Snapshot;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;

const default_protocol_version = "2025-06-18";
const server_name = "synapse";
const server_version = "0.1.0";
const max_message_bytes = 4 * 1024 * 1024;

const Prop = struct { name: []const u8, desc: []const u8, optional: bool = false };
const Tool = struct { name: []const u8, description: []const u8, props: []const Prop };

const tool_defs = [_]Tool{
    .{
        .name = "synapse_symbols",
        .description = "List addressable function symbols in a TypeScript file with their content hashes.",
        .props = &.{.{ .name = "file", .desc = "path to a .ts file" }},
    },
    .{
        .name = "synapse_skeleton",
        .description = "Structural outline of a file: every symbol's signature with bodies elided. Read this instead of the whole file to locate a target cheaply.",
        .props = &.{.{ .name = "file", .desc = "path to a .ts file" }},
    },
    .{
        .name = "synapse_read_symbol",
        .description = "Return the current body of one symbol plus its hash, so you can edit just that function without reading the whole file; feed the hash straight into synapse_try.",
        .props = &.{
            .{ .name = "file", .desc = "path to a .ts file" },
            .{ .name = "symbol", .desc = "symbol ref, e.g. Class.method or add" },
        },
    },
    .{
        .name = "synapse_try",
        .description = "Type-checked atomic mutation: replaces the symbol body, runs test_cmd in a sandbox, and writes to disk only if the test passes; otherwise nothing is written.",
        .props = &.{
            .{ .name = "file", .desc = "path to a .ts file" },
            .{ .name = "symbol", .desc = "symbol ref, e.g. Class.method or add" },
            .{ .name = "hash", .desc = "current 32-hex hash of the symbol from synapse_symbols" },
            .{ .name = "body", .desc = "new function body including braces" },
            .{ .name = "test_cmd", .desc = "shell command that must exit 0 for the mutation to commit; defaults to test_cmd in .synapserc.json when omitted", .optional = true },
        },
    },
    .{
        .name = "synapse_mutate",
        .description = "In-memory dry-run mutation: returns the transformed source and new hash without touching disk.",
        .props = &.{
            .{ .name = "file", .desc = "path to a .ts file" },
            .{ .name = "symbol", .desc = "symbol ref, e.g. Class.method or add" },
            .{ .name = "hash", .desc = "current 32-hex hash of the symbol from synapse_symbols" },
            .{ .name = "body", .desc = "new function body including braces" },
        },
    },
};

pub fn serve(gpa: Allocator, io: std.Io, runtime: *Runtime, out: *Writer) !void {
    const read_buffer = try gpa.alloc(u8, max_message_bytes);
    defer gpa.free(read_buffer);
    var reader = std.Io.File.Reader.init(stdio.stdin(), io, read_buffer);
    const in = &reader.interface;

    while (true) {
        const line = in.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                try writeRpcError(out, .null, -32700, "Message exceeds size limit");
                try out.writeByte('\n');
                try out.flush();
                return;
            },
            error.ReadFailed => return,
        } orelse return;
        const trimmed = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
        if (trimmed.len == 0) continue;

        if (try handleMessage(gpa, io, runtime, trimmed, out)) {
            try out.writeByte('\n');
            try out.flush();
        }
    }
}

pub fn handleMessage(gpa: Allocator, io: std.Io, runtime: *Runtime, line: []const u8, out: *Writer) !bool {
    var parsed = std.json.parseFromSlice(Value, gpa, line, .{}) catch {
        try writeRpcError(out, .null, -32700, "Parse error");
        return true;
    };
    defer parsed.deinit();
    const msg = parsed.value;

    const id = getField(msg, "id");
    const method = getString(msg, "method") orelse {
        if (id) |value| {
            try writeRpcError(out, value, -32600, "Invalid Request");
            return true;
        }
        return false;
    };

    if (id == null) return false;
    const request_id = id.?;

    if (std.mem.eql(u8, method, "initialize")) {
        try writeInitialize(out, request_id, msg);
        return true;
    }
    if (std.mem.eql(u8, method, "ping")) {
        try writeEmptyResult(out, request_id);
        return true;
    }
    if (std.mem.eql(u8, method, "tools/list")) {
        try writeToolsList(out, request_id);
        return true;
    }
    if (std.mem.eql(u8, method, "tools/call")) {
        try handleToolsCall(gpa, io, runtime, out, request_id, msg);
        return true;
    }
    try writeRpcError(out, request_id, -32601, "Method not found");
    return true;
}

const ToolResult = struct { text: []u8, is_error: bool };

fn handleToolsCall(gpa: Allocator, io: std.Io, runtime: *Runtime, out: *Writer, id: Value, msg: Value) !void {
    const params = getField(msg, "params") orelse return writeRpcError(out, id, -32602, "Missing params");
    const name = getString(params, "name") orelse return writeRpcError(out, id, -32602, "Missing tool name");
    const arguments = getField(params, "arguments");

    const result = callTool(gpa, io, runtime, name, arguments) catch |err| switch (err) {
        error.UnknownTool => return writeRpcError(out, id, -32602, "Unknown tool"),
        error.MissingArgument => return writeRpcError(out, id, -32602, "Missing or invalid argument"),
        else => return writeRpcError(out, id, -32603, "Internal error"),
    };
    defer gpa.free(result.text);
    try writeToolResult(out, id, result.text, result.is_error);
}

fn callTool(gpa: Allocator, io: std.Io, runtime: *Runtime, name: []const u8, args: ?Value) !ToolResult {
    if (std.mem.eql(u8, name, "synapse_symbols")) return callSymbols(gpa, io, runtime, args);
    if (std.mem.eql(u8, name, "synapse_skeleton")) return callSkeleton(gpa, io, runtime, args);
    if (std.mem.eql(u8, name, "synapse_read_symbol")) return callReadSymbol(gpa, io, runtime, args);
    if (std.mem.eql(u8, name, "synapse_mutate")) return callMutate(gpa, io, runtime, args);
    if (std.mem.eql(u8, name, "synapse_try")) return callTry(gpa, io, runtime, args);
    return error.UnknownTool;
}

fn callSymbols(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value) !ToolResult {
    const file = try requireString(args, "file");
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    renderSymbols(gpa, io, runtime, file, &buffer.writer) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err);
    };
    return success(gpa, &buffer);
}

fn loadJailed(gpa: Allocator, io: std.Io, runtime: *Runtime, file: []const u8) !*Snapshot {
    const file_abs = try std.Io.Dir.cwd().realPathFileAlloc(io, file, gpa);
    defer gpa.free(file_abs);
    try runner.assertUnderCwdRepo(gpa, io, file_abs);
    return Snapshot.load(runtime, io, .cwd(), file_abs);
}

fn renderSymbols(gpa: Allocator, io: std.Io, runtime: *Runtime, file: []const u8, w: *Writer) !void {
    const snapshot = try loadJailed(gpa, io, runtime, file);
    defer snapshot.destroy();
    const table = try snapshot.symbols();
    try wire.writeSymbols(gpa, w, file, table.*);
}

fn callSkeleton(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value) !ToolResult {
    const file = try requireString(args, "file");
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    renderSkeleton(gpa, io, runtime, file, &buffer.writer) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err);
    };
    return success(gpa, &buffer);
}

fn renderSkeleton(gpa: Allocator, io: std.Io, runtime: *Runtime, file: []const u8, w: *Writer) !void {
    const snapshot = try loadJailed(gpa, io, runtime, file);
    defer snapshot.destroy();
    const text = try skeleton.skeletonize(gpa, runtime.parser, snapshot.tree);
    defer gpa.free(text);
    try wire.writeSkeleton(w, file, text);
}

fn callReadSymbol(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value) !ToolResult {
    const file = try requireString(args, "file");
    const sym = try requireString(args, "symbol");
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    renderSymbolBody(gpa, io, runtime, file, sym, &buffer.writer) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err);
    };
    return success(gpa, &buffer);
}

fn renderSymbolBody(gpa: Allocator, io: std.Io, runtime: *Runtime, file: []const u8, sym: []const u8, w: *Writer) !void {
    const snapshot = try loadJailed(gpa, io, runtime, file);
    defer snapshot.destroy();
    const table = try snapshot.symbols();
    const ref = try symbol.Ref.parse(gpa, sym);
    defer ref.deinit(gpa);
    const found = try table.resolve(ref);
    try wire.writeSymbolBody(w, file, sym, found.hash, snapshot.tree.text(found.body));
}

fn callMutate(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value) !ToolResult {
    const file = try requireString(args, "file");
    const sym = try requireString(args, "symbol");
    const hash_hex = try requireString(args, "hash");
    const body = try requireString(args, "body");
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    renderMutate(gpa, io, runtime, file, sym, hash_hex, body, &buffer.writer) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err);
    };
    return success(gpa, &buffer);
}

fn renderMutate(gpa: Allocator, io: std.Io, runtime: *Runtime, file: []const u8, sym: []const u8, hash_hex: []const u8, body: []const u8, w: *Writer) !void {
    const ref = try symbol.Ref.parse(gpa, sym);
    defer ref.deinit(gpa);
    const expected = try symbol.parseHash(hash_hex);
    const base = try loadJailed(gpa, io, runtime, file);
    defer base.destroy();
    if (base.tree.root().hasError()) return error.SourceHasErrors;
    const applied = try cas.apply(base, .{ .ref = ref, .expected_hash = expected, .new_body = body });
    defer applied.snapshot.destroy();
    try wire.writeMutated(w, sym, expected, applied.hash, applied.snapshot.source);
}

fn callTry(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value) !ToolResult {
    const file = try requireString(args, "file");
    const sym = try requireString(args, "symbol");
    const hash_hex = try requireString(args, "hash");
    const body = try requireString(args, "body");
    const test_cmd = if (args) |a| getString(a, "test_cmd") orelse "" else "";
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    const is_error = tryInto(gpa, io, runtime, file, sym, hash_hex, body, test_cmd, &buffer.writer) catch |err| blk: {
        if (err == error.OutOfMemory) return err;
        buffer.clearRetainingCapacity();
        try wire.writeError(&buffer.writer, @errorName(err), wire.exitCode(err));
        break :blk true;
    };
    return .{ .text = try dupTrim(gpa, buffer.written()), .is_error = is_error };
}

fn tryInto(gpa: Allocator, io: std.Io, runtime: *Runtime, file: []const u8, sym: []const u8, hash_hex: []const u8, body: []const u8, test_cmd: []const u8, w: *Writer) !bool {
    const file_abs = try std.Io.Dir.cwd().realPathFileAlloc(io, file, gpa);
    defer gpa.free(file_abs);
    const test_command = try runner.resolveTestCommand(gpa, io, file_abs, test_cmd);
    defer gpa.free(test_command);
    const expected = try symbol.parseHash(hash_hex);
    const result = try runner.tryMutate(gpa, io, runtime, .{
        .file_abs = file_abs,
        .ref_text = sym,
        .expected_hash = expected,
        .new_body = body,
        .test_command = test_command,
    });
    defer result.deinit(gpa);
    switch (result) {
        .committed => |new_hash| {
            try wire.writeCommitted(w, sym, expected, new_hash);
            return false;
        },
        .rejected => |report| {
            try wire.writeRejected(w, test_command, report);
            return true;
        },
    }
}

fn success(gpa: Allocator, buffer: *std.Io.Writer.Allocating) !ToolResult {
    return .{ .text = try dupTrim(gpa, buffer.written()), .is_error = false };
}

fn failure(gpa: Allocator, buffer: *std.Io.Writer.Allocating, err: anyerror) !ToolResult {
    buffer.clearRetainingCapacity();
    try wire.writeError(&buffer.writer, @errorName(err), wire.exitCode(err));
    return .{ .text = try dupTrim(gpa, buffer.written()), .is_error = true };
}

fn dupTrim(gpa: Allocator, bytes: []const u8) ![]u8 {
    const end = if (bytes.len > 0 and bytes[bytes.len - 1] == '\n') bytes.len - 1 else bytes.len;
    return gpa.dupe(u8, bytes[0..end]);
}

fn requireString(args: ?Value, key: []const u8) error{MissingArgument}![]const u8 {
    const object = args orelse return error.MissingArgument;
    return getString(object, key) orelse error.MissingArgument;
}

fn getField(value: Value, key: []const u8) ?Value {
    if (value != .object) return null;
    return value.object.get(key);
}

fn getString(value: Value, key: []const u8) ?[]const u8 {
    const field = getField(value, key) orelse return null;
    return switch (field) {
        .string => |s| s,
        else => null,
    };
}

fn writeInitialize(out: *Writer, id: Value, msg: Value) !void {
    const protocol_version = blk: {
        const params = getField(msg, "params") orelse break :blk default_protocol_version;
        break :blk getString(params, "protocolVersion") orelse default_protocol_version;
    };
    var js: std.json.Stringify = .{ .writer = out };
    try js.beginObject();
    try envelope(&js, id);
    try js.objectField("result");
    try js.beginObject();
    try js.objectField("protocolVersion");
    try js.write(protocol_version);
    try js.objectField("capabilities");
    try js.beginObject();
    try js.objectField("tools");
    try js.beginObject();
    try js.endObject();
    try js.endObject();
    try js.objectField("serverInfo");
    try js.beginObject();
    try js.objectField("name");
    try js.write(server_name);
    try js.objectField("version");
    try js.write(server_version);
    try js.endObject();
    try js.endObject();
    try js.endObject();
}

fn writeEmptyResult(out: *Writer, id: Value) !void {
    var js: std.json.Stringify = .{ .writer = out };
    try js.beginObject();
    try envelope(&js, id);
    try js.objectField("result");
    try js.beginObject();
    try js.endObject();
    try js.endObject();
}

fn writeToolsList(out: *Writer, id: Value) !void {
    var js: std.json.Stringify = .{ .writer = out };
    try js.beginObject();
    try envelope(&js, id);
    try js.objectField("result");
    try js.beginObject();
    try js.objectField("tools");
    try js.beginArray();
    for (tool_defs) |tool| {
        try js.beginObject();
        try js.objectField("name");
        try js.write(tool.name);
        try js.objectField("description");
        try js.write(tool.description);
        try js.objectField("inputSchema");
        try js.beginObject();
        try js.objectField("type");
        try js.write("object");
        try js.objectField("properties");
        try js.beginObject();
        for (tool.props) |prop| {
            try js.objectField(prop.name);
            try js.beginObject();
            try js.objectField("type");
            try js.write("string");
            try js.objectField("description");
            try js.write(prop.desc);
            try js.endObject();
        }
        try js.endObject();
        try js.objectField("required");
        try js.beginArray();
        for (tool.props) |prop| {
            if (!prop.optional) try js.write(prop.name);
        }
        try js.endArray();
        try js.endObject();
        try js.endObject();
    }
    try js.endArray();
    try js.endObject();
    try js.endObject();
}

fn writeToolResult(out: *Writer, id: Value, text: []const u8, is_error: bool) !void {
    var js: std.json.Stringify = .{ .writer = out };
    try js.beginObject();
    try envelope(&js, id);
    try js.objectField("result");
    try js.beginObject();
    try js.objectField("content");
    try js.beginArray();
    try js.beginObject();
    try js.objectField("type");
    try js.write("text");
    try js.objectField("text");
    try js.write(text);
    try js.endObject();
    try js.endArray();
    try js.objectField("isError");
    try js.write(is_error);
    try js.endObject();
    try js.endObject();
}

fn writeRpcError(out: *Writer, id: Value, code: i32, message: []const u8) !void {
    var js: std.json.Stringify = .{ .writer = out };
    try js.beginObject();
    try envelope(&js, id);
    try js.objectField("error");
    try js.beginObject();
    try js.objectField("code");
    try js.write(code);
    try js.objectField("message");
    try js.write(message);
    try js.endObject();
    try js.endObject();
}

fn envelope(js: *std.json.Stringify, id: Value) !void {
    try js.objectField("jsonrpc");
    try js.write("2.0");
    try js.objectField("id");
    try js.write(id);
}

const testing = std.testing;

fn respond(gpa: Allocator, io: std.Io, runtime: *Runtime, line: []const u8) !?[]u8 {
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    const wrote = try handleMessage(gpa, io, runtime, line, &buffer.writer);
    if (!wrote) return null;
    return try gpa.dupe(u8, buffer.written());
}

test "initialize reflects the client protocol version and advertises tools" {
    const response = (try respond(testing.allocator, testing.io, undefined,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}
    )).?;
    defer testing.allocator.free(response);

    try testing.expect(std.mem.indexOf(u8, response, "\"protocolVersion\":\"2024-11-05\"") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"name\":\"synapse\"") != null);
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

    try testing.expect(std.mem.indexOf(u8, response, "synapse_symbols") != null);
    try testing.expect(std.mem.indexOf(u8, response, "synapse_skeleton") != null);
    try testing.expect(std.mem.indexOf(u8, response, "synapse_read_symbol") != null);
    try testing.expect(std.mem.indexOf(u8, response, "synapse_try") != null);
    try testing.expect(std.mem.indexOf(u8, response, "synapse_mutate") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"required\":[\"file\",\"symbol\",\"hash\",\"body\"]") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"required\":[\"file\",\"symbol\",\"hash\",\"body\",\"test_cmd\"]") == null);
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
        \\{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"synapse_symbols","arguments":{}}}
    )).?;
    defer testing.allocator.free(response);
    try testing.expect(std.mem.indexOf(u8, response, "\"code\":-32602") != null);
}

test "synapse_symbols call returns a text content block with the symbols NDJSON" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    const response = (try respond(testing.allocator, testing.io, runtime,
        \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"synapse_symbols","arguments":{"file":"tests/fixtures/functions.ts"}}}
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
        \\{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"synapse_symbols","arguments":{"file":"tests/fixtures/broken.ts"}}}
    )).?;
    defer testing.allocator.free(response);

    try testing.expect(std.mem.indexOf(u8, response, "\"isError\":true") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\\\"error\\\":\\\"SourceHasErrors\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\\\"exit_code\\\":3") != null);
}

test "synapse_skeleton call returns the outline with bodies elided" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    const response = (try respond(testing.allocator, testing.io, runtime,
        \\{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"synapse_skeleton","arguments":{"file":"tests/fixtures/functions.ts"}}}
    )).?;
    defer testing.allocator.free(response);

    try testing.expect(std.mem.indexOf(u8, response, "\"isError\":false") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\\\"skeleton\\\":\\\"") != null);
}

test "synapse_read_symbol returns one body and its hash" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    const response = (try respond(testing.allocator, testing.io, runtime,
        \\{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"synapse_read_symbol","arguments":{"file":"tests/fixtures/functions.ts","symbol":"add"}}}
    )).?;
    defer testing.allocator.free(response);

    try testing.expect(std.mem.indexOf(u8, response, "\"isError\":false") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\\\"symbol\\\":\\\"add\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\\\"hash\\\":\\\"35b462b8e42e39e0fe66ae0dae747ab7\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\\\"body\\\":\\\"") != null);
}

test "synapse_read_symbol on an unknown symbol is a tool error" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    const response = (try respond(testing.allocator, testing.io, runtime,
        \\{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"synapse_read_symbol","arguments":{"file":"tests/fixtures/functions.ts","symbol":"nope"}}}
    )).?;
    defer testing.allocator.free(response);

    try testing.expect(std.mem.indexOf(u8, response, "\"isError\":true") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\\\"error\\\":\\\"SymbolNotFound\\\"") != null);
}

test "synapse_mutate call returns the transformed source without touching disk" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    const response = (try respond(testing.allocator, testing.io, runtime,
        \\{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"synapse_mutate","arguments":{"file":"tests/fixtures/functions.ts","symbol":"add","hash":"35b462b8e42e39e0fe66ae0dae747ab7","body":"{ return 0; }"}}}
    )).?;
    defer testing.allocator.free(response);

    try testing.expect(std.mem.indexOf(u8, response, "\"isError\":false") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\\\"status\\\":\\\"mutated\\\"") != null);
}

test "synapse_mutate with a stale hash is a tool error, not a protocol error" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    const response = (try respond(testing.allocator, testing.io, runtime,
        \\{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"synapse_mutate","arguments":{"file":"tests/fixtures/functions.ts","symbol":"add","hash":"00000000000000000000000000000000","body":"{ return 0; }"}}}
    )).?;
    defer testing.allocator.free(response);

    try testing.expect(std.mem.indexOf(u8, response, "\"isError\":true") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\\\"error\\\":\\\"HashMismatch\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"code\":-320") == null);
}
