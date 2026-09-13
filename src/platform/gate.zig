const std = @import("std");
const boundedness = @import("../engine/boundedness.zig");

const Allocator = std.mem.Allocator;

pub const Gate = enum { full, scoped };

// Safety-valve default (no scoped cmd): boundedness is telemetry, not control —
// BOUNDED and UNBOUNDED both run the full test_command, behavior unchanged; teeth
// come only from the scoped path. The scoped path is a softer guarantee: it trusts
// the runner's related-test (import-graph) heuristic, blind to dynamic import / DI /
// reflection. Prefer the full command when tests reach code dynamically; scoped is
// a trade-off the user opts into explicitly. Fast-path opens only for BOUNDED.
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
