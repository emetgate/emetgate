const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");
const context_epoch = emetgate.context_epoch;
const handlers = emetgate.handlers;
const lockdown = emetgate.lockdown;
const lockdown_slash = emetgate.lockdown_slash;
const mirror_mod = emetgate.mirror;
const server = emetgate.server;
const telemetry = emetgate.telemetry;
const Runtime = emetgate.runtime.Runtime;

const testing = std.testing;
const Watch = context_epoch.Watch;

const session = "11111111-2222-3333-4444-555555555555";
const startup = "{\"session_id\":\"" ++ session ++ "\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}";
const compact = "{\"session_id\":\"" ++ session ++ "\",\"hook_event_name\":\"SessionStart\",\"source\":\"compact\"}";
const clear = "{\"session_id\":\"66666666-7777-8888-9999-000000000000\",\"hook_event_name\":\"SessionStart\",\"source\":\"clear\"}";

const Case = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    file: [:0]u8,
    epoch: []u8,
    runtime: *Runtime,
    mirror: mirror_mod.Mirror,
    watch: Watch,

    fn init(self: *Case) !void {
        self.tmp = testing.tmpDir(.{});
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "notes.txt", .data = "hello\n" });
        self.root = try self.tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        self.file = try self.tmp.dir.realPathFileAlloc(testing.io, "notes.txt", testing.allocator);
        self.epoch = try std.fmt.allocPrint(testing.allocator, "{s}\\state\\a.epoch", .{self.root});
        self.runtime = try Runtime.create(testing.allocator);
        self.mirror = .init(testing.allocator, true);
        self.watch = .{ .gpa = testing.allocator, .path = try testing.allocator.dupe(u8, self.epoch), .session = try testing.allocator.dupe(u8, session) };
    }

    fn deinit(self: *Case) void {
        self.watch.deinit();
        self.mirror.deinit();
        self.runtime.destroy() catch @panic("live snapshots");
        testing.allocator.free(self.epoch);
        testing.allocator.free(self.file);
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn read(self: *Case) ![]const u8 {
        var event: telemetry.Event = .{ .tool = "emetgate_read_file" };
        const line = try std.json.Stringify.valueAlloc(testing.allocator, .{ .file = self.file }, .{});
        defer testing.allocator.free(line);
        const args = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
        defer args.deinit();
        const result = try handlers.callTool(testing.allocator, testing.io, self.runtime, "emetgate_read_file", args.value, &event, .{ .root = self.root, .mirror = &self.mirror, .mirror_enabled = true, .context = &self.watch });
        errdefer testing.allocator.free(result.text);
        errdefer std.debug.print("{s}\n", .{result.text});
        try testing.expect(!result.is_error);
        return result.text;
    }

    fn sends(self: *Case) !bool {
        const text = try self.read();
        defer testing.allocator.free(text);
        const sent = std.mem.indexOf(u8, text, "hello") != null;
        const unchanged = std.mem.indexOf(u8, text, "\"status\":\"unchanged\"") != null;
        try testing.expect(sent != unchanged);
        return sent;
    }

    fn hook(self: *Case, input: []const u8) !void {
        try context_epoch.record(testing.allocator, testing.io, self.epoch, input);
    }
};

test "context epoch: a compaction makes the next read send the content, and a repeat after it is unchanged again" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.hook(startup);
    try testing.expect(try case.sends());
    try testing.expect(!try case.sends());
    try case.hook(compact);
    try testing.expect(try case.sends());
    try testing.expect(!try case.sends());
}

test "context epoch: without a move a repeated read stays unchanged across many calls" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.hook(startup);
    try testing.expect(try case.sends());
    for (0..5) |_| try testing.expect(!try case.sends());
}

test "context epoch: a clear under a new session id also makes the next read send the content" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.hook(startup);
    try testing.expect(try case.sends());
    try case.hook(clear);
    try testing.expect(try case.sends());
    try testing.expect(!try case.sends());
}

test "context epoch: the session hook with empty or unreadable stdin still moves the epoch" {
    for ([_][]const u8{ "", "{", "not json", "[1,2]", "{\"session_id\":7}", "{\"session_id\":\"a b\\n\"}" }) |bad| {
        var case: Case = undefined;
        try case.init();
        defer case.deinit();
        try case.hook(startup);
        try testing.expect(try case.sends());
        try testing.expect(!try case.sends());
        try case.hook(bad);
        try testing.expect(try case.sends());
    }
}

test "context epoch: with no epoch file the server sends the content every time" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    for (0..3) |_| try testing.expect(try case.sends());
}

test "context epoch: a watch with no path never lets a read answer unchanged" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    testing.allocator.free(case.watch.path.?);
    case.watch.path = null;
    for (0..3) |_| try testing.expect(try case.sends());
}

test "context epoch: a file another session left behind does not arm the mirror until the epoch moves" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.hook("{\"session_id\":\"someone-else\"}");
    for (0..3) |_| try testing.expect(try case.sends());
    try case.hook(compact);
    try testing.expect(try case.sends());
    try testing.expect(!try case.sends());
}

test "context epoch: an epoch file that disappears sends the content until the hook writes it again" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.hook(startup);
    try testing.expect(try case.sends());
    try testing.expect(!try case.sends());
    try std.Io.Dir.cwd().deleteFile(testing.io, case.epoch);
    for (0..2) |_| try testing.expect(try case.sends());
    try case.hook(startup);
    try testing.expect(try case.sends());
    try testing.expect(!try case.sends());
}

test "context epoch: an epoch file that cannot be read sends the content on that call" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.hook(startup);
    try testing.expect(try case.sends());
    try testing.expect(!try case.sends());
    try std.Io.Dir.cwd().deleteFile(testing.io, case.epoch);
    try std.Io.Dir.cwd().createDirPath(testing.io, case.epoch);
    try testing.expect(try case.sends());
    try testing.expect(try case.sends());
}

test "context epoch: since_call keeps counting across a reset and names the call that resent the content" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.hook(startup);
    try testing.expect(try case.sends());
    try testing.expect(!try case.sends());
    try case.hook(compact);
    try testing.expect(try case.sends());
    const text = try case.read();
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "\"since_call\":3") != null);
}

test "context epoch: two launches do not share a file, so one compaction leaves the other mirror alone" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const state = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(state);
    const first = try lockdown_slash.launchContext(testing.allocator, testing.io, state);
    defer testing.allocator.free(first);
    const second = try lockdown_slash.launchContext(testing.allocator, testing.io, state);
    defer testing.allocator.free(second);
    try testing.expect(!std.mem.eql(u8, first, second));
    try testing.expect(std.mem.startsWith(u8, first, state));

    var a: Watch = .{ .gpa = testing.allocator, .path = try testing.allocator.dupe(u8, first), .session = try testing.allocator.dupe(u8, session) };
    defer a.deinit();
    var b: Watch = .{ .gpa = testing.allocator, .path = try testing.allocator.dupe(u8, second), .session = try testing.allocator.dupe(u8, session) };
    defer b.deinit();
    try context_epoch.record(testing.allocator, testing.io, first, startup);
    try context_epoch.record(testing.allocator, testing.io, second, startup);
    try testing.expect(a.stale());
    try testing.expect(b.stale());
    try testing.expect(!a.stale());
    try testing.expect(!b.stale());
    try context_epoch.record(testing.allocator, testing.io, first, compact);
    try testing.expect(a.stale());
    try testing.expect(!b.stale());
    try testing.expect(!a.stale());
}

test "context epoch: two servers on one project file both reset when either session compacts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const file = try std.fmt.allocPrint(testing.allocator, "{s}\\shared.epoch", .{root});
    defer testing.allocator.free(file);
    var a: Watch = .{ .gpa = testing.allocator, .path = try testing.allocator.dupe(u8, file), .session = try testing.allocator.dupe(u8, "aaa") };
    defer a.deinit();
    var b: Watch = .{ .gpa = testing.allocator, .path = try testing.allocator.dupe(u8, file), .session = try testing.allocator.dupe(u8, "bbb") };
    defer b.deinit();
    try context_epoch.record(testing.allocator, testing.io, file, "{\"session_id\":\"aaa\"}");
    try testing.expect(a.stale());
    try testing.expect(b.stale());
    try testing.expect(!a.stale());
    try testing.expect(b.stale());
    try context_epoch.record(testing.allocator, testing.io, file, "{\"session_id\":\"bbb\"}");
    try testing.expect(a.stale());
    try testing.expect(b.stale());
    try testing.expect(!a.stale());
    try testing.expect(!b.stale());
    try context_epoch.record(testing.allocator, testing.io, file, "{\"session_id\":\"aaa\"}");
    try testing.expect(a.stale());
    try testing.expect(b.stale());
}

test "context epoch: the hook and the server name the same file from the same environment" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try testing.expect(try context_epoch.path(testing.allocator, &env) == null);
    try env.put("LOCALAPPDATA", "C:\\L");
    try testing.expect(try context_epoch.path(testing.allocator, &env) == null);
    try env.put("CLAUDE_PROJECT_DIR", "C:\\Repo\\App");
    const project = (try context_epoch.path(testing.allocator, &env)).?;
    defer testing.allocator.free(project);
    try testing.expect(std.mem.startsWith(u8, project, "C:\\L\\emetgate\\context\\"));
    try env.put("CLAUDE_PROJECT_DIR", "c:/repo/app/");
    const same = (try context_epoch.path(testing.allocator, &env)).?;
    defer testing.allocator.free(same);
    try testing.expectEqualStrings(project, same);
    try env.put("CLAUDE_PROJECT_DIR", "C:\\Repo\\Other");
    const other = (try context_epoch.path(testing.allocator, &env)).?;
    defer testing.allocator.free(other);
    try testing.expect(!std.mem.eql(u8, project, other));
    try env.put("EMETGATE_CONTEXT", "C:\\launch.epoch");
    const given = (try context_epoch.path(testing.allocator, &env)).?;
    defer testing.allocator.free(given);
    try testing.expectEqualStrings("C:\\launch.epoch", given);
    try env.put("EMETGATE_CONTEXT", "");
    const empty = (try context_epoch.path(testing.allocator, &env)).?;
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings(other, empty);
}

test "context epoch: the hook writes the file the environment names and writes nothing when it names none" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const file = try std.fmt.allocPrint(testing.allocator, "{s}\\made\\by\\hook.epoch", .{root});
    defer testing.allocator.free(file);
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try context_epoch.hook(testing.allocator, testing.io, &env, compact);
    try env.put("EMETGATE_CONTEXT", file);
    try context_epoch.hook(testing.allocator, testing.io, &env, compact);
    const first = try std.Io.Dir.cwd().readFileAlloc(testing.io, file, testing.allocator, .limited(context_epoch.max_epoch_bytes));
    defer testing.allocator.free(first);
    try testing.expect(std.mem.endsWith(u8, first, " " ++ session ++ "\n"));
    try context_epoch.hook(testing.allocator, testing.io, &env, compact);
    const second = try std.Io.Dir.cwd().readFileAlloc(testing.io, file, testing.allocator, .limited(context_epoch.max_epoch_bytes));
    defer testing.allocator.free(second);
    try testing.expect(!std.mem.eql(u8, first, second));
}

test "context epoch: a hook that cannot write reports the error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "blocker", .data = "a file where the folder should be" });
    const file = try std.fmt.allocPrint(testing.allocator, "{s}\\blocker\\e.epoch", .{root});
    defer testing.allocator.free(file);
    if (context_epoch.record(testing.allocator, testing.io, file, compact)) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "context epoch: a served policy watches the epoch unless --mirror trusts it or no environment was given" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("EMETGATE_CONTEXT", "C:\\launch.epoch");

    var watched: server.Served = undefined;
    watched.open(testing.allocator, testing.io, runtime, .{ .mirror_enabled = true }, .{ .root = root, .environ = &env });
    defer watched.close();
    try testing.expectEqualStrings("C:\\launch.epoch", watched.policy.context.?.path.?);

    var trusted: server.Served = undefined;
    trusted.open(testing.allocator, testing.io, runtime, .{ .mirror_enabled = true, .mirror_trusted = true }, .{ .root = root, .environ = &env });
    defer trusted.close();
    try testing.expect(trusted.policy.context == null);

    var bare: server.Served = undefined;
    bare.open(testing.allocator, testing.io, runtime, .{ .mirror_enabled = true }, .{ .root = root });
    defer bare.close();
    try testing.expect(bare.policy.context == null);
}

test "context epoch: --mirror trusts the mirror without an epoch, the default and --no-mirror do not" {
    try testing.expect(!server.parsePolicy(&[_][]const u8{}).?.mirror_trusted);
    try testing.expect(server.parsePolicy(&[_][]const u8{"--mirror"}).?.mirror_trusted);
    try testing.expect(!server.parsePolicy(&[_][]const u8{"--no-mirror"}).?.mirror_trusted);
}

const probe =
    "@if not defined EMETGATE_CONTEXT exit /b 3\r\n" ++
    "@(echo %EMETGATE_CONTEXT%)>>\"%~dp0seen.txt\"\r\n" ++
    "@for %%d in (\"%EMETGATE_CONTEXT%\") do @if not exist \"%%~dpd\" mkdir \"%%~dpd\"\r\n" ++
    "@(echo epoch)>\"%EMETGATE_CONTEXT%\"\r\n" ++
    "@exit /b 9\r\n";

test "lockdown gives each claude launch its own context file under the state folder and removes it after" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "project");
    try tmp.dir.createDirPath(testing.io, "local");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "project/.mcp.json", .data = "{\"mcpServers\":{\"gate\":{\"command\":\"emetgate\",\"args\":[\"mcp\"]}}}" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "claude-probe.cmd", .data = probe });
    const program = try tmp.dir.realPathFileAlloc(testing.io, "claude-probe.cmd", testing.allocator);
    defer testing.allocator.free(program);
    const local = try tmp.dir.realPathFileAlloc(testing.io, "local", testing.allocator);
    defer testing.allocator.free(local);
    var project = try tmp.dir.openDir(testing.io, "project", .{ .iterate = true });
    defer project.close(testing.io);
    var parent = try testing.environ.createMap(testing.allocator);
    defer parent.deinit();
    try parent.put("LOCALAPPDATA", local);
    try parent.put("EMETGATE_CONTEXT", "C:\\not\\this\\launch.epoch");

    const exe = "C:\\tools\\emetgate.exe";
    for (0..2) |_| try testing.expectEqual(@as(u8, 9), try lockdown.launchIn(testing.allocator, testing.io, project, &parent, program, exe, &.{ "-p", "hi" }));
    const seen = try tmp.dir.readFileAlloc(testing.io, "seen.txt", testing.allocator, .limited(8192));
    defer testing.allocator.free(seen);
    const state = try lockdown_slash.stateDir(testing.allocator, local, exe);
    defer testing.allocator.free(state);
    var lines = std.mem.tokenizeAny(u8, seen, "\r\n");
    const first = lines.next().?;
    const second = lines.next().?;
    try testing.expect(!std.mem.eql(u8, first, second));
    for ([_][]const u8{ first, second }) |line| {
        const file = std.mem.trim(u8, line, " ");
        try testing.expect(std.mem.startsWith(u8, file, state));
        try testing.expect(std.mem.endsWith(u8, file, lockdown_slash.context_extension));
        try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, file, .{}));
    }
}
