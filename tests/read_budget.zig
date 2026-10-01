const std = @import("std");
const server = @import("emetgate").server;
const read_budget = @import("emetgate").read_budget;
const Runtime = @import("emetgate").runtime.Runtime;

const testing = std.testing;
const Value = std.json.Value;

const fixture = "tests/fixtures/folding.ts";

const Reply = struct {
    envelope: std.json.Parsed(Value),
    body: std.json.Parsed(Value),
    is_error: bool,

    fn deinit(self: *Reply) void {
        self.body.deinit();
        self.envelope.deinit();
    }

    fn field(self: *Reply, name: []const u8) ?Value {
        return self.body.value.object.get(name);
    }
};

fn readSymbol(runtime: *Runtime, args: anytype, budget: usize) !Reply {
    var line: std.Io.Writer.Allocating = .init(testing.allocator);
    defer line.deinit();
    var js: std.json.Stringify = .{ .writer = &line.writer };
    try js.write(.{ .jsonrpc = "2.0", .id = 1, .method = "tools/call", .params = .{ .name = "emetgate_read_symbol", .arguments = args } });

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const policy: server.Policy = .{ .read_budget = budget };
    _ = try server.handleMessageObserved(testing.allocator, testing.io, runtime, line.written(), &out.writer, null, policy);

    const envelope = try std.json.parseFromSlice(Value, testing.allocator, out.written(), .{ .allocate = .alloc_always });
    errdefer envelope.deinit();
    const result = envelope.value.object.get("result") orelse return error.NotAToolResult;
    const text = result.object.get("content").?.array.items[0].object.get("text").?.string;
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const body = try std.json.parseFromSlice(Value, testing.allocator, text[0..end], .{ .allocate = .alloc_always });
    return .{ .envelope = envelope, .body = body, .is_error = result.object.get("isError").?.bool };
}

const Source = struct {
    bytes: []u8,

    fn load() !Source {
        return .{ .bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, fixture, testing.allocator, .unlimited) };
    }

    fn deinit(self: Source) void {
        testing.allocator.free(self.bytes);
    }

    fn line(self: Source, number: usize) []const u8 {
        var current: usize = 1;
        var start: usize = 0;
        for (self.bytes, 0..) |c, i| {
            if (c != '\n') continue;
            if (current == number) return self.bytes[start .. i + 1];
            current += 1;
            start = i + 1;
        }
        return self.bytes[start..];
    }

    fn eol(self: Source) []const u8 {
        return if (std.mem.indexOf(u8, self.bytes, "\r\n") != null) "\r\n" else "\n";
    }

    fn settleBody(self: Source) []const u8 {
        const open = std.mem.indexOfScalar(u8, self.bytes, '{').?;
        const close = std.mem.indexOf(u8, self.bytes, "\n}").? + 2;
        return self.bytes[open..close];
    }

    fn elision(self: Source, indent: []const u8, first: usize, last: usize) ![]u8 {
        return std.fmt.allocPrint(testing.allocator, "{s}\u{2026} lines {d}-{d} elided ({d} lines); read them with line_start/line_end{s}", .{ indent, first, last, last - first + 1, self.eol() });
    }
};

fn expectElided(reply: *Reply, expected: []const [2]i64) !void {
    const elided = reply.field("elided").?.array.items;
    try testing.expectEqual(expected.len, elided.len);
    for (expected, elided) |want, got| {
        try testing.expectEqual(want[0], got.object.get("line_start").?.integer);
        try testing.expectEqual(want[1], got.object.get("line_end").?.integer);
        try testing.expectEqual(want[1] - want[0] + 1, got.object.get("lines").?.integer);
    }
}

test "a symbol body within the read budget comes back exactly as before" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var reply = try readSymbol(runtime, .{ .file = fixture, .symbol = "small" }, read_budget.default_budget);
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    try testing.expectEqual(@as(usize, 4), reply.body.value.object.count());
    const body = reply.field("body").?.string;
    try testing.expect(std.mem.startsWith(u8, body, "{"));
    try testing.expect(std.mem.indexOf(u8, body, "return a + 1;") != null);
    try testing.expect(reply.field("status") == null);
}

test "a body exactly at the read budget is not folded and one byte over it is" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const source = try Source.load();
    defer source.deinit();
    const body = source.settleBody();

    var at = try readSymbol(runtime, .{ .file = fixture, .symbol = "settle" }, body.len);
    defer at.deinit();
    try testing.expect(at.field("status") == null);
    try testing.expectEqualStrings(body, at.field("body").?.string);

    var over = try readSymbol(runtime, .{ .file = fixture, .symbol = "settle" }, body.len - 1);
    defer over.deinit();
    try testing.expectEqualStrings("partial", over.field("status").?.string);
}

test "a folded body names each elided range in place, deepest blocks first, with an outline" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const source = try Source.load();
    defer source.deinit();
    const body = source.settleBody();

    var reply = try readSymbol(runtime, .{ .file = fixture, .symbol = "settle" }, body.len - 1);
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    try expectElided(&reply, &.{ .{ 5, 8 }, .{ 10, 13 } });
    const text = reply.field("body").?.string;
    const first = try source.elision("      ", 5, 8);
    defer testing.allocator.free(first);
    const second = try source.elision("      ", 10, 13);
    defer testing.allocator.free(second);
    try testing.expect(std.mem.indexOf(u8, text, first) != null);
    try testing.expect(std.mem.indexOf(u8, text, second) != null);
    try testing.expect(std.mem.indexOf(u8, text, source.line(4)) != null);
    try testing.expect(std.mem.indexOf(u8, text, source.line(9)) != null);
    try testing.expect(std.mem.indexOf(u8, text, source.line(17)) != null);
    try testing.expectEqual(@as(i64, 1), reply.field("start_line").?.integer);
    try testing.expectEqual(@as(i64, 25), reply.field("end_line").?.integer);
    try testing.expectEqual(@as(i64, @intCast(body.len)), reply.field("chars").?.integer);
    try testing.expect(std.mem.startsWith(u8, reply.field("signature").?.string, "export function settle("));

    const outline = reply.field("outline").?.array.items;
    const expected = [_]struct { []const u8, i64, i64 }{
        .{ "for_in_statement", 3, 15 },
        .{ "if_statement", 4, 9 },
        .{ "else_clause", 9, 14 },
        .{ "try_statement", 16, 21 },
    };
    try testing.expectEqual(expected.len, outline.len);
    for (expected, outline) |want, got| {
        try testing.expectEqualStrings(want[0], got.object.get("kind").?.string);
        try testing.expectEqual(want[1], got.object.get("line_start").?.integer);
        try testing.expectEqual(want[2], got.object.get("line_end").?.integer);
    }
}

test "a tighter budget folds the outer blocks and a tiny one cuts the tail, every range named" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const source = try Source.load();
    defer source.deinit();

    var inner = try readSymbol(runtime, .{ .file = fixture, .symbol = "settle" }, source.settleBody().len - 1);
    defer inner.deinit();
    const inner_folded = inner.field("body").?.string.len;

    var outer = try readSymbol(runtime, .{ .file = fixture, .symbol = "settle" }, inner_folded - 1);
    defer outer.deinit();
    try expectElided(&outer, &.{ .{ 4, 14 }, .{ 17, 20 } });
    const loop = try source.elision("    ", 4, 14);
    defer testing.allocator.free(loop);
    try testing.expect(std.mem.indexOf(u8, outer.field("body").?.string, loop) != null);

    var tiny = try readSymbol(runtime, .{ .file = fixture, .symbol = "settle" }, 100);
    defer tiny.deinit();
    try expectElided(&tiny, &.{.{ 2, 24 }});
    const cut = try source.elision("  ", 2, 24);
    defer testing.allocator.free(cut);
    const expected = try std.mem.concat(testing.allocator, u8, &.{ "{", source.eol(), cut, "}" });
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, tiny.field("body").?.string);
}

test "detail full returns every line of a body over the read budget" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const source = try Source.load();
    defer source.deinit();

    var reply = try readSymbol(runtime, .{ .file = fixture, .symbol = "settle", .detail = "full" }, 100);
    defer reply.deinit();
    try testing.expect(reply.field("status") == null);
    try testing.expectEqualStrings(source.settleBody(), reply.field("body").?.string);
}

test "a line range inside a declaration over the budget returns the requested lines and names the rest" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const source = try Source.load();
    defer source.deinit();

    var reply = try readSymbol(runtime, .{ .file = fixture, .line_start = 17, .line_end = 18 }, 100);
    defer reply.deinit();
    try testing.expect(!reply.is_error);
    const entry = reply.field("symbols").?.array.items[0];
    try testing.expectEqualStrings("settle", entry.object.get("symbol").?.string);
    try testing.expectEqualStrings("partial", entry.object.get("status").?.string);
    const head = try source.elision("  ", 2, 16);
    defer testing.allocator.free(head);
    const tail = try source.elision("    ", 19, 24);
    defer testing.allocator.free(tail);
    const expected = try std.mem.concat(testing.allocator, u8, &.{ source.line(1), head, source.line(17), source.line(18), tail, "}" });
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, entry.object.get("text").?.string);
}

test "with symbols, only the bodies over the read budget are folded" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var reply = try readSymbol(runtime, .{ .file = fixture, .symbols = &[_][]const u8{ "settle", "small" } }, 600);
    defer reply.deinit();
    const entries = reply.field("symbols").?.array.items;
    try testing.expectEqualStrings("partial", entries[0].object.get("status").?.string);
    try testing.expect(entries[1].object.get("status") == null);
    try testing.expect(std.mem.indexOf(u8, entries[1].object.get("body").?.string, "return a + 1;") != null);
}

test "an unknown detail value is refused instead of ignored" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var reply = try readSymbol(runtime, .{ .file = fixture, .symbol = "settle", .detail = "concise" }, 100);
    defer reply.deinit();
    try testing.expect(reply.is_error);
    try testing.expectEqualStrings("UnknownDetail", reply.field("error").?.string);
}

test "--read-budget sets the budget and refuses zero, a missing value or a non-number" {
    try testing.expectEqual(read_budget.default_budget, server.parsePolicy(&[_][]const u8{}).?.read_budget);
    try testing.expectEqual(@as(usize, 5000), server.parsePolicy(&[_][]const u8{ "--read-budget", "5000" }).?.read_budget);
    try testing.expect(server.parsePolicy(&[_][]const u8{ "--read-budget", "0" }) == null);
    try testing.expect(server.parsePolicy(&[_][]const u8{ "--read-budget", "lots" }) == null);
    try testing.expect(server.parsePolicy(&[_][]const u8{"--read-budget"}) == null);
    try testing.expect(server.parsePolicy(&[_][]const u8{ "--read-budget", "10", "--read-budget", "20" }) == null);
}
