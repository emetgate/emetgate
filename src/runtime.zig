const std = @import("std");
const ts = @import("tree_sitter.zig");
const alloc_bridge = @import("alloc_bridge.zig");
const test_util = @import("test_util.zig");

pub const Runtime = struct {
    gpa: std.mem.Allocator,
    parser: ts.Parser,
    live_snapshots: usize = 0,

    pub fn init(gpa: std.mem.Allocator) ts.Error!Runtime {
        alloc_bridge.install(gpa);
        errdefer alloc_bridge.uninstall();
        return .{ .gpa = gpa, .parser = try ts.Parser.init(ts.typescript()) };
    }

    pub fn deinit(self: *Runtime) error{LiveSnapshots}!void {
        if (self.live_snapshots != 0) return error.LiveSnapshots;
        self.parser.deinit();
        alloc_bridge.uninstall();
        self.* = undefined;
    }
};

const testing = std.testing;

test "a runtime refuses to close while a snapshot is alive" {
    var runtime = try Runtime.init(testing.allocator);
    const snapshot = try test_util.snapshotOf(&runtime, "function f() {}\n");

    try testing.expectEqual(@as(usize, 1), runtime.live_snapshots);
    try testing.expectError(error.LiveSnapshots, runtime.deinit());

    snapshot.destroy();
    try testing.expectEqual(@as(usize, 0), runtime.live_snapshots);
    try runtime.deinit();
}

test "a closed runtime releases the allocator bridge so a new one can start" {
    for (0..3) |_| {
        var runtime = try Runtime.init(testing.allocator);
        const snapshot = try test_util.snapshotOf(&runtime, "const x = () => 1;\n");
        _ = try snapshot.symbols();
        snapshot.destroy();
        try runtime.deinit();
        try testing.expectEqual(alloc_bridge.Stats{ .blocks = 0, .bytes = 0 }, alloc_bridge.stats());
    }
}
