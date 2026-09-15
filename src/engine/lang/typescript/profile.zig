const ts = @import("../../tree_sitter.zig");
const Profile = @import("../profile.zig").Profile;

extern fn tree_sitter_typescript() callconv(.c) ?*const ts.Language;

fn grammar() *const ts.Language {
    return tree_sitter_typescript().?;
}

pub const profile: Profile = .{
    .name = "typescript",
    .extensions = &.{".ts"},
    .grammar = grammar,
};
