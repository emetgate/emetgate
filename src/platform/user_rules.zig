const std = @import("std");
const builtin = @import("builtin");
const memory = @import("memory.zig");
const own_dir = @import("own_dir.zig");
const shadow = @import("shadow.zig");
const cache_lease = @import("cache_lease.zig");
const sandbox = @import("sandbox.zig");

const Allocator = std.mem.Allocator;

pub const dir_name = "rules";

pub var dir_override: ?[]const u8 = null;

pub fn dirIn(gpa: Allocator, data_abs: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}\\{s}", .{ std.mem.trimEnd(u8, data_abs, "\\/"), dir_name });
}

pub fn dir(gpa: Allocator) ![]u8 {
    if (dir_override) |overridden| return gpa.dupe(u8, overridden);
    const data = if (builtin.is_test) try cache_lease.testDataDir(gpa) else try profileDataDir(gpa);
    defer gpa.free(data);
    return dirIn(gpa, data);
}

pub fn profileDataDir(gpa: Allocator) ![]u8 {
    const local = try profileLocalAppData(gpa);
    defer gpa.free(local);
    return std.fmt.allocPrint(gpa, "{s}\\{s}", .{ std.mem.trimEnd(u8, local, "\\/"), cache_lease.data_dir_name });
}

fn profileLocalAppData(gpa: Allocator) ![]u8 {
    if (builtin.os.tag != .windows) return error.LocalAppDataUnavailable;
    var path: ?[*:0]u16 = null;
    defer if (path) |owned| known_folder.CoTaskMemFree(@ptrCast(owned));
    if (known_folder.SHGetKnownFolderPath(&known_folder.local_app_data, known_folder.dont_verify, null, &path) != 0) return error.LocalAppDataUnavailable;
    const wide = path orelse return error.LocalAppDataUnavailable;
    return std.unicode.wtf16LeToWtf8Alloc(gpa, std.mem.span(wide));
}

const known_folder = struct {
    const windows = std.os.windows;
    const dont_verify: windows.DWORD = 0x00004000;
    const local_app_data: windows.GUID = .{ .Data1 = 0xF1B32785, .Data2 = 0x6FBA, .Data3 = 0x4FCF, .Data4 = .{ 0x9D, 0x55, 0x7B, 0x8E, 0x7F, 0x15, 0x70, 0x91 } };
    extern "shell32" fn SHGetKnownFolderPath(id: *const windows.GUID, flags: windows.DWORD, token: ?windows.HANDLE, path: *?[*:0]u16) callconv(.winapi) i32;
    extern "ole32" fn CoTaskMemFree(memory: ?*anyopaque) callconv(.winapi) void;
};

pub fn ledgerPath(gpa: Allocator, dir_abs: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}\\{s}", .{ dir_abs, memory.ledger_name });
}

fn hold(io: std.Io, dir_abs: []const u8, mode: own_dir.Mode) !?own_dir.Held {
    return own_dir.hold(io, dir_abs, mode) catch |err| renamed(err);
}

fn holdToRead(io: std.Io, dir_abs: []const u8) !?own_dir.Held {
    return own_dir.holdToRead(io, dir_abs) catch |err| renamed(err);
}

fn renamed(err: own_dir.Error) anyerror {
    return switch (err) {
        error.WorkspaceIsLink => error.UserRulesDirIsLink,
        error.WorkspaceBusy => error.MemoryBusy,
        error.WorkspaceOpenFailed => error.UserRulesDirUnavailable,
        else => err,
    };
}

fn refuseLinkedLedger(gpa: Allocator, dir_abs: []const u8) !void {
    const path = try ledgerPath(gpa, dir_abs);
    defer gpa.free(path);
    if (try shadow.isReparsePoint(path)) return error.UserRulesDirIsLink;
}

fn named(err: anyerror) anyerror {
    return switch (err) {
        error.LedgerCorrupt, error.LedgerNeedsRepair, error.LedgerMissingWithSidecars => error.UserLedgerCorrupt,
        else => err,
    };
}

pub fn peek(gpa: Allocator, io: std.Io) !memory.Recall {
    const at = try dir(gpa);
    defer gpa.free(at);
    return peekIn(gpa, io, at);
}

pub fn peekIn(gpa: Allocator, io: std.Io, dir_abs: []const u8) !memory.Recall {
    const held = (try holdToRead(io, dir_abs)) orelse return memory.emptyRecall(gpa);
    defer held.close();
    try refuseLinkedLedger(gpa, dir_abs);
    return memory.peekUser(gpa, io, dir_abs, false) catch |err| return named(err);
}

fn peekAllIn(gpa: Allocator, io: std.Io, dir_abs: []const u8) !memory.Recall {
    const held = (try holdToRead(io, dir_abs)) orelse return memory.emptyRecall(gpa);
    defer held.close();
    try refuseLinkedLedger(gpa, dir_abs);
    return memory.peekUser(gpa, io, dir_abs, true) catch |err| return named(err);
}

pub fn recall(gpa: Allocator, io: std.Io, all: bool) !memory.Recall {
    const at = try dir(gpa);
    defer gpa.free(at);
    return recallIn(gpa, io, at, all);
}

pub fn recallIn(gpa: Allocator, io: std.Io, dir_abs: []const u8, all: bool) !memory.Recall {
    const held = (hold(io, dir_abs, .existing) catch |err| {
        if (err == error.MemoryBusy or err == error.UserRulesDirUnavailable) return if (all) peekAllIn(gpa, io, dir_abs) else peekIn(gpa, io, dir_abs);
        return err;
    }) orelse return memory.emptyRecall(gpa);
    defer held.close();
    try refuseLinkedLedger(gpa, dir_abs);
    const place: memory.Place = .{ .user = dir_abs };
    const recalled = if (all) memory.recallAllAt(gpa, io, place) else memory.recallAt(gpa, io, place);
    return recalled catch |err| {
        if (err == error.MemoryBusy) return if (all) peekAllIn(gpa, io, dir_abs) else peekIn(gpa, io, dir_abs);
        return named(err);
    };
}

pub fn remember(gpa: Allocator, io: std.Io, text: []const u8, enforce: bool, check: ?[]const u8, where: ?[]const u8) ![]u8 {
    const at = try dir(gpa);
    defer gpa.free(at);
    const held = (try hold(io, at, .create)) orelse return error.UserRulesDirUnavailable;
    defer held.close();
    try refuseLinkedLedger(gpa, at);
    return memory.rememberAt(gpa, io, .{ .user = at }, .global, text, enforce, check, where) catch |err| return named(err);
}

pub fn supersede(gpa: Allocator, io: std.Io, id: []const u8, text: []const u8, enforce: bool, check: ?[]const u8, where: ?[]const u8) ![]u8 {
    const at = try dir(gpa);
    defer gpa.free(at);
    const held = (try hold(io, at, .existing)) orelse return error.DecisionNotActive;
    defer held.close();
    try refuseLinkedLedger(gpa, at);
    return memory.supersedeAt(gpa, io, .{ .user = at }, id, .global, text, enforce, check, where) catch |err| return named(err);
}

pub fn forget(gpa: Allocator, io: std.Io, id: []const u8) !void {
    const at = try dir(gpa);
    defer gpa.free(at);
    const held = (try hold(io, at, .existing)) orelse return error.DecisionNotActive;
    defer held.close();
    try refuseLinkedLedger(gpa, at);
    return memory.forgetAt(gpa, io, .{ .user = at }, id) catch |err| return named(err);
}

pub fn holds(gpa: Allocator, io: std.Io, id: []const u8) bool {
    if (!memory.isUserId(id)) return false;
    const recalled = peek(gpa, io) catch return false;
    defer recalled.deinit();
    for (recalled.decisions) |decision| {
        if (std.mem.eql(u8, decision.id, id)) return true;
    }
    return false;
}

pub fn countIn(gpa: Allocator, io: std.Io, dir_abs: []const u8) !?usize {
    const recalled = try peekIn(gpa, io, dir_abs);
    defer recalled.deinit();
    const path = try ledgerPath(gpa, dir_abs);
    defer gpa.free(path);
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return recalled.decisions.len;
}
