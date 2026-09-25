const std = @import("std");
const ts = @import("../../tree_sitter.zig");
const symbol = @import("../../symbol.zig");

const Allocator = std.mem.Allocator;

extern fn tree_sitter_markdown() callconv(.c) ?*const ts.Language;

pub fn grammar() *const ts.Language {
    return tree_sitter_markdown().?;
}

pub const Entry = struct {
    heading: []const u8,
    level: u8,
    line: u32,
    hash: symbol.Hash,
    node: ts.Node,
};

pub const Error = error{HeadingNotFound} || Allocator.Error;

fn atxLevel(marker_kind: []const u8) ?u8 {
    const names = [_][]const u8{ "atx_h1_marker", "atx_h2_marker", "atx_h3_marker", "atx_h4_marker", "atx_h5_marker", "atx_h6_marker" };
    for (names, 1..) |name, level| {
        if (std.mem.eql(u8, marker_kind, name)) return @intCast(level);
    }
    return null;
}

fn setextLevel(node: ts.Node) ?u8 {
    var i: u32 = 0;
    while (node.namedChild(i)) |child| : (i += 1) {
        if (std.mem.eql(u8, child.kind(), "setext_h1_underline")) return 1;
        if (std.mem.eql(u8, child.kind(), "setext_h2_underline")) return 2;
    }
    return null;
}

fn headingOf(tree: ts.Tree, section: ts.Node) ?ts.Node {
    const first = section.namedChild(0) orelse return null;
    if (std.mem.eql(u8, first.kind(), "atx_heading") or std.mem.eql(u8, first.kind(), "setext_heading")) return first;
    _ = tree;
    return null;
}

fn headingText(tree: ts.Tree, heading: ts.Node) []const u8 {
    const content = heading.childByField("heading_content") orelse return "";
    return std.mem.trim(u8, tree.text(content), " \t\r\n");
}

fn headingLevel(heading: ts.Node) u8 {
    if (std.mem.eql(u8, heading.kind(), "setext_heading")) return setextLevel(heading) orelse 1;
    var i: u32 = 0;
    while (heading.child(i)) |child| : (i += 1) {
        if (atxLevel(child.kind())) |level| return level;
    }
    return 1;
}

fn hashOfNode(tree: ts.Tree, node: ts.Node) symbol.Hash {
    return symbol.hashOf(tree.text(node));
}

pub fn headingTree(gpa: Allocator, tree: ts.Tree) Allocator.Error![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    errdefer out.deinit(gpa);
    try walk(gpa, tree, tree.root(), &out);
    return out.toOwnedSlice(gpa);
}

fn walk(gpa: Allocator, tree: ts.Tree, node: ts.Node, out: *std.ArrayList(Entry)) Allocator.Error!void {
    var i: u32 = 0;
    while (node.namedChild(i)) |child| : (i += 1) {
        if (!std.mem.eql(u8, child.kind(), "section")) continue;
        if (headingOf(tree, child)) |heading| {
            try out.append(gpa, .{
                .heading = headingText(tree, heading),
                .level = headingLevel(heading),
                .line = heading.startPoint().row + 1,
                .hash = hashOfNode(tree, child),
                .node = child,
            });
        }
        try walk(gpa, tree, child, out);
    }
}

pub fn resolve(gpa: Allocator, tree: ts.Tree, heading: []const u8) Error!Entry {
    const entries = try headingTree(gpa, tree);
    defer gpa.free(entries);
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.heading, heading)) return entry;
    }
    return error.HeadingNotFound;
}

const testing = std.testing;
const test_util = @import("../../test_util.zig");
const alloc_bridge = @import("../../alloc_bridge.zig");

fn parseMarkdown(parser: ts.Parser, source: []const u8) !ts.Tree {
    return parser.parseIn(grammar(), source);
}

test "headingTree lists every heading with its level and line, nested sections included" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try test_util.parser();
    defer parser.deinit();

    const source = "# Title\n\nintro\n\n## Setup\n\ndetails\n\n### Install\n\nsteps\n";
    const tree = try parseMarkdown(parser, source);
    defer tree.deinit();

    const entries = try headingTree(testing.allocator, tree);
    defer testing.allocator.free(entries);

    try testing.expectEqual(@as(usize, 3), entries.len);
    try testing.expectEqualStrings("Title", entries[0].heading);
    try testing.expectEqual(@as(u8, 1), entries[0].level);
    try testing.expectEqual(@as(u32, 1), entries[0].line);
    try testing.expectEqualStrings("Setup", entries[1].heading);
    try testing.expectEqual(@as(u8, 2), entries[1].level);
    try testing.expectEqualStrings("Install", entries[2].heading);
    try testing.expectEqual(@as(u8, 3), entries[2].level);
}

test "resolve returns a section's full text including its nested subsections" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try test_util.parser();
    defer parser.deinit();

    const source = "# Title\n\nintro\n\n## Setup\n\ndetails\n\n### Install\n\nsteps\n\n## Other\n\nmore\n";
    const tree = try parseMarkdown(parser, source);
    defer tree.deinit();

    const entry = try resolve(testing.allocator, tree, "Setup");
    const text = tree.text(entry.node);
    try testing.expect(std.mem.indexOf(u8, text, "## Setup") != null);
    try testing.expect(std.mem.indexOf(u8, text, "### Install") != null);
    try testing.expect(std.mem.indexOf(u8, text, "## Other") == null);
}

test "resolve on a missing heading is an error, not a guess" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try test_util.parser();
    defer parser.deinit();

    const tree = try parseMarkdown(parser, "# Title\n");
    defer tree.deinit();
    try testing.expectError(error.HeadingNotFound, resolve(testing.allocator, tree, "Nope"));
}

test "a setext heading is recognized with its underline level" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try test_util.parser();
    defer parser.deinit();

    const tree = try parseMarkdown(parser, "Title\n=====\n\nbody\n");
    defer tree.deinit();
    const entries = try headingTree(testing.allocator, tree);
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("Title", entries[0].heading);
    try testing.expectEqual(@as(u8, 1), entries[0].level);
}
