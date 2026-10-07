const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");
const fixture = @import("ts_fixture.zig");
const common = @import("commit_batch.zig");

const verify_run = emetgate.verify_run;
const receipts = emetgate.receipts;
const jcs = emetgate.jcs;
const Verdict = emetgate.checker.Verdict;

const testing = std.testing;
const Plain = common.Plain;
const Env = common.Env;

const util_src = "export function add(a: number, b: number): number {\n  return a + b;\n}\n";
const new_body = "{\n  return b + a;\n}";
const files = [_]fixture.File{ .{ .rel = "src/util.ts", .text = util_src }, common.ignore };

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn verdictOf(case: *Plain) !Verdict {
    const result = try verify_run.run(testing.allocator, case.env.arena(), testing.io, case.runtime, case.repo.root_abs, .{ .commit = "HEAD", .test_command = common.green });
    return result.report.verdict;
}

fn note(env: *Env) ![]const u8 {
    return env.git(&.{ "notes", "--ref=emetgate", "show", "HEAD" });
}

fn committed(case: *Plain) !void {
    const env = &case.env;
    const reply = try env.call("emetgate_try", .{ .file = try env.abs("src/util.ts"), .symbol = "add", .hash = try env.hashOf("src/util.ts", "add"), .body = new_body, .message = "fix: swap" }, common.green, true);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
}

fn byHand(case: *Plain) !void {
    const env = &case.env;
    const reply = try env.call("emetgate_try", .{ .file = try env.abs("src/util.ts"), .symbol = "add", .hash = try env.hashOf("src/util.ts", "add"), .body = new_body }, common.green, false);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    _ = try env.git(&.{ "commit", "-q", "-am", "by the user" });
    const attached = try receipts.attach(testing.allocator, testing.io, case.repo.root_abs, "HEAD");
    try testing.expectEqual(@as(usize, 1), attached.count);
}

fn setForm(case: *Plain, form: ?[]const u8) !void {
    const env = &case.env;
    const arena = env.arena();
    const parsed = try jcs.parse(arena, try note(env));
    for (parsed.value.array.items) |*item| {
        const predicate = item.object.getPtr("predicate").?;
        _ = predicate.object.orderedRemove("form");
        if (form) |name| try predicate.object.put(arena, "form", .{ .string = name });
    }
    try case.repo.write(".git/note-edit", try jcs.canonicalize(arena, parsed.value));
    _ = try env.git(&.{ "notes", "--ref=emetgate", "add", "-f", "-F", ".git/note-edit", "HEAD" });
}

test "receipt form: a receipt of a committing call says stored and verifies over the blob, and one written without a commit carries no form and verifies as before" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    {
        var case: Plain = undefined;
        try case.init(&files);
        defer case.deinit();
        try committed(&case);
        try testing.expect(contains(try note(&case.env), "\"form\":\"stored\""));
        try testing.expectEqual(Verdict.verified, try verdictOf(&case));
    }
    {
        var case: Plain = undefined;
        try case.init(&files);
        defer case.deinit();
        try byHand(&case);
        try testing.expect(!contains(try note(&case.env), "\"form\""));
        try testing.expectEqual(Verdict.verified, try verdictOf(&case));
    }
}

test "receipt form: checked_out written out is read as a receipt without the field, and either receipt read in the other form of an unfiltered file still verifies" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    try byHand(&case);
    try setForm(&case, "checked_out");
    try testing.expect(contains(try note(&case.env), "\"form\":\"checked_out\""));
    try testing.expectEqual(Verdict.verified, try verdictOf(&case));
    try setForm(&case, "stored");
    try testing.expectEqual(Verdict.verified, try verdictOf(&case));
    try setForm(&case, null);
    try testing.expectEqual(Verdict.verified, try verdictOf(&case));
}

test "receipt form: a form the format does not name is a receipt that does not follow the format" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    try committed(&case);
    try testing.expectEqual(Verdict.verified, try verdictOf(&case));
    try setForm(&case, "working");
    try testing.expectEqual(Verdict.mismatch, try verdictOf(&case));
}
