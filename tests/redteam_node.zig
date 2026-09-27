const std = @import("std");
const builtin = @import("builtin");
const handlers = @import("emetgate").handlers;
const telemetry = @import("emetgate").telemetry;
const Runtime = @import("emetgate").runtime.Runtime;
const fixture = @import("ts_fixture.zig");
const mirror_mod = @import("emetgate").mirror;

const testing = std.testing;
const Value = std.json.Value;

const math_src =
    \\export function clamp(x: number): number {
    \\  if (x > 10) {
    \\    return 10;
    \\  }
    \\  /* keep in sync with the docs */
    \\  return x;
    \\}
    \\export function twice(x: number): number {
    \\  const doubled = x * 2;
    \\  return doubled;
    \\}
    \\export function half(x: number): number {
    \\  const doubled = x * 2;
    \\  return x / 2;
    \\}
    \\export function logged(x: number): number {
    \\  note(x); /* first */
    \\  return x + 0; /* second */
    \\}
    \\
;
const use_src = "import { twice } from \"./math\";\nexport const four = twice(2);\n";
const other_src = "export function add(a: number, b: number): number {\n  return a + b;\n}\n";
const green = "cmd /c exit 0";

const Case = struct {
    repo: fixture.TsRepo,
    runtime: *Runtime,
    arena_state: std.heap.ArenaAllocator,

    fn init(self: *Case) !void {
        self.repo = try fixture.TsRepo.init(&.{
            .{ .rel = "src/math.ts", .text = math_src },
            .{ .rel = "src/use.ts", .text = use_src },
            .{ .rel = "src/other.ts", .text = other_src },
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

    fn call(self: *Case, tool: []const u8, args: std.json.ObjectMap) !Reply {
        var event: telemetry.Event = .{ .tool = tool };
        const result = try handlers.callTool(testing.allocator, testing.io, self.runtime, tool, .{ .object = args }, &event, .{ .root = self.repo.root_abs, .test_command = green });
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

    fn address(self: *Case, file: []const u8, symbol_ref: []const u8, line: []const u8) ![]const u8 {
        const reply = try self.call("emetgate_read_symbol", try self.object(.{ .file = file, .symbol = symbol_ref, .nodes = true }));
        errdefer std.debug.print("{s}\n", .{reply.text});
        try testing.expect(!reply.is_error);
        const parsed = try std.json.parseFromSliceLeaky(Value, self.arena(), reply.text, .{});
        var lines = std.mem.splitScalar(u8, parsed.object.get("nodes").?.string, '\n');
        while (lines.next()) |candidate| {
            const bar = std.mem.indexOfScalar(u8, candidate, '|') orelse continue;
            if (std.mem.eql(u8, std.mem.trim(u8, candidate[bar + 1 ..], " "), line)) return candidate[0..bar];
        }
        return error.NoAddress;
    }

    fn tryNode(self: *Case, file: []const u8, node: []const u8, text: []const u8) !Reply {
        return self.call("emetgate_try", try self.object(.{ .file = file, .node = node, .text = text }));
    }

    fn expectRefused(self: *Case, reply: Reply, err: []const u8, rel: []const u8, expected: []const u8) !void {
        errdefer std.debug.print("{s}\n", .{reply.text});
        try testing.expect(reply.is_error);
        try testing.expect(std.mem.indexOf(u8, reply.text, err) != null);
        const on_disk = try self.repo.read(rel);
        defer testing.allocator.free(on_disk);
        try testing.expectEqualStrings(expected, on_disk);
    }
};

test "redteam node: a stale node hash is refused after its node or a child of it changed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();

    const block = try case.address("src/math.ts", "clamp", "if (x > 10) {");
    const inner = try case.address("src/math.ts", "clamp", "return 10;");
    const first = try case.tryNode("src/math.ts", inner, "return 11;");
    errdefer std.debug.print("{s}\n", .{first.text});
    try testing.expect(!first.is_error);
    const after = try std.mem.replaceOwned(u8, case.arena(), math_src, "return 10;", "return 11;");

    try case.expectRefused(try case.tryNode("src/math.ts", inner, "return 12;"), "HashMismatch", "src/math.ts", after);
    try case.expectRefused(try case.tryNode("src/math.ts", block, "if (x > 10) {\n    return 0;\n  }"), "HashMismatch", "src/math.ts", after);
}

test "redteam node: text that spills out of its node is a BodyEscape, including a comment that swallows its neighbours" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();

    const ret = try case.address("src/math.ts", "clamp", "return x;");
    const spills = [_][]const u8{
        "return x;\n}\nexport function evil(): number {\n  return 0;",
        "return x; /*",
        "return x; } function evil() {",
    };
    for (spills) |text| {
        const reply = try case.tryNode("src/math.ts", ret, text);
        errdefer std.debug.print("accepted: {s}\n", .{text});
        try testing.expect(reply.is_error);
        try testing.expect(std.mem.indexOf(u8, reply.text, "BodyEscape") != null or std.mem.indexOf(u8, reply.text, "MutationSyntaxInvalid") != null);
        const on_disk = try case.repo.read("src/math.ts");
        defer testing.allocator.free(on_disk);
        try testing.expectEqualStrings(math_src, on_disk);
    }
    const block = try case.address("src/math.ts", "clamp", "if (x > 10) {");
    try case.expectRefused(try case.tryNode("src/math.ts", block, "if (x > 10) {\n    return 10;\n  } /*"), "BodyEscape", "src/math.ts", math_src);
}

test "redteam node: text for one node cannot reshape the neighbour next to it" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();

    const ret = try case.address("src/math.ts", "twice", "return doubled;");
    const cases = [_][]const u8{
        "return doubled;\n}\nexport function twice2(x: number): number {\n  return x;",
        "return doubled; }\nexport function extra(): number { return 1;",
    };
    for (cases) |text| {
        const reply = try case.tryNode("src/math.ts", ret, text);
        errdefer std.debug.print("accepted: {s}\n{s}\n", .{ text, reply.text });
        try testing.expect(reply.is_error);
        const on_disk = try case.repo.read("src/math.ts");
        defer testing.allocator.free(on_disk);
        try testing.expectEqualStrings(math_src, on_disk);
    }

    const noted = try case.address("src/math.ts", "logged", "note(x); /* first */");
    try case.expectRefused(try case.tryNode("src/math.ts", noted, "note(x); /*"), "BodyEscape", "src/math.ts", math_src);

    var items = std.json.Array.init(case.arena());
    const inner = try case.address("src/math.ts", "clamp", "return 10;");
    try items.append(.{ .object = try case.object(.{ .node = inner, .text = "return 10; }\n  if (x < 0) {\n    return 0;" }) });
    const reply = try case.call("emetgate_try", try case.object(.{ .file = "src/math.ts", .nodes = Value{ .array = items } }));
    try case.expectRefused(reply, "BodyEscape", "src/math.ts", math_src);
}

test "redteam node: an address from another file, a shared one or one that lands in another symbol is caught or reported" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();

    const foreign = try case.address("src/other.ts", "add", "return a + b;");
    try case.expectRefused(try case.tryNode("src/math.ts", foreign, "return 0;"), "HashMismatch", "src/math.ts", math_src);

    const shared = case.address("src/math.ts", "twice", "const doubled = x * 2;");
    try testing.expectError(error.NoAddress, shared);

    const in_half = try case.address("src/math.ts", "half", "return x / 2;");
    const reply = try case.tryNode("src/math.ts", in_half, "return x * 0.5;");
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    const parsed = try std.json.parseFromSliceLeaky(Value, case.arena(), reply.text, .{});
    const symbols = parsed.object.get("symbols").?.array.items;
    try testing.expectEqual(@as(usize, 1), symbols.len);
    try testing.expectEqualStrings("half", symbols[0].object.get("symbol").?.string);
    const on_disk = try case.repo.read("src/math.ts");
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(try std.mem.replaceOwned(u8, case.arena(), math_src, "return x / 2;", "return x * 0.5;"), on_disk);
}

test "redteam node: deleting a function that is still called is refused unless the call goes in the same batch" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();

    const whole = try case.address("src/math.ts", "twice", "export function twice(x: number): number {");
    try case.expectRefused(try case.tryNode("src/math.ts", whole, ""), "SymbolReferenced", "src/math.ts", math_src);

    const use_reply = try case.call("emetgate_read_symbol", try case.object(.{ .file = "src/use.ts", .line_start = Value{ .integer = 1 }, .line_end = Value{ .integer = 2 }, .nodes = true }));
    try testing.expect(!use_reply.is_error);
    const parsed = try std.json.parseFromSliceLeaky(Value, case.arena(), use_reply.text, .{});
    var import_address: ?[]const u8 = null;
    var const_address: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, parsed.object.get("nodes").?.string, '\n');
    while (lines.next()) |candidate| {
        const bar = std.mem.indexOfScalar(u8, candidate, '|') orelse continue;
        if (std.mem.startsWith(u8, candidate[bar + 1 ..], "import")) import_address = candidate[0..bar];
        if (std.mem.startsWith(u8, candidate[bar + 1 ..], "export const")) const_address = candidate[0..bar];
    }

    var use_nodes = std.json.Array.init(case.arena());
    try use_nodes.append(.{ .object = try case.object(.{ .node = import_address.?, .text = "" }) });
    try use_nodes.append(.{ .object = try case.object(.{ .node = const_address.?, .text = "export const four = 4;" }) });
    var items = std.json.Array.init(case.arena());
    try items.append(.{ .object = try case.object(.{ .file = "src/math.ts", .node = whole, .text = "" }) });
    try items.append(.{ .object = try case.object(.{ .file = "src/use.ts", .nodes = Value{ .array = use_nodes } }) });
    const reply = try case.call("emetgate_try_batch", try case.object(.{ .edits = Value{ .array = items } }));
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    const math_after = try case.repo.read("src/math.ts");
    defer testing.allocator.free(math_after);
    try testing.expect(std.mem.indexOf(u8, math_after, "twice") == null);
}

test "redteam node: the node form cannot create a file or target one file twice in a batch" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();

    const ret = try case.address("src/math.ts", "clamp", "return x;");
    const missing = try case.tryNode("src/new.ts", ret, "return x;");
    try testing.expect(missing.is_error);
    try testing.expect(!case.repo.exists("src/new.ts"));

    var items = std.json.Array.init(case.arena());
    try items.append(.{ .object = try case.object(.{ .file = "src/math.ts", .node = ret, .text = "return 1;" }) });
    try items.append(.{ .object = try case.object(.{ .file = "src/math.ts", .node = ret, .text = "return 2;" }) });
    const twice_reply = try case.call("emetgate_try_batch", try case.object(.{ .edits = Value{ .array = items } }));
    try case.expectRefused(twice_reply, "DuplicateBatchFile", "src/math.ts", math_src);
}

test "redteam node: a mirrored body read never hides node hashes, and symbols with nodes annotates each declaration" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    var mirror: mirror_mod.Mirror = .init(testing.allocator, true);
    defer mirror.deinit();

    const plain = try case.object(.{ .file = "src/math.ts", .symbol = "clamp" });
    for (0..2) |_| {
        var event: telemetry.Event = .{ .tool = "emetgate_read_symbol" };
        const result = try handlers.callTool(testing.allocator, testing.io, case.runtime, "emetgate_read_symbol", .{ .object = plain }, &event, .{ .root = case.repo.root_abs, .test_command = green, .mirror = &mirror, .mirror_enabled = true });
        testing.allocator.free(result.text);
    }
    var event: telemetry.Event = .{ .tool = "emetgate_read_symbol" };
    const annotated = try handlers.callTool(testing.allocator, testing.io, case.runtime, "emetgate_read_symbol", .{ .object = try case.object(.{ .file = "src/math.ts", .symbol = "clamp", .nodes = true }) }, &event, .{ .root = case.repo.root_abs, .test_command = green, .mirror = &mirror, .mirror_enabled = true });
    defer testing.allocator.free(annotated.text);
    errdefer std.debug.print("{s}\n", .{annotated.text});
    try testing.expect(std.mem.indexOf(u8, annotated.text, "|export function clamp") != null);

    var list = std.json.Array.init(case.arena());
    try list.append(.{ .string = "clamp" });
    try list.append(.{ .string = "half" });
    const both = try case.call("emetgate_read_symbol", try case.object(.{ .file = "src/math.ts", .symbols = Value{ .array = list }, .nodes = true }));
    errdefer std.debug.print("{s}\n", .{both.text});
    try testing.expect(!both.is_error);
    const parsed = try std.json.parseFromSliceLeaky(Value, case.arena(), both.text, .{});
    const entries = parsed.object.get("symbols").?.array.items;
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expect(std.mem.indexOf(u8, entries[0].object.get("nodes").?.string, "|  if (x > 10) {") != null);
    try testing.expect(std.mem.indexOf(u8, entries[1].object.get("nodes").?.string, "|  return x / 2;") != null);
}
