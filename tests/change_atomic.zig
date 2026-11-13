const std = @import("std");
const builtin = @import("builtin");
const git_fixture = @import("git_fixture.zig");
const server = @import("emetgate").server;
const telemetry = @import("emetgate").telemetry;
const memory = @import("emetgate").memory;
const symbol = @import("emetgate").symbol;
const Runtime = @import("emetgate").runtime.Runtime;
const KnownFiles = @import("emetgate").known_files.KnownFiles;

const testing = std.testing;
const gpa = testing.allocator;
const Value = std.json.Value;

pub const app_js = "export function total(a, b) {\n  return a + b;\n}\n";
const fails_on_broken = "(findstr BROKEN src\\app.js >nul && exit 1 || exit 0)";
const green = "cmd /c exit 0";

pub const Reply = struct {
    parsed: std.json.Parsed(Value),
    is_error: bool,
    text: []const u8,

    pub fn deinit(self: *Reply) void {
        self.parsed.deinit();
    }

    pub fn body(self: *Reply) !std.json.Parsed(Value) {
        errdefer std.debug.print("reply: {s}\n", .{self.text});
        const end = std.mem.indexOfScalar(u8, self.text, '\n') orelse self.text.len;
        return std.json.parseFromSlice(Value, gpa, self.text[0..end], .{});
    }

    pub fn has(self: *Reply, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.text, needle) != null;
    }
};

fn run(root_abs: []const u8, args: []const []const u8) ![]u8 {
    var argv: [8][]const u8 = undefined;
    argv[0] = try git_fixture.git();
    @memcpy(argv[1..][0..args.len], args);
    const result = try @import("emetgate").bounded_run.run(gpa, testing.io, .{ .argv = argv[0 .. args.len + 1], .cwd = .{ .path = root_abs } });
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            gpa.free(result.stdout);
            return error.GitFailed;
        },
        else => {
            gpa.free(result.stdout);
            return error.GitFailed;
        },
    }
    return result.stdout;
}

/// A committed repository with src/app.js and any extra files, served to emetgate_change.
pub const Repo = struct {
    tmp: testing.TmpDir,
    root_abs: [:0]u8,
    workspace_abs: []u8,
    runtime: *Runtime,
    known: KnownFiles,

    pub fn init(files: []const [2][]const u8) !Repo {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo/src");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/app.js", .data = app_js });
        for (files) |file| {
            const sub = try std.fmt.allocPrint(gpa, "repo/{s}", .{file[0]});
            defer gpa.free(sub);
            try tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = file[1] });
        }
        const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", gpa);
        errdefer gpa.free(root_abs);
        try git_fixture.initRepo(root_abs);
        try git_fixture.commitInit(root_abs, false);
        const workspace_abs = try std.fmt.allocPrint(gpa, "{s}\\.emetgate", .{root_abs});
        errdefer gpa.free(workspace_abs);
        return .{ .tmp = tmp, .root_abs = root_abs, .workspace_abs = workspace_abs, .runtime = try Runtime.create(gpa), .known = .init(gpa) };
    }

    pub fn deinit(self: *Repo) void {
        self.known.deinit();
        self.runtime.destroy() catch @panic("live snapshots");
        gpa.free(self.workspace_abs);
        gpa.free(self.root_abs);
        self.tmp.cleanup();
    }

    pub fn callAs(self: *Repo, tool: []const u8, args: anytype, test_command: []const u8) !Reply {
        var line: std.Io.Writer.Allocating = .init(gpa);
        defer line.deinit();
        var js: std.json.Stringify = .{ .writer = &line.writer };
        try js.write(.{ .jsonrpc = "2.0", .id = 1, .method = "tools/call", .params = .{ .name = tool, .arguments = args } });
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var observer: telemetry.Observer = .{ .workspace_abs = self.workspace_abs };
        _ = try server.handleMessageObserved(gpa, testing.io, self.runtime, line.written(), &out.writer, &observer, .{ .root = self.root_abs, .test_command = test_command, .known_files = &self.known, .allow_repo_memory = true });
        const parsed = try std.json.parseFromSlice(Value, gpa, out.written(), .{ .allocate = .alloc_always });
        errdefer parsed.deinit();
        const result = parsed.value.object.get("result") orelse return error.NotAToolResult;
        const content = result.object.get("content").?.array.items[0];
        return .{ .parsed = parsed, .is_error = result.object.get("isError").?.bool, .text = content.object.get("text").?.string };
    }

    pub fn call(self: *Repo, args: anytype, test_command: []const u8) !Reply {
        return self.callAs("emetgate_change", args, test_command);
    }

    pub fn read(self: *Repo, rel: []const u8) ![]u8 {
        const sub = try std.fmt.allocPrint(gpa, "repo/{s}", .{rel});
        defer gpa.free(sub);
        return self.tmp.dir.readFileAlloc(testing.io, sub, gpa, .unlimited);
    }

    pub fn expectFile(self: *Repo, rel: []const u8, expected: []const u8) !void {
        const on_disk = try self.read(rel);
        defer gpa.free(on_disk);
        try testing.expectEqualStrings(expected, on_disk);
    }

    pub fn path(self: *Repo, rel: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "{s}\\{s}", .{ self.root_abs, rel });
    }

    pub fn expectGit(self: *Repo, args: []const []const u8, expected: []const u8) !void {
        const out = try run(self.root_abs, args);
        defer gpa.free(out);
        try testing.expectEqualStrings(expected, std.mem.trim(u8, out, " \r\n"));
    }

    fn gitText(self: *Repo, args: []const []const u8) ![]u8 {
        const out = try run(self.root_abs, args);
        defer gpa.free(out);
        return gpa.dupe(u8, std.mem.trim(u8, out, " \r\n"));
    }
};

test "change atomic: a branch this call created is switched away from and deleted when its edits are refused, so the same call succeeds once fixed" {
    var repo = try Repo.init(&.{});
    defer repo.deinit();
    const start = try repo.gitText(&.{ "rev-parse", "--abbrev-ref", "HEAD" });
    defer gpa.free(start);
    const app = try repo.path("src\\app.js");
    defer gpa.free(app);

    var refused = try repo.call(.{ .branch = "feature/x", .edits = .{
        .{ .file = app, .old_string = "return a + b;", .new_string = "return a + b; BROKEN;" },
    } }, fails_on_broken);
    defer refused.deinit();
    errdefer std.debug.print("reply: {s}\n", .{refused.text});
    try testing.expect(refused.is_error);
    try testing.expect(refused.has("\"stopped_at\":\"edits\""));
    try testing.expect(refused.has("\"branch_undone\":\"yes:"));
    try repo.expectGit(&.{ "rev-parse", "--abbrev-ref", "HEAD" }, start);
    try repo.expectGit(&.{ "branch", "--list", "feature/x" }, "");
    try repo.expectFile("src/app.js", app_js);

    var again = try repo.call(.{ .branch = "feature/x", .edits = .{
        .{ .file = app, .old_string = "return a + b;", .new_string = "return b + a;" },
    } }, fails_on_broken);
    defer again.deinit();
    errdefer std.debug.print("reply: {s}\n", .{again.text});
    try testing.expect(!again.is_error);
    try repo.expectGit(&.{ "rev-parse", "--abbrev-ref", "HEAD" }, "feature/x");
    try repo.expectFile("src/app.js", "export function total(a, b) {\n  return b + a;\n}\n");
}

test "change atomic: a branch that already exists stops the call with a fix that names the switch" {
    var repo = try Repo.init(&.{});
    defer repo.deinit();
    gpa.free(try run(repo.root_abs, &.{ "branch", "feature/old" }));
    var reply = try repo.call(.{ .branch = "feature/old" }, green);
    defer reply.deinit();
    errdefer std.debug.print("reply: {s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try testing.expect(reply.has("\"stopped_at\":\"branch\""));
    try testing.expect(reply.has("\"fix\":"));
    try testing.expect(reply.has("switch"));
}

test "change atomic: a commit message a rule refuses stops the call before any edit is written, and the reply says the edits were not kept" {
    var repo = try Repo.init(&.{});
    defer repo.deinit();
    const id = try memory.remember(gpa, testing.io, repo.root_abs, .project, "signed", true, "message:require:Signed-off-by:", null);
    gpa.free(id);
    const app = try repo.path("src\\app.js");
    defer gpa.free(app);

    var reply = try repo.call(.{ .edits = .{
        .{ .file = app, .old_string = "return a + b;", .new_string = "return b + a;" },
    }, .commit = "no signoff" }, green);
    defer reply.deinit();
    errdefer std.debug.print("reply: {s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try testing.expect(reply.has("\"stopped_at\":\"commit\""));
    try testing.expect(reply.has("the edits were not kept"));
    try testing.expect(!reply.has("edits written, commit refused"));
    try repo.expectFile("src/app.js", app_js);
    try repo.expectGit(&.{ "log", "-1", "--format=%s" }, "init");
    try repo.expectGit(&.{ "status", "--porcelain", "--", "src" }, "");
}

test "change atomic: a branch and a commit message a rule refuses leave HEAD on the branch it was on" {
    var repo = try Repo.init(&.{});
    defer repo.deinit();
    const start = try repo.gitText(&.{ "rev-parse", "--abbrev-ref", "HEAD" });
    defer gpa.free(start);
    const id = try memory.remember(gpa, testing.io, repo.root_abs, .project, "no WIP commits", true, "message:forbid:WIP", null);
    gpa.free(id);
    const app = try repo.path("src\\app.js");
    defer gpa.free(app);

    var reply = try repo.call(.{ .branch = "feature/y", .edits = .{
        .{ .file = app, .old_string = "return a + b;", .new_string = "return b + a;" },
    }, .commit = "WIP swap" }, green);
    defer reply.deinit();
    errdefer std.debug.print("reply: {s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try testing.expect(reply.has("the edits were not kept"));
    try repo.expectFile("src/app.js", app_js);
    try repo.expectGit(&.{ "rev-parse", "--abbrev-ref", "HEAD" }, start);
    try repo.expectGit(&.{ "branch", "--list", "feature/y" }, "");
}

test "change atomic: a commit refused after the edits were written puts every file back and leaves no receipt behind" {
    var repo = try Repo.init(&.{});
    defer repo.deinit();
    const id = try memory.remember(gpa, testing.io, repo.root_abs, .project, "no eval in src", true, "forbid:eval", "src/");
    gpa.free(id);
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/outside.js", .data = "eval('1');\n" });
    const app = try repo.path("src\\app.js");
    defer gpa.free(app);
    const made = try repo.path("src\\made.js");
    defer gpa.free(made);

    var reply = try repo.call(.{ .edits = .{
        .{ .file = app, .old_string = "return a + b;", .new_string = "return b + a;" },
        .{ .file = made, .content = "export const made = 1;\n" },
    }, .commit = "swap" }, green);
    defer reply.deinit();
    errdefer std.debug.print("reply: {s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try testing.expect(reply.has("\"stopped_at\":\"commit\""));
    try testing.expect(reply.has("the edits were not kept"));
    try testing.expect(reply.has("back as it was before the call"));
    try testing.expect(!reply.has("edits written, commit refused"));
    try repo.expectFile("src/app.js", app_js);
    try testing.expectError(error.FileNotFound, repo.tmp.dir.access(testing.io, "repo/src/made.js", .{}));
    try repo.expectGit(&.{ "log", "-1", "--format=%s" }, "init");
    try repo.expectGit(&.{ "status", "--porcelain", "--", "src/app.js", "src/made.js" }, "");
    var receipts = try repo.tmp.dir.openDir(testing.io, "repo/.emetgate/receipts", .{ .iterate = true });
    defer receipts.close(testing.io);
    var it = receipts.iterate();
    while (try it.next(testing.io)) |entry| {
        try testing.expect(!std.mem.endsWith(u8, entry.name, ".json"));
    }
}

const Before = struct {
    status: []u8,
    index: []u8,
    receipts: []u8,

    fn take(repo: *Repo) !Before {
        const status = try repo.gitText(&.{ "status", "--porcelain", "--untracked-files=all", "--", ".", ":(exclude).emetgate" });
        errdefer gpa.free(status);
        const index = try repo.gitText(&.{ "ls-files", "-s" });
        errdefer gpa.free(index);
        return .{ .status = status, .index = index, .receipts = try receiptNames(repo) };
    }

    fn deinit(self: Before) void {
        gpa.free(self.status);
        gpa.free(self.index);
        gpa.free(self.receipts);
    }

    fn expectSame(self: Before, repo: *Repo) !void {
        const now = try Before.take(repo);
        defer now.deinit();
        try testing.expectEqualStrings(self.status, now.status);
        try testing.expectEqualStrings(self.index, now.index);
        try testing.expectEqualStrings(self.receipts, now.receipts);
    }
};

fn receiptNames(repo: *Repo) ![]u8 {
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |name| gpa.free(name);
        names.deinit(gpa);
    }
    var receipts = repo.tmp.dir.openDir(testing.io, "repo/.emetgate/receipts", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return gpa.dupe(u8, ""),
        else => |e| return e,
    };
    defer receipts.close(testing.io);
    var it = receipts.iterate();
    while (try it.next(testing.io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return std.mem.join(gpa, "\n", names.items);
}

fn forbidEvalOutside(repo: *Repo) !void {
    const id = try memory.remember(gpa, testing.io, repo.root_abs, .project, "no eval in src", true, "forbid:eval", "src/");
    gpa.free(id);
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/outside.js", .data = "eval('1');\n" });
}

fn expectUndone(reply: *Reply) !void {
    try testing.expect(reply.is_error);
    try testing.expect(reply.has("\"stopped_at\":\"commit\""));
    try testing.expect(reply.has("the edits were not kept"));
    try testing.expect(!reply.has("edits written, commit refused"));
}

test "change atomic: a refused commit removes the folders the call created for new files and keeps a folder that was there before" {
    var repo = try Repo.init(&.{});
    defer repo.deinit();
    try forbidEvalOutside(&repo);
    try repo.tmp.dir.createDirPath(testing.io, "repo/src/kept");
    const app = try repo.path("src\\app.js");
    defer gpa.free(app);
    const deep = try repo.path("src\\new\\deep\\made.js");
    defer gpa.free(deep);
    const kept = try repo.path("src\\kept\\made.js");
    defer gpa.free(kept);
    const before = try Before.take(&repo);
    defer before.deinit();

    var reply = try repo.call(.{ .edits = .{
        .{ .file = app, .old_string = "return a + b;", .new_string = "return b + a;" },
        .{ .file = deep, .content = "export const deep = 1;\n" },
        .{ .file = kept, .content = "export const kept = 1;\n" },
    }, .commit = "swap" }, green);
    defer reply.deinit();
    errdefer std.debug.print("reply: {s}\n", .{reply.text});
    try expectUndone(&reply);
    try repo.expectFile("src/app.js", app_js);
    try testing.expectError(error.FileNotFound, repo.tmp.dir.access(testing.io, "repo/src/new", .{}));
    try testing.expectError(error.FileNotFound, repo.tmp.dir.access(testing.io, "repo/src/kept/made.js", .{}));
    try repo.tmp.dir.access(testing.io, "repo/src/kept", .{});
    try before.expectSame(&repo);
}

test "change atomic: a commit refused for drift after the edits were written puts the work tree, index and receipts back as they were" {
    var repo = try Repo.init(&.{.{ "src/other.js", "export const other = 1;\n" }});
    defer repo.deinit();
    const app = try repo.path("src\\app.js");
    defer gpa.free(app);
    const other = try repo.path("src\\other.js");
    defer gpa.free(other);

    var first = try repo.call(.{ .edits = .{
        .{ .file = other, .old_string = "other = 1", .new_string = "other = 2" },
    } }, green);
    defer first.deinit();
    errdefer std.debug.print("first: {s}\n", .{first.text});
    try testing.expect(!first.is_error);
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/other.js", .data = "export const other = 3;\n" });
    const before = try Before.take(&repo);
    defer before.deinit();
    try testing.expect(before.receipts.len != 0);

    var reply = try repo.call(.{ .edits = .{
        .{ .file = app, .old_string = "return a + b;", .new_string = "return b + a;" },
    }, .commit = "swap" }, green);
    defer reply.deinit();
    errdefer std.debug.print("reply: {s}\n", .{reply.text});
    try expectUndone(&reply);
    try testing.expect(reply.has("src/other.js"));
    try repo.expectFile("src/app.js", app_js);
    try repo.expectFile("src/other.js", "export const other = 3;\n");
    try repo.expectGit(&.{ "log", "-1", "--format=%s" }, "init");
    try before.expectSame(&repo);
}

test "change atomic: a commit refused for a staged copy of a file it carries puts the work tree back and keeps the staged copy" {
    var repo = try Repo.init(&.{});
    defer repo.deinit();
    const app = try repo.path("src\\app.js");
    defer gpa.free(app);
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/app.js", .data = "export const staged = 1;\n" });
    gpa.free(try run(repo.root_abs, &.{ "add", "--", "src/app.js" }));
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/app.js", .data = app_js });
    const before = try Before.take(&repo);
    defer before.deinit();

    var reply = try repo.call(.{ .edits = .{
        .{ .file = app, .old_string = "return a + b;", .new_string = "return b + a;" },
    }, .commit = "swap" }, green);
    defer reply.deinit();
    errdefer std.debug.print("reply: {s}\n", .{reply.text});
    try expectUndone(&reply);
    try testing.expect(reply.has("restore"));
    try repo.expectFile("src/app.js", app_js);
    try repo.expectGit(&.{ "show", ":src/app.js" }, "export const staged = 1;");
    try repo.expectGit(&.{ "log", "-1", "--format=%s" }, "init");
    try before.expectSame(&repo);
}

test "change atomic: a refused commit puts a deleted file back with the index entry it had, staged or untracked" {
    var repo = try Repo.init(&.{.{ "src/gone.js", "export const gone = 1;\n" }});
    defer repo.deinit();
    try forbidEvalOutside(&repo);
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/gone.js", .data = "export const gone = 2;\n" });
    gpa.free(try run(repo.root_abs, &.{ "add", "--", "src/gone.js" }));
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/gone.js", .data = "export const gone = 3;\n" });
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/loose.js", .data = "export const loose = 1;\n" });
    const app = try repo.path("src\\app.js");
    defer gpa.free(app);
    const gone = try repo.path("src\\gone.js");
    defer gpa.free(gone);
    const loose = try repo.path("src\\loose.js");
    defer gpa.free(loose);
    const gone_hash = symbol.formatHash(symbol.fileHash("export const gone = 3;\n"));
    const loose_hash = symbol.formatHash(symbol.fileHash("export const loose = 1;\n"));
    const before = try Before.take(&repo);
    defer before.deinit();

    var reply = try repo.call(.{ .edits = .{
        .{ .file = app, .old_string = "return a + b;", .new_string = "return b + a;" },
        .{ .file = gone, .op = "delete", .hash = &gone_hash },
        .{ .file = loose, .op = "delete", .hash = &loose_hash },
    }, .commit = "swap" }, green);
    defer reply.deinit();
    errdefer std.debug.print("reply: {s}\n", .{reply.text});
    try expectUndone(&reply);
    try repo.expectFile("src/app.js", app_js);
    try repo.expectFile("src/gone.js", "export const gone = 3;\n");
    try repo.expectFile("src/loose.js", "export const loose = 1;\n");
    try repo.expectGit(&.{ "show", ":src/gone.js" }, "export const gone = 2;");
    try before.expectSame(&repo);
}

test "change atomic: legacy emetgate_write refuses to overwrite an existing file without its file_hash, and accepts it with the hash" {
    var repo = try Repo.init(&.{.{ "seen.txt", "kept by the user\n" }});
    defer repo.deinit();
    var refused = try repo.callAs("emetgate_write", .{ .file = "seen.txt", .content = "clobbered\n" }, green);
    defer refused.deinit();
    errdefer std.debug.print("reply: {s}\n", .{refused.text});
    try testing.expect(refused.is_error);
    try testing.expect(refused.has("FileExists"));
    try repo.expectFile("seen.txt", "kept by the user\n");

    var stale = try repo.callAs("emetgate_write", .{ .file = "seen.txt", .content = "clobbered\n", .hash = "0123456789abcdef0123456789abcdef" }, green);
    defer stale.deinit();
    try testing.expect(stale.is_error);
    try repo.expectFile("seen.txt", "kept by the user\n");

    const hex = symbol.formatHash(symbol.fileHash("kept by the user\n"));
    var given = try repo.callAs("emetgate_write", .{ .file = "seen.txt", .content = "replaced\n", .hash = @as([]const u8, &hex) }, green);
    defer given.deinit();
    errdefer std.debug.print("reply: {s}\n", .{given.text});
    try testing.expect(!given.is_error);
    try repo.expectFile("seen.txt", "replaced\n");

    var created = try repo.callAs("emetgate_write", .{ .file = "new.txt", .content = "fresh\n" }, green);
    defer created.deinit();
    errdefer std.debug.print("reply: {s}\n", .{created.text});
    try testing.expect(!created.is_error);
    try repo.expectFile("new.txt", "fresh\n");
}

test "change atomic: an edit that leaves a TypeScript, JavaScript, Zig or C# file with an error-free tree-sitter parse is reported verified" {
    var repo = try Repo.init(&.{
        .{ "src/w.ts", "export const n: number = 1;\n" },
        .{ "src/w.zig", "pub fn one() u8 {\n    return 1;\n}\n" },
        .{ "src/W.cs", "class C {\n    int One() { return 1; }\n}\n" },
    });
    defer repo.deinit();
    const app = try repo.path("src\\app.js");
    defer gpa.free(app);
    const ts_file = try repo.path("src\\w.ts");
    defer gpa.free(ts_file);
    const zig_file = try repo.path("src\\w.zig");
    defer gpa.free(zig_file);
    const cs_file = try repo.path("src\\W.cs");
    defer gpa.free(cs_file);

    var reply = try repo.call(.{ .edits = .{
        .{ .file = app, .old_string = "return a + b;", .new_string = "return b + a;" },
        .{ .file = ts_file, .old_string = "= 1;", .new_string = "= 2;" },
        .{ .file = zig_file, .old_string = "return 1;", .new_string = "return 2;" },
        .{ .file = cs_file, .old_string = "return 1;", .new_string = "return 2;" },
    } }, green);
    defer reply.deinit();
    errdefer std.debug.print("reply: {s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expect(reply.has("\"parse\":\"verified: the language check passed after the reparse\""));
    try testing.expect(!reply.has("not verified"));
}

test "change atomic: an edit that leaves a TypeScript, JavaScript, Zig or C# file with a syntax error is not reported verified" {
    var repo = try Repo.init(&.{
        .{ "src/b.ts", "export function f() {\n  return 1;\n" },
        .{ "src/b.js", "export function g() {\n  return 1;\n" },
        .{ "src/b.zig", "pub fn one() u8 {\n    return 1;\n" },
        .{ "src/B.cs", "class C {\n    int One() { return 1; }\n" },
    });
    defer repo.deinit();
    const app = try repo.path("src\\app.js");
    defer gpa.free(app);
    const ts_file = try repo.path("src\\b.ts");
    defer gpa.free(ts_file);
    const js_file = try repo.path("src\\b.js");
    defer gpa.free(js_file);
    const zig_file = try repo.path("src\\b.zig");
    defer gpa.free(zig_file);
    const cs_file = try repo.path("src\\B.cs");
    defer gpa.free(cs_file);

    var reply = try repo.call(.{ .edits = .{
        .{ .file = app, .old_string = "return a + b;", .new_string = "return b + a;" },
        .{ .file = ts_file, .old_string = "return 1;", .new_string = "return 2;" },
        .{ .file = js_file, .old_string = "return 1;", .new_string = "return 2;" },
        .{ .file = zig_file, .old_string = "return 1;", .new_string = "return 2;" },
        .{ .file = cs_file, .old_string = "return 1;", .new_string = "return 2;" },
    } }, green);
    defer reply.deinit();
    errdefer std.debug.print("reply: {s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expect(!reply.has("\"parse\":\"verified:"));
    try testing.expect(reply.has("\"parse\":\"verified for "));
    try testing.expect(reply.has("app.js; not verified for "));
    try testing.expect(reply.has("ERROR or MISSING nodes"));
    for ([_][]const u8{ "b.ts (typescript)", "b.js (javascript)", "b.zig (zig)", "B.cs (csharp)" }) |label| {
        try testing.expect(reply.has(label));
    }
}
