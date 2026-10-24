const std = @import("std");
const telemetry = @import("telemetry.zig");
const tool_result = @import("tool_result.zig");
const repo = @import("../platform/repo.zig");
const exe_path = @import("../platform/exe_path.zig");
const git_symbols = @import("git_symbols.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;

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
    MissingPath,
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

pub fn callGit(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, root: ?[]const u8) !ToolResult {
    const sub = try requireString(args, "sub");
    event.label = "git";
    event.file = sub;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    render(gpa, io, runtime, root, sub, args, &buffer.writer) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err, event);
    };
    return success(gpa, &buffer);
}

fn render(gpa: Allocator, io: std.Io, runtime: *Runtime, root: ?[]const u8, sub: []const u8, args: ?Value, w: *Writer) !void {
    const path = if (args) |a| getString(a, "path") else null;
    const place = try repo.jail(gpa, io, root, path orelse ".");
    defer place.deinit(gpa);

    const git = try exe_path.git(gpa, place.root);
    defer gpa.free(git);
    var argv: [max_argv][]const u8 = undefined;
    var n: usize = 0;
    for (safe_prefix) |a| {
        argv[n] = a;
        n += 1;
    }
    argv[0] = git;

    var count_buf: [8]u8 = undefined;
    var show_commit: ?[]const u8 = null;
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
        show_commit = commit;
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
    } else if (std.mem.eql(u8, sub, "blame")) {
        // blame has no unambiguous --no-color (it collides with
        // --no-color-lines); color is already off via the -c prefix.
        if (path == null or place.rel.len == 0) return error.MissingPath;
        argv[n] = "blame";
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

    const annotated: []const []const u8 = if (std.mem.eql(u8, sub, "log"))
        annotatedCommits(gpa, io, git, place.root) catch &.{}
    else
        &.{};
    defer if (annotated.len != 0) {
        for (annotated) |oid| gpa.free(oid);
        gpa.free(annotated);
    };

    // Symbol-level view: diff and show map their changed line ranges to the
    // enclosing symbols; blame maps each symbol to the commit that last
    // touched it. Best-effort — a failure here leaves the raw git output intact.
    var summary: ?git_symbols.Summary = null;
    defer if (summary) |*s| s.deinit();
    var blame: ?git_symbols.BlameReport = null;
    defer if (blame) |*b| b.deinit();

    if (std.mem.eql(u8, sub, "diff")) {
        // An empty rev means the index: `git show :<path>`. For the working
        // tree the new side is read from disk (null rev).
        const sides: git_symbols.Sides = if (getBool(args, "staged"))
            .{ .old_rev = "HEAD", .new_rev = "" }
        else
            .{ .old_rev = "", .new_rev = null };
        summary = git_symbols.analyzeDiff(gpa, io, runtime, git, place.root, sides, result.stdout) catch null;
    } else if (std.mem.eql(u8, sub, "show")) {
        const parent = try std.fmt.allocPrint(gpa, "{s}^", .{show_commit.?});
        defer gpa.free(parent);
        const sides: git_symbols.Sides = .{ .old_rev = parent, .new_rev = show_commit.? };
        summary = git_symbols.analyzeDiff(gpa, io, runtime, git, place.root, sides, result.stdout) catch null;
    }

    var porcelain: ?[]u8 = null;
    defer if (porcelain) |p| gpa.free(p);
    if (std.mem.eql(u8, sub, "blame")) {
        porcelain = blamePorcelain(gpa, io, git, place.root, place.rel) catch null;
        if (porcelain) |text|
            blame = git_symbols.analyzeBlame(gpa, io, runtime, place.root, place.rel, text) catch null;
    }

    try writeResult(gpa, w, sub, path, result.stdout, annotated, if (summary) |*s| s else null, if (blame) |*b| b else null);
}

/// Second blame pass in machine-readable form, used only to map symbols to the
/// commit that last changed them. Best-effort: a failure returns null and the
/// raw blame stays the whole answer.
fn blamePorcelain(gpa: Allocator, io: std.Io, git: []const u8, root: []const u8, rel: []const u8) !?[]u8 {
    const argv = [_][]const u8{ git, "--no-pager", "blame", "--line-porcelain", "--", rel };
    const result = std.process.run(gpa, io, .{
        .argv = &argv,
        .cwd = .{ .path = root },
        .stdout_limit = .limited(max_git_output_bytes * 8),
        .stderr_limit = .limited(max_git_output_bytes),
    }) catch return null;
    defer gpa.free(result.stderr);
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        gpa.free(result.stdout);
        return null;
    }
    return result.stdout;
}

/// Column ② — proof-aware reading: the full object ids of every commit that
/// carries an emetgate receipt note (refs/notes/emetgate). Used to flag each
/// log line as receipt-backed or not. Best-effort: a missing notes ref yields
/// an empty set rather than an error.
fn annotatedCommits(gpa: Allocator, io: std.Io, git: []const u8, root: []const u8) ![]const []const u8 {
    const argv = [_][]const u8{ git, "--no-pager", "notes", "--ref=emetgate", "list" };
    const limit: std.Io.Limit = .limited(max_git_output_bytes);
    const result = std.process.run(gpa, io, .{
        .argv = &argv,
        .cwd = .{ .path = root },
        .stdout_limit = limit,
        .stderr_limit = limit,
    }) catch return &.{};
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    const exited = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!exited) return &.{};
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |oid| gpa.free(oid);
        list.deinit(gpa);
    }
    var lines = std.mem.tokenizeAny(u8, result.stdout, "\r\n");
    while (lines.next()) |line| {
        // Each line is "<note-object> <annotated-commit-object>".
        const space = std.mem.lastIndexOfScalar(u8, line, ' ') orelse continue;
        const commit = std.mem.trim(u8, line[space + 1 ..], " \t");
        if (commit.len == 0) continue;
        try list.append(gpa, try gpa.dupe(u8, commit));
    }
    return list.toOwnedSlice(gpa);
}

fn isAnnotated(annotated: []const []const u8, oid: []const u8) bool {
    for (annotated) |known| if (std.mem.eql(u8, known, oid)) return true;
    return false;
}

fn writeResult(gpa: Allocator, w: *Writer, sub: []const u8, path: ?[]const u8, stdout: []const u8, annotated: []const []const u8, summary: ?*const git_symbols.Summary, blame: ?*const git_symbols.BlameReport) !void {
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
    if (std.mem.eql(u8, sub, "log")) {
        try js.objectField("commits");
        try js.beginArray();
        for (kept.items) |line| {
            if (line.len == 0) continue;
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse line.len;
            const oid = line[0..tab];
            try js.beginObject();
            try js.objectField("commit");
            try js.write(oid);
            try js.objectField("verification");
            // v1 proof-mark: a receipt note is attached ("verified") or not
            // ("unverified"). Replaying the receipt is the job of
            // `emetgate verify` / `verify --branch`; here we only read the ref.
            try js.write(if (isAnnotated(annotated, oid)) "verified" else "unverified");
            try js.endObject();
        }
        try js.endArray();
    }
    if (summary) |s| try writeSymbolSummary(&js, s.*);
    if (blame) |b| try writeBlameSummary(&js, b.*);
    try js.endObject();
    try w.writeByte('\n');
}

fn writeSymbolSummary(js: *std.json.Stringify, summary: git_symbols.Summary) !void {
    try js.objectField("symbol_changes");
    try js.beginArray();
    for (summary.files) |file| {
        try js.beginObject();
        try js.objectField("path");
        try js.write(file.path);
        try js.objectField("status");
        try js.write(file.status);
        try js.objectField("mapped");
        try js.write(file.mapped);
        try js.objectField("non_symbol_change");
        try js.write(file.non_symbol_change);
        if (file.note) |note| {
            try js.objectField("note");
            try js.write(note);
        }
        try js.objectField("symbols");
        try js.beginArray();
        for (file.symbols) |sym| {
            try js.beginObject();
            try js.objectField("ref");
            try js.write(sym.ref);
            try js.objectField("kind");
            try js.write(sym.kind);
            try js.objectField("change");
            try js.write(@tagName(sym.change));
            try js.endObject();
        }
        try js.endArray();
        try js.endObject();
    }
    try js.endArray();
    try js.objectField("symbol_changes_truncated");
    try js.write(summary.truncated);
}

fn writeBlameSummary(js: *std.json.Stringify, blame: git_symbols.BlameReport) !void {
    try js.objectField("symbol_blame");
    try js.beginObject();
    try js.objectField("file");
    try js.write(blame.file);
    try js.objectField("mapped");
    try js.write(blame.mapped);
    if (blame.note) |note| {
        try js.objectField("note");
        try js.write(note);
    }
    try js.objectField("symbols");
    try js.beginArray();
    for (blame.symbols) |sym| {
        try js.beginObject();
        try js.objectField("ref");
        try js.write(sym.ref);
        try js.objectField("kind");
        try js.write(sym.kind);
        try js.objectField("commit");
        try js.write(sym.commit);
        try js.objectField("summary");
        try js.write(sym.summary);
        try js.objectField("author");
        try js.write(sym.author);
        try js.objectField("line_start");
        try js.write(sym.start_line);
        try js.objectField("line_end");
        try js.write(sym.end_line);
        try js.endObject();
    }
    try js.endArray();
    try js.endObject();
}
