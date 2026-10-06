const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");
const fixture = @import("ts_fixture.zig");
const support = @import("runner_support.zig");
const common = @import("commit_batch.zig");

const symbol = emetgate.symbol;
const disk = emetgate.disk;
const runner = emetgate.runner;
const doc_writer = emetgate.doc_writer;
const git_commit = emetgate.git_commit;
const commit_plan = emetgate.commit_plan;
const verify_run = emetgate.verify_run;
const server = emetgate.server;

const testing = std.testing;
const Plain = common.Plain;
const Env = common.Env;

const util_src = "export function add(a: number, b: number): number {\n  return a + b;\n}\n";
const util_hand = "export function add(a: number, b: number): number {\n  return a + b + 0;\n}\n";
const new_body = "{\n  return b + a;\n}";
const mark = "b + a";
const notes_src = "# Notes\n\n## Setup\n\nold\n";
const setup_old = "## Setup\n\nold\n";
const setup_new = "## Setup\n\nnew\n";
const message = "fix: swap";
const files = [_]fixture.File{ .{ .rel = "src/util.ts", .text = util_src }, .{ .rel = "notes.md", .text = notes_src }, common.ignore };

const after_lock = 3;
const after_branch = 4;
const after_index = 5;

fn skipOffWindows() !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
}

const Cut = struct {
    target: usize,
    seen: usize = 0,

    fn reached(context: *anyopaque) bool {
        const self: *Cut = @ptrCast(@alignCast(context));
        self.seen += 1;
        return self.seen == self.target;
    }
};

fn swap(case: *Plain, stop: usize, request: *commit_plan.Request) !bool {
    const env = &case.env;
    var at: Cut = .{ .target = stop };
    const step: disk.Step = .{ .context = &at, .reached = Cut.reached };
    const file = try env.abs("src/util.ts");
    const result = runner.tryMutate(testing.allocator, testing.io, case.runtime, .{
        .file_abs = file,
        .ref_text = "add",
        .expected_hash = .{ .present = try support.hashOfRef(testing.allocator, testing.io, case.runtime, file, "add") },
        .new_body = new_body,
        .test_command = common.green,
        .commit = request,
        .commit_step = &step,
    }) catch |err| switch (err) {
        error.Crashed => return true,
        else => |e| return e,
    };
    result.deinit(testing.allocator);
    return false;
}

fn cutAt(case: *Plain, stop: usize) !void {
    var request: commit_plan.Request = .{ .message = message };
    defer request.deinit(testing.allocator);
    try testing.expect(try swap(case, stop, &request));
}

fn recover(case: *Plain) !disk.RecoverReport {
    return disk.recover(testing.allocator, testing.io, case.repo.root_abs);
}

fn status(env: *Env) ![]const u8 {
    return env.git(&.{ "status", "--porcelain", "--untracked-files=all" });
}

fn gitFails(env: *Env, argv: []const []const u8) !bool {
    var full: std.ArrayList([]const u8) = .empty;
    try full.append(env.arena(), "git");
    try full.appendSlice(env.arena(), argv);
    const result = try std.process.run(env.arena(), testing.io, .{ .argv = full.items, .cwd = .{ .path = env.repo.root_abs } });
    return switch (result.term) {
        .exited => |code| code != 0,
        else => true,
    };
}

fn written(case: *Plain) !bool {
    return std.mem.indexOf(u8, try case.env.read("src/util.ts"), mark) != null;
}

test "commit protocol: the cut points the tests below use are the held lock, the moved branch and the published index" {
    try skipOffWindows();
    {
        var case: Plain = undefined;
        try case.init(&files);
        defer case.deinit();
        const before = try case.env.head();
        try cutAt(&case, after_lock);
        try testing.expectEqualStrings(before, try case.env.head());
        try testing.expect(case.repo.exists(".git/index.lock"));
        try testing.expect(case.repo.exists(".emetgate/intents"));
        try testing.expect(!try written(&case));
    }
    {
        var case: Plain = undefined;
        try case.init(&files);
        defer case.deinit();
        const before = try case.env.head();
        try cutAt(&case, after_branch);
        try testing.expectEqualStrings(before, try case.env.git(&.{ "rev-parse", "HEAD^" }));
        try testing.expect(case.repo.exists(".git/index.lock"));
        try testing.expect(!try written(&case));
    }
    {
        var case: Plain = undefined;
        try case.init(&files);
        defer case.deinit();
        const before = try case.env.head();
        try cutAt(&case, after_index);
        try testing.expectEqualStrings(before, try case.env.git(&.{ "rev-parse", "HEAD^" }));
        try testing.expect(!case.repo.exists(".git/index.lock"));
        try testing.expectEqualStrings("", try case.env.git(&.{ "diff", "--cached", "--name-only" }));
        try testing.expect(!try written(&case));
    }
}

test "commit protocol: a committing write_doc cut after any step recovers to no write or to the whole commit, with a clean tree" {
    try skipOffWindows();
    var stop: usize = 1;
    var crashes: usize = 0;
    while (true) : (stop += 1) {
        var case: Plain = undefined;
        try case.init(&files);
        defer case.deinit();
        errdefer std.debug.print("cut after step {d}\n", .{stop});
        const env = &case.env;
        const before = try env.head();
        var at: Cut = .{ .target = stop };
        const step: disk.Step = .{ .context = &at, .reached = Cut.reached };
        var request: commit_plan.Request = .{ .message = message };
        defer request.deinit(testing.allocator);
        const outcome = doc_writer.tryWriteDoc(testing.allocator, testing.io, .{
            .file_abs = try env.abs("notes.md"),
            .selector = .{ .heading = "Setup" },
            .expected_hash = symbol.hashOf(setup_old),
            .new_text = setup_new,
            .test_command = common.green,
            .commit = &request,
            .commit_step = &step,
        }, null);
        const crashed = if (outcome) |result| blk: {
            result.deinit(testing.allocator);
            break :blk false;
        } else |err| switch (err) {
            error.Crashed => true,
            else => |e| return e,
        };
        if (crashed) {
            crashes += 1;
            const report = try recover(&case);
            try testing.expectEqual(@as(usize, 0), report.failed + report.commits.pending + report.commits.failed + report.commits.left);
        }
        const on_disk = std.mem.indexOf(u8, try env.read("notes.md"), "new") != null;
        const in_head = std.mem.indexOf(u8, try env.git(&.{ "show", "HEAD:notes.md" }), "new") != null;
        const moved = !std.mem.eql(u8, before, try env.head());
        try testing.expectEqual(on_disk, in_head);
        try testing.expectEqual(moved, in_head);
        try testing.expectEqualStrings("", try status(env));
        try testing.expect(!case.repo.exists(".git/index.lock"));
        try testing.expect(!case.repo.exists(".emetgate/intents"));
        if (!crashed) break;
    }
    try testing.expect(crashes >= 6);
}

test "commit protocol: recover never removes or replaces an index lock it does not own, before the branch moved or after" {
    try skipOffWindows();
    {
        var case: Plain = undefined;
        try case.init(&files);
        defer case.deinit();
        const before = try case.env.head();
        try cutAt(&case, after_lock);
        try case.repo.write(".git/index.lock", "held by someone else");
        const report = try recover(&case);
        try testing.expectEqual(@as(usize, 1), report.commits.dropped);
        try testing.expectEqualStrings("held by someone else", try case.env.read(".git/index.lock"));
        try testing.expectEqualStrings(before, try case.env.head());
        try testing.expect(!try written(&case));
    }
    {
        var case: Plain = undefined;
        try case.init(&files);
        defer case.deinit();
        try cutAt(&case, after_branch);
        try case.repo.write(".git/index.lock", "held by someone else");
        const blocked = try recover(&case);
        try testing.expectEqual(@as(usize, 1), blocked.commits.pending);
        try testing.expectEqualStrings("IndexLocked", blocked.commits.reason.?);
        try testing.expectEqualStrings("held by someone else", try case.env.read(".git/index.lock"));
        try testing.expect(!try written(&case));
        try testing.expect(case.repo.exists(".emetgate/intents"));

        var request: commit_plan.Request = .{ .message = message };
        defer request.deinit(testing.allocator);
        try testing.expectError(error.CommitStillPending, swap(&case, 0, &request));
        try testing.expectEqualStrings("held by someone else", try case.env.read(".git/index.lock"));

        try case.repo.tmp.dir.deleteFile(testing.io, "repo/.git/index.lock");
        const done = try recover(&case);
        try testing.expectEqual(@as(usize, 1), done.commits.landed);
        try testing.expect(try written(&case));
        try testing.expectEqualStrings("", try status(&case.env));
    }
}

test "commit protocol: the user removes the lock and commits before the index was published, and recover writes nothing and leaves a clean tree" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    try cutAt(&case, after_branch);
    const made = try env.head();
    try testing.expect(try gitFails(env, &.{ "commit", "-q", "--allow-empty", "-m", "user: blocked" }));
    try case.repo.tmp.dir.deleteFile(testing.io, "repo/.git/index.lock");
    _ = try env.git(&.{ "commit", "-q", "--allow-empty", "-m", "user: after the crash" });

    const report = try recover(&case);
    try testing.expectEqual(@as(usize, 1), report.commits.dropped);
    try testing.expectEqual(@as(usize, 0), report.commits.written + report.commits.landed + report.commits.pending + report.commits.failed);
    try testing.expectEqualStrings(made, try env.git(&.{ "rev-parse", "HEAD^" }));
    try testing.expectEqualStrings(util_src, try env.read("src/util.ts"));
    try testing.expectEqualStrings("", try status(env));
    try testing.expect(!case.repo.exists(".emetgate/intents"));
}

test "commit protocol: the user commits after the index was published, and recover writes the file that commit holds and leaves a clean tree" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    try cutAt(&case, after_index);
    _ = try env.git(&.{ "commit", "-q", "--allow-empty", "-m", "user: after the crash" });

    const report = try recover(&case);
    try testing.expectEqual(@as(usize, 1), report.commits.landed);
    try testing.expectEqual(@as(usize, 1), report.commits.written);
    try testing.expect(try written(&case));
    try testing.expect(std.mem.indexOf(u8, try env.git(&.{ "show", "HEAD:src/util.ts" }), mark) != null);
    try testing.expectEqualStrings("", try status(env));
}

test "commit protocol: a target the user edited after the crash is left as found, named in the report, and shows as their change" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    try cutAt(&case, after_index);
    try case.repo.write("src/util.ts", util_hand);

    const report = try recover(&case);
    try testing.expectEqual(@as(usize, 1), report.commits.left);
    try testing.expectEqual(@as(usize, 0), report.commits.written + report.commits.pending);
    try testing.expectEqualStrings("TargetChangedAfterCommit", report.commits.reason.?);
    try testing.expectEqualStrings(util_hand, try env.read("src/util.ts"));
    try testing.expectEqualStrings("M src/util.ts", try status(env));
    try testing.expect(!case.repo.exists(".emetgate/intents"));
}

test "commit protocol: a soft reset while the lock is held undoes the commit, and recover releases the lock and writes nothing" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    const before = try env.head();
    try cutAt(&case, after_branch);
    _ = try env.git(&.{ "reset", "-q", "--soft", "HEAD^" });

    const report = try recover(&case);
    try testing.expectEqual(@as(usize, 1), report.commits.dropped);
    try testing.expectEqualStrings(before, try env.head());
    try testing.expect(!case.repo.exists(".git/index.lock"));
    try testing.expectEqualStrings(util_src, try env.read("src/util.ts"));
    try testing.expectEqualStrings("", try status(env));
}

test "commit protocol: design limit: a soft reset after the index was published keeps the published entry staged, as a soft reset does" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    try cutAt(&case, after_index);
    _ = try env.git(&.{ "reset", "-q", "--soft", "HEAD^" });

    const report = try recover(&case);
    try testing.expectEqual(@as(usize, 1), report.commits.dropped);
    try testing.expectEqualStrings(util_src, try env.read("src/util.ts"));
    try testing.expectEqualStrings("MM src/util.ts", try status(env));
}

test "commit protocol: a branch made after the index was published carries the commit, and recover writes the file there" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    try cutAt(&case, after_index);
    _ = try env.git(&.{ "checkout", "-q", "-b", "other" });

    const report = try recover(&case);
    try testing.expectEqual(@as(usize, 1), report.commits.written);
    try testing.expect(try written(&case));
    try testing.expectEqualStrings("", try status(env));
    try testing.expectEqualStrings("other", try env.git(&.{ "symbolic-ref", "--short", "HEAD" }));
}

test "commit protocol: a branch switch is refused by git while the lock is held" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    try cutAt(&case, after_branch);
    _ = try env.git(&.{ "branch", "other", "HEAD^" });
    try testing.expect(try gitFails(env, &.{ "checkout", "-q", "other" }));
    const report = try recover(&case);
    try testing.expectEqual(@as(usize, 1), report.commits.landed);
    try testing.expect(try written(&case));
    try testing.expectEqualStrings("", try status(env));
}

test "commit protocol: a publish that is refused a few times is retried, and one that keeps being refused is reported with the commit and finished later" {
    try skipOffWindows();
    {
        var case: Plain = undefined;
        try case.init(&files);
        defer case.deinit();
        git_commit.publish_refusals = 3;
        defer git_commit.publish_refusals = 0;
        var request: commit_plan.Request = .{ .message = message };
        defer request.deinit(testing.allocator);
        try testing.expect(!try swap(&case, 0, &request));
        try testing.expect(request.unfinished == null);
        try testing.expect(try written(&case));
        try testing.expectEqualStrings("", try status(&case.env));
    }
    {
        var case: Plain = undefined;
        try case.init(&files);
        defer case.deinit();
        const env = &case.env;
        git_commit.publish_refusals = 1000;
        defer git_commit.publish_refusals = 0;
        const reply = try env.call("emetgate_try", .{ .file = try env.abs("src/util.ts"), .symbol = "add", .hash = try env.hashOf("src/util.ts", "add"), .body = new_body, .message = message }, common.green, true);
        errdefer std.debug.print("{s}\n", .{reply.text});
        const commit = (try reply.field(env.arena(), "commit")).?.string;
        try testing.expectEqualStrings(commit, try env.head());
        try testing.expectEqualStrings("IndexNotPublished", (try reply.field(env.arena(), "commit_unfinished")).?.string);
        try testing.expect(case.repo.exists(".git/index.lock"));
        try testing.expect(case.repo.exists(".emetgate/intents"));
        try testing.expect(!try written(&case));

        git_commit.publish_refusals = 0;
        const report = try recover(&case);
        try testing.expectEqual(@as(usize, 1), report.commits.landed);
        try testing.expect(try written(&case));
        try testing.expectEqualStrings("", try status(env));
    }
}

test "commit protocol: a repository with a split index gets the commit and a clean tree" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    _ = try env.git(&.{ "update-index", "--split-index" });
    var request: commit_plan.Request = .{ .message = message };
    defer request.deinit(testing.allocator);
    try testing.expect(!try swap(&case, 0, &request));
    try testing.expectEqualStrings(request.oid.?, try env.head());
    try testing.expectEqualStrings("", try status(env));
    try testing.expectEqualStrings("", try env.git(&.{ "diff", "--cached", "--name-only" }));
    _ = try env.git(&.{ "fsck", "--no-dangling" });
}

test "commit protocol: the files put back into the shadow are byte for byte what git cat-file with filters gives, line end conversion included" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ .{ .rel = "src/util.ts", .text = util_src }, .{ .rel = "keep.txt", .text = "one\ntwo\n" }, .{ .rel = ".gitattributes", .text = "*.ts text eol=crlf\n*.txt ident\n" }, common.ignore });
    defer case.deinit();
    const env = &case.env;
    const head = try git_commit.preflight(testing.allocator, testing.io, case.repo.root_abs, &.{});
    defer head.deinit(testing.allocator);
    const out = try env.abs("..\\out");
    try std.Io.Dir.cwd().createDirPath(testing.io, out);
    const paths = [_][]const u8{ "src/util.ts", "keep.txt" };
    try git_commit.checkoutInto(testing.allocator, testing.io, case.repo.root_abs, head, &paths, out);
    for (paths) |path| {
        const path_arg = try std.fmt.allocPrint(env.arena(), "--path={s}", .{path});
        const spec = try std.fmt.allocPrint(env.arena(), "HEAD:{s}", .{path});
        var argv = [_][]const u8{ "git", "cat-file", "--filters", path_arg, spec };
        const filtered = try std.process.run(env.arena(), testing.io, .{ .argv = &argv, .cwd = .{ .path = case.repo.root_abs } });
        const got = try std.Io.Dir.cwd().readFileAlloc(testing.io, try std.fmt.allocPrint(env.arena(), "{s}\\{s}", .{ out, path }), env.arena(), .unlimited);
        try testing.expectEqualStrings(filtered.stdout, got);
    }
    try testing.expect(std.mem.indexOf(u8, try std.Io.Dir.cwd().readFileAlloc(testing.io, try std.fmt.allocPrint(env.arena(), "{s}\\src/util.ts", .{out}), env.arena(), .unlimited), "\r\n") != null);
}

test "commit protocol: a commit completed by recover has no receipt, and verify calls it unverified, never verified" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    try cutAt(&case, after_index);
    const report = try recover(&case);
    try testing.expectEqual(@as(usize, 1), report.commits.landed);
    const result = try verify_run.run(testing.allocator, env.arena(), testing.io, case.runtime, case.repo.root_abs, .{ .commit = "HEAD", .test_command = common.green });
    try testing.expectEqual(emetgate.checker.Verdict.unverified, result.report.verdict);
}

test "commit protocol: the server finishes a pending commit when it starts" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    try cutAt(&case, after_branch);
    server.finishPendingCommits(testing.allocator, testing.io, case.repo.root_abs);
    try testing.expect(try written(&case));
    try testing.expect(!case.repo.exists(".git/index.lock"));
    try testing.expectEqualStrings("", try status(&case.env));
}

test "commit protocol: an index lock is refused before the gate runs, so a failing test is never reached" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    try case.repo.write(".git/index.lock", "held by someone else");
    const reply = try env.call("emetgate_try", .{ .file = try env.abs("src/util.ts"), .symbol = "add", .hash = try env.hashOf("src/util.ts", "add"), .body = new_body, .message = message }, common.red, true);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try testing.expect(std.mem.indexOf(u8, reply.text, "IndexLocked") != null);
    try testing.expectEqualStrings("held by someone else", try env.read(".git/index.lock"));
}

fn raceStage(root_abs: []const u8, shadow_abs: []const u8) void {
    const io = testing.io;
    var started_buf: [std.fs.max_path_bytes]u8 = undefined;
    var raced_buf: [std.fs.max_path_bytes]u8 = undefined;
    const started = std.fmt.bufPrint(&started_buf, "{s}\\started", .{shadow_abs}) catch return;
    const raced = std.fmt.bufPrint(&raced_buf, "{s}\\raced", .{shadow_abs}) catch return;
    var attempt: usize = 0;
    while (attempt < 3000) : (attempt += 1) {
        if (std.Io.Dir.cwd().access(io, started, .{})) |_| break else |_| {}
        io.sleep(.fromMilliseconds(10), .awake) catch return;
    } else return;
    var file_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = std.fmt.bufPrint(&file_buf, "{s}\\src\\util.ts", .{root_abs}) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = util_hand }) catch return;
    support.Repo.git(root_abs, &.{ "add", "src/util.ts" }) catch {};
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = util_src }) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = raced, .data = "" }) catch return;
}

const racing_cmd = "echo.> started & (for /l %i in (1,1,3000) do @if exist raced (exit 0) else ping -n 1 127.0.0.1 >nul) & exit 1";

test "commit protocol: a change the user stages on the target while the tests run is not overwritten in the index" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    const location = try emetgate.shadow_root.locate(testing.allocator, case.repo.root_abs, null);
    defer location.deinit(testing.allocator);
    const before = try env.head();
    const hash = try env.hashOf("src/util.ts", "add");
    const racer = try std.Thread.spawn(.{}, raceStage, .{ @as([]const u8, case.repo.root_abs), @as([]const u8, location.shadow) });
    const outcome = env.call("emetgate_try", .{ .file = try env.abs("src/util.ts"), .symbol = "add", .hash = hash, .body = new_body, .message = message }, racing_cmd, true);
    racer.join();
    const reply = try outcome;
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try testing.expect(std.mem.indexOf(u8, reply.text, "TargetHasUncommittedChanges") != null);
    try testing.expectEqualStrings(before, try env.head());
    try testing.expectEqualStrings("MM src/util.ts", try status(env));
    try testing.expect(std.mem.indexOf(u8, try env.git(&.{ "show", ":src/util.ts" }), "a + b + 0") != null);
    try testing.expect(!case.repo.exists(".git/index.lock"));
}

fn firstIntent(case: *Plain, suffix: []const u8) ![]const u8 {
    const env = &case.env;
    var dir = try case.repo.tmp.dir.openDir(testing.io, "repo/.emetgate/intents", .{ .iterate = true });
    defer dir.close(testing.io);
    var it = dir.iterate();
    while (try it.next(testing.io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, suffix)) return std.fmt.allocPrint(env.arena(), ".emetgate/intents/{s}", .{entry.name});
    }
    return error.NoIntent;
}

test "commit protocol: staged bytes that were tampered with are never written, whether or not the record was changed to match" {
    try skipOffWindows();
    const tampered = "export function add(a: number, b: number): number {\n  return 666;\n}\n";
    {
        var case: Plain = undefined;
        try case.init(&files);
        defer case.deinit();
        try cutAt(&case, after_index);
        try case.repo.write(try firstIntent(&case, ".0.new"), tampered);
        const report = try recover(&case);
        try testing.expectEqual(@as(usize, 1), report.commits.failed);
        try testing.expectEqualStrings("CorruptIntent", report.commits.reason.?);
        try testing.expectEqualStrings(util_src, try case.env.read("src/util.ts"));
        try testing.expect(!case.repo.exists(".emetgate/intents"));
    }
    {
        var case: Plain = undefined;
        try case.init(&files);
        defer case.deinit();
        const env = &case.env;
        try cutAt(&case, after_index);
        const staged = try firstIntent(&case, ".0.new");
        const record = try firstIntent(&case, ".json");
        const good = symbol.formatHash(symbol.hashOf(try env.read(staged)));
        const bad = symbol.formatHash(symbol.hashOf(tampered));
        const text = try env.read(record);
        const changed = try std.mem.replaceOwned(u8, env.arena(), text, &good, &bad);
        try testing.expect(!std.mem.eql(u8, text, changed));
        try case.repo.write(record, changed);
        try case.repo.write(staged, tampered);
        const report = try recover(&case);
        try testing.expectEqual(@as(usize, 1), report.commits.failed);
        try testing.expectEqualStrings("CorruptIntent", report.commits.reason.?);
        try testing.expectEqualStrings(util_src, try env.read("src/util.ts"));
    }
}

const gate_files = [_]fixture.File{ .{ .rel = "src/util.ts", .text = util_src }, .{ .rel = "state.txt", .text = "good\n" }, common.ignore };
const needs_good = "findstr /c:good state.txt";

test "commit protocol: the gate tests the tree the commit will hold, not a hand edit to another file, hidden from git status or not" {
    try skipOffWindows();
    for ([_]bool{ false, true }) |hidden| {
        var case: Plain = undefined;
        try case.init(&gate_files);
        defer case.deinit();
        const env = &case.env;
        if (hidden) _ = try env.git(&.{ "update-index", "--assume-unchanged", "state.txt" });
        try case.repo.write("state.txt", "broken\n");
        const reply = try env.call("emetgate_try", .{ .file = try env.abs("src/util.ts"), .symbol = "add", .hash = try env.hashOf("src/util.ts", "add"), .body = new_body, .message = message }, needs_good, true);
        errdefer std.debug.print("hidden {}: {s}\n", .{ hidden, reply.text });
        try testing.expect(!reply.is_error);
        try testing.expectEqualStrings("M\tsrc/util.ts", try env.git(&.{ "diff", "--name-status", "HEAD^", "HEAD" }));
        try testing.expectEqualStrings("broken\n", try env.read("state.txt"));
        try testing.expectEqualStrings("good", try env.git(&.{ "show", "HEAD:state.txt" }));
    }
}

test "commit protocol: without commits the gate still tests the working tree as it is" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&gate_files);
    defer case.deinit();
    const env = &case.env;
    try case.repo.write("state.txt", "broken\n");
    const reply = try env.call("emetgate_try", .{ .file = try env.abs("src/util.ts"), .symbol = "add", .hash = try env.hashOf("src/util.ts", "add"), .body = new_body }, needs_good, false);
    try testing.expect(reply.is_error);
    try testing.expectEqualStrings(util_src, try env.read("src/util.ts"));
}

test "commit protocol: a record that did not come from a commit cannot delete a file the replaced commit does not hold" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    const local = "kept by the user\n";
    try case.repo.write("local.txt", local);
    const head = try env.head();
    const record = try std.fmt.allocPrint(env.arena(), "{{\"version\":1,\"commit\":\"{s}\",\"base\":\"{s}\",\"branch\":\"{s}\",\"lock\":\"{s}\",\"items\":[{{\"path\":\"local.txt\",\"mode\":\"100644\",\"blob\":\"\",\"base\":\"{s}\",\"new\":\"\"}}]}}", .{
        head,
        head,
        try env.git(&.{ "symbolic-ref", "HEAD" }),
        "00" ** 32,
        &symbol.formatHash(symbol.hashOf(local)),
    });
    try case.repo.write(".emetgate/intents/0123456789abcdef.json", record);

    const report = try recover(&case);
    try testing.expectEqual(@as(usize, 1), report.commits.failed);
    try testing.expectEqualStrings("CorruptIntent", report.commits.reason.?);
    try testing.expectEqualStrings(local, try env.read("local.txt"));
    try testing.expect(!case.repo.exists(".emetgate/intents"));
}

test "commit protocol: a record with a commit id or a branch that is not one is dropped without a git call on it" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    const head = try env.head();
    const record = try std.fmt.allocPrint(env.arena(), "{{\"version\":1,\"commit\":\"{s}\",\"base\":\"--output=owned.txt\",\"branch\":\"refs/heads/main\",\"lock\":\"{s}\",\"items\":[]}}", .{ head, "00" ** 32 });
    try case.repo.write(".emetgate/intents/0123456789abcdef.json", record);
    const report = try recover(&case);
    try testing.expectEqual(@as(usize, 1), report.commits.failed);
    try testing.expect(!case.repo.exists("owned.txt"));
    try testing.expect(!case.repo.exists(".emetgate/intents"));
}
