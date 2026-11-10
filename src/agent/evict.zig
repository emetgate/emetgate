const std = @import("std");
const ledger_mod = @import("ledger.zig");

const Allocator = std.mem.Allocator;
const Ledger = ledger_mod.Ledger;
const Entry = ledger_mod.Entry;
const Target = ledger_mod.Target;

pub const Policy = struct {
    trigger_tokens: usize = 60_000,
    clear_at_least: usize = 8_000,
    keep_recent: usize = 2,
};

pub const Plan = struct {
    collapse: []*Entry,
    freed: usize,
    resident_before: usize,

    pub fn triggered(self: Plan) bool {
        return self.collapse.len != 0;
    }
};

pub fn plan(ledger: *Ledger, active: []const Target, policy: Policy, out: *std.ArrayList(*Entry)) Allocator.Error!Plan {
    out.clearRetainingCapacity();
    const resident = ledger.residentTokens();
    if (resident < policy.trigger_tokens) {
        return .{ .collapse = out.items, .freed = 0, .resident_before = resident };
    }

    const keep_from = recentCutoff(ledger, policy.keep_recent);
    for (ledger.entries.items) |*entry| {
        if (entry.state != .live) continue;
        if (entry.call_index >= keep_from) continue;
        if (overlapsActive(entry.*, active)) continue;
        entry.state = .spent;
    }

    const freed = try ledger.selectForEviction(out, policy.clear_at_least);
    return .{ .collapse = out.items, .freed = freed, .resident_before = resident };
}

fn recentCutoff(ledger: *Ledger, keep_recent: usize) u32 {
    if (keep_recent == 0) return std.math.maxInt(u32);
    var max_call: u32 = 0;
    for (ledger.entries.items) |entry| max_call = @max(max_call, entry.call_index);
    const span: u32 = @intCast(@min(keep_recent, max_call + 1));
    return max_call + 1 - span;
}

fn overlapsActive(entry: Entry, active: []const Target) bool {
    for (entry.targets) |x| {
        for (active) |y| {
            if (std.mem.eql(u8, x.file, y.file)) {
                if (x.symbol.len == 0 or y.symbol.len == 0 or std.mem.eql(u8, x.symbol, y.symbol)) return true;
            }
        }
    }
    return false;
}

const testing = std.testing;

fn root(tag: []const u8) ledger_mod.Hash {
    return @import("../engine/symbol.zig").hashOf(tag);
}

fn bigBody(comptime c: u8) []const u8 {
    return &([_]u8{c} ** 40000);
}

test "under the trigger nothing is planned" {
    var l: Ledger = .init(testing.allocator);
    defer l.deinit();
    l.tick();
    _ = try l.register(.{ .claim = "a", .body = "small body", .merkle_root = root("r1"), .msg_index = 0 });
    var out: std.ArrayList(*Entry) = .empty;
    defer out.deinit(testing.allocator);
    const p = try plan(&l, &.{}, .{}, &out);
    try testing.expect(!p.triggered());
    try testing.expectEqual(@as(usize, 0), p.freed);
}

test "over the trigger, old non-active entries are collapsed until clear_at_least is met" {
    var l: Ledger = .init(testing.allocator);
    defer l.deinit();
    l.tick();
    _ = try l.register(.{ .claim = "old1", .body = bigBody('a'), .merkle_root = root("r1"), .targets = &.{.{ .file = "a.zig" }}, .msg_index = 0 });
    l.tick();
    _ = try l.register(.{ .claim = "old2", .body = bigBody('b'), .merkle_root = root("r1"), .targets = &.{.{ .file = "b.zig" }}, .msg_index = 1 });

    var out: std.ArrayList(*Entry) = .empty;
    defer out.deinit(testing.allocator);
    const p = try plan(&l, &.{}, .{ .trigger_tokens = 1000, .clear_at_least = 5000, .keep_recent = 0 }, &out);
    try testing.expect(p.triggered());
    try testing.expect(p.freed >= 5000);
}

test "the active target is never collapsed" {
    var l: Ledger = .init(testing.allocator);
    defer l.deinit();
    l.tick();
    const keep = try l.register(.{ .claim = "keep", .body = bigBody('a'), .merkle_root = root("r1"), .targets = &.{.{ .file = "keep.zig" }}, .msg_index = 0 });
    l.tick();
    _ = try l.register(.{ .claim = "drop", .body = bigBody('b'), .merkle_root = root("r1"), .targets = &.{.{ .file = "drop.zig" }}, .msg_index = 1 });

    var out: std.ArrayList(*Entry) = .empty;
    defer out.deinit(testing.allocator);
    const p = try plan(&l, &.{.{ .file = "keep.zig" }}, .{ .trigger_tokens = 1000, .clear_at_least = 1000, .keep_recent = 0 }, &out);
    try testing.expect(p.triggered());
    for (p.collapse) |e| try testing.expect(!std.mem.eql(u8, &e.handle, &keep));
    try testing.expectEqual(ledger_mod.State.live, l.find(keep).?.state);
}

test "keep_recent protects the newest entries from being marked spent" {
    var l: Ledger = .init(testing.allocator);
    defer l.deinit();
    l.tick();
    _ = try l.register(.{ .claim = "old", .body = bigBody('a'), .merkle_root = root("r1"), .targets = &.{.{ .file = "old.zig" }}, .msg_index = 0 });
    l.tick();
    const recent = try l.register(.{ .claim = "recent", .body = bigBody('b'), .merkle_root = root("r1"), .targets = &.{.{ .file = "recent.zig" }}, .msg_index = 1 });

    var out: std.ArrayList(*Entry) = .empty;
    defer out.deinit(testing.allocator);
    _ = try plan(&l, &.{}, .{ .trigger_tokens = 1000, .clear_at_least = 1000, .keep_recent = 1 }, &out);
    try testing.expectEqual(ledger_mod.State.live, l.find(recent).?.state);
}
