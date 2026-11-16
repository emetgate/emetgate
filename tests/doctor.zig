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
    defer found.deinit(testing.allocator);
    try testing.expectEqualStrings("npm test", found.given);
    try testing.expect(found.names_test);
    try testing.expect(found.allow_repo_config);
    try testing.expectEqualStrings("C:\\tools\\emetgate.exe", found.command);
    try testing.expectEqual(@as(usize, 4), found.args.len);
    try testing.expectEqualStrings("mcp", found.args[0]);
    try testing.expectEqualStrings("--allow-repo-config", found.args[3]);

    const bare = try doctor.serverTest(testing.allocator, "{\"mcpServers\": {\"emetgate\": {\"command\": \"emetgate\", \"args\": [\"mcp\"]}}}");
    defer bare.deinit(testing.allocator);
    try testing.expectEqualStrings("emetgate", bare.command);
    try testing.expectEqualStrings("", bare.given);
    try testing.expect(!bare.names_test);
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

test "doctor: a repository with no tests to find warns that writes land unverified and does not fail" {
    var place = try Place.make("no tests");
    defer place.deinit();
    try git_fixture.initRepo(place.dir);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), try place.run(&out.writer));
    const text = out.written();
    try testing.expect(hasLine(text, "ok    .mcp.json none here"));
    try testing.expect(hasLine(text, "warn  tests     none found"));
    try testing.expect(std.mem.indexOf(u8, text, "unverified_no_tests") != null);
    try testing.expect(!hasLine(text, "FAIL  tests"));
}

test "doctor: with no --test it reports the command lockdown will detect, with or without an .mcp.json" {
    const configs = [_]?[]const u8{
        null,
        "{\"mcpServers\": {\"emetgate\": {\"command\": \"emetgate\", \"args\": [\"mcp\"]}}}",
        "{\"mcpServers\": {\"emetgate\": {\"command\": \"emetgate\", \"args\": [\"mcp\", \"--detect-test\"]}}}",
    };
    for (configs) |config| {
        var place = try Place.make("detected tests");
        defer place.deinit();
        try git_fixture.initRepo(place.dir);
        var dir = try std.Io.Dir.cwd().openDir(testing.io, place.dir, .{});
        defer dir.close(testing.io);
        try dir.writeFile(testing.io, .{ .sub_path = "go.mod", .data = "module x\n" });
        if (config) |data| try dir.writeFile(testing.io, .{ .sub_path = ".mcp.json", .data = data });
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        _ = try place.run(&out.writer);
        const text = out.written();
        try testing.expect(std.mem.indexOf(u8, text, "tests     \"go test ./...\"") != null);
        try testing.expect(!hasLine(text, "FAIL  tests"));
    }
}

test "doctor: an empty --test is not detected, because lockdown adds no detection beside it" {
    var place = try Place.make("empty test");
    defer place.deinit();
    try git_fixture.initRepo(place.dir);
    var dir = try std.Io.Dir.cwd().openDir(testing.io, place.dir, .{});
    defer dir.close(testing.io);
    try dir.writeFile(testing.io, .{ .sub_path = "go.mod", .data = "module x\n" });
    try dir.writeFile(testing.io, .{ .sub_path = ".mcp.json", .data = "{\"mcpServers\": {\"emetgate\": {\"command\": \"emetgate\", \"args\": [\"mcp\", \"--test\", \"\"]}}}" });
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    _ = try place.run(&out.writer);
    try testing.expect(hasLine(out.written(), "FAIL  tests     no test command"));
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

test "doctor: the server's initialize reply is read for its name and version, and anything else is no answer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const reply = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"emetgate\",\"version\":\"0.9.0\"}}}\r\n";
    try testing.expectEqualStrings("0.9.0", doctor.serverAnswer(a, reply).?);
    try testing.expectEqualStrings("0.9.0", doctor.serverAnswer(a, "starting\n" ++ reply).?);
    try testing.expectEqual(@as(?[]const u8, null), doctor.serverAnswer(a, ""));
    try testing.expectEqual(@as(?[]const u8, null), doctor.serverAnswer(a, "error: InvalidArguments\n"));
    try testing.expectEqual(@as(?[]const u8, null), doctor.serverAnswer(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"serverInfo\":{\"name\":\"other\",\"version\":\"1\"}}}"));
    try testing.expectEqual(@as(?[]const u8, null), doctor.serverAnswer(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32600}}"));
}

test "doctor: a server that is missing, does not start or does not answer blocks lockdown, an older one warns" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const self = "C:\\Programs\\emetgate\\emetgate.exe";
    const reply = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"serverInfo\":{\"name\":\"emetgate\",\"version\":\"0.8.0\"}}}\n";

    const missing = doctor.serverCheck(a, "C:\\old\\emetgate.exe", .missing, "0.9.0", self);
    try testing.expectEqual(doctor.Status.fail, missing.status);
    try testing.expect(std.mem.indexOf(u8, missing.detail, "C:\\old\\emetgate.exe is not there") != null);
    try testing.expect(std.mem.indexOf(u8, missing.fix, self) != null);

    const failed = doctor.serverCheck(a, "emetgate", .{ .failed = error.AccessDenied }, "0.9.0", self);
    try testing.expectEqual(doctor.Status.fail, failed.status);
    try testing.expect(std.mem.indexOf(u8, failed.detail, "AccessDenied") != null);

    const silent = doctor.serverCheck(a, "emetgate", .{ .finished = .{ .stdout = "", .stderr = "error: unknown flag --tset\nusage: ...\n" } }, "0.9.0", self);
    try testing.expectEqual(doctor.Status.fail, silent.status);
    try testing.expect(std.mem.indexOf(u8, silent.detail, "did not answer initialize: error: unknown flag --tset") != null);
    try testing.expect(std.mem.indexOf(u8, silent.detail, "usage") == null);

    const older = doctor.serverCheck(a, "emetgate", .{ .finished = .{ .stdout = reply, .stderr = "" } }, "0.9.0", self);
    try testing.expectEqual(doctor.Status.warn, older.status);
    try testing.expect(std.mem.indexOf(u8, older.detail, "is emetgate 0.8.0, this is 0.9.0") != null);

    const same = doctor.serverCheck(a, "emetgate", .{ .finished = .{ .stdout = reply, .stderr = "" } }, "0.8.0", self);
    try testing.expectEqual(doctor.Status.ok, same.status);
    try testing.expectEqualStrings("answers as emetgate 0.8.0", same.detail);
}

test "doctor: an .mcp.json whose emetgate server is not on disk fails the server check and is not ready" {
    var place = try Place.make("moved server");
    defer place.deinit();
    try git_fixture.initRepo(place.dir);
    var dir = try std.Io.Dir.cwd().openDir(testing.io, place.dir, .{});
    defer dir.close(testing.io);
    try dir.writeFile(testing.io, .{ .sub_path = ".mcp.json", .data = "{\"mcpServers\": {\"emetgate\": {\"command\": \"C:\\\\no\\\\such\\\\folder\\\\emetgate.exe\", \"args\": [\"mcp\", \"--test\", \"cmd /c exit 0\"]}}}" });
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(@as(u8, 1), try place.run(&out.writer));
    const text = out.written();
    try testing.expect(hasLine(text, "ok    .mcp.json one emetgate server"));
    try testing.expect(hasLine(text, "FAIL  server    C:\\no\\such\\folder\\emetgate.exe is not there"));
    try testing.expect(std.mem.indexOf(u8, text, "C:\\nowhere\\emetgate.exe") != null);
    try testing.expect(hasLine(text, "not ready: "));
}

fn touch(dir: []const u8, name: []const u8, data: []const u8) ![]const u8 {
    try std.Io.Dir.cwd().createDirPath(testing.io, dir);
    const path = try std.fs.path.join(testing.allocator, &.{ dir, name });
    errdefer testing.allocator.free(path);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = data });
    return path;
}

test "doctor: every emetgate on PATH is listed in PATH order, once, and a missing folder is skipped" {
    var place = try Place.make("path");
    defer place.deinit();
    const a = place.arena.allocator();
    const first = try std.fs.path.join(a, &.{ place.dir, "first" });
    const second = try std.fs.path.join(a, &.{ place.dir, "second" });
    testing.allocator.free(try touch(first, "emetgate.exe", "x"));
    testing.allocator.free(try touch(second, "emetgate.cmd", "x"));
    const path_list = try std.fmt.allocPrint(a, "{s};C:\\no\\such\\folder;\"{s}\\\";{s}", .{ first, second, first });
    const hits = try doctor.onPath(a, testing.io, path_list, ".COM;.EXE;.BAT;.CMD", "emetgate");
    try testing.expectEqual(@as(usize, 2), hits.len);
    try testing.expect(std.ascii.endsWithIgnoreCase(hits[0], "first\\emetgate.exe"));
    try testing.expect(std.ascii.endsWithIgnoreCase(hits[1], "second\\emetgate.cmd"));
}

test "doctor: the path line is ok for one copy, and warns when another copy runs first or shadows the rest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const self = "C:\\nowhere\\new\\emetgate.exe";
    const old = "C:\\nowhere\\old\\emetgate.exe";

    const none = try doctor.pathCheck(a, self, &.{}, null);
    try testing.expectEqual(doctor.Status.warn, none.status);
    try testing.expect(std.mem.indexOf(u8, none.fix, "C:\\nowhere\\new") != null);

    const only = try doctor.pathCheck(a, self, &.{"c:\\NOWHERE\\new\\emetgate.exe"}, null);
    try testing.expectEqual(doctor.Status.ok, only.status);

    const shadowing = try doctor.pathCheck(a, self, &.{ old, self }, "0.9.0");
    try testing.expectEqual(doctor.Status.warn, shadowing.status);
    try testing.expect(std.mem.indexOf(u8, shadowing.detail, "runs C:\\nowhere\\old\\emetgate.exe (emetgate 0.9.0), not this C:\\nowhere\\new\\emetgate.exe; also on PATH: C:\\nowhere\\new\\emetgate.exe") != null);
    try testing.expect(std.mem.indexOf(u8, shadowing.fix, "remove C:\\nowhere\\old from PATH") != null);

    const shadowed = try doctor.pathCheck(a, self, &.{ self, old }, null);
    try testing.expectEqual(doctor.Status.warn, shadowed.status);
    try testing.expect(std.mem.indexOf(u8, shadowed.detail, "2 copies on PATH") != null);
    try testing.expect(std.mem.indexOf(u8, shadowed.detail, old) != null);
}

test "doctor: the release line compares with the last release seen, and says why when it could not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const newer = try doctor.releaseCheck(a, "0.10.4", .{ .latest = "0.10.5", .newer = true, .checked_ago_s = 3 * 3600 });
    try testing.expectEqual(doctor.Status.warn, newer.status);
    try testing.expectEqualStrings("emetgate 0.10.5 is out, this is 0.10.4 (checked 3 h ago)", newer.detail);
    try testing.expectEqualStrings("emetgate update", newer.fix);

    const latest = try doctor.releaseCheck(a, "0.10.4", .{ .latest = "0.10.4", .checked_ago_s = 5 * 86400 });
    try testing.expectEqual(doctor.Status.ok, latest.status);
    try testing.expectEqualStrings("0.10.4 is the latest release (checked 5 days ago)", latest.detail);

    const offline = try doctor.releaseCheck(a, "0.10.4", .{ .offline = error.ConnectFailed });
    try testing.expectEqual(doctor.Status.warn, offline.status);
    try testing.expect(std.mem.indexOf(u8, offline.detail, "ConnectFailed") != null);

    try testing.expect(std.mem.indexOf(u8, (try doctor.releaseCheck(a, "0.10.4", .{ .disabled = true })).detail, "EMETGATE_NO_UPDATE") != null);
    try testing.expectEqual(doctor.Status.ok, (try doctor.releaseCheck(a, "0.0.0-dev", .{ .release_build = false })).status);
    const replaced = try doctor.releaseCheck(a, "0.10.4", .{ .updated_to = "0.10.5", .latest = "0.10.5", .newer = true });
    try testing.expect(std.mem.indexOf(u8, replaced.detail, "just replaced by emetgate 0.10.5") != null);
}

test "doctor: other emetgate processes are listed with pid and command line, and only warn" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(doctor.install_probe.isEmetgateImage("EMETGATE.EXE"));
    try testing.expect(doctor.install_probe.isEmetgateImage("emetgate.old.exe"));
    try testing.expect(!doctor.install_probe.isEmetgateImage("emetgate-helper.exe"));

    try testing.expectEqual(doctor.Status.ok, (try doctor.processCheck(a, &.{})).status);
    const two = try doctor.processCheck(a, &.{
        .{ .pid = 41, .image = "C:\\x\\emetgate.exe", .command_line = "\"C:\\x\\emetgate.exe\" mcp --test \"npm test\"" },
        .{ .pid = 42, .image = "C:\\y\\emetgate.exe", .command_line = "" },
    });
    try testing.expectEqual(doctor.Status.warn, two.status);
    try testing.expectEqualStrings("2 other emetgate processes: pid 41 \"C:\\x\\emetgate.exe\" mcp --test \"npm test\"; pid 42 C:\\y\\emetgate.exe", two.detail);
    try testing.expect(std.mem.indexOf(u8, two.fix, "stops nothing") != null);

    const own = try doctor.install_probe.emetgateProcesses(a);
    for (own) |process| try testing.expect(process.pid != 0);
}

test "doctor: claude's config folder is CLAUDE_CONFIG_DIR when set, else the home .claude, and a missing one warns" {
    var place = try Place.make("config");
    defer place.deinit();
    const a = place.arena.allocator();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try testing.expect((try doctor.claudeConfig(a, &env)) == null);
    try testing.expectEqual(doctor.Status.warn, (try doctor.configCheck(a, testing.io, null)).status);

    try env.put("USERPROFILE", "C:\\Users\\you");
    const home = (try doctor.claudeConfig(a, &env)).?;
    try testing.expectEqualStrings("C:\\Users\\you\\.claude", home.dir);
    try testing.expectEqualStrings("C:\\Users\\you\\.claude.json", home.json);
    try testing.expect(!home.from_env);
    try testing.expectEqual(doctor.Status.ok, (try doctor.configCheck(a, testing.io, home)).status);

    const missing = try std.fs.path.join(a, &.{ place.dir, "gone" });
    try env.put("CLAUDE_CONFIG_DIR", missing);
    const moved = (try doctor.claudeConfig(a, &env)).?;
    try testing.expect(moved.from_env);
    try testing.expectEqualStrings("C:\\Users\\you\\.claude.json", moved.default_json.?);
    try testing.expect(std.mem.endsWith(u8, moved.json, "gone\\.claude.json"));
    const warned = try doctor.configCheck(a, testing.io, moved);
    try testing.expectEqual(doctor.Status.warn, warned.status);
    try testing.expect(std.mem.indexOf(u8, warned.fix, "CLAUDE_CONFIG_DIR") != null);

    try env.put("CLAUDE_CONFIG_DIR", place.dir);
    const present = try doctor.configCheck(a, testing.io, (try doctor.claudeConfig(a, &env)).?);
    try testing.expectEqual(doctor.Status.ok, present.status);
    try testing.expect(std.mem.indexOf(u8, present.detail, "C:\\Users\\you\\.claude.json instead") != null);
}

test "doctor: user and local emetgate registrations are read from claude's config for this project only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config =
        \\{"mcpServers": {"emetgate": {"type": "stdio", "command": "C:\\tools\\emetgate.exe", "args": ["mcp"]}, "other": {"command": "node", "args": ["x.js"]}},
        \\ "projects": {"C:/Users/You/Proje": {"mcpServers": {"gate": {"command": "emetgate", "args": ["mcp", "--test", "npm test"]}}},
        \\              "C:/Users/You/Other": {"mcpServers": {"emetgate": {"command": "emetgate", "args": ["mcp"]}}}}}
    ;
    const found = try doctor.registrations(a, config, &.{"c:\\users\\you\\proje\\"});
    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expectEqualStrings("user", found[0].scope);
    try testing.expectEqualStrings("C:\\tools\\emetgate.exe", found[0].command);
    try testing.expectEqualStrings("local", found[1].scope);
    try testing.expectEqualStrings("gate", found[1].name);
    try testing.expectEqual(@as(usize, 0), (try doctor.registrations(a, "{}", &.{"C:\\x"})).len);
    try testing.expectError(error.McpConfigInvalid, doctor.registrations(a, "not json", &.{"C:\\x"}));
}

test "doctor: a registration whose exe is gone or is another copy warns, and one only in the other config folder is named" {
    var place = try Place.make("registered");
    defer place.deinit();
    const a = place.arena.allocator();
    const self = try touch(place.dir, "emetgate.exe", "x");
    defer testing.allocator.free(self);
    const config: doctor.ClaudeConfig = .{ .dir = "D:\\cfg", .json = "D:\\cfg\\.claude.json", .from_env = true, .default_json = "C:\\Users\\you\\.claude.json" };

    const lines = try doctor.registrationChecks(a, testing.io, self, config, &.{
        .{ .scope = "user", .name = "emetgate", .command = self },
        .{ .scope = "local", .name = "gate", .command = "C:\\no\\such\\emetgate.exe" },
    }, &.{});
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqual(doctor.Status.ok, lines[0].status);
    try testing.expectEqualStrings("mcp user", lines[0].name);
    try testing.expectEqual(doctor.Status.warn, lines[1].status);
    try testing.expectEqualStrings("mcp local", lines[1].name);
    try testing.expect(std.mem.indexOf(u8, lines[1].detail, "C:\\no\\such\\emetgate.exe, which is not there") != null);
    try testing.expect(std.mem.indexOf(u8, lines[1].fix, "claude mcp remove gate -s local") != null);

    const split = try doctor.registrationChecks(a, testing.io, self, config, &.{}, &.{.{ .scope = "user", .name = "emetgate", .command = self }});
    try testing.expectEqual(doctor.Status.warn, split[0].status);
    try testing.expect(std.mem.indexOf(u8, split[0].detail, "registered in C:\\Users\\you\\.claude.json, but CLAUDE_CONFIG_DIR makes claude read D:\\cfg\\.claude.json") != null);

    const nowhere = try doctor.registrationChecks(a, testing.io, self, .{ .dir = "C:\\h\\.claude", .json = "C:\\h\\.claude.json", .from_env = false }, &.{}, &.{});
    try testing.expectEqual(doctor.Status.ok, nowhere[0].status);
}

test "doctor: the data line gives emetgate's data folder and its size" {
    var place = try Place.make("data");
    defer place.deinit();
    const a = place.arena.allocator();
    const empty = try doctor.dataCheck(a, testing.io, place.dir);
    try testing.expect(std.mem.endsWith(u8, empty.detail, "emetgate (not created yet)"));

    const data = try std.fs.path.join(a, &.{ place.dir, "emetgate" });
    testing.allocator.free(try touch(data, "a", "0123456789"));
    testing.allocator.free(try touch(try std.fs.path.join(a, &.{ data, "deep", "er" }), "b", "01234"));
    const measured = try doctor.dataCheck(a, testing.io, place.dir);
    try testing.expectEqual(doctor.Status.ok, measured.status);
    try testing.expect(std.mem.endsWith(u8, measured.detail, "emetgate: 15 B in 2 files"));

    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try doctor.install_probe.writeBytes(&w, 3 * 1024 * 1024 + 512 * 1024);
    try testing.expectEqualStrings("3.5 MiB", w.buffered());
}

test "doctor: --json gives every line as an object with name, status, detail and fix, plus ready" {
    var place = try Place.make("json");
    defer place.deinit();
    try git_fixture.initRepo(place.dir);
    const a = place.arena.allocator();
    const local = try std.fs.path.join(a, &.{ place.dir, "local" });
    try std.Io.Dir.cwd().createDirPath(testing.io, local);
    const bin = try std.fs.path.join(a, &.{ place.dir, "bin" });
    testing.allocator.free(try touch(bin, "emetgate.exe", "not an exe"));
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("PATH", bin);
    try env.put("USERPROFILE", place.dir);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const code = try doctor.run(testing.allocator, testing.io, .{
        .cwd = place.dir,
        .claude = "emetgate-doctor-no-such-claude",
        .self_exe = "C:\\nowhere\\emetgate.exe",
        .local_app_data = local,
        .version = "0.0.0",
        .env = &env,
        .release = .{ .latest = "0.0.1", .newer = true, .checked_ago_s = 60 },
        .json = true,
    }, &out.writer);
    try testing.expectEqual(@as(u8, 1), code);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.written(), .{});
    defer parsed.deinit();
    try testing.expectEqual(false, parsed.value.object.get("ready").?.bool);
    try testing.expectEqualStrings("0.0.0", parsed.value.object.get("version").?.string);
    var seen: usize = 0;
    for (parsed.value.object.get("checks").?.array.items) |item| {
        const name = item.object.get("name").?.string;
        const status = item.object.get("status").?.string;
        if (std.mem.eql(u8, name, "path")) {
            try testing.expectEqualStrings("warn", status);
            seen += 1;
        }
        if (std.mem.eql(u8, name, "release")) {
            try testing.expectEqualStrings("warn", status);
            seen += 1;
        }
        if (std.mem.eql(u8, name, "config") or std.mem.eql(u8, name, "mcp") or std.mem.eql(u8, name, "data") or std.mem.eql(u8, name, "repo")) {
            try testing.expectEqualStrings("ok", status);
            seen += 1;
        }
        if (std.mem.eql(u8, name, "claude")) try testing.expectEqualStrings("fail", status);
        try testing.expect(item.object.get("fix") != null and item.object.get("detail") != null);
    }
    try testing.expectEqual(@as(usize, 6), seen);
}
