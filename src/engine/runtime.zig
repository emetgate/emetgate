const std = @import("std");
const ts = @import("tree_sitter.zig");
const alloc_bridge = @import("alloc_bridge.zig");
const test_util = @import("test_util.zig");

pub const Runtime = struct {
    gpa: std.mem.Allocator,
    parser: ts.Parser,
    live_snapshots: usize = 0,
    next_checkpoint_id: u64 = 0,

    pub const OpenError = error{RuntimeAlreadyOpen} || ts.Error || std.mem.Allocator.Error;
    pub const CloseError = error{ LiveSnapshots, LiveAllocations };

    pub fn create(gpa: std.mem.Allocator) OpenError!*Runtime {
        alloc_bridge.install(gpa) catch return error.RuntimeAlreadyOpen;
        errdefer alloc_bridge.uninstall();
        const self = try gpa.create(Runtime);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .parser = try ts.Parser.init(ts.typescript()) };
        return self;
    }

    pub fn nextCheckpointId(self: *Runtime) u64 {
        defer self.next_checkpoint_id += 1;
        return self.next_checkpoint_id;
    }

    pub fn destroy(self: *Runtime) CloseError!void {
        if (self.live_snapshots != 0) return error.LiveSnapshots;
        self.parser.deinit();
        if (alloc_bridge.stats().blocks != 0) {
            self.parser = ts.Parser.init(ts.typescript()) catch @panic("cannot restore the parser of a runtime that refused to close");
            return error.LiveAllocations;
        }
        alloc_bridge.uninstall();
        const gpa = self.gpa;
        self.* = undefined;
        gpa.destroy(self);
    }
};

const testing = std.testing;

test "a runtime refuses to close while a snapshot is alive" {
    const runtime = try Runtime.create(testing.allocator);
    const snapshot = try test_util.snapshotOf(runtime, "function f() {}\n");

    try testing.expectEqual(@as(usize, 1), runtime.live_snapshots);
    try testing.expectError(error.LiveSnapshots, runtime.destroy());

    snapshot.destroy();
    try testing.expectEqual(@as(usize, 0), runtime.live_snapshots);
    try runtime.destroy();
}

test "a runtime refuses to close while a plain tree is alive and stays usable" {
    const runtime = try Runtime.create(testing.allocator);
    const tree = try runtime.parser.parse("const x = 1;\n");

    try testing.expectError(error.LiveAllocations, runtime.destroy());

    const snapshot = try test_util.snapshotOf(runtime, "function f() { return 1; }\n");
    try testing.expect(!snapshot.tree.root().hasError());
    snapshot.destroy();

    tree.deinit();
    try runtime.destroy();
}

test "only one runtime can be open, and a closed one frees the bridge for the next" {
    const first = try Runtime.create(testing.allocator);
    try testing.expectError(error.RuntimeAlreadyOpen, Runtime.create(testing.allocator));
    try first.destroy();

    for (0..3) |_| {
        const runtime = try Runtime.create(testing.allocator);
        const snapshot = try test_util.snapshotOf(runtime, "const x = () => 1;\n");
        _ = try snapshot.symbols();
        snapshot.destroy();
        try runtime.destroy();
        try testing.expectEqual(alloc_bridge.Stats{ .blocks = 0, .bytes = 0 }, alloc_bridge.stats());
    }
}
