const std = @import("std");
const builtin = @import("builtin");
const git_commit = @import("git_commit.zig");
const gate_tree = @import("gate_tree.zig");
const dir_scan = @import("dir_scan.zig");
const own_dir = @import("own_dir.zig");
const shadow = @import("shadow.zig");
const worker_pool = @import("worker_pool.zig");
const commit_record = @import("commit_record.zig");

const Allocator = std.mem.Allocator;
const refuseLinks = shadow.ensureNoLinks;
const Dir = std.Io.Dir;

pub const tree_name = "tree";
pub const state_name = "state";
const state_new = "state.new";
const attributes_name = ".gitattributes";
const max_state_bytes = 512;

pub const Built = enum { kept, updated, rebuilt };

pub const Store = struct {
    dir: []const u8,
    count: usize,
    built: Built = .kept,
};

pub const Error = error{ CommittedTreeUnavailable, CommittedTreeIncomplete };

pub var crash_after_marking: bool = false;
pub var rebuilds: usize = 0;

const Held = struct {
    tree: []const u8,
    count: usize,
};

const State = union(enum) {
    none,
    ready: struct { tree: []const u8, conversion: []const u8, count: usize },
    moving: struct { from: []const u8, to: []const u8, conversion: []const u8, count: usize },
};

fn readState(arena: Allocator, io: std.Io, dir_abs: []const u8) !State {
    var dir = try Dir.openDirAbsolute(io, dir_abs, .{});
    defer dir.close(io);
    const text = dir.readFileAlloc(io, state_name, arena, .limited(max_state_bytes)) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => return .none,
        else => |e| return e,
    };
    if (text.len == 0 or text[text.len - 1] != '\n') return .none;
    var fields = std.mem.tokenizeScalar(u8, text[0 .. text.len - 1], ' ');
    const kind = fields.next() orelse return .none;
    if (std.mem.eql(u8, kind, "ready")) {
        const tree = fields.next() orelse return .none;
        const conversion = fields.next() orelse return .none;
        const count = std.fmt.parseInt(usize, fields.next() orelse return .none, 10) catch return .none;
        if (fields.next() != null) return .none;
        return .{ .ready = .{ .tree = tree, .conversion = conversion, .count = count } };
    }
    if (std.mem.eql(u8, kind, "moving")) {
        const from = fields.next() orelse return .none;
        const to = fields.next() orelse return .none;
        const conversion = fields.next() orelse return .none;
        const count = std.fmt.parseInt(usize, fields.next() orelse return .none, 10) catch return .none;
        if (fields.next() != null) return .none;
        return .{ .moving = .{ .from = from, .to = to, .conversion = conversion, .count = count } };
    }
    return .none;
}

fn writeState(arena: Allocator, io: std.Io, dir_abs: []const u8, text: []const u8) !void {
    const fresh = try std.fs.path.join(arena, &.{ dir_abs, state_new });
    const final = try std.fs.path.join(arena, &.{ dir_abs, state_name });
    {
        var file = try Dir.cwd().createFile(io, fresh, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, text);
        try file.sync(io);
    }
    var from_wide: commit_record.WidePath = undefined;
    var to_wide: commit_record.WidePath = undefined;
    if (win.MoveFileExW(try commit_record.toWide(&from_wide, fresh), try commit_record.toWide(&to_wide, final), win.replace_existing | win.write_through) == .FALSE) return error.CommittedTreeUnavailable;
}

fn isAttributes(path: []const u8) bool {
    return std.mem.eql(u8, std.fs.path.basenamePosix(path), attributes_name);
}

fn removeStored(io: std.Io, tree_abs: []const u8, rel: []const u8) !void {
    var tree = try Dir.openDirAbsolute(io, tree_abs, .{});
    defer tree.close(io);
    tree.deleteFile(io, rel) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
    var parent = std.fs.path.dirnamePosix(rel);
    while (parent) |dir| : (parent = std.fs.path.dirnamePosix(dir)) {
        tree.deleteDir(io, dir) catch return;
    }
}

const Context = struct {
    gpa: Allocator,
    arena: Allocator,
    io: std.Io,
    root: []const u8,
    dir_abs: []const u8,
    tree_abs: []const u8,
    conversion: []const u8,

    fn move(self: Context, from: []const u8, to: []const u8, count: usize) !?usize {
        const changes = git_commit.treeChanges(self.arena, self.io, self.root, from, to) catch return null;
        var after = count;
        for (changes) |change| {
            if (isAttributes(change.path)) return null;
            if (change.was) {
                if (after == 0) return null;
                after -= 1;
            }
            if (change.now) after += 1;
        }
        try writeState(self.arena, self.io, self.dir_abs, try std.fmt.allocPrint(self.arena, "moving {s} {s} {s} {d}\n", .{ from, to, self.conversion, count }));
        if (builtin.is_test and crash_after_marking) return error.CommittedTreeUnavailable;
        var written: std.ArrayList([]const u8) = .empty;
        for (changes) |change| {
            try shadow.validateRelative(change.path);
            if (change.was) try removeStored(self.io, self.tree_abs, change.path);
            if (change.now) try written.append(self.arena, try std.fmt.allocPrint(self.arena, "{s}/{s}", .{ tree_name, change.path }));
        }
        git_commit.checkoutChanges(self.gpa, self.io, self.root, to, changes, self.tree_abs) catch return error.CommittedTreeUnavailable;
        const handle = (try dir_scan.openRoot(self.dir_abs)) orelse return error.CommittedTreeUnavailable;
        defer dir_scan.close(handle);
        gate_tree.flushFiles(null, handle, written.items) catch return error.CommittedTreeIncomplete;
        try self.ready(to, after);
        return after;
    }

    fn ready(self: Context, tree: []const u8, count: usize) !void {
        try writeState(self.arena, self.io, self.dir_abs, try std.fmt.allocPrint(self.arena, "ready {s} {s} {d}\n", .{ tree, self.conversion, count }));
    }

    fn rebuild(self: Context, tree: []const u8) !usize {
        if (builtin.is_test) rebuilds += 1;
        try writeState(self.arena, self.io, self.dir_abs, "building\n");
        const handle = (try dir_scan.openRoot(self.dir_abs)) orelse return error.CommittedTreeUnavailable;
        defer dir_scan.close(handle);
        {
            const inner = (try dir_scan.openRoot(self.tree_abs)) orelse return error.CommittedTreeUnavailable;
            defer dir_scan.close(inner);
            _ = try gate_tree.removeAll(inner);
        }
        const count = git_commit.checkoutTree(self.gpa, self.io, self.root, tree, self.tree_abs) catch return error.CommittedTreeUnavailable;
        var pool: worker_pool.Pool = undefined;
        pool.start(worker_pool.max_threads);
        defer pool.deinit();
        var wants: std.ArrayList(gate_tree.Want) = .empty;
        var found: gate_tree.Found = .{};
        try gate_tree.discover(self.arena, &pool, handle, 0, tree_name, &wants, &found);
        if (wants.items.len != count or found.skipped_links != 0) return error.CommittedTreeIncomplete;
        const rels = try self.arena.alloc([]const u8, wants.items.len);
        for (wants.items, rels) |want, *rel| rel.* = want.rel;
        gate_tree.flushFiles(&pool, handle, rels) catch return error.CommittedTreeIncomplete;
        try self.ready(tree, count);
        return count;
    }
};

pub fn ensure(gpa: Allocator, io: std.Io, root: []const u8, base_abs: []const u8, dir_abs: []const u8, head: git_commit.Head) !Store {
    if (builtin.os.tag != .windows) return error.Unsupported;
    try shadow.ensureInsideWorkspace(base_abs, dir_abs);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tree_abs = try std.fs.path.join(arena, &.{ dir_abs, tree_name });
    try refuseLinks(base_abs, tree_abs);
    try Dir.cwd().createDirPath(io, tree_abs);
    const held = (try own_dir.hold(io, dir_abs, .existing)) orelse return error.CommittedTreeUnavailable;
    defer held.close();

    const ctx: Context = .{ .gpa = gpa, .arena = arena, .io = io, .root = root, .dir_abs = dir_abs, .tree_abs = tree_abs, .conversion = &head.conversion };
    var have: ?Held = null;
    var built: Built = .kept;
    switch (try readState(arena, io, dir_abs)) {
        .none => {},
        .ready => |state| {
            if (std.mem.eql(u8, state.conversion, ctx.conversion)) have = .{ .tree = state.tree, .count = state.count };
        },
        .moving => |state| {
            if (std.mem.eql(u8, state.conversion, ctx.conversion)) {
                built = .updated;
                if (try ctx.move(state.from, state.to, state.count)) |count| have = .{ .tree = state.to, .count = count };
            }
        },
    }
    if (have) |known| {
        if (!std.mem.eql(u8, known.tree, head.tree)) {
            built = .updated;
            have = if (try ctx.move(known.tree, head.tree, known.count)) |count| .{ .tree = head.tree, .count = count } else null;
        }
    }
    const known = have orelse return .{ .dir = dir_abs, .count = try ctx.rebuild(head.tree), .built = .rebuilt };
    return .{ .dir = dir_abs, .count = known.count, .built = built };
}

pub fn invalidate(gpa: Allocator, io: std.Io, dir_abs: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    try writeState(arena_state.allocator(), io, dir_abs, "building\n");
}

const win = struct {
    const replace_existing: u32 = 0x1;
    const write_through: u32 = 0x8;

    extern "kernel32" fn MoveFileExW(from: [*:0]const u16, to: [*:0]const u16, flags: u32) callconv(.winapi) std.os.windows.BOOL;
};
