const std = @import("std");
const builtin = @import("builtin");
const fixture = @import("ts_fixture.zig");
const common = @import("commit_batch.zig");
const first = @import("every_write.zig");
const rename_case = @import("rename_tool.zig");
const move_case = @import("move_tool.zig");
const move_file_case = @import("move_file_tool.zig");

const testing = std.testing;
const Plain = common.Plain;
const Env = common.Env;
const green = common.green;
const ignore = common.ignore;
const message = first.message;
const enforce = first.enforce;
const capture = first.capture;
const expectRefused = first.expectRefused;
const body = first.body;
const rename = first.rename;
const move = first.move;
const moveFile = first.moveFile;

const evil_query = "q:((identifier) @violation (#eq? @violation \"evil\"))";
const evil_body = "{ const evil = 1; return evil; }";
const two_src = "function helper(x) {\n  return x + 1;\n}\nexport function main(y) {\n  return helper(y);\n}\n";
const three_src = two_src ++ "export function spare() {\n  return 3;\n}\n";
const main_src = "export function main(y) {\n  return y;\n}\n";
const f_src = "function f() {\n  return 1;\n}\nexport function keep() {\n  return 2;\n}\n";
const base_src = "export function base() {\n  return 9;\n}\n";
const keep_src = "export function already() {\n  return 1;\n}\n";
const token_src = "export const X = \"networkidle-token\";\n";
const commented_src = "export function g() {\n  // a banned comment\n  return 1;\n}\n";
const b_src = "export const B = 1;\nexport function touch() {\n  return B;\n}\n";
const a_src = "import { B } from \"./b\";\nexport const A = B + 1;\n";

fn skipOffWindows() !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
}

test "leaving a scope: a file move that takes the file out of a rule scoped to it is refused" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ .{ .rel = "src/a.ts", .text = main_src }, ignore });
    defer case.deinit();
    const env = &case.env;
    try enforce(case.repo.root_abs, "forbid:evil", "src/a.ts");
    const before = try capture(env);
    try expectRefused(env, try body(env, "src/a.ts", "main", evil_body, true), before, "forbid:evil");
    try expectRefused(env, try moveFile(env, "src/a.ts", "src/z.ts", true), before, "forbid:evil");
    try testing.expect(case.repo.exists("src/a.ts"));
    try testing.expect(!case.repo.exists("src/z.ts"));
}

test "leaving a scope: a rename of the symbol a rule is scoped to is refused" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ .{ .rel = "src/a.ts", .text = two_src }, ignore });
    defer case.deinit();
    const env = &case.env;
    try enforce(case.repo.root_abs, "forbid:evil", "src/a.ts#helper");
    const before = try capture(env);
    try expectRefused(env, try body(env, "src/a.ts", "helper", evil_body, true), before, "forbid:evil");
    try expectRefused(env, try rename(env, "src/a.ts", "helper", "worker", true), before, "forbid:evil");
    try testing.expectEqualStrings(two_src, try env.read("src/a.ts"));
}

test "leaving a scope: a move of the symbol a rule is scoped to is refused" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ .{ .rel = "src/a.ts", .text = f_src }, .{ .rel = "src/b.ts", .text = base_src }, ignore });
    defer case.deinit();
    const env = &case.env;
    try enforce(case.repo.root_abs, "forbid:evil", "src/a.ts#f");
    const before = try capture(env);
    try expectRefused(env, try body(env, "src/a.ts", "f", evil_body, true), before, "forbid:evil");
    try expectRefused(env, try move(env, "src/a.ts", "f", "src/b.ts"), before, "forbid:evil");
    try testing.expectEqualStrings(f_src, try env.read("src/a.ts"));
    try testing.expectEqualStrings(base_src, try env.read("src/b.ts"));
}

test "leaving a scope: a batch that deletes the file a rule is scoped to is refused" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ .{ .rel = "src/a.ts", .text = main_src }, .{ .rel = "src/k.ts", .text = keep_src }, ignore });
    defer case.deinit();
    const env = &case.env;
    try enforce(case.repo.root_abs, "forbid:evil", "src/a.ts");
    const before = try capture(env);
    try expectRefused(env, try body(env, "src/a.ts", "main", evil_body, true), before, "forbid:evil");
    const edits = .{.{ .file = try env.abs("src/a.ts"), .op = "delete", .hash = try env.fileHash("src/a.ts") }};
    try expectRefused(env, try env.call("emetgate_try_batch", .{ .edits = edits, .message = message }, green, true), before, "forbid:evil");
    try testing.expect(case.repo.exists("src/a.ts"));
}

test "leaving a scope: a batch that deletes the symbol a rule is scoped to is refused" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ .{ .rel = "src/a.ts", .text = f_src }, ignore });
    defer case.deinit();
    const env = &case.env;
    try enforce(case.repo.root_abs, "forbid:evil", "src/a.ts#f");
    const before = try capture(env);
    try expectRefused(env, try body(env, "src/a.ts", "f", evil_body, true), before, "forbid:evil");
    const edits = .{.{ .file = try env.abs("src/a.ts"), .op = "delete", .symbol = "f", .hash = try env.hashOf("src/a.ts", "f") }};
    try expectRefused(env, try env.call("emetgate_try_batch", .{ .edits = edits, .message = message }, green, true), before, "forbid:evil");
    try testing.expectEqualStrings(f_src, try env.read("src/a.ts"));
}

test "leaving a scope: a file move out of a directory a rule is scoped to is refused" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ .{ .rel = "src/inside/keep.ts", .text = keep_src }, .{ .rel = "src/inside/stay.ts", .text = base_src }, ignore });
    defer case.deinit();
    const env = &case.env;
    try enforce(case.repo.root_abs, "forbid:evil", "src/inside/");
    const before = try capture(env);
    try expectRefused(env, try body(env, "src/inside/keep.ts", "already", evil_body, true), before, "forbid:evil");
    try expectRefused(env, try moveFile(env, "src/inside/keep.ts", "src/outside/keep.ts", true), before, "forbid:evil");
    try testing.expect(case.repo.exists("src/inside/keep.ts"));
    try testing.expect(!case.repo.exists("src/outside/keep.ts"));
}

fn finds(comptime token: []const u8) []const u8 {
    return "cmd:findstr /s /m /l /c:" ++ token ++ " src\\*.ts >nul && exit 1 || exit 0";
}

const move_files = [_]fixture.File{
    .{ .rel = "src/util.ts", .text = "export const HELPER = 1;\n" },
    .{ .rel = "src/outside/a.ts", .text = "import { HELPER } from \"../util\";\nfunction lonely() {\n  return HELPER + 1;\n}\nexport function keep() {\n  return 2;\n}\n" },
    .{ .rel = "src/deep/inner/t.ts", .text = base_src },
    ignore,
};
const rename_files = [_]fixture.File{ .{ .rel = "src/a.ts", .text = three_src }, ignore };
const import_files = [_]fixture.File{ .{ .rel = "src/b.ts", .text = b_src }, .{ .rel = "src/a.ts", .text = a_src }, ignore };

const CommandCase = struct {
    files: []const fixture.File,
    token: []const u8,
    check: []const u8,
    where: ?[]const u8,
    control: [2][]const u8,
    tool: enum { rename, move, move_file },
};

fn expectCommandRan(one: CommandCase) !void {
    var case: Plain = undefined;
    try case.init(one.files);
    defer case.deinit();
    const env = &case.env;
    try enforce(case.repo.root_abs, one.check, one.where);
    const before = try capture(env);
    const marked = try std.fmt.allocPrint(env.arena(), "{{ return \"{s}\"; }}", .{one.token});
    try expectRefused(env, try body(env, one.control[0], one.control[1], marked, true), before, "findstr");
    const reply = switch (one.tool) {
        .rename => try rename(env, "src/a.ts", "helper", "evilName", true),
        .move => try move(env, "src/outside/a.ts", "lonely", "src/deep/inner/t.ts"),
        .move_file => try moveFile(env, "src/a.ts", "src/sub/a.ts", true),
    };
    try expectRefused(env, reply, before, "findstr");
}

test "command rules: one with no scope runs on a rename and on a symbol move" {
    try skipOffWindows();
    try expectCommandRan(.{ .files = &rename_files, .token = "evilName", .check = finds("evilName"), .where = null, .control = .{ "src/a.ts", "spare" }, .tool = .rename });
    try expectCommandRan(.{ .files = &move_files, .token = "../../util", .check = finds("../../util"), .where = null, .control = .{ "src/deep/inner/t.ts", "base" }, .tool = .move });
}

test "command rules: one scoped to another symbol of the file runs on a rename" {
    try skipOffWindows();
    try expectCommandRan(.{ .files = &rename_files, .token = "evilName", .check = finds("evilName"), .where = "src/a.ts#main", .control = .{ "src/a.ts", "main" }, .tool = .rename });
}

test "command rules: one scoped to another symbol of the target runs on a symbol move" {
    try skipOffWindows();
    try expectCommandRan(.{ .files = &move_files, .token = "../../util", .check = finds("../../util"), .where = "src/deep/inner/t.ts#base", .control = .{ "src/deep/inner/t.ts", "base" }, .tool = .move });
}

test "command rules: one scoped to the directory a symbol leaves runs on the move" {
    try skipOffWindows();
    try expectCommandRan(.{ .files = &move_files, .token = "../../util", .check = finds("../../util"), .where = "src/outside/", .control = .{ "src/outside/a.ts", "keep" }, .tool = .move });
}

test "command rules: one with no scope runs on a file move" {
    try skipOffWindows();
    try expectCommandRan(.{ .files = &import_files, .token = "../b", .check = finds("../b"), .where = null, .control = .{ "src/b.ts", "touch" }, .tool = .move_file });
}

test "command rules: one scoped to a directory runs on a file move inside it" {
    try skipOffWindows();
    try expectCommandRan(.{ .files = &import_files, .token = "../b", .check = finds("../b"), .where = "src/", .control = .{ "src/b.ts", "touch" }, .tool = .move_file });
}

test "added rules: the new name of a rename is counted" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ .{ .rel = "src/a.ts", .text = two_src }, ignore });
    defer case.deinit();
    const env = &case.env;
    try enforce(case.repo.root_abs, "added:forbid:evil", null);
    const before = try capture(env);
    try expectRefused(env, try body(env, "src/a.ts", "main", evil_body, true), before, "added:forbid:evil");
    try expectRefused(env, try rename(env, "src/a.ts", "helper", "evilName", true), before, "added:forbid:evil");
    try testing.expectEqualStrings(two_src, try env.read("src/a.ts"));
}

test "added rules: an identifier a query rule forbids is counted when a rename creates it" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ .{ .rel = "src/a.ts", .text = two_src }, ignore });
    defer case.deinit();
    const env = &case.env;
    try enforce(case.repo.root_abs, "added:" ++ evil_query, null);
    const before = try capture(env);
    try expectRefused(env, try body(env, "src/a.ts", "main", "{ let evil = y; return evil; }", true), before, "@violation");
    try expectRefused(env, try rename(env, "src/a.ts", "helper", "evil", true), before, "@violation");
    try testing.expectEqualStrings(two_src, try env.read("src/a.ts"));
}

test "added rules: a file moved into the scope is added in full" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ .{ .rel = "src/outside/mod.ts", .text = token_src }, .{ .rel = "src/inside/keep.ts", .text = keep_src }, ignore });
    defer case.deinit();
    const env = &case.env;
    try enforce(case.repo.root_abs, "added:forbid:networkidle", "src/inside/");
    const before = try capture(env);
    try expectRefused(env, try body(env, "src/inside/keep.ts", "already", "{ return \"networkidle\"; }", true), before, "added:forbid:networkidle");
    try expectRefused(env, try moveFile(env, "src/outside/mod.ts", "src/inside/mod.ts", true), before, "added:forbid:networkidle");
    try testing.expect(!case.repo.exists("src/inside/mod.ts"));
}

test "added rules: the import a file move rewrites is counted" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&import_files);
    defer case.deinit();
    const env = &case.env;
    try enforce(case.repo.root_abs, "added:forbid:../b", null);
    const before = try capture(env);
    try expectRefused(env, try body(env, "src/b.ts", "touch", "{ const p = \"../b\"; return p.length; }", true), before, "added:forbid:../b");
    try expectRefused(env, try moveFile(env, "src/a.ts", "src/sub/a.ts", true), before, "added:forbid:../b");
    try testing.expect(!case.repo.exists("src/sub/a.ts"));
}

test "added rules: the comments of a file moved into a no_comment scope are counted" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ .{ .rel = "src/outside/c.ts", .text = commented_src }, .{ .rel = "src/inside/keep.ts", .text = keep_src }, ignore });
    defer case.deinit();
    const env = &case.env;
    try enforce(case.repo.root_abs, "added:no_comment", "src/inside/");
    const before = try capture(env);
    try expectRefused(env, try body(env, "src/inside/keep.ts", "already", "{ // nope\n  return 2; }", true), before, "added:no_comment");
    try expectRefused(env, try moveFile(env, "src/outside/c.ts", "src/inside/c.ts", true), before, "added:no_comment");
    try testing.expect(!case.repo.exists("src/inside/c.ts"));
}

pub const Served = struct {
    case: rename_case.Case,
    env: Env,

    pub fn deinit(self: *Served) void {
        self.env.deinit();
        self.case.deinit();
    }
};

test "other modules: a rename that puts a forbidden name into another module is refused" {
    try skipOffWindows();
    var served: Served = undefined;
    try served.case.init(&.{ .{ .rel = "src/a.ts", .text = rename_case.a_src }, .{ .rel = "src/b.ts", .text = rename_case.b_src }, .{ .rel = "src/c.ts", .text = rename_case.c_src }, ignore }, true);
    served.env = Env.init(&served.case.repo, served.case.runtime, &served.case.session);
    defer served.deinit();
    const env = &served.env;
    try enforce(served.case.repo.root_abs, "forbid:sum", "src/c.ts");
    const before = try capture(env);
    try served.case.plan(&rename_case.all_locations);
    const reply = try env.call("emetgate_rename", .{ .file = try env.abs("src/a.ts"), .symbol = "add", .hash = try env.hashOf("src/a.ts", "add"), .new_name = "sum", .interface_change = true, .message = message }, green, true);
    try expectRefused(env, reply, before, "forbid:sum");
    try testing.expectEqualStrings(rename_case.a_src, try env.read("src/a.ts"));
    try testing.expectEqualStrings(rename_case.c_src, try env.read("src/c.ts"));
}

test "other modules: a symbol move whose rewritten import in a user module is forbidden is refused" {
    try skipOffWindows();
    var served: Served = undefined;
    try move_case.initMath(&served.case, move_case.math_src, move_case.app_src, &.{ignore}, true);
    served.env = Env.init(&served.case.repo, served.case.runtime, &served.case.session);
    defer served.deinit();
    const env = &served.env;
    try enforce(served.case.repo.root_abs, "forbid:./shapes", "src/app.ts");
    const before = try capture(env);
    try move_case.plan(&served.case, &move_case.area_refs);
    const reply = try env.call("emetgate_move", .{ .file = try env.abs("src/math.ts"), .symbol = "area", .hash = try env.hashOf("src/math.ts", "area"), .target_file = try env.abs("src/shapes.ts"), .interface_change = true, .message = message }, green, true);
    try expectRefused(env, reply, before, "forbid:./shapes");
    try testing.expectEqualStrings(move_case.app_src, try env.read("src/app.ts"));
    try testing.expect(!served.case.repo.exists("src/shapes.ts"));
}

test "other modules: a file move whose rewritten import in an importing module is forbidden is refused" {
    try skipOffWindows();
    var served: Served = undefined;
    try move_file_case.initFiles(&served.case, &.{ignore}, true);
    served.env = Env.init(&served.case.repo, served.case.runtime, &served.case.session);
    defer served.deinit();
    const env = &served.env;
    try enforce(served.case.repo.root_abs, "forbid:core/tools", "src/app.ts");
    const before = try capture(env);
    try move_file_case.plan(&served.case, &move_file_case.changes);
    const reply = try env.call("emetgate_move_file", .{ .from = try env.abs("src/util.ts"), .to = try env.abs("src/core/tools/util.ts"), .from_hash = try env.fileHash("src/util.ts"), .message = message }, green, true);
    try expectRefused(env, reply, before, "forbid:core/tools");
    try testing.expectEqualStrings(move_file_case.app_src, try env.read("src/app.ts"));
    try testing.expect(served.case.repo.exists("src/util.ts"));
}
