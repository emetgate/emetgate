const std = @import("std");
const symbol = @import("../engine/symbol.zig");

const Allocator = std.mem.Allocator;

pub const KnownFiles = struct {
    gpa: Allocator,
    hashes: std.StringHashMapUnmanaged(symbol.Hash) = .empty,

    pub fn init(gpa: Allocator) KnownFiles {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *KnownFiles) void {
        var keys = self.hashes.keyIterator();
        while (keys.next()) |key| self.gpa.free(key.*);
        self.hashes.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn note(self: *KnownFiles, abs: []const u8, hash: symbol.Hash) Allocator.Error!void {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const key = keyOf(&buffer, abs) orelse return;
        if (self.hashes.getPtr(key)) |slot| {
            slot.* = hash;
            return;
        }
        const owned = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(owned);
        try self.hashes.put(self.gpa, owned, hash);
    }

    pub fn get(self: *const KnownFiles, abs: []const u8) ?symbol.Hash {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        return self.hashes.get(keyOf(&buffer, abs) orelse return null);
    }
};

fn keyOf(buffer: *[std.fs.max_path_bytes]u8, abs: []const u8) ?[]const u8 {
    if (abs.len > buffer.len) return null;
    for (abs, buffer[0..abs.len]) |c, *slot| slot.* = if (c == '/') '\\' else std.ascii.toLower(c);
    return buffer[0..abs.len];
}

test "a file noted under one spelling is found under another spelling of the same path" {
    var known = KnownFiles.init(std.testing.allocator);
    defer known.deinit();
    const hash = symbol.fileHash("one");
    try known.note("C:\\Repo\\src\\App.js", hash);
    try std.testing.expectEqual(hash, known.get("c:/repo/src/app.js").?);
    try known.note("c:\\repo\\src\\app.js", symbol.fileHash("two"));
    try std.testing.expectEqual(symbol.fileHash("two"), known.get("C:\\Repo\\src\\App.js").?);
    try std.testing.expect(known.get("C:\\Repo\\src\\other.js") == null);
}
