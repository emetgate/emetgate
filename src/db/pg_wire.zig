const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const protocol_version: u32 = 196608;
pub const ssl_request_code: u32 = 80877103;
pub const max_message_default = 32 * 1024 * 1024;

pub const Error = error{ ProtocolViolation, MessageTooLarge, NulInText };

pub const Message = struct {
    tag: u8,
    body: []const u8,
};

pub const Body = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn int32(self: *Body) Error!i32 {
        if (self.bytes.len - self.pos < 4) return error.ProtocolViolation;
        defer self.pos += 4;
        return std.mem.readInt(i32, self.bytes[self.pos..][0..4], .big);
    }

    pub fn int16(self: *Body) Error!i16 {
        if (self.bytes.len - self.pos < 2) return error.ProtocolViolation;
        defer self.pos += 2;
        return std.mem.readInt(i16, self.bytes[self.pos..][0..2], .big);
    }

    pub fn byte(self: *Body) Error!u8 {
        if (self.pos >= self.bytes.len) return error.ProtocolViolation;
        defer self.pos += 1;
        return self.bytes[self.pos];
    }

    pub fn cstr(self: *Body) Error![]const u8 {
        const end = std.mem.indexOfScalarPos(u8, self.bytes, self.pos, 0) orelse return error.ProtocolViolation;
        defer self.pos = end + 1;
        return self.bytes[self.pos..end];
    }

    pub fn take(self: *Body, n: usize) Error![]const u8 {
        if (self.bytes.len - self.pos < n) return error.ProtocolViolation;
        defer self.pos += n;
        return self.bytes[self.pos..][0..n];
    }

    pub fn rest(self: *Body) []const u8 {
        defer self.pos = self.bytes.len;
        return self.bytes[self.pos..];
    }
};

pub fn readMessage(r: *Io.Reader, gpa: Allocator, buf: *std.ArrayList(u8), max: usize) !Message {
    const head = try r.takeArray(5);
    const tag = head[0];
    const len = std.mem.readInt(u32, head[1..5], .big);
    if (len < 4) return error.ProtocolViolation;
    const body_len: usize = len - 4;
    if (body_len > max) {
        try r.discardAll(body_len);
        return error.MessageTooLarge;
    }
    buf.clearRetainingCapacity();
    try buf.resize(gpa, body_len);
    try r.readSliceAll(buf.items);
    return .{ .tag = tag, .body = buf.items };
}

fn noNul(text: []const u8) Error!void {
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.NulInText;
}

fn writeLength(w: *Io.Writer, len: usize) !void {
    try w.writeInt(u32, @intCast(len), .big);
}

pub const Param = struct { []const u8, []const u8 };

pub fn writeStartup(w: *Io.Writer, params: []const Param) !void {
    var len: usize = 4 + 4 + 1;
    for (params) |p| {
        try noNul(p[0]);
        try noNul(p[1]);
        len += p[0].len + 1 + p[1].len + 1;
    }
    try writeLength(w, len);
    try w.writeInt(u32, protocol_version, .big);
    for (params) |p| {
        try w.writeAll(p[0]);
        try w.writeByte(0);
        try w.writeAll(p[1]);
        try w.writeByte(0);
    }
    try w.writeByte(0);
}

pub fn writeSslRequest(w: *Io.Writer) !void {
    try writeLength(w, 8);
    try w.writeInt(u32, ssl_request_code, .big);
}

pub fn writePassword(w: *Io.Writer, password: []const u8) !void {
    try noNul(password);
    try w.writeByte('p');
    try writeLength(w, 4 + password.len + 1);
    try w.writeAll(password);
    try w.writeByte(0);
}

pub fn writeSaslInitial(w: *Io.Writer, mechanism: []const u8, data: []const u8) !void {
    try w.writeByte('p');
    try writeLength(w, 4 + mechanism.len + 1 + 4 + data.len);
    try w.writeAll(mechanism);
    try w.writeByte(0);
    try w.writeInt(i32, @intCast(data.len), .big);
    try w.writeAll(data);
}

pub fn writeSaslResponse(w: *Io.Writer, data: []const u8) !void {
    try w.writeByte('p');
    try writeLength(w, 4 + data.len);
    try w.writeAll(data);
}

pub fn writeQuery(w: *Io.Writer, sql: []const u8) !void {
    try noNul(sql);
    try w.writeByte('Q');
    try writeLength(w, 4 + sql.len + 1);
    try w.writeAll(sql);
    try w.writeByte(0);
}

pub fn writeParse(w: *Io.Writer, name: []const u8, sql: []const u8, param_types: []const u32) !void {
    try noNul(sql);
    try noNul(name);
    try w.writeByte('P');
    try writeLength(w, 4 + name.len + 1 + sql.len + 1 + 2 + 4 * param_types.len);
    try w.writeAll(name);
    try w.writeByte(0);
    try w.writeAll(sql);
    try w.writeByte(0);
    try w.writeInt(u16, @intCast(param_types.len), .big);
    for (param_types) |oid| try w.writeInt(u32, oid, .big);
}

pub fn writeBind(w: *Io.Writer, portal: []const u8, statement: []const u8, params: []const ?[]const u8) !void {
    var len: usize = 4 + portal.len + 1 + statement.len + 1 + 2 + 2 + 2;
    for (params) |p| len += 4 + if (p) |v| v.len else 0;
    try w.writeByte('B');
    try writeLength(w, len);
    try w.writeAll(portal);
    try w.writeByte(0);
    try w.writeAll(statement);
    try w.writeByte(0);
    try w.writeInt(u16, 0, .big);
    try w.writeInt(u16, @intCast(params.len), .big);
    for (params) |p| {
        if (p) |v| {
            try w.writeInt(i32, @intCast(v.len), .big);
            try w.writeAll(v);
        } else try w.writeInt(i32, -1, .big);
    }
    try w.writeInt(u16, 0, .big);
}

pub fn writeDescribe(w: *Io.Writer, kind: u8, name: []const u8) !void {
    try w.writeByte('D');
    try writeLength(w, 4 + 1 + name.len + 1);
    try w.writeByte(kind);
    try w.writeAll(name);
    try w.writeByte(0);
}

pub fn writeExecute(w: *Io.Writer, portal: []const u8, max_rows: u32) !void {
    try w.writeByte('E');
    try writeLength(w, 4 + portal.len + 1 + 4);
    try w.writeAll(portal);
    try w.writeByte(0);
    try w.writeInt(u32, max_rows, .big);
}

pub fn writeSync(w: *Io.Writer) !void {
    try w.writeByte('S');
    try writeLength(w, 4);
}

pub fn writeTerminate(w: *Io.Writer) !void {
    try w.writeByte('X');
    try writeLength(w, 4);
}

pub const ErrorFields = struct {
    severity: []const u8 = "",
    code: []const u8 = "",
    message: []const u8 = "",
    hint: []const u8 = "",
    position: []const u8 = "",
};

pub fn parseError(body: []const u8) ErrorFields {
    var fields: ErrorFields = .{};
    var b: Body = .{ .bytes = body };
    while (true) {
        const kind = b.byte() catch break;
        if (kind == 0) break;
        const value = b.cstr() catch break;
        switch (kind) {
            'V' => fields.severity = value,
            'S' => if (fields.severity.len == 0) {
                fields.severity = value;
            },
            'C' => fields.code = value,
            'M' => fields.message = value,
            'H' => fields.hint = value,
            'P' => fields.position = value,
            else => {},
        }
    }
    return fields;
}

pub const Field = struct {
    name: []const u8,
    table_oid: u32,
    column: i16,
    type_oid: u32,
};

pub fn parseRowDescription(arena: Allocator, body: []const u8) ![]Field {
    var b: Body = .{ .bytes = body };
    const n = try b.int16();
    if (n < 0) return error.ProtocolViolation;
    const fields = try arena.alloc(Field, @intCast(n));
    for (fields) |*f| {
        const name = try b.cstr();
        const table: u32 = @bitCast(try b.int32());
        const column = try b.int16();
        const type_oid: u32 = @bitCast(try b.int32());
        _ = try b.int16();
        _ = try b.int32();
        _ = try b.int16();
        f.* = .{ .name = try arena.dupe(u8, name), .table_oid = table, .column = column, .type_oid = type_oid };
    }
    return fields;
}

pub fn parseDataRow(body: []const u8, cells: []?[]const u8) Error!void {
    var b: Body = .{ .bytes = body };
    const n = try b.int16();
    if (n < 0 or @as(usize, @intCast(n)) != cells.len) return error.ProtocolViolation;
    for (cells) |*cell| {
        const len = try b.int32();
        cell.* = if (len < 0) null else try b.take(@intCast(len));
    }
}

pub fn commandRows(tag: []const u8) ?i64 {
    const text = std.mem.trimEnd(u8, tag, "\x00");
    const space = std.mem.lastIndexOfScalar(u8, text, ' ') orelse return null;
    const verb_end = std.mem.indexOfScalar(u8, text, ' ') orelse return null;
    const verb = text[0..verb_end];
    const known = [_][]const u8{ "INSERT", "UPDATE", "DELETE", "MERGE", "SELECT", "COPY", "MOVE", "FETCH" };
    for (known) |k| {
        if (std.mem.eql(u8, verb, k)) return std.fmt.parseInt(i64, text[space + 1 ..], 10) catch null;
    }
    return null;
}

pub const Auth = union(enum) {
    ok,
    cleartext,
    md5: [4]u8,
    sasl: []const u8,
    sasl_continue: []const u8,
    sasl_final: []const u8,
    other: i32,
};

pub fn parseAuth(body: []const u8) Error!Auth {
    var b: Body = .{ .bytes = body };
    const code = try b.int32();
    return switch (code) {
        0 => .ok,
        3 => .cleartext,
        5 => .{ .md5 = (try b.take(4))[0..4].* },
        10 => .{ .sasl = b.rest() },
        11 => .{ .sasl_continue = b.rest() },
        12 => .{ .sasl_final = b.rest() },
        else => .{ .other = code },
    };
}

pub fn saslOffers(list: []const u8, mechanism: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, 0);
    while (it.next()) |name| {
        if (std.mem.eql(u8, name, mechanism)) return true;
    }
    return false;
}

pub fn md5Password(out: *[35]u8, user: []const u8, password: []const u8, salt: [4]u8) void {
    const Md5 = std.crypto.hash.Md5;
    var inner: [16]u8 = undefined;
    var h = Md5.init(.{});
    h.update(password);
    h.update(user);
    h.final(&inner);
    const inner_hex = std.fmt.bytesToHex(inner, .lower);
    var outer: [16]u8 = undefined;
    var h2 = Md5.init(.{});
    h2.update(&inner_hex);
    h2.update(&salt);
    h2.final(&outer);
    out[0..3].* = "md5".*;
    out[3..].* = std.fmt.bytesToHex(outer, .lower);
}

pub fn quoteIdent(w: *Io.Writer, name: []const u8) Io.Writer.Error!void {
    try w.writeByte('"');
    for (name) |ch| {
        if (ch == '"') try w.writeByte('"');
        try w.writeByte(ch);
    }
    try w.writeByte('"');
}

pub fn decodeHexBytea(arena: Allocator, text: []const u8) !?[]u8 {
    if (!std.mem.startsWith(u8, text, "\\x")) return null;
    const hex = text[2..];
    if (hex.len % 2 != 0) return null;
    const out = try arena.alloc(u8, hex.len / 2);
    _ = std.fmt.hexToBytes(out, hex) catch return null;
    return out;
}

const testing = std.testing;

fn encoded(comptime f: anytype, args: anytype) ![]u8 {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try @call(.auto, f, .{&out.writer} ++ args);
    return out.toOwnedSlice();
}

test "pg wire: frontend messages carry their tag, a big-endian length that counts itself, and NUL-terminated text" {
    const startup = try encoded(writeStartup, .{&[_]Param{ .{ "user", "app" }, .{ "database", "db" } }});
    defer testing.allocator.free(startup);
    try testing.expectEqualSlices(u8, "\x00\x00\x00\x1e\x00\x03\x00\x00user\x00app\x00database\x00db\x00\x00", startup);
    const ssl = try encoded(writeSslRequest, .{});
    defer testing.allocator.free(ssl);
    try testing.expectEqualSlices(u8, "\x00\x00\x00\x08\x04\xd2\x16\x2f", ssl);
    const parse = try encoded(writeParse, .{ "", "SELECT 1", &[_]u32{} });
    defer testing.allocator.free(parse);
    try testing.expectEqualSlices(u8, "P\x00\x00\x00\x10\x00SELECT 1\x00\x00\x00", parse);
    const bind = try encoded(writeBind, .{ "", "", &[_]?[]const u8{ "ab", null } });
    defer testing.allocator.free(bind);
    try testing.expectEqualSlices(u8, "B\x00\x00\x00\x16\x00\x00\x00\x00\x00\x02\x00\x00\x00\x02ab\xff\xff\xff\xff\x00\x00", bind);
    const execute = try encoded(writeExecute, .{ "", 201 });
    defer testing.allocator.free(execute);
    try testing.expectEqualSlices(u8, "E\x00\x00\x00\x09\x00\x00\x00\x00\xc9", execute);
    const sasl = try encoded(writeSaslInitial, .{ "SCRAM-SHA-256", "n,,n=,r=x" });
    defer testing.allocator.free(sasl);
    try testing.expectEqualSlices(u8, "p\x00\x00\x00\x1fSCRAM-SHA-256\x00\x00\x00\x00\x09n,,n=,r=x", sasl);
    try testing.expectError(error.NulInText, encoded(writeQuery, .{"SELECT 1\x00; DROP TABLE t"}));
}

test "pg wire: backend messages decode, and a short or oversized message is a protocol error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const row_desc = "\x00\x02id\x00\x00\x00\x40\x01\x00\x01\x00\x00\x00\x17\x00\x04\xff\xff\xff\xff\x00\x00e\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x19\xff\xff\xff\xff\xff\xff\x00\x00";
    const fields = try parseRowDescription(arena, row_desc);
    try testing.expectEqual(@as(usize, 2), fields.len);
    try testing.expectEqualStrings("id", fields[0].name);
    try testing.expectEqual(@as(u32, 0x4001), fields[0].table_oid);
    try testing.expectEqual(@as(i16, 1), fields[0].column);
    try testing.expectEqual(@as(u32, 23), fields[0].type_oid);
    try testing.expectEqual(@as(u32, 0), fields[1].table_oid);
    var cells: [2]?[]const u8 = undefined;
    try parseDataRow("\x00\x02\x00\x00\x00\x017\xff\xff\xff\xff", &cells);
    try testing.expectEqualStrings("7", cells[0].?);
    try testing.expect(cells[1] == null);
    try testing.expectError(error.ProtocolViolation, parseDataRow("\x00\x02\x00\x00\x00\x09ab", &cells));
    try testing.expectError(error.ProtocolViolation, parseDataRow("\x00\x03", &cells));
    const fields_e = parseError("SERROR\x00VERROR\x00C57014\x00Mcanceling statement due to statement timeout\x00DFailing row contains (secret)\x00\x00");
    try testing.expectEqualStrings("57014", fields_e.code);
    try testing.expectEqualStrings("ERROR", fields_e.severity);
    try testing.expectEqualStrings("canceling statement due to statement timeout", fields_e.message);
    try testing.expectEqual(@as(?i64, 3), commandRows("UPDATE 3"));
    try testing.expectEqual(@as(?i64, 1), commandRows("INSERT 0 1"));
    try testing.expectEqual(@as(?i64, null), commandRows("CREATE TABLE"));
    try testing.expectEqual(Auth.ok, try parseAuth("\x00\x00\x00\x00"));
    try testing.expectEqualStrings("SCRAM-SHA-256\x00\x00", (try parseAuth("\x00\x00\x00\x0aSCRAM-SHA-256\x00\x00")).sasl);
    try testing.expect(saslOffers("SCRAM-SHA-256-PLUS\x00SCRAM-SHA-256\x00\x00", "SCRAM-SHA-256"));
    try testing.expect(!saslOffers("SCRAM-SHA-256-PLUS\x00\x00", "SCRAM-SHA-256"));
    var stream: Io.Reader = .fixed("Z\x00\x00\x00\x05I" ++ "D\x00\x00\x00\x02" ++ "D\xff\xff\xff\xff");
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const ready = try readMessage(&stream, testing.allocator, &buf, 1024);
    try testing.expectEqual(@as(u8, 'Z'), ready.tag);
    try testing.expectEqualStrings("I", ready.body);
    try testing.expectError(error.ProtocolViolation, readMessage(&stream, testing.allocator, &buf, 1024));
    var big: Io.Reader = .fixed("D\x00\x00\x01\x04" ++ "x" ** 256 ++ "Z\x00\x00\x00\x05I");
    try testing.expectError(error.MessageTooLarge, readMessage(&big, testing.allocator, &buf, 16));
    try testing.expectEqual(@as(u8, 'Z'), (try readMessage(&big, testing.allocator, &buf, 16)).tag);
    var md5: [35]u8 = undefined;
    md5Password(&md5, "postgres", "secret", .{ 1, 2, 3, 4 });
    try testing.expect(std.mem.startsWith(u8, &md5, "md5"));
    const bytes = (try decodeHexBytea(arena, "\\x00ff41")).?;
    try testing.expectEqualSlices(u8, "\x00\xffA", bytes);
}
