const std = @import("std");
const builtin = @import("builtin");
const fixture = @import("run_fixture.zig");
const server = @import("emetgate").server;
const output_digest = @import("emetgate").output_digest;
const run_trim = @import("emetgate").run_trim;
const run_command = @import("emetgate").run_command;

const testing = std.testing;
const gpa = testing.allocator;

fn openPolicy(root_abs: []const u8) server.Policy {
    var policy: server.Policy = .{ .root = root_abs };
    policy.open_run = true;
    return policy;
}

fn contains(text: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, text, needle) != null;
}

fn numbered(count: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (1..count + 1) |i| try out.print(gpa, "line {d}\n", .{i});
    return out.toOwnedSlice(gpa);
}

test "open run: any command runs in the repo root, the reply names the shell and the exit code, and a nonzero exit is not a tool error" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try fixture.Repo.init(&.{});
    defer repo.deinit();
    var reply = try fixture.call(openPolicy(repo.root_abs), .{ .command = "git rev-parse --show-prefix && echo from the root && git show HEAD:missing.txt" });
    defer reply.deinit();
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings("ran", try reply.string("status"));
    const shell = try reply.string("shell");
    try testing.expect(std.mem.eql(u8, shell, "git bash") or std.mem.eql(u8, shell, "cmd"));
    try testing.expectEqual(@as(i64, 128), (try reply.field("exit_code")).?.integer);
    const content = try reply.string("content");
    try testing.expect(contains(content, "from the root"));
    try testing.expect(contains(content, run_trim.stderr_mark));
    try testing.expect(contains(content, "missing.txt"));
}

test "open run: long output keeps its head and tail with a labeled cut, raw returns all of it, and the full log comes back by id" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try fixture.Repo.init(&.{});
    defer repo.deinit();
    const big = try numbered(2000);
    defer gpa.free(big);
    try repo.commitScript("big.txt", big);
    const policy = openPolicy(repo.root_abs);

    var cut = try fixture.call(policy, .{ .command = "git show HEAD:big.txt" });
    defer cut.deinit();
    errdefer std.debug.print("{s}\n", .{cut.text});
    const content = try cut.string("content");
    try testing.expect(content.len < run_trim.general_budget + 256);
    try testing.expect(std.mem.startsWith(u8, content, "line 1\n"));
    try testing.expect(contains(content, "line 2000"));
    try testing.expect(!contains(content, "line 1000\n"));
    try testing.expect(contains(content, "cut; " ++ run_trim.raw_hint));
    try testing.expectEqual(@as(i64, @intCast(big.len)), (try cut.field("output_bytes")).?.integer);
    const full_log = try cut.string("full_log");
    try testing.expect(contains(full_log, output_digest.log_prefix));

    var raw = try fixture.call(policy, .{ .command = "git show HEAD:big.txt", .raw = true });
    defer raw.deinit();
    try testing.expectEqualStrings(big, try raw.string("content"));
    try testing.expect((try raw.field("full_log")) == null);

    const start = std.mem.indexOf(u8, full_log, output_digest.log_prefix).?;
    const id = full_log[start + output_digest.log_prefix.len ..][0..8];
    const request = try std.fmt.allocPrint(gpa, "{s}{s}", .{ output_digest.log_prefix, id });
    defer gpa.free(request);
    var log = try fixture.call(policy, .{ .command = request, .raw = true });
    defer log.deinit();
    try testing.expectEqualStrings(big, try log.string("text"));
}

test "open run: a file dump gets the larger budget" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try fixture.Repo.init(&.{});
    defer repo.deinit();
    const big = try numbered(3000);
    defer gpa.free(big);
    try repo.commitScript("big.txt", big);
    var reply = try fixture.call(openPolicy(repo.root_abs), .{ .command = "git show HEAD:big.txt | sed -n 1,3000p" });
    defer reply.deinit();
    errdefer std.debug.print("{s}\n", .{reply.text});
    const content = try reply.string("content");
    if (std.mem.eql(u8, try reply.string("shell"), "cmd")) return;
    try testing.expect(content.len > run_trim.general_budget * 2);
    try testing.expect(content.len < run_trim.file_budget + 256);
}

test "open run: a passing test run is one line and a failing one keeps the failing test" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try fixture.Repo.init(&.{});
    defer repo.deinit();
    const passing = "tests/test_math.py ...                                                   [100%]\n========================= 3 passed in 0.05s =========================\n";
    try repo.commitScript("pass.txt", passing);
    try repo.commitScript("fail.txt", output_digest.pytest_failure);
    var policy = openPolicy(repo.root_abs);

    policy.test_command = "git show HEAD:pass.txt";
    var pass = try fixture.call(policy, .{ .command = "git show HEAD:pass.txt" });
    defer pass.deinit();
    errdefer std.debug.print("{s}\n", .{pass.text});
    const line = try pass.string("content");
    try testing.expect(std.mem.startsWith(u8, line, "ok: "));
    try testing.expect(contains(line, "3 passed"));
    try testing.expect(std.mem.indexOfScalar(u8, line, '\n') == null);

    policy.test_command = "git show HEAD:fail.txt && git show HEAD:missing.txt";
    var fail = try fixture.call(policy, .{ .command = "git show HEAD:fail.txt && git show HEAD:missing.txt" });
    defer fail.deinit();
    errdefer std.debug.print("{s}\n", .{fail.text});
    const kept = try fail.string("content");
    try testing.expect(contains(kept, "test_add"));
    try testing.expect(contains(kept, "assert 3 == 4"));
    try testing.expect(!contains(kept, "platform win32"));
    try testing.expect((try fail.field("full_log")) != null);
}

test "open run: git noise is dropped with a labeled count" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try fixture.Repo.init(&.{});
    defer repo.deinit();
    var reply = try fixture.call(openPolicy(repo.root_abs), .{ .command = "git rev-parse --abbrev-ref HEAD && echo hint: pull first 1>&2" });
    defer reply.deinit();
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expectEqual(@as(i64, 0), (try reply.field("exit_code")).?.integer);
    const content = try reply.string("content");
    try testing.expect(!contains(content, "hint:"));
    try testing.expect(!contains(content, run_trim.stderr_mark));
    try testing.expect(contains(content, "1 git noise lines dropped"));
    try testing.expect(contains(content, run_trim.raw_hint));
}

test "open run: a command that writes files reports files_changed with a receipt" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try fixture.Repo.init(&.{});
    defer repo.deinit();
    var reply = try fixture.call(openPolicy(repo.root_abs), .{ .command = "git rev-parse HEAD > head.txt" });
    defer reply.deinit();
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expectEqual(@as(i64, 0), (try reply.field("exit_code")).?.integer);
    try testing.expectEqual(@as(i64, 1), (try reply.field("files_changed")).?.integer);
    try testing.expect((try reply.field("receipt")) != null);
    try testing.expect(repo.exists("repo/head.txt"));
}

test "open run: a file that only enters the listing, such as a cache file git add tracks, is not counted as changed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try fixture.Repo.init(&.{});
    defer repo.deinit();
    try repo.tmp.dir.createDirPath(testing.io, "repo/__pycache__");
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/__pycache__/calc.pyc", .data = "cached bytes" });
    const policy = openPolicy(repo.root_abs);
    var age = try fixture.call(policy, .{ .command = "touch -d 2020-01-01 __pycache__/calc.pyc" });
    defer age.deinit();
    if (std.mem.eql(u8, try age.string("shell"), "cmd")) return;
    try testing.expectEqual(@as(i64, 0), (try age.field("exit_code")).?.integer);
    try testing.expect((try age.field("files_changed")) == null);
    var add = try fixture.call(policy, .{ .command = "git add __pycache__ && echo made > made.txt" });
    defer add.deinit();
    errdefer std.debug.print("{s}\n", .{add.text});
    try testing.expectEqual(@as(i64, 0), (try add.field("exit_code")).?.integer);
    try testing.expectEqual(@as(i64, 1), (try add.field("files_changed")).?.integer);
    try testing.expect(run_command.untouchedSince(0, 3 * std.time.ns_per_s));
    try testing.expect(!run_command.untouchedSince(std.time.ns_per_s, 2 * std.time.ns_per_s));
}

test "open run: a command past its timeout is killed and the reply says how to give it more time" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try fixture.Repo.init(&.{});
    defer repo.deinit();
    var reply = try fixture.call(openPolicy(repo.root_abs), .{ .command = "ping -n 6 127.0.0.1", .timeout_s = 1 });
    defer reply.deinit();
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expectEqualStrings("timed_out", try reply.string("outcome"));
    try testing.expectEqual(@as(i64, 1), (try reply.field("timeout_s")).?.integer);
    try testing.expect(contains(try reply.string("fix"), "timeout_s"));
}

test "open run: a missing command, a non-boolean raw and a timeout out of range are refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try fixture.Repo.init(&.{});
    defer repo.deinit();
    const policy = openPolicy(repo.root_abs);
    var none = try fixture.call(policy, .{});
    defer none.deinit();
    try testing.expect(none.is_error);
    var blank = try fixture.call(policy, .{ .command = "  " });
    defer blank.deinit();
    try testing.expect(blank.is_error);
    var raw = try fixture.call(policy, .{ .command = "git status", .raw = "yes" });
    defer raw.deinit();
    try testing.expect(raw.is_error);
    var zero = try fixture.call(policy, .{ .command = "git status", .timeout_s = 0 });
    defer zero.deinit();
    try testing.expect(zero.is_error);
    var long = try fixture.call(policy, .{ .command = "git status", .timeout_s = 601 });
    defer long.deinit();
    try testing.expect(long.is_error);
}

test "open run: tools/list gives the open run tool under open run and the allowlist tool otherwise" {
    var plain: ?server.Tool = null;
    for (server.tool_defs) |tool| {
        if (std.mem.eql(u8, tool.name, "emetgate_run")) plain = tool;
    }
    const listed = plain.?;
    try testing.expectEqualStrings(listed.description, server.servedDef(listed, false).description);
    const open = server.servedDef(listed, true);
    try testing.expectEqualStrings("emetgate_run", open.name);
    try testing.expect(!std.mem.eql(u8, listed.description, open.description));
    try testing.expectEqual(@as(usize, 3), open.props.len);
    try testing.expect(!open.props[0].optional);
    try testing.expectEqualStrings("boolean", open.props[1].ty);
    try testing.expectEqualStrings("integer", open.props[2].ty);
    try testing.expect(!contains(open.description, "safe"));
    const other = server.servedDef(server.tool_defs[0], true);
    try testing.expectEqualStrings(server.tool_defs[0].description, other.description);
}
