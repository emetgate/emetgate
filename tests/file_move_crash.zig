const std = @import("std");
const builtin = @import("builtin");
const disk = @import("emetgate").disk;
const symbol = @import("emetgate").symbol;
const fixture = @import("ts_fixture.zig");

const testing = std.testing;
const TsRepo = fixture.TsRepo;

const a_old = "export function a(): number {\n  return 1;\n}\n";
const a_new = "export function a(): number {\n  return 1;\n}\n// moved\n";
const u1_old = "import { a } from \"./a\";\nexport const one = a();\n";
const u1_new = "import { a } from \"./lib/deep/a\";\nexport const one = a();\n";
const u2_old = "import { a } from \"./a\";\nexport const two = a() + 1;\n";
const u2_new = "import { a } from \"./lib/deep/a\";\nexport const two = a() + 1;\n";

const StopAt = struct {
    target: usize,
    seen: usize = 0,

    fn reached(context: *anyopaque) bool {
        const self: *StopAt = @ptrCast(@alignCast(context));
        self.seen += 1;
        return self.seen == self.target;
    }
};

const Setup = struct {
    repo: TsRepo,
    source: []u8,
    target: []u8,
    u1: []u8,
    u2: []u8,
    lib: []u8,
    deep: []u8,
    journal: []u8,

    fn init() !Setup {
        var repo = try TsRepo.init(&.{ .{ .rel = "src/a.ts", .text = a_old }, .{ .rel = "src/u1.ts", .text = u1_old }, .{ .rel = "src/u2.ts", .text = u2_old } });
        errdefer repo.deinit();
        return .{
            .source = try repo.abs(testing.allocator, "src/a.ts"),
            .target = try repo.abs(testing.allocator, "src/lib/deep/a.ts"),
            .u1 = try repo.abs(testing.allocator, "src/u1.ts"),
            .u2 = try repo.abs(testing.allocator, "src/u2.ts"),
            .lib = try repo.abs(testing.allocator, "src/lib"),
            .deep = try repo.abs(testing.allocator, "src/lib/deep"),
            .journal = try repo.abs(testing.allocator, ".emetgate/journal"),
            .repo = repo,
        };
    }

    fn deinit(self: *Setup) void {
        for ([_][]u8{ self.source, self.target, self.u1, self.u2, self.lib, self.deep, self.journal }) |p| testing.allocator.free(p);
        self.repo.deinit();
    }

    fn run(self: *Setup, step: ?*const disk.Step) !void {
        var pendings: [3]disk.Pending = undefined;
        pendings[0] = try disk.stageRename(testing.allocator, testing.io, self.source, self.target, a_new, symbol.fileHash(a_old));
        pendings[1] = try disk.prepare(testing.allocator, testing.io, self.u1, u1_new, symbol.fileHash(u1_old));
        pendings[2] = try disk.prepare(testing.allocator, testing.io, self.u2, u2_new, symbol.fileHash(u2_old));
        var batch = disk.Batch.init(testing.allocator, testing.io, self.journal);
        batch.root = self.repo.root_abs;
        const dirs = [_][]const u8{ self.lib, self.deep };
        batch.created_dirs = &dirs;
        try disk.commitBatch(&pendings, null, null, &batch, step);
    }

    fn tracked(self: *Setup, rel: []const u8) !bool {
        const result = try std.process.run(testing.allocator, testing.io, .{ .argv = &.{ "git", "ls-files", "--", rel }, .cwd = .{ .path = self.repo.root_abs } });
        defer testing.allocator.free(result.stdout);
        defer testing.allocator.free(result.stderr);
        return std.mem.trim(u8, result.stdout, " \r\n").len != 0;
    }

    fn file(self: *Setup, rel: []const u8, expected: []const u8) !bool {
        const text = self.repo.read(rel) catch return false;
        defer testing.allocator.free(text);
        return std.mem.eql(u8, text, expected);
    }

    fn state(self: *Setup) !enum { old, new } {
        if (try self.file("src/a.ts", a_old) and !self.repo.exists("src/lib") and try self.file("src/u1.ts", u1_old) and try self.file("src/u2.ts", u2_old)) {
            if (!try self.tracked("src/a.ts") or try self.tracked("src/lib/deep/a.ts")) return error.IndexWrong;
            return .old;
        }
        if (!self.repo.exists("src/a.ts") and try self.file("src/lib/deep/a.ts", a_new) and try self.file("src/u1.ts", u1_new) and try self.file("src/u2.ts", u2_new)) {
            if (try self.tracked("src/a.ts") or !try self.tracked("src/lib/deep/a.ts")) return error.IndexWrong;
            return .new;
        }
        std.debug.print("a.ts exists {}, target exists {}, lib exists {}\n", .{ self.repo.exists("src/a.ts"), self.repo.exists("src/lib/deep/a.ts"), self.repo.exists("src/lib") });
        return error.MixedBatch;
    }

    fn noDebris(self: *Setup) !void {
        if (std.Io.Dir.openDirAbsolute(testing.io, self.journal, .{ .iterate = true })) |opened| {
            var journal_dir = opened;
            defer journal_dir.close(testing.io);
            var entries = journal_dir.iterate();
            if (try entries.next(testing.io)) |entry| {
                std.debug.print("journal debris: {s}\n", .{entry.name});
                return error.Debris;
            }
        } else |_| {}
        var dir = try std.Io.Dir.openDirAbsolute(testing.io, self.repo.root_abs, .{ .iterate = true });
        defer dir.close(testing.io);
        var walker = try dir.walk(testing.allocator);
        defer walker.deinit();
        while (try walker.next(testing.io)) |entry| {
            if (std.mem.indexOf(u8, entry.basename, ".emetgate-") != null) {
                std.debug.print("debris: {s}\n", .{entry.path});
                return error.Debris;
            }
        }
    }
};

fn recoverTwice(setup: *Setup, crash_in_recovery: bool) !void {
    if (crash_in_recovery) {
        disk.crash_in_recovery = true;
        defer disk.crash_in_recovery = false;
        if (disk.recover(testing.allocator, testing.io, setup.repo.root_abs)) |_| {} else |err| try testing.expectEqual(error.Crashed, err);
    }
    const report = try disk.recover(testing.allocator, testing.io, setup.repo.root_abs);
    try testing.expectEqual(@as(usize, 0), report.failed);
    try testing.expectEqual(@as(usize, 0), report.not_indexed);
}

test "file move crash: a move into two new directories with two users cut after every step recovers to all old or all new" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    for ([_]bool{ false, true }) |crash_in_recovery| {
        var seen_new = false;
        var crashes: usize = 0;
        var stop: usize = 1;
        while (true) : (stop += 1) {
            errdefer std.debug.print("crash after step {d}, crash in recovery {}\n", .{ stop, crash_in_recovery });
            var setup = try Setup.init();
            defer setup.deinit();
            var at: StopAt = .{ .target = stop };
            const step: disk.Step = .{ .context = &at, .reached = StopAt.reached };
            if (setup.run(&step)) |_| {
                try testing.expectEqual(.new, try setup.state());
                try setup.noDebris();
                break;
            } else |err| try testing.expectEqual(error.Crashed, err);
            crashes += 1;
            try recoverTwice(&setup, crash_in_recovery);
            const now = try setup.state();
            try setup.noDebris();
            if (now == .new) seen_new = true;
            if (seen_new) try testing.expectEqual(.new, now);
        }
        try testing.expect(crashes >= 8);
        try testing.expect(seen_new);
    }
}

test "file move crash: a rename whose directory entry was not made durable before the crash recovers to all old" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    for ([_]usize{ 1, 2, 3 }) |nth| {
        for ([_]bool{ false, true }) |lost| {
            errdefer std.debug.print("rename {d}, entry lost {}\n", .{ nth, lost });
            var setup = try Setup.init();
            defer setup.deinit();
            disk.resetRenameCount();
            disk.crash_after_rename = nth;
            defer disk.crash_after_rename = null;
            try testing.expectError(error.Crashed, setup.run(null));
            if (lost) {
                const placed = switch (nth) {
                    1 => setup.target,
                    2 => setup.u1,
                    else => setup.u2,
                };
                if (nth == 1) {
                    const orphan = try std.fmt.allocPrint(testing.allocator, "{s}.emetgate-0000000000000000.tmp", .{placed});
                    defer testing.allocator.free(orphan);
                    try std.Io.Dir.renameAbsolute(placed, orphan, testing.io);
                }
            }
            try recoverTwice(&setup, false);
            try testing.expectEqual(.old, try setup.state());
            try setup.noDebris();
        }
    }
}

test "file move crash: a target path longer than MAX_PATH is created, placed, verified and indexed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var setup = try Setup.init();
    defer setup.deinit();
    const segment = "d" ** 60;
    var dirs: [4][]u8 = undefined;
    var built: usize = 0;
    defer for (dirs[0..built]) |d| testing.allocator.free(d);
    var parent: []const u8 = setup.lib;
    const lib_copy = try testing.allocator.dupe(u8, setup.lib);
    dirs[0] = lib_copy;
    built = 1;
    parent = lib_copy;
    while (built < dirs.len) : (built += 1) {
        dirs[built] = try std.fmt.allocPrint(testing.allocator, "{s}\\{s}", .{ parent, segment });
        parent = dirs[built];
    }
    const target = try std.fmt.allocPrint(testing.allocator, "{s}\\moved-{s}.ts", .{ parent, segment });
    defer testing.allocator.free(target);
    try testing.expect(target.len > 260);
    var pendings = [1]disk.Pending{try disk.stageRename(testing.allocator, testing.io, setup.source, target, a_new, symbol.fileHash(a_old))};
    var batch = disk.Batch.init(testing.allocator, testing.io, setup.journal);
    batch.root = setup.repo.root_abs;
    const created: []const []const u8 = @ptrCast(dirs[0..]);
    batch.created_dirs = created;
    try disk.commitBatch(&pendings, null, null, &batch, null);
    try testing.expect(!setup.repo.exists("src/a.ts"));
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, target, testing.allocator, .unlimited);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(a_new, text);
    try testing.expect(!try setup.tracked("src/a.ts"));
}

const Intruder = struct {
    setup: *Setup,
    placed: bool = false,

    fn reached(context: *anyopaque) bool {
        const self: *Intruder = @ptrCast(@alignCast(context));
        if (self.placed or !self.setup.repo.exists("src/lib/deep") or self.setup.repo.exists("src/lib/deep/a.ts")) return false;
        self.setup.repo.write("src/lib/deep/a.ts", "intruder\n") catch return false;
        self.placed = true;
        return false;
    }
};

test "file move crash: a file another process puts at the target before the placement is never replaced" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var setup = try Setup.init();
    defer setup.deinit();
    var intruder: Intruder = .{ .setup = &setup };
    const step: disk.Step = .{ .context = &intruder, .reached = Intruder.reached };
    try testing.expectError(error.Conflict, setup.run(&step));
    try testing.expect(intruder.placed);
    try testing.expect(try setup.file("src/lib/deep/a.ts", "intruder\n"));
    try testing.expect(try setup.file("src/a.ts", a_old));
    try testing.expect(try setup.file("src/u1.ts", u1_old));
}

test "file move crash: the disk layer refuses a rename that only changes letter case" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var setup = try Setup.init();
    defer setup.deinit();
    const upper = try setup.repo.abs(testing.allocator, "src/A.ts");
    defer testing.allocator.free(upper);
    try testing.expectError(error.CaseOnlyRename, disk.stageRename(testing.allocator, testing.io, setup.source, upper, a_old, symbol.fileHash(a_old)));
}
