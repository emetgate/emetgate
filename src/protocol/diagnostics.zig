const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Diagnostic = struct {
    file: []const u8,
    line: u32,
    col: u32,
    message: []const u8,
};

pub const max_diagnostics = 100;

pub fn parse(gpa: Allocator, text: []const u8) ![]Diagnostic {
    var list: std.ArrayList(Diagnostic) = .empty;
    errdefer list.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (list.items.len >= max_diagnostics) break;
        if (parseLine(trimCr(raw))) |d| try list.append(gpa, d);
    }
    return list.toOwnedSlice(gpa);
}

fn trimCr(line: []const u8) []const u8 {
    return if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
}

fn parseLine(line: []const u8) ?Diagnostic {
    const open = std.mem.indexOfScalar(u8, line, '(') orelse return null;
    if (open == 0) return null;
    const rest = line[open + 1 ..];
    const close = std.mem.indexOfScalar(u8, rest, ')') orelse return null;
    const inside = rest[0..close];
    const comma = std.mem.indexOfScalar(u8, inside, ',') orelse return null;
    const line_no = std.fmt.parseInt(u32, inside[0..comma], 10) catch return null;
    const col_no = std.fmt.parseInt(u32, inside[comma + 1 ..], 10) catch return null;
    const after = rest[close + 1 ..];
    if (!std.mem.startsWith(u8, after, ": ")) return null;
    const message = std.mem.trim(u8, after[2..], " ");
    if (message.len == 0) return null;
    return .{ .file = line[0..open], .line = line_no, .col = col_no, .message = message };
}

const testing = std.testing;

test "parses tsc diagnostics into file, line, col and message" {
    const out =
        "src/orders.ts(12,3): error TS2322: Type 'string' is not assignable to type 'number'.\n" ++
        "some unrelated build noise\n" ++
        "src/util.ts(4,10): error TS2554: Expected 1 arguments, but got 2.\n";
    const diags = try parse(testing.allocator, out);
    defer testing.allocator.free(diags);

    try testing.expectEqual(@as(usize, 2), diags.len);
    try testing.expectEqualStrings("src/orders.ts", diags[0].file);
    try testing.expectEqual(@as(u32, 12), diags[0].line);
    try testing.expectEqual(@as(u32, 3), diags[0].col);
    try testing.expectEqualStrings("error TS2322: Type 'string' is not assignable to type 'number'.", diags[0].message);
    try testing.expectEqualStrings("src/util.ts", diags[1].file);
    try testing.expectEqual(@as(u32, 4), diags[1].line);
}

test "output without the tsc shape yields no diagnostics" {
    const diags = try parse(testing.allocator, "npm ERR! something failed\nexit 1\n");
    defer testing.allocator.free(diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "a flood of diagnostics is capped" {
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    var i: usize = 0;
    while (i < max_diagnostics + 50) : (i += 1) {
        try buffer.writer.print("f.ts({d},1): error TS1: boom\n", .{i + 1});
    }
    const diags = try parse(testing.allocator, buffer.written());
    defer testing.allocator.free(diags);
    try testing.expectEqual(max_diagnostics, diags.len);
}
