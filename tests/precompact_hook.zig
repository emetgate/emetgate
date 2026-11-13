const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");
const compaction_marker = emetgate.compaction_marker;
const precompact_hook = emetgate.precompact_hook;
const lockdown_slash = emetgate.lockdown_slash;
const git_fixture = @import("git_fixture.zig");

const testing = std.testing;

const Repo = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,

    fn init() !Repo {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        errdefer testing.allocator.free(root);
        try git_fixture.initRepo(root);
        return .{ .tmp = tmp, .root = root };
    }

    fn deinit(self: *Repo) void {
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn marker(self: *Repo) ![]u8 {
        return self.tmp.dir.readFileAlloc(testing.io, ".emetgate/compacted", testing.allocator, .limited(64));
    }
};

fn hookInput(cwd: []const u8, trigger: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(testing.allocator, .{
        .session_id = "11111111-2222-3333-4444-555555555555",
        .transcript_path = "C:\\Users\\u\\.claude\\projects\\x\\t.jsonl",
        .cwd = cwd,
        .hook_event_name = "PreCompact",
        .trigger = trigger,
        .custom_instructions = "",
    }, .{});
}

test "precompact hook: generation reads 0 while there is no marker" {
    var repo = try Repo.init();
    defer repo.deinit();
    try testing.expectEqual(@as(u64, 0), compaction_marker.generation(testing.io, repo.root));
    try testing.expectEqual(@as(u64, 0), compaction_marker.generation(testing.io, "C:\\no\\such\\emetgate\\root"));
}

test "precompact hook: generation reads 0 for a marker that is not a number" {
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.tmp.dir.createDirPath(testing.io, ".emetgate");
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = ".emetgate/compacted", .data = "not a number\n" });
    try testing.expectEqual(@as(u64, 0), compaction_marker.generation(testing.io, repo.root));
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = ".emetgate/compacted", .data = "42\r\n" });
    try testing.expectEqual(@as(u64, 42), compaction_marker.generation(testing.io, repo.root));
}

test "precompact hook: each compaction writes a marker whose number grows" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const manual = try hookInput(repo.root, "manual");
    defer testing.allocator.free(manual);
    const auto = try hookInput(repo.root, "auto");
    defer testing.allocator.free(auto);

    const first = precompact_hook.record(testing.allocator, testing.io, repo.root, manual) orelse return error.TestExpectedMarker;
    try testing.expect(first > 0);
    try testing.expectEqual(first, compaction_marker.generation(testing.io, repo.root));
    const text = try repo.marker();
    defer testing.allocator.free(text);
    const want = try std.fmt.allocPrint(testing.allocator, "{d}\n", .{first});
    defer testing.allocator.free(want);
    try testing.expectEqualStrings(want, text);

    var last = first;
    for (0..3) |_| {
        const now = precompact_hook.record(testing.allocator, testing.io, repo.root, auto) orelse return error.TestExpectedMarker;
        try testing.expect(now > last);
        try testing.expectEqual(now, compaction_marker.generation(testing.io, repo.root));
        last = now;
    }

    var workspace = try repo.tmp.dir.openDir(testing.io, ".emetgate", .{ .iterate = true });
    defer workspace.close(testing.io);
    var it = workspace.iterate();
    var names: usize = 0;
    while (try it.next(testing.io)) |entry| {
        names += 1;
        try testing.expect(std.mem.eql(u8, entry.name, "compacted") or std.mem.eql(u8, entry.name, ".gitignore"));
    }
    try testing.expectEqual(@as(usize, 2), names);
}

test "precompact hook: a marker written again after it was deleted still grows" {
    try testing.expectEqual(@as(u64, 8), compaction_marker.next(7, 3));
    try testing.expectEqual(@as(u64, 1000), compaction_marker.next(7, 1000));
    try testing.expectEqual(@as(u64, 1), compaction_marker.next(0, -5));
    try testing.expectEqual(std.math.maxInt(u64), compaction_marker.next(std.math.maxInt(u64), 0));
}

test "precompact hook: stdin that is not hook JSON still marks the directory the hook runs in" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const inputs = [_][]const u8{ "", "not json", "[1,2]", "{\"cwd\":7}", "{\"cwd\":\"\"}", "{\"trigger\":\"manual\",\"extra\":{\"x\":[null]}}", "{\"cwd\":\"C:\\\\no\\\\such\\\\dir\"}" };
    var last: u64 = 0;
    for (inputs) |input| {
        const now = precompact_hook.record(testing.allocator, testing.io, repo.root, input) orelse return error.TestExpectedMarker;
        try testing.expect(now > last);
        last = now;
    }
}

test "precompact hook: the cwd in the hook JSON wins over the directory the hook runs in" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var named = try Repo.init();
    defer named.deinit();
    var other = try Repo.init();
    defer other.deinit();
    const input = try hookInput(named.root, "auto");
    defer testing.allocator.free(input);
    const value = precompact_hook.record(testing.allocator, testing.io, other.root, input) orelse return error.TestExpectedMarker;
    try testing.expectEqual(value, compaction_marker.generation(testing.io, named.root));
    try testing.expectEqual(@as(u64, 0), compaction_marker.generation(testing.io, other.root));
}

test "precompact hook: lockdown settings run it for every compaction in exec form" {
    const exe = "C:\\tools\\emetgate.exe";
    const json = try lockdown_slash.settingsJson(testing.allocator, exe);
    defer testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const groups = parsed.value.object.get("hooks").?.object.get("PreCompact").?.array.items;
    try testing.expectEqual(@as(usize, 1), groups.len);
    try testing.expect(groups[0].object.get("matcher") == null);
    const handlers = groups[0].object.get("hooks").?.array.items;
    try testing.expectEqual(@as(usize, 1), handlers.len);
    try testing.expectEqualStrings("command", handlers[0].object.get("type").?.string);
    try testing.expectEqualStrings(exe, handlers[0].object.get("command").?.string);
    const args = handlers[0].object.get("args").?.array.items;
    try testing.expectEqual(@as(usize, 2), args.len);
    try testing.expectEqualStrings("hook", args[0].string);
    try testing.expectEqualStrings("precompact", args[1].string);
    try testing.expectEqualStrings(precompact_hook.hook_args[1], "precompact");
}
