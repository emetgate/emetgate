const std = @import("std");
const git_fixture = @import("git_fixture.zig");
const server = @import("emetgate").server;
const tree_cache_mod = @import("emetgate").tree_cache;
const search_index = @import("emetgate").search_index;
const search_session = @import("emetgate").search_session;
const symbol = @import("emetgate").symbol;
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
        return std.json.parseFromSlice(Value, testing.allocator, self.text, .{});
    }
};

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

fn commitAll(root: []const u8) !void {
    try git_fixture.initRepo(root);
    try gitIn(root, &.{ "add", "." });
    try gitIn(root, &.{ "commit", "-q", "-m", "init" });
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

fn search(runtime: *Runtime, root: []const u8, pattern: []const u8) !Reply {
    return callToolServedPolicy(runtime, "emetgate_search", .{ .pattern = pattern, .dir = root }, .{ .root = root });
}

fn searchRegex(runtime: *Runtime, root: []const u8, pattern: []const u8) !Reply {
    return callToolServedPolicy(runtime, "emetgate_search", .{ .pattern = pattern, .dir = root, .regex = true }, .{ .root = root });
}

fn searchKinds(runtime: *Runtime, root: []const u8, pattern: []const u8, kinds: []const []const u8) !Reply {
    return callToolServedPolicy(runtime, "emetgate_search", .{ .pattern = pattern, .dir = root, .kinds = kinds }, .{ .root = root });
}

fn groupsOf(parsed: Value) []const Value {
    return parsed.object.get("groups").?.array.items;
}

fn findGroupBySymbol(groups: []const Value, name: []const u8) ?Value {
    for (groups) |g| {
        const sym = g.object.get("symbol") orelse continue;
        if (std.mem.eql(u8, sym.string, name)) return g;
    }
    return null;
}

fn hitKinds(group: Value) []const Value {
    return group.object.get("hits").?.array.items;
}

test "a hit inside a function is grouped by its enclosing symbol with a hash and a definition role" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export function loadPending(): number {\n  // loadPending starts here\n  return 1;\n}\n" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try commitAll(root);

    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try search(runtime, root, "loadPending");
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();

    const group = findGroupBySymbol(groupsOf(body.value), "loadPending") orelse return error.TestUnexpectedResult;
    try testing.expect(group.object.get("hash") != null);
    const hits = hitKinds(group);
    try testing.expectEqual(@as(usize, 2), hits.len);

    var saw_definition = false;
    var saw_comment = false;
    for (hits) |h| {
        if (h.object.get("role")) |role| {
            if (std.mem.eql(u8, role.string, "definition")) saw_definition = true;
        }
        if (std.mem.eql(u8, h.object.get("kind").?.string, "comment")) saw_comment = true;
    }
    try testing.expect(saw_definition);
    try testing.expect(saw_comment);
}

test "a hit inside a string literal is tagged string, not code" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export const msg = \"needleword\";\nexport function needleword() {\n  return 1;\n}\n" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try commitAll(root);

    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try search(runtime, root, "needleword");
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();

    var saw_string = false;
    var saw_code = false;
    for (groupsOf(body.value)) |g| {
        for (hitKinds(g)) |h| {
            const kind = h.object.get("kind").?.string;
            if (std.mem.eql(u8, kind, "string")) saw_string = true;
            if (std.mem.eql(u8, kind, "code")) saw_code = true;
        }
    }
    try testing.expect(saw_string);
    try testing.expect(saw_code);
}

test "kinds filter keeps only the requested classification" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export const msg = \"needleword\";\nexport function needleword() {\n  return 1;\n}\n" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try commitAll(root);

    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try searchKinds(runtime, root, "needleword", &.{"code"});
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();

    for (groupsOf(body.value)) |g| {
        for (hitKinds(g)) |h| {
            try testing.expectEqualStrings("code", h.object.get("kind").?.string);
        }
    }
}

test "a hit in a JSON file is grouped by its JSON pointer" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "pkg.json", .data = "{\n  \"dependencies\": {\n    \"express\": \"^4.0.0-needle\"\n  }\n}\n" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try commitAll(root);

    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try search(runtime, root, "needle");
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();

    var found = false;
    for (groupsOf(body.value)) |g| {
        const pointer = g.object.get("pointer") orelse continue;
        if (std.mem.eql(u8, pointer.string, "/dependencies/express")) found = true;
    }
    try testing.expect(found);
}

test "a hit in a Markdown file is grouped by its heading" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "README.md", .data = "# Title\n\n## Install\n\nrun the needleword command\n" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try commitAll(root);

    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try search(runtime, root, "needleword");
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();

    var found = false;
    for (groupsOf(body.value)) |g| {
        const heading = g.object.get("heading") orelse continue;
        if (std.mem.eql(u8, heading.string, "Install")) found = true;
    }
    try testing.expect(found);
}

test "a stale index does not hide a match added to a file after the index was built" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "hello world\n" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try commitAll(root);

    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    var first = try search(runtime, root, "zzzstale");
    defer first.deinit();
    try testing.expect(!first.is_error);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "hello world\nzzzstale marker\n" });

    var second = try search(runtime, root, "zzzstale");
    defer second.deinit();
    try testing.expect(!second.is_error);
    var body = try second.payload();
    defer body.deinit();
    try testing.expect(groupsOf(body.value).len >= 1);
}

test "a corrupted on-disk index still returns correct results, not a false empty" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "needlepattern here\n" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try commitAll(root);

    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    var warm = try search(runtime, root, "needlepattern");
    defer warm.deinit();
    try testing.expect(!warm.is_error);

    const index_dir = try search_index.indexDir(testing.allocator, root);
    defer testing.allocator.free(index_dir);
    const pointer = try std.fmt.allocPrint(testing.allocator, "{s}\\index.v4", .{index_dir});
    defer testing.allocator.free(pointer);
    var tag: [16]u8 = undefined;
    const generation = try std.Io.Dir.cwd().readFile(testing.io, pointer, &tag);
    const index_path = try std.fmt.allocPrint(testing.allocator, "{s}\\index.v4.{s}", .{ index_dir, generation });
    defer testing.allocator.free(index_path);
    const original = std.Io.Dir.cwd().readFileAlloc(testing.io, index_path, testing.allocator, .unlimited) catch return error.TestUnexpectedResult;
    defer testing.allocator.free(original);
    if (original.len > 20) {
        const tampered = try testing.allocator.dupe(u8, original);
        defer testing.allocator.free(tampered);
        tampered[tampered.len / 2] = tampered[tampered.len / 2] +% 1;
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = index_path, .data = tampered });
    }

    var reply = try search(runtime, root, "needlepattern");
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expect(groupsOf(body.value).len >= 1);
}

test "search never returns a hit from inside .git" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "needleword\n" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try commitAll(root);

    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try search(runtime, root, "needleword");
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    try testing.expect(std.mem.indexOf(u8, reply.text, ".git") == null);
}

test "the total hit count is capped and truncated is reported" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var lines: std.ArrayList(u8) = .empty;
    defer lines.deinit(testing.allocator);
    var i: usize = 0;
    while (i < 250) : (i += 1) try lines.print(testing.allocator, "needleword {d}\n", .{i});
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "many.txt", .data = lines.items });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try commitAll(root);

    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try callToolServedPolicy(runtime, "emetgate_search", .{ .pattern = "needleword", .dir = root, .detail = "full" }, .{ .root = root });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expect(body.value.object.get("truncated").?.bool);
    var hits: usize = 0;
    for (groupsOf(body.value)) |g| hits += g.object.get("hits").?.array.items.len;
    try testing.expectEqual(@as(usize, 200), hits);
}

test "regex mode matches a pattern that has no literal three-byte run" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "code 1\ncode 22\ncode 333\n" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try commitAll(root);

    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try searchRegex(runtime, root, "code [0-9][0-9][0-9]");
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();

    var found_333 = false;
    for (groupsOf(body.value)) |g| {
        for (hitKinds(g)) |h| {
            if (std.mem.indexOf(u8, h.object.get("text").?.string, "333") != null) found_333 = true;
        }
    }
    try testing.expect(found_333);
}

test "a group with a definition hit is listed before a group with only references" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "a.ts",
        .data = "export function helperNeedle() {\n  return 1;\n}\nexport function caller() {\n  return helperNeedle();\n}\n",
    });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try commitAll(root);

    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try search(runtime, root, "helperNeedle");
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();

    const groups = groupsOf(body.value);
    try testing.expect(groups.len >= 1);
    var definition_index: ?usize = null;
    for (groups, 0..) |g, idx| {
        for (hitKinds(g)) |h| {
            if (h.object.get("role")) |role| {
                if (std.mem.eql(u8, role.string, "definition")) definition_index = idx;
            }
        }
    }
    try testing.expectEqual(@as(?usize, 0), definition_index);
}

test "a search scoped to a subdirectory does not return hits from outside it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "inside");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "inside/a.txt", .data = "scopedneedle\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "outside.txt", .data = "scopedneedle\n" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try commitAll(root);
    const inside_abs = try tmp.dir.realPathFileAlloc(testing.io, "inside", testing.allocator);
    defer testing.allocator.free(inside_abs);

    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try callToolServedPolicy(runtime, "emetgate_search", .{ .pattern = "scopedneedle", .dir = inside_abs }, .{ .root = root });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();

    for (groupsOf(body.value)) |g| {
        try testing.expect(!std.mem.eql(u8, g.object.get("file").?.string, "outside.txt"));
    }
    try testing.expect(groupsOf(body.value).len >= 1);
}

const win = std.os.windows;

const BasicInfo = extern struct {
    creation: i64,
    access: i64,
    write: i64,
    change: i64,
    attributes: u32,
};

const file_basic_info: c_int = 0;
const filetime_unix_offset: i64 = 116444736000000000;

extern "kernel32" fn GetFileInformationByHandleEx(file: win.HANDLE, class: c_int, info: *anyopaque, size: win.DWORD) callconv(.winapi) win.BOOL;
extern "kernel32" fn SetFileInformationByHandle(file: win.HANDLE, class: c_int, info: *anyopaque, size: win.DWORD) callconv(.winapi) win.BOOL;

fn readTimes(dir: std.Io.Dir, sub_path: []const u8) !BasicInfo {
    const file = try dir.openFile(testing.io, sub_path, .{});
    defer file.close(testing.io);
    var info: BasicInfo = undefined;
    if (GetFileInformationByHandleEx(file.handle, file_basic_info, &info, @sizeOf(BasicInfo)) == .FALSE) return error.Unexpected;
    return info;
}

fn writeTimes(dir: std.Io.Dir, sub_path: []const u8, write: i64, change: i64) !void {
    return writeAllTimes(dir, sub_path, 0, write, change);
}

fn writeAllTimes(dir: std.Io.Dir, sub_path: []const u8, creation: i64, write: i64, change: i64) !void {
    const file = try dir.openFile(testing.io, sub_path, .{ .mode = .read_write });
    defer file.close(testing.io);
    var info: BasicInfo = .{ .creation = creation, .access = 0, .write = write, .change = change, .attributes = 0 };
    if (SetFileInformationByHandle(file.handle, file_basic_info, &info, @sizeOf(BasicInfo)) == .FALSE) return error.Unexpected;
}

fn filetimeAgo(seconds: i64) i64 {
    const now_ns: i64 = @intCast(std.Io.Clock.real.now(testing.io).nanoseconds);
    return @divTrunc(now_ns, 100) + filetime_unix_offset - seconds * 10_000_000;
}

fn dropIndex(root: []const u8) void {
    const dir = search_index.indexDir(testing.allocator, root) catch return;
    defer testing.allocator.free(dir);
    std.Io.Dir.cwd().deleteTree(testing.io, dir) catch {};
}

fn searchIn(runtime: *Runtime, session: *search_session.Session, root: []const u8, pattern: []const u8) !Reply {
    return callToolServedPolicy(runtime, "emetgate_search", .{ .pattern = pattern, .dir = root }, .{ .root = root, .search_session = session });
}

test "a file rewritten with its old size and last-write time while no session runs is read again because its change time moved" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export function wrongName() {\n  return 1;\n}\n" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    defer dropIndex(root);
    try commitAll(root);
    const old = filetimeAgo(3600);
    try writeTimes(tmp.dir, "a.ts", old, old);
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    {
        var first = search_session.Session.init(testing.allocator, testing.io, root, .{});
        defer first.deinit();
        var reply = try searchIn(runtime, &first, root, "wrongName");
        defer reply.deinit();
        var body = try reply.payload();
        defer body.deinit();
        try testing.expect(findGroupBySymbol(groupsOf(body.value), "wrongName") != null);
    }
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export function realFn___() {\n  return 1;\n}\n" });
    try writeTimes(tmp.dir, "a.ts", old, 0);
    const times = try readTimes(tmp.dir, "a.ts");
    try testing.expectEqual(old, times.write);
    try testing.expect(times.change != old);

    var second = search_session.Session.init(testing.allocator, testing.io, root, .{});
    defer second.deinit();
    var reply = try searchIn(runtime, &second, root, "realFn___");
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expect(findGroupBySymbol(groupsOf(body.value), "realFn___") != null);
    var stale = try searchIn(runtime, &second, root, "wrongName");
    defer stale.deinit();
    var stale_body = try stale.payload();
    defer stale_body.deinit();
    try testing.expectEqual(@as(usize, 0), groupsOf(stale_body.value).len);
}

test "a file rewritten inside the racy window with its old size and both of its old times is read again by the next session" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "firstText\n" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    defer dropIndex(root);
    try commitAll(root);
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "firstText\n" });
    {
        var first = search_session.Session.init(testing.allocator, testing.io, root, .{});
        defer first.deinit();
        var reply = try searchIn(runtime, &first, root, "firstText");
        defer reply.deinit();
        var body = try reply.payload();
        defer body.deinit();
        try testing.expectEqual(@as(usize, 1), groupsOf(body.value).len);
    }
    const before = try readTimes(tmp.dir, "a.txt");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "otherText\n" });
    try writeTimes(tmp.dir, "a.txt", before.write, before.change);
    const after = try readTimes(tmp.dir, "a.txt");
    try testing.expectEqual(before.write, after.write);
    try testing.expectEqual(before.change, after.change);

    var second = search_session.Session.init(testing.allocator, testing.io, root, .{});
    defer second.deinit();
    var reply = try searchIn(runtime, &second, root, "otherText");
    defer reply.deinit();
    var body = try reply.payload();
    defer body.deinit();
    try testing.expectEqual(@as(usize, 1), groupsOf(body.value).len);
}

test "a file rewritten with its old size and change time but a new last-write time is read again by the next session" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export function wrongName() {\n  return 1;\n}\n" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    defer dropIndex(root);
    try commitAll(root);
    const old = filetimeAgo(3600);
    try writeAllTimes(tmp.dir, "a.ts", old, old, old);
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    {
        var first = search_session.Session.init(testing.allocator, testing.io, root, .{});
        defer first.deinit();
        var reply = try searchIn(runtime, &first, root, "wrongName");
        defer reply.deinit();
        var body = try reply.payload();
        defer body.deinit();
        try testing.expect(findGroupBySymbol(groupsOf(body.value), "wrongName") != null);
    }
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export function realFn___() {\n  return 1;\n}\n" });
    const newer = filetimeAgo(1800);
    try writeAllTimes(tmp.dir, "a.ts", old, newer, old);
    const times = try readTimes(tmp.dir, "a.ts");
    try testing.expectEqual(newer, times.write);
    try testing.expectEqual(old, times.change);

    var second = search_session.Session.init(testing.allocator, testing.io, root, .{});
    defer second.deinit();
    var reply = try searchIn(runtime, &second, root, "realFn___");
    defer reply.deinit();
    var body = try reply.payload();
    defer body.deinit();
    try testing.expect(findGroupBySymbol(groupsOf(body.value), "realFn___") != null);
}

test "a regex sees the line of a CRLF file without its carriage return, as rg --crlf does" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "crlf.txt", .data = "alpha end\r\nbeta gamma\r\n" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    defer dropIndex(root);
    try commitAll(root);
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    const Case = struct { pattern: []const u8, hits: usize };
    for ([_]Case{ .{ .pattern = "end$", .hits = 1 }, .{ .pattern = "^[a-z ]+$", .hits = 2 }, .{ .pattern = "[^a-z ]", .hits = 0 } }) |case| {
        var reply = try searchRegex(runtime, root, case.pattern);
        defer reply.deinit();
        errdefer std.debug.print("{s}: {s}\n", .{ case.pattern, reply.text });
        try testing.expect(!reply.is_error);
        var body = try reply.payload();
        defer body.deinit();
        var hits: usize = 0;
        for (groupsOf(body.value)) |g| hits += g.object.get("hits").?.array.items.len;
        try testing.expectEqual(case.hits, hits);
    }
}

fn searchReason(runtime: *Runtime, session: *search_session.Session, root: []const u8, pattern: []const u8, reason: []u8) !struct { files: usize, reason: []const u8 } {
    var reply = try callToolServedPolicy(runtime, "emetgate_search", .{ .pattern = pattern, .dir = root, .stats = true, .detail = "full" }, .{ .root = root, .search_session = session });
    defer reply.deinit();
    var body = try reply.payload();
    defer body.deinit();
    const why = body.value.object.get("stats").?.object.get("refresh_reason").?.string;
    const n = @min(why.len, reason.len);
    @memcpy(reason[0..n], why[0..n]);
    return .{ .files = groupsOf(body.value).len, .reason = reason[0..n] };
}

test "a full refresh re-reads a file the running session read inside the racy window, though it was rewritten with its old size and both of its old times" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    for (0..150) |i| {
        var name: [32]u8 = undefined;
        try tmp.dir.writeFile(testing.io, .{ .sub_path = try std.fmt.bufPrint(&name, "f{d}.txt", .{i}), .data = "seed\n" });
    }
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "zeroText\n" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    defer dropIndex(root);
    try commitAll(root);
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var session = search_session.Session.init(testing.allocator, testing.io, root, .{ .buffer_bytes = 1024 });
    defer session.deinit();
    var reason: [64]u8 = undefined;
    _ = try searchReason(runtime, &session, root, "seed", &reason);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "firstText\n" });
    const first = try searchReason(runtime, &session, root, "firstText", &reason);
    try testing.expectEqual(@as(usize, 1), first.files);

    const before = try readTimes(tmp.dir, "a.txt");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "otherText\n" });
    try writeTimes(tmp.dir, "a.txt", before.write, before.change);
    for (0..150) |i| {
        var name: [32]u8 = undefined;
        try tmp.dir.writeFile(testing.io, .{ .sub_path = try std.fmt.bufPrint(&name, "f{d}.txt", .{i}), .data = "burst\n" });
    }
    const after = try readTimes(tmp.dir, "a.txt");
    try testing.expectEqual(before.write, after.write);
    try testing.expectEqual(before.change, after.change);
    const found = try searchReason(runtime, &session, root, "otherText", &reason);
    try testing.expectEqualStrings("overflow", found.reason);
    try testing.expectEqual(@as(usize, 1), found.files);
}

test "a file read within three seconds of its last change keeps a smudged stamp and an older file keeps its real stamp" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "old.txt", .data = "old\n" });
    const old = filetimeAgo(3600);
    try writeTimes(tmp.dir, "old.txt", old, old);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "fresh.txt", .data = "fresh\n" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const paths = [_][]const u8{ "fresh.txt", "old.txt" };
    const seen = [_]?search_index.Seen{ null, null };
    const prepared = try search_index.prepareAll(testing.allocator, testing.io, root, &paths, &seen, false, true, null, null);
    defer search_index.freeAll(testing.allocator, prepared);
    try testing.expectEqual(search_index.smudged_mtime_ns, prepared[0].stamp.mtime_ns);
    try testing.expect(prepared[1].stamp.mtime_ns != search_index.smudged_mtime_ns);
    try testing.expectEqual(@as(u64, 4), prepared[1].stamp.size);
}
test "a file that did not parse cleanly is searched through a live parse, and a kinds filter on it makes the answer partial as unclassified" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const real_bytes = "export function loadPending(): number {\n  // loadPending starts here\n  return 1;\n}\nconst broken = (;\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = real_bytes });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try commitAll(root);

    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var session = search_session.Session.init(testing.allocator, testing.io, root, .{});
    defer session.deinit();

    var reply = try searchIn(runtime, &session, root, "loadPending");
    defer reply.deinit();
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expectEqualStrings("complete", body.value.object.get("status").?.string);
    var saw_comment = false;
    for (groupsOf(body.value)) |g| {
        for (hitKinds(g)) |h| {
            if (std.mem.eql(u8, h.object.get("kind").?.string, "comment")) saw_comment = true;
        }
    }
    try testing.expect(saw_comment);

    var filtered = try callToolServedPolicy(runtime, "emetgate_search", .{ .pattern = "loadPending", .dir = root, .kinds = &[_][]const u8{"code"} }, .{ .root = root, .search_session = &session });
    defer filtered.deinit();
    errdefer std.debug.print("{s}\n", .{filtered.text});
    var filtered_body = try filtered.payload();
    defer filtered_body.deinit();
    try testing.expectEqualStrings("partial", filtered_body.value.object.get("status").?.string);
    const missing = filtered_body.value.object.get("missing").?.array.items;
    try testing.expectEqualStrings("unclassified", missing[0].object.get("reason").?.string);
}

test "a symbol's byte offsets are recomputed, not reused stale, after the file grows by a leading comment" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export function foo() {\n  return 1;\n}\n" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try commitAll(root);

    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    {
        var reply = try search(runtime, root, "foo");
        defer reply.deinit();
        var body = try reply.payload();
        defer body.deinit();
        try testing.expect(findGroupBySymbol(groupsOf(body.value), "foo") != null);
    }

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "// a leading comment that shifts every later byte offset\nexport function foo() {\n  return 1;\n}\n" });
    try gitIn(root, &.{ "add", "." });
    try gitIn(root, &.{ "commit", "-q", "-m", "shift" });

    var reply = try search(runtime, root, "foo");
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();

    const group = findGroupBySymbol(groupsOf(body.value), "foo") orelse return error.TestUnexpectedResult;
    var saw_definition = false;
    for (hitKinds(group)) |h| {
        if (h.object.get("role")) |role| {
            if (std.mem.eql(u8, role.string, "definition")) saw_definition = true;
        }
    }
    try testing.expect(saw_definition);
}

test "a regex whose literal parts are optional or alternatives still finds every file that matches" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "only_bar.ts", .data = "export const a = \"bar\";\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "only_foo.ts", .data = "export const b = \"foo\";\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "us.ts", .data = "export const c = \"color\";\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "uk.ts", .data = "export const d = \"colour\";\n" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try commitAll(root);

    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    const Case = struct { pattern: []const u8, files: usize };
    for ([_]Case{ .{ .pattern = "foo|bar", .files = 2 }, .{ .pattern = "(foo|bar)", .files = 2 }, .{ .pattern = "colou?r", .files = 2 } }) |case| {
        var reply = try searchRegex(runtime, root, case.pattern);
        defer reply.deinit();
        try testing.expect(!reply.is_error);
        var body = try reply.payload();
        defer body.deinit();
        errdefer std.debug.print("{s}: {s}\n", .{ case.pattern, reply.text });
        try testing.expectEqual(case.files, groupsOf(body.value).len);
    }
}
