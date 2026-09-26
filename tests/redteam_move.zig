const std = @import("std");
const builtin = @import("builtin");
const move_batch = @import("emetgate").move_batch;
const fixture = @import("ts_fixture.zig");
const mt = @import("move_tool.zig");

const testing = std.testing;
const Case = mt.Case;
const Loc = fixture.Loc;

fn expectOld(case: *Case, math: []const u8, app: []const u8) !void {
    try case.expectFile("src/math.ts", math);
    try case.expectFile("src/app.ts", app);
    try testing.expect(!case.repo.exists("src/shapes.ts"));
}

test "red team move: a move that makes the target and the source import each other is refused as a cycle" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const math = "export const factor = 3;\nexport function area(r: number): number {\n  return r * r * factor;\n}\nexport function ring(r: number): number {\n  return area(r) - area(r / 2);\n}\n";
    var case: Case = undefined;
    try mt.initMath(&case, math, mt.app_src, &.{}, true);
    defer case.deinit();
    try mt.plan(&case, &.{ .{ .rel = "src/math.ts", .needle = "function area", .name = "area" }, .{ .rel = "src/math.ts", .needle = "area(r) -", .name = "area" }, .{ .rel = "src/math.ts", .needle = "area(r / 2)", .name = "area" }, mt.area_refs[1], mt.area_refs[2] });
    try testing.expectError(error.ImportCycle, mt.move(&case, "src/math.ts", "area", "src/shapes.ts", .{}));
    try expectOld(&case, math, mt.app_src);
}

test "red team move: a source with a module-level effect needs order_change and is then classed as spending" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const math = mt.math_src ++ "console.log(\"math loaded\");\n";
    var case: Case = undefined;
    try mt.initMath(&case, math, mt.app_src, &.{}, true);
    defer case.deinit();
    try mt.plan(&case, &mt.area_refs);
    try testing.expectError(error.ModuleSideEffect, mt.move(&case, "src/math.ts", "area", "src/shapes.ts", .{}));
    try expectOld(&case, math, mt.app_src);
    const outcome = try mt.move(&case, "src/math.ts", "area", "src/shapes.ts", .{ .order_change = true });
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try testing.expect(outcome.plan.order_change);
}

test "red team move: a package.json sideEffects entry for the source is refused without order_change" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try mt.initMath(&case, mt.math_src, mt.app_src, &.{.{ .rel = "package.json", .text = "{\"name\":\"x\",\"sideEffects\":[\"./src/math.ts\"]}" }}, true);
    defer case.deinit();
    try mt.plan(&case, &mt.area_refs);
    try testing.expectError(error.DeclaredSideEffect, mt.move(&case, "src/math.ts", "area", "src/shapes.ts", .{}));
    try expectOld(&case, mt.math_src, mt.app_src);
}

test "red team move: a target that already binds the name is refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const shapes = "export function area(): number {\n  return 0;\n}\n";
    var case: Case = undefined;
    try mt.initMath(&case, mt.math_src, mt.app_src, &.{.{ .rel = "src/shapes.ts", .text = shapes }}, true);
    defer case.deinit();
    try mt.plan(&case, &mt.area_refs);
    try testing.expectError(error.TargetNameTaken, mt.move(&case, "src/math.ts", "area", "src/shapes.ts", .{}));
    try case.expectFile("src/shapes.ts", shapes);
    try case.expectFile("src/math.ts", mt.math_src);
}

test "red team move: a target that binds a free name of the moved code differently is refused as capture" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const shapes = "export function round(x: number): number {\n  return x;\n}\n";
    var case: Case = undefined;
    try mt.initMath(&case, mt.math_src, mt.app_src, &.{.{ .rel = "src/shapes.ts", .text = shapes }}, true);
    defer case.deinit();
    try mt.plan(&case, &mt.area_refs);
    try testing.expectError(error.TargetCapture, mt.move(&case, "src/math.ts", "area", "src/shapes.ts", .{}));
    try case.expectFile("src/shapes.ts", shapes);
}

test "red team move: a namespace import, a re-export, a string key and export default are refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const cases = [_]struct { app: []const u8, math: []const u8, err: anyerror }{
        .{ .app = "import * as m from \"./math\";\nexport function total(r: number): number {\n  return m.area(r);\n}\n", .math = mt.math_src, .err = error.NamespaceImportUse },
        .{ .app = "export { area } from \"./math\";\n", .math = mt.math_src, .err = error.ReExported },
        .{ .app = "import { area } from \"./math\";\nexport const key = \"area\";\nexport function total(r: number): number {\n  return area(r);\n}\n", .math = mt.math_src, .err = error.DynamicReference },
        .{ .app = "export const x = 1;\n", .math = "export default function area(r: number): number {\n  return r;\n}\n", .err = error.ExportDefault },
    };
    for (cases) |c| {
        errdefer std.debug.print("app: {s}\n", .{c.app});
        var case: Case = undefined;
        try mt.initMath(&case, c.math, c.app, &.{}, true);
        defer case.deinit();
        try mt.plan(&case, &.{.{ .rel = "src/math.ts", .needle = "function area", .name = "area" }});
        try testing.expectError(c.err, mt.move(&case, "src/math.ts", "area", "src/shapes.ts", .{}));
        try expectOld(&case, c.math, c.app);
    }
}

test "red team move: a dependency the source does not export and a local use of an unexported symbol are refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    {
        const math = "const factor = 3;\nexport function area(r: number): number {\n  return r * factor;\n}\n";
        var case: Case = undefined;
        try mt.initMath(&case, math, "export const x = 1;\n", &.{}, true);
        defer case.deinit();
        try mt.plan(&case, &.{.{ .rel = "src/math.ts", .needle = "function area", .name = "area" }});
        try testing.expectError(error.SourceDependencyNotExported, mt.move(&case, "src/math.ts", "area", "src/shapes.ts", .{}));
    }
    const math = "function area(r: number): number {\n  return r * r;\n}\nexport function ring(r: number): number {\n  return area(r) - 1;\n}\n";
    var case: Case = undefined;
    try mt.initMath(&case, math, "export const x = 1;\n", &.{}, true);
    defer case.deinit();
    try mt.plan(&case, &.{ .{ .rel = "src/math.ts", .needle = "function area", .name = "area" }, .{ .rel = "src/math.ts", .needle = "area(r) -", .name = "area" } });
    try testing.expectError(error.MoveNeedsExport, mt.move(&case, "src/math.ts", "area", "src/shapes.ts", .{}));
}

test "red team move: the language service naming a user the kernel cannot rewrite, or missing one it found, is refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try mt.initMath(&case, mt.math_src, mt.app_src, &.{.{ .rel = "src/legacy.js", .text = "const m = require(\"./math\");\nmodule.exports = () => m.area(1);\n" }}, true);
    defer case.deinit();
    try mt.plan(&case, &(mt.area_refs ++ [_]Loc{.{ .rel = "src/legacy.js", .needle = "m.area", .name = "area" }}));
    try testing.expectError(error.UnhandledReference, mt.move(&case, "src/math.ts", "area", "src/shapes.ts", .{}));
    try mt.plan(&case, mt.area_refs[0..1]);
    try testing.expectError(error.ResolutionMismatch, mt.move(&case, "src/math.ts", "area", "src/shapes.ts", .{}));
    try expectOld(&case, mt.math_src, mt.app_src);
}

test "red team move: the proof catches a moved text that changed, a user left without its import and another symbol that changed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    defer move_batch.injected_fault = null;
    const faults = [_]struct { fault: move_batch.Fault, err: anyerror }{
        .{ .fault = .alter_moved_text, .err = error.ContentHashMismatch },
        .{ .fault = .drop_user_import, .err = error.IncompleteMove },
        .{ .fault = .alter_other_symbol, .err = error.BodyChanged },
    };
    for (faults) |f| {
        errdefer std.debug.print("fault {t}\n", .{f.fault});
        var case: Case = undefined;
        try mt.initMath(&case, mt.math_src, mt.app_src, &.{}, true);
        defer case.deinit();
        try mt.plan(&case, &mt.area_refs);
        move_batch.injected_fault = f.fault;
        try testing.expectError(f.err, mt.move(&case, "src/math.ts", "area", "src/shapes.ts", .{}));
        move_batch.injected_fault = null;
        try expectOld(&case, mt.math_src, mt.app_src);
    }
}

test "red team move: a class, an interface and a type alias move with the imports their users need" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const model = "export interface Shape {\n  area(): number;\n}\nexport type Id = string;\nexport class Circle implements Shape {\n  constructor(public r: number) {}\n  area(): number {\n    return this.r * this.r * 3;\n  }\n}\n";
    const app = "import { Circle, Shape } from \"./model\";\nexport function make(): Shape {\n  return new Circle(1);\n}\n";
    var case: Case = undefined;
    try case.init(&.{ .{ .rel = "src/model.ts", .text = model }, .{ .rel = "src/app.ts", .text = app } }, true);
    defer case.deinit();
    try mt.plan(&case, &.{ .{ .rel = "src/model.ts", .needle = "class Circle", .name = "Circle" }, .{ .rel = "src/app.ts", .needle = "{ Circle", .name = "Circle" }, .{ .rel = "src/app.ts", .needle = "new Circle", .name = "Circle" } });
    const outcome = try mt.move(&case, "src/model.ts", "Circle", "src/circle.ts", .{});
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try case.expectFile("src/circle.ts", "import type { Shape } from \"./model\";\nexport class Circle implements Shape {\n  constructor(public r: number) {}\n  area(): number {\n    return this.r * this.r * 3;\n  }\n}\n");
    try case.expectFile("src/model.ts", "export interface Shape {\n  area(): number;\n}\nexport type Id = string;\n");
    try case.expectFile("src/app.ts", "import { Shape } from \"./model\";\nimport { Circle } from \"./circle\";\nexport function make(): Shape {\n  return new Circle(1);\n}\n");
}
