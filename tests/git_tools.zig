const std = @import("std");
const git_fixture = @import("git_fixture.zig");
const server = @import("emetgate").server;
const Runtime = @import("emetgate").runtime.Runtime;

const testing = std.testing;
const gpa = testing.allocator;
const Value = std.json.Value;

const Reply = struct {
    parsed: std.json.Parsed(Value),
    is_error: bool,
    text: []const u8,

    fn deinit(self: *Reply) void {
        self.parsed.deinit();
    }

    fn payload(self: *Reply) !std.json.Parsed(Value) {
        const end = std.mem.indexOfScalar(u8, self.text, '\n') orelse self.text.len;
        return std.json.parseFromSlice(Value, gpa, self.text[0..end], .{});
    }
};

const Repo = struct {
    tmp: testing.TmpDir,
    root_abs: [:0]u8,

    fn init() !Repo {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "outside.txt", .data = "not part of the repo\n" });
        const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", gpa);
        errdefer gpa.free(root_abs);
        try git_fixture.initRepo(root_abs);
        return .{ .tmp = tmp, .root_abs = root_abs };
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

    fn git(self: *Repo, args: []const []const u8) !void {
        var argv: [8][]const u8 = undefined;
        argv[0] = "git";
        @memcpy(argv[1..][0..args.len], args);
        const result = try std.process.run(gpa, testing.io, .{ .argv = argv[0 .. args.len + 1], .cwd = .{ .path = self.root_abs } });
        gpa.free(result.stdout);
        gpa.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.GitSetupFailed,
            else => return error.GitSetupFailed,
        }
    }

    fn commitAll(self: *Repo, message: []const u8) !void {
        try self.git(&.{ "add", "." });
        try self.git(&.{ "commit", "-q", "-m", message });
    }
};

fn callTool(runtime: *Runtime, root_abs: []const u8, args: anytype) !Reply {
    var line: std.Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    var js: std.json.Stringify = .{ .writer = &line.writer };
    try js.write(.{ .jsonrpc = "2.0", .id = 1, .method = "tools/call", .params = .{ .name = "emetgate_git", .arguments = args } });

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try server.handleMessageObserved(gpa, testing.io, runtime, line.written(), &out.writer, null, .{ .root = root_abs });

    const parsed = try std.json.parseFromSlice(Value, gpa, out.written(), .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    const result = parsed.value.object.get("result") orelse return error.NotAToolResult;
    const content = result.object.get("content").?.array.items[0];
    return .{ .parsed = parsed, .is_error = result.object.get("isError").?.bool, .text = content.object.get("text").?.string };
}

fn expectError(runtime: *Runtime, root_abs: []const u8, args: anytype, name: []const u8) !void {
    var reply = try callTool(runtime, root_abs, args);
    defer reply.deinit();
    try testing.expect(reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expectEqualStrings(name, body.value.object.get("error").?.string);
}

test "git status lists an untracked file" {
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.writeFile("a.txt", "one\n");

    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try callTool(runtime, repo.root_abs, .{ .sub = "status", .path = repo.root_abs });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expect(std.mem.indexOf(u8, body.value.object.get("output").?.string, "a.txt") != null);
}

test "git log reports commits newest first and n clamps the count" {
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.writeFile("a.txt", "one\n");
    try repo.commitAll("first");
    try repo.writeFile("a.txt", "two\n");
    try repo.commitAll("second");

    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try callTool(runtime, repo.root_abs, .{ .sub = "log", .n = 1, .path = repo.root_abs });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    const output = body.value.object.get("output").?.string;
    try testing.expect(std.mem.indexOf(u8, output, "second") != null);
    try testing.expect(std.mem.indexOf(u8, output, "first") == null);
    try testing.expectEqual(@as(i64, 1), body.value.object.get("lines_shown").?.integer);
}

test "git diff shows a working tree change, cached shows a staged one" {
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.writeFile("a.txt", "one\n");
    try repo.commitAll("first");
    try repo.writeFile("a.txt", "two\n");

    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var working = try callTool(runtime, repo.root_abs, .{ .sub = "diff", .path = repo.root_abs });
    defer working.deinit();
    try testing.expect(!working.is_error);
    var working_body = try working.payload();
    defer working_body.deinit();
    try testing.expect(std.mem.indexOf(u8, working_body.value.object.get("output").?.string, "-one") != null);

    try repo.git(&.{ "add", "a.txt" });
    var staged = try callTool(runtime, repo.root_abs, .{ .sub = "diff", .staged = true, .path = repo.root_abs });
    defer staged.deinit();
    var staged_body = try staged.payload();
    defer staged_body.deinit();
    try testing.expect(std.mem.indexOf(u8, staged_body.value.object.get("output").?.string, "+two") != null);
}

test "git show returns one commit and refuses a malformed commit id" {
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.writeFile("a.txt", "one\n");
    try repo.commitAll("first");

    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try callTool(runtime, repo.root_abs, .{ .sub = "show", .commit = "HEAD", .path = repo.root_abs });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expect(std.mem.startsWith(u8, body.value.object.get("output").?.string, "commit "));

    try expectError(runtime, repo.root_abs, .{ .sub = "show", .commit = "; whoami", .path = repo.root_abs }, "InvalidCommit");
    try expectError(runtime, repo.root_abs, .{ .sub = "show", .path = repo.root_abs }, "MissingCommit");
}

test "git refuses an unknown subcommand and a path outside the repo" {
    var repo = try Repo.init();
    defer repo.deinit();

    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    try expectError(runtime, repo.root_abs, .{ .sub = "clone", .path = repo.root_abs }, "UnknownGitSubcommand");

    const outside = try std.fmt.allocPrint(gpa, "{s}\\..\\outside.txt", .{repo.root_abs});
    defer gpa.free(outside);
    try expectError(runtime, repo.root_abs, .{ .sub = "log", .path = outside }, "FileOutsideRepo");
}

test "git diff caps output at a line count and marks it truncated" {
    var repo = try Repo.init();
    defer repo.deinit();
    var big_before: std.Io.Writer.Allocating = .init(gpa);
    defer big_before.deinit();
    for (0..1500) |i| try big_before.writer.print("line {d}\n", .{i});
    try repo.writeFile("big.txt", big_before.written());
    try repo.commitAll("big file");

    var big_after: std.Io.Writer.Allocating = .init(gpa);
    defer big_after.deinit();
    for (0..1500) |i| try big_after.writer.print("changed {d}\n", .{i});
    try repo.writeFile("big.txt", big_after.written());

    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try callTool(runtime, repo.root_abs, .{ .sub = "diff", .path = repo.root_abs });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expect(body.value.object.get("truncated").?.bool);
    try testing.expect(body.value.object.get("lines_shown").?.integer < body.value.object.get("lines_total").?.integer);
}
