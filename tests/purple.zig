const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const builtin = @import("builtin");
const build_options = @import("build_options");
const symbol = @import("../src/engine/symbol.zig");
const disk = @import("../src/platform/disk.zig");
const shadow = @import("../src/platform/shadow.zig");
const sandbox = @import("../src/platform/sandbox.zig");
const runner = @import("../src/platform/runner.zig");
const server = @import("../src/protocol/server.zig");
const Runtime = @import("../src/engine/runtime.zig").Runtime;
const Snapshot = @import("../src/engine/loader.zig").Snapshot;

const testing = std.testing;
const Allocator = std.mem.Allocator;

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

    fn onDisk(self: *Repo) ![]u8 {
        return self.tmp.dir.readFileAlloc(testing.io, "repo/src/math.ts", testing.allocator, .unlimited);
    }

    fn hasSibling(self: *Repo, suffix: []const u8) !bool {
        var dir = try self.tmp.dir.openDir(testing.io, "repo/src", .{ .iterate = true });
        defer dir.close(testing.io);
        var it = dir.iterate();
        while (try it.next(testing.io)) |entry| {
            if (std.mem.indexOf(u8, entry.name, suffix) != null and !std.mem.eql(u8, entry.name, "math.ts")) return true;
        }
        return false;
    }

    fn hasShadow(self: *Repo) bool {
        self.tmp.dir.access(testing.io, "repo/.emetgate", .{}) catch return false;
        return true;
    }

    fn shadowPath(self: *Repo, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}\\{s}\\shadow", .{ self.root_abs, shadow.workspace_dir });
    }

    fn reportLeftoverShadow(self: *Repo) void {
        std.debug.print("leftover {s} entries:\n", .{shadow.workspace_dir});
        if (self.tmp.dir.openDir(testing.io, "repo/" ++ shadow.workspace_dir, .{ .iterate = true })) |opened| {
            var dir = opened;
            defer dir.close(testing.io);
            var walker = dir.walk(testing.allocator) catch |err| {
                std.debug.print("  walk failed: {t}\n", .{err});
                return;
            };
            defer walker.deinit();
            var listed: usize = 0;
            while (listed < 20) : (listed += 1) {
                const entry = (walker.next(testing.io) catch |err| {
                    std.debug.print("  walk failed: {t}\n", .{err});
                    break;
                }) orelse break;
                std.debug.print("  {s}\n", .{entry.path});
            }
        } else |err| std.debug.print("  open failed: {t}\n", .{err});

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const shadow_abs = self.shadowPath(&buf) catch |err| {
            std.debug.print("shadow path: {t}\n", .{err});
            return;
        };
        if (shadow.remove(testing.io, self.root_abs, shadow_abs)) |_| {
            std.debug.print("shadow.remove: removed on retry\n", .{});
        } else |err| std.debug.print("shadow.remove: {t}\n", .{err});
    }
};

fn hashOfAdd(gpa: Allocator, runtime: *Runtime, file: []const u8) !symbol.Hash {
    const snapshot = try Snapshot.load(runtime, testing.io, .cwd(), file);
    defer snapshot.destroy();
    const table = try snapshot.symbols();
    const ref = try symbol.Ref.parse(gpa, "add");
    defer ref.deinit(gpa);
    return (try table.resolve(ref)).hash;
}

fn expectPristine(repo: *Repo) !void {
    const on_disk = try repo.onDisk();
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(Repo.source, on_disk);
    try testing.expect(!try repo.hasSibling(".tmp"));
    try testing.expect(!try repo.hasSibling(".bak"));
    if (repo.hasShadow()) {
        repo.reportLeftoverShadow();
        return error.TestUnexpectedResult;
    }
}

fn attempt(runtime: *Runtime, file: []const u8, hash: symbol.Hash, body: []const u8) !runner.Result {
    return runner.tryMutate(testing.allocator, testing.io, runtime, .{
        .file_abs = file,
        .ref_text = "add",
        .expected_hash = .{ .present = hash },
        .new_body = body,
        .test_command = "cmd /c exit 0",
    });
}

test "purple C1: a stale hash never reaches disk" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);

    try testing.expectError(error.HashMismatch, attempt(runtime, file, symbol.hashOf("stale"), "{ return a - b; }"));
    try expectPristine(&repo);
}

test "purple C1: a fabricated hash never reaches disk" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);

    const zero: symbol.Hash = @splat(0);
    try testing.expectError(error.HashMismatch, attempt(runtime, file, zero, "{ return a - b; }"));
    try expectPristine(&repo);
}

test "purple C1: a concurrent change is caught at commit and the original survives" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);

    try testing.expectError(error.BaseChanged, disk.replaceReporting(testing.allocator, testing.io, file, "corrupted", symbol.hashOf("some other content"), null, null));
    try expectPristine(&repo);
}

test "purple C1: a second run on a locked repo is refused with a typed WorkspaceBusy" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();

    {
        const held = try shadow.Lock.acquire(testing.io, repo.root_abs);
        defer held.release();
        try testing.expectError(error.WorkspaceBusy, shadow.Lock.acquire(testing.io, repo.root_abs));
    }
    const reacquired = try shadow.Lock.acquire(testing.io, repo.root_abs);
    reacquired.release();
}

test "purple V3: a repo-committed test_cmd is untrusted and refused by default" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.emetgaterc.json", .data = "{\"test_cmd\":\"echo owned > pwned.txt & exit 0\"}" });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);
    try testing.expectError(error.UntrustedRepoConfig, runner.resolveTestCommand(testing.allocator, testing.io, file, "", false));
}

test "purple C2: a brace-injection body cannot escape the slot" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);
    const hash = try hashOfAdd(testing.allocator, runtime, file);

    try testing.expectError(error.BodyEscape, attempt(runtime, file, hash, "{ return a; } globalThis.pwn = 1;"));
    try expectPristine(&repo);
}

test "purple C2: a syntactically broken body is rejected" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);
    const hash = try hashOfAdd(testing.allocator, runtime, file);

    try testing.expectError(error.MutationSyntaxInvalid, attempt(runtime, file, hash, "{ return a"));
    try expectPristine(&repo);
}

test "purple C2: every placeholder variant is rejected before any test runs" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);
    const hash = try hashOfAdd(testing.allocator, runtime, file);

    const variants = [_][]const u8{
        "{ /* ...existing code... */ }",
        "{ // keep the original\n}",
        "{\n  // ...\n}",
    };
    for (variants) |body| {
        errdefer std.debug.print("variant accepted: {s}\n", .{body});
        try testing.expectError(error.PlaceholderBody, attempt(runtime, file, hash, body));
    }
    try expectPristine(&repo);
}

test "purple C3: a hanging test command times out and nothing commits" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);
    const hash = try hashOfAdd(testing.allocator, runtime, file);

    const result = try runner.tryMutate(testing.allocator, testing.io, runtime, .{
        .file_abs = file,
        .ref_text = "add",
        .expected_hash = .{ .present = hash },
        .new_body = "{ return a - b; }",
        .test_command = "ping -n 20 127.0.0.1 >nul",
        .limits = .{ .timeout_ms = 1500 },
    });
    defer result.deinit(testing.allocator);
    try testing.expect(result == .rejected);
    try testing.expectEqual(sandbox.Outcome.timed_out, result.rejected.outcome);
    try expectPristine(&repo);
}

test "purple C3: a test command that leaves a lingering process is caught, not passed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const report = try sandbox.run(testing.allocator, testing.io, .{
        .argv = &.{ build_options.probe_path, "orphan" },
        .cwd = ".",
        .limits = .{ .timeout_ms = 20_000 },
    });
    defer report.deinit(testing.allocator);
    try testing.expect(report.killed_leftovers);
    try testing.expect(!report.passed());
}

test "purple C3: path traversal, device names and drive paths are refused" {
    const unsafe = [_][]const u8{ "..\\escape.ts", "a\\..\\b.ts", "CON", "C:\\windows\\x.ts", "sub\\..\\..\\out.ts" };
    for (unsafe) |path| {
        errdefer std.debug.print("unsafe path accepted: {s}\n", .{path});
        try testing.expectError(error.UnsafePath, shadow.validateRelative(path));
    }
    try shadow.validateRelative("src\\math.ts");
}

test "purple C4: a rejected mutation leaves no temp, backup, or shadow artifacts" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);
    const hash = try hashOfAdd(testing.allocator, runtime, file);

    const result = try runner.tryMutate(testing.allocator, testing.io, runtime, .{
        .file_abs = file,
        .ref_text = "add",
        .expected_hash = .{ .present = hash },
        .new_body = "{ return a - b; }",
        .test_command = "cmd /c exit 1",
    });
    defer result.deinit(testing.allocator);
    try testing.expect(result == .rejected);
    try expectPristine(&repo);
}

test "purple C4: a committed mutation leaves no temp or backup artifacts" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);
    const hash = try hashOfAdd(testing.allocator, runtime, file);

    const result = try runner.tryMutate(testing.allocator, testing.io, runtime, .{
        .file_abs = file,
        .ref_text = "add",
        .expected_hash = .{ .present = hash },
        .new_body = "{ return a - b; }",
        .test_command = "cmd /c exit 0",
    });
    defer result.deinit(testing.allocator);
    errdefer diagnostics.printResult(result);
    try testing.expect(result == .committed);
    try testing.expect(!try repo.hasSibling(".tmp"));
    try testing.expect(!try repo.hasSibling(".bak"));
    if (repo.hasShadow()) {
        repo.reportLeftoverShadow();
        return error.TestUnexpectedResult;
    }
}

test "purple V6: an MCP read tool cannot escape the project root" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    const response = try respond(runtime,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"emetgate_symbols","arguments":{"file":"C:/Windows/System32/drivers/etc/hosts"}}}
    );
    defer testing.allocator.free(response);

    try testing.expect(std.mem.indexOf(u8, response, "\"isError\":true") != null);
    try testing.expect(std.mem.indexOf(u8, response, "FileOutsideRepo") != null);
}

test "purple V7: no MCP tool reaches a repository other than the one being served" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);
    const hex = symbol.formatHash(try hashOfAdd(testing.allocator, runtime, file));

    for ([_][]const u8{ "emetgate_try", "emetgate_try_batch" }) |tool| {
        const line = try toolCallLine(tool, file, hex[0..], "");
        defer testing.allocator.free(line);
        const response = try respondWith(runtime, line, .{ .test_command = "cmd /c exit 0" });
        defer testing.allocator.free(response);
        errdefer std.debug.print("{s}: {s}\n", .{ tool, response });
        try testing.expect(std.mem.indexOf(u8, response, "\"isError\":true") != null);
        try testing.expect(std.mem.indexOf(u8, response, "FileOutsideRepo") != null);
        try expectPristine(&repo);
    }

    const escaped = try jsonEscaped(file);
    defer testing.allocator.free(escaped);
    const read_line = try std.fmt.allocPrint(testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"emetgate_read_file\",\"arguments\":{{\"file\":\"{s}\"}}}}}}", .{escaped});
    defer testing.allocator.free(read_line);
    const read = try respondWith(runtime, read_line, .{});
    defer testing.allocator.free(read);
    try testing.expect(std.mem.indexOf(u8, read, "FileOutsideRepo") != null);
    try testing.expect(std.mem.indexOf(u8, read, "return a + b") == null);
}

test "purple V8: an MCP write tool cannot edit the emetgate workspace inside the served repository" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    try repo.tmp.dir.createDirPath(testing.io, "repo/.emetgate");
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.emetgate/math.ts", .data = Repo.source });
    const inner = try std.fmt.allocPrint(testing.allocator, "{s}\\.emetgate\\math.ts", .{repo.root_abs});
    defer testing.allocator.free(inner);
    const hex = symbol.formatHash(try hashOfAdd(testing.allocator, runtime, inner));

    for ([_][]const u8{ "emetgate_try", "emetgate_try_batch" }) |tool| {
        const line = try toolCallLine(tool, inner, hex[0..], "");
        defer testing.allocator.free(line);
        const response = try respondWith(runtime, line, .{ .test_command = "cmd /c exit 0", .root = repo.root_abs });
        defer testing.allocator.free(response);
        errdefer std.debug.print("{s}: {s}\n", .{ tool, response });
        try testing.expect(std.mem.indexOf(u8, response, "\"isError\":true") != null);
        try testing.expect(std.mem.indexOf(u8, response, "InternalPath") != null);
        const after = try repo.tmp.dir.readFileAlloc(testing.io, "repo/.emetgate/math.ts", testing.allocator, .unlimited);
        defer testing.allocator.free(after);
        try testing.expectEqualStrings(Repo.source, after);
    }
}

const orig_a = "export function a(): number { return 1; }\n";
const new_a = "export function a(): number { return 2; }\n";

fn writeJournal(tmp: *testing.TmpDir, root: []const u8, tag: []const u8, rel_target: []const u8, base_hash_hex: []const u8) !void {
    try tmp.dir.createDirPath(testing.io, ".emetgate/journal");
    const target_abs = try std.fmt.allocPrint(testing.allocator, "{s}\\{s}", .{ root, rel_target });
    defer testing.allocator.free(target_abs);

    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    var js: std.json.Stringify = .{ .writer = &buffer.writer };
    try js.beginObject();
    try js.objectField("target");
    try js.write(target_abs);
    try js.objectField("base_hash");
    try js.write(base_hash_hex);
    try js.endObject();

    var name_buf: [128]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, ".emetgate/journal/{s}.json", .{tag});
    try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = buffer.written() });
}

const tag_a = "0123456789abcdef";

test "purple recover #7: a journaled backup restores the original (happy path)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = new_a });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts.emetgate-" ++ tag_a ++ ".bak", .data = orig_a });
    try writeJournal(&tmp, root, tag_a, "a.ts", &symbol.formatHash(symbol.hashOf(orig_a)));

    const report = try disk.recover(testing.allocator, testing.io, root);
    try testing.expectEqual(@as(usize, 1), report.restored);
    try testing.expectEqual(@as(usize, 0), report.failed);
    const a = try tmp.dir.readFileAlloc(testing.io, "a.ts", testing.allocator, .unlimited);
    defer testing.allocator.free(a);
    try testing.expectEqualStrings(orig_a, a);
}

test "purple recover #3 (A): a journal target outside the repo is refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try tmp.dir.createDirPath(testing.io, ".emetgate/journal");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".emetgate/journal/" ++ tag_a ++ ".json", .data = "{\"target\":\"C:\\\\Windows\\\\System32\\\\drivers\\\\etc\\\\hosts\",\"base_hash\":\"" ++ "af1349b9f5f9a1a6a0404dea36dcc949" ++ "\"}" });

    const report = try disk.recover(testing.allocator, testing.io, root);
    try testing.expectEqual(@as(usize, 0), report.restored);
    try testing.expectEqual(@as(usize, 1), report.failed);
}

test "purple recover #4 (C): a backup whose content does not match base_hash is refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = new_a });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts.emetgate-" ++ tag_a ++ ".bak", .data = "export const STOLEN = 1;\n" });
    try writeJournal(&tmp, root, tag_a, "a.ts", &symbol.formatHash(symbol.hashOf(orig_a)));

    const report = try disk.recover(testing.allocator, testing.io, root);
    try testing.expectEqual(@as(usize, 0), report.restored);
    try testing.expectEqual(@as(usize, 1), report.failed);
    const a = try tmp.dir.readFileAlloc(testing.io, "a.ts", testing.allocator, .unlimited);
    defer testing.allocator.free(a);
    try testing.expectEqualStrings(new_a, a);
}

test "purple recover #1: a zero-byte backup never overwrites the target" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = new_a });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts.emetgate-" ++ tag_a ++ ".bak", .data = "" });
    try writeJournal(&tmp, root, tag_a, "a.ts", &symbol.formatHash(symbol.hashOf(orig_a)));

    const report = try disk.recover(testing.allocator, testing.io, root);
    try testing.expectEqual(@as(usize, 0), report.restored);
    try testing.expectEqual(@as(usize, 1), report.failed);
    const a = try tmp.dir.readFileAlloc(testing.io, "a.ts", testing.allocator, .unlimited);
    defer testing.allocator.free(a);
    try testing.expectEqualStrings(new_a, a);
}

test "purple recover #5 (B): a corrupt journal fails closed without a panic" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try tmp.dir.createDirPath(testing.io, ".emetgate/journal");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".emetgate/journal/" ++ tag_a ++ ".json", .data = "{ this is not json" });

    const report = try disk.recover(testing.allocator, testing.io, root);
    try testing.expectEqual(@as(usize, 0), report.restored);
    try testing.expectEqual(@as(usize, 1), report.failed);
}

test "purple recover #6 (D): a journal entry with no backup is skipped, target untouched" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = orig_a });
    try writeJournal(&tmp, root, tag_a, "a.ts", &symbol.formatHash(symbol.hashOf(orig_a)));

    const report = try disk.recover(testing.allocator, testing.io, root);
    try testing.expectEqual(@as(usize, 0), report.restored);
    try testing.expectEqual(@as(usize, 1), report.skipped);
    const a = try tmp.dir.readFileAlloc(testing.io, "a.ts", testing.allocator, .unlimited);
    defer testing.allocator.free(a);
    try testing.expectEqualStrings(orig_a, a);
}

test "purple recover: a journal with a non-hex tag is refused (tag hardening)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = new_a });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts.emetgate-notavalidtag.bak", .data = orig_a });
    try writeJournal(&tmp, root, "notavalidtag", "a.ts", &symbol.formatHash(symbol.hashOf(orig_a)));

    const report = try disk.recover(testing.allocator, testing.io, root);
    try testing.expectEqual(@as(usize, 0), report.restored);
    try testing.expect(report.failed >= 1);
    const a = try tmp.dir.readFileAlloc(testing.io, "a.ts", testing.allocator, .unlimited);
    defer testing.allocator.free(a);
    try testing.expectEqualStrings(new_a, a);
}

const secret = "export const SECRET = 1;\n";

test "purple recover: a symlinked backup is refused (reparse guard, privilege-gated)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "outside_secret.ts", .data = secret });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = new_a });
    tmp.dir.symLink(testing.io, "outside_secret.ts", "a.ts.emetgate-" ++ tag_a ++ ".bak", .{}) catch return error.SkipZigTest;
    try writeJournal(&tmp, root, tag_a, "a.ts", &symbol.formatHash(symbol.hashOf(secret)));

    const report = try disk.recover(testing.allocator, testing.io, root);
    try testing.expectEqual(@as(usize, 0), report.restored);
    try testing.expect(report.failed >= 1);
    const a = try tmp.dir.readFileAlloc(testing.io, "a.ts", testing.allocator, .unlimited);
    defer testing.allocator.free(a);
    try testing.expectEqualStrings(new_a, a);
}

fn recoverWorkspace(root: []const u8, err_out: *std.Io.Writer.Allocating) !u8 {
    const lock = try shadow.Lock.acquire(testing.io, root);
    defer lock.release();
    return disk.recoverWorkspace(testing.allocator, testing.io, root, &err_out.writer);
}

test "purple recover: a shadow that cannot be removed exits 16 and says so after the summary" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try tmp.dir.createDirPath(testing.io, ".emetgate/shadow/src");
    var held_buf: [std.fs.max_path_bytes]u8 = undefined;
    const held_path = try std.fmt.bufPrint(&held_buf, "{s}\\.emetgate\\shadow\\src\\held.ts", .{root});
    const held = try shadow.FileLock.acquire(held_path);

    var err_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer err_out.deinit();
    const code = recoverWorkspace(root, &err_out);
    held.release();

    try testing.expectEqual(@as(u8, 16), try code);
    const text = err_out.written();
    const summary = std.mem.indexOf(u8, text, "recovered 0 file(s)") orelse return error.TestUnexpectedResult;
    const failure = std.mem.indexOf(u8, text, "could not remove shadow: ") orelse return error.TestUnexpectedResult;
    try testing.expect(summary < failure);
}

test "purple recover: no shadow at all is a clean recover with exit 0" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    var err_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer err_out.deinit();
    try testing.expectEqual(@as(u8, 0), try recoverWorkspace(root, &err_out));
    try testing.expect(std.mem.indexOf(u8, err_out.written(), "could not remove shadow") == null);
}

fn respond(runtime: *Runtime, line: []const u8) ![]u8 {
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    _ = try server.handleMessage(testing.allocator, testing.io, runtime, line, &buffer.writer);
    return testing.allocator.dupe(u8, buffer.written());
}

fn respondWith(runtime: *Runtime, line: []const u8, policy: server.Policy) ![]u8 {
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    _ = try server.handleMessageObserved(testing.allocator, testing.io, runtime, line, &buffer.writer, null, policy);
    return testing.allocator.dupe(u8, buffer.written());
}

fn jsonEscaped(text: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, testing.allocator, text, "\\", "\\\\");
}

fn toolCallLine(tool: []const u8, file: []const u8, hash_hex: []const u8, extra: []const u8) ![]u8 {
    const escaped = try jsonEscaped(file);
    defer testing.allocator.free(escaped);
    if (std.mem.eql(u8, tool, "emetgate_try_batch")) {
        return std.fmt.allocPrint(testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"emetgate_try_batch\",\"arguments\":{{\"edits\":[{{\"file\":\"{s}\",\"symbol\":\"add\",\"hash\":\"{s}\",\"body\":\"{{ return a - b; }}\"}}]{s}}}}}}}", .{ escaped, hash_hex, extra });
    }
    return std.fmt.allocPrint(testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"emetgate_try\",\"arguments\":{{\"file\":\"{s}\",\"symbol\":\"add\",\"hash\":\"{s}\",\"body\":\"{{ return a - b; }}\"{s}}}}}}}", .{ escaped, hash_hex, extra });
}

const edited_source = "export function add(a: number, b: number): number { return a - b; }\n";

test "purple C5: malformed JSON is a typed parse error, never a crash" {
    const response = try respond(undefined, "{ this is not json ]");
    defer testing.allocator.free(response);
    try testing.expect(std.mem.indexOf(u8, response, "\"code\":-32700") != null);
}

test "purple C5: a type-confused argument is invalid params, not an internal error" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const response = try respond(runtime,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"emetgate_symbols","arguments":{"file":123}}}
    );
    defer testing.allocator.free(response);
    try testing.expect(std.mem.indexOf(u8, response, "\"code\":-32602") != null);
    try testing.expect(std.mem.indexOf(u8, response, "-32603") == null);
}

test "purple C5: an unknown tool is invalid params" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const response = try respond(runtime,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"rm_rf","arguments":{}}}
    );
    defer testing.allocator.free(response);
    try testing.expect(std.mem.indexOf(u8, response, "\"code\":-32602") != null);
}

test "purple C7: a test command supplied by the model is refused and never runs" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);
    const hex = symbol.formatHash(try hashOfAdd(testing.allocator, runtime, file));

    const marker = try std.fmt.allocPrint(testing.allocator, "{s}\\model-ran.txt", .{repo.root_abs});
    defer testing.allocator.free(marker);
    const marker_json = try jsonEscaped(marker);
    defer testing.allocator.free(marker_json);
    const extra = try std.fmt.allocPrint(testing.allocator, ",\"test_cmd\":\"cmd /c echo ran> {s}\"", .{marker_json});
    defer testing.allocator.free(extra);

    const policies = [_]server.Policy{ .{}, .{ .test_command = "cmd /c exit 1" }, .{ .test_command = "cmd /c exit 0" } };
    for ([_][]const u8{ "emetgate_try", "emetgate_try_batch" }) |tool| {
        for (policies) |policy| {
            const line = try toolCallLine(tool, file, hex[0..], extra);
            defer testing.allocator.free(line);
            const response = try respondWith(runtime, line, policy);
            defer testing.allocator.free(response);
            try testing.expect(std.mem.indexOf(u8, response, "ModelSuppliedTestPolicy") != null);
            try testing.expect(std.mem.indexOf(u8, response, "\"isError\":true") != null);
            try expectPristine(&repo);
            try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, marker, .{}));
        }
    }
}

test "purple C7: a typecheck command supplied by the model is refused and never runs" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);
    const hex = symbol.formatHash(try hashOfAdd(testing.allocator, runtime, file));

    const marker = try std.fmt.allocPrint(testing.allocator, "{s}\\model-typecheck-ran.txt", .{repo.root_abs});
    defer testing.allocator.free(marker);
    const marker_json = try jsonEscaped(marker);
    defer testing.allocator.free(marker_json);
    const extra = try std.fmt.allocPrint(testing.allocator, ",\"typecheck_cmd\":\"cmd /c echo ran> {s}\"", .{marker_json});
    defer testing.allocator.free(extra);

    const policies = [_]server.Policy{ .{ .test_command = "cmd /c exit 0" }, .{ .test_command = "cmd /c exit 0", .typecheck_command = "cmd /c exit 0" } };
    for ([_][]const u8{ "emetgate_try", "emetgate_try_batch" }) |tool| {
        for (policies) |policy| {
            const line = try toolCallLine(tool, file, hex[0..], extra);
            defer testing.allocator.free(line);
            const response = try respondWith(runtime, line, policy);
            defer testing.allocator.free(response);
            try testing.expect(std.mem.indexOf(u8, response, "ModelSuppliedTestPolicy") != null);
            try testing.expect(std.mem.indexOf(u8, response, "\"isError\":true") != null);
            try expectPristine(&repo);
            try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, marker, .{}));
        }
    }
}

test "purple C7: a repo config opt-in supplied by the model is refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.emetgaterc.json", .data = "{\"test_cmd\":\"cmd /c exit 0\"}" });
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);
    const hex = symbol.formatHash(try hashOfAdd(testing.allocator, runtime, file));

    for ([_][]const u8{ "emetgate_try", "emetgate_try_batch" }) |tool| {
        for ([_][]const u8{ ",\"allow_repo_config\":true", ",\"allow_repo_config\":false" }) |extra| {
            const line = try toolCallLine(tool, file, hex[0..], extra);
            defer testing.allocator.free(line);
            const response = try respondWith(runtime, line, .{});
            defer testing.allocator.free(response);
            try testing.expect(std.mem.indexOf(u8, response, "ModelSuppliedTestPolicy") != null);
            try expectPristine(&repo);
        }
    }
}

test "purple C7: only the user's policy decides whether an edit can commit" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);
    const hex = symbol.formatHash(try hashOfAdd(testing.allocator, runtime, file));
    const line = try toolCallLine("emetgate_try", file, hex[0..], "");
    defer testing.allocator.free(line);

    for ([_]server.Policy{ .{ .root = repo.root_abs }, .{ .allow_repo_config = true, .root = repo.root_abs } }) |policy| {
        const response = try respondWith(runtime, line, policy);
        defer testing.allocator.free(response);
        try testing.expect(std.mem.indexOf(u8, response, "NoTestCommand") != null);
        try expectPristine(&repo);
    }

    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.emetgaterc.json", .data = "{\"test_cmd\":\"cmd /c exit 0\"}" });
    const untrusted = try respondWith(runtime, line, .{ .root = repo.root_abs });
    defer testing.allocator.free(untrusted);
    try testing.expect(std.mem.indexOf(u8, untrusted, "UntrustedRepoConfig") != null);

    const committed = try respondWith(runtime, line, .{ .allow_repo_config = true, .root = repo.root_abs });
    defer testing.allocator.free(committed);
    errdefer std.debug.print("response={s}\n", .{committed});
    try testing.expect(std.mem.indexOf(u8, committed, "\\\"status\\\":\\\"committed\\\"") != null);
    const on_disk = try repo.onDisk();
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(edited_source, on_disk);
}

test "purple C7: tools/list never offers the model a test command or a repo opt-in" {
    const response = try respond(undefined,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list"}
    );
    defer testing.allocator.free(response);
    try testing.expect(std.mem.indexOf(u8, response, "emetgate_try_batch") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"test_cmd\"") == null);
    try testing.expect(std.mem.indexOf(u8, response, "\"typecheck_cmd\"") == null);
    try testing.expect(std.mem.indexOf(u8, response, "\"allow_repo_config\"") == null);
    try testing.expect(std.mem.indexOf(u8, response, "\"allow_repo_memory\"") == null);
}

test "purple C6: an MCP batch frees every resolved path with its real size" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);
    const hex = symbol.formatHash(try hashOfAdd(testing.allocator, runtime, file));

    var line: std.Io.Writer.Allocating = .init(testing.allocator);
    defer line.deinit();
    var js: std.json.Stringify = .{ .writer = &line.writer };
    try js.beginObject();
    try js.objectField("jsonrpc");
    try js.write("2.0");
    try js.objectField("id");
    try js.write(1);
    try js.objectField("method");
    try js.write("tools/call");
    try js.objectField("params");
    try js.beginObject();
    try js.objectField("name");
    try js.write("emetgate_try_batch");
    try js.objectField("arguments");
    try js.beginObject();
    try js.objectField("edits");
    try js.beginArray();
    try js.beginObject();
    try js.objectField("file");
    try js.write(file);
    try js.objectField("symbol");
    try js.write("add");
    try js.objectField("hash");
    try js.write(hex[0..]);
    try js.objectField("body");
    try js.write("{\n  return a - b;\n}");
    try js.endObject();
    try js.endArray();
    try js.endObject();
    try js.endObject();
    try js.endObject();

    const response = try respondWith(runtime, line.written(), .{ .test_command = "cmd /c exit 0", .root = repo.root_abs });
    defer testing.allocator.free(response);
    errdefer std.debug.print("response={s}\n", .{response});
    try testing.expect(std.mem.indexOf(u8, response, "\"isError\":false") != null);
    const on_disk = try repo.onDisk();
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings("export function add(a: number, b: number): number {\n  return a - b;\n}\n", on_disk);
}

test "purple C5: a poisoned .emetgaterc.json is refused, not executed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);

    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.emetgaterc.json", .data = "{ this is not json" });
    try testing.expectError(error.InvalidConfig, runner.resolveTestCommand(testing.allocator, testing.io, file, "", true));

    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.emetgaterc.json", .data = "{\"test_cmd\":\"\"}" });
    try testing.expectError(error.NoTestCommand, runner.resolveTestCommand(testing.allocator, testing.io, file, "", true));
}

test "purple: a batch item with hash absent is refused by name and the repository is untouched" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);

    const line = try toolCallLine("emetgate_try_batch", file, "absent", "");
    defer testing.allocator.free(line);
    const response = try respondWith(runtime, line, .{ .test_command = "cmd /c exit 0", .root = repo.root_abs });
    defer testing.allocator.free(response);
    errdefer std.debug.print("response: {s}\n", .{response});
    try testing.expect(std.mem.indexOf(u8, response, "AbsentInBatch") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"isError\":true") != null);
    try expectPristine(&repo);
}

fn newFileCall(tool: []const u8, file: []const u8) ![]u8 {
    const escaped = try jsonEscaped(file);
    defer testing.allocator.free(escaped);
    return std.fmt.allocPrint(testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{{\"file\":\"{s}\",\"symbol\":\"mul\",\"hash\":\"absent\",\"body\":\"export function mul(a: number, b: number): number {{ return a * b; }}\"}}}}}}", .{ tool, escaped });
}

test "purple: hash absent on a missing file creates it through emetgate_try, and emetgate_mutate only previews it" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const file = try std.fmt.allocPrint(testing.allocator, "{s}\\src\\mul.ts", .{repo.root_abs});
    defer testing.allocator.free(file);
    const policy: server.Policy = .{ .test_command = "cmd /c exit 0", .root = repo.root_abs };

    const preview_line = try newFileCall("emetgate_mutate", file);
    defer testing.allocator.free(preview_line);
    const preview = try respondWith(runtime, preview_line, policy);
    defer testing.allocator.free(preview);
    errdefer std.debug.print("preview: {s}\n", .{preview});
    try testing.expect(std.mem.indexOf(u8, preview, "\\\"old_hash\\\":\\\"absent\\\"") != null);
    try testing.expectError(error.FileNotFound, repo.tmp.dir.access(testing.io, "repo/src/mul.ts", .{}));

    const try_line = try newFileCall("emetgate_try", file);
    defer testing.allocator.free(try_line);
    const created = try respondWith(runtime, try_line, policy);
    defer testing.allocator.free(created);
    errdefer std.debug.print("try: {s}\n", .{created});
    try testing.expect(std.mem.indexOf(u8, created, "\\\"status\\\":\\\"committed\\\"") != null);
    const on_disk = try repo.tmp.dir.readFileAlloc(testing.io, "repo/src/mul.ts", testing.allocator, .unlimited);
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings("export function mul(a: number, b: number): number { return a * b; }\n", on_disk);
}

test "purple: hash absent in a directory that does not exist is refused by name through MCP" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const file = try std.fmt.allocPrint(testing.allocator, "{s}\\src\\nested\\mul.ts", .{repo.root_abs});
    defer testing.allocator.free(file);

    for ([_][]const u8{ "emetgate_try", "emetgate_mutate" }) |tool| {
        const line = try newFileCall(tool, file);
        defer testing.allocator.free(line);
        const response = try respondWith(runtime, line, .{ .test_command = "cmd /c exit 0", .root = repo.root_abs });
        defer testing.allocator.free(response);
        errdefer std.debug.print("{s}: {s}\n", .{ tool, response });
        try testing.expect(std.mem.indexOf(u8, response, "ParentDirectoryMissing") != null);
    }
    try testing.expectError(error.FileNotFound, repo.tmp.dir.access(testing.io, "repo/src/nested", .{}));
    try expectPristine(&repo);
}
