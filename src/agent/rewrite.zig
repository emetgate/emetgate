const std = @import("std");
const api = @import("api.zig");
const ledger_mod = @import("ledger.zig");

const Allocator = std.mem.Allocator;
const Ledger = ledger_mod.Ledger;
const Entry = ledger_mod.Entry;

pub const Projected = struct {
    messages: []api.Message,
    freed_tokens: usize,
    collapsed: usize,
};

pub fn project(arena: Allocator, canonical: []const api.Message, ledger: *Ledger) Allocator.Error!Projected {
    const out = try arena.alloc(api.Message, canonical.len);
    var freed: usize = 0;
    var collapsed: usize = 0;
    for (canonical, out) |msg, *slot| {
        if (!needsRewrite(msg, ledger)) {
            slot.* = msg;
            continue;
        }
        const blocks = try arena.alloc(api.ContentBlock, msg.content.len);
        for (msg.content, blocks) |block, *b| {
            switch (block) {
                .tool_result => |tr| {
                    if (collapsedEntry(ledger, tr.tool_use_id)) |entry| {
                        const ph = try entry.placeholder(arena);
                        freed += entry.body_tokens -| entry.residentTokens();
                        collapsed += 1;
                        b.* = .{ .tool_result = .{ .tool_use_id = tr.tool_use_id, .content = ph, .is_error = tr.is_error } };
                    } else b.* = block;
                },
                else => b.* = block,
            }
        }
        slot.* = .{ .role = msg.role, .content = blocks };
    }
    return .{ .messages = out, .freed_tokens = freed, .collapsed = collapsed };
}

fn needsRewrite(msg: api.Message, ledger: *Ledger) bool {
    for (msg.content) |block| {
        switch (block) {
            .tool_result => |tr| {
                if (collapsedEntry(ledger, tr.tool_use_id) != null) return true;
            },
            else => {},
        }
    }
    return false;
}

fn collapsedEntry(ledger: *Ledger, tool_use_id: []const u8) ?*Entry {
    if (tool_use_id.len == 0) return null;
    for (ledger.entries.items) |*e| {
        if (e.state == .collapsed and std.mem.eql(u8, e.tool_use_id, tool_use_id)) return e;
    }
    return null;
}

const testing = std.testing;

fn root(tag: []const u8) ledger_mod.Hash {
    return @import("../engine/symbol.zig").hashOf(tag);
}

test "a collapsed entry's tool_result becomes its placeholder, other blocks untouched" {
    var l: Ledger = .init(testing.allocator);
    defer l.deinit();
    const body = "search body " ** 400;
    const h = try l.register(.{ .claim = "search 86 hits", .body = body, .tool_use_id = "tu_1", .merkle_root = root("r1"), .msg_index = 0 });
    Ledger.collapse(l.find(h).?);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const canonical = [_]api.Message{
        .{ .role = .user, .content = &.{.{ .tool_result = .{ .tool_use_id = "tu_1", .content = body } }} },
        .{ .role = .assistant, .content = &.{.{ .text = "thinking" }} },
    };
    const projected = try project(arena, &canonical, &l);

    const want = try l.find(h).?.placeholder(arena);
    try testing.expectEqualStrings(want, projected.messages[0].content[0].tool_result.content);
    try testing.expectEqualStrings("thinking", projected.messages[1].content[0].text);
    try testing.expectEqual(@as(usize, 1), projected.collapsed);
    try testing.expect(projected.freed_tokens > 0);
}

test "a live entry is left at full size" {
    var l: Ledger = .init(testing.allocator);
    defer l.deinit();
    const body = "full body text here";
    _ = try l.register(.{ .claim = "c", .body = body, .tool_use_id = "tu_1", .merkle_root = root("r1"), .msg_index = 0 });

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const canonical = [_]api.Message{
        .{ .role = .user, .content = &.{.{ .tool_result = .{ .tool_use_id = "tu_1", .content = body } }} },
    };
    const projected = try project(arena, &canonical, &l);
    try testing.expectEqualStrings(body, projected.messages[0].content[0].tool_result.content);
    try testing.expectEqual(@as(usize, 0), projected.collapsed);
}

test "text and tool_use blocks are never rewritten" {
    var l: Ledger = .init(testing.allocator);
    defer l.deinit();
    const h = try l.register(.{ .claim = "c", .body = "b" ** 100, .tool_use_id = "tu_9", .merkle_root = root("r1"), .msg_index = 0 });
    Ledger.collapse(l.find(h).?);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const canonical = [_]api.Message{
        .{ .role = .assistant, .content = &.{
            .{ .text = "let me search" },
            .{ .tool_use = .{ .id = "tu_9", .name = "emetgate_search", .input_json = "{\"pattern\":\"x\"}" } },
        } },
    };
    const projected = try project(arena, &canonical, &l);
    try testing.expectEqualStrings("let me search", projected.messages[0].content[0].text);
    try testing.expectEqualStrings("tu_9", projected.messages[0].content[1].tool_use.id);
    try testing.expectEqual(@as(usize, 0), projected.collapsed);
}

test "projection is deterministic across runs" {
    var l: Ledger = .init(testing.allocator);
    defer l.deinit();
    const body = "z" ** 500;
    const h = try l.register(.{ .claim = "fold", .body = body, .tool_use_id = "tu_1", .merkle_root = root("r1"), .msg_index = 0 });
    Ledger.collapse(l.find(h).?);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const canonical = [_]api.Message{
        .{ .role = .user, .content = &.{.{ .tool_result = .{ .tool_use_id = "tu_1", .content = body } }} },
    };
    const a = try project(arena, &canonical, &l);
    const b = try project(arena, &canonical, &l);
    try testing.expectEqualStrings(a.messages[0].content[0].tool_result.content, b.messages[0].content[0].tool_result.content);
}
