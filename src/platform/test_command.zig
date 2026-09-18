const std = @import("std");
const repo = @import("repo.zig");

const Allocator = std.mem.Allocator;

pub const config_file = ".emetgaterc.json";

pub fn resolveTestCommand(gpa: Allocator, io: std.Io, file_abs: []const u8, given: []const u8, allow_repo_config: bool) ![]u8 {
    if (given.len != 0) return gpa.dupe(u8, given);

    const dir = std.fs.path.dirname(file_abs) orelse return error.InvalidPath;
    const root = try repo.gitToplevel(gpa, io, dir);
    defer gpa.free(root);
    const repo_path = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ root, config_file });
    defer gpa.free(repo_path);

    if (!allow_repo_config) {
        if (try fileExists(io, repo_path)) return error.UntrustedRepoConfig;
        return error.NoTestCommand;
    }
    return (try readConfigCommand(gpa, io, repo_path, .test_cmd)) orelse error.NoTestCommand;
}

pub fn resolveTypecheckCommand(gpa: Allocator, io: std.Io, file_abs: []const u8, given: []const u8, allow_repo_config: bool) !?[]u8 {
    if (given.len != 0) return try gpa.dupe(u8, given);
    if (!allow_repo_config) return null;

    const dir = std.fs.path.dirname(file_abs) orelse return error.InvalidPath;
    const root = try repo.gitToplevel(gpa, io, dir);
    defer gpa.free(root);
    const repo_path = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ root, config_file });
    defer gpa.free(repo_path);
    return readConfigCommand(gpa, io, repo_path, .typecheck_cmd);
}

const ConfigField = enum { test_cmd, typecheck_cmd };

fn readConfigCommand(gpa: Allocator, io: std.Io, path: []const u8, comptime field: ConfigField) !?[]u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer gpa.free(bytes);
    const parsed = std.json.parseFromSlice(struct { test_cmd: ?[]const u8 = null, typecheck_cmd: ?[]const u8 = null }, gpa, bytes, .{ .ignore_unknown_fields = true }) catch return error.InvalidConfig;
    defer parsed.deinit();
    const cmd = @field(parsed.value, @tagName(field)) orelse return null;
    if (cmd.len == 0) return null;
    return try gpa.dupe(u8, cmd);
}

fn fileExists(io: std.Io, path: []const u8) !bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}
