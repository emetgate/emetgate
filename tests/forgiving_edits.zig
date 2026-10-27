const std = @import("std");
const builtin = @import("builtin");
const git_fixture = @import("git_fixture.zig");
const server = @import("emetgate").server;
const telemetry = @import("emetgate").telemetry;
const symbol = @import("emetgate").symbol;
const batch_plan = @import("emetgate").batch_plan;
const Runtime = @import("emetgate").runtime.Runtime;

const testing = std.testing;
const gpa = testing.allocator;
const Value = std.json.Value;

const app_js = "export function total(a, b) {\n  return a + b;\n}\n";
const readme = "# App\n\nold\n";

const Reply = struct {
    parsed: std.json.Parsed(Value),
    is_error: bool,
    text: []const u8,

    fn deinit(self: *Reply) void {
        self.parsed.deinit();
    }

    fn expectWritten(self: *Reply) !void {
        errdefer std.debug.print("reply: {s}\n", .{self.text});
        try testing.expect(!self.is_error);
        try testing.expect(std.mem.indexOf(u8, self.text, "\"status\":\"written\"") != null);
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
    const result = try std.process.run(gpa, testing.io, .{ .argv = argv[0 .. args.len + 1], .cwd = .{ .path = root_abs } });
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
    runtime: *Runtime,

    fn init() !Repo {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo/src");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/app.js", .data = app_js });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/README.md", .data = readme });
        const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", gpa);
        errdefer gpa.free(root_abs);
        try git_fixture.initRepo(root_abs);
        try git(root_abs, &.{ "add", "." });
        try git(root_abs, &.{ "commit", "-q", "-m", "init" });
        return .{ .tmp = tmp, .root_abs = root_abs, .runtime = try Runtime.create(gpa) };
    }

    fn deinit(self: *Repo) void {
        self.runtime.destroy() catch @panic("live snapshots");
        gpa.free(self.root_abs);
        self.tmp.cleanup();
    }

    fn path(self: *Repo, rel: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "{s}\\{s}", .{ self.root_abs, rel });
    }

    fn call(self: *Repo, tool: []const u8, args: anytype) !Reply {
        var line: std.Io.Writer.Allocating = .init(gpa);
        defer line.deinit();
        var js: std.json.Stringify = .{ .writer = &line.writer };
        try js.write(.{ .jsonrpc = "2.0", .id = 1, .method = "tools/call", .params = .{ .name = tool, .arguments = args } });
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const workspace = try std.fmt.allocPrint(gpa, "{s}\\.emetgate", .{self.root_abs});
        defer gpa.free(workspace);
        var observer: telemetry.Observer = .{ .workspace_abs = workspace };
        _ = try server.handleMessageObserved(gpa, testing.io, self.runtime, line.written(), &out.writer, &observer, .{ .root = self.root_abs, .test_command = "cmd /c exit 0" });
        const parsed = try std.json.parseFromSlice(Value, gpa, out.written(), .{ .allocate = .alloc_always });
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

    fn expectMissing(self: *Repo, rel: []const u8) !void {
        const sub = try std.fmt.allocPrint(gpa, "repo/{s}", .{rel});
        defer gpa.free(sub);
        try testing.expectError(error.FileNotFound, self.tmp.dir.access(testing.io, sub, .{}));
    }
};

test "forgiving edits: try_batch with hash absent and content but no symbol creates the whole file in a new directory" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const file = try repo.path("pkg\\tools\\settings.toml");
    defer gpa.free(file);
    var reply = try repo.call("emetgate_try_batch", .{ .edits = .{
        .{ .file = file, .hash = "absent", .content = "name = \"app\"\n" },
    } });
    defer reply.deinit();
    try reply.expectWritten();
    try repo.expectFile("pkg/tools/settings.toml", "name = \"app\"\n");
}

test "forgiving edits: try with path and body but no symbol creates a source file whole" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const file = try repo.path("src\\util.js");
    defer gpa.free(file);
    var reply = try repo.call("emetgate_try", .{ .path = file, .hash = "", .body = "export const one = 1;\n" });
    defer reply.deinit();
    try reply.expectWritten();
    try repo.expectFile("src/util.js", "export const one = 1;\n");
}

test "forgiving edits: a kind doc line range on a JavaScript file goes through the gate and is written" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const file = try repo.path("src\\app.js");
    defer gpa.free(file);
    const hash = symbol.formatHash(symbol.hashOf("  return a + b;\n"));
    var reply = try repo.call("emetgate_try_batch", .{ .edits = .{
        .{ .kind = "doc", .file = file, .hash = hash[0..], .start_line = @as(i64, 2), .end_line = @as(i64, 2), .content = "  return b + a;\n" },
    } });
    defer reply.deinit();
    try reply.expectWritten();
    try repo.expectFile("src/app.js", "export function total(a, b) {\n  return b + a;\n}\n");
}

test "forgiving edits: a line range is accepted under the whole file's hash too" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const file = try repo.path("src\\app.js");
    defer gpa.free(file);
    const hash = symbol.formatHash(symbol.fileHash(app_js));
    var reply = try repo.call("emetgate_try_batch", .{ .edits = .{
        .{ .file = file, .hash = hash[0..], .line = @as(i64, 2), .content = "  return a - b;\n" },
    } });
    defer reply.deinit();
    try reply.expectWritten();
    try repo.expectFile("src/app.js", "export function total(a, b) {\n  return a - b;\n}\n");
}

test "forgiving edits: an old and new text pair on a source file in try_batch is replaced through the gate" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const file = try repo.path("src\\app.js");
    defer gpa.free(file);
    var reply = try repo.call("emetgate_try_batch", .{ .edits = .{
        .{ .file_path = file, .old_str = "a + b", .new_str = "a * b" },
    } });
    defer reply.deinit();
    try reply.expectWritten();
    try repo.expectFile("src/app.js", "export function total(a, b) {\n  return a * b;\n}\n");
}

test "forgiving edits: a whole-file write under a stale hash is refused and nothing is written" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const file = try repo.path("README.md");
    defer gpa.free(file);
    const stale = symbol.formatHash(symbol.fileHash("# Other\n"));
    var reply = try repo.call("emetgate_try_batch", .{ .edits = .{
        .{ .file = file, .hash = stale[0..], .content = "# App\n\nnew\n" },
    } });
    defer reply.deinit();
    try reply.expectError("HashMismatch");
    try repo.expectFile("README.md", readme);
}

test "forgiving edits: write_doc with hash absent and no selector creates a document" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const file = try repo.path("pyproject.toml");
    defer gpa.free(file);
    var reply = try repo.call("emetgate_write_doc", .{ .file = file, .hash = "absent", .pointer = "", .content = "[project]\nname = \"app\"\n" });
    defer reply.deinit();
    try reply.expectWritten();
    try repo.expectFile("pyproject.toml", "[project]\nname = \"app\"\n");
}

test "forgiving edits: emetgate_write takes body as content" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const file = try repo.path("notes.txt");
    defer gpa.free(file);
    var reply = try repo.call("emetgate_write", .{ .path = file, .body = "hi\n" });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    try repo.expectFile("notes.txt", "hi\n");
}

test "forgiving edits: a symbol edit with neither symbol nor content still names the missing field" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const file = try repo.path("src\\app.js");
    defer gpa.free(file);
    try testing.expectError(error.NotAToolResult, repo.call("emetgate_try_batch", .{ .edits = .{.{ .file = file }} }));
    try repo.expectFile("src/app.js", app_js);
}

test "textAfter keeps a whole-file write to its hash and reads a line range under the file hash" {
    const whole: batch_plan.Text = .{ .whole = "b\n" };
    try testing.expectError(error.HashMismatch, batch_plan.textAfter(gpa, "a\n", .{ .present = symbol.fileHash("z\n") }, whole));
    const replaced = try batch_plan.textAfter(gpa, "a\n", .{ .present = symbol.fileHash("a\n") }, whole);
    defer gpa.free(replaced);
    try testing.expectEqualStrings("b\n", replaced);
    const region: batch_plan.Text = .{ .region = .{ .selector = .{ .line_range = .{ .start = 2, .end = 2 } }, .new_text = "y\n" } };
    const ranged = try batch_plan.textAfter(gpa, "x\nb\nz\n", .{ .present = symbol.fileHash("x\nb\nz\n") }, region);
    defer gpa.free(ranged);
    try testing.expectEqualStrings("x\ny\nz\n", ranged);
    try testing.expectError(error.HashMismatch, batch_plan.textAfter(gpa, "x\nb\nz\n", .absent, region));
}
