const std = @import("std");
const symbol = @import("../engine/symbol.zig");

const Allocator = std.mem.Allocator;

pub const Hash = symbol.Hash;

pub const Outcome = enum { unchanged, changed };

pub const Entry = struct {
    hash: Hash,
    file_hash: ?Hash = null,
    call: u32 = 0,
};

pub const Undo = struct {
    key: []u8,
    previous: ?Entry,
};

pub const Journal = std.ArrayList(Undo);

pub const Mirror = struct {
    gpa: Allocator,
    enabled: bool,
    entries: std.StringHashMapUnmanaged(Entry) = .{},
    calls: u32 = 0,
    journal: ?*Journal = null,

    pub fn init(gpa: Allocator, enabled: bool) Mirror {
        return .{ .gpa = gpa, .enabled = enabled };
    }

    pub fn deinit(self: *Mirror) void {
        var it = self.entries.keyIterator();
        while (it.next()) |key| self.gpa.free(key.*);
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn tick(self: *Mirror) void {
        self.calls +|= 1;
    }

    pub fn check(self: *Mirror, key: []const u8, hash: Hash, force: bool) Allocator.Error!Outcome {
        return if (try self.seen(key, hash, null, force) == null) .changed else .unchanged;
    }

    pub fn seen(self: *Mirror, key: []const u8, hash: Hash, file_hash: ?Hash, force: bool) Allocator.Error!?u32 {
        if (!self.enabled) return null;
        if (!force) {
            if (self.entries.get(key)) |old| {
                if (std.mem.eql(u8, &old.hash, &hash) and sameFileHash(old.file_hash, file_hash)) return old.call;
            }
        }
        try self.put(key, .{ .hash = hash, .file_hash = file_hash, .call = self.calls });
        return null;
    }

    pub fn get(self: *const Mirror, key: []const u8) ?Entry {
        return self.entries.get(key);
    }

    fn put(self: *Mirror, key: []const u8, entry: Entry) Allocator.Error!void {
        if (self.journal) |journal| {
            const copy = try self.gpa.dupe(u8, key);
            errdefer self.gpa.free(copy);
            try journal.append(self.gpa, .{ .key = copy, .previous = self.entries.get(key) });
        }
        if (self.entries.getPtr(key)) |slot| {
            slot.* = entry;
        } else {
            const owned = try self.gpa.dupe(u8, key);
            errdefer self.gpa.free(owned);
            try self.entries.put(self.gpa, owned, entry);
        }
    }

    pub fn rollback(self: *Mirror, journal: *Journal) void {
        var i = journal.items.len;
        while (i > 0) {
            i -= 1;
            const undo = journal.items[i];
            if (undo.previous) |previous| {
                if (self.entries.getPtr(undo.key)) |slot| slot.* = previous;
            } else if (self.entries.fetchRemove(undo.key)) |removed| {
                self.gpa.free(removed.key);
            }
        }
        self.settle(journal);
    }

    pub fn settle(self: *Mirror, journal: *Journal) void {
        for (journal.items) |undo| self.gpa.free(undo.key);
        journal.clearRetainingCapacity();
    }

    pub fn reset(self: *Mirror) void {
        var it = self.entries.keyIterator();
        while (it.next()) |key| self.gpa.free(key.*);
        self.entries.clearRetainingCapacity();
    }
};

fn sameFileHash(a: ?Hash, b: ?Hash) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    return std.mem.eql(u8, &x, &y);
}

const testing = std.testing;

fn hashOf(text: []const u8) Hash {
    return symbol.hashOf(text);
}

test "a disabled mirror always reports changed and remembers nothing" {
    var mirror: Mirror = .init(testing.allocator, false);
    defer mirror.deinit();
    try testing.expectEqual(Outcome.changed, try mirror.check("a", hashOf("x"), false));
    try testing.expectEqual(Outcome.changed, try mirror.check("a", hashOf("x"), false));
    try testing.expectEqual(@as(u32, 0), mirror.entries.count());
}

test "an enabled mirror reports unchanged for a repeated identical hash" {
    var mirror: Mirror = .init(testing.allocator, true);
    defer mirror.deinit();
    try testing.expectEqual(Outcome.changed, try mirror.check("a", hashOf("x"), false));
    try testing.expectEqual(Outcome.unchanged, try mirror.check("a", hashOf("x"), false));
}

test "an enabled mirror reports changed once the hash moves, and remembers the new one" {
    var mirror: Mirror = .init(testing.allocator, true);
    defer mirror.deinit();
    _ = try mirror.check("a", hashOf("x"), false);
    try testing.expectEqual(Outcome.changed, try mirror.check("a", hashOf("y"), false));
    try testing.expectEqual(Outcome.unchanged, try mirror.check("a", hashOf("y"), false));
}

test "force always reports changed even for an identical hash, and keeps the mirror in sync" {
    var mirror: Mirror = .init(testing.allocator, true);
    defer mirror.deinit();
    _ = try mirror.check("a", hashOf("x"), false);
    try testing.expectEqual(Outcome.changed, try mirror.check("a", hashOf("x"), true));
    try testing.expectEqual(Outcome.unchanged, try mirror.check("a", hashOf("x"), false));
}

test "reset forgets every remembered hash so the next check reports changed" {
    var mirror: Mirror = .init(testing.allocator, true);
    defer mirror.deinit();
    _ = try mirror.check("a", hashOf("x"), false);
    mirror.reset();
    try testing.expectEqual(Outcome.changed, try mirror.check("a", hashOf("x"), false));
}

test "distinct keys are tracked independently" {
    var mirror: Mirror = .init(testing.allocator, true);
    defer mirror.deinit();
    _ = try mirror.check("a", hashOf("x"), false);
    try testing.expectEqual(Outcome.changed, try mirror.check("b", hashOf("x"), false));
}

test "seen returns the call that first sent an identical hash and file hash, and records anew when the file hash moves" {
    var mirror: Mirror = .init(testing.allocator, true);
    defer mirror.deinit();
    mirror.tick();
    try testing.expectEqual(@as(?u32, null), try mirror.seen("a", hashOf("x"), hashOf("f1"), false));
    mirror.tick();
    try testing.expectEqual(@as(?u32, 1), try mirror.seen("a", hashOf("x"), hashOf("f1"), false));
    mirror.tick();
    try testing.expectEqual(@as(?u32, null), try mirror.seen("a", hashOf("x"), hashOf("f2"), false));
    try testing.expectEqual(@as(?u32, 3), try mirror.seen("a", hashOf("x"), hashOf("f2"), false));
    try testing.expectEqual(@as(?u32, null), try mirror.seen("a", hashOf("x"), null, false));
}

test "rollback restores replaced entries and removes added ones, settle keeps them" {
    var mirror: Mirror = .init(testing.allocator, true);
    defer mirror.deinit();
    mirror.tick();
    _ = try mirror.seen("kept", hashOf("x"), null, false);
    var journal: Journal = .empty;
    defer journal.deinit(testing.allocator);
    mirror.journal = &journal;
    mirror.tick();
    _ = try mirror.seen("kept", hashOf("y"), null, false);
    _ = try mirror.seen("added", hashOf("z"), null, false);
    mirror.rollback(&journal);
    try testing.expectEqual(@as(?u32, 1), try mirror.seen("kept", hashOf("x"), null, false));
    try testing.expect(mirror.get("added") == null);
    _ = try mirror.seen("added", hashOf("z"), null, false);
    mirror.settle(&journal);
    mirror.journal = null;
    try testing.expectEqual(@as(?u32, 2), try mirror.seen("added", hashOf("z"), null, false));
}
