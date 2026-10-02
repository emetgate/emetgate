const std = @import("std");
const emetgate = @import("emetgate");
const facts_extract = emetgate.facts_extract;
const facts_tests = emetgate.facts_tests;
const test_util = emetgate.test_util;

const testing = std.testing;

const suite =
    \\import { decide } from "./a";
    \\describe("decide", () => {
    \\  it("stops on fail", () => {
    \\    expect(decide(1)).toBe("stop");
    \\  });
    \\  describe.each([[1], [2]])("with %s", (n) => {
    \\    test.skip(`returns ${n}`, () => {
    \\      decide(n);
    \\    });
    \\  });
    \\});
    \\test(`top
    \\  level`, () => {});
    \\
;

test "test blocks: describe, it and test calls become nested blocks with their titles and lines" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const snapshot = try test_util.snapshotOf(runtime, suite);
    defer snapshot.destroy();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const found = try facts_extract.extract(arena, snapshot);
    const blocks = found.tests;
    try testing.expectEqual(@as(usize, 5), blocks.len);
    try testing.expectEqualStrings("decide", blocks[0].title);
    try testing.expectEqual(@as(u32, 2), blocks[0].line);
    try testing.expectEqualStrings("stops on fail", blocks[1].title);
    try testing.expectEqual(@as(u32, 0), blocks[1].parent);
    try testing.expectEqualStrings("with %s", blocks[2].title);
    try testing.expectEqual(@as(u32, 0), blocks[2].parent);
    try testing.expectEqualStrings("returns ${n}", blocks[3].title);
    try testing.expectEqual(@as(u32, 2), blocks[3].parent);
    try testing.expectEqualStrings("top level", blocks[4].title);
    try testing.expectEqual(emetgate.facts.none, blocks[4].parent);
    const call = std.mem.indexOf(u8, suite, "decide(n)").?;
    const inner = facts_tests.innermost(blocks, @intCast(call)).?;
    try testing.expectEqualStrings("decide > with %s > returns ${n}", try facts_tests.titleChain(arena, blocks, inner));
    try testing.expectEqual(@as(?u32, null), facts_tests.innermost(blocks, 3));
}

test "test blocks: a file without test calls keeps no block" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const snapshot = try test_util.snapshotOf(runtime, "export function it2(x: number) { return submit(x).test; }\n");
    defer snapshot.destroy();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const found = try facts_extract.extract(arena_state.allocator(), snapshot);
    try testing.expectEqual(@as(usize, 0), found.tests.len);
}

test "test blocks: test files are the ones the profile names, by test and spec infixes and __tests__ folders" {
    const table = test_util.language.facts.?;
    for ([_][]const u8{ "src/a.test.ts", "a.spec.js", "src/__tests__/a.ts", "__tests__/b.ts", "packages/x/test/run.test.tsx" }) |path| {
        if (!facts_tests.isTestPath(table, path)) {
            std.debug.print("not a test path: {s}\n", .{path});
            return error.TestPathMissed;
        }
    }
    for ([_][]const u8{ "src/a.ts", "src/latest.ts", "src/testing/a.ts", "src/my__tests__/a.ts", "src/contest.spec" }) |path| {
        if (facts_tests.isTestPath(table, path)) {
            std.debug.print("taken for a test path: {s}\n", .{path});
            return error.TestPathTaken;
        }
    }
}
