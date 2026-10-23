const std = @import("std");
const builtin = @import("builtin");
const symbol = @import("emetgate").symbol;
const handlers = @import("emetgate").handlers;
const telemetry = @import("emetgate").telemetry;
const receipts = @import("emetgate").receipts;
const verify_branch = @import("emetgate").verify_branch;
const checker = @import("emetgate").checker;
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

    fn head(self: *Case) ![]const u8 {
        return receipts.resolveCommit(self.arena(), testing.io, self.repo.root_abs, "HEAD");
    }

    /// A gated edit that rewrites `add`'s body, then commit + attach its receipt.
    fn gatedCommit(self: *Case, body: []const u8, message: []const u8) !void {
        const file = try self.repo.abs(self.arena(), "src/math.ts");
        const hash = symbol.formatHash(try support.hashOfRef(testing.allocator, testing.io, self.runtime, file, "add"));
        var args: std.json.ObjectMap = .empty;
        try args.put(self.arena(), "file", .{ .string = file });
        try args.put(self.arena(), "symbol", .{ .string = "add" });
        try args.put(self.arena(), "hash", .{ .string = try self.arena().dupe(u8, &hash) });
        try args.put(self.arena(), "body", .{ .string = body });
        try args.put(self.arena(), "detail", .{ .string = "full" });
        var event: telemetry.Event = .{ .tool = "emetgate_try" };
        const result = try handlers.callTool(testing.allocator, testing.io, self.runtime, "emetgate_try", .{ .object = args }, &event, .{ .root = self.repo.root_abs, .test_command = green });
        defer testing.allocator.free(result.text);
        errdefer std.debug.print("{s}\n", .{result.text});
        try testing.expect(!result.is_error);
        try support.Repo.git(self.repo.root_abs, &.{ "add", "-A" });
        try support.Repo.git(self.repo.root_abs, &.{ "commit", "-q", "-m", message });
        try testing.expectEqual(@as(usize, 1), (try receipts.attach(testing.allocator, testing.io, self.repo.root_abs, "HEAD")).count);
    }

    fn handCommit(self: *Case, text: []const u8, message: []const u8) !void {
        try self.repo.write("src/math.ts", text);
        try support.Repo.git(self.repo.root_abs, &.{ "add", "-A" });
        try support.Repo.git(self.repo.root_abs, &.{ "commit", "-q", "-m", message });
    }

    fn verify(self: *Case, base: []const u8) !verify_branch.Result {
        return verify_branch.run(testing.allocator, self.arena(), testing.io, self.runtime, self.repo.root_abs, .{
            .base = base,
            .head = "HEAD",
            .test_command = green,
        });
    }

    fn note(self: *Case, commit: []const u8) ![]u8 {
        return (try receipts.noteBytes(self.arena(), testing.io, self.repo.root_abs, commit)).?;
    }

    fn replaceNote(self: *Case, commit: []const u8, bytes: []const u8) !void {
        try self.repo.write("note.tmp", bytes);
        const path = try self.repo.abs(self.arena(), "note.tmp");
        try support.Repo.git(self.repo.root_abs, &.{ "notes", "--ref=emetgate", "add", "-f", "-F", path, commit });
    }
};

test "verify --branch: a run of gated commits is fully verified and hash-chained" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const base = try case.head();
    try case.gatedCommit("{\n  return b + a;\n}", "c1");
    try case.gatedCommit("{\n  return a + b + 0;\n}", "c2");

    const result = try case.verify(base);
    try testing.expectEqual(verify_branch.BranchVerdict.verified, result.verdict);
    try testing.expectEqual(@as(usize, 2), result.count);
    for (result.links) |link| {
        try testing.expect(link.has_receipt);
        try testing.expectEqual(checker.Verdict.verified, link.verdict);
    }
    // The chain binds each link to its parent: the tip equals the last link's cert.
    try testing.expectEqualSlices(u8, &result.links[1].cert, &result.tip);
    try testing.expect(!std.mem.eql(u8, &result.links[0].cert, &result.links[1].cert));
    try testing.expectEqual(@as(u8, 0), verify_branch.exitCode(result.verdict));
}

test "verify --branch: a missing receipt makes the branch partial, not green" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const base = try case.head();
    try case.gatedCommit("{\n  return b + a;\n}", "gated");
    try case.handCommit("export function add(a: number, b: number): number {\n  return a - b;\n}\n", "by hand");

    const result = try case.verify(base);
    try testing.expectEqual(verify_branch.BranchVerdict.partial, result.verdict);
    try testing.expectEqual(@as(usize, 2), result.count);
    try testing.expect(result.links[0].has_receipt);
    try testing.expect(!result.links[1].has_receipt);
    try testing.expect(verify_branch.exitCode(result.verdict) != 0);
}

test "verify --branch: a forged receipt note makes the branch broken and shifts the chain tip" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const base = try case.head();
    try case.gatedCommit("{\n  return b + a;\n}", "c1");
    try case.gatedCommit("{\n  return a + b + 0;\n}", "c2");

    const honest = try case.verify(base);
    try testing.expectEqual(verify_branch.BranchVerdict.verified, honest.verdict);
    const honest_tip = honest.tip;

    // Flip a hash digit in the first commit's receipt note.
    const first = honest.links[0].commit;
    const original = try case.note(first);
    const at = std.mem.indexOf(u8, original, "\"after\":\"").? + "\"after\":\"".len;
    const forged = try case.arena().dupe(u8, original);
    forged[at] = if (forged[at] == '0') '1' else '0';
    try case.replaceNote(first, forged);

    const tampered = try case.verify(base);
    try testing.expectEqual(verify_branch.BranchVerdict.broken, tampered.verdict);
    try testing.expect(!std.mem.eql(u8, &honest_tip, &tampered.tip));
    try testing.expectEqual(@as(u8, 54), verify_branch.exitCode(tampered.verdict));
}

test "git log: proof-marks each commit as verified when a receipt note is attached" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.gatedCommit("{\n  return b + a;\n}", "gated");
    const gated_oid = try case.arena().dupe(u8, try case.head());
    try case.handCommit("export function add(a: number, b: number): number {\n  return a - b;\n}\n", "by hand");
    const hand_oid = try case.arena().dupe(u8, try case.head());

    var args: std.json.ObjectMap = .empty;
    try args.put(case.arena(), "sub", .{ .string = "log" });
    try args.put(case.arena(), "path", .{ .string = case.repo.root_abs });
    try args.put(case.arena(), "n", .{ .integer = 10 });
    var event: telemetry.Event = .{ .tool = "emetgate_git" };
    const result = try handlers.callTool(testing.allocator, testing.io, case.runtime, "emetgate_git", .{ .object = args }, &event, .{ .root = case.repo.root_abs, .test_command = green });
    defer testing.allocator.free(result.text);
    try testing.expect(!result.is_error);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result.text, .{});
    defer parsed.deinit();
    const commits = parsed.value.object.get("commits").?.array;
    var saw_gated = false;
    var saw_hand = false;
    for (commits.items) |c| {
        const oid = c.object.get("commit").?.string;
        const mark = c.object.get("verification").?.string;
        if (std.mem.eql(u8, oid, gated_oid)) {
            saw_gated = true;
            try testing.expectEqualStrings("verified", mark);
        } else if (std.mem.eql(u8, oid, hand_oid)) {
            saw_hand = true;
            try testing.expectEqualStrings("unverified", mark);
        }
    }
    try testing.expect(saw_gated and saw_hand);
}

test "verify --branch: range parsing splits base..head" {
    const split = verify_branch.parseRange("main..HEAD");
    try testing.expectEqualStrings("main", split.base);
    try testing.expectEqualStrings("HEAD", split.head);
    const bare = verify_branch.parseRange("abc123");
    try testing.expectEqualStrings("abc123", bare.base);
    try testing.expectEqualStrings("HEAD", bare.head);
}
