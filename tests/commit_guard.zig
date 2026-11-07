const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");
const git_fixture = @import("git_fixture.zig");

const commit_guard = emetgate.commit_guard;
const memory = emetgate.memory;
const rules = emetgate.rules;
const test_util = emetgate.test_util;
const bounded_run = emetgate.bounded_run;
const Runtime = emetgate.runtime.Runtime;

const testing = std.testing;
const gpa = testing.allocator;
const Allocating = std.Io.Writer.Allocating;

const Fixture = struct {
    tmp: testing.TmpDir,
    arena_state: std.heap.ArenaAllocator,
    runtime: *Runtime,
    root: []const u8,
    below: []const u8,

    fn init(self: *Fixture) !void {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        self.* = .{ .tmp = testing.tmpDir(.{}), .arena_state = .init(gpa), .runtime = try test_util.openRuntime(), .root = "", .below = "" };
        errdefer self.deinit();
        const a = self.arena_state.allocator();
        try self.tmp.dir.createDirPath(testing.io, "top/below/src");
        const base = try self.tmp.dir.realPathFileAlloc(testing.io, ".", a);
        self.root = try std.fmt.allocPrint(a, "{s}\\top", .{base});
        self.below = try std.fmt.allocPrint(a, "{s}\\below", .{self.root});
        try self.write("top/src.js", "function hello() {\n  return 1;\n}\n");
        try self.repo(self.root);
        try self.gitIn(self.root, &.{ "add", "-A" });
        try self.gitIn(self.root, &.{ "commit", "-qm", "base" });
    }

    fn deinit(self: *Fixture) void {
        rules.outer_root = null;
        self.runtime.destroy() catch {};
        self.arena_state.deinit();
        self.tmp.cleanup();
    }

    fn write(self: *Fixture, rel: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = rel, .data = data });
    }

    fn gitResult(self: *Fixture, cwd: []const u8, args: []const []const u8, env: ?*const std.process.Environ.Map) !std.process.RunResult {
        var argv: std.ArrayList([]const u8) = .empty;
        const a = self.arena_state.allocator();
        try argv.append(a, try git_fixture.git());
        try argv.appendSlice(a, args);
        return bounded_run.run(a, testing.io, .{ .argv = argv.items, .cwd = .{ .path = cwd }, .environ_map = env });
    }

    fn gitIn(self: *Fixture, cwd: []const u8, args: []const []const u8) !void {
        const result = try self.gitResult(cwd, args, null);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.GitFailed,
            else => return error.GitFailed,
        }
    }

    fn repo(self: *Fixture, cwd: []const u8) !void {
        try self.gitIn(cwd, &.{ "init", "-q" });
        try self.gitIn(cwd, &.{ "config", "user.name", "t" });
        try self.gitIn(cwd, &.{ "config", "user.email", "t@t" });
    }

    fn rule(_: *Fixture, root: []const u8, text: []const u8, check_spec: []const u8) !void {
        const id = try memory.remember(gpa, testing.io, root, .project, text, true, check_spec, null);
        gpa.free(id);
    }

    fn judged(self: *Fixture, message: []const u8) !struct { code: u8, text: []const u8 } {
        const a = self.arena_state.allocator();
        try self.write("top/.git/COMMIT_EDITMSG", message);
        const path = try std.fmt.allocPrint(a, "{s}\\.git\\COMMIT_EDITMSG", .{self.root});
        var out: Allocating = .init(a);
        const code = try commit_guard.check(gpa, testing.io, self.runtime, self.root, path, false, &out.writer);
        return .{ .code = code, .text = out.written() };
    }

    fn stage(self: *Fixture, rel: []const u8, data: []const u8) !void {
        const a = self.arena_state.allocator();
        try self.write(try std.fmt.allocPrint(a, "top/{s}", .{rel}), data);
        try self.gitIn(self.root, &.{ "add", "-A" });
    }
};

fn expectHas(text: []const u8, part: []const u8) !void {
    if (std.mem.indexOf(u8, text, part) == null) {
        std.debug.print("missing {s} in: {s}\n", .{ part, text });
        return error.TestExpectedEqual;
    }
}

test "commit guard: with no rules everything passes and nothing is created" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.stage("a.js", "console.log(1);\n");
    const got = try f.judged("feat: a\n\nCo-Authored-By: x <x@x>\n");
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expectError(error.FileNotFound, f.tmp.dir.access(testing.io, "top/.emetgate", .{}));
}

test "commit guard: a message rule refuses the commit and names the rule" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.rule(f.root, "no co-author", "message:forbid:Co-Authored-By");
    const bad = try f.judged("feat: a\n\nCo-Authored-By: x <x@x>\n");
    try testing.expectEqual(@as(u8, 1), bad.code);
    try expectHas(bad.text, "commit refused");
    try expectHas(bad.text, "no co-author");
    try expectHas(bad.text, "fix:");
    const good = try f.judged("feat: a\n");
    try testing.expectEqual(@as(u8, 0), good.code);
}

test "commit guard: a staged code file that adds a violation is refused" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.rule(f.root, "no console.log", "forbid:console.log");
    try f.stage("a.js", "console.log(1);\n");
    const bad = try f.judged("feat: a\n");
    try testing.expectEqual(@as(u8, 1), bad.code);
    try expectHas(bad.text, "a.js:1:");
    try expectHas(bad.text, "no console.log");
}

test "commit guard: a violation already in HEAD does not block an unrelated line" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.stage("a.js", "console.log(1);\nconst k = 1;\n");
    try f.gitIn(f.root, &.{ "commit", "-qm", "old" });
    try f.rule(f.root, "no console.log", "forbid:console.log");
    try f.stage("a.js", "console.log(1);\nconst k = 2;\n");
    const got = try f.judged("feat: a\n");
    try testing.expectEqual(@as(u8, 0), got.code);
}

test "commit guard: old violations between two changes do not block, a new one beside them does" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.stage("a.js", "const a = 1;\nconsole.log(1);\nconst b = 1;\nconsole.log(2);\nconst c = 1;\n");
    try f.gitIn(f.root, &.{ "commit", "-qm", "old" });
    try f.rule(f.root, "no console.log", "forbid:console.log");
    try f.stage("a.js", "const a = 2;\nconst added = 0;\nconsole.log(1);\nconst b = 2;\nconsole.log(2);\nconst c = 2;");
    try testing.expectEqual(@as(u8, 0), (try f.judged("feat: a\n")).code);
    try f.stage("a.js", "const a = 2;\nconsole.log(1);\nconst b = 2;\nconsole.log(3);\nconsole.log(2);\nconst c = 1;\n");
    const bad = try f.judged("feat: a\n");
    try testing.expectEqual(@as(u8, 1), bad.code);
    try expectHas(bad.text, "a.js:4:");
}

test "commit guard: a diff that is not understood reads as nothing" {
    const a = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const none = try commit_guard.holesFromDiff(arena.allocator(), "@@ -x +1 @@\n", "a\n", "b\n");
    try testing.expect(none == null);
    const one = (try commit_guard.holesFromDiff(arena.allocator(), "@@ -2,0 +3 @@ tail\n+c\n", "a\nb\n", "a\nb\nc\n")).?;
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqual(@as(u32, 4), one[0].old.start);
    try testing.expectEqual(@as(u32, 4), one[0].old.end);
    try testing.expectEqual(@as(u32, 4), one[0].new.start);
    try testing.expectEqual(@as(u32, 6), one[0].new.end);
}

test "commit guard: a staged deletion is judged and does not crash" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.rule(f.root, "no console.log", "forbid:console.log");
    try f.gitIn(f.root, &.{ "rm", "-q", "src.js" });
    const got = try f.judged("feat: a\n");
    try testing.expectEqual(@as(u8, 0), got.code);
}

test "commit guard: a merge has its message judged and not its files" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.gitIn(f.root, &.{ "checkout", "-qb", "side" });
    try f.stage("a.js", "console.log(1);\n");
    try f.gitIn(f.root, &.{ "commit", "-qm", "side" });
    try f.gitIn(f.root, &.{ "checkout", "-q", "-" });
    try f.stage("b.js", "const b = 1;\n");
    try f.gitIn(f.root, &.{ "commit", "-qm", "main" });
    try f.gitIn(f.root, &.{ "merge", "--no-commit", "--no-ff", "-q", "side" });
    try f.rule(f.root, "no console.log", "forbid:console.log");
    try f.rule(f.root, "no co-author", "message:forbid:Co-Authored-By");
    const clean = try f.judged("merge side\n");
    try testing.expectEqual(@as(u8, 0), clean.code);
    const bad = try f.judged("merge side\n\nCo-Authored-By: x <x@x>\n");
    try testing.expectEqual(@as(u8, 1), bad.code);
}

test "commit guard: rules of the folder above reach a repository below it" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.write("top/below/src/a.js", "const a = 1;\n");
    try f.repo(f.below);
    try f.gitIn(f.below, &.{ "add", "-A" });
    try f.gitIn(f.below, &.{ "commit", "-qm", "base" });
    try f.rule(f.root, "no co-author", "message:forbid:Co-Authored-By");
    rules.outer_root = f.root;
    const a = f.arena_state.allocator();
    try f.write("top/below/.git/COMMIT_EDITMSG", "feat\n\nCo-Authored-By: x <x@x>\n");
    const path = try std.fmt.allocPrint(a, "{s}\\.git\\COMMIT_EDITMSG", .{f.below});
    var out: Allocating = .init(a);
    try testing.expectEqual(@as(u8, 1), try commit_guard.check(gpa, testing.io, f.runtime, f.below, path, false, &out.writer));
}

const Hooked = struct { f: *Fixture, env: std.process.Environ.Map };

fn hooked(f: *Fixture, stub_exit: u8, user_count: ?[]const u8) !Hooked {
    const a = f.arena_state.allocator();
    const stub_rel = "stub-emetgate.sh";
    try f.write(stub_rel, try std.fmt.allocPrint(a, "#!/bin/sh\necho \"$2 $(basename \"$3\")\" >> \"$GUARD_LOG\"\nexit {d}\n", .{stub_exit}));
    const base = try f.tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const stub = try std.fmt.allocPrint(a, "{s}\\{s}", .{ base, stub_rel });
    const state = try std.fmt.allocPrint(a, "{s}\\state", .{base});
    const hooks = try commit_guard.install(gpa, testing.io, state, stub);
    defer gpa.free(hooks);
    const again = try commit_guard.install(gpa, testing.io, state, stub);
    defer gpa.free(again);
    try testing.expectEqualStrings(hooks, again);
    var env = try testing.environ.createMap(a);
    for (try commit_guard.environment(a, hooks, f.root, false, user_count)) |variable| try env.put(variable.name, variable.value);
    try env.put("GUARD_LOG", try std.fmt.allocPrint(a, "{s}\\guard.log", .{base}));
    try env.put("GIT_AUTHOR_NAME", "d");
    try env.put("GIT_AUTHOR_EMAIL", "d@d");
    try env.put("GIT_COMMITTER_NAME", "d");
    try env.put("GIT_COMMITTER_EMAIL", "d@d");
    return .{ .f = f, .env = env };
}

fn exitCode(result: std.process.RunResult) u8 {
    return switch (result.term) {
        .exited => |code| code,
        else => 255,
    };
}

test "commit guard: a real git commit runs the guard, and its refusal stops the commit" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var run = try hooked(&f, 1, null);
    try f.stage("a.js", "const a = 1;\n");
    const before = try f.gitResult(f.root, &.{ "rev-parse", "HEAD" }, null);
    const result = try f.gitResult(f.root, &.{ "commit", "-qm", "feat: a" }, &run.env);
    try testing.expectEqual(@as(u8, 1), exitCode(result));
    const after = try f.gitResult(f.root, &.{ "rev-parse", "HEAD" }, null);
    try testing.expectEqualStrings(before.stdout, after.stdout);
    const log = try f.tmp.dir.readFileAlloc(testing.io, "guard.log", f.arena_state.allocator(), .limited(4096));
    try expectHas(log, "commit-msg COMMIT_EDITMSG");
}

test "commit guard: the guard passing lets the commit through" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var run = try hooked(&f, 0, null);
    try f.stage("a.js", "const a = 1;\n");
    const result = try f.gitResult(f.root, &.{ "commit", "-qm", "feat: a" }, &run.env);
    try testing.expectEqual(@as(u8, 0), exitCode(result));
}

test "commit guard: the repository's own hooks in .git/hooks still run" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var run = try hooked(&f, 0, null);
    try f.write("top/.git/hooks/pre-commit", "#!/bin/sh\necho own-pre >> \"$GUARD_LOG\"\n");
    try f.write("top/.git/hooks/commit-msg", "#!/bin/sh\necho own-msg >> \"$GUARD_LOG\"\n");
    try f.write("top/.git/hooks/post-commit", "#!/bin/sh\necho own-post >> \"$GUARD_LOG\"\n");
    try f.stage("a.js", "const a = 1;\n");
    try testing.expectEqual(@as(u8, 0), exitCode(try f.gitResult(f.root, &.{ "commit", "-qm", "feat: a" }, &run.env)));
    const log = try f.tmp.dir.readFileAlloc(testing.io, "guard.log", f.arena_state.allocator(), .limited(4096));
    try expectHas(log, "own-pre");
    try expectHas(log, "own-msg");
    try expectHas(log, "own-post");
}

test "commit guard: the repository's own failing hook still stops the commit" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var run = try hooked(&f, 0, null);
    try f.write("top/.git/hooks/commit-msg", "#!/bin/sh\nexit 3\n");
    try f.stage("a.js", "const a = 1;\n");
    try testing.expect(exitCode(try f.gitResult(f.root, &.{ "commit", "-qm", "feat: a" }, &run.env)) != 0);
}

test "commit guard: a repository's own core.hooksPath is honoured" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var run = try hooked(&f, 0, null);
    try f.tmp.dir.createDirPath(testing.io, "top/.husky");
    try f.write("top/.husky/pre-commit", "#!/bin/sh\necho husky >> \"$GUARD_LOG\"\n");
    try f.gitIn(f.root, &.{ "config", "core.hooksPath", ".husky" });
    try f.stage("a.js", "const a = 1;\n");
    try testing.expectEqual(@as(u8, 0), exitCode(try f.gitResult(f.root, &.{ "commit", "-qm", "feat: a" }, &run.env)));
    const log = try f.tmp.dir.readFileAlloc(testing.io, "guard.log", f.arena_state.allocator(), .limited(4096));
    try expectHas(log, "husky");
    const local = try f.gitResult(f.root, &.{ "config", "--local", "core.hooksPath" }, null);
    try testing.expectEqualStrings(".husky", std.mem.trim(u8, local.stdout, "\r\n"));
}

test "commit guard: settings the user passed through GIT_CONFIG_COUNT survive" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var run = try hooked(&f, 1, "1");
    try run.env.put("GIT_CONFIG_KEY_0", "user.name");
    try run.env.put("GIT_CONFIG_VALUE_0", "kept");
    const name = try f.gitResult(f.root, &.{ "config", "user.name" }, &run.env);
    try testing.expectEqualStrings("kept", std.mem.trim(u8, name.stdout, "\r\n"));
    try f.stage("a.js", "const a = 1;\n");
    try testing.expectEqual(@as(u8, 1), exitCode(try f.gitResult(f.root, &.{ "commit", "-qm", "feat: a" }, &run.env)));
}

test "commit guard: a path with a quote survives the hook script" {
    const script = try commit_guard.guardScript(gpa, "C:\\it's here\\emetgate.exe");
    defer gpa.free(script);
    try expectHas(script, "exec 'C:/it'\\''s here/emetgate.exe' hook commit-msg \"$1\"");
}
