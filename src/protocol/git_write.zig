const std = @import("std");
const telemetry = @import("telemetry.zig");
const tool_result = @import("tool_result.zig");
const repo = @import("../platform/repo.zig");
const exe_path = @import("../platform/exe_path.zig");
const shadow = @import("../platform/shadow.zig");
const bounded_run = @import("../platform/bounded_run.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;
const ToolResult = tool_result.ToolResult;

pub const description = "Local git writes, args as for git, e.g. [\"switch\",\"-c\",\"x\"]: branch/switch/tag/stash/merge/rebase/cherry-pick/reset/push etc.; force:true for work-losing forms.";

pub const max_args = 32;
const max_output_lines = 40;
const max_output_bytes = 6 * 1024;
const local_timeout_ms = 120_000;
const network_timeout_ms = 180_000;
const max_git_output = 1024 * 1024;

pub const Error = error{ MissingGitArgs, TooManyGitArgs, InvalidGitArg };

const Flag = struct {
    name: []const u8,
    value: bool = false,
    lossy: bool = false,
};

fn v(name: []const u8) Flag {
    return .{ .name = name, .value = true };
}

fn x(name: []const u8) Flag {
    return .{ .name = name, .lossy = true };
}

const Spec = struct {
    sub: []const u8,
    flags: []const Flag,
    network: bool = false,
    actions: []const []const u8 = &.{},
    lossy_actions: []const []const u8 = &.{},
};

const specs = [_]Spec{
    .{ .sub = "branch", .flags = &.{ .{ .name = "-d" }, .{ .name = "--delete" }, .{ .name = "-m" }, .{ .name = "--move" }, .{ .name = "-c" }, .{ .name = "--copy" }, .{ .name = "-a" }, .{ .name = "--all" }, .{ .name = "-r" }, .{ .name = "--remotes" }, .{ .name = "-l" }, .{ .name = "--list" }, .{ .name = "-v" }, .{ .name = "-vv" }, .{ .name = "--verbose" }, .{ .name = "--show-current" }, .{ .name = "--merged" }, .{ .name = "--no-merged" }, .{ .name = "--contains" }, v("--sort"), v("-u"), v("--set-upstream-to"), .{ .name = "--unset-upstream" }, .{ .name = "--track" }, .{ .name = "--no-track" }, x("-D"), x("-M"), x("-C"), x("-f"), x("--force") } },
    .{ .sub = "switch", .flags = &.{ .{ .name = "-c" }, .{ .name = "--create" }, .{ .name = "-d" }, .{ .name = "--detach" }, .{ .name = "-t" }, .{ .name = "--track" }, .{ .name = "--no-track" }, .{ .name = "--orphan" }, .{ .name = "-m" }, .{ .name = "--merge" }, .{ .name = "--guess" }, .{ .name = "--no-guess" }, x("-C"), x("--force-create"), x("-f"), x("--force"), x("--discard-changes") } },
    .{ .sub = "checkout", .flags = &.{ .{ .name = "-b" }, .{ .name = "-t" }, .{ .name = "--track" }, .{ .name = "--no-track" }, .{ .name = "--detach" }, .{ .name = "-m" }, .{ .name = "--merge" }, .{ .name = "--orphan" }, x("-B"), x("-f"), x("--force") } },
    .{ .sub = "tag", .flags = &.{ .{ .name = "-a" }, .{ .name = "--annotate" }, v("-m"), v("--message"), .{ .name = "-d" }, .{ .name = "--delete" }, .{ .name = "-l" }, .{ .name = "--list" }, .{ .name = "-n" }, .{ .name = "--contains" }, .{ .name = "--points-at" }, v("--sort"), x("-f"), x("--force") } },
    .{ .sub = "stash", .flags = &.{ v("-m"), v("--message"), .{ .name = "-u" }, .{ .name = "--include-untracked" }, .{ .name = "-k" }, .{ .name = "--keep-index" }, .{ .name = "--no-keep-index" }, .{ .name = "-S" }, .{ .name = "--staged" }, .{ .name = "--index" }, .{ .name = "--stat" }, .{ .name = "-p" }, .{ .name = "--patch" } }, .actions = &.{ "push", "save", "list", "show", "pop", "apply", "branch" }, .lossy_actions = &.{ "drop", "clear" } },
    .{ .sub = "add", .flags = &.{ .{ .name = "-A" }, .{ .name = "--all" }, .{ .name = "-u" }, .{ .name = "--update" }, .{ .name = "-N" }, .{ .name = "--intent-to-add" }, .{ .name = "-f" }, .{ .name = "--force" }, .{ .name = "--renormalize" }, .{ .name = "-v" }, .{ .name = "-n" }, .{ .name = "--dry-run" } } },
    .{ .sub = "rm", .flags = &.{ .{ .name = "--cached" }, .{ .name = "-r" }, .{ .name = "-n" }, .{ .name = "--dry-run" }, .{ .name = "--ignore-unmatch" }, x("-f"), x("--force") } },
    .{ .sub = "mv", .flags = &.{ .{ .name = "-k" }, .{ .name = "-n" }, .{ .name = "-v" }, x("-f"), x("--force") } },
    .{ .sub = "commit", .flags = &.{ v("-m"), v("--message"), v("-am"), .{ .name = "-a" }, .{ .name = "--all" }, .{ .name = "--amend" }, .{ .name = "--no-edit" }, .{ .name = "--allow-empty" }, .{ .name = "--allow-empty-message" }, v("--author"), v("--date"), .{ .name = "-s" }, .{ .name = "--signoff" }, .{ .name = "-o" }, .{ .name = "--only" }, .{ .name = "-i" }, .{ .name = "--include" }, v("--fixup"), v("--squash") } },
    .{ .sub = "restore", .flags = &.{ .{ .name = "-S" }, .{ .name = "--staged" }, .{ .name = "-W" }, .{ .name = "--worktree" }, v("-s"), v("--source"), .{ .name = "--ours" }, .{ .name = "--theirs" }, .{ .name = "-m" }, .{ .name = "--merge" }, v("--conflict") } },
    .{ .sub = "reset", .flags = &.{ .{ .name = "--soft" }, .{ .name = "--mixed" }, .{ .name = "-N" }, .{ .name = "--keep" }, .{ .name = "--merge" }, x("--hard") } },
    .{ .sub = "merge", .flags = &.{ .{ .name = "--no-ff" }, .{ .name = "--ff" }, .{ .name = "--ff-only" }, .{ .name = "--squash" }, .{ .name = "--no-squash" }, .{ .name = "--commit" }, .{ .name = "--no-commit" }, v("-m"), v("--message"), .{ .name = "--abort" }, .{ .name = "--continue" }, .{ .name = "--quit" }, .{ .name = "--no-edit" }, v("-X"), v("--strategy-option"), .{ .name = "--allow-unrelated-histories" }, .{ .name = "--stat" }, .{ .name = "--no-stat" }, .{ .name = "--log" }, .{ .name = "--signoff" } } },
    .{ .sub = "rebase", .flags = &.{ v("--onto"), .{ .name = "--abort" }, .{ .name = "--continue" }, .{ .name = "--skip" }, .{ .name = "--quit" }, .{ .name = "--autostash" }, .{ .name = "--no-autostash" }, .{ .name = "--keep-base" }, .{ .name = "--root" }, v("--empty"), .{ .name = "--keep-empty" }, .{ .name = "--no-keep-empty" }, .{ .name = "--update-refs" }, .{ .name = "--committer-date-is-author-date" }, .{ .name = "--reset-author-date" }, .{ .name = "--autosquash" }, .{ .name = "--no-autosquash" }, .{ .name = "--rebase-merges" }, v("-X"), v("--strategy-option"), .{ .name = "--signoff" } } },
    .{ .sub = "cherry-pick", .flags = &.{ .{ .name = "-x" }, .{ .name = "-n" }, .{ .name = "--no-commit" }, v("-m"), v("--mainline"), .{ .name = "--abort" }, .{ .name = "--continue" }, .{ .name = "--skip" }, .{ .name = "--quit" }, .{ .name = "--ff" }, .{ .name = "--allow-empty" }, .{ .name = "--keep-redundant-commits" }, v("-X"), v("--strategy-option"), .{ .name = "-s" }, .{ .name = "--signoff" } } },
    .{ .sub = "revert", .flags = &.{ .{ .name = "-n" }, .{ .name = "--no-commit" }, .{ .name = "--no-edit" }, v("-m"), v("--mainline"), .{ .name = "--abort" }, .{ .name = "--continue" }, .{ .name = "--skip" }, .{ .name = "--quit" }, v("-X"), v("--strategy-option"), .{ .name = "-s" }, .{ .name = "--signoff" } } },
    .{ .sub = "fetch", .network = true, .flags = &.{ .{ .name = "--all" }, .{ .name = "-p" }, .{ .name = "--prune" }, .{ .name = "-t" }, .{ .name = "--tags" }, .{ .name = "--no-tags" }, v("--depth"), .{ .name = "--unshallow" }, .{ .name = "--dry-run" }, .{ .name = "-v" } } },
    .{ .sub = "pull", .network = true, .flags = &.{ .{ .name = "--ff-only" }, .{ .name = "--ff" }, .{ .name = "--no-ff" }, .{ .name = "--rebase" }, .{ .name = "--no-rebase" }, .{ .name = "--autostash" }, .{ .name = "--no-edit" }, .{ .name = "--tags" }, .{ .name = "-v" } } },
    .{ .sub = "push", .network = true, .flags = &.{ .{ .name = "-u" }, .{ .name = "--set-upstream" }, .{ .name = "--tags" }, .{ .name = "--follow-tags" }, .{ .name = "-n" }, .{ .name = "--dry-run" }, .{ .name = "-v" }, x("-f"), x("--force"), x("--force-with-lease"), x("--force-if-includes"), x("-d"), x("--delete"), x("--mirror"), x("--prune") } },
};

const prefix = [_][]const u8{
    "-c",                       "core.editor=:",
    "-c",                       "sequence.editor=:",
    "-c",                       "core.pager=cat",
    "-c",                       "credential.interactive=never",
    "-c",                       "gc.auto=0",
    "-c",                       "maintenance.auto=false",
    "-c",                       "core.fsmonitor=false",
    "-c",                       "color.ui=false",
    "-c",                       "advice.detachedHead=false",
    "-c",                       "core.longpaths=true",
    "--no-pager",
};

pub const Check = union(enum) {
    ok: struct { spec: *const Spec, lossy: bool },
    refused: struct { reason: []const u8, arg: []const u8 },
};

fn findSpec(sub: []const u8) ?*const Spec {
    for (&specs) |*spec| if (std.mem.eql(u8, spec.sub, sub)) return spec;
    return null;
}

fn findFlag(spec: *const Spec, arg: []const u8) ?struct { flag: Flag, inline_value: bool } {
    for (spec.flags) |flag| {
        if (std.mem.eql(u8, arg, flag.name)) return .{ .flag = flag, .inline_value = false };
        if (std.mem.startsWith(u8, flag.name, "--") and arg.len > flag.name.len and std.mem.startsWith(u8, arg, flag.name) and arg[flag.name.len] == '=') return .{ .flag = flag, .inline_value = true };
    }
    return null;
}

fn listed(list: []const []const u8, word: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, word)) return true;
    return false;
}

pub fn check(args: []const []const u8) Check {
    if (args.len == 0) return .{ .refused = .{ .reason = "unsupported_subcommand", .arg = "" } };
    const spec = findSpec(args[0]) orelse return .{ .refused = .{ .reason = "unsupported_subcommand", .arg = args[0] } };
    var lossy = false;
    var paths_only = false;
    var staged = false;
    var worktree = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (paths_only) continue;
        if (std.mem.eql(u8, arg, "--")) {
            paths_only = true;
            continue;
        }
        if (arg.len > 1 and arg[0] == '-') {
            const found = findFlag(spec, arg) orelse return .{ .refused = .{ .reason = "unsupported_flag", .arg = arg } };
            if (found.flag.lossy) lossy = true;
            if (std.mem.eql(u8, found.flag.name, "--staged") or std.mem.eql(u8, found.flag.name, "-S")) staged = true;
            if (std.mem.eql(u8, found.flag.name, "--worktree") or std.mem.eql(u8, found.flag.name, "-W")) worktree = true;
            if (found.flag.value and !found.inline_value) {
                i += 1;
                if (i == args.len) return .{ .refused = .{ .reason = "missing_value", .arg = arg } };
            }
            continue;
        }
        if (i == 1 and (spec.actions.len != 0 or spec.lossy_actions.len != 0)) {
            if (listed(spec.lossy_actions, arg)) {
                lossy = true;
            } else if (!listed(spec.actions, arg)) {
                return .{ .refused = .{ .reason = "unsupported_action", .arg = arg } };
            }
            continue;
        }
        if (spec.network and (arg[0] == '+' or arg[0] == ':')) lossy = true;
    }
    if (std.mem.eql(u8, spec.sub, "restore") and !(staged and !worktree)) lossy = true;
    return .{ .ok = .{ .spec = spec, .lossy = lossy } };
}

fn checkoutTargets(args: []const []const u8) struct { refs: [2]?[]const u8 = .{ null, null }, count: usize = 0, paths: bool = false } {
    var out: @TypeOf(checkoutTargets(&.{})) = .{};
    const spec = findSpec("checkout").?;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            out.paths = i + 1 < args.len;
            break;
        }
        if (arg.len > 1 and arg[0] == '-') {
            const found = findFlag(spec, arg) orelse continue;
            if (std.mem.eql(u8, found.flag.name, "-b") or std.mem.eql(u8, found.flag.name, "-B") or std.mem.eql(u8, found.flag.name, "--orphan")) i += 1;
            continue;
        }
        if (out.count < out.refs.len) out.refs[out.count] = arg;
        out.count += 1;
    }
    return out;
}

pub fn callGitWrite(gpa: Allocator, io: std.Io, args: ?Value, event: *telemetry.Event, root: ?[]const u8) !ToolResult {
    event.label = "git_write";
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const argv = try gitArgs(arena, args);
    if (argv.len != 0) event.file = argv[0];
    const force = if (args) |a| tool_result.getBool(a, "force") orelse false else false;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    const is_error = render(arena, io, root, argv, force, &buffer.writer, event) catch |err| {
        if (err == error.OutOfMemory) return err;
        return tool_result.failure(gpa, &buffer, err, event);
    };
    return .{ .text = try tool_result.dupTrim(gpa, buffer.written()), .is_error = is_error };
}

fn gitArgs(arena: Allocator, args: ?Value) ![]const []const u8 {
    const object = args orelse return error.MissingGitArgs;
    const field = tool_result.getField(object, "args") orelse return error.MissingGitArgs;
    var list: std.ArrayList([]const u8) = .empty;
    switch (field) {
        .array => |items| for (items.items) |item| switch (item) {
            .string => |s| try list.append(arena, s),
            .integer => |n| try list.append(arena, try std.fmt.allocPrint(arena, "{d}", .{n})),
            else => return error.InvalidGitArg,
        },
        .string => |s| try splitWords(arena, &list, s),
        else => return error.MissingGitArgs,
    }
    if (list.items.len != 0 and std.mem.eql(u8, list.items[0], "git")) _ = list.orderedRemove(0);
    if (list.items.len == 0) return error.MissingGitArgs;
    if (list.items.len > max_args) return error.TooManyGitArgs;
    for (list.items) |a| if (std.mem.indexOfScalar(u8, a, 0) != null) return error.InvalidGitArg;
    return list.items;
}

fn splitWords(arena: Allocator, list: *std.ArrayList([]const u8), text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        if (i == text.len) break;
        var word: std.ArrayList(u8) = .empty;
        var quote: ?u8 = null;
        while (i < text.len) : (i += 1) {
            const c = text[i];
            if (quote) |q| {
                if (c == q) quote = null else try word.append(arena, c);
            } else if (c == '"' or c == '\'') {
                quote = c;
            } else if (std.ascii.isWhitespace(c)) {
                break;
            } else try word.append(arena, c);
        }
        try list.append(arena, word.items);
    }
}

fn render(arena: Allocator, io: std.Io, root: ?[]const u8, args: []const []const u8, force: bool, w: *Writer, event: *telemetry.Event) !bool {
    const root_abs = try repo.servedRoot(arena, io, root);
    const git = try exe_path.git(arena, root_abs);
    const ok = switch (check(args)) {
        .refused => |why| {
            event.fail("GitWriteRefused");
            try writeRefused(w, why.reason, why.arg);
            return true;
        },
        .ok => |ok| ok,
    };
    var lossy = ok.lossy;
    if (std.mem.eql(u8, ok.spec.sub, "checkout") and !lossy) lossy = try checkoutLosesWork(arena, io, git, root_abs, args);
    if (lossy and !force) {
        event.fail("WouldLoseWork");
        try writeRefused(w, "would_lose_work", args[0]);
        return true;
    }

    const lock = try shadow.Lock.acquire(io, root_abs);
    defer lock.release();

    const before = try headOid(arena, io, git, root_abs);
    var full: std.ArrayList([]const u8) = .empty;
    try full.append(arena, git);
    try full.appendSlice(arena, &prefix);
    try full.appendSlice(arena, args);
    const timeout_ms: u64 = if (ok.spec.network) network_timeout_ms else local_timeout_ms;
    var outcome: []const u8 = "exited";
    var exit_code: ?u32 = null;
    var stdout: []const u8 = "";
    var stderr: []const u8 = "";
    if (bounded_run.run(arena, io, .{
        .argv = full.items,
        .cwd = .{ .path = root_abs },
        .stdout_limit = .limited(max_git_output),
        .stderr_limit = .limited(max_git_output),
        .timeout = bounded_run.timeoutMs(timeout_ms),
    })) |result| {
        stdout = result.stdout;
        stderr = result.stderr;
        switch (result.term) {
            .exited => |code| exit_code = code,
            else => outcome = "crashed",
        }
    } else |err| switch (err) {
        error.Timeout => outcome = "timed_out",
        error.StreamTooLong => outcome = "output_limit",
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.GitCommandFailed,
    }
    const after = try headOid(arena, io, git, root_abs);
    const branch = try capture(arena, io, git, root_abs, &.{ "branch", "--show-current" });
    var shortstat: ?[]const u8 = null;
    if (before != null and after != null and !std.mem.eql(u8, before.?, after.?)) {
        shortstat = try capture(arena, io, git, root_abs, &.{ "diff", "--shortstat", before.?, after.? });
    }

    const failed = exit_code == null or exit_code.? != 0;
    if (failed) event.fail("GitCommandFailed");
    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("status");
    try js.write(if (failed) "failed" else "ok");
    if (!std.mem.eql(u8, outcome, "exited")) {
        try js.objectField("outcome");
        try js.write(outcome);
    }
    if (exit_code) |code| if (code != 0) {
        try js.objectField("exit_code");
        try js.write(code);
    };
    if (after) |oid| {
        try js.objectField("head");
        try js.write(oid);
    }
    if (branch) |name| if (name.len != 0) {
        try js.objectField("branch");
        try js.write(name);
    };
    if (shortstat) |stat| if (stat.len != 0) {
        try js.objectField("from");
        try js.write(before.?);
        try js.objectField("shortstat");
        try js.write(stat);
    };
    const output = try tail(arena, stdout, stderr);
    if (output.len != 0) {
        try js.objectField("output");
        try js.write(output);
    }
    try js.endObject();
    try w.writeByte('\n');
    return failed;
}

fn checkoutLosesWork(arena: Allocator, io: std.Io, git: []const u8, root_abs: []const u8, args: []const []const u8) !bool {
    const targets = checkoutTargets(args);
    if (targets.paths or targets.count > 1) return true;
    if (targets.count == 0) return false;
    const spec = try std.fmt.allocPrint(arena, "{s}^{{commit}}", .{targets.refs[0].?});
    const resolved = try capture(arena, io, git, root_abs, &.{ "rev-parse", "--verify", "--quiet", "--end-of-options", spec });
    if (resolved != null) return false;
    const remote = try capture(arena, io, git, root_abs, &.{ "for-each-ref", "--count=1", "--format=%(refname)", try std.fmt.allocPrint(arena, "refs/remotes/*/{s}", .{targets.refs[0].?}) });
    return remote == null or remote.?.len == 0;
}

fn headOid(arena: Allocator, io: std.Io, git: []const u8, root_abs: []const u8) !?[]const u8 {
    return capture(arena, io, git, root_abs, &.{ "rev-parse", "--verify", "--quiet", "HEAD" });
}

fn capture(arena: Allocator, io: std.Io, git: []const u8, root_abs: []const u8, args: []const []const u8) !?[]const u8 {
    var full: std.ArrayList([]const u8) = .empty;
    try full.appendSlice(arena, &.{ git, "-c", "core.fsmonitor=false", "--no-optional-locks", "--no-pager" });
    try full.appendSlice(arena, args);
    const result = bounded_run.run(arena, io, .{
        .argv = full.items,
        .cwd = .{ .path = root_abs },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return switch (result.term) {
        .exited => |code| if (code == 0) std.mem.trim(u8, result.stdout, " \r\n") else null,
        else => null,
    };
}

fn tail(arena: Allocator, stdout: []const u8, stderr: []const u8) ![]const u8 {
    const joined = std.mem.trim(u8, try std.mem.concat(arena, u8, &.{ std.mem.trim(u8, stdout, "\r\n"), if (stdout.len != 0 and stderr.len != 0) "\n" else "", std.mem.trim(u8, stderr, "\r\n") }), "\r\n");
    var start = joined.len;
    var lines: usize = 0;
    while (start > 0) {
        const prev = std.mem.lastIndexOfScalar(u8, joined[0 .. start - 1], '\n');
        const next_start = if (prev) |p| p + 1 else 0;
        if (lines == max_output_lines or joined.len - next_start > max_output_bytes) break;
        start = next_start;
        lines += 1;
        if (prev == null) break;
    }
    if (start == 0) return joined;
    const left = std.mem.count(u8, joined[0..start], "\n");
    return std.fmt.allocPrint(arena, "[{d} earlier lines left out]\n{s}", .{ left, joined[start..] });
}

fn writeRefused(w: *Writer, reason: []const u8, arg: []const u8) !void {
    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("status");
    try js.write("refused");
    try js.objectField("reason");
    try js.write(reason);
    if (arg.len != 0) {
        try js.objectField("arg");
        try js.write(arg);
    }
    try js.objectField("fix");
    try js.write(fixFor(reason));
    try js.endObject();
    try w.writeByte('\n');
}

fn fixFor(reason: []const u8) []const u8 {
    if (std.mem.eql(u8, reason, "would_lose_work")) return "this discards uncommitted work or rewrites a remote; pass force:true only when the user asked for exactly that";
    if (std.mem.eql(u8, reason, "unsupported_subcommand")) return "args[0] is one of " ++ sub_list;
    if (std.mem.eql(u8, reason, "missing_value")) return "give the flag its value as the next element or as --flag=value";
    return "use a supported flag; read-only views are emetgate_git, file edits go through the gate";
}

const sub_list = blk: {
    var text: []const u8 = "";
    for (specs, 0..) |spec, i| text = text ++ (if (i == 0) "" else ", ") ++ spec.sub;
    break :blk text;
};

const testing = std.testing;

fn expectReason(args: []const []const u8, reason: []const u8) !void {
    switch (check(args)) {
        .refused => |why| try testing.expectEqualStrings(reason, why.reason),
        .ok => return error.TestExpectedRefusal,
    }
}

fn expectLossy(args: []const []const u8, lossy: bool) !void {
    switch (check(args)) {
        .refused => |why| {
            std.debug.print("refused {s} {s}\n", .{ why.reason, why.arg });
            return error.TestUnexpectedRefusal;
        },
        .ok => |ok| try testing.expectEqual(lossy, ok.lossy),
    }
}

test "git write accepts the local workflow and marks only work-losing forms" {
    try expectLossy(&.{ "switch", "-c", "release-11.3.0" }, false);
    try expectLossy(&.{ "branch", "feature" }, false);
    try expectLossy(&.{ "tag", "-a", "v1", "-m", "release" }, false);
    try expectLossy(&.{ "stash", "push", "-m", "wip" }, false);
    try expectLossy(&.{ "stash", "pop" }, false);
    try expectLossy(&.{ "commit", "-m", "Bump version to 11.3.0" }, false);
    try expectLossy(&.{ "merge", "--no-ff", "feature" }, false);
    try expectLossy(&.{ "rebase", "main" }, false);
    try expectLossy(&.{ "cherry-pick", "abc1234" }, false);
    try expectLossy(&.{ "restore", "--staged", "a.txt" }, false);
    try expectLossy(&.{ "reset", "--soft", "HEAD~1" }, false);
    try expectLossy(&.{ "push", "-u", "origin", "feature" }, false);
    try expectLossy(&.{ "reset", "--hard", "HEAD" }, true);
    try expectLossy(&.{ "restore", "a.txt" }, true);
    try expectLossy(&.{ "restore", "--staged", "--worktree", "a.txt" }, true);
    try expectLossy(&.{ "stash", "drop" }, true);
    try expectLossy(&.{ "branch", "-D", "feature" }, true);
    try expectLossy(&.{ "switch", "--discard-changes", "main" }, true);
    try expectLossy(&.{ "push", "--force", "origin", "main" }, true);
    try expectLossy(&.{ "push", "origin", "+main" }, true);
}

test "git write refuses execution and config flags and unknown subcommands" {
    try expectReason(&.{ "rebase", "-x", "calc.exe", "main" }, "unsupported_flag");
    try expectReason(&.{ "rebase", "--exec=calc.exe", "main" }, "unsupported_flag");
    try expectReason(&.{ "fetch", "--upload-pack=calc.exe", "origin" }, "unsupported_flag");
    try expectReason(&.{ "commit", "--no-verify", "-m", "x" }, "unsupported_flag");
    try expectReason(&.{ "config", "core.hooksPath", "x" }, "unsupported_subcommand");
    try expectReason(&.{ "clean", "-fdx" }, "unsupported_subcommand");
    try expectReason(&.{ "stash", "nuke" }, "unsupported_action");
    try expectReason(&.{ "commit", "-m" }, "missing_value");
}

test "a commit message that looks like a flag is a value, not a flag" {
    try expectLossy(&.{ "commit", "-m", "--hard" }, false);
    try expectLossy(&.{ "tag", "-m", "-f", "v2" }, false);
}

test "checkout targets separate a branch switch from a path checkout" {
    const branch = checkoutTargets(&.{ "checkout", "-b", "new", "main" });
    try testing.expectEqual(@as(usize, 1), branch.count);
    try testing.expectEqualStrings("main", branch.refs[0].?);
    try testing.expect(!branch.paths);
    const paths = checkoutTargets(&.{ "checkout", "HEAD", "--", "a.txt" });
    try testing.expect(paths.paths);
}
