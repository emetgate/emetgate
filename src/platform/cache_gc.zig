const std = @import("std");
const builtin = @import("builtin");
const shadow = @import("shadow.zig");
const shadow_root = @import("shadow_root.zig");
const cache_lease = @import("cache_lease.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Key = [shadow_root.key_len]u8;

pub const families = [_][]const u8{ "find", "index", "facts", shadow_family };
pub const shadow_family = "shadow";
pub const lock_name = "gc.lock";
pub const stamp_name = "gc.stamp";
pub const default_max_age_days: u32 = 30;
pub const default_max_mb: u64 = 5 * 1024;
pub const interval_ns: i96 = std.time.ns_per_day;
const max_marker_bytes = 64 * 1024;
const max_depth = 64;

pub const Policy = struct {
    max_age_days: u32 = default_max_age_days,
    max_mb: u64 = default_max_mb,

    pub fn maxAgeNs(self: Policy) i96 {
        return @as(i96, self.max_age_days) * std.time.ns_per_day;
    }

    pub fn maxBytes(self: Policy) u64 {
        return std.math.mul(u64, self.max_mb, 1024 * 1024) catch std.math.maxInt(u64);
    }
};

pub const age_flag = "--cache-max-age-days";
pub const size_flag = "--cache-max-mb";

pub const Flags = struct {
    policy: Policy = .{},
    age_set: bool = false,
    size_set: bool = false,

    pub fn take(self: *Flags, args: anytype, i: *usize) ?bool {
        const arg: []const u8 = args[i.*];
        const is_age = std.mem.eql(u8, arg, age_flag);
        if (!is_age and !std.mem.eql(u8, arg, size_flag)) return false;
        if (i.* + 1 >= args.len) return null;
        const value = std.fmt.parseInt(u32, @as([]const u8, args[i.* + 1]), 10) catch return null;
        if (value == 0) return null;
        if (is_age) {
            if (self.age_set) return null;
            self.age_set = true;
            self.policy.max_age_days = value;
        } else {
            if (self.size_set) return null;
            self.size_set = true;
            self.policy.max_mb = value;
        }
        i.* += 1;
        return true;
    }
};

pub const Report = struct {
    ran: bool = false,
    busy: bool = false,
    removed: usize = 0,
    freed_bytes: u64 = 0,
    live: usize = 0,
    refused: usize = 0,
    kept: usize = 0,
    kept_bytes: u64 = 0,
    failed: usize = 0,
    first_failure: ?anyerror = null,

    fn fail(self: *Report, err: anyerror) void {
        self.failed += 1;
        if (self.first_failure == null) self.first_failure = err;
    }
};

const Entry = struct {
    key: Key,
    bytes: u64 = 0,
    last_used: i96 = 0,
};

pub fn sweepDaily(gpa: Allocator, io: std.Io, data_abs: []const u8, policy: Policy, now: i96, cancel: ?*const std.atomic.Value(bool)) !Report {
    if (try stampFresh(io, data_abs, now)) return .{};
    return locked(gpa, io, data_abs, policy, now, cancel, true);
}

pub fn sweep(gpa: Allocator, io: std.Io, data_abs: []const u8, policy: Policy, now: i96, cancel: ?*const std.atomic.Value(bool)) !Report {
    return locked(gpa, io, data_abs, policy, now, cancel, false);
}

fn locked(gpa: Allocator, io: std.Io, data_abs: []const u8, policy: Policy, now: i96, cancel: ?*const std.atomic.Value(bool), daily: bool) !Report {
    if (builtin.os.tag != .windows) return .{};
    Dir.accessAbsolute(io, data_abs, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => |e| return e,
    };
    var lock_buf: [std.fs.max_path_bytes]u8 = undefined;
    const lock: ?shadow.FileLock = shadow.FileLock.acquire(try std.fmt.bufPrint(&lock_buf, "{s}\\{s}", .{ data_abs, lock_name })) catch |err| switch (err) {
        error.Busy => return .{ .busy = true },
        error.Unsupported => null,
        else => |e| return e,
    };
    defer if (lock) |held| held.release();
    if (daily and try stampFresh(io, data_abs, now)) return .{};
    var report = try collect(gpa, io, data_abs, policy, now, cancel);
    writeStamp(io, data_abs, now) catch |err| report.fail(err);
    return report;
}

fn stampFresh(io: std.Io, data_abs: []const u8, now: i96) !bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}\\{s}", .{ data_abs, stamp_name });
    const stat = Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    const age = now - stat.mtime.nanoseconds;
    return age >= 0 and age < interval_ns;
}

fn writeStamp(io: std.Io, data_abs: []const u8, now: i96) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}\\{s}", .{ data_abs, stamp_name });
    var file = try Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.setTimestamps(io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = now } } });
}

fn collect(gpa: Allocator, io: std.Io, data_abs: []const u8, policy: Policy, now: i96, cancel: ?*const std.atomic.Value(bool)) !Report {
    var report: Report = .{ .ran = true };
    var entries: std.AutoArrayHashMapUnmanaged(Key, Entry) = .empty;
    defer entries.deinit(gpa);
    var unmeasured: std.AutoArrayHashMapUnmanaged(Key, void) = .empty;
    defer unmeasured.deinit(gpa);
    for (families) |family| try scanFamily(gpa, io, data_abs, family, &entries, &unmeasured, &report);
    try scanLeases(gpa, io, data_abs, &entries);
    for (unmeasured.keys()) |key| _ = entries.swapRemove(key);

    var total: u64 = 0;
    for (entries.values()) |entry| total +|= entry.bytes;
    const order = try gpa.dupe(Entry, entries.values());
    defer gpa.free(order);
    std.mem.sort(Entry, order, {}, olderFirst);

    for (order) |entry| {
        if (cancel) |flag| if (flag.load(.acquire)) break;
        const outcome = settle(gpa, io, data_abs, policy, now, entry, total) catch |err| {
            report.fail(err);
            continue;
        };
        switch (outcome) {
            .live => report.live += 1,
            .kept => {
                report.kept += 1;
                report.kept_bytes +|= entry.bytes;
            },
            .refused => {
                report.refused += 1;
                report.kept += 1;
                report.kept_bytes +|= entry.bytes;
            },
            .removed => {
                report.removed += 1;
                report.freed_bytes +|= entry.bytes;
                total -|= entry.bytes;
            },
        }
    }
    return report;
}

fn olderFirst(_: void, a: Entry, b: Entry) bool {
    if (a.last_used != b.last_used) return a.last_used < b.last_used;
    return std.mem.order(u8, &a.key, &b.key) == .lt;
}

const Outcome = enum { live, kept, refused, removed };

fn settle(gpa: Allocator, io: std.Io, data_abs: []const u8, policy: Policy, now: i96, entry: Entry, total: u64) !Outcome {
    const held = cache_lease.claim(data_abs, &entry.key) catch |err| switch (err) {
        error.Busy => return .live,
        else => |e| return e,
    };
    var drop = false;
    defer held.release(drop);
    const verdict = try recordedVerdict(gpa, io, data_abs, held, &entry.key);
    const last_used = if (held.created) entry.last_used else @max(entry.last_used, held.modifiedNs(io) orelse entry.last_used);
    const aged = now - last_used > policy.maxAgeNs();
    const over = total > policy.maxBytes();
    if (verdict != .gone and !aged and !over) return if (verdict == .refused) .refused else .kept;
    try removeEntries(gpa, io, data_abs, &entry.key);
    drop = true;
    return .removed;
}

fn recordedVerdict(gpa: Allocator, io: std.Io, data_abs: []const u8, held: cache_lease.Claim, key: []const u8) !shadow_root.Verdict {
    var buf: [max_marker_bytes]u8 = undefined;
    if (held.readRoot(io, &buf)) |recorded| return shadow_root.verdict(io, recorded, key);
    const marker = try std.fmt.allocPrint(gpa, "{s}\\{s}\\{s}\\{s}", .{ data_abs, shadow_family, key, shadow_root.marker_name });
    defer gpa.free(marker);
    if (try shadow.isReparsePoint(marker)) return .refused;
    const recorded = Dir.cwd().readFileAlloc(io, marker, gpa, .limited(max_marker_bytes)) catch |err| switch (err) {
        error.FileNotFound => return .none,
        else => |e| return e,
    };
    defer gpa.free(recorded);
    return shadow_root.verdict(io, recorded, key);
}

fn removeEntries(gpa: Allocator, io: std.Io, data_abs: []const u8, key: []const u8) !void {
    for (families) |family| {
        const family_abs = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ data_abs, family });
        defer gpa.free(family_abs);
        if (try shadow.isReparsePoint(family_abs)) return error.CacheFamilyIsLink;
        const entry_abs = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ family_abs, key });
        defer gpa.free(entry_abs);
        if (try shadow.isReparsePoint(entry_abs)) return error.CacheEntryIsLink;
        Dir.accessAbsolute(io, entry_abs, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        if (std.mem.eql(u8, family, shadow_family)) {
            try shadow.removeWorkspace(io, family_abs, entry_abs);
        } else {
            try shadow.clearTemp(io, entry_abs);
        }
    }
}

fn scanFamily(gpa: Allocator, io: std.Io, data_abs: []const u8, family: []const u8, entries: *std.AutoArrayHashMapUnmanaged(Key, Entry), unmeasured: *std.AutoArrayHashMapUnmanaged(Key, void), report: *Report) !void {
    const family_abs = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ data_abs, family });
    defer gpa.free(family_abs);
    if (try shadow.isReparsePoint(family_abs)) return;
    var dir = Dir.openDirAbsolute(io, family_abs, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |item| {
        if (item.kind != .directory or !shadow_root.isKey(item.name)) continue;
        var key: Key = undefined;
        @memcpy(&key, item.name);
        const slot = try entries.getOrPut(gpa, key);
        if (!slot.found_existing) slot.value_ptr.* = .{ .key = key };
        measureEntry(io, dir, item.name, slot.value_ptr) catch |err| {
            report.fail(err);
            try unmeasured.put(gpa, key, {});
        };
    }
}

fn measureEntry(io: std.Io, parent: Dir, name: []const u8, entry: *Entry) !void {
    const stat = try parent.statFile(io, name, .{ .follow_symlinks = false });
    entry.last_used = @max(entry.last_used, stat.mtime.nanoseconds);
    var dir = try parent.openDir(io, name, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);
    try measureTree(io, dir, entry, 0);
}

fn measureTree(io: std.Io, dir: Dir, entry: *Entry, depth: usize) !void {
    if (depth > max_depth) return error.CacheTooDeep;
    var it = dir.iterate();
    while (try it.next(io)) |item| {
        switch (item.kind) {
            .directory => {
                var child = try dir.openDir(io, item.name, .{ .iterate = true, .follow_symlinks = false });
                defer child.close(io);
                try measureTree(io, child, entry, depth + 1);
            },
            .file => {
                const stat = try dir.statFile(io, item.name, .{ .follow_symlinks = false });
                entry.last_used = @max(entry.last_used, stat.mtime.nanoseconds);
                if (stat.nlink <= 1) entry.bytes +|= stat.size;
            },
            else => {},
        }
    }
}

fn scanLeases(gpa: Allocator, io: std.Io, data_abs: []const u8, entries: *std.AutoArrayHashMapUnmanaged(Key, Entry)) !void {
    const leases_abs = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ data_abs, cache_lease.leases_dir });
    defer gpa.free(leases_abs);
    if (try shadow.isReparsePoint(leases_abs)) return error.CacheFamilyIsLink;
    var dir = Dir.openDirAbsolute(io, leases_abs, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |item| {
        if (item.kind != .file or !shadow_root.isKey(item.name)) continue;
        var key: Key = undefined;
        @memcpy(&key, item.name);
        const slot = try entries.getOrPut(gpa, key);
        if (!slot.found_existing) slot.value_ptr.* = .{ .key = key };
        const stat = dir.statFile(io, item.name, .{ .follow_symlinks = false }) catch continue;
        slot.value_ptr.last_used = @max(slot.value_ptr.last_used, stat.mtime.nanoseconds);
    }
}

var noted: std.atomic.Value(u16) = .init(0);

pub fn note(err: anyerror) void {
    noted.store(@intFromError(err), .release);
}

pub fn takeFailure() ?anyerror {
    const raw = noted.swap(0, .acq_rel);
    if (raw == 0) return null;
    return @errorFromInt(raw);
}

pub fn writeReport(out: *std.Io.Writer, swept: anyerror!Report) !bool {
    const report = swept catch |err| {
        try out.print("could not sweep the emetgate caches: {t}\n", .{err});
        return true;
    };
    if (report.busy) {
        try out.writeAll("caches: another emetgate process is sweeping them\n");
        return false;
    }
    if (!report.ran) return false;
    try out.print("caches: removed {d} unused entr(ies), freed {d} MB, kept {d} ({d} MB), {d} in use, {d} with a marker naming another repository\n", .{ report.removed, report.freed_bytes / (1024 * 1024), report.kept, report.kept_bytes / (1024 * 1024), report.live, report.refused });
    const err = report.first_failure orelse return false;
    try out.print("could not sweep {d} cache entr(ies): {t}\n", .{ report.failed, err });
    return true;
}

pub const Background = struct {
    thread: ?std.Thread = null,
    cancel: std.atomic.Value(bool) = .init(false),

    pub fn start(self: *Background, gpa: Allocator, io: std.Io, policy: Policy) void {
        if (builtin.is_test) return;
        const data = cache_lease.defaultDataDir(gpa) catch return;
        self.thread = std.Thread.spawn(.{}, run, .{ gpa, io, data, policy, &self.cancel }) catch {
            gpa.free(data);
            return;
        };
    }

    pub fn stop(self: *Background) void {
        self.cancel.store(true, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    fn run(gpa: Allocator, io: std.Io, data: []u8, policy: Policy, cancel: *const std.atomic.Value(bool)) void {
        defer gpa.free(data);
        const now = std.Io.Clock.real.now(io).nanoseconds;
        const report = sweepDaily(gpa, io, data, policy, now, cancel) catch |err| {
            note(err);
            std.debug.print("emetgate: could not sweep the caches under {s}: {t}\n", .{ data, err });
            return;
        };
        const err = report.first_failure orelse return;
        note(err);
        std.debug.print("emetgate: could not sweep {d} cache entr(ies) under {s}: {t}\n", .{ report.failed, data, err });
    }
};

const testing = std.testing;
const day: i96 = std.time.ns_per_day;
const mib = 1024 * 1024;

const Fixture = struct {
    tmp: testing.TmpDir,
    top: [:0]u8,
    data: []u8,
    now: i96,

    fn init() !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const top = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        errdefer testing.allocator.free(top);
        const data = try std.fmt.allocPrint(testing.allocator, "{s}\\data", .{top});
        errdefer testing.allocator.free(data);
        try tmp.dir.createDirPath(testing.io, "data");
        return .{ .tmp = tmp, .top = top, .data = data, .now = std.Io.Clock.real.now(testing.io).nanoseconds };
    }

    fn deinit(self: *Fixture) void {
        testing.allocator.free(self.data);
        testing.allocator.free(self.top);
        self.tmp.cleanup();
    }

    fn root(self: *Fixture, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(testing.allocator, "{s}\\{s}", .{ self.top, name });
    }

    fn cache(self: *Fixture, family: []const u8, key: []const u8, bytes: usize, mtime: i96) !void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        try self.tmp.dir.createDirPath(testing.io, try std.fmt.bufPrint(&buf, "data/{s}/{s}", .{ family, key }));
        const blob = try testing.allocator.alloc(u8, bytes);
        defer testing.allocator.free(blob);
        @memset(blob, 'x');
        const sub = try std.fmt.bufPrint(&buf, "data/{s}/{s}/blob", .{ family, key });
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = blob });
        var file = try self.tmp.dir.openFile(testing.io, sub, .{ .mode = .read_write });
        defer file.close(testing.io);
        try file.setTimestamps(testing.io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = mtime } } });
    }

    fn workspace(self: *Fixture, key: []const u8, recorded: []const u8) !void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        try self.tmp.dir.createDirPath(testing.io, try std.fmt.bufPrint(&buf, "data/shadow/{s}/shadow/src", .{key}));
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = try std.fmt.bufPrint(&buf, "data/shadow/{s}/shadow/src/a.ts", .{key}), .data = "a\n" });
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = try std.fmt.bufPrint(&buf, "data/shadow/{s}/{s}", .{ key, shadow_root.marker_name }), .data = recorded });
    }

    fn present(self: *Fixture, family: []const u8, key: []const u8) bool {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const sub = std.fmt.bufPrint(&buf, "data/{s}/{s}", .{ family, key }) catch return false;
        self.tmp.dir.access(testing.io, sub, .{}) catch return false;
        return true;
    }

    fn sweepAt(self: *Fixture, policy: Policy, now: i96) !Report {
        return sweep(testing.allocator, testing.io, self.data, policy, now, null);
    }
};

test "a cache whose recorded repository is gone is removed from every family, whether the shadow marker or the lease records the root" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init();
    defer fx.deinit();
    const gone = try fx.root("gone");
    defer testing.allocator.free(gone);
    const left = try fx.root("left");
    defer testing.allocator.free(left);
    const gone_key = shadow_root.repoKey(gone);
    const left_key = shadow_root.repoKey(left);
    const kept_key = shadow_root.repoKey(fx.top);
    try fx.workspace(&gone_key, gone);
    try fx.cache("find", &gone_key, 100, fx.now);
    try fx.cache("index", &gone_key, 200, fx.now);
    try fx.cache("facts", &gone_key, 300, fx.now);
    const lease = try cache_lease.acquire(fx.data, left, 0);
    lease.release();
    try fx.cache("index", &left_key, 50, fx.now);
    try fx.workspace(&kept_key, fx.top);
    try fx.cache("find", &kept_key, 10, fx.now);

    const report = try fx.sweepAt(.{}, fx.now);
    try testing.expectEqual(@as(usize, 2), report.removed);
    try testing.expectEqual(@as(usize, 1), report.kept);
    try testing.expectEqual(@as(usize, 0), report.failed);
    try testing.expectEqual(@as(u64, 100 + 200 + 300 + 50 + 2 + gone.len), report.freed_bytes);
    for (families) |family| try testing.expect(!fx.present(family, &gone_key));
    try testing.expect(!fx.present("index", &left_key));
    try testing.expect(!fx.present(cache_lease.leases_dir, &left_key));
    try testing.expect(fx.present("find", &kept_key));
    try testing.expect(fx.present(shadow_family, &kept_key));
}

test "a marker that names a repository owning another key is refused and the young entry stays" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init();
    defer fx.deinit();
    const gone = try fx.root("gone");
    defer testing.allocator.free(gone);
    const other_key = shadow_root.repoKey("C:\\some\\other\\repository");
    try fx.workspace(&other_key, gone);
    try fx.cache("find", &other_key, 10, fx.now);

    const report = try fx.sweepAt(.{}, fx.now);
    try testing.expectEqual(@as(usize, 0), report.removed);
    try testing.expectEqual(@as(usize, 1), report.refused);
    try testing.expect(fx.present(shadow_family, &other_key));
    try testing.expect(fx.present("find", &other_key));
}

test "an entry unused for longer than the age limit is removed, and the limit can be raised" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init();
    defer fx.deinit();
    const key = shadow_root.repoKey("C:\\never\\recorded");
    try fx.cache("find", &key, 10, fx.now);

    const later = fx.now + 31 * day;
    try testing.expectEqual(@as(usize, 0), (try fx.sweepAt(.{ .max_age_days = 60 }, later)).removed);
    try testing.expect(fx.present("find", &key));
    try testing.expectEqual(@as(usize, 0), (try fx.sweepAt(.{}, fx.now + 29 * day)).removed);
    try testing.expect(fx.present("find", &key));
    const report = try fx.sweepAt(.{}, later);
    try testing.expectEqual(@as(usize, 1), report.removed);
    try testing.expect(!fx.present("find", &key));
}

test "over the size cap the least recently used entries go first, until the total fits" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init();
    defer fx.deinit();
    const oldest = shadow_root.repoKey("C:\\lru\\oldest");
    const middle = shadow_root.repoKey("C:\\lru\\middle");
    const newest = shadow_root.repoKey("C:\\lru\\newest");
    try fx.cache("index", &middle, mib, fx.now + 2 * day);
    try fx.cache("index", &newest, mib, fx.now + 3 * day);
    try fx.cache("find", &oldest, mib, fx.now + 1 * day);

    const report = try fx.sweepAt(.{ .max_mb = 2 }, fx.now + 3 * day);
    try testing.expectEqual(@as(usize, 1), report.removed);
    try testing.expectEqual(@as(u64, mib), report.freed_bytes);
    try testing.expect(!fx.present("find", &oldest));
    try testing.expect(fx.present("index", &middle));
    try testing.expect(fx.present("index", &newest));
}

test "an entry whose lease a live process holds is never removed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init();
    defer fx.deinit();
    const gone = try fx.root("gone");
    defer testing.allocator.free(gone);
    const key = shadow_root.repoKey(gone);
    try fx.workspace(&key, gone);
    try fx.cache("facts", &key, mib, fx.now);
    const lease = try cache_lease.acquire(fx.data, gone, 0);

    const held = fx.sweepAt(.{ .max_mb = 1, .max_age_days = 1 }, fx.now + 90 * day);
    lease.release();
    const report = try held;
    try testing.expectEqual(@as(usize, 1), report.live);
    try testing.expectEqual(@as(usize, 0), report.removed);
    try testing.expect(fx.present(shadow_family, &key));
    try testing.expect(fx.present("facts", &key));
    try testing.expectEqual(@as(usize, 1), (try fx.sweepAt(.{}, fx.now)).removed);
    try testing.expect(!fx.present("facts", &key));
}

test "only one process sweeps the caches at a time, and a second one leaves them alone" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init();
    defer fx.deinit();
    const gone = try fx.root("gone");
    defer testing.allocator.free(gone);
    const key = shadow_root.repoKey(gone);
    try fx.workspace(&key, gone);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const lock = try shadow.FileLock.acquire(try std.fmt.bufPrint(&buf, "{s}\\{s}", .{ fx.data, lock_name }));

    const busy = sweepDaily(testing.allocator, testing.io, fx.data, .{}, fx.now, null);
    lock.release();
    const report = try busy;
    try testing.expect(report.busy);
    try testing.expect(!report.ran);
    try testing.expect(fx.present(shadow_family, &key));
    try testing.expectEqual(@as(usize, 1), (try sweepDaily(testing.allocator, testing.io, fx.data, .{}, fx.now, null)).removed);
}

test "the daily sweep runs at most once a day per data directory" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init();
    defer fx.deinit();
    const first = try fx.root("first");
    defer testing.allocator.free(first);
    const second = try fx.root("second");
    defer testing.allocator.free(second);
    const first_key = shadow_root.repoKey(first);
    const second_key = shadow_root.repoKey(second);
    try fx.workspace(&first_key, first);

    const ran = try sweepDaily(testing.allocator, testing.io, fx.data, .{}, fx.now, null);
    try testing.expect(ran.ran);
    try testing.expectEqual(@as(usize, 1), ran.removed);
    try fx.workspace(&second_key, second);
    const skipped = try sweepDaily(testing.allocator, testing.io, fx.data, .{}, fx.now + 23 * std.time.ns_per_hour, null);
    try testing.expect(!skipped.ran);
    try testing.expect(fx.present(shadow_family, &second_key));
    const next = try sweepDaily(testing.allocator, testing.io, fx.data, .{}, fx.now + 25 * std.time.ns_per_hour, null);
    try testing.expect(next.ran);
    try testing.expect(!fx.present(shadow_family, &second_key));
}

test "an entry the sweep could not remove is reported, not swallowed, and a link target outside the data directory survives" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init();
    defer fx.deinit();
    const gone = try fx.root("gone");
    defer testing.allocator.free(gone);
    const key = shadow_root.repoKey(gone);
    try fx.workspace(&key, gone);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = try std.fmt.bufPrint(&buf, "data/shadow/{s}/unknown.txt", .{&key}), .data = "not ours\n" });
    const linked_root = try fx.root("linked");
    defer testing.allocator.free(linked_root);
    const linked = shadow_root.repoKey(linked_root);
    try fx.workspace(&linked, linked_root);
    try fx.tmp.dir.createDirPath(testing.io, "data/find");
    try fx.tmp.dir.createDirPath(testing.io, "victim");
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "victim/keep.txt", .data = "keep\n" });
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    try shadow.createJunction(testing.io, try std.fmt.bufPrint(&link_buf, "{s}\\find\\{s}", .{ fx.data, &linked }), try std.fmt.bufPrint(&target_buf, "{s}\\victim", .{fx.top}));

    const report = try fx.sweepAt(.{}, fx.now);
    try testing.expectEqual(@as(usize, 2), report.failed);
    try testing.expect(report.first_failure != null);
    try fx.tmp.dir.access(testing.io, "victim/keep.txt", .{});
    var out_buf: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    try testing.expect(try writeReport(&out, report));
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "could not sweep 2 cache entr(ies)") != null);

    note(error.WorkspaceNotEmpty);
    try testing.expectEqual(@as(?anyerror, error.WorkspaceNotEmpty), takeFailure());
    try testing.expectEqual(@as(?anyerror, null), takeFailure());
}

test "cache flags parse once each and refuse zero, junk and repeats" {
    var flags: Flags = .{};
    const good = [_][]const u8{ "--cache-max-age-days", "7", "--cache-max-mb", "100" };
    var i: usize = 0;
    try testing.expectEqual(@as(?bool, true), flags.take(&good, &i));
    i += 1;
    try testing.expectEqual(@as(?bool, true), flags.take(&good, &i));
    try testing.expectEqual(@as(u32, 7), flags.policy.max_age_days);
    try testing.expectEqual(@as(u64, 100), flags.policy.max_mb);
    var j: usize = 0;
    try testing.expectEqual(@as(?bool, null), flags.take(&good, &j));
    const bads = [_][]const []const u8{ &.{ "--cache-max-mb", "0" }, &.{ "--cache-max-mb", "x" }, &.{"--cache-max-age-days"} };
    for (bads) |bad| {
        var fresh: Flags = .{};
        var k: usize = 0;
        try testing.expectEqual(@as(?bool, null), fresh.take(bad, &k));
    }
    var other: Flags = .{};
    var k: usize = 0;
    try testing.expectEqual(@as(?bool, false), other.take(&[_][]const u8{"--commit"}, &k));
}
