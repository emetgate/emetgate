const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");
const git_fixture = @import("git_fixture.zig");

const server = emetgate.server;
const workspace = emetgate.workspace;
const memory = emetgate.memory;
const checks = emetgate.checks;
const test_util = emetgate.test_util;
const bounded_run = emetgate.bounded_run;
const Runtime = emetgate.runtime.Runtime;
const Policy = server.Policy;

const testing = std.testing;
const gpa = testing.allocator;

const Reply = struct { text: []const u8, is_error: bool };

fn git(cwd: []const u8, args: []const []const u8) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "git");
    try argv.appendSlice(gpa, args);
    const result = try bounded_run.run(gpa, testing.io, .{ .argv = argv.items, .cwd = .{ .path = cwd } });
    defer gpa.free(result.stderr);
    errdefer gpa.free(result.stdout);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitFailed,
        else => return error.GitFailed,
    }
    return result.stdout;
}

fn gitQuiet(cwd: []const u8, args: []const []const u8) !void {
    gpa.free(try git(cwd, args));
}

fn commitAll(cwd: []const u8) !void {
    try gitQuiet(cwd, &.{ "add", "-A" });
    try gitQuiet(cwd, &.{ "commit", "-qm", "base" });
}

const Fixture = struct {
    tmp: testing.TmpDir,
    arena_state: std.heap.ArenaAllocator,
    runtime: *Runtime,
    top: []const u8,
    session: []const u8,
    mobil: []const u8,
    backend: []const u8,
    served: server.Served = undefined,
    repositories: workspace.Workspace = undefined,
    open: bool = false,

    fn init(self: *Fixture) !void {
        self.* = .{
            .tmp = testing.tmpDir(.{}),
            .arena_state = .init(gpa),
            .runtime = try test_util.openRuntime(),
            .top = "",
            .session = "",
            .mobil = "",
            .backend = "",
        };
        const a = self.arena_state.allocator();
        const dir = self.tmp.dir;
        const io = testing.io;
        try dir.createDirPath(io, "top/app/mobil/src");
        try dir.createDirPath(io, "top/app/backend/src");
        const base = try dir.realPathFileAlloc(io, ".", a);
        self.top = try std.fmt.allocPrint(a, "{s}\\top", .{base});
        self.session = try std.fmt.allocPrint(a, "{s}\\app", .{self.top});
        self.mobil = try std.fmt.allocPrint(a, "{s}\\mobil", .{self.session});
        self.backend = try std.fmt.allocPrint(a, "{s}\\backend", .{self.session});
        try dir.writeFile(io, .{ .sub_path = "top/top.txt", .data = "top\n" });
        try dir.writeFile(io, .{ .sub_path = "top/app/.gitignore", .data = "mobil/\nbackend/\n" });
        try git_fixture.initRepo(self.top);
        try commitAll(self.top);
        for ([_][]const u8{ self.mobil, self.backend }, [_][]const u8{ "top/app/mobil", "top/app/backend" }) |repo_abs, rel| {
            const source = try std.fmt.allocPrint(a, "{s}/src/main.js", .{rel});
            try dir.writeFile(io, .{ .sub_path = source, .data = "function hello(n) {\n  return n + 1;\n}\nmodule.exports = { hello };\n" });
            const kept = try std.fmt.allocPrint(a, "{s}/kept.txt", .{rel});
            try dir.writeFile(io, .{ .sub_path = kept, .data = "kept\n" });
            try git_fixture.initRepo(repo_abs);
            try commitAll(repo_abs);
        }
    }

    fn serve(self: *Fixture, given: Policy) !void {
        var policy = given;
        policy.test_command = "cmd /c exit 0";
        const final_top = try self.arena_state.allocator().dupe(u8, self.top);
        self.served.open(gpa, testing.io, self.runtime, policy, .{ .root = final_top });
        self.repositories = workspace.Workspace.init(gpa, testing.io, self.runtime, policy, null, &self.served, try gpa.dupe(u8, self.session));
        self.open = true;
    }

    fn deinit(self: *Fixture) void {
        if (self.open) {
            self.repositories.deinit();
            self.served.close();
        }
        test_util.closeRuntime(self.runtime);
        self.arena_state.deinit();
        self.tmp.cleanup();
    }

    fn call(self: *Fixture, tool: []const u8, args: anytype) !Reply {
        const a = self.arena_state.allocator();
        const line = try std.json.Stringify.valueAlloc(a, .{
            .jsonrpc = "2.0",
            .id = 1,
            .method = "tools/call",
            .params = .{ .name = tool, .arguments = args },
        }, .{});
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        _ = try self.repositories.handle(line, &out.writer);
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, try a.dupe(u8, std.mem.trim(u8, out.written(), "\r\n")), .{});
        const result = parsed.object.get("result") orelse return error.NoResult;
        const content = result.object.get("content").?.array.items[0].object.get("text").?.string;
        const is_error = if (result.object.get("isError")) |flag| flag.bool else false;
        return .{ .text = content, .is_error = is_error };
    }

    fn path(self: *Fixture, base: []const u8, rel: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.arena_state.allocator(), "{s}\\{s}", .{ base, rel });
    }

    fn rule(self: *Fixture, text: []const u8, check: []const u8, where: ?[]const u8) !void {
        const id = try memory.remember(gpa, testing.io, self.top, .project, text, true, check, where);
        gpa.free(id);
    }

    fn exists(self: *Fixture, abs: []const u8) bool {
        _ = self;
        std.Io.Dir.cwd().access(testing.io, abs, .{}) catch return false;
        return true;
    }
};

fn contains(text: []const u8, part: []const u8) bool {
    return std.mem.indexOf(u8, text, part) != null;
}

fn expectHas(text: []const u8, part: []const u8) !void {
    errdefer std.debug.print("expected {s} in:\n{s}\n", .{ part, text });
    try testing.expect(contains(text, part));
}

fn skipOffWindows() !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
}

test "nested repos: search and list from the session folder reach repositories git ignores" {
    try skipOffWindows();
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.serve(.{});
    const found = try f.call("emetgate_search", .{ .pattern = "hello", .dir = f.session });
    try testing.expect(!found.is_error);
    try expectHas(found.text, "--- mobil/");
    try expectHas(found.text, "mobil/src/main.js");
    try expectHas(found.text, "--- backend/");
    try expectHas(found.text, "backend/src/main.js");
    try testing.expect(!contains(found.text, "nothing was searched"));
    const listed = try f.call("emetgate_list", .{ .dir = f.session });
    try expectHas(listed.text, "\"folders\":[\"backend\",\"mobil\"]");
    try expectHas(listed.text, "mobil/kept.txt");
    try expectHas(listed.text, "\"dir\":\"mobil\"");
}

test "nested repos: the everyday text search names files from the session folder" {
    try skipOffWindows();
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.serve(.{ .search_text = true, .search_internals = false });
    const found = try f.call("emetgate_search", .{ .pattern = "hello", .dir = f.session });
    try testing.expect(!found.is_error);
    try expectHas(found.text, "--- mobil/");
    try expectHas(found.text, "mobil/src/main.js");
    try expectHas(found.text, "backend/src/main.js");
    const empty = try f.call("emetgate_search", .{ .pattern = "absent_everywhere", .dir = f.session });
    try testing.expect(!contains(empty.text, "nothing was searched"));
}

test "nested repos: a repository under a dot folder or a linked worktree stays out of the search" {
    try skipOffWindows();
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena_state.allocator();
    try f.tmp.dir.createDirPath(testing.io, "top/app/.yedek/old");
    const old = try f.path(f.session, ".yedek\\old");
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "top/app/.yedek/old/old.txt", .data = "hello\n" });
    try git_fixture.initRepo(old);
    try commitAll(old);
    const linked = try f.path(f.session, "linked");
    try gitQuiet(f.mobil, &.{ "worktree", "add", "-q", "-b", "other", try std.mem.replaceOwned(u8, a, linked, "\\", "/") });
    try f.serve(.{});
    const found = try f.call("emetgate_search", .{ .pattern = "hello", .dir = f.session });
    try testing.expect(!contains(found.text, "old.txt"));
    try testing.expect(!contains(found.text, "--- linked/"));
    try expectHas(found.text, "--- mobil/");
}

test "nested repos: an empty folder is not reported as a passed search" {
    try skipOffWindows();
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.tmp.dir.createDirPath(testing.io, "top/empty");
    try f.serve(.{});
    const found = try f.call("emetgate_search", .{ .pattern = "hello", .dir = try f.path(f.top, "empty") });
    try expectHas(found.text, "nothing was searched");
    try testing.expect(!contains(found.text, "\"answer\":\"\u{2713}"));
}

test "nested repos: the everyday text search does not pass an empty folder either" {
    try skipOffWindows();
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.tmp.dir.createDirPath(testing.io, "top/empty");
    try f.serve(.{ .search_text = true, .search_internals = false });
    const found = try f.call("emetgate_search", .{ .pattern = "hello", .dir = try f.path(f.top, "empty") });
    try expectHas(found.text, "nothing was searched");
    try testing.expect(!contains(found.text, "\u{2713}"));
}

test "nested repos: a call across two repositories is refused and a call inside one is routed" {
    try skipOffWindows();
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.serve(.{});
    const spans = try f.call("emetgate_move_file", .{ .from = try f.path(f.mobil, "kept.txt"), .to = try f.path(f.backend, "kept.txt") });
    try testing.expect(spans.is_error);
    try expectHas(spans.text, "SpansRepositories");
    try testing.expect(f.exists(try f.path(f.mobil, "kept.txt")));
    const read = try f.call("emetgate_read_file", .{ .file = try f.path(f.mobil, "kept.txt") });
    try testing.expect(!read.is_error);
    try expectHas(read.text, "kept");
    const status = try f.call("emetgate_git", .{ .sub = "status", .dir = f.mobil });
    try testing.expect(!status.is_error);
    try expectHas(status.text, "\"clean\":true");
    const top_status = try f.call("emetgate_git", .{ .sub = "status" });
    try expectHas(top_status.text, "other git repositories below this folder");
}

test "nested repos: the git folder of a nested repository stays unreadable" {
    try skipOffWindows();
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.serve(.{});
    const reply = try f.call("emetgate_read_file", .{ .file = try f.path(f.mobil, ".git\\config") });
    try testing.expect(reply.is_error);
    try testing.expect(!contains(reply.text, "[core]"));
}

test "nested repos: a junction to a repository elsewhere does not become a routed repository" {
    try skipOffWindows();
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena_state.allocator();
    try f.tmp.dir.createDirPath(testing.io, "outside/src");
    const base = try std.fs.path.resolve(a, &.{ f.top, ".." });
    const outside = try f.path(base, "outside");
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "outside/secret.txt", .data = "secret-outside\n" });
    try git_fixture.initRepo(outside);
    try commitAll(outside);
    const link = try f.path(f.session, "linked");
    const made = try bounded_run.run(gpa, testing.io, .{ .argv = &.{ "cmd", "/c", "mklink", "/J", link, outside }, .cwd = .{ .path = f.top } });
    gpa.free(made.stdout);
    gpa.free(made.stderr);
    try testing.expect(made.term == .exited and made.term.exited == 0);
    try f.serve(.{});
    const reply = try f.call("emetgate_read_file", .{ .file = try f.path(link, "secret.txt") });
    try testing.expect(reply.is_error);
    try testing.expect(!contains(reply.text, "secret-outside"));
    const found = try f.call("emetgate_search", .{ .pattern = "secret-outside", .dir = f.session });
    try testing.expect(!contains(found.text, "secret.txt"));
}

test "nested repos: a rule of the outer repository holds inside a nested one only where it reaches" {
    try skipOffWindows();
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.rule("nowhere", "forbid:BANNED_EVERYWHERE", null);
    try f.rule("backend only", "forbid:BANNED_BACKEND", "app/backend/");
    try f.serve(.{});
    const everywhere = try f.call("emetgate_write_doc", .{ .file = try f.path(f.mobil, "a.js"), .content = "const BANNED_EVERYWHERE = 1;\n" });
    try expectHas(everywhere.text, "rule_violation");
    try testing.expect(!f.exists(try f.path(f.mobil, "a.js")));
    const elsewhere = try f.call("emetgate_write_doc", .{ .file = try f.path(f.mobil, "b.js"), .content = "const BANNED_BACKEND = 1;\n" });
    try testing.expect(!contains(elsewhere.text, "rule_violation"));
    try testing.expect(f.exists(try f.path(f.mobil, "b.js")));
    const there = try f.call("emetgate_write_doc", .{ .file = try f.path(f.backend, "c.js"), .content = "const BANNED_BACKEND = 1;\n" });
    try expectHas(there.text, "rule_violation");
    try testing.expect(!f.exists(try f.path(f.backend, "c.js")));
}

test "nested repos: a message rule of the outer repository refuses a commit in a nested one" {
    try skipOffWindows();
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.rule("no co-author", "message:forbid_any_case:co-authored-by", null);
    try f.serve(.{});
    const before = try git(f.mobil, &.{ "rev-parse", "HEAD" });
    defer gpa.free(before);
    const written = try f.call("emetgate_write_doc", .{ .file = try f.path(f.mobil, "note.md"), .content = "note\n" });
    try testing.expect(!written.is_error);
    const refused = try f.call("emetgate_commit", .{ .message = "feat: note\n\nCo-Authored-By: x <x@x>", .dir = f.mobil });
    try testing.expect(!contains(refused.text, "\"status\":\"committed\""));
    const still = try git(f.mobil, &.{ "rev-parse", "HEAD" });
    defer gpa.free(still);
    try testing.expectEqualStrings(before, still);
    const clean = try f.call("emetgate_commit", .{ .message = "feat: note", .dir = f.mobil });
    try expectHas(clean.text, "\"status\":\"committed\"");
    const top_log = try git(f.top, &.{ "log", "--format=%s" });
    defer gpa.free(top_log);
    try testing.expect(!contains(top_log, "feat: note"));
}

test "nested repos: a command runs in the session folder and a frozen file of a nested repository comes back" {
    try skipOffWindows();
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.rule("kept stays", checks.frozen_name, "app/mobil/kept.txt");
    try f.serve(.{ .open_run = true });
    const where = try f.call("emetgate_run", .{ .command = "ls" });
    try expectHas(where.text, "mobil");
    try expectHas(where.text, "backend");
    const touched = try f.call("emetgate_run", .{ .command = "echo tampered > mobil/kept.txt" });
    try expectHas(touched.text, "frozen_restored");
    var buffer: [64]u8 = undefined;
    const text = try std.Io.Dir.cwd().readFile(testing.io, try f.path(f.mobil, "kept.txt"), &buffer);
    try testing.expectEqualStrings("kept\n", std.mem.trim(u8, text, "\r"));
    const free = try f.call("emetgate_run", .{ .command = "echo changed > backend/kept.txt" });
    try testing.expect(!contains(free.text, "frozen_restored"));
}

test "nested repos: a path spelled from the repository root is read from the session folder" {
    try skipOffWindows();
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena_state.allocator();
    const from_root = try workspace.chooseSpelling(a, testing.io, f.top, f.session, "app/mobil/kept.txt");
    try testing.expectEqualStrings("mobil/kept.txt", from_root.spelled);
    const from_session = try workspace.chooseSpelling(a, testing.io, f.top, f.session, "mobil/kept.txt");
    try testing.expectEqualStrings("mobil/kept.txt", from_session.spelled);
    const above = try workspace.chooseSpelling(a, testing.io, f.top, f.session, "top.txt");
    try testing.expectEqualStrings("../top.txt", above.spelled);
    const fresh = try workspace.chooseSpelling(a, testing.io, f.top, f.session, "app/mobil/new.txt");
    try testing.expectEqualStrings("mobil/new.txt", fresh.spelled);
    const unknown = try workspace.chooseSpelling(a, testing.io, f.top, f.session, "nowhere/at/all.txt");
    try testing.expectEqualStrings("nowhere/at/all.txt", unknown.spelled);
}
