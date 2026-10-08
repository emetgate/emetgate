const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");
const fixture = @import("ts_fixture.zig");
const common = @import("commit_batch.zig");

const verify_run = emetgate.verify_run;
const checker = emetgate.checker;
const Verdict = checker.Verdict;

const testing = std.testing;
const Plain = common.Plain;

const util_src = "export function add(a: number, b: number): number {\n  return a + b;\n}\n";
const padded_body = "{\n  return b + a + 0;\n}";
const marker = "@@@ wrapped {{{";
const files = [_]fixture.File{ .{ .rel = "src/util.ts", .text = util_src }, .{ .rel = ".gitignore", .text = ".emetgate/\n" } };

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn script(case: *Plain, name: []const u8, text: []const u8) ![]const u8 {
    const env = &case.env;
    const rel = try std.fmt.allocPrint(env.arena(), ".git/{s}", .{name});
    try case.repo.write(rel, text);
    const abs = try env.arena().dupe(u8, try env.abs(rel));
    std.mem.replaceScalar(u8, abs, '\\', '/');
    return std.fmt.allocPrint(env.arena(), "sh \"{s}\"", .{abs});
}

fn wrap(case: *Plain, rel: []const u8) !void {
    const env = &case.env;
    _ = try env.git(&.{ "config", "filter.wrap.clean", try script(case, "wrap-clean.sh", "printf '%s\\n' '" ++ marker ++ "'\nsed 's/ + 0//'\n") });
    _ = try env.git(&.{ "config", "filter.wrap.smudge", try script(case, "wrap-smudge.sh", "tail -n +2\n") });
    _ = try env.git(&.{ "config", "filter.wrap.required", "true" });
    try case.repo.write(".gitattributes", "*.ts filter=wrap -text\n");
    _ = try env.git(&.{ "add", ".gitattributes" });
    _ = try env.git(&.{ "add", "--renormalize", "." });
    _ = try env.git(&.{ "commit", "-q", "-m", "store wrapped" });
    try testing.expect(contains(try env.git(&.{ "cat-file", "blob", try std.fmt.allocPrint(env.arena(), "HEAD:{s}", .{rel}) }), marker));
    try testing.expectEqualStrings("", try env.git(&.{ "status", "--porcelain" }));
}

fn swap(case: *Plain) !void {
    const env = &case.env;
    const before = try env.head();
    const reply = try env.call("emetgate_try", .{ .file = try env.abs("src/util.ts"), .symbol = "add", .hash = try env.hashOf("src/util.ts", "add"), .body = padded_body, .message = "fix: swap" }, common.green, true);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings(before, try env.git(&.{ "rev-parse", "HEAD^" }));
    const stored = try env.git(&.{ "cat-file", "blob", "HEAD:src/util.ts" });
    try testing.expect(contains(stored, marker));
    try testing.expect(contains(stored, "b + a;"));
    try testing.expect(contains(try env.read("src/util.ts"), "b + a + 0;"));
}

fn verdict(case: *Plain) !checker.Report {
    const result = try verify_run.run(testing.allocator, case.env.arena(), testing.io, case.runtime, case.repo.root_abs, .{ .commit = "HEAD", .test_command = common.green });
    return result.report;
}

fn expectNotCheckedOut(report: checker.Report) !void {
    errdefer for (report.receipts) |r| std.debug.print("receipt {s}: {t} {s}\n", .{ r.operation, r.outcome.verdict, r.outcome.reason });
    try testing.expectEqual(Verdict.unverified, report.verdict);
    try testing.expectEqual(@as(usize, 1), report.receipts.len);
    try testing.expectEqualStrings(checker.not_checked_out, report.receipts[0].outcome.reason);
}

test "verify filtered commit: a commit whose stored form is not source is verified over what its filter checks out" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    try wrap(&case, "src/util.ts");
    try swap(&case);
    const report = try verdict(&case);
    errdefer for (report.receipts) |r| std.debug.print("receipt {s}: {t} {s}\n", .{ r.operation, r.outcome.verdict, r.outcome.reason });
    try testing.expectEqual(Verdict.verified, report.verdict);
}

test "verify filtered commit: without the filter that checks the file out the verdict is unverified by name, not mismatch" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    try wrap(&case, "src/util.ts");
    try swap(&case);
    _ = try case.env.git(&.{ "config", "--unset", "filter.wrap.smudge" });
    _ = try case.env.git(&.{ "config", "filter.wrap.required", "false" });
    try expectNotCheckedOut(try verdict(&case));
}

test "verify filtered commit: a filter that fails gives unverified by name, not mismatch" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    try wrap(&case, "src/util.ts");
    try swap(&case);
    _ = try case.env.git(&.{ "config", "filter.wrap.smudge", try script(&case, "wrap-fail.sh", "exit 1\n") });
    try expectNotCheckedOut(try verdict(&case));
}

test "verify filtered commit: a hand edit under the same filter is still unverified, as a control" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    try wrap(&case, "src/util.ts");
    try case.repo.write("src/util.ts", "export function add(a: number, b: number): number {\n  return a + b + 1;\n}\n");
    _ = try case.env.git(&.{ "commit", "-q", "-am", "by hand" });
    const report = try verdict(&case);
    try testing.expectEqual(Verdict.unverified, report.verdict);
    try testing.expectEqual(@as(usize, 0), report.receipts.len);
}

const local_src = "function add1(x: number): number {\n  return x + 1;\n}\nexport function twice(x: number): number {\n  return add1(add1(x));\n}\n";
const local_files = [_]fixture.File{ .{ .rel = "src/local.ts", .text = local_src }, .{ .rel = ".gitignore", .text = ".emetgate/\n" } };

fn rename(case: *Plain) !void {
    const env = &case.env;
    const before = try env.head();
    const reply = try env.call("emetgate_rename", .{ .file = try env.abs("src/local.ts"), .symbol = "add1", .hash = try env.hashOf("src/local.ts", "add1"), .new_name = "inc", .message = "refactor: rename" }, common.green, true);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings(before, try env.git(&.{ "rev-parse", "HEAD^" }));
    try testing.expect(contains(try env.git(&.{ "cat-file", "blob", "HEAD:src/local.ts" }), marker));
    try testing.expect(contains(try env.read("src/local.ts"), "inc(inc(x))"));
}

test "verify filtered commit: a rename under a filter is verified by the alpha hash of what the filter checks out" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Plain = undefined;
    try case.init(&local_files);
    defer case.deinit();
    try wrap(&case, "src/local.ts");
    try rename(&case);
    const report = try verdict(&case);
    errdefer for (report.receipts) |r| std.debug.print("receipt {s}: {t} {s}\n", .{ r.operation, r.outcome.verdict, r.outcome.reason });
    try testing.expectEqual(Verdict.verified, report.verdict);
    try testing.expectEqualStrings("rename", report.receipts[0].operation);
}

test "verify filtered commit: a rename whose files cannot be checked out is unverified by name, not mismatch" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    {
        var case: Plain = undefined;
        try case.init(&local_files);
        defer case.deinit();
        try wrap(&case, "src/local.ts");
        try rename(&case);
        _ = try case.env.git(&.{ "config", "--unset", "filter.wrap.smudge" });
        _ = try case.env.git(&.{ "config", "filter.wrap.required", "false" });
        try expectNotCheckedOut(try verdict(&case));
    }
    {
        var case: Plain = undefined;
        try case.init(&local_files);
        defer case.deinit();
        try wrap(&case, "src/local.ts");
        try rename(&case);
        _ = try case.env.git(&.{ "config", "filter.wrap.smudge", try script(&case, "wrap-fail.sh", "exit 1\n") });
        try expectNotCheckedOut(try verdict(&case));
    }
}
