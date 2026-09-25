const std = @import("std");
const builtin = @import("builtin");
const symbol = @import("emetgate").symbol;
const disk = @import("emetgate").disk;
const shadow = @import("emetgate").shadow;

const testing = std.testing;
const max_files = 3;

const StopAt = struct {
    target: usize,
    seen: usize = 0,

    fn reached(context: *anyopaque) bool {
        const self: *StopAt = @ptrCast(@alignCast(context));
        self.seen += 1;
        return self.seen == self.target;
    }
};

const Repo = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    journal_dir: []u8,
    files: usize,

    fn init(files: usize) !Repo {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        for (0..files) |i| {
            var name_buf: [16]u8 = undefined;
            try tmp.dir.writeFile(testing.io, .{ .sub_path = try name(&name_buf, i), .data = old[i] });
        }
        const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        errdefer testing.allocator.free(root);
        const journal_dir = try std.fmt.allocPrint(testing.allocator, "{s}\\{s}\\journal", .{ root, shadow.workspace_dir });
        return .{ .tmp = tmp, .root = root, .journal_dir = journal_dir, .files = files };
    }

    fn deinit(self: *Repo) void {
        testing.allocator.free(self.journal_dir);
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn path(self: *const Repo, buf: []u8, i: usize) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}\\f{d}.ts", .{ self.root, i });
    }

    fn prepareAll(self: *const Repo, pendings: []disk.Pending) !void {
        for (pendings, 0..) |*p, i| {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            p.* = try disk.prepare(testing.allocator, testing.io, try self.path(&buf, i), new[i], symbol.hashOf(old[i]));
        }
    }

    fn content(self: *const Repo, i: usize) ![]u8 {
        var name_buf: [16]u8 = undefined;
        return self.tmp.dir.readFileAlloc(testing.io, try name(&name_buf, i), testing.allocator, .unlimited);
    }

    fn expectAll(self: *const Repo, expected: []const []const u8) !void {
        for (0..self.files) |i| {
            const actual = try self.content(i);
            defer testing.allocator.free(actual);
            try testing.expectEqualStrings(expected[i], actual);
        }
    }

    fn expectAllOldOrAllNew(self: *const Repo) !void {
        var olds: usize = 0;
        var news: usize = 0;
        for (0..self.files) |i| {
            const actual = try self.content(i);
            defer testing.allocator.free(actual);
            if (std.mem.eql(u8, actual, old[i])) olds += 1;
            if (std.mem.eql(u8, actual, new[i])) news += 1;
        }
        if (olds != self.files and news != self.files) {
            std.debug.print("mixed batch: {d} old, {d} new of {d}\n", .{ olds, news, self.files });
            return error.MixedBatch;
        }
    }

    fn expectNoDebris(self: *const Repo) !void {
        var it = self.tmp.dir.iterate();
        while (try it.next(testing.io)) |entry| {
            if (entry.kind == .directory and std.mem.eql(u8, entry.name, shadow.workspace_dir)) continue;
            errdefer std.debug.print("unexpected entry: {s}\n", .{entry.name});
            if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, "f") or !std.mem.endsWith(u8, entry.name, ".ts") or entry.name.len != "f0.ts".len) return error.Debris;
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

    fn recover(self: *const Repo) !disk.RecoverReport {
        return disk.recover(testing.allocator, testing.io, self.root);
    }
};

fn name(buf: []u8, i: usize) ![]const u8 {
    return std.fmt.bufPrint(buf, "f{d}.ts", .{i});
}

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

fn crashAtEveryStep(files: usize) !void {
    const swap_steps = 1 + 3 * files;
    const steps = swap_steps + 1 + files + 1;
    var stop: usize = 1;
    while (true) : (stop += 1) {
        var repo = try Repo.init(files);
        defer repo.deinit();
        const batch = disk.Batch.init(testing.allocator, testing.io, repo.journal_dir);
        var pendings: [max_files]disk.Pending = undefined;
        try repo.prepareAll(pendings[0..files]);

        var at: StopAt = .{ .target = stop };
        const step: disk.Step = .{ .context = &at, .reached = StopAt.reached };
        disk.commitBatch(pendings[0..files], null, null, &batch, &step) catch |err| {
            errdefer std.debug.print("crash after step {d} of {d}\n", .{ stop, steps });
            try testing.expectEqual(error.Crashed, err);
            const report = try repo.recover();
            try testing.expectEqual(@as(usize, 0), report.failed);
            try repo.expectAllOldOrAllNew();
            try repo.expectAll(if (stop <= swap_steps) old[0..files] else new[0..files]);
            try repo.expectNoDebris();
            continue;
        };
        try testing.expectEqual(steps + 1, stop);
        try repo.expectAll(new[0..files]);
        try repo.expectNoDebris();
        break;
    }
}

test "batch crash: a crash after any step of a two-file commit recovers to all old or all new" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try crashAtEveryStep(2);
}

test "batch crash: a crash after any step of a three-file commit recovers to all old or all new" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try crashAtEveryStep(3);
}

test "batch crash: a crash while files are still being prepared recovers to all old" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    for (1..max_files + 1) |prepared| {
        var repo = try Repo.init(max_files);
        defer repo.deinit();
        var pendings: [max_files]disk.Pending = undefined;
        try repo.prepareAll(pendings[0..prepared]);
        for (pendings[0..prepared]) |*p| p.abandon();

        const report = try repo.recover();
        try testing.expectEqual(@as(usize, 0), report.failed);
        try repo.expectAll(old[0..max_files]);
        try repo.expectNoDebris();
    }
}

test "batch crash: recover never rolls forward a file whose content is not the journaled new hash" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init(2);
    defer repo.deinit();
    const batch = disk.Batch.init(testing.allocator, testing.io, repo.journal_dir);
    var pendings: [2]disk.Pending = undefined;
    try repo.prepareAll(&pendings);

    var at: StopAt = .{ .target = 1 + 3 * 2 + 1 };
    const step: disk.Step = .{ .context = &at, .reached = StopAt.reached };
    try testing.expectError(error.Crashed, disk.commitBatch(&pendings, null, null, &batch, &step));

    const external = "export const a = 42;\n";
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "f0.ts", .data = external });

    const report = try repo.recover();
    try testing.expectEqual(@as(usize, 1), report.failed);
    try testing.expectEqual(@as(usize, 1), report.rolled_forward);
    try repo.expectAll(&.{ external, new[1] });

    var backups: usize = 0;
    var it = repo.tmp.dir.iterate();
    while (try it.next(testing.io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, "f0.ts.emetgate-") and std.mem.endsWith(u8, entry.name, ".bak")) {
            const kept = try repo.tmp.dir.readFileAlloc(testing.io, entry.name, testing.allocator, .unlimited);
            defer testing.allocator.free(kept);
            try testing.expectEqualStrings(old[0], kept);
            backups += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), backups);
}
