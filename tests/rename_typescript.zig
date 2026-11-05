const std = @import("std");
const builtin = @import("builtin");
const sandbox = @import("emetgate").sandbox;
const rename_batch = @import("emetgate").rename_batch;
const tool = @import("rename_tool.zig");

const testing = std.testing;
const Case = tool.Case;

fn typescriptDir(arena: std.mem.Allocator) !?[]u8 {
    const dir = (try sandbox.environmentValue(arena, std.unicode.utf8ToUtf16LeStringLiteral("EMETGATE_TEST_TYPESCRIPT"))) orelse return null;
    std.mem.replaceScalar(u8, dir, '/', '\\');
    return dir;
}

fn linkTypeScript(case: *Case, target: []const u8) !void {
    try case.repo.tmp.dir.createDirPath(testing.io, "repo/node_modules");
    const link = try case.repo.abs(testing.allocator, "node_modules/typescript");
    defer testing.allocator.free(link);
    const result = try @import("emetgate").bounded_run.run(testing.allocator, testing.io, .{ .argv = &.{ "cmd.exe", "/d", "/c", "mklink", "/J", link, target } });
    testing.allocator.free(result.stdout);
    testing.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.JunctionFailed,
        else => return error.JunctionFailed,
    }
}

test "real typescript: set EMETGATE_TEST_TYPESCRIPT to a typescript package directory to rename across three files with it" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const target = (try typescriptDir(arena_state.allocator())) orelse return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&.{ .{ .rel = "src/a.ts", .text = tool.a_src }, .{ .rel = "src/b.ts", .text = tool.b_src }, .{ .rel = "src/c.ts", .text = tool.c_src } }, false);
    defer case.deinit();
    try linkTypeScript(&case, target);
    const outcome = try case.rename("src/a.ts", "add", "sum", true, null);
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try testing.expectEqual(rename_batch.Resolver.language_service, outcome.plan.resolver);
    try case.expectNew();
}

test "real typescript: a shadowing parameter stays and a tsconfig plugin that would exit is never loaded" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const target = (try typescriptDir(arena_state.allocator())) orelse return error.SkipZigTest;
    const source = "export function add(a: number): number {\n  return a + 1;\n}\nexport function g(add: number): number {\n  return add;\n}\nexport function h(): number {\n  return add(2);\n}\n";
    const expected = "export function sum(a: number): number {\n  return a + 1;\n}\nexport function g(add: number): number {\n  return add;\n}\nexport function h(): number {\n  return sum(2);\n}\n";
    var case: Case = undefined;
    try case.init(&.{
        .{ .rel = "src/a.ts", .text = source },
        .{ .rel = "tsconfig.json", .text = "{\"compilerOptions\":{\"strict\":true,\"plugins\":[{\"name\":\"evil-plugin\"}]}}" },
    }, false);
    defer case.deinit();
    try case.repo.write("node_modules/evil-plugin/package.json", "{\"name\":\"evil-plugin\",\"main\":\"index.js\"}");
    try case.repo.write("node_modules/evil-plugin/index.js", "process.exit(9);\n");
    try linkTypeScript(&case, target);
    const outcome = try case.rename("src/a.ts", "add", "sum", true, null);
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try testing.expectEqual(rename_batch.Resolver.language_service, outcome.plan.resolver);
    try case.expectFile("src/a.ts", expected);
}

test "real typescript: a class used as a type, in extends and in new is renamed across two files" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const target = (try typescriptDir(arena_state.allocator())) orelse return error.SkipZigTest;
    const kinds = @import("rename_kinds.zig");
    var case: Case = undefined;
    try case.init(&.{ .{ .rel = "src/shape.ts", .text = kinds.shape_src }, .{ .rel = "src/user.ts", .text = kinds.user_src } }, false);
    defer case.deinit();
    try linkTypeScript(&case, target);
    const outcome = try kinds.renameDeclaration(&case, "src/shape.ts", "Shape", "Figure", true);
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try testing.expectEqual(rename_batch.Resolver.language_service, outcome.plan.resolver);
    try case.expectFile("src/shape.ts", kinds.shape_new);
    try case.expectFile("src/user.ts", kinds.user_new);
}

test "real typescript: a moved function's references agree with the kernel's users and the move commits" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const target = (try typescriptDir(arena_state.allocator())) orelse return error.SkipZigTest;
    const mt = @import("move_tool.zig");
    var case: Case = undefined;
    try mt.initMath(&case, mt.math_src, mt.app_src, &.{}, false);
    defer case.deinit();
    try linkTypeScript(&case, target);
    const outcome = try mt.move(&case, "src/math.ts", "area", "src/shapes.ts", .{});
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try testing.expectEqual(@import("emetgate").move_batch.Resolver.language_service, outcome.plan.resolver);
    try case.expectFile("src/shapes.ts", mt.shapes_new);
    try case.expectFile("src/app.ts", mt.app_new);
}

test "real typescript: getEditsForFileRename and the kernel agree on every rewritten path of a file move" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const target = (try typescriptDir(arena_state.allocator())) orelse return error.SkipZigTest;
    const mf = @import("move_file_tool.zig");
    var case: Case = undefined;
    try mf.initFiles(&case, &.{}, false);
    defer case.deinit();
    try linkTypeScript(&case, target);
    const outcome = try mf.moveFile(&case, .{});
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try testing.expectEqual(@import("emetgate").file_move.Resolver.language_service, outcome.plan.resolver);
    try mf.expectNew(&case);
}

fn realCase(case: *Case, files: []const @import("ts_fixture.zig").File, arena: std.mem.Allocator) !void {
    const target = (try typescriptDir(arena)) orelse return error.SkipZigTest;
    try case.init(files, false);
    errdefer case.deinit();
    try linkTypeScript(case, target);
}

const js_cart = "export class Cart {\n  total() {\n    return 2;\n  }\n}\nexport function discount(v) {\n  return v - 1;\n}\n";

test "real typescript: a member reached through an untyped parameter is refused and names the site" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const use = "import { Cart } from './cart.js';\nfunction f(c) {\n  return c.total();\n}\nexport function run() {\n  return f(new Cart());\n}\n";
    var case: Case = undefined;
    try realCase(&case, &.{ .{ .rel = "src/cart.js", .text = js_cart }, .{ .rel = "src/use.js", .text = use } }, arena_state.allocator());
    defer case.deinit();
    try testing.expectError(error.RenameUnresolved, case.rename("src/cart.js", "Cart.total", "grand", true, null));
    try case.expectFile("src/cart.js", js_cart);
    try case.expectFile("src/use.js", use);
}

test "real typescript: a destructured parameter with no type is refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const use = "export function f({ total }) {\n  return total;\n}\n";
    var case: Case = undefined;
    try realCase(&case, &.{ .{ .rel = "src/cart.js", .text = js_cart }, .{ .rel = "src/use.js", .text = use } }, arena_state.allocator());
    defer case.deinit();
    try testing.expectError(error.RenameUnresolved, case.rename("src/cart.js", "Cart.total", "grand", true, null));
    try case.expectFile("src/use.js", use);
}

test "real typescript: a member use with a known type elsewhere does not block the rename" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var case: Case = undefined;
    try realCase(&case, &.{
        .{ .rel = "src/cart.ts", .text = "export class Cart {\n  total(): number {\n    return 2;\n  }\n}\n" },
        .{ .rel = "src/use.ts", .text = "import { Cart } from './cart';\nconst o = { total: () => 5 };\nexport const y = new Cart().total() + o.total();\n" },
    }, arena_state.allocator());
    defer case.deinit();
    const outcome = try case.rename("src/cart.ts", "Cart.total", "grand", true, null);
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try case.expectFile("src/use.ts", "import { Cart } from './cart';\nconst o = { total: () => 5 };\nexport const y = new Cart().grand() + o.total();\n");
}

test "real typescript: a local variable with an untyped member of the same name still renames" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var case: Case = undefined;
    try realCase(&case, &.{.{ .rel = "src/use.js", .text = "function g(o) {\n  const total = 1;\n  return total + o.total;\n}\nexport { g };\n" }}, arena_state.allocator());
    defer case.deinit();
    const outcome = try case.rename("src/use.js", "g", "h", true, null);
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
}

test "real typescript: a function nothing can reach by name leaves an untyped member of that name alone" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var case: Case = undefined;
    try realCase(&case, &.{.{ .rel = "src/use.js", .text = "function g(o) {\n  return o.g;\n}\nexport const x = g({});\n" }}, arena_state.allocator());
    defer case.deinit();
    const outcome = try case.rename("src/use.js", "g", "h", true, null);
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try case.expectFile("src/use.js", "function h(o) {\n  return o.g;\n}\nexport const x = h({});\n");
}

test "real typescript: an object shorthand of a renamed function keeps its key" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var case: Case = undefined;
    try realCase(&case, &.{
        .{ .rel = "src/cart.js", .text = js_cart },
        .{ .rel = "src/use.js", .text = "import { discount } from './cart.js';\nexport function run() {\n  const o = { discount };\n  return o.discount(3);\n}\n" },
    }, arena_state.allocator());
    defer case.deinit();
    const outcome = try case.rename("src/cart.js", "discount", "cut", true, null);
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try case.expectFile("src/use.js", "import { cut } from './cart.js';\nexport function run() {\n  const o = { discount: cut };\n  return o.discount(3);\n}\n");
}

test "real typescript: a commonjs export shorthand follows the rename" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var case: Case = undefined;
    try realCase(&case, &.{
        .{ .rel = "src/cart.js", .text = "function discount(v) {\n  return v - 1;\n}\nmodule.exports = { discount };\n" },
        .{ .rel = "src/use.js", .text = "const m = require('./cart.js');\nmodule.exports = { run() { return m.discount(3); } };\n" },
    }, arena_state.allocator());
    defer case.deinit();
    const outcome = try case.rename("src/cart.js", "discount", "cut", true, null);
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try case.expectFile("src/cart.js", "function cut(v) {\n  return v - 1;\n}\nmodule.exports = { cut };\n");
    try case.expectFile("src/use.js", "const m = require('./cart.js');\nmodule.exports = { run() { return m.cut(3); } };\n");
}
