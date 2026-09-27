const std = @import("std");
const builtin = @import("builtin");
const disk = @import("emetgate").disk;
const durability_log = @import("emetgate").durability_log;
const symbol = @import("emetgate").symbol;
const fixture = @import("ts_fixture.zig");

const testing = std.testing;
const gpa = testing.allocator;

const a_old = "export const a = 1;\n";
const a_new = "export const a = 2;\n";
const b_old = "export const b = 1;\n";
const b_new = "export const b = 2;\n";
const c_new = "export const c = 3;\n";

const Shape = enum { modify_two, create_and_modify };

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
    repo: fixture.TsRepo,
    shape: Shape,
    a: []u8,
    b: []u8,
    c: []u8,
    journal: []u8,
    log: durability_log.Log,

    fn init(shape: Shape) !*Setup {
        const self = try gpa.create(Setup);
        errdefer gpa.destroy(self);
        var repo = try fixture.TsRepo.init(&.{ .{ .rel = "src/a.ts", .text = a_old }, .{ .rel = "src/b.ts", .text = b_old } });
        errdefer repo.deinit();
        self.* = .{
            .shape = shape,
            .a = try repo.abs(gpa, "src/a.ts"),
            .b = try repo.abs(gpa, "src/b.ts"),
            .c = try repo.abs(gpa, "src/c.ts"),
            .journal = try repo.abs(gpa, ".emetgate/journal"),
            .log = .init(gpa, testing.io),
            .repo = repo,
        };
        durability_log.active = &self.log;
        return self;
    }

    fn deinit(self: *Setup) void {
        durability_log.active = null;
        self.log.deinit();
        for ([_][]u8{ self.a, self.b, self.c, self.journal }) |p| gpa.free(p);
        self.repo.deinit();
        gpa.destroy(self);
    }

    fn run(self: *Setup, step: ?*const disk.Step) !void {
        var pendings: [2]disk.Pending = undefined;
        switch (self.shape) {
            .modify_two => {
                pendings[0] = try disk.prepare(gpa, testing.io, self.a, a_new, symbol.fileHash(a_old));
                pendings[1] = try disk.prepare(gpa, testing.io, self.b, b_new, symbol.fileHash(b_old));
            },
            .create_and_modify => {
                pendings[0] = try disk.stageCreate(gpa, testing.io, self.c, c_new);
                pendings[1] = try disk.prepare(gpa, testing.io, self.a, a_new, symbol.fileHash(a_old));
            },
        }
        var batch = disk.Batch.init(gpa, testing.io, self.journal);
        batch.root = self.repo.root_abs;
        try disk.commitBatch(&pendings, null, null, &batch, step);
    }

    fn recover(self: *Setup) !void {
        const report = try disk.recover(gpa, testing.io, self.repo.root_abs);
        try testing.expectEqual(@as(usize, 0), report.failed);
    }

    fn has(self: *Setup, rel: []const u8, expected: ?[]const u8) !bool {
        const want = expected orelse return !self.repo.exists(rel);
        const text = self.repo.read(rel) catch return false;
        defer gpa.free(text);
        return std.mem.eql(u8, text, want);
    }

    fn state(self: *Setup) !enum { old, new } {
        const old_ok, const new_ok = switch (self.shape) {
            .modify_two => .{
                try self.has("src/a.ts", a_old) and try self.has("src/b.ts", b_old),
                try self.has("src/a.ts", a_new) and try self.has("src/b.ts", b_new),
            },
            .create_and_modify => .{
                try self.has("src/c.ts", null) and try self.has("src/a.ts", a_old),
                try self.has("src/c.ts", c_new) and try self.has("src/a.ts", a_new),
            },
        };
        if (old_ok) return .old;
        if (new_ok) return .new;
        std.debug.print("a.ts new {}, b.ts new {}, c.ts exists {}\n", .{ try self.has("src/a.ts", a_new), try self.has("src/b.ts", b_new), self.repo.exists("src/c.ts") });
        return error.MixedBatch;
    }

    fn noDebris(self: *Setup) !void {
        var dir = try std.Io.Dir.openDirAbsolute(testing.io, self.repo.root_abs, .{ .iterate = true });
        defer dir.close(testing.io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(testing.io)) |entry| {
            const in_journal = std.mem.indexOf(u8, entry.path, "journal") != null and entry.kind == .file;
            if (std.mem.indexOf(u8, entry.basename, ".emetgate-") != null or in_journal) {
                std.debug.print("debris: {s}\n", .{entry.path});
                return error.Debris;
            }
        }
    }
};

fn isBackupCreation(op: durability_log.Op) bool {
    return op.kind == .created and op.endsWith(".bak");
}

fn isJournalRemoval(op: durability_log.Op) bool {
    return op.kind == .removed and op.endsWith(".json");
}

fn outsideJournal(op: durability_log.Op) bool {
    return std.mem.indexOf(u8, op.path, "\\.emetgate\\journal") == null;
}

fn anything(op: durability_log.Op) bool {
    _ = op;
    return true;
}

test "dir flush bak: a backup whose directory entry was lost with the swapped target still recovers to all old" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const setup = try Setup.init(.modify_two);
    defer setup.deinit();
    disk.resetRenameCount();
    disk.crash_after_rename = 1;
    defer disk.crash_after_rename = null;
    try testing.expectError(error.Crashed, setup.run(null));
    setup.log.powerLoss(isBackupCreation);
    try setup.recover();
    try testing.expectEqual(.old, try setup.state());
    try setup.noDebris();
}

test "dir flush fin: a power loss after a finished batch does not bring a deleted backup back" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const setup = try Setup.init(.modify_two);
    defer setup.deinit();
    try setup.run(null);
    setup.log.powerLoss(anything);
    try setup.recover();
    try testing.expectEqual(.new, try setup.state());
    try setup.noDebris();
}

fn flushCount(shape: Shape, stop: ?usize, in_recovery: bool) !usize {
    const dry = try Setup.init(shape);
    defer dry.deinit();
    var at: StopAt = .{ .target = stop orelse std.math.maxInt(usize) };
    const step: disk.Step = .{ .context = &at, .reached = StopAt.reached };
    if (stop == null) try dry.run(null) else try testing.expectError(error.Crashed, dry.run(&step));
    if (!in_recovery) return dry.log.flushes;
    dry.log.flushes = 0;
    try dry.recover();
    return dry.log.flushes;
}


const after_commit_record = 8;



test "dir flush log: a power loss undoes an unflushed creation and keeps one whose directory was flushed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(dir);
    var log: durability_log.Log = .init(gpa, testing.io);
    defer log.deinit();
    durability_log.active = &log;
    defer durability_log.active = null;

    const kept = try std.fmt.allocPrint(gpa, "{s}\\kept.txt", .{dir});
    defer gpa.free(kept);
    const lost = try std.fmt.allocPrint(gpa, "{s}\\lost.txt", .{dir});
    defer gpa.free(lost);
    try disk.writeDurably(testing.io, kept, "kept\n");
    try testing.expect(durability_log.flushing(dir));
    try disk.writeDurably(testing.io, lost, "lost\n");
    try testing.expectEqual(@as(usize, 1), log.unflushed().len);
    log.powerLoss(anything);
    try tmp.dir.access(testing.io, "kept.txt", .{});
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "lost.txt", .{}));
}
