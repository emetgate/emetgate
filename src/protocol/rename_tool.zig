const std = @import("std");
const symbol = @import("../engine/symbol.zig");
const wire = @import("wire.zig");
const telemetry = @import("telemetry.zig");
const policy_mod = @import("policy.zig");
const tool_result = @import("tool_result.zig");
const runner = @import("../platform/runner.zig");
const repo = @import("../platform/repo.zig");
const shadow_root = @import("../platform/shadow_root.zig");
const rename_batch = @import("../platform/rename_batch.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;
const Policy = policy_mod.Policy;
const ToolResult = tool_result.ToolResult;

pub fn callRename(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, policy: Policy) !ToolResult {
    const file = try tool_result.requireString(args, "file");
    const sym = try tool_result.requireString(args, "symbol");
    const hash_hex = try tool_result.requireString(args, "hash");
    const new_name = try tool_result.requireString(args, "new_name");
    const interface_change = tool_result.getBool(args.?, "interface_change") orelse false;
    event.label = "rename";
    event.file = file;
    event.symbol = sym;
    event.mutating = true;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    const is_error = renameInto(gpa, io, runtime, file, sym, hash_hex, new_name, interface_change, args, policy, &buffer.writer, event) catch |err| blk: {
        if (err == error.OutOfMemory) return err;
        event.fail(@errorName(err));
        buffer.clearRetainingCapacity();
        if (err == error.WrittenButNotIndexed) {
            try wire.writeNotIndexed(&buffer.writer, file);
        } else {
            try wire.writeError(&buffer.writer, @errorName(err), wire.exitCode(err));
        }
        break :blk true;
    };
    return .{ .text = try tool_result.dupTrim(gpa, buffer.written()), .is_error = is_error };
}

fn renameInto(gpa: Allocator, io: std.Io, runtime: *Runtime, file: []const u8, sym: []const u8, hash_hex: []const u8, new_name: []const u8, interface_change: bool, args: ?Value, policy: Policy, w: *Writer, event: *telemetry.Event) !bool {
    const given = try policy_mod.trustedTestCommand(args, policy);
    const hash = try symbol.parseHash(hash_hex);
    const place = try repo.jail(gpa, io, policy.root, file);
    defer place.deinit(gpa);
    const test_command = try runner.resolveTestCommand(gpa, io, place.abs, given, policy.allow_repo_config);
    defer gpa.free(test_command);
    const typecheck_command = try runner.resolveTypecheckCommand(gpa, io, place.abs, policy_mod.trustedTypecheckCommand(policy), policy.allow_repo_config);
    defer if (typecheck_command) |command| gpa.free(command);
    const outcome = try rename_batch.tryRename(gpa, io, runtime, .{
        .request = .{ .file_abs = place.abs, .ref_text = sym, .expected_hash = hash, .new_name = new_name, .interface_change = interface_change },
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
    event.chars_emetgate = sym.len + hash_hex.len + new_name.len;
    event.chars_fullfile = event.trace.new_len;
    switch (outcome.result) {
        .committed => {
            event.outcome = .committed;
            event.edits = outcome.plan.prepared.len;
            event.hash = outcome.plan.new_hash;
            const files = try gpa.alloc(wire.RenamedFile, outcome.plan.prepared.len);
            defer gpa.free(files);
            for (outcome.plan.prepared, files) |p, *slot| slot.* = .{ .file = p.rel, .old_hash = p.base_hash.?, .new_hash = p.hash };
            try wire.writeRenameCommitted(w, .{
                .symbol = sym,
                .new_symbol = outcome.plan.new_ref,
                .old_hash = hash,
                .new_hash = outcome.plan.new_hash,
                .resolver = @tagName(outcome.plan.resolver),
                .fallback = if (outcome.plan.fallback) |err| @errorName(err) else null,
                .interface_change = outcome.plan.interface_change,
                .regions_checked = outcome.plan.regions_checked,
                .symbols_checked = outcome.plan.symbols_checked,
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
