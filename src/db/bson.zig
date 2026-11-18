const std = @import("std");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;

pub const max_depth = 100;
pub const max_document_bytes = 48 * 1000 * 1000;

pub const Kind = enum(u8) {
    double = 0x01,
    string = 0x02,
    document = 0x03,
    array = 0x04,
    binary = 0x05,
    undefined = 0x06,
    object_id = 0x07,
    boolean = 0x08,
    datetime = 0x09,
    null = 0x0A,
    regex = 0x0B,
    db_pointer = 0x0C,
    code = 0x0D,
    symbol = 0x0E,
    code_with_scope = 0x0F,
    int32 = 0x10,
    timestamp = 0x11,
    int64 = 0x12,
    decimal128 = 0x13,
    min_key = 0xFF,
    max_key = 0x7F,
    _,
};

pub const DecodeError = error{BadBson};

pub const Element = struct {
    key: []const u8,
    kind: Kind,
    data: []const u8,

    pub fn doc(self: Element) ?Doc {
        if (self.kind != .document and self.kind != .array) return null;
        return Doc.init(self.data) catch null;
    }

    pub fn string(self: Element) ?[]const u8 {
        if (self.kind != .string and self.kind != .symbol and self.kind != .code) return null;
        return stringBody(self.data) catch null;
    }

    pub fn int(self: Element) ?i64 {
        return switch (self.kind) {
            .int32 => std.mem.readInt(i32, self.data[0..4], .little),
            .int64 => std.mem.readInt(i64, self.data[0..8], .little),
            .double => blk: {
                const f = self.float().?;
                if (!std.math.isFinite(f) or @trunc(f) != f or @abs(f) > 9.0e15) break :blk null;
                break :blk @intFromFloat(f);
            },
            else => null,
        };
    }

    pub fn float(self: Element) ?f64 {
        return switch (self.kind) {
            .double => @bitCast(std.mem.readInt(u64, self.data[0..8], .little)),
            .int32, .int64 => @floatFromInt(self.int().?),
            else => null,
        };
    }

    pub fn boolean(self: Element) ?bool {
        if (self.kind != .boolean) return null;
        return self.data[0] != 0;
    }

    pub fn binary(self: Element) ?struct { subtype: u8, bytes: []const u8 } {
        if (self.kind != .binary) return null;
        const len: usize = @intCast(std.mem.readInt(i32, self.data[0..4], .little));
        return .{ .subtype = self.data[4], .bytes = self.data[5 .. 5 + len] };
    }

    pub fn truthy(self: Element) bool {
        return switch (self.kind) {
            .boolean => self.data[0] != 0,
            .int32, .int64, .double => (self.float() orelse 0) != 0,
            .null, .undefined => false,
            else => true,
        };
    }
};

fn stringBody(data: []const u8) DecodeError![]const u8 {
    if (data.len < 5) return error.BadBson;
    const len = std.mem.readInt(i32, data[0..4], .little);
    if (len < 1 or @as(usize, @intCast(len)) + 4 != data.len or data[data.len - 1] != 0) return error.BadBson;
    return data[4 .. data.len - 1];
}

pub const Doc = struct {
    bytes: []const u8,

    pub fn init(bytes: []const u8) DecodeError!Doc {
        if (bytes.len < 5 or bytes.len > max_document_bytes) return error.BadBson;
        const len = std.mem.readInt(i32, bytes[0..4], .little);
        if (len < 5 or @as(usize, @intCast(len)) != bytes.len or bytes[bytes.len - 1] != 0) return error.BadBson;
        return .{ .bytes = bytes };
    }

    pub fn prefix(bytes: []const u8) DecodeError!Doc {
        if (bytes.len < 5) return error.BadBson;
        const len = std.mem.readInt(i32, bytes[0..4], .little);
        if (len < 5 or @as(usize, @intCast(len)) > bytes.len) return error.BadBson;
        return init(bytes[0..@intCast(len)]);
    }

    pub fn iterator(self: Doc) Iterator {
        return .{ .bytes = self.bytes, .at = 4 };
    }

    pub fn get(self: Doc, key: []const u8) ?Element {
        var it = self.iterator();
        while (it.next() catch return null) |element| {
            if (std.mem.eql(u8, element.key, key)) return element;
        }
        return null;
    }

    pub fn validate(self: Doc) DecodeError!void {
        return self.validateDepth(0);
    }

    fn validateDepth(self: Doc, depth: usize) DecodeError!void {
        if (depth > max_depth) return error.BadBson;
        var it = self.iterator();
        while (try it.next()) |element| {
            switch (element.kind) {
                .document, .array => try (try Doc.init(element.data)).validateDepth(depth + 1),
                .string, .symbol, .code => _ = try stringBody(element.data),
                else => {},
            }
        }
    }
};

pub const Iterator = struct {
    bytes: []const u8,
    at: usize,

    pub fn next(self: *Iterator) DecodeError!?Element {
        if (self.at >= self.bytes.len - 1) return null;
        const kind: Kind = @enumFromInt(self.bytes[self.at]);
        const key_start = self.at + 1;
        const key_end = std.mem.indexOfScalarPos(u8, self.bytes, key_start, 0) orelse return error.BadBson;
        if (key_end >= self.bytes.len - 1) return error.BadBson;
        const start = key_end + 1;
        const len = try valueLength(kind, self.bytes[start .. self.bytes.len - 1]);
        if (start + len > self.bytes.len - 1) return error.BadBson;
        self.at = start + len;
        return .{ .key = self.bytes[key_start..key_end], .kind = kind, .data = self.bytes[start .. start + len] };
    }
};

fn readLen(rest: []const u8) DecodeError!usize {
    if (rest.len < 4) return error.BadBson;
    const n = std.mem.readInt(i32, rest[0..4], .little);
    if (n < 0) return error.BadBson;
    return @intCast(n);
}

fn cstringLen(rest: []const u8) DecodeError!usize {
    const end = std.mem.indexOfScalar(u8, rest, 0) orelse return error.BadBson;
    return end + 1;
}

fn valueLength(kind: Kind, rest: []const u8) DecodeError!usize {
    const len: usize = switch (kind) {
        .double, .datetime, .timestamp, .int64 => 8,
        .int32 => 4,
        .decimal128 => 16,
        .object_id => 12,
        .boolean => 1,
        .null, .undefined, .min_key, .max_key => 0,
        .string, .symbol, .code => 4 + try readLen(rest),
        .document, .array, .code_with_scope => try readLen(rest),
        .binary => 5 + try readLen(rest),
        .regex => blk: {
            const a = try cstringLen(rest);
            break :blk a + try cstringLen(rest[@min(a, rest.len)..]);
        },
        .db_pointer => blk: {
            const s = 4 + try readLen(rest);
            break :blk s + 12;
        },
        _ => return error.BadBson,
    };
    if (len > rest.len) return error.BadBson;
    if (kind == .boolean and rest[0] > 1) return error.BadBson;
    if ((kind == .document or kind == .array or kind == .code_with_scope) and len < 5) return error.BadBson;
    return len;
}

pub const EncodeError = error{ KeyHasNul, TooDeep, BadExtendedJson, OutOfMemory };

pub const Builder = struct {
    gpa: Allocator,
    buf: std.ArrayList(u8) = .empty,
    stack: std.ArrayList(usize) = .empty,

    pub fn init(gpa: Allocator) Builder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Builder) void {
        self.buf.deinit(self.gpa);
        self.stack.deinit(self.gpa);
    }

    pub fn bytes(self: *const Builder) []const u8 {
        return self.buf.items;
    }

    pub fn begin(self: *Builder) !void {
        try self.stack.append(self.gpa, self.buf.items.len);
        try self.buf.appendNTimes(self.gpa, 0, 4);
    }

    pub fn end(self: *Builder) !void {
        try self.buf.append(self.gpa, 0);
        const start = self.stack.pop().?;
        const len: i32 = @intCast(self.buf.items.len - start);
        std.mem.writeInt(i32, self.buf.items[start..][0..4], len, .little);
    }

    fn head(self: *Builder, kind: Kind, key: []const u8) EncodeError!void {
        if (std.mem.indexOfScalar(u8, key, 0) != null) return error.KeyHasNul;
        try self.buf.append(self.gpa, @intFromEnum(kind));
        try self.buf.appendSlice(self.gpa, key);
        try self.buf.append(self.gpa, 0);
    }

    fn int32Raw(self: *Builder, n: i32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(i32, &b, n, .little);
        try self.buf.appendSlice(self.gpa, &b);
    }

    fn int64Raw(self: *Builder, n: i64) !void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(i64, &b, n, .little);
        try self.buf.appendSlice(self.gpa, &b);
    }

    pub fn string(self: *Builder, key: []const u8, text: []const u8) EncodeError!void {
        try self.head(.string, key);
        try self.int32Raw(@intCast(text.len + 1));
        try self.buf.appendSlice(self.gpa, text);
        try self.buf.append(self.gpa, 0);
    }

    pub fn int32(self: *Builder, key: []const u8, n: i32) EncodeError!void {
        try self.head(.int32, key);
        try self.int32Raw(n);
    }

    pub fn int64(self: *Builder, key: []const u8, n: i64) EncodeError!void {
        try self.head(.int64, key);
        try self.int64Raw(n);
    }

    pub fn int(self: *Builder, key: []const u8, n: i64) EncodeError!void {
        if (std.math.cast(i32, n)) |small| return self.int32(key, small);
        return self.int64(key, n);
    }

    pub fn double(self: *Builder, key: []const u8, f: f64) EncodeError!void {
        try self.head(.double, key);
        try self.int64Raw(@bitCast(f));
    }

    pub fn boolean(self: *Builder, key: []const u8, b: bool) EncodeError!void {
        try self.head(.boolean, key);
        try self.buf.append(self.gpa, @intFromBool(b));
    }

    pub fn null_(self: *Builder, key: []const u8) EncodeError!void {
        try self.head(.null, key);
    }

    pub fn binary(self: *Builder, key: []const u8, subtype: u8, data: []const u8) EncodeError!void {
        try self.head(.binary, key);
        try self.int32Raw(@intCast(data.len));
        try self.buf.append(self.gpa, subtype);
        try self.buf.appendSlice(self.gpa, data);
    }

    pub fn objectId(self: *Builder, key: []const u8, id: [12]u8) EncodeError!void {
        try self.head(.object_id, key);
        try self.buf.appendSlice(self.gpa, &id);
    }

    pub fn datetime(self: *Builder, key: []const u8, ms: i64) EncodeError!void {
        try self.head(.datetime, key);
        try self.int64Raw(ms);
    }

    pub fn regex(self: *Builder, key: []const u8, pattern: []const u8, options: []const u8) EncodeError!void {
        if (std.mem.indexOfScalar(u8, pattern, 0) != null or std.mem.indexOfScalar(u8, options, 0) != null) return error.KeyHasNul;
        try self.head(.regex, key);
        try self.buf.appendSlice(self.gpa, pattern);
        try self.buf.append(self.gpa, 0);
        try self.buf.appendSlice(self.gpa, options);
        try self.buf.append(self.gpa, 0);
    }

    pub fn timestamp(self: *Builder, key: []const u8, t: u32, i: u32) EncodeError!void {
        try self.head(.timestamp, key);
        var b: [8]u8 = undefined;
        std.mem.writeInt(u32, b[0..4], i, .little);
        std.mem.writeInt(u32, b[4..8], t, .little);
        try self.buf.appendSlice(self.gpa, &b);
    }

    pub fn beginDoc(self: *Builder, key: []const u8) EncodeError!void {
        try self.head(.document, key);
        try self.begin();
    }

    pub fn beginArray(self: *Builder, key: []const u8) EncodeError!void {
        try self.head(.array, key);
        try self.begin();
    }

    pub fn raw(self: *Builder, key: []const u8, kind: Kind, data: []const u8) EncodeError!void {
        try self.head(kind, key);
        try self.buf.appendSlice(self.gpa, data);
    }

    pub fn json(self: *Builder, key: []const u8, value: Value) EncodeError!void {
        return self.jsonDepth(key, value, 0);
    }

    fn jsonDepth(self: *Builder, key: []const u8, value: Value, depth: usize) EncodeError!void {
        if (depth > max_depth) return error.TooDeep;
        switch (value) {
            .null => try self.null_(key),
            .bool => |b| try self.boolean(key, b),
            .integer => |n| try self.int(key, n),
            .float => |f| try self.double(key, f),
            .number_string => |text| try self.double(key, std.fmt.parseFloat(f64, text) catch return error.BadExtendedJson),
            .string => |text| try self.string(key, text),
            .array => |list| {
                try self.beginArray(key);
                var name: [24]u8 = undefined;
                for (list.items, 0..) |item, i| try self.jsonDepth(std.fmt.bufPrint(&name, "{d}", .{i}) catch unreachable, item, depth + 1);
                try self.end();
            },
            .object => |object| {
                if (try self.extended(key, object)) return;
                try self.beginDoc(key);
                var it = object.iterator();
                while (it.next()) |entry| try self.jsonDepth(entry.key_ptr.*, entry.value_ptr.*, depth + 1);
                try self.end();
            },
        }
    }

    pub fn jsonFields(self: *Builder, object: std.json.ObjectMap) EncodeError!void {
        var it = object.iterator();
        while (it.next()) |entry| try self.jsonDepth(entry.key_ptr.*, entry.value_ptr.*, 1);
    }

    fn extended(self: *Builder, key: []const u8, object: std.json.ObjectMap) EncodeError!bool {
        const tag = extendedTag(object) orelse return false;
        const inner = object.values()[0];
        switch (tag) {
            .oid => {
                const text = if (inner == .string) inner.string else return error.BadExtendedJson;
                try self.objectId(key, parseObjectId(text) orelse return error.BadExtendedJson);
            },
            .date => {
                const ms: i64 = switch (inner) {
                    .integer => |n| n,
                    .string => |text| parseIsoDate(text) orelse return error.BadExtendedJson,
                    .object => |o| blk: {
                        if (o.count() != 1) return error.BadExtendedJson;
                        const n = o.get("$numberLong") orelse return error.BadExtendedJson;
                        if (n != .string) return error.BadExtendedJson;
                        break :blk std.fmt.parseInt(i64, n.string, 10) catch return error.BadExtendedJson;
                    },
                    else => return error.BadExtendedJson,
                };
                try self.datetime(key, ms);
            },
            .number_long => {
                if (inner != .string) return error.BadExtendedJson;
                try self.int64(key, std.fmt.parseInt(i64, inner.string, 10) catch return error.BadExtendedJson);
            },
            .number_int => {
                if (inner != .string) return error.BadExtendedJson;
                try self.int32(key, std.fmt.parseInt(i32, inner.string, 10) catch return error.BadExtendedJson);
            },
            .number_double => {
                if (inner != .string) return error.BadExtendedJson;
                try self.double(key, std.fmt.parseFloat(f64, inner.string) catch return error.BadExtendedJson);
            },
            .regular_expression => {
                if (inner != .object) return error.BadExtendedJson;
                const pattern = inner.object.get("pattern") orelse return error.BadExtendedJson;
                const options = inner.object.get("options") orelse Value{ .string = "" };
                if (pattern != .string or options != .string or inner.object.count() > 2) return error.BadExtendedJson;
                try self.regex(key, pattern.string, options.string);
            },
            .binary => {
                if (inner != .object) return error.BadExtendedJson;
                const b64 = inner.object.get("base64") orelse return error.BadExtendedJson;
                const sub = inner.object.get("subType") orelse return error.BadExtendedJson;
                if (b64 != .string or sub != .string or inner.object.count() != 2) return error.BadExtendedJson;
                const subtype = std.fmt.parseInt(u8, sub.string, 16) catch return error.BadExtendedJson;
                const decoder = std.base64.standard.Decoder;
                const n = decoder.calcSizeForSlice(b64.string) catch return error.BadExtendedJson;
                const out = try self.gpa.alloc(u8, n);
                defer self.gpa.free(out);
                decoder.decode(out, b64.string) catch return error.BadExtendedJson;
                try self.binary(key, subtype, out);
            },
            .uuid => {
                if (inner != .string) return error.BadExtendedJson;
                var out: [16]u8 = undefined;
                var n: usize = 0;
                var i: usize = 0;
                while (i < inner.string.len) {
                    if (inner.string[i] == '-') {
                        i += 1;
                        continue;
                    }
                    if (n == 16 or i + 2 > inner.string.len) return error.BadExtendedJson;
                    out[n] = std.fmt.parseInt(u8, inner.string[i .. i + 2], 16) catch return error.BadExtendedJson;
                    n += 1;
                    i += 2;
                }
                if (n != 16) return error.BadExtendedJson;
                try self.binary(key, 4, &out);
            },
            .timestamp => {
                if (inner != .object) return error.BadExtendedJson;
                const t = inner.object.get("t") orelse return error.BadExtendedJson;
                const i = inner.object.get("i") orelse return error.BadExtendedJson;
                if (t != .integer or i != .integer) return error.BadExtendedJson;
                try self.timestamp(key, std.math.cast(u32, t.integer) orelse return error.BadExtendedJson, std.math.cast(u32, i.integer) orelse return error.BadExtendedJson);
            },
            .min_key => try self.head(.min_key, key),
            .max_key => try self.head(.max_key, key),
        }
        return true;
    }
};

pub const ExtendedTag = enum { oid, date, number_long, number_int, number_double, regular_expression, binary, uuid, timestamp, min_key, max_key };

const extended_names = std.StaticStringMap(ExtendedTag).initComptime(.{
    .{ "$oid", .oid },
    .{ "$date", .date },
    .{ "$numberLong", .number_long },
    .{ "$numberInt", .number_int },
    .{ "$numberDouble", .number_double },
    .{ "$regularExpression", .regular_expression },
    .{ "$binary", .binary },
    .{ "$uuid", .uuid },
    .{ "$timestamp", .timestamp },
    .{ "$minKey", .min_key },
    .{ "$maxKey", .max_key },
});

pub fn extendedTag(object: std.json.ObjectMap) ?ExtendedTag {
    if (object.count() != 1) return null;
    return extended_names.get(object.keys()[0]);
}

pub fn parseObjectId(text: []const u8) ?[12]u8 {
    if (text.len != 24) return null;
    var out: [12]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch return null;
    return out;
}

fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn civilFromDays(z_in: i64) struct { y: i64, m: u8, d: u8 } {
    const z = z_in + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .y = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0), .m = @intCast(m), .d = @intCast(d) };
}

fn digits(text: []const u8, at: usize, n: usize) ?i64 {
    if (at + n > text.len) return null;
    for (text[at .. at + n]) |ch| if (!std.ascii.isDigit(ch)) return null;
    return std.fmt.parseInt(i64, text[at .. at + n], 10) catch null;
}

pub fn parseIsoDate(text: []const u8) ?i64 {
    const y = digits(text, 0, 4) orelse return null;
    if (text.len < 10 or text[4] != '-' or text[7] != '-') return null;
    const mo = digits(text, 5, 2) orelse return null;
    const d = digits(text, 8, 2) orelse return null;
    if (mo < 1 or mo > 12 or d < 1 or d > 31) return null;
    var ms: i64 = daysFromCivil(y, mo, d) * std.time.ms_per_day;
    var at: usize = 10;
    if (at < text.len and (text[at] == 'T' or text[at] == ' ')) {
        const h = digits(text, at + 1, 2) orelse return null;
        if (at + 3 >= text.len or text[at + 3] != ':') return null;
        const mi = digits(text, at + 4, 2) orelse return null;
        if (h > 23 or mi > 59) return null;
        ms += h * std.time.ms_per_hour + mi * std.time.ms_per_min;
        at += 6;
        if (at < text.len and text[at] == ':') {
            const s = digits(text, at + 1, 2) orelse return null;
            if (s > 60) return null;
            ms += s * std.time.ms_per_s;
            at += 3;
            if (at < text.len and text[at] == '.') {
                var end = at + 1;
                while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
                if (end == at + 1) return null;
                const frac = text[at + 1 .. end];
                var milli: i64 = 0;
                for (0..3) |i| milli = milli * 10 + (if (i < frac.len) @as(i64, frac[i] - '0') else 0);
                ms += milli;
                at = end;
            }
        }
        if (at < text.len) {
            if (text[at] == 'Z' and at + 1 == text.len) return ms;
            if ((text[at] == '+' or text[at] == '-') and at + 6 == text.len and text[at + 3] == ':') {
                const oh = digits(text, at + 1, 2) orelse return null;
                const om = digits(text, at + 4, 2) orelse return null;
                const offset = oh * std.time.ms_per_hour + om * std.time.ms_per_min;
                return if (text[at] == '+') ms - offset else ms + offset;
            }
            return null;
        }
        return ms;
    }
    if (at != text.len) return null;
    return ms;
}

pub fn writeIsoDate(w: *Writer, ms: i64) Writer.Error!void {
    const days = @divFloor(ms, std.time.ms_per_day);
    const rem: u64 = @intCast(ms - days * std.time.ms_per_day);
    const civil = civilFromDays(days);
    const secs = rem / 1000;
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{ @as(u64, @intCast(civil.y)), civil.m, civil.d, secs / 3600, (secs / 60) % 60, secs % 60 });
    if (rem % 1000 != 0) try w.print(".{d:0>3}", .{rem % 1000});
    try w.writeByte('Z');
}

pub fn writeDecimal128(w: *Writer, data: []const u8) Writer.Error!void {
    const low = std.mem.readInt(u64, data[0..8], .little);
    const high = std.mem.readInt(u64, data[8..16], .little);
    const negative = (high >> 63) != 0;
    const combination = (high >> 58) & 0x1F;
    if (combination == 0x1F) return w.writeAll("NaN");
    if (combination == 0x1E) return w.writeAll(if (negative) "-Infinity" else "Infinity");
    var exponent: i64 = undefined;
    var coefficient: u128 = undefined;
    if ((combination >> 3) == 3) {
        exponent = @intCast((high >> 47) & 0x3FFF);
        coefficient = 0;
    } else {
        exponent = @intCast((high >> 49) & 0x3FFF);
        coefficient = (@as(u128, high & 0x1FFFFFFFFFFFF) << 64) | low;
        if (coefficient > 9999999999999999999999999999999999) coefficient = 0;
    }
    exponent -= 6176;
    var buf: [40]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{coefficient}) catch unreachable;
    if (negative) try w.writeByte('-');
    const n: i64 = @intCast(text.len);
    const adjusted = exponent + n - 1;
    if (exponent <= 0 and adjusted >= -6) {
        if (exponent == 0) return w.writeAll(text);
        const point = n + exponent;
        if (point > 0) {
            const p: usize = @intCast(point);
            return w.print("{s}.{s}", .{ text[0..p], text[p..] });
        }
        try w.writeAll("0.");
        try w.splatByteAll('0', @intCast(-point));
        return w.writeAll(text);
    }
    try w.writeByte(text[0]);
    if (text.len > 1) try w.print(".{s}", .{text[1..]});
    try w.print("E{s}{d}", .{ if (adjusted >= 0) "+" else "", adjusted });
}

pub fn writeJsonString(w: *Writer, text: []const u8) Writer.Error!void {
    try w.writeByte('"');
    if (std.unicode.utf8ValidateSlice(text)) {
        try std.json.Stringify.encodeJsonStringChars(text, .{}, w);
    } else {
        for (text) |ch| {
            if (ch < 0x80) {
                try std.json.Stringify.encodeJsonStringChars(&.{ch}, .{}, w);
            } else try w.writeAll("\\ufffd");
        }
    }
    try w.writeByte('"');
}

pub fn writeRelaxed(w: *Writer, element: Element) Writer.Error!void {
    return writeRelaxedDepth(w, element, 0);
}

fn writeRelaxedDepth(w: *Writer, e: Element, depth: usize) Writer.Error!void {
    switch (e.kind) {
        .double => {
            const f = e.float().?;
            if (std.math.isNan(f)) return w.writeAll("{\"$numberDouble\":\"NaN\"}");
            if (std.math.isInf(f)) return w.writeAll(if (f > 0) "{\"$numberDouble\":\"Infinity\"}" else "{\"$numberDouble\":\"-Infinity\"}");
            if (@trunc(f) == f and @abs(f) < 1e15) return w.print("{d}.0", .{@as(i64, @intFromFloat(f))});
            try w.print("{d}", .{f});
        },
        .string => try writeJsonString(w, e.string() orelse ""),
        .document, .array => {
            const sub = e.doc() orelse return w.writeAll("null");
            if (depth >= max_depth) return w.writeAll("\"...\"");
            const is_array = e.kind == .array;
            try w.writeByte(if (is_array) '[' else '{');
            var it = sub.iterator();
            var first = true;
            while (it.next() catch null) |child| {
                if (!first) try w.writeByte(',');
                first = false;
                if (!is_array) {
                    try writeJsonString(w, child.key);
                    try w.writeByte(':');
                }
                try writeRelaxedDepth(w, child, depth + 1);
            }
            try w.writeByte(if (is_array) ']' else '}');
        },
        .binary => {
            const b = e.binary().?;
            if (b.subtype == 4 and b.bytes.len == 16) {
                const x = b.bytes;
                return w.print("{{\"$uuid\":\"{x}-{x}-{x}-{x}-{x}\"}}", .{ x[0..4], x[4..6], x[6..8], x[8..10], x[10..16] });
            }
            try w.writeAll("{\"$binary\":{\"base64\":\"");
            try std.base64.standard.Encoder.encodeWriter(w, b.bytes);
            try w.print("\",\"subType\":\"{x:0>2}\"}}}}", .{b.subtype});
        },
        .undefined => try w.writeAll("{\"$undefined\":true}"),
        .object_id => try w.print("{{\"$oid\":\"{x}\"}}", .{e.data[0..12]}),
        .boolean => try w.writeAll(if (e.data[0] != 0) "true" else "false"),
        .datetime => {
            const ms = std.mem.readInt(i64, e.data[0..8], .little);
            if (ms >= 0 and ms < 253402300800000) {
                try w.writeAll("{\"$date\":\"");
                try writeIsoDate(w, ms);
                try w.writeAll("\"}");
            } else try w.print("{{\"$date\":{{\"$numberLong\":\"{d}\"}}}}", .{ms});
        },
        .null => try w.writeAll("null"),
        .regex => {
            const a = std.mem.indexOfScalar(u8, e.data, 0).?;
            try w.writeAll("{\"$regularExpression\":{\"pattern\":");
            try writeJsonString(w, e.data[0..a]);
            try w.writeAll(",\"options\":");
            try writeJsonString(w, e.data[a + 1 .. e.data.len - 1]);
            try w.writeAll("}}");
        },
        .code => {
            try w.writeAll("{\"$code\":");
            try writeJsonString(w, e.string() orelse "");
            try w.writeByte('}');
        },
        .symbol => {
            try w.writeAll("{\"$symbol\":");
            try writeJsonString(w, e.string() orelse "");
            try w.writeByte('}');
        },
        .int32, .int64 => try w.print("{d}", .{e.int().?}),
        .timestamp => try w.print("{{\"$timestamp\":{{\"t\":{d},\"i\":{d}}}}}", .{ std.mem.readInt(u32, e.data[4..8], .little), std.mem.readInt(u32, e.data[0..4], .little) }),
        .decimal128 => {
            try w.writeAll("{\"$numberDecimal\":\"");
            try writeDecimal128(w, e.data);
            try w.writeAll("\"}");
        },
        .min_key => try w.writeAll("{\"$minKey\":1}"),
        .max_key => try w.writeAll("{\"$maxKey\":1}"),
        .db_pointer, .code_with_scope, _ => try w.print("{{\"$bsonType\":{d}}}", .{@intFromEnum(e.kind)}),
    }
}

pub fn typeName(kind: Kind) []const u8 {
    return switch (kind) {
        .double => "double",
        .string => "string",
        .document => "object",
        .array => "array",
        .binary => "binData",
        .undefined => "undefined",
        .object_id => "objectId",
        .boolean => "bool",
        .datetime => "date",
        .null => "null",
        .regex => "regex",
        .db_pointer => "dbPointer",
        .code => "javascript",
        .symbol => "symbol",
        .code_with_scope => "javascriptWithScope",
        .int32 => "int",
        .timestamp => "timestamp",
        .int64 => "long",
        .decimal128 => "decimal",
        .min_key => "minKey",
        .max_key => "maxKey",
        _ => "unknown",
    };
}

pub fn fromJson(gpa: Allocator, object: std.json.ObjectMap) ![]u8 {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try b.begin();
    try b.jsonFields(object);
    try b.end();
    return b.buf.toOwnedSlice(gpa);
}

pub fn toJson(gpa: Allocator, doc: Doc) ![]u8 {
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writeRelaxed(&out.writer, .{ .key = "", .kind = .document, .data = doc.bytes });
    return out.toOwnedSlice();
}

const testing = std.testing;

fn roundTrip(json_text: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const value = try std.json.parseFromSliceLeaky(Value, arena.allocator(), json_text, .{});
    const bytes = try fromJson(testing.allocator, value.object);
    defer testing.allocator.free(bytes);
    const doc = try Doc.init(bytes);
    try doc.validate();
    return toJson(testing.allocator, doc);
}

test "db bson: json round-trips through bson with extended json for ids, dates, longs and regexes" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "{\"a\":1,\"b\":\"x\",\"c\":[true,null,2.5],\"d\":{\"e\":-3}}", "{\"a\":1,\"b\":\"x\",\"c\":[true,null,2.5],\"d\":{\"e\":-3}}" },
        .{ "{\"_id\":{\"$oid\":\"64b7f0c2a1b2c3d4e5f60718\"}}", "{\"_id\":{\"$oid\":\"64b7f0c2a1b2c3d4e5f60718\"}}" },
        .{ "{\"at\":{\"$date\":\"2024-02-29T13:45:01.250Z\"}}", "{\"at\":{\"$date\":\"2024-02-29T13:45:01.250Z\"}}" },
        .{ "{\"at\":{\"$date\":\"2024-03-01T01:00:00+01:00\"}}", "{\"at\":{\"$date\":\"2024-03-01T00:00:00Z\"}}" },
        .{ "{\"at\":{\"$date\":{\"$numberLong\":\"-1000\"}}}", "{\"at\":{\"$date\":{\"$numberLong\":\"-1000\"}}}" },
        .{ "{\"n\":{\"$numberLong\":\"9000000000\"},\"m\":5000000000,\"f\":2.0}", "{\"n\":9000000000,\"m\":5000000000,\"f\":2.0}" },
        .{ "{\"r\":{\"$regularExpression\":{\"pattern\":\"^a\",\"options\":\"i\"}}}", "{\"r\":{\"$regularExpression\":{\"pattern\":\"^a\",\"options\":\"i\"}}}" },
        .{ "{\"u\":{\"$uuid\":\"00112233-4455-6677-8899-aabbccddeeff\"}}", "{\"u\":{\"$uuid\":\"00112233-4455-6677-8899-aabbccddeeff\"}}" },
        .{ "{\"b\":{\"$binary\":{\"base64\":\"AQI=\",\"subType\":\"00\"}}}", "{\"b\":{\"$binary\":{\"base64\":\"AQI=\",\"subType\":\"00\"}}}" },
        .{ "{\"t\":{\"$timestamp\":{\"t\":5,\"i\":7}},\"k\":{\"$minKey\":1}}", "{\"t\":{\"$timestamp\":{\"t\":5,\"i\":7}},\"k\":{\"$minKey\":1}}" },
        .{ "{\"s\":\"a\\u0000b\"}", "{\"s\":\"a\\u0000b\"}" },
    };
    for (cases) |case| {
        const got = try roundTrip(case[0]);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(case[1], got);
    }
}

test "db bson: a key with a NUL byte and malformed extended json are refused instead of truncated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const nul = try std.json.parseFromSliceLeaky(Value, arena.allocator(), "{\"ssn\\u0000x\":1}", .{});
    try testing.expectError(error.KeyHasNul, fromJson(testing.allocator, nul.object));
    for ([_][]const u8{ "{\"a\":{\"$oid\":\"zz\"}}", "{\"a\":{\"$date\":\"yesterday\"}}", "{\"a\":{\"$numberLong\":\"x\"}}" }) |text| {
        const v = try std.json.parseFromSliceLeaky(Value, arena.allocator(), text, .{});
        try testing.expectError(error.BadExtendedJson, fromJson(testing.allocator, v.object));
    }
}

test "db bson: a truncated or lying document is BadBson, never an out-of-bounds read" {
    const good = [_]u8{ 0x10, 0, 0, 0, 0x10, 'a', 0, 1, 0, 0, 0, 0x08, 'b', 0, 1, 0 };
    _ = try Doc.init(&good);
    try testing.expectError(error.BadBson, Doc.init(good[0..10]));
    var short = good;
    short[0] = 0x0D;
    try testing.expectError(error.BadBson, Doc.init(&short));
    var bad_len = good;
    bad_len[0] = 0x40;
    try testing.expectError(error.BadBson, Doc.init(&bad_len));
    var bad_bool = good;
    bad_bool[14] = 7;
    const doc = try Doc.init(&bad_bool);
    try testing.expectError(error.BadBson, doc.validate());
    var bad_kind = good;
    bad_kind[4] = 0x55;
    try testing.expectError(error.BadBson, (try Doc.init(&bad_kind)).validate());
    var string_len = [_]u8{ 0x10, 0, 0, 0, 0x02, 'a', 0, 0x7f, 0, 0, 0, 'x', 0, 0, 0, 0 };
    try testing.expectError(error.BadBson, (try Doc.init(&string_len)).validate());
}

test "db bson: decimal128 prints like the reference implementation" {
    const cases = [_]struct { u64, u64, []const u8 }{
        .{ 0x3040000000000000, 1, "1" },
        .{ 0x303C000000000000, 12345, "123.45" },
        .{ 0xB03C000000000000, 5, "-0.05" },
        .{ 0x3042000000000000, 12, "1.2E+2" },
        .{ 0x7C00000000000000, 0, "NaN" },
        .{ 0x7800000000000000, 0, "Infinity" },
        .{ 0x3024000000000000, 1, "1E-14" },
    };
    for (cases) |case| {
        var bytes: [16]u8 = undefined;
        std.mem.writeInt(u64, bytes[0..8], case[1], .little);
        std.mem.writeInt(u64, bytes[8..16], case[0], .little);
        var out: Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try writeDecimal128(&out.writer, &bytes);
        try testing.expectEqualStrings(case[2], out.written());
    }
}
