const std = @import("std");
const builtin = @import("builtin");
const git_fixture = @import("git_fixture.zig");
const server = @import("emetgate").server;
const symbol = @import("emetgate").symbol;
const batch_stage = @import("emetgate").batch_stage;
const wire = @import("emetgate").wire;
const Runtime = @import("emetgate").runtime.Runtime;

const testing = std.testing;
const gpa = testing.allocator;
const Value = std.json.Value;

const spare = "export function unused(): number {\n  return 7;\n}\n";
const gate = "cmd /c findstr /c:good src\\b.ts";

const Repo = struct {
    tmp: testing.TmpDir,
    root_abs: [:0]u8,
    store: batch_stage.Store,

    fn init(self: *Repo) !void {
        self.tmp = testing.tmpDir(.{ .iterate = true });
        errdefer self.tmp.cleanup();
        try self.tmp.dir.createDirPath(testing.io, "repo/src");
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/spare.ts", .data = spare });
        self.root_abs = try self.tmp.dir.realPathFileAlloc(testing.io, "repo", gpa);
        errdefer gpa.free(self.root_abs);
        try git_fixture.initRepo(self.root_abs);
        try git(self.root_abs, &.{ "add", "." });
        try git(self.root_abs, &.{ "commit", "-q", "-m", "init" });
        self.store = .init(gpa);
    }

    fn deinit(self: *Repo) void {
        self.store.deinit();
        gpa.free(self.root_abs);
        self.tmp.cleanup();
    }

    fn read(self: *Repo, rel: []const u8) !?[]u8 {
        const path = try std.fmt.allocPrint(gpa, "repo/{s}", .{rel});
        defer gpa.free(path);
        return self.tmp.dir.readFileAlloc(testing.io, path, gpa, .unlimited) catch |err| switch (err) {
            error.FileNotFound => null,
            else => |e| e,
        };
    }

    fn expectFile(self: *Repo, rel: []const u8, want: ?[]const u8) !void {
        const got = try self.read(rel);
        defer if (got) |g| gpa.free(g);
        if (want == null or got == null) return testing.expect(want == null and got == null);
        try testing.expectEqualStrings(want.?, got.?);
    }

    fn rooted(self: *Repo, line: []const u8) ![]u8 {
        const prefix = try std.fmt.allocPrint(gpa, "\"{s}/src/", .{self.root_abs});
        defer gpa.free(prefix);
        const escaped = try std.mem.replaceOwned(u8, gpa, prefix, "\\", "/");
        defer gpa.free(escaped);
        return std.mem.replaceOwned(u8, gpa, line, "\"src/", escaped);
    }

    fn call(self: *Repo, arguments: []const u8) !Reply {
        const line = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"emetgate_try_batch\",\"arguments\":{s}}}}}", .{arguments});
        defer gpa.free(line);
        const absolute = try self.rooted(line);
        defer gpa.free(absolute);
        const runtime = try Runtime.create(gpa);
        defer runtime.destroy() catch @panic("live snapshots");
        var buffer: std.Io.Writer.Allocating = .init(gpa);
        defer buffer.deinit();
        _ = try server.handleMessageObserved(gpa, testing.io, runtime, absolute, &buffer.writer, null, .{ .test_command = gate, .root = self.root_abs, .batch_stage = &self.store });
        return Reply.parse(buffer.written());
    }
};

fn git(root_abs: []const u8, args: []const []const u8) !void {
    var argv: [8][]const u8 = undefined;
    argv[0] = "git";
    @memcpy(argv[1..][0..args.len], args);
    const result = try @import("emetgate").bounded_run.run(gpa, testing.io, .{ .argv = argv[0 .. args.len + 1], .cwd = .{ .path = root_abs } });
    gpa.free(result.stdout);
    gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitSetupFailed,
        else => return error.GitSetupFailed,
    }
}

const Reply = struct {
    envelope: std.json.Parsed(Value),
    body: std.json.Parsed(Value),
    text: []const u8,
    is_error: bool,

    fn parse(raw: []const u8) !Reply {
        const envelope = try std.json.parseFromSlice(Value, gpa, raw, .{});
        errdefer envelope.deinit();
        const result = envelope.value.object.get("result").?.object;
        const text = result.get("content").?.array.items[0].object.get("text").?.string;
        const first = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
        const body = try std.json.parseFromSlice(Value, gpa, first, .{});
        return .{ .envelope = envelope, .body = body, .text = text, .is_error = result.get("isError").?.bool };
    }

    fn deinit(self: *Reply) void {
        self.body.deinit();
        self.envelope.deinit();
    }

    fn string(self: *const Reply, key: []const u8) ?[]const u8 {
        const value = self.body.value.object.get(key) orelse return null;
        return if (value == .string) value.string else null;
    }
};

const first_batch =
    \\{"edits":[{"file":"src/a.ts","hash":"absent","content":"export const a = 1;\n"},{"file":"src/b.ts","hash":"absent","content":"export const b = 'bad';\n"}]}
;

test "batch retry: a rejected batch is kept under a retry id, and a retry that sends only the changed item commits the whole merged batch" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo: Repo = undefined;
    try repo.init();
    defer repo.deinit();
    var rejected = try repo.call(first_batch);
    defer rejected.deinit();
    errdefer std.debug.print("{s}\n", .{rejected.text});
    try testing.expect(rejected.is_error);
    try testing.expectEqualStrings("rejected", rejected.string("status").?);
    const id = rejected.string("retry").?;
    try testing.expectEqual(batch_stage.id_len, id.len);
    try repo.expectFile("src/a.ts", null);

    const retry = try std.fmt.allocPrint(gpa, "{{\"retry\":\"{s}\",\"edits\":[{{\"file\":\"src/b.ts\",\"hash\":\"absent\",\"content\":\"export const b = 'good';\\n\"}}]}}", .{id});
    defer gpa.free(retry);
    var committed = try repo.call(retry);
    defer committed.deinit();
    errdefer std.debug.print("{s}\n", .{committed.text});
    try testing.expect(!committed.is_error);
    try testing.expectEqualStrings("written", committed.string("status").?);
    try testing.expectEqualStrings(wire.verified_text, committed.string("verified").?);
    try repo.expectFile("src/a.ts", "export const a = 1;\n");
    try repo.expectFile("src/b.ts", "export const b = 'good';\n");

    var again = try repo.call(retry);
    defer again.deinit();
    try testing.expectEqualStrings("StagedBatchUnknown", again.string("error").?);
}

test "batch retry: a file delete refused for its missing hash is retried with only that item and its hash" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo: Repo = undefined;
    try repo.init();
    defer repo.deinit();
    var refused = try repo.call(
        \\{"edits":[{"file":"src/b.ts","hash":"absent","content":"export const b = 'good';\n"},{"file":"src/spare.ts","op":"delete"}]}
    );
    defer refused.deinit();
    errdefer std.debug.print("{s}\n", .{refused.text});
    try testing.expectEqualStrings("MissingFileHash", refused.string("error").?);
    const hash = symbol.formatHash(symbol.fileHash(spare));
    try testing.expect(std.mem.indexOf(u8, refused.string("fix").?, &hash) != null);
    const id = refused.string("retry").?;

    const retry = try std.fmt.allocPrint(gpa, "{{\"retry\":\"{s}\",\"edits\":[{{\"file\":\"src/spare.ts\",\"op\":\"delete\",\"hash\":\"{s}\"}}]}}", .{ id, &hash });
    defer gpa.free(retry);
    var committed = try repo.call(retry);
    defer committed.deinit();
    errdefer std.debug.print("{s}\n", .{committed.text});
    try testing.expect(!committed.is_error);
    try repo.expectFile("src/b.ts", "export const b = 'good';\n");
    try repo.expectFile("src/spare.ts", null);
}

test "batch retry: a kept batch whose file changed on disk is refused as stale and nothing is written" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo: Repo = undefined;
    try repo.init();
    defer repo.deinit();
    var rejected = try repo.call(first_batch);
    defer rejected.deinit();
    const id = rejected.string("retry").?;
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/a.ts", .data = "export const a = 2;\n" });

    const retry = try std.fmt.allocPrint(gpa, "{{\"retry\":\"{s}\",\"edits\":[{{\"file\":\"src/b.ts\",\"hash\":\"absent\",\"content\":\"export const b = 'good';\\n\"}}]}}", .{id});
    defer gpa.free(retry);
    var stale = try repo.call(retry);
    defer stale.deinit();
    errdefer std.debug.print("{s}\n", .{stale.text});
    try testing.expect(stale.is_error);
    try testing.expectEqualStrings("StagedBatchStale", stale.string("error").?);
    try testing.expect(std.mem.indexOf(u8, stale.string("fix").?, "a.ts") != null);
    try repo.expectFile("src/a.ts", "export const a = 2;\n");
    try repo.expectFile("src/b.ts", null);
}

test "batch retry: an unknown retry id is refused and a retry that is still rejected keeps its id" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo: Repo = undefined;
    try repo.init();
    defer repo.deinit();
    var unknown = try repo.call("{\"retry\":\"0123abcd\"}");
    defer unknown.deinit();
    try testing.expectEqualStrings("StagedBatchUnknown", unknown.string("error").?);

    var rejected = try repo.call(first_batch);
    defer rejected.deinit();
    const id = rejected.string("retry").?;
    const retry = try std.fmt.allocPrint(gpa, "{{\"retry\":\"{s}\"}}", .{id});
    defer gpa.free(retry);
    var still = try repo.call(retry);
    defer still.deinit();
    try testing.expectEqualStrings("rejected", still.string("status").?);
    try testing.expectEqualStrings(id, still.string("retry").?);
    try repo.expectFile("src/a.ts", null);
}

fn attrib(root_abs: []const u8, flag: []const u8) !void {
    const result = try @import("emetgate").bounded_run.run(gpa, testing.io, .{ .argv = &.{ "attrib", flag, "src\\spare.ts" }, .cwd = .{ .path = root_abs } });
    gpa.free(result.stdout);
    gpa.free(result.stderr);
}

test "batch retry: a batch whose commit started and failed is not kept for a retry" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo: Repo = undefined;
    try repo.init();
    defer repo.deinit();
    try attrib(repo.root_abs, "+r");
    defer attrib(repo.root_abs, "-r") catch {};
    const hash = symbol.formatHash(symbol.fileHash(spare));
    const batch = try std.fmt.allocPrint(gpa, "{{\"edits\":[{{\"file\":\"src/b.ts\",\"hash\":\"absent\",\"content\":\"export const b = 'good';\\n\"}},{{\"file\":\"src/spare.ts\",\"hash\":\"{s}\",\"content\":\"export const spare = 1;\\n\"}}]}}", .{&hash});
    defer gpa.free(batch);
    var failed = try repo.call(batch);
    defer failed.deinit();
    errdefer std.debug.print("{s}\n", .{failed.text});
    try testing.expect(failed.is_error);
    try testing.expect(std.mem.indexOf(u8, failed.text, "disk untouched") == null);
    try testing.expect(failed.string("retry") == null);
}
