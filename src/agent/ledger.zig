const std = @import("std");
const symbol = @import("../engine/symbol.zig");

const Allocator = std.mem.Allocator;

pub const Hash = symbol.Hash;

pub const handle_len: usize = 12;
pub const Handle = [handle_len]u8;

pub fn handleOf(hash: Hash) Handle {
    const hex = symbol.formatHash(hash);
    return hex[0..handle_len].*;
}

pub const State = enum { live, spent, collapsed };

pub const Target = struct {
    file: []const u8,
    symbol: []const u8 = "",
};

pub const Entry = struct {
    handle: Handle,
    hash: Hash,
    claim: []const u8,
    body: []const u8,
    body_tokens: usize,
    merkle_root: Hash,
    targets: []const Target,
    tool_use_id: []const u8,
    call_index: u32,
    msg_index: usize,
    state: State,

    pub fn placeholder(self: Entry, gpa: Allocator) Allocator.Error![]u8 {
        return std.fmt.allocPrint(gpa, "[collapsed #{s} \u{00B7} {s} \u{00B7} emetgate_expand #{s}]", .{ &self.handle, self.claim, &self.handle });
    }

    pub fn residentTokens(self: Entry) usize {
        return switch (self.state) {
            .collapsed => estimateTokens(placeholderLen(self)),
            .live, .spent => self.body_tokens,
        };
    }
};

fn placeholderLen(entry: Entry) usize {
    return "[collapsed # \u{00B7}  \u{00B7} emetgate_expand #]".len + 2 * handle_len + entry.claim.len;
}

pub fn estimateTokens(chars: usize) usize {
    return (chars + 3) / 4;
}

pub const ExpandState = enum { fresh, stale };

pub const Expansion = struct {
    body: []const u8,
    state: ExpandState,
    handle: Handle,
};

pub const Ledger = struct {
    gpa: Allocator,
    entries: std.ArrayList(Entry) = .empty,
    calls: u32 = 0,

    pub fn init(gpa: Allocator) Ledger {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Ledger) void {
        for (self.entries.items) |entry| self.freeEntry(entry);
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    fn freeEntry(self: *Ledger, entry: Entry) void {
        self.gpa.free(entry.claim);
        self.gpa.free(entry.body);
        self.gpa.free(entry.tool_use_id);
        for (entry.targets) |t| {
            self.gpa.free(t.file);
            self.gpa.free(t.symbol);
        }
        self.gpa.free(entry.targets);
    }

    pub fn tick(self: *Ledger) void {
        self.calls +|= 1;
    }

    pub const Record = struct {
        claim: []const u8,
        body: []const u8,
        body_tokens: ?usize = null,
        merkle_root: Hash,
        targets: []const Target = &.{},
        tool_use_id: []const u8 = "",
        msg_index: usize,
    };

    pub fn register(self: *Ledger, record: Record) Allocator.Error!Handle {
        const hash = symbol.hashOf(record.body);
        const claim = try self.gpa.dupe(u8, record.claim);
        errdefer self.gpa.free(claim);
        const body = try self.gpa.dupe(u8, record.body);
        errdefer self.gpa.free(body);
        const tool_use_id = try self.gpa.dupe(u8, record.tool_use_id);
        errdefer self.gpa.free(tool_use_id);
        const targets = try self.gpa.alloc(Target, record.targets.len);
        var filled: usize = 0;
        errdefer {
            for (targets[0..filled]) |t| {
                self.gpa.free(t.file);
                self.gpa.free(t.symbol);
            }
            self.gpa.free(targets);
        }
        for (record.targets, targets) |src, *dst| {
            const file = try self.gpa.dupe(u8, src.file);
            errdefer self.gpa.free(file);
            const sym = try self.gpa.dupe(u8, src.symbol);
            dst.* = .{ .file = file, .symbol = sym };
            filled += 1;
        }
        const entry: Entry = .{
            .handle = handleOf(hash),
            .hash = hash,
            .claim = claim,
            .body = body,
            .body_tokens = record.body_tokens orelse estimateTokens(record.body.len),
            .merkle_root = record.merkle_root,
            .targets = targets,
            .tool_use_id = tool_use_id,
            .call_index = self.calls,
            .msg_index = record.msg_index,
            .state = .live,
        };
        try self.entries.append(self.gpa, entry);
        return entry.handle;
    }

    pub fn find(self: *Ledger, handle: Handle) ?*Entry {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, &entry.handle, &handle)) return entry;
        }
        return null;
    }

    pub fn touch(self: *Ledger, handle: Handle) void {
        if (self.find(handle)) |entry| {
            if (entry.state == .spent) entry.state = .live;
        }
    }

    pub fn markSpentExcept(self: *Ledger, active: []const Target) void {
        for (self.entries.items) |*entry| {
            if (entry.state != .live) continue;
            if (!overlaps(entry.targets, active)) entry.state = .spent;
        }
    }

    pub fn residentTokens(self: *Ledger) usize {
        var total: usize = 0;
        for (self.entries.items) |entry| total += entry.residentTokens();
        return total;
    }

    pub fn selectForEviction(self: *Ledger, out: *std.ArrayList(*Entry), free_at_least: usize) Allocator.Error!usize {
        out.clearRetainingCapacity();
        var freed: usize = 0;
        for (self.entries.items) |*entry| {
            if (entry.state != .spent) continue;
            const saving = entry.body_tokens -| estimateTokens(placeholderLen(entry.*));
            if (saving == 0) continue;
            try out.append(self.gpa, entry);
            freed += saving;
            if (freed >= free_at_least) break;
        }
        if (freed < free_at_least) {
            out.clearRetainingCapacity();
            return 0;
        }
        return freed;
    }

    pub fn collapse(entry: *Entry) void {
        entry.state = .collapsed;
    }

    pub fn expand(self: *Ledger, handle: Handle, current_root: Hash) ?Expansion {
        const entry = self.find(handle) orelse return null;
        const state: ExpandState = if (std.mem.eql(u8, &entry.merkle_root, &current_root)) .fresh else .stale;
        return .{ .body = entry.body, .state = state, .handle = handle };
    }
};

fn overlaps(a: []const Target, b: []const Target) bool {
    for (a) |x| {
        for (b) |y| {
            if (std.mem.eql(u8, x.file, y.file)) {
                if (x.symbol.len == 0 or y.symbol.len == 0 or std.mem.eql(u8, x.symbol, y.symbol)) return true;
            }
        }
    }
    return false;
}

const testing = std.testing;

fn root(tag: []const u8) Hash {
    return symbol.hashOf(tag);
}

test "register copies inputs, hashes the body into a handle, and starts live" {
    var ledger: Ledger = .init(testing.allocator);
    defer ledger.deinit();
    const h = try ledger.register(.{ .claim = "fold() verified", .body = "long body text", .merkle_root = root("r1"), .msg_index = 0 });
    const entry = ledger.find(h).?;
    try testing.expectEqual(State.live, entry.state);
    try testing.expectEqualStrings("fold() verified", entry.claim);
    try testing.expectEqualStrings("long body text", entry.body);
    try testing.expectEqual(handleOf(symbol.hashOf("long body text")), h);
}

test "identical bodies share a handle" {
    var ledger: Ledger = .init(testing.allocator);
    defer ledger.deinit();
    const a = try ledger.register(.{ .claim = "x", .body = "same", .merkle_root = root("r1"), .msg_index = 0 });
    const b = try ledger.register(.{ .claim = "y", .body = "same", .merkle_root = root("r1"), .msg_index = 1 });
    try testing.expectEqual(a, b);
}

test "placeholder is deterministic and smaller than the body it replaces" {
    var ledger: Ledger = .init(testing.allocator);
    defer ledger.deinit();
    const big = "x" ** 4000;
    const h = try ledger.register(.{ .claim = "search 86 hits", .body = big, .merkle_root = root("r1"), .msg_index = 0 });
    const entry = ledger.find(h).?;
    const p1 = try entry.placeholder(testing.allocator);
    defer testing.allocator.free(p1);
    const p2 = try entry.placeholder(testing.allocator);
    defer testing.allocator.free(p2);
    try testing.expectEqualStrings(p1, p2);
    try testing.expect(p1.len < big.len);
    try testing.expect(std.mem.indexOf(u8, p1, &h) != null);
}

test "markSpentExcept keeps entries whose target is still active" {
    var ledger: Ledger = .init(testing.allocator);
    defer ledger.deinit();
    const keep = try ledger.register(.{ .claim = "a", .body = "A", .merkle_root = root("r1"), .targets = &.{.{ .file = "a.zig", .symbol = "foo" }}, .msg_index = 0 });
    const drop = try ledger.register(.{ .claim = "b", .body = "B", .merkle_root = root("r1"), .targets = &.{.{ .file = "b.zig", .symbol = "bar" }}, .msg_index = 1 });
    ledger.markSpentExcept(&.{.{ .file = "a.zig" }});
    try testing.expectEqual(State.live, ledger.find(keep).?.state);
    try testing.expectEqual(State.spent, ledger.find(drop).?.state);
}

test "selectForEviction takes oldest spent first until the saving is met, else nothing" {
    var ledger: Ledger = .init(testing.allocator);
    defer ledger.deinit();
    _ = try ledger.register(.{ .claim = "a", .body = "a" ** 800, .merkle_root = root("r1"), .msg_index = 0 });
    _ = try ledger.register(.{ .claim = "b", .body = "b" ** 800, .merkle_root = root("r1"), .msg_index = 1 });
    ledger.markSpentExcept(&.{});
    var chosen: std.ArrayList(*Entry) = .empty;
    defer chosen.deinit(testing.allocator);

    const freed = try ledger.selectForEviction(&chosen, 150);
    try testing.expect(freed >= 150);
    try testing.expectEqual(@as(usize, 1), chosen.items.len);

    const impossible = try ledger.selectForEviction(&chosen, 1_000_000);
    try testing.expectEqual(@as(usize, 0), impossible);
    try testing.expectEqual(@as(usize, 0), chosen.items.len);
}

test "collapse shrinks resident tokens; expand serves the body fresh without un-collapsing" {
    var ledger: Ledger = .init(testing.allocator);
    defer ledger.deinit();
    const h = try ledger.register(.{ .claim = "fold", .body = "z" ** 2000, .merkle_root = root("r1"), .msg_index = 0 });
    const before = ledger.residentTokens();
    ledger.find(h).?.state = .spent;
    Ledger.collapse(ledger.find(h).?);
    try testing.expect(ledger.residentTokens() < before);

    const fresh = ledger.expand(h, root("r1")).?;
    try testing.expectEqual(ExpandState.fresh, fresh.state);
    try testing.expectEqualStrings("z" ** 2000, fresh.body);
    try testing.expectEqual(State.collapsed, ledger.find(h).?.state);

    const stale = ledger.expand(h, root("r2")).?;
    try testing.expectEqual(ExpandState.stale, stale.state);
}

test "expand of an unknown handle is null" {
    var ledger: Ledger = .init(testing.allocator);
    defer ledger.deinit();
    try testing.expect(ledger.expand(handleOf(root("nope")), root("r1")) == null);
}
