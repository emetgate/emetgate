const std = @import("std");
const builtin = @import("builtin");
const symbol = @import("emetgate").symbol;
const handlers = @import("emetgate").handlers;
const server = @import("emetgate").server;
const telemetry = @import("emetgate").telemetry;
const recovery = @import("emetgate").recovery;
const Runtime = @import("emetgate").runtime.Runtime;
const fixture = @import("ts_fixture.zig");
const support = @import("runner_support.zig");

const testing = std.testing;
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
const notes_src = "# Notes\n\nfirst\n";
const green = "cmd /c exit 0";

const Case = struct {
    repo: fixture.TsRepo,
    runtime: *Runtime,
    arena_state: std.heap.ArenaAllocator,

    fn init(self: *Case) !void {
        self.repo = try fixture.TsRepo.init(&.{
            .{ .rel = "src/math.ts", .text = math_src },
            .{ .rel = "src/util.ts", .text = util_src },
            .{ .rel = "notes.md", .text = notes_src },
            .{ .rel = "plain.txt", .text = "a\nb\n" },
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

    fn abs(self: *Case, rel: []const u8) ![]const u8 {
        return self.repo.abs(self.arena(), rel);
    }

    fn fix(self: *Case, tool: []const u8, arguments: Value) ![]const u8 {
        var event: telemetry.Event = .{ .tool = tool };
        const result = try handlers.callTool(testing.allocator, testing.io, self.runtime, tool, arguments, &event, .{ .root = self.repo.root_abs, .test_command = green });
        defer testing.allocator.free(result.text);
        errdefer std.debug.print("{s}\n", .{result.text});
        try testing.expect(result.is_error);
        const parsed = try std.json.parseFromSliceLeaky(Value, self.arena(), result.text, .{ .allocate = .alloc_always });
        return parsed.object.get("fix").?.string;
    }

    fn parse(self: *Case, json: []const u8) !Value {
        return std.json.parseFromSliceLeaky(Value, self.arena(), json, .{ .allocate = .alloc_always });
    }

    fn args(self: *Case, comptime fmt: []const u8, values: anytype) !Value {
        return self.parse(try std.fmt.allocPrint(self.arena(), fmt, values));
    }

    fn escaped(self: *Case, rel: []const u8) ![]const u8 {
        const path = try self.abs(rel);
        return std.mem.replaceOwned(u8, self.arena(), path, "\\", "\\\\");
    }
};

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    errdefer std.debug.print("missing {s} in {s}\n", .{ needle, haystack });
    try testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

test "recovery hints: a stale symbol hash is answered with the current hash" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const current = symbol.formatHash(try support.hashOfRef(testing.allocator, testing.io, case.runtime, try case.abs("src/math.ts"), "clamp"));
    const stale = "0123456789abcdef0123456789abcdef";
    const fix = try case.fix("emetgate_try", try case.args("{{\"file\":\"{s}\",\"symbol\":\"clamp\",\"hash\":\"{s}\",\"body\":\"{{ return x; }}\"}}", .{ try case.escaped("src/math.ts"), stale }));
    try expectContains(fix, "the current hash of clamp is ");
    try expectContains(fix, &current);
}

test "recovery hints: a symbol hash sent as a node id is named as such" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const current = symbol.formatHash(try support.hashOfRef(testing.allocator, testing.io, case.runtime, try case.abs("src/math.ts"), "twice"));
    const fix = try case.fix("emetgate_try", try case.args("{{\"file\":\"{s}\",\"node\":\"{s}\",\"text\":\"return 1;\"}}", .{ try case.escaped("src/math.ts"), &current }));
    try expectContains(fix, "is the symbol hash of twice, not a node id");

    const unknown = try case.fix("emetgate_try", try case.args("{{\"file\":\"{s}\",\"nodes\":[{{\"node\":\"0123456789ab\",\"text\":\"return 1;\"}}]}}", .{try case.escaped("src/math.ts")}));
    try expectContains(unknown, "node 0123456789ab is not in");
}

test "recovery hints: deleting a file without its hash is answered with its file_hash" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const current = symbol.formatHash(symbol.fileHash(util_src));
    const missing = try case.fix("emetgate_try_batch", try case.args("{{\"edits\":[{{\"file\":\"{s}\",\"op\":\"delete\"}}]}}", .{try case.escaped("src/util.ts")}));
    try expectContains(missing, &current);
    try expectContains(missing, "pass it as hash to delete the file");

    const stale = try case.fix("emetgate_try_batch", try case.args("{{\"edits\":[{{\"file\":\"{s}\",\"op\":\"delete\",\"hash\":\"0123456789abcdef0123456789abcdef\"}}]}}", .{try case.escaped("src/util.ts")}));
    try expectContains(stale, &current);
}

test "recovery hints: write_doc with hash absent points at creating the file instead" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const fix = try case.fix("emetgate_write_doc", try case.args("{{\"file\":\"{s}\",\"hash\":\"absent\",\"content\":\"# Notes\\n\",\"heading\":\"Notes\"}}", .{try case.escaped("notes.md")}));
    try expectContains(fix, "create a new file with emetgate_write");
}

test "recovery hints: an error without a computed hint carries the static fix line" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const fix = try case.fix("emetgate_symbols", try case.args("{{\"file\":\"{s}\"}}", .{try case.escaped("src/missing.ts")}));
    try testing.expect(fix.len > 0);
}

fn rpcMessage(line: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    _ = try server.handleMessage(testing.allocator, testing.io, undefined, line, &out.writer);
    const parsed = try std.json.parseFromSlice(Value, testing.allocator, out.written(), .{});
    defer parsed.deinit();
    return testing.allocator.dupe(u8, parsed.value.object.get("error").?.object.get("message").?.string);
}

test "recovery hints: a missing argument names the field and its type" {
    const cases = [_][2][]const u8{
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"emetgate_try\",\"arguments\":{}}}", "Missing or invalid argument: file (string)" },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"emetgate_try_batch\",\"arguments\":{\"edits\":[]}}}", "Missing or invalid argument: edits (non-empty array of objects, one per file)" },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"emetgate_try_batch\",\"arguments\":{\"edits\":[{\"file\":\"a.ts\",\"symbol\":\"f\",\"hash\":\"absent\"}]}}}", "Missing or invalid argument: edits[0].body (string)" },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"emetgate_try_batch\",\"arguments\":{\"edits\":[{\"file\":\"a.ts\"},{\"file\":\"README.md\",\"hash\":\"x\",\"content\":\"y\"}]}}}", "Missing or invalid argument: edits[0].symbol (string)" },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"emetgate_try_batch\",\"arguments\":{\"edits\":[{\"file\":\"README.md\",\"hash\":\"x\",\"content\":\"y\"}]}}}", "Missing or invalid argument: edits[0].symbol (string); README.md is not source code, so it needs kind:\"doc\" with hash, content and pointer, heading, or line_start and line_end (integers)" },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"emetgate_try_batch\",\"arguments\":{\"edits\":[{\"file\":\"README.md\",\"kind\":\"doc\",\"hash\":\"x\",\"content\":\"y\"}]}}}", "Missing or invalid argument: edits[0]: pointer, heading, or line_start and line_end (integers)" },
    };
    for (cases) |case| {
        const message = try rpcMessage(case[0]);
        defer testing.allocator.free(message);
        try testing.expectEqualStrings(case[1], message);
    }
}

test "recovery hints: tools/list stays under 9000 characters and initialize says which tool reads, searches and edits" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    _ = try server.handleMessage(testing.allocator, testing.io, undefined, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}", &out.writer);
    const parsed = try std.json.parseFromSlice(Value, testing.allocator, out.written(), .{});
    defer parsed.deinit();
    var tools: std.Io.Writer.Allocating = .init(testing.allocator);
    defer tools.deinit();
    try std.json.Stringify.value(parsed.value.object.get("result").?.object.get("tools").?, .{}, &tools.writer);
    errdefer std.debug.print("tools/list is {d} characters\n", .{tools.written().len});
    try testing.expect(tools.written().len < 9000);

    var init: std.Io.Writer.Allocating = .init(testing.allocator);
    defer init.deinit();
    _ = try server.handleMessage(testing.allocator, testing.io, undefined, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\"}}", &init.writer);
    const reply = try std.json.parseFromSlice(Value, testing.allocator, init.written(), .{});
    defer reply.deinit();
    const instructions = reply.value.object.get("result").?.object.get("instructions").?.string;
    try testing.expectEqualStrings(server.instructions, instructions);
    inline for (.{ "emetgate_read_symbol", "emetgate_search", "emetgate_try" }) |tool| try expectContains(instructions, tool);
}

test "recovery hints: a body that closes more braces than it opens is named with the surplus" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const current = symbol.formatHash(try support.hashOfRef(testing.allocator, testing.io, case.runtime, try case.abs("src/math.ts"), "twice"));
    const fix = try case.fix("emetgate_try", try case.args("{{\"file\":\"{s}\",\"symbol\":\"twice\",\"hash\":\"{s}\",\"body\":\"{{\\n  return x * 3;\\n}}\\n}}\"}}", .{ try case.escaped("src/math.ts"), &current }));
    try testing.expectEqualStrings("the body of twice closes 1 more \"}\" than it opens; send it with balanced braces", fix);

    const batch = try case.fix("emetgate_try_batch", try case.args("{{\"edits\":[{{\"file\":\"{s}\",\"symbol\":\"twice\",\"hash\":\"{s}\",\"body\":\"{{\\n  return x * 3;\\n}}\\n}}\"}}]}}", .{ try case.escaped("src/math.ts"), &current }));
    try expectContains(batch, "edits[0]: the body of twice closes 1 more");

    const escape = try case.fix("emetgate_try", try case.args("{{\"file\":\"{s}\",\"symbol\":\"twice\",\"hash\":\"{s}\",\"body\":\"{{ return x * 3; }}\\nexport function extra(): number {{ return 1; }}\"}}", .{ try case.escaped("src/math.ts"), &current }));
    try testing.expectEqualStrings("the body of twice must be only its block, from its opening brace to its closing brace; anything before or after it reaches outside the symbol", escape);
}

test "recovery hints: brace balance counts opening minus closing braces" {
    try testing.expectEqual(@as(i64, 0), recovery.braceBalance("{ a } { b }"));
    try testing.expectEqual(@as(i64, -1), recovery.braceBalance("{ a } }"));
    try testing.expectEqual(@as(i64, 2), recovery.braceBalance("{{"));
}

test "recovery hints: a stale hash inside a batch names the item and the current hash" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const current = symbol.formatHash(try support.hashOfRef(testing.allocator, testing.io, case.runtime, try case.abs("src/util.ts"), "add"));
    const fix = try case.fix("emetgate_try_batch", try case.args("{{\"edits\":[{{\"file\":\"{s}\",\"symbol\":\"add\",\"hash\":\"0123456789abcdef0123456789abcdef\",\"body\":\"{{ return a; }}\"}}]}}", .{try case.escaped("src/util.ts")}));
    const expected = try std.fmt.allocPrint(case.arena(), "edits[0]: the current hash of add is {s}; re-read it with emetgate_read_symbol if you have not seen this version, then retry with that hash", .{&current});
    try testing.expectEqualStrings(expected, fix);
}

test "recovery hints: a hint left from an earlier call never reaches the next error" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    @import("emetgate").wire.setFix("left over", .{});
    const fix = try case.fix("emetgate_symbols", try case.args("{{\"file\":\"{s}\"}}", .{try case.escaped("src/missing.ts")}));
    try testing.expect(!std.mem.eql(u8, "left over", fix));
}
