const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");
const file_move = emetgate.file_move;
const move_batch = emetgate.move_batch;
const rename_batch = emetgate.rename_batch;
const symbol = emetgate.symbol;
const fixture = @import("ts_fixture.zig");
const tool = @import("rename_tool.zig");
const moves = @import("move_tool.zig");

const testing = std.testing;
const Case = tool.Case;

const cart = "export class Cart {\n  total() {\n    return 2;\n  }\n}\nexport function discount(v) {\n  return v - 1;\n}\nexport function makeCart() {\n  return new Cart();\n}\n";
const cjs = "class Cart {\n  total() {\n    return 2;\n  }\n}\nfunction discount(v) {\n  return v - 1;\n}\nfunction makeCart() {\n  return new Cart();\n}\nmodule.exports = { Cart, discount, makeCart };\n";
const imports = "import { Cart, makeCart, discount } from './cart.js';\n";

fn moveFile(case: *Case, from_rel: []const u8, to_rel: []const u8) !file_move.Outcome {
    const from = try case.repo.abs(testing.allocator, from_rel);
    defer testing.allocator.free(from);
    const to = try case.repo.abs(testing.allocator, to_rel);
    defer testing.allocator.free(to);
    const text = try case.repo.read(from_rel);
    defer testing.allocator.free(text);
    return file_move.tryMoveFile(testing.allocator, testing.io, case.runtime, .{
        .request = .{ .from_abs = from, .to_abs = to, .from_hash = symbol.fileHash(text), .interface_change = true },
        .test_command = "cmd /c exit 0",
        .language_service = &case.session,
    });
}

fn expectRename(source: []const u8, use: []const u8, ref_text: []const u8, new_name: []const u8, source_after: []const u8, use_after: []const u8) !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&.{ .{ .rel = "src/cart.js", .text = source }, .{ .rel = "src/use.js", .text = use } }, false);
    defer case.deinit();
    const outcome = try case.rename("src/cart.js", ref_text, new_name, true, null);
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try testing.expectEqual(rename_batch.Resolver.facts, outcome.plan.resolver);
    try case.expectFile("src/cart.js", source_after);
    try case.expectFile("src/use.js", use_after);
}

fn refuseRename(use: []const u8, ref_text: []const u8, new_name: []const u8, expected: anyerror) !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&.{ .{ .rel = "src/cart.js", .text = cart }, .{ .rel = "src/use.js", .text = use } }, false);
    defer case.deinit();
    try testing.expectError(expected, case.rename("src/cart.js", ref_text, new_name, true, null));
    try case.expectFile("src/cart.js", cart);
    try case.expectFile("src/use.js", use);
}

fn refuseMoveFile(files: []const fixture.File, expected: anyerror) !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(files, false);
    defer case.deinit();
    try testing.expectError(expected, moveFile(&case, "src/cart.js", "src/models/cart.js"));
    try case.expectFile("src/cart.js", cart);
}

const renamed_total = "export class Cart {\n  grand() {\n    return 2;\n  }\n}\nexport function discount(v) {\n  return v - 1;\n}\nexport function makeCart() {\n  return new Cart();\n}\n";

test "js without typescript: a method called on a new object is renamed by the facts resolver" {
    try expectRename(cart, imports ++ "export function run() {\n  const c = new Cart();\n  return c.total();\n}\n", "Cart.total", "grand", renamed_total, imports ++ "export function run() {\n  const c = new Cart();\n  return c.grand();\n}\n");
}

test "js without typescript: a method called on what a factory returns is renamed" {
    try expectRename(cart, imports ++ "export function run() {\n  const c = makeCart();\n  return c.total();\n}\n", "Cart.total", "grand", renamed_total, imports ++ "export function run() {\n  const c = makeCart();\n  return c.grand();\n}\n");
}

test "js without typescript: an unrelated object with the same method keeps its name" {
    try expectRename(cart, imports ++ "const o = { total() { return 5; } };\nexport function run() {\n  return new Cart().total() + o.total();\n}\n", "Cart.total", "grand", renamed_total, imports ++ "const o = { total() { return 5; } };\nexport function run() {\n  return new Cart().grand() + o.total();\n}\n");
}

test "js without typescript: a method reached through a parameter is refused" {
    try refuseRename(imports ++ "function f(c) {\n  return c.total();\n}\nexport function run() {\n  return f(new Cart());\n}\n", "Cart.total", "grand", error.RenameUnresolved);
}

test "js without typescript: a destructured method is refused" {
    try refuseRename(imports ++ "export function run() {\n  const { total } = new Cart();\n  return total;\n}\n", "Cart.total", "grand", error.RenameUnresolved);
}

test "js without typescript: an object shorthand of a renamed function is refused" {
    try refuseRename(imports ++ "export function run() {\n  const o = { discount };\n  return o.discount(3);\n}\n", "discount", "cut", error.RenameUnresolved);
}

test "js without typescript: destructured require follows a commonjs rename" {
    try expectRename(cjs, "const { discount } = require('./cart.js');\nmodule.exports = { run() { return discount(3); } };\n", "discount", "cut", "class Cart {\n  total() {\n    return 2;\n  }\n}\nfunction cut(v) {\n  return v - 1;\n}\nfunction makeCart() {\n  return new Cart();\n}\nmodule.exports = { Cart, cut, makeCart };\n", "const { cut } = require('./cart.js');\nmodule.exports = { run() { return cut(3); } };\n");
}

test "js without typescript: a member of a required module follows a commonjs rename" {
    try expectRename(cjs, "const m = require('./cart.js');\nmodule.exports = { run() { return m.discount(3); } };\n", "discount", "cut", "class Cart {\n  total() {\n    return 2;\n  }\n}\nfunction cut(v) {\n  return v - 1;\n}\nfunction makeCart() {\n  return new Cart();\n}\nmodule.exports = { Cart, cut, makeCart };\n", "const m = require('./cart.js');\nmodule.exports = { run() { return m.cut(3); } };\n");
}

test "js without typescript: moving a file rewrites import, require and literal import()" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&.{
        .{ .rel = "src/cart.js", .text = cart },
        .{ .rel = "src/a.js", .text = imports },
        .{ .rel = "src/b.js", .text = "const c = require('./cart');\nmodule.exports = c;\n" },
        .{ .rel = "src/c.js", .text = "export const l = () => import('./cart.js');\n" },
    }, false);
    defer case.deinit();
    const outcome = try moveFile(&case, "src/cart.js", "src/models/cart.js");
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try case.expectFile("src/models/cart.js", cart);
    try case.expectFile("src/a.js", "import { Cart, makeCart, discount } from './models/cart.js';\n");
    try case.expectFile("src/b.js", "const c = require('./models/cart');\nmodule.exports = c;\n");
    try case.expectFile("src/c.js", "export const l = () => import('./models/cart.js');\n");
}

test "js without typescript: a computed require that may reach the file is refused" {
    try refuseMoveFile(&.{ .{ .rel = "src/cart.js", .text = cart }, .{ .rel = "src/use.js", .text = "const n = 'cart';\nconst c = require('./' + n);\nmodule.exports = c;\n" } }, error.DynamicPathUse);
}

test "js without typescript: a string naming the file's path is refused" {
    try refuseMoveFile(&.{ .{ .rel = "src/cart.js", .text = cart }, .{ .rel = "src/use.js", .text = "import fs from 'node:fs';\nexport const has = fs.existsSync('src/cart.js');\n" } }, error.DynamicPathUse);
}

test "js without typescript: an alias import ending in the file's name is refused" {
    try refuseMoveFile(&.{ .{ .rel = "src/cart.js", .text = cart }, .{ .rel = "src/use.js", .text = "import { makeCart } from '#lib/cart.js';\nexport const c = makeCart();\n" } }, error.FileMoveUnresolved);
}

test "js without typescript: a bare import ending in the file's name is refused only under a declared baseUrl" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const use = "import { makeCart } from 'cart';\nexport const c = makeCart();\n";
    try refuseMoveFile(&.{ .{ .rel = "src/cart.js", .text = cart }, .{ .rel = "src/use.js", .text = use }, .{ .rel = "jsconfig.json", .text = "{\"compilerOptions\":{\"baseUrl\":\"src\"}}" } }, error.FileMoveUnresolved);
    var case: Case = undefined;
    try case.init(&.{ .{ .rel = "src/cart.js", .text = cart }, .{ .rel = "src/use.js", .text = use } }, false);
    defer case.deinit();
    const outcome = try moveFile(&case, "src/cart.js", "src/models/cart.js");
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try case.expectFile("src/use.js", use);
}

test "js without typescript: an import of an installed package with the file's name is not an alias" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const use = "import { x } from 'shop/cart';\nexport const y = x;\n";
    var case: Case = undefined;
    try case.init(&.{ .{ .rel = "src/cart.js", .text = cart }, .{ .rel = "src/use.js", .text = use }, .{ .rel = "node_modules/shop/package.json", .text = "{}" } }, false);
    defer case.deinit();
    const outcome = try moveFile(&case, "src/cart.js", "src/models/cart.js");
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try case.expectFile("src/use.js", use);
}

test "js without typescript: a scoped package with the file's name is not an alias" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const use = "import { x } from '@shop/kit/cart';\nexport const y = x;\n";
    var case: Case = undefined;
    try case.init(&.{ .{ .rel = "src/cart.js", .text = cart }, .{ .rel = "src/use.js", .text = use }, .{ .rel = "node_modules/@shop/kit/package.json", .text = "{}" } }, false);
    defer case.deinit();
    const outcome = try moveFile(&case, "src/cart.js", "src/models/cart.js");
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
}

test "js without typescript: a moved file that locates itself is refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const texts = [_][]const u8{
        cart ++ "export const here = import.meta.url;\n",
        cart ++ "export const dir = __dirname;\n",
        cart ++ "export const file = __filename;\n",
    };
    for (texts) |text| {
        errdefer std.debug.print("source: {s}\n", .{text});
        var case: Case = undefined;
        try case.init(&.{.{ .rel = "src/cart.js", .text = text }}, false);
        defer case.deinit();
        try testing.expectError(error.DynamicPathUse, moveFile(&case, "src/cart.js", "src/models/cart.js"));
        try case.expectFile("src/cart.js", text);
    }
}

test "js without typescript: moving an exported function rewrites its importers" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&.{
        .{ .rel = "src/cart.js", .text = "export function discount(v) {\n  return v - 1;\n}\nexport const keep = 1;\n" },
        .{ .rel = "src/use.js", .text = "import { discount, keep } from './cart.js';\nexport const y = discount(keep);\n" },
    }, false);
    defer case.deinit();
    const outcome = try moves.move(&case, "src/cart.js", "discount", "src/pricing.js", .{});
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try case.expectFile("src/cart.js", "export const keep = 1;\n");
    try case.expectFile("src/pricing.js", "export function discount(v) {\n  return v - 1;\n}\n");
    try case.expectFile("src/use.js", "import { keep } from './cart.js';\nimport { discount } from './pricing.js';\nexport const y = discount(keep);\n");
}

test "js without typescript: moving a function a commonjs file requires is refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const source = "export function discount(v) {\n  return v - 1;\n}\n";
    const use = "const { discount } = require('./cart.js');\nmodule.exports = discount;\n";
    var case: Case = undefined;
    try case.init(&.{ .{ .rel = "src/cart.js", .text = source }, .{ .rel = "src/use.js", .text = use } }, false);
    defer case.deinit();
    try testing.expectError(error.MoveUnresolved, moves.move(&case, "src/cart.js", "discount", "src/pricing.js", .{}));
    try case.expectFile("src/cart.js", source);
    try case.expectFile("src/use.js", use);
}

test "typescript files without typescript installed: a typed factory rename goes through the facts resolver" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&.{
        .{ .rel = "src/cart.ts", .text = "export class Cart {\n  total(): number {\n    return 2;\n  }\n}\nexport function makeCart(): Cart {\n  return new Cart();\n}\n" },
        .{ .rel = "src/use.ts", .text = "import { makeCart } from './cart';\nexport function run(): number {\n  const c = makeCart();\n  return c.total();\n}\n" },
    }, false);
    defer case.deinit();
    const outcome = try case.rename("src/cart.ts", "Cart.total", "grand", true, null);
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try testing.expectEqual(rename_batch.Resolver.facts, outcome.plan.resolver);
    try case.expectFile("src/use.ts", "import { makeCart } from './cart';\nexport function run(): number {\n  const c = makeCart();\n  return c.grand();\n}\n");
}

test "typescript files with typescript installed keep the language service resolver" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.initThree();
    defer case.deinit();
    try case.plan(&tool.all_locations);
    const outcome = try case.rename("src/a.ts", "add", "sum", true, null);
    defer outcome.deinit(testing.allocator);
    try testing.expectEqual(rename_batch.Resolver.language_service, outcome.plan.resolver);
    try testing.expect(move_batch.Resolver.language_service != move_batch.Resolver.text);
}
