const std = @import("std");
const builtin = @import("builtin");
const git_fixture = @import("git_fixture.zig");
const server = @import("emetgate").server;
const telemetry = @import("emetgate").telemetry;
const bounded_run = @import("emetgate").bounded_run;
const Runtime = @import("emetgate").runtime.Runtime;

const testing = std.testing;
const gpa = testing.allocator;
const Value = std.json.Value;

const File = struct { rel: []const u8, text: []const u8 };

const Reply = struct {
    parsed: std.json.Parsed(Value),
    body: std.json.Parsed(Value),
    is_error: bool,
    text: []const u8,

    fn deinit(self: *Reply) void {
        self.body.deinit();
        self.parsed.deinit();
    }

    fn field(self: *Reply, name: []const u8) ?Value {
        return self.body.value.object.get(name);
    }

    fn string(self: *Reply, name: []const u8) []const u8 {
        const value = self.field(name) orelse return "";
        return switch (value) {
            .string => |s| s,
            else => "",
        };
    }
};

fn git(root_abs: []const u8, args: []const []const u8) !void {
    var argv: [8][]const u8 = undefined;
    argv[0] = "git";
    @memcpy(argv[1..][0..args.len], args);
    const result = try bounded_run.run(gpa, testing.io, .{ .argv = argv[0 .. args.len + 1], .cwd = .{ .path = root_abs } });
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

    fn init(files: []const File) !Repo {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.gitignore", .data = ".emetgate/\n__pycache__/\n.pytest_cache/\n" });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/pytest.ini", .data = "[pytest]\n" });
        for (files) |file| {
            const sub = try std.fmt.allocPrint(gpa, "repo/{s}", .{file.rel});
            defer gpa.free(sub);
            try tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = file.text });
        }
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
        var line: std.Io.Writer.Allocating = .init(gpa);
        defer line.deinit();
        var js: std.json.Stringify = .{ .writer = &line.writer };
        try js.write(.{ .jsonrpc = "2.0", .id = 1, .method = "tools/call", .params = .{ .name = tool, .arguments = args } });
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var observer: telemetry.Observer = .{ .workspace_abs = self.workspace_abs };
        _ = try server.handleMessageObserved(gpa, testing.io, self.runtime, line.written(), &out.writer, &observer, .{ .root = self.root_abs, .detect_test = true });
        const parsed = try std.json.parseFromSlice(Value, gpa, out.written(), .{ .allocate = .alloc_always });
        errdefer parsed.deinit();
        const result = parsed.value.object.get("result") orelse return error.NotAToolResult;
        const text = result.object.get("content").?.array.items[0].object.get("text").?.string;
        const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
        const body = try std.json.parseFromSlice(Value, gpa, text[0..end], .{ .allocate = .alloc_always });
        return .{ .parsed = parsed, .body = body, .is_error = result.object.get("isError").?.bool, .text = text };
    }

    fn expectFile(self: *Repo, rel: []const u8, expected: []const u8) !void {
        const sub = try std.fmt.allocPrint(gpa, "repo/{s}", .{rel});
        defer gpa.free(sub);
        const on_disk = try self.tmp.dir.readFileAlloc(testing.io, sub, gpa, .unlimited);
        defer gpa.free(on_disk);
        try testing.expectEqualStrings(expected, on_disk);
    }
};

const calc_test = "from calc import add\n\n\ndef test_add():\n    assert add(1, 2) == 3\n";
const calc_ok = "def add(a, b):\n    return a + b\n";
const calc_wrong = "def add(a, b):\n    return a - b\n";
const passing = "def test_old():\n    assert True\n";

test "regression gate: a test written first is accepted as debt, commit is refused until it passes, then commits" {
    var repo = try Repo.init(&.{.{ .rel = "test_old.py", .text = passing }});
    defer repo.deinit();

    var first = try repo.call("emetgate_write", .{ .file = "test_calc.py", .content = calc_test });
    defer first.deinit();
    errdefer std.debug.print("{s}\n", .{first.text});
    try testing.expect(!first.is_error);
    try testing.expect(std.mem.indexOf(u8, first.string("failing_tests"), "test_calc.py") != null);
    try testing.expect(std.mem.indexOf(u8, first.string("failing_tests"), "refused") != null);
    try testing.expect(first.field("verified") == null);

    var refused = try repo.call("emetgate_commit", .{ .message = "add calc test" });
    defer refused.deinit();
    errdefer std.debug.print("{s}\n", .{refused.text});
    try testing.expect(refused.is_error);
    try testing.expectEqualStrings("TestsFailing", refused.string("error"));
    const named = refused.field("failing").?.array.items;
    try testing.expectEqual(@as(usize, 1), named.len);
    try testing.expectEqualStrings("test_calc.py", named[0].string);
    try testing.expect(refused.string("fix").len != 0);

    var fixed = try repo.call("emetgate_write", .{ .file = "calc.py", .content = calc_ok });
    defer fixed.deinit();
    errdefer std.debug.print("{s}\n", .{fixed.text});
    try testing.expect(!fixed.is_error);
    try testing.expect(fixed.field("failing_tests") == null);

    var landed = try repo.call("emetgate_commit", .{ .message = "add calc" });
    defer landed.deinit();
    errdefer std.debug.print("{s}\n", .{landed.text});
    try testing.expect(!landed.is_error);
    try testing.expectEqualStrings("committed", landed.string("status"));
}

test "regression gate: a write that breaks a test that passed is rejected and names the test" {
    var repo = try Repo.init(&.{ .{ .rel = "calc.py", .text = calc_ok }, .{ .rel = "test_calc.py", .text = calc_test } });
    defer repo.deinit();

    var broken = try repo.call("emetgate_write", .{ .file = "calc.py", .content = calc_wrong });
    defer broken.deinit();
    errdefer std.debug.print("{s}\n", .{broken.text});
    try testing.expect(broken.is_error);
    try testing.expectEqualStrings("test_calc.py::test_add", broken.string("regressed"));
    try repo.expectFile("calc.py", calc_ok);
}

test "regression gate: a test that failed before the session neither blocks a write nor the commit" {
    var repo = try Repo.init(&.{ .{ .rel = "test_old.py", .text = passing }, .{ .rel = "test_broken.py", .text = "def test_broken():\n    assert False\n" } });
    defer repo.deinit();

    var write = try repo.call("emetgate_write", .{ .file = "other.py", .content = "X = 1\n" });
    defer write.deinit();
    errdefer std.debug.print("{s}\n", .{write.text});
    try testing.expect(!write.is_error);
    try testing.expect(std.mem.indexOf(u8, write.string("failing_tests"), "test_broken.py::test_broken") != null);
    try testing.expect(std.mem.indexOf(u8, write.string("failing_tests"), "not blocked") != null);
    try testing.expect(write.field("verified") == null);

    var landed = try repo.call("emetgate_commit", .{ .message = "add other" });
    defer landed.deinit();
    errdefer std.debug.print("{s}\n", .{landed.text});
    try testing.expect(!landed.is_error);
    try testing.expectEqualStrings("committed", landed.string("status"));
}
