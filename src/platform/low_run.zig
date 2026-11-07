const std = @import("std");
const sandbox = @import("sandbox.zig");
const shadow = @import("shadow.zig");
const shadow_root = @import("shadow_root.zig");
const cache_lease = @import("cache_lease.zig");
const link_tree = @import("link_tree.zig");

const Allocator = std.mem.Allocator;

pub const temp_family = "run-tmp";
pub const cache_family = "cache";

pub const denied_note = "the command ran at low integrity and may have been refused a write outside the repository (access denied); if it must write there, call emetgate_run again with as_user:true and the user is asked before it runs with full rights";

pub const Confined = struct {
    temp: []const u8,
    env: []const sandbox.EnvVar,
};

pub fn lowWritable(arena: Allocator, dir_abs: []const u8) !bool {
    const extended = try std.fmt.allocPrint(arena, "\\\\?\\{s}", .{dir_abs});
    const wide = try std.unicode.wtf8ToWtf16LeAllocZ(arena, extended);
    return !try link_tree.lowWriteBlocked(wide);
}

pub fn labelRoot(arena: Allocator, root_abs: []const u8) !void {
    if (!try lowWritable(arena, root_abs)) try shadow.grantLowIntegrityWrite(root_abs);
}

pub fn prepare(arena: Allocator, gpa: Allocator, io: std.Io, root_abs: []const u8, extra_env: []const sandbox.EnvVar) !Confined {
    try labelRoot(arena, root_abs);
    const data = try cache_lease.defaultDataDir(gpa);
    defer gpa.free(data);
    const key = shadow_root.repoKey(root_abs);
    const temp = try std.fmt.allocPrint(arena, "{s}\\{s}\\{s}", .{ data, temp_family, &key });
    const cache = try std.fmt.allocPrint(arena, "{s}\\{s}", .{ data, cache_family });
    try shadow.ensureCache(io, cache);
    try shadow.freshTemp(io, temp);
    const env = try std.mem.concat(arena, sandbox.EnvVar, &.{ extra_env, try sandbox.cacheEnvironment(arena, cache) });
    return .{ .temp = temp, .env = env };
}

const denial_markers = [_][]const u8{ "permission denied", "access is denied", "access denied", "eacces", "eperm", "unauthorizedaccess" };

pub fn deniedWrite(report: sandbox.Report) bool {
    if (report.passed()) return false;
    for (denial_markers) |marker| {
        if (std.ascii.indexOfIgnoreCase(report.stdout, marker) != null) return true;
        if (std.ascii.indexOfIgnoreCase(report.stderr, marker) != null) return true;
    }
    return false;
}
