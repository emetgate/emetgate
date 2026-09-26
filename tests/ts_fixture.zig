const std = @import("std");
const git_fixture = @import("git_fixture.zig");
const support = @import("runner_support.zig");

const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const File = struct {
    rel: []const u8,
    text: []const u8,
};

pub const stub_dir = "tests/fixtures/typescript-stub";

pub const TsRepo = struct {
    tmp: testing.TmpDir,
    root_abs: [:0]u8,

    pub fn init(files: []const File) !TsRepo {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo");
        for (files) |file| {
            const sub = try std.fmt.allocPrint(testing.allocator, "repo/{s}", .{file.rel});
            defer testing.allocator.free(sub);
            if (std.fs.path.dirname(sub)) |dir| try tmp.dir.createDirPath(testing.io, dir);
            try tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = file.text });
        }
        const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", testing.allocator);
        errdefer testing.allocator.free(root_abs);
        try git_fixture.initRepo(root_abs);
        try support.Repo.git(root_abs, &.{ "add", "." });
        try support.Repo.git(root_abs, &.{ "commit", "-q", "-m", "init" });
        return .{ .tmp = tmp, .root_abs = root_abs };
    }

    pub fn deinit(self: *TsRepo) void {
        testing.allocator.free(self.root_abs);
        self.tmp.cleanup();
    }

    pub fn installStub(self: *TsRepo) !void {
        try self.tmp.dir.createDirPath(testing.io, "repo/node_modules/typescript");
        for ([_][]const u8{ "package.json", "typescript.js" }) |name| {
            const from = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ stub_dir, name });
            defer testing.allocator.free(from);
            const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, from, testing.allocator, .limited(1024 * 1024));
            defer testing.allocator.free(bytes);
            const to = try std.fmt.allocPrint(testing.allocator, "repo/node_modules/typescript/{s}", .{name});
            defer testing.allocator.free(to);
            try self.tmp.dir.writeFile(testing.io, .{ .sub_path = to, .data = bytes });
        }
        try self.setPlan("{}");
    }

    pub fn setPlan(self: *TsRepo, json: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/node_modules/typescript/plan.json", .data = json });
    }

    pub fn write(self: *TsRepo, rel: []const u8, text: []const u8) !void {
        const sub = try std.fmt.allocPrint(testing.allocator, "repo/{s}", .{rel});
        defer testing.allocator.free(sub);
        if (std.fs.path.dirname(sub)) |dir| try self.tmp.dir.createDirPath(testing.io, dir);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = text });
    }

    pub fn read(self: *TsRepo, rel: []const u8) ![]u8 {
        const sub = try std.fmt.allocPrint(testing.allocator, "repo/{s}", .{rel});
        defer testing.allocator.free(sub);
        return self.tmp.dir.readFileAlloc(testing.io, sub, testing.allocator, .unlimited);
    }

    pub fn exists(self: *TsRepo, rel: []const u8) bool {
        const sub = std.fmt.allocPrint(testing.allocator, "repo/{s}", .{rel}) catch return false;
        defer testing.allocator.free(sub);
        self.tmp.dir.access(testing.io, sub, .{}) catch return false;
        return true;
    }

    pub fn abs(self: *TsRepo, gpa: Allocator, rel: []const u8) ![]u8 {
        const joined = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ self.root_abs, rel });
        std.mem.replaceScalar(u8, joined, '/', '\\');
        return joined;
    }

    pub fn slashed(self: *TsRepo, gpa: Allocator, rel: []const u8) ![]u8 {
        const joined = try self.abs(gpa, rel);
        std.mem.replaceScalar(u8, joined, '\\', '/');
        return joined;
    }
};

pub const Loc = struct {
    rel: []const u8,
    needle: []const u8,
    nth: usize = 0,
    name: []const u8,
    prefix: bool = false,
    definition: bool = false,
};

pub fn offsetOf(text: []const u8, needle: []const u8, nth: usize, name: []const u8) u32 {
    var from: usize = 0;
    var seen: usize = 0;
    while (true) {
        const at = std.mem.indexOfPos(u8, text, from, needle).?;
        if (seen == nth) return @intCast(at + std.mem.indexOf(u8, needle, name).?);
        seen += 1;
        from = at + 1;
    }
}

pub fn locationsJson(gpa: Allocator, repo: *TsRepo, field: []const u8, locs: []const Loc) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer };
    try js.beginObject();
    try js.objectField(field);
    try js.beginArray();
    for (locs) |loc| {
        const text = try repo.read(loc.rel);
        defer testing.allocator.free(text);
        const start = offsetOf(text, loc.needle, loc.nth, loc.name);
        const file = try repo.slashed(gpa, loc.rel);
        defer gpa.free(file);
        try js.write(.{ .file = file, .start = start, .end = start + @as(u32, @intCast(loc.name.len)), .prefix = loc.prefix, .definition = loc.definition });
    }
    try js.endArray();
    try js.endObject();
    return out.toOwnedSlice();
}
