const std = @import("std");
const builtin = @import("builtin");
const git_fixture = @import("git_fixture.zig");
const symbol = @import("emetgate").symbol;
const disk = @import("emetgate").disk;
const shadow = @import("emetgate").shadow;

const testing = std.testing;
const max_files = 3;

const Kind = enum { modify, create, delete };

const StopAt = struct {
    target: usize,
    seen: usize = 0,

    fn reached(context: *anyopaque) bool {
        const self: *StopAt = @ptrCast(@alignCast(context));
        self.seen += 1;
        return self.seen == self.target;
    }
};

const old = [max_files][]const u8{
    "export const a = 1;\n",
    "export const b = 1;\n",
    "export const c = 1;\n",
};
const new = [max_files][]const u8{
    "export const a = 2;\n",
    "export const b = 2;\n",
    "export const c = 2;\n",
};

fn git(root: []const u8, args: []const []const u8) ![]u8 {
    var argv: [8][]const u8 = undefined;
    argv[0] = "git";
    @memcpy(argv[1..][0..args.len], args);
    const result = try std.process.run(testing.allocator, testing.io, .{ .argv = argv[0 .. args.len + 1], .cwd = .{ .path = root } });
    defer testing.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            testing.allocator.free(result.stdout);
            return error.GitFailed;
        },
        else => {
            testing.allocator.free(result.stdout);
            return error.GitFailed;
        },
    }
    return result.stdout;
}

fn tracked(root: []const u8, rel: []const u8) !bool {
    const out = try git(root, &.{ "ls-files", "--", rel });
    defer testing.allocator.free(out);
    return std.mem.trim(u8, out, " \r\n").len != 0;
}

fn name(buf: []u8, i: usize) ![]const u8 {
    return std.fmt.bufPrint(buf, "f{d}.ts", .{i});
}

const Repo = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    journal_dir: []u8,
    kinds: []const Kind,

    fn init(kinds: []const Kind) !Repo {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        for (kinds, 0..) |kind, i| {
            if (kind == .create) continue;
            var name_buf: [16]u8 = undefined;
            try tmp.dir.writeFile(testing.io, .{ .sub_path = try name(&name_buf, i), .data = old[i] });
        }
        const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        errdefer testing.allocator.free(root);
        try git_fixture.initRepo(root);
        testing.allocator.free(try git(root, &.{ "add", "." }));
        testing.allocator.free(try git(root, &.{ "commit", "-q", "--allow-empty", "-m", "init" }));
        const journal_dir = try std.fmt.allocPrint(testing.allocator, "{s}\\{s}\\journal", .{ root, shadow.workspace_dir });
        return .{ .tmp = tmp, .root = root, .journal_dir = journal_dir, .kinds = kinds };
    }

    fn deinit(self: *Repo) void {
        testing.allocator.free(self.journal_dir);
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn batch(self: *const Repo) disk.Batch {
        var b = disk.Batch.init(testing.allocator, testing.io, self.journal_dir);
        b.root = self.root;
        return b;
    }

    fn prepareAll(self: *const Repo, pendings: []disk.Pending) !void {
        for (pendings, 0..) |*p, i| {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = try std.fmt.bufPrint(&buf, "{s}\\f{d}.ts", .{ self.root, i });
            p.* = switch (self.kinds[i]) {
                .modify => try disk.prepare(testing.allocator, testing.io, path, new[i], symbol.hashOf(old[i])),
                .create => try disk.stageCreate(testing.allocator, testing.io, path, new[i]),
                .delete => try disk.stageDelete(testing.allocator, testing.io, path, symbol.hashOf(old[i])),
            };
        }
    }

    fn content(self: *const Repo, i: usize) !?[]u8 {
        var name_buf: [16]u8 = undefined;
        return self.tmp.dir.readFileAlloc(testing.io, try name(&name_buf, i), testing.allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => null,
            else => |e| e,
        };
    }

    fn expectFile(self: *const Repo, i: usize, expected: ?[]const u8) !void {
        const actual = try self.content(i);
        defer if (actual) |a| testing.allocator.free(a);
        var name_buf: [16]u8 = undefined;
        const rel = try name(&name_buf, i);
        if (expected) |e| {
            try testing.expectEqualStrings(e, actual orelse return error.FileMissing);
            if (!try tracked(self.root, rel)) return error.NotIndexed;
        } else {
            if (actual != null) return error.FileLeft;
            if (try tracked(self.root, rel)) return error.StillIndexed;
        }
    }

    fn expectOld(self: *const Repo) !void {
        for (self.kinds, 0..) |kind, i| try self.expectFile(i, if (kind == .create) null else old[i]);
    }

    fn expectNew(self: *const Repo) !void {
        for (self.kinds, 0..) |kind, i| try self.expectFile(i, if (kind == .delete) null else new[i]);
    }

    fn expectNoDebris(self: *const Repo) !void {
        var it = self.tmp.dir.iterate();
        while (try it.next(testing.io)) |entry| {
            if (entry.kind == .directory) continue;
            errdefer std.debug.print("unexpected entry: {s}\n", .{entry.name});
            if (!std.mem.startsWith(u8, entry.name, "f") or entry.name.len != "f0.ts".len) return error.Debris;
        }
        var journal = self.tmp.dir.openDir(testing.io, shadow.workspace_dir ++ "\\journal", .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => |e| return e,
        };
        defer journal.close(testing.io);
        var entries = journal.iterate();
        if (try entries.next(testing.io)) |entry| {
            std.debug.print("journal debris: {s}\n", .{entry.name});
            return error.Debris;
        }
    }
};

fn crashAtEveryStep(kinds: []const Kind) !void {
    var written: usize = 0;
    var finalized: usize = 0;
    var indexed: usize = 0;
    for (kinds) |kind| switch (kind) {
        .modify => {
            written += 1;
            finalized += 1;
        },
        .create => {
            written += 1;
            indexed = 1;
        },
        .delete => {
            finalized += 1;
            indexed = 1;
        },
    };
    const before_record = 1 + 3 * written;
    const steps = before_record + 1 + finalized + indexed + 1;
    var stop: usize = 1;
    while (true) : (stop += 1) {
        var repo = try Repo.init(kinds);
        defer repo.deinit();
        const batch = repo.batch();
        var pendings: [max_files]disk.Pending = undefined;
        try repo.prepareAll(pendings[0..kinds.len]);

        var at: StopAt = .{ .target = stop };
        const step: disk.Step = .{ .context = &at, .reached = StopAt.reached };
        disk.commitBatch(pendings[0..kinds.len], null, null, &batch, &step) catch |err| {
            errdefer std.debug.print("crash after step {d} of {d}\n", .{ stop, steps });
            try testing.expectEqual(error.Crashed, err);
            const report = try disk.recover(testing.allocator, testing.io, repo.root);
            try testing.expectEqual(@as(usize, 0), report.failed);
            try testing.expectEqual(@as(usize, 0), report.not_indexed);
            if (stop <= before_record) try repo.expectOld() else try repo.expectNew();
            try repo.expectNoDebris();
            continue;
        };
        try testing.expectEqual(steps + 1, stop);
        try repo.expectNew();
        try repo.expectNoDebris();
        break;
    }
}

test "batch delete crash: a crash after any step of a modify plus delete commit recovers to all old or all new" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try crashAtEveryStep(&.{ .modify, .delete });
}

test "batch delete crash: a crash after any step of a modify, create and delete commit recovers to all old or all new" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try crashAtEveryStep(&.{ .delete, .modify, .create });
}

test "batch delete crash: a file deleted by a batch stays on disk until the commit record" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init(&.{ .modify, .delete });
    defer repo.deinit();
    const batch = repo.batch();
    var pendings: [2]disk.Pending = undefined;
    try repo.prepareAll(&pendings);
    var at: StopAt = .{ .target = 1 + 3 * 1 };
    const step: disk.Step = .{ .context = &at, .reached = StopAt.reached };
    try testing.expectError(error.Crashed, disk.commitBatch(&pendings, null, null, &batch, &step));
    try repo.expectFile(1, old[1]);
}

test "batch delete crash: recover leaves a file alone when it changed after the commit record" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init(&.{ .modify, .delete });
    defer repo.deinit();
    const batch = repo.batch();
    var pendings: [2]disk.Pending = undefined;
    try repo.prepareAll(&pendings);
    var at: StopAt = .{ .target = 1 + 3 * 1 + 1 };
    const step: disk.Step = .{ .context = &at, .reached = StopAt.reached };
    try testing.expectError(error.Crashed, disk.commitBatch(&pendings, null, null, &batch, &step));

    const edited = "export const b = 'edited after the commit';\n";
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "f1.ts", .data = edited });
    const report = try disk.recover(testing.allocator, testing.io, repo.root);
    try testing.expectEqual(@as(usize, 1), report.skipped);
    const kept = (try repo.content(1)).?;
    defer testing.allocator.free(kept);
    try testing.expectEqualStrings(edited, kept);
}

test "batch delete crash: staging the delete of a symlink is refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init(&.{.modify});
    defer repo.deinit();
    repo.tmp.dir.symLink(testing.io, "f0.ts", "link.ts", .{}) catch return error.SkipZigTest;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}\\link.ts", .{repo.root});
    try testing.expectError(error.ReparsePoint, disk.stageDelete(testing.allocator, testing.io, path, symbol.hashOf(old[0])));
    try repo.expectFile(0, old[0]);
}

fn writeLegacy(repo: *Repo, tag: []const u8, fields: []const u8) !void {
    try repo.tmp.dir.createDirPath(testing.io, shadow.workspace_dir ++ "/journal");
    var name_buf: [64]u8 = undefined;
    const sub = try std.fmt.bufPrint(&name_buf, shadow.workspace_dir ++ "/journal/{s}.json", .{tag});
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = fields });
}

test "batch delete crash: per-file journals written before v2 still roll a committed batch forward" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init(&.{ .modify, .modify });
    defer repo.deinit();
    const batch_tag = "fedcba9876543210";
    const tags = [_][]const u8{ "0123456789abcdef", "1123456789abcdef" };
    for (0..2) |i| {
        var name_buf: [64]u8 = undefined;
        const bak = try std.fmt.bufPrint(&name_buf, "f{d}.ts.emetgate-{s}.bak", .{ i, tags[i] });
        try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = bak, .data = old[i] });
        var file_buf: [16]u8 = undefined;
        try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = try name(&file_buf, i), .data = new[i] });
        const target = try std.fmt.allocPrint(testing.allocator, "{s}\\f{d}.ts", .{ repo.root, i });
        defer testing.allocator.free(target);
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer };
        try js.beginObject();
        try js.objectField("target");
        try js.write(target);
        const base_hex = symbol.formatHash(symbol.hashOf(old[i]));
        const new_hex = symbol.formatHash(symbol.hashOf(new[i]));
        try js.objectField("base_hash");
        try js.write(base_hex[0..]);
        try js.objectField("new_hash");
        try js.write(new_hex[0..]);
        try js.objectField("batch");
        try js.write(batch_tag);
        try js.endObject();
        try writeLegacy(&repo, tags[i], out.written());
    }
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = shadow.workspace_dir ++ "/journal/" ++ batch_tag ++ ".commit", .data = batch_tag });

    const report = try disk.recover(testing.allocator, testing.io, repo.root);
    try testing.expectEqual(@as(usize, 2), report.rolled_forward);
    try testing.expectEqual(@as(usize, 0), report.failed);
    for (0..2) |i| {
        const actual = (try repo.content(i)).?;
        defer testing.allocator.free(actual);
        try testing.expectEqualStrings(new[i], actual);
    }
    try repo.expectNoDebris();
}
