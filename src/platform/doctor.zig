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

    try checks.append(arena, selfCheck(arena, probe));
    try appendClaude(arena, io, probe, &checks);
    const root = try appendRepo(arena, io, probe, &checks);
    try checks.append(arena, try mcpAndTests(arena, io, probe, root, &checks));
    try checks.append(arena, writeCheck(arena, io, "write", root orelse probe.cwd));
    try checks.append(arena, stateCheck(arena, io, probe));
    try checks.append(arena, sandboxCheck(arena, io, root orelse probe.cwd));
    try checks.append(arena, appContainerCheck());
    try checks.append(arena, codePageCheck(probe.code_page));

    for (checks.items) |check| try writeLine(out, check);
    const code = exitCode(checks.items);
    if (code == 0) {
        try out.writeAll("ready: run `emetgate lockdown` here\n");
    } else {
        try out.writeAll("not ready: fix each FAIL line above, then run `emetgate doctor` again\n");
    }
    return code;
}

fn selfCheck(arena: Allocator, probe: Probe) Check {
    const detail = std.fmt.allocPrint(arena, "{s} at {s}", .{ probe.version, probe.self_exe }) catch probe.version;
    const found = exe_path.resolve(arena, "emetgate", null) catch {
        const dir = std.fs.path.dirname(probe.self_exe) orelse probe.self_exe;
        const fix = std.fmt.allocPrint(arena, "[Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path','User') + ';{s}', 'User')  then open a new terminal", .{dir}) catch "";
        return .{ .name = "emetgate", .status = .warn, .detail = std.fmt.allocPrint(arena, "{s}; not on PATH", .{detail}) catch detail, .fix = fix };
    };
    _ = found;
    return .{ .name = "emetgate", .status = .ok, .detail = detail };
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
        try checks.append(arena, .{ .name = "repo", .status = .fail, .detail = std.fmt.allocPrint(arena, "{s} is not inside a git repository ({t})", .{ probe.cwd, err }) catch "not in a repository", .fix = "cd into your project, or run: git init" });
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
    } else |err| switch (err) {
        error.FileNotFound => try checks.append(arena, .{ .name = ".mcp.json", .status = .ok, .detail = "none here; lockdown uses its own and finds the tests itself" }),
        else => {
            try checks.append(arena, mcpConfigFailure(err));
            return .{ .name = "tests", .status = .fail, .detail = "skipped: .mcp.json could not be read" };
        },
    }
    if (root == null) return .{ .name = "tests", .status = .fail, .detail = "skipped: needs a git repository" };
    const given = if (server.names_test) server.given else test_command.detect;
    const command = test_command.resolveTestCommand(arena, io, config_path, given, server.allow_repo_config) catch |err| return testFailure(err);
    if (test_command.takeUnverified()) return noTestsFound();
    const program = firstWord(command);
    _ = exe_path.resolve(arena, program, root) catch {
        return .{ .name = "tests", .status = .warn, .detail = std.fmt.allocPrint(arena, "\"{s}\": {s} is not on PATH", .{ command, program }) catch command, .fix = name_test_command };
    };
    return .{ .name = "tests", .status = .ok, .detail = std.fmt.allocPrint(arena, "\"{s}\"", .{command}) catch command };
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
