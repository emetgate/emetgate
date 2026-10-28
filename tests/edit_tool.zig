const std = @import("std");
const builtin = @import("builtin");
const git_fixture = @import("git_fixture.zig");
const server = @import("emetgate").server;
const telemetry = @import("emetgate").telemetry;
const memory = @import("emetgate").memory;
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

    fn expectStatus(self: *Reply, status: []const u8) !void {
        errdefer std.debug.print("reply: {s}\n", .{self.text});
        const end = std.mem.indexOfScalar(u8, self.text, '\n') orelse self.text.len;
        const body = try std.json.parseFromSlice(Value, gpa, self.text[0..end], .{});
        defer body.deinit();
        try testing.expectEqualStrings(status, body.value.object.get("status").?.string);
    }

    fn expectError(self: *Reply, name: []const u8) !void {
        errdefer std.debug.print("reply: {s}\n", .{self.text});
        try testing.expect(self.is_error);
        try testing.expect(std.mem.indexOf(u8, self.text, name) != null);
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
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/README.md", .data = "# App\n\nold line\nold line\n" });
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

    fn call(self: *Repo, tool: []const u8, args: anytype) !Reply {
        return self.callWith(tool, args, "cmd /c exit 0");
    }

    fn callWith(self: *Repo, tool: []const u8, args: anytype, test_command: []const u8) !Reply {
        var line: std.Io.Writer.Allocating = .init(gpa);
        defer line.deinit();
        var js: std.json.Stringify = .{ .writer = &line.writer };
        try js.write(.{ .jsonrpc = "2.0", .id = 1, .method = "tools/call", .params = .{ .name = tool, .arguments = args } });
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var observer: telemetry.Observer = .{ .workspace_abs = self.workspace_abs };
        _ = try server.handleMessageObserved(gpa, testing.io, self.runtime, line.written(), &out.writer, &observer, .{ .root = self.root_abs, .test_command = test_command });
        const parsed = try std.json.parseFromSlice(Value, gpa, out.written(), .{ .allocate = .alloc_always });
        errdefer parsed.deinit();
        const result = parsed.value.object.get("result") orelse return error.NotAToolResult;
        const content = result.object.get("content").?.array.items[0];
        return .{ .parsed = parsed, .is_error = result.object.get("isError").?.bool, .text = content.object.get("text").?.string };
    }

    fn read(self: *Repo, rel: []const u8) ![]u8 {
        const sub = try std.fmt.allocPrint(gpa, "repo/{s}", .{rel});
        defer gpa.free(sub);
        return self.tmp.dir.readFileAlloc(testing.io, sub, gpa, .unlimited);
    }

    fn expectFile(self: *Repo, rel: []const u8, expected: []const u8) !void {
        const on_disk = try self.read(rel);
        defer gpa.free(on_disk);
        try testing.expectEqualStrings(expected, on_disk);
    }

    fn missing(self: *Repo, rel: []const u8) bool {
        const sub = std.fmt.allocPrint(gpa, "repo/{s}", .{rel}) catch return false;
        defer gpa.free(sub);
        self.tmp.dir.access(testing.io, sub, .{}) catch return true;
        return false;
    }
};

test "emetgate_edit replaces one unique line through the gate with a reply that never echoes the file" {
    var repo = try Repo.init();
    defer repo.deinit();
    var reply = try repo.call("emetgate_edit", .{ .file = "src/app.js", .old_string = "return a + b;", .new_string = "return a + b + 0;" });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    try reply.expectStatus("committed");
    try testing.expect(std.mem.indexOf(u8, reply.text, "export function") == null);
    try testing.expect(reply.text.len < 200);
    try repo.expectFile("src/app.js", "export function total(a, b) {\n  return a + b + 0;\n}\n");
}

test "emetgate_edit refuses an old_string that is missing or repeated and states the match count" {
    var repo = try Repo.init();
    defer repo.deinit();
    var absent = try repo.call("emetgate_edit", .{ .file = "README.md", .old_string = "nowhere", .new_string = "x" });
    defer absent.deinit();
    try absent.expectError("OldStringNotFound");
    try testing.expect(std.mem.indexOf(u8, absent.text, "matches 0 times") != null);
    var twice = try repo.call("emetgate_edit", .{ .file = "README.md", .old_string = "old line", .new_string = "new line" });
    defer twice.deinit();
    try twice.expectError("OldStringNotUnique");
    try testing.expect(std.mem.indexOf(u8, twice.text, "matches 2 times") != null);
    try repo.expectFile("README.md", "# App\n\nold line\nold line\n");
    var all = try repo.call("emetgate_edit", .{ .file = "README.md", .old_string = "old line", .new_string = "new line", .replace_all = true });
    defer all.deinit();
    try all.expectStatus("committed");
    try repo.expectFile("README.md", "# App\n\nnew line\nnew line\n");
}

test "emetgate_edit leaves the file untouched when the test command fails in the shadow" {
    var repo = try Repo.init();
    defer repo.deinit();
    var reply = try repo.callWith("emetgate_edit", .{ .file = "src/app.js", .old_string = "return a + b;", .new_string = "return a + b; BROKEN;" }, fails_on_broken);
    defer reply.deinit();
    try testing.expect(reply.is_error);
    try reply.expectStatus("rejected");
    try repo.expectFile("src/app.js", app_js);
}

test "emetgate_edit refuses a code edit that breaks the syntax of a clean file" {
    var repo = try Repo.init();
    defer repo.deinit();
    var reply = try repo.call("emetgate_edit", .{ .file = "src/app.js", .old_string = "return a + b;\n}", .new_string = "return a + b;\n" });
    defer reply.deinit();
    try reply.expectError("MutationSyntaxInvalid");
    try repo.expectFile("src/app.js", app_js);
}

test "emetgate_edit is refused by an enforced rule on the new text" {
    var repo = try Repo.init();
    defer repo.deinit();
    const id = try memory.remember(gpa, testing.io, repo.root_abs, .project, "no comments", true, "no_comment", null);
    gpa.free(id);
    var reply = try repo.call("emetgate_edit", .{ .file = "src/app.js", .old_string = "return a + b;", .new_string = "// sum\n  return a + b;" });
    defer reply.deinit();
    try testing.expect(reply.is_error);
    try testing.expect(std.mem.indexOf(u8, reply.text, "rule_violation") != null);
    try repo.expectFile("src/app.js", app_js);
}

test "emetgate_write creates a code file under missing directories and non-code files at the root" {
    var repo = try Repo.init();
    defer repo.deinit();
    var code = try repo.call("emetgate_write", .{ .file = "src/a/b.js", .content = "export const b = 1;\n" });
    defer code.deinit();
    try code.expectStatus("committed");
    try repo.expectFile("src/a/b.js", "export const b = 1;\n");
    var manifest = try repo.call("emetgate_write", .{ .file = "package.json", .content = "{\"name\":\"app\"}\n" });
    defer manifest.deinit();
    try manifest.expectStatus("committed");
    try repo.expectFile("package.json", "{\"name\":\"app\"}\n");
    var ignored = try repo.call("emetgate_write", .{ .file = ".gitignore", .content = "node_modules/\n" });
    defer ignored.deinit();
    try ignored.expectStatus("committed");
    try repo.expectFile(".gitignore", "node_modules/\n");
    var same = try repo.call("emetgate_write", .{ .file = "package.json", .content = "{\"name\":\"app\"}\n" });
    defer same.deinit();
    try same.expectStatus("unchanged");
}

test "emetgate_write that fails the gate leaves no file and no created directory behind" {
    var repo = try Repo.init();
    defer repo.deinit();
    var broken = try repo.call("emetgate_write", .{ .file = "src/x/y/z.js", .content = "export function (\n" });
    defer broken.deinit();
    try broken.expectError("MutationSyntaxInvalid");
    try testing.expect(repo.missing("src/x"));
    var rejected = try repo.callWith("emetgate_write", .{ .file = "src/p/q.js", .content = "export const q = 1;\n" }, "cmd /c exit 1");
    defer rejected.deinit();
    try testing.expect(rejected.is_error);
    try rejected.expectStatus("rejected");
    try testing.expect(repo.missing("src/p"));
}

test "emetgate_write replaces a whole existing file and refuses paths outside the repo" {
    var repo = try Repo.init();
    defer repo.deinit();
    var whole = try repo.call("emetgate_write", .{ .file = "src/app.js", .content = "export const total = 3;\n" });
    defer whole.deinit();
    try whole.expectStatus("committed");
    try repo.expectFile("src/app.js", "export const total = 3;\n");
    var outside = try repo.call("emetgate_write", .{ .file = "../escape.txt", .content = "x" });
    defer outside.deinit();
    try testing.expect(outside.is_error);
    try testing.expect(repo.missing("../escape.txt"));
    var internal = try repo.call("emetgate_write", .{ .file = ".git/config2", .content = "x" });
    defer internal.deinit();
    try testing.expect(internal.is_error);
}

test "emetgate_write refuses binary content and a new file under an ignored path" {
    var repo = try Repo.init();
    defer repo.deinit();
    var binary = try repo.call("emetgate_write", .{ .file = "data.txt", .content = "a\x00b" });
    defer binary.deinit();
    try binary.expectError("BinaryFile");
    try testing.expect(repo.missing("data.txt"));
    var rules = try repo.call("emetgate_write", .{ .file = ".gitignore", .content = "dist/\n" });
    defer rules.deinit();
    try rules.expectStatus("committed");
    var ignored = try repo.call("emetgate_write", .{ .file = "dist/out.js", .content = "export const x = 1;\n" });
    defer ignored.deinit();
    try ignored.expectError("IgnoredPath");
    try testing.expect(repo.missing("dist"));
}

test "emetgate_edit matches a LF old_string in a CRLF file" {
    var repo = try Repo.init();
    defer repo.deinit();
    var crlf = try repo.call("emetgate_write", .{ .file = "notes.txt", .content = "one\r\ntwo\r\n" });
    defer crlf.deinit();
    try crlf.expectStatus("committed");
    var reply = try repo.call("emetgate_edit", .{ .file = "notes.txt", .old_string = "one\ntwo", .new_string = "one\n2" });
    defer reply.deinit();
    try reply.expectStatus("committed");
    try repo.expectFile("notes.txt", "one\r\n2\r\n");
}
