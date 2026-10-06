const std = @import("std");
const receipts = @import("../platform/receipts.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const version = @import("server.zig").server_version;

pub fn record(gpa: Allocator, io: std.Io, root: []const u8, rec: receipts.Record, w: *Writer, full: bool) !void {
    const written = receipts.write(gpa, io, root, rec);
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

pub fn commit(gpa: Allocator, io: std.Io, root: []const u8, oid: []const u8, w: *Writer) !void {
    const attached = receipts.attach(gpa, io, root, oid);
    const field = if (attached) |_|
        try std.fmt.allocPrint(gpa, ",\"commit\":\"{s}\"", .{oid})
    else |err|
        try std.fmt.allocPrint(gpa, ",\"commit\":\"{s}\",\"receipt_attach_error\":\"{t}\"", .{ oid, err });
    defer gpa.free(field);
    try insert(gpa, w, field);
}
