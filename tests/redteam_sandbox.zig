const std = @import("std");
const git_fixture = @import("git_fixture.zig");
const diagnostics = @import("diagnostics.zig");
const builtin = @import("builtin");
const runner = @import("emetgate").runner;
const shadow = @import("emetgate").shadow;
const shadow_root = @import("emetgate").shadow_root;
const sandbox = @import("emetgate").sandbox;
const symbol = @import("emetgate").symbol;
const Runtime = @import("emetgate").runtime.Runtime;
const Snapshot = @import("emetgate").loader.Snapshot;

const testing = std.testing;
const gpa = testing.allocator;

const math_src = "export function add(a: number, b: number): number {\n  return a + b;\n}\n";
const other_src = "export function other(): number {\n  return 1;\n}\n";
const dependency_src = "module.exports = 42;\n";
const outside_src = "machine-wide secret\n";

const Victim = struct {
    tmp: testing.TmpDir,
    top_abs: [:0]u8,
    root_abs: [:0]u8,

    fn init() !Victim {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo/src");
        try tmp.dir.createDirPath(testing.io, "repo/node_modules/pkg");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/math.ts", .data = math_src });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/other.ts", .data = other_src });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/node_modules/pkg/index.js", .data = dependency_src });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.gitignore", .data = "node_modules/\n" });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "outside.txt", .data = outside_src });
        const top_abs = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
        errdefer gpa.free(top_abs);
        const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", gpa);
        errdefer gpa.free(root_abs);
        try git_fixture.initRepo(root_abs);
        for ([_][]const []const u8{
            &.{ "add", "." },
            &.{ "commit", "-q", "-m", "init" },
        }) |args| try git(root_abs, args);
        return .{ .tmp = tmp, .top_abs = top_abs, .root_abs = root_abs };
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

    fn deinit(self: *Victim) void {
        gpa.free(self.root_abs);
        gpa.free(self.top_abs);
        self.tmp.cleanup();
    }

    fn attack(self: *Victim, exit_code: u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "(echo inside> inside-shadow.txt || exit 7) & " ++
            "(echo BACKDOOR> \"{0s}\\src\\other.ts\") & " ++
            "(echo BACKDOOR> \"{0s}\\planted.ts\") & " ++
            "(echo BACKDOOR> \"{1s}\\outside.txt\") & " ++
            "(echo BACKDOOR> \"{1s}\\planted.txt\") & " ++
            "(echo BACKDOOR> node_modules\\pkg\\index.js) & " ++
            "(echo BACKDOOR> node_modules\\pkg\\planted.js) & " ++
            "exit {2d}", .{ self.root_abs, self.top_abs, exit_code });
    }

    fn fingerprint(self: *Victim) ![]u8 {
        var lines: std.ArrayList([]u8) = .empty;
        defer {
            for (lines.items) |line| gpa.free(line);
            lines.deinit(gpa);
        }
        var walker = try self.tmp.dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(testing.io)) |entry| {
            if (isInternal(entry.path)) continue;
            const line = switch (entry.kind) {
                .file => blk: {
                    const bytes = try self.tmp.dir.readFileAlloc(testing.io, entry.path, gpa, .unlimited);
                    defer gpa.free(bytes);
                    break :blk try std.fmt.allocPrint(gpa, "{s} {x}", .{ entry.path, std.hash.Wyhash.hash(0, bytes) });
                },
                else => try std.fmt.allocPrint(gpa, "{s} {t}", .{ entry.path, entry.kind }),
            };
            errdefer gpa.free(line);
            try lines.append(gpa, line);
        }
        std.mem.sort([]u8, lines.items, {}, lessThan);
        return std.mem.join(gpa, "\n", lines.items);
    }

    fn isInternal(path: []const u8) bool {
        for ([_][]const u8{ "repo\\.git", "repo/.git", "repo\\.emetgate", "repo/.emetgate", "repo\\src\\math.ts", "repo/src/math.ts" }) |prefix| {
            if (std.mem.startsWith(u8, path, prefix)) return true;
        }
        return false;
    }

    fn lessThan(_: void, a: []u8, b: []u8) bool {
        return std.mem.lessThan(u8, a, b);
    }

    fn read(self: *Victim, sub_path: []const u8) ![]u8 {
        return self.tmp.dir.readFileAlloc(testing.io, sub_path, gpa, .unlimited);
    }
};

fn hashOfAdd(runtime: *Runtime, file_abs: []const u8) !symbol.Hash {
    const snapshot = try Snapshot.load(runtime, testing.io, .cwd(), file_abs);
    defer snapshot.destroy();
    const ref = try symbol.Ref.parse(gpa, "add");
    defer ref.deinit(gpa);
    return (try (try snapshot.symbols()).resolve(ref)).hash;
}

fn expectOnlyTargetChanged(victim: *Victim, before: []const u8, math_expected: []const u8) !void {
    const math = try victim.read("repo/src/math.ts");
    defer gpa.free(math);
    try testing.expectEqualStrings(math_expected, math);

    for ([_]struct { path: []const u8, bytes: []const u8 }{
        .{ .path = "repo/src/other.ts", .bytes = other_src },
        .{ .path = "repo/node_modules/pkg/index.js", .bytes = dependency_src },
        .{ .path = "outside.txt", .bytes = outside_src },
    }) |kept| {
        errdefer std.debug.print("modified outside the shadow: {s}\n", .{kept.path});
        const bytes = try victim.read(kept.path);
        defer gpa.free(bytes);
        try testing.expectEqualStrings(kept.bytes, bytes);
    }
    for ([_][]const u8{ "repo/planted.ts", "planted.txt", "repo/node_modules/pkg/planted.js", "repo/inside-shadow.txt" }) |planted| {
        errdefer std.debug.print("created outside the shadow: {s}\n", .{planted});
        try testing.expectError(error.FileNotFound, victim.tmp.dir.access(testing.io, planted, .{}));
    }

    const after = try victim.fingerprint();
    defer gpa.free(after);
    try testing.expectEqualStrings(before, after);
}

fn runAttack(exit_code: u8) !struct { victim: Victim, before: []u8, result: runner.Result } {
    var victim = try Victim.init();
    errdefer victim.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    const file = try std.fmt.allocPrint(gpa, "{s}\\src\\math.ts", .{victim.root_abs});
    defer gpa.free(file);
    const command = try victim.attack(exit_code);
    defer gpa.free(command);
    const before = try victim.fingerprint();
    errdefer gpa.free(before);

    const result = try runner.tryMutate(gpa, testing.io, runtime, .{
        .file_abs = file,
        .ref_text = "add",
        .expected_hash = .{ .present = try hashOfAdd(runtime, file) },
        .new_body = "{\n  return a - b;\n}",
        .test_command = command,
    });
    return .{ .victim = victim, .before = before, .result = result };
}

test "redteam sandbox: a passing test command cannot write outside the shadow, and only the target is committed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var run = try runAttack(0);
    defer run.victim.deinit();
    defer gpa.free(run.before);
    defer run.result.deinit(gpa);

    errdefer diagnostics.printResult(run.result);
    try testing.expect(run.result == .committed);
    try expectOnlyTargetChanged(&run.victim, run.before, "export function add(a: number, b: number): number {\n  return a - b;\n}\n");
}

test "redteam sandbox: a failing test command cannot leave writes behind outside the shadow" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var run = try runAttack(1);
    defer run.victim.deinit();
    defer gpa.free(run.before);
    defer run.result.deinit(gpa);

    try testing.expect(run.result == .rejected);
    try testing.expectEqual(sandbox.Outcome{ .exited = 1 }, run.result.rejected.outcome);
    try expectOnlyTargetChanged(&run.victim, run.before, math_src);
}

test "redteam sandbox: every failure to build the low-integrity token refuses to run the command at all" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    defer sandbox.injected_fault = null;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(cwd);
    try shadow.grantLowIntegrityWrite(cwd);

    inline for (std.meta.fields(sandbox.TokenStep)) |field| {
        const step: sandbox.TokenStep = @enumFromInt(field.value);
        errdefer std.debug.print("fault at {t} did not fail closed\n", .{step});
        sandbox.injected_fault = step;
        try testing.expectError(error.SandboxUnavailable, sandbox.run(gpa, testing.io, .{
            .argv = &.{ "cmd.exe", "/d", "/c", "echo ran> ran.txt" },
            .cwd = cwd,
            .limits = .{ .timeout_ms = 10_000 },
        }));
        try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "ran.txt", .{}));
    }

    sandbox.injected_fault = null;
    const report = try sandbox.run(gpa, testing.io, .{
        .argv = &.{ "cmd.exe", "/d", "/c", "echo ran> ran.txt" },
        .cwd = cwd,
        .limits = .{ .timeout_ms = 10_000 },
    });
    defer report.deinit(gpa);
    errdefer diagnostics.printReport(report);
    try testing.expect(report.passed());
    try tmp.dir.access(testing.io, "ran.txt", .{});
}

test "redteam sandbox: an unavailable sandbox rejects the proposal and leaves the repository untouched" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    defer sandbox.injected_fault = null;
    var victim = try Victim.init();
    defer victim.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");

    const file = try std.fmt.allocPrint(gpa, "{s}\\src\\math.ts", .{victim.root_abs});
    defer gpa.free(file);
    const command = try victim.attack(0);
    defer gpa.free(command);
    const before = try victim.fingerprint();
    defer gpa.free(before);

    sandbox.injected_fault = .verify;
    try testing.expectError(error.SandboxUnavailable, runner.tryMutate(gpa, testing.io, runtime, .{
        .file_abs = file,
        .ref_text = "add",
        .expected_hash = .{ .present = try hashOfAdd(runtime, file) },
        .new_body = "{\n  return a - b;\n}",
        .test_command = command,
    }));
    try expectOnlyTargetChanged(&victim, before, math_src);
}

test "redteam sandbox: the shadow lives under the operator's shadow root, outside the repository, flags a dot segment and is gone afterwards" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var victim = try Victim.init();
    defer victim.deinit();
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    const file = try std.fmt.allocPrint(gpa, "{s}\\src\\math.ts", .{victim.root_abs});
    defer gpa.free(file);

    for ([_]struct { dir: []const u8, dotted: bool }{ .{ .dir = "shadows", .dotted = false }, .{ .dir = ".dotted\\shadows", .dotted = true } }) |case| {
        const base = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ victim.top_abs, case.dir });
        defer gpa.free(base);
        const location = try shadow_root.locate(gpa, victim.root_abs, base);
        defer location.deinit(gpa);

        var trace: runner.Trace = .{};
        const result = try runner.tryMutate(gpa, testing.io, runtime, .{
            .file_abs = file,
            .ref_text = "add",
            .expected_hash = .{ .present = try hashOfAdd(runtime, file) },
            .new_body = "{\n  return a - b;\n}",
            .test_command = "cd & exit 1",
            .shadow_root = base,
            .trace = &trace,
        });
        defer result.deinit(gpa);
        try testing.expect(result == .rejected);
        errdefer std.debug.print("stdout: {s}\n", .{result.rejected.stdout});
        try testing.expect(std.ascii.indexOfIgnoreCase(result.rejected.stdout, location.shadow) != null);
        try testing.expect(std.ascii.indexOfIgnoreCase(location.shadow, victim.root_abs) == null);
        try testing.expectEqual(location.dotted(), trace.shadow_dotted);
        if (case.dotted) try testing.expect(trace.shadow_dotted);
        try testing.expectEqual(@as(usize, 1), trace.linked_files);
        try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, location.workspace, .{}));
    }
}
