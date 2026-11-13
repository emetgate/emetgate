const std = @import("std");
const batch = @import("batch.zig");
const shadow = @import("shadow.zig");
const receipts = @import("receipts.zig");
const own_dir = @import("own_dir.zig");
const repo = @import("repo.zig");
const file_edit = @import("file_edit.zig");

const Allocator = std.mem.Allocator;

const max_bytes = 64 << 20;

pub const Entry = struct {
    abs: []const u8,
    rel: []const u8,
    before: ?[]const u8,
    index: []const u8,
};

pub const Snapshot = struct {
    root: []const u8,
    entries: []const Entry,
    created_dirs: []const []const u8,
    receipts: []const []const u8,
};

pub fn take(arena: Allocator, io: std.Io, root: []const u8, files: []const []const u8) !Snapshot {
    var entries: std.ArrayList(Entry) = .empty;
    var rels: std.ArrayList([]const u8) = .empty;
    var dirs: std.ArrayList([]const u8) = .empty;
    outer: for (files) |file| {
        const abs = try std.fs.path.resolve(arena, &.{ root, file });
        for (entries.items) |seen| if (std.ascii.eqlIgnoreCase(seen.abs, abs)) continue :outer;
        const rel = repo.relativeUnder(arena, root, abs) catch continue;
        std.mem.replaceScalar(u8, rel, '\\', '/');
        const before = try readOrNull(arena, io, abs);
        if (before == null) try newDirs(arena, io, root, file, &dirs);
        try entries.append(arena, .{ .abs = abs, .rel = rel, .before = before, .index = "" });
        try rels.append(arena, rel);
    }
    const index = try repo.indexEntriesOf(arena, io, root, rels.items);
    for (entries.items, index) |*entry, held| entry.index = held;
    return .{ .root = root, .entries = entries.items, .created_dirs = dirs.items, .receipts = try receiptNames(arena, io, root) };
}

fn newDirs(arena: Allocator, io: std.Io, root: []const u8, file: []const u8, dirs: *std.ArrayList([]const u8)) !void {
    const target = file_edit.jailWrite(arena, io, root, file, true) catch return;
    outer: for (target.created_dirs) |dir| {
        for (dirs.items) |have| if (std.ascii.eqlIgnoreCase(have, dir)) continue :outer;
        try dirs.append(arena, dir);
    }
}

pub fn restore(gpa: Allocator, arena: Allocator, io: std.Io, snapshot: Snapshot) ![]const []const u8 {
    var back: std.ArrayList(batch.Restore) = .empty;
    for (snapshot.entries) |entry| {
        const now = try readOrNull(arena, io, entry.abs);
        if (now == null and entry.before == null) continue;
        if (now != null and entry.before != null and std.mem.eql(u8, now.?, entry.before.?)) continue;
        try back.append(arena, .{ .abs = entry.abs, .rel = entry.rel, .now = now, .before = entry.before, .index = entry.index });
    }
    const unrestored = try batch.restore(gpa, arena, io, snapshot.root, back.items, snapshot.created_dirs);
    try dropNewReceipts(arena, io, snapshot);
    return unrestored;
}

fn readOrNull(arena: Allocator, io: std.Io, abs: []const u8) !?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, abs, arena, .limited(max_bytes)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| return e,
    };
}

fn receiptsDir(arena: Allocator, root: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena, "{s}\\{s}\\{s}", .{ root, shadow.workspace_dir, receipts.receipts_dir });
}

fn receiptNames(arena: Allocator, io: std.Io, root: []const u8) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    const held = (try own_dir.hold(io, try receiptsDir(arena, root), .existing)) orelse return names.items;
    defer held.close();
    var it = held.dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    return names.items;
}

fn dropNewReceipts(arena: Allocator, io: std.Io, snapshot: Snapshot) !void {
    const now = try receiptNames(arena, io, snapshot.root);
    if (now.len == 0) return;
    const held = (try own_dir.hold(io, try receiptsDir(arena, snapshot.root), .existing)) orelse return;
    defer held.close();
    outer: for (now) |name| {
        for (snapshot.receipts) |kept| if (std.mem.eql(u8, kept, name)) continue :outer;
        try held.dir.deleteFile(io, name);
    }
}
