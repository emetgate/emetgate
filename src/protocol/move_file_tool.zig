const std = @import("std");
const symbol = @import("../engine/symbol.zig");
const wire = @import("wire.zig");
const telemetry = @import("telemetry.zig");
const policy_mod = @import("policy.zig");
const tool_result = @import("tool_result.zig");
const runner = @import("../platform/runner.zig");
const repo = @import("../platform/repo.zig");
const shadow_root = @import("../platform/shadow_root.zig");
const file_move = @import("../platform/file_move.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;
const Policy = policy_mod.Policy;
const ToolResult = tool_result.ToolResult;

const Arguments = struct {
    from: []const u8,
    to: []const u8,
    hash: []const u8,
    interface_change: bool,
};

pub fn callMoveFile(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, policy: Policy) !ToolResult {
    const arguments: Arguments = .{
        .from = try tool_result.requireString(args, "from"),
        .to = try tool_result.requireString(args, "to"),
        .hash = try tool_result.requireString(args, "from_hash"),
        .interface_change = tool_result.getBool(args.?, "interface_change") orelse false,
    };
    event.label = "move_file";
    event.file = arguments.from;
    event.mutating = true;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    const is_error = moveInto(gpa, io, runtime, arguments, args, policy, &buffer.writer, event) catch |err| blk: {
        if (err == error.OutOfMemory) return err;
        event.fail(@errorName(err));
        buffer.clearRetainingCapacity();
        if (err == error.WrittenButNotIndexed) {
            try wire.writeNotIndexed(&buffer.writer, arguments.to);
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
    const place = try repo.jail(gpa, io, policy.root, a.from);
    defer place.deinit(gpa);
    try repo.refuseLinkAsWritten(gpa, io, a.from);
    const to_abs = try file_move.jailDestination(gpa, io, place.root, a.to);
    defer gpa.free(to_abs);
    const to_rel = try repo.relativeUnder(gpa, place.root, to_abs);
    defer gpa.free(to_rel);
    const test_command = try runner.resolveTestCommand(gpa, io, place.abs, given, policy.allow_repo_config);
    defer gpa.free(test_command);
    const typecheck_command = try runner.resolveTypecheckCommand(gpa, io, place.abs, policy_mod.trustedTypecheckCommand(policy), policy.allow_repo_config);
    defer if (typecheck_command) |command| gpa.free(command);
    const outcome = try file_move.tryMoveFile(gpa, io, runtime, .{
        .request = .{ .from_abs = place.abs, .to_abs = to_abs, .from_hash = hash, .interface_change = a.interface_change },
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
    event.chars_emetgate = a.from.len + a.to.len + a.hash.len;
    event.chars_fullfile = event.trace.new_len;
    switch (outcome.result) {
        .committed => {
            event.outcome = .committed;
            event.edits = outcome.plan.prepared.len;
            if (policy.tree_cache) |cache| {
                cache.invalidate(place.abs);
                for (outcome.plan.edits) |edit| cache.invalidate(edit.file_abs);
            }
            const files = try gpa.alloc(wire.MovedFile, outcome.plan.prepared.len);
            defer gpa.free(files);
            for (outcome.plan.prepared, files) |p, *slot| slot.* = .{ .file = p.rel, .old_hash = p.base_hash, .new_hash = p.hash };
            try wire.writeFileMoveCommitted(w, .{
                .from = place.rel,
                .to = to_rel,
                .resolver = @tagName(outcome.plan.resolver),
                .fallback = if (outcome.plan.fallback) |err| @errorName(err) else null,
                .interface_change = outcome.plan.interface_change,
                .created_dirs = outcome.plan.created_dirs.len,
                .users = outcome.plan.users,
                .rewritten = outcome.plan.rewritten,
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
