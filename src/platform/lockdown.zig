const std = @import("std");

const Allocator = std.mem.Allocator;

pub const claude_program = "claude";
pub const allowed_builtin_tools = "ToolSearch";
pub const mcp_config_name = ".mcp.json";

const reserved_flags = [_][]const u8{
    "--tools",
    "--allowedTools",
    "--allowed-tools",
    "--mcp-config",
    "--strict-mcp-config",
    "--settings",
    "--plugin-dir",
    "--agents",
    "--dangerously-skip-permissions",
    "--allow-dangerously-skip-permissions",
};

pub fn refuseReserved(passthrough: []const []const u8) error{LockdownFlagOverride}!void {
    for (passthrough) |arg| {
        for (reserved_flags) |flag| {
            if (std.mem.eql(u8, arg, flag)) return error.LockdownFlagOverride;
            if (arg.len > flag.len and std.mem.startsWith(u8, arg, flag) and arg[flag.len] == '=') return error.LockdownFlagOverride;
        }
    }
}

pub fn buildArgv(gpa: Allocator, mcp_config_abs: []const u8, passthrough: []const []const u8) ![]const []const u8 {
    try refuseReserved(passthrough);
    const fixed = [_][]const u8{ claude_program, "--tools", allowed_builtin_tools, "--mcp-config", mcp_config_abs, "--strict-mcp-config" };
    const argv = try gpa.alloc([]const u8, fixed.len + passthrough.len);
    @memcpy(argv[0..fixed.len], &fixed);
    @memcpy(argv[fixed.len..], passthrough);
    return argv;
}

pub fn resolveMcpConfig(gpa: Allocator, io: std.Io, dir: std.Io.Dir) ![:0]u8 {
    return dir.realPathFileAlloc(io, mcp_config_name, gpa) catch |err| switch (err) {
        error.FileNotFound => return error.McpConfigMissing,
        else => return err,
    };
}

pub fn launch(gpa: Allocator, io: std.Io, passthrough: []const []const u8) !u8 {
    try refuseReserved(passthrough);
    const config_abs = try resolveMcpConfig(gpa, io, std.Io.Dir.cwd());
    defer gpa.free(config_abs);
    const argv = try buildArgv(gpa, config_abs, passthrough);
    defer gpa.free(argv);
    var child = try std.process.spawn(io, .{ .argv = argv });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| code,
        else => error.ClaudeTerminated,
    };
}
