const std = @import("std");
const builtin = @import("builtin");
const rename_batch = @import("emetgate").rename_batch;
const fixture = @import("ts_fixture.zig");
const tool = @import("rename_tool.zig");

const testing = std.testing;
const Case = tool.Case;
const Loc = fixture.Loc;

const shadow_src = "export function add(a: number): number {\n  return a + 1;\n}\nexport function g(add: number): number {\n  return add;\n}\nexport function h(): number {\n  return add(2);\n}\n";
const shadow_new = "export function sum(a: number): number {\n  return a + 1;\n}\nexport function g(add: number): number {\n  return add;\n}\nexport function h(): number {\n  return sum(2);\n}\n";

fn initShadow(case: *Case) !void {
    try case.init(&.{.{ .rel = "src/a.ts", .text = shadow_src }}, true);
}

test "red team rename: a shadowing parameter of the same name is left alone when the service leaves it" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try initShadow(&case);
    defer case.deinit();
    try case.plan(&.{ .{ .rel = "src/a.ts", .needle = "function add", .name = "add" }, .{ .rel = "src/a.ts", .needle = "add(2)", .name = "add" } });
    const outcome = try case.rename("src/a.ts", "add", "sum", true, null);
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try case.expectFile("src/a.ts", shadow_new);
}

test "red team rename: a service that renames the use of a shadowing parameter but not the parameter is refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try initShadow(&case);
    defer case.deinit();
    try case.plan(&.{
        .{ .rel = "src/a.ts", .needle = "function add", .name = "add" },
        .{ .rel = "src/a.ts", .needle = "return add;", .name = "add" },
        .{ .rel = "src/a.ts", .needle = "add(2)", .name = "add" },
    });
    try testing.expectError(error.ResolutionMismatch, case.rename("src/a.ts", "add", "sum", true, null));
    try case.expectFile("src/a.ts", shadow_src);
}

test "red team rename: a new name that another touched file already uses is refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.initThree();
    defer case.deinit();
    try case.plan(&tool.all_locations);
    try testing.expectError(error.NameTaken, case.rename("src/a.ts", "add", "twice", true, null));
    try testing.expectError(error.NameTaken, case.rename("src/a.ts", "add", "label", true, null));
    try case.expectOld();
}

test "red team rename: a location inside a comment or a string is refused and both stay unchanged" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.initThree();
    defer case.deinit();
    const in_comment = tool.all_locations ++ [_]Loc{.{ .rel = "src/c.ts", .needle = "// add", .name = "add" }};
    try case.plan(&in_comment);
    try testing.expectError(error.NotAnIdentifier, case.rename("src/a.ts", "add", "sum", true, null));
    const in_string = tool.all_locations ++ [_]Loc{.{ .rel = "src/c.ts", .needle = "\"add numbers", .name = "add" }};
    try case.plan(&in_string);
    try testing.expectError(error.NotAnIdentifier, case.rename("src/a.ts", "add", "sum", true, null));
    try case.expectOld();
}

test "red team rename: a service that skips a whole file that still calls the old name is refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.initThree();
    defer case.deinit();
    try case.plan(tool.all_locations[0..3]);
    try testing.expectError(error.IncompleteRename, case.rename("src/a.ts", "add", "sum", true, null));
    try case.expectOld();
}

test "red team rename: a service that skips one call in a touched file is refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.initThree();
    defer case.deinit();
    try case.plan(tool.all_locations[0..5]);
    try testing.expectError(error.IncompleteRename, case.rename("src/a.ts", "add", "sum", true, null));
    try case.plan(&.{ tool.all_locations[0], tool.all_locations[1], tool.all_locations[3], tool.all_locations[4], tool.all_locations[5] });
    try testing.expectError(error.IncompleteRename, case.rename("src/a.ts", "add", "sum", true, null));
    try case.expectOld();
}

test "red team rename: a location outside the repo or in an untracked file is refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.initThree();
    defer case.deinit();
    try case.repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "outside.ts", .data = "export function add(): number { return 1; }\n" });
    const outside = try case.repo.tmp.dir.realPathFileAlloc(testing.io, "outside.ts", testing.allocator);
    defer testing.allocator.free(outside);
    std.mem.replaceScalar(u8, outside, '\\', '/');
    const escaped = try std.fmt.allocPrint(testing.allocator, "{{\"rename\":[{{\"file\":\"{s}\",\"start\":16,\"end\":19}}]}}", .{outside});
    defer testing.allocator.free(escaped);
    try case.repo.setPlan(escaped);
    try testing.expectError(error.RenameOutsideRepo, case.rename("src/a.ts", "add", "sum", true, null));

    try case.repo.write("node_modules/dep/index.ts", "export function add(): number { return 1; }\n");
    const untracked = try case.repo.slashed(testing.allocator, "node_modules/dep/index.ts");
    defer testing.allocator.free(untracked);
    const plan = try std.fmt.allocPrint(testing.allocator, "{{\"rename\":[{{\"file\":\"{s}\",\"start\":16,\"end\":19}}]}}", .{untracked});
    defer testing.allocator.free(plan);
    try case.repo.setPlan(plan);
    try testing.expectError(error.RenameOutsideRepo, case.rename("src/a.ts", "add", "sum", true, null));
    try case.expectOld();
}

test "red team rename: a malicious tsconfig plugin is never loaded and the rename still goes through the service" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&.{
        .{ .rel = "src/a.ts", .text = tool.a_src },
        .{ .rel = "src/b.ts", .text = tool.b_src },
        .{ .rel = "src/c.ts", .text = tool.c_src },
        .{ .rel = "tsconfig.json", .text = "{\"compilerOptions\":{\"plugins\":[{\"name\":\"evil\"}]}}" },
    }, true);
    defer case.deinit();
    try case.plan(&tool.all_locations);
    const outcome = try case.rename("src/a.ts", "add", "sum", true, null);
    defer outcome.deinit(testing.allocator);
    try testing.expectEqual(rename_batch.Resolver.language_service, outcome.plan.resolver);
    try case.expectNew();
}

test "red team rename: a string key, eval or a computed require in a touched file is unresolved dynamic access" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const variants = [_][]const u8{
        "import { add } from \"./a\";\nexport function twice(x: number): number {\n  return add(x, x) + (globalThis as any)[\"add\"];\n}\n",
        "import { add } from \"./a\";\nexport function twice(x: number): number {\n  return add(x, x) + eval(\"1\");\n}\n",
        "import { add } from \"./a\";\nexport function twice(x: number): number {\n  return add(x, x) + require(\"./\" + \"a\").add;\n}\n",
    };
    for (variants) |b| {
        errdefer std.debug.print("variant: {s}\n", .{b});
        var case: Case = undefined;
        try case.init(&.{ .{ .rel = "src/a.ts", .text = tool.a_src }, .{ .rel = "src/b.ts", .text = b } }, true);
        defer case.deinit();
        try case.plan(&.{ tool.all_locations[0], tool.all_locations[1], tool.all_locations[2] });
        try testing.expectError(error.DynamicReference, case.rename("src/a.ts", "add", "sum", true, null));
        try case.expectFile("src/b.ts", b);
    }
}

test "red team rename: a shorthand property location and a refused rename info are both refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.initThree();
    defer case.deinit();
    var shorthand = tool.all_locations;
    shorthand[2].prefix = true;
    try case.plan(&shorthand);
    try testing.expectError(error.ShorthandReference, case.rename("src/a.ts", "add", "sum", true, null));
    try case.repo.setPlan("{\"canRename\":false}");
    try testing.expectError(error.RenameRefused, case.rename("src/a.ts", "add", "sum", true, null));
    try case.expectOld();
}
