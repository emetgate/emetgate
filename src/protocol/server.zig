const std = @import("std");
const telemetry = @import("telemetry.zig");
const handlers = @import("handlers.zig");
const policy_mod = @import("policy.zig");
const tool_result = @import("tool_result.zig");
const runner = @import("../platform/runner.zig");
const shadow = @import("../platform/shadow.zig");
const stdio = @import("../platform/stdio.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;
const getField = tool_result.getField;
const getString = tool_result.getString;

pub const Policy = policy_mod.Policy;
pub const parsePolicy = policy_mod.parsePolicy;

const default_protocol_version = "2025-06-18";
const server_name = "emetgate";
const server_version = "0.1.0";
const max_message_bytes = 4 * 1024 * 1024;

pub const Prop = struct { name: []const u8, desc: []const u8, optional: bool = false, ty: []const u8 = "string" };
pub const Tool = struct { name: []const u8, description: []const u8, props: []const Prop };

pub const tool_defs = [_]Tool{
    .{
        .name = "emetgate_symbols",
        .description = "List addressable function symbols in a source file of a registered language with their content hashes.",
        .props = &.{.{ .name = "file", .desc = "path to a source file in a registered language" }},
    },
    .{
        .name = "emetgate_skeleton",
        .description = "Structural outline of a source file in a registered language: every symbol's signature with bodies elided, plus every adopted rule that covers this file (id, text, enforce or advisory, predicate, scope). Read this instead of the whole file to locate a target cheaply, and write a body that already obeys the listed rules: an enforced rule rejects a proposal before the tests run. The rules are read-only here; they are adopted, superseded and forgotten only from the emetgate CLI. Files of other languages are refused; use emetgate_read_file for docs and config.",
        .props = &.{.{ .name = "file", .desc = "path to a source file in a registered language" }},
    },
    .{
        .name = "emetgate_read_symbol",
        .description = "Return the current body of one symbol plus its hash, so you can edit just that function without reading the whole file; feed the hash straight into emetgate_try.",
        .props = &.{
            .{ .name = "file", .desc = "path to a source file in a registered language" },
            .{ .name = "symbol", .desc = "symbol ref, e.g. Class.method or add" },
        },
    },
    .{
        .name = "emetgate_try",
        .description = "Atomic mutation: replaces the symbol body, runs the project's trusted typecheck command (when configured) and then its test command in a sandbox, and writes to disk only if both pass; otherwise nothing is written. The test command is fixed by the user who started emetgate (emetgate mcp --test <cmd>, or the repo .emetgaterc.json with --allow-repo-config); a call that passes test_cmd, typecheck_cmd, allow_repo_config or allow_repo_memory is refused.",
        .props = &.{
            .{ .name = "file", .desc = "path to a source file in a registered language" },
            .{ .name = "symbol", .desc = "symbol ref, e.g. Class.method or add" },
            .{ .name = "hash", .desc = "current 32-hex hash of the symbol from emetgate_symbols" },
            .{ .name = "body", .desc = "new function body including braces" },
        },
    },
    .{
        .name = "emetgate_mutate",
        .description = "In-memory dry-run mutation: returns the transformed source and new hash without touching disk.",
        .props = &.{
            .{ .name = "file", .desc = "path to a source file in a registered language" },
            .{ .name = "symbol", .desc = "symbol ref, e.g. Class.method or add" },
            .{ .name = "hash", .desc = "current 32-hex hash of the symbol from emetgate_symbols" },
            .{ .name = "body", .desc = "new function body including braces" },
        },
    },
    .{
        .name = "emetgate_read_file",
        .description = "Read a non-code file inside the repo (README, JSON, config, docs). Returns at most 16 KiB and sets truncated:true when cut. For TypeScript code use emetgate_skeleton and emetgate_read_symbol instead. Paths outside the repo, .git and .emetgate are refused.",
        .props = &.{.{ .name = "file", .desc = "path inside the repo" }},
    },
    .{
        .name = "emetgate_list",
        .description = "List git-tracked files under a directory of the repo (at most 2000 entries, truncated:true when cut).",
        .props = &.{.{ .name = "dir", .desc = "directory inside the repo; defaults to the repo root", .optional = true }},
    },
    .{
        .name = "emetgate_search",
        .description = "Find a literal, case-sensitive substring in git-tracked text files under a directory of the repo; returns file, line and the trimmed line (at most 200 matches, truncated:true when cut). Files of 1 MiB or more are skipped (files under 1 MiB are read).",
        .props = &.{
            .{ .name = "pattern", .desc = "literal text to find" },
            .{ .name = "dir", .desc = "directory inside the repo; defaults to the repo root", .optional = true },
        },
    },
    .{
        .name = "emetgate_scan",
        .description = "Measure one check expression against the git-tracked files of the repo and report its violations; nothing is written and the ledger is not read. The report has the same fields as `emetgate scan --check <check> --json`, lists at most 100 violations, and adds violation_count and truncated:true when cut.",
        .props = &.{
            .{ .name = "check", .desc = "check expression, e.g. forbid:networkidle" },
            .{ .name = "where", .desc = "scope: a file, a directory ending in /, or file#symbol; defaults to the whole repo", .optional = true },
        },
    },
};

pub fn serve(gpa: Allocator, io: std.Io, runtime: *Runtime, out: *Writer, policy: Policy) !void {
    const root: ?[]u8 = runner.repoRoot(gpa, io) catch null;
    defer if (root) |r| gpa.free(r);
    const workspace: ?[]u8 = if (root) |r| std.fmt.allocPrint(gpa, "{s}\\{s}", .{ r, shadow.workspace_dir }) catch null else null;
    defer if (workspace) |ws| gpa.free(ws);
    var observer: ?telemetry.Observer = if (workspace) |ws| .{ .workspace_abs = ws } else null;
    const observer_ptr: ?*telemetry.Observer = if (observer) |*o| o else null;
    var served = policy;
    served.root = root;

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
                in.tossBuffered();
                _ = in.discardDelimiterInclusive('\n') catch return;
                continue;
            },
            error.ReadFailed => return,
        } orelse return;
        const trimmed = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
        if (trimmed.len == 0) continue;

        if (try handleMessageObserved(gpa, io, runtime, trimmed, out, observer_ptr, served)) {
            try out.writeByte('\n');
            try out.flush();
        }
    }
}

pub fn handleMessage(gpa: Allocator, io: std.Io, runtime: *Runtime, line: []const u8, out: *Writer) !bool {
    return handleMessageObserved(gpa, io, runtime, line, out, null, .{});
}

pub fn handleMessageObserved(gpa: Allocator, io: std.Io, runtime: *Runtime, line: []const u8, out: *Writer, observer: ?*telemetry.Observer, policy: Policy) !bool {
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
        try handleToolsCall(gpa, io, runtime, out, request_id, msg, observer, policy);
        return true;
    }
    try writeRpcError(out, request_id, -32601, "Method not found");
    return true;
}

fn handleToolsCall(gpa: Allocator, io: std.Io, runtime: *Runtime, out: *Writer, id: Value, msg: Value, observer: ?*telemetry.Observer, policy: Policy) !void {
    const params = getField(msg, "params") orelse return writeRpcError(out, id, -32602, "Missing params");
    const name = getString(params, "name") orelse return writeRpcError(out, id, -32602, "Missing tool name");
    const arguments = getField(params, "arguments");

    var event: telemetry.Event = .{ .tool = name };
    const result = handlers.callTool(gpa, io, runtime, name, arguments, &event, policy) catch |err| {
        if (observer) |obs| {
            event.fail(@errorName(err));
            obs.record(gpa, io, event);
        }
        return switch (err) {
            error.UnknownTool => writeRpcError(out, id, -32602, "Unknown tool"),
            error.MissingArgument => writeRpcError(out, id, -32602, "Missing or invalid argument"),
            else => writeRpcError(out, id, -32603, "Internal error"),
        };
    };
    defer gpa.free(result.text);
    const decorated: ?[]u8 = if (observer) |obs| telemetry.observe(gpa, io, obs, event, result.text) else null;
    defer if (decorated) |d| gpa.free(d);
    try writeToolResult(out, id, decorated orelse result.text, result.is_error);
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
            try js.write(prop.ty);
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
    try writeBatchToolDef(&js);
    try js.endArray();
    try js.endObject();
    try js.endObject();
}

fn writeBatchToolDef(js: *std.json.Stringify) !void {
    try js.beginObject();
    try js.objectField("name");
    try js.write("emetgate_try_batch");
    try js.objectField("description");
    try js.write("All-or-nothing cross-file mutation: apply several symbol edits across files, run the project's trusted typecheck command (when configured) and then its test command once over all of them, and commit every file only if both pass; otherwise nothing is written. One edit per file. The test command is fixed by the user who started emetgate; a call that passes test_cmd, typecheck_cmd, allow_repo_config or allow_repo_memory is refused.");
    try js.objectField("inputSchema");
    try js.beginObject();
    try js.objectField("type");
    try js.write("object");
    try js.objectField("properties");
    try js.beginObject();
    try js.objectField("edits");
    try js.beginObject();
    try js.objectField("type");
    try js.write("array");
    try js.objectField("description");
    try js.write("one edit per file: {file, symbol, hash, body}");
    try js.objectField("items");
    try js.beginObject();
    try js.objectField("type");
    try js.write("object");
    try js.objectField("required");
    try js.beginArray();
    inline for (.{ "file", "symbol", "hash", "body" }) |field| try js.write(field);
    try js.endArray();
    try js.endObject();
    try js.endObject();
    try js.endObject();
    try js.objectField("required");
    try js.beginArray();
    try js.write("edits");
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
