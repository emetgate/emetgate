const std = @import("std");
const build_options = @import("build_options");

const testing = std.testing;

fn read(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(1024 * 1024));
}

fn declaresTests(source: []const u8) bool {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "test \"") or std.mem.startsWith(u8, line, "test {")) return true;
    }
    return false;
}

fn collect(dir_path: []const u8, out: *std.ArrayList([]u8)) !void {
    var dir = try std.Io.Dir.cwd().openDir(testing.io, dir_path, .{ .iterate = true });
    defer dir.close(testing.io);
    var it = dir.iterate();
    while (try it.next(testing.io)) |entry| {
        const path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir_path, entry.name });
        switch (entry.kind) {
            .directory => {
                defer testing.allocator.free(path);
                try collect(path, out);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".zig")) {
                    testing.allocator.free(path);
                    continue;
                }
                try out.append(testing.allocator, path);
            },
            else => testing.allocator.free(path),
        }
    }
}

test "suites: every test file under tests/ is imported by exactly one suite" {
    const root = try read("test_root.zig");
    defer testing.allocator.free(root);
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| testing.allocator.free(p);
        paths.deinit(testing.allocator);
    }
    try collect("tests", &paths);

    var missing: usize = 0;
    var counted: usize = 0;
    for (paths.items) |path| {
        const source = try read(path);
        defer testing.allocator.free(source);
        if (!declaresTests(source)) continue;
        counted += 1;
        const needle = try std.fmt.allocPrint(testing.allocator, "_ = @import(\"{s}\");", .{path});
        defer testing.allocator.free(needle);
        const imports = std.mem.count(u8, root, needle);
        if (imports != 1) {
            std.debug.print("{s} is imported {d} times by test_root.zig\n", .{ path, imports });
            missing += 1;
        }
    }
    try testing.expect(counted > 10);
    try testing.expectEqual(@as(usize, 0), missing);
}

test "suites: every suite build.zig builds runs at least one test file" {
    const root = try read("test_root.zig");
    defer testing.allocator.free(root);
    for (build_options.suites) |suite| {
        const needle = try std.fmt.allocPrint(testing.allocator, "runs(\"{s}\")", .{suite});
        defer testing.allocator.free(needle);
        errdefer std.debug.print("suite {s} has no file in test_root.zig\n", .{suite});
        try testing.expect(std.mem.indexOf(u8, root, needle) != null);
    }
}

test "suites: no test file imports another file that declares tests, so no test runs in two suites" {
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| testing.allocator.free(p);
        paths.deinit(testing.allocator);
    }
    try collect("tests", &paths);

    var shared: usize = 0;
    for (paths.items) |path| {
        const source = try read(path);
        defer testing.allocator.free(source);
        var rest = source;
        while (std.mem.indexOf(u8, rest, "@import(\"")) |at| {
            rest = rest[at + "@import(\"".len ..];
            const end = std.mem.indexOfScalar(u8, rest, '"') orelse break;
            const target = rest[0..end];
            if (!std.mem.endsWith(u8, target, ".zig")) continue;
            const dir = std.fs.path.dirname(path) orelse ".";
            const joined = try std.fs.path.resolvePosix(testing.allocator, &.{ dir, target });
            defer testing.allocator.free(joined);
            if (!std.mem.startsWith(u8, joined, "tests/")) continue;
            const imported = read(joined) catch continue;
            defer testing.allocator.free(imported);
            if (declaresTests(imported)) {
                std.debug.print("{s} imports {s}, which declares tests\n", .{ path, joined });
                shared += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), shared);
}
