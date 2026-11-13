//! Which working files a command changed, without hashing the whole tree twice.
//!
//! Before the command every working file gets a stamp (size, write time and
//! change time, read from the directory listing). Its content hash comes from
//! the memo this process keeps per repository when the stamp still matches
//! and the file was already old when that hash was taken; otherwise the file
//! is read. After the command a file whose stamp is unchanged and whose write
//! time lies more than `mtime_slack_ns` before the snapshot counts as
//! unchanged without being read. Every other file is read again: a changed
//! stamp, a new file, or a racy one whose write time is too close to the
//! snapshot for the stamp to prove anything (git's racy-clean rule).
//! The memo lives in process memory only, so the command cannot plant a
//! hash in it.

const std = @import("std");
const receipts = @import("receipts.zig");
const receipt = @import("../verify/receipt.zig");
const stat_scan = @import("stat_scan.zig");

const Allocator = std.mem.Allocator;
const Hash = receipt.Hash;

pub const Stamp = stat_scan.Stamp;

pub const mtime_slack_ns: i96 = 2 * std.time.ns_per_s;

pub fn untouchedSince(mtime_ns: i96, started_ns: i96) bool {
    return mtime_ns < started_ns - mtime_slack_ns;
}

pub const max_hashed_bytes = 256 * 1024 * 1024;

/// Reads and hashes working files, counting each read.
pub const Reader = struct {
    gpa: Allocator,
    io: std.Io,
    root_abs: []const u8,
    reads: usize = 0,

    pub fn hash(self: *Reader, rel: []const u8) ?Hash {
        var buffer: [2 * std.fs.max_path_bytes]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&buffer);
        const abs = absOf(fixed.allocator(), self.root_abs, rel) catch return null;
        self.reads += 1;
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, abs, self.gpa, .limited(max_hashed_bytes)) catch return null;
        defer self.gpa.free(bytes);
        return receipt.blake3(bytes);
    }
};

pub fn absOf(arena: Allocator, root_abs: []const u8, rel: []const u8) ![]u8 {
    const abs = try std.fmt.allocPrint(arena, "{s}\\{s}", .{ root_abs, rel });
    std.mem.replaceScalar(u8, abs, '/', '\\');
    return abs;
}

/// The stamp of each listed regular file; null for a link, a directory, a
/// missing file or where the platform gives no listing, which is always read.
pub fn stampsOf(gpa: Allocator, arena: Allocator, root_abs: []const u8, files: []const []const u8) ![]?Stamp {
    const seen = try gpa.alloc(?stat_scan.Seen, files.len);
    defer gpa.free(seen);
    try stat_scan.stampAll(gpa, root_abs, files, seen, null);
    const out = try arena.alloc(?Stamp, files.len);
    for (seen, out) |s, *o| o.* = if (s) |known| (if (known.kind == .file) known.stamp else null) else null;
    return out;
}

pub const Entry = struct { stamp: ?Stamp, hash: Hash };

pub const Before = struct {
    /// Wall time taken before the first stamp was read.
    at_ns: i96,
    files: std.StringArrayHashMapUnmanaged(Entry) = .empty,
};

fn sameStamp(a: Stamp, b: Stamp) bool {
    return a.size == b.size and a.mtime_ns == b.mtime_ns and a.ctime_ns == b.ctime_ns;
}

/// A hash taken earlier, kept while the stamp it was taken under still holds.
pub const Known = struct { stamp: Stamp, hash: Hash, at_ns: i96 };

pub const Memo = struct {
    arena: std.heap.ArenaAllocator,
    files: std.StringHashMapUnmanaged(Known) = .empty,

    pub fn init(backing: Allocator) Memo {
        return .{ .arena = .init(backing) };
    }

    pub fn deinit(self: *Memo) void {
        self.arena.deinit();
    }

    /// The remembered hash, when the file still has the stamp it had then and
    /// was already old enough at that time for the stamp to vouch for it.
    pub fn recall(self: *const Memo, rel: []const u8, stamp: ?Stamp) ?Hash {
        const now = stamp orelse return null;
        const known = self.files.get(rel) orelse return null;
        if (!sameStamp(known.stamp, now)) return null;
        if (!untouchedSince(known.stamp.mtime_ns, known.at_ns)) return null;
        return known.hash;
    }

    pub fn remember(self: *Memo, rel: []const u8, stamp: ?Stamp, hash: Hash, at_ns: i96) !void {
        const a = self.arena.allocator();
        const now = stamp orelse {
            _ = self.files.remove(rel);
            return;
        };
        const got = try self.files.getOrPut(a, rel);
        if (!got.found_existing) got.key_ptr.* = try a.dupe(u8, rel);
        got.value_ptr.* = .{ .stamp = now, .hash = hash, .at_ns = at_ns };
    }

    pub fn forget(self: *Memo, rel: []const u8) void {
        _ = self.files.remove(rel);
    }
};

/// The state before the command: each readable file's stamp and content hash.
pub fn take(arena: Allocator, reader: *Reader, files: []const []const u8, stamps: []const ?Stamp, memo: ?*const Memo, at_ns: i96) !Before {
    std.debug.assert(files.len == stamps.len);
    var before: Before = .{ .at_ns = at_ns };
    try before.files.ensureTotalCapacity(arena, files.len);
    for (files, stamps) |rel, stamp| {
        const hash = (if (memo) |m| m.recall(rel, stamp) else null) orelse reader.hash(rel) orelse continue;
        before.files.putAssumeCapacity(rel, .{ .stamp = stamp, .hash = hash });
    }
    return before;
}

/// Replaces the memo's content with what `take` saw.
pub fn rememberAll(memo: *Memo, before: *const Before) !void {
    _ = memo.arena.reset(.retain_capacity);
    memo.files = .empty;
    for (before.files.keys(), before.files.values()) |rel, entry| {
        try memo.remember(rel, entry.stamp, entry.hash, before.at_ns);
    }
}

pub const Compared = struct {
    changes: []receipts.FileChange,
    /// Files read after the command, with the stamp they had when read.
    fresh: []const Fresh,
    gone: []const []const u8,
};

pub const Fresh = struct { rel: []const u8, stamp: ?Stamp, hash: Hash };

/// The files the command created, changed or deleted, in listing order and
/// then deleted files in snapshot order.
pub fn compare(arena: Allocator, reader: *Reader, files: []const []const u8, stamps: []const ?Stamp, before: *const Before, started_ns: i96) !Compared {
    std.debug.assert(files.len == stamps.len);
    const io = reader.io;
    const root_abs = reader.root_abs;
    var changes: std.ArrayList(receipts.FileChange) = .empty;
    var fresh: std.ArrayList(Fresh) = .empty;
    var gone: std.ArrayList([]const u8) = .empty;
    var present: std.StringHashMapUnmanaged(void) = .empty;
    for (files, stamps) |rel, stamp| {
        try present.put(arena, rel, {});
        const abs = try absOf(arena, root_abs, rel);
        const was = before.files.get(rel);
        if (was == null) {
            const stat = std.Io.Dir.cwd().statFile(io, abs, .{}) catch continue;
            if (untouchedSince(stat.mtime.nanoseconds, started_ns)) continue;
        }
        if (was) |entry| if (entry.stamp != null and stamp != null and sameStamp(entry.stamp.?, stamp.?) and untouchedSince(stamp.?.mtime_ns, before.at_ns)) continue;
        const now = reader.hash(rel) orelse continue;
        try fresh.append(arena, .{ .rel = rel, .stamp = stamp, .hash = now });
        if (was) |entry| if (std.mem.eql(u8, &entry.hash, &now)) continue;
        try changes.append(arena, .{ .rel = rel, .before = if (was) |entry| entry.hash else null, .after_abs = abs });
    }
    for (before.files.keys(), before.files.values()) |rel, entry| {
        if (present.contains(rel)) continue;
        try gone.append(arena, rel);
        if (std.Io.Dir.cwd().access(io, try absOf(arena, root_abs, rel), .{})) |_| continue else |_| {}
        try changes.append(arena, .{ .rel = rel, .before = entry.hash, .after_abs = null });
    }
    return .{ .changes = changes.items, .fresh = fresh.items, .gone = gone.items };
}

/// Folds what `compare` read into the memo, so the next snapshot need not read it.
pub fn rememberCompared(memo: *Memo, compared: Compared, at_ns: i96) !void {
    for (compared.fresh) |f| try memo.remember(f.rel, f.stamp, f.hash, at_ns);
    for (compared.gone) |rel| memo.forget(rel);
}

/// One memo per repository root for the life of the process.
pub const Store = struct {
    lock: std.Io.Mutex = .init,
    slots: [slots_len]?Slot = @splat(null),
    next: usize = 0,

    const slots_len = 8;
    const backing = std.heap.page_allocator;
    const Slot = struct { root: []u8, memo: *Memo };

    /// Returns the memo for `root_abs` with the store locked; call `release` after.
    pub fn acquire(self: *Store, io: std.Io, root_abs: []const u8) !*Memo {
        self.lock.lockUncancelable(io);
        errdefer self.lock.unlock(io);
        for (&self.slots) |*slot| {
            const s = slot.* orelse continue;
            if (std.ascii.eqlIgnoreCase(s.root, root_abs)) return s.memo;
        }
        const memo = try backing.create(Memo);
        errdefer backing.destroy(memo);
        memo.* = .init(backing);
        const root = try backing.dupe(u8, root_abs);
        const at = self.next % slots_len;
        self.next += 1;
        if (self.slots[at]) |old| {
            old.memo.deinit();
            backing.destroy(old.memo);
            backing.free(old.root);
        }
        self.slots[at] = .{ .root = root, .memo = memo };
        return memo;
    }

    pub fn release(self: *Store, io: std.Io) void {
        self.lock.unlock(io);
    }
};

pub var store: Store = .{};
