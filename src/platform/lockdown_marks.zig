const std = @import("std");
const lockdown_slash = @import("lockdown_slash.zig");

const Allocator = std.mem.Allocator;

pub const off_flag = "--no-marks";
pub const plugin_flag = "--plugin-dir";
pub const plugin_dir = "marks";

pub const File = struct {
    path: []const u8,
    data: []const u8,
};

pub const files = [_]File{
    .{ .path = ".claude-plugin\\plugin.json", .data = @embedFile("marks/plugin.json") },
    .{ .path = "hooks\\hooks.json", .data = @embedFile("marks/hooks.json") },
    .{ .path = "hooks\\register.tsx", .data = @embedFile("marks/register.tsx") },
    .{ .path = "hooks\\scene.ts", .data = @embedFile("marks/scene.ts") },
    .{ .path = "types\\index.d.ts", .data = @embedFile("marks/index.d.ts") },
};

pub const Choice = struct {
    wanted: bool,
    rest: []const []const u8,
};

pub fn choose(args: []const []const u8) Choice {
    if (args.len > 0 and std.mem.eql(u8, args[0], off_flag)) return .{ .wanted = false, .rest = args[1..] };
    return .{ .wanted = true, .rest = args };
}

pub fn install(gpa: Allocator, io: std.Io, state_dir: []const u8) ![]u8 {
    const dir = try std.fs.path.join(gpa, &.{ state_dir, plugin_dir });
    errdefer gpa.free(dir);
    for (files) |file| {
        const abs = try std.fs.path.join(gpa, &.{ dir, file.path });
        defer gpa.free(abs);
        try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(abs).?);
        try lockdown_slash.place(gpa, io, abs, file.data);
    }
    return dir;
}

pub fn extend(gpa: Allocator, argv: []const []const u8, passthrough_len: usize, dir: []const u8) ![][]const u8 {
    const added = [_][]const u8{ plugin_flag, dir };
    const at = argv.len - passthrough_len;
    const out = try gpa.alloc([]const u8, argv.len + added.len);
    @memcpy(out[0..at], argv[0..at]);
    @memcpy(out[at .. at + added.len], &added);
    @memcpy(out[at + added.len ..], argv[at..]);
    return out;
}
