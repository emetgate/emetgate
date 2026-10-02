const std = @import("std");
const builtin = @import("builtin");
const git_fixture = @import("git_fixture.zig");
const server = @import("emetgate").server;
const shadow = @import("emetgate").shadow;
const repo_mod = @import("emetgate").repo;
const tsserver = @import("emetgate").tsserver;
const exe_path = @import("emetgate").exe_path;
const Runtime = @import("emetgate").runtime.Runtime;

const testing = std.testing;
const gpa = testing.allocator;

const marker = "planted.marker";
const planted_script = "@echo ran>\"%~dp0" ++ marker ++ "\"\r\n@exit /b 0\r\n";

fn gitIn(root: []const u8, args: []const []const u8) !void {
    var argv: [8][]const u8 = undefined;
    argv[0] = try exe_path.git(gpa, root);
    defer gpa.free(argv[0]);
    @memcpy(argv[1..][0..args.len], args);
    const result = try std.process.run(gpa, testing.io, .{ .argv = argv[0 .. args.len + 1], .cwd = .{ .path = root } });
    gpa.free(result.stdout);
    gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitSetupFailed,
        else => return error.GitSetupFailed,
    }
}

const Planted = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,

    fn init() !Planted {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export const plantedNeedle = 1;\n" });
        const root = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
        errdefer gpa.free(root);
        try git_fixture.initRepo(root);
        try gitIn(root, &.{ "add", "a.ts" });
        try gitIn(root, &.{ "commit", "-q", "-m", "init" });
        for ([_][]const u8{ "git.bat", "git.cmd", "rg.bat", "rg.cmd", "node.bat", "claude.cmd" }) |name| {
            try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = planted_script });
        }
        return .{ .tmp = tmp, .root = root };
    }

    fn deinit(self: *Planted) void {
        gpa.free(self.root);
        self.tmp.cleanup();
    }

    fn plantExe(self: *Planted, name: []const u8) !void {
        const where = try exe_path.system(gpa, "where.exe");
        defer gpa.free(where);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, where, gpa, .limited(4 * 1024 * 1024));
        defer gpa.free(bytes);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = bytes });
    }

    fn expectNoMarker(self: *Planted) !void {
        try testing.expectError(error.FileNotFound, self.tmp.dir.access(testing.io, marker, .{}));
    }
};

fn exercise(planted: *Planted, runtime: *Runtime) !void {
    const tracked = try shadow.trackedFiles(gpa, testing.io, planted.root);
    defer {
        shadow.freeFileList(gpa, tracked);
        gpa.free(tracked);
    }
    try testing.expectEqual(@as(usize, 1), tracked.len);
    try testing.expectEqualStrings("a.ts", tracked[0]);

    const program_files = try tsserver.programFiles(gpa, testing.io, planted.root);
    defer {
        for (program_files) |f| gpa.free(f);
        gpa.free(program_files);
    }
    try testing.expectEqual(@as(usize, 1), program_files.len);

    try testing.expect(!try repo_mod.isIgnored(gpa, testing.io, planted.root, "a.ts"));
    const mentioning = try repo_mod.filesMentioning(gpa, testing.io, planted.root, "plantedNeedle");
    defer gpa.free(mentioning);
    try testing.expect(std.mem.indexOf(u8, mentioning, "a.ts") != null);
    const top = try repo_mod.gitToplevel(gpa, testing.io, planted.root);
    defer gpa.free(top);
    try testing.expect(std.ascii.eqlIgnoreCase(top, planted.root));

    var line: std.Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    var js: std.json.Stringify = .{ .writer = &line.writer };
    try js.write(.{ .jsonrpc = "2.0", .id = 1, .method = "tools/call", .params = .{ .name = "emetgate_git", .arguments = .{ .sub = "log", .n = 1 } } });
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try server.handleMessageObserved(gpa, testing.io, runtime, line.written(), &out.writer, null, .{ .root = planted.root });
    errdefer std.debug.print("{s}\n", .{out.written()});
    try testing.expect(std.mem.indexOf(u8, out.written(), "init") != null);
}

test "process launch: a repository that plants git, rg, node and claude scripts or a git.exe at its root never runs them" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var planted = try Planted.init();
    defer planted.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    try exercise(&planted, runtime);
    try planted.expectNoMarker();

    try planted.plantExe("git.exe");
    try exercise(&planted, runtime);
    try planted.expectNoMarker();
}
