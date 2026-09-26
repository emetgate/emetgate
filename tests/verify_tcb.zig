const std = @import("std");
const zig_source = @import("zig_source.zig");

const testing = std.testing;

test "verify tcb: the receipt checker reaches no writing code, no platform code and no protocol code" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const files = try zig_source.reachable(arena_state.allocator(), testing.io, std.Io.Dir.cwd(), &.{"src/verify/checker.zig"});
    const forbidden = [_][]const u8{ "src/platform/", "src/protocol/", "src/engine/cas.zig", "src/engine/rename.zig", "src/engine/removal.zig", "src/engine/scope.zig", "src/engine/modules.zig" };
    try testing.expect(files.len > 3);
    for (files) |path| {
        for (forbidden) |prefix| {
            errdefer std.debug.print("the checker reaches {s}\n", .{path});
            try testing.expect(!std.mem.startsWith(u8, path, prefix));
        }
    }
}
