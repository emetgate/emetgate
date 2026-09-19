const std = @import("std");
const scan = @import("../platform/scan.zig");
const wire = @import("wire.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;

const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

pub const violations_exit_code: u8 = 10;

pub const ledger_needs_repair_message = "the ledger ends in a partial row; the next call that changes the ledger moves it to quarantine, after which scan runs";

pub const nothing_in_scope_message = "no file inside the scope has a language profile, so nothing was measured";

pub const Options = struct {
    source: scan.Source,
    json: bool,
    pause: scan.Pause = .{},
    max_violations: ?usize = null,
    refusal: ?*?[]const u8 = null,

    pub fn parse(args: []const [:0]const u8) ?Options {
        var options: Options = .{ .source = .ledger, .json = false };
        var check: ?[]const u8 = null;
        var in: ?[]const u8 = null;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--json")) {
                if (options.json) return null;
                options.json = true;
            } else if (std.mem.eql(u8, arg, "--check")) {
                if (check != null or i + 1 >= args.len) return null;
                i += 1;
                check = args[i];
            } else if (std.mem.eql(u8, arg, "--in")) {
                if (in != null or i + 1 >= args.len) return null;
                i += 1;
                in = args[i];
            } else return null;
        }
        if (check) |spec| {
            options.source = .{ .check = .{ .spec = spec, .where = in } };
        } else if (in != null) return null;
        return options;
    }
};

pub fn run(gpa: Allocator, io: std.Io, runtime: *Runtime, root_abs: []const u8, options: Options, out: *Writer, err_out: *Writer) !u8 {
    const enforced = scan.load(gpa, io, root_abs, options.source, options.pause) catch |err| {
        if (err == error.LedgerNeedsRepair) {
            refuse(options, err);
            const code = wire.exitCode(err);
            if (options.json) {
                try wire.writeErrorMessage(out, @errorName(err), code, ledger_needs_repair_message);
            } else {
                try err_out.print("error: {t}: {s}\n", .{ err, ledger_needs_repair_message });
            }
            return code;
        }
        return report(err, options, out, err_out);
    };
    defer enforced.deinit();

    if (scan.firstMalformed(enforced.rules)) |bad| {
        refuse(options, bad.reason);
        const code = wire.exitCode(bad.reason);
        if (options.json) {
            try wire.writeMalformedRule(out, bad.rule.id, bad.rule.check, @errorName(bad.reason), code);
        } else {
            try err_out.print("error: {t}: rule {s} has check \"{s}\"\n", .{ bad.reason, bad.rule.id, bad.rule.check });
        }
        return code;
    }

    const unresolved = scan.firstUnresolved(gpa, io, runtime, root_abs, enforced.rules) catch |err| return report(err, options, out, err_out);
    if (unresolved) |bad| {
        const err = error.ScopeUnresolved;
        refuse(options, err);
        const code = wire.exitCode(err);
        if (options.json) {
            try wire.writeUnresolvedScope(out, bad.rule.id, bad.rule.where.?, @errorName(bad.reason), code);
        } else {
            try err_out.print("error: {t}: rule {s} has scope \"{s}\": {t}\n", .{ err, bad.rule.id, bad.rule.where.?, bad.reason });
        }
        return code;
    }

    const result = scan.scan(gpa, io, runtime, root_abs, enforced.rules) catch |err| return report(err, options, out, err_out);
    defer result.deinit(gpa);

    if (options.json) {
        try wire.writeScan(out, result, options.max_violations);
    } else {
        try writeText(out, result);
    }
    if (result.nothingInScope()) {
        if (!options.json) try out.print("{t}: {s}\n", .{ error.NothingInScope, nothing_in_scope_message });
        return wire.exitCode(error.NothingInScope);
    }
    return if (result.violations.len == 0) 0 else violations_exit_code;
}

fn refuse(options: Options, err: anyerror) void {
    if (options.refusal) |name| name.* = @errorName(err);
}

fn report(err: anyerror, options: Options, out: *Writer, err_out: *Writer) !u8 {
    refuse(options, err);
    const code = wire.exitCode(err);
    if (options.json) {
        try wire.writeError(out, @errorName(err), code);
    } else {
        try err_out.print("error: {t}\n", .{err});
    }
    return code;
}

fn writeText(out: *Writer, result: scan.Result) !void {
    for (result.violations) |v| {
        if (std.mem.eql(u8, v.rule, v.check)) {
            try out.print("{s}:{d}:{d}: {s}: {s}\n", .{ v.file, v.line, v.col, v.rule, v.text });
        } else {
            try out.print("{s}:{d}:{d}: {s} ({s}): {s}\n", .{ v.file, v.line, v.col, v.rule, v.check, v.text });
        }
    }
    for (result.unreadable) |u| try out.print("warning: {s}: not scanned: {t}\n", .{ u.file, u.reason });
    for (result.parse_errors) |file| try out.print("warning: {s}: parse error; tree-based checks may be incomplete\n", .{file});
    const unreadable = result.unreadable.len;
    const tracked = result.scanned + result.out_of_scope + result.unsupported + unreadable;
    try out.print("{d} violation(s) in {d} file(s), {d} rule(s)\n", .{ result.violations.len, filesWithViolations(result), result.rules });
    try out.print("{d} tracked file(s): {d} scanned, {d} outside rule scope, {d} without a language profile, {d} unreadable\n", .{
        tracked,
        result.scanned,
        result.out_of_scope,
        result.unsupported,
        unreadable,
    });
    if (result.parse_errors.len > 0) {
        try out.print("{d} of the {d} scanned file(s) had parse errors; tree-based checks there may be incomplete\n", .{ result.parse_errors.len, result.scanned });
    }
}

fn filesWithViolations(result: scan.Result) usize {
    const violations = result.violations;
    var count: usize = 0;
    for (violations, 0..) |v, i| {
        if (i == 0 or !std.mem.eql(u8, v.file, violations[i - 1].file)) count += 1;
    }
    return count;
}
