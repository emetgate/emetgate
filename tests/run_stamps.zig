const std = @import("std");
const builtin = @import("builtin");
const run_stamps = @import("emetgate").run_stamps;
const receipts = @import("emetgate").receipts;
const receipt = @import("emetgate").receipt;

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;

const old_ns: i96 = 1_577_836_800 * std.time.ns_per_s;

const Tree = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    arena_state: std.heap.ArenaAllocator,

    fn init() !Tree {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        return .{ .tmp = tmp, .root = root, .arena_state = .init(gpa) };
    }

    fn deinit(self: *Tree) void {
        self.arena_state.deinit();
        gpa.free(self.root);
        self.tmp.cleanup();
    }

    fn arena(self: *Tree) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    fn write(self: *Tree, rel: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(rel)) |parent| try self.tmp.dir.createDirPath(io, parent);
        try self.tmp.dir.writeFile(io, .{ .sub_path = rel, .data = data });
    }

    fn age(self: *Tree, rel: []const u8) !void {
        try self.putWriteTimeBack(rel);
        try self.setChangeTime(rel, old_ns);
    }

    fn setChangeTime(self: *Tree, rel: []const u8, ns: i96) !void {
        const file = try self.tmp.dir.openFile(io, rel, .{ .mode = .read_write });
        defer file.close(io);
        const win = std.os.windows;
        var info = std.mem.zeroes(win.FILE.BASIC_INFORMATION);
        info.ChangeTime = @intCast(@divTrunc(ns, 100) + 116_444_736_000_000_000);
        var iosb: win.IO_STATUS_BLOCK = undefined;
        if (win.ntdll.NtSetInformationFile(file.handle, &iosb, &info, @sizeOf(win.FILE.BASIC_INFORMATION), .Basic) != .SUCCESS) return error.ChangeTimeNotSet;
    }

    fn putWriteTimeBack(self: *Tree, rel: []const u8) !void {
        const file = try self.tmp.dir.openFile(io, rel, .{ .mode = .read_write });
        defer file.close(io);
        try file.setTimestamps(io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = old_ns } } });
    }

    fn writeOld(self: *Tree, rel: []const u8, data: []const u8) !void {
        try self.write(rel, data);
        try self.age(rel);
    }

    fn reader(self: *Tree) run_stamps.Reader {
        return .{ .gpa = gpa, .io = io, .root_abs = self.root };
    }

    fn stamps(self: *Tree, files: []const []const u8) ![]?run_stamps.Stamp {
        return run_stamps.stampsOf(gpa, self.arena(), self.root, files);
    }

    fn take(self: *Tree, r: *run_stamps.Reader, files: []const []const u8, memo: ?*const run_stamps.Memo) !run_stamps.Before {
        return run_stamps.take(self.arena(), r, files, try self.stamps(files), memo, now());
    }
};

fn now() i96 {
    return std.Io.Timestamp.now(io, .real).nanoseconds;
}

/// The comparison as it was before stamps: every file hashed before and after.
const Reference = struct {
    seen: std.StringArrayHashMapUnmanaged(receipt.Hash) = .empty,

    fn take(arena: std.mem.Allocator, r: *run_stamps.Reader, files: []const []const u8) !Reference {
        var out: Reference = .{};
        for (files) |rel| try out.seen.put(arena, rel, r.hash(rel) orelse continue);
        return out;
    }

    fn compare(self: *const Reference, arena: std.mem.Allocator, r: *run_stamps.Reader, files: []const []const u8, started_ns: i96) ![]receipts.FileChange {
        var changes: std.ArrayList(receipts.FileChange) = .empty;
        var present: std.StringHashMapUnmanaged(void) = .empty;
        for (files) |rel| {
            try present.put(arena, rel, {});
            const abs = try run_stamps.absOf(arena, r.root_abs, rel);
            const was = self.seen.get(rel);
            if (was == null) {
                const stat = std.Io.Dir.cwd().statFile(io, abs, .{}) catch continue;
                if (run_stamps.untouchedSince(.{ .mtime_ns = @intCast(stat.mtime.nanoseconds), .ctime_ns = @intCast(stat.ctime.nanoseconds), .size = stat.size }, started_ns)) continue;
            }
            const hash = r.hash(rel) orelse continue;
            if (was) |h| if (std.mem.eql(u8, &h, &hash)) continue;
            try changes.append(arena, .{ .rel = rel, .before = was, .after_abs = abs });
        }
        for (self.seen.keys(), self.seen.values()) |rel, hash| {
            if (present.contains(rel)) continue;
            if (std.Io.Dir.cwd().access(io, try run_stamps.absOf(arena, r.root_abs, rel), .{})) |_| continue else |_| {}
            try changes.append(arena, .{ .rel = rel, .before = hash, .after_abs = null });
        }
        return changes.items;
    }
};

fn expectSameChanges(expected: []const receipts.FileChange, actual: []const receipts.FileChange) !void {
    errdefer {
        std.debug.print("expected:\n", .{});
        for (expected) |c| std.debug.print("  {s} before={any} after={?s}\n", .{ c.rel, c.before != null, c.after_abs });
        std.debug.print("actual:\n", .{});
        for (actual) |c| std.debug.print("  {s} before={any} after={?s}\n", .{ c.rel, c.before != null, c.after_abs });
    }
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| {
        try testing.expectEqualStrings(e.rel, a.rel);
        try testing.expectEqual(e.before, a.before);
        try testing.expectEqual(e.after_abs == null, a.after_abs == null);
        if (e.after_abs) |abs| try testing.expectEqualStrings(abs, a.after_abs.?);
    }
}

fn findChange(changes: []const receipts.FileChange, rel: []const u8) ?receipts.FileChange {
    for (changes) |c| if (std.mem.eql(u8, c.rel, rel)) return c;
    return null;
}

test "run stamps: modified, created, deleted, touched-but-identical and untouched files come out as a full hash finds them, and untouched files are not read" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.writeOld("src/modified.ts", "one");
    try tree.writeOld("src/deleted.ts", "gone soon");
    try tree.writeOld("src/touched.ts", "same bytes");
    try tree.writeOld("src/untouched.ts", "never changes");
    try tree.writeOld("src/same_size.ts", "aaaa");
    try tree.writeOld("cache/entered.pyc", "old cache");
    const before_files = [_][]const u8{ "src/modified.ts", "src/deleted.ts", "src/touched.ts", "src/untouched.ts", "src/same_size.ts" };

    var r = tree.reader();
    const before = try tree.take(&r, &before_files, null);
    var ref_reader = tree.reader();
    const reference = try Reference.take(tree.arena(), &ref_reader, &before_files);
    const started_ns = now();

    try tree.write("src/modified.ts", "one and more");
    try tree.tmp.dir.deleteFile(io, "src/deleted.ts");
    try tree.write("src/touched.ts", "same bytes");
    try tree.write("src/same_size.ts", "bbbb");
    try tree.write("src/created.ts", "new");
    const after_files = [_][]const u8{ "cache/entered.pyc", "src/created.ts", "src/modified.ts", "src/same_size.ts", "src/touched.ts", "src/untouched.ts" };

    r.reads = 0;
    const compared = try run_stamps.compare(tree.arena(), &r, &after_files, try tree.stamps(&after_files), &before, started_ns);
    const expected = try reference.compare(tree.arena(), &ref_reader, &after_files, started_ns);
    try expectSameChanges(expected, compared.changes);

    try testing.expectEqual(@as(usize, 4), compared.changes.len);
    try testing.expect(findChange(compared.changes, "src/modified.ts").?.before != null);
    try testing.expect(findChange(compared.changes, "src/same_size.ts").?.before != null);
    try testing.expect(findChange(compared.changes, "src/created.ts").?.before == null);
    try testing.expect(findChange(compared.changes, "src/deleted.ts").?.after_abs == null);
    try testing.expect(findChange(compared.changes, "src/touched.ts") == null);
    try testing.expect(findChange(compared.changes, "cache/entered.pyc") == null);
    try testing.expectEqual(@as(usize, 4), r.reads);
}

test "run stamps: a file changed within the same second at the same size is found, whether or not its stamp moved" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.write("racy.ts", "aaaa");
    try tree.writeOld("old.ts", "cccc");
    const files = [_][]const u8{ "racy.ts", "old.ts" };
    var r = tree.reader();
    const stamps = try tree.stamps(&files);
    const before = try run_stamps.take(tree.arena(), &r, &files, stamps, null, now());
    try testing.expectEqual(@as(usize, 2), r.reads);
    const started_ns = now();
    try tree.write("racy.ts", "bbbb");

    r.reads = 0;
    const moved = try run_stamps.compare(tree.arena(), &r, &files, try tree.stamps(&files), &before, started_ns);
    try testing.expectEqual(@as(usize, 1), moved.changes.len);
    try testing.expectEqualStrings("racy.ts", moved.changes[0].rel);
    try testing.expectEqual(@as(usize, 1), r.reads);

    // A filesystem with coarse times can leave size and times as they were:
    // the racy rule still reads the file because its write time is too close
    // to the snapshot for the stamp to vouch for it.
    r.reads = 0;
    const same = try run_stamps.compare(tree.arena(), &r, &files, stamps, &before, started_ns);
    try testing.expectEqual(@as(usize, 1), same.changes.len);
    try testing.expectEqualStrings("racy.ts", same.changes[0].rel);
    try testing.expect(same.changes[0].before != null);
    try testing.expectEqual(@as(usize, 1), r.reads);
}

test "run stamps: the memo spares unchanged old files the read on the next snapshot, and a file whose stamp moved is read again" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.writeOld("a.ts", "alpha");
    try tree.writeOld("b.ts", "beta");
    try tree.write("fresh.ts", "fresh");
    const files = [_][]const u8{ "a.ts", "b.ts", "fresh.ts" };
    var memo = run_stamps.Memo.init(gpa);
    defer memo.deinit();

    var r = tree.reader();
    const first = try tree.take(&r, &files, &memo);
    try testing.expectEqual(@as(usize, 3), r.reads);
    try run_stamps.rememberAll(&memo, &first);

    r.reads = 0;
    const second = try tree.take(&r, &files, &memo);
    try testing.expectEqual(@as(usize, 1), r.reads);
    try testing.expectEqualDeep(first.files.get("a.ts").?.hash, second.files.get("a.ts").?.hash);
    try run_stamps.rememberAll(&memo, &second);

    try tree.write("b.ts", "BETA");
    try tree.putWriteTimeBack("b.ts");
    r.reads = 0;
    const third = try tree.take(&r, &files, &memo);
    try testing.expectEqual(@as(usize, 2), r.reads);
    try testing.expect(!std.mem.eql(u8, &second.files.get("b.ts").?.hash, &third.files.get("b.ts").?.hash));
}

test "run stamps: what compare read goes into the memo and a deleted file leaves it" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.writeOld("kept.ts", "kept");
    try tree.writeOld("changed.ts", "one");
    try tree.writeOld("deleted.ts", "bye");
    const before_files = [_][]const u8{ "changed.ts", "deleted.ts", "kept.ts" };
    var memo = run_stamps.Memo.init(gpa);
    defer memo.deinit();
    var r = tree.reader();
    const before = try tree.take(&r, &before_files, &memo);
    try run_stamps.rememberAll(&memo, &before);
    const started_ns = now();
    try tree.writeOld("changed.ts", "two!");
    try tree.tmp.dir.deleteFile(io, "deleted.ts");
    const after_files = [_][]const u8{ "changed.ts", "kept.ts" };
    const stamps = try tree.stamps(&after_files);
    const compared = try run_stamps.compare(tree.arena(), &r, &after_files, stamps, &before, started_ns);
    try testing.expectEqual(@as(usize, 2), compared.changes.len);
    try run_stamps.rememberCompared(&memo, compared, now());
    try testing.expect(memo.files.get("deleted.ts") == null);
    const fresh = receipt.blake3("two!");
    try testing.expectEqualDeep(fresh, memo.recall("changed.ts", stamps[0]).?);
}

test "run stamps: a large unchanged file is never read, before or after the command" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    const big = try gpa.alloc(u8, 16 * 1024 * 1024);
    defer gpa.free(big);
    @memset(big, 'x');
    try tree.writeOld("big.bin", big);
    try tree.writeOld("small.ts", "small");
    const files = [_][]const u8{ "big.bin", "small.ts" };
    var memo = run_stamps.Memo.init(gpa);
    defer memo.deinit();
    var r = tree.reader();
    try run_stamps.rememberAll(&memo, &try tree.take(&r, &files, &memo));

    r.reads = 0;
    const before = try tree.take(&r, &files, &memo);
    try testing.expectEqual(@as(usize, 0), r.reads);
    const started_ns = now();
    try tree.write("small.ts", "SMALL!");
    const compared = try run_stamps.compare(tree.arena(), &r, &files, try tree.stamps(&files), &before, started_ns);
    try testing.expectEqual(@as(usize, 1), compared.changes.len);
    try testing.expectEqualStrings("small.ts", compared.changes[0].rel);
    try testing.expectEqual(@as(usize, 1), r.reads);
}

test "run stamps: a file the platform gives no stamp for is always read" {
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.writeOld("a.ts", "one");
    const files = [_][]const u8{"a.ts"};
    const none = [_]?run_stamps.Stamp{null};
    var r = tree.reader();
    const before = try run_stamps.take(tree.arena(), &r, &files, &none, null, now());
    const started_ns = now();
    try tree.writeOld("a.ts", "two");
    r.reads = 0;
    const compared = try run_stamps.compare(tree.arena(), &r, &files, &none, &before, started_ns);
    try testing.expectEqual(@as(usize, 1), compared.changes.len);
    try testing.expectEqual(@as(usize, 1), r.reads);
}

test "run stamps: a same-size rewrite inside one clock tick, with its write time put back, is read again while its change time is recent" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    const files = [_][]const u8{"tick.ts"};
    const changed_ns = now() - std.time.ns_per_s;
    try tree.write("tick.ts", "first");
    try tree.putWriteTimeBack("tick.ts");
    try tree.setChangeTime("tick.ts", changed_ns);
    var memo = run_stamps.Memo.init(gpa);
    defer memo.deinit();
    var r = tree.reader();
    const before = try tree.take(&r, &files, &memo);
    try run_stamps.rememberAll(&memo, &before);

    try tree.write("tick.ts", "FIRST");
    try tree.putWriteTimeBack("tick.ts");
    try tree.setChangeTime("tick.ts", changed_ns);
    r.reads = 0;
    const after = try tree.take(&r, &files, &memo);
    try testing.expectEqual(@as(usize, 1), r.reads);
    try testing.expect(!std.mem.eql(u8, &before.files.get("tick.ts").?.hash, &after.files.get("tick.ts").?.hash));
}
