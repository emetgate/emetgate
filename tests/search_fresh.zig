const std = @import("std");
const builtin = @import("builtin");
const git_fixture = @import("git_fixture.zig");
const server = @import("emetgate").server;
const search_session = @import("emetgate").search_session;
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

    fn init(file_count: usize) !Repo {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo/src");
        var name: [64]u8 = undefined;
        for (0..file_count) |i| {
            const rel = try std.fmt.bufPrint(&name, "repo/src/f{d}.ts", .{i});
            try tmp.dir.writeFile(testing.io, .{ .sub_path = rel, .data = "export const seed = 0;\n" });
        }
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.gitignore", .data = ".emetgate/\n" });
        const root = try tmp.dir.realPathFileAlloc(testing.io, "repo", gpa);
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

    fn write(self: *Repo, index: usize, data: []const u8) !void {
        var name: [64]u8 = undefined;
        const rel = try std.fmt.bufPrint(&name, "repo/src/f{d}.ts", .{index});
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = rel, .data = data });
    }
};

const Found = struct {
    files: usize,
    reason: []const u8,
};

fn search(runtime: *Runtime, session: *search_session.Session, root: []const u8, pattern: []const u8, reason_buf: []u8) !Found {
    var line: std.Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    var js: std.json.Stringify = .{ .writer = &line.writer };
    try js.write(.{ .jsonrpc = "2.0", .id = 1, .method = "tools/call", .params = .{ .name = "emetgate_search", .arguments = .{ .pattern = pattern, .dir = root, .stats = true } } });
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try server.handleMessageObserved(gpa, testing.io, runtime, line.written(), &out.writer, null, .{ .root = root, .search_session = session });
    const parsed = try std.json.parseFromSlice(Value, gpa, out.written(), .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const result = parsed.value.object.get("result") orelse return error.NotAToolResult;
    if (result.object.get("isError").?.bool) return error.SearchFailed;
    const text = result.object.get("content").?.array.items[0].object.get("text").?.string;
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const body = try std.json.parseFromSlice(Value, gpa, text[0..end], .{});
    defer body.deinit();
    var files: std.StringHashMapUnmanaged(void) = .empty;
    defer files.deinit(gpa);
    for (body.value.object.get("groups").?.array.items) |g| try files.put(gpa, g.object.get("file").?.string, {});
    const reason = body.value.object.get("stats").?.object.get("refresh_reason").?.string;
    const n = @min(reason.len, reason_buf.len);
    @memcpy(reason_buf[0..n], reason[0..n]);
    return .{ .files = files.count(), .reason = reason_buf[0..n] };
}

test "search freshness: a tracked file written and searched with no pause is found, 200 times in a row" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init(5);
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    var session = search_session.Session.init(gpa, testing.io, repo.root, .{});
    defer session.deinit();
    var reason_buf: [64]u8 = undefined;
    _ = try search(runtime, &session, repo.root, "seed", &reason_buf);

    var data: [64]u8 = undefined;
    var token: [32]u8 = undefined;
    for (0..200) |i| {
        const tok = try std.fmt.bufPrint(&token, "fresh_token_{d}", .{i});
        try repo.write(i % 5, try std.fmt.bufPrint(&data, "export const {s} = 1;\n", .{tok}));
        const found = try search(runtime, &session, repo.root, tok, &reason_buf);
        errdefer std.debug.print("iteration {d}: {s} found in {d} files, refresh {s}\n", .{ i, tok, found.files, found.reason });
        try testing.expectEqual(@as(usize, 1), found.files);
    }
}

const Noise = struct {
    repo: *Repo,
    stop: std.atomic.Value(bool) = .init(false),
    written: std.atomic.Value(u32) = .init(0),

    fn run(self: *Noise) void {
        var i: usize = 0;
        while (!self.stop.load(.acquire)) : (i += 1) {
            self.repo.write(5 + i % 20, if (i % 2 == 0) "export const noise = 1;\n" else "export const noise = 22;\n") catch return;
            _ = self.written.fetchAdd(1, .release);
        }
    }
};

test "search freshness: every write is found while another thread keeps rewriting other tracked files" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init(25);
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    var session = search_session.Session.init(gpa, testing.io, repo.root, .{});
    defer session.deinit();
    var reason_buf: [64]u8 = undefined;
    _ = try search(runtime, &session, repo.root, "seed", &reason_buf);

    var noise: Noise = .{ .repo = &repo };
    const thread = try std.Thread.spawn(.{}, Noise.run, .{&noise});
    defer {
        noise.stop.store(true, .release);
        thread.join();
    }
    var data: [64]u8 = undefined;
    var token: [32]u8 = undefined;
    for (0..100) |i| {
        const tok = try std.fmt.bufPrint(&token, "busy_token_{d}", .{i});
        try repo.write(i % 5, try std.fmt.bufPrint(&data, "export const {s} = 1;\n", .{tok}));
        const found = try search(runtime, &session, repo.root, tok, &reason_buf);
        errdefer std.debug.print("iteration {d}: {s} found in {d} files, refresh {s}\n", .{ i, tok, found.files, found.reason });
        try testing.expectEqual(@as(usize, 1), found.files);
    }
    try testing.expect(noise.written.load(.acquire) > 0);
}

test "search freshness: a burst that overflows the watch buffer falls back to a full stat refresh and misses nothing" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init(150);
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    var session = search_session.Session.init(gpa, testing.io, repo.root, .{ .buffer_bytes = 1024 });
    defer session.deinit();
    var reason_buf: [64]u8 = undefined;
    _ = try search(runtime, &session, repo.root, "seed", &reason_buf);

    for (0..150) |i| try repo.write(i, "export const burst_token = 1;\n");
    const found = try search(runtime, &session, repo.root, "burst_token", &reason_buf);
    try testing.expectEqualStrings("overflow", found.reason);
    try testing.expectEqual(@as(usize, 150), found.files);
}

test "search freshness: a git add that changes the tracked set is picked up without waiting" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init(3);
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    var session = search_session.Session.init(gpa, testing.io, repo.root, .{});
    defer session.deinit();
    var reason_buf: [64]u8 = undefined;
    _ = try search(runtime, &session, repo.root, "seed", &reason_buf);

    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/added.ts", .data = "export const added_token = 1;\n" });
    try gitIn(repo.root, &.{ "add", "src/added.ts" });
    const found = try search(runtime, &session, repo.root, "added_token", &reason_buf);
    try testing.expectEqual(@as(usize, 1), found.files);
}
