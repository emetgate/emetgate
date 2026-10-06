const std = @import("std");
const lockdown = @import("emetgate").lockdown;
const lockdown_marks = @import("emetgate").lockdown_marks;
const lockdown_slash = @import("emetgate").lockdown_slash;

const testing = std.testing;

const exe = "C:\\Program Files\\emet g\u{e2}te\\emetgate.exe";

fn fileAt(dir: std.Io.Dir, sub_path: []const u8) ![]u8 {
    return dir.readFileAlloc(testing.io, sub_path, testing.allocator, .unlimited);
}

fn countFiles(dir: std.Io.Dir, sub_path: []const u8) !usize {
    var opened = try dir.openDir(testing.io, sub_path, .{ .iterate = true });
    defer opened.close(testing.io);
    var walker = try opened.walk(testing.allocator);
    defer walker.deinit();
    var count: usize = 0;
    while (try walker.next(testing.io)) |entry| {
        if (entry.kind == .file) count += 1;
    }
    return count;
}

test "lockdown marks: --no-marks as the first argument turns the plugin off and is not passed on" {
    const off = lockdown_marks.choose(&.{ "--no-marks", "-p", "hi" });
    try testing.expect(!off.wanted);
    try testing.expectEqual(@as(usize, 2), off.rest.len);
    try testing.expectEqualStrings("-p", off.rest[0]);
    try testing.expectEqualStrings("hi", off.rest[1]);
}

test "lockdown marks: without the flag the plugin is on and every argument is passed on" {
    const on = lockdown_marks.choose(&.{ "-p", "hi" });
    try testing.expect(on.wanted);
    try testing.expectEqual(@as(usize, 2), on.rest.len);
    const none = lockdown_marks.choose(&.{});
    try testing.expect(none.wanted);
    try testing.expectEqual(@as(usize, 0), none.rest.len);
}

test "lockdown marks: the flag anywhere but first is the user's own argument" {
    const later = lockdown_marks.choose(&.{ "-p", "--no-marks" });
    try testing.expect(later.wanted);
    try testing.expectEqual(@as(usize, 2), later.rest.len);
    try testing.expectEqualStrings("--no-marks", later.rest[1]);
}

test "lockdown marks: the plugin is a manifest, one hooks module and the files that module imports" {
    var manifest: ?[]const u8 = null;
    var hooks: ?[]const u8 = null;
    var has_register = false;
    var has_scene = false;
    var has_types = false;
    for (lockdown_marks.files) |file| {
        try testing.expect(file.data.len > 0);
        try testing.expect(std.mem.indexOfScalar(u8, file.data, '\r') == null);
        if (std.mem.eql(u8, file.path, ".claude-plugin\\plugin.json")) manifest = file.data;
        if (std.mem.eql(u8, file.path, "hooks\\hooks.json")) hooks = file.data;
        if (std.mem.eql(u8, file.path, "hooks\\register.tsx")) has_register = true;
        if (std.mem.eql(u8, file.path, "hooks\\scene.ts")) has_scene = true;
        if (std.mem.eql(u8, file.path, "types\\index.d.ts")) has_types = true;
    }
    try testing.expectEqual(@as(usize, 5), lockdown_marks.files.len);
    try testing.expect(has_register and has_scene and has_types);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, manifest.?, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("emetgate-marks", parsed.value.object.get("name").?.string);
    try testing.expectEqualStrings("./types/index.d.ts", parsed.value.object.get("types").?.string);

    const modules = try std.json.parseFromSlice(std.json.Value, testing.allocator, hooks.?, .{});
    defer modules.deinit();
    const list = modules.value.object.get("modules").?.array.items;
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqualStrings("./register.tsx", list[0].string);
}

test "lockdown marks: the plugin registers no tool and sends nothing to the model" {
    for (lockdown_marks.files) |file| {
        for ([_][]const u8{ "$.tool.register", "$.model.", "$.prompt.fill", "$.prompt.suggest", "prompt.compose", "$.http.", "$.process.", "$.fs.", "$.env." }) |call| {
            try testing.expect(std.mem.indexOf(u8, file.data, call) == null);
        }
    }
}

test "lockdown marks: install writes every file byte for byte under the marks directory" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const state = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(state);

    const dir = try lockdown_marks.install(testing.allocator, testing.io, state);
    defer testing.allocator.free(dir);
    const want = try std.fmt.allocPrint(testing.allocator, "{s}\\marks", .{state});
    defer testing.allocator.free(want);
    try testing.expectEqualStrings(want, dir);

    for (lockdown_marks.files) |file| {
        const sub = try std.fmt.allocPrint(testing.allocator, "marks\\{s}", .{file.path});
        defer testing.allocator.free(sub);
        const got = try fileAt(tmp.dir, sub);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(file.data, got);
    }
    try testing.expectEqual(lockdown_marks.files.len, try countFiles(tmp.dir, "marks"));
}

test "lockdown marks: a second install repairs a changed file and leaves nothing else behind" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const state = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(state);

    const first = try lockdown_marks.install(testing.allocator, testing.io, state);
    defer testing.allocator.free(first);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "marks\\hooks\\register.tsx", .data = "changed" });

    const second = try lockdown_marks.install(testing.allocator, testing.io, state);
    defer testing.allocator.free(second);
    const got = try fileAt(tmp.dir, "marks\\hooks\\register.tsx");
    defer testing.allocator.free(got);
    try testing.expect(!std.mem.eql(u8, got, "changed"));
    try testing.expect(std.mem.indexOf(u8, got, "export const register") != null);
    try testing.expectEqual(lockdown_marks.files.len, try countFiles(tmp.dir, "marks"));
}

test "lockdown marks: the plugin flag comes after the lock and the user's arguments stay last" {
    const locked = try lockdown.buildArgv(testing.allocator, "C:\\repo\\.mcp.json", "mcp__emetgate__emetgate_search", &.{ "-p", "hello" });
    defer testing.allocator.free(locked);
    const argv = try lockdown_marks.extend(testing.allocator, locked, 2, "C:\\state\\k\\marks");
    defer testing.allocator.free(argv);
    const expected = [_][]const u8{ "claude", "--tools", "", "--allowedTools", "mcp__emetgate__emetgate_search", "--mcp-config", "C:\\repo\\.mcp.json", "--strict-mcp-config", "--plugin-dir", "C:\\state\\k\\marks", "-p", "hello" };
    try testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |want, got| try testing.expectEqualStrings(want, got);
}

test "lockdown marks: with no user argument the plugin flag is the last pair" {
    const locked = try lockdown.buildArgv(testing.allocator, "C:\\repo\\.mcp.json", "x", &.{});
    defer testing.allocator.free(locked);
    const argv = try lockdown_marks.extend(testing.allocator, locked, 0, "C:\\m");
    defer testing.allocator.free(argv);
    try testing.expectEqual(locked.len + 2, argv.len);
    try testing.expectEqualStrings("--plugin-dir", argv[argv.len - 2]);
    try testing.expectEqualStrings("C:\\m", argv[argv.len - 1]);
}

test "lockdown marks: the user cannot name a plugin directory of their own" {
    try testing.expectError(error.LockdownFlagOverride, lockdown.refuseReserved(&.{ "--plugin-dir", "C:\\evil" }));
    try testing.expectError(error.LockdownFlagOverride, lockdown.refuseReserved(&.{"--plugin-dir=C:\\evil"}));
}

const emetgate_config =
    \\{"mcpServers":{"gate":{"command":"emetgate","args":["mcp"]}}}
;

const walk =
    "@set n=0\r\n" ++
    "@set seen=0\r\n" ++
    "@set right=0\r\n" ++
    "@set hook=0\r\n" ++
    ":next\r\n" ++
    "@set /a n+=1\r\n" ++
    "@if \"%~1\"==\"--no-marks\" exit /b 4\r\n" ++
    "@if \"%~1\"==\"--settings\" set hook=1\r\n" ++
    "@if \"%~1\"==\"--plugin-dir\" set seen=1\r\n" ++
    "@if \"%~1\"==\"--strict-mcp-config\" if \"%~2\"==\"--plugin-dir\" if \"%~4\"==\"-p\" set right=1\r\n" ++
    "@shift\r\n" ++
    "@if %n% lss 24 goto next\r\n" ++
    "@if %hook%==0 exit /b 5\r\n";

const probe = walk ++
    "@if not %right%==1 exit /b 3\r\n" ++
    "@exit /b 9\r\n";

const probe_off = walk ++
    "@if not %seen%==0 exit /b 3\r\n" ++
    "@exit /b 9\r\n";

const Launch = struct {
    tmp: testing.TmpDir,
    program: [:0]u8,
    local: [:0]u8,
    project: std.Io.Dir,
    parent: std.process.Environ.Map,

    fn init(script: []const u8) !Launch {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "project");
        try tmp.dir.createDirPath(testing.io, "local");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "project/.mcp.json", .data = emetgate_config });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "claude-probe.cmd", .data = script });
        const program = try tmp.dir.realPathFileAlloc(testing.io, "claude-probe.cmd", testing.allocator);
        errdefer testing.allocator.free(program);
        const local = try tmp.dir.realPathFileAlloc(testing.io, "local", testing.allocator);
        errdefer testing.allocator.free(local);
        var parent = try testing.environ.createMap(testing.allocator);
        errdefer parent.deinit();
        try parent.put("LOCALAPPDATA", local);
        return .{ .tmp = tmp, .program = program, .local = local, .project = try tmp.dir.openDir(testing.io, "project", .{ .iterate = true }), .parent = parent };
    }

    fn deinit(self: *Launch) void {
        self.project.close(testing.io);
        self.parent.deinit();
        testing.allocator.free(self.local);
        testing.allocator.free(self.program);
        self.tmp.cleanup();
    }

    fn marksManifest(self: *Launch) ![]u8 {
        const state = try lockdown_slash.stateDir(testing.allocator, self.local, exe);
        defer testing.allocator.free(state);
        return std.fmt.allocPrint(testing.allocator, "{s}\\marks\\.claude-plugin\\plugin.json", .{state});
    }
};

test "lockdown marks: the launched claude gets the plugin directory right after the lock, and the project gains no file" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var case = try Launch.init(probe);
    defer case.deinit();

    try testing.expectEqual(@as(u8, 9), try lockdown.launchIn(testing.allocator, testing.io, case.project, &case.parent, case.program, exe, &.{ "-p", "hi" }));
    const manifest = try case.marksManifest();
    defer testing.allocator.free(manifest);
    const got = try std.Io.Dir.cwd().readFileAlloc(testing.io, manifest, testing.allocator, .unlimited);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(lockdown_marks.files[0].data, got);
    try testing.expectEqual(@as(usize, 1), try countFiles(case.tmp.dir, "project"));
}

test "lockdown marks: with --no-marks claude gets no plugin directory, no plugin file is written and the hook stays" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var case = try Launch.init(probe_off);
    defer case.deinit();

    try testing.expectEqual(@as(u8, 9), try lockdown.launchIn(testing.allocator, testing.io, case.project, &case.parent, case.program, exe, &.{ "--no-marks", "-p", "hi" }));
    const manifest = try case.marksManifest();
    defer testing.allocator.free(manifest);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, manifest, .{}));
    try testing.expectEqual(@as(usize, 1), try countFiles(case.tmp.dir, "project"));
}

test "lockdown marks: a lock override after --no-marks is still refused" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var case = try Launch.init(probe_off);
    defer case.deinit();
    try testing.expectError(error.LockdownFlagOverride, lockdown.launchIn(testing.allocator, testing.io, case.project, &case.parent, case.program, exe, &.{ "--no-marks", "--plugin-dir", "C:\\evil" }));
}
