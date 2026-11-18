const std = @import("std");

pub const TokenKind = enum { ident, quoted, unicode, string, number, param, op, punct };

pub const Token = struct {
    kind: TokenKind,
    text: []const u8,
    start: usize,

    pub fn is(self: Token, kind: TokenKind, text: []const u8) bool {
        return self.kind == kind and std.mem.eql(u8, self.text, text);
    }

    pub fn word(self: Token, text: []const u8) bool {
        return self.kind == .ident and std.ascii.eqlIgnoreCase(self.text, text);
    }

    pub fn isName(self: Token) bool {
        return self.kind == .ident or self.kind == .quoted or self.kind == .unicode;
    }

    pub fn nameEquals(self: Token, name: []const u8) bool {
        switch (self.kind) {
            .ident => return std.ascii.eqlIgnoreCase(self.text, name),
            .quoted => {
                const inner = self.text[1 .. self.text.len - 1];
                var i: usize = 0;
                var j: usize = 0;
                while (i < inner.len) : (i += 1) {
                    if (j >= name.len) return false;
                    if (std.ascii.toLower(inner[i]) != std.ascii.toLower(name[j])) return false;
                    if (inner[i] == '"') i += 1;
                    j += 1;
                }
                return j == name.len;
            },
            else => return false,
        }
    }

    pub fn nameExact(self: Token, name: []const u8) bool {
        switch (self.kind) {
            .ident => return std.mem.eql(u8, self.text, name),
            .quoted => {
                const inner = self.text[1 .. self.text.len - 1];
                var i: usize = 0;
                var j: usize = 0;
                while (i < inner.len) : (i += 1) {
                    if (j >= name.len or inner[i] != name[j]) return false;
                    if (inner[i] == '"') i += 1;
                    j += 1;
                }
                return j == name.len;
            },
            else => return false,
        }
    }

    pub fn nameInto(self: Token, buf: []u8) ?[]const u8 {
        switch (self.kind) {
            .ident => {
                if (self.text.len > buf.len) return null;
                @memcpy(buf[0..self.text.len], self.text);
                return buf[0..self.text.len];
            },
            .quoted => {
                const inner = self.text[1 .. self.text.len - 1];
                var i: usize = 0;
                var j: usize = 0;
                while (i < inner.len) : (i += 1) {
                    if (j >= buf.len) return null;
                    buf[j] = inner[i];
                    if (inner[i] == '"') i += 1;
                    j += 1;
                }
                return buf[0..j];
            },
            else => return null,
        }
    }
};

pub const LexError = error{ UnterminatedText, UnterminatedComment };

const op_chars = "+-*/<>=~!@#%^&|`?";

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$' or c >= 0x80;
}

pub const Lexer = struct {
    src: []const u8,
    pos: usize = 0,

    pub fn init(src: []const u8) Lexer {
        return .{ .src = src };
    }

    fn skipSpace(self: *Lexer) LexError!void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == '\x0b' or c == '\x0c') {
                self.pos += 1;
                continue;
            }
            if (c == '-' and self.peekAt(1) == '-') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
                continue;
            }
            if (c == '/' and self.peekAt(1) == '*') {
                var depth: usize = 0;
                while (true) {
                    if (self.pos + 1 >= self.src.len) return error.UnterminatedComment;
                    if (self.src[self.pos] == '/' and self.src[self.pos + 1] == '*') {
                        depth += 1;
                        self.pos += 2;
                    } else if (self.src[self.pos] == '*' and self.src[self.pos + 1] == '/') {
                        depth -= 1;
                        self.pos += 2;
                        if (depth == 0) break;
                    } else self.pos += 1;
                }
                continue;
            }
            break;
        }
    }

    fn peekAt(self: *const Lexer, offset: usize) u8 {
        const i = self.pos + offset;
        return if (i < self.src.len) self.src[i] else 0;
    }

    fn quotedEnd(self: *const Lexer, from: usize, quote: u8, backslash: bool) LexError!usize {
        var i = from;
        while (i < self.src.len) {
            const c = self.src[i];
            if (backslash and c == '\\') {
                i += 2;
                continue;
            }
            if (c == quote) {
                if (i + 1 < self.src.len and self.src[i + 1] == quote) {
                    i += 2;
                    continue;
                }
                return i + 1;
            }
            i += 1;
        }
        return error.UnterminatedText;
    }

    fn dollarTag(self: *const Lexer) ?usize {
        var i = self.pos + 1;
        if (i < self.src.len and self.src[i] == '$') return i + 1;
        if (i >= self.src.len or !(std.ascii.isAlphabetic(self.src[i]) or self.src[i] == '_' or self.src[i] >= 0x80)) return null;
        while (i < self.src.len and (std.ascii.isAlphanumeric(self.src[i]) or self.src[i] == '_' or self.src[i] >= 0x80)) i += 1;
        if (i < self.src.len and self.src[i] == '$') return i + 1;
        return null;
    }

    pub fn next(self: *Lexer) LexError!?Token {
        try self.skipSpace();
        if (self.pos >= self.src.len) return null;
        const start = self.pos;
        const c = self.src[start];
        const make = struct {
            fn at(lexer: *Lexer, kind: TokenKind, from: usize, end: usize) Token {
                lexer.pos = end;
                return .{ .kind = kind, .text = lexer.src[from..end], .start = from };
            }
        }.at;
        if ((c == 'U' or c == 'u') and self.peekAt(1) == '&' and (self.peekAt(2) == '"' or self.peekAt(2) == '\'')) {
            const end = try self.quotedEnd(start + 3, self.peekAt(2), false);
            return make(self, .unicode, start, end);
        }
        if ((c == 'E' or c == 'e') and self.peekAt(1) == '\'') {
            return make(self, .string, start, try self.quotedEnd(start + 2, '\'', true));
        }
        if ((c == 'B' or c == 'b' or c == 'X' or c == 'x' or c == 'N' or c == 'n') and self.peekAt(1) == '\'') {
            return make(self, .string, start, try self.quotedEnd(start + 2, '\'', false));
        }
        if (c == '\'') return make(self, .string, start, try self.quotedEnd(start + 1, '\'', false));
        if (c == '"') return make(self, .quoted, start, try self.quotedEnd(start + 1, '"', false));
        if (c == '$') {
            if (std.ascii.isDigit(self.peekAt(1))) {
                var i = start + 1;
                while (i < self.src.len and std.ascii.isDigit(self.src[i])) i += 1;
                return make(self, .param, start, i);
            }
            if (self.dollarTag()) |body| {
                const tag = self.src[start..body];
                const close = std.mem.indexOfPos(u8, self.src, body, tag) orelse return error.UnterminatedText;
                return make(self, .string, start, close + tag.len);
            }
            return make(self, .punct, start, start + 1);
        }
        if (isIdentStart(c)) {
            var i = start + 1;
            while (i < self.src.len and isIdentChar(self.src[i])) i += 1;
            return make(self, .ident, start, i);
        }
        if (std.ascii.isDigit(c) or (c == '.' and std.ascii.isDigit(self.peekAt(1)))) {
            var i = start;
            while (i < self.src.len and (std.ascii.isAlphanumeric(self.src[i]) or self.src[i] == '.' or self.src[i] == '_')) {
                if ((self.src[i] == 'e' or self.src[i] == 'E') and i + 1 < self.src.len and (self.src[i + 1] == '+' or self.src[i + 1] == '-')) i += 1;
                if (self.src[i] == '.' and i + 1 < self.src.len and self.src[i + 1] == '.') break;
                i += 1;
            }
            return make(self, .number, start, i);
        }
        if (c == ':' and self.peekAt(1) == ':') return make(self, .punct, start, start + 2);
        if (std.mem.indexOfScalar(u8, op_chars, c) != null) {
            var i = start;
            while (i < self.src.len and std.mem.indexOfScalar(u8, op_chars, self.src[i]) != null) {
                if (i > start and ((self.src[i] == '-' and i + 1 < self.src.len and self.src[i + 1] == '-') or (self.src[i] == '/' and i + 1 < self.src.len and self.src[i + 1] == '*'))) break;
                i += 1;
            }
            return make(self, .op, start, i);
        }
        return make(self, .punct, start, start + 1);
    }
};

pub fn tokenize(arena: std.mem.Allocator, src: []const u8) (LexError || std.mem.Allocator.Error)![]Token {
    var list: std.ArrayList(Token) = .empty;
    var lexer = Lexer.init(src);
    while (try lexer.next()) |token| try list.append(arena, token);
    return list.items;
}

pub const Statement = enum {
    select,
    insert,
    update,
    delete,
    merge,
    create_table,
    create_table_as,
    create_view,
    create_matview,
    create_index,
    create_sequence,
    alter_table,
    alter_index,
    alter_view,
    alter_sequence,
    drop,
    truncate,
    comment,
    analyze,
    refresh_matview,
    denied,
    empty,
};

pub const Shape = struct {
    statement: Statement,
    targets: []const Name = &.{},
    rename: bool = false,
    query_start: ?usize = null,
    query_end: ?usize = null,
    leading: []const u8 = "",
};

pub const Name = struct {
    schema: ?[]const u8 = null,
    name: []const u8,
};

const Cursor = struct {
    tokens: []const Token,
    i: usize = 0,

    fn peek(self: *const Cursor) ?Token {
        return if (self.i < self.tokens.len) self.tokens[self.i] else null;
    }

    fn peekWord(self: *const Cursor, text: []const u8) bool {
        const token = self.peek() orelse return false;
        return token.word(text);
    }

    fn take(self: *Cursor, text: []const u8) bool {
        if (!self.peekWord(text)) return false;
        self.i += 1;
        return true;
    }

    fn takeAll(self: *Cursor, words: []const []const u8) bool {
        const saved = self.i;
        for (words) |w| {
            if (!self.take(w)) {
                self.i = saved;
                return false;
            }
        }
        return true;
    }

    fn name(self: *Cursor, arena: std.mem.Allocator) !?Name {
        const first = self.peek() orelse return null;
        if (!first.isName()) return null;
        self.i += 1;
        var parts: [3][]const u8 = undefined;
        var n: usize = 0;
        parts[n] = try unquote(arena, first);
        n += 1;
        while (self.peek()) |dot| {
            if (!dot.is(.punct, ".")) break;
            const after = if (self.i + 1 < self.tokens.len) self.tokens[self.i + 1] else break;
            if (!after.isName()) break;
            self.i += 2;
            if (n == parts.len) return null;
            parts[n] = try unquote(arena, after);
            n += 1;
        }
        return switch (n) {
            1 => .{ .name = parts[0] },
            2 => .{ .schema = parts[0], .name = parts[1] },
            else => .{ .schema = parts[n - 2], .name = parts[n - 1] },
        };
    }

    fn nameList(self: *Cursor, arena: std.mem.Allocator) ![]const Name {
        var list: std.ArrayList(Name) = .empty;
        while (true) {
            _ = self.take("only");
            const got = (try self.name(arena)) orelse break;
            try list.append(arena, got);
            if (self.peek()) |star| {
                if (star.is(.op, "*")) self.i += 1;
            }
            const comma = self.peek() orelse break;
            if (!comma.is(.punct, ",")) break;
            self.i += 1;
        }
        return list.items;
    }
};

pub fn unquote(arena: std.mem.Allocator, token: Token) ![]const u8 {
    if (token.kind != .quoted) return arena.dupe(u8, token.text);
    const buf = try arena.alloc(u8, token.text.len);
    return token.nameInto(buf) orelse token.text;
}

pub fn firstWord(tokens: []const Token) ?Token {
    for (tokens) |token| {
        if (token.is(.punct, "(")) continue;
        return token;
    }
    return null;
}

pub fn isQueryStart(token: Token) bool {
    return token.word("select") or token.word("with") or token.word("values") or token.word("table");
}

fn skipParens(tokens: []const Token, at: usize) usize {
    var depth: usize = 0;
    var i = at;
    while (i < tokens.len) : (i += 1) {
        if (tokens[i].is(.punct, "(")) depth += 1;
        if (tokens[i].is(.punct, ")")) {
            if (depth == 0) return i;
            depth -= 1;
            if (depth == 0) return i + 1;
        }
    }
    return i;
}

pub fn shape(arena: std.mem.Allocator, sql: []const u8, tokens: []const Token) !Shape {
    _ = sql;
    if (tokens.len == 0) return .{ .statement = .empty };
    var cur: Cursor = .{ .tokens = tokens };
    const head = firstWord(tokens) orelse return .{ .statement = .empty };
    if (head.word("select") or head.word("values") or head.word("table")) return .{ .statement = .select };
    if (head.word("with")) return .{ .statement = withBody(tokens) };
    if (head.word("insert")) return .{ .statement = .insert };
    if (head.word("update")) return .{ .statement = .update };
    if (head.word("delete")) return .{ .statement = .delete };
    if (head.word("merge")) return .{ .statement = .merge };
    if (cur.take("truncate")) {
        for (tokens) |token| {
            if (token.word("cascade")) return .{ .statement = .denied };
        }
        _ = cur.take("table");
        return .{ .statement = .truncate, .targets = try cur.nameList(arena) };
    }
    if (cur.take("analyze") or cur.take("analyse")) {
        _ = cur.take("verbose");
        return .{ .statement = .analyze, .targets = try cur.nameList(arena) };
    }
    if (cur.take("refresh")) {
        if (!cur.takeAll(&.{ "materialized", "view" })) return .{ .statement = .denied };
        _ = cur.take("concurrently");
        const target = (try cur.name(arena)) orelse return .{ .statement = .denied };
        return .{ .statement = .refresh_matview, .targets = try arena.dupe(Name, &.{target}) };
    }
    if (cur.take("comment")) {
        if (!cur.take("on")) return .{ .statement = .denied };
        if (cur.take("column")) {
            const target = (try cur.name(arena)) orelse return .{ .statement = .denied };
            const table: Name = .{ .name = target.schema orelse return .{ .statement = .denied } };
            return .{ .statement = .comment, .targets = try arena.dupe(Name, &.{table}) };
        }
        _ = cur.take("materialized");
        if (cur.take("table") or cur.take("view") or cur.take("index") or cur.take("sequence")) {
            const target = (try cur.name(arena)) orelse return .{ .statement = .denied };
            return .{ .statement = .comment, .targets = try arena.dupe(Name, &.{target}) };
        }
        return .{ .statement = .denied };
    }
    if (cur.take("drop")) {
        _ = cur.take("materialized");
        if (!(cur.take("table") or cur.take("view") or cur.take("index") or cur.take("sequence"))) return .{ .statement = .denied };
        _ = cur.take("concurrently");
        _ = cur.takeAll(&.{ "if", "exists" });
        return .{ .statement = .drop, .targets = try cur.nameList(arena) };
    }
    if (cur.take("alter")) {
        const what: Statement = if (cur.take("table")) .alter_table else if (cur.take("index")) .alter_index else if (cur.takeAll(&.{ "materialized", "view" }) or cur.take("view")) .alter_view else if (cur.take("sequence")) .alter_sequence else return .{ .statement = .denied };
        _ = cur.takeAll(&.{ "if", "exists" });
        _ = cur.take("only");
        const target = (try cur.name(arena)) orelse return .{ .statement = .denied };
        var renames = false;
        for (tokens[cur.i..]) |token| {
            if (token.word("rename") or token.word("detach") or token.word("inherit")) renames = true;
        }
        return .{ .statement = what, .targets = try arena.dupe(Name, &.{target}), .rename = renames };
    }
    if (cur.take("create")) {
        _ = cur.takeAll(&.{ "or", "replace" });
        _ = cur.take("global") or cur.take("local");
        _ = cur.take("temp") or cur.take("temporary") or cur.take("unlogged");
        _ = cur.take("recursive");
        if (cur.take("table")) {
            _ = cur.takeAll(&.{ "if", "not", "exists" });
            const target = (try cur.name(arena)) orelse return .{ .statement = .denied };
            var as_query = false;
            var depth: usize = 0;
            for (tokens[cur.i..]) |token| {
                if (token.is(.punct, "(")) depth += 1;
                if (token.is(.punct, ")") and depth > 0) depth -= 1;
                if (depth == 0 and token.word("as")) as_query = true;
            }
            return .{ .statement = if (as_query) .create_table_as else .create_table, .targets = try arena.dupe(Name, &.{target}) };
        }
        if (cur.takeAll(&.{ "materialized", "view" })) {
            _ = cur.takeAll(&.{ "if", "not", "exists" });
            const target = (try cur.name(arena)) orelse return .{ .statement = .denied };
            return .{ .statement = .create_matview, .targets = try arena.dupe(Name, &.{target}) };
        }
        if (cur.take("view")) {
            const target = (try cur.name(arena)) orelse return .{ .statement = .denied };
            var i = cur.i;
            if (i < tokens.len and tokens[i].is(.punct, "(")) i = skipParens(tokens, i);
            if (i < tokens.len and tokens[i].word("with") and i + 1 < tokens.len and tokens[i + 1].is(.punct, "(")) i = skipParens(tokens, i + 1);
            if (i >= tokens.len or !tokens[i].word("as") or i + 1 >= tokens.len) return .{ .statement = .denied };
            const body = i + 1;
            var end = tokens.len;
            if (end >= 3 and tokens[end - 1].word("option") and tokens[end - 2].word("check")) {
                end -= 2;
                if (end >= 1 and (tokens[end - 1].word("cascaded") or tokens[end - 1].word("local"))) end -= 1;
                if (end >= 1 and tokens[end - 1].word("with")) end -= 1 else return .{ .statement = .denied };
            }
            if (end <= body) return .{ .statement = .denied };
            const last = tokens[end - 1];
            return .{ .statement = .create_view, .targets = try arena.dupe(Name, &.{target}), .query_start = tokens[body].start, .query_end = last.start + last.text.len };
        }
        if (cur.take("sequence")) {
            _ = cur.takeAll(&.{ "if", "not", "exists" });
            const target = (try cur.name(arena)) orelse return .{ .statement = .denied };
            return .{ .statement = .create_sequence, .targets = try arena.dupe(Name, &.{target}) };
        }
        _ = cur.take("unique");
        if (cur.take("index")) {
            _ = cur.take("concurrently");
            _ = cur.takeAll(&.{ "if", "not", "exists" });
            if (!cur.peekWord("on")) _ = try cur.name(arena);
            if (!cur.take("on")) return .{ .statement = .denied };
            _ = cur.take("only");
            const target = (try cur.name(arena)) orelse return .{ .statement = .denied };
            return .{ .statement = .create_index, .targets = try arena.dupe(Name, &.{target}) };
        }
        return .{ .statement = .denied };
    }
    return .{ .statement = .denied };
}

fn withBody(tokens: []const Token) Statement {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        const token = tokens[i];
        if (token.is(.punct, "(")) {
            depth += 1;
            continue;
        }
        if (token.is(.punct, ")")) {
            if (depth > 0) depth -= 1;
            continue;
        }
        if (depth != 0 or i == 0) continue;
        if (token.word("select") or token.word("values") or token.word("table")) return .select;
        if (token.word("insert")) return .insert;
        if (token.word("update")) return .update;
        if (token.word("delete")) return .delete;
        if (token.word("merge")) return .merge;
    }
    return .select;
}

pub fn writesData(statement: Statement) bool {
    return switch (statement) {
        .insert, .update, .delete, .merge => true,
        else => false,
    };
}

pub fn hasUnicodeEscape(tokens: []const Token) bool {
    for (tokens) |token| {
        if (token.kind == .unicode) return true;
    }
    return false;
}

const testing = std.testing;

test "pg sql: the lexer skips comments, strings, dollar quotes and keeps quoted names whole" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const tokens = try tokenize(arena_state.allocator(), "SELECT \"Pass\"\"word\", 'a''b' -- x\n/* a /* nested */ b */ , $q$ ; $q$, E'\\'', $1, x::text, a<>b FROM t");
    try testing.expectEqual(@as(usize, 20), tokens.len);
    try testing.expect(tokens[1].nameExact("Pass\"word"));
    try testing.expect(tokens[1].nameEquals("pass\"WORD"));
    try testing.expectEqual(TokenKind.string, tokens[3].kind);
    try testing.expectEqualStrings("$q$ ; $q$", tokens[5].text);
    try testing.expectEqualStrings("E'\\''", tokens[7].text);
    try testing.expectEqual(TokenKind.param, tokens[9].kind);
    try testing.expect(tokens[12].is(.punct, "::"));
    try testing.expect(tokens[16].is(.op, "<>"));
    try testing.expectError(error.UnterminatedComment, tokenize(arena_state.allocator(), "SELECT /* open"));
    try testing.expectError(error.UnterminatedText, tokenize(arena_state.allocator(), "SELECT 'open"));
}

test "pg sql: a statement's shape names its kind and the tables it targets" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Case = struct { []const u8, Statement, []const u8 };
    for ([_]Case{
        .{ "SELECT 1", .select, "" },
        .{ "(SELECT 1)", .select, "" },
        .{ "WITH d AS (DELETE FROM a RETURNING *) SELECT * FROM d", .select, "" },
        .{ "WITH d AS (SELECT 1) DELETE FROM orders", .delete, "" },
        .{ "TRUNCATE TABLE ONLY public.orders, items", .truncate, "orders" },
        .{ "TRUNCATE users CASCADE", .denied, "" },
        .{ "DROP TABLE IF EXISTS \"Orders\" CASCADE", .drop, "Orders" },
        .{ "drop materialized view mv", .drop, "mv" },
        .{ "ALTER TABLE users RENAME TO people", .alter_table, "users" },
        .{ "CREATE TABLE copy AS SELECT 1", .create_table_as, "copy" },
        .{ "CREATE TEMP TABLE t (a int, b int CHECK (b > 0))", .create_table, "t" },
        .{ "CREATE UNIQUE INDEX CONCURRENTLY i ON ONLY s.orders (id)", .create_index, "orders" },
        .{ "CREATE INDEX ON orders (id)", .create_index, "orders" },
        .{ "CREATE OR REPLACE VIEW v (a) WITH (security_barrier) AS SELECT 1 WITH LOCAL CHECK OPTION", .create_view, "v" },
        .{ "CREATE FUNCTION f() RETURNS int AS 'select 1' LANGUAGE sql", .denied, "" },
        .{ "CREATE TRIGGER t AFTER INSERT ON orders EXECUTE FUNCTION f()", .denied, "" },
        .{ "COPY users TO STDOUT", .denied, "" },
        .{ "SET ROLE postgres", .denied, "" },
        .{ "DO $$ BEGIN END $$", .denied, "" },
        .{ "GRANT SELECT ON users TO public", .denied, "" },
        .{ "COMMENT ON COLUMN users.email IS 'x'", .comment, "users" },
        .{ "", .empty, "" },
    }) |case| {
        const tokens = try tokenize(arena, case[0]);
        const got = try shape(arena, case[0], tokens);
        try testing.expectEqual(case[1], got.statement);
        if (case[2].len != 0) try testing.expectEqualStrings(case[2], got.targets[0].name);
    }
    const view_sql = "CREATE VIEW v AS SELECT a FROM t WITH CHECK OPTION";
    const view = try shape(arena, view_sql, try tokenize(arena, view_sql));
    try testing.expectEqualStrings("SELECT a FROM t", view_sql[view.query_start.?..view.query_end.?]);
    const renamed = try shape(arena, "ALTER TABLE users RENAME COLUMN a TO b", try tokenize(arena, "ALTER TABLE users RENAME COLUMN a TO b"));
    try testing.expect(renamed.rename);
}
