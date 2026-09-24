const std = @import("std");
const wire = @import("wire.zig");
const telemetry = @import("telemetry.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const ToolResult = struct { text: []u8, is_error: bool };

pub fn success(gpa: Allocator, buffer: *std.Io.Writer.Allocating) !ToolResult {
    return .{ .text = try dupTrim(gpa, buffer.written()), .is_error = false };
}

pub fn failure(gpa: Allocator, buffer: *std.Io.Writer.Allocating, err: anyerror, event: *telemetry.Event) !ToolResult {
    event.fail(@errorName(err));
    buffer.clearRetainingCapacity();
    try wire.writeError(&buffer.writer, @errorName(err), wire.exitCode(err));
    return .{ .text = try dupTrim(gpa, buffer.written()), .is_error = true };
}

pub fn dupTrim(gpa: Allocator, bytes: []const u8) ![]u8 {
    const end = if (bytes.len > 0 and bytes[bytes.len - 1] == '\n') bytes.len - 1 else bytes.len;
    return gpa.dupe(u8, bytes[0..end]);
}

pub fn requireString(args: ?Value, key: []const u8) error{MissingArgument}![]const u8 {
    const object = args orelse return error.MissingArgument;
    return getString(object, key) orelse error.MissingArgument;
}

pub fn getField(value: Value, key: []const u8) ?Value {
    if (value != .object) return null;
    return value.object.get(key);
}

pub fn getString(value: Value, key: []const u8) ?[]const u8 {
    const field = getField(value, key) orelse return null;
    return switch (field) {
        .string => |s| s,
        else => null,
    };
}

pub fn getInt(value: Value, key: []const u8) ?i64 {
    const field = getField(value, key) orelse return null;
    return switch (field) {
        .integer => |n| n,
        else => null,
    };
}

pub fn getBool(value: Value, key: []const u8) ?bool {
    const field = getField(value, key) orelse return null;
    return switch (field) {
        .bool => |b| b,
        else => null,
    };
}

pub fn getStringArray(value: Value, key: []const u8) ?[]const Value {
    const field = getField(value, key) orelse return null;
    return switch (field) {
        .array => |a| a.items,
        else => null,
    };
}
