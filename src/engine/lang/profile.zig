const std = @import("std");
const ts = @import("../tree_sitter.zig");

pub const Profile = struct {
    name: []const u8,
    extensions: []const []const u8,
    grammar: *const fn () *const ts.Language,

    pub fn handles(self: *const Profile, path: []const u8) bool {
        for (self.extensions) |extension| {
            if (std.ascii.endsWithIgnoreCase(path, extension)) return true;
        }
        return false;
    }
};
