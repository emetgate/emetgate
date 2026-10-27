const std = @import("std");
const bounded_run = @import("bounded_run.zig");
const builtin = @import("builtin");
const exe_path = @import("exe_path.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{ RgNotFound, InvalidRegex, RgFailed, OutOfMemory };

pub const Hit = struct {
    file: u32,
    line: u32,
    col: u32,
    text: []const u8,
};

pub const Outcome = struct {
    arena: std.heap.ArenaAllocator,
    hits: []Hit,
    failed: []const u32,

    pub fn deinit(self: *Outcome) void {
        self.arena.deinit();
    }
};

pub const max_command_units: usize = 30_000;
pub const max_output_bytes: usize = 512 * 1024 * 1024;

const fixed_args = [_][]const u8{ "--json", "--no-config", "--no-ignore", "--hidden", "--crlf" };

pub fn find(gpa: Allocator, repo_root: []const u8) Error![]u8 {
    return exe_path.resolve(gpa, "rg", repo_root) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ExecutableNotFound, error.NameInvalid => error.RgNotFound,
    };
}

pub fn search(gpa: Allocator, io: std.Io, rg: []const u8, root: []const u8, pattern: []const u8, files: []const []const u8, diagnostic: *std.Io.Writer) Error!Outcome {
    var outcome: Outcome = .{ .arena = .init(gpa), .hits = &.{}, .failed = &.{} };
    errdefer outcome.arena.deinit();
    const arena = outcome.arena.allocator();
    var index: std.StringHashMapUnmanaged(u32) = .empty;
    for (files, 0..) |f, i| try index.put(arena, f, @intCast(i));

    var hits: std.ArrayList(Hit) = .empty;
    var failed: std.ArrayList(u32) = .empty;
    var argv: std.ArrayList([]const u8) = .empty;
    var at: usize = 0;
    while (at < files.len) {
        argv.clearRetainingCapacity();
        try argv.append(arena, rg);
        try argv.appendSlice(arena, &fixed_args);
        try argv.appendSlice(arena, &.{ "-e", pattern, "--" });
        var units: usize = rg.len + pattern.len + 64;
        for (fixed_args) |a| units += a.len + 1;
        const start = at;
        while (at < files.len and (at == start or units + files[at].len + 3 <= max_command_units)) : (at += 1) {
            units += files[at].len + 3;
            try argv.append(arena, files[at]);
        }
        const result = bounded_run.run(arena, io, .{
            .argv = argv.items,
            .cwd = .{ .path = root },
            .stdout_limit = .limited(max_output_bytes),
            .stderr_limit = .limited(1024 * 1024),
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.RgFailed,
        };
        const code: u8 = switch (result.term) {
            .exited => |c| c,
            else => return error.RgFailed,
        };
        if (code == 2 and result.stdout.len == 0 and isPatternError(result.stderr)) {
            diagnostic.writeAll(firstLine(result.stderr)) catch {};
            return error.InvalidRegex;
        }
        if (code > 2) return error.RgFailed;
        try parseMatches(arena, result.stdout, &index, &hits);
        if (code == 2) try parseFailures(arena, result.stderr, &index, &failed);
    }
    std.mem.sort(Hit, hits.items, {}, lessHit);
    outcome.hits = hits.items;
    outcome.failed = failed.items;
    return outcome;
}

fn lessHit(_: void, a: Hit, b: Hit) bool {
    if (a.file != b.file) return a.file < b.file;
    return a.line < b.line;
}

fn isPatternError(stderr: []const u8) bool {
    return std.mem.indexOf(u8, stderr, "regex parse error") != null or std.mem.indexOf(u8, stderr, "error parsing") != null;
}

fn firstLine(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \r\n");
    return trimmed[0 .. std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len];
}

fn parseMatches(arena: Allocator, stdout: []const u8, index: *const std.StringHashMapUnmanaged(u32), hits: *std.ArrayList(Hit)) Error!void {
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |raw| {
        if (raw.len == 0 or std.mem.indexOf(u8, raw, "\"type\":\"match\"") == null) continue;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch return error.RgFailed;
        const data = field(parsed, "data") orelse return error.RgFailed;
        const path = textOf(arena, field(data, "path") orelse return error.RgFailed) orelse continue;
        const file = index.get(path) orelse continue;
        const number = field(data, "line_number") orelse return error.RgFailed;
        if (number != .integer or number.integer <= 0) return error.RgFailed;
        const body = textOf(arena, field(data, "lines") orelse return error.RgFailed) orelse return error.RgFailed;
        var col: u32 = 0;
        if (field(data, "submatches")) |subs| if (subs == .array and subs.array.items.len != 0) {
            if (field(subs.array.items[0], "start")) |s| if (s == .integer and s.integer >= 0) {
                col = @intCast(s.integer);
            };
        };
        try hits.append(arena, .{ .file = file, .line = @intCast(number.integer), .col = col, .text = std.mem.trimEnd(u8, body, "\r\n") });
    }
}

fn parseFailures(arena: Allocator, stderr: []const u8, index: *const std.StringHashMapUnmanaged(u32), failed: *std.ArrayList(u32)) Error!void {
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        const rest = if (std.mem.startsWith(u8, line, "rg: ")) line[4..] else line;
        const end = std.mem.indexOf(u8, rest, ": ") orelse continue;
        const file = index.get(rest[0..end]) orelse continue;
        if (std.mem.indexOfScalar(u32, failed.items, file) == null) try failed.append(arena, file);
    }
}

fn field(value: std.json.Value, name: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(name);
}

fn textOf(arena: Allocator, value: std.json.Value) ?[]const u8 {
    if (field(value, "text")) |t| if (t == .string) return t.string;
    const bytes = field(value, "bytes") orelse return null;
    if (bytes != .string) return null;
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(bytes.string) catch return null;
    const out = arena.alloc(u8, size) catch return null;
    decoder.decode(out, bytes.string) catch return null;
    return out;
}

const testing = std.testing;

test "rg search: hits come back per file in line order with the match column, and a pattern rg rejects is named" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "src");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/a.ts", .data = "let forget = 1;\r\nforgetful();\r\n  forget it\r\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.ts", .data = "no match here\nforget\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "c.ts", .data = "forget me\n" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const rg = find(testing.allocator, root) catch |err| switch (err) {
        error.RgNotFound => return error.SkipZigTest,
        else => |e| return e,
    };
    defer testing.allocator.free(rg);

    var diag: std.Io.Writer.Allocating = .init(testing.allocator);
    defer diag.deinit();
    const files = [_][]const u8{ "src/a.ts", "b.ts" };
    var outcome = try search(testing.allocator, testing.io, rg, root, "\\bforget\\b", &files, &diag.writer);
    defer outcome.deinit();
    try testing.expectEqual(@as(usize, 3), outcome.hits.len);
    try testing.expectEqual(@as(u32, 0), outcome.hits[0].file);
    try testing.expectEqual(@as(u32, 1), outcome.hits[0].line);
    try testing.expectEqual(@as(u32, 4), outcome.hits[0].col);
    try testing.expectEqualStrings("let forget = 1;", outcome.hits[0].text);
    try testing.expectEqual(@as(u32, 3), outcome.hits[1].line);
    try testing.expectEqualStrings("  forget it", outcome.hits[1].text);
    try testing.expectEqual(@as(u32, 1), outcome.hits[2].file);
    try testing.expectEqual(@as(u32, 2), outcome.hits[2].line);

    try testing.expectError(error.InvalidRegex, search(testing.allocator, testing.io, rg, root, "(unclosed", &files, &diag.writer));
    try testing.expect(diag.written().len != 0);
}
