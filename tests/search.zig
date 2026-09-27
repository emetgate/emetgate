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

    const index_path = try search_index.indexPath(testing.allocator, root);
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

    var reply = try search(runtime, root, "needleword");
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();
    try testing.expect(body.value.object.get("truncated").?.bool);
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

test "a resident index entry whose stored hash does not match the file's live bytes is never trusted for symbol grouping" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const real_bytes = "export function realFn() {\n  return 1;\n}\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = real_bytes });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try commitAll(root);
    const abs = try std.fmt.allocPrint(testing.allocator, "{s}\\a.ts", .{root});
    defer testing.allocator.free(abs);

    const real_stat = try std.Io.Dir.cwd().statFile(testing.io, abs, .{});
    const stamp: search_index.Stamp = .{ .mtime_ns = real_stat.mtime.nanoseconds, .size = real_stat.size };
    const trigrams = try search_index.trigramsOfAlloc(testing.allocator, real_bytes);
    defer testing.allocator.free(trigrams);

    const fake_arena = try testing.allocator.create(std.heap.ArenaAllocator);
    fake_arena.* = std.heap.ArenaAllocator.init(testing.allocator);

    var wrong_hash: symbol.Hash = std.mem.zeroes(symbol.Hash);
    wrong_hash[0] = 0xff;
    var fake_symbols = [_]search_index.kind_spans.SymbolSpan{.{
        .ref_text = "wrongName",
        .name = "wrongName",
        .hash = std.mem.zeroes(symbol.Hash),
        .node_start = 0,
        .body_start = 0,
        .node_end = @intCast(real_bytes.len),
    }};
    const fake_spans = search_index.kind_spans.FileSpans{
        .symbols = fake_symbols[0..],
        .kind_spans = &.{},
        .reference_spans = &.{},
    };
    var fake_entries = [_]search_index.Entry{.{
        .path = "a.ts",
        .stamp = stamp,
        .trigrams = trigrams,
        .content_hash = wrong_hash,
        .spans = fake_spans,
    }};
    var session = search_session.Session.init(testing.allocator, testing.io, root, .{});
    defer session.deinit();
    session.index = .{ .arena = fake_arena, .entries = fake_entries[0..], .written_ns = null };

    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try callToolServedPolicy(runtime, "emetgate_search", .{ .pattern = "realFn", .dir = root }, .{ .root = root, .search_session = &session });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();

    try testing.expect(findGroupBySymbol(groupsOf(body.value), "realFn") != null);
    try testing.expect(findGroupBySymbol(groupsOf(body.value), "wrongName") == null);
}

test "a hash-matching index entry with no persisted spans still classifies comments and definitions via a live parse" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const real_bytes = "export function loadPending(): number {\n  // loadPending starts here\n  return 1;\n}\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = real_bytes });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try commitAll(root);
    const abs = try std.fmt.allocPrint(testing.allocator, "{s}\\a.ts", .{root});
    defer testing.allocator.free(abs);

    const real_stat = try std.Io.Dir.cwd().statFile(testing.io, abs, .{});
    const stamp: search_index.Stamp = .{ .mtime_ns = real_stat.mtime.nanoseconds, .size = real_stat.size };
    const trigrams = try search_index.trigramsOfAlloc(testing.allocator, real_bytes);
    defer testing.allocator.free(trigrams);

    const fake_arena = try testing.allocator.create(std.heap.ArenaAllocator);
    fake_arena.* = std.heap.ArenaAllocator.init(testing.allocator);

    var fake_entries = [_]search_index.Entry{.{
        .path = "a.ts",
        .stamp = stamp,
        .trigrams = trigrams,
        .content_hash = symbol.fileHash(real_bytes),
        .spans = null,
    }};
    var session = search_session.Session.init(testing.allocator, testing.io, root, .{});
    defer session.deinit();
    session.index = .{ .arena = fake_arena, .entries = fake_entries[0..], .written_ns = null };

    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    var reply = try callToolServedPolicy(runtime, "emetgate_search", .{ .pattern = "loadPending", .dir = root }, .{ .root = root, .search_session = &session });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    var body = try reply.payload();
    defer body.deinit();

    const group = findGroupBySymbol(groupsOf(body.value), "loadPending") orelse return error.TestUnexpectedResult;
    var saw_definition = false;
    var saw_comment = false;
    for (hitKinds(group)) |h| {
        if (h.object.get("role")) |role| {
            if (std.mem.eql(u8, role.string, "definition")) saw_definition = true;
        }
        if (std.mem.eql(u8, h.object.get("kind").?.string, "comment")) saw_comment = true;
    }
    try testing.expect(saw_definition);
    try testing.expect(saw_comment);
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
