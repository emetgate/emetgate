const std = @import("std");
const repo = @import("repo.zig");

const Allocator = std.mem.Allocator;

pub const config_file = ".emetgaterc.json";
pub const detect = "\x00detect";
pub const unverified_command = "exit 0";
pub const unverified_status = "unverified_no_tests";
pub const markers_hint = "package.json scripts.test, a .csproj/.sln/.slnx, Cargo.toml, go.mod, pyproject.toml, pytest.ini, build.zig";
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
};

const python_markers = [_][]const u8{ "pyproject.toml", "pytest.ini", "tox.ini", "setup.cfg", "setup.py" };
const requirement_files = [_][]const u8{ "requirements.txt", "requirements-dev.txt", "requirements-test.txt", "dev-requirements.txt" };
pub const venv_dirs = [_][]const u8{ ".venv", "venv" };
const pytest_run = "-m pytest";
const unittest_run = "-m unittest discover";

threadlocal var python_command: [64]u8 = undefined;

pub fn detectIn(gpa: Allocator, io: std.Io, root_abs: []const u8) !?[]const u8 {
    var dir = std.Io.Dir.openDirAbsolute(io, root_abs, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    if (try packageTestScript(gpa, io, dir)) return "npm test";
    for (markers) |marker| {
        if (dir.access(io, marker.file, .{})) |_| return marker.command else |_| {}
    }
    for (python_markers) |marker| {
        if (dir.access(io, marker, .{})) |_| return pythonCommand(io, dir, pytest_run) else |_| {}
    }
    if (try requirementsProject(gpa, io, dir)) |run| return pythonCommand(io, dir, run);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (isDotnetRoot(entry.name)) return "dotnet test";
    }
    return nestedTestProject(io, dir);
}

const dotnet_roots = [_][]const u8{ ".sln", ".slnx", ".csproj", ".fsproj", ".vbproj" };
const dotnet_projects = [_][]const u8{ ".csproj", ".fsproj", ".vbproj" };
const skipped_dirs = [_][]const u8{ "bin", "obj", "node_modules", "packages", "target", "dist", "out" };
const max_project_depth = 2;

fn endsWithAny(name: []const u8, suffixes: []const []const u8) bool {
    for (suffixes) |suffix| {
        if (std.ascii.endsWithIgnoreCase(name, suffix)) return true;
    }
    return false;
}

fn isDotnetRoot(name: []const u8) bool {
    return endsWithAny(name, &dotnet_roots);
}

pub fn isTestProject(name: []const u8) bool {
    if (!endsWithAny(name, &dotnet_projects)) return false;
    return std.ascii.indexOfIgnoreCase(name, "test") != null;
}

fn skippedDir(name: []const u8) bool {
    if (name.len == 0 or name[0] == '.') return true;
    for (skipped_dirs) |skipped| {
        if (std.ascii.eqlIgnoreCase(name, skipped)) return true;
    }
    return false;
}

const Found = struct {
    count: usize = 0,
    path: [512]u8 = undefined,
    len: usize = 0,
};

threadlocal var nested_command: [600]u8 = undefined;

fn nestedTestProject(io: std.Io, dir: std.Io.Dir) ?[]const u8 {
    var found: Found = .{};
    var prefix: [512]u8 = undefined;
    findTestProjects(io, dir, &prefix, 0, 1, &found);
    if (found.count != 1) return null;
    return std.fmt.bufPrint(&nested_command, "dotnet test \"{s}\"", .{found.path[0..found.len]}) catch null;
}

fn findTestProjects(io: std.Io, dir: std.Io.Dir, prefix: *[512]u8, prefix_len: usize, depth: usize, found: *Found) void {
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory or skippedDir(entry.name)) continue;
        const sub_len = prefix_len + entry.name.len + 1;
        if (sub_len > prefix.len) continue;
        @memcpy(prefix[prefix_len..][0..entry.name.len], entry.name);
        prefix[prefix_len + entry.name.len] = '\\';
        var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
        defer sub.close(io);
        var files = sub.iterate();
        while (files.next(io) catch null) |file| {
            if (file.kind != .file or !isTestProject(file.name)) continue;
            found.count += 1;
            if (sub_len + file.name.len > found.path.len) continue;
            @memcpy(found.path[0..sub_len], prefix[0..sub_len]);
            @memcpy(found.path[sub_len..][0..file.name.len], file.name);
            found.len = sub_len + file.name.len;
        }
        if (depth < max_project_depth) findTestProjects(io, sub, prefix, sub_len, depth + 1, found);
    }
}

fn venvOf(io: std.Io, dir: std.Io.Dir) ?[]const u8 {
    for (venv_dirs) |venv| {
        var buffer: [32]u8 = undefined;
        const exe = std.fmt.bufPrint(&buffer, "{s}\\Scripts\\python.exe", .{venv}) catch continue;
        if (dir.access(io, exe, .{})) |_| return venv else |_| {}
    }
    return null;
}

fn pythonCommand(io: std.Io, dir: std.Io.Dir, run: []const u8) []const u8 {
    const venv = venvOf(io, dir) orelse return if (std.mem.eql(u8, run, pytest_run)) "python -m pytest" else "python -m unittest discover";
    return std.fmt.bufPrint(&python_command, "{s}\\Scripts\\python {s}", .{ venv, run }) catch "python -m pytest";
}

fn requirementsProject(gpa: Allocator, io: std.Io, dir: std.Io.Dir) !?[]const u8 {
    var listed_pytest = false;
    var any = false;
    for (requirement_files) |name| {
        const bytes = dir.readFileAlloc(io, name, gpa, .limited(max_manifest_bytes)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer gpa.free(bytes);
        any = true;
        if (requiresPytest(bytes)) listed_pytest = true;
    }
    if (!any or !hasPythonTests(io, dir)) return null;
    if (listed_pytest or venvHasPytest(io, dir)) return pytest_run;
    return unittest_run;
}

pub fn requiresPytest(bytes: []const u8) bool {
    var lines = std.mem.tokenizeAny(u8, bytes, "\r\n");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (!std.ascii.startsWithIgnoreCase(line, "pytest")) continue;
        if (line.len == "pytest".len) return true;
        const next = line["pytest".len];
        if (std.mem.indexOfScalar(u8, " \t=<>!~;[@", next) != null) return true;
    }
    return false;
}

fn venvHasPytest(io: std.Io, dir: std.Io.Dir) bool {
    const venv = venvOf(io, dir) orelse return false;
    var buffer: [64]u8 = undefined;
    const site = std.fmt.bufPrint(&buffer, "{s}\\Lib\\site-packages\\pytest", .{venv}) catch return false;
    if (dir.access(io, site, .{})) |_| return true else |_| return false;
}

fn hasPythonTests(io: std.Io, dir: std.Io.Dir) bool {
    for ([_][]const u8{ "tests", "test" }) |name| {
        var sub = dir.openDir(io, name, .{}) catch continue;
        sub.close(io);
        return true;
    }
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.ascii.startsWithIgnoreCase(entry.name, "test_") and std.ascii.endsWithIgnoreCase(entry.name, ".py")) return true;
    }
    return false;
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
