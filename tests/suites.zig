const std = @import("std");
const builtin = @import("builtin");
const zig_source = @import("zig_source.zig");

const testing = std.testing;

fn read(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(1024 * 1024));
}

fn declaresTests(source: []const u8) !bool {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    return zig_source.declaresTests(arena_state.allocator(), source);
}

fn importCount(source: []const u8, path: []const u8) !usize {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var count: usize = 0;
    for (try zig_source.imports(arena_state.allocator(), source)) |target| {
        if (std.mem.eql(u8, target, path)) count += 1;
    }
    return count;
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

test "suites: every test file under tests/ is imported exactly once by test_root.zig" {
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
        if (!try declaresTests(source)) continue;
        counted += 1;
        const imports = try importCount(root, path);
        if (imports != 1) {
            std.debug.print("{s} is imported {d} times by test_root.zig\n", .{ path, imports });
            missing += 1;
        }
    }
    try testing.expect(counted > 10);
    try testing.expectEqual(@as(usize, 0), missing);
}

test "suites: a test is found in any form and position, and a commented one is not" {
    try testing.expect(try declaresTests("test \"a\" {}\n"));
    try testing.expect(try declaresTests("test named {}\n"));
    try testing.expect(try declaresTests("const S = struct {\n    test \"inside\" {}\n};\n"));
    try testing.expect(try declaresTests("test {\n    _ = 1;\n}\n"));
    try testing.expect(!try declaresTests("// test \"commented\" {}\nconst x = \"test \\\"in a string\\\" {}\";\n"));
}

test "suites: an import in a comment or a string is not counted" {
    const source = "_ = @import(\"tests/a.zig\");\n// _ = @import(\"tests/a.zig\");\nconst s = \"_ = @import(\\\"tests/a.zig\\\")\";\n";
    try testing.expectEqual(@as(usize, 1), try importCount(source, "tests/a.zig"));
    try testing.expectEqual(@as(usize, 0), try importCount("// _ = @import(\"tests/b.zig\");\n", "tests/b.zig"));
}

fn testNamePrefix(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const stem = path[0 .. path.len - ".zig".len];
    const prefix = try std.fmt.allocPrint(gpa, "{s}.", .{stem});
    std.mem.replaceScalar(u8, prefix, '/', '.');
    return prefix;
}

fn binaryRuns(prefix: []const u8) bool {
    for (builtin.test_functions) |t| {
        if (!std.mem.startsWith(u8, t.name, prefix)) continue;
        const rest = t.name[prefix.len..];
        if (std.mem.startsWith(u8, rest, "test.") or std.mem.startsWith(u8, rest, "decltest.")) return true;
    }
    return false;
}

test "suites: the one test binary runs the src tests and the tests of every file test_root.zig imports" {
    try testing.expect(binaryRuns("src.engine.cas."));
    try testing.expect(binaryRuns("src.platform.disk."));
    try testing.expect(binaryRuns("src.protocol.wire."));

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try read("test_root.zig");
    defer testing.allocator.free(root);
    var checked: usize = 0;
    for (try zig_source.imports(arena, root)) |path| {
        if (!std.mem.startsWith(u8, path, "tests/")) continue;
        const source = try read(path);
        defer testing.allocator.free(source);
        if (!try declaresTests(source)) continue;
        checked += 1;
        errdefer std.debug.print("{s} is imported by test_root.zig but none of its tests is in the binary\n", .{path});
        try testing.expect(binaryRuns(try testNamePrefix(arena, path)));
    }
    try testing.expect(checked > 10);
}
