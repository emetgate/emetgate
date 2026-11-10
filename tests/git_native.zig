const std = @import("std");
const builtin = @import("builtin");
const git_fixture = @import("git_fixture.zig");
const emetgate = @import("emetgate");
const git_native = emetgate.git_native;

const testing = std.testing;
const gpa = testing.allocator;

const Case = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    arena_state: std.heap.ArenaAllocator,

    fn init(self: *Case) !void {
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        try self.tmp.dir.createDirPath(testing.io, "repo/src/deep");
        try self.write("a.ts", "export const a = 1;\n");
        try self.write("src/b.ts", "export const b = 1;\n");
        try self.write("src/deep/c.ts", "export const c = 1;\n");
        try self.write("src/Main.cs", "class Main {}\n");
        self.root = try self.tmp.dir.realPathFileAlloc(testing.io, "repo", gpa);
        errdefer gpa.free(self.root);
        self.arena_state = std.heap.ArenaAllocator.init(gpa);
        try git_fixture.initRepo(self.root);
        try git_fixture.commitInit(self.root, false);
    }

    fn deinit(self: *Case) void {
        self.arena_state.deinit();
        gpa.free(self.root);
        self.tmp.cleanup();
    }

    fn arena(self: *Case) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    fn write(self: *Case, rel: []const u8, text: []const u8) !void {
        const sub = try std.fmt.allocPrint(gpa, "repo/{s}", .{rel});
        defer gpa.free(sub);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = text });
    }

    fn gitMaybe(self: *Case, args: []const []const u8) !?[]const u8 {
        var argv: [12][]const u8 = undefined;
        argv[0] = try git_fixture.git();
        @memcpy(argv[1..][0..args.len], args);
        const result = try emetgate.bounded_run.run(self.arena(), testing.io, .{ .argv = argv[0 .. args.len + 1], .cwd = .{ .path = self.root } });
        return switch (result.term) {
            .exited => |code| if (code == 0) result.stdout else null,
            else => error.GitFailed,
        };
    }

    fn git(self: *Case, args: []const []const u8) ![]const u8 {
        return (try self.gitMaybe(args)) orelse error.GitFailed;
    }

    fn head(self: *Case) ![]const u8 {
        return std.mem.trim(u8, try self.git(&.{ "rev-parse", "HEAD" }), "\r\n");
    }

    fn expectSameAsGit(self: *Case, rev: []const u8) !void {
        const a = self.arena();
        const listed = try self.git(&.{ "rev-list", "--parents", "-n", "1", rev });
        var ids = std.mem.tokenizeAny(u8, listed, " \r\n");
        _ = ids.next();
        const found = (try git_native.parents(a, testing.io, self.root, rev)) orelse return error.NotAnswered;
        for (found) |parent| try testing.expectEqualStrings(ids.next() orelse return error.TooManyParents, parent);
        try testing.expect(ids.next() == null);

        const changed = try self.git(&.{ "diff-tree", "--no-commit-id", "--root", "-r", "--name-only", "-z", rev });
        var names = std.mem.tokenizeScalar(u8, changed, 0);
        const paths = (try git_native.changedPaths(a, testing.io, self.root, rev)) orelse return error.NotAnswered;
        for (paths) |path| try testing.expectEqualStrings(names.next() orelse return error.TooManyPaths, path);
        try testing.expect(names.next() == null);

        const files = try self.git(&.{ "ls-tree", "-r", "-z", "--name-only", rev });
        var each = std.mem.tokenizeScalar(u8, files, 0);
        while (each.next()) |path| {
            const spec = try std.fmt.allocPrint(a, "{s}:{s}", .{ rev, path });
            const want = try self.git(&.{ "cat-file", "blob", spec });
            const got = (try git_native.blobAt(a, testing.io, self.root, spec)) orelse return error.NotAnswered;
            try testing.expectEqualStrings(want, got.found);
        }
        const missing = try std.fmt.allocPrint(a, "{s}:src/not-there.ts", .{rev});
        try testing.expect((try self.gitMaybe(&.{ "cat-file", "blob", missing })) == null);
        try testing.expect(((try git_native.blobAt(a, testing.io, self.root, missing)) orelse return error.NotAnswered) == .absent);
        const folder = try std.fmt.allocPrint(a, "{s}:src", .{rev});
        try testing.expect((try self.gitMaybe(&.{ "cat-file", "blob", folder })) == null);
        try testing.expect(((try git_native.blobAt(a, testing.io, self.root, folder)) orelse return error.NotAnswered) == .absent);
    }

    fn expectFactsSameAsGit(self: *Case) !void {
        const a = self.arena();
        const out = try self.git(&.{ "rev-parse", "--absolute-git-dir", "--git-path", "index", "--git-path", "info/attributes", "HEAD^{commit}", "HEAD^{tree}", "--symbolic-full-name", "HEAD" });
        var lines = std.mem.tokenizeAny(u8, out, "\r\n");
        const known = (try git_native.facts(a, testing.io, self.root)) orelse return error.NotAnswered;
        try testing.expectEqualStrings(lines.next().?, known.git_dir);
        try testing.expectEqualStrings(lines.next().?, known.index);
        try testing.expectEqualStrings(lines.next().?, known.attributes);
        try testing.expectEqualStrings(lines.next().?, known.commit);
        try testing.expectEqualStrings(lines.next().?, known.tree);
        try testing.expectEqualStrings(lines.next().?, known.branch);
    }

    fn expectListingSameAsGit(self: *Case, pathspec: []const u8) !void {
        const want = try self.git(&.{ "ls-files", "-z", "--", pathspec });
        const got = (try git_native.trackedUnder(gpa, testing.io, self.root, pathspec)) orelse return error.NotAnswered;
        defer gpa.free(got);
        try testing.expectEqualStrings(want, got);
    }
};

fn skipOffWindows() !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
}

test "git native: parents, changed paths, blobs and facts of a root commit, an edit and a merge are what git says, loose and packed" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const first = try case.head();
    try case.expectSameAsGit(first);
    try case.expectFactsSameAsGit();

    try case.write("a.ts", "export const a = 2;\n");
    try case.write("src/new.ts", "export const n = 1;\n");
    try case.tmp.dir.deleteFile(testing.io, "repo/src/deep/c.ts");
    _ = try case.git(&.{ "add", "-A" });
    _ = try case.git(&.{ "commit", "-q", "-m", "edit" });
    const second = try case.head();
    try case.expectSameAsGit(second);
    try case.expectSameAsGit("HEAD");

    _ = try case.git(&.{ "checkout", "-q", "-b", "side", first });
    try case.write("side.ts", "export const s = 1;\n");
    _ = try case.git(&.{ "add", "-A" });
    _ = try case.git(&.{ "commit", "-q", "-m", "side" });
    _ = try case.git(&.{ "merge", "-q", "--no-ff", "-m", "merge", second });
    const merged = try case.head();
    try case.expectSameAsGit(merged);
    try case.expectFactsSameAsGit();

    _ = try case.git(&.{ "gc", "-q" });
    try case.expectSameAsGit(first);
    try case.expectSameAsGit(second);
    try case.expectSameAsGit(merged);
    try case.expectFactsSameAsGit();
}

test "git native: a path that turns from a file into a folder, a moved tree and an unknown revision are left to git" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena();
    try case.tmp.dir.deleteFile(testing.io, "repo/a.ts");
    try case.tmp.dir.createDirPath(testing.io, "repo/a.ts");
    try case.write("a.ts/inner.ts", "export const i = 1;\n");
    _ = try case.git(&.{ "add", "-A" });
    _ = try case.git(&.{ "commit", "-q", "-m", "file to folder" });
    try testing.expect((try git_native.changedPaths(a, testing.io, case.root, try case.head())) == null);

    try testing.expect((try git_native.parents(a, testing.io, case.root, "HEAD~1")) == null);
    try testing.expect((try git_native.blobAt(a, testing.io, case.root, "HEAD~1:src/b.ts")) == null);
    try testing.expect((try git_native.parents(a, testing.io, case.root, "0000000000000000000000000000000000000000")) == null);

    _ = try case.git(&.{ "checkout", "-q", "--detach" });
    try testing.expect((try git_native.facts(a, testing.io, case.root)) == null);
}

test "git native: a note is read as git notes show prints it, a missing note and a missing notes ref are told apart from not knowing" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena();
    const commit = try case.head();
    try testing.expect(((try git_native.note(a, testing.io, case.root, "emetgate", commit)) orelse return error.NotAnswered) == .absent);
    try testing.expect((try case.gitMaybe(&.{ "notes", "--ref=emetgate", "show", commit })) == null);

    try case.write("note.txt", "{\"receipt\":1}\n");
    _ = try case.git(&.{ "notes", "--ref=emetgate", "add", "-f", "-F", "note.txt", commit });
    const want = try case.git(&.{ "notes", "--ref=emetgate", "show", commit });
    const got = (try git_native.note(a, testing.io, case.root, "emetgate", commit)) orelse return error.NotAnswered;
    try testing.expectEqualStrings(want, got.found);
    const by_head = (try git_native.note(a, testing.io, case.root, "emetgate", "HEAD")) orelse return error.NotAnswered;
    try testing.expectEqualStrings(want, by_head.found);

    try case.write("more.ts", "export const m = 1;\n");
    _ = try case.git(&.{ "add", "-A" });
    _ = try case.git(&.{ "commit", "-q", "-m", "more" });
    try testing.expect((try git_native.note(a, testing.io, case.root, "emetgate", try case.head())) == null);
    _ = try case.git(&.{ "gc", "-q" });
    const packed_note = (try git_native.note(a, testing.io, case.root, "emetgate", commit)) orelse return error.NotAnswered;
    try testing.expectEqualStrings(want, packed_note.found);
}

test "git native: the tracked listing under a pathspec is git ls-files byte for byte, and what it cannot read exactly goes to git" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    for ([_][]const u8{ ".", "src", "src/", "src/deep", "src/b.ts", "*.ts", "*.cs", "src/*.ts", "nothing-here", ":(icase,literal)SRC", ":(icase,literal).emetgate" }) |pathspec| {
        errdefer std.debug.print("pathspec: {s}\n", .{pathspec});
        try case.expectListingSameAsGit(pathspec);
    }
    for ([_][]const u8{ "SRC/b.ts", ":(glob)**/b.ts", ":!src", "src/[ab].ts", "../repo" }) |pathspec| {
        errdefer std.debug.print("pathspec: {s}\n", .{pathspec});
        try testing.expect((try git_native.trackedUnder(gpa, testing.io, case.root, pathspec)) == null);
    }
    _ = try case.git(&.{ "update-index", "--split-index" });
    try testing.expect((try git_native.trackedUnder(gpa, testing.io, case.root, "src")) == null);
}

test "git native: the root of a directory is found on disk and is what git says, and a nested repository or a redirected one is left to git" {
    try skipOffWindows();
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const repo = emetgate.repo;
    const deep = try std.fmt.allocPrint(case.arena(), "{s}\\src\\deep", .{case.root});

    const before = repo.toplevels_discovered.load(.monotonic);
    for ([_][]const u8{ case.root, deep }) |dir| {
        const top = try repo.gitToplevel(gpa, testing.io, dir);
        defer gpa.free(top);
        var argv = [_][]const u8{ try git_fixture.git(), "rev-parse", "--show-toplevel" };
        const result = try emetgate.bounded_run.run(case.arena(), testing.io, .{ .argv = &argv, .cwd = .{ .path = dir } });
        const want = try case.arena().dupe(u8, std.mem.trim(u8, result.stdout, "\r\n"));
        std.mem.replaceScalar(u8, want, '/', '\\');
        try testing.expectEqualStrings(want, top);
    }
    try testing.expect(repo.toplevels_discovered.load(.monotonic) > before);

    const inner = try std.fmt.allocPrint(case.arena(), "{s}\\src", .{case.root});
    try git_fixture.initRepo(inner);
    const nested = try repo.gitToplevel(gpa, testing.io, deep);
    defer gpa.free(nested);
    try testing.expectEqualStrings(inner, nested);

    const elsewhere = try std.fmt.allocPrint(case.arena(), "{s}\\..\\elsewhere", .{case.root});
    _ = try case.git(&.{ "worktree", "add", "-q", "--detach", elsewhere });
    const linked = try std.fs.path.resolve(case.arena(), &.{elsewhere});
    const counted = repo.toplevels_discovered.load(.monotonic);
    const top = try repo.gitToplevel(gpa, testing.io, linked);
    defer gpa.free(top);
    try testing.expectEqualStrings(linked, top);
    try testing.expectEqual(counted, repo.toplevels_discovered.load(.monotonic));
}

