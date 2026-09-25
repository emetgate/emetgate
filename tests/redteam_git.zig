const std = @import("std");
const git_fixture = @import("git_fixture.zig");
const server = @import("emetgate").server;
const Runtime = @import("emetgate").runtime.Runtime;

const testing = std.testing;
const gpa = testing.allocator;
const Value = std.json.Value;

const marker_name = "ran.txt";

const Clone = struct {
    tmp: testing.TmpDir,
    root_abs: [:0]u8,
    drop_abs: [:0]u8,

    fn init() !Clone {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo");
        try tmp.dir.createDirPath(testing.io, "drop");
        const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", gpa);
        errdefer gpa.free(root_abs);
        const drop_abs = try tmp.dir.realPathFileAlloc(testing.io, "drop", gpa);
        errdefer gpa.free(drop_abs);
        try git_fixture.initRepo(root_abs);
        return .{ .tmp = tmp, .root_abs = root_abs, .drop_abs = drop_abs };
    }

    fn deinit(self: *Clone) void {
        gpa.free(self.drop_abs);
        gpa.free(self.root_abs);
        self.tmp.cleanup();
    }

    fn git(self: *Clone, args: []const []const u8) !void {
        var argv: [8][]const u8 = undefined;
        argv[0] = "git";
        @memcpy(argv[1..][0..args.len], args);
        const result = try std.process.run(gpa, testing.io, .{ .argv = argv[0 .. args.len + 1], .cwd = .{ .path = self.root_abs } });
        gpa.free(result.stdout);
        gpa.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.GitSetupFailed,
            else => return error.GitSetupFailed,
        }
    }

    fn writeRepoFile(self: *Clone, rel: []const u8, data: []const u8) !void {
        const target = try std.fmt.allocPrint(gpa, "repo/{s}", .{rel});
        defer gpa.free(target);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = target, .data = data });
    }

    fn markerPath(self: *Clone) ![]u8 {
        return std.fmt.allocPrint(gpa, "{s}\\{s}", .{ self.drop_abs, marker_name });
    }

    fn markerExists(self: *Clone) bool {
        const rel = std.fmt.allocPrint(gpa, "drop/{s}", .{marker_name}) catch return false;
        defer gpa.free(rel);
        self.tmp.dir.access(testing.io, rel, .{}) catch return false;
        return true;
    }

    fn setHostileConfig(self: *Clone) !void {
        const marker = try self.markerPath();
        defer gpa.free(marker);
        const hostile = try std.fmt.allocPrint(gpa, "echo ran > {s}", .{marker});
        defer gpa.free(hostile);
        try self.git(&.{ "config", "--local", "core.pager", hostile });
        try self.git(&.{ "config", "--local", "diff.external", hostile });
        try self.git(&.{ "config", "--local", "core.fsmonitor", hostile });
        try self.git(&.{ "config", "--local", "diff.mine.textconv", hostile });
        try self.git(&.{ "config", "--local", "filter.mine.clean", hostile });
        try self.git(&.{ "config", "--local", "filter.mine.smudge", hostile });
        try self.writeRepoFile(".gitattributes", "a.secret diff=mine\na.secret filter=mine\n");
    }
};

fn callTool(runtime: *Runtime, root_abs: []const u8, args: anytype) ![]u8 {
    var line: std.Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    var js: std.json.Stringify = .{ .writer = &line.writer };
    try js.write(.{ .jsonrpc = "2.0", .id = 1, .method = "tools/call", .params = .{ .name = "emetgate_git", .arguments = args } });

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try server.handleMessageObserved(gpa, testing.io, runtime, line.written(), &out.writer, null, .{ .root = root_abs });
    return gpa.dupe(u8, out.written());
}

test "redteam git: hostile pager, external diff, fsmonitor, textconv and filter never run" {
    var clone = try Clone.init();
    defer clone.deinit();
    try clone.writeRepoFile("a.secret", "one\n");
    try clone.git(&.{ "add", "." });
    try clone.git(&.{ "commit", "-q", "-m", "init" });

    try clone.setHostileConfig();
    try clone.writeRepoFile("a.secret", "two\n");

    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    for ([_]struct { sub: []const u8 }{
        .{ .sub = "status" },
        .{ .sub = "diff" },
        .{ .sub = "log" },
        .{ .sub = "show" },
    }) |case| {
        if (std.mem.eql(u8, case.sub, "show")) {
            const out = try callTool(runtime, clone.root_abs, .{ .sub = "show", .commit = "HEAD", .path = clone.root_abs });
            gpa.free(out);
        } else {
            const out = try callTool(runtime, clone.root_abs, .{ .sub = case.sub, .path = clone.root_abs });
            gpa.free(out);
        }
        try testing.expect(!clone.markerExists());
    }
}

test "redteam git: argument injection through path or commit is refused, not run" {
    var clone = try Clone.init();
    defer clone.deinit();
    try clone.writeRepoFile("a.txt", "one\n");
    try clone.git(&.{ "add", "." });
    try clone.git(&.{ "commit", "-q", "-m", "init" });

    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    const injections = [_][]const u8{
        "--output=pwned.txt",
        "-c",
        "; whoami",
        "a.txt; whoami",
        "--upload-pack=calc",
    };
    for (injections) |commit| {
        const out = try callTool(runtime, clone.root_abs, .{ .sub = "show", .commit = commit, .path = clone.root_abs });
        defer gpa.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "InvalidCommit") != null);
    }

    const outside = try callTool(runtime, clone.root_abs, .{ .sub = "log", .path = clone.drop_abs });
    defer gpa.free(outside);
    try testing.expect(std.mem.indexOf(u8, outside, "isError\":true") != null);
}

test "redteam git: a malformed commit id and an unknown subcommand never reach git" {
    var clone = try Clone.init();
    defer clone.deinit();
    try clone.writeRepoFile("a.txt", "one\n");
    try clone.git(&.{ "add", "." });
    try clone.git(&.{ "commit", "-q", "-m", "init" });

    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    const bad_ids = [_][]const u8{ "", "not-hex", "abc", "0000000000000000000000000000000000000000000000000000000000000" };
    for (bad_ids) |id| {
        const out = try callTool(runtime, clone.root_abs, .{ .sub = "show", .commit = id, .path = clone.root_abs });
        defer gpa.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "\"isError\":true") != null);
    }

    const unknown = try callTool(runtime, clone.root_abs, .{ .sub = "checkout", .path = clone.root_abs });
    defer gpa.free(unknown);
    try testing.expect(std.mem.indexOf(u8, unknown, "UnknownGitSubcommand") != null);
}
