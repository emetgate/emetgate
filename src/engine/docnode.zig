const std = @import("std");
const ts = @import("tree_sitter.zig");
const symbol = @import("symbol.zig");
const line_range = @import("line_range.zig");
const json_pointer = @import("lang/json/pointer.zig");
const markdown_heading = @import("lang/markdown/heading.zig");

const Allocator = std.mem.Allocator;
const Span = symbol.Span;

pub const Error = error{
    HashMismatch,
    PointerNotFound,
    HeadingNotFound,
    InvalidLineRange,
    LineOutOfRange,
    InvalidJson,
    DocSyntaxInvalid,
    NotUtf8,
    DocTooLarge,
    BinaryFile,
} || Allocator.Error || ts.Error || line_range.Error;

pub const Applied = struct {
    source: []u8,
    hash: symbol.Hash,
};

pub const Selector = union(enum) {
    pointer: []const u8,
    heading: []const u8,
    line_range: struct { start: u32, end: u32 },
};

pub const max_bytes = 1024 * 1024;

const binary_probe_bytes = 8000;

pub fn looksBinary(bytes: []const u8) bool {
    return std.mem.indexOfScalar(u8, bytes[0..@min(bytes.len, binary_probe_bytes)], 0) != null;
}

pub fn checkReadable(source: []const u8) Error!void {
    if (source.len > max_bytes) return error.DocTooLarge;
    if (looksBinary(source)) return error.BinaryFile;
}

fn splice(gpa: Allocator, source: []const u8, span: Span, actual_hash: symbol.Hash, expected_hash: symbol.Hash, new_text: []const u8) Error![]u8 {
    if (!std.mem.eql(u8, &actual_hash, &expected_hash)) return error.HashMismatch;
    return std.mem.concat(gpa, u8, &.{ source[0..span.start], new_text, source[span.end..] });
}

pub fn applyJsonPointer(gpa: Allocator, parser: ts.Parser, source: []const u8, pointer: []const u8, expected_hash: symbol.Hash, new_value: []const u8) Error!Applied {
    if (!std.unicode.utf8ValidateSlice(new_value)) return error.NotUtf8;
    const value_tree = parser.parseIn(json_pointer.grammar(), new_value) catch return error.InvalidJson;
    defer value_tree.deinit();
    if (value_tree.root().hasError()) return error.InvalidJson;

    const tree = parser.parseIn(json_pointer.grammar(), source) catch return error.InvalidJson;
    defer tree.deinit();
    if (tree.root().hasError()) return error.InvalidJson;
    const entry = try json_pointer.resolve(gpa, tree, pointer);
    defer gpa.free(entry.pointer);
    const span: Span = .{ .start = entry.node.startByte(), .end = entry.node.endByte() };
    const actual_hash = symbol.hashOf(tree.text(entry.node));
    const spliced = try splice(gpa, source, span, actual_hash, expected_hash, new_value);
    errdefer gpa.free(spliced);

    const reparsed = parser.parseIn(json_pointer.grammar(), spliced) catch return error.InvalidJson;
    defer reparsed.deinit();
    if (reparsed.root().hasError()) return error.DocSyntaxInvalid;
    const verify = json_pointer.resolve(gpa, reparsed, pointer) catch return error.DocSyntaxInvalid;
    defer gpa.free(verify.pointer);
    if (!std.mem.eql(u8, reparsed.text(verify.node), new_value)) return error.DocSyntaxInvalid;

    return .{ .source = spliced, .hash = symbol.hashOf(new_value) };
}

fn headingLine(text: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    return text[0..end];
}

fn atxLevelOf(line: []const u8) ?u8 {
    var count: u8 = 0;
    while (count < line.len and line[count] == '#') count += 1;
    if (count == 0 or count > 6) return null;
    if (count < line.len and line[count] != ' ') return null;
    return count;
}

pub fn applyMarkdownHeading(gpa: Allocator, parser: ts.Parser, source: []const u8, heading: []const u8, expected_hash: symbol.Hash, new_section: []const u8) Error!Applied {
    if (!std.unicode.utf8ValidateSlice(new_section)) return error.NotUtf8;
    if (atxLevelOf(headingLine(new_section)) == null) return error.DocSyntaxInvalid;

    const tree = try parser.parseIn(markdown_heading.grammar(), source);
    defer tree.deinit();
    const entry = try markdown_heading.resolve(gpa, tree, heading);
    const span: Span = .{ .start = entry.node.startByte(), .end = entry.node.endByte() };
    const actual_hash = symbol.hashOf(tree.text(entry.node));
    const spliced = try splice(gpa, source, span, actual_hash, expected_hash, new_section);
    errdefer gpa.free(spliced);

    const reparsed = try parser.parseIn(markdown_heading.grammar(), spliced);
    defer reparsed.deinit();
    const entries = try markdown_heading.headingTree(gpa, reparsed);
    defer gpa.free(entries);
    var found = false;
    for (entries) |candidate| {
        if (candidate.node.startByte() == span.start) {
            found = candidate.node.endByte() == span.start + new_section.len;
            break;
        }
    }
    if (!found) return error.DocSyntaxInvalid;

    return .{ .source = spliced, .hash = symbol.hashOf(new_section) };
}

pub fn applyLineRange(gpa: Allocator, source: []const u8, line_start: u32, line_end: u32, expected_hash: symbol.Hash, new_content: []const u8) Error!Applied {
    if (!std.unicode.utf8ValidateSlice(source) or !std.unicode.utf8ValidateSlice(new_content)) return error.NotUtf8;
    const span = try line_range.byteRangeForLines(source, line_start, line_end);
    const actual_hash = symbol.hashOf(source[span.start..span.end]);
    const spliced = try splice(gpa, source, span, actual_hash, expected_hash, new_content);
    return .{ .source = spliced, .hash = symbol.hashOf(new_content) };
}

pub fn apply(gpa: Allocator, parser: ts.Parser, source: []const u8, selector: Selector, expected_hash: symbol.Hash, new_text: []const u8) Error!Applied {
    return switch (selector) {
        .pointer => |p| applyJsonPointer(gpa, parser, source, p, expected_hash, new_text),
        .heading => |h| applyMarkdownHeading(gpa, parser, source, h, expected_hash, new_text),
        .line_range => |r| applyLineRange(gpa, source, r.start, r.end, expected_hash, new_text),
    };
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const alloc_bridge = @import("alloc_bridge.zig");

test "applyJsonPointer replaces one value and leaves the rest of the document untouched" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try test_util.parser();
    defer parser.deinit();

    const source = "{\"a\": 1, \"b\": {\"c\": 2}}";
    const tree = parser.parseIn(json_pointer.grammar(), source) catch unreachable;
    defer tree.deinit();
    const entry = try json_pointer.resolve(testing.allocator, tree, "/b/c");
    defer testing.allocator.free(entry.pointer);

    const applied = try applyJsonPointer(testing.allocator, parser, source, "/b/c", entry.hash, "9");
    defer testing.allocator.free(applied.source);
    try testing.expectEqualStrings("{\"a\": 1, \"b\": {\"c\": 9}}", applied.source);
    try testing.expectEqual(symbol.hashOf("9"), applied.hash);
}

test "applyJsonPointer refuses a stale hash and refuses a value that is not valid json" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try test_util.parser();
    defer parser.deinit();

    const source = "{\"a\": 1}";
    const tree = parser.parseIn(json_pointer.grammar(), source) catch unreachable;
    defer tree.deinit();
    const entry = try json_pointer.resolve(testing.allocator, tree, "/a");
    defer testing.allocator.free(entry.pointer);

    try testing.expectError(error.HashMismatch, applyJsonPointer(testing.allocator, parser, source, "/a", symbol.hashOf("stale"), "2"));
    try testing.expectError(error.InvalidJson, applyJsonPointer(testing.allocator, parser, source, "/a", entry.hash, "{not json"));
}

test "applyJsonPointer refuses a value that reparses to something other than exactly what was written" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try test_util.parser();
    defer parser.deinit();

    const source = "{\"a\": 1}";
    const tree = parser.parseIn(json_pointer.grammar(), source) catch unreachable;
    defer tree.deinit();
    const entry = try json_pointer.resolve(testing.allocator, tree, "/a");
    defer testing.allocator.free(entry.pointer);

    try testing.expectError(error.DocSyntaxInvalid, applyJsonPointer(testing.allocator, parser, source, "/a", entry.hash, "9 "));
}

test "applyMarkdownHeading replaces a section and keeps a sibling section untouched" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try test_util.parser();
    defer parser.deinit();

    const source = "# Title\n\n## Setup\n\nold\n\n## Other\n\nkeep\n";
    const tree = try parser.parseIn(markdown_heading.grammar(), source);
    defer tree.deinit();
    const entry = try markdown_heading.resolve(testing.allocator, tree, "Setup");

    const applied = try applyMarkdownHeading(testing.allocator, parser, source, "Setup", entry.hash, "## Setup\n\nnew\n\n");
    defer testing.allocator.free(applied.source);
    try testing.expect(std.mem.indexOf(u8, applied.source, "new") != null);
    try testing.expect(std.mem.indexOf(u8, applied.source, "old") == null);
    try testing.expect(std.mem.indexOf(u8, applied.source, "## Other\n\nkeep\n") != null);
}

test "applyMarkdownHeading refuses a replacement that does not start with a heading line" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try test_util.parser();
    defer parser.deinit();

    const source = "# Title\n\n## Setup\n\nold\n";
    const tree = try parser.parseIn(markdown_heading.grammar(), source);
    defer tree.deinit();
    const entry = try markdown_heading.resolve(testing.allocator, tree, "Setup");
    try testing.expectError(error.DocSyntaxInvalid, applyMarkdownHeading(testing.allocator, parser, source, "Setup", entry.hash, "not a heading\n"));
}

test "applyMarkdownHeading refuses a replacement whose unclosed code fence swallows the next heading" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try test_util.parser();
    defer parser.deinit();

    const source = "# Title\n\n## Setup\n\nold\n\n## Other\n\nkeep\n";
    const tree = try parser.parseIn(markdown_heading.grammar(), source);
    defer tree.deinit();
    const entry = try markdown_heading.resolve(testing.allocator, tree, "Setup");
    try testing.expectError(error.DocSyntaxInvalid, applyMarkdownHeading(testing.allocator, parser, source, "Setup", entry.hash, "## Setup\n\n```js\nx = 1\n"));
}

test "applyMarkdownHeading refuses a replacement whose unclosed html block swallows the next heading" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try test_util.parser();
    defer parser.deinit();

    const source = "# Title\n\n## Setup\n\nold\n\n## Other\n\nkeep\n";
    const tree = try parser.parseIn(markdown_heading.grammar(), source);
    defer tree.deinit();
    const entry = try markdown_heading.resolve(testing.allocator, tree, "Setup");
    try testing.expectError(error.DocSyntaxInvalid, applyMarkdownHeading(testing.allocator, parser, source, "Setup", entry.hash, "## Setup\n\n<script>\n"));
}

test "applyLineRange replaces a byte-exact line span and refuses a stale hash" {
    const source = "aaa\nbbb\nccc\n";
    const span = try line_range.byteRangeForLines(source, 2, 2);
    const hash = symbol.hashOf(source[span.start..span.end]);

    const applied = try applyLineRange(testing.allocator, source, 2, 2, hash, "zzz\n");
    defer testing.allocator.free(applied.source);
    try testing.expectEqualStrings("aaa\nzzz\nccc\n", applied.source);

    try testing.expectError(error.HashMismatch, applyLineRange(testing.allocator, source, 2, 2, symbol.hashOf("stale"), "zzz\n"));
}
