const std = @import("std");
const ledger_mod = @import("ledger.zig");
const wrap = @import("wrap.zig");

const Allocator = std.mem.Allocator;
const Ledger = ledger_mod.Ledger;
const Handle = ledger_mod.Handle;
const Hash = ledger_mod.Hash;

pub const Threshold = struct {
    max_chars: usize = 1200,
    head_chars: usize = 700,
};

pub const Outcome = struct {
    text: []u8,
    compacted: bool,
    handle: ?Handle,
};

pub fn compact(
    gpa: Allocator,
    ledger: *Ledger,
    tool_name: []const u8,
    args_json: []const u8,
    result_text: []const u8,
    is_error: bool,
    merkle_root: Hash,
    threshold: Threshold,
) !Outcome {
    if (is_error or result_text.len <= threshold.max_chars) {
        return .{ .text = try gpa.dupe(u8, result_text), .compacted = false, .handle = null };
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const claim = try wrap.claim(arena, tool_name, result_text, is_error);
    const tgts = try wrap.targets(arena, args_json);
    ledger.tick();
    const handle = try ledger.register(.{
        .claim = claim,
        .body = result_text,
        .merkle_root = merkle_root,
        .targets = tgts,
        .tool_use_id = "",
        .msg_index = 0,
    });

    const head = headOf(result_text, threshold.head_chars);
    const hidden = result_text.len - head.len;
    const text = try std.fmt.allocPrint(gpa, "{s}\n\u{2026} +{d} chars collapsed \u{00B7} emetgate_expand {{\"handle\":\"{s}\"}}\n", .{ head, hidden, &handle });
    return .{ .text = text, .compacted = true, .handle = handle };
}

pub const Expansion = struct {
    text: []u8,
    found: bool,
    stale: bool,
};

pub fn expand(gpa: Allocator, ledger: *Ledger, handle_text: []const u8, current_root: Hash) Allocator.Error!Expansion {
    const clean = if (handle_text.len != 0 and handle_text[0] == '#') handle_text[1..] else handle_text;
    if (clean.len != ledger_mod.handle_len) {
        return .{ .text = try gpa.dupe(u8, "expand: malformed handle; copy the exact handle from the collapsed line"), .found = false, .stale = false };
    }
    var handle: Handle = undefined;
    @memcpy(&handle, clean[0..ledger_mod.handle_len]);
    const got = ledger.expand(handle, current_root) orelse {
        return .{ .text = try gpa.dupe(u8, "expand: unknown handle; it may be from an earlier server run, re-run the original tool"), .found = false, .stale = false };
    };
    const stale = got.state == .stale;
    if (stale) {
        return .{ .text = try std.fmt.allocPrint(gpa, "(stale: the file changed since this was captured; re-run the tool for the current version)\n{s}", .{got.body}), .found = true, .stale = true };
    }
    return .{ .text = try gpa.dupe(u8, got.body), .found = true, .stale = false };
}

fn headOf(text: []const u8, limit: usize) []const u8 {
    if (text.len <= limit) return text;
    var end = limit;
    if (std.mem.lastIndexOfScalar(u8, text[0..limit], '\n')) |nl| {
        if (nl > limit / 2) end = nl;
    }
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

const testing = std.testing;

fn root(tag: []const u8) Hash {
    return @import("../engine/symbol.zig").hashOf(tag);
}

test "a small result passes through unchanged and stores nothing" {
    var l: Ledger = .init(testing.allocator);
    defer l.deinit();
    const out = try compact(testing.allocator, &l, "emetgate_read_symbol", "{\"file\":\"a.zig\"}", "short body", false, root("r1"), .{});
    defer testing.allocator.free(out.text);
    try testing.expect(!out.compacted);
    try testing.expectEqualStrings("short body", out.text);
    try testing.expectEqual(@as(usize, 0), l.entries.items.len);
}

test "an error passes through even when large" {
    var l: Ledger = .init(testing.allocator);
    defer l.deinit();
    const big = "E" ** 5000;
    const out = try compact(testing.allocator, &l, "emetgate_try", "{}", big, true, root("r1"), .{});
    defer testing.allocator.free(out.text);
    try testing.expect(!out.compacted);
    try testing.expectEqual(@as(usize, 0), l.entries.items.len);
}

test "a large result is compacted to a head plus an expand handle and the body is stored" {
    var l: Ledger = .init(testing.allocator);
    defer l.deinit();
    const big = "line\n" ** 2000;
    const out = try compact(testing.allocator, &l, "emetgate_search", "{\"pattern\":\"x\"}", big, false, root("r1"), .{});
    defer testing.allocator.free(out.text);
    try testing.expect(out.compacted);
    try testing.expect(out.text.len < big.len);
    try testing.expect(std.mem.indexOf(u8, out.text, "emetgate_expand") != null);
    try testing.expect(std.mem.indexOf(u8, out.text, &out.handle.?) != null);
    try testing.expectEqual(@as(usize, 1), l.entries.items.len);
}

test "expand returns the stored body fresh, and flags stale when the root changed" {
    var l: Ledger = .init(testing.allocator);
    defer l.deinit();
    const big = "data " ** 1000;
    const out = try compact(testing.allocator, &l, "emetgate_search", "{\"file\":\"a.zig\"}", big, false, root("r1"), .{});
    defer testing.allocator.free(out.text);

    var hbuf: [ledger_mod.handle_len]u8 = out.handle.?;
    const fresh = try expand(testing.allocator, &l, &hbuf, root("r1"));
    defer testing.allocator.free(fresh.text);
    try testing.expect(fresh.found and !fresh.stale);
    try testing.expectEqualStrings(big, fresh.text);

    const stale = try expand(testing.allocator, &l, &hbuf, root("r2"));
    defer testing.allocator.free(stale.text);
    try testing.expect(stale.found and stale.stale);
    try testing.expect(std.mem.indexOf(u8, stale.text, "stale") != null);
}

test "expand of an unknown or malformed handle is a helpful message, not a crash" {
    var l: Ledger = .init(testing.allocator);
    defer l.deinit();
    const unknown = try expand(testing.allocator, &l, "abcdef012345", root("r1"));
    defer testing.allocator.free(unknown.text);
    try testing.expect(!unknown.found);

    const malformed = try expand(testing.allocator, &l, "xyz", root("r1"));
    defer testing.allocator.free(malformed.text);
    try testing.expect(!malformed.found);
    try testing.expect(std.mem.indexOf(u8, malformed.text, "malformed") != null);
}
