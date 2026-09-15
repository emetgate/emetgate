pub const Cases = struct {
    source: []const u8,
    target_ref: []const u8,
    neighbour_ref: []const u8,
    exported_ref: []const u8,
    valid_body: []const u8,
    placeholder_body: []const u8,
    escaping_body: []const u8,
    broken_body: []const u8,
};

pub const Entry = struct {
    language: []const u8,
    cases: Cases,
};

pub const all = [_]Entry{
    .{ .language = "typescript", .cases = @import("typescript/cases.zig").cases },
};
