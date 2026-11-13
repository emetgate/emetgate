//! Every cut reply of emetgate_git and emetgate_scan stays bounded and names
//! a continuation the same tool takes, which reaches the rest in one call.

const std = @import("std");
const git_fixture = @import("git_fixture.zig");
const emetgate = @import("emetgate");
const server = emetgate.server;
const Runtime = emetgate.runtime.Runtime;

const testing = std.testing;
const gpa = testing.allocator;
const Value = std.json.Value;

/// Generous bound on a whole reply line: the read budget plus the fields
/// around it.
const reply_cap = 16 * 1024;

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

    fn run(self: *Repo, args: []const []const u8, input: ?[]const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.append(gpa, try git_fixture.git());
        try argv.appendSlice(gpa, args);
        const options: std.process.RunOptions = .{ .argv = argv.items, .cwd = .{ .path = self.root_abs } };
        const result = if (input) |bytes| try emetgate.bounded_run.runFed(gpa, testing.io, options, bytes) else try emetgate.bounded_run.run(gpa, testing.io, options);
        gpa.free(result.stdout);
        gpa.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.GitSetupFailed,
            else => return error.GitSetupFailed,
        }
    }

    fn commitAll(self: *Repo, message: []const u8) !void {
        try self.run(&.{ "add", "." }, null);
        try self.run(&.{ "commit", "-q", "-m", message }, null);
    }
};

const Reply = struct {
    envelope: std.json.Parsed(Value),
    body: std.json.Parsed(Value),
    is_error: bool,
    len: usize,

    fn deinit(self: *Reply) void {
        self.body.deinit();
        self.envelope.deinit();
    }

    fn get(self: *Reply, name: []const u8) ?Value {
        return self.body.value.object.get(name);
    }

    fn int(self: *Reply, name: []const u8) !i64 {
        const v = self.get(name) orelse return error.MissingField;
        return v.integer;
    }

    fn str(self: *Reply, name: []const u8) ![]const u8 {
        const v = self.get(name) orelse return error.MissingField;
        return v.string;
    }
};

fn call(runtime: *Runtime, root_abs: []const u8, tool: []const u8, args: anytype) !Reply {
    var line: std.Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    var js: std.json.Stringify = .{ .writer = &line.writer };
    try js.write(.{ .jsonrpc = "2.0", .id = 1, .method = "tools/call", .params = .{ .name = tool, .arguments = args } });

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try server.handleMessageObserved(gpa, testing.io, runtime, line.written(), &out.writer, null, .{ .root = root_abs });

    const envelope = try std.json.parseFromSlice(Value, gpa, out.written(), .{ .allocate = .alloc_always });
    errdefer envelope.deinit();
    const result = envelope.value.object.get("result") orelse return error.NotAToolResult;
    const text = result.object.get("content").?.array.items[0].object.get("text").?.string;
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const body = try std.json.parseFromSlice(Value, gpa, text[0..end], .{ .allocate = .alloc_always });
    return .{ .envelope = envelope, .body = body, .is_error = result.object.get("isError").?.bool, .len = text.len };
}

fn numbered(prefix: []const u8, count: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (0..count) |i| try out.writer.print("{s} {d}\n", .{ prefix, i });
    return gpa.dupe(u8, out.written());
}

/// A repository whose one file of 100,000 lines is changed on every line:
/// the raw diff is some 2.6 MB.
fn hugeChange(repo: *Repo) !void {
    const before = try numbered("line", 100_000);
    defer gpa.free(before);
    try repo.writeFile("big.txt", before);
    try repo.writeFile("small.txt", "one\n");
    try repo.commitAll("big file");
    const after = try numbered("changed", 100_000);
    defer gpa.free(after);
    try repo.writeFile("big.txt", after);
    try repo.writeFile("small.txt", "two\n");
}

test "a huge diff answers with a bounded first page, a stat of every file and a next_line that reaches the rest" {
    var repo = try Repo.init();
    defer repo.deinit();
    try hugeChange(&repo);
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var first = try call(runtime, repo.root_abs, "emetgate_git", .{ .sub = "diff" });
    defer first.deinit();
    try testing.expect(!first.is_error);
    try testing.expect(first.len < reply_cap);
    try testing.expectEqual(@as(i64, 2), try first.int("files_total"));
    try testing.expectEqual(@as(i64, 100_001), try first.int("added"));
    const files = first.get("files").?.array.items;
    try testing.expectEqual(@as(usize, 2), files.len);
    try testing.expectEqualStrings("big.txt", files[0].object.get("path").?.string);
    try testing.expectEqual(@as(i64, 100_000), files[0].object.get("removed").?.integer);
    try testing.expectEqual(@as(i64, 1), try first.int("line_start"));
    const total = try first.int("lines_total");
    try testing.expect(total > 200_000);
    const next = try first.int("next_line");
    try testing.expect(next > 1 and next < total);
    try testing.expect(std.mem.indexOf(u8, try first.str("note"), "line_start") != null);

    // The continuation starts exactly where the first page stopped.
    var second = try call(runtime, repo.root_abs, "emetgate_git", .{ .sub = "diff", .line_start = next });
    defer second.deinit();
    try testing.expect(!second.is_error);
    try testing.expect(second.len < reply_cap);
    try testing.expectEqual(next, try second.int("line_start"));
    try testing.expect(try second.int("next_line") > next);
    try testing.expect(second.get("files") == null);

    // The second file's line from the stat reaches its diff directly.
    const small_line = files[1].object.get("line").?.integer;
    var small = try call(runtime, repo.root_abs, "emetgate_git", .{ .sub = "diff", .line_start = small_line });
    defer small.deinit();
    try testing.expect(std.mem.startsWith(u8, try small.str("output"), "diff --git a/small.txt"));
    try testing.expect(small.get("next_line") == null);

    // path narrows to one file, and line_start past the end says so.
    const big_abs = try std.fmt.allocPrint(gpa, "{s}/big.txt", .{repo.root_abs});
    defer gpa.free(big_abs);
    var one = try call(runtime, repo.root_abs, "emetgate_git", .{ .sub = "diff", .path = big_abs });
    defer one.deinit();
    try testing.expect(!one.is_error);
    try testing.expectEqual(@as(i64, 1), try one.int("files_total"));
    var past = try call(runtime, repo.root_abs, "emetgate_git", .{ .sub = "diff", .line_start = total + 10 });
    defer past.deinit();
    try testing.expect(!past.is_error);
    try testing.expect(past.get("next_line") == null);
    try testing.expectEqualStrings("", try past.str("output"));
}

test "show of a huge commit is bounded and pages the same way" {
    var repo = try Repo.init();
    defer repo.deinit();
    try hugeChange(&repo);
    try repo.commitAll("change every line");
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var first = try call(runtime, repo.root_abs, "emetgate_git", .{ .sub = "show", .commit = "HEAD" });
    defer first.deinit();
    try testing.expect(!first.is_error);
    try testing.expect(first.len < reply_cap);
    const next = try first.int("next_line");
    var second = try call(runtime, repo.root_abs, "emetgate_git", .{ .sub = "show", .commit = "HEAD", .line_start = next });
    defer second.deinit();
    try testing.expect(!second.is_error);
    try testing.expectEqual(next, try second.int("line_start"));
}

test "a folded compact diff names the raw line its fold cut at" {
    var repo = try Repo.init();
    defer repo.deinit();
    const before = try numbered("line", 1500);
    defer gpa.free(before);
    try repo.writeFile("mid.txt", before);
    try repo.commitAll("mid file");
    const after = try numbered("changed again", 1500);
    defer gpa.free(after);
    try repo.writeFile("mid.txt", after);
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var folded = try call(runtime, repo.root_abs, "emetgate_git", .{ .sub = "diff" });
    defer folded.deinit();
    try testing.expect(folded.get("elided") != null);
    const next = try folded.int("next_line");
    try testing.expect(std.mem.indexOf(u8, try folded.str("output"), "line_start:") != null);
    var rest = try call(runtime, repo.root_abs, "emetgate_git", .{ .sub = "diff", .line_start = next });
    defer rest.deinit();
    const text = try rest.str("output");
    try testing.expect(std.mem.startsWith(u8, text, "@@") or std.mem.startsWith(u8, text, "diff --git"));
}

test "a long log pages by next_cursor to its last commit, and the args form pages by line_start" {
    var repo = try Repo.init();
    defer repo.deinit();
    var stream: std.Io.Writer.Allocating = .init(gpa);
    defer stream.deinit();
    const commits = 260;
    for (0..commits) |i| try stream.writer.print("commit refs/heads/work\ncommitter t <t@t> {d} +0000\ndata 9\nc {d:0>6}\n\n", .{ 1_700_000_000 + i, i });
    try repo.run(&.{ "fast-import", "--quiet" }, stream.written());
    try repo.run(&.{ "symbolic-ref", "HEAD", "refs/heads/work" }, null);
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var seen: usize = 0;
    var cursor: ?[]u8 = null;
    defer if (cursor) |c| gpa.free(c);
    var calls: usize = 0;
    while (calls < 40) : (calls += 1) {
        var page = if (cursor) |c|
            try call(runtime, repo.root_abs, "emetgate_git", .{ .sub = "log", .n = 500, .cursor = c })
        else
            try call(runtime, repo.root_abs, "emetgate_git", .{ .sub = "log", .n = 500 });
        defer page.deinit();
        try testing.expect(!page.is_error);
        try testing.expect(page.len < reply_cap);
        try testing.expectEqual(@as(i64, 200), try page.int("n_used"));
        seen += page.get("commits").?.array.items.len;
        if (cursor) |c| gpa.free(c);
        cursor = null;
        const next = page.get("next_cursor") orelse break;
        cursor = try gpa.dupe(u8, next.string);
    }
    try testing.expectEqual(@as(usize, commits), seen);

    var head = try call(runtime, repo.root_abs, "emetgate_git", .{ .sub = "log", .args = .{"--oneline"} });
    defer head.deinit();
    try testing.expect(!head.is_error);
    const shown = try head.str("output");
    try testing.expect(std.mem.indexOf(u8, shown, "[lines 1-200 of 260 shown; pass line_start:201") != null);
    var tail = try call(runtime, repo.root_abs, "emetgate_git", .{ .sub = "log", .args = .{"--oneline"}, .line_start = 201 });
    defer tail.deinit();
    const rest = try tail.str("output");
    try testing.expect(std.mem.indexOf(u8, rest, "[lines 201-260 of 260 shown]") != null);
    try testing.expect(std.mem.indexOf(u8, rest, "c 000000") != null);
}

test "blame of a file past the capture limit is bounded and pages by next_line" {
    var repo = try Repo.init();
    defer repo.deinit();
    const text = try numbered("a line of the big file", 5000);
    defer gpa.free(text);
    try repo.writeFile("big.log", text);
    try repo.commitAll("big log");
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    const file_abs = try std.fmt.allocPrint(gpa, "{s}/big.log", .{repo.root_abs});
    defer gpa.free(file_abs);

    const saved = emetgate.git_tools.capture_limit;
    emetgate.git_tools.capture_limit = 128 * 1024;
    defer emetgate.git_tools.capture_limit = saved;

    var cut = try call(runtime, repo.root_abs, "emetgate_git", .{ .sub = "blame", .path = file_abs });
    defer cut.deinit();
    try testing.expect(!cut.is_error);
    try testing.expect(cut.len < reply_cap);
    try testing.expect(cut.get("capture_cut").?.bool);
    const next = try cut.int("next_line");
    try testing.expect(next > 1);
    try testing.expect(std.mem.indexOf(u8, try cut.str("note"), "line_start") != null);

    var on = try call(runtime, repo.root_abs, "emetgate_git", .{ .sub = "blame", .path = file_abs, .line_start = next });
    defer on.deinit();
    try testing.expect(!on.is_error);
    try testing.expect(on.len < reply_cap);
    var want_buf: [32]u8 = undefined;
    const want = try std.fmt.bufPrint(&want_buf, "{d} ", .{next});
    try testing.expect(std.mem.startsWith(u8, try on.str("output"), want));
    try testing.expect(try on.int("next_line") > next);

    // The last page has no next_line.
    var last = try call(runtime, repo.root_abs, "emetgate_git", .{ .sub = "blame", .path = file_abs, .line_start = 4990 });
    defer last.deinit();
    try testing.expect(last.get("next_line") == null);
    try testing.expectEqual(@as(i64, 11), try last.int("lines_shown"));
}

test "no fix of a cut git reply names a parameter that does nothing for its subcommand" {
    const wire = emetgate.wire;
    const fix = wire.fixFor("GitOutputTooLarge") orelse "";
    try testing.expect(std.mem.indexOf(u8, fix, "line_start") == null);
    try testing.expect(std.mem.indexOf(u8, fix, " n,") == null);
}

test "scan with more than 100 violations pages by offset to the last one" {
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.tmp.dir.createDirPath(testing.io, "repo/src");
    try repo.writeFile("src/a.ts", "networkidle;\n" ** 250);
    try git_fixture.commitInit(repo.root_abs, true);
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var offset: i64 = 0;
    var listed: usize = 0;
    var pages: usize = 0;
    while (pages < 10) : (pages += 1) {
        var page = try call(runtime, repo.root_abs, "emetgate_scan", .{ .check = "forbid:networkidle", .offset = offset });
        defer page.deinit();
        try testing.expect(!page.is_error);
        try testing.expectEqual(@as(i64, 250), try page.int("violation_count"));
        listed += page.get("violations").?.array.items.len;
        const next = page.get("next_offset") orelse {
            try testing.expect(!page.get("truncated").?.bool);
            break;
        };
        try testing.expect(page.get("truncated").?.bool);
        try testing.expect(std.mem.indexOf(u8, try page.str("note"), "offset:") != null);
        offset = next.integer;
    }
    try testing.expectEqual(@as(usize, 250), listed);
    try testing.expectEqual(@as(usize, 2), pages);
}
