const std = @import("std");
const access_mod = @import("access.zig");
const engine = @import("engine.zig");
const bson = @import("bson.zig");
const guard = @import("mongo_guard.zig");
const wire = @import("mongo_wire.zig");
const scram = @import("scram.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;
const Access = access_mod.Access;

pub const default_port: u16 = 27017;
pub const describe_sample = 100;
pub const max_collections = 10_000;
pub const max_view_depth = 8;
pub const socket_grace_ms = 5_000;
pub const max_fetched_bytes = 32 * 1024 * 1024;
pub const max_message_chars = 400;

pub const Host = struct { name: []const u8, port: u16 };

pub const Uri = struct {
    hosts: []const Host,
    user: ?[]const u8 = null,
    password: ?[]const u8 = null,
    database: []const u8,
    auth_source: []const u8,
    mechanism: ?scram.Mechanism = null,
    tls: bool = false,
    verify_certificate: bool = true,
    verify_host: bool = true,
    connect_timeout_ms: u32 = 10_000,
};

pub const UriError = error{ InvalidUri, SrvNotSupported, OutOfMemory };

fn percentDecode(arena: Allocator, text: []const u8) UriError![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '%') == null) return text;
    var out = try arena.alloc(u8, text.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (n += 1) {
        if (text[i] == '%') {
            if (i + 3 > text.len) return error.InvalidUri;
            out[n] = std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16) catch return error.InvalidUri;
            i += 3;
        } else {
            out[n] = text[i];
            i += 1;
        }
    }
    return out[0..n];
}

fn boolOption(value: []const u8) UriError!bool {
    if (std.ascii.eqlIgnoreCase(value, "true")) return true;
    if (std.ascii.eqlIgnoreCase(value, "false")) return false;
    return error.InvalidUri;
}

pub fn isMongoUrl(text: []const u8) bool {
    return startsWithIgnoreCase(text, "mongodb://") or startsWithIgnoreCase(text, "mongodb+srv://");
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

pub fn parseUri(arena: Allocator, text: []const u8, why: *[]const u8) UriError!Uri {
    if (startsWithIgnoreCase(text, "mongodb+srv://")) {
        why.* = "mongodb+srv:// needs a DNS SRV lookup, which emetgate does not do; list the hosts instead: mongodb://user@host1:27017,host2:27017/db?tls=true";
        return error.SrvNotSupported;
    }
    if (!startsWithIgnoreCase(text, "mongodb://")) {
        why.* = "the connection string starts with mongodb://";
        return error.InvalidUri;
    }
    var rest = text["mongodb://".len..];
    var query: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '?')) |q| {
        query = rest[q + 1 ..];
        rest = rest[0..q];
    }
    var path: []const u8 = "";
    const at = std.mem.lastIndexOfScalar(u8, rest, '@');
    const host_start = if (at) |a| a + 1 else 0;
    if (std.mem.indexOfScalarPos(u8, rest, host_start, '/')) |slash| {
        path = rest[slash + 1 ..];
        rest = rest[0..slash];
    }
    var uri: Uri = .{ .hosts = &.{}, .database = "", .auth_source = "" };
    if (at) |a| {
        const userinfo = rest[0..a];
        rest = rest[a + 1 ..];
        if (std.mem.indexOfScalar(u8, userinfo, ':')) |colon| {
            uri.user = try percentDecode(arena, userinfo[0..colon]);
            uri.password = try arena.dupe(u8, try percentDecode(arena, userinfo[colon + 1 ..]));
        } else uri.user = try percentDecode(arena, userinfo);
        if (uri.user.?.len == 0) {
            why.* = "the user name before @ is empty";
            return error.InvalidUri;
        }
    }
    var hosts: std.ArrayList(Host) = .empty;
    var host_it = std.mem.splitScalar(u8, rest, ',');
    while (host_it.next()) |entry| {
        if (entry.len == 0) {
            why.* = "a host in the connection string is empty";
            return error.InvalidUri;
        }
        var name = entry;
        var port: u16 = default_port;
        if (entry[0] == '[') {
            const close = std.mem.indexOfScalar(u8, entry, ']') orelse {
                why.* = "an IPv6 host is written [address]:port";
                return error.InvalidUri;
            };
            name = entry[1..close];
            if (close + 1 < entry.len) {
                if (entry[close + 1] != ':') return error.InvalidUri;
                port = std.fmt.parseUnsigned(u16, entry[close + 2 ..], 10) catch return error.InvalidUri;
            }
        } else if (std.mem.lastIndexOfScalar(u8, entry, ':')) |colon| {
            name = entry[0..colon];
            port = std.fmt.parseUnsigned(u16, entry[colon + 1 ..], 10) catch {
                why.* = "a port in the connection string is not a number";
                return error.InvalidUri;
            };
        }
        if (name.len == 0 or port == 0) {
            why.* = "a host in the connection string is empty";
            return error.InvalidUri;
        }
        try hosts.append(arena, .{ .name = try percentDecode(arena, name), .port = port });
    }
    uri.hosts = hosts.items;
    uri.database = try percentDecode(arena, path);
    if (uri.database.len == 0) {
        why.* = "name the database in the path: mongodb://user@host:27017/mydb";
        return error.InvalidUri;
    }
    if (std.mem.indexOfAny(u8, uri.database, "/\\. \"$\x00") != null) {
        why.* = "the database name holds a character MongoDB does not allow (/\\. \"$)";
        return error.InvalidUri;
    }
    uri.auth_source = uri.database;
    var opts = std.mem.splitAny(u8, query, "&;");
    while (opts.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse {
            why.* = "a connection string option is written name=value";
            return error.InvalidUri;
        };
        const key = pair[0..eq];
        const value = try percentDecode(arena, pair[eq + 1 ..]);
        if (std.ascii.eqlIgnoreCase(key, "authSource")) {
            if (value.len == 0) return error.InvalidUri;
            uri.auth_source = value;
        } else if (std.ascii.eqlIgnoreCase(key, "authMechanism")) {
            if (std.mem.eql(u8, value, "DEFAULT")) continue;
            uri.mechanism = scram.Mechanism.parse(value) orelse {
                why.* = "only SCRAM-SHA-256 and SCRAM-SHA-1 authentication are supported; X.509, Kerberos, LDAP, AWS and OIDC are not";
                return error.InvalidUri;
            };
        } else if (std.ascii.eqlIgnoreCase(key, "tls") or std.ascii.eqlIgnoreCase(key, "ssl")) {
            uri.tls = boolOption(value) catch {
                why.* = "tls is true or false";
                return error.InvalidUri;
            };
        } else if (std.ascii.eqlIgnoreCase(key, "tlsAllowInvalidCertificates")) {
            uri.verify_certificate = !(try boolOption(value));
        } else if (std.ascii.eqlIgnoreCase(key, "tlsAllowInvalidHostnames")) {
            uri.verify_host = !(try boolOption(value));
        } else if (std.ascii.eqlIgnoreCase(key, "tlsInsecure")) {
            const insecure = try boolOption(value);
            uri.verify_certificate = !insecure;
            uri.verify_host = !insecure;
        } else if (std.ascii.eqlIgnoreCase(key, "connectTimeoutMS")) {
            uri.connect_timeout_ms = std.fmt.parseUnsigned(u32, value, 10) catch return error.InvalidUri;
            if (uri.connect_timeout_ms == 0) uri.connect_timeout_ms = 10_000;
        } else if (eqlAnyIgnoreCase(key, &.{ "tlsCAFile", "tlsCertificateKeyFile", "tlsCertificateKeyFilePassword", "sslCAFile", "sslPEMKeyFile", "authMechanismProperties", "gssapiServiceName" })) {
            why.* = std.fmt.allocPrint(arena, "the option {s} is not supported: the server certificate is checked against the Windows certificate store, and only password (SCRAM) logins work", .{key}) catch "unsupported option";
            return error.InvalidUri;
        } else if (eqlAnyIgnoreCase(key, &.{ "replicaSet", "directConnection", "appName", "retryWrites", "retryReads", "w", "journal", "wtimeoutMS", "readPreference", "readPreferenceTags", "maxPoolSize", "minPoolSize", "maxIdleTimeMS", "serverSelectionTimeoutMS", "socketTimeoutMS", "heartbeatFrequencyMS", "localThresholdMS", "compressors", "zlibCompressionLevel", "readConcernLevel", "loadBalanced", "maxConnecting", "srvMaxHosts", "srvServiceName", "uuidRepresentation", "tlsDisableOCSPEndpointCheck", "tlsDisableCertificateRevocationCheck" })) {} else {
            why.* = std.fmt.allocPrint(arena, "the connection string option {s} is unknown", .{key}) catch "unknown option";
            return error.InvalidUri;
        }
    }
    if (uri.password != null and uri.user == null) return error.InvalidUri;
    return uri;
}

fn eqlAnyIgnoreCase(text: []const u8, options: []const []const u8) bool {
    for (options) |option| {
        if (std.ascii.eqlIgnoreCase(text, option)) return true;
    }
    return false;
}

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

const CollInfo = struct {
    name: []const u8,
    kind: engine.TableKind,
    view_on: ?[]const u8 = null,
    pipeline: []const Value = &.{},
};

pub const Conn = struct {
    gpa: Allocator,
    io: std.Io,
    transport: *wire.Transport,
    access: Access,
    limits: engine.Limits,
    mode: engine.Mode,
    database: []const u8,
    secondary: bool = false,
    state: std.heap.ArenaAllocator,
    collections: ?[]const CollInfo = null,
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

    pub fn close(self: *Conn) void {
        self.transport.close();
        self.state.deinit();
        self.gpa.destroy(self);
    }

    fn start(arena: Allocator) !bson.Builder {
        var b: bson.Builder = .init(arena);
        try b.begin();
        return b;
    }

    fn begin(arena: Allocator, verb: []const u8, subject: anytype) !bson.Builder {
        var b = try start(arena);
        switch (@TypeOf(subject)) {
            i32, comptime_int => try b.int32(verb, subject),
            else => try b.string(verb, subject),
        }
        return b;
    }

    fn badReply(self: *Conn) error{SqlFailed} {
        self.setProblem("the server sent a reply emetgate cannot read", .{});
        return error.SqlFailed;
    }

    fn send(self: *Conn, arena: Allocator, b: *bson.Builder, db: []const u8) !bson.Doc {
        try b.string("$db", db);
        if (self.secondary) {
            try b.beginDoc("$readPreference");
            try b.string("mode", "primaryPreferred");
            try b.end();
        }
        try b.end();
        const reply = self.transport.roundTrip(arena, b.bytes()) catch |err| {
            if (err == error.OutOfMemory) return err;
            if (self.transport.timedOut()) {
                self.setProblem("the database did not answer within {d} ms", .{self.limits.timeout_ms + socket_grace_ms});
                return error.QueryTimeout;
            }
            self.setProblem("the connection to the database failed: {t}", .{err});
            return error.DatabaseUnavailable;
        };
        if (reply.get("ok")) |ok| {
            if (ok.truthy()) return reply;
        }
        return self.serverError(reply);
    }

    fn serverError(self: *Conn, reply: bson.Doc) engine.Error {
        const code = if (reply.get("code")) |c| c.int() orelse 0 else 0;
        const name = if (reply.get("codeName")) |c| c.string() orelse "" else "";
        const message = if (reply.get("errmsg")) |m| m.string() orelse "" else "";
        self.setProblem("{s}{s}{f}", .{ name, if (name.len != 0) ": " else "", Scrubbed{ .text = message } });
        return switch (code) {
            50 => blk: {
                self.setProblem("the query ran past the {d} ms timeout and was stopped (MaxTimeMSExpired)", .{self.limits.timeout_ms});
                break :blk error.QueryTimeout;
            },
            26 => error.TableNotFound,
            else => error.SqlFailed,
        };
    }

    fn command(self: *Conn, arena: Allocator, b: *bson.Builder) !bson.Doc {
        return self.send(arena, b, self.database);
    }

    fn loadCollections(self: *Conn) ![]const CollInfo {
        if (self.collections) |known| return known;
        const arena = self.state.allocator();
        var b = try begin(arena, "listCollections", 1);
        try b.boolean("authorizedCollections", true);
        try b.beginDoc("cursor");
        try b.end();
        try b.int64("maxTimeMS", self.limits.timeout_ms);
        const reply = try self.command(arena, &b);
        var list: std.ArrayList(CollInfo) = .empty;
        var cursor = try Cursor.open(self, arena, reply, "$cmd.listCollections", max_collections);
        while (try cursor.next()) |doc| {
            const name = (doc.get("name") orelse continue).string() orelse continue;
            const kind_text = if (doc.get("type")) |t| t.string() orelse "collection" else "collection";
            var entry: CollInfo = .{ .name = try arena.dupe(u8, name), .kind = if (std.mem.eql(u8, kind_text, "view")) .view else .table };
            if (entry.kind == .view) {
                if (doc.get("options")) |o| if (o.doc()) |options| {
                    if (options.get("viewOn")) |v| if (v.string()) |on| {
                        entry.view_on = try arena.dupe(u8, on);
                    };
                    if (options.get("pipeline")) |p| if (p.doc()) |stages| {
                        const text = try bson.toJson(arena, stages);
                        const parsed = std.json.parseFromSliceLeaky(Value, arena, text, .{}) catch null;
                        if (parsed) |value| {
                            if (value == .object) {
                                var items: std.ArrayList(Value) = .empty;
                                for (value.object.values()) |stage| try items.append(arena, stage);
                                entry.pipeline = items.items;
                            }
                        }
                    };
                };
            }
            try list.append(arena, entry);
        }
        self.collections = list.items;
        return list.items;
    }

    fn info(self: *Conn, name: []const u8) !?CollInfo {
        for (try self.loadCollections()) |known| {
            if (std.mem.eql(u8, known.name, name)) return known;
        }
        return null;
    }

    fn chain(self: *Conn, arena: Allocator, name: []const u8) ![]const []const u8 {
        var names: std.ArrayList([]const u8) = .empty;
        var current = name;
        for (0..max_view_depth) |_| {
            try names.append(arena, current);
            const found = (try self.info(current)) orelse break;
            if (found.kind != .view) break;
            current = found.view_on orelse break;
        } else return error.TableRefused;
        return names.items;
    }

    fn resolverChain(ptr: ?*anyopaque, arena: Allocator, name: []const u8) anyerror![]const []const u8 {
        const self: *Conn = @ptrCast(@alignCast(ptr.?));
        return self.chain(arena, name);
    }

    fn checker(self: *Conn, arena: Allocator, names: []const []const u8) guard.Checker {
        return .{ .arena = arena, .scope = .{ .access = self.access, .names = names }, .resolver = .{ .ptr = self, .chain = resolverChain } };
    }

    fn target(self: *Conn, arena: Allocator, name: []const u8) !guard.Scope {
        if (name.len == 0 or name[0] == '$' or std.mem.indexOfScalar(u8, name, 0) != null) {
            self.setProblem("{s} is not a collection name", .{name});
            return error.CommandInvalid;
        }
        const names = self.chain(arena, name) catch |err| {
            if (err == error.TableRefused) self.setProblem("{s} is a view nested more than {d} deep", .{ name, max_view_depth });
            return err;
        };
        const scope: guard.Scope = .{ .access = self.access, .names = names };
        if (scope.refusal()) |r| {
            const why = if (guard.isSystem(r.name)) "is a system collection" else if (r.why == .not_allowed) "is not on the allowed collection list" else "is blocked by the database access rules";
            if (std.mem.eql(u8, r.name, name)) {
                self.setProblem("collection {s} {s}", .{ name, why });
            } else self.setProblem("view {s} reads {s}, which {s}", .{ name, r.name, why });
            return error.TableRefused;
        }
        for (names[0 .. names.len - 1]) |view_name| {
            const view = (try self.info(view_name)) orelse continue;
            var check = self.checker(arena, names);
            check.raw = true;
            check.pipeline(view.pipeline, 1) catch |err| {
                if (err == error.OutOfMemory) return err;
                self.setProblem("view {s} is refused: its definition {s}", .{ view_name, check.message });
                return error.TableRefused;
            };
        }
        return scope;
    }

    fn guardFailed(self: *Conn, err: guard.Error, message: []const u8) anyerror {
        if (err == error.OutOfMemory) return err;
        self.setProblem("{s}", .{message});
        return err;
    }

    pub fn tables(self: *Conn, arena: Allocator) !engine.Tables {
        var shown: std.ArrayList(engine.TableInfo) = .empty;
        var withheld: usize = 0;
        for (try self.loadCollections()) |known| {
            if (guard.isSystem(known.name)) continue;
            const names = try self.chain(arena, known.name);
            if ((guard.Scope{ .access = self.access, .names = names }).refusal() != null) {
                withheld += 1;
                continue;
            }
            try shown.append(arena, .{ .name = try arena.dupe(u8, known.name), .kind = known.kind });
        }
        std.mem.sort(engine.TableInfo, shown.items, {}, struct {
            fn less(_: void, a: engine.TableInfo, b: engine.TableInfo) bool {
                return std.ascii.lessThanIgnoreCase(a.name, b.name);
            }
        }.less);
        return .{ .shown = shown.items, .withheld = withheld };
    }

    pub fn count(self: *Conn, arena: Allocator, name: []const u8) !i64 {
        _ = try self.target(arena, name);
        var b = try begin(arena, "count", name);
        try b.int64("maxTimeMS", self.limits.timeout_ms);
        const reply = try self.command(arena, &b);
        return (reply.get("n") orelse return 0).int() orelse 0;
    }

    pub fn describe(self: *Conn, arena: Allocator, name: []const u8) !engine.Description {
        const scope = try self.target(arena, name);
        const found = (try self.info(name)) orelse {
            self.setProblem("no collection or view named {s}", .{name});
            return error.TableNotFound;
        };
        var b = try begin(arena, "aggregate", name);
        const shape =
            \\[{"$sample":{"size":100}},{"$project":{"_id":0,"f":{"$map":{"input":{"$objectToArray":"$$ROOT"},"as":"p","in":{"k":"$$p.k","t":{"$type":"$$p.v"}}}}}}]
        ;
        const pipeline = try std.json.parseFromSliceLeaky(Value, arena, shape, .{});
        try b.json("pipeline", pipeline);
        try b.beginDoc("cursor");
        try b.int32("batchSize", describe_sample);
        try b.end();
        try b.int64("maxTimeMS", self.limits.timeout_ms);
        const reply = try self.command(arena, &b);
        const Field = struct { name: []const u8, types: std.ArrayList([]const u8) = .empty, seen: usize = 0, nulls: bool = false };
        var fields: std.ArrayList(Field) = .empty;
        var docs: usize = 0;
        var cursor = try Cursor.open(self, arena, reply, name, describe_sample);
        while (try cursor.next()) |doc| {
            docs += 1;
            const list = (doc.get("f") orelse continue).doc() orelse continue;
            var it = list.iterator();
            while (try it.next()) |pair_el| {
                const pair = pair_el.doc() orelse continue;
                const key = (pair.get("k") orelse continue).string() orelse continue;
                const kind = (pair.get("t") orelse continue).string() orelse continue;
                const slot = for (fields.items) |*f| {
                    if (std.mem.eql(u8, f.name, key)) break f;
                } else blk: {
                    try fields.append(arena, .{ .name = try arena.dupe(u8, key) });
                    break :blk &fields.items[fields.items.len - 1];
                };
                slot.seen += 1;
                if (std.mem.eql(u8, kind, "null")) slot.nulls = true;
                for (slot.types.items) |t| {
                    if (std.mem.eql(u8, t, kind)) break;
                } else try slot.types.append(arena, try arena.dupe(u8, kind));
            }
        }
        var columns: std.ArrayList(engine.ColumnInfo) = .empty;
        for (fields.items) |f| {
            var text: std.ArrayList(u8) = .empty;
            for (f.types.items, 0..) |t, i| {
                if (i != 0) try text.append(arena, '|');
                try text.appendSlice(arena, t);
            }
            if (f.seen < docs) try text.appendSlice(arena, "|missing");
            const how: engine.Treatment = if (scope.hidden(f.name)) .hidden else if (scope.mask(f.name)) |m| .{ .masked = m } else .plain;
            try columns.append(arena, .{
                .name = f.name,
                .decl_type = text.items,
                .not_null = f.seen == docs and !f.nulls,
                .primary_key = if (std.mem.eql(u8, f.name, "_id")) 1 else 0,
                .default = null,
                .generated = false,
                .treatment = how,
            });
        }
        var indexes: std.ArrayList(engine.IndexInfo) = .empty;
        if (found.kind == .table) {
            var ib = try begin(arena, "listIndexes", name);
            try ib.beginDoc("cursor");
            try ib.end();
            if (self.command(arena, &ib)) |index_reply| {
                var index_cursor = try Cursor.open(self, arena, index_reply, name, 1000);
                while (try index_cursor.next()) |doc| {
                    const index_name = (doc.get("name") orelse continue).string() orelse continue;
                    var keys: std.ArrayList([]const u8) = .empty;
                    if (doc.get("key")) |k| if (k.doc()) |key_doc| {
                        var kit = key_doc.iterator();
                        while (try kit.next()) |key| {
                            const dir = if (key.int()) |n| (if (n < 0) " desc" else "") else if (key.string()) |s| try std.fmt.allocPrint(arena, " {s}", .{s}) else "";
                            try keys.append(arena, try std.fmt.allocPrint(arena, "{s}{s}", .{ key.key, dir }));
                        }
                    };
                    const unique = if (doc.get("unique")) |u| u.truthy() else std.mem.eql(u8, index_name, "_id_");
                    try indexes.append(arena, .{ .name = try arena.dupe(u8, index_name), .unique = unique, .columns = keys.items });
                }
            } else |err| if (err == error.OutOfMemory) return err;
        }
        return .{ .table = try arena.dupe(u8, name), .kind = found.kind, .columns = columns.items, .indexes = indexes.items, .foreign_keys = &.{} };
    }

    pub fn sample(self: *Conn, arena: Allocator, name: []const u8, rows: u32, sink: engine.Sink) !engine.Outcome {
        const scope = try self.target(arena, name);
        if (scope.wholeGuarded()) {
            self.setProblem("every field of {s} is hidden or masked", .{name});
            return error.HiddenFieldUsed;
        }
        const cmd: guard.Command = .{ .verb = .{ .read = .find }, .collection = name };
        const cap = @min(rows, self.limits.max_rows);
        const hidden = try scope.hiddenNames(arena);
        const pipeline = try guard.readPipeline(arena, cmd, hidden, cap);
        return self.runRows(arena, name, scope, pipeline, cap, sink);
    }

    fn prepare(self: *Conn, arena: Allocator, text: []const u8) !struct { cmd: guard.Command, scope: guard.Scope, pipeline: []const Value } {
        var message: []const u8 = "";
        const cmd = guard.parse(arena, text, &message) catch |err| return self.guardFailed(err, message);
        if (cmd.verb != .read) {
            self.setProblem("emetgate_db only reads; {s} changes data and goes through emetgate_db_write after the user types /db write", .{cmd.verbName()});
            return error.StatementNotRead;
        }
        const scope = try self.target(arena, cmd.collection);
        var check = self.checker(arena, scope.names);
        guard.checkRead(&check, cmd) catch |err| return self.guardFailed(err, check.message);
        const hidden = try scope.hiddenNames(arena);
        const pipeline = try guard.readPipeline(arena, cmd, hidden, @as(i64, self.limits.max_rows) + 1);
        return .{ .cmd = cmd, .scope = scope, .pipeline = pipeline };
    }

    pub fn query(self: *Conn, arena: Allocator, text: []const u8, sink: engine.Sink) !engine.Outcome {
        const prepared = try self.prepare(arena, text);
        return self.runRows(arena, prepared.cmd.collection, prepared.scope, prepared.pipeline, self.limits.max_rows, sink);
    }

    fn aggregate(self: *Conn, arena: Allocator, name: []const u8, pipeline: []const Value, batch: u32) !bson.Doc {
        var b = try begin(arena, "aggregate", name);
        var list = std.json.Array.init(arena);
        try list.appendSlice(pipeline);
        b.json("pipeline", .{ .array = list }) catch |err| return self.encodeFailed(err);
        try b.beginDoc("cursor");
        try b.int32("batchSize", @intCast(@min(batch, std.math.maxInt(i32))));
        try b.end();
        try b.int64("maxTimeMS", self.limits.timeout_ms);
        return self.command(arena, &b);
    }

    fn encodeFailed(self: *Conn, err: bson.EncodeError) anyerror {
        switch (err) {
            error.OutOfMemory => return err,
            error.KeyHasNul => self.setProblem("a field name or regex holds a NUL character", .{}),
            error.TooDeep => self.setProblem("the command nests too deep", .{}),
            error.BadExtendedJson => self.setProblem("an extended JSON value ($oid, $date, $numberLong, $binary, ...) is malformed", .{}),
        }
        return error.CommandInvalid;
    }

    fn runRows(self: *Conn, arena: Allocator, name: []const u8, scope: guard.Scope, pipeline: []const Value, max_rows: u32, sink: engine.Sink) !engine.Outcome {
        const started = std.Io.Timestamp.now(self.io, .awake);
        const reply = try self.aggregate(arena, name, pipeline, max_rows + 1);
        var docs: std.ArrayList(bson.Doc) = .empty;
        var cursor = try Cursor.open(self, arena, reply, name, max_rows + 1);
        while (try cursor.next()) |doc| try docs.append(arena, doc);
        cursor.close();
        var outcome: engine.Outcome = .{};
        const hidden = try scope.hiddenNames(arena);
        var nulled: std.ArrayList([]const u8) = .empty;
        for (hidden) |field| try nulled.append(arena, try std.fmt.allocPrint(arena, "{s}.{s}", .{ name, field }));
        outcome.nulled = nulled.items;
        var columns: std.ArrayList(engine.ResultColumn) = .empty;
        for (docs.items[0..@min(docs.items.len, max_rows)]) |doc| {
            var it = doc.iterator();
            while (try it.next()) |element| {
                if (scope.hidden(element.key)) continue;
                for (columns.items) |known| {
                    if (std.mem.eql(u8, known.name, element.key)) break;
                } else {
                    const how: engine.Treatment = if (scope.mask(element.key)) |m| .{ .masked = m } else .plain;
                    try columns.append(arena, .{ .name = try arena.dupe(u8, element.key), .table = name, .origin = try arena.dupe(u8, element.key), .treatment = how });
                }
            }
        }
        try sink.begin(sink.ptr, columns.items);
        const values = try arena.alloc(engine.Value, columns.items.len);
        var row_arena = std.heap.ArenaAllocator.init(self.gpa);
        defer row_arena.deinit();
        for (docs.items, 0..) |doc, i| {
            if (i >= max_rows) {
                outcome.more = true;
                outcome.stop = .rows;
                break;
            }
            _ = row_arena.reset(.retain_capacity);
            for (values, columns.items) |*value, column| {
                const element = doc.get(column.name) orelse {
                    value.* = .null;
                    continue;
                };
                value.* = try cellValue(row_arena.allocator(), element, column.treatment);
            }
            if (!try sink.row(sink.ptr, values)) {
                outcome.more = true;
                outcome.stop = .bytes;
                break;
            }
            outcome.rows += 1;
        }
        if (!outcome.more and cursor.cut) {
            outcome.more = true;
            outcome.stop = .bytes;
        }
        outcome.elapsed_ms = elapsedSince(self.io, started);
        return outcome;
    }

    pub fn explain(self: *Conn, arena: Allocator, text: []const u8) ![]const []const u8 {
        const prepared = try self.prepare(arena, text);
        var b = try start(arena);
        try b.beginDoc("explain");
        try b.string("aggregate", prepared.cmd.collection);
        var list = std.json.Array.init(arena);
        try list.appendSlice(prepared.pipeline);
        b.json("pipeline", .{ .array = list }) catch |err| return self.encodeFailed(err);
        try b.beginDoc("cursor");
        try b.end();
        try b.end();
        try b.string("verbosity", "queryPlanner");
        try b.int64("maxTimeMS", self.limits.timeout_ms);
        const reply = try self.command(arena, &b);
        var lines: std.ArrayList([]const u8) = .empty;
        if (findDoc(reply, "winningPlan", 0)) |plan| try planLines(arena, &lines, plan, 0);
        if (reply.get("stages")) |s| if (s.doc()) |stages| {
            var it = stages.iterator();
            while (try it.next()) |st| {
                const sd = st.doc() orelse continue;
                var sit = sd.iterator();
                const first = (try sit.next()) orelse continue;
                if (std.mem.eql(u8, first.key, "$cursor")) continue;
                try lines.append(arena, try arena.dupe(u8, first.key));
            }
        };
        if (lines.items.len == 0) try lines.append(arena, "no plan returned");
        return lines.items;
    }

    pub fn write(self: *Conn, arena: Allocator, text: []const u8, permit: engine.Permit) !engine.WriteOutcome {
        if (self.mode != .write) {
            self.setProblem("this connection was opened read-only", .{});
            return error.ActionDenied;
        }
        var message: []const u8 = "";
        const cmd = guard.parse(arena, text, &message) catch |err| return self.guardFailed(err, message);
        if (cmd.verb != .write) {
            self.setProblem("{s} only reads; it changes nothing: run it with emetgate_db op query", .{cmd.verbName()});
            return error.StatementOnlyReads;
        }
        const scope = try self.target(arena, cmd.collection);
        var check = self.checker(arena, scope.names);
        guard.checkWrite(&check, cmd) catch |err| return self.guardFailed(err, check.message);
        const kind = cmd.verb.write;
        var destructive = kind == .drop;
        if (kind == .deleteMany or kind == .updateMany) {
            if (guard.isEmptyFilter(cmd.filter)) {
                destructive = true;
                if (!permit.destructive) self.setProblem("{s} with an empty filter changes every document of {s}; nothing was changed", .{ cmd.verbName(), cmd.collection });
            } else {
                const total = try self.countWhere(arena, cmd.collection, null);
                const matched = try self.countWhere(arena, cmd.collection, cmd.filter);
                if (total >= 2 and matched >= total) {
                    destructive = true;
                    if (!permit.destructive) self.setProblem("this {s} matches every document of {s} ({d}); nothing was changed", .{ cmd.verbName(), cmd.collection, total });
                }
            }
        } else if (kind == .drop and !permit.destructive) self.setProblem("dropping {s} is destructive; nothing was changed", .{cmd.collection});
        if (destructive and !permit.destructive) return error.DestructiveNotGranted;
        const started = std.Io.Timestamp.now(self.io, .awake);
        var changes: i64 = 0;
        var action: engine.WriteAction = .other;
        switch (kind) {
            .insertOne, .insertMany => {
                action = .insert;
                var b = try begin(arena, "insert", cmd.collection);
                var list = std.json.Array.init(arena);
                try list.appendSlice(cmd.documents);
                b.json("documents", .{ .array = list }) catch |err| return self.encodeFailed(err);
                try b.boolean("ordered", true);
                const reply = try self.command(arena, &b);
                try self.writeErrors(reply);
                changes = if (reply.get("n")) |n| n.int() orelse 0 else 0;
            },
            .updateOne, .updateMany => {
                action = .update;
                var b = try begin(arena, "update", cmd.collection);
                try b.beginArray("updates");
                try b.beginDoc("0");
                b.json("q", .{ .object = cmd.filter.? }) catch |err| return self.encodeFailed(err);
                b.json("u", .{ .object = cmd.update.? }) catch |err| return self.encodeFailed(err);
                try b.boolean("multi", kind == .updateMany);
                try b.boolean("upsert", cmd.upsert);
                try b.end();
                try b.end();
                try b.boolean("ordered", true);
                const reply = try self.command(arena, &b);
                try self.writeErrors(reply);
                changes = if (reply.get("nModified")) |n| n.int() orelse 0 else 0;
                if (reply.get("upserted")) |u| if (u.doc()) |list| {
                    var it = list.iterator();
                    while (try it.next()) |_| changes += 1;
                };
            },
            .deleteOne, .deleteMany => {
                action = .delete;
                var b = try begin(arena, "delete", cmd.collection);
                try b.beginArray("deletes");
                try b.beginDoc("0");
                b.json("q", .{ .object = cmd.filter.? }) catch |err| return self.encodeFailed(err);
                try b.int32("limit", if (kind == .deleteOne) 1 else 0);
                try b.end();
                try b.end();
                try b.boolean("ordered", true);
                const reply = try self.command(arena, &b);
                try self.writeErrors(reply);
                changes = if (reply.get("n")) |n| n.int() orelse 0 else 0;
            },
            .drop => {
                action = .drop;
                var b = try begin(arena, "drop", cmd.collection);
                _ = try self.command(arena, &b);
                self.collections = null;
            },
        }
        return .{ .action = action, .table = cmd.collection, .changes = changes, .destructive = destructive, .elapsed_ms = elapsedSince(self.io, started) };
    }

    fn countWhere(self: *Conn, arena: Allocator, name: []const u8, filter: ?std.json.ObjectMap) !i64 {
        var b = try begin(arena, "count", name);
        if (filter) |f| b.json("query", .{ .object = f }) catch |err| return self.encodeFailed(err);
        try b.int64("maxTimeMS", self.limits.timeout_ms);
        const reply = try self.command(arena, &b);
        return (reply.get("n") orelse return 0).int() orelse 0;
    }

    fn writeErrors(self: *Conn, reply: bson.Doc) !void {
        if (reply.get("writeErrors")) |w| if (w.doc()) |list| {
            var it = list.iterator();
            if (try it.next()) |first| {
                const e = first.doc() orelse return error.SqlFailed;
                const message = if (e.get("errmsg")) |m| m.string() orelse "" else "";
                self.setProblem("the write failed: {f}", .{Scrubbed{ .text = message }});
                return error.SqlFailed;
            }
        };
        if (reply.get("writeConcernError")) |w| if (w.doc()) |e| {
            const message = if (e.get("errmsg")) |m| m.string() orelse "" else "";
            self.setProblem("the write concern failed: {f}", .{Scrubbed{ .text = message }});
            return error.SqlFailed;
        };
    }
};

const Scrubbed = struct {
    text: []const u8,

    pub fn format(self: Scrubbed, w: *Writer) Writer.Error!void {
        var text = self.text;
        if (std.mem.indexOf(u8, text, "dup key")) |at| text = text[0..at];
        if (std.mem.indexOf(u8, text, "consideredValue")) |at| text = text[0..at];
        var end = @min(text.len, max_message_chars);
        while (end > 0 and end < text.len and (text[end] & 0xC0) == 0x80) end -= 1;
        try w.writeAll(text[0..end]);
        if (end < self.text.len) try w.writeAll("...");
    }
};

const Cursor = struct {
    conn: *Conn,
    arena: Allocator,
    name: []const u8,
    id: i64,
    batch: bson.Iterator,
    left: usize,
    fetched: usize,
    cut: bool = false,

    fn open(conn: *Conn, arena: Allocator, reply: bson.Doc, name: []const u8, limit: usize) !Cursor {
        const cursor = (reply.get("cursor") orelse return conn.badReply()).doc() orelse return conn.badReply();
        const first = (cursor.get("firstBatch") orelse return conn.badReply()).doc() orelse return conn.badReply();
        const id = (cursor.get("id") orelse return conn.badReply()).int() orelse 0;
        const ns = if (cursor.get("ns")) |n| n.string() orelse name else name;
        const coll = if (std.mem.indexOfScalar(u8, ns, '.')) |dot| ns[dot + 1 ..] else name;
        return .{ .conn = conn, .arena = arena, .name = try arena.dupe(u8, coll), .id = id, .batch = first.iterator(), .left = limit, .fetched = reply.bytes.len };
    }

    fn next(self: *Cursor) !?bson.Doc {
        if (self.left == 0) {
            self.close();
            return null;
        }
        while (true) {
            if (try self.batch.next()) |element| {
                self.left -= 1;
                return element.doc() orelse return self.conn.badReply();
            }
            if (self.id == 0) return null;
            if (self.fetched >= max_fetched_bytes) {
                self.cut = true;
                self.close();
                return null;
            }
            var b = try Conn.start(self.arena);
            try b.int64("getMore", self.id);
            try b.string("collection", self.name);
            try b.int32("batchSize", @intCast(@min(self.left, std.math.maxInt(i32))));
            try b.int64("maxTimeMS", self.conn.limits.timeout_ms);
            const reply = try self.conn.command(self.arena, &b);
            self.fetched += reply.bytes.len;
            const cursor = (reply.get("cursor") orelse return self.conn.badReply()).doc() orelse return self.conn.badReply();
            const batch = (cursor.get("nextBatch") orelse return self.conn.badReply()).doc() orelse return self.conn.badReply();
            self.id = (cursor.get("id") orelse return self.conn.badReply()).int() orelse 0;
            self.batch = batch.iterator();
        }
    }

    fn close(self: *Cursor) void {
        if (self.id == 0) return;
        const id = self.id;
        self.id = 0;
        var b = Conn.begin(self.arena, "killCursors", self.name) catch return;
        b.beginArray("cursors") catch return;
        b.int64("0", id) catch return;
        b.end() catch return;
        _ = self.conn.command(self.arena, &b) catch {};
    }
};

fn findDoc(doc: bson.Doc, key: []const u8, depth: usize) ?bson.Doc {
    if (depth > 12) return null;
    var it = doc.iterator();
    while (it.next() catch null) |element| {
        if (std.mem.eql(u8, element.key, key)) {
            if (element.doc()) |found| return found;
        }
        if (element.doc()) |child| {
            if (findDoc(child, key, depth + 1)) |found| return found;
        }
    }
    return null;
}

fn planLines(arena: Allocator, lines: *std.ArrayList([]const u8), plan: bson.Doc, depth: usize) !void {
    if (depth > 20 or lines.items.len > 200) return;
    var next_depth = depth;
    if (plan.get("stage")) |s| if (s.string()) |stage_name| {
        var line: std.ArrayList(u8) = .empty;
        try line.appendNTimes(arena, ' ', depth * 2);
        try line.appendSlice(arena, stage_name);
        if (plan.get("indexName")) |i| if (i.string()) |index_name| try line.print(arena, " {s}", .{index_name});
        if (plan.get("direction")) |d| if (d.string()) |dir| try line.print(arena, " {s}", .{dir});
        try lines.append(arena, line.items);
        next_depth += 1;
    };
    for ([_][]const u8{ "queryPlan", "inputStage", "outerStage", "innerStage" }) |key| {
        if (plan.get(key)) |child| if (child.doc()) |sub| try planLines(arena, lines, sub, next_depth);
    }
    if (plan.get("inputStages")) |many| if (many.doc()) |list| {
        var it = list.iterator();
        while (try it.next()) |child| if (child.doc()) |sub| try planLines(arena, lines, sub, next_depth);
    };
}

fn elapsedSince(io: std.Io, started: std.Io.Timestamp) u64 {
    const ns = started.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
    return @intCast(@max(@divTrunc(ns, std.time.ns_per_ms), 0));
}

pub fn cellValue(arena: Allocator, element: bson.Element, how: engine.Treatment) !engine.Value {
    switch (how) {
        .hidden => return .null,
        .masked => |mask| {
            if (element.kind == .null or element.kind == .undefined) return .null;
            var out: Writer.Allocating = .init(arena);
            switch (element.kind) {
                .string => try access_mod.writeMasked(&out.writer, mask, element.string() orelse ""),
                .int32, .int64 => try access_mod.writeMasked(&out.writer, mask, try std.fmt.allocPrint(arena, "{d}", .{element.int().?})),
                .double => try access_mod.writeMasked(&out.writer, mask, try std.fmt.allocPrint(arena, "{d}", .{element.float().?})),
                else => try out.writer.writeAll("***"),
            }
            return .{ .text = out.written() };
        },
        .plain => return switch (element.kind) {
            .null, .undefined => .null,
            .string => .{ .text = element.string() orelse "" },
            .int32, .int64 => .{ .integer = element.int().? },
            .double => blk: {
                const f = element.float().?;
                if (std.math.isFinite(f)) break :blk .{ .real = f };
                var out: Writer.Allocating = .init(arena);
                try bson.writeRelaxed(&out.writer, element);
                break :blk .{ .json = out.written() };
            },
            else => blk: {
                var out: Writer.Allocating = .init(arena);
                try bson.writeRelaxed(&out.writer, element);
                break :blk .{ .json = out.written() };
            },
        },
    }
}

fn helloCommand(arena: Allocator, uri: Uri, legacy: bool) !bson.Builder {
    var b: bson.Builder = .init(arena);
    try b.begin();
    try b.int32(if (legacy) "isMaster" else "hello", 1);
    if (!legacy) try b.boolean("helloOk", true);
    try b.beginDoc("client");
    try b.beginDoc("driver");
    try b.string("name", "emetgate");
    try b.string("version", "1");
    try b.end();
    try b.beginDoc("os");
    try b.string("type", "Windows");
    try b.end();
    try b.end();
    if (uri.user) |user| try b.string("saslSupportedMechs", try std.fmt.allocPrint(arena, "{s}.{s}", .{ uri.auth_source, user }));
    try b.string("$db", "admin");
    try b.end();
    return b;
}

const Hello = struct { writable: bool, mechanism: scram.Mechanism };

fn handshake(transport: *wire.Transport, arena: Allocator, uri: Uri, why: *OpenProblem) !Hello {
    var b = try helloCommand(arena, uri, false);
    var reply = transport.roundTrip(arena, b.bytes()) catch |err| {
        why.set("the server did not answer the MongoDB handshake: {t}", .{err});
        return error.DatabaseUnavailable;
    };
    if (reply.get("ok")) |ok| if (!ok.truthy()) {
        b = try helloCommand(arena, uri, true);
        reply = transport.roundTrip(arena, b.bytes()) catch |err| {
            why.set("the server did not answer the MongoDB handshake: {t}", .{err});
            return error.DatabaseUnavailable;
        };
    };
    if (reply.get("maxWireVersion")) |v| {
        if ((v.int() orelse 0) < 6) {
            why.set("the server speaks a MongoDB wire version older than 3.6, which emetgate does not support", .{});
            return error.DatabaseUnavailable;
        }
    }
    const writable = if (reply.get("isWritablePrimary") orelse reply.get("ismaster")) |w| w.truthy() else false;
    var mechanism: scram.Mechanism = .sha256;
    if (reply.get("saslSupportedMechs")) |m| if (m.doc()) |list| {
        var any256 = false;
        var any1 = false;
        var it = list.iterator();
        while (it.next() catch null) |item| {
            const text = item.string() orelse continue;
            if (std.mem.eql(u8, text, "SCRAM-SHA-256")) any256 = true;
            if (std.mem.eql(u8, text, "SCRAM-SHA-1")) any1 = true;
        }
        if (!any256 and any1) mechanism = .sha1;
    };
    return .{ .writable = writable, .mechanism = uri.mechanism orelse mechanism };
}

fn authenticate(io: std.Io, transport: *wire.Transport, arena: Allocator, uri: Uri, mechanism: scram.Mechanism, why: *OpenProblem) !void {
    const user = uri.user orelse return;
    const password = uri.password orelse "";
    var raw: [18]u8 = undefined;
    io.random(&raw);
    var nonce: [24]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&nonce, &raw);
    var client = try scram.Client.init(arena, mechanism, user, password, &nonce);
    var b: bson.Builder = .init(arena);
    try b.begin();
    try b.int32("saslStart", 1);
    try b.string("mechanism", mechanism.name());
    try b.binary("payload", 0, try client.first(arena));
    try b.beginDoc("options");
    try b.boolean("skipEmptyExchange", true);
    try b.end();
    try b.string("$db", uri.auth_source);
    try b.end();
    var reply = try authStep(transport, arena, b.bytes(), why);
    const conversation = reply.get("conversationId") orelse return authFailed(why, "the server sent no conversationId");
    const server_first = (reply.get("payload") orelse return authFailed(why, "the server sent no SCRAM payload")).binary() orelse return authFailed(why, "the SCRAM payload is not binary");
    const final = client.final(arena, server_first.bytes) catch return authFailed(why, "the server's SCRAM challenge is malformed");
    var c: bson.Builder = .init(arena);
    try c.begin();
    try c.int32("saslContinue", 1);
    try c.raw("conversationId", conversation.kind, conversation.data);
    try c.binary("payload", 0, final);
    try c.string("$db", uri.auth_source);
    try c.end();
    reply = try authStep(transport, arena, c.bytes(), why);
    const server_final = (reply.get("payload") orelse return authFailed(why, "the server sent no SCRAM signature")).binary() orelse return authFailed(why, "the SCRAM signature is not binary");
    client.verify(server_final.bytes) catch return authFailed(why, "the server's SCRAM signature does not match: it does not know the password, so it is not the server you configured");
    var done = if (reply.get("done")) |d| d.truthy() else false;
    var rounds: usize = 0;
    while (!done and rounds < 2) : (rounds += 1) {
        var e: bson.Builder = .init(arena);
        try e.begin();
        try e.int32("saslContinue", 1);
        try e.raw("conversationId", conversation.kind, conversation.data);
        try e.binary("payload", 0, "");
        try e.string("$db", uri.auth_source);
        try e.end();
        reply = try authStep(transport, arena, e.bytes(), why);
        done = if (reply.get("done")) |d| d.truthy() else false;
    }
    if (!done) return authFailed(why, "the SCRAM conversation did not finish");
}

fn authStep(transport: *wire.Transport, arena: Allocator, body: []const u8, why: *OpenProblem) !bson.Doc {
    const reply = transport.roundTrip(arena, body) catch |err| {
        why.set("authentication failed: {t}", .{err});
        return error.DatabaseUnavailable;
    };
    if (reply.get("ok")) |ok| if (ok.truthy()) return reply;
    const message = if (reply.get("errmsg")) |m| m.string() orelse "" else "";
    why.set("authentication failed: {s}", .{message});
    return error.DatabaseUnavailable;
}

fn authFailed(why: *OpenProblem, message: []const u8) error{DatabaseUnavailable} {
    why.set("authentication failed: {s}", .{message});
    return error.DatabaseUnavailable;
}

pub fn open(gpa: Allocator, uri_text: []const u8, settings: engine.Settings, why: *OpenProblem) !*Conn {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var uri_why: []const u8 = "the connection string is not a valid mongodb:// URI";
    const uri = parseUri(arena, uri_text, &uri_why) catch |err| {
        if (err == error.OutOfMemory) return err;
        why.set("{s}", .{uri_why});
        return error.DatabaseUnavailable;
    };
    defer if (uri.password) |p| std.crypto.secureZero(u8, @constCast(p));
    var last: OpenProblem = .{};
    last.set("no host was reachable", .{});
    for (uri.hosts) |host| {
        const sock = wire.connectHost(gpa, host.name, host.port, uri.connect_timeout_ms) catch |err| {
            if (err == error.OutOfMemory) return err;
            last.set("{s}:{d} is not reachable: {t}", .{ host.name, host.port, err });
            continue;
        };
        const transport = wire.Transport.open(gpa, settings.io, sock, if (uri.tls) .{ .host = host.name, .verify_certificate = uri.verify_certificate, .verify_host = uri.verify_host } else null, settings.limits.timeout_ms + socket_grace_ms) catch |err| {
            if (err == error.OutOfMemory) return err;
            _ = wire.closesocket(sock);
            last.set("the TLS handshake with {s}:{d} failed: {t}{s}", .{ host.name, host.port, err, if (err == error.TlsUnexpectedMessage) " (the server most likely asks for a client certificate, as mongod does when started with tlsCAFile; emetgate's TLS client cannot answer that request)" else "" });
            continue;
        };
        var keep = false;
        defer if (!keep) transport.close();
        const hello = handshake(transport, arena, uri, &last) catch |err| {
            if (err == error.OutOfMemory) return err;
            continue;
        };
        if (settings.mode == .write and !hello.writable and uri.hosts.len > 1) {
            last.set("{s}:{d} is not the writable primary", .{ host.name, host.port });
            continue;
        }
        authenticate(settings.io, transport, arena, uri, hello.mechanism, &last) catch |err| {
            if (err == error.OutOfMemory) return err;
            why.* = last;
            return error.DatabaseUnavailable;
        };
        const self = try gpa.create(Conn);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = settings.io,
            .transport = transport,
            .access = settings.access,
            .limits = settings.limits,
            .mode = settings.mode,
            .database = "",
            .secondary = !hello.writable,
            .state = .init(gpa),
        };
        self.database = try self.state.allocator().dupe(u8, uri.database);
        keep = true;
        return self;
    }
    why.* = last;
    return error.DatabaseUnavailable;
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

fn vQuery(ptr: *anyopaque, arena: Allocator, text: []const u8, sink: engine.Sink) anyerror!engine.Outcome {
    const self: *Conn = @ptrCast(@alignCast(ptr));
    return self.query(arena, text, sink);
}

fn vExplain(ptr: *anyopaque, arena: Allocator, text: []const u8) anyerror![]const []const u8 {
    const self: *Conn = @ptrCast(@alignCast(ptr));
    return self.explain(arena, text);
}

fn vWrite(ptr: *anyopaque, arena: Allocator, text: []const u8, permit: engine.Permit) anyerror!engine.WriteOutcome {
    const self: *Conn = @ptrCast(@alignCast(ptr));
    return self.write(arena, text, permit);
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

test "db mongo: a mongodb:// URI yields hosts, user, password, database, authSource and TLS settings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var why: []const u8 = "";
    const uri = try parseUri(arena.allocator(), "mongodb://app%40corp:p%3Ass@db1.local:27018,db2.local,[::1]:27019/shop?authSource=admin&tls=true&tlsAllowInvalidHostnames=true&replicaSet=rs0", &why);
    try testing.expectEqual(@as(usize, 3), uri.hosts.len);
    try testing.expectEqualStrings("db1.local", uri.hosts[0].name);
    try testing.expectEqual(@as(u16, 27018), uri.hosts[0].port);
    try testing.expectEqual(default_port, uri.hosts[1].port);
    try testing.expectEqualStrings("::1", uri.hosts[2].name);
    try testing.expectEqualStrings("app@corp", uri.user.?);
    try testing.expectEqualStrings("p:ss", uri.password.?);
    try testing.expectEqualStrings("shop", uri.database);
    try testing.expectEqualStrings("admin", uri.auth_source);
    try testing.expect(uri.tls and uri.verify_certificate and !uri.verify_host);
    const plain = try parseUri(arena.allocator(), "mongodb://localhost/app", &why);
    try testing.expectEqualStrings("app", plain.auth_source);
    try testing.expect(plain.user == null and !plain.tls);
}

test "db mongo: SRV, a missing database, X.509 and an unknown option are refused with a reason" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var why: []const u8 = "";
    try testing.expectError(error.SrvNotSupported, parseUri(arena.allocator(), "mongodb+srv://u:p@cluster0.example.net/app", &why));
    try testing.expect(std.mem.indexOf(u8, why, "SRV") != null);
    try testing.expectError(error.InvalidUri, parseUri(arena.allocator(), "mongodb://localhost:27017", &why));
    try testing.expectError(error.InvalidUri, parseUri(arena.allocator(), "mongodb://localhost/app?authMechanism=MONGODB-X509", &why));
    try testing.expectError(error.InvalidUri, parseUri(arena.allocator(), "mongodb://localhost/app?frobnicate=1", &why));
    try testing.expectError(error.InvalidUri, parseUri(arena.allocator(), "mongodb://localhost:notaport/app", &why));
    try testing.expectError(error.InvalidUri, parseUri(arena.allocator(), "mongodb://localhost/a.b", &why));
}

test "db mongo: a server error message drops the duplicate key and the considered value" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try out.writer.print("{f}", .{Scrubbed{ .text = "E11000 duplicate key error collection: app.users index: ssn_1 dup key: { ssn: \"111-22-3333\" }" }});
    try testing.expect(std.mem.indexOf(u8, out.written(), "111-22") == null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "E11000") != null);
}
