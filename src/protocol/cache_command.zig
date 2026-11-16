const std = @import("std");
const builtin = @import("builtin");
const cache_gc = @import("../platform/cache_gc.zig");
const cache_lease = @import("../platform/cache_lease.zig");
const shadow_root = @import("../platform/shadow_root.zig");
const shadow = @import("../platform/shadow.zig");
const install_probe = @import("../platform/install_probe.zig");
const low_run = @import("../platform/low_run.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const day: i96 = std.time.ns_per_day;

pub const default_older_than_days: u32 = 14;

pub const usage =
    \\       emetgate cache size [--json]
    \\       emetgate cache prune [--older-than <days>] [--max-mb <n>] [--dry-run]
    \\       emetgate cache prune --all [--dry-run]
    \\
;

pub const shared_folders = [_][]const u8{ low_run.cache_family, low_run.temp_family };

pub const Prune = struct {
    older_than_days: u32 = default_older_than_days,
    age_set: bool = false,
    max_mb: ?u64 = null,
    all: bool = false,
    dry_run: bool = false,

    pub fn policy(self: Prune) cache_gc.Policy {
        return .{
            .max_age_days = if (self.all) 0 else self.older_than_days,
            .max_mb = self.max_mb orelse std.math.maxInt(u64),
            .dry_run = self.dry_run,
        };
    }
};

pub const Options = union(enum) {
    size: struct { json: bool = false },
    prune: Prune,
};

pub fn parse(args: []const [:0]const u8) ?Options {
    if (args.len == 0) return null;
    const verb: []const u8 = args[0];
    if (std.mem.eql(u8, verb, "size")) {
        if (args.len == 1) return .{ .size = .{} };
        if (args.len == 2 and std.mem.eql(u8, args[1], "--json")) return .{ .size = .{ .json = true } };
        return null;
    }
    if (!std.mem.eql(u8, verb, "prune")) return null;
    var prune: Prune = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.eql(u8, arg, "--dry-run")) {
            if (prune.dry_run) return null;
            prune.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--all")) {
            if (prune.all or prune.age_set or prune.max_mb != null) return null;
            prune.all = true;
        } else if (std.mem.eql(u8, arg, "--max-mb")) {
            if (prune.all or prune.max_mb != null or i + 1 >= args.len) return null;
            i += 1;
            const mb = std.fmt.parseInt(u64, @as([]const u8, args[i]), 10) catch return null;
            if (mb == 0) return null;
            prune.max_mb = mb;
        } else if (std.mem.eql(u8, arg, "--older-than")) {
            if (prune.all or prune.age_set or i + 1 >= args.len) return null;
            i += 1;
            const days = std.fmt.parseInt(u32, @as([]const u8, args[i]), 10) catch return null;
            if (days == 0) return null;
            prune.older_than_days = days;
            prune.age_set = true;
        } else return null;
    }
    return .{ .prune = prune };
}

pub fn run(gpa: Allocator, io: std.Io, options: Options, out: *Writer) !u8 {
    const data = try cache_lease.defaultDataDir(gpa);
    defer gpa.free(data);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const others: ?[]const u32 = if (install_probe.emetgateProcesses(arena)) |found| blk: {
        const pids = try arena.alloc(u32, found.len);
        for (found, pids) |process, *pid| pid.* = process.pid;
        break :blk pids;
    } else |_| null;
    return runIn(gpa, io, data, std.Io.Clock.real.now(io).nanoseconds, options, others, out);
}

pub fn runIn(gpa: Allocator, io: std.Io, data_abs: []const u8, now: i96, options: Options, others: ?[]const u32, out: *Writer) !u8 {
    switch (options) {
        .size => |size| {
            var measured = try cache_gc.measure(gpa, io, data_abs);
            defer measured.deinit(gpa);
            if (size.json) try writeSizeJson(out, data_abs, measured, now) else try writeSizeText(out, data_abs, measured, now);
            return 0;
        },
        .prune => |prune| {
            const report = try cache_gc.sweep(gpa, io, data_abs, prune.policy(), now, null);
            const code = try writePrune(out, data_abs, prune, report);
            if (report.busy or !report.ran) return code;
            const shared_failed = try pruneShared(io, data_abs, prune, others, out);
            return if (shared_failed) 1 else code;
        },
    }
}

const Shared = struct { name: []const u8, path: []u8, bytes: u64 };

fn pruneShared(io: std.Io, data_abs: []const u8, prune: Prune, others: ?[]const u32, out: *Writer) !bool {
    var paths: [shared_folders.len][std.fs.max_path_bytes]u8 = undefined;
    var found: [shared_folders.len]Shared = undefined;
    var count: usize = 0;
    var total: u64 = 0;
    for (shared_folders, 0..) |name, i| {
        const path = try std.fmt.bufPrint(&paths[i], "{s}\\{s}", .{ data_abs, name });
        const bytes = (try cache_gc.folderBytes(io, path)) orelse continue;
        found[count] = .{ .name = name, .path = path, .bytes = bytes };
        count += 1;
        total +|= bytes;
    }
    const shared = found[0..count];
    if (shared.len == 0) return false;
    if (!prune.all) {
        try out.writeAll("left alone: shared folders ");
        try writeShared(out, shared);
        try out.writeAll("; emetgate cache prune --all clears them while no other emetgate is running\n");
        return false;
    }
    const running = others orelse {
        try out.writeAll("kept shared folders ");
        try writeShared(out, shared);
        try out.writeAll(": could not list the running processes to check that no other emetgate uses them\n");
        return true;
    };
    if (running.len != 0) {
        try out.writeAll("kept shared folders ");
        try writeShared(out, shared);
        try out.writeAll(": other emetgate processes are running (PID");
        for (running, 0..) |pid, i| try out.print("{s} {d}", .{ if (i == 0) "" else ",", pid });
        try out.writeAll("); close them and run emetgate cache prune --all again\n");
        return false;
    }
    if (prune.dry_run) {
        try out.writeAll("would clear shared folders ");
        try writeShared(out, shared);
        try out.writeAll(", would free ");
        try cache_gc.writeSize(out, total);
        try out.writeAll("\n");
        return false;
    }
    var freed: u64 = 0;
    var failed = false;
    for (shared) |folder| {
        shadow.clearTemp(io, folder.path) catch |err| {
            try out.print("could not clear {s}: {t}\n", .{ folder.path, err });
            failed = true;
            continue;
        };
        freed +|= folder.bytes;
    }
    try out.writeAll("cleared shared folders ");
    try writeShared(out, shared);
    try out.writeAll(", freed ");
    try cache_gc.writeSize(out, freed);
    try out.writeAll("\n");
    return failed;
}

fn writeShared(out: *Writer, shared: []const Shared) !void {
    for (shared, 0..) |folder, i| {
        if (i != 0) try out.writeAll(", ");
        try out.print("{s} (", .{folder.name});
        try cache_gc.writeSize(out, folder.bytes);
        try out.writeAll(")");
    }
}

fn daysSince(now: i96, then: i96) ?i96 {
    if (then == 0) return null;
    return @divFloor(@max(now - then, 0), day);
}

fn writeSizeText(out: *Writer, data_abs: []const u8, measured: cache_gc.Usage, now: i96) !void {
    try out.print("emetgate data in {s}: ", .{data_abs});
    try cache_gc.writeSize(out, measured.total);
    try out.writeAll("\n");
    if (measured.folders.len == 0) return out.writeAll("  (empty)\n");
    for (measured.folders) |folder| {
        try out.print("  {s:<16} ", .{folder.name});
        try cache_gc.writeSize(out, folder.bytes);
        try out.writeAll("\n");
    }
    if (measured.projects.len != 0) {
        try out.writeAll("project caches (find, index, facts, shadow), biggest first:\n");
        for (measured.projects) |project| {
            try out.writeAll("  ");
            try cache_gc.writeSize(out, project.bytes);
            if (daysSince(now, project.last_used)) |days| try out.print("  used {d} day(s) ago", .{days});
            if (project.root) |root| try out.print("  {s}\n", .{root}) else try out.print("  {s}\n", .{&project.key});
        }
    }
    if (measured.first_failure) |err| try out.print("could not measure {d} item(s): {t}\n", .{ measured.failed, err });
}

fn writeSizeJson(out: *Writer, data_abs: []const u8, measured: cache_gc.Usage, now: i96) !void {
    var js: std.json.Stringify = .{ .writer = out };
    try js.beginObject();
    try js.objectField("data_dir");
    try js.write(data_abs);
    try js.objectField("total_bytes");
    try js.write(measured.total);
    try js.objectField("folders");
    try js.beginArray();
    for (measured.folders) |folder| {
        try js.beginObject();
        try js.objectField("name");
        try js.write(folder.name);
        try js.objectField("bytes");
        try js.write(folder.bytes);
        try js.endObject();
    }
    try js.endArray();
    try js.objectField("projects");
    try js.beginArray();
    for (measured.projects) |project| {
        try js.beginObject();
        try js.objectField("key");
        try js.write(&project.key);
        try js.objectField("root");
        try js.write(project.root);
        try js.objectField("bytes");
        try js.write(project.bytes);
        try js.objectField("last_used_days");
        try js.write(daysSince(now, project.last_used));
        try js.endObject();
    }
    try js.endArray();
    try js.objectField("failed");
    try js.write(measured.failed);
    try js.endObject();
    try out.writeAll("\n");
}

fn writePrune(out: *Writer, data_abs: []const u8, prune: Prune, report: cache_gc.Report) !u8 {
    if (report.busy) {
        try out.writeAll("another emetgate process is sweeping the caches; try again in a moment\n");
        return 1;
    }
    if (!report.ran) {
        try out.print("no emetgate caches in {s}\n", .{data_abs});
        return 0;
    }
    if (prune.dry_run) try out.writeAll("dry run, nothing deleted: would remove ") else try out.writeAll("removed ");
    try out.print("{d} project cache(s)", .{report.removed});
    if (prune.all) try out.writeAll(" (all not in use)") else try out.print(" unused for {d}+ day(s) or whose repository is gone", .{prune.older_than_days});
    try out.writeAll(if (prune.dry_run) ", would free " else ", freed ");
    try cache_gc.writeSize(out, report.freed_bytes);
    try out.print("; kept {d} (", .{report.kept});
    try cache_gc.writeSize(out, report.kept_bytes);
    try out.print("), {d} in use\n", .{report.live});
    const err = report.first_failure orelse return 0;
    try out.print("could not remove {d} cache(s): {t}\n", .{ report.failed, err });
    return 1;
}

const testing = std.testing;

test "cache size and prune parse their flags and refuse junk, zero, repeats and --all with --older-than" {
    const Case = struct { args: []const [:0]const u8, ok: bool };
    const cases = [_]Case{
        .{ .args = &.{"size"}, .ok = true },
        .{ .args = &.{ "size", "--json" }, .ok = true },
        .{ .args = &.{ "size", "--all" }, .ok = false },
        .{ .args = &.{"prune"}, .ok = true },
        .{ .args = &.{ "prune", "--older-than", "3", "--dry-run" }, .ok = true },
        .{ .args = &.{ "prune", "--all", "--dry-run" }, .ok = true },
        .{ .args = &.{ "prune", "--all", "--older-than", "3" }, .ok = false },
        .{ .args = &.{ "prune", "--older-than", "0" }, .ok = false },
        .{ .args = &.{ "prune", "--older-than" }, .ok = false },
        .{ .args = &.{ "prune", "--dry-run", "--dry-run" }, .ok = false },
        .{ .args = &.{ "prune", "--max-mb", "500", "--older-than", "7" }, .ok = true },
        .{ .args = &.{ "prune", "--max-mb", "0" }, .ok = false },
        .{ .args = &.{ "prune", "--all", "--max-mb", "5" }, .ok = false },
        .{ .args = &.{"wipe"}, .ok = false },
        .{ .args = &.{}, .ok = false },
    };
    for (cases) |case| try testing.expectEqual(case.ok, parse(case.args) != null);
    const defaulted = parse(&.{"prune"}).?.prune.policy();
    try testing.expectEqual(default_older_than_days, defaulted.max_age_days);
    try testing.expect(!defaulted.dry_run);
    const all = parse(&.{ "prune", "--all", "--dry-run" }).?.prune.policy();
    try testing.expectEqual(@as(u32, 0), all.max_age_days);
    try testing.expect(all.dry_run);
    try testing.expectEqual(@as(u32, 3), parse(&.{ "prune", "--older-than", "3" }).?.prune.policy().max_age_days);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), defaulted.max_mb);
    try testing.expectEqual(@as(u64, 500), parse(&.{ "prune", "--max-mb", "500" }).?.prune.policy().max_mb);
}

test "sizes print in B, KB, MB and GB" {
    var buf: [64]u8 = undefined;
    const Case = struct { bytes: u64, text: []const u8 };
    for ([_]Case{
        .{ .bytes = 512, .text = "512 B" },
        .{ .bytes = 1536, .text = "1.5 KB" },
        .{ .bytes = 5 * 1024 * 1024, .text = "5.0 MB" },
        .{ .bytes = 5 * 1024 * 1024 * 1024, .text = "5.0 GB" },
    }) |case| {
        var w: Writer = .fixed(&buf);
        try cache_gc.writeSize(&w, case.bytes);
        try testing.expectEqualStrings(case.text, w.buffered());
    }
}

const Fixture = struct {
    tmp: testing.TmpDir,
    top: [:0]u8,
    data: []u8,
    now: i96,

    fn init() !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const top = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        errdefer testing.allocator.free(top);
        const data = try std.fmt.allocPrint(testing.allocator, "{s}\\data", .{top});
        errdefer testing.allocator.free(data);
        try tmp.dir.createDirPath(testing.io, "data");
        return .{ .tmp = tmp, .top = top, .data = data, .now = std.Io.Clock.real.now(testing.io).nanoseconds };
    }

    fn deinit(self: *Fixture) void {
        testing.allocator.free(self.data);
        testing.allocator.free(self.top);
        self.tmp.cleanup();
    }

    fn cache(self: *Fixture, family: []const u8, key: []const u8, bytes: usize, mtime: i96) !void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        try self.tmp.dir.createDirPath(testing.io, try std.fmt.bufPrint(&buf, "data/{s}/{s}", .{ family, key }));
        const blob = try testing.allocator.alloc(u8, bytes);
        defer testing.allocator.free(blob);
        @memset(blob, 'x');
        const sub = try std.fmt.bufPrint(&buf, "data/{s}/{s}/blob", .{ family, key });
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = blob });
        var file = try self.tmp.dir.openFile(testing.io, sub, .{ .mode = .read_write });
        defer file.close(testing.io);
        try file.setTimestamps(testing.io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = mtime } } });
    }

    fn present(self: *Fixture, family: []const u8, key: []const u8) bool {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const sub = std.fmt.bufPrint(&buf, "data/{s}/{s}", .{ family, key }) catch return false;
        self.tmp.dir.access(testing.io, sub, .{}) catch return false;
        return true;
    }

    fn run(self: *Fixture, args: []const [:0]const u8, out: *Writer) !u8 {
        return self.runWith(args, &.{}, out);
    }

    fn runWith(self: *Fixture, args: []const [:0]const u8, others: ?[]const u32, out: *Writer) !u8 {
        return runIn(testing.allocator, testing.io, self.data, self.now, parse(args).?, others, out);
    }
};

test "cache size totals every top-level folder and lists each project cache with its recorded root, also as JSON" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init();
    defer fx.deinit();
    const root = try std.fmt.allocPrint(testing.allocator, "{s}\\repo", .{fx.top});
    defer testing.allocator.free(root);
    const key = shadow_root.repoKey(root);
    try fx.cache("index", &key, 3000, fx.now);
    try fx.cache("find", &key, 1000, fx.now);
    const lease = try cache_lease.acquire(fx.data, root, 0);
    lease.release();
    try fx.tmp.dir.createDirPath(testing.io, "data/cache/npm");
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "data/cache/npm/pkg", .data = "x" ** 500 });
    fx.now += 2 * day + std.time.ns_per_hour;

    var buf: [8192]u8 = undefined;
    var text: Writer = .fixed(&buf);
    try testing.expectEqual(@as(u8, 0), try fx.run(&.{"size"}, &text));
    const shown = text.buffered();
    try testing.expect(std.mem.indexOf(u8, shown, "  index            2.9 KB\n") != null);
    try testing.expect(std.mem.indexOf(u8, shown, "  cache            500 B\n") != null);
    try testing.expect(std.mem.indexOf(u8, shown, "  3.9 KB  used 2 day(s) ago  ") != null);
    try testing.expect(std.mem.indexOf(u8, shown, root) != null);

    var json_buf: [8192]u8 = undefined;
    var json: Writer = .fixed(&json_buf);
    try testing.expectEqual(@as(u8, 0), try fx.run(&.{ "size", "--json" }, &json));
    const Parsed = struct {
        data_dir: []const u8,
        total_bytes: u64,
        folders: []const struct { name: []const u8, bytes: u64 },
        projects: []const struct { key: []const u8, root: ?[]const u8, bytes: u64, last_used_days: ?i64 },
        failed: usize,
    };
    const parsed = try std.json.parseFromSlice(Parsed, testing.allocator, json.buffered(), .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(u64, 3000 + 1000 + 500 + root.len), parsed.value.total_bytes);
    try testing.expectEqualStrings("index", parsed.value.folders[0].name);
    try testing.expectEqual(@as(usize, 1), parsed.value.projects.len);
    try testing.expectEqualStrings(root, parsed.value.projects[0].root.?);
    try testing.expectEqual(@as(u64, 4000), parsed.value.projects[0].bytes);
    try testing.expectEqual(@as(?i64, 2), parsed.value.projects[0].last_used_days);
}

test "cache size of a missing data directory is empty, not an error" {
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.tmp.dir.deleteDir(testing.io, "data");
    var buf: [1024]u8 = undefined;
    var out: Writer = .fixed(&buf);
    try testing.expectEqual(@as(u8, 0), try fx.run(&.{"size"}, &out));
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "(empty)") != null);
}

test "cache prune removes caches older than the limit, a dry run deletes nothing, --all spares only leased caches" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init();
    defer fx.deinit();
    const old = shadow_root.repoKey("C:\\prune\\old");
    const young = shadow_root.repoKey("C:\\prune\\young");
    const held_root = "C:\\prune\\held";
    const held = shadow_root.repoKey(held_root);
    try fx.cache("index", &old, 2048, fx.now);
    try fx.cache("find", &young, 1024, fx.now + 17 * day);
    try fx.cache("facts", &held, 4096, fx.now);
    const lease = try cache_lease.acquire(fx.data, held_root, 0);
    defer lease.release();
    fx.now += 20 * day;

    var buf: [2048]u8 = undefined;
    var dry: Writer = .fixed(&buf);
    try testing.expectEqual(@as(u8, 0), try fx.run(&.{ "prune", "--dry-run" }, &dry));
    try testing.expect(std.mem.indexOf(u8, dry.buffered(), "would remove 1 project cache(s)") != null);
    try testing.expect(std.mem.indexOf(u8, dry.buffered(), "would free 2.0 KB") != null);
    try testing.expect(std.mem.indexOf(u8, dry.buffered(), "1 in use") != null);
    try testing.expect(fx.present("index", &old));

    var real: Writer = .fixed(&buf);
    try testing.expectEqual(@as(u8, 0), try fx.run(&.{"prune"}, &real));
    try testing.expect(std.mem.indexOf(u8, real.buffered(), "removed 1 project cache(s)") != null);
    try testing.expect(std.mem.indexOf(u8, real.buffered(), "freed 2.0 KB") != null);
    try testing.expect(!fx.present("index", &old));
    try testing.expect(fx.present("find", &young));
    try testing.expect(fx.present("facts", &held));

    var older: Writer = .fixed(&buf);
    try testing.expectEqual(@as(u8, 0), try fx.run(&.{ "prune", "--older-than", "5" }, &older));
    try testing.expect(fx.present("find", &young));

    var all: Writer = .fixed(&buf);
    try testing.expectEqual(@as(u8, 0), try fx.run(&.{ "prune", "--all" }, &all));
    try testing.expect(std.mem.indexOf(u8, all.buffered(), "removed 1 project cache(s) (all not in use), freed 1.0 KB") != null);
    try testing.expect(!fx.present("find", &young));
    try testing.expect(fx.present("facts", &held));
}

test "prune --all clears the shared cache and run-tmp folders only while no other emetgate runs, without following a link out" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init();
    defer fx.deinit();
    try fx.tmp.dir.createDirPath(testing.io, "data/cache/npm");
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "data/cache/npm/pkg", .data = "x" ** 2048 });
    try fx.tmp.dir.createDirPath(testing.io, "data/run-tmp/k");
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "data/run-tmp/k/t", .data = "x" ** 1024 });
    try fx.tmp.dir.createDirPath(testing.io, "victim");
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "victim/keep.txt", .data = "keep\n" });
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    try shadow.createJunction(testing.io, try std.fmt.bufPrint(&link_buf, "{s}\\cache\\linked", .{fx.data}), try std.fmt.bufPrint(&target_buf, "{s}\\victim", .{fx.top}));

    var buf: [2048]u8 = undefined;
    var plain: Writer = .fixed(&buf);
    try testing.expectEqual(@as(u8, 0), try fx.run(&.{"prune"}, &plain));
    try testing.expect(std.mem.indexOf(u8, plain.buffered(), "left alone: shared folders cache (2.0 KB), run-tmp (1.0 KB); emetgate cache prune --all") != null);

    var busy: Writer = .fixed(&buf);
    try testing.expectEqual(@as(u8, 0), try fx.runWith(&.{ "prune", "--all" }, &.{ 4242, 77 }, &busy));
    try testing.expect(std.mem.indexOf(u8, busy.buffered(), "other emetgate processes are running (PID 4242, 77)") != null);
    try fx.tmp.dir.access(testing.io, "data/cache/npm/pkg", .{});

    var unknown: Writer = .fixed(&buf);
    try testing.expectEqual(@as(u8, 1), try fx.runWith(&.{ "prune", "--all" }, null, &unknown));
    try fx.tmp.dir.access(testing.io, "data/run-tmp/k/t", .{});

    var dry: Writer = .fixed(&buf);
    try testing.expectEqual(@as(u8, 0), try fx.run(&.{ "prune", "--all", "--dry-run" }, &dry));
    try testing.expect(std.mem.indexOf(u8, dry.buffered(), "would clear shared folders cache (2.0 KB), run-tmp (1.0 KB), would free 3.0 KB") != null);
    try fx.tmp.dir.access(testing.io, "data/cache/npm/pkg", .{});

    var all: Writer = .fixed(&buf);
    try testing.expectEqual(@as(u8, 0), try fx.run(&.{ "prune", "--all" }, &all));
    try testing.expect(std.mem.indexOf(u8, all.buffered(), "cleared shared folders cache (2.0 KB), run-tmp (1.0 KB), freed 3.0 KB") != null);
    try testing.expectError(error.FileNotFound, fx.tmp.dir.access(testing.io, "data/cache", .{}));
    try testing.expectError(error.FileNotFound, fx.tmp.dir.access(testing.io, "data/run-tmp", .{}));
    try fx.tmp.dir.access(testing.io, "victim/keep.txt", .{});
}
