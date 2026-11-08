const std = @import("std");
const builtin = @import("builtin");
const sandbox = @import("sandbox.zig");
const shadow = @import("shadow.zig");
const shadow_root = @import("shadow_root.zig");
const cache_lease = @import("cache_lease.zig");
const link_tree = @import("link_tree.zig");
const exe_path = @import("exe_path.zig");

const Allocator = std.mem.Allocator;

pub const temp_family = "run-tmp";
pub const cache_family = "cache";

pub const denied_note = "the command ran at low integrity and may have been refused a write outside the repository (access denied); if it must write there, call emetgate_run again with as_user:true and the user is asked before it runs with full rights";
pub const msys_note = "an MSYS program (Git Bash, sh, bash, sed, a git hook or another tool from Git's usr\\bin) cannot start at low integrity, so low runs use cmd.exe; use a native command, or call emetgate_run again with as_user:true and the user is asked before it runs in Git Bash with full rights";

pub const PrepareError = error{
    OutOfMemory,
    LowRootUnresolved,
    LowRootOnNetwork,
    LowRootLabelDenied,
    LowRootLabelFailed,
    LowDataDirUnavailable,
    LowTempUnavailable,
};

pub fn fix(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.LowRootUnresolved => "the command did not run: emetgate could not resolve the repository folder to its real path to label it for the low-integrity sandbox; check that it exists and this account can open it, or call again with as_user:true and the user is asked first",
        error.LowRootOnNetwork => "the command did not run: the repository is on a network drive, where a low-integrity process writes with the user's rights and the sandbox cannot keep writes inside it; move it to a local disk, or call again with as_user:true and the user is asked first",
        error.LowRootLabelDenied => "the command did not run: this account may not label the repository folder for the low-integrity sandbox (it is owned by another account, e.g. Administrators); take ownership of it, or call again with as_user:true and the user is asked first",
        error.LowRootLabelFailed => "the command did not run: Windows refused the low-integrity label on the repository folder (a file system without integrity labels, such as FAT or some synced folders); move it to an NTFS disk, or call again with as_user:true and the user is asked first",
        error.LowDataDirUnavailable => "the command did not run: emetgate could not find %LOCALAPPDATA% for the low-integrity TEMP and cache folders; set LOCALAPPDATA, or call again with as_user:true and the user is asked first",
        error.LowTempUnavailable => "the command did not run: emetgate could not create and label its TEMP or cache folder under %LOCALAPPDATA%\\emetgate; emetgate doctor says why, or call again with as_user:true and the user is asked first",
        else => null,
    };
}

pub const Confined = struct {
    root: []const u8,
    temp: []const u8,
    env: []const sandbox.EnvVar,
};

pub fn lowWritable(arena: Allocator, dir_abs: []const u8) !bool {
    const extended = if (std.mem.startsWith(u8, dir_abs, "\\\\")) dir_abs else try std.fmt.allocPrint(arena, "\\\\?\\{s}", .{dir_abs});
    const wide = try std.unicode.wtf8ToWtf16LeAllocZ(arena, extended);
    return !try link_tree.lowWriteBlocked(wide);
}

pub fn realRoot(arena: Allocator, root_abs: []const u8) PrepareError![]const u8 {
    const final = (try exe_path.finalDosPath(arena, root_abs)) orelse return error.LowRootUnresolved;
    if (std.mem.startsWith(u8, final, "\\\\")) return error.LowRootOnNetwork;
    if (builtin.os.tag == .windows) {
        const drive: [3:0]u16 = .{ final[0], ':', '\\' };
        if (GetDriveTypeW(&drive) == drive_remote) return error.LowRootOnNetwork;
    }
    return final;
}

pub fn labelRoot(arena: Allocator, root_abs: []const u8) PrepareError![]const u8 {
    const root = try realRoot(arena, root_abs);
    const writable = lowWritable(arena, root) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.LowRootLabelFailed;
    if (!writable) shadow.grantLowIntegrityWrite(root) catch |err| return if (err == error.LabelDenied) error.LowRootLabelDenied else error.LowRootLabelFailed;
    return root;
}

pub fn prepare(arena: Allocator, gpa: Allocator, io: std.Io, root_abs: []const u8, extra_env: []const sandbox.EnvVar) PrepareError!Confined {
    const root = try labelRoot(arena, root_abs);
    const data_owned = cache_lease.defaultDataDir(gpa) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.LowDataDirUnavailable;
    defer gpa.free(data_owned);
    const data = try arena.dupe(u8, data_owned);
    const key = shadow_root.repoKey(root);
    const temp = try std.fmt.allocPrint(arena, "{s}\\{s}\\{s}", .{ data, temp_family, &key });
    const cache = try std.fmt.allocPrint(arena, "{s}\\{s}", .{ data, cache_family });
    shadow.ensureCache(io, cache) catch return error.LowTempUnavailable;
    shadow.freshTemp(io, temp) catch return error.LowTempUnavailable;
    const cache_env = sandbox.cacheEnvironment(arena, cache) catch return error.OutOfMemory;
    const env = try std.mem.concat(arena, sandbox.EnvVar, &.{ extra_env, cache_env });
    return .{ .root = root, .temp = temp, .env = env };
}

const denial_markers = [_][]const u8{ "permission denied", "access is denied", "access denied", "eacces", "eperm", "unauthorizedaccess" };
const msys_markers = [_][]const u8{ "*** fatal error - ", "msys-2.0" };

fn mentions(report: sandbox.Report, markers: []const []const u8) bool {
    for (markers) |marker| {
        if (std.ascii.indexOfIgnoreCase(report.stdout, marker) != null) return true;
        if (std.ascii.indexOfIgnoreCase(report.stderr, marker) != null) return true;
    }
    return false;
}

pub fn note(report: sandbox.Report) ?[]const u8 {
    if (report.passed()) return null;
    if (mentions(report, &msys_markers)) return msys_note;
    if (mentions(report, &denial_markers)) return denied_note;
    var buffer: [1024]u8 = undefined;
    if (systemDenialText(&buffer)) |text| {
        if (std.mem.indexOf(u8, report.stdout, text) != null or std.mem.indexOf(u8, report.stderr, text) != null) return denied_note;
    }
    return null;
}

pub fn systemDenialText(buffer: *[1024]u8) ?[]const u8 {
    if (builtin.os.tag != .windows) return null;
    var wide: [256]u16 = undefined;
    const len = FormatMessageW(format_from_system | format_ignore_inserts, null, error_access_denied, 0, &wide, wide.len, null);
    if (len == 0) return null;
    const written = std.unicode.wtf16LeToWtf8(buffer, wide[0..@min(len, wide.len)]);
    const text = std.mem.trim(u8, buffer[0..written], " \t\r\n.");
    return if (text.len == 0) null else text;
}

const drive_remote: c_uint = 4;
const error_access_denied: u32 = 5;
const format_from_system: u32 = 0x1000;
const format_ignore_inserts: u32 = 0x200;
extern "kernel32" fn GetDriveTypeW(root: [*:0]const u16) callconv(.winapi) c_uint;
extern "kernel32" fn FormatMessageW(flags: u32, source: ?*const anyopaque, message_id: u32, language_id: u32, buffer: [*]u16, size: u32, arguments: ?*anyopaque) callconv(.winapi) u32;

fn noteFor(outcome: sandbox.Outcome, stderr: []const u8) ?[]const u8 {
    var err_buf: [512]u8 = undefined;
    @memcpy(err_buf[0..stderr.len], stderr);
    return note(.{ .outcome = outcome, .duration_ns = 0, .stdout = &.{}, .stderr = err_buf[0..stderr.len], .truncated = false, .killed_leftovers = false });
}

test "low run: a fatal start of the MSYS runtime is named as an MSYS program, other fatal errors are not" {
    const msys = "      1 [main] bash (5400) C:\\Program Files\\Git\\bin\\..\\usr\\bin\\bash.exe: *** fatal error - CreateFileMapping shared.5, Win32 error 5.  Terminating.\n";
    try std.testing.expectEqualStrings(msys_note, noteFor(.{ .crashed = 0xC0000142 }, msys).?);
    try std.testing.expectEqualStrings(msys_note, noteFor(.{ .exited = 1 }, msys).?);
    try std.testing.expectEqual(@as(?[]const u8, null), noteFor(.{ .exited = 0 }, msys));
    try std.testing.expectEqual(@as(?[]const u8, null), noteFor(.{ .exited = 1 }, "fatal error: missing.h: No such file or directory\n"));
}
