const std = @import("std");
const boundedness = @import("../engine/boundedness.zig");

const Allocator = std.mem.Allocator;

pub const Gate = enum { full, scoped };

pub fn chooseGate(confidence: boundedness.Confidence, has_scoped: bool) Gate {
    if (confidence == .bounded and has_scoped) return .scoped;
    return .full;
}

pub fn substituteFile(gpa: Allocator, template: []const u8, rel: []const u8) ![]u8 {
    const needle = "{file}";
    const count = std.mem.count(u8, template, needle);
    if (count == 0) return gpa.dupe(u8, template);
    const out = try gpa.alloc(u8, template.len - count * needle.len + count * rel.len);
    _ = std.mem.replace(u8, template, needle, rel, out);
    return out;
}
