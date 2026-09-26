const std = @import("std");
const builtin = @import("builtin");
const move_batch = @import("emetgate").move_batch;
const disk = @import("emetgate").disk;
const symbol = @import("emetgate").symbol;
const handlers = @import("emetgate").handlers;
const telemetry = @import("emetgate").telemetry;
const Snapshot = @import("emetgate").loader.Snapshot;
const fixture = @import("ts_fixture.zig");
const tool = @import("rename_tool.zig");
const support = @import("runner_support.zig");

const testing = std.testing;
pub const Case = tool.Case;
const Loc = fixture.Loc;

pub const math_src = "import { round } from \"./util\";\nexport function area(r: number): number {\n  return round(r * r * 3);\n}\nexport function perimeter(r: number): number {\n  return round(2 * r * 3);\n}\n";
pub const util_src = "export function round(x: number): number {\n  return Math.round(x);\n}\n";
pub const app_src = "import { area, perimeter } from \"./math\";\nexport function total(r: number): number {\n  return area(r) + perimeter(r);\n}\n";

pub const math_new = "import { round } from \"./util\";\nexport function perimeter(r: number): number {\n  return round(2 * r * 3);\n}\n";
pub const shapes_new = "import { round } from \"./util\";\nexport function area(r: number): number {\n  return round(r * r * 3);\n}\n";
pub const app_new = "import { perimeter } from \"./math\";\nimport { area } from \"./shapes\";\nexport function total(r: number): number {\n  return area(r) + perimeter(r);\n}\n";

pub const area_refs = [_]Loc{
    .{ .rel = "src/math.ts", .needle = "function area", .name = "area", .definition = true },
    .{ .rel = "src/app.ts", .needle = "{ area", .name = "area" },
    .{ .rel = "src/app.ts", .needle = "area(r)", .name = "area" },
};

pub fn initMath(case: *Case, math: []const u8, app: []const u8, extra: []const fixture.File, stub: bool) !void {
    var files: std.ArrayList(fixture.File) = .empty;
    defer files.deinit(testing.allocator);
    try files.appendSlice(testing.allocator, &.{ .{ .rel = "src/math.ts", .text = math }, .{ .rel = "src/util.ts", .text = util_src }, .{ .rel = "src/app.ts", .text = app } });
    try files.appendSlice(testing.allocator, extra);
    try case.init(files.items, stub);
}

pub fn plan(case: *Case, refs: []const Loc) !void {
    const json = try fixture.locationsJson(testing.allocator, &case.repo, "references", refs);
    defer testing.allocator.free(json);
    try case.repo.setPlan(json);
}

fn hashOf(case: *Case, file: []const u8, ref_text: []const u8) !symbol.Hash {
    const snapshot = try Snapshot.load(case.runtime, testing.io, .cwd(), file);
    defer snapshot.destroy();
    const table = try snapshot.symbols();
    const ref = try symbol.Ref.parse(testing.allocator, ref_text);
    defer ref.deinit(testing.allocator);
    if (table.resolve(ref)) |found| return found.hash else |_| {}
    for (table.declarations) |d| if (d.ref.eql(ref)) return d.hash;
    return error.SymbolNotFound;
}

pub const MoveArgs = struct {
    interface_change: bool = true,
    order_change: bool = false,
    step: ?*const disk.Step = null,
    test_command: []const u8 = "cmd /c exit 0",
};

pub fn move(case: *Case, rel: []const u8, ref_text: []const u8, target_rel: []const u8, args: MoveArgs) !move_batch.Outcome {
    const file = try case.repo.abs(testing.allocator, rel);
    defer testing.allocator.free(file);
    const target = try case.repo.abs(testing.allocator, target_rel);
    defer testing.allocator.free(target);
    return move_batch.tryMove(testing.allocator, testing.io, case.runtime, .{
        .request = .{ .file_abs = file, .ref_text = ref_text, .expected_hash = try hashOf(case, file, ref_text), .target_abs = target, .interface_change = args.interface_change, .order_change = args.order_change },
        .test_command = args.test_command,
        .commit_step = args.step,
        .language_service = &case.session,
    });
}

fn expectOld(case: *Case) !void {
    try case.expectFile("src/math.ts", math_src);
    try case.expectFile("src/app.ts", app_src);
    try testing.expect(!case.repo.exists("src/shapes.ts"));
}

test "move: a function goes to a new file with its import, and its user imports it from there" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try initMath(&case, math_src, app_src, &.{}, true);
    defer case.deinit();
    try plan(&case, &area_refs);
    const outcome = try move(&case, "src/math.ts", "area", "src/shapes.ts", .{});
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try testing.expectEqual(move_batch.Resolver.language_service, outcome.plan.resolver);
    try testing.expect(outcome.plan.creates_target);
    try testing.expectEqual(@as(usize, 1), outcome.plan.users);
    try case.expectFile("src/math.ts", math_new);
    try case.expectFile("src/shapes.ts", shapes_new);
    try case.expectFile("src/app.ts", app_new);
}

test "move: an exported symbol needs interface_change and a failing test writes nothing" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try initMath(&case, math_src, app_src, &.{}, true);
    defer case.deinit();
    try plan(&case, &area_refs);
    try testing.expectError(error.InterfaceChangeNeedsApproval, move(&case, "src/math.ts", "area", "src/shapes.ts", .{ .interface_change = false }));
    const outcome = try move(&case, "src/math.ts", "area", "src/shapes.ts", .{ .test_command = "cmd /c exit 1" });
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .rejected);
    try expectOld(&case);
}

test "move: an existing target keeps its code and gets the import at the top and the declaration at the end" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try initMath(&case, math_src, app_src, &.{.{ .rel = "src/shapes.ts", .text = "export const sides = 4;\n" }}, true);
    defer case.deinit();
    try plan(&case, &area_refs);
    const outcome = try move(&case, "src/math.ts", "area", "src/shapes.ts", .{});
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try testing.expect(!outcome.plan.creates_target);
    try case.expectFile("src/shapes.ts", "import { round } from \"./util\";\nexport const sides = 4;\n\nexport function area(r: number): number {\n  return round(r * r * 3);\n}\n");
}

test "move: the tool reports the class, the files and the derived imports" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try initMath(&case, math_src, app_src, &.{}, true);
    defer case.deinit();
    try plan(&case, &area_refs);
    const file = try case.repo.abs(testing.allocator, "src/math.ts");
    defer testing.allocator.free(file);
    const target = try case.repo.abs(testing.allocator, "src/shapes.ts");
    defer testing.allocator.free(target);
    const hash = symbol.formatHash(try hashOf(&case, file, "area"));
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var args: std.json.ObjectMap = .empty;
    try args.put(arena, "file", .{ .string = file });
    try args.put(arena, "symbol", .{ .string = "area" });
    try args.put(arena, "hash", .{ .string = &hash });
    try args.put(arena, "target_file", .{ .string = target });
    try args.put(arena, "interface_change", .{ .bool = true });
    var event: telemetry.Event = .{ .tool = "emetgate_move" };
    const result = try handlers.callTool(testing.allocator, testing.io, case.runtime, "emetgate_move", .{ .object = args }, &event, .{ .root = case.repo.root_abs, .test_command = "cmd /c exit 0", .language_service = &case.session });
    defer testing.allocator.free(result.text);
    errdefer std.debug.print("{s}\n", .{result.text});
    try testing.expect(!result.is_error);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result.text, .{});
    defer parsed.deinit();
    const body = parsed.value.object;
    try testing.expectEqualStrings("symmetry", body.get("class").?.string);
    try testing.expect(body.get("created_target").?.bool);
    try testing.expectEqual(@as(i64, 2), body.get("imports_added").?.integer);
    try testing.expectEqual(@as(usize, 3), body.get("files").?.array.items.len);
    try case.expectFile("src/app.ts", app_new);
}

test "move: without the language service a local unused declaration moves, an exported one is unresolved" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const math = "function scale(x: number): number {\n  return x * 2;\n}\n" ++ math_src;
    var case: Case = undefined;
    try initMath(&case, math, app_src, &.{}, false);
    defer case.deinit();
    try testing.expectError(error.MoveUnresolved, move(&case, "src/math.ts", "area", "src/shapes.ts", .{}));
    const outcome = try move(&case, "src/math.ts", "scale", "src/scale.ts", .{ .interface_change = false });
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try testing.expectEqual(move_batch.Resolver.text, outcome.plan.resolver);
    try case.expectFile("src/scale.ts", "function scale(x: number): number {\n  return x * 2;\n}\n");
    try case.expectFile("src/math.ts", math_src);
}
