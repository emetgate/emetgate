const std = @import("std");
const commit_plan = @import("../platform/commit_plan.zig");
const symbol = @import("../engine/symbol.zig");
const node_cas = @import("../engine/node_cas.zig");
const wire = @import("wire.zig");
const telemetry = @import("telemetry.zig");
const policy_mod = @import("policy.zig");
const tool_result = @import("tool_result.zig");
const runner = @import("../platform/runner.zig");
const batch = @import("../platform/batch.zig");
const repo = @import("../platform/repo.zig");
const disk = @import("../platform/disk.zig");
const shadow_root = @import("../platform/shadow_root.zig");
const receipts = @import("../platform/receipts.zig");
const receipt = @import("../verify/receipt.zig");
const receipt_note = @import("receipt_note.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;
const Policy = policy_mod.Policy;
const ToolResult = tool_result.ToolResult;

pub fn isNodeForm(item: Value) bool {
    return tool_result.getField(item, "node") != null or tool_result.getField(item, "nodes") != null;
}

pub fn parse(gpa: Allocator, item: Value) ![]node_cas.Edit {
    inline for (.{ "symbol", "hash", "body", "op" }) |field| {
        if (tool_result.getField(item, field) != null) return error.MixedEditForms;
    }
    const single = tool_result.getField(item, "node") != null;
    const list = tool_result.getField(item, "nodes");
    if (single and list != null) return error.MixedEditForms;
    if (single) {
        const out = try gpa.alloc(node_cas.Edit, 1);
        errdefer gpa.free(out);
        out[0] = try one(item);
        return out;
    }
    const entries = switch (list orelse return error.MissingArgument) {
        .array => |array| array.items,
        else => return error.MissingArgument,
    };
    if (entries.len == 0) return error.NoNodeEdits;
    if (entries.len > node_cas.max_edits) return error.TooManyNodeEdits;
    const out = try gpa.alloc(node_cas.Edit, entries.len);
    errdefer gpa.free(out);
    for (entries, out) |entry, *slot| slot.* = try one(entry);
    return out;
}

fn one(item: Value) error{MissingArgument}!node_cas.Edit {
    return .{
        .address = tool_result.getString(item, "node") orelse return error.MissingArgument,
        .text = tool_result.getString(item, "text") orelse return error.MissingArgument,
    };
}

pub fn symbolEntries(arena: Allocator, rel: []const u8, applied: node_cas.Applied, out: *std.ArrayList(receipt.SymbolEntry)) !void {
    for (applied.units) |unit| {
        if (unit.ref.len == 0) continue;
        try out.append(arena, .{ .path = rel, .ref = unit.ref, .before = unit.before, .after = unit.after });
    }
}

pub fn sentChars(edits: []const node_cas.Edit) usize {
    var sent: usize = 0;
    for (edits) |edit| sent += edit.address.len + edit.text.len;
    return sent;
}

pub fn callTry(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, policy: Policy) !ToolResult {
    const file = try tool_result.requireString(args, "file");
    event.label = "try_nodes";
    event.file = file;
    event.mutating = true;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    const is_error = tryInto(gpa, io, runtime, file, args.?, policy, &buffer.writer, event) catch |err| blk: {
        if (err == error.OutOfMemory) return err;
        event.fail(@errorName(err));
        buffer.clearRetainingCapacity();
        try wire.writeError(&buffer.writer, @errorName(err), wire.exitCode(err));
        break :blk true;
    };
    return .{ .text = try tool_result.dupTrim(gpa, buffer.written()), .is_error = is_error };
}

fn tryInto(gpa: Allocator, io: std.Io, runtime: *Runtime, file: []const u8, args: Value, policy: Policy, w: *Writer, event: *telemetry.Event) !bool {
    const given = try policy_mod.trustedTestCommand(args, policy);
    var commit = try policy_mod.commitRequest(args, policy, runtime);
    defer if (commit) |request| request.deinit(gpa);
    const node_edits = try parse(gpa, args);
    defer gpa.free(node_edits);
    const place = try repo.jailTarget(gpa, io, policy.root, file, false);
    defer place.deinit(gpa);
    const test_command = try runner.resolveTestCommand(gpa, io, place.abs, given, policy.allow_repo_config);
    defer gpa.free(test_command);
    const typecheck_command = try runner.resolveTypecheckCommand(gpa, io, place.abs, policy_mod.trustedTypecheckCommand(policy), policy.allow_repo_config);
    defer if (typecheck_command) |command| gpa.free(command);
    const before_hash: ?symbol.Hash = disk.hashFile(gpa, io, place.abs) catch null;

    const edit_list = [_]runner.Edit{.{ .file_abs = place.abs, .ref_text = "", .expected_hash = .absent, .nodes = node_edits }};
    const options: batch.BatchOptions = .{
        .edits = &edit_list,
        .test_command = test_command,
        .typecheck_command = typecheck_command,
        .allow_repo_memory = policy.allow_repo_memory,
        .shadow_root = policy.shadow_root,
        .gate_tree = policy.treeChoice(),
        .trace = &event.trace,
        .language_service = policy.language_service,
        .commit = if (commit) |*request| request else null,
    };
    var planned = try batch.planBatch(gpa, io, runtime, options);
    defer planned.deinit(gpa);
    const result = try batch.commitPlanned(gpa, io, planned.root, planned.prepared.items, &edit_list, options);
    defer result.deinit(gpa);
    const applied = planned.prepared.items[0].nodes.?;

    const note_root = try shadow_root.displayRoot(gpa, policy.shadow_root);
    defer gpa.free(note_root);
    const note = wire.shadowNote(note_root, event.trace);
    event.chars_emetgate = sentChars(node_edits);
    event.chars_fullfile = event.trace.new_len;
    switch (result) {
        .committed => {
            event.outcome = .committed;
            event.edits = node_edits.len;
            if (policy.tree_cache) |cache| cache.invalidate(place.abs);
            const full = tool_result.wantsFull(args);
            try wire.writeNodesCommitted(w, file, applied, note, full);
            try record(gpa, io, place.root, place.rel, place.abs, before_hash, applied, test_command, typecheck_command, event.trace.test_ms, w, full, if (commit) |*made| made else null);
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

fn record(gpa: Allocator, io: std.Io, root: []const u8, rel: []const u8, abs: []const u8, before: ?symbol.Hash, applied: node_cas.Applied, test_command: []const u8, typecheck_command: ?[]const u8, test_ms: ?u64, w: *Writer, full: bool, request: ?*commit_plan.Request) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var symbols: std.ArrayList(receipt.SymbolEntry) = .empty;
    try symbolEntries(arena, rel, applied, &symbols);
    try receipt_note.record(gpa, io, root, .{
        .operation = .@"try",
        .class = .spending,
        .evidence = "test",
        .files = &.{.{ .rel = rel, .before = before, .after_abs = abs }},
        .symbols = symbols.items,
        .test_command = test_command,
        .typecheck_command = typecheck_command,
        .test_ms = test_ms,
        .version = receipt_note.version,
    }, w, full, request);
}
