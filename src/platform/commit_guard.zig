const std = @import("std");
const disk = @import("disk.zig");
const receipts = @import("receipts.zig");
const rules = @import("rules.zig");
const sandbox = @import("sandbox.zig");
const registry = @import("../engine/lang/registry.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;
const Snapshot = @import("../engine/loader.zig").Snapshot;
const Span = @import("../engine/symbol.zig").Span;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const hook_command = "hook";
pub const hook_name = "commit-msg";
pub const outer_variable = "EMETGATE_OUTER_ROOT";
pub const repo_memory_variable = "EMETGATE_ALLOW_REPO_MEMORY";
pub const user_count_variable = "EMETGATE_GIT_CONFIG_COUNT";

const max_message_bytes = 1024 * 1024;
const max_code_bytes = 16 * 1024 * 1024;

const chained_hooks = [_][]const u8{
    "applypatch-msg",     "pre-applypatch",   "post-applypatch",    "pre-commit",
    "pre-merge-commit",   "prepare-commit-msg", "post-commit",      "pre-rebase",
    "post-checkout",      "post-merge",       "pre-push",           "pre-receive",
    "update",             "proc-receive",     "post-receive",       "post-update",
    "reference-transaction", "push-to-checkout", "pre-auto-gc",     "post-rewrite",
    "sendemail-validate", "post-index-change", "p4-changelist",     "p4-prepare-changelist",
    "p4-post-changelist", "p4-pre-submit",
};

const find_own_hooks =
    "#!/bin/sh\n" ++
    "GIT_CONFIG_COUNT=${{" ++ user_count_variable ++ ":-0}}\n" ++
    "export GIT_CONFIG_COUNT\n" ++
    "own=$(git config --type=path --get core.hooksPath) || own=$(git rev-parse --git-common-dir)/hooks\n";

pub fn chainScript(gpa: Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, find_own_hooks ++ "[ -x \"$own/{s}\" ] || exit 0\nexec \"$own/{s}\" \"$@\"\n", .{ name, name });
}

pub fn guardScript(gpa: Allocator, exe_abs: []const u8) ![]u8 {
    var quoted: std.ArrayList(u8) = .empty;
    defer quoted.deinit(gpa);
    for (exe_abs) |c| switch (c) {
        '\\' => try quoted.append(gpa, '/'),
        '\'' => try quoted.appendSlice(gpa, "'\\''"),
        else => try quoted.append(gpa, c),
    };
    return std.fmt.allocPrint(gpa, find_own_hooks ++ "if [ -x \"$own/{s}\" ]; then \"$own/{s}\" \"$@\" || exit $?; fi\nexec '{s}' {s} {s} \"$1\"\n", .{ hook_name, hook_name, quoted.items, hook_command, hook_name });
}

pub fn install(gpa: Allocator, io: std.Io, state_abs: []const u8, exe_abs: []const u8) ![]u8 {
    const guard = try guardScript(gpa, exe_abs);
    defer gpa.free(guard);
    var hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(guard, &hash, .{});
    const key = std.fmt.bytesToHex(hash[0..8], .lower);
    const dir_abs = try std.fmt.allocPrint(gpa, "{s}\\commit-hooks\\{s}", .{ state_abs, &key });
    errdefer gpa.free(dir_abs);
    if (std.Io.Dir.accessAbsolute(io, dir_abs, .{})) |_| return dir_abs else |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    }
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    const temp_abs = try std.fmt.allocPrint(gpa, "{s}.{x}", .{ dir_abs, &nonce });
    defer gpa.free(temp_abs);
    try std.Io.Dir.cwd().createDirPath(io, temp_abs);
    var temp = try std.Io.Dir.openDirAbsolute(io, temp_abs, .{});
    {
        defer temp.close(io);
        try temp.writeFile(io, .{ .sub_path = hook_name, .data = guard });
        for (chained_hooks) |name| {
            const script = try chainScript(gpa, name);
            defer gpa.free(script);
            try temp.writeFile(io, .{ .sub_path = name, .data = script });
        }
    }
    std.Io.Dir.renameAbsolute(temp_abs, dir_abs, io) catch |err| {
        std.Io.Dir.cwd().deleteTree(io, temp_abs) catch {};
        std.Io.Dir.accessAbsolute(io, dir_abs, .{}) catch return err;
    };
    return dir_abs;
}

pub fn environment(arena: Allocator, hooks_abs: []const u8, outer_abs: []const u8, allow_repo_memory: bool, user_count: ?[]const u8) ![]sandbox.EnvVar {
    const count: u32 = if (user_count) |text| std.fmt.parseInt(u32, text, 10) catch 0 else 0;
    const forward = try arena.dupe(u8, hooks_abs);
    std.mem.replaceScalar(u8, forward, '\\', '/');
    var vars: std.ArrayList(sandbox.EnvVar) = .empty;
    try vars.appendSlice(arena, &.{
        .{ .name = "GIT_CONFIG_COUNT", .value = try std.fmt.allocPrint(arena, "{d}", .{count + 1}) },
        .{ .name = try std.fmt.allocPrint(arena, "GIT_CONFIG_KEY_{d}", .{count}), .value = "core.hooksPath" },
        .{ .name = try std.fmt.allocPrint(arena, "GIT_CONFIG_VALUE_{d}", .{count}), .value = forward },
        .{ .name = user_count_variable, .value = try std.fmt.allocPrint(arena, "{d}", .{count}) },
        .{ .name = outer_variable, .value = outer_abs },
    });
    if (allow_repo_memory) try vars.append(arena, .{ .name = repo_memory_variable, .value = "1" });
    return vars.toOwnedSlice(arena);
}

pub const Staged = struct {
    changes: std.ArrayList(rules.Change) = .empty,
    targets: std.ArrayList([]const u8) = .empty,
    snapshots: std.ArrayList(*Snapshot) = .empty,

    pub fn deinit(self: *Staged, gpa: Allocator) void {
        for (self.snapshots.items) |snapshot| snapshot.destroy();
        self.snapshots.deinit(gpa);
        self.changes.deinit(gpa);
        self.targets.deinit(gpa);
    }

    fn parsed(self: *Staged, gpa: Allocator, runtime: *Runtime, rel: []const u8, source: ?[]const u8) !?*Snapshot {
        const bytes = source orelse return null;
        if (bytes.len > max_code_bytes) return null;
        const profile = registry.forPath(rel) orelse return null;
        const snapshot = try Snapshot.fromSource(runtime, profile, try gpa.dupe(u8, bytes));
        errdefer snapshot.destroy();
        try self.snapshots.append(gpa, snapshot);
        return snapshot;
    }
};

fn blob(arena: Allocator, io: std.Io, root_abs: []const u8, spec: []const u8) !?[]u8 {
    if (try @import("git_native.zig").blobAt(arena, io, root_abs, spec)) |found| return switch (found) {
        .found => |bytes| bytes,
        .absent => null,
    };
    return receipts.git(arena, io, root_abs, &.{ "cat-file", "blob", spec });
}

fn lineStarts(arena: Allocator, source: []const u8) ![]u32 {
    var starts: std.ArrayList(u32) = .empty;
    try starts.append(arena, 0);
    for (source, 0..) |c, i| if (c == '\n') try starts.append(arena, @intCast(i + 1));
    return starts.items;
}

fn hunkSide(text: []const u8, starts: []const u32, size: usize) ?Span {
    var parts = std.mem.splitScalar(u8, text, ',');
    const first = std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch return null;
    const count = if (parts.next()) |more| std.fmt.parseInt(u32, more, 10) catch return null else 1;
    const from: u64 = if (count == 0) first else if (first == 0) return null else first - 1;
    const to = from + count;
    const start = if (from < starts.len) starts[@intCast(from)] else @as(u32, @intCast(size));
    const end = if (to < starts.len) starts[@intCast(to)] else @as(u32, @intCast(size));
    return .{ .start = start, .end = end };
}

pub fn holesFromDiff(arena: Allocator, diff: []const u8, old: []const u8, new: []const u8) !?[]const rules.Hole {
    const old_starts = try lineStarts(arena, old);
    const new_starts = try lineStarts(arena, new);
    var holes: std.ArrayList(rules.Hole) = .empty;
    var lines = std.mem.splitScalar(u8, diff, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "@@ -")) continue;
        var words = std.mem.tokenizeScalar(u8, line[3..], ' ');
        const old_word = words.next() orelse return null;
        const new_word = words.next() orelse return null;
        if (old_word[0] != '-' or new_word.len < 2 or new_word[0] != '+') return null;
        try holes.append(arena, .{
            .old = hunkSide(old_word[1..], old_starts, old.len) orelse return null,
            .new = hunkSide(new_word[1..], new_starts, new.len) orelse return null,
        });
    }
    return holes.items;
}

fn changedHoles(arena: Allocator, io: std.Io, root_abs: []const u8, rel: []const u8, base: ?*Snapshot, after: ?*Snapshot, diff_argv: []const []const u8) !?[]const rules.Hole {
    const old = base orelse return null;
    const new = after orelse return null;
    const diff = (try receipts.git(arena, io, root_abs, diff_argv)) orelse return null;
    const holes = try holesFromDiff(arena, diff, old.source, new.source) orelse return null;
    rules.confirmClaim(.{ .rel = rel, .base = old, .after = new, .holes = holes }) catch return null;
    return holes;
}

const diff_flags = [_][]const u8{ "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", "--unified=0" };

fn diffArgv(arena: Allocator, head: []const []const u8, rel: []const u8) ![]const []const u8 {
    return std.mem.concat(arena, []const u8, &.{ head, &diff_flags, &.{ "--", rel } });
}

fn addChange(arena: Allocator, gpa: Allocator, io: std.Io, runtime: *Runtime, root_abs: []const u8, rel: []const u8, before: ?[]const u8, after: ?[]const u8, diff_argv: []const []const u8, staged: *Staged) !void {
    const base = try staged.parsed(gpa, runtime, rel, before);
    const usable = if (base) |snapshot| !snapshot.tree.root().hasError() else false;
    const known = if (usable) base else null;
    const now = try staged.parsed(gpa, runtime, rel, after);
    try staged.changes.append(gpa, .{
        .rel = rel,
        .base = known,
        .after = now,
        .holes = try changedHoles(arena, io, root_abs, rel, known, now, diff_argv),
        .removed = after == null,
    });
    if (after != null) try staged.targets.append(gpa, rel);
}

fn readStaged(arena: Allocator, gpa: Allocator, io: std.Io, runtime: *Runtime, root_abs: []const u8, staged: *Staged) !void {
    const listed = (try receipts.git(arena, io, root_abs, &.{ "diff", "--cached", "--name-status", "-z", "--no-renames" })) orelse return error.GitFailed;
    var tokens = std.mem.splitScalar(u8, listed, 0);
    while (tokens.next()) |status| {
        if (status.len == 0) continue;
        const rel = tokens.next() orelse return error.GitFailed;
        const before = try blob(arena, io, root_abs, try std.fmt.allocPrint(arena, "HEAD:{s}", .{rel}));
        const after = if (status[0] == 'D') null else try blob(arena, io, root_abs, try std.fmt.allocPrint(arena, ":{s}", .{rel}));
        try addChange(arena, gpa, io, runtime, root_abs, rel, before, after, try diffArgv(arena, &.{ "--literal-pathspecs", "diff", "--cached" }, rel), staged);
    }
}

pub fn readCommit(arena: Allocator, gpa: Allocator, io: std.Io, runtime: *Runtime, root_abs: []const u8, oid: []const u8, staged: *Staged) !void {
    const listed = (try receipts.git(arena, io, root_abs, &.{ "diff-tree", "-r", "--root", "--no-commit-id", "--name-status", "-z", "--no-renames", oid })) orelse return error.GitFailed;
    var tokens = std.mem.splitScalar(u8, listed, 0);
    while (tokens.next()) |status| {
        if (status.len == 0) continue;
        const rel = tokens.next() orelse return error.GitFailed;
        const before = try blob(arena, io, root_abs, try std.fmt.allocPrint(arena, "{s}^:{s}", .{ oid, rel }));
        const after = if (status[0] == 'D') null else try blob(arena, io, root_abs, try std.fmt.allocPrint(arena, "{s}:{s}", .{ oid, rel }));
        try addChange(arena, gpa, io, runtime, root_abs, rel, before, after, try diffArgv(arena, &.{ "--literal-pathspecs", "diff-tree", "-r", "--root", "--no-commit-id", "-p", oid }, rel), staged);
    }
}

pub fn addWorking(arena: Allocator, gpa: Allocator, io: std.Io, runtime: *Runtime, root_abs: []const u8, rel: []const u8, bytes: ?[]const u8, staged: *Staged) !void {
    const before = try blob(arena, io, root_abs, try std.fmt.allocPrint(arena, "HEAD:{s}", .{rel}));
    var after = bytes;
    if (before) |old| {
        if (bytes) |now| {
            if (std.mem.indexOfScalar(u8, old, '\r') == null and std.mem.indexOf(u8, now, "\r\n") != null) {
                const plain = try arena.alloc(u8, std.mem.replacementSize(u8, now, "\r\n", "\n"));
                _ = std.mem.replace(u8, now, "\r\n", "\n", plain);
                after = plain;
            }
        }
    }
    try addChange(arena, gpa, io, runtime, root_abs, rel, before, after, try diffArgv(arena, &.{ "--literal-pathspecs", "diff", "HEAD", "--ignore-cr-at-eol" }, rel), staged);
}

fn writeRefusal(w: *Writer, gate: rules.Gate) !void {
    switch (gate) {
        .ok => {},
        .violated => |report| {
            try w.print("emetgate: commit refused, {d} rule violation(s)\n", .{report.violations.len});
            for (report.violations) |v| {
                try w.print("  {s}:{d}:{d} rule {s}", .{ v.file, v.line, v.col, v.rule });
                if (v.rule_text.len != 0) try w.print(" ({s})", .{v.rule_text});
                try w.print(": {s}\n", .{v.text});
            }
            try w.writeAll("fix: change what the rule names, stage it, and commit again\n");
        },
        .failed => |failure| try w.print("emetgate: commit refused, rule {s} could not run on {s}: {s} {s}\nfix: repair the rule or its command, and commit again\n", .{ failure.rule, failure.file, failure.detail, failure.text }),
    }
}

fn refused(gpa: Allocator, w: *Writer, gate: rules.Gate) !bool {
    defer gate.deinit(gpa);
    if (gate == .ok) return false;
    try writeRefusal(w, gate);
    return true;
}

pub fn check(gpa: Allocator, io: std.Io, runtime: *Runtime, root_abs: []const u8, message_path: []const u8, allow_repo_memory: bool, w: *Writer) !u8 {
    const enforced = try rules.peek(gpa, io, root_abs);
    defer enforced.deinit();
    if (enforced.rules.len == 0) return 0;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const message = try std.Io.Dir.cwd().readFileAlloc(io, message_path, arena, .limited(max_message_bytes));
    if (try refused(gpa, w, try rules.evaluateMessage(gpa, enforced.rules, message))) return 1;

    var staged: Staged = .{};
    defer staged.deinit(gpa);
    const merging = try receipts.git(arena, io, root_abs, &.{ "rev-parse", "-q", "--verify", "MERGE_HEAD" }) != null;
    if (!merging) {
        try readStaged(arena, gpa, io, runtime, root_abs, &staged);
        if (try refused(gpa, w, try rules.judgeUnder(gpa, io, root_abs, enforced.rules, staged.changes.items, allow_repo_memory))) return 1;
    }
    if (try refused(gpa, w, try rules.commandGate(gpa, io, root_abs, staged.targets.items, .{ .shadow_abs = root_abs, .allow_repo_memory = allow_repo_memory, .message = message }))) return 1;
    return 0;
}

pub fn writeUnchecked(w: *Writer, err: anyerror) !void {
    try w.print("emetgate: commit refused, the rules could not be checked: {t}\nfix: run emetgate doctor, or fix the cause and commit again\n", .{err});
}
