const std = @import("std");
const builtin = @import("builtin");
const fixture = @import("run_fixture.zig");
const server = @import("emetgate").server;
const shadow = @import("emetgate").shadow;
const symbol = @import("emetgate").symbol;
const Runtime = @import("emetgate").runtime.Runtime;

const testing = std.testing;
const gpa = testing.allocator;

const notes = "line one\nline two\n";
const kept_field = "\"gate_tree\":{\"kind\":\"kept\",\"private_copies\":0}";
const copy_field = "\"gate_tree\":{\"kind\":\"full_copy\",\"reason\":\"requested\"}";

fn newRepo() !fixture.Repo {
    return fixture.Repo.init(&.{
        .{ .name = "say.cmd", .body = "@echo off\r\necho ran\r\n" },
        .{ .name = "notes.txt", .body = notes },
    });
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

fn expectHas(reply: []const u8, needle: []const u8) !void {
    errdefer std.debug.print("reply: {s}\nwanted: {s}\n", .{ reply, needle });
    try testing.expect(std.mem.indexOf(u8, reply, needle) != null);
}

fn policies(root_abs: []const u8) [2]server.Policy {
    var kept = fixture.policyWith(root_abs, &.{".\\say.cmd"});
    kept.test_command = "cmd /c exit 1";
    var copy = kept;
    copy.shadow_tree = .full_copy;
    return .{ kept, copy };
}

test "gate tree replies: a run reply says which tree was used, and two servers in one process keep their own choice" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try newRepo();
    defer repo.deinit();
    const pair = policies(repo.root_abs);
    for ([_]usize{ 0, 1, 0, 1, 1, 0 }) |which| {
        const reply = try run(pair[which]);
        defer gpa.free(reply);
        try expectHas(reply, "\"status\":\"ran\"");
        try expectHas(reply, if (which == 0) kept_field else copy_field);
    }
}

test "gate tree replies: a rejected doc write says which tree was used, for each server's own choice" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try newRepo();
    defer repo.deinit();
    const pair = policies(repo.root_abs);
    for ([_]usize{ 1, 0, 1, 0 }) |which| {
        const reply = try writeDoc(pair[which], repo.root_abs);
        defer gpa.free(reply);
        try expectHas(reply, "\"status\":\"rejected\"");
        try expectHas(reply, if (which == 0) kept_field else copy_field);
        try testing.expect(std.mem.indexOf(u8, reply, "\"shadow\":") == null);
    }
    const on_disk = try repo.tmp.dir.readFileAlloc(testing.io, "repo/notes.txt", gpa, .unlimited);
    defer gpa.free(on_disk);
    try testing.expectEqualStrings(notes, on_disk);
}

test "gate tree replies: a repository on another volume, or a volume without hard links, gets a full copy and the reply gives the reason" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try newRepo();
    defer repo.deinit();
    const kept = policies(repo.root_abs)[0];
    defer shadow.injected_probe = .{};

    shadow.injected_probe = .{ .tree_volume = 0x1234_5678_9abc_def0 };
    const other = try run(kept);
    defer gpa.free(other);
    try expectHas(other, "\"status\":\"ran\"");
    try expectHas(other, "\"gate_tree\":{\"kind\":\"full_copy\",\"reason\":\"other_volume\"}");

    shadow.injected_probe = .{ .hard_links = false };
    const unsupported = try writeDoc(kept, repo.root_abs);
    defer gpa.free(unsupported);
    try expectHas(unsupported, "\"gate_tree\":{\"kind\":\"full_copy\",\"reason\":\"no_hard_links\"}");

    shadow.injected_probe = .{};
    const again = try run(kept);
    defer gpa.free(again);
    try expectHas(again, kept_field);
}

test "gate tree replies: a full copy that could not be removed after the call is named in the reply, a compact committed one included" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try newRepo();
    defer repo.deinit();
    var copy = policies(repo.root_abs)[1];
    defer shadow.injected_probe = .{};
    const left_field = "\"gate_tree\":{\"kind\":\"full_copy\",\"reason\":\"requested\",\"left_behind\":\"FileBusy\"}";

    shadow.injected_probe = .{ .removal = error.FileBusy };
    const ran = try run(copy);
    defer gpa.free(ran);
    try expectHas(ran, "\"status\":\"ran\"");
    try expectHas(ran, left_field);

    const rejected = try writeDoc(copy, repo.root_abs);
    defer gpa.free(rejected);
    try expectHas(rejected, "\"status\":\"rejected\"");
    try expectHas(rejected, left_field);

    copy.test_command = "cmd /c exit 0";
    const committed = try writeDoc(copy, repo.root_abs);
    defer gpa.free(committed);
    try expectHas(committed, "\"status\":\"committed\"");
    try expectHas(committed, left_field);
    try testing.expect(std.mem.indexOf(u8, committed, "\"shadow\":") == null);

    shadow.injected_probe = .{};
    const clean = try run(copy);
    defer gpa.free(clean);
    try expectHas(clean, copy_field);
    try testing.expect(std.mem.indexOf(u8, clean, "left_behind") == null);
}
