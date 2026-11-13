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

test "change atomic: when a message rule refuses the commit after the edits were written, the reply and footer say the edits are on disk" {
    var repo = try Repo.init(&.{});
    defer repo.deinit();
    const id = try memory.remember(gpa, testing.io, repo.root_abs, .project, "no WIP commits", true, "message:forbid:WIP", null);
    gpa.free(id);
    const app = try repo.path("src\\app.js");
    defer gpa.free(app);

    var reply = try repo.call(.{ .edits = .{
        .{ .file = app, .old_string = "return a + b;", .new_string = "return b + a;" },
    }, .commit = "WIP swap" }, green);
    defer reply.deinit();
    errdefer std.debug.print("reply: {s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try testing.expect(reply.has("\"stopped_at\":\"commit\""));
    try testing.expect(reply.has("\"on_disk\":\"the edits are written"));
    try testing.expect(reply.has("edits written, commit refused"));
    try testing.expect(!reply.has("disk untouched"));
    try repo.expectFile("src/app.js", "export function total(a, b) {\n  return b + a;\n}\n");
    try repo.expectGit(&.{ "log", "-1", "--format=%s" }, "init");
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
