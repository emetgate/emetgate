const std = @import("std");
const tool_names = @import("../engine/tool_names.zig");
const commit_intent = @import("../platform/commit_intent.zig");
const commit_plan = @import("../platform/commit_plan.zig");
const telemetry = @import("telemetry.zig");
const json_input = @import("json_input.zig");
const handlers = @import("handlers.zig");
const policy_mod = @import("policy.zig");
const tool_result = @import("tool_result.zig");
const wire = @import("wire.zig");
const run_tool = @import("run_tool.zig");
const open_run = @import("open_run.zig");
const git_write = @import("git_write.zig");
const edit_tool = @import("edit_tool.zig");
const read_budget = @import("read_budget.zig");
const runner = @import("../platform/runner.zig");
const shadow = @import("../platform/shadow.zig");
const cache_gc = @import("../platform/cache_gc.zig");
const cache_lease = @import("../platform/cache_lease.zig");
const stdio = @import("../platform/stdio.zig");
const mirror_mod = @import("mirror.zig");
const context_epoch = @import("context_epoch.zig");
const tree_cache_mod = @import("../engine/tree_cache.zig");
const batch_stage_mod = @import("batch_stage.zig");
const search_session_mod = @import("../platform/search_session.zig");
const tsserver = @import("../platform/tsserver.zig");
const map_tools = @import("map_tools.zig");
const find_tools = @import("find_tools.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;
const getField = tool_result.getField;
const getString = tool_result.getString;

pub const Policy = policy_mod.Policy;
pub const parsePolicy = policy_mod.parsePolicy;
pub const open_run_flag = policy_mod.open_run_flag;
pub const parseTree = policy_mod.parseTree;
pub const refusedRunEntry = policy_mod.refusedRunEntry;
pub const RunRefusal = policy_mod.RunRefusal;

const default_protocol_version = "2025-06-18";
const server_name = "emetgate";
pub const server_version = @import("version").version;
const max_message_bytes = 4 * 1024 * 1024;

pub const Prop = struct { name: []const u8, desc: []const u8, optional: bool = false, ty: []const u8 = "string" };
pub const Tool = struct { name: []const u8, description: []const u8, props: []const Prop };

const budget_text = std.fmt.comptimePrint("{d}", .{read_budget.default_budget});

pub const open_run_def: Tool = .{
    .name = "emetgate_run",
    .description = open_run.description,
    .props = &.{
        .{ .name = "command", .desc = open_run.command_desc },
        .{ .name = "raw", .desc = open_run.raw_desc, .optional = true, .ty = "boolean" },
        .{ .name = "timeout_s", .desc = open_run.timeout_desc, .optional = true, .ty = "integer" },
    },
};

pub fn servedDef(tool: Tool, open: bool) Tool {
    return if (open and std.mem.eql(u8, tool.name, open_run_def.name)) open_run_def else tool;
}

pub const tool_defs = [_]Tool{
    .{
        .name = "emetgate_explore",
        .description = map_tools.explore_description,
        .props = &.{
            .{ .name = "question", .desc = "" },
            .{ .name = "names", .desc = "", .optional = true, .ty = "array" },
        },
    },
    .{
        .name = "emetgate_evidence",
        .description = map_tools.evidence_description,
        .props = &.{.{ .name = "names", .desc = "Class.method or function", .ty = "array" }},
    },
    .{
        .name = "emetgate_symbols",
        .description = "Lists a source file's symbols.",
        .props = &.{.{ .name = "file", .desc = "" }},
    },
    .{
        .name = "emetgate_skeleton",
        .description = "Outline of a source file (whole if under 8 KiB) with file_hash and covering rules.",
        .props = &.{
            .{ .name = "file", .desc = "" },
            .{ .name = "force", .desc = "", .optional = true, .ty = "boolean" },
        },
    },
    .{
        .name = "emetgate_read_symbol",
        .description = "Reads symbol bodies with hashes by symbol, symbols or line_start+line_end; docs fold, bodies over " ++ budget_text ++ " chars too, unless detail:\"full\". nodes:true adds node ids for emetgate_try.",
        .props = &.{
            .{ .name = "file", .desc = "" },
            .{ .name = "symbol", .desc = "ref, e.g. Class.method or add", .optional = true },
            .{ .name = "symbols", .desc = "", .optional = true, .ty = "array" },
            .{ .name = "line_start", .desc = "", .optional = true, .ty = "integer" },
            .{ .name = "line_end", .desc = "", .optional = true, .ty = "integer" },
            .{ .name = "force", .desc = "", .optional = true, .ty = "boolean" },
            .{ .name = "nodes", .desc = "", .optional = true, .ty = "boolean" },
            .{ .name = "detail", .desc = "\"full\" or \"budgeted\"", .optional = true },
        },
    },
    .{
        .name = "emetgate_try",
        .description = "Edits code, gated: symbol+hash+body (as read; hash \"absent\" + whole declaration adds one), or node+text / nodes:[{node,text}] (ids: emetgate_read_symbol nodes:true).",
        .props = &.{
            .{ .name = "file", .desc = "" },
            .{ .name = "symbol", .desc = "", .optional = true },
            .{ .name = "hash", .desc = "from emetgate_symbols, or \"absent\"", .optional = true },
            .{ .name = "body", .desc = "", .optional = true },
            .{ .name = "node", .desc = "", .optional = true },
            .{ .name = "text", .desc = "", .optional = true },
            .{ .name = "nodes", .desc = "", .optional = true, .ty = "array" },
        },
    },
    .{
        .name = "emetgate_rename",
        .description = "Renames a symbol and its references, gated; other files or exports need interface_change:true.",
        .props = &.{
            .{ .name = "file", .desc = "TS, JS, Python or C# file declaring it" },
            .{ .name = "symbol", .desc = "" },
            .{ .name = "hash", .desc = "" },
            .{ .name = "new_name", .desc = "" },
            .{ .name = "interface_change", .desc = "", .optional = true, .ty = "boolean" },
            .{ .name = "allow_dynamic", .desc = "", .optional = true, .ty = "boolean" },
        },
    },
    .{
        .name = "emetgate_move",
        .description = "Moves a top-level declaration to target_file, rewriting imports, gated. Exports need interface_change:true, side effects order_change:true.",
        .props = &.{
            .{ .name = "file", .desc = "TS or JS file declaring it" },
            .{ .name = "symbol", .desc = "" },
            .{ .name = "hash", .desc = "" },
            .{ .name = "target_file", .desc = "" },
            .{ .name = "interface_change", .desc = "", .optional = true, .ty = "boolean" },
            .{ .name = "order_change", .desc = "", .optional = true, .ty = "boolean" },
        },
    },
    .{
        .name = "emetgate_move_file",
        .description = "Moves a TS/JS file, rewriting relative imports, gated; one named in package.json or tsconfig paths needs interface_change:true.",
        .props = &.{
            .{ .name = "from", .desc = "" },
            .{ .name = "to", .desc = "must not exist" },
            .{ .name = "from_hash", .desc = "file_hash of from" },
            .{ .name = "interface_change", .desc = "", .optional = true, .ty = "boolean" },
        },
    },
    .{
        .name = "emetgate_mutate",
        .description = "Previews a symbol body replacement without writing.",
        .props = &.{
            .{ .name = "file", .desc = "" },
            .{ .name = "symbol", .desc = "" },
            .{ .name = "hash", .desc = "" },
            .{ .name = "body", .desc = "" },
        },
    },
    .{
        .name = "emetgate_read_file",
        .description = "Reads up to 32 files: .json key tree or pointer value; .md headings or heading section; else 16 KiB or lines.",
        .props = &.{
            .{ .name = "file", .desc = "", .optional = true },
            .{ .name = "files", .desc = "", .optional = true, .ty = "array" },
            .{ .name = "raw", .desc = "", .optional = true, .ty = "boolean" },
            .{ .name = "pointer", .desc = "e.g. /a/b", .optional = true },
            .{ .name = "heading", .desc = "", .optional = true },
            .{ .name = "line_start", .desc = "", .optional = true, .ty = "integer" },
            .{ .name = "line_end", .desc = "", .optional = true, .ty = "integer" },
            .{ .name = "force", .desc = "", .optional = true, .ty = "boolean" },
        },
    },
    .{
        .name = "emetgate_list",
        .description = "Lists up to 2000 tracked files under dir.",
        .props = &.{.{ .name = "dir", .desc = "", .optional = true }},
    },
    .{
        .name = "emetgate_search",
        .description = "Finds a case-sensitive literal (or regex:true) in tracked text under dir: path, then line:text per hit (* definition, |N legend). Ends \u{2713} if complete, else next offset; detail:\"full\" allows 200.",
        .props = &.{
            .{ .name = "pattern", .desc = "" },
            .{ .name = "dir", .desc = "", .optional = true },
            .{ .name = "regex", .desc = "", .optional = true, .ty = "boolean" },
            .{ .name = "kinds", .desc = "[\"code\"] skips comments and strings", .optional = true, .ty = "array" },
            .{ .name = "offset", .desc = "", .optional = true, .ty = "integer" },
            .{ .name = "detail", .desc = "\"full\" or \"compact\"", .optional = true },
        },
    },
    .{
        .name = "emetgate_find",
        .description = find_tools.description,
        .props = &.{.{ .name = "pattern", .desc = "1 to 4096 bytes" }},
    },
    .{
        .name = "emetgate_scan",
        .description = "Lists up to 100 violations of one check in tracked files.",
        .props = &.{
            .{ .name = "check", .desc = "e.g. forbid:networkidle" },
            .{ .name = "where", .desc = "file, dir/ or file#symbol", .optional = true },
        },
    },
    .{
        .name = "emetgate_commit",
        .description = "Commits pending gated changes; refused on outside edits or tests broken this session.",
        .props = &.{.{ .name = "message", .desc = "" }},
    },
    .{
        .name = "emetgate_git",
        .description = "Read-only git, symbol-anchored, within " ++ budget_text ++ " chars; detail:\"full\" is raw. log pages by next_cursor; blame takes commit and a line range.",
        .props = &.{
            .{ .name = "sub", .desc = "status, diff, log, show, blame, or with args any read-only git e.g. grep" },
            .{ .name = "args", .desc = "", .optional = true, .ty = "array" },
            .{ .name = "path", .desc = "required for blame", .optional = true },
            .{ .name = "detail", .desc = "", .optional = true },
            .{ .name = "symbols_only", .desc = "", .optional = true, .ty = "boolean" },
            .{ .name = "staged", .desc = "", .optional = true, .ty = "boolean" },
            .{ .name = "n", .desc = "", .optional = true, .ty = "integer" },
            .{ .name = "cursor", .desc = "", .optional = true },
            .{ .name = "commit", .desc = "", .optional = true },
            .{ .name = "line_start", .desc = "", .optional = true, .ty = "integer" },
            .{ .name = "line_end", .desc = "", .optional = true, .ty = "integer" },
        },
    },
    .{
        .name = "emetgate_git_write",
        .description = git_write.description,
        .props = &.{
            .{ .name = "args", .desc = "", .ty = "array" },
            .{ .name = "force", .desc = "", .optional = true, .ty = "boolean" },
        },
    },
    .{
        .name = "emetgate_run",
        .description = run_tool.description,
        .props = &.{.{ .name = "command", .desc = "one allowlist entry, verbatim", .optional = true }},
    },
    .{
        .name = "emetgate_edit",
        .description = edit_tool.edit_description,
        .props = &.{
            .{ .name = "file", .desc = "" },
            .{ .name = "old_string", .desc = "" },
            .{ .name = "new_string", .desc = "" },
            .{ .name = "replace_all", .desc = "", .optional = true, .ty = "boolean" },
        },
    },
    .{
        .name = "emetgate_write",
        .description = edit_tool.write_description,
        .props = &.{
            .{ .name = "file", .desc = "" },
            .{ .name = "content", .desc = "" },
        },
    },
    .{
        .name = "emetgate_write_doc",
        .description = "Replaces a JSON value, Markdown section or line range, gated.",
        .props = &.{
            .{ .name = "file", .desc = "" },
            .{ .name = "hash", .desc = "from emetgate_read_file" },
            .{ .name = "content", .desc = "" },
            .{ .name = "pointer", .desc = "", .optional = true },
            .{ .name = "heading", .desc = "", .optional = true },
            .{ .name = "line_start", .desc = "", .optional = true, .ty = "integer" },
            .{ .name = "line_end", .desc = "", .optional = true, .ty = "integer" },
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

pub const Served = struct {
    gpa: Allocator,
    io: std.Io,
    root: ?[]u8,
    workspace: ?[]u8,
    observer: ?telemetry.Observer,
    mirror: mirror_mod.Mirror,
    context: context_epoch.Watch,
    tree_cache: tree_cache_mod.TreeCache,
    search: search_session_mod.Session,
    language_service: tsserver.Session,
    map_session: ?*map_tools.Session,
    find_session: ?*find_tools.Session,
    batch_stage: batch_stage_mod.Store,
    policy: Policy,
    cache_sweep: cache_gc.Background,

    pub const Options = struct {
        root: ?[]const u8 = null,
        fact_store: ?[]const u8 = null,
        environ: ?*const std.process.Environ.Map = null,
    };

    pub fn open(self: *Served, gpa: Allocator, io: std.Io, runtime: *Runtime, policy: Policy, options: Options) void {
        const root: ?[]u8 = if (options.root) |given| gpa.dupe(u8, given) catch null else runner.repoRoot(gpa, io) catch null;
        if (root) |r| finishPendingCommits(gpa, io, r);
        const workspace: ?[]u8 = if (root) |r| std.fmt.allocPrint(gpa, "{s}\\{s}", .{ r, shadow.workspace_dir }) catch null else null;
        self.* = .{
            .gpa = gpa,
            .io = io,
            .root = root,
            .workspace = workspace,
            .observer = if (workspace) |ws| .{ .workspace_abs = ws } else null,
            .mirror = .init(gpa, policy.mirror_enabled),
            .context = .init(gpa, options.environ),
            .tree_cache = .init(gpa),
            .search = search_session_mod.Session.init(gpa, io, root, .{}),
            .language_service = .{ .gpa = gpa, .io = io, .root = root },
            .map_session = if (root) |r| map_tools.Session.create(gpa, io, runtime, r) catch null else null,
            .find_session = if (root) |r| find_tools.Session.create(gpa, io, r) catch null else null,
            .batch_stage = .init(gpa),
            .policy = policy,
            .cache_sweep = .{},
        };
        self.policy.root = root;
        self.policy.mirror = &self.mirror;
        self.policy.context = if (policy.mirror_trusted or options.environ == null) null else &self.context;
        self.policy.tree_cache = &self.tree_cache;
        self.policy.search_session = &self.search;
        self.policy.language_service = &self.language_service;
        self.policy.map_session = self.map_session;
        self.policy.find_session = self.find_session;
        self.policy.batch_stage = &self.batch_stage;
        self.search.start();
        if (self.map_session) |ms| {
            ms.store_override = options.fact_store;
            ms.start();
        }
        if (self.find_session) |fs| fs.start();
        if (root) |r| self.startCacheSweep(r);
    }

    fn startCacheSweep(self: *Served, root: []const u8) void {
        cache_lease.holdDefault(self.gpa, root) catch |err| {
            cache_gc.note(err);
            std.debug.print("emetgate: could not lease the caches of {s}, skipping the cache sweep: {t}\n", .{ root, err });
            return;
        };
        self.cache_sweep.start(self.gpa, self.io, self.policy.cache.policy);
    }

    pub fn close(self: *Served) void {
        self.cache_sweep.stop();
        if (self.find_session) |fs| fs.destroy();
        if (self.map_session) |ms| ms.destroy();
        self.batch_stage.deinit();
        self.language_service.deinit();
        self.search.deinit();
        self.tree_cache.deinit();
        self.mirror.deinit();
        self.context.deinit();
        if (self.workspace) |ws| self.gpa.free(ws);
        if (self.root) |r| self.gpa.free(r);
    }

    pub fn handle(self: *Served, runtime: *Runtime, line: []const u8, out: *Writer) !bool {
        const observer: ?*telemetry.Observer = if (self.observer) |*o| o else null;
        return handleMessageObserved(self.gpa, self.io, runtime, line, out, observer, self.policy);
    }
};

pub fn serve(gpa: Allocator, io: std.Io, runtime: *Runtime, out: *Writer, policy: Policy, environ: *const std.process.Environ.Map) !void {
    try tool_names.setPrefix(policy.tool_prefix);
    var served: Served = undefined;
    served.open(gpa, io, runtime, policy, .{ .environ = environ });
    defer served.close();

    const read_buffer = try gpa.alloc(u8, max_message_bytes);
    defer gpa.free(read_buffer);
    var reader = stdio.stdinReader(io, read_buffer);
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

        if (try served.handle(runtime, trimmed, out)) {
            try out.writeByte('\n');
            try out.flush();
        }
    }
}

pub fn handleMessage(gpa: Allocator, io: std.Io, runtime: *Runtime, line: []const u8, out: *Writer) !bool {
    return handleMessageObserved(gpa, io, runtime, line, out, null, .{});
}

pub fn handleMessageObserved(gpa: Allocator, io: std.Io, runtime: *Runtime, line: []const u8, out: *Writer, observer: ?*telemetry.Observer, policy: Policy) !bool {
    var parsed = json_input.parse(Value, gpa, line, .{}) catch {
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
        try writeToolsList(out, request_id, policy.commit, policy.open_run);
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
    tool_result.clearMissing();
    wire.clearFix();
    const result = callAny(gpa, io, runtime, name, arguments, &event, policy) catch |err| {
        if (observer) |obs| {
            event.fail(@errorName(err));
            obs.record(gpa, io, event);
        }
        return switch (err) {
            error.UnknownTool => writeRpcError(out, id, -32602, "Unknown tool"),
            error.MissingArgument => writeMissingArgument(out, id),
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
    defer if (session.takeNote()) |note| {
        event.reason = note;
    };
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
    try js.objectField("instructions");
    try tool_names.writeJson(&js, instructions);
    try js.endObject();
    try js.endObject();
}

pub const instructions = "Read code with emetgate_skeleton for the outline and emetgate_read_symbol for bodies and hashes, and other files with emetgate_read_file. Search with emetgate_search (tracked text, regex) or emetgate_find (any literal), or ask emetgate_explore a question. Edit code with emetgate_try, several files with emetgate_try_batch, and non-code files with emetgate_write_doc; each writes only if typecheck passes and no test fails that did not fail before (pytest and dotnet let a new test fail until emetgate_commit), and takes the hash you last read. Every error reply has a fix field saying how to recover. Source these tools return is already read; do not read it again with another tool.";

fn writeEmptyResult(out: *Writer, id: Value) !void {
    var js: std.json.Stringify = .{ .writer = out };
    try js.beginObject();
    try envelope(&js, id);
    try js.objectField("result");
    try js.beginObject();
    try js.endObject();
    try js.endObject();
}

pub const commit_tools = [_][]const u8{ "emetgate_try", "emetgate_rename", "emetgate_move", "emetgate_move_file", "emetgate_write_doc", "emetgate_edit", "emetgate_write" };
const commit_prop: Prop = .{ .name = "message", .desc = "commit message for this change" };

fn commits(tool: []const u8) bool {
    for (commit_tools) |name| {
        if (std.mem.eql(u8, name, tool)) return true;
    }
    return false;
}

fn writeToolsList(out: *Writer, id: Value, commit: bool, open: bool) !void {
    var js: std.json.Stringify = .{ .writer = out };
    try js.beginObject();
    try envelope(&js, id);
    try js.objectField("result");
    try js.beginObject();
    try js.objectField("tools");
    try js.beginArray();
    for (tool_defs) |listed| {
        const tool = servedDef(listed, open);
        try js.beginObject();
        try js.objectField("name");
        try js.write(tool.name);
        try js.objectField("description");
        try tool_names.writeJson(&js, tool.description);
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
            if (prop.desc.len > 0) {
                try js.objectField("description");
                try tool_names.writeJson(&js, prop.desc);
            }
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

pub const batch_description = "Gated multi-file edits: {file,symbol,hash,body}, {file,node,text}, {file,nodes}, {file,old_string,new_string,replace_all?} or {file,hash,content} (whole file, hash \"absent\" creates; pointer, heading or line_start+line_end for a region); op:\"delete\" drops a symbol, or a file by its file_hash. One file's items apply in order. On failure, send retry and only the items of files you change.";

fn writeBatchToolDef(js: *std.json.Stringify, commit: bool) !void {
    try js.beginObject();
    try js.objectField("name");
    try js.write("emetgate_try_batch");
    try js.objectField("description");
    try tool_names.writeJson(js, batch_description);
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
    try js.objectField("retry");
    try js.beginObject();
    try js.objectField("type");
    try js.write("string");
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

pub const missing_argument_message = "Missing or invalid argument";

fn writeMissingArgument(out: *Writer, id: Value) !void {
    const field = tool_result.missingField() orelse return writeRpcError(out, id, -32602, missing_argument_message);
    var buf: [512]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, missing_argument_message ++ ": {s}", .{field}) catch missing_argument_message;
    return writeRpcError(out, id, -32602, message);
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
