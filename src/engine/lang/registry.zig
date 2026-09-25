const std = @import("std");
const Profile = @import("profile.zig").Profile;

pub const profiles = [_]*const Profile{
    &@import("typescript/profile.zig").profile,
    &@import("tsx/profile.zig").profile,
    &@import("javascript/profile.zig").profile,
    &@import("zig/profile.zig").profile,
};

pub fn forPath(path: []const u8) ?*const Profile {
    for (profiles) |profile| {
        if (profile.handles(path)) return profile;
    }
    return null;
}

const testing = std.testing;
const ts = @import("../tree_sitter.zig");
const alloc_bridge = @import("../alloc_bridge.zig");

test "every registered profile loads its grammar and alone claims its extensions in any case" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();

    for (profiles, 0..) |profile, i| {
        errdefer std.debug.print("profile: {s}\n", .{profile.name});
        const parser = try ts.Parser.init(profile.grammar());
        parser.deinit();

        try testing.expect(profile.extensions.len > 0);
        for (profile.extensions) |extension| {
            var buf: [64]u8 = undefined;
            const path = try std.fmt.bufPrint(&buf, "src/file{s}", .{extension});
            try testing.expectEqual(profile, forPath(path).?);
            try testing.expectEqual(profile, forPath(std.ascii.upperString(buf[path.len..], path)).?);
            for (profiles[i + 1 ..]) |other| try testing.expect(!other.handles(path));
        }
    }
    try testing.expect(forPath("Makefile") == null);
    try testing.expect(forPath("notes.unknown-language") == null);
}
