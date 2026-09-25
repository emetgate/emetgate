const std = @import("std");
const builtin = @import("builtin");
const git_fixture = @import("git_fixture.zig");
const server = @import("emetgate").server;
const shadow = @import("emetgate").shadow;
const Runtime = @import("emetgate").runtime.Runtime;

const testing = std.testing;

const source = "export function add(a: number, b: number): number {\n  return a + b;\n}\n";
const helper = "export function helper(x: number): number { return x + 1; }";

const Repo = struct {
    tmp: testing.TmpDir,
    root_abs: [:0]u8,
    outside_abs: [:0]u8,

    fn init() !Repo {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo/src");
        try tmp.dir.createDirPath(testing.io, "outside");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/math.ts", .data = source });
        const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", testing.allocator);
        errdefer testing.allocator.free(root_abs);
        const outside_abs = try tmp.dir.realPathFileAlloc(testing.io, "outside", testing.allocator);
        errdefer testing.allocator.free(outside_abs);
        try git_fixture.initRepo(root_abs);
        try git(root_abs, &.{ "add", "." });
        try git(root_abs, &.{ "commit", "-q", "-m", "init" });
        return .{ .tmp = tmp, .root_abs = root_abs, .outside_abs = outside_abs };
    }

    fn deinit(self: *Repo) void {
        testing.allocator.free(self.outside_abs);
        testing.allocator.free(self.root_abs);
        self.tmp.cleanup();
    }

    fn exists(self: *Repo, sub_path: []const u8) bool {
        self.tmp.dir.access(testing.io, sub_path, .{}) catch return false;
        return true;
    }

    fn expectMathUntouched(self: *Repo) !void {
        const on_disk = try self.tmp.dir.readFileAlloc(testing.io, "repo/src/math.ts", testing.allocator, .unlimited);
        defer testing.allocator.free(on_disk);
        try testing.expectEqualStrings(source, on_disk);
    }
};

fn git(root_abs: []const u8, args: []const []const u8) !void {
    var argv: [8][]const u8 = undefined;
    argv[0] = "git";
    @memcpy(argv[1..][0..args.len], args);
    const result = try std.process.run(testing.allocator, testing.io, .{ .argv = argv[0 .. args.len + 1], .cwd = .{ .path = root_abs } });
    testing.allocator.free(result.stdout);
    testing.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitSetupFailed,
        else => return error.GitSetupFailed,
    }
}

const Item = struct {
    file: []const u8,
    symbol: []const u8 = "helper",
    body: []const u8 = helper,
};

fn batchLine(items: []const Item) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer };
    try js.beginObject();
    try js.objectField("jsonrpc");
    try js.write("2.0");
    try js.objectField("id");
    try js.write(1);
    try js.objectField("method");
    try js.write("tools/call");
    try js.objectField("params");
    try js.beginObject();
    try js.objectField("name");
    try js.write("emetgate_try_batch");
    try js.objectField("arguments");
    try js.beginObject();
    try js.objectField("edits");
    try js.beginArray();
    for (items) |item| {
        try js.beginObject();
        try js.objectField("file");
        try js.write(item.file);
        try js.objectField("symbol");
        try js.write(item.symbol);
        try js.objectField("hash");
        try js.write("absent");
        try js.objectField("body");
        try js.write(item.body);
        try js.endObject();
    }
    try js.endArray();
    try js.endObject();
    try js.endObject();
    try js.endObject();
    return testing.allocator.dupe(u8, out.written());
}

fn call(repo: *Repo, items: []const Item) ![]u8 {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const line = try batchLine(items);
    defer testing.allocator.free(line);
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    _ = try server.handleMessageObserved(testing.allocator, testing.io, runtime, line, &buffer.writer, null, .{ .test_command = "cmd /c exit 0", .root = repo.root_abs });
    return testing.allocator.dupe(u8, buffer.written());
}

fn expectRefused(response: []const u8, reason: []const u8) !void {
    errdefer std.debug.print("response: {s}\n", .{response});
    try testing.expect(std.mem.indexOf(u8, response, "\"isError\":true") != null);
    try testing.expect(std.mem.indexOf(u8, response, reason) != null);
}

test "redteam batch create: hash absent on an existing file with that symbol is refused and never overwrites it" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const file = try std.fmt.allocPrint(testing.allocator, "{s}\\src\\math.ts", .{repo.root_abs});
    defer testing.allocator.free(file);
    const response = try call(&repo, &.{.{ .file = file, .symbol = "add", .body = "export function add(a: number, b: number): number { return 0; }" }});
    defer testing.allocator.free(response);
    try expectRefused(response, "SymbolExists");
    try repo.expectMathUntouched();
}

test "redteam batch create: a create outside the served repository is refused and writes nothing there" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const escape = try std.fmt.allocPrint(testing.allocator, "{s}\\..\\outside\\x.ts", .{repo.root_abs});
    defer testing.allocator.free(escape);
    const direct = try std.fmt.allocPrint(testing.allocator, "{s}\\y.ts", .{repo.outside_abs});
    defer testing.allocator.free(direct);
    for ([_][]const u8{ escape, direct }) |file| {
        const response = try call(&repo, &.{.{ .file = file }});
        defer testing.allocator.free(response);
        try expectRefused(response, "FileOutsideRepo");
    }
    try testing.expect(!repo.exists("outside/x.ts"));
    try testing.expect(!repo.exists("outside/y.ts"));
}

test "redteam batch create: a create under .git or .emetgate is refused as an internal path" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.tmp.dir.createDirPath(testing.io, "repo/" ++ shadow.workspace_dir);
    const in_git = try std.fmt.allocPrint(testing.allocator, "{s}\\.git\\hooks.ts", .{repo.root_abs});
    defer testing.allocator.free(in_git);
    const in_workspace = try std.fmt.allocPrint(testing.allocator, "{s}\\{s}\\x.ts", .{ repo.root_abs, shadow.workspace_dir });
    defer testing.allocator.free(in_workspace);
    for ([_][]const u8{ in_git, in_workspace }) |file| {
        const response = try call(&repo, &.{.{ .file = file }});
        defer testing.allocator.free(response);
        try expectRefused(response, "InternalPath");
    }
    try testing.expect(!repo.exists("repo/.git/hooks.ts"));
    try testing.expect(!repo.exists("repo/" ++ shadow.workspace_dir ++ "/x.ts"));
}

test "redteam batch create: the same new path twice in one batch is refused and creates nothing" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const file = try std.fmt.allocPrint(testing.allocator, "{s}\\src\\new.ts", .{repo.root_abs});
    defer testing.allocator.free(file);
    const response = try call(&repo, &.{ .{ .file = file }, .{ .file = file, .symbol = "other", .body = "export function other(): number { return 2; }" } });
    defer testing.allocator.free(response);
    try expectRefused(response, "DuplicateBatchFile");
    try testing.expect(!repo.exists("repo/src/new.ts"));
}

test "redteam batch create: a create through a junction that leaves the repository is refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const link = try std.fmt.allocPrint(testing.allocator, "{s}\\src\\link", .{repo.root_abs});
    defer testing.allocator.free(link);
    try shadow.createJunction(testing.io, link, repo.outside_abs);
    const file = try std.fmt.allocPrint(testing.allocator, "{s}\\z.ts", .{link});
    defer testing.allocator.free(file);
    const response = try call(&repo, &.{.{ .file = file }});
    defer testing.allocator.free(response);
    try expectRefused(response, "FileOutsideRepo");
    try testing.expect(!repo.exists("outside/z.ts"));
}

test "redteam batch create: a new file in a batch is committed with a symmetry class and indexed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const file = try std.fmt.allocPrint(testing.allocator, "{s}\\src\\fresh.ts", .{repo.root_abs});
    defer testing.allocator.free(file);
    const response = try call(&repo, &.{.{ .file = file }});
    defer testing.allocator.free(response);
    errdefer std.debug.print("response: {s}\n", .{response});
    try testing.expect(std.mem.indexOf(u8, response, "committed") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\\\"class\\\":\\\"symmetry\\\"") != null);
    try testing.expect(repo.exists("repo/src/fresh.ts"));
}
