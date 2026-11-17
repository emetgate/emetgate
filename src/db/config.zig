const std = @import("std");
const builtin = @import("builtin");
const access = @import("access.zig");
const engine = @import("engine.zig");
const json_input = @import("../protocol/json_input.zig");
const shadow = @import("../platform/shadow.zig");
const user_rules = @import("../platform/user_rules.zig");
const cache_lease = @import("../platform/cache_lease.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const file_name = "db.json";
pub const repo_path = shadow.workspace_dir ++ "/" ++ file_name;
pub const global_dir_name = "db";
pub const global_file_name = "rules.json";
pub const max_config_bytes = 1024 * 1024;
pub const max_databases = 32;
pub const max_entries = 256;

pub var global_dir_override: ?[]const u8 = null;

pub const MaskEntry = struct {
    column: []const u8,
    mode: access.MaskMode = .partial,
    keep: u8 = access.default_keep,
};

pub const Rules = struct {
    hidden: []const []const u8 = &.{},
    masked: []const MaskEntry = &.{},
    allowed_tables: []const []const u8 = &.{},
    blocked_tables: []const []const u8 = &.{},

    pub fn empty(self: Rules) bool {
        return self.hidden.len == 0 and self.masked.len == 0 and self.allowed_tables.len == 0 and self.blocked_tables.len == 0;
    }
};

pub const Database = struct {
    name: []const u8,
    kind: engine.Kind,
    path: ?[]const u8 = null,
    credential: ?[]const u8 = null,
    display: ?[]const u8 = null,
    rules: Rules = .{},
    limits: engine.Limits = .{},
};

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    databases: []Database,
    global: Rules,

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }

    pub fn find(self: *const Config, name: []const u8) ?*Database {
        for (self.databases) |*db| {
            if (std.ascii.eqlIgnoreCase(db.name, name)) return db;
        }
        return null;
    }

    pub fn accessFor(self: *Config, db: *const Database) !access.Access {
        const arena = self.arena.allocator();
        var hidden: std.ArrayList(access.Column) = .empty;
        var masked: std.ArrayList(access.Mask) = .empty;
        var blocked: std.ArrayList([]const u8) = .empty;
        for ([_]Rules{ self.global, db.rules }) |rules| {
            for (rules.hidden) |text| try hidden.append(arena, access.Column.parse(text) orelse return error.InvalidDbConfig);
            for (rules.masked) |entry| {
                const col = access.Column.parse(entry.column) orelse return error.InvalidDbConfig;
                try masked.append(arena, .{ .table = col.table, .column = col.column, .mode = entry.mode, .keep = entry.keep });
            }
            try blocked.appendSlice(arena, rules.blocked_tables);
        }
        return .{ .hidden = hidden.items, .masked = masked.items, .allowed_tables = db.rules.allowed_tables, .blocked_tables = blocked.items };
    }

    pub fn location(self: *Config, db: *const Database, root_abs: []const u8) ![]const u8 {
        const given = db.path orelse return error.EngineNotSupported;
        const arena = self.arena.allocator();
        const joined = if (std.fs.path.isAbsolute(given)) try arena.dupe(u8, given) else try std.fmt.allocPrint(arena, "{s}\\{s}", .{ std.mem.trimEnd(u8, root_abs, "\\/"), given });
        std.mem.replaceScalar(u8, joined, '/', '\\');
        return joined;
    }
};

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or !std.ascii.isAlphanumeric(name[0])) return false;
    for (name) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return false;
    }
    return true;
}

pub fn repoFile(gpa: Allocator, root_abs: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}\\{s}\\{s}", .{ std.mem.trimEnd(u8, root_abs, "\\/"), shadow.workspace_dir, file_name });
}

pub fn globalDir(gpa: Allocator) ![]u8 {
    if (global_dir_override) |dir| return gpa.dupe(u8, dir);
    const data = if (builtin.is_test) try cache_lease.testDataDir(gpa) else try user_rules.profileDataDir(gpa);
    defer gpa.free(data);
    return std.fmt.allocPrint(gpa, "{s}\\{s}", .{ std.mem.trimEnd(u8, data, "\\/"), global_dir_name });
}

pub fn globalFile(gpa: Allocator) ![]u8 {
    const dir = try globalDir(gpa);
    defer gpa.free(dir);
    return std.fmt.allocPrint(gpa, "{s}\\{s}", .{ dir, global_file_name });
}

fn readOptional(gpa: Allocator, io: std.Io, path: []const u8) !?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_config_bytes)) catch |err| switch (err) {
        error.FileNotFound => null,
        error.StreamTooLong => error.InvalidDbConfig,
        else => err,
    };
}

pub fn load(gpa: Allocator, io: std.Io, root_abs: []const u8) !Config {
    var config: Config = .{ .arena = .init(gpa), .databases = &.{}, .global = .{} };
    errdefer config.deinit();
    const arena = config.arena.allocator();
    const repo = try repoFile(gpa, root_abs);
    defer gpa.free(repo);
    if (try readOptional(gpa, io, repo)) |bytes| {
        defer gpa.free(bytes);
        config.databases = try parseRepo(arena, bytes);
    }
    const global = try globalFile(gpa);
    defer gpa.free(global);
    if (try readOptional(gpa, io, global)) |bytes| {
        defer gpa.free(bytes);
        const value = json_input.parseLeaky(std.json.Value, arena, bytes, .{}) catch return error.InvalidDbConfig;
        config.global = try parseRules(arena, value);
    }
    return config;
}

pub fn parseRepo(arena: Allocator, bytes: []const u8) ![]Database {
    const value = json_input.parseLeaky(std.json.Value, arena, bytes, .{}) catch return error.InvalidDbConfig;
    if (value != .object) return error.InvalidDbConfig;
    const list = value.object.get("databases") orelse return &.{};
    if (list != .array or list.array.items.len > max_databases) return error.InvalidDbConfig;
    const out = try arena.alloc(Database, list.array.items.len);
    for (list.array.items, out) |item, *db| {
        if (item != .object) return error.InvalidDbConfig;
        const name = stringField(item, "name") orelse return error.InvalidDbConfig;
        if (!validName(name)) return error.InvalidDbConfig;
        const kind = engine.Kind.parse(stringField(item, "engine") orelse "sqlite") orelse return error.InvalidDbConfig;
        db.* = .{
            .name = name,
            .kind = kind,
            .path = stringField(item, "path"),
            .credential = stringField(item, "credential"),
            .display = stringField(item, "display"),
            .rules = try parseRules(arena, item),
            .limits = try parseLimits(item),
        };
        if (kind == .sqlite and db.path == null) return error.InvalidDbConfig;
        if (kind != .sqlite and db.credential == null) return error.InvalidDbConfig;
    }
    for (out, 0..) |db, i| {
        for (out[0..i]) |earlier| {
            if (std.ascii.eqlIgnoreCase(earlier.name, db.name)) return error.InvalidDbConfig;
        }
    }
    return out;
}

fn stringField(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = value.object.get(key) orelse return null;
    return if (field == .string) field.string else null;
}

fn stringList(arena: Allocator, value: std.json.Value, key: []const u8, comptime check: fn ([]const u8) bool) ![]const []const u8 {
    const field = value.object.get(key) orelse return &.{};
    if (field != .array or field.array.items.len > max_entries) return error.InvalidDbConfig;
    const out = try arena.alloc([]const u8, field.array.items.len);
    for (field.array.items, out) |item, *slot| {
        if (item != .string or !check(item.string)) return error.InvalidDbConfig;
        slot.* = item.string;
    }
    return out;
}

fn validColumn(text: []const u8) bool {
    return access.Column.parse(text) != null;
}

pub fn parseRules(arena: Allocator, value: std.json.Value) !Rules {
    if (value != .object) return error.InvalidDbConfig;
    var rules: Rules = .{
        .hidden = try stringList(arena, value, "hidden", validColumn),
        .allowed_tables = try stringList(arena, value, "allowed_tables", access.validName),
        .blocked_tables = try stringList(arena, value, "blocked_tables", access.validName),
    };
    if (value.object.get("masked")) |field| {
        if (field != .array or field.array.items.len > max_entries) return error.InvalidDbConfig;
        const out = try arena.alloc(MaskEntry, field.array.items.len);
        for (field.array.items, out) |item, *slot| {
            if (item == .string) {
                if (!validColumn(item.string)) return error.InvalidDbConfig;
                slot.* = .{ .column = item.string };
                continue;
            }
            if (item != .object) return error.InvalidDbConfig;
            const column = stringField(item, "column") orelse return error.InvalidDbConfig;
            if (!validColumn(column)) return error.InvalidDbConfig;
            const mode = access.MaskMode.parse(stringField(item, "mode") orelse "partial") orelse return error.InvalidDbConfig;
            var keep: u8 = access.default_keep;
            if (item.object.get("keep")) |k| {
                if (k != .integer or k.integer < 0 or k.integer > access.max_keep) return error.InvalidDbConfig;
                keep = @intCast(k.integer);
            }
            slot.* = .{ .column = column, .mode = mode, .keep = keep };
        }
        rules.masked = out;
    }
    return rules;
}

fn parseLimits(value: std.json.Value) !engine.Limits {
    var limits: engine.Limits = .{};
    const field = value.object.get("limits") orelse return limits;
    if (field != .object) return error.InvalidDbConfig;
    var it = field.object.iterator();
    while (it.next()) |entry| {
        const which = engine.Limits.parseField(entry.key_ptr.*) orelse return error.InvalidDbConfig;
        const n = entry.value_ptr.*;
        if (n != .integer or n.integer <= 0 or n.integer > std.math.maxInt(u32)) return error.InvalidDbConfig;
        limits.set(which, @intCast(n.integer)) catch return error.InvalidDbConfig;
    }
    return limits;
}

pub fn writeRules(js: *std.json.Stringify, rules: Rules) !void {
    if (rules.hidden.len != 0) {
        try js.objectField("hidden");
        try js.write(rules.hidden);
    }
    if (rules.masked.len != 0) {
        try js.objectField("masked");
        try js.beginArray();
        for (rules.masked) |entry| {
            try js.beginObject();
            try js.objectField("column");
            try js.write(entry.column);
            try js.objectField("mode");
            try js.write(@tagName(entry.mode));
            if (entry.keep != access.default_keep) {
                try js.objectField("keep");
                try js.write(entry.keep);
            }
            try js.endObject();
        }
        try js.endArray();
    }
    if (rules.allowed_tables.len != 0) {
        try js.objectField("allowed_tables");
        try js.write(rules.allowed_tables);
    }
    if (rules.blocked_tables.len != 0) {
        try js.objectField("blocked_tables");
        try js.write(rules.blocked_tables);
    }
}

pub fn writeLimits(js: *std.json.Stringify, limits: engine.Limits, all: bool) !void {
    const defaults: engine.Limits = .{};
    inline for (std.meta.fields(engine.Limits)) |field| {
        const value = @field(limits, field.name);
        if (all or value != @field(defaults, field.name)) {
            try js.objectField(field.name);
            try js.write(value);
        }
    }
}

pub fn render(gpa: Allocator, databases: []const Database) ![]u8 {
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    try js.beginObject();
    try js.objectField("databases");
    try js.beginArray();
    for (databases) |db| {
        try js.beginObject();
        try js.objectField("name");
        try js.write(db.name);
        try js.objectField("engine");
        try js.write(@tagName(db.kind));
        if (db.path) |path| {
            try js.objectField("path");
            try js.write(path);
        }
        if (db.credential) |credential| {
            try js.objectField("credential");
            try js.write(credential);
        }
        if (db.display) |display| {
            try js.objectField("display");
            try js.write(display);
        }
        try writeRules(&js, db.rules);
        const defaults: engine.Limits = .{};
        if (!std.meta.eql(db.limits, defaults)) {
            try js.objectField("limits");
            try js.beginObject();
            try writeLimits(&js, db.limits, false);
            try js.endObject();
        }
        try js.endObject();
    }
    try js.endArray();
    try js.endObject();
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

pub fn renderRules(gpa: Allocator, rules: Rules) ![]u8 {
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    try js.beginObject();
    try writeRules(&js, rules);
    try js.endObject();
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

pub fn place(gpa: Allocator, io: std.Io, abs: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(abs)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
    if (builtin.os.tag == .windows and try shadow.isReparsePoint(abs)) return error.DbConfigIsLink;
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    const staged = try std.fmt.allocPrint(gpa, "{s}.{x}.tmp", .{ abs, &nonce });
    defer gpa.free(staged);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = staged, .data = data });
    errdefer std.Io.Dir.cwd().deleteFile(io, staged) catch {};
    try std.Io.Dir.renameAbsolute(staged, abs, io);
}

pub fn save(gpa: Allocator, io: std.Io, root_abs: []const u8, databases: []const Database) !void {
    const bytes = try render(gpa, databases);
    defer gpa.free(bytes);
    const path = try repoFile(gpa, root_abs);
    defer gpa.free(path);
    try place(gpa, io, path, bytes);
}

pub fn saveGlobal(gpa: Allocator, io: std.Io, rules: Rules) !void {
    const bytes = try renderRules(gpa, rules);
    defer gpa.free(bytes);
    const path = try globalFile(gpa);
    defer gpa.free(path);
    try place(gpa, io, path, bytes);
}

const testing = std.testing;

test "db config: a repository file round-trips through render and parse, with defaults left out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dbs = [_]Database{
        .{
            .name = "main",
            .kind = .sqlite,
            .path = "data/app.db",
            .rules = .{ .hidden = &.{"users.password_hash"}, .masked = &.{.{ .column = "users.email", .mode = .email }}, .blocked_tables = &.{"secret"} },
            .limits = .{ .max_rows = 50 },
        },
        .{ .name = "prod", .kind = .postgres, .credential = "prod", .display = "postgres://app@db/app" },
    };
    const text = try render(testing.allocator, &dbs);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "\"max_rows\": 50") != null);
    try testing.expect(std.mem.indexOf(u8, text, "timeout_ms") == null);
    const back = try parseRepo(arena, text);
    try testing.expectEqual(@as(usize, 2), back.len);
    try testing.expectEqualStrings("data/app.db", back[0].path.?);
    try testing.expectEqual(access.MaskMode.email, back[0].rules.masked[0].mode);
    try testing.expectEqual(@as(u32, 50), back[0].limits.max_rows);
    try testing.expectEqual(engine.Kind.postgres, back[1].kind);
}

test "db config: a bad name, a duplicate, an unknown engine or limit, and a quoted column are refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{
        "{\"databases\":[{\"name\":\"a b\",\"path\":\"x\"}]}",
        "{\"databases\":[{\"name\":\"a\",\"path\":\"x\"},{\"name\":\"A\",\"path\":\"y\"}]}",
        "{\"databases\":[{\"name\":\"a\",\"engine\":\"oracle\",\"path\":\"x\"}]}",
        "{\"databases\":[{\"name\":\"a\",\"path\":\"x\",\"limits\":{\"rows\":5}}]}",
        "{\"databases\":[{\"name\":\"a\",\"path\":\"x\",\"limits\":{\"max_rows\":0}}]}",
        "{\"databases\":[{\"name\":\"a\",\"path\":\"x\",\"hidden\":[\"\\\"users\\\".x\"]}]}",
        "{\"databases\":[{\"name\":\"a\",\"engine\":\"postgres\"}]}",
        "{\"databases\":[{\"name\":\"a\"}]}",
        "not json",
    }) |bytes| try testing.expectError(error.InvalidDbConfig, parseRepo(arena, bytes));
    try testing.expectEqual(@as(usize, 0), (try parseRepo(arena, "{}")).len);
}
