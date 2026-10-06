const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");
const fixture = @import("ts_fixture.zig");
const common = @import("commit_batch.zig");

const own_dir = emetgate.own_dir;
const shadow = emetgate.shadow;
const disk = emetgate.disk;
const receipts = emetgate.receipts;

const testing = std.testing;
const Plain = common.Plain;

const util_src = "export function add(a: number, b: number): number {\n  return a + b;\n}\n";
const new_body = "{\n  return b + a;\n}";
const files = [_]fixture.File{ .{ .rel = "src/util.ts", .text = util_src }, .{ .rel = ".gitignore", .text = ".emetgate/\n" } };

fn skipOffWindows() !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
}

const Tree = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,

    fn init() !Tree {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        return .{ .tmp = tmp, .root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator) };
    }

    fn deinit(self: *Tree) void {
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn abs(self: *Tree, buffer: []u8, rel: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{s}\\{s}", .{ self.root, rel });
    }
};

test "own dir: a directory that is a junction is refused by name, and so is one under a junction" {
    try skipOffWindows();
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.tmp.dir.createDirPath(testing.io, "vault/inner");
    try tree.tmp.dir.createDirPath(testing.io, "work");
    var a: [std.fs.max_path_bytes]u8 = undefined;
    var b: [std.fs.max_path_bytes]u8 = undefined;
    try shadow.createJunction(testing.io, try tree.abs(&a, "work\\linked"), try tree.abs(&b, "vault"));
    defer tree.tmp.dir.deleteDir(testing.io, "work/linked") catch {};

    try testing.expectError(error.WorkspaceIsLink, own_dir.hold(testing.io, try tree.abs(&a, "work\\linked"), .existing));
    try testing.expectError(error.WorkspaceIsLink, own_dir.hold(testing.io, try tree.abs(&a, "work\\linked"), .create));
    try testing.expectError(error.WorkspaceIsLink, own_dir.hold(testing.io, try tree.abs(&a, "work\\linked\\inner"), .existing));
    try testing.expectError(error.WorkspaceIsLink, own_dir.hold(testing.io, try tree.abs(&a, "work\\linked\\fresh"), .create));
    try testing.expectError(error.FileNotFound, tree.tmp.dir.access(testing.io, "vault/fresh", .{}));
}

test "own dir: a missing directory is absent when asked for and made when wanted" {
    try skipOffWindows();
    var tree = try Tree.init();
    defer tree.deinit();
    var a: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expect(try own_dir.hold(testing.io, try tree.abs(&a, "ws\\intents"), .existing) == null);
    try testing.expectError(error.FileNotFound, tree.tmp.dir.access(testing.io, "ws", .{}));
    const held = (try own_dir.hold(testing.io, try tree.abs(&a, "ws\\intents"), .create)).?;
    try held.dir.writeFile(testing.io, .{ .sub_path = "0123456789abcdef.json", .data = "{}" });
    held.close();
    try tree.tmp.dir.access(testing.io, "ws/intents/0123456789abcdef.json", .{});
}

test "own dir: a held directory cannot be renamed away or replaced until it is released" {
    try skipOffWindows();
    var tree = try Tree.init();
    defer tree.deinit();
    var a: [std.fs.max_path_bytes]u8 = undefined;
    const held = (try own_dir.hold(testing.io, try tree.abs(&a, "ws\\intents"), .create)).?;
    var released = false;
    defer if (!released) held.close();

    try testing.expect(std.meta.isError(tree.tmp.dir.rename("ws/intents", tree.tmp.dir, "ws/moved", testing.io)));
    try testing.expect(std.meta.isError(tree.tmp.dir.rename("ws", tree.tmp.dir, "moved", testing.io)));
    try testing.expect(std.meta.isError(tree.tmp.dir.deleteDir(testing.io, "ws/intents")));
    try tree.tmp.dir.access(testing.io, "ws/intents", .{});

    held.close();
    released = true;
    try tree.tmp.dir.rename("ws/intents", tree.tmp.dir, "ws/moved", testing.io);
}

test "own dir: only an empty plain directory is removed, never a junction and never a directory with a file" {
    try skipOffWindows();
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.tmp.dir.createDirPath(testing.io, "vault");
    try tree.tmp.dir.createDirPath(testing.io, "full");
    try tree.tmp.dir.createDirPath(testing.io, "empty");
    try tree.tmp.dir.writeFile(testing.io, .{ .sub_path = "full/kept.txt", .data = "kept\n" });
    var a: [std.fs.max_path_bytes]u8 = undefined;
    var b: [std.fs.max_path_bytes]u8 = undefined;
    try shadow.createJunction(testing.io, try tree.abs(&a, "linked"), try tree.abs(&b, "vault"));
    defer tree.tmp.dir.deleteDir(testing.io, "linked") catch {};

    try testing.expect(!own_dir.removeEmpty(try tree.abs(&a, "linked")));
    try testing.expect(try shadow.isReparsePoint(try tree.abs(&a, "linked")));
    try testing.expect(!own_dir.removeEmpty(try tree.abs(&a, "full")));
    try tree.tmp.dir.access(testing.io, "full/kept.txt", .{});
    try testing.expect(own_dir.removeEmpty(try tree.abs(&a, "empty")));
    try testing.expectError(error.FileNotFound, tree.tmp.dir.access(testing.io, "empty", .{}));
    try testing.expect(!own_dir.removeEmpty(try tree.abs(&a, "missing")));
}

test "own dir: a name is ours only when it is sixteen lower case hex digits and one of our endings" {
    const ends = [_][]const u8{ ".json", ".json.tmp" };
    try testing.expectEqualStrings("0123456789abcdef", own_dir.tagOf("0123456789abcdef.json", &ends).?);
    try testing.expectEqualStrings("0123456789abcdef", own_dir.tagOf("0123456789abcdef.json.tmp", &ends).?);
    for ([_][]const u8{ "data.json", "clone.json", "0123456789abcdef", "0123456789abcdef.txt", "0123456789ABCDEF.json", "0123456789abcde.json", "0123456789abcdef0.json", "0123456789abcdeg.json", ".json", "" }) |name| {
        errdefer std.debug.print("taken as ours: {s}\n", .{name});
        try testing.expect(own_dir.tagOf(name, &ends) == null);
    }
    try testing.expect(own_dir.numbered("blob-0", "blob-", ""));
    try testing.expect(own_dir.numbered(".12.new", ".", ".new"));
    for ([_][]const u8{ "blob-", "blob-x", "blob-1x", "blobs-1" }) |name| try testing.expect(!own_dir.numbered(name, "blob-", ""));
    try testing.expect(!own_dir.numbered("..new", ".", ".new"));
}

test "own dir: the workspace lock refuses a workspace that is a junction and leaves the junction in place" {
    try skipOffWindows();
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.tmp.dir.createDirPath(testing.io, "vault");
    try tree.tmp.dir.createDirPath(testing.io, "repo");
    var a: [std.fs.max_path_bytes]u8 = undefined;
    var b: [std.fs.max_path_bytes]u8 = undefined;
    var c: [std.fs.max_path_bytes]u8 = undefined;
    try shadow.createJunction(testing.io, try tree.abs(&a, "repo\\.emetgate"), try tree.abs(&b, "vault"));
    defer tree.tmp.dir.deleteDir(testing.io, "repo/.emetgate") catch {};

    try testing.expectError(error.WorkspaceIsLink, shadow.Lock.acquire(testing.io, try tree.abs(&c, "repo")));
    try testing.expect(try shadow.isReparsePoint(try tree.abs(&a, "repo\\.emetgate")));
    try testing.expectError(error.FileNotFound, tree.tmp.dir.access(testing.io, "vault/.lock", .{}));
}

test "own dir: releasing the workspace lock leaves a junction that stands where a work directory would be" {
    try skipOffWindows();
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.tmp.dir.createDirPath(testing.io, "vault");
    try tree.tmp.dir.createDirPath(testing.io, "repo/.emetgate");
    var a: [std.fs.max_path_bytes]u8 = undefined;
    var b: [std.fs.max_path_bytes]u8 = undefined;
    var c: [std.fs.max_path_bytes]u8 = undefined;
    try shadow.createJunction(testing.io, try tree.abs(&a, "repo\\.emetgate\\journal"), try tree.abs(&b, "vault"));
    defer tree.tmp.dir.deleteDir(testing.io, "repo/.emetgate/journal") catch {};

    const lock = try shadow.Lock.acquire(testing.io, try tree.abs(&c, "repo"));
    lock.release();
    try testing.expect(try shadow.isReparsePoint(try tree.abs(&a, "repo\\.emetgate\\journal")));
    try tree.tmp.dir.access(testing.io, "vault", .{});
}

test "own dir: recover leaves a file it did not write in the intents directory, whatever its ending" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    try case.repo.write(".emetgate/intents/notes.txt", "mine\n");
    try case.repo.write(".emetgate/intents/data.json", "{}\n");
    try case.repo.write(".emetgate/intents/data.ts", "export const data = 1;\n");
    try case.repo.write(".emetgate/intents/0123456789abcdef.7.new", "ours by name\n");

    const report = try disk.recover(testing.allocator, testing.io, case.repo.root_abs);
    try testing.expectEqual(@as(usize, 0), report.commits.failed + report.commits.pending);
    try testing.expect(case.repo.exists(".emetgate/intents/notes.txt"));
    try testing.expect(case.repo.exists(".emetgate/intents/data.json"));
    try testing.expect(case.repo.exists(".emetgate/intents/data.ts"));
    try testing.expect(!case.repo.exists(".emetgate/intents/0123456789abcdef.7.new"));
}

test "own dir: recover leaves a journal and a commit record it did not name, and reports the journal" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    try case.repo.write(".emetgate/journal/a.json", "{}\n");
    try case.repo.write(".emetgate/journal/readme.txt", "kept\n");
    try case.repo.write(".emetgate/journal/mine.commit", "kept\n");
    try case.repo.write(".emetgate/journal/0123456789abcdef.commit", "{\"batch\":\"0123456789abcdef\"}");

    const report = try disk.recover(testing.allocator, testing.io, case.repo.root_abs);
    try testing.expectEqual(@as(usize, 1), report.failed);
    try testing.expect(case.repo.exists(".emetgate/journal/a.json"));
    try testing.expect(case.repo.exists(".emetgate/journal/readme.txt"));
    try testing.expect(case.repo.exists(".emetgate/journal/mine.commit"));
    try testing.expect(!case.repo.exists(".emetgate/journal/0123456789abcdef.commit"));
}

test "own dir: a commit call leaves a file it did not write in the commit work directory" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    try case.repo.write(".emetgate/commit/readme.txt", "kept\n");
    try case.repo.write(".emetgate/commit/blob-old", "kept too\n");
    try case.repo.write(".emetgate/commit/blob-7", "stale\n");
    const before = try env.head();

    const reply = try env.call("emetgate_try", .{ .file = try env.abs("src/util.ts"), .symbol = "add", .hash = try env.hashOf("src/util.ts", "add"), .body = new_body, .message = "fix: swap" }, common.green, true);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings(before, try env.git(&.{ "rev-parse", "HEAD^" }));
    try testing.expect(case.repo.exists(".emetgate/commit/readme.txt"));
    try testing.expect(case.repo.exists(".emetgate/commit/blob-old"));
    try testing.expect(!case.repo.exists(".emetgate/commit/blob-7"));
}

test "own dir: receipts are not read or moved through a receipts directory that is a junction" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ .{ .rel = "src/util.ts", .text = util_src }, .{ .rel = ".gitignore", .text = ".emetgate/\n" }, .{ .rel = "vault/a.json", .text = "{}\n" } });
    defer case.deinit();
    const env = &case.env;
    try case.repo.tmp.dir.createDirPath(testing.io, "repo/.emetgate");
    try shadow.createJunction(testing.io, try env.abs(".emetgate/receipts"), try env.abs("vault"));
    defer case.repo.tmp.dir.deleteDir(testing.io, "repo/.emetgate/receipts") catch {};

    try testing.expectError(error.WorkspaceIsLink, receipts.attach(testing.allocator, testing.io, case.repo.root_abs, "HEAD"));
    try testing.expect(case.repo.exists("vault/a.json"));
    try testing.expect(!case.repo.exists("vault/attached"));
}

test "own dir: while a shadow is prepared its workspace cannot be renamed away" {
    try skipOffWindows();
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.tmp.dir.createDirPath(testing.io, "project");
    try tree.tmp.dir.writeFile(testing.io, .{ .sub_path = "project/a.ts", .data = "export const a = 1;\n" });
    var a: [std.fs.max_path_bytes]u8 = undefined;
    var b: [std.fs.max_path_bytes]u8 = undefined;
    var c: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tree.abs(&a, "project");
    const base = try tree.abs(&b, "shadows");
    const key = emetgate.shadow_root.repoKey(root);
    const shadow_abs = try std.fmt.bufPrint(&c, "{s}\\{s}\\shadow", .{ base, &key });
    var key_rel_buf: [128]u8 = undefined;
    const key_rel = try std.fmt.bufPrint(&key_rel_buf, "shadows/{s}", .{&key});

    var prepared = try shadow.Shadow.prepare(testing.io, .{ .root_abs = root, .base_abs = base, .shadow_abs = shadow_abs, .files = &.{"a.ts"} });
    var closed = false;
    defer if (!closed) prepared.close();
    try testing.expect(std.meta.isError(tree.tmp.dir.rename(key_rel, tree.tmp.dir, "shadows/moved", testing.io)));
    prepared.close();
    closed = true;
    try shadow.remove(testing.io, base, shadow_abs);
}
