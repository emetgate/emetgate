const std = @import("std");
const symbol = @import("../engine/symbol.zig");
const mirror_mod = @import("mirror.zig");
const wire = @import("wire.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Mirror = mirror_mod.Mirror;

pub const covered_hint = "inside your earlier whole read of this file, unchanged since (same file_hash); force:true resends";

fn wholeKey(gpa: Allocator, file: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "whole:{s}", .{file});
}

pub fn recordWhole(gpa: Allocator, mirror: ?*Mirror, file: []const u8, file_hash: symbol.Hash) !void {
    const m = mirror orelse return;
    const key = try wholeKey(gpa, file);
    defer gpa.free(key);
    _ = try m.check(key, file_hash, true);
}

pub fn coversWhole(gpa: Allocator, mirror: ?*Mirror, file: []const u8, file_hash: symbol.Hash, force: bool) !bool {
    const m = mirror orelse return false;
    if (force or !m.enabled) return false;
    const key = try wholeKey(gpa, file);
    defer gpa.free(key);
    const held = m.entries.get(key) orelse return false;
    return std.mem.eql(u8, &held, &file_hash);
}

pub fn writeCovered(w: *Writer, file: []const u8, unit: ?[]const u8, file_hash: symbol.Hash) !void {
    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("status");
    try js.write("unchanged");
    try js.objectField("file");
    try js.write(file);
    if (unit) |u| {
        try js.objectField("symbol");
        try js.write(u);
    }
    try wire.writeFileHash(&js, file_hash);
    try js.objectField("hint");
    try js.write(covered_hint);
    try js.endObject();
    try w.writeByte('\n');
}

const testing = std.testing;

test "a whole read covers later reads of the same file only while its hash holds" {
    var m: Mirror = .init(testing.allocator, true);
    defer m.deinit();
    const before = symbol.hashOf("a");
    const after = symbol.hashOf("b");
    try testing.expect(!try coversWhole(testing.allocator, &m, "f.js", before, false));
    try recordWhole(testing.allocator, &m, "f.js", before);
    try testing.expect(try coversWhole(testing.allocator, &m, "f.js", before, false));
    try testing.expect(!try coversWhole(testing.allocator, &m, "f.js", before, true));
    try testing.expect(!try coversWhole(testing.allocator, &m, "f.js", after, false));
    try testing.expect(!try coversWhole(testing.allocator, &m, "g.js", before, false));
    try recordWhole(testing.allocator, &m, "f.js", after);
    try testing.expect(!try coversWhole(testing.allocator, &m, "f.js", before, false));
    try testing.expect(try coversWhole(testing.allocator, &m, "f.js", after, false));
}

test "a disabled or absent mirror never covers a read" {
    var m: Mirror = .init(testing.allocator, false);
    defer m.deinit();
    const hash = symbol.hashOf("a");
    try recordWhole(testing.allocator, &m, "f.js", hash);
    try testing.expect(!try coversWhole(testing.allocator, &m, "f.js", hash, false));
    try testing.expect(!try coversWhole(testing.allocator, null, "f.js", hash, false));
}
