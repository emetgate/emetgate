const std = @import("std");
const symbol = @import("symbol.zig");

const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

pub fn writeSymbols(gpa: Allocator, writer: *Writer, file: []const u8, table: symbol.Table) !void {
    var js: std.json.Stringify = .{ .writer = writer };
    try js.beginObject();
    try js.objectField("file");
    try js.write(file);
    try js.objectField("symbols");
    try js.beginArray();
    for (table.symbols) |entry| {
        const point = entry.node.startPoint();
        const hex = symbol.formatHash(entry.hash);
        const ref = try std.fmt.allocPrint(gpa, "{f}", .{entry.ref});
        defer gpa.free(ref);
        try js.beginObject();
        try js.objectField("hash");
        try js.write(hex[0..]);
        try js.objectField("kind");
        try js.write(entry.kind);
        try js.objectField("ref");
        try js.write(ref);
        try js.objectField("line");
        try js.write(point.row + 1);
        try js.objectField("col");
        try js.write(point.column + 1);
        try js.objectField("ambiguous");
        try js.write(entry.ambiguous);
        try js.endObject();
    }
    try js.endArray();
    try js.endObject();
    try writer.writeByte('\n');
}

pub fn writeError(writer: *Writer, name: []const u8, exit_code: u8) !void {
    var js: std.json.Stringify = .{ .writer = writer };
    try js.beginObject();
    try js.objectField("status");
    try js.write("error");
    try js.objectField("error");
    try js.write(name);
    try js.objectField("exit_code");
    try js.write(exit_code);
    try js.endObject();
    try writer.writeByte('\n');
}

const testing = std.testing;
const ts = @import("tree_sitter.zig");
const alloc_bridge = @import("alloc_bridge.zig");
const test_util = @import("test_util.zig");

fn renderSymbols(gpa: Allocator, file: []const u8, tree: ts.Tree) ![]u8 {
    const table = try symbol.Table.build(gpa, tree);
    defer table.deinit();
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    try writeSymbols(gpa, &buffer.writer, file, table);
    return gpa.dupe(u8, buffer.written());
}

test "symbols render as one NDJSON line with typed fields" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const t = try test_util.TestTree.init("export function add(a: number, b: number): number { return a + b; }\n");
    defer t.deinit();

    const json = try renderSymbols(testing.allocator, "src/math.ts", t.tree);
    defer testing.allocator.free(json);

    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, json, "\n"));
    try testing.expect(json[json.len - 1] == '\n');
    try testing.expect(std.mem.indexOf(u8, json, "\"file\":\"src/math.ts\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"ref\":\"add\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"function\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"line\":1") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"ambiguous\":false") != null);
}

test "file paths with backslashes and quotes are JSON-escaped" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const t = try test_util.TestTree.init("function f() {}\n");
    defer t.deinit();

    const json = try renderSymbols(testing.allocator, "tests\\e2e\\a\"b.ts", t.tree);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "tests\\\\e2e\\\\a\\\"b.ts") != null);
}

test "error payload carries the name and exit code on one line" {
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    try writeError(&buffer.writer, "PlaceholderBody", 13);

    try testing.expectEqualStrings(
        "{\"status\":\"error\",\"error\":\"PlaceholderBody\",\"exit_code\":13}\n",
        buffer.written(),
    );
}
