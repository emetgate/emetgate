const std = @import("std");
const builtin = @import("builtin");
const fixture = @import("run_fixture.zig");
const server = @import("emetgate").server;
const run_command = @import("emetgate").run_command;

const testing = std.testing;
const gpa = testing.allocator;

test "run policy: --allow-run collects each command once and keeps the order" {
    const policy = server.parsePolicy(&[_][]const u8{ "--allow-run", "npm test", "--test", "npm test", "--allow-run", "npm run lint", "--allow-run", "npm test" }).?;
    try testing.expectEqual(@as(usize, 2), policy.allowedRuns().len);
    try testing.expectEqualStrings("npm test", policy.allowedRuns()[0]);
    try testing.expectEqualStrings("npm run lint", policy.allowedRuns()[1]);
    try testing.expectEqual(@as(usize, 0), server.parsePolicy(&[_][]const u8{}).?.allowedRuns().len);
}

test "run policy: an --allow-run entry with a shell metacharacter, an install or a commit is refused at startup with its reason" {
    const cases = [_]struct { entry: []const u8, reason: run_command.EntryError }{
        .{ .entry = "npm test & del x", .reason = error.RunCommandShellMetacharacter },
        .{ .entry = "npm test | more", .reason = error.RunCommandShellMetacharacter },
        .{ .entry = "echo %USERPROFILE%", .reason = error.RunCommandShellMetacharacter },
        .{ .entry = "npm install", .reason = error.RunCommandOutOfScope },
        .{ .entry = "pnpm i", .reason = error.RunCommandOutOfScope },
        .{ .entry = "git push", .reason = error.RunCommandOutOfScope },
        .{ .entry = "", .reason = error.RunCommandEmpty },
    };
    for (cases) |c| {
        errdefer std.debug.print("entry: {s}\n", .{c.entry});
        const args = [_][]const u8{ "--allow-run", "npm test", "--allow-run", c.entry };
        try testing.expect(server.parsePolicy(&args) == null);
        const refused = server.refusedRunEntry(&args) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(c.entry, refused.entry);
        try testing.expectEqual(c.reason, refused.reason);
    }
    try testing.expect(server.refusedRunEntry(&[_][]const u8{ "--allow-run", "npm test" }) == null);
    try testing.expect(server.parsePolicy(&[_][]const u8{"--allow-run"}) == null);
}

test "run tool: a call without command lists the allowlist" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try fixture.Repo.init(&.{});
    defer repo.deinit();
    var reply = try fixture.call(fixture.policyWith(repo.root_abs, &.{ "npm test", "npm run lint" }), .{});
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings("allowlist", try reply.string("status"));
    const commands = (try reply.field("commands")).?.array.items;
    try testing.expectEqual(@as(usize, 2), commands.len);
    try testing.expectEqualStrings("npm run lint", commands[1].string);
}

test "run tool: an allowlisted command runs in the shadow and reports its exit code and output" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try fixture.Repo.init(&.{.{ .name = "say.cmd", .body = "@echo off\r\necho hello from the shadow\r\nexit /b 3\r\n" }});
    defer repo.deinit();
    var reply = try fixture.call(fixture.policyWith(repo.root_abs, &.{".\\say.cmd"}), .{ .command = ".\\say.cmd" });
    defer reply.deinit();
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings("ran", try reply.string("status"));
    try testing.expectEqualStrings("exited", try reply.string("outcome"));
    try testing.expectEqual(@as(i64, 3), (try reply.field("exit_code")).?.integer);
    try testing.expectEqualStrings("hello from the shadow\r\n", try reply.string("stdout"));
}

test "run tool: a command the user did not allow is refused and the allowlist comes back" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try fixture.Repo.init(&.{});
    defer repo.deinit();
    var reply = try fixture.call(fixture.policyWith(repo.root_abs, &.{"npm test"}), .{ .command = "npm run build" });
    defer reply.deinit();
    try testing.expect(reply.is_error);
    try testing.expectEqualStrings("refused", try reply.string("status"));
    try testing.expectEqualStrings("not_allowed", try reply.string("reason"));
    try testing.expectEqualStrings("npm test", (try reply.field("allowed")).?.array.items[0].string);
}

test "run tool: the repository's run list counts only with --allow-repo-config" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try fixture.Repo.init(&.{
        .{ .name = ".emetgaterc.json", .body = "{\"run\": [\".\\\\say.cmd\"]}" },
        .{ .name = "say.cmd", .body = "@echo off\r\necho from config\r\n" },
    });
    defer repo.deinit();

    var untrusted = try fixture.call(fixture.policyWith(repo.root_abs, &.{}), .{ .command = ".\\say.cmd" });
    defer untrusted.deinit();
    try testing.expect(untrusted.is_error);
    try testing.expectEqualStrings("not_allowed", try untrusted.string("reason"));

    var policy = fixture.policyWith(repo.root_abs, &.{});
    policy.allow_repo_config = true;
    var trusted = try fixture.call(policy, .{ .command = ".\\say.cmd" });
    defer trusted.deinit();
    errdefer std.debug.print("{s}\n", .{trusted.text});
    try testing.expect(!trusted.is_error);
    try testing.expectEqual(@as(i64, 0), (try trusted.field("exit_code")).?.integer);
}
