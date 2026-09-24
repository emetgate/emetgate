const std = @import("std");
const git_fixture = @import("git_fixture.zig");
const symbol = @import("emetgate").symbol;
const Runtime = @import("emetgate").runtime.Runtime;
const Snapshot = @import("emetgate").loader.Snapshot;

const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const Repo = struct {
    tmp: testing.TmpDir,
    root_abs: [:0]u8,

    pub const source = "export function add(a: number, b: number): number {\n  return a + b;\n}\n";

    pub fn init() !Repo {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo/src");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/math.ts", .data = source });
        const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", testing.allocator);
        errdefer testing.allocator.free(root_abs);

        try git_fixture.initRepo(root_abs);
        try git(root_abs, &.{ "add", "." });
        try git(root_abs, &.{ "commit", "-q", "-m", "init" });
        return .{ .tmp = tmp, .root_abs = root_abs };
    }

    pub fn git(root_abs: []const u8, args: []const []const u8) !void {
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

    pub fn deinit(self: *Repo) void {
        testing.allocator.free(self.root_abs);
        self.tmp.cleanup();
    }

    pub fn filePath(self: *Repo, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}\\src\\math.ts", .{self.root_abs});
    }

    pub fn read(self: *Repo) ![]u8 {
        return self.tmp.dir.readFileAlloc(testing.io, "repo/src/math.ts", testing.allocator, .unlimited);
    }
};

pub fn hashOfRef(gpa: Allocator, io: std.Io, runtime: *Runtime, file_abs: []const u8, ref_text: []const u8) !symbol.Hash {
    const snapshot = try Snapshot.load(runtime, io, .cwd(), file_abs);
    defer snapshot.destroy();
    const table = try snapshot.symbols();
    const ref = try symbol.Ref.parse(gpa, ref_text);
    defer ref.deinit(gpa);
    return (try table.resolve(ref)).hash;
}

pub const TwoFile = struct {
    tmp: testing.TmpDir,
    root_abs: [:0]u8,

    pub const a_src = "export function add(a: number, b: number): number {\n  return a + b;\n}\n";
    pub const b_src = "export function twice(x: number): number {\n  return x + x;\n}\n";

    pub fn init() !TwoFile {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo/src");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/a.ts", .data = a_src });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/b.ts", .data = b_src });
        const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", testing.allocator);
        errdefer testing.allocator.free(root_abs);
        try git_fixture.initRepo(root_abs);
        try Repo.git(root_abs, &.{ "add", "." });
        try Repo.git(root_abs, &.{ "commit", "-q", "-m", "init" });
        return .{ .tmp = tmp, .root_abs = root_abs };
    }

    pub fn deinit(self: *TwoFile) void {
        testing.allocator.free(self.root_abs);
        self.tmp.cleanup();
    }

    pub fn pathA(self: *TwoFile, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}\\src\\a.ts", .{self.root_abs});
    }
    pub fn pathB(self: *TwoFile, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}\\src\\b.ts", .{self.root_abs});
    }
    pub fn readA(self: *TwoFile) ![]u8 {
        return self.tmp.dir.readFileAlloc(testing.io, "repo/src/a.ts", testing.allocator, .unlimited);
    }
    pub fn readB(self: *TwoFile) ![]u8 {
        return self.tmp.dir.readFileAlloc(testing.io, "repo/src/b.ts", testing.allocator, .unlimited);
    }
};

pub const crash_command = "exit -1073741502";
