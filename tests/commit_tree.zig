const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");
const fixture = @import("ts_fixture.zig");
const common = @import("commit_batch.zig");

const handlers = emetgate.handlers;
const telemetry = emetgate.telemetry;
const Policy = emetgate.server.Policy;
const shadow = emetgate.shadow;
const shadow_root = emetgate.shadow_root;
const commit_store = emetgate.commit_store;
const disk = emetgate.disk;

const testing = std.testing;
const Plain = common.Plain;
const Env = common.Env;
const Reply = common.Reply;

const util_src = "export function add(a: number, b: number): number {\n  return a + b;\n}\n";
const new_body = "{\n  return b + a;\n}";
const other_body = "{\n  return b + a + 0;\n}";
const flag_old = "export const flag = 'aaaa';\n";
const flag_new = "export const flag = 'bbbb';\n";
const text_lf = "a\nb\n";
const message = "fix: swap";
const util_file: fixture.File = .{ .rel = "src/util.ts", .text = util_src };
const flag_file: fixture.File = .{ .rel = "src/flag.ts", .text = flag_old };
const gone_file: fixture.File = .{ .rel = "src/gone.ts", .text = "export const gone = 1;\n" };
const text_file: fixture.File = .{ .rel = "f.txt", .text = text_lf };
const only_workspace: fixture.File = .{ .rel = ".gitignore", .text = ".emetgate/\n" };
const files = [_]fixture.File{ util_file, flag_file, gone_file, text_file, only_workspace };

const has_new = "findstr bbbb src\\flag.ts";
const text_is_crlf = "for %I in (f.txt) do if not %~zI==6 exit 1";
const text_is_lf = "for %I in (f.txt) do if not %~zI==4 exit 1";
const red = "cmd /c exit 1";

fn skipOffWindows() !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn callWith(env: *Env, body: []const u8, policy_in: Policy, with_message: bool) !Reply {
    var event: telemetry.Event = .{ .tool = "emetgate_try" };
    var policy = policy_in;
    policy.root = env.repo.root_abs;
    policy.language_service = env.session;
    const hash = try env.hashOf("src/util.ts", "add");
    const file = try env.abs("src/util.ts");
    const args = if (with_message)
        try common.toValue(env.arena(), .{ .file = file, .symbol = "add", .hash = hash, .body = body, .message = message })
    else
        try common.toValue(env.arena(), .{ .file = file, .symbol = "add", .hash = hash, .body = body });
    const result = try handlers.callTool(testing.allocator, testing.io, env.runtime, "emetgate_try", args, &event, policy);
    defer testing.allocator.free(result.text);
    return .{ .text = try env.arena().dupe(u8, result.text), .is_error = result.is_error };
}

fn swap(env: *Env, body: []const u8, test_command: []const u8) !Reply {
    return callWith(env, body, .{ .root = "", .test_command = test_command, .commit = true }, true);
}

fn expectLanded(env: *Env, reply: Reply, before: []const u8) !void {
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings(before, try env.git(&.{ "rev-parse", "HEAD^" }));
}

fn expectRefused(env: *Env, reply: Reply, before: []const u8) !void {
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try testing.expectEqualStrings(before, try env.head());
}

fn byHand(env: *Env, subject: []const u8) !void {
    _ = try env.git(&.{ "add", "-A" });
    _ = try env.git(&.{ "commit", "-q", "-m", subject });
}

fn storedPath(env: *Env, location: shadow_root.Location, rel: []const u8) ![]const u8 {
    return std.fs.path.join(env.arena(), &.{ location.committed, commit_store.tree_name, rel });
}

fn readAbs(env: *Env, path: []const u8) ![]const u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, env.arena(), .limited(1 << 20));
    return std.mem.replaceOwned(u8, env.arena(), bytes, "\r", "");
}

fn removeFile(env: *Env, rel: []const u8) !void {
    try std.Io.Dir.cwd().deleteFile(testing.io, try env.abs(rel));
}

fn existsAbs(path: []const u8) bool {
    std.Io.Dir.accessAbsolute(testing.io, path, .{}) catch return false;
    return true;
}

test "commit tree: a tracked file deleted by hand in the working tree is still in the tree the gate tests, and the deletion stays" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    try removeFile(env, "src/flag.ts");
    const before = try env.head();
    try expectLanded(env, try swap(env, new_body, "if not exist src\\flag.ts exit 1"), before);
    try testing.expect(!case.repo.exists("src/flag.ts"));
    try testing.expectEqualStrings("D src/flag.ts", std.mem.trim(u8, try env.git(&.{ "status", "--porcelain" }), " "));
}

test "commit tree: after a commit the user makes by hand the gate tests the new HEAD without building the store again" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    try expectRefused(env, try swap(env, new_body, has_new), try env.head());

    try case.repo.write("src/flag.ts", flag_new);
    try removeFile(env, "src/gone.ts");
    try case.repo.write("lib/deep/fresh.ts", "export const fresh = 1;\n");
    try byHand(env, "user: three changes");
    try case.repo.write("src/flag.ts", flag_old);
    const before = try env.head();
    const built = commit_store.rebuilds;
    const flushed = emetgate.gate_tree.flushed.load(.monotonic);
    const reply = try swap(env, new_body, "(if exist src\\gone.ts exit 1) & (if not exist lib\\deep\\fresh.ts exit 1) & findstr bbbb src\\flag.ts");
    try expectLanded(env, reply, before);
    try testing.expectEqual(built, commit_store.rebuilds);
    try testing.expectEqual(flushed + 2, emetgate.gate_tree.flushed.load(.monotonic));

    const location = try shadow_root.locate(testing.allocator, case.repo.root_abs, null);
    defer location.deinit(testing.allocator);
    try testing.expect(!existsAbs(try storedPath(env, location, "src/gone.ts")));
    try testing.expectEqualStrings(flag_old, try env.read("src/flag.ts"));
}

test "commit tree: a commit that changes .gitattributes builds the store again in the new checked-out form" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    _ = try env.git(&.{ "config", "core.autocrlf", "false" });
    try expectRefused(env, try swap(env, new_body, text_is_crlf), try env.head());

    try case.repo.write(".gitattributes", "*.txt eol=crlf\n");
    try byHand(env, "user: attributes");
    const before = try env.head();
    const built = commit_store.rebuilds;
    try expectLanded(env, try swap(env, new_body, text_is_crlf), before);
    try testing.expectEqual(built + 1, commit_store.rebuilds);
}

test "commit tree: a changed conversion setting builds the store again, and a setting that does not shape a checkout does not" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    _ = try env.git(&.{ "config", "core.autocrlf", "false" });
    try expectRefused(env, try swap(env, new_body, text_is_crlf), try env.head());

    _ = try env.git(&.{ "config", "user.name", "someone else" });
    var built = commit_store.rebuilds;
    try expectRefused(env, try swap(env, new_body, text_is_crlf), try env.head());
    try testing.expectEqual(built, commit_store.rebuilds);

    _ = try env.git(&.{ "config", "core.autocrlf", "true" });
    built = commit_store.rebuilds;
    try expectRefused(env, try swap(env, new_body, text_is_lf), try env.head());
    try testing.expectEqual(built + 1, commit_store.rebuilds);

    try case.repo.write(".git/info/attributes", "*.txt -text\n");
    built = commit_store.rebuilds;
    try expectRefused(env, try swap(env, new_body, text_is_crlf), try env.head());
    try testing.expectEqual(built + 1, commit_store.rebuilds);

    try case.repo.write(".git/info/attributes", "");
    try case.repo.write(".git/own-attributes", "");
    _ = try env.git(&.{ "config", "core.attributesfile", try env.abs(".git/own-attributes") });
    try expectRefused(env, try swap(env, new_body, text_is_lf), try env.head());
    try case.repo.write(".git/own-attributes", "*.txt -text\n");
    built = commit_store.rebuilds;
    const before = try env.head();
    try expectLanded(env, try swap(env, new_body, text_is_lf), before);
    try testing.expectEqual(built + 1, commit_store.rebuilds);
}

test "commit tree: a file missing from the store is noticed by the count and the store is built again" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    try expectRefused(env, try swap(env, new_body, red), try env.head());

    const location = try shadow_root.locate(testing.allocator, case.repo.root_abs, null);
    defer location.deinit(testing.allocator);
    try std.Io.Dir.cwd().deleteFile(testing.io, try storedPath(env, location, "src/flag.ts"));
    const built = commit_store.rebuilds;
    const before = try env.head();
    try expectLanded(env, try swap(env, new_body, "if not exist src\\flag.ts exit 1"), before);
    try testing.expectEqual(built + 1, commit_store.rebuilds);
    try testing.expectEqualStrings(flag_old, try readAbs(env, try storedPath(env, location, "src/flag.ts")));

    try std.Io.Dir.cwd().deleteFile(testing.io, try storedPath(env, location, "src/flag.ts"));
    const again = try env.head();
    const copy: Policy = .{ .root = "", .test_command = "if not exist src\\flag.ts exit 1", .commit = true, .shadow_tree = .full_copy };
    try expectLanded(env, try callWith(env, other_body, copy, true), again);
    try testing.expectEqual(built + 2, commit_store.rebuilds);
}

test "commit tree: an update of the store that stopped half way is finished by the next call" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    try expectRefused(env, try swap(env, new_body, red), try env.head());

    try case.repo.write("src/flag.ts", flag_new);
    try byHand(env, "user: flag");
    const before = try env.head();
    commit_store.crash_after_marking = true;
    const stopped = swap(env, new_body, has_new);
    commit_store.crash_after_marking = false;
    if (stopped) |reply| try testing.expect(reply.is_error) else |_| {}
    try testing.expectEqualStrings(before, try env.head());

    const location = try shadow_root.locate(testing.allocator, case.repo.root_abs, null);
    defer location.deinit(testing.allocator);
    try testing.expect(std.mem.startsWith(u8, try readAbs(env, try std.fs.path.join(env.arena(), &.{ location.committed, commit_store.state_name })), "moving "));
    try testing.expectEqualStrings(flag_old, try readAbs(env, try storedPath(env, location, "src/flag.ts")));

    const built = commit_store.rebuilds;
    try expectLanded(env, try swap(env, new_body, has_new), before);
    try testing.expectEqual(built, commit_store.rebuilds);
    try testing.expectEqualStrings(flag_new, try readAbs(env, try storedPath(env, location, "src/flag.ts")));
}

test "commit tree: with the full copy the gate still tests HEAD, for a hand edit and for a tracked file under node_modules" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ util_file, flag_file, only_workspace, .{ .rel = "node_modules/dep/flag.txt", .text = "committed\n" } });
    defer case.deinit();
    const env = &case.env;
    const copy: Policy = .{ .root = "", .test_command = "findstr byhand node_modules\\dep\\flag.txt src\\flag.ts", .commit = true, .shadow_tree = .full_copy };
    try case.repo.write("node_modules/dep/flag.txt", "byhand\n");
    try case.repo.write("node_modules/dep/loose.txt", "loose\n");
    const before = try env.head();
    const first = try callWith(env, new_body, copy, true);
    try expectRefused(env, first, before);
    try testing.expect(contains(first.text, "\"gate_tree\":{\"kind\":\"full_copy\",\"tracked_files\":\"head\",\"reason\":\"requested\"}"));

    try case.repo.write("src/flag.ts", "export const flag = 'byhand';\n");
    try expectRefused(env, try callWith(env, new_body, copy, true), before);

    var sees: Policy = copy;
    sees.test_command = "findstr committed node_modules\\dep\\flag.txt && findstr aaaa src\\flag.ts && findstr loose node_modules\\dep\\loose.txt";
    try expectLanded(env, try callWith(env, new_body, sees, true), before);
}

test "commit tree: the reply says the tracked files came from HEAD, and a call that does not commit does not" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    const committing = try swap(env, new_body, red);
    try testing.expect(committing.is_error);
    try testing.expect(contains(committing.text, "\"gate_tree\":{\"kind\":\"kept\",\"tracked_files\":\"head\",\"private_copies\":0}"));
    const plain = try callWith(env, new_body, .{ .root = "", .test_command = red }, false);
    try testing.expect(plain.is_error);
    try testing.expect(contains(plain.text, "\"gate_tree\":{\"kind\":\"kept\",\"private_copies\":0}"));
}

test "commit tree: the test command cannot write a tracked file of the tree in place, and a private path is a copy that leaves the store alone" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    const appends = "echo x>> src\\flag.ts";
    const before = try env.head();
    try expectRefused(env, try swap(env, new_body, appends), before);

    const location = try shadow_root.locate(testing.allocator, case.repo.root_abs, null);
    defer location.deinit(testing.allocator);
    try testing.expectEqualStrings(flag_old, try readAbs(env, try storedPath(env, location, "src/flag.ts")));

    var private: Policy = .{ .root = "", .test_command = appends, .commit = true };
    private.shadow_private[0] = "src";
    private.shadow_private_len = 1;
    const reply = try callWith(env, new_body, private, true);
    try expectLanded(env, reply, before);
    try testing.expectEqualStrings(flag_old, try readAbs(env, try storedPath(env, location, "src/flag.ts")));
    try testing.expectEqualStrings(flag_old, try env.read("src/flag.ts"));
}

test "commit tree: recover removes the store and the trees with the workspace" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    try expectRefused(env, try swap(env, new_body, red), try env.head());
    const location = try shadow_root.locate(testing.allocator, case.repo.root_abs, null);
    defer location.deinit(testing.allocator);
    try testing.expect(existsAbs(try storedPath(env, location, "src/flag.ts")));
    try testing.expect(existsAbs(location.committed_shadow));

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    _ = try disk.recoverWorkspace(testing.allocator, testing.io, case.repo.root_abs, null, &out.writer);
    try testing.expect(!existsAbs(location.committed));
    try testing.expect(!existsAbs(location.workspace));
    try testing.expectEqualStrings(flag_old, try env.read("src/flag.ts"));
}

test "commit tree: the run tool and a call that does not commit keep the tree of working files, and neither undoes the committing tree" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    try expectRefused(env, try swap(env, new_body, red), try env.head());
    try case.repo.write("src/flag.ts", flag_new);

    var policy: Policy = .{ .root = case.repo.root_abs, .test_command = red, .commit = true, .language_service = env.session };
    policy.allow_run[0] = has_new;
    policy.allow_run_len = 1;
    var event: telemetry.Event = .{ .tool = "emetgate_run" };
    const result = try handlers.callTool(testing.allocator, testing.io, env.runtime, "emetgate_run", try common.toValue(env.arena(), .{ .command = has_new }), &event, policy);
    defer testing.allocator.free(result.text);
    errdefer std.debug.print("{s}\n", .{result.text});
    try testing.expect(!result.is_error);
    try testing.expect(contains(result.text, "\"exit_code\":0"));

    const location = try shadow_root.locate(testing.allocator, case.repo.root_abs, null);
    defer location.deinit(testing.allocator);
    try testing.expectEqualStrings(flag_new, try readAbs(env, try std.fs.path.join(env.arena(), &.{ location.shadow, "src", "flag.ts" })));
    try testing.expectEqualStrings(flag_old, try readAbs(env, try std.fs.path.join(env.arena(), &.{ location.committed_shadow, "src", "flag.ts" })));

    try expectRefused(env, try swap(env, other_body, has_new), try env.head());

    const plain = try callWith(env, new_body, .{ .root = "", .test_command = has_new }, false);
    errdefer std.debug.print("{s}\n", .{plain.text});
    try testing.expect(!plain.is_error);
    try testing.expect(contains(try env.read("src/util.ts"), "b + a"));
    try testing.expectEqualStrings(flag_old, try readAbs(env, try std.fs.path.join(env.arena(), &.{ location.committed_shadow, "src", "flag.ts" })));
}

fn expectNamed(env: *Env, outcome: anyerror!Reply, name: []const u8, before: []const u8) !void {
    if (outcome) |reply| {
        errdefer std.debug.print("{s}\n", .{reply.text});
        try testing.expect(reply.is_error);
        try testing.expect(contains(reply.text, name));
    } else |err| try testing.expectEqualStrings(name, @errorName(err));
    try testing.expectEqualStrings(before, try env.head());
}

test "commit tree: in the kept tree a tracked file under node_modules comes from HEAD and an untracked file beside it is the working file" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ util_file, only_workspace, .{ .rel = "node_modules/dep/flag.txt", .text = "committed\n" } });
    defer case.deinit();
    const env = &case.env;
    try case.repo.write("node_modules/dep/flag.txt", "byhand\n");
    try case.repo.write("node_modules/dep/loose.txt", "loose\n");
    const before = try env.head();
    try expectLanded(env, try swap(env, new_body, "findstr committed node_modules\\dep\\flag.txt && findstr loose node_modules\\dep\\loose.txt"), before);
    try testing.expectEqualStrings("byhand\n", try env.read("node_modules/dep/flag.txt"));
}

test "commit tree: an update of the store takes attributes from HEAD, not from the working tree" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ util_file, text_file, only_workspace, .{ .rel = ".gitattributes", .text = "*.txt eol=crlf\n" } });
    defer case.deinit();
    const env = &case.env;
    _ = try env.git(&.{ "config", "core.autocrlf", "false" });
    try expectRefused(env, try swap(env, new_body, red), try env.head());

    try case.repo.write("f.txt", "a\nb\nc\n");
    try byHand(env, "user: one more line");
    try case.repo.write(".gitattributes", "*.txt -text\n");
    const before = try env.head();
    const built = commit_store.rebuilds;
    try expectLanded(env, try swap(env, new_body, "for %I in (f.txt) do if not %~zI==9 exit 1"), before);
    try testing.expectEqual(built, commit_store.rebuilds);
}

test "commit tree: two tracked names that differ only in case cannot both be stored, and the call is refused by name" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    const oid = try env.git(&.{ "rev-parse", "HEAD:src/flag.ts" });
    _ = try env.git(&.{ "update-index", "--add", "--cacheinfo", try std.fmt.allocPrint(env.arena(), "100644,{s},src/FLAG.ts", .{oid}) });
    _ = try env.git(&.{ "commit", "-q", "-m", "user: a second spelling" });
    const before = try env.head();
    try expectNamed(env, swap(env, new_body, common.green), "TrackedNamesDifferOnlyInCase", before);
}

test "commit tree: a junction where the store keeps its files is refused and nothing is written through it" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    const location = try shadow_root.locate(testing.allocator, case.repo.root_abs, null);
    defer location.deinit(testing.allocator);
    const elsewhere = try env.abs(".git/elsewhere");
    try std.Io.Dir.cwd().createDirPath(testing.io, elsewhere);
    try std.Io.Dir.cwd().createDirPath(testing.io, location.committed);
    const link = try std.fs.path.join(env.arena(), &.{ location.committed, commit_store.tree_name });
    try shadow.createJunction(testing.io, link, elsewhere);
    defer std.Io.Dir.cwd().deleteDir(testing.io, link) catch {};
    const before = try env.head();
    try expectNamed(env, swap(env, new_body, common.green), "WorkspaceIsLink", before);
    try testing.expect(!existsAbs(try std.fs.path.join(env.arena(), &.{ elsewhere, "src" })));
}

test "commit tree: a store built whole flushes every file it wrote before it is called ready" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    const flushed = emetgate.gate_tree.flushed.load(.monotonic);
    try expectRefused(env, try swap(env, new_body, red), try env.head());
    try testing.expectEqual(flushed + files.len, emetgate.gate_tree.flushed.load(.monotonic));
}

test "commit tree: a record whose commit id is an option for git is dropped before git sees it" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    const head = try env.head();
    const record = try std.fmt.allocPrint(env.arena(), "{{\"version\":1,\"commit\":\"--output=owned.txt\",\"base\":\"{s}\",\"branch\":\"refs/heads/main\",\"lock\":\"{s}\",\"items\":[]}}", .{ head, "00" ** 32 });
    try case.repo.write(".emetgate/intents/0123456789abcdef.json", record);
    const report = try disk.recover(testing.allocator, testing.io, case.repo.root_abs);
    try testing.expectEqual(@as(usize, 1), report.commits.failed);
    try testing.expect(!case.repo.exists("owned.txt"));
}

test "commit tree: the full copy refuses a store whose files are reached through a junction" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    try expectRefused(env, try swap(env, new_body, red), try env.head());
    const location = try shadow_root.locate(testing.allocator, case.repo.root_abs, null);
    defer location.deinit(testing.allocator);
    const real = try std.fs.path.join(env.arena(), &.{ location.committed, commit_store.tree_name });
    const moved = try std.fs.path.join(env.arena(), &.{ location.committed, "moved" });
    try std.Io.Dir.renameAbsolute(real, moved, testing.io);
    try shadow.createJunction(testing.io, real, moved);
    defer {
        std.Io.Dir.cwd().deleteDir(testing.io, real) catch {};
        std.Io.Dir.renameAbsolute(moved, real, testing.io) catch {};
    }
    try testing.expectError(error.WorkspaceIsLink, shadow.Shadow.prepare(testing.io, .{
        .root_abs = case.repo.root_abs,
        .base_abs = location.base,
        .shadow_abs = location.committed_shadow,
        .files = &.{},
        .tree = .full_copy,
        .committed = .{ .dir = location.committed, .count = files.len },
    }));
}

const slipped = "  return a + b; // slipped past the code rules\n";

fn callJson(env: *Env, tool: []const u8, args: anytype) !Reply {
    var text: std.Io.Writer.Allocating = .init(env.arena());
    var js: std.json.Stringify = .{ .writer = &text.writer };
    try js.write(args);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, env.arena(), text.written(), .{});
    var event: telemetry.Event = .{ .tool = tool };
    const policy: Policy = .{ .root = env.repo.root_abs, .test_command = common.green, .commit = true, .language_service = env.session };
    const result = try handlers.callTool(testing.allocator, testing.io, env.runtime, tool, parsed, &event, policy);
    defer testing.allocator.free(result.text);
    return .{ .text = try env.arena().dupe(u8, result.text), .is_error = result.is_error };
}

fn expectSourceRefused(env: *Env, reply: Reply, before: []const u8) !void {
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try testing.expect(contains(reply.text, "UseSymbolToolsForSource"));
    try testing.expectEqualStrings(before, try env.head());
    try testing.expectEqualStrings(util_src, try env.read("src/util.ts"));
    try testing.expectEqualStrings("", try env.git(&.{ "status", "--porcelain" }));
}

fn lineHash(env: *Env) ![]const u8 {
    return env.arena().dupe(u8, &emetgate.symbol.formatHash(emetgate.symbol.hashOf("  return a + b;\n")));
}

test "commit tree: a doc edit of a source file inside a committing batch is refused, writes nothing and commits nothing" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    const before = try env.head();
    const Doc = struct { kind: []const u8, file: []const u8, hash: []const u8, content: []const u8, line_start: i64, line_end: i64 };
    const reply = try callJson(env, "emetgate_try_batch", .{
        .edits = [_]Doc{.{ .kind = "doc", .file = try env.abs("src/util.ts"), .hash = try lineHash(env), .content = slipped, .line_start = 2, .line_end = 2 }},
        .message = message,
    });
    try expectSourceRefused(env, reply, before);
}

test "commit tree: a committing write_doc on a source file is refused, writes nothing and commits nothing" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    const before = try env.head();
    const reply = try callJson(env, "emetgate_write_doc", .{ .file = try env.abs("src/util.ts"), .hash = try lineHash(env), .content = slipped, .line_start = @as(i64, 2), .line_end = @as(i64, 2), .message = message });
    try expectSourceRefused(env, reply, before);
}
