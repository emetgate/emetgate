const std = @import("std");
const builtin = @import("builtin");
const runner = @import("emetgate").runner;
const tsserver = @import("emetgate").tsserver;
const symbol = @import("emetgate").symbol;
const Runtime = @import("emetgate").runtime.Runtime;
const fixture = @import("ts_fixture.zig");
const support = @import("runner_support.zig");

const testing = std.testing;
const TsRepo = fixture.TsRepo;

const a_src = "export function keep(): number {\n  return 1;\n}\nexport function drop(): number {\n  return 2;\n}\n";

const Case = struct {
    repo: TsRepo,
    runtime: *Runtime,
    session: tsserver.Session,

    fn init(self: *Case, b_src: []const u8, stub: bool) !void {
        self.repo = try TsRepo.init(&.{ .{ .rel = "src/a.ts", .text = a_src }, .{ .rel = "src/b.ts", .text = b_src } });
        errdefer self.repo.deinit();
        if (stub) try self.repo.installStub();
        self.runtime = try Runtime.create(testing.allocator);
        self.session = .{ .gpa = testing.allocator, .io = testing.io, .root = self.repo.root_abs, .options = .{ .timeout_ms = 20_000 } };
    }

    fn deinit(self: *Case) void {
        self.session.deinit();
        self.runtime.destroy() catch @panic("live snapshots");
        self.repo.deinit();
    }

    fn plan(self: *Case, locs: []const fixture.Loc) !void {
        const json = try fixture.locationsJson(testing.allocator, &self.repo, "references", locs);
        defer testing.allocator.free(json);
        try self.repo.setPlan(json);
    }

    fn deleteDrop(self: *Case, extra: ?runner.Edit) !runner.BatchResult {
        const a = try self.repo.abs(testing.allocator, "src/a.ts");
        defer testing.allocator.free(a);
        const hash = try support.hashOfRef(testing.allocator, testing.io, self.runtime, a, "drop");
        var edits: [2]runner.Edit = undefined;
        edits[0] = .{ .file_abs = a, .ref_text = "drop", .expected_hash = .{ .present = hash }, .op = .delete };
        var count: usize = 1;
        if (extra) |e| {
            edits[1] = e;
            count = 2;
        }
        return runner.tryMutateBatch(testing.allocator, testing.io, self.runtime, .{ .edits = edits[0..count], .test_command = "cmd /c exit 0", .language_service = &self.session });
    }

    fn expectDropped(self: *Case) !void {
        const text = try self.repo.read("src/a.ts");
        defer testing.allocator.free(text);
        try testing.expectEqualStrings("export function keep(): number {\n  return 1;\n}\n", text);
    }

    fn expectKept(self: *Case) !void {
        const text = try self.repo.read("src/a.ts");
        defer testing.allocator.free(text);
        try testing.expectEqualStrings(a_src, text);
    }
};

const declaration: fixture.Loc = .{ .rel = "src/a.ts", .needle = "function drop", .name = "drop", .definition = true };

test "delete references: a reference the language service reports in another file refuses the delete" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init("import { keep } from \"./a\";\nexport function g(): number {\n  return keep();\n}\n", true);
    defer case.deinit();
    try case.plan(&.{ declaration, .{ .rel = "src/b.ts", .needle = "keep", .name = "keep" } });
    try testing.expectError(error.SymbolReferenced, case.deleteDrop(null));
    try case.expectKept();
    try testing.expect((try case.session.get()).starts == 1);
}

test "delete references: a name only a comment elsewhere mentions is deleted when the language service finds no reference" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init("// drop used to live here\nexport function g(): number {\n  return 3;\n}\n", true);
    defer case.deinit();
    try case.plan(&.{declaration});
    const result = try case.deleteDrop(null);
    defer result.deinit(testing.allocator);
    try testing.expect(result == .committed);
    try case.expectDropped();
}

test "delete references: without the language service the text scan still refuses the comment mention" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init("// drop used to live here\nexport function g(): number {\n  return 3;\n}\n", false);
    defer case.deinit();
    try testing.expectError(error.SymbolReferenced, case.deleteDrop(null));
    try testing.expectEqual(@as(?anyerror, error.TypeScriptNotInstalled), case.session.last_error);
    try case.expectKept();
}

test "delete references: a quoted name elsewhere is dynamic access and refuses the delete even with no reference found" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init("import * as a from \"./a\";\nexport function g(): number {\n  return (a as any)[\"drop\"]();\n}\n", true);
    defer case.deinit();
    try case.plan(&.{declaration});
    try testing.expectError(error.SymbolReferenced, case.deleteDrop(null));
    try case.expectKept();
}

test "delete references: a reference in a file the same batch rewrites is judged on the new text" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init("import * as a from \"./a\";\nexport function g(): number {\n  return a.drop();\n}\n", true);
    defer case.deinit();
    try case.plan(&.{ declaration, .{ .rel = "src/b.ts", .needle = "a.drop", .name = "drop" } });
    const b = try case.repo.abs(testing.allocator, "src/b.ts");
    defer testing.allocator.free(b);
    const g_hash = try support.hashOfRef(testing.allocator, testing.io, case.runtime, b, "g");
    const result = try case.deleteDrop(.{ .file_abs = b, .ref_text = "g", .expected_hash = .{ .present = g_hash }, .new_body = "{\n  return 3;\n}" });
    defer result.deinit(testing.allocator);
    try testing.expect(result == .committed);
    try case.expectDropped();
}
