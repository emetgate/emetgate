const std = @import("std");

const Allocator = std.mem.Allocator;
const max_git_output = 64 * 1024;

pub fn repoRoot(gpa: Allocator, io: std.Io) ![]u8 {
    return gitToplevel(gpa, io, ".");
}

pub fn assertUnderCwdRepo(gpa: Allocator, io: std.Io, file_abs: []const u8) !void {
    const root = try gitToplevel(gpa, io, ".");
    defer gpa.free(root);
    const rel = try relativeUnder(gpa, root, file_abs);
    gpa.free(rel);
}

pub fn repoRelative(gpa: Allocator, io: std.Io, path_abs: []const u8) ![]u8 {
    const root = try gitToplevel(gpa, io, ".");
    defer gpa.free(root);
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
