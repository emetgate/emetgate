const std = @import("std");
const pretool_hook = @import("emetgate").pretool_hook;

const testing = std.testing;
const Allocating = std.Io.Writer.Allocating;

fn reply(input: []const u8) ![]u8 {
    var out: Allocating = .init(testing.allocator);
    defer out.deinit();
    try pretool_hook.respond(testing.allocator, input, &out.writer);
    return out.toOwnedSlice();
}

fn callJson(tool: []const u8, command: []const u8) ![]u8 {
    var out: Allocating = .init(testing.allocator);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer };
    try js.beginObject();
    try js.objectField("session_id");
    try js.write("s");
    try js.objectField("hook_event_name");
    try js.write("PreToolUse");
    try js.objectField("tool_name");
    try js.write(tool);
    try js.objectField("tool_input");
    try js.beginObject();
    try js.objectField("command");
    try js.write(command);
    try js.endObject();
    try js.objectField("tool_use_id");
    try js.write("toolu_1");
    try js.endObject();
    return out.toOwnedSlice();
}

fn askReason(text: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.object.count());
    const specific = parsed.value.object.get("hookSpecificOutput").?.object;
    try testing.expectEqual(@as(usize, 3), specific.count());
    try testing.expectEqualStrings("PreToolUse", specific.get("hookEventName").?.string);
    try testing.expectEqualStrings("ask", specific.get("permissionDecision").?.string);
    return testing.allocator.dupe(u8, specific.get("permissionDecisionReason").?.string);
}

test "pretool hook: a destructive run asks with the reason and the command part" {
    const input = try callJson("mcp__emetgate__emetgate_run", "npm test && git push --force origin main");
    defer testing.allocator.free(input);
    const out = try reply(input);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.endsWith(u8, out, "}\n"));
    const reason = try askReason(out);
    defer testing.allocator.free(reason);
    try testing.expect(std.mem.indexOf(u8, reason, "git push --force origin main") != null);
    try testing.expect(std.mem.indexOf(u8, reason, "rewrites or deletes remote history") != null);
}

test "pretool hook: any server name in front of emetgate_run is matched" {
    const input = try callJson("mcp__my-repo__emetgate_run", "rm -rf build");
    defer testing.allocator.free(input);
    const out = try reply(input);
    defer testing.allocator.free(out);
    const reason = try askReason(out);
    defer testing.allocator.free(reason);
    try testing.expect(std.mem.indexOf(u8, reason, "rm -rf build") != null);
}

test "pretool hook: an everyday command and another tool print nothing" {
    for ([_][2][]const u8{
        .{ "mcp__emetgate__emetgate_run", "git status" },
        .{ "mcp__emetgate__emetgate_run", "grep -rn 'rm -rf' src" },
        .{ "mcp__emetgate__emetgate_read_file", "rm -rf /" },
        .{ "mcp__emetgate__emetgate_runner", "rm -rf /" },
        .{ "Bash", "rm -rf /" },
    }) |case| {
        const input = try callJson(case[0], case[1]);
        defer testing.allocator.free(input);
        const out = try reply(input);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("", out);
    }
}

test "pretool hook: a run without a command prints nothing" {
    const out = try reply("{\"tool_name\":\"mcp__emetgate__emetgate_run\",\"tool_input\":{}}");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("", out);
}

test "pretool hook: input it cannot read asks instead of passing" {
    for ([_][]const u8{ "", "not json", "[]", "{\"tool_input\":{}}", "{\"tool_name\":\"mcp__emetgate__emetgate_run\",\"tool_input\":{\"command\":7}}" }) |input| {
        const out = try reply(input);
        defer testing.allocator.free(out);
        const reason = try askReason(out);
        defer testing.allocator.free(reason);
        try testing.expectEqualStrings(pretool_hook.unreadable_reason, reason);
    }
}

test "pretool hook: the reply is ASCII even for a command with other characters" {
    const input = try callJson("mcp__emetgate__emetgate_run", "rm -rf d\u{e9}j\u{e0}");
    defer testing.allocator.free(input);
    const out = try reply(input);
    defer testing.allocator.free(out);
    for (out) |c| try testing.expect(c < 0x80);
    const reason = try askReason(out);
    defer testing.allocator.free(reason);
    try testing.expect(std.mem.indexOf(u8, reason, "d\u{e9}j\u{e0}") != null);
}
