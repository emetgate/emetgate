const std = @import("std");
const git_fixture = @import("git_fixture.zig");
const builtin = @import("builtin");
const server = @import("emetgate").server;
const read_tools = @import("emetgate").read_tools;
const mirror_mod = @import("emetgate").mirror;
const Runtime = @import("emetgate").runtime.Runtime;

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
    try testing.expect(!body.value.object.get("truncated").?.bool);
    try testing.expectEqual(@as(i64, @intCast(expected.len)), body.value.object.get("bytes").?.integer);
    try testing.expectEqualStrings(expected, body.value.object.get("content").?.string);
}

test "read_file refuses a source file of a registered language unless raw is set" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    try expectToolError(runtime, "emetgate_read_file", .{ .file = "tests/fixtures/functions.ts" }, "UseSymbolToolsForSource");

    const expected = try std.Io.Dir.cwd().readFileAlloc(testing.io, "tests/fixtures/functions.ts", testing.allocator, .unlimited);
    defer testing.allocator.free(expected);
    var reply = try callTool(runtime, "emetgate_read_file", .{ .file = "tests/fixtures/functions.ts", .raw = true });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expectEqualStrings(expected, body.value.object.get("content").?.string);
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
    var found_express = false;
    for (keys) |k| {
        if (std.mem.eql(u8, k.object.get("pointer").?.string, "/dependencies/express")) {
            try testing.expectEqualStrings("string", k.object.get("type").?.string);
            found_express = true;
        }
    }
    try testing.expect(found_express);

    var value_reply = try callTool(runtime, "emetgate_read_file", .{ .file = "tests/fixtures/sample.json", .pointer = "/dependencies/express" });
    defer value_reply.deinit();
    try testing.expect(!value_reply.is_error);
    var value_body = try value_reply.payload();
    defer value_body.deinit();
    try testing.expectEqualStrings("\"^4.0.0\"", value_body.value.object.get("value").?.string);
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

test "read_file caps a large file and says it was truncated" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const path = "src/platform/disk.zig";
    const whole = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .unlimited);
    defer testing.allocator.free(whole);
    try testing.expect(whole.len > 16 * 1024);

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
    try testing.expect(!body.value.object.get("truncated").?.bool);
}

test "search finds a literal in tracked files under a directory and refuses an empty pattern" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var reply = try callTool(runtime, "emetgate_search", .{ .pattern = "export function afterUnicode", .dir = "tests/fixtures" });
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

fn commitAll(root: []const u8) !void {
    try git_fixture.initRepo(root);
    try gitIn(root, &.{ "add", "." });
    try gitIn(root, &.{ "commit", "-q", "-m", "init" });
}

test "search reads a tracked file just under 1 MiB and skips one of 1 MiB" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const mib = 1024 * 1024;
    const under_cap = try testing.allocator.alloc(u8, mib - 1);
    defer testing.allocator.free(under_cap);
    @memset(under_cap, 'x');
    @memcpy(under_cap[0..7], "needle\n");
    const at_cap = try testing.allocator.alloc(u8, mib);
    defer testing.allocator.free(at_cap);
    @memset(at_cap, 'x');
    @memcpy(at_cap[0..7], "needle\n");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "under_cap.txt", .data = under_cap });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "at_cap.txt", .data = at_cap });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try commitAll(root);

    var result = try searchedFiles(root, .{});
    defer result.deinit();
    try testing.expect(matchedFile(result.value, "under_cap.txt"));
    try testing.expect(!matchedFile(result.value, "at_cap.txt"));
}

test "search skips a tracked binary file" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "text.txt", .data = "needle here\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "blob.bin", .data = "needle\x00binary\n" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try commitAll(root);

    var result = try searchedFiles(root, .{});
    defer result.deinit();
    try testing.expect(matchedFile(result.value, "text.txt"));
    try testing.expect(!matchedFile(result.value, "blob.bin"));
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
    const made = try std.process.run(testing.allocator, testing.io, .{ .argv = &.{ "cmd", "/c", "mklink", "/J", "alias", ".git" }, .cwd = .{ .path = root_abs } });
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
