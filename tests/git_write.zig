const std = @import("std");
const builtin = @import("builtin");
const git_fixture = @import("git_fixture.zig");
const server = @import("emetgate").server;
const Runtime = @import("emetgate").runtime.Runtime;

const testing = std.testing;
const gpa = testing.allocator;
const Value = std.json.Value;

const Repo = struct {
    tmp: testing.TmpDir,
    root_abs: [:0]u8,

    fn init() !Repo {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo");
        const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", gpa);
        errdefer gpa.free(root_abs);
        try git_fixture.initRepo(root_abs);
        var repo: Repo = .{ .tmp = tmp, .root_abs = root_abs };
        gpa.free(try repo.git(&.{ "config", "core.autocrlf", "false" }));
        return repo;
    }

    fn deinit(self: *Repo) void {
        gpa.free(self.root_abs);
        self.tmp.cleanup();
    }

    fn writeFile(self: *Repo, rel: []const u8, data: []const u8) !void {
        const target = try std.fmt.allocPrint(gpa, "repo/{s}", .{rel});
        defer gpa.free(target);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = target, .data = data });
    }

    fn readFile(self: *Repo, rel: []const u8) ![]u8 {
        const target = try std.fmt.allocPrint(gpa, "repo/{s}", .{rel});
        defer gpa.free(target);
        return self.tmp.dir.readFileAlloc(testing.io, target, gpa, .limited(1024 * 1024));
    }

    fn git(self: *Repo, args: []const []const u8) ![]u8 {
        var argv: [12][]const u8 = undefined;
        argv[0] = "git";
        @memcpy(argv[1..][0..args.len], args);
        const result = try @import("emetgate").bounded_run.run(gpa, testing.io, .{ .argv = argv[0 .. args.len + 1], .cwd = .{ .path = self.root_abs } });
        defer gpa.free(result.stderr);
        errdefer gpa.free(result.stdout);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.GitSetupFailed,
            else => return error.GitSetupFailed,
        }
        return result.stdout;
    }

    fn commitAll(self: *Repo, message: []const u8) !void {
        gpa.free(try self.git(&.{ "add", "." }));
        gpa.free(try self.git(&.{ "commit", "-q", "-m", message }));
    }
};

const Reply = struct {
    parsed: std.json.Parsed(Value),
    body: std.json.Parsed(Value),
    is_error: bool,

    fn deinit(self: *Reply) void {
        self.body.deinit();
        self.parsed.deinit();
    }

    fn string(self: *Reply, name: []const u8) ?[]const u8 {
        const value = self.body.value.object.get(name) orelse return null;
        return if (value == .string) value.string else null;
    }
};

fn call(runtime: *Runtime, root_abs: []const u8, args: anytype) !Reply {
    return callTool(runtime, root_abs, "emetgate_git_write", args);
}

fn callTool(runtime: *Runtime, root_abs: []const u8, name: []const u8, args: anytype) !Reply {
    var line: std.Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    var js: std.json.Stringify = .{ .writer = &line.writer };
    try js.write(.{ .jsonrpc = "2.0", .id = 1, .method = "tools/call", .params = .{ .name = name, .arguments = args } });

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try server.handleMessageObserved(gpa, testing.io, runtime, line.written(), &out.writer, null, .{ .root = root_abs });

    const parsed = try std.json.parseFromSlice(Value, gpa, out.written(), .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    const result = parsed.value.object.get("result") orelse return error.NotAToolResult;
    const text = result.object.get("content").?.array.items[0].object.get("text").?.string;
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    errdefer std.debug.print("{s}\n", .{text});
    const body = try std.json.parseFromSlice(Value, gpa, text[0..end], .{ .allocate = .alloc_always });
    return .{ .parsed = parsed, .body = body, .is_error = result.object.get("isError").?.bool };
}

test "git write creates and switches to a branch, commits on it and reports head and shortstat" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.writeFile("version.txt", "11.2.0\n");
    try repo.commitAll("init");
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var switched = try call(runtime, repo.root_abs, .{ .args = .{ "switch", "-c", "release-11.3.0" } });
    defer switched.deinit();
    try testing.expect(!switched.is_error);
    try testing.expectEqualStrings("ok", switched.string("status").?);
    try testing.expectEqualStrings("release-11.3.0", switched.string("branch").?);

    try repo.writeFile("version.txt", "11.3.0\n");
    var committed = try call(runtime, repo.root_abs, .{ .args = .{ "commit", "-a", "-m", "Bump version to 11.3.0" } });
    defer committed.deinit();
    try testing.expect(!committed.is_error);
    try testing.expectEqualStrings("1 file changed, 1 insertion(+), 1 deletion(-)", committed.string("shortstat").?);
    const head = try repo.git(&.{ "rev-parse", "HEAD" });
    defer gpa.free(head);
    try testing.expectEqualStrings(std.mem.trim(u8, head, "\r\n"), committed.string("head").?);
    const subject = try repo.git(&.{ "log", "-1", "--format=%s", "release-11.3.0" });
    defer gpa.free(subject);
    try testing.expectEqualStrings("Bump version to 11.3.0\n", subject);
}

test "git write refuses a hard reset that would lose work until force is true" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.writeFile("a.txt", "one\n");
    try repo.commitAll("init");
    try repo.writeFile("a.txt", "uncommitted\n");
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var refused = try call(runtime, repo.root_abs, .{ .args = .{ "reset", "--hard" } });
    defer refused.deinit();
    try testing.expect(refused.is_error);
    try testing.expectEqualStrings("would_lose_work", refused.string("reason").?);
    const kept = try repo.readFile("a.txt");
    defer gpa.free(kept);
    try testing.expectEqualStrings("uncommitted\n", kept);

    var forced = try call(runtime, repo.root_abs, .{ .args = .{ "reset", "--hard" }, .force = true });
    defer forced.deinit();
    try testing.expect(!forced.is_error);
    const reset = try repo.readFile("a.txt");
    defer gpa.free(reset);
    try testing.expectEqualStrings("one\n", reset);
}

test "git write treats checkout of a branch as a switch and checkout of a path as work-losing" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.writeFile("a.txt", "one\n");
    try repo.commitAll("init");
    gpa.free(try repo.git(&.{ "branch", "topic" }));
    try repo.writeFile("a.txt", "dirty\n");
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var path = try call(runtime, repo.root_abs, .{ .args = .{ "checkout", "a.txt" } });
    defer path.deinit();
    try testing.expectEqualStrings("would_lose_work", path.string("reason").?);

    var branch = try call(runtime, repo.root_abs, .{ .args = .{ "checkout", "topic" } });
    defer branch.deinit();
    try testing.expect(!branch.is_error);
    try testing.expectEqualStrings("topic", branch.string("branch").?);
    const kept = try repo.readFile("a.txt");
    defer gpa.free(kept);
    try testing.expectEqualStrings("dirty\n", kept);
}

test "git write refuses a flag that runs a program and a subcommand outside the list" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.writeFile("a.txt", "one\n");
    try repo.commitAll("init");
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var exec = try call(runtime, repo.root_abs, .{ .args = .{ "rebase", "--exec", "calc", "HEAD" } });
    defer exec.deinit();
    try testing.expectEqualStrings("unsupported_flag", exec.string("reason").?);
    var config = try call(runtime, repo.root_abs, .{ .args = .{ "config", "core.hooksPath", "x" } });
    defer config.deinit();
    try testing.expectEqualStrings("unsupported_config_key", config.string("reason").?);
    var gc = try call(runtime, repo.root_abs, .{ .args = .{ "gc", "--prune=now" } });
    defer gc.deinit();
    try testing.expectEqualStrings("unsupported_subcommand", gc.string("reason").?);
}

fn expectOk(reply: *Reply) !void {
    if (reply.is_error) std.debug.print("{s} {s}\n", .{ reply.string("reason") orelse "", reply.string("output") orelse "" });
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings("ok", reply.string("status").?);
}

fn expectRefused(reply: *Reply, reason: []const u8) !void {
    try testing.expect(reply.is_error);
    try testing.expectEqualStrings(reason, reply.string("reason").?);
}

fn expectOutputHas(reply: *Reply, needle: []const u8) !void {
    const output = reply.string("output") orelse "";
    if (std.mem.indexOf(u8, output, needle) == null) {
        std.debug.print("missing {s} in {s}\n", .{ needle, output });
        return error.TestExpectedOutput;
    }
}

fn exists(repo: *Repo, rel: []const u8) bool {
    const target = std.fmt.allocPrint(gpa, "repo/{s}", .{rel}) catch return false;
    defer gpa.free(target);
    repo.tmp.dir.access(testing.io, target, .{}) catch return false;
    return true;
}

test "git parity: init and clone run inside the root and refuse targets outside it" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.writeFile("a.txt", "one\n");
    try repo.commitAll("init");
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var init = try call(runtime, repo.root_abs, .{ .args = .{ "init", "-b", "main", "nested" } });
    defer init.deinit();
    try expectOk(&init);
    try testing.expect(exists(&repo, "nested/.git/HEAD"));
    var outside = try call(runtime, repo.root_abs, .{ .args = .{ "init", "..\\escaped" } });
    defer outside.deinit();
    try expectRefused(&outside, "outside_root");
    try testing.expect(!exists(&repo, "../escaped"));

    var clone = try call(runtime, repo.root_abs, .{ .args = .{ "clone", "-q", ".", "vendor/copy" } });
    defer clone.deinit();
    try expectOk(&clone);
    try testing.expect(exists(&repo, "vendor/copy/a.txt"));
    var from_outside = try call(runtime, repo.root_abs, .{ .args = .{ "clone", "..", "stolen" } });
    defer from_outside.deinit();
    try expectRefused(&from_outside, "outside_root");
    var helper = try call(runtime, repo.root_abs, .{ .args = .{ "clone", "ext::cmd /c calc", "x" } });
    defer helper.deinit();
    try expectRefused(&helper, "unsupported_url");
}

test "git parity: remote add, list and remove, removal only with force" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.writeFile("a.txt", "one\n");
    try repo.commitAll("init");
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var add = try call(runtime, repo.root_abs, .{ .args = .{ "remote", "add", "upstream", "https://example.com/r.git" } });
    defer add.deinit();
    try expectOk(&add);
    var list = try call(runtime, repo.root_abs, .{ .args = .{ "remote", "-v" } });
    defer list.deinit();
    try expectOutputHas(&list, "upstream\thttps://example.com/r.git (fetch)");
    var local = try call(runtime, repo.root_abs, .{ .args = .{ "remote", "add", "evil", "C:\\Windows" } });
    defer local.deinit();
    try expectRefused(&local, "outside_root");
    var remove = try call(runtime, repo.root_abs, .{ .args = .{ "remote", "remove", "upstream" } });
    defer remove.deinit();
    try expectRefused(&remove, "would_lose_work");
    var forced = try call(runtime, repo.root_abs, .{ .args = .{ "remote", "remove", "upstream" }, .force = true });
    defer forced.deinit();
    try expectOk(&forced);
    const remotes = try repo.git(&.{"remote"});
    defer gpa.free(remotes);
    try testing.expectEqualStrings("", remotes);
}

test "git parity: config writes only listed keys and reads any key" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var set = try call(runtime, repo.root_abs, .{ .args = .{ "config", "user.name", "Release Bot" } });
    defer set.deinit();
    try expectOk(&set);
    var get = try call(runtime, repo.root_abs, .{ .args = .{ "config", "--get", "user.name" } });
    defer get.deinit();
    try expectOutputHas(&get, "Release Bot");
    var hooks = try call(runtime, repo.root_abs, .{ .args = .{ "config", "set", "core.hooksPath", "x" } });
    defer hooks.deinit();
    try expectRefused(&hooks, "unsupported_config_key");
    var alias = try call(runtime, repo.root_abs, .{ .args = .{ "config", "alias.x", "!calc" } });
    defer alias.deinit();
    try expectRefused(&alias, "unsupported_config_key");
    var global = try call(runtime, repo.root_abs, .{ .args = .{ "config", "--global", "user.name", "x" } });
    defer global.deinit();
    try expectRefused(&global, "unsupported_flag");
}

test "git parity: clean previews freely and deletes only with force" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.writeFile("a.txt", "one\n");
    try repo.commitAll("init");
    try repo.writeFile("junk.tmp", "x\n");
    try repo.tmp.dir.createDirPath(testing.io, "repo/.emetgate");
    try repo.writeFile(".emetgate/keep.txt", "state");
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var preview = try call(runtime, repo.root_abs, .{ .args = .{ "clean", "-nd" } });
    defer preview.deinit();
    try expectOk(&preview);
    try expectOutputHas(&preview, "Would remove junk.tmp");
    var refused = try call(runtime, repo.root_abs, .{ .args = .{ "clean", "-fd" } });
    defer refused.deinit();
    try expectRefused(&refused, "would_lose_work");
    try testing.expect(exists(&repo, "junk.tmp"));
    var forced = try call(runtime, repo.root_abs, .{ .args = .{ "clean", "-fd" }, .force = true });
    defer forced.deinit();
    try expectOk(&forced);
    try testing.expect(!exists(&repo, "junk.tmp"));
    try testing.expect(exists(&repo, ".emetgate/keep.txt"));
}

test "git parity: worktree add and list inside the root, outside refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.writeFile("a.txt", "one\n");
    try repo.commitAll("init");
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var add = try call(runtime, repo.root_abs, .{ .args = .{ "worktree", "add", "-b", "side", "trees/side" } });
    defer add.deinit();
    try expectOk(&add);
    try testing.expect(exists(&repo, "trees/side/a.txt"));
    var list = try call(runtime, repo.root_abs, .{ .args = .{ "worktree", "list", "--porcelain" } });
    defer list.deinit();
    try expectOutputHas(&list, "branch refs/heads/side");
    var outside = try call(runtime, repo.root_abs, .{ .args = .{ "worktree", "add", "..\\side2" } });
    defer outside.deinit();
    try expectRefused(&outside, "outside_root");
    var remove = try call(runtime, repo.root_abs, .{ .args = .{ "worktree", "remove", "trees/side" } });
    defer remove.deinit();
    try expectRefused(&remove, "would_lose_work");
}

test "git parity: format-patch, apply --check and am carry a commit across a reset" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.writeFile("a.txt", "one\n");
    try repo.commitAll("init");
    try repo.writeFile("a.txt", "two\n");
    try repo.commitAll("second");
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var patch = try call(runtime, repo.root_abs, .{ .args = .{ "format-patch", "-1", "-o", "patches" } });
    defer patch.deinit();
    try expectOk(&patch);
    try testing.expect(exists(&repo, "patches/0001-second.patch"));
    var reset = try call(runtime, repo.root_abs, .{ .args = .{ "reset", "--hard", "HEAD~1" }, .force = true });
    defer reset.deinit();
    try expectOk(&reset);
    var check = try call(runtime, repo.root_abs, .{ .args = .{ "apply", "--check", "patches/0001-second.patch" } });
    defer check.deinit();
    try expectOk(&check);
    var am = try call(runtime, repo.root_abs, .{ .args = .{ "am", "patches/0001-second.patch" } });
    defer am.deinit();
    try expectOk(&am);
    const content = try repo.readFile("a.txt");
    defer gpa.free(content);
    try testing.expectEqualStrings("two\n", content);
    var outside = try call(runtime, repo.root_abs, .{ .args = .{ "format-patch", "-1", "-o", "..\\out" } });
    defer outside.deinit();
    try expectRefused(&outside, "outside_root");
}

test "git parity: bisect walks to the first bad commit and resets" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.writeFile("v.txt", "good\n");
    try repo.commitAll("c1");
    try repo.writeFile("w.txt", "x\n");
    try repo.commitAll("c2");
    try repo.writeFile("v.txt", "bad\n");
    try repo.commitAll("c3");
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var start = try call(runtime, repo.root_abs, .{ .args = .{ "bisect", "start", "HEAD", "HEAD~2" } });
    defer start.deinit();
    try expectOk(&start);
    var good = try call(runtime, repo.root_abs, .{ .args = .{ "bisect", "good" } });
    defer good.deinit();
    try expectOk(&good);
    try expectOutputHas(&good, "is the first bad commit");
    var reset = try call(runtime, repo.root_abs, .{ .args = .{ "bisect", "reset" } });
    defer reset.deinit();
    try expectOk(&reset);
    var run = try call(runtime, repo.root_abs, .{ .args = .{ "bisect", "run", "cmd" } });
    defer run.deinit();
    try expectRefused(&run, "unsupported_action");
}

test "git parity: a merge conflict shows as conflicted and merge --abort restores the branch" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.writeFile("a.txt", "base\n");
    try repo.commitAll("init");
    gpa.free(try repo.git(&.{ "switch", "-q", "-c", "other" }));
    try repo.writeFile("a.txt", "theirs\n");
    try repo.commitAll("theirs");
    gpa.free(try repo.git(&.{ "switch", "-q", "-" }));
    try repo.writeFile("a.txt", "ours\n");
    try repo.commitAll("ours");
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var merge = try call(runtime, repo.root_abs, .{ .args = .{ "merge", "other" } });
    defer merge.deinit();
    try testing.expectEqualStrings("failed", merge.string("status").?);
    try expectOutputHas(&merge, "CONFLICT");
    var status = try callTool(runtime, repo.root_abs, "emetgate_git", .{ .sub = "status", .path = repo.root_abs });
    defer status.deinit();
    const conflicted = status.body.value.object.get("conflicted").?.array.items;
    try testing.expectEqual(@as(usize, 1), conflicted.len);
    try testing.expectEqualStrings("a.txt", conflicted[0].string);
    var abort = try call(runtime, repo.root_abs, .{ .args = .{ "merge", "--abort" } });
    defer abort.deinit();
    try expectOk(&abort);
    const content = try repo.readFile("a.txt");
    defer gpa.free(content);
    try testing.expectEqualStrings("ours\n", content);
}

test "git parity: emetgate_git runs read-only subcommands from args and refuses changing forms" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.writeFile("a.txt", "needle here\n");
    try repo.commitAll("init");
    gpa.free(try repo.git(&.{ "tag", "v1.0" }));
    try repo.writeFile("b.txt", "more\n");
    try repo.commitAll("next");
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var grep = try callTool(runtime, repo.root_abs, "emetgate_git", .{ .sub = "grep", .args = .{ "-n", "needle" } });
    defer grep.deinit();
    try expectOk(&grep);
    try expectOutputHas(&grep, "a.txt:1:needle here");
    var files = try callTool(runtime, repo.root_abs, "emetgate_git", .{ .sub = "ls-files" });
    defer files.deinit();
    try expectOutputHas(&files, "b.txt");
    var describe = try callTool(runtime, repo.root_abs, "emetgate_git", .{ .sub = "describe", .args = .{"--tags"} });
    defer describe.deinit();
    try expectOutputHas(&describe, "v1.0-1-g");
    var shortlog = try callTool(runtime, repo.root_abs, "emetgate_git", .{ .sub = "shortlog", .args = .{"-sn"} });
    defer shortlog.deinit();
    try expectOutputHas(&shortlog, "2\tt");
    var reflog = try callTool(runtime, repo.root_abs, "emetgate_git", .{ .sub = "reflog", .args = .{ "-n", "1" } });
    defer reflog.deinit();
    try expectOk(&reflog);
    var none = try callTool(runtime, repo.root_abs, "emetgate_git", .{ .sub = "grep", .args = .{"absent"} });
    defer none.deinit();
    try expectOk(&none);
    try testing.expectEqual(@as(i64, 1), none.body.value.object.get("exit_code").?.integer);
    var expire = try callTool(runtime, repo.root_abs, "emetgate_git", .{ .sub = "reflog", .args = .{ "expire", "--all" } });
    defer expire.deinit();
    try expectRefused(&expire, "not_read_only");
    var flag = try callTool(runtime, repo.root_abs, "emetgate_git", .{ .sub = "grep", .args = .{ "-O", "x" } });
    defer flag.deinit();
    try expectRefused(&flag, "unsupported_flag");
}

test "git parity: stash list and show, branch rename and delete, and amend run through git write" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.writeFile("a.txt", "one\n");
    try repo.commitAll("init");
    try repo.writeFile("a.txt", "wip\n");
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    var push = try call(runtime, repo.root_abs, .{ .args = .{ "stash", "push", "-m", "wip" } });
    defer push.deinit();
    try expectOk(&push);
    var list = try call(runtime, repo.root_abs, .{ .args = .{ "stash", "list" } });
    defer list.deinit();
    try expectOutputHas(&list, "stash@{0}: On ");
    var show = try call(runtime, repo.root_abs, .{ .args = .{ "stash", "show", "--stat" } });
    defer show.deinit();
    try expectOutputHas(&show, "a.txt");
    var branch = try call(runtime, repo.root_abs, .{ .args = .{ "branch", "topic" } });
    defer branch.deinit();
    try expectOk(&branch);
    var rename = try call(runtime, repo.root_abs, .{ .args = .{ "branch", "-m", "topic", "renamed" } });
    defer rename.deinit();
    try expectOk(&rename);
    var delete = try call(runtime, repo.root_abs, .{ .args = .{ "branch", "-d", "renamed" } });
    defer delete.deinit();
    try expectOk(&delete);
    var amend = try call(runtime, repo.root_abs, .{ .args = .{ "commit", "--amend", "--allow-empty", "-m", "init again" } });
    defer amend.deinit();
    try expectOk(&amend);
}
