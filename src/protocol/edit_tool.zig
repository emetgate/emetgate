const std = @import("std");
const commit_plan = @import("../platform/commit_plan.zig");
const wire = @import("wire.zig");
const telemetry = @import("telemetry.zig");
const policy_mod = @import("policy.zig");
const tool_result = @import("tool_result.zig");
const runner = @import("../platform/runner.zig");
const shadow_root = @import("../platform/shadow_root.zig");
const file_edit = @import("../platform/file_edit.zig");
const receipts = @import("../platform/receipts.zig");
const receipt_note = @import("receipt_note.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;
const Policy = policy_mod.Policy;
const ToolResult = tool_result.ToolResult;

pub const edit_description = "Replaces exact old_string (unique unless replace_all) with new_string in any file, gated.";

pub const write_description = "Creates or overwrites a whole file, gated.";

const Request = struct {
    file: []const u8,
    change: file_edit.Change,
    may_create: bool,
    sent: usize,
};

pub fn callEdit(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, policy: Policy) !ToolResult {
    const file = try tool_result.requireString(args, "file");
    const old = try tool_result.requireString(args, "old_string");
    const new = try tool_result.requireString(args, "new_string");
    const all = tool_result.getBool(args.?, "replace_all") orelse false;
    event.label = "edit";
    return run(gpa, io, runtime, args, event, policy, .{ .file = file, .change = .{ .replace = .{ .old = old, .new = new, .all = all } }, .may_create = false, .sent = old.len + new.len });
}

pub fn callWrite(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, policy: Policy) !ToolResult {
    const file = try tool_result.requireString(args, "file");
    const content = try tool_result.requireString(args, "content");
    event.label = "write";
    return run(gpa, io, runtime, args, event, policy, .{ .file = file, .change = .{ .whole = content }, .may_create = true, .sent = content.len });
}

fn run(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, policy: Policy, request: Request) !ToolResult {
    event.file = request.file;
    event.mutating = true;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    var matches: usize = 0;
    const is_error = applyInto(gpa, io, runtime, args, policy, request, &matches, &buffer.writer, event) catch |err| blk: {
        if (err == error.OutOfMemory) return err;
        event.fail(@errorName(err));
        buffer.clearRetainingCapacity();
        switch (err) {
            error.WrittenButNotIndexed => try wire.writeNotIndexed(&buffer.writer, request.file),
            error.OldStringNotFound => try wire.writeErrorMessage(&buffer.writer, @errorName(err), wire.exitCode(err), "old_string matches 0 times; copy it exactly from the file"),
            error.OldStringNotUnique => {
                var text: [96]u8 = undefined;
                const message = std.fmt.bufPrint(&text, "old_string matches {d} times; add context or set replace_all", .{matches}) catch unreachable;
                try wire.writeErrorMessage(&buffer.writer, @errorName(err), wire.exitCode(err), message);
            },
            else => try wire.writeFailure(&buffer.writer, err, &event.trace.blocked),
        }
        break :blk true;
    };
    return .{ .text = try tool_result.dupTrim(gpa, buffer.written()), .is_error = is_error };
}

fn record(gpa: Allocator, io: std.Io, outcome: file_edit.Outcome, file_abs: []const u8, test_command: []const u8, typecheck_command: ?[]const u8, test_ms: ?u64, w: *Writer, full: bool, request: ?*commit_plan.Request) !void {
    const files = [1]receipts.FileChange{.{ .rel = outcome.rel, .before = outcome.before, .after_abs = file_abs }};
    try receipt_note.record(gpa, io, outcome.root, .{
        .operation = .try_batch,
        .class = .spending,
        .evidence = "test",
        .files = &files,
        .test_command = test_command,
        .typecheck_command = typecheck_command,
        .test_ms = test_ms,
        .version = receipt_note.version,
    }, w, full, request);
}

fn applyInto(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, policy: Policy, request: Request, matches: *usize, w: *Writer, event: *telemetry.Event) !bool {
    const given = try policy_mod.trustedTestCommand(args, policy);
    var commit = try policy_mod.commitRequest(args, policy, runtime);
    defer if (commit) |made| made.deinit(gpa);
    const target = try file_edit.jailWrite(gpa, io, policy.root, request.file, request.may_create);
    defer target.deinit(gpa);
    const anchor = file_edit.existingAncestor(io, target.abs) orelse return error.InvalidPath;
    const probe = try std.fmt.allocPrint(gpa, "{s}\\_", .{anchor});
    defer gpa.free(probe);
    const test_command = try runner.resolveTestCommand(gpa, io, probe, given, policy.allow_repo_config);
    defer gpa.free(test_command);
    const typecheck_command = try runner.resolveTypecheckCommand(gpa, io, probe, policy_mod.trustedTypecheckCommand(policy), policy.allow_repo_config);
    defer if (typecheck_command) |command| gpa.free(command);
    const created_dirs: []const []const u8 = @ptrCast(target.created_dirs);
    const outcome = try file_edit.apply(gpa, io, runtime, .{
        .file_abs = target.abs,
        .change = request.change,
        .created_dirs = created_dirs,
        .test_command = test_command,
        .typecheck_command = typecheck_command,
        .allow_repo_memory = policy.allow_repo_memory,
        .shadow_root = policy.shadow_root,
        .gate_tree = policy.treeChoice(),
        .trace = &event.trace,
        .commit = if (commit) |*made| made else null,
    }, matches);
    defer outcome.deinit(gpa);
    event.chars_emetgate = request.sent;
    event.chars_fullfile = event.trace.new_len;
    const full = tool_result.wantsFull(args);
    const result = outcome.result orelse {
        event.outcome = .committed;
        try wire.writeFileUnchanged(w);
        return false;
    };
    const note_root = try shadow_root.displayRoot(gpa, policy.shadow_root);
    defer gpa.free(note_root);
    const note = wire.shadowNote(note_root, event.trace);
    switch (result) {
        .committed => {
            event.outcome = .committed;
            event.edits = 1;
            event.hash = outcome.after;
            if (policy.tree_cache) |cache| cache.invalidate(target.abs);
            try wire.writeFileCommitted(w, .{ .file = outcome.rel, .created = outcome.created, .replaced = outcome.matches, .old_hash = outcome.before, .new_hash = outcome.after, .test_ms = event.trace.test_ms }, note, full);
            try record(gpa, io, outcome, target.abs, test_command, typecheck_command, event.trace.test_ms, w, full, if (commit) |*made| made else null);
            try receipt_note.commit(gpa, io, outcome.root, commit, w);
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
