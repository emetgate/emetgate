const std = @import("std");
const c = @import("c");
const access_mod = @import("access.zig");
const engine = @import("engine.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Access = access_mod.Access;
const Mask = access_mod.Mask;

pub const max_sql_bytes = 100_000;
pub const max_value_bytes = 16 * 1024 * 1024;
pub const heap_limit: i64 = 512 * 1024 * 1024;
pub const progress_ops = 1000;
pub const busy_ms = 1000;
const savepoint_name = "emetgate_db_write";
const whitespace = " \t\r\n";

pub const allowed_functions = std.StaticStringMap(void).initComptime(.{
    .{"abs"},               .{"char"},             .{"coalesce"},          .{"concat"},           .{"concat_ws"},
    .{"format"},            .{"printf"},           .{"glob"},              .{"hex"},              .{"ifnull"},
    .{"iif"},               .{"if"},               .{"instr"},             .{"length"},           .{"like"},
    .{"likelihood"},        .{"likely"},           .{"lower"},             .{"ltrim"},            .{"max"},
    .{"min"},               .{"nullif"},           .{"octet_length"},      .{"quote"},            .{"random"},
    .{"randomblob"},        .{"replace"},          .{"round"},             .{"rtrim"},            .{"sign"},
    .{"substr"},            .{"substring"},        .{"trim"},              .{"typeof"},           .{"unhex"},
    .{"unicode"},           .{"unlikely"},         .{"upper"},             .{"zeroblob"},         .{"avg"},
    .{"count"},             .{"group_concat"},     .{"string_agg"},        .{"sum"},              .{"total"},
    .{"date"},              .{"time"},             .{"datetime"},          .{"julianday"},        .{"unixepoch"},
    .{"strftime"},          .{"timediff"},         .{"row_number"},        .{"rank"},             .{"dense_rank"},
    .{"percent_rank"},      .{"cume_dist"},        .{"ntile"},             .{"lag"},              .{"lead"},
    .{"first_value"},       .{"last_value"},       .{"nth_value"},         .{"json"},             .{"jsonb"},
    .{"json_array"},        .{"json_array_length"}, .{"json_extract"},     .{"json_insert"},      .{"json_object"},
    .{"json_patch"},        .{"json_remove"},      .{"json_replace"},      .{"json_set"},         .{"json_type"},
    .{"json_valid"},        .{"json_quote"},       .{"json_group_array"},  .{"json_group_object"}, .{"json_pretty"},
    .{"json_error_position"}, .{"->"},             .{"->>"},               .{"acos"},             .{"acosh"},
    .{"asin"},              .{"asinh"},            .{"atan"},              .{"atan2"},            .{"atanh"},
    .{"ceil"},              .{"ceiling"},          .{"cos"},               .{"cosh"},             .{"degrees"},
    .{"exp"},               .{"floor"},            .{"ln"},                .{"log"},              .{"log10"},
    .{"log2"},              .{"mod"},              .{"pi"},                .{"pow"},              .{"power"},
    .{"radians"},           .{"sin"},              .{"sinh"},              .{"sqrt"},             .{"tan"},
    .{"tanh"},              .{"trunc"},            .{"last_insert_rowid"}, .{"sqlite_version"},   .{"changes"},
    .{"current_timestamp"}, .{"current_date"}, .{"current_time"},
});

pub const schema_rewrite_functions = std.StaticStringMap(void).initComptime(.{
    .{"sqlite_rename_column"}, .{"sqlite_rename_table"}, .{"sqlite_rename_test"}, .{"sqlite_drop_column"}, .{"sqlite_rename_quotefix"},
});

const Phase = enum { internal, user, probe, running };

const Denial = enum { table, function, action, hidden_write, masked_write, destructive, reprepared };

const MaskedRead = struct { table: []const u8, column: []const u8, count: u32 };

const Target = struct { action: engine.WriteAction, table: []const u8 };

const Guard = struct {
    phase: Phase = .internal,
    mode: engine.Mode = .read,
    permit: engine.Permit = .{},
    saw_select: bool = false,
    probe_hit: bool = false,
    failed_memory: bool = false,
    denial: ?Denial = null,
    refusal: ?access_mod.Refusal = null,
    denied_buf: [256]u8 = undefined,
    denied_len: usize = 0,
    reads: std.ArrayList(MaskedRead) = .empty,
    nulled: std.ArrayList([]const u8) = .empty,
    targets: std.ArrayList(Target) = .empty,

    fn denied(self: *const Guard) []const u8 {
        return self.denied_buf[0..self.denied_len];
    }
};

pub const Conn = struct {
    gpa: Allocator,
    io: std.Io,
    db: *c.sqlite3,
    access: Access,
    limits: engine.Limits,
    mode: engine.Mode,
    guard: Guard = .{},
    scratch: std.heap.ArenaAllocator,
    derived: std.heap.ArenaAllocator,
    derived_hidden: []const access_mod.Column = &.{},
    deadline_ns: i96 = 0,
    timed_out: bool = false,
    problem_buf: [2048]u8 = undefined,
    problem_len: usize = 0,

    pub fn connection(self: *Conn) engine.Connection {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn setProblem(self: *Conn, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(&self.problem_buf, fmt, args) catch self.problem_buf[0..];
        self.problem_len = written.len;
    }

    pub fn problem(self: *const Conn) []const u8 {
        return self.problem_buf[0..self.problem_len];
    }

    fn sqlFailed(self: *Conn) engine.Error {
        self.setProblem("{s}", .{std.mem.span(c.sqlite3_errmsg(self.db))});
        return error.SqlFailed;
    }

    pub fn close(self: *Conn) void {
        _ = c.sqlite3_close_v2(self.db);
        self.guard.reads.deinit(self.gpa);
        self.guard.nulled.deinit(self.gpa);
        self.guard.targets.deinit(self.gpa);
        self.scratch.deinit();
        self.derived.deinit();
        self.gpa.destroy(self);
    }

    fn isHidden(self: *const Conn, table: []const u8, column: []const u8) bool {
        if (self.access.isHidden(table, column)) return true;
        for (self.derived_hidden) |derived| {
            if (derived.matches(table, column)) return true;
        }
        return false;
    }

    fn treatment(self: *const Conn, table: []const u8, column: []const u8) engine.Treatment {
        if (self.isHidden(table, column)) return .hidden;
        if (self.access.maskOf(table, column)) |mask| return .{ .masked = mask };
        return .plain;
    }

    fn deny(self: *Conn, kind: Denial, name: []const u8) c_int {
        if (self.guard.denial == null) {
            self.guard.denial = kind;
            const n = @min(name.len, self.guard.denied_buf.len);
            @memcpy(self.guard.denied_buf[0..n], name[0..n]);
            self.guard.denied_len = n;
        }
        return c.SQLITE_DENY;
    }

    fn tableCheck(self: *Conn, table: []const u8) ?c_int {
        if (table.len == 0) return null;
        if (self.guard.mode == .write and isSchemaTable(table) and !self.access.isBlocked(table)) return null;
        if (self.access.tableRefusal(table)) |refusal| {
            if (self.guard.denial == null) self.guard.refusal = refusal;
            return self.deny(.table, table);
        }
        return null;
    }

    fn record(self: *Conn, action: engine.WriteAction, table: []const u8, context: []const u8) void {
        if (context.len != 0 or isSchemaTable(table)) return;
        for (self.guard.targets.items) |known| {
            if (known.action == action and std.ascii.eqlIgnoreCase(known.table, table)) return;
        }
        const owned = self.scratch.allocator().dupe(u8, table) catch {
            self.guard.failed_memory = true;
            return;
        };
        self.guard.targets.append(self.gpa, .{ .action = action, .table = owned }) catch {
            self.guard.failed_memory = true;
        };
    }

    fn noteNulled(self: *Conn, table: []const u8, column: []const u8) void {
        if (column.len == 0) return;
        var buf: [300]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "{s}.{s}", .{ table, column }) catch return;
        for (self.guard.nulled.items) |known| {
            if (std.ascii.eqlIgnoreCase(known, name)) return;
        }
        const owned = self.scratch.allocator().dupe(u8, name) catch {
            self.guard.failed_memory = true;
            return;
        };
        self.guard.nulled.append(self.gpa, owned) catch {
            self.guard.failed_memory = true;
        };
    }

    fn countRead(self: *Conn, table: []const u8, column: []const u8) void {
        for (self.guard.reads.items) |*seen| {
            if (std.ascii.eqlIgnoreCase(seen.table, table) and std.ascii.eqlIgnoreCase(seen.column, column)) {
                seen.count += 1;
                return;
            }
        }
        const arena = self.scratch.allocator();
        const owned_table = arena.dupe(u8, table) catch {
            self.guard.failed_memory = true;
            return;
        };
        const owned_column = arena.dupe(u8, column) catch {
            self.guard.failed_memory = true;
            return;
        };
        self.guard.reads.append(self.gpa, .{ .table = owned_table, .column = owned_column, .count = 1 }) catch {
            self.guard.failed_memory = true;
        };
    }

    fn decide(self: *Conn, action: c_int, a1: []const u8, a2: []const u8, a4: []const u8) c_int {
        switch (self.guard.phase) {
            .internal => return c.SQLITE_OK,
            .probe => {
                self.guard.probe_hit = true;
                return c.SQLITE_DENY;
            },
            .running => return self.deny(.reprepared, "the running statement"),
            .user => {},
        }
        if (self.guard.failed_memory) return c.SQLITE_DENY;
        const writing = self.guard.mode == .write;
        switch (action) {
            c.SQLITE_SELECT => {
                self.guard.saw_select = true;
                return c.SQLITE_OK;
            },
            c.SQLITE_RECURSIVE => return c.SQLITE_OK,
            c.SQLITE_READ => return self.read(a1, a2, a4),
            c.SQLITE_FUNCTION => {
                var buf: [64]u8 = undefined;
                if (a2.len > buf.len) return self.deny(.function, a2);
                const lower = std.ascii.lowerString(&buf, a2);
                if (allowed_functions.has(lower)) return c.SQLITE_OK;
                if (writing and schema_rewrite_functions.has(lower)) return c.SQLITE_OK;
                return self.deny(.function, a2);
            },
            c.SQLITE_INSERT, c.SQLITE_DELETE => {
                if (!writing) return self.deny(.action, actionName(action));
                if (self.tableCheck(a1)) |refused| return refused;
                self.record(if (action == c.SQLITE_INSERT) .insert else .delete, a1, a4);
                return c.SQLITE_OK;
            },
            c.SQLITE_UPDATE => {
                if (!writing) return self.deny(.action, actionName(action));
                if (self.tableCheck(a1)) |refused| return refused;
                if (self.isHidden(a1, a2)) return self.deny(.hidden_write, a2);
                self.record(.update, a1, a4);
                return c.SQLITE_OK;
            },
            c.SQLITE_CREATE_TABLE, c.SQLITE_CREATE_TEMP_TABLE, c.SQLITE_CREATE_VIEW, c.SQLITE_CREATE_TEMP_VIEW => {
                if (!writing) return self.deny(.action, actionName(action));
                if (self.tableCheck(a1)) |refused| return refused;
                self.record(.create, a1, a4);
                return c.SQLITE_OK;
            },
            c.SQLITE_CREATE_INDEX, c.SQLITE_CREATE_TEMP_INDEX, c.SQLITE_CREATE_TRIGGER, c.SQLITE_CREATE_TEMP_TRIGGER => {
                if (!writing) return self.deny(.action, actionName(action));
                if (self.tableCheck(a2)) |refused| return refused;
                self.record(.create, a2, a4);
                return c.SQLITE_OK;
            },
            c.SQLITE_DROP_TABLE, c.SQLITE_DROP_TEMP_TABLE, c.SQLITE_DROP_VIEW, c.SQLITE_DROP_TEMP_VIEW, c.SQLITE_DROP_INDEX, c.SQLITE_DROP_TEMP_INDEX, c.SQLITE_DROP_TRIGGER, c.SQLITE_DROP_TEMP_TRIGGER => {
                if (!writing) return self.deny(.action, actionName(action));
                const table = if (action == c.SQLITE_DROP_INDEX or action == c.SQLITE_DROP_TEMP_INDEX or action == c.SQLITE_DROP_TRIGGER or action == c.SQLITE_DROP_TEMP_TRIGGER) a2 else a1;
                if (self.tableCheck(table)) |refused| return refused;
                if (!self.guard.permit.destructive) return self.deny(.destructive, a1);
                self.record(.drop, a1, a4);
                return c.SQLITE_OK;
            },
            c.SQLITE_ALTER_TABLE => {
                if (!writing) return self.deny(.action, actionName(action));
                if (self.tableCheck(a2)) |refused| return refused;
                self.record(.alter, a2, a4);
                return c.SQLITE_OK;
            },
            c.SQLITE_REINDEX, c.SQLITE_ANALYZE => {
                if (!writing) return self.deny(.action, actionName(action));
                return c.SQLITE_OK;
            },
            else => return self.deny(.action, actionName(action)),
        }
    }

    fn read(self: *Conn, table: []const u8, column: []const u8, context: []const u8) c_int {
        if (self.tableCheck(context)) |refused| return refused;
        if (self.tableCheck(table)) |refused| return refused;
        const writing = self.guard.mode == .write;
        if (self.isHidden(table, column)) {
            if (writing) return self.deny(.hidden_write, column);
            self.noteNulled(table, column);
            return c.SQLITE_IGNORE;
        }
        if (self.access.maskOf(table, column) != null) {
            if (writing) return self.deny(.masked_write, column);
            self.countRead(table, column);
        }
        return c.SQLITE_OK;
    }

    fn resetGuard(self: *Conn, mode: engine.Mode) void {
        self.guard.reads.clearRetainingCapacity();
        self.guard.nulled.clearRetainingCapacity();
        self.guard.targets.clearRetainingCapacity();
        _ = self.scratch.reset(.retain_capacity);
        self.guard.mode = mode;
        self.guard.saw_select = false;
        self.guard.probe_hit = false;
        self.guard.failed_memory = false;
        self.guard.denial = null;
        self.guard.refusal = null;
        self.guard.denied_len = 0;
    }

    fn refusalError(self: *Conn) engine.Error {
        const name = self.guard.denied();
        const kind = self.guard.denial orelse return self.sqlFailed();
        switch (kind) {
            .table => {
                const why = if (self.guard.refusal == .not_allowed) "is not on the allowed table list" else "is blocked";
                self.setProblem("table {s} {s} by the database access rules", .{ name, why });
                return error.TableRefused;
            },
            .function => {
                self.setProblem("function {s} is not on the allowed function list", .{name});
                return error.FunctionDenied;
            },
            .action => {
                if (self.guard.mode == .read) {
                    self.setProblem("this connection only reads: {s} is not allowed", .{name});
                    return error.StatementNotRead;
                }
                self.setProblem("{s} is not allowed, even with write mode", .{name});
                return error.ActionDenied;
            },
            .hidden_write => {
                self.setProblem("column {s} is hidden: a write may not read or change it", .{name});
                return error.GuardedColumnInWrite;
            },
            .masked_write => {
                self.setProblem("column {s} is masked: a write may not read it", .{name});
                return error.GuardedColumnInWrite;
            },
            .destructive => {
                self.setProblem("dropping {s} is destructive", .{name});
                return error.DestructiveNotGranted;
            },
            .reprepared => {
                self.setProblem("the database schema changed while the statement ran, so it was stopped; run it again", .{});
                return error.SqlFailed;
            },
        }
    }

    fn prepareUser(self: *Conn, sql: []const u8, mode: engine.Mode) engine.Error!*c.sqlite3_stmt {
        if (sql.len > max_sql_bytes) {
            self.setProblem("the statement is {d} bytes, over the limit of {d}", .{ sql.len, max_sql_bytes });
            return error.SqlFailed;
        }
        self.resetGuard(mode);
        self.guard.phase = .user;
        defer self.guard.phase = .internal;
        var stmt: ?*c.sqlite3_stmt = null;
        var tail: [*c]const u8 = null;
        const rc = c.sqlite3_prepare_v3(self.db, sql.ptr, @intCast(sql.len), 0, &stmt, &tail);
        if (rc != c.SQLITE_OK) {
            _ = c.sqlite3_finalize(stmt);
            if (self.guard.denial != null) return self.refusalError();
            if (self.guard.failed_memory) {
                self.setProblem("out of memory while checking the statement", .{});
                return error.SqlFailed;
            }
            return self.sqlFailed();
        }
        const prepared = stmt orelse {
            self.setProblem("the statement is empty", .{});
            return error.EmptyStatement;
        };
        errdefer _ = c.sqlite3_finalize(prepared);
        if (self.guard.failed_memory) {
            self.setProblem("out of memory while checking the statement", .{});
            return error.SqlFailed;
        }
        const used: usize = if (tail == null) sql.len else @intFromPtr(tail) - @intFromPtr(sql.ptr);
        if (!self.restIsEmpty(sql[@min(used, sql.len)..])) {
            self.setProblem("send one statement per call; text after the first statement is not run", .{});
            return error.MultipleStatements;
        }
        return prepared;
    }

    fn restIsEmpty(self: *Conn, rest_in: []const u8) bool {
        var rest = rest_in;
        self.guard.phase = .probe;
        defer self.guard.phase = .user;
        while (std.mem.trim(u8, rest, whitespace).len != 0) {
            var stmt: ?*c.sqlite3_stmt = null;
            var tail: [*c]const u8 = null;
            const rc = c.sqlite3_prepare_v3(self.db, rest.ptr, @intCast(rest.len), 0, &stmt, &tail);
            if (stmt != null) {
                _ = c.sqlite3_finalize(stmt);
                return false;
            }
            if (rc != c.SQLITE_OK or self.guard.probe_hit) return false;
            if (tail == null) return true;
            const used = @intFromPtr(tail) - @intFromPtr(rest.ptr);
            if (used == 0 or used > rest.len) return false;
            rest = rest[used..];
        }
        return true;
    }

    fn arm(self: *Conn) void {
        self.guard.phase = .running;
        self.timed_out = false;
        self.deadline_ns = std.Io.Timestamp.now(self.io, .awake).nanoseconds + @as(i96, self.limits.timeout_ms) * std.time.ns_per_ms;
        c.sqlite3_progress_handler(self.db, progress_ops, progress, self);
    }

    fn disarm(self: *Conn) void {
        self.guard.phase = .internal;
        c.sqlite3_progress_handler(self.db, 0, null, null);
    }

    fn elapsedSince(self: *const Conn, started: std.Io.Timestamp) u64 {
        const ns = started.durationTo(std.Io.Timestamp.now(self.io, .awake)).nanoseconds;
        return @intCast(@max(@divTrunc(ns, std.time.ns_per_ms), 0));
    }

    fn stepFailed(self: *Conn, rc: c_int) engine.Error {
        if (self.timed_out or rc == c.SQLITE_INTERRUPT) {
            self.setProblem("the statement ran past the {d} ms timeout and was stopped", .{self.limits.timeout_ms});
            return error.QueryTimeout;
        }
        if (self.guard.denial == .reprepared) return self.refusalError();
        return self.sqlFailed();
    }

    fn resultColumns(self: *Conn, arena: Allocator, stmt: *c.sqlite3_stmt) ![]engine.ResultColumn {
        const n: usize = @intCast(c.sqlite3_column_count(stmt));
        const columns = try arena.alloc(engine.ResultColumn, n);
        for (columns, 0..) |*column, i| {
            const index: c_int = @intCast(i);
            const name = c.sqlite3_column_name(stmt, index);
            const table = c.sqlite3_column_table_name(stmt, index);
            const origin = c.sqlite3_column_origin_name(stmt, index);
            column.* = .{ .name = if (name == null) "?" else try arena.dupe(u8, std.mem.span(name)) };
            if (table != null and origin != null) {
                column.table = try arena.dupe(u8, std.mem.span(table));
                column.origin = try arena.dupe(u8, std.mem.span(origin));
                column.treatment = self.treatment(column.table.?, column.origin.?);
            }
        }
        return columns;
    }

    fn checkMasked(self: *Conn, columns: []const engine.ResultColumn) engine.Error!void {
        for (self.guard.reads.items) |seen| {
            var direct: u32 = 0;
            for (columns) |column| {
                const table = column.table orelse continue;
                const origin = column.origin orelse continue;
                if (std.ascii.eqlIgnoreCase(table, seen.table) and std.ascii.eqlIgnoreCase(origin, seen.column)) direct += 1;
            }
            if (seen.count > direct) {
                self.setProblem("{s}.{s} is masked, so it may appear only as a plain result column: not in WHERE, JOIN, GROUP BY, ORDER BY or any expression or function", .{ seen.table, seen.column });
                return error.MaskedColumnUsed;
            }
        }
    }

    fn prepareRead(self: *Conn, arena: Allocator, sql: []const u8) engine.Error!struct { stmt: *c.sqlite3_stmt, columns: []engine.ResultColumn } {
        const stmt = try self.prepareUser(sql, .read);
        errdefer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_stmt_readonly(stmt) == 0 or (!self.guard.saw_select and c.sqlite3_stmt_isexplain(stmt) == 0)) {
            self.setProblem("only a SELECT (or WITH ... SELECT) reads; this statement would do something else", .{});
            return error.StatementNotRead;
        }
        const columns = self.resultColumns(arena, stmt) catch {
            self.setProblem("out of memory", .{});
            return error.SqlFailed;
        };
        try self.checkMasked(columns);
        return .{ .stmt = stmt, .columns = columns };
    }

    fn run(self: *Conn, arena: Allocator, stmt: *c.sqlite3_stmt, columns: []const engine.ResultColumn, max_rows: u32, sink: engine.Sink) !engine.Outcome {
        const started = std.Io.Timestamp.now(self.io, .awake);
        try sink.begin(sink.ptr, columns);
        const values = try arena.alloc(engine.Value, columns.len);
        var row_arena = std.heap.ArenaAllocator.init(self.gpa);
        defer row_arena.deinit();
        var outcome: engine.Outcome = .{};
        const nulled = try arena.alloc([]const u8, self.guard.nulled.items.len);
        for (nulled, self.guard.nulled.items) |*slot, name| slot.* = try arena.dupe(u8, name);
        outcome.nulled = nulled;
        self.arm();
        defer self.disarm();
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return self.stepFailed(rc);
            if (outcome.rows >= max_rows) {
                outcome.more = true;
                outcome.stop = .rows;
                break;
            }
            _ = row_arena.reset(.retain_capacity);
            for (values, columns, 0..) |*value, column, i| value.* = try cellValue(row_arena.allocator(), stmt, @intCast(i), column.treatment);
            if (!try sink.row(sink.ptr, values)) {
                outcome.more = true;
                outcome.stop = .bytes;
                break;
            }
            outcome.rows += 1;
        }
        outcome.elapsed_ms = self.elapsedSince(started);
        return outcome;
    }

    pub fn query(self: *Conn, arena: Allocator, sql: []const u8, sink: engine.Sink) !engine.Outcome {
        const prepared = try self.prepareRead(arena, sql);
        defer _ = c.sqlite3_finalize(prepared.stmt);
        return self.run(arena, prepared.stmt, prepared.columns, self.limits.max_rows, sink);
    }

    pub fn sample(self: *Conn, arena: Allocator, table: []const u8, rows: u32, sink: engine.Sink) !engine.Outcome {
        const sql = try std.fmt.allocPrint(arena, "SELECT * FROM {f}", .{quoted(table)});
        const prepared = try self.prepareRead(arena, sql);
        defer _ = c.sqlite3_finalize(prepared.stmt);
        return self.run(arena, prepared.stmt, prepared.columns, @min(rows, self.limits.max_rows), sink);
    }

    pub fn count(self: *Conn, arena: Allocator, table: []const u8) !i64 {
        const sql = try std.fmt.allocPrint(arena, "SELECT count(*) FROM {f}", .{quoted(table)});
        const stmt = try self.prepareUser(sql, .read);
        defer _ = c.sqlite3_finalize(stmt);
        self.arm();
        defer self.disarm();
        const rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_ROW) return self.stepFailed(rc);
        return c.sqlite3_column_int64(stmt, 0);
    }

    pub fn explain(self: *Conn, arena: Allocator, sql: []const u8) ![]const []const u8 {
        const stmt = try self.prepareUser(sql, .read);
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_stmt_readonly(stmt) == 0 or !self.guard.saw_select) {
            self.setProblem("only a SELECT (or WITH ... SELECT) can be explained here", .{});
            return error.StatementNotRead;
        }
        if (c.sqlite3_stmt_explain(stmt, 2) != c.SQLITE_OK) return self.sqlFailed();
        var lines: std.ArrayList([]const u8) = .empty;
        var depths: std.AutoHashMapUnmanaged(i64, usize) = .empty;
        self.arm();
        defer self.disarm();
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return self.stepFailed(rc);
            const id = c.sqlite3_column_int64(stmt, 0);
            const parent = c.sqlite3_column_int64(stmt, 1);
            const depth: usize = if (depths.get(parent)) |d| d + 1 else 0;
            try depths.put(arena, id, depth);
            const detail = textAt(stmt, 3);
            const line = try arena.alloc(u8, depth * 2 + detail.len);
            @memset(line[0 .. depth * 2], ' ');
            @memcpy(line[depth * 2 ..], detail);
            try lines.append(arena, line);
        }
        return lines.items;
    }

    fn exec(self: *Conn, sql: [:0]const u8) engine.Error!void {
        const phase = self.guard.phase;
        self.guard.phase = .internal;
        defer self.guard.phase = phase;
        if (c.sqlite3_exec(self.db, sql.ptr, null, null, null) != c.SQLITE_OK) return self.sqlFailed();
    }

    fn internalInt(self: *Conn, arena: Allocator, comptime fmt: []const u8, name: []const u8) !?i64 {
        const sql = try std.fmt.allocPrint(arena, fmt, .{quoted(name)});
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) {
            _ = c.sqlite3_finalize(stmt);
            return null;
        }
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return c.sqlite3_column_int64(stmt, 0);
    }

    fn columnCount(self: *Conn, table: []const u8) ?i64 {
        const stmt = self.bound("SELECT count(*) FROM pragma_table_xinfo(?1)", table) catch return null;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        const n = c.sqlite3_column_int64(stmt, 0);
        return if (n == 0) null else n;
    }

    pub fn write(self: *Conn, arena: Allocator, sql: []const u8, permit: engine.Permit) !engine.WriteOutcome {
        if (self.mode != .write) {
            self.setProblem("this connection was opened read-only", .{});
            return error.ActionDenied;
        }
        self.guard.permit = permit;
        defer self.guard.permit = .{};
        const stmt = try self.prepareUser(sql, .write);
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_stmt_readonly(stmt) != 0) {
            self.setProblem("this statement only reads; it changes nothing", .{});
            return error.StatementOnlyReads;
        }
        const targets = try arena.dupe(Target, self.guard.targets.items);
        const before = try arena.alloc(?i64, targets.len);
        try self.exec("SAVEPOINT " ++ savepoint_name);
        var kept = false;
        defer if (!kept) {
            self.exec("ROLLBACK TO " ++ savepoint_name) catch {};
            self.exec("RELEASE " ++ savepoint_name) catch {};
        };
        self.guard.phase = .internal;
        for (targets, before) |target, *slot| slot.* = switch (target.action) {
            .delete, .update => try self.internalInt(arena, "SELECT count(*) FROM {f}", target.table),
            .alter => self.columnCount(target.table),
            else => null,
        };
        const started = std.Io.Timestamp.now(self.io, .awake);
        self.arm();
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) {
                self.disarm();
                return self.stepFailed(rc);
            }
        }
        self.disarm();
        const elapsed = self.elapsedSince(started);
        const primary: ?Target = if (targets.len == 0) null else targets[0];
        const action: engine.WriteAction = if (primary) |p| p.action else .other;
        const dml = action == .insert or action == .update or action == .delete;
        const changes: i64 = if (dml) c.sqlite3_changes64(self.db) else 0;
        var destructive = false;
        for (targets) |target| destructive = destructive or target.action == .drop;
        for (targets, before) |target, was| {
            const rows_before = was orelse continue;
            switch (target.action) {
                .delete => {
                    const after = (try self.internalInt(arena, "SELECT count(*) FROM {f}", target.table)) orelse continue;
                    if (rows_before >= 2 and after == 0) {
                        destructive = true;
                        if (!permit.destructive) self.setProblem("this DELETE would remove every row of {s} ({d} rows); nothing was changed", .{ target.table, rows_before });
                    }
                },
                .update => {
                    if (rows_before >= 2 and changes >= rows_before) {
                        destructive = true;
                        if (!permit.destructive) self.setProblem("this UPDATE would change every row of {s} ({d} rows); nothing was changed", .{ target.table, rows_before });
                    }
                },
                .alter => {
                    const after = self.columnCount(target.table) orelse continue;
                    if (after < rows_before) {
                        destructive = true;
                        if (!permit.destructive) self.setProblem("this ALTER would drop a column of {s}; nothing was changed", .{target.table});
                    }
                },
                else => {},
            }
        }
        if (destructive and !permit.destructive) return error.DestructiveNotGranted;
        try self.exec("RELEASE " ++ savepoint_name);
        kept = true;
        return .{
            .action = action,
            .table = if (primary) |p| try arena.dupe(u8, p.table) else null,
            .changes = changes,
            .destructive = destructive,
            .elapsed_ms = elapsed,
        };
    }

    pub fn tables(self: *Conn, arena: Allocator) !engine.Tables {
        const sql = "SELECT name, type FROM sqlite_schema WHERE type IN ('table','view') AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY name COLLATE NOCASE";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return self.sqlFailed();
        defer _ = c.sqlite3_finalize(stmt);
        var shown: std.ArrayList(engine.TableInfo) = .empty;
        var withheld: usize = 0;
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return self.sqlFailed();
            const name = textAt(stmt.?, 0);
            if (self.access.tableRefusal(name) != null) {
                withheld += 1;
                continue;
            }
            const kind: engine.TableKind = if (std.mem.eql(u8, textAt(stmt.?, 1), "view")) .view else .table;
            try shown.append(arena, .{ .name = try arena.dupe(u8, name), .kind = kind });
        }
        return .{ .shown = shown.items, .withheld = withheld };
    }

    fn lookup(self: *Conn, arena: Allocator, table: []const u8) !struct { name: []const u8, kind: engine.TableKind } {
        if (self.access.tableRefusal(table)) |refusal| {
            self.guard.refusal = refusal;
            self.guard.denial = .table;
            const n = @min(table.len, self.guard.denied_buf.len);
            @memcpy(self.guard.denied_buf[0..n], table[0..n]);
            self.guard.denied_len = n;
            return self.refusalError();
        }
        const sql = "SELECT name, type FROM sqlite_schema WHERE type IN ('table','view') AND name = ?1 COLLATE NOCASE";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return self.sqlFailed();
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, table.ptr, @intCast(table.len), null);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) {
            self.setProblem("no table or view named {s}", .{table});
            return error.TableNotFound;
        }
        const kind: engine.TableKind = if (std.mem.eql(u8, textAt(stmt.?, 1), "view")) .view else .table;
        return .{ .name = try arena.dupe(u8, textAt(stmt.?, 0)), .kind = kind };
    }

    pub fn describe(self: *Conn, arena: Allocator, table_in: []const u8) !engine.Description {
        const found = try self.lookup(arena, table_in);
        const table = found.name;
        var columns: std.ArrayList(engine.ColumnInfo) = .empty;
        {
            const stmt = try self.bound("SELECT name, type, \"notnull\", dflt_value, pk, hidden FROM pragma_table_xinfo(?1)", table);
            defer _ = c.sqlite3_finalize(stmt);
            while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                const hidden_kind = c.sqlite3_column_int(stmt, 5);
                if (hidden_kind == 1) continue;
                const name = try arena.dupe(u8, textAt(stmt, 0));
                const how = self.treatment(table, name);
                try columns.append(arena, .{
                    .name = name,
                    .decl_type = try arena.dupe(u8, textAt(stmt, 1)),
                    .not_null = c.sqlite3_column_int(stmt, 2) != 0,
                    .default = if (how != .plain or c.sqlite3_column_type(stmt, 3) == c.SQLITE_NULL) null else try arena.dupe(u8, textAt(stmt, 3)),
                    .primary_key = @intCast(@max(c.sqlite3_column_int(stmt, 4), 0)),
                    .generated = hidden_kind == 2 or hidden_kind == 3,
                    .treatment = how,
                });
            }
        }
        var indexes: std.ArrayList(engine.IndexInfo) = .empty;
        {
            const stmt = try self.bound("SELECT name, \"unique\" FROM pragma_index_list(?1) ORDER BY name", table);
            defer _ = c.sqlite3_finalize(stmt);
            while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                const name = try arena.dupe(u8, textAt(stmt, 0));
                const unique = c.sqlite3_column_int(stmt, 1) != 0;
                var names: std.ArrayList([]const u8) = .empty;
                const inner = try self.bound("SELECT coalesce(name, '<expression>') FROM pragma_index_info(?1) ORDER BY seqno", name);
                defer _ = c.sqlite3_finalize(inner);
                while (c.sqlite3_step(inner) == c.SQLITE_ROW) try names.append(arena, try arena.dupe(u8, textAt(inner, 0)));
                try indexes.append(arena, .{ .name = name, .unique = unique, .columns = names.items });
            }
        }
        var keys: std.ArrayList(engine.ForeignKey) = .empty;
        {
            const stmt = try self.bound("SELECT \"from\", \"table\", \"to\" FROM pragma_foreign_key_list(?1) ORDER BY id, seq", table);
            defer _ = c.sqlite3_finalize(stmt);
            while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                const target = textAt(stmt, 1);
                if (self.access.tableRefusal(target) != null) continue;
                try keys.append(arena, .{
                    .from = try arena.dupe(u8, textAt(stmt, 0)),
                    .table = try arena.dupe(u8, target),
                    .to = if (c.sqlite3_column_type(stmt, 2) == c.SQLITE_NULL) null else try arena.dupe(u8, textAt(stmt, 2)),
                });
            }
        }
        return .{ .table = table, .kind = found.kind, .columns = columns.items, .indexes = indexes.items, .foreign_keys = keys.items };
    }

    fn bound(self: *Conn, sql: [:0]const u8, value: []const u8) engine.Error!*c.sqlite3_stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            _ = c.sqlite3_finalize(stmt);
            return self.sqlFailed();
        }
        _ = c.sqlite3_bind_text(stmt, 1, value.ptr, @intCast(value.len), null);
        return stmt.?;
    }

    fn deriveHidden(self: *Conn) !void {
        if (self.access.hidden.len == 0 and self.access.masked.len == 0) return;
        const arena = self.derived.allocator();
        var found: std.ArrayList(access_mod.Column) = .empty;
        const sql = "SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            _ = c.sqlite3_finalize(stmt);
            return self.sqlFailed();
        }
        defer _ = c.sqlite3_finalize(stmt);
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return self.sqlFailed();
            const table = textAt(stmt.?, 0);
            if (!self.access.guards(table)) continue;
            const owned_table = try arena.dupe(u8, table);
            const inner = try self.bound("SELECT name FROM pragma_table_xinfo(?1) WHERE hidden IN (2, 3)", owned_table);
            defer _ = c.sqlite3_finalize(inner);
            while (c.sqlite3_step(inner) == c.SQLITE_ROW) {
                try found.append(arena, .{ .table = owned_table, .column = try arena.dupe(u8, textAt(inner, 0)) });
            }
        }
        self.derived_hidden = found.items;
    }
};

fn isSchemaTable(name: []const u8) bool {
    return name.len >= 7 and std.ascii.eqlIgnoreCase(name[0..7], "sqlite_");
}

fn progress(ptr: ?*anyopaque) callconv(.c) c_int {
    const self: *Conn = @ptrCast(@alignCast(ptr.?));
    if (std.Io.Timestamp.now(self.io, .awake).nanoseconds >= self.deadline_ns) {
        self.timed_out = true;
        return 1;
    }
    return 0;
}

fn authorize(ptr: ?*anyopaque, action: c_int, a1: [*c]const u8, a2: [*c]const u8, a3: [*c]const u8, a4: [*c]const u8) callconv(.c) c_int {
    _ = a3;
    const self: *Conn = @ptrCast(@alignCast(ptr.?));
    return self.decide(action, span(a1), span(a2), span(a4));
}

fn span(p: [*c]const u8) []const u8 {
    if (p == null) return "";
    return std.mem.span(@as([*:0]const u8, @ptrCast(p)));
}

fn textAt(stmt: *c.sqlite3_stmt, index: c_int) []const u8 {
    const ptr = c.sqlite3_column_text(stmt, index);
    if (ptr == null) return "";
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, index));
    return @as([*]const u8, @ptrCast(ptr))[0..len];
}

fn blobAt(stmt: *c.sqlite3_stmt, index: c_int) []const u8 {
    const ptr = c.sqlite3_column_blob(stmt, index);
    if (ptr == null) return "";
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, index));
    return @as([*]const u8, @ptrCast(ptr))[0..len];
}

fn cellValue(arena: Allocator, stmt: *c.sqlite3_stmt, index: c_int, how: engine.Treatment) !engine.Value {
    const kind = c.sqlite3_column_type(stmt, index);
    switch (how) {
        .hidden => return .null,
        .plain => return switch (kind) {
            c.SQLITE_INTEGER => .{ .integer = c.sqlite3_column_int64(stmt, index) },
            c.SQLITE_FLOAT => .{ .real = c.sqlite3_column_double(stmt, index) },
            c.SQLITE_TEXT => .{ .text = textAt(stmt, index) },
            c.SQLITE_BLOB => .{ .blob = blobAt(stmt, index) },
            else => .null,
        },
        .masked => |mask| {
            if (kind == c.SQLITE_NULL) return .null;
            var out: Writer.Allocating = .init(arena);
            if (kind == c.SQLITE_BLOB) {
                try out.writer.writeAll("***");
            } else {
                try access_mod.writeMasked(&out.writer, mask, textAt(stmt, index));
            }
            return .{ .text = out.written() };
        },
    }
}

const Quoted = struct {
    name: []const u8,

    pub fn format(self: Quoted, w: *Writer) Writer.Error!void {
        try w.writeByte('"');
        for (self.name) |ch| {
            if (ch == '"') try w.writeByte('"');
            try w.writeByte(ch);
        }
        try w.writeByte('"');
    }
};

fn quoted(name: []const u8) Quoted {
    return .{ .name = name };
}

fn actionName(action: c_int) []const u8 {
    return switch (action) {
        c.SQLITE_CREATE_INDEX => "CREATE INDEX",
        c.SQLITE_CREATE_TABLE => "CREATE TABLE",
        c.SQLITE_CREATE_TEMP_INDEX => "CREATE TEMP INDEX",
        c.SQLITE_CREATE_TEMP_TABLE => "CREATE TEMP TABLE",
        c.SQLITE_CREATE_TEMP_TRIGGER => "CREATE TEMP TRIGGER",
        c.SQLITE_CREATE_TEMP_VIEW => "CREATE TEMP VIEW",
        c.SQLITE_CREATE_TRIGGER => "CREATE TRIGGER",
        c.SQLITE_CREATE_VIEW => "CREATE VIEW",
        c.SQLITE_DELETE => "DELETE",
        c.SQLITE_DROP_INDEX, c.SQLITE_DROP_TEMP_INDEX => "DROP INDEX",
        c.SQLITE_DROP_TABLE, c.SQLITE_DROP_TEMP_TABLE => "DROP TABLE",
        c.SQLITE_DROP_TRIGGER, c.SQLITE_DROP_TEMP_TRIGGER => "DROP TRIGGER",
        c.SQLITE_DROP_VIEW, c.SQLITE_DROP_TEMP_VIEW => "DROP VIEW",
        c.SQLITE_INSERT => "INSERT",
        c.SQLITE_PRAGMA => "PRAGMA",
        c.SQLITE_TRANSACTION => "a transaction statement",
        c.SQLITE_UPDATE => "UPDATE",
        c.SQLITE_ATTACH => "ATTACH",
        c.SQLITE_DETACH => "DETACH",
        c.SQLITE_ALTER_TABLE => "ALTER TABLE",
        c.SQLITE_REINDEX => "REINDEX",
        c.SQLITE_ANALYZE => "ANALYZE",
        c.SQLITE_CREATE_VTABLE => "CREATE VIRTUAL TABLE",
        c.SQLITE_DROP_VTABLE => "DROP VIRTUAL TABLE",
        c.SQLITE_SAVEPOINT => "SAVEPOINT",
        else => "this statement",
    };
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

fn vSample(ptr: *anyopaque, arena: Allocator, table: []const u8, rows: u32, sink: engine.Sink) anyerror!engine.Outcome {
    const self: *Conn = @ptrCast(@alignCast(ptr));
    return self.sample(arena, table, rows, sink);
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

var heap_limited = std.atomic.Value(bool).init(false);

pub const OpenProblem = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const OpenProblem) []const u8 {
        return self.buf[0..self.len];
    }

    fn set(self: *OpenProblem, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(&self.buf, fmt, args) catch self.buf[0..];
        self.len = written.len;
    }
};

fn dbConfig(db: *c.sqlite3, op: c_int, value: c_int) void {
    _ = c.sqlite3_db_config(db, op, value, @as(?*c_int, null));
}

pub fn open(gpa: Allocator, path: []const u8, settings: engine.Settings, why: *OpenProblem) !*Conn {
    if (!heap_limited.swap(true, .acq_rel)) _ = c.sqlite3_hard_heap_limit64(heap_limit);
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    std.Io.Dir.cwd().access(settings.io, path, .{}) catch |err| {
        why.set("the database file {s} cannot be opened: {t}", .{ path, err });
        return error.DatabaseUnavailable;
    };
    const access_flag: c_int = if (settings.mode == .write) c.SQLITE_OPEN_READWRITE else c.SQLITE_OPEN_READONLY;
    var handle: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open_v2(path_z.ptr, &handle, access_flag | c.SQLITE_OPEN_NOFOLLOW | c.SQLITE_OPEN_EXRESCODE | c.SQLITE_OPEN_PRIVATECACHE, null);
    const db = handle orelse return error.OutOfMemory;
    if (rc != c.SQLITE_OK) {
        why.set("the database file {s} cannot be opened: {s}", .{ path, std.mem.span(c.sqlite3_errmsg(db)) });
        _ = c.sqlite3_close_v2(db);
        return error.DatabaseUnavailable;
    }
    const self = gpa.create(Conn) catch |err| {
        _ = c.sqlite3_close_v2(db);
        return err;
    };
    self.* = .{
        .gpa = gpa,
        .io = settings.io,
        .db = db,
        .access = settings.access,
        .limits = settings.limits,
        .mode = settings.mode,
        .scratch = .init(gpa),
        .derived = .init(gpa),
    };
    errdefer self.close();
    dbConfig(db, c.SQLITE_DBCONFIG_DEFENSIVE, 1);
    dbConfig(db, c.SQLITE_DBCONFIG_TRUSTED_SCHEMA, 0);
    dbConfig(db, c.SQLITE_DBCONFIG_DQS_DML, 0);
    dbConfig(db, c.SQLITE_DBCONFIG_DQS_DDL, 0);
    dbConfig(db, c.SQLITE_DBCONFIG_ENABLE_ATTACH_CREATE, 0);
    dbConfig(db, c.SQLITE_DBCONFIG_ENABLE_ATTACH_WRITE, 0);
    _ = c.sqlite3_limit(db, c.SQLITE_LIMIT_ATTACHED, 0);
    _ = c.sqlite3_limit(db, c.SQLITE_LIMIT_LENGTH, max_value_bytes);
    _ = c.sqlite3_limit(db, c.SQLITE_LIMIT_SQL_LENGTH, max_sql_bytes);
    _ = c.sqlite3_busy_timeout(db, busy_ms);
    if (c.sqlite3_set_authorizer(db, authorize, self) != c.SQLITE_OK) return error.DatabaseUnavailable;
    if (settings.mode == .read) self.exec("PRAGMA query_only = 1") catch {
        why.set("{s}", .{self.problem()});
        return error.DatabaseUnavailable;
    };
    self.deriveHidden() catch |err| {
        if (err == error.OutOfMemory) return err;
        why.set("the file {s} is not a readable SQLite database: {s}", .{ path, self.problem() });
        return error.DatabaseUnavailable;
    };
    return self;
}
