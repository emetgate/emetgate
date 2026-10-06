const std = @import("std");
const builtin = @import("builtin");
const handlers = @import("emetgate").handlers;
const telemetry = @import("emetgate").telemetry;
const memory = @import("emetgate").memory;
const Policy = @typeInfo(@TypeOf(handlers.callTool)).@"fn".params[6].type.?;
const Runtime = @import("emetgate").runtime.Runtime;
const fixture = @import("ts_fixture.zig");
const support = @import("runner_support.zig");

const testing = std.testing;
const TsRepo = fixture.TsRepo;
const Value = std.json.Value;

const util_src = "export function add(a: number, b: number): number {\n  return a + b;\n}\n";
const new_body = "{\n  return b + a;\n}";
const util_after = "export function add(a: number, b: number): number {\n  return b + a;\n}\n";
const green = "cmd /c exit 0";
const red = "cmd /c exit 1";

const Case = struct {
    repo: TsRepo,
    runtime: *Runtime,
    arena_state: std.heap.ArenaAllocator,

    fn init(self: *Case) !void {
        self.repo = try TsRepo.init(&.{
            .{ .rel = "src/util.ts", .text = util_src },
            .{ .rel = "notes.md", .text = "# Notes\n\nText.\n" },
            .{ .rel = ".gitignore", .text = ".emetgate/\n" },
        });
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
        var full: std.ArrayList([]const u8) = .empty;
        try full.append(self.arena(), "git");
        try full.appendSlice(self.arena(), argv);
        const result = try std.process.run(self.arena(), testing.io, .{ .argv = full.items, .cwd = .{ .path = self.repo.root_abs } });
        switch (result.term) {
            .exited => |code| if (code != 0) return error.GitCommandFailed,
            else => return error.GitCommandFailed,
        }
        return std.mem.trim(u8, result.stdout, " \r\n");
    }

    fn addHash(self: *Case) ![]const u8 {
        const file = try self.repo.abs(self.arena(), "src/util.ts");
        const hash = try support.hashOfRef(testing.allocator, testing.io, self.runtime, file, "add");
        return self.arena().dupe(u8, &std.fmt.bytesToHex(hash, .lower));
    }

    const Reply = struct { value: Value, is_error: bool, text: []const u8 };

    fn call(self: *Case, tool: []const u8, fields: []const [2][]const u8, policy: Policy) !Reply {
        var map: std.json.ObjectMap = .empty;
        for (fields) |field| {
            const value = if (std.mem.eql(u8, field[0], "file")) try self.repo.abs(self.arena(), field[1]) else field[1];
            try map.put(self.arena(), field[0], .{ .string = value });
        }
        var event: telemetry.Event = .{ .tool = tool };
        var with_root = policy;
        with_root.root = self.repo.root_abs;
        const result = try handlers.callTool(testing.allocator, testing.io, self.runtime, tool, .{ .object = map }, &event, with_root);
        defer testing.allocator.free(result.text);
        const text = try self.arena().dupe(u8, result.text);
        return .{ .value = try std.json.parseFromSliceLeaky(Value, self.arena(), text, .{}), .is_error = result.is_error, .text = text };
    }

    fn expectUntouched(self: *Case, head: []const u8) !void {
        try testing.expectEqualStrings(head, try self.git(&.{ "rev-parse", "HEAD" }));
        try testing.expectEqualStrings("", try self.git(&.{ "status", "--porcelain" }));
        const on_disk = try self.repo.read("src/util.ts");
        defer testing.allocator.free(on_disk);
        try testing.expectEqualStrings(util_src, on_disk);
    }
};

const committing: Policy = .{ .test_command = green, .commit = true };

test "commit on write: an accepted try is one commit with the given message and bytes, and its receipt rides on it" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const before = try case.git(&.{ "rev-parse", "HEAD" });

    const reply = try case.call("emetgate_try", &.{ .{ "file", "src/util.ts" }, .{ "symbol", "add" }, .{ "hash", try case.addHash() }, .{ "body", new_body }, .{ "message", "fix(util): swap the operands" } }, committing);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings("committed", reply.value.object.get("status").?.string);
    const commit = reply.value.object.get("commit").?.string;
    try testing.expect(reply.value.object.get("receipt_attach_error") == null);

    try testing.expectEqualStrings(commit, try case.git(&.{ "rev-parse", "HEAD" }));
    try testing.expectEqualStrings(before, try case.git(&.{ "rev-parse", "HEAD^" }));
    try testing.expectEqualStrings("fix(util): swap the operands", try case.git(&.{ "log", "-1", "--format=%B" }));
    try testing.expectEqualStrings("M\tsrc/util.ts", try case.git(&.{ "diff", "--name-status", "HEAD^", "HEAD" }));
    try testing.expectEqualStrings("", try case.git(&.{ "status", "--porcelain" }));
    const on_disk = try case.repo.read("src/util.ts");
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(util_after, on_disk);
    try testing.expectEqualStrings(std.mem.trim(u8, util_after, "\n"), try case.git(&.{ "show", "HEAD:src/util.ts" }));
    const note = try case.git(&.{ "notes", "--ref=emetgate", "show", "HEAD" });
    try testing.expect(std.mem.indexOf(u8, note, "src/util.ts") != null);
}

test "commit on write: a change the tests reject leaves no commit and no write" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const before = try case.git(&.{ "rev-parse", "HEAD" });
    const reply = try case.call("emetgate_try", &.{ .{ "file", "src/util.ts" }, .{ "symbol", "add" }, .{ "hash", try case.addHash() }, .{ "body", new_body }, .{ "message", "fix: swap" } }, .{ .test_command = red, .commit = true });
    try testing.expect(reply.is_error);
    try testing.expectEqualStrings("rejected", reply.value.object.get("status").?.string);
    try case.expectUntouched(before);
}

test "commit on write: a message that breaks a message rule is refused with the rule, and nothing is written" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const before = try case.git(&.{ "rev-parse", "HEAD" });
    const id = try memory.remember(testing.allocator, testing.io, case.repo.root_abs, .project, "one line", true, "message:max_lines:1", null);
    defer testing.allocator.free(id);

    const reply = try case.call("emetgate_try", &.{ .{ "file", "src/util.ts" }, .{ "symbol", "add" }, .{ "hash", try case.addHash() }, .{ "body", new_body }, .{ "message", "fix: swap\n\nA body." } }, committing);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try testing.expectEqualStrings("rule_violation", reply.value.object.get("reason").?.string);
    try testing.expect(std.mem.indexOf(u8, reply.text, id) != null);
    try testing.expect(std.mem.indexOf(u8, reply.text, "message:max_lines:1") != null);
    try case.expectUntouched(before);

    const passing = try case.call("emetgate_try", &.{ .{ "file", "src/util.ts" }, .{ "symbol", "add" }, .{ "hash", try case.addHash() }, .{ "body", new_body }, .{ "message", "fix: swap" } }, committing);
    try testing.expect(!passing.is_error);
}

test "commit on write: with commits on a call without a message is refused, with commits off a call with one is refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const before = try case.git(&.{ "rev-parse", "HEAD" });

    const missing = try case.call("emetgate_try", &.{ .{ "file", "src/util.ts" }, .{ "symbol", "add" }, .{ "hash", try case.addHash() }, .{ "body", new_body } }, committing);
    try testing.expect(missing.is_error);
    try testing.expect(std.mem.indexOf(u8, missing.text, "MissingCommitMessage") != null);
    try case.expectUntouched(before);

    const unasked = try case.call("emetgate_try", &.{ .{ "file", "src/util.ts" }, .{ "symbol", "add" }, .{ "hash", try case.addHash() }, .{ "body", new_body }, .{ "message", "fix: swap" } }, .{ .test_command = green });
    try testing.expect(unasked.is_error);
    try testing.expect(std.mem.indexOf(u8, unasked.text, "CommitNotEnabled") != null);
    try case.expectUntouched(before);
}

test "commit on write: a target edited by hand is refused and keeps the hand edit" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const before = try case.git(&.{ "rev-parse", "HEAD" });
    const edited = "export function add(a: number, b: number): number {\n  return a + b + 0;\n}\n";
    try case.repo.write("src/util.ts", edited);

    const reply = try case.call("emetgate_try", &.{ .{ "file", "src/util.ts" }, .{ "symbol", "add" }, .{ "hash", try case.addHash() }, .{ "body", new_body }, .{ "message", "fix: swap" } }, committing);
    try testing.expect(reply.is_error);
    try testing.expect(std.mem.indexOf(u8, reply.text, "TargetHasUncommittedChanges") != null);
    try testing.expectEqualStrings(before, try case.git(&.{ "rev-parse", "HEAD" }));
    const on_disk = try case.repo.read("src/util.ts");
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(edited, on_disk);
}

test "commit on write: a new file is created and committed in the same call" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const reply = try case.call("emetgate_try", &.{ .{ "file", "src/fresh.ts" }, .{ "symbol", "fresh" }, .{ "hash", "absent" }, .{ "body", "export function fresh(): number {\n  return 1;\n}\n" }, .{ "message", "feat: a fresh file" } }, committing);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings(reply.value.object.get("commit").?.string, try case.git(&.{ "rev-parse", "HEAD" }));
    try testing.expectEqualStrings("A\tsrc/fresh.ts", try case.git(&.{ "diff", "--name-status", "HEAD^", "HEAD" }));
    try testing.expectEqualStrings("", try case.git(&.{ "status", "--porcelain" }));
}

test "commit on write: a write tool that cannot commit yet refuses while commits are on" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try testing.expectError(error.CommitNotSupportedByTool, case.call("emetgate_write_doc", &.{ .{ "file", "notes.md" }, .{ "heading", "Notes" }, .{ "hash", "0" }, .{ "text", "# Notes\n" } }, committing));
    try testing.expectError(error.CommitNotSupportedByTool, case.call("emetgate_try_batch", &.{}, committing));
}
