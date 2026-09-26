const std = @import("std");
const jcs = @import("jcs.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Array = std.json.Array;

pub const statement_type = "https://in-toto.io/Statement/v1";
pub const predicate_type = "https://emetgate.dev/receipt/v1";
pub const file_digest = "blake3-128";

pub const Hash = [16]u8;
pub const Sha256 = [32]u8;

pub const Class = enum { symmetry, spending };
pub const Operation = enum { @"try", try_batch, rename, move, move_file };
pub const CheckKind = enum { typecheck, @"test" };

pub const FileEntry = struct {
    path: []const u8,
    before: ?Hash,
    after: ?Hash,
};

pub const SymbolEntry = struct {
    path: []const u8,
    ref: []const u8,
    before: ?Hash,
    after: ?Hash,
};

pub const Subject = struct {
    path: []const u8,
    blake3: Hash,
    sha256: Sha256,
};

pub const Check = struct {
    kind: CheckKind,
    command: []const u8,
    command_digest: Hash,
    exit_code: i64,
    duration_ms: ?i64,
};

pub const Rule = struct {
    id: []const u8,
    digest: Hash,
};

pub const Sandbox = struct {
    integrity: []const u8,
    job_memory_bytes: i64,
    active_process_limit: i64,
    timeout_ms: i64,
    output_limit_bytes: i64,
};

pub const Receipt = struct {
    batch: []const u8,
    operation: Operation,
    class: Class,
    evidence: []const u8,
    resolver: ?[]const u8,
    subjects: []const Subject,
    files: []const FileEntry,
    symbols: []const SymbolEntry,
    checks: []const Check,
    rules: []const Rule,
    sandbox: Sandbox,
    version: []const u8,
};

pub const Invalid = error{InvalidReceipt};

pub fn blake3(bytes: []const u8) Hash {
    var out: Hash = undefined;
    std.crypto.hash.Blake3.hash(bytes, &out, .{});
    return out;
}

pub fn sha256(bytes: []const u8) Sha256 {
    var out: Sha256 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return out;
}

fn hex(arena: Allocator, bytes: []const u8) ![]u8 {
    const out = try arena.alloc(u8, bytes.len * 2);
    const digits = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[2 * i] = digits[b >> 4];
        out[2 * i + 1] = digits[b & 15];
    }
    return out;
}

fn string(text: []const u8) Value {
    return .{ .string = text };
}

fn optionalHash(arena: Allocator, hash: ?Hash) !Value {
    const h = hash orelse return .null;
    return string(try hex(arena, &h));
}

fn object(arena: Allocator, fields: anytype) !Value {
    var map: ObjectMap = .empty;
    inline for (std.meta.fields(@TypeOf(fields))) |member| {
        try map.put(arena, member.name, @field(fields, member.name));
    }
    return .{ .object = map };
}

pub fn toValue(arena: Allocator, r: Receipt) !Value {
    var subjects: Array = .init(arena);
    for (r.subjects) |s| {
        const digest = try object(arena, .{ .@"blake3-128" = string(try hex(arena, &s.blake3)), .sha256 = string(try hex(arena, &s.sha256)) });
        try subjects.append(try object(arena, .{ .name = string(s.path), .digest = digest }));
    }
    var files: Array = .init(arena);
    for (r.files) |f| try files.append(try object(arena, .{ .path = string(f.path), .before = try optionalHash(arena, f.before), .after = try optionalHash(arena, f.after) }));
    var symbols: Array = .init(arena);
    for (r.symbols) |s| try symbols.append(try object(arena, .{ .path = string(s.path), .ref = string(s.ref), .before = try optionalHash(arena, s.before), .after = try optionalHash(arena, s.after) }));
    var checks: Array = .init(arena);
    for (r.checks) |c| try checks.append(try object(arena, .{
        .kind = string(@tagName(c.kind)),
        .command = string(c.command),
        .command_digest = string(try hex(arena, &c.command_digest)),
        .exit_code = Value{ .integer = c.exit_code },
        .duration_ms = if (c.duration_ms) |d| Value{ .integer = d } else Value.null,
    }));
    var rules: Array = .init(arena);
    for (r.rules) |rule| try rules.append(try object(arena, .{ .id = string(rule.id), .digest = string(try hex(arena, &rule.digest)) }));
    const sandbox = try object(arena, .{
        .integrity = string(r.sandbox.integrity),
        .job_memory_bytes = Value{ .integer = r.sandbox.job_memory_bytes },
        .active_process_limit = Value{ .integer = r.sandbox.active_process_limit },
        .timeout_ms = Value{ .integer = r.sandbox.timeout_ms },
        .output_limit_bytes = Value{ .integer = r.sandbox.output_limit_bytes },
    });
    const predicate = try object(arena, .{
        .batch = string(r.batch),
        .operation = string(@tagName(r.operation)),
        .class = string(@tagName(r.class)),
        .evidence = string(r.evidence),
        .resolver = if (r.resolver) |res| string(res) else Value.null,
        .files = Value{ .array = files },
        .symbols = Value{ .array = symbols },
        .checks = Value{ .array = checks },
        .rules = Value{ .array = rules },
        .sandbox = sandbox,
        .emetgate = try object(arena, .{ .version = string(r.version) }),
    });
    return object(arena, .{
        ._type = string(statement_type),
        .subject = Value{ .array = subjects },
        .predicateType = string(predicate_type),
        .predicate = predicate,
    });
}

fn field(map: ObjectMap, name: []const u8) Invalid!Value {
    return map.get(name) orelse error.InvalidReceipt;
}

fn asObject(value: Value) Invalid!ObjectMap {
    return if (value == .object) value.object else error.InvalidReceipt;
}

fn asArray(value: Value) Invalid![]const Value {
    return if (value == .array) value.array.items else error.InvalidReceipt;
}

fn asString(value: Value) Invalid![]const u8 {
    return if (value == .string) value.string else error.InvalidReceipt;
}

fn asInteger(value: Value) Invalid!i64 {
    return if (value == .integer) value.integer else error.InvalidReceipt;
}

fn parseHex(comptime n: usize, text: []const u8) Invalid![n]u8 {
    if (text.len != n * 2) return error.InvalidReceipt;
    for (text) |c| if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'))) return error.InvalidReceipt;
    var out: [n]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch return error.InvalidReceipt;
    return out;
}

fn optionalHex(value: Value) Invalid!?Hash {
    if (value == .null) return null;
    return try parseHex(16, try asString(value));
}

fn expectKeys(map: ObjectMap, keys: []const []const u8) Invalid!void {
    if (map.count() != keys.len) return error.InvalidReceipt;
    for (keys) |k| if (map.get(k) == null) return error.InvalidReceipt;
}

fn validPath(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    if (path.len > 1 and path[1] == ':') return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

pub fn fromValue(arena: Allocator, value: Value) (Invalid || Allocator.Error)!Receipt {
    const top = try asObject(value);
    try expectKeys(top, &.{ "_type", "subject", "predicateType", "predicate" });
    if (!std.mem.eql(u8, try asString(try field(top, "_type")), statement_type)) return error.InvalidReceipt;
    if (!std.mem.eql(u8, try asString(try field(top, "predicateType")), predicate_type)) return error.InvalidReceipt;
    const p = try asObject(try field(top, "predicate"));
    try expectKeys(p, &.{ "batch", "operation", "class", "evidence", "resolver", "files", "symbols", "checks", "rules", "sandbox", "emetgate" });

    var subjects: std.ArrayList(Subject) = .empty;
    for (try asArray(try field(top, "subject"))) |item| {
        const s = try asObject(item);
        try expectKeys(s, &.{ "name", "digest" });
        const d = try asObject(try field(s, "digest"));
        try expectKeys(d, &.{ file_digest, "sha256" });
        const path = try asString(try field(s, "name"));
        if (!validPath(path)) return error.InvalidReceipt;
        try subjects.append(arena, .{ .path = path, .blake3 = try parseHex(16, try asString(try field(d, file_digest))), .sha256 = try parseHex(32, try asString(try field(d, "sha256"))) });
    }
    var files: std.ArrayList(FileEntry) = .empty;
    for (try asArray(try field(p, "files"))) |item| {
        const f = try asObject(item);
        try expectKeys(f, &.{ "path", "before", "after" });
        const path = try asString(try field(f, "path"));
        if (!validPath(path)) return error.InvalidReceipt;
        const entry: FileEntry = .{ .path = path, .before = try optionalHex(try field(f, "before")), .after = try optionalHex(try field(f, "after")) };
        if (entry.before == null and entry.after == null) return error.InvalidReceipt;
        for (files.items) |other| if (std.mem.eql(u8, other.path, path)) return error.InvalidReceipt;
        try files.append(arena, entry);
    }
    if (files.items.len == 0) return error.InvalidReceipt;
    var symbols: std.ArrayList(SymbolEntry) = .empty;
    for (try asArray(try field(p, "symbols"))) |item| {
        const s = try asObject(item);
        try expectKeys(s, &.{ "path", "ref", "before", "after" });
        const path = try asString(try field(s, "path"));
        var listed = false;
        for (files.items) |f| if (std.mem.eql(u8, f.path, path)) {
            listed = true;
        };
        if (!listed) return error.InvalidReceipt;
        try symbols.append(arena, .{ .path = path, .ref = try asString(try field(s, "ref")), .before = try optionalHex(try field(s, "before")), .after = try optionalHex(try field(s, "after")) });
    }
    var checks: std.ArrayList(Check) = .empty;
    for (try asArray(try field(p, "checks"))) |item| {
        const c = try asObject(item);
        try expectKeys(c, &.{ "kind", "command", "command_digest", "exit_code", "duration_ms" });
        const kind = std.meta.stringToEnum(CheckKind, try asString(try field(c, "kind"))) orelse return error.InvalidReceipt;
        const duration = try field(c, "duration_ms");
        try checks.append(arena, .{
            .kind = kind,
            .command = try asString(try field(c, "command")),
            .command_digest = try parseHex(16, try asString(try field(c, "command_digest"))),
            .exit_code = try asInteger(try field(c, "exit_code")),
            .duration_ms = if (duration == .null) null else try asInteger(duration),
        });
    }
    var rules: std.ArrayList(Rule) = .empty;
    for (try asArray(try field(p, "rules"))) |item| {
        const r = try asObject(item);
        try expectKeys(r, &.{ "id", "digest" });
        try rules.append(arena, .{ .id = try asString(try field(r, "id")), .digest = try parseHex(16, try asString(try field(r, "digest"))) });
    }
    const sb = try asObject(try field(p, "sandbox"));
    try expectKeys(sb, &.{ "integrity", "job_memory_bytes", "active_process_limit", "timeout_ms", "output_limit_bytes" });
    const em = try asObject(try field(p, "emetgate"));
    try expectKeys(em, &.{"version"});
    const resolver = try field(p, "resolver");
    const batch = try asString(try field(p, "batch"));
    _ = try parseHex(8, batch);
    return .{
        .batch = batch,
        .operation = std.meta.stringToEnum(Operation, try asString(try field(p, "operation"))) orelse return error.InvalidReceipt,
        .class = std.meta.stringToEnum(Class, try asString(try field(p, "class"))) orelse return error.InvalidReceipt,
        .evidence = try asString(try field(p, "evidence")),
        .resolver = if (resolver == .null) null else try asString(resolver),
        .subjects = subjects.items,
        .files = files.items,
        .symbols = symbols.items,
        .checks = checks.items,
        .rules = rules.items,
        .sandbox = .{
            .integrity = try asString(try field(sb, "integrity")),
            .job_memory_bytes = try asInteger(try field(sb, "job_memory_bytes")),
            .active_process_limit = try asInteger(try field(sb, "active_process_limit")),
            .timeout_ms = try asInteger(try field(sb, "timeout_ms")),
            .output_limit_bytes = try asInteger(try field(sb, "output_limit_bytes")),
        },
        .version = try asString(try field(em, "version")),
    };
}

pub fn ruleDigest(arena: Allocator, id: []const u8, text: []const u8, mode: []const u8, check: ?[]const u8, where: ?[]const u8) !Hash {
    const value = try object(arena, .{
        .id = string(id),
        .text = string(text),
        .mode = string(mode),
        .check = if (check) |c| string(c) else Value.null,
        .where = if (where) |w| string(w) else Value.null,
    });
    return blake3(try jcs.canonicalize(arena, value));
}

pub fn encode(arena: Allocator, r: Receipt) ![]u8 {
    return jcs.canonicalize(arena, try toValue(arena, r));
}

const testing = std.testing;

pub fn sample() Receipt {
    return .{
        .batch = "0123456789abcdef",
        .operation = .@"try",
        .class = .spending,
        .evidence = "test",
        .resolver = null,
        .subjects = &.{},
        .files = &.{.{ .path = "src/a.ts", .before = blake3("a"), .after = blake3("b") }},
        .symbols = &.{.{ .path = "src/a.ts", .ref = "add", .before = blake3("x"), .after = blake3("y") }},
        .checks = &.{.{ .kind = .@"test", .command = "npm test", .command_digest = blake3("npm test"), .exit_code = 0, .duration_ms = 12 }},
        .rules = &.{.{ .id = "R1", .digest = blake3("rule") }},
        .sandbox = .{ .integrity = "low", .job_memory_bytes = 1, .active_process_limit = 2, .timeout_ms = 3, .output_limit_bytes = 4 },
        .version = "0.1.0",
    };
}

test "receipt: a receipt encodes to canonical JSON and decodes back to the same fields" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bytes = try encode(arena, sample());
    try testing.expect(std.mem.startsWith(u8, bytes, "{\"_type\":\"https://in-toto.io/Statement/v1\",\"predicate\":{\"batch\""));
    const parsed = try jcs.parse(arena, bytes);
    const again = try jcs.canonicalize(arena, parsed.value);
    try testing.expectEqualStrings(bytes, again);
    const back = try fromValue(arena, parsed.value);
    try testing.expectEqual(Operation.@"try", back.operation);
    try testing.expectEqualStrings("add", back.symbols[0].ref);
    try testing.expectEqual(blake3("b"), back.files[0].after.?);
    try testing.expectEqual(@as(?i64, 12), back.checks[0].duration_ms);
}

test "receipt: an unknown field, a missing field, an escaping path and a bad digest are invalid" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const good = try encode(arena, sample());
    const cases = [_]struct { from: []const u8, to: []const u8 }{
        .{ .from = "\"batch\":", .to = "\"extra\":1,\"batch\":" },
        .{ .from = "\"evidence\":\"test\",", .to = "" },
        .{ .from = "\"path\":\"src/a.ts\"", .to = "\"path\":\"../a.ts\"" },
        .{ .from = "\"command_digest\":\"", .to = "\"command_digest\":\"zz" },
    };
    for (cases) |c| {
        const bad = try std.mem.replaceOwned(u8, arena, good, c.from, c.to);
        const parsed = try jcs.parse(arena, bad);
        try testing.expectError(error.InvalidReceipt, fromValue(arena, parsed.value));
    }
}
