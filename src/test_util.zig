const std = @import("std");
const ts = @import("tree_sitter.zig");
const Runtime = @import("runtime.zig").Runtime;
const Snapshot = @import("loader.zig").Snapshot;

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

pub const Fixture = struct {
    source: []u8,
    tree: ts.Tree,

    pub fn deinit(self: Fixture) void {
        self.tree.deinit();
        std.testing.allocator.free(self.source);
    }
};

pub fn openFixture(parser: ts.Parser, name: []const u8) !Fixture {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try fixturePath(&path_buf, name), std.testing.allocator, .unlimited);
    errdefer std.testing.allocator.free(source);
    return .{ .source = source, .tree = try parser.parse(source) };
}

pub fn openRuntime() !Runtime {
    return Runtime.init(std.testing.allocator);
}

pub fn closeRuntime(runtime: *Runtime) void {
    const live = runtime.live_snapshots;
    runtime.deinit() catch |err| std.debug.panic("runtime closed with {d} live snapshots: {t}", .{ live, err });
}

pub fn snapshotOf(runtime: *Runtime, source: []const u8) !*Snapshot {
    return Snapshot.fromSource(runtime, try std.testing.allocator.dupe(u8, source));
}

pub fn loadFixture(runtime: *Runtime, name: []const u8) !*Snapshot {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    return Snapshot.load(runtime, std.testing.io, .cwd(), try fixturePath(&path_buf, name));
}

fn fixturePath(buf: []u8, name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, fixture_dir ++ "{s}", .{name});
}
