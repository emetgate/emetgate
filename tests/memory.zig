const std = @import("std");
const builtin = @import("builtin");
const memory = @import("../src/platform/memory.zig");
const shadow = @import("../src/platform/shadow.zig");

const testing = std.testing;

const a_active = "{\"id\":\"ma\",\"scope\":\"project\",\"text\":\"use Money for amounts\",\"enforce\":true,\"check\":null,\"status\":\"active\",\"supersedes\":null,\"ts\":1}\n";
const b_active = "{\"id\":\"mb\",\"scope\":\"file\",\"text\":\"no comments\",\"enforce\":false,\"check\":\"no_comment\",\"status\":\"active\",\"supersedes\":null,\"ts\":2}\n";
const a_superseded = "{\"id\":\"ma\",\"scope\":\"project\",\"text\":\"use Money for amounts\",\"enforce\":true,\"check\":null,\"status\":\"superseded\",\"supersedes\":null,\"ts\":3}\n";
const c_active = "{\"id\":\"mc\",\"scope\":\"project\",\"text\":\"use Money and Currency\",\"enforce\":true,\"check\":null,\"status\":\"active\",\"supersedes\":\"ma\",\"ts\":3}\n";
const history = a_active ++ b_active ++ a_superseded ++ c_active;

const Store = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,

    fn init() !Store {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        return .{ .tmp = tmp, .root = root };
    }

    fn deinit(self: *Store) void {
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn put(self: *Store, name: []const u8, bytes: []const u8) !void {
        try self.tmp.dir.createDirPath(testing.io, ".synapse");
        const path = try std.fmt.allocPrint(testing.allocator, ".synapse/{s}", .{name});
        defer testing.allocator.free(path);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = bytes });
    }

    fn get(self: *Store, name: []const u8) ![]u8 {
        const path = try std.fmt.allocPrint(testing.allocator, ".synapse/{s}", .{name});
        defer testing.allocator.free(path);
        return self.tmp.dir.readFileAlloc(testing.io, path, testing.allocator, .unlimited);
    }

    fn remove(self: *Store, name: []const u8) !void {
        const path = try std.fmt.allocPrint(testing.allocator, ".synapse/{s}", .{name});
        defer testing.allocator.free(path);
        try self.tmp.dir.deleteFile(testing.io, path);
    }
};

fn expectIds(decisions: []const memory.Decision, ids: []const []const u8) !void {
    try testing.expectEqual(ids.len, decisions.len);
    for (ids, decisions) |want, got| try testing.expectEqualStrings(want, got.id);
}

test "memory: recall returns only active decisions" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var store = try Store.init();
    defer store.deinit();
    try store.put(memory.ledger_name, history);

    const recalled = try memory.recall(testing.allocator, testing.io, store.root);
    defer recalled.deinit();
    try expectIds(recalled.decisions, &.{ "mb", "mc" });
    try testing.expectEqualStrings("ma", recalled.decisions[1].supersedes.?);
}

test "memory: operations append rows and never rewrite earlier ledger bytes" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var store = try Store.init();
    defer store.deinit();

    const first = try memory.remember(testing.allocator, testing.io, store.root, .project, "first", true, null);
    defer testing.allocator.free(first);
    const after_first = try store.get(memory.ledger_name);
    defer testing.allocator.free(after_first);

    const second = try memory.remember(testing.allocator, testing.io, store.root, .file, "second", false, "no_comment");
    defer testing.allocator.free(second);
    const after_second = try store.get(memory.ledger_name);
    defer testing.allocator.free(after_second);

    const replacement = try memory.supersede(testing.allocator, testing.io, store.root, first, .project, "first v2", true, null);
    defer testing.allocator.free(replacement);
    try memory.forget(testing.allocator, testing.io, store.root, second);
    const final = try store.get(memory.ledger_name);
    defer testing.allocator.free(final);

    try testing.expect(std.mem.startsWith(u8, after_second, after_first));
    try testing.expect(std.mem.startsWith(u8, final, after_second));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rows = try memory.parseLedger(arena.allocator(), final);
    try testing.expectEqual(@as(usize, 5), rows.len);
    try testing.expectEqualStrings(first, rows[2].decision.id);
    try testing.expectEqual(memory.Status.superseded, rows[2].decision.status);
    try testing.expectEqualStrings(replacement, rows[3].decision.id);
    try testing.expectEqualStrings(first, rows[3].decision.supersedes.?);
    try testing.expectEqualStrings(second, rows[4].decision.id);
    try testing.expectEqual(memory.Status.superseded, rows[4].decision.status);
}

test "memory: a corrupt or partial ledger line is refused, not skipped" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const bad = [_][]const u8{
        a_active ++ "{not json\n" ++ b_active,
        a_active ++ b_active[0 .. b_active.len - 1],
        a_active ++ "{\"id\":\"mx\",\"scope\":\"team\",\"text\":\"t\",\"enforce\":true,\"check\":null,\"status\":\"active\",\"supersedes\":null,\"ts\":9}\n",
        a_active ++ "\n" ++ b_active,
        a_superseded,
    };
    for (bad) |ledger| {
        var store = try Store.init();
        defer store.deinit();
        try store.put(memory.ledger_name, ledger);
        try testing.expectError(error.LedgerCorrupt, memory.recall(testing.allocator, testing.io, store.root));
        try testing.expectError(error.LedgerCorrupt, memory.remember(testing.allocator, testing.io, store.root, .global, "x", false, null));
        const after = try store.get(memory.ledger_name);
        defer testing.allocator.free(after);
        try testing.expectEqualStrings(ledger, after);
    }
}

test "memory: a stale state.bin is never trusted over the ledger" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var store = try Store.init();
    defer store.deinit();
    try store.put(memory.ledger_name, a_active);
    const first = try memory.recall(testing.allocator, testing.io, store.root);
    first.deinit();
    const stale = try store.get(memory.state_name);
    defer testing.allocator.free(stale);

    try store.put(memory.ledger_name, a_active ++ b_active);
    try store.put(memory.state_name, stale);
    const recalled = try memory.recall(testing.allocator, testing.io, store.root);
    defer recalled.deinit();
    try expectIds(recalled.decisions, &.{ "ma", "mb" });
}

test "memory: compact drops superseded history and never an active decision" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var store = try Store.init();
    defer store.deinit();
    try store.put(memory.ledger_name, history);

    try memory.compact(testing.allocator, testing.io, store.root);
    const compacted = try store.get(memory.ledger_name);
    defer testing.allocator.free(compacted);
    try testing.expectEqualStrings(b_active ++ c_active, compacted);

    const recalled = try memory.recall(testing.allocator, testing.io, store.root);
    defer recalled.deinit();
    try expectIds(recalled.decisions, &.{ "mb", "mc" });
}

test "memory: a held repo lock blocks writes and recall" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var store = try Store.init();
    defer store.deinit();

    const held = try shadow.Lock.acquire(testing.io, store.root);
    try testing.expectError(error.WorkspaceBusy, memory.remember(testing.allocator, testing.io, store.root, .global, "blocked", false, null));
    try testing.expectError(error.WorkspaceBusy, memory.recall(testing.allocator, testing.io, store.root));
    held.release();

    const id = try memory.remember(testing.allocator, testing.io, store.root, .global, "after release", false, null);
    defer testing.allocator.free(id);
}

test "memory: state.bin is a derived fold, rebuilt byte-identical from the untouched ledger" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var store = try Store.init();
    defer store.deinit();
    try store.put(memory.ledger_name, history);

    const original = try memory.recall(testing.allocator, testing.io, store.root);
    defer original.deinit();
    const state = try store.get(memory.state_name);
    defer testing.allocator.free(state);

    var original_ids: [8][]const u8 = undefined;
    for (original.decisions, 0..) |d, i| original_ids[i] = d.id;
    const ids = original_ids[0..original.decisions.len];

    try store.remove(memory.state_name);
    const rebuilt = try memory.recall(testing.allocator, testing.io, store.root);
    defer rebuilt.deinit();
    try expectIds(rebuilt.decisions, ids);
    const after_delete = try store.get(memory.state_name);
    defer testing.allocator.free(after_delete);
    try testing.expectEqualSlices(u8, state, after_delete);

    const wrong_magic = try testing.allocator.dupe(u8, state);
    defer testing.allocator.free(wrong_magic);
    wrong_magic[0] ^= 0xFF;
    const trailing = try std.mem.concat(testing.allocator, u8, &.{ state, "xx" });
    defer testing.allocator.free(trailing);

    for ([_][]const u8{ "junk", state[0 .. state.len - 3], wrong_magic, trailing }) |damaged| {
        try store.put(memory.state_name, damaged);
        const repaired = try memory.recall(testing.allocator, testing.io, store.root);
        defer repaired.deinit();
        try expectIds(repaired.decisions, ids);
        const after_repair = try store.get(memory.state_name);
        defer testing.allocator.free(after_repair);
        try testing.expectEqualSlices(u8, state, after_repair);
    }

    const ledger = try store.get(memory.ledger_name);
    defer testing.allocator.free(ledger);
    try testing.expectEqualStrings(history, ledger);
}
