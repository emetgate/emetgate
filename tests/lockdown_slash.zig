const std = @import("std");
const lockdown = @import("emetgate").lockdown;
const lockdown_slash = @import("emetgate").lockdown_slash;

const testing = std.testing;

const exe = "C:\\Program Files\\emet g\u{e2}te\\emetgate.exe";

test "lockdown slash: the hook is a command in exec form that names this executable" {
    const json = try lockdown_slash.settingsJson(testing.allocator, exe);
    defer testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 1), parsed.value.object.count());
    const events = parsed.value.object.get("hooks").?.object;
    try testing.expectEqual(@as(usize, 1), events.count());
    const groups = events.get("UserPromptSubmit").?.array.items;
    try testing.expectEqual(@as(usize, 1), groups.len);
    try testing.expectEqual(@as(usize, 1), groups[0].object.count());
    const handlers = groups[0].object.get("hooks").?.array.items;
    try testing.expectEqual(@as(usize, 1), handlers.len);
    const handler = handlers[0].object;
    try testing.expectEqual(@as(usize, 3), handler.count());
    try testing.expectEqualStrings("command", handler.get("type").?.string);
    try testing.expectEqualStrings(exe, handler.get("command").?.string);
    const args = handler.get("args").?.array.items;
    try testing.expectEqual(@as(usize, 2), args.len);
    try testing.expectEqualStrings("hook", args[0].string);
    try testing.expectEqualStrings("prompt", args[1].string);
}

fn fileAt(dir: std.Io.Dir, sub_path: []const u8) ![]u8 {
    return dir.readFileAlloc(testing.io, sub_path, testing.allocator, .unlimited);
}

fn countEntries(dir: std.Io.Dir, sub_path: []const u8) !usize {
    var opened = try dir.openDir(testing.io, sub_path, .{ .iterate = true });
    defer opened.close(testing.io);
    var it = opened.iterate();
    var count: usize = 0;
    while (try it.next(testing.io)) |_| count += 1;
    return count;
}

test "lockdown slash: install puts the settings and the command file under emetgate's own directory" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const local = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(local);

    const entry = try lockdown_slash.install(testing.allocator, testing.io, local, exe);
    defer entry.deinit(testing.allocator);

    const prefix = try std.fmt.allocPrint(testing.allocator, "{s}\\emetgate\\lockdown\\", .{local});
    defer testing.allocator.free(prefix);
    try testing.expect(std.mem.startsWith(u8, entry.dir, prefix));
    try testing.expect(std.mem.indexOfAny(u8, entry.dir[prefix.len..], "\\/") == null);
    const settings_want = try std.fmt.allocPrint(testing.allocator, "{s}\\settings.json", .{entry.dir});
    defer testing.allocator.free(settings_want);
    try testing.expectEqualStrings(settings_want, entry.settings);

    const settings = try fileAt(.cwd(), entry.settings);
    defer testing.allocator.free(settings);
    const json = try lockdown_slash.settingsJson(testing.allocator, exe);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(json, settings);

    const command_abs = try std.fmt.allocPrint(testing.allocator, "{s}\\.claude\\commands\\rule.md", .{entry.dir});
    defer testing.allocator.free(command_abs);
    const command = try fileAt(.cwd(), command_abs);
    defer testing.allocator.free(command);
    try testing.expectEqualStrings("---\ndescription: add, list, supersede or forget an emetgate rule\ndisable-model-invocation: true\n---\n", command);
}

test "lockdown slash: a second install repairs a changed file and leaves nothing else behind" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const local = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(local);

    const first = try lockdown_slash.install(testing.allocator, testing.io, local, exe);
    defer first.deinit(testing.allocator);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = first.settings, .data = "{\"hooks\":{}}" });

    const second = try lockdown_slash.install(testing.allocator, testing.io, local, exe);
    defer second.deinit(testing.allocator);
    try testing.expectEqualStrings(first.dir, second.dir);
    const settings = try fileAt(.cwd(), second.settings);
    defer testing.allocator.free(settings);
    const json = try lockdown_slash.settingsJson(testing.allocator, exe);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(json, settings);

    try testing.expectEqual(@as(usize, 2), try countEntries(.cwd(), second.dir));
    const commands = try std.fmt.allocPrint(testing.allocator, "{s}\\.claude\\commands", .{second.dir});
    defer testing.allocator.free(commands);
    try testing.expectEqual(@as(usize, 1), try countEntries(.cwd(), commands));
}

test "lockdown slash: two executables do not share a settings file" {
    const a = try lockdown_slash.stateDir(testing.allocator, "C:\\Users\\u\\AppData\\Local", "C:\\tools\\emetgate.exe");
    defer testing.allocator.free(a);
    const b = try lockdown_slash.stateDir(testing.allocator, "C:\\Users\\u\\AppData\\Local", "D:\\dev\\zig-out\\bin\\emetgate.exe");
    defer testing.allocator.free(b);
    const same = try lockdown_slash.stateDir(testing.allocator, "C:\\Users\\u\\AppData\\Local", "c:/tools/EMETGATE.exe");
    defer testing.allocator.free(same);
    try testing.expect(!std.mem.eql(u8, a, b));
    try testing.expectEqualStrings(a, same);
}

test "lockdown slash: the hook flags come before the lock and the prompt stays the last argument" {
    const locked = try lockdown.buildArgv(testing.allocator, "C:\\repo\\.mcp.json", "mcp__emetgate__emetgate_search", &.{"hello"});
    defer testing.allocator.free(locked);
    var dir = "C:\\state\\k".*;
    var settings = "C:\\state\\k\\settings.json".*;
    const argv = try lockdown_slash.extend(testing.allocator, locked, .{ .dir = &dir, .settings = &settings });
    defer testing.allocator.free(argv);
    const expected = [_][]const u8{ "claude", "--add-dir", "C:\\state\\k", "--settings", "C:\\state\\k\\settings.json", "--tools", "", "--allowedTools", "mcp__emetgate__emetgate_search", "--mcp-config", "C:\\repo\\.mcp.json", "--strict-mcp-config", "hello" };
    try testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |want, got| try testing.expectEqualStrings(want, got);
}

const emetgate_config =
    \\{"mcpServers":{"gate":{"command":"emetgate","args":["mcp"]}}}
;

const probe =
    "@if not \"%~1\"==\"--add-dir\" exit /b 3\r\n" ++
    "@if not \"%~3\"==\"--settings\" exit /b 4\r\n" ++
    "@if not exist \"%~2\\.claude\\commands\\rule.md\" exit /b 5\r\n" ++
    "@if not exist \"%~4\" exit /b 6\r\n" ++
    "@if not \"%~5\"==\"--tools\" exit /b 8\r\n" ++
    "@exit /b 9\r\n";

test "lockdown slash: the launched claude gets the hook settings and the command directory, and the project gains no file" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "project");
    try tmp.dir.createDirPath(testing.io, "local");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "project/.mcp.json", .data = emetgate_config });
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
    try testing.expectEqual(@as(u8, 9), try lockdown.launchIn(testing.allocator, testing.io, project, &parent, program, exe, &.{ "-p", "hi" }));
    try testing.expectEqual(@as(usize, 1), try countEntries(tmp.dir, "project"));
    try testing.expectEqual(@as(usize, 1), try countEntries(tmp.dir, "local"));
}

test "lockdown slash: without a local application data directory lockdown stops by name before claude starts" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".mcp.json", .data = emetgate_config });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "claude-probe.cmd", .data = "@exit /b 9\r\n" });
    const program = try tmp.dir.realPathFileAlloc(testing.io, "claude-probe.cmd", testing.allocator);
    defer testing.allocator.free(program);
    var parent: std.process.Environ.Map = .init(testing.allocator);
    defer parent.deinit();
    try testing.expectError(error.LocalAppDataUnavailable, lockdown.launchIn(testing.allocator, testing.io, tmp.dir, &parent, program, exe, &.{ "-p", "hi" }));
}
