const std = @import("std");
const builtin = @import("builtin");
const shadow = @import("shadow.zig");
const cache_lease = @import("cache_lease.zig");
const install_probe = @import("install_probe.zig");
const user_rules = @import("user_rules.zig");
const self_update = @import("../update/update.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Environ = std.process.Environ;
const windows = std.os.windows;

pub const local_app_data_variable = "LOCALAPPDATA";
pub const program_subdir = "Programs\\emetgate";
pub const exe_names = [_][]const u8{ self_update.exe_asset, self_update.old_name, self_update.new_name };
pub const confirm_flag = "--yes";
pub const keep_cache_flag = "--keep-cache";
pub const max_depth: usize = 64;

pub const Options = struct {
    yes: bool = false,
    keep_cache: bool = false,
};

pub fn parse(args: []const [:0]const u8) ?Options {
    var options: Options = .{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, confirm_flag) and !options.yes) {
            options.yes = true;
        } else if (std.mem.eql(u8, arg, keep_cache_flag) and !options.keep_cache) {
            options.keep_cache = true;
        } else return null;
    }
    return options;
}

pub const Process = struct { pid: u32, image: []const u8 };

pub const PathValue = struct { text: []const u8, expand: bool };

pub const Facts = struct {
    local_app_data: []const u8,
    self_exe: []const u8,
    user_path: ?PathValue,
    program_entries: ?[]const []const u8,
    data_present: bool,
    data_bytes: u64,
    others: []const Process,
    keep_cache: bool,
    global_rules: ?GlobalRules = null,
};

pub const GlobalRules = struct {
    path: []const u8,
    count: ?usize,
};

pub const Plan = struct {
    program_dir: []const u8,
    program_present: bool,
    program_files: []const []const u8,
    program_extras: []const []const u8,
    self_in_program: bool,
    self_exe: []const u8,
    path_removed: []const []const u8,
    new_user_path: ?PathValue,
    data_dir: []const u8,
    data_present: bool,
    data_bytes: u64,
    keep_cache: bool,
    others: []const Process,
    global_rules: ?GlobalRules = null,

    pub fn removesData(self: Plan) bool {
        return self.data_present and !self.keep_cache;
    }

    pub fn nothingToDo(self: Plan) bool {
        return self.program_files.len == 0 and self.path_removed.len == 0 and !self.removesData();
    }
};

pub fn programDir(arena: Allocator, local_app_data: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}\\{s}", .{ trimSeparators(local_app_data), program_subdir });
}

pub fn dataDir(arena: Allocator, local_app_data: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}\\{s}", .{ trimSeparators(local_app_data), cache_lease.data_dir_name });
}

fn trimSeparators(path: []const u8) []const u8 {
    return std.mem.trimEnd(u8, path, "\\/");
}

fn samePath(a: []const u8, b: []const u8) bool {
    const left = trimSeparators(a);
    const right = trimSeparators(b);
    if (left.len != right.len) return false;
    for (left, right) |x, y| {
        const nx = if (x == '/') '\\' else std.ascii.toLower(x);
        const ny = if (y == '/') '\\' else std.ascii.toLower(y);
        if (nx != ny) return false;
    }
    return true;
}

pub fn isExeName(name: []const u8) bool {
    for (exe_names) |exe| if (std.ascii.eqlIgnoreCase(name, exe)) return true;
    return false;
}

pub fn expand(arena: Allocator, text: []const u8, env: *const Environ.Map) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '%') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '%')) |close| {
                const name = text[i + 1 .. close];
                if (name.len > 0 and std.unicode.wtf8ValidateSlice(name)) {
                    if (env.get(name)) |value| {
                        try out.appendSlice(arena, value);
                        i = close + 1;
                        continue;
                    }
                }
            }
        }
        try out.append(arena, text[i]);
        i += 1;
    }
    return out.items;
}

pub const PathEdit = struct { value: []const u8, removed: []const []const u8 };

pub fn withoutDir(arena: Allocator, raw: []const u8, dir: []const u8, env: *const Environ.Map) !PathEdit {
    var kept: std.ArrayList([]const u8) = .empty;
    var removed: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, raw, ';');
    while (parts.next()) |entry| {
        const bare = std.mem.trim(u8, entry, " \"");
        if (bare.len > 0 and samePath(try expand(arena, bare, env), dir)) {
            try removed.append(arena, entry);
            continue;
        }
        try kept.append(arena, entry);
    }
    if (removed.items.len == 0) return .{ .value = raw, .removed = &.{} };
    return .{ .value = try std.mem.join(arena, ";", kept.items), .removed = removed.items };
}

pub fn plan(arena: Allocator, facts: Facts, env: *const Environ.Map) !Plan {
    const program = try programDir(arena, facts.local_app_data);
    var files: std.ArrayList([]const u8) = .empty;
    var extras: std.ArrayList([]const u8) = .empty;
    if (facts.program_entries) |entries| for (entries) |name| {
        if (isExeName(name)) try files.append(arena, name) else try extras.append(arena, name);
    };
    const self_dir = std.fs.path.dirname(facts.self_exe) orelse "";
    var removed: []const []const u8 = &.{};
    var new_path: ?PathValue = null;
    if (facts.user_path) |path| {
        const edit = try withoutDir(arena, path.text, program, env);
        removed = edit.removed;
        if (removed.len > 0) new_path = .{ .text = edit.value, .expand = path.expand };
    }
    return .{
        .program_dir = program,
        .program_present = facts.program_entries != null,
        .program_files = files.items,
        .program_extras = extras.items,
        .self_in_program = samePath(self_dir, program),
        .self_exe = facts.self_exe,
        .path_removed = removed,
        .new_user_path = new_path,
        .data_dir = try dataDir(arena, facts.local_app_data),
        .data_present = facts.data_present,
        .data_bytes = facts.data_bytes,
        .keep_cache = facts.keep_cache,
        .others = facts.others,
        .global_rules = if (facts.data_present) facts.global_rules else null,
    };
}

fn writeGlobalRules(out: *std.Io.Writer, rules: GlobalRules, removed: bool) std.Io.Writer.Error!void {
    try out.print("  rules    {s} (", .{rules.path});
    if (rules.count) |count| {
        try out.print("your {d} global rule{s}, applied in every repository", .{ count, if (count == 1) "" else "s" });
    } else {
        try out.writeAll("your global rules; the file cannot be read");
    }
    try out.writeAll(if (removed) "; removed with the data folder, " ++ keep_cache_flag ++ " keeps them)\n" else "; kept with the data folder)\n");
}

pub fn writeSize(out: *std.Io.Writer, bytes: u64) std.Io.Writer.Error!void {
    const kb: u64 = 1024;
    if (bytes < kb * kb) return out.print("{d} KB", .{(bytes + kb - 1) / kb});
    const units = [_][]const u8{ "MB", "GB", "TB" };
    var scale: u64 = kb * kb;
    var unit: usize = 0;
    while (unit + 1 < units.len and bytes >= scale * kb) : (unit += 1) scale *= kb;
    const tenths = (bytes * 10 + scale / 2) / scale;
    try out.print("{d}.{d} {s}", .{ tenths / 10, tenths % 10, units[unit] });
}

pub fn writePlan(out: *std.Io.Writer, p: Plan, confirmed: bool) std.Io.Writer.Error!void {
    if (!confirmed) try out.writeAll("emetgate uninstall: dry run, nothing is removed yet.\n\n");
    if (p.nothingToDo()) {
        try out.writeAll("Nothing to remove: no emetgate program folder, PATH entry or data folder was found");
        if (p.data_present and p.keep_cache) try out.writeAll(" apart from the data folder you keep");
        try out.writeAll(".\n");
    } else {
        try out.writeAll(if (confirmed) "Removing:\n" else "Would remove:\n");
        if (p.program_files.len > 0) {
            try out.print("  program  {s} (", .{p.program_dir});
            for (p.program_files, 0..) |name, i| try out.print("{s}{s}", .{ if (i == 0) "" else ", ", name });
            try out.writeAll(if (p.program_extras.len == 0) ", then the folder)\n" else ")\n");
        }
        for (p.path_removed) |entry| try out.print("  PATH     {s} from your user PATH\n", .{entry});
        if (p.removesData()) {
            try out.print("  data     {s} (", .{p.data_dir});
            try writeSize(out, p.data_bytes);
            try out.writeAll(": caches, lockdown files, logs)\n");
            if (p.global_rules) |rules| try writeGlobalRules(out, rules, true);
        }
    }
    const kept_data = p.data_present and p.keep_cache;
    if (kept_data or p.program_extras.len > 0 or (!p.self_in_program and p.self_exe.len > 0)) {
        try out.writeAll("Kept:\n");
        if (kept_data) {
            try out.print("  data     {s} (", .{p.data_dir});
            try writeSize(out, p.data_bytes);
            try out.print(", {s})\n", .{keep_cache_flag});
            if (p.global_rules) |rules| try writeGlobalRules(out, rules, false);
        }
        for (p.program_extras) |name| try out.print("  {s}\\{s} (not an emetgate file)\n", .{ p.program_dir, name });
        if (!p.self_in_program and p.self_exe.len > 0) try out.print("  {s} (this emetgate is not in the installer's folder; delete it yourself if you want it gone)\n", .{p.self_exe});
    }
    try out.writeAll("Not touched: the .emetgate folder and the emetgate entry in .mcp.json of each project. Delete them by hand where you no longer want them.\n");
    if (p.others.len > 0) {
        try out.print("\nWarning: {d} other emetgate process{s} running. Close {s} first; uninstall --yes does not run while they do and never stops them:\n", .{ p.others.len, if (p.others.len == 1) " is" else "es are", if (p.others.len == 1) "it" else "them" });
        for (p.others) |process| try out.print("  pid {d}  {s}\n", .{ process.pid, process.image });
    }
    if (!confirmed and !p.nothingToDo()) try out.print("\nTo remove these, run: emetgate uninstall {s}{s}\n", .{ confirm_flag, if (p.keep_cache or !p.data_present) "" else "   (add " ++ keep_cache_flag ++ " to keep the data folder)" });
}

pub const CleanupError = error{ UnsafePath, OutOfMemory };

pub fn cleanupCommand(arena: Allocator, cmd_exe: []const u8, program_dir: []const u8, self_exe: []const u8) CleanupError![]const u8 {
    for ([_][]const u8{ cmd_exe, program_dir, self_exe }) |path| {
        if (std.mem.indexOfAny(u8, path, "\"%\r\n") != null) return error.UnsafePath;
    }
    var others: std.ArrayList(u8) = .empty;
    for (exe_names) |name| try others.print(arena, " \"{s}\\{s}\"", .{ program_dir, name });
    return std.fmt.allocPrint(
        arena,
        "\"{s}\" /d /v:off /c \"(for /l %i in (1,1,30) do @(if exist \"{s}\" (ping -n 2 127.0.0.1 >nul & del /f /q \"{s}\" 2>nul))) & del /f /q{s} 2>nul & rd \"{s}\" 2>nul\"",
        .{ cmd_exe, self_exe, self_exe, others.items, program_dir },
    );
}

pub fn manualCommand(arena: Allocator, program_dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "rd /s /q \"{s}\"", .{program_dir});
}

pub fn measure(io: std.Io, dir_abs: []const u8) u64 {
    var dir = Dir.openDirAbsolute(io, dir_abs, .{ .iterate = true, .follow_symlinks = false }) catch return 0;
    defer dir.close(io);
    var total: u64 = 0;
    measureTree(io, dir, &total, 0);
    return total;
}

fn measureTree(io: std.Io, dir: Dir, total: *u64, depth: usize) void {
    if (depth > max_depth) return;
    var it = dir.iterate();
    while (it.next(io) catch return) |item| switch (item.kind) {
        .directory => {
            var child = dir.openDir(io, item.name, .{ .iterate = true, .follow_symlinks = false }) catch continue;
            defer child.close(io);
            measureTree(io, child, total, depth + 1);
        },
        .file => {
            const stat = dir.statFile(io, item.name, .{ .follow_symlinks = false }) catch continue;
            if (stat.nlink <= 1) total.* +|= stat.size;
        },
        else => {},
    };
}

fn listDir(arena: Allocator, io: std.Io, dir_abs: []const u8) !?[]const []const u8 {
    if (builtin.os.tag == .windows and try shadow.isReparsePoint(dir_abs)) return error.ProgramFolderIsLink;
    var dir = Dir.openDirAbsolute(io, dir_abs, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |item| try names.append(arena, try arena.dupe(u8, item.name));
    return names.items;
}

fn holdsGlobalRules(arena: Allocator, data_abs: []const u8) !bool {
    const resolved = user_rules.dir(arena) catch |err| {
        if (err == error.OutOfMemory) return err;
        return false;
    };
    return samePath(resolved, try user_rules.dirIn(arena, data_abs));
}

pub fn globalRulesIn(arena: Allocator, io: std.Io, data_abs: []const u8) !?GlobalRules {
    const dir = try user_rules.dirIn(arena, data_abs);
    const path = try user_rules.ledgerPath(arena, dir);
    const count = user_rules.countIn(arena, io, dir) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{ .path = path, .count = null };
    };
    return .{ .path = path, .count = count orelse return null };
}

fn exists(io: std.Io, path: []const u8) bool {
    Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

pub fn run(arena: Allocator, io: std.Io, env: *const Environ.Map, options: Options, out: *std.Io.Writer) !u8 {
    const self_exe = std.process.executablePathAlloc(io, arena) catch "";
    if (builtin.os.tag != .windows) {
        try out.print("emetgate uninstall removes what install.ps1 installs, and that installer is Windows only.\nDelete {s} yourself.\n", .{if (self_exe.len > 0) self_exe else "the emetgate binary"});
        return 1;
    }
    const local = env.get(local_app_data_variable) orelse return error.LocalAppDataUnavailable;
    const data = try dataDir(arena, local);
    const data_present = exists(io, data);
    const facts: Facts = .{
        .local_app_data = local,
        .self_exe = self_exe,
        .user_path = try registry.readUserPath(arena),
        .program_entries = try listDir(arena, io, try programDir(arena, local)),
        .data_present = data_present,
        .data_bytes = if (data_present) measure(io, data) else 0,
        .others = try otherProcesses(arena),
        .keep_cache = options.keep_cache,
        .global_rules = if (data_present and try holdsGlobalRules(arena, data)) try globalRulesIn(arena, io, data) else null,
    };
    const p = try plan(arena, facts, env);
    if (!options.yes) {
        try writePlan(out, p, false);
        return 0;
    }
    if (p.others.len > 0) {
        try writePlan(out, p, false);
        try out.writeAll("\nNothing was removed.\n");
        return 1;
    }
    try writePlan(out, p, true);
    try out.writeAll("\n");
    return apply(arena, io, env, p, out);
}

fn apply(arena: Allocator, io: std.Io, env: *const Environ.Map, p: Plan, out: *std.Io.Writer) !u8 {
    var failed = false;
    if (p.new_user_path) |value| {
        if (registry.writeUserPath(arena, value)) {
            registry.announce();
            try out.writeAll("Removed the PATH entry. New terminals no longer find emetgate.\n");
        } else |err| {
            failed = true;
            try out.print("Could not change your user PATH ({t}); remove {s} from it in Settings > Environment variables.\n", .{ err, p.program_dir });
        }
    }
    if (p.removesData()) {
        if (shadow.clearTemp(io, p.data_dir)) {
            try out.print("Removed {s}.\n", .{p.data_dir});
        } else |err| {
            failed = true;
            try out.print("Could not remove all of {s} ({t}); delete what is left by hand.\n", .{ p.data_dir, err });
        }
    }
    if (p.program_files.len > 0) {
        if (p.self_in_program) {
            if (scheduleCleanup(arena, env, p)) {
                try out.print("{s} is removed a few seconds after this command exits.\nIf it is still there later, run: {s}\n", .{ p.program_dir, try manualCommand(arena, p.program_dir) });
            } else |err| {
                failed = true;
                try out.print("Could not schedule the removal of {s} ({t}). After this command exits, run: {s}\n", .{ p.program_dir, err, try manualCommand(arena, p.program_dir) });
            }
        } else if (removeProgram(arena, io, p)) {
            try out.print("Removed {s}.\n", .{p.program_dir});
        } else |err| {
            failed = true;
            try out.print("Could not remove {s} ({t}). Run: {s}\n", .{ p.program_dir, err, try manualCommand(arena, p.program_dir) });
        }
    }
    return if (failed) 1 else 0;
}

fn removeProgram(arena: Allocator, io: std.Io, p: Plan) !void {
    for (p.program_files) |name| try Dir.cwd().deleteFile(io, try std.fmt.allocPrint(arena, "{s}\\{s}", .{ p.program_dir, name }));
    if (p.program_extras.len == 0) try Dir.cwd().deleteDir(io, p.program_dir);
}

fn scheduleCleanup(arena: Allocator, env: *const Environ.Map, p: Plan) !void {
    const system_root = env.get("SystemRoot") orelse env.get("windir") orelse return error.SystemRootUnavailable;
    const cmd_exe = try std.fmt.allocPrint(arena, "{s}\\System32\\cmd.exe", .{trimSeparators(system_root)});
    const line = try cleanupCommand(arena, cmd_exe, p.program_dir, p.self_exe);
    const cwd = std.fs.path.dirname(p.program_dir) orelse return error.UnsafePath;
    try detached.spawn(arena, cmd_exe, line, cwd);
}

const detached = struct {
    const create_no_window: windows.DWORD = 0x08000000;
    const detached_process: windows.DWORD = 0x00000008;
    const create_new_process_group: windows.DWORD = 0x00000200;
    const create_unicode_environment: windows.DWORD = 0x00000400;

    extern "kernel32" fn CreateProcessW(application: ?[*:0]const u16, command_line: ?[*:0]u16, process_attributes: ?*anyopaque, thread_attributes: ?*anyopaque, inherit_handles: windows.BOOL, flags: windows.DWORD, environment: ?*anyopaque, cwd: ?[*:0]const u16, startup: *windows.STARTUPINFOW, info: *windows.PROCESS.INFORMATION) callconv(.winapi) windows.BOOL;

    fn spawn(arena: Allocator, exe: []const u8, line: []const u8, cwd: []const u8) !void {
        const exe_w = try std.unicode.wtf8ToWtf16LeAllocZ(arena, exe);
        const line_w = try std.unicode.wtf8ToWtf16LeAllocZ(arena, line);
        const cwd_w = try std.unicode.wtf8ToWtf16LeAllocZ(arena, cwd);
        var startup = std.mem.zeroes(windows.STARTUPINFOW);
        startup.cb = @sizeOf(windows.STARTUPINFOW);
        var info: windows.PROCESS.INFORMATION = undefined;
        if (CreateProcessW(exe_w.ptr, line_w.ptr, null, null, .FALSE, create_no_window | detached_process | create_new_process_group, null, cwd_w.ptr, &startup, &info) == .FALSE) return error.CleanupSpawnFailed;
        windows.CloseHandle(info.hThread);
        windows.CloseHandle(info.hProcess);
    }
};

const registry = struct {
    const Hkey = *opaque {};
    const current_user: Hkey = @ptrFromInt(0x80000001);
    const key_query_value: u32 = 0x0001;
    const key_set_value: u32 = 0x0002;
    const reg_sz: windows.DWORD = 1;
    const reg_expand_sz: windows.DWORD = 2;
    const error_success: i32 = 0;
    const error_file_not_found: i32 = 2;
    const subkey = std.unicode.utf8ToUtf16LeStringLiteral("Environment");
    const value_name = std.unicode.utf8ToUtf16LeStringLiteral("Path");

    extern "advapi32" fn RegOpenKeyExW(key: Hkey, sub_key: [*:0]const u16, options: windows.DWORD, sam: u32, result: *Hkey) callconv(.winapi) i32;
    extern "advapi32" fn RegQueryValueExW(key: Hkey, name: [*:0]const u16, reserved: ?*windows.DWORD, kind: ?*windows.DWORD, data: ?[*]u8, size: ?*windows.DWORD) callconv(.winapi) i32;
    extern "advapi32" fn RegSetValueExW(key: Hkey, name: [*:0]const u16, reserved: windows.DWORD, kind: windows.DWORD, data: [*]const u8, size: windows.DWORD) callconv(.winapi) i32;
    extern "advapi32" fn RegCloseKey(key: Hkey) callconv(.winapi) i32;
    extern "user32" fn SendMessageTimeoutW(window: usize, message: u32, wparam: usize, lparam: [*:0]const u16, flags: u32, timeout: u32, result: ?*usize) callconv(.winapi) isize;

    fn open(access: u32) !?Hkey {
        var key: Hkey = undefined;
        return switch (RegOpenKeyExW(current_user, subkey, 0, access, &key)) {
            error_success => key,
            error_file_not_found => null,
            else => error.RegistryOpenFailed,
        };
    }

    fn readUserPath(arena: Allocator) !?PathValue {
        const key = (try open(key_query_value)) orelse return null;
        defer _ = RegCloseKey(key);
        var kind: windows.DWORD = 0;
        var size: windows.DWORD = 0;
        switch (RegQueryValueExW(key, value_name, null, &kind, null, &size)) {
            error_success => {},
            error_file_not_found => return null,
            else => return error.RegistryReadFailed,
        }
        if (kind != reg_sz and kind != reg_expand_sz) return error.UserPathNotText;
        const units = try arena.alignedAlloc(u16, .of(u16), size / 2 + 1);
        var got: windows.DWORD = @intCast(units.len * 2);
        if (RegQueryValueExW(key, value_name, null, &kind, @ptrCast(units.ptr), &got) != error_success) return error.RegistryReadFailed;
        const text = std.mem.sliceTo(units[0 .. got / 2], 0);
        return .{ .text = try std.unicode.wtf16LeToWtf8Alloc(arena, text), .expand = kind == reg_expand_sz };
    }

    fn writeUserPath(arena: Allocator, value: PathValue) !void {
        const key = (try open(key_set_value)) orelse return error.RegistryOpenFailed;
        defer _ = RegCloseKey(key);
        const wide = try std.unicode.wtf8ToWtf16LeAllocZ(arena, value.text);
        const bytes: windows.DWORD = @intCast((wide.len + 1) * 2);
        if (RegSetValueExW(key, value_name, 0, if (value.expand) reg_expand_sz else reg_sz, @ptrCast(wide.ptr), bytes) != error_success) return error.RegistryWriteFailed;
    }

    fn announce() void {
        _ = SendMessageTimeoutW(0xffff, 0x001A, 0, std.unicode.utf8ToUtf16LeStringLiteral("Environment"), 0x0002, 5000, null);
    }
};

fn otherProcesses(arena: Allocator) ![]const Process {
    const found = try install_probe.emetgateProcesses(arena);
    const list = try arena.alloc(Process, found.len);
    for (found, list) |process, *item| item.* = .{ .pid = process.pid, .image = process.image };
    return list;
}

const testing = std.testing;

fn testEnv(gpa: Allocator) !Environ.Map {
    var env: Environ.Map = .init(gpa);
    errdefer env.deinit();
    try env.put("LOCALAPPDATA", "C:\\Users\\u\\AppData\\Local");
    try env.put("USERPROFILE", "C:\\Users\\u");
    return env;
}

fn testFacts(path: ?PathValue) Facts {
    return .{
        .local_app_data = "C:\\Users\\u\\AppData\\Local",
        .self_exe = "C:\\Users\\u\\AppData\\Local\\Programs\\emetgate\\emetgate.exe",
        .user_path = path,
        .program_entries = &.{ "emetgate.exe", "emetgate.old.exe" },
        .data_present = true,
        .data_bytes = 5 * 1024 * 1024 * 1024 + 300 * 1024 * 1024,
        .others = &.{},
        .keep_cache = false,
    };
}

test "uninstall parse takes --yes and --keep-cache once each and nothing else" {
    try testing.expectEqual(Options{}, parse(&.{}).?);
    try testing.expectEqual(Options{ .yes = true, .keep_cache = true }, parse(&.{ "--keep-cache", "--yes" }).?);
    try testing.expect(parse(&.{ "--yes", "--yes" }) == null);
    try testing.expect(parse(&.{"--force"}) == null);
    try testing.expect(parse(&.{"-y"}) == null);
}

test "uninstall removes only the emetgate PATH entry, in raw or %VAR% form, and keeps the rest byte for byte" {
    var env = try testEnv(testing.allocator);
    defer env.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = "C:\\Users\\u\\AppData\\Local\\Programs\\emetgate";

    const raw = "%USERPROFILE%\\bin;C:\\Users\\u\\AppData\\Local\\Programs\\emetgate;;C:\\Tools\\emetgate-old;%LocalAppData%\\programs\\EMETGATE\\";
    const edit = try withoutDir(arena, raw, dir, &env);
    try testing.expectEqualStrings("%USERPROFILE%\\bin;;C:\\Tools\\emetgate-old", edit.value);
    try testing.expectEqual(@as(usize, 2), edit.removed.len);
    try testing.expectEqualStrings("%LocalAppData%\\programs\\EMETGATE\\", edit.removed[1]);

    const untouched = "C:\\a;C:\\Users\\u\\AppData\\Local\\Programs\\emetgate2";
    const none = try withoutDir(arena, untouched, dir, &env);
    try testing.expectEqualStrings(untouched, none.value);
    try testing.expectEqual(@as(usize, 0), none.removed.len);

    const only = try withoutDir(arena, "C:/Users/u/AppData/Local/Programs/emetgate", dir, &env);
    try testing.expectEqualStrings("", only.value);
}

test "uninstall plan keeps the PATH value kind and splits emetgate files from foreign ones" {
    var env = try testEnv(testing.allocator);
    defer env.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var facts = testFacts(.{ .text = "C:\\x;%LOCALAPPDATA%\\Programs\\emetgate", .expand = true });
    facts.program_entries = &.{ "emetgate.exe", "notes.txt", "emetgate.new.exe" };
    const p = try plan(arena, facts, &env);
    try testing.expectEqualStrings("C:\\Users\\u\\AppData\\Local\\Programs\\emetgate", p.program_dir);
    try testing.expectEqualStrings("C:\\Users\\u\\AppData\\Local\\emetgate", p.data_dir);
    try testing.expect(p.self_in_program);
    try testing.expect(p.new_user_path.?.expand);
    try testing.expectEqualStrings("C:\\x", p.new_user_path.?.text);
    try testing.expectEqual(@as(usize, 2), p.program_files.len);
    try testing.expectEqual(@as(usize, 1), p.program_extras.len);
    try testing.expect(p.removesData());

    var plain = testFacts(.{ .text = "C:\\Users\\u\\AppData\\Local\\Programs\\emetgate", .expand = false });
    plain.keep_cache = true;
    const q = try plan(arena, plain, &env);
    try testing.expect(!q.new_user_path.?.expand);
    try testing.expect(!q.removesData());

    var absent = testFacts(null);
    absent.program_entries = null;
    absent.data_present = false;
    const r = try plan(arena, absent, &env);
    try testing.expect(r.nothingToDo());
    try testing.expect(r.new_user_path == null);
}

test "uninstall dry run names every target, the data size, the project folders and how to confirm" {
    var env = try testEnv(testing.allocator);
    defer env.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var facts = testFacts(.{ .text = "C:\\x;C:\\Users\\u\\AppData\\Local\\Programs\\emetgate", .expand = true });
    facts.others = &.{.{ .pid = 4242, .image = "C:\\Users\\u\\AppData\\Local\\Programs\\emetgate\\emetgate.exe" }};
    const p = try plan(arena, facts, &env);
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writePlan(&writer, p, false);
    const text = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "dry run") != null);
    try testing.expect(std.mem.indexOf(u8, text, "program  C:\\Users\\u\\AppData\\Local\\Programs\\emetgate (emetgate.exe, emetgate.old.exe, then the folder)") != null);
    try testing.expect(std.mem.indexOf(u8, text, "PATH     C:\\Users\\u\\AppData\\Local\\Programs\\emetgate from your user PATH") != null);
    try testing.expect(std.mem.indexOf(u8, text, "data     C:\\Users\\u\\AppData\\Local\\emetgate (5.3 GB") != null);
    try testing.expect(std.mem.indexOf(u8, text, ".emetgate folder") != null);
    try testing.expect(std.mem.indexOf(u8, text, "pid 4242") != null);
    try testing.expect(std.mem.indexOf(u8, text, "emetgate uninstall --yes") != null);
    try testing.expect(std.mem.indexOf(u8, text, "--keep-cache") != null);
}

test "uninstall size reads in KB, MB and GB" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeSize(&writer, 0);
    try writer.writeAll("|");
    try writeSize(&writer, 1500);
    try writer.writeAll("|");
    try writeSize(&writer, 3 * 1024 * 1024 / 2);
    try writer.writeAll("|");
    try writeSize(&writer, 5 * 1024 * 1024 * 1024);
    try testing.expectEqualStrings("0 KB|2 KB|1.5 MB|5.0 GB", writer.buffered());
}

test "uninstall cleanup waits for the exe, deletes only emetgate's files and removes the folder only when empty" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = "C:\\Users\\u\\AppData\\Local\\Programs\\emetgate";
    const line = try cleanupCommand(arena, "C:\\Windows\\System32\\cmd.exe", dir, dir ++ "\\emetgate.exe");
    try testing.expect(std.mem.startsWith(u8, line, "\"C:\\Windows\\System32\\cmd.exe\" /d /v:off /c \"(for /l %i in (1,1,30) do @(if exist \"" ++ dir ++ "\\emetgate.exe\""));
    try testing.expect(std.mem.indexOf(u8, line, "del /f /q \"" ++ dir ++ "\\emetgate.exe\" \"" ++ dir ++ "\\emetgate.old.exe\" \"" ++ dir ++ "\\emetgate.new.exe\" 2>nul") != null);
    try testing.expect(std.mem.endsWith(u8, line, "& rd \"" ++ dir ++ "\" 2>nul\""));
    try testing.expect(std.mem.indexOf(u8, line, "/s") == null);
    try testing.expect(std.mem.indexOf(u8, line, "taskkill") == null);
    try testing.expectError(error.UnsafePath, cleanupCommand(arena, "C:\\Windows\\System32\\cmd.exe", "C:\\100%\\emetgate", "C:\\100%\\emetgate\\emetgate.exe"));
    try testing.expectError(error.UnsafePath, cleanupCommand(arena, "C:\\Windows\\System32\\cmd.exe", "C:\\a\"b", "C:\\a\"b\\emetgate.exe"));
}

test "uninstall measures a tree without following links into other folders" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "a/b");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a/one.bin", .data = "x" ** 1000 });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a/b/two.bin", .data = "y" ** 24 });
    const root = try tmp.dir.realPathFileAlloc(testing.io, "a", testing.allocator);
    defer testing.allocator.free(root);
    try testing.expectEqual(@as(u64, 1024), measure(testing.io, root));
}
