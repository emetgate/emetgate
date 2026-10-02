const std = @import("std");
const emetgate = @import("emetgate");
const facts = emetgate.facts;
const facts_extract = emetgate.facts_extract;
const test_util = emetgate.test_util;

const testing = std.testing;

const source =
    \\/**
    \\ * Runs one node and decides whether the workflow goes on.
    \\ * @param node the node
    \\ */
    \\export async function runNode(
    \\  node: string,
    \\  retries: number,
    \\): Promise<boolean> {
    \\  return true;
    \\}
    \\
    \\// Keeps the count of retries.
    \\// A second line that is not the first.
    \\const counter = { value: 0 };
    \\
    \\// eslint-disable-next-line @typescript-eslint/no-explicit-any
    \\export const loose = (x: any) => x;
    \\
    \\export class Engine extends Base implements Runner {
    \\  /** Starts the engine. */
    \\  @Inject()
    \\  start(): void {}
    \\
    \\  stop() {}
    \\}
    \\
    \\/** Detached. */
    \\
    \\function far() {}
    \\
;

fn defNamed(defs: []const facts.Def, qname: []const u8) !facts.Def {
    for (defs) |d| {
        if (std.mem.eql(u8, d.qname, qname)) return d;
    }
    std.debug.print("no definition {s}\n", .{qname});
    return error.DefNotFound;
}

test "signatures: a definition keeps its signature up to its body and the first line of the comment right above it" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const snapshot = try test_util.snapshotOf(runtime, source);
    defer snapshot.destroy();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const found = try facts_extract.extract(arena_state.allocator(), snapshot);
    const run = try defNamed(found.defs, "runNode");
    try testing.expectEqualStrings("export async function runNode( node: string, retries: number, ): Promise<boolean>", run.signature);
    try testing.expectEqualStrings("Runs one node and decides whether the workflow goes on.", run.doc);
    const counter = try defNamed(found.defs, "counter");
    try testing.expectEqualStrings("const counter = { value: 0 };", counter.signature);
    try testing.expectEqualStrings("Keeps the count of retries.", counter.doc);
    for (found.defs) |d| {
        if (std.mem.eql(u8, d.qname, "loose")) try testing.expectEqualStrings("", d.doc);
    }
    const engine = try defNamed(found.defs, "Engine");
    try testing.expectEqualStrings("export class Engine extends Base implements Runner", engine.signature);
    const start = try defNamed(found.defs, "Engine.start");
    try testing.expect(std.mem.endsWith(u8, start.signature, "start(): void"));
    try testing.expectEqualStrings("Starts the engine.", start.doc);
    try testing.expectEqualStrings("", (try defNamed(found.defs, "Engine.stop")).doc);
    try testing.expectEqualStrings("", (try defNamed(found.defs, "far")).doc);
}

test "signatures: a long signature is cut at a character boundary and marked" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "export function wide(");
    for (0..60) |i| try text.print(testing.allocator, "argument{d}: number, ", .{i});
    try text.appendSlice(testing.allocator, ") {\n  return 1;\n}\n");
    const snapshot = try test_util.snapshotOf(runtime, text.items);
    defer snapshot.destroy();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const found = try facts_extract.extract(arena_state.allocator(), snapshot);
    const wide = try defNamed(found.defs, "wide");
    try testing.expect(std.mem.endsWith(u8, wide.signature, "..."));
    try testing.expectEqual(emetgate.facts_signature.max_signature_chars + 3, wide.signature.len);
}
