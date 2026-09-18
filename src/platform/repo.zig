const std = @import("std");
const shadow = @import("shadow.zig");

const Allocator = std.mem.Allocator;
const max_git_output = 64 * 1024;

pub const Jailed = struct {
    root: []u8,
    abs: [:0]u8,
    rel: []u8,

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
