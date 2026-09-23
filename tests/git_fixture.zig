const std = @import("std");

const testing = std.testing;

pub const settings = "[user]\n\temail = t@t\n\tname = t\n[maintenance]\n\tauto = false\n[gc]\n\tauto = 0\n";

const Template = struct {
    head: []const u8,
    config: []const u8,
};

var template: ?Template = null;

const layout = [_][]const u8{ "objects/info", "objects/pack", "refs/heads", "refs/tags" };

pub fn initRepo(root_abs: []const u8) !void {
    const t = template orelse try makeTemplate();
    var root = try std.Io.Dir.cwd().openDir(testing.io, root_abs, .{});
    defer root.close(testing.io);
    for (layout) |dir| {
        const sub = try std.fmt.allocPrint(testing.allocator, ".git/{s}", .{dir});
        defer testing.allocator.free(sub);
        try root.createDirPath(testing.io, sub);
    }
    try root.writeFile(testing.io, .{ .sub_path = ".git/HEAD", .data = t.head });
    const config = try std.mem.concat(testing.allocator, u8, &.{ t.config, settings });
    defer testing.allocator.free(config);
    try root.writeFile(testing.io, .{ .sub_path = ".git/config", .data = config });
}

fn makeTemplate() !Template {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir_abs);
    const result = try std.process.run(testing.allocator, testing.io, .{ .argv = &.{ "git", "init", "-q", "--template=" }, .cwd = .{ .path = dir_abs } });
    testing.allocator.free(result.stdout);
    testing.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitSetupFailed,
        else => return error.GitSetupFailed,
    }
    const keep = std.heap.page_allocator;
    const made: Template = .{
        .head = try tmp.dir.readFileAlloc(testing.io, ".git/HEAD", keep, .limited(4096)),
        .config = try tmp.dir.readFileAlloc(testing.io, ".git/config", keep, .limited(64 * 1024)),
    };
    template = made;
    return made;
}

fn gitOut(cwd: []const u8, args: []const []const u8) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(testing.allocator);
    try argv.append(testing.allocator, "git");
    try argv.appendSlice(testing.allocator, args);
    const result = try std.process.run(testing.allocator, testing.io, .{ .argv = argv.items, .cwd = .{ .path = cwd } });
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

    try initRepo(root_abs);
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
