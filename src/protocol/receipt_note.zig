const std = @import("std");
const receipts = @import("../platform/receipts.zig");
const commit_plan = @import("../platform/commit_plan.zig");
const commit_refusal = @import("../platform/commit_refusal.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const version = @import("server.zig").server_version;

pub fn record(gpa: Allocator, io: std.Io, root: []const u8, rec: receipts.Record, w: *Writer, full: bool, request: ?*commit_plan.Request) !void {
    var bound = rec;
    if (request) |made| {
        if (made.oid) |oid| bound.commit = .{ .base = made.base.?, .oid = oid, .runtime = made.runtime };
    }
    const written = receipts.write(gpa, io, root, bound);
    if (written) |ok| {
        if (request) |made| made.receipt = ok.batch[0..16].*;
    } else |_| {}
    if (!full) {
        if (written) |ok| gpa.free(ok.batch) else |_| {}
        return;
    }
    const field = if (written) |ok| blk: {
        defer gpa.free(ok.batch);
        break :blk try std.fmt.allocPrint(gpa, ",\"receipt\":\"{s}\",\"receipt_batch\":\"{s}\"", .{ &ok.id, ok.batch });
    } else |err| try std.fmt.allocPrint(gpa, ",\"receipt_error\":\"{t}\"", .{err});
    defer gpa.free(field);
    try insert(gpa, w, field);
}

pub fn insert(gpa: Allocator, w: *Writer, field: []const u8) !void {
    const allocating: *std.Io.Writer.Allocating = @fieldParentPtr("writer", w);
    const text = allocating.written();
    const close = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    if (close == 0 or text[close - 1] != '}') return;
    const tail = try gpa.dupe(u8, text[close - 1 ..]);
    defer gpa.free(tail);
    allocating.shrinkRetainingCapacity(close - 1);
    try allocating.writer.writeAll(field);
    try allocating.writer.writeAll(tail);
}

pub fn withRecovered(gpa: Allocator, text: []const u8, found: commit_plan.Found) ![]u8 {
    var field: std.Io.Writer.Allocating = .init(gpa);
    defer field.deinit();
    try field.writer.writeAll("\"recovered\":");
    var js: std.json.Stringify = .{ .writer = &field.writer };
    try js.write(found.reason);
    try field.writer.writeAll(",\"recovered_left_as_found\":");
    var names: std.json.Stringify = .{ .writer = &field.writer };
    try names.write(found.names());
    const close = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    if (close < 2 or text[close - 1] != '}') return std.fmt.allocPrint(gpa, "{s}\n{{{s}}}", .{ text, field.written() });
    return std.fmt.allocPrint(gpa, "{s},{s}{s}", .{ text[0 .. close - 1], field.written(), text[close - 1 ..] });
}

pub fn withPaths(gpa: Allocator, text: []const u8, named: commit_refusal.Named) ![]u8 {
    var field: std.Io.Writer.Allocating = .init(gpa);
    defer field.deinit();
    try field.writer.writeAll("\"paths\":");
    var js: std.json.Stringify = .{ .writer = &field.writer };
    try js.beginArray();
    var paths = named.paths();
    while (paths.next()) |path| {
        if (path.len != 0) try js.write(path);
    }
    try js.endArray();
    if (named.more() != 0) try field.writer.print(",\"paths_more\":{d}", .{named.more()});
    const close = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    if (close < 2 or text[close - 1] != '}') return std.fmt.allocPrint(gpa, "{s}\n{{{s}}}", .{ text, field.written() });
    return std.fmt.allocPrint(gpa, "{s},{s}{s}", .{ text[0 .. close - 1], field.written(), text[close - 1 ..] });
}

pub fn commit(gpa: Allocator, io: std.Io, root: []const u8, request: ?commit_plan.Request, w: *Writer) !void {
    const made = request orelse return;
    const oid = made.oid orelse return;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    try buffer.writer.print(",\"commit\":\"{s}\"", .{oid});
    if (made.unfinished) |name| try buffer.writer.print(",\"commit_unfinished\":\"{s}\"", .{name});
    if (made.left != 0) try buffer.writer.print(",\"files_left_as_found\":{d}", .{made.left});
    if (made.left_names_len != 0) {
        try buffer.writer.writeAll(",\"left_as_found\":");
        var js: std.json.Stringify = .{ .writer = &buffer.writer };
        try js.write(made.left_names[0..made.left_names_len]);
    }
    if (made.receipt) |batch| {
        if (receipts.attachNew(gpa, io, root, oid, &batch)) |_| {} else |err| try buffer.writer.print(",\"receipt_attach_error\":\"{t}\"", .{err});
    }
    try insert(gpa, w, buffer.written());
}

test "receipt note: the paths of a refusal are added as a list, with the count of those left out" {
    const gpa = std.testing.allocator;
    _ = commit_refusal.take();
    commit_refusal.note(&.{ "src/a.ts", "src/A.ts" }, 5);
    const named = commit_refusal.take().?;
    const text = try withPaths(gpa, "{\"status\":\"error\",\"error\":\"GateTreeNotHead\"}", named);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("{\"status\":\"error\",\"error\":\"GateTreeNotHead\",\"paths\":[\"src/a.ts\",\"src/A.ts\"],\"paths_more\":3}", text);
}
