const std = @import("std");
const emetgate = @import("emetgate");
const sent_ledger = emetgate.sent_ledger;
const handlers = emetgate.handlers;
const telemetry = emetgate.telemetry;
const Policy = emetgate.policy.Policy;
const Runtime = emetgate.runtime.Runtime;

const testing = std.testing;
const Ledger = sent_ledger.Ledger;

test "sent ledger: content shown exactly is seen unchanged, other content is not" {
    var ledger = Ledger.init(testing.allocator);
    defer ledger.deinit();
    const bytes = "fn a() {}\nfn b() {}\n";
    try ledger.recordBytes("src/a.zig", bytes, .{ .start = 0, .end = 9 }, .exact);
    try testing.expect(ledger.seenUnchanged("src/a.zig", sent_ledger.spanHash("fn a() {}")));
    try testing.expect(ledger.seenUnchanged("src\\A.zig", sent_ledger.spanHash("fn a() {}")));
    try testing.expect(!ledger.seenUnchanged("src/a.zig", sent_ledger.spanHash("fn b() {}")));
    try testing.expect(!ledger.seenUnchanged("src/other.zig", sent_ledger.spanHash("fn a() {}")));
}

test "sent ledger: a changed file makes the entries over changed bytes stale" {
    var ledger = Ledger.init(testing.allocator);
    defer ledger.deinit();
    const before = "fn a() {}\nfn b() {}\n";
    try ledger.recordBytes("src/a.zig", before, .{ .start = 0, .end = 9 }, .exact);
    try ledger.recordBytes("src/a.zig", before, .{ .start = 10, .end = 19 }, .exact);
    try ledger.recordBytes("src/b.zig", before, .{ .start = 0, .end = 9 }, .exact);

    const none = try ledger.staleFor(testing.allocator, "src/a.zig", before);
    defer testing.allocator.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);

    const after = "fn a() {}\nfn B() {}\n";
    const stale = try ledger.staleFor(testing.allocator, "src/a.zig", after);
    defer testing.allocator.free(stale);
    try testing.expectEqual(@as(usize, 1), stale.len);
    try testing.expectEqual(@as(u32, 10), stale[0].span.start);
    try testing.expectEqualStrings("src/a.zig", stale[0].path);

    const shrunk = try ledger.staleFor(testing.allocator, "src/a.zig", "fn a() {}");
    defer testing.allocator.free(shrunk);
    try testing.expectEqual(@as(usize, 1), shrunk.len);
}

test "sent ledger: dense showings do not count as seen for editing" {
    var ledger = Ledger.init(testing.allocator);
    defer ledger.deinit();
    const bytes = "fn a() { return 1; }";
    try ledger.recordBytes("a.zig", bytes, .{ .start = 0, .end = bytes.len }, .dense);
    try testing.expect(!ledger.seenUnchanged("a.zig", sent_ledger.spanHash(bytes)));
    try ledger.recordBytes("a.zig", bytes, .{ .start = 0, .end = bytes.len }, .exact);
    try testing.expect(ledger.seenUnchanged("a.zig", sent_ledger.spanHash(bytes)));
    try testing.expectEqual(@as(usize, 1), ledger.len());
}

test "sent ledger: reset forgets everything" {
    var ledger = Ledger.init(testing.allocator);
    defer ledger.deinit();
    try ledger.recordBytes("a.zig", "abc", .{ .start = 0, .end = 3 }, .exact);
    try testing.expectEqual(@as(usize, 1), ledger.len());
    ledger.reset();
    try testing.expectEqual(@as(usize, 0), ledger.len());
    try testing.expect(!ledger.seenUnchanged("a.zig", sent_ledger.spanHash("abc")));

    const policy: Policy = .{ .sent_ledger = &ledger };
    try ledger.recordBytes("a.zig", "abc", .{ .start = 0, .end = 3 }, .exact);
    policy.ledgerReset();
    try testing.expectEqual(@as(usize, 0), ledger.len());
    const without: Policy = .{};
    without.ledgerReset();
}

test "sent ledger: past the cap the oldest entry is evicted first" {
    var ledger = Ledger.initCap(testing.allocator, 3);
    defer ledger.deinit();
    const bytes = "0123456789";
    for (0..5) |i| try ledger.recordBytes("a.zig", bytes, .{ .start = @intCast(i), .end = @intCast(i + 1) }, .exact);
    try testing.expectEqual(@as(usize, 3), ledger.len());
    try testing.expect(!ledger.seenUnchanged("a.zig", sent_ledger.spanHash("0")));
    try testing.expect(!ledger.seenUnchanged("a.zig", sent_ledger.spanHash("1")));
    try testing.expect(ledger.seenUnchanged("a.zig", sent_ledger.spanHash("2")));
    try testing.expect(ledger.seenUnchanged("a.zig", sent_ledger.spanHash("4")));
    try testing.expectEqual(@as(usize, sent_ledger.default_cap), Ledger.init(testing.allocator).cap);
}

const Fixture = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    runtime: *Runtime,
    ledger: Ledger,

    fn init(self: *Fixture) !void {
        self.tmp = testing.tmpDir(.{});
        try self.tmp.dir.createDirPath(testing.io, "src");
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "src/notes.txt", .data = "hello\n" });
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "src/lib.ts", .data = "export function one(): number {\n  return 1;\n}\n" });
        self.root = try self.tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        self.runtime = try Runtime.create(testing.allocator);
        self.ledger = Ledger.init(testing.allocator);
    }

    fn deinit(self: *Fixture) void {
        self.ledger.deinit();
        self.runtime.destroy() catch @panic("live snapshots");
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn call(self: *Fixture, tool: []const u8, args: anytype) !void {
        var event: telemetry.Event = .{ .tool = tool };
        const line = try std.json.Stringify.valueAlloc(testing.allocator, args, .{});
        defer testing.allocator.free(line);
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
        defer parsed.deinit();
        const result = try handlers.callTool(testing.allocator, testing.io, self.runtime, tool, parsed.value, &event, .{ .root = self.root, .sent_ledger = &self.ledger });
        defer testing.allocator.free(result.text);
        errdefer std.debug.print("{s}\n", .{result.text});
        try testing.expect(!result.is_error);
    }

    fn abs(self: *Fixture, rel: []const u8) ![]u8 {
        return std.fmt.allocPrint(testing.allocator, "{s}\\{s}", .{ self.root, rel });
    }
};

test "sent ledger: a read_file call records the bytes it returned" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const file = try f.abs("src\\notes.txt");
    defer testing.allocator.free(file);
    try f.call("emetgate_read_file", .{ .file = file });
    try testing.expectEqual(@as(usize, 1), f.ledger.len());
    const entry = f.ledger.entries.items[0];
    try testing.expectEqualStrings("src/notes.txt", entry.path);
    try testing.expectEqual(sent_ledger.Form.exact, entry.form);
    try testing.expectEqual(@as(u32, 0), entry.span.start);
    try testing.expectEqual(@as(u32, 6), entry.span.end);
    try testing.expect(f.ledger.seenUnchanged("src/notes.txt", sent_ledger.spanHash("hello\n")));
    const stale = try f.ledger.staleFor(testing.allocator, "src/notes.txt", "hello, world\n");
    defer testing.allocator.free(stale);
    try testing.expectEqual(@as(usize, 1), stale.len);
}

test "sent ledger: a read_symbol call records the body it returned" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const file = try f.abs("src\\lib.ts");
    defer testing.allocator.free(file);
    try f.call("emetgate_read_symbol", .{ .file = file, .symbol = "one" });
    try testing.expectEqual(@as(usize, 1), f.ledger.len());
    const entry = f.ledger.entries.items[0];
    try testing.expectEqualStrings("src/lib.ts", entry.path);
    const source = "export function one(): number {\n  return 1;\n}\n";
    try testing.expectEqual(sent_ledger.Form.exact, entry.form);
    try testing.expect(f.ledger.seenUnchanged("src/lib.ts", sent_ledger.spanHash(source[entry.span.start..entry.span.end])));
}
