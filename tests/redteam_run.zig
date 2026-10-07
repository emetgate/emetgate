const std = @import("std");
const builtin = @import("builtin");
const fixture = @import("run_fixture.zig");
const server = @import("emetgate").server;
const sandbox = @import("emetgate").sandbox;
const run_command = @import("emetgate").run_command;
const run_tool = @import("emetgate").run_tool;

const testing = std.testing;
const gpa = testing.allocator;

fn expectRefused(reply: *fixture.Reply, reason: []const u8) !void {
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try testing.expectEqualStrings("refused", try reply.string("status"));
    try testing.expectEqualStrings(reason, try reply.string("reason"));
}

test "redteam run: shell injection around an allowed command is refused and nothing runs" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try fixture.Repo.init(&.{});
    defer repo.deinit();
    const before = try repo.fingerprint();
    defer gpa.free(before);
    const policy = fixture.policyWith(repo.root_abs, &.{"echo safe"});

    const marker = try std.fmt.allocPrint(gpa, "{s}\\pwned.txt", .{repo.top_abs});
    defer gpa.free(marker);
    const shapes = [_]struct { fmt: []const u8, reason: []const u8 }{
        .{ .fmt = "echo safe & echo pwned> \"{s}\"", .reason = "shell_metacharacter" },
        .{ .fmt = "echo safe && echo pwned> \"{s}\"", .reason = "shell_metacharacter" },
        .{ .fmt = "echo safe | echo pwned> \"{s}\"", .reason = "shell_metacharacter" },
        .{ .fmt = "echo safe; echo pwned> \"{s}\"", .reason = "shell_metacharacter" },
        .{ .fmt = "echo safe `echo pwned> \"{s}\"`", .reason = "shell_metacharacter" },
        .{ .fmt = "echo safe $(echo pwned> \"{s}\")", .reason = "shell_metacharacter" },
        .{ .fmt = "echo safe\necho pwned> \"{s}\"", .reason = "shell_metacharacter" },
        .{ .fmt = "echo safe\r\necho pwned> \"{s}\"", .reason = "shell_metacharacter" },
        .{ .fmt = "echo safe ^& echo pwned> \"{s}\"", .reason = "shell_metacharacter" },
        .{ .fmt = "echo safe > \"{s}\"", .reason = "shell_metacharacter" },
        .{ .fmt = "echo %USERPROFILE% \"{s}\"", .reason = "shell_metacharacter" },
        .{ .fmt = "echo safe \"{s}\"", .reason = "not_allowed" },
        .{ .fmt = "echo safe {s}", .reason = "not_allowed" },
    };
    for (shapes) |shape| {
        const command = try std.mem.replaceOwned(u8, gpa, shape.fmt, "{s}", marker);
        defer gpa.free(command);
        errdefer std.debug.print("injection: {s}\n", .{command});
        var reply = try fixture.call(policy, .{ .command = command });
        defer reply.deinit();
        try expectRefused(&reply, shape.reason);
        try testing.expect(!repo.exists("pwned.txt"));
    }
    const after = try repo.fingerprint();
    defer gpa.free(after);
    try testing.expectEqualStrings(before, after);
}

test "redteam run: an allowlist entry that carries a metacharacter or an install is refused at call time even if it reached the policy" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try fixture.Repo.init(&.{});
    defer repo.deinit();
    const injected = try std.fmt.allocPrint(gpa, "echo safe & echo pwned> \"{s}\\pwned.txt\"", .{repo.top_abs});
    defer gpa.free(injected);
    const policy = fixture.policyWith(repo.root_abs, &.{ injected, "npm install" });

    var metachar = try fixture.call(policy, .{ .command = injected });
    defer metachar.deinit();
    try expectRefused(&metachar, "shell_metacharacter");
    try testing.expect(!repo.exists("pwned.txt"));

    var install = try fixture.call(policy, .{ .command = "npm install" });
    defer install.deinit();
    try expectRefused(&install, "out_of_scope");
}

test "redteam run: an allowed script cannot write outside the shadow, runs from the shadow and leaves no trace in the working tree" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try fixture.Repo.init(&.{});
    defer repo.deinit();
    const script = try std.fmt.allocPrint(gpa, "@echo off\r\ncd\r\n" ++
        "echo inside> inside-shadow.txt\r\n" ++
        "echo BACKDOOR> \"{0s}\\src\\kept.ts\"\r\n" ++
        "echo BACKDOOR> \"{0s}\\planted.ts\"\r\n" ++
        "echo BACKDOOR> \"{1s}\\outside.txt\"\r\n" ++
        "echo BACKDOOR> \"{1s}\\planted.txt\"\r\n" ++
        "echo BACKDOOR> node_modules\\pkg\\index.js\r\n" ++
        "echo BACKDOOR> node_modules\\pkg\\planted.js\r\n" ++
        "if exist inside-shadow.txt (echo wrote-inside) else (echo inside-refused)\r\n" ++
        "exit /b 0\r\n", .{ repo.root_abs, repo.top_abs });
    defer gpa.free(script);
    try repo.commitScript("attack.cmd", script);
    const before = try repo.fingerprint();
    defer gpa.free(before);

    var reply = try fixture.call(fixture.policyWith(repo.root_abs, &.{".\\attack.cmd"}), .{ .command = ".\\attack.cmd" });
    defer reply.deinit();
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings("exited", try reply.string("outcome"));
    const stdout = try reply.string("stdout");
    const cwd_line = std.mem.trimEnd(u8, stdout[0 .. std.mem.indexOfScalar(u8, stdout, '\n') orelse stdout.len], "\r");
    try testing.expect(!std.ascii.startsWithIgnoreCase(cwd_line, repo.root_abs));
    try testing.expect(std.mem.indexOf(u8, stdout, "wrote-inside") != null);

    const after = try repo.fingerprint();
    defer gpa.free(after);
    try testing.expectEqualStrings(before, after);
    for ([_][]const u8{ "repo/inside-shadow.txt", "repo/planted.ts", "planted.txt", "repo/node_modules/pkg/planted.js" }) |planted| {
        errdefer std.debug.print("created outside the shadow: {s}\n", .{planted});
        try testing.expect(!repo.exists(planted));
    }
}

test "redteam run: a long command that leaves a child is stopped at the deadline" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try fixture.Repo.init(&.{.{ .name = "hang.cmd", .body = "@echo off\r\nstart /b cmd /d /c ping -n 30 127.0.0.1\r\nping -n 30 127.0.0.1\r\n" }});
    defer repo.deinit();
    const report = try run_command.runInShadow(gpa, testing.io, .{
        .root_abs = repo.root_abs,
        .command = ".\\hang.cmd",
        .limits = .{ .timeout_ms = 1500 },
    });
    defer report.deinit(gpa);
    try testing.expectEqual(sandbox.Outcome.timed_out, report.outcome);
    try testing.expect(report.duration_ns < 15 * std.time.ns_per_s);
}

test "redteam run: a flood of output comes back cut to the last lines with a count of the rest" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try fixture.Repo.init(&.{
        .{ .name = "flood.txt", .body = "flood flood flood flood flood flood flood flood\r\n" ** 4096 },
        .{ .name = "flood.cmd", .body = "@echo off\r\n:again\r\ntype flood.txt\r\ngoto again\r\n" },
    });
    defer repo.deinit();
    var reply = try fixture.call(fixture.policyWith(repo.root_abs, &.{".\\flood.cmd"}), .{ .command = ".\\flood.cmd" });
    defer reply.deinit();
    errdefer std.debug.print("{s}\n", .{reply.text[0..@min(reply.text.len, 400)]});
    try testing.expectEqualStrings("output_limit", try reply.string("outcome"));
    const stdout = try reply.string("stdout");
    try testing.expect(stdout.len <= run_tool.max_output_bytes);
    try testing.expect(std.mem.count(u8, stdout, "\n") <= run_tool.max_output_lines);
    try testing.expect((try reply.field("stdout_omitted_lines")).?.integer > 0);
}

test "redteam run: a call that names any policy field is refused before anything runs" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try fixture.Repo.init(&.{});
    defer repo.deinit();
    const policy = fixture.policyWith(repo.root_abs, &.{"echo safe"});
    inline for (.{
        .{ .command = "echo safe", .allow_run = "echo pwned" },
        .{ .command = "echo safe", .test_cmd = "echo pwned" },
        .{ .command = "echo safe", .typecheck_cmd = "echo pwned" },
        .{ .command = "echo safe", .allow_repo_config = true },
        .{ .command = "echo safe", .allow_repo_memory = true },
        .{ .command = "echo safe", .shadow_root = "C:\\" },
    }) |args| {
        var reply = try fixture.call(policy, args);
        defer reply.deinit();
        errdefer std.debug.print("{s}\n", .{reply.text});
        try testing.expect(reply.is_error);
        try testing.expectEqualStrings("ModelSuppliedTestPolicy", try reply.string("error"));
    }
}

test "redteam run: when the low-integrity token cannot be built the command is refused, never run unconfined" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    defer sandbox.injected_fault = null;
    var repo = try fixture.Repo.init(&.{});
    defer repo.deinit();
    const script = try std.fmt.allocPrint(gpa, "@echo off\r\necho ran> \"{s}\\ran.txt\"\r\n", .{repo.top_abs});
    defer gpa.free(script);
    try repo.commitScript("mark.cmd", script);
    const policy = fixture.policyWith(repo.root_abs, &.{".\\mark.cmd"});
    inline for (std.meta.fields(sandbox.TokenStep)) |field| {
        sandbox.injected_fault = @enumFromInt(field.value);
        var reply = try fixture.call(policy, .{ .command = ".\\mark.cmd" });
        defer reply.deinit();
        try expectRefused(&reply, "sandbox_unavailable");
        try testing.expect(!repo.exists("ran.txt"));
    }
}
