const std = @import("std");
const builtin = @import("builtin");
const shadow = @import("shadow.zig");
const sandbox = @import("sandbox.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

pub const key_len = 32;
pub const marker_name = "root.txt";
const max_marker_bytes = 64 * 1024;

pub const Location = struct {
    base: []u8,
    workspace: []u8,
    shadow: []u8,

    pub fn deinit(self: Location, gpa: Allocator) void {
        gpa.free(self.shadow);
        gpa.free(self.workspace);
        gpa.free(self.base);
    }

    pub fn dotted(self: Location) bool {
        return hasDotSegment(self.shadow);
    }
};

pub fn locate(gpa: Allocator, root_abs: []const u8, override: ?[]const u8) !Location {
    const base = if (override) |dir| try validBase(gpa, dir) else try defaultBase(gpa);
    errdefer gpa.free(base);
    const key = repoKey(root_abs);
    const workspace = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ base, &key });
    errdefer gpa.free(workspace);
    const shadow_abs = try std.fmt.allocPrint(gpa, "{s}\\shadow", .{workspace});
    return .{ .base = base, .workspace = workspace, .shadow = shadow_abs };
}

pub fn displayRoot(gpa: Allocator, override: ?[]const u8) ![]u8 {
    return if (override) |dir| validBase(gpa, dir) else defaultBase(gpa);
}

pub fn defaultBase(gpa: Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const local = (try sandbox.environmentValue(arena_state.allocator(), std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA"))) orelse return error.ShadowRootUnavailable;
    const joined = try std.fmt.allocPrint(gpa, "{s}\\emetgate\\shadow", .{local});
    errdefer gpa.free(joined);
    const checked = try validBase(gpa, joined);
    gpa.free(joined);
    return checked;
}

pub fn validBase(gpa: Allocator, dir: []const u8) ![]u8 {
    var trimmed = dir;
    while (trimmed.len > 3 and (trimmed[trimmed.len - 1] == '\\' or trimmed[trimmed.len - 1] == '/')) trimmed = trimmed[0 .. trimmed.len - 1];
    if (trimmed.len < 4 or !std.ascii.isAlphabetic(trimmed[0]) or trimmed[1] != ':' or (trimmed[2] != '\\' and trimmed[2] != '/')) return error.InvalidShadowRoot;
    shadow.validateRelative(trimmed[3..]) catch return error.InvalidShadowRoot;
    const owned = try gpa.dupe(u8, trimmed);
    std.mem.replaceScalar(u8, owned, '/', '\\');
    return owned;
}

pub fn repoKey(root_abs: []const u8) [key_len]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    var end = root_abs.len;
    while (end > 3 and (root_abs[end - 1] == '\\' or root_abs[end - 1] == '/')) end -= 1;
    for (root_abs[0..end]) |byte| {
        const folded: u8 = if (byte == '/') '\\' else std.ascii.toLower(byte);
        hasher.update(&.{folded});
    }
    var digest: [key_len / 2]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn isKey(name: []const u8) bool {
    if (name.len != key_len) return false;
    for (name) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

pub fn hasDotSegment(path: []const u8) bool {
    var segments = std.mem.tokenizeAny(u8, path, "\\/");
    while (segments.next()) |segment| {
        if (segment.len > 1 and segment[0] == '.') return true;
    }
    return false;
}

pub fn writeMarker(io: std.Io, location: Location, root_abs: []const u8) !void {
    var dir = try Dir.openDirAbsolute(io, location.workspace, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = marker_name, .data = root_abs });
}

pub fn sweep(gpa: Allocator, io: std.Io, base_abs: []const u8, keep_abs: []const u8) !usize {
    var base = Dir.openDirAbsolute(io, base_abs, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => |e| return e,
    };
    defer base.close(io);
    var removed: usize = 0;
    var it = base.iterate();
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| gpa.free(name);
        names.deinit(gpa);
    }
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory or !isKey(entry.name)) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    for (names.items) |name| {
        const workspace = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ base_abs, name });
        defer gpa.free(workspace);
        if (std.ascii.eqlIgnoreCase(workspace, keep_abs)) continue;
        if (!try isStale(gpa, io, workspace)) continue;
        const shadow_abs = try std.fmt.allocPrint(gpa, "{s}\\shadow", .{workspace});
        defer gpa.free(shadow_abs);
        shadow.remove(io, base_abs, shadow_abs) catch continue;
        removed += 1;
    }
    return removed;
}

fn isStale(gpa: Allocator, io: std.Io, workspace: []const u8) !bool {
    if (try shadow.isReparsePoint(workspace)) return false;
    var dir = Dir.openDirAbsolute(io, workspace, .{}) catch return false;
    defer dir.close(io);
    const recorded = dir.readFileAlloc(io, marker_name, gpa, .limited(max_marker_bytes)) catch return false;
    defer gpa.free(recorded);
    if (!std.fs.path.isAbsolute(recorded)) return false;
    Dir.accessAbsolute(io, recorded, .{}) catch |err| return err == error.FileNotFound;
    return false;
}

const testing = std.testing;

test "the shadow key folds case and separators, and two repositories never share one" {
    const a = repoKey("C:\\work\\project");
    try testing.expectEqualStrings(&a, &repoKey("c:/WORK/Project/"));
    try testing.expect(!std.mem.eql(u8, &a, &repoKey("C:\\work\\project2")));
    try testing.expect(!std.mem.eql(u8, &a, &repoKey("C:\\work\\projec")));
    try testing.expect(isKey(&a));
    try testing.expect(!isKey("shadow"));
}

test "an operator shadow root must be an absolute drive path with safe segments" {
    const good = try validBase(testing.allocator, "D:/shadows/emetgate/");
    defer testing.allocator.free(good);
    try testing.expectEqualStrings("D:\\shadows\\emetgate", good);
    for ([_][]const u8{ "", "shadows", "\\\\server\\share\\x", "\\rooted", "C:", "C:\\", "C:\\a\\..\\b", "C:\\a\\b:stream", "C:\\CON\\x", "C:\\a~1" }) |bad| {
        errdefer std.debug.print("accepted shadow root: {s}\n", .{bad});
        try testing.expectError(error.InvalidShadowRoot, validBase(testing.allocator, bad));
    }
}

test "a shadow path with a segment starting with a dot is flagged" {
    try testing.expect(hasDotSegment("C:\\Users\\.me\\AppData\\emetgate"));
    try testing.expect(!hasDotSegment("C:\\Users\\first.last\\AppData\\Local\\emetgate\\shadow"));
    try testing.expect(hasDotSegment("C:\\work\\project\\.emetgate\\shadow"));
}

test "sweep removes only stale shadows whose repository is gone, and never follows a junction" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const top = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(top);
    try tmp.dir.createDirPath(testing.io, "live");
    try tmp.dir.createDirPath(testing.io, "victim");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "victim/keep.txt", .data = "keep\n" });
    const base = try std.fmt.allocPrint(testing.allocator, "{s}\\base", .{top});
    defer testing.allocator.free(base);
    const live = try std.fmt.allocPrint(testing.allocator, "{s}\\live", .{top});
    defer testing.allocator.free(live);
    const gone = try std.fmt.allocPrint(testing.allocator, "{s}\\gone", .{top});
    defer testing.allocator.free(gone);

    const cases = [_]struct { root: []const u8, key: [key_len]u8 }{
        .{ .root = live, .key = repoKey(live) },
        .{ .root = gone, .key = repoKey(gone) },
    };
    for (cases) |c| {
        const shadow_rel = try std.fmt.allocPrint(testing.allocator, "base/{s}/shadow", .{&c.key});
        defer testing.allocator.free(shadow_rel);
        try tmp.dir.createDirPath(testing.io, shadow_rel);
        const marker_rel = try std.fmt.allocPrint(testing.allocator, "base/{s}/{s}", .{ &c.key, marker_name });
        defer testing.allocator.free(marker_rel);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = marker_rel, .data = c.root });
    }
    try tmp.dir.createDirPath(testing.io, "base/notakey/shadow");
    const trap_key = repoKey("C:\\trap");
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    try shadow.createJunction(testing.io, try std.fmt.bufPrint(&link_buf, "{s}\\{s}", .{ base, &trap_key }), try std.fmt.bufPrint(&target_buf, "{s}\\victim", .{top}));

    try testing.expectEqual(@as(usize, 1), try sweep(testing.allocator, testing.io, base, ""));
    const gone_key = repoKey(gone);
    const live_key = repoKey(live);
    const gone_rel = try std.fmt.allocPrint(testing.allocator, "base/{s}", .{&gone_key});
    defer testing.allocator.free(gone_rel);
    const live_rel = try std.fmt.allocPrint(testing.allocator, "base/{s}/shadow", .{&live_key});
    defer testing.allocator.free(live_rel);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, gone_rel, .{}));
    try tmp.dir.access(testing.io, live_rel, .{});
    try tmp.dir.access(testing.io, "base/notakey/shadow", .{});
    try tmp.dir.access(testing.io, "victim/keep.txt", .{});
}
