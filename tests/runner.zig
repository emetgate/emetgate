const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const builtin = @import("builtin");
const runner = @import("emetgate").runner;
const symbol = @import("emetgate").symbol;
const sandbox = @import("emetgate").sandbox;
const wire = @import("emetgate").wire;
const memory = @import("emetgate").memory;
const Runtime = @import("emetgate").runtime.Runtime;
const Snapshot = @import("emetgate").loader.Snapshot;

const Allocator = std.mem.Allocator;
const Edit = runner.Edit;
const Gate = runner.Gate;
const chooseGate = runner.chooseGate;
const resolveTestCommand = runner.resolveTestCommand;
const resolveTypecheckCommand = runner.resolveTypecheckCommand;
const tryMutate = runner.tryMutate;
const tryMutateBatch = runner.tryMutateBatch;

const support = @import("runner_support.zig");
const Repo = support.Repo;
const TwoFile = support.TwoFile;
const hashOfRef = support.hashOfRef;
const crash_command = support.crash_command;

const testing = std.testing;

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
    errdefer diagnostics.printResult(result);
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
    errdefer diagnostics.printResult(result);
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

    errdefer diagnostics.printResult(result);
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
    errdefer diagnostics.printResult(result);
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
        errdefer diagnostics.printResult(result);
        try testing.expectEqual(c.expected, std.meta.activeTag(result));
    }
}

fn expectCrash(result: anytype, stage: std.meta.Tag(@TypeOf(result)), reason: []const u8) !void {
    errdefer diagnostics.printResult(result);
    try testing.expectEqual(stage, std.meta.activeTag(result));
    const report = switch (result) {
        .rejected, .typecheck_failed => |report| report,
        .committed, .rule_violation, .rule_check_failed => unreachable,
    };
    try testing.expectEqual(sandbox.Outcome{ .crashed = 0xC0000142 }, report.outcome);
    try testing.expectEqualStrings(reason, if (stage == .typecheck_failed) wire.typecheckReason(report) else wire.rejectionReason(report));
}

test "crash: a typecheck that crashes rejects as typecheck_crashed and leaves disk untouched" {
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
        .typecheck_command = crash_command,
    });
    defer result.deinit(testing.allocator);
    try expectCrash(result, .typecheck_failed, "typecheck_crashed");

    const on_disk = try repo.read();
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(Repo.source, on_disk);
}

test "crash: a test command that crashes rejects as test_crashed and leaves disk untouched" {
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
        .test_command = crash_command,
        .typecheck_command = "exit 0",
    });
    defer result.deinit(testing.allocator);
    try expectCrash(result, .rejected, "test_crashed");

    const on_disk = try repo.read();
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(Repo.source, on_disk);
}

test "crash: a typecheck that crashes rejects a whole batch as typecheck_crashed and leaves disk untouched" {
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
        .typecheck_command = crash_command,
    });
    defer result.deinit(testing.allocator);
    try expectCrash(result, .typecheck_failed, "typecheck_crashed");

    const on_disk = try repo.read();
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(Repo.source, on_disk);
}

test "crash: a test command that crashes rejects a whole batch as test_crashed and leaves disk untouched" {
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
        .test_command = crash_command,
    });
    defer result.deinit(testing.allocator);
    try expectCrash(result, .rejected, "test_crashed");

    const on_disk = try repo.read();
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(Repo.source, on_disk);
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
