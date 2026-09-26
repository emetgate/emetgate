const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{ ProfileUnavailable, NameTooLong };
pub const AclError = error{ AclFailed, NameTooLong, InvalidWtf8 };

pub const name_capacity = 64;

var serial: std.atomic.Value(u64) = .init(0);

pub const SecurityCapabilities = extern struct {
    app_container_sid: ?*anyopaque,
    capabilities: ?*anyopaque,
    capability_count: u32,
    reserved: u32,
};

pub const proc_thread_attribute_security_capabilities: usize = 0x00020009;
pub const proc_thread_attribute_all_application_packages_policy: usize = 0x0002000F;
pub const all_application_packages_opt_out: u32 = 0x1;

pub const Profile = struct {
    sid: *anyopaque,
    lpac: bool,
    name: [name_capacity + 1]u16,
    name_len: usize,

    pub fn create(lpac: bool) Error!Profile {
        if (builtin.os.tag != .windows) return error.ProfileUnavailable;
        var profile: Profile = .{ .sid = undefined, .lpac = lpac, .name = undefined, .name_len = 0 };
        try profile.pickName();
        const name_z = profile.nameZ();

        const display = std.unicode.utf8ToUtf16LeStringLiteral("emetgate sandbox");
        const description = std.unicode.utf8ToUtf16LeStringLiteral("emetgate command sandbox");
        var sid: ?*anyopaque = null;
        const created = win.CreateAppContainerProfile(name_z, display, description, null, 0, &sid);
        if (created < 0) {
            if (@as(u32, @bitCast(created)) != win.hresult_already_exists) return error.ProfileUnavailable;
            if (win.DeriveAppContainerSidFromAppContainerName(name_z, &sid) < 0) return error.ProfileUnavailable;
        }
        profile.sid = sid orelse return error.ProfileUnavailable;
        return profile;
    }

    fn pickName(self: *Profile) Error!void {
        var buf: [name_capacity]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "emetgate-run-{d}-{x}-{d}", .{ win.GetCurrentProcessId(), win.GetTickCount64(), serial.fetchAdd(1, .monotonic) }) catch return error.NameTooLong;
        const len = std.unicode.wtf8ToWtf16Le(self.name[0..name_capacity], text) catch return error.NameTooLong;
        self.name[len] = 0;
        self.name_len = len;
    }

    fn nameZ(self: *const Profile) [*:0]const u16 {
        return @ptrCast(&self.name);
    }

    pub fn deinit(self: *Profile) void {
        if (builtin.os.tag != .windows) return;
        _ = win.DeleteAppContainerProfile(self.nameZ());
        _ = win.FreeSid(self.sid);
        self.* = undefined;
    }

    pub fn securityCapabilities(self: *const Profile) SecurityCapabilities {
        return .{ .app_container_sid = self.sid, .capabilities = null, .capability_count = 0, .reserved = 0 };
    }

    pub fn isAppContainer(process: std.os.windows.HANDLE) bool {
        var token: std.os.windows.HANDLE = undefined;
        if (win.OpenProcessToken(process, win.token_query, &token) == .FALSE) return false;
        defer std.os.windows.CloseHandle(token);
        var value: u32 = 0;
        var returned: std.os.windows.DWORD = 0;
        if (win.GetTokenInformation(token, win.token_is_app_container, &value, @sizeOf(u32), &returned) == .FALSE) return false;
        return value != 0;
    }

    pub fn allowRead(self: *const Profile, path_abs: []const u8) AclError!void {
        return self.grant(path_abs, win.generic_read | win.generic_execute, win.sub_containers_and_objects_inherit);
    }

    pub fn allowReadFile(self: *const Profile, path_abs: []const u8) AclError!void {
        return self.grant(path_abs, win.generic_read | win.generic_execute, 0);
    }

    pub fn allowWrite(self: *const Profile, path_abs: []const u8) AclError!void {
        return self.grant(path_abs, win.generic_read | win.generic_write | win.generic_execute, win.sub_containers_and_objects_inherit);
    }

    fn grant(self: *const Profile, path_abs: []const u8, mask: std.os.windows.DWORD, inherit: std.os.windows.DWORD) AclError!void {
        if (builtin.os.tag != .windows) return;
        var path_w: [std.fs.max_path_bytes:0]u16 = undefined;
        const wide = try toWide(&path_w, path_abs);

        var dacl: ?*anyopaque = null;
        var descriptor: ?*anyopaque = null;
        if (win.GetNamedSecurityInfoW(wide, win.se_file_object, win.dacl_security_information, null, null, &dacl, null, &descriptor) != 0) return error.AclFailed;
        defer _ = win.LocalFree(descriptor);

        var access: win.ExplicitAccess = std.mem.zeroes(win.ExplicitAccess);
        access.access_permissions = mask;
        access.access_mode = win.grant_access;
        access.inheritance = inherit;
        access.trustee.trustee_form = win.trustee_is_sid;
        access.trustee.trustee_type = win.trustee_is_unknown;
        access.trustee.name = self.sid;

        var merged: ?*anyopaque = null;
        if (win.SetEntriesInAclW(1, &access, dacl, &merged) != 0) return error.AclFailed;
        defer _ = win.LocalFree(merged);
        if (win.SetNamedSecurityInfoW(wide, win.se_file_object, win.dacl_security_information, null, null, merged, null) != 0) return error.AclFailed;
    }
};

fn toWide(buffer: *[std.fs.max_path_bytes:0]u16, path: []const u8) AclError![*:0]u16 {
    const len = std.unicode.wtf8ToWtf16Le(buffer[0..], path) catch return error.InvalidWtf8;
    if (len >= buffer.len) return error.NameTooLong;
    buffer[len] = 0;
    return @ptrCast(buffer);
}

const win = struct {
    const windows = std.os.windows;
    const hresult_already_exists: u32 = 0x800700B0;
    const token_query: windows.DWORD = 0x0008;
    const token_is_app_container: c_int = 29;
    const generic_read: windows.DWORD = 0x80000000;
    const generic_write: windows.DWORD = 0x40000000;
    const generic_execute: windows.DWORD = 0x20000000;
    const se_file_object: c_int = 1;
    const dacl_security_information: windows.DWORD = 0x00000004;
    const grant_access: c_int = 1;
    const trustee_is_sid: c_int = 0;
    const trustee_is_unknown: c_int = 0;
    const object_inherit_ace: windows.DWORD = 0x1;
    const container_inherit_ace: windows.DWORD = 0x2;
    const sub_containers_and_objects_inherit: windows.DWORD = object_inherit_ace | container_inherit_ace;

    const Trustee = extern struct {
        multiple_trustee: ?*anyopaque = null,
        multiple_trustee_operation: c_int = 0,
        trustee_form: c_int = 0,
        trustee_type: c_int = 0,
        name: ?*anyopaque = null,
    };

    const ExplicitAccess = extern struct {
        access_permissions: windows.DWORD,
        access_mode: c_int,
        inheritance: windows.DWORD,
        trustee: Trustee,
    };

    extern "userenv" fn CreateAppContainerProfile(name: [*:0]const u16, display: [*:0]const u16, description: [*:0]const u16, capabilities: ?*anyopaque, capability_count: windows.DWORD, sid: *?*anyopaque) callconv(.winapi) i32;
    extern "userenv" fn DeriveAppContainerSidFromAppContainerName(name: [*:0]const u16, sid: *?*anyopaque) callconv(.winapi) i32;
    extern "userenv" fn DeleteAppContainerProfile(name: [*:0]const u16) callconv(.winapi) i32;
    extern "advapi32" fn FreeSid(sid: *anyopaque) callconv(.winapi) ?*anyopaque;
    extern "advapi32" fn EqualSid(a: *anyopaque, b: *anyopaque) callconv(.winapi) windows.BOOL;
    extern "advapi32" fn OpenProcessToken(process: windows.HANDLE, access: windows.DWORD, token: *windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "advapi32" fn GetTokenInformation(token: windows.HANDLE, class: c_int, info: *anyopaque, length: windows.DWORD, returned: *windows.DWORD) callconv(.winapi) windows.BOOL;
    extern "advapi32" fn GetNamedSecurityInfoW(name: [*:0]const u16, object_type: c_int, info: windows.DWORD, owner: ?*?*anyopaque, group: ?*?*anyopaque, dacl: *?*anyopaque, sacl: ?*?*anyopaque, descriptor: *?*anyopaque) callconv(.winapi) windows.DWORD;
    extern "advapi32" fn SetNamedSecurityInfoW(name: [*:0]u16, object_type: c_int, info: windows.DWORD, owner: ?*anyopaque, group: ?*anyopaque, dacl: ?*anyopaque, sacl: ?*anyopaque) callconv(.winapi) windows.DWORD;
    extern "advapi32" fn SetEntriesInAclW(count: windows.ULONG, list: *ExplicitAccess, old: ?*anyopaque, new: *?*anyopaque) callconv(.winapi) windows.DWORD;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) windows.DWORD;
    extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
    extern "kernel32" fn LocalFree(memory: ?*anyopaque) callconv(.winapi) ?*anyopaque;
};

const testing = std.testing;

test "a profile derives the same sid it was created with, then deletes cleanly" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var profile = try Profile.create(false);
    defer profile.deinit();

    var derived: ?*anyopaque = null;
    try testing.expect(win.DeriveAppContainerSidFromAppContainerName(profile.nameZ(), &derived) >= 0);
    defer _ = win.FreeSid(derived.?);
    try testing.expect(win.EqualSid(profile.sid, derived.?) != .FALSE);
}

test "a fresh profile carries no capabilities and points its security struct at its own sid" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var profile = try Profile.create(true);
    defer profile.deinit();
    const caps = profile.securityCapabilities();
    try testing.expectEqual(@as(u32, 0), caps.capability_count);
    try testing.expectEqual(@as(?*anyopaque, null), caps.capabilities);
    try testing.expectEqual(profile.sid, caps.app_container_sid.?);
}
