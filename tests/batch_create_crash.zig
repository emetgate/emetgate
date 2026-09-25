const std = @import("std");
const builtin = @import("builtin");
const git_fixture = @import("git_fixture.zig");
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

pub fn tracked(root: []const u8, rel: []const u8) !bool {
    const result = try std.process.run(testing.allocator, testing.io, .{ .argv = &.{ "git", "ls-files", "--", rel }, .cwd = .{ .path = root } });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    return std.mem.trim(u8, result.stdout, " \r\n").len != 0;
}

const Repo = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    journal_dir: []u8,
    creates: []const bool,

    fn init(creates: []const bool) !Repo {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        for (creates, 0..) |is_create, i| {
            if (is_create) continue;
            var name_buf: [16]u8 = undefined;
            try tmp.dir.writeFile(testing.io, .{ .sub_path = try name(&name_buf, i), .data = old[i] });
        }
        const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        errdefer testing.allocator.free(root);
        try git_fixture.initRepo(root);
        const journal_dir = try std.fmt.allocPrint(testing.allocator, "{s}\\{s}\\journal", .{ root, shadow.workspace_dir });
        return .{ .tmp = tmp, .root = root, .journal_dir = journal_dir, .creates = creates };
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
            p.* = if (self.creates[i])
                try disk.stageCreate(testing.allocator, testing.io, path, new[i])
            else
                try disk.prepare(testing.allocator, testing.io, path, new[i], symbol.hashOf(old[i]));
        }
    }

    fn content(self: *const Repo, i: usize) !?[]u8 {
        var name_buf: [16]u8 = undefined;
        return self.tmp.dir.readFileAlloc(testing.io, try name(&name_buf, i), testing.allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => null,
            else => |e| e,
        };
    }

    fn expectOld(self: *const Repo) !void {
        for (self.creates, 0..) |is_create, i| {
            const actual = try self.content(i);
            defer if (actual) |a| testing.allocator.free(a);
            if (is_create) {
                if (actual != null) return error.CreatedFileLeft;
            } else {
                try testing.expectEqualStrings(old[i], actual orelse return error.FileMissing);
            }
        }
    }

    fn expectNew(self: *const Repo) !void {
        for (self.creates, 0..) |is_create, i| {
            const actual = try self.content(i);
            defer if (actual) |a| testing.allocator.free(a);
            try testing.expectEqualStrings(new[i], actual orelse return error.FileMissing);
            if (is_create) {
                var name_buf: [16]u8 = undefined;
                if (!try tracked(self.root, try name(&name_buf, i))) return error.CreatedFileNotIndexed;
            }
        }
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

fn name(buf: []u8, i: usize) ![]const u8 {
    return std.fmt.bufPrint(buf, "f{d}.ts", .{i});
}

fn crashAtEveryStep(creates: []const bool) !void {
    var create_count: usize = 0;
    for (creates) |c| create_count += @intFromBool(c);
    const modify_count = creates.len - create_count;
    const swap_steps = 1 + 3 * creates.len;
    const steps = swap_steps + 1 + modify_count + 1 + 1;
    var stop: usize = 1;
    while (true) : (stop += 1) {
        var repo = try Repo.init(creates);
        defer repo.deinit();
        const batch = repo.batch();
        var pendings: [max_files]disk.Pending = undefined;
        try repo.prepareAll(pendings[0..creates.len]);

        var at: StopAt = .{ .target = stop };
        const step: disk.Step = .{ .context = &at, .reached = StopAt.reached };
        disk.commitBatch(pendings[0..creates.len], null, null, &batch, &step) catch |err| {
            errdefer std.debug.print("crash after step {d} of {d}\n", .{ stop, steps });
            try testing.expectEqual(error.Crashed, err);
            const report = try disk.recover(testing.allocator, testing.io, repo.root);
            try testing.expectEqual(@as(usize, 0), report.failed);
            try testing.expectEqual(@as(usize, 0), report.not_indexed);
            if (stop <= swap_steps) try repo.expectOld() else try repo.expectNew();
            try repo.expectNoDebris();
            continue;
        };
        try testing.expectEqual(steps + 1, stop);
        try repo.expectNew();
        try repo.expectNoDebris();
        break;
    }
}

test "batch create crash: a crash after any step of a modify plus create commit recovers to all old or all new" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try crashAtEveryStep(&.{ false, true });
}

test "batch create crash: a crash after any step of a three-file commit with two creates recovers to all old or all new" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try crashAtEveryStep(&.{ true, false, true });
}

test "batch create crash: staging a create over an existing file is refused before anything is written" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init(&.{false});
    defer repo.deinit();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}\\f0.ts", .{repo.root});
    try testing.expectError(error.FileExists, disk.stageCreate(testing.allocator, testing.io, path, new[0]));
    try repo.expectOld();
    try repo.expectNoDebris();
}

const ExternalSave = struct {
    repo: *Repo,
    target: usize,
    seen: usize = 0,

    fn reached(context: *anyopaque) bool {
        const self: *ExternalSave = @ptrCast(@alignCast(context));
        self.seen += 1;
        if (self.seen == self.target) self.repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "f1.ts", .data = external }) catch {};
        return false;
    }
};

const external = "export const saved = 'by another tool';\n";

test "batch create crash: a file that appears at a create target before commit is never overwritten and the batch rolls back" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init(&.{ false, true });
    defer repo.deinit();
    const batch = repo.batch();
    var pendings: [2]disk.Pending = undefined;
    try repo.prepareAll(&pendings);

    var save: ExternalSave = .{ .repo = &repo, .target = 6 };
    const step: disk.Step = .{ .context = &save, .reached = ExternalSave.reached };
    try testing.expectError(error.Conflict, disk.commitBatch(&pendings, null, null, &batch, &step));

    const f0 = (try repo.content(0)).?;
    defer testing.allocator.free(f0);
    try testing.expectEqualStrings(old[0], f0);
    const f1 = (try repo.content(1)).?;
    defer testing.allocator.free(f1);
    try testing.expectEqualStrings(external, f1);
    try repo.expectNoDebris();
}

test "batch create crash: recover leaves a create target alone when its content is not the journaled new hash" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init(&.{ false, true });
    defer repo.deinit();
    const batch = repo.batch();
    var pendings: [2]disk.Pending = undefined;
    try repo.prepareAll(&pendings);

    var at: StopAt = .{ .target = 7 };
    const step: disk.Step = .{ .context = &at, .reached = StopAt.reached };
    try testing.expectError(error.Crashed, disk.commitBatch(&pendings, null, null, &batch, &step));
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "f1.ts", .data = external });

    const report = try disk.recover(testing.allocator, testing.io, repo.root);
    try testing.expectEqual(@as(usize, 1), report.skipped);
    const f1 = (try repo.content(1)).?;
    defer testing.allocator.free(f1);
    try testing.expectEqualStrings(external, f1);
}
