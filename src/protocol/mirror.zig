const std = @import("std");
const symbol = @import("../engine/symbol.zig");

const Allocator = std.mem.Allocator;

pub const Hash = symbol.Hash;

pub const Outcome = enum { unchanged, changed };

pub const Mirror = struct {
    gpa: Allocator,
    enabled: bool,
    entries: std.StringHashMapUnmanaged(Hash) = .{},

    pub fn init(gpa: Allocator, enabled: bool) Mirror {
        return .{ .gpa = gpa, .enabled = enabled };
    }

    pub fn deinit(self: *Mirror) void {
        var it = self.entries.keyIterator();
        while (it.next()) |key| self.gpa.free(key.*);
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn check(self: *Mirror, key: []const u8, hash: Hash, force: bool) Allocator.Error!Outcome {
        if (!self.enabled) return .changed;
        if (!force) {
            if (self.entries.get(key)) |old| {
                if (std.mem.eql(u8, &old, &hash)) return .unchanged;
            }
        }
        if (self.entries.getPtr(key)) |slot| {
            slot.* = hash;
        } else {
            const owned = try self.gpa.dupe(u8, key);
            errdefer self.gpa.free(owned);
            try self.entries.put(self.gpa, owned, hash);
        }
        return .changed;
    }

    pub fn reset(self: *Mirror) void {
        var it = self.entries.keyIterator();
        while (it.next()) |key| self.gpa.free(key.*);
        self.entries.clearRetainingCapacity();
    }
};

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
