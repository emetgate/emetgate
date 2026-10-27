const std = @import("std");
const receipts = @import("../platform/receipts.zig");
const commit_plan = @import("../platform/commit_plan.zig");
const commit_refusal = @import("../platform/commit_refusal.zig");
const wire = @import("wire.zig");

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

pub fn restated(gpa: Allocator, text: []const u8, to: []const u8, extra: []const u8) !?[]u8 {
    const open = "{\"status\":\"";
    if (!std.mem.startsWith(u8, text, open)) return null;
    const end = std.mem.indexOfScalarPos(u8, text, open.len, '"') orelse return null;
    const status = text[open.len..end];
    if (!std.mem.eql(u8, status, wire.written_status) and !std.mem.eql(u8, status, wire.committed_status)) return null;
    return try std.fmt.allocPrint(gpa, "{s}{s}\"{s}{s}", .{ open, to, extra, text[end + 1 ..] });
}

const max_unverified_files = 20;
const kept_fields = [_][]const u8{ "commit", "commit_unfinished", "files_left_as_found", "left_as_found" };

pub fn unverified(gpa: Allocator, text: []const u8, to: []const u8, hint: []const u8) !?[]u8 {
    const open = "{\"status\":\"";
    if (!std.mem.startsWith(u8, text, open)) return null;
    const end = std.mem.indexOfScalarPos(u8, text, open.len, '"') orelse return null;
    const status = text[open.len..end];
    if (!std.mem.eql(u8, status, wire.written_status) and !std.mem.eql(u8, status, wire.committed_status)) return null;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const close = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, text[0..close], .{}) catch return null;
    if (parsed != .object) return null;
    var files: std.ArrayList([]const u8) = .empty;
    try collectFile(arena, &files, parsed);
    for ([_][]const u8{ "edits", "files" }) |name| {
        const list = parsed.object.get(name) orelse continue;
        if (list != .array) continue;
        for (list.array.items) |item| try collectFile(arena, &files, item);
    }
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer };
    try js.beginObject();
    try js.objectField("status");
    try js.write(to);
    try js.objectField("files");
    try js.write(files.items[0..@min(files.items.len, max_unverified_files)]);
    if (files.items.len > max_unverified_files) {
        try js.objectField("files_more");
        try js.write(files.items.len - max_unverified_files);
    }
    for (kept_fields) |name| {
        const value = parsed.object.get(name) orelse continue;
        try js.objectField(name);
        try js.write(value);
    }
    try js.objectField("tests");
    try js.write(hint);
    try js.endObject();
    try out.writer.writeByte('\n');
    return try out.toOwnedSlice();
}

fn collectFile(arena: Allocator, files: *std.ArrayList([]const u8), value: std.json.Value) !void {
    if (value != .object) return;
    const file = value.object.get("file") orelse return;
    if (file != .string) return;
    for (files.items) |seen| {
        if (std.mem.eql(u8, seen, file.string)) return;
    }
    try files.append(arena, file.string);
}

fn promote(gpa: Allocator, w: *Writer) !void {
    const allocating: *std.Io.Writer.Allocating = @fieldParentPtr("writer", w);
    const text = (try restated(gpa, allocating.written(), wire.committed_status, "")) orelse return;
    defer gpa.free(text);
    allocating.shrinkRetainingCapacity(0);
    try allocating.writer.writeAll(text);
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
    try promote(gpa, w);
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

test "receipt note: an unverified write is one short line that names the files and drops the symbol listing" {
    const gpa = std.testing.allocator;
    const text = "{\"status\":\"written\",\"edits\":[{\"file\":\"src/A.cs\",\"symbols\":[{\"symbol\":\"A\",\"new_hash\":\"abc\"}]},{\"file\":\"src/A.cs\",\"symbols\":[]},{\"file\":\"src/B.cs\"}],\"commit\":\"c0ffee\"}\n";
    const short = (try unverified(gpa, text, "unverified_no_tests", "none: add a test command")).?;
    defer gpa.free(short);
    try std.testing.expectEqualStrings("{\"status\":\"unverified_no_tests\",\"files\":[\"src/A.cs\",\"src/B.cs\"],\"commit\":\"c0ffee\",\"tests\":\"none: add a test command\"}\n", short);
    try std.testing.expect((try unverified(gpa, "{\"status\":\"rejected\"}\n", "unverified_no_tests", "x")) == null);
}
