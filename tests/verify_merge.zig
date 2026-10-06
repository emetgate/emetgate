const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");
const fixture = @import("ts_fixture.zig");
const n_version = @import("verify_n_version.zig");

const receipts = emetgate.receipts;
const verify_run = emetgate.verify_run;
const verify_merge = emetgate.verify_merge;
const checker = emetgate.checker;
const Runtime = emetgate.runtime.Runtime;
const Verdict = checker.Verdict;

const testing = std.testing;
const TsRepo = fixture.TsRepo;

const util_src = "export function add(a: number, b: number): number {\n  return a + b;\n}\n";
const util_hand = "export function add(a: number, b: number): number {\n  return a + b + 0;\n}\n";
const other_src = "export const one = 1;\n";
const lines_src = "export const first = 1;\nexport const second = 2;\nexport const third = 3;\n";
const green = "cmd /c exit 0";
const files = [_]fixture.File{
    .{ .rel = "src/util.ts", .text = util_src },
    .{ .rel = "src/other.ts", .text = other_src },
    .{ .rel = "src/lines.ts", .text = lines_src },
    .{ .rel = "src/untouched.ts", .text = "export const still = 0;\n" },
};

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

const Entry = struct {
    path: []const u8,
    digest: [32]u8,

    fn less(_: void, a: Entry, b: Entry) bool {
        return std.mem.order(u8, a.path, b.path) == .lt;
    }
};

const Case = struct {
    repo: TsRepo,
    runtime: *Runtime,
    arena_state: std.heap.ArenaAllocator,

    fn init(self: *Case) !void {
        self.repo = try TsRepo.init(&files);
        errdefer self.repo.deinit();
        self.runtime = try Runtime.create(testing.allocator);
        self.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    }

    fn deinit(self: *Case) void {
        self.arena_state.deinit();
        self.runtime.destroy() catch @panic("live snapshots");
        self.repo.deinit();
    }

    fn arena(self: *Case) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    fn git(self: *Case, argv: []const []const u8) ![]const u8 {
        const out = (try receipts.git(self.arena(), testing.io, self.repo.root_abs, argv)) orelse return error.GitFailed;
        return std.mem.trimEnd(u8, out, "\r\n");
    }

    fn change(self: *Case, rel: []const u8, text: []const u8, message: []const u8) !void {
        try self.repo.write(rel, text);
        _ = try self.git(&.{ "commit", "-q", "-am", message });
    }

    fn twoSides(self: *Case, side_rel: []const u8, side_text: []const u8, main_rel: []const u8, main_text: []const u8) !void {
        const base = try self.git(&.{ "rev-parse", "HEAD" });
        _ = try self.git(&.{ "checkout", "-q", "-b", "side" });
        try self.change(side_rel, side_text, "side");
        _ = try self.git(&.{ "checkout", "-q", "-b", "trunk", base });
        try self.change(main_rel, main_text, "trunk");
    }

    fn store(self: *Case) ![]const Entry {
        var objects = try self.repo.tmp.dir.openDir(testing.io, "repo/.git/objects", .{ .iterate = true });
        defer objects.close(testing.io);
        var walker = try objects.walk(testing.allocator);
        defer walker.deinit();
        var list: std.ArrayList(Entry) = .empty;
        while (try walker.next(testing.io)) |entry| {
            var digest: [32]u8 = @splat(0);
            if (entry.kind == .file) {
                const bytes = try objects.readFileAlloc(testing.io, entry.path, self.arena(), .unlimited);
                std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
            }
            try list.append(self.arena(), .{ .path = try self.arena().dupe(u8, entry.path), .digest = digest });
        }
        std.mem.sort(Entry, list.items, {}, Entry.less);
        return list.items;
    }

    fn expectStore(self: *Case, before: []const Entry) !void {
        const after = try self.store();
        try testing.expectEqual(before.len, after.len);
        for (before, after) |a, b| {
            errdefer std.debug.print("object store changed at {s} / {s}\n", .{ a.path, b.path });
            try testing.expectEqualStrings(a.path, b.path);
            try testing.expectEqualSlices(u8, &a.digest, &b.digest);
        }
    }

    fn verify(self: *Case) !verify_run.Result {
        const before = try self.store();
        try testing.expect(before.len > 4);
        const result = try verify_run.run(testing.allocator, self.arena(), testing.io, self.runtime, self.repo.root_abs, .{ .commit = "HEAD", .test_command = green });
        try self.expectStore(before);
        try testing.expect(!self.repo.exists(".emetgate"));
        try n_version.compare(self.arena(), self.repo.root_abs, result);
        try self.expectStore(before);
        try testing.expectEqualStrings("", try self.git(&.{ "status", "--porcelain", "--untracked-files=all" }));
        return result;
    }
};

fn expectNamed(result: verify_run.Result, paths: []const []const u8) !void {
    errdefer for (result.report.files) |f| std.debug.print("file {s}: {t} {s}\n", .{ f.path, f.outcome.verdict, f.outcome.reason });
    try testing.expectEqual(Verdict.unverified, result.report.verdict);
    try testing.expectEqualStrings(verify_merge.carries_content, result.report.reason);
    try testing.expectEqual(@as(u8, 53), verify_run.exitCode(result.report.verdict));
    try testing.expectEqual(paths.len, result.report.files.len);
    for (paths, result.report.files) |path, f| {
        try testing.expectEqualStrings(path, f.path);
        try testing.expectEqual(Verdict.unverified, f.outcome.verdict);
        try testing.expectEqualStrings(verify_merge.carries_content, f.outcome.reason);
    }
}

test "verify merge: a merge commit that carries a hand edit is unverified and names the path" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const first = try case.git(&.{ "rev-parse", "HEAD" });
    const side = try case.git(&.{ "commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "side" });
    try case.repo.write("src/util.ts", util_hand);
    _ = try case.git(&.{ "add", "src/util.ts" });
    const tree = try case.git(&.{"write-tree"});
    const merge = try case.git(&.{ "commit-tree", tree, "-p", first, "-p", side, "-m", "merge side" });
    _ = try case.git(&.{ "update-ref", "HEAD", merge });
    try testing.expect(contains(try case.git(&.{ "show", "HEAD:src/util.ts" }), "a + b + 0"));

    try expectNamed(try case.verify(), &.{"src/util.ts"});
}

test "verify merge: a merge commit whose tree is what git merges from its two parents is merged, with its own exit code" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.twoSides("src/other.ts", "export const one = 11;\n", "src/util.ts", util_hand);
    _ = try case.git(&.{ "merge", "-q", "--no-ff", "-m", "merge side", "side" });
    try testing.expect(contains(try case.git(&.{ "show", "HEAD:src/other.ts" }), "11"));
    try testing.expect(contains(try case.git(&.{ "show", "HEAD:src/util.ts" }), "a + b + 0"));

    const result = try case.verify();
    try testing.expectEqual(Verdict.merged, result.report.verdict);
    try testing.expectEqualStrings(verify_merge.added_nothing, result.report.reason);
    try testing.expectEqual(@as(usize, 0), result.report.files.len);
    try testing.expectEqual(@as(usize, 0), result.report.receipts.len);
    const code = verify_run.exitCode(result.report.verdict);
    try testing.expectEqual(@as(u8, 58), code);
    try testing.expect(code != verify_run.exitCode(.verified));
    try testing.expect(code != verify_run.exitCode(.unverified));
    try testing.expect(code != verify_run.exitCode(.mismatch));
}

test "verify merge: a hand edit made while two real sides are merged is named, and the repository's object store stays byte for byte" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.twoSides("src/other.ts", "export const one = 11;\n", "src/util.ts", util_hand);
    _ = try case.git(&.{ "merge", "-q", "--no-ff", "--no-commit", "side" });
    try case.repo.write("src/lines.ts", "export const first = 1;\nexport const second = 22;\nexport const third = 3;\n");
    _ = try case.git(&.{ "add", "src/lines.ts" });
    _ = try case.git(&.{ "commit", "-q", "-m", "merge side" });
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, try case.git(&.{ "rev-list", "--parents", "-n", "1", "HEAD" }), " ") + 1);
    _ = try case.git(&.{ "prune", "--expire=now" });

    try expectNamed(try case.verify(), &.{"src/lines.ts"});
}

test "verify merge: a conflict resolved by hand is named, and the repository's object store stays byte for byte" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.twoSides("src/lines.ts", "export const first = 10;\nexport const second = 2;\nexport const third = 3;\n", "src/lines.ts", "export const first = 100;\nexport const second = 2;\nexport const third = 3;\n");
    try testing.expectError(error.GitFailed, case.git(&.{ "merge", "-q", "--no-ff", "-m", "merge side", "side" }));
    try case.repo.write("src/lines.ts", "export const first = 110;\nexport const second = 2;\nexport const third = 3;\n");
    _ = try case.git(&.{ "add", "src/lines.ts" });
    _ = try case.git(&.{ "commit", "-q", "-m", "merge side" });

    try expectNamed(try case.verify(), &.{"src/lines.ts"});
}

test "verify merge: a commit with three parents is unverified because what it adds cannot be told" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const first = try case.git(&.{ "rev-parse", "HEAD" });
    const one = try case.git(&.{ "commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "one" });
    const two = try case.git(&.{ "commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "two" });
    const merge = try case.git(&.{ "commit-tree", "HEAD^{tree}", "-p", first, "-p", one, "-p", two, "-m", "three" });
    _ = try case.git(&.{ "update-ref", "HEAD", merge });

    const result = try case.verify();
    try testing.expectEqual(Verdict.unverified, result.report.verdict);
    try testing.expectEqualStrings(verify_merge.many_parents, result.report.reason);
    try testing.expectEqual(@as(usize, 0), result.report.files.len);
}

test "verify merge: two parents git cannot merge on its own leave the commit unverified because it cannot be told" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const first = try case.git(&.{ "rev-parse", "HEAD" });
    const apart = try case.git(&.{ "commit-tree", "HEAD^{tree}", "-m", "no history in common" });
    const merge = try case.git(&.{ "commit-tree", "HEAD^{tree}", "-p", first, "-p", apart, "-m", "merge apart" });
    _ = try case.git(&.{ "update-ref", "HEAD", merge });

    const result = try case.verify();
    try testing.expectEqual(Verdict.unverified, result.report.verdict);
    try testing.expectEqualStrings(verify_merge.merge_not_run, result.report.reason);
    try testing.expectEqual(@as(usize, 0), result.report.files.len);
}

test "verify merge: the printed report carries the verdict word and the reason, as text and as JSON" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.twoSides("src/other.ts", "export const one = 11;\n", "src/util.ts", util_hand);
    _ = try case.git(&.{ "merge", "-q", "--no-ff", "-m", "merge side", "side" });
    const result = try case.verify();

    var text: std.Io.Writer.Allocating = .init(testing.allocator);
    defer text.deinit();
    try verify_run.writeText(&text.writer, result);
    try testing.expect(contains(text.written(), ": merged  (" ++ verify_merge.added_nothing ++ ")\n"));
    var json: std.Io.Writer.Allocating = .init(testing.allocator);
    defer json.deinit();
    try verify_run.writeJson(&json.writer, result);
    try testing.expect(contains(json.written(), "\"verdict\":\"merged\",\"reason\":\"" ++ verify_merge.added_nothing ++ "\",\"files\":[]"));
}

test "verify merge: the work directory is emptied of git's object files only" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const object = "0334b41c0825c460cc8c3338b56b57ad4e46a5";
    try tmp.dir.createDirPath(testing.io, "d8");
    try tmp.dir.createDirPath(testing.io, "e1");
    try tmp.dir.createDirPath(testing.io, "notes");
    try tmp.dir.createDirPath(testing.io, "D9");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "d8/" ++ object, .data = "x" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "e1/" ++ object, .data = "x" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "e1/kept.txt", .data = "mine\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "notes/" ++ object, .data = "mine\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "D9/" ++ object, .data = "mine\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "ab", .data = "mine\n" });

    verify_merge.clear(testing.io, tmp.dir);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "d8", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "e1/" ++ object, .{}));
    try tmp.dir.access(testing.io, "e1/kept.txt", .{});
    try tmp.dir.access(testing.io, "notes/" ++ object, .{});
    try tmp.dir.access(testing.io, "D9/" ++ object, .{});
    try tmp.dir.access(testing.io, "ab", .{});
}

test "verify merge: a work directory that is a junction is refused by name and nothing is written through it" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.twoSides("src/other.ts", "export const one = 11;\n", "src/util.ts", util_hand);
    _ = try case.git(&.{ "merge", "-q", "--no-ff", "--no-commit", "side" });
    try case.repo.write("src/lines.ts", "export const first = 1;\nexport const second = 22;\nexport const third = 3;\n");
    _ = try case.git(&.{ "add", "src/lines.ts" });
    _ = try case.git(&.{ "commit", "-q", "-m", "merge side" });
    try case.repo.tmp.dir.createDirPath(testing.io, "vault");
    try case.repo.tmp.dir.createDirPath(testing.io, "repo/.emetgate");
    const link = try case.repo.abs(case.arena(), ".emetgate/verify");
    const target = try std.fmt.allocPrint(case.arena(), "{s}\\..\\vault", .{case.repo.root_abs});
    try emetgate.shadow.createJunction(testing.io, link, try std.Io.Dir.cwd().realPathFileAlloc(testing.io, target, case.arena()));
    defer std.Io.Dir.cwd().deleteDir(testing.io, link) catch {};

    try testing.expectError(error.WorkspaceIsLink, verify_run.run(testing.allocator, case.arena(), testing.io, case.runtime, case.repo.root_abs, .{ .commit = "HEAD", .test_command = green }));
    var vault = try case.repo.tmp.dir.openDir(testing.io, "vault", .{ .iterate = true });
    defer vault.close(testing.io);
    var it = vault.iterate();
    try testing.expect(try it.next(testing.io) == null);
}
