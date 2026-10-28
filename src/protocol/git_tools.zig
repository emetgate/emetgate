const std = @import("std");
const bounded_run = @import("../platform/bounded_run.zig");
const telemetry = @import("telemetry.zig");
const tool_result = @import("tool_result.zig");
const repo = @import("../platform/repo.zig");
const exe_path = @import("../platform/exe_path.zig");
const git_symbols = @import("git_symbols.zig");
const git_write = @import("git_write.zig");
const diff_digest = @import("diff_digest.zig");
const read_budget = @import("read_budget.zig");
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

pub fn callGit(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, root: ?[]const u8, budget: usize) !ToolResult {
    const sub = try requireString(args, "sub");
    event.label = "git";
    event.file = sub;
    if (git_write.wantsRead(sub, args) and git_write.isReadSub(sub)) return git_write.callRead(gpa, io, sub, args, event, root, budget);
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    render(gpa, io, runtime, root, sub, args, &buffer.writer, budget) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err, event);
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

    var count_buf: [24]u8 = undefined;
    var show_commit: ?[]const u8 = null;
    var blame_range: ?[]const u8 = null;
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
        if (opts.line_start) |ls| {
            const le = opts.line_end orelse ls;
            argv[n] = "-L";
            n += 1;
            argv[n] = std.fmt.bufPrint(&count_buf, "{d},{d}", .{ ls, le }) catch return error.InvalidCount;
            blame_range = argv[n];
            n += 1;
        }
    } else {
        return error.UnknownGitSubcommand;
    }

    if (path != null and place.rel.len != 0) {
        argv[n] = "--";
        n += 1;
        argv[n] = place.rel;
        n += 1;
    }

    const result = bounded_run.run(gpa, io, .{
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
        porcelain = blamePorcelain(gpa, io, git, place.root, place.rel, blame_range) catch null;
        if (porcelain) |text|
            blame = git_symbols.analyzeBlame(gpa, io, runtime, place.root, place.rel, text) catch null;
    }

    try writeResult(gpa, w, sub, path, result.stdout, annotated, if (summary) |*s| s else null, if (blame) |*b| b else null, opts);
}

/// Second blame pass in machine-readable form, used only to map symbols to the
/// commit that last changed them. Best-effort: a failure returns null and the
/// raw blame stays the whole answer.
fn blamePorcelain(gpa: Allocator, io: std.Io, git: []const u8, root: []const u8, rel: []const u8, range: ?[]const u8) !?[]u8 {
    const whole = [_][]const u8{ git, "--no-pager", "blame", "--line-porcelain", "--", rel };
    const windowed = [_][]const u8{ git, "--no-pager", "blame", "--line-porcelain", "-L", range orelse "", "--", rel };
    const result = bounded_run.run(gpa, io, .{
        .argv = if (range != null) &windowed else &whole,
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

const Folded = struct {
    text: []u8,
    elided: bool,
    elided_start: u32,
    elided_end: u32,
    lines_shown: usize,
    lines_total: usize,
    hunks_elided: usize,

    fn deinit(self: Folded, gpa: Allocator) void {
        gpa.free(self.text);
    }
};

fn isHunkBoundary(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "@");
}

fn foldDiff(gpa: Allocator, text: []const u8, budget: usize) !Folded {
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
        return .{ .text = try gpa.dupe(u8, text), .elided = false, .elided_start = 0, .elided_end = 0, .lines_shown = total, .lines_total = total, .hunks_elided = 0 };
    }
    var keep = fit;
    while (keep > 0 and !isHunkBoundary(lines.items[keep])) keep -= 1;
    if (keep == 0) keep = fit;

    var hunks_elided: usize = 0;
    for (lines.items[keep..]) |l| {
        if (std.mem.startsWith(u8, l, "@")) hunks_elided += 1;
    }
    const remaining = total - keep;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (lines.items[0..keep], 0..) |l, i| {
        if (i != 0) try out.writer.writeByte('\n');
        try out.writer.writeAll(l);
    }
    if (keep != 0) try out.writer.writeByte('\n');
    try out.writer.print(ellipsis ++ " {d} lines in {d} hunks elided; pass detail:\"full\" for the full diff, or read a changed symbol with emetgate_read_symbol", .{ remaining, hunks_elided });

    return .{
        .text = try gpa.dupe(u8, out.written()),
        .elided = true,
        .elided_start = @intCast(keep + 1),
        .elided_end = @intCast(total),
        .lines_shown = keep,
        .lines_total = total,
        .hunks_elided = hunks_elided,
    };
}

fn writeDiffShow(gpa: Allocator, js: *std.json.Stringify, sub: []const u8, path: ?[]const u8, stdout: []const u8, summary: ?*const git_symbols.Summary, opts: Options) !void {
    try writeBase(js, sub, path, opts);
    if (opts.symbols_only or opts.detail == .full) {
        if (summary) |s| try writeSymbolSummary(js, s.*);
    }

    if (opts.symbols_only) {
        try js.objectField("symbols_only");
        try js.write(true);
        try js.objectField("note");
        try js.write("symbol summary only; no raw diff bytes — pass detail:\"full\" or drop symbols_only for hunks");
        try js.endObject();
        return;
    }

    if (opts.detail == .full) {
        try writeRaw(gpa, js, stdout);
        try js.endObject();
        return;
    }

    const condensed = try diff_digest.condense(gpa, stdout, summary);
    defer gpa.free(condensed);
    const folded = try foldDiff(gpa, condensed, opts.budget);
    defer folded.deinit(gpa);
    try js.objectField("output");
    try js.write(folded.text);
    if (!folded.elided) {
        try js.endObject();
        return;
    }
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
    if (folded.elided) {
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
    }
    try js.endArray();
    try js.objectField("note");
    try js.write("compact diff folded under the read budget; pass detail:\"full\" for every hunk, or symbols_only:true for symbol_changes only");
    try js.endObject();
}

fn writeBlame(gpa: Allocator, js: *std.json.Stringify, path: ?[]const u8, stdout: []const u8, blame: ?*const git_symbols.BlameReport, opts: Options) !void {
    try writeBase(js, "blame", path, opts);
    if (blame) |b| try writeBlameSummary(js, b.*);
    const want_raw = opts.detail == .full or opts.line_start != null;
    if (want_raw) {
        try writeRaw(gpa, js, stdout);
    } else {
        try js.objectField("note");
        try js.write("compact: symbol_blame is the primary view; pass detail:\"full\" for raw per-line blame, or line_start/line_end for a window");
    }
    try js.endObject();
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
