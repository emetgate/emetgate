const std = @import("std");
const builtin = @import("builtin");
const file_move = @import("emetgate").file_move;
const disk = @import("emetgate").disk;
const symbol = @import("emetgate").symbol;
const fixture = @import("ts_fixture.zig");
const tool = @import("rename_tool.zig");

const testing = std.testing;
pub const Case = tool.Case;

pub const util_src = "import { base } from \"./base\";\nexport function util(): number {\n  return base + 1;\n}\n";
pub const base_src = "export const base = 1;\n";
pub const app_src = "import { util } from \"./util\";\nexport const app = util();\n";
pub const lib_src = "import { util } from \"../util\";\nexport const lib = util() * 2;\n";

pub const util_new = "import { base } from \"../../base\";\nexport function util(): number {\n  return base + 1;\n}\n";
pub const app_new = "import { util } from \"./core/tools/util\";\nexport const app = util();\n";
pub const lib_new = "import { util } from \"../core/tools/util\";\nexport const lib = util() * 2;\n";

pub fn initFiles(case: *Case, extra: []const fixture.File, stub: bool) !void {
    var files: std.ArrayList(fixture.File) = .empty;
    defer files.deinit(testing.allocator);
    try files.appendSlice(testing.allocator, &.{
        .{ .rel = "src/util.ts", .text = util_src },
        .{ .rel = "src/base.ts", .text = base_src },
        .{ .rel = "src/app.ts", .text = app_src },
        .{ .rel = "src/lib/lib.ts", .text = lib_src },
    });
    try files.appendSlice(testing.allocator, extra);
    try case.init(files.items, stub);
}

const Change = struct { rel: []const u8, needle: []const u8, text: []const u8 };

pub const changes = [_]Change{
    .{ .rel = "src/util.ts", .needle = "./base", .text = "../../base" },
    .{ .rel = "src/app.ts", .needle = "./util", .text = "./core/tools/util" },
    .{ .rel = "src/lib/lib.ts", .needle = "../util", .text = "../core/tools/util" },
};

pub fn plan(case: *Case, list: []const Change) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer };
    try js.beginObject();
    try js.objectField("fileRename");
    try js.beginArray();
    for (list) |c| {
        const text = try case.repo.read(c.rel);
        defer testing.allocator.free(text);
        const start: u32 = @intCast(std.mem.indexOf(u8, text, c.needle).?);
        const file = try case.repo.slashed(testing.allocator, c.rel);
        defer testing.allocator.free(file);
        try js.write(.{ .file = file, .start = start, .end = start + @as(u32, @intCast(c.needle.len)), .text = c.text });
    }
    try js.endArray();
    try js.endObject();
    try case.repo.setPlan(out.written());
}

pub const Args = struct {
    to: []const u8 = "src/core/tools/util.ts",
    from: []const u8 = "src/util.ts",
    hash: ?symbol.Hash = null,
    interface_change: bool = false,
    step: ?*const disk.Step = null,
};

pub fn moveFile(case: *Case, args: Args) !file_move.Outcome {
    const from = try case.repo.abs(testing.allocator, args.from);
    defer testing.allocator.free(from);
    const to = try case.repo.abs(testing.allocator, args.to);
    defer testing.allocator.free(to);
    const text = try case.repo.read(args.from);
    defer testing.allocator.free(text);
    return file_move.tryMoveFile(testing.allocator, testing.io, case.runtime, .{
        .request = .{ .from_abs = from, .to_abs = to, .from_hash = args.hash orelse symbol.fileHash(text), .interface_change = args.interface_change },
        .test_command = "cmd /c exit 0",
        .commit_step = args.step,
        .language_service = &case.session,
    });
}

pub fn tracked(case: *Case, rel: []const u8) !bool {
    const result = try std.process.run(testing.allocator, testing.io, .{ .argv = &.{ "git", "ls-files", "--", rel }, .cwd = .{ .path = case.repo.root_abs } });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    return std.mem.trim(u8, result.stdout, " \r\n").len != 0;
}

pub fn expectOld(case: *Case) !void {
    try case.expectFile("src/util.ts", util_src);
    try case.expectFile("src/app.ts", app_src);
    try case.expectFile("src/lib/lib.ts", lib_src);
    try testing.expect(!case.repo.exists("src/core"));
}

pub fn expectNew(case: *Case) !void {
    try testing.expect(!case.repo.exists("src/util.ts"));
    try case.expectFile("src/core/tools/util.ts", util_new);
    try case.expectFile("src/app.ts", app_new);
    try case.expectFile("src/lib/lib.ts", lib_new);
    try testing.expect(!try tracked(case, "src/util.ts"));
    try testing.expect(try tracked(case, "src/core/tools/util.ts"));
}

test "move file: a file moves into two new directories and every import to and from it is rewritten" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try initFiles(&case, &.{}, true);
    defer case.deinit();
    try plan(&case, &changes);
    const outcome = try moveFile(&case, .{});
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try testing.expectEqual(file_move.Resolver.language_service, outcome.plan.resolver);
    try testing.expectEqual(@as(usize, 2), outcome.plan.created_dirs.len);
    try testing.expectEqual(@as(usize, 2), outcome.plan.users);
    try testing.expectEqual(@as(usize, 3), outcome.plan.rewritten);
    try expectNew(&case);
}

test "move file: the language service proposing a different edit set is refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try initFiles(&case, &.{}, true);
    defer case.deinit();
    try plan(&case, changes[0..2]);
    try testing.expectError(error.ServiceMismatch, moveFile(&case, .{}));
    const wrong = [_]Change{ changes[0], changes[1], .{ .rel = "src/lib/lib.ts", .needle = "../util", .text = "../core/tools/util.js" } };
    try plan(&case, &wrong);
    try testing.expectError(error.ServiceMismatch, moveFile(&case, .{}));
    try expectOld(&case);
}

test "move file: an existing target, a case-only rename, a stale hash and a target outside the repo are refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try initFiles(&case, &.{}, true);
    defer case.deinit();
    try plan(&case, &changes);
    try testing.expectError(error.NoClobber, moveFile(&case, .{ .to = "src/base.ts" }));
    try testing.expectError(error.CaseOnlyRename, moveFile(&case, .{ .to = "src/Util.ts" }));
    try testing.expectError(error.HashMismatch, moveFile(&case, .{ .hash = symbol.hashOf("stale") }));
    try testing.expectError(error.FileOutsideRepo, file_move.jailDestination(testing.allocator, testing.io, case.repo.root_abs, "C:\\Windows\\x.ts"));
    const git_path = try case.repo.abs(testing.allocator, ".git/x.ts");
    defer testing.allocator.free(git_path);
    try testing.expectError(error.InternalPath, file_move.jailDestination(testing.allocator, testing.io, case.repo.root_abs, git_path));
    try expectOld(&case);
}

test "move file: a require or a computed import that reaches the file is refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const variants = [_][]const u8{
        "const u = require(\"./util\");\nexport const x = u.util();\n",
        "export async function load(name: string) {\n  return import(\"./\" + name);\n}\nexport const util = 1;\n",
    };
    for (variants) |extra| {
        errdefer std.debug.print("variant: {s}\n", .{extra});
        var case: Case = undefined;
        try initFiles(&case, &.{.{ .rel = "src/dyn.ts", .text = extra }}, true);
        defer case.deinit();
        try plan(&case, &changes);
        try testing.expectError(error.DynamicPathUse, moveFile(&case, .{}));
        try expectOld(&case);
    }
}

test "move file: a file package.json or tsconfig paths names needs interface_change" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const manifests = [_]fixture.File{
        .{ .rel = "package.json", .text = "{\"name\":\"x\",\"main\":\"./src/util.js\"}" },
        .{ .rel = "tsconfig.json", .text = "{\"compilerOptions\":{\"paths\":{\"@util\":[\"src/util.ts\"]}}}" },
    };
    for (manifests) |m| {
        errdefer std.debug.print("manifest: {s}\n", .{m.rel});
        var case: Case = undefined;
        try initFiles(&case, &.{m}, true);
        defer case.deinit();
        try plan(&case, &changes);
        try testing.expectError(error.InterfaceChangeNeedsApproval, moveFile(&case, .{}));
        const outcome = try moveFile(&case, .{ .interface_change = true });
        defer outcome.deinit(testing.allocator);
        try testing.expect(outcome.result == .committed);
    }
}

test "move file: without the language service only a file nothing imports moves" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try initFiles(&case, &.{}, false);
    defer case.deinit();
    try testing.expectError(error.FileMoveUnresolved, moveFile(&case, .{}));
    const outcome = try moveFile(&case, .{ .from = "src/app.ts", .to = "src/entry/app.ts" });
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try testing.expectEqual(file_move.Resolver.text, outcome.plan.resolver);
    try case.expectFile("src/entry/app.ts", "import { util } from \"../util\";\nexport const app = util();\n");
}

test "move file: the proof catches a user left behind and an own import left unrewritten" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    defer file_move.injected_fault = null;
    const cases = [_]struct { fault: file_move.Fault, list: []const Change, err: anyerror }{
        .{ .fault = .skip_user, .list = &.{ changes[0], changes[2] }, .err = error.IncompleteMove },
        .{ .fault = .skip_own_import, .list = changes[1..3], .err = error.MovedImportBroken },
    };
    for (cases) |c| {
        errdefer std.debug.print("fault {t}\n", .{c.fault});
        var case: Case = undefined;
        try initFiles(&case, &.{}, true);
        defer case.deinit();
        try plan(&case, c.list);
        file_move.injected_fault = c.fault;
        try testing.expectError(c.err, moveFile(&case, .{}));
        file_move.injected_fault = null;
        try expectOld(&case);
    }
}
