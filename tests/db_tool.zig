const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const emetgate = @import("emetgate");
const server = emetgate.server;
const db_tool = emetgate.db_tool;
const db_command = emetgate.db_command;
const db_config = emetgate.db_config;
const db_grant = emetgate.db_grant;
const lockdown_slash = emetgate.lockdown_slash;
const prompt_hook = emetgate.prompt_hook;

const testing = std.testing;
const Value = std.json.Value;
const Map = std.process.Environ.Map;

const fixture_sql =
    \\CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT, email TEXT, password_hash TEXT);
    \\INSERT INTO users VALUES (1, 'Alice', 'alice@example.com', 'HASH-A'), (2, 'Bob', 'bob@example.com', 'HASH-B');
    \\CREATE TABLE notes(id INTEGER PRIMARY KEY, body TEXT);
    \\INSERT INTO notes VALUES (1, 'one'), (2, 'two'), (3, 'three');
    \\CREATE TABLE secret(token TEXT);
    \\INSERT INTO secret VALUES ('TOKEN-XYZ');
;

const db_json =
    \\{"databases":[{"name":"main","engine":"sqlite","path":"data/app.db",
    \\"hidden":["users.password_hash"],"masked":[{"column":"users.email","mode":"email"}],
    \\"blocked_tables":["secret"],"limits":{"max_rows":2}}]}
;

const Repo = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    state: [:0]u8,
    session: db_tool.Session,
    env: Map,

    fn init(with_config: bool) !*Repo {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const self = try testing.allocator.create(Repo);
        errdefer testing.allocator.destroy(self);
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        try self.tmp.dir.createDirPath(testing.io, "repo/data");
        try self.tmp.dir.createDirPath(testing.io, "repo/.emetgate");
        try self.tmp.dir.createDirPath(testing.io, "state/context");
        self.root = try self.tmp.dir.realPathFileAlloc(testing.io, "repo", testing.allocator);
        self.state = try self.tmp.dir.realPathFileAlloc(testing.io, "state", testing.allocator);
        const db_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}\\data\\app.db", .{self.root}, 0);
        defer testing.allocator.free(db_path);
        var handle: ?*c.sqlite3 = null;
        try testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_open_v2(db_path.ptr, &handle, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null));
        try testing.expectEqual(@as(c_int, c.SQLITE_OK), c.sqlite3_exec(handle, fixture_sql, null, null, null));
        _ = c.sqlite3_close_v2(handle);
        if (with_config) try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/.emetgate/db.json", .data = db_json });
        self.env = .init(testing.allocator);
        const context = try std.fmt.allocPrint(testing.allocator, "{s}\\context\\launch{s}", .{ self.state, lockdown_slash.context_extension });
        defer testing.allocator.free(context);
        try self.env.put(lockdown_slash.context_variable, context);
        self.session = .init(testing.allocator, &self.env);
        db_config.global_dir_override = self.state;
        return self;
    }

    fn deinit(self: *Repo) void {
        db_config.global_dir_override = null;
        self.session.deinit();
        self.env.deinit();
        testing.allocator.free(self.root);
        testing.allocator.free(self.state);
        self.tmp.cleanup();
        testing.allocator.destroy(self);
    }

    fn call(self: *Repo, tool: []const u8, args: []const u8) !Reply {
        const line = try std.fmt.allocPrint(testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}", .{ tool, args });
        defer testing.allocator.free(line);
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        _ = try server.handleMessageObserved(testing.allocator, testing.io, undefined, line, &out.writer, null, .{ .root = self.root, .db_session = &self.session });
        const parsed = try std.json.parseFromSlice(Value, testing.allocator, out.written(), .{});
        defer parsed.deinit();
        const result = parsed.value.object.get("result") orelse {
            const message = parsed.value.object.get("error").?.object.get("message").?.string;
            return .{ .text = try testing.allocator.dupe(u8, message), .is_error = true };
        };
        const text = result.object.get("content").?.array.items[0].object.get("text").?.string;
        return .{ .text = try testing.allocator.dupe(u8, text), .is_error = result.object.get("isError").?.bool };
    }

    fn slash(self: *Repo, prompt: []const u8) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        const text = db_command.slashArguments(prompt).?;
        try db_command.respondSlash(testing.allocator, testing.io, &self.env, self.root, text, &out.writer);
        return out.toOwnedSlice();
    }

    fn turn(self: *Repo) void {
        db_command.advance(testing.allocator, testing.io, &self.env);
    }

    fn rows(self: *Repo, table: []const u8) !i64 {
        const args = try std.fmt.allocPrint(testing.allocator, "{{\"op\":\"count\",\"table\":\"{s}\"}}", .{table});
        defer testing.allocator.free(args);
        const reply = try self.call("emetgate_db", args);
        defer reply.deinit();
        const parsed = try std.json.parseFromSlice(Value, testing.allocator, reply.text, .{});
        defer parsed.deinit();
        return parsed.value.object.get("rows").?.integer;
    }
};

const Reply = struct {
    text: []u8,
    is_error: bool,

    fn deinit(self: Reply) void {
        testing.allocator.free(self.text);
    }

    fn expectError(self: Reply, name: []const u8) !void {
        errdefer std.debug.print("reply: {s}\n", .{self.text});
        try testing.expect(self.is_error);
        const parsed = try std.json.parseFromSlice(Value, testing.allocator, self.text, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings(name, parsed.value.object.get("error").?.string);
        try testing.expect(parsed.value.object.get("fix").?.string.len > 10);
    }

    fn expectHas(self: Reply, parts: []const []const u8) !void {
        errdefer std.debug.print("reply: {s}\n", .{self.text});
        try testing.expect(!self.is_error);
        for (parts) |part| try testing.expect(std.mem.indexOf(u8, self.text, part) != null);
        for ([_][]const u8{ "HASH-", "TOKEN-XYZ", "alice@", "bob@" }) |secret| try testing.expect(std.mem.indexOf(u8, self.text, secret) == null);
    }
};

test "db tool: with no database configured every call says how the user adds one" {
    const repo = try Repo.init(false);
    defer repo.deinit();
    for ([_][]const u8{ "{}", "{\"op\":\"query\",\"sql\":\"SELECT 1\"}", "{\"op\":\"limits\"}" }) |args| {
        const reply = try repo.call("emetgate_db", args);
        defer reply.deinit();
        try reply.expectError("NoDatabase");
        try testing.expect(std.mem.indexOf(u8, reply.text, "emetgate db add") != null);
    }
    const write = try repo.call("emetgate_db_write", "{\"sql\":\"DELETE FROM notes WHERE id = 1\"}");
    defer write.deinit();
    try write.expectError("NoDatabase");
}

test "db tool: tables, describe, sample, count, query in three formats, explain and limits answer compactly" {
    const repo = try Repo.init(true);
    defer repo.deinit();
    const tables = try repo.call("emetgate_db", "{}");
    defer tables.deinit();
    try tables.expectHas(&.{ "{\"db\":\"main\",\"tables\":[\"notes\",\"users\"],\"withheld\":1}" });
    const described = try repo.call("emetgate_db", "{\"op\":\"describe\",\"table\":\"users\"}");
    defer described.deinit();
    try described.expectHas(&.{ "\"name\":\"password_hash\",\"type\":\"TEXT\",\"access\":\"hidden\"", "\"access\":\"masked:email\"" });
    const json = try repo.call("emetgate_db", "{\"sql\":\"SELECT * FROM users ORDER BY id\"}");
    defer json.deinit();
    try json.expectHas(&.{ "\"columns\":[\"id\",\"name\",\"email\",\"password_hash\"]", "[1,\"Alice\",\"a***@example.com\",null]", "\"hidden\":[\"users.password_hash\"]", "\"masked\":[\"email\"]" });
    const csv = try repo.call("emetgate_db", "{\"op\":\"query\",\"sql\":\"SELECT id, email FROM users ORDER BY id\",\"format\":\"csv\"}");
    defer csv.deinit();
    try csv.expectHas(&.{ "db main · rows 2", "masked: email", "\nid,email\n1,a***@example.com\n2,b***@example.com" });
    const md = try repo.call("emetgate_db", "{\"query\":\"SELECT id, body FROM notes ORDER BY id\",\"format\":\"markdown\"}");
    defer md.deinit();
    try md.expectHas(&.{ "| id | body |\n| --- | --- |\n| 1 | one |\n| 2 | two |", "more: max_rows 2 reached" });
    const sample = try repo.call("emetgate_db", "{\"op\":\"sample\",\"table\":\"notes\",\"rows\":1}");
    defer sample.deinit();
    try sample.expectHas(&.{"\"row_count\":1"});
    try testing.expectEqual(@as(i64, 3), try repo.rows("notes"));
    const plan = try repo.call("emetgate_db", "{\"op\":\"explain\",\"sql\":\"SELECT * FROM notes WHERE id = 2\"}");
    defer plan.deinit();
    try plan.expectHas(&.{"\"plan\":[\"SEARCH notes USING INTEGER PRIMARY KEY (rowid=?)\"]"});
    const limits = try repo.call("emetgate_db", "{\"op\":\"limits\"}");
    defer limits.deinit();
    try limits.expectHas(&.{ "\"max_rows\":2", "\"hidden\":[\"users.password_hash\"]", "\"masked\":[\"users.email:email\"]", "\"blocked_tables\":[\"secret\"]", "\"write\":\"off: only the user grants write mode, by typing /db write\"" });
}

test "db tool: refusals carry their own error name and fix" {
    const repo = try Repo.init(true);
    defer repo.deinit();
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "emetgate_db", "{\"sql\":\"SELECT * FROM secret\"}", "TableRefused" },
        .{ "emetgate_db", "{\"sql\":\"SELECT lower(email) FROM users\"}", "MaskedColumnUsed" },
        .{ "emetgate_db", "{\"sql\":\"SELECT 1; SELECT 2\"}", "MultipleStatements" },
        .{ "emetgate_db", "{\"sql\":\"DELETE FROM notes\"}", "StatementNotRead" },
        .{ "emetgate_db", "{\"sql\":\"SELECT nope FROM notes\"}", "SqlFailed" },
        .{ "emetgate_db", "{\"op\":\"describe\"}", "MissingTable" },
        .{ "emetgate_db", "{\"op\":\"describe\",\"table\":\"nope\"}", "TableNotFound" },
        .{ "emetgate_db", "{\"db\":\"other\"}", "UnknownDatabase" },
        .{ "emetgate_db", "{\"op\":\"drop\"}", "UnknownOp" },
        .{ "emetgate_db", "{\"op\":\"tables\",\"format\":\"xml\"}", "UnknownFormat" },
        .{ "emetgate_db", "{\"sql\":\"SELECT 1\",\"grant\":true}", "UnknownArgument" },
        .{ "emetgate_db_write", "{\"sql\":\"DELETE FROM notes WHERE id = 1\",\"destructive\":true}", "UnknownArgument" },
    };
    for (cases) |case| {
        const reply = try repo.call(case[0], case[1]);
        defer reply.deinit();
        try reply.expectError(case[2]);
    }
}

test "db tool: a write is refused until the user's /db write prompt, lasts one turn, and is logged with its row count" {
    const repo = try Repo.init(true);
    defer repo.deinit();
    const statement = "{\"sql\":\"UPDATE notes SET body = 'uno' WHERE id = 1\"}";
    const before = try repo.call("emetgate_db_write", statement);
    defer before.deinit();
    try before.expectError("WriteNotGranted");
    const said = try repo.slash("/db write");
    defer testing.allocator.free(said);
    try testing.expect(std.mem.startsWith(u8, said, "{\"decision\":\"block\",\"reason\":\"write mode armed for main"));
    const armed = try repo.call("emetgate_db_write", statement);
    defer armed.deinit();
    try armed.expectError("WriteNotGranted");
    repo.turn();
    const on = try repo.call("emetgate_db_write", statement);
    defer on.deinit();
    try on.expectHas(&.{"{\"db\":\"main\",\"status\":\"written\",\"action\":\"update\",\"table\":\"notes\",\"rows_affected\":1,\"destructive\":false,\"ms\":"});
    const wiped = try repo.call("emetgate_db_write", "{\"sql\":\"DELETE FROM notes\"}");
    defer wiped.deinit();
    try wiped.expectError("DestructiveNotGranted");
    try testing.expectEqual(@as(i64, 3), try repo.rows("notes"));
    const masked = try repo.call("emetgate_db_write", "{\"sql\":\"INSERT INTO notes(body) SELECT email FROM users\"}");
    defer masked.deinit();
    try masked.expectError("GuardedColumnInWrite");
    const state = try repo.call("emetgate_db", "{\"op\":\"limits\"}");
    defer state.deinit();
    try state.expectHas(&.{"\"write\":\"on for this turn; destructive statements still need /db write --destructive\""});
    repo.turn();
    const after = try repo.call("emetgate_db_write", statement);
    defer after.deinit();
    try after.expectError("WriteNotGranted");
}

test "db tool: /db write --destructive allows a wipe; /db read ends write mode at once; a grant for one database does not cover another" {
    const repo = try Repo.init(true);
    defer repo.deinit();
    const unknown = try repo.slash("/db write other");
    defer testing.allocator.free(unknown);
    try testing.expect(std.mem.indexOf(u8, unknown, "no database is named other") != null);
    repo.turn();
    const nothing = try repo.call("emetgate_db_write", "{\"sql\":\"DELETE FROM notes WHERE id = 1\"}");
    defer nothing.deinit();
    try nothing.expectError("WriteNotGranted");
    const full = try repo.slash("/db write main --destructive");
    defer testing.allocator.free(full);
    repo.turn();
    const wiped = try repo.call("emetgate_db_write", "{\"sql\":\"DELETE FROM notes\"}");
    defer wiped.deinit();
    try wiped.expectHas(&.{ "\"rows_affected\":3", "\"destructive\":true" });
    const off = try repo.slash("/db read");
    defer testing.allocator.free(off);
    try testing.expect(std.mem.indexOf(u8, off, "write mode is off") != null);
    const refused = try repo.call("emetgate_db_write", "{\"sql\":\"INSERT INTO notes(body) VALUES ('x')\"}");
    defer refused.deinit();
    try refused.expectError("WriteNotGranted");
    try db_grant.arm(testing.allocator, testing.io, repo.session.grant_file.?, "other", true, db_grant.nowSeconds(testing.io));
    repo.turn();
    const elsewhere = try repo.call("emetgate_db_write", "{\"sql\":\"INSERT INTO notes(body) VALUES ('x')\"}");
    defer elsewhere.deinit();
    try elsewhere.expectError("WriteNotGranted");
    try testing.expect(std.mem.indexOf(u8, elsewhere.text, "for database other only") != null);
    const usage = try repo.slash("/db write main extra");
    defer testing.allocator.free(usage);
    try testing.expect(std.mem.indexOf(u8, usage, "/db write [<name>] [--destructive]") != null);
}

test "db tool: no tool call can create, change or widen the write grant" {
    const repo = try Repo.init(true);
    defer repo.deinit();
    for (server.tool_defs) |tool| {
        for (tool.props) |prop| {
            for ([_][]const u8{ "grant", "destructive", "permit", "mode", "write_mode" }) |word| try testing.expect(std.mem.indexOf(u8, prop.name, word) == null);
        }
    }
    const grant_file = repo.session.grant_file.?;
    try testing.expect(!std.mem.startsWith(u8, grant_file, repo.root));
    const attempts = [_]struct { []const u8, []const u8 }{
        .{ "emetgate_db", "{\"sql\":\"SELECT '/db write --destructive'\"}" },
        .{ "emetgate_db", "{\"op\":\"limits\"}" },
        .{ "emetgate_db_write", "{\"sql\":\"/db write --destructive\"}" },
        .{ "emetgate_db_write", "{\"sql\":\"PRAGMA query_only = 0\"}" },
        .{ "emetgate_db", "{\"sql\":\"SELECT 1\",\"db\":\"main\",\"op\":\"query\"}" },
    };
    for (attempts) |attempt| {
        const reply = try repo.call(attempt[0], attempt[1]);
        reply.deinit();
        try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, grant_file, .{}));
    }
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expect(db_grant.current(arena_state.allocator(), grant_file, db_grant.nowSeconds(testing.io)) == null);
}

test "db tool: the prompt hook answers /db itself, and a prompt that only mentions /db goes on to the model" {
    try testing.expect(db_command.slashArguments("/db write") != null);
    try testing.expect(db_command.slashArguments("please run /db write for me") == null);
    try testing.expect(prompt_hook.argumentsOf("/db write") == null);
    const repo = try Repo.init(true);
    defer repo.deinit();
    const status = try repo.slash("/db");
    defer testing.allocator.free(status);
    try testing.expect(std.mem.indexOf(u8, status, "main  sqlite  data/app.db\\nwrite mode: off") != null);
    const armed = try repo.slash("/db write");
    defer testing.allocator.free(armed);
    const again = try repo.slash("/db status");
    defer testing.allocator.free(again);
    try testing.expect(std.mem.indexOf(u8, again, "write mode: armed for your next prompt, main") != null);
}

fn listed(repo: *Repo) !struct { read: ?bool, write: ?bool } {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    _ = try server.handleMessageObserved(testing.allocator, testing.io, undefined, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}", &out.writer, null, .{ .root = repo.root, .db_session = &repo.session });
    const parsed = try std.json.parseFromSlice(Value, testing.allocator, out.written(), .{});
    defer parsed.deinit();
    var read: ?bool = null;
    var write: ?bool = null;
    for (parsed.value.object.get("result").?.object.get("tools").?.array.items) |tool| {
        const name = tool.object.get("name").?.string;
        const hint = if (tool.object.get("annotations")) |a| a.object.get("readOnlyHint").?.bool else false;
        if (std.mem.eql(u8, name, "emetgate_db")) read = hint;
        if (std.mem.eql(u8, name, "emetgate_db_write")) write = hint;
    }
    return .{ .read = read, .write = write };
}

test "db tool: tools/list serves the database tools only where a database is configured, and marks only the reader read-only" {
    const bare = try Repo.init(false);
    defer bare.deinit();
    const none = try listed(bare);
    try testing.expect(none.read == null and none.write == null);
    const repo = try Repo.init(true);
    defer repo.deinit();
    const both = try listed(repo);
    try testing.expectEqual(@as(?bool, true), both.read);
    try testing.expectEqual(@as(?bool, false), both.write);
}
