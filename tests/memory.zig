const std = @import("std");
const builtin = @import("builtin");
const memory = @import("../src/platform/memory.zig");
const shadow = @import("../src/platform/shadow.zig");

const testing = std.testing;

const a_active = "{\"id\":\"ma\",\"scope\":\"project\",\"text\":\"use Money for amounts\",\"enforce\":true,\"check\":null,\"status\":\"active\",\"supersedes\":null,\"ts\":1}\n";
const b_active = "{\"id\":\"mb\",\"scope\":\"file\",\"text\":\"no comments\",\"enforce\":false,\"check\":\"no_comment\",\"status\":\"active\",\"supersedes\":null,\"ts\":2}\n";
const a_forgotten = "{\"id\":\"ma\",\"scope\":\"project\",\"text\":\"use Money for amounts\",\"enforce\":true,\"check\":null,\"status\":\"superseded\",\"supersedes\":null,\"ts\":3}\n";
const c_supersedes_a = "{\"id\":\"mc\",\"scope\":\"project\",\"text\":\"use Money and Currency\",\"enforce\":true,\"check\":null,\"status\":\"active\",\"supersedes\":\"ma\",\"ts\":4}\n";

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

    fn path(name: []const u8) ![]u8 {
        return std.fmt.allocPrint(testing.allocator, ".synapse/{s}", .{name});
    }

    fn put(self: *Store, name: []const u8, bytes: []const u8) !void {
        try self.tmp.dir.createDirPath(testing.io, ".synapse");
        const p = try path(name);
        defer testing.allocator.free(p);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = p, .data = bytes });
    }

    fn get(self: *Store, name: []const u8) ![]u8 {
        const p = try path(name);
        defer testing.allocator.free(p);
        return self.tmp.dir.readFileAlloc(testing.io, p, testing.allocator, .unlimited);
    }

    fn exists(self: *Store, name: []const u8) bool {
        const p = path(name) catch return false;
        defer testing.allocator.free(p);
        self.tmp.dir.access(testing.io, p, .{}) catch return false;
        return true;
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
    try store.put(memory.ledger_name, a_active ++ b_active ++ a_forgotten);

    const recalled = try memory.recall(testing.allocator, testing.io, store.root);
    defer recalled.deinit();
    try expectIds(recalled.decisions, &.{"mb"});
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
    try testing.expectEqual(@as(usize, 4), rows.len);
    try testing.expectEqualStrings(replacement, rows[2].decision.id);
    try testing.expectEqual(memory.Status.active, rows[2].decision.status);
    try testing.expectEqualStrings(first, rows[2].decision.supersedes.?);
    try testing.expectEqualStrings(second, rows[3].decision.id);
    try testing.expectEqual(memory.Status.superseded, rows[3].decision.status);
}

test "memory: a corrupt ledger line before the end is refused, not skipped" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const bad = [_][]const u8{
        a_active ++ "{not json\n" ++ b_active,
        a_active ++ "{\"id\":\"mx\",\"scope\":\"team\",\"text\":\"t\",\"enforce\":true,\"check\":null,\"status\":\"active\",\"supersedes\":null,\"ts\":9}\n" ++ b_active,
        a_active ++ "\n" ++ b_active,
        a_forgotten,
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

test "memory: supersede retires the prior decision in the same row" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var store = try Store.init();
    defer store.deinit();
    try store.put(memory.ledger_name, a_active ++ c_supersedes_a);

    try testing.expectError(error.DecisionNotActive, memory.forget(testing.allocator, testing.io, store.root, "ma"));
    try testing.expectError(error.DecisionNotActive, memory.supersede(testing.allocator, testing.io, store.root, "ma", .project, "again", true, null));
    const after = try store.get(memory.ledger_name);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(a_active ++ c_supersedes_a, after);
}

test "memory: compact drops retired history and never an active decision" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var store = try Store.init();
    defer store.deinit();
    try store.put(memory.ledger_name, a_active ++ b_active ++ a_forgotten);

    try memory.compact(testing.allocator, testing.io, store.root);
    const compacted = try store.get(memory.ledger_name);
    defer testing.allocator.free(compacted);
    try testing.expectEqualStrings(b_active, compacted);

    const recalled = try memory.recall(testing.allocator, testing.io, store.root);
    defer recalled.deinit();
    try expectIds(recalled.decisions, &.{"mb"});
}

test "memory: compact collapses a supersede chain without leaving a dangling pointer" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var store = try Store.init();
    defer store.deinit();
    try store.put(memory.ledger_name, a_active ++ c_supersedes_a);

    try memory.compact(testing.allocator, testing.io, store.root);
    const recalled = try memory.recall(testing.allocator, testing.io, store.root);
    defer recalled.deinit();

    const compacted = try store.get(memory.ledger_name);
    defer testing.allocator.free(compacted);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for (try memory.parseLedger(arena.allocator(), compacted)) |row| try testing.expect(row.decision.supersedes == null);
}

test "memory: a held memory lock blocks every operation and the repo lock does not" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var store = try Store.init();
    defer store.deinit();
    try store.tmp.dir.createDirPath(testing.io, ".synapse");
    const lock_path = try std.fmt.allocPrint(testing.allocator, "{s}\\.synapse\\{s}", .{ store.root, memory.lock_name });
    defer testing.allocator.free(lock_path);

    const held = try shadow.FileLock.acquire(lock_path);
    try testing.expectError(error.MemoryBusy, memory.remember(testing.allocator, testing.io, store.root, .global, "blocked", false, null));
    try testing.expectError(error.MemoryBusy, memory.recall(testing.allocator, testing.io, store.root));
    try testing.expectError(error.MemoryBusy, memory.compact(testing.allocator, testing.io, store.root));
    held.release();

    const repo = try shadow.Lock.acquire(testing.io, store.root);
    defer repo.release();
    const id = try memory.remember(testing.allocator, testing.io, store.root, .global, "repo lock is separate", false, null);
    defer testing.allocator.free(id);
}

test "memory: recall folds the ledger and never creates state.bin" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var store = try Store.init();
    defer store.deinit();
    try store.put(memory.ledger_name, a_active ++ b_active ++ a_forgotten);

    const recalled = try memory.recall(testing.allocator, testing.io, store.root);
    recalled.deinit();
    try memory.compact(testing.allocator, testing.io, store.root);
    try testing.expect(!store.exists("state.bin"));
}
