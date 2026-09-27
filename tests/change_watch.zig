const std = @import("std");
const builtin = @import("builtin");
const change_watch = @import("emetgate").change_watch;

const testing = std.testing;
const gpa = testing.allocator;
const Watcher = change_watch.Watcher;

const patience_ms: u32 = 10_000;

const Tree = struct {
    tmp: testing.TmpDir,
    root_abs: [:0]u8,

    fn init() !Tree {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo");
        const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", gpa);
        return .{ .tmp = tmp, .root_abs = root_abs };
    }

    fn deinit(self: *Tree) void {
        gpa.free(self.root_abs);
        self.tmp.cleanup();
    }

    fn sub(rel: []const u8, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "repo/{s}", .{rel});
    }

    fn write(self: *Tree, rel: []const u8, data: []const u8) !void {
        var buf: [512]u8 = undefined;
        const path = try sub(rel, &buf);
        if (std.fs.path.dirname(path)) |dir| try self.tmp.dir.createDirPath(testing.io, dir);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = data });
    }

    fn mkdir(self: *Tree, rel: []const u8) !void {
        var buf: [512]u8 = undefined;
        try self.tmp.dir.createDirPath(testing.io, try sub(rel, &buf));
    }

    fn rename(self: *Tree, from: []const u8, to: []const u8) !void {
        var a: [512]u8 = undefined;
        var b: [512]u8 = undefined;
        try self.tmp.dir.rename(try sub(from, &a), self.tmp.dir, try sub(to, &b), testing.io);
    }

    fn delete(self: *Tree, rel: []const u8) !void {
        var buf: [512]u8 = undefined;
        try self.tmp.dir.deleteFile(testing.io, try sub(rel, &buf));
    }

    fn start(self: *Tree, options: change_watch.Options) !*Watcher {
        return Watcher.start(gpa, testing.io, self.root_abs, options);
    }
};

fn expectDirty(watcher: *Watcher, rels: []const []const u8) !void {
    const dirty = try watcher.sync(patience_ms);
    defer dirty.deinit(gpa);
    for (rels) |rel| {
        if (!dirty.contains(rel)) {
            std.debug.print("missing {s}; files:", .{rel});
            for (dirty.files) |p| std.debug.print(" {s}", .{p});
            std.debug.print("; subtrees:", .{});
            for (dirty.subtrees) |p| std.debug.print(" {s}", .{p});
            std.debug.print("\n", .{});
            return error.MissingDirtyPath;
        }
    }
}

test "change watch: a file written and synced with no pause is in the dirty set, 200 times in a row" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.write("src/keep.ts", "export const a = 0;\n");
    const watcher = try tree.start(.{});
    defer watcher.deinit();

    var name_buf: [64]u8 = undefined;
    for (0..200) |i| {
        const rel = try std.fmt.bufPrint(&name_buf, "src/f{d}.ts", .{i % 7});
        try tree.write(rel, if (i % 2 == 0) "export const a = 1;\n" else "export const a = 22;\n");
        try expectDirty(watcher, &.{rel});
        try tree.write("src/keep.ts", if (i % 2 == 0) "export const a = 3;\n" else "export const a = 4;\n");
        try expectDirty(watcher, &.{"src/keep.ts"});
    }
}

test "change watch: a sync hands the dirty set over once and starts a new one" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    const watcher = try tree.start(.{});
    defer watcher.deinit();

    try tree.write("a.ts", "1");
    try expectDirty(watcher, &.{"a.ts"});
    try tree.write("b.ts", "2");
    const second = try watcher.sync(patience_ms);
    defer second.deinit(gpa);
    try testing.expect(second.contains("b.ts"));
    try testing.expect(!second.contains("a.ts"));
}

const Writer = struct {
    tree: *Tree,
    stop: std.atomic.Value(bool) = .init(false),
    written: std.atomic.Value(u32) = .init(0),

    fn run(self: *Writer) void {
        var name_buf: [64]u8 = undefined;
        var i: u32 = 0;
        while (!self.stop.load(.acquire)) : (i += 1) {
            const rel = std.fmt.bufPrint(&name_buf, "noise/n{d}.ts", .{i % 50}) catch return;
            self.tree.write(rel, "export const noise = 1;\n") catch return;
            _ = self.written.fetchAdd(1, .release);
        }
    }
};

test "change watch: every synced write is seen while another thread keeps writing" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.mkdir("noise");
    const watcher = try tree.start(.{});
    defer watcher.deinit();

    var writer: Writer = .{ .tree = &tree };
    const thread = try std.Thread.spawn(.{}, Writer.run, .{&writer});
    defer {
        writer.stop.store(true, .release);
        thread.join();
    }

    var name_buf: [64]u8 = undefined;
    var overflowed: usize = 0;
    for (0..200) |i| {
        const rel = try std.fmt.bufPrint(&name_buf, "mine/m{d}.ts", .{i % 5});
        try tree.write(rel, if (i % 2 == 0) "a" else "bb");
        const dirty = watcher.sync(patience_ms) catch |err| switch (err) {
            error.Overflow => {
                overflowed += 1;
                continue;
            },
            else => return err,
        };
        defer dirty.deinit(gpa);
        try testing.expect(dirty.contains(rel));
    }
    try testing.expect(writer.written.load(.acquire) > 0);
    try testing.expect(overflowed < 200);
}

test "change watch: rename marks both ends, delete, directory rename and a nested create are seen" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.write("old.ts", "1");
    try tree.write("gone.ts", "2");
    try tree.write("dir/inner/x.ts", "3");
    const watcher = try tree.start(.{});
    defer watcher.deinit();

    try tree.rename("old.ts", "new.ts");
    try expectDirty(watcher, &.{ "old.ts", "new.ts" });

    try tree.delete("gone.ts");
    try expectDirty(watcher, &.{"gone.ts"});

    try tree.rename("dir", "moved");
    try expectDirty(watcher, &.{ "dir/inner/x.ts", "moved/inner/x.ts" });

    try tree.write("a/b/c/d/e.ts", "4");
    try expectDirty(watcher, &.{"a/b/c/d/e.ts"});
}

test "change watch: a directory moved in from outside the tree marks its whole subtree" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.tmp.dir.createDirPath(testing.io, "outside/pkg");
    try tree.tmp.dir.writeFile(testing.io, .{ .sub_path = "outside/pkg/index.ts", .data = "1" });
    const watcher = try tree.start(.{});
    defer watcher.deinit();

    try tree.tmp.dir.rename("outside/pkg", tree.tmp.dir, "repo/pkg", testing.io);
    try expectDirty(watcher, &.{"pkg/index.ts"});
}

test "change watch: git and emetgate internals stay out of the dirty set" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    const watcher = try tree.start(.{});
    defer watcher.deinit();

    try tree.write(".git/index", "x");
    try tree.write(".emetgate/journal/j1", "y");
    try tree.write("src/real.ts", "z");
    const dirty = try watcher.sync(patience_ms);
    defer dirty.deinit(gpa);
    try testing.expect(dirty.contains("src/real.ts"));
    for (dirty.files) |p| {
        try testing.expect(!std.mem.startsWith(u8, p, ".git"));
        try testing.expect(!std.mem.startsWith(u8, p, ".emetgate"));
    }
}

test "change watch: a buffer too small for the burst reports Overflow and the next sync is trustworthy again" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    const watcher = try tree.start(.{ .buffer_bytes = change_watch.min_buffer_bytes });
    defer watcher.deinit();

    var name_buf: [64]u8 = undefined;
    for (0..2000) |i| {
        const rel = try std.fmt.bufPrint(&name_buf, "burst/file-with-a-long-name-{d}.ts", .{i});
        try tree.write(rel, "x");
    }
    try testing.expectError(error.Overflow, watcher.sync(patience_ms));

    try tree.write("after.ts", "1");
    try expectDirty(watcher, &.{"after.ts"});
}

test "change watch: a sync that runs out of time says Timeout and never hands out a clean set" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    const watcher = try tree.start(.{});
    defer watcher.deinit();

    try tree.write("late.ts", "1");
    try testing.expectError(error.Timeout, watcher.sync(0));
    try tree.write("later.ts", "2");
    try expectDirty(watcher, &.{"later.ts"});
}

test "change watch: a deleted root is NotWatching and stays so" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    const watcher = try tree.start(.{});
    defer watcher.deinit();
    try tree.write("a.ts", "1");
    try expectDirty(watcher, &.{"a.ts"});

    try tree.tmp.dir.deleteTree(testing.io, "repo");
    try testing.expectError(error.NotWatching, watcher.sync(patience_ms));
    try testing.expectError(error.NotWatching, watcher.sync(patience_ms));
}

test "change watch: a root that is missing, a file or on no drive letter is refused at start" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.write("plain.ts", "1");
    const file_abs = try std.fmt.allocPrint(gpa, "{s}\\plain.ts", .{tree.root_abs});
    defer gpa.free(file_abs);
    const missing_abs = try std.fmt.allocPrint(gpa, "{s}\\missing", .{tree.root_abs});
    defer gpa.free(missing_abs);
    try testing.expectError(error.NotWatching, Watcher.start(gpa, testing.io, file_abs, .{}));
    try testing.expectError(error.NotWatching, Watcher.start(gpa, testing.io, missing_abs, .{}));
    try testing.expectError(error.NotWatching, Watcher.start(gpa, testing.io, "\\\\server\\share\\repo", .{}));
}

test "redteam change watch: files already sitting in the cookie directory cannot end a barrier early" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    const watcher = try tree.start(.{});
    defer watcher.deinit();

    var name_buf: [96]u8 = undefined;
    for (0..40) |i| {
        const rel = try std.fmt.bufPrint(&name_buf, ".emetgate/cookies/{x:0>32}", .{i});
        try tree.write(rel, "");
        try tree.delete(rel);
        try tree.write(rel, "");
    }
    for (0..50) |i| {
        const rel = try std.fmt.bufPrint(&name_buf, "src/r{d}.ts", .{i});
        try tree.write(rel, "1");
        try expectDirty(watcher, &.{rel});
    }
}

test "redteam change watch: a cookie directory that is a file or a junction is refused, never reported clean" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    const watcher = try tree.start(.{});
    defer watcher.deinit();

    try tree.write(".emetgate/cookies", "not a directory");
    try tree.write("a.ts", "1");
    try testing.expectError(error.NotWatching, watcher.sync(patience_ms));
    try tree.delete(".emetgate/cookies");

    try tree.tmp.dir.createDirPath(testing.io, "elsewhere");
    const target = try tree.tmp.dir.realPathFileAlloc(testing.io, "elsewhere", gpa);
    defer gpa.free(target);
    const link = try std.fmt.allocPrint(gpa, "{s}\\.emetgate\\cookies", .{tree.root_abs});
    defer gpa.free(link);
    const made = try std.process.run(gpa, testing.io, .{ .argv = &.{ "cmd.exe", "/d", "/c", "mklink", "/J", link, target } });
    gpa.free(made.stdout);
    gpa.free(made.stderr);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, made.term);
    try testing.expectError(error.NotWatching, watcher.sync(patience_ms));
}

test "change watch: a write through a handle that is kept open is seen once the writer flushes or closes it" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tree = try Tree.init();
    defer tree.deinit();
    try tree.write("flushed.ts", "export const v = 1;\n");
    try tree.write("closed.ts", "export const v = 1;\n");
    const watcher = try tree.start(.{});
    defer watcher.deinit();

    const flushed = try tree.tmp.dir.openFile(testing.io, "repo/flushed.ts", .{ .mode = .read_write });
    defer flushed.close(testing.io);
    for (0..10) |i| {
        try flushed.writePositionalAll(testing.io, if (i % 2 == 0) "export const v = 2;\n" else "export const v = 3;\n", 0);
        try flushed.sync(testing.io);
        try expectDirty(watcher, &.{"flushed.ts"});
    }

    for (0..10) |i| {
        const closed = try tree.tmp.dir.openFile(testing.io, "repo/closed.ts", .{ .mode = .read_write });
        try closed.writePositionalAll(testing.io, if (i % 2 == 0) "export const v = 2;\n" else "export const v = 3;\n", 0);
        closed.close(testing.io);
        try expectDirty(watcher, &.{"closed.ts"});
    }
}
