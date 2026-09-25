const std = @import("std");
const builtin = @import("builtin");
const git_fixture = @import("git_fixture.zig");
const server = @import("emetgate").server;
const symbol = @import("emetgate").symbol;
const shadow = @import("emetgate").shadow;
const Runtime = @import("emetgate").runtime.Runtime;

const testing = std.testing;

const math = "export function add(a: number, b: number): number {\n  return a + b;\n}\n";
const user = "import { add } from './math';\nexport function total(): number {\n  return add(1, 2);\n}\n";
const spare = "export function unused(): number {\n  return 7;\n}\n";

const Repo = struct {
    tmp: testing.TmpDir,
    root_abs: [:0]u8,
    outside_abs: [:0]u8,

    fn init() !Repo {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo/src");
        try tmp.dir.createDirPath(testing.io, "outside");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/math.ts", .data = math });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/user.ts", .data = user });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/spare.ts", .data = spare });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "outside/x.ts", .data = spare });
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

    fn path(self: *Repo, rel: []const u8) ![]u8 {
        return std.fmt.allocPrint(testing.allocator, "{s}\\{s}", .{ self.root_abs, rel });
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
    symbol: ?[]const u8 = null,
    hash: ?[]const u8 = null,
};

fn deleteLine(items: []const Item) ![]u8 {
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
        try js.objectField("op");
        try js.write("delete");
        if (item.symbol) |s| {
            try js.objectField("symbol");
            try js.write(s);
        }
        if (item.hash) |h| {
            try js.objectField("hash");
            try js.write(h);
        }
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
    const line = try deleteLine(items);
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

fn symbolHash(source: []const u8, name: []const u8) ![symbol.hash_hex_len]u8 {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const snapshot = try @import("emetgate").test_util.snapshotOf(runtime, source);
    defer snapshot.destroy();
    return symbol.formatHash((try (try snapshot.symbols()).resolve(.{ .name = name })).hash);
}

test "redteam batch delete: a symbol that another tracked file calls is refused and the file is untouched" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const file = try repo.path("src\\math.ts");
    defer testing.allocator.free(file);
    const hash = try symbolHash(math, "add");
    const response = try call(&repo, &.{.{ .file = file, .symbol = "add", .hash = &hash }});
    defer testing.allocator.free(response);
    try expectRefused(response, "SymbolReferenced");
    const on_disk = try repo.tmp.dir.readFileAlloc(testing.io, "repo/src/math.ts", testing.allocator, .unlimited);
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(math, on_disk);
}

test "redteam batch delete: deleting a file outside the served repository is refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const escape = try std.fmt.allocPrint(testing.allocator, "{s}\\..\\outside\\x.ts", .{repo.root_abs});
    defer testing.allocator.free(escape);
    const response = try call(&repo, &.{.{ .file = escape }});
    defer testing.allocator.free(response);
    try expectRefused(response, "FileOutsideRepo");
    try testing.expect(repo.exists("outside/x.ts"));
}

test "redteam batch delete: deleting under .git or .emetgate is refused as an internal path" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.tmp.dir.createDirPath(testing.io, "repo/" ++ shadow.workspace_dir);
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/" ++ shadow.workspace_dir ++ "/keep.json", .data = "{}" });
    const head = try repo.path(".git\\HEAD");
    defer testing.allocator.free(head);
    const kept = try repo.path(shadow.workspace_dir ++ "\\keep.json");
    defer testing.allocator.free(kept);
    for ([_][]const u8{ head, kept }) |file| {
        const response = try call(&repo, &.{.{ .file = file }});
        defer testing.allocator.free(response);
        try expectRefused(response, "InternalPath");
    }
    try testing.expect(repo.exists("repo/.git/HEAD"));
    try testing.expect(repo.exists("repo/" ++ shadow.workspace_dir ++ "/keep.json"));
}

test "redteam batch delete: a stale whole-file hash is refused and the file stays" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const file = try repo.path("src\\spare.ts");
    defer testing.allocator.free(file);
    const stale = symbol.formatHash(symbol.hashOf("an older version"));
    const response = try call(&repo, &.{.{ .file = file, .hash = &stale }});
    defer testing.allocator.free(response);
    try expectRefused(response, "HashMismatch");
    try testing.expect(repo.exists("repo/src/spare.ts"));
}

test "redteam batch delete: deleting through a symlink is refused and its target stays" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    repo.tmp.dir.symLink(testing.io, "spare.ts", "repo/src/link.ts", .{}) catch return error.SkipZigTest;
    const file = try repo.path("src\\link.ts");
    defer testing.allocator.free(file);
    const response = try call(&repo, &.{.{ .file = file }});
    defer testing.allocator.free(response);
    try expectRefused(response, "ReparsePoint");
    try testing.expect(repo.exists("repo/src/spare.ts"));
}

test "redteam batch delete: an unreferenced file is deleted through the tool and reported as deleted" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const file = try repo.path("src\\spare.ts");
    defer testing.allocator.free(file);
    const current = symbol.formatHash(symbol.hashOf(spare));
    const response = try call(&repo, &.{.{ .file = file, .hash = &current }});
    defer testing.allocator.free(response);
    errdefer std.debug.print("response: {s}\n", .{response});
    try testing.expect(std.mem.indexOf(u8, response, "committed") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\\\"deleted\\\":true") != null);
    try testing.expect(!repo.exists("repo/src/spare.ts"));
}
