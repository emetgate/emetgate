const std = @import("std");
const sandbox = @import("../src/platform/sandbox.zig");

pub fn printReport(report: sandbox.Report) void {
    switch (report.outcome) {
        .exited, .crashed => |code| std.debug.print("outcome={t} code=0x{X:0>8} killed_leftovers={} duration_ms={d} stderr={s}\n", .{ report.outcome, code, report.killed_leftovers, report.duration_ns / std.time.ns_per_ms, report.stderr }),
        .timed_out, .output_limit => std.debug.print("outcome={t} duration_ms={d} stderr={s}\n", .{ report.outcome, report.duration_ns / std.time.ns_per_ms, report.stderr }),
    }
}

pub fn printResult(result: anytype) void {
    switch (result) {
        .rejected, .typecheck_failed => |report| {
            std.debug.print("result={t} ", .{result});
            printReport(report);
        },
        .rule_violation => |report| {
            std.debug.print("result={t} violations={d}\n", .{ result, report.violations.len });
            for (report.violations) |v| std.debug.print("  rule={s} file={s} line={d} text={s}\n", .{ v.rule, v.file, v.line, v.text });
        },
        .rule_check_failed => |failure| std.debug.print("result={t} rule={s} check={s} file={s} detail={s} text={s}\n", .{ result, failure.rule, failure.check, failure.file, failure.detail, failure.text }),
        .committed => std.debug.print("result={t}\n", .{result}),
    }
}
