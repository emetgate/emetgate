const std = @import("std");
const git_fixture = @import("git_fixture.zig");
const builtin = @import("builtin");
const server = @import("emetgate").server;
const read_tools = @import("emetgate").read_tools;
const mirror_mod = @import("emetgate").mirror;
const tree_cache_mod = @import("emetgate").tree_cache;
const Runtime = @import("emetgate").runtime.Runtime;
const outline_mod = @import("emetgate").outline;

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
    const expected = try std.Io.Dir.cwd().readFileAlloc(testing.io, "src/protocol/tool_result.zig", testing.allocator, .unlimited);
    defer testing.allocator.free(expected);

    var reply = try callTool(runtime, "emetgate_read_file", .{ .file = "src/protocol/tool_result.zig", .raw = true });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expect(body.value.object.get("truncated") == null);
    try testing.expect(body.value.object.get("bytes") == null);
    try testing.expectEqualStrings(expected, body.value.object.get("content").?.string);
}

test "read_file returns a source file under the outline threshold whole, with or without raw" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const expected = try std.Io.Dir.cwd().readFileAlloc(testing.io, "tests/fixtures/functions.ts", testing.allocator, .unlimited);
    defer testing.allocator.free(expected);
    try testing.expect(expected.len <= outline_mod.threshold);
    for ([_]bool{ false, true }) |raw| {
        var reply = try callTool(runtime, "emetgate_read_file", .{ .file = "tests/fixtures/functions.ts", .raw = raw });
        defer reply.deinit();
        try testing.expect(!reply.is_error);
        var body = try reply.payload();
        defer body.deinit();
        try testing.expectEqualStrings(expected, body.value.object.get("content").?.string);
    }
}

fn manyFunctions(gpa: std.mem.Allocator, count: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (0..count) |i| try out.writer.print("export function f{d}(a: number): number {{\n  const b = a * {d};\n  const c = b + 1;\n  const d = c - 2;\n  return a + b + c + d;\n}}\n", .{ i, i });
    return out.toOwnedSlice();
}

test "read_file returns the outline of a source file over the threshold, with line ranges and hashes, and text for a line range" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = try manyFunctions(testing.allocator, 200);
    defer testing.allocator.free(source);
    try testing.expect(source.len > outline_mod.threshold);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "big.ts", .data = source });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "big.ts", testing.allocator);
    defer testing.allocator.free(path);
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    for ([_]bool{ false, true }) |raw| {
        var reply = try callTool(runtime, "emetgate_read_file", .{ .file = path, .raw = raw });
        defer reply.deinit();
        try testing.expect(!reply.is_error);
        var body = try reply.payload();
        defer body.deinit();
        try testing.expect(body.value.object.get("content") == null);
        try testing.expectEqual(@as(i64, 1200), body.value.object.get("lines").?.integer);
        try testing.expectEqualStrings(outline_mod.hint, body.value.object.get("hint").?.string);
        const text = body.value.object.get("outline").?.string;
        try testing.expectEqual(@as(usize, 200), std.mem.count(u8, text, "\n"));
        try testing.expect(std.mem.startsWith(u8, text, "1-6 function f0 "));
        try testing.expect(std.mem.indexOf(u8, text, "\n1195-1200 function f199 ") != null);
        try testing.expect(text.len < source.len / 2);
    }

    var range = try callTool(runtime, "emetgate_read_file", .{ .file = path, .line_start = 4, .line_end = 6 });
    defer range.deinit();
    var range_body = try range.payload();
    defer range_body.deinit();
    try testing.expectEqualStrings(linesOf(source, 4, 6), range_body.value.object.get("content").?.string);
}

test "read_file at exactly the outline threshold still returns the text" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const head = "export function f(a: number): number {\n  return a;\n}\n";
    const source = try testing.allocator.alloc(u8, outline_mod.threshold);
    defer testing.allocator.free(source);
    @memset(source, '\n');
    @memcpy(source[0..head.len], head);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "edge.ts", .data = source });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "edge.ts", testing.allocator);
    defer testing.allocator.free(path);
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var reply = try callTool(runtime, "emetgate_read_file", .{ .file = path });
    defer reply.deinit();
    var body = try reply.payload();
    defer body.deinit();
    try testing.expectEqualStrings(source, body.value.object.get("content").?.string);
}

test "read_file returns a JSON key tree by default, and a pointer's subtree with pointer given" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    var tree_reply = try callTool(runtime, "emetgate_read_file", .{ .file = "tests/fixtures/sample.json" });
    defer tree_reply.deinit();
    try testing.expect(!tree_reply.is_error);
    var tree_body = try tree_reply.payload();
    defer tree_body.deinit();
    const keys = tree_body.value.object.get("keys").?.array.items;
    var found_dependencies = false;
    for (keys) |k| {
        try testing.expect(!std.mem.eql(u8, k.object.get("pointer").?.string, "/dependencies/express"));
        if (std.mem.eql(u8, k.object.get("pointer").?.string, "/dependencies")) {
            try testing.expectEqualStrings("object", k.object.get("type").?.string);
            try testing.expect(k.object.get("children").?.integer >= 1);
            found_dependencies = true;
        }
    }
    try testing.expect(found_dependencies);

    var value_reply = try callTool(runtime, "emetgate_read_file", .{ .file = "tests/fixtures/sample.json", .pointer = "/dependencies/express" });
    defer value_reply.deinit();
    try testing.expect(!value_reply.is_error);
    var value_body = try value_reply.payload();
    defer value_body.deinit();
    try testing.expectEqualStrings("\"^4.0.0\"", value_body.value.object.get("value").?.string);
}

extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: std.os.windows.DWORD, share: std.os.windows.DWORD, security: ?*anyopaque, disposition: std.os.windows.DWORD, flags: std.os.windows.DWORD, template: ?std.os.windows.HANDLE) callconv(.winapi) std.os.windows.HANDLE;

fn holdWithoutSharing(path: []const u8) !std.os.windows.HANDLE {
    var wide: [std.os.windows.PATH_MAX_WIDE:0]u16 = undefined;
    const len = try std.unicode.wtf8ToWtf16Le(&wide, path);
    wide[len] = 0;
    for (0..200) |_| {
        const handle = CreateFileW(&wide, 0x80000000, 0, null, 3, 0x80, null);
        if (handle != std.os.windows.INVALID_HANDLE_VALUE) return handle;
        try std.Io.sleep(testing.io, .fromMilliseconds(5), .awake);
    }
    return error.HoldFailed;
}

test "read_file on a file another handle holds without sharing fails as busy within 50 ms" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "held.txt", .data = "held text\n" });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "held.txt", testing.allocator);
    defer testing.allocator.free(path);
    const root = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const holder = try holdWithoutSharing(path);
    defer std.os.windows.CloseHandle(holder);

    var line: std.Io.Writer.Allocating = .init(testing.allocator);
    defer line.deinit();
    var js: std.json.Stringify = .{ .writer = &line.writer };
    try js.write(.{ .jsonrpc = "2.0", .id = 1, .method = "tools/call", .params = .{ .name = "emetgate_read_file", .arguments = .{ .file = path } } });
    var fastest: i96 = std.math.maxInt(i96);
    for (0..5) |_| {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        const started = std.Io.Clock.awake.now(testing.io).nanoseconds;
        _ = try server.handleMessageObserved(testing.allocator, testing.io, runtime, line.written(), &out.writer, null, .{ .root = root });
        fastest = @min(fastest, std.Io.Clock.awake.now(testing.io).nanoseconds - started);
        errdefer std.debug.print("{s}\n", .{out.written()});
        try testing.expect(std.mem.indexOf(u8, out.written(), "FileBusy") != null);
    }
    try testing.expect(fastest < 50 * std.time.ns_per_ms);
}

test "read_file refuses malformed JSON instead of serving a partial key tree" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "broken.json", .data = "{\"a\": }" });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "broken.json", testing.allocator);
    defer testing.allocator.free(path);

    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    try expectToolError(runtime, "emetgate_read_file", .{ .file = path }, "InvalidJson");
}

test "read_file returns a Markdown heading tree by default, and one section with heading given" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    var tree_reply = try callTool(runtime, "emetgate_read_file", .{ .file = "tests/fixtures/sample.md" });
    defer tree_reply.deinit();
    try testing.expect(!tree_reply.is_error);
    var tree_body = try tree_reply.payload();
    defer tree_body.deinit();
    const headings = tree_body.value.object.get("headings").?.array.items;
    var found_setup = false;
    for (headings) |h| {
        if (std.mem.eql(u8, h.object.get("heading").?.string, "Setup")) {
            try testing.expectEqual(@as(i64, 2), h.object.get("level").?.integer);
            found_setup = true;
        }
    }
    try testing.expect(found_setup);

    var section_reply = try callTool(runtime, "emetgate_read_file", .{ .file = "tests/fixtures/sample.md", .heading = "Setup" });
    defer section_reply.deinit();
    try testing.expect(!section_reply.is_error);
    var section_body = try section_reply.payload();
    defer section_body.deinit();
    const section = section_body.value.object.get("section").?.string;
    try testing.expect(std.mem.indexOf(u8, section, "## Setup") != null);
    try testing.expect(std.mem.indexOf(u8, section, "### Install") != null);
    try testing.expect(std.mem.indexOf(u8, section, "## Other") == null);
}

test "read_file on an unknown Markdown heading is a tool error" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    try expectToolError(runtime, "emetgate_read_file", .{ .file = "tests/fixtures/sample.md", .heading = "Nope" }, "HeadingNotFound");
}

test "read_file with raw skips the Markdown heading tree" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var reply = try callTool(runtime, "emetgate_read_file", .{ .file = "tests/fixtures/sample.md", .raw = true });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    try testing.expect(std.mem.indexOf(u8, reply.text, "\"headings\"") == null);
    try testing.expect(std.mem.indexOf(u8, reply.text, "# Title") != null);
}

test "read_file on an unknown JSON pointer is a tool error" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    try expectToolError(runtime, "emetgate_read_file", .{ .file = "tests/fixtures/sample.json", .pointer = "/nope" }, "PointerNotFound");
}

test "read_file with raw skips the JSON key tree" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var reply = try callTool(runtime, "emetgate_read_file", .{ .file = "tests/fixtures/sample.json", .raw = true });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    try testing.expect(std.mem.indexOf(u8, reply.text, "\"keys\"") == null);
    try testing.expect(std.mem.indexOf(u8, reply.text, "dependencies") != null);
}

test "read_file with a line range returns just that range and its hash" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var reply = try callTool(runtime, "emetgate_read_file", .{ .file = "LICENSE", .line_start = 1, .line_end = 1 });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expect(body.value.object.get("hash") != null);
    const content = body.value.object.get("content").?.string;
    try testing.expect(std.mem.count(u8, content, "\n") <= 1);
}

fn linesOf(bytes: []const u8, first: usize, last: usize) []const u8 {
    var line: usize = 1;
    var start: ?usize = if (first == 1) 0 else null;
    for (bytes, 0..) |c, i| {
        if (c != '\n') continue;
        if (line == last) return bytes[start.? .. i + 1];
        line += 1;
        if (line == first) start = i + 1;
    }
    return bytes[start.?..];
}

test "read_file applies a line range to a raw read of a source file" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const path = "tests/fixtures/functions.ts";
    const whole = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .unlimited);
    defer testing.allocator.free(whole);

    var reply = try callTool(runtime, "emetgate_read_file", .{ .file = path, .raw = true, .line_start = 3, .line_end = 5 });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expectEqualStrings(linesOf(whole, 3, 5), body.value.object.get("content").?.string);
    try testing.expectEqual(@as(i64, 3), body.value.object.get("start_line").?.integer);
    try testing.expectEqual(@as(i64, 5), body.value.object.get("end_line").?.integer);
    try testing.expect(body.value.object.get("status") == null);
    try testing.expect(body.value.object.get("truncated") == null);
}

test "read_file refuses an inverted or out-of-file line range and marks a range cut at the end of the file as partial" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const path = "tests/fixtures/functions.ts";
    const whole = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .unlimited);
    defer testing.allocator.free(whole);
    const last: i64 = @intCast(std.mem.count(u8, whole, "\n") + @intFromBool(whole[whole.len - 1] != '\n'));

    try expectToolError(runtime, "emetgate_read_file", .{ .file = path, .raw = true, .line_start = 5, .line_end = 3 }, "InvalidLineRange");
    try expectToolError(runtime, "emetgate_read_file", .{ .file = path, .raw = true, .line_start = last + 1, .line_end = last + 5 }, "LineOutOfRange");

    var reply = try callTool(runtime, "emetgate_read_file", .{ .file = path, .raw = true, .line_start = last - 1, .line_end = last + 40 });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expectEqualStrings("partial", body.value.object.get("status").?.string);
    try testing.expectEqual(last, body.value.object.get("end_line").?.integer);
    try testing.expectEqual(last + 40, body.value.object.get("requested_end_line").?.integer);
    try testing.expectEqualStrings(linesOf(whole, @intCast(last - 1), @intCast(last)), body.value.object.get("content").?.string);
}

test "read_file caps a large file and says it was truncated" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const whole = try testing.allocator.alloc(u8, 40 * 1024);
    defer testing.allocator.free(whole);
    for (whole, 0..) |*c, i| c.* = if (i % 64 == 63) '\n' else 'a' + @as(u8, @intCast(i % 26));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "big.txt", .data = whole });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "big.txt", testing.allocator);
    defer testing.allocator.free(path);

    var reply = try callTool(runtime, "emetgate_read_file", .{ .file = path, .raw = true });
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

    try expectToolError(runtime, "emetgate_read_file", .{ .file = outside }, "FileOutsideRepo");
    try expectToolError(runtime, "emetgate_list", .{ .dir = "C:\\Windows" }, "FileOutsideRepo");
    try expectToolError(runtime, "emetgate_search", .{ .pattern = "fonts", .dir = "C:\\Windows" }, "FileOutsideRepo");
}

test "read tools refuse a file whose real path matches the served root's length but leaves it at its last name, and a file of the previously served root" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "r");
    try tmp.dir.createDirPath(testing.io, "x/y");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "r/a.txt", .data = "inside\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "x/y/f.txt", .data = "outside secret\n" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, "r", testing.allocator);
    defer testing.allocator.free(root);
    try commitAll(root);
    const outside = try tmp.dir.realPathFileAlloc(testing.io, "x/y/f.txt", testing.allocator);
    defer testing.allocator.free(outside);
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    for ([_][]const u8{ "emetgate_read_file", "emetgate_search" }) |tool| {
        var reply = if (std.mem.eql(u8, tool, "emetgate_read_file"))
            try callToolServed(runtime, root, tool, .{ .file = outside })
        else
            try callToolServed(runtime, root, tool, .{ .pattern = "secret", .dir = outside });
        defer reply.deinit();
        try testing.expect(reply.is_error);
        var body = try reply.payload();
        defer body.deinit();
        try testing.expectEqualStrings("FileOutsideRepo", body.value.object.get("error").?.string);
    }

    try tmp.dir.createDirPath(testing.io, "s");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "s/b.txt", .data = "other repo\n" });
    const other = try tmp.dir.realPathFileAlloc(testing.io, "s", testing.allocator);
    defer testing.allocator.free(other);
    try commitAll(other);
    const first = try tmp.dir.realPathFileAlloc(testing.io, "r/a.txt", testing.allocator);
    defer testing.allocator.free(first);
    {
        var reply = try callToolServed(runtime, root, "emetgate_read_file", .{ .file = first });
        defer reply.deinit();
        try testing.expect(!reply.is_error);
    }
    var reply = try callToolServed(runtime, other, "emetgate_read_file", .{ .file = first });
    defer reply.deinit();
    try testing.expect(reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expectEqualStrings("FileOutsideRepo", body.value.object.get("error").?.string);
}

test "read tools refuse a file of a nested repository, worktree or bare repository under the served root, at any depth" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "dirrepo/a/b");
    const dirrepo = try tmp.dir.realPathFileAlloc(testing.io, "dirrepo", testing.allocator);
    defer testing.allocator.free(dirrepo);
    try git_fixture.initRepo(dirrepo);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "dirrepo/a/b/note.txt", .data = "nested\n" });
    try tmp.dir.createDirPath(testing.io, "filerepo/src");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "filerepo/.git", .data = "gitdir: C:/nowhere/.git/worktrees/x\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "filerepo/src/note.txt", .data = "nested\n" });
    try tmp.dir.createDirPath(testing.io, "bare.git/objects");
    try tmp.dir.createDirPath(testing.io, "bare.git/refs");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bare.git/HEAD", .data = "ref: refs/heads/main\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bare.git/description", .data = "nested\n" });
    try tmp.dir.createDirPath(testing.io, "plain/a");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "plain/a/note.txt", .data = "plain\n" });

    for ([_][]const u8{ "dirrepo/a/b/note.txt", "filerepo/src/note.txt", "bare.git/description" }) |rel| {
        const abs = try tmp.dir.realPathFileAlloc(testing.io, rel, testing.allocator);
        defer testing.allocator.free(abs);
        errdefer std.debug.print("not refused: {s}\n", .{rel});
        try expectToolError(runtime, "emetgate_read_file", .{ .file = abs }, "FileOutsideRepo");
    }
    const plain = try tmp.dir.realPathFileAlloc(testing.io, "plain/a/note.txt", testing.allocator);
    defer testing.allocator.free(plain);
    var reply = try callTool(runtime, "emetgate_read_file", .{ .file = plain });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expectEqualStrings("plain\n", body.value.object.get("content").?.string);
}

extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: ?[*:0]const u16) callconv(.winapi) std.os.windows.BOOL;

test "with a git discovery variable set for the server, read tools still refuse a nested repository and serve the served one" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "dirrepo/a");
    const dirrepo = try tmp.dir.realPathFileAlloc(testing.io, "dirrepo", testing.allocator);
    defer testing.allocator.free(dirrepo);
    try git_fixture.initRepo(dirrepo);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "dirrepo/a/note.txt", .data = "nested\n" });
    try tmp.dir.createDirPath(testing.io, "plain");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "plain/note.txt", .data = "plain\n" });
    const nested = try tmp.dir.realPathFileAlloc(testing.io, "dirrepo/a/note.txt", testing.allocator);
    defer testing.allocator.free(nested);
    const plain = try tmp.dir.realPathFileAlloc(testing.io, "plain/note.txt", testing.allocator);
    defer testing.allocator.free(plain);

    const name = std.unicode.utf8ToUtf16LeStringLiteral("GIT_CEILING_DIRECTORIES");
    try testing.expect(SetEnvironmentVariableW(name, std.unicode.utf8ToUtf16LeStringLiteral("C:\\emetgate-no-such-ceiling")) != .FALSE);
    defer _ = SetEnvironmentVariableW(name, null);
    try expectToolError(runtime, "emetgate_read_file", .{ .file = nested }, "FileOutsideRepo");
    var reply = try callTool(runtime, "emetgate_read_file", .{ .file = plain });
    defer reply.deinit();
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expectEqualStrings("plain\n", body.value.object.get("content").?.string);
}

test "read tools refuse .git internals" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    try expectToolError(runtime, "emetgate_read_file", .{ .file = ".git/HEAD" }, "InternalPath");
    try expectToolError(runtime, "emetgate_list", .{ .dir = ".git" }, "InternalPath");
}

test "skeleton refuses a file of no registered language instead of echoing it; read_file serves it" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "NOTES.txt", .data = "SECRET_LINE_77\n" });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "NOTES.txt", testing.allocator);
    defer testing.allocator.free(path);

    for ([_][]const u8{ "emetgate_skeleton", "emetgate_symbols" }) |tool| {
        var reply = try callTool(runtime, tool, .{ .file = path });
        defer reply.deinit();
        try testing.expect(reply.is_error);
        try testing.expect(std.mem.indexOf(u8, reply.text, "UnsupportedLanguage") != null);
        try testing.expect(std.mem.indexOf(u8, reply.text, "SECRET_LINE_77") == null);
    }

    var reply = try callTool(runtime, "emetgate_read_file", .{ .file = path });
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
    try expectToolError(runtime, "emetgate_read_file", .{ .file = path }, "BinaryFile");
}

test "with --mirror, read_file reports unchanged on a repeat and full content after force or a change" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "notes.txt", .data = "hello\n" });
    const root_abs = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root_abs);
    try commitAll(root_abs);
    const file_abs = try tmp.dir.realPathFileAlloc(testing.io, "notes.txt", testing.allocator);
    defer testing.allocator.free(file_abs);

    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var m: mirror_mod.Mirror = .init(testing.allocator, true);
    defer m.deinit();
    const policy: server.Policy = .{ .mirror = &m, .root = root_abs };

    var first = try callToolServedPolicy(runtime, "emetgate_read_file", .{ .file = file_abs }, policy);
    defer first.deinit();
    try testing.expect(!first.is_error);
    try testing.expect(std.mem.indexOf(u8, first.text, "hello") != null);

    var second = try callToolServedPolicy(runtime, "emetgate_read_file", .{ .file = file_abs }, policy);
    defer second.deinit();
    var second_body = try second.payload();
    defer second_body.deinit();
    try testing.expectEqualStrings("unchanged", second_body.value.object.get("status").?.string);

    var forced = try callToolServedPolicy(runtime, "emetgate_read_file", .{ .file = file_abs, .force = true }, policy);
    defer forced.deinit();
    try testing.expect(std.mem.indexOf(u8, forced.text, "hello") != null);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "notes.txt", .data = "goodbye\n" });
    var changed = try callToolServedPolicy(runtime, "emetgate_read_file", .{ .file = file_abs }, policy);
    defer changed.deinit();
    try testing.expect(std.mem.indexOf(u8, changed.text, "goodbye") != null);
}

test "with --mirror, a changed symbol body is reported again in full with its new hash" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export function add(a: number): number {\n  return a;\n}\n" });
    const root_abs = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root_abs);
    try commitAll(root_abs);
    const file_abs = try tmp.dir.realPathFileAlloc(testing.io, "a.ts", testing.allocator);
    defer testing.allocator.free(file_abs);

    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var m: mirror_mod.Mirror = .init(testing.allocator, true);
    defer m.deinit();
    const policy: server.Policy = .{ .mirror = &m, .root = root_abs };

    var first = try callToolServedPolicy(runtime, "emetgate_read_symbol", .{ .file = file_abs, .symbol = "add" }, policy);
    defer first.deinit();
    try testing.expect(std.mem.indexOf(u8, first.text, "\"body\":\"") != null);

    var unchanged = try callToolServedPolicy(runtime, "emetgate_read_symbol", .{ .file = file_abs, .symbol = "add" }, policy);
    defer unchanged.deinit();
    var unchanged_body = try unchanged.payload();
    defer unchanged_body.deinit();
    try testing.expectEqualStrings("unchanged", unchanged_body.value.object.get("status").?.string);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export function add(a: number): number {\n  return a + 1;\n}\n" });

    var changed = try callToolServedPolicy(runtime, "emetgate_read_symbol", .{ .file = file_abs, .symbol = "add" }, policy);
    defer changed.deinit();
    try testing.expect(std.mem.indexOf(u8, changed.text, "\"body\":\"") != null);
    try testing.expect(std.mem.indexOf(u8, changed.text, "return a + 1") != null);

    var settled = try callToolServedPolicy(runtime, "emetgate_read_symbol", .{ .file = file_abs, .symbol = "add" }, policy);
    defer settled.deinit();
    var settled_body = try settled.payload();
    defer settled_body.deinit();
    try testing.expectEqualStrings("unchanged", settled_body.value.object.get("status").?.string);
}

test "with a tree cache, a symbol table is not reparsed for an unchanged file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export function add(a: number): number {\n  return a;\n}\n" });
    const root_abs = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root_abs);
    try commitAll(root_abs);
    const file_abs = try tmp.dir.realPathFileAlloc(testing.io, "a.ts", testing.allocator);
    defer testing.allocator.free(file_abs);

    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var cache: tree_cache_mod.TreeCache = .init(testing.allocator);
    defer cache.deinit();
    const policy: server.Policy = .{ .root = root_abs, .tree_cache = &cache };

    var first = try callToolServedPolicy(runtime, "emetgate_symbols", .{ .file = file_abs }, policy);
    defer first.deinit();
    try testing.expect(!first.is_error);
    try testing.expectEqual(@as(usize, 1), cache.count());

    var second = try callToolServedPolicy(runtime, "emetgate_skeleton", .{ .file = file_abs }, policy);
    defer second.deinit();
    try testing.expect(!second.is_error);
    try testing.expectEqual(@as(usize, 1), cache.count());
}

test "with a tree cache, read_symbol after a committed emetgate_try reflects the change, not a stale cached tree" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export function add(a: number): number {\n  return a;\n}\n" });
    const root_abs = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root_abs);
    try commitAll(root_abs);
    const file_abs = try tmp.dir.realPathFileAlloc(testing.io, "a.ts", testing.allocator);
    defer testing.allocator.free(file_abs);

    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var cache: tree_cache_mod.TreeCache = .init(testing.allocator);
    defer cache.deinit();
    const policy: server.Policy = .{ .root = root_abs, .tree_cache = &cache, .test_command = "cmd /c exit 0" };

    var warm = try callToolServedPolicy(runtime, "emetgate_read_symbol", .{ .file = file_abs, .symbol = "add" }, policy);
    defer warm.deinit();
    try testing.expect(!warm.is_error);
    var warm_body = try warm.payload();
    defer warm_body.deinit();
    const hash = warm_body.value.object.get("hash").?.string;

    var tried = try callToolServedPolicy(runtime, "emetgate_try", .{ .file = file_abs, .symbol = "add", .hash = hash, .body = "{ return a + 1; }" }, policy);
    defer tried.deinit();
    try testing.expect(!tried.is_error);

    var after = try callToolServedPolicy(runtime, "emetgate_read_symbol", .{ .file = file_abs, .symbol = "add" }, policy);
    defer after.deinit();
    try testing.expect(!after.is_error);
    try testing.expect(std.mem.indexOf(u8, after.text, "return a + 1") != null);
}

test "with a tree cache, read_symbol after a committed emetgate_try_batch reflects the change" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export function add(a: number): number {\n  return a;\n}\n" });
    const root_abs = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root_abs);
    try commitAll(root_abs);
    const file_abs = try tmp.dir.realPathFileAlloc(testing.io, "a.ts", testing.allocator);
    defer testing.allocator.free(file_abs);

    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var cache: tree_cache_mod.TreeCache = .init(testing.allocator);
    defer cache.deinit();
    const policy: server.Policy = .{ .root = root_abs, .tree_cache = &cache, .test_command = "cmd /c exit 0" };

    var warm = try callToolServedPolicy(runtime, "emetgate_read_symbol", .{ .file = file_abs, .symbol = "add" }, policy);
    defer warm.deinit();
    var warm_body = try warm.payload();
    defer warm_body.deinit();
    const hash = warm_body.value.object.get("hash").?.string;

    var tried = try callToolServedPolicy(runtime, "emetgate_try_batch", .{
        .edits = &.{.{ .file = file_abs, .symbol = "add", .hash = hash, .body = "{ return a + 1; }" }},
    }, policy);
    defer tried.deinit();
    try testing.expect(!tried.is_error);

    var after = try callToolServedPolicy(runtime, "emetgate_read_symbol", .{ .file = file_abs, .symbol = "add" }, policy);
    defer after.deinit();
    try testing.expect(std.mem.indexOf(u8, after.text, "return a + 1") != null);
}

test "list returns only tracked files under the requested directory" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var reply = try callTool(runtime, "emetgate_list", .{ .dir = "tests/fixtures" });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    const files = fileNames(body.value);
    try testing.expect(containsString(files, "tests/fixtures/functions.ts"));
    for (files) |item| try testing.expect(std.mem.startsWith(u8, item.string, "tests/fixtures/"));
    try testing.expect(body.value.object.get("truncated") == null);
}

test "search finds a literal in tracked files under a directory and refuses an empty pattern" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var reply = try callTool(runtime, "emetgate_search", .{ .pattern = "export function afterUnicode", .dir = "tests/fixtures" });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    const groups = body.value.object.get("groups").?.array.items;
    try testing.expect(groups.len >= 1);
    var found = false;
    for (groups) |g| {
        try testing.expect(std.mem.startsWith(u8, g.object.get("file").?.string, "tests/fixtures/"));
        if (std.mem.eql(u8, g.object.get("file").?.string, "tests/fixtures/functions.ts")) found = true;
    }
    try testing.expect(found);

    try expectToolError(runtime, "emetgate_search", .{ .pattern = "" }, "EmptyPattern");
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
    const result = try @import("emetgate").bounded_run.run(testing.allocator, testing.io, .{ .argv = argv[0 .. args.len + 1], .cwd = .{ .path = root } });
    testing.allocator.free(result.stdout);
    testing.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitSetupFailed,
        else => return error.GitSetupFailed,
    }
}

fn commitAll(root: []const u8) !void {
    try git_fixture.initRepo(root);
    try gitIn(root, &.{ "add", "." });
    try gitIn(root, &.{ "commit", "-q", "-m", "init" });
}

test "internal workspace and git paths are refused, others pass" {
    try testing.expectError(error.InternalPath, read_tools.refuseInternal(".git\\HEAD"));
    try testing.expectError(error.InternalPath, read_tools.refuseInternal(".GIT/config"));
    try testing.expectError(error.InternalPath, read_tools.refuseInternal(".emetgate\\events.ndjson"));
    try read_tools.refuseInternal("");
    try read_tools.refuseInternal("docs\\.git-notes.md");
    try read_tools.refuseInternal("src\\main.zig");
}

fn callToolServed(runtime: *Runtime, root: []const u8, tool: []const u8, args: anytype) !Reply {
    return callToolServedPolicy(runtime, tool, args, .{ .root = root });
}

fn callToolServedPolicy(runtime: *Runtime, tool: []const u8, args: anytype, policy: server.Policy) !Reply {
    var line: std.Io.Writer.Allocating = .init(testing.allocator);
    defer line.deinit();
    var js: std.json.Stringify = .{ .writer = &line.writer };
    try js.write(.{ .jsonrpc = "2.0", .id = 1, .method = "tools/call", .params = .{ .name = tool, .arguments = args } });

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    _ = try server.handleMessageObserved(testing.allocator, testing.io, runtime, line.written(), &out.writer, null, policy);

    const parsed = try std.json.parseFromSlice(Value, testing.allocator, out.written(), .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    const result = parsed.value.object.get("result") orelse return error.NotAToolResult;
    const content = result.object.get("content").?.array.items[0];
    return .{ .parsed = parsed, .is_error = result.object.get("isError").?.bool, .text = content.object.get("text").?.string };
}

test "read tools refuse a path that only reaches .git through a junction" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "repo");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/a.ts", .data = "export const a = 1;\n" });
    const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", testing.allocator);
    defer testing.allocator.free(root_abs);
    try commitAll(root_abs);
    const made = try @import("emetgate").bounded_run.run(testing.allocator, testing.io, .{ .argv = &.{ "cmd", "/c", "mklink", "/J", "alias", ".git" }, .cwd = .{ .path = root_abs } });
    testing.allocator.free(made.stdout);
    testing.allocator.free(made.stderr);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, made.term);

    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const file = try std.fmt.allocPrint(testing.allocator, "{s}/alias/HEAD", .{root_abs});
    defer testing.allocator.free(file);
    var reply = try callToolServed(runtime, root_abs, "emetgate_read_file", .{ .file = file });
    defer reply.deinit();
    errdefer std.debug.print("reply: {s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expectEqualStrings("InternalPath", body.value.object.get("error").?.string);
}

test "read tools refuse .git internals in a git worktree, where .git is a file" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "main");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "main/a.ts", .data = "export const a = 1;\n" });
    const main_abs = try tmp.dir.realPathFileAlloc(testing.io, "main", testing.allocator);
    defer testing.allocator.free(main_abs);
    try commitAll(main_abs);
    try gitIn(main_abs, &.{ "worktree", "add", "-q", "../wt" });
    const wt_abs = try tmp.dir.realPathFileAlloc(testing.io, "wt", testing.allocator);
    defer testing.allocator.free(wt_abs);

    const dot_git = try tmp.dir.statFile(testing.io, "wt/.git", .{});
    try testing.expectEqual(std.Io.File.Kind.file, dot_git.kind);

    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    for ([_][]const u8{ ".git/HEAD", ".git/config", ".GIT/HEAD", ".git" }) |inside| {
        const file = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ wt_abs, inside });
        defer testing.allocator.free(file);
        var reply = try callToolServed(runtime, wt_abs, "emetgate_read_file", .{ .file = file });
        defer reply.deinit();
        errdefer std.debug.print("{s}: {s}\n", .{ inside, reply.text });
        try testing.expect(reply.is_error);
        var body = try reply.payload();
        defer body.deinit();
        try testing.expectEqualStrings("InternalPath", body.value.object.get("error").?.string);
    }

    const served = try std.fmt.allocPrint(testing.allocator, "{s}/a.ts", .{wt_abs});
    defer testing.allocator.free(served);
    var ok = try callToolServed(runtime, wt_abs, "emetgate_read_file", .{ .file = served, .raw = true });
    defer ok.deinit();
    try testing.expect(!ok.is_error);
}

fn statusOf(reply: *Reply) ![]const u8 {
    var body = try reply.payload();
    defer body.deinit();
    const status = body.value.object.get("status") orelse return "";
    return if (std.mem.eql(u8, status.string, "unchanged")) "unchanged" else "other";
}

test "after a whole read_file, reads of its symbols and lines come back unchanged until the file changes or force is set" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export function add(a: number): number {\n  return a;\n}\nexport function sub(a: number): number {\n  return -a;\n}\n" });
    const root_abs = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root_abs);
    try commitAll(root_abs);
    const file_abs = try tmp.dir.realPathFileAlloc(testing.io, "a.ts", testing.allocator);
    defer testing.allocator.free(file_abs);

    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var m: mirror_mod.Mirror = .init(testing.allocator, true);
    defer m.deinit();
    const policy: server.Policy = .{ .mirror = &m, .root = root_abs };

    var whole = try callToolServedPolicy(runtime, "emetgate_read_file", .{ .file = file_abs }, policy);
    defer whole.deinit();
    try testing.expect(std.mem.indexOf(u8, whole.text, "return -a") != null);

    var sym = try callToolServedPolicy(runtime, "emetgate_read_symbol", .{ .file = file_abs, .symbol = "add" }, policy);
    defer sym.deinit();
    try testing.expectEqualStrings("unchanged", try statusOf(&sym));
    try testing.expect(std.mem.indexOf(u8, sym.text, "return a") == null);
    try testing.expect(std.mem.indexOf(u8, sym.text, "file_hash") != null);

    var many = try callToolServedPolicy(runtime, "emetgate_read_symbol", .{ .file = file_abs, .symbols = &[_][]const u8{ "add", "sub" } }, policy);
    defer many.deinit();
    try testing.expect(!many.is_error);
    try testing.expect(std.mem.indexOf(u8, many.text, "return") == null);

    var lines = try callToolServedPolicy(runtime, "emetgate_read_symbol", .{ .file = file_abs, .line_start = 4, .line_end = 5 }, policy);
    defer lines.deinit();
    try testing.expect(!lines.is_error);
    try testing.expect(std.mem.indexOf(u8, lines.text, "return") == null);

    var range = try callToolServedPolicy(runtime, "emetgate_read_file", .{ .file = file_abs, .line_start = 2, .line_end = 2 }, policy);
    defer range.deinit();
    try testing.expectEqualStrings("unchanged", try statusOf(&range));

    var forced = try callToolServedPolicy(runtime, "emetgate_read_symbol", .{ .file = file_abs, .symbol = "sub", .force = true }, policy);
    defer forced.deinit();
    try testing.expect(std.mem.indexOf(u8, forced.text, "return -a") != null);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export function add(a: number): number {\n  return a + 1;\n}\nexport function sub(a: number): number {\n  return -a;\n}\n" });
    var changed = try callToolServedPolicy(runtime, "emetgate_read_symbol", .{ .file = file_abs, .symbol = "add" }, policy);
    defer changed.deinit();
    try testing.expect(std.mem.indexOf(u8, changed.text, "return a + 1") != null);

    var changed_range = try callToolServedPolicy(runtime, "emetgate_read_file", .{ .file = file_abs, .line_start = 5, .line_end = 5 }, policy);
    defer changed_range.deinit();
    try testing.expect(std.mem.indexOf(u8, changed_range.text, "return -a") != null);
}

test "a truncated read_file does not cover a later line range read" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const whole = try testing.allocator.alloc(u8, 40 * 1024);
    defer testing.allocator.free(whole);
    for (whole, 0..) |*c, i| c.* = if (i % 64 == 63) '\n' else 'a' + @as(u8, @intCast(i % 26));
    @memcpy(whole[whole.len - 9 ..], "TAIL_MARK");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "big.txt", .data = whole });
    const root_abs = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root_abs);
    try commitAll(root_abs);
    const file_abs = try tmp.dir.realPathFileAlloc(testing.io, "big.txt", testing.allocator);
    defer testing.allocator.free(file_abs);

    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var m: mirror_mod.Mirror = .init(testing.allocator, true);
    defer m.deinit();
    const policy: server.Policy = .{ .mirror = &m, .root = root_abs };

    var first = try callToolServedPolicy(runtime, "emetgate_read_file", .{ .file = file_abs }, policy);
    defer first.deinit();
    try testing.expect(std.mem.indexOf(u8, first.text, "TAIL_MARK") == null);
    const last: i64 = @intCast(std.mem.count(u8, whole, "\n") + 1);
    var tail = try callToolServedPolicy(runtime, "emetgate_read_file", .{ .file = file_abs, .line_start = last, .line_end = last }, policy);
    defer tail.deinit();
    try testing.expect(std.mem.indexOf(u8, tail.text, "TAIL_MARK") != null);
}

test "read_symbol over a line range that holds no symbol returns the raw lines instead of an error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "c.js", .data = "\"use strict\";\nmodule.exports = {\n  meta: { type: \"problem\" },\n};\nfunction f() {\n  return 1;\n}\n" });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "c.js", testing.allocator);
    defer testing.allocator.free(path);
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try callTool(runtime, "emetgate_read_symbol", .{ .file = path, .line_start = 2, .line_end = 4 });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expectEqualStrings("module.exports = {\n  meta: { type: \"problem\" },\n};\n", body.value.object.get("content").?.string);
    try testing.expectEqual(@as(i64, 2), body.value.object.get("start_line").?.integer);

    try expectToolError(runtime, "emetgate_read_symbol", .{ .file = path, .line_start = 40, .line_end = 41 }, "LineOutOfRange");
}

test "policy: the read cache is on by default, --no-mirror turns it off, and a mirror flag is given at most once" {
    try testing.expect(server.parsePolicy(&[_][]const u8{}).?.mirror_enabled);
    try testing.expect(server.parsePolicy(&[_][]const u8{"--mirror"}).?.mirror_enabled);
    try testing.expect(!server.parsePolicy(&[_][]const u8{"--no-mirror"}).?.mirror_enabled);
    try testing.expect(server.parsePolicy(&[_][]const u8{ "--mirror", "--mirror" }) == null);
    try testing.expect(server.parsePolicy(&[_][]const u8{ "--mirror", "--no-mirror" }) == null);
    try testing.expect(server.parsePolicy(&[_][]const u8{}).?.raw_code);
    try testing.expect(!server.parsePolicy(&[_][]const u8{"--json-code"}).?.raw_code);
    try testing.expect(server.parsePolicy(&[_][]const u8{ "--json-code", "--json-code" }) == null);
}

test "symbol listings name ambiguity only where it holds" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "d.js", .data = "function a() {\n  return 1;\n}\nfunction a() {\n  return 2;\n}\nfunction b() {\n  return 3;\n}\n" });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "d.js", testing.allocator);
    defer testing.allocator.free(path);
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var reply = try callTool(runtime, "emetgate_symbols", .{ .file = path });
    defer reply.deinit();
    var body = try reply.payload();
    defer body.deinit();
    const symbols = body.value.object.get("symbols").?.array.items;
    try testing.expectEqual(@as(usize, 3), symbols.len);
    try testing.expect(symbols[0].object.get("ambiguous").?.bool);
    try testing.expect(symbols[1].object.get("ambiguous").?.bool);
    try testing.expect(symbols[2].object.get("ambiguous") == null);
}

test "symbol listings of a large file are compact lines without hashes unless detail full" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var source: std.Io.Writer.Allocating = .init(testing.allocator);
    defer source.deinit();
    for (0..50) |i| try source.writer.print("function f{d}() {{\n  return {d};\n}}\n", .{ i, i });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "big.js", .data = source.written() });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "big.js", testing.allocator);
    defer testing.allocator.free(path);
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try callTool(runtime, "emetgate_symbols", .{ .file = path });
    defer reply.deinit();
    var body = try reply.payload();
    defer body.deinit();
    const lines = body.value.object.get("symbols").?.string;
    try testing.expectEqual(@as(usize, 50), std.mem.count(u8, lines, "\n"));
    try testing.expect(std.mem.startsWith(u8, lines, "1 function f0\n4 function f1\n"));
    try testing.expect(std.mem.indexOf(u8, reply.text, "\"hash\"") == null);

    var full = try callTool(runtime, "emetgate_symbols", .{ .file = path, .detail = "full" });
    defer full.deinit();
    var full_body = try full.payload();
    defer full_body.deinit();
    const symbols = full_body.value.object.get("symbols").?.array.items;
    try testing.expectEqual(@as(usize, 50), symbols.len);
    try testing.expect(symbols[0].object.get("hash") != null);
}

test "symbol listings over the read budget fold members under their class with a count and a within hint" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var source: std.Io.Writer.Allocating = .init(testing.allocator);
    defer source.deinit();
    for (0..30) |c| {
        try source.writer.print("class Container{d} {{\n", .{c});
        for (0..10) |m| try source.writer.print("  memberWithADescriptiveName{d}() {{ return {d}; }}\n", .{ m, m });
        try source.writer.writeAll("}\n");
    }
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "classes.js", .data = source.written() });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "classes.js", testing.allocator);
    defer testing.allocator.free(path);
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try callTool(runtime, "emetgate_symbols", .{ .file = path });
    defer reply.deinit();
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(reply.text.len < 8 * 1024);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expect(body.value.object.get("symbols") == null);
    try testing.expect(body.value.object.get("elided") == null);
    const outline = body.value.object.get("outline").?.string;
    try testing.expectEqual(@as(usize, 30), std.mem.count(u8, outline, "\n"));
    try testing.expect(std.mem.startsWith(u8, outline, "1 class Container0 +10\n13 class Container1 +10\n"));
    try testing.expect(std.mem.indexOf(u8, body.value.object.get("members").?.string, "within:") != null);

    var inner = try callTool(runtime, "emetgate_symbols", .{ .file = path, .within = "Container3" });
    defer inner.deinit();
    var inner_body = try inner.payload();
    defer inner_body.deinit();
    const listed = inner_body.value.object.get("symbols").?.array.items;
    try testing.expectEqual(@as(usize, 10), listed.len);
    for (listed) |entry| try testing.expect(std.mem.startsWith(u8, entry.object.get("ref").?.string, "Container3."));
    const declared = inner_body.value.object.get("declarations").?.array.items;
    try testing.expectEqual(@as(usize, 1), declared.len);
    try testing.expectEqualStrings("Container3", declared[0].object.get("ref").?.string);

    try expectToolError(runtime, "emetgate_symbols", .{ .file = path, .within = "Container99" }, "NoSymbolsWithin");
}

test "symbol listings whose outline still exceeds the read budget say how many names were left out and from which line" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var source: std.Io.Writer.Allocating = .init(testing.allocator);
    defer source.deinit();
    for (0..600) |i| try source.writer.print("function aFunctionWithAFairlyLongName{d}() {{ return {d}; }}\n", .{ i, i });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "many.js", .data = source.written() });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "many.js", testing.allocator);
    defer testing.allocator.free(path);
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try callTool(runtime, "emetgate_symbols", .{ .file = path });
    defer reply.deinit();
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(reply.text.len < 9 * 1024);
    var body = try reply.payload();
    defer body.deinit();
    const outline = body.value.object.get("outline").?.string;
    const shown = std.mem.count(u8, outline, "\n");
    try testing.expect(shown > 0 and shown < 600);
    const elided = body.value.object.get("elided").?.string;
    const expected = try std.fmt.allocPrint(testing.allocator, "{d} more names ({d} symbols) from line {d} on;", .{ 600 - shown, 600 - shown, shown + 1 });
    defer testing.allocator.free(expected);
    try testing.expect(std.mem.startsWith(u8, elided, expected));
}

test "with raw code on, read replies put a one-line JSON header before the code as plain text" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = "export function add(a: number): number {\n\treturn a + \"x\".length;\n}\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = source });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "a.ts", testing.allocator);
    defer testing.allocator.free(path);
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const policy: server.Policy = .{ .raw_code = true };

    var whole = try callToolServedPolicy(runtime, "emetgate_read_file", .{ .file = path }, policy);
    defer whole.deinit();
    const nl = std.mem.indexOfScalar(u8, whole.text, '\n').?;
    try testing.expectEqualStrings(source, whole.text[nl + 1 ..][0..source.len]);
    var header = try whole.payload();
    defer header.deinit();
    try testing.expect(header.value.object.get("content") == null);
    try testing.expect(header.value.object.get("file_hash") != null);

    var sym = try callToolServedPolicy(runtime, "emetgate_read_symbol", .{ .file = path, .symbol = "add" }, policy);
    defer sym.deinit();
    try testing.expect(std.mem.indexOf(u8, sym.text, "\treturn a + \"x\".length;\n") != null);
    try testing.expect(std.mem.indexOf(u8, sym.text[std.mem.indexOfScalar(u8, sym.text, '\n').?..], "\\n") == null);

    var skel = try callToolServedPolicy(runtime, "emetgate_skeleton", .{ .file = path }, policy);
    defer skel.deinit();
    try testing.expect(std.mem.indexOf(u8, skel.text, source) != null);
}

test "skeleton of a file over 8 KiB folds doc blocks and lists no declarations; a small file comes back whole and covers later reads" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var big: std.Io.Writer.Allocating = .init(testing.allocator);
    defer big.deinit();
    for (0..120) |i| try big.writer.print("/**\n * Doubles f{d}.\n * @param a the input\n * @returns twice a\n */\nexport function f{d}(a: number): number {{\n  return a * 2;\n}}\n", .{ i, i });
    try big.writer.writeAll("export const LIMIT = 3;\n");
    try testing.expect(big.written().len > outline_mod.threshold);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "big.ts", .data = big.written() });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "small.ts", .data = "export function one(): number {\n  return 1;\n}\n" });
    const root_abs = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root_abs);
    try commitAll(root_abs);
    const big_abs = try tmp.dir.realPathFileAlloc(testing.io, "big.ts", testing.allocator);
    defer testing.allocator.free(big_abs);
    const small_abs = try tmp.dir.realPathFileAlloc(testing.io, "small.ts", testing.allocator);
    defer testing.allocator.free(small_abs);
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var m: mirror_mod.Mirror = .init(testing.allocator, true);
    defer m.deinit();
    const policy: server.Policy = .{ .mirror = &m, .root = root_abs };

    var reply = try callToolServedPolicy(runtime, "emetgate_skeleton", .{ .file = big_abs }, policy);
    defer reply.deinit();
    var body = try reply.payload();
    defer body.deinit();
    const text = body.value.object.get("skeleton").?.string;
    try testing.expect(std.mem.indexOf(u8, text, "/** Doubles f7. */\nexport function f7(a: number): number;") != null);
    try testing.expect(std.mem.indexOf(u8, text, "@param") == null);
    try testing.expect(text.len < big.written().len / 2);
    try testing.expect(body.value.object.get("declarations") == null);
    try testing.expect(body.value.object.get("rules") == null);

    var small = try callToolServedPolicy(runtime, "emetgate_skeleton", .{ .file = small_abs }, policy);
    defer small.deinit();
    try testing.expect(std.mem.indexOf(u8, small.text, "return 1") != null);
    var after = try callToolServedPolicy(runtime, "emetgate_read_symbol", .{ .file = small_abs, .symbol = "one" }, policy);
    defer after.deinit();
    try testing.expectEqualStrings("unchanged", try statusOf(&after));
}

test "skeleton and read_symbol fold doc blocks to one line, name the original lines, and detail full keeps them" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = "/*\n * Copyright 2024 Acme\n * Licensed under MIT\n */\nexport function box(): number {\n  /**\n   * Opens the box. Carefully.\n   * @returns nothing\n   */\n  function open(): void {\n    return;\n  }\n  return 1;\n}\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "box.ts", .data = source });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "box.ts", testing.allocator);
    defer testing.allocator.free(path);
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    var skel = try callTool(runtime, "emetgate_skeleton", .{ .file = path });
    defer skel.deinit();
    var skel_body = try skel.payload();
    defer skel_body.deinit();
    try testing.expectEqualStrings("/* Copyright 2024 Acme */\nexport function box(): number {\n  /** Opens the box. */\n  function open(): void {\n    return;\n  }\n  return 1;\n}\n", skel_body.value.object.get("content").?.string);
    try testing.expectEqualStrings("folded lines 1-4,6-9; emetgate_read_file raw:true has them", skel_body.value.object.get("docs").?.string);

    var short = try callTool(runtime, "emetgate_read_symbol", .{ .file = path, .symbol = "box" });
    defer short.deinit();
    var short_body = try short.payload();
    defer short_body.deinit();
    try testing.expect(std.mem.indexOf(u8, short_body.value.object.get("body").?.string, "  /** Opens the box. */\n  function open(): void {") != null);
    try testing.expectEqualStrings("folded lines 6-9; detail:\"full\" has them", short_body.value.object.get("docs").?.string);

    var full = try callTool(runtime, "emetgate_read_symbol", .{ .file = path, .symbol = "box", .detail = "full" });
    defer full.deinit();
    var full_body = try full.payload();
    defer full_body.deinit();
    try testing.expect(std.mem.indexOf(u8, full_body.value.object.get("body").?.string, "@returns nothing") != null);
    try testing.expect(full_body.value.object.get("docs") == null);
    try testing.expectEqualStrings(short_body.value.object.get("hash").?.string, full_body.value.object.get("hash").?.string);
}

test "read_symbol folds a python docstring to its first sentence" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = "def area(r):\n    \"\"\"Return the area. Uses pi.\n\n    Args:\n        r: radius\n    \"\"\"\n    return 3.14 * r * r\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "geo.py", .data = source });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "geo.py", testing.allocator);
    defer testing.allocator.free(path);
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var reply = try callTool(runtime, "emetgate_read_symbol", .{ .file = path, .symbol = "area" });
    defer reply.deinit();
    var body = try reply.payload();
    defer body.deinit();
    try testing.expectEqualStrings("\"\"\"Return the area.\"\"\"\n    return 3.14 * r * r", body.value.object.get("body").?.string);
    try testing.expectEqualStrings("folded lines 2-6; detail:\"full\" has them", body.value.object.get("docs").?.string);
}

test "list includes untracked files that are not ignored and leaves ignored ones out" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "repo/src");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/a.ts", .data = "export const a = 1;\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.gitignore", .data = "secret.txt\n" });
    const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", testing.allocator);
    defer testing.allocator.free(root_abs);
    try commitAll(root_abs);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/new.ts", .data = "export const b = 2;\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/secret.txt", .data = "x\n" });

    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var reply = try callToolServed(runtime, root_abs, "emetgate_list", .{ .dir = root_abs });
    defer reply.deinit();
    errdefer std.debug.print("reply: {s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    const files = fileNames(body.value);
    try testing.expect(containsString(files, "a.ts"));
    try testing.expect(containsString(files, "src/new.ts"));
    try testing.expect(!containsString(files, "secret.txt"));
}
