const std = @import("std");

const testing = std.testing;

pub const settings = "[user]\n\temail = t@t\n\tname = t\n[maintenance]\n\tauto = false\n[gc]\n\tauto = 0\n";

const Template = struct {
    head: []const u8,
    config: []const u8,
};

var template: ?Template = null;

var git_exe: ?[]const u8 = null;

pub fn git() error{ GitNotFound, OutOfMemory }![]const u8 {
    if (git_exe) |found| return found;
    const found = try @import("emetgate").exe_path.git(std.heap.page_allocator, null);
    git_exe = found;
    return found;
}

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
    const result = try @import("emetgate").bounded_run.run(testing.allocator, testing.io, .{ .argv = &.{ try git(), "init", "-q", "--template=" }, .cwd = .{ .path = dir_abs } });
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

fn runGit(root_abs: []const u8, args: []const []const u8) !void {
    var argv: [8][]const u8 = undefined;
    argv[0] = try git();
    @memcpy(argv[1..][0..args.len], args);
    const result = try @import("emetgate").bounded_run.run(testing.allocator, testing.io, .{ .argv = argv[0 .. args.len + 1], .cwd = .{ .path = root_abs } });
    testing.allocator.free(result.stdout);
    testing.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitSetupFailed,
        else => return error.GitSetupFailed,
    }
}

pub fn commitInit(root_abs: []const u8, allow_empty: bool) !void {
    try runGit(root_abs, &.{ "add", "." });
    if (allow_empty) try runGit(root_abs, &.{ "commit", "-q", "--allow-empty", "-m", "init" }) else try runGit(root_abs, &.{ "commit", "-q", "-m", "init" });
}
