const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");
const fact_store = emetgate.fact_store;
const fact_file = emetgate.fact_file;
const facts = emetgate.facts;
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
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const started = std.Io.Clock.awake.now(testing.io).nanoseconds;
    const result = try repo.evidence(arena.allocator(), .{ .targets = &.{.{ .path = "a.ts", .qname = "f" }}, .intent = .explain }, evidence.default_budget);
    const elapsed = std.Io.Clock.awake.now(testing.io).nanoseconds - started;
    try testing.expectEqual(answer.Status.partial, result.status());
    const text = try evidenceText(result);
    try testing.expect(std.mem.indexOf(u8, text, evidence.unreadable_note) != null);
    try testing.expect(std.mem.indexOf(u8, text, "\nPartial because: 1 files could not be read (locked or access denied).\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "missing 1 unreadable") != null);
    try testing.expect(elapsed < 50 * std.time.ns_per_ms);
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
    {
        const repo = try fixture.open(runtime, fact_store.default_max_file_bytes);
        defer repo.deinit();
        _ = try repo.refresh();
        const source = repo.store.file(repo.store.fileId("a.ts").?).facts;
        outline = try keep.dupe(facts.Outline, source.outline);
        bodies = try keep.alloc(u32, source.defs.len);
        for (source.defs, bodies) |d, *slot| slot.* = d.body_start;
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
    const held = try repo.refresh();
    std.os.windows.CloseHandle(holder);
    try testing.expect(held.extract_ms < 50);
    const id = repo.store.fileId("a.ts").?;
    try testing.expectEqual(emetgate.facts_store.Status.unreadable, repo.store.file(id).status);
    const free = try repo.refresh();
    try testing.expectEqual(@as(usize, 1), free.extracted);
    try testing.expectEqual(emetgate.facts_store.Status.indexed, repo.store.file(id).status);
}
