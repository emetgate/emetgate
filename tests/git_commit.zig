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
        const repo: Repo = .{ .tmp = tmp, .root = root };
        try git_fixture.commitInit(root, false);
        return repo;
    }

    fn deinit(self: *Repo) void {
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn out(self: *Repo, argv: []const []const u8) ![]u8 {
        var full: std.ArrayList([]const u8) = .empty;
        defer full.deinit(testing.allocator);
        try full.append(testing.allocator, try git_fixture.git());
        try full.appendSlice(testing.allocator, argv);
        const result = try @import("emetgate").bounded_run.run(testing.allocator, testing.io, .{ .argv = full.items, .cwd = .{ .path = self.root } });
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

    fn has(self: *Repo, rel: []const u8) bool {
        const sub = std.fmt.allocPrint(testing.allocator, "repo/{s}", .{rel}) catch return false;
        defer testing.allocator.free(sub);
        self.tmp.dir.access(testing.io, sub, .{}) catch return false;
        return true;
    }

    fn land(self: *Repo, head: git_commit.Head, prepared: git_commit.Prepared) !void {
        const staged_abs = try std.fmt.allocPrint(testing.allocator, "{s}.staged-index", .{self.root});
        defer testing.allocator.free(staged_abs);
        const staged = try git_commit.stageIndex(testing.allocator, testing.io, self.root, prepared.entries, staged_abs);
        try git_commit.acquireIndex(testing.allocator, testing.io, self.root, staged_abs, staged);
        const branch = try git_commit.currentBranch(testing.allocator, testing.io, self.root);
        defer testing.allocator.free(branch);
        git_commit.moveBranch(testing.allocator, testing.io, self.root, branch, prepared.commit, head.oid) catch |err| {
            try git_commit.releaseIndex(testing.allocator, testing.io, self.root, staged.digest);
            return err;
        };
        try testing.expect(try git_commit.publishIndex(testing.allocator, testing.io, self.root, staged.digest));
    }

    fn prepare(self: *Repo, head: git_commit.Head, changes: []const git_commit.Change, message: []const u8) !git_commit.Prepared {
        const gate = try std.fmt.allocPrint(testing.allocator, "{s}.gate", .{self.root});
        defer testing.allocator.free(gate);
        std.Io.Dir.cwd().deleteTree(testing.io, gate) catch {};
        defer std.Io.Dir.cwd().deleteTree(testing.io, gate) catch {};
        _ = try git_commit.checkoutTree(testing.allocator, testing.io, self.root, head.tree, gate);
        var dir = try std.Io.Dir.cwd().openDir(testing.io, gate, .{});
        defer dir.close(testing.io);
        for (changes) |change| {
            const rel = try testing.allocator.dupe(u8, change.rel);
            defer testing.allocator.free(rel);
            std.mem.replaceScalar(u8, rel, '\\', '/');
            const bytes = change.content orelse {
                try dir.deleteFile(testing.io, rel);
                continue;
            };
            if (std.fs.path.dirnamePosix(rel)) |parent| try dir.createDirPath(testing.io, parent);
            try dir.writeFile(testing.io, .{ .sub_path = rel, .data = bytes });
        }
        const derived = switch (try emetgate.commit_derive.derive(testing.allocator, testing.io, self.root, head, gate, changes, null)) {
            .derived => |tree| tree,
            .foreign => |found| {
                found.deinit(testing.allocator);
                return error.GateTreeNotHead;
            },
        };
        defer derived.deinit(testing.allocator);
        return git_commit.prepare(testing.allocator, testing.io, self.root, head, derived.lines, derived.entries, message);
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
    const prepared = try repo.prepare(head, &changes, "fix: two");
    defer prepared.deinit(testing.allocator);
    const commit = prepared.commit;

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
    try repo.land(head, prepared);
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
    const prepared = try repo.prepare(head, &.{.{ .rel = "src\\a.ts", .content = "export const a = 2;\n" }}, message);
    defer prepared.deinit(testing.allocator);
    const commit = prepared.commit;
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
    const prepared = try repo.prepare(head, &changes, "feat: swap");
    defer prepared.deinit(testing.allocator);
    const commit = prepared.commit;
    try repo.expectOut("D\tsrc/b.ts\nA\tsrc/deep/new.ts", &.{ "diff", "--name-status", head.oid, commit });
    const listed = try std.fmt.allocPrint(testing.allocator, "{s}", .{commit});
    defer testing.allocator.free(listed);
    const tree = try repo.out(&.{ "ls-tree", "-r", listed, "--", "src/deep/new.ts" });
    defer testing.allocator.free(tree);
    try testing.expect(std.mem.startsWith(u8, tree, "100644 blob "));

    try repo.tmp.dir.createDirPath(testing.io, "repo/src/deep");
    try repo.write("src/deep/new.ts", "export const n = 1;\n");
    try repo.tmp.dir.deleteFile(testing.io, "repo/src/b.ts");
    try repo.land(head, prepared);
    try repo.expectOut(commit, &.{ "rev-parse", "HEAD" });
    try repo.expectOut("", &.{ "status", "--porcelain" });
}

test "git commit: a change that leaves the tree as it is has nothing to commit" {
    try skipOffWindows();
    var repo = try Repo.init();
    defer repo.deinit();
    const head = try git_commit.preflight(testing.allocator, testing.io, repo.root, &.{"src\\a.ts"});
    defer head.deinit(testing.allocator);
    try testing.expectError(error.NothingToCommit, repo.prepare(head, &.{.{ .rel = "src\\a.ts", .content = "export const a = 1;\n" }}, "fix: same"));
}

test "git commit: a detached HEAD is refused" {
    try skipOffWindows();
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.git(&.{ "checkout", "-q", "--detach" });
    try testing.expectError(error.DetachedHead, git_commit.preflight(testing.allocator, testing.io, repo.root, &.{"src\\a.ts"}));
}

test "git commit: a repository with no commit yet gets a root commit with no parent" {
    try skipOffWindows();
    var tmp = testing.tmpDir(.{ .iterate = true });
    tmp.dir.createDirPath(testing.io, "repo/src") catch |err| {
        tmp.cleanup();
        return err;
    };
    const root = tmp.dir.realPathFileAlloc(testing.io, "repo", testing.allocator) catch |err| {
        tmp.cleanup();
        return err;
    };
    var repo: Repo = .{ .tmp = tmp, .root = root };
    defer repo.deinit();
    try git_fixture.initRepo(repo.root);
    const head = try git_commit.preflight(testing.allocator, testing.io, repo.root, &.{"src\\a.ts"});
    defer head.deinit(testing.allocator);
    try testing.expect(git_commit.isUnborn(head.oid));
    try testing.expectEqualStrings(git_commit.emptyTreeFor("sha1").?, head.tree);
    const prepared = try repo.prepare(head, &.{.{ .rel = "src\\a.ts", .content = "export const a = 1;\n" }}, "feat: first");
    defer prepared.deinit(testing.allocator);
    try repo.land(head, prepared);
    try repo.expectOut("1", &.{ "rev-list", "--count", "HEAD" });
    try repo.expectOut("feat: first", &.{ "log", "-1", "--format=%s" });
    try repo.expectOut("src/a.ts", &.{ "ls-tree", "-r", "--name-only", "HEAD" });
    try repo.expectOut("0", &.{ "rev-list", "--count", "--min-parents=1", "HEAD" });
}

test "git commit: only an all-zero id stands for an unborn branch" {
    try testing.expect(git_commit.isUnborn("0000000000000000000000000000000000000000"));
    try testing.expect(!git_commit.isUnborn(""));
    try testing.expect(!git_commit.isUnborn("4b825dc642cb6eb9a060e54bf8d69288fbee4904"));
    try testing.expect(!git_commit.isUnborn("0000000000000000000000000000000000000001"));
    try testing.expectEqual(@as(usize, 64), git_commit.emptyTreeFor("sha256").?.len);
    try testing.expect(git_commit.emptyTreeFor("md5") == null);
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
    try testing.expectError(error.TargetNotInHead, git_commit.preflight(testing.allocator, testing.io, repo.root, &.{"src\\new.ts"}));
}

test "git commit: a hand edit to another file stays out of the commit and stays in the working tree" {
    try skipOffWindows();
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.write("src/b.ts", "export const b = 9;\n");
    const head = try git_commit.preflight(testing.allocator, testing.io, repo.root, &.{"src\\a.ts"});
    defer head.deinit(testing.allocator);
    const changes = [_]git_commit.Change{.{ .rel = "src\\a.ts", .content = "export const a = 2;\n" }};
    const prepared = try repo.prepare(head, &changes, "fix: two");
    defer prepared.deinit(testing.allocator);
    const commit = prepared.commit;
    try repo.write("src/a.ts", "export const a = 2;\n");
    try repo.land(head, prepared);
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
    const prepared = try repo.prepare(head, &changes, "fix: two");
    defer prepared.deinit(testing.allocator);

    try repo.git(&.{ "commit", "-q", "--allow-empty", "-m", "someone else" });
    const newer = try repo.out(&.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(newer);
    try testing.expectError(error.BranchMoved, repo.land(head, prepared));
    try testing.expect(!repo.has(".git/index.lock"));
    try repo.expectOut(std.mem.trim(u8, newer, " \r\n"), &.{ "rev-parse", "HEAD" });
}

test "git commit: a target the user keeps out of the working tree with skip-worktree is refused by that name, even with the same bytes" {
    try skipOffWindows();
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.git(&.{ "update-index", "--skip-worktree", "src/a.ts" });
    try testing.expectError(error.TargetSkipWorktree, git_commit.preflight(testing.allocator, testing.io, repo.root, &.{"src\\a.ts"}));
}

test "git commit: a target whose staged entry differs from HEAD is refused though the file on disk matches HEAD" {
    try skipOffWindows();
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.write("src/a.ts", "export const a = 5;\n");
    try repo.git(&.{ "add", "src/a.ts" });
    try repo.write("src/a.ts", "export const a = 1;\n");
    try testing.expectError(error.TargetHasUncommittedChanges, git_commit.preflight(testing.allocator, testing.io, repo.root, &.{"src\\a.ts"}));
}

test "git commit: a tracked file deleted by hand is not a free path to create on" {
    try skipOffWindows();
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.tmp.dir.deleteFile(testing.io, "repo/src/a.ts");
    try testing.expectError(error.TargetHasUncommittedChanges, git_commit.preflight(testing.allocator, testing.io, repo.root, &.{"src\\a.ts"}));
}

test "git commit: an index lock held by another process is never taken over, and it stays as it was" {
    try skipOffWindows();
    var repo = try Repo.init();
    defer repo.deinit();
    const head = try git_commit.preflight(testing.allocator, testing.io, repo.root, &.{"src\\a.ts"});
    defer head.deinit(testing.allocator);
    const changes = [_]git_commit.Change{.{ .rel = "src\\a.ts", .content = "export const a = 2;\n" }};
    const prepared = try repo.prepare(head, &changes, "fix: two");
    defer prepared.deinit(testing.allocator);
    const staged_abs = try std.fmt.allocPrint(testing.allocator, "{s}.staged-index", .{repo.root});
    defer testing.allocator.free(staged_abs);
    const staged = try git_commit.stageIndex(testing.allocator, testing.io, repo.root, prepared.entries, staged_abs);
    try repo.write(".git/index.lock", "held by someone else");
    try testing.expectError(error.IndexLocked, git_commit.acquireIndex(testing.allocator, testing.io, repo.root, staged_abs, staged));
    try testing.expectEqual(git_commit.LockState.foreign, try git_commit.lockState(testing.allocator, testing.io, repo.root, staged.digest));
    try git_commit.releaseIndex(testing.allocator, testing.io, repo.root, staged.digest);
    try testing.expect(!try git_commit.publishIndex(testing.allocator, testing.io, repo.root, staged.digest));
    const lock = try repo.read(".git/index.lock");
    defer testing.allocator.free(lock);
    try testing.expectEqualStrings("held by someone else", lock);
    try repo.expectOut(head.oid, &.{ "rev-parse", "HEAD" });
}

test "git commit: an index that changed after it was copied is not replaced, and what the user staged meanwhile stays staged" {
    try skipOffWindows();
    var repo = try Repo.init();
    defer repo.deinit();
    const head = try git_commit.preflight(testing.allocator, testing.io, repo.root, &.{"src\\a.ts"});
    defer head.deinit(testing.allocator);
    const changes = [_]git_commit.Change{.{ .rel = "src\\a.ts", .content = "export const a = 2;\n" }};
    const prepared = try repo.prepare(head, &changes, "fix: two");
    defer prepared.deinit(testing.allocator);
    const staged_abs = try std.fmt.allocPrint(testing.allocator, "{s}.staged-index", .{repo.root});
    defer testing.allocator.free(staged_abs);
    const staged = try git_commit.stageIndex(testing.allocator, testing.io, repo.root, prepared.entries, staged_abs);
    try repo.write("src/b.ts", "export const b = 7;\n");
    try repo.git(&.{ "add", "src/b.ts" });
    try testing.expectError(error.IndexChanged, git_commit.acquireIndex(testing.allocator, testing.io, repo.root, staged_abs, staged));
    try testing.expect(!repo.has(".git/index.lock"));
    try repo.expectOut("M  src/b.ts", &.{ "status", "--porcelain" });
}

test "git commit: a blob id worked out in process is the one git stores, and any path git could convert is left to git" {
    try skipOffWindows();
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.write(".gitattributes", "*.id ident\n*.flt filter=upper\n*.enc working-tree-encoding=UTF-16\n*.txt ident\n");
    try repo.tmp.dir.createDirPath(testing.io, "repo/sub");
    try repo.write("sub/.gitattributes", "*.txt !ident\n");
    try repo.git(&.{ "add", "." });
    try repo.git(&.{ "commit", "-q", "-m", "attributes" });
    try repo.tmp.dir.deleteFile(testing.io, "repo/sub/.gitattributes");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const git = try git_commit.Git.init(arena_state.allocator(), testing.io, repo.root);
    const items = [_]git_commit.Content{
        .{ .path = "src/a.ts", .bytes = "export const a = 2;\n" },
        .{ .path = "src/crlf.ts", .bytes = "export const c = 1;\r\n" },
        .{ .path = "x.id", .bytes = "$Id$\n" },
        .{ .path = "x.flt", .bytes = "plain\n" },
        .{ .path = "x.enc", .bytes = "plain\n" },
        .{ .path = "sub/k.txt", .bytes = "$Id$\n" },
        .{ .path = "src/b.ts", .bytes = "" },
        .{ .path = "new/c.ts", .bytes = "export const c = 3;\n" },
    };
    const plain = try git_commit.plainOids(git, 40, &items);
    const kept = [_]bool{ true, false, false, false, false, false, true, true };
    for (items, plain.oids, kept) |item, oid, want| {
        try testing.expectEqual(want, oid != null);
        const found = oid orelse continue;
        const path_arg = try std.fmt.allocPrint(arena_state.allocator(), "--path={s}", .{item.path});
        try testing.expectEqualStrings(try git.fed(&.{ "hash-object", "--stdin", path_arg }, item.bytes), found);
    }
    try testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", try git_commit.blobOid(arena_state.allocator(), 40, ""));
    try testing.expectEqualStrings("473a0f4c3be8a93681a267e3b1e9a7dcda1185436fe141f7749120a303721813", try git_commit.blobOid(arena_state.allocator(), 64, ""));
    const few = try git_commit.plainOids(git, 40, items[0..1]);
    try testing.expect(few.oids[0] == null);
}

fn expectSameHead(arena: std.mem.Allocator, git: git_commit.Git) !void {
    const git_dir = try git.need(&.{ "rev-parse", "--absolute-git-dir" });
    const mine = (try git_commit.readHead(arena, testing.io, git_dir)) orelse return error.NotRead;
    const theirs = try git.run(&.{ "symbolic-ref", "-q", "HEAD" });
    switch (mine) {
        .branch => |name| try testing.expectEqualStrings(theirs orelse return error.TestUnexpectedResult, name),
        .detached => try testing.expect(theirs == null),
    }
}

test "git commit: HEAD read in process names the branch git symbolic-ref names" {
    try skipOffWindows();
    var repo = try Repo.init();
    defer repo.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const git = try git_commit.Git.init(arena, testing.io, repo.root);
    try expectSameHead(arena, git);
    try repo.git(&.{ "checkout", "-q", "-b", "feature/x" });
    try expectSameHead(arena, git);

    const wt = try std.fmt.allocPrint(arena, "{s}-wt", .{repo.root});
    try repo.git(&.{ "worktree", "add", "-q", "--detach", wt });
    const other = try git_commit.Git.init(arena, testing.io, wt);
    try expectSameHead(arena, other);
    _ = try other.need(&.{ "checkout", "-q", "-b", "side" });
    try expectSameHead(arena, other);
    try expectSameHead(arena, git);

    try repo.git(&.{ "checkout", "-q", "--detach" });
    try expectSameHead(arena, git);
    try repo.git(&.{ "symbolic-ref", "HEAD", "refs/heads/unborn" });
    try expectSameHead(arena, git);

    const head_abs = try std.fmt.allocPrint(arena, "{s}\\.git\\HEAD", .{repo.root});
    const git_dir = try git.need(&.{ "rev-parse", "--absolute-git-dir" });
    for ([_][]const u8{ "ref: refs/heads/main\r\n", "ref: refs/heads/.invalid\n", "ref: refs/heads/a..b\n", "ref: HEAD\n", "ref: refs/heads/main", "0123\n" }) |text| {
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = head_abs, .data = text });
        try testing.expect((try git_commit.readHead(arena, testing.io, git_dir)) == null);
    }
}

fn expectSameListing(arena: std.mem.Allocator, git: git_commit.Git, index_abs: []const u8, specs: []const []const u8, icase: bool) !void {
    const all = (try emetgate.git_index.readEntries(arena, testing.io, index_abs)) orelse return error.NotRead;
    const mine = (try git_commit.matchEntries(arena, all, specs, icase)) orelse return error.NotRead;
    const theirs = try git_commit.indexEntries(git, specs, icase);
    try testing.expectEqual(theirs.len, mine.len);
    for (theirs, mine) |want, got| {
        try testing.expectEqualStrings(want.path, got.path);
        try testing.expectEqual(want.tag, got.tag);
        try testing.expectEqualStrings(want.mode, got.mode);
        try testing.expectEqualStrings(want.oid, got.oid);
        try testing.expectEqual(want.stage, got.stage);
    }
}

test "git commit: the index read in process lists exactly what git ls-files lists" {
    try skipOffWindows();
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.tmp.dir.createDirPath(testing.io, "repo/src/deep");
    try repo.write("src/deep/x.ts", "export const x = 1;\n");
    try repo.write("srcx.ts", "export const s = 1;\n");
    try repo.write("tool.sh", "echo\n");
    try repo.write("src/\xc3\xbcn\xc3\xaf.ts", "export const u = 1;\n");
    try repo.write("new.ts", "export const n = 1;\n");
    try repo.git(&.{ "add", "src", "srcx.ts", "tool.sh" });
    try repo.git(&.{ "update-index", "--chmod=+x", "tool.sh" });
    try repo.git(&.{ "add", "-N", "new.ts" });
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const git = try git_commit.Git.init(arena, testing.io, repo.root);
    const head = try git.need(&.{ "rev-parse", "HEAD" });
    const blob = try git.need(&.{ "rev-parse", "HEAD:src/a.ts" });
    try repo.git(&.{ "update-index", "--add", "--cacheinfo", try std.fmt.allocPrint(arena, "160000,{s},lib", .{head}) });
    try repo.git(&.{ "update-index", "--add", "--cacheinfo", try std.fmt.allocPrint(arena, "120000,{s},link", .{blob}) });
    _ = try git.fed(&.{ "update-index", "--index-info" }, try std.fmt.allocPrint(arena, "100644 {s} 1\tconf.ts\n100644 {s} 2\tconf.ts\n100755 {s} 3\tconf.ts\n", .{ blob, blob, blob }));
    try repo.git(&.{ "update-index", "--skip-worktree", "src/b.ts" });
    try repo.git(&.{ "update-index", "--assume-unchanged", "src/a.ts" });

    const index_abs = try std.fmt.allocPrint(arena, "{s}\\.git\\index", .{repo.root});
    const exact = [_][]const u8{ "src", "src/a.ts", "conf.ts", "lib", "link", "srcx.ts", "sr", "missing", "src/deep", "tool.sh", "new.ts", "src/\xc3\xbcn\xc3\xaf.ts", "SRC/A.TS" };
    const folded = [_][]const u8{ "SRC/A.TS", "Conf.ts", "LIB", "Src/Deep", "src", "SR", "Tool.SH", "NEW.ts" };
    var many: [70][]const u8 = undefined;
    for (&many, 0..) |*slot, i| slot.* = try std.fmt.allocPrint(arena, "f{d}", .{i});
    many[0] = "src";
    many[65] = "src";
    many[66] = "conf.ts";
    for ([_][]const u8{ "3", "4" }) |version| {
        try repo.git(&.{ "update-index", "--index-version", version });
        try expectSameListing(arena, git, index_abs, &exact, false);
        try expectSameListing(arena, git, index_abs, &folded, true);
        try expectSameListing(arena, git, index_abs, &many, false);
        const all = (try emetgate.git_index.readEntries(arena, testing.io, index_abs)) orelse return error.NotRead;
        try testing.expect((try git_commit.matchEntries(arena, all, &.{"src/abNcd.ts"}, true)) == null);
        try testing.expect((try git_commit.matchEntries(arena, all, &.{"./src"}, false)) == null);
        try testing.expect((try git_commit.matchEntries(arena, all, &.{"src/"}, false)) == null);
        try testing.expect((try git_commit.matchEntries(arena, all, &.{"src/\xc3\xbcn\xc3\xaf.ts"}, true)) == null);
        try testing.expect((try git_commit.matchEntries(arena, all, &.{"src/\xc4\xb0.ts"}, true)) == null);
        try testing.expect((try git_commit.matchEntries(arena, all, &.{"/src"}, false)) == null);
        try testing.expect((try git_commit.matchEntries(arena, all, &.{"C:/src"}, false)) == null);
    }
}

const git_objects = emetgate.git_objects;

const ObjectsCase = struct {
    repo: Repo,
    arena_state: std.heap.ArenaAllocator,
    git_dir: []const u8,

    fn init() !ObjectsCase {
        var repo = try Repo.init();
        errdefer repo.deinit();
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer arena_state.deinit();
        const git_dir_out = try repo.out(&.{ "rev-parse", "--absolute-git-dir" });
        defer testing.allocator.free(git_dir_out);
        const git_dir = try arena_state.allocator().dupe(u8, std.mem.trim(u8, git_dir_out, " \r\n"));
        return .{ .repo = repo, .arena_state = arena_state, .git_dir = git_dir };
    }

    fn deinit(self: *ObjectsCase) void {
        self.arena_state.deinit();
        self.repo.deinit();
    }

    fn store(self: *ObjectsCase) !?git_objects.Store {
        return git_objects.Store.open(self.arena_state.allocator(), testing.io, self.git_dir, null);
    }

    fn line(self: *ObjectsCase, argv: []const []const u8) ![]const u8 {
        const out = try self.repo.out(argv);
        defer testing.allocator.free(out);
        return self.arena_state.allocator().dupe(u8, std.mem.trim(u8, out, " \r\n"));
    }

    fn head(self: *ObjectsCase) ![]const u8 {
        return self.line(&.{ "rev-parse", "HEAD" });
    }

    fn write(self: *ObjectsCase, rel: []const u8, text: []const u8) !void {
        const sub = try std.fmt.allocPrint(testing.allocator, "repo/{s}", .{rel});
        defer testing.allocator.free(sub);
        if (std.fs.path.dirname(sub)) |parent| try self.repo.tmp.dir.createDirPath(testing.io, parent);
        try self.repo.tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = text });
    }

    fn commitAll(self: *ObjectsCase, message: []const u8) !void {
        try self.repo.git(&.{ "add", "-A" });
        try self.repo.git(&.{ "commit", "-q", "-m", message });
    }
};

const PathSink = struct {
    arena: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,

    pub fn add(self: *PathSink, path: []const u8, mode: u32, oid: git_objects.Oid) !void {
        try self.out.print(self.arena, "{o:0>6} {s} {s}\t{s}\x00", .{ mode, git_objects.kindOfMode(mode), std.fmt.bytesToHex(oid, .lower), path });
    }
};

fn sortedRecords(arena: std.mem.Allocator, bytes: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var records = std.mem.tokenizeScalar(u8, bytes, 0);
    while (records.next()) |record| try list.append(arena, record);
    std.mem.sort([]const u8, list.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return list.items;
}

fn expectSameObjects(case: *ObjectsCase, commits: []const []const u8, paths: []const []const u8) !void {
    const arena = case.arena_state.allocator();
    var objects = (try case.store()) orelse return error.StoreRefused;
    for (commits) |commit| {
        const theirs = try case.repo.out(&.{ "ls-tree", "-r", "-z", commit });
        defer testing.allocator.free(theirs);
        const mine = (try objects.listing(commit)) orelse return error.NotRead;
        try testing.expectEqualStrings(theirs, mine);

        const listed = try case.line(&.{ "rev-list", "--parents", "-n", "1", commit });
        var ids = std.mem.tokenizeScalar(u8, listed, ' ');
        try testing.expectEqualStrings(commit, ids.next().?);
        const parents = (try objects.parents(commit)) orelse return error.NotRead;
        for (parents) |parent| try testing.expectEqualStrings(ids.next() orelse return error.TestUnexpectedResult, parent);
        try testing.expect(ids.next() == null);

        var sink: PathSink = .{ .arena = arena };
        try testing.expect(try objects.entriesAt(commit, paths, &sink));
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ "ls-tree", "-z", commit, "--" });
        try argv.appendSlice(arena, paths);
        const each = try case.repo.out(argv.items);
        defer testing.allocator.free(each);
        const want = try sortedRecords(arena, each);
        const got = try sortedRecords(arena, sink.out.items);
        try testing.expectEqual(want.len, got.len);
        for (want, got) |a, b| try testing.expectEqualStrings(a, b);
    }
}

test "git objects: trees and parents read in process match git for loose objects, offset deltas and ref deltas" {
    try skipOffWindows();
    var case = try ObjectsCase.init();
    defer case.deinit();
    const arena = case.arena_state.allocator();
    var commits: std.ArrayList([]const u8) = .empty;
    try commits.append(arena, try case.head());
    var big: std.ArrayList(u8) = .empty;
    for (0..4000) |i| try big.print(arena, "export const line{d} = {d};\n", .{ i, i * 7 });
    for (0..4) |round| {
        try big.print(arena, "export const round{d} = {d};\n", .{ round, round });
        try case.write("src/deep/er/big.ts", big.items);
        try case.write(try std.fmt.allocPrint(arena, "docs/n{d}.md", .{round}), "note\n");
        try case.write("z.txt", try std.fmt.allocPrint(arena, "z {d}\n", .{round}));
        try case.commitAll("round");
        try commits.append(arena, try case.head());
    }
    const a_blob = try case.line(&.{ "rev-parse", "HEAD:src/a.ts" });
    const first = commits.items[0];
    try case.repo.git(&.{ "update-index", "--add", "--cacheinfo", try std.fmt.allocPrint(arena, "120000,{s},src/link", .{a_blob}) });
    try case.repo.git(&.{ "update-index", "--add", "--cacheinfo", try std.fmt.allocPrint(arena, "160000,{s},vendor/sub", .{first}) });
    try case.repo.git(&.{ "update-index", "--chmod=+x", "src/b.ts" });
    try case.repo.git(&.{ "commit", "-q", "-m", "modes" });
    try commits.append(arena, try case.head());
    const branch = try case.line(&.{ "symbolic-ref", "--short", "HEAD" });
    try case.repo.git(&.{ "checkout", "-q", "-b", "side", first });
    try case.write("side.txt", "side\n");
    try case.commitAll("side");
    try commits.append(arena, try case.head());
    try case.repo.git(&.{ "checkout", "-q", "-f", branch });
    try case.repo.git(&.{ "merge", "-q", "--no-edit", "--no-ff", "side" });
    try commits.append(arena, try case.head());
    const paths = [_][]const u8{ "src/a.ts", "src/b.ts", "src/link", "vendor/sub", "vendor/subx", "src/deep/er/big.ts", "missing.ts", "src/b.tsx", "src/a.ts", "z.txt", "docs" };
    var objects = (try case.store()) orelse return error.StoreRefused;
    var sink: PathSink = .{ .arena = arena };
    try testing.expect(!try objects.entriesAt(first, &.{ "src", "src/a.ts" }, &sink));
    try testing.expect(!try objects.entriesAt(first, &.{ "vendor/sub/x", "vendor/sub" }, &sink));
    try testing.expect(!try objects.entriesAt(first, &.{"src/"}, &sink));
    try testing.expect(!try objects.entriesAt(first, &.{":(icase)src"}, &sink));

    try expectSameObjects(&case, commits.items, &paths);
    try case.repo.git(&.{ "repack", "-a", "-d", "-f", "-q", "--depth=50", "--window=50" });
    try case.repo.git(&.{"prune-packed"});
    try expectSameObjects(&case, commits.items, &paths);
    try case.repo.git(&.{ "-c", "repack.useDeltaBaseOffset=false", "repack", "-a", "-d", "-f", "-q", "--depth=50", "--window=50" });
    try case.repo.git(&.{"prune-packed"});
    try expectSameObjects(&case, commits.items, &paths);
}

test "git objects: the reader declines repositories whose objects git would find or rewrite another way" {
    try skipOffWindows();
    var case = try ObjectsCase.init();
    defer case.deinit();
    const arena = case.arena_state.allocator();
    var objects = (try case.store()) orelse return error.StoreRefused;
    try testing.expect((try objects.read("0000000000000000000000000000000000000000")) == null);
    try testing.expect((try objects.read("HEAD")) == null);
    try testing.expect((try objects.listing("0000000000000000000000000000000000000000")) == null);

    const first = try case.head();
    try case.write("c.ts", "c\n");
    try case.commitAll("two");
    const second = try case.head();
    try case.repo.git(&.{ "replace", second, first });
    try testing.expect((try case.store()) == null);
    try case.repo.git(&.{ "replace", "-d", second });
    try case.repo.git(&.{ "pack-refs", "--all" });
    try std.Io.Dir.cwd().deleteTree(testing.io, try std.fs.path.join(arena, &.{ case.git_dir, "refs", "replace" }));
    try testing.expect((try case.store()) != null);

    for ([_][]const u8{ "objects/info/alternates", "info/grafts", "shallow" }) |rest| {
        const path = try std.fs.path.join(arena, &.{ case.git_dir, rest });
        if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(testing.io, parent);
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = "x\n" });
        try testing.expect((try case.store()) == null);
        try std.Io.Dir.cwd().deleteFile(testing.io, path);
        try testing.expect((try case.store()) != null);
    }

    try case.repo.git(&.{ "config", "extensions.worktreeConfig", "true" });
    try testing.expect((try case.store()) == null);
    try case.repo.git(&.{ "config", "--unset", "extensions.worktreeConfig" });
    try testing.expect((try case.store()) != null);

    var env = std.process.Environ.Map.init(arena);
    try env.put("GIT_OBJECT_DIRECTORY", "x");
    try testing.expect((try git_objects.Store.open(arena, testing.io, case.git_dir, &env)) == null);
}

test "git objects: a loose object whose bytes do not hash to its name is never returned" {
    try skipOffWindows();
    var case = try ObjectsCase.init();
    defer case.deinit();
    const arena = case.arena_state.allocator();
    const commit = try case.head();
    const tree = try case.line(&.{ "rev-parse", "HEAD^{tree}" });
    const commit_path = try std.fmt.allocPrint(arena, "{s}/objects/{s}/{s}", .{ case.git_dir, commit[0..2], commit[2..] });
    const tree_path = try std.fmt.allocPrint(arena, "{s}/objects/{s}/{s}", .{ case.git_dir, tree[0..2], tree[2..] });
    const tree_bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, tree_path, arena, .unlimited);
    try std.Io.Dir.cwd().deleteFile(testing.io, commit_path);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = commit_path, .data = tree_bytes });
    var objects = (try case.store()) orelse return error.StoreRefused;
    try testing.expect((try objects.read(commit)) == null);
    try testing.expect((try objects.parents(commit)) == null);
    try testing.expect((try objects.listing(commit)) == null);
}

test "git objects: a delta is applied exactly and a malformed one is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = "hello world, hello zig";
    const delta = [_]u8{ base.len, 11, 0x91, 0, 5, 6, ' ', 't', 'h', 'e', 'r', 'e' };
    try testing.expectEqualStrings("hello there", try git_objects.applyDelta(arena, base, &delta));
    try testing.expectError(error.BadDelta, git_objects.applyDelta(arena, "short", &delta));
    try testing.expectError(error.BadDelta, git_objects.applyDelta(arena, base, &[_]u8{ base.len, 5, 0 }));
    try testing.expectError(error.BadDelta, git_objects.applyDelta(arena, base, &[_]u8{ base.len, 4, 0x91, 20, 5 }));
    try testing.expectError(error.BadDelta, git_objects.applyDelta(arena, base, &[_]u8{ base.len, 6, 0x91, 0, 5 }));
}

fn reversedRecords(arena: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var records = std.mem.tokenizeScalar(u8, bytes, 0);
    while (records.next()) |record| try list.append(arena, record);
    std.mem.reverse([]const u8, list.items);
    var out: std.ArrayList(u8) = .empty;
    for (list.items) |record| {
        try out.appendSlice(arena, record);
        try out.append(arena, 0);
    }
    return out.items;
}

fn mtimeOf(path: []const u8) !i96 {
    const seen = try std.Io.Dir.cwd().statFile(testing.io, path, .{});
    return seen.mtime.nanoseconds;
}

fn expectTreesRebuilt(case: *ObjectsCase, commits: []const []const u8) !void {
    const arena = case.arena_state.allocator();
    var objects = (try case.store()) orelse return error.StoreRefused;
    for (commits) |commit| {
        const want = try case.line(&.{ "rev-parse", try std.fmt.allocPrint(arena, "{s}^{{tree}}", .{commit}) });
        const listed = try case.repo.out(&.{ "ls-tree", "-r", "-z", commit });
        defer testing.allocator.free(listed);
        try testing.expectEqualStrings(want, (try objects.writeTree(listed)) orelse return error.NotWritten);
        try testing.expectEqualStrings(want, (try objects.writeTree(try reversedRecords(arena, listed))) orelse return error.NotWritten);
    }
}

test "git objects: a tree written in process from a full listing is the tree git wrote, loose or packed" {
    try skipOffWindows();
    var case = try ObjectsCase.init();
    defer case.deinit();
    const arena = case.arena_state.allocator();
    var commits: std.ArrayList([]const u8) = .empty;
    try commits.append(arena, try case.head());
    for ([_][]const u8{ "a-b", "a.b", "a0", "a/b-c/d", "a/b.c", "a/b/c", "A1", "z z/q", "deep/er/est/x.ts" }) |rel| try case.write(rel, rel);
    try case.commitAll("names");
    try commits.append(arena, try case.head());
    const first = commits.items[0];
    const a_blob = try case.line(&.{ "rev-parse", "HEAD:src/a.ts" });
    try case.repo.git(&.{ "update-index", "--add", "--cacheinfo", try std.fmt.allocPrint(arena, "120000,{s},src/link", .{a_blob}) });
    try case.repo.git(&.{ "update-index", "--add", "--cacheinfo", try std.fmt.allocPrint(arena, "160000,{s},vendor/sub", .{first}) });
    try case.repo.git(&.{ "update-index", "--chmod=+x", "src/b.ts" });
    try case.repo.git(&.{ "commit", "-q", "-m", "modes" });
    try commits.append(arena, try case.head());
    try case.repo.git(&.{ "rm", "-q", "-r", "deep", "a" });
    try case.commitAll("fewer");
    try commits.append(arena, try case.head());

    try expectTreesRebuilt(&case, commits.items);
    const before = std.Io.Timestamp.now(testing.io, .real).nanoseconds;
    var objects = (try case.store()) orelse return error.StoreRefused;
    const listed = try case.repo.out(&.{ "ls-tree", "-r", "-z", "HEAD" });
    defer testing.allocator.free(listed);
    const root = (try objects.writeTree(listed)) orelse return error.NotWritten;
    try testing.expect(try mtimeOf(try std.fmt.allocPrint(arena, "{s}/objects/{s}/{s}", .{ case.git_dir, root[0..2], root[2..] })) >= before);

    var moved: std.ArrayList(u8) = .empty;
    try moved.appendSlice(arena, listed);
    try moved.print(arena, "100644 blob {s}\tfresh/dir/moved.ts\x00", .{a_blob});
    const fresh = (try objects.writeTree(moved.items)) orelse return error.NotWritten;
    try testing.expect(!std.mem.eql(u8, fresh, root));
    const back = try case.repo.out(&.{ "ls-tree", "-r", "-z", fresh });
    defer testing.allocator.free(back);
    const want = try sortedRecords(arena, moved.items);
    const got = try sortedRecords(arena, back);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |a, b| try testing.expectEqualStrings(a, b);
    try case.repo.git(&.{ "fsck", "--strict", "--no-dangling", "--no-progress" });

    try case.repo.git(&.{ "repack", "-a", "-d", "-q" });
    try case.repo.git(&.{"prune-packed"});
    try expectTreesRebuilt(&case, commits.items);
    const packed_at = std.Io.Timestamp.now(testing.io, .real).nanoseconds;
    var repacked = (try case.store()) orelse return error.StoreRefused;
    try testing.expectEqualStrings(root, (try repacked.writeTree(listed)) orelse return error.NotWritten);
    var pack_dir = try std.Io.Dir.openDirAbsolute(testing.io, try std.fs.path.join(arena, &.{ case.git_dir, "objects", "pack" }), .{ .iterate = true });
    defer pack_dir.close(testing.io);
    var entries = pack_dir.iterate();
    var freshened = false;
    while (try entries.next(testing.io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".pack")) continue;
        if (try mtimeOf(try std.fs.path.join(arena, &.{ case.git_dir, "objects", "pack", entry.name })) >= packed_at) freshened = true;
    }
    try testing.expect(freshened);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(testing.io, try std.fmt.allocPrint(arena, "{s}/objects/{s}/{s}", .{ case.git_dir, root[0..2], root[2..] }), .{}));
    try case.repo.git(&.{ "fsck", "--strict", "--no-dangling", "--no-progress" });
}

test "git objects: a listing git would reject, reshape or resolve by order is left to git" {
    try skipOffWindows();
    var case = try ObjectsCase.init();
    defer case.deinit();
    const arena = case.arena_state.allocator();
    var objects = (try case.store()) orelse return error.StoreRefused;
    const blob = try case.line(&.{ "rev-parse", "HEAD:src/a.ts" });
    const ok = try std.fmt.allocPrint(arena, "100644 blob {s}\tsrc/a.ts\x00100644 blob {s}\t.gitignore\x00100644 blob {s}\tsub/.gitattributes\x00120000 blob {s}\tsub/link\x00", .{ blob, blob, blob, blob });
    const written = (try objects.writeTree(ok)) orelse return error.NotWritten;
    const back = try case.repo.out(&.{ "ls-tree", "-r", "-z", written });
    defer testing.allocator.free(back);
    try testing.expectEqual(@as(usize, 4), (try sortedRecords(arena, back)).len);
    const refused = [_][]const u8{
        "100644 blob {s}\tx\x00100644 blob {s}\tx/y\x00",
        "100644 blob {s}\tx/y\x00100644 blob {s}\tx\x00",
        "100644 blob {s}\tSrc/x\x00100644 blob {s}\tsrc/y\x00",
        "100644 blob {s}\tx\x00100644 blob {s}\tx\x00",
        "100644 blob {s}\tReadme\x00100644 blob {s}\treadme\x00",
        "100644 blob {s}\t.git/x\x00",
        "100644 blob {s}\tsub/.GIT\x00",
        "120000 blob {s}\t.gitmodules\x00",
        "120000 blob {s}\tsub/.gitignore\x00",
        "100644 blob {s}\t.git. \x00",
        "100644 blob {s}\ta/CON\x00",
        "100644 blob {s}\tcon.txt\x00",
        "100644 blob {s}\tx.\x00",
        "100644 blob {s}\tx \x00",
        "100644 blob {s}\tgit~1/x\x00",
        "100644 blob {s}\ta\\b\x00",
        "100644 blob {s}\ta:b\x00",
        "100644 blob {s}\t\xc3\xbc.ts\x00",
        "100644 blob {s}\ta//b\x00",
        "100644 blob {s}\t./a\x00",
        "100644 blob {s}\ta/..\x00",
        "100644 blob {s}\t/a\x00",
        "100644 blob {s}\ta/\x00",
        "100664 blob {s}\ta\x00",
        "040000 tree {s}\ta\x00",
        "100644 commit {s}\ta\x00",
        "160000 blob {s}\ta\x00",
        "100644 blob {s}\ta\x00\x00",
        "100644  blob {s}\ta\x00",
    };
    for (refused) |shape| {
        errdefer std.debug.print("accepted: {s}\n", .{shape});
        var text: std.ArrayList(u8) = .empty;
        var parts = std.mem.splitSequence(u8, shape, "{s}");
        try text.appendSlice(arena, parts.next().?);
        while (parts.next()) |part| {
            try text.appendSlice(arena, blob);
            try text.appendSlice(arena, part);
        }
        try testing.expect((try objects.writeTree(text.items)) == null);
    }
    try testing.expect((try objects.writeTree("100644 blob 0123456789abcdef0123456789abcdef01234567\ta\x00")) == null);
    try testing.expect((try objects.writeTree(try std.fmt.allocPrint(arena, "100644 blob {s}\ta\x00", .{try std.ascii.allocUpperString(arena, blob)}))) == null);
}
