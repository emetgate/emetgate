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
