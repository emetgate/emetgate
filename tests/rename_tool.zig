const std = @import("std");
const builtin = @import("builtin");
const runner = @import("emetgate").runner;
const disk = @import("emetgate").disk;
const tsserver = @import("emetgate").tsserver;
const rename_batch = @import("emetgate").rename_batch;
const symbol = @import("emetgate").symbol;
const handlers = @import("emetgate").handlers;
const telemetry = @import("emetgate").telemetry;
const Runtime = @import("emetgate").runtime.Runtime;
const fixture = @import("ts_fixture.zig");
const support = @import("runner_support.zig");

const testing = std.testing;
const TsRepo = fixture.TsRepo;
const Loc = fixture.Loc;

pub const a_src = "export function add(a: number, b: number): number {\n  return a + b;\n}\n";
pub const b_src = "import { add } from \"./a\";\nexport function twice(x: number): number {\n  return add(x, x);\n}\n";
pub const c_src = "import { add } from \"./a\";\n// add is used here\nexport function thrice(x: number): string {\n  const label = \"add numbers\";\n  return add(add(x, x), x) + label;\n}\n";

pub const a_new = "export function sum(a: number, b: number): number {\n  return a + b;\n}\n";
pub const b_new = "import { sum } from \"./a\";\nexport function twice(x: number): number {\n  return sum(x, x);\n}\n";
pub const c_new = "import { sum } from \"./a\";\n// add is used here\nexport function thrice(x: number): string {\n  const label = \"add numbers\";\n  return sum(sum(x, x), x) + label;\n}\n";

pub const all_locations = [_]Loc{
    .{ .rel = "src/a.ts", .needle = "function add", .name = "add" },
    .{ .rel = "src/b.ts", .needle = "{ add }", .name = "add" },
    .{ .rel = "src/b.ts", .needle = "add(x, x)", .name = "add" },
    .{ .rel = "src/c.ts", .needle = "{ add }", .name = "add" },
    .{ .rel = "src/c.ts", .needle = "add(add", .name = "add" },
    .{ .rel = "src/c.ts", .needle = "(add(x", .name = "add" },
};

pub const Case = struct {
    repo: TsRepo,
    runtime: *Runtime,
    session: tsserver.Session,

    pub fn init(self: *Case, files: []const fixture.File, stub: bool) !void {
        self.repo = try TsRepo.init(files);
        errdefer self.repo.deinit();
        if (stub) try self.repo.installStub();
        self.runtime = try Runtime.create(testing.allocator);
        self.session = .{ .gpa = testing.allocator, .io = testing.io, .root = self.repo.root_abs, .options = .{ .timeout_ms = 20_000 } };
    }

    pub fn initThree(self: *Case) !void {
        try self.init(&.{ .{ .rel = "src/a.ts", .text = a_src }, .{ .rel = "src/b.ts", .text = b_src }, .{ .rel = "src/c.ts", .text = c_src } }, true);
    }

    pub fn deinit(self: *Case) void {
        self.session.deinit();
        self.runtime.destroy() catch @panic("live snapshots");
        self.repo.deinit();
    }

    pub fn plan(self: *Case, locs: []const Loc) !void {
        const json = try fixture.locationsJson(testing.allocator, &self.repo, "rename", locs);
        defer testing.allocator.free(json);
        try self.repo.setPlan(json);
    }

    pub fn rename(self: *Case, rel: []const u8, ref_text: []const u8, new_name: []const u8, interface_change: bool, step: ?*const disk.Step) !rename_batch.Outcome {
        return self.renameWith(rel, ref_text, new_name, interface_change, step, "cmd /c exit 0");
    }

    pub fn renameWith(self: *Case, rel: []const u8, ref_text: []const u8, new_name: []const u8, interface_change: bool, step: ?*const disk.Step, test_command: []const u8) !rename_batch.Outcome {
        const file = try self.repo.abs(testing.allocator, rel);
        defer testing.allocator.free(file);
        const hash = try support.hashOfRef(testing.allocator, testing.io, self.runtime, file, ref_text);
        return rename_batch.tryRename(testing.allocator, testing.io, self.runtime, .{
            .request = .{ .file_abs = file, .ref_text = ref_text, .expected_hash = hash, .new_name = new_name, .interface_change = interface_change },
            .test_command = test_command,
            .commit_step = step,
            .language_service = &self.session,
        });
    }

    pub fn expectFile(self: *Case, rel: []const u8, expected: []const u8) !void {
        const text = try self.repo.read(rel);
        defer testing.allocator.free(text);
        try testing.expectEqualStrings(expected, text);
    }

    pub fn expectOld(self: *Case) !void {
        try self.expectFile("src/a.ts", a_src);
        try self.expectFile("src/b.ts", b_src);
        try self.expectFile("src/c.ts", c_src);
    }

    pub fn expectNew(self: *Case) !void {
        try self.expectFile("src/a.ts", a_new);
        try self.expectFile("src/b.ts", b_new);
        try self.expectFile("src/c.ts", c_new);
    }
};

test "rename: the language service proposes, the kernel proves, and all three files change in one batch" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.initThree();
    defer case.deinit();
    try case.plan(&all_locations);
    const outcome = try case.rename("src/a.ts", "add", "sum", true, null);
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try testing.expectEqual(rename_batch.Resolver.language_service, outcome.plan.resolver);
    try testing.expect(outcome.plan.interface_change);
    try testing.expectEqual(@as(usize, 3), outcome.plan.prepared.len);
    try testing.expectEqualStrings("sum", outcome.plan.new_ref);
    try case.expectNew();
}

test "rename: a rename that reaches other modules is refused without the interface_change approval" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.initThree();
    defer case.deinit();
    try case.plan(&all_locations);
    try testing.expectError(error.InterfaceChangeNeedsApproval, case.rename("src/a.ts", "add", "sum", false, null));
    try case.expectOld();
}

test "rename: an exported symbol with no other user still needs the interface_change approval" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&.{.{ .rel = "src/a.ts", .text = a_src }}, true);
    defer case.deinit();
    try case.plan(&.{.{ .rel = "src/a.ts", .needle = "function add", .name = "add" }});
    try testing.expectError(error.InterfaceChangeNeedsApproval, case.rename("src/a.ts", "add", "sum", false, null));
    try case.expectFile("src/a.ts", a_src);
}

test "rename: a failing test command rejects the rename and writes nothing" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.initThree();
    defer case.deinit();
    try case.plan(&all_locations);
    const file = try case.repo.abs(testing.allocator, "src/a.ts");
    defer testing.allocator.free(file);
    const outcome = try case.renameWith("src/a.ts", "add", "sum", true, null, "cmd /c exit 1");
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .rejected);
    try case.expectOld();
}

test "rename: a stale symbol hash is refused before the language service is asked" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.initThree();
    defer case.deinit();
    try case.plan(&all_locations);
    const file = try case.repo.abs(testing.allocator, "src/a.ts");
    defer testing.allocator.free(file);
    try testing.expectError(error.HashMismatch, rename_batch.tryRename(testing.allocator, testing.io, case.runtime, .{
        .request = .{ .file_abs = file, .ref_text = "add", .expected_hash = symbol.hashOf("stale"), .new_name = "sum", .interface_change = true },
        .test_command = "cmd /c exit 0",
        .language_service = &case.session,
    }));
    try testing.expect(!(try case.session.get()).running());
}

const local_src = "function add(a: number): number {\n  return a + 1;\n}\nexport function twice(x: number): number {\n  return add(add(x));\n}\n";
const local_new = "function inc(a: number): number {\n  return a + 1;\n}\nexport function twice(x: number): number {\n  return inc(inc(x));\n}\n";

test "rename: without the language service a local unexported symbol is renamed by the text path and says so" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&.{ .{ .rel = "src/a.ts", .text = local_src }, .{ .rel = "src/b.ts", .text = "export const other = 1;\n" } }, false);
    defer case.deinit();
    const outcome = try case.rename("src/a.ts", "add", "inc", false, null);
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try testing.expectEqual(rename_batch.Resolver.text, outcome.plan.resolver);
    try testing.expectEqual(@as(?anyerror, error.TypeScriptNotInstalled), outcome.plan.fallback);
    try case.expectFile("src/a.ts", local_new);
}

test "rename: without the language service an exported symbol or a name another file mentions is unresolved" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    {
        var alone: Case = undefined;
        try alone.init(&.{.{ .rel = "src/a.ts", .text = a_src }}, false);
        defer alone.deinit();
        try testing.expectError(error.RenameUnresolved, alone.rename("src/a.ts", "add", "sum", true, null));
        try alone.expectFile("src/a.ts", a_src);
    }
    {
        var exported: Case = undefined;
        try exported.initThree();
        defer exported.deinit();
        try exported.repo.setPlan("{\"exit\":true}");
        try testing.expectError(error.RenameUnresolved, exported.rename("src/a.ts", "add", "sum", true, null));
        try exported.expectOld();
    }
    var mentioned: Case = undefined;
    try mentioned.init(&.{ .{ .rel = "src/a.ts", .text = local_src }, .{ .rel = "src/b.ts", .text = "// add lives in a.ts\nexport const other = 1;\n" } }, false);
    defer mentioned.deinit();
    try testing.expectError(error.RenameUnresolved, mentioned.rename("src/a.ts", "add", "inc", false, null));
    try mentioned.expectFile("src/a.ts", local_src);
}

test "rename: without the language service a local name with a second binder is unresolved" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const shadowed = "function add(a: number): number {\n  return a + 1;\n}\nexport function g(add: number): number {\n  return add;\n}\n";
    var case: Case = undefined;
    try case.init(&.{.{ .rel = "src/a.ts", .text = shadowed }}, false);
    defer case.deinit();
    try testing.expectError(error.RenameUnresolved, case.rename("src/a.ts", "add", "inc", false, null));
    try case.expectFile("src/a.ts", shadowed);
}

test "rename: the tool answers with the class, the resolver, the evidence and every touched file" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.initThree();
    defer case.deinit();
    try case.plan(&all_locations);
    const file = try case.repo.abs(testing.allocator, "src/a.ts");
    defer testing.allocator.free(file);
    const hash = symbol.formatHash(try support.hashOfRef(testing.allocator, testing.io, case.runtime, file, "add"));
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var args: std.json.ObjectMap = .empty;
    try args.put(arena, "file", .{ .string = file });
    try args.put(arena, "symbol", .{ .string = "add" });
    try args.put(arena, "hash", .{ .string = &hash });
    try args.put(arena, "new_name", .{ .string = "sum" });
    try args.put(arena, "interface_change", .{ .bool = true });
    var event: telemetry.Event = .{ .tool = "emetgate_rename" };
    const result = try handlers.callTool(testing.allocator, testing.io, case.runtime, "emetgate_rename", .{ .object = args }, &event, .{ .root = case.repo.root_abs, .test_command = "cmd /c exit 0", .language_service = &case.session });
    defer testing.allocator.free(result.text);
    errdefer std.debug.print("{s}\n", .{result.text});
    try testing.expect(!result.is_error);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result.text, .{});
    defer parsed.deinit();
    const body = parsed.value.object;
    try testing.expectEqualStrings("committed", body.get("status").?.string);
    try testing.expectEqualStrings("symmetry", body.get("class").?.string);
    try testing.expectEqualStrings("language_service", body.get("resolver").?.string);
    try testing.expectEqualStrings("sum", body.get("new_symbol").?.string);
    try testing.expect(body.get("interface_change").?.bool);
    try testing.expectEqual(@as(usize, 3), body.get("files").?.array.items.len);
    try testing.expect(body.get("evidence").?.object.get("alpha_regions").?.integer >= 5);
    try case.expectNew();
}
