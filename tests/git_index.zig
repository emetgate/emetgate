const std = @import("std");
const builtin = @import("builtin");
const git_fixture = @import("git_fixture.zig");
const git_index = @import("emetgate").git_index;

const testing = std.testing;
const gpa = testing.allocator;

fn git(root: []const u8, args: []const []const u8) ![]u8 {
    var argv: [10][]const u8 = undefined;
    argv[0] = "git";
    @memcpy(argv[1..][0..args.len], args);
    const result = try std.process.run(gpa, testing.io, .{ .argv = argv[0 .. args.len + 1], .cwd = .{ .path = root } });
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
    const listed = try git(root, &.{ "ls-files", "-z" });
    defer gpa.free(listed);
    var expected = std.mem.tokenizeScalar(u8, listed, 0);
    var n: usize = 0;
    while (expected.next()) |name| : (n += 1) {
        if (n >= names.len) return error.TooFewNames;
        try testing.expectEqualStrings(name, names[n]);
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
        try gitOk(root, &.{ "add", "." });
        try gitOk(root, &.{ "commit", "-q", "-m", "init" });
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

test "git index reader: a merge conflict lists its path once per stage, as git ls-files does" {
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
