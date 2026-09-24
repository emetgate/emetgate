const std = @import("std");
const core = @import("../tools/mutate/core.zig");
const schema = @import("../tools/mutate/schema.zig");

const testing = std.testing;

const Mut = struct { number: u32, from: []const u8, to: []const u8, all: bool = false };

fn transformed(arena: std.mem.Allocator, source: []const u8, muts: []const Mut) !schema.Transformed {
    var file = try schema.File.parse(arena, source);
    var entries: std.ArrayList(schema.Entry) = .empty;
    for (muts) |m| {
        const site = switch (try file.locate(arena, m.from)) {
            .site => |site| site,
            .refused => |why| {
                std.debug.print("refused {s}: {t}\n", .{ m.from, why });
                return error.Refused;
            },
        };
        try entries.append(arena, .{ .number = m.number, .site = site, .from = m.from, .to = m.to, .all = m.all });
    }
    return schema.transform(arena, source, entries.items);
}

fn refusal(arena: std.mem.Allocator, source: []const u8, from: []const u8) !?schema.Refusal {
    var file = try schema.File.parse(arena, source);
    return switch (try file.locate(arena, from)) {
        .site => null,
        .refused => |why| why,
    };
}

test "schema: a mutant gets a copy of its function and a dispatch line at the top of the original" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source =
        \\const std = @import("std");
        \\
        \\pub fn add(a: u32, b: u32) u32 {
        \\    return a + b;
        \\}
        \\
    ;
    const t = try transformed(arena, source, &.{.{ .number = 3, .from = "a + b", .to = "a - b" }});
    try testing.expectEqualStrings(
        \\const std = @import("std");
        \\
        \\pub fn add(a: u32, b: u32) u32 { if (@import("root").emetgate_mutant == 3) return add__m3(a, b);
        \\    return a + b;
        \\}
        \\
        \\fn add__m3(a: u32, b: u32) u32 {
        \\    return a - b;
        \\}
        \\
    , t.text);
}

test "schema: two mutants in one function get two dispatch lines and two copies, in number order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source =
        \\fn pick(x: u32) u32 {
        \\    if (x > 3) return 1;
        \\    return 2;
        \\}
        \\
    ;
    const t = try transformed(arena, source, &.{ .{ .number = 9, .from = "return 2;", .to = "return 0;" }, .{ .number = 4, .from = "x > 3", .to = "x >= 3" } });
    try testing.expectEqualStrings(
        \\fn pick(x: u32) u32 { if (@import("root").emetgate_mutant == 4) return pick__m4(x); if (@import("root").emetgate_mutant == 9) return pick__m9(x);
        \\    if (x > 3) return 1;
        \\    return 2;
        \\}
        \\
        \\fn pick__m4(x: u32) u32 {
        \\    if (x >= 3) return 1;
        \\    return 2;
        \\}
        \\
        \\fn pick__m9(x: u32) u32 {
        \\    if (x > 3) return 1;
        \\    return 0;
        \\}
        \\
    , t.text);
}

test "schema: an unnamed parameter is named in the original so the copy can be given it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source =
        \\const S = struct {
        \\    x: u32,
        \\    fn get(self: *const S, _: u8, comptime T: type) T {
        \\        return @intCast(self.x + 1);
        \\    }
        \\};
        \\
    ;
    const t = try transformed(arena, source, &.{.{ .number = 1, .from = "self.x + 1", .to = "self.x + 2" }});
    try testing.expectEqualStrings(
        \\const S = struct {
        \\    x: u32,
        \\    fn get(self: *const S, __emetgate_p1: u8, comptime T: type) T { if (@import("root").emetgate_mutant == 1) return get__m1(self, __emetgate_p1, T);
        \\        return @intCast(self.x + 1);
        \\    }
        \\
        \\fn get__m1(self: *const S, _: u8, comptime T: type) T {
        \\        return @intCast(self.x + 2);
        \\    }
        \\};
        \\
    , t.text);
}

test "schema: a mutation outside a function, in a test, across functions or in a signature runs on its own" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source =
        \\const limit = 10;
        \\fn a(x: u32) u32 {
        \\    return x + limit;
        \\}
        \\fn b(x: u32) u32 {
        \\    return x + limit + 1;
        \\}
        \\inline fn c() u32 {
        \\    return 7;
        \\}
        \\export fn d() u32 {
        \\    return 8;
        \\}
        \\test "t" {
        \\    _ = a(99);
        \\}
        \\
    ;
    try testing.expectEqual(@as(?schema.Refusal, .outside_function), try refusal(arena, source, "const limit = 10;"));
    try testing.expectEqual(@as(?schema.Refusal, .several_functions), try refusal(arena, source, "x + limit"));
    try testing.expectEqual(@as(?schema.Refusal, .touches_signature), try refusal(arena, source, "fn a(x: u32) u32 {"));
    try testing.expectEqual(@as(?schema.Refusal, .in_test_block), try refusal(arena, source, "_ = a(99);"));
    try testing.expectEqual(@as(?schema.Refusal, .inline_extern_or_export), try refusal(arena, source, "return 7;"));
    try testing.expectEqual(@as(?schema.Refusal, .inline_extern_or_export), try refusal(arena, source, "return 8;"));
    try testing.expectEqual(@as(?schema.Refusal, .no_hit), try refusal(arena, source, "nowhere"));
    try testing.expectEqual(@as(?schema.Refusal, null), try refusal(arena, source, "limit + 1"));
}

test "schema: a compile error in a copy drops that mutant, one in the original drops every mutant of the function" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source =
        \\fn one(x: u32) u32 {
        \\    const y = x * 2;
        \\    return y + 1;
        \\}
        \\
        \\fn two(x: u32) u32 {
        \\    return x - 1;
        \\}
        \\
    ;
    const t = try transformed(arena, source, &.{
        .{ .number = 1, .from = "x * 2", .to = "x * 3" },
        .{ .number = 2, .from = "y + 1", .to = "y + 5" },
        .{ .number = 5, .from = "x - 1", .to = "x - 2" },
    });
    const text = t.text;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var number: u32 = 0;
    var copy_line: u32 = 0;
    var original_line: u32 = 0;
    var two_line: u32 = 0;
    while (lines.next()) |line| {
        number += 1;
        if (std.mem.indexOf(u8, line, "x * 3") != null) copy_line = number;
        if (std.mem.indexOf(u8, line, "const y = x * 2;") != null and original_line == 0) original_line = number;
        if (std.mem.indexOf(u8, line, "return x - 1;") != null) two_line = number;
    }
    var dropped: std.ArrayList(u32) = .empty;
    try t.mutantsAt(copy_line, &dropped, arena);
    try testing.expectEqualSlices(u32, &.{1}, dropped.items);
    dropped.clearRetainingCapacity();
    try t.mutantsAt(original_line, &dropped, arena);
    std.mem.sort(u32, dropped.items, {}, std.sort.asc(u32));
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, dropped.items);
    dropped.clearRetainingCapacity();
    try t.mutantsAt(two_line, &dropped, arena);
    try testing.expectEqualSlices(u32, &.{5}, dropped.items);
    dropped.clearRetainingCapacity();
    try t.mutantsAt(1_000, &dropped, arena);
    try testing.expectEqual(@as(usize, 0), dropped.items.len);
}

test "schema: compile errors are read with Windows and POSIX paths" {
    const output =
        \\install
        \\+- compile test test-all Debug native 2 errors
        \\src\engine\query.zig:120:9: error: unused local constant
        \\C:\x\tree\src/platform/rules.zig:7:1: error: expected type
        \\    note: not an error line
        \\src/engine/query.zig: error: no line
    ;
    const found = try schema.compileErrors(testing.allocator, output);
    defer testing.allocator.free(found);
    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expectEqual(@as(u32, 120), found[0].line);
    try testing.expect(schema.samePath(found[0].path, "src/engine/query.zig"));
    try testing.expect(!schema.samePath(found[0].path, "engine/query.zig.bak"));
    try testing.expect(!schema.samePath(found[0].path, "c/engine/query.zig"));
    try testing.expectEqual(@as(u32, 7), found[1].line);
    try testing.expect(schema.samePath(found[1].path, "src/platform/rules.zig"));
}

test "schema: a crash names the test that was running when the process died" {
    try testing.expectEqualStrings("tests.a.test.deep", core.unfinishedTest("1/3 tests.a.test.one...OK (1 ms)\n2/3 tests.a.test.deep...thread 7 panic: stack overflow\n").?);
    try testing.expect(core.unfinishedTest("1/2 tests.a.test.one...OK (1 ms)\n2/2 tests.a.test.two...FAIL (x)\n") == null);
    try testing.expect(core.unfinishedTest("1/1 tests.a.test.one...SKIP\n") == null);
    try testing.expect(core.unfinishedTest("a/b not a test...\n") == null);
}
