const std = @import("std");
const exe_path = @import("exe_path.zig");
const lockdown_marks = @import("lockdown_marks.zig");
const lockdown_slash = @import("lockdown_slash.zig");

const Allocator = std.mem.Allocator;

pub const claude_program = "claude";
pub const allowed_builtin_tools = "";
pub const mcp_config_name = ".mcp.json";
pub const own_mcp_config_name = "mcp.json";
pub const project_mcp_config_name = "project-mcp.json";
pub const always_load_field = "alwaysLoad";
pub const own_server_name = "emetgate";
pub const own_server_args = [_][]const u8{"mcp"};
pub const detect_flag = "--detect-test";
pub const test_flag = "--test";
pub const setting_sources_flag = "--setting-sources";
pub const setting_sources = "project";
const user_settings_off = [_][]const u8{ setting_sources_flag, setting_sources };
pub const max_mcp_config_bytes = 1024 * 1024;
pub const tool_search_variable = "ENABLE_TOOL_SEARCH";
pub const tool_search_value = "false";

pub const read_only_tools = [_][]const u8{
    "emetgate_explore",
    "emetgate_evidence",
    "emetgate_symbols",
    "emetgate_skeleton",
    "emetgate_read_symbol",
    "emetgate_read_file",
    "emetgate_list",
    "emetgate_search",
    "emetgate_find",
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
    "--setting-sources",
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
    const locked = [_][]const u8{ claude_program, "--tools", allowed_builtin_tools, "--allowedTools", allowed_tools, "--mcp-config", mcp_config_abs, "--strict-mcp-config" };
    const fixed = locked[0..1].* ++ user_settings_off ++ locked[1..].*;
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

pub fn alwaysLoadConfig(gpa: Allocator, mcp_config: []const u8) !?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, mcp_config, .{}) catch return error.McpConfigInvalid;
    defer parsed.deinit();
    if (parsed.value != .object) return error.McpConfigInvalid;
    const servers = parsed.value.object.getPtr("mcpServers") orelse return error.NoEmetgateServer;
    if (servers.* != .object) return error.McpConfigInvalid;
    var changed = false;
    var entries = servers.object.iterator();
    while (entries.next()) |entry| {
        if (!isEmetgateServer(entry.value_ptr.*)) continue;
        if (entry.value_ptr.object.get(always_load_field)) |present| {
            if (present == .bool and present.bool) continue;
        }
        try entry.value_ptr.object.put(parsed.arena.allocator(), always_load_field, .{ .bool = true });
        changed = true;
    }
    if (!changed) return null;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.json.Stringify.value(parsed.value, .{}, &out.writer);
    return try out.toOwnedSlice();
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

pub fn ownMcpConfigJson(gpa: Allocator, exe_abs: []const u8, test_command: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer };
    try js.beginObject();
    try js.objectField("mcpServers");
    try js.beginObject();
    try js.objectField(own_server_name);
    try js.beginObject();
    try js.objectField("command");
    try js.write(exe_abs);
    try js.objectField("args");
    try js.beginArray();
    for (own_server_args) |arg| try js.write(arg);
    if (test_command) |command| {
        try js.write(test_flag);
        try js.write(command);
    } else try js.write(detect_flag);
    try js.endArray();
    try js.objectField(always_load_field);
    try js.write(true);
    try js.endObject();
    try js.endObject();
    try js.endObject();
    return out.toOwnedSlice();
}

pub const TestChoice = struct {
    command: ?[]const u8,
    rest: []const []const u8,
};

pub fn chooseTest(args: []const []const u8) !TestChoice {
    if (args.len == 0) return .{ .command = null, .rest = args };
    const first = args[0];
    if (std.mem.eql(u8, first, test_flag)) {
        if (args.len < 2 or std.mem.trim(u8, args[1], " \t").len == 0) return error.LockdownTestCommandMissing;
        return .{ .command = args[1], .rest = args[2..] };
    }
    if (std.mem.startsWith(u8, first, test_flag ++ "=")) {
        const command = first[test_flag.len + 1 ..];
        if (std.mem.trim(u8, command, " \t").len == 0) return error.LockdownTestCommandMissing;
        return .{ .command = command, .rest = args[1..] };
    }
    return .{ .command = null, .rest = args };
}

pub fn chooseMcpConfig(gpa: Allocator, io: std.Io, dir: std.Io.Dir, state_dir: []const u8, exe_abs: []const u8, given_test: ?[]const u8) ![:0]u8 {
    const found = resolveMcpConfig(gpa, io, dir) catch |err| switch (err) {
        error.McpConfigMissing => {
            const own = try std.fs.path.joinZ(gpa, &.{ state_dir, own_mcp_config_name });
            errdefer gpa.free(own);
            const json = try ownMcpConfigJson(gpa, exe_abs, given_test);
            defer gpa.free(json);
            try lockdown_slash.place(gpa, io, own, json);
            return own;
        },
        else => return err,
    };
    if (given_test != null) {
        gpa.free(found);
        return error.LockdownTestWithMcpConfig;
    }
    defer gpa.free(found);
    const config = try std.Io.Dir.cwd().readFileAlloc(io, found, gpa, .limited(max_mcp_config_bytes));
    defer gpa.free(config);
    const loaded = alwaysLoadConfig(gpa, config) catch return gpa.dupeZ(u8, found);
    const json = loaded orelse return gpa.dupeZ(u8, found);
    defer gpa.free(json);
    const copy = try std.fs.path.joinZ(gpa, &.{ state_dir, project_mcp_config_name });
    errdefer gpa.free(copy);
    try lockdown_slash.place(gpa, io, copy, json);
    return copy;
}

pub fn childEnviron(gpa: Allocator, parent: *const std.process.Environ.Map) !std.process.Environ.Map {
    var env = try parent.clone(gpa);
    errdefer env.deinit();
    try env.put(tool_search_variable, tool_search_value);
    return env;
}

pub const git_init_notice = "emetgate lockdown: the directory was not a git repository, ran git init\n";

fn gitSucceeds(gpa: Allocator, io: std.Io, git: []const u8, dir_abs: []const u8, env: *const std.process.Environ.Map, args: []const []const u8) !bool {
    var argv: [4][]const u8 = undefined;
    argv[0] = git;
    @memcpy(argv[1..][0..args.len], args);
    const result = std.process.run(gpa, io, .{
        .argv = argv[0 .. args.len + 1],
        .cwd = .{ .path = dir_abs },
        .environ_map = env,
    }) catch return error.GitFailed;
    gpa.free(result.stdout);
    gpa.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

pub fn ensureRepo(gpa: Allocator, io: std.Io, dir_abs: []const u8, env: *const std.process.Environ.Map) !bool {
    const git = try exe_path.git(gpa, dir_abs);
    defer gpa.free(git);
    if (try gitSucceeds(gpa, io, git, dir_abs, env, &.{ "rev-parse", "--show-toplevel" })) return false;
    if (!try gitSucceeds(gpa, io, git, dir_abs, env, &.{ "init", "-q" })) return error.GitInitFailed;
    return true;
}

fn ensureRepoAt(gpa: Allocator, io: std.Io, dir: std.Io.Dir, env: *const std.process.Environ.Map) !void {
    const dir_abs = try dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir_abs);
    if (!try ensureRepo(gpa, io, dir_abs, env)) return;
    std.Io.File.stderr().writeStreamingAll(io, git_init_notice) catch {};
}

pub fn launch(gpa: Allocator, io: std.Io, parent_env: *const std.process.Environ.Map, passthrough: []const []const u8) !u8 {
    const self_exe = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(self_exe);
    return launchIn(gpa, io, std.Io.Dir.cwd(), parent_env, claude_program, self_exe, passthrough);
}

pub fn launchIn(gpa: Allocator, io: std.Io, dir: std.Io.Dir, parent_env: *const std.process.Environ.Map, program: []const u8, self_exe: []const u8, args: []const []const u8) !u8 {
    const tests = try chooseTest(args);
    const marks = lockdown_marks.choose(tests.rest);
    const passthrough = marks.rest;
    try refuseReserved(passthrough);
    const local_app_data = parent_env.get(lockdown_slash.local_app_data_variable) orelse return error.LocalAppDataUnavailable;
    try ensureRepoAt(gpa, io, dir, parent_env);
    const slash = try lockdown_slash.install(gpa, io, local_app_data, self_exe);
    defer slash.deinit(gpa);
    const config_abs = try chooseMcpConfig(gpa, io, dir, slash.dir, self_exe, tests.command);
    defer gpa.free(config_abs);
    const config = try std.Io.Dir.cwd().readFileAlloc(io, config_abs, gpa, .limited(max_mcp_config_bytes));
    defer gpa.free(config);
    const server = try emetgateServer(gpa, config);
    defer gpa.free(server);
    const allowed = try allowedTools(gpa, server);
    defer gpa.free(allowed);
    const locked = try buildArgv(gpa, config_abs, allowed, passthrough);
    defer gpa.free(locked);
    const hooked = try lockdown_slash.extend(gpa, locked, slash);
    defer gpa.free(hooked);
    const marks_dir: ?[]u8 = if (marks.wanted) try lockdown_marks.install(gpa, io, slash.dir) else null;
    defer if (marks_dir) |owned| gpa.free(owned);
    const argv = if (marks_dir) |plugin| try lockdown_marks.extend(gpa, hooked, passthrough.len, plugin) else try gpa.dupe([]const u8, hooked);
    defer gpa.free(argv);
    const resolved = exe_path.resolve(gpa, program, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ExecutableNotFound, error.NameInvalid => return error.ClaudeNotFound,
    };
    defer gpa.free(resolved);
    argv[0] = resolved;
    var env = try childEnviron(gpa, parent_env);
    defer env.deinit();
    var child = try std.process.spawn(io, .{ .argv = argv, .environ_map = &env });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| code,
        else => error.ClaudeTerminated,
    };
}
