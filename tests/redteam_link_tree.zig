const std = @import("std");
const builtin = @import("builtin");
const diagnostics = @import("diagnostics.zig");
const shadow = @import("emetgate").shadow;
const sandbox = @import("emetgate").sandbox;

const testing = std.testing;
const gpa = testing.allocator;

const dependency_src = "module.exports = 42;\n";
const sibling_src = "module.exports = 7;\n";
const weak_src = "module.exports = 'weak';\n";
const secret_src = "machine-wide secret\n";

const Victim = struct {
    tmp: testing.TmpDir,
    top_abs: [:0]u8,
    root_abs: []u8,
    shadow_abs: []u8,
    workspace: shadow.Shadow,

    fn init() !Victim {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo/node_modules/pkg");
        try tmp.dir.createDirPath(testing.io, "outside");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/a.ts", .data = "export const a = 1;\n" });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/node_modules/pkg/index.js", .data = dependency_src });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/node_modules/pkg/sibling.js", .data = sibling_src });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/node_modules/pkg/weak.js", .data = weak_src });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "outside/secret.txt", .data = secret_src });
        const top_abs = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
        errdefer gpa.free(top_abs);
        const root_abs = try std.fmt.allocPrint(gpa, "{s}\\repo", .{top_abs});
        errdefer gpa.free(root_abs);
        const shadow_abs = try std.fmt.allocPrint(gpa, "{s}\\.emetgate\\shadow", .{root_abs});
        errdefer gpa.free(shadow_abs);

        var weak_buf: [std.fs.max_path_bytes]u8 = undefined;
        try shadow.grantLowIntegrityWrite(try std.fmt.bufPrint(&weak_buf, "{s}\\node_modules\\pkg\\weak.js", .{root_abs}));
        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        var target_buf: [std.fs.max_path_bytes]u8 = undefined;
        try shadow.createJunction(testing.io, try std.fmt.bufPrint(&link_buf, "{s}\\node_modules\\pkg\\escape", .{root_abs}), try std.fmt.bufPrint(&target_buf, "{s}\\outside", .{top_abs}));

        const workspace = try shadow.Shadow.prepare(testing.io, .{
            .root_abs = root_abs,
            .shadow_abs = shadow_abs,
            .files = &.{"a.ts"},
            .linked = &.{"node_modules"},
        });
        return .{ .tmp = tmp, .top_abs = top_abs, .root_abs = root_abs, .shadow_abs = shadow_abs, .workspace = workspace };
    }

    fn deinit(self: *Victim) void {
        self.workspace.close();
        shadow.remove(testing.io, self.root_abs, self.shadow_abs) catch {};
        gpa.free(self.shadow_abs);
        gpa.free(self.root_abs);
        gpa.free(self.top_abs);
        self.tmp.cleanup();
    }

    fn inside(self: *Victim, command: []const u8) !sandbox.Report {
        return sandbox.run(gpa, testing.io, .{
            .argv = &.{ "cmd.exe", "/d", "/c", command },
            .cwd = self.shadow_abs,
            .limits = .{ .timeout_ms = 20_000 },
        });
    }

    fn expectReal(self: *Victim, sub_path: []const u8, expected: []const u8) !void {
        errdefer std.debug.print("the real file changed: {s}\n", .{sub_path});
        const actual = try self.tmp.dir.readFileAlloc(testing.io, sub_path, gpa, .unlimited);
        defer gpa.free(actual);
        try testing.expectEqualStrings(expected, actual);
    }

    fn expectRealUntouched(self: *Victim) !void {
        try self.expectReal("repo/node_modules/pkg/index.js", dependency_src);
        try self.expectReal("repo/node_modules/pkg/sibling.js", sibling_src);
        try self.expectReal("repo/node_modules/pkg/weak.js", weak_src);
        try self.expectReal("outside/secret.txt", secret_src);
        try testing.expectError(error.FileNotFound, self.tmp.dir.access(testing.io, "repo/node_modules/pkg/planted.js", .{}));
        try testing.expectError(error.FileNotFound, self.tmp.dir.access(testing.io, "repo/node_modules/pkg/moved.js", .{}));
        try testing.expectError(error.FileNotFound, self.tmp.dir.access(testing.io, "outside/planted.txt", .{}));
    }
};

test "redteam link tree: the sandbox reads a dependency through its hardlink" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var victim = try Victim.init();
    defer victim.deinit();

    const report = try victim.inside("type node_modules\\pkg\\index.js > seen.txt");
    defer report.deinit(gpa);
    errdefer diagnostics.printReport(report);
    try testing.expect(report.passed());
    const seen = try victim.workspace.dir.readFileAlloc(testing.io, "seen.txt", gpa, .unlimited);
    defer gpa.free(seen);
    try testing.expectEqualStrings(dependency_src, seen);
}

test "redteam link tree: writing, appending, truncating or changing attributes through a hardlink leaves the real file as it was" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var victim = try Victim.init();
    defer victim.deinit();

    for ([_][]const u8{
        "echo BACKDOOR> node_modules\\pkg\\index.js",
        "echo BACKDOOR>> node_modules\\pkg\\index.js",
        "copy /y nul node_modules\\pkg\\index.js",
        "attrib +r +h node_modules\\pkg\\index.js",
        "echo BACKDOOR>> node_modules\\pkg\\weak.js",
    }) |command| {
        errdefer std.debug.print("attack: {s}\n", .{command});
        const report = try victim.inside(command);
        report.deinit(gpa);
        try victim.expectRealUntouched();
    }
    const copy = try victim.workspace.dir.readFileAlloc(testing.io, "node_modules/pkg/weak.js", gpa, .unlimited);
    defer gpa.free(copy);
    try testing.expect(std.mem.indexOf(u8, copy, "BACKDOOR") != null);
    try victim.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/node_modules/pkg/index.js", .data = dependency_src });
}

test "redteam link tree: deleting, renaming or adding files in the shadow never reaches the real dependency" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var victim = try Victim.init();
    defer victim.deinit();

    const report = try victim.inside("del /f /q node_modules\\pkg\\index.js & ren node_modules\\pkg\\sibling.js moved.js & echo BACKDOOR> node_modules\\pkg\\planted.js");
    defer report.deinit(gpa);
    try victim.expectRealUntouched();
    const planted = try victim.workspace.dir.readFileAlloc(testing.io, "node_modules/pkg/planted.js", gpa, .unlimited);
    gpa.free(planted);
}

test "redteam link tree: a junction inside a linked directory is not followed into the shadow" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var victim = try Victim.init();
    defer victim.deinit();

    try testing.expectError(error.FileNotFound, victim.workspace.dir.access(testing.io, "node_modules/pkg/escape", .{}));
    try testing.expectEqual(@as(usize, 1), victim.workspace.link_stats.skipped_links);
    const report = try victim.inside("echo BACKDOOR> node_modules\\pkg\\escape\\planted.txt");
    defer report.deinit(gpa);
    try victim.expectRealUntouched();
}

test "redteam link tree: removing the shadow deletes only the links and keeps every real file" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var victim = try Victim.init();
    defer victim.deinit();

    try shadow.remove(testing.io, victim.root_abs, victim.shadow_abs);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, victim.shadow_abs, .{}));
    try victim.expectRealUntouched();
    try victim.expectReal("repo/a.ts", "export const a = 1;\n");
}
