//! The gate fails closed and never claims what it did not verify:
//! no "verified" without a test that ran, every changed file is tested,
//! a test or typecheck command that cannot start refuses the write, and a
//! git-ignored path is refused before anything is written.
const std = @import("std");
const builtin = @import("builtin");
const git_fixture = @import("git_fixture.zig");
const server = @import("emetgate").server;
const wire = @import("emetgate").wire;
const baseline = @import("emetgate").baseline;
const test_outcome = @import("emetgate").test_outcome;
const telemetry = @import("emetgate").telemetry;
const Runtime = @import("emetgate").runtime.Runtime;
const KnownFiles = @import("emetgate").known_files.KnownFiles;

const testing = std.testing;
const gpa = testing.allocator;
const Value = std.json.Value;

const app_js = "export function total(a, b) {\n  return a + b;\n}\n";
const readme = "# Title\n\nOLD heading text\n";
const passing = "cmd /c echo 1 passing";
const readme_test = "(findstr OLD README.md >nul && echo 1 passing && exit 0 || exit 1)";
const missing_program = "emetgate_absent_program_42 --run";

const Repo = struct {
    tmp: testing.TmpDir,
    root_abs: [:0]u8,
    workspace_abs: []u8,
    runtime: *Runtime,
    known: KnownFiles,

    fn init() !Repo {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo/src");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/app.js", .data = app_js });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/README.md", .data = readme });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.gitignore", .data = "ignored/\n" });
        const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", gpa);
        errdefer gpa.free(root_abs);
        try git_fixture.initRepo(root_abs);
        try git_fixture.commitInit(root_abs, false);
        const workspace_abs = try std.fmt.allocPrint(gpa, "{s}\\.emetgate", .{root_abs});
        errdefer gpa.free(workspace_abs);
        return .{ .tmp = tmp, .root_abs = root_abs, .workspace_abs = workspace_abs, .runtime = try Runtime.create(gpa), .known = .init(gpa) };
    }

    fn deinit(self: *Repo) void {
        self.known.deinit();
        self.runtime.destroy() catch @panic("live snapshots");
        gpa.free(self.workspace_abs);
        gpa.free(self.root_abs);
        self.tmp.cleanup();
    }

    fn change(self: *Repo, args: anytype, policy: server.Policy) !Reply {
        var line: std.Io.Writer.Allocating = .init(gpa);
        defer line.deinit();
        var js: std.json.Stringify = .{ .writer = &line.writer };
        try js.write(.{ .jsonrpc = "2.0", .id = 1, .method = "tools/call", .params = .{ .name = "emetgate_change", .arguments = args } });
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var observer: telemetry.Observer = .{ .workspace_abs = self.workspace_abs };
        var given = policy;
        given.root = self.root_abs;
        given.known_files = &self.known;
        _ = try server.handleMessageObserved(gpa, testing.io, self.runtime, line.written(), &out.writer, &observer, given);
        const envelope = try std.json.parseFromSlice(Value, gpa, out.written(), .{ .allocate = .alloc_always });
        defer envelope.deinit();
        const result = envelope.value.object.get("result") orelse return error.NotAToolResult;
        const text = try gpa.dupe(u8, result.object.get("content").?.array.items[0].object.get("text").?.string);
        errdefer gpa.free(text);
        const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
        const body = try std.json.parseFromSlice(Value, gpa, text[0..end], .{ .allocate = .alloc_always });
        return .{ .text = text, .body = body, .is_error = result.object.get("isError").?.bool };
    }

    fn path(self: *Repo, rel: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "{s}\\{s}", .{ self.root_abs, rel });
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

const Reply = struct {
    text: []u8,
    body: std.json.Parsed(Value),
    is_error: bool,

    fn deinit(self: *Reply) void {
        self.body.deinit();
        gpa.free(self.text);
    }

    fn edits(self: *Reply) std.json.ObjectMap {
        return self.body.value.object.get("edits").?.object;
    }

    fn claimsVerified(self: *Reply) bool {
        return std.mem.indexOf(u8, self.text, wire.verified_text) != null;
    }
};

fn summaryOf(stdout: []const u8) test_outcome.Summary {
    return test_outcome.summarize(.{ .outcome = .{ .exited = 0 }, .duration_ns = 0, .stdout = @constCast(stdout), .stderr = @constCast(""), .truncated = false, .killed_leftovers = false });
}

test "gate fail closed: a run counts as testing only when its summary shows a test that ran" {
    try testing.expect(test_outcome.ranSome(summaryOf("  3 passing (5ms)\n")));
    try testing.expect(test_outcome.ranSome(summaryOf("Ran 2 tests in 0.001s\n")));
    try testing.expect(test_outcome.ranSome(summaryOf("test result: ok. 5 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s\n")));
    try testing.expect(test_outcome.ranSome(summaryOf("ok  \texample.com/pkg\t0.012s\n")));
    try testing.expect(!test_outcome.ranSome(summaryOf("")));
    try testing.expect(!test_outcome.ranSome(summaryOf("  0 passing (1ms)\n")));
    try testing.expect(!test_outcome.ranSome(summaryOf("Tests: 0 passed, 0 total\n")));
}

test "gate fail closed: with no test command the change reply says unverified_no_tests and never verified" {
    var repo = try Repo.init();
    defer repo.deinit();
    const fresh = try repo.path("src\\fresh.js");
    defer gpa.free(fresh);
    var reply = try repo.change(.{ .edits = .{.{ .file = fresh, .content = "export const fresh = 1;\n" }} }, .{ .detect_test = true });
    defer reply.deinit();
    errdefer std.debug.print("reply: {s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expect(!reply.claimsVerified());
    try testing.expectEqualStrings("unverified_no_tests", reply.edits().get("status").?.string);
    try testing.expect(std.mem.startsWith(u8, reply.edits().get("tests").?.string, "none"));
    try testing.expect(std.mem.endsWith(u8, reply.edits().get("files").?.array.items[0].string, "fresh.js"));
    try repo.expectFile("src/fresh.js", "export const fresh = 1;\n");
}

test "gate fail closed: a test command that runs no test, or reports zero tests, is never called verified" {
    var repo = try Repo.init();
    defer repo.deinit();
    const app = try repo.path("src\\app.js");
    defer gpa.free(app);
    const silent = [_][]const u8{ "cmd /c exit 0", "cmd /c echo 0 passing" };
    for (silent, 0..) |command, i| {
        var reply = try repo.change(.{ .edits = .{.{ .file = app, .old_string = if (i == 0) "a + b" else "b + a", .new_string = if (i == 0) "b + a" else "a + b" }} }, .{ .test_command = command });
        defer reply.deinit();
        errdefer std.debug.print("{s}: {s}\n", .{ command, reply.text });
        try testing.expect(!reply.is_error);
        try testing.expect(!reply.claimsVerified());
    }
    var ran = try repo.change(.{ .edits = .{.{ .file = app, .old_string = "a + b", .new_string = "b + a" }} }, .{ .test_command = passing });
    defer ran.deinit();
    errdefer std.debug.print("reply: {s}\n", .{ran.text});
    try testing.expect(!ran.is_error);
    try testing.expect(ran.claimsVerified());
}

test "gate fail closed: a README change that breaks a test is tested and refused, so it never becomes baseline" {
    var repo = try Repo.init();
    defer repo.deinit();
    const doc = try repo.path("README.md");
    defer gpa.free(doc);
    var reply = try repo.change(.{ .edits = .{.{ .file = doc, .old_string = "OLD heading", .new_string = "NEW heading" }} }, .{ .test_command = readme_test });
    defer reply.deinit();
    errdefer std.debug.print("reply: {s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try testing.expectEqualStrings("tests_failed", reply.edits().get("reason").?.string);
    try repo.expectFile("README.md", readme);

    const notice = try repo.path("CHANGELOG.md");
    defer gpa.free(notice);
    var ok = try repo.change(.{ .edits = .{.{ .file = notice, .content = "# Changes\n" }} }, .{ .test_command = readme_test });
    defer ok.deinit();
    errdefer std.debug.print("reply: {s}\n", .{ok.text});
    try testing.expect(!ok.is_error);
    try testing.expect(ok.claimsVerified());
    try testing.expect(std.mem.indexOf(u8, ok.text, "not run") == null);
}

test "gate fail closed: a test command that cannot start refuses the write with a fix, unless --allow-unverified" {
    var repo = try Repo.init();
    defer repo.deinit();
    const app = try repo.path("src\\app.js");
    defer gpa.free(app);
    {
        var reply = try repo.change(.{ .edits = .{.{ .file = app, .old_string = "a + b", .new_string = "b + a" }} }, .{ .test_command = missing_program });
        defer reply.deinit();
        errdefer std.debug.print("reply: {s}\n", .{reply.text});
        try testing.expect(reply.is_error);
        try testing.expectEqualStrings("test_env_error", reply.edits().get("reason").?.string);
        try testing.expect(std.mem.indexOf(u8, reply.edits().get("fix").?.string, "--allow-unverified") != null);
        try repo.expectFile("src/app.js", app_js);
    }
    {
        var reply = try repo.change(.{ .edits = .{.{ .file = app, .old_string = "a + b", .new_string = "b + a" }} }, .{ .test_command = passing, .typecheck_command = missing_program });
        defer reply.deinit();
        errdefer std.debug.print("reply: {s}\n", .{reply.text});
        try testing.expect(reply.is_error);
        try testing.expectEqualStrings("typecheck_env_error", reply.edits().get("reason").?.string);
        try testing.expect(std.mem.indexOf(u8, reply.edits().get("fix").?.string, "typecheck") != null);
        try repo.expectFile("src/app.js", app_js);
    }
    baseline.allow_unverified = true;
    defer baseline.allow_unverified = false;
    {
        var reply = try repo.change(.{ .edits = .{.{ .file = app, .old_string = "a + b", .new_string = "b + a" }} }, .{ .test_command = passing, .typecheck_command = missing_program });
        defer reply.deinit();
        errdefer std.debug.print("reply: {s}\n", .{reply.text});
        try testing.expect(!reply.is_error);
        try testing.expect(!reply.claimsVerified());
        try testing.expect(std.mem.startsWith(u8, reply.edits().get("unverified").?.string, "the typecheck command could not run"));
    }
    {
        var reply = try repo.change(.{ .edits = .{.{ .file = app, .old_string = "b + a", .new_string = "a + b" }} }, .{ .test_command = missing_program });
        defer reply.deinit();
        errdefer std.debug.print("reply: {s}\n", .{reply.text});
        try testing.expect(!reply.is_error);
        try testing.expect(!reply.claimsVerified());
        try testing.expect(std.mem.startsWith(u8, reply.edits().get("unverified").?.string, "the test command could not run"));
        try repo.expectFile("src/app.js", app_js);
    }
}

test "gate fail closed: a new file under a git-ignored path is refused before anything is written" {
    var repo = try Repo.init();
    defer repo.deinit();
    const ignored = try repo.path("ignored\\new.txt");
    defer gpa.free(ignored);
    try repo.tmp.dir.createDirPath(testing.io, "repo/ignored");
    var reply = try repo.change(.{ .edits = .{.{ .file = ignored, .content = "x\n" }} }, .{ .test_command = passing });
    defer reply.deinit();
    errdefer std.debug.print("reply: {s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try testing.expectEqualStrings("IgnoredPath", reply.edits().get("error").?.string);
    const fix = reply.edits().get("fix").?.string;
    try testing.expect(std.mem.indexOf(u8, fix, "ignored") != null);
    try testing.expect(std.mem.indexOf(u8, fix, "git add") == null);
    try testing.expect(repo.missing("ignored/new.txt"));
}
