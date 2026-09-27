const std = @import("std");
const ts = @import("tree_sitter.zig");
const json_pointer = @import("lang/json/pointer.zig");
const markdown_heading = @import("lang/markdown/heading.zig");

const Allocator = std.mem.Allocator;

pub const Kind = enum { json, markdown };

pub const Span = struct {
    start: u32,
    end: u32,
    label: []const u8,
};

pub const DocSpans = struct {
    kind: Kind,
    spans: []const Span,
};

pub fn kindFor(path: []const u8) ?Kind {
    if (std.ascii.endsWithIgnoreCase(path, ".json")) return .json;
    if (std.ascii.endsWithIgnoreCase(path, ".md")) return .markdown;
    return null;
}

pub fn build(a: Allocator, path: []const u8, bytes: []const u8) ?DocSpans {
    const kind = kindFor(path) orelse return null;
    const parser = ts.Parser.create();
    defer parser.deinit();
    const grammar = switch (kind) {
        .json => json_pointer.grammar(),
        .markdown => markdown_heading.grammar(),
    };
    const tree = parser.parseIn(grammar, bytes) catch return null;
    defer tree.deinit();
    return switch (kind) {
        .json => jsonSpans(a, tree) catch null,
        .markdown => markdownSpans(a, tree) catch null,
    };
}

fn jsonSpans(a: Allocator, tree: ts.Tree) !?DocSpans {
    if (tree.root().hasError()) return null;
    const entries = json_pointer.keyTree(a, tree) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    const spans = try a.alloc(Span, entries.len);
    for (entries, spans) |entry, *span| {
        span.* = .{ .start = entry.node.startByte(), .end = entry.node.endByte(), .label = entry.pointer };
    }
    return .{ .kind = .json, .spans = spans };
}

fn markdownSpans(a: Allocator, tree: ts.Tree) !?DocSpans {
    const entries = try markdown_heading.headingTree(a, tree);
    const spans = try a.alloc(Span, entries.len);
    for (entries, spans) |entry, *span| {
        span.* = .{ .start = entry.node.startByte(), .end = entry.node.endByte(), .label = try a.dupe(u8, entry.heading) };
    }
    return .{ .kind = .markdown, .spans = spans };
}

pub fn at(doc: DocSpans, offset: u32) ?[]const u8 {
    var best: ?Span = null;
    for (doc.spans) |span| {
        if (offset < span.start or offset >= span.end) continue;
        if (best == null or span.end - span.start < best.?.end - best.?.start) best = span;
    }
    return if (best) |b| b.label else null;
}

pub fn dupe(a: Allocator, doc: ?DocSpans) !?DocSpans {
    const d = doc orelse return null;
    const spans = try a.alloc(Span, d.spans.len);
    for (d.spans, spans) |span, *out| out.* = .{ .start = span.start, .end = span.end, .label = try a.dupe(u8, span.label) };
    return .{ .kind = d.kind, .spans = spans };
}

const testing = std.testing;
const alloc_bridge = @import("alloc_bridge.zig");

fn liveJson(gpa: Allocator, bytes: []const u8, offset: u32) !?[]u8 {
    const parser = ts.Parser.create();
    defer parser.deinit();
    const tree = try parser.parseIn(json_pointer.grammar(), bytes);
    defer tree.deinit();
    return json_pointer.pointerAt(gpa, tree, offset);
}

fn liveMarkdown(gpa: Allocator, bytes: []const u8, offset: u32) !?[]const u8 {
    const parser = ts.Parser.create();
    defer parser.deinit();
    const tree = try parser.parseIn(markdown_heading.grammar(), bytes);
    defer tree.deinit();
    const found = try markdown_heading.sectionAt(gpa, tree, offset);
    return if (found) |f| try gpa.dupe(u8, f) else null;
}

test "stored JSON spans give the same pointer as a live parse at every offset" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const bytes =
        \\{"name": "demo", "deps": {"a/b": "1.0", "c~d": ["x", {"deep": true}]}, "list": [1, 2]}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const doc = build(arena.allocator(), "package.json", bytes) orelse return error.NoSpans;
    for (0..bytes.len) |i| {
        const offset: u32 = @intCast(i);
        const live = try liveJson(testing.allocator, bytes, offset);
        defer if (live) |l| testing.allocator.free(l);
        const stored = at(doc, offset);
        if (live == null) {
            try testing.expect(stored == null);
        } else {
            try testing.expectEqualStrings(live.?, stored orelse return error.MissingPointer);
        }
    }
}

test "stored Markdown spans give the same heading as a live parse at every offset" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const bytes = "intro\n# Title\ntext\n## Setup\nsteps\n### Deep\nmore\n## Usage\nend\n# Other\nlast\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const doc = build(arena.allocator(), "README.md", bytes) orelse return error.NoSpans;
    for (0..bytes.len) |i| {
        const offset: u32 = @intCast(i);
        const live = try liveMarkdown(testing.allocator, bytes, offset);
        defer if (live) |l| testing.allocator.free(l);
        const stored = at(doc, offset);
        if (live == null) {
            try testing.expect(stored == null);
        } else {
            try testing.expectEqualStrings(live.?, stored orelse return error.MissingHeading);
        }
    }
}

test "a file that is neither JSON nor Markdown has no document spans" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect(build(arena.allocator(), "a.ts", "const a = 1;") == null);
}
