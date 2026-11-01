const std = @import("std");
const builtin = @import("builtin");
const fixture = @import("run_fixture.zig");
const emetgate = @import("emetgate");
const server = emetgate.server;
const memory = emetgate.memory;
const bounded_run = emetgate.bounded_run;
const run_command = emetgate.run_command;

const testing = std.testing;
const gpa = testing.allocator;
const frozen_file = "test/a.test.js";
const original = "original\n";

const Env = struct {
    repo: fixture.Repo,

    fn init() !Env {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        var repo = try fixture.Repo.init(&.{});
        errdefer repo.deinit();
        try repo.tmp.dir.createDirPath(testing.io, "repo/test");
        var env: Env = .{ .repo = repo };
        gpa.free(try env.git(&.{ "config", "core.autocrlf", "false" }));
        try env.repo.commitScript(".gitignore", "node_modules/\n.emetgate/\n");
        try env.repo.commitScript("app.js", "app\n");
        try env.repo.commitScript(frozen_file, original);
        return env;
    }

    fn deinit(self: *Env) void {
        self.repo.deinit();
    }

    fn freeze(self: *Env) !void {
        const id = try memory.remember(gpa, testing.io, self.repo.root_abs, .project, "tests are changed by hand", true, "frozen", "test/");
        gpa.free(id);
    }

    fn run(self: *Env, command: []const u8) !fixture.Reply {
        var policy: server.Policy = .{ .root = self.repo.root_abs };
        policy.open_run = true;
        return fixture.call(policy, .{ .command = command });
    }

    fn setup(self: *Env, command: []const u8) !void {
        var reply = try self.run(command);
        defer reply.deinit();
        errdefer std.debug.print("{s}\n", .{reply.text});
        try testing.expectEqual(@as(i64, 0), (try reply.field("exit_code")).?.integer);
    }

    fn read(self: *Env, rel: []const u8) ![]u8 {
        const path = try std.fmt.allocPrint(gpa, "repo/{s}", .{rel});
        defer gpa.free(path);
        return self.repo.tmp.dir.readFileAlloc(testing.io, path, gpa, .limited(1024 * 1024));
    }

    fn expectFile(self: *Env, rel: []const u8, want: []const u8) !void {
        const got = try self.read(rel);
        defer gpa.free(got);
        try testing.expectEqualStrings(want, got);
    }

    fn missing(self: *Env, rel: []const u8) bool {
        const path = std.fmt.allocPrint(gpa, "repo/{s}", .{rel}) catch return false;
        defer gpa.free(path);
        return !self.repo.exists(path);
    }

    fn git(self: *Env, args: []const []const u8) ![]u8 {
        var argv: [10][]const u8 = undefined;
        argv[0] = "git";
        @memcpy(argv[1..][0..args.len], args);
        const result = try bounded_run.run(gpa, testing.io, .{ .argv = argv[0 .. args.len + 1], .cwd = .{ .path = self.repo.root_abs } });
        gpa.free(result.stderr);
        errdefer gpa.free(result.stdout);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.GitSetupFailed,
            else => return error.GitSetupFailed,
        }
        return result.stdout;
    }

    fn expectGit(self: *Env, args: []const []const u8, want: []const u8) !void {
        const got = try self.git(args);
        defer gpa.free(got);
        try testing.expectEqualStrings(want, std.mem.trim(u8, got, " \r\n"));
    }
};

fn expectRestored(reply: *fixture.Reply, path: []const u8) !void {
    const list = (try reply.field("frozen_restored")) orelse return error.NothingRestored;
    for (list.array.items) |item| {
        if (std.mem.eql(u8, item.object.get("path").?.string, path)) {
            try testing.expect(item.object.get("rules").?.array.items.len == 1);
            try testing.expect(std.mem.indexOf(u8, try reply.string("fix"), "by hand") != null);
            return;
        }
    }
    return error.PathNotRestored;
}

test "frozen hold: a frozen file a command edits comes back, and a file no rule holds stays changed with its receipt" {
    var env = try Env.init();
    defer env.deinit();
    try env.freeze();
    var reply = try env.run("echo weak > test/a.test.js && echo changed > app.js");
    defer reply.deinit();
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings("ran", try reply.string("status"));
    try env.expectFile(frozen_file, original);
    try env.expectFile("app.js", "changed\n");
    try expectRestored(&reply, frozen_file);
    try testing.expectEqual(@as(i64, 1), (try reply.field("files_changed")).?.integer);
    try testing.expect((try reply.field("receipt")) != null);
    try testing.expect(env.missing(".emetgate/frozen-hold"));
}

test "frozen hold: new files under a frozen path are deleted with the folders they needed" {
    var env = try Env.init();
    defer env.deinit();
    try env.freeze();
    var reply = try env.run("mkdir -p test/deep && echo x > test/deep/new.js && echo y > test/new.js");
    defer reply.deinit();
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(env.missing("test/deep/new.js"));
    try testing.expect(env.missing("test/deep"));
    try testing.expect(env.missing("test/new.js"));
    try env.expectFile(frozen_file, original);
    try expectRestored(&reply, "test/deep/new.js");
    try expectRestored(&reply, "test/new.js");
    try testing.expect((try reply.field("files_changed")) == null);
}

test "frozen hold: a frozen file a command deletes is created again" {
    var env = try Env.init();
    defer env.deinit();
    try env.freeze();
    var reply = try env.run("rm -rf test");
    defer reply.deinit();
    errdefer std.debug.print("{s}\n", .{reply.text});
    try env.expectFile(frozen_file, original);
    try expectRestored(&reply, frozen_file);
}

test "frozen hold: a command that fails still gives the frozen file back" {
    var env = try Env.init();
    defer env.deinit();
    try env.freeze();
    var reply = try env.run("echo weak > test/a.test.js; exit 3");
    defer reply.deinit();
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expectEqual(@as(i64, 3), (try reply.field("exit_code")).?.integer);
    try env.expectFile(frozen_file, original);
    try expectRestored(&reply, frozen_file);
}

test "frozen hold: a frozen change a command staged leaves the index as it was" {
    var env = try Env.init();
    defer env.deinit();
    try env.freeze();
    var reply = try env.run("echo weak > test/a.test.js && echo also > test/new.js && git add -A");
    defer reply.deinit();
    errdefer std.debug.print("{s}\n", .{reply.text});
    try env.expectFile(frozen_file, original);
    try env.expectGit(&.{ "diff", "--cached", "--name-only" }, "");
    try env.expectGit(&.{ "status", "--short" }, "");
    try expectRestored(&reply, frozen_file);
    try expectRestored(&reply, "test/new.js");
}

test "frozen hold: what the user staged by hand before the run survives it" {
    var env = try Env.init();
    defer env.deinit();
    try env.repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/" ++ frozen_file, .data = "staged\n" });
    const added = try env.git(&.{ "add", frozen_file });
    gpa.free(added);
    try env.repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/" ++ frozen_file, .data = "hand\n" });
    try env.freeze();
    var reply = try env.run("echo weak > test/a.test.js && git add -A");
    defer reply.deinit();
    errdefer std.debug.print("{s}\n", .{reply.text});
    try env.expectFile(frozen_file, "hand\n");
    const index = try env.git(&.{ "show", ":" ++ frozen_file });
    defer gpa.free(index);
    try testing.expectEqualStrings("staged\n", index);
    try expectRestored(&reply, frozen_file);

    var quiet = try env.run("echo nothing");
    defer quiet.deinit();
    try testing.expect((try quiet.field("frozen_restored")) == null);
    try testing.expect((try quiet.field("fix")) == null);
}

test "frozen hold: a frozen change committed in the run is named and the commit stays" {
    var env = try Env.init();
    defer env.deinit();
    try env.freeze();
    var reply = try env.run("echo weak > test/a.test.js && git add -A && git commit -q -m weaken");
    defer reply.deinit();
    errdefer std.debug.print("{s}\n", .{reply.text});
    try env.expectFile(frozen_file, "weak\n");
    try env.expectGit(&.{ "log", "-1", "--format=%s" }, "weaken");
    try testing.expect((try reply.field("frozen_restored")) == null);
    const committed = (try reply.field("frozen_committed")).?.array.items;
    try testing.expectEqual(@as(usize, 1), committed.len);
    try testing.expectEqualStrings("weaken", committed[0].object.get("subject").?.string);
    try testing.expectEqualStrings(frozen_file, committed[0].object.get("paths").?.array.items[0].string);
    try testing.expect(std.mem.indexOf(u8, try reply.string("fix"), "by hand") != null);
}

test "frozen hold: a merge bringing a teammate's change to a frozen file keeps it and warns about nothing" {
    var env = try Env.init();
    defer env.deinit();
    try env.setup("git checkout -q -b side && echo teammate > test/a.test.js && git add -A && GIT_COMMITTER_DATE=2020-01-01T00:00:00 GIT_AUTHOR_DATE=2020-01-01T00:00:00 git commit -q -m teammate && git checkout -q - ");
    try env.repo.commitScript("other.js", "other\n");
    try env.freeze();
    var reply = try env.run("git merge -q --no-edit side");
    defer reply.deinit();
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expectEqual(@as(i64, 0), (try reply.field("exit_code")).?.integer);
    try env.expectFile(frozen_file, "teammate\n");
    try env.expectGit(&.{ "status", "--short" }, "");
    try testing.expect((try reply.field("frozen_restored")) == null);
    try testing.expect((try reply.field("frozen_committed")) == null);
    try testing.expect((try reply.field("fix")) == null);
}

test "frozen hold: a merge stopped on a frozen file is left for the user to finish" {
    var env = try Env.init();
    defer env.deinit();
    try env.setup("git checkout -q -b side && echo teammate > test/a.test.js && git add -A && git commit -q -m teammate && git checkout -q - ");
    try env.repo.commitScript(frozen_file, "ours\n");
    try env.freeze();
    var reply = try env.run("git merge -q --no-edit side");
    defer reply.deinit();
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expectEqual(@as(i64, 1), (try reply.field("exit_code")).?.integer);
    const left = (try reply.field("frozen_in_merge")).?.array.items;
    try testing.expectEqualStrings(frozen_file, left[0].string);
    try testing.expect((try reply.field("frozen_restored")) == null);
    const unmerged = try env.git(&.{ "ls-files", "-u" });
    defer gpa.free(unmerged);
    try testing.expect(unmerged.len != 0);
    gpa.free(try env.git(&.{ "merge", "--abort" }));
}

test "frozen hold: no copy is made without a frozen rule, and one is made with it" {
    var env = try Env.init();
    defer env.deinit();
    const probe = "test -e .emetgate/frozen-hold && echo copies || echo none; echo weak > test/a.test.js";
    var open = try env.run(probe);
    defer open.deinit();
    errdefer std.debug.print("{s}\n", .{open.text});
    try testing.expect(std.mem.indexOf(u8, try open.string("content"), "none") != null);
    try testing.expect((try open.field("frozen_restored")) == null);
    try env.expectFile(frozen_file, "weak\n");

    gpa.free(try env.git(&.{ "checkout", "--", frozen_file }));
    try env.freeze();
    var held = try env.run(probe);
    defer held.deinit();
    try testing.expect(std.mem.indexOf(u8, try held.string("content"), "copies") != null);
    try env.expectFile(frozen_file, original);
}

test "frozen hold: a held copy that changed during the run is reported and nothing reads as clean" {
    var env = try Env.init();
    defer env.deinit();
    try env.freeze();
    var reply = try env.run("echo weak > test/a.test.js && echo forged > .emetgate/frozen-hold/*/0");
    defer reply.deinit();
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try testing.expectEqualStrings("frozen_not_restored", try reply.string("status"));
    const failed = (try reply.field("frozen_failed")).?.array.items;
    try testing.expectEqualStrings(frozen_file, failed[0].object.get("path").?.string);
    try testing.expectEqualStrings("HeldCopyChanged", failed[0].object.get("reason").?.string);
    try testing.expect((try reply.field("receipt")) == null);
    try env.expectFile(frozen_file, "weak\n");
}

test "frozen hold: a toolchain command is held the same way" {
    var env = try Env.init();
    defer env.deinit();
    const id = try memory.remember(gpa, testing.io, env.repo.root_abs, .project, "the manifest is changed by hand", true, "frozen", "package.json");
    gpa.free(id);
    const ran = run_command.runInRepo(gpa, testing.io, env.repo.root_abs, "npm init -y", run_command.toolchain_limits, "test") catch return error.SkipZigTest;
    defer ran.report.deinit(gpa);
    defer ran.frozen.deinit(gpa);
    if (!ran.report.passed()) return error.SkipZigTest;
    try testing.expect(env.missing("package.json"));
    try testing.expectEqual(@as(usize, 1), ran.frozen.restored.len);
    try testing.expectEqualStrings("package.json", ran.frozen.restored[0].path);
}
