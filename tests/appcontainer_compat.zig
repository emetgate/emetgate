const std = @import("std");
const builtin = @import("builtin");
const test_util = @import("emetgate").test_util;
const sandbox = @import("emetgate").sandbox;
const shadow = @import("emetgate").shadow;
const shadow_root = @import("emetgate").shadow_root;
const appcontainer = @import("emetgate").appcontainer;

const testing = std.testing;
const gpa = testing.allocator;

const Mode = enum { low, regular, lpac };

const Bench = struct {
    regular: appcontainer.Profile,
    lpac: appcontainer.Profile,
    base_abs: []u8,
    location: ?shadow_root.Location = null,
    work_abs: []const u8 = "",

    var serial: u32 = 0;

    fn init() !Bench {
        return initWith(true);
    }

    fn initWith(grant: bool) !Bench {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const local = try sandbox.environmentValue(arena_state.allocator(), std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA")) orelse return error.SkipZigTest;
        serial += 1;
        const base_abs = try std.fmt.allocPrint(gpa, "{s}\\emetgate-redteam\\compat-{d}-{d}", .{ local, GetCurrentProcessId(), serial });
        errdefer gpa.free(base_abs);
        try std.Io.Dir.cwd().createDirPath(testing.io, base_abs);
        errdefer std.Io.Dir.cwd().deleteTree(testing.io, base_abs) catch {};
        var regular = try appcontainer.Profile.create(false);
        errdefer regular.deinit();
        var lpac = try appcontainer.Profile.create(true);
        errdefer lpac.deinit();
        if (grant) try regular.allowWrite(base_abs);
        if (grant) try lpac.allowWrite(base_abs);
        return .{ .regular = regular, .lpac = lpac, .base_abs = base_abs };
    }

    fn deinit(self: *Bench) void {
        if (self.location) |location| {
            shadow.remove(testing.io, location.base, location.shadow) catch {};
            location.deinit(gpa);
        }
        self.lpac.deinit();
        self.regular.deinit();
        std.Io.Dir.cwd().deleteTree(testing.io, self.base_abs) catch {};
        if (std.fs.path.dirname(self.base_abs)) |parent| std.Io.Dir.cwd().deleteDir(testing.io, parent) catch {};
        gpa.free(self.base_abs);
    }

    fn place(self: *Bench, root_abs: []const u8) !void {
        const location = try shadow_root.locate(gpa, root_abs, self.base_abs);
        self.location = location;
        self.work_abs = location.shadow;
    }

    fn emptyShadow(self: *Bench) !void {
        try self.place(self.base_abs);
        try std.Io.Dir.cwd().createDirPath(testing.io, self.work_abs);
        try shadow.grantLowIntegrityWrite(self.work_abs);
    }

    fn repoShadow(self: *Bench, root_abs: []const u8) !void {
        try self.place(root_abs);
        const files = try shadow.trackedFiles(gpa, testing.io, root_abs);
        defer {
            shadow.freeFileList(gpa, files);
            gpa.free(files);
        }
        var workspace = try shadow.Shadow.prepare(testing.io, .{
            .root_abs = root_abs,
            .base_abs = self.location.?.base,
            .shadow_abs = self.work_abs,
            .files = files,
            .linked = &.{"node_modules"},
        });
        workspace.close();
    }

    fn measure(self: *Bench, label: []const u8, mode: Mode, argv: []const []const u8, timeout_ms: u64) !void {
        const backend: sandbox.Backend = switch (mode) {
            .low => .low_integrity,
            .regular => .{ .app_container = &self.regular },
            .lpac => .{ .app_container = &self.lpac },
        };
        const report = sandbox.run(gpa, testing.io, .{
            .argv = argv,
            .cwd = self.work_abs,
            .limits = .{ .timeout_ms = timeout_ms, .max_output_bytes = 4 * 1024 * 1024 },
            .backend = backend,
        }) catch |err| {
            std.debug.print("[compat] {s} {t}: refused {t}\n", .{ label, mode, err });
            return;
        };
        defer report.deinit(gpa);
        const head = report.stderr[0..@min(report.stderr.len, 1500)];
        const tail = report.stderr[report.stderr.len -| 400..];
        const out_tail = report.stdout[report.stdout.len -| 400..];
        std.debug.print("[compat] {s} {t} in {s}: outcome {any}, passed {any}, {d} ms\n[compat-stderr-head] {s}\n[compat-stderr] {s}\n[compat-stdout] {s}\n", .{
            label,
            mode,
            self.work_abs,
            report.outcome,
            report.passed(),
            report.duration_ns / std.time.ns_per_ms,
            head,
            tail,
            out_tail,
        });
    }
};

fn writeInShadow(bench: *Bench, name: []const u8, data: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(testing.io, bench.work_abs, .{});
    defer dir.close(testing.io);
    try dir.writeFile(testing.io, .{ .sub_path = name, .data = data });
}

fn evalRoot(arena: std.mem.Allocator, name: []const u8) !?[]u8 {
    const base = try sandbox.environmentValue(arena, std.unicode.utf8ToUtf16LeStringLiteral("EMETGATE_COMPAT_EVAL")) orelse return null;
    return try std.fmt.allocPrint(arena, "{s}\\{s}", .{ base, name });
}

const node_script = "process.stdout.write('ok');\n";
const zig_fixture = "const std = @import(\"std\");\npub fn build(b: *std.Build) void {\n    _ = b;\n}\n";
const mocha_argv = [_][]const u8{ "node", "node_modules/mocha/bin/mocha.js", "--require", "test/support/env", "--reporter", "dot", "--check-leaks", "test/", "test/acceptance/" };

test "compat: node under the low-integrity token, a regular app container and lpac" {
    try test_util.slow();
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    inline for (.{ Mode.low, Mode.regular, Mode.lpac }) |mode| {
        var bench = try Bench.initWith(mode != .low);
        defer bench.deinit();
        try bench.emptyShadow();
        try writeInShadow(&bench, "probe.js", node_script);
        try bench.measure("node -e", mode, &.{ "node", "-e", "process.exit(0)" }, 60_000);
        try bench.measure("node shadow script", mode, &.{ "node", "probe.js" }, 60_000);
    }
}

test "compat: zig under the low-integrity token and a regular app container" {
    try test_util.slow();
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    inline for (.{ Mode.low, Mode.regular }) |mode| {
        var bench = try Bench.initWith(mode != .low);
        defer bench.deinit();
        try bench.emptyShadow();
        try writeInShadow(&bench, "build.zig", zig_fixture);
        try bench.measure("zig version", mode, &.{ "zig", "version" }, 60_000);
        try bench.measure("zig build", mode, &.{ "zig", "build" }, 300_000);
        try bench.measure("zig build with shadow caches", mode, &.{ "zig", "build", "--global-cache-dir", "zig-global", "--cache-dir", "zig-local" }, 300_000);
    }
}

test "compat: express npm test through a hardlinked shadow" {
    try test_util.slow();
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const root = try evalRoot(arena_state.allocator(), "express-test") orelse return error.SkipZigTest;
    inline for (.{ Mode.low, Mode.regular }) |mode| {
        var bench = try Bench.initWith(mode != .low);
        defer bench.deinit();
        try bench.repoShadow(root);
        try bench.measure("express npm test", mode, &.{ "cmd.exe", "/d", "/c", "npm test" }, 300_000);
        try bench.measure("express mocha direct", mode, &mocha_argv, 300_000);
    }
}

test "compat: eslint npm test through a hardlinked shadow" {
    try test_util.slow();
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const root = try evalRoot(arena_state.allocator(), "eslint-test") orelse return error.SkipZigTest;
    inline for (.{ Mode.regular, Mode.low }) |mode| {
        var bench = try Bench.initWith(mode != .low);
        defer bench.deinit();
        try bench.repoShadow(root);
        try bench.measure("eslint npm test", mode, &.{ "cmd.exe", "/d", "/c", "npm test" }, 900_000);
    }
}

extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) std.os.windows.DWORD;

test "compat: the low-integrity baseline with and without the app container grant on the base" {
    try test_util.slow();
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    inline for (.{ false, true }) |grant| {
        var bench = try Bench.initWith(grant);
        defer bench.deinit();
        try bench.emptyShadow();
        try writeInShadow(&bench, "probe.js", "process.stdout.write('ok');\n");
        const label = if (grant) "granted base" else "plain base";
        try bench.measure(label ++ " cmd cd", .low, &.{ "cmd.exe", "/d", "/c", "cd" }, 60_000);
        try bench.measure(label ++ " node script", .low, &.{ "node", "probe.js" }, 60_000);
    }
}
