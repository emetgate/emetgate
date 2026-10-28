const std = @import("std");
const symbol = @import("../engine/symbol.zig");
const disk = @import("../platform/disk.zig");
const wire = @import("wire.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const id_len = 8;
pub const max_entries = 4;
pub const ttl_ns: i96 = 15 * std.time.ns_per_min;

const Seen = struct { file: []u8, hash: ?symbol.Hash };

const Entry = struct {
    id: [id_len]u8,
    root: []u8,
    items: []u8,
    seen: []Seen,
    staged_at: i96,

    fn deinit(self: Entry, gpa: Allocator) void {
        for (self.seen) |s| gpa.free(s.file);
        gpa.free(self.seen);
        gpa.free(self.items);
        gpa.free(self.root);
    }
};

pub const Store = struct {
    gpa: Allocator,
    entries: [max_entries]?Entry = @splat(null),
    serial: u64 = 0,

    pub fn init(gpa: Allocator) Store {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Store) void {
        for (&self.entries) |*slot| {
            if (slot.*) |entry| entry.deinit(self.gpa);
            slot.* = null;
        }
    }

    pub fn stage(self: *Store, io: std.Io, root: ?[]const u8, items: []const Value, reuse: ?[]const u8, now: i96) ![id_len]u8 {
        const gpa = self.gpa;
        const text = try std.json.Stringify.valueAlloc(gpa, items, .{});
        errdefer gpa.free(text);
        const root_copy = try gpa.dupe(u8, root orelse "");
        errdefer gpa.free(root_copy);
        var seen: std.ArrayList(Seen) = .empty;
        errdefer {
            for (seen.items) |s| gpa.free(s.file);
            seen.deinit(gpa);
        }
        for (items) |item| {
            const file = fileOf(item) orelse continue;
            if (indexOfFile(root, seen.items, file) != null) continue;
            const hash = try hashOnDisk(gpa, io, root, file);
            const owned = try gpa.dupe(u8, file);
            errdefer gpa.free(owned);
            try seen.append(gpa, .{ .file = owned, .hash = hash });
        }
        const id = if (reuse) |given| (if (given.len == id_len) given[0..id_len].* else self.freshId(text, now)) else self.freshId(text, now);
        const entry: Entry = .{ .id = id, .root = root_copy, .items = text, .seen = try seen.toOwnedSlice(gpa), .staged_at = now };
        self.put(entry, now);
        return id;
    }

    fn put(self: *Store, entry: Entry, now: i96) void {
        for (&self.entries) |*slot| {
            const have = slot.* orelse continue;
            if (!std.mem.eql(u8, &have.id, &entry.id) and !expired(have, now)) continue;
            have.deinit(self.gpa);
            slot.* = null;
        }
        var target: usize = 0;
        for (self.entries, 0..) |slot, i| {
            const have = slot orelse {
                target = i;
                break;
            };
            if (have.staged_at < self.entries[target].?.staged_at) target = i;
        }
        if (self.entries[target]) |evicted| evicted.deinit(self.gpa);
        self.entries[target] = entry;
    }

    fn freshId(self: *Store, text: []const u8, now: i96) [id_len]u8 {
        self.serial += 1;
        var h = std.hash.Wyhash.init(self.serial);
        h.update(text);
        h.update(std.mem.asBytes(&now));
        var id: [id_len]u8 = undefined;
        _ = std.fmt.bufPrint(&id, "{x:0>8}", .{@as(u32, @truncate(h.final()))}) catch unreachable;
        return id;
    }

    fn find(self: *Store, root: ?[]const u8, id: []const u8, now: i96) ?*Entry {
        for (&self.entries) |*slot| {
            const entry = &(slot.* orelse continue);
            if (!std.mem.eql(u8, &entry.id, id)) continue;
            if (expired(entry.*, now) or !std.mem.eql(u8, entry.root, root orelse "")) return null;
            return entry;
        }
        return null;
    }

    pub fn remove(self: *Store, id: []const u8) void {
        for (&self.entries) |*slot| {
            const entry = slot.* orelse continue;
            if (!std.mem.eql(u8, &entry.id, id)) continue;
            entry.deinit(self.gpa);
            slot.* = null;
        }
    }

    pub fn merge(self: *Store, arena: Allocator, io: std.Io, root: ?[]const u8, id: []const u8, given: []const Value, now: i96) ![]Value {
        const entry = self.find(root, id, now) orelse return error.StagedBatchUnknown;
        const staged = try std.json.parseFromSliceLeaky(Value, arena, entry.items, .{ .allocate = .alloc_always });
        if (staged != .array) return error.StagedBatchUnknown;
        for (entry.seen) |s| {
            if (replaced(root, given, s.file)) continue;
            const now_hash = try hashOnDisk(arena, io, root, s.file);
            if (sameHash(now_hash, s.hash)) continue;
            const file = s.file;
            wire.setFix("{s} changed on disk after batch {s} was kept; send the whole batch again without retry", .{ file, id });
            self.remove(id);
            return error.StagedBatchStale;
        }
        var out: std.ArrayList(Value) = .empty;
        var placed = try arena.alloc(bool, given.len);
        @memset(placed, false);
        for (staged.array.items) |item| {
            const file = fileOf(item) orelse continue;
            if (!replaced(root, given, file)) {
                try out.append(arena, item);
                continue;
            }
            for (given, 0..) |fresh, j| {
                if (placed[j]) continue;
                const fresh_file = fileOf(fresh) orelse continue;
                if (!sameFile(root, fresh_file, file)) continue;
                try out.append(arena, fresh);
                placed[j] = true;
            }
        }
        for (given, 0..) |fresh, j| {
            if (!placed[j]) try out.append(arena, fresh);
        }
        return out.toOwnedSlice(arena);
    }
};

fn expired(entry: Entry, now: i96) bool {
    return now - entry.staged_at > ttl_ns;
}

fn sameHash(a: ?symbol.Hash, b: ?symbol.Hash) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, &a.?, &b.?);
}

fn fileOf(item: Value) ?[]const u8 {
    if (item != .object) return null;
    const value = item.object.get("file") orelse return null;
    return if (value == .string) value.string else null;
}

fn replaced(root: ?[]const u8, given: []const Value, file: []const u8) bool {
    for (given) |fresh| {
        const fresh_file = fileOf(fresh) orelse continue;
        if (sameFile(root, fresh_file, file)) return true;
    }
    return false;
}

fn indexOfFile(root: ?[]const u8, seen: []const Seen, file: []const u8) ?usize {
    for (seen, 0..) |s, i| {
        if (sameFile(root, s.file, file)) return i;
    }
    return null;
}

fn underRoot(root: ?[]const u8, file: []const u8) []const u8 {
    var rest = file;
    if (root) |r| {
        if (r.len != 0 and rest.len > r.len and std.ascii.eqlIgnoreCase(rest[0..r.len], r) and isSep(rest[r.len])) rest = rest[r.len + 1 ..];
    }
    while (rest.len >= 2 and rest[0] == '.' and isSep(rest[1])) rest = rest[2..];
    return rest;
}

fn isSep(c: u8) bool {
    return c == '/' or c == '\\';
}

pub fn sameFile(root: ?[]const u8, a: []const u8, b: []const u8) bool {
    const x = underRoot(root, a);
    const y = underRoot(root, b);
    if (x.len != y.len) return false;
    for (x, y) |p, q| {
        if (isSep(p) and isSep(q)) continue;
        if (std.ascii.toLower(p) != std.ascii.toLower(q)) return false;
    }
    return true;
}

fn hashOnDisk(gpa: Allocator, io: std.Io, root: ?[]const u8, file: []const u8) !?symbol.Hash {
    const abs = if (std.fs.path.isAbsolute(file) or root == null) try gpa.dupe(u8, file) else try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ root.?, file });
    defer gpa.free(abs);
    return disk.hashFile(gpa, io, abs) catch |err| switch (err) {
        error.OutOfMemory => err,
        else => null,
    };
}

pub fn clock(io: std.Io) i96 {
    return std.Io.Timestamp.now(io, .awake).nanoseconds;
}

pub fn withRetry(gpa: Allocator, text: []const u8, id: [id_len]u8) ![]u8 {
    if (text.len == 0 or text[0] != '{') return gpa.dupe(u8, text);
    return std.mem.concat(gpa, u8, &.{ "{\"retry\":\"", &id, "\",", text[1..] });
}

const testing = std.testing;

fn parseItems(arena: Allocator, text: []const u8) ![]const Value {
    const parsed = try std.json.parseFromSliceLeaky(Value, arena, text, .{ .allocate = .alloc_always });
    return parsed.array.items;
}

const Fixture = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,

    fn init() !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "src");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/a.ts", .data = "a\n" });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/b.ts", .data = "b\n" });
        const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        return .{ .tmp = tmp, .root = root };
    }

    fn deinit(self: *Fixture) void {
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }
};

test "a kept batch merges a retry: an item for the same file replaces the kept ones in place, a new file is appended" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var store: Store = .init(testing.allocator);
    defer store.deinit();
    const first = try parseItems(arena, "[{\"file\":\"src/a.ts\",\"content\":\"A\"},{\"file\":\"src/b.ts\",\"old_string\":\"b\",\"new_string\":\"x\"},{\"file\":\"src\\\\b.ts\",\"old_string\":\"x\",\"new_string\":\"y\"}]");
    const id = try store.stage(testing.io, fx.root, first, null, 0);
    const retry = try parseItems(arena, "[{\"file\":\"SRC/B.ts\",\"old_string\":\"b\",\"new_string\":\"z\"},{\"file\":\"src/c.ts\",\"hash\":\"absent\",\"content\":\"c\"}]");
    const merged = try store.merge(arena, testing.io, fx.root, &id, retry, 1);
    try testing.expectEqual(@as(usize, 3), merged.len);
    try testing.expectEqualStrings("src/a.ts", fileOf(merged[0]).?);
    try testing.expectEqualStrings("SRC/B.ts", fileOf(merged[1]).?);
    try testing.expectEqualStrings("z", merged[1].object.get("new_string").?.string);
    try testing.expectEqualStrings("src/c.ts", fileOf(merged[2]).?);
}

test "a kept batch whose untouched file changed on disk is refused as stale and dropped" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var store: Store = .init(testing.allocator);
    defer store.deinit();
    const first = try parseItems(arena, "[{\"file\":\"src/a.ts\",\"old_string\":\"a\",\"new_string\":\"q\"},{\"file\":\"src/b.ts\",\"content\":\"B\",\"hash\":\"absent\"}]");
    const id = try store.stage(testing.io, fx.root, first, null, 0);
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "src/a.ts", .data = "changed\n" });
    const retry = try parseItems(arena, "[{\"file\":\"src/b.ts\",\"content\":\"B2\",\"hash\":\"absent\"}]");
    try testing.expectError(error.StagedBatchStale, store.merge(arena, testing.io, fx.root, &id, retry, 1));
    _ = wire.takeFixForTest();
    try testing.expectError(error.StagedBatchUnknown, store.merge(arena, testing.io, fx.root, &id, &.{}, 2));
}

test "a kept batch whose file was created after it was kept is stale, and one whose own file is resent is not" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var store: Store = .init(testing.allocator);
    defer store.deinit();
    const first = try parseItems(arena, "[{\"file\":\"src/n.ts\",\"hash\":\"absent\",\"content\":\"n\"},{\"file\":\"src/a.ts\",\"content\":\"A\"}]");
    const id = try store.stage(testing.io, fx.root, first, null, 0);
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "src/a.ts", .data = "changed\n" });
    const fixed = try parseItems(arena, "[{\"file\":\"src/a.ts\",\"content\":\"A2\"}]");
    const merged = try store.merge(arena, testing.io, fx.root, &id, fixed, 1);
    try testing.expectEqual(@as(usize, 2), merged.len);
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "src/n.ts", .data = "someone else\n" });
    try testing.expectError(error.StagedBatchStale, store.merge(arena, testing.io, fx.root, &id, fixed, 2));
    _ = wire.takeFixForTest();
}

test "a kept batch expires, belongs to its root, and the oldest is evicted past the limit" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var store: Store = .init(testing.allocator);
    defer store.deinit();
    const items = try parseItems(arena, "[{\"file\":\"src/a.ts\",\"content\":\"A\"}]");
    const id = try store.stage(testing.io, fx.root, items, null, 0);
    try testing.expectError(error.StagedBatchUnknown, store.merge(arena, testing.io, "C:\\elsewhere", &id, &.{}, 1));
    try testing.expectError(error.StagedBatchUnknown, store.merge(arena, testing.io, fx.root, &id, &.{}, ttl_ns + 1));
    _ = try store.merge(arena, testing.io, fx.root, &id, &.{}, ttl_ns);
    var ids: [max_entries][id_len]u8 = undefined;
    for (&ids, 0..) |*slot, i| slot.* = try store.stage(testing.io, fx.root, items, null, @intCast(i + 1));
    try testing.expectError(error.StagedBatchUnknown, store.merge(arena, testing.io, fx.root, &id, &.{}, 10));
    for (ids) |kept| _ = try store.merge(arena, testing.io, fx.root, &kept, &.{}, 10);
    store.remove(&ids[0]);
    try testing.expectError(error.StagedBatchUnknown, store.merge(arena, testing.io, fx.root, &ids[0], &.{}, 10));
}

test "a retry id goes first in the reply object" {
    const text = try withRetry(testing.allocator, "{\"status\":\"rejected\"}\n", "0123abcd".*);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("{\"retry\":\"0123abcd\",\"status\":\"rejected\"}\n", text);
}
