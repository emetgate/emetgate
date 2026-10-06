const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");
const git_fixture = @import("git_fixture.zig");

const git_commit = emetgate.git_commit;
const testing = std.testing;

fn skipOffWindows() !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
}

const Repo = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,

    fn init() !Repo {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo/src");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/a.ts", .data = "export const a = 1;\n" });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/b.ts", .data = "export const b = 1;\n" });
        const root = try tmp.dir.realPathFileAlloc(testing.io, "repo", testing.allocator);
        errdefer testing.allocator.free(root);
        try git_fixture.initRepo(root);
        var repo: Repo = .{ .tmp = tmp, .root = root };
        try repo.git(&.{ "add", "." });
        try repo.git(&.{ "commit", "-q", "-m", "init" });
        return repo;
    }

    fn deinit(self: *Repo) void {
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn out(self: *Repo, argv: []const []const u8) ![]u8 {
        var full: std.ArrayList([]const u8) = .empty;
        defer full.deinit(testing.allocator);
        try full.append(testing.allocator, "git");
        try full.appendSlice(testing.allocator, argv);
        const result = try std.process.run(testing.allocator, testing.io, .{ .argv = full.items, .cwd = .{ .path = self.root } });
        defer testing.allocator.free(result.stderr);
        errdefer testing.allocator.free(result.stdout);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.GitCommandFailed,
            else => return error.GitCommandFailed,
        }
        return result.stdout;
    }

    fn git(self: *Repo, argv: []const []const u8) !void {
        testing.allocator.free(try self.out(argv));
    }

    fn expectOut(self: *Repo, want: []const u8, argv: []const []const u8) !void {
        const got = try self.out(argv);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(want, std.mem.trim(u8, got, " \r\n"));
    }

    fn write(self: *Repo, rel: []const u8, data: []const u8) !void {
        const sub = try std.fmt.allocPrint(testing.allocator, "repo/{s}", .{rel});
        defer testing.allocator.free(sub);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = data });
    }

    fn read(self: *Repo, rel: []const u8) ![]u8 {
        const sub = try std.fmt.allocPrint(testing.allocator, "repo/{s}", .{rel});
        defer testing.allocator.free(sub);
        return self.tmp.dir.readFileAlloc(testing.io, sub, testing.allocator, .limited(64 * 1024));
    }
};

test "git commit: a prepared commit holds the given bytes on top of HEAD and moves nothing until it is published" {
    try skipOffWindows();
    var repo = try Repo.init();
    defer repo.deinit();

    const head = try git_commit.preflight(testing.allocator, testing.io, repo.root, &.{"src\\a.ts"});
    defer head.deinit(testing.allocator);
    const changes = [_]git_commit.Change{.{ .rel = "src\\a.ts", .content = "export const a = 2;\n" }};
    const commit = try git_commit.prepare(testing.allocator, testing.io, repo.root, head, &changes, "fix: two");
    defer testing.allocator.free(commit);

    try repo.expectOut(head.oid, &.{ "rev-parse", "HEAD" });
    try repo.expectOut("", &.{ "status", "--porcelain" });
    const untouched = try repo.read("src/a.ts");
    defer testing.allocator.free(untouched);
    try testing.expectEqualStrings("export const a = 1;\n", untouched);

    const parent = try std.fmt.allocPrint(testing.allocator, "{s}^", .{commit});
    defer testing.allocator.free(parent);
    try repo.expectOut(head.oid, &.{ "rev-parse", parent });
    const blob = try std.fmt.allocPrint(testing.allocator, "{s}:src/a.ts", .{commit});
    defer testing.allocator.free(blob);
    try repo.expectOut("export const a = 2;", &.{ "cat-file", "-p", blob });
    try repo.expectOut("fix: two", &.{ "log", "-1", "--format=%B", commit });
    try repo.expectOut("M\tsrc/a.ts", &.{ "diff", "--name-status", head.oid, commit });

    try repo.write("src/a.ts", "export const a = 2;\n");
    try git_commit.publish(testing.allocator, testing.io, repo.root, head, commit, &changes);
    try repo.expectOut(commit, &.{ "rev-parse", "HEAD" });
    try repo.expectOut("", &.{ "status", "--porcelain" });
    try repo.git(&.{ "symbolic-ref", "-q", "HEAD" });
}

test "git commit: a message with a body and a trailer is stored as given" {
    try skipOffWindows();
    var repo = try Repo.init();
    defer repo.deinit();
    const head = try git_commit.preflight(testing.allocator, testing.io, repo.root, &.{"src\\a.ts"});
    defer head.deinit(testing.allocator);
    const message = "fix: two\n\nWhy it changed.\n\nSigned-off-by: A Developer <a@example.com>";
    const commit = try git_commit.prepare(testing.allocator, testing.io, repo.root, head, &.{.{ .rel = "src\\a.ts", .content = "export const a = 2;\n" }}, message);
    defer testing.allocator.free(commit);
    try repo.expectOut(message, &.{ "log", "-1", "--format=%B", commit });
}

test "git commit: a new file and a deleted file land in one commit" {
    try skipOffWindows();
    var repo = try Repo.init();
    defer repo.deinit();
    const rels = [_][]const u8{ "src\\deep\\new.ts", "src\\b.ts" };
    const head = try git_commit.preflight(testing.allocator, testing.io, repo.root, &rels);
    defer head.deinit(testing.allocator);
    const changes = [_]git_commit.Change{
        .{ .rel = "src\\deep\\new.ts", .content = "export const n = 1;\n" },
        .{ .rel = "src\\b.ts", .content = null },
    };
    const commit = try git_commit.prepare(testing.allocator, testing.io, repo.root, head, &changes, "feat: swap");
    defer testing.allocator.free(commit);
    try repo.expectOut("D\tsrc/b.ts\nA\tsrc/deep/new.ts", &.{ "diff", "--name-status", head.oid, commit });
    const listed = try std.fmt.allocPrint(testing.allocator, "{s}", .{commit});
    defer testing.allocator.free(listed);
    const tree = try repo.out(&.{ "ls-tree", "-r", listed, "--", "src/deep/new.ts" });
    defer testing.allocator.free(tree);
    try testing.expect(std.mem.startsWith(u8, tree, "100644 blob "));

    try repo.tmp.dir.createDirPath(testing.io, "repo/src/deep");
    try repo.write("src/deep/new.ts", "export const n = 1;\n");
    try repo.tmp.dir.deleteFile(testing.io, "repo/src/b.ts");
    try git_commit.publish(testing.allocator, testing.io, repo.root, head, commit, &changes);
    try repo.expectOut(commit, &.{ "rev-parse", "HEAD" });
    try repo.expectOut("", &.{ "status", "--porcelain" });
}

test "git commit: a change that leaves the tree as it is has nothing to commit" {
    try skipOffWindows();
    var repo = try Repo.init();
    defer repo.deinit();
    const head = try git_commit.preflight(testing.allocator, testing.io, repo.root, &.{"src\\a.ts"});
    defer head.deinit(testing.allocator);
    try testing.expectError(error.NothingToCommit, git_commit.prepare(testing.allocator, testing.io, repo.root, head, &.{.{ .rel = "src\\a.ts", .content = "export const a = 1;\n" }}, "fix: same"));
}

test "git commit: a detached HEAD is refused" {
    try skipOffWindows();
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.git(&.{ "checkout", "-q", "--detach" });
    try testing.expectError(error.DetachedHead, git_commit.preflight(testing.allocator, testing.io, repo.root, &.{"src\\a.ts"}));
}

test "git commit: a repository with no commit yet is refused" {
    try skipOffWindows();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "repo");
    const root = try tmp.dir.realPathFileAlloc(testing.io, "repo", testing.allocator);
    defer testing.allocator.free(root);
    try git_fixture.initRepo(root);
    try testing.expectError(error.NoCommitYet, git_commit.preflight(testing.allocator, testing.io, root, &.{"a.ts"}));
}

test "git commit: a merge in progress is refused" {
    try skipOffWindows();
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.write(".git/MERGE_HEAD", "0000000000000000000000000000000000000000\n");
    try testing.expectError(error.OperationInProgress, git_commit.preflight(testing.allocator, testing.io, repo.root, &.{"src\\a.ts"}));
}

test "git commit: a repository that signs its commits is refused" {
    try skipOffWindows();
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.git(&.{ "config", "commit.gpgsign", "true" });
    try testing.expectError(error.SigningNotSupported, git_commit.preflight(testing.allocator, testing.io, repo.root, &.{"src\\a.ts"}));
}

test "git commit: a target edited by hand is refused, and an edit to another file is not in the way" {
    try skipOffWindows();
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.write("src/b.ts", "export const b = 9;\n");
    const head = try git_commit.preflight(testing.allocator, testing.io, repo.root, &.{"src\\a.ts"});
    head.deinit(testing.allocator);
    try testing.expectError(error.TargetHasUncommittedChanges, git_commit.preflight(testing.allocator, testing.io, repo.root, &.{"src\\b.ts"}));
    try repo.write("src/new.ts", "export const n = 1;\n");
    try testing.expectError(error.TargetHasUncommittedChanges, git_commit.preflight(testing.allocator, testing.io, repo.root, &.{"src\\new.ts"}));
}

test "git commit: a hand edit to another file stays out of the commit and stays in the working tree" {
    try skipOffWindows();
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.write("src/b.ts", "export const b = 9;\n");
    const head = try git_commit.preflight(testing.allocator, testing.io, repo.root, &.{"src\\a.ts"});
    defer head.deinit(testing.allocator);
    const changes = [_]git_commit.Change{.{ .rel = "src\\a.ts", .content = "export const a = 2;\n" }};
    const commit = try git_commit.prepare(testing.allocator, testing.io, repo.root, head, &changes, "fix: two");
    defer testing.allocator.free(commit);
    try repo.write("src/a.ts", "export const a = 2;\n");
    try git_commit.publish(testing.allocator, testing.io, repo.root, head, commit, &changes);
    try repo.expectOut("M\tsrc/a.ts", &.{ "diff", "--name-status", head.oid, commit });
    try repo.expectOut("M src/b.ts", &.{ "status", "--porcelain" });
}

test "git commit: when HEAD moved after the commit was prepared, publish refuses and the branch keeps the newer commit" {
    try skipOffWindows();
    var repo = try Repo.init();
    defer repo.deinit();
    const head = try git_commit.preflight(testing.allocator, testing.io, repo.root, &.{"src\\a.ts"});
    defer head.deinit(testing.allocator);
    const changes = [_]git_commit.Change{.{ .rel = "src\\a.ts", .content = "export const a = 2;\n" }};
    const commit = try git_commit.prepare(testing.allocator, testing.io, repo.root, head, &changes, "fix: two");
    defer testing.allocator.free(commit);

    try repo.git(&.{ "commit", "-q", "--allow-empty", "-m", "someone else" });
    const newer = try repo.out(&.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(newer);
    try testing.expectError(error.WrittenButNotCommitted, git_commit.publish(testing.allocator, testing.io, repo.root, head, commit, &changes));
    try repo.expectOut(std.mem.trim(u8, newer, " \r\n"), &.{ "rev-parse", "HEAD" });
}
