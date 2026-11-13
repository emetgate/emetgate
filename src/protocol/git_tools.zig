const std = @import("std");
const tool_names = @import("../engine/tool_names.zig");
const bounded_run = @import("../platform/bounded_run.zig");
const telemetry = @import("telemetry.zig");
const tool_result = @import("tool_result.zig");
const repo = @import("../platform/repo.zig");
const exe_path = @import("../platform/exe_path.zig");
const git_symbols = @import("git_symbols.zig");
const git_write = @import("git_write.zig");
const diff_digest = @import("diff_digest.zig");
const read_budget = @import("read_budget.zig");
const wire = @import("wire.zig");
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

/// How much of one git command's stdout a call reads. Past it git is stopped
/// and the reply covers what was read, saying so; it is a variable only so a
/// test can reach the cut without writing a 32 MiB file.
pub var capture_limit: usize = 32 * 1024 * 1024;

threadlocal var git_reason_buf: [320]u8 = undefined;
threadlocal var git_reason_len: usize = 0;
const default_log_count = 20;
const max_log_count = 200;
const max_argv = 28;
const max_status_entries = 40;
const ellipsis = "\u{2026}";

pub const Error = error{
    UnknownGitSubcommand,
    MissingCommit,
    MissingPath,
    InvalidCommit,
    InvalidCount,
    GitCommandFailed,
    GitOutputTooLarge,
    UnknownDetail,
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
    if (text.len == 0 or text.len > 80) return false;
    const base = std.mem.indexOfAny(u8, text, "^~") orelse text.len;
    const head = text[0..base];
    if (!std.mem.eql(u8, head, "HEAD")) {
        if (head.len < 4 or head.len > 64) return false;
        for (head) |c| if (!isHexDigit(c)) return false;
    }
    for (text[base..]) |c| if (c != '^' and c != '~' and !std.ascii.isDigit(c)) return false;
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

pub fn callGit(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, root: ?[]const u8, budget: usize) !ToolResult {
    const sub = try requireString(args, "sub");
    event.label = "git";
    event.file = sub;
    if (git_write.wantsRead(sub, args) and git_write.isReadSub(sub)) return git_write.callRead(gpa, io, sub, args, event, root, budget);
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    git_reason_len = 0;
    render(gpa, io, runtime, root, sub, args, &buffer.writer, budget) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (err != error.GitCommandFailed or git_reason_len == 0) return failure(gpa, &buffer, err, event);
        event.fail(@errorName(err));
        buffer.clearRetainingCapacity();
        try wire.writeErrorMessage(&buffer.writer, @errorName(err), wire.exitCode(err), git_reason_buf[0..git_reason_len]);
        return .{ .text = try tool_result.dupTrim(gpa, buffer.written()), .is_error = true };
    };
    return success(gpa, &buffer);
}

const Options = struct {
    detail: read_budget.Detail,
    symbols_only: bool,
    budget: usize,
    line_start: ?i64,
    line_end: ?i64,
    cursor: ?[]const u8,
    clamped: usize = 0,
    requested: i64 = 0,
    rev: ?[]const u8 = null,
    unborn: bool = false,
    /// git printed more than `capture_limit` and was stopped there.
    cut: bool = false,
};

fn render(gpa: Allocator, io: std.Io, runtime: *Runtime, root: ?[]const u8, sub: []const u8, args: ?Value, w: *Writer, budget: usize) !void {
    const detail = try read_budget.parseDetail(if (args) |a| getString(a, "detail") else null);
    var opts: Options = .{
        .detail = detail,
        .symbols_only = getBool(args, "symbols_only"),
        .budget = budget,
        .line_start = getInt(args, "line_start"),
        .line_end = getInt(args, "line_end"),
        .cursor = if (args) |a| getString(a, "cursor") else null,
    };
    if (opts.cursor) |c| if (!isValidCommit(c)) return error.InvalidCommit;
    const path = if (args) |a| getString(a, "path") else null;
    const place = repo.jail(gpa, io, root, path orelse ".") catch |err| switch (err) {
        error.FileOutsideRepo => if (path == null and root != null) try repo.jail(gpa, io, root, root.?) else return err,
        else => return err,
    };
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

    var count_buf: [24]u8 = undefined;
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
        opts.clamped = clamped;
        opts.requested = requested;
        argv[n] = "log";
        n += 1;
        argv[n] = "--no-color";
        n += 1;
        argv[n] = "-n";
        n += 1;
        argv[n] = std.fmt.bufPrint(&count_buf, "{d}", .{clamped + 1}) catch return error.InvalidCount;
        n += 1;
        argv[n] = "--date=iso-strict";
        n += 1;
        argv[n] = "--pretty=format:%H%x09%ad%x09%s";
        n += 1;
        if (opts.cursor) |c| {
            argv[n] = c;
            n += 1;
        }
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
        argv[n] = "--porcelain";
        n += 1;
        if (opts.line_start) |ls| {
            if (ls < 1) return error.InvalidCount;
            argv[n] = "-L";
            n += 1;
            // Without line_end, one line past a page is asked for, so the
            // reply knows whether a next_line follows.
            argv[n] = if (opts.line_end) |le|
                std.fmt.bufPrint(&count_buf, "{d},{d}", .{ ls, le }) catch return error.InvalidCount
            else
                std.fmt.bufPrint(&count_buf, "{d},+{d}", .{ ls, max_output_lines + 1 }) catch return error.InvalidCount;
            n += 1;
        }
        if (args) |a| if (getString(a, "commit")) |rev| {
            if (!isValidCommit(rev)) return error.InvalidCommit;
            opts.rev = rev;
            argv[n] = rev;
            n += 1;
        };
    } else {
        return error.UnknownGitSubcommand;
    }

    if (path != null and place.rel.len != 0) {
        argv[n] = "--";
        n += 1;
        argv[n] = place.rel;
        n += 1;
    }

    const is_blame = std.mem.eql(u8, sub, "blame");
    var cut = false;
    const result = bounded_run.runHead(gpa, io, .{
        .argv = argv[0..n],
        .cwd = .{ .path = place.root },
        .stdout_limit = .limited(capture_limit),
        .stderr_limit = .limited(max_git_output_bytes),
    }, &cut) catch |err| return if (err == error.StreamTooLong) error.GitOutputTooLarge else error.GitCommandFailed;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    opts.cut = cut;

    const ok = cut or switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        if (std.mem.eql(u8, sub, "status") or std.mem.eql(u8, sub, "diff") or opts.cursor != null or opts.rev != null or !try unbornHead(gpa, io, git, place.root)) {
            noteReason(result.stderr);
            return error.GitCommandFailed;
        }
        if (!std.mem.eql(u8, sub, "log")) return error.NoCommitYet;
        opts.unborn = true;
        var js: std.json.Stringify = .{ .writer = w };
        try writeLog(gpa, &js, path, "", &.{}, opts);
        try w.writeByte('\n');
        return;
    }

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

    // A cut capture ends at the last whole line (for blame, the last whole
    // record); the symbol maps need the whole output, so they are skipped.
    const stdout = if (cut) wholeLines(result.stdout, is_blame) else result.stdout;
    const analyzable = !cut and stdout.len <= max_git_output_bytes;

    if (std.mem.eql(u8, sub, "diff") and analyzable) {
        // An empty rev means the index: `git show :<path>`. For the working
        // tree the new side is read from disk (null rev).
        const sides: git_symbols.Sides = if (getBool(args, "staged"))
            .{ .old_rev = "HEAD", .new_rev = "" }
        else
            .{ .old_rev = "", .new_rev = null };
        summary = git_symbols.analyzeDiff(gpa, io, runtime, git, place.root, sides, stdout) catch null;
    } else if (std.mem.eql(u8, sub, "show") and analyzable) {
        const parent = try std.fmt.allocPrint(gpa, "{s}^", .{show_commit.?});
        defer gpa.free(parent);
        const sides: git_symbols.Sides = .{ .old_rev = parent, .new_rev = show_commit.? };
        summary = git_symbols.analyzeDiff(gpa, io, runtime, git, place.root, sides, stdout) catch null;
    }

    if (is_blame and !cut) blame = git_symbols.analyzeBlame(gpa, io, runtime, git, place.root, place.rel, opts.rev, stdout) catch null;

    try writeResult(gpa, w, sub, path, stdout, annotated, if (summary) |*s| s else null, if (blame) |*b| b else null, opts);
}

/// The longest prefix of a cut capture that ends on a whole line; for blame
/// porcelain, on the last whole record (its tab-led text line).
fn wholeLines(text: []const u8, porcelain: bool) []const u8 {
    var end = text.len;
    while (end > 0) {
        const nl = std.mem.lastIndexOfScalar(u8, text[0..end], '\n') orelse return text[0..0];
        const start = if (std.mem.lastIndexOfScalar(u8, text[0..nl], '\n')) |p| p + 1 else 0;
        if (!porcelain or (nl > start and text[start] == '\t')) return text[0 .. nl + 1];
        end = nl;
    }
    return text[0..0];
}

fn unbornHead(gpa: Allocator, io: std.Io, git: []const u8, root: []const u8) !bool {
    {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        if (try @import("../platform/git_native.zig").headOid(arena, io, root)) |state| switch (state) {
            .oid => |oid| {
                var opened = (try @import("../platform/git_native.zig").Repo.open(arena, io, root)) orelse return false;
                if (try opened.store.read(oid)) |object| {
                    if (object.kind == .commit) return false;
                }
            },
            .unborn => {},
        };
    }
    const probe = bounded_run.run(gpa, io, .{
        .argv = &.{ git, "rev-parse", "--verify", "-q", "HEAD^{commit}" },
        .cwd = .{ .path = root },
        .stdout_limit = .limited(max_git_output_bytes),
        .stderr_limit = .limited(max_git_output_bytes),
    }) catch return false;
    defer gpa.free(probe.stdout);
    defer gpa.free(probe.stderr);
    const status = switch (probe.term) {
        .exited => |code| code,
        else => return false,
    };
    if (status == 0) return false;
    const inside = bounded_run.run(gpa, io, .{
        .argv = &.{ git, "rev-parse", "--git-dir" },
        .cwd = .{ .path = root },
        .stdout_limit = .limited(max_git_output_bytes),
        .stderr_limit = .limited(max_git_output_bytes),
    }) catch return false;
    defer gpa.free(inside.stdout);
    defer gpa.free(inside.stderr);
    return switch (inside.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn noteReason(stderr: []const u8) void {
    const trimmed = std.mem.trim(u8, stderr, " \r\n\t");
    const first = trimmed[0 .. std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len];
    const line = std.mem.trimEnd(u8, first, "\r");
    const kept = line[0..@min(line.len, git_reason_buf.len)];
    @memcpy(git_reason_buf[0..kept.len], kept);
    git_reason_len = kept.len;
}

/// Column ② — proof-aware reading: the full object ids of every commit that
/// carries an emetgate receipt note (refs/notes/emetgate). Used to flag each
/// log line as receipt-backed or not. Best-effort: a missing notes ref yields
/// an empty set rather than an error.
fn annotatedCommits(gpa: Allocator, io: std.Io, git: []const u8, root: []const u8) ![]const []const u8 {
    const argv = [_][]const u8{ git, "--no-pager", "notes", "--ref=emetgate", "list" };
    const limit: std.Io.Limit = .limited(max_git_output_bytes);
    const result = bounded_run.run(gpa, io, .{
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

fn viewLabel(opts: Options) []const u8 {
    return if (opts.detail == .full) "full" else "compact";
}

fn writeBase(js: *std.json.Stringify, sub: []const u8, path: ?[]const u8, opts: Options) !void {
    try js.beginObject();
    try js.objectField("sub");
    try js.write(sub);
    if (path) |p| {
        try js.objectField("path");
        try js.write(p);
    }
    try js.objectField("view");
    try js.write(viewLabel(opts));
}

fn writeRaw(gpa: Allocator, js: *std.json.Stringify, stdout: []const u8) !void {
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    var kept: std.ArrayList([]const u8) = .empty;
    defer kept.deinit(gpa);
    var total: usize = 0;
    while (lines.next()) |line| {
        total += 1;
        if (kept.items.len < max_output_lines) try kept.append(gpa, line);
    }
    const truncated = total > kept.items.len;
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
}

fn writeResult(gpa: Allocator, w: *Writer, sub: []const u8, path: ?[]const u8, stdout: []const u8, annotated: []const []const u8, summary: ?*const git_symbols.Summary, blame: ?*const git_symbols.BlameReport, opts: Options) !void {
    var js: std.json.Stringify = .{ .writer = w };
    if (std.mem.eql(u8, sub, "log")) {
        try writeLog(gpa, &js, path, stdout, annotated, opts);
    } else if (std.mem.eql(u8, sub, "status")) {
        try writeStatus(gpa, &js, path, stdout, opts);
    } else if (std.mem.eql(u8, sub, "diff") or std.mem.eql(u8, sub, "show")) {
        try writeDiffShow(gpa, &js, sub, path, stdout, summary, opts);
    } else if (std.mem.eql(u8, sub, "blame")) {
        try writeBlame(gpa, &js, path, stdout, blame, opts);
    } else {
        try writeBase(&js, sub, path, opts);
        try writeRaw(gpa, &js, stdout);
        try js.endObject();
    }
    try w.writeByte('\n');
}

fn oidOf(line: []const u8) []const u8 {
    const tab = std.mem.indexOfScalar(u8, line, '\t') orelse line.len;
    return line[0..tab];
}

fn writeLog(gpa: Allocator, js: *std.json.Stringify, path: ?[]const u8, stdout: []const u8, annotated: []const []const u8, opts: Options) !void {
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    var rows: std.ArrayList([]const u8) = .empty;
    defer rows.deinit(gpa);
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try rows.append(gpa, line);
    }

    try writeBase(js, "log", path, opts);
    try js.objectField("commits");
    try js.beginArray();
    var shown: usize = 0;
    var size: usize = 0;
    var next_cursor: ?[]const u8 = null;
    for (rows.items, 0..) |line, idx| {
        if (opts.clamped != 0 and idx >= opts.clamped) {
            next_cursor = oidOf(line);
            break;
        }
        if (opts.detail != .full and shown > 0 and size > opts.budget) {
            next_cursor = oidOf(line);
            break;
        }
        const oid = oidOf(line);
        var date: []const u8 = "";
        var subject: []const u8 = "";
        if (std.mem.indexOfScalar(u8, line, '\t')) |t1| {
            const rest = line[t1 + 1 ..];
            if (std.mem.indexOfScalar(u8, rest, '\t')) |t2| {
                date = rest[0..t2];
                subject = rest[t2 + 1 ..];
            } else date = rest;
        }
        try js.beginObject();
        try js.objectField("commit");
        try js.write(oid);
        try js.objectField("date");
        try js.write(date);
        try js.objectField("subject");
        try js.write(subject);
        try js.objectField("verification");
        try js.write(if (isAnnotated(annotated, oid)) "receipt" else "no_receipt");
        try js.endObject();
        shown += 1;
        size += line.len + 48;
    }
    try js.endArray();
    try js.objectField("commits_shown");
    try js.write(shown);
    try js.objectField("verification_note");
    try js.write("receipt means a receipt note is attached, not that it holds; emetgate verify <commit> checks it");
    if (opts.clamped != 0 and opts.requested != @as(i64, @intCast(opts.clamped))) {
        try js.objectField("n_used");
        try js.write(opts.clamped);
    }
    if (opts.unborn) {
        try js.objectField("note");
        try js.write("no commits yet");
    }
    if (next_cursor) |c| {
        try js.objectField("next_cursor");
        try js.write(c);
        try js.objectField("note");
        try js.write("more commits follow; pass cursor:<next_cursor> to page from there");
    }
    if (opts.detail == .full) try writeRaw(gpa, js, stdout);
    try js.endObject();
}

const StatusEntry = struct { code: u8, path: []const u8 };

fn statusPath(field: []const u8) []const u8 {
    if (std.mem.indexOf(u8, field, " -> ")) |i| return field[i + 4 ..];
    return field;
}

fn writeEntryGroup(js: *std.json.Stringify, name: []const u8, entries: []const StatusEntry) !void {
    try js.objectField(name);
    try js.beginObject();
    try js.objectField("count");
    try js.write(entries.len);
    try js.objectField("files");
    try js.beginArray();
    const cap = @min(entries.len, max_status_entries);
    for (entries[0..cap]) |e| {
        try js.beginObject();
        try js.objectField("code");
        const code = [_]u8{e.code};
        try js.write(&code);
        try js.objectField("path");
        try js.write(e.path);
        try js.endObject();
    }
    try js.endArray();
    if (entries.len > cap) {
        try js.objectField("more");
        try js.write(entries.len - cap);
    }
    try js.endObject();
}

fn writeStatus(gpa: Allocator, js: *std.json.Stringify, path: ?[]const u8, stdout: []const u8, opts: Options) !void {
    var staged: std.ArrayList(StatusEntry) = .empty;
    defer staged.deinit(gpa);
    var unstaged: std.ArrayList(StatusEntry) = .empty;
    defer unstaged.deinit(gpa);
    var untracked_files: std.ArrayList([]const u8) = .empty;
    defer untracked_files.deinit(gpa);
    var conflicted: std.ArrayList([]const u8) = .empty;
    defer conflicted.deinit(gpa);
    var dir_names: std.ArrayList([]const u8) = .empty;
    defer dir_names.deinit(gpa);
    var dir_counts: std.ArrayList(usize) = .empty;
    defer dir_counts.deinit(gpa);

    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        if (line.len < 4) continue;
        const x = line[0];
        const y = line[1];
        const p = statusPath(line[3..]);
        if (x == '?' and y == '?') {
            if (std.mem.indexOfScalar(u8, p, '/')) |slash| {
                const dir = p[0..slash];
                var found = false;
                for (dir_names.items, 0..) |d, i| {
                    if (std.mem.eql(u8, d, dir)) {
                        dir_counts.items[i] += 1;
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try dir_names.append(gpa, dir);
                    try dir_counts.append(gpa, 1);
                }
            } else {
                try untracked_files.append(gpa, p);
            }
            continue;
        }
        if (x == 'U' or y == 'U' or (x == y and (x == 'A' or x == 'D'))) {
            try conflicted.append(gpa, p);
            continue;
        }
        if (x != ' ' and x != '?') try staged.append(gpa, .{ .code = x, .path = p });
        if (y != ' ' and y != '?') try unstaged.append(gpa, .{ .code = y, .path = p });
    }

    const untracked_total = untracked_files.items.len + dir_counts.items.len;
    const clean = staged.items.len == 0 and unstaged.items.len == 0 and untracked_total == 0 and conflicted.items.len == 0;

    try writeBase(js, "status", path, opts);
    try js.objectField("clean");
    try js.write(clean);
    if (conflicted.items.len != 0) {
        try js.objectField("conflicted");
        try js.beginArray();
        for (conflicted.items[0..@min(conflicted.items.len, max_status_entries)]) |p| try js.write(p);
        try js.endArray();
    }
    try writeEntryGroup(js, "staged", staged.items);
    try writeEntryGroup(js, "unstaged", unstaged.items);

    try js.objectField("untracked");
    try js.beginObject();
    try js.objectField("count");
    try js.write(untracked_total);
    try js.objectField("files");
    try js.beginArray();
    const fcap = @min(untracked_files.items.len, max_status_entries);
    for (untracked_files.items[0..fcap]) |p| try js.write(p);
    try js.endArray();
    if (untracked_files.items.len > fcap) {
        try js.objectField("files_more");
        try js.write(untracked_files.items.len - fcap);
    }
    if (dir_names.items.len != 0) {
        try js.objectField("dirs");
        try js.beginArray();
        for (dir_names.items, dir_counts.items) |d, c| {
            try js.beginObject();
            try js.objectField("dir");
            try js.write(d);
            try js.objectField("count");
            try js.write(c);
            try js.endObject();
        }
        try js.endArray();
    }
    try js.endObject();

    if (opts.detail == .full) try writeRaw(gpa, js, stdout);
    try js.endObject();
}

// --- bounded replies -------------------------------------------------------
//
// Every cut reply names where the rest starts, in a parameter the same tool
// takes: `next_line` for `line_start`, `next_cursor` for `cursor`. The two
// helpers below are the whole contract for line-numbered text: `pageLines`
// picks one window under a byte budget, and `writePageFields` writes the
// fields that let the next call continue from it.

/// One window of a line-numbered text: lines `first`..`last` (1-based,
/// inclusive; `last` is first - 1 when nothing was shown), `next` is the first
/// line the window left out, or null when it reached the end of what was asked.
const Page = struct {
    first: usize,
    last: usize,
    next: ?usize,
    total: usize,
    text: []u8,
    /// One line longer than the whole budget was shortened to fit.
    line_shortened: bool,

    fn deinit(self: Page, gpa: Allocator) void {
        gpa.free(self.text);
    }
};

/// Picks lines `first`..`last_wanted` of `lines` that fit `byte_budget` and
/// `max_lines`. When the budget, not the end, stops it, the window is cut back
/// to the last line `boundary` accepts, so a hunk or file is not split when it
/// fits. At least one line is always shown, shortened if it alone is over the
/// budget, so a continuation always moves forward.
fn pageLines(gpa: Allocator, lines: []const []const u8, first: usize, last_wanted: usize, byte_budget: usize, max_lines: usize, boundary: *const fn ([]const u8) bool) !Page {
    const total = lines.len;
    const start = @max(first, 1);
    if (start > total) return .{ .first = start, .last = start - 1, .next = null, .total = total, .text = try gpa.dupe(u8, ""), .line_shortened = false };
    const stop = @min(total, @max(last_wanted, start));
    var end = start - 1;
    var size: usize = 0;
    while (end < stop and end - (start - 1) < max_lines and size + lines[end].len + 1 <= byte_budget) : (end += 1) {
        size += lines[end].len + 1;
    }
    if (end < stop) {
        // Back to a boundary only when that keeps at least half the page:
        // one hunk bigger than the budget is cut at a line instead.
        var b = end;
        while (b > start and !boundary(lines[b])) b -= 1;
        if (b > start and (b - (start - 1)) * 2 >= end - (start - 1)) end = b;
    }
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var shortened = false;
    if (end < start) {
        const line = lines[start - 1];
        var keep = @min(line.len, byte_budget);
        while (keep > 0 and keep < line.len and (line[keep] & 0xC0) == 0x80) keep -= 1;
        try out.writer.writeAll(line[0..keep]);
        try out.writer.writeAll(ellipsis);
        shortened = true;
        end = start;
    } else {
        for (lines[start - 1 .. end], 0..) |line, i| {
            if (i != 0) try out.writer.writeByte('\n');
            try out.writer.writeAll(line);
        }
    }
    const next: ?usize = if (end < stop) end + 1 else null;
    return .{ .first = start, .last = end, .next = next, .total = total, .text = try gpa.dupe(u8, out.written()), .line_shortened = shortened };
}

/// The fields of a page reply: the text, which lines it holds, and the line to
/// pass as `line_start` for the rest. `captured_cut` says git printed more than
/// `capture_limit`, so lines past `lines_total` exist but no call reaches them.
fn writePageFields(js: *std.json.Stringify, page: Page, captured_cut: bool) !void {
    try js.objectField("output");
    try js.write(page.text);
    try js.objectField("line_start");
    try js.write(page.first);
    try js.objectField("line_end");
    try js.write(page.last);
    try js.objectField("lines_total");
    try js.write(page.total);
    if (page.line_shortened) {
        try js.objectField("line_shortened");
        try js.write(true);
    }
    if (page.next) |next| {
        try js.objectField("next_line");
        try js.write(next);
    }
    if (captured_cut) {
        try js.objectField("capture_cut");
        try js.write(true);
    }
}

fn splitLines(gpa: Allocator, text: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    const body = if (std.mem.endsWith(u8, text, "\n")) text[0 .. text.len - 1] else text;
    if (body.len == 0) return list.toOwnedSlice(gpa);
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |l| try list.append(gpa, l);
    return list.toOwnedSlice(gpa);
}

fn isDiffBoundary(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "@@") or std.mem.startsWith(u8, line, "diff --git ");
}

/// One file of a raw diff: its path, the raw line its `diff --git` header is
/// on, and its added and removed line counts.
const FileStat = struct { path: []const u8, line: usize, added: usize, removed: usize };

fn diffPath(header: []const u8) []const u8 {
    const at = std.mem.lastIndexOf(u8, header, " b/") orelse std.mem.lastIndexOf(u8, header, " \"b/") orelse return header["diff --git ".len..];
    const rest = header[at + 1 ..];
    const unquoted = if (rest.len >= 2 and rest[0] == '"' and rest[rest.len - 1] == '"') rest[1 .. rest.len - 1] else rest;
    return if (std.mem.startsWith(u8, unquoted, "b/")) unquoted[2..] else unquoted;
}

fn diffFiles(gpa: Allocator, lines: []const []const u8) ![]FileStat {
    var files: std.ArrayList(FileStat) = .empty;
    errdefer files.deinit(gpa);
    var in_hunk = false;
    for (lines, 0..) |line, i| {
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            try files.append(gpa, .{ .path = diffPath(std.mem.trimEnd(u8, line, "\r")), .line = i + 1, .added = 0, .removed = 0 });
            in_hunk = false;
            continue;
        }
        if (files.items.len == 0) continue;
        if (std.mem.startsWith(u8, line, "@@")) {
            in_hunk = true;
            continue;
        }
        if (!in_hunk or line.len == 0) continue;
        const f = &files.items[files.items.len - 1];
        if (line[0] == '+') f.added += 1 else if (line[0] == '-') f.removed += 1;
    }
    return files.toOwnedSlice(gpa);
}

/// Writes the stat of every file of the diff, as many as fit `budget` bytes,
/// and returns the bytes used. Each file names the raw `line` its diff starts
/// on, a `line_start` for it; `files_more` counts those left out.
fn writeFileStats(js: *std.json.Stringify, files: []const FileStat, budget: usize) !usize {
    var added: usize = 0;
    var removed: usize = 0;
    for (files) |f| {
        added += f.added;
        removed += f.removed;
    }
    try js.objectField("files_total");
    try js.write(files.len);
    try js.objectField("added");
    try js.write(added);
    try js.objectField("removed");
    try js.write(removed);
    try js.objectField("files");
    try js.beginArray();
    var used: usize = 0;
    var shown: usize = 0;
    for (files) |f| {
        const cost = f.path.len + 64;
        if (shown != 0 and used + cost > budget) break;
        used += cost;
        shown += 1;
        try js.beginObject();
        try js.objectField("path");
        try js.write(f.path);
        try js.objectField("added");
        try js.write(f.added);
        try js.objectField("removed");
        try js.write(f.removed);
        try js.objectField("line");
        try js.write(f.line);
        try js.endObject();
    }
    try js.endArray();
    if (shown < files.len) {
        try js.objectField("files_more");
        try js.write(files.len - shown);
    }
    return used + 80;
}

const Folded = struct {
    text: []u8,
    elided: bool,
    elided_start: u32,
    elided_end: u32,
    lines_shown: usize,
    lines_total: usize,
    hunks_elided: usize,
    /// The raw diff line where what the fold left out begins.
    next_line: usize,

    fn deinit(self: Folded, gpa: Allocator) void {
        gpa.free(self.text);
    }
};

fn isHunkBoundary(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "@");
}

fn hunkNewStart(line: []const u8) ?usize {
    const plus = std.mem.indexOfScalar(u8, line, '+') orelse return null;
    var end = plus + 1;
    while (end < line.len and std.ascii.isDigit(line[end])) end += 1;
    return std.fmt.parseInt(usize, line[plus + 1 .. end], 10) catch null;
}

fn isCondensedSummary(line: []const u8) bool {
    return line.len != 0 and std.ascii.isDigit(line[0]) and std.mem.indexOf(u8, line, " files +") != null;
}

/// Maps the first line a fold of the condensed diff left out to a raw diff
/// line: the start of the hunk that holds it (or of its file), so a
/// `line_start` call goes on from there, repeating at most the part of that
/// hunk the fold already showed.
fn rawLineOfFold(condensed: []const []const u8, keep: usize, raw: []const []const u8, files: []const FileStat) usize {
    var summary: ?usize = null;
    for (condensed[0..keep], 0..) |l, i| if (isCondensedSummary(l)) {
        summary = i;
        break;
    };
    const after = (summary orelse return 1) + 1;
    if (keep < after) return 1;
    var headers: usize = 0;
    for (condensed[after .. keep + 1]) |l| {
        if (l.len == 0 or (l[0] != '@' and l[0] != '-' and l[0] != '+')) headers += 1;
    }
    if (headers == 0 or headers > files.len) return 1;
    const file = files[headers - 1];
    // The block the cut line belongs to: the nearest `@` line above it.
    var at = keep;
    while (at > after and condensed[at].len != 0 and (condensed[at][0] == '-' or condensed[at][0] == '+')) at -= 1;
    const first = condensed[at];
    if (first.len == 0 or first[0] != '@') return file.line;
    var digits: usize = 1;
    while (digits < first.len and std.ascii.isDigit(first[digits])) digits += 1;
    const wanted = std.fmt.parseInt(usize, first[1..digits], 10) catch return file.line;
    const file_end = if (headers < files.len) files[headers].line - 1 else raw.len;
    var best = file.line;
    var i = file.line;
    while (i < file_end) : (i += 1) {
        const l = raw[i];
        if (!std.mem.startsWith(u8, l, "@@")) continue;
        const new_start = hunkNewStart(l) orelse continue;
        if (new_start > wanted) break;
        best = i + 1;
    }
    return best;
}

fn foldDiff(gpa: Allocator, text: []const u8, budget: usize, raw: []const []const u8, files: []const FileStat) !Folded {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try lines.append(gpa, l);
    const total = lines.items.len;

    var size: usize = 0;
    var fit: usize = 0;
    while (fit < total and size + lines.items[fit].len + 1 <= budget) : (fit += 1) {
        size += lines.items[fit].len + 1;
    }
    if (fit >= total) {
        return .{ .text = try gpa.dupe(u8, text), .elided = false, .elided_start = 0, .elided_end = 0, .lines_shown = total, .lines_total = total, .hunks_elided = 0, .next_line = 0 };
    }
    var keep = fit;
    while (keep > 0 and !isHunkBoundary(lines.items[keep])) keep -= 1;
    if (keep * 2 < fit) keep = fit;

    var hunks_elided: usize = 0;
    for (lines.items[keep..]) |l| {
        if (std.mem.startsWith(u8, l, "@")) hunks_elided += 1;
    }
    const remaining = total - keep;
    const next_line = rawLineOfFold(lines.items, keep, raw, files);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (lines.items[0..keep], 0..) |l, i| {
        if (i != 0) try out.writer.writeByte('\n');
        try out.writer.writeAll(l);
    }
    if (keep != 0) try out.writer.writeByte('\n');
    try out.writer.print(ellipsis ++ " {d} lines in {d} hunks elided; pass line_start:{d} for the raw diff from there, or path for one file", .{ remaining, hunks_elided, next_line });

    return .{
        .text = try gpa.dupe(u8, out.written()),
        .elided = true,
        .elided_start = @intCast(keep + 1),
        .elided_end = @intCast(total),
        .lines_shown = keep,
        .lines_total = total,
        .hunks_elided = hunks_elided,
        .next_line = next_line,
    };
}

const page_note = "raw diff lines line_start..line_end of lines_total; pass line_start:<next_line> for the next page, or path:<file> from files for one file";

fn writeDiffShow(gpa: Allocator, js: *std.json.Stringify, sub: []const u8, path: ?[]const u8, stdout: []const u8, summary: ?*const git_symbols.Summary, opts: Options) !void {
    try writeBase(js, sub, path, opts);
    if (opts.symbols_only or opts.detail == .full) {
        if (summary) |s| try writeSymbolSummary(js, s.*);
    }
    if (summary == null and stdout.len > max_git_output_bytes) {
        try js.objectField("symbol_changes_skipped");
        try js.write("the diff is over 256 KiB; pass path for one file to map its symbols");
    }

    if (opts.symbols_only) {
        try js.objectField("symbols_only");
        try js.write(true);
        try js.objectField("note");
        try js.write("symbol summary only; no raw diff bytes — pass detail:\"full\" or drop symbols_only for hunks");
        try js.endObject();
        return;
    }

    const raw = try splitLines(gpa, stdout);
    defer gpa.free(raw);

    if (opts.detail == .full and opts.line_start == null) {
        try writeRaw(gpa, js, stdout);
        if (raw.len > max_output_lines) {
            try js.objectField("next_line");
            try js.write(max_output_lines + 1);
            try js.objectField("note");
            try js.write("raw diff cut at 800 lines; pass line_start:<next_line> with detail:\"full\" for the next 800");
        }
        try js.endObject();
        return;
    }

    const files = try diffFiles(gpa, raw);
    defer gpa.free(files);

    if (opts.line_start == null and !opts.cut and stdout.len <= max_git_output_bytes) {
        const condensed = try diff_digest.condense(gpa, stdout, summary);
        defer gpa.free(condensed);
        if (condensed.len <= opts.budget) {
            try js.objectField("output");
            try js.write(condensed);
            try js.endObject();
            return;
        }
        const stat_used = try writeFileStats(js, files, opts.budget / 4);
        const folded = try foldDiff(gpa, condensed, opts.budget -| stat_used, raw, files);
        defer folded.deinit(gpa);
        try js.objectField("output");
        try js.write(folded.text);
        try js.objectField("lines_shown");
        try js.write(folded.lines_shown);
        try js.objectField("lines_total");
        try js.write(folded.lines_total);
        try js.objectField("chars");
        try js.write(stdout.len);
        try js.objectField("budget");
        try js.write(opts.budget);
        try js.objectField("elided");
        try js.beginArray();
        try js.beginObject();
        try js.objectField("line_start");
        try js.write(folded.elided_start);
        try js.objectField("line_end");
        try js.write(folded.elided_end);
        try js.objectField("lines");
        try js.write(folded.elided_end - folded.elided_start + 1);
        try js.objectField("hunks");
        try js.write(folded.hunks_elided);
        try js.endObject();
        try js.endArray();
        try js.objectField("next_line");
        try js.write(folded.next_line);
        try js.objectField("note");
        try js.write("compact diff folded under the read budget; files gives every file's stat and the raw line it starts on; pass line_start:<next_line> for the raw diff from where the fold cut, path:<file> for one file, or symbols_only:true for symbol_changes only");
        try js.endObject();
        return;
    }

    // A page of the raw diff: asked for with line_start, or the first page
    // of a diff too big to condense.
    const first_page = opts.line_start == null;
    const stat_used = if (first_page) try writeFileStats(js, files, opts.budget / 4) else 0;
    const from: usize = if (opts.line_start) |ls| @intCast(@max(ls, 1)) else 1;
    const to: usize = if (opts.line_end) |le| @intCast(@max(le, 0)) else std.math.maxInt(usize);
    const byte_budget = if (opts.detail == .full) std.math.maxInt(usize) else opts.budget -| stat_used;
    const max_lines: usize = if (opts.detail == .full) max_output_lines else std.math.maxInt(usize);
    const page = try pageLines(gpa, raw, from, to, byte_budget, max_lines, isDiffBoundary);
    defer page.deinit(gpa);
    try writePageFields(js, page, opts.cut);
    try js.objectField("note");
    if (opts.cut)
        try js.write("git printed more than 32 MiB and was stopped; lines_total counts what was read. " ++ page_note)
    else if (page.first > page.total)
        try js.write("line_start is past the end of the diff (lines_total lines)")
    else
        try js.write(page_note);
    try js.endObject();
}

fn writeBlame(gpa: Allocator, js: *std.json.Stringify, path: ?[]const u8, porcelain: []const u8, blame: ?*const git_symbols.BlameReport, opts: Options) !void {
    try writeBase(js, "blame", path, opts);
    if (opts.rev) |rev| {
        try js.objectField("commit");
        try js.write(rev);
    }
    const line_budget = if (opts.detail == .full) std.math.maxInt(usize) else opts.budget;
    const report = blame orelse {
        // No symbol map: the porcelain was cut at capture_limit, or the
        // file's language has no profile. Per-line text, paged by next_line.
        const next = try writeBlameLines(gpa, js, porcelain, line_budget, opts.cut);
        try js.objectField("note");
        if (opts.cut)
            try js.write("git blame printed more than 32 MiB and was stopped, so there is no symbol map; output lines are: line commit text; pass line_start:<next_line> for the next lines")
        else if (next != null)
            try js.write("output lines are: line commit text; pass line_start:<next_line> for the next lines")
        else
            try js.write("output lines are: line commit text");
        try js.endObject();
        return;
    };
    const per_line = opts.detail == .full or opts.line_start != null;
    const symbol_share = if (opts.symbols_only) opts.budget else opts.budget / 2;
    const symbols_left = try writeBlameSummary(js, report.*, symbol_share);
    var ranges_left: usize = 0;
    var next_line: ?u32 = null;
    if (opts.symbols_only) {} else if (per_line) {
        next_line = try writeBlameLines(gpa, js, porcelain, if (opts.detail == .full) line_budget else opts.budget - symbol_share, false);
    } else {
        ranges_left = try writeBlameRanges(gpa, js, report.lines, opts.budget - symbol_share);
    }
    try js.objectField("note");
    if (ranges_left != 0 or next_line != null)
        try js.write("cut at the read budget; pass line_start:<next_line> for the next lines")
    else if (symbols_left != 0)
        try js.write("symbol_blame cut at the read budget; symbols_only:true gives it the whole budget, or pass line_start/line_end to blame a smaller range")
    else if (per_line)
        try js.write("output lines are: line commit text")
    else
        try js.write("ranges are first-last lines and a commit from commits; pass line_start/line_end for the text");
    try js.endObject();
}

fn shortSha(sha: []const u8) []const u8 {
    return sha[0..@min(sha.len, 8)];
}

fn writeBlameRanges(gpa: Allocator, js: *std.json.Stringify, lines: []const ?git_symbols.LineInfo, budget: usize) !usize {
    var cited: std.StringArrayHashMapUnmanaged(git_symbols.LineInfo) = .empty;
    defer cited.deinit(gpa);
    var line_buf: [64]u8 = undefined;
    var used: usize = 0;
    var left: usize = 0;
    var next_line: usize = 0;
    try js.objectField("ranges");
    try js.beginArray();
    var first: usize = 0;
    while (first < lines.len) {
        const info = lines[first] orelse {
            first += 1;
            continue;
        };
        var last = first;
        while (last + 1 < lines.len) : (last += 1) {
            const next = lines[last + 1] orelse break;
            if (!std.mem.eql(u8, next.sha, info.sha)) break;
        }
        const sha = shortSha(info.sha);
        const range = std.fmt.bufPrint(&line_buf, "{d}-{d} {s}", .{ first + 1, last + 1, sha }) catch unreachable;
        const cost = range.len + 3 + if (cited.contains(sha)) 0 else sha.len + info.author.len + info.summary.len + 20;
        const fits = used + cost <= budget;
        if (!fits) {
            if (left == 0) next_line = first + 1;
            left += 1;
        } else {
            used += cost;
            try js.write(range);
            try cited.put(gpa, sha, info);
        }
        first = last + 1;
    }
    try js.endArray();
    try js.objectField("commits");
    try js.beginObject();
    var date_buf: [16]u8 = undefined;
    var text_buf: std.Io.Writer.Allocating = .init(gpa);
    defer text_buf.deinit();
    var it = cited.iterator();
    while (it.next()) |entry| {
        text_buf.clearRetainingCapacity();
        try text_buf.writer.print("{s} {s} {s}", .{ entry.value_ptr.author, isoDate(&date_buf, entry.value_ptr.time), entry.value_ptr.summary });
        try js.objectField(entry.key_ptr.*);
        try js.write(text_buf.written());
    }
    try js.endObject();
    if (left != 0) {
        try js.objectField("ranges_left");
        try js.write(left);
        try js.objectField("next_line");
        try js.write(next_line);
    }
    return left;
}

fn isoDate(buf: *[16]u8, time: i64) []const u8 {
    const secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(time, 0)) };
    const year_day = secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year_day.year, month_day.month.numeric(), @as(u32, month_day.day_index) + 1 }) catch "";
}

/// Writes blame porcelain as `line commit text` lines, a contiguous run
/// from the first under `budget` and 800 lines, and returns (and writes) the
/// file line the next call starts at with `line_start`, when lines were left.
fn writeBlameLines(gpa: Allocator, js: *std.json.Stringify, porcelain: []const u8, budget: usize, captured_cut: bool) !?u32 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var sha: []const u8 = "";
    var final_line: u32 = 0;
    var shown: usize = 0;
    var total: usize = 0;
    var next_line: ?u32 = null;
    var last_line: u32 = 0;
    var lines = std.mem.splitScalar(u8, porcelain, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len != 0 and line[0] == '\t') {
            total += 1;
            last_line = final_line;
            if (next_line != null) continue;
            const text = line[1..];
            const head_len = std.fmt.count("{d} {s} ", .{ final_line, shortSha(sha) });
            if (shown < max_output_lines and out.written().len + head_len + text.len + 1 <= budget) {
                if (shown != 0) try out.writer.writeByte('\n');
                try out.writer.print("{d} {s} {s}", .{ final_line, shortSha(sha), text });
                shown += 1;
            } else if (shown == 0) {
                // One line over the whole budget: shortened, so the next
                // call still moves on.
                var keep = @min(text.len, budget -| head_len);
                while (keep > 0 and keep < text.len and (text[keep] & 0xC0) == 0x80) keep -= 1;
                try out.writer.print("{d} {s} {s}" ++ ellipsis, .{ final_line, shortSha(sha), text[0..keep] });
                shown += 1;
            } else next_line = final_line;
        } else if (git_symbols.headerStart(line)) |h| {
            sha = h.sha;
            final_line = h.final_line;
        }
    }
    if (next_line == null and captured_cut and total != 0) next_line = last_line + 1;
    try js.objectField("output");
    try js.write(out.written());
    try js.objectField("lines_shown");
    try js.write(shown);
    if (!captured_cut) {
        try js.objectField("lines_total");
        try js.write(total);
    } else {
        try js.objectField("capture_cut");
        try js.write(true);
    }
    try js.objectField("truncated");
    try js.write(next_line != null);
    if (next_line) |n| {
        try js.objectField("next_line");
        try js.write(n);
    }
    return next_line;
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
        if (!file.mapped) {
            try js.objectField("mapped");
            try js.write(false);
        }
        if (file.non_symbol_change) {
            try js.objectField("non_symbol_change");
            try js.write(true);
        }
        if (file.note) |note| {
            try js.objectField("note");
            try js.write(note);
        }
        if (file.symbols.len != 0) try js.objectField("symbols");
        if (file.symbols.len != 0) try js.beginArray();
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
        if (file.symbols.len != 0) try js.endArray();
        try js.endObject();
    }
    try js.endArray();
    if (summary.truncated) {
        try js.objectField("symbol_changes_truncated");
        try js.write(true);
    }
}

fn writeBlameSummary(js: *std.json.Stringify, blame: git_symbols.BlameReport, budget: usize) !usize {
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
    var used: usize = 0;
    var left: usize = 0;
    for (blame.symbols) |sym| {
        const cost = sym.ref.len + sym.kind.len + sym.commit.len + sym.summary.len + sym.author.len + 110;
        if (used + cost > budget) {
            left += 1;
            continue;
        }
        used += cost;
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
    if (left != 0) {
        try js.objectField("symbols_left");
        try js.write(left);
    }
    try js.endObject();
    return left;
}
