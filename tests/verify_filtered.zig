const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");
const fixture = @import("ts_fixture.zig");
const support = @import("runner_support.zig");
const n_version = @import("verify_n_version.zig");

const symbol = emetgate.symbol;
const handlers = emetgate.handlers;
const telemetry = emetgate.telemetry;
const receipts = emetgate.receipts;
const verify_run = emetgate.verify_run;
const checker = emetgate.checker;
const jcs = emetgate.jcs;
const Runtime = emetgate.runtime.Runtime;
const Verdict = checker.Verdict;

const testing = std.testing;
const TsRepo = fixture.TsRepo;

const util_src = "export function add(a: number, b: number): number {\n  return a + b;\n}\n";
const swapped_body = "{\n  return b + a;\n}";
const padded_body = "{\n  return b + a + 0;\n}";
const marker = "@@@ wrapped {{{";
const green = "cmd /c exit 0";
const keep_all = "printf '%s\\n' '" ++ marker ++ "'\ncat\n";
const drop_padding = "printf '%s\\n' '" ++ marker ++ "'\nsed 's/ + 0//'\n";
const padded_src = "export function add(a: number, b: number): number {\n  return a + b + 0;\n}\n";
const padded_files = [_]fixture.File{ .{ .rel = "src/util.ts", .text = padded_src }, .{ .rel = ".gitignore", .text = ".emetgate/\n" } };
const files = [_]fixture.File{ .{ .rel = "src/util.ts", .text = util_src }, .{ .rel = ".gitignore", .text = ".emetgate/\n" } };
const local_src = "function add1(x: number): number {\n  return x + 1;\n}\nexport function twice(x: number): number {\n  return add1(add1(x));\n}\n";
const local_files = [_]fixture.File{ .{ .rel = "src/local.ts", .text = local_src }, .{ .rel = ".gitignore", .text = ".emetgate/\n" } };

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

const Case = struct {
    repo: TsRepo,
    runtime: *Runtime,
    arena_state: std.heap.ArenaAllocator,

    fn init(self: *Case, tree: []const fixture.File) !void {
        self.repo = try TsRepo.init(tree);
        errdefer self.repo.deinit();
        self.runtime = try Runtime.create(testing.allocator);
        self.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    }

    fn deinit(self: *Case) void {
        self.arena_state.deinit();
        self.runtime.destroy() catch @panic("live snapshots");
        self.repo.deinit();
    }

    fn arena(self: *Case) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    fn git(self: *Case, argv: []const []const u8) ![]const u8 {
        const out = (try receipts.git(self.arena(), testing.io, self.repo.root_abs, argv)) orelse return error.GitFailed;
        return std.mem.trimEnd(u8, out, "\r\n");
    }

    fn script(self: *Case, name: []const u8, text: []const u8) ![]const u8 {
        const rel = try std.fmt.allocPrint(self.arena(), ".git/{s}", .{name});
        try self.repo.write(rel, text);
        return std.fmt.allocPrint(self.arena(), "sh \"{s}\"", .{try self.repo.slashed(self.arena(), rel)});
    }

    fn wrap(self: *Case, rel: []const u8, clean: []const u8) !void {
        _ = try self.git(&.{ "config", "filter.wrap.clean", try self.script("wrap-clean.sh", clean) });
        _ = try self.git(&.{ "config", "filter.wrap.smudge", try self.script("wrap-smudge.sh", "tail -n +2\n") });
        _ = try self.git(&.{ "config", "filter.wrap.required", "true" });
        try self.repo.write(".gitattributes", "*.ts filter=wrap -text\n");
        _ = try self.git(&.{ "add", ".gitattributes" });
        _ = try self.git(&.{ "add", "--renormalize", "." });
        _ = try self.git(&.{ "commit", "-q", "-m", "store wrapped" });
        try testing.expect(contains(try self.git(&.{ "cat-file", "blob", try std.fmt.allocPrint(self.arena(), "HEAD:{s}", .{rel}) }), marker));
        try testing.expectEqualStrings("", try self.git(&.{ "status", "--porcelain" }));
    }

    fn call(self: *Case, tool: []const u8, rel: []const u8, name: []const u8, field: []const u8, value: []const u8) !void {
        const file = try self.repo.abs(self.arena(), rel);
        const hash = symbol.formatHash(try support.hashOfRef(testing.allocator, testing.io, self.runtime, file, name));
        var args: std.json.ObjectMap = .empty;
        try args.put(self.arena(), "file", .{ .string = file });
        try args.put(self.arena(), "symbol", .{ .string = name });
        try args.put(self.arena(), "hash", .{ .string = try self.arena().dupe(u8, &hash) });
        try args.put(self.arena(), field, .{ .string = value });
        var event: telemetry.Event = .{ .tool = tool };
        const result = try handlers.callTool(testing.allocator, testing.io, self.runtime, tool, .{ .object = args }, &event, .{ .root = self.repo.root_abs, .test_command = green });
        defer testing.allocator.free(result.text);
        errdefer std.debug.print("{s}\n", .{result.text});
        try testing.expect(!result.is_error);
    }

    fn commitGated(self: *Case, stored_mark: []const u8) !void {
        _ = try self.git(&.{ "add", "-A" });
        _ = try self.git(&.{ "commit", "-q", "-m", "gated" });
        const changed = try self.git(&.{ "diff-tree", "--no-commit-id", "-r", "--name-only", "HEAD" });
        const stored = try self.git(&.{ "cat-file", "blob", try std.fmt.allocPrint(self.arena(), "HEAD:{s}", .{changed}) });
        try testing.expect(contains(stored, marker));
        try testing.expect(contains(stored, stored_mark));
        try testing.expectEqual(@as(usize, 1), (try receipts.attach(testing.allocator, testing.io, self.repo.root_abs, "HEAD")).count);
    }

    fn swap(self: *Case) !void {
        try self.call("emetgate_try", "src/util.ts", "add", "body", swapped_body);
        try self.commitGated("b + a;");
    }

    fn rename(self: *Case) !void {
        try self.call("emetgate_rename", "src/local.ts", "add1", "new_name", "inc");
        try self.commitGated("inc(inc(x))");
    }

    fn verify(self: *Case) !checker.Report {
        const result = try verify_run.run(testing.allocator, self.arena(), testing.io, self.runtime, self.repo.root_abs, .{ .commit = "HEAD", .test_command = green });
        try n_version.compare(self.arena(), self.repo.root_abs, result);
        return result.report;
    }

    fn dropSmudge(self: *Case) !void {
        _ = try self.git(&.{ "config", "--unset", "filter.wrap.smudge" });
        _ = try self.git(&.{ "config", "filter.wrap.required", "false" });
    }

    fn failSmudge(self: *Case) !void {
        _ = try self.git(&.{ "config", "filter.wrap.smudge", try self.script("wrap-fail.sh", "exit 1\n") });
    }
};

fn explain(report: checker.Report) void {
    for (report.files) |f| std.debug.print("file {s}: {t} {s}\n", .{ f.path, f.outcome.verdict, f.outcome.reason });
    for (report.receipts) |r| std.debug.print("receipt {s}: {t} {s}\n", .{ r.operation, r.outcome.verdict, r.outcome.reason });
}

fn expectNotCheckedOut(report: checker.Report) !void {
    errdefer explain(report);
    try testing.expectEqual(Verdict.unverified, report.verdict);
    try testing.expectEqual(@as(usize, 1), report.receipts.len);
    try testing.expectEqual(Verdict.unverified, report.receipts[0].outcome.verdict);
    try testing.expectEqualStrings(checker.not_checked_out, report.receipts[0].outcome.reason);
    for (report.files) |f| try testing.expectEqual(Verdict.unverified, f.outcome.verdict);
}

test "verify filtered: a commit whose stored form is not source is verified over what its filter checks out" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&files);
    defer case.deinit();
    try case.wrap("src/util.ts", keep_all);
    try case.swap();
    const report = try case.verify();
    errdefer explain(report);
    try testing.expectEqual(Verdict.verified, report.verdict);
    try testing.expectEqual(@as(usize, 1), report.receipts.len);
}

test "verify filtered: without the filter that checks the file out the verdict is unverified by name, not mismatch" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&files);
    defer case.deinit();
    try case.wrap("src/util.ts", keep_all);
    try case.swap();
    try case.dropSmudge();
    try expectNotCheckedOut(try case.verify());
}

test "verify filtered: a filter that fails gives unverified by name for the receipt and the file, not mismatch" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&files);
    defer case.deinit();
    try case.wrap("src/util.ts", keep_all);
    try case.swap();
    try case.failSmudge();
    const report = try case.verify();
    try expectNotCheckedOut(report);
    try testing.expectEqual(@as(usize, 1), report.files.len);
    try testing.expectEqualStrings(checker.not_checked_out, report.files[0].outcome.reason);
}

test "verify filtered: a filter that does not give back the file the gate tested leaves the change unverified, not mismatch" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&files);
    defer case.deinit();
    try case.wrap("src/util.ts", drop_padding);
    try case.call("emetgate_try", "src/util.ts", "add", "body", padded_body);
    try case.commitGated("b + a;");
    const report = try case.verify();
    errdefer explain(report);
    try testing.expectEqual(Verdict.unverified, report.verdict);
    try testing.expectEqual(@as(usize, 1), report.files.len);
    try testing.expectEqual(Verdict.unverified, report.files[0].outcome.verdict);
}

test "verify filtered: a working file its filter does not give back before the change leaves the change unverified, not mismatch" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&padded_files);
    defer case.deinit();
    try case.wrap("src/util.ts", drop_padding);
    try testing.expect(!contains(try case.git(&.{ "cat-file", "blob", "HEAD:src/util.ts" }), "+ 0"));
    try case.swap();
    try expectNotCheckedOut(try case.verify());
}

test "verify filtered: a receipt that calls a filtered file absent is not taken on trust when the file cannot be checked out" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&files);
    defer case.deinit();
    try case.wrap("src/util.ts", keep_all);
    try case.repo.write(".gitattributes", "*.ts -text\n");
    try case.call("emetgate_try", "src/util.ts", "add", "body", swapped_body);
    _ = try case.git(&.{ "add", "-A" });
    _ = try case.git(&.{ "commit", "-q", "-m", "gated, filter dropped" });
    try testing.expect(!contains(try case.git(&.{ "cat-file", "blob", "HEAD:src/util.ts" }), marker));
    try testing.expectEqual(@as(usize, 1), (try receipts.attach(testing.allocator, testing.io, case.repo.root_abs, "HEAD")).count);
    {
        const honest = try case.verify();
        errdefer explain(honest);
        try testing.expectEqual(Verdict.verified, honest.receipts[0].outcome.verdict);
    }

    const note = (try receipts.noteBytes(case.arena(), testing.io, case.repo.root_abs, "HEAD")).?;
    const parsed = try jcs.parse(case.arena(), note);
    const predicate = parsed.value.array.items[0].object.getPtr("predicate").?;
    try predicate.object.getPtr("files").?.array.items[0].object.put(case.arena(), "before", .null);
    try predicate.object.put(case.arena(), "symbols", .{ .array = std.json.Array.init(case.arena()) });
    try case.repo.write(".git/forged-note", try jcs.canonicalize(case.arena(), parsed.value));
    _ = try case.git(&.{ "notes", "--ref=emetgate", "add", "-f", "-F", try case.repo.abs(case.arena(), ".git/forged-note"), "HEAD" });
    try case.failSmudge();

    const report = try case.verify();
    errdefer explain(report);
    try testing.expectEqual(Verdict.unverified, report.receipts[0].outcome.verdict);
    try testing.expectEqualStrings(checker.not_checked_out, report.receipts[0].outcome.reason);
}

test "verify filtered: a hand edit under the same filter is still unverified, as a control" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&files);
    defer case.deinit();
    try case.wrap("src/util.ts", keep_all);
    try case.repo.write("src/util.ts", "export function add(a: number, b: number): number {\n  return a + b + 1;\n}\n");
    _ = try case.git(&.{ "commit", "-q", "-am", "by hand" });
    const report = try case.verify();
    try testing.expectEqual(Verdict.unverified, report.verdict);
    try testing.expectEqual(@as(usize, 0), report.receipts.len);
}

test "verify filtered: a hand edit after the gate under the same filter is unverified, as a control" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&files);
    defer case.deinit();
    try case.wrap("src/util.ts", keep_all);
    try case.call("emetgate_try", "src/util.ts", "add", "body", swapped_body);
    try case.repo.write("src/util.ts", "export function add(a: number, b: number): number {\n  return b + a + 1;\n}\n");
    try case.commitGated("b + a + 1;");
    const report = try case.verify();
    errdefer explain(report);
    try testing.expectEqual(Verdict.unverified, report.verdict);
    try testing.expectEqualStrings("the file changed after the receipt, outside the gate", report.files[0].outcome.reason);
}

test "verify filtered: a rename under a filter is verified by the alpha hash of what the filter checks out" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&local_files);
    defer case.deinit();
    try case.wrap("src/local.ts", keep_all);
    try case.rename();
    const report = try case.verify();
    errdefer explain(report);
    try testing.expectEqual(Verdict.verified, report.verdict);
    try testing.expectEqualStrings("rename", report.receipts[0].operation);
}

test "verify filtered: a rename whose files cannot be checked out is unverified by name, not mismatch" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    {
        var case: Case = undefined;
        try case.init(&local_files);
        defer case.deinit();
        try case.wrap("src/local.ts", keep_all);
        try case.rename();
        try case.dropSmudge();
        try expectNotCheckedOut(try case.verify());
    }
    {
        var case: Case = undefined;
        try case.init(&local_files);
        defer case.deinit();
        try case.wrap("src/local.ts", keep_all);
        try case.rename();
        try case.failSmudge();
        try expectNotCheckedOut(try case.verify());
    }
}
