const std = @import("std");
const builtin = @import("builtin");
const rename_batch = @import("emetgate").rename_batch;
const symbol = @import("emetgate").symbol;
const Snapshot = @import("emetgate").loader.Snapshot;
const fixture = @import("ts_fixture.zig");
const tool = @import("rename_tool.zig");

const testing = std.testing;
const Case = tool.Case;
const Loc = fixture.Loc;

fn declarationHash(case: *Case, file: []const u8, ref_text: []const u8) !symbol.Hash {
    const snapshot = try Snapshot.load(case.runtime, testing.io, .cwd(), file);
    defer snapshot.destroy();
    const table = try snapshot.symbols();
    for (table.declarations) |d| {
        const text = try std.fmt.allocPrint(testing.allocator, "{f}", .{d.ref});
        defer testing.allocator.free(text);
        if (std.mem.eql(u8, text, ref_text)) return d.hash;
    }
    return error.DeclarationNotFound;
}

pub fn renameDeclaration(case: *Case, rel: []const u8, ref_text: []const u8, new_name: []const u8, interface_change: bool) !rename_batch.Outcome {
    const file = try case.repo.abs(testing.allocator, rel);
    defer testing.allocator.free(file);
    const hash = try declarationHash(case, file, ref_text);
    return rename_batch.tryRename(testing.allocator, testing.io, case.runtime, .{
        .request = .{ .file_abs = file, .ref_text = ref_text, .expected_hash = hash, .new_name = new_name, .interface_change = interface_change },
        .test_command = "cmd /c exit 0",
        .language_service = &case.session,
    });
}

fn expectCommitted(outcome: rename_batch.Outcome) !void {
    try testing.expect(outcome.result == .committed);
}

pub const shape_src = "export class Shape {\n  area(): number {\n    return 0;\n  }\n}\nexport interface Sized {\n  size: number;\n}\n";
pub const user_src = "import { Shape, Sized } from \"./shape\";\nexport class Square extends Shape implements Sized {\n  size = 2;\n}\nexport function make(): Shape {\n  const s: Shape = new Shape();\n  return s;\n}\n";
pub const shape_new = "export class Figure {\n  area(): number {\n    return 0;\n  }\n}\nexport interface Sized {\n  size: number;\n}\n";
pub const user_new = "import { Figure, Sized } from \"./shape\";\nexport class Square extends Figure implements Sized {\n  size = 2;\n}\nexport function make(): Figure {\n  const s: Figure = new Figure();\n  return s;\n}\n";

const class_locations = [_]Loc{
    .{ .rel = "src/shape.ts", .needle = "class Shape", .name = "Shape" },
    .{ .rel = "src/user.ts", .needle = "{ Shape", .name = "Shape" },
    .{ .rel = "src/user.ts", .needle = "extends Shape", .name = "Shape" },
    .{ .rel = "src/user.ts", .needle = "(): Shape", .name = "Shape" },
    .{ .rel = "src/user.ts", .needle = "s: Shape", .name = "Shape" },
    .{ .rel = "src/user.ts", .needle = "new Shape", .name = "Shape" },
};

fn initShapes(case: *Case) !void {
    try case.init(&.{ .{ .rel = "src/shape.ts", .text = shape_src }, .{ .rel = "src/user.ts", .text = user_src } }, true);
}

test "rename kinds: a class is renamed in its declaration, an import, extends, a return type, a variable type and new" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try initShapes(&case);
    defer case.deinit();
    try case.plan(&class_locations);
    try testing.expectError(error.InterfaceChangeNeedsApproval, renameDeclaration(&case, "src/shape.ts", "Shape", "Figure", false));
    const outcome = try renameDeclaration(&case, "src/shape.ts", "Shape", "Figure", true);
    defer outcome.deinit(testing.allocator);
    try expectCommitted(outcome);
    try testing.expectEqual(rename_batch.Resolver.language_service, outcome.plan.resolver);
    try case.expectFile("src/shape.ts", shape_new);
    try case.expectFile("src/user.ts", user_new);
}

test "rename kinds: a service that misses a use in a type position is refused as incomplete" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try initShapes(&case);
    defer case.deinit();
    try case.plan(&.{ class_locations[0], class_locations[1], class_locations[2], class_locations[3], class_locations[5] });
    try testing.expectError(error.IncompleteRename, renameDeclaration(&case, "src/shape.ts", "Shape", "Figure", true));
    try case.expectFile("src/user.ts", user_src);
}

test "rename kinds: an interface merged with a class of the same name must be renamed with it" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const merged = "export interface Box {\n  a: number;\n}\nexport class Box {\n  b = 1;\n}\nexport function f(x: Box): Box {\n  return x;\n}\n";
    var case: Case = undefined;
    try case.init(&.{.{ .rel = "src/box.ts", .text = merged }}, true);
    defer case.deinit();
    try case.plan(&.{ .{ .rel = "src/box.ts", .needle = "interface Box", .name = "Box" }, .{ .rel = "src/box.ts", .needle = "x: Box", .name = "Box" }, .{ .rel = "src/box.ts", .needle = "): Box", .name = "Box" } });
    try testing.expectError(error.MergedDeclaration, renameDeclaration(&case, "src/box.ts", "Box", "Crate", true));
    try case.expectFile("src/box.ts", merged);
}

test "rename kinds: a type alias is renamed while a value of the same name stays" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const source = "export type Point = { x: number };\nexport const Point = { x: 0 };\nexport function f(p: Point): number {\n  return p.x + Point.x;\n}\n";
    const expected = "export type Coord = { x: number };\nexport const Point = { x: 0 };\nexport function f(p: Coord): number {\n  return p.x + Point.x;\n}\n";
    var case: Case = undefined;
    try case.init(&.{.{ .rel = "src/point.ts", .text = source }}, true);
    defer case.deinit();
    try case.plan(&.{ .{ .rel = "src/point.ts", .needle = "type Point", .name = "Point" }, .{ .rel = "src/point.ts", .needle = "p: Point", .name = "Point" } });
    const file = try case.repo.abs(testing.allocator, "src/point.ts");
    defer testing.allocator.free(file);
    const snapshot = try Snapshot.load(case.runtime, testing.io, .cwd(), file);
    const hash = blk: {
        defer snapshot.destroy();
        const table = try snapshot.symbols();
        for (table.declarations) |d| if (d.kind == .type_alias) break :blk d.hash;
        return error.DeclarationNotFound;
    };
    const outcome = try rename_batch.tryRename(testing.allocator, testing.io, case.runtime, .{
        .request = .{ .file_abs = file, .ref_text = "Point", .expected_hash = hash, .new_name = "Coord", .interface_change = true },
        .test_command = "cmd /c exit 0",
        .language_service = &case.session,
    });
    defer outcome.deinit(testing.allocator);
    try expectCommitted(outcome);
    try case.expectFile("src/point.ts", expected);
}

test "rename kinds: a local type parameter that shadows the renamed type is left alone, renaming only its use is refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const source = "type Item = { id: number };\nexport function first(xs: Item[]): Item {\n  return xs[0];\n}\nexport function keep<Item>(x: Item): Item {\n  return x;\n}\n";
    const expected = "type Entry = { id: number };\nexport function first(xs: Entry[]): Entry {\n  return xs[0];\n}\nexport function keep<Item>(x: Item): Item {\n  return x;\n}\n";
    var case: Case = undefined;
    try case.init(&.{.{ .rel = "src/item.ts", .text = source }}, true);
    defer case.deinit();
    const right = [_]Loc{
        .{ .rel = "src/item.ts", .needle = "type Item", .name = "Item" },
        .{ .rel = "src/item.ts", .needle = "xs: Item", .name = "Item" },
        .{ .rel = "src/item.ts", .needle = "]): Item", .name = "Item" },
    };
    try case.plan(&(right ++ [_]Loc{.{ .rel = "src/item.ts", .needle = "x: Item", .name = "Item" }}));
    try testing.expectError(error.ResolutionMismatch, renameDeclaration(&case, "src/item.ts", "Item", "Entry", false));
    try case.plan(&right);
    const outcome = try renameDeclaration(&case, "src/item.ts", "Item", "Entry", false);
    defer outcome.deinit(testing.allocator);
    try expectCommitted(outcome);
    try case.expectFile("src/item.ts", expected);
}

test "rename kinds: a JSX component name is renamed in the opening and closing tags" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const source = "class Panel {\n  render(): any {\n    return null;\n  }\n}\nexport function view(): any {\n  return <Panel>text</Panel>;\n}\n";
    const expected = "class Card {\n  render(): any {\n    return null;\n  }\n}\nexport function view(): any {\n  return <Card>text</Card>;\n}\n";
    var case: Case = undefined;
    try case.init(&.{.{ .rel = "src/view.tsx", .text = source }}, true);
    defer case.deinit();
    try case.plan(&.{ .{ .rel = "src/view.tsx", .needle = "class Panel", .name = "Panel" }, .{ .rel = "src/view.tsx", .needle = "<Panel>", .name = "Panel" }, .{ .rel = "src/view.tsx", .needle = "</Panel>", .name = "Panel" } });
    const outcome = try renameDeclaration(&case, "src/view.tsx", "Panel", "Card", false);
    defer outcome.deinit(testing.allocator);
    try expectCommitted(outcome);
    try case.expectFile("src/view.tsx", expected);
}

test "rename kinds: a class field is renamed with its this and obj accesses the service reports" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const source = "export class Counter {\n  count = 0;\n  bump(): void {\n    this.count += 1;\n  }\n}\nexport function read(c: Counter): number {\n  return c.count;\n}\n";
    const expected = "export class Counter {\n  total = 0;\n  bump(): void {\n    this.total += 1;\n  }\n}\nexport function read(c: Counter): number {\n  return c.total;\n}\n";
    var case: Case = undefined;
    try case.init(&.{.{ .rel = "src/counter.ts", .text = source }}, true);
    defer case.deinit();
    try case.plan(&.{ .{ .rel = "src/counter.ts", .needle = "count = 0", .name = "count" }, .{ .rel = "src/counter.ts", .needle = "this.count", .name = "count" }, .{ .rel = "src/counter.ts", .needle = "c.count", .name = "count" } });
    try testing.expectError(error.InterfaceChangeNeedsApproval, renameDeclaration(&case, "src/counter.ts", "Counter.count", "total", false));
    const outcome = try renameDeclaration(&case, "src/counter.ts", "Counter.count", "total", true);
    defer outcome.deinit(testing.allocator);
    try expectCommitted(outcome);
    try case.expectFile("src/counter.ts", expected);
}

test "rename kinds: an enum member used as a string key is unresolved dynamic access" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const source = "export enum Level {\n  Low,\n  High,\n}\nexport function pick(): number {\n  return Level.Low + (Level as any)[\"Low\"];\n}\n";
    var case: Case = undefined;
    try case.init(&.{.{ .rel = "src/level.ts", .text = source }}, true);
    defer case.deinit();
    try case.plan(&.{ .{ .rel = "src/level.ts", .needle = "Low,", .name = "Low" }, .{ .rel = "src/level.ts", .needle = "Level.Low", .name = "Low" } });
    try testing.expectError(error.DynamicReference, renameDeclaration(&case, "src/level.ts", "Level.Low", "Min", true));
    try case.expectFile("src/level.ts", source);
}

test "rename kinds: a local export alias keeps its public name and only the local name changes" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const source = "class Engine {\n  run(): number {\n    return 1;\n  }\n}\nexport { Engine as Motor };\n";
    const expected = "class Driver {\n  run(): number {\n    return 1;\n  }\n}\nexport { Driver as Motor };\n";
    var case: Case = undefined;
    try case.init(&.{.{ .rel = "src/engine.ts", .text = source }}, true);
    defer case.deinit();
    try case.plan(&.{ .{ .rel = "src/engine.ts", .needle = "class Engine", .name = "Engine" }, .{ .rel = "src/engine.ts", .needle = "{ Engine", .name = "Engine" } });
    try testing.expectError(error.InterfaceChangeNeedsApproval, renameDeclaration(&case, "src/engine.ts", "Engine", "Driver", false));
    const outcome = try renameDeclaration(&case, "src/engine.ts", "Engine", "Driver", true);
    defer outcome.deinit(testing.allocator);
    try expectCommitted(outcome);
    try case.expectFile("src/engine.ts", expected);
}

test "rename kinds: without the language service a local class is renamed by the text path, a type and a value of one name are unresolved" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    {
        const source = "class Cache {\n  size = 0;\n}\nexport function make(): number {\n  const c: Cache = new Cache();\n  return c.size;\n}\n";
        const expected = "class Store {\n  size = 0;\n}\nexport function make(): number {\n  const c: Store = new Store();\n  return c.size;\n}\n";
        var case: Case = undefined;
        try case.init(&.{.{ .rel = "src/cache.ts", .text = source }}, false);
        defer case.deinit();
        const outcome = try renameDeclaration(&case, "src/cache.ts", "Cache", "Store", false);
        defer outcome.deinit(testing.allocator);
        try expectCommitted(outcome);
        try testing.expectEqual(rename_batch.Resolver.text, outcome.plan.resolver);
        try case.expectFile("src/cache.ts", expected);
    }
    const both = "type Mode = number;\nconst Mode = 1;\nexport function f(m: Mode): number {\n  return m + Mode;\n}\n";
    var case: Case = undefined;
    try case.init(&.{.{ .rel = "src/mode.ts", .text = both }}, false);
    defer case.deinit();
    try testing.expectError(error.RenameUnresolved, renameDeclaration(&case, "src/mode.ts", "Mode", "Kind", false));
    try case.expectFile("src/mode.ts", both);
}

test "rename kinds: a top-level variable is renamed across its uses" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const source = "const limit = 3;\nexport function over(n: number): boolean {\n  return n > limit;\n}\n";
    const expected = "const maximum = 3;\nexport function over(n: number): boolean {\n  return n > maximum;\n}\n";
    var case: Case = undefined;
    try case.init(&.{.{ .rel = "src/limit.ts", .text = source }}, true);
    defer case.deinit();
    try case.plan(&.{ .{ .rel = "src/limit.ts", .needle = "const limit", .name = "limit" }, .{ .rel = "src/limit.ts", .needle = "> limit", .name = "limit" } });
    const outcome = try renameDeclaration(&case, "src/limit.ts", "limit", "maximum", false);
    defer outcome.deinit(testing.allocator);
    try expectCommitted(outcome);
    try case.expectFile("src/limit.ts", expected);
}
