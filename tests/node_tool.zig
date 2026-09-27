const std = @import("std");
const builtin = @import("builtin");
const symbol = @import("emetgate").symbol;
const handlers = @import("emetgate").handlers;
const telemetry = @import("emetgate").telemetry;
const receipts = @import("emetgate").receipts;
const verify_run = @import("emetgate").verify_run;
const checker = @import("emetgate").checker;
const memory = @import("emetgate").memory;
const Runtime = @import("emetgate").runtime.Runtime;
const fixture = @import("ts_fixture.zig");
const support = @import("runner_support.zig");

const testing = std.testing;
const TsRepo = fixture.TsRepo;
const Value = std.json.Value;

const math_src =
    \\const limit = 10;
    \\export function clamp(x: number): number {
    \\  if (x > limit) {
    \\    return limit;
    \\  }
    \\  return x;
    \\}
    \\export function twice(x: number): number {
    \\  return x * 2;
    \\}
    \\
;
const util_src = "export function add(a: number, b: number): number {\n  return a + b;\n}\n";
const green = "cmd /c exit 0";

const Case = struct {
    repo: TsRepo,
    runtime: *Runtime,
    arena_state: std.heap.ArenaAllocator,

    fn init(self: *Case) !void {
        self.repo = try TsRepo.init(&.{
            .{ .rel = "src/math.ts", .text = math_src },
            .{ .rel = "src/util.ts", .text = util_src },
            .{ .rel = ".gitignore", .text = ".emetgate/\n" },
        });
        errdefer self.repo.deinit();
        self.runtime = try Runtime.create(testing.allocator);
        self.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    }

    fn deinit(self: *Case) void {
        self.arena_state.deinit();
        self.runtime.destroy() catch @panic("live snapshots");
        self.repo.deinit();
    }

    fn arena(self: *Case) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    const Reply = struct { text: []const u8, is_error: bool };

    fn call(self: *Case, tool: []const u8, args: std.json.ObjectMap, test_command: []const u8) !Reply {
        var event: telemetry.Event = .{ .tool = tool };
        const result = try handlers.callTool(testing.allocator, testing.io, self.runtime, tool, .{ .object = args }, &event, .{ .root = self.repo.root_abs, .test_command = test_command });
        defer testing.allocator.free(result.text);
        return .{ .text = try self.arena().dupe(u8, result.text), .is_error = result.is_error };
    }

    fn object(self: *Case, fields: anytype) !std.json.ObjectMap {
        var map: std.json.ObjectMap = .empty;
        inline for (std.meta.fields(@TypeOf(fields))) |field| {
            const value = @field(fields, field.name);
            const json: Value = switch (@TypeOf(value)) {
                Value => value,
                bool => .{ .bool = value },
                else => .{ .string = if (comptime std.mem.eql(u8, field.name, "file")) try self.repo.abs(self.arena(), value) else value },
            };
            try map.put(self.arena(), field.name, json);
        }
        return map;
    }

    fn annotated(self: *Case, symbol_ref: []const u8) ![]const u8 {
        const reply = try self.call("emetgate_read_symbol", try self.object(.{ .file = "src/math.ts", .symbol = symbol_ref, .nodes = true }), green);
        errdefer std.debug.print("{s}\n", .{reply.text});
        try testing.expect(!reply.is_error);
        const parsed = try std.json.parseFromSliceLeaky(Value, self.arena(), reply.text, .{});
        return parsed.object.get("nodes").?.string;
    }

    fn address(self: *Case, symbol_ref: []const u8, line: []const u8) ![]const u8 {
        const text = try self.annotated(symbol_ref);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |candidate| {
            const bar = std.mem.indexOfScalar(u8, candidate, '|') orelse continue;
            if (std.mem.eql(u8, std.mem.trim(u8, candidate[bar + 1 ..], " "), line)) return candidate[0..bar];
        }
        std.debug.print("no node hash on {s} in:\n{s}\n", .{ line, text });
        return error.NoAddress;
    }

    fn expectFile(self: *Case, rel: []const u8, expected: []const u8) !void {
        const on_disk = try self.repo.read(rel);
        defer testing.allocator.free(on_disk);
        try testing.expectEqualStrings(expected, on_disk);
    }
};

test "node edit: read_symbol with nodes gives hash|code lines and a node try commits exactly that node with a receipt that verifies" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();

    const text = try case.annotated("clamp");
    try testing.expect(std.mem.indexOf(u8, text, "|export function clamp(x: number): number {") != null);
    try testing.expect(std.mem.indexOf(u8, text, "|  if (x > limit) {") != null);

    const address = try case.address("clamp", "return x;");
    const reply = try case.call("emetgate_try", try case.object(.{ .file = "src/math.ts", .node = address, .text = "return Math.max(x, 0);" }), green);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try case.expectFile("src/math.ts", std.mem.replaceOwned(u8, case.arena(), math_src, "  return x;\n}\nexport function twice", "  return Math.max(x, 0);\n}\nexport function twice") catch unreachable);

    const parsed = try std.json.parseFromSliceLeaky(Value, case.arena(), reply.text, .{});
    try testing.expectEqualStrings("committed", parsed.object.get("status").?.string);
    const nodes = parsed.object.get("nodes").?.array.items;
    try testing.expectEqual(@as(usize, 1), nodes.len);
    try testing.expectEqual(@as(usize, 1), nodes[0].array.items.len);
    const symbols = parsed.object.get("symbols").?.array.items;
    try testing.expectEqual(@as(usize, 1), symbols.len);
    try testing.expectEqualStrings("clamp", symbols[0].object.get("symbol").?.string);
    try testing.expect(parsed.object.get("receipt") == null);
    try testing.expect(parsed.object.get("shadow") == null);

    const chained = try case.call("emetgate_try", try case.object(.{ .file = "src/math.ts", .node = nodes[0].array.items[0].string, .text = "return Math.max(x, 1);", .detail = "full" }), green);
    try testing.expect(!chained.is_error);
    const chained_parsed = try std.json.parseFromSliceLeaky(Value, case.arena(), chained.text, .{});
    try testing.expect(chained_parsed.object.get("receipt") != null);

    try support.Repo.git(case.repo.root_abs, &.{ "add", "-A" });
    try support.Repo.git(case.repo.root_abs, &.{ "commit", "-q", "-m", "node edits" });
    try testing.expectEqual(@as(usize, 2), (try receipts.attach(testing.allocator, testing.io, case.repo.root_abs, "HEAD")).count);
    const result = try verify_run.run(testing.allocator, case.arena(), testing.io, case.runtime, case.repo.root_abs, .{ .commit = "HEAD", .test_command = green });
    try testing.expect(result.report.verdict != .mismatch);
}

test "node edit: a failing test, a stale hash, an ambiguous or mixed request leave the file untouched" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const address = try case.address("clamp", "return x;");

    const red = try case.call("emetgate_try", try case.object(.{ .file = "src/math.ts", .node = address, .text = "return -x;" }), "cmd /c exit 1");
    try testing.expect(red.is_error);
    try case.expectFile("src/math.ts", math_src);

    const Refused = struct { args: std.json.ObjectMap, err: []const u8 };
    const refused = [_]Refused{
        .{ .args = try case.object(.{ .file = "src/math.ts", .node = "0123456789ab", .text = "return 1;" }), .err = "HashMismatch" },
        .{ .args = try case.object(.{ .file = "src/math.ts", .node = address, .text = "return 1;", .symbol = "clamp" }), .err = "MixedEditForms" },
        .{ .args = try case.object(.{ .file = "src/math.ts", .node = address[0..6], .text = "return 1;" }), .err = "InvalidHash" },
        .{ .args = try case.object(.{ .file = "src/math.ts", .node = address, .text = "return 1; }\nexport function evil() { return 2;" }), .err = "BodyEscape" },
        .{ .args = try case.object(.{ .file = "src/math.ts", .node = address, .text = "// ...existing code..." }), .err = "PlaceholderBody" },
        .{ .args = try case.object(.{ .file = "../outside.ts", .node = address, .text = "return 1;" }), .err = "" },
    };
    for (refused) |r| {
        const reply = try case.call("emetgate_try", r.args, green);
        errdefer std.debug.print("{s}\n", .{reply.text});
        try testing.expect(reply.is_error);
        if (r.err.len != 0) try testing.expect(std.mem.indexOf(u8, reply.text, r.err) != null);
        try case.expectFile("src/math.ts", math_src);
    }
}

test "node edit: a top-level statement is still held to a file-scoped enforced rule" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const id = try memory.remember(testing.allocator, testing.io, case.repo.root_abs, .global, "no eval in math", true, "forbid:eval(", "src/math.ts");
    defer testing.allocator.free(id);
    const other = try memory.remember(testing.allocator, testing.io, case.repo.root_abs, .global, "no Number in twice", true, "forbid:Number(", "src/math.ts#twice");
    defer testing.allocator.free(other);

    const limit_address = try topLevelAddress(&case, "const limit = 10;");
    const evil = try case.call("emetgate_try", try case.object(.{ .file = "src/math.ts", .node = limit_address, .text = "const limit = eval(\"10\");" }), green);
    try testing.expect(evil.is_error);
    try testing.expect(std.mem.indexOf(u8, evil.text, "rule_violation") != null);
    try case.expectFile("src/math.ts", math_src);

    const clean = try case.call("emetgate_try", try case.object(.{ .file = "src/math.ts", .node = limit_address, .text = "const limit = Number(\"10\");" }), green);
    errdefer std.debug.print("{s}\n", .{clean.text});
    try testing.expect(!clean.is_error);
}

fn topLevelAddress(case: *Case, line: []const u8) ![]const u8 {
    const reply = try case.call("emetgate_read_symbol", try case.object(.{ .file = "src/math.ts", .line_start = Value{ .integer = 1 }, .line_end = Value{ .integer = 1 }, .nodes = true }), green);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    const parsed = try std.json.parseFromSliceLeaky(Value, case.arena(), reply.text, .{});
    var lines = std.mem.splitScalar(u8, parsed.object.get("nodes").?.string, '\n');
    while (lines.next()) |candidate| {
        const bar = std.mem.indexOfScalar(u8, candidate, '|') orelse continue;
        if (std.mem.eql(u8, candidate[bar + 1 ..], line)) return candidate[0..bar];
    }
    return error.NoAddress;
}

test "node edit: try_batch commits a node edit and a symbol edit in two files together" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const address = try case.address("twice", "return x * 2;");
    const util_abs = try case.repo.abs(case.arena(), "src/util.ts");
    const add_hash = symbol.formatHash(try support.hashOfRef(testing.allocator, testing.io, case.runtime, util_abs, "add"));

    var items = std.json.Array.init(case.arena());
    try items.append(.{ .object = try case.object(.{ .file = "src/math.ts", .node = address, .text = "return x + x;" }) });
    try items.append(.{ .object = try case.object(.{ .file = "src/util.ts", .symbol = "add", .hash = @as([]const u8, &add_hash), .body = "{\n  return b + a;\n}" }) });
    const reply = try case.call("emetgate_try_batch", try case.object(.{ .edits = Value{ .array = items } }), green);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try case.expectFile("src/math.ts", std.mem.replaceOwned(u8, case.arena(), math_src, "return x * 2;", "return x + x;") catch unreachable);
    try case.expectFile("src/util.ts", "export function add(a: number, b: number): number {\n  return b + a;\n}\n");
    const parsed = try std.json.parseFromSliceLeaky(Value, case.arena(), reply.text, .{});
    const edits = parsed.object.get("edits").?.array.items;
    try testing.expect(edits[0].object.get("nodes") != null);
    try testing.expect(edits[1].object.get("new_hash") != null);

    var red_items = std.json.Array.init(case.arena());
    const second = try case.address("clamp", "return x;");
    try red_items.append(.{ .object = try case.object(.{ .file = "src/math.ts", .node = second, .text = "return 0;" }) });
    const red = try case.call("emetgate_try_batch", try case.object(.{ .edits = Value{ .array = red_items } }), "cmd /c exit 1");
    try testing.expect(red.is_error);
}
