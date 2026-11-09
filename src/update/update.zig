const std = @import("std");
const builtin = @import("builtin");
const bounded_run = @import("../platform/bounded_run.zig");
pub const winhttp = @import("winhttp.zig");

const Allocator = std.mem.Allocator;
const Ed25519 = std.crypto.sign.Ed25519;

pub const latest_url = "https://api.github.com/repos/emetgate/emetgate/releases/latest";
pub const download_base = "https://github.com/emetgate/emetgate/releases/download/";
pub const exe_asset = "emetgate.exe";
pub const sig_asset = "emetgate.exe.sig";
pub const old_name = "emetgate.old.exe";
pub const new_name = "emetgate.new.exe";
pub const stamp_path = "update\\last-check";
pub const no_update_variable = "EMETGATE_NO_UPDATE";
pub const ci_variable = "CI";
pub const check_interval_s: i64 = 24 * 60 * 60;
pub const check_deadline_ms: u32 = 2_000;
pub const download_deadline_ms: u32 = 60_000;
pub const version_deadline_ms: u64 = 10_000;
pub const max_release_bytes: usize = 1 << 20;
pub const max_exe_bytes: usize = 64 << 20;
pub const max_sig_bytes: usize = 1024;
pub const auto_in_build = builtin.mode != .Debug;

pub const release_key: ?[32]u8 = parseKey(@embedFile("release_key.pub"));

pub fn parseKey(text: []const u8) ?[32]u8 {
    var key: [32]u8 = undefined;
    decodeExact(&key, text) catch return null;
    return key;
}

fn decodeExact(dest: []u8, text: []const u8) !void {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const decoder = std.base64.standard.Decoder;
    if (try decoder.calcSizeForSlice(trimmed) != dest.len) return error.WrongLength;
    try decoder.decode(dest, trimmed);
}

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,

    pub fn parse(text: []const u8) ?Version {
        const bare = if (text.len > 0 and text[0] == 'v') text[1..] else text;
        var parts = std.mem.splitScalar(u8, bare, '.');
        var numbers: [3]u32 = undefined;
        for (&numbers) |*number| number.* = parseNumber(parts.next() orelse return null) orelse return null;
        if (parts.next() != null) return null;
        return .{ .major = numbers[0], .minor = numbers[1], .patch = numbers[2] };
    }

    fn parseNumber(part: []const u8) ?u32 {
        if (part.len == 0 or part.len > 9) return null;
        if (part.len > 1 and part[0] == '0') return null;
        for (part) |c| if (!std.ascii.isDigit(c)) return null;
        return std.fmt.parseInt(u32, part, 10) catch null;
    }

    pub fn order(a: Version, b: Version) std.math.Order {
        if (a.major != b.major) return std.math.order(a.major, b.major);
        if (a.minor != b.minor) return std.math.order(a.minor, b.minor);
        return std.math.order(a.patch, b.patch);
    }

    pub fn format(self: Version, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
    }
};

pub const Latest = union(enum) {
    release: Version,
    prerelease,
    unrecognized,
};

pub fn parseLatest(gpa: Allocator, body: []const u8) Latest {
    const Payload = struct { tag_name: []const u8 = "", prerelease: bool = false, draft: bool = false };
    const parsed = std.json.parseFromSlice(Payload, gpa, body, .{ .ignore_unknown_fields = true }) catch return .unrecognized;
    defer parsed.deinit();
    const tag = parsed.value.tag_name;
    if (parsed.value.draft or parsed.value.prerelease or std.mem.indexOfAny(u8, tag, "-+") != null) return .prerelease;
    return .{ .release = Version.parse(tag) orelse return .unrecognized };
}

pub fn verify(key: [32]u8, exe: []const u8, signature_text: []const u8) !void {
    var bytes: [Ed25519.Signature.encoded_length]u8 = undefined;
    try decodeExact(&bytes, signature_text);
    const public_key = try Ed25519.PublicKey.fromBytes(key);
    try Ed25519.Signature.fromBytes(bytes).verify(exe, public_key);
}

pub fn due(last: ?i64, now: i64) bool {
    const seen = last orelse return true;
    if (seen > now) return true;
    return now - seen >= check_interval_s;
}

pub fn autoDisabled(env: *const std.process.Environ.Map, build_allows: bool) bool {
    if (!build_allows) return true;
    if (env.get(ci_variable) != null) return true;
    const value = env.get(no_update_variable) orelse return false;
    return value.len != 0 and !std.mem.eql(u8, value, "0");
}

pub const Fetch = struct {
    context: ?*anyopaque,
    getFn: *const fn (context: ?*anyopaque, gpa: Allocator, url: []const u8, limit: usize, deadline_ms: u32) anyerror![]u8,

    pub fn get(self: Fetch, gpa: Allocator, url: []const u8, limit: usize, deadline_ms: u32) anyerror![]u8 {
        return self.getFn(self.context, gpa, url, limit, deadline_ms);
    }
};

pub const network: Fetch = .{ .context = null, .getFn = networkGet };

fn networkGet(_: ?*anyopaque, gpa: Allocator, url: []const u8, limit: usize, deadline_ms: u32) anyerror![]u8 {
    return winhttp.get(gpa, url, limit, deadline_ms);
}

pub const System = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (context: *anyopaque, gpa: Allocator, path: []const u8, limit: usize) anyerror![]u8,
        write: *const fn (context: *anyopaque, path: []const u8, data: []const u8) anyerror!void,
        rename: *const fn (context: *anyopaque, from: []const u8, to: []const u8) anyerror!void,
        delete: *const fn (context: *anyopaque, path: []const u8) anyerror!void,
        reportVersion: *const fn (context: *anyopaque, gpa: Allocator, exe: []const u8) anyerror![]u8,
    };

    pub fn read(self: System, gpa: Allocator, path: []const u8, limit: usize) anyerror![]u8 {
        return self.vtable.read(self.context, gpa, path, limit);
    }

    pub fn write(self: System, path: []const u8, data: []const u8) anyerror!void {
        return self.vtable.write(self.context, path, data);
    }

    pub fn rename(self: System, from: []const u8, to: []const u8) anyerror!void {
        return self.vtable.rename(self.context, from, to);
    }

    pub fn delete(self: System, path: []const u8) anyerror!void {
        return self.vtable.delete(self.context, path);
    }

    pub fn reportVersion(self: System, gpa: Allocator, exe: []const u8) anyerror![]u8 {
        return self.vtable.reportVersion(self.context, gpa, exe);
    }
};

pub const Disk = struct {
    io: std.Io,

    pub fn system(self: *Disk) System {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable: System.VTable = .{ .read = read, .write = write, .rename = rename, .delete = delete, .reportVersion = reportVersion };

    fn of(context: *anyopaque) *Disk {
        return @ptrCast(@alignCast(context));
    }

    fn read(context: *anyopaque, gpa: Allocator, path: []const u8, limit: usize) anyerror![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(of(context).io, path, gpa, .limited(limit));
    }

    fn write(context: *anyopaque, path: []const u8, data: []const u8) anyerror!void {
        const io = of(context).io;
        if (std.fs.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
    }

    fn rename(context: *anyopaque, from: []const u8, to: []const u8) anyerror!void {
        if (builtin.os.tag != .windows) {
            const cwd = std.Io.Dir.cwd();
            return std.Io.Dir.rename(cwd, from, cwd, to, of(context).io);
        }
        var from_wide: [std.fs.max_path_bytes:0]u16 = undefined;
        var to_wide: [std.fs.max_path_bytes:0]u16 = undefined;
        if (win.MoveFileExW(try wide(&from_wide, from), try wide(&to_wide, to), win.movefile_replace_existing | win.movefile_write_through) != .FALSE) return;
        return switch (std.os.windows.GetLastError()) {
            .FILE_NOT_FOUND, .PATH_NOT_FOUND => error.FileNotFound,
            .ACCESS_DENIED, .SHARING_VIOLATION => error.AccessDenied,
            else => error.RenameFailed,
        };
    }

    fn wide(buf: *[std.fs.max_path_bytes:0]u16, path: []const u8) ![*:0]const u16 {
        if (path.len >= buf.len) return error.NameTooLong;
        const len = try std.unicode.wtf8ToWtf16Le(buf, path);
        buf[len] = 0;
        return buf[0..len :0];
    }

    fn delete(context: *anyopaque, path: []const u8) anyerror!void {
        std.Io.Dir.cwd().deleteFile(of(context).io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    fn reportVersion(context: *anyopaque, gpa: Allocator, exe: []const u8) anyerror![]u8 {
        const result = try bounded_run.run(gpa, of(context).io, .{
            .argv = &.{ exe, "--version" },
            .timeout = bounded_run.timeoutMs(version_deadline_ms),
            .create_no_window = true,
        });
        gpa.free(result.stderr);
        errdefer gpa.free(result.stdout);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.VersionCommandFailed,
            else => return error.VersionCommandFailed,
        }
        return result.stdout;
    }
};

const win = struct {
    const windows = std.os.windows;
    const movefile_replace_existing: windows.DWORD = 0x1;
    const movefile_write_through: windows.DWORD = 0x8;

    extern "kernel32" fn MoveFileExW(from: [*:0]const u16, to: [*:0]const u16, flags: windows.DWORD) callconv(.winapi) windows.BOOL;
};

pub const Outcome = union(enum) {
    up_to_date: Version,
    updated: Version,
    prerelease,
    no_release,
    no_release_key,
    not_a_release_build,
    offline: anyerror,
    download_failed: anyerror,
    bad_signature: Version,
    wrong_version: Version,
    previous_still_running,
    apply_failed: anyerror,
    rollback_failed: anyerror,

    pub fn shownWhenAuto(self: Outcome) bool {
        return switch (self) {
            .updated, .bad_signature, .wrong_version, .previous_still_running, .apply_failed, .rollback_failed => true,
            else => false,
        };
    }

    pub fn exitCode(self: Outcome) u8 {
        return switch (self) {
            .up_to_date, .updated, .prerelease => 0,
            else => 1,
        };
    }

    pub fn write(self: Outcome, writer: *std.Io.Writer, current: []const u8, arrow: []const u8) std.Io.Writer.Error!void {
        switch (self) {
            .up_to_date => |latest| try writer.print("emetgate {s} is up to date (latest release {f})\n", .{ current, latest }),
            .updated => |latest| try writer.print("emetgate {s} {s} {f} updated\n", .{ current, arrow, latest }),
            .prerelease => try writer.writeAll("emetgate update: the latest release is a prerelease or a draft; skipped\n"),
            .no_release => try writer.writeAll("emetgate update: the latest release has no vX.Y.Z tag; skipped\n"),
            .no_release_key => try writer.writeAll("emetgate update: this build has no release key (src/update/release_key.pub), so it cannot verify a download; get the release by hand\n"),
            .not_a_release_build => try writer.print("emetgate update: this build's version {s} is not X.Y.Z, so there is nothing to compare\n", .{current}),
            .offline => |err| try writer.print("emetgate update: could not reach GitHub ({t})\n", .{err}),
            .download_failed => |err| try writer.print("emetgate update: could not download the release ({t}); kept {s}\n", .{ err, current }),
            .bad_signature => |latest| try writer.print("warning: emetgate {f} does not carry a valid signature from the release key; not installed, kept {s}\n", .{ latest, current }),
            .wrong_version => |latest| try writer.print("warning: the downloaded emetgate.exe does not report version {f}; not installed, kept {s}\n", .{ latest, current }),
            .previous_still_running => try writer.print("warning: emetgate update: " ++ old_name ++ " from the last update is still running; close it, then run emetgate update (kept {s})\n", .{current}),
            .apply_failed => |err| try writer.print("warning: emetgate update could not replace emetgate.exe ({t}); kept {s}\n", .{ err, current }),
            .rollback_failed => |err| try writer.print("warning: emetgate update could not replace emetgate.exe ({t}) nor put it back; rename " ++ old_name ++ " to emetgate.exe\n", .{err}),
        }
    }
};

pub fn writeDownloading(writer: *std.Io.Writer, current: []const u8, latest: Version, arrow: []const u8) std.Io.Writer.Error!void {
    try writer.print("emetgate {s} {s} {f}: downloading the signed release\n", .{ current, arrow, latest });
}

pub fn arrowFor(code_page: u32) []const u8 {
    return if (code_page == 0 or code_page == 65001) "\u{2192}" else "->";
}

pub const Updater = struct {
    gpa: Allocator,
    fetch: Fetch,
    system: System,
    exe_path: []const u8,
    current: []const u8,
    key: ?[32]u8,
    latest_url: []const u8 = latest_url,
    download_base: []const u8 = download_base,
    on_download: ?*const fn (latest: Version) void = null,

    pub fn run(self: Updater) Outcome {
        const current = Version.parse(self.current) orelse return .not_a_release_build;
        const key = self.key orelse return .no_release_key;
        const body = self.fetch.get(self.gpa, self.latest_url, max_release_bytes, check_deadline_ms) catch |err| return .{ .offline = err };
        const latest = parseLatest(self.gpa, body);
        self.gpa.free(body);
        const version = switch (latest) {
            .release => |found| found,
            .prerelease => return .prerelease,
            .unrecognized => return .no_release,
        };
        if (version.order(current) != .gt) return .{ .up_to_date = version };

        if (self.on_download) |announce| announce(version);
        const exe = self.download(version, exe_asset, max_exe_bytes) catch |err| return .{ .download_failed = err };
        defer self.gpa.free(exe);
        const signature = self.download(version, sig_asset, max_sig_bytes) catch |err| return .{ .download_failed = err };
        defer self.gpa.free(signature);
        verify(key, exe, signature) catch return .{ .bad_signature = version };
        return self.install(version, exe);
    }

    fn download(self: Updater, version: Version, asset: []const u8, limit: usize) ![]u8 {
        const url = try std.fmt.allocPrint(self.gpa, "{s}v{f}/{s}", .{ self.download_base, version, asset });
        defer self.gpa.free(url);
        return self.fetch.get(self.gpa, url, limit, download_deadline_ms);
    }

    fn install(self: Updater, version: Version, exe: []const u8) Outcome {
        const dir = std.fs.path.dirname(self.exe_path) orelse return .{ .apply_failed = error.ExeHasNoFolder };
        const old = std.fs.path.join(self.gpa, &.{ dir, old_name }) catch |err| return .{ .apply_failed = err };
        defer self.gpa.free(old);
        const new = std.fs.path.join(self.gpa, &.{ dir, new_name }) catch |err| return .{ .apply_failed = err };
        defer self.gpa.free(new);
        self.system.delete(old) catch return .previous_still_running;
        self.system.write(new, exe) catch |err| {
            self.system.delete(new) catch {};
            return .{ .apply_failed = err };
        };
        if (!self.reports(new, version)) {
            self.system.delete(new) catch {};
            return .{ .wrong_version = version };
        }
        swap(self.system, self.exe_path, old, new) catch |err| switch (err) {
            error.RollbackFailed => return .{ .rollback_failed = err },
            else => return .{ .apply_failed = err },
        };
        return .{ .updated = version };
    }

    fn reports(self: Updater, exe: []const u8, version: Version) bool {
        const output = self.system.reportVersion(self.gpa, exe) catch return false;
        defer self.gpa.free(output);
        const line = std.mem.trim(u8, output, " \t\r\n");
        const prefix = "emetgate ";
        if (!std.mem.startsWith(u8, line, prefix)) return false;
        const reported = Version.parse(line[prefix.len..]) orelse return false;
        return reported.order(version) == .eq;
    }
};

pub fn swap(system: System, exe: []const u8, old: []const u8, new: []const u8) anyerror!void {
    system.rename(exe, old) catch |err| {
        system.delete(new) catch {};
        return err;
    };
    system.rename(new, exe) catch |err| {
        system.rename(old, exe) catch {
            system.delete(new) catch {};
            return error.RollbackFailed;
        };
        system.delete(new) catch {};
        return err;
    };
}

pub fn removeLeftover(gpa: Allocator, system: System, exe_path: []const u8) void {
    const dir = std.fs.path.dirname(exe_path) orelse return;
    const old = std.fs.path.join(gpa, &.{ dir, old_name }) catch return;
    defer gpa.free(old);
    system.delete(old) catch {};
}

pub fn autoCheck(updater: Updater, env: *const std.process.Environ.Map, build_allows: bool, data_dir: []const u8, now: i64) ?Outcome {
    if (autoDisabled(env, build_allows)) return null;
    const stamp = std.fs.path.join(updater.gpa, &.{ data_dir, stamp_path }) catch return null;
    defer updater.gpa.free(stamp);
    if (!due(readStamp(updater.gpa, updater.system, stamp), now)) return null;
    var buf: [24]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{now}) catch return null;
    updater.system.write(stamp, text) catch return null;
    return updater.run();
}

fn readStamp(gpa: Allocator, system: System, path: []const u8) ?i64 {
    const text = system.read(gpa, path, 64) catch return null;
    defer gpa.free(text);
    return std.fmt.parseInt(i64, std.mem.trim(u8, text, " \t\r\n"), 10) catch null;
}
