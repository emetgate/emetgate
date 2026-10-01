const std = @import("std");
const emetgate = @import("emetgate");
const fact_store = emetgate.fact_store;
const fact_file = emetgate.fact_file;
const facts_query = emetgate.facts_query;
const io_seam = emetgate.io_seam;
const answer = emetgate.answer;
const test_util = emetgate.test_util;
const git_fixture = @import("git_fixture.zig");

const testing = std.testing;

fn git(root: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(testing.allocator);
    try argv.append(testing.allocator, "git");
    try argv.appendSlice(testing.allocator, args);
    const result = try std.process.run(testing.allocator, testing.io, .{ .argv = argv.items, .cwd = .{ .path = root } });
    testing.allocator.free(result.stdout);
    testing.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitFailed,
        else => return error.GitFailed,
    }
}

const File = struct { path: []const u8, data: []const u8 };

const Fixture = struct {
    tmp: testing.TmpDir,
    root: []u8,
    store_path: []u8,
    real: io_seam.Real,

    fn init(files: []const File) !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo");
        for (files) |f| try writeIn(tmp.dir, f);
        const base = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        defer testing.allocator.free(base);
        const root = try std.fmt.allocPrint(testing.allocator, "{s}\\repo", .{base});
        errdefer testing.allocator.free(root);
        try git_fixture.initRepo(root);
        try git(root, &.{ "add", "." });
        return .{ .tmp = tmp, .root = root, .store_path = try std.fmt.allocPrint(testing.allocator, "{s}\\store\\facts.v{d}", .{ base, fact_file.version }), .real = io_seam.Real.init(testing.allocator, testing.io) };
    }

    fn writeIn(dir: std.Io.Dir, f: File) !void {
        const sub = try std.fmt.allocPrint(testing.allocator, "repo/{s}", .{f.path});
        defer testing.allocator.free(sub);
        if (std.fs.path.dirnamePosix(sub)) |d| try dir.createDirPath(testing.io, d);
        try dir.writeFile(testing.io, .{ .sub_path = sub, .data = f.data });
    }

    fn write(self: *Fixture, f: File) !void {
        try writeIn(self.tmp.dir, f);
        try git(self.root, &.{ "add", "." });
    }

    fn deinit(self: *Fixture) void {
        self.real.deinit();
        testing.allocator.free(self.root);
        testing.allocator.free(self.store_path);
        self.tmp.cleanup();
    }

    fn open(self: *Fixture, runtime: anytype, max_file_bytes: usize) !*fact_store.Repo {
        return fact_store.Repo.open(testing.allocator, self.real.seam(), runtime, .{ .root_abs = self.root, .store_path = self.store_path, .threads = 2, .max_file_bytes = max_file_bytes });
    }
};

fn callerPaths(arena: std.mem.Allocator, repo: *fact_store.Repo, subject: []const u8) ![]const []const u8 {
    const result = try repo.query(arena, .{ .relation = .callers, .subject = subject });
    const value = switch (result) {
        .complete => |c| c.value,
        .partial => |p| p.value,
        .refused => return error.Refused,
    };
    var out: std.ArrayList([]const u8) = .empty;
    for (value.sites) |s| try out.append(arena, s.path);
    return out.items;
}

test "fact store: a file edited on disk is extracted again on refresh and leaves no stale caller" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var fixture = try Fixture.init(&.{
        .{ .path = "a.ts", .data = "export function f() { return 1; }\n" },
        .{ .path = "b.ts", .data = "import { f } from \"./a\";\nexport function g() { return f(); }\n" },
        .{ .path = "c.ts", .data = "import { f } from \"./a\";\nexport function h() { return f(); }\n" },
    });
    defer fixture.deinit();
    const repo = try fixture.open(runtime, fact_store.default_max_file_bytes);
    defer repo.deinit();
    const first = try repo.refresh();
    try testing.expectEqual(@as(usize, 3), first.extracted);
    try testing.expect(first.full_link);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 2), (try callerPaths(arena.allocator(), repo, "f")).len);

    try fixture.write(.{ .path = "b.ts", .data = "import { f } from \"./a\";\nexport function g() { return 2; }\n" });
    const second = try repo.refresh();
    try testing.expectEqual(@as(usize, 1), second.extracted);
    try testing.expect(!second.full_link);
    const paths = try callerPaths(arena.allocator(), repo, "f");
    try testing.expectEqual(@as(usize, 1), paths.len);
    try testing.expectEqualStrings("c.ts", paths[0]);
}

test "fact store: a saved store opens again without extracting and answers the same" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var fixture = try Fixture.init(&.{
        .{ .path = "a.ts", .data = "export class C { go() { return 1; } }\n" },
        .{ .path = "b.ts", .data = "import { C } from \"./a\";\nexport function use(c: C) { return c.go(); }\n" },
    });
    defer fixture.deinit();
    var root_before: answer.Digest = undefined;
    {
        const repo = try fixture.open(runtime, fact_store.default_max_file_bytes);
        defer repo.deinit();
        const report = try repo.refresh();
        try testing.expect(report.saved);
        root_before = repo.snapshot().root;
    }
    const repo = try fixture.open(runtime, fact_store.default_max_file_bytes);
    defer repo.deinit();
    try testing.expectEqual(fact_store.Load.loaded, repo.load);
    const report = try repo.refresh();
    try testing.expectEqual(@as(usize, 0), report.extracted);
    try testing.expectEqual(@as(usize, 2), report.reused + report.rehashed);
    try testing.expect(!report.full_link);
    try testing.expectEqualSlices(u8, &root_before, &repo.snapshot().root);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const paths = try callerPaths(arena.allocator(), repo, "C.go");
    try testing.expectEqual(@as(usize, 1), paths.len);
    try testing.expectEqualStrings("b.ts", paths[0]);
}

test "fact store: a store file with one flipped byte is rebuilt and says why" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var fixture = try Fixture.init(&.{
        .{ .path = "a.ts", .data = "export function f() { return 1; }\n" },
        .{ .path = "b.ts", .data = "import { f } from \"./a\";\nexport function g() { return f(); }\n" },
    });
    defer fixture.deinit();
    {
        const repo = try fixture.open(runtime, fact_store.default_max_file_bytes);
        defer repo.deinit();
        _ = try repo.refresh();
    }
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, fixture.store_path, testing.allocator, .unlimited);
    defer testing.allocator.free(bytes);
    bytes[bytes.len / 2] ^= 0x40;
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = fixture.store_path, .data = bytes });
    const repo = try fixture.open(runtime, fact_store.default_max_file_bytes);
    defer repo.deinit();
    switch (repo.load) {
        .rebuilt => |why| try testing.expectEqualStrings("corrupt", why),
        else => return error.CorruptStoreAccepted,
    }
    const report = try repo.refresh();
    try testing.expectEqual(@as(usize, 2), report.extracted);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 1), (try callerPaths(arena.allocator(), repo, "f")).len);
}

test "fact store: a file over the size limit is never read as empty, it makes the answer partial with a declared limit" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(testing.allocator);
    try big.appendSlice(testing.allocator, "import { f } from \"./a\";\nexport function g() { return f(); }\n");
    for (0..200) |_| try big.appendSlice(testing.allocator, "// padding padding padding padding\n");
    var fixture = try Fixture.init(&.{
        .{ .path = "a.ts", .data = "export function f() { return 1; }\n" },
        .{ .path = "big.ts", .data = big.items },
    });
    defer fixture.deinit();
    const repo = try fixture.open(runtime, 4096);
    defer repo.deinit();
    _ = try repo.refresh();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try repo.query(arena.allocator(), .{ .relation = .callers, .subject = "f" });
    try testing.expectEqual(answer.Status.partial, result.status());
    const missing = result.missingList();
    try testing.expectEqual(@as(usize, 1), missing.len);
    try testing.expectEqual(answer.Reason.too_large, missing[0].reason);
    try testing.expectEqualStrings("big.ts", missing[0].path.?);
    try testing.expectEqual(answer.Limit.file_bytes, result.certificate().?.budgets[0].limit);
}

test "fact store: a workspace package name and a tsconfig path alias resolve to the source files" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var fixture = try Fixture.init(&.{
        .{ .path = "packages/core/package.json", .data = "{ \"name\": \"pkg-core\", \"main\": \"dist/index.js\" }\n" },
        .{ .path = "packages/core/tsconfig.build.json", .data = "{\n  // build\n  \"compilerOptions\": { \"rootDir\": \"src\", \"outDir\": \"dist\", },\n}\n" },
        .{ .path = "packages/core/src/index.ts", .data = "export * from \"./engine\";\n" },
        .{ .path = "packages/core/src/engine.ts", .data = "export class Engine { start() { return 1; } }\n" },
        .{ .path = "packages/cli/tsconfig.json", .data = "{ \"compilerOptions\": { \"paths\": { \"@/*\": [\"./src/*\"] } } }\n" },
        .{ .path = "packages/cli/src/run.ts", .data = "import { Engine } from \"pkg-core\";\nimport { helper } from \"@/util\";\nexport function run() { const e = new Engine(); return e.start() + helper(); }\n" },
        .{ .path = "packages/cli/src/util.ts", .data = "export function helper() { return 2; }\n" },
    });
    defer fixture.deinit();
    const repo = try fixture.open(runtime, fact_store.default_max_file_bytes);
    defer repo.deinit();
    _ = try repo.refresh();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const start = try callerPaths(arena.allocator(), repo, "Engine.start");
    try testing.expectEqual(@as(usize, 1), start.len);
    try testing.expectEqualStrings("packages/cli/src/run.ts", start[0]);
    const helper = try callerPaths(arena.allocator(), repo, "helper");
    try testing.expectEqual(@as(usize, 1), helper.len);
}

test "fact store: a tracked file whose directory is gone is reported unreadable and the failed listing is counted" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var fixture = try Fixture.init(&.{
        .{ .path = "a.ts", .data = "export function f() { return 1; }\n" },
        .{ .path = "gone/b.ts", .data = "import { f } from \"../a\";\nexport function g() { return f(); }\n" },
    });
    defer fixture.deinit();
    try fixture.tmp.dir.deleteTree(testing.io, "repo/gone");
    const repo = try fixture.open(runtime, fact_store.default_max_file_bytes);
    defer repo.deinit();
    const report = try repo.refresh();
    try testing.expectEqual(@as(usize, 1), report.stat_failures);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try repo.query(arena.allocator(), .{ .relation = .callers, .subject = "f" });
    try testing.expectEqual(answer.Status.partial, result.status());
    try testing.expectEqual(answer.Reason.unreadable, result.missingList()[0].reason);
    try testing.expectEqualStrings("gone/b.ts", result.missingList()[0].path.?);
}

test "fact store: an invalid package manifest is reported, never skipped in silence" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var fixture = try Fixture.init(&.{
        .{ .path = "a.ts", .data = "export function f() { return 1; }\n" },
        .{ .path = "pkg/package.json", .data = "{ \"name\": \"broken\", \n" },
    });
    defer fixture.deinit();
    const repo = try fixture.open(runtime, fact_store.default_max_file_bytes);
    defer repo.deinit();
    const report = try repo.refresh();
    try testing.expectEqual(@as(usize, 1), report.config_notes);
}

test "fact store: a store whose definition name was altered on disk is refused by its checksum and rebuilt" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var fixture = try Fixture.init(&.{
        .{ .path = "a.ts", .data = "export function distinctiveFlipTarget() { return 1; }\n" },
    });
    defer fixture.deinit();
    {
        const repo = try fixture.open(runtime, fact_store.default_max_file_bytes);
        defer repo.deinit();
        _ = try repo.refresh();
    }
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, fixture.store_path, testing.allocator, .unlimited);
    defer testing.allocator.free(bytes);
    const at = std.mem.indexOf(u8, bytes, "distinctiveFlipTarget") orelse return error.NameNotStored;
    bytes[at] = 'X';
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = fixture.store_path, .data = bytes });
    const repo = try fixture.open(runtime, fact_store.default_max_file_bytes);
    defer repo.deinit();
    switch (repo.load) {
        .rebuilt => |why| try testing.expectEqualStrings("corrupt", why),
        else => return error.AlteredStoreAccepted,
    }
}

test "fact store: an in-memory edit relinks the file and moves the snapshot root to the value a full recount gives" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var fixture = try Fixture.init(&.{
        .{ .path = "a.ts", .data = "export function f() { return 1; }\n" },
        .{ .path = "b.ts", .data = "import { f } from \"./a\";\nexport function g() { return f(); }\n" },
        .{ .path = "c.ts", .data = "export const c = 3;\n" },
    });
    defer fixture.deinit();
    const repo = try fixture.open(runtime, fact_store.default_max_file_bytes);
    defer repo.deinit();
    _ = try repo.refresh();
    const before = repo.snapshot();
    const update = try repo.updateSource("b.ts", "import { f } from \"./a\";\nexport function g() { return 2; }\n");
    try testing.expect(!update.reshaped);
    const after = repo.snapshot();
    try testing.expect(after.barrier > before.barrier);
    try testing.expect(!std.mem.eql(u8, &before.root, &after.root));
    const incremental = after.root;
    try repo.computeSnapshot();
    try testing.expectEqualSlices(u8, &repo.snapshot().root, &incremental);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 0), (try callerPaths(arena.allocator(), repo, "f")).len);
}
