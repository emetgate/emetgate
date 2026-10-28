const std = @import("std");
const builtin = @import("builtin");
const git_fixture = @import("git_fixture.zig");
const server = @import("emetgate").server;
const handlers = @import("emetgate").handlers;
const find_tools = @import("emetgate").find_tools;
const map_tools = @import("emetgate").map_tools;
const fact_file = @import("emetgate").fact_file;
const Runtime = @import("emetgate").runtime.Runtime;

const testing = std.testing;
const gpa = testing.allocator;
const Value = std.json.Value;

const app_js = "export function total(a, b) {\n  return a + b;\n}\n";
const util_js = "export function total_of(xs) {\n  return xs.length;\n}\n";

fn git(root_abs: []const u8, args: []const []const u8) !void {
    var argv: [8][]const u8 = undefined;
    argv[0] = "git";
    @memcpy(argv[1..][0..args.len], args);
    const result = try @import("emetgate").bounded_run.run(gpa, testing.io, .{ .argv = argv[0 .. args.len + 1], .cwd = .{ .path = root_abs } });
    gpa.free(result.stdout);
    gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitSetupFailed,
        else => return error.GitSetupFailed,
    }
}

const Repo = struct {
    tmp: testing.TmpDir,
    root_abs: [:0]u8,
    runtime: *Runtime,
    session: *find_tools.Session,
    store_path: []u8,
    map: *map_tools.Session,

    fn init(watch: bool) !Repo {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo/src");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/app.js", .data = app_js });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/util.js", .data = util_js });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.gitignore", .data = ".emetgate/\n" });
        const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", gpa);
        errdefer gpa.free(root_abs);
        try git_fixture.initRepo(root_abs);
        try git(root_abs, &.{ "add", "." });
        try git(root_abs, &.{ "commit", "-q", "-m", "init" });
        const runtime = try Runtime.create(gpa);
        errdefer runtime.destroy() catch @panic("live snapshots");
        const session = try find_tools.Session.create(gpa, testing.io, root_abs);
        errdefer session.destroy();
        if (watch) session.start();
        try session.prepare(.build);
        const base = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
        defer gpa.free(base);
        const store_path = try std.fmt.allocPrint(gpa, "{s}\\store\\facts.v{d}", .{ base, fact_file.version });
        errdefer gpa.free(store_path);
        const map = try map_tools.Session.create(gpa, testing.io, runtime, root_abs);
        errdefer map.destroy();
        map.store_override = store_path;
        try map.build();
        return .{ .tmp = tmp, .root_abs = root_abs, .runtime = runtime, .session = session, .store_path = store_path, .map = map };
    }

    fn deinit(self: *Repo) void {
        self.map.destroy();
        gpa.free(self.store_path);
        self.session.destroy();
        if (find_tools.indexDir(gpa, self.root_abs)) |dir| {
            defer gpa.free(dir);
            std.Io.Dir.cwd().deleteTree(testing.io, dir) catch {};
        } else |_| {}
        self.runtime.destroy() catch @panic("live snapshots");
        gpa.free(self.root_abs);
        self.tmp.cleanup();
    }

    fn call(self: *Repo, tool: []const u8, args: anytype) !Reply {
        var line: std.Io.Writer.Allocating = .init(gpa);
        defer line.deinit();
        var js: std.json.Stringify = .{ .writer = &line.writer };
        try js.write(.{ .jsonrpc = "2.0", .id = 1, .method = "tools/call", .params = .{ .name = tool, .arguments = args } });
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        _ = try server.handleMessageObserved(gpa, testing.io, self.runtime, line.written(), &out.writer, null, .{ .root = self.root_abs, .test_command = "cmd /c exit 0", .find_session = self.session, .map_session = self.map });
        const parsed = try std.json.parseFromSlice(Value, gpa, out.written(), .{ .allocate = .alloc_always });
        errdefer parsed.deinit();
        const result = parsed.value.object.get("result") orelse return error.NotAToolResult;
        const content = result.object.get("content").?.array.items[0];
        return .{ .parsed = parsed, .is_error = result.object.get("isError").?.bool, .text = content.object.get("text").?.string };
    }

    fn expectFind(self: *Repo, pattern: []const u8, summary: []const u8) !void {
        var reply = try self.call("emetgate_find", .{ .pattern = pattern });
        defer reply.deinit();
        errdefer std.debug.print("find {s}: {s}\n", .{ pattern, reply.text });
        try testing.expect(!reply.is_error);
        try testing.expect(std.mem.startsWith(u8, reply.text, summary));
    }

    fn expectEvidence(self: *Repo, tool: []const u8, args: anytype, has: []const u8, lacks: []const u8) !void {
        var reply = try self.call(tool, args);
        defer reply.deinit();
        errdefer std.debug.print("{s}: {s}\n", .{ tool, reply.text });
        try testing.expect(!reply.is_error);
        try testing.expect(std.mem.indexOf(u8, reply.text, has) != null);
        try testing.expect(std.mem.indexOf(u8, reply.text, lacks) == null);
    }

    fn expectCommitted(self: *Repo, tool: []const u8, args: anytype) !void {
        var reply = try self.call(tool, args);
        defer reply.deinit();
        errdefer std.debug.print("{s}: {s}\n", .{ tool, reply.text });
        try testing.expect(!reply.is_error);
    }
};

const Reply = struct {
    parsed: std.json.Parsed(Value),
    is_error: bool,
    text: []const u8,

    fn deinit(self: *Reply) void {
        self.parsed.deinit();
    }
};

test "find after write: an index with no watcher sees a file written through emetgate_write on the very next find" {
    var repo = try Repo.init(false);
    defer repo.deinit();
    try repo.expectFind("total", "2 hits in 2 files");
    try repo.expectFind("grand_sum", "0 hits in 0 files");
    try repo.expectCommitted("emetgate_write", .{ .file = "src/app.js", .content = "export function grand_sum(a, b) {\n  return a + b;\n}\n" });
    try repo.expectFind("grand_sum", "1 hits in 1 files");
    try repo.expectFind("total", "1 hits in 1 files");
}

test "find after write: an index with no watcher sees every emetgate_edit across files on the very next find" {
    var repo = try Repo.init(false);
    defer repo.deinit();
    try repo.expectFind("total", "2 hits in 2 files");
    try repo.expectCommitted("emetgate_edit", .{ .file = "src/app.js", .old_string = "function total(", .new_string = "function grand_sum(" });
    try repo.expectFind("total", "1 hits in 1 files");
    try repo.expectCommitted("emetgate_edit", .{ .file = "src/util.js", .old_string = "function total_of(", .new_string = "function grand_sum_of(" });
    try repo.expectFind("total", "0 hits in 0 files");
    try repo.expectFind("grand_sum", "2 hits in 2 files");
}

test "find after write: a watched index returns fresh hits right after each write, 30 times in a row" {
    var repo = try Repo.init(true);
    defer repo.deinit();
    try repo.expectFind("total", "2 hits in 2 files");
    var content: [96]u8 = undefined;
    var token: [32]u8 = undefined;
    for (0..30) |i| {
        const tok = try std.fmt.bufPrint(&token, "fresh_token_{d}_", .{i});
        try repo.expectCommitted("emetgate_write", .{ .file = "src/app.js", .content = try std.fmt.bufPrint(&content, "export function {s}(a, b) {{\n  return a + b;\n}}\n", .{tok}) });
        errdefer std.debug.print("iteration {d}\n", .{i});
        try repo.expectFind(tok, "1 hits in 1 files");
        try repo.expectFind("fresh_token_", "1 hits in 1 files");
    }
}

test "find after write: evidence and explore know a function renamed through emetgate_edit on the very next call" {
    var repo = try Repo.init(false);
    defer repo.deinit();
    try repo.expectEvidence("emetgate_evidence", .{ .names = .{"grand_sum"} }, "No symbol named grand_sum", "function grand_sum(");
    try repo.expectCommitted("emetgate_edit", .{ .file = "src/app.js", .old_string = "function total(", .new_string = "function grand_sum(" });
    try repo.expectEvidence("emetgate_evidence", .{ .names = .{"grand_sum"} }, "function grand_sum(", "No symbol named grand_sum");
    try repo.expectCommitted("emetgate_edit", .{ .file = "src/util.js", .old_string = "function total_of(", .new_string = "function count_of(" });
    try repo.expectEvidence("emetgate_explore", .{ .question = "what does count_of return", .names = .{"count_of"} }, "function count_of(", "No symbol named count_of");
}

test "find after write: evidence and explore know a function renamed by an editor outside emetgate on the very next call" {
    var repo = try Repo.init(false);
    defer repo.deinit();
    try repo.expectEvidence("emetgate_evidence", .{ .names = .{"outside_sum"} }, "No symbol named outside_sum", "function outside_sum(");
    const builds = repo.map.names_builds;
    try repo.expectEvidence("emetgate_evidence", .{ .names = .{"total"} }, "function total(", "No symbol named total");
    try testing.expectEqual(builds, repo.map.names_builds);
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/app.js", .data = "export function outside_sum(a, b) {\n  return a + b;\n}\n" });
    try repo.expectEvidence("emetgate_evidence", .{ .names = .{"outside_sum"} }, "function outside_sum(", "No symbol named outside_sum");
    try testing.expectEqual(builds + 1, repo.map.names_builds);
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/util.js", .data = "export function outside_count(xs) {\n  return xs.length;\n}\n" });
    try repo.expectEvidence("emetgate_explore", .{ .question = "what does outside_count return", .names = .{"outside_count"} }, "function outside_count(", "No symbol named outside_count");
}

test "find after write: a read only tool leaves the find index alone and every other tool marks it stale" {
    for ([_][]const u8{ "emetgate_find", "emetgate_search", "emetgate_read_file", "emetgate_git", "emetgate_mutate" }) |name| try testing.expect(handlers.readOnly(name));
    for ([_][]const u8{ "emetgate_rename", "emetgate_try_batch", "emetgate_commit", "emetgate_write", "emetgate_edit", "emetgate_run", "emetgate_git_write", "emetgate_move_file", "emetgate_unknown" }) |name| try testing.expect(!handlers.readOnly(name));
}
