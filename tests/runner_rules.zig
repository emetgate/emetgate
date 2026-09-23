const std = @import("std");
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
const printResult = support.printResult;
const crash_command = support.crash_command;

const testing = std.testing;

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
    const id = try memory.remember(testing.allocator, testing.io, repo.root_abs, .global, "no comments", true, "no_comment", null);
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
    const id = try memory.remember(testing.allocator, testing.io, repo.root_abs, .global, "no comments", true, "no_comment", null);
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
    const id = try memory.remember(testing.allocator, testing.io, repo.root_abs, .global, "no Math.abs", true, "forbid:Math.abs", null);
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
    const id = try memory.remember(testing.allocator, testing.io, repo.root_abs, .global, "no Math.abs", true, "forbid:Math.abs", null);
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
    const id = try memory.remember(testing.allocator, testing.io, repo.root_abs, .global, "no Math.abs", true, "forbid:Math.abs", null);
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
    const id = try memory.remember(testing.allocator, testing.io, repo.root_abs, .global, "no Math.abs", true, "forbid:Math.abs", null);
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
    const unenforced = try memory.remember(testing.allocator, testing.io, repo.root_abs, .global, "prefer no comments", false, "no_comment", null);
    defer testing.allocator.free(unenforced);
    const checkless = try memory.remember(testing.allocator, testing.io, repo.root_abs, .global, "be kind", true, null, null);
    defer testing.allocator.free(checkless);
    const forgotten = try memory.remember(testing.allocator, testing.io, repo.root_abs, .global, "no comments", true, "no_comment", null);
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
    const id = try memory.remember(testing.allocator, testing.io, repo.root_abs, .global, "mystery", true, "no_such_check", null);
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
    const id = try memory.remember(testing.allocator, testing.io, repo.root_abs, .global, "no comments", true, "no_comment", null);
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

fn tryAddUnder(where: []const u8) !runner.Result {
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const id = try memory.remember(testing.allocator, testing.io, repo.root_abs, .file, "no Math.abs", true, "forbid:Math.abs", where);
    defer testing.allocator.free(id);
    return tryAdd(&repo, runtime, "{\n  return Math.abs(a - b);\n}", "exit 0");
}

test "scope: a rule whose where names another file does not block the proposal" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const result = try tryAddUnder("src/other.ts");
    defer result.deinit(testing.allocator);
    try testing.expect(result == .committed);
}

test "scope: a rule whose where names the proposed file or its directory blocks the proposal" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    for ([_][]const u8{ "src/math.ts", "src/", "SRC/Math.ts" }) |where| {
        const result = try tryAddUnder(where);
        defer result.deinit(testing.allocator);
        try testing.expect(result == .rule_violation);
        try testing.expectEqualStrings("Math.abs", result.rule_violation.violations[0].text);
    }
}

test "scope: at the gate a where naming a missing file or symbol blocks nothing and raises nothing" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    for ([_][]const u8{ "src/deleted.ts", "src/math.ts#gone", "lib/" }) |where| {
        const result = try tryAddUnder(where);
        defer result.deinit(testing.allocator);
        try testing.expect(result == .committed);
    }
}

test "scope: a symbol-scoped rule blocks only a proposal to that symbol" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const other = try tryAddUnder("src/math.ts#sub");
    defer other.deinit(testing.allocator);
    try testing.expect(other == .committed);

    const same = try tryAddUnder("src/math.ts#add");
    defer same.deinit(testing.allocator);
    try testing.expect(same == .rule_violation);
}

fn batchUnder(where: []const u8) !runner.BatchResult {
    var repo = try TwoFile.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const id = try memory.remember(testing.allocator, testing.io, repo.root_abs, .symbol, "no Math.abs", true, "forbid:Math.abs", where);
    defer testing.allocator.free(id);

    var buf_a: [std.fs.max_path_bytes]u8 = undefined;
    var buf_b: [std.fs.max_path_bytes]u8 = undefined;
    const file_a = try repo.pathA(&buf_a);
    const file_b = try repo.pathB(&buf_b);
    const edits = [_]Edit{
        .{ .file_abs = file_a, .ref_text = "add", .expected_hash = try hashOfRef(testing.allocator, testing.io, runtime, file_a, "add"), .new_body = "{ return Math.abs(a); }" },
        .{ .file_abs = file_b, .ref_text = "twice", .expected_hash = try hashOfRef(testing.allocator, testing.io, runtime, file_b, "twice"), .new_body = "{ return Math.abs(x); }" },
    };
    return tryMutateBatch(testing.allocator, testing.io, runtime, .{ .edits = &edits, .test_command = "cmd /c exit 0" });
}

test "scope: a batch applies a symbol-scoped rule only to the edit of that symbol" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const outside = try batchUnder("src/a.ts#twice");
    defer outside.deinit(testing.allocator);
    try testing.expect(outside == .committed);

    const inside = try batchUnder("src/b.ts#twice");
    defer inside.deinit(testing.allocator);
    try testing.expect(inside == .rule_violation);
    try testing.expect(std.mem.endsWith(u8, inside.rule_violation.violations[0].file, "b.ts"));
}

test "scope: at the gate an excluded file is not blocked and a file left in scope is" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    for ([_][]const u8{ "src/ !src/math.ts", "src/ !*.ts", "src/ !src/" }) |where| {
        const result = try tryAddUnder(where);
        defer result.deinit(testing.allocator);
        try testing.expect(result == .committed);
    }
    for ([_][]const u8{ "src/ !__tests__/", "src/ !*.test.ts", "src/ !src/other.ts", "src/math.ts#add !lib/" }) |where| {
        const result = try tryAddUnder(where);
        defer result.deinit(testing.allocator);
        try testing.expect(result == .rule_violation);
    }
}

const probe_rel = "probe.txt";

fn addCommandRule(repo: *Repo, command: []const u8, where: ?[]const u8) ![]u8 {
    const spec = try std.fmt.allocPrint(testing.allocator, "cmd:{s}", .{command});
    defer testing.allocator.free(spec);
    return memory.remember(testing.allocator, testing.io, repo.root_abs, .global, "command rule", true, spec, where);
}

fn tryAddLimited(repo: *Repo, runtime: *Runtime, body: []const u8, test_command: []const u8, limits: sandbox.Limits) !runner.Result {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);
    const hash = try hashOfRef(testing.allocator, testing.io, runtime, file, "add");
    return tryMutate(testing.allocator, testing.io, runtime, .{
        .file_abs = file,
        .ref_text = "add",
        .expected_hash = .{ .present = hash },
        .new_body = body,
        .test_command = test_command,
        .limits = limits,
    });
}

fn expectNoProbe(repo: *Repo) !void {
    try testing.expectError(error.FileNotFound, repo.tmp.dir.access(testing.io, "repo/" ++ probe_rel, .{}));
}

fn expectRuleCheckFailed(result: runner.Result, id: []const u8, detail: []const u8) !void {
    errdefer printResult(result);
    try testing.expect(result == .rule_check_failed);
    try testing.expectEqualStrings(id, result.rule_check_failed.rule);
    try testing.expectEqualStrings("src\\math.ts", result.rule_check_failed.file);
    try testing.expectEqualStrings(detail, result.rule_check_failed.detail);
}

test "cmd rule: a non-zero exit is a violation carrying the output of the command, and nothing is written" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const id = try addCommandRule(&repo, "echo no console.log allowed& exit 3", null);
    defer testing.allocator.free(id);

    const result = try tryAdd(&repo, runtime, clean_body, "exit 0");
    defer result.deinit(testing.allocator);
    try testing.expect(result == .rule_violation);
    const violations = result.rule_violation.violations;
    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqualStrings(id, violations[0].rule);
    try testing.expectEqualStrings("cmd:echo no console.log allowed& exit 3", violations[0].check);
    try testing.expectEqualStrings("src\\math.ts", violations[0].file);
    try testing.expectEqualStrings("no console.log allowed", violations[0].text);
    try expectPristineRepo(&repo);
}

test "cmd rule: exit zero lets the proposal through to the tests and on to disk" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const id = try addCommandRule(&repo, "exit 0", null);
    defer testing.allocator.free(id);

    const result = try tryAdd(&repo, runtime, clean_body, "exit 0");
    defer result.deinit(testing.allocator);
    try testing.expect(result == .committed);
}

test "cmd rule: the command runs in the shadow copy, so its writes never reach the real tree" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const id = try addCommandRule(&repo, "echo tainted> src\\math.ts& echo ran> " ++ probe_rel, null);
    defer testing.allocator.free(id);

    const result = try tryAdd(&repo, runtime, clean_body, "exit 0");
    defer result.deinit(testing.allocator);
    try testing.expect(result == .committed);

    const on_disk = try repo.read();
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings("export function add(a: number, b: number): number {\n  return a - b;\n}\n", on_disk);
    try expectNoProbe(&repo);
}

test "cmd rule: a crashing command is not a verdict, it is rule_check_crashed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const id = try addCommandRule(&repo, crash_command, null);
    defer testing.allocator.free(id);

    const result = try tryAdd(&repo, runtime, clean_body, "exit 0");
    defer result.deinit(testing.allocator);
    try expectRuleCheckFailed(result, id, "crashed");
    try expectPristineRepo(&repo);
}

test "cmd rule: a command that does not exist is not a verdict either" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const id = try addCommandRule(&repo, "emetgate-no-such-binary-xyz", null);
    defer testing.allocator.free(id);

    const result = try tryAdd(&repo, runtime, clean_body, "exit 0");
    defer result.deinit(testing.allocator);
    try expectRuleCheckFailed(result, id, "command_not_found");
    try expectPristineRepo(&repo);
}

test "cmd rule: a command that outlives the wall clock is not a verdict either" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const id = try addCommandRule(&repo, "ping -n 20 127.0.0.1 > nul", null);
    defer testing.allocator.free(id);

    const result = try tryAddLimited(&repo, runtime, clean_body, "exit 0", .{ .timeout_ms = 500 });
    defer result.deinit(testing.allocator);
    try expectRuleCheckFailed(result, id, "timed_out");
    try expectPristineRepo(&repo);
}

test "cmd rule: a sandbox that cannot be built refuses the command instead of running it unrestricted" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    defer sandbox.injected_fault = null;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const id = try addCommandRule(&repo, "echo ran> " ++ probe_rel, null);
    defer testing.allocator.free(id);

    inline for (std.meta.fields(sandbox.TokenStep)) |field| {
        sandbox.injected_fault = @enumFromInt(field.value);
        const result = try tryAdd(&repo, runtime, clean_body, "exit 0");
        defer result.deinit(testing.allocator);
        try expectRuleCheckFailed(result, id, "sandbox_unavailable");
        try testing.expectEqualStrings("SandboxUnavailable", result.rule_check_failed.text);
        try expectNoProbe(&repo);
        try expectPristineRepo(&repo);
    }
}

test "cmd rule: a scope that excludes the file keeps the command from running at all" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const id = try addCommandRule(&repo, "echo ran> " ++ probe_rel ++ "& exit 3", "src/other.ts");
    defer testing.allocator.free(id);

    const result = try tryAdd(&repo, runtime, clean_body, "exit 0");
    defer result.deinit(testing.allocator);
    try testing.expect(result == .committed);
    try expectNoProbe(&repo);
}

test "cmd rule: a scope that covers the file still runs the command" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const id = try addCommandRule(&repo, "exit 3", "src/math.ts#add");
    defer testing.allocator.free(id);

    const result = try tryAdd(&repo, runtime, clean_body, "exit 0");
    defer result.deinit(testing.allocator);
    try testing.expect(result == .rule_violation);
    try testing.expectEqualStrings(id, result.rule_violation.violations[0].rule);
}
