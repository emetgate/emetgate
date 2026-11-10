const std = @import("std");
const ledger_mod = @import("ledger.zig");

const Allocator = std.mem.Allocator;
const Target = ledger_mod.Target;

pub const max_claim_tail: usize = 56;

pub fn claim(gpa: Allocator, tool_name: []const u8, result_text: []const u8, is_error: bool) Allocator.Error![]u8 {
    const status: []const u8 = if (is_error) "error" else "ok";
    const head = firstLine(result_text);
    const tail = clip(head, max_claim_tail);
    if (tail.len == 0) {
        return std.fmt.allocPrint(gpa, "{s} \u{00B7} {s} \u{00B7} {d} chars", .{ tool_name, status, result_text.len });
    }
    return std.fmt.allocPrint(gpa, "{s} \u{00B7} {s} \u{00B7} {s}", .{ tool_name, status, tail });
}

pub fn targets(arena: Allocator, input_json: []const u8) Allocator.Error![]Target {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, input_json, .{}) catch return &.{};
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return &.{},
    };
    const file = stringField(obj, "file") orelse stringField(obj, "from") orelse stringField(obj, "path");
    if (file == null) return &.{};
    const sym = stringField(obj, "symbol") orelse "";
    const out = try arena.alloc(Target, 1);
    out[0] = .{ .file = try arena.dupe(u8, file.?), .symbol = try arena.dupe(u8, sym) };
    return out;
}

fn stringField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = obj.get(name) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn firstLine(text: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, text, " \t\r\n");
    const nl = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
    return std.mem.trimEnd(u8, trimmed[0..nl], " \t\r");
}

fn clip(text: []const u8, limit: usize) []const u8 {
    if (text.len <= limit) return text;
    var end = limit;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

const testing = std.testing;

test "claim carries tool name, status, and a clipped first line" {
    const c = try claim(testing.allocator, "emetgate_search", "src/a.zig:10 hit one\nsrc/b.zig:20 hit two\n", false);
    defer testing.allocator.free(c);
    try testing.expect(std.mem.startsWith(u8, c, "emetgate_search \u{00B7} ok \u{00B7} "));
    try testing.expect(std.mem.indexOf(u8, c, "src/a.zig:10 hit one") != null);
    try testing.expect(std.mem.indexOf(u8, c, "hit two") == null);
}

test "an error claim says error and an empty body falls back to a char count" {
    const e = try claim(testing.allocator, "emetgate_try", "", true);
    defer testing.allocator.free(e);
    try testing.expect(std.mem.indexOf(u8, e, "error") != null);
    try testing.expect(std.mem.indexOf(u8, e, "0 chars") != null);
}

test "targets reads the file and symbol from the tool input" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const t = try targets(arena, "{\"file\":\"src/x.zig\",\"symbol\":\"foo\"}");
    try testing.expectEqual(@as(usize, 1), t.len);
    try testing.expectEqualStrings("src/x.zig", t[0].file);
    try testing.expectEqualStrings("foo", t[0].symbol);
}

test "targets is empty when there is no file-like field" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(@as(usize, 0), (try targets(arena, "{\"question\":\"how\"}")).len);
    try testing.expectEqual(@as(usize, 0), (try targets(arena, "not json")).len);
}

test "targets accepts from and path as file-like fields" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = try targets(arena, "{\"from\":\"old.zig\"}");
    try testing.expectEqualStrings("old.zig", a[0].file);
    const b = try targets(arena, "{\"path\":\"p.zig\"}");
    try testing.expectEqualStrings("p.zig", b[0].file);
}
