const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");
const fixture = @import("ts_fixture.zig");
const support = @import("runner_support.zig");
const common = @import("commit_batch.zig");

const symbol = emetgate.symbol;
const disk = emetgate.disk;
const runner = emetgate.runner;
const commit_plan = emetgate.commit_plan;

const testing = std.testing;
const Plain = common.Plain;
const Env = common.Env;
const Reply = common.Reply;

const two_src = "export function add(a: number, b: number): number {\n  return a + b;\n}\nexport function keep(x: number): number {\n  return x;\n}\n";
const two_hand = "export function add(a: number, b: number): number {\n  return a + b;\n}\nexport function keep(x: number): number {\n  return x + 0;\n}\n";
const new_body = "{\n  return b + a;\n}";
const mark = "b + a";
const message = "fix: swap";
const ignore: fixture.File = .{ .rel = ".gitignore", .text = ".emetgate/\n" };
const other_src = "export function sub(a: number, b: number): number {\n  return a - b;\n}\n";
const two_file: fixture.File = .{ .rel = "src/util.ts", .text = two_src };

fn skipOffWindows() !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn status(env: *Env) ![]const u8 {
    return env.git(&.{ "status", "--porcelain", "--untracked-files=all" });
}

fn swapCall(env: *Env) !Reply {
    return env.call("emetgate_try", .{ .file = try env.abs("src/util.ts"), .symbol = "add", .hash = try env.hashOf("src/util.ts", "add"), .body = new_body, .message = message }, common.green, true);
}

const rename_script =
    \\#!/bin/sh
    \\data=$(cat; printf x)
    \\data=${data%x}
    \\printf '%s' "$data"
    \\if [ -f .git/tap-armed ] && [ ! -f .git/tap-fired ]; then
    \\  case "$data" in
    \\    *"b + a"*) : ;;
    \\    *) : > .git/tap-fired
    \\       cp .git/tap-user src/util.ts.saving
    \\       mv src/util.ts.saving src/util.ts
    \\       echo $? > .git/tap-moved ;;
    \\  esac
    \\fi
    \\
;

test "commit window: a file renamed over the target after its measurement is kept, and the user's change is not committed under the call's message" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ two_file, ignore, .{ .rel = ".gitattributes", .text = "*.ts filter=tap\n" } });
    defer case.deinit();
    const env = &case.env;
    try case.repo.write(".git/tap.sh", rename_script);
    try case.repo.write(".git/tap-user", two_hand);
    _ = try env.git(&.{ "config", "filter.tap.clean", "sh .git/tap.sh" });
    try testing.expectEqualStrings("", try status(env));
    const before = try env.head();
    const hash = try env.hashOf("src/util.ts", "add");
    try case.repo.write(".git/tap-armed", "");

    const reply = try env.call("emetgate_try", .{ .file = try env.abs("src/util.ts"), .symbol = "add", .hash = hash, .body = new_body, .message = message }, common.green, true);
    errdefer std.debug.print("{s}\n", .{reply.text});
    if (!case.repo.exists(".git/tap-fired")) return error.RenameWasNotTried;
    try testing.expectEqualStrings("0", std.mem.trim(u8, try env.read(".git/tap-moved"), " \r\n"));
    try testing.expectEqualStrings(two_hand, try env.read("src/util.ts"));
    try testing.expect(reply.is_error);
    try testing.expect(contains(reply.text, "TargetHasUncommittedChanges"));
    try testing.expectEqualStrings(before, try env.head());
    try testing.expectEqualStrings("", try env.git(&.{ "diff", "--cached", "--name-only" }));
    try testing.expect(!case.repo.exists(".git/index.lock"));
    try testing.expect(!case.repo.exists(".emetgate/intents"));
}

fn request() commit_plan.Request {
    return .{ .message = message };
}

fn swapDirect(case: *Plain, plan: *commit_plan.Request) !void {
    const file = try case.env.abs("src/util.ts");
    const result = try runner.tryMutate(testing.allocator, testing.io, case.runtime, .{
        .file_abs = file,
        .ref_text = "add",
        .expected_hash = .{ .present = try support.hashOfRef(testing.allocator, testing.io, case.runtime, file, "add") },
        .new_body = new_body,
        .test_command = common.green,
        .commit = plan,
    });
    result.deinit(testing.allocator);
}

fn sidecars(case: *Plain) !usize {
    var dir = try case.repo.tmp.dir.openDir(testing.io, "repo/src", .{ .iterate = true });
    defer dir.close(testing.io);
    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next(testing.io)) |entry| {
        if (contains(entry.name, ".emetgate-")) count += 1;
    }
    return count;
}

test "commit window: a crash between the two moves of the file write recovers to the whole commit, by recover and by the next call" {
    try skipOffWindows();
    for ([_]bool{ true, false }) |by_recover| {
        var case: Plain = undefined;
        try case.init(&.{ two_file, ignore, .{ .rel = "src/other.ts", .text = other_src } });
        defer case.deinit();
        const env = &case.env;
        const before = try env.head();
        var plan = request();
        defer plan.deinit(testing.allocator);
        disk.crash_between_moves = true;
        defer disk.crash_between_moves = false;
        try testing.expectError(error.Crashed, swapDirect(&case, &plan));
        try testing.expect(!case.repo.exists("src/util.ts"));
        try testing.expectEqual(@as(usize, 2), try sidecars(&case));
        const made = try env.head();
        try testing.expect(!std.mem.eql(u8, before, made));

        if (by_recover) {
            const report = try disk.recover(testing.allocator, testing.io, case.repo.root_abs);
            try testing.expectEqual(@as(usize, 0), report.failed + report.commits.pending + report.commits.failed + report.commits.left);
            try testing.expectEqual(@as(usize, 1), report.commits.landed);
        } else {
            const reply = try env.call("emetgate_try", .{ .file = try env.abs("src/other.ts"), .symbol = "sub", .hash = try env.hashOf("src/other.ts", "sub"), .body = "{\n  return b - a;\n}", .message = message }, common.green, true);
            errdefer std.debug.print("{s}\n", .{reply.text});
            try testing.expect(!reply.is_error);
            try testing.expectEqualStrings(made, try env.git(&.{ "rev-parse", "HEAD^" }));
        }
        try testing.expect(contains(try env.read("src/util.ts"), mark));
        if (by_recover) try testing.expectEqualStrings(made, try env.head());
        try testing.expectEqualStrings("", try env.git(&.{ "status", "--porcelain", "--untracked-files=no" }));
        try testing.expect(!case.repo.exists(".emetgate/intents"));
        if (by_recover) {
            try testing.expectEqualStrings("", try status(env));
            try testing.expectEqual(@as(usize, 0), try sidecars(&case));
        }
    }
}

test "commit window: a crash of recover between the two moves is finished by the next recover" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ two_file, ignore });
    defer case.deinit();
    const env = &case.env;
    var plan = request();
    defer plan.deinit(testing.allocator);
    disk.crash_between_moves = true;
    defer disk.crash_between_moves = false;
    try testing.expectError(error.Crashed, swapDirect(&case, &plan));
    const made = try env.head();

    disk.crash_between_moves = true;
    try testing.expectError(error.Crashed, disk.recover(testing.allocator, testing.io, case.repo.root_abs));
    try testing.expect(!case.repo.exists("src/util.ts"));
    const report = try disk.recover(testing.allocator, testing.io, case.repo.root_abs);
    try testing.expectEqual(@as(usize, 0), report.failed + report.commits.pending + report.commits.failed + report.commits.left);
    try testing.expect(contains(try env.read("src/util.ts"), mark));
    try testing.expectEqualStrings(made, try env.head());
    try testing.expectEqualStrings("", try status(env));
    try testing.expectEqual(@as(usize, 0), try sidecars(&case));
}

const Creator = struct {
    case: *Plain,

    fn run(context: *anyopaque) void {
        const self: *Creator = @ptrCast(@alignCast(context));
        self.case.repo.write("src/util.ts", two_hand) catch {};
    }
};

test "commit window: a file created at the path between the two moves is kept, the commit stands, the reply names the path and no backup is left" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ two_file, ignore });
    defer case.deinit();
    const env = &case.env;
    const before = try env.head();
    var writer: Creator = .{ .case = &case };
    disk.between_moves = .{ .context = &writer, .run = Creator.run };
    defer disk.between_moves = null;

    const reply = try swapCall(env);
    errdefer std.debug.print("{s}\n", .{reply.text});
    disk.between_moves = null;
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings(before, try env.git(&.{ "rev-parse", "HEAD^" }));
    try testing.expect(contains(try env.git(&.{ "show", "HEAD:src/util.ts" }), mark));
    try testing.expectEqualStrings(two_hand, try env.read("src/util.ts"));
    try testing.expect(contains(reply.text, "\"commit_unfinished\":\"TargetChangedAfterCommit\""));
    try testing.expect(contains(reply.text, "\"left_as_found\":\"src/util.ts\""));
    try testing.expectEqualStrings("M src/util.ts", try status(env));
    try testing.expectEqual(@as(usize, 0), try sidecars(&case));
    try testing.expect(!case.repo.exists(".emetgate/intents"));
}

test "commit window: an entry staged after the crash on an index that was never published is left, named by recover, and the file is not written" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ two_file, ignore, .{ .rel = "src/other.ts", .text = "export const other = 1;\n" } });
    defer case.deinit();
    const env = &case.env;

    var at: Cut = .{ .target = 4 };
    const step: disk.Step = .{ .context = &at, .reached = Cut.reached };
    var plan = request();
    defer plan.deinit(testing.allocator);
    const file = try env.abs("src/util.ts");
    try testing.expectError(error.Crashed, runner.tryMutate(testing.allocator, testing.io, case.runtime, .{
        .file_abs = file,
        .ref_text = "add",
        .expected_hash = .{ .present = try support.hashOfRef(testing.allocator, testing.io, case.runtime, file, "add") },
        .new_body = new_body,
        .test_command = common.green,
        .commit = &plan,
        .commit_step = &step,
    }));
    const made = try env.head();
    try testing.expect(case.repo.exists(".git/index.lock"));
    try case.repo.tmp.dir.deleteFile(testing.io, "repo/.git/index.lock");
    try case.repo.write("src/other.ts", "export const other = 2;\n");
    _ = try env.git(&.{ "add", "src/other.ts" });
    const staged = try env.git(&.{ "rev-parse", ":src/util.ts" });

    const report = try disk.recover(testing.allocator, testing.io, case.repo.root_abs);
    try testing.expectEqual(@as(usize, 1), report.commits.left);
    try testing.expectEqualStrings("IndexChangedAfterCommit", report.commits.reason.?);
    try testing.expectEqualStrings("src/util.ts", report.commits.names());
    try testing.expectEqualStrings(staged, try env.git(&.{ "rev-parse", ":src/util.ts" }));
    try testing.expectEqualStrings(two_src, try env.read("src/util.ts"));
    try testing.expectEqualStrings(made, try env.head());
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

test "commit window: what an implicit recover left as found is named in the reply of the call that ran it" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ two_file, ignore, .{ .rel = "src/other.ts", .text = "export function sub(a: number, b: number): number {\n  return a - b;\n}\n" } });
    defer case.deinit();
    const env = &case.env;

    var at: Cut = .{ .target = 5 };
    const step: disk.Step = .{ .context = &at, .reached = Cut.reached };
    var plan = request();
    defer plan.deinit(testing.allocator);
    const file = try env.abs("src/util.ts");
    try testing.expectError(error.Crashed, runner.tryMutate(testing.allocator, testing.io, case.runtime, .{
        .file_abs = file,
        .ref_text = "add",
        .expected_hash = .{ .present = try support.hashOfRef(testing.allocator, testing.io, case.runtime, file, "add") },
        .new_body = new_body,
        .test_command = common.green,
        .commit = &plan,
        .commit_step = &step,
    }));
    try case.repo.write("src/util.ts", two_hand);

    const reply = try env.call("emetgate_try", .{ .file = try env.abs("src/other.ts"), .symbol = "sub", .hash = try env.hashOf("src/other.ts", "sub"), .body = "{\n  return b - a;\n}", .message = message }, common.green, true);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expect(contains(reply.text, "\"recovered\":\"TargetChangedAfterCommit\""));
    try testing.expect(contains(reply.text, "\"recovered_left_as_found\":\"src/util.ts\""));
    try testing.expectEqualStrings(two_hand, try env.read("src/util.ts"));
}

fn cutAfterIndex(case: *Plain) !void {
    var at: Cut = .{ .target = 5 };
    const step: disk.Step = .{ .context = &at, .reached = Cut.reached };
    var plan = request();
    defer plan.deinit(testing.allocator);
    const file = try case.env.abs("src/util.ts");
    try testing.expectError(error.Crashed, runner.tryMutate(testing.allocator, testing.io, case.runtime, .{
        .file_abs = file,
        .ref_text = "add",
        .expected_hash = .{ .present = try support.hashOfRef(testing.allocator, testing.io, case.runtime, file, "add") },
        .new_body = new_body,
        .test_command = common.green,
        .commit = &plan,
        .commit_step = &step,
    }));
}

test "commit window: recover leaves a file whose line ends the user changed after the crash, though git stores it the same" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ two_file, ignore });
    defer case.deinit();
    const env = &case.env;
    _ = try env.git(&.{ "config", "core.autocrlf", "true" });
    try testing.expectEqualStrings("", try status(env));
    try cutAfterIndex(&case);
    const with_crlf = try std.mem.replaceOwned(u8, env.arena(), two_src, "\n", "\r\n");
    try case.repo.write("src/util.ts", with_crlf);

    const report = try disk.recover(testing.allocator, testing.io, case.repo.root_abs);
    try testing.expectEqual(@as(usize, 1), report.commits.left);
    try testing.expectEqualStrings("src/util.ts", report.commits.names());
    try testing.expectEqualStrings(with_crlf, try env.read("src/util.ts"));
}

test "commit window: a record that names the hash of the user's uncommitted edit as its base cannot write over that edit" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ two_file, ignore });
    defer case.deinit();
    const env = &case.env;
    const reply = try swapCall(env);
    try testing.expect(!reply.is_error);
    const head = try env.head();
    const parent = try env.git(&.{ "rev-parse", "HEAD^" });
    const blob = try env.git(&.{ "rev-parse", "HEAD:src/util.ts" });
    const committed = try env.arena().dupe(u8, try env.read("src/util.ts"));
    try case.repo.write("src/util.ts", two_hand);

    const tag = "0123456789abcdef";
    try case.repo.write(".emetgate/intents/" ++ tag ++ ".0.new", committed);
    const record = try std.fmt.allocPrint(env.arena(), "{{\"version\":1,\"commit\":\"{s}\",\"base\":\"{s}\",\"branch\":\"{s}\",\"lock\":\"{s}\",\"items\":[{{\"path\":\"src/util.ts\",\"mode\":\"100644\",\"blob\":\"{s}\",\"base\":\"{s}\",\"new\":\"{s}\"}}]}}", .{
        head,
        parent,
        try env.git(&.{ "symbolic-ref", "HEAD" }),
        "00" ** 32,
        blob,
        &symbol.formatHash(symbol.hashOf(two_hand)),
        &symbol.formatHash(symbol.hashOf(committed)),
    });
    try case.repo.write(".emetgate/intents/" ++ tag ++ ".json", record);

    const report = try disk.recover(testing.allocator, testing.io, case.repo.root_abs);
    try testing.expectEqual(@as(usize, 1), report.commits.left);
    try testing.expectEqualStrings(two_hand, try env.read("src/util.ts"));
    try testing.expect(!case.repo.exists(".emetgate/intents"));
}

const switch_script =
    \\#!/bin/sh
    \\data=$(cat; printf x)
    \\data=${data%x}
    \\printf '%s' "$data"
    \\if [ -f .git/tap-armed ] && [ ! -f .git/tap-fired ]; then
    \\  : > .git/tap-fired
    \\  git symbolic-ref HEAD refs/heads/other
    \\  echo $? > .git/tap-switched
    \\fi
    \\
;

test "commit window: a HEAD that was pointed at another branch after the measurement puts the commit on that branch and leaves the first alone" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ two_file, ignore, .{ .rel = ".gitattributes", .text = "*.ts filter=tap\n" } });
    defer case.deinit();
    const env = &case.env;
    try case.repo.write(".git/tap.sh", switch_script);
    _ = try env.git(&.{ "config", "filter.tap.clean", "sh .git/tap.sh" });
    _ = try env.git(&.{ "branch", "other" });
    const first = try env.git(&.{ "symbolic-ref", "HEAD" });
    const before = try env.head();
    const hash = try env.hashOf("src/util.ts", "add");
    try case.repo.write(".git/tap-armed", "");

    const reply = try env.call("emetgate_try", .{ .file = try env.abs("src/util.ts"), .symbol = "add", .hash = hash, .body = new_body, .message = message }, common.green, true);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expectEqualStrings("0", std.mem.trim(u8, try env.read(".git/tap-switched"), " \r\n"));
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings(before, try env.git(&.{ "rev-parse", first }));
    try testing.expectEqualStrings(before, try env.git(&.{ "rev-parse", "refs/heads/other^" }));
    try testing.expectEqualStrings("refs/heads/other", try env.git(&.{ "symbolic-ref", "HEAD" }));
    try testing.expect(contains(try env.read("src/util.ts"), mark));
    try testing.expectEqualStrings("", try status(env));
    try testing.expect(!case.repo.exists(".git/index.lock"));
    try testing.expect(!case.repo.exists(".emetgate/intents"));
}

test "commit window: a record whose blob is not the one its commit holds at that path is refused whole" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ two_file, ignore });
    defer case.deinit();
    const env = &case.env;
    const reply = try swapCall(env);
    try testing.expect(!reply.is_error);
    const head = try env.head();
    const parent = try env.git(&.{ "rev-parse", "HEAD^" });
    const other_blob = try env.git(&.{ "rev-parse", "HEAD^:src/util.ts" });
    const committed = try env.arena().dupe(u8, try env.read("src/util.ts"));

    const tag = "0123456789abcdef";
    try case.repo.write(".emetgate/intents/" ++ tag ++ ".0.new", two_src);
    const record = try std.fmt.allocPrint(env.arena(), "{{\"version\":1,\"commit\":\"{s}\",\"base\":\"{s}\",\"branch\":\"{s}\",\"lock\":\"{s}\",\"items\":[{{\"path\":\"src/util.ts\",\"mode\":\"100644\",\"blob\":\"{s}\",\"base\":\"{s}\",\"new\":\"{s}\"}}]}}", .{
        head,
        parent,
        try env.git(&.{ "symbolic-ref", "HEAD" }),
        "00" ** 32,
        other_blob,
        &symbol.formatHash(symbol.hashOf(committed)),
        &symbol.formatHash(symbol.hashOf(two_src)),
    });
    try case.repo.write(".emetgate/intents/" ++ tag ++ ".json", record);

    const report = try disk.recover(testing.allocator, testing.io, case.repo.root_abs);
    try testing.expectEqual(@as(usize, 1), report.commits.failed);
    try testing.expectEqualStrings("CorruptIntent", report.commits.reason.?);
    try testing.expectEqualStrings(committed, try env.read("src/util.ts"));
    try testing.expectEqualStrings("", try status(env));
}

const Stager = struct {
    case: *Plain,
    at: usize,
    seen: usize = 0,
    staged: bool = false,

    fn reached(context: *anyopaque) bool {
        const self: *Stager = @ptrCast(@alignCast(context));
        self.seen += 1;
        if (self.seen != self.at) return false;
        self.case.repo.write("src/other.ts", "export function sub(a: number, b: number): number {\n  return a - b - 0;\n}\n") catch return false;
        _ = self.case.env.git(&.{ "add", "src/other.ts" }) catch return false;
        self.staged = true;
        return false;
    }
};

test "commit window: an entry staged on another file between the index copy and the lock is still staged after the commit lands" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ two_file, ignore, .{ .rel = "src/other.ts", .text = other_src } });
    defer case.deinit();
    const env = &case.env;
    const before = try env.head();
    var stager: Stager = .{ .case = &case, .at = 2 };
    const step: disk.Step = .{ .context = &stager, .reached = Stager.reached };
    var plan = request();
    defer plan.deinit(testing.allocator);
    const file = try env.abs("src/util.ts");
    const result = try runner.tryMutate(testing.allocator, testing.io, case.runtime, .{
        .file_abs = file,
        .ref_text = "add",
        .expected_hash = .{ .present = try support.hashOfRef(testing.allocator, testing.io, case.runtime, file, "add") },
        .new_body = new_body,
        .test_command = common.green,
        .commit = &plan,
        .commit_step = &step,
    });
    result.deinit(testing.allocator);
    try testing.expect(stager.staged);
    try testing.expectEqualStrings(before, try env.git(&.{ "rev-parse", "HEAD^" }));
    try testing.expect(contains(try env.read("src/util.ts"), mark));
    try testing.expectEqualStrings("src/other.ts", try env.git(&.{ "diff", "--cached", "--name-only" }));
    try testing.expectEqualStrings("M  src/other.ts", try env.git(&.{ "status", "--porcelain" }));
    try testing.expect(!case.repo.exists(".git/index.lock"));
}
