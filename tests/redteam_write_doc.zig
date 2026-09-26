const std = @import("std");
const builtin = @import("builtin");
const git_fixture = @import("git_fixture.zig");
const server = @import("emetgate").server;
const Runtime = @import("emetgate").runtime.Runtime;
const symbol = @import("emetgate").symbol;

const testing = std.testing;
const gpa = testing.allocator;
const Value = std.json.Value;

const dummy_hash = "0" ** 32;
const note_md = "# Notes\n\n## Setup\n\nold\n";

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

fn callToolServed(runtime: *Runtime, root: []const u8, tool: []const u8, args: anytype) !Reply {
    var line: std.Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    var js: std.json.Stringify = .{ .writer = &line.writer };
    try js.write(.{ .jsonrpc = "2.0", .id = 1, .method = "tools/call", .params = .{ .name = tool, .arguments = args } });

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try server.handleMessageObserved(gpa, testing.io, runtime, line.written(), &out.writer, null, .{ .root = root, .test_command = "cmd /c exit 0" });

    const parsed = try std.json.parseFromSlice(Value, gpa, out.written(), .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    const result = parsed.value.object.get("result") orelse return error.NotAToolResult;
    const content = result.object.get("content").?.array.items[0];
    return .{ .parsed = parsed, .is_error = result.object.get("isError").?.bool, .text = content.object.get("text").?.string };
}

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
    outside_abs: [:0]u8,

    fn init() !Repo {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo");
        try tmp.dir.createDirPath(testing.io, "outside");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/notes.md", .data = note_md });
        const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", gpa);
        errdefer gpa.free(root_abs);
        const outside_abs = try tmp.dir.realPathFileAlloc(testing.io, "outside", gpa);
        errdefer gpa.free(outside_abs);
        try git_fixture.initRepo(root_abs);
        try git(root_abs, &.{ "add", "." });
        try git(root_abs, &.{ "commit", "-q", "-m", "init" });
        return .{ .tmp = tmp, .root_abs = root_abs, .outside_abs = outside_abs };
    }

    fn deinit(self: *Repo) void {
        gpa.free(self.outside_abs);
        gpa.free(self.root_abs);
        self.tmp.cleanup();
    }

    fn expectNotesUntouched(self: *Repo) !void {
        const on_disk = try self.tmp.dir.readFileAlloc(testing.io, "repo/notes.md", gpa, .unlimited);
        defer gpa.free(on_disk);
        try testing.expectEqualStrings(note_md, on_disk);
    }
};

test "write_doc refuses a path outside the repo, leaves the target untouched" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const file = try std.fmt.allocPrint(gpa, "{s}\\secret.md", .{repo.outside_abs});
    defer gpa.free(file);
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "outside/secret.md", .data = "keep\n" });

    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    var reply = try callToolServed(runtime, repo.root_abs, "emetgate_write_doc", .{ .file = file, .hash = dummy_hash, .content = "changed\n", .heading = "Setup" });
    defer reply.deinit();
    try testing.expect(reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expectEqualStrings("FileOutsideRepo", body.value.object.get("error").?.string);

    const still = try repo.tmp.dir.readFileAlloc(testing.io, "outside/secret.md", gpa, .unlimited);
    defer gpa.free(still);
    try testing.expectEqualStrings("keep\n", still);
}

test "write_doc refuses a path that escapes the repo with .." {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "outside/secret.md", .data = "keep\n" });
    const file = try std.fmt.allocPrint(gpa, "{s}\\..\\outside\\secret.md", .{repo.root_abs});
    defer gpa.free(file);

    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    var reply = try callToolServed(runtime, repo.root_abs, "emetgate_write_doc", .{ .file = file, .hash = dummy_hash, .content = "changed\n", .heading = "Setup" });
    defer reply.deinit();
    try testing.expect(reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expectEqualStrings("FileOutsideRepo", body.value.object.get("error").?.string);

    const still = try repo.tmp.dir.readFileAlloc(testing.io, "outside/secret.md", gpa, .unlimited);
    defer gpa.free(still);
    try testing.expectEqualStrings("keep\n", still);
}

test "write_doc refuses .git/config" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const file = try std.fmt.allocPrint(gpa, "{s}\\.git\\config", .{repo.root_abs});
    defer gpa.free(file);
    const before = try repo.tmp.dir.readFileAlloc(testing.io, "repo/.git/config", gpa, .unlimited);
    defer gpa.free(before);

    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    var reply = try callToolServed(runtime, repo.root_abs, "emetgate_write_doc", .{ .file = file, .hash = dummy_hash, .content = "[core]\n", .line_start = @as(i64, 1), .line_end = @as(i64, 1) });
    defer reply.deinit();
    try testing.expect(reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expectEqualStrings("InternalPath", body.value.object.get("error").?.string);

    const after = try repo.tmp.dir.readFileAlloc(testing.io, "repo/.git/config", gpa, .unlimited);
    defer gpa.free(after);
    try testing.expectEqualStrings(before, after);
}

test "write_doc refuses a path under .emetgate/" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.tmp.dir.createDirPath(testing.io, "repo/.emetgate");
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.emetgate/events.ndjson", .data = "{}\n" });
    const file = try std.fmt.allocPrint(gpa, "{s}\\.emetgate\\events.ndjson", .{repo.root_abs});
    defer gpa.free(file);

    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    var reply = try callToolServed(runtime, repo.root_abs, "emetgate_write_doc", .{ .file = file, .hash = dummy_hash, .content = "{}\n", .line_start = @as(i64, 1), .line_end = @as(i64, 1) });
    defer reply.deinit();
    try testing.expect(reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expectEqualStrings("InternalPath", body.value.object.get("error").?.string);

    const after = try repo.tmp.dir.readFileAlloc(testing.io, "repo/.emetgate/events.ndjson", gpa, .unlimited);
    defer gpa.free(after);
    try testing.expectEqualStrings("{}\n", after);
}

test "write_doc refuses a path that only reaches .git through a junction" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const made = try std.process.run(gpa, testing.io, .{ .argv = &.{ "cmd", "/c", "mklink", "/J", "alias", ".git" }, .cwd = .{ .path = repo.root_abs } });
    gpa.free(made.stdout);
    gpa.free(made.stderr);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, made.term);
    const file = try std.fmt.allocPrint(gpa, "{s}\\alias\\config", .{repo.root_abs});
    defer gpa.free(file);
    const before = try repo.tmp.dir.readFileAlloc(testing.io, "repo/.git/config", gpa, .unlimited);
    defer gpa.free(before);

    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    var reply = try callToolServed(runtime, repo.root_abs, "emetgate_write_doc", .{ .file = file, .hash = dummy_hash, .content = "[core]\n", .line_start = @as(i64, 1), .line_end = @as(i64, 1) });
    defer reply.deinit();
    try testing.expect(reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expectEqualStrings("InternalPath", body.value.object.get("error").?.string);

    const after = try repo.tmp.dir.readFileAlloc(testing.io, "repo/.git/config", gpa, .unlimited);
    defer gpa.free(after);
    try testing.expectEqualStrings(before, after);
}

test "write_doc refuses a file that does not exist yet, it never creates one" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const file = try std.fmt.allocPrint(gpa, "{s}\\brand-new.md", .{repo.root_abs});
    defer gpa.free(file);

    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    var reply = try callToolServed(runtime, repo.root_abs, "emetgate_write_doc", .{ .file = file, .hash = dummy_hash, .content = "# New\n", .heading = "New" });
    defer reply.deinit();
    try testing.expect(reply.is_error);

    repo.tmp.dir.access(testing.io, "repo/brand-new.md", .{}) catch |err| {
        try testing.expectEqual(error.FileNotFound, err);
        return;
    };
    return error.FileWasCreated;
}

test "a JSON pointer cannot reach outside the document: an unresolved pointer is refused, not silently written elsewhere" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/data.json", .data = "{\"a\": 1}\n" });
    try git(repo.root_abs, &.{ "add", "." });
    try git(repo.root_abs, &.{ "commit", "-q", "-m", "data" });
    const file = try std.fmt.allocPrint(gpa, "{s}\\data.json", .{repo.root_abs});
    defer gpa.free(file);

    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    var reply = try callToolServed(runtime, repo.root_abs, "emetgate_write_doc", .{ .file = file, .hash = dummy_hash, .content = "2", .pointer = "/../../etc/passwd" });
    defer reply.deinit();
    try testing.expect(reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expectEqualStrings("PointerNotFound", body.value.object.get("error").?.string);

    const after = try repo.tmp.dir.readFileAlloc(testing.io, "repo/data.json", gpa, .unlimited);
    defer gpa.free(after);
    try testing.expectEqualStrings("{\"a\": 1}\n", after);
}

test "emetgate_try_batch commits a code edit and a doc edit together" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/a.ts", .data = "export const a = 1;\n" });
    try git(repo.root_abs, &.{ "add", "." });
    try git(repo.root_abs, &.{ "commit", "-q", "-m", "code" });

    const code_file = try std.fmt.allocPrint(gpa, "{s}\\a.ts", .{repo.root_abs});
    defer gpa.free(code_file);
    const doc_file = try std.fmt.allocPrint(gpa, "{s}\\notes.md", .{repo.root_abs});
    defer gpa.free(doc_file);
    const doc_hash = symbol.formatHash(symbol.hashOf("## Setup\n\nold\n"));

    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    var reply = try callToolServed(runtime, repo.root_abs, "emetgate_try_batch", .{ .edits = .{
        .{ .file = code_file, .symbol = "b", .hash = symbol.absent_text, .body = "export function b(): number { return 2; }" },
        .{ .file = doc_file, .kind = "doc", .hash = doc_hash[0..], .content = "## Setup\n\nnew\n", .heading = "Setup" },
    } });
    defer reply.deinit();
    errdefer std.debug.print("reply: {s}\n", .{reply.text});
    try testing.expect(!reply.is_error);

    const code_after = try repo.tmp.dir.readFileAlloc(testing.io, "repo/a.ts", gpa, .unlimited);
    defer gpa.free(code_after);
    try testing.expect(std.mem.indexOf(u8, code_after, "b") != null);
    const doc_after = try repo.tmp.dir.readFileAlloc(testing.io, "repo/notes.md", gpa, .unlimited);
    defer gpa.free(doc_after);
    try testing.expect(std.mem.indexOf(u8, doc_after, "new") != null);
    try testing.expect(std.mem.indexOf(u8, doc_after, "old") == null);
}
