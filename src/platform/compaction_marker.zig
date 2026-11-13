//! The compaction marker: `.emetgate/compacted` under the repository root.
//! The PreCompact hook raises the number it holds each time Claude Code
//! compacts the conversation, and the server reads it on each tool call to
//! learn that the client no longer has the code it was shown before.
const std = @import("std");
const lockdown_slash = @import("lockdown_slash.zig");
const shadow = @import("shadow.zig");

const Allocator = std.mem.Allocator;

pub const file_name = "compacted";
pub const max_marker_bytes = 32;

/// The marker's value, or 0 when there is none or it cannot be read. The value
/// only grows while the marker exists; a server that remembers the last value
/// it saw treats any other value as a compaction.
pub fn generation(io: std.Io, root_abs: []const u8) u64 {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "{s}\\{s}\\{s}", .{ root_abs, shadow.workspace_dir, file_name }) catch return 0;
    var buffer: [max_marker_bytes]u8 = undefined;
    const bytes = std.Io.Dir.cwd().readFile(io, path, &buffer) catch return 0;
    return parse(bytes) orelse 0;
}

pub fn parse(bytes: []const u8) ?u64 {
    const text = std.mem.trim(u8, bytes, " \t\r\n");
    if (text.len == 0) return null;
    return std.fmt.parseInt(u64, text, 10) catch null;
}

/// The value after `previous`: the wall clock in milliseconds, or one more than
/// `previous` when the clock is not ahead of it. A marker that was deleted and
/// written again therefore still gets a value larger than any it held before.
pub fn next(previous: u64, now_ms: i64) u64 {
    const clock: u64 = if (now_ms > 0) @intCast(now_ms) else 0;
    const after = std.math.add(u64, previous, 1) catch previous;
    return @max(clock, after);
}

/// Raises the marker under `root_abs` and returns its new value. The number is
/// written beside the marker and renamed over it, so a reader sees the old or
/// the new value and never a partial one.
pub fn bump(gpa: Allocator, io: std.Io, root_abs: []const u8) !u64 {
    const dir = try std.fs.path.join(gpa, &.{ root_abs, shadow.workspace_dir });
    defer gpa.free(dir);
    const status = try std.Io.Dir.cwd().createDirPathStatus(io, dir, .default_dir);
    if (status == .created) ignoreWorkspace(gpa, io, dir);
    const value = next(generation(io, root_abs), std.Io.Timestamp.now(io, .real).toMilliseconds());
    const path = try std.fs.path.join(gpa, &.{ dir, file_name });
    defer gpa.free(path);
    var text: [max_marker_bytes]u8 = undefined;
    try lockdown_slash.place(gpa, io, path, try std.fmt.bufPrint(&text, "{d}\n", .{value}));
    return value;
}

fn ignoreWorkspace(gpa: Allocator, io: std.Io, dir: []const u8) void {
    const path = std.fs.path.join(gpa, &.{ dir, ".gitignore" }) catch return;
    defer gpa.free(path);
    const file = std.Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true }) catch return;
    defer file.close(io);
    file.writeStreamingAll(io, "*\n") catch {};
}
