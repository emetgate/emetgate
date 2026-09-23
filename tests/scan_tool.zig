const std = @import("std");
const git_fixture = @import("git_fixture.zig");
const builtin = @import("builtin");
const server = @import("../src/protocol/server.zig");
const Runtime = @import("../src/engine/runtime.zig").Runtime;

const testing = std.testing;
const Value = std.json.Value;

const ledger_row = "{\"id\":\"mf\",\"scope\":\"project\",\"text\":\"no networkidle\",\"enforce\":true,\"check\":\"forbid:networkidle\",\"status\":\"active\",\"supersedes\":null,\"ts\":1}\n";

const Repo = struct {
    tmp: testing.TmpDir,
    root_abs: [:0]u8,

    fn init(files: []const [2][]const u8) !Repo {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo/src");
        for (files) |file| {
            const sub = try std.fmt.allocPrint(testing.allocator, "repo/{s}", .{file[0]});
            defer testing.allocator.free(sub);
            try tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = file[1] });
        }
        const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", testing.allocator);
        errdefer testing.allocator.free(root_abs);
        try git_fixture.initRepo(root_abs);
        try git(root_abs, &.{ "add", "." });
        try git(root_abs, &.{ "commit", "-q", "--allow-empty", "-m", "init" });
        return .{ .tmp = tmp, .root_abs = root_abs };
    }

    fn deinit(self: *Repo) void {
        testing.allocator.free(self.root_abs);
        self.tmp.cleanup();
    }

    fn hasWorkspace(self: *Repo) bool {
        self.tmp.dir.access(testing.io, "repo/.emetgate", .{}) catch return false;
        return true;
    }
};

fn git(cwd: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(testing.allocator);
    try argv.append(testing.allocator, "git");
    try argv.appendSlice(testing.allocator, args);
    const result = try std.process.run(testing.allocator, testing.io, .{ .argv = argv.items, .cwd = .{ .path = cwd } });
    testing.allocator.free(result.stdout);
    testing.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

fn skipOffWindows() !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
}

const Reply = struct {
    envelope: std.json.Parsed(Value),
    body: ?std.json.Parsed(Value),
    is_error: bool,

    fn deinit(self: *Reply) void {
        if (self.body) |*b| b.deinit();
        self.envelope.deinit();
    }

    fn field(self: Reply, name: []const u8) Value {
        return self.body.?.value.object.get(name).?;
    }
};

fn call(repo: *Repo, args: anytype) !Reply {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch |err| std.debug.panic("runtime closed with live allocations: {t}", .{err});
    var line: std.Io.Writer.Allocating = .init(testing.allocator);
    defer line.deinit();
    var js: std.json.Stringify = .{ .writer = &line.writer };
    try js.write(.{ .jsonrpc = "2.0", .id = 1, .method = "tools/call", .params = .{ .name = "emetgate_scan", .arguments = args } });

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    _ = try server.handleMessageObserved(testing.allocator, testing.io, runtime, line.written(), &out.writer, null, .{ .root = repo.root_abs });

    const envelope = try std.json.parseFromSlice(Value, testing.allocator, out.written(), .{ .allocate = .alloc_always });
    errdefer envelope.deinit();
    const result = envelope.value.object.get("result") orelse return .{ .envelope = envelope, .body = null, .is_error = true };
    const text = result.object.get("content").?.array.items[0].object.get("text").?.string;
    const body = try std.json.parseFromSlice(Value, testing.allocator, text, .{ .allocate = .alloc_always });
    return .{ .envelope = envelope, .body = body, .is_error = result.object.get("isError").?.bool };
}

fn expectRefused(repo: *Repo, args: anytype, name: []const u8) !void {
    var reply = try call(repo, args);
    defer reply.deinit();
    try testing.expect(reply.is_error);
    try testing.expectEqualStrings("error", reply.field("status").string);
    try testing.expectEqualStrings(name, reply.field("error").string);
}

test "scan tool: tools/list offers emetgate_scan with check required and where optional" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    _ = try server.handleMessage(testing.allocator, testing.io, undefined, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}", &out.writer);
    const parsed = try std.json.parseFromSlice(Value, testing.allocator, out.written(), .{});
    defer parsed.deinit();
    for (parsed.value.object.get("result").?.object.get("tools").?.array.items) |tool| {
        if (!std.mem.eql(u8, tool.object.get("name").?.string, "emetgate_scan")) continue;
        const schema = tool.object.get("inputSchema").?.object;
        const props = schema.get("properties").?.object;
        try testing.expectEqual(@as(usize, 2), props.count());
        try testing.expectEqualStrings("string", props.get("check").?.object.get("type").?.string);
        try testing.expectEqualStrings("string", props.get("where").?.object.get("type").?.string);
        const required = schema.get("required").?.array.items;
        try testing.expectEqual(@as(usize, 1), required.len);
        try testing.expectEqualStrings("check", required[0].string);
        return;
    }
    return error.ScanToolNotListed;
}

test "scan tool: a call without check or with a non-string where is a missing argument" {
    try skipOffWindows();
    var repo = try Repo.init(&.{.{ "src/a.ts", "networkidle;\n" }});
    defer repo.deinit();
    inline for (.{ .{ .where = "src/a.ts" }, .{ .check = "forbid:networkidle", .where = 3 } }) |args| {
        var reply = try call(&repo, args);
        defer reply.deinit();
        try testing.expect(reply.body == null);
        const err = reply.envelope.value.object.get("error").?.object;
        try testing.expectEqual(@as(i64, -32602), err.get("code").?.integer);
        try testing.expectEqualStrings("Missing or invalid argument", err.get("message").?.string);
    }
}

test "scan tool: a malformed check is refused by its existing error name" {
    try skipOffWindows();
    var repo = try Repo.init(&.{.{ "src/a.ts", "networkidle;\n" }});
    defer repo.deinit();
    try expectRefused(&repo, .{ .check = "frbid:x" }, "UnknownCheck");
    var reply = try call(&repo, .{ .check = "forbid:" });
    defer reply.deinit();
    try testing.expect(reply.is_error);
    try testing.expectEqualStrings("forbid:", reply.field("check").string);
}

test "scan tool: an invalid where is refused by its existing error name" {
    try skipOffWindows();
    var repo = try Repo.init(&.{.{ "src/a.ts", "networkidle;\n" }});
    defer repo.deinit();
    for ([_][]const u8{ "src/*.ts", "../x.ts", "C:/x.ts", ".git/config" }, [_][]const u8{ "WhereGlob", "WhereParentSegment", "WhereAbsolute", "WhereInternal" }) |bad, name| {
        try expectRefused(&repo, .{ .check = "forbid:networkidle", .where = bad }, name);
    }
    try expectRefused(&repo, .{ .check = "forbid:networkidle", .where = "src/gone.ts" }, "ScopeUnresolved");
}

test "scan tool: violations are reported with the scan json fields" {
    try skipOffWindows();
    var repo = try Repo.init(&.{ .{ "src/a.ts", "networkidle;\nexport function a() {\n  wait(\"networkidle\");\n}\n" }, .{ "src/b.ts", "networkidle;\n" } });
    defer repo.deinit();
    var reply = try call(&repo, .{ .check = "forbid:networkidle", .where = "src/a.ts" });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings("violations", reply.field("status").string);
    try testing.expectEqual(@as(i64, 1), reply.field("rules").integer);
    try testing.expectEqual(@as(i64, 1), reply.field("scanned").integer);
    try testing.expectEqual(@as(i64, 1), reply.field("out_of_scope").integer);
    try testing.expectEqual(@as(i64, 2), reply.field("violation_count").integer);
    try testing.expect(!reply.field("truncated").bool);
    const violations = reply.field("violations").array.items;
    try testing.expectEqual(@as(usize, 2), violations.len);
    try testing.expectEqualStrings("src/a.ts", violations[1].object.get("file").?.string);
    try testing.expectEqual(@as(i64, 3), violations[1].object.get("line").?.integer);
    try testing.expectEqual(@as(i64, 9), violations[1].object.get("col").?.integer);
}

test "scan tool: a clean check reports no violations" {
    try skipOffWindows();
    var repo = try Repo.init(&.{.{ "src/a.ts", "export function a() {\n  return 1;\n}\n" }});
    defer repo.deinit();
    var reply = try call(&repo, .{ .check = "forbid:networkidle" });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings("clean", reply.field("status").string);
    try testing.expectEqual(@as(i64, 1), reply.field("scanned").integer);
    try testing.expectEqual(@as(i64, 0), reply.field("violation_count").integer);
    try testing.expect(!reply.field("truncated").bool);
    try testing.expectEqual(@as(usize, 0), reply.field("violations").array.items.len);
}

test "scan tool: more violations than the cap are cut and the report says so" {
    try skipOffWindows();
    const many = "networkidle;\n" ** 150;
    var repo = try Repo.init(&.{.{ "src/a.ts", many }});
    defer repo.deinit();
    var reply = try call(&repo, .{ .check = "forbid:networkidle" });
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    try testing.expectEqual(@as(usize, 100), reply.field("violations").array.items.len);
    try testing.expectEqual(@as(i64, 150), reply.field("violation_count").integer);
    try testing.expect(reply.field("truncated").bool);
}

test "scan tool: exactly the cap is not cut" {
    try skipOffWindows();
    const many = "networkidle;\n" ** 100;
    var repo = try Repo.init(&.{.{ "src/a.ts", many }});
    defer repo.deinit();
    var reply = try call(&repo, .{ .check = "forbid:networkidle" });
    defer reply.deinit();
    try testing.expectEqual(@as(usize, 100), reply.field("violations").array.items.len);
    try testing.expect(!reply.field("truncated").bool);
}

test "scan tool: a call creates no workspace and leaves the ledger untouched" {
    try skipOffWindows();
    var repo = try Repo.init(&.{.{ "src/a.ts", "networkidle;\n" }});
    defer repo.deinit();
    {
        var reply = try call(&repo, .{ .check = "forbid:networkidle" });
        defer reply.deinit();
    }
    try testing.expect(!repo.hasWorkspace());

    try repo.tmp.dir.createDirPath(testing.io, "repo/.emetgate");
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.emetgate/ledger.ndjson", .data = ledger_row });
    {
        var reply = try call(&repo, .{ .check = "no_comment" });
        defer reply.deinit();
        try testing.expectEqual(@as(i64, 1), reply.field("rules").integer);
    }
    const after = try repo.tmp.dir.readFileAlloc(testing.io, "repo/.emetgate/ledger.ndjson", testing.allocator, .unlimited);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(ledger_row, after);
    var dir = try repo.tmp.dir.openDir(testing.io, "repo/.emetgate", .{ .iterate = true });
    defer dir.close(testing.io);
    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next(testing.io)) |_| count += 1;
    try testing.expectEqual(@as(usize, 1), count);
}
