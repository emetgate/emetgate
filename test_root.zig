const std = @import("std");
const build_options = @import("build_options");

fn runs(comptime suite: []const u8) bool {
    comptime {
        for (build_options.suites) |built| {
            if (std.mem.eql(u8, built, suite)) break;
        } else @compileError("test suite " ++ suite ++ " is not built by build.zig");
        return std.mem.eql(u8, build_options.suite, "all") or std.mem.eql(u8, build_options.suite, suite);
    }
}

test {
    if (comptime runs("runner")) _ = @import("tests/runner.zig");
    if (comptime runs("runner_rules")) _ = @import("tests/runner_rules.zig");
    if (comptime runs("scan")) _ = @import("tests/scan.zig");
    if (comptime runs("scan")) _ = @import("tests/scan_tool.zig");
    if (comptime runs("redteam")) _ = @import("tests/redteam_memory.zig");
    if (comptime runs("redteam")) _ = @import("tests/redteam_ledger.zig");
    if (comptime runs("redteam")) _ = @import("tests/redteam_sandbox.zig");
    if (comptime runs("purple")) _ = @import("tests/purple.zig");
    if (comptime runs("query")) _ = @import("tests/query.zig");
    if (comptime runs("rule")) _ = @import("tests/rule.zig");
    if (comptime runs("rule")) _ = @import("tests/observability.zig");
    if (comptime runs("rest")) _ = @import("tests/readtools.zig");
    if (comptime runs("rest")) _ = @import("tests/server.zig");
    if (comptime runs("rest")) _ = @import("tests/lockdown.zig");
    if (comptime runs("rest")) _ = @import("tests/symbol.zig");
    if (comptime runs("rest")) _ = @import("tests/mutate_harness.zig");
    if (comptime runs("rest")) _ = @import("tests/memory.zig");
    if (comptime runs("rest")) _ = @import("tests/lang/conformance.zig");
    if (comptime runs("rest")) _ = @import("tests/git_fixture_test.zig");
    if (comptime runs("rest")) _ = @import("tests/suites.zig");
}
