const std = @import("std");
const builtin = @import("builtin");
const git_fixture = @import("git_fixture.zig");
const server = @import("emetgate").server;
const telemetry = @import("emetgate").telemetry;
const Runtime = @import("emetgate").runtime.Runtime;

const testing = std.testing;
const gpa = testing.allocator;
const Value = std.json.Value;

const app_js = "export function total(a, b) {\n  return a + b;\n}\n";
const fails_on_broken = "(findstr BROKEN src\\app.js >nul && exit 1 || exit 0)";

const Reply = struct {
    parsed: std.json.Parsed(Value),
    is_error: bool,
    text: []const u8,

    fn deinit(self: *Reply) void {
        self.parsed.deinit();
    }

    fn body(self: *Reply) !std.json.Parsed(Value) {
        errdefer std.debug.print("reply: {s}\n", .{self.text});
        const end = std.mem.indexOfScalar(u8, self.text, '\n') orelse self.text.len;
        return std.json.parseFromSlice(Value, gpa, self.text[0..end], .{});
    }

    fn expectAfter(self: *Reply, branch: []const u8, clean: bool) !void {
        var parsed = try self.body();
        defer parsed.deinit();
        errdefer std.debug.print("reply: {s}\n", .{self.text});
        const after = parsed.value.object.get("after").?.object;
        try testing.expectEqualStrings(branch, after.get("branch").?.string);
        try testing.expectEqual(clean, after.get("clean").?.bool);
    }

    fn expectStatus(self: *Reply, status: []const u8) !void {
        var parsed = try self.body();
        defer parsed.deinit();
        errdefer std.debug.print("reply: {s}\n", .{self.text});
        try testing.expectEqualStrings(status, parsed.value.object.get("status").?.string);
    }
};

fn run(root_abs: []const u8, args: []const []const u8) ![]u8 {
    var argv: [8][]const u8 = undefined;
    argv[0] = try git_fixture.git();
    @memcpy(argv[1..][0..args.len], args);
    const result = try @import("emetgate").bounded_run.run(gpa, testing.io, .{ .argv = argv[0 .. args.len + 1], .cwd = .{ .path = root_abs } });
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            gpa.free(result.stdout);
            return error.GitFailed;
        },
        else => {
            gpa.free(result.stdout);
            return error.GitFailed;
        },
    }
    return result.stdout;
}

fn git(root_abs: []const u8, args: []const []const u8) !void {
    gpa.free(try run(root_abs, args));
}

const Repo = struct {
    tmp: testing.TmpDir,
    root_abs: [:0]u8,
    workspace_abs: []u8,
    runtime: *Runtime,

    fn init() !Repo {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo/src");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/app.js", .data = app_js });
        const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", gpa);
        errdefer gpa.free(root_abs);
        try git_fixture.initRepo(root_abs);
        try git(root_abs, &.{ "add", "." });
        try git(root_abs, &.{ "commit", "-q", "-m", "init" });
        const workspace_abs = try std.fmt.allocPrint(gpa, "{s}\\.emetgate", .{root_abs});
        errdefer gpa.free(workspace_abs);
        return .{ .tmp = tmp, .root_abs = root_abs, .workspace_abs = workspace_abs, .runtime = try Runtime.create(gpa) };
    }

    fn deinit(self: *Repo) void {
        self.runtime.destroy() catch @panic("live snapshots");
        gpa.free(self.workspace_abs);
        gpa.free(self.root_abs);
        self.tmp.cleanup();
    }

    fn raw(self: *Repo, args: anytype, test_command: []const u8) ![]u8 {
        return self.rawAs("emetgate_change", args, test_command);
    }

    fn rawAs(self: *Repo, tool: []const u8, args: anytype, test_command: []const u8) ![]u8 {
        var line: std.Io.Writer.Allocating = .init(gpa);
        defer line.deinit();
        var js: std.json.Stringify = .{ .writer = &line.writer };
        try js.write(.{ .jsonrpc = "2.0", .id = 1, .method = "tools/call", .params = .{ .name = tool, .arguments = args } });
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        var observer: telemetry.Observer = .{ .workspace_abs = self.workspace_abs };
        _ = try server.handleMessageObserved(gpa, testing.io, self.runtime, line.written(), &out.writer, &observer, .{ .root = self.root_abs, .test_command = test_command });
        return out.toOwnedSlice();
    }

    fn call(self: *Repo, args: anytype, test_command: []const u8) !Reply {
        const text = try self.raw(args, test_command);
        defer gpa.free(text);
        const parsed = try std.json.parseFromSlice(Value, gpa, text, .{ .allocate = .alloc_always });
        errdefer parsed.deinit();
        const result = parsed.value.object.get("result") orelse return error.NotAToolResult;
        const content = result.object.get("content").?.array.items[0];
        return .{ .parsed = parsed, .is_error = result.object.get("isError").?.bool, .text = content.object.get("text").?.string };
    }

    fn expectFile(self: *Repo, rel: []const u8, expected: []const u8) !void {
        const sub = try std.fmt.allocPrint(gpa, "repo/{s}", .{rel});
        defer gpa.free(sub);
        const on_disk = try self.tmp.dir.readFileAlloc(testing.io, sub, gpa, .unlimited);
        defer gpa.free(on_disk);
        try testing.expectEqualStrings(expected, on_disk);
    }

    fn missing(self: *Repo, rel: []const u8) bool {
        const sub = std.fmt.allocPrint(gpa, "repo/{s}", .{rel}) catch return false;
        defer gpa.free(sub);
        self.tmp.dir.access(testing.io, sub, .{}) catch return true;
        return false;
    }

    fn path(self: *Repo, rel: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "{s}\\{s}", .{ self.root_abs, rel });
    }

    fn gitText(self: *Repo, args: []const []const u8) ![]u8 {
        const out = try run(self.root_abs, args);
        defer gpa.free(out);
        return gpa.dupe(u8, std.mem.trim(u8, out, " \r\n"));
    }

    fn expectGit(self: *Repo, args: []const []const u8, expected: []const u8) !void {
        const text = try self.gitText(args);
        defer gpa.free(text);
        try testing.expectEqualStrings(expected, text);
    }
};

test "emetgate_change writes an exact replacement and a new file in one gated call and reports them applied" {
    var repo = try Repo.init();
    defer repo.deinit();
    const app = try repo.path("src\\app.js");
    defer gpa.free(app);
    const add = try repo.path("src\\add.js");
    defer gpa.free(add);
    var reply = try repo.call(.{ .edits = .{
        .{ .file = app, .old_string = "return a + b;", .new_string = "return add(a, b);" },
        .{ .file = add, .content = "export function add(a, b) {\n  return a + b;\n}\n" },
    } }, "cmd /c exit 0");
    defer reply.deinit();
    errdefer std.debug.print("reply: {s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try reply.expectStatus("applied");
    try testing.expect(std.mem.indexOf(u8, reply.text, "\"committed\"") == null);
    try repo.expectFile("src/app.js", "export function total(a, b) {\n  return add(a, b);\n}\n");
    try repo.expectFile("src/add.js", "export function add(a, b) {\n  return a + b;\n}\n");
    try repo.expectGit(&.{ "log", "-1", "--format=%s" }, "init");
}

test "emetgate_change writes none of its edits when the test command fails and says where it stopped" {
    var repo = try Repo.init();
    defer repo.deinit();
    const app = try repo.path("src\\app.js");
    defer gpa.free(app);
    const extra = try repo.path("src\\extra.js");
    defer gpa.free(extra);
    var reply = try repo.call(.{ .edits = .{
        .{ .file = app, .old_string = "return a + b;", .new_string = "return a + b; BROKEN;" },
        .{ .file = extra, .content = "export const extra = 1;\n" },
    }, .commit = "never made" }, fails_on_broken);
    defer reply.deinit();
    try testing.expect(reply.is_error);
    try reply.expectStatus("stopped");
    try testing.expect(std.mem.indexOf(u8, reply.text, "\"stopped_at\":\"edits\"") != null);
    try repo.expectFile("src/app.js", app_js);
    try testing.expect(repo.missing("src/extra.js"));
    try repo.expectGit(&.{ "log", "-1", "--format=%s" }, "init");
}

test "emetgate_change creates and switches to the branch, writes the edits and commits every change with the message" {
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/notes.txt", .data = "made outside\n" });
    const health = try repo.path("src\\health.js");
    defer gpa.free(health);
    var reply = try repo.call(.{ .branch = "feature/health", .edits = .{
        .{ .file = health, .content = "export const health = () => ({ status: 'ok' });\n" },
    }, .commit = "Add health endpoint" }, "cmd /c exit 0");
    defer reply.deinit();
    errdefer std.debug.print("reply: {s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try reply.expectStatus("applied");
    try repo.expectGit(&.{ "rev-parse", "--abbrev-ref", "HEAD" }, "feature/health");
    try reply.expectAfter("feature/health", true);
    try repo.expectGit(&.{ "log", "-1", "--format=%s" }, "Add health endpoint");
    try repo.expectGit(&.{ "show", "--name-only", "--format=", "HEAD" }, "notes.txt\nsrc/health.js");
    try repo.expectGit(&.{ "status", "--porcelain" }, "");
}

test "emetgate_change with only a commit message commits the work tree as it is" {
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/app.js", .data = "export const total = (a, b) => a + b;\n" });
    var reply = try repo.call(.{ .commit = "Initial book API" }, "cmd /c exit 0");
    defer reply.deinit();
    errdefer std.debug.print("reply: {s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try reply.expectStatus("applied");
    try repo.expectGit(&.{ "log", "-1", "--format=%s" }, "Initial book API");
    try repo.expectGit(&.{ "status", "--porcelain" }, "");
}

test "emetgate_change asks for edits, commit or branch when it is given none of them" {
    var repo = try Repo.init();
    defer repo.deinit();
    const text = try repo.raw(.{ .edits = .{} }, "cmd /c exit 0");
    defer gpa.free(text);
    errdefer std.debug.print("reply: {s}\n", .{text});
    try testing.expect(std.mem.indexOf(u8, text, "\"error\":{") != null);
    try testing.expect(std.mem.indexOf(u8, text, "edits, commit or branch") != null);
    try repo.expectGit(&.{ "log", "-1", "--format=%s" }, "init");
}

test "emetgate_change answers a file name Windows cannot hold with an error and writes nothing" {
    var repo = try Repo.init();
    defer repo.deinit();
    var reply = try repo.call(.{ .edits = .{
        .{ .file = "src/a?b.js", .content = "export const x = 1;\n" },
    } }, "cmd /c exit 0");
    defer reply.deinit();
    errdefer std.debug.print("reply: {s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try reply.expectStatus("stopped");
    try repo.expectGit(&.{ "status", "--porcelain" }, "");
}

test "emetgate_change commits a gated edit and a file written outside the gate in one commit with one receipt" {
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/package.json", .data = "{\"name\":\"app\"}\n" });
    const app = try repo.path("src\\app.js");
    defer gpa.free(app);
    var reply = try repo.call(.{ .edits = .{
        .{ .file = app, .old_string = "return a + b;", .new_string = "return b + a;" },
    }, .commit = "Initial book API" }, "cmd /c exit 0");
    defer reply.deinit();
    errdefer std.debug.print("reply: {s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    var parsed = try reply.body();
    defer parsed.deinit();
    const commit = parsed.value.object.get("commit").?.object;
    try testing.expectEqualStrings("applied", commit.get("status").?.string);
    try testing.expectEqual(@as(i64, 2), commit.get("files").?.integer);
    try testing.expectEqual(@as(i64, 1), commit.get("receipts").?.integer);
    try repo.expectGit(&.{ "show", "--name-only", "--format=", "HEAD" }, "package.json\nsrc/app.js");
    try repo.expectGit(&.{ "status", "--porcelain" }, "");
}

test "emetgate_change after a branch alone names the new branch and says the work tree still holds the uncommitted file" {
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/notes.txt", .data = "made outside\n" });
    var reply = try repo.call(.{ .branch = "feature/notes" }, "cmd /c exit 0");
    defer reply.deinit();
    errdefer std.debug.print("reply: {s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try reply.expectAfter("feature/notes", false);
}

test "emetgate_change leaves after out when it only writes edits" {
    var repo = try Repo.init();
    defer repo.deinit();
    const app = try repo.path("src\\app.js");
    defer gpa.free(app);
    var reply = try repo.call(.{ .edits = .{
        .{ .file = app, .old_string = "return a + b;", .new_string = "return b + a;" },
    } }, "cmd /c exit 0");
    defer reply.deinit();
    errdefer std.debug.print("reply: {s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expect(std.mem.indexOf(u8, reply.text, "\"after\"") == null);
}
