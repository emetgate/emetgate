const std = @import("std");
const builtin = @import("builtin");
const symbol = @import("emetgate").symbol;
const handlers = @import("emetgate").handlers;
const telemetry = @import("emetgate").telemetry;
const receipts = @import("emetgate").receipts;
const verify_run = @import("emetgate").verify_run;
const checker = @import("emetgate").checker;
const jcs = @import("emetgate").jcs;
const rule_command = @import("emetgate").rule_command;
const Runtime = @import("emetgate").runtime.Runtime;
const fixture = @import("ts_fixture.zig");
const support = @import("runner_support.zig");

const testing = std.testing;
const TsRepo = fixture.TsRepo;

const math_src = "export function add(a: number, b: number): number {\n  return a + b;\n}\n";
const green = "cmd /c exit 0";

const Case = struct {
    repo: TsRepo,
    runtime: *Runtime,
    arena_state: std.heap.ArenaAllocator,

    fn init(self: *Case) !void {
        self.repo = try TsRepo.init(&.{ .{ .rel = "src/math.ts", .text = math_src }, .{ .rel = ".gitignore", .text = ".emetgate/\n" } });
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

    fn call(self: *Case, tool: []const u8, args: std.json.ObjectMap, test_command: []const u8) ![]u8 {
        var event: telemetry.Event = .{ .tool = tool };
        const result = try handlers.callTool(testing.allocator, testing.io, self.runtime, tool, .{ .object = args }, &event, .{ .root = self.repo.root_abs, .test_command = test_command });
        defer testing.allocator.free(result.text);
        errdefer std.debug.print("{s}\n", .{result.text});
        try testing.expect(!result.is_error);
        return self.arena().dupe(u8, result.text);
    }

    fn tryBody(self: *Case, body: []const u8, test_command: []const u8) ![]u8 {
        const file = try self.repo.abs(self.arena(), "src/math.ts");
        const hash = symbol.formatHash(try support.hashOfRef(testing.allocator, testing.io, self.runtime, file, "add"));
        var args: std.json.ObjectMap = .empty;
        try args.put(self.arena(), "file", .{ .string = file });
        try args.put(self.arena(), "symbol", .{ .string = "add" });
        try args.put(self.arena(), "hash", .{ .string = try self.arena().dupe(u8, &hash) });
        try args.put(self.arena(), "body", .{ .string = body });
        return self.call("emetgate_try", args, test_command);
    }

    fn commit(self: *Case, message: []const u8) !void {
        try support.Repo.git(self.repo.root_abs, &.{ "add", "-A" });
        try support.Repo.git(self.repo.root_abs, &.{ "commit", "-q", "-m", message });
    }

    fn attach(self: *Case) !usize {
        return (try receipts.attach(testing.allocator, testing.io, self.repo.root_abs, "HEAD")).count;
    }

    fn verify(self: *Case, options: verify_run.Options) !verify_run.Result {
        return verify_run.run(testing.allocator, self.arena(), testing.io, self.runtime, self.repo.root_abs, options);
    }

    fn note(self: *Case) ![]u8 {
        return (try receipts.noteBytes(self.arena(), testing.io, self.repo.root_abs, "HEAD")).?;
    }

    fn replaceNote(self: *Case, bytes: []const u8) !void {
        try self.repo.write("note.tmp", bytes);
        const path = try self.repo.abs(self.arena(), "note.tmp");
        try support.Repo.git(self.repo.root_abs, &.{ "notes", "--ref=emetgate", "add", "-f", "-F", path, "HEAD" });
    }
};

fn fileVerdict(result: verify_run.Result, path: []const u8) ?checker.Verdict {
    for (result.report.files) |f| if (std.mem.eql(u8, f.path, path)) return f.outcome.verdict;
    return null;
}

test "verify: a gated edit gets a receipt that verifies at the user's commit, tests rerun in the sandbox" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const text = try case.tryBody("{\n  return b + a;\n}", green);
    try testing.expect(std.mem.indexOf(u8, text, "\"receipt\":\"") != null);
    try case.commit("gated");
    try testing.expectEqual(@as(usize, 1), try case.attach());
    const result = try case.verify(.{ .commit = "HEAD", .test_command = green });
    try testing.expectEqual(checker.Verdict.verified, result.report.verdict);
    try testing.expectEqual(@as(?checker.Verdict, .verified), fileVerdict(result, "src/math.ts"));
    try testing.expectEqual(@as(u8, 0), verify_run.exitCode(result.report.verdict));
}

test "verify: a change without a receipt is unverified and never green" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.repo.write("src/math.ts", "export function add(a: number, b: number): number {\n  return a - b;\n}\n");
    try case.commit("by hand");
    const result = try case.verify(.{ .commit = "HEAD", .test_command = green });
    try testing.expectEqual(checker.Verdict.unverified, result.report.verdict);
    try testing.expect(verify_run.exitCode(result.report.verdict) != 0);
}

test "verify: a file edited by hand after the gate is unverified, the gated one stays verified" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    _ = try case.tryBody("{\n  return b + a;\n}", green);
    try case.repo.write("src/math.ts", "export function add(a: number, b: number): number {\n  return b + a + 0;\n}\n");
    try case.commit("gated then edited");
    _ = try case.attach();
    const result = try case.verify(.{ .commit = "HEAD", .test_command = green });
    try testing.expectEqual(@as(?checker.Verdict, .unverified), fileVerdict(result, "src/math.ts"));
    try testing.expect(result.report.verdict != .verified);
}

test "verify: a forged digest, a non-canonical note, an added and a removed receipt are caught" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    _ = try case.tryBody("{\n  return b + a;\n}", green);
    try case.commit("one");
    _ = try case.attach();
    const original = try case.note();

    const at = std.mem.indexOf(u8, original, "\"after\":\"").? + "\"after\":\"".len;
    const forged = try case.arena().dupe(u8, original);
    forged[at] = if (forged[at] == '0') '1' else '0';
    try case.replaceNote(forged);
    try testing.expectEqual(checker.Verdict.mismatch, (try case.verify(.{ .commit = "HEAD", .test_command = green })).report.verdict);

    const spaced = try std.mem.replaceOwned(u8, case.arena(), original, "\"_type\":", "\"_type\": ");
    try case.replaceNote(spaced);
    try testing.expectEqual(checker.Verdict.mismatch, (try case.verify(.{ .commit = "HEAD", .test_command = green })).report.verdict);

    const doubled = try std.mem.concat(case.arena(), u8, &.{ original[0 .. original.len - 1], ",", original[1..] });
    try case.replaceNote(doubled);
    try testing.expectEqual(checker.Verdict.mismatch, (try case.verify(.{ .commit = "HEAD", .test_command = green })).report.verdict);

    try case.replaceNote("[]");
    try testing.expectEqual(checker.Verdict.unverified, (try case.verify(.{ .commit = "HEAD", .test_command = green })).report.verdict);

    try case.replaceNote(original);
    try testing.expectEqual(checker.Verdict.verified, (try case.verify(.{ .commit = "HEAD", .test_command = green })).report.verdict);
}

test "verify: a spending receipt whose tests are red at the commit is a mismatch" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const flaky = "cmd /c type green.txt";
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.repo.write("green.txt", "green\n");
    try case.commit("green");
    _ = try case.tryBody("{\n  return b + a;\n}", flaky);
    try std.Io.Dir.deleteFileAbsolute(testing.io, try case.repo.abs(case.arena(), "green.txt"));
    try case.commit("tests red at the commit");
    _ = try case.attach();
    const result = try case.verify(.{ .commit = "HEAD", .test_command = flaky });
    try testing.expectEqual(@as(?checker.Verdict, .mismatch), fileVerdict(result, "src/math.ts"));
    try testing.expectEqual(@as(?checker.Verdict, .unverified), fileVerdict(result, "green.txt"));
    try testing.expectEqual(checker.Verdict.mismatch, result.report.verdict);
}

test "verify: a receipt's command never runs, only the trusted one, and a different command leaves the change unverified" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    _ = try case.tryBody("{\n  return b + a;\n}", green);
    try case.commit("one");
    _ = try case.attach();
    const original = try case.note();
    const marker = try case.repo.slashed(case.arena(), "pwned.txt");
    const evil = try std.fmt.allocPrint(case.arena(), "cmd /c echo x> {s}", .{marker});
    const evil_hex = std.fmt.bytesToHex(@import("emetgate").receipt.blake3(evil), .lower);
    const green_hex = std.fmt.bytesToHex(@import("emetgate").receipt.blake3(green), .lower);
    var poisoned = try std.mem.replaceOwned(u8, case.arena(), original, "\"command\":\"cmd /c exit 0\"", try std.fmt.allocPrint(case.arena(), "\"command\":\"{s}\"", .{evil}));
    poisoned = try std.mem.replaceOwned(u8, case.arena(), poisoned, &green_hex, &evil_hex);
    const parsed = try jcs.parse(case.arena(), poisoned);
    try case.replaceNote(try jcs.canonicalize(case.arena(), parsed.value));
    const result = try case.verify(.{ .commit = "HEAD", .test_command = green });
    try testing.expectEqual(checker.Verdict.unverified, result.report.verdict);
    try testing.expect(!case.repo.exists("pwned.txt"));
    const skipped = try case.verify(.{ .commit = "HEAD", .test_command = evil, .skip_tests = true });
    try testing.expectEqual(checker.Verdict.unverified, skipped.report.verdict);
}

test "verify: a rule the receipt names with a changed digest is a mismatch" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const request = rule_command.parse(&.{ "add", "prefer strict equality", "--check", "forbid:==" }) orelse return error.UsageRefused;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer err_out.deinit();
    try rule_command.run(testing.allocator, testing.io, case.repo.root_abs, request, &out.writer, &err_out.writer);
    _ = try case.tryBody("{\n  return b + a;\n}", green);
    try case.commit("with a rule");
    _ = try case.attach();
    const original = try case.note();
    const at = std.mem.indexOf(u8, original, "\"rules\":[{\"digest\":\"").? + "\"rules\":[{\"digest\":\"".len;
    try testing.expectEqual(checker.Verdict.verified, (try case.verify(.{ .commit = "HEAD", .test_command = green })).report.verdict);
    const forged = try case.arena().dupe(u8, original);
    forged[at] = if (forged[at] == '0') '1' else '0';
    try case.replaceNote(forged);
    try testing.expectEqual(checker.Verdict.mismatch, (try case.verify(.{ .commit = "HEAD", .test_command = green })).report.verdict);
}

test "verify: a rename's symmetry receipt verifies by alpha hash without running any test" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.repo.write("src/local.ts", "function add1(x: number): number {\n  return x + 1;\n}\nexport function twice(x: number): number {\n  return add1(add1(x));\n}\n");
    try case.commit("local");
    const file = try case.repo.abs(case.arena(), "src/local.ts");
    const hash = symbol.formatHash(try support.hashOfRef(testing.allocator, testing.io, case.runtime, file, "add1"));
    var args: std.json.ObjectMap = .empty;
    try args.put(case.arena(), "file", .{ .string = file });
    try args.put(case.arena(), "symbol", .{ .string = "add1" });
    try args.put(case.arena(), "hash", .{ .string = try case.arena().dupe(u8, &hash) });
    try args.put(case.arena(), "new_name", .{ .string = "inc" });
    _ = try case.call("emetgate_rename", args, green);
    try case.commit("rename");
    _ = try case.attach();
    const result = try case.verify(.{ .commit = "HEAD", .skip_tests = true });
    try testing.expectEqual(checker.Verdict.verified, result.report.verdict);
    try testing.expectEqualStrings("rename", result.report.receipts[0].operation);
}

test "verify: a spending change relabelled as a symmetric rename fails the alpha hash" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    _ = try case.tryBody("{\n  return b + a;\n}", green);
    try case.commit("one");
    _ = try case.attach();
    const original = try case.note();
    var relabelled = try std.mem.replaceOwned(u8, case.arena(), original, "\"class\":\"spending\"", "\"class\":\"symmetry\"");
    relabelled = try std.mem.replaceOwned(u8, case.arena(), relabelled, "\"operation\":\"try\"", "\"operation\":\"rename\"");
    try case.replaceNote(relabelled);
    const result = try case.verify(.{ .commit = "HEAD", .skip_tests = true });
    try testing.expectEqual(checker.Verdict.mismatch, result.report.verdict);
}
