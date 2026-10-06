const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");
const fixture = @import("ts_fixture.zig");
const support = @import("runner_support.zig");
const git_fixture = @import("git_fixture.zig");
const common = @import("commit_batch.zig");

const symbol = emetgate.symbol;
const disk = emetgate.disk;
const runner = emetgate.runner;
const commit_plan = emetgate.commit_plan;
const verify_run = emetgate.verify_run;
const prompt_hook = emetgate.prompt_hook;
const prompt_words = emetgate.prompt_words;
const Verdict = emetgate.checker.Verdict;

const testing = std.testing;
const Plain = common.Plain;
const Env = common.Env;
const Reply = common.Reply;

const util_src = "export function add(a: number, b: number): number {\n  return a + b;\n}\n";
const util_hand = "export function add(a: number, b: number): number {\n  return a + b + 0;\n}\n";
const util_later = "export function add(a: number, b: number): number {\n  return a + b + 0 + 0;\n}\n";
const new_body = "{\n  return b + a;\n}";
const mark = "b + a";
const notes_src = "# Notes\n\n## Setup\n\nold\n";
const setup_old = "## Setup\n\nold\n";
const setup_new = "## Setup\n\nnew\n";
const message = "fix: swap";
const only_workspace: fixture.File = .{ .rel = ".gitignore", .text = ".emetgate/\n" };
const util_file: fixture.File = .{ .rel = "src/util.ts", .text = util_src };
const notes_file: fixture.File = .{ .rel = "notes.md", .text = notes_src };
const files = [_]fixture.File{ util_file, notes_file, only_workspace };

const after_lock = 3;
const after_branch = 4;
const after_index = 5;

fn skipOffWindows() !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
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

fn swapAt(runtime: *emetgate.runtime.Runtime, file: []const u8, stop: usize) !bool {
    var at: Cut = .{ .target = stop };
    const step: disk.Step = .{ .context = &at, .reached = Cut.reached };
    var request: commit_plan.Request = .{ .message = message };
    defer request.deinit(testing.allocator);
    const result = runner.tryMutate(testing.allocator, testing.io, runtime, .{
        .file_abs = file,
        .ref_text = "add",
        .expected_hash = .{ .present = try support.hashOfRef(testing.allocator, testing.io, runtime, file, "add") },
        .new_body = new_body,
        .test_command = common.green,
        .commit = &request,
        .commit_step = &step,
    }) catch |err| switch (err) {
        error.Crashed => return true,
        else => |e| return e,
    };
    result.deinit(testing.allocator);
    return false;
}

fn cutAt(case: *Plain, stop: usize) !void {
    try testing.expect(try swapAt(case.runtime, try case.env.abs("src/util.ts"), stop));
}

fn recover(case: *Plain) !disk.RecoverReport {
    return disk.recover(testing.allocator, testing.io, case.repo.root_abs);
}

fn status(env: *Env) ![]const u8 {
    return env.git(&.{ "status", "--porcelain", "--untracked-files=all" });
}

fn swapCall(env: *Env, rel: []const u8, body: []const u8, test_command: []const u8) !Reply {
    return env.call("emetgate_try", .{ .file = try env.abs(rel), .symbol = "add", .hash = try env.hashOf(rel, "add"), .body = body, .message = message }, test_command, true);
}

fn verdictOf(case: *Plain, rev: []const u8) !Verdict {
    return verdictWith(case, rev, common.green);
}

fn verdictWith(case: *Plain, rev: []const u8, test_command: []const u8) !Verdict {
    const result = try verify_run.run(testing.allocator, case.env.arena(), testing.io, case.runtime, case.repo.root_abs, .{ .commit = rev, .test_command = test_command });
    return result.report.verdict;
}

fn explain(case: *Plain, rev: []const u8) void {
    const result = verify_run.run(testing.allocator, case.env.arena(), testing.io, case.runtime, case.repo.root_abs, .{ .commit = rev, .test_command = common.green }) catch return;
    for (result.report.files) |f| std.debug.print("file {s}: {t} {s}\n", .{ f.path, f.outcome.verdict, f.outcome.reason });
    for (result.report.receipts) |r| std.debug.print("receipt {s}: {t} {s}\n", .{ r.operation, r.outcome.verdict, r.outcome.reason });
}

fn runOk(env: *Env, argv: []const []const u8) !void {
    const result = try std.process.run(env.arena(), testing.io, .{ .argv = argv, .cwd = .{ .path = env.repo.root_abs } });
    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("{s}: {s}{s}\n", .{ argv[0], result.stdout, result.stderr });
            return error.CommandFailed;
        },
        else => return error.CommandFailed,
    }
}

fn junction(env: *Env, link_rel: []const u8, target_rel: []const u8) !void {
    try runOk(env, &.{ "cmd.exe", "/d", "/c", "mklink", "/J", try env.abs(link_rel), try env.abs(target_rel) });
}

fn unlink(env: *Env, link_rel: []const u8) void {
    const abs = env.abs(link_rel) catch return;
    runOk(env, &.{ "cmd.exe", "/d", "/c", "rmdir", abs }) catch {};
}

test "redteam2 commit: a change the user stages on a target after a crash is still staged after recover" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    try cutAt(&case, after_index);
    try case.repo.write("src/util.ts", util_hand);
    _ = try env.git(&.{ "add", "src/util.ts" });
    const staged = try env.git(&.{ "rev-parse", ":src/util.ts" });
    try case.repo.write("src/util.ts", util_later);

    _ = try recover(&case);
    try testing.expectEqualStrings(util_later, try env.read("src/util.ts"));
    try testing.expectEqualStrings(staged, try env.git(&.{ "rev-parse", ":src/util.ts" }));
}

test "redteam2 commit: a record that names the blob of HEAD does not unstage what the user staged on that path" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    const head = try env.head();
    const blob = try env.git(&.{ "rev-parse", "HEAD:src/util.ts" });
    try case.repo.write("src/util.ts", util_hand);
    _ = try env.git(&.{ "add", "src/util.ts" });
    const staged = try env.git(&.{ "rev-parse", ":src/util.ts" });
    try case.repo.write("src/util.ts", util_later);

    const record = try std.fmt.allocPrint(env.arena(), "{{\"version\":1,\"commit\":\"{s}\",\"base\":\"{s}\",\"branch\":\"refs/heads/main\",\"lock\":\"{s}\",\"items\":[{{\"path\":\"src/util.ts\",\"mode\":\"100644\",\"blob\":\"{s}\",\"base\":\"\",\"new\":\"{s}\"}}]}}", .{ head, head, "0" ** 64, blob, "0" ** 32 });
    try case.repo.write(".emetgate/intents/clone.json", record);

    _ = try recover(&case);
    try testing.expectEqualStrings(util_later, try env.read("src/util.ts"));
    try testing.expectEqualStrings(staged, try env.git(&.{ "rev-parse", ":src/util.ts" }));
}

test "redteam2 commit: verify does not call a merge commit that carries a hand edit verified" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    const first = try env.head();
    const side = try env.git(&.{ "commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "side" });
    try case.repo.write("src/util.ts", util_hand);
    _ = try env.git(&.{ "add", "src/util.ts" });
    const tree = try env.git(&.{"write-tree"});
    const merge = try env.git(&.{ "commit-tree", tree, "-p", first, "-p", side, "-m", "merge side" });
    _ = try env.git(&.{ "update-ref", "HEAD", merge });
    try testing.expectEqualStrings("", try status(env));
    try testing.expect(contains(try env.git(&.{ "show", "HEAD:src/util.ts" }), "a + b + 0"));

    try testing.expect(try verdictOf(&case, "HEAD") != .verified);
}

test "redteam2 commit: a plain hand commit of the same edit is not verified, as a control for the merge case" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    try case.repo.write("src/util.ts", util_hand);
    _ = try env.git(&.{ "commit", "-q", "-am", "by hand" });
    try testing.expectEqual(Verdict.unverified, try verdictOf(&case, "HEAD"));
}

const flag_probe = "findstr byhand node_modules\\dep\\flag.txt";

test "redteam2 commit: a hand edit to a tracked file under node_modules is not what the gate tests" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ util_file, only_workspace, .{ .rel = "node_modules/dep/flag.txt", .text = "committed\n" } });
    defer case.deinit();
    const env = &case.env;
    try testing.expectEqualStrings("node_modules/dep/flag.txt", try env.git(&.{ "ls-files", "node_modules" }));
    const before = try env.head();

    const clean = try swapCall(env, "src/util.ts", new_body, flag_probe);
    try testing.expect(clean.is_error);
    try testing.expectEqualStrings(before, try env.head());

    try case.repo.write("node_modules/dep/flag.txt", "byhand\n");
    try testing.expectEqualStrings("M node_modules/dep/flag.txt", try status(env));
    const reply = try swapCall(env, "src/util.ts", new_body, flag_probe);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try testing.expectEqualStrings(before, try env.head());
}

test "redteam2 commit: a file created through a junction is committed at the path its bytes are on, or refused" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    try junction(env, "alias", "src");
    defer unlink(env, "alias");
    const before = try env.head();

    const reply = try env.call("emetgate_try", .{ .file = try env.abs("alias/fresh.ts"), .symbol = "fresh", .hash = "absent", .body = "export function fresh(): number {\n  return 1;\n}\n", .message = message }, common.green, true);
    errdefer std.debug.print("{s}\n", .{reply.text});
    if (reply.is_error) {
        try testing.expectEqualStrings(before, try env.head());
        try testing.expect(!case.repo.exists("src/fresh.ts"));
        return;
    }
    try testing.expect(contains(try env.git(&.{ "ls-tree", "-r", "--name-only", "HEAD" }), "src/fresh.ts"));
}

test "redteam2 commit: recover leaves the files of a directory that .emetgate/intents links to" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ util_file, only_workspace, .{ .rel = "vault/readme.txt", .text = "kept\n" }, .{ .rel = "vault/plan.txt", .text = "kept too\n" } });
    defer case.deinit();
    const env = &case.env;
    try case.repo.tmp.dir.createDirPath(testing.io, "repo/.emetgate");
    try junction(env, ".emetgate/intents", "vault");
    defer unlink(env, ".emetgate/intents");

    _ = recover(&case) catch {};
    try testing.expect(case.repo.exists("vault/readme.txt"));
    try testing.expect(case.repo.exists("vault/plan.txt"));
}

test "redteam2 commit: a commit call leaves the files of a directory that .emetgate/intents links to" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ util_file, only_workspace, .{ .rel = "vault/data.json", .text = "{}\n" }, .{ .rel = "vault/data.ts", .text = "export const data = 1;\n" }, .{ .rel = "vault/database.txt", .text = "rows\n" } });
    defer case.deinit();
    const env = &case.env;
    try case.repo.tmp.dir.createDirPath(testing.io, "repo/.emetgate");
    try junction(env, ".emetgate/intents", "vault");
    defer unlink(env, ".emetgate/intents");

    const reply = swapCall(env, "src/util.ts", new_body, common.green) catch |err| blk: {
        std.debug.print("call failed: {t}\n", .{err});
        break :blk Reply{ .text = "", .is_error = true };
    };
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(case.repo.exists("vault/data.json"));
    try testing.expect(case.repo.exists("vault/data.ts"));
    try testing.expect(case.repo.exists("vault/database.txt"));
}

test "redteam2 commit: a commit call leaves the files of a directory that .emetgate/commit links to" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ util_file, only_workspace, .{ .rel = "vault/readme.txt", .text = "kept\n" }, .{ .rel = "vault/index", .text = "not an index\n" } });
    defer case.deinit();
    const env = &case.env;
    try case.repo.tmp.dir.createDirPath(testing.io, "repo/.emetgate");
    try junction(env, ".emetgate/commit", "vault");
    defer unlink(env, ".emetgate/commit");

    const reply = swapCall(env, "src/util.ts", new_body, common.green) catch |err| blk: {
        std.debug.print("call failed: {t}\n", .{err});
        break :blk Reply{ .text = "", .is_error = true };
    };
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(case.repo.exists("vault/readme.txt"));
    try testing.expect(case.repo.exists("vault/index"));
}

test "redteam2 commit: recover leaves the files of a directory that .emetgate/journal links to" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ util_file, only_workspace, .{ .rel = "vault/readme.txt", .text = "kept\n" }, .{ .rel = "vault/a.json", .text = "{}\n" } });
    defer case.deinit();
    const env = &case.env;
    try case.repo.tmp.dir.createDirPath(testing.io, "repo/.emetgate");
    try junction(env, ".emetgate/journal", "vault");
    defer unlink(env, ".emetgate/journal");

    _ = recover(&case) catch {};
    try testing.expect(case.repo.exists("vault/readme.txt"));
    try testing.expect(case.repo.exists("vault/a.json"));
}

const flag_old = "export const flag = \"aaaa\";\n";
const flag_hand = "export const flag = \"bbbb\";\n";
const old_time = "2001-01-01T00:00:00Z";

fn setOldTime(env: *Env, rel: []const u8) !void {
    const script = try std.fmt.allocPrint(env.arena(), "(Get-Item -LiteralPath '{s}').LastWriteTimeUtc = [datetime]::Parse('{s}').ToUniversalTime()", .{ try env.abs(rel), old_time });
    try runOk(env, &.{ "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script });
}

test "redteam2 commit: a hand edit to another file that keeps its size and its time is not what the gate tests" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ util_file, only_workspace, .{ .rel = "src/flag.ts", .text = flag_old } });
    defer case.deinit();
    const env = &case.env;
    try setOldTime(env, "src/flag.ts");
    _ = try env.git(&.{ "update-index", "--refresh" });
    try testing.expectEqualStrings("", try status(env));
    const before = try env.head();

    const clean = try swapCall(env, "src/util.ts", new_body, "findstr bbbb src\\flag.ts");
    try testing.expect(clean.is_error);
    try testing.expectEqualStrings(before, try env.head());

    try case.repo.write("src/flag.ts", flag_hand);
    try setOldTime(env, "src/flag.ts");
    if ((try status(env)).len != 0) return error.SkipZigTest;
    try testing.expectEqualStrings(flag_hand, try env.read("src/flag.ts"));

    const reply = try swapCall(env, "src/util.ts", new_body, "findstr bbbb src\\flag.ts");
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try testing.expectEqualStrings(before, try env.head());
}

test "redteam2 commit: a rule line typed after a blank or a line break is still taken by the hook, not handed on" {
    for ([_][]const u8{ " /rule list", "\n/rule list", "\t/rule add \"x\" --check forbid:y --enforce", "\xef\xbb\xbf/rule list" }) |prompt| {
        errdefer std.debug.print("prompt: {s}\n", .{prompt});
        try testing.expect(prompt_hook.argumentsOf(prompt) != null);
    }
}

test "redteam2 commit: a prompt that only mentions the rule command is not taken as one" {
    for ([_][]const u8{ "please run /rule add x", "/rules", "/ruler", "/rule_add", "/RULE list", "//rule list", "/rule\x0blist", "/rule\xc2\xa0list" }) |prompt| {
        errdefer std.debug.print("prompt: {s}\n", .{prompt});
        try testing.expect(prompt_hook.argumentsOf(prompt) == null);
    }
}

test "redteam2 commit: the words of a rule line are the words a shell would hand to the rule command" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const words = try prompt_words.split(arena, " add \"two words\" --check 'forbid:a b' \"\" --enforce\r\n");
    try testing.expectEqual(@as(usize, 6), words.len);
    try testing.expectEqualStrings("add", words[0]);
    try testing.expectEqualStrings("two words", words[1]);
    try testing.expectEqualStrings("--check", words[2]);
    try testing.expectEqualStrings("forbid:a b", words[3]);
    try testing.expectEqualStrings("", words[4]);
    try testing.expectEqualStrings("--enforce", words[5]);
    try testing.expectError(error.UnterminatedQuote, prompt_words.split(arena, " add don't --check forbid:x"));
}

fn callAt(case: *Plain, root: []const u8, tool: []const u8, args: anytype, test_command: []const u8) !Reply {
    const env = &case.env;
    var event: emetgate.telemetry.Event = .{ .tool = tool };
    const policy: emetgate.server.Policy = .{ .root = root, .test_command = test_command, .commit = true };
    const result = try emetgate.handlers.callTool(testing.allocator, testing.io, case.runtime, tool, try common.toValue(env.arena(), args), &event, policy);
    defer testing.allocator.free(result.text);
    return .{ .text = try env.arena().dupe(u8, result.text), .is_error = result.is_error };
}

fn hashAt(case: *Plain, file_abs: []const u8, ref: []const u8) ![]const u8 {
    const hash = try support.hashOfRef(testing.allocator, testing.io, case.runtime, file_abs, ref);
    return case.env.arena().dupe(u8, &symbol.formatHash(hash));
}

fn expectStoredForm(env: *Env, rel: []const u8) !void {
    const path_arg = try std.fmt.allocPrint(env.arena(), "--path={s}", .{rel});
    const spec = try std.fmt.allocPrint(env.arena(), "HEAD:{s}", .{rel});
    try testing.expectEqualStrings(try env.git(&.{ "hash-object", path_arg, "--", rel }), try env.git(&.{ "rev-parse", spec }));
    try testing.expectEqualStrings("", try status(env));
    try testing.expectEqualStrings("", try env.git(&.{ "diff", "HEAD", "--name-only" }));
    try testing.expectEqualStrings("", try env.git(&.{ "diff", "--cached", "--name-only" }));
}

const extra_file: fixture.File = .{ .rel = "lib/extra.ts", .text = "export const extra = 1;\n" };

test "redteam2 commit: in a cone sparse checkout with a sparse index the gate sees the whole committed tree and the commit leaves a clean sparse tree" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ util_file, only_workspace, extra_file });
    defer case.deinit();
    const env = &case.env;
    _ = try env.git(&.{ "sparse-checkout", "init", "--cone", "--sparse-index" });
    _ = try env.git(&.{ "sparse-checkout", "set", "src" });
    try testing.expect(!case.repo.exists("lib/extra.ts"));
    try testing.expect(contains(try env.git(&.{ "ls-files", "--sparse", "-t" }), "S lib/"));
    const before = try env.head();

    const needs_extra = "if not exist lib\\extra.ts exit 1";
    const reply = try swapCall(env, "src/util.ts", new_body, needs_extra);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings(before, try env.git(&.{ "rev-parse", "HEAD^" }));
    try testing.expectEqualStrings("M\tsrc/util.ts", try env.git(&.{ "diff", "--name-status", "HEAD^", "HEAD" }));
    try testing.expectEqualStrings("", try status(env));
    try testing.expectEqualStrings("", try env.git(&.{ "diff", "--cached", "--name-only" }));
    try testing.expect(!case.repo.exists("lib"));
    try testing.expect(contains(try env.git(&.{ "ls-files", "-t" }), "S lib/extra.ts"));
    try testing.expect(contains(try env.read("src/util.ts"), mark));
    try testing.expectEqual(Verdict.verified, try verdictWith(&case, "HEAD", needs_extra));
}

test "redteam2 commit: in a sparse checkout a crash after any step recovers to no write or to the whole commit" {
    try skipOffWindows();
    var stop: usize = 1;
    var crashes: usize = 0;
    while (true) : (stop += 1) {
        var case: Plain = undefined;
        try case.init(&.{ util_file, only_workspace, extra_file });
        defer case.deinit();
        const env = &case.env;
        errdefer std.debug.print("cut after step {d}\n", .{stop});
        _ = try env.git(&.{ "sparse-checkout", "init", "--cone", "--sparse-index" });
        _ = try env.git(&.{ "sparse-checkout", "set", "src" });
        const before = try env.head();
        const crashed = try swapAt(case.runtime, try env.abs("src/util.ts"), stop);
        if (crashed) {
            crashes += 1;
            const report = try recover(&case);
            try testing.expectEqual(@as(usize, 0), report.commits.pending + report.commits.failed + report.commits.left);
        }
        const written = contains(try env.read("src/util.ts"), mark);
        const committed = contains(try env.git(&.{ "show", "HEAD:src/util.ts" }), mark);
        try testing.expectEqual(written, committed);
        try testing.expectEqual(committed, !std.mem.eql(u8, before, try env.head()));
        try testing.expectEqualStrings("", try status(env));
        try testing.expect(!case.repo.exists(".git/index.lock"));
        try testing.expect(!case.repo.exists("lib"));
        if (!crashed) break;
    }
    try testing.expect(crashes >= 5);
}

test "redteam2 commit: an index in version 4 with the untracked cache and a split index gets the commit and a clean tree" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    _ = try env.git(&.{ "config", "core.untrackedCache", "true" });
    _ = try env.git(&.{ "config", "core.splitIndex", "true" });
    _ = try env.git(&.{ "update-index", "--index-version", "4" });
    _ = try env.git(&.{ "update-index", "--split-index", "--force-untracked-cache" });
    try testing.expectEqualStrings("", try status(env));
    const before = try env.head();

    const reply = try swapCall(env, "src/util.ts", new_body, common.green);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings(before, try env.git(&.{ "rev-parse", "HEAD^" }));
    try expectStoredForm(env, "src/util.ts");
    try case.repo.write("fresh-untracked.txt", "x\n");
    try testing.expectEqualStrings("?? fresh-untracked.txt", try status(env));
    try testing.expectEqual(Verdict.verified, try verdictOf(&case, "HEAD"));
}

test "redteam2 commit: with autocrlf on a write_doc commit holds the written file in the form git stores it" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    _ = try env.git(&.{ "config", "core.autocrlf", "true" });
    const hash = try env.arena().dupe(u8, &symbol.formatHash(symbol.hashOf(setup_old)));

    const reply = try env.call("emetgate_write_doc", .{ .file = try env.abs("notes.md"), .heading = "Setup", .hash = hash, .content = "## Setup\r\n\r\nnew\r\n", .message = message }, common.green, true);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expect(contains(try env.read("notes.md"), "new\r\n"));
    try testing.expect(!contains(try env.git(&.{ "cat-file", "blob", "HEAD:notes.md" }), "\r"));
    try expectStoredForm(env, "notes.md");
}

const batch_a = "export function add(a: number, b: number): number {\n  return a + b;\n}\nexport function keep(x: number): number {\n  return x;\n}\n";

test "redteam2 commit: with autocrlf on a try_batch commit holds every file in the form git stores it and verify accepts it" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ .{ .rel = "src/a.ts", .text = batch_a }, .{ .rel = "src/old.ts", .text = "export const unused = 1;\n" }, only_workspace });
    defer case.deinit();
    const env = &case.env;
    _ = try env.git(&.{ "config", "core.autocrlf", "true" });
    const edits = .{
        .{ .file = try env.abs("src/a.ts"), .symbol = "add", .hash = try env.hashOf("src/a.ts", "add"), .body = "{\r\n  return b + a;\r\n}" },
        .{ .file = try env.abs("src/fresh.ts"), .symbol = "fresh", .hash = "absent", .body = "export function fresh(): number {\r\n  return 1;\r\n}\r\n" },
        .{ .file = try env.abs("src/old.ts"), .op = "delete", .hash = try env.fileHash("src/old.ts") },
    };

    const reply = try env.call("emetgate_try_batch", .{ .edits = edits, .message = message }, common.green, true);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expect(contains(try env.read("src/a.ts"), "\r\n"));
    try testing.expect(contains(try env.read("src/fresh.ts"), "\r\n"));
    try testing.expect(!contains(try env.git(&.{ "cat-file", "blob", "HEAD:src/fresh.ts" }), "\r"));
    try expectStoredForm(env, "src/a.ts");
    try expectStoredForm(env, "src/fresh.ts");
    try testing.expectEqual(Verdict.verified, try verdictOf(&case, "HEAD"));
}

test "redteam2 commit: in a linked worktree a crash after any step recovers to no write or to the whole commit, and the main checkout is untouched" {
    try skipOffWindows();
    var stop: usize = 1;
    var crashes: usize = 0;
    while (true) : (stop += 1) {
        var case: Plain = undefined;
        try case.init(&files);
        defer case.deinit();
        const env = &case.env;
        errdefer std.debug.print("cut after step {d}\n", .{stop});
        const main_head = try env.head();
        const linked = try std.fmt.allocPrint(env.arena(), "{s}\\..\\linked", .{case.repo.root_abs});
        _ = try env.git(&.{ "worktree", "add", "-q", "-b", "side", linked });
        const linked_abs = try case.repo.tmp.dir.realPathFileAlloc(testing.io, "linked", env.arena());
        const file = try std.fmt.allocPrint(env.arena(), "{s}\\src\\util.ts", .{linked_abs});

        const crashed = try swapAt(case.runtime, file, stop);
        if (crashed) {
            crashes += 1;
            const report = try disk.recover(testing.allocator, testing.io, linked_abs);
            try testing.expectEqual(@as(usize, 0), report.commits.pending + report.commits.failed + report.commits.left);
        }
        const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, file, env.arena(), .unlimited);
        const written = contains(text, mark);
        const committed = contains(try env.git(&.{ "show", "side:src/util.ts" }), mark);
        try testing.expectEqual(written, committed);
        try testing.expectEqual(committed, !std.mem.eql(u8, main_head, try env.git(&.{ "rev-parse", "side" })));
        try testing.expectEqualStrings("", try env.git(&.{ "-C", linked_abs, "status", "--porcelain", "--untracked-files=all" }));
        const lock = try env.git(&.{ "-C", linked_abs, "rev-parse", "--path-format=absolute", "--git-path", "index.lock" });
        try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, lock, .{}));
        try testing.expectEqualStrings(main_head, try env.head());
        try testing.expectEqualStrings("", try status(env));
        try testing.expectEqualStrings(util_src, try env.read("src/util.ts"));
        if (!crashed) break;
    }
    try testing.expect(crashes >= 5);
}

test "redteam2 commit: an amended commit that carries the receipt note along is not verified once its content differs" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    const reply = try swapCall(env, "src/util.ts", new_body, common.green);
    try testing.expect(!reply.is_error);
    try testing.expectEqual(Verdict.verified, try verdictOf(&case, "HEAD"));
    _ = try env.git(&.{ "config", "notes.rewriteRef", "refs/notes/emetgate" });

    try case.repo.write("notes.md", "# Notes\n\nby hand\n");
    _ = try env.git(&.{ "add", "notes.md" });
    _ = try env.git(&.{ "commit", "-q", "--amend", "--no-edit" });
    _ = try env.git(&.{ "notes", "--ref=emetgate", "show", "HEAD" });
    try testing.expect(try verdictOf(&case, "HEAD") != .verified);

    try case.repo.write("src/util.ts", "export function add(a: number, b: number): number {\n  return b + a + 1;\n}\n");
    _ = try env.git(&.{ "add", "src/util.ts" });
    _ = try env.git(&.{ "commit", "-q", "--amend", "--no-edit" });
    _ = try env.git(&.{ "notes", "--ref=emetgate", "show", "HEAD" });
    try testing.expect(try verdictOf(&case, "HEAD") != .verified);
}

test "redteam2 commit: recover after the index was published finishes on a detached HEAD and drops the record after a forced switch to another branch" {
    try skipOffWindows();
    {
        var case: Plain = undefined;
        try case.init(&files);
        defer case.deinit();
        const env = &case.env;
        try cutAt(&case, after_index);
        const made = try env.head();
        _ = try env.git(&.{ "checkout", "-q", "--detach" });
        const report = try recover(&case);
        try testing.expectEqual(@as(usize, 0), report.commits.pending + report.commits.failed + report.commits.left);
        try testing.expectEqualStrings(made, try env.head());
        try testing.expect(contains(try env.read("src/util.ts"), mark));
        try testing.expectEqualStrings("", try status(env));
        try testing.expect(!case.repo.exists(".emetgate/intents"));
    }
    {
        var case: Plain = undefined;
        try case.init(&files);
        defer case.deinit();
        const env = &case.env;
        _ = try env.git(&.{ "config", "core.autocrlf", "false" });
        const first = try env.git(&.{ "symbolic-ref", "--short", "HEAD" });
        _ = try env.git(&.{ "branch", "other" });
        try cutAt(&case, after_index);
        const made = try env.head();
        _ = try env.git(&.{ "checkout", "-q", "-f", "other" });
        const report = try recover(&case);
        try testing.expectEqual(@as(usize, 0), report.commits.pending + report.commits.failed + report.commits.written);
        try testing.expectEqualStrings(util_src, try env.read("src/util.ts"));
        try testing.expectEqualStrings("", try status(env));
        try testing.expectEqualStrings(made, try env.git(&.{ "rev-parse", first }));
        try testing.expect(!case.repo.exists(".emetgate/intents"));
    }
}

test "redteam2 commit: under a Git LFS filter the commit holds the pointer git stores and verify accepts the commit" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ util_file, only_workspace, .{ .rel = ".gitattributes", .text = "*.ts filter=lfs diff=lfs merge=lfs -text\n" } });
    defer case.deinit();
    const env = &case.env;
    const pointer = "version https://git-lfs";
    if (!contains(env.git(&.{ "cat-file", "blob", "HEAD:src/util.ts" }) catch return error.SkipZigTest, pointer)) return error.SkipZigTest;
    try testing.expectEqualStrings("", try status(env));
    const before = try env.head();

    const reply = try swapCall(env, "src/util.ts", new_body, common.green);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings(before, try env.git(&.{ "rev-parse", "HEAD^" }));
    try testing.expect(contains(try env.read("src/util.ts"), mark));
    try testing.expect(contains(try env.git(&.{ "cat-file", "blob", "HEAD:src/util.ts" }), pointer));
    try expectStoredForm(env, "src/util.ts");
    errdefer explain(&case, "HEAD");
    try testing.expectEqual(Verdict.verified, try verdictOf(&case, "HEAD"));
}

test "redteam2 commit: inside a submodule the commit lands in the submodule, a crash recovers there, and the outer repository gets no commit" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ notes_file, only_workspace });
    defer case.deinit();
    const env = &case.env;
    try case.repo.tmp.dir.createDirPath(testing.io, "other/src");
    try case.repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "other/src/util.ts", .data = util_src });
    try case.repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "other/.gitignore", .data = ".emetgate/\n" });
    const other_abs = try case.repo.tmp.dir.realPathFileAlloc(testing.io, "other", env.arena());
    try git_fixture.initRepo(other_abs);
    try support.Repo.git(other_abs, &.{ "add", "." });
    try support.Repo.git(other_abs, &.{ "commit", "-q", "-m", "init" });
    _ = try env.git(&.{ "-c", "protocol.file.allow=always", "submodule", "add", "-q", other_abs, "sub" });
    _ = try env.git(&.{ "commit", "-q", "-m", "add sub" });
    const outer = try env.head();
    const sub_abs = try env.abs("sub");
    _ = try env.git(&.{ "-C", sub_abs, "config", "user.email", "t@t" });
    _ = try env.git(&.{ "-C", sub_abs, "config", "user.name", "t" });
    _ = try env.git(&.{ "-C", sub_abs, "symbolic-ref", "HEAD" });
    const inner = try env.git(&.{ "-C", sub_abs, "rev-parse", "HEAD" });
    const file = try env.abs("sub/src/util.ts");

    try testing.expect(try swapAt(case.runtime, file, after_branch));
    const report = try disk.recover(testing.allocator, testing.io, sub_abs);
    try testing.expectEqual(@as(usize, 0), report.commits.pending + report.commits.failed + report.commits.left);
    try testing.expectEqualStrings(inner, try env.git(&.{ "-C", sub_abs, "rev-parse", "HEAD^" }));
    try testing.expect(contains(try env.read("sub/src/util.ts"), mark));
    try testing.expectEqualStrings("", try env.git(&.{ "-C", sub_abs, "status", "--porcelain", "--untracked-files=all" }));

    const reply = try callAt(&case, sub_abs, "emetgate_try", .{ .file = file, .symbol = "add", .hash = try hashAt(&case, file, "add"), .body = "{\n  return a + b + 2;\n}", .message = message }, common.green);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings(inner, try env.git(&.{ "-C", sub_abs, "rev-parse", "HEAD~2" }));
    try testing.expectEqualStrings("", try env.git(&.{ "-C", sub_abs, "status", "--porcelain", "--untracked-files=all" }));
    try testing.expectEqualStrings(outer, try env.head());
    try testing.expectEqualStrings("M sub", try status(env));
}

const tap_script =
    \\#!/bin/sh
    \\data=$(cat; printf x)
    \\data=${data%x}
    \\printf '%s' "$data"
    \\if [ -f .git/tap-armed ] && [ ! -f .git/tap-fired ]; then
    \\  case "$data" in
    \\    *"b + a"*) : > .git/tap-seen ;;
    \\    *) if [ -f .git/tap-seen ]; then
    \\         : > .git/tap-fired
    \\         if [ -f .git/tap-index ]; then
    \\           git update-index --cacheinfo 100644,$(git hash-object -w .git/tap-user),src/util.ts
    \\         else
    \\           cp .git/tap-user src/util.ts
    \\         fi
    \\       fi ;;
    \\  esac
    \\fi
    \\
;

test "redteam2 commit: a hand edit that lands on the target between its last measurement and the write is kept" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ util_file, only_workspace, .{ .rel = ".gitattributes", .text = "*.ts filter=tap\n" } });
    defer case.deinit();
    const env = &case.env;
    try case.repo.write(".git/tap.sh", tap_script);
    try case.repo.write(".git/tap-user", util_hand);
    _ = try env.git(&.{ "config", "filter.tap.clean", "sh .git/tap.sh" });
    try testing.expectEqualStrings("", try status(env));
    try testing.expectEqualStrings(try env.git(&.{ "rev-parse", "HEAD:src/util.ts" }), try env.git(&.{ "hash-object", "--", "src/util.ts" }));
    try case.repo.write(".git/tap-armed", "");

    const reply = try swapCall(env, "src/util.ts", new_body, common.green);
    errdefer std.debug.print("{s}\n", .{reply.text});
    if (!case.repo.exists(".git/tap-fired")) return error.HandEditWasNotPlaced;
    try testing.expectEqualStrings(util_hand, try env.read("src/util.ts"));
}

test "redteam2 commit: a change staged on the target between its last measurement and the lock is still staged afterwards" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ util_file, only_workspace, .{ .rel = ".gitattributes", .text = "*.ts filter=tap\n" } });
    defer case.deinit();
    const env = &case.env;
    try case.repo.write(".git/tap.sh", tap_script);
    try case.repo.write(".git/tap-user", util_hand);
    try case.repo.write(".git/tap-index", "");
    _ = try env.git(&.{ "config", "filter.tap.clean", "sh .git/tap.sh" });
    try testing.expectEqualStrings("", try status(env));
    const staged = try env.git(&.{ "hash-object", "--", ".git/tap-user" });
    const before = try env.head();
    try case.repo.write(".git/tap-armed", "");

    const reply = try swapCall(env, "src/util.ts", new_body, common.green);
    errdefer std.debug.print("{s}\n", .{reply.text});
    if (!case.repo.exists(".git/tap-fired")) return error.StagedChangeWasNotPlaced;
    if (reply.is_error) try testing.expectEqualStrings(before, try env.head());
    try testing.expectEqualStrings(staged, try env.git(&.{ "rev-parse", ":src/util.ts" }));
}

const prefix_rule = "message:cmd:findstr /l /b /g:allowed.txt .emetgate\\COMMIT_EDITMSG";
const loose_message = "wip: loosen the checker";

fn adoptRule(case: *Plain, check: []const u8) !void {
    const id = try emetgate.memory.remember(testing.allocator, testing.io, case.repo.root_abs, .project, "checked by a command", true, check, null);
    testing.allocator.free(id);
}

test "redteam2 commit: a message command that reads a tracked file refuses a message the file did not allow, as a control" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ util_file, only_workspace, .{ .rel = "allowed.txt", .text = "fix:" } });
    defer case.deinit();
    const env = &case.env;
    try adoptRule(&case, prefix_rule);
    const before = try env.head();

    const refused = try env.call("emetgate_try", .{ .file = try env.abs("src/util.ts"), .symbol = "add", .hash = try env.hashOf("src/util.ts", "add"), .body = new_body, .message = loose_message }, common.green, true);
    errdefer std.debug.print("{s}\n", .{refused.text});
    try testing.expect(refused.is_error);
    try testing.expect(contains(refused.text, "rule_violation"));
    try testing.expectEqualStrings(before, try env.head());

    const accepted = try swapCall(env, "src/util.ts", new_body, common.green);
    errdefer std.debug.print("{s}\n", .{accepted.text});
    try testing.expect(!accepted.is_error);
}

test "redteam2 commit: a call cannot loosen the file its message command reads in the same commit that message is judged for" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ util_file, only_workspace, .{ .rel = "allowed.txt", .text = "fix:" } });
    defer case.deinit();
    const env = &case.env;
    try adoptRule(&case, prefix_rule);
    const before = try env.head();
    const hash = try env.arena().dupe(u8, &symbol.formatHash(symbol.hashOf("fix:")));

    const reply = try env.call("emetgate_write_doc", .{ .file = try env.abs("allowed.txt"), .line_start = std.json.Value{ .integer = 1 }, .line_end = std.json.Value{ .integer = 1 }, .hash = hash, .content = "wip:", .message = loose_message }, common.green, true);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try testing.expectEqualStrings(before, try env.head());
    try testing.expectEqualStrings("fix:", try env.read("allowed.txt"));
}

fn attrib(env: *Env, flag: []const u8, rel: []const u8) void {
    const abs = env.abs(rel) catch return;
    runOk(env, &.{ "attrib.exe", flag, abs }) catch {};
}

test "redteam2 commit: a read-only index file ends in a refusal or a whole commit, never in a held lock" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    const before = try env.head();
    attrib(env, "+R", ".git/index");
    defer {
        attrib(env, "-R", ".git/index");
        attrib(env, "-R", ".git/index.lock");
    }

    const reply = try swapCall(env, "src/util.ts", new_body, common.green);
    errdefer std.debug.print("{s}\n", .{reply.text});
    const moved = !std.mem.eql(u8, before, try env.head());
    const written = contains(try env.read("src/util.ts"), mark);
    try testing.expectEqual(moved, written);
    try testing.expect(!case.repo.exists(".git/index.lock"));
    try testing.expect(!contains(reply.text, "commit_unfinished"));
}

const Reader = struct {
    root: []const u8,
    stop: std.atomic.Value(bool) = .init(false),
    runs: std.atomic.Value(usize) = .init(0),

    fn loop(self: *Reader) void {
        while (!self.stop.load(.acquire)) {
            for ([_][]const []const u8{ &.{ "git", "status", "--porcelain" }, &.{ "git", "diff", "--cached", "--name-only" }, &.{ "git", "ls-files", "-s" } }) |argv| {
                const result = std.process.run(std.heap.page_allocator, testing.io, .{ .argv = argv, .cwd = .{ .path = self.root } }) catch continue;
                std.heap.page_allocator.free(result.stdout);
                std.heap.page_allocator.free(result.stderr);
            }
            _ = self.runs.fetchAdd(1, .monotonic);
        }
    }
};

test "redteam2 commit: while another process keeps reading the index every call is refused clean or lands whole" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    var reader: Reader = .{ .root = case.repo.root_abs };
    const thread = try std.Thread.spawn(.{}, Reader.loop, .{&reader});
    var joined = false;
    defer if (!joined) {
        reader.stop.store(true, .release);
        thread.join();
    };

    const bodies = [_][]const u8{ "{\n  return b + a;\n}", "{\n  return a + b;\n}" };
    var landed: usize = 0;
    var refused: usize = 0;
    while (landed < 8) {
        const before = try env.head();
        const body = bodies[landed % 2];
        const reply = try swapCall(env, "src/util.ts", body, common.green);
        errdefer std.debug.print("after {d} landed: {s}\n", .{ landed, reply.text });
        const head = try env.head();
        if (reply.is_error) {
            refused += 1;
            try testing.expectEqualStrings(before, head);
            try testing.expect(contains(reply.text, "IndexLocked") or contains(reply.text, "IndexChanged"));
            if (refused > 200) return error.NeverLanded;
            continue;
        }
        landed += 1;
        try testing.expect(!contains(reply.text, "commit_unfinished"));
        try testing.expectEqualStrings(before, try env.git(&.{ "rev-parse", "HEAD^" }));
        try testing.expectEqualStrings(try env.git(&.{ "hash-object", "--", "src/util.ts" }), try env.git(&.{ "rev-parse", "HEAD:src/util.ts" }));
    }
    reader.stop.store(true, .release);
    thread.join();
    joined = true;
    try testing.expect(reader.runs.load(.monotonic) > 0);
    try testing.expectEqual(@as(usize, 8), landed);
    try testing.expect(!case.repo.exists(".git/index.lock"));
    try testing.expect(!case.repo.exists(".emetgate/intents"));
    try testing.expectEqualStrings("", try status(env));
    try testing.expectEqualStrings("", try env.git(&.{ "diff", "--cached", "--name-only" }));
}
