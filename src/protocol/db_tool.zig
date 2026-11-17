const std = @import("std");
const wire = @import("wire.zig");
const telemetry = @import("telemetry.zig");
const tool_result = @import("tool_result.zig");
const reply_contract = @import("reply_contract.zig");
const tool_names = @import("../engine/tool_names.zig");
const repo = @import("../platform/repo.zig");
const access_mod = @import("../db/access.zig");
const engine = @import("../db/engine.zig");
const sqlite = @import("../db/sqlite.zig");
const render = @import("../db/render.zig");
const config = @import("../db/config.zig");
const grant = @import("../db/grant.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;
const ToolResult = tool_result.ToolResult;

pub const read_tool = "emetgate_db";
pub const write_tool = "emetgate_db_write";

pub const read_description = "Reads a configured database: op tables, describe, sample, count, query, explain or limits. Read-only; hidden columns read as null, masked ones come back masked.";
pub const write_description = "Runs one write statement on a configured database, only in the turn after the user typed /db write.";
pub const op_desc = "tables, describe, sample, count, query, explain or limits";
pub const format_desc = "json, csv or markdown";

pub fn isDbTool(name: []const u8) bool {
    return std.mem.eql(u8, name, read_tool) or std.mem.eql(u8, name, write_tool);
}

pub fn configured(io: std.Io, root: ?[]const u8) bool {
    const given = root orelse return false;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}\\{s}", .{ std.mem.trimEnd(u8, given, "\\/"), config.repo_path }) catch return false;
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

pub const Op = enum { tables, describe, sample, count, query, explain, limits };

pub const op_names = std.meta.fieldNames(Op);
pub const format_names = std.meta.fieldNames(render.Format);

pub const exit_config: u8 = 70;
pub const exit_refused: u8 = 71;
pub const exit_not_granted: u8 = 72;
pub const exit_limit: u8 = 73;
pub const exit_sql: u8 = 74;

const add_hint = "the user adds one in a terminal (not through a tool): emetgate db add <name> <path-to-file.db>";
const grant_hint = "ask the user to type /db write (or /db write <name>) as their next prompt, then repeat this call in that turn; the user types /db write --destructive to also allow a statement that drops or empties a table";

pub const Fix = struct { name: []const u8, code: u8, fix: []const u8 };

pub const fixes = [_]Fix{
    .{ .name = "NoDatabase", .code = exit_config, .fix = add_hint },
    .{ .name = "UnknownDatabase", .code = exit_config, .fix = "pass db as one of the names op limits lists" },
    .{ .name = "DbNameRequired", .code = exit_config, .fix = "more than one database is configured: pass db with one of the names op limits lists" },
    .{ .name = "InvalidDbConfig", .code = exit_config, .fix = "the user repairs .emetgate/db.json or the global db rules (emetgate doctor names the problem); emetgate db list shows what is configured" },
    .{ .name = "DatabaseUnavailable", .code = exit_config, .fix = "the database file could not be opened; the user checks it with emetgate db list and emetgate doctor" },
    .{ .name = "EngineNotSupported", .code = exit_config, .fix = "this emetgate serves sqlite databases only; PostgreSQL and MySQL come in a later version" },
    .{ .name = "UnknownOp", .code = 2, .fix = "op is one of " ++ op_desc },
    .{ .name = "UnknownFormat", .code = 2, .fix = "format is one of " ++ format_desc },
    .{ .name = "MissingTable", .code = 2, .fix = "pass table: a name from op tables" },
    .{ .name = "MissingSql", .code = 2, .fix = "pass sql: one SQL statement" },
    .{ .name = "EmptyStatement", .code = exit_sql, .fix = "sql holds no statement; send one SQL statement" },
    .{ .name = "MultipleStatements", .code = exit_sql, .fix = "send one statement per call; split the rest into further calls" },
    .{ .name = "StatementNotRead", .code = exit_refused, .fix = "emetgate_db only reads: send one SELECT or WITH ... SELECT; a change goes through emetgate_db_write after the user types /db write" },
    .{ .name = "StatementOnlyReads", .code = exit_refused, .fix = "this statement only reads: run it with emetgate_db op query" },
    .{ .name = "TableRefused", .code = exit_refused, .fix = "the user's database access rules keep this table out; op tables lists the tables you may use" },
    .{ .name = "TableNotFound", .code = exit_sql, .fix = "op tables lists the tables and views" },
    .{ .name = "MaskedColumnUsed", .code = exit_refused, .fix = "select the masked column directly (SELECT email FROM ...) so it can be masked, and filter, join and sort on other columns" },
    .{ .name = "ActionDenied", .code = exit_refused, .fix = "this kind of statement is never run here: no ATTACH, PRAGMA, transaction, savepoint or virtual table statements" },
    .{ .name = "FunctionDenied", .code = exit_refused, .fix = "use a core SQL function (lower, substr, date, json_extract, count, sum, ...); op limits lists the access rules" },
    .{ .name = "GuardedColumnInWrite", .code = exit_refused, .fix = "a write may not read or set hidden or masked columns; leave them out of the statement" },
    .{ .name = "DestructiveNotGranted", .code = exit_not_granted, .fix = "nothing was changed; dropping a table, emptying it or changing every row needs the user to type /db write --destructive first, then repeat the call" },
    .{ .name = "WriteNotGranted", .code = exit_not_granted, .fix = grant_hint },
    .{ .name = "WriteGrantUnavailable", .code = exit_not_granted, .fix = "write mode is granted by the /db write prompt hook, which emetgate lockdown installs; the user starts the session with emetgate lockdown and types /db write" },
    .{ .name = "QueryTimeout", .code = exit_limit, .fix = "narrow the query (a WHERE on an indexed column, fewer joins) or the user raises timeout-ms with emetgate db limit" },
    .{ .name = "RateLimited", .code = exit_limit, .fix = "too many database calls this minute; wait, then retry, or the user raises rate-per-minute with emetgate db limit" },
    .{ .name = "SqlFailed", .code = exit_sql, .fix = "fix the SQL; op describe shows a table's columns" },
};

pub fn fixOf(name: []const u8) ?Fix {
    for (fixes) |fix| {
        if (std.mem.eql(u8, fix.name, name)) return fix;
    }
    return null;
}

pub const Session = struct {
    gpa: Allocator,
    grant_file: ?[]u8 = null,
    calls: std.ArrayList(i64) = .empty,

    pub fn init(gpa: Allocator, env: ?*const std.process.Environ.Map) Session {
        const file = if (env) |map| grant.path(gpa, map) catch null else null;
        return .{ .gpa = gpa, .grant_file = file };
    }

    pub fn deinit(self: *Session) void {
        if (self.grant_file) |file| self.gpa.free(file);
        self.calls.deinit(self.gpa);
    }

    fn admit(self: *Session, now_s: i64, per_minute: u32) bool {
        var kept: usize = 0;
        for (self.calls.items) |at| {
            if (now_s - at < 60) {
                self.calls.items[kept] = at;
                kept += 1;
            }
        }
        self.calls.shrinkRetainingCapacity(kept);
        if (self.calls.items.len >= per_minute) return false;
        self.calls.append(self.gpa, now_s) catch return false;
        return true;
    }
};

pub const Call = struct {
    root: ?[]const u8,
    session: ?*Session,
};

const Refusal = struct {
    name: []const u8,
    message: []const u8,
};

fn refuse(gpa: Allocator, event: *telemetry.Event, name: []const u8, message: []const u8) !ToolResult {
    event.fail(name);
    const known = fixOf(name);
    wire.clearFix();
    if (known) |fix| {
        var named: Writer.Allocating = .init(gpa);
        defer named.deinit();
        try tool_names.write(&named.writer, fix.fix);
        wire.setFix("{s}", .{named.written()});
    }
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try wire.writeErrorMessage(&out.writer, name, if (known) |fix| fix.code else 1, message);
    return .{ .text = try tool_result.dupTrim(gpa, out.written()), .is_error = true };
}

fn argString(args: ?Value, key: []const u8) ?[]const u8 {
    const object = args orelse return null;
    return tool_result.getString(object, key);
}

fn argInt(args: ?Value, key: []const u8) ?i64 {
    const object = args orelse return null;
    return tool_result.getInt(object, key);
}

const Chosen = struct {
    loaded: config.Config,
    index: usize,
    root: []u8,

    fn database(self: *Chosen) *config.Database {
        return &self.loaded.databases[self.index];
    }
};

fn choose(gpa: Allocator, io: std.Io, call: Call, args: ?Value, event: *telemetry.Event, failed: *?ToolResult) !?Chosen {
    const root = repo.servedRoot(gpa, io, call.root) catch {
        failed.* = try refuse(gpa, event, "NoDatabase", "no database is configured: this session has no repository");
        return null;
    };
    var keep = false;
    defer if (!keep) gpa.free(root);
    var loaded = config.load(gpa, io, root) catch |err| {
        if (err == error.OutOfMemory) return err;
        failed.* = try refuse(gpa, event, "InvalidDbConfig", "the database configuration (.emetgate/db.json or the global db rules) does not parse");
        return null;
    };
    defer if (!keep) loaded.deinit();
    if (loaded.databases.len == 0) {
        failed.* = try refuse(gpa, event, "NoDatabase", "no database is configured for this repository");
        return null;
    }
    const index: usize = if (argString(args, "db")) |name| blk: {
        for (loaded.databases, 0..) |db, i| {
            if (std.ascii.eqlIgnoreCase(db.name, name)) break :blk i;
        }
        const message = try namesMessage(gpa, "no database is named ", name, loaded.databases);
        defer gpa.free(message);
        failed.* = try refuse(gpa, event, "UnknownDatabase", message);
        return null;
    } else if (loaded.databases.len == 1) 0 else {
        const message = try namesMessage(gpa, "pass db; the databases are", "", loaded.databases);
        defer gpa.free(message);
        failed.* = try refuse(gpa, event, "DbNameRequired", message);
        return null;
    };
    keep = true;
    return .{ .loaded = loaded, .index = index, .root = root };
}

fn namesMessage(gpa: Allocator, lead: []const u8, given: []const u8, databases: []const config.Database) ![]u8 {
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.print("{s}{s}; configured:", .{ lead, given });
    for (databases) |db| try out.writer.print(" {s}", .{db.name});
    return out.toOwnedSlice();
}

fn engineFailure(gpa: Allocator, event: *telemetry.Event, err: anyerror, problem: []const u8) !ToolResult {
    if (err == error.OutOfMemory) return err;
    const name = @errorName(err);
    if (fixOf(name) == null) return refuse(gpa, event, "SqlFailed", if (problem.len != 0) problem else name);
    return refuse(gpa, event, name, if (problem.len != 0) problem else name);
}

fn openConn(gpa: Allocator, io: std.Io, chosen: *Chosen, mode: engine.Mode, event: *telemetry.Event, failed: *?ToolResult) !?*sqlite.Conn {
    const db = chosen.database();
    if (!db.kind.supported()) {
        failed.* = try refuse(gpa, event, "EngineNotSupported", try std.fmt.allocPrint(chosen.loaded.arena.allocator(), "database {s} is a {s} database; this version serves sqlite only", .{ db.name, @tagName(db.kind) }));
        return null;
    }
    const rules = chosen.loaded.accessFor(db) catch |err| {
        if (err == error.OutOfMemory) return err;
        failed.* = try refuse(gpa, event, "InvalidDbConfig", "a hidden or masked column entry is not table.column");
        return null;
    };
    const path = try chosen.loaded.location(db, chosen.root);
    var limits = db.limits;
    limits.max_result_bytes = @min(limits.max_result_bytes, @as(u32, @intCast(reply_contract.room(.db))));
    var why: sqlite.OpenProblem = .{};
    return sqlite.open(gpa, path, .{ .io = io, .mode = mode, .access = rules, .limits = limits }, &why) catch |err| {
        if (err == error.OutOfMemory) return err;
        failed.* = try refuse(gpa, event, "DatabaseUnavailable", why.text());
        return null;
    };
}

fn admitted(gpa: Allocator, io: std.Io, call: Call, chosen: *Chosen, event: *telemetry.Event) !?ToolResult {
    const session = call.session orelse return null;
    if (session.admit(grant.nowSeconds(io), chosen.database().limits.rate_per_minute)) return null;
    return try refuse(gpa, event, "RateLimited", try std.fmt.allocPrint(chosen.loaded.arena.allocator(), "more than {d} database calls in the last minute", .{chosen.database().limits.rate_per_minute}));
}

pub fn callRead(gpa: Allocator, io: std.Io, args: ?Value, event: *telemetry.Event, call: Call) !ToolResult {
    event.label = "db";
    const op_text = argString(args, "op") orelse if (argString(args, "sql") != null) "query" else "tables";
    const op = std.meta.stringToEnum(Op, op_text) orelse return refuse(gpa, event, "UnknownOp", "op is not one of " ++ op_desc);
    const format = if (argString(args, "format")) |text| render.Format.parse(text) orelse return refuse(gpa, event, "UnknownFormat", "format is not one of " ++ format_desc) else render.Format.json;
    var failed: ?ToolResult = null;
    var chosen = (try choose(gpa, io, call, args, event, &failed)) orelse return failed.?;
    defer {
        chosen.loaded.deinit();
        gpa.free(chosen.root);
    }
    event.file = chosen.database().name;
    if (op == .limits) return limitsReply(gpa, io, &chosen, call);
    if (try admitted(gpa, io, call, &chosen, event)) |refused| return refused;
    const table = argString(args, "table");
    const sql = argString(args, "sql");
    switch (op) {
        .describe, .sample, .count => if (table == null) return refuse(gpa, event, "MissingTable", "this op needs table"),
        .query, .explain => if (sql == null) return refuse(gpa, event, "MissingSql", "this op needs sql"),
        else => {},
    }
    const conn = (try openConn(gpa, io, &chosen, .read, event, &failed)) orelse return failed.?;
    defer conn.close();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    const name = chosen.database().name;
    switch (op) {
        .tables => {
            const listed = conn.tables(arena) catch |err| return engineFailure(gpa, event, err, conn.problem());
            try writeTables(&out.writer, name, listed);
        },
        .describe => {
            const described = conn.describe(arena, table.?) catch |err| return engineFailure(gpa, event, err, conn.problem());
            try writeDescription(&out.writer, name, described);
        },
        .count => {
            const n = conn.count(arena, table.?) catch |err| return engineFailure(gpa, event, err, conn.problem());
            var js: std.json.Stringify = .{ .writer = &out.writer };
            try js.write(.{ .db = name, .table = table.?, .rows = n });
        },
        .explain => {
            const plan = conn.explain(arena, sql.?) catch |err| return engineFailure(gpa, event, err, conn.problem());
            var js: std.json.Stringify = .{ .writer = &out.writer };
            try js.write(.{ .db = name, .plan = plan });
        },
        .query, .sample => {
            var rows: render.Rows = .init(gpa, format, conn.limits);
            defer rows.deinit();
            const asked: u32 = if (argInt(args, "rows")) |n| @intCast(std.math.clamp(n, 1, conn.limits.max_rows)) else @min(20, conn.limits.max_rows);
            const outcome = (if (op == .query) conn.query(arena, sql.?, rows.sink()) else conn.sample(arena, table.?, asked, rows.sink())) catch |err| return engineFailure(gpa, event, err, conn.problem());
            try writeRows(&out.writer, name, format, &rows, outcome, conn.limits);
        },
        .limits => unreachable,
    }
    return .{ .text = try tool_result.dupTrim(gpa, out.written()), .is_error = false };
}

pub fn callWrite(gpa: Allocator, io: std.Io, args: ?Value, event: *telemetry.Event, call: Call) !ToolResult {
    event.label = "db_write";
    const sql = argString(args, "sql") orelse return refuse(gpa, event, "MissingSql", "this call needs sql");
    var failed: ?ToolResult = null;
    var chosen = (try choose(gpa, io, call, args, event, &failed)) orelse return failed.?;
    defer {
        chosen.loaded.deinit();
        gpa.free(chosen.root);
    }
    const name = chosen.database().name;
    event.file = name;
    event.command = sql;
    const session = call.session orelse return refuse(gpa, event, "WriteGrantUnavailable", "this server has no session to read a write grant from");
    const file = session.grant_file orelse return refuse(gpa, event, "WriteGrantUnavailable", "this session was not started by emetgate lockdown, so no /db write grant can reach it");
    var grant_arena = std.heap.ArenaAllocator.init(gpa);
    defer grant_arena.deinit();
    const given = grant.active(grant_arena.allocator(), file, grant.nowSeconds(io)) orelse return refuse(gpa, event, "WriteNotGranted", "write mode is off: the user has not typed /db write for this turn");
    if (!given.covers(name)) {
        const message = try std.fmt.allocPrint(chosen.loaded.arena.allocator(), "the user granted write mode for database {s} only, not {s}", .{ given.db.?, name });
        return refuse(gpa, event, "WriteNotGranted", message);
    }
    if (try admitted(gpa, io, call, &chosen, event)) |refused| return refused;
    const conn = (try openConn(gpa, io, &chosen, .write, event, &failed)) orelse return failed.?;
    defer conn.close();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const outcome = conn.write(arena_state.allocator(), sql, .{ .destructive = given.destructive }) catch |err| return engineFailure(gpa, event, err, conn.problem());
    event.rows = outcome.changes;
    event.outcome = .committed;
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };
    try js.write(.{
        .db = name,
        .status = "written",
        .action = @tagName(outcome.action),
        .table = outcome.table,
        .rows_affected = outcome.changes,
        .destructive = outcome.destructive,
        .ms = outcome.elapsed_ms,
    });
    return .{ .text = try tool_result.dupTrim(gpa, out.written()), .is_error = false };
}

fn writeTables(w: *Writer, name: []const u8, listed: engine.Tables) !void {
    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("db");
    try js.write(name);
    try js.objectField("tables");
    try js.beginArray();
    for (listed.shown) |table| {
        if (table.kind == .table) {
            try js.write(table.name);
        } else {
            try js.beginObject();
            try js.objectField("view");
            try js.write(table.name);
            try js.endObject();
        }
    }
    try js.endArray();
    if (listed.withheld != 0) {
        try js.objectField("withheld");
        try js.write(listed.withheld);
    }
    try js.endObject();
}

fn treatmentText(buf: []u8, how: engine.Treatment) ?[]const u8 {
    return switch (how) {
        .plain => null,
        .hidden => "hidden",
        .masked => |mask| std.fmt.bufPrint(buf, "masked:{s}", .{@tagName(mask.mode)}) catch "masked",
    };
}

fn writeDescription(w: *Writer, name: []const u8, d: engine.Description) !void {
    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("db");
    try js.write(name);
    try js.objectField(if (d.kind == .view) "view" else "table");
    try js.write(d.table);
    try js.objectField("columns");
    try js.beginArray();
    for (d.columns) |column| {
        try js.beginObject();
        try js.objectField("name");
        try js.write(column.name);
        if (column.decl_type.len != 0) {
            try js.objectField("type");
            try js.write(column.decl_type);
        }
        if (column.primary_key != 0) {
            try js.objectField("pk");
            try js.write(column.primary_key);
        }
        if (column.not_null) {
            try js.objectField("not_null");
            try js.write(true);
        }
        if (column.default) |default| {
            try js.objectField("default");
            try js.write(default);
        }
        if (column.generated) {
            try js.objectField("generated");
            try js.write(true);
        }
        var buf: [32]u8 = undefined;
        if (treatmentText(&buf, column.treatment)) |text| {
            try js.objectField("access");
            try js.write(text);
        }
        try js.endObject();
    }
    try js.endArray();
    if (d.indexes.len != 0) {
        try js.objectField("indexes");
        try js.beginArray();
        for (d.indexes) |index| try js.write(.{ .name = index.name, .unique = index.unique, .columns = index.columns });
        try js.endArray();
    }
    if (d.foreign_keys.len != 0) {
        try js.objectField("foreign_keys");
        try js.beginArray();
        for (d.foreign_keys) |key| {
            try js.beginObject();
            try js.objectField("from");
            try js.write(key.from);
            try js.objectField("table");
            try js.write(key.table);
            if (key.to) |to| {
                try js.objectField("to");
                try js.write(to);
            }
            try js.endObject();
        }
        try js.endArray();
    }
    try js.endObject();
}

fn stopText(stop: engine.Stop, limits: engine.Limits, buf: []u8) []const u8 {
    return switch (stop) {
        .none => "",
        .rows => std.fmt.bufPrint(buf, "max_rows {d} reached; add WHERE or LIMIT/OFFSET to see other rows", .{limits.max_rows}) catch "max_rows reached",
        .bytes => std.fmt.bufPrint(buf, "max_result_bytes {d} reached; select fewer columns or rows", .{limits.max_result_bytes}) catch "max_result_bytes reached",
    };
}

fn writeRows(w: *Writer, name: []const u8, format: render.Format, rows: *render.Rows, outcome: engine.Outcome, limits: engine.Limits) !void {
    var stop_buf: [128]u8 = undefined;
    const stop = stopText(outcome.stop, limits, &stop_buf);
    if (format == .json) {
        var js: std.json.Stringify = .{ .writer = w };
        try js.beginObject();
        try js.objectField("db");
        try js.write(name);
        try js.objectField("columns");
        try js.beginArray();
        for (rows.columns) |column| try js.write(column.name);
        try js.endArray();
        try js.objectField("rows");
        try js.beginWriteRaw();
        try js.writer.writeByte('[');
        try js.writer.writeAll(rows.written());
        try js.writer.writeByte(']');
        js.endWriteRaw();
        try js.objectField("row_count");
        try js.write(outcome.rows);
        if (outcome.nulled.len != 0) {
            try js.objectField("hidden");
            try js.write(outcome.nulled);
        }
        try writeTreated(&js, rows.columns);
        if (rows.cut_cells != 0) {
            try js.objectField("cut_cells");
            try js.write(rows.cut_cells);
        }
        if (outcome.more) {
            try js.objectField("more");
            try js.write(stop);
        }
        try js.objectField("ms");
        try js.write(outcome.elapsed_ms);
        try js.endObject();
        return;
    }
    try w.print("db {s} · rows {d} · {d} ms", .{ name, outcome.rows, outcome.elapsed_ms });
    for (outcome.nulled, 0..) |column, i| try w.print("{s}{s}", .{ if (i == 0) " · hidden (null): " else ", ", column });
    try writeTreatedPlain(w, rows.columns, .masked);
    if (rows.cut_cells != 0) try w.print(" · {d} cells cut at {d} chars", .{ rows.cut_cells, limits.max_cell_chars });
    if (outcome.more) try w.print(" · more: {s}", .{stop});
    try w.writeByte('\n');
    try render.writeHeader(w, format, rows.columns);
    try w.writeAll(rows.written());
}

fn writeTreated(js: *std.json.Stringify, columns: []const engine.ResultColumn) !void {
    inline for (.{.masked}) |which| {
        var any = false;
        for (columns) |column| {
            if (std.meta.activeTag(column.treatment) != which) continue;
            if (!any) {
                try js.objectField(@tagName(which));
                try js.beginArray();
                any = true;
            }
            try js.write(column.name);
        }
        if (any) try js.endArray();
    }
}

fn writeTreatedPlain(w: *Writer, columns: []const engine.ResultColumn, which: std.meta.Tag(engine.Treatment)) !void {
    var any = false;
    for (columns) |column| {
        if (std.meta.activeTag(column.treatment) != which) continue;
        try w.writeAll(if (any) ", " else " · masked: ");
        try w.writeAll(column.name);
        any = true;
    }
}

fn limitsReply(gpa: Allocator, io: std.Io, chosen: *Chosen, call: Call) !ToolResult {
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer };
    try js.beginObject();
    try js.objectField("databases");
    try js.beginArray();
    for (chosen.loaded.databases) |db| {
        try js.beginObject();
        try js.objectField("name");
        try js.write(db.name);
        try js.objectField("engine");
        try js.write(@tagName(db.kind));
        if (!db.kind.supported()) {
            try js.objectField("served");
            try js.write(false);
        }
        try js.endObject();
    }
    try js.endArray();
    const db = chosen.database();
    try js.objectField("db");
    try js.write(db.name);
    try js.objectField("limits");
    try js.beginObject();
    try config.writeLimits(&js, db.limits, true);
    try js.endObject();
    const rules = try chosen.loaded.accessFor(db);
    try js.objectField("access");
    try js.beginObject();
    try js.objectField("hidden");
    try js.beginArray();
    var entry_buf: [400]u8 = undefined;
    for (rules.hidden) |col| try js.write(std.fmt.bufPrint(&entry_buf, "{f}", .{col}) catch col.column);
    try js.endArray();
    try js.objectField("masked");
    try js.beginArray();
    for (rules.masked) |mask| try js.write(std.fmt.bufPrint(&entry_buf, "{s}.{s}:{s}", .{ mask.table, mask.column, @tagName(mask.mode) }) catch mask.column);
    try js.endArray();
    if (rules.allowed_tables.len != 0) {
        try js.objectField("allowed_tables");
        try js.write(rules.allowed_tables);
    }
    try js.objectField("blocked_tables");
    try js.write(rules.blocked_tables);
    try js.endObject();
    try js.objectField("write");
    try js.write(writeState(gpa, io, call, db.name));
    try js.endObject();
    return .{ .text = try tool_result.dupTrim(gpa, out.written()), .is_error = false };
}

fn writeState(gpa: Allocator, io: std.Io, call: Call, name: []const u8) []const u8 {
    const session = call.session orelse return "off: only the user grants write mode, by typing /db write";
    const file = session.grant_file orelse return "unavailable: the /db write grant needs a session started by emetgate lockdown";
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const given = grant.active(arena_state.allocator(), file, grant.nowSeconds(io)) orelse return "off: only the user grants write mode, by typing /db write";
    if (!given.covers(name)) return "off for this database: the user granted another one";
    return if (given.destructive) "on for this turn, destructive statements included" else "on for this turn; destructive statements still need /db write --destructive";
}

const testing = std.testing;

test "db tool: every error the tool names has a fix and an exit code of its own family" {
    for (fixes) |fix| {
        try testing.expect(fix.fix.len > 20);
        try testing.expect(fix.code != 1);
    }
    inline for (@typeInfo(engine.Error).error_set.?) |err| {
        try testing.expect(fixOf(err.name) != null);
    }
}

test "db tool: the rate window admits the configured number of calls per minute and then refuses" {
    var session: Session = .init(testing.allocator, null);
    defer session.deinit();
    for (0..3) |_| try testing.expect(session.admit(100, 3));
    try testing.expect(!session.admit(110, 3));
    try testing.expect(session.admit(161, 3));
}
