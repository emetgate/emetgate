const std = @import("std");

const Allocator = std.mem.Allocator;

pub const claude_program = "claude";
pub const allowed_builtin_tools = "";
pub const mcp_config_name = ".mcp.json";
pub const max_mcp_config_bytes = 1024 * 1024;
pub const tool_search_variable = "ENABLE_TOOL_SEARCH";
pub const tool_search_value = "false";

pub const read_only_tools = [_][]const u8{
    "emetgate_symbols",
    "emetgate_skeleton",
    "emetgate_read_symbol",
    "emetgate_read_file",
    "emetgate_list",
    "emetgate_search",
    "emetgate_scan",
    "emetgate_git",
    "emetgate_mutate",
};

const emetgate_program = "emetgate";
const server_commands = [_][]const u8{ "mcp", "serve" };
const claude_ai_prefix = "claude.ai ";

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

const permission_mode_flag = "--permission-mode";
const refused_permission_mode = "bypassPermissions";

pub fn refuseReserved(passthrough: []const []const u8) error{LockdownFlagOverride}!void {
    for (passthrough, 0..) |arg, i| {
        for (reserved_flags) |flag| {
            if (std.mem.eql(u8, arg, flag)) return error.LockdownFlagOverride;
            if (arg.len > flag.len and std.mem.startsWith(u8, arg, flag) and arg[flag.len] == '=') return error.LockdownFlagOverride;
        }
        if (permissionMode(passthrough, i)) |mode| {
            if (std.ascii.eqlIgnoreCase(mode, refused_permission_mode)) return error.LockdownFlagOverride;
        }
    }
}

fn permissionMode(args: []const []const u8, i: usize) ?[]const u8 {
    const arg = args[i];
    if (std.mem.eql(u8, arg, permission_mode_flag)) return if (i + 1 < args.len) args[i + 1] else null;
    if (std.mem.startsWith(u8, arg, permission_mode_flag ++ "=")) return arg[permission_mode_flag.len + 1 ..];
    return null;
}

pub fn buildArgv(gpa: Allocator, mcp_config_abs: []const u8, allowed_tools: []const u8, passthrough: []const []const u8) ![][]const u8 {
    try refuseReserved(passthrough);
    const fixed = [_][]const u8{ claude_program, "--tools", allowed_builtin_tools, "--allowedTools", allowed_tools, "--mcp-config", mcp_config_abs, "--strict-mcp-config" };
    const argv = try gpa.alloc([]const u8, fixed.len + passthrough.len);
    @memcpy(argv[0..fixed.len], &fixed);
    @memcpy(argv[fixed.len..], passthrough);
    return argv;
}

pub fn emetgateServer(gpa: Allocator, mcp_config: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, mcp_config, .{}) catch return error.McpConfigInvalid;
    defer parsed.deinit();
    if (parsed.value != .object) return error.McpConfigInvalid;
    const servers = parsed.value.object.get("mcpServers") orelse return error.NoEmetgateServer;
    if (servers != .object) return error.McpConfigInvalid;
    var found: ?[]const u8 = null;
    var entries = servers.object.iterator();
    while (entries.next()) |entry| {
        if (!isEmetgateServer(entry.value_ptr.*)) continue;
        if (found != null) return error.SeveralEmetgateServers;
        found = entry.key_ptr.*;
    }
    return toolNamePart(gpa, found orelse return error.NoEmetgateServer);
}

fn isEmetgateServer(server: std.json.Value) bool {
    if (server != .object) return false;
    const command = server.object.get("command") orelse return false;
    const args = server.object.get("args") orelse return false;
    if (command != .string or args != .array or args.array.items.len == 0) return false;
    const first = args.array.items[0];
    if (first != .string) return false;
    for (server_commands) |name| {
        if (std.mem.eql(u8, first.string, name)) return isEmetgateProgram(command.string);
    }
    return false;
}

fn isEmetgateProgram(command: []const u8) bool {
    const name = std.fs.path.basenameWindows(command);
    const stem = if (std.ascii.endsWithIgnoreCase(name, ".exe")) name[0 .. name.len - ".exe".len] else name;
    return std.ascii.eqlIgnoreCase(stem, emetgate_program);
}

pub fn toolNamePart(gpa: Allocator, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var codepoints = (std.unicode.Utf8View.init(name) catch return error.McpConfigInvalid).iterator();
    while (codepoints.nextCodepoint()) |c| {
        if (c < 0x80 and (std.ascii.isAlphanumeric(@intCast(c)) or c == '_' or c == '-')) {
            try out.append(gpa, @intCast(c));
        } else {
            try out.appendNTimes(gpa, '_', if (c > 0xFFFF) 2 else 1);
        }
    }
    if (std.mem.startsWith(u8, name, claude_ai_prefix)) collapseUnderscores(&out);
    return out.toOwnedSlice(gpa);
}

fn collapseUnderscores(out: *std.ArrayList(u8)) void {
    var kept: usize = 0;
    for (out.items) |c| {
        if (c == '_' and kept > 0 and out.items[kept - 1] == '_') continue;
        out.items[kept] = c;
        kept += 1;
    }
    const start: usize = if (kept > 0 and out.items[0] == '_') 1 else 0;
    const end: usize = if (kept > start and out.items[kept - 1] == '_') kept - 1 else kept;
    std.mem.copyForwards(u8, out.items[0 .. end - start], out.items[start..end]);
    out.shrinkRetainingCapacity(end - start);
}

pub fn allowedTools(gpa: Allocator, server: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (read_only_tools, 0..) |tool, i| {
        if (i != 0) try out.append(gpa, ' ');
        try out.print(gpa, "mcp__{s}__{s}", .{ server, tool });
    }
    return out.toOwnedSlice(gpa);
}

pub fn resolveMcpConfig(gpa: Allocator, io: std.Io, dir: std.Io.Dir) ![:0]u8 {
    return dir.realPathFileAlloc(io, mcp_config_name, gpa) catch |err| switch (err) {
        error.FileNotFound => return error.McpConfigMissing,
        else => return err,
    };
}

pub fn childEnviron(gpa: Allocator, parent: *const std.process.Environ.Map) !std.process.Environ.Map {
    var env = try parent.clone(gpa);
    errdefer env.deinit();
    try env.put(tool_search_variable, tool_search_value);
    return env;
}

pub fn launch(gpa: Allocator, io: std.Io, parent_env: *const std.process.Environ.Map, passthrough: []const []const u8) !u8 {
    return launchIn(gpa, io, std.Io.Dir.cwd(), parent_env, claude_program, passthrough);
}

pub fn launchIn(gpa: Allocator, io: std.Io, dir: std.Io.Dir, parent_env: *const std.process.Environ.Map, program: []const u8, passthrough: []const []const u8) !u8 {
    try refuseReserved(passthrough);
    const config_abs = try resolveMcpConfig(gpa, io, dir);
    defer gpa.free(config_abs);
    const config = try dir.readFileAlloc(io, mcp_config_name, gpa, .limited(max_mcp_config_bytes));
    defer gpa.free(config);
    const server = try emetgateServer(gpa, config);
    defer gpa.free(server);
    const allowed = try allowedTools(gpa, server);
    defer gpa.free(allowed);
    const argv = try buildArgv(gpa, config_abs, allowed, passthrough);
    defer gpa.free(argv);
    argv[0] = program;
    var env = try childEnviron(gpa, parent_env);
    defer env.deinit();
    var child = try std.process.spawn(io, .{ .argv = argv, .environ_map = &env });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| code,
        else => error.ClaudeTerminated,
    };
}
