const std = @import("std");
const builtin = @import("builtin");
const memory = @import("emetgate").memory;
const doc_case = @import("commit_write_doc.zig");

const testing = std.testing;
const Case = doc_case.Case;
const committing = doc_case.committing;

const starts_with_fix = "message:cmd:findstr /b fix: .emetgate\\COMMIT_EDITMSG";
const starts_with_fix_on_stdin = "message:cmd:findstr /b fix: < .emetgate\\COMMIT_EDITMSG";
const green = "cmd /c exit 0";

fn adopt(case: *Case, check: []const u8) ![]const u8 {
    const id = try memory.remember(testing.allocator, testing.io, case.repo.root_abs, .project, "checked by a command", true, check, null);
    defer testing.allocator.free(id);
    return case.arena().dupe(u8, id);
}

fn expectJudged(check: []const u8) !void {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const before = try case.git(&.{ "rev-parse", "HEAD" });
    const id = try adopt(&case, check);

    const refused = try case.writeBuild("build: typecheck", committing);
    errdefer std.debug.print("{s}\n", .{refused.text});
    try testing.expect(refused.is_error);
    try testing.expect(std.mem.indexOf(u8, refused.text, "\"reason\":\"rule_violation\"") != null);
    try testing.expect(std.mem.indexOf(u8, refused.text, id) != null);
    try testing.expect(std.mem.indexOf(u8, refused.text, "commit message") != null);
    try case.expectUntouched(before);

    const accepted = try case.writeBuild("fix: typecheck without emitting", committing);
    errdefer std.debug.print("{s}\n", .{accepted.text});
    try testing.expect(!accepted.is_error);
    try testing.expectEqualStrings("fix: typecheck without emitting", try case.git(&.{ "log", "-1", "--format=%B" }));
    try testing.expectEqualStrings("", try case.git(&.{ "status", "--porcelain" }));
}

test "message command: the command reads the message from the file named on its command line, refuses one message and accepts another" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try expectJudged(starts_with_fix);
}

test "message command: the same file redirected to standard input serves a checker that reads the message there" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try expectJudged(starts_with_fix_on_stdin);
}

test "message command: the message file is gone before the tests run" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    _ = try adopt(&case, starts_with_fix);
    const reply = try case.writeBuild("fix: typecheck", .{ .test_command = "if exist .emetgate\\COMMIT_EDITMSG exit 1", .commit = true });
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expect(!case.repo.exists(".emetgate/COMMIT_EDITMSG"));
}

test "message command: with commits off there is no message and the command does not run" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    _ = try adopt(&case, "message:cmd:exit 1");
    const reply = try case.writeBuild(null, .{ .test_command = green });
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
}

test "message command: a command that cannot be found is a failed check, not a verdict, and nothing is written" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const before = try case.git(&.{ "rev-parse", "HEAD" });
    _ = try adopt(&case, "message:cmd:emetgate-no-such-checker-xyz");
    const reply = try case.writeBuild("fix: typecheck", committing);
    try testing.expect(reply.is_error);
    try testing.expect(std.mem.indexOf(u8, reply.text, "\"reason\":\"rule_check_crashed\"") != null);
    try testing.expect(std.mem.indexOf(u8, reply.text, "command_not_found") != null);
    try case.expectUntouched(before);
}

test "message command: from a committed ledger it never runs without --allow-repo-memory, and runs with it" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    _ = try adopt(&case, starts_with_fix);
    _ = try case.git(&.{ "add", "-f", "--", ".emetgate/ledger.ndjson" });
    _ = try case.git(&.{ "commit", "-q", "-m", "ship a ledger" });
    const before = try case.git(&.{ "rev-parse", "HEAD" });

    const untrusted = try case.writeBuild("fix: typecheck", committing);
    try testing.expect(untrusted.is_error);
    try testing.expect(std.mem.indexOf(u8, untrusted.text, "UntrustedRepoMemory") != null);
    try case.expectUntouched(before);

    const refused = try case.writeBuild("build: typecheck", .{ .test_command = green, .commit = true, .allow_repo_memory = true });
    try testing.expect(refused.is_error);
    try testing.expect(std.mem.indexOf(u8, refused.text, "\"reason\":\"rule_violation\"") != null);
    try case.expectUntouched(before);

    const trusted = try case.writeBuild("fix: typecheck", .{ .test_command = green, .commit = true, .allow_repo_memory = true });
    errdefer std.debug.print("{s}\n", .{trusted.text});
    try testing.expect(!trusted.is_error);
    try testing.expectEqualStrings(before, try case.git(&.{ "rev-parse", "HEAD^" }));
    try testing.expectEqualStrings("", try case.git(&.{ "status", "--porcelain" }));
}

test "message command: a tracked file where the message file goes is refused by name and stays as it was" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    _ = try adopt(&case, starts_with_fix);
    try case.repo.write(".emetgate/COMMIT_EDITMSG", "fix: not this one\n");
    _ = try case.git(&.{ "add", "-f", "--", ".emetgate/COMMIT_EDITMSG" });
    _ = try case.git(&.{ "commit", "-q", "-m", "track a file in the way" });
    const before = try case.git(&.{ "rev-parse", "HEAD" });

    const reply = try case.writeBuild("build: typecheck", committing);
    try testing.expect(reply.is_error);
    try testing.expect(std.mem.indexOf(u8, reply.text, "MessageFileInTheWay") != null);
    try case.expectUntouched(before);
}
