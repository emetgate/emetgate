const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");

const disk = emetgate.disk;
const symbol = emetgate.symbol;

const testing = std.testing;

const base_text = "export const a = 1;\n";
const new_text = "export const a = 2;\n";
const user_text = "export const a = 3; // typed by the user after the crash\n";

const Cut = struct {
    target: usize,
    seen: usize = 0,

    fn reached(context: *anyopaque) bool {
        const self: *Cut = @ptrCast(@alignCast(context));
        self.seen += 1;
        return self.seen == self.target;
    }
};

const Tree = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    file: []u8,
    journal: []u8,

    fn init() !Tree {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = base_text });
        const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        errdefer testing.allocator.free(root);
        const file = try std.fmt.allocPrint(testing.allocator, "{s}\\a.ts", .{root});
        errdefer testing.allocator.free(file);
        return .{ .tmp = tmp, .root = root, .file = file, .journal = try std.fmt.allocPrint(testing.allocator, "{s}\\.emetgate\\journal", .{root}) };
    }

    fn deinit(self: *Tree) void {
        testing.allocator.free(self.journal);
        testing.allocator.free(self.file);
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn read(self: *Tree) !?[]u8 {
        return self.tmp.dir.readFileAlloc(testing.io, "a.ts", testing.allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => null,
            else => |e| return e,
        };
    }

    fn crashAt(self: *Tree, stop: usize) !bool {
        var at: Cut = .{ .target = stop };
        const step: disk.Step = .{ .context = &at, .reached = Cut.reached };
        disk.replaceReporting(testing.allocator, testing.io, self.file, new_text, symbol.hashOf(base_text), null, self.journal, &step) catch |err| switch (err) {
            error.Crashed => return true,
            else => |e| return e,
        };
        return false;
    }

    fn crashBetweenMoves(self: *Tree) !void {
        disk.crash_between_moves = true;
        defer disk.crash_between_moves = false;
        try testing.expectError(error.Crashed, disk.replaceReporting(testing.allocator, testing.io, self.file, new_text, symbol.hashOf(base_text), null, self.journal, null));
        try testing.expect(try self.read() == null);
    }

    fn sidecars(self: *Tree) !usize {
        var count: usize = 0;
        var it = self.tmp.dir.iterate();
        while (try it.next(testing.io)) |entry| {
            if (std.mem.indexOf(u8, entry.name, ".emetgate-") != null) count += 1;
        }
        return count;
    }
};

test "journal base: after a crash at any step recover leaves the old or the new file whole and no file of its own" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var stop: usize = 1;
    var crashes: usize = 0;
    var missing: usize = 0;
    while (true) : (stop += 1) {
        var tree = try Tree.init();
        defer tree.deinit();
        errdefer std.debug.print("cut after step {d}\n", .{stop});
        const crashed = try tree.crashAt(stop);
        if (crashed) {
            crashes += 1;
            if (try tree.read()) |found| testing.allocator.free(found) else missing += 1;
            const report = try disk.recover(testing.allocator, testing.io, tree.root);
            try testing.expectEqual(@as(usize, 0), report.failed);
        }
        const now = (try tree.read()) orelse return error.TargetMissingAfterRecover;
        defer testing.allocator.free(now);
        try testing.expect(std.mem.eql(u8, now, base_text) or std.mem.eql(u8, now, new_text));
        try testing.expectEqual(@as(usize, 0), try tree.sidecars());
        if (!crashed) {
            try testing.expectEqualStrings(new_text, now);
            break;
        }
    }
    try testing.expect(crashes >= 4);
    try testing.expect(missing <= 1);
}

test "journal base: recover does not put the old bytes back over a file the user edited after the crash" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var stop: usize = 1;
    var edited: usize = 0;
    while (true) : (stop += 1) {
        var tree = try Tree.init();
        defer tree.deinit();
        errdefer std.debug.print("cut after step {d}\n", .{stop});
        if (!try tree.crashAt(stop)) break;
        const found = try tree.read();
        defer if (found) |bytes| testing.allocator.free(bytes);
        if (found == null or !std.mem.eql(u8, found.?, new_text)) continue;
        try tree.tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = user_text });
        edited += 1;

        _ = try disk.recover(testing.allocator, testing.io, tree.root);
        const now = (try tree.read()).?;
        defer testing.allocator.free(now);
        try testing.expectEqualStrings(user_text, now);
    }
    try testing.expect(edited >= 1);
}

test "journal base: a crash between the two moves leaves no file at the path, and recover puts the old one back" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.crashBetweenMoves();
    try testing.expectEqual(@as(usize, 2), try tree.sidecars());
    const report = try disk.recover(testing.allocator, testing.io, tree.root);
    try testing.expectEqual(@as(usize, 1), report.restored);
    const now = (try tree.read()).?;
    defer testing.allocator.free(now);
    try testing.expectEqualStrings(base_text, now);
    try testing.expectEqual(@as(usize, 0), try tree.sidecars());
}

test "journal base: recover does not put the old bytes back over a file the user created where the crash left none" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.crashBetweenMoves();
    try tree.tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = user_text });

    const report = try disk.recover(testing.allocator, testing.io, tree.root);
    try testing.expectEqual(@as(usize, 0), report.restored);
    try testing.expectEqual(@as(usize, 1), report.skipped);
    const now = (try tree.read()).?;
    defer testing.allocator.free(now);
    try testing.expectEqualStrings(user_text, now);
}

test "journal base: a file created at the path between the two moves is kept, the write is refused by name and the old bytes are named as left over" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    var writer: Creator = .{ .tree = &tree };
    disk.between_moves = .{ .context = &writer, .run = Creator.run };
    defer disk.between_moves = null;
    var leftover: disk.Leftover = .{};
    try testing.expectError(error.Conflict, disk.replaceReporting(testing.allocator, testing.io, tree.file, new_text, symbol.hashOf(base_text), &leftover, tree.journal, null));
    const now = (try tree.read()).?;
    defer testing.allocator.free(now);
    try testing.expectEqualStrings(user_text, now);
    try testing.expect(std.mem.endsWith(u8, leftover.path().?, ".bak"));
    const kept = try std.Io.Dir.cwd().readFileAlloc(testing.io, leftover.path().?, testing.allocator, .unlimited);
    defer testing.allocator.free(kept);
    try testing.expectEqualStrings(base_text, kept);
}

const Creator = struct {
    tree: *Tree,

    fn run(context: *anyopaque) void {
        const self: *Creator = @ptrCast(@alignCast(context));
        self.tree.tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = user_text }) catch {};
    }
};

const Mover = struct {
    tree: *Tree,
    at: usize,
    seen: usize = 0,
    refused: bool = false,

    fn reached(context: *anyopaque) bool {
        const self: *Mover = @ptrCast(@alignCast(context));
        self.seen += 1;
        if (self.seen != self.at) return false;
        self.tree.tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts.saving", .data = user_text }) catch return false;
        self.tree.tmp.dir.rename("a.ts.saving", self.tree.tmp.dir, "a.ts", testing.io) catch {
            self.refused = true;
        };
        return false;
    }
};

test "journal base: a file renamed over the target between the check and the write is refused, and the write lands whole" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    var mover: Mover = .{ .tree = &tree, .at = 3 };
    const step: disk.Step = .{ .context = &mover, .reached = Mover.reached };
    try disk.replaceReporting(testing.allocator, testing.io, tree.file, new_text, symbol.hashOf(base_text), null, tree.journal, &step);
    try testing.expectEqual(@as(usize, 3), @min(mover.seen, 3));
    try testing.expect(mover.refused);
    const now = (try tree.read()).?;
    defer testing.allocator.free(now);
    try testing.expectEqualStrings(new_text, now);
}
