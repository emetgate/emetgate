const std = @import("std");
const symbol = @import("../engine/symbol.zig");
const read_budget = @import("read_budget.zig");
const wire = @import("wire.zig");
const reply_contract = @import("reply_contract.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const threshold = 8 * 1024;

pub const hint = "outline only, file over 8 KiB: read_symbol {file,symbol} for a body, read_file line_start/line_end for raw lines";

const Row = struct {
    start: u32,
    end: u32,
    kind: []const u8,
    ref: symbol.Ref,
    hash: symbol.Hash,
};

fn lessByStart(_: void, a: Row, b: Row) bool {
    if (a.start != b.start) return a.start < b.start;
    return a.end > b.end;
}

pub const View = struct {
    /// First outline row to show.
    offset: usize = 0,
    /// Most bytes the outline rows may take in the reply, JSON-escaped.
    limit: usize = std.math.maxInt(usize),
};

pub const Rendered = struct {
    text: []u8,
    /// First row left out, when the rows did not all fit.
    next: ?usize,
    total: usize,
};

pub fn render(gpa: Allocator, file: []const u8, source: []const u8, table: *const symbol.Table, view: View) !Rendered {
    const lines = try read_budget.Lines.init(gpa, source);
    defer lines.deinit(gpa);
    const rows = try gpa.alloc(Row, table.symbols.len + table.declarations.len);
    defer gpa.free(rows);
    for (table.symbols, rows[0..table.symbols.len]) |entry, *row| {
        row.* = .{ .start = entry.declaration.start, .end = entry.declaration.end, .kind = @tagName(entry.kind), .ref = entry.ref, .hash = entry.hash };
    }
    for (table.declarations, rows[table.symbols.len..]) |entry, *row| {
        row.* = .{ .start = entry.declaration.start, .end = entry.declaration.end, .kind = @tagName(entry.kind), .ref = entry.ref, .hash = entry.hash };
    }
    std.mem.sort(Row, rows, {}, lessByStart);

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    var next: ?usize = null;
    var used: usize = 0;
    const first_row = @min(view.offset, rows.len);
    for (rows[first_row..], first_row..) |row, i| {
        const before = body.written().len;
        const first = lines.lineOf(row.start);
        const last = lines.lineOf(if (row.end > row.start) row.end - 1 else row.start);
        const hex = symbol.formatHash(row.hash);
        try body.writer.print("{d}-{d} {s} {f} {s}\n", .{ first, last, row.kind, row.ref, hex[0..] });
        const added = reply_contract.encodedLen(body.written()[before..], .json);
        if (used + added > view.limit and i > first_row) {
            body.shrinkRetainingCapacity(before);
            next = i;
            break;
        }
        used += added;
    }

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer };
    try js.beginObject();
    try js.objectField("file");
    try js.write(file);
    try wire.writeFileHash(&js, symbol.fileHash(source));
    try js.objectField("bytes");
    try js.write(source.len);
    try js.objectField("lines");
    try js.write(lines.starts.len - @intFromBool(source.len != 0 and source[source.len - 1] == '\n'));
    if (first_row != 0 or next != null) {
        try js.objectField("rows");
        try js.write(rows.len);
        try js.objectField("offset");
        try js.write(first_row);
    }
    try js.objectField("outline");
    try js.write(body.written());
    try js.objectField("hint");
    try js.write(hint);
    try js.endObject();
    try out.writer.writeByte('\n');
    return .{ .text = try out.toOwnedSlice(), .next = next, .total = rows.len };
}
