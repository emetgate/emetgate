const std = @import("std");
const lockdown = @import("emetgate").lockdown;

const testing = std.testing;

test "lockdown argv allows only ToolSearch and the strict .mcp.json servers, then the user's args" {
    const argv = try lockdown.buildArgv(testing.allocator, "C:\\repo\\.mcp.json", &.{ "-p", "fix the bug" });
    defer testing.allocator.free(argv);
    const expected = [_][]const u8{ "claude", "--tools", "ToolSearch", "--mcp-config", "C:\\repo\\.mcp.json", "--strict-mcp-config", "-p", "fix the bug" };
    try testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |want, got| try testing.expectEqualStrings(want, got);
}

test "a positional prompt right after lockdown is not swallowed by a variadic flag" {
    const argv = try lockdown.buildArgv(testing.allocator, "cfg", &.{"hello"});
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
        try testing.expectError(error.LockdownFlagOverride, lockdown.buildArgv(testing.allocator, "cfg", &.{flag}));
    }
}

const Parsed = struct {
    tools: std.ArrayList([]const u8) = .empty,
    configs: std.ArrayList([]const u8) = .empty,
    positional: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *Parsed) void {
        self.tools.deinit(testing.allocator);
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
        const list: ?*std.ArrayList([]const u8) = if (std.mem.eql(u8, arg, "--tools")) &parsed.tools else if (std.mem.eql(u8, arg, "--mcp-config")) &parsed.configs else null;
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
        const argv = try lockdown.buildArgv(testing.allocator, "C:\\repo\\.mcp.json", passthrough);
        defer testing.allocator.free(argv);
        var parsed = try parseLikeClaude(argv);
        defer parsed.deinit();
        try testing.expectEqual(@as(usize, 1), parsed.tools.items.len);
        try testing.expectEqualStrings("ToolSearch", parsed.tools.items[0]);
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
    try testing.expectError(error.LockdownFlagOverride, lockdown.launchIn(testing.allocator, testing.io, tmp.dir, &.{ "--tools", "default" }));
    try testing.expectError(error.McpConfigMissing, lockdown.launchIn(testing.allocator, testing.io, tmp.dir, &.{ "-p", "hi" }));
}

test "ordinary claude args pass through the lock" {
    try lockdown.refuseReserved(&.{ "-p", "hi", "--output-format", "stream-json", "--verbose", "--max-turns", "1", "--toolsy" });
}
