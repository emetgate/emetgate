//! Path confinement: nothing outside the repository is read or returned.
//!
//! A junction, symbolic link or other reparse point inside the repository can
//! name a folder or file anywhere on the disk. git and the directory walkers
//! follow it, so a listing of the working tree can hold paths whose content
//! lives outside the repository. `within` answers the question for one path by
//! resolving it to its final location; `Confine` answers it cheaply for many
//! repository-relative paths by checking each directory prefix once and only
//! resolving the prefixes that are reparse points.
const std = @import("std");
const builtin = @import("builtin");
const exe_path = @import("exe_path.zig");

const Allocator = std.mem.Allocator;
const windows = std.os.windows;

/// True when `path_abs`, with every junction and link on the way resolved, is
/// the real root or lies under it. A path that cannot be resolved (missing,
/// dangling link) is not inside.
pub fn within(gpa: Allocator, root_abs: []const u8, path_abs: []const u8) !bool {
    if (builtin.os.tag != .windows) return true;
    const root_real = try exe_path.finalDosPath(gpa, root_abs) orelse return false;
    defer gpa.free(root_real);
    const final = try exe_path.finalDosPath(gpa, path_abs) orelse return false;
    defer gpa.free(final);
    return isUnder(root_real, final);
}

/// True when `path` equals `root` or names something below it. Both are
/// absolute Windows paths; the comparison ignores case and slash direction.
pub fn isUnder(root: []const u8, path: []const u8) bool {
    const r = std.mem.trimEnd(u8, root, "\\/");
    if (path.len < r.len) return false;
    for (r, path[0..r.len]) |a, b| {
        const sa = a == '/' or a == '\\';
        const sb = b == '/' or b == '\\';
        if (sa != sb) return false;
        if (!sa and std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return path.len == r.len or path[r.len] == '\\' or path[r.len] == '/';
}

/// Filters repository-relative paths (forward or back slashes) down to the
/// ones whose directories resolve inside the root. Each directory prefix is
/// checked once: a plain folder costs one attribute read, a reparse point one
/// open and final-path lookup. The file name itself is not checked here; a
/// reader that opens files checks a file link with `within`.
pub const Confine = struct {
    gpa: Allocator,
    root: []u8,
    root_real: ?[]u8,
    verdicts: std.StringHashMapUnmanaged(bool) = .empty,
    /// Directory prefixes found to lead outside the root, with a trailing
    /// slash, in the order met. Owned by the Confine.
    outside: std.ArrayList([]const u8) = .empty,

    pub fn init(gpa: Allocator, root_abs: []const u8) !Confine {
        const root = try gpa.dupe(u8, std.mem.trimEnd(u8, root_abs, "\\/"));
        errdefer gpa.free(root);
        const root_real = if (builtin.os.tag == .windows) try exe_path.finalDosPath(gpa, root) else null;
        return .{ .gpa = gpa, .root = root, .root_real = root_real };
    }

    pub fn deinit(self: *Confine) void {
        var it = self.verdicts.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.verdicts.deinit(self.gpa);
        for (self.outside.items) |p| self.gpa.free(p);
        self.outside.deinit(self.gpa);
        self.gpa.free(self.root);
        if (self.root_real) |r| self.gpa.free(r);
    }

    /// True when every directory on the way to `rel` stays inside the root.
    pub fn keeps(self: *Confine, rel: []const u8) !bool {
        if (builtin.os.tag != .windows) return true;
        var i: usize = 0;
        while (std.mem.indexOfAnyPos(u8, rel, i, "/\\")) |k| : (i = k + 1) {
            if (k == 0) continue;
            const dir = rel[0..k];
            if (self.verdicts.get(dir)) |inside| {
                if (!inside) return false;
                continue;
            }
            const inside = try self.dirInside(dir);
            const key = try self.gpa.dupe(u8, dir);
            errdefer self.gpa.free(key);
            try self.verdicts.put(self.gpa, key, inside);
            if (!inside) {
                const shown = try std.fmt.allocPrint(self.gpa, "{s}/", .{dir});
                errdefer self.gpa.free(shown);
                std.mem.replaceScalar(u8, shown, '\\', '/');
                try self.outside.append(self.gpa, shown);
                return false;
            }
        }
        return true;
    }

    /// Keeps the paths `keeps` accepts, in order, and returns the kept prefix
    /// of `paths`.
    pub fn filter(self: *Confine, comptime T: type, paths: []T) ![]T {
        var kept: usize = 0;
        for (paths) |p| {
            if (!try self.keeps(p)) continue;
            paths[kept] = p;
            kept += 1;
        }
        return paths[0..kept];
    }

    fn dirInside(self: *Confine, dir: []const u8) !bool {
        const root_real = self.root_real orelse return true;
        const abs = try std.fmt.allocPrint(self.gpa, "{s}\\{s}", .{ self.root, dir });
        defer self.gpa.free(abs);
        std.mem.replaceScalar(u8, abs, '/', '\\');
        if (!isReparsePoint(abs)) return true;
        const final = try exe_path.finalDosPath(self.gpa, abs) orelse return false;
        defer self.gpa.free(final);
        return isUnder(root_real, final);
    }
};

/// True when the path exists and is a junction, symbolic link or other
/// reparse point. A path that cannot be read is reported as not one.
pub fn isReparsePoint(path_abs: []const u8) bool {
    if (builtin.os.tag != .windows) return false;
    var wide: [windows.PATH_MAX_WIDE + 8:0]u16 = undefined;
    const prefix = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\");
    const use_prefix = std.fs.path.isAbsolute(path_abs) and !std.mem.startsWith(u8, path_abs, "\\\\");
    const offset: usize = if (use_prefix) prefix.len else 0;
    if (offset + path_abs.len >= wide.len) return false;
    if (use_prefix) @memcpy(wide[0..prefix.len], prefix);
    const len = std.unicode.wtf8ToWtf16Le(wide[offset..], path_abs) catch return false;
    for (wide[offset .. offset + len]) |*unit| {
        if (unit.* == '/') unit.* = '\\';
    }
    wide[offset + len] = 0;
    const attributes = GetFileAttributesW(&wide);
    if (attributes == invalid_file_attributes) return false;
    return attributes & file_attribute_reparse_point != 0;
}

const invalid_file_attributes: windows.DWORD = 0xFFFFFFFF;
const file_attribute_reparse_point: windows.DWORD = 0x00000400;
extern "kernel32" fn GetFileAttributesW(name: [*:0]const u16) callconv(.winapi) windows.DWORD;

test "isUnder compares case and slashes loosely and respects the name boundary" {
    try std.testing.expect(isUnder("C:\\repo", "C:\\repo"));
    try std.testing.expect(isUnder("C:\\repo\\", "c:/REPO/src/a.ts"));
    try std.testing.expect(!isUnder("C:\\repo", "C:\\repository\\a.ts"));
    try std.testing.expect(!isUnder("C:\\repo", "C:\\other"));
}
