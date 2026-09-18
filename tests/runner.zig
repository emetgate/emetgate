const std = @import("std");
const builtin = @import("builtin");
const runner = @import("../src/platform/runner.zig");
const symbol = @import("../src/engine/symbol.zig");
const sandbox = @import("../src/platform/sandbox.zig");
const memory = @import("../src/platform/memory.zig");
const Runtime = @import("../src/engine/runtime.zig").Runtime;
const Snapshot = @import("../src/engine/loader.zig").Snapshot;

const Allocator = std.mem.Allocator;
const Edit = runner.Edit;
const Gate = runner.Gate;
const chooseGate = runner.chooseGate;
const resolveTestCommand = runner.resolveTestCommand;
const resolveTypecheckCommand = runner.resolveTypecheckCommand;
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
        .expected_hash = .{ .present = hash },
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
        .expected_hash = .{ .present = hash },
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
        .expected_hash = .{ .present = hash },
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
        .expected_hash = .{ .present = hash },
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
        .expected_hash = .{ .present = hash },
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
        .expected_hash = .{ .present = symbol.hashOf("stale") },
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
        .expected_hash = .{ .present = hash },
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

test "typecheck: a failing typecheck rejects before the tests run and leaves disk untouched" {
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
        .expected_hash = .{ .present = hash },
        .new_body = "{\n  return a - b;\n}",
        .test_command = "exit 0",
        .typecheck_command = "exit 2",
    });
    defer result.deinit(testing.allocator);
    try testing.expect(result == .typecheck_failed);

    const on_disk = try repo.read();
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(Repo.source, on_disk);
}

test "typecheck: it checks the patched shadow copy and only then runs the test command" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const typecheck = "findstr a-b src\\math.ts";
    const Case = struct { body: []const u8, test_command: []const u8, expected: std.meta.Tag(runner.Result) };
    const cases = [_]Case{
        .{ .body = "{\n  return a*b;\n}", .test_command = "exit 0", .expected = .typecheck_failed },
        .{ .body = "{\n  return a-b;\n}", .test_command = "exit 1", .expected = .rejected },
        .{ .body = "{\n  return a-b;\n}", .test_command = "exit 0", .expected = .committed },
    };
    for (cases) |c| {
        errdefer std.debug.print("case body={s} test={s}\n", .{ c.body, c.test_command });
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
            .expected_hash = .{ .present = hash },
            .new_body = c.body,
            .test_command = c.test_command,
            .typecheck_command = typecheck,
        });
        defer result.deinit(testing.allocator);
        try testing.expectEqual(c.expected, std.meta.activeTag(result));
    }
}

test "typecheck: a failing typecheck rejects a whole batch and leaves disk untouched" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);
    const hash = try hashOfRef(testing.allocator, testing.io, runtime, file, "add");

    const edits = [_]runner.Edit{.{ .file_abs = file, .ref_text = "add", .expected_hash = hash, .new_body = "{\n  return a - b;\n}" }};
    const result = try tryMutateBatch(testing.allocator, testing.io, runtime, .{
        .edits = &edits,
        .test_command = "exit 0",
        .typecheck_command = "exit 2",
    });
    defer result.deinit(testing.allocator);
    try testing.expect(result == .typecheck_failed);

    const on_disk = try repo.read();
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(Repo.source, on_disk);
}

test "typecheck command: the flag wins, an untrusted repo config is ignored, a trusted one is read" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.emetgaterc.json", .data = "{\"test_cmd\":\"exit 0\",\"typecheck_cmd\":\"tsc --noEmit\"}" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);

    const given = (try resolveTypecheckCommand(testing.allocator, testing.io, file, "npx tsc", false)).?;
    defer testing.allocator.free(given);
    try testing.expectEqualStrings("npx tsc", given);

    try testing.expect((try resolveTypecheckCommand(testing.allocator, testing.io, file, "", false)) == null);

    const trusted = (try resolveTypecheckCommand(testing.allocator, testing.io, file, "", true)).?;
    defer testing.allocator.free(trusted);
    try testing.expectEqualStrings("tsc --noEmit", trusted);

    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.emetgaterc.json", .data = "{\"test_cmd\":\"exit 0\",\"typecheck_cmd\":\"\"}" });
    try testing.expect((try resolveTypecheckCommand(testing.allocator, testing.io, file, "", true)) == null);
}

const commented_body = "{\n  // why\n  return a - b;\n}";
const clean_body = "{\n  return a - b;\n}";

fn tryAdd(repo: *Repo, runtime: *Runtime, body: []const u8, test_command: []const u8) !runner.Result {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);
    const hash = try hashOfRef(testing.allocator, testing.io, runtime, file, "add");
    return tryMutate(testing.allocator, testing.io, runtime, .{
        .file_abs = file,
        .ref_text = "add",
        .expected_hash = .{ .present = hash },
        .new_body = body,
        .test_command = test_command,
    });
}

fn expectPristineRepo(repo: *Repo) !void {
    const on_disk = try repo.read();
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(Repo.source, on_disk);
}

test "rules: an enforced no_comment rule rejects a commented body before the tests run" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const id = try memory.remember(testing.allocator, testing.io, repo.root_abs, .global, "no comments", true, "no_comment");
    defer testing.allocator.free(id);

    const result = try tryAdd(&repo, runtime, commented_body, "exit 1");
    defer result.deinit(testing.allocator);
    try testing.expect(result == .rule_violation);
    const violations = result.rule_violation.violations;
    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqualStrings(id, violations[0].rule);
    try testing.expectEqualStrings("no_comment", violations[0].check);
    try testing.expectEqualStrings("// why", violations[0].text);
    try testing.expectEqualStrings("src\\math.ts", violations[0].file);
    try testing.expectEqual(@as(u32, 2), violations[0].line);
    try testing.expectEqual(@as(u32, 3), violations[0].col);
    try expectPristineRepo(&repo);
}

test "rules: a clean body still commits under an enforced rule" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const id = try memory.remember(testing.allocator, testing.io, repo.root_abs, .global, "no comments", true, "no_comment");
    defer testing.allocator.free(id);

    const result = try tryAdd(&repo, runtime, clean_body, "exit 0");
    defer result.deinit(testing.allocator);
    try testing.expect(result == .committed);
}

test "rules: an enforced forbid rule rejects a body containing its text before the tests run" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const id = try memory.remember(testing.allocator, testing.io, repo.root_abs, .global, "no Math.abs", true, "forbid:Math.abs");
    defer testing.allocator.free(id);

    const result = try tryAdd(&repo, runtime, "{\n  return Math.abs(a) - Math.abs(b);\n}", "exit 0");
    defer result.deinit(testing.allocator);
    try testing.expect(result == .rule_violation);
    const violations = result.rule_violation.violations;
    try testing.expectEqual(@as(usize, 2), violations.len);
    for (violations, [_]u32{ 10, 24 }) |v, col| {
        try testing.expectEqualStrings(id, v.rule);
        try testing.expectEqualStrings("forbid:Math.abs", v.check);
        try testing.expectEqualStrings("Math.abs", v.text);
        try testing.expectEqual(@as(u32, 2), v.line);
        try testing.expectEqual(col, v.col);
    }
    try expectPristineRepo(&repo);
}

test "rules: a body without the forbidden text still commits under an enforced forbid rule" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const id = try memory.remember(testing.allocator, testing.io, repo.root_abs, .global, "no Math.abs", true, "forbid:Math.abs");
    defer testing.allocator.free(id);

    const result = try tryAdd(&repo, runtime, clean_body, "exit 0");
    defer result.deinit(testing.allocator);
    try testing.expect(result == .committed);
}

const sub_body = "export function sub(a: number, b: number): number {\n  return a - b;\n}";

fn tryInsert(repo: *Repo, runtime: *Runtime, ref_text: []const u8, body: []const u8, test_command: []const u8) !runner.Result {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    return tryMutate(testing.allocator, testing.io, runtime, .{
        .file_abs = try repo.filePath(&buf),
        .ref_text = ref_text,
        .expected_hash = .absent,
        .new_body = body,
        .test_command = test_command,
    });
}

test "absent: a new top-level symbol is appended, committed, parses and joins the symbol table" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);
    const add_before = try hashOfRef(testing.allocator, testing.io, runtime, file, "add");

    const result = try tryInsert(&repo, runtime, "sub", sub_body, "exit 0");
    defer result.deinit(testing.allocator);
    try testing.expect(result == .committed);

    const on_disk = try repo.read();
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(Repo.source ++ "\n" ++ sub_body ++ "\n", on_disk);
    try testing.expectEqual(result.committed, try hashOfRef(testing.allocator, testing.io, runtime, file, "sub"));
    try testing.expectEqual(add_before, try hashOfRef(testing.allocator, testing.io, runtime, file, "add"));
}

test "absent: a symbol that already exists is refused and the repository is untouched" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    try testing.expectError(error.SymbolExists, tryInsert(&repo, runtime, "add", "export function add(a: number, b: number): number {\n  return 0;\n}", "exit 0"));
    try expectPristineRepo(&repo);
}

test "absent: a proposed name that differs from the body's is refused and the repository is untouched" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    try testing.expectError(error.SymbolNameMismatch, tryInsert(&repo, runtime, "subtract", sub_body, "exit 0"));
    try expectPristineRepo(&repo);
}

test "absent: an inserted body that breaks a forbid rule is rejected even when the tests pass" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const id = try memory.remember(testing.allocator, testing.io, repo.root_abs, .global, "no Math.abs", true, "forbid:Math.abs");
    defer testing.allocator.free(id);

    const result = try tryInsert(&repo, runtime, "dist", "export function dist(a: number, b: number): number {\n  return Math.abs(a - b);\n}", "exit 0");
    defer result.deinit(testing.allocator);
    try testing.expect(result == .rule_violation);
    const violations = result.rule_violation.violations;
    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqualStrings(id, violations[0].rule);
    try testing.expectEqualStrings("Math.abs", violations[0].text);
    try testing.expectEqual(@as(u32, 6), violations[0].line);
    try testing.expectEqual(@as(u32, 10), violations[0].col);
    try expectPristineRepo(&repo);
}

test "absent: an insertion whose tests fail leaves nothing on disk" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    const result = try tryInsert(&repo, runtime, "sub", sub_body, "exit 1");
    defer result.deinit(testing.allocator);
    try testing.expect(result == .rejected);
    try expectPristineRepo(&repo);
    try testing.expectError(error.FileNotFound, repo.tmp.dir.access(testing.io, "repo/.emetgate", .{}));
}

test "absent: a file that does not end with a newline is refused and left byte for byte" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const unterminated = Repo.source[0 .. Repo.source.len - 1];
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/math.ts", .data = unterminated });

    try testing.expectError(error.MissingTrailingNewline, tryInsert(&repo, runtime, "sub", sub_body, "exit 0"));
    const on_disk = try repo.read();
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(unterminated, on_disk);
}

const mul_body = "export function mul(a: number, b: number): number {\n  return a * b;\n}";
const sees_mul = "if exist src\\mul.ts (exit 0) else (exit 1)";

fn newFilePath(repo: *Repo, rel: []const u8) ![]u8 {
    return std.fmt.allocPrint(testing.allocator, "{s}\\{s}", .{ repo.root_abs, rel });
}

fn tryNewFile(repo: *Repo, runtime: *Runtime, rel: []const u8, ref_text: []const u8, body: []const u8, test_command: []const u8) !runner.Result {
    const file = try newFilePath(repo, rel);
    defer testing.allocator.free(file);
    return tryMutate(testing.allocator, testing.io, runtime, .{
        .file_abs = file,
        .ref_text = ref_text,
        .expected_hash = .absent,
        .new_body = body,
        .test_command = test_command,
    });
}

fn indexed(repo: *Repo, rel: []const u8) !bool {
    const result = try std.process.run(testing.allocator, testing.io, .{ .argv = &.{ "git", "ls-files", "--error-unmatch", "--", rel }, .cwd = .{ .path = repo.root_abs } });
    testing.allocator.free(result.stdout);
    testing.allocator.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn expectNoNewFile(repo: *Repo, rel: []const u8) !void {
    const sub = try std.fmt.allocPrint(testing.allocator, "repo/{s}", .{rel});
    defer testing.allocator.free(sub);
    try testing.expectError(error.FileNotFound, repo.tmp.dir.access(testing.io, sub, .{}));
    try testing.expect(!try indexed(repo, rel));
    try expectPristineRepo(repo);
}

test "new file: absent on a missing file creates it, the shadow sees it, and it is committed, parsed, listed and indexed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    const result = try tryNewFile(&repo, runtime, "src/mul.ts", "mul", mul_body, sees_mul);
    defer result.deinit(testing.allocator);
    try testing.expect(result == .committed);

    const on_disk = try repo.tmp.dir.readFileAlloc(testing.io, "repo/src/mul.ts", testing.allocator, .unlimited);
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(mul_body ++ "\n", on_disk);
    const file = try newFilePath(&repo, "src/mul.ts");
    defer testing.allocator.free(file);
    try testing.expectEqual(result.committed, try hashOfRef(testing.allocator, testing.io, runtime, file, "mul"));
    try testing.expect(try indexed(&repo, "src/mul.ts"));
    try expectPristineRepo(&repo);
}

test "new file: a later proposal to another file runs in a shadow that contains the created file" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    const created = try tryNewFile(&repo, runtime, "src/mul.ts", "mul", mul_body, "exit 0");
    defer created.deinit(testing.allocator);
    try testing.expect(created == .committed);

    const next = try tryAdd(&repo, runtime, clean_body, sees_mul);
    defer next.deinit(testing.allocator);
    errdefer if (next == .rejected) std.debug.print("second proposal: {t}\n", .{next.rejected.outcome});
    try testing.expect(next == .committed);
}

test "new file: absent on a file that already exists appends instead of overwriting, and jailNew refuses it" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    const result = try tryNewFile(&repo, runtime, "src/math.ts", "mul", mul_body, "exit 0");
    defer result.deinit(testing.allocator);
    try testing.expect(result == .committed);
    const on_disk = try repo.read();
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(Repo.source ++ "\n" ++ mul_body ++ "\n", on_disk);

    const file = try newFilePath(&repo, "src/math.ts");
    defer testing.allocator.free(file);
    try testing.expectError(error.FileExists, runner.jailNew(testing.allocator, testing.io, repo.root_abs, file));
}

test "new file: a missing directory is refused and nothing is created" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();

    const file = try newFilePath(&repo, "src/nested/mul.ts");
    defer testing.allocator.free(file);
    try testing.expectError(error.ParentDirectoryMissing, runner.jailNew(testing.allocator, testing.io, repo.root_abs, file));
    try testing.expectError(error.FileNotFound, repo.tmp.dir.access(testing.io, "repo/src/nested", .{}));
    try expectPristineRepo(&repo);
}

test "new file: paths inside .git and .emetgate, or with an unsafe name, are refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.tmp.dir.createDirPath(testing.io, "repo/.emetgate");

    for ([_][]const u8{ ".git/mul.ts", ".emetgate/mul.ts" }) |rel| {
        errdefer std.debug.print("accepted: {s}\n", .{rel});
        const file = try newFilePath(&repo, rel);
        defer testing.allocator.free(file);
        try testing.expectError(error.InternalPath, runner.jailNew(testing.allocator, testing.io, repo.root_abs, file));
    }
    for ([_][]const u8{ "src/nul.ts", "src/mul.ts.", "src/MUL~1.ts", "src/a:b.ts" }) |rel| {
        errdefer std.debug.print("accepted: {s}\n", .{rel});
        const file = try newFilePath(&repo, rel);
        defer testing.allocator.free(file);
        try testing.expectError(error.InvalidPath, runner.jailNew(testing.allocator, testing.io, repo.root_abs, file));
    }
    try testing.expectError(error.FileNotFound, repo.tmp.dir.access(testing.io, "repo/.git/mul.ts", .{}));
    try testing.expectError(error.FileNotFound, repo.tmp.dir.access(testing.io, "repo/.emetgate/mul.ts", .{}));
}

test "new file: a path ignored by .gitignore is refused before anything runs" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.gitignore", .data = "*.gen.ts\n" });

    try testing.expectError(error.IgnoredPath, tryNewFile(&repo, runtime, "src/mul.gen.ts", "mul", mul_body, "exit 0"));
    try testing.expectError(error.FileNotFound, repo.tmp.dir.access(testing.io, "repo/src/mul.gen.ts", .{}));
    try expectPristineRepo(&repo);
}

test "new file: an extension with no language profile is refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    try testing.expectError(error.UnsupportedLanguage, tryNewFile(&repo, runtime, "src/mul.py", "mul", mul_body, "exit 0"));
    try expectNoNewFile(&repo, "src/mul.py");
}

test "new file: a creation whose tests fail leaves no file on disk and nothing in the index" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    const result = try tryNewFile(&repo, runtime, "src/mul.ts", "mul", mul_body, "exit 1");
    defer result.deinit(testing.allocator);
    try testing.expect(result == .rejected);
    try expectNoNewFile(&repo, "src/mul.ts");
    try testing.expectError(error.FileNotFound, repo.tmp.dir.access(testing.io, "repo/.emetgate", .{}));
}

test "new file: a body that breaks a forbid rule is rejected even when the tests pass" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const id = try memory.remember(testing.allocator, testing.io, repo.root_abs, .global, "no Math.abs", true, "forbid:Math.abs");
    defer testing.allocator.free(id);

    const result = try tryNewFile(&repo, runtime, "src/dist.ts", "dist", "export function dist(a: number, b: number): number {\n  return Math.abs(a - b);\n}", "exit 0");
    defer result.deinit(testing.allocator);
    try testing.expect(result == .rule_violation);
    try testing.expectEqualStrings("Math.abs", result.rule_violation.violations[0].text);
    try testing.expectEqual(@as(u32, 2), result.rule_violation.violations[0].line);
    try expectNoNewFile(&repo, "src/dist.ts");
}

test "new file: when git add fails the file stays on disk with the written body and the error is WrittenButNotIndexed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.git/index.lock", .data = "" });
    defer repo.tmp.dir.deleteFile(testing.io, "repo/.git/index.lock") catch {};

    try testing.expectError(error.WrittenButNotIndexed, tryNewFile(&repo, runtime, "src/mul.ts", "mul", mul_body, "exit 0"));
    const on_disk = try repo.tmp.dir.readFileAlloc(testing.io, "repo/src/mul.ts", testing.allocator, .unlimited);
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(mul_body ++ "\n", on_disk);
    try repo.tmp.dir.deleteFile(testing.io, "repo/.git/index.lock");
    try testing.expect(!try indexed(&repo, "src/mul.ts"));
}

test "rules: unenforced, checkless and forgotten rules never block an edit" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const unenforced = try memory.remember(testing.allocator, testing.io, repo.root_abs, .global, "prefer no comments", false, "no_comment");
    defer testing.allocator.free(unenforced);
    const checkless = try memory.remember(testing.allocator, testing.io, repo.root_abs, .global, "be kind", true, null);
    defer testing.allocator.free(checkless);
    const forgotten = try memory.remember(testing.allocator, testing.io, repo.root_abs, .global, "no comments", true, "no_comment");
    defer testing.allocator.free(forgotten);
    try memory.forget(testing.allocator, testing.io, repo.root_abs, forgotten);

    const result = try tryAdd(&repo, runtime, commented_body, "exit 0");
    defer result.deinit(testing.allocator);
    try testing.expect(result == .committed);
}

test "rules: an unknown check in the ledger fails closed and leaves disk untouched" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const id = try memory.remember(testing.allocator, testing.io, repo.root_abs, .global, "mystery", true, "no_such_check");
    defer testing.allocator.free(id);

    try testing.expectError(error.UnknownCheck, tryAdd(&repo, runtime, clean_body, "exit 0"));
    try expectPristineRepo(&repo);
}

test "rules: one violating edit rejects the whole batch and leaves disk untouched" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const id = try memory.remember(testing.allocator, testing.io, repo.root_abs, .global, "no comments", true, "no_comment");
    defer testing.allocator.free(id);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);
    const hash = try hashOfRef(testing.allocator, testing.io, runtime, file, "add");

    const edits = [_]runner.Edit{.{ .file_abs = file, .ref_text = "add", .expected_hash = hash, .new_body = commented_body }};
    const result = try tryMutateBatch(testing.allocator, testing.io, runtime, .{ .edits = &edits, .test_command = "exit 0" });
    defer result.deinit(testing.allocator);
    try testing.expect(result == .rule_violation);
    try expectPristineRepo(&repo);
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
        .expected_hash = .{ .present = hash },
        .new_body = "{\n  return a - b;\n}",
        .test_command = "exit 0",
    });
    result.deinit(testing.allocator);

    try testing.expectError(error.FileNotFound, repo.tmp.dir.access(testing.io, "repo/.emetgate", .{}));
}
