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

    pub fn add(self: *Report, other: Report) void {
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

fn forwardOne(gpa: Allocator, arena: Allocator, io: std.Io, root: []const u8, dir: []const u8, tag: []const u8, base_commit: []const u8, index: usize, item: Item) !Forward {
    try shadow.validateRelative(item.path);
    const abs = try std.fmt.allocPrint(arena, "{s}\\{s}", .{ root, item.path });
    std.mem.replaceScalar(u8, abs, '/', '\\');
    const base = try optionalHash(item.base);
    const new = try optionalHash(item.new);
    const now = try hashAt(gpa, io, abs);
    if (same(now, new)) return .kept;
    if (!same(now, base)) return .left;
    const journal_dir = try std.fmt.allocPrint(arena, "{s}\\{s}\\journal", .{ root, shadow.workspace_dir });

    if (new == null) {
        const before = (try git_commit.blobAt(gpa, io, root, base_commit, item.path)) orelse return error.CorruptIntent;
        defer gpa.free(before);
        if (!try git_commit.storesAs(gpa, io, root, item.path, abs, before)) return error.CorruptIntent;
        var pendings = [1]disk.Pending{try disk.stageDelete(gpa, io, abs, base.?)};
        try disk.commitBatch(&pendings, null, null, null, null);
        return .written;
    }
    const staged = try stagedPath(arena, dir, tag, index);
    const bytes = try Dir.cwd().readFileAlloc(io, staged, arena, .limited(max_staged_bytes));
    if (!std.mem.eql(u8, &symbol.hashOf(bytes), &new.?)) return error.CorruptIntent;
    if (!try git_commit.storesAs(gpa, io, root, item.path, staged, item.blob)) return error.CorruptIntent;
    if (base) |expected| {
        try disk.replaceReporting(gpa, io, abs, bytes, expected, null, journal_dir, null);
        return .written;
    }
    if (std.fs.path.dirname(abs)) |parent| try Dir.cwd().createDirPath(io, parent);
    disk.create(gpa, io, abs, bytes) catch |err| switch (err) {
        error.FileExists => return .left,
        else => |e| return e,
    };
    return .written;
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

    const entries = try arena.alloc(git_commit.Entry, record.items.len);
    for (record.items, entries) |item, *slot| {
        if (item.mode.len != 6) return error.CorruptIntent;
        for (item.mode) |c| if (!std.ascii.isDigit(c)) return error.CorruptIntent;
        if (item.blob.len != 0 and !isObjectId(item.blob)) return error.CorruptIntent;
        slot.* = .{ .path = try arena.dupe(u8, item.path), .mode = item.mode[0..6].*, .blob = if (item.blob.len == 0) null else try arena.dupe(u8, item.blob) };
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
    if (!published) {
        var behind: std.ArrayList(git_commit.Entry) = .empty;
        for (entries, now.wanted, now.indexed) |entry, wanted, indexed| {
            if (wanted and !indexed) try behind.append(arena, entry);
        }
        if (behind.items.len != 0) {
            if (held == .foreign) {
                report.pending = 1;
                report.reason = index_locked;
                return report;
            }
            git_commit.updateIndex(gpa, io, root, behind.items) catch {
                report.pending = 1;
                report.reason = index_not_updated;
                return report;
            };
            if (disk.Step.stops(step)) return error.Crashed;
        }
    }

    for (record.items, now.wanted, 0..) |item, wanted, i| {
        if (!wanted) continue;
        const outcome = forwardOne(gpa, arena, io, root, dir, tag, record.base, i, item) catch |err| {
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
                report.reason = target_changed;
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
