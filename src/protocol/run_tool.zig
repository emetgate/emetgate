const std = @import("std");
const shadow = @import("../platform/shadow.zig");
const wire = @import("wire.zig");
const telemetry = @import("telemetry.zig");
const tool_result = @import("tool_result.zig");
const policy_mod = @import("policy.zig");
const repo = @import("../platform/repo.zig");
const run_command = @import("../platform/run_command.zig");
const sandbox = @import("../platform/sandbox.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;
const ToolResult = tool_result.ToolResult;
const Policy = policy_mod.Policy;

pub const max_output_lines = 200;
pub const max_output_bytes = 16 * 1024;

pub const description = "Runs one command of the allowlist set when the server started, in a sandboxed shadow copy, and returns its exit code and the last 200 lines (16 KiB) of each output stream; the working tree is not changed. Without command, returns the allowlist.";

const Allowlist = struct {
    items: std.ArrayList([]const u8) = .empty,
    repo_runs: ?run_command.RepoRuns = null,

    fn deinit(self: *Allowlist, gpa: Allocator) void {
        self.items.deinit(gpa);
        if (self.repo_runs) |runs| runs.deinit();
    }
};

fn loadAllowlist(gpa: Allocator, io: std.Io, root_abs: []const u8, policy: *const Policy) !Allowlist {
    var list: Allowlist = .{};
    errdefer list.deinit(gpa);
    try list.items.appendSlice(gpa, policy.allowedRuns());
    if (policy.allow_repo_config) {
        list.repo_runs = try run_command.repoConfigRuns(gpa, io, root_abs);
        for (list.repo_runs.?.entries()) |entry| {
            if (run_command.match(list.items.items, entry) == null) try list.items.append(gpa, entry);
        }
    }
    return list;
}

pub fn callRun(gpa: Allocator, io: std.Io, args: ?Value, event: *telemetry.Event, policy: Policy) !ToolResult {
    event.label = "run";
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    const requested: ?[]const u8 = if (args) |a| switch (tool_result.getField(a, "command") orelse Value{ .null = {} }) {
        .null => null,
        .string => |text| text,
        else => return error.MissingArgument,
    } else null;
    const is_error = render(gpa, io, requested, args, &policy, &buffer.writer, event) catch |err| {
        if (err == error.OutOfMemory) return err;
        return tool_result.failure(gpa, &buffer, err, event);
    };
    return .{ .text = try tool_result.dupTrim(gpa, buffer.written()), .is_error = is_error };
}

fn render(gpa: Allocator, io: std.Io, requested: ?[]const u8, args: ?Value, policy: *const Policy, w: *Writer, event: *telemetry.Event) !bool {
    try policy_mod.refuseModelPolicy(args);
    const root_abs = try repo.servedRoot(gpa, io, policy.root);
    defer gpa.free(root_abs);
    var allowlist = try loadAllowlist(gpa, io, root_abs, policy);
    defer allowlist.deinit(gpa);
    const allowed = allowlist.items.items;

    const command = requested orelse {
        try writeAllowlist(w, allowed);
        return false;
    };
    const entry = switch (run_command.check(allowed, command)) {
        .refused => |why| {
            event.fail("RunRefused");
            try writeRefused(w, command, @tagName(why), allowed);
            return true;
        },
        .allowed => |entry| entry,
    };
    var used: shadow.TreeUse = .{};
    const report = run_command.runInShadow(gpa, io, .{
        .root_abs = root_abs,
        .command = entry,
        .shadow_root = policy.shadow_root,
        .gate_tree = policy.treeChoice(),
        .beside_commits = policy.commit,
        .used = &used,
        .blocked = &event.trace.blocked,
    }) catch |err| switch (err) {
        error.SandboxUnavailable => {
            event.fail("SandboxUnavailable");
            try writeRefused(w, command, "sandbox_unavailable", allowed);
            return true;
        },
        else => |e| return e,
    };
    defer report.deinit(gpa);
    try writeRan(w, entry, report, used);
    return false;
}

fn writeAllowlist(w: *Writer, allowed: []const []const u8) !void {
    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("status");
    try js.write("allowlist");
    try js.objectField("commands");
    try js.write(allowed);
    try js.endObject();
    try w.writeByte('\n');
}

fn writeRefused(w: *Writer, command: []const u8, reason: []const u8, allowed: []const []const u8) !void {
    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("status");
    try js.write("refused");
    try js.objectField("reason");
    try js.write(reason);
    try js.objectField("command");
    try js.write(command);
    try js.objectField("allowed");
    try js.write(allowed);
    try js.endObject();
    try w.writeByte('\n');
}

fn writeRan(w: *Writer, command: []const u8, report: sandbox.Report, used: shadow.TreeUse) !void {
    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("status");
    try js.write("ran");
    try js.objectField("command");
    try js.write(command);
    try js.objectField("outcome");
    switch (report.outcome) {
        .exited => |code| {
            try js.write("exited");
            try js.objectField("exit_code");
            try js.write(code);
        },
        .crashed => |code| {
            var code_buf: [10]u8 = undefined;
            try js.write("crashed");
            try js.objectField("crash_code");
            try js.write(try std.fmt.bufPrint(&code_buf, "0x{X:0>8}", .{code}));
        },
        .timed_out => try js.write("timed_out"),
        .output_limit => try js.write("output_limit"),
    }
    try js.objectField("killed_leftovers");
    try js.write(report.killed_leftovers);
    try js.objectField("duration_ms");
    try js.write(report.duration_ns / std.time.ns_per_ms);
    try writeStream(&js, "stdout", report.stdout);
    try writeStream(&js, "stderr", report.stderr);
    try wire.writeGateTree(&js, used);
    try js.objectField("truncated");
    try js.write(report.truncated);
    try js.endObject();
    try w.writeByte('\n');
}

fn writeStream(js: *std.json.Stringify, comptime name: []const u8, bytes: []const u8) !void {
    const cut = run_command.tail(bytes, max_output_lines, max_output_bytes);
    try js.objectField(name);
    try js.write(cut.text);
    try js.objectField(name ++ "_omitted_lines");
    try js.write(cut.omitted_lines);
}
