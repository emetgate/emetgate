const std = @import("std");
const commit_plan = @import("../platform/commit_plan.zig");
const commit_group = @import("../platform/commit_group.zig");
const change_undo = @import("../platform/change_undo.zig");
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
const map_tools = @import("map_tools.zig");
const read_tools = @import("read_tools.zig");
const sent_ledger = @import("../engine/sent_ledger.zig");
const read_budget = @import("read_budget.zig");
const read_cache = @import("read_cache.zig");
const reply_contract = @import("reply_contract.zig");
const raw_reply = @import("raw_reply.zig");
const outline = @import("outline.zig");
const search_v1 = @import("search_v1.zig");
const find_tools = @import("find_tools.zig");
const git_tools = @import("git_tools.zig");
const git_write = @import("git_write.zig");
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
const batch_stage = @import("batch_stage.zig");
const runner = @import("../platform/runner.zig");
const test_command_mod = @import("../platform/test_command.zig");
const test_debt = @import("../platform/test_debt.zig");
const tool_names = @import("../engine/tool_names.zig");
const shadow_root = @import("../platform/shadow_root.zig");
const repo = @import("../platform/repo.zig");
const git_commit = @import("../platform/git_commit.zig");
const known_files = @import("known_files.zig");
const file_edit = @import("../platform/file_edit.zig");
const fuzzy_match = @import("../platform/fuzzy_match.zig");
const rules = @import("../platform/rules.zig");
const lang_registry = @import("../engine/lang/registry.zig");
const Profile = @import("../engine/lang/profile.zig").Profile;
const forgive = @import("forgive.zig");
const batch_plan = @import("../platform/batch_plan.zig");
const batch_merge = @import("batch_merge.zig");
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

pub const unverified_note = "none: no test command yet, so this write ran no test; add one (" ++ test_command_mod.markers_hint ++ ") or pass --test; then every write runs it";

pub fn callTool(gpa: Allocator, io: std.Io, runtime: *Runtime, name: []const u8, args: ?Value, event: *telemetry.Event, policy: Policy) !ToolResult {
    wire.clearFix();
    tool_result.clearMissing();
    _ = commit_plan.takeFound();
    _ = commit_refusal.take();
    _ = test_command_mod.takeUnverified();
    _ = test_command_mod.takeLate();
    test_debt.drop();
    const context_changed: ?bool = if (policy.context) |context| context.stale() else null;
    if (policy.mirror) |m| {
        if (context_changed orelse false) m.reset();
        m.tick();
    }
    // The model may have lost what it was shown: after a compaction, or when the session has no
    // context watch at all, the ledger forgets, so nothing is ever skipped as "already shown".
    if (context_changed orelse true) policy.ledgerReset();
    var result = try dispatch(gpa, io, runtime, name, args, event, policy);
    if (test_command_mod.takeUnverified()) {
        if (try receipt_note.unverified(gpa, result.text, test_command_mod.unverified_status, unverified_note, args)) |text| {
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

const read_only_tools = [_][]const u8{
    "emetgate_symbols",
    "emetgate_skeleton",
    "emetgate_read_symbol",
    "emetgate_mutate",
    "emetgate_read_file",
    "emetgate_list",
    "emetgate_search",
    "emetgate_find",
    "emetgate_scan",
    "emetgate_git",
};

pub fn readOnly(name: []const u8) bool {
    for (read_only_tools) |tool| {
        if (std.mem.eql(u8, tool, name)) return true;
    }
    return false;
}

fn dispatch(gpa: Allocator, io: std.Io, runtime: *Runtime, given_name: []const u8, given_args: ?Value, event: *telemetry.Event, policy: Policy) !ToolResult {
    var forgiven = std.heap.ArenaAllocator.init(gpa);
    defer forgiven.deinit();
    const call = try forgive.normalize(forgiven.allocator(), given_name, given_args);
    const name = call.name;
    const args = call.args;
    if (std.mem.eql(u8, name, "emetgate_symbols")) return callSymbols(gpa, io, runtime, args, event, policy.root, policy.tree_cache, policy.read_budget);
    if (std.mem.eql(u8, name, "emetgate_skeleton")) return rawCode(gpa, policy, try callSkeleton(gpa, io, runtime, args, event, policy.root, policy.mirror, policy.tree_cache));
    if (std.mem.eql(u8, name, "emetgate_read_symbol")) return rawCode(gpa, policy, try callReadSymbol(gpa, io, runtime, args, event, policy.root, policy.mirror, policy.tree_cache, policy.read_budget, policy.sent_ledger));
    if (std.mem.eql(u8, name, "emetgate_mutate")) return callMutate(gpa, io, runtime, args, event, policy.root);
    if (std.mem.eql(u8, name, "emetgate_try")) return callTry(gpa, io, runtime, args, event, policy);
    if (std.mem.eql(u8, name, "emetgate_commit")) return callCommit(gpa, io, runtime, args, event, policy);
    if (std.mem.eql(u8, name, "emetgate_try_batch")) return callTryBatch(gpa, io, runtime, args, event, policy);
    if (std.mem.eql(u8, name, "emetgate_change")) return callChange(gpa, io, runtime, args, event, policy);
    if (std.mem.eql(u8, name, "emetgate_rename")) return rename_tool.callRename(gpa, io, runtime, args, event, policy);
    if (std.mem.eql(u8, name, "emetgate_move")) return move_tool.callMove(gpa, io, runtime, args, event, policy);
    if (std.mem.eql(u8, name, "emetgate_move_file")) return move_file_tool.callMoveFile(gpa, io, runtime, args, event, policy);
    if (std.mem.eql(u8, name, "emetgate_write_doc")) return callWriteDoc(gpa, io, args, event, policy);
    if (std.mem.eql(u8, name, "emetgate_edit")) return edit_tool.callEdit(gpa, io, runtime, args, event, policy);
    if (std.mem.eql(u8, name, "emetgate_write")) return edit_tool.callWrite(gpa, io, runtime, args, event, policy);
    if (std.mem.eql(u8, name, "emetgate_read_file")) return rawCode(gpa, policy, try read_tools.callReadFile(gpa, io, args, event, policy.root, policy.mirror, .{ .runtime = runtime, .tree_cache = policy.tree_cache, .sent_ledger = policy.sent_ledger }, policy.raw_code));
    if (std.mem.eql(u8, name, "emetgate_list")) return read_tools.callList(gpa, io, args, event, policy.root);
    if (std.mem.eql(u8, name, "emetgate_search")) return search_v1.callSearchAs(gpa, io, runtime, args, event, policy.root, policy.tree_cache, policy.search_session, .{ .format = if (policy.search_text) .text else .json, .internals = policy.search_internals });
    if (std.mem.eql(u8, name, "emetgate_find")) return find_tools.callFind(gpa, args, event, policy.find_session);
    if (std.mem.eql(u8, name, "emetgate_scan")) return callScan(gpa, io, runtime, args, event, policy.root, policy.tree_cache);
    if (std.mem.eql(u8, name, "emetgate_git")) return git_tools.callGit(gpa, io, runtime, args, event, policy.root, policy.read_budget);
    if (std.mem.eql(u8, name, "emetgate_git_write")) {
        if (try gatedGitCommit(gpa, io, runtime, args, event, policy)) |made| return made;
        return git_write.callGitWrite(gpa, io, args, event, policy.root, policy.open_run);
    }
    if (std.mem.eql(u8, name, "emetgate_run")) {
        const result = try run_tool.callRun(gpa, io, runtime, args, event, policy);
        return if (policy.open_run) rawCode(gpa, policy, result) else result;
    }
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
    const offset: usize = if (getField(args.?, "offset")) |field| switch (field) {
        .integer => |n| if (n >= 0) @intCast(n) else return tool_result.missing("offset (integer of at least 0)", .{}),
        .null => 0,
        else => return tool_result.missing("offset (integer of at least 0)", .{}),
    } else 0;
    event.label = "scan";
    event.file = where;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    var refusal: ?[]const u8 = null;
    renderScan(gpa, io, runtime, root, check, where, offset, tree_cache, &buffer.writer, &refusal) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err, event);
    };
    if (refusal) |name| {
        event.fail(name);
        return .{ .text = try dupTrim(gpa, buffer.written()), .is_error = true };
    }
    return success(gpa, &buffer);
}

fn renderScan(gpa: Allocator, io: std.Io, runtime: *Runtime, root: ?[]const u8, check: []const u8, where: ?[]const u8, offset: usize, tree_cache: ?*tree_cache_mod.TreeCache, w: *Writer, refusal: *?[]const u8) !void {
    const root_abs = try repo.servedRoot(gpa, io, root);
    defer gpa.free(root_abs);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    _ = try scan_command.run(gpa, io, runtime, root_abs, .{
        .source = .{ .check = .{ .spec = check, .where = where } },
        .json = true,
        .max_violations = max_scan_violations,
        .violation_offset = offset,
        .call_operations = max_scan_operations,
        .refusal = refusal,
        .tree_cache = tree_cache,
    }, w, &discard.writer);
}

fn callSymbols(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, root: ?[]const u8, tree_cache: ?*tree_cache_mod.TreeCache, budget: usize) !ToolResult {
    const file = try requireString(args, "file");
    event.label = "symbols";
    event.file = file;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    const within = if (args) |a| getString(a, "within") else null;
    const offset = if (args) |a| getInt(a, "offset") else null;
    if (offset) |n| if (n < 0) return tool_result.missing("offset (integer, 0 or more)", .{});
    const page: ?usize = if (offset) |n| @intCast(n) else if (tool_result.wantsFull(args)) 0 else null;
    renderSymbols(gpa, io, runtime, root, file, tree_cache, page, within, budget, &buffer.writer) catch |err| {
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

fn renderSymbols(gpa: Allocator, io: std.Io, runtime: *Runtime, root: ?[]const u8, file: []const u8, tree_cache: ?*tree_cache_mod.TreeCache, page: ?usize, within: ?[]const u8, budget: usize, w: *Writer) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const prefix: []const []const u8 = if (within) |text| try wire.withinSegments(arena, text) else &.{};
    const loaded = try loadJailed(gpa, io, runtime, root, file, tree_cache);
    defer loaded.deinit(gpa);
    const table = try wire.symbolsWithin(arena, (try loaded.snapshot.symbols()).*, prefix);
    if (table.symbols.len + table.declarations.len + table.statements.len == 0 and prefix.len != 0) return error.NoSymbolsWithin;
    if (page == null and table.symbols.len + table.declarations.len > wire.compact_symbols_over) return wire.writeSymbolsCompact(gpa, w, file, table, prefix, budget);
    try writeSymbolsPage(gpa, w, file, table, within, page orelse 0);
}

const symbols_entry_cost: usize = 128;

fn symbolsRefAt(table: symbol.Table, index: usize) symbol.Ref {
    if (index < table.symbols.len) return table.symbols[index].ref;
    const after = index - table.symbols.len;
    if (after < table.declarations.len) return table.declarations[after].ref;
    return table.statements[after - table.declarations.len].ref;
}

fn pageOf(comptime T: type, items: []T, base: usize, from: usize, end: usize) []T {
    const lo = std.math.clamp(from, base, base + items.len) - base;
    const hi = std.math.clamp(end, base, base + items.len) - base;
    return items[lo..hi];
}

fn writeSymbolsPage(gpa: Allocator, w: *Writer, file: []const u8, table: symbol.Table, within: ?[]const u8, offset: usize) !void {
    const total = table.symbols.len + table.declarations.len + table.statements.len;
    const from = @min(offset, total);
    const limit = reply_contract.room(.symbols) -| (2 * file.len + 64);
    var used: usize = 0;
    var end = from;
    while (end < total) : (end += 1) {
        const cost = symbols_entry_cost + std.fmt.count("{f}", .{symbolsRefAt(table, end)});
        if (end != from and used + cost > limit) break;
        used += cost;
    }
    const declared_base = table.symbols.len;
    const statement_base = declared_base + table.declarations.len;
    const shown: symbol.Table = .{
        .arena = table.arena,
        .symbols = pageOf(symbol.Symbol, table.symbols, 0, from, end),
        .declarations = pageOf(symbol.Declaration, table.declarations, declared_base, from, end),
        .statements = pageOf(symbol.Statement, table.statements, statement_base, from, end),
        .short_refs = table.short_refs,
    };
    try wire.writeSymbols(gpa, w, file, shown);
    if (end < total) try reply_contract.writeTrailer(w, "symbols {d}-{d} of {d}", .{ end + 1, total, total }, "emetgate_symbols", .{ .file = file, .within = within, .offset = end });
}

fn callSkeleton(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, root: ?[]const u8, mirror: ?*mirror_mod.Mirror, tree_cache: ?*tree_cache_mod.TreeCache) !ToolResult {
    const file = try requireString(args, "file");
    const force = if (args) |a| tool_result.getBool(a, "force") orelse false else false;
    event.label = "skeleton";
    event.file = file;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    const offset = if (args) |a| tool_result.getInt(a, "offset") orelse 0 else 0;
    renderSkeleton(gpa, io, runtime, root, file, force, offset, mirror, tree_cache, &buffer.writer, event) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err, event);
    };
    return success(gpa, &buffer);
}

fn renderSkeleton(gpa: Allocator, io: std.Io, runtime: *Runtime, root: ?[]const u8, file: []const u8, force: bool, offset_arg: i64, mirror: ?*mirror_mod.Mirror, tree_cache: ?*tree_cache_mod.TreeCache, w: *Writer, event: *telemetry.Event) !void {
    if (offset_arg < 0) return error.InvalidOffset;
    const loaded = try loadJailed(gpa, io, runtime, root, file, tree_cache);
    defer loaded.deinit(gpa);
    const place = loaded.place;
    const snapshot = loaded.snapshot;
    const whole = snapshot.source.len <= outline.threshold;
    const file_hash = symbol.fileHash(snapshot.source);
    if (whole) if (try read_cache.wholeSince(gpa, mirror, file, file_hash, force)) |since| {
        event.chars_emetgate = 0;
        event.chars_fullfile = snapshot.source.len;
        return read_cache.writeCoveredSince(w, file, null, file_hash, since);
    };
    const docs: ?doc_fold.Folded = if (whole) try doc_fold.fold(gpa, snapshot.profile, snapshot.tree, 0, @intCast(snapshot.source.len)) else null;
    defer if (docs) |d| d.deinit(gpa);
    const full_text = if (docs) |d| try gpa.dupe(u8, d.text) else try skeleton.compact(gpa, runtime.parser, snapshot.profile, snapshot.tree);
    defer gpa.free(full_text);
    // The skeleton from byte `offset`, cut at a line end to the reply budget.
    const from = reply_contract.charStart(full_text, @intCast(offset_arg));
    const cut = reply_contract.cut(full_text[from..], reply_contract.room(.skeleton), .json);
    const text = cut.kept;
    const hash = symbol.hashOf(text);
    if (mirror) |m| {
        const key = try std.fmt.allocPrint(gpa, "skeleton:{s}@{d}", .{ file, from });
        defer gpa.free(key);
        if (try m.seen(key, hash, file_hash, force)) |since| {
            event.chars_emetgate = 0;
            event.chars_fullfile = snapshot.source.len;
            return wire.writeUnchangedSince(w, file, null, hash, file_hash, since);
        }
    }
    const adopted = try rules.adoptedFor(gpa, io, place.root, place.rel);
    defer adopted.deinit();
    event.chars_emetgate = text.len;
    event.chars_fullfile = snapshot.source.len;
    try wire.writeSkeleton(w, file, file_hash, if (whole) .content else .skeleton, text, adopted.items, if (docs) |d| d.spans else &.{});
    if (whole and from == 0 and cut.whole) try read_cache.recordWhole(gpa, mirror, file, file_hash);
    if (!cut.whole) {
        const next = from + text.len;
        try reply_contract.writeTrailer(w, "skeleton bytes {d}-{d}", .{ next, full_text.len }, "emetgate_skeleton", .{ .file = file, .offset = next });
    }
}

fn callReadSymbol(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, root: ?[]const u8, mirror: ?*mirror_mod.Mirror, tree_cache: ?*tree_cache_mod.TreeCache, budget: usize, ledger: ?*sent_ledger.Ledger) !ToolResult {
    const file = try requireString(args, "file");
    const force = if (args) |a| tool_result.getBool(a, "force") orelse false else false;
    const nodes = if (args) |a| tool_result.getBool(a, "nodes") orelse false else false;
    event.label = "read_symbol";
    event.file = file;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    const arguments = args.?;
    const detail = read_budget.parseDetail(tool_result.getString(arguments, "detail")) catch |err| return failure(gpa, &buffer, err, event);
    const reading: Reading = .{ .budget = budget, .detail = detail, .ledger = ledger };
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
            if (err == error.AmbiguousSymbol) for (list) |item| switch (item) {
                .string => |text| if (recovery.ambiguity(gpa, io, runtime, root, "", file, text)) break,
                else => {},
            };
            return failure(gpa, &buffer, err, event);
        };
        return success(gpa, &buffer);
    }
    const sym = try requireString(args, "symbol");
    event.symbol = sym;
    renderSymbolBody(gpa, io, runtime, root, file, sym, force, nodes, reading, mirror, tree_cache, &buffer.writer, event) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (err == error.AmbiguousSymbol) _ = recovery.ambiguity(gpa, io, runtime, root, "", file, sym);
        return failure(gpa, &buffer, err, event);
    };
    return success(gpa, &buffer);
}

const Reading = struct {
    budget: usize,
    detail: read_budget.Detail,
    ledger: ?*sent_ledger.Ledger = null,

    fn note(self: Reading, rel: []const u8) read_tools.Note {
        return .{ .ledger = self.ledger, .rel = rel };
    }

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

fn signatureOf(snapshot: *const Snapshot, found: symbol.Item) []const u8 {
    const start = found.span.start;
    const body_start = (found.body orelse return "").startByte();
    if (body_start <= start) return "";
    return std.mem.trim(u8, snapshot.source[start..body_start], " \t\r\n");
}

fn firstLineOf(text: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    return std.mem.trim(u8, text[0..end], " \t\r\n");
}

fn shownSpan(found: symbol.Item) symbol.Span {
    const body = found.body orelse return found.span;
    return .{ .start = body.startByte(), .end = body.endByte() };
}

fn renderSymbolBody(gpa: Allocator, io: std.Io, runtime: *Runtime, root: ?[]const u8, file: []const u8, sym: []const u8, force: bool, nodes: bool, reading: Reading, mirror: ?*mirror_mod.Mirror, tree_cache: ?*tree_cache_mod.TreeCache, w: *Writer, event: *telemetry.Event) !void {
    const loaded = try loadJailed(gpa, io, runtime, root, file, tree_cache);
    defer loaded.deinit(gpa);
    const snapshot = loaded.snapshot;
    const table = try snapshot.symbols();
    try requireSymbols(gpa, table.*, file, &.{sym});
    const ref = try symbol.Ref.parse(gpa, sym);
    defer ref.deinit(gpa);
    const found = try table.item(ref);
    event.hash = found.hash;
    const shown = shownSpan(found);
    const note = reading.note(loaded.place.rel);
    const docs = if (nodes) null else try reading.foldDocs(gpa, snapshot, shown.start, shown.end);
    defer if (docs) |d| d.deinit(gpa);
    const body = if (docs) |d| d.text else snapshot.source[shown.start..shown.end];
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
        const annotated = try node_cas_mod.annotateSnapshot(gpa, snapshot, found.span);
        defer gpa.free(annotated);
        const cut = LinesCut.of(snapshot.source, annotated, found.span.start, found.span.end, 0);
        try note.shown(snapshot.source, found.span.start, found.span.end, .dense);
        event.chars_emetgate = cut.c.kept.len;
        try wire.writeSymbolNodes(w, file, sym, found.hash, cut.c.kept);
        return cut.trailer(w, file, .nodes, "");
    }
    if (folds) {
        const lines = try read_budget.Lines.init(gpa, snapshot.source);
        defer lines.deinit(gpa);
        const view = try read_budget.fold(gpa, snapshot.source, lines, found.body orelse found.node, reading.budget);
        defer view.deinit(gpa);
        try note.shown(snapshot.source, shown.start, shown.end, .dense);
        event.chars_emetgate = view.text.len;
        return wire.writeSymbolBodyFolded(w, file, sym, found.hash, .{ .view = view, .signature = signatureOf(snapshot, found), .budget = reading.budget });
    }
    // detail:"full" sends the body unfolded, still within the reply budget.
    const cut = LinesCut.of(snapshot.source, body, shown.start, shown.end, 0);
    try note.shown(snapshot.source, shown.start, shown.end, if (docs == null) .exact else .dense);
    event.chars_emetgate = cut.c.kept.len;
    try wire.writeSymbolBody(w, file, sym, found.hash, cut.c.kept, if (docs) |d| d.spans else &.{});
    return cut.trailer(w, file, if (docs == null) .source else .folded, "");
}

/// A symbol's text (source, docs-folded or node-annotated) that starts at byte
/// `start` of the source, cut to the read_symbol budget; `trailer` then names
/// the call returning the lines left out.
const LinesCut = struct {
    c: reply_contract.Cut,
    first: i64,
    last: i64,
    column: usize,

    const Form = enum { source, folded, nodes };

    fn of(source: []const u8, text: []const u8, start: usize, end: usize, used: usize) LinesCut {
        const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..start], '\n')) |nl| nl + 1 else 0;
        return .{
            .c = reply_contract.cut(text, reply_contract.room(.read_symbol) -| used, .json),
            .first = @intCast(std.mem.count(u8, source[0..start], "\n") + 1),
            .last = @intCast(std.mem.count(u8, source[0..@max(start, end -| 1)], "\n") + 1),
            .column = start - line_start,
        };
    }

    fn trailer(self: LinesCut, w: *Writer, file: []const u8, form: Form, also: []const u8) !void {
        if (self.c.whole) return;
        if (form == .folded) {
            // Folded text has fewer lines than the source: resume at its start.
            return reply_contract.writeTrailer(w, "the rest of lines {d}-{d}{s}", .{ self.first, self.last, also }, "emetgate_read_file", .{ .file = file, .line_start = self.first, .line_end = self.last });
        }
        if (self.c.split_line) {
            if (form == .nodes) return reply_contract.writeTrailer(w, "the rest of lines {d}-{d} (line {d} is longer than the reply){s}", .{ self.first, self.last, self.first, also }, "emetgate_read_file", .{ .file = file, .line_start = self.first, .line_end = self.last });
            const resume_at = self.column + self.c.kept.len;
            return reply_contract.writeTrailer(w, "bytes {d}- of line {d} and lines {d}-{d}{s}", .{ resume_at, self.first, self.first + 1, self.last, also }, "emetgate_read_file", .{ .file = file, .line_start = self.first, .line_end = self.last, .offset = resume_at });
        }
        const next = self.first + @as(i64, @intCast(self.c.lines));
        if (form == .nodes) return reply_contract.writeTrailer(w, "lines {d}-{d}{s}", .{ next, self.last, also }, "emetgate_read_symbol", .{ .file = file, .line_start = next, .line_end = self.last, .nodes = true });
        return reply_contract.writeTrailer(w, "lines {d}-{d}{s}", .{ next, self.last, also }, "emetgate_read_file", .{ .file = file, .line_start = next, .line_end = self.last });
    }
};

fn requireSymbols(gpa: Allocator, table: symbol.Table, file: []const u8, refs: []const []const u8) !void {
    var names_buf: [400]u8 = undefined;
    var names: std.Io.Writer = .fixed(&names_buf);
    var missing: usize = 0;
    for (refs) |sym| {
        const ref = symbol.Ref.parse(gpa, sym) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        defer ref.deinit(gpa);
        _ = table.item(ref) catch |err| switch (err) {
            error.SymbolNotFound => {
                names.print("{s}{s}", .{ if (missing == 0) "" else ", ", utf8Head(sym, 120) }) catch {};
                missing += 1;
            },
            else => {},
        };
    }
    if (missing == 0) return;
    wire.setFix("{s} has no symbol {s}; call {s}emetgate_symbols with this file for the exact symbol refs", .{ utf8Head(file, 200), names.buffered(), tool_names.prefix() });
    return error.SymbolNotFound;
}

/// Approximate reply size of one entry of a symbols or range reply.
fn entryCost(ref: []const u8, text: ?[]const u8) usize {
    return 200 + 2 * ref.len + if (text) |t| reply_contract.encodedLen(t, .json) else 0;
}

fn utf8Head(text: []const u8, limit: usize) []const u8 {
    return read_tools.utf8Prefix(text, limit);
}

fn renderSymbolBodies(gpa: Allocator, io: std.Io, runtime: *Runtime, root: ?[]const u8, file: []const u8, symbols: []const Value, force: bool, nodes: bool, reading: Reading, mirror: ?*mirror_mod.Mirror, tree_cache: ?*tree_cache_mod.TreeCache, w: *Writer, event: *telemetry.Event) !void {
    if (symbols.len == 0) return tool_result.missing("symbols (non-empty array of symbol refs)", .{});
    const loaded = try loadJailed(gpa, io, runtime, root, file, tree_cache);
    defer loaded.deinit(gpa);
    const snapshot = loaded.snapshot;
    const table = try snapshot.symbols();
    const entries = try gpa.alloc(wire.SymbolEntry, symbols.len);
    defer gpa.free(entries);
    const refs = try gpa.alloc([]const u8, symbols.len);
    defer gpa.free(refs);
    for (symbols, 0..) |item, i| refs[i] = switch (item) {
        .string => |s| s,
        else => return tool_result.missing("symbols[{d}] (string)", .{i}),
    };
    try requireSymbols(gpa, table.*, file, refs);
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |t| gpa.free(t);
        owned.deinit(gpa);
    }
    var views: usize = 0;
    defer for (entries[0..views]) |entry| if (entry.folded) |folded| folded.view.deinit(gpa);
    var lines: ?read_budget.Lines = null;
    defer if (lines) |l| l.deinit(gpa);
    var folded_docs: std.ArrayList(doc_fold.Folded) = .empty;
    defer {
        for (folded_docs.items) |d| d.deinit(gpa);
        folded_docs.deinit(gpa);
    }
    const room = reply_contract.room(.read_symbol);
    var used: usize = 0;
    var chars: usize = 0;
    var shown_count: usize = symbols.len;
    var first_cut: ?LinesCut = null;
    var cut_form: LinesCut.Form = .source;
    const covered = try read_cache.coversWhole(gpa, mirror, file, symbol.fileHash(snapshot.source), force);
    for (refs, 0..) |sym, i| {
        const ref = try symbol.Ref.parse(gpa, sym);
        defer ref.deinit(gpa);
        const found = try table.item(ref);
        const shown = shownSpan(found);
        if (nodes) {
            const text = try node_cas_mod.annotateSnapshot(gpa, snapshot, found.span);
            try owned.append(gpa, text);
            const cost = entryCost(sym, text);
            if (used + cost > room and i != 0) {
                shown_count = i;
                break;
            }
            var body: []const u8 = text;
            if (used + cost > room) {
                const cut = LinesCut.of(snapshot.source, text, found.span.start, found.span.end, entryCost(sym, null));
                first_cut = cut;
                cut_form = .nodes;
                body = cut.c.kept;
                shown_count = 1;
            }
            entries[i] = .{ .ref = sym, .hash = found.hash, .body = body, .nodes = true };
            views = i + 1;
            try reading.note(loaded.place.rel).shown(snapshot.source, found.span.start, found.span.end, .dense);
            used += entryCost(sym, body);
            chars += body.len;
            if (first_cut != null) break;
            continue;
        }
        try folded_docs.ensureUnusedCapacity(gpa, 1);
        const docs = try reading.foldDocs(gpa, snapshot, shown.start, shown.end);
        if (docs) |d| folded_docs.appendAssumeCapacity(d);
        const body = if (docs) |d| d.text else snapshot.source[shown.start..shown.end];
        const folds = reading.folds(body.len);
        // Decide whether the entry fits before the mirror records it as sent.
        const cost = if (folds) entryCost(sym, null) + reading.budget + reading.budget / 4 else entryCost(sym, body);
        if (used + cost > room and i != 0) {
            shown_count = i;
            break;
        }
        if (used + cost > room and !folds) {
            const cut = LinesCut.of(snapshot.source, body, shown.start, shown.end, entryCost(sym, null));
            first_cut = cut;
            cut_form = if (docs == null) .source else .folded;
            entries[i] = .{ .ref = sym, .hash = found.hash, .body = cut.c.kept, .docs = if (docs) |d| d.spans else &.{} };
            views = i + 1;
            try reading.note(loaded.place.rel).shown(snapshot.source, shown.start, shown.end, .dense);
            chars += cut.c.kept.len;
            shown_count = 1;
            break;
        }
        var unchanged = covered;
        if (!covered) if (mirror) |m| {
            const key = try mirrorKey(gpa, file, sym, folds or docs != null);
            defer gpa.free(key);
            unchanged = try m.check(key, found.hash, force) == .unchanged;
        };
        entries[i] = .{ .ref = sym, .hash = found.hash, .body = if (unchanged) null else body, .docs = if (docs) |d| d.spans else &.{} };
        views = i + 1;
        if (unchanged) {
            used += entryCost(sym, null);
            continue;
        }
        try reading.note(loaded.place.rel).shown(snapshot.source, shown.start, shown.end, if (folds or docs != null) .dense else .exact);
        if (folds) {
            if (lines == null) lines = try read_budget.Lines.init(gpa, snapshot.source);
            const view = try read_budget.fold(gpa, snapshot.source, lines.?, found.body orelse found.node, reading.budget);
            entries[i].folded = .{ .view = view, .signature = signatureOf(snapshot, found), .budget = reading.budget };
            chars += view.text.len;
            used += entryCost(sym, view.text);
            continue;
        }
        chars += body.len;
        used += cost;
    }
    event.chars_emetgate = chars;
    event.chars_fullfile = snapshot.source.len;
    try wire.writeSymbolBodies(w, file, entries[0..shown_count]);
    const rest = refs[shown_count..];
    var rest_buf: [256]u8 = undefined;
    const rest_text = if (rest.len == 0) "" else std.fmt.bufPrint(&rest_buf, "{d} symbol(s) from {s}", .{ rest.len, utf8Head(rest[0], 120) }) catch "";
    if (first_cut) |cut| {
        var also_buf: [512]u8 = undefined;
        const also = if (rest.len == 0) "" else std.fmt.bufPrint(&also_buf, " of {s}; then {s}", .{ utf8Head(refs[0], 120), rest_text }) catch "";
        return cut.trailer(w, file, cut_form, also);
    }
    if (rest.len != 0) {
        try reply_contract.writeTrailer(w, "{s}", .{rest_text}, "emetgate_read_symbol", .{
            .file = file,
            .symbols = rest,
            .nodes = if (nodes) true else null,
            .detail = if (reading.detail == .full) @as(?[]const u8, "full") else null,
        });
    }
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
        const cut = LinesCut.of(snapshot.source, annotated, region.start, region.end, 0);
        try reading.note(loaded.place.rel).shown(snapshot.source, region.start, region.end, .dense);
        event.chars_emetgate = cut.c.kept.len;
        event.chars_fullfile = snapshot.source.len;
        try wire.writeRangeNodes(w, file, @intCast(start), @intCast(end), cut.c.kept);
        return cut.trailer(w, file, .nodes, "");
    }
    const table = try snapshot.symbols();
    const requested = try line_range.byteRangeForLines(snapshot.source, @intCast(start), @intCast(end));
    const matched = line_range.symbolsOverlapping(gpa, table.*, requested) catch |err| switch (err) {
        error.NoSymbolInRange => return read_tools.renderRange(gpa, file, snapshot.source, start, end, force, mirror, reading.note(loaded.place.rel), w, event),
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
    const room = reply_contract.room(.read_symbol);
    var used: usize = 0;
    var chars: usize = 0;
    var shown_count: usize = matched.len;
    var first_cut: ?LinesCut = null;
    var cut_form: LinesCut.Form = .source;
    var stop_line: i64 = 0;
    for (matched, 0..) |found, i| {
        ref_text[i] = try std.fmt.allocPrint(gpa, "{f}", .{found.ref});
        named = i + 1;
        const start_line = std.mem.count(u8, snapshot.source[0..found.declaration.start], "\n") + 1;
        const end_line = std.mem.count(u8, snapshot.source[0..found.declaration.end], "\n") + 1;
        try folded_docs.ensureUnusedCapacity(gpa, 1);
        const docs = try reading.foldDocs(gpa, snapshot, found.declaration.start, found.declaration.end);
        if (docs) |d| folded_docs.appendAssumeCapacity(d);
        const text = if (docs) |d| d.text else snapshot.source[found.declaration.start..found.declaration.end];
        const folds = reading.folds(text.len);
        var view: ?read_budget.View = null;
        if (folds) {
            if (lines == null) lines = try read_budget.Lines.init(gpa, snapshot.source);
            view = try read_budget.focus(gpa, snapshot.source, lines.?, found.declaration.start, found.declaration.end, @intCast(start), @intCast(end));
        }
        const cost = entryCost(ref_text[i], if (view) |v| v.text else text);
        if (used + cost > room) {
            if (view) |v| v.deinit(gpa);
            if (i != 0) {
                shown_count = i;
                stop_line = @intCast(start_line);
                break;
            }
            const span: symbol.Span = if (folds) .{ .start = @max(found.declaration.start, requested.start), .end = @min(found.declaration.end, requested.end) } else found.declaration;
            const cut = LinesCut.of(snapshot.source, if (folds) snapshot.source[span.start..span.end] else text, span.start, span.end, entryCost(ref_text[i], null));
            first_cut = cut;
            cut_form = if (folds or docs == null) .source else .folded;
            entries[i] = .{ .ref = ref_text[i], .hash = found.hash, .text = cut.c.kept, .start_line = @intCast(cut.first), .end_line = @intCast(end_line), .docs = if (docs != null and !folds) docs.?.spans else &.{} };
            views = i + 1;
            try reading.note(loaded.place.rel).shown(snapshot.source, span.start, span.end, .dense);
            chars += cut.c.kept.len;
            shown_count = 1;
            break;
        }
        var unchanged = whole_read;
        if (!whole_read) if (mirror) |m| {
            const key = try mirrorKey(gpa, file, ref_text[i], folds or docs != null);
            defer gpa.free(key);
            unchanged = try m.check(key, found.hash, force) == .unchanged;
        };
        entries[i] = .{ .ref = ref_text[i], .hash = found.hash, .text = if (unchanged) null else text, .start_line = @intCast(start_line), .end_line = @intCast(end_line), .docs = if (docs) |d| d.spans else &.{} };
        views = i + 1;
        if (unchanged) {
            if (view) |v| v.deinit(gpa);
            used += entryCost(ref_text[i], null);
            continue;
        }
        try reading.note(loaded.place.rel).shown(snapshot.source, found.declaration.start, found.declaration.end, if (folds or docs != null) .dense else .exact);
        if (view) |v| {
            entries[i].folded = .{ .view = v, .signature = firstLineOf(snapshot.source[found.declaration.start..found.declaration.end]), .budget = reading.budget };
            chars += v.text.len;
            used += cost;
            continue;
        }
        chars += text.len;
        used += cost;
    }
    event.chars_emetgate = chars;
    event.chars_fullfile = snapshot.source.len;
    try wire.writeSymbolRange(w, file, @intCast(start), @intCast(end), entries[0..shown_count]);
    if (first_cut) |cut| {
        if (shown_count < matched.len or cut.last < end) {
            var also_buf: [96]u8 = undefined;
            const also = std.fmt.bufPrint(&also_buf, "; the range runs on to line {d}", .{end}) catch "";
            return cut.trailer(w, file, cut_form, also);
        }
        return cut.trailer(w, file, cut_form, "");
    }
    if (shown_count < matched.len) {
        var rest_buf: [256]u8 = undefined;
        const rest = std.fmt.bufPrint(&rest_buf, "{d} of {d}, from line {d}", .{ matched.len - shown_count, matched.len, stop_line }) catch "";
        // A later symbol that starts after the requested start continues the
        // same symbol view; otherwise the raw lines make progress.
        const from = @max(stop_line, start);
        if (from > start) {
            try reply_contract.writeTrailer(w, "the symbols {s}", .{rest}, "emetgate_read_symbol", .{ .file = file, .line_start = from, .line_end = end, .detail = if (reading.detail == .full) @as(?[]const u8, "full") else null });
        } else {
            try reply_contract.writeTrailer(w, "the symbols {s}", .{rest}, "emetgate_read_file", .{ .file = file, .line_start = from, .line_end = end });
        }
    }
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
        const target = try (try base.symbols()).item(ref);
        const shown = shownSpan(target);
        event.chars_sr = shown.end - shown.start + body.len;
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
        .test_scoped_cmd = policy.test_scoped_command,
        .typecheck_command = typecheck_command,
        .allow_repo_memory = policy.allow_repo_memory,
        .guard_config = policy.open_run,
        .shadow_root = policy.shadow_root,
        .gate_tree = policy.treeChoice(),
        .trace = &event.trace,
        .commit = if (commit) |*request| request else null,
    });
    defer result.deinit(gpa);
    defer runner.releaseTrace(gpa, &event.trace);
    const ran_test = runner.ranTestCommand(event.trace, test_command);
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
                .test_command = ran_test,
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
            try wire.writeRejected(gpa, w, ran_test, report, note);
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
    return commitReply(gpa, io, runtime, try requireString(args, "message"), policy, event, false);
}

fn commitReply(gpa: Allocator, io: std.Io, runtime: *Runtime, message: []const u8, policy: Policy, event: *telemetry.Event, outside: bool) !ToolResult {
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    const is_error = commitInto(gpa, io, runtime, message, policy, &buffer.writer, event, outside) catch |err| blk: {
        if (err == error.OutOfMemory) return err;
        event.fail(@errorName(err));
        buffer.clearRetainingCapacity();
        if (err == error.TargetHasUncommittedChanges) stagedFix();
        try wire.writeFailure(&buffer.writer, err, &event.trace.blocked);
        break :blk true;
    };
    return .{ .text = try dupTrim(gpa, buffer.written()), .is_error = is_error };
}

fn stagedFix() void {
    const prefix = tool_names.prefix();
    const named = commit_refusal.peek() orelse return wire.setFix("the git index holds staged changes no emetgate write made on a file this commit carries; see them with {s}emetgate_git sub \"status\", unstage each with {s}emetgate_git_write args [\"restore\",\"--staged\",\"--\",\"<path>\"] (the file on disk stays), then commit again with {s}emetgate_change", .{ prefix, prefix, prefix });
    var paths = named.paths();
    const path = paths.next() orelse "";
    wire.setFix("the git index holds a staged copy of {s} that no emetgate write made; run {s}emetgate_git_write with args [\"restore\",\"--staged\",\"--\",\"{s}\"] (the file on disk stays as it is), then commit again with {s}emetgate_change", .{ path, prefix, path, prefix });
}

fn commitInto(gpa: Allocator, io: std.Io, runtime: *Runtime, message: []const u8, policy: Policy, w: *Writer, event: *telemetry.Event, outside: bool) !bool {
    try commit_message.check(message);
    const root = try repo.servedRoot(gpa, io, policy.root);
    defer gpa.free(root);
    const result = try commit_group.commit(gpa, io, root, .{
        .message = message,
        .shadow_root = policy.shadow_root,
        .gate_tree = policy.treeChoice(),
        .runtime = runtime,
        .guard_config = policy.open_run,
        .tests = .{ .given = policy.test_command orelse if (policy.detect_test) test_command_mod.detect else "", .typecheck = policy.typecheck_command orelse "", .allow_repo_config = policy.allow_repo_config },
        .outside = outside,
        .allow_repo_memory = policy.allow_repo_memory,
    });
    defer result.deinit(gpa);
    return writeCommitResult(gpa, io, root, result, w, event);
}

fn commitAdmission(gpa: Allocator, io: std.Io, message: []const u8, policy: Policy, event: *telemetry.Event) !?ToolResult {
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    const refused = admissionInto(gpa, io, message, policy, &buffer.writer, event) catch |err| blk: {
        if (err == error.OutOfMemory) return err;
        event.fail(@errorName(err));
        buffer.clearRetainingCapacity();
        try wire.writeFailure(&buffer.writer, err, &event.trace.blocked);
        break :blk true;
    };
    if (!refused) return null;
    return .{ .text = try dupTrim(gpa, buffer.written()), .is_error = true };
}

fn admissionInto(gpa: Allocator, io: std.Io, message: []const u8, policy: Policy, w: *Writer, event: *telemetry.Event) !bool {
    try commit_message.check(message);
    const root = try repo.servedRoot(gpa, io, policy.root);
    defer gpa.free(root);
    const result = (try commit_group.admit(gpa, io, root, message)) orelse return false;
    defer result.deinit(gpa);
    return writeCommitResult(gpa, io, root, result, w, event);
}

fn writeCommitResult(gpa: Allocator, io: std.Io, root: []const u8, result: commit_group.Result, w: *Writer, event: *telemetry.Event) !bool {
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
            if (try commitShortstat(gpa, io, root, c.base, c.oid)) |stat| {
                defer gpa.free(stat);
                try js.objectField("shortstat");
                try js.write(stat);
            }
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
        .tests_failing => |failing| {
            event.outcome = .rejected;
            event.reason = "tests_failing";
            try js.beginObject();
            try js.objectField("status");
            try js.write("error");
            try js.objectField("error");
            try js.write("TestsFailing");
            try js.objectField("failing");
            try js.write(failing.names);
            try js.objectField("total");
            try js.write(failing.total);
            try js.objectField("fix");
            try tool_names.writeJson(&js, commit_tests_fix);
            try js.endObject();
            return true;
        },
    }
}

pub const commit_tests_fix = "these tests passed or did not exist when this session started and fail now; make them pass with emetgate_change, then commit again with emetgate_change";

fn commitShortstat(gpa: Allocator, io: std.Io, root: []const u8, base: []const u8, oid: []const u8) !?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const out = receipts.git(arena_state.allocator(), io, root, &.{ "diff", "--shortstat", base, oid }) catch return null;
    const text = std.mem.trim(u8, out orelse return null, " \r\n");
    if (text.len == 0) return null;
    return try gpa.dupe(u8, text);
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
        .guard_config = policy.open_run,
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

pub const change_description = "Applies one change in a single gated call. edits are {file, old_string, new_string} (old_string copied exactly and unique, replace_all for every match) or {file, content} for a new file or for a file this session wrote or a run reported, while it is unchanged ({file, hash, content} with its file_hash overwrites any other existing file); they are written together only if typecheck passes and no test fails that did not fail before, else none is. branch creates that branch and switches to it before the edits; commit then stages every change in the work tree and commits it with that message. Give branch or commit only when the user asks for them. After a branch or commit, after names the branch checked out and whether the work tree is clean.";

pub const change_missing = "edits, commit or branch";

fn callChange(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, policy: Policy) !ToolResult {
    const arguments = args orelse return tool_result.missing(change_missing, .{});
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const edits: ?Value = if (getField(arguments, "edits")) |given| switch (given) {
        .array => |list| try withoutNoOps(arena, list),
        else => return tool_result.missing("edits (array of {{file, old_string, new_string}} or {{file, content}})", .{}),
    } else null;
    const message = getString(arguments, "commit");
    const branch = getString(arguments, "branch");
    if (edits == null and message == null and branch == null) return tool_result.missing(change_missing, .{});
    event.label = "change";
    var out: std.Io.Writer.Allocating = .init(arena);
    var js: std.json.Stringify = .{ .writer = &out.writer };
    try js.beginObject();
    var failed: ?[]const u8 = null;
    var made_branch = false;
    var before: ?HeadBefore = null;
    const committed_with_edits = policy.commit and edits != null;
    const separate: ?[]const u8 = if (committed_with_edits) null else message;
    if (separate) |text| if (try commitAdmission(gpa, io, text, policy, event)) |refused| {
        defer gpa.free(refused.text);
        try changeStep(arena, &js, "commit", refused.text);
        failed = "commit";
        if (edits != null) {
            try js.objectField("on_disk");
            try js.write(edits_not_written);
        }
    };
    if (failed == null) if (branch) |name| {
        before = try headBefore(arena, io, policy.root);
        const reply = try git_write.callGitWrite(gpa, io, try gitArgs(arena, &.{ "switch", "-c", name }), event, policy.root, policy.open_run);
        defer gpa.free(reply.text);
        try changeStep(arena, &js, "branch", reply.text);
        if (reply.is_error) failed = "branch" else made_branch = true;
        if (reply.is_error) {
            try js.objectField("fix");
            try js.write(try std.fmt.allocPrint(arena, "the branch was not created (see branch); if {s} already exists, switch to it with emetgate_git_write args [\"switch\", \"{s}\"] and resend without branch, or pick another name", .{ name, name }));
        }
    };
    var edits_written = false;
    var undo: ?change_undo.Snapshot = null;
    if (failed == null) if (edits) |list| {
        const root = policy.root orelse ".";
        if (separate != null) undo = try change_undo.take(arena, io, try repo.servedRoot(arena, io, policy.root), try editedFiles(arena, list));
        var batch: std.json.ObjectMap = .empty;
        try batch.put(arena, "edits", if (policy.known_files) |known| try withKnownHashes(arena, io, root, list, known) else list);
        if (policy.commit) if (getString(arguments, "message") orelse message) |text| try batch.put(arena, "message", .{ .string = text });
        const forgiven = try forgive.normalize(arena, "emetgate_try_batch", .{ .object = batch });
        const reply = try callTryBatch(gpa, io, runtime, forgiven.args, event, policy);
        defer gpa.free(reply.text);
        try changeStep(arena, &js, "edits", reply.text);
        if (reply.is_error) failed = "edits";
        edits_written = !reply.is_error;
        if (!reply.is_error) try writeParseCheck(arena, io, runtime, root, &js, list);
        if (!reply.is_error) if (policy.known_files) |known| try noteWritten(arena, io, root, list, known);
        if (!reply.is_error) if (policy.map_session) |session| try writeUnreached(arena, io, &js, session, root, list);
        if (reply.is_error and made_branch) try undoBranch(arena, io, &js, policy.root, branch.?, before);
    };
    if (failed == null) if (separate) |text| {
        const made = try commitReply(gpa, io, runtime, text, policy, event, true);
        defer gpa.free(made.text);
        try changeStep(arena, &js, "commit", made.text);
        if (made.is_error) failed = "commit";
        if (made.is_error and edits_written) {
            try js.objectField("on_disk");
            if (undo) |snapshot| {
                if (change_undo.restore(gpa, arena, io, snapshot)) |unrestored| {
                    if (unrestored.len == 0) try js.write(edits_undone) else try js.write(try std.fmt.allocPrint(arena, "{s}, except the git index: {s} held merge conflict stages, which cannot be put back, and now holds the restored file instead", .{ edits_undone, try std.mem.join(arena, ", ", unrestored) }));
                } else |err| {
                    try js.write(try std.fmt.allocPrint(arena, "the edits are written to the work tree; the commit was refused and undoing the edits failed ({s}), so they are on disk but not committed", .{@errorName(err)}));
                    event.disk = "edits written, commit refused";
                }
            } else {
                try js.write("the edits are written to the work tree; the commit was refused, so they are not committed");
                event.disk = "edits written, commit refused";
            }
        }
        if (made.is_error and made_branch and event.disk == null) try undoBranch(arena, io, &js, policy.root, branch.?, before);
    };
    if (branch != null or message != null) try writeAfter(gpa, io, &js, policy);
    try js.objectField("status");
    try js.write(if (failed == null) "applied" else "stopped");
    if (failed) |step| {
        try js.objectField("stopped_at");
        try js.write(step);
    }
    try js.endObject();
    return .{ .text = try dupTrim(gpa, out.written()), .is_error = failed != null };
}

const edits_not_written = "the commit was refused before any edit was written, so the edits were not kept: the work tree is as it was before the call";
const edits_undone = "the commit was refused, so the edits were not kept: every file this call wrote is back as it was before the call";

fn editedFiles(arena: Allocator, list: Value) ![]const []const u8 {
    var files: std.ArrayList([]const u8) = .empty;
    for (list.array.items) |item| {
        try files.append(arena, getString(item, "file") orelse continue);
    }
    return files.items;
}

const HeadBefore = struct {
    /// The branch checked out before the call, or null when HEAD was detached.
    branch: ?[]const u8,
    oid: []const u8,
};

fn headBefore(arena: Allocator, io: std.Io, served: ?[]const u8) !?HeadBefore {
    const root = try repo.servedRoot(arena, io, served);
    const git = git_commit.Git.init(arena, io, root) catch return null;
    const oid = (git.run(&.{ "rev-parse", "--verify", "-q", "HEAD" }) catch return null) orelse return null;
    const ref = git.run(&.{ "symbolic-ref", "-q", "--short", "HEAD" }) catch null;
    return .{ .branch = ref, .oid = oid };
}

/// The edits of a call that created its branch were refused: switch back to where HEAD was
/// and delete the branch, but only while it still points at that commit (no commits of its
/// own), so the same call can be sent again.
fn undoBranch(arena: Allocator, io: std.Io, js: *std.json.Stringify, served: ?[]const u8, name: []const u8, before: ?HeadBefore) !void {
    try js.objectField("branch_undone");
    const was = before orelse return js.write("no: HEAD had no commit before the call, so the branch is left checked out");
    const root = try repo.servedRoot(arena, io, served);
    const git = git_commit.Git.init(arena, io, root) catch return js.write("no: git could not be started; the branch is left checked out");
    const full = try std.fmt.allocPrint(arena, "refs/heads/{s}", .{name});
    const tip = (git.run(&.{ "rev-parse", "--verify", "-q", full }) catch null) orelse return js.write("no: the branch is not found; nothing to undo");
    if (!std.mem.eql(u8, tip, was.oid)) return js.write("no: the branch has commits of its own, so it is kept");
    const back = if (was.branch) |b| try arena.dupe([]const u8, &.{ "switch", "-q", b }) else try arena.dupe([]const u8, &.{ "switch", "-q", "--detach", was.oid });
    if ((git.run(back) catch null) == null) return js.write("no: switching back failed; the branch is left checked out");
    const where = was.branch orelse was.oid;
    if ((git.run(&.{ "branch", "-q", "-d", name }) catch null) == null) {
        return js.write(try std.fmt.allocPrint(arena, "partly: back on {s}, but deleting {s} failed, so it still exists", .{ where, name }));
    }
    try js.write(try std.fmt.allocPrint(arena, "yes: back on {s}, and {s} is deleted; the same call can be sent again", .{ where, name }));
}

/// Says which written source files the language's own check verified after the reparse.
/// A language without a check is named, never reported as verified.
fn writeParseCheck(arena: Allocator, io: std.Io, runtime: *Runtime, root: []const u8, js: *std.json.Stringify, list: Value) !void {
    var verified: std.ArrayList(u8) = .empty;
    var broken: std.ArrayList(u8) = .empty;
    var unverified: std.ArrayList(u8) = .empty;
    for (list.array.items) |item| {
        const file = getString(item, "file") orelse continue;
        const profile = lang_registry.forPath(file) orelse continue;
        const into = if (profile.source_check != null)
            &verified
        else if (profile.grammar_verifies)
            (if (try parsesClean(arena, io, runtime, root, file, profile) orelse continue) &verified else &broken)
        else
            &unverified;
        if (into.items.len != 0) try into.appendSlice(arena, ", ");
        try into.appendSlice(arena, file);
        if (into != &verified) try into.print(arena, " ({s})", .{profile.name});
    }
    if (verified.items.len == 0 and broken.items.len == 0 and unverified.items.len == 0) return;
    try js.objectField("parse");
    if (broken.items.len == 0 and unverified.items.len == 0) return js.write("verified: the language check passed after the reparse");
    var text: std.ArrayList(u8) = .empty;
    if (verified.items.len != 0) try text.print(arena, "verified for {s}", .{verified.items});
    if (broken.items.len != 0) {
        if (text.items.len != 0) try text.appendSlice(arena, "; ");
        try text.print(arena, "not verified for {s}: the tree-sitter parse has ERROR or MISSING nodes", .{broken.items});
    }
    if (unverified.items.len != 0) {
        if (text.items.len != 0) try text.appendSlice(arena, "; ");
        try text.print(arena, "not verified for {s}: tree-sitter only, no language check", .{unverified.items});
    }
    try js.write(text.items);
}

fn parsesClean(arena: Allocator, io: std.Io, runtime: *Runtime, root: []const u8, file: []const u8, profile: *const Profile) !?bool {
    const abs = try std.fs.path.resolve(arena, &.{ root, file });
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, abs, arena, .limited(max_known_bytes)) catch return null;
    const tree = runtime.parser.parseIn(profile.grammar(), bytes) catch return false;
    defer tree.deinit();
    return !tree.root().hasError();
}

pub const unreached_shown: usize = 8;

/// Names the changed functions that no test reaches, so a passing gate never hides
/// code the tests did not exercise. Skipped silently while the fact store is building.
fn writeUnreached(arena: Allocator, io: std.Io, js: *std.json.Stringify, session: *map_tools.Session, root: []const u8, list: Value) !void {
    var edited: std.ArrayList(map_tools.Edited) = .empty;
    for (list.array.items) |item| {
        if (item != .object) continue;
        const file = getString(item, "file") orelse continue;
        const abs = try std.fs.path.resolve(arena, &.{ root, file });
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, abs, arena, .limited(max_known_bytes)) catch continue;
        const span = writtenSpan(bytes, item) orelse continue;
        try edited.append(arena, .{ .path = try storePath(arena, root, abs), .start = span.start, .end = span.end });
    }
    if (edited.items.len == 0) return;
    const found = (session.untested(arena, edited.items) catch return) orelse return;
    if (found.len == 0) return;
    try js.objectField("no_test_reaches");
    try js.beginArray();
    for (found[0..@min(found.len, unreached_shown)]) |u| {
        try js.write(try std.fmt.allocPrint(arena, "{s} ({s}:{d})", .{ u.qname, u.path, u.line }));
    }
    if (found.len > unreached_shown) try js.write(try std.fmt.allocPrint(arena, "and {d} more", .{found.len - unreached_shown}));
    try js.endArray();
}

pub const Span = struct { start: u32, end: u32 };

/// Where an edit's new text sits in the file as written; a whole-file write spans the file.
pub fn writtenSpan(bytes: []const u8, item: Value) ?Span {
    if (getString(item, "new_string")) |text| {
        if (text.len == 0) return null;
        const at = std.mem.indexOf(u8, bytes, text) orelse return null;
        return .{ .start = @intCast(at), .end = @intCast(at + text.len) };
    }
    if (getString(item, "content") != null) return .{ .start = 0, .end = @intCast(bytes.len) };
    return null;
}

/// A path as the fact store keys it: relative to the root, '/' separated.
pub fn storePath(arena: Allocator, root: []const u8, abs: []const u8) ![]const u8 {
    const root_abs = try std.fs.path.resolve(arena, &.{root});
    var rel = abs;
    if (abs.len > root_abs.len and std.ascii.startsWithIgnoreCase(abs, root_abs)) {
        rel = abs[root_abs.len..];
        while (rel.len > 0 and (rel[0] == '\\' or rel[0] == '/')) rel = rel[1..];
    }
    const out = try arena.dupe(u8, rel);
    std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
}

fn withKnownHashes(arena: Allocator, io: std.Io, root: []const u8, list: Value, known: *known_files.KnownFiles) !Value {
    var out = std.json.Array.init(arena);
    for (list.array.items) |item| {
        try out.append(try withKnownHash(arena, io, root, item, known));
    }
    return .{ .array = out };
}

fn withKnownHash(arena: Allocator, io: std.Io, root: []const u8, item: Value, known: *known_files.KnownFiles) !Value {
    if (item != .object or getField(item, "hash") != null or getString(item, "content") == null) return item;
    const file = getString(item, "file") orelse return item;
    const abs = try std.fs.path.resolve(arena, &.{ root, file });
    const known_hash = known.get(abs) orelse return item;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, abs, arena, .limited(max_known_bytes)) catch return item;
    if (!std.mem.eql(u8, &symbol.fileHash(bytes), &known_hash)) return item;
    var copy = try item.object.clone(arena);
    const hex = symbol.formatHash(known_hash);
    try copy.put(arena, "hash", .{ .string = try arena.dupe(u8, &hex) });
    return .{ .object = copy };
}

fn noteWritten(arena: Allocator, io: std.Io, root: []const u8, list: Value, known: *known_files.KnownFiles) !void {
    for (list.array.items) |item| {
        const file = getString(item, "file") orelse continue;
        const abs = try std.fs.path.resolve(arena, &.{ root, file });
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, abs, arena, .limited(max_known_bytes)) catch continue;
        try known.note(abs, symbol.fileHash(bytes));
    }
}

const max_known_bytes = 64 << 20;

fn withoutNoOps(arena: Allocator, list: std.json.Array) !?Value {
    var kept = std.json.Array.init(arena);
    for (list.items) |item| {
        const old = getString(item, "old_string");
        const new = getString(item, "new_string");
        if (old != null and new != null and old.?.len != 0 and std.mem.eql(u8, old.?, new.?)) continue;
        try kept.append(item);
    }
    return if (kept.items.len == 0) null else .{ .array = kept };
}

fn gatedGitCommit(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, policy: Policy) !?ToolResult {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const plain = (try git_write.plainCommit(arena_state.allocator(), args)) orelse return null;
    const root = try repo.servedRoot(gpa, io, policy.root);
    defer gpa.free(root);
    const ready = git_commit.readyToCommit(gpa, io, root, plain.all) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    if (!ready) return null;
    event.label = "git_write";
    const made = try commitReply(gpa, io, runtime, plain.message, policy, event, true);
    if (made.is_error) return made;
    defer gpa.free(made.text);
    return .{ .text = try asGitWrite(gpa, io, arena_state.allocator(), made.text, root), .is_error = false };
}

fn asGitWrite(gpa: Allocator, io: std.Io, arena: Allocator, text: []const u8, root: []const u8) ![]u8 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const reply = std.json.parseFromSliceLeaky(Value, arena, text[0..end], .{}) catch return gpa.dupe(u8, text);
    if (reply != .object) return gpa.dupe(u8, text);
    var out: std.Io.Writer.Allocating = .init(arena);
    var js: std.json.Stringify = .{ .writer = &out.writer };
    try js.beginObject();
    try js.objectField("status");
    try js.write("ok");
    if (reply.object.get("commit")) |commit| {
        try js.objectField("head");
        try js.write(commit);
    }
    if (git_commit.headState(gpa, io, root)) |state| {
        defer state.deinit(gpa);
        if (state.branch) |name| {
            try js.objectField("branch");
            try js.write(name);
        }
        try js.objectField("clean");
        try js.write(state.clean);
    } else |err| if (err == error.OutOfMemory) return err;
    inline for (.{ "shortstat", "files", "receipts" }) |field| if (reply.object.get(field)) |value| {
        try js.objectField(field);
        try js.write(value);
    };
    try js.endObject();
    return gpa.dupe(u8, out.written());
}

fn writeAfter(gpa: Allocator, io: std.Io, js: *std.json.Stringify, policy: Policy) !void {
    const root = try repo.servedRoot(gpa, io, policy.root);
    defer gpa.free(root);
    const state = git_commit.headState(gpa, io, root) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    defer state.deinit(gpa);
    try js.objectField("after");
    try js.beginObject();
    if (state.branch) |name| {
        try js.objectField("branch");
        try js.write(name);
    }
    try js.objectField("clean");
    try js.write(state.clean);
    try js.endObject();
}

fn gitArgs(arena: Allocator, words: []const []const u8) !Value {
    var list = std.json.Array.init(arena);
    for (words) |word| try list.append(.{ .string = word });
    var object: std.json.ObjectMap = .empty;
    try object.put(arena, "args", .{ .array = list });
    return .{ .object = object };
}

fn changeStep(arena: Allocator, js: *std.json.Stringify, field: []const u8, text: []const u8) !void {
    try js.objectField(field);
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    var value = std.json.parseFromSliceLeaky(Value, arena, text[0..end], .{}) catch return js.write(text);
    if (value == .object) {
        if (value.object.getPtr("status")) |status| {
            if (status.* == .string and std.mem.eql(u8, status.string, wire.committed_status)) status.* = .{ .string = "applied" };
        }
        if (end < text.len) try value.object.put(arena, "note", .{ .string = std.mem.trim(u8, text[end..], " \t\r\n") });
    }
    try js.write(value);
}

fn callTryBatch(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, policy: Policy) !ToolResult {
    fuzzy_match.reset();
    const reply = try tryBatchReply(gpa, io, runtime, args, event, policy);
    if (!fuzzy_match.wasUsed()) return reply;
    defer gpa.free(reply.text);
    return .{ .text = try fuzzy_match.annotate(gpa, reply.text), .is_error = reply.is_error };
}

fn tryBatchReply(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, policy: Policy) !ToolResult {
    const arguments = args orelse return tool_result.missing(edits_missing, .{});
    const retry = getString(arguments, "retry");
    const given: []const Value = if (getField(arguments, "edits")) |edits_val| switch (edits_val) {
        .array => |list| list.items,
        else => return tool_result.missing(edits_missing, .{}),
    } else &.{};
    if (given.len == 0 and retry == null) return tool_result.missing(edits_missing, .{});
    var merge_state = std.heap.ArenaAllocator.init(gpa);
    defer merge_state.deinit();
    const now = batch_stage.clock(io);
    const items: []const Value = if (retry) |id| merged: {
        const store = policy.batch_stage orelse return batchFailure(gpa, event, error.StagedBatchUnknown);
        break :merged store.merge(merge_state.allocator(), io, policy.root, id, given, now) catch |err| switch (err) {
            error.StagedBatchUnknown, error.StagedBatchStale => return batchFailure(gpa, event, err),
            else => |e| return e,
        };
    } else given;
    for (items, 0..) |item, i| {
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
    const is_error = batchInto(gpa, io, runtime, items, given, arguments, policy, &buffer.writer, event) catch |err| blk: {
        if (err == error.OutOfMemory) return err;
        event.fail(@errorName(err));
        recovery.afterBatch(gpa, io, runtime, policy.root, items, err);
        buffer.clearRetainingCapacity();
        if (err == error.WrittenButNotIndexed) {
            try wire.writeNotIndexed(&buffer.writer, firstAbsentFile(items));
        } else {
            try wire.writeFailure(&buffer.writer, err, &event.trace.blocked);
        }
        break :blk true;
    };
    const store = policy.batch_stage orelse return .{ .text = try dupTrim(gpa, buffer.written()), .is_error = is_error };
    if (!is_error or event.trace.commit_attempted) {
        if (retry) |id| store.remove(id);
        return .{ .text = try dupTrim(gpa, buffer.written()), .is_error = is_error };
    }
    const kept = try store.stage(io, policy.root, items, retry, now);
    const text = try batch_stage.withRetry(gpa, buffer.written(), kept);
    defer gpa.free(text);
    return .{ .text = try dupTrim(gpa, text), .is_error = true };
}

fn batchFailure(gpa: Allocator, event: *telemetry.Event, err: anyerror) !ToolResult {
    event.fail(@errorName(err));
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    try wire.writeError(&buffer.writer, @errorName(err), wire.exitCode(err));
    return .{ .text = try dupTrim(gpa, buffer.written()), .is_error = true };
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

fn earlierText(items: []const Value, places: []const repo.Jailed, abs: []const u8) ?usize {
    for (items, places, 0..) |item, place, j| {
        if ((itemKind(item) catch continue) != .text) continue;
        if (std.ascii.eqlIgnoreCase(place.abs, abs)) return j;
    }
    return null;
}

fn mergeSameFile(arena: Allocator, io: std.Io, items: []const Value, places: []const repo.Jailed, order: []const usize, edits: []runner.Edit) !void {
    for (edits, 0..) |*edit, slot| {
        if (edit.text == null) continue;
        var parts: std.ArrayList(batch_merge.Part) = .empty;
        for (items, 0..) |item, i| {
            if ((try itemKind(item)) != .text or order[i] != slot) continue;
            try parts.append(arena, .{ .index = i, .expected = try itemExpected(item), .text = try itemText(item, i) });
        }
        if (parts.items.len < 2) continue;
        const first = parts.items[0].index;
        const base = try file_edit.readBase(arena, io, places[first].abs, lang_registry.forPath(edit.file_abs) != null);
        const merged = try batch_merge.merge(arena, base, getString(items[first], "file").?, parts.items);
        edit.text = .{ .whole = merged.content };
        edit.expected_hash = merged.expected;
    }
}

fn firstAbsentFile(items: []const Value) []const u8 {
    for (items) |item| {
        if (node_tool.isNodeForm(item)) continue;
        const expected = symbol.parseExpected(getString(item, "hash") orelse continue) catch continue;
        if (expected == .absent) return getString(item, "file").?;
    }
    return getString(items[0], "file").?;
}

fn sentNow(given: []const Value, item: Value) bool {
    for (given) |fresh| {
        if (fresh == .object and item == .object and fresh.object.keys().ptr == item.object.keys().ptr) return true;
    }
    return false;
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

fn batchInto(gpa: Allocator, io: std.Io, runtime: *Runtime, items: []const Value, sent_items: []const Value, args: Value, policy: Policy, w: *Writer, event: *telemetry.Event) !bool {
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
                if (earlierText(items[0..i], places[0..i], places[i].abs)) |first| {
                    order[i] = order[first];
                    continue;
                }
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

    const code_used = ci;
    for (items, 0..) |item, i| {
        if (try itemKind(item) == .doc) order[i] = code_used + (order[i] - code_count);
    }
    var merge_arena_state = std.heap.ArenaAllocator.init(gpa);
    defer merge_arena_state.deinit();
    try mergeSameFile(merge_arena_state.allocator(), io, items, places, order, edits[0..code_used]);

    const anchor = file_edit.existingAncestor(io, places[0].abs) orelse return error.InvalidPath;
    const in_place = std.mem.eql(u8, anchor, std.fs.path.dirname(places[0].abs) orelse anchor);
    const probe = if (in_place) try gpa.dupe(u8, places[0].abs) else try std.fmt.allocPrint(gpa, "{s}\\_", .{anchor});
    defer gpa.free(probe);
    const resolved = try runner.resolveTestCommand(gpa, io, probe, given, policy.allow_repo_config);
    defer gpa.free(resolved);
    const typecheck_command = try runner.resolveTypecheckCommand(gpa, io, probe, trustedTypecheckCommand(policy), policy.allow_repo_config);
    defer if (typecheck_command) |command| gpa.free(command);
    const before_hashes = try gpa.alloc(?symbol.Hash, code_used);
    defer gpa.free(before_hashes);
    for (edits[0..code_used], before_hashes) |edit, *slot| slot.* = disk.hashFile(gpa, io, edit.file_abs) catch null;
    const options: batch_mod.BatchOptions = .{ .edits = edits[0..code_used], .doc_edits = doc_edits, .test_command = resolved, .test_scoped_cmd = policy.test_scoped_command, .typecheck_command = typecheck_command, .allow_repo_memory = policy.allow_repo_memory, .guard_config = policy.open_run, .shadow_root = policy.shadow_root, .gate_tree = policy.treeChoice(), .trace = &event.trace, .language_service = policy.language_service, .commit = if (commit) |*request| request else null, .created_dirs = @ptrCast(new_dirs.items) };
    var planned = try batch_mod.planBatch(gpa, io, runtime, options);
    defer planned.deinit(gpa);
    const result = try batch_mod.commitPlanned(gpa, io, planned.root, planned.prepared.items, edits[0..code_used], options);
    defer result.deinit(gpa);
    defer runner.releaseTrace(gpa, &event.trace);
    const gated = event.trace.scoped_command orelse test_command_mod.takeLate() orelse resolved;
    const note_root = try shadow_root.displayRoot(gpa, policy.shadow_root);
    defer gpa.free(note_root);
    const note = wire.shadowNote(note_root, event.trace);

    var sent: usize = 0;
    for (items, node_lists) |item, list| {
        if (!sentNow(sent_items, item)) continue;
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
            if (policy.tree_cache) |cache| for (edits[0..code_used]) |edit| cache.invalidate(edit.file_abs);
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
                        .old_hash = .{ .present = doc_expected[slot - code_used] },
                        .new_hash = committed[slot].hash,
                        .evidence = null,
                        .deleted = false,
                    },
                };
            }
            try wire.writeBatchCommitted(w, views, note, full);
            const code_places = try gpa.alloc(repo.Jailed, code_used);
            defer gpa.free(code_places);
            const code_committed = try gpa.alloc(@import("../platform/batch.zig").Committed, code_used);
            defer gpa.free(code_committed);
            for (items, 0..) |item, i| {
                if (itemKind(item) catch unreachable == .doc) continue;
                code_places[order[i]] = places[i];
                code_committed[order[i]] = committed[order[i]];
            }
            try recordBatch(gpa, io, places[0].root, code_places, edits[0..code_used], planned.prepared.items, before_hashes, code_committed, gated, typecheck_command, event.trace.test_ms, w, full, if (commit) |*made| made else null);
            try receipt_note.commit(gpa, io, places[0].root, commit, w);
            return false;
        },
        .rejected => |report| {
            event.outcome = .rejected;
            event.reason = wire.rejectionReason(report);
            try wire.writeRejected(gpa, w, gated, report, note);
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
