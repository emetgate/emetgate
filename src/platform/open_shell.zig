const std = @import("std");
const sandbox = @import("sandbox.zig");
const exe_path = @import("exe_path.zig");
const test_outcome = @import("test_outcome.zig");

const Allocator = std.mem.Allocator;

pub const Kind = enum {
    git_bash,
    cmd,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .git_bash => "git bash",
            .cmd => "cmd",
        };
    }
};

pub const Shell = struct {
    kind: Kind,
    path: []u8,

    pub fn deinit(self: Shell, gpa: Allocator) void {
        gpa.free(self.path);
    }
};

const shell_env = [_]sandbox.EnvVar{.{ .name = "NoDefaultCurrentDirectoryInExePath", .value = "1" }};

pub fn find(gpa: Allocator, repo_root: ?[]const u8) !Shell {
    if (exe_path.gitBash(gpa, repo_root)) |bash| {
        return .{ .kind = .git_bash, .path = bash };
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BashNotFound => {},
    }
    return .{ .kind = .cmd, .path = try exe_path.system(gpa, "cmd.exe") };
}

pub fn quoted(gpa: Allocator, arg: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.append(gpa, '"');
    var backslashes: usize = 0;
    for (arg) |byte| switch (byte) {
        '\\' => backslashes += 1,
        '"' => {
            try buf.appendNTimes(gpa, '\\', backslashes * 2 + 1);
            try buf.append(gpa, '"');
            backslashes = 0;
        },
        else => {
            try buf.appendNTimes(gpa, '\\', backslashes);
            try buf.append(gpa, byte);
            backslashes = 0;
        },
    };
    try buf.appendNTimes(gpa, '\\', backslashes * 2);
    try buf.append(gpa, '"');
    return buf.toOwnedSlice(gpa);
}

pub fn tail(gpa: Allocator, kind: Kind, command: []const u8) ![]u8 {
    return switch (kind) {
        .git_bash => quoted(gpa, command),
        .cmd => std.fmt.allocPrint(gpa, "\"{s}\"", .{command}),
    };
}

pub fn run(gpa: Allocator, io: std.Io, cwd: []const u8, shell: Shell, command: []const u8, limits: sandbox.Limits) !sandbox.Report {
    const verbatim = try tail(gpa, shell.kind, command);
    defer gpa.free(verbatim);
    const bash_argv = [_][]const u8{ shell.path, "-c" };
    const cmd_argv = [_][]const u8{ shell.path, "/d", "/s", "/c" };
    const argv: []const []const u8 = switch (shell.kind) {
        .git_bash => &bash_argv,
        .cmd => &cmd_argv,
    };
    var report = try sandbox.run(gpa, io, .{ .argv = argv, .cwd = cwd, .limits = limits, .backend = .user, .env = &shell_env, .verbatim_tail = verbatim });
    report.no_tests = test_outcome.noTests(report);
    return report;
}

test "open shell: bash gets one argument in the quoting its runtime splits on" {
    const gpa = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "ls -la", "\"ls -la\"" },
        .{ "echo \"a b\"", "\"echo \\\"a b\\\"\"" },
        .{ "cat C:\\dir\\", "\"cat C:\\dir\\\\\"" },
        .{ "printf '%s\\n' x", "\"printf '%s\\n' x\"" },
    };
    for (cases) |case| {
        const got = try tail(gpa, .git_bash, case[0]);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(case[1], got);
    }
}

test "open shell: cmd gets the command verbatim between the quotes /s strips" {
    const gpa = std.testing.allocator;
    const got = try tail(gpa, .cmd, "dir \"a b\" && echo \"x\"");
    defer gpa.free(got);
    try std.testing.expectEqualStrings("\"dir \"a b\" && echo \"x\"\"", got);
}
