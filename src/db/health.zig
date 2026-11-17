const std = @import("std");
const doctor = @import("../platform/doctor.zig");
const config = @import("config.zig");
const credentials = @import("credentials.zig");
const sqlite = @import("sqlite.zig");

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
        return .{ .name = name, .status = .warn, .detail = try std.fmt.allocPrint(arena, "{s} {s}: this version serves sqlite only; the connection string is {s}", .{ @tagName(db.kind), db.display orelse "", if (sealed) "sealed with DPAPI" else "missing from the credential store" }), .fix = if (sealed) "" else try std.fmt.allocPrint(arena, "emetgate db remove {s}, then add it again", .{db.name}) };
    }
    const rules = loaded.accessFor(db) catch {
        return .{ .name = name, .status = .warn, .detail = "a hidden or masked entry is not table.column, so emetgate_db refuses it", .fix = "fix it with emetgate db unset and emetgate db hide or mask" };
    };
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

fn insideRoot(path: []const u8, root: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, root, "\\/");
    return path.len > trimmed.len + 1 and std.ascii.eqlIgnoreCase(path[0..trimmed.len], trimmed) and (path[trimmed.len] == '\\' or path[trimmed.len] == '/');
}
