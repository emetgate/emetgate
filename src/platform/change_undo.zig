const std = @import("std");
const symbol = @import("../engine/symbol.zig");
const disk = @import("disk.zig");
const shadow = @import("shadow.zig");
const receipts = @import("receipts.zig");
const own_dir = @import("own_dir.zig");

const Allocator = std.mem.Allocator;

const max_bytes = 64 << 20;

pub const Entry = struct {
    abs: []const u8,
    before: ?[]const u8,
};

pub const Snapshot = struct {
    root: []const u8,
    entries: []const Entry,
    receipts: []const []const u8,
};

pub fn take(arena: Allocator, io: std.Io, root: []const u8, files: []const []const u8) !Snapshot {
    var entries: std.ArrayList(Entry) = .empty;
    outer: for (files) |file| {
        const abs = try std.fs.path.resolve(arena, &.{ root, file });
        for (entries.items) |seen| if (std.ascii.eqlIgnoreCase(seen.abs, abs)) continue :outer;
        try entries.append(arena, .{ .abs = abs, .before = try readOrNull(arena, io, abs) });
    }
    return .{ .root = root, .entries = entries.items, .receipts = try receiptNames(arena, io, root) };
}

pub fn restore(gpa: Allocator, arena: Allocator, io: std.Io, snapshot: Snapshot) !void {
    var pendings: std.ArrayList(disk.Pending) = .empty;
    defer pendings.deinit(gpa);
    var staged = false;
    errdefer if (!staged) for (pendings.items) |*p| p.abandon();
    for (snapshot.entries) |entry| {
        const now = try readOrNull(arena, io, entry.abs);
        if (now == null and entry.before == null) continue;
        if (now != null and entry.before != null and std.mem.eql(u8, now.?, entry.before.?)) continue;
        const pending = if (entry.before) |bytes|
            (if (now) |current| try disk.prepare(gpa, io, entry.abs, bytes, symbol.fileHash(current)) else try disk.stageCreate(gpa, io, entry.abs, bytes))
        else
            try disk.stageDelete(gpa, io, entry.abs, symbol.fileHash(now.?));
        try pendings.append(gpa, pending);
    }
    if (pendings.items.len != 0) {
        const journal_dir = try std.fmt.allocPrint(arena, "{s}\\{s}\\journal", .{ snapshot.root, shadow.workspace_dir });
        var batch = disk.Batch.init(gpa, io, journal_dir);
        batch.root = snapshot.root;
        staged = true;
        try disk.commitBatch(pendings.items, null, null, &batch, null);
    }
    try dropNewReceipts(arena, io, snapshot);
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
