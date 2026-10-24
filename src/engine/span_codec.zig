const std = @import("std");
const kind_spans = @import("kind_spans.zig");
const doc_spans = @import("doc_spans.zig");
const symbol = @import("symbol.zig");

const Allocator = std.mem.Allocator;

pub const Decoded = struct {
    spans: ?kind_spans.FileSpans,
    doc: ?doc_spans.DocSpans,
};

pub const Error = error{ Corrupt, OutOfMemory };

const has_spans: u8 = 1;
const has_doc: u8 = 2;

pub fn encode(gpa: Allocator, spans: ?kind_spans.FileSpans, doc: ?doc_spans.DocSpans) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var flags: u8 = 0;
    if (spans != null) flags |= has_spans;
    if (doc != null) flags |= has_doc;
    try out.append(gpa, flags);
    if (spans) |s| {
        try varint(gpa, &out, s.symbols.len);
        for (s.symbols) |sym| {
            if (sym.body_start < sym.node_start or sym.node_end < sym.body_start) return error.Corrupt;
            try bytes(gpa, &out, sym.ref_text);
            try bytes(gpa, &out, sym.name);
            try out.appendSlice(gpa, &sym.hash);
            try varint(gpa, &out, sym.node_start);
            try varint(gpa, &out, sym.body_start - sym.node_start);
            try varint(gpa, &out, sym.node_end - sym.body_start);
        }
        const kinds = try gpa.dupe(kind_spans.KindSpan, s.kind_spans);
        defer gpa.free(kinds);
        std.mem.sort(kind_spans.KindSpan, kinds, {}, struct {
            fn less(_: void, a: kind_spans.KindSpan, b: kind_spans.KindSpan) bool {
                return a.start < b.start;
            }
        }.less);
        try varint(gpa, &out, kinds.len);
        var prev: u32 = 0;
        for (kinds) |k| {
            if (k.end < k.start) return error.Corrupt;
            try varint(gpa, &out, k.start - prev);
            try varint(gpa, &out, k.end - k.start);
            try out.append(gpa, @intFromEnum(k.kind));
            prev = k.start;
        }
        const refs = try gpa.dupe(kind_spans.Span, s.reference_spans);
        defer gpa.free(refs);
        std.mem.sort(kind_spans.Span, refs, {}, struct {
            fn less(_: void, a: kind_spans.Span, b: kind_spans.Span) bool {
                return a.start < b.start;
            }
        }.less);
        try varint(gpa, &out, refs.len);
        prev = 0;
        for (refs) |r| {
            if (r.end < r.start) return error.Corrupt;
            try varint(gpa, &out, r.start - prev);
            try varint(gpa, &out, r.end - r.start);
            prev = r.start;
        }
    }
    if (doc) |d| {
        try out.append(gpa, @intFromEnum(d.kind));
        const sorted = try gpa.dupe(doc_spans.Span, d.spans);
        defer gpa.free(sorted);
        std.mem.sort(doc_spans.Span, sorted, {}, struct {
            fn less(_: void, a: doc_spans.Span, b: doc_spans.Span) bool {
                return a.start < b.start;
            }
        }.less);
        try varint(gpa, &out, sorted.len);
        var prev: u32 = 0;
        for (sorted) |span| {
            if (span.end < span.start) return error.Corrupt;
            try varint(gpa, &out, span.start - prev);
            try varint(gpa, &out, span.end - span.start);
            try bytes(gpa, &out, span.label);
            prev = span.start;
        }
    }
    return out.toOwnedSlice(gpa);
}

fn varint(gpa: Allocator, out: *std.ArrayList(u8), value: usize) !void {
    var v: u64 = value;
    while (v >= 0x80) : (v >>= 7) try out.append(gpa, @as(u8, @truncate(v)) | 0x80);
    try out.append(gpa, @truncate(v));
}

fn bytes(gpa: Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try varint(gpa, out, text.len);
    try out.appendSlice(gpa, text);
}

const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn byte(self: *Reader) Error!u8 {
        if (self.pos >= self.buf.len) return error.Corrupt;
        defer self.pos += 1;
        return self.buf[self.pos];
    }

    fn varint(self: *Reader) Error!u32 {
        var out: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            const b = try self.byte();
            out |= @as(u64, b & 0x7f) << shift;
            if (b & 0x80 == 0) break;
            if (shift >= 35) return error.Corrupt;
            shift += 7;
        }
        if (out > std.math.maxInt(u32)) return error.Corrupt;
        return @intCast(out);
    }

    fn take(self: *Reader, n: usize) Error![]const u8 {
        if (n > self.buf.len - self.pos) return error.Corrupt;
        defer self.pos += n;
        return self.buf[self.pos .. self.pos + n];
    }

    fn text(self: *Reader) Error![]const u8 {
        return self.take(try self.varint());
    }

    fn count(self: *Reader, min_bytes: usize) Error!usize {
        const n = try self.varint();
        if (@as(u64, n) * min_bytes > self.buf.len - self.pos) return error.Corrupt;
        return n;
    }

    fn add(a: u32, b: u32) Error!u32 {
        return std.math.add(u32, a, b) catch error.Corrupt;
    }
};

pub fn decode(a: Allocator, blob: []const u8) Error!Decoded {
    var r: Reader = .{ .buf = blob };
    const flags = try r.byte();
    if (flags & ~(has_spans | has_doc) != 0) return error.Corrupt;
    var out: Decoded = .{ .spans = null, .doc = null };
    if (flags & has_spans != 0) {
        const symbols = try a.alloc(kind_spans.SymbolSpan, try r.count(3 + 16 + 3));
        for (symbols) |*sym| {
            sym.ref_text = try r.text();
            sym.name = try r.text();
            @memcpy(&sym.hash, try r.take(@sizeOf(symbol.Hash)));
            sym.node_start = try r.varint();
            sym.body_start = try Reader.add(sym.node_start, try r.varint());
            sym.node_end = try Reader.add(sym.body_start, try r.varint());
        }
        const kinds = try a.alloc(kind_spans.KindSpan, try r.count(3));
        var prev: u32 = 0;
        for (kinds) |*k| {
            const start = try Reader.add(prev, try r.varint());
            const end = try Reader.add(start, try r.varint());
            const tag = try r.byte();
            if (tag > @intFromEnum(kind_spans.Kind.string)) return error.Corrupt;
            k.* = .{ .start = start, .end = end, .kind = @enumFromInt(tag) };
            prev = start;
        }
        const refs = try a.alloc(kind_spans.Span, try r.count(2));
        prev = 0;
        for (refs) |*ref| {
            const start = try Reader.add(prev, try r.varint());
            ref.* = .{ .start = start, .end = try Reader.add(start, try r.varint()) };
            prev = start;
        }
        out.spans = .{ .symbols = symbols, .kind_spans = kinds, .reference_spans = refs };
    }
    if (flags & has_doc != 0) {
        const tag = try r.byte();
        if (tag > @intFromEnum(doc_spans.Kind.markdown)) return error.Corrupt;
        const spans = try a.alloc(doc_spans.Span, try r.count(3));
        var prev: u32 = 0;
        for (spans) |*span| {
            const start = try Reader.add(prev, try r.varint());
            span.* = .{ .start = start, .end = try Reader.add(start, try r.varint()), .label = try r.text() };
            prev = start;
        }
        out.doc = .{ .kind = @enumFromInt(tag), .spans = spans };
    }
    if (r.pos != blob.len) return error.Corrupt;
    return out;
}

const testing = std.testing;

test "span codec: symbols, kind spans, reference spans and document spans round-trip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const symbols = [_]kind_spans.SymbolSpan{
        .{ .ref_text = "Store.load", .name = "load", .hash = [_]u8{7} ** 16, .node_start = 10, .body_start = 30, .node_end = 400 },
        .{ .ref_text = "top", .name = "top", .hash = [_]u8{9} ** 16, .node_start = 500, .body_start = 520, .node_end = 600 },
    };
    const kinds = [_]kind_spans.KindSpan{ .{ .start = 50, .end = 60, .kind = .string }, .{ .start = 12, .end = 20, .kind = .comment } };
    const refs = [_]kind_spans.Span{ .{ .start = 300, .end = 310 }, .{ .start = 31, .end = 35 } };
    const doc = [_]doc_spans.Span{ .{ .start = 0, .end = 9, .label = "/a/b" }, .{ .start = 2, .end = 5, .label = "/a" } };
    const blob = try encode(testing.allocator, .{ .symbols = &symbols, .kind_spans = &kinds, .reference_spans = &refs }, .{ .kind = .json, .spans = &doc });
    defer testing.allocator.free(blob);
    const back = try decode(a, blob);
    try testing.expectEqual(@as(usize, 2), back.spans.?.symbols.len);
    try testing.expectEqualStrings("Store.load", back.spans.?.symbols[0].ref_text);
    try testing.expectEqual(@as(u32, 400), back.spans.?.symbols[0].node_end);
    try testing.expectEqual(@as(u32, 12), back.spans.?.kind_spans[0].start);
    try testing.expectEqual(kind_spans.Kind.string, back.spans.?.kind_spans[1].kind);
    try testing.expectEqual(@as(u32, 35), back.spans.?.reference_spans[0].end);
    try testing.expectEqualStrings("/a/b", back.doc.?.spans[0].label);
    try testing.expectEqual(kind_spans.Kind.comment, kind_spans.classify(back.spans.?.kind_spans, 15).?);

    const none = try encode(testing.allocator, null, null);
    defer testing.allocator.free(none);
    const empty = try decode(a, none);
    try testing.expect(empty.spans == null and empty.doc == null);
}

test "span codec: a cut or altered blob is refused, never read past its end" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const symbols = [_]kind_spans.SymbolSpan{.{ .ref_text = "f", .name = "f", .hash = [_]u8{1} ** 16, .node_start = 0, .body_start = 4, .node_end = 9 }};
    const blob = try encode(testing.allocator, .{ .symbols = &symbols, .kind_spans = &.{}, .reference_spans = &.{} }, null);
    defer testing.allocator.free(blob);
    for (0..blob.len) |cut| try testing.expectError(error.Corrupt, decode(arena.allocator(), blob[0..cut]));
    const extra = try std.mem.concat(testing.allocator, u8, &.{ blob, "x" });
    defer testing.allocator.free(extra);
    try testing.expectError(error.Corrupt, decode(arena.allocator(), extra));
}
