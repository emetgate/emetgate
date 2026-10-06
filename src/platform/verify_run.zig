const std = @import("std");
const checker = @import("../verify/checker.zig");
const receipt = @import("../verify/receipt.zig");
const receipts = @import("receipts.zig");
const verify_merge = @import("verify_merge.zig");
const rules = @import("rules.zig");
const runner = @import("runner.zig");
const sandbox = @import("sandbox.zig");
const shadow = @import("shadow.zig");
const exe_path = @import("exe_path.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;

const Allocator = std.mem.Allocator;
const Hash = receipt.Hash;

pub const Options = struct {
    commit: []const u8,
    test_command: ?[]const u8 = null,
    typecheck_command: ?[]const u8 = null,
    skip_tests: bool = false,
    limits: sandbox.Limits = .{},
};

pub const Result = struct {
    commit: []const u8,
    parent: ?[]const u8,
    report: checker.Report,
};

const Context = struct {
    arena: Allocator,
    io: std.Io,
    root: []const u8,
    commit: []const u8,
    parent: ?[]const u8,
    options: Options,
    tests: ?bool = null,
    tests_ran: bool = false,
    typecheck: ?bool = null,
    typecheck_ran: bool = false,
    rule_digests: std.StringHashMapUnmanaged(Hash) = .empty,

    fn blob(self: *Context, rev: ?[]const u8, path: []const u8) !?[]const u8 {
        const r = rev orelse return null;
        const spec = try std.fmt.allocPrint(self.arena, "{s}:{s}", .{ r, path });
        return receipts.git(self.arena, self.io, self.root, &.{ "cat-file", "blob", spec });
    }

    fn before(context: *anyopaque, path: []const u8) anyerror!?[]const u8 {
        const self: *Context = @ptrCast(@alignCast(context));
        return self.blob(self.parent, path);
    }

    fn after(context: *anyopaque, path: []const u8) anyerror!?[]const u8 {
        const self: *Context = @ptrCast(@alignCast(context));
        return self.blob(self.commit, path);
    }

    fn text(self: *Context, rev: ?[]const u8, path: []const u8) !checker.Text {
        const r = rev orelse return .stored;
        if (!try receipts.filtered(self.arena, self.io, self.root, r, path)) return .stored;
        const bytes = (try receipts.checkedOut(self.arena, self.io, self.root, r, path)) orelse return .unavailable;
        return .{ .driver = bytes };
    }

    fn beforeText(context: *anyopaque, path: []const u8) anyerror!checker.Text {
        const self: *Context = @ptrCast(@alignCast(context));
        return self.text(self.parent, path);
    }

    fn afterText(context: *anyopaque, path: []const u8) anyerror!checker.Text {
        const self: *Context = @ptrCast(@alignCast(context));
        return self.text(self.commit, path);
    }

    fn mentioned(context: *anyopaque, name: []const u8, except: []const u8) anyerror!bool {
        const self: *Context = @ptrCast(@alignCast(context));
        const out = (try receipts.git(self.arena, self.io, self.root, &.{ "grep", "-z", "-l", "-w", "-F", "-e", name, self.commit, "--" })) orelse return false;
        var it = std.mem.tokenizeScalar(u8, out, 0);
        while (it.next()) |entry| {
            const colon = std.mem.indexOfScalar(u8, entry, ':') orelse continue;
            if (!std.mem.eql(u8, entry[colon + 1 ..], except)) return true;
        }
        return false;
    }

    fn check(context: *anyopaque, kind: receipt.CheckKind, digest: Hash) ?bool {
        const self: *Context = @ptrCast(@alignCast(context));
        if (self.options.skip_tests) return null;
        const trusted = switch (kind) {
            .@"test" => self.options.test_command,
            .typecheck => self.options.typecheck_command,
        } orelse return null;
        if (!std.mem.eql(u8, &receipt.blake3(trusted), &digest)) return null;
        const ran = if (kind == .@"test") &self.tests_ran else &self.typecheck_ran;
        const slot = if (kind == .@"test") &self.tests else &self.typecheck;
        if (!ran.*) {
            ran.* = true;
            slot.* = self.rerun(trusted) catch null;
        }
        return slot.*;
    }

    fn rule(context: *anyopaque, id: []const u8) ?Hash {
        const self: *Context = @ptrCast(@alignCast(context));
        return self.rule_digests.get(id);
    }

    fn rerun(self: *Context, command: []const u8) !bool {
        var random: [8]u8 = undefined;
        self.io.random(&random);
        const dir = try std.fmt.allocPrint(self.arena, "{s}\\{s}\\verify\\{s}", .{ self.root, shadow.workspace_dir, &std.fmt.bytesToHex(random, .lower) });
        _ = (try receipts.git(self.arena, self.io, self.root, &.{ "worktree", "add", "--detach", "--quiet", dir, self.commit })) orelse return error.WorktreeFailed;
        defer {
            _ = receipts.git(self.arena, self.io, self.root, &.{ "worktree", "remove", "--force", dir }) catch null;
        }
        const modules = try std.fmt.allocPrint(self.arena, "{s}\\node_modules", .{self.root});
        if (std.Io.Dir.cwd().access(self.io, modules, .{})) |_| {
            const link = try std.fmt.allocPrint(self.arena, "{s}\\node_modules", .{dir});
            const cmd = exe_path.system(self.arena, "cmd.exe") catch return error.LinkFailed;
            const made = std.process.run(self.arena, self.io, .{ .argv = &.{ cmd, "/d", "/c", "mklink", "/J", link, modules } }) catch return error.LinkFailed;
            _ = made;
        } else |_| {}
        try shadow.grantLowIntegrityWrite(dir);
        const report = try runner.runCommand(self.arena, self.io, dir, command, self.options.limits);
        defer report.deinit(self.arena);
        return report.passed();
    }
};

pub fn run(gpa: Allocator, arena: Allocator, io: std.Io, runtime: *Runtime, root: []const u8, options: Options) !Result {
    _ = gpa;
    const commit = try receipts.resolveCommit(arena, io, root, options.commit);
    const parents = try verify_merge.parents(arena, io, root, commit);
    if (parents.len > 1) return .{ .commit = commit, .parent = parents[0], .report = try verify_merge.judge(arena, io, root, commit, parents) };
    const parent_spec = try std.fmt.allocPrint(arena, "{s}^", .{commit});
    const parent: ?[]const u8 = receipts.resolveCommit(arena, io, root, parent_spec) catch null;
    const changed = try receipts.changedPaths(arena, io, root, commit);
    const note = try receipts.noteBytes(arena, io, root, commit);
    var context: Context = .{ .arena = arena, .io = io, .root = root, .commit = commit, .parent = parent, .options = options };
    for (changed) |path| {
        const adopted = rules.adoptedFor(arena, io, root, path) catch continue;
        for (adopted.items) |r| try context.rule_digests.put(arena, r.id, try receipt.ruleDigest(arena, r.id, r.text, r.mode, r.check, r.where));
    }
    const report = try checker.check(arena, runtime, note, .{
        .context = &context,
        .changed = changed,
        .before = Context.before,
        .after = Context.after,
        .mentioned = Context.mentioned,
        .check = Context.check,
        .rule = Context.rule,
        .before_text = Context.beforeText,
        .after_text = Context.afterText,
    });
    return .{ .commit = commit, .parent = parent, .report = report };
}

pub fn writeJson(w: *std.Io.Writer, result: Result) !void {
    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("commit");
    try js.write(result.commit);
    try js.objectField("verdict");
    try js.write(@tagName(result.report.verdict));
    if (result.report.reason.len != 0) {
        try js.objectField("reason");
        try js.write(result.report.reason);
    }
    try js.objectField("files");
    try js.beginArray();
    for (result.report.files) |f| {
        try js.beginObject();
        try js.objectField("path");
        try js.write(f.path);
        try js.objectField("verdict");
        try js.write(@tagName(f.outcome.verdict));
        if (f.outcome.reason.len != 0) {
            try js.objectField("reason");
            try js.write(f.outcome.reason);
        }
        try js.endObject();
    }
    try js.endArray();
    try js.objectField("receipts");
    try js.beginArray();
    for (result.report.receipts) |r| {
        try js.beginObject();
        try js.objectField("id");
        try js.write(&r.id);
        try js.objectField("batch");
        try js.write(r.batch);
        try js.objectField("operation");
        try js.write(r.operation);
        try js.objectField("verdict");
        try js.write(@tagName(r.outcome.verdict));
        if (r.outcome.reason.len != 0) {
            try js.objectField("reason");
            try js.write(r.outcome.reason);
        }
        try js.endObject();
    }
    try js.endArray();
    try js.endObject();
    try w.writeByte('\n');
}

pub fn writeText(w: *std.Io.Writer, result: Result) !void {
    try w.print("commit {s}: {t}", .{ result.commit, result.report.verdict });
    if (result.report.reason.len != 0) try w.print("  ({s})", .{result.report.reason});
    try w.writeByte('\n');
    for (result.report.files) |f| {
        try w.print("  {t: <10} {s}", .{ f.outcome.verdict, f.path });
        if (f.outcome.reason.len != 0) try w.print("  ({s})", .{f.outcome.reason});
        try w.writeByte('\n');
    }
    for (result.report.receipts) |r| {
        try w.print("  receipt {s} {s}: {t}", .{ r.id[0..16], r.operation, r.outcome.verdict });
        if (r.outcome.reason.len != 0) try w.print("  ({s})", .{r.outcome.reason});
        try w.writeByte('\n');
    }
}

pub fn exitCode(verdict: checker.Verdict) u8 {
    return switch (verdict) {
        .verified => 0,
        .merged => 58,
        .unverified => 53,
        .mismatch => 54,
    };
}
