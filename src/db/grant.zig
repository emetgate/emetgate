const std = @import("std");
const builtin = @import("builtin");
const json_input = @import("../protocol/json_input.zig");
const context_epoch = @import("../protocol/context_epoch.zig");
const lockdown_slash = @import("../platform/lockdown_slash.zig");
const open_nowait = @import("../platform/open_nowait.zig");
const shadow = @import("../platform/shadow.zig");
const config = @import("config.zig");

const Allocator = std.mem.Allocator;
const Map = std.process.Environ.Map;

pub const extension = ".dbgrant";
pub const armed_ttl_s: i64 = 15 * 60;
pub const active_ttl_s: i64 = 60 * 60;
pub const max_grant_bytes = 1024;

pub const State = enum { armed, active };

pub const Grant = struct {
    state: State,
    db: ?[]const u8 = null,
    destructive: bool = false,
    at: i64,

    pub fn covers(self: Grant, name: []const u8) bool {
        const only = self.db orelse return true;
        return std.ascii.eqlIgnoreCase(only, name);
    }
};

pub fn path(gpa: Allocator, env: *const Map) Allocator.Error!?[]u8 {
    const epoch = (try context_epoch.path(gpa, env)) orelse return null;
    defer gpa.free(epoch);
    const stem = if (std.mem.endsWith(u8, epoch, lockdown_slash.context_extension)) epoch[0 .. epoch.len - lockdown_slash.context_extension.len] else epoch;
    return try std.fmt.allocPrint(gpa, "{s}{s}", .{ stem, extension });
}

pub fn nowSeconds(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

fn parse(arena: Allocator, bytes: []const u8) ?Grant {
    const value = json_input.parseLeaky(std.json.Value, arena, bytes, .{}) catch return null;
    if (value != .object) return null;
    const state_value = value.object.get("state") orelse return null;
    if (state_value != .string) return null;
    const state = std.meta.stringToEnum(State, state_value.string) orelse return null;
    const at_value = value.object.get("at") orelse return null;
    if (at_value != .integer) return null;
    var grant: Grant = .{ .state = state, .at = at_value.integer };
    if (value.object.get("db")) |db| {
        if (db == .string) {
            if (!config.validName(db.string)) return null;
            grant.db = db.string;
        } else if (db != .null) return null;
    }
    if (value.object.get("destructive")) |flag| {
        if (flag != .bool) return null;
        grant.destructive = flag.bool;
    }
    return grant;
}

fn render(gpa: Allocator, grant: Grant) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer };
    try js.beginObject();
    try js.objectField("state");
    try js.write(@tagName(grant.state));
    try js.objectField("db");
    try js.write(grant.db);
    try js.objectField("destructive");
    try js.write(grant.destructive);
    try js.objectField("at");
    try js.write(grant.at);
    try js.endObject();
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

fn expired(grant: Grant, now: i64) bool {
    const ttl = if (grant.state == .armed) armed_ttl_s else active_ttl_s;
    return now < grant.at or now - grant.at > ttl;
}

fn readRaw(gpa: Allocator, file: []const u8) ?[]u8 {
    if (builtin.os.tag == .windows) {
        if (shadow.isReparsePoint(file) catch true) return null;
    }
    return open_nowait.readFileAlloc(gpa, file, max_grant_bytes) catch null;
}

pub fn current(arena: Allocator, file: []const u8, now: i64) ?Grant {
    const bytes = readRaw(arena, file) orelse return null;
    const grant = parse(arena, bytes) orelse return null;
    if (expired(grant, now)) return null;
    return grant;
}

pub fn active(arena: Allocator, file: []const u8, now: i64) ?Grant {
    const grant = current(arena, file, now) orelse return null;
    return if (grant.state == .active) grant else null;
}

pub fn arm(gpa: Allocator, io: std.Io, file: []const u8, db: ?[]const u8, destructive: bool, now: i64) !void {
    const bytes = try render(gpa, .{ .state = .armed, .db = db, .destructive = destructive, .at = now });
    defer gpa.free(bytes);
    try config.place(gpa, io, file, bytes);
}

pub fn revoke(io: std.Io, file: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, file) catch {};
}

pub fn advance(gpa: Allocator, io: std.Io, file: []const u8, now: i64) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bytes = readRaw(arena, file) orelse return;
    const grant = parse(arena, bytes) orelse return revoke(io, file);
    if (grant.state == .active or expired(grant, now)) return revoke(io, file);
    var next = grant;
    next.state = .active;
    next.at = now;
    const text = try render(gpa, next);
    defer gpa.free(text);
    try config.place(gpa, io, file, text);
}

const testing = std.testing;

test "db grant: armed by the user, active for exactly the next prompt, then gone" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const file = try std.fmt.allocPrint(testing.allocator, "{s}\\launch{s}", .{ dir, extension });
    defer testing.allocator.free(file);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expect(current(arena, file, 1000) == null);
    try arm(testing.allocator, testing.io, file, "main", false, 1000);
    try testing.expect(active(arena, file, 1001) == null);
    try testing.expectEqual(State.armed, current(arena, file, 1001).?.state);
    try advance(testing.allocator, testing.io, file, 1010);
    const on = active(arena, file, 1011).?;
    try testing.expect(on.covers("MAIN") and !on.covers("other") and !on.destructive);
    try advance(testing.allocator, testing.io, file, 1020);
    try testing.expect(current(arena, file, 1021) == null);
    try arm(testing.allocator, testing.io, file, null, true, 2000);
    try testing.expect(current(arena, file, 2000 + armed_ttl_s + 1) == null);
    try advance(testing.allocator, testing.io, file, 2000 + armed_ttl_s + 1);
    try testing.expect(current(arena, file, 2000) == null);
    try arm(testing.allocator, testing.io, file, null, true, 3000);
    try advance(testing.allocator, testing.io, file, 3001);
    try testing.expect(active(arena, file, 3001 + active_ttl_s + 1) == null);
    try testing.expect(active(arena, file, 3002).?.covers("any"));
    revoke(testing.io, file);
    try testing.expect(current(arena, file, 3003) == null);
}

test "db grant: a damaged grant file grants nothing and the next prompt removes it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const file = try std.fmt.allocPrint(testing.allocator, "{s}\\g{s}", .{ dir, extension });
    defer testing.allocator.free(file);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    for ([_][]const u8{ "{\"state\":\"active\"}", "{\"state\":\"active\",\"at\":5,\"db\":\"..\\\\x\"}", "garbage", "{\"state\":\"open\",\"at\":5}" }) |bytes| {
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "g" ++ extension, .data = bytes });
        try testing.expect(current(arena_state.allocator(), file, 6) == null);
        try advance(testing.allocator, testing.io, file, 6);
        try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "g" ++ extension, .{}));
    }
}

test "db grant: the grant file sits next to the launch's context file, outside the repository" {
    var env: Map = .init(testing.allocator);
    defer env.deinit();
    try env.put(lockdown_slash.context_variable, "C:\\Users\\u\\AppData\\Local\\emetgate\\lockdown\\k\\context\\abc.epoch");
    const got = (try path(testing.allocator, &env)).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("C:\\Users\\u\\AppData\\Local\\emetgate\\lockdown\\k\\context\\abc" ++ extension, got);
    var bare: Map = .init(testing.allocator);
    defer bare.deinit();
    try testing.expect((try path(testing.allocator, &bare)) == null);
}
