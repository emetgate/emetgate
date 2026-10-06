const std = @import("std");
const exe_path = @import("exe_path.zig");
const shadow = @import("shadow.zig");
const disk = @import("disk.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

pub const work_dir = "commit";
pub const max_git_output = 1024 * 1024;

pub const Change = struct {
    rel: []const u8,
    content: ?[]const u8,
};

pub const Error = error{
    GitFailed,
    DetachedHead,
    NoCommitYet,
    OperationInProgress,
    SigningNotSupported,
    NoCommitIdentity,
    TargetHasUncommittedChanges,
    NothingToCommit,
    WrittenButNotCommitted,
};

pub const Head = struct {
    oid: []u8,
    tree: []u8,

    pub fn deinit(self: Head, gpa: Allocator) void {
        gpa.free(self.oid);
        gpa.free(self.tree);
    }
};

const in_progress = [_][]const u8{ "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG", "rebase-merge", "rebase-apply" };

const Git = struct {
    arena: Allocator,
    io: std.Io,
    root: []const u8,
    exe: []const u8,
    env: ?*const std.process.Environ.Map = null,

    fn init(arena: Allocator, io: std.Io, root: []const u8) !Git {
        return .{ .arena = arena, .io = io, .root = root, .exe = try exe_path.git(arena, root) };
    }

    fn run(self: Git, argv: []const []const u8) !?[]const u8 {
        var full: std.ArrayList([]const u8) = .empty;
        try full.appendSlice(self.arena, &.{ self.exe, "-c", "core.longpaths=true", "-c", "core.fsmonitor=false" });
        try full.appendSlice(self.arena, argv);
        const result = std.process.run(self.arena, self.io, .{
            .argv = full.items,
            .cwd = .{ .path = self.root },
            .environ_map = self.env,
            .stdout_limit = .limited(max_git_output),
            .stderr_limit = .limited(max_git_output),
        }) catch return error.GitFailed;
        return switch (result.term) {
            .exited => |code| if (code == 0) std.mem.trim(u8, result.stdout, " \r\n") else null,
            else => error.GitFailed,
        };
    }

    fn need(self: Git, argv: []const []const u8) ![]const u8 {
        return (try self.run(argv)) orelse error.GitFailed;
    }
};

fn slashed(arena: Allocator, rel: []const u8) ![]u8 {
    const out = try arena.dupe(u8, rel);
    std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
}

pub fn preflight(gpa: Allocator, io: std.Io, root: []const u8, rels: []const []const u8) !Head {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const git = try Git.init(arena, io, root);

    if (try git.run(&.{ "symbolic-ref", "-q", "HEAD" }) == null) return error.DetachedHead;
    const oid = (try git.run(&.{ "rev-parse", "--verify", "-q", "HEAD^{commit}" })) orelse return error.NoCommitYet;
    const tree = try git.need(&.{ "rev-parse", "--verify", "-q", "HEAD^{tree}" });

    const git_dir = try git.need(&.{ "rev-parse", "--absolute-git-dir" });
    for (in_progress) |name| {
        const path = try std.fs.path.join(arena, &.{ git_dir, name });
        Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return error.GitFailed,
        };
        return error.OperationInProgress;
    }

    if (try git.run(&.{ "config", "--type=bool", "--get", "commit.gpgsign" })) |value| {
        if (std.mem.eql(u8, value, "true")) return error.SigningNotSupported;
    }
    if (try git.run(&.{ "var", "GIT_COMMITTER_IDENT" }) == null) return error.NoCommitIdentity;

    var status: std.ArrayList([]const u8) = .empty;
    try status.appendSlice(arena, &.{ "status", "--porcelain=v1", "--untracked-files=all", "--" });
    for (rels) |rel| try status.append(arena, try slashed(arena, rel));
    if ((try git.need(status.items)).len != 0) return error.TargetHasUncommittedChanges;

    const owned_oid = try gpa.dupe(u8, oid);
    errdefer gpa.free(owned_oid);
    return .{ .oid = owned_oid, .tree = try gpa.dupe(u8, tree) };
}

pub fn prepare(gpa: Allocator, io: std.Io, root: []const u8, head: Head, changes: []const Change, message: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var git = try Git.init(arena, io, root);

    const dir = try std.fs.path.join(arena, &.{ root, shadow.workspace_dir, work_dir });
    try Dir.cwd().createDirPath(io, dir);
    defer Dir.cwd().deleteTree(io, dir) catch {};

    const index_path = try std.fs.path.join(arena, &.{ dir, "index" });
    var env = std.process.Environ.createMap(.{ .block = .global }, arena) catch return error.GitFailed;
    try env.put("GIT_INDEX_FILE", index_path);

    var blobs: std.ArrayList(?[]const u8) = .empty;
    for (changes, 0..) |change, i| {
        const content = change.content orelse {
            try blobs.append(arena, null);
            continue;
        };
        const blob_path = try std.fmt.allocPrint(arena, "{s}\\blob-{d}", .{ dir, i });
        try disk.writeDurably(io, blob_path, content);
        const path_arg = try std.fmt.allocPrint(arena, "--path={s}", .{try slashed(arena, change.rel)});
        try blobs.append(arena, try git.need(&.{ "hash-object", "-w", path_arg, "--", blob_path }));
    }

    git.env = &env;
    _ = try git.need(&.{ "read-tree", head.oid });
    for (changes, blobs.items) |change, blob| {
        const rel = try slashed(arena, change.rel);
        const oid = blob orelse {
            _ = try git.need(&.{ "update-index", "--force-remove", "--", rel });
            continue;
        };
        const listed = try git.need(&.{ "ls-files", "-s", "--", rel });
        const mode = if (listed.len >= 6) listed[0..6] else "100644";
        const info = try std.fmt.allocPrint(arena, "{s},{s},{s}", .{ mode, oid, rel });
        _ = try git.need(&.{ "update-index", "--add", "--cacheinfo", info });
    }
    const tree = try git.need(&.{ "write-tree" });
    git.env = null;
    if (std.mem.eql(u8, tree, head.tree)) return error.NothingToCommit;

    const message_path = try std.fs.path.join(arena, &.{ dir, "message" });
    const stored = if (std.mem.endsWith(u8, message, "\n")) message else try std.mem.concat(arena, u8, &.{ message, "\n" });
    try disk.writeDurably(io, message_path, stored);
    const commit = try git.need(&.{ "commit-tree", tree, "-p", head.oid, "-F", message_path });
    return gpa.dupe(u8, commit);
}

pub fn publish(gpa: Allocator, io: std.Io, root: []const u8, head: Head, commit: []const u8, changes: []const Change) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const git = try Git.init(arena, io, root);

    if (try git.run(&.{ "update-ref", "-m", "emetgate: commit", "HEAD", commit, head.oid }) == null) return error.WrittenButNotCommitted;

    var written: std.ArrayList([]const u8) = .empty;
    try written.appendSlice(arena, &.{ "add", "--" });
    var removed: std.ArrayList([]const u8) = .empty;
    try removed.appendSlice(arena, &.{ "rm", "--cached", "--ignore-unmatch", "-q", "--" });
    for (changes) |change| {
        const rel = try slashed(arena, change.rel);
        try (if (change.content != null) &written else &removed).append(arena, rel);
    }
    if (written.items.len > 2 and try git.run(written.items) == null) return error.WrittenButNotIndexed;
    if (removed.items.len > 5 and try git.run(removed.items) == null) return error.WrittenButNotIndexed;
}
