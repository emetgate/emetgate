pub const ts = @import("ts.zig");
pub const alloc_bridge = @import("alloc_bridge.zig");
pub const document = @import("document.zig");
pub const syntax = @import("syntax.zig");
pub const skeleton = @import("skeleton.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
