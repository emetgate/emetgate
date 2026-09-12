const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const symbol = @import("symbol.zig");
const disk = @import("disk.zig");
const shadow = @import("shadow.zig");
const sandbox = @import("sandbox.zig");
const runner = @import("runner.zig");
const server = @import("server.zig");
const Runtime = @import("runtime.zig").Runtime;
const Snapshot = @import("loader.zig").Snapshot;

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
        self.tmp.dir.access(testing.io, "repo/.synapse", .{}) catch return false;
        return true;
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
    try testing.expect(!repo.hasShadow());
}

fn attempt(runtime: *Runtime, file: []const u8, hash: symbol.Hash, body: []const u8) !runner.Result {
    return runner.tryMutate(testing.allocator, testing.io, runtime, .{
        .file_abs = file,
        .ref_text = "add",
        .expected_hash = hash,
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

    try testing.expectError(error.BaseChanged, disk.replaceReporting(testing.allocator, testing.io, file, "corrupted", symbol.hashOf("some other content"), null));
    try expectPristine(&repo);
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
        .expected_hash = hash,
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
        .expected_hash = hash,
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
        .expected_hash = hash,
        .new_body = "{ return a - b; }",
        .test_command = "cmd /c exit 0",
    });
    defer result.deinit(testing.allocator);
    try testing.expect(result == .committed);
    try testing.expect(!try repo.hasSibling(".tmp"));
    try testing.expect(!try repo.hasSibling(".bak"));
    try testing.expect(!repo.hasShadow());
}

fn respond(runtime: *Runtime, line: []const u8) ![]u8 {
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    _ = try server.handleMessage(testing.allocator, testing.io, runtime, line, &buffer.writer);
    return testing.allocator.dupe(u8, buffer.written());
}

test "purple C5: malformed JSON is a typed parse error, never a crash" {
    const response = try respond(undefined, "{ this is not json ]");
    defer testing.allocator.free(response);
    try testing.expect(std.mem.indexOf(u8, response, "\"code\":-32700") != null);
}

test "purple C5: a type-confused argument is invalid params, not an internal error" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const response = try respond(runtime,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"synapse_symbols","arguments":{"file":123}}}
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

test "purple C5: a poisoned .synapserc.json is refused, not executed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);

    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.synapserc.json", .data = "{ this is not json" });
    try testing.expectError(error.InvalidConfig, runner.resolveTestCommand(testing.allocator, testing.io, file, ""));

    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.synapserc.json", .data = "{\"test_cmd\":\"\"}" });
    try testing.expectError(error.NoTestCommand, runner.resolveTestCommand(testing.allocator, testing.io, file, ""));
}
