const std = @import("std");
const shadow = @import("shadow.zig");

const Allocator = std.mem.Allocator;
const max_git_output = 64 * 1024;

pub const Jailed = struct {
    root: []u8,
    abs: [:0]u8,
    rel: []u8,
    creates: bool = false,

    pub fn deinit(self: Jailed, gpa: Allocator) void {
        gpa.free(self.root);
        gpa.free(self.abs);
        gpa.free(self.rel);
    }
};

pub fn repoRoot(gpa: Allocator, io: std.Io) ![]u8 {
    return gitToplevel(gpa, io, ".");
}

pub fn servedRoot(gpa: Allocator, io: std.Io, root: ?[]const u8) ![]u8 {
    const given = root orelse return repoRoot(gpa, io);
    const owned = try gpa.dupe(u8, given);
    std.mem.replaceScalar(u8, owned, '/', '\\');
    return owned;
}

pub fn jail(gpa: Allocator, io: std.Io, root: ?[]const u8, path: []const u8) !Jailed {
    const served = try servedRoot(gpa, io, root);
    errdefer gpa.free(served);
    const abs = try std.Io.Dir.cwd().realPathFileAlloc(io, path, gpa);
    errdefer gpa.free(abs);
    const rel = try relativeTo(gpa, served, abs);
    errdefer gpa.free(rel);
    try refuseInternal(rel);
    if (rel.len != 0) try expectSameRepo(gpa, io, served, abs);
    return .{ .root = served, .abs = abs, .rel = rel };
}

pub fn jailTarget(gpa: Allocator, io: std.Io, root: ?[]const u8, path: []const u8, may_create: bool) !Jailed {
    return jail(gpa, io, root, path) catch |err| switch (err) {
        error.FileNotFound => if (may_create) jailNew(gpa, io, root, path) else error.FileNotFound,
        else => |e| e,
    };
}

pub fn jailNew(gpa: Allocator, io: std.Io, root: ?[]const u8, path: []const u8) !Jailed {
    const name = std.fs.path.basename(path);
    if (name.len == 0 or std.mem.indexOfAny(u8, name, "/\\") != null) return error.InvalidPath;
    shadow.validateRelative(name) catch return error.InvalidPath;
    const parent = std.fs.path.dirname(path) orelse ".";

    const served = try servedRoot(gpa, io, root);
    errdefer gpa.free(served);
    const parent_abs = std.Io.Dir.cwd().realPathFileAlloc(io, parent, gpa) catch |err| switch (err) {
        error.FileNotFound => return error.ParentDirectoryMissing,
        else => |e| return e,
    };
    defer gpa.free(parent_abs);
    var parent_dir = std.Io.Dir.openDirAbsolute(io, parent_abs, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.ParentDirectoryMissing,
        else => |e| return e,
    };
    parent_dir.close(io);

    const joined = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ parent_abs, name });
    defer gpa.free(joined);
    const abs = try gpa.dupeZ(u8, joined);
    errdefer gpa.free(abs);
    const rel = try relativeTo(gpa, served, abs);
    errdefer gpa.free(rel);
    if (rel.len == 0) return error.InvalidPath;
    try refuseInternal(rel);
    try expectSameRepo(gpa, io, served, abs);
    std.Io.Dir.cwd().access(io, abs, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{ .root = served, .abs = abs, .rel = rel, .creates = true },
        else => |e| return e,
    };
    return error.FileExists;
}

pub fn isIgnored(gpa: Allocator, io: std.Io, root_abs: []const u8, rel: []const u8) !bool {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "git", "check-ignore", "-q", "--no-index", "--", rel },
        .cwd = .{ .path = root_abs },
        .stdout_limit = .limited(max_git_output),
    }) catch return error.GitFailed;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return switch (result.term) {
        .exited => |code| switch (code) {
            0 => true,
            1 => false,
            else => error.GitFailed,
        },
        else => error.GitFailed,
    };
}

pub fn trackedListing(gpa: Allocator, io: std.Io, root_abs: []const u8, pathspec: []const u8) ![]u8 {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "git", "ls-files", "-z", "--", pathspec },
        .cwd = .{ .path = root_abs },
        .stdout_limit = .limited(max_git_output),
    }) catch return error.GitFailed;
    defer gpa.free(result.stderr);
    errdefer gpa.free(result.stdout);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitFailed,
        else => return error.GitFailed,
    }
    return result.stdout;
}

pub fn addToIndex(gpa: Allocator, io: std.Io, root_abs: []const u8, rel: []const u8) !void {
    var attempt: usize = 0;
    while (attempt < index_add_attempts) : (attempt += 1) {
        if (attempt != 0) io.sleep(.fromMilliseconds(index_retry_ms), .awake) catch {};
        const result = std.process.run(gpa, io, .{
            .argv = &.{ "git", "add", "--", rel },
            .cwd = .{ .path = root_abs },
            .stdout_limit = .limited(max_git_output),
        }) catch continue;
        gpa.free(result.stdout);
        gpa.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code == 0) return,
            else => {},
        }
    }
    return error.WrittenButNotIndexed;
}

const index_add_attempts = 3;
const index_retry_ms = 100;

fn expectSameRepo(gpa: Allocator, io: std.Io, root: []const u8, abs: []const u8) !void {
    const dir = std.fs.path.dirname(abs) orelse return error.FileOutsideRepo;
    const own = gitToplevel(gpa, io, dir) catch |err| switch (err) {
        error.NotInRepo => return error.FileOutsideRepo,
        else => return err,
    };
    defer gpa.free(own);
    if (!std.ascii.eqlIgnoreCase(own, root)) return error.FileOutsideRepo;
}

pub fn refuseInternal(rel: []const u8) error{InternalPath}!void {
    var segments = std.mem.tokenizeAny(u8, rel, "/\\");
    const first = segments.next() orelse return;
    if (std.ascii.eqlIgnoreCase(first, ".git") or std.ascii.eqlIgnoreCase(first, shadow.workspace_dir)) return error.InternalPath;
}

pub fn relativeTo(gpa: Allocator, root: []const u8, path_abs: []const u8) ![]u8 {
    const normalized = try gpa.dupe(u8, path_abs);
    defer gpa.free(normalized);
    std.mem.replaceScalar(u8, normalized, '/', '\\');
    if (std.ascii.eqlIgnoreCase(normalized, root)) return gpa.dupe(u8, "");
    return relativeUnder(gpa, root, normalized);
}

pub fn relativeUnder(gpa: Allocator, root: []const u8, file_abs: []const u8) ![]u8 {
    const normalized = try gpa.dupe(u8, file_abs);
    defer gpa.free(normalized);
    std.mem.replaceScalar(u8, normalized, '/', '\\');
    if (normalized.len <= root.len or !std.ascii.startsWithIgnoreCase(normalized, root) or normalized[root.len] != '\\') {
        return error.FileOutsideRepo;
    }
    return gpa.dupe(u8, normalized[root.len + 1 ..]);
}

pub fn gitToplevel(gpa: Allocator, io: std.Io, dir_abs: []const u8) ![]u8 {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "git", "rev-parse", "--show-toplevel" },
        .cwd = .{ .path = dir_abs },
        .stdout_limit = .limited(max_git_output),
    }) catch return error.GitFailed;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.NotInRepo,
        else => return error.GitFailed,
    }
    const trimmed = std.mem.trim(u8, result.stdout, " \r\n");
    const owned = try gpa.dupe(u8, trimmed);
    std.mem.replaceScalar(u8, owned, '/', '\\');
    return owned;
}
