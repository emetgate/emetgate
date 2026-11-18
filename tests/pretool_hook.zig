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

test "pretool hook: git am asks like a commit outside the gate, git clean -f asks, and git apply, git mv and am --quit pass like other file writes" {
    for ([_][2][]const u8{
        .{ "git am 0001-fix.patch", "commits patches outside the gate" },
        .{ "npm test && git am --continue", "commits patches outside the gate" },
        .{ "git clean -f", "deletes untracked files" },
    }) |case| {
        const input = try callJson("mcp__emetgate__emetgate_run", case[0]);
        defer testing.allocator.free(input);
        const out = try reply(input);
        defer testing.allocator.free(out);
        const reason = try askReason(out);
        defer testing.allocator.free(reason);
        try testing.expect(std.mem.indexOf(u8, reason, case[1]) != null);
    }
    for ([_][]const u8{ "git apply fix.patch", "git mv a.txt b.txt", "git am --quit", "git am --show-current-patch", "git clean -n" }) |command| {
        const input = try callJson("mcp__emetgate__emetgate_run", command);
        defer testing.allocator.free(input);
        const out = try reply(input);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("", out);
    }
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

test "pretool hook: as_user asks even for an everyday command, and as_user false or a string as_user is judged as it should be" {
    const asked = try reply("{\"tool_name\":\"mcp__emetgate__emetgate_run\",\"tool_input\":{\"command\":\"git status\",\"as_user\":true}}");
    defer testing.allocator.free(asked);
    const reason = try askReason(asked);
    defer testing.allocator.free(reason);
    try testing.expect(std.mem.indexOf(u8, reason, "as_user") != null);
    try testing.expect(std.mem.indexOf(u8, reason, "git status") != null);

    const passed = try reply("{\"tool_name\":\"mcp__emetgate__emetgate_run\",\"tool_input\":{\"command\":\"git status\",\"as_user\":false}}");
    defer testing.allocator.free(passed);
    try testing.expectEqualStrings("", passed);

    const unreadable = try reply("{\"tool_name\":\"mcp__emetgate__emetgate_run\",\"tool_input\":{\"command\":\"git status\",\"as_user\":\"yes\"}}");
    defer testing.allocator.free(unreadable);
    const unreadable_reason = try askReason(unreadable);
    defer testing.allocator.free(unreadable_reason);
    try testing.expectEqualStrings(pretool_hook.unreadable_reason, unreadable_reason);
}

const repo_cwd = "C:\\work\\repo";

fn runIn(command: []const u8, cwd: ?[]const u8, as_user: bool) ![]u8 {
    var input: Allocating = .init(testing.allocator);
    defer input.deinit();
    var js: std.json.Stringify = .{ .writer = &input.writer };
    try js.beginObject();
    try js.objectField("hook_event_name");
    try js.write("PreToolUse");
    if (cwd) |dir| {
        try js.objectField("cwd");
        try js.write(dir);
    }
    try js.objectField("tool_name");
    try js.write("mcp__emetgate__emetgate_run");
    try js.objectField("tool_input");
    try js.beginObject();
    try js.objectField("command");
    try js.write(command);
    if (as_user) {
        try js.objectField("as_user");
        try js.write(true);
    }
    try js.endObject();
    try js.endObject();
    return reply(input.written());
}

fn decision(text: []const u8) !struct { kind: []u8, reason: []u8 } {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    const specific = parsed.value.object.get("hookSpecificOutput").?.object;
    return .{
        .kind = try testing.allocator.dupe(u8, specific.get("permissionDecision").?.string),
        .reason = try testing.allocator.dupe(u8, specific.get("permissionDecisionReason").?.string),
    };
}

fn expectDenied(command: []const u8, cwd: ?[]const u8, named: []const []const u8) !void {
    const out = try runIn(command, cwd, false);
    defer testing.allocator.free(out);
    errdefer std.debug.print("{s}: {s}\n", .{ command, out });
    if (out.len == 0) return error.TestExpectedDenial;
    const got = try decision(out);
    defer testing.allocator.free(got.kind);
    defer testing.allocator.free(got.reason);
    try testing.expectEqualStrings("deny", got.kind);
    try testing.expect(std.mem.indexOf(u8, got.reason, "mcp__emetgate__emetgate_delete") != null);
    try testing.expect(std.mem.indexOf(u8, got.reason, "outside the gate") != null);
    for (named) |file| try testing.expect(std.mem.indexOf(u8, got.reason, file) != null);
}

fn expectNotDenied(command: []const u8) !void {
    const out = try runIn(command, repo_cwd, false);
    defer testing.allocator.free(out);
    errdefer std.debug.print("{s}: {s}\n", .{ command, out });
    if (out.len == 0) return;
    const got = try decision(out);
    defer testing.allocator.free(got.kind);
    defer testing.allocator.free(got.reason);
    try testing.expectEqualStrings("ask", got.kind);
}

test "pretool hook: a plain file delete in the repository is denied with a fix that names emetgate_delete and the files" {
    try expectDenied("del scratch.txt", repo_cwd, &.{ "del scratch.txt", "\"file\":\"scratch.txt\"", "file_hash", "mcp__emetgate__emetgate_read_file" });
    try expectDenied("erase /q a.txt b.txt", repo_cwd, &.{ "a.txt, b.txt", "\"file\":\"b.txt\"" });
    try expectDenied("rm notes.md", repo_cwd, &.{"notes.md"});
    try expectDenied("Remove-Item -Path src\\old.ts", repo_cwd, &.{"old.ts"});
    try expectDenied("git rm src/gone.ts", repo_cwd, &.{"src/gone.ts"});
    try expectDenied("unlink build.log", repo_cwd, &.{"build.log"});
    try expectDenied("del C:\\work\\repo\\x.txt", repo_cwd, &.{"x.txt"});
    try expectDenied("del scratch.txt", null, &.{"scratch.txt"});
    try expectDenied("rmdir old", repo_cwd, &.{ "removes a folder", "empty folder" });
    try expectDenied("del *.log", repo_cwd, &.{ "*.log", "mcp__emetgate__emetgate_list" });
}

test "pretool hook: a delete chained with other commands is denied and the fix says to run the rest without it" {
    try expectDenied("del a.txt && echo done", repo_cwd, &.{ "(del a.txt)", "the rest of the command" });
    try expectDenied("npm test; rm a.txt", repo_cwd, &.{"(rm a.txt)"});
    try expectDenied("npm test || del a.txt", repo_cwd, &.{"a.txt"});
    try expectDenied("dir | del a.txt", repo_cwd, &.{"a.txt"});
    try expectDenied("cmd /c \"del a.txt\"", repo_cwd, &.{"a.txt"});
    try expectDenied("powershell -Command \"Remove-Item a.txt\"", repo_cwd, &.{"a.txt"});
}

test "pretool hook: a delete is denied even with as_user, since it would still bypass the gate" {
    const out = try runIn("del a.txt", repo_cwd, true);
    defer testing.allocator.free(out);
    const got = try decision(out);
    defer testing.allocator.free(got.kind);
    defer testing.allocator.free(got.reason);
    try testing.expectEqualStrings("deny", got.kind);
}

test "pretool hook: mentions of a delete, recursive deletes and deletes outside the repository are not denied" {
    for ([_][]const u8{
        "echo rm a.txt",
        "grep del src",
        "git log --grep=rm",
        "git commit -m \"del a.txt\"",
        "git rm --cached a.txt",
        "git rm -r src",
        "rm -rf build",
        "del /s *.obj",
        "rmdir /s /q build",
        "Remove-Item -Recurse build",
        "Remove-Item a.txt -WhatIf",
        "del ..\\outside.txt",
        "del %TEMP%\\x.txt",
        "del .git\\index.lock",
        "cd .. && del x.txt",
    }) |command| try expectNotDenied(command);
    const recursive = try runIn("rm -rf build", repo_cwd, false);
    defer testing.allocator.free(recursive);
    const got = try decision(recursive);
    defer testing.allocator.free(got.kind);
    defer testing.allocator.free(got.reason);
    try testing.expectEqualStrings("ask", got.kind);
}

test "pretool hook: a recursive git rm asks the user and names it, and an index-only one passes" {
    const out = try runIn("git rm -r src", repo_cwd, false);
    defer testing.allocator.free(out);
    const got = try decision(out);
    defer testing.allocator.free(got.kind);
    defer testing.allocator.free(got.reason);
    try testing.expectEqualStrings("ask", got.kind);
    try testing.expect(std.mem.indexOf(u8, got.reason, "git rm -r src") != null);
    try testing.expect(std.mem.indexOf(u8, got.reason, "deletes tracked files recursively") != null);
    const cached = try runIn("git rm --cached -r src", repo_cwd, false);
    defer testing.allocator.free(cached);
    try testing.expectEqualStrings("", cached);
}
