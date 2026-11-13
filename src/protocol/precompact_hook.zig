//! `emetgate hook precompact`: the PreCompact hook lockdown gives Claude Code.
//! It raises the compaction marker of the repository the session works in and
//! never stops a compaction: it prints nothing and its command exits 0.
const std = @import("std");
const json_input = @import("json_input.zig");
const compaction_marker = @import("../platform/compaction_marker.zig");
const lockdown_slash = @import("../platform/lockdown_slash.zig");
const repo = @import("../platform/repo.zig");

const Allocator = std.mem.Allocator;

pub const hook_args = lockdown_slash.precompact_args;
pub const max_input_bytes = 4 * 1024 * 1024;

/// The `cwd` field of the hook JSON, when the input is an object that has one
/// as a non-empty string.
pub fn cwdOf(arena: Allocator, input: []const u8) ?[]const u8 {
    const parsed = json_input.parseLeaky(std.json.Value, arena, input, .{}) catch return null;
    if (parsed != .object) return null;
    const cwd = parsed.object.get("cwd") orelse return null;
    if (cwd != .string or cwd.string.len == 0) return null;
    return cwd.string;
}

/// Raises the marker of the repository that holds the hook's `cwd`, or, when
/// the input names none or it is not in a repository, the one that holds
/// `fallback_dir`. Returns the new value, or null when no marker was written.
pub fn record(gpa: Allocator, io: std.Io, fallback_dir: []const u8, input: []const u8) ?u64 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = rootOf(gpa, io, cwdOf(arena, input)) orelse rootOf(gpa, io, fallback_dir) orelse return null;
    defer gpa.free(root);
    return compaction_marker.bump(gpa, io, root) catch null;
}

fn rootOf(gpa: Allocator, io: std.Io, dir: ?[]const u8) ?[]u8 {
    return repo.gitToplevel(gpa, io, dir orelse return null) catch null;
}
