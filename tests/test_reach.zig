const std = @import("std");
const emetgate = @import("emetgate");
const test_reach = emetgate.test_reach;
const test_util = emetgate.test_util;
const Repo = @import("facts_repo.zig").Repo;

const testing = std.testing;

const cart = "export function total(items) { return items.reduce((s, i) => s + i.price * i.qty, 0); }\n" ++
    "export function discount(sum) { return sum * 0.9; }\n";
const shop = "import { total } from \"./cart\";\nexport function checkout(items) { return total(items); }\n";

fn reachOf(repo: *Repo, arena: std.mem.Allocator, path: []const u8, qname: []const u8) !test_reach.Reach {
    return test_reach.reach(arena, &repo.store, try repo.def(path, qname));
}

test "a function a test calls directly is tested" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    _ = try repo.put("cart.ts", cart);
    _ = try repo.put("cart.test.ts", "import { total } from \"./cart\";\ntest(\"total\", () => { total([]); });\n");
    try repo.linkAll();
    try testing.expectEqual(test_reach.Reach.tested, try reachOf(&repo, arena.allocator(), "cart.ts", "total"));
}

test "a function a test reaches through a caller is tested" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    _ = try repo.put("cart.ts", cart);
    _ = try repo.put("shop.ts", shop);
    _ = try repo.put("shop.test.ts", "import { checkout } from \"./shop\";\ntest(\"checkout\", () => { checkout([]); });\n");
    try repo.linkAll();
    try testing.expectEqual(test_reach.Reach.tested, try reachOf(&repo, arena.allocator(), "cart.ts", "total"));
}

test "a function no test reaches is untested" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    _ = try repo.put("cart.ts", cart);
    _ = try repo.put("shop.ts", shop);
    _ = try repo.put("shop.test.ts", "import { checkout } from \"./shop\";\ntest(\"checkout\", () => { checkout([]); });\n");
    try repo.linkAll();
    try testing.expectEqual(test_reach.Reach.untested, try reachOf(&repo, arena.allocator(), "cart.ts", "discount"));
}

test "the written span is where the new text landed, or the whole file for a content write" {
    const handlers = emetgate.handlers;
    const bytes = "export function a() {}\nexport function b() { return 2; }\n";
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(testing.allocator);
    try obj.put(testing.allocator, "new_string", .{ .string = "return 2;" });
    const span = handlers.writtenSpan(bytes, .{ .object = obj }).?;
    try testing.expectEqualStrings("return 2;", bytes[span.start..span.end]);
    _ = obj.swapRemove("new_string");
    try obj.put(testing.allocator, "new_string", .{ .string = "" });
    try testing.expect(handlers.writtenSpan(bytes, .{ .object = obj }) == null);
    _ = obj.swapRemove("new_string");
    try obj.put(testing.allocator, "content", .{ .string = bytes });
    const whole = handlers.writtenSpan(bytes, .{ .object = obj }).?;
    try testing.expectEqual(@as(u32, 0), whole.start);
    try testing.expectEqual(@as(u32, @intCast(bytes.len)), whole.end);
}

test "a written path becomes the store's root-relative, slash-separated key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const handlers = emetgate.handlers;
    try testing.expectEqualStrings("src/cart.ts", try handlers.storePath(a, "C:\\repo", "C:\\repo\\src\\cart.ts"));
    try testing.expectEqualStrings("src/cart.ts", try handlers.storePath(a, "C:\\Repo", "c:\\repo\\src\\cart.ts"));
    try testing.expectEqualStrings("cart.ts", try handlers.storePath(a, "C:\\repo\\", "C:\\repo\\cart.ts"));
}

test "a change inside a method names the method, not its class" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const source = "export class Cart {\n  total(items) { return items.length; }\n}\n";
    const id = try repo.put("cart.ts", source);
    try repo.linkAll();
    const state = repo.store.file(id);
    const at: u32 = @intCast(std.mem.indexOf(u8, source, "items.length").?);
    const changed = try test_reach.changedDefs(arena.allocator(), state, at, at + 12);
    try testing.expectEqual(@as(usize, 1), changed.len);
    try testing.expectEqualStrings("total", state.facts.defs[changed[0]].name);
}
