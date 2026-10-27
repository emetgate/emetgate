const std = @import("std");

const registry = @import("../engine/lang/registry.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

pub const Call = struct {
    name: []const u8,
    args: ?Value,
};

const Alias = struct { []const u8, []const []const u8 };

const file_aliases = [_][]const u8{ "path", "file_path", "filepath", "filename" };
const item_aliases = [_]Alias{
    .{ "file", &file_aliases },
    .{ "old_string", &.{ "old_str", "old_text", "old" } },
    .{ "new_string", &.{ "new_str", "new_text", "new" } },
    .{ "line_start", &.{ "start_line", "start" } },
    .{ "line_end", &.{ "end_line", "end" } },
    .{ "hash", &.{ "file_hash", "expected_hash" } },
    .{ "body", &.{ "content", "new_body", "code" } },
    .{ "content", &.{ "body", "new_content", "text" } },
};
const write_aliases = [_]Alias{
    .{ "file", &file_aliases },
    .{ "content", &.{ "body", "text", "code", "new_content" } },
};
const edit_aliases = [_]Alias{
    .{ "file", &file_aliases },
    .{ "old_string", &.{ "old_str", "old_text", "old" } },
    .{ "new_string", &.{ "new_str", "new_text", "new" } },
};
const rename_aliases = [_]Alias{
    .{ "file", &file_aliases },
    .{ "symbol", &.{ "old_name", "name" } },
    .{ "new_name", &.{ "to", "new", "newName", "rename_to" } },
};
const move_aliases = [_]Alias{
    .{ "file", &file_aliases },
    .{ "target_file", &.{ "target", "to", "destination", "dest" } },
};
const move_file_aliases = [_]Alias{
    .{ "from", &.{ "file", "source", "src", "path", "from_path" } },
    .{ "to", &.{ "target", "destination", "dest", "to_path", "new_path" } },
    .{ "from_hash", &.{ "hash", "file_hash" } },
};

const code_kinds = [_][]const u8{ "code", "source", "symbol" };
const doc_kinds = [_][]const u8{ "doc", "docs", "document", "text", "file" };
const write_ops = [_][]const u8{ "write", "create", "replace", "update", "overwrite", "edit", "insert", "add" };
const delete_ops = [_][]const u8{ "delete", "remove" };
const absent_words = [_][]const u8{ "absent", "", "none", "new", "null" };

pub fn normalize(arena: Allocator, name: []const u8, args: ?Value) !Call {
    const given = args orelse return .{ .name = name, .args = args };
    if (given != .object) return .{ .name = name, .args = args };
    if (eql(name, "emetgate_try")) {
        const item = try normalizeItem(arena, given);
        return .{ .name = name, .args = item };
    }
    if (eql(name, "emetgate_try_batch")) return .{ .name = name, .args = try normalizeBatch(arena, given) };
    if (eql(name, "emetgate_write")) return .{ .name = name, .args = try aliased(arena, given, &write_aliases) };
    if (eql(name, "emetgate_edit")) return .{ .name = name, .args = try aliased(arena, given, &edit_aliases) };
    if (eql(name, "emetgate_rename")) return .{ .name = name, .args = try aliased(arena, given, &rename_aliases) };
    if (eql(name, "emetgate_move")) return .{ .name = name, .args = try aliased(arena, given, &move_aliases) };
    if (eql(name, "emetgate_move_file")) return .{ .name = name, .args = try aliased(arena, given, &move_file_aliases) };
    if (eql(name, "emetgate_write_doc")) {
        var item = try normalizeItem(arena, given);
        if (!needsBatch(item)) return .{ .name = name, .args = item };
        if (!item.object.contains("kind")) try item.object.put(arena, "kind", .{ .string = "doc" });
        return .{ .name = "emetgate_try_batch", .args = try asBatch(arena, item) };
    }
    return .{ .name = name, .args = args };
}

pub fn asBatch(arena: Allocator, item: Value) !Value {
    var map = try copy(arena, item.object);
    var edits: std.json.Array = .init(arena);
    try edits.append(item);
    try map.put(arena, "edits", .{ .array = edits });
    return .{ .object = map };
}

fn needsBatch(item: Value) bool {
    const file = stringOf(item, "file") orelse return false;
    if (registry.forPath(file) != null) return true;
    const hash = stringOf(item, "hash") orelse return true;
    if (eql(hash, "absent")) return true;
    if (stringOf(item, "pointer")) |pointer| return pointer.len == 0;
    return stringOf(item, "heading") == null and item.object.get("line_start") == null;
}

fn stringOf(item: Value, key: []const u8) ?[]const u8 {
    const value = item.object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn normalizeBatch(arena: Allocator, given: Value) !Value {
    var map = try copy(arena, given.object);
    const edits = map.get("edits") orelse {
        if (map.get("file") != null or map.get("path") != null or map.get("file_path") != null) {
            const item = try normalizeItem(arena, given);
            return asBatch(arena, item);
        }
        return .{ .object = map };
    };
    const items: []const Value = switch (edits) {
        .array => |a| a.items,
        .object => &.{edits},
        else => return .{ .object = map },
    };
    var out: std.json.Array = .init(arena);
    for (items) |item| try out.append(if (item == .object) try normalizeItem(arena, item) else item);
    try map.put(arena, "edits", .{ .array = out });
    return .{ .object = map };
}

pub fn normalizeItem(arena: Allocator, given: Value) !Value {
    var item = try aliased(arena, given, &item_aliases);
    const map = &item.object;
    if (map.get("line_start") == null) if (map.get("line")) |line| {
        try map.put(arena, "line_start", line);
        try map.put(arena, "line_end", line);
    };
    if (map.get("line_start")) |start| if (map.get("line_end") == null and start == .integer) try map.put(arena, "line_end", start);
    if (map.get("hash")) |hash| switch (hash) {
        .null => try map.put(arena, "hash", .{ .string = "absent" }),
        .string => |text| if (isAny(text, &absent_words)) try map.put(arena, "hash", .{ .string = "absent" }),
        else => {},
    };
    if (map.get("kind")) |kind| if (kind == .string) {
        if (isAny(kind.string, &code_kinds)) try map.put(arena, "kind", .{ .string = "code" });
        if (isAny(kind.string, &doc_kinds)) try map.put(arena, "kind", .{ .string = "doc" });
    };
    if (map.get("op")) |op| if (op == .string) {
        if (isAny(op.string, &write_ops)) try map.put(arena, "op", .{ .string = "write" });
        if (isAny(op.string, &delete_ops)) try map.put(arena, "op", .{ .string = "delete" });
    };
    return item;
}

fn aliased(arena: Allocator, given: Value, aliases: []const Alias) !Value {
    var map = try copy(arena, given.object);
    for (aliases) |alias| {
        if (map.get(alias[0]) != null) continue;
        for (alias[1]) |other| {
            const value = given.object.get(other) orelse continue;
            if (value != .string and value != .integer) continue;
            try map.put(arena, alias[0], value);
            break;
        }
    }
    return .{ .object = map };
}

fn copy(arena: Allocator, object: ObjectMap) !ObjectMap {
    var map: ObjectMap = .empty;
    var it = object.iterator();
    while (it.next()) |entry| try map.put(arena, entry.key_ptr.*, entry.value_ptr.*);
    return map;
}

fn isAny(text: []const u8, words: []const []const u8) bool {
    for (words) |word| if (std.ascii.eqlIgnoreCase(text, word)) return true;
    return false;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const testing = std.testing;

fn parse(arena: Allocator, text: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, arena, text, .{});
}

test "normalizeItem maps path and content aliases and reads an empty hash as absent" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const item = try normalizeItem(arena, try parse(arena, "{\"path\":\"a.py\",\"hash\":\"\",\"content\":\"x = 1\\n\",\"start_line\":3}"));
    try testing.expectEqualStrings("a.py", item.object.get("file").?.string);
    try testing.expectEqualStrings("x = 1\n", item.object.get("body").?.string);
    try testing.expectEqualStrings("absent", item.object.get("hash").?.string);
    try testing.expectEqual(@as(i64, 3), item.object.get("line_end").?.integer);
}

test "normalize sends write_doc through try_batch as a doc item and keeps the top-level fields" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const call = try normalize(arena, "emetgate_write_doc", try parse(arena, "{\"file\":\"a.md\",\"hash\":\"absent\",\"body\":\"# A\\n\"}"));
    try testing.expectEqualStrings("emetgate_try_batch", call.name);
    const item = call.args.?.object.get("edits").?.array.items[0];
    try testing.expectEqualStrings("doc", item.object.get("kind").?.string);
    try testing.expectEqualStrings("# A\n", item.object.get("content").?.string);
    try testing.expectEqualStrings("a.md", call.args.?.object.get("file").?.string);
}

test "normalize keeps a write_doc that names a selector and hash on a non-source file" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const call = try normalize(arena, "emetgate_write_doc", try parse(arena, "{\"path\":\"a.json\",\"hash\":\"00\",\"pointer\":\"/a\",\"text\":\"1\"}"));
    try testing.expectEqualStrings("emetgate_write_doc", call.name);
    try testing.expectEqualStrings("a.json", call.args.?.object.get("file").?.string);
    try testing.expectEqualStrings("1", call.args.?.object.get("content").?.string);
}

test "normalize wraps a try_batch call that names a file but no edits array" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const call = try normalize(arena, "emetgate_try_batch", try parse(arena, "{\"file_path\":\"b.js\",\"content\":\"x\"}"));
    try testing.expectEqual(@as(usize, 1), call.args.?.object.get("edits").?.array.items.len);
}
