const std = @import("std");
const loader = @import("loader.zig");
const Runtime = @import("runtime.zig").Runtime;

const Allocator = std.mem.Allocator;
const Snapshot = loader.Snapshot;

const Stamp = struct {
    mtime_ns: i96,
    size: u64,
};

const Entry = struct {
    snapshot: *Snapshot,
    stamp: ?Stamp,
};

pub const TreeCache = struct {
    gpa: Allocator,
    entries: std.StringHashMapUnmanaged(Entry) = .{},

    pub fn init(gpa: Allocator) TreeCache {
        return .{ .gpa = gpa };
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

    fn stampOf(io: std.Io, abs_path: []const u8) ?Stamp {
        const stat = std.Io.Dir.cwd().statFile(io, abs_path, .{}) catch return null;
        return .{ .mtime_ns = stat.mtime.nanoseconds, .size = stat.size };
    }

    fn sameStamp(a: ?Stamp, b: ?Stamp) bool {
        const x = a orelse return false;
        const y = b orelse return false;
        return x.mtime_ns == y.mtime_ns and x.size == y.size;
    }

    pub fn load(self: *TreeCache, runtime: *Runtime, io: std.Io, abs_path: []const u8) Snapshot.LoadError!*Snapshot {
        const fresh_stamp = stampOf(io, abs_path);
        if (fresh_stamp) |fs| {
            if (self.entries.get(abs_path)) |entry| {
                if (sameStamp(entry.stamp, fs)) return entry.snapshot;
            }
        }
        const fresh = try Snapshot.load(runtime, io, .cwd(), abs_path);
        self.insert(abs_path, fresh, fresh_stamp) catch {
            return fresh;
        };
        return fresh;
    }

    pub fn put(self: *TreeCache, io: std.Io, abs_path: []const u8, snapshot: *Snapshot) void {
        const stamp = stampOf(io, abs_path);
        self.insert(abs_path, snapshot, stamp) catch {
            snapshot.destroy();
        };
    }

    fn insert(self: *TreeCache, abs_path: []const u8, snapshot: *Snapshot, stamp: ?Stamp) Allocator.Error!void {
        if (self.entries.getPtr(abs_path)) |existing| {
            if (existing.snapshot != snapshot) existing.snapshot.destroy();
            existing.* = .{ .snapshot = snapshot, .stamp = stamp };
            return;
        }
        const owned_key = try self.gpa.dupe(u8, abs_path);
        errdefer self.gpa.free(owned_key);
        try self.entries.put(self.gpa, owned_key, .{ .snapshot = snapshot, .stamp = stamp });
    }

    pub fn invalidate(self: *TreeCache, abs_path: []const u8) void {
        if (self.entries.fetchRemove(abs_path)) |kv| {
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

test "put installs an already-produced snapshot without reparsing, and it is what load then serves" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export function add(a: number): number {\n  return a;\n}\n" });
    const abs = try tmp.dir.realPathFileAlloc(testing.io, "a.ts", testing.allocator);
    defer testing.allocator.free(abs);

    var cache: TreeCache = .init(testing.allocator);
    defer cache.deinit();

    const produced = try Snapshot.load(runtime, testing.io, .cwd(), abs);
    cache.put(testing.io, abs, produced);

    const served = try cache.load(runtime, testing.io, abs);
    try testing.expect(served == produced);
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
