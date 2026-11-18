const std = @import("std");
const access = @import("../db/access.zig");
const engine = @import("../db/engine.zig");
const config = @import("../db/config.zig");
const credentials = @import("../db/credentials.zig");
const grant = @import("../db/grant.zig");
const sqlite = @import("../db/sqlite.zig");
const postgres = @import("../db/postgres.zig");
const mongo = @import("../db/mongo.zig");
const prompt_words = @import("prompt_words.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Map = std.process.Environ.Map;

pub const slash = "/db";
pub const global_flag = "--global";
pub const destructive_flag = "--destructive";
pub const password_variable = "PGPASSWORD";

pub var env_password: ?[]const u8 = null;

pub fn usage(comptime prefix: []const u8) []const u8 {
    return prefix ++ "add <name> <file.db | mongodb://user[:password]@host[:port]/db[?authSource=..&tls=true] | postgres://user[:password]@host[:port]/db[?sslmode=disable|prefer|require|verify-full] | mysql://...>   (a postgres password may come from %PGPASSWORD% instead)\n" ++
        prefix ++ "list [--json]\n" ++
        prefix ++ "remove <name>\n" ++
        prefix ++ "hide (<name> | --global) <table.column>   (the model reads it as NULL everywhere)\n" ++
        prefix ++ "mask (<name> | --global) <table.column> [--mode partial|email|full] [--keep <n>]\n" ++
        prefix ++ "block (<name> | --global) <table>\n" ++
        prefix ++ "allow <name> <table>   (once any table is allowed, only allowed tables are read)\n" ++
        prefix ++ "unset (<name> | --global) <table.column | table>   (drop a hide, mask, block or allow entry)\n" ++
        prefix ++ "protect <name>   (label the SQLite file so low-integrity commands such as emetgate_run cannot read its bytes)\n" ++
        prefix ++ "limit <name> <max-rows | max-cell-chars | max-result-bytes | timeout-ms | rate-per-minute> <n>\n";
}

pub const slash_usage =
    "/db write [<name>] [--destructive]   (lets the model write to the database during your next prompt's turn only)\n" ++
    "/db read   (turns write mode off now)\n" ++
    "/db status   (the configured databases and whether write mode is on)\n";

pub const Scope = union(enum) {
    db: []const u8,
    global,
};

pub const Request = union(enum) {
    add: struct { name: []const u8, target: []const u8 },
    list: struct { json: bool },
    remove: []const u8,
    protect: []const u8,
    hide: struct { scope: Scope, column: []const u8 },
    mask: struct { scope: Scope, column: []const u8, mode: access.MaskMode, keep: u8 },
    block: struct { scope: Scope, table: []const u8 },
    allow: struct { name: []const u8, table: []const u8 },
    unset: struct { scope: Scope, entry: []const u8 },
    limit: struct { name: []const u8, field: engine.Limits.Field, value: u32 },
};

fn scopeOf(text: []const u8) ?Scope {
    if (std.mem.eql(u8, text, global_flag)) return .global;
    if (!config.validName(text)) return null;
    return .{ .db = text };
}

pub fn parse(args: []const [:0]const u8) ?Request {
    if (args.len == 0) return null;
    const verb: []const u8 = args[0];
    const rest = args[1..];
    if (std.mem.eql(u8, verb, "add")) {
        if (rest.len != 2 or !config.validName(rest[0]) or rest[1].len == 0) return null;
        return .{ .add = .{ .name = rest[0], .target = rest[1] } };
    }
    if (std.mem.eql(u8, verb, "list")) {
        if (rest.len == 0) return .{ .list = .{ .json = false } };
        if (rest.len == 1 and std.mem.eql(u8, rest[0], "--json")) return .{ .list = .{ .json = true } };
        return null;
    }
    if (std.mem.eql(u8, verb, "remove")) {
        if (rest.len != 1 or !config.validName(rest[0])) return null;
        return .{ .remove = rest[0] };
    }
    if (std.mem.eql(u8, verb, "protect")) {
        if (rest.len != 1 or !config.validName(rest[0])) return null;
        return .{ .protect = rest[0] };
    }
    if (std.mem.eql(u8, verb, "hide")) {
        if (rest.len != 2 or access.Column.parse(rest[1]) == null) return null;
        return .{ .hide = .{ .scope = scopeOf(rest[0]) orelse return null, .column = rest[1] } };
    }
    if (std.mem.eql(u8, verb, "mask")) {
        if (rest.len < 2 or access.Column.parse(rest[1]) == null) return null;
        var mode: ?access.MaskMode = null;
        var keep: ?u8 = null;
        var i: usize = 2;
        while (i < rest.len) : (i += 2) {
            if (i + 1 >= rest.len) return null;
            const value: []const u8 = rest[i + 1];
            if (std.mem.eql(u8, rest[i], "--mode") and mode == null) {
                mode = access.MaskMode.parse(value) orelse return null;
            } else if (std.mem.eql(u8, rest[i], "--keep") and keep == null) {
                const n = std.fmt.parseUnsigned(u8, value, 10) catch return null;
                if (n > access.max_keep) return null;
                keep = n;
            } else return null;
        }
        return .{ .mask = .{ .scope = scopeOf(rest[0]) orelse return null, .column = rest[1], .mode = mode orelse .partial, .keep = keep orelse access.default_keep } };
    }
    if (std.mem.eql(u8, verb, "block")) {
        if (rest.len != 2 or !access.validName(rest[1])) return null;
        return .{ .block = .{ .scope = scopeOf(rest[0]) orelse return null, .table = rest[1] } };
    }
    if (std.mem.eql(u8, verb, "allow")) {
        if (rest.len != 2 or !config.validName(rest[0]) or !access.validName(rest[1])) return null;
        return .{ .allow = .{ .name = rest[0], .table = rest[1] } };
    }
    if (std.mem.eql(u8, verb, "unset")) {
        if (rest.len != 2 or rest[1].len == 0) return null;
        return .{ .unset = .{ .scope = scopeOf(rest[0]) orelse return null, .entry = rest[1] } };
    }
    if (std.mem.eql(u8, verb, "limit")) {
        if (rest.len != 3 or !config.validName(rest[0])) return null;
        const field = engine.Limits.parseField(rest[1]) orelse return null;
        const value = std.fmt.parseUnsigned(u32, rest[2], 10) catch return null;
        var probe: engine.Limits = .{};
        probe.set(field, value) catch return null;
        return .{ .limit = .{ .name = rest[0], .field = field, .value = value } };
    }
    return null;
}

const Kind = engine.Kind;

fn kindOfUrl(url: []const u8) ?Kind {
    const end = std.mem.indexOf(u8, url, "://") orelse return null;
    const scheme = url[0..end];
    if (std.ascii.eqlIgnoreCase(scheme, "postgres") or std.ascii.eqlIgnoreCase(scheme, "postgresql")) return .postgres;
    if (std.ascii.eqlIgnoreCase(scheme, "mysql") or std.ascii.eqlIgnoreCase(scheme, "mariadb")) return .mysql;
    if (std.ascii.eqlIgnoreCase(scheme, "sqlite")) return .sqlite;
    if (std.ascii.eqlIgnoreCase(scheme, "mongodb") or std.ascii.eqlIgnoreCase(scheme, "mongodb+srv")) return .mongodb;
    return null;
}

pub fn run(gpa: Allocator, io: std.Io, root: anyerror![]const u8, request: Request, out: *Writer, err_out: *Writer) !u8 {
    const repo_root = root catch |err| {
        if (request == .list or request == .add or request == .remove or request == .allow or request == .limit or request == .protect) {
            try err_out.print("error: {t}: emetgate db keeps its settings in the repository, so run it inside one\n", .{err});
            return 1;
        }
        return runGlobal(gpa, io, request, out, err_out);
    };
    var loaded = config.load(gpa, io, repo_root) catch |err| switch (err) {
        error.InvalidDbConfig => {
            try err_out.print("error: InvalidDbConfig: {s} or the global rules file does not parse; fix or delete it\n", .{config.repo_path});
            return 1;
        },
        else => return err,
    };
    defer loaded.deinit();
    const arena = loaded.arena.allocator();
    var list: std.ArrayList(config.Database) = .empty;
    try list.appendSlice(arena, loaded.databases);
    switch (request) {
        .list => |listing| return list_(gpa, io, &loaded, repo_root, listing.json, out),
        .add => |added| {
            if (loaded.find(added.name) != null) {
                try err_out.print("error: DatabaseExists: {s} is already configured; emetgate db remove {s} first\n", .{ added.name, added.name });
                return 1;
            }
            const db = (try describeTarget(gpa, io, arena, repo_root, added.name, added.target, err_out)) orelse return 1;
            try list.append(arena, db);
            try config.save(gpa, io, repo_root, list.items);
            try out.print("added {s}: {s} {s}\n", .{ db.name, @tagName(db.kind), db.path orelse db.display orelse "" });
            if (!db.kind.supported()) try out.print("note: this version does not serve {s} yet; {s} is kept for a later version, its connection string sealed with DPAPI under {s}\n", .{ @tagName(db.kind), db.name, "%LOCALAPPDATA%\\emetgate\\db\\credentials" });
            if (db.kind == .postgres) try out.print("the connection string is sealed with DPAPI under %LOCALAPPDATA%\\emetgate\\db\\credentials; connect with a role that has only SELECT, and use sslmode=verify-full off this machine\nnext: emetgate db hide/mask/block {s} ... for private data, then emetgate doctor checks the connection and the role\n", .{db.name});
            try out.writeAll("the model reads it with emetgate_db from its next session on; it writes only after you type /db write in a lockdown session\n");
            if (db.kind == .mongodb) try out.print("next: emetgate db hide/mask/block {s} collection.field ... for private fields; give it a MongoDB user with only the read role (readWrite only if you will grant /db write)\n", .{db.name});
            if (db.kind == .sqlite) try out.print("next: emetgate db hide/mask/block {s} ... for private data, and emetgate db protect {s} so low-integrity commands cannot read the file itself\n", .{ db.name, db.name });
            return 0;
        },
        .remove => |name| {
            const index = indexOf(list.items, name) orelse return missing(err_out, name);
            const gone = list.orderedRemove(index);
            try config.save(gpa, io, repo_root, list.items);
            if (gone.credential) |cred| credentials.remove(gpa, io, cred) catch {};
            try out.print("removed {s}\n", .{gone.name});
            return 0;
        },
        .protect => |name| {
            const db = findIn(list.items, name) orelse return missing(err_out, name);
            if (db.kind != .sqlite) {
                try err_out.print("error: EngineNotSupported: {s} is not a file; protect labels SQLite files only\n", .{db.name});
                return 1;
            }
            const path = try loaded.location(db, repo_root);
            var labeled: usize = 0;
            for ([_][]const u8{ "", "-wal", "-shm", "-journal" }) |suffix| {
                const file = try std.fmt.allocPrint(arena, "{s}{s}", .{ path, suffix });
                std.Io.Dir.cwd().access(io, file, .{}) catch continue;
                credentials.labelNoLowRead(gpa, file) catch |err| {
                    try err_out.print("error: {t}: {s} could not be labeled\n", .{ err, file });
                    return 1;
                };
                labeled += 1;
            }
            try out.print("{s}: {d} file{s} labeled: low-integrity commands (emetgate_run) can no longer read them; your own programs read and write them as before. A program that deletes and recreates the file drops the label; emetgate doctor says when.\n", .{ db.name, labeled, if (labeled == 1) "" else "s" });
            return 0;
        },
        .allow => |allowed| {
            const db = findIn(list.items, allowed.name) orelse return missing(err_out, allowed.name);
            db.rules.allowed_tables = try appendUnique(arena, db.rules.allowed_tables, allowed.table);
            try config.save(gpa, io, repo_root, list.items);
            try out.print("{s}: only allowed tables are read now: {f}\n", .{ db.name, joined(db.rules.allowed_tables) });
            return 0;
        },
        .limit => |set| {
            const db = findIn(list.items, set.name) orelse return missing(err_out, set.name);
            try db.limits.set(set.field, set.value);
            try config.save(gpa, io, repo_root, list.items);
            try out.print("{s}: {t} = {d}\n", .{ db.name, set.field, set.value });
            return 0;
        },
        .hide, .mask, .block, .unset => {
            const scope: Scope = switch (request) {
                .hide => |r| r.scope,
                .mask => |r| r.scope,
                .block => |r| r.scope,
                .unset => |r| r.scope,
                else => unreachable,
            };
            switch (scope) {
                .global => return runGlobal(gpa, io, request, out, err_out),
                .db => |name| {
                    const db = findIn(list.items, name) orelse return missing(err_out, name);
                    const said = try applyRule(arena, &db.rules, request);
                    if (said == null) {
                        try err_out.print("error: EntryNotFound: {s} has no hide, mask, block or allow entry {s}\n", .{ db.name, request.unset.entry });
                        return 1;
                    }
                    try config.save(gpa, io, repo_root, list.items);
                    try out.print("{s}: {s}\n", .{ db.name, said.? });
                    return 0;
                },
            }
        },
    }
}

fn runGlobal(gpa: Allocator, io: std.Io, request: Request, out: *Writer, err_out: *Writer) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = try config.globalFile(gpa);
    defer gpa.free(path);
    var rules: config.Rules = .{};
    if (std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(config.max_config_bytes))) |bytes| {
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch {
            try err_out.print("error: InvalidDbConfig: {s} does not parse; fix or delete it\n", .{path});
            return 1;
        };
        rules = config.parseRules(arena, value) catch {
            try err_out.print("error: InvalidDbConfig: {s} does not parse; fix or delete it\n", .{path});
            return 1;
        };
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    const said = (try applyRule(arena, &rules, request)) orelse {
        try err_out.print("error: EntryNotFound: the global db rules have no entry {s}\n", .{request.unset.entry});
        return 1;
    };
    if (rules.allowed_tables.len != 0) rules.allowed_tables = &.{};
    try config.saveGlobal(gpa, io, rules);
    try out.print("every database in every repository: {s}\n", .{said});
    return 0;
}

fn applyRule(arena: Allocator, rules: *config.Rules, request: Request) !?[]const u8 {
    switch (request) {
        .hide => |r| {
            rules.hidden = try appendUnique(arena, rules.hidden, r.column);
            return try std.fmt.allocPrint(arena, "{s} is hidden: the model reads it as NULL in every query, and a write may not use it", .{r.column});
        },
        .mask => |r| {
            var kept: std.ArrayList(config.MaskEntry) = .empty;
            for (rules.masked) |entry| {
                if (!std.ascii.eqlIgnoreCase(entry.column, r.column)) try kept.append(arena, entry);
            }
            try kept.append(arena, .{ .column = r.column, .mode = r.mode, .keep = r.keep });
            rules.masked = kept.items;
            return try std.fmt.allocPrint(arena, "{s} is masked ({t}): it may only be selected directly, and comes back masked", .{ r.column, r.mode });
        },
        .block => |r| {
            rules.blocked_tables = try appendUnique(arena, rules.blocked_tables, r.table);
            return try std.fmt.allocPrint(arena, "table {s} is blocked: no query, view or write may touch it", .{r.table});
        },
        .unset => |r| {
            var found = false;
            rules.hidden = try without(arena, rules.hidden, r.entry, &found);
            rules.blocked_tables = try without(arena, rules.blocked_tables, r.entry, &found);
            rules.allowed_tables = try without(arena, rules.allowed_tables, r.entry, &found);
            var kept: std.ArrayList(config.MaskEntry) = .empty;
            for (rules.masked) |entry| {
                if (std.ascii.eqlIgnoreCase(entry.column, r.entry)) {
                    found = true;
                } else try kept.append(arena, entry);
            }
            rules.masked = kept.items;
            if (!found) return null;
            return try std.fmt.allocPrint(arena, "{s} is no longer hidden, masked, blocked or allowed", .{r.entry});
        },
        else => unreachable,
    }
}

fn appendUnique(arena: Allocator, list: []const []const u8, item: []const u8) ![]const []const u8 {
    for (list) |known| {
        if (std.ascii.eqlIgnoreCase(known, item)) return list;
    }
    const out = try arena.alloc([]const u8, list.len + 1);
    @memcpy(out[0..list.len], list);
    out[list.len] = try arena.dupe(u8, item);
    return out;
}

fn without(arena: Allocator, list: []const []const u8, item: []const u8, found: *bool) ![]const []const u8 {
    var kept: std.ArrayList([]const u8) = .empty;
    for (list) |known| {
        if (std.ascii.eqlIgnoreCase(known, item)) {
            found.* = true;
        } else try kept.append(arena, known);
    }
    return kept.items;
}

fn indexOf(list: []const config.Database, name: []const u8) ?usize {
    for (list, 0..) |db, i| {
        if (std.ascii.eqlIgnoreCase(db.name, name)) return i;
    }
    return null;
}

fn findIn(list: []config.Database, name: []const u8) ?*config.Database {
    const i = indexOf(list, name) orelse return null;
    return &list[i];
}

fn missing(err_out: *Writer, name: []const u8) !u8 {
    try err_out.print("error: UnknownDatabase: no database is named {s}; emetgate db list shows them\n", .{name});
    return 1;
}

const Joined = struct {
    items: []const []const u8,

    pub fn format(self: Joined, w: *Writer) Writer.Error!void {
        for (self.items, 0..) |item, i| {
            if (i != 0) try w.writeAll(", ");
            try w.writeAll(item);
        }
    }
};

fn joined(items: []const []const u8) Joined {
    return .{ .items = items };
}

fn describeTarget(gpa: Allocator, io: std.Io, arena: Allocator, root: []const u8, name: []const u8, target: []const u8, err_out: *Writer) !?config.Database {
    if (kindOfUrl(target)) |kind| {
        if (kind == .sqlite) return describeTarget(gpa, io, arena, root, name, target["sqlite://".len..], err_out);
        var sealed: []const u8 = target;
        if (kind == .postgres) {
            const parsed = postgres.parseUrl(arena, target) catch {
                try err_out.writeAll("error: InvalidUrl: the connection string is not a postgres URL emetgate reads; use postgres://user[:password]@host[:port]/db[?sslmode=disable|prefer|require|verify-full][&sslrootcert=C:\\path\\ca.pem]\n");
                return null;
            };
            if (parsed.password == null) {
                if (env_password) |password| sealed = try postgres.withPassword(arena, target, password);
            }
        }
        if (kind == .mongodb) {
            var why: mongo.OpenProblem = .{};
            const conn = mongo.open(gpa, target, .{ .io = io, .mode = .read, .access = .{}, .limits = .{} }, &why) catch |err| {
                if (err == error.OutOfMemory) return err;
                try err_out.print("error: DatabaseUnavailable: {s}; nothing was added\n", .{why.text()});
                return null;
            };
            conn.close();
        }
        credentials.store(gpa, io, name, sealed) catch |err| {
            try err_out.print("error: {t}: the connection string could not be sealed with DPAPI\n", .{err});
            return null;
        };
        const shown = try credentials.redact(gpa, target);
        defer gpa.free(shown);
        return .{ .name = try arena.dupe(u8, name), .kind = kind, .credential = try arena.dupe(u8, name), .display = try arena.dupe(u8, shown) };
    }
    if (std.mem.indexOf(u8, target, "://") != null) {
        try err_out.print("error: UnknownEngine: {s} names an engine emetgate does not know; use a file path, mongodb://, postgres://, mysql:// or sqlite://\n", .{target});
        return null;
    }
    const abs = std.Io.Dir.cwd().realPathFileAlloc(io, target, gpa) catch |err| {
        try err_out.print("error: {t}: {s} cannot be opened\n", .{ err, target });
        return null;
    };
    defer gpa.free(abs);
    var why: sqlite.OpenProblem = .{};
    const conn = sqlite.open(gpa, abs, .{ .io = io, .mode = .read, .access = .{}, .limits = .{} }, &why) catch |err| {
        if (err == error.OutOfMemory) return err;
        try err_out.print("error: DatabaseUnavailable: {s}\n", .{why.text()});
        return null;
    };
    conn.close();
    const trimmed = std.mem.trimEnd(u8, root, "\\/");
    const inside = abs.len > trimmed.len + 1 and std.ascii.eqlIgnoreCase(abs[0..trimmed.len], trimmed) and (abs[trimmed.len] == '\\' or abs[trimmed.len] == '/');
    const stored = if (inside) try std.mem.replaceOwned(u8, arena, abs[trimmed.len + 1 ..], "\\", "/") else try arena.dupe(u8, abs);
    return .{ .name = try arena.dupe(u8, name), .kind = .sqlite, .path = stored };
}

fn list_(gpa: Allocator, io: std.Io, loaded: *config.Config, root: []const u8, json: bool, out: *Writer) !u8 {
    if (json) {
        const bytes = try config.render(gpa, loaded.databases);
        defer gpa.free(bytes);
        try out.writeAll(bytes);
        return 0;
    }
    if (loaded.databases.len == 0) {
        try out.writeAll("no database is configured; add one with: emetgate db add <name> <file.db>\n");
    }
    for (loaded.databases) |*db| {
        try out.print("{s}  {s}  {s}\n", .{ db.name, @tagName(db.kind), db.path orelse db.display orelse "" });
        if (db.credential) |cred| try out.print("  credential  {s}\n", .{if (credentials.exists(gpa, io, cred)) "sealed with DPAPI" else "MISSING: emetgate db remove and add it again"});
        try writeRulesLines(out, db.rules);
        const defaults: engine.Limits = .{};
        try out.print("  limits      max-rows {d}, max-cell-chars {d}, max-result-bytes {d}, timeout-ms {d}, rate-per-minute {d}{s}\n", .{ db.limits.max_rows, db.limits.max_cell_chars, db.limits.max_result_bytes, db.limits.timeout_ms, db.limits.rate_per_minute, if (std.meta.eql(db.limits, defaults)) " (defaults)" else "" });
        if (db.kind == .sqlite) {
            const path = try loaded.location(db, root);
            std.Io.Dir.cwd().access(io, path, .{}) catch try out.print("  problem     {s} does not exist\n", .{path});
        }
    }
    if (!loaded.global.empty()) {
        try out.writeAll("global rules (every database in every repository)\n");
        try writeRulesLines(out, loaded.global);
    }
    return 0;
}

fn writeRulesLines(out: *Writer, rules: config.Rules) !void {
    if (rules.hidden.len != 0) try out.print("  hidden      {f}\n", .{joined(rules.hidden)});
    if (rules.masked.len != 0) {
        try out.writeAll("  masked      ");
        for (rules.masked, 0..) |entry, i| {
            if (i != 0) try out.writeAll(", ");
            try out.print("{s} ({t})", .{ entry.column, entry.mode });
        }
        try out.writeByte('\n');
    }
    if (rules.blocked_tables.len != 0) try out.print("  blocked     {f}\n", .{joined(rules.blocked_tables)});
    if (rules.allowed_tables.len != 0) try out.print("  allowed     {f} (no other table is read)\n", .{joined(rules.allowed_tables)});
}

pub fn slashArguments(prompt: []const u8) ?[]const u8 {
    var rest = std.mem.trimStart(u8, prompt, " \t\r\n");
    if (std.mem.startsWith(u8, rest, "\xef\xbb\xbf")) rest = std.mem.trimStart(u8, rest[3..], " \t\r\n");
    if (!std.mem.startsWith(u8, rest, slash)) return null;
    const after = rest[slash.len..];
    if (after.len != 0 and std.mem.indexOfScalar(u8, " \t\r\n", after[0]) == null) return null;
    return after;
}

pub fn respondSlash(gpa: Allocator, io: std.Io, env: *const Map, root: anyerror![]const u8, text: []const u8, out: *Writer) !void {
    var reason: Writer.Allocating = .init(gpa);
    defer reason.deinit();
    answerSlash(gpa, io, env, root, text, &reason.writer) catch |err| switch (err) {
        error.OutOfMemory, error.WriteFailed => return err,
        else => try reason.writer.print("error: {t}\n", .{err}),
    };
    const said = std.mem.trimEnd(u8, reason.written(), " \t\r\n");
    var js: std.json.Stringify = .{ .writer = out, .options = .{ .escape_unicode = true } };
    try js.beginObject();
    try js.objectField("decision");
    try js.write("block");
    try js.objectField("reason");
    try js.write(if (said.len == 0) "ok" else said);
    try js.endObject();
    try out.writeByte('\n');
}

fn answerSlash(gpa: Allocator, io: std.Io, env: *const Map, root_result: anyerror![]const u8, text: []const u8, reason: *Writer) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const words = prompt_words.split(arena, text) catch return reason.writeAll(slash_usage);
    const verb: []const u8 = if (words.len == 0) "status" else words[0];
    const off = std.mem.eql(u8, verb, "read") or std.mem.eql(u8, verb, "off");
    const status = std.mem.eql(u8, verb, "status") or std.mem.eql(u8, verb, "list");
    const write = std.mem.eql(u8, verb, "write");
    if (!off and !status and !write) return reason.writeAll(slash_usage);
    if ((off or status) and words.len > 1) return reason.writeAll(slash_usage);
    var name: ?[]const u8 = null;
    var destructive = false;
    if (write) for (words[1..]) |word| {
        if (std.mem.eql(u8, word, destructive_flag) and !destructive) {
            destructive = true;
        } else if (name == null and config.validName(word)) {
            name = word;
        } else return reason.writeAll(slash_usage);
    };
    const file = (try grant.path(arena, env)) orelse return reason.writeAll("write mode needs a session started by emetgate lockdown, which gives this hook a place outside the repository to keep the grant\n");
    const now = grant.nowSeconds(io);
    if (off) {
        grant.revoke(io, file);
        return reason.writeAll("write mode is off: emetgate_db_write refuses every statement\n");
    }
    const root = root_result catch |err| return reason.print("error: {t}: /db works inside a repository\n", .{err});
    var loaded = try config.load(gpa, io, root);
    defer loaded.deinit();
    if (status) {
        if (loaded.databases.len == 0) try reason.writeAll("no database is configured; add one in a terminal with: emetgate db add <name> <file.db>\n");
        for (loaded.databases) |db| try reason.print("{s}  {s}  {s}\n", .{ db.name, @tagName(db.kind), db.path orelse db.display orelse "" });
        const state = grant.current(arena, file, now);
        if (state) |g| {
            const which = g.db orelse "every configured database";
            const when = if (g.state == .armed) "armed for your next prompt" else "on for this turn";
            try reason.print("write mode: {s}, {s}{s}\n", .{ when, which, if (g.destructive) ", destructive statements included" else "" });
        } else try reason.writeAll("write mode: off\n");
        return;
    }
    if (loaded.databases.len == 0) return reason.writeAll("no database is configured, so there is nothing to write to; add one in a terminal with: emetgate db add <name> <file.db>\n");
    if (name) |given| {
        const db = loaded.find(given) orelse {
            try reason.print("no database is named {s}; configured:", .{given});
            for (loaded.databases) |db| try reason.print(" {s}", .{db.name});
            return reason.writeByte('\n');
        };
        name = db.name;
    } else if (loaded.databases.len == 1) name = loaded.databases[0].name;
    try grant.arm(gpa, io, file, name, destructive, now);
    const which = name orelse "every configured database";
    try reason.print("write mode armed for {s}: during your next prompt's turn the model may run INSERT, UPDATE, DELETE and DDL with emetgate_db_write, one statement per call, each logged with its row count. ", .{which});
    if (destructive) {
        try reason.writeAll("Destructive statements (DROP, emptying a table, changing every row) are allowed too. ");
    } else {
        try reason.writeAll("A statement that drops a table, empties it, changes every row or drops a column is still refused; /db write --destructive allows it. ");
    }
    try reason.writeAll("Write mode ends when that turn ends; /db read ends it now.\n");
}

pub fn advance(gpa: Allocator, io: std.Io, env: *const Map) void {
    const file = (grant.path(gpa, env) catch return) orelse return;
    defer gpa.free(file);
    grant.advance(gpa, io, file, grant.nowSeconds(io)) catch {};
}

const testing = std.testing;

fn argv(comptime words: []const [:0]const u8) []const [:0]const u8 {
    return words;
}

test "db command: the CLI verbs parse their arguments and refuse the rest" {
    try testing.expectEqualStrings("main", parse(argv(&.{ "add", "main", "data/app.db" })).?.add.name);
    try testing.expect(parse(argv(&.{ "add", "bad name", "x" })) == null);
    try testing.expect(parse(argv(&.{"list"})).?.list.json == false);
    try testing.expect(parse(argv(&.{ "list", "--json" })).?.list.json);
    try testing.expectEqual(Scope.global, parse(argv(&.{ "hide", "--global", "users.password_hash" })).?.hide.scope);
    try testing.expect(parse(argv(&.{ "hide", "main", "password_hash" })) == null);
    const mask = parse(argv(&.{ "mask", "main", "users.email", "--mode", "email", "--keep", "2" })).?.mask;
    try testing.expectEqual(access.MaskMode.email, mask.mode);
    try testing.expectEqual(@as(u8, 2), mask.keep);
    try testing.expect(parse(argv(&.{ "mask", "main", "users.email", "--mode", "rot13" })) == null);
    try testing.expect(parse(argv(&.{ "limit", "main", "max-rows", "500" })) != null);
    try testing.expect(parse(argv(&.{ "limit", "main", "max-rows", "0" })) == null);
    try testing.expect(parse(argv(&.{ "limit", "main", "rows", "5" })) == null);
    try testing.expect(parse(argv(&.{ "allow", "--global", "orders" })) == null);
    try testing.expect(parse(argv(&.{"drop"})) == null);
}

test "db command: only a prompt that starts with /db as a word is a /db prompt" {
    try testing.expectEqualStrings(" write main", slashArguments("  /db write main").?);
    try testing.expectEqualStrings("", slashArguments("/db").?);
    try testing.expect(slashArguments("/dbx write") == null);
    try testing.expect(slashArguments("please /db write") == null);
    try testing.expect(slashArguments("/rule add x") == null);
}
