const std = @import("std");
const symbol = @import("../engine/symbol.zig");
const shadow = @import("shadow.zig");
const disk = @import("disk.zig");
const commit_record = @import("commit_record.zig");
const git_commit = @import("git_commit.zig");
const own_dir = @import("own_dir.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

pub const dir_name = "intents";
pub const version: u32 = 1;
pub const max_bytes = 16 * 1024 * 1024;
pub const max_staged_bytes = 1024 * 1024 * 1024;

pub const Tag = commit_record.Tag;

pub const Item = struct {
    path: []const u8,
    mode: []const u8,
    blob: []const u8 = "",
    base: []const u8 = "",
    new: []const u8 = "",
};

pub const Record = struct {
    version: u32 = version,
    commit: []const u8,
    base: []const u8,
    branch: []const u8,
    lock: []const u8,
    index_base: []const u8 = "",
    items: []const Item,
};

pub const Report = struct {
    landed: usize = 0,
    dropped: usize = 0,
    written: usize = 0,
    left: usize = 0,
    pending: usize = 0,
    failed: usize = 0,
    reason: ?[]const u8 = null,
    named: [named_bytes]u8 = undefined,
    named_len: usize = 0,

    pub const named_bytes = 480;

    pub fn names(self: *const Report) []const u8 {
        return self.named[0..self.named_len];
    }

    pub fn name(self: *Report, path: []const u8) void {
        const separator: []const u8 = if (self.named_len == 0) "" else ", ";
        if (self.named_len + separator.len + path.len > named_bytes) return;
        @memcpy(self.named[self.named_len..][0..separator.len], separator);
        self.named_len += separator.len;
        @memcpy(self.named[self.named_len..][0..path.len], path);
        self.named_len += path.len;
    }

    pub fn add(self: *Report, other: Report) void {
        var parts = std.mem.splitSequence(u8, other.names(), ", ");
        while (parts.next()) |part| {
            if (part.len != 0) self.name(part);
        }
        self.landed += other.landed;
        self.dropped += other.dropped;
        self.written += other.written;
        self.left += other.left;
        self.pending += other.pending;
        self.failed += other.failed;
        if (other.reason) |reason| self.reason = reason;
    }
};

pub const index_not_published = "IndexNotPublished";
pub const index_locked = "IndexLocked";
pub const index_not_updated = "IndexNotUpdated";
pub const file_not_written = "FileNotWritten";
pub const target_changed = "TargetChangedAfterCommit";
pub const index_changed = "IndexChangedAfterCommit";

pub fn dirOf(gpa: Allocator, root: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}\\{s}\\{s}", .{ root, shadow.workspace_dir, dir_name });
}

fn recordPath(arena: Allocator, dir: []const u8, tag: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena, "{s}\\{s}.json", .{ dir, tag });
}

fn stagedPath(arena: Allocator, dir: []const u8, tag: []const u8, index: usize) ![]u8 {
    return std.fmt.allocPrint(arena, "{s}\\{s}.{d}.new", .{ dir, tag, index });
}

pub fn indexPath(arena: Allocator, dir: []const u8, tag: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena, "{s}\\{s}.index", .{ dir, tag });
}

pub fn stage(gpa: Allocator, io: std.Io, root: []const u8, tag: []const u8, contents: []const ?[]const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = try dirOf(arena, root);
    const held = (try own_dir.hold(io, dir, .create)).?;
    defer held.close();
    for (contents, 0..) |content, i| {
        const bytes = content orelse continue;
        try disk.writeDurably(io, try stagedPath(arena, dir, tag, i), bytes);
    }
}

pub fn write(gpa: Allocator, io: std.Io, root: []const u8, tag: []const u8, record: Record) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = try dirOf(arena, root);
    const held = (try own_dir.hold(io, dir, .create)).?;
    defer held.close();
    const final = try recordPath(arena, dir, tag);
    const staged = try std.fmt.allocPrint(arena, "{s}.tmp", .{final});
    var buffer: std.Io.Writer.Allocating = .init(arena);
    var js: std.json.Stringify = .{ .writer = &buffer.writer };
    try js.write(record);
    Dir.deleteFileAbsolute(io, staged) catch {};
    try disk.writeDurably(io, staged, buffer.written());
    errdefer Dir.deleteFileAbsolute(io, staged) catch {};
    try disk.moveOver(gpa, staged, final);
    commit_record.flushDir(dir) catch {};
}

const record_suffix = ".json";
const own_suffixes = [_][]const u8{ record_suffix, ".json.tmp", ".index" };

fn ownTag(name: []const u8) ?[]const u8 {
    if (own_dir.tagOf(name, &own_suffixes)) |tag| return tag;
    if (name.len <= own_dir.tag_len or !own_dir.isTag(name[0..own_dir.tag_len])) return null;
    return if (own_dir.numbered(name[own_dir.tag_len..], ".", ".new")) name[0..own_dir.tag_len] else null;
}

fn removeFiles(arena: Allocator, io: std.Io, held: own_dir.Held, tag: ?[]const u8) !void {
    var names: std.ArrayList([]const u8) = .empty;
    var it = held.dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const owner = ownTag(entry.name) orelse continue;
        if (tag) |t| {
            if (!std.mem.eql(u8, owner, t)) continue;
        }
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    for (names.items) |name| {
        if (std.mem.endsWith(u8, name, record_suffix)) continue;
        held.dir.deleteFile(io, name) catch {};
    }
    for (names.items) |name| {
        if (!std.mem.endsWith(u8, name, record_suffix)) continue;
        held.dir.deleteFile(io, name) catch return error.IntentNotRemoved;
    }
}

fn release(held: own_dir.Held, dir_abs: []const u8) void {
    commit_record.flushDir(dir_abs) catch {};
    held.close();
    _ = own_dir.removeEmpty(dir_abs);
}

pub fn discard(gpa: Allocator, io: std.Io, root: []const u8, tag: []const u8, lock: ?git_commit.Digest) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (lock) |digest| git_commit.releaseIndex(gpa, io, root, digest) catch {};
    const dir = dirOf(arena, root) catch return;
    const held = (own_dir.hold(io, dir, .existing) catch return) orelse return;
    removeFiles(arena, io, held, tag) catch {};
    release(held, dir);
}

fn isObjectId(text: []const u8) bool {
    if (text.len != 40 and text.len != 64) return false;
    for (text) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

fn parseDigest(hex: []const u8) !git_commit.Digest {
    var out: git_commit.Digest = undefined;
    if (hex.len != out.len * 2) return error.CorruptIntent;
    _ = std.fmt.hexToBytes(&out, hex) catch return error.CorruptIntent;
    return out;
}

fn optionalHash(hex: []const u8) !?symbol.Hash {
    if (hex.len == 0) return null;
    return symbol.parseHash(hex) catch error.CorruptIntent;
}

fn hashAt(gpa: Allocator, io: std.Io, path_abs: []const u8) !?symbol.Hash {
    return disk.hashFile(gpa, io, path_abs) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| e,
    };
}

fn same(a: ?symbol.Hash, b: ?symbol.Hash) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, &a.?, &b.?);
}

const Forward = enum { kept, written, left };

fn readAt(arena: Allocator, io: std.Io, path_abs: []const u8) !?[]const u8 {
    return Dir.cwd().readFileAlloc(io, path_abs, arena, .limited(max_staged_bytes)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| return e,
    };
}

fn forwardOne(gpa: Allocator, arena: Allocator, io: std.Io, root: []const u8, dir: []const u8, tag: []const u8, base_oid: []const u8, index: usize, item: Item) !Forward {
    try shadow.validateRelative(item.path);
    const abs = try std.fmt.allocPrint(arena, "{s}\\{s}", .{ root, item.path });
    std.mem.replaceScalar(u8, abs, '/', '\\');
    const base = try optionalHash(item.base);
    const new = try optionalHash(item.new);
    const found = try readAt(arena, io, abs);
    const now: ?symbol.Hash = if (found) |bytes| symbol.hashOf(bytes) else null;
    if (same(now, new)) return .kept;
    if (base != null and !same(now, base)) return .left;
    if (found) |bytes| {
        if (base_oid.len == 0) return .left;
        const stored = try git_commit.storedForm(gpa, io, root, item.path, bytes);
        defer gpa.free(stored);
        if (!std.mem.eql(u8, stored, base_oid)) return .left;
    } else if (base_oid.len != 0) return .left;
    const journal_dir = try std.fmt.allocPrint(arena, "{s}\\{s}\\journal", .{ root, shadow.workspace_dir });

    if (new == null) {
        var pendings = [1]disk.Pending{try disk.stageDelete(gpa, io, abs, now.?)};
        pendings[0].base_in_history = true;
        try disk.commitBatch(&pendings, null, null, null, null);
        return .written;
    }
    const staged = try stagedPath(arena, dir, tag, index);
    const bytes = try Dir.cwd().readFileAlloc(io, staged, arena, .limited(max_staged_bytes));
    if (!std.mem.eql(u8, &symbol.hashOf(bytes), &new.?)) return error.CorruptIntent;
    if (!try git_commit.storesAs(gpa, io, root, item.path, staged, item.blob)) return error.CorruptIntent;
    if (now) |expected| {
        var pendings = [1]disk.Pending{try disk.prepare(gpa, io, abs, bytes, expected)};
        pendings[0].base_in_history = true;
        const journal = disk.Batch.init(gpa, io, journal_dir);
        try disk.commitBatch(&pendings, null, null, &journal, null);
        return .written;
    }
    if (std.fs.path.dirname(abs)) |parent| try Dir.cwd().createDirPath(io, parent);
    disk.create(gpa, io, abs, bytes) catch |err| switch (err) {
        error.FileExists => return .left,
        else => |e| return e,
    };
    return .written;
}

pub fn finish(gpa: Allocator, io: std.Io, root: []const u8, tag: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = try dirOf(arena, root);
    const held = (try own_dir.hold(io, dir, .existing)) orelse return;
    removeFiles(arena, io, held, tag) catch |err| {
        held.close();
        return err;
    };
    release(held, dir);
}

pub fn complete(gpa: Allocator, io: std.Io, root: []const u8, tag: []const u8, step: ?*const disk.Step) !Report {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = try dirOf(arena, root);
    if (!own_dir.isTag(tag)) return error.CorruptIntent;
    const folder = (try own_dir.hold(io, dir, .existing)) orelse return error.FileNotFound;
    var holding = true;
    defer if (holding) folder.close();
    const bytes = try folder.dir.readFileAlloc(io, try std.fmt.allocPrint(arena, "{s}" ++ record_suffix, .{tag}), arena, .limited(max_bytes));
    const record = std.json.parseFromSliceLeaky(Record, arena, bytes, .{ .ignore_unknown_fields = true }) catch return error.CorruptIntent;
    if (record.version != version) return error.CorruptIntent;
    if (!isObjectId(record.commit) or !isObjectId(record.base)) return error.CorruptIntent;
    if (!std.mem.startsWith(u8, record.branch, git_commit.branch_prefix)) return error.CorruptIntent;
    const lock = try parseDigest(record.lock);
    const index_base: ?git_commit.Digest = if (record.index_base.len == 0) null else try parseDigest(record.index_base);

    const entries = try arena.alloc(git_commit.Entry, record.items.len);
    const paths = try arena.alloc([]const u8, record.items.len);
    for (record.items, entries, paths) |item, *slot, *path| {
        if (item.mode.len != 6) return error.CorruptIntent;
        for (item.mode) |c| if (!std.ascii.isDigit(c)) return error.CorruptIntent;
        if (item.blob.len != 0 and !isObjectId(item.blob)) return error.CorruptIntent;
        shadow.validateRelative(item.path) catch return error.CorruptIntent;
        slot.* = .{ .path = try arena.dupe(u8, item.path), .mode = item.mode[0..6].*, .blob = if (item.blob.len == 0) null else try arena.dupe(u8, item.blob) };
        path.* = slot.path;
    }
    const line = (try git_commit.lineage(gpa, io, root, record.commit, record.base, paths)) orelse return error.CorruptIntent;
    defer line.deinit(gpa);
    for (record.items, line.after) |item, after| {
        if (!std.mem.eql(u8, item.blob, after)) return error.CorruptIntent;
    }
    const now = try git_commit.standing(gpa, io, root, record.branch, record.commit, entries);
    defer now.deinit(gpa);

    var report: Report = .{};
    var published = false;
    const held = try git_commit.lockState(gpa, io, root, lock);
    if (held == .ours) {
        if (now.on_commit) {
            if (!try git_commit.publishIndex(gpa, io, root, lock)) {
                report.pending = 1;
                report.reason = index_not_published;
                return report;
            }
            published = true;
            if (disk.Step.stops(step)) return error.Crashed;
        } else try git_commit.releaseIndex(gpa, io, root, lock);
    }
    const indexed = try arena.dupe(bool, now.indexed);
    if (published) @memset(indexed, true);
    if (!published) {
        var behind: std.ArrayList(git_commit.Entry) = .empty;
        var marks: std.ArrayList(usize) = .empty;
        for (entries, now.wanted, now.indexed, 0..) |entry, wanted, has, i| {
            if (wanted and !has) {
                try behind.append(arena, entry);
                try marks.append(arena, i);
            }
        }
        if (behind.items.len != 0) {
            if (held == .foreign) {
                report.pending = 1;
                report.reason = index_locked;
                return report;
            }
            const untouched = untouched: {
                const base_digest = index_base orelse break :untouched false;
                const current = (try git_commit.indexDigest(gpa, io, root)) orelse break :untouched false;
                break :untouched std.mem.eql(u8, &current, &base_digest);
            };
            if (untouched) {
                git_commit.advanceIndex(gpa, io, root, behind.items, try indexPath(arena, dir, tag), index_base.?) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    report.pending = 1;
                    report.reason = if (err == error.IndexLocked) index_locked else index_not_updated;
                    return report;
                };
                for (marks.items) |i| indexed[i] = true;
                if (disk.Step.stops(step)) return error.Crashed;
            } else {
                for (behind.items) |entry| report.name(entry.path);
                report.left += behind.items.len;
                report.reason = index_changed;
            }
        }
    }

    for (record.items, now.wanted, indexed, line.base, 0..) |item, wanted, has, base_oid, i| {
        if (!wanted or !has) continue;
        const outcome = forwardOne(gpa, arena, io, root, dir, tag, base_oid, i, item) catch |err| {
            if (err == error.Crashed or err == error.OutOfMemory or err == error.CorruptIntent) return err;
            report.pending = 1;
            report.reason = file_not_written;
            return report;
        };
        switch (outcome) {
            .kept => {},
            .written => {
                report.written += 1;
                if (disk.Step.stops(step)) return error.Crashed;
            },
            .left => {
                report.left += 1;
                report.name(item.path);
                if (report.reason == null) report.reason = target_changed;
            },
        }
    }

    try removeFiles(arena, io, folder, tag);
    holding = false;
    release(folder, dir);
    if (now.any()) report.landed = 1 else report.dropped = 1;
    return report;
}

pub fn recoverAll(gpa: Allocator, io: std.Io, root: []const u8) !Report {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir_abs = try dirOf(arena, root);
    var total: Report = .{};
    var tags: std.ArrayList([]const u8) = .empty;
    const held = (try own_dir.hold(io, dir_abs, .existing)) orelse return total;
    var holding = true;
    defer if (holding) held.close();
    {
        var it = held.dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const tag = own_dir.tagOf(entry.name, &.{record_suffix}) orelse continue;
            try tags.append(arena, try arena.dupe(u8, tag));
        }
    }
    for (tags.items) |tag| {
        const one = complete(gpa, io, root, tag, null) catch |err| {
            if (err == error.Crashed or err == error.OutOfMemory) return err;
            if (err == error.CorruptIntent) removeFiles(arena, io, held, tag) catch {};
            total.failed += 1;
            total.reason = @errorName(err);
            continue;
        };
        total.add(one);
    }
    if (total.pending == 0 and total.failed == 0) removeFiles(arena, io, held, null) catch {};
    holding = false;
    release(held, dir_abs);
    return total;
}
