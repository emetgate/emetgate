const std = @import("std");
const doctor = @import("../platform/doctor.zig");
const config = @import("config.zig");
const credentials = @import("credentials.zig");
const sqlite = @import("sqlite.zig");
const postgres = @import("postgres.zig");
const mongo = @import("mongo.zig");
const access = @import("access.zig");

const Allocator = std.mem.Allocator;
const Check = doctor.Check;

pub fn append(arena: Allocator, io: std.Io, root: ?[]const u8, checks: *std.ArrayList(Check)) !void {
    const repo_root = root orelse return;
    var loaded = config.load(arena, io, repo_root) catch |err| {
        if (err == error.OutOfMemory) return err;
        try checks.append(arena, .{ .name = "databases", .status = .warn, .detail = try std.fmt.allocPrint(arena, "{s} or %LOCALAPPDATA%\\emetgate\\db\\rules.json cannot be read ({t}), so emetgate_db refuses every call", .{ config.repo_path, err }), .fix = "repair or delete the file, then: emetgate db list" });
        return;
    };
    defer loaded.deinit();
    for (loaded.databases) |*db| try checks.append(arena, try check(arena, io, &loaded, db, repo_root));
}

fn check(arena: Allocator, io: std.Io, loaded: *config.Config, db: *const config.Database, root: []const u8) !Check {
    const name = try std.fmt.allocPrint(arena, "db {s}", .{db.name});
    if (!db.kind.supported()) {
        const sealed = if (db.credential) |cred| credentials.exists(arena, io, cred) else false;
        return .{ .name = name, .status = .warn, .detail = try std.fmt.allocPrint(arena, "{s} {s}: this version does not serve {s} yet; the connection string is {s}", .{ @tagName(db.kind), db.display orelse "", @tagName(db.kind), if (sealed) "sealed with DPAPI" else "missing from the credential store" }), .fix = if (sealed) "" else try std.fmt.allocPrint(arena, "emetgate db remove {s}, then add it again", .{db.name}) };
    }
    const rules = loaded.accessFor(db) catch {
        return .{ .name = name, .status = .warn, .detail = "a hidden or masked entry is not table.column, so emetgate_db refuses it", .fix = "fix it with emetgate db unset and emetgate db hide or mask" };
    };
    if (db.kind == .postgres) return checkPostgres(arena, io, db, rules, name);
    if (db.kind == .mongodb) return checkMongo(arena, io, db, rules, name);
    const path = try loaded.location(db, root);
    var why: sqlite.OpenProblem = .{};
    const conn = sqlite.open(arena, path, .{ .io = io, .mode = .read, .access = rules, .limits = db.limits }, &why) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{ .name = name, .status = .warn, .detail = try arena.dupe(u8, why.text()), .fix = try std.fmt.allocPrint(arena, "point it at the right file: emetgate db remove {s}, then emetgate db add {s} <file.db>", .{ db.name, db.name }) };
    };
    defer conn.close();
    const listed = conn.tables(arena) catch {
        return .{ .name = name, .status = .warn, .detail = try std.fmt.allocPrint(arena, "{s} opens but its schema cannot be read: {s}", .{ path, conn.problem() }) };
    };
    const guarded = rules.hidden.len + rules.masked.len != 0;
    const summary = try std.fmt.allocPrint(arena, "sqlite {s}: {d} tables and views shown, {d} withheld; {d} hidden, {d} masked, {d} blocked; read-only, writes only after /db write", .{ db.path.?, listed.shown.len, listed.withheld, rules.hidden.len, rules.masked.len, rules.blocked_tables.len });
    if (guarded and !credentials.blocksLowRead(arena, path)) {
        return .{ .name = name, .status = .warn, .detail = try std.fmt.allocPrint(arena, "{s}; but the file itself is readable by low-integrity commands, so emetgate_run could copy the hidden and masked values out of it", .{summary}), .fix = try std.fmt.allocPrint(arena, "emetgate db protect {s}", .{db.name}) };
    }
    if (guarded and insideRoot(path, root)) {
        return .{ .name = name, .status = .warn, .detail = try std.fmt.allocPrint(arena, "{s}; but the file is inside the repository, where the file and search tools can see its bytes", .{summary}), .fix = "keep the database outside the repository and add it by its absolute path" };
    }
    return .{ .name = name, .status = .ok, .detail = summary };
}

fn checkPostgres(arena: Allocator, io: std.Io, db: *const config.Database, rules: @import("access.zig").Access, name: []const u8) !Check {
    const shown = db.display orelse "";
    const again = try std.fmt.allocPrint(arena, "emetgate db remove {s}, then emetgate db add {s} postgres://user@host:5432/db?sslmode=verify-full", .{ db.name, db.name });
    const secret = credentials.load(arena, io, db.credential orelse db.name) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{ .name = name, .status = .warn, .detail = try std.fmt.allocPrint(arena, "postgres {s}: the connection string cannot be read from the credential store ({t})", .{ shown, err }), .fix = again };
    };
    defer credentials.wipe(arena, secret);
    const target = postgres.parseUrl(arena, secret) catch {
        return .{ .name = name, .status = .warn, .detail = try std.fmt.allocPrint(arena, "postgres {s}: the sealed connection string is not a postgres:// URL emetgate reads", .{shown}), .fix = again };
    };
    var why: postgres.OpenProblem = .{};
    const conn = postgres.open(arena, target, .{ .io = io, .mode = .read, .access = rules, .limits = db.limits }, &why) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{ .name = name, .status = .warn, .detail = try std.fmt.allocPrint(arena, "postgres {s}: {s}", .{ shown, why.text() }), .fix = "check that the server is reachable and the password is right; emetgate db add stores a new one" };
    };
    defer conn.close();
    const listed = conn.tables(arena) catch {
        return .{ .name = name, .status = .warn, .detail = try std.fmt.allocPrint(arena, "postgres {s} connects but its tables cannot be listed: {s}", .{ shown, conn.problem() }) };
    };
    const role = conn.roleFacts(arena) catch {
        return .{ .name = name, .status = .warn, .detail = try std.fmt.allocPrint(arena, "postgres {s} connects but its role cannot be read: {s}", .{ shown, conn.problem() }) };
    };
    const summary = try std.fmt.allocPrint(arena, "postgres {s} (server {s}, {s}, role {s}): {d} tables and views shown, {d} withheld; {d} hidden, {d} masked, {d} blocked; every read runs in a READ ONLY transaction, writes only after /db write", .{ shown, conn.version(), if (conn.encrypted) "TLS" else "no TLS", role.user, listed.shown.len, listed.withheld, rules.hidden.len, rules.masked.len, rules.blocked_tables.len });
    if (role.superuser) {
        return .{ .name = name, .status = .warn, .detail = try std.fmt.allocPrint(arena, "{s}; but role {s} is a superuser, which can read every file and setting of the server outside emetgate's checks", .{ summary, role.user }), .fix = "connect with a least-privilege role: CREATE ROLE emetgate_reader LOGIN PASSWORD '...'; GRANT SELECT ON the tables it may read; then emetgate db remove and add it with that role" };
    }
    if (role.can_write) {
        return .{ .name = name, .status = .warn, .detail = try std.fmt.allocPrint(arena, "{s}; but role {s} can INSERT, UPDATE, DELETE or TRUNCATE, so only emetgate's checks keep reads read-only", .{ summary, role.user }), .fix = "connect with a role that has only SELECT; give write rights to a second database entry you use with /db write" };
    }
    if (!conn.encrypted and !isLocal(target.host)) {
        return .{ .name = name, .status = .warn, .detail = try std.fmt.allocPrint(arena, "{s}; but the connection to {s} is not encrypted", .{ summary, target.host }), .fix = "add sslmode=verify-full (or require) to the connection string" };
    }
    if (conn.auth_note.len != 0) return .{ .name = name, .status = .warn, .detail = try std.fmt.allocPrint(arena, "{s}; but {s}", .{ summary, conn.auth_note }) };
    return .{ .name = name, .status = .ok, .detail = summary };
}

fn isLocal(host: []const u8) bool {
    return std.ascii.eqlIgnoreCase(host, "localhost") or std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "::1");
}

fn checkMongo(arena: Allocator, io: std.Io, db: *const config.Database, rules: access.Access, name: []const u8) !Check {
    const display = db.display orelse "";
    const secret = credentials.load(arena, io, db.credential orelse db.name) catch |err| {
        return .{ .name = name, .status = .warn, .detail = try std.fmt.allocPrint(arena, "mongodb {s}: the sealed connection string cannot be read ({t})", .{ display, err }), .fix = try std.fmt.allocPrint(arena, "emetgate db remove {s}, then add it again", .{db.name}) };
    };
    defer credentials.wipe(arena, secret);
    var why: mongo.OpenProblem = .{};
    const conn = mongo.open(arena, secret, .{ .io = io, .mode = .read, .access = rules, .limits = db.limits }, &why) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{ .name = name, .status = .warn, .detail = try std.fmt.allocPrint(arena, "mongodb {s}: {s}", .{ display, why.text() }), .fix = "start the server or fix the address, then: emetgate db list" };
    };
    defer conn.close();
    const listed = conn.tables(arena) catch {
        return .{ .name = name, .status = .warn, .detail = try std.fmt.allocPrint(arena, "mongodb {s} answers but its collections cannot be listed: {s}", .{ display, conn.problem() }) };
    };
    const summary = try std.fmt.allocPrint(arena, "mongodb {s}: {d} collections and views shown, {d} withheld; {d} hidden, {d} masked, {d} blocked; read-only, writes only after /db write", .{ display, listed.shown.len, listed.withheld, rules.hidden.len, rules.masked.len, rules.blocked_tables.len });
    if (std.mem.indexOfScalar(u8, display, '@') == null and rules.hidden.len + rules.masked.len + rules.blocked_tables.len != 0) {
        return .{ .name = name, .status = .warn, .detail = try std.fmt.allocPrint(arena, "{s}; but the server takes connections without a password, so any program on this machine, emetgate_run included, can read the hidden and masked fields directly", .{summary}), .fix = "turn on MongoDB authentication and add the database again with a user: mongodb://user:password@host/db" };
    }
    return .{ .name = name, .status = .ok, .detail = summary };
}

fn insideRoot(path: []const u8, root: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, root, "\\/");
    return path.len > trimmed.len + 1 and std.ascii.eqlIgnoreCase(path[0..trimmed.len], trimmed) and (path[trimmed.len] == '\\' or path[trimmed.len] == '/');
}
