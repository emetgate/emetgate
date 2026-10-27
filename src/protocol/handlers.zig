const std = @import("std");
const commit_plan = @import("../platform/commit_plan.zig");
const commit_group = @import("../platform/commit_group.zig");
const commit_refusal = @import("../platform/commit_refusal.zig");
const symbol = @import("../engine/symbol.zig");
const cas = @import("../engine/cas.zig");
const skeleton = @import("../engine/skeleton.zig");
const doc_fold = @import("../engine/doc_fold.zig");
const line_range = @import("../engine/line_range.zig");
const mirror_mod = @import("mirror.zig");
const tree_cache_mod = @import("../engine/tree_cache.zig");
const wire = @import("wire.zig");
const telemetry = @import("telemetry.zig");
const policy_mod = @import("policy.zig");
const read_tools = @import("read_tools.zig");
const read_budget = @import("read_budget.zig");
const read_cache = @import("read_cache.zig");
const raw_reply = @import("raw_reply.zig");
const outline = @import("outline.zig");
const search_v1 = @import("search_v1.zig");
const find_tools = @import("find_tools.zig");
const git_tools = @import("git_tools.zig");
const rename_tool = @import("rename_tool.zig");
const move_tool = @import("move_tool.zig");
const node_tool = @import("node_tool.zig");
const node_cas_mod = @import("../engine/node_cas.zig");
const batch_mod = @import("../platform/batch.zig");
const move_file_tool = @import("move_file_tool.zig");
const edit_tool = @import("edit_tool.zig");
const run_tool = @import("run_tool.zig");
const receipt_note = @import("receipt_note.zig");
const receipts = @import("../platform/receipts.zig");
const disk = @import("../platform/disk.zig");
const scan_command = @import("scan_command.zig");
const tool_result = @import("tool_result.zig");
const recovery = @import("recovery.zig");
const runner = @import("../platform/runner.zig");
const test_command_mod = @import("../platform/test_command.zig");
const shadow_root = @import("../platform/shadow_root.zig");
const repo = @import("../platform/repo.zig");
const file_edit = @import("../platform/file_edit.zig");
const rules = @import("../platform/rules.zig");
const lang_registry = @import("../engine/lang/registry.zig");
const forgive = @import("forgive.zig");
const batch_plan = @import("../platform/batch_plan.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;
const Snapshot = @import("../engine/loader.zig").Snapshot;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;
const Policy = policy_mod.Policy;
const trustedTestCommand = policy_mod.trustedTestCommand;
const trustedTypecheckCommand = policy_mod.trustedTypecheckCommand;
const ToolResult = tool_result.ToolResult;
const requireString = tool_result.requireString;
const getField = tool_result.getField;
const getString = tool_result.getString;
const getInt = tool_result.getInt;
const getStringArray = tool_result.getStringArray;
const success = tool_result.success;
const failure = tool_result.failure;
const dupTrim = tool_result.dupTrim;

pub const unverified_note = "none: no test command yet, so this write ran no test; add one (package.json scripts.test, a .csproj/.sln/.slnx, Cargo.toml, go.mod, pyproject.toml, pytest.ini, build.zig) or pass --test; then every write must pass it";

pub fn callTool(gpa: Allocator, io: std.Io, runtime: *Runtime, name: []const u8, args: ?Value, event: *telemetry.Event, policy: Policy) !ToolResult {
    wire.clearFix();
    tool_result.clearMissing();
    _ = commit_plan.takeFound();
    _ = commit_refusal.take();
    _ = test_command_mod.takeUnverified();
    var result = try dispatch(gpa, io, runtime, name, args, event, policy);
    if (test_command_mod.takeUnverified()) {
        if (try receipt_note.unverified(gpa, result.text, test_command_mod.unverified_status, unverified_note)) |text| {
            gpa.free(result.text);
            result.text = text;
        }
    }
    if (commit_refusal.take()) |named| {
        errdefer gpa.free(result.text);
        const text = try receipt_note.withPaths(gpa, result.text, named);
        gpa.free(result.text);
        result.text = text;
    }
    const found = commit_plan.takeFound() orelse return result;
    errdefer gpa.free(result.text);
    const text = try receipt_note.withRecovered(gpa, result.text, found);
    gpa.free(result.text);
    result.text = text;
    return result;
}

fn dispatch(gpa: Allocator, io: std.Io, runtime: *Runtime, given_name: []const u8, given_args: ?Value, event: *telemetry.Event, policy: Policy) !ToolResult {
    var forgiven = std.heap.ArenaAllocator.init(gpa);
    defer forgiven.deinit();
    const call = try forgive.normalize(forgiven.allocator(), given_name, given_args);
    const name = call.name;
    const args = call.args;
    if (std.mem.eql(u8, name, "emetgate_symbols")) return callSymbols(gpa, io, runtime, args, event, policy.root, policy.tree_cache);
    if (std.mem.eql(u8, name, "emetgate_skeleton")) return rawCode(gpa, policy, try callSkeleton(gpa, io, runtime, args, event, policy.root, policy.mirror, policy.tree_cache));
    if (std.mem.eql(u8, name, "emetgate_read_symbol")) return rawCode(gpa, policy, try callReadSymbol(gpa, io, runtime, args, event, policy.root, policy.mirror, policy.tree_cache, policy.read_budget));
    if (std.mem.eql(u8, name, "emetgate_mutate")) return callMutate(gpa, io, runtime, args, event, policy.root);
    if (std.mem.eql(u8, name, "emetgate_try")) return callTry(gpa, io, runtime, args, event, policy);
    if (std.mem.eql(u8, name, "emetgate_commit")) return callCommit(gpa, io, runtime, args, event, policy);
    if (std.mem.eql(u8, name, "emetgate_try_batch")) return callTryBatch(gpa, io, runtime, args, event, policy);
    if (std.mem.eql(u8, name, "emetgate_rename")) return rename_tool.callRename(gpa, io, runtime, args, event, policy);
    if (std.mem.eql(u8, name, "emetgate_move")) return move_tool.callMove(gpa, io, runtime, args, event, policy);
    if (std.mem.eql(u8, name, "emetgate_move_file")) return move_file_tool.callMoveFile(gpa, io, runtime, args, event, policy);
    if (std.mem.eql(u8, name, "emetgate_write_doc")) return callWriteDoc(gpa, io, args, event, policy);
    if (std.mem.eql(u8, name, "emetgate_edit")) return edit_tool.callEdit(gpa, io, runtime, args, event, policy);
    if (std.mem.eql(u8, name, "emetgate_write")) return edit_tool.callWrite(gpa, io, runtime, args, event, policy);
    if (std.mem.eql(u8, name, "emetgate_read_file")) return rawCode(gpa, policy, try read_tools.callReadFile(gpa, io, args, event, policy.root, policy.mirror, .{ .runtime = runtime, .tree_cache = policy.tree_cache }));
    if (std.mem.eql(u8, name, "emetgate_list")) return read_tools.callList(gpa, io, args, event, policy.root);
    if (std.mem.eql(u8, name, "emetgate_search")) return search_v1.callSearchAs(gpa, io, runtime, args, event, policy.root, policy.tree_cache, policy.search_session, .{ .format = if (policy.search_text) .text else .json, .internals = policy.search_internals });
    if (std.mem.eql(u8, name, "emetgate_find")) return find_tools.callFind(gpa, args, event, policy.find_session);
    if (std.mem.eql(u8, name, "emetgate_scan")) return callScan(gpa, io, runtime, args, event, policy.root, policy.tree_cache);
    if (std.mem.eql(u8, name, "emetgate_git")) return git_tools.callGit(gpa, io, runtime, args, event, policy.root, policy.read_budget);
    if (std.mem.eql(u8, name, "emetgate_run")) return run_tool.callRun(gpa, io, args, event, policy);
    return error.UnknownTool;
}

pub const max_scan_violations = 100;

pub const max_scan_operations: u64 = 100_000_000;

fn rawCode(gpa: Allocator, policy: Policy, result: ToolResult) !ToolResult {
    if (!policy.raw_code or result.is_error) return result;
    errdefer gpa.free(result.text);
    const raw = try raw_reply.convert(gpa, result.text) orelse return result;
    gpa.free(result.text);
    return .{ .text = raw, .is_error = false };
}

fn callScan(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, root: ?[]const u8, tree_cache: ?*tree_cache_mod.TreeCache) !ToolResult {
    const check = try requireString(args, "check");
    const where: ?[]const u8 = if (getField(args.?, "where")) |field| switch (field) {
        .string => |text| text,
        else => return tool_result.missing("where (string)", .{}),
    } else null;
    event.label = "scan";
    event.file = where;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    var refusal: ?[]const u8 = null;
    renderScan(gpa, io, runtime, root, check, where, tree_cache, &buffer.writer, &refusal) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err, event);
    };
    if (refusal) |name| {
        event.fail(name);
        return .{ .text = try dupTrim(gpa, buffer.written()), .is_error = true };
    }
    return success(gpa, &buffer);
}

fn renderScan(gpa: Allocator, io: std.Io, runtime: *Runtime, root: ?[]const u8, check: []const u8, where: ?[]const u8, tree_cache: ?*tree_cache_mod.TreeCache, w: *Writer, refusal: *?[]const u8) !void {
    const root_abs = try repo.servedRoot(gpa, io, root);
    defer gpa.free(root_abs);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    _ = try scan_command.run(gpa, io, runtime, root_abs, .{
        .source = .{ .check = .{ .spec = check, .where = where } },
        .json = true,
        .max_violations = max_scan_violations,
        .call_operations = max_scan_operations,
        .refusal = refusal,
        .tree_cache = tree_cache,
    }, w, &discard.writer);
}

fn callSymbols(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, root: ?[]const u8, tree_cache: ?*tree_cache_mod.TreeCache) !ToolResult {
    const file = try requireString(args, "file");
    event.label = "symbols";
    event.file = file;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    renderSymbols(gpa, io, runtime, root, file, tree_cache, tool_result.wantsFull(args), &buffer.writer) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err, event);
    };
    return success(gpa, &buffer);
}

const Loaded = struct {
    place: repo.Jailed,
    snapshot: *Snapshot,
    owned: bool,

    fn deinit(self: Loaded, gpa: Allocator) void {
        if (self.owned) self.snapshot.destroy();
        self.place.deinit(gpa);
    }
};

fn loadJailed(gpa: Allocator, io: std.Io, runtime: *Runtime, root: ?[]const u8, file: []const u8, tree_cache: ?*tree_cache_mod.TreeCache) !Loaded {
    const place = try repo.jail(gpa, io, root, file);
    errdefer place.deinit(gpa);
    if (tree_cache) |cache| return .{ .place = place, .snapshot = try cache.load(runtime, io, place.abs), .owned = false };
    return .{ .place = place, .snapshot = try Snapshot.load(runtime, io, .cwd(), place.abs), .owned = true };
}

fn renderSymbols(gpa: Allocator, io: std.Io, runtime: *Runtime, root: ?[]const u8, file: []const u8, tree_cache: ?*tree_cache_mod.TreeCache, full: bool, w: *Writer) !void {
    const loaded = try loadJailed(gpa, io, runtime, root, file, tree_cache);
    defer loaded.deinit(gpa);
    const table = try loaded.snapshot.symbols();
    if (!full and table.symbols.len + table.declarations.len > wire.compact_symbols_over) return wire.writeSymbolsCompact(gpa, w, file, table.*);
    try wire.writeSymbols(gpa, w, file, table.*);
}

fn callSkeleton(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, root: ?[]const u8, mirror: ?*mirror_mod.Mirror, tree_cache: ?*tree_cache_mod.TreeCache) !ToolResult {
    const file = try requireString(args, "file");
    const force = if (args) |a| tool_result.getBool(a, "force") orelse false else false;
    event.label = "skeleton";
    event.file = file;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    renderSkeleton(gpa, io, runtime, root, file, force, mirror, tree_cache, &buffer.writer, event) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err, event);
    };
    return success(gpa, &buffer);
}

fn renderSkeleton(gpa: Allocator, io: std.Io, runtime: *Runtime, root: ?[]const u8, file: []const u8, force: bool, mirror: ?*mirror_mod.Mirror, tree_cache: ?*tree_cache_mod.TreeCache, w: *Writer, event: *telemetry.Event) !void {
    const loaded = try loadJailed(gpa, io, runtime, root, file, tree_cache);
    defer loaded.deinit(gpa);
    const place = loaded.place;
    const snapshot = loaded.snapshot;
    const whole = snapshot.source.len <= outline.threshold;
    const file_hash = symbol.fileHash(snapshot.source);
    if (whole and try read_cache.coversWhole(gpa, mirror, file, file_hash, force)) {
        event.chars_emetgate = 0;
        event.chars_fullfile = snapshot.source.len;
        return read_cache.writeCovered(w, file, null, file_hash);
    }
    const docs: ?doc_fold.Folded = if (whole) try doc_fold.fold(gpa, snapshot.profile, snapshot.tree, 0, @intCast(snapshot.source.len)) else null;
    defer if (docs) |d| d.deinit(gpa);
    const text = if (docs) |d| try gpa.dupe(u8, d.text) else try skeleton.compact(gpa, runtime.parser, snapshot.profile, snapshot.tree);
    defer gpa.free(text);
    const hash = symbol.hashOf(text);
    if (mirror) |m| {
        const key = try std.fmt.allocPrint(gpa, "skeleton:{s}", .{file});
        defer gpa.free(key);
        if (try m.check(key, hash, force) == .unchanged) {
            event.chars_emetgate = 0;
            event.chars_fullfile = snapshot.source.len;
            return wire.writeUnchanged(w, file, null, hash, file_hash);
        }
    }
    const adopted = try rules.adoptedFor(gpa, io, place.root, place.rel);
    defer adopted.deinit();
    event.chars_emetgate = text.len;
    event.chars_fullfile = snapshot.source.len;
    try wire.writeSkeleton(w, file, file_hash, if (whole) .content else .skeleton, text, adopted.items, if (docs) |d| d.spans else &.{});
    if (whole) try read_cache.recordWhole(gpa, mirror, file, file_hash);
}

fn callReadSymbol(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, root: ?[]const u8, mirror: ?*mirror_mod.Mirror, tree_cache: ?*tree_cache_mod.TreeCache, budget: usize) !ToolResult {
    const file = try requireString(args, "file");
    const force = if (args) |a| tool_result.getBool(a, "force") orelse false else false;
    const nodes = if (args) |a| tool_result.getBool(a, "nodes") orelse false else false;
    event.label = "read_symbol";
    event.file = file;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    const arguments = args.?;
    const detail = read_budget.parseDetail(tool_result.getString(arguments, "detail")) catch |err| return failure(gpa, &buffer, err, event);
    const reading: Reading = .{ .budget = budget, .detail = detail };
    const line_start = getInt(arguments, "line_start");
    const line_end = getInt(arguments, "line_end");
    const symbols = getStringArray(arguments, "symbols");
    if (line_start != null or line_end != null) {
        renderSymbolRange(gpa, io, runtime, root, file, line_start, line_end, force, nodes, reading, mirror, tree_cache, &buffer.writer, event) catch |err| {
            if (err == error.OutOfMemory) return err;
            return failure(gpa, &buffer, err, event);
        };
        return success(gpa, &buffer);
    }
    if (symbols) |list| {
        renderSymbolBodies(gpa, io, runtime, root, file, list, force, nodes, reading, mirror, tree_cache, &buffer.writer, event) catch |err| {
            if (err == error.OutOfMemory) return err;
            return failure(gpa, &buffer, err, event);
        };
        return success(gpa, &buffer);
    }
    const sym = try requireString(args, "symbol");
    event.symbol = sym;
    renderSymbolBody(gpa, io, runtime, root, file, sym, force, nodes, reading, mirror, tree_cache, &buffer.writer, event) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err, event);
    };
    return success(gpa, &buffer);
}

const Reading = struct {
    budget: usize,
    detail: read_budget.Detail,

    fn folds(self: Reading, chars: usize) bool {
        return self.detail == .budgeted and chars > self.budget;
    }

    fn foldDocs(self: Reading, gpa: Allocator, snapshot: *const Snapshot, start: u32, end: u32) !?doc_fold.Folded {
        if (self.detail == .full) return null;
        const docs = try doc_fold.fold(gpa, snapshot.profile, snapshot.tree, start, end);
        if (docs.spans.len != 0) return docs;
        docs.deinit(gpa);
        return null;
    }
};

fn mirrorKey(gpa: Allocator, file: []const u8, sym: []const u8, folded: bool) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}:{s}#{s}", .{ if (folded) "folded" else "symbol", file, sym });
}

fn signatureOf(snapshot: *const Snapshot, found: *const symbol.Symbol) []const u8 {
    const start = found.declaration.start;
    const body_start = found.body.startByte();
    if (body_start <= start) return "";
    return std.mem.trim(u8, snapshot.source[start..body_start], " \t\r\n");
}

fn firstLineOf(text: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    return std.mem.trim(u8, text[0..end], " \t\r\n");
}

fn renderSymbolBody(gpa: Allocator, io: std.Io, runtime: *Runtime, root: ?[]const u8, file: []const u8, sym: []const u8, force: bool, nodes: bool, reading: Reading, mirror: ?*mirror_mod.Mirror, tree_cache: ?*tree_cache_mod.TreeCache, w: *Writer, event: *telemetry.Event) !void {
    const loaded = try loadJailed(gpa, io, runtime, root, file, tree_cache);
    defer loaded.deinit(gpa);
    const snapshot = loaded.snapshot;
    const table = try snapshot.symbols();
    const ref = try symbol.Ref.parse(gpa, sym);
    defer ref.deinit(gpa);
    const found = try table.resolve(ref);
    event.hash = found.hash;
    const docs = if (nodes) null else try reading.foldDocs(gpa, snapshot, found.body.startByte(), found.body.endByte());
    defer if (docs) |d| d.deinit(gpa);
    const body = if (docs) |d| d.text else snapshot.tree.text(found.body);
    const folds = !nodes and reading.folds(body.len);
    if (!nodes and try read_cache.coversWhole(gpa, mirror, file, symbol.fileHash(snapshot.source), force)) {
        event.chars_emetgate = 0;
        event.chars_fullfile = snapshot.source.len;
        return read_cache.writeCovered(w, file, sym, symbol.fileHash(snapshot.source));
    }
    if (!nodes) if (mirror) |m| {
        const key = try mirrorKey(gpa, file, sym, folds or docs != null);
        defer gpa.free(key);
        if (try m.check(key, found.hash, force) == .unchanged) {
            event.chars_emetgate = 0;
            event.chars_fullfile = snapshot.source.len;
            return wire.writeUnchanged(w, file, sym, found.hash, null);
        }
    };
    event.chars_fullfile = snapshot.source.len;
    if (nodes) {
        const annotated = try node_cas_mod.annotateSnapshot(gpa, snapshot, found.declaration);
        defer gpa.free(annotated);
        event.chars_emetgate = annotated.len;
        return wire.writeSymbolNodes(w, file, sym, found.hash, annotated);
    }
    if (folds) {
        const lines = try read_budget.Lines.init(gpa, snapshot.source);
        defer lines.deinit(gpa);
        const view = try read_budget.fold(gpa, snapshot.source, lines, found.body, reading.budget);
        defer view.deinit(gpa);
        event.chars_emetgate = view.text.len;
        return wire.writeSymbolBodyFolded(w, file, sym, found.hash, .{ .view = view, .signature = signatureOf(snapshot, found), .budget = reading.budget });
    }
    event.chars_emetgate = body.len;
    try wire.writeSymbolBody(w, file, sym, found.hash, body, if (docs) |d| d.spans else &.{});
}

fn renderSymbolBodies(gpa: Allocator, io: std.Io, runtime: *Runtime, root: ?[]const u8, file: []const u8, symbols: []const Value, force: bool, nodes: bool, reading: Reading, mirror: ?*mirror_mod.Mirror, tree_cache: ?*tree_cache_mod.TreeCache, w: *Writer, event: *telemetry.Event) !void {
    if (symbols.len == 0) return tool_result.missing("symbols (non-empty array of symbol refs)", .{});
    const loaded = try loadJailed(gpa, io, runtime, root, file, tree_cache);
    defer loaded.deinit(gpa);
    const snapshot = loaded.snapshot;
    const table = try snapshot.symbols();
    const entries = try gpa.alloc(wire.SymbolEntry, symbols.len);
    defer gpa.free(entries);
    var annotated: usize = 0;
    defer for (entries[0..annotated]) |entry| gpa.free(entry.body.?);
    var views: usize = 0;
    defer for (entries[0..views]) |entry| if (entry.folded) |folded| folded.view.deinit(gpa);
    var lines: ?read_budget.Lines = null;
    defer if (lines) |l| l.deinit(gpa);
    var folded_docs: std.ArrayList(doc_fold.Folded) = .empty;
    defer {
        for (folded_docs.items) |d| d.deinit(gpa);
        folded_docs.deinit(gpa);
    }
    var chars: usize = 0;
    const covered = try read_cache.coversWhole(gpa, mirror, file, symbol.fileHash(snapshot.source), force);
    for (symbols, 0..) |item, i| {
        const sym = switch (item) {
            .string => |s| s,
            else => return tool_result.missing("symbols[{d}] (string)", .{i}),
        };
        const ref = try symbol.Ref.parse(gpa, sym);
        defer ref.deinit(gpa);
        const found = try table.resolve(ref);
        if (nodes) {
            const text = try node_cas_mod.annotateSnapshot(gpa, snapshot, found.declaration);
            entries[i] = .{ .ref = sym, .hash = found.hash, .body = text, .nodes = true };
            annotated = i + 1;
            chars += text.len;
            continue;
        }
        try folded_docs.ensureUnusedCapacity(gpa, 1);
        const docs = try reading.foldDocs(gpa, snapshot, found.body.startByte(), found.body.endByte());
        if (docs) |d| folded_docs.appendAssumeCapacity(d);
        const body = if (docs) |d| d.text else snapshot.tree.text(found.body);
        const folds = reading.folds(body.len);
        var unchanged = covered;
        if (!covered) if (mirror) |m| {
            const key = try mirrorKey(gpa, file, sym, folds or docs != null);
            defer gpa.free(key);
            unchanged = try m.check(key, found.hash, force) == .unchanged;
        };
        entries[i] = .{ .ref = sym, .hash = found.hash, .body = if (unchanged) null else body, .docs = if (docs) |d| d.spans else &.{} };
        views = i + 1;
        if (unchanged) continue;
        if (folds) {
            if (lines == null) lines = try read_budget.Lines.init(gpa, snapshot.source);
            const view = try read_budget.fold(gpa, snapshot.source, lines.?, found.body, reading.budget);
            entries[i].folded = .{ .view = view, .signature = signatureOf(snapshot, found), .budget = reading.budget };
            chars += view.text.len;
            continue;
        }
        chars += body.len;
    }
    event.chars_emetgate = chars;
    event.chars_fullfile = snapshot.source.len;
    try wire.writeSymbolBodies(w, file, entries);
}

fn renderSymbolRange(gpa: Allocator, io: std.Io, runtime: *Runtime, root: ?[]const u8, file: []const u8, line_start: ?i64, line_end: ?i64, force: bool, nodes: bool, reading: Reading, mirror: ?*mirror_mod.Mirror, tree_cache: ?*tree_cache_mod.TreeCache, w: *Writer, event: *telemetry.Event) !void {
    const start = line_start orelse return tool_result.missing("line_start (integer, with line_end)", .{});
    const end = line_end orelse return tool_result.missing("line_end (integer, with line_start)", .{});
    if (start < 1 or end < 1) return error.InvalidLineRange;
    const loaded = try loadJailed(gpa, io, runtime, root, file, tree_cache);
    defer loaded.deinit(gpa);
    const snapshot = loaded.snapshot;
    if (nodes) {
        if (snapshot.tree.root().hasError()) return error.SourceHasErrors;
        const region = try line_range.byteRangeForLines(snapshot.source, @intCast(start), @intCast(end));
        const annotated = try node_cas_mod.annotateSnapshot(gpa, snapshot, region);
        defer gpa.free(annotated);
        event.chars_emetgate = annotated.len;
        event.chars_fullfile = snapshot.source.len;
        return wire.writeRangeNodes(w, file, @intCast(start), @intCast(end), annotated);
    }
    const table = try snapshot.symbols();
    const requested = try line_range.byteRangeForLines(snapshot.source, @intCast(start), @intCast(end));
    const matched = line_range.symbolsOverlapping(gpa, table.*, requested) catch |err| switch (err) {
        error.NoSymbolInRange => return read_tools.renderRange(gpa, file, snapshot.source, start, end, force, mirror, w, event),
        else => |e| return e,
    };
    defer gpa.free(matched);
    const whole_read = try read_cache.coversWhole(gpa, mirror, file, symbol.fileHash(snapshot.source), force);
    const entries = try gpa.alloc(wire.RangeEntry, matched.len);
    defer gpa.free(entries);
    var views: usize = 0;
    defer for (entries[0..views]) |entry| if (entry.folded) |folded| folded.view.deinit(gpa);
    const ref_text = try gpa.alloc([]u8, matched.len);
    var named: usize = 0;
    defer {
        for (ref_text[0..named]) |t| gpa.free(t);
        gpa.free(ref_text);
    }
    var lines: ?read_budget.Lines = null;
    defer if (lines) |l| l.deinit(gpa);
    var folded_docs: std.ArrayList(doc_fold.Folded) = .empty;
    defer {
        for (folded_docs.items) |d| d.deinit(gpa);
        folded_docs.deinit(gpa);
    }
    var chars: usize = 0;
    for (matched, 0..) |found, i| {
        ref_text[i] = try std.fmt.allocPrint(gpa, "{f}", .{found.ref});
        named = i + 1;
        try folded_docs.ensureUnusedCapacity(gpa, 1);
        const docs = try reading.foldDocs(gpa, snapshot, found.declaration.start, found.declaration.end);
        if (docs) |d| folded_docs.appendAssumeCapacity(d);
        const text = if (docs) |d| d.text else snapshot.source[found.declaration.start..found.declaration.end];
        const folds = reading.folds(text.len);
        var unchanged = whole_read;
        if (!whole_read) if (mirror) |m| {
            const key = try mirrorKey(gpa, file, ref_text[i], folds or docs != null);
            defer gpa.free(key);
            unchanged = try m.check(key, found.hash, force) == .unchanged;
        };
        const start_line = std.mem.count(u8, snapshot.source[0..found.declaration.start], "\n") + 1;
        const end_line = std.mem.count(u8, snapshot.source[0..found.declaration.end], "\n") + 1;
        entries[i] = .{ .ref = ref_text[i], .hash = found.hash, .text = if (unchanged) null else text, .start_line = @intCast(start_line), .end_line = @intCast(end_line), .docs = if (docs) |d| d.spans else &.{} };
        views = i + 1;
        if (unchanged) continue;
        if (folds) {
            if (lines == null) lines = try read_budget.Lines.init(gpa, snapshot.source);
            const view = try read_budget.focus(gpa, snapshot.source, lines.?, found.declaration.start, found.declaration.end, @intCast(start), @intCast(end));
            entries[i].folded = .{ .view = view, .signature = firstLineOf(snapshot.source[found.declaration.start..found.declaration.end]), .budget = reading.budget };
            chars += view.text.len;
            continue;
        }
        chars += text.len;
    }
    event.chars_emetgate = chars;
    event.chars_fullfile = snapshot.source.len;
    try wire.writeSymbolRange(w, file, @intCast(start), @intCast(end), entries);
}

fn callMutate(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, root: ?[]const u8) !ToolResult {
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
    renderMutate(gpa, io, runtime, root, file, sym, hash_hex, body, &buffer.writer, event) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err, event);
    };
    return success(gpa, &buffer);
}

fn renderMutate(gpa: Allocator, io: std.Io, runtime: *Runtime, root: ?[]const u8, file: []const u8, sym: []const u8, hash_hex: []const u8, body: []const u8, w: *Writer, event: *telemetry.Event) !void {
    const ref = try symbol.Ref.parse(gpa, sym);
    defer ref.deinit(gpa);
    const expected = try symbol.parseExpected(hash_hex);
    const place = try repo.jailTarget(gpa, io, root, file, expected == .absent);
    defer place.deinit(gpa);
    if (place.creates) {
        const created = try runner.prepareCreate(gpa, io, runtime, place.root, place.abs, place.rel, ref, body);
        defer created.snapshot.destroy();
        event.hash = created.hash;
        event.chars_emetgate = sym.len + hash_hex.len + body.len;
        event.chars_fullfile = created.snapshot.source.len;
        try wire.writeMutated(w, sym, expected, created.hash, created.snapshot.source);
        return;
    }
    const base = try Snapshot.load(runtime, io, .cwd(), place.abs);
    defer base.destroy();
    if (base.tree.root().hasError()) return error.SourceHasErrors;
    if (expected == .present) {
        const target = try (try base.symbols()).resolve(ref);
        event.chars_sr = target.body.endByte() - target.body.startByte() + body.len;
    }
    const applied = try cas.propose(base, ref, expected, body);
    defer applied.snapshot.destroy();
    event.hash = applied.hash;
    event.chars_emetgate = sym.len + hash_hex.len + body.len;
    event.chars_fullfile = applied.snapshot.source.len;
    try wire.writeMutated(w, sym, expected, applied.hash, applied.snapshot.source);
}

fn callTry(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, policy: Policy) !ToolResult {
    if (args) |a| if (node_tool.isNodeForm(a)) return node_tool.callTry(gpa, io, runtime, args, event, policy);
    if (args) |a| if ((itemKind(a) catch .code) != .code) return tryAsBatch(gpa, io, runtime, a, event, policy);
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
        if (err == error.ParentDirectoryMissing) return tryAsBatch(gpa, io, runtime, args.?, event, policy);
        event.fail(@errorName(err));
        recovery.afterSymbolEdit(gpa, io, runtime, policy.root, file, sym, hash_hex, body, err);
        buffer.clearRetainingCapacity();
        if (err == error.WrittenButNotIndexed) {
            try wire.writeNotIndexed(&buffer.writer, file);
        } else {
            try wire.writeFailure(&buffer.writer, err, &event.trace.blocked);
        }
        break :blk true;
    };
    return .{ .text = try dupTrim(gpa, buffer.written()), .is_error = is_error };
}

fn tryAsBatch(gpa: Allocator, io: std.Io, runtime: *Runtime, item: Value, event: *telemetry.Event, policy: Policy) !ToolResult {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    return callTryBatch(gpa, io, runtime, try forgive.asBatch(arena_state.allocator(), item), event, policy);
}

fn tryInto(gpa: Allocator, io: std.Io, runtime: *Runtime, file: []const u8, sym: []const u8, hash_hex: []const u8, body: []const u8, args: ?Value, policy: Policy, w: *Writer, event: *telemetry.Event) !bool {
    const given = try trustedTestCommand(args, policy);
    var commit = try policy_mod.commitRequest(args, policy, runtime);
    defer if (commit) |request| request.deinit(gpa);
    const expected = try symbol.parseExpected(hash_hex);
    const place = try repo.jailTarget(gpa, io, policy.root, file, expected == .absent);
    defer place.deinit(gpa);
    const file_abs = place.abs;
    const test_command = try runner.resolveTestCommand(gpa, io, file_abs, given, policy.allow_repo_config);
    defer gpa.free(test_command);
    const typecheck_command = try runner.resolveTypecheckCommand(gpa, io, file_abs, trustedTypecheckCommand(policy), policy.allow_repo_config);
    defer if (typecheck_command) |command| gpa.free(command);
    const before_hash: ?symbol.Hash = disk.hashFile(gpa, io, file_abs) catch null;
    const result = try runner.tryMutate(gpa, io, runtime, .{
        .file_abs = file_abs,
        .ref_text = sym,
        .expected_hash = expected,
        .new_body = body,
        .test_command = test_command,
        .typecheck_command = typecheck_command,
        .allow_repo_memory = policy.allow_repo_memory,
        .shadow_root = policy.shadow_root,
        .gate_tree = policy.treeChoice(),
        .trace = &event.trace,
        .commit = if (commit) |*request| request else null,
    });
    defer result.deinit(gpa);
    const note_root = try shadow_root.displayRoot(gpa, policy.shadow_root);
    defer gpa.free(note_root);
    const note = wire.shadowNote(note_root, event.trace);
    event.chars_emetgate = sym.len + hash_hex.len + body.len;
    event.chars_fullfile = event.trace.new_len;
    event.chars_sr = if (event.trace.old_body_len) |old| old + body.len else null;
    const full = tool_result.wantsFull(args);
    switch (result) {
        .committed => |new_hash| {
            event.outcome = .committed;
            event.edits = 1;
            event.hash = new_hash;
            if (policy.tree_cache) |cache| cache.invalidate(file_abs);
            try wire.writeCommitted(w, sym, expected, new_hash, note, full);
            try receipt_note.record(gpa, io, place.root, .{
                .operation = .@"try",
                .class = .spending,
                .evidence = "test",
                .files = &.{.{ .rel = place.rel, .before = before_hash, .after_abs = file_abs }},
                .symbols = &.{.{ .path = place.rel, .ref = sym, .before = if (expected == .present) expected.present else null, .after = new_hash }},
                .test_command = test_command,
                .typecheck_command = typecheck_command,
                .test_ms = event.trace.test_ms,
                .version = receipt_note.version,
            }, w, full, if (commit) |*made| made else null);
            try receipt_note.commit(gpa, io, place.root, commit, w);
            return false;
        },
        .rejected => |report| {
            event.outcome = .rejected;
            event.reason = wire.rejectionReason(report);
            try wire.writeRejected(gpa, w, test_command, report, note);
            return true;
        },
        .typecheck_failed => |report| {
            event.outcome = .rejected;
            event.reason = wire.typecheckReason(report);
            try wire.writeTypecheckRejected(gpa, w, typecheck_command.?, report, note);
            return true;
        },
        .rule_violation => |report| {
            event.outcome = .rejected;
            event.reason = "rule_violation";
            try wire.writeRuleViolation(w, report);
            return true;
        },
        .rule_check_failed => |crashed| {
            event.outcome = .rejected;
            event.reason = wire.rule_check_crashed_reason;
            try wire.writeRuleCheckFailed(w, crashed, note);
            return true;
        },
    }
}

const commit_message = @import("../platform/commit_message.zig");

fn callCommit(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, policy: Policy) !ToolResult {
    event.label = "commit";
    event.mutating = true;
    const message = try requireString(args, "message");
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    const is_error = commitInto(gpa, io, runtime, message, policy, &buffer.writer, event) catch |err| blk: {
        if (err == error.OutOfMemory) return err;
        event.fail(@errorName(err));
        buffer.clearRetainingCapacity();
        try wire.writeFailure(&buffer.writer, err, &event.trace.blocked);
        break :blk true;
    };
    return .{ .text = try dupTrim(gpa, buffer.written()), .is_error = is_error };
}

fn commitInto(gpa: Allocator, io: std.Io, runtime: *Runtime, message: []const u8, policy: Policy, w: *Writer, event: *telemetry.Event) !bool {
    try commit_message.check(message);
    const root = try repo.servedRoot(gpa, io, policy.root);
    defer gpa.free(root);
    const result = try commit_group.commit(gpa, io, root, .{
        .message = message,
        .shadow_root = policy.shadow_root,
        .gate_tree = policy.treeChoice(),
        .runtime = runtime,
    });
    defer result.deinit(gpa);
    var js: std.json.Stringify = .{ .writer = w };
    switch (result) {
        .committed => |c| {
            event.outcome = .committed;
            event.edits = c.files;
            try js.beginObject();
            try js.objectField("status");
            try js.write("committed");
            try js.objectField("commit");
            try js.write(c.oid);
            try js.objectField("base");
            try js.write(c.base);
            try js.objectField("files");
            try js.write(c.files);
            try js.objectField("receipts");
            try js.write(c.receipts);
            try js.endObject();
            return false;
        },
        .nothing_pending => {
            event.outcome = .rejected;
            event.reason = "nothing_pending";
            try js.beginObject();
            try js.objectField("status");
            try js.write("error");
            try js.objectField("error");
            try js.write("NothingToCommit");
            try js.endObject();
            return true;
        },
        .drift => {
            // commit_group already noted the uncertified paths; callTool adds them
            // to the reply as a "paths" list.
            event.outcome = .rejected;
            event.reason = "uncertified";
            try js.beginObject();
            try js.objectField("status");
            try js.write("error");
            try js.objectField("error");
            try js.write("UncertifiedChanges");
            try js.endObject();
            return true;
        },
        .rule_violation => |report| {
            event.outcome = .rejected;
            event.reason = "rule_violation";
            try wire.writeRuleViolation(w, report);
            return true;
        },
        .rule_check_failed => |crashed| {
            event.outcome = .rejected;
            event.reason = wire.rule_check_crashed_reason;
            try wire.writeRuleCheckFailed(w, crashed, null);
            return true;
        },
    }
}

const doc_writer = @import("../platform/doc_writer.zig");

fn docSelector(args: Value) !struct { selector: doc_writer.Selector, label: []const u8 } {
    if (getString(args, "pointer")) |pointer| return .{ .selector = .{ .pointer = pointer }, .label = pointer };
    if (getString(args, "heading")) |heading| return .{ .selector = .{ .heading = heading }, .label = heading };
    const start = getInt(args, "line_start") orelse return tool_result.missing(selector_missing, .{});
    const end = getInt(args, "line_end") orelse return tool_result.missing(selector_missing, .{});
    if (start < 1 or end < 1) return error.InvalidLineRange;
    return .{ .selector = .{ .line_range = .{ .start = @intCast(start), .end = @intCast(end) } }, .label = "range" };
}

fn callWriteDoc(gpa: Allocator, io: std.Io, args: ?Value, event: *telemetry.Event, policy: Policy) !ToolResult {
    const file = try requireString(args, "file");
    const hash_hex = try requireString(args, "hash");
    const new_text = try requireString(args, "content");
    event.label = "write_doc";
    event.file = file;
    event.mutating = true;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    const is_error = writeDocInto(gpa, io, file, hash_hex, new_text, args, policy, &buffer.writer, event) catch |err| blk: {
        if (err == error.OutOfMemory) return err;
        event.fail(@errorName(err));
        recovery.afterWriteDoc(hash_hex, err);
        buffer.clearRetainingCapacity();
        if (err == error.WrittenButNotIndexed) {
            try wire.writeNotIndexed(&buffer.writer, file);
        } else {
            try wire.writeFailure(&buffer.writer, err, &event.trace.blocked);
        }
        break :blk true;
    };
    return .{ .text = try dupTrim(gpa, buffer.written()), .is_error = is_error };
}

fn writeDocInto(gpa: Allocator, io: std.Io, file: []const u8, hash_hex: []const u8, new_text: []const u8, args: ?Value, policy: Policy, w: *Writer, event: *telemetry.Event) !bool {
    const given = try trustedTestCommand(args, policy);
    var commit = try policy_mod.commitRequest(args, policy, null);
    defer if (commit) |request| request.deinit(gpa);
    const arguments = args orelse return error.MissingArgument;
    const picked = try docSelector(arguments);
    const expected_hash = try symbol.parseHash(hash_hex);
    const place = try repo.jailTarget(gpa, io, policy.root, file, false);
    defer place.deinit(gpa);
    const test_command = try runner.resolveTestCommand(gpa, io, place.abs, given, policy.allow_repo_config);
    defer gpa.free(test_command);
    const typecheck_command = try runner.resolveTypecheckCommand(gpa, io, place.abs, trustedTypecheckCommand(policy), policy.allow_repo_config);
    defer if (typecheck_command) |command| gpa.free(command);
    var doc_trace: doc_writer.Trace = .{};
    defer event.trace.blocked = doc_trace.gate.blocked;
    const result = try doc_writer.tryWriteDoc(gpa, io, .{
        .file_abs = place.abs,
        .selector = picked.selector,
        .expected_hash = expected_hash,
        .new_text = new_text,
        .test_command = test_command,
        .typecheck_command = typecheck_command,
        .allow_repo_memory = policy.allow_repo_memory,
        .shadow_root = policy.shadow_root,
        .commit = if (commit) |*request| request else null,
        .gate_tree = policy.treeChoice(),
    }, &doc_trace);
    defer result.deinit(gpa);
    const doc_note = wire.treeNote(doc_trace.gate);
    const expected: symbol.Expected = .{ .present = expected_hash };
    const full = tool_result.wantsFull(args);
    switch (result) {
        .committed => |new_hash| {
            event.outcome = .committed;
            event.edits = 1;
            event.hash = new_hash;
            try wire.writeCommitted(w, picked.label, expected, new_hash, doc_note, full);
            try receipt_note.commit(gpa, io, place.root, commit, w);
            return false;
        },
        .rejected => |report| {
            event.outcome = .rejected;
            event.reason = wire.rejectionReason(report);
            try wire.writeRejected(gpa, w, test_command, report, doc_note);
            return true;
        },
        .typecheck_failed => |report| {
            event.outcome = .rejected;
            event.reason = wire.typecheckReason(report);
            try wire.writeTypecheckRejected(gpa, w, typecheck_command.?, report, doc_note);
            return true;
        },
        .rule_violation => |report| {
            event.outcome = .rejected;
            event.reason = "rule_violation";
            try wire.writeRuleViolation(w, report);
            return true;
        },
        .rule_check_failed => |crashed| {
            event.outcome = .rejected;
            event.reason = wire.rule_check_crashed_reason;
            try wire.writeRuleCheckFailed(w, crashed, null);
            return true;
        },
    }
}

const ItemKind = enum { code, doc, text };

fn itemKind(item: Value) !ItemKind {
    const declared = getString(item, "kind");
    var doc = false;
    if (declared) |text| {
        if (std.mem.eql(u8, text, "doc")) {
            doc = true;
        } else if (!std.mem.eql(u8, text, "code")) return error.InvalidOp;
    }
    if (node_tool.isNodeForm(item)) return .code;
    if (getString(item, "old_string") != null) return .text;
    const file = getString(item, "file") orelse return if (doc) .doc else .code;
    const symbol_named = getString(item, "symbol") != null;
    if (doc or (declared == null and !symbol_named and hasRegion(item))) {
        if (lang_registry.forPath(file) != null or absentHash(item) or !hasRegion(item)) return .text;
        return .doc;
    }
    if (try itemOp(item) == .delete) return .code;
    if (!symbol_named and (getString(item, "body") != null or getString(item, "content") != null)) return .text;
    return .code;
}

fn hasRegion(item: Value) bool {
    if (getString(item, "pointer")) |pointer| return pointer.len != 0;
    return getString(item, "heading") != null or getInt(item, "line_start") != null;
}

fn absentHash(item: Value) bool {
    const text = getString(item, "hash") orelse return true;
    return std.mem.eql(u8, text, "absent");
}

fn itemExpected(item: Value) !symbol.Expected {
    const text = getString(item, "hash") orelse return .absent;
    return symbol.parseExpected(text);
}

fn itemText(item: Value, index: usize) !batch_plan.Text {
    if (getString(item, "old_string")) |old| {
        const new = getString(item, "new_string") orelse return tool_result.missing("edits[{d}].new_string (string)", .{index});
        return .{ .replace = .{ .old = old, .new = new, .all = tool_result.getBool(item, "replace_all") orelse false } };
    }
    const content = getString(item, "content") orelse getString(item, "body") orelse return tool_result.missing("edits[{d}].content (string): the whole new file, or the text for line_start..line_end", .{index});
    if (!absentHash(item) and hasRegion(item)) return .{ .region = .{ .selector = (try docSelector(item)).selector, .new_text = content } };
    return .{ .whole = content };
}

fn jailItem(gpa: Allocator, io: std.Io, root: ?[]const u8, file: []const u8, may_create: bool, dirs: *std.ArrayList([]u8)) !repo.Jailed {
    return repo.jailTarget(gpa, io, root, file, may_create) catch |err| {
        if (err != error.ParentDirectoryMissing or !may_create) return err;
        const target = try file_edit.jailWrite(gpa, io, root, file, true);
        defer target.deinit(gpa);
        const served = try repo.servedRoot(gpa, io, root);
        errdefer gpa.free(served);
        const abs = try gpa.dupeZ(u8, target.abs);
        errdefer gpa.free(abs);
        const rel = try repo.relativeTo(gpa, served, abs);
        errdefer gpa.free(rel);
        for (target.created_dirs) |dir| {
            const known = for (dirs.items) |have| {
                if (std.ascii.eqlIgnoreCase(have, dir)) break true;
            } else false;
            if (!known) try dirs.append(gpa, try gpa.dupe(u8, dir));
        }
        return .{ .root = served, .abs = abs, .rel = rel, .creates = true };
    };
}

fn callTryBatch(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, policy: Policy) !ToolResult {
    const arguments = args orelse return tool_result.missing(edits_missing, .{});
    const edits_val = getField(arguments, "edits") orelse return tool_result.missing(edits_missing, .{});
    if (edits_val != .array or edits_val.array.items.len == 0) return tool_result.missing(edits_missing, .{});
    for (edits_val.array.items, 0..) |item, i| {
        const file = getString(item, "file") orelse return tool_result.missing("edits[{d}].file (string)", .{i});
        switch (try itemKind(item)) {
            .doc => {
                inline for (.{ "hash", "content" }) |field| {
                    if (getString(item, field) == null) return tool_result.missing("edits[{d}]." ++ field ++ " (string)", .{i});
                }
                _ = docSelector(item) catch |err| return if (err == error.MissingArgument) tool_result.missing("edits[{d}]: " ++ selector_missing, .{i}) else err;
            },
            .code => {
                if (node_tool.isNodeForm(item)) continue;
                if (try itemOp(item) == .delete) continue;
                inline for (.{ "symbol", "body" }) |field| {
                    if (getString(item, field) == null) return missingCodeField(i, field, file);
                }
            },
            .text => {
                const text = try itemText(item, i);
                if (text == .region and getString(item, "hash") == null) return tool_result.missing("edits[{d}].hash (string)", .{i});
            },
        }
    }
    event.mutating = true;

    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    const is_error = batchInto(gpa, io, runtime, edits_val.array.items, arguments, policy, &buffer.writer, event) catch |err| blk: {
        if (err == error.OutOfMemory) return err;
        event.fail(@errorName(err));
        recovery.afterBatch(gpa, io, runtime, policy.root, edits_val.array.items, err);
        buffer.clearRetainingCapacity();
        if (err == error.WrittenButNotIndexed) {
            try wire.writeNotIndexed(&buffer.writer, firstAbsentFile(edits_val.array.items));
        } else {
            try wire.writeFailure(&buffer.writer, err, &event.trace.blocked);
        }
        break :blk true;
    };
    return .{ .text = try dupTrim(gpa, buffer.written()), .is_error = is_error };
}

const edits_missing = "edits (non-empty array of objects, one per file)";
const selector_missing = "pointer, heading, or line_start and line_end (integers)";

fn missingCodeField(index: usize, comptime field: []const u8, file: []const u8) error{MissingArgument} {
    if (lang_registry.forPath(file) == null) return tool_result.missing("edits[{d}]." ++ field ++ " (string); {s} is not source code, so it needs content (the whole file) or kind:\"doc\" with hash, content and " ++ selector_missing, .{ index, file });
    return tool_result.missing("edits[{d}]." ++ field ++ " (string)", .{index});
}

fn itemOp(item: Value) !runner.EditOp {
    const text = getString(item, "op") orelse return .write;
    return std.meta.stringToEnum(runner.EditOp, text) orelse error.InvalidOp;
}

fn firstAbsentFile(items: []const Value) []const u8 {
    for (items) |item| {
        if (node_tool.isNodeForm(item)) continue;
        const expected = symbol.parseExpected(getString(item, "hash") orelse continue) catch continue;
        if (expected == .absent) return getString(item, "file").?;
    }
    return getString(items[0], "file").?;
}

fn recordBatch(gpa: Allocator, io: std.Io, root: []const u8, places: []const repo.Jailed, edits: []const runner.Edit, prepared: []const batch_mod.Prepared, before_hashes: []const ?symbol.Hash, committed: []const batch_mod.Committed, test_command: []const u8, typecheck_command: ?[]const u8, test_ms: ?u64, w: *Writer, full: bool, request: ?*commit_plan.Request) !void {
    if (edits.len == 0) return;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var files: std.ArrayList(receipts.FileChange) = .empty;
    var symbols: std.ArrayList(@import("../verify/receipt.zig").SymbolEntry) = .empty;
    var symmetric = true;
    for (places, edits, prepared, before_hashes, committed) |place, edit, p, before, c| {
        if (edit.text != null) {
            try files.append(arena, .{ .rel = place.rel, .before = before, .after_abs = place.abs });
            symmetric = false;
            continue;
        }
        if (p.nodes) |applied| {
            try files.append(arena, .{ .rel = place.rel, .before = before, .after_abs = place.abs });
            try node_tool.symbolEntries(arena, place.rel, applied, &symbols);
            symmetric = false;
            continue;
        }
        const removes_file = c.deleted and edit.ref_text.len == 0;
        try files.append(arena, .{ .rel = place.rel, .before = before, .after_abs = if (removes_file) null else place.abs });
        if (c.deleted) {
            if (edit.ref_text.len != 0) try symbols.append(arena, .{ .path = place.rel, .ref = edit.ref_text, .before = c.hash, .after = null });
            continue;
        }
        const created = edit.expected_hash == .absent;
        if (edit.ref_text.len != 0) try symbols.append(arena, .{ .path = place.rel, .ref = edit.ref_text, .before = if (created) null else edit.expected_hash.present, .after = c.hash });
        const evidence = c.evidence orelse {
            symmetric = false;
            continue;
        };
        if (!created or !evidence.symmetric()) symmetric = false;
    }
    try receipt_note.record(gpa, io, root, .{
        .operation = .try_batch,
        .class = if (symmetric) .symmetry else .spending,
        .evidence = if (symmetric) "unreferenced" else "test",
        .files = files.items,
        .symbols = symbols.items,
        .test_command = test_command,
        .typecheck_command = typecheck_command,
        .test_ms = test_ms,
        .version = receipt_note.version,
    }, w, full, request);
}

fn batchInto(gpa: Allocator, io: std.Io, runtime: *Runtime, items: []const Value, args: Value, policy: Policy, w: *Writer, event: *telemetry.Event) !bool {
    const given = try trustedTestCommand(args, policy);
    var commit = try policy_mod.commitRequest(args, policy, runtime);
    defer if (commit) |request| request.deinit(gpa);

    var code_count: usize = 0;
    var doc_count: usize = 0;
    for (items) |item| switch (try itemKind(item)) {
        .code, .text => code_count += 1,
        .doc => doc_count += 1,
    };
    var new_dirs: std.ArrayList([]u8) = .empty;
    defer {
        for (new_dirs.items) |dir| gpa.free(dir);
        new_dirs.deinit(gpa);
    }

    const edits = try gpa.alloc(runner.Edit, code_count);
    defer gpa.free(edits);
    const doc_edits = try gpa.alloc(runner.DocEdit, doc_count);
    defer gpa.free(doc_edits);
    const order = try gpa.alloc(usize, items.len);
    defer gpa.free(order);
    const doc_expected = try gpa.alloc(symbol.Hash, doc_count);
    defer gpa.free(doc_expected);
    const places = try gpa.alloc(repo.Jailed, items.len);
    defer gpa.free(places);
    var built: usize = 0;
    defer for (places[0..built]) |place| place.deinit(gpa);
    const node_lists = try gpa.alloc([]node_cas_mod.Edit, items.len);
    defer gpa.free(node_lists);
    var parsed: usize = 0;
    defer for (node_lists[0..parsed]) |list| gpa.free(list);

    var ci: usize = 0;
    var di: usize = 0;
    for (items, 0..) |item, i| {
        const file = getString(item, "file").?;
        switch (try itemKind(item)) {
            .code => {
                const node_form = node_tool.isNodeForm(item);
                node_lists[i] = if (node_form) try node_tool.parse(gpa, item) else &.{};
                parsed = i + 1;
                const op = try itemOp(item);
                const expected: symbol.Expected = if (getString(item, "hash")) |hash| try symbol.parseExpected(hash) else .absent;
                places[i] = try jailItem(gpa, io, policy.root, file, !node_form and op == .write and expected == .absent, &new_dirs);
                built = i + 1;
                if (op == .delete) try repo.refuseLinkAsWritten(gpa, io, file);
                edits[ci] = .{
                    .file_abs = places[i].abs,
                    .ref_text = getString(item, "symbol") orelse "",
                    .new_body = getString(item, "body") orelse "",
                    .expected_hash = expected,
                    .op = op,
                    .nodes = node_lists[i],
                };
                order[i] = ci;
                ci += 1;
            },
            .text => {
                node_lists[i] = &.{};
                parsed = i + 1;
                const text = try itemText(item, i);
                places[i] = try jailItem(gpa, io, policy.root, file, text == .whole, &new_dirs);
                built = i + 1;
                edits[ci] = .{
                    .file_abs = places[i].abs,
                    .ref_text = "",
                    .expected_hash = try itemExpected(item),
                    .text = text,
                };
                order[i] = ci;
                ci += 1;
            },
            .doc => {
                node_lists[i] = &.{};
                parsed = i + 1;
                places[i] = try repo.jailTarget(gpa, io, policy.root, file, false);
                built = i + 1;
                const picked = try docSelector(item);
                const expected_hash = try symbol.parseHash(getString(item, "hash").?);
                doc_expected[di] = expected_hash;
                doc_edits[di] = .{
                    .file_abs = places[i].abs,
                    .selector = picked.selector,
                    .expected_hash = expected_hash,
                    .new_text = getString(item, "content").?,
                };
                order[i] = code_count + di;
                di += 1;
            },
        }
    }

    const anchor = file_edit.existingAncestor(io, places[0].abs) orelse return error.InvalidPath;
    const in_place = std.mem.eql(u8, anchor, std.fs.path.dirname(places[0].abs) orelse anchor);
    const probe = if (in_place) try gpa.dupe(u8, places[0].abs) else try std.fmt.allocPrint(gpa, "{s}\\_", .{anchor});
    defer gpa.free(probe);
    const resolved = try runner.resolveTestCommand(gpa, io, probe, given, policy.allow_repo_config);
    defer gpa.free(resolved);
    const typecheck_command = try runner.resolveTypecheckCommand(gpa, io, probe, trustedTypecheckCommand(policy), policy.allow_repo_config);
    defer if (typecheck_command) |command| gpa.free(command);
    const before_hashes = try gpa.alloc(?symbol.Hash, edits.len);
    defer gpa.free(before_hashes);
    for (edits, before_hashes) |edit, *slot| slot.* = disk.hashFile(gpa, io, edit.file_abs) catch null;
    const options: batch_mod.BatchOptions = .{ .edits = edits, .doc_edits = doc_edits, .test_command = resolved, .typecheck_command = typecheck_command, .allow_repo_memory = policy.allow_repo_memory, .shadow_root = policy.shadow_root, .gate_tree = policy.treeChoice(), .trace = &event.trace, .language_service = policy.language_service, .commit = if (commit) |*request| request else null, .created_dirs = @ptrCast(new_dirs.items) };
    var planned = try batch_mod.planBatch(gpa, io, runtime, options);
    defer planned.deinit(gpa);
    const result = try batch_mod.commitPlanned(gpa, io, planned.root, planned.prepared.items, edits, options);
    defer result.deinit(gpa);
    const note_root = try shadow_root.displayRoot(gpa, policy.shadow_root);
    defer gpa.free(note_root);
    const note = wire.shadowNote(note_root, event.trace);

    var sent: usize = 0;
    for (items, node_lists) |item, list| {
        sent += node_tool.sentChars(list);
        inline for (.{ "symbol", "hash", "body", "content", "old_string", "new_string" }) |field| {
            if (getString(item, field)) |text| sent += text.len;
        }
    }
    event.chars_emetgate = sent;
    event.chars_fullfile = event.trace.new_len;
    const full = tool_result.wantsFull(args);
    switch (result) {
        .committed => |committed| {
            event.outcome = .committed;
            event.edits = items.len;
            if (policy.tree_cache) |cache| for (edits) |edit| cache.invalidate(edit.file_abs);
            const views = try gpa.alloc(wire.BatchEdit, items.len);
            defer gpa.free(views);
            for (items, 0..) |item, i| {
                const slot = order[i];
                views[i] = switch (try itemKind(item)) {
                    .code => .{
                        .file = getString(item, "file").?,
                        .symbol = getString(item, "symbol") orelse "",
                        .old_hash = if (committed[slot].deleted) .{ .present = committed[slot].hash } else edits[slot].expected_hash,
                        .new_hash = committed[slot].hash,
                        .evidence = committed[slot].evidence,
                        .deleted = committed[slot].deleted,
                        .nodes = planned.prepared.items[slot].nodes,
                    },
                    .text => .{
                        .file = getString(item, "file").?,
                        .symbol = "",
                        .old_hash = if (planned.prepared.items[slot].base_hash) |hash| .{ .present = hash } else .absent,
                        .new_hash = committed[slot].hash,
                        .evidence = null,
                        .deleted = false,
                    },
                    .doc => .{
                        .file = getString(item, "file").?,
                        .symbol = (docSelector(item) catch unreachable).label,
                        .old_hash = .{ .present = doc_expected[slot - code_count] },
                        .new_hash = committed[slot].hash,
                        .evidence = null,
                        .deleted = false,
                    },
                };
            }
            try wire.writeBatchCommitted(w, views, note, full);
            const code_places = try gpa.alloc(repo.Jailed, edits.len);
            defer gpa.free(code_places);
            const code_committed = try gpa.alloc(@import("../platform/batch.zig").Committed, edits.len);
            defer gpa.free(code_committed);
            for (items, 0..) |item, i| {
                if (itemKind(item) catch unreachable == .doc) continue;
                code_places[order[i]] = places[i];
                code_committed[order[i]] = committed[order[i]];
            }
            try recordBatch(gpa, io, places[0].root, code_places, edits, planned.prepared.items, before_hashes, code_committed, resolved, typecheck_command, event.trace.test_ms, w, full, if (commit) |*made| made else null);
            try receipt_note.commit(gpa, io, places[0].root, commit, w);
            return false;
        },
        .rejected => |report| {
            event.outcome = .rejected;
            event.reason = wire.rejectionReason(report);
            try wire.writeRejected(gpa, w, resolved, report, note);
            return true;
        },
        .typecheck_failed => |report| {
            event.outcome = .rejected;
            event.reason = wire.typecheckReason(report);
            try wire.writeTypecheckRejected(gpa, w, typecheck_command.?, report, note);
            return true;
        },
        .rule_violation => |report| {
            event.outcome = .rejected;
            event.reason = "rule_violation";
            try wire.writeRuleViolation(w, report);
            return true;
        },
        .rule_check_failed => |crashed| {
            event.outcome = .rejected;
            event.reason = wire.rule_check_crashed_reason;
            try wire.writeRuleCheckFailed(w, crashed, note);
            return true;
        },
    }
}
