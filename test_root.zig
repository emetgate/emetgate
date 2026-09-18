test {
    _ = @import("src/root.zig");
    _ = @import("tests/purple.zig");
    _ = @import("tests/observability.zig");
    _ = @import("tests/readtools.zig");
    _ = @import("tests/server.zig");
    _ = @import("tests/lockdown.zig");
    _ = @import("tests/symbol.zig");
    _ = @import("tests/runner.zig");
    _ = @import("tests/mutate_harness.zig");
    _ = @import("tests/memory.zig");
    _ = @import("tests/scan.zig");
    _ = @import("tests/redteam_memory.zig");
    _ = @import("tests/redteam_sandbox.zig");
    _ = @import("tests/lang/conformance.zig");
}
