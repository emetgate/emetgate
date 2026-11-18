const std = @import("std");
const emetgate = @import("emetgate");
const postgres = emetgate.db_postgres;
const plan = emetgate.db_pg_plan;
const pg_sql = emetgate.db_pg_sql;
const engine = emetgate.db_engine;
const render = emetgate.db_render;
const access = emetgate.db_access;

const testing = std.testing;
const Allocator = std.mem.Allocator;

const fixture_db = "emetgate_fixture";
const reader_role = "emetgate_reader";
const writer_role = "emetgate_writer";
const role_password = "emetgate-Fixture-pw1";

const fixture_sql =
    \\CREATE TABLE users(id serial PRIMARY KEY, name text, email text, password_hash text, ssn text);
    \\INSERT INTO users(name, email, password_hash, ssn) VALUES ('Alice','alice@example.com','HASH-A','111-22-3333'),('Bob','bob@example.com','HASH-B','444-55-6666'),('Carol','carol@example.com','HASH-C','777-88-9999');
    \\CREATE TABLE secret(id int PRIMARY KEY, token text);
    \\INSERT INTO secret VALUES (1,'TOKEN-XYZ');
    \\CREATE TABLE orders(id serial PRIMARY KEY, user_id int REFERENCES users(id), total numeric, note text);
    \\INSERT INTO orders(user_id,total) VALUES (1,9.5),(1,20),(2,7.25);
    \\CREATE VIEW secret_view AS SELECT token FROM secret;
    \\CREATE VIEW user_hashes AS SELECT name, password_hash FROM users;
    \\CREATE VIEW user_emails AS SELECT name, lower(email) AS e FROM users;
    \\CREATE TABLE events(id int, at date, ssn text) PARTITION BY RANGE (at);
    \\CREATE TABLE events_2024 PARTITION OF events FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');
    \\CREATE TABLE events_2025 PARTITION OF events FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');
    \\INSERT INTO events VALUES (1,'2024-05-01','111-22-3333'),(2,'2025-05-01','444-55-6666');
    \\CREATE TABLE people_base(id int, name text, ssn text);
    \\CREATE TABLE staff(role text) INHERITS (people_base);
    \\INSERT INTO staff VALUES (1, 'Dan', '555-11-2222', 'admin');
    \\CREATE TABLE big(n int);
    \\INSERT INTO big SELECT generate_series(1, 5000);
    \\CREATE TABLE "Mixed"(id int, "Email" text);
    \\INSERT INTO "Mixed" VALUES (1, 'dan@example.com');
    \\CREATE MATERIALIZED VIEW order_totals AS SELECT user_id, sum(total) AS total FROM orders GROUP BY user_id;
    \\CREATE FUNCTION public.leak(int) RETURNS text LANGUAGE sql STABLE AS 'SELECT password_hash FROM users WHERE id = $1';
    \\CREATE FUNCTION public.upper(users) RETURNS text LANGUAGE sql STABLE AS 'SELECT $1.password_hash';
    \\CREATE FUNCTION public.peek(int, int) RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS 'BEGIN RETURN $1 = $2; END';
    \\CREATE OPERATOR public.=== (LEFTARG = int, RIGHTARG = int, FUNCTION = public.peek);
    \\GRANT SELECT ON ALL TABLES IN SCHEMA public TO emetgate_reader;
    \\GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA public TO emetgate_writer;
    \\GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO emetgate_writer;
    \\GRANT CREATE ON SCHEMA public TO emetgate_writer;
    \\ALTER TABLE orders OWNER TO emetgate_writer;
    \\ANALYZE;
;

const roles_sql =
    \\DO $$ BEGIN
    \\IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'emetgate_reader') THEN CREATE ROLE emetgate_reader LOGIN PASSWORD 'emetgate-Fixture-pw1'; END IF;
    \\IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'emetgate_writer') THEN CREATE ROLE emetgate_writer LOGIN PASSWORD 'emetgate-Fixture-pw1'; END IF;
    \\END $$;
;

const secrets = [_][]const u8{ "HASH-", "TOKEN-XYZ", "alice@", "bob@", "carol@", "111-22", "444-55", "777-88", "555-11" };

const rules: access.Access = .{
    .hidden = &.{ .{ .table = "users", .column = "password_hash" }, .{ .table = "*", .column = "ssn" } },
    .masked = &.{.{ .table = "users", .column = "email", .mode = .email }},
    .blocked_tables = &.{"secret"},
};

const Expect = union(enum) {
    refused: anyerror,
    runs: struct { shape: []const u8 = "", has: []const []const u8 = &.{} },
};

const Case = struct { sql: []const u8, expect: Expect };

fn runs(shape: []const u8, has: []const []const u8) Expect {
    return .{ .runs = .{ .shape = shape, .has = has } };
}

const read_cases = [_]Case{
    .{ .sql = "SELECT id, email FROM users ORDER BY id", .expect = runs("pm", &.{ "[1,\"a***@example.com\"]", "[2,\"b***@example.com\"]" }) },
    .{ .sql = "SELECT email AS e FROM users ORDER BY id", .expect = runs("m", &.{"\"a***@example.com\""}) },
    .{ .sql = "SELECT * FROM users ORDER BY id", .expect = runs("ppmhh", &.{"[1,\"Alice\",\"a***@example.com\",null,null]"}) },
    .{ .sql = "SELECT x FROM (SELECT email AS x FROM users) s", .expect = runs("m", &.{"a***@example.com"}) },
    .{ .sql = "WITH m AS (SELECT email FROM users) SELECT * FROM m", .expect = runs("m", &.{"a***@example.com"}) },
    .{ .sql = "WITH m AS MATERIALIZED (SELECT email FROM users) SELECT * FROM m", .expect = runs("m", &.{"a***@example.com"}) },
    .{ .sql = "SELECT p FROM (SELECT password_hash AS p FROM users OFFSET 0) s", .expect = runs("h", &.{"[null]"}) },
    .{ .sql = "SELECT s.id FROM (SELECT id, password_hash FROM users OFFSET 0) s ORDER BY 1", .expect = runs("p", &.{"[1]"}) },
    .{ .sql = "SELECT u.password_hash FROM users u JOIN orders o ON o.user_id = u.id", .expect = runs("h", &.{"[null]"}) },
    .{ .sql = "SELECT ssn FROM staff", .expect = runs("h", &.{"[null]"}) },
    .{ .sql = "SELECT * FROM people_base", .expect = runs("pph", &.{"[1,\"Dan\",null]"}) },
    .{ .sql = "SELECT * FROM events ORDER BY id", .expect = runs("pph", &.{"[1,\"2024-05-01\",null]"}) },
    .{ .sql = "SELECT e.ssn FROM events e WHERE e.id = 2", .expect = runs("h", &.{"[null]"}) },
    .{ .sql = "SELECT * FROM events WHERE at = '2024-05-01'", .expect = runs("pph", &.{"[1,\"2024-05-01\",null]"}) },
    .{ .sql = "SELECT name, upper(name) FROM users WHERE id = 1", .expect = .{ .refused = error.FunctionDenied } },
    .{ .sql = "SELECT name, lower(name), length(name) FROM users WHERE id = 1", .expect = runs("ppp", &.{"[\"Alice\",\"alice\",5]"}) },
    .{ .sql = "SELECT user_id, total FROM order_totals ORDER BY user_id", .expect = runs("pp", &.{"[1,29.5]"}) },
    .{ .sql = "SELECT \"Email\" FROM \"Mixed\"", .expect = runs("p", &.{"dan@example.com"}) },
    .{ .sql = "VALUES (1, 'x')", .expect = runs("pp", &.{"[1,\"x\"]"}) },
    .{ .sql = "SELECT count(*) FROM users u JOIN orders o ON o.user_id = u.id WHERE u.name LIKE 'A%'", .expect = runs("p", &.{"[2]"}) },
    .{ .sql = "SELECT g, n FROM generate_series(1, 2) g JOIN big ON big.n = g ORDER BY g", .expect = runs("pp", &.{"[1,1]"}) },
    .{ .sql = "SELECT row_number() OVER (ORDER BY id), name FROM users", .expect = runs("pp", &.{"[1,\"Alice\"]"}) },
    .{ .sql = "SELECT to_jsonb(o) FROM orders o WHERE id = 1", .expect = runs("p", &.{"user_id"}) },
    .{ .sql = "SELECT 1;", .expect = runs("p", &.{"[1]"}) },
    .{ .sql = "SELECT 2; -- trailing note", .expect = runs("p", &.{"[2]"}) },
    .{ .sql = "SELECT lower(email) FROM users", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT email || '' FROM users", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT id FROM users WHERE email LIKE 'a%'", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT id FROM users ORDER BY email", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT DISTINCT email FROM users", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT max(email) FROM users", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT string_agg(email, ',') FROM users", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT id FROM users WHERE password_hash LIKE 'HASH%'", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT count(*) FROM users GROUP BY password_hash", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT id FROM users WHERE length(password_hash) > 3", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT CASE WHEN password_hash LIKE 'H%' THEN 1 END FROM users", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT 1 / (CASE WHEN password_hash = 'HASH-A' THEN 0 ELSE 1 END) FROM users", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT u FROM users u", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT row_to_json(u) FROM users u", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT to_jsonb(u.*) FROM users u", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT json_agg(u) FROM users u", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT format('%s', u) FROM users u", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT concat(u.*) FROM users u", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT u::text FROM users u", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT ROW(u.*) FROM users u", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT jsonb_build_object('h', password_hash) FROM users", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT * FROM user_hashes", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT e FROM user_emails", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT lower(p) FROM (SELECT password_hash p FROM users OFFSET 0) s", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT p || '' FROM (SELECT email p FROM users OFFSET 0) s", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "WITH s AS MATERIALIZED (SELECT password_hash p FROM users) SELECT length(p) FROM s", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "WITH s AS MATERIALIZED (SELECT password_hash p FROM users) SELECT a.p, (SELECT b.p FROM s b LIMIT 1) FROM s a", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT (SELECT email FROM users ORDER BY id LIMIT 1) AS e", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT ARRAY(SELECT password_hash FROM users)", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT * FROM unnest(ARRAY(SELECT email FROM users)) x", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT name FROM users UNION ALL SELECT email FROM users", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT x FROM (SELECT email x FROM users UNION ALL SELECT name FROM users) s", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT password_hash FROM users INTERSECT SELECT 'HASH-A'", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "WITH RECURSIVE r AS (SELECT password_hash p, 1 n FROM users UNION ALL SELECT p, n + 1 FROM r WHERE n < 2) SELECT p FROM r", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT id FROM users WHERE id IN (SELECT id FROM users WHERE ssn LIKE '1%')", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT * FROM users NATURAL JOIN (SELECT 'HASH-A'::text AS password_hash) x", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT u.id FROM users u WHERE EXISTS (SELECT 1 FROM users v WHERE v.password_hash = u.password_hash AND v.id <> u.id)", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT row_number() OVER (ORDER BY email) FROM users", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT id FROM users ORDER BY ssn", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT ssn FROM events WHERE ssn > ''", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT id FROM events ORDER BY ssn", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT * FROM people_base WHERE ssn IS NOT NULL", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT array_agg(ssn) FROM staff", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT id FROM users u WHERE u.email = (SELECT min(v.email) FROM users v)", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT * FROM secret", .expect = .{ .refused = error.TableRefused } },
    .{ .sql = "SELECT token FROM \"secret\"", .expect = .{ .refused = error.TableRefused } },
    .{ .sql = "SELECT * FROM public.secret", .expect = .{ .refused = error.TableRefused } },
    .{ .sql = "TABLE secret", .expect = .{ .refused = error.TableRefused } },
    .{ .sql = "SELECT * FROM secret_view", .expect = .{ .refused = error.TableRefused } },
    .{ .sql = "SELECT count(*) FROM secret", .expect = .{ .refused = error.TableRefused } },
    .{ .sql = "SELECT (SELECT token FROM secret) AS t", .expect = .{ .refused = error.TableRefused } },
    .{ .sql = "SELECT id FROM users WHERE EXISTS (SELECT 1 FROM secret WHERE token LIKE 'T%')", .expect = .{ .refused = error.TableRefused } },
    .{ .sql = "SELECT * FROM pg_catalog.pg_stats", .expect = .{ .refused = error.TableRefused } },
    .{ .sql = "SELECT most_common_vals FROM pg_stats WHERE tablename = 'users'", .expect = .{ .refused = error.TableRefused } },
    .{ .sql = "SELECT * FROM information_schema.columns", .expect = .{ .refused = error.TableRefused } },
    .{ .sql = "SELECT relname FROM pg_class", .expect = .{ .refused = error.TableRefused } },
    .{ .sql = "SELECT pg_read_file('postgresql.conf')", .expect = .{ .refused = error.FunctionDenied } },
    .{ .sql = "SELECT query_to_xml('select * from users', true, true, '')", .expect = .{ .refused = error.FunctionDenied } },
    .{ .sql = "SELECT table_to_xml('users', true, true, '')", .expect = .{ .refused = error.FunctionDenied } },
    .{ .sql = "SELECT lo_get(1)", .expect = .{ .refused = error.FunctionDenied } },
    .{ .sql = "SELECT set_config('role', 'postgres', false)", .expect = .{ .refused = error.FunctionDenied } },
    .{ .sql = "SELECT current_setting('data_directory')", .expect = .{ .refused = error.FunctionDenied } },
    .{ .sql = "SELECT pg_sleep(1)", .expect = .{ .refused = error.FunctionDenied } },
    .{ .sql = "SELECT leak(1)", .expect = .{ .refused = error.FunctionDenied } },
    .{ .sql = "SELECT public.leak(1)", .expect = .{ .refused = error.FunctionDenied } },
    .{ .sql = "SELECT upper(u) FROM users u", .expect = .{ .refused = error.MaskedColumnUsed } },
    .{ .sql = "SELECT id FROM orders WHERE user_id === 1", .expect = .{ .refused = error.FunctionDenied } },
    .{ .sql = "SELECT id FROM orders WHERE user_id OPERATOR(public.===) 1", .expect = .{ .refused = error.FunctionDenied } },
    .{ .sql = "SELECT * FROM orders FOR UPDATE", .expect = .{ .refused = error.StatementNotRead } },
    .{ .sql = "WITH d AS (DELETE FROM orders RETURNING *) SELECT * FROM d", .expect = .{ .refused = error.StatementNotRead } },
};

const plain_cases = [_]Case{
    .{ .sql = "DELETE FROM orders", .expect = .{ .refused = error.StatementNotRead } },
    .{ .sql = "UPDATE orders SET total = 0", .expect = .{ .refused = error.StatementNotRead } },
    .{ .sql = "INSERT INTO orders(user_id, total) VALUES (1, 1)", .expect = .{ .refused = error.StatementNotRead } },
    .{ .sql = "DROP TABLE orders", .expect = .{ .refused = error.StatementNotRead } },
    .{ .sql = "CREATE TABLE x(a int)", .expect = .{ .refused = error.StatementNotRead } },
    .{ .sql = "COPY users TO STDOUT", .expect = .{ .refused = error.StatementNotRead } },
    .{ .sql = "COPY (SELECT * FROM users) TO STDOUT", .expect = .{ .refused = error.StatementNotRead } },
    .{ .sql = "SET ROLE postgres", .expect = .{ .refused = error.StatementNotRead } },
    .{ .sql = "SHOW data_directory", .expect = .{ .refused = error.StatementNotRead } },
    .{ .sql = "BEGIN", .expect = .{ .refused = error.StatementNotRead } },
    .{ .sql = "EXPLAIN ANALYZE SELECT 1", .expect = .{ .refused = error.StatementNotRead } },
    .{ .sql = "DO $$ BEGIN END $$", .expect = .{ .refused = error.StatementNotRead } },
    .{ .sql = "DECLARE c CURSOR FOR SELECT * FROM users", .expect = .{ .refused = error.StatementNotRead } },
    .{ .sql = "PREPARE p AS SELECT 1", .expect = .{ .refused = error.StatementNotRead } },
    .{ .sql = "SELECT * INTO copy FROM orders", .expect = .{ .refused = error.StatementNotRead } },
    .{ .sql = "SELECT 1; DROP TABLE users", .expect = .{ .refused = error.MultipleStatements } },
    .{ .sql = "SELECT 1; SELECT * FROM secret", .expect = .{ .refused = error.MultipleStatements } },
    .{ .sql = "SELECT 1;;SELECT 2", .expect = .{ .refused = error.MultipleStatements } },
    .{ .sql = "SELECT 1; /* c */ SELECT 2", .expect = .{ .refused = error.MultipleStatements } },
    .{ .sql = "   ", .expect = .{ .refused = error.EmptyStatement } },
    .{ .sql = "-- only a comment", .expect = .{ .refused = error.EmptyStatement } },
    .{ .sql = "SELECT $1", .expect = .{ .refused = error.SqlFailed } },
};

const write_cases = [_]Case{
    .{ .sql = "INSERT INTO orders(user_id, total) SELECT id, length(email) FROM users", .expect = .{ .refused = error.GuardedColumnInWrite } },
    .{ .sql = "UPDATE users SET name = password_hash WHERE id = 1", .expect = .{ .refused = error.GuardedColumnInWrite } },
    .{ .sql = "UPDATE users SET name = 'x' WHERE email = 'alice@example.com'", .expect = .{ .refused = error.GuardedColumnInWrite } },
    .{ .sql = "UPDATE users SET name = name WHERE id = 1 RETURNING password_hash", .expect = .{ .refused = error.GuardedColumnInWrite } },
    .{ .sql = "UPDATE orders SET note = (SELECT password_hash FROM users LIMIT 1)", .expect = .{ .refused = error.GuardedColumnInWrite } },
    .{ .sql = "INSERT INTO orders(user_id, total, note) SELECT id, 1, u::text FROM users u", .expect = .{ .refused = error.GuardedColumnInWrite } },
    .{ .sql = "DELETE FROM orders WHERE user_id IN (SELECT id FROM users WHERE ssn LIKE '1%')", .expect = .{ .refused = error.GuardedColumnInWrite } },
    .{ .sql = "CREATE TABLE copy AS SELECT email FROM users", .expect = .{ .refused = error.GuardedColumnInWrite } },
    .{ .sql = "CREATE TABLE copy AS SELECT * FROM users", .expect = .{ .refused = error.GuardedColumnInWrite } },
    .{ .sql = "CREATE MATERIALIZED VIEW mv AS SELECT password_hash FROM users", .expect = .{ .refused = error.GuardedColumnInWrite } },
    .{ .sql = "SELECT * INTO copy FROM users", .expect = .{ .refused = error.GuardedColumnInWrite } },
    .{ .sql = "INSERT INTO orders(user_id, total) SELECT id, 1 FROM secret", .expect = .{ .refused = error.TableRefused } },
    .{ .sql = "DELETE FROM secret WHERE id = 1", .expect = .{ .refused = error.TableRefused } },
    .{ .sql = "UPDATE orders SET note = leak(1) WHERE id = 1", .expect = .{ .refused = error.FunctionDenied } },
    .{ .sql = "INSERT INTO orders(user_id, total, note) VALUES (1, 1, pg_read_file('postgresql.conf'))", .expect = .{ .refused = error.FunctionDenied } },
    .{ .sql = "UPDATE orders SET note = 'x' WHERE id = 1", .expect = runs("", &.{}) },
    .{ .sql = "INSERT INTO orders(user_id, total) VALUES (2, 3)", .expect = runs("", &.{}) },
};

const Sinked = struct {
    err: ?anyerror,
    text: []u8,
    rows: usize,
    more: bool,
    shape: [16]u8 = undefined,
    shape_len: usize = 0,

    fn deinit(self: Sinked) void {
        testing.allocator.free(self.text);
    }
};

fn shapeOf(columns: []const engine.ResultColumn, out: *Sinked) void {
    for (columns, 0..) |column, i| {
        if (i >= out.shape.len) break;
        out.shape[i] = switch (column.treatment) {
            .plain => 'p',
            .hidden => 'h',
            .masked => 'm',
        };
        out.shape_len = i + 1;
    }
}

fn expectNoLeak(text: []const u8) !void {
    for (secrets) |secret| {
        if (std.mem.indexOf(u8, text, secret) != null) {
            std.debug.print("leaked {s} in: {s}\n", .{ secret, text });
            return error.TestLeaked;
        }
    }
}

fn checkVerdict(arena: Allocator, case: Case, evidence: plan.Evidence, mode: engine.Mode) !void {
    const verdict = try plan.decide(arena, evidence, rules, mode);
    switch (case.expect) {
        .refused => |want| switch (verdict) {
            .refused => |got| {
                try expectNoLeak(got.message);
                if (got.err != want) {
                    std.debug.print("{s}: wanted {t}, the plan check said {t}: {s}\n", .{ case.sql, want, got.err, got.message });
                    return error.TestWrongRefusal;
                }
            },
            .ok => {
                if (want == error.FunctionDenied or want == error.MaskedColumnUsed or want == error.TableRefused or want == error.GuardedColumnInWrite or want == error.StatementNotRead) {
                    std.debug.print("{s}: wanted {t}, the plan check let it run\n", .{ case.sql, want });
                    return error.TestExpectedRefusal;
                }
            },
        },
        .runs => |want| switch (verdict) {
            .refused => |got| {
                std.debug.print("{s}: wanted it to run, the plan check said {t}: {s}\n", .{ case.sql, got.err, got.message });
                return error.TestUnexpectedRefusal;
            },
            .ok => |approval| {
                if (want.shape.len == 0) return;
                var got: [16]u8 = undefined;
                for (approval.treatments, 0..) |how, i| got[i] = switch (how) {
                    .plain => 'p',
                    .hidden => 'h',
                    .masked => 'm',
                };
                if (!std.mem.eql(u8, want.shape, got[0..approval.treatments.len])) {
                    std.debug.print("{s}: wanted columns {s}, got {s}\n", .{ case.sql, want.shape, got[0..approval.treatments.len] });
                    return error.TestWrongTreatment;
                }
            },
        },
    }
}

const Recorded = struct {
    sql: []const u8,
    mode: engine.Mode,
    evidence: plan.Evidence,
};

const fixture_bytes = @embedFile("fixtures/pg_evidence.json");

fn loadFixtures(arena: Allocator) ![]const Recorded {
    return std.json.parseFromSliceLeaky([]const Recorded, arena, fixture_bytes, .{});
}

fn findRecorded(recorded: []const Recorded, sql: []const u8, mode: engine.Mode) ?Recorded {
    for (recorded) |r| {
        if (r.mode == mode and std.mem.eql(u8, r.sql, sql)) return r;
    }
    return null;
}

test "pg security: recorded plans of every read bypass are refused, and plain reads keep their hidden and masked columns" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const recorded = try loadFixtures(arena);
    var checked: usize = 0;
    for (read_cases) |case| {
        const r = findRecorded(recorded, case.sql, .read) orelse {
            std.debug.print("no recorded plan for: {s}\n", .{case.sql});
            return error.TestMissingFixture;
        };
        try checkVerdict(arena, case, r.evidence, .read);
        checked += 1;
    }
    try testing.expectEqual(read_cases.len, checked);
}

test "pg security: recorded plans of writes that read hidden, masked or blocked data or call unlisted functions are refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const recorded = try loadFixtures(arena);
    for (write_cases) |case| {
        const r = findRecorded(recorded, case.sql, .write) orelse {
            if (std.mem.startsWith(u8, case.sql, "CREATE TABLE") or std.mem.startsWith(u8, case.sql, "CREATE MATERIALIZED")) continue;
            std.debug.print("no recorded plan for: {s}\n", .{case.sql});
            return error.TestMissingFixture;
        };
        try checkVerdict(arena, case, r.evidence, .write);
    }
}

test "pg security: a write that names a hidden or masked column, or calls a server function, is refused from its text" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Text = struct { []const u8, ?anyerror };
    for ([_]Text{
        .{ "UPDATE users SET password_hash = 'x' WHERE id = 1", error.GuardedColumnInWrite },
        .{ "UPDATE users SET \"password_hash\" = 'x' WHERE id = 1", error.GuardedColumnInWrite },
        .{ "UPDATE people_base SET SSN = 'x'", error.GuardedColumnInWrite },
        .{ "ALTER TABLE users ADD COLUMN c text GENERATED ALWAYS AS (password_hash) STORED", error.GuardedColumnInWrite },
        .{ "ALTER TABLE users RENAME COLUMN password_hash TO pw", error.GuardedColumnInWrite },
        .{ "ALTER TABLE orders ADD FOREIGN KEY (note) REFERENCES users(email)", error.GuardedColumnInWrite },
        .{ "CREATE INDEX ON users (email)", error.GuardedColumnInWrite },
        .{ "COMMENT ON COLUMN users.password_hash IS 'x'", error.GuardedColumnInWrite },
        .{ "ALTER TABLE orders ADD COLUMN x text DEFAULT current_setting('data_directory')", error.FunctionDenied },
        .{ "ALTER TABLE orders ADD COLUMN x text DEFAULT pg_read_file('x')", error.FunctionDenied },
        .{ "ALTER TABLE orders ADD CONSTRAINT c CHECK (dblink_exec('x') = 'y')", error.FunctionDenied },
        .{ "ALTER TABLE orders ADD COLUMN x text", null },
        .{ "UPDATE orders SET note = 'email' WHERE id = 1", null },
        .{ "CREATE TABLE notes (id int, body text)", null },
    }) |case| {
        const tokens = try pg_sql.tokenize(arena, case[0]);
        const involved = try plan.involvedNames(arena, tokens, &.{});
        const got = try plan.ddlCheck(arena, tokens, rules, involved, &.{});
        if (case[1]) |want| {
            const refusal = got orelse {
                std.debug.print("{s}: wanted {t}, it passed\n", .{ case[0], want });
                return error.TestExpectedRefusal;
            };
            try testing.expectEqual(want, @as(anyerror, refusal.err));
        } else if (got) |refusal| {
            std.debug.print("{s}: wanted it to pass, got {s}\n", .{ case[0], refusal.message });
            return error.TestUnexpectedRefusal;
        }
    }
    const shadow_tokens = try pg_sql.tokenize(arena, "ALTER TABLE orders ADD COLUMN x text DEFAULT leak(1)");
    const shadow = try plan.ddlCheck(arena, shadow_tokens, rules, &.{"orders"}, &.{"leak"});
    try testing.expectEqual(@as(anyerror, error.FunctionDenied), @as(anyerror, shadow.?.err));
}

test "pg security: a plan the checker cannot read, an unknown plan step or a relation it was not told about is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Bad = struct { []const u8, anyerror };
    for ([_]Bad{
        .{ "not json", error.SqlFailed },
        .{ "[{\"Plan\": {\"Node Type\": \"Custom Scan\", \"Output\": [\"1\"]}}]", error.ActionDenied },
        .{ "[{\"Plan\": {\"Node Type\": \"Seq Scan\", \"Relation Name\": \"users\", \"Schema\": \"public\", \"Alias\": \"users\", \"Output\": [\"users.id\"]}}]", error.SqlFailed },
        .{ "[{\"Plan\": {\"Node Type\": \"Foreign Scan\", \"Output\": [\"x.a\"]}}]", error.ActionDenied },
        .{ "[{\"Plan\": {\"Node Type\": \"ModifyTable\", \"Operation\": \"Delete\", \"Relation Name\": \"orders\", \"Schema\": \"public\", \"Alias\": \"orders\"}}]", error.StatementNotRead },
    }) |case| {
        const verdict = try plan.decide(arena, .{ .plan = case[0], .relations = &.{.{ .schema = "public", .name = "orders", .chain = &.{"orders"} }} }, rules, .read);
        try testing.expect(verdict == .refused);
        try testing.expectEqual(case[1], @as(anyerror, verdict.refused.err));
    }
}

const net = emetgate.db_pg_net;
const wire = emetgate.db_pg_wire;
const scram = emetgate.db_pg_scram;

const fake_password = "fake-Pass-1";
const fake_plan =
    \\[{"Plan":{"Node Type":"Seq Scan","Relation Name":"users","Schema":"public","Alias":"users","Output":["id","email","password_hash"]}}]
;

const FakeServer = struct {
    listener: net.Listener,
    forge: bool = false,
    cleartext: bool = false,
    startup: [512]u8 = undefined,
    startup_len: usize = 0,
    seen_sql: std.ArrayList(u8) = .empty,
    failed: ?anyerror = null,
    read_buf: [8192]u8 = undefined,
    write_buf: [8192]u8 = undefined,
    sock: net.Socket = undefined,
    body: std.ArrayList(u8) = .empty,

    fn run(self: *FakeServer) void {
        self.serve() catch |err| {
            self.failed = err;
        };
        self.sock.close();
        self.body.deinit(testing.allocator);
    }

    fn send(self: *FakeServer, tag: u8, parts: []const []const u8) !void {
        var len: usize = 4;
        for (parts) |p| len += p.len;
        const w = &self.sock.writer;
        try w.writeByte(tag);
        try w.writeInt(u32, @intCast(len), .big);
        for (parts) |p| try w.writeAll(p);
    }

    fn int32(buf: *[4]u8, value: i32) []const u8 {
        std.mem.writeInt(i32, buf, value, .big);
        return buf;
    }

    fn int16(buf: *[2]u8, value: i16) []const u8 {
        std.mem.writeInt(i16, buf, value, .big);
        return buf;
    }

    fn ready(self: *FakeServer) !void {
        try self.send('Z', &.{"I"});
        try self.sock.writer.flush();
    }

    fn row(self: *FakeServer, cells: []const ?[]const u8) !void {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try out.writer.writeInt(i16, @intCast(cells.len), .big);
        for (cells) |c| {
            if (c) |v| {
                try out.writer.writeInt(i32, @intCast(v.len), .big);
                try out.writer.writeAll(v);
            } else try out.writer.writeInt(i32, -1, .big);
        }
        try self.send('D', &.{out.written()});
    }

    fn rowDescription(self: *FakeServer) !void {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try out.writer.writeInt(i16, 3, .big);
        const cols = [_]struct { []const u8, i16, u32 }{ .{ "id", 1, 23 }, .{ "email", 3, 25 }, .{ "password_hash", 4, 25 } };
        for (cols) |c| {
            try out.writer.writeAll(c[0]);
            try out.writer.writeByte(0);
            try out.writer.writeInt(u32, 16400, .big);
            try out.writer.writeInt(i16, c[1], .big);
            try out.writer.writeInt(u32, c[2], .big);
            try out.writer.writeInt(i16, -1, .big);
            try out.writer.writeInt(i32, -1, .big);
            try out.writer.writeInt(i16, 0, .big);
        }
        try self.send('T', &.{out.written()});
    }

    fn next(self: *FakeServer) !wire.Message {
        return wire.readMessage(&self.sock.reader, testing.allocator, &self.body, 1 << 20);
    }

    fn serve(self: *FakeServer) !void {
        const handle = try self.listener.accept();
        self.sock.init(handle, &self.read_buf, &self.write_buf, 10_000);
        const r = &self.sock.reader;
        var len = try r.takeInt(u32, .big);
        var code = try r.takeInt(u32, .big);
        if (code == wire.ssl_request_code) {
            try self.sock.writer.writeByte('N');
            try self.sock.writer.flush();
            len = try r.takeInt(u32, .big);
            code = try r.takeInt(u32, .big);
        }
        if (code != wire.protocol_version) return error.FakeBadStartup;
        self.startup_len = @min(len - 8, self.startup.len);
        try r.readSliceAll(self.startup[0..self.startup_len]);
        try r.discardAll(len - 8 - self.startup_len);
        var b4: [4]u8 = undefined;
        if (self.cleartext) {
            try self.send('R', &.{int32(&b4, 3)});
            try self.sock.writer.flush();
            _ = self.next() catch return;
            try self.send('R', &.{int32(&b4, 0)});
            try self.ready();
            return;
        }
        try self.send('R', &.{ int32(&b4, 10), "SCRAM-SHA-256\x00\x00" });
        try self.sock.writer.flush();
        const initial = try self.next();
        var body: wire.Body = .{ .bytes = initial.body };
        if (!std.mem.eql(u8, try body.cstr(), "SCRAM-SHA-256")) return error.FakeBadMechanism;
        _ = try body.int32();
        var first_buf: [256]u8 = undefined;
        const first = body.rest();
        @memcpy(first_buf[0..first.len], first);
        const first_bare = first_buf[3..first.len];
        const client_nonce = first_bare[std.mem.indexOf(u8, first_bare, "r=").? + 2 ..];
        var server_first_buf: [256]u8 = undefined;
        const server_first = try std.fmt.bufPrint(&server_first_buf, "r={s}fakeSERVERnonce,s=c2FsdHNhbHQ=,i=4096", .{client_nonce});
        try self.send('R', &.{ int32(&b4, 11), server_first });
        try self.sock.writer.flush();
        const final_msg = try self.next();
        const final = final_msg.body;
        const proof_at = std.mem.indexOf(u8, final, ",p=").?;
        var auth_buf: [1024]u8 = undefined;
        const auth = try std.fmt.bufPrint(&auth_buf, "{s},{s},{s}", .{ first_bare, server_first, final[0..proof_at] });
        const keys = scram.Keys.derive(fake_password, "saltsalt", 4096);
        const want_proof = scram.proofFor(keys, auth);
        var want_text: [64]u8 = undefined;
        const want_b64 = std.base64.standard.Encoder.encode(&want_text, &want_proof);
        if (!std.mem.eql(u8, want_b64, final[proof_at + 3 ..])) {
            try self.send('E', &.{"SFATAL\x00C28P01\x00Mpassword authentication failed\x00\x00"});
            try self.sock.writer.flush();
            return;
        }
        var sig = scram.serverSignature(keys, auth);
        if (self.forge) sig[0] ^= 1;
        var sig_text: [64]u8 = undefined;
        const sig_b64 = std.base64.standard.Encoder.encode(&sig_text, &sig);
        var server_final_buf: [128]u8 = undefined;
        try self.send('R', &.{ int32(&b4, 12), try std.fmt.bufPrint(&server_final_buf, "v={s}", .{sig_b64}) });
        try self.send('R', &.{int32(&b4, 0)});
        try self.send('S', &.{"server_version\x0016.99\x00"});
        try self.send('K', &.{ int32(&b4, 7), "\x00\x00\x00\x01" });
        try self.ready();
        var parse_sql: []u8 = &.{};
        defer testing.allocator.free(parse_sql);
        var param: []u8 = &.{};
        defer testing.allocator.free(param);
        var describe_portal = false;
        while (true) {
            const message = self.next() catch return;
            switch (message.tag) {
                'X' => return,
                'Q' => {
                    try self.seen_sql.appendSlice(testing.allocator, message.body);
                    try self.send('C', &.{"OK\x00"});
                    try self.ready();
                },
                'P' => {
                    var b: wire.Body = .{ .bytes = message.body };
                    _ = try b.cstr();
                    testing.allocator.free(parse_sql);
                    parse_sql = try testing.allocator.dupe(u8, try b.cstr());
                    try self.seen_sql.appendSlice(testing.allocator, parse_sql);
                    try self.seen_sql.append(testing.allocator, '\n');
                    try self.send('1', &.{});
                },
                'B' => {
                    var b: wire.Body = .{ .bytes = message.body };
                    _ = try b.cstr();
                    _ = try b.cstr();
                    _ = try b.int16();
                    const n = try b.int16();
                    testing.allocator.free(param);
                    param = &.{};
                    var i: i16 = 0;
                    while (i < n) : (i += 1) {
                        const plen = try b.int32();
                        const value = if (plen < 0) "" else try b.take(@intCast(plen));
                        if (i == n - 1) {
                            testing.allocator.free(param);
                            param = try testing.allocator.dupe(u8, value);
                        }
                    }
                    try self.send('2', &.{});
                },
                'D' => {
                    describe_portal = message.body[0] == 'P';
                    if (!describe_portal) {
                        var b2: [2]u8 = undefined;
                        try self.send('t', &.{int16(&b2, 0)});
                    }
                    if (std.mem.startsWith(u8, parse_sql, "SELECT id, email")) try self.rowDescription() else try self.send('n', &.{});
                },
                'E' => try self.answer(parse_sql, param),
                'S' => try self.ready(),
                else => {},
            }
        }
    }

    fn answer(self: *FakeServer, sql: []const u8, param: []const u8) !void {
        if (std.mem.startsWith(u8, sql, "EXPLAIN")) {
            try self.row(&.{fake_plan});
        } else if (std.mem.startsWith(u8, sql, "SELECT c.oid::text")) {
            try self.row(&.{"16400"});
        } else if (std.mem.startsWith(u8, sql, "WITH RECURSIVE up")) {
            try self.row(&.{ "public", "users" });
        } else if (std.mem.indexOf(u8, sql, "attnum > 0") != null and std.mem.startsWith(u8, sql, "SELECT attname")) {
            for ([_][]const u8{ "id", "email", "password_hash" }) |name| try self.row(&.{name});
        } else if (std.mem.startsWith(u8, sql, "SELECT attname")) {
            const name: []const u8 = if (std.mem.eql(u8, param, "1")) "id" else if (std.mem.eql(u8, param, "3")) "email" else "password_hash";
            try self.row(&.{name});
        } else if (std.mem.startsWith(u8, sql, "SELECT id, email")) {
            try self.row(&.{ "1", "alice@example.com", "HASH-A" });
            try self.row(&.{ "2", "bob@example.com", "HASH-B" });
        }
        try self.send('C', &.{"SELECT 1\x00"});
    }
};

fn fakeOpen(port: u16, password: []const u8, ssl: postgres.SslMode, why: *postgres.OpenProblem) !*postgres.Conn {
    return fakeOpenWith(port, password, ssl, .{}, why);
}

fn fakeOpenWith(port: u16, password: []const u8, ssl: postgres.SslMode, limits: engine.Limits, why: *postgres.OpenProblem) !*postgres.Conn {
    const target: postgres.Target = .{ .host = "127.0.0.1", .port = port, .database = "app", .user = "agent", .password = password, .sslmode = ssl };
    return postgres.open(testing.allocator, target, .{ .io = testing.io, .mode = .read, .access = rules, .limits = limits }, why);
}

test "pg fake server: SCRAM login, the checked read and the masking all run over the wire with no real PostgreSQL" {
    var server: FakeServer = .{ .listener = try net.Listener.open() };
    defer server.listener.close();
    defer server.seen_sql.deinit(testing.allocator);
    const thread = try std.Thread.spawn(.{}, FakeServer.run, .{&server});
    var why: postgres.OpenProblem = .{};
    const conn = fakeOpen(server.listener.port, fake_password, .prefer, &why) catch |err| {
        std.debug.print("open: {s}\n", .{why.text()});
        thread.join();
        return err;
    };
    try testing.expect(!conn.encrypted);
    try testing.expectEqualStrings("16.99", conn.version());
    const ran = try liveQuery(conn, "SELECT id, email, password_hash FROM users");
    defer ran.deinit();
    conn.close();
    thread.join();
    if (server.failed) |err| return err;
    try testing.expect(ran.err == null);
    try testing.expectEqualStrings("[1,\"a***@example.com\",null],[2,\"b***@example.com\",null]", ran.text);
    try testing.expectEqualStrings("pmh", ran.shape[0..ran.shape_len]);
    const seen = server.seen_sql.items;
    try testing.expect(std.mem.indexOf(u8, seen, "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY") != null);
    try testing.expect(std.mem.indexOf(u8, seen, "SET LOCAL statement_timeout = 5000") != null);
    try testing.expect(std.mem.indexOf(u8, seen, "EXPLAIN (VERBOSE, FORMAT JSON) SELECT id, email, password_hash FROM users") != null);
    try testing.expect(std.mem.indexOf(u8, seen, "ROLLBACK") != null);
    const startup = server.startup[0..server.startup_len];
    try testing.expect(std.mem.indexOf(u8, startup, "default_transaction_read_only\x00on\x00") != null);
    try testing.expect(std.mem.indexOf(u8, startup, "statement_timeout\x005000\x00") != null);
}

test "pg fake server: the row cap holds on the wire and the reply says more rows exist" {
    var server: FakeServer = .{ .listener = try net.Listener.open() };
    defer server.listener.close();
    defer server.seen_sql.deinit(testing.allocator);
    const thread = try std.Thread.spawn(.{}, FakeServer.run, .{&server});
    var why: postgres.OpenProblem = .{};
    const conn = fakeOpenWith(server.listener.port, fake_password, .disable, .{ .max_rows = 1 }, &why) catch |err| {
        thread.join();
        return err;
    };
    const ran = try liveQuery(conn, "SELECT id, email, password_hash FROM users");
    defer ran.deinit();
    conn.close();
    thread.join();
    try testing.expectEqual(@as(usize, 1), ran.rows);
    try testing.expect(ran.more);
    try testing.expectEqualStrings("[1,\"a***@example.com\",null]", ran.text);
}

test "pg fake server: a clear-text password request over an unencrypted connection is refused" {
    var server: FakeServer = .{ .listener = try net.Listener.open(), .cleartext = true };
    defer server.listener.close();
    defer server.seen_sql.deinit(testing.allocator);
    const thread = try std.Thread.spawn(.{}, FakeServer.run, .{&server});
    var why: postgres.OpenProblem = .{};
    const got = fakeOpen(server.listener.port, fake_password, .disable, &why);
    if (got) |conn| conn.close() else |_| {}
    thread.join();
    try testing.expectError(error.DatabaseUnavailable, got);
    try testing.expect(std.mem.indexOf(u8, why.text(), "clear text") != null);
}

test "pg fake server: a wrong password and a server that cannot prove the password are both refused" {
    for ([_]struct { []const u8, bool, []const u8 }{
        .{ "wrong", false, "28P01" },
        .{ fake_password, true, "SCRAM server signature mismatch" },
    }) |case| {
        var server: FakeServer = .{ .listener = try net.Listener.open(), .forge = case[1] };
        defer server.listener.close();
        defer server.seen_sql.deinit(testing.allocator);
        const thread = try std.Thread.spawn(.{}, FakeServer.run, .{&server});
        var why: postgres.OpenProblem = .{};
        const got = fakeOpen(server.listener.port, case[0], .disable, &why);
        if (got) |conn| conn.close() else |_| {}
        thread.join();
        try testing.expectError(error.DatabaseUnavailable, got);
        try testing.expect(std.mem.indexOf(u8, why.text(), case[2]) != null);
    }
    var server: FakeServer = .{ .listener = try net.Listener.open() };
    defer server.listener.close();
    defer server.seen_sql.deinit(testing.allocator);
    const thread = try std.Thread.spawn(.{}, FakeServer.run, .{&server});
    var why: postgres.OpenProblem = .{};
    const got = fakeOpen(server.listener.port, fake_password, .require, &why);
    if (got) |conn| conn.close() else |_| {}
    thread.join();
    try testing.expectError(error.DatabaseUnavailable, got);
    try testing.expect(std.mem.indexOf(u8, why.text(), "does not accept TLS") != null);
}

test "pg tool: emetgate db add seals a postgres URL, and emetgate_db reads through it with the rules applied" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const db_command = emetgate.db_command;
    const db_config = emetgate.db_config;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "repo/.emetgate");
    try tmp.dir.createDirPath(testing.io, "state");
    const root = try tmp.dir.realPathFileAlloc(testing.io, "repo", testing.allocator);
    defer testing.allocator.free(root);
    const state = try tmp.dir.realPathFileAlloc(testing.io, "state", testing.allocator);
    defer testing.allocator.free(state);
    db_config.global_dir_override = state;
    defer db_config.global_dir_override = null;
    var server: FakeServer = .{ .listener = try net.Listener.open() };
    defer server.listener.close();
    defer server.seen_sql.deinit(testing.allocator);
    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrintZ(&url_buf, "postgres://agent@127.0.0.1:{d}/app?sslmode=disable", .{server.listener.port});
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer err_out.deinit();
    db_command.env_password = fake_password;
    defer db_command.env_password = null;
    const steps = [_][]const [:0]const u8{
        &.{ "add", "pg", url },
        &.{ "hide", "pg", "users.password_hash" },
        &.{ "mask", "pg", "users.email", "--mode", "email" },
    };
    for (steps) |args| {
        const request = db_command.parse(args).?;
        const code = try db_command.run(testing.allocator, testing.io, root, request, &out.writer, &err_out.writer);
        if (code != 0) std.debug.print("{s}\n", .{err_out.written()});
        try testing.expectEqual(@as(u8, 0), code);
    }
    const saved = try tmp.dir.readFileAlloc(testing.io, "repo/.emetgate/db.json", testing.allocator, .unlimited);
    defer testing.allocator.free(saved);
    try testing.expect(std.mem.indexOf(u8, saved, fake_password) == null);
    try testing.expect(std.mem.indexOf(u8, saved, "\"engine\": \"postgres\"") != null);
    const thread = try std.Thread.spawn(.{}, FakeServer.run, .{&server});
    var session: emetgate.db_tool.Session = .init(testing.allocator, null);
    defer session.deinit();
    const line = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"emetgate_db\",\"arguments\":{\"db\":\"pg\",\"sql\":\"SELECT id, email, password_hash FROM users\"}}}";
    var reply: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reply.deinit();
    _ = try emetgate.server.handleMessageObserved(testing.allocator, testing.io, undefined, line, &reply.writer, null, .{ .root = root, .db_session = &session });
    thread.join();
    if (server.failed) |err| return err;
    try expectNoLeak(reply.written());
    try testing.expect(std.mem.indexOf(u8, reply.written(), "a***@example.com") != null);
    try testing.expect(std.mem.indexOf(u8, reply.written(), "users.password_hash") != null);
}

const Live = struct {
    admin: postgres.Target,
    arena_state: std.heap.ArenaAllocator,

    fn init() !?Live {
        var env = try testing.environ.createMap(testing.allocator);
        defer env.deinit();
        const url = env.get("EMETGATE_PG_URL") orelse return null;
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer arena_state.deinit();
        const admin = try postgres.parseUrl(arena_state.allocator(), try arena_state.allocator().dupe(u8, url));
        return .{ .admin = admin, .arena_state = arena_state };
    }

    fn deinit(self: *Live) void {
        self.arena_state.deinit();
    }

    fn open(self: *Live, target: postgres.Target, mode: engine.Mode, given: access.Access, limits: engine.Limits) !*postgres.Conn {
        _ = self;
        var why: postgres.OpenProblem = .{};
        return postgres.open(testing.allocator, target, .{ .io = testing.io, .mode = mode, .access = given, .limits = limits }, &why) catch |err| {
            std.debug.print("open failed: {s}\n", .{why.text()});
            return err;
        };
    }

    fn reset(self: *Live) !void {
        const admin = try self.open(self.admin, .write, .{}, .{ .timeout_ms = 60_000 });
        defer admin.close();
        try admin.simple(roles_sql);
        try admin.simple("DROP DATABASE IF EXISTS " ++ fixture_db ++ " WITH (FORCE)");
        try admin.simple("CREATE DATABASE " ++ fixture_db);
        var target = self.admin;
        target.database = fixture_db;
        const setup = try self.open(target, .write, .{}, .{ .timeout_ms = 60_000 });
        defer setup.close();
        try setup.simple(fixture_sql);
    }

    fn as(self: *Live, role: []const u8) postgres.Target {
        var target = self.admin;
        target.database = fixture_db;
        target.user = role;
        target.password = role_password;
        return target;
    }
};

fn liveQuery(conn: *postgres.Conn, sql: []const u8) !Sinked {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var rows: render.Rows = .init(testing.allocator, .json, conn.limits);
    defer rows.deinit();
    const outcome = conn.query(arena_state.allocator(), sql, rows.sink()) catch |err| {
        return .{ .err = err, .text = try testing.allocator.dupe(u8, conn.problem()), .rows = 0, .more = false };
    };
    var out: Sinked = .{ .err = null, .text = try testing.allocator.dupe(u8, rows.written()), .rows = outcome.rows, .more = outcome.more };
    shapeOf(rows.columns, &out);
    return out;
}

fn liveCheck(conn: *postgres.Conn, case: Case, server_may_refuse: bool) !void {
    const ran = try liveQuery(conn, case.sql);
    defer ran.deinit();
    try expectNoLeak(ran.text);
    switch (case.expect) {
        .refused => |want| {
            const err = ran.err orelse {
                std.debug.print("{s}: wanted {t}, it ran: {s}\n", .{ case.sql, want, ran.text });
                return error.TestExpectedRefusal;
            };
            if (server_may_refuse and err == error.SqlFailed and std.mem.indexOf(u8, ran.text, "permission denied") != null) return;
            if (err != want) {
                std.debug.print("{s}: wanted {t}, got {t}: {s}\n", .{ case.sql, want, err, ran.text });
                return error.TestWrongRefusal;
            }
        },
        .runs => |want| {
            if (ran.err) |err| {
                std.debug.print("{s}: wanted rows, got {t}: {s}\n", .{ case.sql, err, ran.text });
                return error.TestUnexpectedRefusal;
            }
            for (want.has) |part| {
                if (std.mem.indexOf(u8, ran.text, part) == null) {
                    std.debug.print("{s}: wanted {s} in: {s}\n", .{ case.sql, part, ran.text });
                    return error.TestExpectedText;
                }
            }
            if (want.shape.len != 0 and !std.mem.eql(u8, want.shape, ran.shape[0..ran.shape_len])) {
                std.debug.print("{s}: wanted columns {s}, got {s}\n", .{ case.sql, want.shape, ran.shape[0..ran.shape_len] });
                return error.TestWrongTreatment;
            }
        },
    }
}

fn liveWrite(conn: *postgres.Conn, sql: []const u8, permit: engine.Permit) !engine.WriteOutcome {
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

fn liveWriteRefused(conn: *postgres.Conn, sql: []const u8, permit: engine.Permit, want: anyerror) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    if (conn.write(arena_state.allocator(), sql, permit)) |outcome| {
        std.debug.print("{s}: wanted {t}, it wrote {d} rows\n", .{ sql, want, outcome.changes });
        return error.TestExpectedRefusal;
    } else |err| {
        try expectNoLeak(conn.problem());
        if (want == error.FunctionDenied and err == error.SqlFailed and std.mem.indexOf(u8, conn.problem(), "permission denied") != null) return;
        if (err != want) {
            std.debug.print("{s}: wanted {t}, got {t}: {s}\n", .{ sql, want, err, conn.problem() });
            return error.TestWrongRefusal;
        }
    }
}

fn liveCount(conn: *postgres.Conn, table: []const u8) !i64 {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    return conn.count(arena_state.allocator(), table);
}

test "pg live: writes run only on a write connection, destructive ones need the grant and are rolled back, guarded data stays out (EMETGATE_PG_URL)" {
    var live = (try Live.init()) orelse return error.SkipZigTest;
    defer live.deinit();
    try live.reset();
    const reader = try live.open(live.as(reader_role), .read, rules, .{});
    defer reader.close();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    try testing.expectError(error.ActionDenied, reader.write(scratch.allocator(), "DELETE FROM orders WHERE id = 1", .{ .destructive = true }));
    const writer = try live.open(live.as(writer_role), .write, rules, .{});
    defer writer.close();
    const plain: engine.Permit = .{};
    const full: engine.Permit = .{ .destructive = true };
    for (write_cases) |case| switch (case.expect) {
        .refused => |want| try liveWriteRefused(writer, case.sql, full, want),
        .runs => {},
    };
    for ([_]struct { []const u8, anyerror }{
        .{ "UPDATE users SET password_hash = 'x' WHERE id = 1", error.GuardedColumnInWrite },
        .{ "ALTER TABLE users ADD COLUMN c text GENERATED ALWAYS AS (password_hash) STORED", error.GuardedColumnInWrite },
        .{ "ALTER TABLE users RENAME TO people", error.ActionDenied },
        .{ "CREATE VIEW v AS SELECT * FROM users", error.GuardedColumnInWrite },
        .{ "DROP TABLE secret", error.TableRefused },
        .{ "TRUNCATE secret", error.TableRefused },
        .{ "CREATE INDEX ON secret (token)", error.TableRefused },
        .{ "COPY users TO STDOUT", error.ActionDenied },
        .{ "CREATE FUNCTION f() RETURNS int LANGUAGE sql AS 'select 1'", error.ActionDenied },
        .{ "GRANT SELECT ON users TO PUBLIC", error.ActionDenied },
        .{ "SET ROLE postgres", error.ActionDenied },
        .{ "UPDATE users SET U&\"name\" = 'x' WHERE id = 1", error.ActionDenied },
        .{ "SELECT * FROM orders", error.StatementOnlyReads },
        .{ "INSERT INTO orders(user_id, total) VALUES (1, 1); DELETE FROM users", error.MultipleStatements },
        .{ "ALTER TABLE orders ADD COLUMN x text DEFAULT current_setting('data_directory')", error.FunctionDenied },
    }) |case| try liveWriteRefused(writer, case[0], full, case[1]);
    for ([_][]const u8{
        "DELETE FROM orders",
        "DELETE FROM orders WHERE id > 0",
        "UPDATE orders SET total = 0",
        "UPDATE orders SET total = total WHERE true",
        "DROP TABLE orders",
        "TRUNCATE orders",
        "ALTER TABLE orders DROP COLUMN note",
        "WITH d AS (DELETE FROM orders RETURNING *) SELECT count(*) FROM d",
    }) |sql| try liveWriteRefused(writer, sql, plain, error.DestructiveNotGranted);
    try testing.expectEqual(@as(i64, 3), try liveCount(writer, "orders"));
    const one = try liveWrite(writer, "UPDATE orders SET total = 10 WHERE id = 1", plain);
    try testing.expectEqual(@as(i64, 1), one.changes);
    try testing.expectEqual(engine.WriteAction.update, one.action);
    try testing.expect(!one.destructive);
    const added = try liveWrite(writer, "INSERT INTO orders(user_id, total) VALUES (2, 3)", plain);
    try testing.expectEqual(@as(i64, 1), added.changes);
    try testing.expectEqual(engine.WriteAction.insert, added.action);
    const column = try liveWrite(writer, "ALTER TABLE orders ADD COLUMN extra text", plain);
    try testing.expectEqual(engine.WriteAction.alter, column.action);
    const created = try liveWrite(writer, "CREATE TABLE notes (id int, body text)", plain);
    try testing.expectEqual(engine.WriteAction.create, created.action);
    const removed = try liveWrite(writer, "DELETE FROM orders WHERE id = 2", plain);
    try testing.expectEqual(@as(i64, 1), removed.changes);
    try testing.expectEqual(@as(i64, 3), try liveCount(writer, "orders"));
    const copied = try liveWrite(writer, "CREATE TABLE order_copy AS SELECT id, total FROM orders", plain);
    try testing.expectEqual(engine.WriteAction.create, copied.action);
    const cleared = try liveWrite(writer, "DELETE FROM orders", full);
    try testing.expect(cleared.destructive);
    try testing.expectEqual(@as(i64, 3), cleared.changes);
    try testing.expectEqual(@as(i64, 0), try liveCount(writer, "orders"));
    const dropped = try liveWrite(writer, "DROP TABLE order_copy", full);
    try testing.expect(dropped.destructive);
    try testing.expectEqual(engine.WriteAction.drop, dropped.action);
    const users = try liveQuery(reader, "SELECT name, password_hash FROM users WHERE id = 1");
    defer users.deinit();
    try testing.expectEqualStrings("[\"Alice\",null]", users.text);
}

test "pg live: limits, timeouts, listing and describing hold on a real server (EMETGATE_PG_URL)" {
    var live = (try Live.init()) orelse return error.SkipZigTest;
    defer live.deinit();
    try live.reset();
    const capped = try live.open(live.as(reader_role), .read, rules, .{ .max_rows = 50, .timeout_ms = 300 });
    defer capped.close();
    const big = try liveQuery(capped, "SELECT n FROM big ORDER BY n LIMIT 1000000");
    defer big.deinit();
    try testing.expectEqual(@as(usize, 50), big.rows);
    try testing.expect(big.more);
    try testing.expect(std.mem.indexOf(u8, big.text, "[51]") == null);
    const exact = try liveQuery(capped, "SELECT n FROM big ORDER BY n LIMIT 50");
    defer exact.deinit();
    try testing.expect(!exact.more);
    const started = std.Io.Timestamp.now(testing.io, .awake);
    try liveCheck(capped, .{ .sql = "SELECT count(*) FROM big a, big b, big c", .expect = .{ .refused = error.QueryTimeout } }, false);
    try liveCheck(capped, .{ .sql = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c", .expect = .{ .refused = error.QueryTimeout } }, false);
    const took = started.durationTo(std.Io.Timestamp.now(testing.io, .awake)).toMilliseconds();
    try testing.expect(took < 10_000);
    const conn = try live.open(live.as(reader_role), .read, rules, .{});
    defer conn.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const listed = try conn.tables(arena);
    try testing.expectEqual(@as(usize, 1), listed.withheld);
    for (listed.shown) |table| {
        try testing.expect(!std.ascii.eqlIgnoreCase(table.name, "secret"));
        try testing.expect(!std.mem.startsWith(u8, table.name, "events_"));
    }
    try testing.expectError(error.TableRefused, conn.describe(arena, "SECRET"));
    try testing.expectError(error.TableNotFound, conn.describe(arena, "nope"));
    try testing.expectError(error.TableRefused, conn.count(arena, "secret"));
    try testing.expectError(error.TableRefused, conn.describe(arena, "pg_catalog.pg_class"));
    const users = try conn.describe(arena, "Users");
    try testing.expectEqualStrings("users", users.table);
    var hidden: usize = 0;
    var masked: usize = 0;
    for (users.columns) |column| switch (column.treatment) {
        .hidden => hidden += 1,
        .masked => masked += 1,
        .plain => {},
    };
    try testing.expectEqual(@as(usize, 2), hidden);
    try testing.expectEqual(@as(usize, 1), masked);
    try testing.expectEqual(@as(u32, 1), users.columns[0].primary_key);
    const orders = try conn.describe(arena, "orders");
    try testing.expectEqual(@as(usize, 1), orders.foreign_keys.len);
    try testing.expect(orders.indexes.len >= 1);
    try testing.expectEqual(@as(i64, 3), try conn.count(arena, "users"));
    const lines = try conn.explain(arena, "SELECT * FROM orders WHERE id = 1");
    try testing.expect(lines.len >= 1);
    try testing.expectError(error.TableRefused, conn.explain(arena, "SELECT * FROM secret"));
    try testing.expectError(error.StatementNotRead, conn.explain(arena, "DELETE FROM orders"));
    var rows: render.Rows = .init(testing.allocator, .json, conn.limits);
    defer rows.deinit();
    const sampled = try conn.sample(arena, "users", 2, rows.sink());
    try testing.expectEqual(@as(usize, 2), sampled.rows);
    try testing.expect(sampled.more);
    try expectNoLeak(rows.written());
    var other: render.Rows = .init(testing.allocator, .json, conn.limits);
    defer other.deinit();
    try testing.expectError(error.TableRefused, conn.sample(arena, "SECRET", 2, other.sink()));
    try testing.expectError(error.TableNotFound, conn.sample(arena, "users\"; DROP TABLE users; --", 2, other.sink()));
    try testing.expectEqual(@as(i64, 3), try conn.count(arena, "users"));
    const facts = try conn.roleFacts(arena);
    try testing.expect(!facts.superuser);
    try testing.expect(!facts.can_write);
    var why: postgres.OpenProblem = .{};
    var wrong = live.as(reader_role);
    wrong.password = "not-the-password";
    try testing.expectError(error.DatabaseUnavailable, postgres.open(testing.allocator, wrong, .{ .io = testing.io, .mode = .read, .access = .{}, .limits = .{} }, &why));
    try testing.expect(std.mem.indexOf(u8, why.text(), "28P01") != null);
}

test "pg live: TLS with sslmode=require and verify-full, and verify-full refuses a certificate no root vouches for (EMETGATE_PG_URL, EMETGATE_PG_TLS_ROOT)" {
    var live = (try Live.init()) orelse return error.SkipZigTest;
    defer live.deinit();
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    const root = env.get("EMETGATE_PG_TLS_ROOT") orelse return error.SkipZigTest;
    const root_abs = try live.arena_state.allocator().dupe(u8, root);
    try live.reset();
    var target = live.as(reader_role);
    target.host = "localhost";
    target.sslmode = .require;
    const required = try live.open(target, .read, rules, .{});
    try testing.expect(required.encrypted);
    const ran = try liveQuery(required, "SELECT id, email FROM users ORDER BY id LIMIT 1");
    defer ran.deinit();
    try testing.expectEqualStrings("[1,\"a***@example.com\"]", ran.text);
    required.close();
    target.sslmode = .verify_full;
    target.sslrootcert = root_abs;
    const verified = try live.open(target, .read, rules, .{});
    try testing.expect(verified.encrypted);
    verified.close();
    target.sslrootcert = null;
    var why: postgres.OpenProblem = .{};
    try testing.expectError(error.DatabaseUnavailable, postgres.open(testing.allocator, target, .{ .io = testing.io, .mode = .read, .access = rules, .limits = .{} }, &why));
    try testing.expect(std.mem.indexOf(u8, why.text(), "TLS handshake") != null);
}

fn record(arena: Allocator, out: *std.ArrayList(Recorded), conn: *postgres.Conn, sql: []const u8, mode: engine.Mode) !void {
    const evidence = conn.evidenceFor(arena, sql, mode) catch return;
    try out.append(arena, .{ .sql = sql, .mode = mode, .evidence = evidence });
}

test "pg live: every bypass is refused by a real server and nothing private comes back (EMETGATE_PG_URL)" {
    var live = (try Live.init()) orelse return error.SkipZigTest;
    defer live.deinit();
    try live.reset();
    const reader = try live.open(live.as(reader_role), .read, rules, .{});
    defer reader.close();
    for (read_cases) |case| try liveCheck(reader, case, true);
    for (plain_cases) |case| try liveCheck(reader, case, true);
    var super_target = live.admin;
    super_target.database = fixture_db;
    const super = try live.open(super_target, .read, rules, .{});
    defer super.close();
    for (read_cases) |case| try liveCheck(super, case, false);
    for (plain_cases) |case| try liveCheck(super, case, false);
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    const path = env.get("EMETGATE_PG_RECORD") orelse return;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(Recorded) = .empty;
    for (read_cases) |case| try record(arena, &out, super, case.sql, .read);
    const writer = try live.open(super_target, .write, rules, .{});
    defer writer.close();
    for (write_cases) |case| try record(arena, &out, writer, case.sql, .write);
    var text: std.Io.Writer.Allocating = .init(arena);
    var js: std.json.Stringify = .{ .writer = &text.writer, .options = .{ .whitespace = .indent_1 } };
    try js.write(out.items);
    try text.writer.writeByte('\n');
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = text.written() });
}
