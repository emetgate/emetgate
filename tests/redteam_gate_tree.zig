const std = @import("std");
const builtin = @import("builtin");
const diagnostics = @import("diagnostics.zig");
const shadow = @import("emetgate").shadow;
const shadow_root = @import("emetgate").shadow_root;
const gate_tree = @import("emetgate").gate_tree;
const sandbox = @import("emetgate").sandbox;

const testing = std.testing;
const gpa = testing.allocator;

const a_src = "export const a = 1;\n";
const b_src = "export function b() { return 2; }\n";
const dependency_src = "module.exports = 42;\n";
const secret_src = "machine-wide secret\n";

const Victim = struct {
    tmp: testing.TmpDir,
    top_abs: [:0]u8,
    root_abs: []u8,
    base_abs: []u8,
    shadow_abs: []u8,
    private: []const []const u8 = &.{},
    workspace: ?shadow.Shadow = null,

    fn init() !Victim {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo/src");
        try tmp.dir.createDirPath(testing.io, "repo/node_modules/pkg");
        try tmp.dir.createDirPath(testing.io, "outside");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/a.ts", .data = a_src });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/b.ts", .data = b_src });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/node_modules/pkg/index.js", .data = dependency_src });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "outside/secret.txt", .data = secret_src });
        const top_abs = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
        errdefer gpa.free(top_abs);
        const root_abs = try std.fmt.allocPrint(gpa, "{s}\\repo", .{top_abs});
        errdefer gpa.free(root_abs);
        const base_abs = try std.fmt.allocPrint(gpa, "{s}\\shadows", .{top_abs});
        errdefer gpa.free(base_abs);
        const key = shadow_root.repoKey(root_abs);
        const shadow_abs = try std.fmt.allocPrint(gpa, "{s}\\{s}\\shadow", .{ base_abs, &key });
        return .{ .tmp = tmp, .top_abs = top_abs, .root_abs = root_abs, .base_abs = base_abs, .shadow_abs = shadow_abs };
    }

    fn deinit(self: *Victim) void {
        if (self.workspace) |*workspace| workspace.finish();
        shadow.remove(testing.io, self.base_abs, self.shadow_abs) catch {};
        gpa.free(self.shadow_abs);
        gpa.free(self.base_abs);
        gpa.free(self.root_abs);
        gpa.free(self.top_abs);
        self.tmp.cleanup();
    }

    fn gate(self: *Victim) !void {
        if (self.workspace) |*workspace| workspace.finish();
        self.workspace = null;
        self.workspace = try shadow.Shadow.prepare(testing.io, .{
            .root_abs = self.root_abs,
            .base_abs = self.base_abs,
            .shadow_abs = self.shadow_abs,
            .files = &.{ "a.ts", "src/b.ts" },
            .linked = &.{"node_modules"},
            .tree = .kept,
            .private = self.private,
        });
        try testing.expectEqual(shadow.TreeMode.kept, self.workspace.?.use.mode);
    }

    fn inside(self: *Victim, command: []const u8) !void {
        errdefer std.debug.print("attack: {s}\n", .{command});
        const report = try sandbox.run(gpa, testing.io, .{
            .argv = &.{ "cmd.exe", "/d", "/c", command },
            .cwd = self.shadow_abs,
            .limits = .{ .timeout_ms = 20_000 },
        });
        report.deinit(gpa);
    }

    fn expectFile(self: *Victim, sub_path: []const u8, expected: []const u8) !void {
        errdefer std.debug.print("unexpected content: {s}\n", .{sub_path});
        const actual = try self.tmp.dir.readFileAlloc(testing.io, sub_path, gpa, .unlimited);
        defer gpa.free(actual);
        try testing.expectEqualStrings(expected, actual);
    }

    fn expectTree(self: *Victim, sub_path: []const u8, expected: []const u8) !void {
        errdefer std.debug.print("unexpected content in the tree: {s}\n", .{sub_path});
        const actual = try self.workspace.?.dir.readFileAlloc(testing.io, sub_path, gpa, .unlimited);
        defer gpa.free(actual);
        try testing.expectEqualStrings(expected, actual);
    }

    fn expectGone(self: *Victim, sub_path: []const u8) !void {
        errdefer std.debug.print("still in the tree: {s}\n", .{sub_path});
        try testing.expectError(error.FileNotFound, self.workspace.?.dir.access(testing.io, sub_path, .{}));
    }

    fn expectSameFile(self: *Victim, real: []const u8, kept: []const u8) !void {
        errdefer std.debug.print("not the working file itself: {s}\n", .{kept});
        const a = try self.tmp.dir.statFile(testing.io, real, .{});
        const b = try self.workspace.?.dir.statFile(testing.io, kept, .{});
        try testing.expectEqual(a.inode, b.inode);
    }

    fn expectRealUntouched(self: *Victim) !void {
        try self.expectFile("repo/a.ts", a_src);
        try self.expectFile("repo/src/b.ts", b_src);
        try self.expectFile("repo/node_modules/pkg/index.js", dependency_src);
        try self.expectFile("outside/secret.txt", secret_src);
        for ([_][]const u8{ "repo/planted.ts", "repo/src/moved.ts", "repo/out", "outside/planted.txt", "outside/b.ts", "repo/a.ts.extra" }) |absent| {
            errdefer std.debug.print("appeared outside the tree: {s}\n", .{absent});
            try testing.expectError(error.FileNotFound, self.tmp.dir.access(testing.io, absent, .{}));
        }
        const stat = try self.tmp.dir.statFile(testing.io, "repo/a.ts", .{});
        try testing.expectEqual(@as(u64, a_src.len), stat.size);
    }

    fn abs(self: *Victim, buf: []u8, sub_path: []const u8) ![]u8 {
        return std.fmt.bufPrint(buf, "{s}\\{s}", .{ self.top_abs, sub_path });
    }
};

test "redteam gate tree: every write the sandbox tries on a linked tracked file is denied and the working file stays as it was" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var victim = try Victim.init();
    defer victim.deinit();
    try victim.gate();
    try victim.gate();
    try victim.inside("ren src\\b.ts moved.ts");
    try victim.gate();

    for ([_][]const u8{
        "echo BACKDOOR> a.ts",
        "echo BACKDOOR>> a.ts",
        "copy /y nul a.ts",
        "copy /y src\\b.ts a.ts",
        "attrib +r +h a.ts",
        "echo BACKDOOR> a.ts:hidden",
        "mklink /H a.ts.extra a.ts",
        "mklink /H ..\\..\\..\\repo\\a.ts.extra a.ts",
        "echo BACKDOOR>> src\\b.ts",
        "echo BACKDOOR>> node_modules\\pkg\\index.js",
    }) |command| {
        try victim.inside(command);
        try victim.expectRealUntouched();
        try victim.expectTree("a.ts", a_src);
        try victim.expectTree("src/b.ts", b_src);
        try victim.expectSameFile("repo/a.ts", "a.ts");
    }
    try victim.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/a.ts", .data = a_src });
}

test "redteam gate tree: what the sandbox may do to names is seen and undone by the next call" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var victim = try Victim.init();
    defer victim.deinit();
    try victim.gate();

    try victim.inside("del /f /q a.ts & echo FORGED> a.ts");
    try victim.inside("ren src\\b.ts moved.ts");
    try victim.inside("echo FORGED> t.tmp & move /y t.tmp node_modules\\pkg\\index.js");
    try victim.inside("echo junk> planted.ts & mkdir out\\deep & echo junk> out\\deep\\o.js");
    try victim.inside("ren node_modules nm2 & mkdir node_modules\\pkg & echo FORGED> node_modules\\pkg\\index.js");
    try victim.expectRealUntouched();
    try victim.expectTree("a.ts", "FORGED\r\n");

    try victim.gate();
    try victim.inside("echo BACKDOOR>> a.ts & echo BACKDOOR>> src\\b.ts & echo BACKDOOR>> node_modules\\pkg\\index.js");
    try victim.expectRealUntouched();
    try victim.expectTree("a.ts", a_src);
    try victim.expectTree("src/b.ts", b_src);
    try victim.expectTree("node_modules/pkg/index.js", dependency_src);
    try victim.expectSameFile("repo/a.ts", "a.ts");
    try victim.expectSameFile("repo/src/b.ts", "src/b.ts");
    try victim.expectSameFile("repo/node_modules/pkg/index.js", "node_modules/pkg/index.js");
    for ([_][]const u8{ "src/moved.ts", "planted.ts", "out", "nm2", "t.tmp" }) |gone| try victim.expectGone(gone);
}

test "redteam gate tree: a file a test left behind is gone when the next call starts" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var victim = try Victim.init();
    defer victim.deinit();
    try victim.gate();
    try victim.inside("echo leaked> leak.txt & mkdir coverage & echo leaked> coverage\\lcov.info & echo leaked> src\\generated.ts");
    try victim.expectTree("leak.txt", "leaked \r\n");

    try victim.gate();
    for ([_][]const u8{ "leak.txt", "coverage", "src/generated.ts" }) |gone| try victim.expectGone(gone);
    try victim.expectRealUntouched();
}

test "redteam gate tree: a junction, a symlink and a hard link planted in the tree are removed without being followed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var victim = try Victim.init();
    defer victim.deinit();
    try victim.gate();

    try victim.inside("mklink /J jump ..\\..\\..\\outside & mklink escape.txt ..\\..\\..\\outside\\secret.txt & mklink /H hard.txt ..\\..\\..\\outside\\secret.txt");
    try victim.inside("echo BACKDOOR> jump\\planted.txt");
    try victim.expectRealUntouched();

    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const outside = try victim.abs(&target_buf, "outside");
    try shadow.createJunction(testing.io, try std.fmt.bufPrint(&link_buf, "{s}\\jump2", .{victim.shadow_abs}), outside);
    try victim.workspace.?.dir.rename("src", victim.workspace.?.dir, "src.away", testing.io);
    try shadow.createJunction(testing.io, try std.fmt.bufPrint(&link_buf, "{s}\\src", .{victim.shadow_abs}), outside);
    try victim.workspace.?.dir.rename("node_modules", victim.workspace.?.dir, "nm.away", testing.io);
    try shadow.createJunction(testing.io, try std.fmt.bufPrint(&link_buf, "{s}\\node_modules", .{victim.shadow_abs}), outside);

    try victim.gate();
    for ([_][]const u8{ "jump", "jump2", "escape.txt", "hard.txt", "src.away", "nm.away" }) |gone| try victim.expectGone(gone);
    try victim.expectTree("src/b.ts", b_src);
    try victim.expectTree("node_modules/pkg/index.js", dependency_src);
    try victim.expectSameFile("repo/src/b.ts", "src/b.ts");
    try victim.expectRealUntouched();
    var outside_dir = try victim.tmp.dir.openDir(testing.io, "outside", .{ .iterate = true });
    defer outside_dir.close(testing.io);
    var it = outside_dir.iterate();
    var names: usize = 0;
    while (try it.next(testing.io)) |_| names += 1;
    try testing.expectEqual(@as(usize, 1), names);
}

test "redteam gate tree: a working file the sandbox could write is a private copy, so a write to it stays in the tree" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var victim = try Victim.init();
    defer victim.deinit();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try shadow.grantLowIntegrityWrite(try victim.abs(&buf, "repo\\a.ts"));
    try victim.gate();
    try testing.expectEqual(@as(usize, 1), victim.workspace.?.use.private_copies);

    try victim.inside("echo BACKDOOR>> a.ts");
    const written = try victim.workspace.?.dir.readFileAlloc(testing.io, "a.ts", gpa, .unlimited);
    defer gpa.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "BACKDOOR") != null);
    try victim.expectRealUntouched();

    try victim.gate();
    try victim.expectTree("a.ts", a_src);
    try victim.expectRealUntouched();
}

test "redteam gate tree: a test that writes a tracked file in place is refused in the kept tree and served by a private prefix" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var victim = try Victim.init();
    defer victim.deinit();
    try victim.gate();
    try victim.inside("echo SNAPSHOT> src\\b.ts");
    try victim.expectTree("src/b.ts", b_src);

    victim.private = &.{"src"};
    try victim.gate();
    try testing.expectEqual(@as(usize, 1), victim.workspace.?.use.private_copies);
    try victim.inside("echo SNAPSHOT> src\\b.ts");
    try victim.expectTree("src/b.ts", "SNAPSHOT\r\n");
    try victim.expectRealUntouched();

    try victim.gate();
    try victim.expectTree("src/b.ts", b_src);
    try victim.expectRealUntouched();
}

test "redteam gate tree: an edit the user makes in place and a replace-style save both reach the next gate" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var victim = try Victim.init();
    defer victim.deinit();
    try victim.gate();

    var file = try victim.tmp.dir.openFile(testing.io, "repo/a.ts", .{ .mode = .read_write });
    try file.writePositionalAll(testing.io, "EXPORT", 0);
    file.close(testing.io);
    try victim.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/b.ts.tmp", .data = "export function b() { return 3; }\n" });
    try victim.tmp.dir.rename("repo/src/b.ts.tmp", victim.tmp.dir, "repo/src/b.ts", testing.io);

    try victim.gate();
    try victim.inside("type a.ts > seen_a.txt & type src\\b.ts > seen_b.txt");
    try victim.expectTree("seen_a.txt", "EXPORT const a = 1;\n");
    try victim.expectTree("seen_b.txt", "export function b() { return 3; }\n");
    try victim.expectSameFile("repo/src/b.ts", "src/b.ts");
}

test "redteam gate tree: a call that stops at any step of the rebuild is followed by a call that ends with the proved tree" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    defer gate_tree.injected_fault = null;
    var steps: usize = 0;
    while (steps < 64) : (steps += 1) {
        var victim = try Victim.init();
        defer victim.deinit();
        try victim.gate();
        try victim.inside("del /f /q a.ts & echo FORGED> a.ts & ren src\\b.ts moved.ts & mkdir out & echo junk> out\\o.js & del /f /q node_modules\\pkg\\index.js");

        gate_tree.injected_fault = steps;
        const interrupted = victim.gate();
        gate_tree.injected_fault = null;
        const finished = if (interrupted) |_| true else |err| blk: {
            try testing.expectEqual(error.GateTreeInjected, err);
            break :blk false;
        };

        errdefer std.debug.print("after a stop at step {d}\n", .{steps});
        try victim.gate();
        try victim.expectTree("a.ts", a_src);
        try victim.expectTree("src/b.ts", b_src);
        try victim.expectTree("node_modules/pkg/index.js", dependency_src);
        try victim.expectSameFile("repo/a.ts", "a.ts");
        try victim.expectSameFile("repo/src/b.ts", "src/b.ts");
        for ([_][]const u8{ "src/moved.ts", "out" }) |gone| try victim.expectGone(gone);
        try victim.expectRealUntouched();
        if (finished) {
            try testing.expect(steps >= 5);
            return;
        }
    }
    return error.TestUnexpectedResult;
}

test "redteam gate tree: a kept tree whose repository is gone is removed by the sweep and its files are only unlinked" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var victim = try Victim.init();
    defer victim.deinit();
    try victim.gate();
    victim.workspace.?.finish();
    victim.workspace = null;
    try victim.tmp.dir.createDirPath(testing.io, "elsewhere");
    try victim.tmp.dir.rename("repo", victim.tmp.dir, "elsewhere/repo", testing.io);

    try testing.expectEqual(@as(usize, 1), try shadow_root.sweep(gpa, testing.io, victim.base_abs, ""));
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, victim.shadow_abs, .{}));
    try victim.expectFile("elsewhere/repo/a.ts", a_src);
    try victim.expectFile("elsewhere/repo/node_modules/pkg/index.js", dependency_src);
    const stat = try victim.tmp.dir.statFile(testing.io, "elsewhere/repo/a.ts", .{});
    try testing.expect(stat.nlink == 1);
}
