const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");
const fixture = @import("ts_fixture.zig");
const support = @import("runner_support.zig");

const own_dir = emetgate.own_dir;
const shadow = emetgate.shadow;
const disk = emetgate.disk;
const receipts = emetgate.receipts;
const symbol = emetgate.symbol;
const handlers = emetgate.handlers;
const telemetry = emetgate.telemetry;
const Runtime = emetgate.runtime.Runtime;

const testing = std.testing;
const TsRepo = fixture.TsRepo;

const util_src = "export function add(a: number, b: number): number {\n  return a + b;\n}\n";
const new_body = "{\n  return b + a;\n}";
const green = "cmd /c exit 0";
const files = [_]fixture.File{ .{ .rel = "src/util.ts", .text = util_src }, .{ .rel = ".gitignore", .text = ".emetgate/\n" } };
const vault_files = [_]fixture.File{
    .{ .rel = "src/util.ts", .text = util_src },
    .{ .rel = ".gitignore", .text = ".emetgate/\n" },
    .{ .rel = "vault/readme.txt", .text = "kept\n" },
    .{ .rel = "vault/a.json", .text = "{}\n" },
    .{ .rel = "vault/0123456789abcdef.json", .text = "{}\n" },
    .{ .rel = "vault/0123456789abcdef.commit", .text = "{\"batch\":\"0123456789abcdef\"}" },
    .{ .rel = "vault/fedcba9876543210.json.tmp", .text = "{}\n" },
};

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

const Linked = struct {
    repo: TsRepo,
    link: []u8,

    fn init(self: *Linked, link_rel: []const u8) !void {
        self.repo = try TsRepo.init(&vault_files);
        errdefer self.repo.deinit();
        try self.repo.tmp.dir.createDirPath(testing.io, "repo/.emetgate");
        self.link = try self.repo.abs(testing.allocator, link_rel);
        errdefer testing.allocator.free(self.link);
        const target = try self.repo.abs(testing.allocator, "vault");
        defer testing.allocator.free(target);
        try shadow.createJunction(testing.io, self.link, target);
    }

    fn deinit(self: *Linked) void {
        std.Io.Dir.cwd().deleteDir(testing.io, self.link) catch {};
        testing.allocator.free(self.link);
        self.repo.deinit();
    }

    fn expectVaultWhole(self: *Linked) !void {
        for (vault_files[2..]) |file| {
            errdefer std.debug.print("gone: {s}\n", .{file.rel});
            try testing.expect(self.repo.exists(file.rel));
        }
        try testing.expect(try shadow.isReparsePoint(self.link));
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
    try testing.expect(try own_dir.hold(testing.io, try tree.abs(&a, "ws\\journal"), .existing) == null);
    try testing.expectError(error.FileNotFound, tree.tmp.dir.access(testing.io, "ws", .{}));
    const held = (try own_dir.hold(testing.io, try tree.abs(&a, "ws\\journal"), .create)).?;
    try held.dir.writeFile(testing.io, .{ .sub_path = "0123456789abcdef.json", .data = "{}" });
    held.close();
    try tree.tmp.dir.access(testing.io, "ws/journal/0123456789abcdef.json", .{});
}

test "own dir: a held directory cannot be renamed away or replaced until it is released" {
    try skipOffWindows();
    var tree = try Tree.init();
    defer tree.deinit();
    var a: [std.fs.max_path_bytes]u8 = undefined;
    const held = (try own_dir.hold(testing.io, try tree.abs(&a, "ws\\journal"), .create)).?;
    var released = false;
    defer if (!released) held.close();

    try testing.expect(std.meta.isError(tree.tmp.dir.rename("ws/journal", tree.tmp.dir, "ws/moved", testing.io)));
    try testing.expect(std.meta.isError(tree.tmp.dir.rename("ws", tree.tmp.dir, "moved", testing.io)));
    try testing.expect(std.meta.isError(tree.tmp.dir.deleteDir(testing.io, "ws/journal")));
    try tree.tmp.dir.access(testing.io, "ws/journal", .{});

    held.close();
    released = true;
    try tree.tmp.dir.rename("ws/journal", tree.tmp.dir, "ws/moved", testing.io);
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

test "own dir: releasing the workspace lock leaves a junction that stands where the journal directory would be" {
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

test "own dir: recover leaves the files of a directory that .emetgate/journal links to and refuses by name" {
    try skipOffWindows();
    var case: Linked = undefined;
    try case.init(".emetgate/journal");
    defer case.deinit();

    try testing.expectError(error.WorkspaceIsLink, disk.recover(testing.allocator, testing.io, case.repo.root_abs));
    try case.expectVaultWhole();
}

test "own dir: recover leaves the files of a directory that .emetgate itself links to" {
    try skipOffWindows();
    var repo = try TsRepo.init(&.{
        .{ .rel = "src/util.ts", .text = util_src },
        .{ .rel = "vault/journal/a.json", .text = "{}\n" },
        .{ .rel = "vault/journal/0123456789abcdef.json", .text = "{}\n" },
        .{ .rel = "vault/journal/0123456789abcdef.commit", .text = "{}\n" },
    });
    defer repo.deinit();
    const link = try repo.abs(testing.allocator, ".emetgate");
    defer testing.allocator.free(link);
    const target = try repo.abs(testing.allocator, "vault");
    defer testing.allocator.free(target);
    try shadow.createJunction(testing.io, link, target);
    defer std.Io.Dir.cwd().deleteDir(testing.io, link) catch {};

    try testing.expectError(error.WorkspaceIsLink, disk.recover(testing.allocator, testing.io, repo.root_abs));
    try testing.expect(repo.exists("vault/journal/a.json"));
    try testing.expect(repo.exists("vault/journal/0123456789abcdef.json"));
    try testing.expect(repo.exists("vault/journal/0123456789abcdef.commit"));
}

test "own dir: a gated write is refused by name when .emetgate/journal is a junction, and nothing is written through it" {
    try skipOffWindows();
    var case: Linked = undefined;
    try case.init(".emetgate/journal");
    defer case.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const file = try case.repo.abs(arena, "src/util.ts");
    const hash = symbol.formatHash(try support.hashOfRef(testing.allocator, testing.io, runtime, file, "add"));
    var args: std.json.ObjectMap = .empty;
    try args.put(arena, "file", .{ .string = file });
    try args.put(arena, "symbol", .{ .string = "add" });
    try args.put(arena, "hash", .{ .string = try arena.dupe(u8, &hash) });
    try args.put(arena, "body", .{ .string = new_body });
    var event: telemetry.Event = .{ .tool = "emetgate_try" };
    const result = try handlers.callTool(testing.allocator, testing.io, runtime, "emetgate_try", .{ .object = args }, &event, .{ .root = case.repo.root_abs, .test_command = green });
    defer testing.allocator.free(result.text);
    errdefer std.debug.print("{s}\n", .{result.text});

    try testing.expect(result.is_error);
    try testing.expect(std.mem.indexOf(u8, result.text, "WorkspaceIsLink") != null);
    const now = try case.repo.read("src/util.ts");
    defer testing.allocator.free(now);
    try testing.expectEqualStrings(util_src, now);
    try case.expectVaultWhole();
    var vault = try case.repo.tmp.dir.openDir(testing.io, "repo/vault", .{ .iterate = true });
    defer vault.close(testing.io);
    var count: usize = 0;
    var it = vault.iterate();
    while (try it.next(testing.io)) |_| count += 1;
    try testing.expectEqual(vault_files.len - 2, count);
}

test "own dir: recover leaves a journal and a commit record it did not name, and reports the journal" {
    try skipOffWindows();
    var repo = try TsRepo.init(&files);
    defer repo.deinit();
    try repo.write(".emetgate/journal/a.json", "{}\n");
    try repo.write(".emetgate/journal/readme.txt", "kept\n");
    try repo.write(".emetgate/journal/mine.commit", "kept\n");
    try repo.write(".emetgate/journal/0123456789abcdef.commit", "{\"batch\":\"0123456789abcdef\"}");

    const report = try disk.recover(testing.allocator, testing.io, repo.root_abs);
    try testing.expectEqual(@as(usize, 1), report.failed);
    try testing.expect(repo.exists(".emetgate/journal/a.json"));
    try testing.expect(repo.exists(".emetgate/journal/readme.txt"));
    try testing.expect(repo.exists(".emetgate/journal/mine.commit"));
    try testing.expect(!repo.exists(".emetgate/journal/0123456789abcdef.commit"));
}

test "own dir: receipts are not read or moved through a receipts directory that is a junction" {
    try skipOffWindows();
    var case: Linked = undefined;
    try case.init(".emetgate/receipts");
    defer case.deinit();

    try testing.expectError(error.WorkspaceIsLink, receipts.attach(testing.allocator, testing.io, case.repo.root_abs, "HEAD"));
    try case.expectVaultWhole();
    try testing.expect(!case.repo.exists("vault/attached"));
}

test "own dir: a receipt is not written through a receipts directory that is a junction" {
    try skipOffWindows();
    var case: Linked = undefined;
    try case.init(".emetgate/receipts");
    defer case.deinit();

    try testing.expectError(error.WorkspaceIsLink, receipts.write(testing.allocator, testing.io, case.repo.root_abs, .{
        .operation = .@"try",
        .class = .spending,
        .evidence = "test",
        .files = &.{},
        .test_command = green,
        .version = "0",
    }));
    try case.expectVaultWhole();
    var vault = try case.repo.tmp.dir.openDir(testing.io, "repo/vault", .{ .iterate = true });
    defer vault.close(testing.io);
    var count: usize = 0;
    var it = vault.iterate();
    while (try it.next(testing.io)) |_| count += 1;
    try testing.expectEqual(vault_files.len - 2, count);
}

extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, disposition: u32, flags: u32, template: ?std.os.windows.HANDLE) callconv(.winapi) std.os.windows.HANDLE;

test "own dir: a shadow workspace that another handle holds alone is not cleaned" {
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

    var prepared = try shadow.Shadow.prepare(testing.io, .{ .root_abs = root, .base_abs = base, .shadow_abs = shadow_abs, .files = &.{"a.ts"} });
    prepared.close();

    var wide: [std.fs.max_path_bytes:0]u16 = undefined;
    const workspace = std.fs.path.dirname(shadow_abs).?;
    const len = try std.unicode.wtf8ToWtf16Le(&wide, workspace);
    wide[len] = 0;
    const alone = CreateFileW(&wide, 0x80000000, 0, null, 3, 0x02000000, null);
    try testing.expect(alone != std.os.windows.INVALID_HANDLE_VALUE);
    const refused = shadow.remove(testing.io, base, shadow_abs);
    std.os.windows.CloseHandle(alone);
    try testing.expectError(error.WorkspaceBusy, refused);
    var probe: [std.fs.max_path_bytes]u8 = undefined;
    try std.Io.Dir.cwd().access(testing.io, try std.fmt.bufPrint(&probe, "{s}\\a.ts", .{shadow_abs}), .{});
    try shadow.remove(testing.io, base, shadow_abs);
}

test "own dir: a shadow directory that is itself a junction is refused and what it points to stays" {
    try skipOffWindows();
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.tmp.dir.createDirPath(testing.io, "vault");
    try tree.tmp.dir.writeFile(testing.io, .{ .sub_path = "vault/kept.txt", .data = "kept\n" });
    var a: [std.fs.max_path_bytes]u8 = undefined;
    var b: [std.fs.max_path_bytes]u8 = undefined;
    var c: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tree.abs(&a, "shadows");
    const key = emetgate.shadow_root.repoKey(base);
    const shadow_abs = try std.fmt.bufPrint(&c, "{s}\\{s}\\shadow", .{ base, &key });
    try std.Io.Dir.cwd().createDirPath(testing.io, std.fs.path.dirname(shadow_abs).?);
    try shadow.createJunction(testing.io, shadow_abs, try tree.abs(&b, "vault"));
    defer std.Io.Dir.cwd().deleteDir(testing.io, shadow_abs) catch {};

    try testing.expectError(error.WorkspaceIsLink, shadow.remove(testing.io, base, shadow_abs));
    try testing.expect(try shadow.isReparsePoint(shadow_abs));
    try tree.tmp.dir.access(testing.io, "vault/kept.txt", .{});
}
