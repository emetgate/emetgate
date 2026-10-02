const std = @import("std");

pub const Intent = enum {
    decides,
    callers,
    callees,
    flow,
    where_defined,
    explain,
};

pub const SymbolRef = struct {
    path: []const u8,
    qname: []const u8,
};

pub const Include = struct {
    callers: ?bool = null,
    callees: ?bool = null,
    tests: ?bool = null,
};

pub const EvidenceRequest = struct {
    targets: []const SymbolRef,
    intent: Intent,
    terms: []const []const u8 = &.{},
    include: Include = .{},
};

const testing = std.testing;

test "evidence request: the six intents keep the names the question compiler and the command line use" {
    const names = [_][]const u8{ "decides", "callers", "callees", "flow", "where_defined", "explain" };
    try testing.expectEqual(names.len, std.meta.fields(Intent).len);
    for (names, 0..) |name, i| try testing.expectEqual(@as(usize, i), @intFromEnum(std.meta.stringToEnum(Intent, name).?));
}
