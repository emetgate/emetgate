const std = @import("std");
const facts = @import("facts.zig");
const facts_store = @import("facts_store.zig");
const map = @import("map.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Store = facts_store.Store;
const FileState = facts_store.FileState;
const none = facts.none;

pub const max_chars: usize = 2_000;

pub const Change = enum { added, removed, changed };

pub const SymbolChange = struct {
    change: Change,
    region: ?map.RegionId,
    path: []const u8,
    kind: facts.DefKind,
    qname: []const u8,
    line: u32,
};

pub const Delta = struct {
    unchanged: bool,
    files: u32,
    added: u32,
    removed: u32,
    changed: u32,
    changes: []const SymbolChange,
    text: []const u8,
    summarized: bool,
};

const Old = struct {
    snap: map.SymbolSnap,
    seen: bool = false,
};

const Differ = struct {
    arena: Allocator,
    m: *const map.Map,
    changes: std.ArrayList(SymbolChange) = .empty,
    files: u32 = 0,

    fn keyOf(self: *Differ, ordinals: *std.StringHashMapUnmanaged(u32), kind: facts.DefKind, qname: []const u8) ![]const u8 {
        const base = try std.fmt.allocPrint(self.arena, "{d}\x00{s}", .{ @intFromEnum(kind), qname });
        const entry = try ordinals.getOrPut(self.arena, base);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        const ordinal = entry.value_ptr.*;
        entry.value_ptr.* += 1;
        return std.fmt.allocPrint(self.arena, "{s}\x00{d}", .{ base, ordinal });
    }

    fn add(self: *Differ, change: Change, region: ?map.RegionId, path: []const u8, kind: facts.DefKind, qname: []const u8, line: u32) !void {
        try self.changes.append(self.arena, .{ .change = change, .region = region, .path = path, .kind = kind, .qname = qname, .line = line });
    }

    fn whole(self: *Differ, change: Change, region: ?map.RegionId, path: []const u8, old: []const map.SymbolSnap, state: ?*const FileState) !void {
        self.files += 1;
        if (state) |s| {
            if (s.status == .indexed) {
                for (s.facts.defs) |d| {
                    if (d.kind == .module) continue;
                    try self.add(change, region, path, d.kind, d.qname, d.line);
                }
            }
            return;
        }
        for (old) |o| try self.add(change, region, path, o.kind, o.qname, o.line);
    }

    fn file(self: *Differ, region: ?map.RegionId, path: []const u8, old: []const map.SymbolSnap, state: *const FileState) !void {
        self.files += 1;
        var ordinals: std.StringHashMapUnmanaged(u32) = .empty;
        var before: std.StringHashMapUnmanaged(*Old) = .empty;
        const olds = try self.arena.alloc(Old, old.len);
        for (old, olds) |o, *slot| {
            slot.* = .{ .snap = o };
            try before.put(self.arena, try self.keyOf(&ordinals, o.kind, o.qname), slot);
        }
        ordinals.clearRetainingCapacity();
        if (state.status == .indexed) {
            for (state.facts.defs) |d| {
                if (d.kind == .module) continue;
                const key = try self.keyOf(&ordinals, d.kind, d.qname);
                const prior = before.get(key) orelse {
                    try self.add(.added, region, path, d.kind, d.qname, d.line);
                    continue;
                };
                prior.seen = true;
                if (!std.mem.eql(u8, &prior.snap.hash, &d.hash)) try self.add(.changed, region, path, d.kind, d.qname, d.line);
            }
        }
        for (olds) |o| {
            if (!o.seen) try self.add(.removed, region, path, o.snap.kind, o.snap.qname, o.snap.line);
        }
    }
};

fn changeLess(_: void, a: SymbolChange, b: SymbolChange) bool {
    const ar = a.region orelse none;
    const br = b.region orelse none;
    if (ar != br) return ar < br;
    switch (std.mem.order(u8, a.path, b.path)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    if (a.line != b.line) return a.line < b.line;
    if (@intFromEnum(a.change) != @intFromEnum(b.change)) return @intFromEnum(a.change) < @intFromEnum(b.change);
    return std.mem.order(u8, a.qname, b.qname) == .lt;
}

fn sameGroup(a: SymbolChange, b: SymbolChange) bool {
    const ar = a.region orelse return b.region == null and std.mem.eql(u8, a.path, b.path);
    const br = b.region orelse return false;
    return ar == br;
}

fn mark(change: Change) u8 {
    return switch (change) {
        .added => '+',
        .removed => '-',
        .changed => '~',
    };
}

fn regionName(m: *const map.Map, region: ?map.RegionId, path: []const u8, buf: []u8) ![]const u8 {
    if (region) |r| return std.fmt.bufPrint(buf, "r{d} {s}", .{ r + 1, m.regions[r].path });
    return std.fmt.bufPrint(buf, "new file {s} (outside every region)", .{path});
}

fn detailed(arena: Allocator, m: *const map.Map, changes: []const SymbolChange, head: []const u8) ![]const u8 {
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll(head);
    var i: usize = 0;
    var buf: [1024]u8 = undefined;
    while (i < changes.len) {
        var j = i;
        while (j < changes.len and sameGroup(changes[i], changes[j])) j += 1;
        try w.print("{s}:", .{try regionName(m, changes[i].region, changes[i].path, &buf)});
        for (changes[i..j], 0..) |c, n| {
            try w.print("{s}{c}{s}", .{ if (n == 0) " " else ", ", mark(c.change), c.qname });
            if (c.change != .removed) try w.print(" {s}:{d}", .{ c.path, c.line });
        }
        try w.writeByte('\n');
        i = j;
    }
    return out.written();
}

fn summary(arena: Allocator, m: *const map.Map, changes: []const SymbolChange, head: []const u8) ![]const u8 {
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll(head);
    var i: usize = 0;
    var buf: [1024]u8 = undefined;
    var lines: std.ArrayList([]const u8) = .empty;
    while (i < changes.len) {
        var j = i;
        var counts = [_]u32{ 0, 0, 0 };
        while (j < changes.len and sameGroup(changes[i], changes[j])) : (j += 1) counts[@intFromEnum(changes[j].change)] += 1;
        const name = try regionName(m, changes[i].region, changes[i].path, &buf);
        const line = if (changes[i].region) |r|
            try std.fmt.allocPrint(arena, "{s}: +{d} -{d} ~{d}; read it with emetgate_region {{\"region\":\"r{d}\"}}\n", .{ name, counts[0], counts[1], counts[2], r + 1 })
        else
            try std.fmt.allocPrint(arena, "{s}: +{d} -{d} ~{d}\n", .{ name, counts[0], counts[1], counts[2] });
        try lines.append(arena, line);
        i = j;
    }
    var used = head.len;
    for (lines.items, 0..) |line, n| {
        const rest = lines.items.len - n;
        const tail_room: usize = if (rest > 1) 80 else 0;
        if (used + line.len + tail_room > max_chars) {
            try w.print("... {d} more changed regions not listed (delta limit {d} characters)\n", .{ rest, max_chars });
            return out.written();
        }
        try w.writeAll(line);
        used += line.len;
    }
    return out.written();
}

pub fn mapDelta(arena: Allocator, store: *const Store, m: *const map.Map) !Delta {
    const snap = &m.snapshot;
    if (std.mem.eql(u8, &store.root, &snap.store_root)) {
        return .{ .unchanged = true, .files = 0, .added = 0, .removed = 0, .changed = 0, .changes = &.{}, .text = "", .summarized = false };
    }
    var d: Differ = .{ .arena = arena, .m = m };
    const seen = try arena.alloc(bool, snap.files.len);
    @memset(seen, false);
    var by_path = false;
    for (store.files.items, 0..) |*state, id| {
        const k: u32 = if (id < snap.by_store_id.len) snap.by_store_id[id] else none;
        if (k != none and !std.mem.eql(u8, snap.files[k].path, state.path)) {
            by_path = true;
            break;
        }
    }
    for (store.files.items, 0..) |*state, id| {
        var k: u32 = none;
        if (by_path) {
            k = indexOfPath(snap.files, state.path) orelse none;
        } else if (id < snap.by_store_id.len) {
            k = snap.by_store_id[id];
        }
        if (k != none) seen[k] = true;
        if (state.status == .removed) {
            if (k != none) try d.whole(.removed, snap.files[k].region, snap.files[k].path, snap.files[k].symbols, null);
            continue;
        }
        if (k == none) {
            try d.whole(.added, m.regionOfPath(state.path), state.path, &.{}, state);
            continue;
        }
        const old = snap.files[k];
        if (old.status == state.status and std.mem.eql(u8, &old.content_hash, &state.content_hash)) continue;
        try d.file(old.region, old.path, old.symbols, state);
    }
    for (snap.files, seen) |f, was| {
        if (!was) try d.whole(.removed, f.region, f.path, f.symbols, null);
    }
    std.mem.sort(SymbolChange, d.changes.items, {}, changeLess);
    var counts = [_]u32{ 0, 0, 0 };
    for (d.changes.items) |c| counts[@intFromEnum(c.change)] += 1;
    if (d.files == 0) {
        return .{ .unchanged = true, .files = 0, .added = 0, .removed = 0, .changed = 0, .changes = &.{}, .text = "", .summarized = false };
    }
    const head = try std.fmt.allocPrint(arena, "Changes since the map: {d} files, +{d} -{d} ~{d} symbols (+ added, - removed, ~ changed)\n", .{ d.files, counts[0], counts[1], counts[2] });
    var text = try detailed(arena, m, d.changes.items, head);
    var summarized = false;
    if (text.len > max_chars) {
        text = try summary(arena, m, d.changes.items, head);
        summarized = true;
    }
    return .{
        .unchanged = false,
        .files = d.files,
        .added = counts[0],
        .removed = counts[1],
        .changed = counts[2],
        .changes = d.changes.items,
        .text = text,
        .summarized = summarized,
    };
}

fn indexOfPath(files: []const map.FileSnap, path: []const u8) ?u32 {
    var lo: usize = 0;
    var hi: usize = files.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, files[mid].path, path)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return @intCast(mid),
        }
    }
    return null;
}
