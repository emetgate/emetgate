const std = @import("std");
const tool_names = @import("../engine/tool_names.zig");
const telemetry = @import("telemetry.zig");
const tool_result = @import("tool_result.zig");
const policy_mod = @import("policy.zig");
const repo = @import("../platform/repo.zig");
const run_command = @import("../platform/run_command.zig");
const open_shell = @import("../platform/open_shell.zig");
const commit_guard = @import("../platform/commit_guard.zig");
const sandbox_env = @import("../platform/sandbox.zig");
const test_command = @import("../platform/test_command.zig");
const test_outcome = @import("../platform/test_outcome.zig");
const sandbox = @import("../platform/sandbox.zig");
const output_digest = @import("output_digest.zig");
const receipt_note = @import("receipt_note.zig");
const run_trim = @import("run_trim.zig");
const frozen_hold = @import("../platform/frozen_hold.zig");
const run_audit = @import("../platform/run_audit.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;
const Policy = policy_mod.Policy;

pub const description = "Runs any shell command in the session folder (Git Bash if installed, else cmd) and replies with the shell, the exit code and the output. Long output is cut and each cut is labeled: git line-ending warnings, hints and progress are dropped, a passing test run is one line, a failing one keeps its failing tests, other output keeps its head and tail (4 KiB, 16 KiB for cat/sed/head). raw:true returns all output up to 64 KiB. Commands that delete recursively, rewrite git history, discard changes, drop data or commit outside the gate ask the user first. A path held by a frozen rule comes back after the command: changes to it are put back and the reply names them in frozen_restored; a commit the command made to one is named in frozen_committed.";

pub const command_desc = "the shell command, as you would type it";
pub const raw_desc = "return the output uncut, up to 64 KiB";
pub const timeout_desc = "seconds before the command is killed: default 120, 600 for a test run, at most 600";

pub const default_timeout_s: u64 = 120;
pub const test_timeout_s: u64 = 600;
pub const max_timeout_s: u64 = 600;
pub const max_output_bytes = 16 * 1024 * 1024;
pub const timeout_fix = "the command ran past its time; pass timeout_s (at most 600), or run it in parts";

pub const frozen_fix = "fix the code instead; a frozen path is changed by hand by the user";
pub const frozen_failed_fix = "a frozen path could not be put back; frozen_failed names each one and why: restore it by hand before going on";
pub const frozen_merge_fix = "a merge, rebase, cherry-pick or revert left the frozen_in_merge paths as git has them; emetgate_commit still checks them";
pub const rules_fix = "the command left what the rule_violations name, and nothing was undone; change what each rule names, and for a commit amend it or follow it with one that fixes it";
pub const hold_fix = "the command did not run: emetgate could not keep a copy of the frozen paths; emetgate doctor says why";

pub const Request = struct {
    command: []const u8,
    raw: bool = false,
    timeout_s: ?u64 = null,
};

pub fn parse(args: ?Value) error{MissingArgument}!Request {
    const a = args orelse return tool_result.missing("command (string)", .{});
    const command = switch (tool_result.getField(a, "command") orelse return tool_result.missing("command (string)", .{})) {
        .string => |text| text,
        else => return tool_result.missing("command (string)", .{}),
    };
    if (std.mem.trim(u8, command, " \t\r\n").len == 0) return tool_result.missing("command (string)", .{});
    var request: Request = .{ .command = command };
    if (tool_result.getField(a, "raw")) |value| switch (value) {
        .bool => |flag| request.raw = flag,
        .null => {},
        else => return tool_result.missing("raw (boolean)", .{}),
    };
    if (tool_result.getField(a, "timeout_s")) |value| switch (value) {
        .integer => |n| {
            if (n < 1 or n > max_timeout_s) return tool_result.missing("timeout_s (integer from 1 to {d})", .{max_timeout_s});
            request.timeout_s = @intCast(n);
        },
        .null => {},
        else => return tool_result.missing("timeout_s (integer from 1 to {d})", .{max_timeout_s}),
    };
    return request;
}

pub fn render(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, policy: *const Policy, w: *Writer, event: *telemetry.Event) !bool {
    try policy_mod.refuseModelPolicy(args);
    const request = try parse(args);
    event.command = request.command;
    const root_abs = try repo.servedRoot(gpa, io, policy.root);
    defer gpa.free(root_abs);
    if (output_digest.logRequest(request.command)) |id| {
        if (request.raw) return output_digest.writeLogLimited(gpa, io, root_abs, id, w, std.math.maxInt(usize), run_trim.raw_cap);
        return output_digest.writeLog(gpa, io, root_abs, id, w);
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const configured: ?[]const u8 = policy.test_command orelse if (policy.detect_test) test_command.detectIn(arena, io, root_abs) catch null else null;
    const shape = try run_trim.shapeOf(arena, request.command, configured);
    const timeout_s = request.timeout_s orelse if (shape.test_run) test_timeout_s else default_timeout_s;
    const limits: sandbox.Limits = .{ .timeout_ms = timeout_s * std.time.ms_per_s, .max_output_bytes = max_output_bytes };

    const shell = try open_shell.find(gpa, root_abs);
    defer shell.deinit(gpa);
    const guard = try guardEnvironment(arena, gpa, io, root_abs, policy);
    var audit: run_audit.Audit = undefined;
    try audit.begin(gpa, io, runtime, root_abs, policy.nested_roots, policy.allow_repo_memory);
    defer audit.deinit();
    const ran = run_command.runOpenInRepo(gpa, io, root_abs, shell, request.command, limits, receipt_note.version, .{ .cwd = policy.session_dir, .also_hold = policy.nested_roots, .env = guard.env }) catch |err| switch (err) {
        error.SandboxUnavailable, error.SandboxBusy, error.FrozenHoldFailed => {
            event.fail(@errorName(err));
            try writeNotRun(w, request.command, shell.kind, err);
            return true;
        },
        else => |e| return e,
    };
    defer ran.report.deinit(gpa);
    defer ran.frozen.deinit(gpa);
    try audit.finish();
    const broken = audit.findings.items.len != 0;
    switch (ran.report.outcome) {
        .exited => |code| event.exit_code = code,
        else => event.fail(@tagName(ran.report.outcome)),
    }
    const body = try shapedOutput(gpa, arena, ran.report, shape, request.raw);
    defer gpa.free(body.text);

    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("status");
    try js.write(if (!ran.frozen.held()) "frozen_not_restored" else if (broken) "rules_broken" else "ran");
    try js.objectField("command");
    try js.write(request.command);
    try js.objectField("shell");
    try js.write(shell.kind.label());
    try writeOutcome(&js, ran.report);
    try js.objectField("duration_ms");
    try js.write(ran.report.duration_ns / std.time.ns_per_ms);
    if (ran.report.outcome == .timed_out) {
        try js.objectField("timeout_s");
        try js.write(timeout_s);
    }
    try writeAudit(&js, &audit);
    const other_fix: ?[]const u8 = if (broken and ran.report.outcome == .timed_out)
        try std.mem.join(arena, "; ", &.{ timeout_fix, rules_fix })
    else if (broken)
        rules_fix
    else if (ran.report.outcome == .timed_out)
        timeout_fix
    else
        null;
    try writeFrozen(gpa, &js, ran.frozen, other_fix);
    if (guard.failed) |reason| {
        try js.objectField("commit_guard_error");
        try js.write(reason);
    }
    if (ran.report.no_tests) {
        try js.objectField("note");
        try js.write(test_outcome.no_tests_note);
    }
    if (ran.report.killed_leftovers) {
        try js.objectField("killed_leftovers");
        try js.write(ran.report.killed_leftovers);
    }
    if (ran.report.truncated) {
        try js.objectField("truncated");
        try js.write(true);
    }
    if (ran.changed != 0) {
        try js.objectField("files_changed");
        try js.write(ran.changed);
        if (ran.receipt) |id| {
            try js.objectField("receipt");
            try js.write(&id);
        }
    }
    if (ran.receipt_error) |err| {
        try js.objectField("receipt_error");
        try js.write(@errorName(err));
    }
    if (body.cut) {
        try js.objectField("output_bytes");
        try js.write(ran.report.stdout.len + ran.report.stderr.len);
        if (try output_digest.storeLog(gpa, io, root_abs, ran.report)) |id| {
            var buf: [96 + tool_names.max_prefix]u8 = undefined;
            try js.objectField("full_log");
            try js.write(try std.fmt.bufPrint(&buf, "{s}emetgate_run command=\"{s}{s}\" raw=true", .{ tool_names.prefix(), output_digest.log_prefix, &id }));
        }
    }
    try js.objectField("content");
    try js.write(body.text);
    try js.endObject();
    try w.writeByte('\n');
    if (!ran.frozen.held()) event.fail("FrozenNotRestored") else if (broken) event.fail("RulesBroken");
    return !ran.frozen.held() or broken;
}

pub fn writeFrozen(gpa: Allocator, js: *std.json.Stringify, frozen: frozen_hold.Report, other_fix: ?[]const u8) !void {
    if (frozen.restored.len != 0) {
        try js.objectField("frozen_restored");
        try js.write(frozen.restored);
    }
    if (frozen.committed.len != 0) {
        try js.objectField("frozen_committed");
        try js.write(frozen.committed);
    }
    if (frozen.in_merge.len != 0) {
        try js.objectField("frozen_in_merge");
        try js.write(frozen.in_merge);
    }
    if (!frozen.held()) {
        try js.objectField("frozen_failed");
        try js.beginArray();
        for (frozen.failed) |item| try js.write(item);
        if (frozen.failure) |err| try js.write(frozen_hold.Failed{ .path = "(all)", .reason = @errorName(err) });
        try js.endArray();
    }
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);
    if (other_fix) |text| try parts.append(gpa, text);
    if (!frozen.held()) try parts.append(gpa, frozen_failed_fix);
    if (frozen.restored.len != 0 or frozen.committed.len != 0) try parts.append(gpa, frozen_fix);
    if (frozen.in_merge.len != 0) try parts.append(gpa, frozen_merge_fix);
    if (parts.items.len == 0) return;
    const fix = try std.mem.join(gpa, "; ", parts.items);
    defer gpa.free(fix);
    try js.objectField("fix");
    try js.write(fix);
}

fn writeAudit(js: *std.json.Stringify, audit: *const run_audit.Audit) !void {
    if (audit.findings.items.len != 0) {
        try js.objectField("rule_violations");
        try js.beginArray();
        for (audit.findings.items) |finding| {
            try js.beginObject();
            if (finding.commit) |commit| {
                try js.objectField("commit");
                try js.write(commit);
            }
            try js.objectField("file");
            try js.write(finding.file);
            try js.objectField("line");
            try js.write(finding.line);
            try js.objectField("col");
            try js.write(finding.col);
            try js.objectField("rule");
            try js.write(finding.rule);
            if (finding.rule_text.len != 0) {
                try js.objectField("rule_text");
                try js.write(finding.rule_text);
            }
            try js.objectField("text");
            try js.write(finding.text);
            try js.endObject();
        }
        try js.endArray();
    }
    if (audit.more_findings != 0) {
        try js.objectField("rule_violations_more");
        try js.write(audit.more_findings);
    }
    if (audit.unchecked.items.len != 0) {
        try js.objectField("rules_unchecked");
        try js.write(audit.unchecked.items);
    }
}

fn writeOutcome(js: *std.json.Stringify, report: sandbox.Report) !void {
    switch (report.outcome) {
        .exited => |code| {
            try js.objectField("exit_code");
            try js.write(code);
        },
        .crashed => |code| {
            var code_buf: [10]u8 = undefined;
            try js.objectField("outcome");
            try js.write("crashed");
            try js.objectField("crash_code");
            try js.write(try std.fmt.bufPrint(&code_buf, "0x{X:0>8}", .{code}));
        },
        .timed_out => {
            try js.objectField("outcome");
            try js.write("timed_out");
        },
        .output_limit => {
            try js.objectField("outcome");
            try js.write("output_limit");
        },
    }
}

const Guard = struct { env: []const sandbox_env.EnvVar = &.{}, failed: ?[]const u8 = null };

fn guardEnvironment(arena: Allocator, gpa: Allocator, io: std.Io, root_abs: []const u8, policy: *const Policy) !Guard {
    const exe = policy.commit_guard_exe orelse return .{};
    const local = try sandbox_env.environmentValue(arena, std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA")) orelse return .{ .failed = "LocalAppDataUnavailable" };
    const state = try std.fmt.allocPrint(arena, "{s}\\emetgate", .{local});
    const hooks = commit_guard.install(gpa, io, state, exe) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failed = @errorName(err) },
    };
    defer gpa.free(hooks);
    const count = try sandbox_env.environmentValue(arena, std.unicode.utf8ToUtf16LeStringLiteral("GIT_CONFIG_COUNT"));
    return .{ .env = try commit_guard.environment(arena, hooks, root_abs, policy.allow_repo_memory, count) };
}

fn writeNotRun(w: *Writer, command: []const u8, kind: open_shell.Kind, err: anyerror) !void {
    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("status");
    try js.write("not_run");
    try js.objectField("reason");
    try js.write(@errorName(err));
    try js.objectField("command");
    try js.write(command);
    try js.objectField("shell");
    try js.write(kind.label());
    try js.objectField("fix");
    try js.write(switch (err) {
        error.SandboxBusy => "another command or test run is still running; call again when it ends",
        error.FrozenHoldFailed => hold_fix,
        else => "emetgate could not start the shell; emetgate doctor says why",
    });
    try js.endObject();
    try w.writeByte('\n');
}

pub const Body = struct { text: []u8, cut: bool };

pub fn shapedOutput(gpa: Allocator, arena: Allocator, report: sandbox.Report, shape: run_trim.Shape, raw: bool) !Body {
    if (raw) {
        const all = try run_trim.joined(arena, report.stdout, report.stderr);
        const cut = try run_trim.headTail(gpa, all, run_trim.raw_cap, "raw output stops at 64 KiB; full_log has the rest");
        return .{ .text = cut.text, .cut = cut.lines_cut != 0 };
    }
    if (shape.test_run) {
        if (try output_digest.passLine(gpa, report)) |line| return .{ .text = line, .cut = report.stdout.len + report.stderr.len > line.len };
        if (!report.passed()) {
            const d = try output_digest.digest(gpa, report.stdout, report.stderr);
            if (d.dropped_lines == 0) return .{ .text = d.text, .cut = false };
            defer gpa.free(d.text);
            const text = try std.fmt.allocPrint(gpa, "{s}\n[emetgate: {d} lines of passing tests and runner noise cut; {s}]", .{ d.text, d.dropped_lines, run_trim.raw_hint });
            return .{ .text = text, .cut = true };
        }
    }
    var stdout = report.stdout;
    var stderr = report.stderr;
    var dropped: usize = 0;
    if (shape.git) {
        const out = try run_trim.dropGitNoise(arena, stdout);
        const err = try run_trim.dropGitNoise(arena, stderr);
        stdout = out.text;
        stderr = if (std.mem.trim(u8, err.text, " \t\r\n").len == 0) "" else err.text;
        dropped = out.dropped + err.dropped;
    }
    const all = try run_trim.joined(arena, stdout, stderr);
    const cut = try run_trim.headTail(arena, all, shape.budget(), run_trim.raw_hint);
    if (dropped == 0) return .{ .text = try gpa.dupe(u8, cut.text), .cut = cut.lines_cut != 0 };
    const gap: []const u8 = if (cut.text.len == 0 or cut.text[cut.text.len - 1] == '\n') "" else "\n";
    const text = try std.fmt.allocPrint(gpa, "{s}{s}[emetgate: {d} git noise lines dropped (line-ending warnings, hints, progress); {s}]", .{ cut.text, gap, dropped, run_trim.raw_hint });
    return .{ .text = text, .cut = true };
}
