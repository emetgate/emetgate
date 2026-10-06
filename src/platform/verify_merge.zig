const std = @import("std");
const builtin = @import("builtin");
const checker = @import("../verify/checker.zig");
const receipts = @import("receipts.zig");
const shadow = @import("shadow.zig");
const exe_path = @import("exe_path.zig");
const own_dir = @import("own_dir.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

pub const added_nothing = "adds nothing to its parents; the combination was not gated";
pub const carries_content = "holds content that git's own merge of its two parents does not produce";
pub const many_parents = "has more than two parents; what it adds cannot be told";
pub const merge_not_run = "git could not merge the two parents on its own (git merge-tree --write-tree, git 2.38 or later); what the commit adds cannot be told";

pub const work_dir = "verify";
pub const objects_suffix = ".objects";
const object_directory = "GIT_OBJECT_DIRECTORY";
const alternate_directories = "GIT_ALTERNATE_OBJECT_DIRECTORIES";
const max_output = 64 * 1024 * 1024;

pub fn parents(arena: Allocator, io: std.Io, root: []const u8, commit: []const u8) ![]const []const u8 {
    const out = (try receipts.git(arena, io, root, &.{ "rev-list", "--parents", "-n", "1", commit })) orelse return error.GitFailed;
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, out, " \r\n");
    _ = it.next() orelse return error.GitFailed;
    while (it.next()) |parent| try list.append(arena, parent);
    return list.items;
}

pub fn judge(arena: Allocator, io: std.Io, root: []const u8, commit: []const u8, of: []const []const u8) !checker.Report {
    if (of.len != 2) return told(.unverified, many_parents);
    const differing = switch ((try compare(arena, io, root, commit, of[0], of[1])) orelse return told(.unverified, merge_not_run)) {
        .same => return told(.merged, added_nothing),
        .differ => |paths| paths,
    };
    var files: std.ArrayList(checker.FileResult) = .empty;
    for (differing) |path| try files.append(arena, .{ .path = path, .outcome = .{ .verdict = .unverified, .reason = carries_content } });
    return .{ .files = files.items, .receipts = &.{}, .verdict = .unverified, .reason = carries_content };
}

fn told(verdict: checker.Verdict, reason: []const u8) checker.Report {
    return .{ .files = &.{}, .receipts = &.{}, .verdict = verdict, .reason = reason };
}

const Compared = union(enum) {
    same,
    differ: []const []const u8,
};

fn compare(arena: Allocator, io: std.Io, root: []const u8, commit: []const u8, ours: []const u8, theirs: []const u8) !?Compared {
    if (builtin.os.tag != .windows) return null;
    const store_out = (try receipts.git(arena, io, root, &.{ "rev-parse", "--path-format=absolute", "--git-path", "objects" })) orelse return null;
    const store = std.mem.trim(u8, store_out, " \r\n");
    const want_out = (try receipts.git(arena, io, root, &.{ "rev-parse", "--verify", "--quiet", try std.fmt.allocPrint(arena, "{s}^{{tree}}", .{commit}) })) orelse return null;
    const want = std.mem.trim(u8, want_out, " \r\n");

    const scratch = try Scratch.open(arena, io, root);
    defer scratch.close(io);
    const process: std.process.Environ = .{ .block = .global };
    var env = try process.createMap(arena);
    try env.put(object_directory, scratch.dir_abs);
    try env.put(alternate_directories, store);

    const merged = try run(arena, io, root, &env, &.{ "merge-tree", "--write-tree", "--no-messages", ours, theirs });
    if (merged.code != 0 and merged.code != 1) return null;
    const tree = std.mem.sliceTo(merged.stdout, '\n');
    if (std.mem.eql(u8, tree, want)) return .same;
    const diff = try run(arena, io, root, &env, &.{ "diff-tree", "-r", "--name-only", "-z", tree, want });
    if (diff.code != 0) return null;
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, diff.stdout, 0);
    while (it.next()) |path| try list.append(arena, path);
    return .{ .differ = list.items };
}

const Ran = struct {
    code: u8,
    stdout: []const u8,
};

fn run(arena: Allocator, io: std.Io, root: []const u8, env: *const std.process.Environ.Map, argv: []const []const u8) !Ran {
    var full: std.ArrayList([]const u8) = .empty;
    try full.appendSlice(arena, &.{ try exe_path.git(arena, root), "-c", "core.longpaths=true" });
    try full.appendSlice(arena, argv);
    const result = std.process.run(arena, io, .{ .argv = full.items, .cwd = .{ .path = root }, .environ_map = env, .stdout_limit = .limited(max_output) }) catch return error.GitFailed;
    return switch (result.term) {
        .exited => |code| .{ .code = code, .stdout = result.stdout },
        else => error.GitFailed,
    };
}

const Scratch = struct {
    outer: own_dir.Held,
    inner: own_dir.Held,
    workspace_abs: []const u8,
    outer_abs: []const u8,
    dir_abs: []const u8,

    fn open(arena: Allocator, io: std.Io, root: []const u8) !Scratch {
        var random: [8]u8 = undefined;
        io.random(&random);
        const workspace_abs = try std.fmt.allocPrint(arena, "{s}\\{s}", .{ root, shadow.workspace_dir });
        const outer_abs = try std.fmt.allocPrint(arena, "{s}\\{s}", .{ workspace_abs, work_dir });
        const dir_abs = try std.fmt.allocPrint(arena, "{s}\\{s}{s}", .{ outer_abs, &std.fmt.bytesToHex(random, .lower), objects_suffix });
        const outer = (try own_dir.hold(io, outer_abs, .create)).?;
        errdefer outer.close();
        const inner = (try own_dir.hold(io, dir_abs, .create)).?;
        return .{ .outer = outer, .inner = inner, .workspace_abs = workspace_abs, .outer_abs = outer_abs, .dir_abs = dir_abs };
    }

    fn close(self: Scratch, io: std.Io) void {
        clear(io, self.inner.dir);
        self.inner.close();
        _ = own_dir.removeEmpty(self.dir_abs);
        self.outer.close();
        _ = own_dir.removeEmpty(self.outer_abs);
        _ = own_dir.removeEmpty(self.workspace_abs);
    }
};

pub fn clear(io: std.Io, objects: Dir) void {
    var fans: [256][2]u8 = undefined;
    var count: usize = 0;
    var it = objects.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory or entry.name.len != 2 or !lowerHex(entry.name)) continue;
        fans[count] = entry.name[0..2].*;
        count += 1;
        if (count == fans.len) break;
    }
    for (fans[0..count]) |fan| {
        clearFan(io, objects, &fan);
        objects.deleteDir(io, &fan) catch {};
    }
}

fn clearFan(io: std.Io, objects: Dir, fan: []const u8) void {
    var dir = objects.openDir(io, fan, .{ .iterate = true, .follow_symlinks = false }) catch return;
    defer dir.close(io);
    while (true) {
        var name_buf: [64]u8 = undefined;
        var name: ?[]const u8 = null;
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file or !objectName(entry.name)) continue;
            @memcpy(name_buf[0..entry.name.len], entry.name);
            name = name_buf[0..entry.name.len];
            break;
        }
        dir.deleteFile(io, name orelse return) catch return;
    }
}

fn objectName(name: []const u8) bool {
    return (name.len == 38 or name.len == 62) and lowerHex(name);
}

fn lowerHex(text: []const u8) bool {
    for (text) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    }
    return true;
}
