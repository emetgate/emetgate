const std = @import("std");
const builtin = @import("builtin");
const handlers = @import("emetgate").handlers;
const telemetry = @import("emetgate").telemetry;
const memory = @import("emetgate").memory;
const symbol = @import("emetgate").symbol;
const Policy = @typeInfo(@TypeOf(handlers.callTool)).@"fn".params[6].type.?;
const Runtime = @import("emetgate").runtime.Runtime;
const fixture = @import("ts_fixture.zig");

const testing = std.testing;
const TsRepo = fixture.TsRepo;
const Value = std.json.Value;

const package_before = "{\"name\": \"demo\", \"scripts\": {\"build\": \"tsc\"}}\n";
const package_after = "{\"name\": \"demo\", \"scripts\": {\"build\": \"tsc --noEmit\"}}\n";
const old_value = "\"tsc\"";
const new_value = "\"tsc --noEmit\"";
const notes_before = "# Notes\n\nText.\n";
const green = "cmd /c exit 0";
const red = "cmd /c exit 1";

pub const Case = struct {
    repo: TsRepo,
    runtime: *Runtime,
    arena_state: std.heap.ArenaAllocator,

    pub fn init(self: *Case) !void {
        self.repo = try TsRepo.init(&.{
            .{ .rel = "package.json", .text = package_before },
            .{ .rel = "notes.md", .text = notes_before },
            .{ .rel = ".gitignore", .text = ".emetgate/\n" },
        });
        errdefer self.repo.deinit();
        self.runtime = try Runtime.create(testing.allocator);
        self.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    }

    pub fn deinit(self: *Case) void {
        self.arena_state.deinit();
        self.runtime.destroy() catch @panic("live snapshots");
        self.repo.deinit();
    }

    pub fn arena(self: *Case) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    pub fn git(self: *Case, argv: []const []const u8) ![]const u8 {
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

    pub const Reply = struct { value: Value, is_error: bool, text: []const u8 };

    pub fn call(self: *Case, tool: []const u8, fields: []const [2][]const u8, policy: Policy) !Reply {
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

    pub fn writeBuild(self: *Case, message: ?[]const u8, policy: Policy) !Reply {
        const hash = try self.arena().dupe(u8, &symbol.formatHash(symbol.hashOf(old_value)));
        var fields: std.ArrayList([2][]const u8) = .empty;
        try fields.appendSlice(self.arena(), &.{ .{ "file", "package.json" }, .{ "pointer", "/scripts/build" }, .{ "hash", hash }, .{ "content", new_value } });
        if (message) |text| try fields.append(self.arena(), .{ "message", text });
        return self.call("emetgate_write_doc", fields.items, policy);
    }

    pub fn expectUntouched(self: *Case, head: []const u8) !void {
        try testing.expectEqualStrings(head, try self.git(&.{ "rev-parse", "HEAD" }));
        try testing.expectEqualStrings("", try self.git(&.{ "status", "--porcelain" }));
        const on_disk = try self.repo.read("package.json");
        defer testing.allocator.free(on_disk);
        try testing.expectEqualStrings(package_before, on_disk);
    }
};

pub const committing: Policy = .{ .test_command = green, .commit = true };

test "commit write_doc: an accepted write is one commit with the given message and the written bytes" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const before = try case.git(&.{ "rev-parse", "HEAD" });

    const reply = try case.writeBuild("build: typecheck without emitting", committing);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings("committed", reply.value.object.get("status").?.string);
    const commit = (reply.value.object.get("commit") orelse return error.TestExpectedCommit).string;

    try testing.expectEqualStrings(commit, try case.git(&.{ "rev-parse", "HEAD" }));
    try testing.expectEqualStrings(before, try case.git(&.{ "rev-parse", "HEAD^" }));
    try testing.expectEqualStrings("build: typecheck without emitting", try case.git(&.{ "log", "-1", "--format=%B" }));
    try testing.expectEqualStrings("M\tpackage.json", try case.git(&.{ "diff", "--name-status", "HEAD^", "HEAD" }));
    try testing.expectEqualStrings("", try case.git(&.{ "status", "--porcelain" }));
    const on_disk = try case.repo.read("package.json");
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(package_after, on_disk);
    try testing.expectEqualStrings(std.mem.trim(u8, package_after, "\n"), try case.git(&.{ "show", "HEAD:package.json" }));
    try testing.expectEqualStrings(try case.git(&.{ "hash-object", "package.json" }), try case.git(&.{ "rev-parse", "HEAD:package.json" }));
}

test "commit write_doc: a write the tests reject leaves no commit and no write" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const before = try case.git(&.{ "rev-parse", "HEAD" });
    const reply = try case.writeBuild("build: typecheck", .{ .test_command = red, .commit = true });
    try testing.expect(reply.is_error);
    try testing.expectEqualStrings("rejected", reply.value.object.get("status").?.string);
    try case.expectUntouched(before);
}

test "commit write_doc: a message that breaks a message rule is refused with the rule, and nothing is written" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const before = try case.git(&.{ "rev-parse", "HEAD" });
    const id = try memory.remember(testing.allocator, testing.io, case.repo.root_abs, .project, "one line", true, "message:max_lines:1", null);
    defer testing.allocator.free(id);

    const reply = try case.writeBuild("build: typecheck\n\nA body.", committing);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try testing.expect(std.mem.indexOf(u8, reply.text, "\"reason\":\"rule_violation\"") != null);
    try testing.expect(std.mem.indexOf(u8, reply.text, id) != null);
    try case.expectUntouched(before);

    const passing = try case.writeBuild("build: typecheck", committing);
    try testing.expect(!passing.is_error);
}

test "commit write_doc: with commits on a call without a message is refused, with commits off a call with one is refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const before = try case.git(&.{ "rev-parse", "HEAD" });

    const missing = try case.writeBuild(null, committing);
    try testing.expect(missing.is_error);
    try testing.expect(std.mem.indexOf(u8, missing.text, "MissingCommitMessage") != null);
    try case.expectUntouched(before);

    const unasked = try case.writeBuild("build: typecheck", .{ .test_command = green });
    try testing.expect(unasked.is_error);
    try testing.expect(std.mem.indexOf(u8, unasked.text, "CommitNotEnabled") != null);
    try case.expectUntouched(before);
}

test "commit write_doc: a target edited by hand is refused and keeps the hand edit" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const before = try case.git(&.{ "rev-parse", "HEAD" });
    const edited = "{\"name\": \"mine\", \"scripts\": {\"build\": \"tsc\"}}\n";
    try case.repo.write("package.json", edited);

    const reply = try case.writeBuild("build: typecheck", committing);
    try testing.expect(reply.is_error);
    try testing.expect(std.mem.indexOf(u8, reply.text, "TargetHasUncommittedChanges") != null);
    try testing.expectEqualStrings(before, try case.git(&.{ "rev-parse", "HEAD" }));
    const on_disk = try case.repo.read("package.json");
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(edited, on_disk);
}

test "commit write_doc: a target git does not track yet is refused and stays as it was" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const before = try case.git(&.{ "rev-parse", "HEAD" });
    const draft = "{\"build\": \"tsc\"}\n";
    try case.repo.write("draft.json", draft);

    const hash = try case.arena().dupe(u8, &symbol.formatHash(symbol.hashOf(old_value)));
    const reply = try case.call("emetgate_write_doc", &.{ .{ "file", "draft.json" }, .{ "pointer", "/build" }, .{ "hash", hash }, .{ "content", new_value }, .{ "message", "build: typecheck" } }, committing);
    try testing.expect(reply.is_error);
    try testing.expect(std.mem.indexOf(u8, reply.text, "TargetNotInHead") != null);
    try testing.expectEqualStrings(before, try case.git(&.{ "rev-parse", "HEAD" }));
    const on_disk = try case.repo.read("draft.json");
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(draft, on_disk);
}

test "commit write_doc: a hand edit to another file stays in the working tree and out of the commit" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const mine = "# Notes\n\nMine.\n";
    try case.repo.write("notes.md", mine);

    const reply = try case.writeBuild("build: typecheck", committing);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings("M\tpackage.json", try case.git(&.{ "diff", "--name-status", "HEAD^", "HEAD" }));
    try testing.expectEqualStrings("M notes.md", try case.git(&.{ "status", "--porcelain" }));
    const on_disk = try case.repo.read("notes.md");
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(mine, on_disk);
}

test "commit write_doc: with commits off an accepted write makes no commit" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const before = try case.git(&.{ "rev-parse", "HEAD" });
    const reply = try case.writeBuild(null, .{ .test_command = green });
    try testing.expect(!reply.is_error);
    try testing.expect(reply.value.object.get("commit") == null);
    try testing.expectEqualStrings(before, try case.git(&.{ "rev-parse", "HEAD" }));
    try testing.expectEqualStrings("M package.json", try case.git(&.{ "status", "--porcelain" }));
}
