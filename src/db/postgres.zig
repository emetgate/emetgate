const std = @import("std");
const access_mod = @import("access.zig");
const engine = @import("engine.zig");
const pg_net = @import("pg_net.zig");
const pg_wire = @import("pg_wire.zig");
const pg_sql = @import("pg_sql.zig");
const pg_plan = @import("pg_plan.zig");
const pg_scram = @import("pg_scram.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const Access = access_mod.Access;
const tls = std.crypto.tls;

pub const max_sql_bytes = 100_000;
pub const max_message_bytes = 32 * 1024 * 1024;
pub const connect_timeout_ms = 10_000;
pub const grace_ms = 5_000;
pub const default_port: u16 = 5432;

pub const SslMode = enum {
    disable,
    prefer,
    require,
    verify_full,

    pub fn parse(text: []const u8) ?SslMode {
        if (std.mem.eql(u8, text, "verify-full")) return .verify_full;
        if (std.mem.eql(u8, text, "verify_full")) return .verify_full;
        if (std.mem.eql(u8, text, "verify-ca")) return null;
        return std.meta.stringToEnum(SslMode, text);
    }

    pub fn label(self: SslMode) []const u8 {
        return if (self == .verify_full) "verify-full" else @tagName(self);
    }
};

pub const Target = struct {
    host: []const u8,
    port: u16 = default_port,
    database: []const u8,
    user: []const u8,
    password: ?[]const u8 = null,
    sslmode: SslMode = .prefer,
    sslrootcert: ?[]const u8 = null,
};

pub const UrlError = error{InvalidUrl};

fn percentDecode(arena: Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '%') == null) return arena.dupe(u8, text);
    const out = try arena.alloc(u8, text.len);
    var i: usize = 0;
    var n: usize = 0;
    while (i < text.len) {
        if (text[i] == '%' and i + 2 < text.len) {
            const byte = std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16) catch return error.InvalidUrl;
            out[n] = byte;
            n += 1;
            i += 3;
            continue;
        }
        if (text[i] == '%') return error.InvalidUrl;
        out[n] = text[i];
        n += 1;
        i += 1;
    }
    return out[0..n];
}

pub fn parseUrl(arena: Allocator, url: []const u8) !Target {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return error.InvalidUrl;
    const scheme = url[0..scheme_end];
    if (!std.ascii.eqlIgnoreCase(scheme, "postgres") and !std.ascii.eqlIgnoreCase(scheme, "postgresql")) return error.InvalidUrl;
    var rest = url[scheme_end + 3 ..];
    var query: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '?')) |q| {
        query = rest[q + 1 ..];
        rest = rest[0..q];
    }
    const slash = std.mem.indexOfScalar(u8, rest, '/');
    const authority = if (slash) |s| rest[0..s] else rest;
    const path = if (slash) |s| rest[s + 1 ..] else "";
    var target: Target = .{ .host = "", .database = "", .user = "" };
    var hostport = authority;
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| {
        const info = authority[0..at];
        hostport = authority[at + 1 ..];
        if (std.mem.indexOfScalar(u8, info, ':')) |colon| {
            target.user = try percentDecode(arena, info[0..colon]);
            target.password = try percentDecode(arena, info[colon + 1 ..]);
        } else target.user = try percentDecode(arena, info);
    }
    if (hostport.len != 0 and hostport[0] == '[') {
        const close = std.mem.indexOfScalar(u8, hostport, ']') orelse return error.InvalidUrl;
        target.host = try arena.dupe(u8, hostport[1..close]);
        const after = hostport[close + 1 ..];
        if (after.len != 0) {
            if (after[0] != ':') return error.InvalidUrl;
            target.port = std.fmt.parseUnsigned(u16, after[1..], 10) catch return error.InvalidUrl;
        }
    } else if (std.mem.lastIndexOfScalar(u8, hostport, ':')) |colon| {
        target.host = try percentDecode(arena, hostport[0..colon]);
        target.port = std.fmt.parseUnsigned(u16, hostport[colon + 1 ..], 10) catch return error.InvalidUrl;
    } else target.host = try percentDecode(arena, hostport);
    if (target.host.len == 0) target.host = "localhost";
    target.database = try percentDecode(arena, path);
    var params = std.mem.splitScalar(u8, query, '&');
    while (params.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return error.InvalidUrl;
        const key = pair[0..eq];
        const value = try percentDecode(arena, pair[eq + 1 ..]);
        if (std.mem.eql(u8, key, "sslmode")) {
            target.sslmode = SslMode.parse(value) orelse return error.InvalidUrl;
        } else if (std.mem.eql(u8, key, "sslrootcert")) {
            target.sslrootcert = value;
        } else if (std.mem.eql(u8, key, "user")) {
            target.user = value;
        } else if (std.mem.eql(u8, key, "password")) {
            target.password = value;
        } else if (std.mem.eql(u8, key, "dbname")) {
            target.database = value;
        } else if (std.mem.eql(u8, key, "host")) {
            target.host = value;
        } else if (std.mem.eql(u8, key, "port")) {
            target.port = std.fmt.parseUnsigned(u16, value, 10) catch return error.InvalidUrl;
        } else if (!std.mem.eql(u8, key, "application_name") and !std.mem.eql(u8, key, "connect_timeout")) return error.InvalidUrl;
    }
    if (target.user.len == 0) return error.InvalidUrl;
    if (target.database.len == 0) target.database = target.user;
    return target;
}

pub fn withPassword(arena: Allocator, url: []const u8, password: []const u8) ![]const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return error.InvalidUrl;
    const start = scheme_end + 3;
    const rest = url[start..];
    const authority_end = std.mem.indexOfAny(u8, rest, "/?") orelse rest.len;
    const at = std.mem.lastIndexOfScalar(u8, rest[0..authority_end], '@') orelse return error.InvalidUrl;
    if (std.mem.indexOfScalar(u8, rest[0..at], ':') != null) return arena.dupe(u8, url);
    var out: Writer.Allocating = .init(arena);
    try out.writer.writeAll(url[0 .. start + at]);
    try out.writer.writeByte(':');
    for (password) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '.' or ch == '_' or ch == '~') {
            try out.writer.writeByte(ch);
        } else try out.writer.print("%{X:0>2}", .{ch});
    }
    try out.writer.writeAll(rest[at..]);
    return out.written();
}

const TlsState = struct {
    client: tls.Client,
    read_buf: []u8,
    write_buf: []u8,
    bundle: std.crypto.Certificate.Bundle = .empty,
    lock: Io.RwLock = .init,
};

const Link = struct {
    socket: pg_net.Socket,
    sock_read: []u8,
    sock_write: []u8,
    tls: ?*TlsState = null,

    fn reader(self: *Link) *Io.Reader {
        return if (self.tls) |t| &t.client.reader else &self.socket.reader;
    }

    fn writer(self: *Link) *Io.Writer {
        return if (self.tls) |t| &t.client.writer else &self.socket.writer;
    }

    fn flush(self: *Link) !void {
        try self.writer().flush();
        if (self.tls != null) try self.socket.writer.flush();
    }
};

pub const OpenProblem = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const OpenProblem) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn set(self: *OpenProblem, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(&self.buf, fmt, args) catch self.buf[0..];
        self.len = written.len;
    }
};

const Described = struct {
    fields: []pg_wire.Field,
    params: usize,
    rows: bool,
};

const Checked = struct {
    plan: []const u8,
    fields: []pg_wire.Field,
    approval: pg_plan.Approval,
};

pub const RoleFacts = struct {
    superuser: bool,
    can_write: bool,
    user: []const u8,
};

pub const Conn = struct {
    gpa: Allocator,
    io: Io,
    link: Link,
    access: Access,
    limits: engine.Limits,
    mode: engine.Mode,
    msg: std.ArrayList(u8) = .empty,
    problem_buf: [2048]u8 = undefined,
    problem_len: usize = 0,
    broken: bool = false,
    closed: bool = false,
    encrypted: bool = false,
    auth_note: []const u8 = "",
    server_version: [32]u8 = undefined,
    server_version_len: usize = 0,
    operators: ?[]const []const u8 = null,
    derived: std.heap.ArenaAllocator,

    pub fn connection(self: *Conn) engine.Connection {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn problem(self: *const Conn) []const u8 {
        return self.problem_buf[0..self.problem_len];
    }

    fn setProblem(self: *Conn, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(&self.problem_buf, fmt, args) catch self.problem_buf[0..];
        self.problem_len = written.len;
    }

    pub fn version(self: *const Conn) []const u8 {
        return self.server_version[0..self.server_version_len];
    }

    pub fn close(self: *Conn) void {
        if (!self.closed) {
            if (!self.broken) {
                pg_wire.writeTerminate(self.link.writer()) catch {};
                self.link.flush() catch {};
            }
            self.link.socket.close();
            self.closed = true;
        }
        if (self.link.tls) |t| {
            t.bundle.deinit(self.gpa);
            self.gpa.free(t.read_buf);
            self.gpa.free(t.write_buf);
            self.gpa.destroy(t);
        }
        self.gpa.free(self.link.sock_read);
        self.gpa.free(self.link.sock_write);
        self.msg.deinit(self.gpa);
        self.derived.deinit();
        self.gpa.destroy(self);
    }

    fn breakLink(self: *Conn) void {
        self.broken = true;
        if (!self.closed) {
            self.link.socket.close();
            self.closed = true;
        }
    }

    fn netError(self: *Conn, err: anyerror) engine.Error {
        self.breakLink();
        if (err == error.ReadFailed or err == error.WriteFailed) {
            if (self.link.socket.err) |e| {
                if (e == error.NetTimeout) {
                    self.setProblem("the database did not answer within the {d} ms timeout; the connection was closed", .{self.limits.timeout_ms});
                    return error.QueryTimeout;
                }
            }
        }
        if (err == error.MessageTooLarge) {
            self.setProblem("a row or message from the database is larger than {d} MB; select fewer or smaller columns", .{max_message_bytes / (1024 * 1024)});
            return error.SqlFailed;
        }
        if (err == error.OutOfMemory) {
            self.setProblem("out of memory while reading from the database", .{});
            return error.SqlFailed;
        }
        self.setProblem("the connection to the database failed ({t})", .{err});
        return error.DatabaseUnavailable;
    }

    fn send(self: *Conn) engine.Error!void {
        if (self.broken) {
            self.setProblem("the connection to the database is closed", .{});
            return error.DatabaseUnavailable;
        }
        self.link.flush() catch |err| return self.netError(err);
    }

    fn next(self: *Conn) engine.Error!pg_wire.Message {
        while (true) {
            if (self.broken) {
                self.setProblem("the connection to the database is closed", .{});
                return error.DatabaseUnavailable;
            }
            const message = pg_wire.readMessage(self.link.reader(), self.gpa, &self.msg, max_message_bytes) catch |err| return self.netError(err);
            switch (message.tag) {
                'N', 'A' => continue,
                'S' => {
                    var b: pg_wire.Body = .{ .bytes = message.body };
                    const name = b.cstr() catch continue;
                    const value = b.cstr() catch continue;
                    if (std.mem.eql(u8, name, "server_version")) {
                        const n = @min(value.len, self.server_version.len);
                        @memcpy(self.server_version[0..n], value[0..n]);
                        self.server_version_len = n;
                    }
                    continue;
                },
                else => return message,
            }
        }
    }

    fn serverError(self: *Conn, body: []const u8) engine.Error {
        const fields = pg_wire.parseError(body);
        const message = fields.message[0..@min(fields.message.len, 1500)];
        if (fields.hint.len != 0) {
            self.setProblem("{s} (SQLSTATE {s}); hint: {s}", .{ message, fields.code, fields.hint[0..@min(fields.hint.len, 300)] });
        } else self.setProblem("{s} (SQLSTATE {s})", .{ message, fields.code });
        const code = fields.code;
        if (std.mem.eql(u8, code, "57014")) {
            self.setProblem("the statement ran past the {d} ms timeout and was stopped", .{self.limits.timeout_ms});
            return error.QueryTimeout;
        }
        if (std.mem.eql(u8, code, "25006")) return error.StatementNotRead;
        if (std.mem.eql(u8, code, "42601") and std.mem.indexOf(u8, fields.message, "multiple commands") != null) {
            self.setProblem("send one statement per call; text after the first statement is not run", .{});
            return error.MultipleStatements;
        }
        if (std.mem.startsWith(u8, code, "08") or std.mem.startsWith(u8, code, "28") or std.mem.eql(u8, code, "3D000") or std.mem.startsWith(u8, code, "57P")) return error.DatabaseUnavailable;
        return error.SqlFailed;
    }

    fn untilReady(self: *Conn, failure: ?engine.Error) engine.Error!void {
        var first = failure;
        while (true) {
            const message = try self.next();
            switch (message.tag) {
                'Z' => break,
                'E' => {
                    const err = self.serverError(message.body);
                    if (first == null) first = err;
                },
                else => {},
            }
        }
        if (first) |err| return err;
    }

    pub fn simple(self: *Conn, sql: []const u8) engine.Error!void {
        pg_wire.writeQuery(self.link.writer(), sql) catch |err| return self.netError(err);
        try self.send();
        try self.untilReady(null);
    }

    pub fn rows(self: *Conn, arena: Allocator, sql: []const u8, params: []const ?[]const u8) engine.Error![]const []const ?[]const u8 {
        const w = self.link.writer();
        pg_wire.writeParse(w, "", sql, &.{}) catch |err| return self.netError(err);
        pg_wire.writeBind(w, "", "", params) catch |err| return self.netError(err);
        pg_wire.writeExecute(w, "", 0) catch |err| return self.netError(err);
        pg_wire.writeSync(w) catch |err| return self.netError(err);
        try self.send();
        var out: std.ArrayList([]const ?[]const u8) = .empty;
        var failure: ?engine.Error = null;
        while (true) {
            const message = try self.next();
            switch (message.tag) {
                'D' => {
                    if (failure != null) continue;
                    var b: pg_wire.Body = .{ .bytes = message.body };
                    const n = b.int16() catch return self.netError(error.ProtocolViolation);
                    const cells = arena.alloc(?[]const u8, @intCast(@max(n, 0))) catch return self.netError(error.OutOfMemory);
                    pg_wire.parseDataRow(message.body, cells) catch return self.netError(error.ProtocolViolation);
                    for (cells) |*slot| {
                        if (slot.*) |v| slot.* = arena.dupe(u8, v) catch return self.netError(error.OutOfMemory);
                    }
                    out.append(arena, cells) catch return self.netError(error.OutOfMemory);
                },
                'E' => {
                    if (failure == null) failure = self.serverError(message.body);
                },
                'Z' => break,
                else => {},
            }
        }
        if (failure) |err| return err;
        return out.items;
    }

    fn one(self: *Conn, arena: Allocator, sql: []const u8, params: []const ?[]const u8) engine.Error!?[]const u8 {
        const got = try self.rows(arena, sql, params);
        if (got.len == 0 or got[0].len == 0) return null;
        return got[0][0];
    }

    fn describeUser(self: *Conn, arena: Allocator, sql: []const u8) engine.Error!Described {
        const w = self.link.writer();
        pg_wire.writeParse(w, "", sql, &.{}) catch |err| {
            if (err == error.NulInText) {
                self.setProblem("the statement holds a NUL byte", .{});
                return error.SqlFailed;
            }
            return self.netError(err);
        };
        pg_wire.writeDescribe(w, 'S', "") catch |err| return self.netError(err);
        pg_wire.writeSync(w) catch |err| return self.netError(err);
        try self.send();
        var described: Described = .{ .fields = &.{}, .params = 0, .rows = false };
        var failure: ?engine.Error = null;
        while (true) {
            const message = try self.next();
            switch (message.tag) {
                't' => {
                    var b: pg_wire.Body = .{ .bytes = message.body };
                    described.params = @intCast(@max(b.int16() catch 0, 0));
                },
                'T' => {
                    described.fields = pg_wire.parseRowDescription(arena, message.body) catch return self.netError(error.ProtocolViolation);
                    described.rows = true;
                },
                'E' => {
                    if (failure == null) failure = self.serverError(message.body);
                },
                'Z' => break,
                else => {},
            }
        }
        if (failure) |err| return err;
        if (described.params != 0) {
            self.setProblem("the statement uses $1-style parameters; write the values into the statement instead", .{});
            return error.SqlFailed;
        }
        return described;
    }

    fn begin(self: *Conn, read_only: bool) engine.Error!void {
        var buf: [256]u8 = undefined;
        const sql = std.fmt.bufPrint(&buf, "BEGIN ISOLATION LEVEL REPEATABLE READ{s}; SET LOCAL statement_timeout = {d}; SET LOCAL lock_timeout = {d}", .{ if (read_only) " READ ONLY" else " READ WRITE", self.limits.timeout_ms, self.limits.timeout_ms }) catch unreachable;
        try self.simple(sql);
    }

    fn rollback(self: *Conn) void {
        if (self.broken) return;
        self.simple("ROLLBACK") catch {};
    }

    fn chainOf(self: *Conn, arena: Allocator, oid: []const u8) engine.Error!struct { schema: []const u8, name: []const u8, chain: []const []const u8 } {
        const sql =
            \\WITH RECURSIVE up(relid, depth) AS (SELECT $1::oid, 0 UNION ALL SELECT i.inhparent, up.depth + 1 FROM pg_catalog.pg_inherits i JOIN up ON i.inhrelid = up.relid WHERE up.depth < 32)
            \\SELECT n.nspname, c.relname FROM up JOIN pg_catalog.pg_class c ON c.oid = up.relid JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace ORDER BY up.depth, c.relname
        ;
        const got = try self.rows(arena, sql, &.{oid});
        if (got.len == 0) {
            self.setProblem("relation {s} could not be looked up", .{oid});
            return error.SqlFailed;
        }
        const chain = arena.alloc([]const u8, got.len) catch return self.netError(error.OutOfMemory);
        for (got, chain) |row, *slot| slot.* = row[1] orelse "";
        return .{ .schema = got[0][0] orelse "", .name = got[0][1] orelse "", .chain = chain };
    }

    fn userOperators(self: *Conn) engine.Error![]const []const u8 {
        if (self.operators) |ops| return ops;
        const arena = self.derived.allocator();
        const got = try self.rows(arena, "SELECT DISTINCT oprname FROM pg_catalog.pg_operator WHERE oprnamespace <> 'pg_catalog'::regnamespace", &.{});
        const ops = arena.alloc([]const u8, got.len) catch return self.netError(error.OutOfMemory);
        for (got, ops) |row, *slot| slot.* = row[0] orelse "";
        self.operators = ops;
        return ops;
    }

    fn shadowed(self: *Conn, arena: Allocator, names: []const []const u8) engine.Error![]const []const u8 {
        if (names.len == 0) return &.{};
        var list: Writer.Allocating = .init(arena);
        list.writer.writeByte('{') catch return self.netError(error.OutOfMemory);
        for (names, 0..) |name, i| {
            if (i != 0) list.writer.writeByte(',') catch return self.netError(error.OutOfMemory);
            list.writer.writeByte('"') catch return self.netError(error.OutOfMemory);
            for (name) |ch| {
                if (ch == '"' or ch == '\\') list.writer.writeByte('\\') catch return self.netError(error.OutOfMemory);
                list.writer.writeByte(ch) catch return self.netError(error.OutOfMemory);
            }
            list.writer.writeByte('"') catch return self.netError(error.OutOfMemory);
        }
        list.writer.writeByte('}') catch return self.netError(error.OutOfMemory);
        const sql =
            \\SELECT DISTINCT p.proname FROM pg_catalog.pg_proc p
            \\WHERE p.pronamespace <> 'pg_catalog'::regnamespace AND p.proname = ANY ($1::text[])
            \\AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_depend d WHERE d.classid = 'pg_catalog.pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
        ;
        const got = try self.rows(arena, sql, &.{list.written()});
        const out = arena.alloc([]const u8, got.len) catch return self.netError(error.OutOfMemory);
        for (got, out) |row, *slot| slot.* = row[0] orelse "";
        return out;
    }

    fn gather(self: *Conn, arena: Allocator, plan: []const u8, fields: []const pg_wire.Field) engine.Error!pg_plan.Evidence {
        const needs = pg_plan.needs(arena, plan) catch {
            self.setProblem("the query plan could not be read", .{});
            return error.SqlFailed;
        };
        var relations: std.ArrayList(pg_plan.RelationFacts) = .empty;
        for (needs.relations) |rel| {
            const oid = (try self.one(arena, "SELECT c.oid::text FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = $1 AND c.relname = $2", &.{ rel.schema.?, rel.name })) orelse {
                self.setProblem("relation {s}.{s} could not be looked up", .{ rel.schema.?, rel.name });
                return error.SqlFailed;
            };
            const found = try self.chainOf(arena, oid);
            const listed = try self.rows(arena, "SELECT attname::text FROM pg_catalog.pg_attribute WHERE attrelid = $1::oid AND attnum > 0 AND NOT attisdropped", &.{oid});
            const columns = arena.alloc([]const u8, listed.len) catch return self.netError(error.OutOfMemory);
            for (listed, columns) |row, *slot| slot.* = row[0] orelse "";
            relations.append(arena, .{ .schema = rel.schema.?, .name = rel.name, .chain = found.chain, .system = pg_plan.isSystemSchema(found.schema), .columns = columns }) catch return self.netError(error.OutOfMemory);
        }
        const results = arena.alloc(pg_plan.ResultField, fields.len) catch return self.netError(error.OutOfMemory);
        for (fields, results) |field, *slot| {
            slot.* = .{ .name = field.name };
            if (field.table_oid == 0 or field.column == 0) continue;
            var oid_buf: [16]u8 = undefined;
            const oid = std.fmt.bufPrint(&oid_buf, "{d}", .{field.table_oid}) catch unreachable;
            const found = try self.chainOf(arena, oid);
            var num_buf: [8]u8 = undefined;
            const num = std.fmt.bufPrint(&num_buf, "{d}", .{field.column}) catch unreachable;
            const column = (try self.one(arena, "SELECT attname::text FROM pg_catalog.pg_attribute WHERE attrelid = $1::oid AND attnum = $2::int2", &.{ oid, num })) orelse continue;
            slot.origin = .{ .schema = found.schema, .table = found.name, .column = column, .chain = found.chain };
        }
        return .{
            .plan = plan,
            .fields = results,
            .relations = relations.items,
            .shadowed = try self.shadowed(arena, needs.functions),
            .operators = try self.userOperators(),
        };
    }

    fn explainJson(self: *Conn, arena: Allocator, sql: []const u8) engine.Error![]const u8 {
        const text = std.fmt.allocPrint(arena, "EXPLAIN (VERBOSE, FORMAT JSON) {s}", .{sql}) catch return self.netError(error.OutOfMemory);
        return (try self.one(arena, text, &.{})) orelse {
            self.setProblem("the database returned no plan for the statement", .{});
            return error.SqlFailed;
        };
    }

    pub fn evidenceFor(self: *Conn, arena: Allocator, sql: []const u8, mode: engine.Mode) !pg_plan.Evidence {
        try self.begin(mode == .read);
        defer self.rollback();
        const described = try self.describeUser(arena, sql);
        const plan = try self.explainJson(arena, sql);
        return self.gather(arena, plan, if (mode == .read) described.fields else &.{});
    }

    fn refusedBy(self: *Conn, refusal: pg_plan.Refusal) engine.Error {
        self.setProblem("{s}", .{refusal.message});
        return refusal.err;
    }

    fn checkRead(self: *Conn, arena: Allocator, sql: []const u8) engine.Error!Checked {
        if (sql.len > max_sql_bytes) {
            self.setProblem("the statement is {d} bytes, over the limit of {d}", .{ sql.len, max_sql_bytes });
            return error.SqlFailed;
        }
        const tokens = pg_sql.tokenize(arena, sql) catch |err| {
            if (err == error.OutOfMemory) return self.netError(err);
            self.setProblem("the statement has an unterminated string, quoted name or comment", .{});
            return error.SqlFailed;
        };
        const head = pg_sql.firstWord(tokens) orelse {
            self.setProblem("the statement is empty", .{});
            return error.EmptyStatement;
        };
        if (!pg_sql.isQueryStart(head)) {
            self.setProblem("only a SELECT, WITH ... SELECT, VALUES or TABLE statement reads; this one starts with {s}", .{head.text[0..@min(head.text.len, 40)]});
            return error.StatementNotRead;
        }
        const described = try self.describeUser(arena, sql);
        if (!described.rows) {
            self.setProblem("only a SELECT (or WITH ... SELECT) reads; this statement returns no rows", .{});
            return error.StatementNotRead;
        }
        const plan = try self.explainJson(arena, sql);
        const evidence = try self.gather(arena, plan, described.fields);
        const verdict = pg_plan.decide(arena, evidence, self.access, .read) catch return self.netError(error.OutOfMemory);
        switch (verdict) {
            .refused => |refusal| return self.refusedBy(refusal),
            .ok => |approval| return .{ .plan = plan, .fields = described.fields, .approval = approval },
        }
    }

    fn cell(arena: Allocator, text: []const u8, type_oid: u32, how: engine.Treatment) !engine.Value {
        switch (how) {
            .hidden => return .null,
            .masked => |mask| {
                if (type_oid == 17) return .{ .text = "***" };
                var out: Writer.Allocating = .init(arena);
                try access_mod.writeMasked(&out.writer, mask, text);
                return .{ .text = out.written() };
            },
            .plain => {},
        }
        switch (type_oid) {
            20, 21, 23, 26 => return if (std.fmt.parseInt(i64, text, 10)) |n| .{ .integer = n } else |_| .{ .text = text },
            700, 701 => {
                if (std.mem.eql(u8, text, "NaN")) return .{ .real = std.math.nan(f64) };
                if (std.mem.eql(u8, text, "Infinity")) return .{ .real = std.math.inf(f64) };
                if (std.mem.eql(u8, text, "-Infinity")) return .{ .real = -std.math.inf(f64) };
                return if (std.fmt.parseFloat(f64, text)) |f| .{ .real = f } else |_| .{ .text = text };
            },
            1700 => {
                var digits: usize = 0;
                for (text) |ch| {
                    if (std.ascii.isDigit(ch)) digits += 1;
                }
                if (digits > 15) return .{ .text = text };
                return if (std.fmt.parseFloat(f64, text)) |f| .{ .real = f } else |_| .{ .text = text };
            },
            16 => return .{ .text = if (std.mem.eql(u8, text, "t")) "true" else "false" },
            17 => return if (try pg_wire.decodeHexBytea(arena, text)) |bytes| .{ .blob = bytes } else .{ .text = text },
            else => return .{ .text = text },
        }
    }

    fn execute(self: *Conn, arena: Allocator, sql: []const u8, checked: Checked, max_rows: u32, sink: engine.Sink) !engine.Outcome {
        const started = Io.Timestamp.now(self.io, .awake);
        const w = self.link.writer();
        pg_wire.writeParse(w, "", sql, &.{}) catch |err| return self.netError(err);
        pg_wire.writeBind(w, "", "", &.{}) catch |err| return self.netError(err);
        pg_wire.writeDescribe(w, 'P', "") catch |err| return self.netError(err);
        pg_wire.writeExecute(w, "", max_rows + 1) catch |err| return self.netError(err);
        pg_wire.writeSync(w) catch |err| return self.netError(err);
        try self.send();
        const columns = try arena.alloc(engine.ResultColumn, checked.fields.len);
        for (columns, checked.fields, checked.approval.treatments) |*column, field, how| column.* = .{ .name = field.name, .treatment = how };
        var outcome: engine.Outcome = .{ .nulled = checked.approval.nulled };
        const values = try arena.alloc(engine.Value, columns.len);
        const cells = try arena.alloc(?[]const u8, columns.len);
        var row_arena = std.heap.ArenaAllocator.init(self.gpa);
        defer row_arena.deinit();
        var failure: ?engine.Error = null;
        var begun = false;
        while (true) {
            const message = try self.next();
            switch (message.tag) {
                'T' => {
                    const again = pg_wire.parseRowDescription(arena, message.body) catch return self.netError(error.ProtocolViolation);
                    if (again.len != checked.fields.len) failure = failure orelse self.changed();
                    for (again, checked.fields) |a, b| {
                        if (a.table_oid != b.table_oid or a.column != b.column or a.type_oid != b.type_oid) failure = failure orelse self.changed();
                    }
                    if (failure == null) {
                        try sink.begin(sink.ptr, columns);
                        begun = true;
                    }
                },
                'D' => {
                    if (failure != null or !begun) continue;
                    if (outcome.rows >= max_rows) {
                        outcome.more = true;
                        outcome.stop = .rows;
                        continue;
                    }
                    pg_wire.parseDataRow(message.body, cells) catch return self.netError(error.ProtocolViolation);
                    _ = row_arena.reset(.retain_capacity);
                    for (values, cells, checked.fields, checked.approval.treatments) |*value, text, field, how| {
                        value.* = if (text) |t| try cell(row_arena.allocator(), t, field.type_oid, how) else .null;
                    }
                    if (!try sink.row(sink.ptr, values)) {
                        outcome.more = true;
                        outcome.stop = .bytes;
                        self.breakLink();
                        break;
                    }
                    outcome.rows += 1;
                },
                'E' => {
                    if (failure == null) failure = self.serverError(message.body);
                },
                'Z' => break,
                else => {},
            }
        }
        if (failure) |err| return err;
        if (!begun) try sink.begin(sink.ptr, columns);
        const ns = started.durationTo(Io.Timestamp.now(self.io, .awake)).nanoseconds;
        outcome.elapsed_ms = @intCast(@max(@divTrunc(ns, std.time.ns_per_ms), 0));
        return outcome;
    }

    fn changed(self: *Conn) engine.Error {
        self.setProblem("the statement's result columns changed between the check and the run; run it again", .{});
        return error.SqlFailed;
    }

    pub fn query(self: *Conn, arena: Allocator, sql: []const u8, sink: engine.Sink) !engine.Outcome {
        return self.readRun(arena, sql, self.limits.max_rows, sink);
    }

    fn readRun(self: *Conn, arena: Allocator, sql: []const u8, max_rows: u32, sink: engine.Sink) !engine.Outcome {
        try self.begin(true);
        defer self.rollback();
        const checked = try self.checkRead(arena, sql);
        return self.execute(arena, sql, checked, max_rows, sink);
    }

    pub fn explain(self: *Conn, arena: Allocator, sql: []const u8) ![]const []const u8 {
        try self.begin(true);
        defer self.rollback();
        const checked = try self.checkRead(arena, sql);
        return pg_plan.planLines(arena, checked.plan) catch {
            self.setProblem("the query plan could not be read", .{});
            return error.SqlFailed;
        };
    }

    const Found = struct { schema: []const u8, name: []const u8, oid: []const u8, kind: engine.TableKind, chain: []const []const u8 };

    fn qualified(arena: Allocator, schema: []const u8, name: []const u8) ![]const u8 {
        var out: Writer.Allocating = .init(arena);
        try pg_wire.quoteIdent(&out.writer, schema);
        try out.writer.writeByte('.');
        try pg_wire.quoteIdent(&out.writer, name);
        return out.written();
    }

    fn lookup(self: *Conn, arena: Allocator, table: []const u8) engine.Error!Found {
        var schema: ?[]const u8 = null;
        var name = table;
        if (std.mem.indexOfScalar(u8, table, '.')) |dot| {
            if (dot != 0 and dot + 1 < table.len) {
                schema = table[0..dot];
                name = table[dot + 1 ..];
            }
        }
        if (self.access.tableRefusal(name)) |refusal| {
            const why = if (refusal == .not_allowed) "is not on the allowed table list" else "is blocked";
            self.setProblem("table {s} {s} by the database access rules", .{ name, why });
            return error.TableRefused;
        }
        if (schema) |s| {
            if (pg_plan.isSystemSchema(s)) {
                self.setProblem("{s} is a system schema; op tables lists the tables you may use", .{s});
                return error.TableRefused;
            }
        }
        const sql =
            \\SELECT n.nspname, c.relname, c.oid::text, c.relkind::text FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            \\WHERE c.relkind IN ('r','v','m','p','f') AND n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg\_toast%'
            \\AND ($2::text IS NULL OR n.nspname = $2) AND (c.relname = $1 OR lower(c.relname) = lower($1))
            \\ORDER BY c.relname = $1 DESC, n.nspname = ANY (current_schemas(false)) DESC, n.nspname LIMIT 1
        ;
        try self.begin(true);
        defer self.rollback();
        const got = try self.rows(arena, sql, &.{ name, schema });
        if (got.len == 0) {
            self.setProblem("no table or view named {s}", .{table});
            return error.TableNotFound;
        }
        const row = got[0];
        const found_chain = try self.chainOf(arena, row[2].?);
        const kind: engine.TableKind = if (std.mem.eql(u8, row[3] orelse "", "v")) .view else .table;
        const found: Found = .{ .schema = row[0].?, .name = row[1].?, .oid = row[2].?, .kind = kind, .chain = found_chain.chain };
        for (found.chain) |link_name| {
            if (self.access.tableRefusal(link_name)) |refusal| {
                const why = if (refusal == .not_allowed) "is not on the allowed table list" else "is blocked";
                self.setProblem("table {s} {s} by the database access rules", .{ link_name, why });
                return error.TableRefused;
            }
        }
        return found;
    }

    pub fn sample(self: *Conn, arena: Allocator, table: []const u8, wanted: u32, sink: engine.Sink) !engine.Outcome {
        const found = try self.lookup(arena, table);
        const sql = try std.fmt.allocPrint(arena, "SELECT * FROM {s}", .{try qualified(arena, found.schema, found.name)});
        return self.readRun(arena, sql, @min(wanted, self.limits.max_rows), sink);
    }

    const Capture = struct {
        value: ?i64 = null,

        fn sink(self: *Capture) engine.Sink {
            return .{ .ptr = self, .begin = beginCapture, .row = rowCapture };
        }

        fn beginCapture(ptr: *anyopaque, columns: []const engine.ResultColumn) anyerror!void {
            _ = ptr;
            _ = columns;
        }

        fn rowCapture(ptr: *anyopaque, values: []const engine.Value) anyerror!bool {
            const self: *Capture = @ptrCast(@alignCast(ptr));
            if (values.len != 0 and values[0] == .integer) self.value = values[0].integer;
            return true;
        }
    };

    pub fn count(self: *Conn, arena: Allocator, table: []const u8) !i64 {
        const found = try self.lookup(arena, table);
        const sql = try std.fmt.allocPrint(arena, "SELECT count(*) FROM {s}", .{try qualified(arena, found.schema, found.name)});
        var capture: Capture = .{};
        _ = try self.readRun(arena, sql, 1, capture.sink());
        return capture.value orelse 0;
    }

    pub fn tables(self: *Conn, arena: Allocator) !engine.Tables {
        const sql =
            \\SELECT n.nspname, c.relname, c.relkind::text, coalesce((SELECT string_agg(p.relname, chr(31)) FROM pg_catalog.pg_inherits i JOIN pg_catalog.pg_class p ON p.oid = i.inhparent WHERE i.inhrelid = c.oid), '')
            \\FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            \\WHERE c.relkind IN ('r','v','m','p','f') AND NOT c.relispartition AND n.nspname NOT IN ('pg_catalog','information_schema')
            \\AND n.nspname NOT LIKE 'pg\_toast%' AND n.nspname NOT LIKE 'pg\_temp%' AND pg_catalog.has_any_column_privilege(c.oid, 'SELECT')
            \\ORDER BY n.nspname <> 'public', n.nspname, lower(c.relname)
        ;
        try self.begin(true);
        defer self.rollback();
        const got = try self.rows(arena, sql, &.{});
        var shown: std.ArrayList(engine.TableInfo) = .empty;
        var withheld: usize = 0;
        for (got) |row| {
            const schema = row[0] orelse "";
            const name = row[1] orelse "";
            var refused = self.access.tableRefusal(name) != null;
            var parents = std.mem.splitScalar(u8, row[3] orelse "", 31);
            while (parents.next()) |parent| {
                if (parent.len != 0 and self.access.tableRefusal(parent) != null) refused = true;
            }
            if (refused) {
                withheld += 1;
                continue;
            }
            const shown_name = if (std.mem.eql(u8, schema, "public")) name else try std.fmt.allocPrint(arena, "{s}.{s}", .{ schema, name });
            try shown.append(arena, .{ .name = shown_name, .kind = if (std.mem.eql(u8, row[2] orelse "", "v")) .view else .table });
        }
        return .{ .shown = shown.items, .withheld = withheld };
    }

    pub fn describe(self: *Conn, arena: Allocator, table: []const u8) !engine.Description {
        const found = try self.lookup(arena, table);
        try self.begin(true);
        defer self.rollback();
        const column_sql =
            \\SELECT a.attname::text, pg_catalog.format_type(a.atttypid, a.atttypmod), a.attnotnull::text, pg_catalog.pg_get_expr(d.adbin, d.adrelid),
            \\(a.attgenerated <> '')::text, coalesce((SELECT k.ord FROM unnest(i.indkey::int2[]) WITH ORDINALITY k(n, ord) WHERE k.n = a.attnum), 0)::text
            \\FROM pg_catalog.pg_attribute a LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            \\LEFT JOIN pg_catalog.pg_index i ON i.indrelid = a.attrelid AND i.indisprimary
            \\WHERE a.attrelid = $1::oid AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum
        ;
        var columns: std.ArrayList(engine.ColumnInfo) = .empty;
        for (try self.rows(arena, column_sql, &.{found.oid})) |row| {
            const name = row[0] orelse "";
            const how = chainTreat(self.access, found.chain, name);
            try columns.append(arena, .{
                .name = name,
                .decl_type = row[1] orelse "",
                .not_null = std.mem.eql(u8, row[2] orelse "", "true"),
                .default = if (how != .plain) null else row[3],
                .generated = std.mem.eql(u8, row[4] orelse "", "true"),
                .primary_key = std.fmt.parseUnsigned(u32, row[5] orelse "0", 10) catch 0,
                .treatment = how,
            });
        }
        const index_sql =
            \\SELECT ic.relname::text, i.indisunique::text, array_to_string(ARRAY(SELECT coalesce(a.attname::text, '<expression>') FROM unnest(i.indkey::int2[]) WITH ORDINALITY k(attnum, ord)
            \\LEFT JOIN pg_catalog.pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum ORDER BY k.ord), chr(31))
            \\FROM pg_catalog.pg_index i JOIN pg_catalog.pg_class ic ON ic.oid = i.indexrelid WHERE i.indrelid = $1::oid ORDER BY ic.relname
        ;
        var indexes: std.ArrayList(engine.IndexInfo) = .empty;
        for (try self.rows(arena, index_sql, &.{found.oid})) |row| {
            var names: std.ArrayList([]const u8) = .empty;
            var parts = std.mem.splitScalar(u8, row[2] orelse "", 31);
            while (parts.next()) |part| {
                if (part.len != 0) try names.append(arena, part);
            }
            try indexes.append(arena, .{ .name = row[0] orelse "", .unique = std.mem.eql(u8, row[1] orelse "", "true"), .columns = names.items });
        }
        const key_sql =
            \\SELECT a.attname::text, fc.relname::text, fa.attname::text FROM pg_catalog.pg_constraint k
            \\CROSS JOIN LATERAL unnest(k.conkey, k.confkey) AS u(src, dst)
            \\JOIN pg_catalog.pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = u.src
            \\JOIN pg_catalog.pg_class fc ON fc.oid = k.confrelid
            \\JOIN pg_catalog.pg_attribute fa ON fa.attrelid = k.confrelid AND fa.attnum = u.dst
            \\WHERE k.conrelid = $1::oid AND k.contype = 'f' ORDER BY k.conname
        ;
        var keys: std.ArrayList(engine.ForeignKey) = .empty;
        for (try self.rows(arena, key_sql, &.{found.oid})) |row| {
            const target = row[1] orelse "";
            if (self.access.tableRefusal(target) != null) continue;
            try keys.append(arena, .{ .from = row[0] orelse "", .table = target, .to = row[2] });
        }
        return .{ .table = found.name, .kind = found.kind, .columns = columns.items, .indexes = indexes.items, .foreign_keys = keys.items };
    }

    fn resolveTarget(self: *Conn, arena: Allocator, name: pg_sql.Name) engine.Error!?[]const []const u8 {
        var text: Writer.Allocating = .init(arena);
        if (name.schema) |s| {
            pg_wire.quoteIdent(&text.writer, s) catch return self.netError(error.OutOfMemory);
            text.writer.writeByte('.') catch return self.netError(error.OutOfMemory);
        }
        pg_wire.quoteIdent(&text.writer, name.name) catch return self.netError(error.OutOfMemory);
        const oid = (try self.one(arena, "SELECT pg_catalog.to_regclass($1)::oid::text", &.{text.written()})) orelse return null;
        const found = try self.chainOf(arena, oid);
        if (pg_plan.isSystemSchema(found.schema)) {
            self.setProblem("{s}.{s} is a system catalog; a write may not touch it", .{ found.schema, found.name });
            return error.TableRefused;
        }
        return found.chain;
    }

    fn countUpTo(self: *Conn, arena: Allocator, schema: []const u8, name: []const u8, limit: ?u32) engine.Error!i64 {
        const table = qualified(arena, schema, name) catch return self.netError(error.OutOfMemory);
        const sql = if (limit) |n|
            std.fmt.allocPrint(arena, "SELECT count(*)::text FROM (SELECT 1 FROM {s} LIMIT {d}) x", .{ table, n }) catch return self.netError(error.OutOfMemory)
        else
            std.fmt.allocPrint(arena, "SELECT count(*)::text FROM {s}", .{table}) catch return self.netError(error.OutOfMemory);
        const got = (try self.one(arena, sql, &.{})) orelse return 0;
        return std.fmt.parseInt(i64, got, 10) catch 0;
    }

    fn columnCount(self: *Conn, arena: Allocator, chain_oid: []const u8) engine.Error!i64 {
        const got = (try self.one(arena, "SELECT count(*)::text FROM pg_catalog.pg_attribute WHERE attrelid = $1::oid AND attnum > 0 AND NOT attisdropped", &.{chain_oid})) orelse return 0;
        return std.fmt.parseInt(i64, got, 10) catch 0;
    }

    fn checkChain(self: *Conn, chain: []const []const u8) engine.Error!void {
        for (chain) |name| {
            if (self.access.tableRefusal(name)) |refusal| {
                const why = if (refusal == .not_allowed) "is not on the allowed table list" else "is blocked";
                self.setProblem("table {s} {s} by the database access rules", .{ name, why });
                return error.TableRefused;
            }
        }
    }

    fn guarded(self: *Conn, chain: []const []const u8) bool {
        for (chain) |name| {
            if (self.access.guards(name)) return true;
        }
        return false;
    }

    fn callNames(arena: Allocator, tokens: []const pg_sql.Token) ![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        for (tokens, 0..) |token, i| {
            if (!token.isName() or i + 1 >= tokens.len or !tokens[i + 1].is(.punct, "(")) continue;
            try list.append(arena, try pg_sql.unquote(arena, token));
            if (token.kind == .ident) try list.append(arena, try std.ascii.allocLowerString(arena, token.text));
        }
        return list.items;
    }

    pub fn write(self: *Conn, arena: Allocator, sql: []const u8, permit: engine.Permit) !engine.WriteOutcome {
        if (self.mode != .write) {
            self.setProblem("this connection was opened read-only", .{});
            return error.ActionDenied;
        }
        if (sql.len > max_sql_bytes) {
            self.setProblem("the statement is {d} bytes, over the limit of {d}", .{ sql.len, max_sql_bytes });
            return error.SqlFailed;
        }
        const tokens = pg_sql.tokenize(arena, sql) catch {
            self.setProblem("the statement has an unterminated string, quoted name or comment", .{});
            return error.SqlFailed;
        };
        if (pg_sql.hasUnicodeEscape(tokens)) {
            self.setProblem("U&\"...\" and U&'...' escapes are not allowed in a write; spell the name or text out", .{});
            return error.ActionDenied;
        }
        const shaped = try pg_sql.shape(arena, sql, tokens);
        switch (shaped.statement) {
            .empty => {
                self.setProblem("the statement is empty", .{});
                return error.EmptyStatement;
            },
            .denied => {
                self.setProblem("only INSERT, UPDATE, DELETE, MERGE, TRUNCATE, ANALYZE, COMMENT ON, and CREATE, ALTER or DROP of a table, view, materialized view, index or sequence run here; functions, triggers, roles, grants, COPY, SET and DO never do", .{});
                return error.ActionDenied;
            },
            else => {},
        }
        try self.begin(false);
        var committed = false;
        defer if (!committed) self.rollback();
        const described = try self.describeUser(arena, sql);
        var statement = shaped.statement;
        var plan_targets: []const pg_plan.Target = &.{};
        var plan_chains: []const []const []const u8 = &.{};
        const planned = statement == .select or pg_sql.writesData(statement) or statement == .create_table_as or statement == .create_matview or statement == .create_view;
        if (planned) {
            const explained_sql = if (statement == .create_view) sql[shaped.query_start.?..shaped.query_end.?] else sql;
            const plan = try self.explainJson(arena, explained_sql);
            const evidence = try self.gather(arena, plan, &.{});
            const verdict = try pg_plan.decide(arena, evidence, self.access, .write);
            switch (verdict) {
                .refused => |refusal| return self.refusedBy(refusal),
                .ok => |approval| {
                    plan_targets = approval.targets;
                    plan_chains = approval.relations;
                },
            }
            if (statement == .select) {
                if (plan_targets.len != 0) {
                    statement = switch (plan_targets[0].action) {
                        .insert => .insert,
                        .delete => .delete,
                        else => .update,
                    };
                } else if (described.rows) {
                    self.setProblem("this statement only reads; it changes nothing", .{});
                    return error.StatementOnlyReads;
                } else statement = .create_table_as;
            }
        }
        var chains: std.ArrayList([]const []const u8) = .empty;
        try chains.appendSlice(arena, plan_chains);
        for (shaped.targets) |name| {
            if (try self.resolveTarget(arena, name)) |chain| {
                try self.checkChain(chain);
                if (shaped.rename and self.guarded(chain)) {
                    self.setProblem("{s} has hidden or masked columns; renaming it or its columns, or detaching it from its parent, would drop those rules, so it is refused", .{name.name});
                    return error.ActionDenied;
                }
                try chains.append(arena, chain);
            } else {
                const single = try arena.alloc([]const u8, 1);
                single[0] = name.name;
                try self.checkChain(single);
                try chains.append(arena, single);
            }
        }
        const involved = try pg_plan.involvedNames(arena, tokens, chains.items);
        const shadow = try self.shadowed(arena, try callNames(arena, tokens));
        if (try pg_plan.ddlCheck(arena, tokens, self.access, involved, shadow)) |refusal| return self.refusedBy(refusal);
        var destructive = statement == .drop or statement == .truncate;
        if (destructive and !permit.destructive) {
            const what = if (statement == .drop) "dropping" else "truncating";
            self.setProblem("{s} {s} is destructive; nothing was changed", .{ what, if (shaped.targets.len != 0) shaped.targets[0].name else "it" });
            return error.DestructiveNotGranted;
        }
        const Before = struct { target: pg_plan.Target, rows: i64 };
        var befores: std.ArrayList(Before) = .empty;
        for (plan_targets) |target| {
            if (target.action == .delete or target.action == .other) {
                try befores.append(arena, .{ .target = target, .rows = try self.countUpTo(arena, target.schema, target.name, 2) });
            } else try befores.append(arena, .{ .target = target, .rows = 0 });
        }
        var alter_oid: ?[]const u8 = null;
        var columns_before: i64 = 0;
        if (statement == .alter_table and shaped.targets.len != 0) {
            var text: Writer.Allocating = .init(arena);
            if (shaped.targets[0].schema) |s| {
                try pg_wire.quoteIdent(&text.writer, s);
                try text.writer.writeByte('.');
            }
            try pg_wire.quoteIdent(&text.writer, shaped.targets[0].name);
            alter_oid = try self.one(arena, "SELECT pg_catalog.to_regclass($1)::oid::text", &.{text.written()});
            if (alter_oid) |oid| columns_before = try self.columnCount(arena, oid);
        }
        const started = Io.Timestamp.now(self.io, .awake);
        const w = self.link.writer();
        pg_wire.writeParse(w, "", sql, &.{}) catch |err| return self.netError(err);
        pg_wire.writeBind(w, "", "", &.{}) catch |err| return self.netError(err);
        pg_wire.writeExecute(w, "", 0) catch |err| return self.netError(err);
        pg_wire.writeSync(w) catch |err| return self.netError(err);
        try self.send();
        var changes: i64 = 0;
        var failure: ?engine.Error = null;
        while (true) {
            const message = try self.next();
            switch (message.tag) {
                'C' => changes = pg_wire.commandRows(message.body) orelse 0,
                'E' => {
                    if (failure == null) failure = self.serverError(message.body);
                },
                'Z' => break,
                else => {},
            }
        }
        if (failure) |err| return err;
        const ns = started.durationTo(Io.Timestamp.now(self.io, .awake)).nanoseconds;
        for (befores.items) |before| {
            const target = before.target;
            if (target.action == .delete or target.action == .other) {
                const after = try self.countUpTo(arena, target.schema, target.name, 1);
                if (before.rows >= 2 and after == 0) {
                    destructive = true;
                    if (!permit.destructive) self.setProblem("this statement would remove every row of {s}; nothing was changed", .{target.name});
                }
            }
            if ((target.action == .update or target.action == .other) and changes >= 2) {
                const total = try self.countUpTo(arena, target.schema, target.name, null);
                if (changes >= total) {
                    destructive = true;
                    if (!permit.destructive) self.setProblem("this statement would change every row of {s} ({d} rows); nothing was changed", .{ target.name, total });
                }
            }
        }
        if (alter_oid) |oid| {
            const after = try self.columnCount(arena, oid);
            if (after < columns_before) {
                destructive = true;
                if (!permit.destructive) self.setProblem("this ALTER would drop a column of {s}; nothing was changed", .{shaped.targets[0].name});
            }
        }
        if (destructive and !permit.destructive) return error.DestructiveNotGranted;
        try self.simple("COMMIT");
        committed = true;
        const action: engine.WriteAction = switch (statement) {
            .insert => .insert,
            .update, .merge => .update,
            .delete, .truncate => .delete,
            .create_table, .create_table_as, .create_view, .create_matview, .create_index, .create_sequence => .create,
            .drop => .drop,
            .alter_table, .alter_index, .alter_view, .alter_sequence => .alter,
            else => .other,
        };
        const table: ?[]const u8 = if (plan_targets.len != 0) plan_targets[0].name else if (shaped.targets.len != 0) shaped.targets[0].name else null;
        return .{
            .action = action,
            .table = table,
            .changes = if (pg_sql.writesData(statement)) changes else 0,
            .destructive = destructive,
            .elapsed_ms = @intCast(@max(@divTrunc(ns, std.time.ns_per_ms), 0)),
        };
    }

    pub fn roleFacts(self: *Conn, arena: Allocator) !RoleFacts {
        try self.begin(true);
        defer self.rollback();
        const sql =
            \\SELECT r.rolname::text, r.rolsuper::text, coalesce((SELECT bool_or(pg_catalog.has_table_privilege(c.oid, 'INSERT,UPDATE,DELETE,TRUNCATE'))
            \\FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            \\WHERE c.relkind IN ('r','p') AND n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg\_toast%'), false)::text
            \\FROM pg_catalog.pg_roles r WHERE r.rolname = current_user
        ;
        const got = try self.rows(arena, sql, &.{});
        if (got.len == 0) return .{ .superuser = false, .can_write = false, .user = "" };
        return .{ .user = got[0][0] orelse "", .superuser = std.mem.eql(u8, got[0][1] orelse "", "true"), .can_write = std.mem.eql(u8, got[0][2] orelse "", "true") };
    }
};

fn chainTreat(access: Access, chain: []const []const u8, column: []const u8) engine.Treatment {
    return pg_plan.treatmentOf(access, .{ .schema = "", .table = "", .column = column, .chain = chain });
}

fn startTls(conn: *Conn, target: Target, why: *OpenProblem) !void {
    const gpa = conn.gpa;
    const state = try gpa.create(TlsState);
    errdefer gpa.destroy(state);
    state.* = .{ .client = undefined, .read_buf = try gpa.alloc(u8, tls.Client.min_buffer_len), .write_buf = undefined };
    errdefer gpa.free(state.read_buf);
    state.write_buf = try gpa.alloc(u8, 4096);
    errdefer gpa.free(state.write_buf);
    var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
    conn.io.random(&entropy);
    const now = Io.Clock.real.now(conn.io);
    const verify = target.sslmode == .verify_full;
    if (verify) {
        if (target.sslrootcert) |path| {
            state.bundle.addCertsFromFilePathAbsolute(gpa, conn.io, now, path) catch |err| {
                why.set("the sslrootcert file {s} could not be read: {t}", .{ path, err });
                return error.DatabaseUnavailable;
            };
        }
    }
    state.client = tls.Client.init(&conn.link.socket.reader, &conn.link.socket.writer, .{
        .host = if (verify) .{ .explicit = target.host } else .no_verification,
        .ca = if (verify) .{ .bundle = .{ .gpa = gpa, .io = conn.io, .lock = &state.lock, .bundle = &state.bundle } } else .no_verification,
        .read_buffer = state.read_buf,
        .write_buffer = state.write_buf,
        .entropy = &entropy,
        .realtime_now = now,
    }) catch |err| {
        state.bundle.deinit(gpa);
        why.set("the TLS handshake with {s} failed: {t}{s}", .{ target.host, err, if (verify) " (sslmode=verify-full checks the certificate against the Windows root store or sslrootcert, and the host name)" else "" });
        return error.DatabaseUnavailable;
    };
    conn.link.tls = state;
    conn.encrypted = true;
}

fn authenticate(conn: *Conn, target: Target, why: *OpenProblem) !void {
    var scram: ?pg_scram.Client = null;
    while (true) {
        const message = conn.next() catch {
            why.set("{s}", .{conn.problem()});
            return error.DatabaseUnavailable;
        };
        switch (message.tag) {
            'E' => {
                switch (conn.serverError(message.body)) {
                    else => {},
                }
                why.set("{s}", .{conn.problem()});
                return error.DatabaseUnavailable;
            },
            'R' => {
                const auth = pg_wire.parseAuth(message.body) catch {
                    why.set("the server sent a malformed authentication message", .{});
                    return error.DatabaseUnavailable;
                };
                const password = target.password orelse "";
                switch (auth) {
                    .ok => {},
                    .cleartext => {
                        if (!conn.encrypted) {
                            why.set("the server asks for the password in clear text over an unencrypted connection; use sslmode=require or verify-full, or switch the server to scram-sha-256", .{});
                            return error.DatabaseUnavailable;
                        }
                        try pg_wire.writePassword(conn.link.writer(), password);
                        try conn.link.flush();
                    },
                    .md5 => |salt| {
                        if (!conn.encrypted) conn.auth_note = "the server uses md5 password authentication over an unencrypted connection; prefer scram-sha-256 and sslmode=verify-full";
                        var hashed: [35]u8 = undefined;
                        pg_wire.md5Password(&hashed, target.user, password, salt);
                        try pg_wire.writePassword(conn.link.writer(), &hashed);
                        try conn.link.flush();
                    },
                    .sasl => |list| {
                        if (!pg_wire.saslOffers(list, pg_scram.mechanism)) {
                            why.set("the server offers only SASL mechanisms emetgate does not speak (it speaks SCRAM-SHA-256)", .{});
                            return error.DatabaseUnavailable;
                        }
                        var raw: [18]u8 = undefined;
                        conn.io.random(&raw);
                        scram = pg_scram.Client.init(&raw);
                        const first = try scram.?.first("");
                        try pg_wire.writeSaslInitial(conn.link.writer(), pg_scram.mechanism, first);
                        try conn.link.flush();
                    },
                    .sasl_continue => |server_first| {
                        if (scram == null) {
                            why.set("the server sent a SASL message out of order", .{});
                            return error.DatabaseUnavailable;
                        }
                        var out: [512]u8 = undefined;
                        const final = scram.?.final(password, server_first, &out) catch |err| {
                            why.set("SCRAM authentication failed: {t}", .{err});
                            return error.DatabaseUnavailable;
                        };
                        try pg_wire.writeSaslResponse(conn.link.writer(), final);
                        try conn.link.flush();
                    },
                    .sasl_final => |server_final| {
                        if (scram == null) {
                            why.set("the server sent a SASL message out of order", .{});
                            return error.DatabaseUnavailable;
                        }
                        scram.?.verify(server_final) catch {
                            why.set("the server could not prove that it knows the password (SCRAM server signature mismatch), so the connection was dropped", .{});
                            return error.DatabaseUnavailable;
                        };
                        scram = null;
                    },
                    .other => |code| {
                        why.set("the server asks for authentication method {d}, which emetgate does not speak (it speaks scram-sha-256, md5 and, over TLS, password)", .{code});
                        return error.DatabaseUnavailable;
                    },
                }
            },
            'K' => {},
            'Z' => return,
            'v' => {},
            else => {
                why.set("the server sent an unexpected message during startup", .{});
                return error.DatabaseUnavailable;
            },
        }
    }
}

pub fn open(gpa: Allocator, target: Target, settings: engine.Settings, why: *OpenProblem) !*Conn {
    const handle = pg_net.dial(target.host, target.port, connect_timeout_ms) catch |err| {
        why.set("cannot reach {s}:{d}: {t}", .{ target.host, target.port, err });
        return error.DatabaseUnavailable;
    };
    var handed = false;
    defer if (!handed) pg_net.closeHandle(handle);
    const self = try gpa.create(Conn);
    const read_buf = gpa.alloc(u8, tls.Client.min_buffer_len) catch |err| {
        gpa.destroy(self);
        return err;
    };
    const write_buf = gpa.alloc(u8, tls.Client.min_buffer_len) catch |err| {
        gpa.free(read_buf);
        gpa.destroy(self);
        return err;
    };
    self.* = .{
        .gpa = gpa,
        .io = settings.io,
        .link = .{ .socket = undefined, .sock_read = read_buf, .sock_write = write_buf },
        .access = settings.access,
        .limits = settings.limits,
        .mode = settings.mode,
        .derived = .init(gpa),
    };
    self.link.socket.init(handle, read_buf, write_buf, settings.limits.timeout_ms + grace_ms);
    handed = true;
    errdefer self.close();
    if (target.sslmode != .disable) {
        try pg_wire.writeSslRequest(&self.link.socket.writer);
        self.link.socket.writer.flush() catch {
            why.set("the connection to {s} failed while asking for TLS", .{target.host});
            return error.DatabaseUnavailable;
        };
        const answer = self.link.socket.reader.takeByte() catch {
            why.set("the server at {s}:{d} closed the connection when asked for TLS; is it a PostgreSQL server?", .{ target.host, target.port });
            return error.DatabaseUnavailable;
        };
        if (self.link.socket.reader.bufferedLen() != 0) {
            why.set("the server sent data before the TLS handshake; the connection was dropped", .{});
            return error.DatabaseUnavailable;
        }
        if (answer == 'S') {
            try startTls(self, target, why);
        } else if (answer == 'N') {
            if (target.sslmode != .prefer) {
                why.set("the server at {s} does not accept TLS, and sslmode={s} requires it", .{ target.host, target.sslmode.label() });
                return error.DatabaseUnavailable;
            }
        } else {
            why.set("the server answered the TLS request with an unexpected byte; is it a PostgreSQL server?", .{});
            return error.DatabaseUnavailable;
        }
    }
    var timeout_buf: [16]u8 = undefined;
    const timeout = std.fmt.bufPrint(&timeout_buf, "{d}", .{settings.limits.timeout_ms}) catch unreachable;
    var idle_buf: [16]u8 = undefined;
    const idle = std.fmt.bufPrint(&idle_buf, "{d}", .{@as(u64, settings.limits.timeout_ms) * 4 + 60_000}) catch unreachable;
    const params = [_]pg_wire.Param{
        .{ "user", target.user },
        .{ "database", target.database },
        .{ "application_name", "emetgate" },
        .{ "client_encoding", "UTF8" },
        .{ "DateStyle", "ISO, YMD" },
        .{ "standard_conforming_strings", "on" },
        .{ "statement_timeout", timeout },
        .{ "lock_timeout", timeout },
        .{ "idle_in_transaction_session_timeout", idle },
        .{ "default_transaction_read_only", if (settings.mode == .read) "on" else "off" },
    };
    pg_wire.writeStartup(self.link.writer(), &params) catch {
        why.set("the user or database name holds a NUL byte", .{});
        return error.DatabaseUnavailable;
    };
    self.link.flush() catch {
        why.set("the connection to {s} failed during startup", .{target.host});
        return error.DatabaseUnavailable;
    };
    authenticate(self, target, why) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (why.len == 0) why.set("authentication with {s} failed: {t}", .{ target.host, err });
        return error.DatabaseUnavailable;
    };
    return self;
}

fn vClose(ptr: *anyopaque) void {
    const self: *Conn = @ptrCast(@alignCast(ptr));
    self.close();
}

fn vProblem(ptr: *anyopaque) []const u8 {
    const self: *Conn = @ptrCast(@alignCast(ptr));
    return self.problem();
}

fn vTables(ptr: *anyopaque, arena: Allocator) anyerror!engine.Tables {
    const self: *Conn = @ptrCast(@alignCast(ptr));
    return self.tables(arena);
}

fn vDescribe(ptr: *anyopaque, arena: Allocator, table: []const u8) anyerror!engine.Description {
    const self: *Conn = @ptrCast(@alignCast(ptr));
    return self.describe(arena, table);
}

fn vCount(ptr: *anyopaque, arena: Allocator, table: []const u8) anyerror!i64 {
    const self: *Conn = @ptrCast(@alignCast(ptr));
    return self.count(arena, table);
}

fn vSample(ptr: *anyopaque, arena: Allocator, table: []const u8, wanted: u32, sink: engine.Sink) anyerror!engine.Outcome {
    const self: *Conn = @ptrCast(@alignCast(ptr));
    return self.sample(arena, table, wanted, sink);
}

fn vQuery(ptr: *anyopaque, arena: Allocator, sql: []const u8, sink: engine.Sink) anyerror!engine.Outcome {
    const self: *Conn = @ptrCast(@alignCast(ptr));
    return self.query(arena, sql, sink);
}

fn vExplain(ptr: *anyopaque, arena: Allocator, sql: []const u8) anyerror![]const []const u8 {
    const self: *Conn = @ptrCast(@alignCast(ptr));
    return self.explain(arena, sql);
}

fn vWrite(ptr: *anyopaque, arena: Allocator, sql: []const u8, permit: engine.Permit) anyerror!engine.WriteOutcome {
    const self: *Conn = @ptrCast(@alignCast(ptr));
    return self.write(arena, sql, permit);
}

const vtable: engine.Connection.VTable = .{
    .close = vClose,
    .problem = vProblem,
    .tables = vTables,
    .describe = vDescribe,
    .count = vCount,
    .sample = vSample,
    .query = vQuery,
    .explain = vExplain,
    .write = vWrite,
};

const testing = std.testing;

test "pg url: host, port, database, user, password and sslmode parse, and unknown parameters are refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const t = try parseUrl(arena, "postgres://app:p%40ss%3Aw@db.local:6543/shop?sslmode=verify-full&sslrootcert=C%3A%5Cca.pem");
    try testing.expectEqualStrings("app", t.user);
    try testing.expectEqualStrings("p@ss:w", t.password.?);
    try testing.expectEqualStrings("db.local", t.host);
    try testing.expectEqual(@as(u16, 6543), t.port);
    try testing.expectEqualStrings("shop", t.database);
    try testing.expectEqual(SslMode.verify_full, t.sslmode);
    try testing.expectEqualStrings("C:\\ca.pem", t.sslrootcert.?);
    const plain = try parseUrl(arena, "postgresql://reader@[::1]/app");
    try testing.expectEqualStrings("::1", plain.host);
    try testing.expectEqual(default_port, plain.port);
    try testing.expectEqual(SslMode.prefer, plain.sslmode);
    try testing.expect(plain.password == null);
    try testing.expectError(error.InvalidUrl, parseUrl(arena, "postgres://u@h/db?sslmode=verify-ca"));
    try testing.expectError(error.InvalidUrl, parseUrl(arena, "postgres://u@h/db?options=-c%20role%3Dpostgres"));
    try testing.expectError(error.InvalidUrl, parseUrl(arena, "postgres://h/db"));
    try testing.expectError(error.InvalidUrl, parseUrl(arena, "mysql://u@h/db"));
    try testing.expectEqualStrings("postgres://u:a%20b%40c@h:5/db?sslmode=require", try withPassword(arena, "postgres://u@h:5/db?sslmode=require", "a b@c"));
    try testing.expectEqualStrings("postgres://u:x@h/db", try withPassword(arena, "postgres://u:x@h/db", "other"));
}
