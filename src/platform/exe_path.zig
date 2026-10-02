const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

const Allocator = std.mem.Allocator;

pub const Error = error{ ExecutableNotFound, NameInvalid, OutOfMemory };

const default_pathext = ".COM;.EXE;.BAT;.CMD";

pub fn resolve(gpa: Allocator, name: []const u8, repo_root: ?[]const u8) Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path_list = try environment(arena, std.unicode.utf8ToUtf16LeStringLiteral("PATH")) orelse "";
    const pathext = try environment(arena, std.unicode.utf8ToUtf16LeStringLiteral("PATHEXT")) orelse default_pathext;
    const cwd = try currentDirectory(arena);
    return resolveIn(gpa, name, .{ .path = path_list, .pathext = pathext, .cwd = cwd, .repo_root = repo_root });
}

pub fn git(gpa: Allocator, repo_root: ?[]const u8) error{ GitNotFound, OutOfMemory }![]u8 {
    return resolve(gpa, "git", repo_root) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ExecutableNotFound, error.NameInvalid => error.GitNotFound,
    };
}

pub fn system(gpa: Allocator, name: []const u8) Error![]u8 {
    if (!plainName(name)) return error.NameInvalid;
    var buf: [windows.PATH_MAX_WIDE]u16 = undefined;
    const len = win.GetSystemDirectoryW(&buf, buf.len);
    if (len == 0 or len >= buf.len) return error.ExecutableNotFound;
    const dir = std.unicode.wtf16LeToWtf8Alloc(gpa, buf[0..len]) catch return error.OutOfMemory;
    defer gpa.free(dir);
    const full = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ dir, name });
    errdefer gpa.free(full);
    if (!isFile(full)) return error.ExecutableNotFound;
    return full;
}

pub const Search = struct {
    path: []const u8,
    pathext: []const u8 = default_pathext,
    cwd: ?[]const u8 = null,
    repo_root: ?[]const u8 = null,
};

pub fn resolveIn(gpa: Allocator, name: []const u8, search: Search) Error![]u8 {
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, 0) != null) return error.NameInvalid;
    if (std.mem.indexOfAny(u8, name, "\\/:") != null) {
        if (!fullyQualified(name)) return error.NameInvalid;
        if (!isFile(name)) return error.ExecutableNotFound;
        return gpa.dupe(u8, name);
    }
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(gpa);
    const own_extension = hasListedExtension(name, search.pathext);
    var cwd_buf: [windows.PATH_MAX_WIDE]u16 = undefined;
    var root_buf: [windows.PATH_MAX_WIDE]u16 = undefined;
    var entry_buf: [windows.PATH_MAX_WIDE]u16 = undefined;
    const cwd_final = if (search.cwd) |cwd| finalName(&cwd_buf, cwd) else null;
    const root_final = if (search.repo_root) |root| finalName(&root_buf, root) else null;
    var entries = std.mem.tokenizeScalar(u8, search.path, ';');
    while (entries.next()) |raw| {
        const dir = std.mem.trimEnd(u8, std.mem.trim(u8, raw, " \""), "\\/");
        if (dir.len == 0 or !fullyQualified(dir)) continue;
        const dir_final = finalName(&entry_buf, dir);
        if (search.cwd) |cwd| if (inside(dir, dir_final, cwd, cwd_final)) continue;
        if (search.repo_root) |root| if (inside(dir, dir_final, root, root_final)) continue;
        if (own_extension) {
            if (try candidate(gpa, &scratch, dir, name, "")) |found| return found;
            continue;
        }
        var extensions = std.mem.tokenizeScalar(u8, search.pathext, ';');
        while (extensions.next()) |ext| {
            const trimmed = std.mem.trim(u8, ext, " ");
            if (trimmed.len < 2 or trimmed[0] != '.') continue;
            if (try candidate(gpa, &scratch, dir, name, trimmed)) |found| return found;
        }
    }
    return error.ExecutableNotFound;
}

fn candidate(gpa: Allocator, scratch: *std.ArrayList(u8), dir: []const u8, name: []const u8, ext: []const u8) Error!?[]u8 {
    scratch.clearRetainingCapacity();
    try scratch.print(gpa, "{s}\\{s}{s}", .{ dir, name, ext });
    if (!isFile(scratch.items)) return null;
    return try gpa.dupe(u8, scratch.items);
}

fn plainName(name: []const u8) bool {
    return name.len != 0 and std.mem.indexOfAny(u8, name, "\\/:\x00") == null;
}

fn hasListedExtension(name: []const u8, pathext: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const ext = name[dot..];
    var extensions = std.mem.tokenizeScalar(u8, pathext, ';');
    while (extensions.next()) |listed| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, listed, " "), ext)) return true;
    }
    return false;
}

fn fullyQualified(path: []const u8) bool {
    if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '\\' or path[2] == '/')) return true;
    return path.len > 2 and (path[0] == '\\' or path[0] == '/') and (path[1] == '\\' or path[1] == '/');
}

pub fn finalName(buf: []u16, path: []const u8) ?[]const u16 {
    var wide: [windows.PATH_MAX_WIDE:0]u16 = undefined;
    const prefix = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\");
    const long = path.len >= long_from and std.ascii.isAlphabetic(path[0]) and path[1] == ':';
    const offset: usize = if (long) prefix.len else 0;
    if (offset + path.len >= wide.len) return null;
    if (long) @memcpy(wide[0..prefix.len], prefix);
    const len = std.unicode.wtf8ToWtf16Le(wide[offset..], path) catch return null;
    for (wide[offset .. offset + len]) |*unit| {
        if (unit.* == '/') unit.* = '\\';
    }
    wide[offset + len] = 0;
    const handle = win.CreateFileW(&wide, win.file_read_attributes, win.file_share_all, null, win.open_existing, win.file_flag_backup_semantics, null);
    if (handle == windows.INVALID_HANDLE_VALUE) return null;
    defer windows.CloseHandle(handle);
    const got = win.GetFinalPathNameByHandleW(handle, buf.ptr, @intCast(buf.len), win.volume_name_nt);
    if (got == 0 or got >= buf.len) return null;
    return buf[0..got];
}

const long_from: usize = 240;

fn inside(dir: []const u8, dir_final: ?[]const u16, base: []const u8, base_final: ?[]const u16) bool {
    if (dir_final != null and base_final != null) return withinWide(dir_final.?, base_final.?);
    return within(dir, base);
}

fn withinWide(dir: []const u16, base_raw: []const u16) bool {
    var base = base_raw;
    while (base.len != 0 and base[base.len - 1] == '\\') base = base[0 .. base.len - 1];
    if (base.len == 0 or dir.len < base.len) return false;
    for (dir[0..base.len], base) |a, b| {
        if (foldWide(a) != foldWide(b)) return false;
    }
    return dir.len == base.len or dir[base.len] == '\\';
}

fn foldWide(unit: u16) u16 {
    return if (unit < 128) std.ascii.toLower(@intCast(unit)) else unit;
}

fn within(dir: []const u8, base_raw: []const u8) bool {
    const base = std.mem.trimEnd(u8, base_raw, "\\/");
    if (base.len == 0 or dir.len < base.len) return false;
    for (dir[0..base.len], base) |a, b| {
        if (fold(a) != fold(b)) return false;
    }
    return dir.len == base.len or dir[base.len] == '\\' or dir[base.len] == '/';
}

fn fold(c: u8) u8 {
    return if (c == '/') '\\' else std.ascii.toLower(c);
}

fn isFile(path: []const u8) bool {
    var wide: [windows.PATH_MAX_WIDE:0]u16 = undefined;
    const len = std.unicode.wtf8ToWtf16Le(&wide, path) catch return false;
    if (len >= wide.len) return false;
    wide[len] = 0;
    const attributes = win.GetFileAttributesW(&wide);
    return attributes != win.invalid_file_attributes and attributes & win.file_attribute_directory == 0;
}

fn environment(arena: Allocator, name: [:0]const u16) Error!?[]u8 {
    const needed = win.GetEnvironmentVariableW(name.ptr, null, 0);
    if (needed == 0) return null;
    const value = try arena.alloc(u16, needed);
    const written = win.GetEnvironmentVariableW(name.ptr, value.ptr, needed);
    if (written == 0 or written >= needed) return null;
    return std.unicode.wtf16LeToWtf8Alloc(arena, value[0..written]) catch return error.OutOfMemory;
}

fn currentDirectory(arena: Allocator) Error!?[]u8 {
    var buf: [windows.PATH_MAX_WIDE]u16 = undefined;
    const len = win.GetCurrentDirectoryW(buf.len, &buf);
    if (len == 0 or len >= buf.len) return null;
    return std.unicode.wtf16LeToWtf8Alloc(arena, buf[0..len]) catch return error.OutOfMemory;
}

const win = struct {
    const invalid_file_attributes: windows.DWORD = 0xFFFFFFFF;
    const file_attribute_directory: windows.DWORD = 0x10;
    const file_read_attributes: windows.DWORD = 0x0080;
    const file_share_all: windows.DWORD = 0x00000007;
    const open_existing: windows.DWORD = 3;
    const file_flag_backup_semantics: windows.DWORD = 0x02000000;
    const volume_name_nt: windows.DWORD = 0x2;

    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: windows.DWORD, share: windows.DWORD, security: ?*anyopaque, disposition: windows.DWORD, flags: windows.DWORD, template: ?windows.HANDLE) callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn GetFinalPathNameByHandleW(file: windows.HANDLE, buffer: [*]u16, size: windows.DWORD, flags: windows.DWORD) callconv(.winapi) windows.DWORD;

    extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buffer: ?[*]u16, size: windows.DWORD) callconv(.winapi) windows.DWORD;
    extern "kernel32" fn GetCurrentDirectoryW(size: windows.DWORD, buffer: [*]u16) callconv(.winapi) windows.DWORD;
    extern "kernel32" fn GetSystemDirectoryW(buffer: [*]u16, size: windows.UINT) callconv(.winapi) windows.UINT;
    extern "kernel32" fn GetFileAttributesW(name: [*:0]const u16) callconv(.winapi) windows.DWORD;
};

const testing = std.testing;

const Layout = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,

    fn init() !Layout {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        for ([_][]const u8{ "tools", "later", "repo/bin", "work" }) |dir| try tmp.dir.createDirPath(testing.io, dir);
        for ([_][]const u8{ "tools/tool.bat", "later/tool.exe", "repo/bin/tool.exe", "work/tool.exe", "repo/tool.cmd" }) |file| {
            try tmp.dir.writeFile(testing.io, .{ .sub_path = file, .data = "x" });
        }
        const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        return .{ .tmp = tmp, .root = root };
    }

    fn deinit(self: *Layout) void {
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn join(self: Layout, buf: []u8, rel: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}\\{s}", .{ self.root, rel }) catch unreachable;
    }
};

test "exe path: only fully qualified PATH entries outside the working directory and the repository are searched, in PATHEXT order" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var layout = try Layout.init();
    defer layout.deinit();
    var b: [6][2048]u8 = undefined;
    const tools = layout.join(&b[0], "tools");
    const later = layout.join(&b[1], "later");
    const repo_root = layout.join(&b[2], "repo");
    const repo_bin = layout.join(&b[3], "repo\\bin");
    const work = layout.join(&b[4], "work");
    const path_list = try std.fmt.bufPrint(&b[5], "bin;{s};{s};{s};\"{s}\"", .{ repo_bin, work, repo_root, later });

    const found = try resolveIn(testing.allocator, "tool", .{ .path = path_list, .cwd = work, .repo_root = repo_root });
    defer testing.allocator.free(found);
    try expectPath(later, "tool.exe", found);

    const ordered = try std.fmt.bufPrint(&b[5], "{s};{s}", .{ tools, later });
    const bat = try resolveIn(testing.allocator, "tool", .{ .path = ordered });
    defer testing.allocator.free(bat);
    try expectPath(tools, "tool.bat", bat);
    const exe_first = try resolveIn(testing.allocator, "tool", .{ .path = ordered, .pathext = ".EXE" });
    defer testing.allocator.free(exe_first);
    try expectPath(later, "tool.exe", exe_first);
    const named = try resolveIn(testing.allocator, "tool.exe", .{ .path = ordered });
    defer testing.allocator.free(named);
    try expectPath(later, "tool.exe", named);
}

fn expectPath(dir: []const u8, file: []const u8, got: []const u8) !void {
    var buf: [2048]u8 = undefined;
    const want = try std.fmt.bufPrint(&buf, "{s}\\{s}", .{ dir, file });
    if (std.ascii.eqlIgnoreCase(want, got)) return;
    std.debug.print("want {s}, got {s}\n", .{ want, got });
    return error.TestUnexpectedResult;
}

test "exe path: a name found nowhere else, a relative name and a relative path entry are refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var layout = try Layout.init();
    defer layout.deinit();
    var b: [3][2048]u8 = undefined;
    const repo_root = layout.join(&b[0], "repo");
    const work = layout.join(&b[1], "work");
    const only_inside = try std.fmt.bufPrint(&b[2], "{s};{s};.;bin", .{ repo_root, work });
    try testing.expectError(error.ExecutableNotFound, resolveIn(testing.allocator, "tool", .{ .path = only_inside, .cwd = work, .repo_root = repo_root }));
    try testing.expectError(error.NameInvalid, resolveIn(testing.allocator, "bin\\tool.exe", .{ .path = only_inside }));
    try testing.expectError(error.NameInvalid, resolveIn(testing.allocator, "", .{ .path = only_inside }));
    try testing.expectError(error.ExecutableNotFound, resolveIn(testing.allocator, "missing-tool", .{ .path = only_inside }));

    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(cwd);
    try testing.expect(within(layout.root, cwd));
    var rel_buf: [2048]u8 = undefined;
    const relative = try std.fmt.bufPrint(&rel_buf, "{s}\\later", .{layout.root[cwd.len + 1 ..]});
    try testing.expectError(error.ExecutableNotFound, resolveIn(testing.allocator, "tool", .{ .path = relative }));
}

test "exe path: a PATH entry that reaches the repository or the working directory through a junction is still skipped" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var layout = try Layout.init();
    defer layout.deinit();
    var b: [6][2048]u8 = undefined;
    const repo_root = layout.join(&b[0], "repo");
    const later = layout.join(&b[1], "later");
    const alias = layout.join(&b[2], "alias");
    const work = layout.join(&b[3], "work");
    const work_alias = layout.join(&b[4], "work_alias");
    const cmd = try system(testing.allocator, "cmd.exe");
    defer testing.allocator.free(cmd);
    for ([_][2][]const u8{ .{ alias, repo_root }, .{ work_alias, work } }) |pair| {
        const made = try std.process.run(testing.allocator, testing.io, .{ .argv = &.{ cmd, "/d", "/c", "mklink", "/J", pair[0], pair[1] } });
        testing.allocator.free(made.stdout);
        testing.allocator.free(made.stderr);
        if (made.term != .exited or made.term.exited != 0) return error.SkipZigTest;
    }
    const path_list = try std.fmt.bufPrint(&b[5], "{s}\\bin;{s};{s}", .{ alias, work_alias, later });
    const found = try resolveIn(testing.allocator, "tool", .{ .path = path_list, .cwd = work, .repo_root = repo_root });
    defer testing.allocator.free(found);
    try expectPath(later, "tool.exe", found);
}

test "exe path: the system directory gives cmd.exe and the live PATH gives a program it holds" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const cmd = try system(testing.allocator, "cmd.exe");
    defer testing.allocator.free(cmd);
    try testing.expect(fullyQualified(cmd));
    try testing.expect(std.ascii.endsWithIgnoreCase(cmd, "\\cmd.exe"));
    try testing.expectError(error.NameInvalid, system(testing.allocator, "..\\cmd.exe"));
    const where = try resolve(testing.allocator, "where", null);
    defer testing.allocator.free(where);
    try testing.expect(fullyQualified(where));
}
