const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");
const fact_store = emetgate.fact_store;
const fact_file = emetgate.fact_file;
const facts = emetgate.facts;
const facts_store = emetgate.facts_store;
const facts_query = emetgate.facts_query;
const facts_evidence = emetgate.facts_evidence;
const evidence = emetgate.evidence;
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
    const result = try @import("emetgate").bounded_run.run(testing.allocator, testing.io, .{ .argv = argv.items, .cwd = .{ .path = root } });
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

test "fact store: a clean refresh keeps the words of files with syntax errors and of unindexed files after the workers free their bytes" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var files: std.ArrayList(File) = .empty;
    for (0..8) |i| try files.append(arena, .{ .path = try std.fmt.allocPrint(arena, "src/broken{d}.ts", .{i}), .data = try std.fmt.allocPrint(arena, "export function f{d}( {{\n  return brokenWord{d} +;\n}}\n", .{ i, i }) });
    for (0..2) |i| try files.append(arena, .{ .path = try std.fmt.allocPrint(arena, "src/view{d}.vue", .{i}), .data = try std.fmt.allocPrint(arena, "<script>\nexport default {{ name: vueWord{d} }}\n</script>\n", .{i}) });
    var fixture = try Fixture.init(files.items);
    defer fixture.deinit();
    const repo = try fixture.open(runtime, fact_store.default_max_file_bytes);
    defer repo.deinit();
    const report = try repo.refresh();
    try testing.expectEqual(@as(usize, 10), report.extracted);
    for (files.items, 0..) |f, i| {
        const word = if (i < 8) try std.fmt.allocPrint(arena, "brokenWord{d}", .{i}) else try std.fmt.allocPrint(arena, "vueWord{d}", .{i - 8});
        const holders = repo.store.token_files.get(word) orelse {
            std.debug.print("no file keeps the word {s} of {s}\n", .{ word, f.path });
            return error.WordLost;
        };
        const id = repo.store.fileId(f.path).?;
        const kept = for (holders.items) |key| {
            if (key.file == id) break true;
        } else false;
        try testing.expect(kept);
    }
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
        .{ .path = "b.ts", .data = "import { f } from \"./a\";\nexport function g() { f(); return 1; }\n" },
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

test "fact store: an edit that changes what a function returns reshapes the file" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var fixture = try Fixture.init(&.{
        .{ .path = "a.ts", .data = "export function f() { return 1; }\n" },
        .{ .path = "b.ts", .data = "import { f } from \"./a\";\nexport function g() { return f(); }\n" },
    });
    defer fixture.deinit();
    const repo = try fixture.open(runtime, fact_store.default_max_file_bytes);
    defer repo.deinit();
    _ = try repo.refresh();
    const update = try repo.updateSource("b.ts", "import { f } from \"./a\";\nexport function g() { return 2; }\n");
    try testing.expect(update.reshaped);
}

test "fact store: evidence never shows a line of a file that changed after the snapshot as current" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var fixture = try Fixture.init(&.{
        .{ .path = "a.ts", .data = "export function f() { return 1; }\n" },
        .{ .path = "b.ts", .data = "import { f } from \"./a\";\nexport function g() { return f(); }\n" },
    });
    defer fixture.deinit();
    const repo = try fixture.open(runtime, fact_store.default_max_file_bytes);
    defer repo.deinit();
    _ = try repo.refresh();
    try fixture.write(.{ .path = "b.ts", .data = "import { f } from \"./a\";\nexport function g() { return 7 + f(); }\n" });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try repo.query(arena.allocator(), .{ .relation = .callers, .subject = "f" });
    var lines: fact_store.SourceLines = .{ .repo = repo, .arena = arena.allocator() };
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    _ = try facts_evidence.render(arena.allocator(), &out.writer, result, lines.source(), facts_evidence.default_budget);
    try testing.expect(std.mem.indexOf(u8, out.written(), "return 7") == null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "source unavailable") != null);
}

fn evidenceText(result: evidence.EvidenceAnswer) ![]const u8 {
    return switch (result) {
        .complete => |c| c.value.text,
        .partial => |p| p.value.text,
        .refused => error.Refused,
    };
}

test "fact store: the evidence view of a repository comes from one call and quotes the current lines" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var fixture = try Fixture.init(&.{
        .{ .path = "a.ts", .data = "export function f() {\n  return 1;\n}\n" },
    });
    defer fixture.deinit();
    const repo = try fixture.open(runtime, fact_store.default_max_file_bytes);
    defer repo.deinit();
    _ = try repo.refresh();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const view = try repo.factStore(arena.allocator());
    try testing.expectEqual(repo.snapshot().barrier, view.snapshot.barrier);
    const result = evidence.evidence(&view, .{ .targets = &.{.{ .path = "a.ts", .qname = "f" }}, .intent = .explain }, evidence.default_budget);
    try testing.expectEqual(answer.Status.complete, result.status());
    try testing.expect(std.mem.indexOf(u8, try evidenceText(result), "\na.ts\n1  export function f() {  [target f ") != null);
    try testing.expect(std.mem.indexOf(u8, try evidenceText(result), "\n2    return 1;\n") != null);
}

test "fact store: evidence refreshes a file changed after the snapshot and quotes its new lines" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var fixture = try Fixture.init(&.{
        .{ .path = "a.ts", .data = "export function f() { return 1; }\n" },
        .{ .path = "b.ts", .data = "import { f } from \"./a\";\nexport function g() { return f(); }\n" },
    });
    defer fixture.deinit();
    const repo = try fixture.open(runtime, fact_store.default_max_file_bytes);
    defer repo.deinit();
    _ = try repo.refresh();
    const before = repo.snapshot().barrier;
    try fixture.write(.{ .path = "b.ts", .data = "import { f } from \"./a\";\nexport function g() { return 7 + f(); }\n" });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try repo.evidence(arena.allocator(), .{ .targets = &.{.{ .path = "a.ts", .qname = "f" }}, .intent = .callers }, evidence.default_budget);
    try testing.expectEqual(answer.Status.complete, result.status());
    const text = try evidenceText(result);
    try testing.expect(std.mem.indexOf(u8, text, "\nb.ts\n2  export function g() { return 7 + f(); }  [caller of f: g ") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\n2  export function g() { return 7 + f(); }  [call proven]\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "return f();") == null);
    try testing.expect(repo.snapshot().barrier > before);
}

test "fact store: evidence of a target whose file was deleted on disk is partial and names the file vanished" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var fixture = try Fixture.init(&.{
        .{ .path = "a.ts", .data = "export function f() {\n  return 1;\n}\n" },
    });
    defer fixture.deinit();
    const repo = try fixture.open(runtime, fact_store.default_max_file_bytes);
    defer repo.deinit();
    _ = try repo.refresh();
    try fixture.tmp.dir.deleteFile(testing.io, "repo/a.ts");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try repo.evidence(arena.allocator(), .{ .targets = &.{.{ .path = "a.ts", .qname = "f" }}, .intent = .explain }, evidence.default_budget);
    try testing.expectEqual(answer.Status.partial, result.status());
    const text = try evidenceText(result);
    try testing.expect(std.mem.indexOf(u8, text, evidence.vanished_note) != null);
    try testing.expect(std.mem.indexOf(u8, text, "\nPartial because: 1 files no longer exist.\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "missing 1 vanished") != null);
}

test "fact store: evidence of a target whose file grew over the size limit names the declared exclusion and its limit" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var fixture = try Fixture.init(&.{
        .{ .path = "a.ts", .data = "export function f() {\n  return 1;\n}\n" },
    });
    defer fixture.deinit();
    const repo = try fixture.open(runtime, 200);
    defer repo.deinit();
    _ = try repo.refresh();
    try fixture.write(.{ .path = "a.ts", .data = "export function f() {\n  return 1;\n}\n" ++ ("// padding to pass the limit\n" ** 10) });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try repo.evidence(arena.allocator(), .{ .targets = &.{.{ .path = "a.ts", .qname = "f" }}, .intent = .explain }, evidence.default_budget);
    try testing.expectEqual(answer.Status.complete, result.status());
    const text = try evidenceText(result);
    try testing.expect(std.mem.indexOf(u8, text, evidence.large_note) != null);
    try testing.expect(std.mem.indexOf(u8, text, "\nExcluded by rule: 1 files over the 200-byte size limit are not read.\n") != null);
    try testing.expect(std.mem.endsWith(u8, text, "; skipped 1 too_large"));
}

const kernel32 = struct {
    const FileTime = extern struct { low: u32, high: u32 };
    extern "kernel32" fn SetFileTime(file: std.os.windows.HANDLE, creation: ?*const FileTime, access: ?*const FileTime, write: ?*const FileTime) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: std.os.windows.DWORD, share: std.os.windows.DWORD, security: ?*anyopaque, disposition: std.os.windows.DWORD, flags: std.os.windows.DWORD, template: ?std.os.windows.HANDLE) callconv(.winapi) std.os.windows.HANDLE;
};

fn writtenLongAgo(path: []const u8) !void {
    const wide = try std.unicode.wtf8ToWtf16LeAllocZ(testing.allocator, path);
    defer testing.allocator.free(wide);
    const handle = kernel32.CreateFileW(wide, 0x100, 0x7, null, 3, 0x80, null);
    if (handle == std.os.windows.INVALID_HANDLE_VALUE) return error.TouchFailed;
    defer std.os.windows.CloseHandle(handle);
    const old: kernel32.FileTime = .{ .low = 0, .high = 30_000_000 };
    if (kernel32.SetFileTime(handle, null, null, &old) == .FALSE) return error.TouchFailed;
}

fn holdWithoutSharing(path: []const u8) !std.os.windows.HANDLE {
    const wide = try std.unicode.wtf8ToWtf16LeAllocZ(testing.allocator, path);
    defer testing.allocator.free(wide);
    const handle = kernel32.CreateFileW(wide, 0x80000000, 0, null, 3, 0x80, null);
    if (handle == std.os.windows.INVALID_HANDLE_VALUE) return error.HoldFailed;
    return handle;
}

test "fact store: evidence of a target whose file another handle holds is partial at once and names the file unreadable" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var fixture = try Fixture.init(&.{
        .{ .path = "a.ts", .data = "export function f() {\n  return 1;\n}\n" },
    });
    defer fixture.deinit();
    const repo = try fixture.open(runtime, fact_store.default_max_file_bytes);
    defer repo.deinit();
    _ = try repo.refresh();
    const abs = try std.fmt.allocPrint(testing.allocator, "{s}\\a.ts", .{fixture.root});
    defer testing.allocator.free(abs);
    const holder = try holdWithoutSharing(abs);
    defer std.os.windows.CloseHandle(holder);
    var fastest: i96 = std.math.maxInt(i96);
    for (0..5) |_| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const started = std.Io.Clock.awake.now(testing.io).nanoseconds;
        const result = try repo.evidence(arena.allocator(), .{ .targets = &.{.{ .path = "a.ts", .qname = "f" }}, .intent = .explain }, evidence.default_budget);
        fastest = @min(fastest, std.Io.Clock.awake.now(testing.io).nanoseconds - started);
        try testing.expectEqual(answer.Status.partial, result.status());
        const text = try evidenceText(result);
        try testing.expect(std.mem.indexOf(u8, text, evidence.unreadable_note) != null);
        try testing.expect(std.mem.indexOf(u8, text, "\nPartial because: 1 files could not be read (locked or access denied).\n") != null);
        try testing.expect(std.mem.indexOf(u8, text, "missing 1 unreadable") != null);
    }
    try testing.expect(fastest < 50 * std.time.ns_per_ms);
}

fn sameOutline(a: []const facts.Outline, b: []const facts.Outline) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.start != y.start or x.end != y.end or x.parent != y.parent) return false;
        if (@as(u8, @bitCast(x.kind)) != @as(u8, @bitCast(y.kind))) return false;
    }
    return true;
}

fn sameTests(a: []const facts.TestBlock, b: []const facts.TestBlock) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.start != y.start or x.end != y.end or x.line != y.line or x.parent != y.parent) return false;
        if (!std.mem.eql(u8, x.title, y.title)) return false;
    }
    return true;
}

test "fact store: a saved store opens again with every outline node, test block and body start it was saved with" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var fixture = try Fixture.init(&.{
        .{ .path = "a.ts", .data = "export function f(x: number) {\n  if (x > 1) {\n    // the larger one\n    return 2;\n  }\n  return x;\n}\n" },
        .{ .path = "a.test.ts", .data = "import { f } from \"./a\";\ndescribe(\"f\", () => {\n  it(\"returns two\", () => {\n    expect(f(2)).toBe(2);\n  });\n});\n" },
    });
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const keep = arena.allocator();
    var outline: []const facts.Outline = &.{};
    var blocks: []facts.TestBlock = &.{};
    var bodies: []u32 = &.{};
    var signatures: [][]const u8 = &.{};
    var docs: [][]const u8 = &.{};
    {
        const repo = try fixture.open(runtime, fact_store.default_max_file_bytes);
        defer repo.deinit();
        _ = try repo.refresh();
        const source = repo.store.file(repo.store.fileId("a.ts").?).facts;
        outline = try keep.dupe(facts.Outline, source.outline);
        bodies = try keep.alloc(u32, source.defs.len);
        for (source.defs, bodies) |d, *slot| slot.* = d.body_start;
        signatures = try keep.alloc([]const u8, source.defs.len);
        docs = try keep.alloc([]const u8, source.defs.len);
        for (source.defs, signatures, docs) |d, *signature, *doc| {
            signature.* = try keep.dupe(u8, d.signature);
            doc.* = try keep.dupe(u8, d.doc);
        }
        const suite = repo.store.file(repo.store.fileId("a.test.ts").?).facts;
        blocks = try keep.dupe(facts.TestBlock, suite.tests);
        for (blocks) |*b| b.title = try keep.dupe(u8, b.title);
    }
    try testing.expect(outline.len >= 3);
    try testing.expectEqual(@as(usize, 2), blocks.len);
    const repo = try fixture.open(runtime, fact_store.default_max_file_bytes);
    defer repo.deinit();
    try testing.expectEqual(fact_store.Load.loaded, repo.load);
    const report = try repo.refresh();
    try testing.expectEqual(@as(usize, 0), report.extracted);
    const source = repo.store.file(repo.store.fileId("a.ts").?).facts;
    try testing.expect(sameOutline(outline, source.outline));
    try testing.expectEqual(bodies.len, source.defs.len);
    for (bodies, source.defs) |body, d| try testing.expectEqual(body, d.body_start);
    for (signatures, docs, source.defs) |signature, doc, d| {
        try testing.expectEqualStrings(signature, d.signature);
        try testing.expectEqualStrings(doc, d.doc);
    }
    try testing.expectEqualStrings("export function f(x: number)", signatures[1]);
    try testing.expect(bodies[1] != facts.none);
    try testing.expect(sameTests(blocks, repo.store.file(repo.store.fileId("a.test.ts").?).facts.tests));
}

test "fact store: a refresh reads past a file another handle holds at once, names it unreadable and reads it again once it is free" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var fixture = try Fixture.init(&.{
        .{ .path = "a.ts", .data = "export function f() {\n  return 1;\n}\n" },
        .{ .path = "b.ts", .data = "import { f } from \"./a\";\nexport function g() { return f(); }\n" },
    });
    defer fixture.deinit();
    const repo = try fixture.open(runtime, fact_store.default_max_file_bytes);
    defer repo.deinit();
    const abs = try std.fmt.allocPrint(testing.allocator, "{s}\\a.ts", .{fixture.root});
    defer testing.allocator.free(abs);
    try writtenLongAgo(abs);
    const holder = try holdWithoutSharing(abs);
    var released = false;
    defer if (!released) std.os.windows.CloseHandle(holder);
    var fastest: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const held = try repo.refresh();
        fastest = @min(fastest, held.extract_ms);
        try testing.expectEqual(emetgate.facts_store.Status.unreadable, repo.store.file(repo.store.fileId("a.ts").?).status);
    }
    std.os.windows.CloseHandle(holder);
    released = true;
    try testing.expect(fastest < 50);
    const id = repo.store.fileId("a.ts").?;
    const free = try repo.refresh();
    try testing.expectEqual(@as(usize, 1), free.extracted);
    try testing.expectEqual(emetgate.facts_store.Status.indexed, repo.store.file(id).status);
}

test "fact store: a saved store keeps the submodule a Python from-import may name" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var fixture = try Fixture.init(&.{
        .{ .path = "p/__init__.py", .data = "" },
        .{ .path = "p/m.py", .data = "def helper():\n    return 1\n" },
        .{ .path = "n.py", .data = "import os\nfrom p import m\n" },
    });
    defer fixture.deinit();
    {
        const repo = try fixture.open(runtime, fact_store.default_max_file_bytes);
        defer repo.deinit();
        const report = try repo.refresh();
        try testing.expect(report.saved);
    }
    const repo = try fixture.open(runtime, fact_store.default_max_file_bytes);
    defer repo.deinit();
    try testing.expectEqual(fact_store.Load.loaded, repo.load);
    const id = repo.store.fileId("n.py") orelse return error.TestUnexpectedResult;
    const loaded = repo.store.file(id).facts;
    try testing.expectEqual(@as(usize, 2), loaded.bindings.len);
    try testing.expectEqual(facts.none, loaded.bindings[0].submodule);
    const sub = loaded.bindings[1].submodule;
    try testing.expect(sub != facts.none);
    try testing.expectEqualStrings("p.m", loaded.specs[sub].text);
}

fn targetOf(repo: *fact_store.Repo, path: []const u8, spec_text: []const u8) !facts_store.SpecTarget {
    for (repo.store.files.items) |state| {
        if (!std.mem.eql(u8, state.path, path)) continue;
        for (state.facts.specs, state.spec_targets) |spec, target| {
            if (std.mem.eql(u8, spec.text, spec_text)) return target;
        }
    }
    return error.TestExpectedEqual;
}

fn linkedQname(repo: *fact_store.Repo, path: []const u8, kind: facts.RefKind, name: []const u8) ![]const u8 {
    const id = repo.store.fileId(path) orelse return error.FileNotFound;
    const state = repo.store.file(id);
    for (state.facts.refs, state.links) |r, l| {
        if (r.kind != kind or !std.mem.eql(u8, r.name, name)) continue;
        return switch (l) {
            .def => |d| (repo.store.defOf(d.id) orelse return error.DefNotFound).qname,
            .unresolved => "",
        };
    }
    return error.RefNotFound;
}

fn expectCalls(data: []const File, kind: facts.RefKind, name: []const u8, qname: []const u8) !void {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var fixture = try Fixture.init(data);
    defer fixture.deinit();
    const repo = try fixture.open(runtime, fact_store.default_max_file_bytes);
    defer repo.deinit();
    _ = try repo.refresh();
    try testing.expectEqualStrings(qname, try linkedQname(repo, "Use.cs", kind, name));
}

const pricing_cs = File{ .path = "Pricing.cs", .data = "namespace Shop.Services\n{\n    public static class Pricing\n    {\n        public static int Apply() { return 1; }\n        public const int Max = 1;\n    }\n\n    public class G<T>\n    {\n        public int Size() { return 1; }\n    }\n}\n" };

test "fact store: csharp usings resolve to a namespace, a type's file or outside the repo" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var fixture = try Fixture.init(&.{
        .{ .path = "src/Cart.cs", .data = "namespace Shop.Models;\n\npublic static class Cart\n{\n    public static int Make() { return 1; }\n}\n" },
        .{ .path = "src/Use.cs", .data = "using System;\nusing Shop.Models;\nusing static Shop.Models.Cart;\nusing C = Shop.Models.Cart;\n\nnamespace Shop;\n\npublic class Use\n{\n    public int Go() { return Make(); }\n}\n" },
        .{ .path = "src/Scoped.cs", .data = "namespace Shop\n{\n    using Models;\n\n    public class Scoped\n    {\n    }\n}\n" },
    });
    defer fixture.deinit();
    const repo = try fixture.open(runtime, fact_store.default_max_file_bytes);
    defer repo.deinit();
    _ = try repo.refresh();
    try testing.expect(try targetOf(repo, "src/Use.cs", "System") == .external);
    try testing.expect(try targetOf(repo, "src/Use.cs", "Shop.Models") == .namespace);
    const static_target = try targetOf(repo, "src/Use.cs", "Shop.Models.Cart");
    try testing.expect(static_target == .file);
    try testing.expectEqualStrings("src/Cart.cs", repo.store.file(static_target.file).path);
    try testing.expect(try targetOf(repo, "src/Scoped.cs", "Models") == .namespace);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const declaring = try repo.store.declaring(arena.allocator(), "Shop.Models", .namespace);
    try testing.expectEqual(@as(usize, 1), declaring.len);
    try testing.expectEqualStrings("src/Cart.cs", repo.store.file(declaring[0]).path);
}

test "fact store: a csharp using follows a namespace that appears or disappears on refresh" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var fixture = try Fixture.init(&.{
        .{ .path = "src/Cart.cs", .data = "namespace Shop.Models;\n\npublic class Cart\n{\n}\n" },
        .{ .path = "src/Use.cs", .data = "using Shop.Models;\n\npublic class Use\n{\n}\n" },
    });
    defer fixture.deinit();
    const repo = try fixture.open(runtime, fact_store.default_max_file_bytes);
    defer repo.deinit();
    _ = try repo.refresh();
    try testing.expect(try targetOf(repo, "src/Use.cs", "Shop.Models") == .namespace);
    _ = try repo.updateSource("src/Cart.cs", "namespace Shop.Other;\n\npublic class Cart\n{\n}\n");
    try testing.expect(try targetOf(repo, "src/Use.cs", "Shop.Models") == .external);
}

test "fact store: csharp usings survive a store round trip" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var fixture = try Fixture.init(&.{
        .{ .path = "src/Cart.cs", .data = "namespace Shop.Models;\n\npublic class Cart\n{\n}\n" },
        .{ .path = "src/Use.cs", .data = "using Shop.Models;\n\npublic class Use\n{\n}\n" },
    });
    defer fixture.deinit();
    {
        const repo = try fixture.open(runtime, fact_store.default_max_file_bytes);
        defer repo.deinit();
        _ = try repo.refresh();
    }
    const again = try fixture.open(runtime, fact_store.default_max_file_bytes);
    defer again.deinit();
    _ = try again.refresh();
    try testing.expect(try targetOf(again, "src/Use.cs", "Shop.Models") == .namespace);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 1), (try again.store.declaring(arena.allocator(), "Shop.Models", .namespace)).len);
}

test "fact store: a python name inside a module resolves to the module, not to a repo-external package" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var fixture = try Fixture.init(&.{
        .{ .path = "pkg/__init__.py", .data = "" },
        .{ .path = "pkg/cart.py", .data = "class Cart:\n    pass\n" },
        .{ .path = "pkg/app.py", .data = "from pkg.cart import Cart\nimport os\n\ndef run():\n    return Cart(), os.getcwd()\n" },
    });
    defer fixture.deinit();
    const repo = try fixture.open(runtime, fact_store.default_max_file_bytes);
    defer repo.deinit();
    _ = try repo.refresh();
    const cart = try targetOf(repo, "pkg/app.py", "pkg.cart");
    try testing.expect(cart == .file);
    try testing.expectEqualStrings("pkg/cart.py", repo.store.file(cart.file).path);
    try testing.expect(try targetOf(repo, "pkg/app.py", "os") == .external);
}

test "fact store: a csharp using static links a bare call to the imported type's static method" {
    try expectCalls(&.{ pricing_cs, .{ .path = "Use.cs", .data = "using static Shop.Services.Pricing;\n\nnamespace App\n{\n    public class Use\n    {\n        public int Go() { return Apply(); }\n    }\n}\n" } }, .call, "Apply", "Shop.Services.Pricing.Apply@static");
    try expectCalls(&.{ pricing_cs, .{ .path = "Use.cs", .data = "global using static Shop.Services.Pricing;\n\nnamespace App\n{\n    public class Use\n    {\n        public int Go() { return Apply(); }\n    }\n}\n" } }, .call, "Apply", "Shop.Services.Pricing.Apply@static");
    try expectCalls(&.{ pricing_cs, .{ .path = "Global.cs", .data = "global using static Shop.Services.Pricing;\n" }, .{ .path = "Use.cs", .data = "namespace App\n{\n    public class Use\n    {\n        public int Go() { return Apply(); }\n    }\n}\n" } }, .call, "Apply", "Shop.Services.Pricing.Apply@static");
    try expectCalls(&.{ pricing_cs, .{ .path = "Use.cs", .data = "namespace Shop\n{\n    using static Services.Pricing;\n\n    public class Use\n    {\n        public int Go() { return Apply(); }\n    }\n}\n" } }, .call, "Apply", "Shop.Services.Pricing.Apply@static");
}

test "fact store: a csharp using static stays unproven when another import, block or base could supply the name" {
    try expectCalls(&.{ pricing_cs, .{ .path = "Use.cs", .data = "using static Shop.Services.Pricing;\nusing static System.Math;\n\nnamespace App\n{\n    public class Use\n    {\n        public int Go() { return Apply(); }\n    }\n}\n" } }, .call, "Apply", "");
    try expectCalls(&.{ pricing_cs, .{ .path = "Use.cs", .data = "namespace App\n{\n    using static Shop.Services.Pricing;\n}\n\nnamespace App\n{\n    public class Use\n    {\n        public int Go() { return Apply(); }\n    }\n}\n" } }, .call, "Apply", "");
    try expectCalls(&.{ pricing_cs, .{ .path = "Use.cs", .data = "using static Shop.Services.Pricing;\n\nnamespace App\n{\n    public class Use : Outside\n    {\n        public int Go() { return Apply(); }\n    }\n}\n" } }, .call, "Apply", "");
    try expectCalls(&.{ pricing_cs, .{ .path = "Use.cs", .data = "namespace App\n{\n    public class Use\n    {\n        public int Go() { return Apply(); }\n    }\n}\n" } }, .call, "Apply", "");
    try expectCalls(&.{ pricing_cs, .{ .path = "Other.cs", .data = "namespace Shop\n{\n    public static class Other { public static int Apply() { return 2; } }\n}\n" }, .{ .path = "Use.cs", .data = "using static Shop.Services.Pricing;\nusing static Shop.Other;\n\nnamespace App\n{\n    public class Use\n    {\n        public int Go() { return Apply(); }\n    }\n}\n" } }, .call, "Apply", "");
}

test "fact store: a csharp bare call finds its own class before a using static" {
    try expectCalls(&.{ pricing_cs, .{ .path = "Use.cs", .data = "using static Shop.Services.Pricing;\n\nnamespace App\n{\n    public class Parent\n    {\n        public int Apply() { return 2; }\n    }\n\n    public class Use : Parent\n    {\n        public int Go() { return Apply(); }\n    }\n}\n" } }, .call, "Apply", "App.Parent.Apply");
}

test "fact store: a csharp namespace-qualified static call links through its full path" {
    const qualified = File{ .path = "Use.cs", .data = "namespace App\n{\n    public class Use\n    {\n        public int Go() { return Shop.Services.Pricing.Apply() + Shop.Services.Pricing.Max; }\n    }\n}\n" };
    try expectCalls(&.{ pricing_cs, qualified }, .call, "Apply", "Shop.Services.Pricing.Apply@static");
    try expectCalls(&.{ pricing_cs, qualified }, .read, "Max", "Shop.Services.Pricing.Max");
    try expectCalls(&.{ pricing_cs, .{ .path = "Use.cs", .data = "namespace App\n{\n    public class Use\n    {\n        public int Go() { return Shop.Services.Pricing.Max; }\n    }\n}\n" } }, .read, "Pricing", "Shop.Services.Pricing");
    try expectCalls(&.{ pricing_cs, .{ .path = "Use.cs", .data = "namespace Shop\n{\n    public class Use\n    {\n        public int Go() { return Services.Pricing.Apply(); }\n    }\n}\n" } }, .call, "Apply", "Shop.Services.Pricing.Apply@static");
    try expectCalls(&.{ pricing_cs, .{ .path = "Use.cs", .data = "namespace App\n{\n    public class Use\n    {\n        public int Go() { return Other.Pricing.Apply(); }\n    }\n}\n" } }, .call, "Apply", "");
    try expectCalls(&.{ pricing_cs, .{ .path = "Use.cs", .data = "namespace App\n{\n    public class Use\n    {\n        public int Go(Thing Shop) { return Shop.Services.Pricing.Apply(); }\n    }\n}\n" } }, .call, "Apply", "");
    try expectCalls(&.{ pricing_cs, .{ .path = "Use.cs", .data = "namespace App\n{\n    using Shop = Elsewhere.Things;\n\n    public class Use\n    {\n        public int Go() { return Shop.Services.Pricing.Apply(); }\n    }\n}\n" } }, .call, "Apply", "");
}

test "fact store: a csharp generic new links to the generic class, bare or qualified" {
    try expectCalls(&.{ pricing_cs, .{ .path = "Use.cs", .data = "using Shop.Services;\n\nnamespace App\n{\n    public class Use\n    {\n        public int Go() { return new G<int>().Size(); }\n    }\n}\n" } }, .new, "G", "Shop.Services.G");
    try expectCalls(&.{ pricing_cs, .{ .path = "Use.cs", .data = "namespace App\n{\n    public class Use\n    {\n        public object Go() { return new Shop.Services.G<int>(); }\n    }\n}\n" } }, .new, "G", "Shop.Services.G");
    try expectCalls(&.{ pricing_cs, .{ .path = "Use.cs", .data = "using Shop.Services;\n\nnamespace App\n{\n    public class Use\n    {\n        public int Go() { return new G<int>().Size(); }\n    }\n}\n" } }, .call, "Size", "Shop.Services.G.Size");
    try expectCalls(&.{ pricing_cs, .{ .path = "Use.cs", .data = "namespace App\n{\n    public class Use\n    {\n        public object Go() { return new G<int>(); }\n    }\n}\n" } }, .new, "G", "");
}

test "fact store: a csharp name finds the nearest namespace first and a block's own using applies only inside it" {
    const near = File{ .path = "Use.cs", .data = "namespace Shop\n{\n    public class Cart { }\n}\n\nnamespace Shop.Sub\n{\n    public class Cart { }\n    public class Use\n    {\n        public object Go() { return new Cart(); }\n    }\n}\n" };
    try expectCalls(&.{near}, .new, "Cart", "Shop.Sub.Cart");
    const shadowed = File{ .path = "Use.cs", .data = "using Shop.Services;\n\nnamespace App\n{\n    public class Pricing { public static int Apply() { return 2; } }\n    public class Use\n    {\n        public int Go() { return Pricing.Apply(); }\n    }\n}\n" };
    try expectCalls(&.{ pricing_cs, shadowed }, .call, "Apply", "App.Pricing.Apply@static");
    try expectCalls(&.{ .{ .path = "Far.cs", .data = "namespace Far\n{\n    public class Cart { }\n}\n" }, .{ .path = "Use.cs", .data = "using Far;\n\nnamespace Near\n{\n    public class Cart { }\n}\n\nnamespace Near.Inner\n{\npublic class Use\n{\n    public object Go() { return new Cart(); }\n}\n}\n" } }, .new, "Cart", "Near.Cart");
    try expectCalls(&.{ .{ .path = "Cart.cs", .data = "namespace Outer\n{\n    public class Cart { }\n}\n" }, .{ .path = "Use.cs", .data = "namespace Outer\n{\n    namespace Inner\n    {\n        using Far.Away;\n\npublic class Use\n{\n    public object Go() { return new Cart(); }\n}\n    }\n}\n" } }, .new, "Cart", "");
    try expectCalls(&.{ .{ .path = "A.cs", .data = "namespace A\n{\n    public class Cart { }\n}\n" }, .{ .path = "B.cs", .data = "namespace B\n{\n    public class Cart { }\n}\n" }, .{ .path = "Use.cs", .data = "using A;\nusing B;\n\nnamespace App\n{\npublic class Use\n{\n    public object Go() { return new Cart(); }\n}\n}\n" } }, .new, "Cart", "");
}

test "fact store: a csharp class with a constructor and a nested type links its own names" {
    const own = File{ .path = "Use.cs", .data = "namespace Shop\n{\n    public class Use\n    {\n        public Use() { }\n        public Use Clone() { return new Use(); }\n        public object Make() { return new Inner(); }\n        public int Read(Use other) { return Inner.Count(); }\n        public class Inner { public static int Count() { return 1; } }\n    }\n}\n" };
    try expectCalls(&.{own}, .new, "Use", "Shop.Use");
    try expectCalls(&.{own}, .read, "Use", "Shop.Use");
    try expectCalls(&.{own}, .new, "Inner", "Shop.Use.Inner");
    try expectCalls(&.{own}, .call, "Count", "Shop.Use.Inner.Count@static");
}

test "fact store: a csharp call's return type is unproven when a base class may hold another overload" {
    try expectCalls(&.{.{ .path = "Use.cs", .data = "namespace App\n{\n    public class Cart { public int Total() { return 1; } }\n    public class Other { public int Total() { return 2; } }\n    public class A { public Cart Make(int n) { return new Cart(); } }\n    public class B : A { public Other Make() { return new Other(); } }\n    public class Use\n    {\n        public int Go() { var c = new B().Make(1); return c.Total(); }\n    }\n}\n" }}, .call, "Total", "");
    try expectCalls(&.{.{ .path = "Use.cs", .data = "namespace App\n{\n    public class Cart { public int Total() { return 1; } }\n    public class B : Outside { public Cart Make() { return new Cart(); } }\n    public class Use\n    {\n        public int Go() { var c = new B().Make(); return c.Total(); }\n    }\n}\n" }}, .call, "Total", "");
    try expectCalls(&.{.{ .path = "Use.cs", .data = "namespace App\n{\n    public class Cart { public int Total() { return 1; } }\n    public interface IMake { Cart Make(); }\n    public class A { public int Size() { return 1; } }\n    public class B : A { public Cart Make() { return new Cart(); } }\n    public class C : IMake { public Cart Make() { return new Cart(); } }\n    public class Use\n    {\n        public int Go() { var c = new B().Make(); return c.Total(); }\n        public int Run() { var c = new C().Make(); return c.Total(); }\n    }\n}\n" }}, .call, "Total", "App.Cart.Total");
}

test "fact store: a csharp call's return type follows a change in the file that declares it" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var fixture = try Fixture.init(&.{
        .{ .path = "Maker.cs", .data = "namespace Shop\n{\n    public class Cart { public int Total() { return 1; } }\n    public class Bag { public int Total() { return 2; } }\n    public static class Maker { public static Cart Make() { return null; } }\n}\n" },
        .{ .path = "Use.cs", .data = "namespace Shop\n{\n    public class Use\n    {\n        public int Go() { var c = Maker.Make(); return c.Total(); }\n    }\n}\n" },
    });
    defer fixture.deinit();
    const repo = try fixture.open(runtime, fact_store.default_max_file_bytes);
    defer repo.deinit();
    _ = try repo.refresh();
    try testing.expectEqualStrings("Shop.Cart.Total", try linkedQname(repo, "Use.cs", .call, "Total"));
    _ = try repo.updateSource("Maker.cs", "namespace Shop\n{\n    public class Cart { public int Total() { return 1; } }\n    public class Bag { public int Total() { return 2; } }\n    public static class Maker { public static Bag Make() { return null; } }\n}\n");
    try testing.expectEqualStrings("Shop.Bag.Total", try linkedQname(repo, "Use.cs", .call, "Total"));
}

test "fact store: a new csharp type reaches files with no using" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var fixture = try Fixture.init(&.{
        .{ .path = "Use.cs", .data = "using static Shop.Services.Pricing;\nusing Alias = Shop.Services.G<int>;\n\nnamespace Shop.Services\n{\n    public class Use\n    {\n        public int Go() { var c = Make(); return c.Total() + Apply(); }\n        public object Fresh() { return new Cart(); }\n        public object Other() { return new Alias(); }\n    }\n}\n" },
        .{ .path = "Cart.cs", .data = "namespace Shop.Services\n{\n    public class Placeholder { }\n}\n" },
        .{ .path = "Plain.cs", .data = "namespace Shop.Services\n{\n    public class Plain\n    {\n        public object Fresh() { return new Cart(); }\n    }\n}\n" },
    });
    defer fixture.deinit();
    const repo = try fixture.open(runtime, fact_store.default_max_file_bytes);
    defer repo.deinit();
    _ = try repo.refresh();
    try testing.expectEqualStrings("", try linkedQname(repo, "Plain.cs", .new, "Cart"));
    _ = try repo.updateSource("Cart.cs", "namespace Shop.Services\n{\n    public class Cart { public int Total() { return 1; } }\n    public static class Pricing\n    {\n        public static Cart Make() { return new Cart(); }\n        public static int Apply() { return 1; }\n    }\n}\n");
    try testing.expectEqualStrings("Shop.Services.Cart", try linkedQname(repo, "Plain.cs", .new, "Cart"));
    try testing.expectEqualStrings("Shop.Services.Cart.Total", try linkedQname(repo, "Use.cs", .call, "Total"));
}

test "fact store: a csharp call through a type name is proven and one through a local is typed" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var fixture = try Fixture.init(&.{
        .{ .path = "Use.cs", .data = "using Shop.Services;\n\nnamespace App\n{\n    public class Use\n    {\n        public int Go() { var c = new Cart(); return c.Total() + Pricing.Apply(); }\n    }\n}\n" },
        .{ .path = "Cart.cs", .data = "namespace Shop.Services\n{\n    public class Cart { public int Total() { return 1; } }\n    public static class Pricing { public static int Apply() { return 1; } }\n}\n" },
    });
    defer fixture.deinit();
    const repo = try fixture.open(runtime, fact_store.default_max_file_bytes);
    defer repo.deinit();
    _ = try repo.refresh();
    const state = repo.store.file(repo.store.fileId("Use.cs").?);
    for (state.facts.refs, state.links) |r, l| {
        const expected: facts.Certainty = if (std.mem.eql(u8, r.name, "Apply")) .proven else if (std.mem.eql(u8, r.name, "Total")) .typed else continue;
        try testing.expectEqual(expected, l.def.certainty);
    }
}

test "fact store: a csharp type declared twice in one file is unproven and the nearest namespace wins inside a file" {
    try expectCalls(&.{.{ .path = "Use.cs", .data = "namespace Shop\n{\n    public class G { }\n    public class G<T> { }\n    public class Use\n    {\n        public object Make() { return new G<int>(); }\n    }\n}\n" }}, .new, "G", "");
    try expectCalls(&.{.{ .path = "Use.cs", .data = "namespace Far\n{\n    public class Cart { }\n}\n\nnamespace Shop\n{\n    public class Cart { }\n    public class Use\n    {\n        public object Make() { return new Cart(); }\n    }\n}\n" }}, .new, "Cart", "Shop.Cart");
}

test "fact store: a csharp type parameter makes no reference to a class of the same name" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var fixture = try Fixture.init(&.{.{ .path = "Use.cs", .data = "public class T { }\n\npublic class Use<T>\n{\n    public T Get() { return default(T); }\n    public int Read(int x) { return x; }\n    public object Make() { return new Cart(); }\n}\n\npublic class Cart { }\n" }});
    defer fixture.deinit();
    const repo = try fixture.open(runtime, fact_store.default_max_file_bytes);
    defer repo.deinit();
    _ = try repo.refresh();
    try testing.expectEqualStrings("Cart", try linkedQname(repo, "Use.cs", .new, "Cart"));
    try testing.expectError(error.RefNotFound, linkedQname(repo, "Use.cs", .type, "T"));
}

test "fact store: a csharp interface base leaves a call's return type proven" {
    try expectCalls(&.{.{ .path = "Use.cs", .data = "namespace App\n{\n    public class Cart { public int Total() { return 1; } }\n    public interface IMake { Cart Make(int n); }\n    public class C : IMake\n    {\n        public Cart Make(int n) { return new Cart(); }\n    }\n    public class Use\n    {\n        public int Go() { var c = new C().Make(1); return c.Total(); }\n    }\n}\n" }}, .call, "Total", "App.Cart.Total");
}

test "fact store: a csharp path through a type never continues into a namespace of the same name" {
    try expectCalls(&.{
        .{ .path = "Cart.cs", .data = "namespace Shop\n{\n    public class Cart { }\n}\n" },
        .{ .path = "X.cs", .data = "namespace Shop.Cart.Missing\n{\n    public static class X { public static int Run() { return 1; } }\n}\n" },
        .{ .path = "Use.cs", .data = "namespace App\n{\n    public class Use\n    {\n        public int Go() { return Shop.Cart.Missing.X.Run(); }\n    }\n}\n" },
    }, .call, "Run", "");
}

test "fact store: a csharp return type moved between two methods reaches the caller" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var fixture = try Fixture.init(&.{
        .{ .path = "Maker.cs", .data = "namespace Shop\n{\n    public class Cart { public int Total() { return 1; } }\n    public static class Maker\n    {\n        public static Cart A() { return null; }\n        public static int B() { return 1; }\n    }\n}\n" },
        .{ .path = "Use.cs", .data = "namespace Shop\n{\n    public class Use\n    {\n        public int Go() { var c = Maker.B(); return c.Total(); }\n    }\n}\n" },
    });
    defer fixture.deinit();
    const repo = try fixture.open(runtime, fact_store.default_max_file_bytes);
    defer repo.deinit();
    _ = try repo.refresh();
    try testing.expectEqualStrings("", try linkedQname(repo, "Use.cs", .call, "Total"));
    _ = try repo.updateSource("Maker.cs", "namespace Shop\n{\n    public class Cart { public int Total() { return 1; } }\n    public static class Maker\n    {\n        public static int A() { return 1; }\n        public static Cart B() { return null; }\n    }\n}\n");
    try testing.expectEqualStrings("Shop.Cart.Total", try linkedQname(repo, "Use.cs", .call, "Total"));
}

test "fact store: a csharp call in a partial class whose other part may overload it gives no type" {
    try expectCalls(&.{ .{ .path = "Use.cs", .data = "public class Cart\n{\n    public int Total() { return 1; }\n}\n\npublic class Box\n{\n    public int Total() { return 2; }\n}\n\npublic partial class Maker\n{\n    public Cart Make() { return new Cart(); }\n    public int Go() { var c = Make(); return c.Total(); }\n}\n" }, .{ .path = "P2.cs", .data = "public partial class Maker\n{\n    public Box Make(int x) { return new Box(); }\n}\n" } }, .call, "Total", "");
}

test "fact store: a saved csharp store opens again with every new link field" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var fixture = try Fixture.init(&.{
        .{ .path = "Use.cs", .data = "using static Shop.Services.Pricing;\nusing Alias = Shop.Services.G<int>;\n\nnamespace Shop.Services\n{\n    public class Use\n    {\n        public int Go() { var c = Make(); return c.Total() + Apply(); }\n        public object Fresh() { return new Cart(); }\n        public object Other() { return new Alias(); }\n    }\n}\n" },
        .{ .path = "Cart.cs", .data = "namespace Shop.Services\n{\n    public class Cart { public int Total() { return 1; } }\n    public static class Pricing\n    {\n        public static Cart Make() { return new Cart(); }\n        public static int Apply() { return 1; }\n    }\n}\n" },
    });
    defer fixture.deinit();
    {
        const repo = try fixture.open(runtime, fact_store.default_max_file_bytes);
        defer repo.deinit();
        try testing.expect((try repo.refresh()).saved);
    }
    const again = try fixture.open(runtime, fact_store.default_max_file_bytes);
    defer again.deinit();
    try testing.expectEqual(fact_store.Load.loaded, again.load);
    try testing.expectEqual(@as(usize, 0), (try again.refresh()).extracted);
    try testing.expectEqualStrings("Shop.Services.Cart", try linkedQname(again, "Use.cs", .new, "Cart"));
    try testing.expectEqualStrings("Shop.Services.Cart.Total", try linkedQname(again, "Use.cs", .call, "Total"));
    try testing.expectEqualStrings("Shop.Services.Pricing.Apply@static", try linkedQname(again, "Use.cs", .call, "Apply"));
    try testing.expectEqualStrings("", try linkedQname(again, "Use.cs", .new, "Alias"));
}

test "fact store: a csharp test class links its evidence through a qualified call" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var fixture = try Fixture.init(&.{
        .{ .path = "src/Pricing.cs", .data = "namespace Shop.Services\n{\n    public static class Pricing\n    {\n        public static int Apply() { return 1; }\n    }\n}\n" },
        .{ .path = "tests/PricingTests.cs", .data = "using Xunit;\n\nnamespace Shop.Tests\n{\n    public class PricingTests\n    {\n        [Fact]\n        public void Applies() { Assert.Equal(1, Shop.Services.Pricing.Apply()); }\n    }\n}\n" },
    });
    defer fixture.deinit();
    const repo = try fixture.open(runtime, fact_store.default_max_file_bytes);
    defer repo.deinit();
    _ = try repo.refresh();
    try testing.expectEqualStrings("Shop.Services.Pricing.Apply@static", try linkedQname(repo, "tests/PricingTests.cs", .call, "Apply"));
}
