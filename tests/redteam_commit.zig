const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");
const handlers = emetgate.handlers;
const telemetry = emetgate.telemetry;
const memory = emetgate.memory;
const git_commit = emetgate.git_commit;
const verify_run = emetgate.verify_run;
const receipts = emetgate.receipts;
const shadow_root = emetgate.shadow_root;
const text_checks = emetgate.text_checks;
const Policy = @typeInfo(@TypeOf(handlers.callTool)).@"fn".params[6].type.?;
const Runtime = emetgate.runtime.Runtime;
const fixture = @import("ts_fixture.zig");
const support = @import("runner_support.zig");
const git_fixture = @import("git_fixture.zig");

const testing = std.testing;
const TsRepo = fixture.TsRepo;
const Value = std.json.Value;

const util_src = "export function add(a: number, b: number): number {\n  return a + b;\n}\n\nexport function sub(a: number, b: number): number {\n  return a - b;\n}\n";
const util_hand = "export function add(a: number, b: number): number {\n  return a + b;\n}\n\nexport function sub(a: number, b: number): number {\n  return a - b - 0;\n}\n";
const hand_mark = "a - b - 0";
const new_body = "{\n  return b + a;\n}";
const model_mark = "b + a";
const green = "cmd /c exit 0";
const red = "cmd /c exit 1";
const ignore_workspace: fixture.File = .{ .rel = ".gitignore", .text = ".emetgate/\n" };
const util_file: fixture.File = .{ .rel = "src/util.ts", .text = util_src };

const committing: Policy = .{ .test_command = green, .commit = true };

fn skipOffWindows() !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
}

const Case = struct {
    repo: TsRepo,
    runtime: *Runtime,
    arena_state: std.heap.ArenaAllocator,

    fn init(self: *Case, files: []const fixture.File) !void {
        self.repo = try TsRepo.init(files);
        errdefer self.repo.deinit();
        self.runtime = try Runtime.create(testing.allocator);
        self.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    }

    fn initDefault(self: *Case) !void {
        try self.init(&.{ util_file, ignore_workspace });
    }

    fn deinit(self: *Case) void {
        self.arena_state.deinit();
        self.runtime.destroy() catch @panic("live snapshots");
        self.repo.deinit();
    }

    fn arena(self: *Case) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    fn gitRaw(self: *Case, argv: []const []const u8) !?[]const u8 {
        var full: std.ArrayList([]const u8) = .empty;
        try full.append(self.arena(), "git");
        try full.appendSlice(self.arena(), argv);
        const result = try std.process.run(self.arena(), testing.io, .{ .argv = full.items, .cwd = .{ .path = self.repo.root_abs }, .stdout_limit = .limited(4 * 1024 * 1024) });
        return switch (result.term) {
            .exited => |code| if (code == 0) result.stdout else null,
            else => null,
        };
    }

    fn git(self: *Case, argv: []const []const u8) ![]const u8 {
        const out = (try self.gitRaw(argv)) orelse return error.GitCommandFailed;
        return std.mem.trim(u8, out, " \r\n");
    }

    fn hashOf(self: *Case, rel: []const u8, ref: []const u8) ![]const u8 {
        const file = try self.repo.abs(self.arena(), rel);
        const hash = try support.hashOfRef(testing.allocator, testing.io, self.runtime, file, ref);
        return self.arena().dupe(u8, &std.fmt.bytesToHex(hash, .lower));
    }

    fn disk(self: *Case, rel: []const u8) ![]const u8 {
        const bytes = try self.repo.read(rel);
        defer testing.allocator.free(bytes);
        return self.arena().dupe(u8, bytes);
    }

    const Reply = struct { value: Value, is_error: bool, text: []const u8 };

    fn call(self: *Case, tool: []const u8, fields: []const [2][]const u8, policy: Policy) !Reply {
        var map: std.json.ObjectMap = .empty;
        for (fields) |field| {
            const value = if (std.mem.eql(u8, field[0], "file")) try self.repo.abs(self.arena(), field[1]) else field[1];
            try map.put(self.arena(), field[0], .{ .string = value });
        }
        var event: telemetry.Event = .{ .tool = tool };
        var with_root = policy;
        with_root.root = self.repo.root_abs;
        const result = try handlers.callTool(testing.allocator, testing.io, self.runtime, tool, .{ .object = map }, &event, with_root);
        defer testing.allocator.free(result.text);
        const text = try self.arena().dupe(u8, result.text);
        return .{ .value = try std.json.parseFromSliceLeaky(Value, self.arena(), text, .{}), .is_error = result.is_error, .text = text };
    }

    fn swap(self: *Case, rel: []const u8, body: []const u8, message: []const u8, policy: Policy) !Reply {
        return self.call("emetgate_try", &.{ .{ "file", rel }, .{ "symbol", "add" }, .{ "hash", try self.hashOf(rel, "add") }, .{ "body", body }, .{ "message", message } }, policy);
    }

    fn headBlob(self: *Case, rel: []const u8) ![]const u8 {
        const spec = try std.fmt.allocPrint(self.arena(), "HEAD:{s}", .{rel});
        return (try self.gitRaw(&.{ "cat-file", "blob", spec })) orelse error.GitCommandFailed;
    }

    fn verdict(self: *Case) !emetgate.checker.Verdict {
        return self.verdictWith(green);
    }

    fn verdictWith(self: *Case, test_command: []const u8) !emetgate.checker.Verdict {
        const result = try verify_run.run(testing.allocator, self.arena(), testing.io, self.runtime, self.repo.root_abs, .{ .commit = "HEAD", .test_command = test_command });
        return result.report.verdict;
    }
};

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "redteam commit: with autocrlf on the commit holds the bytes the gate tested" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.initDefault();
    defer case.deinit();
    _ = try case.git(&.{ "config", "core.autocrlf", "true" });

    const reply = try case.swap("src/util.ts", "{\r\n  return b + a;\r\n}", "fix: swap", committing);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    const tested = try case.disk("src/util.ts");
    try testing.expect(contains(tested, "\r\n"));
    try testing.expectEqualStrings(tested, try case.headBlob("src/util.ts"));
}

test "redteam commit: with autocrlf on a fresh checkout of the commit gives back the tested bytes" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.initDefault();
    defer case.deinit();
    _ = try case.git(&.{ "config", "core.autocrlf", "true" });

    const reply = try case.swap("src/util.ts", "{\r\n  return b + a;\r\n}", "fix: swap", committing);
    try testing.expect(!reply.is_error);
    const tested = try case.disk("src/util.ts");
    try case.repo.tmp.dir.deleteFile(testing.io, "repo/src/util.ts");
    _ = try case.git(&.{ "checkout", "-q", "HEAD", "--", "src/util.ts" });
    try testing.expectEqualStrings(tested, try case.disk("src/util.ts"));
}

test "redteam commit: with autocrlf on verify accepts the commit emetgate just made" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.initDefault();
    defer case.deinit();
    _ = try case.git(&.{ "config", "core.autocrlf", "true" });

    const reply = try case.swap("src/util.ts", "{\r\n  return b + a;\r\n}", "fix: swap", committing);
    try testing.expect(!reply.is_error);
    try testing.expectEqual(emetgate.checker.Verdict.verified, try case.verdict());
}

test "redteam commit: a cloned gitattributes ident filter does not change the committed bytes" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.init(&.{ util_file, ignore_workspace, .{ .rel = ".gitattributes", .text = "*.ts ident\n" } });
    defer case.deinit();
    _ = try case.git(&.{ "config", "core.autocrlf", "false" });

    const reply = try case.swap("src/util.ts", "{\n  return \"$Id: tested $\".length + b + a;\n}", "fix: swap", committing);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    const tested = try case.disk("src/util.ts");
    try testing.expect(contains(tested, "$Id: tested $"));
    try testing.expectEqualStrings(tested, try case.headBlob("src/util.ts"));
}

test "redteam commit: a cloned gitattributes eol rule does not change the committed bytes" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.init(&.{ util_file, ignore_workspace, .{ .rel = ".gitattributes", .text = "*.ts text eol=lf\n" } });
    defer case.deinit();
    _ = try case.git(&.{ "config", "core.autocrlf", "false" });

    const reply = try case.swap("src/util.ts", "{\r\n  return b + a;\r\n}", "fix: swap", committing);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings(try case.disk("src/util.ts"), try case.headBlob("src/util.ts"));
}

test "redteam commit: a hand edit hidden by assume-unchanged is not committed under the model's message" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.initDefault();
    defer case.deinit();
    _ = try case.git(&.{ "update-index", "--assume-unchanged", "src/util.ts" });
    try case.repo.write("src/util.ts", util_hand);
    try testing.expectEqualStrings("", try case.git(&.{ "status", "--porcelain" }));

    const reply = try case.swap("src/util.ts", new_body, "fix: swap", committing);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(contains(try case.disk("src/util.ts"), hand_mark));
    try testing.expect(!contains(try case.headBlob("src/util.ts"), hand_mark));
}

test "redteam commit: a hand edit hidden by skip-worktree is not committed under the model's message" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.initDefault();
    defer case.deinit();
    _ = try case.git(&.{ "update-index", "--skip-worktree", "src/util.ts" });
    try case.repo.write("src/util.ts", util_hand);
    try testing.expectEqualStrings("", try case.git(&.{ "status", "--porcelain" }));

    const reply = try case.swap("src/util.ts", new_body, "fix: swap", committing);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(contains(try case.disk("src/util.ts"), hand_mark));
    try testing.expect(!contains(try case.headBlob("src/util.ts"), hand_mark));
}

test "redteam commit: a file the user keeps ignored is not put into history by a try on it" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.init(&.{ util_file, .{ .rel = ".gitignore", .text = ".emetgate/\nsrc/local.ts\n" } });
    defer case.deinit();
    try case.repo.write("src/local.ts", "export const token = \"private-value\";\n\n" ++ util_src);
    try testing.expectEqualStrings("", try case.git(&.{ "status", "--porcelain" }));
    const before = try case.git(&.{ "rev-parse", "HEAD" });

    const reply = try case.swap("src/local.ts", new_body, "fix: swap", committing);
    errdefer std.debug.print("{s}\n", .{reply.text});
    const tree = try case.git(&.{ "ls-tree", "-r", "--name-only", "HEAD" });
    try testing.expect(!contains(tree, "src/local.ts"));
    try testing.expectEqualStrings(before, try case.git(&.{ "rev-parse", "HEAD" }));
}

test "redteam commit: a file outside the sparse checkout is not replaced by a create on its path" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.init(&.{ util_file, ignore_workspace, .{ .rel = "src/other.ts", .text = "export function kept(): number {\n  return 7;\n}\n" } });
    defer case.deinit();
    _ = try case.git(&.{ "update-index", "--skip-worktree", "src/other.ts" });
    try case.repo.tmp.dir.deleteFile(testing.io, "repo/src/other.ts");
    try testing.expectEqualStrings("", try case.git(&.{ "status", "--porcelain" }));

    const reply = try case.call("emetgate_try", &.{ .{ "file", "src/other.ts" }, .{ "symbol", "fresh" }, .{ "hash", "absent" }, .{ "body", "export function fresh(): number {\n  return 1;\n}\n" }, .{ "message", "feat: fresh" } }, committing);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try testing.expect(contains(try case.headBlob("src/other.ts"), "kept"));
    try testing.expectEqualStrings("", try case.git(&.{ "status", "--porcelain" }));
}

test "redteam commit: a target named in another letter case is still seen as edited by hand" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.initDefault();
    defer case.deinit();
    const before = try case.git(&.{ "rev-parse", "HEAD" });
    try case.repo.write("src/util.ts", util_hand);

    const reply = try case.call("emetgate_try", &.{ .{ "file", "SRC/UTIL.TS" }, .{ "symbol", "add" }, .{ "hash", try case.hashOf("src/util.ts", "add") }, .{ "body", new_body }, .{ "message", "fix: swap" } }, committing);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try testing.expect(contains(reply.text, "TargetHasUncommittedChanges"));
    try testing.expectEqualStrings(before, try case.git(&.{ "rev-parse", "HEAD" }));
    try testing.expectEqualStrings(util_hand, try case.disk("src/util.ts"));
}

test "redteam commit: a target named in another letter case commits the one tracked path" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.initDefault();
    defer case.deinit();

    const reply = try case.call("emetgate_try", &.{ .{ "file", "SRC/UTIL.TS" }, .{ "symbol", "add" }, .{ "hash", try case.hashOf("src/util.ts", "add") }, .{ "body", new_body }, .{ "message", "fix: swap" } }, committing);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings(".gitignore\nsrc/util.ts", try case.git(&.{ "ls-tree", "-r", "--name-only", "HEAD" }));
    try testing.expectEqualStrings("", try case.git(&.{ "status", "--porcelain" }));
}

fn installAbortingHook(case: *Case) !void {
    try case.repo.tmp.dir.createDirPath(testing.io, "repo/.git/hooks");
    try case.repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.git/hooks/reference-transaction", .data = "#!/bin/sh\nexit 1\n" });
}

test "redteam commit: when the branch cannot move the reply names the state" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.initDefault();
    defer case.deinit();
    try installAbortingHook(&case);

    const reply = try case.swap("src/util.ts", new_body, "fix: swap", committing);
    try testing.expect(reply.is_error);
    try testing.expect(contains(reply.text, "WrittenButNotCommitted"));
}

test "redteam commit: when the branch cannot move no write is left without a commit" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.initDefault();
    defer case.deinit();
    try installAbortingHook(&case);

    const reply = try case.swap("src/util.ts", new_body, "fix: swap", committing);
    errdefer std.debug.print("{s}\n", .{reply.text});
    const written = contains(try case.disk("src/util.ts"), model_mark);
    const committed = contains(try case.headBlob("src/util.ts"), model_mark);
    try testing.expectEqual(written, committed);
}

test "redteam commit: a write left without a commit cannot be committed by the next call under a new message" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.initDefault();
    defer case.deinit();
    try installAbortingHook(&case);
    const before = try case.git(&.{ "rev-parse", "HEAD" });
    _ = try case.swap("src/util.ts", new_body, "fix: swap", committing);
    try case.repo.tmp.dir.deleteFile(testing.io, "repo/.git/hooks/reference-transaction");

    const next = try case.call("emetgate_try", &.{ .{ "file", "src/util.ts" }, .{ "symbol", "sub" }, .{ "hash", try case.hashOf("src/util.ts", "sub") }, .{ "body", "{\n  return a - b - 1;\n}" }, .{ "message", "fix: another message" } }, committing);
    try testing.expect(next.is_error);
    try testing.expect(contains(next.text, "TargetHasUncommittedChanges"));
    try testing.expectEqualStrings(before, try case.git(&.{ "rev-parse", "HEAD" }));
}

fn raceCommit(root_abs: []const u8, shadow_abs: []const u8) void {
    const io = testing.io;
    var started_buf: [std.fs.max_path_bytes]u8 = undefined;
    var raced_buf: [std.fs.max_path_bytes]u8 = undefined;
    const started = std.fmt.bufPrint(&started_buf, "{s}\\started", .{shadow_abs}) catch return;
    const raced = std.fmt.bufPrint(&raced_buf, "{s}\\raced", .{shadow_abs}) catch return;
    var attempt: usize = 0;
    while (attempt < 3000) : (attempt += 1) {
        if (std.Io.Dir.cwd().access(io, started, .{})) |_| break else |_| {}
        io.sleep(.fromMilliseconds(10), .awake) catch return;
    } else return;
    support.Repo.git(root_abs, &.{ "commit", "-q", "--allow-empty", "-m", "user: an unrelated commit" }) catch {};
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = raced, .data = "" }) catch return;
}

const racing_cmd = "echo.> started & (for /l %i in (1,1,3000) do @if exist raced (exit 0) else ping -n 1 127.0.0.1 >nul) & exit 1";

test "redteam commit: a user commit made while the tests run leaves no write without a commit" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.initDefault();
    defer case.deinit();
    const location = try shadow_root.locate(testing.allocator, case.repo.root_abs, null);
    defer location.deinit(testing.allocator);

    const hash = try case.hashOf("src/util.ts", "add");
    const racer = try std.Thread.spawn(.{}, raceCommit, .{ @as([]const u8, case.repo.root_abs), @as([]const u8, location.shadow) });
    const outcome = case.call("emetgate_try", &.{ .{ "file", "src/util.ts" }, .{ "symbol", "add" }, .{ "hash", hash }, .{ "body", new_body }, .{ "message", "fix: swap" } }, .{ .test_command = racing_cmd, .commit = true });
    racer.join();
    const reply = try outcome;
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expectEqualStrings("user: an unrelated commit", try case.git(&.{ "log", "-1", "--format=%s", "--grep=user:" }));
    const written = contains(try case.disk("src/util.ts"), model_mark);
    const committed = contains(try case.headBlob("src/util.ts"), model_mark);
    try testing.expectEqual(written, committed);
}

test "redteam commit: a user commit made while the tests run is not overwritten" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.initDefault();
    defer case.deinit();
    const location = try shadow_root.locate(testing.allocator, case.repo.root_abs, null);
    defer location.deinit(testing.allocator);

    const hash = try case.hashOf("src/util.ts", "add");
    const racer = try std.Thread.spawn(.{}, raceCommit, .{ @as([]const u8, case.repo.root_abs), @as([]const u8, location.shadow) });
    const outcome = case.call("emetgate_try", &.{ .{ "file", "src/util.ts" }, .{ "symbol", "add" }, .{ "hash", hash }, .{ "body", new_body }, .{ "message", "fix: swap" } }, .{ .test_command = racing_cmd, .commit = true });
    racer.join();
    _ = try outcome;
    const log = try case.git(&.{ "log", "--format=%s" });
    try testing.expect(contains(log, "user: an unrelated commit"));
}

test "redteam commit: a stale index lock does not leave the index behind the new commit" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.initDefault();
    defer case.deinit();
    try case.repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.git/index.lock", .data = "" });

    const reply = try case.swap("src/util.ts", new_body, "fix: swap", committing);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try case.repo.tmp.dir.deleteFile(testing.io, "repo/.git/index.lock");
    try testing.expectEqualStrings("", try case.git(&.{ "diff", "--cached", "--name-only" }));
}

test "redteam commit: when the index cannot be updated the reply still carries the commit it made" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.initDefault();
    defer case.deinit();
    const before = try case.git(&.{ "rev-parse", "HEAD" });
    try case.repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.git/index.lock", .data = "" });

    const reply = try case.swap("src/util.ts", new_body, "fix: swap", committing);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try case.repo.tmp.dir.deleteFile(testing.io, "repo/.git/index.lock");
    const head = try case.git(&.{ "rev-parse", "HEAD" });
    if (!std.mem.eql(u8, before, head)) try testing.expect(contains(reply.text, head));
}

test "redteam commit: a rejected call leaves a clean status in a repository that does not ignore the workspace" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.init(&.{util_file});
    defer case.deinit();
    const before = try case.git(&.{ "rev-parse", "HEAD" });

    const reply = try case.swap("src/util.ts", new_body, "fix: swap", .{ .test_command = red, .commit = true });
    try testing.expect(reply.is_error);
    try testing.expectEqualStrings(before, try case.git(&.{ "rev-parse", "HEAD" }));
    try testing.expectEqualStrings("", try case.git(&.{ "status", "--porcelain" }));
}

test "redteam commit: design limit: an accepted call leaves its receipts untracked in a repository that does not ignore the workspace" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.init(&.{util_file});
    defer case.deinit();

    const reply = try case.swap("src/util.ts", new_body, "fix: swap", committing);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings("?? .emetgate/", try case.git(&.{ "status", "--porcelain" }));
    try testing.expectEqualStrings("M\tsrc/util.ts", try case.git(&.{ "diff", "--name-status", "HEAD^", "HEAD" }));
}

test "redteam commit: a receipt of a discarded earlier write is not attached to the commit" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.initDefault();
    defer case.deinit();
    const hash = try case.hashOf("src/util.ts", "add");
    const loose = try case.call("emetgate_try", &.{ .{ "file", "src/util.ts" }, .{ "symbol", "add" }, .{ "hash", hash }, .{ "body", "{\n  return a + b + 100;\n}" } }, .{ .test_command = green });
    try testing.expect(!loose.is_error);
    _ = try case.git(&.{ "checkout", "-q", "--", "src/util.ts" });

    const reply = try case.swap("src/util.ts", new_body, "fix: swap", committing);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    const note = (try receipts.noteBytes(case.arena(), testing.io, case.repo.root_abs, "HEAD")).?;
    const parsed = try std.json.parseFromSliceLeaky(Value, case.arena(), note, .{});
    try testing.expectEqual(@as(usize, 1), parsed.array.items.len);
}

test "redteam commit: verify accepts a commit made after a discarded earlier write" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.initDefault();
    defer case.deinit();
    const hash = try case.hashOf("src/util.ts", "add");
    const loose = try case.call("emetgate_try", &.{ .{ "file", "src/util.ts" }, .{ "symbol", "add" }, .{ "hash", hash }, .{ "body", "{\n  return a + b + 100;\n}" } }, .{ .test_command = green });
    try testing.expect(!loose.is_error);
    _ = try case.git(&.{ "checkout", "-q", "--", "src/util.ts" });

    const reply = try case.swap("src/util.ts", new_body, "fix: swap", committing);
    try testing.expect(!reply.is_error);
    try testing.expectEqual(emetgate.checker.Verdict.verified, try case.verdict());
}

test "redteam commit: verify accepts a plain commit emetgate made" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.initDefault();
    defer case.deinit();
    _ = try case.git(&.{ "config", "core.autocrlf", "false" });
    const reply = try case.swap("src/util.ts", new_body, "fix: swap", committing);
    try testing.expect(!reply.is_error);
    try testing.expectEqual(emetgate.checker.Verdict.verified, try case.verdict());
}

test "redteam commit: a commit encoding setting does not mislabel the UTF-8 message" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.initDefault();
    defer case.deinit();
    _ = try case.git(&.{ "config", "i18n.commitEncoding", "ISO-8859-9" });
    const message = "docs: türkçe başlık";

    const reply = try case.swap("src/util.ts", new_body, message, committing);
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings(message, try case.git(&.{ "-c", "i18n.logOutputEncoding=UTF-8", "log", "-1", "--format=%B" }));
}

test "redteam commit: a message with comment lines, a leading dash and carriage returns is stored byte for byte" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.initDefault();
    defer case.deinit();
    const message = "-F /etc/passwd\n# not a comment\r\n\n\n  indented\n#\n--amend\nSigned-off-by: A <a@example.com>";

    const reply = try case.swap("src/util.ts", new_body, message, committing);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    const raw = (try case.gitRaw(&.{ "cat-file", "commit", "HEAD" })).?;
    const split = std.mem.indexOf(u8, raw, "\n\n").?;
    try testing.expectEqualStrings(message ++ "\n", raw[split + 2 ..]);
    try testing.expectEqualStrings("M\tsrc/util.ts", try case.git(&.{ "diff", "--name-status", "HEAD^", "HEAD" }));
}

test "redteam commit: a path with a space, a comma, brackets and a non-ASCII letter is one clean commit" {
    try skipOffWindows();
    var case: Case = undefined;
    const rel = "src/ç a,[b].ts";
    try case.init(&.{ util_file, ignore_workspace, .{ .rel = rel, .text = util_src } });
    defer case.deinit();
    const before = try case.git(&.{ "rev-parse", "HEAD" });

    const reply = try case.swap(rel, new_body, "fix: swap", committing);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings(before, try case.git(&.{ "rev-parse", "HEAD^" }));
    try testing.expectEqualStrings("", try case.git(&.{ "status", "--porcelain" }));
    try testing.expectEqualStrings("1", try case.git(&.{ "rev-list", "--count", "HEAD^..HEAD" }));
    try testing.expect(contains(try case.headBlob(rel), model_mark));
    try testing.expect(!contains(try case.headBlob("src/util.ts"), model_mark));
}

test "redteam commit: a hand edit to a file a bracket path also matches is not staged by the commit" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.init(&.{ util_file, ignore_workspace, .{ .rel = "src/a.ts", .text = util_src }, .{ .rel = "src/[ab].ts", .text = util_src } });
    defer case.deinit();
    try case.repo.write("src/a.ts", util_hand);

    const reply = try case.swap("src/[ab].ts", new_body, "fix: swap", committing);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!contains(try case.headBlob("src/a.ts"), hand_mark));
    try testing.expectEqualStrings("", try case.git(&.{ "diff", "--cached", "--name-only" }));
    try testing.expect(contains(try case.disk("src/a.ts"), hand_mark));
}

test "redteam commit: a new file on an ignored path is refused and leaves nothing" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.init(&.{ util_file, .{ .rel = ".gitignore", .text = ".emetgate/\nsrc/gen.ts\n" } });
    defer case.deinit();
    const before = try case.git(&.{ "rev-parse", "HEAD" });

    const reply = try case.call("emetgate_try", &.{ .{ "file", "src/gen.ts" }, .{ "symbol", "fresh" }, .{ "hash", "absent" }, .{ "body", "export function fresh(): number {\n  return 1;\n}\n" }, .{ "message", "feat: fresh" } }, committing);
    try testing.expect(reply.is_error);
    try testing.expect(!case.repo.exists("src/gen.ts"));
    try testing.expectEqualStrings(before, try case.git(&.{ "rev-parse", "HEAD" }));
    try testing.expectEqualStrings("", try case.git(&.{ "status", "--porcelain" }));
}

test "redteam commit: a signing setting that arrives through an include is refused" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.initDefault();
    defer case.deinit();
    try case.repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.git/extra.cfg", .data = "[commit]\n\tgpgsign = yes\n" });
    _ = try case.git(&.{ "config", "include.path", "extra.cfg" });
    const before = try case.git(&.{ "rev-parse", "HEAD" });

    const reply = try case.swap("src/util.ts", new_body, "fix: swap", committing);
    try testing.expect(reply.is_error);
    try testing.expect(contains(reply.text, "SigningNotSupported"));
    try testing.expectEqualStrings(before, try case.git(&.{ "rev-parse", "HEAD" }));
    try testing.expectEqualStrings(util_src, try case.disk("src/util.ts"));
}

test "redteam commit: a file staged by hand stays staged and out of the model's commit" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.init(&.{ util_file, ignore_workspace, .{ .rel = "src/b.ts", .text = "export const b = 1;\n" } });
    defer case.deinit();
    try case.repo.write("src/b.ts", "export const b = 2;\n");
    _ = try case.git(&.{ "add", "src/b.ts" });

    const reply = try case.swap("src/util.ts", new_body, "fix: swap", committing);
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings("M\tsrc/util.ts", try case.git(&.{ "diff", "--name-status", "HEAD^", "HEAD" }));
    try testing.expectEqualStrings("M  src/b.ts", try case.git(&.{ "status", "--porcelain" }));
}

test "redteam commit: mutate and the node form of try write nothing while commits are on" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.initDefault();
    defer case.deinit();
    const before = try case.git(&.{ "rev-parse", "HEAD" });

    _ = try case.call("emetgate_mutate", &.{ .{ "file", "src/util.ts" }, .{ "symbol", "add" }, .{ "hash", try case.hashOf("src/util.ts", "add") }, .{ "body", new_body } }, committing);
    try testing.expectError(error.CommitNotSupportedByTool, case.call("emetgate_try", &.{ .{ "file", "src/util.ts" }, .{ "node", "0" }, .{ "hash", "0" }, .{ "text", "x" }, .{ "message", "fix: swap" } }, committing));
    try testing.expectError(error.CommitNotSupportedByTool, case.call("emetgate_rename", &.{}, committing));
    try testing.expectError(error.CommitNotSupportedByTool, case.call("emetgate_move", &.{}, committing));
    try testing.expectError(error.CommitNotSupportedByTool, case.call("emetgate_move_file", &.{}, committing));
    try testing.expectEqualStrings(before, try case.git(&.{ "rev-parse", "HEAD" }));
    try testing.expectEqualStrings("", try case.git(&.{ "status", "--porcelain" }));
    try testing.expectEqualStrings(util_src, try case.disk("src/util.ts"));
}

test "redteam commit: a model field cannot switch commits off or change the test command" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.initDefault();
    defer case.deinit();
    const before = try case.git(&.{ "rev-parse", "HEAD" });
    const hash = try case.hashOf("src/util.ts", "add");

    for ([_][]const u8{ "commit", "no_commit", "test_cmd", "typecheck_cmd", "allow_repo_memory", "shadow_root" }) |field| {
        const reply = try case.call("emetgate_try", &.{ .{ "file", "src/util.ts" }, .{ "symbol", "add" }, .{ "hash", hash }, .{ "body", new_body }, .{ field, "false" } }, .{ .test_command = red, .commit = true });
        try testing.expect(reply.is_error);
        try testing.expectEqualStrings(before, try case.git(&.{ "rev-parse", "HEAD" }));
        try testing.expectEqualStrings(util_src, try case.disk("src/util.ts"));
    }
}

test "redteam commit: a leftover lock in the private index does not poison the next call" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.initDefault();
    defer case.deinit();
    try case.repo.tmp.dir.createDirPath(testing.io, "repo/.emetgate/commit");
    try case.repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.emetgate/commit/index.lock", .data = "" });
    try case.repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.emetgate/commit/index", .data = "garbage" });
    try case.repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.emetgate/commit/message", .data = "poison\n" });
    const before = try case.git(&.{ "rev-parse", "HEAD" });

    const first = try case.swap("src/util.ts", new_body, "fix: swap", committing);
    if (first.is_error) {
        try testing.expectEqualStrings(before, try case.git(&.{ "rev-parse", "HEAD" }));
        try testing.expectEqualStrings(util_src, try case.disk("src/util.ts"));
        try testing.expect(!case.repo.exists(".emetgate/commit"));
    }
    const second = if (first.is_error) try case.swap("src/util.ts", new_body, "fix: swap", committing) else first;
    errdefer std.debug.print("{s}\n", .{second.text});
    try testing.expect(!second.is_error);
    try testing.expectEqualStrings("fix: swap", try case.git(&.{ "log", "-1", "--format=%B" }));
    try testing.expect(!case.repo.exists(".emetgate/commit"));
}

test "redteam commit: a workspace tracked by git keeps the commit to the one target" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.init(&.{ util_file, .{ .rel = ".emetgate/keep.txt", .text = "tracked\n" } });
    defer case.deinit();

    const reply = try case.swap("src/util.ts", new_body, "fix: swap", committing);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings("M\tsrc/util.ts", try case.git(&.{ "diff", "--name-status", "HEAD^", "HEAD" }));
    try testing.expectEqualStrings("", try case.git(&.{ "diff", "--cached", "--name-only" }));
}

test "redteam commit: a detached head, a merge in progress and a branch with no commit are refused end to end with nothing written" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.initDefault();
    defer case.deinit();
    const before = try case.git(&.{ "rev-parse", "HEAD" });

    try case.repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.git/MERGE_HEAD", .data = "0000000000000000000000000000000000000000\n" });
    const merging = try case.swap("src/util.ts", new_body, "fix: swap", committing);
    try testing.expect(contains(merging.text, "OperationInProgress"));
    try case.repo.tmp.dir.deleteFile(testing.io, "repo/.git/MERGE_HEAD");

    _ = try case.git(&.{ "checkout", "-q", "--detach" });
    const detached = try case.swap("src/util.ts", new_body, "fix: swap", committing);
    try testing.expect(contains(detached.text, "DetachedHead"));
    try testing.expectEqualStrings(before, try case.git(&.{ "rev-parse", "HEAD" }));
    try testing.expectEqualStrings(util_src, try case.disk("src/util.ts"));

    _ = try case.git(&.{ "checkout", "-q", "--orphan", "empty" });
    const unborn = try case.swap("src/util.ts", new_body, "fix: swap", committing);
    try testing.expect(unborn.is_error);
    try testing.expectEqualStrings(util_src, try case.disk("src/util.ts"));
}

test "redteam commit: a look-alike letter passes an any-case forbid rule and git does not read it as that trailer" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.initDefault();
    defer case.deinit();
    const id = try memory.remember(testing.allocator, testing.io, case.repo.root_abs, .project, "no co-author", true, "message:forbid_any_case:co-authored-by", null);
    defer testing.allocator.free(id);

    const plain = try case.swap("src/util.ts", new_body, "fix: swap\n\nCO-AUTHORED-BY: M <m@example.com>", committing);
    try testing.expect(plain.is_error);
    const spaced = try case.swap("src/util.ts", new_body, "fix: swap\n\nCo-authored-by : M <m@example.com>", committing);
    try testing.expect(spaced.is_error);

    const disguised = try case.swap("src/util.ts", new_body, "fix: swap\n\nCo-auth\xd0\xbered-by: M <m@example.com>", committing);
    try testing.expect(!disguised.is_error);
    const trailers = try case.git(&.{ "log", "-1", "--format=%(trailers:key=Co-authored-by)" });
    try testing.expectEqualStrings("", trailers);
}

test "redteam commit: design limit: a rule that forbids a trailer with its colon is passed by a space before the colon, and git still reads the trailer" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.initDefault();
    defer case.deinit();
    const id = try memory.remember(testing.allocator, testing.io, case.repo.root_abs, .project, "no co-author", true, "message:forbid_any_case:co-authored-by:", null);
    defer testing.allocator.free(id);

    const reply = try case.swap("src/util.ts", new_body, "fix: swap\n\nCo-authored-by : M <m@example.com>", committing);
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings("M <m@example.com>", try case.git(&.{ "log", "-1", "--format=%(trailers:key=Co-authored-by,valueonly)" }));
}

test "redteam commit: design limit: a lone carriage return is not a line end for a one-line rule, as it is not for git" {
    try skipOffWindows();
    const hits = try text_checks.run(testing.allocator, "max_lines:1", "fix: swap\r\rCo-authored-by: M <m@example.com>");
    defer testing.allocator.free(hits);
    try testing.expectEqual(@as(usize, 0), hits.len);
}

test "redteam commit: the committed tree passes the test command the gate ran" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.initDefault();
    defer case.deinit();
    const needs_staged = "if exist src\\c.ts (exit 0) else (exit 1)";
    try case.repo.write("src/c.ts", "export const c = 1;\n");
    _ = try case.git(&.{ "add", "src/c.ts" });

    const reply = try case.swap("src/util.ts", new_body, "fix: swap", .{ .test_command = needs_staged, .commit = true });
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings("M\tsrc/util.ts", try case.git(&.{ "diff", "--name-status", "HEAD^", "HEAD" }));
    try testing.expectEqual(emetgate.checker.Verdict.verified, try case.verdictWith(needs_staged));
}

test "redteam commit: verify with the gate's own test command accepts a commit made on a clean tree" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.init(&.{ util_file, ignore_workspace, .{ .rel = "src/c.ts", .text = "export const c = 1;\n" } });
    defer case.deinit();
    const needs_file = "if exist src\\c.ts (exit 0) else (exit 1)";

    const reply = try case.swap("src/util.ts", new_body, "fix: swap", .{ .test_command = needs_file, .commit = true });
    try testing.expect(!reply.is_error);
    try testing.expectEqual(emetgate.checker.Verdict.verified, try case.verdictWith(needs_file));
}

fn raceHandEdit(file_abs: []const u8, shadow_abs: []const u8) void {
    const io = testing.io;
    var started_buf: [std.fs.max_path_bytes]u8 = undefined;
    var raced_buf: [std.fs.max_path_bytes]u8 = undefined;
    const started = std.fmt.bufPrint(&started_buf, "{s}\\started", .{shadow_abs}) catch return;
    const raced = std.fmt.bufPrint(&raced_buf, "{s}\\raced", .{shadow_abs}) catch return;
    var attempt: usize = 0;
    while (attempt < 3000) : (attempt += 1) {
        if (std.Io.Dir.cwd().access(io, started, .{})) |_| break else |_| {}
        io.sleep(.fromMilliseconds(10), .awake) catch return;
    } else return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file_abs, .data = util_hand }) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = raced, .data = "" }) catch return;
}

test "redteam commit: a hand edit made to the target while the tests run is kept and never committed" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.initDefault();
    defer case.deinit();
    const location = try shadow_root.locate(testing.allocator, case.repo.root_abs, null);
    defer location.deinit(testing.allocator);
    const before = try case.git(&.{ "rev-parse", "HEAD" });
    const file = try case.repo.abs(case.arena(), "src/util.ts");

    const hash = try case.hashOf("src/util.ts", "add");
    const racer = try std.Thread.spawn(.{}, raceHandEdit, .{ @as([]const u8, file), @as([]const u8, location.shadow) });
    const outcome = case.call("emetgate_try", &.{ .{ "file", "src/util.ts" }, .{ "symbol", "add" }, .{ "hash", hash }, .{ "body", new_body }, .{ "message", "fix: swap" } }, .{ .test_command = racing_cmd, .commit = true });
    racer.join();
    const reply = try outcome;
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try testing.expectEqualStrings(before, try case.git(&.{ "rev-parse", "HEAD" }));
    try testing.expectEqualStrings(util_hand, try case.disk("src/util.ts"));
    try testing.expect(!case.repo.exists(".emetgate/commit"));
}

test "redteam commit: a linked worktree gets the commit on its own branch and the main checkout is untouched" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.initDefault();
    defer case.deinit();
    const main_head = try case.git(&.{ "rev-parse", "HEAD" });
    const linked = try std.fmt.allocPrint(case.arena(), "{s}\\..\\linked", .{case.repo.root_abs});
    _ = try case.git(&.{ "worktree", "add", "-q", "-b", "side", linked });
    const linked_abs = try case.repo.tmp.dir.realPathFileAlloc(testing.io, "linked", case.arena());
    const file = try std.fmt.allocPrint(case.arena(), "{s}\\src\\util.ts", .{linked_abs});
    const hash = try support.hashOfRef(testing.allocator, testing.io, case.runtime, file, "add");

    var map: std.json.ObjectMap = .empty;
    try map.put(case.arena(), "file", .{ .string = file });
    try map.put(case.arena(), "symbol", .{ .string = "add" });
    try map.put(case.arena(), "hash", .{ .string = try case.arena().dupe(u8, &std.fmt.bytesToHex(hash, .lower)) });
    try map.put(case.arena(), "body", .{ .string = new_body });
    try map.put(case.arena(), "message", .{ .string = "fix: swap" });
    var event: telemetry.Event = .{ .tool = "emetgate_try" };
    var policy = committing;
    policy.root = linked_abs;
    const result = try handlers.callTool(testing.allocator, testing.io, case.runtime, "emetgate_try", .{ .object = map }, &event, policy);
    defer testing.allocator.free(result.text);
    errdefer std.debug.print("{s}\n", .{result.text});
    try testing.expect(!result.is_error);

    try testing.expectEqualStrings(main_head, try case.git(&.{ "rev-parse", "HEAD" }));
    try testing.expectEqualStrings("", try case.git(&.{ "status", "--porcelain" }));
    try testing.expectEqualStrings(util_src, try case.disk("src/util.ts"));
    try testing.expectEqualStrings(main_head, try case.git(&.{ "rev-parse", "side^" }));
    try testing.expectEqualStrings("M\tsrc/util.ts", try case.git(&.{ "diff", "--name-status", "side^", "side" }));
    try testing.expectEqualStrings("", try case.git(&.{ "-C", linked_abs, "status", "--porcelain" }));
}

test "redteam commit: a file inside a nested repository is refused and neither repository gets a commit" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.initDefault();
    defer case.deinit();
    const before = try case.git(&.{ "rev-parse", "HEAD" });
    try case.repo.write("vendor/lib/util.ts", util_src);
    const nested = try case.repo.abs(case.arena(), "vendor/lib");
    try git_fixture.initRepo(nested);
    try support.Repo.git(nested, &.{ "add", "." });
    try support.Repo.git(nested, &.{ "commit", "-q", "-m", "nested" });
    const nested_before = try case.git(&.{ "-C", nested, "rev-parse", "HEAD" });

    const outcome = case.swap("vendor/lib/util.ts", new_body, "fix: swap", committing);
    if (outcome) |reply| try testing.expect(reply.is_error) else |_| {}
    try testing.expectEqualStrings(before, try case.git(&.{ "rev-parse", "HEAD" }));
    try testing.expectEqualStrings(nested_before, try case.git(&.{ "-C", nested, "rev-parse", "HEAD" }));
    try testing.expectEqualStrings(util_src, try case.disk("vendor/lib/util.ts"));
}

test "redteam commit: the executable bit of the target survives the commit" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.initDefault();
    defer case.deinit();
    _ = try case.git(&.{ "update-index", "--chmod=+x", "src/util.ts" });
    _ = try case.git(&.{ "commit", "-q", "-m", "chore: mode" });

    const reply = try case.swap("src/util.ts", new_body, "fix: swap", committing);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expect(std.mem.startsWith(u8, try case.git(&.{ "ls-tree", "HEAD", "src/util.ts" }), "100755 "));
    try testing.expectEqualStrings("", try case.git(&.{ "status", "--porcelain" }));
}

test "redteam commit: a HEAD that points at a tag is refused and the tag does not move" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.initDefault();
    defer case.deinit();
    const before = try case.git(&.{ "rev-parse", "HEAD" });
    _ = try case.git(&.{ "tag", "v1" });
    _ = try case.git(&.{ "symbolic-ref", "HEAD", "refs/tags/v1" });

    const reply = try case.swap("src/util.ts", new_body, "fix: swap", committing);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expectEqualStrings(before, try case.git(&.{ "rev-parse", "refs/tags/v1" }));
    try testing.expect(reply.is_error);
    try testing.expectEqualStrings(util_src, try case.disk("src/util.ts"));
}

test "redteam commit: a hook directory and a config file that arrive with the clone do not run" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.init(&.{
        util_file,
        ignore_workspace,
        .{ .rel = ".githooks/reference-transaction", .text = "#!/bin/sh\necho ran > hook-ran.txt\nexit 1\n" },
        .{ .rel = ".gitconfig", .text = "[core]\n\thooksPath = .githooks\n[commit]\n\tgpgsign = true\n" },
    });
    defer case.deinit();

    const reply = try case.swap("src/util.ts", new_body, "fix: swap", committing);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expect(!case.repo.exists("hook-ran.txt"));
    try testing.expectEqualStrings("", try case.git(&.{ "status", "--porcelain" }));
}
