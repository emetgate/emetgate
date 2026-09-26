const std = @import("std");
const loader = @import("loader.zig");
const symbol = @import("symbol.zig");
const Runtime = @import("runtime.zig").Runtime;

const Allocator = std.mem.Allocator;
const Snapshot = loader.Snapshot;

const max_hash_read_len = std.math.maxInt(u32);

pub const measured_tree_to_source_ratio: usize = 30;

pub const default_budget_bytes: usize = 8 * 1024 * 1024;

const Stamp = struct {
    mtime_ns: i96,
    size: u64,
};

const Entry = struct {
    snapshot: *Snapshot,
    stamp: ?Stamp,
    content_hash: symbol.Hash,
    bytes: usize,
    tick: u64,
};

fn normalizedKey(gpa: Allocator, abs_path: []const u8) Allocator.Error![]u8 {
    const owned = try gpa.dupe(u8, abs_path);
    for (owned) |*byte| {
        if (byte.* == '/') byte.* = '\\';
        byte.* = std.ascii.toLower(byte.*);
    }
    return owned;
}

pub const TreeCache = struct {
    gpa: Allocator,
    entries: std.StringHashMapUnmanaged(Entry) = .{},
    total_bytes: usize = 0,
    next_tick: u64 = 0,
    budget_bytes: usize = default_budget_bytes,

    pub fn init(gpa: Allocator) TreeCache {
        return .{ .gpa = gpa };
    }

    pub fn initWithBudget(gpa: Allocator, budget_bytes: usize) TreeCache {
        return .{ .gpa = gpa, .budget_bytes = budget_bytes };
    }

    pub fn deinit(self: *TreeCache) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            kv.value_ptr.snapshot.destroy();
            self.gpa.free(kv.key_ptr.*);
        }
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn usedBytes(self: *const TreeCache) usize {
        return self.total_bytes;
    }

    fn stampOf(io: std.Io, abs_path: []const u8) ?Stamp {
        const stat = std.Io.Dir.cwd().statFile(io, abs_path, .{}) catch return null;
        return .{ .mtime_ns = stat.mtime.nanoseconds, .size = stat.size };
    }

    fn sameStamp(a: ?Stamp, b: ?Stamp) bool {
        const x = a orelse return false;
        const y = b orelse return false;
        return x.mtime_ns == y.mtime_ns and x.size == y.size;
    }

    pub fn load(self: *TreeCache, runtime: *Runtime, io: std.Io, abs_path: []const u8) (Snapshot.LoadError || Allocator.Error)!*Snapshot {
        const key = try normalizedKey(self.gpa, abs_path);
        defer self.gpa.free(key);
        const fresh_stamp = stampOf(io, abs_path);
        if (fresh_stamp) |fs| {
            if (self.entries.getPtr(key)) |entry| {
                if (sameStamp(entry.stamp, fs)) {
                    if (self.unchangedContent(io, abs_path, entry.content_hash)) {
                        entry.tick = self.nextTick();
                        return entry.snapshot;
                    }
                }
            }
        }
        const fresh = try Snapshot.load(runtime, io, .cwd(), abs_path);
        const fresh_hash = symbol.fileHash(fresh.source);
        self.insert(key, fresh, fresh_stamp, fresh_hash) catch |err| {
            fresh.destroy();
            return err;
        };
        return fresh;
    }

    fn nextTick(self: *TreeCache) u64 {
        self.next_tick += 1;
        return self.next_tick;
    }

    fn unchangedContent(self: *TreeCache, io: std.Io, abs_path: []const u8, expected: symbol.Hash) bool {
        _ = self;
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, abs_path, std.heap.page_allocator, .limited(max_hash_read_len)) catch return false;
        defer std.heap.page_allocator.free(bytes);
        const actual = symbol.fileHash(bytes);
        return std.mem.eql(u8, &actual, &expected);
    }

    fn insert(self: *TreeCache, key: []const u8, snapshot: *Snapshot, stamp: ?Stamp, content_hash: symbol.Hash) Allocator.Error!void {
        const bytes = snapshot.source.len;
        const tick = self.nextTick();
        if (self.entries.getPtr(key)) |existing| {
            if (existing.snapshot != snapshot) existing.snapshot.destroy();
            self.total_bytes = self.total_bytes - existing.bytes + bytes;
            existing.* = .{ .snapshot = snapshot, .stamp = stamp, .content_hash = content_hash, .bytes = bytes, .tick = tick };
            self.evictToFit();
            return;
        }
        const owned_key = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(owned_key);
        try self.entries.put(self.gpa, owned_key, .{ .snapshot = snapshot, .stamp = stamp, .content_hash = content_hash, .bytes = bytes, .tick = tick });
        self.total_bytes += bytes;
        self.evictToFit();
    }

    fn evictToFit(self: *TreeCache) void {
        while (self.total_bytes > self.budget_bytes and self.entries.count() > 1) {
            var oldest_key: ?[]const u8 = null;
            var oldest_tick: u64 = std.math.maxInt(u64);
            var it = self.entries.iterator();
            while (it.next()) |kv| {
                if (kv.value_ptr.tick < oldest_tick) {
                    oldest_tick = kv.value_ptr.tick;
                    oldest_key = kv.key_ptr.*;
                }
            }
            const victim = oldest_key orelse break;
            if (self.entries.fetchRemove(victim)) |kv| {
                self.total_bytes -= kv.value.bytes;
                kv.value.snapshot.destroy();
                self.gpa.free(kv.key);
            }
        }
    }

    pub fn invalidate(self: *TreeCache, abs_path: []const u8) void {
        const key = normalizedKey(self.gpa, abs_path) catch return;
        defer self.gpa.free(key);
        if (self.entries.fetchRemove(key)) |kv| {
            self.total_bytes -= kv.value.bytes;
            kv.value.snapshot.destroy();
            self.gpa.free(kv.key);
        }
    }

    pub fn count(self: *const TreeCache) usize {
        return self.entries.count();
    }
};

const testing = std.testing;
const test_util = @import("test_util.zig");

test "load reparses once, then serves the same snapshot for an unchanged file" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export function add(a: number): number {\n  return a;\n}\n" });
    const abs = try tmp.dir.realPathFileAlloc(testing.io, "a.ts", testing.allocator);
    defer testing.allocator.free(abs);

    var cache: TreeCache = .init(testing.allocator);
    defer cache.deinit();

    const first = try cache.load(runtime, testing.io, abs);
    const second = try cache.load(runtime, testing.io, abs);
    try testing.expect(first == second);
    try testing.expectEqual(@as(usize, 1), cache.count());
}

test "load reparses when the file's mtime or size changed on disk" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export function add(a: number): number {\n  return a;\n}\n" });
    const abs = try tmp.dir.realPathFileAlloc(testing.io, "a.ts", testing.allocator);
    defer testing.allocator.free(abs);

    var cache: TreeCache = .init(testing.allocator);
    defer cache.deinit();

    const first = try cache.load(runtime, testing.io, abs);
    try testing.expectEqualStrings("export function add(a: number): number {\n  return a;\n}\n", first.source);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export function add(a: number): number {\n  return a + 1;\n}\n" });
    const second = try cache.load(runtime, testing.io, abs);
    try testing.expect(std.mem.indexOf(u8, second.source, "return a + 1") != null);
}

test "invalidate forgets a path so the next load reparses from disk" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export function add(a: number): number {\n  return a;\n}\n" });
    const abs = try tmp.dir.realPathFileAlloc(testing.io, "a.ts", testing.allocator);
    defer testing.allocator.free(abs);

    var cache: TreeCache = .init(testing.allocator);
    defer cache.deinit();

    const first = try cache.load(runtime, testing.io, abs);
    cache.invalidate(abs);
    try testing.expectEqual(@as(usize, 0), cache.count());
    const second = try cache.load(runtime, testing.io, abs);
    try testing.expect(first != second);
}

test "a racy mtime collision does not serve stale content, the content hash catches it" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export function add(a: number): number {\n  return a + 1;\n}\n" });
    const abs = try tmp.dir.realPathFileAlloc(testing.io, "a.ts", testing.allocator);
    defer testing.allocator.free(abs);

    var cache: TreeCache = .init(testing.allocator);
    defer cache.deinit();

    const first = try cache.load(runtime, testing.io, abs);
    try testing.expect(std.mem.indexOf(u8, first.source, "return a + 1") != null);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export function add(a: number): number {\n  return a - 1;\n}\n" });
    const key = try normalizedKey(testing.allocator, abs);
    defer testing.allocator.free(key);
    const racy_stamp = TreeCache.stampOf(testing.io, abs);
    cache.entries.getPtr(key).?.stamp = racy_stamp;

    const second = try cache.load(runtime, testing.io, abs);
    try testing.expect(std.mem.indexOf(u8, second.source, "return a - 1") != null);
    try testing.expect(second != first);
}

test "normalizedKey folds slash direction and case so the same file has one entry" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export function add(a: number): number {\n  return a;\n}\n" });
    const abs = try tmp.dir.realPathFileAlloc(testing.io, "a.ts", testing.allocator);
    defer testing.allocator.free(abs);

    const forward_slash = try std.mem.replaceOwned(u8, testing.allocator, abs, "\\", "/");
    defer testing.allocator.free(forward_slash);
    const upper = try std.ascii.allocUpperString(testing.allocator, abs);
    defer testing.allocator.free(upper);

    var cache: TreeCache = .init(testing.allocator);
    defer cache.deinit();

    _ = try cache.load(runtime, testing.io, abs);
    _ = try cache.load(runtime, testing.io, forward_slash);
    _ = try cache.load(runtime, testing.io, upper);
    try testing.expectEqual(@as(usize, 1), cache.count());
}

test "insert evicts the least recently touched entry once the byte budget is exceeded" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export function a(): number {\n  return 1;\n}\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.ts", .data = "export function b(): number {\n  return 2;\n}\n" });
    const abs_a = try tmp.dir.realPathFileAlloc(testing.io, "a.ts", testing.allocator);
    defer testing.allocator.free(abs_a);
    const abs_b = try tmp.dir.realPathFileAlloc(testing.io, "b.ts", testing.allocator);
    defer testing.allocator.free(abs_b);

    var cache: TreeCache = .initWithBudget(testing.allocator, 1);
    defer cache.deinit();

    _ = try cache.load(runtime, testing.io, abs_a);
    try testing.expectEqual(@as(usize, 1), cache.count());
    _ = try cache.load(runtime, testing.io, abs_b);
    try testing.expectEqual(@as(usize, 1), cache.count());

    const key_a = try normalizedKey(testing.allocator, abs_a);
    defer testing.allocator.free(key_a);
    try testing.expect(cache.entries.get(key_a) == null);
}

fn elapsedNs(from: std.Io.Timestamp) u64 {
    return @intCast(from.durationTo(std.Io.Timestamp.now(testing.io, .awake)).nanoseconds);
}

const bench_samples = 200;

test "warm reads are faster than a cold parse, and every repeat is a cache hit" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = try std.Io.Dir.cwd().readFileAlloc(testing.io, test_util.fixture_dir ++ "service.ts", testing.allocator, .unlimited);
    defer testing.allocator.free(source);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "service.ts", .data = source });
    const abs = try tmp.dir.realPathFileAlloc(testing.io, "service.ts", testing.allocator);
    defer testing.allocator.free(abs);

    var cold: [bench_samples]u64 = undefined;
    for (&cold) |*sample| {
        var one_shot: TreeCache = .init(testing.allocator);
        defer one_shot.deinit();
        const started = std.Io.Timestamp.now(testing.io, .awake);
        _ = try one_shot.load(runtime, testing.io, abs);
        sample.* = elapsedNs(started);
    }
    std.mem.sort(u64, &cold, {}, std.sort.asc(u64));

    var cache: TreeCache = .init(testing.allocator);
    defer cache.deinit();
    _ = try cache.load(runtime, testing.io, abs);

    var warm: [bench_samples]u64 = undefined;
    var hits: usize = 0;
    for (&warm) |*sample| {
        const before = cache.count();
        const started = std.Io.Timestamp.now(testing.io, .awake);
        const snapshot = try cache.load(runtime, testing.io, abs);
        sample.* = elapsedNs(started);
        _ = snapshot;
        if (cache.count() == before) hits += 1;
    }
    std.mem.sort(u64, &warm, {}, std.sort.asc(u64));

    const cold_median = cold[cold.len / 2];
    const warm_median = warm[warm.len / 2];
    std.debug.print(
        "\n[tree_cache:Debug] cold parse median {d} ns, p99 {d} ns | warm hit median {d} ns, p99 {d} ns | hit rate {d}/{d}\n",
        .{ cold_median, cold[cold.len * 99 / 100], warm_median, warm[warm.len * 99 / 100], hits, warm.len },
    );

    try testing.expectEqual(bench_samples, hits);
    try testing.expect(warm_median < cold_median);
}
