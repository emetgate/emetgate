pub const tree_sitter = @import("tree_sitter.zig");
pub const alloc_bridge = @import("alloc_bridge.zig");
pub const traversal = @import("traversal.zig");
pub const loader = @import("loader.zig");
pub const syntax = @import("syntax.zig");
pub const skeleton = @import("skeleton.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
