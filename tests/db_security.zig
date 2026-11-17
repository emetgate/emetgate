const std = @import("std");
const c = @import("c");
const emetgate = @import("emetgate");
const sqlite = emetgate.db_sqlite;
const engine = emetgate.db_engine;
const render = emetgate.db_render;
const access = emetgate.db_access;

const testing = std.testing;

const fixture_sql =
    \\CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT, email TEXT, password_hash TEXT, ssn TEXT, lower_email TEXT GENERATED ALWAYS AS (lower(email)) VIRTUAL);
    \\INSERT INTO users(id, name, email, password_hash, ssn) VALUES (1, 'Alice', 'alice@example.com', 'HASH-A', '111-22-3333'), (2, 'Bob', 'bob@example.com', 'HASH-B', '444-55-6666'), (3, 'Carol', 'carol@example.com', 'HASH-C', '777-88-9999');
    \\CREATE TABLE secret(id INTEGER PRIMARY KEY, token TEXT);
    \\INSERT INTO secret VALUES (1, 'TOKEN-XYZ');
    \\CREATE TABLE orders(id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES users(id), total REAL);
    \\INSERT INTO orders VALUES (1, 1, 9.5), (2, 1, 20), (3, 2, 7.25);
    \\CREATE VIEW secret_view AS SELECT token FROM secret;
    \\CREATE VIEW user_hashes AS SELECT name, password_hash FROM users;
    \\CREATE VIEW user_emails AS SELECT name, lower(email) AS e FROM users;
    \\CREATE TABLE stamped(id INTEGER PRIMARY KEY, at TEXT DEFAULT CURRENT_TIMESTAMP, day TEXT DEFAULT (date('now')));
    \\INSERT INTO stamped(id) VALUES (1);
    \\CREATE TABLE big(n INTEGER);
    \\WITH RECURSIVE seq(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM seq WHERE x < 5000) INSERT INTO big SELECT x FROM seq;
;

const secrets = [_][]const u8{ "HASH-", "TOKEN-XYZ", "alice@", "bob@", "carol@", "111-22", "444-55", "777-88" };

const rules: access.Access = .{
    .hidden = &.{ .{ .table = "users", .column = "password_hash" }, .{ .table = "*", .column = "ssn" } },
    .masked = &.{.{ .table = "users", .column = "email", .mode = .email }},
    .blocked_tables = &.{"secret"},
};

const Db = struct {
    tmp: testing.TmpDir,
    path: []u8,

    fn init() !Db {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        defer testing.allocator.free(dir);
        const path = try std.fmt.allocPrint(testing.allocator, "{s}\\app.db", .{dir});
        errdefer testing.allocator.free(path);
        const path_z = try testing.allocator.dupeZ(u8, path);
        defer testing.allocator.free(path_z);
        var handle: ?*c.sqlite3 = null;
        try testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_open_v2(path_z.ptr, &handle, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null));
        defer _ = c.sqlite3_close_v2(handle);
        try testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_exec(handle, fixture_sql, null, null, null));
        return .{ .tmp = tmp, .path = path };
    }

    fn deinit(self: *Db) void {
        testing.allocator.free(self.path);
        self.tmp.cleanup();
    }

    fn open(self: *Db, mode: engine.Mode, limits: engine.Limits) !*sqlite.Conn {
        return self.openWith(mode, rules, limits);
    }

    fn openWith(self: *Db, mode: engine.Mode, given: access.Access, limits: engine.Limits) !*sqlite.Conn {
        var why: sqlite.OpenProblem = .{};
        return sqlite.open(testing.allocator, self.path, .{ .io = testing.io, .mode = mode, .access = given, .limits = limits }, &why);
    }
};

const Ran = struct {
    err: ?anyerror,
    text: []u8,
    rows: usize,
    more: bool,

    fn deinit(self: Ran) void {
        testing.allocator.free(self.text);
    }
};

fn query(conn: *sqlite.Conn, sql: []const u8) !Ran {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var rows: render.Rows = .init(testing.allocator, .json, conn.limits);
    defer rows.deinit();
    const outcome = conn.query(arena_state.allocator(), sql, rows.sink()) catch |err| {
        return .{ .err = err, .text = try testing.allocator.dupe(u8, conn.problem()), .rows = 0, .more = false };
    };
    return .{ .err = null, .text = try testing.allocator.dupe(u8, rows.written()), .rows = outcome.rows, .more = outcome.more };
}

fn expectNoLeak(text: []const u8) !void {
    for (secrets) |secret| {
        if (std.mem.indexOf(u8, text, secret) != null) {
            std.debug.print("leaked {s} in: {s}\n", .{ secret, text });
            return error.TestLeaked;
        }
    }
}

fn expectRefused(conn: *sqlite.Conn, sql: []const u8, want: anyerror) !void {
    const ran = try query(conn, sql);
    defer ran.deinit();
    try expectNoLeak(ran.text);
    if (ran.err) |err| {
        if (err == want) return;
        std.debug.print("{s}: wanted {t}, got {t}: {s}\n", .{ sql, want, err, ran.text });
        return error.TestWrongRefusal;
    }
    std.debug.print("{s}: wanted {t}, it ran: {s}\n", .{ sql, want, ran.text });
    return error.TestExpectedRefusal;
}

fn expectRuns(conn: *sqlite.Conn, sql: []const u8, contains: []const []const u8) !Ran {
    const ran = try query(conn, sql);
    errdefer ran.deinit();
    try expectNoLeak(ran.text);
    if (ran.err) |err| {
        std.debug.print("{s}: wanted rows, got {t}: {s}\n", .{ sql, err, ran.text });
        return error.TestUnexpectedRefusal;
    }
    for (contains) |part| {
        if (std.mem.indexOf(u8, ran.text, part) == null) {
            std.debug.print("{s}: wanted {s} in: {s}\n", .{ sql, part, ran.text });
            return error.TestExpectedText;
        }
    }
    return ran;
}

fn expectRunsClean(conn: *sqlite.Conn, sql: []const u8, contains: []const []const u8) !void {
    const ran = try expectRuns(conn, sql, contains);
    ran.deinit();
}

test "db security: an alias of a masked column still comes back masked" {
    var db = try Db.init();
    defer db.deinit();
    const conn = try db.open(.read, .{});
    defer conn.close();
    try expectRunsClean(conn, "SELECT email AS e FROM users ORDER BY id", &.{ "\"a***@example.com\"", "\"b***@example.com\"" });
    try expectRunsClean(conn, "SELECT x FROM (SELECT email AS x FROM users)", &.{"a***@example.com"});
    try expectRunsClean(conn, "WITH m AS (SELECT email FROM users) SELECT * FROM m", &.{"a***@example.com"});
    try expectRunsClean(conn, "SELECT DISTINCT email FROM users", &.{"c***@example.com"});
    try expectRunsClean(conn, "SELECT * FROM users", &.{"a***@example.com"});
    try expectRunsClean(conn, "SELECT (SELECT email FROM users ORDER BY id LIMIT 1) AS e", &.{"a***@example.com"});
}

test "db security: a masked column inside lower(), ||, CAST, an aggregate, WHERE, ORDER BY or a view expression is refused" {
    var db = try Db.init();
    defer db.deinit();
    const conn = try db.open(.read, .{});
    defer conn.close();
    for ([_][]const u8{
        "SELECT lower(email) FROM users",
        "SELECT email || '' FROM users",
        "SELECT '' || email AS email FROM users",
        "SELECT CAST(email AS BLOB) FROM users",
        "SELECT max(email) FROM users",
        "SELECT group_concat(email) FROM users",
        "SELECT substr(email, 1, 5) FROM (SELECT email FROM users)",
        "SELECT id FROM users WHERE email LIKE 'a%'",
        "SELECT email FROM users WHERE email = 'alice@example.com'",
        "SELECT id FROM users ORDER BY email",
        "SELECT name FROM users UNION ALL SELECT email FROM users",
        "SELECT e FROM user_emails",
        "SELECT json_object('e', email) FROM users",
        "SELECT instr(email, 'alice') FROM users",
        "SELECT users.id FROM users JOIN orders ON orders.user_id = length(users.email)",
    }) |sql| try expectRefused(conn, sql, error.MaskedColumnUsed);
}

test "db security: SELECT * and every path to a hidden column read it as NULL" {
    var db = try Db.init();
    defer db.deinit();
    const conn = try db.open(.read, .{});
    defer conn.close();
    try expectRunsClean(conn, "SELECT * FROM users ORDER BY id", &.{"[1,\"Alice\",\"a***@example.com\",null,null,null]"});
    try expectRunsClean(conn, "SELECT p FROM (SELECT password_hash AS p FROM users)", &.{"[null]"});
    try expectRunsClean(conn, "WITH h AS (SELECT password_hash FROM users) SELECT * FROM h", &.{"[null]"});
    try expectRunsClean(conn, "SELECT * FROM user_hashes", &.{"[\"Alice\",null]"});
    try expectRunsClean(conn, "SELECT count(*) FROM users WHERE password_hash LIKE 'HASH%'", &.{"[0]"});
    try expectRunsClean(conn, "SELECT count(*) FROM users WHERE substr(ssn, 1, 1) = '1'", &.{"[0]"});
    try expectRunsClean(conn, "SELECT hex(password_hash), json_object('h', password_hash), lower_email FROM users", &.{"[\"\",\"{\\\"h\\\":null}\",null]"});
    try expectRunsClean(conn, "SELECT u.password_hash FROM users u JOIN orders o ON o.user_id = u.id", &.{"[null]"});
    try expectRunsClean(conn, "SELECT ssn FROM users", &.{"[null]"});
}

test "db security: a blocked table is refused directly, by any spelling, through a view and through count(*)" {
    var db = try Db.init();
    defer db.deinit();
    const conn = try db.open(.read, .{});
    defer conn.close();
    for ([_][]const u8{
        "SELECT * FROM secret",
        "SELECT token FROM \"SeCrEt\"",
        "SELECT token FROM [secret]",
        "SELECT token FROM `secret`",
        "SELECT * FROM main.secret",
        "SELECT * FROM secret_view",
        "SELECT count(*) FROM secret",
        "SELECT rowid FROM secret",
        "SELECT (SELECT token FROM secret) AS t",
        "SELECT id FROM users WHERE EXISTS (SELECT 1 FROM secret WHERE token LIKE 'T%')",
    }) |sql| try expectRefused(conn, sql, error.TableRefused);
}

test "db security: ATTACH, VACUUM INTO, PRAGMA and the pragma table functions are refused on a read connection" {
    var db = try Db.init();
    defer db.deinit();
    const conn = try db.open(.read, .{});
    defer conn.close();
    try expectRefused(conn, "ATTACH DATABASE 'other.db' AS other", error.StatementNotRead);
    try expectRefused(conn, "DETACH DATABASE other", error.StatementNotRead);
    try expectRefused(conn, "PRAGMA query_only = 0", error.StatementNotRead);
    try expectRefused(conn, "PRAGMA writable_schema = 1", error.StatementNotRead);
    try expectRefused(conn, "PRAGMA table_info(secret)", error.StatementNotRead);
    const vacuum = try query(conn, "VACUUM INTO 'copy.db'");
    defer vacuum.deinit();
    try testing.expect(vacuum.err != null);
    try testing.expectError(error.FileNotFound, db.tmp.dir.access(testing.io, "copy.db", .{}));
    const vtab = try query(conn, "SELECT * FROM pragma_table_info('secret')");
    defer vtab.deinit();
    try testing.expect(vtab.err != null);
    const listed = try query(conn, "SELECT * FROM pragma_database_list");
    defer listed.deinit();
    try testing.expect(listed.err != null);
}

test "db security: load_extension and functions off the allowed list are refused" {
    var db = try Db.init();
    defer db.deinit();
    const conn = try db.open(.read, .{});
    defer conn.close();
    const loaded = try query(conn, "SELECT load_extension('evil.dll')");
    defer loaded.deinit();
    try testing.expect(loaded.err != null);
    const tokenizer = try query(conn, "SELECT fts3_tokenizer('simple')");
    defer tokenizer.deinit();
    try testing.expect(tokenizer.err != null);
    try expectRefused(conn, "SELECT sqlite_compileoption_get(0)", error.FunctionDenied);
    try expectRefused(conn, "SELECT total_changes()", error.FunctionDenied);
    try expectRunsClean(conn, "SELECT upper(name), abs(-2), json_array(1, 2), round(total, 1) FROM users JOIN orders ON orders.user_id = users.id ORDER BY orders.id LIMIT 1", &.{"[\"ALICE\",2,\"[1,2]\",9.5]"});
}

test "db security: only one statement runs; anything after the first is refused before it runs" {
    var db = try Db.init();
    defer db.deinit();
    const conn = try db.open(.read, .{});
    defer conn.close();
    try expectRefused(conn, "SELECT 1; DROP TABLE users", error.MultipleStatements);
    try expectRefused(conn, "SELECT 1; SELECT * FROM secret", error.MultipleStatements);
    try expectRefused(conn, "SELECT 1;;SELECT 2", error.MultipleStatements);
    try expectRefused(conn, "SELECT 1; /* c */ SELECT 2", error.MultipleStatements);
    try expectRunsClean(conn, "SELECT 1;", &.{"[1]"});
    try expectRunsClean(conn, "SELECT 2; -- trailing note", &.{"[2]"});
    try expectRunsClean(conn, "SELECT 3 /* inline */ ;  ", &.{"[3]"});
    try expectRefused(conn, "   ", error.EmptyStatement);
    try expectRefused(conn, "-- only a comment", error.EmptyStatement);
}

test "db security: a read connection refuses every write and DDL statement" {
    var db = try Db.init();
    defer db.deinit();
    const conn = try db.open(.read, .{});
    defer conn.close();
    for ([_][]const u8{
        "DELETE FROM orders",
        "UPDATE orders SET total = 0",
        "INSERT INTO orders(user_id, total) VALUES (1, 1)",
        "DROP TABLE orders",
        "CREATE TABLE x(a)",
        "CREATE TEMP TABLE x(a)",
        "ALTER TABLE orders ADD COLUMN note TEXT",
        "BEGIN",
        "SAVEPOINT s",
        "REINDEX",
        "ANALYZE",
        "WITH d AS (SELECT 1) DELETE FROM orders",
    }) |sql| try expectRefused(conn, sql, error.StatementNotRead);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.ActionDenied, conn.write(arena_state.allocator(), "DELETE FROM orders WHERE id = 1", .{ .destructive = true }));
    try testing.expectEqual(@as(i64, 3), try conn.count(arena_state.allocator(), "orders"));
}

fn pragmaValue(conn: *sqlite.Conn, sql: [:0]const u8) !i64 {
    var stmt: ?*c.sqlite3_stmt = null;
    try testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_prepare_v2(conn.db, sql.ptr, -1, &stmt, null));
    defer _ = c.sqlite3_finalize(stmt);
    try testing.expectEqual(@as(c_int, c.SQLITE_ROW), c.sqlite3_step(stmt));
    return c.sqlite3_column_int64(stmt, 0);
}

test "db security: a read connection is opened read-only with query_only on, and a write connection is not" {
    var db = try Db.init();
    defer db.deinit();
    const reader = try db.open(.read, .{});
    defer reader.close();
    try testing.expectEqual(@as(c_int, 1), c.sqlite3_db_readonly(reader.db, "main"));
    try testing.expectEqual(@as(i64, 1), try pragmaValue(reader, "PRAGMA query_only"));
    try testing.expectEqual(@as(i64, 0), try pragmaValue(reader, "SELECT count(*) FROM pragma_database_list WHERE name <> 'main'"));
    const writer = try db.open(.write, .{});
    defer writer.close();
    try testing.expectEqual(@as(c_int, 0), c.sqlite3_db_readonly(writer.db, "main"));
    try testing.expectEqual(@as(i64, 0), try pragmaValue(writer, "PRAGMA query_only"));
}

test "db security: hiding an INTEGER PRIMARY KEY hides rowid too, and a blocked view name refuses reads through that view" {
    var db = try Db.init();
    defer db.deinit();
    const conn = try db.openWith(.read, .{
        .hidden = &.{.{ .table = "orders", .column = "id" }},
        .blocked_tables = &.{"user_hashes"},
    }, .{});
    defer conn.close();
    const ran = try expectRuns(conn, "SELECT rowid, _rowid_, oid, id, total FROM orders ORDER BY total LIMIT 1", &.{"[null,null,null,null,7.25]"});
    ran.deinit();
    try expectRefused(conn, "SELECT * FROM user_hashes", error.TableRefused);
    try expectRefused(conn, "SELECT name FROM (SELECT * FROM user_hashes)", error.TableRefused);
    const allowed = try db.openWith(.read, .{ .allowed_tables = &.{"orders"} }, .{});
    defer allowed.close();
    try expectRefused(allowed, "SELECT name FROM users", error.TableRefused);
    try expectRefused(allowed, "SELECT name FROM sqlite_schema", error.TableRefused);
    try expectRunsClean(allowed, "SELECT count(*) FROM orders", &.{"[3]"});
}

test "db security: a table whose columns default to CURRENT_TIMESTAMP or date() reads with SELECT *" {
    var db = try Db.init();
    defer db.deinit();
    const conn = try db.open(.read, .{});
    defer conn.close();
    try expectRunsClean(conn, "SELECT * FROM stamped", &.{"[1,\""});
}

test "db security: an expensive query stops at the timeout" {
    var db = try Db.init();
    defer db.deinit();
    const conn = try db.open(.read, .{ .timeout_ms = 200 });
    defer conn.close();
    const started = std.Io.Timestamp.now(testing.io, .awake);
    try expectRefused(conn, "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c", error.QueryTimeout);
    try expectRefused(conn, "SELECT count(*) FROM big a, big b, big c", error.QueryTimeout);
    const took = started.durationTo(std.Io.Timestamp.now(testing.io, .awake)).toMilliseconds();
    try testing.expect(took < 10_000);
}

test "db security: the row cap holds even under LIMIT 1000000 and the reply says more rows exist" {
    var db = try Db.init();
    defer db.deinit();
    const conn = try db.open(.read, .{ .max_rows = 50 });
    defer conn.close();
    const ran = try expectRuns(conn, "SELECT n FROM big LIMIT 1000000", &.{"[50]"});
    defer ran.deinit();
    try testing.expectEqual(@as(usize, 50), ran.rows);
    try testing.expect(ran.more);
    try testing.expect(std.mem.indexOf(u8, ran.text, "[51]") == null);
    const exact = try expectRuns(conn, "SELECT n FROM big LIMIT 50", &.{"[50]"});
    defer exact.deinit();
    try testing.expect(!exact.more);
}

fn writeRefused(conn: *sqlite.Conn, sql: []const u8, permit: engine.Permit, want: anyerror) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    if (conn.write(arena_state.allocator(), sql, permit)) |outcome| {
        std.debug.print("{s}: wanted {t}, it wrote {d} rows\n", .{ sql, want, outcome.changes });
        return error.TestExpectedRefusal;
    } else |err| {
        try expectNoLeak(conn.problem());
        if (err != want) {
            std.debug.print("{s}: wanted {t}, got {t}: {s}\n", .{ sql, want, err, conn.problem() });
            return error.TestWrongRefusal;
        }
    }
}

fn written(conn: *sqlite.Conn, sql: []const u8, permit: engine.Permit) !engine.WriteOutcome {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const outcome = conn.write(arena_state.allocator(), sql, permit) catch |err| {
        std.debug.print("{s}: wanted a write, got {t}: {s}\n", .{ sql, err, conn.problem() });
        return err;
    };
    var copy = outcome;
    copy.table = null;
    return copy;
}

fn rowsOf(conn: *sqlite.Conn, table: []const u8) !i64 {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    return conn.count(arena_state.allocator(), table);
}

test "db security: with a plain write grant a destructive statement is refused and rolled back" {
    var db = try Db.init();
    defer db.deinit();
    const conn = try db.open(.write, .{});
    defer conn.close();
    const plain: engine.Permit = .{};
    try writeRefused(conn, "DELETE FROM orders", plain, error.DestructiveNotGranted);
    try writeRefused(conn, "DELETE FROM orders WHERE 1 = 1", plain, error.DestructiveNotGranted);
    try writeRefused(conn, "DELETE FROM orders WHERE id > 0", plain, error.DestructiveNotGranted);
    try writeRefused(conn, "UPDATE orders SET total = 0", plain, error.DestructiveNotGranted);
    try writeRefused(conn, "UPDATE orders SET total = total WHERE true", plain, error.DestructiveNotGranted);
    try writeRefused(conn, "DROP TABLE orders", plain, error.DestructiveNotGranted);
    try writeRefused(conn, "DROP VIEW user_emails", plain, error.DestructiveNotGranted);
    try writeRefused(conn, "ALTER TABLE orders DROP COLUMN total", plain, error.DestructiveNotGranted);
    try testing.expectEqual(@as(i64, 3), try rowsOf(conn, "orders"));
    const sum = try query(conn, "SELECT sum(total) FROM orders");
    defer sum.deinit();
    try testing.expectEqualStrings("[36.75]", sum.text);
    const one = try written(conn, "UPDATE orders SET total = 10 WHERE id = 1", plain);
    try testing.expectEqual(@as(i64, 1), one.changes);
    try testing.expectEqual(engine.WriteAction.update, one.action);
    try testing.expect(!one.destructive);
    const added = try written(conn, "INSERT INTO orders(user_id, total) VALUES (2, 3)", plain);
    try testing.expectEqual(@as(i64, 1), added.changes);
    const column = try written(conn, "ALTER TABLE orders ADD COLUMN note TEXT", plain);
    try testing.expectEqual(engine.WriteAction.alter, column.action);
    const removed = try written(conn, "DELETE FROM orders WHERE id = 2", plain);
    try testing.expectEqual(@as(i64, 1), removed.changes);
    try testing.expectEqual(@as(i64, 3), try rowsOf(conn, "orders"));
}

test "db security: a destructive grant lets the same statements run and says they were destructive" {
    var db = try Db.init();
    defer db.deinit();
    const conn = try db.open(.write, .{});
    defer conn.close();
    const full: engine.Permit = .{ .destructive = true };
    const cleared = try written(conn, "DELETE FROM orders", full);
    try testing.expect(cleared.destructive);
    try testing.expectEqual(@as(i64, 3), cleared.changes);
    try testing.expectEqual(@as(i64, 0), try rowsOf(conn, "orders"));
    const dropped = try written(conn, "DROP TABLE orders", full);
    try testing.expect(dropped.destructive);
    try testing.expectEqual(engine.WriteAction.drop, dropped.action);
}

test "db security: a write may not read or change hidden or masked columns, nor touch a blocked table" {
    var db = try Db.init();
    defer db.deinit();
    const conn = try db.open(.write, .{});
    defer conn.close();
    const full: engine.Permit = .{ .destructive = true };
    try writeRefused(conn, "INSERT INTO orders(user_id, total) SELECT id, length(email) FROM users", full, error.GuardedColumnInWrite);
    try writeRefused(conn, "UPDATE users SET name = password_hash WHERE id = 1", full, error.GuardedColumnInWrite);
    try writeRefused(conn, "UPDATE users SET password_hash = 'x' WHERE id = 1", full, error.GuardedColumnInWrite);
    try writeRefused(conn, "UPDATE users SET name = 'x' WHERE email = 'alice@example.com'", full, error.GuardedColumnInWrite);
    try writeRefused(conn, "CREATE TABLE copy AS SELECT email FROM users", full, error.GuardedColumnInWrite);
    try writeRefused(conn, "DELETE FROM secret WHERE id = 1", full, error.TableRefused);
    try writeRefused(conn, "INSERT INTO orders(user_id, total) SELECT id, 1 FROM secret", full, error.TableRefused);
    try writeRefused(conn, "DROP TABLE secret", full, error.TableRefused);
    try writeRefused(conn, "ATTACH DATABASE 'x.db' AS x", full, error.ActionDenied);
    try writeRefused(conn, "PRAGMA journal_mode = OFF", full, error.ActionDenied);
    try writeRefused(conn, "SELECT * FROM orders", full, error.StatementOnlyReads);
    try writeRefused(conn, "INSERT INTO orders(user_id, total) VALUES (1, 1); DELETE FROM users", full, error.MultipleStatements);
    try testing.expectEqual(@as(i64, 3), try rowsOf(conn, "orders"));
}

test "db security: tables and describe leave blocked tables out and label hidden and masked columns" {
    var db = try Db.init();
    defer db.deinit();
    const conn = try db.open(.read, .{});
    defer conn.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const listed = try conn.tables(arena);
    try testing.expectEqual(@as(usize, 1), listed.withheld);
    for (listed.shown) |table| try testing.expect(!std.ascii.eqlIgnoreCase(table.name, "secret"));
    try testing.expectError(error.TableRefused, conn.describe(arena, "SECRET"));
    try testing.expectError(error.TableNotFound, conn.describe(arena, "nope"));
    try testing.expectError(error.TableRefused, conn.count(arena, "secret"));
    const users = try conn.describe(arena, "Users");
    try testing.expectEqualStrings("users", users.table);
    var hidden: usize = 0;
    var masked: usize = 0;
    for (users.columns) |column| switch (column.treatment) {
        .hidden => hidden += 1,
        .masked => masked += 1,
        .plain => {},
    };
    try testing.expectEqual(@as(usize, 3), hidden);
    try testing.expectEqual(@as(usize, 1), masked);
    const orders = try conn.describe(arena, "orders");
    try testing.expectEqual(@as(usize, 1), orders.foreign_keys.len);
    const plan = try conn.explain(arena, "SELECT * FROM orders WHERE id = 1");
    try testing.expect(plan.len >= 1);
    try testing.expectError(error.TableRefused, conn.explain(arena, "SELECT * FROM secret"));
    try testing.expectError(error.StatementNotRead, conn.explain(arena, "DELETE FROM orders"));
}

test "db security: sample takes a table name, quotes it, and still applies the rules" {
    var db = try Db.init();
    defer db.deinit();
    const conn = try db.open(.read, .{});
    defer conn.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var rows: render.Rows = .init(testing.allocator, .json, conn.limits);
    defer rows.deinit();
    const outcome = try conn.sample(arena_state.allocator(), "users", 2, rows.sink());
    try testing.expectEqual(@as(usize, 2), outcome.rows);
    try testing.expect(outcome.more);
    try expectNoLeak(rows.written());
    var other: render.Rows = .init(testing.allocator, .json, conn.limits);
    defer other.deinit();
    try testing.expectError(error.TableRefused, conn.sample(arena_state.allocator(), "SECRET", 2, other.sink()));
    try testing.expectError(error.SqlFailed, conn.sample(arena_state.allocator(), "secret\" --", 2, other.sink()));
    try testing.expectError(error.SqlFailed, conn.sample(arena_state.allocator(), "users\"; DROP TABLE users; --", 2, other.sink()));
    try testing.expectEqual(@as(i64, 3), try conn.count(arena_state.allocator(), "users"));
}

test "db security: a missing file or a file that is not a database is refused at open" {
    var db = try Db.init();
    defer db.deinit();
    var why: sqlite.OpenProblem = .{};
    const missing = try std.fmt.allocPrint(testing.allocator, "{s}.missing", .{db.path});
    defer testing.allocator.free(missing);
    try testing.expectError(error.DatabaseUnavailable, sqlite.open(testing.allocator, missing, .{ .io = testing.io, .mode = .read, .access = .{}, .limits = .{} }, &why));
    try db.tmp.dir.writeFile(testing.io, .{ .sub_path = "junk.db", .data = "this is not sqlite at all, just text that is long enough" });
    const junk = try std.fmt.allocPrint(testing.allocator, "{s}\\..\\junk.db", .{db.path});
    defer testing.allocator.free(junk);
    try testing.expectError(error.DatabaseUnavailable, sqlite.open(testing.allocator, junk, .{ .io = testing.io, .mode = .read, .access = rules, .limits = .{} }, &why));
}
