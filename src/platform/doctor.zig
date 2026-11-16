const std = @import("std");
const bounded_run = @import("bounded_run.zig");
const builtin = @import("builtin");
const exe_path = @import("exe_path.zig");
const repo = @import("repo.zig");
const lockdown = @import("lockdown.zig");
const lockdown_slash = @import("lockdown_slash.zig");
const test_command = @import("test_command.zig");
const runner = @import("runner.zig");
const appcontainer = @import("appcontainer.zig");
pub const install_probe = @import("install_probe.zig");

const Allocator = std.mem.Allocator;

pub const Status = enum { ok, warn, fail };

pub const Check = struct {
    name: []const u8,
    status: Status,
    detail: []const u8,
    fix: []const u8 = "",
};

pub const claude_install = "irm https://claude.ai/install.ps1 | iex";
pub const claude_login = "claude auth login";
pub const git_install = "winget install --id Git.Git -e";
pub const utf8_console = "chcp 65001";
pub const utf8_code_page: u32 = 65001;

pub const Probe = struct {
    cwd: []const u8,
    claude: []const u8 = lockdown.claude_program,
    self_exe: []const u8,
    local_app_data: ?[]const u8,
    version: []const u8,
    code_page: u32 = 0,
    env: ?*const std.process.Environ.Map = null,
    release: Release = .{},
    scan_processes: bool = false,
    json: bool = false,
};

pub const Release = struct {
    release_build: bool = true,
    disabled: bool = false,
    latest: ?[]const u8 = null,
    newer: bool = false,
    checked_ago_s: ?i64 = null,
    offline: ?anyerror = null,
    updated_to: ?[]const u8 = null,
};

pub fn statusWord(status: Status) []const u8 {
    return switch (status) {
        .ok => "ok  ",
        .warn => "warn",
        .fail => "FAIL",
    };
}

pub fn writeLine(w: *std.Io.Writer, check: Check) !void {
    try w.print("{s}  {s:<9} {s}", .{ statusWord(check.status), check.name, check.detail });
    if (check.fix.len != 0) try w.print("  -> fix: {s}", .{check.fix});
    try w.writeByte('\n');
}

pub fn exitCode(checks: []const Check) u8 {
    for (checks) |check| if (check.status == .fail) return 1;
    return 0;
}

pub fn claudeVersion(stdout: []const u8) ?[]const u8 {
    const first = std.mem.sliceTo(stdout, '\n');
    const line = std.mem.trim(u8, first, " \r\t");
    if (line.len == 0 or !std.ascii.isDigit(line[0])) return null;
    return line;
}

pub fn loggedIn(gpa: Allocator, stdout: []const u8) ?bool {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, stdout, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const value = parsed.value.object.get("loggedIn") orelse return null;
    if (value != .bool) return null;
    return value.bool;
}

pub const ServerTest = struct {
    given: []const u8 = "",
    names_test: bool = false,
    allow_repo_config: bool = false,
    command: []const u8 = "",
    args: []const []const u8 = &.{},

    pub fn deinit(self: ServerTest, gpa: Allocator) void {
        gpa.free(self.given);
        gpa.free(self.command);
        for (self.args) |arg| gpa.free(arg);
        gpa.free(self.args);
    }
};

pub fn serverTest(gpa: Allocator, mcp_config: []const u8) !ServerTest {
    const name = try lockdown.emetgateServer(gpa, mcp_config);
    defer gpa.free(name);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, mcp_config, .{}) catch return error.McpConfigInvalid;
    defer parsed.deinit();
    var entries = parsed.value.object.get("mcpServers").?.object.iterator();
    while (entries.next()) |entry| {
        const part = try lockdown.toolNamePart(gpa, entry.key_ptr.*);
        defer gpa.free(part);
        if (!std.mem.eql(u8, part, name)) continue;
        const args = (entry.value_ptr.object.get("args") orelse return .{}).array.items;
        var found: ServerTest = .{};
        if (entry.value_ptr.object.get("command")) |command| {
            if (command == .string) found.command = try gpa.dupe(u8, command.string);
        }
        var given_args: std.ArrayList([]const u8) = .empty;
        for (args) |arg| if (arg == .string) try given_args.append(gpa, try gpa.dupe(u8, arg.string));
        found.args = try given_args.toOwnedSlice(gpa);
        for (args, 0..) |arg, i| {
            if (arg != .string) continue;
            if (std.mem.eql(u8, arg.string, "--allow-repo-config")) found.allow_repo_config = true;
            if (!std.mem.eql(u8, arg.string, "--test")) continue;
            found.names_test = true;
            if (i + 1 < args.len and args[i + 1] == .string) {
                found.given = try gpa.dupe(u8, args[i + 1].string);
            }
        }
        return found;
    }
    return .{};
}

const name_test_command = "claude mcp add --scope project emetgate -- emetgate mcp --test \"npm test\"";

pub fn testFailure(err: anyerror) Check {
    return switch (err) {
        error.NoTestCommand => .{ .name = "tests", .status = .fail, .detail = "no test command: lockdown starts, but every write is refused with NoTestCommand", .fix = name_test_command },
        error.UntrustedRepoConfig => .{ .name = "tests", .status = .fail, .detail = ".emetgaterc.json names the test command, but the server is not started with --allow-repo-config", .fix = "claude mcp add --scope project emetgate -- emetgate mcp --allow-repo-config" },
        error.InvalidConfig => .{ .name = "tests", .status = .fail, .detail = ".emetgaterc.json is not valid JSON", .fix = "repair .emetgaterc.json, e.g. {\"test_cmd\": \"npm test\"}" },
        else => .{ .name = "tests", .status = .fail, .detail = @errorName(err) },
    };
}

pub fn noTestsFound() Check {
    return .{ .name = "tests", .status = .warn, .detail = "none found: writes land without a test run, marked unverified_no_tests", .fix = name_test_command };
}

pub fn mcpConfigFailure(err: anyerror) Check {
    return .{ .name = ".mcp.json", .status = .fail, .detail = @errorName(err), .fix = hint(err) orelse "" };
}

pub fn codePageCheck(code_page: u32) Check {
    if (code_page == 0 or code_page == utf8_code_page) return .{ .name = "console", .status = .ok, .detail = "UTF-8 output" };
    return .{ .name = "console", .status = .warn, .detail = "code page is not UTF-8: non-ASCII paths print garbled", .fix = utf8_console };
}

pub fn hint(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.ClaudeNotFound => "claude (Claude Code) is not on PATH; install it with: " ++ claude_install ++ "  then open a new terminal",
        error.ClaudeOnlyUnderWorkingDir => "claude is on PATH only in a folder inside the current folder (npm puts it in %APPDATA%\npm, inside your home), and lockdown runs no program from there so a planted claude cannot start; cd into a project folder and run lockdown again",
        error.LockdownInitRefused => "this folder is not a git repository, and lockdown runs git init only in a project folder, not in a drive root, your home or a folder holding it, or a folder that holds user profiles or other repositories; cd into a project folder (or run git init there yourself) and run lockdown again",
        error.ClaudeTerminated => "claude exited abnormally; run `claude` alone to see why, then `emetgate doctor`",
        error.GitNotFound => "git is not on PATH; install it with: " ++ git_install ++ "  then open a new terminal",
        error.NotInRepo => "this folder is not inside a git repository; cd into your project or run: git init",
        error.GitFailed => "git could not run here; run: git rev-parse --show-toplevel  to see why",
        error.LocalAppDataUnavailable => "LOCALAPPDATA is not set; run: $env:LOCALAPPDATA = \"$env:USERPROFILE\\AppData\\Local\"",
        error.McpConfigInvalid => ".mcp.json in this folder is not valid JSON; fix it or delete it so lockdown uses its own config",
        error.NoEmetgateServer => ".mcp.json has no emetgate server; run: claude mcp add --scope project emetgate -- emetgate mcp --test \"npm test\"",
        error.SeveralEmetgateServers => ".mcp.json has more than one emetgate server; keep one: claude mcp remove <name> --scope project",
        error.LockdownFlagOverride => "a claude flag you passed would undo the lock (--tools, --mcp-config, --settings, --dangerously-skip-permissions...); drop it",
        error.LockdownProjectSetting => ".claude\\settings.json sets agent, which would run claude as that subagent with its own tools, hooks and MCP servers outside the lock; remove the field",
        error.LockdownProjectSettingsTooLarge => ".claude\\settings.json is larger than 2 MiB, so lockdown cannot check it for fields that undo the lock; shrink it",
        error.NoTestCommand => "no test command; pass --test \"npm test\" or put {\"test_cmd\": \"npm test\"} in .emetgaterc.json and add --allow-repo-config",
        error.UntrustedRepoConfig => ".emetgaterc.json came with the repo; trust it with --allow-repo-config or pass --test \"<command>\"",
        error.InvalidConfig => ".emetgaterc.json is not valid JSON; e.g. {\"test_cmd\": \"npm test\"}",
        error.SandboxUnavailable => "the Windows sandbox could not start a low-integrity process; run: emetgate doctor",
        error.LabelDenied => "a sandbox folder is owned by another account (e.g. Administrators after an elevated run) and this account may not relabel it; delete it from the account that created it, or pass --shadow-root <a folder you own>",
        error.AccessDenied, error.PermissionDenied => "access denied; run from a folder you own (not Program Files or a protected folder), then: emetgate doctor",
        error.FileOutsideRepo => "the path is outside the git repository; cd into the repository first",
        else => null,
    };
}

pub fn printError(err: anyerror) void {
    if (hint(err)) |text| {
        std.debug.print("error: {t}: {s}\n", .{ err, text });
    } else {
        std.debug.print("error: {t}\n", .{err});
    }
}

pub fn run(gpa: Allocator, io: std.Io, probe: Probe, out: *std.Io.Writer) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var checks: std.ArrayList(Check) = .empty;

    try checks.append(arena, .{ .name = "emetgate", .status = .ok, .detail = try std.fmt.allocPrint(arena, "{s} at {s}", .{ probe.version, probe.self_exe }) });
    try checks.append(arena, try pathLine(arena, io, probe));
    try checks.append(arena, try releaseCheck(arena, probe.version, probe.release));
    if (probe.scan_processes) try checks.append(arena, processLine(arena));
    try appendClaude(arena, io, probe, &checks);
    const config = if (probe.env) |env| try claudeConfig(arena, env) else null;
    if (probe.env != null) try checks.append(arena, try configCheck(arena, io, config));
    const root = try appendRepo(arena, io, probe, &checks);
    try checks.append(arena, try mcpAndTests(arena, io, probe, root, &checks));
    if (config) |found| try appendRegistrations(arena, io, probe, found, root, &checks);
    try checks.append(arena, writeCheck(arena, io, "write", root orelse probe.cwd));
    try checks.append(arena, stateCheck(arena, io, probe));
    if (probe.local_app_data) |local| try checks.append(arena, try dataCheck(arena, io, local));
    try checks.append(arena, sandboxCheck(arena, io, root orelse probe.cwd));
    try checks.append(arena, appContainerCheck());
    try checks.append(arena, codePageCheck(probe.code_page));

    const code = exitCode(checks.items);
    if (probe.json) {
        try writeJson(out, probe, checks.items, code == 0);
        return code;
    }
    for (checks.items) |check| try writeLine(out, check);
    if (code == 0) {
        try out.writeAll("ready: run `emetgate lockdown` here\n");
    } else {
        try out.writeAll("not ready: fix each FAIL line above, then run `emetgate doctor` again\n");
    }
    return code;
}

const JsonCheck = struct { name: []const u8, status: []const u8, detail: []const u8, fix: []const u8 };

pub fn writeJson(out: *std.Io.Writer, probe: Probe, checks: []const Check, ready: bool) !void {
    var buf: [64]JsonCheck = undefined;
    const count = @min(checks.len, buf.len);
    for (checks[0..count], buf[0..count]) |check, *item| {
        item.* = .{ .name = check.name, .status = @tagName(check.status), .detail = check.detail, .fix = check.fix };
    }
    try std.json.Stringify.value(.{ .version = probe.version, .exe = probe.self_exe, .cwd = probe.cwd, .ready = ready, .checks = buf[0..count] }, .{ .whitespace = .indent_2 }, out);
    try out.writeByte('\n');
}

pub fn onPath(arena: Allocator, io: std.Io, path_list: []const u8, pathext: []const u8, name: []const u8) ![]const []const u8 {
    var hits: std.ArrayList([]const u8) = .empty;
    var entries = std.mem.tokenizeScalar(u8, path_list, ';');
    while (entries.next()) |raw| {
        const dir = std.mem.trimEnd(u8, std.mem.trim(u8, raw, " \""), "\\/");
        if (dir.len == 0) continue;
        var extensions = std.mem.tokenizeScalar(u8, pathext, ';');
        while (extensions.next()) |ext_raw| {
            const ext = std.mem.trim(u8, ext_raw, " ");
            if (ext.len < 2 or ext[0] != '.') continue;
            const candidate = try std.fmt.allocPrint(arena, "{s}\\{s}{s}", .{ dir, name, try std.ascii.allocLowerString(arena, ext) });
            std.Io.Dir.cwd().access(io, candidate, .{}) catch continue;
            for (hits.items) |seen| {
                if (std.ascii.eqlIgnoreCase(seen, candidate)) break;
            } else try hits.append(arena, candidate);
        }
    }
    return hits.toOwnedSlice(arena);
}

pub fn samePath(a: []const u8, b: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(a, b)) return true;
    var a_buf: [std.os.windows.PATH_MAX_WIDE]u16 = undefined;
    var b_buf: [std.os.windows.PATH_MAX_WIDE]u16 = undefined;
    const a_final = exe_path.finalName(&a_buf, a) orelse return false;
    const b_final = exe_path.finalName(&b_buf, b) orelse return false;
    return std.mem.eql(u16, a_final, b_final);
}

fn pathLine(arena: Allocator, io: std.Io, probe: Probe) !Check {
    const hits: []const []const u8 = if (probe.env) |env|
        try onPath(arena, io, env.get("PATH") orelse "", env.get("PATHEXT") orelse ".COM;.EXE;.BAT;.CMD", "emetgate")
    else if (exe_path.resolve(arena, "emetgate", null)) |found|
        try arena.dupe([]const u8, &.{found})
    else |_|
        &.{};
    var first_version: ?[]const u8 = null;
    if (hits.len != 0 and !samePath(hits[0], probe.self_exe)) {
        if (capture(arena, io, &.{ hits[0], "--version" }, probe.cwd)) |text| {
            const line = std.mem.trim(u8, std.mem.sliceTo(text, '\n'), " \r\t");
            if (std.mem.startsWith(u8, line, "emetgate ")) first_version = line["emetgate ".len..];
        }
    }
    return pathCheck(arena, probe.self_exe, hits, first_version);
}

pub fn pathCheck(arena: Allocator, self_exe: []const u8, hits: []const []const u8, first_version: ?[]const u8) !Check {
    if (hits.len == 0) {
        const dir = std.fs.path.dirname(self_exe) orelse self_exe;
        return .{ .name = "path", .status = .warn, .detail = "emetgate is not on PATH, so a new terminal and `claude mcp add ... emetgate` cannot find it", .fix = try std.fmt.allocPrint(arena, "[Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path','User') + ';{s}', 'User')  then open a new terminal", .{dir}) };
    }
    var others: std.Io.Writer.Allocating = .init(arena);
    for (hits[1..], 0..) |hit, i| {
        if (i != 0) try others.writer.writeAll("; ");
        try others.writer.writeAll(hit);
    }
    if (!samePath(hits[0], self_exe)) {
        const version = if (first_version) |v| try std.fmt.allocPrint(arena, " (emetgate {s})", .{v}) else "";
        const also = if (hits.len > 1) try std.fmt.allocPrint(arena, "; also on PATH: {s}", .{others.written()}) else "";
        return .{ .name = "path", .status = .warn, .detail = try std.fmt.allocPrint(arena, "`emetgate` runs {s}{s}, not this {s}{s}", .{ hits[0], version, self_exe, also }), .fix = try std.fmt.allocPrint(arena, "delete {s} or remove {s} from PATH, then open a new terminal", .{ hits[0], std.fs.path.dirname(hits[0]) orelse hits[0] }) };
    }
    if (hits.len > 1) {
        return .{ .name = "path", .status = .warn, .detail = try std.fmt.allocPrint(arena, "{d} copies on PATH; {s} runs, the others are shadowed: {s}", .{ hits.len, hits[0], others.written() }), .fix = "delete the shadowed copies (or remove their folders from PATH) so no session or config starts an old one" };
    }
    return .{ .name = "path", .status = .ok, .detail = "`emetgate` runs this exe, the only copy on PATH" };
}

fn ago(arena: Allocator, seconds: ?i64) ![]const u8 {
    const s = seconds orelse return "time unknown";
    if (s < 3600) return "under an hour ago";
    if (s < 2 * 86400) return std.fmt.allocPrint(arena, "{d} h ago", .{@divTrunc(s, 3600)});
    return std.fmt.allocPrint(arena, "{d} days ago", .{@divTrunc(s, 86400)});
}

pub fn releaseCheck(arena: Allocator, version: []const u8, release: Release) !Check {
    if (release.updated_to) |next| return .{ .name = "release", .status = .warn, .detail = try std.fmt.allocPrint(arena, "this exe was just replaced by emetgate {s}; this run is still {s}", .{ next, version }), .fix = "run emetgate doctor again" };
    if (!release.release_build) return .{ .name = "release", .status = .ok, .detail = try std.fmt.allocPrint(arena, "{s} is not a release version; nothing to compare", .{version}) };
    if (release.latest) |latest| {
        const when = try ago(arena, release.checked_ago_s);
        if (release.newer) return .{ .name = "release", .status = .warn, .detail = try std.fmt.allocPrint(arena, "emetgate {s} is out, this is {s} (checked {s})", .{ latest, version, when }), .fix = "emetgate update" };
        return .{ .name = "release", .status = .ok, .detail = try std.fmt.allocPrint(arena, "{s} is the latest release (checked {s})", .{ version, when }) };
    }
    if (release.offline) |err| return .{ .name = "release", .status = .warn, .detail = try std.fmt.allocPrint(arena, "skipped: GitHub could not be reached ({t})", .{err}), .fix = "emetgate update, when online" };
    if (release.disabled) return .{ .name = "release", .status = .warn, .detail = "not checked: the automatic check is off (EMETGATE_NO_UPDATE, CI, or a debug build)", .fix = "emetgate update" };
    return .{ .name = "release", .status = .warn, .detail = "not checked yet", .fix = "emetgate update" };
}

fn processLine(arena: Allocator) Check {
    const found = install_probe.emetgateProcesses(arena) catch |err| return .{ .name = "running", .status = .warn, .detail = std.fmt.allocPrint(arena, "could not list processes ({t})", .{err}) catch "could not list processes" };
    return processCheck(arena, found) catch .{ .name = "running", .status = .warn, .detail = "out of memory" };
}

pub fn processCheck(arena: Allocator, found: []const install_probe.Process) !Check {
    if (found.len == 0) return .{ .name = "running", .status = .ok, .detail = "no other emetgate process" };
    var detail: std.Io.Writer.Allocating = .init(arena);
    try detail.writer.print("{d} other emetgate process{s}: ", .{ found.len, if (found.len == 1) "" else "es" });
    for (found, 0..) |process, i| {
        if (i != 0) try detail.writer.writeAll("; ");
        const shown = if (process.command_line.len != 0) process.command_line else process.image;
        try detail.writer.print("pid {d} {s}", .{ process.pid, shown[0..@min(shown.len, 160)] });
    }
    return .{ .name = "running", .status = .warn, .detail = detail.written(), .fix = "they hold emetgate.exe open, so update and uninstall wait; close the claude sessions that started them (doctor stops nothing)" };
}

pub const ClaudeConfig = struct {
    dir: []const u8,
    json: []const u8,
    from_env: bool,
    default_json: ?[]const u8 = null,
};

pub const claude_config_variable = "CLAUDE_CONFIG_DIR";

pub fn claudeConfig(arena: Allocator, env: *const std.process.Environ.Map) !?ClaudeConfig {
    const home = env.get("USERPROFILE");
    const default_json = if (home) |h| try std.fs.path.join(arena, &.{ h, ".claude.json" }) else null;
    if (env.get(claude_config_variable)) |raw| {
        const dir = std.mem.trimEnd(u8, std.mem.trim(u8, raw, " \""), "\\/");
        if (dir.len != 0) return .{ .dir = dir, .json = try std.fs.path.join(arena, &.{ dir, ".claude.json" }), .from_env = true, .default_json = default_json };
    }
    const h = home orelse return null;
    return .{ .dir = try std.fs.path.join(arena, &.{ h, ".claude" }), .json = default_json.?, .from_env = false };
}

pub fn configCheck(arena: Allocator, io: std.Io, config: ?ClaudeConfig) !Check {
    const found = config orelse return .{ .name = "config", .status = .warn, .detail = "neither CLAUDE_CONFIG_DIR nor USERPROFILE is set, so claude's config folder is unknown", .fix = "open a normal terminal for your Windows user" };
    if (!found.from_env) return .{ .name = "config", .status = .ok, .detail = try std.fmt.allocPrint(arena, "claude uses {s} (default, CLAUDE_CONFIG_DIR not set); user and local MCP servers live in {s}", .{ found.dir, found.json }) };
    std.Io.Dir.cwd().access(io, found.dir, .{}) catch return .{ .name = "config", .status = .warn, .detail = try std.fmt.allocPrint(arena, "CLAUDE_CONFIG_DIR is {s}, which does not exist; claude starts there with no settings or MCP servers", .{found.dir}), .fix = "fix or unset CLAUDE_CONFIG_DIR, so every terminal uses the same config folder" };
    return .{ .name = "config", .status = .ok, .detail = try std.fmt.allocPrint(arena, "claude uses {s} (CLAUDE_CONFIG_DIR); user and local MCP servers live in {s}; a terminal without the variable reads {s} instead", .{ found.dir, found.json, found.default_json orelse "%USERPROFILE%\\.claude.json" }) };
}

pub const Registration = struct { scope: []const u8, name: []const u8, command: []const u8 };

pub const max_claude_json_bytes = 64 * 1024 * 1024;

pub fn sameProject(key: []const u8, dir: []const u8) bool {
    const a = std.mem.trimEnd(u8, key, "\\/");
    const b = std.mem.trimEnd(u8, dir, "\\/");
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const xs = if (x == '\\') '/' else x;
        const ys = if (y == '\\') '/' else y;
        if (std.ascii.toLower(xs) != std.ascii.toLower(ys)) return false;
    }
    return true;
}

pub fn registrations(arena: Allocator, config_text: []const u8, projects: []const []const u8) ![]const Registration {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, config_text, .{}) catch return error.McpConfigInvalid;
    if (parsed != .object) return error.McpConfigInvalid;
    var found: std.ArrayList(Registration) = .empty;
    if (parsed.object.get("mcpServers")) |servers| try collectServers(arena, "user", servers, &found);
    if (parsed.object.get("projects")) |all| {
        if (all == .object) {
            var entries = all.object.iterator();
            while (entries.next()) |entry| {
                for (projects) |project| {
                    if (!sameProject(entry.key_ptr.*, project)) continue;
                    if (entry.value_ptr.* != .object) break;
                    if (entry.value_ptr.object.get("mcpServers")) |servers| try collectServers(arena, "local", servers, &found);
                    break;
                }
            }
        }
    }
    return found.toOwnedSlice(arena);
}

fn collectServers(arena: Allocator, scope: []const u8, servers: std.json.Value, found: *std.ArrayList(Registration)) !void {
    if (servers != .object) return;
    var entries = servers.object.iterator();
    while (entries.next()) |entry| {
        if (!lockdown.isEmetgateServer(entry.value_ptr.*)) continue;
        try found.append(arena, .{ .scope = scope, .name = entry.key_ptr.*, .command = entry.value_ptr.object.get("command").?.string });
    }
}

fn readRegistrations(arena: Allocator, io: std.Io, path: []const u8, projects: []const []const u8) !?[]const Registration {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_claude_json_bytes)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return try registrations(arena, text, projects);
}

fn appendRegistrations(arena: Allocator, io: std.Io, probe: Probe, config: ClaudeConfig, root: ?[]const u8, checks: *std.ArrayList(Check)) !void {
    const projects: []const []const u8 = if (root) |r| &.{ probe.cwd, r } else &.{probe.cwd};
    const found = readRegistrations(arena, io, config.json, projects) catch |err| {
        try checks.append(arena, .{ .name = "mcp", .status = .warn, .detail = try std.fmt.allocPrint(arena, "could not read {s} ({t})", .{ config.json, err }), .fix = "repair the JSON, or run claude once so it rewrites the file" });
        return;
    };
    const elsewhere: ?[]const Registration = if (config.default_json) |other| readRegistrations(arena, io, other, projects) catch null else null;
    try checks.appendSlice(arena, try registrationChecks(arena, io, probe.self_exe, config, found orelse &.{}, elsewhere orelse &.{}));
}

pub fn registrationChecks(arena: Allocator, io: std.Io, self_exe: []const u8, config: ClaudeConfig, found: []const Registration, elsewhere: []const Registration) ![]const Check {
    var lines: std.ArrayList(Check) = .empty;
    for (found) |reg| {
        const name = if (std.mem.eql(u8, reg.scope, "user")) "mcp user" else "mcp local";
        const fix = try std.fmt.allocPrint(arena, "claude mcp remove {s} -s {s}  then  claude mcp add -s {s} {s} -- \"{s}\" mcp", .{ reg.name, reg.scope, reg.scope, reg.name, self_exe });
        const located = locateServer(arena, io, reg.command) orelse {
            try lines.append(arena, .{ .name = name, .status = .warn, .detail = try std.fmt.allocPrint(arena, "{s} -> {s}, which is not there; claude sessions get no emetgate tools from it", .{ reg.name, reg.command }), .fix = fix });
            continue;
        };
        if (!samePath(located, self_exe)) {
            try lines.append(arena, .{ .name = name, .status = .warn, .detail = try std.fmt.allocPrint(arena, "{s} -> {s}, not this {s}", .{ reg.name, located, self_exe }), .fix = fix });
            continue;
        }
        try lines.append(arena, .{ .name = name, .status = .ok, .detail = try std.fmt.allocPrint(arena, "{s} -> {s}", .{ reg.name, located }) });
    }
    if (found.len != 0) return lines.toOwnedSlice(arena);
    if (config.from_env and elsewhere.len != 0) {
        try lines.append(arena, .{ .name = "mcp", .status = .warn, .detail = try std.fmt.allocPrint(arena, "emetgate is registered in {s}, but CLAUDE_CONFIG_DIR makes claude read {s}, where it is not", .{ config.default_json.?, config.json }), .fix = try std.fmt.allocPrint(arena, "in a terminal with CLAUDE_CONFIG_DIR set: claude mcp add -s user emetgate -- \"{s}\" mcp", .{self_exe}) });
        return lines.toOwnedSlice(arena);
    }
    try lines.append(arena, .{ .name = "mcp", .status = .ok, .detail = try std.fmt.allocPrint(arena, "no user or local registration in {s}; lockdown brings its own server", .{config.json}) });
    return lines.toOwnedSlice(arena);
}

pub fn dataCheck(arena: Allocator, io: std.Io, local_app_data: []const u8) !Check {
    const dir = try std.fs.path.join(arena, &.{ local_app_data, "emetgate" });
    std.Io.Dir.cwd().access(io, dir, .{}) catch return .{ .name = "data", .status = .ok, .detail = try std.fmt.allocPrint(arena, "{s} (not created yet)", .{dir}) };
    const size = install_probe.treeSize(arena, dir) catch |err| return .{ .name = "data", .status = .warn, .detail = try std.fmt.allocPrint(arena, "{s}: could not measure ({t})", .{ dir, err }) };
    var text: std.Io.Writer.Allocating = .init(arena);
    try text.writer.print("{s}: ", .{dir});
    if (!size.complete) try text.writer.writeAll("over ");
    try install_probe.writeBytes(&text.writer, size.bytes);
    try text.writer.print(" in {d} files", .{size.files});
    return .{ .name = "data", .status = .ok, .detail = text.written() };
}

fn appendClaude(arena: Allocator, io: std.Io, probe: Probe, checks: *std.ArrayList(Check)) !void {
    const claude = exe_path.resolve(arena, probe.claude, null) catch {
        if (try exe_path.skipped(arena, probe.claude, null)) |planted| {
            try checks.append(arena, .{ .name = "claude", .status = .fail, .detail = try std.fmt.allocPrint(arena, "skipped {s}: its PATH folder lies inside the current folder, and lockdown runs no program from there", .{planted}), .fix = "cd into a project folder and run emetgate doctor again" });
            return;
        }
        try checks.append(arena, .{ .name = "claude", .status = .fail, .detail = "claude (Claude Code CLI) is not on PATH", .fix = claude_install });
        return;
    };
    const version = capture(arena, io, &.{ claude, "--version" }, probe.cwd);
    const shown = if (version) |text| claudeVersion(text) else null;
    if (shown) |v| {
        try checks.append(arena, .{ .name = "claude", .status = .ok, .detail = std.fmt.allocPrint(arena, "{s} at {s}", .{ v, claude }) catch v });
    } else {
        try checks.append(arena, .{ .name = "claude", .status = .fail, .detail = std.fmt.allocPrint(arena, "{s} --version gave no version", .{claude}) catch claude, .fix = claude_install });
        return;
    }
    const status = capture(arena, io, &.{ claude, "auth", "status" }, probe.cwd);
    try checks.append(arena, loginCheck(if (status) |text| loggedIn(arena, text) else null));
}

fn repoMissing(arena: Allocator, io: std.Io, probe: Probe, err: anyerror) Check {
    const plain: Check = .{ .name = "repo", .status = .fail, .detail = std.fmt.allocPrint(arena, "{s} is not inside a git repository ({t})", .{ probe.cwd, err }) catch "not in a repository", .fix = "cd into your project, or run: git init" };
    const env = probe.env orelse return plain;
    var dir = std.Io.Dir.openDirAbsolute(io, probe.cwd, .{}) catch return plain;
    defer dir.close(io);
    if (lockdown.initRefusal(io, dir, probe.cwd, env)) |why| {
        return .{ .name = "repo", .status = .fail, .detail = std.fmt.allocPrint(arena, "{s} is not a git repository and is {s}, so lockdown will not run git init here", .{ probe.cwd, why.text() }) catch plain.detail, .fix = "cd into your project folder" };
    }
    return .{ .name = "repo", .status = .warn, .detail = std.fmt.allocPrint(arena, "{s} is not a git repository yet; lockdown runs git init here first", .{probe.cwd}) catch plain.detail, .fix = "or run git init yourself, so doctor can check the tests too" };
}

pub fn loginCheck(state: ?bool) Check {
    const signed_in = state orelse return .{ .name = "login", .status = .warn, .detail = "could not read `claude auth status`", .fix = claude_login };
    if (signed_in) return .{ .name = "login", .status = .ok, .detail = "signed in" };
    return .{ .name = "login", .status = .fail, .detail = "claude is not signed in", .fix = claude_login };
}

fn appendRepo(arena: Allocator, io: std.Io, probe: Probe, checks: *std.ArrayList(Check)) !?[]const u8 {
    const git = exe_path.git(arena, probe.cwd) catch {
        try checks.append(arena, .{ .name = "git", .status = .fail, .detail = "git is not on PATH", .fix = git_install });
        return null;
    };
    try checks.append(arena, .{ .name = "git", .status = .ok, .detail = git });
    const root = repo.gitToplevel(arena, io, probe.cwd) catch |err| {
        try checks.append(arena, repoMissing(arena, io, probe, err));
        return null;
    };
    try checks.append(arena, .{ .name = "repo", .status = .ok, .detail = root });
    return root;
}

fn mcpAndTests(arena: Allocator, io: std.Io, probe: Probe, root: ?[]const u8, checks: *std.ArrayList(Check)) !Check {
    const config_path = try std.fs.path.join(arena, &.{ probe.cwd, lockdown.mcp_config_name });
    var server: ServerTest = .{};
    if (std.Io.Dir.cwd().readFileAlloc(io, config_path, arena, .limited(lockdown.max_mcp_config_bytes))) |config| {
        server = serverTest(arena, config) catch |err| {
            try checks.append(arena, mcpConfigFailure(err));
            return .{ .name = "tests", .status = .fail, .detail = "skipped: .mcp.json must be fixed first" };
        };
        try checks.append(arena, .{ .name = ".mcp.json", .status = .ok, .detail = "one emetgate server" });
        try checks.append(arena, serverStart(arena, io, probe, server));
    } else |err| switch (err) {
        error.FileNotFound => try checks.append(arena, .{ .name = ".mcp.json", .status = .ok, .detail = "none here; lockdown uses its own and finds the tests itself" }),
        else => {
            try checks.append(arena, mcpConfigFailure(err));
            return .{ .name = "tests", .status = .fail, .detail = "skipped: .mcp.json could not be read" };
        },
    }
    if (root == null) {
        const repo_warned = for (checks.items) |check| {
            if (std.mem.eql(u8, check.name, "repo")) break check.status == .warn;
        } else false;
        if (repo_warned) return .{ .name = "tests", .status = .warn, .detail = "skipped until the folder is a git repository" };
        return .{ .name = "tests", .status = .fail, .detail = "skipped: needs a git repository" };
    }
    const given = if (server.names_test) server.given else test_command.detect;
    const command = test_command.resolveTestCommand(arena, io, config_path, given, server.allow_repo_config) catch |err| return testFailure(err);
    if (test_command.takeUnverified()) return noTestsFound();
    const program = firstWord(command);
    _ = exe_path.resolve(arena, program, root) catch {
        return .{ .name = "tests", .status = .warn, .detail = std.fmt.allocPrint(arena, "\"{s}\": {s} is not on PATH", .{ command, program }) catch command, .fix = name_test_command };
    };
    return .{ .name = "tests", .status = .ok, .detail = std.fmt.allocPrint(arena, "\"{s}\"", .{command}) catch command };
}

pub const initialize_request = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"emetgate-doctor\",\"version\":\"0\"}}}\n";

pub const Started = union(enum) {
    missing,
    failed: anyerror,
    finished: struct { stdout: []const u8, stderr: []const u8 },
};

fn serverStart(arena: Allocator, io: std.Io, probe: Probe, server: ServerTest) Check {
    const program = locateServer(arena, io, server.command) orelse return serverCheck(arena, server.command, .missing, probe.version, probe.self_exe);
    const argv = arena.alloc([]const u8, server.args.len + 1) catch return serverCheck(arena, server.command, .{ .failed = error.OutOfMemory }, probe.version, probe.self_exe);
    argv[0] = program;
    @memcpy(argv[1..], server.args);
    const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .{ .nanoseconds = 20 * std.time.ns_per_s }, .clock = .awake } };
    const started: Started = if (bounded_run.runFed(arena, io, .{ .argv = argv, .cwd = .{ .path = probe.cwd }, .stdout_limit = .limited(256 * 1024), .stderr_limit = .limited(64 * 1024), .timeout = timeout }, initialize_request)) |result|
        .{ .finished = .{ .stdout = result.stdout, .stderr = result.stderr } }
    else |err|
        .{ .failed = err };
    return serverCheck(arena, server.command, started, probe.version, probe.self_exe);
}

fn locateServer(arena: Allocator, io: std.Io, command: []const u8) ?[]const u8 {
    if (command.len == 0) return null;
    if (std.mem.indexOfAny(u8, command, "\\/") != null) {
        std.Io.Dir.cwd().access(io, command, .{}) catch return null;
        return command;
    }
    return exe_path.resolve(arena, command, null) catch null;
}

pub fn serverAnswer(arena: Allocator, stdout: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch continue;
        if (parsed != .object) continue;
        const result = parsed.object.get("result") orelse continue;
        if (result != .object) continue;
        const info = result.object.get("serverInfo") orelse continue;
        if (info != .object) continue;
        const name = info.object.get("name") orelse continue;
        if (name != .string or !std.mem.eql(u8, name.string, "emetgate")) continue;
        const version = info.object.get("version") orelse return "";
        return if (version == .string) version.string else "";
    }
    return null;
}

fn firstLine(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \r\n\t");
    const end = std.mem.indexOfAny(u8, trimmed, "\r\n") orelse trimmed.len;
    return trimmed[0..@min(end, 160)];
}

pub fn serverCheck(arena: Allocator, command: []const u8, started: Started, version: []const u8, self_exe: []const u8) Check {
    const fix = std.fmt.allocPrint(arena, "set the emetgate server's \"command\" in .mcp.json to {s}", .{self_exe}) catch self_exe;
    switch (started) {
        .missing => return .{ .name = "server", .status = .fail, .detail = std.fmt.allocPrint(arena, "{s} is not there, so lockdown would start claude with no tools", .{command}) catch command, .fix = fix },
        .failed => |err| return .{ .name = "server", .status = .fail, .detail = std.fmt.allocPrint(arena, "{s} did not start ({t})", .{ command, err }) catch command, .fix = fix },
        .finished => |done| {
            const answered = serverAnswer(arena, done.stdout) orelse {
                const said = firstLine(done.stderr);
                const detail = if (said.len != 0)
                    std.fmt.allocPrint(arena, "{s} did not answer initialize: {s}", .{ command, said }) catch command
                else
                    std.fmt.allocPrint(arena, "{s} did not answer initialize", .{command}) catch command;
                return .{ .name = "server", .status = .fail, .detail = detail, .fix = "fix the arguments of the emetgate server in .mcp.json" };
            };
            if (!std.mem.eql(u8, answered, version)) {
                return .{ .name = "server", .status = .warn, .detail = std.fmt.allocPrint(arena, "{s} is emetgate {s}, this is {s}", .{ command, answered, version }) catch command, .fix = fix };
            }
            return .{ .name = "server", .status = .ok, .detail = std.fmt.allocPrint(arena, "answers as emetgate {s}", .{answered}) catch answered };
        },
    }
}

pub fn firstWord(command: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, command, " \t");
    if (trimmed.len != 0 and trimmed[0] == '"') {
        const end = std.mem.indexOfScalarPos(u8, trimmed, 1, '"') orelse trimmed.len;
        return trimmed[1..end];
    }
    const end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
    return trimmed[0..end];
}

fn writeCheck(arena: Allocator, io: std.Io, name: []const u8, dir: []const u8) Check {
    probeWrite(arena, io, dir) catch |err| {
        return .{ .name = name, .status = .fail, .detail = std.fmt.allocPrint(arena, "cannot write in {s} ({t})", .{ dir, err }) catch dir, .fix = "run from a folder you own; check Windows Security > Controlled folder access" };
    };
    return .{ .name = name, .status = .ok, .detail = dir };
}

pub fn probeWrite(gpa: Allocator, io: std.Io, dir: []const u8) !void {
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    const path = try std.fmt.allocPrint(gpa, "{s}\\.emetgate-doctor-{x}.tmp", .{ dir, &nonce });
    defer gpa.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "doctor", .flags = .{ .exclusive = true } });
    try std.Io.Dir.cwd().deleteFile(io, path);
}

fn stateCheck(arena: Allocator, io: std.Io, probe: Probe) Check {
    const local = probe.local_app_data orelse return .{ .name = "state", .status = .fail, .detail = "LOCALAPPDATA is not set", .fix = hint(error.LocalAppDataUnavailable).? };
    const dir = lockdown_slash.stateDir(arena, local, probe.self_exe) catch return .{ .name = "state", .status = .fail, .detail = "out of memory" };
    std.Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        return .{ .name = "state", .status = .fail, .detail = std.fmt.allocPrint(arena, "cannot create {s} ({t})", .{ dir, err }) catch dir, .fix = "check that your user can write %LOCALAPPDATA%" };
    };
    return writeCheck(arena, io, "state", dir);
}

fn sandboxCheck(arena: Allocator, io: std.Io, cwd: []const u8) Check {
    const report = runner.runCommand(arena, io, cwd, "exit 0", .{ .timeout_ms = 30_000 }) catch |err| {
        return .{ .name = "sandbox", .status = .fail, .detail = std.fmt.allocPrint(arena, "the low-integrity test sandbox did not start ({t})", .{err}) catch "did not start", .fix = "run emetgate from a normal (not elevated, not remote-restricted) terminal" };
    };
    if (!report.passed()) return .{ .name = "sandbox", .status = .fail, .detail = "cmd /c exit 0 did not pass inside the sandbox", .fix = "check that antivirus does not block low-integrity cmd.exe" };
    return .{ .name = "sandbox", .status = .ok, .detail = "low-integrity cmd.exe ran" };
}

fn appContainerCheck() Check {
    var profile = appcontainer.Profile.create(false) catch {
        return .{ .name = "appcntr", .status = .warn, .detail = "AppContainer profile could not be created (not used by lockdown today)" };
    };
    profile.deinit();
    return .{ .name = "appcntr", .status = .ok, .detail = "AppContainer profile available" };
}

fn capture(arena: Allocator, io: std.Io, argv: []const []const u8, cwd: []const u8) ?[]const u8 {
    const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .{ .nanoseconds = 20 * std.time.ns_per_s }, .clock = .awake } };
    const result = bounded_run.run(arena, io, .{ .argv = argv, .cwd = .{ .path = cwd }, .stdout_limit = .limited(64 * 1024), .stderr_limit = .limited(64 * 1024), .timeout = timeout }) catch return null;
    return switch (result.term) {
        .exited => result.stdout,
        else => null,
    };
}

pub fn consoleCodePage() u32 {
    if (builtin.os.tag != .windows) return 0;
    return GetConsoleOutputCP();
}

extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) u32;
