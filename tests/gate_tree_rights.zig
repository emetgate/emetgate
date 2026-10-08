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
const everyone = "*S-1-1-0";

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

const modify_only = "D:PAI(A;OICI;0x1301bf;;;AU)";
const modify_without_delete_child = "D:PAI(D;;DC;;;AU)(A;OICI;0x1301bf;;;AU)";

const acl = struct {
    const sddl_revision: u32 = 1;
    const file_object: u32 = 1;
    const dacl_information: u32 = 0x4;
    const protected_dacl_information: u32 = 0x80000000;

    extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW(text: [*:0]const u16, revision: u32, descriptor: *?*anyopaque, size: ?*u32) callconv(.winapi) std.os.windows.BOOL;
    extern "advapi32" fn GetSecurityDescriptorDacl(descriptor: *anyopaque, present: *std.os.windows.BOOL, dacl: *?*anyopaque, defaulted: *std.os.windows.BOOL) callconv(.winapi) std.os.windows.BOOL;
    extern "advapi32" fn SetNamedSecurityInfoW(name: [*:0]const u16, kind: u32, information: u32, owner: ?*anyopaque, group: ?*anyopaque, dacl: ?*anyopaque, sacl: ?*anyopaque) callconv(.winapi) u32;
    extern "kernel32" fn LocalFree(memory: ?*anyopaque) callconv(.winapi) ?*anyopaque;
};

fn replaceDacl(dir_abs: []const u8, comptime sddl: []const u8) !void {
    var path_w: [std.fs.max_path_bytes:0]u16 = undefined;
    path_w[try std.unicode.wtf8ToWtf16Le(&path_w, dir_abs)] = 0;
    var descriptor: ?*anyopaque = null;
    if (acl.ConvertStringSecurityDescriptorToSecurityDescriptorW(std.unicode.utf8ToUtf16LeStringLiteral(sddl), acl.sddl_revision, &descriptor, null) == .FALSE) return error.AclSetupFailed;
    defer _ = acl.LocalFree(descriptor);
    var present: std.os.windows.BOOL = .FALSE;
    var defaulted: std.os.windows.BOOL = .FALSE;
    var dacl: ?*anyopaque = null;
    if (acl.GetSecurityDescriptorDacl(descriptor.?, &present, &dacl, &defaulted) == .FALSE or present == .FALSE) return error.AclSetupFailed;
    if (acl.SetNamedSecurityInfoW(&path_w, acl.file_object, acl.dacl_information | acl.protected_dacl_information, null, null, dacl, null) != 0) return error.AclSetupFailed;
}

fn inheritBelow(dir_abs: []const u8) !void {
    const below = try std.fmt.allocPrint(gpa, "{s}\\*", .{dir_abs});
    defer gpa.free(below);
    try icacls(&.{ below, "/reset", "/T", "/Q" });
}

fn deleteChildDenied(repo: *fixture.Repo) bool {
    return openStatus(repo.tmp.dir, "repo", nt.file_delete_child) == nt.status_access_denied;
}

fn showAcl(dir_abs: []const u8) void {
    const result = std.process.run(gpa, testing.io, .{ .argv = &.{ "icacls", dir_abs } }) catch return;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    std.debug.print("{s}", .{result.stdout});
}

fn grantModifyOnly(repo: *fixture.Repo) !void {
    try replaceDacl(repo.root_abs, modify_only);
    try inheritBelow(repo.root_abs);
    if (deleteChildDenied(repo)) return;
    std.debug.print("the directory lists Modify alone and this account still opens it with delete child:\n", .{});
    showAcl(repo.root_abs);
    try replaceDacl(repo.root_abs, modify_without_delete_child);
    if (deleteChildDenied(repo)) return;
    std.debug.print("skipped: no entry in the directory's list keeps delete child from this account\n", .{});
    return error.SkipZigTest;
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
    defer restoreInherited(repo.root_abs);
    try grantModifyOnly(&repo);
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
    defer restoreInherited(repo.root_abs);
    try icacls(&.{ repo.root_abs, "/grant", everyone ++ ":(OI)(CI)F", "/Q" });
    try grantModifyOnly(&repo);

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

test "gate tree rights: a linked directory or a directory inside it that cannot be listed is named in the reply" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try newRepo();
    defer repo.deinit();
    const cases = [_]struct { sub: []const u8, message: []const u8 }{
        .{ .sub = "node_modules", .message = "\"message\":\"access denied: node_modules (working tree)\"" },
        .{ .sub = "node_modules\\pkg", .message = "\"message\":\"access denied: node_modules/pkg (working tree)\"" },
    };
    for (cases) |case| {
        const dir_abs = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ repo.root_abs, case.sub });
        defer gpa.free(dir_abs);
        try denyListing(dir_abs);
        defer allowListing(dir_abs);
        const reply = try run(keptPolicy(repo.root_abs));
        defer gpa.free(reply);
        try expectHas(reply, "\"error\":\"ScanDenied\"");
        try expectHas(reply, case.message);
    }
}

test "gate tree rights: a repository root that cannot be listed is named in the reply" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try newRepo();
    defer repo.deinit();
    try denyListing(repo.root_abs);
    defer allowListing(repo.root_abs);

    const reply = try run(keptPolicy(repo.root_abs));
    defer gpa.free(reply);
    try expectHas(reply, "\"error\":\"ScanDenied\"");
    try expectHas(reply, "\"message\":\"access denied: . (working tree)\"");
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

test "gate tree rights: a working directory that cannot be listed is named in the reply with the reason" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try newRepo();
    defer repo.deinit();
    const src_abs = try std.fmt.allocPrint(gpa, "{s}\\src", .{repo.root_abs});
    defer gpa.free(src_abs);
    try denyListing(src_abs);
    defer allowListing(src_abs);

    const policy = keptPolicy(repo.root_abs);
    const reply = try run(policy);
    defer gpa.free(reply);
    try expectHas(reply, "\"status\":\"error\"");
    try expectHas(reply, "\"error\":\"ScanDenied\"");
    try expectHas(reply, "\"message\":\"access denied: src (working tree)\"");

    const doc = try writeDoc(policy, repo.root_abs);
    defer gpa.free(doc);
    try expectHas(doc, "\"error\":\"ScanDenied\"");
    try expectHas(doc, "\"message\":\"access denied: src (working tree)\"");

    allowListing(src_abs);
    const healed = try run(policy);
    defer gpa.free(healed);
    try expectHas(healed, "\"status\":\"ran\"");
    try expectHas(healed, kept_field);
}

const head_field = "\"gate_tree\":{\"kind\":\"kept\",\"tracked_files\":\"head\",\"private_copies\":0}";

fn tryCommitting(policy: server.Policy, root_abs: []const u8, body: []const u8) ![]u8 {
    const file = try std.fmt.allocPrint(gpa, "{s}\\calc.ts", .{root_abs});
    defer gpa.free(file);
    const hash = symbol.formatHash(try hashOfTwo(file));
    return callTool(policy, "emetgate_try", .{ .file = file, .symbol = "two", .hash = hash[0..], .body = body, .message = "fix: another two" });
}

fn gitIn(root_abs: []const u8, args: []const []const u8) !void {
    var argv: [8][]const u8 = undefined;
    argv[0] = "git";
    @memcpy(argv[1..][0..args.len], args);
    const result = try std.process.run(gpa, testing.io, .{ .argv = argv[0 .. args.len + 1], .cwd = .{ .path = root_abs } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    errdefer std.debug.print("{s}{s}", .{ result.stdout, result.stderr });
    try testing.expect(result.term == .exited and result.term.exited == 0);
}

test "gate tree rights: committing calls in a repository the user may modify but not fully control are tested on HEAD in the kept tree, before and after HEAD moves" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try newRepo();
    defer repo.deinit();
    defer restoreInherited(repo.root_abs);
    try grantModifyOnly(&repo);

    var policy = keptPolicy(repo.root_abs);
    policy.commit = true;
    const refused = try tryCommitting(policy, repo.root_abs, "{\n  return 1 + 1;\n}");
    defer gpa.free(refused);
    try expectHas(refused, "\"status\":\"rejected\"");
    try expectHas(refused, head_field);
    try expectFile(&repo, "repo/calc.ts", calc);

    policy.test_command = "findstr two notes.txt";
    const landed = try tryCommitting(policy, repo.root_abs, "{\n  return 1 + 1;\n}");
    defer gpa.free(landed);
    try expectHas(landed, "\"status\":\"committed\"");
    try expectFile(&repo, "repo/calc.ts", "export function two(): number {\n  return 1 + 1;\n}\n");

    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/notes.txt", .data = "line one\nline moved\n" });
    try gitIn(repo.root_abs, &.{ "commit", "-q", "-am", "user: notes" });
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/notes.txt", .data = notes });

    const stale = try tryCommitting(policy, repo.root_abs, "{\n  return 2 + 0;\n}");
    defer gpa.free(stale);
    try expectHas(stale, "\"status\":\"rejected\"");
    try expectHas(stale, head_field);

    policy.test_command = "findstr moved notes.txt";
    const moved = try tryCommitting(policy, repo.root_abs, "{\n  return 2 + 0;\n}");
    defer gpa.free(moved);
    try expectHas(moved, "\"status\":\"committed\"");
    try expectFile(&repo, "repo/notes.txt", notes);
}
