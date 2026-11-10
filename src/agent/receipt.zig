const std = @import("std");
const api = @import("api.zig");
const ledger_mod = @import("ledger.zig");
const evict = @import("evict.zig");
const rewrite = @import("rewrite.zig");

const Allocator = std.mem.Allocator;
const Ledger = ledger_mod.Ledger;
const Entry = ledger_mod.Entry;
const Target = ledger_mod.Target;

pub const Session = struct {
    gpa: Allocator,
    ledger: Ledger,
    canonical: std.ArrayList(api.Message) = .empty,
    arena_state: std.heap.ArenaAllocator,
    policy: evict.Policy = .{},
    scratch: std.ArrayList(*Entry) = .empty,

    pub fn init(gpa: Allocator, policy: evict.Policy) Session {
        return .{ .gpa = gpa, .ledger = .init(gpa), .arena_state = std.heap.ArenaAllocator.init(gpa), .policy = policy };
    }

    pub fn deinit(self: *Session) void {
        self.scratch.deinit(self.gpa);
        self.canonical.deinit(self.gpa);
        self.arena_state.deinit();
        self.ledger.deinit();
        self.* = undefined;
    }

    pub const Result = struct {
        tool_use_id: []const u8,
        claim: []const u8,
        body: []const u8,
        body_tokens: ?usize = null,
        targets: []const Target = &.{},
        merkle_root: ledger_mod.Hash,
    };

    pub fn record(self: *Session, result: Result) Allocator.Error!ledger_mod.Handle {
        self.ledger.tick();
        const handle = try self.ledger.register(.{
            .claim = result.claim,
            .body = result.body,
            .body_tokens = result.body_tokens,
            .merkle_root = result.merkle_root,
            .targets = result.targets,
            .tool_use_id = result.tool_use_id,
            .msg_index = self.canonical.items.len,
        });
        const entry = &self.ledger.entries.items[self.ledger.entries.items.len - 1];
        const arena = self.arena_state.allocator();
        const blocks = try arena.alloc(api.ContentBlock, 1);
        blocks[0] = .{ .tool_result = .{ .tool_use_id = entry.tool_use_id, .content = entry.body } };
        try self.canonical.append(self.gpa, .{ .role = .user, .content = blocks });
        return handle;
    }

    pub const Advance = struct { collapsed: usize, freed: usize, resident_after: usize };

    pub fn advance(self: *Session, active: []const Target) Allocator.Error!Advance {
        const plan = try evict.plan(&self.ledger, active, self.policy, &self.scratch);
        for (plan.collapse) |entry| Ledger.collapse(entry);
        return .{ .collapsed = plan.collapse.len, .freed = plan.freed, .resident_after = self.ledger.residentTokens() };
    }

    pub fn sendView(self: *Session, arena: Allocator) Allocator.Error!rewrite.Projected {
        return rewrite.project(arena, self.canonical.items, &self.ledger);
    }

    pub fn residentTokens(self: *Session) usize {
        return self.ledger.residentTokens();
    }
};

const testing = std.testing;

fn root(tag: []const u8) ledger_mod.Hash {
    return @import("../engine/symbol.zig").hashOf(tag);
}

test "the send view matches ledger resident state block for block" {
    var s: Session = .init(testing.allocator, .{ .trigger_tokens = 1500, .clear_at_least = 900, .keep_recent = 1 });
    defer s.deinit();
    var buf: [8]u8 = undefined;
    var fbuf: [8]u8 = undefined;
    for (0..4) |i| {
        const tu = try std.fmt.bufPrint(&buf, "tu_{d}", .{i});
        const file = try std.fmt.bufPrint(&fbuf, "f{d}.zig", .{i});
        _ = try s.record(.{ .tool_use_id = tu, .claim = "search", .body = "b" ** 4000, .body_tokens = 1000, .targets = &.{.{ .file = file }}, .merkle_root = root("r1") });
    }
    _ = try s.advance(&.{.{ .file = "f3.zig" }});

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const view = try s.sendView(arena_state.allocator());
    var collapsed_in_view: usize = 0;
    for (view.messages) |m| {
        for (m.content) |b| {
            switch (b) {
                .tool_result => |tr| {
                    if (std.mem.startsWith(u8, tr.content, "[collapsed #")) collapsed_in_view += 1;
                },
                else => {},
            }
        }
    }
    var collapsed_in_ledger: usize = 0;
    for (s.ledger.entries.items) |e| {
        if (e.state == .collapsed) collapsed_in_ledger += 1;
    }
    try testing.expectEqual(collapsed_in_ledger, collapsed_in_view);
    try testing.expect(collapsed_in_view > 0);
}

test "receipt model keeps the resident-token integral far below the keep-all baseline" {
    const turns: usize = 20;
    const body_tokens: usize = 1000;

    var baseline: Session = .init(testing.allocator, .{ .trigger_tokens = std.math.maxInt(usize) });
    defer baseline.deinit();
    var receipt: Session = .init(testing.allocator, .{ .trigger_tokens = 3000, .clear_at_least = 2000, .keep_recent = 2 });
    defer receipt.deinit();

    var baseline_integral: usize = 0;
    var receipt_integral: usize = 0;
    var receipt_peak: usize = 0;
    var total_collapsed: usize = 0;

    var buf: [16]u8 = undefined;
    var fbuf: [16]u8 = undefined;
    for (0..turns) |i| {
        const tu = try std.fmt.bufPrint(&buf, "tu_{d}", .{i});
        const file = try std.fmt.bufPrint(&fbuf, "f{d}.zig", .{i});
        const result: Session.Result = .{ .tool_use_id = tu, .claim = "search 86 hits", .body = "x" ** 4000, .body_tokens = body_tokens, .targets = &.{.{ .file = file }}, .merkle_root = root("r1") };

        _ = try baseline.record(result);
        _ = try baseline.advance(&.{.{ .file = file }});
        baseline_integral += baseline.residentTokens();

        _ = try receipt.record(result);
        const adv = try receipt.advance(&.{.{ .file = file }});
        total_collapsed += adv.collapsed;
        const resident = receipt.residentTokens();
        receipt_integral += resident;
        receipt_peak = @max(receipt_peak, resident);
    }

    try testing.expect(total_collapsed > 0);
    try testing.expect(receipt_integral * 2 < baseline_integral);
    try testing.expect(receipt_peak < turns * body_tokens / 2);

    std.debug.print("\nintegral: baseline={d} receipt={d} (x{d:.1} smaller), receipt peak={d}t, collapses={d}\n", .{
        baseline_integral,
        receipt_integral,
        @as(f64, @floatFromInt(baseline_integral)) / @as(f64, @floatFromInt(receipt_integral)),
        receipt_peak,
        total_collapsed,
    });
}
