const std = @import("std");
const symbol = @import("../engine/symbol.zig");
const kind_spans = @import("../engine/kind_spans.zig");
const doc_spans = @import("../engine/doc_spans.zig");

const Allocator = std.mem.Allocator;

pub const magic = "EMGIDX\x00\x02";
pub const version: u32 = 2;
pub const checksum_len = 16;

pub const Stamp = struct { mtime_ns: i96, size: u64 };

pub const Entry = struct {
    path: []const u8,
    stamp: Stamp,
    trigrams: []const u24,
    content_hash: ?symbol.Hash,
    spans: ?kind_spans.FileSpans,
    doc: ?doc_spans.DocSpans,
};

pub const Contents = struct {
    written_ns: i96,
    git_stamp: ?Stamp,
    files: []const []const u8,
    entries: []Entry,
};

const Writer = struct {
    list: std.ArrayList(u8) = .empty,
    gpa: Allocator,

    fn bytes(self: *Writer, b: []const u8) !void {
        try self.list.appendSlice(self.gpa, b);
    }

    fn int(self: *Writer, comptime T: type, value: T) !void {
        var buf: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
        std.mem.writeInt(T, &buf, value, .little);
        try self.bytes(&buf);
    }

    fn str(self: *Writer, s: []const u8) !void {
        try self.int(u32, @intCast(s.len));
        try self.bytes(s);
    }

    fn flag(self: *Writer, on: bool) !void {
        try self.int(u8, @intFromBool(on));
    }
};

pub fn encode(gpa: Allocator, contents: Contents) ![]u8 {
    var w: Writer = .{ .gpa = gpa };
    errdefer w.list.deinit(gpa);
    try w.bytes(magic);
    try w.int(u32, version);
    try w.int(i128, contents.written_ns);
    try w.flag(contents.git_stamp != null);
    if (contents.git_stamp) |g| {
        try w.int(i128, g.mtime_ns);
        try w.int(u64, g.size);
    }
    try w.int(u32, @intCast(contents.files.len));
    for (contents.files) |f| try w.str(f);
    try w.int(u32, @intCast(contents.entries.len));
    for (contents.entries) |e| {
        try w.str(e.path);
        try w.int(i128, e.stamp.mtime_ns);
        try w.int(u64, e.stamp.size);
        try w.flag(e.content_hash != null);
        if (e.content_hash) |h| try w.bytes(&h);
        try w.int(u32, @intCast(e.trigrams.len));
        for (e.trigrams) |t| try w.int(u24, t);
        try w.flag(e.spans != null);
        if (e.spans) |sp| {
            try w.int(u32, @intCast(sp.symbols.len));
            for (sp.symbols) |sym| {
                try w.str(sym.ref_text);
                try w.str(sym.name);
                try w.bytes(&sym.hash);
                try w.int(u32, sym.node_start);
                try w.int(u32, sym.body_start);
                try w.int(u32, sym.node_end);
            }
            try w.int(u32, @intCast(sp.kind_spans.len));
            for (sp.kind_spans) |k| {
                try w.int(u32, k.start);
                try w.int(u32, k.end);
                try w.int(u8, @intFromEnum(k.kind));
            }
            try w.int(u32, @intCast(sp.reference_spans.len));
            for (sp.reference_spans) |r| {
                try w.int(u32, r.start);
                try w.int(u32, r.end);
            }
        }
        try w.flag(e.doc != null);
        if (e.doc) |d| {
            try w.int(u8, @intFromEnum(d.kind));
            try w.int(u32, @intCast(d.spans.len));
            for (d.spans) |span| {
                try w.int(u32, span.start);
                try w.int(u32, span.end);
                try w.str(span.label);
            }
        }
    }
    const sum = symbol.hashOf(w.list.items);
    try w.bytes(&sum);
    return w.list.toOwnedSlice(gpa);
}

pub const DecodeError = error{ Corrupt, OutOfMemory };

const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn take(self: *Reader, n: usize) DecodeError![]const u8 {
        if (n > self.buf.len - self.pos) return error.Corrupt;
        defer self.pos += n;
        return self.buf[self.pos .. self.pos + n];
    }

    fn int(self: *Reader, comptime T: type) DecodeError!T {
        const len = @divExact(@typeInfo(T).int.bits, 8);
        const b = try self.take(len);
        return std.mem.readInt(T, b[0..len], .little);
    }

    fn count(self: *Reader, min_item_bytes: usize) DecodeError!usize {
        const n = try self.int(u32);
        if (@as(u64, n) * min_item_bytes > self.buf.len - self.pos) return error.Corrupt;
        return n;
    }

    fn str(self: *Reader, a: Allocator) DecodeError![]const u8 {
        const n = try self.int(u32);
        return a.dupe(u8, try self.take(n));
    }

    fn flag(self: *Reader) DecodeError!bool {
        return switch (try self.int(u8)) {
            0 => false,
            1 => true,
            else => error.Corrupt,
        };
    }

    fn hash(self: *Reader) DecodeError!symbol.Hash {
        var out: symbol.Hash = undefined;
        @memcpy(&out, try self.take(out.len));
        return out;
    }
};

pub fn decode(a: Allocator, bytes: []const u8) DecodeError!Contents {
    if (bytes.len < magic.len + 4 + checksum_len) return error.Corrupt;
    const body = bytes[0 .. bytes.len - checksum_len];
    const claimed = bytes[bytes.len - checksum_len ..];
    const actual = symbol.hashOf(body);
    if (!std.mem.eql(u8, &actual, claimed)) return error.Corrupt;
    var r: Reader = .{ .buf = body };
    if (!std.mem.eql(u8, try r.take(magic.len), magic)) return error.Corrupt;
    if (try r.int(u32) != version) return error.Corrupt;
    const written_ns: i96 = @intCast(try r.int(i128));
    var git_stamp: ?Stamp = null;
    if (try r.flag()) git_stamp = .{ .mtime_ns = @intCast(try r.int(i128)), .size = try r.int(u64) };
    const files = try a.alloc([]const u8, try r.count(4));
    for (files) |*f| f.* = try r.str(a);
    const entries = try a.alloc(Entry, try r.count(4 + 16 + 8 + 1 + 4 + 1 + 1));
    for (entries) |*e| {
        e.path = try r.str(a);
        e.stamp = .{ .mtime_ns = @intCast(try r.int(i128)), .size = try r.int(u64) };
        e.content_hash = if (try r.flag()) try r.hash() else null;
        const trigrams = try a.alloc(u24, try r.count(3));
        for (trigrams) |*t| t.* = try r.int(u24);
        e.trigrams = trigrams;
        e.spans = null;
        if (try r.flag()) {
            const symbols = try a.alloc(kind_spans.SymbolSpan, try r.count(4 + 4 + 16 + 12));
            for (symbols) |*sym| sym.* = .{
                .ref_text = try r.str(a),
                .name = try r.str(a),
                .hash = try r.hash(),
                .node_start = try r.int(u32),
                .body_start = try r.int(u32),
                .node_end = try r.int(u32),
            };
            const kinds = try a.alloc(kind_spans.KindSpan, try r.count(9));
            for (kinds) |*k| {
                const start = try r.int(u32);
                const end = try r.int(u32);
                const tag = try r.int(u8);
                if (tag > @intFromEnum(kind_spans.Kind.string)) return error.Corrupt;
                k.* = .{ .start = start, .end = end, .kind = @enumFromInt(tag) };
            }
            const refs = try a.alloc(kind_spans.Span, try r.count(8));
            for (refs) |*ref| ref.* = .{ .start = try r.int(u32), .end = try r.int(u32) };
            e.spans = .{ .symbols = symbols, .kind_spans = kinds, .reference_spans = refs };
        }
        e.doc = null;
        if (try r.flag()) {
            const tag = try r.int(u8);
            if (tag > @intFromEnum(doc_spans.Kind.markdown)) return error.Corrupt;
            const spans = try a.alloc(doc_spans.Span, try r.count(12));
            for (spans) |*span| span.* = .{ .start = try r.int(u32), .end = try r.int(u32), .label = try r.str(a) };
            e.doc = .{ .kind = @enumFromInt(tag), .spans = spans };
        }
    }
    if (r.pos != body.len) return error.Corrupt;
    return .{ .written_ns = written_ns, .git_stamp = git_stamp, .files = files, .entries = entries };
}

const testing = std.testing;

fn sample(a: Allocator) !Contents {
    const symbols = try a.dupe(kind_spans.SymbolSpan, &.{.{ .ref_text = "Store.load", .name = "load", .hash = [_]u8{7} ** 16, .node_start = 1, .body_start = 5, .node_end = 40 }});
    const kinds = try a.dupe(kind_spans.KindSpan, &.{ .{ .start = 10, .end = 20, .kind = .comment }, .{ .start = 22, .end = 30, .kind = .string } });
    const refs = try a.dupe(kind_spans.Span, &.{.{ .start = 31, .end = 35 }});
    const doc = try a.dupe(doc_spans.Span, &.{.{ .start = 0, .end = 9, .label = "/name with \"quotes\"\nand a newline" }});
    const entries = try a.dupe(Entry, &.{
        .{ .path = "src/a b.ts", .stamp = .{ .mtime_ns = -5, .size = 40 }, .trigrams = &.{ 1, 0xabcdef }, .content_hash = [_]u8{3} ** 16, .spans = .{ .symbols = symbols, .kind_spans = kinds, .reference_spans = refs }, .doc = null },
        .{ .path = "package.json", .stamp = .{ .mtime_ns = 1 << 80, .size = 9 }, .trigrams = &.{}, .content_hash = null, .spans = null, .doc = .{ .kind = .json, .spans = doc } },
    });
    return .{ .written_ns = 123456789, .git_stamp = .{ .mtime_ns = 99, .size = 1024 }, .files = &.{ "src/a b.ts", "package.json" }, .entries = entries };
}

test "an index file round-trips every field, text with quotes and newlines included" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original = try sample(a);
    const bytes = try encode(testing.allocator, original);
    defer testing.allocator.free(bytes);
    const back = try decode(a, bytes);
    try testing.expectEqual(original.written_ns, back.written_ns);
    try testing.expectEqual(original.git_stamp.?.size, back.git_stamp.?.size);
    try testing.expectEqualStrings("package.json", back.files[1]);
    try testing.expectEqualStrings("src/a b.ts", back.entries[0].path);
    try testing.expectEqual(@as(i96, -5), back.entries[0].stamp.mtime_ns);
    try testing.expectEqualSlices(u24, &.{ 1, 0xabcdef }, back.entries[0].trigrams);
    try testing.expectEqualStrings("Store.load", back.entries[0].spans.?.symbols[0].ref_text);
    try testing.expectEqual(kind_spans.Kind.string, back.entries[0].spans.?.kind_spans[1].kind);
    try testing.expectEqual(@as(u32, 35), back.entries[0].spans.?.reference_spans[0].end);
    try testing.expect(back.entries[1].content_hash == null);
    try testing.expectEqual(@as(i96, 1 << 80), back.entries[1].stamp.mtime_ns);
    try testing.expectEqualStrings("/name with \"quotes\"\nand a newline", back.entries[1].doc.?.spans[0].label);
}

test "a flipped byte, a cut tail, another version or another magic is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try encode(testing.allocator, try sample(a));
    defer testing.allocator.free(bytes);

    for (0..bytes.len) |i| {
        const copy = try testing.allocator.dupe(u8, bytes);
        defer testing.allocator.free(copy);
        copy[i] ^= 0x40;
        try testing.expectError(error.Corrupt, decode(a, copy));
    }
    for (0..bytes.len) |cut| try testing.expectError(error.Corrupt, decode(a, bytes[0..cut]));

    const old = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(old);
    std.mem.writeInt(u32, old[magic.len..][0..4], version - 1, .little);
    const resum = symbol.hashOf(old[0 .. old.len - checksum_len]);
    @memcpy(old[old.len - checksum_len ..], &resum);
    try testing.expectError(error.Corrupt, decode(a, old));
}
