const std = @import("std");
const builtin = @import("builtin");
const git_fixture = @import("git_fixture.zig");
const git_index = @import("emetgate").git_index;

const testing = std.testing;
const gpa = testing.allocator;

fn git(root: []const u8, args: []const []const u8) ![]u8 {
    var argv: [10][]const u8 = undefined;
    argv[0] = try git_fixture.git();
    @memcpy(argv[1..][0..args.len], args);
    const result = try @import("emetgate").bounded_run.run(gpa, testing.io, .{ .argv = argv[0 .. args.len + 1], .cwd = .{ .path = root } });
    gpa.free(result.stderr);
    return result.stdout;
}

fn gitOk(root: []const u8, args: []const []const u8) !void {
    gpa.free(try git(root, args));
}

fn expectMatchesLsFiles(root: []const u8) !void {
    const index_path = try std.fmt.allocPrint(gpa, "{s}\\.git\\index", .{root});
    defer gpa.free(index_path);
    const names = (try git_index.readTracked(gpa, testing.io, index_path)) orelse return error.NotRead;
    defer git_index.freeList(gpa, names);
    const listed = try git(root, &.{ "ls-files", "-z", "--deduplicate" });
    defer gpa.free(listed);
    const staged = try git(root, &.{ "ls-files", "-z", "-s" });
    defer gpa.free(staged);
    var submodules: std.StringHashMapUnmanaged(void) = .empty;
    defer submodules.deinit(gpa);
    var entries = std.mem.tokenizeScalar(u8, staged, 0);
    while (entries.next()) |entry| {
        const tab = std.mem.indexOfScalar(u8, entry, '\t') orelse continue;
        if (std.mem.startsWith(u8, entry, "160000 ")) try submodules.put(gpa, entry[tab + 1 ..], {});
    }
    var expected = std.mem.tokenizeScalar(u8, listed, 0);
    var n: usize = 0;
    while (expected.next()) |name| {
        if (submodules.contains(name)) continue;
        if (n >= names.len) return error.TooFewNames;
        try testing.expectEqualStrings(name, names[n]);
        n += 1;
    }
    try testing.expectEqual(n, names.len);
}

const Fixture = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,

    fn init() !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo/src/deep/er");
        const files = [_][]const u8{ "repo/a.ts", "repo/src/b.ts", "repo/src/deep/c.ts", "repo/src/deep/er/d e.ts", "repo/src/deep/er/f.json", "repo/Z.md" };
        for (files) |f| try tmp.dir.writeFile(testing.io, .{ .sub_path = f, .data = "export const v = 1;\n" });
        const root = try tmp.dir.realPathFileAlloc(testing.io, "repo", gpa);
        errdefer gpa.free(root);
        try git_fixture.initRepo(root);
        try git_fixture.commitInit(root, false);
        return .{ .tmp = tmp, .root = root };
    }

    fn deinit(self: *Fixture) void {
        gpa.free(self.root);
        self.tmp.cleanup();
    }
};

test "git index reader: a plain index lists the same paths as git ls-files" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init();
    defer fx.deinit();
    try expectMatchesLsFiles(fx.root);
}

test "git index reader: version 4 prefix compression and an intent-to-add entry read the same as git ls-files" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/deep/new.ts", .data = "x" });
    try gitOk(fx.root, &.{ "add", "-N", "src/deep/new.ts" });
    try expectMatchesLsFiles(fx.root);
    try gitOk(fx.root, &.{ "update-index", "--index-version", "4" });
    try expectMatchesLsFiles(fx.root);
}

test "git index reader: a merge conflict lists its path once, as git ls-files --deduplicate does" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init();
    defer fx.deinit();
    try gitOk(fx.root, &.{ "checkout", "-q", "-b", "other" });
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/a.ts", .data = "export const v = 2;\n" });
    try gitOk(fx.root, &.{ "commit", "-q", "-am", "other" });
    try gitOk(fx.root, &.{ "checkout", "-q", "-" });
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/a.ts", .data = "export const v = 3;\n" });
    try gitOk(fx.root, &.{ "commit", "-q", "-am", "main" });
    try gitOk(fx.root, &.{ "merge", "-q", "other" });
    const status = try git(fx.root, &.{ "ls-files", "-u" });
    defer gpa.free(status);
    try testing.expect(status.len != 0);
    try expectMatchesLsFiles(fx.root);
}

test "git index reader: a split index, a flipped byte or a cut file is not read" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init();
    defer fx.deinit();
    const index_path = try std.fmt.allocPrint(gpa, "{s}\\.git\\index", .{fx.root});
    defer gpa.free(index_path);
    const good = try std.Io.Dir.cwd().readFileAlloc(testing.io, index_path, gpa, .unlimited);
    defer gpa.free(good);

    const flipped = try gpa.dupe(u8, good);
    defer gpa.free(flipped);
    flipped[20] ^= 1;
    try testing.expect((try git_index.parse(gpa, flipped)) == null);
    try testing.expect((try git_index.parse(gpa, good[0 .. good.len - 7])) == null);

    try gitOk(fx.root, &.{ "update-index", "--split-index" });
    try testing.expect((try git_index.readTracked(gpa, testing.io, index_path)) == null);
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/added_after_split.ts", .data = "x" });
    try gitOk(fx.root, &.{ "add", "added_after_split.ts" });
    try testing.expect((try git_index.readTracked(gpa, testing.io, index_path)) == null);
}

test "git index reader: the eval repositories read the same as git ls-files" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    for ([_][]const u8{ "../eval/express-test", "../eval/eslint-test" }) |rel| {
        const root = std.Io.Dir.cwd().realPathFileAlloc(testing.io, rel, gpa) catch continue;
        defer gpa.free(root);
        try expectMatchesLsFiles(root);
    }
}

fn expectTrackedFilesMatchGit(root: []const u8) !void {
    const shadow = @import("emetgate").shadow;
    const files = try shadow.trackedFiles(gpa, testing.io, root);
    defer {
        shadow.freeFileList(gpa, files);
        gpa.free(files);
    }
    const listed = try git(root, &.{ "ls-files", "-z" });
    defer gpa.free(listed);
    var expected = std.mem.tokenizeScalar(u8, listed, 0);
    var n: usize = 0;
    while (expected.next()) |name| {
        if (n >= files.len) return error.TooFewNames;
        try testing.expectEqualStrings(name, files[n]);
        n += 1;
    }
    try testing.expectEqual(n, files.len);
}

test "tracked files: the listing is git ls-files entry for entry, for a plain, a version 4, a conflicted and a split index and from a subdirectory" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init();
    defer fx.deinit();
    try expectTrackedFilesMatchGit(fx.root);

    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/deep/new.ts", .data = "x" });
    try gitOk(fx.root, &.{ "add", "-N", "src/deep/new.ts" });
    try gitOk(fx.root, &.{ "update-index", "--index-version", "4" });
    try expectTrackedFilesMatchGit(fx.root);
    try gitOk(fx.root, &.{ "commit", "-q", "-am", "new" });

    try gitOk(fx.root, &.{ "checkout", "-q", "-b", "other" });
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/a.ts", .data = "export const v = 2;\n" });
    try gitOk(fx.root, &.{ "commit", "-q", "-am", "other" });
    try gitOk(fx.root, &.{ "checkout", "-q", "-" });
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/a.ts", .data = "export const v = 3;\n" });
    try gitOk(fx.root, &.{ "commit", "-q", "-am", "main" });
    try gitOk(fx.root, &.{ "merge", "-q", "other" });
    const unmerged = try git(fx.root, &.{ "ls-files", "-u" });
    defer gpa.free(unmerged);
    try testing.expect(unmerged.len != 0);
    try expectTrackedFilesMatchGit(fx.root);

    const sub = try std.fmt.allocPrint(gpa, "{s}\\src", .{fx.root});
    defer gpa.free(sub);
    try expectTrackedFilesMatchGit(sub);

    try gitOk(fx.root, &.{ "update-index", "--split-index" });
    try expectTrackedFilesMatchGit(fx.root);
}

test "tracked files: an empty repository and one whose index is gone list nothing, as git ls-files does" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.tmp.dir.deleteFile(testing.io, "repo/.git/index");
    try expectTrackedFilesMatchGit(fx.root);
}

test "toplevel: a remembered root is dropped when a repository appears between it and the directory, and when the root stops being one" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const repo = @import("emetgate").repo;
    var fx = try Fixture.init();
    defer fx.deinit();
    const deep = try std.fmt.allocPrint(gpa, "{s}\\src\\deep", .{fx.root});
    defer gpa.free(deep);
    const inner = try std.fmt.allocPrint(gpa, "{s}\\src", .{fx.root});
    defer gpa.free(inner);

    for (0..2) |_| {
        const top = try repo.gitToplevel(gpa, testing.io, deep);
        defer gpa.free(top);
        try testing.expectEqualStrings(fx.root, top);
    }

    try git_fixture.initRepo(inner);
    {
        const top = try repo.gitToplevel(gpa, testing.io, deep);
        defer gpa.free(top);
        try testing.expectEqualStrings(inner, top);
    }

    try fx.tmp.dir.deleteTree(testing.io, "repo/src/.git");
    try fx.tmp.dir.deleteTree(testing.io, "repo/.git");
    const outer = repo.gitToplevel(gpa, testing.io, deep) catch |err| {
        try testing.expectEqual(error.NotInRepo, err);
        return;
    };
    defer gpa.free(outer);
    try testing.expect(!std.ascii.eqlIgnoreCase(outer, fx.root));
    try testing.expect(!std.ascii.eqlIgnoreCase(outer, inner));
}
