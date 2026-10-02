const std = @import("std");
const emetgate = @import("emetgate");
const facts = emetgate.facts;
const facts_extract = emetgate.facts_extract;
const facts_spine = emetgate.facts_spine;
const facts_outline = emetgate.facts_outline;
const test_util = emetgate.test_util;
const Snapshot = emetgate.loader.Snapshot;

const testing = std.testing;
const Range = facts_spine.Range;

const mixed =
    \\export function decide(x: number, node: any) {
    \\  // when the node keeps failing
    \\  if (node.retry) {
    \\    x = x + 1;
    \\  } else if (node.stop) {
    \\    return "stop";
    \\  } else {
    \\    x = x - 1;
    \\  }
    \\  if (node.long) {
    \\    x = x + 1;
    \\    x = x + 2;
    \\    x = x + 3;
    \\    x = x + 4;
    \\    x = x + 5;
    \\    x = x + 6;
    \\    if (x > 9) return "late";
    \\    x = x + 7;
    \\    x = x + 8;
    \\    x = x + 9;
    \\    x = x + 10;
    \\    return x > 3 ? "big" : "small";
    \\  }
    \\  switch (x) {
    \\    case 1:
    \\      return "one";
    \\    case 2: {
    \\      const y = x * 2;
    \\      return y > 3 ? "big" : "small";
    \\    }
    \\    default:
    \\      break;
    \\  }
    \\  for (let i = 0; i < x; i++) {
    \\    if (i > 3) continue;
    \\    try {
    \\      node.run(i);
    \\    } catch (error) {
    \\      throw new Error(
    \\        "failed " + i,
    \\      );
    \\    }
    \\  }
    \\  const handler = async (event: any) => {
    \\    /* a comment
    \\       on two lines */
    \\
    \\    await event.done();
    \\    return event;
    \\  };
    \\  return handler;
    \\}
    \\export class Runner {
    \\  private items: number[] = [];
    \\  run(
    \\    node: any,
    \\    limit: number,
    \\  ): string {
    \\    while (node.next && limit > 0) {
    \\      node = node.next; limit--;
    \\    }
    \\    return node.name;
    \\  }
    \\  get size() { return this.items.length; }
    \\}
    \\const config = {
    \\  execute(input: any) {
    \\    if (!input) {
    \\      return null;
    \\    }
    \\    return input.value;
    \\  },
    \\  handler: (event: any) => {
    \\    return event;
    \\  },
    \\};
    \\
;

fn mutable(arena: std.mem.Allocator, ranges: []const Range) ![]Range {
    return arena.dupe(Range, ranges);
}

fn compare(snapshot: *const Snapshot) !usize {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const found = try facts_extract.extract(arena, snapshot);
    const lines = try facts_spine.Lines.of(arena, snapshot.source);
    const branch_kinds = snapshot.profile.facts.?.branch_statements;
    var compared: usize = 0;
    for (found.defs) |d| {
        if (d.kind == .module) continue;
        const tree_frame = facts_spine.frameOf(snapshot.tree, lines, d.span);
        const outline_frame = facts_outline.frameOf(lines, d);
        try testing.expectEqual(tree_frame.first, outline_frame.first);
        try testing.expectEqual(tree_frame.last, outline_frame.last);
        var line = tree_frame.first;
        while (line <= tree_frame.last) : (line += 1) {
            for ([_]bool{ false, true }) |branches| {
                const want = try facts_spine.merged(arena, try mutable(arena, try facts_spine.unit(arena, snapshot.profile, tree_frame, lines, line, if (branches) branch_kinds else &.{})));
                const got = try facts_spine.merged(arena, try mutable(arena, try facts_outline.unit(arena, found.outline, outline_frame, lines, line, branches)));
                const same = want.len == got.len and for (want, got) |a, b| {
                    if (a.first != b.first or a.last != b.last) break false;
                } else true;
                if (!same) {
                    std.debug.print("{s} line {d} branches {}: tree {any} outline {any}\n", .{ d.qname, line, branches, want, got });
                    return error.UnitsDiffer;
                }
                compared += 1;
            }
        }
    }
    return compared;
}

test "outline: every line of every definition gets the same complete unit from the stored outline as from the parse tree" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const snapshot = try test_util.snapshotOf(runtime, mixed);
    defer snapshot.destroy();
    try testing.expect(try compare(snapshot) > 200);
}

test "outline: the fixtures, the broken one included, give the same units from the outline as from the parse tree" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    for ([_][]const u8{ "functions.ts", "service.ts", "broken.ts" }) |name| {
        const snapshot = try test_util.loadFixture(runtime, name);
        defer snapshot.destroy();
        _ = try compare(snapshot);
    }
}

test "outline: a definition keeps its whole signature up to the line where its body opens" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const snapshot = try test_util.snapshotOf(runtime, mixed);
    defer snapshot.destroy();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const found = try facts_extract.extract(arena, snapshot);
    const lines = try facts_spine.Lines.of(arena, snapshot.source);
    for (found.defs) |d| {
        if (!std.mem.eql(u8, d.qname, "Runner.run")) continue;
        const frame = facts_outline.frameOf(lines, d);
        try testing.expectEqual(@as(u32, 55), frame.first);
        try testing.expectEqual(@as(u32, 58), frame.signature_last);
        return;
    }
    return error.DefNotFound;
}
