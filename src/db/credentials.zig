const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const shadow = @import("../platform/shadow.zig");

const Allocator = std.mem.Allocator;
const windows = std.os.windows;

pub const dir_name = "credentials";
pub const extension = ".dpapi";
pub const entropy_prefix = "emetgate-db-credential:";
pub const max_secret_bytes = 64 * 1024;
pub const low_read_label = "S:(ML;;NRNWNX;;;ME)";

pub fn dir(gpa: Allocator) ![]u8 {
    const base = try config.globalDir(gpa);
    defer gpa.free(base);
    return std.fmt.allocPrint(gpa, "{s}\\{s}", .{ base, dir_name });
}

pub fn fileFor(gpa: Allocator, name: []const u8) ![]u8 {
    if (!config.validName(name)) return error.InvalidCredentialName;
    const base = try dir(gpa);
    defer gpa.free(base);
    return std.fmt.allocPrint(gpa, "{s}\\{s}{s}", .{ base, name, extension });
}

pub fn store(gpa: Allocator, io: std.Io, name: []const u8, secret: []const u8) !void {
    if (secret.len == 0 or secret.len > max_secret_bytes) return error.InvalidSecret;
    const sealed = try protect(gpa, name, secret);
    defer gpa.free(sealed);
    const path = try fileFor(gpa, name);
    defer gpa.free(path);
    try config.place(gpa, io, path, sealed);
    if (builtin.os.tag == .windows) labelNoLowRead(gpa, path) catch {};
}

pub fn load(gpa: Allocator, io: std.Io, name: []const u8) ![]u8 {
    const path = try fileFor(gpa, name);
    defer gpa.free(path);
    if (builtin.os.tag == .windows and try shadow.isReparsePoint(path)) return error.CredentialIsLink;
    const sealed = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_secret_bytes * 4)) catch |err| switch (err) {
        error.FileNotFound => return error.CredentialMissing,
        else => return err,
    };
    defer gpa.free(sealed);
    return unprotect(gpa, name, sealed);
}

pub fn remove(gpa: Allocator, io: std.Io, name: []const u8) !void {
    const path = try fileFor(gpa, name);
    defer gpa.free(path);
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

pub fn exists(gpa: Allocator, io: std.Io, name: []const u8) bool {
    const path = fileFor(gpa, name) catch return false;
    defer gpa.free(path);
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

pub fn wipe(gpa: Allocator, secret: []u8) void {
    std.crypto.secureZero(u8, secret);
    gpa.free(secret);
}

const Blob = extern struct {
    size: windows.DWORD,
    data: ?[*]u8,
};

extern "crypt32" fn CryptProtectData(in: *const Blob, description: ?[*:0]const u16, entropy: ?*const Blob, reserved: ?*anyopaque, prompt: ?*anyopaque, flags: windows.DWORD, out: *Blob) callconv(.winapi) windows.BOOL;
extern "crypt32" fn CryptUnprotectData(in: *const Blob, description: ?*?[*:0]u16, entropy: ?*const Blob, reserved: ?*anyopaque, prompt: ?*anyopaque, flags: windows.DWORD, out: *Blob) callconv(.winapi) windows.BOOL;
extern "kernel32" fn LocalFree(memory: ?*anyopaque) callconv(.winapi) ?*anyopaque;

const ui_forbidden: windows.DWORD = 0x1;
const label_information: windows.DWORD = 0x10;
const sddl_revision: windows.DWORD = 1;

fn entropyFor(buf: []u8, name: []const u8) []u8 {
    const text = std.fmt.bufPrint(buf, "{s}{s}", .{ entropy_prefix, name }) catch buf[0..0];
    return text;
}

pub fn protect(gpa: Allocator, name: []const u8, secret: []const u8) ![]u8 {
    if (builtin.os.tag != .windows) return error.CredentialStoreUnsupported;
    var entropy_buf: [128]u8 = undefined;
    const entropy = entropyFor(&entropy_buf, name);
    const in: Blob = .{ .size = @intCast(secret.len), .data = @constCast(secret.ptr) };
    const extra: Blob = .{ .size = @intCast(entropy.len), .data = entropy.ptr };
    var out: Blob = .{ .size = 0, .data = null };
    if (CryptProtectData(&in, null, &extra, null, null, ui_forbidden, &out) == .FALSE) return error.CredentialProtectFailed;
    defer _ = LocalFree(out.data);
    const bytes = out.data orelse return error.CredentialProtectFailed;
    return gpa.dupe(u8, bytes[0..out.size]);
}

pub fn unprotect(gpa: Allocator, name: []const u8, sealed: []const u8) ![]u8 {
    if (builtin.os.tag != .windows) return error.CredentialStoreUnsupported;
    var entropy_buf: [128]u8 = undefined;
    const entropy = entropyFor(&entropy_buf, name);
    const in: Blob = .{ .size = @intCast(sealed.len), .data = @constCast(sealed.ptr) };
    const extra: Blob = .{ .size = @intCast(entropy.len), .data = entropy.ptr };
    var out: Blob = .{ .size = 0, .data = null };
    if (CryptUnprotectData(&in, null, &extra, null, null, ui_forbidden, &out) == .FALSE) return error.CredentialUnreadable;
    const bytes = out.data orelse return error.CredentialUnreadable;
    defer {
        std.crypto.secureZero(u8, bytes[0..out.size]);
        _ = LocalFree(out.data);
    }
    return gpa.dupe(u8, bytes[0..out.size]);
}

pub fn labelNoLowRead(gpa: Allocator, path: []const u8) !void {
    _ = gpa;
    if (builtin.os.tag != .windows) return;
    try shadow.labelWith(path, std.unicode.utf8ToUtf16LeStringLiteral(low_read_label));
}

extern "advapi32" fn GetFileSecurityW(name: [*:0]const u16, info: windows.DWORD, descriptor: ?*anyopaque, length: windows.DWORD, needed: *windows.DWORD) callconv(.winapi) windows.BOOL;
extern "advapi32" fn ConvertSecurityDescriptorToStringSecurityDescriptorW(descriptor: *anyopaque, revision: windows.DWORD, info: windows.DWORD, text: *?[*:0]u16, size: ?*windows.ULONG) callconv(.winapi) windows.BOOL;

pub fn blocksLowRead(gpa: Allocator, path: []const u8) bool {
    if (builtin.os.tag != .windows) return false;
    const wide = std.unicode.wtf8ToWtf16LeAllocZ(gpa, path) catch return false;
    defer gpa.free(wide);
    var needed: windows.DWORD = 0;
    _ = GetFileSecurityW(wide.ptr, label_information, null, 0, &needed);
    if (needed == 0) return false;
    const buf = gpa.alignedAlloc(u8, .of(usize), needed) catch return false;
    defer gpa.free(buf);
    if (GetFileSecurityW(wide.ptr, label_information, buf.ptr, needed, &needed) == .FALSE) return false;
    var text: ?[*:0]u16 = null;
    if (ConvertSecurityDescriptorToStringSecurityDescriptorW(buf.ptr, sddl_revision, label_information, &text, null) == .FALSE) return false;
    defer _ = LocalFree(text);
    const sddl = std.unicode.wtf16LeToWtf8Alloc(gpa, std.mem.span(text.?)) catch return false;
    defer gpa.free(sddl);
    return std.mem.indexOf(u8, sddl, "NR") != null and (std.mem.indexOf(u8, sddl, ";;;ME)") != null or std.mem.indexOf(u8, sddl, ";;;HI)") != null);
}

pub fn redact(gpa: Allocator, url: []const u8) ![]u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return gpa.dupe(u8, url);
    const authority_start = scheme_end + 3;
    const rest = url[authority_start..];
    const authority_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..authority_end];
    const at = std.mem.lastIndexOfScalar(u8, authority, '@') orelse return stripQuery(gpa, url);
    const userinfo = authority[0..at];
    const user = if (std.mem.indexOfScalar(u8, userinfo, ':')) |colon| userinfo[0..colon] else userinfo;
    const kept = try std.fmt.allocPrint(gpa, "{s}{s}@{s}{s}", .{ url[0..authority_start], user, authority[at + 1 ..], rest[authority_end..] });
    defer gpa.free(kept);
    return stripQuery(gpa, kept);
}

fn stripQuery(gpa: Allocator, url: []const u8) ![]u8 {
    const q = std.mem.indexOfScalar(u8, url, '?') orelse return gpa.dupe(u8, url);
    return gpa.dupe(u8, url[0..q]);
}

const testing = std.testing;

test "db credentials: a secret sealed with DPAPI opens only under its own name" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const sealed = try protect(testing.allocator, "prod", "postgres://u:s3cret@h/db");
    defer testing.allocator.free(sealed);
    try testing.expect(std.mem.indexOf(u8, sealed, "s3cret") == null);
    const opened = try unprotect(testing.allocator, "prod", sealed);
    defer wipe(testing.allocator, opened);
    try testing.expectEqualStrings("postgres://u:s3cret@h/db", opened);
    try testing.expectError(error.CredentialUnreadable, unprotect(testing.allocator, "other", sealed));
}

test "db credentials: store, load and remove go through the data folder and never write the plain secret" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(base);
    config.global_dir_override = base;
    defer config.global_dir_override = null;
    try store(testing.allocator, testing.io, "prod", "mysql://root:hunter2@db/app");
    try testing.expect(exists(testing.allocator, testing.io, "prod"));
    const raw = try tmp.dir.readFileAlloc(testing.io, "credentials\\prod.dpapi", testing.allocator, .unlimited);
    defer testing.allocator.free(raw);
    try testing.expect(std.mem.indexOf(u8, raw, "hunter2") == null);
    const back = try load(testing.allocator, testing.io, "prod");
    defer wipe(testing.allocator, back);
    try testing.expectEqualStrings("mysql://root:hunter2@db/app", back);
    try remove(testing.allocator, testing.io, "prod");
    try testing.expectError(error.CredentialMissing, load(testing.allocator, testing.io, "prod"));
    try testing.expectError(error.InvalidCredentialName, store(testing.allocator, testing.io, "..\\x", "s"));
}

test "db credentials: a file labeled against low reads says so, a plain one does not" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.db", .data = "x" });
    const dir_abs = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir_abs);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}\\a.db", .{dir_abs});
    defer testing.allocator.free(path);
    try testing.expect(!blocksLowRead(testing.allocator, path));
    labelNoLowRead(testing.allocator, path) catch return error.SkipZigTest;
    try testing.expect(blocksLowRead(testing.allocator, path));
}

test "db credentials: redact drops the password and the query string and keeps user, host and path" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "postgres://app:pw@db.local:5432/app?sslmode=require&password=x", "postgres://app@db.local:5432/app" },
        .{ "mysql://root@localhost/app", "mysql://root@localhost/app" },
        .{ "postgresql://db.local/app", "postgresql://db.local/app" },
    };
    for (cases) |case| {
        const got = try redact(testing.allocator, case[0]);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(case[1], got);
    }
}
