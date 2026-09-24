const Kind = @import("emetgate").symbol.Kind;

pub const Member = struct {
    ref: []const u8,
    kind: Kind,
};

pub const Cases = struct {
    member_source: []const u8,
    members: []const Member,
    source: []const u8,
    target_ref: []const u8,
    neighbour_ref: []const u8,
    exported_ref: []const u8,
    valid_body: []const u8,
    placeholder_body: []const u8,
    escaping_body: []const u8,
    broken_body: []const u8,
    optional_call_source: []const u8,
    literal_source: []const u8,
    literal_flagged: []const []const u8,
    query_source: []const u8,
    has_type_annotations: bool,
};

pub const Entry = struct {
    language: []const u8,
    cases: Cases,
};

pub const all = [_]Entry{
    .{ .language = "typescript", .cases = @import("typescript/cases.zig").cases },
    .{ .language = "tsx", .cases = @import("tsx/cases.zig").cases },
    .{ .language = "javascript", .cases = @import("javascript/cases.zig").cases },
};
