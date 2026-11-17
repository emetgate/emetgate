const std = @import("std");

const Writer = std.Io.Writer;

pub const MaskMode = enum {
    partial,
    email,
    full,

    pub fn parse(text: []const u8) ?MaskMode {
        return std.meta.stringToEnum(MaskMode, text);
    }
};

pub const default_keep: u8 = 4;
pub const max_keep: u8 = 64;
pub const wildcard = "*";

pub const Column = struct {
    table: []const u8,
    column: []const u8,

    pub fn parse(text: []const u8) ?Column {
        const dot = std.mem.lastIndexOfScalar(u8, text, '.') orelse return null;
        const table = text[0..dot];
        const column = text[dot + 1 ..];
        if (!validName(table) or !validName(column)) return null;
        return .{ .table = table, .column = column };
    }

    pub fn matches(self: Column, table: []const u8, column: []const u8) bool {
        return nameMatches(self.table, table) and nameMatches(self.column, column);
    }

    pub fn format(self: Column, w: *Writer) Writer.Error!void {
        try w.print("{s}.{s}", .{ self.table, self.column });
    }
};

pub const Mask = struct {
    table: []const u8,
    column: []const u8,
    mode: MaskMode = .partial,
    keep: u8 = default_keep,

    pub fn of(self: Mask) Column {
        return .{ .table = self.table, .column = self.column };
    }
};

pub const Refusal = enum { blocked, not_allowed };

pub const Access = struct {
    hidden: []const Column = &.{},
    masked: []const Mask = &.{},
    allowed_tables: []const []const u8 = &.{},
    blocked_tables: []const []const u8 = &.{},

    pub fn tableRefusal(self: Access, table: []const u8) ?Refusal {
        for (self.blocked_tables) |blocked| {
            if (nameMatches(blocked, table)) return .blocked;
        }
        if (self.allowed_tables.len == 0) return null;
        for (self.allowed_tables) |allowed| {
            if (nameMatches(allowed, table)) return null;
        }
        return .not_allowed;
    }

    pub fn isBlocked(self: Access, table: []const u8) bool {
        for (self.blocked_tables) |blocked| {
            if (nameMatches(blocked, table)) return true;
        }
        return false;
    }

    pub fn isHidden(self: Access, table: []const u8, column: []const u8) bool {
        for (self.hidden) |hidden| {
            if (hidden.matches(table, column)) return true;
        }
        return false;
    }

    pub fn maskOf(self: Access, table: []const u8, column: []const u8) ?Mask {
        if (self.isHidden(table, column)) return null;
        for (self.masked) |mask| {
            if (mask.of().matches(table, column)) return mask;
        }
        return null;
    }

    pub fn guards(self: Access, table: []const u8) bool {
        for (self.hidden) |hidden| {
            if (nameMatches(hidden.table, table)) return true;
        }
        for (self.masked) |mask| {
            if (nameMatches(mask.table, table)) return true;
        }
        return false;
    }

    pub fn empty(self: Access) bool {
        return self.hidden.len == 0 and self.masked.len == 0 and self.allowed_tables.len == 0 and self.blocked_tables.len == 0;
    }
};

pub fn validName(text: []const u8) bool {
    if (text.len == 0 or text.len > 128) return false;
    if (std.mem.eql(u8, text, wildcard)) return true;
    for (text) |c| {
        if (c < 0x20 or c == '.' or c == '"' or c == '`' or c == '[' or c == ']' or c == 0x7f) return false;
    }
    return true;
}

pub fn nameMatches(pattern: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, pattern, wildcard)) return true;
    return std.ascii.eqlIgnoreCase(pattern, name);
}

pub fn writeMasked(w: *Writer, mask: Mask, text: []const u8) Writer.Error!void {
    switch (mask.mode) {
        .full => try w.writeAll("***"),
        .email => {
            const at = std.mem.lastIndexOfScalar(u8, text, '@') orelse return writePartial(w, text, mask.keep);
            if (at == 0) return writePartial(w, text, mask.keep);
            const first = charLen(text[0]);
            try w.writeAll(text[0..@min(first, at)]);
            try w.writeAll("***");
            try w.writeAll(text[at..]);
        },
        .partial => try writePartial(w, text, mask.keep),
    }
}

fn writePartial(w: *Writer, text: []const u8, keep: u8) Writer.Error!void {
    const chars = countChars(text);
    if (chars <= keep) {
        try w.splatByteAll('*', @max(chars, 3));
        return;
    }
    try w.splatByteAll('*', chars - keep);
    try w.writeAll(text[startOfLast(text, keep)..]);
}

fn charLen(lead: u8) usize {
    return std.unicode.utf8ByteSequenceLength(lead) catch 1;
}

fn countChars(text: []const u8) usize {
    var n: usize = 0;
    for (text) |c| {
        if ((c & 0xC0) != 0x80) n += 1;
    }
    return n;
}

fn startOfLast(text: []const u8, keep: usize) usize {
    var seen: usize = 0;
    var i = text.len;
    while (i > 0) {
        i -= 1;
        if ((text[i] & 0xC0) != 0x80) {
            seen += 1;
            if (seen == keep) return i;
        }
    }
    return 0;
}

const testing = std.testing;

fn masked(mask: Mask, text: []const u8) ![]u8 {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeMasked(&out.writer, mask, text);
    return out.toOwnedSlice();
}

test "db access: a mask keeps only what its mode allows" {
    const cases = [_]struct { Mask, []const u8, []const u8 }{
        .{ .{ .table = "u", .column = "e", .mode = .email }, "alice@example.com", "a***@example.com" },
        .{ .{ .table = "u", .column = "e", .mode = .email }, "not-an-email", "********mail" },
        .{ .{ .table = "u", .column = "e", .mode = .full }, "anything", "***" },
        .{ .{ .table = "u", .column = "e" }, "4111111111111111", "************1111" },
        .{ .{ .table = "u", .column = "e" }, "abc", "***" },
        .{ .{ .table = "u", .column = "e", .keep = 2 }, "\u{15f}\u{15f}\u{15f}\u{15f}", "**\u{15f}\u{15f}" },
        .{ .{ .table = "u", .column = "e", .mode = .email }, "\u{e7}a@b.c", "\u{e7}***@b.c" },
    };
    for (cases) |case| {
        const got = try masked(case[0], case[1]);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(case[2], got);
    }
}

test "db access: names match without case, a star matches any table, hidden wins over masked" {
    const access: Access = .{
        .hidden = &.{ .{ .table = "users", .column = "password_hash" }, .{ .table = "*", .column = "ssn" } },
        .masked = &.{ .{ .table = "Users", .column = "Email" }, .{ .table = "users", .column = "password_hash" } },
        .blocked_tables = &.{"secrets"},
    };
    try testing.expect(access.isHidden("USERS", "Password_Hash"));
    try testing.expect(access.isHidden("people", "SSN"));
    try testing.expect(access.maskOf("users", "email") != null);
    try testing.expect(access.maskOf("users", "password_hash") == null);
    try testing.expectEqual(Refusal.blocked, access.tableRefusal("SECRETS").?);
    try testing.expect(access.tableRefusal("users") == null);
    try testing.expect(access.guards("users"));
    try testing.expect(access.guards("orders"));
    try testing.expect(!(Access{ .hidden = &.{.{ .table = "users", .column = "x" }} }).guards("orders"));
    const allow: Access = .{ .allowed_tables = &.{"orders"} };
    try testing.expectEqual(Refusal.not_allowed, allow.tableRefusal("users").?);
    try testing.expect(allow.tableRefusal("ORDERS") == null);
}

test "db access: a column reference parses as table.column and refuses quotes and empty parts" {
    const col = Column.parse("users.email").?;
    try testing.expectEqualStrings("users", col.table);
    try testing.expectEqualStrings("email", col.column);
    try testing.expect(Column.parse("email") == null);
    try testing.expect(Column.parse(".email") == null);
    try testing.expect(Column.parse("users.") == null);
    try testing.expect(Column.parse("\"users\".email") == null);
    try testing.expect(Column.parse("*.ssn") != null);
}
