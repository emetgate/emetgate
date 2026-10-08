const std = @import("std");
const commit_intent = @import("../platform/commit_intent.zig");
const commit_plan = @import("../platform/commit_plan.zig");
const telemetry = @import("telemetry.zig");
const handlers = @import("handlers.zig");
const policy_mod = @import("policy.zig");
const tool_result = @import("tool_result.zig");
const run_tool = @import("run_tool.zig");
const read_budget = @import("read_budget.zig");
const runner = @import("../platform/runner.zig");
const shadow = @import("../platform/shadow.zig");
const stdio = @import("../platform/stdio.zig");
const mirror_mod = @import("mirror.zig");
const tree_cache_mod = @import("../engine/tree_cache.zig");
const search_session_mod = @import("../platform/search_session.zig");
const tsserver = @import("../platform/tsserver.zig");
const map_tools = @import("map_tools.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;
const getField = tool_result.getField;
const getString = tool_result.getString;

pub const Policy = policy_mod.Policy;
pub const parsePolicy = policy_mod.parsePolicy;
pub const parseTree = policy_mod.parseTree;
pub const refusedRunEntry = policy_mod.refusedRunEntry;
pub const RunRefusal = policy_mod.RunRefusal;

const default_protocol_version = "2025-06-18";
const server_name = "emetgate";
pub const server_version = @import("version").version;
const max_message_bytes = 4 * 1024 * 1024;

pub const Prop = struct { name: []const u8, desc: []const u8, optional: bool = false, ty: []const u8 = "string" };
pub const Tool = struct { name: []const u8, description: []const u8, props: []const Prop };

pub const tool_defs = [_]Tool{
    .{
        .name = "emetgate_explore",
        .description = map_tools.explore_description,
        .props = &.{
            .{ .name = "question", .desc = "the question" },
            .{ .name = "names", .desc = "symbol names", .optional = true, .ty = "array" },
        },
    },
    .{
        .name = "emetgate_evidence",
        .description = map_tools.evidence_description,
        .props = &.{.{ .name = "names", .desc = "qualified names, Class.method or function", .ty = "array" }},
    },
    .{
        .name = "emetgate_symbols",
        .description = "Returns the function symbols of a source file with their content hashes.",
        .props = &.{.{ .name = "file", .desc = "path to a source file in a registered language" }},
    },
    .{
        .name = "emetgate_skeleton",
        .description = "Returns the outline of a source file: every symbol's signature without its body, the file hash, and every adopted rule that covers the file. With --mirror an unchanged outline is returned as one line; force:true returns it in full.",
        .props = &.{
            .{ .name = "file", .desc = "path to a source file in a registered language" },
            .{ .name = "force", .desc = "return the outline in full", .optional = true, .ty = "boolean" },
        },
    },
    .{
        .name = "emetgate_read_symbol",
        .description = "Returns the body of a symbol and its hash. symbols reads several; line_start and line_end read a line range widened to the symbols it overlaps; exactly one of symbol, symbols or the line pair. A body over the read budget (" ++ std.fmt.comptimePrint("{d}", .{read_budget.default_budget}) ++ " characters) is returned folded, with each elided line range named in place; detail:\"full\" returns every line. With --mirror an unchanged symbol is returned as one line; force:true returns it in full. nodes:true prefixes every line that starts a syntax node with that node's hash (hash|code).",
        .props = &.{
            .{ .name = "file", .desc = "path to a source file in a registered language" },
            .{ .name = "symbol", .desc = "symbol ref, e.g. Class.method or add", .optional = true },
            .{ .name = "symbols", .desc = "array of symbol refs to read together", .optional = true, .ty = "array" },
            .{ .name = "line_start", .desc = "1-based first line", .optional = true, .ty = "integer" },
            .{ .name = "line_end", .desc = "1-based last line", .optional = true, .ty = "integer" },
            .{ .name = "force", .desc = "return the body in full", .optional = true, .ty = "boolean" },
            .{ .name = "nodes", .desc = "true for node hashes (hash|code)", .optional = true, .ty = "boolean" },
            .{ .name = "detail", .desc = "\"full\" or \"budgeted\" (default)", .optional = true },
        },
    },
    .{
        .name = "emetgate_try",
        .description = "Replaces a symbol body, runs the configured typecheck and test commands in a sandbox, and writes only if they pass. Takes symbol, hash and body; or node and text, where node is a node hash from emetgate_read_symbol with nodes:true and an empty text deletes the node; or nodes: [{node, text}, ...] for several nodes of one file. Every byte outside the replaced span must stay unchanged.",
        .props = &.{
            .{ .name = "file", .desc = "path to a source file in a registered language" },
            .{ .name = "symbol", .desc = "symbol ref, e.g. Class.method or add", .optional = true },
            .{ .name = "hash", .desc = "current 32-hex hash of the symbol from emetgate_symbols", .optional = true },
            .{ .name = "body", .desc = "new function body including braces", .optional = true },
            .{ .name = "node", .desc = "node hash from emetgate_read_symbol with nodes:true", .optional = true },
            .{ .name = "text", .desc = "new source of that node; empty deletes it", .optional = true },
            .{ .name = "nodes", .desc = "array of {node, text} for several nodes of the same file", .optional = true, .ty = "array" },
        },
    },
    .{
        .name = "emetgate_rename",
        .description = "Renames a symbol and every reference to it as one batch, and writes only if the configured typecheck and test commands pass. A rename that touches another file or an exported symbol needs interface_change:true. Refused when a reference cannot be resolved (RenameUnresolved) or the name is also used as a string, in eval or as a computed key (DynamicReference).",
        .props = &.{
            .{ .name = "file", .desc = "path to the TypeScript or JavaScript file that declares the symbol" },
            .{ .name = "symbol", .desc = "symbol ref, e.g. Class.method or add" },
            .{ .name = "hash", .desc = "current 32-hex hash of the symbol from emetgate_symbols" },
            .{ .name = "new_name", .desc = "the new identifier" },
            .{ .name = "interface_change", .desc = "true to allow renaming across files or an exported symbol", .optional = true, .ty = "boolean" },
        },
    },
    .{
        .name = "emetgate_move",
        .description = "Moves a top-level function, class, interface, type, enum or variable to another file, existing or new, and rewrites every import as one batch; writes only if the configured typecheck and test commands pass. An exported symbol needs interface_change:true; a source or target with module-level side effects needs order_change:true. Refused: export default, a namespace import or re-export of the moved name, a name already bound in the target, a new import cycle.",
        .props = &.{
            .{ .name = "file", .desc = "path to the TypeScript or JavaScript file that declares the symbol" },
            .{ .name = "symbol", .desc = "ref of a top-level symbol or declaration" },
            .{ .name = "hash", .desc = "current 32-hex hash from emetgate_symbols (symbols or declarations)" },
            .{ .name = "target_file", .desc = "path of the target file; its directory must exist" },
            .{ .name = "interface_change", .desc = "true to allow moving an exported symbol", .optional = true, .ty = "boolean" },
            .{ .name = "order_change", .desc = "true to allow a change of module evaluation order", .optional = true, .ty = "boolean" },
        },
    },
    .{
        .name = "emetgate_move_file",
        .description = "Moves or renames a TypeScript or JavaScript file and rewrites every relative import to and from it as one batch; writes only if the configured typecheck and test commands pass. The target must not exist. A file named by package.json or tsconfig paths needs interface_change:true. Refused: a rename that only changes letter case, a require or dynamic import that reaches the file.",
        .props = &.{
            .{ .name = "from", .desc = "path of the file to move" },
            .{ .name = "to", .desc = "new path inside the repo; must not exist" },
            .{ .name = "from_hash", .desc = "whole-file hash (file_hash from emetgate_read_file or emetgate_skeleton)" },
            .{ .name = "interface_change", .desc = "true to allow moving a file named by package.json or tsconfig paths", .optional = true, .ty = "boolean" },
        },
    },
    .{
        .name = "emetgate_mutate",
        .description = "Returns the source and the new hash that replacing a symbol body would produce, without writing.",
        .props = &.{
            .{ .name = "file", .desc = "path to a source file in a registered language" },
            .{ .name = "symbol", .desc = "symbol ref, e.g. Class.method or add" },
            .{ .name = "hash", .desc = "current 32-hex hash of the symbol from emetgate_symbols" },
            .{ .name = "body", .desc = "new function body including braces" },
        },
    },
    .{
        .name = "emetgate_read_file",
        .description = "Returns a non-code file of the repository. A .json file returns its key tree with a hash per pointer, or with pointer one value. A .md file returns its heading tree, or with heading one section. Any other file returns at most 16 KiB, or with line_start and line_end a line range. A source file needs raw:true. With --mirror unchanged content is returned as one line; force:true returns it in full.",
        .props = &.{
            .{ .name = "file", .desc = "path inside the repo" },
            .{ .name = "raw", .desc = "true for the raw text of a source, .json or .md file", .optional = true, .ty = "boolean" },
            .{ .name = "pointer", .desc = "JSON pointer, e.g. /dependencies/express", .optional = true },
            .{ .name = "heading", .desc = "exact heading text", .optional = true },
            .{ .name = "line_start", .desc = "1-based first line; a source, .json or .md file also needs raw:true", .optional = true, .ty = "integer" },
            .{ .name = "line_end", .desc = "1-based last line, inclusive", .optional = true, .ty = "integer" },
            .{ .name = "force", .desc = "return the content in full", .optional = true, .ty = "boolean" },
        },
    },
    .{
        .name = "emetgate_list",
        .description = "Returns the git-tracked files under a directory, at most 2000.",
        .props = &.{.{ .name = "dir", .desc = "directory inside the repo; defaults to the repo root", .optional = true }},
    },
    .{
        .name = "emetgate_search",
        .description = "Returns the places where a literal pattern, or with regex:true a regular expression, occurs in git-tracked text files, case-sensitive. Hits are grouped by file and by enclosing symbol with its content hash, JSON pointer or Markdown heading, and tagged code, comment or string and definition or reference. At most 200 hits; files of 1 MiB or more are skipped.",
        .props = &.{
            .{ .name = "pattern", .desc = "text or, with regex:true, a regular expression to find" },
            .{ .name = "dir", .desc = "directory inside the repo; defaults to the repo root", .optional = true },
            .{ .name = "regex", .desc = "true when pattern is a regular expression", .optional = true, .ty = "boolean" },
            .{ .name = "kinds", .desc = "kinds to keep: code, comment, string", .optional = true, .ty = "array" },
        },
    },
    .{
        .name = "emetgate_scan",
        .description = "Returns the violations of one check expression in the git-tracked files, at most 100; writes nothing.",
        .props = &.{
            .{ .name = "check", .desc = "check expression, e.g. forbid:networkidle" },
            .{ .name = "where", .desc = "scope: a file, a directory ending in /, or file#symbol; defaults to the whole repo", .optional = true },
        },
    },
    .{
        .name = "emetgate_git",
        .description = "Returns read-only git output: status, diff (staged:true for the staged diff), log or show. Output is capped.",
        .props = &.{
            .{ .name = "sub", .desc = "one of: status, diff, log, show" },
            .{ .name = "path", .desc = "limit to this file or directory inside the repo", .optional = true },
            .{ .name = "staged", .desc = "diff only: true for the staged (--cached) diff instead of the working tree", .optional = true, .ty = "boolean" },
            .{ .name = "n", .desc = "log only: how many commits, newest first (default 20, at most 200)", .optional = true, .ty = "integer" },
            .{ .name = "commit", .desc = "show only: a commit hash (4 to 40 hex characters) or HEAD, optionally with ~N or ^N", .optional = true },
        },
    },
    .{
        .name = "emetgate_run",
        .description = run_tool.description,
        .props = &.{.{ .name = "command", .desc = "one allowlist entry, byte for byte; omit to list the allowlist", .optional = true }},
    },
    .{
        .name = "emetgate_write_doc",
        .description = "Replaces one node of a non-code file: a JSON pointer's value, a Markdown section or a line range of a text file; writes only if the configured typecheck and test commands pass in a sandbox. Exactly one of pointer, heading or the line pair. A JSON value must be valid JSON; a Markdown section must start with a heading line.",
        .props = &.{
            .{ .name = "file", .desc = "path to a .json, .md or plain text file inside the repo" },
            .{ .name = "hash", .desc = "content hash of the current node, from emetgate_read_file" },
            .{ .name = "content", .desc = "replacement text for the selected node" },
            .{ .name = "pointer", .desc = "JSON pointer, e.g. /dependencies/express", .optional = true },
            .{ .name = "heading", .desc = "exact heading text", .optional = true },
            .{ .name = "line_start", .desc = "1-based first line", .optional = true, .ty = "integer" },
            .{ .name = "line_end", .desc = "1-based last line", .optional = true, .ty = "integer" },
        },
    },
};

pub fn finishPendingCommits(gpa: Allocator, io: std.Io, root: []const u8) void {
    const dir = commit_intent.dirOf(gpa, root) catch return;
    defer gpa.free(dir);
    std.Io.Dir.cwd().access(io, dir, .{}) catch return;
    const lock = shadow.Lock.acquire(io, root) catch return;
    defer lock.release();
    const found = commit_plan.recoverFound(gpa, io, root) catch return;
    if (found.left != 0) std.debug.print("emetgate: recover left as found ({s}): {s}\n", .{ found.reason orelse "", found.names() });
}

pub fn serve(gpa: Allocator, io: std.Io, runtime: *Runtime, out: *Writer, policy: Policy) !void {
    const root: ?[]u8 = runner.repoRoot(gpa, io) catch null;
    defer if (root) |r| gpa.free(r);
    if (root) |r| finishPendingCommits(gpa, io, r);
    const workspace: ?[]u8 = if (root) |r| std.fmt.allocPrint(gpa, "{s}\\{s}", .{ r, shadow.workspace_dir }) catch null else null;
    defer if (workspace) |ws| gpa.free(ws);
    var observer: ?telemetry.Observer = if (workspace) |ws| .{ .workspace_abs = ws } else null;
    const observer_ptr: ?*telemetry.Observer = if (observer) |*o| o else null;
    var served = policy;
    served.root = root;
    var session_mirror: mirror_mod.Mirror = .init(gpa, policy.mirror_enabled);
    defer session_mirror.deinit();
    served.mirror = &session_mirror;
    var session_tree_cache: tree_cache_mod.TreeCache = .init(gpa);
    defer session_tree_cache.deinit();
    served.tree_cache = &session_tree_cache;
    var session_search = search_session_mod.Session.init(gpa, io, root, .{});
    defer session_search.deinit();
    served.search_session = &session_search;
    var language_service: tsserver.Session = .{ .gpa = gpa, .io = io, .root = root };
    defer language_service.deinit();
    served.language_service = &language_service;
    const map_session: ?*map_tools.Session = if (root) |r| map_tools.Session.create(gpa, io, runtime, r) catch null else null;
    defer if (map_session) |ms| ms.destroy();
    if (map_session) |ms| ms.build() catch {};
    served.map_session = map_session;

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
        try writeToolsList(out, request_id, policy.commit);
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
    const result = callAny(gpa, io, runtime, name, arguments, &event, policy) catch |err| {
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

fn callAny(gpa: Allocator, io: std.Io, runtime: *Runtime, name: []const u8, arguments: ?Value, event: *telemetry.Event, policy: Policy) !tool_result.ToolResult {
    const explore = std.mem.eql(u8, name, "emetgate_explore");
    const evidence = std.mem.eql(u8, name, "emetgate_evidence");
    if (!explore and !evidence) return handlers.callTool(gpa, io, runtime, name, arguments, event, policy);
    const session = policy.map_session orelse return .{ .text = try gpa.dupe(u8, "the project map is not available outside a git repository"), .is_error = true };
    return if (explore) session.explore(gpa, arguments) else session.evidenceTool(gpa, arguments);
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

pub const commit_tools = [_][]const u8{ "emetgate_try", "emetgate_rename", "emetgate_move", "emetgate_move_file", "emetgate_write_doc" };
const commit_prop: Prop = .{ .name = "message", .desc = "commit message for this change" };

fn commits(tool: []const u8) bool {
    for (commit_tools) |name| {
        if (std.mem.eql(u8, name, tool)) return true;
    }
    return false;
}

fn writeToolsList(out: *Writer, id: Value, commit: bool) !void {
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
        const with_message = commit and commits(tool.name);
        if (with_message) try writeCommitProp(&js);
        try js.endObject();
        try js.objectField("required");
        try js.beginArray();
        for (tool.props) |prop| {
            if (!prop.optional) try js.write(prop.name);
        }
        if (with_message) try js.write(commit_prop.name);
        try js.endArray();
        try js.endObject();
        try js.endObject();
    }
    try writeBatchToolDef(&js, commit);
    try js.endArray();
    try js.endObject();
    try js.endObject();
}

fn writeCommitProp(js: *std.json.Stringify) !void {
    try js.objectField(commit_prop.name);
    try js.beginObject();
    try js.objectField("type");
    try js.write(commit_prop.ty);
    try js.objectField("description");
    try js.write(commit_prop.desc);
    try js.endObject();
}

fn writeBatchToolDef(js: *std.json.Stringify, commit: bool) !void {
    try js.beginObject();
    try js.objectField("name");
    try js.write("emetgate_try_batch");
    try js.objectField("description");
    try js.write("Applies several edits across files as one unit: runs the configured typecheck and test commands once and writes every file only if they pass. One edit per file. kind \"code\" (default): {file, symbol, hash, body} to write, {file, op: \"delete\", symbol, hash} to remove a symbol, {file, op: \"delete\"} to delete a file, {file, node, text} or {file, nodes: [{node, text}, ...]} to replace syntax nodes; hash \"absent\" adds a new top-level symbol or a new file. kind \"doc\": {file, hash, content} plus exactly one of pointer, heading or the line pair.");
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
    try js.write("the edits, one per file");
    try js.objectField("items");
    try js.beginObject();
    try js.objectField("type");
    try js.write("object");
    try js.objectField("properties");
    try js.beginObject();
    inline for (.{ "file", "symbol", "hash", "body", "node", "text", "content", "pointer", "heading" }) |field| {
        try js.objectField(field);
        try js.beginObject();
        try js.objectField("type");
        try js.write("string");
        try js.endObject();
    }
    inline for (.{ "line_start", "line_end" }) |field| {
        try js.objectField(field);
        try js.beginObject();
        try js.objectField("type");
        try js.write("integer");
        try js.endObject();
    }
    try js.objectField("nodes");
    try js.beginObject();
    try js.objectField("type");
    try js.write("array");
    try js.endObject();
    try js.objectField("kind");
    try js.beginObject();
    try js.objectField("type");
    try js.write("string");
    try js.objectField("enum");
    try js.beginArray();
    try js.write("code");
    try js.write("doc");
    try js.endArray();
    try js.endObject();
    try js.objectField("op");
    try js.beginObject();
    try js.objectField("type");
    try js.write("string");
    try js.objectField("enum");
    try js.beginArray();
    try js.write("write");
    try js.write("delete");
    try js.endArray();
    try js.endObject();
    try js.endObject();
    try js.objectField("required");
    try js.beginArray();
    try js.write("file");
    try js.endArray();
    try js.endObject();
    try js.endObject();
    if (commit) try writeCommitProp(js);
    try js.endObject();
    try js.objectField("required");
    try js.beginArray();
    try js.write("edits");
    if (commit) try js.write(commit_prop.name);
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
