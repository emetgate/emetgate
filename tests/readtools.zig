const std = @import("std");
const builtin = @import("builtin");
const server = @import("../src/protocol/server.zig");
const read_tools = @import("../src/protocol/read_tools.zig");
const Runtime = @import("../src/engine/runtime.zig").Runtime;

const testing = std.testing;
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
        return std.json.parseFromSlice(Value, testing.allocator, self.text[0..end], .{});
    }
};

fn callTool(runtime: *Runtime, tool: []const u8, args: anytype) !Reply {
    var line: std.Io.Writer.Allocating = .init(testing.allocator);
    defer line.deinit();
    var js: std.json.Stringify = .{ .writer = &line.writer };
    try js.write(.{ .jsonrpc = "2.0", .id = 1, .method = "tools/call", .params = .{ .name = tool, .arguments = args } });

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    _ = try server.handleMessage(testing.allocator, testing.io, runtime, line.written(), &out.writer);

    const parsed = try std.json.parseFromSlice(Value, testing.allocator, out.written(), .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    const result = parsed.value.object.get("result") orelse return error.NotAToolResult;
    const content = result.object.get("content").?.array.items[0];
    return .{ .parsed = parsed, .is_error = result.object.get("isError").?.bool, .text = content.object.get("text").?.string };
}

fn expectToolError(runtime: *Runtime, tool: []const u8, args: anytype, name: []const u8) !void {
    var reply = try callTool(runtime, tool, args);
    defer reply.deinit();
    try testing.expect(reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expectEqualStrings(name, body.value.object.get("error").?.string);
}

fn fileNames(body: Value) []const Value {
    return body.object.get("files").?.array.items;
}

fn containsString(items: []const Value, needle: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item.string, needle)) return true;
    }
    return false;
}

test "read_file returns a small repo file whole" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const expected = try std.Io.Dir.cwd().readFileAlloc(testing.io, "tests/fixtures/functions.ts", testing.allocator, .unlimited);
    defer testing.allocator.free(expected);

    var reply = try callTool(runtime, "synapse_read_file", .{ .file = "tests/fixtures/functions.ts" });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expect(!body.value.object.get("truncated").?.bool);
    try testing.expectEqual(@as(i64, @intCast(expected.len)), body.value.object.get("bytes").?.integer);
    try testing.expectEqualStrings(expected, body.value.object.get("content").?.string);
}

test "read_file caps a large file and says it was truncated" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const path = "src/platform/disk.zig";
    const whole = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .unlimited);
    defer testing.allocator.free(whole);
    try testing.expect(whole.len > 16 * 1024);

    var reply = try callTool(runtime, "synapse_read_file", .{ .file = path });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    const content = body.value.object.get("content").?.string;
    try testing.expect(body.value.object.get("truncated").?.bool);
    try testing.expect(content.len <= 16 * 1024);
    try testing.expect(content.len > 0);
    try testing.expect(std.mem.startsWith(u8, whole, content));
    try testing.expectEqual(@as(i64, @intCast(whole.len)), body.value.object.get("bytes").?.integer);
}

test "read tools refuse a path outside the repo" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const outside = "C:\\Windows\\win.ini";
    std.Io.Dir.cwd().access(testing.io, outside, .{}) catch return error.SkipZigTest;

    try expectToolError(runtime, "synapse_read_file", .{ .file = outside }, "FileOutsideRepo");
    try expectToolError(runtime, "synapse_list", .{ .dir = "C:\\Windows" }, "FileOutsideRepo");
    try expectToolError(runtime, "synapse_search", .{ .pattern = "fonts", .dir = "C:\\Windows" }, "FileOutsideRepo");
}

test "read tools refuse .git internals" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    try expectToolError(runtime, "synapse_read_file", .{ .file = ".git/HEAD" }, "InternalPath");
    try expectToolError(runtime, "synapse_list", .{ .dir = ".git" }, "InternalPath");
}

test "skeleton refuses a non-TypeScript file instead of echoing it; read_file serves it" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "NOTES.md", .data = "SECRET_LINE_77\n" });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "NOTES.md", testing.allocator);
    defer testing.allocator.free(path);

    for ([_][]const u8{ "synapse_skeleton", "synapse_symbols" }) |tool| {
        var reply = try callTool(runtime, tool, .{ .file = path });
        defer reply.deinit();
        try testing.expect(reply.is_error);
        try testing.expect(std.mem.indexOf(u8, reply.text, "NotTypeScript") != null);
        try testing.expect(std.mem.indexOf(u8, reply.text, "SECRET_LINE_77") == null);
    }

    var reply = try callTool(runtime, "synapse_read_file", .{ .file = path });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    try testing.expect(std.mem.indexOf(u8, reply.text, "SECRET_LINE_77") != null);
}

test "read_file refuses a binary file" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "blob.bin", .data = "MZ\x00\x01\x02binary" });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "blob.bin", testing.allocator);
    defer testing.allocator.free(path);
    try expectToolError(runtime, "synapse_read_file", .{ .file = path }, "BinaryFile");
}

test "list returns only tracked files under the requested directory" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var reply = try callTool(runtime, "synapse_list", .{ .dir = "tests/fixtures" });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    const files = fileNames(body.value);
    try testing.expect(containsString(files, "tests/fixtures/functions.ts"));
    for (files) |item| try testing.expect(std.mem.startsWith(u8, item.string, "tests/fixtures/"));
    try testing.expect(!body.value.object.get("truncated").?.bool);
}

test "search finds a literal in tracked files under a directory and refuses an empty pattern" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var reply = try callTool(runtime, "synapse_search", .{ .pattern = "export function afterUnicode", .dir = "tests/fixtures" });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    const matches = body.value.object.get("matches").?.array.items;
    try testing.expect(matches.len >= 1);
    var found = false;
    for (matches) |m| {
        try testing.expect(std.mem.startsWith(u8, m.object.get("file").?.string, "tests/fixtures/"));
        if (std.mem.eql(u8, m.object.get("file").?.string, "tests/fixtures/functions.ts")) found = true;
    }
    try testing.expect(found);

    try expectToolError(runtime, "synapse_search", .{ .pattern = "" }, "EmptyPattern");
}

test "a read is cut on a UTF-8 boundary, never inside a character" {
    try testing.expectEqualStrings("a", read_tools.utf8Prefix("aé", 2));
    try testing.expectEqualStrings("aé", read_tools.utf8Prefix("aé", 3));
    try testing.expectEqualStrings("ab", read_tools.utf8Prefix("ab", 16));
}

test "directory filtering matches whole path segments across separators and case" {
    try testing.expect(read_tools.inDirectory("tests/fixtures/a.ts", ""));
    try testing.expect(read_tools.inDirectory("tests/fixtures/a.ts", "tests\\fixtures"));
    try testing.expect(read_tools.inDirectory("Tests/Fixtures/a.ts", "tests\\fixtures"));
    try testing.expect(!read_tools.inDirectory("tests/fixtures2/a.ts", "tests\\fixtures"));
    try testing.expect(!read_tools.inDirectory("tests", "tests"));
    try testing.expect(!read_tools.inDirectory("src/a.ts", "tests"));
}

fn gitIn(root: []const u8, args: []const []const u8) !void {
    var argv: [8][]const u8 = undefined;
    argv[0] = "git";
    @memcpy(argv[1..][0..args.len], args);
    const result = try std.process.run(testing.allocator, testing.io, .{ .argv = argv[0 .. args.len + 1], .cwd = .{ .path = root } });
    testing.allocator.free(result.stdout);
    testing.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitSetupFailed,
        else => return error.GitSetupFailed,
    }
}

fn searchedFiles(root: []const u8, limits: read_tools.SearchLimits) !std.json.Parsed(Value) {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try read_tools.searchIn(testing.allocator, testing.io, root, "", "needle", limits, &out.writer);
    return std.json.parseFromSlice(Value, testing.allocator, out.written(), .{ .allocate = .alloc_always });
}

fn matchedFile(parsed: Value, name: []const u8) bool {
    for (parsed.object.get("matches").?.array.items) |m| {
        if (std.mem.eql(u8, m.object.get("file").?.string, name)) return true;
    }
    return false;
}

test "search skips tracked files over its size cap and tracked binary files" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "small.txt", .data = "needle here\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "large.txt", .data = "needle " ++ ("x" ** 200) ++ "\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "blob.bin", .data = "needle\x00binary\n" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try gitIn(root, &.{ "init", "-q" });
    try gitIn(root, &.{ "config", "user.email", "t@t" });
    try gitIn(root, &.{ "config", "user.name", "t" });
    try gitIn(root, &.{ "add", "." });
    try gitIn(root, &.{ "commit", "-q", "-m", "init" });

    var capped = try searchedFiles(root, .{ .file_bytes = 64 });
    defer capped.deinit();
    try testing.expect(matchedFile(capped.value, "small.txt"));
    try testing.expect(!matchedFile(capped.value, "large.txt"));
    try testing.expect(!matchedFile(capped.value, "blob.bin"));

    var defaults = try searchedFiles(root, .{});
    defer defaults.deinit();
    try testing.expect(matchedFile(defaults.value, "small.txt"));
    try testing.expect(matchedFile(defaults.value, "large.txt"));
    try testing.expect(!matchedFile(defaults.value, "blob.bin"));
}

test "internal workspace and git paths are refused, others pass" {
    try testing.expectError(error.InternalPath, read_tools.refuseInternal(".git\\HEAD"));
    try testing.expectError(error.InternalPath, read_tools.refuseInternal(".GIT/config"));
    try testing.expectError(error.InternalPath, read_tools.refuseInternal(".synapse\\events.ndjson"));
    try read_tools.refuseInternal("");
    try read_tools.refuseInternal("docs\\.git-notes.md");
    try read_tools.refuseInternal("src\\main.zig");
}
