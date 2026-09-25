const std = @import("std");
const telemetry = @import("telemetry.zig");
const tool_result = @import("tool_result.zig");
const repo = @import("../platform/repo.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;
const ToolResult = tool_result.ToolResult;
const requireString = tool_result.requireString;
const getString = tool_result.getString;
const getField = tool_result.getField;
const success = tool_result.success;
const failure = tool_result.failure;

const max_git_output_bytes = 256 * 1024;
const max_output_lines = 800;
const default_log_count = 20;
const max_log_count = 200;
const max_argv = 24;

pub const Error = error{
    UnknownGitSubcommand,
    MissingCommit,
    InvalidCommit,
    InvalidCount,
    GitCommandFailed,
};

const safe_prefix = [_][]const u8{
    "git",
    "-c",
    "core.pager=cat",
    "-c",
    "diff.external=",
    "-c",
    "diff.tool=",
    "-c",
    "core.fsmonitor=false",
    "-c",
    "advice.detachedHead=false",
    "--no-optional-locks",
    "--no-pager",
};

fn isHexDigit(c: u8) bool {
    return switch (c) {
        '0'...'9', 'a'...'f', 'A'...'F' => true,
        else => false,
    };
}

fn isValidCommit(text: []const u8) bool {
    if (text.len == 0 or text.len > 64) return false;
    if (std.mem.eql(u8, text, "HEAD")) return true;
    if (std.mem.startsWith(u8, text, "HEAD~") or std.mem.startsWith(u8, text, "HEAD^")) {
        const rest = text[5..];
        if (rest.len == 0) return true;
        for (rest) |c| if (!std.ascii.isDigit(c)) return false;
        return true;
    }
    if (text.len < 4) return false;
    for (text) |c| if (!isHexDigit(c)) return false;
    return true;
}

fn getInt(args: ?Value, key: []const u8) ?i64 {
    const field = getField(args orelse return null, key) orelse return null;
    return switch (field) {
        .integer => |i| i,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

fn getBool(args: ?Value, key: []const u8) bool {
    const field = getField(args orelse return false, key) orelse return false;
    return switch (field) {
        .bool => |b| b,
        .string => |s| std.mem.eql(u8, s, "true"),
        else => false,
    };
}

pub fn callGit(gpa: Allocator, io: std.Io, args: ?Value, event: *telemetry.Event, root: ?[]const u8) !ToolResult {
    const sub = try requireString(args, "sub");
    event.label = "git";
    event.file = sub;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    render(gpa, io, root, sub, args, &buffer.writer) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err, event);
    };
    return success(gpa, &buffer);
}

fn render(gpa: Allocator, io: std.Io, root: ?[]const u8, sub: []const u8, args: ?Value, w: *Writer) !void {
    const path = if (args) |a| getString(a, "path") else null;
    const place = try repo.jail(gpa, io, root, path orelse ".");
    defer place.deinit(gpa);

    var argv: [max_argv][]const u8 = undefined;
    var n: usize = 0;
    for (safe_prefix) |a| {
        argv[n] = a;
        n += 1;
    }

    var count_buf: [8]u8 = undefined;
    if (std.mem.eql(u8, sub, "status")) {
        argv[n] = "status";
        n += 1;
        argv[n] = "--porcelain=v1";
        n += 1;
        argv[n] = "--untracked-files=all";
        n += 1;
    } else if (std.mem.eql(u8, sub, "diff")) {
        argv[n] = "diff";
        n += 1;
        argv[n] = "--no-color";
        n += 1;
        argv[n] = "--no-ext-diff";
        n += 1;
        argv[n] = "--no-textconv";
        n += 1;
        if (getBool(args, "staged")) {
            argv[n] = "--cached";
            n += 1;
        }
    } else if (std.mem.eql(u8, sub, "log")) {
        const requested = getInt(args, "n") orelse default_log_count;
        const clamped: usize = @intCast(std.math.clamp(requested, 1, max_log_count));
        argv[n] = "log";
        n += 1;
        argv[n] = "--no-color";
        n += 1;
        argv[n] = "-n";
        n += 1;
        argv[n] = std.fmt.bufPrint(&count_buf, "{d}", .{clamped}) catch return error.InvalidCount;
        n += 1;
        argv[n] = "--date=iso-strict";
        n += 1;
        argv[n] = "--pretty=format:%H%x09%ad%x09%s";
        n += 1;
    } else if (std.mem.eql(u8, sub, "show")) {
        const commit = (if (args) |a| getString(a, "commit") else null) orelse return error.MissingCommit;
        if (!isValidCommit(commit)) return error.InvalidCommit;
        argv[n] = "show";
        n += 1;
        argv[n] = "--no-color";
        n += 1;
        argv[n] = "--no-ext-diff";
        n += 1;
        argv[n] = "--no-textconv";
        n += 1;
        argv[n] = commit;
        n += 1;
    } else {
        return error.UnknownGitSubcommand;
    }

    if (path != null and place.rel.len != 0) {
        argv[n] = "--";
        n += 1;
        argv[n] = place.rel;
        n += 1;
    }

    const result = std.process.run(gpa, io, .{
        .argv = argv[0..n],
        .cwd = .{ .path = place.root },
        .stdout_limit = .limited(max_git_output_bytes),
        .stderr_limit = .limited(max_git_output_bytes),
    }) catch return error.GitCommandFailed;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) return error.GitCommandFailed;

    try writeResult(gpa, w, sub, path, result.stdout);
}

fn writeResult(gpa: Allocator, w: *Writer, sub: []const u8, path: ?[]const u8, stdout: []const u8) !void {
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    var kept: std.ArrayList([]const u8) = .empty;
    defer kept.deinit(gpa);
    var total: usize = 0;
    while (lines.next()) |line| {
        total += 1;
        if (kept.items.len < max_output_lines) try kept.append(gpa, line);
    }
    const truncated = total > kept.items.len;

    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("sub");
    try js.write(sub);
    if (path) |p| {
        try js.objectField("path");
        try js.write(p);
    }
    try js.objectField("output");
    var joined: std.Io.Writer.Allocating = .init(gpa);
    defer joined.deinit();
    for (kept.items, 0..) |line, i| {
        if (i != 0) try joined.writer.writeByte('\n');
        try joined.writer.writeAll(line);
    }
    try js.write(joined.written());
    try js.objectField("lines_shown");
    try js.write(kept.items.len);
    try js.objectField("lines_total");
    try js.write(total);
    try js.objectField("truncated");
    try js.write(truncated);
    try js.endObject();
    try w.writeByte('\n');
}
