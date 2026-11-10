const std = @import("std");
const git_fixture = @import("git_fixture.zig");

const testing = std.testing;

fn gitOut(cwd: []const u8, args: []const []const u8) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(testing.allocator);
    try argv.append(testing.allocator, try git_fixture.git());
    try argv.appendSlice(testing.allocator, args);
    const result = try @import("emetgate").bounded_run.run(testing.allocator, testing.io, .{ .argv = argv.items, .cwd = .{ .path = cwd } });
    defer testing.allocator.free(result.stderr);
    errdefer testing.allocator.free(result.stdout);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("git {s} failed: {s}\n", .{ args[0], result.stderr });
            return error.GitFailed;
        },
        else => return error.GitFailed,
    }
    return result.stdout;
}

fn expectGit(cwd: []const u8, args: []const []const u8, want: []const u8) !void {
    const out = try gitOut(cwd, args);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(want, std.mem.trimEnd(u8, out, "\r\n"));
}

test "git fixture: a repo written from the template is one git reads as clean, with the test settings" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "repo/src");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/a.ts", .data = "export const a = 1;\n" });
    const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", testing.allocator);
    defer testing.allocator.free(root_abs);

    try git_fixture.initRepo(root_abs);
    try expectGit(root_abs, &.{ "rev-parse", "--is-inside-work-tree" }, "true");
    const top = try std.mem.replaceOwned(u8, testing.allocator, root_abs, "\\", "/");
    defer testing.allocator.free(top);
    try expectGit(root_abs, &.{ "rev-parse", "--show-toplevel" }, top);
    try expectGit(root_abs, &.{ "config", "--get", "maintenance.auto" }, "false");
    try expectGit(root_abs, &.{ "config", "--get", "gc.auto" }, "0");
    try expectGit(root_abs, &.{ "config", "--get", "user.email" }, "t@t");
    try expectGit(root_abs, &.{ "status", "--porcelain", "--untracked-files=all" }, "?? src/a.ts");

    const add = try gitOut(root_abs, &.{ "add", "." });
    testing.allocator.free(add);
    const commit = try gitOut(root_abs, &.{ "commit", "-q", "-m", "init" });
    testing.allocator.free(commit);
    try expectGit(root_abs, &.{ "status", "--porcelain", "--untracked-files=all" }, "");
    try expectGit(root_abs, &.{ "ls-files" }, "src/a.ts");
    const fsck = try gitOut(root_abs, &.{ "fsck", "--strict" });
    testing.allocator.free(fsck);
}

test "git fixture: a first commit written without git is one git finds clean, whole and stat for stat its own" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "repo/src/deep");
    try tmp.dir.createDirPath(testing.io, "repo/out");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/a.ts", .data = "export const a = 1;\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/deep/b c.ts", .data = "export const b = 2;\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/README.md", .data = "# readme\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/empty.txt", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.gitignore", .data = "out/\n.emetgate/\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/out/built.js", .data = "ignored\n" });
    const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", testing.allocator);
    defer testing.allocator.free(root_abs);

    try git_fixture.initRepo(root_abs);
    const before = git_fixture.native_commits;
    try git_fixture.commitInit(root_abs, false);
    try testing.expectEqual(before + 1, git_fixture.native_commits);

    try expectGit(root_abs, &.{ "status", "--porcelain" }, "");
    try expectGit(root_abs, &.{ "ls-files" }, ".gitignore\nREADME.md\nempty.txt\nsrc/a.ts\nsrc/deep/b c.ts");
    try expectGit(root_abs, &.{ "log", "-1", "--format=%an <%ae>|%s" }, "t <t@t>|init");
    const fsck = try gitOut(root_abs, &.{ "fsck", "--strict", "--no-dangling" });
    testing.allocator.free(fsck);
    const head_tree = try gitOut(root_abs, &.{ "rev-parse", "HEAD^{tree}" });
    defer testing.allocator.free(head_tree);
    const index_tree = try gitOut(root_abs, &.{ "write-tree" });
    defer testing.allocator.free(index_tree);
    try testing.expectEqualStrings(head_tree, index_tree);

    const ours = try gitOut(root_abs, &.{ "ls-files", "--debug" });
    defer testing.allocator.free(ours);
    const refreshed = try gitOut(root_abs, &.{ "update-index", "--really-refresh" });
    testing.allocator.free(refreshed);
    const theirs = try gitOut(root_abs, &.{ "ls-files", "--debug" });
    defer testing.allocator.free(theirs);
    try testing.expectEqualStrings(theirs, ours);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/a.ts", .data = "export const a = 3;\n" });
    try expectGit(root_abs, &.{ "status", "--porcelain" }, " M src/a.ts");
    const added = try gitOut(root_abs, &.{ "add", "." });
    testing.allocator.free(added);
    const committed = try gitOut(root_abs, &.{ "commit", "-q", "-m", "second" });
    testing.allocator.free(committed);
    try expectGit(root_abs, &.{ "rev-list", "--count", "HEAD" }, "2");
}

test "git fixture: a file with a carriage return, an attributes file or a pattern it does not read sends the first commit to git" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const cases = [_]struct { rel: []const u8, text: []const u8 }{
        .{ .rel = "repo/crlf.txt", .text = "one\r\ntwo\r\n" },
        .{ .rel = "repo/.gitattributes", .text = "*.ts text\n" },
        .{ .rel = "repo/.gitignore", .text = "*.log\n" },
    };
    for (cases) |case| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/a.ts", .data = "export const a = 1;\n" });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = case.rel, .data = case.text });
        const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", testing.allocator);
        defer testing.allocator.free(root_abs);
        try git_fixture.initRepo(root_abs);
        const before = git_fixture.native_commits;
        try git_fixture.commitInit(root_abs, false);
        try testing.expectEqual(before, git_fixture.native_commits);
        try expectGit(root_abs, &.{ "status", "--porcelain" }, "");
        try expectGit(root_abs, &.{ "rev-list", "--count", "HEAD" }, "1");
    }
}

