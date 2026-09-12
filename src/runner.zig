const std = @import("std");
const builtin = @import("builtin");
const symbol = @import("symbol.zig");
const cas = @import("cas.zig");
const shadow = @import("shadow.zig");
const sandbox = @import("sandbox.zig");
const disk = @import("disk.zig");
const Runtime = @import("runtime.zig").Runtime;
const Snapshot = @import("loader.zig").Snapshot;

const Allocator = std.mem.Allocator;
const max_git_output = 64 * 1024;

pub const Options = struct {
    file_abs: []const u8,
    ref_text: []const u8,
    expected_hash: symbol.Hash,
    new_body: []const u8,
    test_command: []const u8,
    linked: []const []const u8 = &.{"node_modules"},
    limits: sandbox.Limits = .{},
};

pub const Result = union(enum) {
    committed: symbol.Hash,
    rejected: sandbox.Report,

    pub fn deinit(self: Result, gpa: Allocator) void {
        switch (self) {
            .committed => {},
            .rejected => |report| report.deinit(gpa),
        }
    }
};

pub const config_file = ".synapserc.json";

pub fn assertUnderCwdRepo(gpa: Allocator, io: std.Io, file_abs: []const u8) !void {
    const root = try gitToplevel(gpa, io, ".");
    defer gpa.free(root);
    const rel = try relativeUnder(gpa, root, file_abs);
    gpa.free(rel);
}

pub fn resolveTestCommand(gpa: Allocator, io: std.Io, file_abs: []const u8, given: []const u8) ![]u8 {
    if (given.len != 0) return gpa.dupe(u8, given);
    const dir = std.fs.path.dirname(file_abs) orelse return error.InvalidPath;
    const root = try gitToplevel(gpa, io, dir);
    defer gpa.free(root);
    return (try readTestCommand(gpa, io, root)) orelse error.NoTestCommand;
}

fn readTestCommand(gpa: Allocator, io: std.Io, root: []const u8) !?[]u8 {
    const path = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ root, config_file });
    defer gpa.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer gpa.free(bytes);
    const parsed = std.json.parseFromSlice(struct { test_cmd: ?[]const u8 = null }, gpa, bytes, .{ .ignore_unknown_fields = true }) catch return error.InvalidConfig;
    defer parsed.deinit();
    const cmd = parsed.value.test_cmd orelse return null;
    if (cmd.len == 0) return null;
    return try gpa.dupe(u8, cmd);
}

pub fn tryMutate(gpa: Allocator, io: std.Io, runtime: *Runtime, options: Options) !Result {
    if (options.test_command.len == 0) return error.NoTestCommand;
    const dir = std.fs.path.dirname(options.file_abs) orelse return error.InvalidPath;
    const root = try gitToplevel(gpa, io, dir);
    defer gpa.free(root);
    const lock = try shadow.Lock.acquire(io, root);
    defer lock.release();
    const rel = try relativeUnder(gpa, root, options.file_abs);
    defer gpa.free(rel);

    const base = try Snapshot.load(runtime, io, .cwd(), options.file_abs);
    defer base.destroy();
    if (base.tree.root().hasError()) return error.SourceHasErrors;
    const base_hash = symbol.hashOf(base.source);

    const ref = try symbol.Ref.parse(gpa, options.ref_text);
    defer ref.deinit(gpa);
    const applied = try cas.apply(base, .{ .ref = ref, .expected_hash = options.expected_hash, .new_body = options.new_body });
    defer applied.snapshot.destroy();

    const shadow_abs = try std.fmt.allocPrint(gpa, "{s}\\{s}\\shadow", .{ root, shadow.workspace_dir });
    defer gpa.free(shadow_abs);

    const report = try runInShadow(gpa, io, root, shadow_abs, rel, applied.snapshot.source, options);

    if (!report.passed()) return .{ .rejected = report };
    defer report.deinit(gpa);
    try disk.replaceReporting(gpa, io, options.file_abs, applied.snapshot.source, base_hash, null);
    return .{ .committed = applied.hash };
}

fn runInShadow(gpa: Allocator, io: std.Io, root: []const u8, shadow_abs: []const u8, rel: []const u8, patched: []const u8, options: Options) !sandbox.Report {
    const files = try shadow.trackedFiles(gpa, io, root);
    defer gpa.free(files);
    defer shadow.freeFileList(gpa, files);

    var workspace = try shadow.Shadow.prepare(io, .{
        .root_abs = root,
        .shadow_abs = shadow_abs,
        .files = files,
        .linked = options.linked,
    });
    defer {
        workspace.close();
        shadow.remove(io, root, shadow_abs) catch {};
    }
    try workspace.writeFile(rel, patched);

    const argv = [_][]const u8{ "cmd.exe", "/d", "/c", options.test_command };
    return sandbox.run(gpa, io, .{ .argv = &argv, .cwd = shadow_abs, .limits = options.limits });
}

fn relativeUnder(gpa: Allocator, root: []const u8, file_abs: []const u8) ![]u8 {
    const normalized = try gpa.dupe(u8, file_abs);
    defer gpa.free(normalized);
    std.mem.replaceScalar(u8, normalized, '/', '\\');
    if (normalized.len <= root.len or !std.ascii.startsWithIgnoreCase(normalized, root) or normalized[root.len] != '\\') {
        return error.FileOutsideRepo;
    }
    return gpa.dupe(u8, normalized[root.len + 1 ..]);
}

fn gitToplevel(gpa: Allocator, io: std.Io, dir_abs: []const u8) ![]u8 {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "git", "rev-parse", "--show-toplevel" },
        .cwd = .{ .path = dir_abs },
        .stdout_limit = .limited(max_git_output),
    }) catch return error.GitFailed;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.NotInRepo,
        else => return error.GitFailed,
    }
    const trimmed = std.mem.trim(u8, result.stdout, " \r\n");
    const owned = try gpa.dupe(u8, trimmed);
    std.mem.replaceScalar(u8, owned, '/', '\\');
    return owned;
}

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

test "test command defaults from .synapserc.json when the caller omits it" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.synapserc.json", .data = "{\"test_cmd\":\"exit 0\"}" });
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);
    const hash = try hashOfRef(testing.allocator, testing.io, runtime, file, "add");

    const cmd = try resolveTestCommand(testing.allocator, testing.io, file, "");
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

test "an explicit test command overrides the config default" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();
    try repo.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.synapserc.json", .data = "{\"test_cmd\":\"exit 1\"}" });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);
    const cmd = try resolveTestCommand(testing.allocator, testing.io, file, "exit 0");
    defer testing.allocator.free(cmd);
    try testing.expectEqualStrings("exit 0", cmd);
}

test "a missing config with no test command is refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var repo = try Repo.init();
    defer repo.deinit();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = try repo.filePath(&buf);
    try testing.expectError(error.NoTestCommand, resolveTestCommand(testing.allocator, testing.io, file, ""));
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

    try testing.expectError(error.FileNotFound, repo.tmp.dir.access(testing.io, "repo/.synapse", .{}));
}
