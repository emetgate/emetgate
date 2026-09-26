const std = @import("std");
const receipts = @import("../platform/receipts.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const version = @import("server.zig").server_version;

pub fn record(gpa: Allocator, io: std.Io, root: []const u8, rec: receipts.Record, w: *Writer) !void {
    const allocating: *std.Io.Writer.Allocating = @fieldParentPtr("writer", w);
    const field = if (receipts.write(gpa, io, root, rec)) |written| blk: {
        defer gpa.free(written.batch);
        break :blk try std.fmt.allocPrint(gpa, ",\"receipt\":\"{s}\",\"receipt_batch\":\"{s}\"", .{ &written.id, written.batch });
    } else |err| try std.fmt.allocPrint(gpa, ",\"receipt_error\":\"{t}\"", .{err});
    defer gpa.free(field);
    const text = allocating.written();
    const close = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    if (close == 0 or text[close - 1] != '}') return;
    const tail = try gpa.dupe(u8, text[close - 1 ..]);
    defer gpa.free(tail);
    allocating.shrinkRetainingCapacity(close - 1);
    try allocating.writer.writeAll(field);
    try allocating.writer.writeAll(tail);
}
