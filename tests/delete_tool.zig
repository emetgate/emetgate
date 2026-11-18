const std = @import("std");
const emetgate = @import("emetgate");
const git_fixture = @import("git_fixture.zig");
const change_atomic = @import("change_atomic.zig");

const symbol = emetgate.symbol;
const memory = emetgate.memory;
const checks = emetgate.checks;

const testing = std.testing;
const gpa = testing.allocator;
const Repo = change_atomic.Repo;
const Reply = change_atomic.Reply;

const green = "cmd /c exit 0";
const needs_app = "(if exist src\\app.js (exit 0) else (exit 1))";
const notes = "notes\n";
const draft = "draft\n";

fn hashOf(text: []const u8) [symbol.hash_hex_len]u8 {
    return symbol.formatHash(symbol.fileHash(text));
}

fn at(arena: std.mem.Allocator, repo: *Repo, rel: []const u8) ![]const u8 {
    const native = try arena.dupe(u8, rel);
    std.mem.replaceScalar(u8, native, '/', '\\');
    return std.fmt.allocPrint(arena, "{s}\\{s}", .{ repo.root_abs, native });
}

fn put(repo: *Repo, rel: []const u8, text: []const u8) !void {
    const sub = try std.fmt.allocPrint(gpa, "repo/{s}", .{rel});
    defer gpa.free(sub);
    if (std.fs.path.dirname(sub)) |parent| try repo.tmp.dir.createDirPath(testing.io, parent);
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = text });
}

fn git(repo: *Repo, args: []const []const u8) ![]u8 {
    var argv: [8][]const u8 = undefined;
    argv[0] = try git_fixture.git();
    @memcpy(argv[1..][0..args.len], args);
    const result = try emetgate.bounded_run.run(gpa, testing.io, .{ .argv = argv[0 .. args.len + 1], .cwd = .{ .path = repo.root_abs } });
    defer gpa.free(result.stderr);
    errdefer gpa.free(result.stdout);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitFailed,
        else => return error.GitFailed,
    }
    return result.stdout;
}

fn expectStatus(repo: *Repo, expected: []const u8) !void {
    try repo.expectGit(&.{ "status", "--porcelain", "--untracked-files=all" }, expected);
}

fn exists(repo: *Repo, rel: []const u8) bool {
    const sub = std.fmt.allocPrint(gpa, "repo/{s}", .{rel}) catch return true;
    defer gpa.free(sub);
    repo.tmp.dir.access(testing.io, sub, .{}) catch return false;
    return true;
}

fn errorName(reply: *Reply) ![]const u8 {
    var body = try reply.body();
    defer body.deinit();
    return reply.parsed.arena.allocator().dupe(u8, body.value.object.get("error").?.string);
}

fn expectRefused(reply: *Reply, name: []const u8) !void {
    errdefer std.debug.print("reply: {s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try testing.expectEqualStrings(name, try errorName(reply));
    try testing.expect(reply.has("\"fix\":"));
}

fn expectWritten(reply: *Reply) !void {
    errdefer std.debug.print("reply: {s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expect(reply.has("\"status\":\"written\""));
}

test "delete tool: a tracked file is deleted with its file_hash and leaves the index as git rm does" {
    var repo = try Repo.init(&.{.{ "notes.txt", notes }});
    defer repo.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const hash = hashOf(notes);
    var reply = try repo.callAs("emetgate_delete", .{ .file = try at(arena, &repo, "notes.txt"), .file_hash = @as([]const u8, &hash) }, green);
    defer reply.deinit();
    try expectWritten(&reply);
    try testing.expect(reply.has("notes.txt\",\"symbol\":\"\",\"deleted\":true}"));
    try testing.expect(!exists(&repo, "notes.txt"));
    try expectStatus(&repo, "D  notes.txt");
}

test "delete tool: an untracked file is deleted and git status stays clean" {
    var repo = try Repo.init(&.{});
    defer repo.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/draft.txt", .data = draft });
    const hash = hashOf(draft);
    var reply = try repo.callAs("emetgate_delete", .{ .files = .{.{ .file = try at(arena, &repo, "draft.txt"), .file_hash = @as([]const u8, &hash) }} }, green);
    defer reply.deinit();
    try expectWritten(&reply);
    try testing.expect(!exists(&repo, "draft.txt"));
    try expectStatus(&repo, "");
}

test "delete tool: a staged new file leaves the index too, so git does not show it as added and deleted" {
    var repo = try Repo.init(&.{});
    defer repo.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/staged.txt", .data = draft });
    gpa.free(try git(&repo, &.{ "add", "staged.txt" }));
    try expectStatus(&repo, "A  staged.txt");
    const hash = hashOf(draft);
    var reply = try repo.callAs("emetgate_delete", .{ .path = try at(arena, &repo, "staged.txt"), .hash = @as([]const u8, &hash) }, green);
    defer reply.deinit();
    try expectWritten(&reply);
    try testing.expect(!exists(&repo, "staged.txt"));
    try expectStatus(&repo, "");
}

test "delete tool: a file this session wrote through emetgate_change is deleted without a file_hash, and the index is clean after" {
    var repo = try Repo.init(&.{});
    defer repo.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var wrote = try repo.call(.{ .edits = .{.{ .file = try at(arena, &repo, "scratch.txt"), .content = draft }} }, green);
    defer wrote.deinit();
    try testing.expect(!wrote.is_error);
    try expectStatus(&repo, "A  scratch.txt");
    var reply = try repo.callAs("emetgate_delete", .{ .file = try at(arena, &repo, "scratch.txt") }, green);
    defer reply.deinit();
    try expectWritten(&reply);
    try testing.expect(!exists(&repo, "scratch.txt"));
    try expectStatus(&repo, "");
}

test "delete tool: a file without a file_hash that this session did not write is refused, and one changed since its write is too" {
    var repo = try Repo.init(&.{.{ "notes.txt", notes }});
    defer repo.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var unseen = try repo.callAs("emetgate_delete", .{ .file = try at(arena, &repo, "notes.txt") }, green);
    defer unseen.deinit();
    try expectRefused(&unseen, "MissingFileHash");
    try testing.expect(unseen.has("file_hash"));
    try testing.expect(exists(&repo, "notes.txt"));

    var wrote = try repo.call(.{ .edits = .{.{ .file = try at(arena, &repo, "scratch.txt"), .content = draft }} }, green);
    defer wrote.deinit();
    try testing.expect(!wrote.is_error);
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/scratch.txt", .data = "changed by the user\n" });
    var changed = try repo.callAs("emetgate_delete", .{ .file = try at(arena, &repo, "scratch.txt") }, green);
    defer changed.deinit();
    try expectRefused(&changed, "MissingFileHash");
    try repo.expectFile("scratch.txt", "changed by the user\n");
}

test "delete tool: a stale file_hash is refused and the file stays" {
    var repo = try Repo.init(&.{.{ "notes.txt", notes }});
    defer repo.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const stale = hashOf("an older version\n");
    var reply = try repo.callAs("emetgate_delete", .{ .file = try at(arena, &repo, "notes.txt"), .file_hash = @as([]const u8, &stale) }, green);
    defer reply.deinit();
    try expectRefused(&reply, "HashMismatch");
    try repo.expectFile("notes.txt", notes);
    try expectStatus(&repo, "");
}

test "delete tool: a missing file is refused with a fix that names the index cleanup" {
    var repo = try Repo.init(&.{});
    defer repo.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const hash = hashOf(notes);
    var reply = try repo.callAs("emetgate_delete", .{ .file = try at(arena, &repo, "gone.txt"), .file_hash = @as([]const u8, &hash) }, green);
    defer reply.deinit();
    try expectRefused(&reply, "FileNotFound");
    try testing.expect(reply.has("--cached"));
}

test "delete tool: a path outside the repository and one inside .git are refused" {
    var repo = try Repo.init(&.{});
    defer repo.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "outside.txt", .data = notes });
    const outside = try std.fmt.allocPrint(arena, "{s}\\..\\outside.txt", .{repo.root_abs});
    const hash = hashOf(notes);
    var escaped = try repo.callAs("emetgate_delete", .{ .file = outside, .file_hash = @as([]const u8, &hash) }, green);
    defer escaped.deinit();
    try expectRefused(&escaped, "FileOutsideRepo");
    try repo.tmp.dir.access(testing.io, "outside.txt", .{});

    const config = try at(arena, &repo, ".git/config");
    var internal = try repo.callAs("emetgate_delete", .{ .file = config, .file_hash = @as([]const u8, &hash) }, green);
    defer internal.deinit();
    try expectRefused(&internal, "InternalPath");
}

test "delete tool: a folder with files is refused, an empty folder is deleted, and a folder emptied by the call goes with its last file" {
    var repo = try Repo.init(&.{});
    defer repo.deinit();
    try put(&repo, "old/a.txt", notes);
    try put(&repo, "keep/b.txt", notes);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var full = try repo.callAs("emetgate_delete", .{ .file = try at(arena, &repo, "old") }, green);
    defer full.deinit();
    try expectRefused(&full, "IsDirectory");
    try testing.expect(full.has("emetgate_list"));
    try testing.expect(exists(&repo, "old/a.txt"));

    try repo.tmp.dir.createDirPath(testing.io, "repo/empty");
    var empty = try repo.callAs("emetgate_delete", .{ .file = try at(arena, &repo, "empty") }, green);
    defer empty.deinit();
    try expectWritten(&empty);
    try testing.expect(empty.has("\"folder\":true"));
    try testing.expect(!exists(&repo, "empty"));

    const hash = hashOf(notes);
    var last = try repo.callAs("emetgate_delete", .{ .file = try at(arena, &repo, "old/a.txt"), .file_hash = @as([]const u8, &hash) }, green);
    defer last.deinit();
    try expectWritten(&last);
    try testing.expect(last.has("\"emptied_folders\":[\"old\"]"));
    try testing.expect(!exists(&repo, "old"));
    try testing.expect(exists(&repo, "keep/b.txt"));
}

test "delete tool: several files are deleted all or none, whether a check before the gate or the gate itself refuses one" {
    var repo = try Repo.init(&.{ .{ "a.txt", notes }, .{ "b.txt", draft } });
    defer repo.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = hashOf(notes);
    const stale = hashOf("an older b\n");
    var before = try repo.callAs("emetgate_delete", .{ .files = .{
        .{ .file = try at(arena, &repo, "a.txt"), .file_hash = @as([]const u8, &a) },
        .{ .file = try at(arena, &repo, "b.txt"), .file_hash = @as([]const u8, &stale) },
    } }, green);
    defer before.deinit();
    try expectRefused(&before, "HashMismatch");
    try testing.expect(before.has("files[1] "));
    try testing.expect(before.has("b.txt does not have that file_hash now"));
    try repo.expectFile("a.txt", notes);
    try repo.expectFile("b.txt", draft);

    const app = hashOf(change_atomic.app_js);
    var gated = try repo.callAs("emetgate_delete", .{ .files = .{
        .{ .file = try at(arena, &repo, "a.txt"), .file_hash = @as([]const u8, &a) },
        .{ .file = try at(arena, &repo, "src/app.js"), .file_hash = @as([]const u8, &app) },
    } }, needs_app);
    defer gated.deinit();
    errdefer std.debug.print("reply: {s}\n", .{gated.text});
    try testing.expect(gated.is_error);
    try testing.expect(gated.has("\"status\":\"rejected\""));
    try repo.expectFile("a.txt", notes);
    try repo.expectFile("src/app.js", change_atomic.app_js);
    try expectStatus(&repo, "");

    const b = hashOf(draft);
    var both = try repo.callAs("emetgate_delete", .{ .files = .{
        .{ .file = try at(arena, &repo, "a.txt"), .file_hash = @as([]const u8, &a) },
        .{ .file = try at(arena, &repo, "b.txt"), .file_hash = @as([]const u8, &b) },
    } }, green);
    defer both.deinit();
    try expectWritten(&both);
    try expectStatus(&repo, "D  a.txt\nD  b.txt");
}

test "delete tool: a file named twice is refused before anything is deleted" {
    var repo = try Repo.init(&.{.{ "a.txt", notes }});
    defer repo.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = hashOf(notes);
    var reply = try repo.callAs("emetgate_delete", .{ .files = .{
        .{ .file = try at(arena, &repo, "a.txt"), .file_hash = @as([]const u8, &a) },
        .{ .file = try at(arena, &repo, "A.TXT"), .file_hash = @as([]const u8, &a) },
    } }, green);
    defer reply.deinit();
    try expectRefused(&reply, "DuplicateBatchFile");
    try testing.expect(reply.has("is named twice"));
    try repo.expectFile("a.txt", notes);
}

test "delete tool: a frozen rule refuses the delete of a file it covers and lets one outside its scope go" {
    var repo = try Repo.init(&.{});
    defer repo.deinit();
    try put(&repo, "tests/a.test.js", notes);
    try put(&repo, "docs/b.md", draft);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const id = try memory.remember(gpa, testing.io, repo.root_abs, .project, "tests are frozen", true, checks.frozen_name, "tests/");
    gpa.free(id);
    const a = hashOf(notes);
    var frozen = try repo.callAs("emetgate_delete", .{ .file = try at(arena, &repo, "tests/a.test.js"), .file_hash = @as([]const u8, &a) }, green);
    defer frozen.deinit();
    errdefer std.debug.print("reply: {s}\n", .{frozen.text});
    try testing.expect(frozen.is_error);
    try testing.expect(frozen.has("rule_violation"));
    try testing.expect(frozen.has("\"check\":\"frozen\""));
    try repo.expectFile("tests/a.test.js", notes);

    const b = hashOf(draft);
    var free = try repo.callAs("emetgate_delete", .{ .file = try at(arena, &repo, "docs/b.md"), .file_hash = @as([]const u8, &b) }, green);
    defer free.deinit();
    try expectWritten(&free);
}

test "delete tool: emetgate_change op delete still deletes a file by its file_hash" {
    var repo = try Repo.init(&.{.{ "notes.txt", notes }});
    defer repo.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const hash = hashOf(notes);
    var reply = try repo.call(.{ .edits = .{.{ .file = try at(arena, &repo, "notes.txt"), .op = "delete", .hash = @as([]const u8, &hash) }} }, green);
    defer reply.deinit();
    errdefer std.debug.print("reply: {s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expect(reply.has("\"deleted\":true"));
    try expectStatus(&repo, "D  notes.txt");
}

fn openRun(repo: *Repo, command: []const u8) ![]u8 {
    var line: std.Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    var js: std.json.Stringify = .{ .writer = &line.writer };
    try js.write(.{ .jsonrpc = "2.0", .id = 1, .method = "tools/call", .params = .{ .name = "emetgate_run", .arguments = .{ .command = command } } });
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try emetgate.server.handleMessageObserved(gpa, testing.io, repo.runtime, line.written(), &out.writer, null, .{ .root = repo.root_abs, .open_run = true });
    return out.toOwnedSlice();
}

test "delete tool: an open emetgate_run that deletes a repository file without recursion is refused before it runs, with a fix naming emetgate_delete" {
    var repo = try Repo.init(&.{.{ "notes.txt", notes }});
    defer repo.deinit();
    for ([_][]const u8{ "del notes.txt", "echo x && del notes.txt", "cmd /c \"erase notes.txt\"" }) |command| {
        const out = try openRun(&repo, command);
        defer gpa.free(out);
        errdefer std.debug.print("{s}: {s}\n", .{ command, out });
        try testing.expect(std.mem.indexOf(u8, out, "\"isError\":true") != null);
        try testing.expect(std.mem.indexOf(u8, out, "DeleteOutsideGate") != null);
        try testing.expect(std.mem.indexOf(u8, out, "emetgate_delete") != null);
        try testing.expect(std.mem.indexOf(u8, out, "notes.txt") != null);
        try repo.expectFile("notes.txt", notes);
    }
}

test "delete tool: git rm through emetgate_git_write is refused with or without force, and the fix names emetgate_delete" {
    var repo = try Repo.init(&.{ .{ "notes.txt", notes }, .{ "old.txt", draft } });
    defer repo.deinit();
    for ([_]bool{ false, true }) |force| {
        var plain = try repo.callAs("emetgate_git_write", .{ .args = .{ "rm", "notes.txt" }, .force = force }, green);
        defer plain.deinit();
        errdefer std.debug.print("reply: {s}\n", .{plain.text});
        try testing.expect(plain.is_error);
        try testing.expect(plain.has("\"status\":\"refused\""));
        try testing.expect(plain.has("\"reason\":\"deletes_files\""));
        try testing.expect(plain.has("emetgate_delete"));
        try testing.expect(plain.has("outside the gate"));
        try testing.expect(plain.has("rm --cached"));
        var recursive = try repo.callAs("emetgate_git_write", .{ .args = .{ "rm", "-rf", "--", "." }, .force = force }, green);
        defer recursive.deinit();
        errdefer std.debug.print("reply: {s}\n", .{recursive.text});
        try testing.expect(recursive.is_error);
        try testing.expect(recursive.has("\"reason\":\"deletes_files\""));
    }
    try repo.expectFile("notes.txt", notes);
    try repo.expectFile("old.txt", draft);
    try expectStatus(&repo, "");
}

test "delete tool: an index-only git rm still runs and keeps the file, and a delete through the gate commits with emetgate_git_write" {
    var repo = try Repo.init(&.{ .{ "notes.txt", notes }, .{ "a.txt", draft } });
    defer repo.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var preview = try repo.callAs("emetgate_git_write", .{ .args = .{ "rm", "-n", "notes.txt" } }, green);
    defer preview.deinit();
    errdefer std.debug.print("reply: {s}\n", .{preview.text});
    try testing.expect(!preview.is_error);
    try expectStatus(&repo, "");
    var cached = try repo.callAs("emetgate_git_write", .{ .args = .{ "rm", "--cached", "--", "notes.txt" } }, green);
    defer cached.deinit();
    errdefer std.debug.print("reply: {s}\n", .{cached.text});
    try testing.expect(!cached.is_error);
    try testing.expect(cached.has("\"status\":\"ok\""));
    try repo.expectFile("notes.txt", notes);
    try expectStatus(&repo, "D  notes.txt\n?? notes.txt");

    const hash = hashOf(draft);
    var deleted = try repo.callAs("emetgate_delete", .{ .file = try at(arena, &repo, "a.txt"), .file_hash = @as([]const u8, &hash) }, green);
    defer deleted.deinit();
    try expectWritten(&deleted);
    try expectStatus(&repo, "D  a.txt\nD  notes.txt\n?? notes.txt");
    var committed = try repo.callAs("emetgate_git_write", .{ .args = .{ "commit", "-m", "Drop a.txt and untrack notes.txt" } }, green);
    defer committed.deinit();
    errdefer std.debug.print("reply: {s}\n", .{committed.text});
    try testing.expect(!committed.is_error);
    try testing.expect(!exists(&repo, "a.txt"));
    try repo.expectFile("notes.txt", notes);
    try expectStatus(&repo, "?? notes.txt");
}
