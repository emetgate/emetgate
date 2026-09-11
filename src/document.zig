const std = @import("std");
const ts = @import("ts.zig");
const alloc_bridge = @import("alloc_bridge.zig");

const max_source_len = std.math.maxInt(u32);

pub const Document = struct {
    gpa: std.mem.Allocator,
    source: []u8,
    tree: ts.Tree,

    pub const OpenError = std.Io.Dir.ReadFileAllocError || ts.Error;

    pub fn open(
        gpa: std.mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        path: []const u8,
        parser: ts.Parser,
    ) OpenError!Document {
        const source = try dir.readFileAlloc(io, path, gpa, .limited(max_source_len));
        errdefer gpa.free(source);
        return .{ .gpa = gpa, .source = source, .tree = try parser.parse(source) };
    }

    pub fn deinit(self: Document) void {
        self.tree.deinit();
        self.gpa.free(self.source);
    }
};

const testing = std.testing;

pub const fixture_dir = "tests/fixtures/";

pub fn openFixture(parser: ts.Parser, name: []const u8) !Document {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, fixture_dir ++ "{s}", .{name});
    return Document.open(testing.allocator, testing.io, .cwd(), path, parser);
}

test "opens a fixture from disk and parses it without errors" {
    alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try ts.Parser.init(ts.typescript());
    defer parser.deinit();

    const doc = try openFixture(parser, "functions.ts");
    defer doc.deinit();

    try testing.expect(doc.source.len > 0);
    try testing.expectEqualStrings("program", doc.tree.root().kind());
    try testing.expect(!doc.tree.root().hasError());
    try testing.expectEqual(@as(u32, @intCast(doc.source.len)), doc.tree.root().endByte());
}

test "a syntactically broken fixture loads but reports the error" {
    alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try ts.Parser.init(ts.typescript());
    defer parser.deinit();

    const doc = try openFixture(parser, "broken.ts");
    defer doc.deinit();

    try testing.expect(doc.tree.root().hasError());
}

test "a missing file surfaces FileNotFound and leaks nothing" {
    alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const parser = try ts.Parser.init(ts.typescript());
    defer parser.deinit();

    try testing.expectError(error.FileNotFound, openFixture(parser, "does-not-exist.ts"));
}
