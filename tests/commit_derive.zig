const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");
const fixture = @import("ts_fixture.zig");
const common = @import("commit_batch.zig");

const handlers = emetgate.handlers;
const telemetry = emetgate.telemetry;
const Policy = emetgate.server.Policy;
const shadow_root = emetgate.shadow_root;
const commit_store = emetgate.commit_store;
const commit_derive = emetgate.commit_derive;
const commit_plan = emetgate.commit_plan;
const git_commit = emetgate.git_commit;

const testing = std.testing;
const Plain = common.Plain;
const Env = common.Env;
const Reply = common.Reply;

const util_src = "export function add(a: number, b: number): number {\n  return a + b;\n}\n";
const new_body = "{\n  return b + a;\n}";
const other_body = "{\n  return b + a + 0;\n}";
const flag_old = "export const flag = 'aaaa';\n";
const flag_new = "export const flag = 'bbbb';\n";
const message = "fix: swap";
const util_file: fixture.File = .{ .rel = "src/util.ts", .text = util_src };
const flag_file: fixture.File = .{ .rel = "src/flag.ts", .text = flag_old };
const only_workspace: fixture.File = .{ .rel = ".gitignore", .text = ".emetgate/\n" };
const files = [_]fixture.File{ util_file, flag_file, only_workspace };

const has_new = "findstr bbbb src\\flag.ts";
const has_old = "findstr aaaa src\\flag.ts";
const red = "cmd /c exit 1";

fn skipOffWindows() !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn callWith(env: *Env, body: []const u8, policy_in: Policy) !Reply {
    var event: telemetry.Event = .{ .tool = "emetgate_try" };
    var policy = policy_in;
    policy.root = env.repo.root_abs;
    policy.language_service = env.session;
    const hash = try env.hashOf("src/util.ts", "add");
    const file = try env.abs("src/util.ts");
    const args = try common.toValue(env.arena(), .{ .file = file, .symbol = "add", .hash = hash, .body = body, .message = message });
    const result = try handlers.callTool(testing.allocator, testing.io, env.runtime, "emetgate_try", args, &event, policy);
    defer testing.allocator.free(result.text);
    return .{ .text = try env.arena().dupe(u8, result.text), .is_error = result.is_error };
}

fn swap(env: *Env, body: []const u8, test_command: []const u8) !Reply {
    return callWith(env, body, .{ .root = "", .test_command = test_command, .commit = true });
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

fn expectNamed(env: *Env, reply: Reply, before: []const u8, name: []const u8, paths: []const u8) !void {
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try testing.expect(contains(reply.text, try std.fmt.allocPrint(env.arena(), "\"error\":\"{s}\"", .{name})));
    try testing.expect(contains(reply.text, try std.fmt.allocPrint(env.arena(), "\"paths\":[{s}]", .{paths})));
    try testing.expectEqualStrings(before, try env.head());
    try testing.expectEqualStrings(util_src, try env.read("src/util.ts"));
    try testing.expectEqualStrings("", try env.git(&.{ "status", "--porcelain" }));
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

fn rewriteInPlace(path: []const u8, data: []const u8) !void {
    var file = try std.Io.Dir.cwd().openFile(testing.io, path, .{ .mode = .read_write });
    defer file.close(testing.io);
    try file.setLength(testing.io, 0);
    try file.writePositionalAll(testing.io, data, 0);
}

fn existsAbs(path: []const u8) bool {
    std.Io.Dir.accessAbsolute(testing.io, path, .{}) catch return false;
    return true;
}

test "commit derive: a file of the store rewritten in place is found before the test runs, the call names it and the next call lands on a mended store" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    const before = try env.head();
    try expectRefused(env, try swap(env, new_body, red), before);

    const location = try shadow_root.locate(testing.allocator, case.repo.root_abs, null);
    defer location.deinit(testing.allocator);
    try rewriteInPlace(try storedPath(env, location, "src/flag.ts"), "export const flag = 'bbbb'; // never proposed\n");

    const built = commit_store.rebuilds;
    const mended = commit_store.restores;
    try expectNamed(env, try swap(env, new_body, has_new), before, "GateTreeNotHead", "\"src/flag.ts\"");
    try testing.expectEqual(mended + 1, commit_store.restores);
    try testing.expectEqualStrings(flag_old, try readAbs(env, try storedPath(env, location, "src/flag.ts")));

    try expectRefused(env, try swap(env, new_body, has_new), before);
    try expectLanded(env, try swap(env, new_body, has_old), before);
    try testing.expectEqual(built, commit_store.rebuilds);
    try testing.expectEqual(mended + 1, commit_store.restores);
    try testing.expectEqualStrings("export const flag = 'aaaa';", try env.git(&.{ "show", "HEAD:src/flag.ts" }));
}

test "commit derive: rewritten bytes that git already holds as a blob are not taken into the commit either" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    try case.repo.write("src/flag.ts", flag_new);
    try byHand(env, "user: bbbb");
    try case.repo.write("src/flag.ts", flag_old);
    try byHand(env, "user: aaaa again");
    const before = try env.head();
    try expectRefused(env, try swap(env, new_body, red), before);

    const location = try shadow_root.locate(testing.allocator, case.repo.root_abs, null);
    defer location.deinit(testing.allocator);
    try rewriteInPlace(try storedPath(env, location, "src/flag.ts"), flag_new);
    try expectNamed(env, try swap(env, new_body, has_new), before, "GateTreeNotHead", "\"src/flag.ts\"");

    var copy: Policy = .{ .root = "", .test_command = has_new, .commit = true, .shadow_tree = .full_copy };
    try rewriteInPlace(try storedPath(env, location, "src/flag.ts"), flag_new);
    try expectNamed(env, try callWith(env, new_body, copy), before, "GateTreeNotHead", "\"src/flag.ts\"");
    copy.test_command = has_old;
    try expectLanded(env, try callWith(env, new_body, copy), before);
}

fn overwriteTarget(gate_abs: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}\\src\\util.ts", .{gate_abs}) catch return;
    std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = "export function add(a: number, b: number): number {\n  return 7;\n}\n" }) catch {};
}

fn removeBystander(gate_abs: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}\\src\\flag.ts", .{gate_abs}) catch return;
    std.Io.Dir.cwd().deleteFile(testing.io, path) catch {};
}

test "commit derive: a target changed in the gate tree after emetgate wrote it is refused by name, so the commit and the working file cannot part" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    const before = try env.head();
    commit_derive.probe.before_reading = overwriteTarget;
    const outcome = swap(env, new_body, common.green);
    commit_derive.probe.before_reading = null;
    try expectNamed(env, try outcome, before, "GateTreeNotHead", "\"src/util.ts\"");
    try expectLanded(env, try swap(env, new_body, common.green), before);
}

test "commit derive: a tracked file that left the gate tree before it was read is named, and the next call finds it again" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    const before = try env.head();
    try expectRefused(env, try swap(env, new_body, red), before);
    const built = commit_store.rebuilds;
    commit_derive.probe.before_reading = removeBystander;
    const outcome = swap(env, new_body, common.green);
    commit_derive.probe.before_reading = null;
    try expectNamed(env, try outcome, before, "GateTreeNotHead", "\"src/flag.ts\"");
    try expectLanded(env, try swap(env, new_body, has_old), before);
    try testing.expectEqual(built, commit_store.rebuilds);
}

test "commit derive: a tracked name that cannot be handed to git one per line is refused before any file is read" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    const root = case.repo.root_abs;
    const oid = try env.git(&.{ "rev-parse", "HEAD:src/flag.ts" });
    _ = try env.git(&.{ "-c", "core.protectNTFS=false", "update-index", "--add", "--cacheinfo", try std.fmt.allocPrint(env.arena(), "100644,{s},src/\"quoted\".ts", .{oid}) });
    _ = try env.git(&.{ "-c", "core.protectNTFS=false", "commit", "-q", "-m", "user: a name no Windows volume holds" });
    const head = try git_commit.preflight(testing.allocator, testing.io, root, &.{"src\\util.ts"});
    defer head.deinit(testing.allocator);
    const edit = [_]commit_plan.Change{.{ .rel = "src\\util.ts", .content = util_src }};
    const started = commit_derive.probe.processes;
    try testing.expectError(error.CommittedTreeIncomplete, commit_derive.derive(testing.allocator, testing.io, root, head, root, &edit, null));
    try testing.expectEqual(started, commit_derive.probe.processes);
}

test "commit derive: a file whose stored form git would change on its own is tested as HEAD checks it out and stays as HEAD has it" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ util_file, flag_file, only_workspace, .{ .rel = "notes.txt", .text = "one\r\ntwo\r\n" } });
    defer case.deinit();
    const env = &case.env;
    _ = try env.git(&.{ "config", "core.autocrlf", "false" });
    try case.repo.write("notes.txt", "one\r\ntwo\r\n");
    try case.repo.write(".gitattributes", "*.ts -text\n");
    try byHand(env, "user: notes with CRLF in the blob");
    try case.repo.write(".git/info/attributes", "*.txt text\n");
    const blob = try env.git(&.{ "rev-parse", "HEAD:notes.txt" });
    try testing.expect(!std.mem.eql(u8, blob, try env.git(&.{ "hash-object", "notes.txt" })));

    const before = try env.head();
    const mended = commit_store.restores;
    try expectLanded(env, try swap(env, new_body, "for %I in (notes.txt) do if not %~zI==10 exit 1"), before);
    try testing.expectEqual(mended + 1, commit_store.restores);
    try testing.expectEqualStrings(blob, try env.git(&.{ "rev-parse", "HEAD:notes.txt" }));
    try testing.expectEqualStrings("M\tsrc/util.ts", try env.git(&.{ "diff", "--name-status", "HEAD^", "HEAD" }));

    const location = try shadow_root.locate(testing.allocator, case.repo.root_abs, null);
    defer location.deinit(testing.allocator);
    const again = try env.head();
    try rewriteInPlace(try storedPath(env, location, "notes.txt"), "one\r\nTWO\r\n");
    const refused = try swap(env, other_body, common.green);
    errdefer std.debug.print("{s}\n", .{refused.text});
    try testing.expect(refused.is_error);
    try testing.expect(contains(refused.text, "\"error\":\"GateTreeNotHead\""));
    try testing.expect(contains(refused.text, "\"paths\":[\"notes.txt\"]"));
    try testing.expectEqualStrings(again, try env.head());
}

test "commit derive: a submodule entry and a file mode are carried into the commit as HEAD has them" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    const pinned = try env.head();
    _ = try env.git(&.{ "update-index", "--add", "--cacheinfo", try std.fmt.allocPrint(env.arena(), "160000,{s},vendor/lib", .{pinned}) });
    _ = try env.git(&.{ "update-index", "--chmod=+x", "src/flag.ts" });
    _ = try env.git(&.{ "commit", "-q", "-m", "user: a submodule entry and an executable" });
    const before = try env.head();
    const listed = try env.git(&.{ "ls-tree", "-r", "HEAD", "--", "vendor/lib", "src/flag.ts" });
    try expectLanded(env, try swap(env, new_body, common.green), before);
    try testing.expectEqualStrings(listed, try env.git(&.{ "ls-tree", "-r", "HEAD", "--", "vendor/lib", "src/flag.ts" }));
    try testing.expectEqualStrings("M\tsrc/util.ts", try env.git(&.{ "diff", "--name-status", "HEAD^", "HEAD" }));
}

test "commit derive: a small tree is read by one git process and the call's own files by one more" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    const before = try env.head();
    const started = commit_derive.probe.processes;
    try expectLanded(env, try swap(env, new_body, common.green), before);
    try testing.expectEqual(started + 2, commit_derive.probe.processes);
}

test "commit derive: a commit cannot be prepared from a tree that was not read, or for other changes than the ones read" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    const root = case.repo.root_abs;
    var request: commit_plan.Request = .{ .message = message };
    defer request.deinit(testing.allocator);
    var session: commit_plan.Session = .{ .request = &request, .head = try git_commit.preflight(testing.allocator, testing.io, root, &.{ "src\\util.ts", "src\\flag.ts" }) };
    defer session.deinit(testing.allocator);
    const edit = [_]commit_plan.Change{.{ .rel = "src\\util.ts", .content = "export const add = 1;\n" }};
    const other = [_]commit_plan.Change{.{ .rel = "src\\flag.ts", .content = flag_new }};
    try testing.expectError(error.GateTreeNotDerived, session.prepare(testing.allocator, testing.io, root, &edit));

    const gate = try std.fmt.allocPrint(env.arena(), "{s}.gate", .{root});
    defer std.Io.Dir.cwd().deleteTree(testing.io, gate) catch {};
    _ = try git_commit.checkoutTree(testing.allocator, testing.io, root, session.head.?.tree, gate);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = try std.fs.path.join(env.arena(), &.{ gate, "src", "util.ts" }), .data = edit[0].content.? });
    const found = try session.derive(testing.allocator, testing.io, root, gate, &edit, null);
    try testing.expect(found == null);
    try testing.expectError(error.GateTreeNotDerived, session.prepare(testing.allocator, testing.io, root, &other));
    try session.prepare(testing.allocator, testing.io, root, &edit);
    const commit = session.prepared.?.commit;
    try testing.expectEqualStrings("M\tsrc/util.ts", try env.git(&.{ "diff", "--name-status", "HEAD", commit }));
    try testing.expectEqualStrings("export const add = 1;", try env.git(&.{ "show", try std.fmt.allocPrint(env.arena(), "{s}:src/util.ts", .{commit}) }));
}

test "commit derive: two tracked names that differ only in case are refused with both names before any store is built, the second time too" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    const oid = try env.git(&.{ "rev-parse", "HEAD:src/flag.ts" });
    _ = try env.git(&.{ "update-index", "--add", "--cacheinfo", try std.fmt.allocPrint(env.arena(), "100644,{s},src/FLAG.ts", .{oid}) });
    _ = try env.git(&.{ "commit", "-q", "-m", "user: a second spelling" });
    const before = try env.head();
    const location = try shadow_root.locate(testing.allocator, case.repo.root_abs, null);
    defer location.deinit(testing.allocator);
    const built = commit_store.rebuilds;
    for (0..2) |_| {
        const reply = try swap(env, new_body, common.green);
        errdefer std.debug.print("{s}\n", .{reply.text});
        try testing.expect(reply.is_error);
        try testing.expect(contains(reply.text, "\"error\":\"TrackedNamesDifferOnlyInCase\""));
        try testing.expect(contains(reply.text, "\"paths\":[\"src/FLAG.ts\",\"src/flag.ts\"]"));
        try testing.expectEqualStrings(before, try env.head());
        try testing.expectEqual(built, commit_store.rebuilds);
        try testing.expect(!existsAbs(location.committed));
    }
}

test "commit derive: mending the store refuses a junction where its files are kept and writes nothing through it" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    const root = case.repo.root_abs;
    try expectRefused(env, try swap(env, new_body, red), try env.head());
    const location = try shadow_root.locate(testing.allocator, root, null);
    defer location.deinit(testing.allocator);
    const head = try git_commit.preflight(testing.allocator, testing.io, root, &.{});
    defer head.deinit(testing.allocator);

    const real = try std.fs.path.join(env.arena(), &.{ location.committed, commit_store.tree_name });
    const moved = try std.fs.path.join(env.arena(), &.{ location.committed, "moved" });
    const elsewhere = try env.abs(".git/elsewhere");
    try std.Io.Dir.cwd().createDirPath(testing.io, elsewhere);
    try std.Io.Dir.renameAbsolute(real, moved, testing.io);
    try emetgate.shadow.createJunction(testing.io, real, elsewhere);
    defer {
        std.Io.Dir.cwd().deleteDir(testing.io, real) catch {};
        std.Io.Dir.renameAbsolute(moved, real, testing.io) catch {};
    }
    try testing.expectError(error.WorkspaceIsLink, commit_store.restore(testing.allocator, testing.io, root, location.base, location.committed, head, &.{"src/flag.ts"}));
    try testing.expect(!existsAbs(try std.fs.path.join(env.arena(), &.{ elsewhere, "src" })));
}

test "commit derive: the listing of a tree is asked of git once while HEAD stays or moves by emetgate's own commit, and again when someone else moved it" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    var random: [8]u8 = undefined;
    testing.io.random(&random);
    try case.repo.write("src/flag.ts", try std.fmt.allocPrint(env.arena(), "export const flag = 'aaaa{s}';\n", .{&std.fmt.bytesToHex(random, .lower)}));
    try byHand(env, "user: a tree no other test has");
    const before = try env.head();
    const started = git_commit.listings_read;
    try expectRefused(env, try swap(env, new_body, red), before);
    try expectRefused(env, try swap(env, other_body, red), before);
    try testing.expectEqual(started + 1, git_commit.listings_read);

    try case.repo.write("src/flag.ts", flag_new);
    try byHand(env, "user: bbbb");
    const moved = try env.head();
    try expectLanded(env, try swap(env, new_body, has_new), moved);
    try testing.expectEqual(started + 2, git_commit.listings_read);

    const landed = try env.head();
    try expectLanded(env, try swap(env, other_body, has_new), landed);
    try testing.expectEqual(started + 2, git_commit.listings_read);
    try testing.expectEqualStrings("M\tsrc/util.ts", try env.git(&.{ "diff", "--name-status", "HEAD^", "HEAD" }));
    try testing.expectEqualStrings("", try env.git(&.{ "status", "--porcelain" }));
}
