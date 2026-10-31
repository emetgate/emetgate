const std = @import("std");
const builtin = @import("builtin");
const symbol = @import("emetgate").symbol;
const handlers = @import("emetgate").handlers;
const telemetry = @import("emetgate").telemetry;
const receipts = @import("emetgate").receipts;
const commit_group = @import("emetgate").commit_group;
const verify_branch = @import("emetgate").verify_branch;
const checker = @import("emetgate").checker;
const Runtime = @import("emetgate").runtime.Runtime;
const fixture = @import("ts_fixture.zig");
const support = @import("runner_support.zig");

const testing = std.testing;
const TsRepo = fixture.TsRepo;

const add_src = "export function add(a: number, b: number): number {\n  return a + b;\n}\n";
const twice_src = "export function twice(x: number): number {\n  return x + x;\n}\n";
const green = "cmd /c exit 0";

const Case = struct {
    repo: TsRepo,
    runtime: *Runtime,
    arena_state: std.heap.ArenaAllocator,

    fn init(self: *Case) !void {
        self.repo = try TsRepo.init(&.{
            .{ .rel = "src/math.ts", .text = add_src },
            .{ .rel = "src/util.ts", .text = twice_src },
            .{ .rel = ".gitignore", .text = ".emetgate/\n" },
        });
        errdefer self.repo.deinit();
        self.runtime = try Runtime.create(testing.allocator);
        self.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    }

    fn deinit(self: *Case) void {
        self.arena_state.deinit();
        self.runtime.destroy() catch @panic("live snapshots");
        self.repo.deinit();
    }

    fn arena(self: *Case) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    fn head(self: *Case) ![]const u8 {
        return receipts.resolveCommit(self.arena(), testing.io, self.repo.root_abs, "HEAD");
    }

    /// A gated write with commits OFF: it lands in the working tree and leaves a
    /// pending receipt, but does not commit.
    fn gatedWrite(self: *Case, rel: []const u8, sym: []const u8, body: []const u8) !void {
        const file = try self.repo.abs(self.arena(), rel);
        const hash = symbol.formatHash(try support.hashOfRef(testing.allocator, testing.io, self.runtime, file, sym));
        var args: std.json.ObjectMap = .empty;
        try args.put(self.arena(), "file", .{ .string = file });
        try args.put(self.arena(), "symbol", .{ .string = sym });
        try args.put(self.arena(), "hash", .{ .string = try self.arena().dupe(u8, &hash) });
        try args.put(self.arena(), "body", .{ .string = body });
        var event: telemetry.Event = .{ .tool = "emetgate_try" };
        const result = try handlers.callTool(testing.allocator, testing.io, self.runtime, "emetgate_try", .{ .object = args }, &event, .{ .root = self.repo.root_abs, .test_command = green });
        defer testing.allocator.free(result.text);
        errdefer std.debug.print("{s}\n", .{result.text});
        try testing.expect(!result.is_error);
    }

    fn verify(self: *Case, base: []const u8) !verify_branch.Result {
        return verify_branch.run(testing.allocator, self.arena(), testing.io, self.runtime, self.repo.root_abs, .{
            .base = base,
            .head = "HEAD",
            .test_command = green,
        });
    }
};

test "emetgate_commit: groups several gated writes into one verified commit" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const base = try case.arena().dupe(u8, try case.head());

    try case.gatedWrite("src/math.ts", "add", "{\n  return b + a;\n}");
    try case.gatedWrite("src/util.ts", "twice", "{\n  return 2 * x;\n}");

    var result = try commit_group.commit(testing.allocator, testing.io, case.repo.root_abs, .{ .message = "group two", .runtime = case.runtime });
    defer result.deinit(testing.allocator);
    try testing.expect(result == .committed);
    try testing.expectEqual(@as(usize, 2), result.committed.files);
    try testing.expectEqual(@as(usize, 2), result.committed.receipts);

    // Exactly one new commit was made from the base.
    const verdict = try case.verify(base);
    try testing.expectEqual(verify_branch.BranchVerdict.verified, verdict.verdict);
    try testing.expectEqual(@as(usize, 1), verdict.count);
    try testing.expect(verdict.links[0].has_receipt);
    try testing.expectEqual(checker.Verdict.verified, verdict.links[0].verdict);
    try testing.expectEqual(@as(u8, 0), verify_branch.exitCode(verdict.verdict));
}

test "emetgate_commit: two writes to one file commit as one, honestly reported (never fabricated green)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const base = try case.arena().dupe(u8, try case.head());

    try case.gatedWrite("src/math.ts", "add", "{\n  return b + a;\n}");
    try case.gatedWrite("src/math.ts", "add", "{\n  return a + b + 0;\n}");

    var result = try commit_group.commit(testing.allocator, testing.io, case.repo.root_abs, .{ .message = "one file twice", .runtime = case.runtime });
    defer result.deinit(testing.allocator);
    try testing.expect(result == .committed);
    try testing.expectEqual(@as(usize, 1), result.committed.files);
    // Both receipts for the file are attached as one chained note.
    try testing.expectEqual(@as(usize, 2), result.committed.receipts);

    // The file's final state matches its last receipt, but the intermediate state
    // between the two writes is not present in git, so the verifier reports it
    // honestly as partial — never a fabricated "verified", and never "broken".
    const verdict = try case.verify(base);
    try testing.expectEqual(@as(usize, 1), verdict.count);
    try testing.expectEqual(verify_branch.BranchVerdict.partial, verdict.verdict);
}

test "emetgate_commit: refuses when a file was edited outside the gate" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();

    try case.gatedWrite("src/math.ts", "add", "{\n  return b + a;\n}");
    try case.gatedWrite("src/util.ts", "twice", "{\n  return 2 * x;\n}");
    // Tamper with one file after its receipt was written.
    try case.repo.write("src/math.ts", "export function add(a: number, b: number): number {\n  return a - b;\n}\n");

    var result = try commit_group.commit(testing.allocator, testing.io, case.repo.root_abs, .{ .message = "should refuse", .runtime = case.runtime });
    defer result.deinit(testing.allocator);
    try testing.expect(result == .drift);
    try testing.expectEqual(@as(usize, 1), result.drift.total);
    try testing.expectEqualStrings("src/math.ts", result.drift.paths[0]);
}

test "emetgate_commit: a gated file that git put back to HEAD is skipped, not refused as drift" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();

    try case.gatedWrite("src/math.ts", "add", "{\n  return b + a;\n}");
    try case.gatedWrite("src/util.ts", "twice", "{\n  return 2 * x;\n}");
    try case.repo.write("src/math.ts", add_src);

    var result = try commit_group.commit(testing.allocator, testing.io, case.repo.root_abs, .{ .message = "only util", .runtime = case.runtime });
    defer result.deinit(testing.allocator);
    try testing.expect(result == .committed);
    try testing.expectEqual(@as(usize, 1), result.committed.files);
}

test "emetgate_commit: nothing pending is reported, not committed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    var result = try commit_group.commit(testing.allocator, testing.io, case.repo.root_abs, .{ .message = "empty", .runtime = case.runtime });
    defer result.deinit(testing.allocator);
    try testing.expect(result == .nothing_pending);
}

test "emetgate_commit: the MCP tool commits the pending gated writes" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const base = try case.arena().dupe(u8, try case.head());

    try case.gatedWrite("src/math.ts", "add", "{\n  return b + a;\n}");
    var mcp_args: std.json.ObjectMap = .empty;
    try mcp_args.put(case.arena(), "message", .{ .string = "via mcp" });
    var mcp_event: telemetry.Event = .{ .tool = "emetgate_commit" };
    const result = try handlers.callTool(testing.allocator, testing.io, case.runtime, "emetgate_commit", .{ .object = mcp_args }, &mcp_event, .{ .root = case.repo.root_abs, .test_command = green });
    defer testing.allocator.free(result.text);
    errdefer std.debug.print("{s}\n", .{result.text});
    try testing.expect(!result.is_error);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result.text, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("committed", parsed.value.object.get("status").?.string);
    try testing.expectEqual(@as(i64, 1), parsed.value.object.get("receipts").?.integer);
    try testing.expect(std.mem.startsWith(u8, parsed.value.object.get("shortstat").?.string, "1 file changed"));

    const verdict = try case.verify(base);
    try testing.expectEqual(verify_branch.BranchVerdict.verified, verdict.verdict);
}

test "emetgate_commit: the MCP tool refuses drift and names the uncertified file" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();

    try case.gatedWrite("src/math.ts", "add", "{\n  return b + a;\n}");
    try case.repo.write("src/math.ts", "export function add(a: number, b: number): number {\n  return a - b;\n}\n");

    var mcp_args: std.json.ObjectMap = .empty;
    try mcp_args.put(case.arena(), "message", .{ .string = "should refuse" });
    var mcp_event: telemetry.Event = .{ .tool = "emetgate_commit" };
    const result = try handlers.callTool(testing.allocator, testing.io, case.runtime, "emetgate_commit", .{ .object = mcp_args }, &mcp_event, .{ .root = case.repo.root_abs, .test_command = green });
    defer testing.allocator.free(result.text);
    try testing.expect(result.is_error);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result.text, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("UncertifiedChanges", parsed.value.object.get("error").?.string);
    const paths = parsed.value.object.get("paths").?.array;
    try testing.expectEqual(@as(usize, 1), paths.items.len);
    try testing.expectEqualStrings("src/math.ts", paths.items[0].string);
}

const run_command = @import("emetgate").run_command;
const git_fixture = @import("git_fixture.zig");

fn runReceipt(root: []const u8, files: []const receipts.FileChange) !void {
    const written = try receipts.write(testing.allocator, testing.io, root, .{
        .operation = .run,
        .class = .spending,
        .evidence = "run",
        .files = files,
        .test_command = "npm install",
        .check_kind = .run,
        .integrity = "user",
        .version = "test",
    });
    testing.allocator.free(written.batch);
}

test "emetgate_commit: files a run created or changed commit through the run receipt" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const base = try case.arena().dupe(u8, try case.head());
    const old = try case.repo.read("src/util.ts");
    defer testing.allocator.free(old);
    try case.repo.write("src/util.ts", "export const lock = 1;\n");
    try case.repo.write("package-lock.json", "{}\n");
    try runReceipt(case.repo.root_abs, &.{
        .{ .rel = "src/util.ts", .before = @import("emetgate").receipt.blake3(old), .after_abs = try case.repo.abs(case.arena(), "src/util.ts") },
        .{ .rel = "package-lock.json", .before = null, .after_abs = try case.repo.abs(case.arena(), "package-lock.json") },
    });

    var result = try commit_group.commit(testing.allocator, testing.io, case.repo.root_abs, .{ .message = "lock", .runtime = case.runtime });
    defer result.deinit(testing.allocator);
    try testing.expect(result == .committed);
    try testing.expectEqual(@as(usize, 2), result.committed.files);

    const verdict = try case.verify(base);
    try testing.expectEqual(@as(usize, 1), verdict.count);
    try testing.expect(verdict.links[0].has_receipt);
    try testing.expectEqual(checker.Verdict.unverified, verdict.links[0].verdict);
}

test "emetgate_commit: a run receipt makes the first commit of an unborn branch" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "repo");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.gitignore", .data = ".emetgate/\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/package.json", .data = "{\"name\":\"x\"}\n" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, "repo", testing.allocator);
    defer testing.allocator.free(root);
    try git_fixture.initRepo(root);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try runReceipt(root, &.{
        .{ .rel = ".gitignore", .before = null, .after_abs = try std.fmt.allocPrint(arena, "{s}\\.gitignore", .{root}) },
        .{ .rel = "package.json", .before = null, .after_abs = try std.fmt.allocPrint(arena, "{s}\\package.json", .{root}) },
    });
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    var result = try commit_group.commit(testing.allocator, testing.io, root, .{ .message = "init", .runtime = runtime });
    defer result.deinit(testing.allocator);
    errdefer std.debug.print("{any}\n", .{result});
    try testing.expect(result == .committed);
    try testing.expectEqual(@as(usize, 2), result.committed.files);
    const tree = try receipts.git(arena, testing.io, root, &.{ "ls-tree", "-r", "--name-only", "HEAD" });
    try testing.expect(std.mem.indexOf(u8, tree.?, "package.json") != null);
}

test "emetgate_run: a toolchain command that writes files leaves a run receipt for them" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    var ran = run_command.runInRepo(testing.allocator, testing.io, case.repo.root_abs, "npm init -y", run_command.toolchain_limits, "test") catch return error.SkipZigTest;
    defer ran.report.deinit(testing.allocator);
    switch (ran.report.outcome) {
        .exited => |code| if (code != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }
    try testing.expect(ran.receipt != null);
    try testing.expectEqual(@as(usize, 1), ran.changed);

    var result = try commit_group.commit(testing.allocator, testing.io, case.repo.root_abs, .{ .message = "package", .runtime = case.runtime });
    defer result.deinit(testing.allocator);
    try testing.expect(result == .committed);
    try testing.expectEqual(@as(usize, 1), result.committed.files);
}

test "emetgate_commit: a new file staged with other content than its run receipt is refused, the staged copy kept" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.repo.write("package-lock.json", "{\"staged\":true}\n");
    try @import("runner_support.zig").Repo.git(case.repo.root_abs, &.{ "add", "package-lock.json" });
    try case.repo.write("package-lock.json", "{}\n");
    try runReceipt(case.repo.root_abs, &.{
        .{ .rel = "package-lock.json", .before = null, .after_abs = try case.repo.abs(case.arena(), "package-lock.json") },
    });

    const before = try case.arena().dupe(u8, try case.head());
    var result = commit_group.commit(testing.allocator, testing.io, case.repo.root_abs, .{ .message = "lock", .runtime = case.runtime }) catch |err| {
        try testing.expectEqual(error.TargetHasUncommittedChanges, err);
        try testing.expectEqualStrings(before, try case.head());
        return;
    };
    defer result.deinit(testing.allocator);
    return error.TestUnexpectedResult;
}

const toValue = @import("commit_batch.zig").toValue;

const Sequence = struct {
    case: Case,

    fn init(self: *Sequence) !void {
        try self.case.init();
    }

    fn deinit(self: *Sequence) void {
        self.case.deinit();
    }

    fn arena(self: *Sequence) std.mem.Allocator {
        return self.case.arena();
    }

    fn abs(self: *Sequence, rel: []const u8) ![]const u8 {
        return self.case.repo.abs(self.arena(), rel);
    }

    fn call(self: *Sequence, tool: []const u8, args: anytype) !std.json.Value {
        var event: telemetry.Event = .{ .tool = tool };
        const result = try handlers.callTool(testing.allocator, testing.io, self.case.runtime, tool, try toValue(self.arena(), args), &event, .{ .root = self.case.repo.root_abs, .test_command = green });
        defer testing.allocator.free(result.text);
        const text = try self.arena().dupe(u8, result.text);
        const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
        return std.json.parseFromSliceLeaky(std.json.Value, self.arena(), text[0..end], .{});
    }

    fn write(self: *Sequence, tool: []const u8, args: anytype) !void {
        const reply = try self.call(tool, args);
        errdefer std.debug.print("{s}: {f}\n", .{ tool, std.json.fmt(reply, .{}) });
        try testing.expect(!std.mem.eql(u8, reply.object.get("status").?.string, "error"));
    }

    fn fileHash(self: *Sequence, rel: []const u8) ![]const u8 {
        const text = try self.case.repo.read(rel);
        defer testing.allocator.free(text);
        return self.arena().dupe(u8, &symbol.formatHash(symbol.fileHash(text)));
    }

    fn git(self: *Sequence, argv: []const []const u8) ![]const u8 {
        return (try receipts.git(self.arena(), testing.io, self.case.repo.root_abs, argv)) orelse error.GitCommandFailed;
    }

    fn commitAll(self: *Sequence, tree: []const u8) !void {
        const reply = try self.call("emetgate_commit", .{ .message = "feat: one commit" });
        errdefer std.debug.print("emetgate_commit: {f}\n", .{std.json.fmt(reply, .{})});
        try testing.expectEqualStrings("committed", reply.object.get("status").?.string);
        try testing.expectEqualStrings("", try self.git(&.{ "status", "--porcelain", "--untracked-files=all" }));
        try testing.expectEqualStrings(tree, try self.git(&.{ "ls-tree", "-r", "--name-only", "HEAD" }));
    }
};

test "emetgate_commit: a batch that creates files, then two edits of one of them, commit as one" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var seq: Sequence = undefined;
    try seq.init();
    defer seq.deinit();
    try seq.write("emetgate_try_batch", .{ .edits = .{
        .{ .file = "notes/plan.txt", .hash = "absent", .content = "plan\n" },
        .{ .file = "notes/cli.txt", .hash = "absent", .content = "assert one\nassert two\n" },
    } });
    try seq.write("emetgate_edit", .{ .file = "notes/cli.txt", .old_string = "assert one", .new_string = "assert uno" });
    try seq.write("emetgate_edit", .{ .file = "notes/cli.txt", .old_string = "assert two", .new_string = "assert dos" });
    try seq.commitAll(".gitignore\nnotes/cli.txt\nnotes/plan.txt\nsrc/math.ts\nsrc/util.ts\n");
    try testing.expectEqualStrings("assert uno\nassert dos\n", try seq.git(&.{ "show", "HEAD:notes/cli.txt" }));
}

test "emetgate_commit: files created one by one with emetgate_write, one edited after, commit as one" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var seq: Sequence = undefined;
    try seq.init();
    defer seq.deinit();
    try seq.write("emetgate_write", .{ .file = "notes/a.txt", .content = "a\n" });
    try seq.write("emetgate_write", .{ .file = "notes/b.txt", .content = "b one\n" });
    try seq.write("emetgate_edit", .{ .file = "notes/b.txt", .old_string = "b one", .new_string = "b two" });
    try seq.commitAll(".gitignore\nnotes/a.txt\nnotes/b.txt\nsrc/math.ts\nsrc/util.ts\n");
}

test "emetgate_commit: create, modify, modify again commits the last content" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var seq: Sequence = undefined;
    try seq.init();
    defer seq.deinit();
    try seq.write("emetgate_write", .{ .file = "notes/c.txt", .content = "one\n" });
    try seq.write("emetgate_write", .{ .file = "notes/c.txt", .content = "two\n" });
    try seq.write("emetgate_edit", .{ .file = "notes/c.txt", .old_string = "two", .new_string = "three" });
    try seq.commitAll(".gitignore\nnotes/c.txt\nsrc/math.ts\nsrc/util.ts\n");
    try testing.expectEqualStrings("three\n", try seq.git(&.{ "show", "HEAD:notes/c.txt" }));
}

test "emetgate_commit: create, move, modify commits the file at its new place" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var seq: Sequence = undefined;
    try seq.init();
    defer seq.deinit();
    try seq.write("emetgate_write", .{ .file = "src/d.ts", .content = "export const d = 1;\n" });
    try seq.write("emetgate_move_file", .{ .from = try seq.abs("src/d.ts"), .to = try seq.abs("lib/d.ts"), .from_hash = try seq.fileHash("src/d.ts") });
    try seq.write("emetgate_edit", .{ .file = "lib/d.ts", .old_string = "d = 1", .new_string = "d = 2" });
    try seq.commitAll(".gitignore\nlib/d.ts\nsrc/math.ts\nsrc/util.ts\n");
    try testing.expectEqualStrings("export const d = 2;\n", try seq.git(&.{ "show", "HEAD:lib/d.ts" }));
}

test "emetgate_commit: a tracked file moved, then modified, commits as the move" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var seq: Sequence = undefined;
    try seq.init();
    defer seq.deinit();
    try seq.write("emetgate_move_file", .{ .from = try seq.abs("src/util.ts"), .to = try seq.abs("lib/util.ts"), .from_hash = try seq.fileHash("src/util.ts") });
    try seq.write("emetgate_edit", .{ .file = "lib/util.ts", .old_string = "x + x", .new_string = "2 * x" });
    try seq.commitAll(".gitignore\nlib/util.ts\nsrc/math.ts\n");
}

test "emetgate_commit: a batch with two edits of a created file, then a batch deleting files, commit as one" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var seq: Sequence = undefined;
    try seq.init();
    defer seq.deinit();
    try seq.write("emetgate_write", .{ .file = "notes/e.txt", .content = "first\nsecond\n" });
    try seq.write("emetgate_try_batch", .{ .edits = .{
        .{ .file = try seq.abs("notes/e.txt"), .old_string = "first", .new_string = "1st" },
        .{ .file = try seq.abs("notes/e.txt"), .old_string = "second", .new_string = "2nd" },
        .{ .file = "notes/gone.txt", .hash = "absent", .content = "gone\n" },
    } });
    try seq.write("emetgate_try_batch", .{ .edits = .{
        .{ .file = try seq.abs("notes/gone.txt"), .op = "delete", .hash = try seq.fileHash("notes/gone.txt") },
        .{ .file = try seq.abs("src/util.ts"), .op = "delete", .hash = try seq.fileHash("src/util.ts") },
    } });
    try seq.commitAll(".gitignore\nnotes/e.txt\nsrc/math.ts\n");
    try testing.expectEqualStrings("1st\n2nd\n", try seq.git(&.{ "show", "HEAD:notes/e.txt" }));
}

test "emetgate_commit: a created file staged by hand with other content is refused with a one-step fix" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var seq: Sequence = undefined;
    try seq.init();
    defer seq.deinit();
    try seq.write("emetgate_write", .{ .file = "notes/f.txt", .content = "gated\n" });
    try seq.case.repo.write("notes/f.txt", "by hand\n");
    _ = try seq.git(&.{ "add", "--", "notes/f.txt" });
    try seq.case.repo.write("notes/f.txt", "gated\n");
    const before = try seq.arena().dupe(u8, try seq.case.head());

    const refused = try seq.call("emetgate_commit", .{ .message = "feat: one commit" });
    errdefer std.debug.print("emetgate_commit: {f}\n", .{std.json.fmt(refused, .{})});
    try testing.expectEqualStrings("TargetHasUncommittedChanges", refused.object.get("error").?.string);
    const paths = refused.object.get("paths") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("notes/f.txt", paths.array.items[0].string);
    const fix = (refused.object.get("fix") orelse return error.TestUnexpectedResult).string;
    try testing.expect(std.mem.indexOf(u8, fix, "[\"restore\",\"--staged\",\"--\",\"notes/f.txt\"]") != null);
    try testing.expectEqualStrings(before, try seq.case.head());
    try testing.expect(std.mem.indexOf(u8, try seq.git(&.{ "diff", "--cached" }), "+by hand") != null);

    _ = try seq.git(&.{ "restore", "--staged", "--", "notes/f.txt" });
    try seq.commitAll(".gitignore\nnotes/f.txt\nsrc/math.ts\nsrc/util.ts\n");
}

test "emetgate_commit: a created file edited by hand after its gated writes is still refused as drift" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var seq: Sequence = undefined;
    try seq.init();
    defer seq.deinit();
    try seq.write("emetgate_write", .{ .file = "notes/g.txt", .content = "gated\n" });
    try seq.write("emetgate_edit", .{ .file = "notes/g.txt", .old_string = "gated", .new_string = "gated twice" });
    try seq.case.repo.write("notes/g.txt", "by hand\n");
    const before = try seq.arena().dupe(u8, try seq.case.head());
    const refused = try seq.call("emetgate_commit", .{ .message = "feat: one commit" });
    try testing.expectEqualStrings("UncertifiedChanges", refused.object.get("error").?.string);
    try testing.expectEqualStrings(before, try seq.case.head());
}
