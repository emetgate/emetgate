const std = @import("std");
const receipts = @import("../platform/receipts.zig");
const commit_plan = @import("../platform/commit_plan.zig");

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
    if (made.recovered) |reason| {
        try buffer.writer.print(",\"recovered\":\"{s}\",\"recovered_left_as_found\":", .{reason});
        var js: std.json.Stringify = .{ .writer = &buffer.writer };
        try js.write(made.recovered_names[0..made.recovered_names_len]);
    }
    if (made.receipt) |batch| {
        if (receipts.attachNew(gpa, io, root, oid, &batch)) |_| {} else |err| try buffer.writer.print(",\"receipt_attach_error\":\"{t}\"", .{err});
    }
    try insert(gpa, w, buffer.written());
}
