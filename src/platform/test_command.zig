const std = @import("std");
const repo = @import("repo.zig");

const Allocator = std.mem.Allocator;

pub const config_file = ".emetgaterc.json";
pub const detect = "\x00detect";
pub const unverified_command = "exit 0";
pub const unverified_status = "unverified_no_tests";
const max_manifest_bytes = 1024 * 1024;
const npm_placeholder = "no test specified";

threadlocal var unverified: bool = false;

pub fn takeUnverified() bool {
    defer unverified = false;
    return unverified;
}

pub fn detects(given: []const u8) bool {
    return std.mem.eql(u8, given, detect);
}

pub fn resolveTestCommand(gpa: Allocator, io: std.Io, file_abs: []const u8, given: []const u8, allow_repo_config: bool) ![]u8 {
    const detecting = detects(given);
    if (given.len != 0 and !detecting) return gpa.dupe(u8, given);

    const root = try repo.toplevelOf(gpa, io, file_abs);
    defer gpa.free(root);
    const repo_path = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ root, config_file });
    defer gpa.free(repo_path);

    if (allow_repo_config) {
        if (try readConfigCommand(gpa, io, repo_path, .test_cmd)) |command| return command;
    } else if (!detecting and try fileExists(io, repo_path)) return error.UntrustedRepoConfig;
    if (!detecting) return error.NoTestCommand;
    if (try detectIn(gpa, io, root)) |command| return gpa.dupe(u8, command);
    unverified = true;
    return gpa.dupe(u8, unverified_command);
}

const Marker = struct { file: []const u8, command: []const u8 };

const markers = [_]Marker{
    .{ .file = "build.zig", .command = "zig build test" },
    .{ .file = "Cargo.toml", .command = "cargo test" },
    .{ .file = "go.mod", .command = "go test ./..." },
    .{ .file = "pyproject.toml", .command = "python -m pytest" },
    .{ .file = "pytest.ini", .command = "python -m pytest" },
};

pub fn detectIn(gpa: Allocator, io: std.Io, root_abs: []const u8) !?[]const u8 {
    var dir = std.Io.Dir.openDirAbsolute(io, root_abs, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    if (try packageTestScript(gpa, io, dir)) return "npm test";
    for (markers) |marker| {
        if (dir.access(io, marker.file, .{})) |_| return marker.command else |_| {}
    }
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.ascii.endsWithIgnoreCase(entry.name, ".sln") or std.ascii.endsWithIgnoreCase(entry.name, ".csproj")) return "dotnet test";
    }
    return null;
}

fn packageTestScript(gpa: Allocator, io: std.Io, dir: std.Io.Dir) !bool {
    const bytes = dir.readFileAlloc(io, "package.json", gpa, .limited(max_manifest_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer gpa.free(bytes);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const scripts = parsed.value.object.get("scripts") orelse return false;
    if (scripts != .object) return false;
    const script = scripts.object.get("test") orelse return false;
    if (script != .string) return false;
    if (std.mem.indexOf(u8, script.string, npm_placeholder) != null) return false;
    return std.mem.trim(u8, script.string, " \t").len != 0;
}

pub fn resolveTypecheckCommand(gpa: Allocator, io: std.Io, file_abs: []const u8, given: []const u8, allow_repo_config: bool) !?[]u8 {
    if (given.len != 0) return try gpa.dupe(u8, given);
    if (!allow_repo_config) return null;

    const root = try repo.toplevelOf(gpa, io, file_abs);
    defer gpa.free(root);
    const repo_path = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ root, config_file });
    defer gpa.free(repo_path);
    return readConfigCommand(gpa, io, repo_path, .typecheck_cmd);
}

const ConfigField = enum { test_cmd, typecheck_cmd };

fn readConfigCommand(gpa: Allocator, io: std.Io, path: []const u8, comptime field: ConfigField) !?[]u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer gpa.free(bytes);
    const parsed = std.json.parseFromSlice(struct { test_cmd: ?[]const u8 = null, typecheck_cmd: ?[]const u8 = null }, gpa, bytes, .{ .ignore_unknown_fields = true }) catch return error.InvalidConfig;
    defer parsed.deinit();
    const cmd = @field(parsed.value, @tagName(field)) orelse return null;
    if (cmd.len == 0) return null;
    return try gpa.dupe(u8, cmd);
}

fn fileExists(io: std.Io, path: []const u8) !bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}
