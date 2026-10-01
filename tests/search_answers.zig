const std = @import("std");
const builtin = @import("builtin");
const git_fixture = @import("git_fixture.zig");
const server = @import("emetgate").server;
const answer_mod = @import("emetgate").answer;
const search_index = @import("emetgate").search_index;
const search_session = @import("emetgate").search_session;
const search_v1 = @import("emetgate").search_v1;
const Runtime = @import("emetgate").runtime.Runtime;

const testing = std.testing;
const gpa = testing.allocator;
const Value = std.json.Value;

fn gitIn(root: []const u8, args: []const []const u8) !void {
    var argv: [8][]const u8 = undefined;
    argv[0] = "git";
    @memcpy(argv[1..][0..args.len], args);
    const result = try std.process.run(gpa, testing.io, .{ .argv = argv[0 .. args.len + 1], .cwd = .{ .path = root } });
    gpa.free(result.stdout);
    gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitSetupFailed,
        else => return error.GitSetupFailed,
    }
}

const Repo = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,

    fn init(files: []const [2][]const u8) !Repo {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        for (files) |f| {
            if (std.fs.path.dirname(f[0])) |dir| try tmp.dir.createDirPath(testing.io, dir);
            try tmp.dir.writeFile(testing.io, .{ .sub_path = f[0], .data = f[1] });
        }
        const root = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
        errdefer gpa.free(root);
        try git_fixture.initRepo(root);
        try gitIn(root, &.{ "add", "." });
        try gitIn(root, &.{ "commit", "-q", "-m", "init" });
        return .{ .tmp = tmp, .root = root };
    }

    fn deinit(self: *Repo) void {
        if (search_index.indexDir(gpa, self.root)) |dir| {
            std.Io.Dir.cwd().deleteTree(testing.io, dir) catch {};
            gpa.free(dir);
        } else |_| {}
        gpa.free(self.root);
        self.tmp.cleanup();
    }

    fn path(self: *Repo, rel: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "{s}\\{s}", .{ self.root, rel });
    }
};

const Answer = struct {
    parsed: std.json.Parsed(Value),
    body: ?std.json.Parsed(Value),
    is_error: bool,
    chars: usize = 0,

    fn deinit(self: *Answer) void {
        if (self.body) |*b| b.deinit();
        self.parsed.deinit();
    }

    fn get(self: *Answer, key: []const u8) ?Value {
        return self.body.?.value.object.get(key);
    }

    fn status(self: *Answer) []const u8 {
        return self.get("status").?.string;
    }

    fn groups(self: *Answer) []const Value {
        return self.get("groups").?.array.items;
    }

    fn scope(self: *Answer, key: []const u8) i64 {
        return self.get("certificate").?.object.get("scope").?.object.get(key).?.integer;
    }

    fn line(self: *Answer) []const u8 {
        return self.get("answer").?.string;
    }

    fn note(self: *Answer) []const u8 {
        return self.get("note").?.string;
    }

    fn hitCount(self: *Answer) usize {
        var n: usize = 0;
        for (self.groups()) |g| n += g.object.get("hits").?.array.items.len;
        return n;
    }

    fn errorName(self: *Answer) []const u8 {
        return self.body.?.value.object.get("error").?.string;
    }
};

fn search(runtime: *Runtime, root: []const u8, args: anytype) !Answer {
    return searchPolicy(runtime, .{ .root = root }, args);
}

fn searchIn(runtime: *Runtime, session: *search_session.Session, root: []const u8, args: anytype) !Answer {
    return searchPolicy(runtime, .{ .root = root, .search_session = session }, args);
}

fn searchPolicy(runtime: *Runtime, policy: server.Policy, args: anytype) !Answer {
    var line: std.Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    var js: std.json.Stringify = .{ .writer = &line.writer };
    try js.write(.{ .jsonrpc = "2.0", .id = 1, .method = "tools/call", .params = .{ .name = "emetgate_search", .arguments = args } });
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try server.handleMessageObserved(gpa, testing.io, runtime, line.written(), &out.writer, null, policy);
    var parsed = try std.json.parseFromSlice(Value, gpa, out.written(), .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    const result = parsed.value.object.get("result") orelse return error.NotAToolResult;
    const text = result.object.get("content").?.array.items[0].object.get("text").?.string;
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    errdefer std.debug.print("{s}\n", .{text});
    const body = try std.json.parseFromSlice(Value, gpa, text[0..end], .{ .allocate = .alloc_always });
    return .{ .parsed = parsed, .body = body, .is_error = result.object.get("isError").?.bool, .chars = text.len };
}

test "search answers: a file given as dir is searched by itself" {
    var repo = try Repo.init(&.{
        .{ "src/engine/run.ts", "export function run() {\n  return continueOnFail();\n}\n" },
        .{ "src/engine/other.ts", "export const x = continueOnFail;\n" },
    });
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    const file = try repo.path("src/engine/run.ts");
    defer gpa.free(file);

    var answer = try search(runtime, repo.root, .{ .pattern = "continueOnFail", .dir = file, .certificate = true });
    defer answer.deinit();
    try testing.expect(!answer.is_error);
    try testing.expectEqualStrings("complete", answer.status());
    try testing.expectEqual(@as(i64, 1), answer.scope("in_scope"));
    try testing.expectEqualStrings("src/engine/run.ts", answer.get("certificate").?.object.get("scope").?.object.get("prefix").?.string);
    try testing.expectEqual(@as(usize, 1), answer.groups().len);
    try testing.expect(std.mem.endsWith(u8, answer.groups()[0].object.get("file").?.string, "run.ts"));
}

test "search answers: an untracked file given as dir is named as untracked, not answered as an empty success" {
    var repo = try Repo.init(&.{.{ "a.ts", "export const a = 1;\n" }});
    defer repo.deinit();
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "loose.ts", .data = "export const continueOnFail = 1;\n" });
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    const file = try repo.path("loose.ts");
    defer gpa.free(file);

    var answer = try search(runtime, repo.root, .{ .pattern = "continueOnFail", .dir = file, .certificate = true });
    defer answer.deinit();
    try testing.expectEqual(@as(i64, 0), answer.scope("listed"));
    try testing.expect(std.mem.indexOf(u8, answer.note(), "is not a file git tracks") != null);
}

test "search answers: a literal with a bar that is not found is read as literal alternatives and says so" {
    var repo = try Repo.init(&.{
        .{ "a.ts", "export function a() {\n  handleNodeExecutionError(x);\n}\n" },
        .{ "b.ts", "export function b() {\n  if (!continueExecution) return;\n}\n" },
    });
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var answer = try search(runtime, repo.root, .{ .pattern = "handleNodeExecutionError(|continueExecution", .dir = repo.root });
    defer answer.deinit();
    try testing.expectEqualStrings("literal alternatives", answer.get("read_as").?.string);
    try testing.expectEqual(@as(usize, 2), answer.groups().len);
    try testing.expectEqual(@as(usize, 2), answer.hitCount());
}

test "search answers: a literal with regex syntax and no match says the pattern looks like a regex" {
    var repo = try Repo.init(&.{.{ "a.ts", "export const a = continuesOnError(1);\n" }});
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var answer = try search(runtime, repo.root, .{ .pattern = "continuesOnError\\(", .dir = repo.root });
    defer answer.deinit();
    try testing.expectEqualStrings("complete", answer.status());
    try testing.expectEqual(@as(usize, 0), answer.groups().len);
    try testing.expect(std.mem.indexOf(u8, answer.note(), "regex syntax") != null);
    try testing.expect(std.mem.indexOf(u8, answer.note(), "regex:true") != null);
}

test "search answers: kinds that remove every match say how many matches of which kind were removed" {
    var repo = try Repo.init(&.{.{ "a.ts", "export function f(n: { onError: string }) {\n  if (n.onError === 'continueErrorOutput') return 1;\n  return n.onError === \"continueErrorOutput\" ? 2 : 3;\n}\n" }});
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var answer = try search(runtime, repo.root, .{ .pattern = "continueErrorOutput", .dir = repo.root, .kinds = &[_][]const u8{"code"} });
    defer answer.deinit();
    try testing.expectEqual(@as(usize, 0), answer.groups().len);
    const note = answer.note();
    errdefer std.debug.print("{s}\n", .{note});
    try testing.expect(std.mem.indexOf(u8, note, "2 matching line(s)") != null);
    try testing.expect(std.mem.indexOf(u8, note, "2 string") != null);
    try testing.expect(std.mem.indexOf(u8, note, "kinds [code]") != null);
}

test "search answers: an unknown kind name is refused instead of filtering everything away" {
    var repo = try Repo.init(&.{.{ "a.ts", "export const a = 'x';\n" }});
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var answer = try search(runtime, repo.root, .{ .pattern = "x", .dir = repo.root, .kinds = &[_][]const u8{"strings"} });
    defer answer.deinit();
    try testing.expect(answer.is_error);
    try testing.expectEqualStrings("UnknownKind", answer.errorName());
}

test "search answers: a complete answer with no match states how many files it evaluated" {
    var repo = try Repo.init(&.{
        .{ "a.ts", "export const a = 1;\n" },
        .{ "b.ts", "export const b = 2;\n" },
        .{ "c.md", "# Title\n" },
    });
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var answer = try search(runtime, repo.root, .{ .pattern = "absentNeedle", .dir = repo.root, .certificate = true });
    defer answer.deinit();
    try testing.expectEqualStrings("complete", answer.status());
    try testing.expectEqual(@as(i64, 3), answer.scope("in_scope"));
    try testing.expectEqual(@as(i64, 3), answer.scope("evaluated"));
    try testing.expectEqualStrings("no match in 3 file(s)", answer.note());
    try testing.expect(std.mem.startsWith(u8, answer.line(), "\u{2713} 0 matches in 3 files @"));
}

test "search answers: a regex alternation over many files finds every match a line by line scan finds" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var filler: std.ArrayList(u8) = .empty;
    defer filler.deinit(gpa);
    for (0..300) |i| try filler.print(gpa, "export const filler{d} = computeSomethingWithALongName({d}, other);\n", .{ i, i });
    const file_count = 120;
    var name: [64]u8 = undefined;
    for (0..file_count) |i| {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(gpa);
        try body.appendSlice(gpa, filler.items);
        try body.print(gpa, "if (!continueExecution) return {d};\n", .{i});
        try tmp.dir.writeFile(testing.io, .{ .sub_path = try std.fmt.bufPrint(&name, "f{d}.ts", .{i}), .data = body.items });
    }
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(root);
    try git_fixture.initRepo(root);
    try gitIn(root, &.{ "add", "." });
    try gitIn(root, &.{ "commit", "-q", "-m", "init" });
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var answer = try search(runtime, root, .{ .pattern = "handleNodeExecutionError|continueExecution", .dir = root, .regex = true, .detail = "full" });
    defer answer.deinit();
    try testing.expectEqualStrings("complete", answer.status());
    try testing.expectEqual(@as(usize, file_count), answer.hitCount());
}

test "search answers: a line that runs out of regex steps makes the answer partial and names the file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const long = try gpa.alloc(u8, 300_000);
    defer gpa.free(long);
    @memset(long, 'a');
    long[long.len - 1] = 'z';
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "long.txt", .data = long });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "short.txt", .data = "abz\n" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(root);
    try git_fixture.initRepo(root);
    try gitIn(root, &.{ "add", "." });
    try gitIn(root, &.{ "commit", "-q", "-m", "init" });
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var answer = try search(runtime, root, .{ .pattern = "(a|b|c|d|e|f|g|h)*z", .dir = root, .regex = true, .certificate = true });
    defer answer.deinit();
    try testing.expectEqualStrings("partial", answer.status());
    const missing = answer.get("missing").?.array.items;
    try testing.expectEqual(@as(usize, 1), missing.len);
    try testing.expectEqualStrings("long.txt", missing[0].object.get("path").?.string);
    try testing.expectEqualStrings("budget", missing[0].object.get("reason").?.string);
    try testing.expectEqual(@as(i64, 1), answer.scope("evaluated"));
    try testing.expectEqual(@as(usize, 1), answer.hitCount());
}

test "search answers: a file that cannot be read makes the answer partial instead of a quiet skip" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init(&.{
        .{ "locked.txt", "lockedneedle here\n" },
        .{ "open.txt", "lockedneedle there\n" },
    });
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    const locked = try repo.path("locked.txt");
    defer gpa.free(locked);
    const held = try std.Io.Dir.cwd().openFile(testing.io, locked, .{ .mode = .read_write, .lock = .exclusive });
    var released = false;
    defer if (!released) held.close(testing.io);

    var answer = try search(runtime, repo.root, .{ .pattern = "lockedneedle", .dir = repo.root });
    defer answer.deinit();
    try testing.expectEqualStrings("partial", answer.status());
    const missing = answer.get("missing").?.array.items;
    try testing.expectEqual(@as(usize, 1), missing.len);
    try testing.expectEqualStrings("unreadable", missing[0].object.get("reason").?.string);
    try testing.expectEqual(@as(usize, 1), answer.groups().len);

    held.close(testing.io);
    released = true;
    var after = try search(runtime, repo.root, .{ .pattern = "lockedneedle", .dir = repo.root });
    defer after.deinit();
    try testing.expectEqualStrings("complete", after.status());
    try testing.expectEqual(@as(usize, 2), after.groups().len);
}

test "search answers: a file locked during one search is read by the next search of the same session once the lock is gone" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init(&.{
        .{ "locked.txt", "lockedneedle here\n" },
        .{ "open.txt", "lockedneedle there\n" },
    });
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    var session = search_session.Session.init(gpa, testing.io, repo.root, .{});
    defer session.deinit();
    const locked = try repo.path("locked.txt");
    defer gpa.free(locked);

    {
        const held = try std.Io.Dir.cwd().openFile(testing.io, locked, .{ .mode = .read_write, .lock = .exclusive });
        defer held.close(testing.io);
        var answer = try searchIn(runtime, &session, repo.root, .{ .pattern = "lockedneedle", .dir = repo.root });
        defer answer.deinit();
        try testing.expectEqualStrings("partial", answer.status());
        try testing.expectEqualStrings("unreadable", answer.get("missing").?.array.items[0].object.get("reason").?.string);
    }
    var after = try searchIn(runtime, &session, repo.root, .{ .pattern = "lockedneedle", .dir = repo.root });
    defer after.deinit();
    try testing.expectEqualStrings("complete", after.status());
    try testing.expectEqual(@as(usize, 2), after.groups().len);
}

test "search answers: a tracked file deleted from the work tree makes the answer partial as vanished" {
    var repo = try Repo.init(&.{
        .{ "a.txt", "goneneedle a\n" },
        .{ "b.txt", "goneneedle b\n" },
    });
    defer repo.deinit();
    try repo.tmp.dir.deleteFile(testing.io, "b.txt");
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var answer = try search(runtime, repo.root, .{ .pattern = "goneneedle", .dir = repo.root });
    defer answer.deinit();
    try testing.expectEqualStrings("partial", answer.status());
    const missing = answer.get("missing").?.array.items;
    try testing.expectEqual(@as(usize, 1), missing.len);
    try testing.expectEqualStrings("b.txt", missing[0].object.get("path").?.string);
    try testing.expectEqualStrings("vanished", missing[0].object.get("reason").?.string);
    try testing.expectEqual(@as(usize, 1), answer.groups().len);
}

test "search answers: a tracked path that is now a directory makes the answer partial as unreadable" {
    var repo = try Repo.init(&.{
        .{ "a.txt", "dirneedle a\n" },
        .{ "c.txt", "dirneedle c\n" },
    });
    defer repo.deinit();
    try repo.tmp.dir.deleteFile(testing.io, "c.txt");
    try repo.tmp.dir.createDirPath(testing.io, "c.txt");
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var answer = try search(runtime, repo.root, .{ .pattern = "dirneedle", .dir = repo.root });
    defer answer.deinit();
    try testing.expectEqualStrings("partial", answer.status());
    const missing = answer.get("missing").?.array.items;
    try testing.expectEqual(@as(usize, 1), missing.len);
    try testing.expectEqualStrings("c.txt", missing[0].object.get("path").?.string);
    try testing.expectEqualStrings("unreadable", missing[0].object.get("reason").?.string);
}

test "search answers: a tracked file of exactly 1 MiB is searched and one a byte larger is excluded as too large" {
    const mib = 1024 * 1024;
    const at_cap = try gpa.alloc(u8, mib);
    defer gpa.free(at_cap);
    @memset(at_cap, 'x');
    @memcpy(at_cap[0..10], "capneedle\n");
    const over_cap = try gpa.alloc(u8, mib + 1);
    defer gpa.free(over_cap);
    @memset(over_cap, 'x');
    @memcpy(over_cap[0..10], "capneedle\n");
    var repo = try Repo.init(&.{
        .{ "at_cap.txt", at_cap },
        .{ "over_cap.txt", over_cap },
    });
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var answer = try search(runtime, repo.root, .{ .pattern = "capneedle", .dir = repo.root, .certificate = true });
    defer answer.deinit();
    try testing.expectEqualStrings("complete", answer.status());
    try testing.expectEqual(@as(usize, 1), answer.groups().len);
    try testing.expectEqualStrings("at_cap.txt", answer.groups()[0].object.get("file").?.string);
    try testing.expect(std.mem.endsWith(u8, answer.line(), "; excluded 1 > 1 MiB"));
    const listed = answer.get("certificate").?.object.get("scope").?.object.get("excluded_paths").?.array.items;
    try testing.expectEqual(@as(usize, 1), listed.len);
    try testing.expectEqualStrings("over_cap.txt", listed[0].object.get("path").?.string);
    try testing.expectEqualStrings("too_large", listed[0].object.get("rule").?.string);
}

test "search answers: a tracked binary file is excluded as binary and listed in the certificate" {
    var repo = try Repo.init(&.{
        .{ "text.txt", "binneedle here\n" },
        .{ "blob.bin", "binneedle\x00binary\n" },
    });
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var answer = try search(runtime, repo.root, .{ .pattern = "binneedle", .dir = repo.root, .certificate = true });
    defer answer.deinit();
    try testing.expectEqualStrings("complete", answer.status());
    try testing.expectEqual(@as(usize, 1), answer.groups().len);
    try testing.expectEqualStrings("text.txt", answer.groups()[0].object.get("file").?.string);
    try testing.expect(std.mem.endsWith(u8, answer.line(), "; excluded 1 binary"));
    const listed = answer.get("certificate").?.object.get("scope").?.object.get("excluded_paths").?.array.items;
    try testing.expectEqual(@as(usize, 1), listed.len);
    try testing.expectEqualStrings("blob.bin", listed[0].object.get("path").?.string);
    try testing.expectEqualStrings("binary", listed[0].object.get("rule").?.string);
}

fn expectedRoot(files: []const [2][]const u8) [64]u8 {
    var leaves: [8]answer_mod.Leaf = undefined;
    for (files, 0..) |f, i| leaves[i] = .{ .path = f[0], .digest = answer_mod.contentDigest(f[1]) };
    const root = answer_mod.merkleRoot(leaves[0..files.len]) catch unreachable;
    return std.fmt.bytesToHex(root, .lower);
}

fn snapshotRoot(answer: *Answer) []const u8 {
    return answer.get("certificate").?.object.get("snapshot").?.object.get("root").?.string;
}

test "search answers: the snapshot root is the Merkle root of the searched files and follows writes, an added file and a deleted file in the same session" {
    var repo = try Repo.init(&.{
        .{ "a.txt", "alpha rootneedle\n" },
        .{ "b/c.txt", "beta rootneedle\n" },
    });
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    var session = search_session.Session.init(gpa, testing.io, repo.root, .{});
    defer session.deinit();

    {
        var answer = try searchIn(runtime, &session, repo.root, .{ .pattern = "rootneedle", .dir = repo.root, .certificate = true });
        defer answer.deinit();
        const want = expectedRoot(&.{ .{ "a.txt", "alpha rootneedle\n" }, .{ "b/c.txt", "beta rootneedle\n" } });
        try testing.expectEqualStrings(&want, snapshotRoot(&answer));
        try testing.expect(std.mem.indexOf(u8, answer.line(), want[0..4]) != null);
    }
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "gamma rootneedle\n" });
    {
        var answer = try searchIn(runtime, &session, repo.root, .{ .pattern = "rootneedle", .dir = repo.root, .certificate = true });
        defer answer.deinit();
        const want = expectedRoot(&.{ .{ "a.txt", "gamma rootneedle\n" }, .{ "b/c.txt", "beta rootneedle\n" } });
        try testing.expectEqualStrings(&want, snapshotRoot(&answer));
    }
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "delta rootneedle\n" });
    {
        var answer = try searchIn(runtime, &session, repo.root, .{ .pattern = "rootneedle", .dir = repo.root, .certificate = true });
        defer answer.deinit();
        const want = expectedRoot(&.{ .{ "a.txt", "delta rootneedle\n" }, .{ "b/c.txt", "beta rootneedle\n" } });
        try testing.expectEqualStrings(&want, snapshotRoot(&answer));
    }
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "c.txt", .data = "added rootneedle\n" });
    try gitIn(repo.root, &.{ "add", "c.txt" });
    {
        var answer = try searchIn(runtime, &session, repo.root, .{ .pattern = "rootneedle", .dir = repo.root, .certificate = true });
        defer answer.deinit();
        const want = expectedRoot(&.{ .{ "a.txt", "delta rootneedle\n" }, .{ "b/c.txt", "beta rootneedle\n" }, .{ "c.txt", "added rootneedle\n" } });
        try testing.expectEqualStrings(&want, snapshotRoot(&answer));
    }
    try repo.tmp.dir.deleteFile(testing.io, "b/c.txt");
    var answer = try searchIn(runtime, &session, repo.root, .{ .pattern = "rootneedle", .dir = repo.root, .certificate = true });
    defer answer.deinit();
    const want = expectedRoot(&.{ .{ "a.txt", "delta rootneedle\n" }, .{ "c.txt", "added rootneedle\n" } });
    try testing.expectEqualStrings(&want, snapshotRoot(&answer));
}

test "search answers: a file given as dir is searched by itself after it changed in the session" {
    var repo = try Repo.init(&.{
        .{ "src/engine/run.ts", "export function run() {\n  return 1;\n}\n" },
        .{ "src/engine/run.tsx", "export const y = continueOnFail;\n" },
    });
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    var session = search_session.Session.init(gpa, testing.io, repo.root, .{});
    defer session.deinit();
    const file = try repo.path("src/engine/run.ts");
    defer gpa.free(file);
    {
        var warm = try searchIn(runtime, &session, repo.root, .{ .pattern = "continueOnFail", .dir = file });
        defer warm.deinit();
        try testing.expectEqual(@as(usize, 0), warm.groups().len);
    }
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "src/engine/run.ts", .data = "export function run() {\n  return continueOnFail();\n}\n" });
    var answer = try searchIn(runtime, &session, repo.root, .{ .pattern = "continueOnFail", .dir = file, .certificate = true });
    defer answer.deinit();
    try testing.expectEqualStrings("complete", answer.status());
    try testing.expectEqual(@as(i64, 1), answer.scope("in_scope"));
    try testing.expectEqual(@as(usize, 1), answer.groups().len);
    try testing.expectEqualStrings("src/engine/run.ts", answer.groups()[0].object.get("file").?.string);
}

fn budgetRepo() !Repo {
    var names: [41][2][]const u8 = undefined;
    var storage: std.ArrayList([]u8) = .empty;
    defer {
        for (storage.items) |b| gpa.free(b);
        storage.deinit(gpa);
    }
    names[0] = .{ "z_def.ts", "export function budgetNeedle(): number {\n  return 1;\n}\n" };
    for (0..20) |i| {
        const path = try std.fmt.allocPrint(gpa, "code_{d:0>2}.ts", .{i});
        try storage.append(gpa, path);
        const body = try std.fmt.allocPrint(gpa, "export const v{d} = budgetNeedle() + {d};\n", .{ i, i });
        try storage.append(gpa, body);
        names[1 + i] = .{ path, body };
    }
    for (0..20) |i| {
        const path = try std.fmt.allocPrint(gpa, "note_{d:0>2}.ts", .{i});
        try storage.append(gpa, path);
        const body = try std.fmt.allocPrint(gpa, "// budgetNeedle is described here, part one of note {d}\n// budgetNeedle again, part two of note {d}\n// budgetNeedle a third time, part three of note {d}\nexport const n{d} = {d};\n", .{ i, i, i, i, i });
        try storage.append(gpa, body);
        names[21 + i] = .{ path, body };
    }
    return Repo.init(&names);
}

const Spot = struct { file: []const u8, line: i64 };

fn spots(answer: *Answer, out: *std.ArrayList(Spot)) !void {
    for (answer.groups()) |g| {
        for (g.object.get("hits").?.array.items) |h| {
            try out.append(gpa, .{ .file = g.object.get("file").?.string, .line = h.object.get("line").?.integer });
        }
    }
}

test "search answers: a reply over the size budget shows the best groups first, says what it left out and is partial" {
    var repo = try budgetRepo();
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var answer = try search(runtime, repo.root, .{ .pattern = "budgetNeedle", .dir = repo.root });
    defer answer.deinit();
    errdefer std.debug.print("{s}\n", .{answer.line()});
    try testing.expect(answer.chars < search_v1.reply_budget + 1500);
    try testing.expectEqualStrings("partial", answer.status());
    try testing.expect(answer.get("truncated").?.bool);
    const more = answer.get("more").?.string;
    try testing.expect(std.mem.indexOf(u8, more, "more hits in") != null);
    try testing.expect(std.mem.indexOf(u8, more, "offset:") != null);
    const groups = answer.groups();
    try testing.expectEqualStrings("z_def.ts", groups[0].object.get("file").?.string);
    try testing.expectEqualStrings("definition", groups[0].object.get("hits").?.array.items[0].object.get("role").?.string);
    try testing.expect(std.mem.startsWith(u8, groups[1].object.get("file").?.string, "code_"));
    var match_limit: i64 = 0;
    for (answer.get("missing").?.array.items) |m| {
        if (std.mem.eql(u8, m.object.get("reason").?.string, "match_limit")) match_limit += m.object.get("files").?.integer;
    }
    try testing.expect(match_limit > 0);
    try testing.expect(std.mem.indexOf(u8, answer.line(), "partial:") != null);
}

test "search answers: detail full lifts the size budget and offset pages through the ranked hits without overlap" {
    var repo = try budgetRepo();
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var full = try search(runtime, repo.root, .{ .pattern = "budgetNeedle", .dir = repo.root, .detail = "full" });
    defer full.deinit();
    try testing.expectEqualStrings("complete", full.status());
    try testing.expect(full.get("more") == null);
    var all: std.ArrayList(Spot) = .empty;
    defer all.deinit(gpa);
    try spots(&full, &all);
    try testing.expectEqual(@as(usize, 81), all.items.len);

    var paged: std.ArrayList(Spot) = .empty;
    defer paged.deinit(gpa);
    var pages: std.ArrayList(Answer) = .empty;
    defer {
        for (pages.items) |*p| p.deinit();
        pages.deinit(gpa);
    }
    var offset: usize = 0;
    while (pages.items.len < 20) {
        try pages.append(gpa, try search(runtime, repo.root, .{ .pattern = "budgetNeedle", .dir = repo.root, .offset = offset }));
        const page = &pages.items[pages.items.len - 1];
        const before = paged.items.len;
        try spots(page, &paged);
        try testing.expect(paged.items.len > before);
        offset = paged.items.len;
        if (page.get("more") == null) break;
    }
    try testing.expect(pages.items.len > 1);
    try testing.expectEqual(all.items.len, paged.items.len);
    for (all.items, paged.items) |a, b| {
        try testing.expectEqualStrings(a.file, b.file);
        try testing.expectEqual(a.line, b.line);
    }
}

test "search answers: an unknown detail or a negative offset is refused" {
    var repo = try Repo.init(&.{.{ "a.ts", "export const a = 1;\n" }});
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    var detail = try search(runtime, repo.root, .{ .pattern = "a", .dir = repo.root, .detail = "everything" });
    defer detail.deinit();
    try testing.expect(detail.is_error);
    try testing.expectEqualStrings("UnknownDetail", detail.errorName());
    var offset = try search(runtime, repo.root, .{ .pattern = "a", .dir = repo.root, .offset = -1 });
    defer offset.deinit();
    try testing.expect(offset.is_error);
    try testing.expectEqualStrings("InvalidOffset", offset.errorName());
}

test "search answers: a capped answer is partial" {
    var lines: std.ArrayList(u8) = .empty;
    defer lines.deinit(gpa);
    for (0..250) |i| try lines.print(gpa, "capneedle {d}\n", .{i});
    var repo = try Repo.init(&.{.{ "many.txt", lines.items }});
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var answer = try search(runtime, repo.root, .{ .pattern = "capneedle", .dir = repo.root, .detail = "full" });
    defer answer.deinit();
    try testing.expectEqualStrings("partial", answer.status());
    try testing.expect(answer.get("truncated").?.bool);
    try testing.expectEqual(@as(usize, 200), answer.hitCount());
}

fn gitExit(root: []const u8, args: []const []const u8) !u8 {
    var argv: [8][]const u8 = undefined;
    argv[0] = "git";
    @memcpy(argv[1..][0..args.len], args);
    const result = try std.process.run(gpa, testing.io, .{ .argv = argv[0 .. args.len + 1], .cwd = .{ .path = root } });
    gpa.free(result.stdout);
    gpa.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code,
        else => error.GitSetupFailed,
    };
}

test "search answers: a search in the middle of a merge conflict answers from the conflicted file instead of failing" {
    var repo = try Repo.init(&.{.{ "a.txt", "base line\n" }});
    defer repo.deinit();
    try gitIn(repo.root, &.{ "checkout", "-q", "-b", "side" });
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "side line\n" });
    try gitIn(repo.root, &.{ "commit", "-q", "-am", "side" });
    try gitIn(repo.root, &.{ "checkout", "-q", "-" });
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "main line\n" });
    try gitIn(repo.root, &.{ "commit", "-q", "-am", "main" });
    try testing.expect(try gitExit(repo.root, &.{ "merge", "-q", "side" }) != 0);
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var answer = try search(runtime, repo.root, .{ .pattern = "side line", .dir = repo.root });
    defer answer.deinit();
    try testing.expect(!answer.is_error);
    try testing.expectEqualStrings("complete", answer.status());
    try testing.expectEqual(@as(usize, 1), answer.groups().len);
    try testing.expectEqualStrings("a.txt", answer.groups()[0].object.get("file").?.string);
}
