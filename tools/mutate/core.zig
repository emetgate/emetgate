const std = @import("std");

const Allocator = std.mem.Allocator;

pub const max_source_bytes = 64 * 1024 * 1024;

pub const Kind = enum { unit, e2e };

pub const Status = enum { killed, survived, compile_error, no_tests, timeout, other_error };

pub const Summary = struct {
    passed: u32,
    total: u32,
    failed: u32 = 0,
    crashed: u32 = 0,
};

pub const Skip = enum { e2e, survivor };

pub fn skipReason(kind: Kind, expect_status: []const u8, selected: bool, include_e2e: bool, skip_survivors: bool) ?Skip {
    if (selected) return null;
    if (kind == .e2e and !include_e2e) return .e2e;
    if (skip_survivors and std.mem.eql(u8, expect_status, "survived")) return .survivor;
    return null;
}

pub fn timeoutFor(own: ?u64, global: u64) u64 {
    return own orelse global;
}

pub fn writeSummary(w: *std.Io.Writer, run: usize, failures: usize, skipped_e2e: usize, skipped_survivors: usize) std.Io.Writer.Error!void {
    try w.print("{d} mutation(s) run, {d} as expected, {d} not as expected", .{ run, run - failures, failures });
    if (skipped_e2e != 0) try w.print(", {d} e2e mutation(s) skipped (pass --e2e)", .{skipped_e2e});
    if (skipped_survivors != 0) try w.print(", {d} expected survivor(s) skipped (drop --skip-survivors)", .{skipped_survivors});
}

pub fn applyMutation(gpa: Allocator, source: []const u8, from: []const u8, to: []const u8, all: bool) ![]u8 {
    if (from.len == 0) return error.EmptyPattern;
    const count = std.mem.count(u8, source, from);
    if (count == 0) return error.PatternNotFound;
    if (count > 1 and !all) return error.PatternNotUnique;
    const out = try gpa.alloc(u8, source.len - count * from.len + count * to.len);
    _ = std.mem.replace(u8, source, from, to, out);
    return out;
}

pub fn parseSummary(output: []const u8) ?Summary {
    const marker = " tests passed";
    const at = std.mem.lastIndexOf(u8, output, marker) orelse return null;
    const line_start = if (std.mem.lastIndexOfScalar(u8, output[0..at], '\n')) |nl| nl + 1 else 0;
    const line_end = std.mem.indexOfScalarPos(u8, output, at, '\n') orelse output.len;
    const head = output[line_start..at];
    const token_start = if (std.mem.lastIndexOfAny(u8, head, " ;")) |i| i + 1 else 0;
    const ratio = head[token_start..];
    const slash = std.mem.indexOfScalar(u8, ratio, '/') orelse return null;
    const passed = std.fmt.parseInt(u32, ratio[0..slash], 10) catch return null;
    const total = std.fmt.parseInt(u32, ratio[slash + 1 ..], 10) catch return null;
    const tail = output[at..line_end];
    return .{ .passed = passed, .total = total, .failed = numberBefore(tail, " failed"), .crashed = numberBefore(tail, " crashed") };
}

fn numberBefore(text: []const u8, word: []const u8) u32 {
    const at = std.mem.indexOf(u8, text, word) orelse return 0;
    var start = at;
    while (start > 0 and std.ascii.isDigit(text[start - 1])) start -= 1;
    return std.fmt.parseInt(u32, text[start..at], 10) catch 0;
}

const failure_prefix = "error: '";
const failure_suffixes = [_][]const u8{ "' failed", "' exited with code" };

fn failedTestName(raw: []const u8) ?[]const u8 {
    const line = std.mem.trim(u8, raw, " \r");
    if (!std.mem.startsWith(u8, line, failure_prefix)) return null;
    for (failure_suffixes) |suffix| {
        const close = std.mem.lastIndexOf(u8, line, suffix) orelse continue;
        if (close > failure_prefix.len) return line[failure_prefix.len..close];
    }
    return null;
}

pub fn failedTests(gpa: Allocator, output: []const u8) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(gpa);
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const name = failedTestName(raw) orelse continue;
        for (names.items) |seen| {
            if (std.mem.eql(u8, seen, name)) break;
        } else try names.append(gpa, name);
    }
    return names.toOwnedSlice(gpa);
}

pub fn missingKill(failed: []const []const u8, expected: []const []const u8) ?[]const u8 {
    outer: for (expected) |want| {
        for (failed) |got| {
            if (std.mem.eql(u8, got, want)) continue :outer;
            if (got.len > want.len and std.mem.endsWith(u8, got, want) and std.mem.endsWith(u8, got[0 .. got.len - want.len], ".test.")) continue :outer;
        }
        return want;
    }
    return null;
}

pub fn unexpectedKill(failed: []const []const u8, expected: []const []const u8) ?[]const u8 {
    for (failed) |got| {
        for (expected) |want| {
            if (std.mem.eql(u8, got, want)) break;
            if (got.len > want.len and std.mem.endsWith(u8, got, want) and std.mem.endsWith(u8, got[0 .. got.len - want.len], ".test.")) break;
        } else return got;
    }
    return null;
}

pub fn classify(kind: Kind, exit_code: u8, output: []const u8) Status {
    if (exit_code == 0) {
        if (kind == .e2e) return .survived;
        const summary = parseSummary(output) orelse return .no_tests;
        return if (summary.total == 0) .no_tests else .survived;
    }
    if (isCompileError(output)) return .compile_error;
    switch (kind) {
        .unit => {
            if (parseSummary(output)) |s| {
                if (s.failed + s.crashed > 0) return .killed;
            }
            if (hasFailedTestLine(output)) return .killed;
            return .other_error;
        },
        .e2e => {
            if (std.mem.indexOf(u8, output, "e2e-lockdown: ") != null and std.mem.indexOf(u8, output, " failure(s)") != null) return .killed;
            return .other_error;
        },
    }
}

fn isCompileError(output: []const u8) bool {
    return std.mem.indexOf(u8, output, " compilation error") != null;
}

fn hasFailedTestLine(output: []const u8) bool {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        if (failedTestName(raw) != null) return true;
    }
    return false;
}

pub const Journal = struct {
    dir: std.Io.Dir,
    io: std.Io,

    const path_name = "pending.path";
    const original_name = "pending.orig";

    pub fn record(self: Journal, file_path: []const u8, original: []const u8) !void {
        try self.dir.writeFile(self.io, .{ .sub_path = original_name, .data = original });
        try self.dir.writeFile(self.io, .{ .sub_path = path_name, .data = file_path });
    }

    pub fn clear(self: Journal) void {
        self.dir.deleteFile(self.io, path_name) catch {};
        self.dir.deleteFile(self.io, original_name) catch {};
    }

    pub fn recover(self: Journal, gpa: Allocator, root: std.Io.Dir) !?[]u8 {
        const file_path = self.dir.readFileAlloc(self.io, path_name, gpa, .limited(std.fs.max_path_bytes)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        errdefer gpa.free(file_path);
        const original = try self.dir.readFileAlloc(self.io, original_name, gpa, .limited(max_source_bytes));
        defer gpa.free(original);
        try root.writeFile(self.io, .{ .sub_path = file_path, .data = original });
        self.clear();
        return file_path;
    }
};
