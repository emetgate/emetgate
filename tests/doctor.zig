const std = @import("std");
const emetgate = @import("emetgate");
const doctor = emetgate.doctor;
const sandbox = emetgate.sandbox;
const git_fixture = @import("git_fixture.zig");

const testing = std.testing;

test "doctor: a startup error names what is wrong and the exact fix command on one line" {
    const cases = [_]struct { err: anyerror, needle: []const u8 }{
        .{ .err = error.ClaudeNotFound, .needle = doctor.claude_install },
        .{ .err = error.GitNotFound, .needle = doctor.git_install },
        .{ .err = error.NotInRepo, .needle = "git init" },
        .{ .err = error.LocalAppDataUnavailable, .needle = "$env:LOCALAPPDATA" },
        .{ .err = error.NoEmetgateServer, .needle = "claude mcp add --scope project emetgate" },
        .{ .err = error.SeveralEmetgateServers, .needle = "claude mcp remove" },
        .{ .err = error.McpConfigInvalid, .needle = ".mcp.json" },
        .{ .err = error.LockdownFlagOverride, .needle = "drop it" },
        .{ .err = error.NoTestCommand, .needle = "--test" },
        .{ .err = error.UntrustedRepoConfig, .needle = "--allow-repo-config" },
        .{ .err = error.ClaudeTerminated, .needle = "emetgate doctor" },
    };
    for (cases) |case| {
        const text = doctor.hint(case.err) orelse return error.TestExpectedHint;
        try testing.expect(std.mem.indexOf(u8, text, case.needle) != null);
        try testing.expect(std.mem.indexOfScalar(u8, text, '\n') == null);
    }
    try testing.expectEqual(@as(?[]const u8, null), doctor.hint(error.SymbolNotFound));
}

test "doctor: exit is non-zero only when a check fails, a warning alone does not block" {
    const ok: doctor.Check = .{ .name = "git", .status = .ok, .detail = "" };
    const warn: doctor.Check = .{ .name = "console", .status = .warn, .detail = "" };
    const fail: doctor.Check = .{ .name = "claude", .status = .fail, .detail = "" };
    try testing.expectEqual(@as(u8, 0), doctor.exitCode(&.{ ok, warn }));
    try testing.expectEqual(@as(u8, 1), doctor.exitCode(&.{ ok, fail, warn }));
    try testing.expectEqual(@as(u8, 1), doctor.exitCode(&.{fail}));
}

test "doctor: a line carries the status, the check, the detail and the fix" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try doctor.writeLine(&w, .{ .name = "claude", .status = .fail, .detail = "not on PATH", .fix = "install it" });
    try doctor.writeLine(&w, .{ .name = "git", .status = .ok, .detail = "C:\\git.exe" });
    try testing.expectEqualStrings("FAIL  claude    not on PATH  -> fix: install it\nok    git       C:\\git.exe\n", w.buffered());
}

test "doctor: claude --version and auth status output are read" {
    try testing.expectEqualStrings("2.1.311 (Claude Code)", doctor.claudeVersion("2.1.311 (Claude Code)\r\n").?);
    try testing.expectEqual(@as(?[]const u8, null), doctor.claudeVersion("'claude' is not recognized\r\n"));
    try testing.expectEqual(@as(?[]const u8, null), doctor.claudeVersion(""));
    try testing.expectEqual(@as(?bool, true), doctor.loggedIn(testing.allocator, "{\"loggedIn\": true, \"authMethod\": \"claude.ai\"}"));
    try testing.expectEqual(@as(?bool, false), doctor.loggedIn(testing.allocator, "{\"loggedIn\": false}"));
    try testing.expectEqual(@as(?bool, null), doctor.loggedIn(testing.allocator, "Not logged in"));
    try testing.expectEqual(@as(?bool, null), doctor.loggedIn(testing.allocator, "{\"loggedIn\": \"yes\"}"));
}

test "doctor: a signed-out claude blocks lockdown with claude auth login, an unreadable status only warns" {
    const out = doctor.loginCheck(false);
    try testing.expectEqual(doctor.Status.fail, out.status);
    try testing.expectEqualStrings(doctor.claude_login, out.fix);
    try testing.expectEqual(doctor.Status.ok, doctor.loginCheck(true).status);
    try testing.expectEqual(doctor.Status.warn, doctor.loginCheck(null).status);
}

test "doctor: the test command lockdown will use comes from the emetgate server's --test in .mcp.json" {
    const config =
        \\{"mcpServers": {"other": {"command": "node", "args": ["x.js", "--test", "no"]},
        \\ "gate": {"command": "C:\\tools\\emetgate.exe", "args": ["mcp", "--test", "npm test", "--allow-repo-config"]}}}
    ;
    const found = try doctor.serverTest(testing.allocator, config);
    defer testing.allocator.free(found.given);
    try testing.expectEqualStrings("npm test", found.given);
    try testing.expect(found.allow_repo_config);

    const bare = try doctor.serverTest(testing.allocator, "{\"mcpServers\": {\"emetgate\": {\"command\": \"emetgate\", \"args\": [\"mcp\"]}}}");
    try testing.expectEqualStrings("", bare.given);
    try testing.expect(!bare.allow_repo_config);

    try testing.expectError(error.McpConfigInvalid, doctor.serverTest(testing.allocator, "{not json"));
    try testing.expectError(error.NoEmetgateServer, doctor.serverTest(testing.allocator, "{\"mcpServers\": {}}"));
}

test "doctor: no test command blocks lockdown, and the fix names --test" {
    const missing = doctor.testFailure(error.NoTestCommand);
    try testing.expectEqual(doctor.Status.fail, missing.status);
    try testing.expect(std.mem.indexOf(u8, missing.fix, "--test") != null);
    const untrusted = doctor.testFailure(error.UntrustedRepoConfig);
    try testing.expectEqual(doctor.Status.fail, untrusted.status);
    try testing.expect(std.mem.indexOf(u8, untrusted.fix, "--allow-repo-config") != null);
    const bad = doctor.mcpConfigFailure(error.SeveralEmetgateServers);
    try testing.expectEqual(doctor.Status.fail, bad.status);
    try testing.expect(bad.fix.len != 0);
}

test "doctor: a non-UTF-8 console code page is a warning with chcp 65001" {
    const turkish = doctor.codePageCheck(857);
    try testing.expectEqual(doctor.Status.warn, turkish.status);
    try testing.expectEqualStrings(doctor.utf8_console, turkish.fix);
    try testing.expectEqual(doctor.Status.ok, doctor.codePageCheck(65001).status);
    try testing.expectEqual(doctor.Status.ok, doctor.codePageCheck(0).status);
}

test "doctor: the program of a test command is its first word, quoted or not" {
    try testing.expectEqualStrings("npm", doctor.firstWord("npm test"));
    try testing.expectEqualStrings("zig", doctor.firstWord("  zig build test"));
    try testing.expectEqualStrings("C:\\Program Files\\nodejs\\npm.cmd", doctor.firstWord("\"C:\\Program Files\\nodejs\\npm.cmd\" test"));
    try testing.expectEqualStrings("pytest", doctor.firstWord("pytest"));
}

const Place = struct {
    arena: std.heap.ArenaAllocator,
    dir: []const u8,

    fn make(name: []const u8) !Place {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer arena.deinit();
        const temp = try sandbox.environmentValue(arena.allocator(), std.unicode.utf8ToUtf16LeStringLiteral("TEMP")) orelse return error.SkipZigTest;
        var nonce: [8]u8 = undefined;
        testing.io.random(&nonce);
        const dir = try std.fmt.allocPrint(arena.allocator(), "{s}\\emetgate doctor {x}\\{s}", .{ temp, &nonce, name });
        try std.Io.Dir.cwd().createDirPath(testing.io, dir);
        return .{ .arena = arena, .dir = dir };
    }

    fn deinit(self: *Place) void {
        const parent = std.fs.path.dirname(self.dir).?;
        std.Io.Dir.cwd().deleteTree(testing.io, parent) catch {};
        self.arena.deinit();
    }

    fn run(self: *Place, out: *std.Io.Writer) !u8 {
        const local = try std.fs.path.join(self.arena.allocator(), &.{ self.dir, "local" });
        try std.Io.Dir.cwd().createDirPath(testing.io, local);
        return doctor.run(testing.allocator, testing.io, .{
            .cwd = self.dir,
            .claude = "emetgate-doctor-no-such-claude",
            .self_exe = "C:\\nowhere\\emetgate.exe",
            .local_app_data = local,
            .version = "0.0.0",
        }, out);
    }
};

fn hasLine(text: []const u8, prefix: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, prefix)) return true;
    return false;
}

test "doctor: outside a git repository the repo check fails and doctor exits 1 with the fix" {
    var place = try Place.make("Uğur Çalışkan proje");
    defer place.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), try place.run(&out.writer));
    const text = out.written();
    try testing.expect(hasLine(text, "FAIL  claude    claude (Claude Code CLI) is not on PATH  -> fix: " ++ doctor.claude_install));
    try testing.expect(hasLine(text, "FAIL  repo      "));
    try testing.expect(std.mem.indexOf(u8, text, "git init") != null);
    try testing.expect(hasLine(text, "FAIL  tests     skipped: needs a git repository"));
    try testing.expect(hasLine(text, "not ready: "));
}

test "doctor: in a repository with a Unicode, spaced path the repo, tests, write, state and sandbox checks pass" {
    var place = try Place.make("Uğur Çalışkan proje");
    defer place.deinit();
    try git_fixture.initRepo(place.dir);
    var dir = try std.Io.Dir.cwd().openDir(testing.io, place.dir, .{});
    defer dir.close(testing.io);
    try dir.writeFile(testing.io, .{ .sub_path = ".mcp.json", .data = "{\"mcpServers\": {\"emetgate\": {\"command\": \"emetgate\", \"args\": [\"mcp\", \"--test\", \"cmd /c exit 0\"]}}}" });

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), try place.run(&out.writer));
    const text = out.written();
    try testing.expect(hasLine(text, "ok    repo      "));
    try testing.expect(std.mem.indexOf(u8, text, "Uğur Çalışkan proje") != null);
    try testing.expect(hasLine(text, "ok    .mcp.json one emetgate server"));
    try testing.expect(hasLine(text, "ok    tests     \"cmd /c exit 0\""));
    try testing.expect(hasLine(text, "ok    write     "));
    try testing.expect(hasLine(text, "ok    state     "));
    try testing.expect(hasLine(text, "ok    sandbox   "));
    try testing.expect(hasLine(text, "FAIL  claude    "));
}

test "doctor: a repository with no test command fails the tests check before lockdown starts" {
    var place = try Place.make("no tests");
    defer place.deinit();
    try git_fixture.initRepo(place.dir);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), try place.run(&out.writer));
    const text = out.written();
    try testing.expect(hasLine(text, "ok    .mcp.json none here"));
    try testing.expect(hasLine(text, "FAIL  tests     no test command"));
}

test "doctor: an .mcp.json with two emetgate servers fails before the test command is looked up" {
    var place = try Place.make("two servers");
    defer place.deinit();
    try git_fixture.initRepo(place.dir);
    var dir = try std.Io.Dir.cwd().openDir(testing.io, place.dir, .{});
    defer dir.close(testing.io);
    try dir.writeFile(testing.io, .{ .sub_path = ".mcp.json", .data = "{\"mcpServers\": {\"a\": {\"command\": \"emetgate\", \"args\": [\"mcp\"]}, \"b\": {\"command\": \"emetgate.exe\", \"args\": [\"serve\"]}}}" });
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), try place.run(&out.writer));
    const text = out.written();
    try testing.expect(hasLine(text, "FAIL  .mcp.json SeveralEmetgateServers  -> fix: "));
    try testing.expect(hasLine(text, "FAIL  tests     skipped: .mcp.json must be fixed first"));
}
