const std = @import("std");
const change_watch = @import("change_watch");

const Samples = struct {
    ns: std.ArrayList(u64) = .empty,

    fn add(self: *Samples, gpa: std.mem.Allocator, value: u64) !void {
        try self.ns.append(gpa, value);
    }

    fn report(self: *Samples, label: []const u8) void {
        std.mem.sort(u64, self.ns.items, {}, std.sort.asc(u64));
        const n = self.ns.items.len;
        const median = self.ns.items[n / 2];
        const p99 = self.ns.items[@min(n - 1, (n * 99) / 100)];
        std.debug.print("{s}\tn={d}\tmedian_us={d:.1}\tp99_us={d:.1}\tmax_us={d:.1}\n", .{ label, n, us(median), us(p99), us(self.ns.items[n - 1]) });
    }

    fn us(ns: u64) f64 {
        return @as(f64, @floatFromInt(ns)) / 1000.0;
    }
};

fn now(io: std.Io) std.Io.Timestamp {
    return std.Io.Timestamp.now(io, .awake);
}

fn since(io: std.Io, start: std.Io.Timestamp) u64 {
    return @intCast(start.durationTo(now(io)).nanoseconds);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.debug.print("usage: change_watch_bench <root> <iterations> [file-list]\n", .{});
        return error.Usage;
    }
    const root = args[1];
    const iterations = try std.fmt.parseInt(usize, args[2], 10);

    const watcher = try change_watch.Watcher.start(gpa, io, root, .{});
    defer watcher.deinit();
    (try watcher.sync(10_000)).deinit(gpa);

    var idle: Samples = .{};
    defer idle.ns.deinit(gpa);
    for (0..iterations) |_| {
        const start = now(io);
        const dirty = try watcher.sync(10_000);
        try idle.add(gpa, since(io, start));
        dirty.deinit(gpa);
    }
    idle.report("sync, nothing changed");

    var root_dir = try std.Io.Dir.cwd().openDir(io, root, .{});
    defer root_dir.close(io);
    var after_write: Samples = .{};
    defer after_write.ns.deinit(gpa);
    var name_buf: [64]u8 = undefined;
    for (0..iterations) |i| {
        const rel = try std.fmt.bufPrint(&name_buf, "bench-{d}.txt", .{i % 16});
        try root_dir.writeFile(io, .{ .sub_path = rel, .data = if (i % 2 == 0) "a" else "bb" });
        const start = now(io);
        const dirty = try watcher.sync(10_000);
        try after_write.add(gpa, since(io, start));
        if (!dirty.contains(rel)) return error.MissedWrite;
        dirty.deinit(gpa);
    }
    after_write.report("sync, one file written before it");
    for (0..16) |i| {
        const rel = try std.fmt.bufPrint(&name_buf, "bench-{d}.txt", .{i});
        root_dir.deleteFile(io, rel) catch {};
    }

    if (args.len < 4) return;
    const listing = try std.Io.Dir.cwd().readFileAlloc(io, args[3], gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(listing);
    var scan: Samples = .{};
    defer scan.ns.deinit(gpa);
    var files: usize = 0;
    for (0..@max(iterations / 20, 5) + 2) |round| {
        files = 0;
        const start = now(io);
        var lines = std.mem.tokenizeAny(u8, listing, "\r\n");
        while (lines.next()) |rel| {
            _ = root_dir.statFile(io, rel, .{}) catch continue;
            files += 1;
        }
        if (round >= 2) try scan.add(gpa, since(io, start));
    }
    std.debug.print("stat scan files={d}\n", .{files});
    scan.report("stat scan of every listed file");
}
