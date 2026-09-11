const std = @import("std");
const ts = @import("tree_sitter.zig");
const Document = @import("loader.zig").Document;

pub const fixture_dir = "tests/fixtures/";

pub const TestTree = struct {
    parser: ts.Parser,
    tree: ts.Tree,

    pub fn init(source: []const u8) !TestTree {
        const parser = try ts.Parser.init(ts.typescript());
        errdefer parser.deinit();
        return .{ .parser = parser, .tree = try parser.parse(source) };
    }

    pub fn deinit(self: TestTree) void {
        self.tree.deinit();
        self.parser.deinit();
    }
};

pub fn openFixture(parser: ts.Parser, name: []const u8) !Document {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, fixture_dir ++ "{s}", .{name});
    return Document.open(std.testing.allocator, std.testing.io, .cwd(), path, parser);
}
