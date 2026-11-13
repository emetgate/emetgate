//! Claims discipline: a reply says "complete", "everything" or "no match" only when it
//! checked everything. A match in a file too large for the search index is found or the
//! file is named as skipped; explore's closure counts what matched and what it showed;
//! a minified file is left out of the fact store instead of stalling explore.
const std = @import("std");
const emetgate = @import("emetgate");
const git_fixture = @import("git_fixture.zig");
const server = emetgate.server;
const map_tools = emetgate.map_tools;
const fact_file = emetgate.fact_file;
const search_index = emetgate.search_index;
const test_util = emetgate.test_util;
const Runtime = emetgate.runtime.Runtime;

const testing = std.testing;
const gpa = testing.allocator;

const File = struct { path: []const u8, data: []const u8 };

fn git(root: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, try git_fixture.git());
    try argv.appendSlice(gpa, args);
    const result = try emetgate.bounded_run.run(gpa, testing.io, .{ .argv = argv.items, .cwd = .{ .path = root } });
    gpa.free(result.stdout);
    gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitFailed,
        else => return error.GitFailed,
    }
}

const Repo = struct {
    tmp: testing.TmpDir,
    base: [:0]u8,
    root: []u8,

    fn init(files: []const File) !Repo {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo");
        for (files) |f| {
            const sub = try std.fmt.allocPrint(gpa, "repo/{s}", .{f.path});
            defer gpa.free(sub);
            if (std.fs.path.dirnamePosix(sub)) |d| try tmp.dir.createDirPath(testing.io, d);
            try tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = f.data });
        }
        const base = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
        errdefer gpa.free(base);
        const root = try std.fmt.allocPrint(gpa, "{s}\\repo", .{base});
        errdefer gpa.free(root);
        try git_fixture.initRepo(root);
        try git(root, &.{ "add", "." });
        return .{ .tmp = tmp, .base = base, .root = root };
    }

    fn deinit(self: *Repo) void {
        if (search_index.indexDir(gpa, self.root)) |dir| {
            std.Io.Dir.cwd().deleteTree(testing.io, dir) catch {};
            gpa.free(dir);
        } else |_| {}
        gpa.free(self.root);
        gpa.free(self.base);
        self.tmp.cleanup();
    }
};

/// The reply text of one emetgate_search call as the model sees it (text format).
fn searchText(runtime: *Runtime, root: []const u8, pattern: []const u8) ![]u8 {
    var line: std.Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    var js: std.json.Stringify = .{ .writer = &line.writer };
    try js.write(.{ .jsonrpc = "2.0", .id = 1, .method = "tools/call", .params = .{ .name = "emetgate_search", .arguments = .{ .pattern = pattern, .dir = root } } });
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try server.handleMessageObserved(gpa, testing.io, runtime, line.written(), &out.writer, null, .{ .root = root, .search_text = true, .search_internals = false });
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, out.written(), .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result") orelse return error.NotAToolResult;
    return gpa.dupe(u8, result.object.get("content").?.array.items[0].object.get("text").?.string);
}

fn expectHas(text: []const u8, part: []const u8) !void {
    if (std.mem.indexOf(u8, text, part) != null) return;
    std.debug.print("missing: {s}\n--- reply ---\n{s}\n", .{ part, text });
    return error.TestExpectedEqual;
}

fn expectLacks(text: []const u8, part: []const u8) !void {
    if (std.mem.indexOf(u8, text, part) == null) return;
    std.debug.print("unexpected: {s}\n--- reply ---\n{s}\n", .{ part, text });
    return error.TestExpectedEqual;
}

test "claims: a match in a tracked file over the index size limit is found, never reported as no match" {
    // A log of 17 MiB: over the 16 MiB the search index holds. The match is on its last line.
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(gpa);
    var lines: usize = 0;
    while (log.items.len <= search_index.max_indexed_file_bytes + 1024 * 1024) : (lines += 1) try log.print(gpa, "event id={d:0>8} ok padding\n", .{lines});
    try testing.expect(log.items.len > search_index.max_indexed_file_bytes);
    const last = try std.fmt.allocPrint(gpa, "id={d:0>8} ", .{lines - 1});
    defer gpa.free(last);

    var repo = try Repo.init(&.{
        .{ .path = "huge.log", .data = log.items },
        .{ .path = "src/app.ts", .data = "export function app() { return 1; }\n" },
    });
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    const found = try searchText(runtime, repo.root, last);
    defer gpa.free(found);
    try expectLacks(found, "no match");
    try expectHas(found, "huge.log");
    const line_no = try std.fmt.allocPrint(gpa, "\n{d}:event", .{lines});
    defer gpa.free(line_no);
    try expectHas(found, line_no);

    const absent = try searchText(runtime, repo.root, "id=99999999 ");
    defer gpa.free(absent);
    // Both files were read, so a complete "no match" is a true claim here.
    try expectHas(absent, "\u{2713} no match in 2 file(s)");
}

fn manyFunctions(arena: std.mem.Allocator, count: usize) ![]File {
    const files = try arena.alloc(File, count / 10);
    for (files, 0..) |*f, n| {
        var body: std.ArrayList(u8) = .empty;
        var k: usize = 0;
        while (k < 10) : (k += 1) {
            const id = n * 10 + k;
            try body.print(arena, "export function widgetPart{d}(input: number): number {{\n", .{id});
            try body.print(arena, "  const widgetValue = input * {d} + {d};\n  return widgetValue - {d};\n}}\n\n", .{ id, id + 1, id + 2 });
        }
        f.* = .{ .path = try std.fmt.allocPrint(arena, "src/widgets/part{d}.ts", .{n}), .data = body.items };
    }
    return files;
}

const Explored = struct {
    runtime: *Runtime,
    repo: Repo,
    store_path: []u8,
    session: *map_tools.Session,

    fn open(files: []const File) !Explored {
        const runtime = try test_util.openRuntime();
        errdefer test_util.closeRuntime(runtime);
        var repo = try Repo.init(files);
        errdefer repo.deinit();
        const store_path = try std.fmt.allocPrint(gpa, "{s}\\store\\facts.v{d}", .{ repo.base, fact_file.version });
        errdefer gpa.free(store_path);
        const session = try map_tools.Session.create(gpa, testing.io, runtime, repo.root);
        session.store_override = store_path;
        try session.build();
        return .{ .runtime = runtime, .repo = repo, .store_path = store_path, .session = session };
    }

    fn close(self: *Explored) void {
        self.session.destroy();
        gpa.free(self.store_path);
        self.repo.deinit();
        test_util.closeRuntime(self.runtime);
    }
};

/// The numbers of "The index matched M functions: W shown whole above, A by address, R not shown."
fn coverageOf(text: []const u8) ?[4]usize {
    const head = "The index matched ";
    const at = std.mem.indexOf(u8, text, head) orelse return null;
    var it = std.mem.tokenizeAny(u8, text[at + head.len ..], " :,.\n");
    var got: [4]usize = undefined;
    var n: usize = 0;
    while (it.next()) |word| {
        const v = std.fmt.parseInt(usize, word, 10) catch continue;
        got[n] = v;
        n += 1;
        if (n == 4) return got;
    }
    return null;
}

test "claims: explore that shows only part of what matched says how many matched and how many it showed, and never everything" {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const total = 1_500;
    var f = try Explored.open(try manyFunctions(arena, total));
    defer f.close();

    for ([_]map_tools.ExploreMode{ .full, .dense }) |mode| {
        f.session.explore_mode = mode;
        const text = try f.session.answer(arena, "how is the widget value computed", &.{});
        try expectLacks(text, "This is everything the index matched");
        try expectHas(text, map_tools.closure_partial_footer);
        const c = coverageOf(text) orelse {
            std.debug.print("--- reply ---\n{s}\n", .{text});
            return error.TestExpectedEqual;
        };
        try testing.expectEqual(@as(usize, total), c[0]);
        try testing.expectEqual(c[0], c[1] + c[2] + c[3]);
        try testing.expect(c[3] > 0);
    }
}

test "claims: explore that shows every matching function still says everything" {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var f = try Explored.open(&.{
        .{ .path = "src/rate.ts", .data = "export function rateLimit(n: number) {\n  return n > 10;\n}\n" },
        .{ .path = "src/other.ts", .data = "export function unrelated() {\n  return 0;\n}\n" },
    });
    defer f.close();
    const text = try f.session.answer(arena, "rate limit", &.{});
    try expectHas(text, "src/rate.ts:1 rateLimit\n");
    try expectHas(text, map_tools.closure_footer);
    try expectLacks(text, "The index matched ");
}

fn minifiedJs(arena: std.mem.Allocator, functions: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "!function(){");
    var i: usize = 0;
    while (i < functions) : (i += 1) try out.print(arena, "function q{d}(a){{return a+{d}}}", .{ i, i });
    try out.appendSlice(arena, "}();\n");
    return out.items;
}

test "claims: a minified file does not stall explore or evidence, and explore names it as skipped" {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const min_js = try minifiedJs(arena, 15_000);
    try testing.expect(min_js.len > 300 * 1000);

    const start = std.Io.Timestamp.now(testing.io, .awake);
    var f = try Explored.open(&.{
        .{ .path = "web/min.js", .data = min_js },
        .{ .path = "src/app.ts", .data = "export function startApp(port: number) {\n  return port + 1;\n}\n" },
    });
    defer f.close();
    const first = try f.session.answer(arena, "how does q14999 compute its value", &.{"q14999"});
    const ev_args = try std.json.parseFromSlice(std.json.Value, gpa, "{\"names\":[\"q14999\",\"startApp\"]}", .{});
    defer ev_args.deinit();
    const ev = try f.session.evidenceTool(gpa, ev_args.value);
    defer gpa.free(ev.text);
    const second = try f.session.answer(arena, "how does the app start", &.{"startApp"});
    const spent_ms = start.durationTo(std.Io.Timestamp.now(testing.io, .awake)).toMilliseconds();
    std.debug.print("claims: minified fixture build + 2 explore + 1 evidence: {d} ms\n", .{spent_ms});

    // Generous bound: before the fix the first explore alone took minutes.
    try testing.expect(spent_ms < 30_000);
    try expectHas(first, "web/min.js");
    try expectHas(first, map_tools.minified_note);
    try expectHas(ev.text, "web/min.js");
    try expectHas(second, "src/app.ts:1 startApp\n");
}
