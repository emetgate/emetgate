const std = @import("std");
const shadow = @import("shadow.zig");
const own_dir = @import("own_dir.zig");

const Allocator = std.mem.Allocator;

pub const dir_name = "tests";
pub const file_name = "debt.json";
const max_ledger_bytes = 16 * 1024 * 1024;
pub const shown = 8;

pub const Ledger = struct {
    start: []const []const u8 = &.{},
    failing: []const []const u8 = &.{},
};

const max_roots = 32;
var started: [max_roots]u64 = undefined;
var started_len: usize = 0;
var started_next: usize = 0;
var started_lock: std.Io.Mutex = .init;

fn rootKey(root: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (root) |c| hasher.update(&.{if (c == '/') '\\' else std.ascii.toLower(c)});
    return hasher.final();
}

fn markStarted(io: std.Io, root: []const u8) bool {
    const key = rootKey(root);
    started_lock.lockUncancelable(io);
    defer started_lock.unlock(io);
    for (started[0..started_len]) |seen| if (seen == key) return false;
    if (started_len < max_roots) {
        started[started_len] = key;
        started_len += 1;
    } else {
        started[started_next] = key;
        started_next = (started_next + 1) % max_roots;
    }
    return true;
}

pub fn forget() void {
    started_len = 0;
    started_next = 0;
}

fn dirOf(arena: Allocator, root: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}\\{s}\\{s}", .{ root, shadow.workspace_dir, dir_name });
}

pub fn load(arena: Allocator, io: std.Io, root: []const u8) !?Ledger {
    const held = (try own_dir.hold(io, try dirOf(arena, root), .existing)) orelse return null;
    defer held.close();
    const bytes = held.dir.readFileAlloc(io, file_name, arena, .limited(max_ledger_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return null,
        else => |e| return e,
    };
    const parsed = std.json.parseFromSliceLeaky(Ledger, arena, bytes, .{ .ignore_unknown_fields = true }) catch return error.TestLedgerCorrupt;
    return parsed;
}

fn store(gpa: Allocator, io: std.Io, root: []const u8, ledger: Ledger) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const held = (try own_dir.hold(io, try dirOf(arena, root), .create)).?;
    defer held.close();
    var out: std.Io.Writer.Allocating = .init(arena);
    var js: std.json.Stringify = .{ .writer = &out.writer };
    try js.write(ledger);
    try held.dir.writeFile(io, .{ .sub_path = file_name, .data = out.written() });
}

pub fn begin(gpa: Allocator, io: std.Io, root: []const u8, failing: []const []const u8) !void {
    if (!markStarted(io, root)) return;
    try store(gpa, io, root, .{ .start = failing, .failing = failing });
}

pub fn record(gpa: Allocator, io: std.Io, root: []const u8, failing: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const start = if (try load(arena_state.allocator(), io, root)) |ledger| ledger.start else &.{};
    try store(gpa, io, root, .{ .start = start, .failing = failing });
}

pub fn startOf(arena: Allocator, io: std.Io, root: []const u8) ![]const []const u8 {
    const ledger = (try load(arena, io, root)) orelse return &.{};
    return ledger.start;
}

pub fn introduced(arena: Allocator, start: []const []const u8, failing: []const []const u8) ![]const []const u8 {
    var owed: std.ArrayList([]const u8) = .empty;
    for (failing) |id| {
        const known = for (start) |s| {
            if (std.mem.eql(u8, s, id)) break true;
        } else false;
        if (!known) try owed.append(arena, id);
    }
    return owed.items;
}

const Pending = struct {
    arena: std.heap.ArenaAllocator,
    root: []const u8,
    failing: []const []const u8,
};

threadlocal var pending: ?Pending = null;

pub fn stage(root: []const u8, failing: []const []const u8) void {
    drop();
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_state.allocator();
    const copied = copy(arena, root, failing) catch {
        arena_state.deinit();
        return;
    };
    pending = .{ .arena = arena_state, .root = copied.root, .failing = copied.failing };
}

fn copy(arena: Allocator, root: []const u8, failing: []const []const u8) !struct { root: []const u8, failing: []const []const u8 } {
    const ids = try arena.alloc([]const u8, failing.len);
    for (ids, failing) |*slot, id| slot.* = try arena.dupe(u8, id);
    return .{ .root = try arena.dupe(u8, root), .failing = ids };
}

pub fn drop() void {
    if (pending) |*p| p.arena.deinit();
    pending = null;
}

pub fn settle(gpa: Allocator, io: std.Io, root: []const u8) !void {
    const p = pending orelse return;
    defer drop();
    if (rootKey(p.root) != rootKey(root)) return;
    try record(gpa, io, root, p.failing);
}

pub fn summary(w: *std.Io.Writer, failing: []const []const u8, owed: usize) !void {
    if (owed == 0) {
        try w.print("{d} failing, all failing before this session, so emetgate_commit is not blocked: ", .{failing.len});
    } else {
        try w.print("{d} failing, {d} of them new this session; emetgate_commit is refused until those pass: ", .{ failing.len, owed });
    }
    try names(w, failing);
}

pub fn names(w: *std.Io.Writer, ids: []const []const u8) !void {
    for (ids[0..@min(ids.len, shown)], 0..) |id, i| {
        if (i != 0) try w.writeAll(", ");
        try w.writeAll(id);
    }
    if (ids.len > shown) try w.print(" +{d} more", .{ids.len - shown});
}

const testing = std.testing;

test "debt is what fails now and did not fail when the session started" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const start = [_][]const u8{ "old.py::a", "old.py::b" };
    try testing.expectEqual(@as(usize, 0), (try introduced(arena, &start, &.{"old.py::a"})).len);
    try testing.expectEqual(@as(usize, 0), (try introduced(arena, &start, &.{})).len);
    const owed = try introduced(arena, &start, &.{ "old.py::b", "new.py::c" });
    try testing.expectEqual(@as(usize, 1), owed.len);
    try testing.expectEqualStrings("new.py::c", owed[0]);
    try testing.expectEqual(@as(usize, 2), (try introduced(arena, &.{}, &start)).len);
}

test "the debt summary is bounded and says whether commit is refused" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const ids = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j" };
    try summary(&out.writer, &ids, 3);
    try testing.expectEqualStrings("10 failing, 3 of them new this session; emetgate_commit is refused until those pass: a, b, c, d, e, f, g, h +2 more", out.written());
    out.clearRetainingCapacity();
    try summary(&out.writer, ids[0..1], 0);
    try testing.expectEqualStrings("1 failing, all failing before this session, so emetgate_commit is not blocked: a", out.written());
}
