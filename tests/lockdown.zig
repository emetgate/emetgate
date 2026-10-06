const std = @import("std");
const lockdown = @import("emetgate").lockdown;
const server = @import("emetgate").server;

const testing = std.testing;

const allowed = "mcp__emetgate__emetgate_search mcp__emetgate__emetgate_read_file";

test "lockdown argv allows no built-in tool and only the strict .mcp.json servers, then the user's args" {
    const argv = try lockdown.buildArgv(testing.allocator, "C:\\repo\\.mcp.json", allowed, &.{ "-p", "fix the bug" });
    defer testing.allocator.free(argv);
    const expected = [_][]const u8{ "claude", "--tools", "", "--allowedTools", allowed, "--mcp-config", "C:\\repo\\.mcp.json", "--strict-mcp-config", "-p", "fix the bug" };
    try testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |want, got| try testing.expectEqualStrings(want, got);
}

test "a positional prompt right after lockdown is not swallowed by a variadic flag" {
    const argv = try lockdown.buildArgv(testing.allocator, "cfg", allowed, &.{"hello"});
    defer testing.allocator.free(argv);
    try testing.expectEqualStrings("--strict-mcp-config", argv[argv.len - 2]);
    try testing.expectEqualStrings("hello", argv[argv.len - 1]);
}

test "a passthrough arg that would override the lock is refused in both spellings" {
    const reserved = [_][]const u8{
        "--tools",
        "--allowedTools",
        "--allowed-tools",
        "--mcp-config",
        "--strict-mcp-config",
        "--settings",
        "--plugin-dir",
        "--agents",
        "--dangerously-skip-permissions",
        "--allow-dangerously-skip-permissions",
    };
    for (reserved) |flag| {
        try testing.expectError(error.LockdownFlagOverride, lockdown.refuseReserved(&.{ "-p", "x", flag, "default" }));
        const joined = try std.fmt.allocPrint(testing.allocator, "{s}=default", .{flag});
        defer testing.allocator.free(joined);
        try testing.expectError(error.LockdownFlagOverride, lockdown.refuseReserved(&.{joined}));
        try testing.expectError(error.LockdownFlagOverride, lockdown.buildArgv(testing.allocator, "cfg", allowed, &.{flag}));
    }
}

const Parsed = struct {
    tools: std.ArrayList([]const u8) = .empty,
    allowed: std.ArrayList([]const u8) = .empty,
    configs: std.ArrayList([]const u8) = .empty,
    positional: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *Parsed) void {
        self.tools.deinit(testing.allocator);
        self.allowed.deinit(testing.allocator);
        self.configs.deinit(testing.allocator);
        self.positional.deinit(testing.allocator);
    }
};

fn parseLikeClaude(argv: []const []const u8) !Parsed {
    var parsed: Parsed = .{};
    errdefer parsed.deinit();
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        const list: ?*std.ArrayList([]const u8) = if (std.mem.eql(u8, arg, "--tools")) &parsed.tools else if (std.mem.eql(u8, arg, "--allowedTools")) &parsed.allowed else if (std.mem.eql(u8, arg, "--mcp-config")) &parsed.configs else null;
        if (list) |values| {
            while (i + 1 < argv.len and !std.mem.startsWith(u8, argv[i + 1], "-")) : (i += 1) try values.append(testing.allocator, argv[i + 1]);
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try parsed.positional.append(testing.allocator, arg);
        }
    }
    return parsed;
}

test "a user prompt never becomes a --tools or --mcp-config value" {
    const cases = [_][]const []const u8{
        &.{"fix the bug"},
        &.{ "fix the bug", "-p" },
        &.{ "-p", "fix the bug" },
        &.{ "fix", "the", "bug", "--verbose" },
    };
    for (cases) |passthrough| {
        const argv = try lockdown.buildArgv(testing.allocator, "C:\\repo\\.mcp.json", allowed, passthrough);
        defer testing.allocator.free(argv);
        var parsed = try parseLikeClaude(argv);
        defer parsed.deinit();
        try testing.expectEqual(@as(usize, 1), parsed.tools.items.len);
        try testing.expectEqualStrings("", parsed.tools.items[0]);
        try testing.expectEqual(@as(usize, 1), parsed.allowed.items.len);
        try testing.expectEqualStrings(allowed, parsed.allowed.items[0]);
        try testing.expectEqual(@as(usize, 1), parsed.configs.items.len);
        try testing.expectEqualStrings("C:\\repo\\.mcp.json", parsed.configs.items[0]);
        var expected_positional: usize = 0;
        for (passthrough) |arg| {
            if (!std.mem.startsWith(u8, arg, "-")) expected_positional += 1;
        }
        try testing.expectEqual(expected_positional, parsed.positional.items.len);
    }
}

test "lockdown refuses to launch when the directory has no .mcp.json" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expectError(error.McpConfigMissing, lockdown.resolveMcpConfig(testing.allocator, testing.io, tmp.dir));

    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".mcp.json", .data = "{\"mcpServers\":{}}" });
    const found = try lockdown.resolveMcpConfig(testing.allocator, testing.io, tmp.dir);
    defer testing.allocator.free(found);
    try testing.expect(std.mem.endsWith(u8, found, ".mcp.json"));
}

test "a lock override is refused before .mcp.json is looked up" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var parent: std.process.Environ.Map = .init(testing.allocator);
    defer parent.deinit();
    try testing.expectError(error.LockdownFlagOverride, lockdown.launchIn(testing.allocator, testing.io, tmp.dir, &parent, lockdown.claude_program, "C:/tools/emetgate.exe", &.{ "--tools", "default" }));
    try testing.expectError(error.McpConfigMissing, lockdown.launchIn(testing.allocator, testing.io, tmp.dir, &parent, lockdown.claude_program, "C:/tools/emetgate.exe", &.{ "-p", "hi" }));
}

test "ordinary claude args pass through the lock" {
    try lockdown.refuseReserved(&.{ "-p", "hi", "--output-format", "stream-json", "--verbose", "--max-turns", "1", "--toolsy" });
}

const gated_tools = [_][]const u8{
    "emetgate_try",
    "emetgate_try_batch",
    "emetgate_write_doc",
    "emetgate_rename",
    "emetgate_move",
    "emetgate_move_file",
    "emetgate_run",
};

fn listed(list: []const []const u8, name: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, name)) return true;
    }
    return false;
}

test "lockdown pre-allows only emetgate tools that neither write to the repo nor run a command" {
    for (lockdown.read_only_tools) |tool| try testing.expect(!listed(&gated_tools, tool));
    const value = try lockdown.allowedTools(testing.allocator, "emetgate");
    defer testing.allocator.free(value);
    const prefix = "mcp__emetgate__";
    var names = std.mem.splitScalar(u8, value, ' ');
    var count: usize = 0;
    while (names.next()) |name| : (count += 1) {
        try testing.expect(std.mem.startsWith(u8, name, prefix));
        try testing.expect(!listed(&gated_tools, name[prefix.len..]));
        try testing.expect(listed(&lockdown.read_only_tools, name[prefix.len..]));
    }
    try testing.expectEqual(lockdown.read_only_tools.len, count);
}

test "every emetgate tool is either pre-allowed by lockdown or left to the permission mode" {
    for (server.tool_defs) |tool| try testing.expect(listed(&lockdown.read_only_tools, tool.name) != listed(&gated_tools, tool.name));
    for (lockdown.read_only_tools) |name| {
        var served = false;
        for (server.tool_defs) |tool| served = served or std.mem.eql(u8, tool.name, name);
        try testing.expect(served);
    }
}

const emetgate_config =
    \\{"mcpServers":{"docs":{"command":"node","args":["docs-server.js"]},"gate":{"command":"C:/tools/Emetgate.EXE","args":["mcp","--test","npm test"]}}}
;

test "the allow-list names the emetgate server by its .mcp.json key" {
    const name = try lockdown.emetgateServer(testing.allocator, emetgate_config);
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("gate", name);
    const value = try lockdown.allowedTools(testing.allocator, name);
    defer testing.allocator.free(value);
    try testing.expect(std.mem.startsWith(u8, value, "mcp__gate__emetgate_explore mcp__gate__emetgate_evidence mcp__gate__emetgate_symbols mcp__gate__emetgate_skeleton "));
    try testing.expect(std.mem.endsWith(u8, value, " mcp__gate__emetgate_mutate"));
}

test "a server key becomes the tool name prefix claude derives from it" {
    const cases = [_][2][]const u8{
        .{ "emetgate", "emetgate" },
        .{ "emet-gate_2", "emet-gate_2" },
        .{ "emet.gate dev", "emet_gate_dev" },
        .{ "g\u{e5}te", "g_te" },
        .{ "gate\u{1f600}", "gate__" },
        .{ "claude.ai  Gate!", "claude_ai_Gate" },
    };
    for (cases) |case| {
        const got = try lockdown.toolNamePart(testing.allocator, case[0]);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(case[1], got);
    }
}

test "lockdown refuses a .mcp.json without exactly one emetgate server" {
    const gpa = testing.allocator;
    try testing.expectError(error.NoEmetgateServer, lockdown.emetgateServer(gpa, "{\"mcpServers\":{}}"));
    try testing.expectError(error.NoEmetgateServer, lockdown.emetgateServer(gpa, "{}"));
    try testing.expectError(error.NoEmetgateServer, lockdown.emetgateServer(gpa, "{\"mcpServers\":{\"gate\":{\"command\":\"emetgate\",\"args\":[\"--version\"]}}}"));
    try testing.expectError(error.NoEmetgateServer, lockdown.emetgateServer(gpa, "{\"mcpServers\":{\"gate\":{\"command\":\"emetgate-old\",\"args\":[\"mcp\"]}}}"));
    try testing.expectError(error.SeveralEmetgateServers, lockdown.emetgateServer(gpa, "{\"mcpServers\":{\"a\":{\"command\":\"emetgate\",\"args\":[\"mcp\"]},\"b\":{\"command\":\"D:\\\\bin\\\\emetgate.exe\",\"args\":[\"serve\"]}}}"));
    try testing.expectError(error.McpConfigInvalid, lockdown.emetgateServer(gpa, "{\"mcpServers\":[]}"));
    try testing.expectError(error.McpConfigInvalid, lockdown.emetgateServer(gpa, "{\"mcpServers\":{\"gate\":{\"command\":\"emetgate\",\"args\":[\"mcp\"]},\"gate\":{\"command\":\"node\",\"args\":[]}}}"));
    try testing.expectError(error.McpConfigInvalid, lockdown.emetgateServer(gpa, "not json"));

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".mcp.json", .data = "{\"mcpServers\":{\"docs\":{\"command\":\"node\",\"args\":[\"docs-server.js\"]}}}" });
    var parent: std.process.Environ.Map = .init(gpa);
    defer parent.deinit();
    try testing.expectError(error.NoEmetgateServer, lockdown.launchIn(gpa, testing.io, tmp.dir, &parent, lockdown.claude_program, "C:/tools/emetgate.exe", &.{ "-p", "hi" }));
}

test "the child environment turns tool search off and keeps the rest" {
    var parent: std.process.Environ.Map = .init(testing.allocator);
    defer parent.deinit();
    try parent.put("PATH", "C:\\tools");
    try parent.put("ENABLE_TOOL_SEARCH", "true");
    var child = try lockdown.childEnviron(testing.allocator, &parent);
    defer child.deinit();
    try testing.expectEqualStrings("false", child.get("ENABLE_TOOL_SEARCH").?);
    try testing.expectEqualStrings("C:\\tools", child.get("PATH").?);
    try testing.expectEqualStrings("true", parent.get("ENABLE_TOOL_SEARCH").?);
}

test "the launched claude gets ENABLE_TOOL_SEARCH=false whatever the parent had" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".mcp.json", .data = emetgate_config });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "claude-probe.cmd", .data = "@if \"%ENABLE_TOOL_SEARCH%\"==\"false\" exit /b 7\r\n@exit /b 3\r\n" });
    const program = try tmp.dir.realPathFileAlloc(testing.io, "claude-probe.cmd", testing.allocator);
    defer testing.allocator.free(program);
    var parent = try testing.environ.createMap(testing.allocator);
    defer parent.deinit();
    try parent.put("ENABLE_TOOL_SEARCH", "true");
    const local = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(local);
    try parent.put("LOCALAPPDATA", local);
    try testing.expectEqual(@as(u8, 7), try lockdown.launchIn(testing.allocator, testing.io, tmp.dir, &parent, program, "C:/tools/emetgate.exe", &.{ "-p", "hi" }));
}

test "lockdown refuses the bypassPermissions mode in both spellings" {
    try testing.expectError(error.LockdownFlagOverride, lockdown.refuseReserved(&.{ "-p", "hi", "--permission-mode", "bypassPermissions" }));
    try testing.expectError(error.LockdownFlagOverride, lockdown.refuseReserved(&.{"--permission-mode=bypassPermissions"}));
    try testing.expectError(error.LockdownFlagOverride, lockdown.buildArgv(testing.allocator, "cfg", allowed, &.{ "--permission-mode", "bypassPermissions", "-p", "hi" }));
}

test "the other permission modes pass through the lock" {
    const modes = [_][]const u8{ "acceptEdits", "auto", "manual", "dontAsk", "plan" };
    for (modes) |mode| {
        try lockdown.refuseReserved(&.{ "-p", "hi", "--permission-mode", mode });
        const joined = try std.fmt.allocPrint(testing.allocator, "--permission-mode={s}", .{mode});
        defer testing.allocator.free(joined);
        try lockdown.refuseReserved(&.{joined});
    }
    try lockdown.refuseReserved(&.{ "-p", "bypassPermissions" });
    try lockdown.refuseReserved(&.{"--permission-mode"});
}

test "the bypassPermissions refusal does not depend on letter case" {
    const spellings = [_][]const u8{ "BypassPermissions", "bypasspermissions", "BYPASSPERMISSIONS" };
    for (spellings) |mode| {
        try testing.expectError(error.LockdownFlagOverride, lockdown.refuseReserved(&.{ "--permission-mode", mode }));
        const joined = try std.fmt.allocPrint(testing.allocator, "--permission-mode={s}", .{mode});
        defer testing.allocator.free(joined);
        try testing.expectError(error.LockdownFlagOverride, lockdown.refuseReserved(&.{joined}));
    }
}
