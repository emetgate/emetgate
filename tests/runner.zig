const std = @import("std");
const builtin = @import("builtin");
const runner = @import("../src/platform/runner.zig");
const symbol = @import("../src/engine/symbol.zig");
const sandbox = @import("../src/platform/sandbox.zig");
const Runtime = @import("../src/engine/runtime.zig").Runtime;
const Snapshot = @import("../src/engine/loader.zig").Snapshot;

const Allocator = std.mem.Allocator;
const Edit = runner.Edit;
const Gate = runner.Gate;
const chooseGate = runner.chooseGate;
const resolveTestCommand = runner.resolveTestCommand;
const tryMutate = runner.tryMutate;
const tryMutateBatch = runner.tryMutateBatch;

const testing = std.testing;

const Repo = struct {
    tmp: testing.TmpDir,
    root_abs: [:0]u8,

    const source = "export function add(a: number, b: number): number {\n  return a + b;\n}\n";

    fn init() !Repo {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo/src");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/math.ts", .data = source });
        const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", testing.allocator);
        errdefer testing.allocator.free(root_abs);

        try git(root_abs, &.{ "init", "-q" });
        try git(root_abs, &.{ "config", "user.email", "t@t" });
        try git(root_abs, &.{ "config", "user.name", "t" });
        try git(root_abs, &.{ "add", "." });
        try git(root_abs, &.{ "commit", "-q", "-m", "init" });
        return .{ .tmp = tmp, .root_abs = root_abs };
    }

    fn git(root_abs: []const u8, args: []const []const u8) !void {
        var argv: [8][]const u8 = undefined;
        argv[0] = "git";
        @memcpy(argv[1..][0..args.len], args);
        const result = try std.process.run(testing.allocator, testing.io, .{ .argv = argv[0 .. args.len + 1], .cwd = .{ .path = root_abs } });
        testing.allocator.free(result.stdout);
        testing.allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.GitSetupFailed,
            else => return error.GitSetupFailed,
        }
    }

    fn deinit(self: *Repo) void {
        testing.allocator.free(self.root_abs);
        self.tmp.cleanup();
    }

    fn filePath(self: *Repo, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}\\src\\math.ts", .{self.root_abs});
    }

    fn read(self: *Repo) ![]u8 {
        return self.tmp.dir.readFileAlloc(testing.io, "repo/src/math.ts", testing.allocator, .unlimited);
    }
};

fn hashOfRef(gpa: Allocator, io: std.Io, runtime: *Runtime, file_abs: []const u8, ref_text: []const u8) !symbol.Hash {
    const snapshot = try Snapshot.load(runtime, io, .cwd(), file_abs);
    defer snapshot.destroy();
    const table = try snapshot.symbols();
    const ref = try symbol.Ref.parse(gpa, ref_text);
    defer ref.deinit(gpa);
    return (try table.resolve(ref)).hash;
}

const TwoFile = struct {
    tmp: testing.TmpDir,
    root_abs: [:0]u8,

    const a_src = "export function add(a: number, b: number): number {\n  return a + b;\n}\n";
    const b_src = "export function twice(x: number): number {\n  return x + x;\n}\n";

    fn init() !TwoFile {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo/src");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/a.ts", .data = a_src });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/b.ts", .data = b_src });
        const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", testing.allocator);
        errdefer testing.allocator.free(root_abs);
        try Repo.git(root_abs, &.{ "init", "-q" });
        try Repo.git(root_abs, &.{ "config", "user.email", "t@t" });
        try Repo.git(root_abs, &.{ "config", "user.name", "t" });
        try Repo.git(root_abs, &.{ "add", "." });
        try Repo.git(root_abs, &.{ "commit", "-q", "-m", "init" });
        return .{ .tmp = tmp, .root_abs = root_abs };
    }

    fn deinit(self: *TwoFile) void {
        testing.allocator.free(self.root_abs);
        self.tmp.cleanup();
    }

    fn pathA(self: *TwoFile, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}\\src\\a.ts", .{self.root_abs});
    }
    fn pathB(self: *TwoFile, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}\\src\\b.ts", .{self.root_abs});
    }
    fn readA(self: *TwoFile) ![]u8 {
        return self.tmp.dir.readFileAlloc(testing.io, "repo/src/a.ts", testing.allocator, .unlimited);
    }
    fn readB(self: *TwoFile) ![]u8 {
        return self.tmp.dir.readFileAlloc(testing.io, "repo/src/b.ts", testing.allocator, .unlimited);
    }
};

test "a batch commits every file when the shared test passes" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try TwoFile.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    var buf_a: [std.fs.max_path_bytes]u8 = undefined;
    var buf_b: [std.fs.max_path_bytes]u8 = undefined;
    const file_a = try repo.pathA(&buf_a);
    const file_b = try repo.pathB(&buf_b);
    const hash_a = try hashOfRef(testing.allocator, testing.io, runtime, file_a, "add");
    const hash_b = try hashOfRef(testing.allocator, testing.io, runtime, file_b, "twice");

    const edits = [_]Edit{
        .{ .file_abs = file_a, .ref_text = "add", .expected_hash = hash_a, .new_body = "{ return a - b; }" },
        .{ .file_abs = file_b, .ref_text = "twice", .expected_hash = hash_b, .new_body = "{ return x * 2; }" },
    };
    const result = try tryMutateBatch(testing.allocator, testing.io, runtime, .{ .edits = &edits, .test_command = "cmd /c exit 0" });
    defer result.deinit(testing.allocator);
    try testing.expect(result == .committed);

    const a = try repo.readA();
    defer testing.allocator.free(a);
    const b = try repo.readB();
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("export function add(a: number, b: number): number { return a - b; }\n", a);
    try testing.expectEqualStrings("export function twice(x: number): number { return x * 2; }\n", b);
}

test "a batch with one stale hash writes nothing (pre-validation is fail-closed)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try TwoFile.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    var buf_a: [std.fs.max_path_bytes]u8 = undefined;
    var buf_b: [std.fs.max_path_bytes]u8 = undefined;
    const file_a = try repo.pathA(&buf_a);
    const file_b = try repo.pathB(&buf_b);
    const hash_a = try hashOfRef(testing.allocator, testing.io, runtime, file_a, "add");

    const edits = [_]Edit{
        .{ .file_abs = file_a, .ref_text = "add", .expected_hash = hash_a, .new_body = "{ return a - b; }" },
        .{ .file_abs = file_b, .ref_text = "twice", .expected_hash = symbol.hashOf("stale"), .new_body = "{ return x * 2; }" },
    };
    try testing.expectError(error.HashMismatch, tryMutateBatch(testing.allocator, testing.io, runtime, .{ .edits = &edits, .test_command = "cmd /c exit 0" }));

    const a = try repo.readA();
    defer testing.allocator.free(a);
    const b = try repo.readB();
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(TwoFile.a_src, a);
    try testing.expectEqualStrings(TwoFile.b_src, b);
}

test "a batch cannot edit the same file twice" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try TwoFile.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    var buf_a: [std.fs.max_path_bytes]u8 = undefined;
    const file_a = try repo.pathA(&buf_a);
    const hash_a = try hashOfRef(testing.allocator, testing.io, runtime, file_a, "add");

    const edits = [_]Edit{
        .{ .file_abs = file_a, .ref_text = "add", .expected_hash = hash_a, .new_body = "{ return a - b; }" },
        .{ .file_abs = file_a, .ref_text = "add", .expected_hash = hash_a, .new_body = "{ return b - a; }" },
    };
    try testing.expectError(error.DuplicateBatchFile, tryMutateBatch(testing.allocator, testing.io, runtime, .{ .edits = &edits, .test_command = "cmd /c exit 0" }));
}

test "a batch whose shared test fails writes nothing" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try TwoFile.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    var buf_a: [std.fs.max_path_bytes]u8 = undefined;
    var buf_b: [std.fs.max_path_bytes]u8 = undefined;
    const file_a = try repo.pathA(&buf_a);
    const file_b = try repo.pathB(&buf_b);
    const hash_a = try hashOfRef(testing.allocator, testing.io, runtime, file_a, "add");
    const hash_b = try hashOfRef(testing.allocator, testing.io, runtime, file_b, "twice");

    const edits = [_]Edit{
        .{ .file_abs = file_a, .ref_text = "add", .expected_hash = hash_a, .new_body = "{ return a - b; }" },
        .{ .file_abs = file_b, .ref_text = "twice", .expected_hash = hash_b, .new_body = "{ return x * 2; }" },
    };
    const result = try tryMutateBatch(testing.allocator, testing.io, runtime, .{ .edits = &edits, .test_command = "cmd /c exit 1" });
    defer result.deinit(testing.allocator);
    try testing.expect(result == .rejected);

    const a = try repo.readA();
    defer testing.allocator.free(a);
    const b = try repo.readB();
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(TwoFile.a_src, a);
    try testing.expectEqualStrings(TwoFile.b_src, b);
}

test "gate: only BOUNDED with a scoped command reaches the scoped path" {
    try testing.expectEqual(Gate.scoped, chooseGate(.bounded, true));
    try testing.expectEqual(Gate.full, chooseGate(.bounded, false));
    try testing.expectEqual(Gate.full, chooseGate(.unbounded, true));
    try testing.expectEqual(Gate.full, chooseGate(.unbounded, false));
}

test "gate: a body-only change to an exported symbol runs the full command even with a scoped one" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);
    const hash = try hashOfRef(testing.allocator, testing.io, runtime, file, "add");

    const result = try tryMutate(testing.allocator, testing.io, runtime, .{
        .file_abs = file,
        .ref_text = "add",
        .expected_hash = hash,
        .new_body = "{\n  return a - b;\n}",
        .test_command = "exit 1",
        .test_scoped_cmd = "type {file}",
    });
    defer result.deinit(testing.allocator);
    try testing.expect(result == .rejected);

    const on_disk = try repo.read();
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(Repo.source, on_disk);
}

test "gate: a BOUNDED mutation runs the scoped command against {file}, not the full command" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/math.ts", .data = "function add(a: number, b: number): number {\n  return a + b;\n}\nadd(1, 2);\n" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);
    const hash = try hashOfRef(testing.allocator, testing.io, runtime, file, "add");

    const result = try tryMutate(testing.allocator, testing.io, runtime, .{
        .file_abs = file,
        .ref_text = "add",
        .expected_hash = hash,
        .new_body = "{\n  return a - b;\n}",
        .test_command = "exit 1",
        .test_scoped_cmd = "type {file}",
    });
    defer result.deinit(testing.allocator);
    try testing.expect(result == .committed);

    const on_disk = try repo.read();
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings("function add(a: number, b: number): number {\n  return a - b;\n}\nadd(1, 2);\n", on_disk);
}

test "gate: an empty test command aborts before touching disk" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);
    const hash = try hashOfRef(testing.allocator, testing.io, runtime, file, "add");

    try testing.expectError(error.NoTestCommand, tryMutate(testing.allocator, testing.io, runtime, .{
        .file_abs = file,
        .ref_text = "add",
        .expected_hash = hash,
        .new_body = "{ return a - b; }",
        .test_command = "",
        .test_scoped_cmd = "cmd /c exit 0",
    }));
    const on_disk = try repo.read();
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(Repo.source, on_disk);
}

test "a passing test commits the mutation to disk" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);
    const hash = try hashOfRef(testing.allocator, testing.io, runtime, file, "add");

    const result = try tryMutate(testing.allocator, testing.io, runtime, .{
        .file_abs = file,
        .ref_text = "add",
        .expected_hash = hash,
        .new_body = "{\n  return a - b;\n}",
        .test_command = "exit 0",
    });
    defer result.deinit(testing.allocator);

    try testing.expect(result == .committed);
    const on_disk = try repo.read();
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings("export function add(a: number, b: number): number {\n  return a - b;\n}\n", on_disk);
}

test "a failing test leaves the file on disk untouched" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);
    const hash = try hashOfRef(testing.allocator, testing.io, runtime, file, "add");

    const result = try tryMutate(testing.allocator, testing.io, runtime, .{
        .file_abs = file,
        .ref_text = "add",
        .expected_hash = hash,
        .new_body = "{\n  return a - b;\n}",
        .test_command = "exit 1",
    });
    defer result.deinit(testing.allocator);

    try testing.expect(result == .rejected);
    try testing.expectEqual(sandbox.Outcome{ .exited = 1 }, result.rejected.outcome);
    const on_disk = try repo.read();
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(Repo.source, on_disk);
}

test "a stale hash is refused before any test runs" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);

    try testing.expectError(error.HashMismatch, tryMutate(testing.allocator, testing.io, runtime, .{
        .file_abs = file,
        .ref_text = "add",
        .expected_hash = symbol.hashOf("stale"),
        .new_body = "{\n  return a - b;\n}",
        .test_command = "exit 0",
    }));
    const on_disk = try repo.read();
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(Repo.source, on_disk);
}

test "test command defaults from .emetgaterc.json when the caller omits it" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.emetgaterc.json", .data = "{\"test_cmd\":\"exit 0\"}" });
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);
    const hash = try hashOfRef(testing.allocator, testing.io, runtime, file, "add");

    const cmd = try resolveTestCommand(testing.allocator, testing.io, file, "", true);
    defer testing.allocator.free(cmd);
    try testing.expectEqualStrings("exit 0", cmd);

    const result = try tryMutate(testing.allocator, testing.io, runtime, .{
        .file_abs = file,
        .ref_text = "add",
        .expected_hash = hash,
        .new_body = "{\n  return a - b;\n}",
        .test_command = cmd,
    });
    defer result.deinit(testing.allocator);
    try testing.expect(result == .committed);
}

test "a repo config is untrusted by default and only honored with allow_repo_config" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.emetgaterc.json", .data = "{\"test_cmd\":\"exit 0\"}" });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);
    try testing.expectError(error.UntrustedRepoConfig, resolveTestCommand(testing.allocator, testing.io, file, "", false));

    const cmd = try resolveTestCommand(testing.allocator, testing.io, file, "", true);
    defer testing.allocator.free(cmd);
    try testing.expectEqualStrings("exit 0", cmd);
}

test "an explicit test command overrides an untrusted repo config" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.emetgaterc.json", .data = "{\"test_cmd\":\"exit 1\"}" });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);
    const cmd = try resolveTestCommand(testing.allocator, testing.io, file, "exit 0", false);
    defer testing.allocator.free(cmd);
    try testing.expectEqualStrings("exit 0", cmd);
}

test "a missing config with no test command is refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);
    try testing.expectError(error.NoTestCommand, resolveTestCommand(testing.allocator, testing.io, file, "", true));
}

test "no shadow workspace survives a run" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);
    const hash = try hashOfRef(testing.allocator, testing.io, runtime, file, "add");

    const result = try tryMutate(testing.allocator, testing.io, runtime, .{
        .file_abs = file,
        .ref_text = "add",
        .expected_hash = hash,
        .new_body = "{\n  return a - b;\n}",
        .test_command = "exit 0",
    });
    result.deinit(testing.allocator);

    try testing.expectError(error.FileNotFound, repo.tmp.dir.access(testing.io, "repo/.emetgate", .{}));
}
