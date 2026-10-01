const std = @import("std");
const builtin = @import("builtin");
const git_fixture = @import("git_fixture.zig");
const server = @import("emetgate").server;
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
        return self.get("scope").?.object.get(key).?.integer;
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
    var line: std.Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    var js: std.json.Stringify = .{ .writer = &line.writer };
    try js.write(.{ .jsonrpc = "2.0", .id = 1, .method = "tools/call", .params = .{ .name = "emetgate_search", .arguments = args } });
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try server.handleMessageObserved(gpa, testing.io, runtime, line.written(), &out.writer, null, .{ .root = root });
    var parsed = try std.json.parseFromSlice(Value, gpa, out.written(), .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    const result = parsed.value.object.get("result") orelse return error.NotAToolResult;
    const text = result.object.get("content").?.array.items[0].object.get("text").?.string;
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    errdefer std.debug.print("{s}\n", .{text});
    const body = try std.json.parseFromSlice(Value, gpa, text[0..end], .{ .allocate = .alloc_always });
    return .{ .parsed = parsed, .body = body, .is_error = result.object.get("isError").?.bool };
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

    var answer = try search(runtime, repo.root, .{ .pattern = "continueOnFail", .dir = file });
    defer answer.deinit();
    try testing.expect(!answer.is_error);
    try testing.expectEqualStrings("complete", answer.status());
    try testing.expectEqual(@as(i64, 1), answer.scope("files"));
    try testing.expect(answer.get("scope").?.object.get("is_file").?.bool);
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

    var answer = try search(runtime, repo.root, .{ .pattern = "continueOnFail", .dir = file });
    defer answer.deinit();
    try testing.expectEqual(@as(i64, 0), answer.scope("files"));
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

    var answer = try search(runtime, repo.root, .{ .pattern = "absentNeedle", .dir = repo.root });
    defer answer.deinit();
    try testing.expectEqualStrings("complete", answer.status());
    try testing.expectEqual(@as(i64, 3), answer.scope("files"));
    try testing.expectEqual(@as(i64, 3), answer.scope("evaluated"));
    try testing.expectEqualStrings("no match in 3 file(s)", answer.note());
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

    var answer = try search(runtime, root, .{ .pattern = "handleNodeExecutionError|continueExecution", .dir = root, .regex = true });
    defer answer.deinit();
    try testing.expectEqualStrings("complete", answer.status());
    try testing.expectEqual(@as(i64, file_count), answer.get("matched_files").?.integer);
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

    var answer = try search(runtime, root, .{ .pattern = "(a|b|c|d|e|f|g|h)*z", .dir = root, .regex = true });
    defer answer.deinit();
    try testing.expectEqualStrings("partial", answer.status());
    const missing = answer.get("missing").?.array.items;
    try testing.expectEqual(@as(usize, 1), missing.len);
    try testing.expectEqualStrings("long.txt", missing[0].object.get("path").?.string);
    try testing.expectEqualStrings("regex_step_budget", missing[0].object.get("reason").?.string);
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
    defer held.close(testing.io);

    var answer = try search(runtime, repo.root, .{ .pattern = "lockedneedle", .dir = repo.root });
    defer answer.deinit();
    try testing.expectEqualStrings("partial", answer.status());
    const missing = answer.get("missing").?.array.items;
    try testing.expectEqual(@as(usize, 1), missing.len);
    try testing.expectEqualStrings("unreadable", missing[0].object.get("reason").?.string);
    try testing.expectEqual(@as(usize, 1), answer.groups().len);
}

test "search answers: a capped answer is partial" {
    var lines: std.ArrayList(u8) = .empty;
    defer lines.deinit(gpa);
    for (0..250) |i| try lines.print(gpa, "capneedle {d}\n", .{i});
    var repo = try Repo.init(&.{.{ "many.txt", lines.items }});
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var answer = try search(runtime, repo.root, .{ .pattern = "capneedle", .dir = repo.root });
    defer answer.deinit();
    try testing.expectEqualStrings("partial", answer.status());
    try testing.expect(answer.get("truncated").?.bool);
}
