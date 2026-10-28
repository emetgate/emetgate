const std = @import("std");
const builtin = @import("builtin");
const git_fixture = @import("git_fixture.zig");
const server = @import("emetgate").server;
const Runtime = @import("emetgate").runtime.Runtime;

const testing = std.testing;
const gpa = testing.allocator;
const Value = std.json.Value;

const Repo = struct {
    tmp: testing.TmpDir,
    root_abs: [:0]u8,

    fn init() !Repo {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo");
        const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", gpa);
        errdefer gpa.free(root_abs);
        try git_fixture.initRepo(root_abs);
        var repo: Repo = .{ .tmp = tmp, .root_abs = root_abs };
        gpa.free(try repo.git(&.{ "config", "core.autocrlf", "false" }));
        return repo;
    }

    fn deinit(self: *Repo) void {
        gpa.free(self.root_abs);
        self.tmp.cleanup();
    }

    fn writeFile(self: *Repo, rel: []const u8, data: []const u8) !void {
        const target = try std.fmt.allocPrint(gpa, "repo/{s}", .{rel});
        defer gpa.free(target);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = target, .data = data });
    }

    fn readFile(self: *Repo, rel: []const u8) ![]u8 {
        const target = try std.fmt.allocPrint(gpa, "repo/{s}", .{rel});
        defer gpa.free(target);
        return self.tmp.dir.readFileAlloc(testing.io, target, gpa, .limited(1024 * 1024));
    }

    fn git(self: *Repo, args: []const []const u8) ![]u8 {
        var argv: [8][]const u8 = undefined;
        argv[0] = "git";
        @memcpy(argv[1..][0..args.len], args);
        const result = try @import("emetgate").bounded_run.run(gpa, testing.io, .{ .argv = argv[0 .. args.len + 1], .cwd = .{ .path = self.root_abs } });
        defer gpa.free(result.stderr);
        errdefer gpa.free(result.stdout);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.GitSetupFailed,
            else => return error.GitSetupFailed,
        }
        return result.stdout;
    }

    fn commitAll(self: *Repo, message: []const u8) !void {
        gpa.free(try self.git(&.{ "add", "." }));
        gpa.free(try self.git(&.{ "commit", "-q", "-m", message }));
    }
};

const Reply = struct {
    parsed: std.json.Parsed(Value),
    body: std.json.Parsed(Value),
    is_error: bool,

    fn deinit(self: *Reply) void {
        self.body.deinit();
        self.parsed.deinit();
    }

    fn string(self: *Reply, name: []const u8) ?[]const u8 {
        const value = self.body.value.object.get(name) orelse return null;
        return if (value == .string) value.string else null;
    }
};

fn call(runtime: *Runtime, root_abs: []const u8, args: anytype) !Reply {
    var line: std.Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    var js: std.json.Stringify = .{ .writer = &line.writer };
    try js.write(.{ .jsonrpc = "2.0", .id = 1, .method = "tools/call", .params = .{ .name = "emetgate_git_write", .arguments = args } });

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try server.handleMessageObserved(gpa, testing.io, runtime, line.written(), &out.writer, null, .{ .root = root_abs });

    const parsed = try std.json.parseFromSlice(Value, gpa, out.written(), .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    const result = parsed.value.object.get("result") orelse return error.NotAToolResult;
    const text = result.object.get("content").?.array.items[0].object.get("text").?.string;
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    errdefer std.debug.print("{s}\n", .{text});
    const body = try std.json.parseFromSlice(Value, gpa, text[0..end], .{ .allocate = .alloc_always });
    return .{ .parsed = parsed, .body = body, .is_error = result.object.get("isError").?.bool };
}

test "git write creates and switches to a branch, commits on it and reports head and shortstat" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.writeFile("version.txt", "11.2.0\n");
    try repo.commitAll("init");
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var switched = try call(runtime, repo.root_abs, .{ .args = .{ "switch", "-c", "release-11.3.0" } });
    defer switched.deinit();
    try testing.expect(!switched.is_error);
    try testing.expectEqualStrings("ok", switched.string("status").?);
    try testing.expectEqualStrings("release-11.3.0", switched.string("branch").?);

    try repo.writeFile("version.txt", "11.3.0\n");
    var committed = try call(runtime, repo.root_abs, .{ .args = .{ "commit", "-a", "-m", "Bump version to 11.3.0" } });
    defer committed.deinit();
    try testing.expect(!committed.is_error);
    try testing.expectEqualStrings("1 file changed, 1 insertion(+), 1 deletion(-)", committed.string("shortstat").?);
    const head = try repo.git(&.{ "rev-parse", "HEAD" });
    defer gpa.free(head);
    try testing.expectEqualStrings(std.mem.trim(u8, head, "\r\n"), committed.string("head").?);
    const subject = try repo.git(&.{ "log", "-1", "--format=%s", "release-11.3.0" });
    defer gpa.free(subject);
    try testing.expectEqualStrings("Bump version to 11.3.0\n", subject);
}

test "git write refuses a hard reset that would lose work until force is true" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.writeFile("a.txt", "one\n");
    try repo.commitAll("init");
    try repo.writeFile("a.txt", "uncommitted\n");
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var refused = try call(runtime, repo.root_abs, .{ .args = .{ "reset", "--hard" } });
    defer refused.deinit();
    try testing.expect(refused.is_error);
    try testing.expectEqualStrings("would_lose_work", refused.string("reason").?);
    const kept = try repo.readFile("a.txt");
    defer gpa.free(kept);
    try testing.expectEqualStrings("uncommitted\n", kept);

    var forced = try call(runtime, repo.root_abs, .{ .args = .{ "reset", "--hard" }, .force = true });
    defer forced.deinit();
    try testing.expect(!forced.is_error);
    const reset = try repo.readFile("a.txt");
    defer gpa.free(reset);
    try testing.expectEqualStrings("one\n", reset);
}

test "git write treats checkout of a branch as a switch and checkout of a path as work-losing" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.writeFile("a.txt", "one\n");
    try repo.commitAll("init");
    gpa.free(try repo.git(&.{ "branch", "topic" }));
    try repo.writeFile("a.txt", "dirty\n");
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var path = try call(runtime, repo.root_abs, .{ .args = .{ "checkout", "a.txt" } });
    defer path.deinit();
    try testing.expectEqualStrings("would_lose_work", path.string("reason").?);

    var branch = try call(runtime, repo.root_abs, .{ .args = .{ "checkout", "topic" } });
    defer branch.deinit();
    try testing.expect(!branch.is_error);
    try testing.expectEqualStrings("topic", branch.string("branch").?);
    const kept = try repo.readFile("a.txt");
    defer gpa.free(kept);
    try testing.expectEqualStrings("dirty\n", kept);
}

test "git write refuses a flag that runs a program and a subcommand outside the list" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.writeFile("a.txt", "one\n");
    try repo.commitAll("init");
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var exec = try call(runtime, repo.root_abs, .{ .args = .{ "rebase", "--exec", "calc", "HEAD" } });
    defer exec.deinit();
    try testing.expectEqualStrings("unsupported_flag", exec.string("reason").?);
    var config = try call(runtime, repo.root_abs, .{ .args = .{ "config", "core.hooksPath", "x" } });
    defer config.deinit();
    try testing.expectEqualStrings("unsupported_subcommand", config.string("reason").?);
}
