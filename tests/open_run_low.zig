const std = @import("std");
const builtin = @import("builtin");
const fixture = @import("run_fixture.zig");
const emetgate = @import("emetgate");
const server = emetgate.server;
const sandbox = emetgate.sandbox;
const low_run = emetgate.low_run;
const command_danger = emetgate.command_danger;
const run_command = emetgate.run_command;
const open_shell = emetgate.open_shell;

const testing = std.testing;
const gpa = testing.allocator;

fn openPolicy(root_abs: []const u8) server.Policy {
    var policy: server.Policy = .{ .root = root_abs };
    policy.open_run = true;
    return policy;
}

fn slashed(path: []const u8) ![]u8 {
    const out = try gpa.dupe(u8, path);
    std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
}

fn writeOutside(repo: *fixture.Repo, name: []const u8) ![]u8 {
    const top = try slashed(repo.top_abs);
    defer gpa.free(top);
    return std.fmt.allocPrint(gpa, "echo hi > {s}/{s}", .{ top, name });
}

fn envValue(env: []const sandbox.EnvVar, name: []const u8) ?[]const u8 {
    for (env) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.value;
    }
    return null;
}

test "lockdown run: a command cannot write outside the repository but writes inside it, and the reply says the refusal may come from low integrity" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try fixture.Repo.init(&.{});
    defer repo.deinit();
    const policy = openPolicy(repo.root_abs);

    var inside = try fixture.call(policy, .{ .command = "echo hi > inside_new.txt" });
    defer inside.deinit();
    errdefer std.debug.print("{s}\n", .{inside.text});
    try testing.expectEqualStrings("ran", try inside.string("status"));
    try testing.expectEqualStrings("low", try inside.string("integrity"));
    try testing.expectEqual(@as(i64, 0), (try inside.field("exit_code")).?.integer);
    try testing.expect(repo.exists("repo/inside_new.txt"));

    const command = try writeOutside(&repo, "outside_new.txt");
    defer gpa.free(command);
    var outside = try fixture.call(policy, .{ .command = command });
    defer outside.deinit();
    errdefer std.debug.print("{s}\n", .{outside.text});
    try testing.expectEqualStrings("ran", try outside.string("status"));
    try testing.expectEqualStrings("low", try outside.string("integrity"));
    try testing.expect((try outside.field("exit_code")).?.integer != 0);
    try testing.expect(!repo.exists("outside_new.txt"));
    try testing.expectEqualStrings(low_run.denied_note, try outside.string("low_integrity_note"));
}

test "lockdown run: the repository root keeps a low-write label after the run" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try fixture.Repo.init(&.{});
    defer repo.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expect(!try low_run.lowWritable(arena, repo.root_abs));
    var reply = try fixture.call(openPolicy(repo.root_abs), .{ .command = "echo hi" });
    defer reply.deinit();
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expectEqualStrings("ran", try reply.string("status"));
    try testing.expect(try low_run.lowWritable(arena, repo.root_abs));
}

test "lockdown run: package caches point under the emetgate cache and TEMP is a labelled folder of its own" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try fixture.Repo.init(&.{});
    defer repo.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const place = try low_run.prepare(arena, gpa, testing.io, repo.root_abs, &.{});
    defer emetgate.shadow.clearTemp(testing.io, place.temp) catch {};
    const data = try emetgate.cache_lease.defaultDataDir(gpa);
    defer gpa.free(data);
    const cache = try std.fmt.allocPrint(arena, "{s}\\{s}\\", .{ data, low_run.cache_family });
    const temp_parent = try std.fmt.allocPrint(arena, "{s}\\{s}\\", .{ data, low_run.temp_family });
    try testing.expect(std.mem.startsWith(u8, place.temp, temp_parent));
    try testing.expect(try low_run.lowWritable(arena, place.temp));
    for ([_][]const u8{ "NUGET_PACKAGES", "npm_config_cache", "DOTNET_CLI_HOME" }) |name| {
        const value = envValue(place.env, name) orelse return error.CacheVariableMissing;
        try testing.expect(std.mem.startsWith(u8, value, cache));
    }
}

test "outside lockdown a run writes outside the repository with the user's rights" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try fixture.Repo.init(&.{});
    defer repo.deinit();
    const shell = try open_shell.find(gpa, repo.root_abs);
    defer shell.deinit(gpa);
    const command = try writeOutside(&repo, "outside_user.txt");
    defer gpa.free(command);
    const ran = try run_command.runOpenInRepo(gpa, testing.io, repo.root_abs, shell, command, .{}, "test", .{});
    defer ran.report.deinit(gpa);
    defer ran.frozen.deinit(gpa);
    try testing.expect(ran.report.passed());
    try testing.expect(repo.exists("outside_user.txt"));
}

test "lockdown run: without a low token the command does not run" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try fixture.Repo.init(&.{});
    defer repo.deinit();
    defer sandbox.injected_fault = null;
    sandbox.injected_fault = .restrict;
    var reply = try fixture.call(openPolicy(repo.root_abs), .{ .command = "echo hi > inside_fault.txt" });
    defer reply.deinit();
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expectEqualStrings("not_run", try reply.string("status"));
    try testing.expectEqualStrings("SandboxUnavailable", try reply.string("reason"));
    try testing.expect(!repo.exists("repo/inside_fault.txt"));
}

test "lockdown run: as_user writes outside the repository with the user's rights" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try fixture.Repo.init(&.{});
    defer repo.deinit();
    const command = try writeOutside(&repo, "outside_as_user.txt");
    defer gpa.free(command);
    var reply = try fixture.call(openPolicy(repo.root_abs), .{ .command = command, .as_user = true });
    defer reply.deinit();
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expectEqualStrings("user", try reply.string("integrity"));
    try testing.expectEqual(@as(i64, 0), (try reply.field("exit_code")).?.integer);
    try testing.expect(repo.exists("outside_as_user.txt"));
}

test "lockdown run: a plain git fetch runs with the user's rights for the credential manager" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try fixture.Repo.init(&.{});
    defer repo.deinit();
    var reply = try fixture.call(openPolicy(repo.root_abs), .{ .command = "git fetch --all" });
    defer reply.deinit();
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expectEqualStrings("ran", try reply.string("status"));
    try testing.expectEqualStrings("user", try reply.string("integrity"));
}

test "credential commands: a plain git push or gh runs as the user, a chained or piped one does not" {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "git push", "git push origin main", "git fetch", "git pull --rebase", "git clone https://example.com/x.git", "gh pr create" }) |command| {
        errdefer std.debug.print("{s} should run as the user\n", .{command});
        try testing.expect(try command_danger.usesCredentials(arena, command));
    }
    for ([_][]const u8{ "git push && x", "git push; rm x", "git push | cat", "git push > out.txt", "git push $(x)", "git status", "git -c x=y push", "npm test", "" }) |command| {
        errdefer std.debug.print("{s} should stay at low integrity\n", .{command});
        try testing.expect(!try command_danger.usesCredentials(arena, command));
    }
}
