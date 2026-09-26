const std = @import("std");
const git_fixture = @import("git_fixture.zig");
const server = @import("emetgate").server;
const Runtime = @import("emetgate").runtime.Runtime;

const testing = std.testing;
const gpa = testing.allocator;
const Value = std.json.Value;

pub const kept_src = "export const kept = 1;\n";
pub const dependency_src = "module.exports = 42;\n";
pub const outside_src = "machine-wide secret\n";

pub const Repo = struct {
    tmp: testing.TmpDir,
    top_abs: [:0]u8,
    root_abs: [:0]u8,

    pub fn init(scripts: []const struct { name: []const u8, body: []const u8 }) !Repo {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo/src");
        try tmp.dir.createDirPath(testing.io, "repo/node_modules/pkg");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/src/kept.ts", .data = kept_src });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/node_modules/pkg/index.js", .data = dependency_src });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.gitignore", .data = "node_modules/\n" });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "outside.txt", .data = outside_src });
        for (scripts) |script| {
            const path = try std.fmt.allocPrint(gpa, "repo/{s}", .{script.name});
            defer gpa.free(path);
            try tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = script.body });
        }
        const top_abs = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
        errdefer gpa.free(top_abs);
        const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", gpa);
        errdefer gpa.free(root_abs);
        try git_fixture.initRepo(root_abs);
        try git(root_abs, &.{ "add", "." });
        try git(root_abs, &.{ "commit", "-q", "-m", "init" });
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

    pub fn commitScript(self: *Repo, name: []const u8, body: []const u8) !void {
        const path = try std.fmt.allocPrint(gpa, "repo/{s}", .{name});
        defer gpa.free(path);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = body });
        try git(self.root_abs, &.{ "add", "." });
        try git(self.root_abs, &.{ "commit", "-q", "-m", name });
    }

    pub fn deinit(self: *Repo) void {
        gpa.free(self.root_abs);
        gpa.free(self.top_abs);
        self.tmp.cleanup();
    }

    pub fn fingerprint(self: *Repo) ![]u8 {
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
        for ([_][]const u8{ "repo\\.git", "repo/.git", "repo\\.emetgate", "repo/.emetgate" }) |prefix| {
            if (std.mem.startsWith(u8, path, prefix)) return true;
        }
        return false;
    }

    fn lessThan(_: void, a: []u8, b: []u8) bool {
        return std.mem.lessThan(u8, a, b);
    }

    pub fn exists(self: *Repo, sub_path: []const u8) bool {
        self.tmp.dir.access(testing.io, sub_path, .{}) catch return false;
        return true;
    }
};

pub const Reply = struct {
    parsed: std.json.Parsed(Value),
    is_error: bool,
    text: []const u8,
    body: ?std.json.Parsed(Value) = null,

    pub fn deinit(self: *Reply) void {
        if (self.body) |body| body.deinit();
        self.parsed.deinit();
    }

    pub fn field(self: *Reply, name: []const u8) !?Value {
        if (self.body == null) self.body = try std.json.parseFromSlice(Value, gpa, self.text, .{ .allocate = .alloc_always });
        return self.body.?.value.object.get(name);
    }

    pub fn string(self: *Reply, name: []const u8) ![]const u8 {
        const value = (try self.field(name)) orelse return error.FieldMissing;
        return value.string;
    }
};

pub fn policyWith(root_abs: []const u8, allowed: []const []const u8) server.Policy {
    var policy: server.Policy = .{ .root = root_abs };
    for (allowed) |entry| {
        policy.allow_run[policy.allow_run_len] = entry;
        policy.allow_run_len += 1;
    }
    return policy;
}

pub fn call(policy: server.Policy, args: anytype) !Reply {
    const runtime = try Runtime.create(gpa);
    defer runtime.destroy() catch @panic("live snapshots");
    var line: std.Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    var js: std.json.Stringify = .{ .writer = &line.writer };
    try js.write(.{ .jsonrpc = "2.0", .id = 1, .method = "tools/call", .params = .{ .name = "emetgate_run", .arguments = args } });

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try server.handleMessageObserved(gpa, testing.io, runtime, line.written(), &out.writer, null, policy);

    const parsed = try std.json.parseFromSlice(Value, gpa, out.written(), .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    const result = parsed.value.object.get("result") orelse return error.NotAToolResult;
    const content = result.object.get("content").?.array.items[0];
    return .{ .parsed = parsed, .is_error = result.object.get("isError").?.bool, .text = content.object.get("text").?.string };
}
