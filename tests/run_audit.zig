const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");

const memory = emetgate.memory;
const rules = emetgate.rules;
const run_audit = emetgate.run_audit;
const server = emetgate.server;
const test_util = emetgate.test_util;
const bounded_run = emetgate.bounded_run;
const Runtime = emetgate.runtime.Runtime;

const testing = std.testing;
const gpa = testing.allocator;

const Fixture = struct {
    tmp: testing.TmpDir,
    arena_state: std.heap.ArenaAllocator,
    runtime: *Runtime,
    root: []const u8,
    audit: run_audit.Audit,
    audited: bool,

    fn init(self: *Fixture) !void {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        self.* = .{ .tmp = testing.tmpDir(.{}), .arena_state = .init(gpa), .runtime = try test_util.openRuntime(), .root = "", .audit = undefined, .audited = false };
        errdefer self.deinit();
        const a = self.arena_state.allocator();
        try self.tmp.dir.createDirPath(testing.io, "top");
        const base = try self.tmp.dir.realPathFileAlloc(testing.io, ".", a);
        self.root = try std.fmt.allocPrint(a, "{s}\\top", .{base});
        try self.write("top/src.js", "function hello() {\n  return 1;\n}\n");
        try self.repo(self.root);
        try self.git(self.root, &.{ "add", "-A" });
        try self.git(self.root, &.{ "commit", "-qm", "base" });
    }

    fn deinit(self: *Fixture) void {
        if (self.audited) self.audit.deinit();
        rules.outer_root = null;
        self.runtime.destroy() catch {};
        self.arena_state.deinit();
        self.tmp.cleanup();
    }

    fn write(self: *Fixture, rel: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = rel, .data = data });
    }

    fn gitOut(self: *Fixture, cwd: []const u8, args: []const []const u8, env: ?*const std.process.Environ.Map) ![]const u8 {
        const a = self.arena_state.allocator();
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(a, "git");
        try argv.appendSlice(a, args);
        const result = try bounded_run.run(a, testing.io, .{ .argv = argv.items, .cwd = .{ .path = cwd }, .environ_map = env });
        switch (result.term) {
            .exited => |code| if (code != 0) return error.GitFailed,
            else => return error.GitFailed,
        }
        return std.mem.trim(u8, result.stdout, " \t\r\n");
    }

    fn git(self: *Fixture, cwd: []const u8, args: []const []const u8) !void {
        _ = try self.gitOut(cwd, args, null);
    }

    fn repo(self: *Fixture, cwd: []const u8) !void {
        try self.git(cwd, &.{ "init", "-q" });
        try self.git(cwd, &.{ "config", "user.name", "t" });
        try self.git(cwd, &.{ "config", "user.email", "t@t" });
    }

    fn rule(_: *Fixture, root: []const u8, text: []const u8, check_spec: []const u8) !void {
        const id = try memory.remember(gpa, testing.io, root, .project, text, true, check_spec, null);
        gpa.free(id);
    }

    fn begin(self: *Fixture, nested: []const []const u8) !void {
        try self.audit.begin(gpa, testing.io, self.runtime, self.root, nested, false);
        self.audited = true;
    }

    fn found(self: *Fixture) ![]const run_audit.Finding {
        try self.audit.finish();
        return self.audit.findings.items;
    }
};

test "run audit: with no rules nothing is watched" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.begin(&.{});
    try f.write("top/a.js", "console.log(1);\n");
    try testing.expectEqual(@as(usize, 0), f.audit.repos.items.len);
    try testing.expectEqual(@as(usize, 0), (try f.found()).len);
}

test "run audit: a commit past the hook is judged on message and files" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.rule(f.root, "no co-author", "message:forbid:Co-Authored-By");
    try f.rule(f.root, "no console.log", "forbid:console.log");
    try f.git(f.root, &.{ "add", "-A" });
    try f.git(f.root, &.{ "reset", "-q" });
    try f.begin(&.{});
    try f.write("top/a.js", "console.log(1);\n");
    try f.git(f.root, &.{ "add", "a.js" });
    try f.git(f.root, &.{ "commit", "--no-verify", "-qm", "feat: a", "-m", "Co-Authored-By: x <x@x>" });
    const hits = try f.found();
    try testing.expectEqual(@as(usize, 2), hits.len);
    try testing.expectEqualStrings(rules.message_label, hits[0].file);
    try testing.expect(hits[0].commit != null);
    try testing.expectEqualStrings("a.js", hits[1].file);
    try testing.expect(hits[1].commit != null);
}

test "run audit: commit-tree with update-ref is seen" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.rule(f.root, "no co-author", "message:forbid:Co-Authored-By");
    try f.begin(&.{});
    const head = try f.gitOut(f.root, &.{ "rev-parse", "HEAD" }, null);
    const tree = try f.gitOut(f.root, &.{ "rev-parse", "HEAD^{tree}" }, null);
    const made = try f.gitOut(f.root, &.{ "commit-tree", tree, "-p", head, "-m", "Co-Authored-By: x" }, null);
    try f.git(f.root, &.{ "update-ref", "refs/heads/side", made });
    const hits = try f.found();
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings(rules.message_label, hits[0].file);
}

test "run audit: a file left uncommitted is judged, one already changed and untouched is not" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.rule(f.root, "no console.log", "forbid:console.log");
    try f.write("top/before.js", "console.log(0);\n");
    try f.begin(&.{});
    try f.write("top/a.js", "console.log(1);\n");
    const hits = try f.found();
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("a.js", hits[0].file);
    try testing.expect(hits[0].commit == null);
    try testing.expectEqual(@as(u32, 1), hits[0].line);
}

test "run audit: a file already changed and changed again is judged" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.rule(f.root, "no console.log", "forbid:console.log");
    try f.write("top/before.js", "const a = 1;\n");
    try f.begin(&.{});
    try f.write("top/before.js", "console.log(0);\n");
    const hits = try f.found();
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("before.js", hits[0].file);
}

test "run audit: an old violation beside a changed line is not reported, in LF or CRLF" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.write("top/a.js", "console.log(1);\nconst k = 1;\n");
    try f.git(f.root, &.{ "add", "a.js" });
    try f.git(f.root, &.{ "commit", "-qm", "old" });
    try f.rule(f.root, "no console.log", "forbid:console.log");
    try f.begin(&.{});
    try f.write("top/a.js", "console.log(1);\r\nconst k = 2;\r\n");
    try testing.expectEqual(@as(usize, 0), (try f.found()).len);
}

test "run audit: a command that deletes the rules is still judged by them" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.rule(f.root, "no console.log", "forbid:console.log");
    try f.begin(&.{});
    try f.tmp.dir.deleteTree(testing.io, "top/.emetgate");
    try f.write("top/a.js", "console.log(1);\n");
    const hits = try f.found();
    try testing.expectEqual(@as(usize, 1), hits.len);
}

test "run audit: a repository below is watched and named in the path" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena_state.allocator();
    try f.tmp.dir.createDirPath(testing.io, "top/mobil/src");
    const below = try std.fmt.allocPrint(a, "{s}\\mobil", .{f.root});
    try f.write("top/mobil/one.js", "const a = 1;\n");
    try f.repo(below);
    try f.git(below, &.{ "add", "-A" });
    try f.git(below, &.{ "commit", "-qm", "base" });
    try f.rule(f.root, "no console.log", "forbid:console.log");
    rules.outer_root = f.root;
    const nested = [_][]const u8{below};
    try f.begin(&nested);
    try f.write("top/mobil/src/z.js", "console.log(1);\n");
    try f.git(below, &.{ "add", "-A" });
    try f.git(below, &.{ "commit", "--no-verify", "-qm", "feat: z" });
    const hits = try f.found();
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("mobil/src/z.js", hits[0].file);
}

test "run audit: a commit dated before the run is not judged" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.rule(f.root, "no co-author", "message:forbid:Co-Authored-By");
    try f.begin(&.{});
    var env = try std.process.Environ.createMap(.{ .block = .global }, gpa);
    defer env.deinit();
    try env.put("GIT_COMMITTER_DATE", "2001-01-01T00:00:00");
    _ = try f.gitOut(f.root, &.{ "commit", "--allow-empty", "--no-verify", "-qm", "Co-Authored-By: x" }, &env);
    try testing.expectEqual(@as(usize, 0), (try f.found()).len);
}

test "run audit: emetgate_run answers rules_broken and is an error" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.rule(f.root, "no console.log", "forbid:console.log");
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"emetgate_run\",\"arguments\":{\"command\":\"echo 'console.log(1);' > z.js\"}}}";
    _ = try server.handleMessageObserved(gpa, testing.io, f.runtime, line, &out.writer, null, .{ .root = f.root, .open_run = true });
    const reply = out.written();
    try testing.expect(std.mem.indexOf(u8, reply, "rules_broken") != null);
    try testing.expect(std.mem.indexOf(u8, reply, "rule_violations") != null);
    try testing.expect(std.mem.indexOf(u8, reply, "\"isError\":true") != null);
}

test "run audit: emetgate_run on clean work still answers ran" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.rule(f.root, "no console.log", "forbid:console.log");
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"emetgate_run\",\"arguments\":{\"command\":\"echo 'const a = 1;' > z.js\"}}}";
    _ = try server.handleMessageObserved(gpa, testing.io, f.runtime, line, &out.writer, null, .{ .root = f.root, .open_run = true });
    try testing.expect(std.mem.indexOf(u8, out.written(), "rules_broken") == null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "rule_violations") == null);
}
