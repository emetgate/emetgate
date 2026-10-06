const std = @import("std");
const verify_run = @import("emetgate").verify_run;
const checker = @import("emetgate").checker;

const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const script = "tools/verify_py/emetgate_verify.py";

const categories = [_]struct { needle: []const u8, name: []const u8 }{
    .{ .needle = "check fails", .name = "tests" },
    .{ .needle = "not rerun", .name = "tests" },
    .{ .needle = "without a check", .name = "tests" },
    .{ .needle = "symbol hash", .name = "symbols" },
    .{ .needle = "intermediate state", .name = "symbols" },
    .{ .needle = "rule", .name = "rules" },
    .{ .needle = "alpha hash", .name = "symmetry" },
    .{ .needle = "before and after the move", .name = "symmetry" },
    .{ .needle = "created or deleted", .name = "symmetry" },
    .{ .needle = "symmetry receipt", .name = "symmetry" },
    .{ .needle = "besides the created", .name = "symmetry" },
    .{ .needle = "does not parse", .name = "symmetry" },
};

fn category(reason: []const u8) ?[]const u8 {
    for (categories) |c| if (std.mem.indexOf(u8, reason, c.needle) != null) return c.name;
    return null;
}

fn rank(verdict: []const u8) u8 {
    if (std.mem.eql(u8, verdict, "verified")) return 0;
    if (std.mem.eql(u8, verdict, "consistent")) return 0;
    if (std.mem.eql(u8, verdict, "unverified")) return 1;
    return 2;
}

fn honest(py_verdict: []const u8, not_checked: []const std.json.Value) bool {
    if (std.mem.eql(u8, py_verdict, "verified")) return not_checked.len == 0;
    if (std.mem.eql(u8, py_verdict, "consistent")) return not_checked.len != 0;
    return true;
}

fn contains(list: []const std.json.Value, name: []const u8) bool {
    for (list) |item| if (item == .string and std.mem.eql(u8, item.string, name)) return true;
    return false;
}

fn allowed(zig_verdict: checker.Verdict, zig_reason: []const u8, py_verdict: []const u8, not_checked: []const std.json.Value) bool {
    if (!honest(py_verdict, not_checked)) return false;
    const z = rank(@tagName(zig_verdict));
    const p = rank(py_verdict);
    if (z == p) return true;
    if (p > z) return false;
    const name = category(zig_reason) orelse return false;
    return contains(not_checked, name);
}

pub const Python = struct {
    exit: u8,
    report: std.json.Value,
};

pub fn run(arena: Allocator, root: []const u8, commit: []const u8) !Python {
    const result = try std.process.run(arena, testing.io, .{ .argv = &.{ "python", script, commit, "--repo", root, "--json" } });
    const code: u8 = switch (result.term) {
        .exited => |c| @intCast(c),
        else => return error.PythonCheckerCrashed,
    };
    if (code != 0 and code != 53 and code != 54 and code != 55 and code != 58) {
        std.debug.print("python checker failed: {s}\n", .{result.stderr});
        return error.PythonCheckerFailed;
    }
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, result.stdout, .{});
    return .{ .exit = code, .report = parsed.value };
}

fn compareMerge(zig: verify_run.Result, py: Python) !void {
    const report = py.report.object;
    const reason = report.get("reason") orelse return error.NVersionDisagreement;
    if (!std.mem.eql(u8, reason.string, zig.report.reason)) return error.NVersionDisagreement;
    if (!std.mem.eql(u8, report.get("verdict").?.string, @tagName(zig.report.verdict))) return error.NVersionDisagreement;
    if (py.exit != verify_run.exitCode(zig.report.verdict)) return error.NVersionDisagreement;
    if (report.get("receipts").?.array.items.len != zig.report.receipts.len) return error.NVersionDisagreement;
    const files = report.get("files").?.array.items;
    if (files.len != zig.report.files.len) return error.NVersionDisagreement;
    for (zig.report.files, files) |f, item| {
        const o = item.object;
        if (!std.mem.eql(u8, o.get("path").?.string, f.path)) return error.NVersionDisagreement;
        if (!std.mem.eql(u8, o.get("verdict").?.string, @tagName(f.outcome.verdict))) return error.NVersionDisagreement;
        if (!std.mem.eql(u8, o.get("reason").?.string, f.outcome.reason)) return error.NVersionDisagreement;
    }
}

pub fn compare(arena: Allocator, root: []const u8, zig: verify_run.Result) !void {
    const py = try run(arena, root, zig.commit);
    const report = py.report.object;
    if (zig.report.reason.len != 0 or report.get("reason") != null) {
        errdefer std.debug.print("zig {t} ({s})\npython: {f}\n", .{ zig.report.verdict, zig.report.reason, std.json.fmt(py.report, .{}) });
        return compareMerge(zig, py);
    }
    const not_checked = report.get("not_checked").?.array.items;
    errdefer {
        std.debug.print("zig verdict {t}\n", .{zig.report.verdict});
        for (zig.report.files) |f| std.debug.print("  zig {s}: {t} ({s})\n", .{ f.path, f.outcome.verdict, f.outcome.reason });
        std.debug.print("python: {f}\n", .{std.json.fmt(py.report, .{})});
    }
    for (zig.report.files) |f| {
        var found = false;
        for (report.get("files").?.array.items) |item| {
            const o = item.object;
            if (!std.mem.eql(u8, o.get("path").?.string, f.path)) continue;
            found = true;
            if (!allowed(f.outcome.verdict, f.outcome.reason, o.get("verdict").?.string, o.get("not_checked").?.array.items)) return error.NVersionDisagreement;
        }
        if (!found) return error.NVersionDisagreement;
    }
    if (report.get("files").?.array.items.len != zig.report.files.len) return error.NVersionDisagreement;
    const py_receipts = report.get("receipts").?.array.items;
    if (py_receipts.len != zig.report.receipts.len) return error.NVersionDisagreement;
    for (zig.report.receipts, py_receipts) |r, item| {
        const o = item.object;
        if (!std.mem.eql(u8, o.get("id").?.string, &r.id)) return error.NVersionDisagreement;
        if (!allowed(r.outcome.verdict, r.outcome.reason, o.get("verdict").?.string, o.get("not_checked").?.array.items)) return error.NVersionDisagreement;
    }
    const overall = report.get("verdict").?.string;
    if (!honest(overall, not_checked)) return error.NVersionDisagreement;
    if (rank(overall) > rank(@tagName(zig.report.verdict))) return error.NVersionDisagreement;
    if (rank(overall) < rank(@tagName(zig.report.verdict))) {
        for (zig.report.files) |f| {
            if (rank(@tagName(f.outcome.verdict)) > rank(overall) and !allowed(f.outcome.verdict, f.outcome.reason, overall, not_checked)) return error.NVersionDisagreement;
        }
    }
    const expected_exit: u8 = if (std.mem.eql(u8, overall, "consistent")) 55 else switch (rank(overall)) {
        0 => 0,
        1 => 53,
        else => 54,
    };
    if (py.exit != expected_exit) return error.NVersionDisagreement;
}

test "n-version: the python checker's blake3 matches the official vectors and its JCS the RFC 8785 cases" {
    const result = try std.process.run(testing.allocator, testing.io, .{ .argv = &.{ "python", "tools/verify_py/selftest.py" } });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    errdefer std.debug.print("{s}{s}\n", .{ result.stdout, result.stderr });
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try testing.expect(std.mem.startsWith(u8, result.stdout, "ok: 35 blake3 vectors"));
}
