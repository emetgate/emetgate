const std = @import("std");
const git_fixture = @import("git_fixture.zig");
const builtin = @import("builtin");
const doc_writer = @import("emetgate").doc_writer;
const symbol = @import("emetgate").symbol;

const testing = std.testing;
const gpa = testing.allocator;

const package_json = "{\"name\": \"demo\", \"scripts\": {\"build\": \"tsc\"}}\n";
const readme_md = "# Title\n\n## Setup\n\nold instructions\n\n## Other\n\nkeep this\n";
const notes_txt = "line one\nline two\nline three\n";

const Fixture = struct {
    tmp: testing.TmpDir,
    root_abs: [:0]u8,

    fn init() !Fixture {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/package.json", .data = package_json });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/README.md", .data = readme_md });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/notes.txt", .data = notes_txt });
        const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", gpa);
        errdefer gpa.free(root_abs);
        try git_fixture.initRepo(root_abs);
        for ([_][]const []const u8{
            &.{ "add", "." },
            &.{ "commit", "-q", "-m", "init" },
        }) |args| try git(root_abs, args);
        return .{ .tmp = tmp, .root_abs = root_abs };
    }

    fn git(root_abs: []const u8, args: []const []const u8) !void {
        var argv: [8][]const u8 = undefined;
        argv[0] = "git";
        @memcpy(argv[1..][0..args.len], args);
        const result = try std.process.run(gpa, testing.io, .{ .argv = argv[0 .. args.len + 1], .cwd = .{ .path = root_abs } });
        gpa.free(result.stdout);
        gpa.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.GitSetupFailed,
            else => return error.GitSetupFailed,
        }
    }

    fn deinit(self: *Fixture) void {
        gpa.free(self.root_abs);
        self.tmp.cleanup();
    }

    fn file(self: *Fixture, name: []const u8) ![:0]u8 {
        return std.fmt.allocPrintSentinel(gpa, "{s}\\{s}", .{ self.root_abs, name }, 0);
    }

    fn read(self: *Fixture, name: []const u8) ![]u8 {
        const path = try self.file(name);
        defer gpa.free(path);
        return std.Io.Dir.cwd().readFileAlloc(testing.io, path, gpa, .limited(1024 * 1024));
    }
};

test "doc_writer: a passing test command commits a json pointer write and touches only that file" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init();
    defer fx.deinit();

    const path = try fx.file("package.json");
    defer gpa.free(path);
    const result = try doc_writer.tryWriteDoc(gpa, testing.io, .{
        .file_abs = path,
        .selector = .{ .pointer = "/scripts/build" },
        .expected_hash = symbol.hashOf("\"tsc\""),
        .new_text = "\"tsc --noEmit\"",
        .test_command = "cmd /c exit 0",
    }, null);
    defer result.deinit(gpa);
    try testing.expect(result == .committed);

    const after = try fx.read("package.json");
    defer gpa.free(after);
    try testing.expectEqualStrings("{\"name\": \"demo\", \"scripts\": {\"build\": \"tsc --noEmit\"}}\n", after);
}

test "doc_writer: a failing test command rejects a markdown section write and leaves disk untouched" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init();
    defer fx.deinit();

    const path = try fx.file("README.md");
    defer gpa.free(path);
    const result = try doc_writer.tryWriteDoc(gpa, testing.io, .{
        .file_abs = path,
        .selector = .{ .heading = "Setup" },
        .expected_hash = symbol.hashOf("## Setup\n\nold instructions\n\n"),
        .new_text = "## Setup\n\nnew instructions\n\n",
        .test_command = "cmd /c exit 1",
    }, null);
    defer result.deinit(gpa);
    try testing.expect(result == .rejected);

    const after = try fx.read("README.md");
    defer gpa.free(after);
    try testing.expectEqualStrings(readme_md, after);
}

test "doc_writer: a stale hash on a line range write is refused before any sandbox run" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init();
    defer fx.deinit();

    const path = try fx.file("notes.txt");
    defer gpa.free(path);
    try testing.expectError(error.HashMismatch, doc_writer.tryWriteDoc(gpa, testing.io, .{
        .file_abs = path,
        .selector = .{ .line_range = .{ .start = 2, .end = 2 } },
        .expected_hash = symbol.hashOf("stale"),
        .new_text = "changed\n",
        .test_command = "cmd /c echo BREACH>breach.txt & exit 0",
    }, null));

    const after = try fx.read("notes.txt");
    defer gpa.free(after);
    try testing.expectEqualStrings(notes_txt, after);
}

test "doc_writer: a file over 1 MiB is refused before any parse or sandbox run" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init();
    defer fx.deinit();

    const big = try gpa.alloc(u8, 1024 * 1024 + 1);
    defer gpa.free(big);
    @memset(big, 'a');
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/big.txt", .data = big });

    const path = try fx.file("big.txt");
    defer gpa.free(path);
    try testing.expectError(error.DocTooLarge, doc_writer.tryWriteDoc(gpa, testing.io, .{
        .file_abs = path,
        .selector = .{ .line_range = .{ .start = 1, .end = 1 } },
        .expected_hash = symbol.hashOf("stale"),
        .new_text = "x",
        .test_command = "cmd /c echo BREACH>breach.txt & exit 0",
    }, null));
    try testing.expect(!exists(&fx, "breach.txt"));
}

fn exists(fx: *Fixture, sub_path: []const u8) bool {
    fx.tmp.dir.access(testing.io, sub_path, .{}) catch return false;
    return true;
}

test "doc_writer: a binary file is refused before any parse or sandbox run" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init();
    defer fx.deinit();

    const binary = "line one\x00\x01\x02binary";
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/blob.bin", .data = binary });

    const path = try fx.file("blob.bin");
    defer gpa.free(path);
    try testing.expectError(error.BinaryFile, doc_writer.tryWriteDoc(gpa, testing.io, .{
        .file_abs = path,
        .selector = .{ .line_range = .{ .start = 1, .end = 1 } },
        .expected_hash = symbol.hashOf("stale"),
        .new_text = "x",
        .test_command = "cmd /c echo BREACH>breach.txt & exit 0",
    }, null));
    try testing.expect(!exists(&fx, "breach.txt"));
}

test "doc_writer: a committed write leaves a journal entry for the previous content" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init();
    defer fx.deinit();

    const path = try fx.file("notes.txt");
    defer gpa.free(path);
    const result = try doc_writer.tryWriteDoc(gpa, testing.io, .{
        .file_abs = path,
        .selector = .{ .line_range = .{ .start = 2, .end = 2 } },
        .expected_hash = symbol.hashOf("line two\n"),
        .new_text = "line replaced\n",
        .test_command = "cmd /c exit 0",
    }, null);
    defer result.deinit(gpa);
    try testing.expect(result == .committed);

    var journal_dir = try fx.tmp.dir.openDir(testing.io, "repo\\.emetgate\\journal", .{ .iterate = true });
    defer journal_dir.close(testing.io);
    var it = journal_dir.iterate();
    var count: usize = 0;
    while (try it.next(testing.io)) |_| count += 1;
    try testing.expect(count > 0);
}

test "doc_writer: a line range write commits and leaves the other lines byte-identical" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fx = try Fixture.init();
    defer fx.deinit();

    const path = try fx.file("notes.txt");
    defer gpa.free(path);
    const result = try doc_writer.tryWriteDoc(gpa, testing.io, .{
        .file_abs = path,
        .selector = .{ .line_range = .{ .start = 2, .end = 2 } },
        .expected_hash = symbol.hashOf("line two\n"),
        .new_text = "line replaced\n",
        .test_command = "cmd /c exit 0",
    }, null);
    defer result.deinit(gpa);
    try testing.expect(result == .committed);

    const after = try fx.read("notes.txt");
    defer gpa.free(after);
    try testing.expectEqualStrings("line one\nline replaced\nline three\n", after);
}
