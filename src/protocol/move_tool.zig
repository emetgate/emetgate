const std = @import("std");
const symbol = @import("../engine/symbol.zig");
const wire = @import("wire.zig");
const telemetry = @import("telemetry.zig");
const policy_mod = @import("policy.zig");
const tool_result = @import("tool_result.zig");
const runner = @import("../platform/runner.zig");
const repo = @import("../platform/repo.zig");
const shadow_root = @import("../platform/shadow_root.zig");
const move_batch = @import("../platform/move_batch.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;
const Policy = policy_mod.Policy;
const ToolResult = tool_result.ToolResult;

const Arguments = struct {
    file: []const u8,
    symbol: []const u8,
    hash: []const u8,
    target: []const u8,
    interface_change: bool,
    order_change: bool,
};

pub fn callMove(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, policy: Policy) !ToolResult {
    const arguments: Arguments = .{
        .file = try tool_result.requireString(args, "file"),
        .symbol = try tool_result.requireString(args, "symbol"),
        .hash = try tool_result.requireString(args, "hash"),
        .target = try tool_result.requireString(args, "target_file"),
        .interface_change = tool_result.getBool(args.?, "interface_change") orelse false,
        .order_change = tool_result.getBool(args.?, "order_change") orelse false,
    };
    event.label = "move";
    event.file = arguments.file;
    event.symbol = arguments.symbol;
    event.mutating = true;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    const is_error = moveInto(gpa, io, runtime, arguments, args, policy, &buffer.writer, event) catch |err| blk: {
        if (err == error.OutOfMemory) return err;
        event.fail(@errorName(err));
        buffer.clearRetainingCapacity();
        if (err == error.WrittenButNotIndexed) {
            try wire.writeNotIndexed(&buffer.writer, arguments.target);
        } else {
            try wire.writeError(&buffer.writer, @errorName(err), wire.exitCode(err));
        }
        break :blk true;
    };
    return .{ .text = try tool_result.dupTrim(gpa, buffer.written()), .is_error = is_error };
}

fn moveInto(gpa: Allocator, io: std.Io, runtime: *Runtime, a: Arguments, args: ?Value, policy: Policy, w: *Writer, event: *telemetry.Event) !bool {
    const given = try policy_mod.trustedTestCommand(args, policy);
    const hash = try symbol.parseHash(a.hash);
    const place = try repo.jail(gpa, io, policy.root, a.file);
    defer place.deinit(gpa);
    const target = try repo.jailTarget(gpa, io, policy.root, a.target, true);
    defer target.deinit(gpa);
    try repo.refuseLinkAsWritten(gpa, io, a.target);
    const test_command = try runner.resolveTestCommand(gpa, io, place.abs, given, policy.allow_repo_config);
    defer gpa.free(test_command);
    const typecheck_command = try runner.resolveTypecheckCommand(gpa, io, place.abs, policy_mod.trustedTypecheckCommand(policy), policy.allow_repo_config);
    defer if (typecheck_command) |command| gpa.free(command);
    const outcome = try move_batch.tryMove(gpa, io, runtime, .{
        .request = .{ .file_abs = place.abs, .ref_text = a.symbol, .expected_hash = hash, .target_abs = target.abs, .interface_change = a.interface_change, .order_change = a.order_change },
        .test_command = test_command,
        .typecheck_command = typecheck_command,
        .allow_repo_memory = policy.allow_repo_memory,
        .shadow_root = policy.shadow_root,
        .trace = &event.trace,
        .language_service = policy.language_service,
    });
    defer outcome.deinit(gpa);
    const note_root = try shadow_root.displayRoot(gpa, policy.shadow_root);
    defer gpa.free(note_root);
    const note = wire.shadowNote(note_root, event.trace);
    event.chars_emetgate = a.symbol.len + a.hash.len + a.target.len;
    event.chars_fullfile = event.trace.new_len;
    switch (outcome.result) {
        .committed => {
            event.outcome = .committed;
            event.edits = outcome.plan.prepared.len;
            event.hash = outcome.plan.moved_hash;
            if (policy.tree_cache) |cache| for (outcome.plan.edits) |edit| cache.invalidate(edit.file_abs);
            const files = try gpa.alloc(wire.MovedFile, outcome.plan.prepared.len);
            defer gpa.free(files);
            for (outcome.plan.prepared, files) |p, *slot| slot.* = .{ .file = p.rel, .old_hash = p.base_hash, .new_hash = p.hash };
            try wire.writeMoveCommitted(w, .{
                .symbol = a.symbol,
                .source = place.rel,
                .target = target.rel,
                .hash = outcome.plan.moved_hash,
                .class = if (outcome.plan.order_change) "spending" else "symmetry",
                .resolver = @tagName(outcome.plan.resolver),
                .fallback = if (outcome.plan.fallback) |err| @errorName(err) else null,
                .interface_change = outcome.plan.interface_change,
                .created_target = outcome.plan.creates_target,
                .users = outcome.plan.users,
                .imports_added = outcome.plan.imports_added,
                .files = files,
            }, note);
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
