const std = @import("std");
const builtin = @import("builtin");
const symbol = @import("../engine/symbol.zig");
const cas = @import("../engine/cas.zig");
const skeleton = @import("../engine/skeleton.zig");
const wire = @import("wire.zig");
const telemetry = @import("telemetry.zig");
const runner = @import("../platform/runner.zig");
const shadow = @import("../platform/shadow.zig");
const stdio = @import("../platform/stdio.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;
const Snapshot = @import("../engine/loader.zig").Snapshot;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;

const default_protocol_version = "2025-06-18";
const server_name = "synapse";
const server_version = "0.1.0";
const max_message_bytes = 4 * 1024 * 1024;

const Prop = struct { name: []const u8, desc: []const u8, optional: bool = false, ty: []const u8 = "string" };
const Tool = struct { name: []const u8, description: []const u8, props: []const Prop };

const tool_defs = [_]Tool{
    .{
        .name = "synapse_symbols",
        .description = "List addressable function symbols in a TypeScript file with their content hashes.",
        .props = &.{.{ .name = "file", .desc = "path to a .ts file" }},
    },
    .{
        .name = "synapse_skeleton",
        .description = "Structural outline of a TypeScript (.ts) file: every symbol's signature with bodies elided. Read this instead of the whole file to locate a target cheaply. Other files are refused; use synapse_read_file for docs and config.",
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
        .description = "Atomic mutation: replaces the symbol body, runs the project's trusted test command in a sandbox, and writes to disk only if it passes; otherwise nothing is written. The test command is fixed by the user who started synapse (synapse mcp --test <cmd>, or the repo .synapserc.json with --allow-repo-config); a call that passes test_cmd or allow_repo_config is refused.",
        .props = &.{
            .{ .name = "file", .desc = "path to a .ts file" },
            .{ .name = "symbol", .desc = "symbol ref, e.g. Class.method or add" },
            .{ .name = "hash", .desc = "current 32-hex hash of the symbol from synapse_symbols" },
            .{ .name = "body", .desc = "new function body including braces" },
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
    .{
        .name = "synapse_read_file",
        .description = "Read a non-code file inside the repo (README, JSON, config, docs). Returns at most 16 KiB and sets truncated:true when cut. For TypeScript code use synapse_skeleton and synapse_read_symbol instead. Paths outside the repo, .git and .synapse are refused.",
        .props = &.{.{ .name = "file", .desc = "path inside the repo" }},
    },
    .{
        .name = "synapse_list",
        .description = "List git-tracked files under a directory of the repo (at most 2000 entries, truncated:true when cut).",
        .props = &.{.{ .name = "dir", .desc = "directory inside the repo; defaults to the repo root", .optional = true }},
    },
    .{
        .name = "synapse_search",
        .description = "Find a literal, case-sensitive substring in git-tracked text files under a directory of the repo; returns file, line and the trimmed line (at most 200 matches, truncated:true when cut).",
        .props = &.{
            .{ .name = "pattern", .desc = "literal text to find" },
            .{ .name = "dir", .desc = "directory inside the repo; defaults to the repo root", .optional = true },
        },
    },
};

const max_read_bytes = 16 * 1024;
const max_read_source_bytes = 64 * 1024 * 1024;
const max_list_entries = 2000;
const max_search_matches = 200;
const max_search_file_bytes = 1024 * 1024;
const max_match_text = 200;
const binary_probe_bytes = 8000;

pub const Policy = struct {
    test_command: ?[]const u8 = null,
    allow_repo_config: bool = false,
};

pub fn parsePolicy(args: anytype) ?Policy {
    var policy: Policy = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.eql(u8, arg, "--allow-repo-config")) {
            if (policy.allow_repo_config) return null;
            policy.allow_repo_config = true;
        } else if (std.mem.eql(u8, arg, "--test")) {
            if (policy.test_command != null or i + 1 >= args.len) return null;
            i += 1;
            const command: []const u8 = args[i];
            if (command.len == 0) return null;
            policy.test_command = command;
        } else return null;
    }
    return policy;
}

fn trustedTestCommand(args: ?Value, policy: Policy) error{ModelSuppliedTestPolicy}![]const u8 {
    if (args) |a| {
        if (getField(a, "test_cmd") != null or getField(a, "allow_repo_config") != null) return error.ModelSuppliedTestPolicy;
    }
    return policy.test_command orelse "";
}

pub fn serve(gpa: Allocator, io: std.Io, runtime: *Runtime, out: *Writer, policy: Policy) !void {
    const root: ?[]u8 = runner.repoRoot(gpa, io) catch null;
    defer if (root) |r| gpa.free(r);
    const workspace: ?[]u8 = if (root) |r| std.fmt.allocPrint(gpa, "{s}\\{s}", .{ r, shadow.workspace_dir }) catch null else null;
    defer if (workspace) |ws| gpa.free(ws);
    var observer: ?telemetry.Observer = if (workspace) |ws| .{ .workspace_abs = ws } else null;
    const observer_ptr: ?*telemetry.Observer = if (observer) |*o| o else null;

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

        if (try handleMessageObserved(gpa, io, runtime, trimmed, out, observer_ptr, policy)) {
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

const ToolResult = struct { text: []u8, is_error: bool };

fn handleToolsCall(gpa: Allocator, io: std.Io, runtime: *Runtime, out: *Writer, id: Value, msg: Value, observer: ?*telemetry.Observer, policy: Policy) !void {
    const params = getField(msg, "params") orelse return writeRpcError(out, id, -32602, "Missing params");
    const name = getString(params, "name") orelse return writeRpcError(out, id, -32602, "Missing tool name");
    const arguments = getField(params, "arguments");

    var event: telemetry.Event = .{ .tool = name };
    const result = callTool(gpa, io, runtime, name, arguments, &event, policy) catch |err| {
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

fn callTool(gpa: Allocator, io: std.Io, runtime: *Runtime, name: []const u8, args: ?Value, event: *telemetry.Event, policy: Policy) !ToolResult {
    if (std.mem.eql(u8, name, "synapse_symbols")) return callSymbols(gpa, io, runtime, args, event);
    if (std.mem.eql(u8, name, "synapse_skeleton")) return callSkeleton(gpa, io, runtime, args, event);
    if (std.mem.eql(u8, name, "synapse_read_symbol")) return callReadSymbol(gpa, io, runtime, args, event);
    if (std.mem.eql(u8, name, "synapse_mutate")) return callMutate(gpa, io, runtime, args, event);
    if (std.mem.eql(u8, name, "synapse_try")) return callTry(gpa, io, runtime, args, event, policy);
    if (std.mem.eql(u8, name, "synapse_try_batch")) return callTryBatch(gpa, io, runtime, args, event, policy);
    if (std.mem.eql(u8, name, "synapse_read_file")) return callReadFile(gpa, io, args, event);
    if (std.mem.eql(u8, name, "synapse_list")) return callList(gpa, io, args, event);
    if (std.mem.eql(u8, name, "synapse_search")) return callSearch(gpa, io, args, event);
    return error.UnknownTool;
}

fn callSymbols(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event) !ToolResult {
    const file = try requireString(args, "file");
    event.label = "symbols";
    event.file = file;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    renderSymbols(gpa, io, runtime, file, &buffer.writer) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err, event);
    };
    return success(gpa, &buffer);
}

fn loadJailed(gpa: Allocator, io: std.Io, runtime: *Runtime, file: []const u8) !*Snapshot {
    const file_abs = try std.Io.Dir.cwd().realPathFileAlloc(io, file, gpa);
    defer gpa.free(file_abs);
    try runner.assertUnderCwdRepo(gpa, io, file_abs);
    if (!std.ascii.endsWithIgnoreCase(file_abs, ".ts")) return error.NotTypeScript;
    return Snapshot.load(runtime, io, .cwd(), file_abs);
}

const Jailed = struct {
    abs: [:0]u8,
    rel: []u8,

    fn deinit(self: Jailed, gpa: Allocator) void {
        gpa.free(self.abs);
        gpa.free(self.rel);
    }
};

fn jailPath(gpa: Allocator, io: std.Io, path: []const u8) !Jailed {
    const abs = try std.Io.Dir.cwd().realPathFileAlloc(io, path, gpa);
    errdefer gpa.free(abs);
    const rel = try runner.repoRelative(gpa, io, abs);
    errdefer gpa.free(rel);
    try refuseInternal(rel);
    return .{ .abs = abs, .rel = rel };
}

fn refuseInternal(rel: []const u8) error{InternalPath}!void {
    var segments = std.mem.tokenizeAny(u8, rel, "/\\");
    const first = segments.next() orelse return;
    if (std.ascii.eqlIgnoreCase(first, ".git") or std.ascii.eqlIgnoreCase(first, shadow.workspace_dir)) return error.InternalPath;
}

fn utf8Prefix(bytes: []const u8, limit: usize) []const u8 {
    if (bytes.len <= limit) return bytes;
    var end = limit;
    while (end > 0 and (bytes[end] & 0xC0) == 0x80) end -= 1;
    return bytes[0..end];
}

fn looksBinary(bytes: []const u8) bool {
    return std.mem.indexOfScalar(u8, bytes[0..@min(bytes.len, binary_probe_bytes)], 0) != null;
}

fn inDirectory(path: []const u8, prefix: []const u8) bool {
    if (prefix.len == 0) return true;
    if (path.len <= prefix.len) return false;
    for (prefix, path[0..prefix.len]) |a, b| {
        const na: u8 = if (a == '/') '\\' else std.ascii.toLower(a);
        const nb: u8 = if (b == '/') '\\' else std.ascii.toLower(b);
        if (na != nb) return false;
    }
    return path[prefix.len] == '/' or path[prefix.len] == '\\';
}

fn callReadFile(gpa: Allocator, io: std.Io, args: ?Value, event: *telemetry.Event) !ToolResult {
    const file = try requireString(args, "file");
    event.label = "read_file";
    event.file = file;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    renderReadFile(gpa, io, file, &buffer.writer, event) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err, event);
    };
    return success(gpa, &buffer);
}

fn renderReadFile(gpa: Allocator, io: std.Io, file: []const u8, w: *Writer, event: *telemetry.Event) !void {
    const place = try jailPath(gpa, io, file);
    defer place.deinit(gpa);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, place.abs, gpa, .limited(max_read_source_bytes));
    defer gpa.free(bytes);
    if (looksBinary(bytes)) return error.BinaryFile;
    const shown = utf8Prefix(bytes, max_read_bytes);
    if (!std.unicode.utf8ValidateSlice(shown)) return error.NotUtf8;
    event.chars_synapse = shown.len;
    event.chars_fullfile = bytes.len;
    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("file");
    try js.write(file);
    try js.objectField("bytes");
    try js.write(bytes.len);
    try js.objectField("truncated");
    try js.write(shown.len < bytes.len);
    try js.objectField("content");
    try js.write(shown);
    try js.endObject();
    try w.writeByte('\n');
}

fn callList(gpa: Allocator, io: std.Io, args: ?Value, event: *telemetry.Event) !ToolResult {
    const dir = if (args) |a| getString(a, "dir") orelse "." else ".";
    event.label = "list";
    event.file = dir;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    renderList(gpa, io, dir, &buffer.writer) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err, event);
    };
    return success(gpa, &buffer);
}

fn renderList(gpa: Allocator, io: std.Io, dir: []const u8, w: *Writer) !void {
    const place = try jailPath(gpa, io, dir);
    defer place.deinit(gpa);
    const root = try runner.repoRoot(gpa, io);
    defer gpa.free(root);
    const files = try shadow.trackedFiles(gpa, io, root);
    defer gpa.free(files);
    defer shadow.freeFileList(gpa, files);

    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("dir");
    try js.write(dir);
    try js.objectField("files");
    try js.beginArray();
    var count: usize = 0;
    var truncated = false;
    for (files) |f| {
        if (!inDirectory(f, place.rel)) continue;
        if (count == max_list_entries) {
            truncated = true;
            break;
        }
        try js.write(f);
        count += 1;
    }
    try js.endArray();
    try js.objectField("truncated");
    try js.write(truncated);
    try js.endObject();
    try w.writeByte('\n');
}

fn callSearch(gpa: Allocator, io: std.Io, args: ?Value, event: *telemetry.Event) !ToolResult {
    const pattern = try requireString(args, "pattern");
    const dir = if (args) |a| getString(a, "dir") orelse "." else ".";
    event.label = "search";
    event.file = dir;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    renderSearch(gpa, io, pattern, dir, &buffer.writer) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err, event);
    };
    return success(gpa, &buffer);
}

const SearchLimits = struct {
    file_bytes: usize = max_search_file_bytes,
    matches: usize = max_search_matches,
};

fn renderSearch(gpa: Allocator, io: std.Io, pattern: []const u8, dir: []const u8, w: *Writer) !void {
    if (pattern.len == 0) return error.EmptyPattern;
    const place = try jailPath(gpa, io, dir);
    defer place.deinit(gpa);
    const root = try runner.repoRoot(gpa, io);
    defer gpa.free(root);
    try searchIn(gpa, io, root, place.rel, pattern, .{}, w);
}

fn searchIn(gpa: Allocator, io: std.Io, root: []const u8, prefix: []const u8, pattern: []const u8, limits: SearchLimits, w: *Writer) !void {
    const files = try shadow.trackedFiles(gpa, io, root);
    defer gpa.free(files);
    defer shadow.freeFileList(gpa, files);

    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("pattern");
    try js.write(pattern);
    try js.objectField("matches");
    try js.beginArray();
    var count: usize = 0;
    var truncated = false;
    outer: for (files) |f| {
        if (!inDirectory(f, prefix)) continue;
        const joined = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ root, f });
        defer gpa.free(joined);
        const real = std.Io.Dir.cwd().realPathFileAlloc(io, joined, gpa) catch continue;
        defer gpa.free(real);
        const rel = runner.relativeUnder(gpa, root, real) catch continue;
        defer gpa.free(rel);
        refuseInternal(rel) catch continue;
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, real, gpa, .limited(limits.file_bytes)) catch continue;
        defer gpa.free(bytes);
        if (looksBinary(bytes)) continue;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        var number: usize = 0;
        while (lines.next()) |raw| {
            number += 1;
            if (std.mem.indexOf(u8, raw, pattern) == null) continue;
            const text = utf8Prefix(std.mem.trim(u8, raw, " \t\r"), max_match_text);
            if (!std.unicode.utf8ValidateSlice(text)) continue;
            if (count == limits.matches) {
                truncated = true;
                break :outer;
            }
            try js.beginObject();
            try js.objectField("file");
            try js.write(f);
            try js.objectField("line");
            try js.write(number);
            try js.objectField("text");
            try js.write(text);
            try js.endObject();
            count += 1;
        }
    }
    try js.endArray();
    try js.objectField("truncated");
    try js.write(truncated);
    try js.endObject();
    try w.writeByte('\n');
}

fn renderSymbols(gpa: Allocator, io: std.Io, runtime: *Runtime, file: []const u8, w: *Writer) !void {
    const snapshot = try loadJailed(gpa, io, runtime, file);
    defer snapshot.destroy();
    const table = try snapshot.symbols();
    try wire.writeSymbols(gpa, w, file, table.*);
}

fn callSkeleton(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event) !ToolResult {
    const file = try requireString(args, "file");
    event.label = "skeleton";
    event.file = file;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    renderSkeleton(gpa, io, runtime, file, &buffer.writer, event) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err, event);
    };
    return success(gpa, &buffer);
}

fn renderSkeleton(gpa: Allocator, io: std.Io, runtime: *Runtime, file: []const u8, w: *Writer, event: *telemetry.Event) !void {
    const snapshot = try loadJailed(gpa, io, runtime, file);
    defer snapshot.destroy();
    const text = try skeleton.skeletonize(gpa, runtime.parser, snapshot.tree);
    defer gpa.free(text);
    event.chars_synapse = text.len;
    event.chars_fullfile = snapshot.source.len;
    try wire.writeSkeleton(w, file, text);
}

fn callReadSymbol(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event) !ToolResult {
    const file = try requireString(args, "file");
    const sym = try requireString(args, "symbol");
    event.label = "read_symbol";
    event.file = file;
    event.symbol = sym;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    renderSymbolBody(gpa, io, runtime, file, sym, &buffer.writer, event) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err, event);
    };
    return success(gpa, &buffer);
}

fn renderSymbolBody(gpa: Allocator, io: std.Io, runtime: *Runtime, file: []const u8, sym: []const u8, w: *Writer, event: *telemetry.Event) !void {
    const snapshot = try loadJailed(gpa, io, runtime, file);
    defer snapshot.destroy();
    const table = try snapshot.symbols();
    const ref = try symbol.Ref.parse(gpa, sym);
    defer ref.deinit(gpa);
    const found = try table.resolve(ref);
    const body = snapshot.tree.text(found.body);
    event.hash = found.hash;
    event.chars_synapse = body.len;
    event.chars_fullfile = snapshot.source.len;
    try wire.writeSymbolBody(w, file, sym, found.hash, body);
}

fn callMutate(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event) !ToolResult {
    const file = try requireString(args, "file");
    const sym = try requireString(args, "symbol");
    const hash_hex = try requireString(args, "hash");
    const body = try requireString(args, "body");
    event.label = "dry-run";
    event.file = file;
    event.symbol = sym;
    event.mutating = true;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    renderMutate(gpa, io, runtime, file, sym, hash_hex, body, &buffer.writer, event) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err, event);
    };
    return success(gpa, &buffer);
}

fn renderMutate(gpa: Allocator, io: std.Io, runtime: *Runtime, file: []const u8, sym: []const u8, hash_hex: []const u8, body: []const u8, w: *Writer, event: *telemetry.Event) !void {
    const ref = try symbol.Ref.parse(gpa, sym);
    defer ref.deinit(gpa);
    const expected = try symbol.parseHash(hash_hex);
    const base = try loadJailed(gpa, io, runtime, file);
    defer base.destroy();
    if (base.tree.root().hasError()) return error.SourceHasErrors;
    const target = try (try base.symbols()).resolve(ref);
    const old_body_len = target.body.endByte() - target.body.startByte();
    const applied = try cas.apply(base, .{ .ref = ref, .expected_hash = expected, .new_body = body });
    defer applied.snapshot.destroy();
    event.hash = applied.hash;
    event.chars_synapse = sym.len + hash_hex.len + body.len;
    event.chars_fullfile = applied.snapshot.source.len;
    event.chars_sr = old_body_len + body.len;
    try wire.writeMutated(w, sym, expected, applied.hash, applied.snapshot.source);
}

fn callTry(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, policy: Policy) !ToolResult {
    const file = try requireString(args, "file");
    const sym = try requireString(args, "symbol");
    const hash_hex = try requireString(args, "hash");
    const body = try requireString(args, "body");
    event.file = file;
    event.symbol = sym;
    event.mutating = true;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    const is_error = tryInto(gpa, io, runtime, file, sym, hash_hex, body, args, policy, &buffer.writer, event) catch |err| blk: {
        if (err == error.OutOfMemory) return err;
        event.fail(@errorName(err));
        buffer.clearRetainingCapacity();
        try wire.writeError(&buffer.writer, @errorName(err), wire.exitCode(err));
        break :blk true;
    };
    return .{ .text = try dupTrim(gpa, buffer.written()), .is_error = is_error };
}

fn tryInto(gpa: Allocator, io: std.Io, runtime: *Runtime, file: []const u8, sym: []const u8, hash_hex: []const u8, body: []const u8, args: ?Value, policy: Policy, w: *Writer, event: *telemetry.Event) !bool {
    const given = try trustedTestCommand(args, policy);
    const file_abs = try std.Io.Dir.cwd().realPathFileAlloc(io, file, gpa);
    defer gpa.free(file_abs);
    const test_command = try runner.resolveTestCommand(gpa, io, file_abs, given, policy.allow_repo_config);
    defer gpa.free(test_command);
    const expected = try symbol.parseHash(hash_hex);
    const result = try runner.tryMutate(gpa, io, runtime, .{
        .file_abs = file_abs,
        .ref_text = sym,
        .expected_hash = expected,
        .new_body = body,
        .test_command = test_command,
        .trace = &event.trace,
    });
    defer result.deinit(gpa);
    event.chars_synapse = sym.len + hash_hex.len + body.len;
    event.chars_fullfile = event.trace.new_len;
    event.chars_sr = if (event.trace.old_body_len) |old| old + body.len else null;
    switch (result) {
        .committed => |new_hash| {
            event.outcome = .committed;
            event.edits = 1;
            event.hash = new_hash;
            try wire.writeCommitted(w, sym, expected, new_hash);
            return false;
        },
        .rejected => |report| {
            event.outcome = .rejected;
            event.reason = wire.rejectionReason(report);
            try wire.writeRejected(gpa, w, test_command, report);
            return true;
        },
    }
}

fn callTryBatch(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, policy: Policy) !ToolResult {
    const arguments = args orelse return error.MissingArgument;
    const edits_val = getField(arguments, "edits") orelse return error.MissingArgument;
    if (edits_val != .array or edits_val.array.items.len == 0) return error.MissingArgument;
    for (edits_val.array.items) |item| {
        _ = getString(item, "file") orelse return error.MissingArgument;
        _ = getString(item, "symbol") orelse return error.MissingArgument;
        _ = getString(item, "hash") orelse return error.MissingArgument;
        _ = getString(item, "body") orelse return error.MissingArgument;
    }
    event.mutating = true;

    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    const is_error = batchInto(gpa, io, runtime, edits_val.array.items, arguments, policy, &buffer.writer, event) catch |err| blk: {
        if (err == error.OutOfMemory) return err;
        event.fail(@errorName(err));
        buffer.clearRetainingCapacity();
        try wire.writeError(&buffer.writer, @errorName(err), wire.exitCode(err));
        break :blk true;
    };
    return .{ .text = try dupTrim(gpa, buffer.written()), .is_error = is_error };
}

fn batchInto(gpa: Allocator, io: std.Io, runtime: *Runtime, items: []const Value, args: Value, policy: Policy, w: *Writer, event: *telemetry.Event) !bool {
    const given = try trustedTestCommand(args, policy);
    const edits = try gpa.alloc(runner.Edit, items.len);
    defer gpa.free(edits);
    var built: usize = 0;
    defer {
        var i = built;
        while (i > 0) {
            i -= 1;
            const owned: [:0]const u8 = edits[i].file_abs.ptr[0..edits[i].file_abs.len :0];
            gpa.free(owned);
        }
    }
    for (items, 0..) |item, i| {
        const file_abs = try std.Io.Dir.cwd().realPathFileAlloc(io, getString(item, "file").?, gpa);
        edits[i].file_abs = file_abs;
        built = i + 1;
        edits[i].ref_text = getString(item, "symbol").?;
        edits[i].new_body = getString(item, "body").?;
        edits[i].expected_hash = try symbol.parseHash(getString(item, "hash").?);
    }

    const resolved = try runner.resolveTestCommand(gpa, io, edits[0].file_abs, given, policy.allow_repo_config);
    defer gpa.free(resolved);
    const result = try runner.tryMutateBatch(gpa, io, runtime, .{ .edits = edits, .test_command = resolved, .trace = &event.trace });
    defer result.deinit(gpa);

    var sent: usize = 0;
    for (items) |item| sent += getString(item, "symbol").?.len + getString(item, "hash").?.len + getString(item, "body").?.len;
    event.chars_synapse = sent;
    event.chars_fullfile = event.trace.new_len;
    switch (result) {
        .committed => |hashes| {
            event.outcome = .committed;
            event.edits = items.len;
            const views = try gpa.alloc(wire.BatchEdit, items.len);
            defer gpa.free(views);
            for (items, 0..) |item, i| views[i] = .{
                .file = getString(item, "file").?,
                .symbol = getString(item, "symbol").?,
                .old_hash = edits[i].expected_hash,
                .new_hash = hashes[i],
            };
            try wire.writeBatchCommitted(w, views);
            return false;
        },
        .rejected => |report| {
            event.outcome = .rejected;
            event.reason = wire.rejectionReason(report);
            try wire.writeRejected(gpa, w, resolved, report);
            return true;
        },
    }
}

fn success(gpa: Allocator, buffer: *std.Io.Writer.Allocating) !ToolResult {
    return .{ .text = try dupTrim(gpa, buffer.written()), .is_error = false };
}

fn failure(gpa: Allocator, buffer: *std.Io.Writer.Allocating, err: anyerror, event: *telemetry.Event) !ToolResult {
    event.fail(@errorName(err));
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
    try js.write("synapse_try_batch");
    try js.objectField("description");
    try js.write("All-or-nothing cross-file mutation: apply several symbol edits across files, run the project's trusted test command once over all of them, and commit every file only if it passes; otherwise nothing is written. One edit per file. The test command is fixed by the user who started synapse; a call that passes test_cmd or allow_repo_config is refused.");
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

test "serve policy comes only from the command line synapse was started with" {
    const empty = parsePolicy(&[_][]const u8{}).?;
    try testing.expect(empty.test_command == null);
    try testing.expect(!empty.allow_repo_config);

    const full = parsePolicy(&[_][]const u8{ "--test", "npm test", "--allow-repo-config" }).?;
    try testing.expectEqualStrings("npm test", full.test_command.?);
    try testing.expect(full.allow_repo_config);

    try testing.expect(parsePolicy(&[_][]const u8{"--test"}) == null);
    try testing.expect(parsePolicy(&[_][]const u8{ "--test", "" }) == null);
    try testing.expect(parsePolicy(&[_][]const u8{ "--test", "a", "--test", "b" }) == null);
    try testing.expect(parsePolicy(&[_][]const u8{ "--allow-repo-config", "--allow-repo-config" }) == null);
    try testing.expect(parsePolicy(&[_][]const u8{"--bogus"}) == null);
}

test "a read is cut on a UTF-8 boundary, never inside a character" {
    try testing.expectEqualStrings("a", utf8Prefix("aé", 2));
    try testing.expectEqualStrings("aé", utf8Prefix("aé", 3));
    try testing.expectEqualStrings("ab", utf8Prefix("ab", 16));
}

test "directory filtering matches whole path segments across separators and case" {
    try testing.expect(inDirectory("tests/fixtures/a.ts", ""));
    try testing.expect(inDirectory("tests/fixtures/a.ts", "tests\\fixtures"));
    try testing.expect(inDirectory("Tests/Fixtures/a.ts", "tests\\fixtures"));
    try testing.expect(!inDirectory("tests/fixtures2/a.ts", "tests\\fixtures"));
    try testing.expect(!inDirectory("tests", "tests"));
    try testing.expect(!inDirectory("src/a.ts", "tests"));
}

fn gitIn(root: []const u8, args: []const []const u8) !void {
    var argv: [8][]const u8 = undefined;
    argv[0] = "git";
    @memcpy(argv[1..][0..args.len], args);
    const result = try std.process.run(testing.allocator, testing.io, .{ .argv = argv[0 .. args.len + 1], .cwd = .{ .path = root } });
    testing.allocator.free(result.stdout);
    testing.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitSetupFailed,
        else => return error.GitSetupFailed,
    }
}

fn searchedFiles(root: []const u8, limits: SearchLimits) !std.json.Parsed(Value) {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try searchIn(testing.allocator, testing.io, root, "", "needle", limits, &out.writer);
    return std.json.parseFromSlice(Value, testing.allocator, out.written(), .{ .allocate = .alloc_always });
}

fn matchedFile(parsed: Value, name: []const u8) bool {
    for (parsed.object.get("matches").?.array.items) |m| {
        if (std.mem.eql(u8, m.object.get("file").?.string, name)) return true;
    }
    return false;
}

test "search skips tracked files over its size cap and tracked binary files" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "small.txt", .data = "needle here\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "large.txt", .data = "needle " ++ ("x" ** 200) ++ "\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "blob.bin", .data = "needle\x00binary\n" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try gitIn(root, &.{ "init", "-q" });
    try gitIn(root, &.{ "config", "user.email", "t@t" });
    try gitIn(root, &.{ "config", "user.name", "t" });
    try gitIn(root, &.{ "add", "." });
    try gitIn(root, &.{ "commit", "-q", "-m", "init" });

    var capped = try searchedFiles(root, .{ .file_bytes = 64 });
    defer capped.deinit();
    try testing.expect(matchedFile(capped.value, "small.txt"));
    try testing.expect(!matchedFile(capped.value, "large.txt"));
    try testing.expect(!matchedFile(capped.value, "blob.bin"));

    var defaults = try searchedFiles(root, .{});
    defer defaults.deinit();
    try testing.expect(matchedFile(defaults.value, "small.txt"));
    try testing.expect(matchedFile(defaults.value, "large.txt"));
    try testing.expect(!matchedFile(defaults.value, "blob.bin"));
}

test "internal workspace and git paths are refused, others pass" {
    try testing.expectError(error.InternalPath, refuseInternal(".git\\HEAD"));
    try testing.expectError(error.InternalPath, refuseInternal(".GIT/config"));
    try testing.expectError(error.InternalPath, refuseInternal(".synapse\\events.ndjson"));
    try refuseInternal("");
    try refuseInternal("docs\\.git-notes.md");
    try refuseInternal("src\\main.zig");
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
