const std = @import("std");
const builtin = @import("builtin");
const fixture = @import("run_fixture.zig");
const support = @import("runner_support.zig");
const server = @import("emetgate").server;
const dir_scan = @import("emetgate").dir_scan;
const symbol = @import("emetgate").symbol;
const Runtime = @import("emetgate").runtime.Runtime;

const testing = std.testing;
const gpa = testing.allocator;
const nt = dir_scan.win;

const notes = "line one\nline two\n";
const calc = "export function two(): number {\n  return 2;\n}\n";
const kept_field = "\"gate_tree\":{\"kind\":\"kept\",\"private_copies\":0}";
const authenticated_users = "*S-1-5-11";

fn newRepo() !fixture.Repo {
    return fixture.Repo.init(&.{
        .{ .name = "say.cmd", .body = "@echo off\r\necho ran\r\n" },
        .{ .name = "notes.txt", .body = notes },
        .{ .name = "calc.ts", .body = calc },
    });
}

fn icacls(args: []const []const u8) !void {
    var argv: [8][]const u8 = undefined;
    argv[0] = "icacls";
    @memcpy(argv[1..][0..args.len], args);
    const result = try std.process.run(gpa, testing.io, .{ .argv = argv[0 .. args.len + 1] });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    errdefer std.debug.print("icacls: {s}{s}\n", .{ result.stdout, result.stderr });
    switch (result.term) {
        .exited => |code| if (code != 0) return error.AclSetupFailed,
        else => return error.AclSetupFailed,
    }
}

fn grantModifyOnly(dir_abs: []const u8) !void {
    try icacls(&.{ dir_abs, "/inheritance:r", "/grant:r", authenticated_users ++ ":(OI)(CI)M", "/Q" });
}

fn restoreInherited(dir_abs: []const u8) void {
    icacls(&.{ dir_abs, "/reset", "/T", "/C", "/Q" }) catch {};
}

fn denyListing(dir_abs: []const u8) !void {
    try icacls(&.{ dir_abs, "/deny", authenticated_users ++ ":(RD)", "/Q" });
}

fn allowListing(dir_abs: []const u8) void {
    icacls(&.{ dir_abs, "/remove:d", authenticated_users, "/Q" }) catch {};
}

fn openStatus(parent: std.Io.Dir, comptime name: []const u8, access: u32) u32 {
    var handle: std.os.windows.HANDLE = undefined;
    const status = dir_scan.openRelative(parent.handle, std.unicode.utf8ToUtf16LeStringLiteral(name), access | nt.synchronize, nt.file_open, nt.option_directory | nt.option_sync, &handle);
    if (status == nt.status_success) dir_scan.close(handle);
    return status;
}

fn callTool(policy: server.Policy, tool: []const u8, args: anytype) ![]u8 {
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    var line: std.Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    var js: std.json.Stringify = .{ .writer = &line.writer };
    try js.write(.{ .jsonrpc = "2.0", .id = 1, .method = "tools/call", .params = .{ .name = tool, .arguments = args } });
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try server.handleMessageObserved(gpa, testing.io, runtime, line.written(), &out.writer, null, policy);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, out.written(), .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const result = parsed.value.object.get("result") orelse return error.NotAToolResult;
    return gpa.dupe(u8, result.object.get("content").?.array.items[0].object.get("text").?.string);
}

fn run(policy: server.Policy) ![]u8 {
    return callTool(policy, "emetgate_run", .{ .command = ".\\say.cmd" });
}

fn writeDoc(policy: server.Policy, root_abs: []const u8) ![]u8 {
    const file = try std.fmt.allocPrint(gpa, "{s}\\notes.txt", .{root_abs});
    defer gpa.free(file);
    const hash = symbol.formatHash(symbol.hashOf("line two\n"));
    return callTool(policy, "emetgate_write_doc", .{ .file = file, .hash = hash[0..], .content = "line 2\n", .line_start = @as(i64, 2), .line_end = @as(i64, 2) });
}

fn hashOfTwo(file_abs: []const u8) !symbol.Hash {
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    return support.hashOfRef(gpa, testing.io, runtime, file_abs, "two");
}

fn tryBatch(policy: server.Policy, root_abs: []const u8) ![]u8 {
    const file = try std.fmt.allocPrint(gpa, "{s}\\calc.ts", .{root_abs});
    defer gpa.free(file);
    const hash = symbol.formatHash(try hashOfTwo(file));
    const Edit = struct { file: []const u8, symbol: []const u8, hash: []const u8, body: []const u8 };
    return callTool(policy, "emetgate_try_batch", .{ .edits = [_]Edit{.{ .file = file, .symbol = "two", .hash = hash[0..], .body = "{\n  return 1 + 1;\n}" }} });
}

fn expectFile(repo: *fixture.Repo, sub_path: []const u8, expected: []const u8) !void {
    const actual = try repo.tmp.dir.readFileAlloc(testing.io, sub_path, gpa, .unlimited);
    defer gpa.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

fn expectHas(reply: []const u8, needle: []const u8) !void {
    errdefer std.debug.print("reply: {s}\nwanted: {s}\n", .{ reply, needle });
    try testing.expect(std.mem.indexOf(u8, reply, needle) != null);
}

fn keptPolicy(root_abs: []const u8) server.Policy {
    var policy = fixture.policyWith(root_abs, &.{".\\say.cmd"});
    policy.test_command = "cmd /c exit 1";
    return policy;
}

test "gate tree rights: a repository the user may modify but not fully control gets the kept tree on the first call and on later ones" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try newRepo();
    defer repo.deinit();
    try grantModifyOnly(repo.root_abs);
    defer restoreInherited(repo.root_abs);
    try testing.expectEqual(nt.status_access_denied, openStatus(repo.tmp.dir, "repo", nt.file_delete_child));
    try testing.expectEqual(nt.status_success, openStatus(repo.tmp.dir, "repo", nt.file_list_directory | nt.file_add_file | nt.delete));
    const before = try repo.fingerprint();
    defer gpa.free(before);

    const policy = keptPolicy(repo.root_abs);
    for (0..3) |_| {
        const reply = try run(policy);
        defer gpa.free(reply);
        try expectHas(reply, "\"status\":\"ran\"");
        try expectHas(reply, kept_field);
    }
    const rejected = try writeDoc(policy, repo.root_abs);
    defer gpa.free(rejected);
    try expectHas(rejected, "\"status\":\"rejected\"");
    try expectHas(rejected, kept_field);
    const again = try run(policy);
    defer gpa.free(again);
    try expectHas(again, kept_field);

    const after = try repo.fingerprint();
    defer gpa.free(after);
    try testing.expectEqualStrings(before, after);
}

test "gate tree rights: a doc write and a batch are committed in a repository the user may modify but not fully control" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try newRepo();
    defer repo.deinit();
    try grantModifyOnly(repo.root_abs);
    defer restoreInherited(repo.root_abs);
    try testing.expectEqual(nt.status_access_denied, openStatus(repo.tmp.dir, "repo", nt.file_delete_child));

    var policy = keptPolicy(repo.root_abs);
    policy.test_command = "cmd /c exit 0";
    const doc = try writeDoc(policy, repo.root_abs);
    defer gpa.free(doc);
    try expectHas(doc, "\"status\":\"committed\"");
    try expectFile(&repo, "repo/notes.txt", "line one\nline 2\n");
    const batch = try tryBatch(policy, repo.root_abs);
    defer gpa.free(batch);
    try expectHas(batch, "\"status\":\"committed\"");
    try expectFile(&repo, "repo/calc.ts", "export function two(): number {\n  return 1 + 1;\n}\n");
    const last = try run(policy);
    defer gpa.free(last);
    try expectHas(last, kept_field);
}

test "gate tree rights: a tracked file the user may read but not change is given a private copy" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try newRepo();
    defer repo.deinit();
    const file_abs = try std.fmt.allocPrint(gpa, "{s}\\notes.txt", .{repo.root_abs});
    defer gpa.free(file_abs);
    try icacls(&.{ file_abs, "/inheritance:r", "/grant:r", authenticated_users ++ ":R", "/Q" });
    defer restoreInherited(file_abs);

    const policy = keptPolicy(repo.root_abs);
    for (0..2) |_| {
        const reply = try run(policy);
        defer gpa.free(reply);
        try expectHas(reply, "\"status\":\"ran\"");
        try expectHas(reply, "\"gate_tree\":{\"kind\":\"kept\",\"private_copies\":1}");
    }
    try expectFile(&repo, "repo/notes.txt", notes);
}
