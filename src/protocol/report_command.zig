const std = @import("std");
const repo_mod = @import("../platform/repo.zig");
const shadow = @import("../platform/shadow.zig");
const receipts = @import("../platform/receipts.zig");
const telemetry = @import("telemetry.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;

pub const usage =
    \\       emetgate report [--session <id> | --all] [--root <dir>] [--json]
    \\
;

pub const max_transcript_bytes = 1024 * 1024 * 1024;
pub const max_events_bytes = 256 * 1024 * 1024;
pub const window_slack_ms: i64 = 5000;
const max_encoded_dir = 200;

pub const Options = struct {
    session: ?[]const u8 = null,
    all: bool = false,
    json: bool = false,
    root: ?[]const u8 = null,
};

pub fn parse(args: []const [:0]const u8) ?Options {
    var options: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            options.json = true;
        } else if (std.mem.eql(u8, arg, "--all")) {
            options.all = true;
        } else if (std.mem.eql(u8, arg, "--session") or std.mem.eql(u8, arg, "--root")) {
            i += 1;
            if (i >= args.len) return null;
            const slot = if (std.mem.eql(u8, arg, "--session")) &options.session else &options.root;
            if (slot.* != null) return null;
            slot.* = args[i];
        } else return null;
    }
    if (options.all and options.session != null) return null;
    return options;
}

pub const Selection = union(enum) { latest, one: []const u8, all };

pub const Price = struct { input: f64, output: f64, cache_read: f64 };

const PriceRow = struct { prefix: []const u8, price: Price };

const price_rows = [_]PriceRow{
    .{ .prefix = "claude-fable-5-2", .price = .{ .input = 8, .output = 40, .cache_read = 0.20 } },
    .{ .prefix = "claude-mythos-5-2", .price = .{ .input = 8, .output = 40, .cache_read = 0.20 } },
    .{ .prefix = "claude-fable-5-1", .price = .{ .input = 10, .output = 50, .cache_read = 0.25 } },
    .{ .prefix = "claude-mythos-5-1", .price = .{ .input = 10, .output = 50, .cache_read = 0.25 } },
    .{ .prefix = "claude-fable-5", .price = .{ .input = 10, .output = 50, .cache_read = 1.00 } },
    .{ .prefix = "claude-mythos-5", .price = .{ .input = 10, .output = 50, .cache_read = 1.00 } },
    .{ .prefix = "claude-opus-5-5", .price = .{ .input = 4, .output = 20, .cache_read = 0.20 } },
    .{ .prefix = "claude-opus-5", .price = .{ .input = 5, .output = 25, .cache_read = 0.50 } },
    .{ .prefix = "claude-opus-4-8", .price = .{ .input = 5, .output = 25, .cache_read = 0.50 } },
    .{ .prefix = "claude-opus-4-7", .price = .{ .input = 5, .output = 25, .cache_read = 0.50 } },
    .{ .prefix = "claude-opus-4-6", .price = .{ .input = 5, .output = 25, .cache_read = 0.50 } },
    .{ .prefix = "claude-opus-4-5", .price = .{ .input = 5, .output = 25, .cache_read = 0.50 } },
    .{ .prefix = "claude-opus-4", .price = .{ .input = 15, .output = 75, .cache_read = 1.50 } },
    .{ .prefix = "claude-sonnet-5-5", .price = .{ .input = 2, .output = 10, .cache_read = 0.10 } },
    .{ .prefix = "claude-sonnet-5", .price = .{ .input = 2, .output = 10, .cache_read = 0.20 } },
    .{ .prefix = "claude-sonnet-4", .price = .{ .input = 3, .output = 15, .cache_read = 0.30 } },
    .{ .prefix = "claude-3-7-sonnet", .price = .{ .input = 3, .output = 15, .cache_read = 0.30 } },
    .{ .prefix = "claude-3-5-sonnet", .price = .{ .input = 3, .output = 15, .cache_read = 0.30 } },
    .{ .prefix = "claude-haiku-5-5", .price = .{ .input = 0.10, .output = 0.50, .cache_read = 0.01 } },
    .{ .prefix = "claude-haiku-4-5", .price = .{ .input = 1, .output = 5, .cache_read = 0.10 } },
    .{ .prefix = "claude-3-5-haiku", .price = .{ .input = 0.80, .output = 4, .cache_read = 0.08 } },
    .{ .prefix = "claude-3-haiku", .price = .{ .input = 0.25, .output = 1.25, .cache_read = 0.03 } },
};

pub fn priceOf(model: []const u8) ?Price {
    const start = std.mem.indexOf(u8, model, "claude-") orelse return null;
    const id = model[start..];
    for (price_rows) |entry| {
        if (!std.mem.startsWith(u8, id, entry.prefix)) continue;
        const rest = id[entry.prefix.len..];
        if (rest.len == 0 or rest[0] == '-' or rest[0] == '@' or rest[0] == ':' or rest[0] == '[') return entry.price;
    }
    return null;
}

pub const Tokens = struct {
    input: u64 = 0,
    output: u64 = 0,
    cache_read: u64 = 0,
    cache_write_5m: u64 = 0,
    cache_write_1h: u64 = 0,

    pub fn cacheWrite(self: Tokens) u64 {
        return self.cache_write_5m + self.cache_write_1h;
    }

    fn add(self: *Tokens, other: Tokens) void {
        self.input += other.input;
        self.output += other.output;
        self.cache_read += other.cache_read;
        self.cache_write_5m += other.cache_write_5m;
        self.cache_write_1h += other.cache_write_1h;
    }

    pub fn cost(self: Tokens, price: Price) f64 {
        const m = 1_000_000.0;
        return (f(self.input) * price.input + f(self.output) * price.output + f(self.cache_read) * price.cache_read +
            f(self.cache_write_5m) * price.input * 1.25 + f(self.cache_write_1h) * price.input * 2.0) / m;
    }
};

fn f(n: u64) f64 {
    return @floatFromInt(n);
}

pub const ModelUse = struct { model: []const u8, turns: u64 = 0, tokens: Tokens = .{}, cost_usd: ?f64 = null };

pub const ToolCount = struct { name: []const u8, count: u64 };

pub const Gate = struct {
    events: u64 = 0,
    writes_applied: u64 = 0,
    writes_rejected: u64 = 0,
    rule_violations: u64 = 0,
    tests_run: u64 = 0,
    tests_failed: u64 = 0,
    test_ms: u64 = 0,
    commands_run: u64 = 0,
    commits: u64 = 0,
    receipts: u64 = 0,

    fn add(self: *Gate, other: Gate) void {
        inline for (std.meta.fields(Gate)) |gf| @field(self, gf.name) += @field(other, gf.name);
    }
};

pub const Summary = struct {
    id: []const u8,
    gated: bool = false,
    started: ?[]const u8 = null,
    ended: ?[]const u8 = null,
    start_ms: ?i64 = null,
    end_ms: ?i64 = null,
    turns: u64 = 0,
    tokens: Tokens = .{},
    cost_usd: f64 = 0,
    unpriced_turns: u64 = 0,
    models: []const ModelUse = &.{},
    tools: []const ToolCount = &.{},
    gate: Gate = .{},

    pub fn durationMs(self: Summary) u64 {
        const s = self.start_ms orelse return 0;
        const e = self.end_ms orelse return 0;
        return if (e > s) @intCast(e - s) else 0;
    }

    pub fn toolCalls(self: Summary) u64 {
        var n: u64 = 0;
        for (self.tools) |t| n += t.count;
        return n;
    }
};

pub fn encodeProjectDir(arena: Allocator, path: []const u8) ![]u8 {
    const out = try arena.dupe(u8, path);
    for (out) |*c| {
        if (!std.ascii.isAlphanumeric(c.*)) c.* = '-';
    }
    return out;
}

pub fn findProjectDir(arena: Allocator, io: std.Io, projects_abs: []const u8, cwd_abs: []const u8) !?[]u8 {
    const encoded = try encodeProjectDir(arena, cwd_abs);
    const exact = try std.fs.path.join(arena, &.{ projects_abs, encoded });
    if (std.Io.Dir.cwd().openDir(io, exact, .{})) |dir| {
        dir.close(io);
        return exact;
    } else |_| {}
    var projects = std.Io.Dir.cwd().openDir(io, projects_abs, .{ .iterate = true }) catch return null;
    defer projects.close(io);
    const long = encoded.len > max_encoded_dir;
    var it = projects.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const same = if (long)
            entry.name.len > max_encoded_dir and std.ascii.eqlIgnoreCase(entry.name[0..max_encoded_dir], encoded[0..max_encoded_dir])
        else
            std.ascii.eqlIgnoreCase(entry.name, encoded);
        if (same) return try std.fs.path.join(arena, &.{ projects_abs, entry.name });
    }
    return null;
}

pub fn parseIsoMs(text: []const u8) ?i64 {
    if (text.len < 19 or text[4] != '-' or text[7] != '-' or (text[10] != 'T' and text[10] != ' ') or text[13] != ':' or text[16] != ':') return null;
    const year = std.fmt.parseInt(i64, text[0..4], 10) catch return null;
    const month = std.fmt.parseInt(i64, text[5..7], 10) catch return null;
    const day = std.fmt.parseInt(i64, text[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(i64, text[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(i64, text[14..16], 10) catch return null;
    const second = std.fmt.parseInt(i64, text[17..19], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    var ms: i64 = 0;
    if (text.len > 20 and text[19] == '.') {
        var scale: i64 = 100;
        var i: usize = 20;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
            ms += @as(i64, text[i] - '0') * scale;
            scale = @divTrunc(scale, 10);
        }
    }
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(month + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return ((days * 24 + hour) * 60 + minute) * 60 * 1000 + second * 1000 + ms;
}

fn field(v: ?Value, name: []const u8) ?Value {
    const value = v orelse return null;
    if (value != .object) return null;
    return value.object.get(name);
}

fn str(v: ?Value) ?[]const u8 {
    const value = v orelse return null;
    return if (value == .string) value.string else null;
}

fn count(v: ?Value) u64 {
    const value = v orelse return 0;
    return switch (value) {
        .integer => |i| if (i > 0) @intCast(i) else 0,
        .float => |x| if (x > 0) @intFromFloat(x) else 0,
        else => 0,
    };
}

pub fn tokensOf(usage_value: ?Value) Tokens {
    const written = count(field(usage_value, "cache_creation_input_tokens"));
    var tokens: Tokens = .{
        .input = count(field(usage_value, "input_tokens")),
        .output = count(field(usage_value, "output_tokens")),
        .cache_read = count(field(usage_value, "cache_read_input_tokens")),
        .cache_write_5m = written,
    };
    const split = field(usage_value, "cache_creation");
    if (split != null and split.? == .object) {
        const hour = @min(written, count(field(split, "ephemeral_1h_input_tokens")));
        tokens.cache_write_1h = hour;
        tokens.cache_write_5m = written - hour;
    }
    return tokens;
}

pub fn toolName(name: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, name, "mcp__")) return name;
    const rest = name["mcp__".len..];
    const cut = std.mem.indexOf(u8, rest, "__") orelse return name;
    return rest[cut + 2 ..];
}

const Turn = struct { model: []const u8, tokens: Tokens };

const Acc = struct {
    gpa: Allocator,
    arena: Allocator,
    turns: std.StringArrayHashMapUnmanaged(Turn) = .empty,
    tool_ids: std.StringHashMapUnmanaged(void) = .empty,
    tools: std.StringArrayHashMapUnmanaged(u64) = .empty,
    anonymous: u64 = 0,
    started: ?[]const u8 = null,
    ended: ?[]const u8 = null,
    start_ms: ?i64 = null,
    end_ms: ?i64 = null,

    fn readFile(self: *Acc, io: std.Io, path: []const u8, main: bool) !void {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, self.gpa, .limited(max_transcript_bytes));
        defer self.gpa.free(bytes);
        try self.readBytes(bytes, main);
    }

    fn readBytes(self: *Acc, bytes: []const u8, main: bool) !void {
        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \r\t");
            if (line.len == 0) continue;
            _ = scratch.reset(.retain_capacity);
            const root = std.json.parseFromSliceLeaky(Value, scratch.allocator(), line, .{}) catch continue;
            try self.readLine(root, main);
        }
    }

    fn stamp(self: *Acc, text: ?[]const u8) !void {
        const ts = text orelse return;
        const ms = parseIsoMs(ts) orelse return;
        if (self.start_ms == null or ms < self.start_ms.?) {
            self.start_ms = ms;
            self.started = try self.arena.dupe(u8, ts);
        }
        if (self.end_ms == null or ms > self.end_ms.?) {
            self.end_ms = ms;
            self.ended = try self.arena.dupe(u8, ts);
        }
    }

    fn readLine(self: *Acc, root: Value, main: bool) !void {
        if (main) try self.stamp(str(field(root, "timestamp")));
        const kind = str(field(root, "type")) orelse return;
        if (!std.mem.eql(u8, kind, "assistant")) return;
        const message = field(root, "message");
        const model = str(field(message, "model")) orelse "unknown";
        if (std.mem.eql(u8, model, "<synthetic>")) return;
        if (field(message, "usage")) |usage_value| {
            const tokens = tokensOf(usage_value);
            const key = if (str(field(message, "id"))) |id| id else blk: {
                self.anonymous += 1;
                break :blk try std.fmt.allocPrint(self.arena, "\x00{d}", .{self.anonymous});
            };
            const slot = try self.turns.getOrPut(self.arena, key);
            if (!slot.found_existing) {
                slot.key_ptr.* = try self.arena.dupe(u8, key);
                slot.value_ptr.* = .{ .model = try self.arena.dupe(u8, model), .tokens = tokens };
            } else slot.value_ptr.tokens = tokens;
        }
        const content = field(message, "content") orelse return;
        if (content != .array) return;
        for (content.array.items) |block| {
            const block_kind = str(field(block, "type")) orelse continue;
            if (!std.mem.eql(u8, block_kind, "tool_use")) continue;
            const name = str(field(block, "name")) orelse continue;
            if (str(field(block, "id"))) |id| {
                const seen = try self.tool_ids.getOrPut(self.arena, id);
                if (seen.found_existing) continue;
                seen.key_ptr.* = try self.arena.dupe(u8, id);
            }
            const short = toolName(name);
            const slot = try self.tools.getOrPut(self.arena, short);
            if (!slot.found_existing) {
                slot.key_ptr.* = try self.arena.dupe(u8, short);
                slot.value_ptr.* = 0;
            }
            slot.value_ptr.* += 1;
        }
    }

    fn finish(self: *Acc, id: []const u8) !Summary {
        var summary: Summary = .{
            .id = try self.arena.dupe(u8, id),
            .started = self.started,
            .ended = self.ended,
            .start_ms = self.start_ms,
            .end_ms = self.end_ms,
        };
        var models: std.StringArrayHashMapUnmanaged(ModelUse) = .empty;
        for (self.turns.values()) |turn| {
            summary.turns += 1;
            summary.tokens.add(turn.tokens);
            const slot = try models.getOrPut(self.arena, turn.model);
            if (!slot.found_existing) slot.value_ptr.* = .{ .model = turn.model };
            slot.value_ptr.turns += 1;
            slot.value_ptr.tokens.add(turn.tokens);
        }
        for (models.values()) |*use| {
            if (priceOf(use.model)) |price| {
                use.cost_usd = use.tokens.cost(price);
                summary.cost_usd += use.cost_usd.?;
            } else summary.unpriced_turns += use.turns;
        }
        summary.models = models.values();
        const tools = try self.arena.alloc(ToolCount, self.tools.count());
        for (self.tools.keys(), self.tools.values(), tools) |name, n, *slot| {
            slot.* = .{ .name = name, .count = n };
            if (std.mem.startsWith(u8, name, "emetgate_")) summary.gated = true;
        }
        std.mem.sort(ToolCount, tools, {}, moreCalls);
        summary.tools = tools;
        return summary;
    }
};

fn moreCalls(_: void, a: ToolCount, b: ToolCount) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.lessThan(u8, a.name, b.name);
}

pub fn summarizeBytes(gpa: Allocator, arena: Allocator, id: []const u8, main: []const u8, subagents: []const []const u8) !Summary {
    var acc: Acc = .{ .gpa = gpa, .arena = arena };
    try acc.readBytes(main, true);
    for (subagents) |bytes| try acc.readBytes(bytes, false);
    return acc.finish(id);
}

pub fn summarizeSession(gpa: Allocator, arena: Allocator, io: std.Io, project_dir: []const u8, id: []const u8) !Summary {
    var acc: Acc = .{ .gpa = gpa, .arena = arena };
    const name = try std.fmt.allocPrint(arena, "{s}.jsonl", .{id});
    try acc.readFile(io, try std.fs.path.join(arena, &.{ project_dir, name }), true);
    const sub_abs = try std.fs.path.join(arena, &.{ project_dir, id, "subagents" });
    if (std.Io.Dir.cwd().openDir(io, sub_abs, .{ .iterate = true })) |opened| {
        var dir = opened;
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
            try acc.readFile(io, try std.fs.path.join(arena, &.{ sub_abs, entry.name }), false);
        }
    } else |_| {}
    return acc.finish(id);
}

pub const Candidate = struct { id: []const u8, mtime_ns: i96 };

fn newer(_: void, a: Candidate, b: Candidate) bool {
    if (a.mtime_ns != b.mtime_ns) return a.mtime_ns > b.mtime_ns;
    return std.mem.lessThan(u8, b.id, a.id);
}

pub fn listSessions(arena: Allocator, io: std.Io, project_dir: []const u8) ![]Candidate {
    var found: std.ArrayList(Candidate) = .empty;
    var dir = std.Io.Dir.cwd().openDir(io, project_dir, .{ .iterate = true }) catch return found.items;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        try found.append(arena, .{ .id = try arena.dupe(u8, entry.name[0 .. entry.name.len - ".jsonl".len]), .mtime_ns = stat.mtime.nanoseconds });
    }
    std.mem.sort(Candidate, found.items, {}, newer);
    return found.items;
}

pub const GateEvent = struct {
    ts: i64,
    tool: []const u8,
    result: []const u8,
    reason: ?[]const u8,
    gated: bool,
    test_ms: u64,
};

pub const GateLog = struct {
    events: []const GateEvent = &.{},
    receipts_ms: []const i64 = &.{},

    pub fn within(self: GateLog, start_ms: ?i64, end_ms: ?i64) Gate {
        var gate: Gate = .{};
        const start = start_ms orelse return gate;
        const end = (end_ms orelse start) + window_slack_ms;
        for (self.events) |event| {
            if (event.ts < start or event.ts > end) continue;
            tally(&gate, event);
        }
        for (self.receipts_ms) |ms| {
            if (ms >= start and ms <= end) gate.receipts += 1;
        }
        return gate;
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn tally(gate: *Gate, event: GateEvent) void {
    gate.events += 1;
    const is_commit = eql(event.tool, "emetgate_commit");
    const is_run = eql(event.tool, "emetgate_run");
    if (is_run) gate.commands_run += 1;
    if (eql(event.result, "committed")) {
        if (is_commit) gate.commits += 1 else gate.writes_applied += 1;
    }
    if (eql(event.result, "rejected") and !is_commit and !is_run) gate.writes_rejected += 1;
    if (event.reason) |reason| {
        if (eql(reason, "rule_violation")) gate.rule_violations += 1;
        if (eql(reason, "tests_failed") or eql(reason, "tests_failing")) gate.tests_failed += 1;
    }
    if (event.gated) {
        gate.tests_run += 1;
        gate.test_ms += event.test_ms;
    }
}

pub fn parseEvents(gpa: Allocator, arena: Allocator, bytes: []const u8) ![]GateEvent {
    var events: std.ArrayList(GateEvent) = .empty;
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;
        _ = scratch.reset(.retain_capacity);
        const root = std.json.parseFromSliceLeaky(Value, scratch.allocator(), line, .{}) catch continue;
        const ts = field(root, "ts") orelse continue;
        if (ts != .integer) continue;
        const gate_value = field(root, "gate");
        try events.append(arena, .{
            .ts = ts.integer,
            .tool = try arena.dupe(u8, str(field(root, "tool")) orelse ""),
            .result = try arena.dupe(u8, str(field(root, "result")) orelse ""),
            .reason = if (str(field(root, "reason"))) |r| try arena.dupe(u8, r) else null,
            .gated = gate_value != null and gate_value.? == .string,
            .test_ms = count(field(root, "test_ms")),
        });
    }
    return events.items;
}

pub fn receiptMs(name: []const u8) ?i64 {
    if (name.len < 21 or name[20] != '-' or !std.mem.endsWith(u8, name, ".json")) return null;
    const ns = std.fmt.parseInt(u128, name[0..20], 10) catch return null;
    return @intCast(ns / std.time.ns_per_ms);
}

pub fn loadGate(gpa: Allocator, arena: Allocator, io: std.Io, root_abs: []const u8) !GateLog {
    const workspace = try std.fs.path.join(arena, &.{ root_abs, shadow.workspace_dir });
    const events_abs = try std.fs.path.join(arena, &.{ workspace, telemetry.events_file });
    var log: GateLog = .{};
    if (std.Io.Dir.cwd().readFileAlloc(io, events_abs, gpa, .limited(max_events_bytes))) |bytes| {
        defer gpa.free(bytes);
        log.events = try parseEvents(gpa, arena, bytes);
    } else |_| {}
    var stamps: std.ArrayList(i64) = .empty;
    const receipts_abs = try std.fs.path.join(arena, &.{ workspace, receipts.receipts_dir });
    for ([_][]const u8{ receipts_abs, try std.fs.path.join(arena, &.{ receipts_abs, "attached" }) }) |dir_abs| {
        var dir = std.Io.Dir.cwd().openDir(io, dir_abs, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (receiptMs(entry.name)) |ms| try stamps.append(arena, ms);
        }
    }
    log.receipts_ms = stamps.items;
    return log;
}

pub const ReportError = error{ NoSessions, SessionNotFound, SessionAmbiguous };

pub fn collect(gpa: Allocator, arena: Allocator, io: std.Io, project_dir: []const u8, gate_log: GateLog, selection: Selection) ![]Summary {
    const candidates = try listSessions(arena, io, project_dir);
    if (candidates.len == 0) return error.NoSessions;
    var picked: std.ArrayList(Summary) = .empty;
    switch (selection) {
        .one => |wanted| {
            var match: ?Candidate = null;
            for (candidates) |c| {
                if (!std.mem.startsWith(u8, c.id, wanted)) continue;
                if (eql(c.id, wanted)) {
                    match = c;
                    break;
                }
                if (match != null) return error.SessionAmbiguous;
                match = c;
            }
            const c = match orelse return error.SessionNotFound;
            try picked.append(arena, try summarizeSession(gpa, arena, io, project_dir, c.id));
        },
        .latest => {
            var fallback: ?Summary = null;
            for (candidates) |c| {
                const summary = try summarizeSession(gpa, arena, io, project_dir, c.id);
                if (fallback == null) fallback = summary;
                if (summary.gated) {
                    try picked.append(arena, summary);
                    break;
                }
            } else try picked.append(arena, fallback.?);
        },
        .all => {
            for (candidates) |c| try picked.append(arena, try summarizeSession(gpa, arena, io, project_dir, c.id));
            std.mem.sort(Summary, picked.items, {}, earlier);
        },
    }
    for (picked.items) |*summary| summary.gate = gate_log.within(summary.start_ms, summary.end_ms);
    return picked.items;
}

fn earlier(_: void, a: Summary, b: Summary) bool {
    const x = a.start_ms orelse std.math.maxInt(i64);
    const y = b.start_ms orelse std.math.maxInt(i64);
    if (x != y) return x < y;
    return std.mem.lessThan(u8, a.id, b.id);
}

pub fn total(summaries: []const Summary) Summary {
    var sum: Summary = .{ .id = "total" };
    var duration: u64 = 0;
    for (summaries) |s| {
        sum.turns += s.turns;
        sum.tokens.add(s.tokens);
        sum.cost_usd += s.cost_usd;
        sum.unpriced_turns += s.unpriced_turns;
        sum.gate.add(s.gate);
        sum.gated = sum.gated or s.gated;
        duration += s.durationMs();
    }
    sum.start_ms = 0;
    sum.end_ms = @intCast(duration);
    return sum;
}

pub fn writeCount(w: *Writer, n: u64) !void {
    var buf: [32]u8 = undefined;
    const digits = std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable;
    for (digits, 0..) |c, i| {
        if (i != 0 and (digits.len - i) % 3 == 0) try w.writeByte(',');
        try w.writeByte(c);
    }
}

fn writeShort(w: *Writer, n: u64) !void {
    const x = f(n);
    if (n < 1000) return w.print("{d}", .{n});
    if (n < 1_000_000) return w.print("{d:.1}k", .{x / 1000});
    if (n < 1_000_000_000) return w.print("{d:.1}M", .{x / 1_000_000});
    return w.print("{d:.1}B", .{x / 1_000_000_000});
}

pub fn writeDuration(w: *Writer, ms: u64) !void {
    const s = ms / 1000;
    if (s >= 3600) return w.print("{d}h {d:0>2}m", .{ s / 3600, (s % 3600) / 60 });
    if (s >= 60) return w.print("{d}m {d:0>2}s", .{ s / 60, s % 60 });
    return w.print("{d}s", .{s});
}

fn writeStarted(w: *Writer, started: ?[]const u8) !void {
    const ts = started orelse return w.writeAll("-");
    if (ts.len < 19) return w.writeAll(ts);
    try w.print("{s} {s} UTC", .{ ts[0..10], ts[11..19] });
}

fn row(w: *Writer, label: []const u8) !void {
    try w.print("  {s}", .{label});
    var pad = 18 -| label.len;
    while (pad > 0) : (pad -= 1) try w.writeByte(' ');
}

pub fn writeText(w: *Writer, s: Summary) !void {
    try w.print("emetgate report · session {s}{s}\n", .{ s.id, if (s.gated) " (emetgate tools)" else " (no emetgate tool calls)" });
    try row(w, "started");
    try writeStarted(w, s.started);
    try w.writeByte('\n');
    try row(w, "duration");
    try writeDuration(w, s.durationMs());
    try w.writeByte('\n');
    try row(w, "model turns");
    try writeCount(w, s.turns);
    for (s.models, 0..) |m, i| {
        try w.writeAll(if (i == 0) "  (" else ", ");
        try w.print("{s} ", .{m.model});
        try writeCount(w, m.turns);
        if (i + 1 == s.models.len) try w.writeByte(')');
    }
    try w.writeByte('\n');
    const token_rows = [_]struct { []const u8, u64 }{
        .{ "input tokens", s.tokens.input },
        .{ "output tokens", s.tokens.output },
        .{ "cache read", s.tokens.cache_read },
        .{ "cache write", s.tokens.cacheWrite() },
    };
    for (token_rows) |r| {
        try row(w, r[0]);
        try writeCount(w, r[1]);
        try w.writeByte('\n');
    }
    try row(w, "cost (estimate)");
    try w.print("${d:.2}", .{s.cost_usd});
    if (s.unpriced_turns != 0) try w.print(" + {d} turns of unknown models, not priced", .{s.unpriced_turns});
    try w.writeByte('\n');
    try row(w, "tool calls");
    try writeCount(w, s.toolCalls());
    for (s.tools, 0..) |t, i| {
        try w.writeAll(if (i == 0) ": " else ", ");
        try w.print("{s} {d}", .{ t.name, t.count });
    }
    try w.writeByte('\n');
    try writeGateRows(w, s.gate);
    try w.writeAll("\ncost is an estimate from emetgate's built-in list prices per model (USD per million tokens);\nyour bill depends on your plan and current prices.\n");
}

fn writeGateRows(w: *Writer, g: Gate) !void {
    const gate_rows = [_]struct { []const u8, u64 }{
        .{ "writes applied", g.writes_applied },
        .{ "writes rejected", g.writes_rejected },
        .{ "rule violations", g.rule_violations },
        .{ "commands run", g.commands_run },
        .{ "receipts", g.receipts },
        .{ "commits", g.commits },
    };
    for (gate_rows[0..3]) |r| {
        try row(w, r[0]);
        try writeCount(w, r[1]);
        try w.writeByte('\n');
    }
    try row(w, "tests run");
    try writeCount(w, g.tests_run);
    if (g.tests_run != 0) {
        try w.print(" ({d} failed", .{g.tests_failed});
        if (g.test_ms != 0) {
            try w.writeAll(", ");
            try writeDuration(w, g.test_ms);
            try w.writeAll(" in tests");
        }
        try w.writeByte(')');
    }
    try w.writeByte('\n');
    for (gate_rows[3..]) |r| {
        try row(w, r[0]);
        try writeCount(w, r[1]);
        try w.writeByte('\n');
    }
}

const columns = [_]struct { []const u8, usize }{
    .{ "session", 10 },    .{ "started", 18 }, .{ "duration", 10 }, .{ "turns", 7 },    .{ "output", 8 },
    .{ "cache read", 11 }, .{ "cost", 9 },     .{ "writes", 7 },    .{ "rejected", 9 }, .{ "rules", 6 },
    .{ "tests", 0 },
};

fn cell(w: *Writer, text: []const u8, width: usize) !void {
    try w.writeAll(text);
    if (width == 0) return;
    var pad = if (text.len < width) width - text.len else 1;
    while (pad > 0) : (pad -= 1) try w.writeByte(' ');
}

fn writeTableRow(w: *Writer, s: Summary, is_total: bool) !void {
    var buf: [64]u8 = undefined;
    var b: Writer = .fixed(&buf);
    const id = if (is_total) "total" else s.id[0..@min(8, s.id.len)];
    try cell(w, id, columns[0][1]);
    b.end = 0;
    if (is_total) try b.writeAll("") else if (s.started) |ts| {
        if (ts.len >= 16) try b.print("{s} {s}", .{ ts[0..10], ts[11..16] }) else try b.writeAll(ts);
    } else try b.writeAll("-");
    try cell(w, b.buffered(), columns[1][1]);
    b.end = 0;
    try writeDuration(&b, s.durationMs());
    try cell(w, b.buffered(), columns[2][1]);
    const numbers = [_]u64{ s.turns, s.tokens.output, s.tokens.cache_read };
    for (numbers, columns[3..6]) |n, col| {
        b.end = 0;
        try writeShort(&b, n);
        try cell(w, b.buffered(), col[1]);
    }
    b.end = 0;
    try b.print("${d:.2}{s}", .{ s.cost_usd, if (s.unpriced_turns != 0) "+" else "" });
    try cell(w, b.buffered(), columns[6][1]);
    const gate_numbers = [_]u64{ s.gate.writes_applied, s.gate.writes_rejected, s.gate.rule_violations, s.gate.tests_run };
    for (gate_numbers, columns[7..]) |n, col| {
        b.end = 0;
        try b.print("{d}", .{n});
        try cell(w, b.buffered(), col[1]);
    }
    try w.writeByte('\n');
}

pub fn writeTable(w: *Writer, summaries: []const Summary) !void {
    for (columns) |col| try cell(w, col[0], col[1]);
    try w.writeByte('\n');
    for (summaries) |s| try writeTableRow(w, s, false);
    if (summaries.len > 1) try writeTableRow(w, total(summaries), true);
    try w.writeAll("\ncost is an estimate from emetgate's built-in list prices per model; + marks sessions with unpriced models.\n");
}

fn writeTokensJson(js: *std.json.Stringify, t: Tokens) !void {
    try js.beginObject();
    try js.objectField("input");
    try js.write(t.input);
    try js.objectField("output");
    try js.write(t.output);
    try js.objectField("cache_read");
    try js.write(t.cache_read);
    try js.objectField("cache_write");
    try js.write(t.cacheWrite());
    try js.objectField("cache_write_5m");
    try js.write(t.cache_write_5m);
    try js.objectField("cache_write_1h");
    try js.write(t.cache_write_1h);
    try js.endObject();
}

fn writeCost(js: *std.json.Stringify, cost: f64) !void {
    try js.print("{d:.4}", .{cost});
}

fn writeGateJson(js: *std.json.Stringify, g: Gate) !void {
    try js.beginObject();
    inline for (std.meta.fields(Gate)) |gf| {
        try js.objectField(gf.name);
        try js.write(@field(g, gf.name));
    }
    try js.endObject();
}

fn writeSummaryJson(js: *std.json.Stringify, s: Summary) !void {
    try js.beginObject();
    try js.objectField("session");
    try js.write(s.id);
    try js.objectField("emetgate_tools");
    try js.write(s.gated);
    try js.objectField("started");
    try js.write(s.started);
    try js.objectField("ended");
    try js.write(s.ended);
    try js.objectField("duration_ms");
    try js.write(s.durationMs());
    try js.objectField("model_turns");
    try js.write(s.turns);
    try js.objectField("tokens");
    try writeTokensJson(js, s.tokens);
    try js.objectField("cost_usd_estimate");
    try writeCost(js, s.cost_usd);
    try js.objectField("unpriced_turns");
    try js.write(s.unpriced_turns);
    try js.objectField("models");
    try js.beginArray();
    for (s.models) |m| {
        try js.beginObject();
        try js.objectField("model");
        try js.write(m.model);
        try js.objectField("turns");
        try js.write(m.turns);
        try js.objectField("tokens");
        try writeTokensJson(js, m.tokens);
        try js.objectField("cost_usd_estimate");
        if (m.cost_usd) |c| try writeCost(js, c) else try js.write(null);
        try js.endObject();
    }
    try js.endArray();
    try js.objectField("tool_calls");
    try js.beginObject();
    for (s.tools) |t| {
        try js.objectField(t.name);
        try js.write(t.count);
    }
    try js.endObject();
    try js.objectField("gate");
    try writeGateJson(js, s.gate);
    try js.endObject();
}

pub fn writeJson(w: *Writer, summaries: []const Summary, all: bool) !void {
    var js: std.json.Stringify = .{ .writer = w };
    if (!all) {
        try writeSummaryJson(&js, summaries[0]);
    } else {
        const sum = total(summaries);
        try js.beginObject();
        try js.objectField("sessions");
        try js.beginArray();
        for (summaries) |s| try writeSummaryJson(&js, s);
        try js.endArray();
        try js.objectField("total");
        try js.beginObject();
        try js.objectField("sessions");
        try js.write(summaries.len);
        try js.objectField("duration_ms");
        try js.write(sum.durationMs());
        try js.objectField("model_turns");
        try js.write(sum.turns);
        try js.objectField("tokens");
        try writeTokensJson(&js, sum.tokens);
        try js.objectField("cost_usd_estimate");
        try writeCost(&js, sum.cost_usd);
        try js.objectField("unpriced_turns");
        try js.write(sum.unpriced_turns);
        try js.objectField("gate");
        try writeGateJson(&js, sum.gate);
        try js.endObject();
        try js.endObject();
    }
    try w.writeByte('\n');
}

pub fn configDir(arena: Allocator, environ: *const std.process.Environ.Map) !?[]const u8 {
    if (environ.get("CLAUDE_CONFIG_DIR")) |dir| if (dir.len != 0) return dir;
    for ([_][]const u8{ "USERPROFILE", "HOME" }) |name| {
        if (environ.get(name)) |home| if (home.len != 0) return try std.fs.path.join(arena, &.{ home, ".claude" });
    }
    return null;
}

pub fn run(gpa: Allocator, io: std.Io, environ: *const std.process.Environ.Map, options: Options, out: *Writer) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cwd_abs: []const u8 = if (options.root) |r| r else try std.Io.Dir.cwd().realPathFileAlloc(io, ".", arena);
    const root_abs: []const u8 = blk: {
        const served = repo_mod.servedRoot(gpa, io, options.root) catch break :blk cwd_abs;
        defer gpa.free(served);
        break :blk try arena.dupe(u8, served);
    };
    const config = (try configDir(arena, environ)) orelse {
        std.debug.print("emetgate report: no Claude config dir: set CLAUDE_CONFIG_DIR or USERPROFILE\n", .{});
        return 1;
    };
    const projects = try std.fs.path.join(arena, &.{ config, "projects" });
    const project_dir = (try findProjectDir(arena, io, projects, cwd_abs)) orelse
        (if (!std.mem.eql(u8, cwd_abs, root_abs)) try findProjectDir(arena, io, projects, root_abs) else null) orelse {
        std.debug.print("emetgate report: Claude Code has no session transcripts for {s} under {s}\n", .{ cwd_abs, projects });
        return 1;
    };
    const gate_log = try loadGate(gpa, arena, io, root_abs);
    const selection: Selection = if (options.all) .all else if (options.session) |id| .{ .one = id } else .latest;
    const summaries = collect(gpa, arena, io, project_dir, gate_log, selection) catch |err| switch (err) {
        error.NoSessions => {
            std.debug.print("emetgate report: no session transcripts in {s}\n", .{project_dir});
            return 1;
        },
        error.SessionNotFound => {
            std.debug.print("emetgate report: no session {s} in {s}\n", .{ options.session.?, project_dir });
            return 1;
        },
        error.SessionAmbiguous => {
            std.debug.print("emetgate report: more than one session starts with {s}; give more of the id\n", .{options.session.?});
            return 1;
        },
        else => |e| return e,
    };
    if (options.json) {
        try writeJson(out, summaries, options.all);
    } else if (options.all) {
        try writeTable(out, summaries);
    } else {
        try writeText(out, summaries[0]);
    }
    return 0;
}

const testing = std.testing;

const fixture_main =
    \\{"type":"user","timestamp":"2026-11-11T11:00:00.000Z","message":{"role":"user","content":"go"}}
    \\{"type":"assistant","timestamp":"2026-11-11T11:00:05.000Z","message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"thinking","thinking":""}],"usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":1000000,"cache_creation_input_tokens":2000,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":2000}}}}
    \\{"type":"assistant","timestamp":"2026-11-11T11:00:05.100Z","message":{"id":"msg_1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tu_1","name":"mcp__emetgate__emetgate_read_file","input":{}}],"usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":1000000,"cache_creation_input_tokens":2000,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":2000}}}}
    \\{"type":"user","timestamp":"2026-11-11T11:00:06.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_1","content":"ok"}]}}
    \\{"type":"assistant","timestamp":"2026-11-11T11:01:00.000Z","message":{"id":"msg_2","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tu_2","name":"mcp__emetgate__emetgate_change","input":{}},{"type":"tool_use","id":"tu_3","name":"mcp__emetgate__emetgate_read_file","input":{}}],"usage":{"input_tokens":5,"output_tokens":1000000,"cache_read_input_tokens":0,"cache_creation_input_tokens":1000000}}}
    \\{"type":"assistant","timestamp":"2026-11-11T11:01:00.100Z","message":{"id":"msg_2","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tu_2","name":"mcp__emetgate__emetgate_change","input":{}}],"usage":{"input_tokens":5,"output_tokens":1000000,"cache_read_input_tokens":0,"cache_creation_input_tokens":1000000}}}
    \\{"type":"assistant","timestamp":"2026-11-11T11:01:01.000Z","message":{"id":"msg_syn","model":"<synthetic>","content":[],"usage":{"input_tokens":0,"output_tokens":0}}}
    \\not json at all
    \\{"type":"last-prompt","lastPrompt":"go"}
    \\{"type":"assistant","timestamp":"2026-11-11T11:02:03.000Z","message":{"id":"msg_3","model":"some-other-model","content":[],"usage":{"input_tokens":7,"output_tokens":3}}}
    \\
;

const fixture_sub =
    \\{"type":"assistant","isSidechain":true,"timestamp":"2026-11-11T12:00:00.000Z","message":{"id":"msg_s1","model":"claude-haiku-4-5-20251001","content":[{"type":"tool_use","id":"tu_s1","name":"Read","input":{}}],"usage":{"input_tokens":1000000,"output_tokens":0}}}
    \\
;

test "report dedupes streamed lines by message id and prices each model" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const s = try summarizeBytes(testing.allocator, arena_state.allocator(), "abc", fixture_main, &.{fixture_sub});
    try testing.expectEqual(@as(u64, 4), s.turns);
    try testing.expectEqual(@as(u64, 10 + 5 + 7 + 1_000_000), s.tokens.input);
    try testing.expectEqual(@as(u64, 100 + 1_000_000 + 3), s.tokens.output);
    try testing.expectEqual(@as(u64, 1_000_000), s.tokens.cache_read);
    try testing.expectEqual(@as(u64, 2000), s.tokens.cache_write_1h);
    try testing.expectEqual(@as(u64, 1_000_000), s.tokens.cache_write_5m);
    try testing.expectEqual(@as(u64, 1), s.unpriced_turns);
    const opus = (15.0 * 4 + 1_000_100.0 * 20 + 1_000_000.0 * 0.20 + 2000.0 * 4 * 2.0 + 1_000_000.0 * 4 * 1.25) / 1_000_000.0;
    const haiku = 1.0;
    try testing.expectApproxEqAbs(opus + haiku, s.cost_usd, 1e-9);
    try testing.expect(s.gated);
    try testing.expectEqual(@as(u64, 4), s.toolCalls());
    try testing.expectEqualStrings("emetgate_read_file", s.tools[0].name);
    try testing.expectEqual(@as(u64, 2), s.tools[0].count);
    try testing.expectEqualStrings("2026-11-11T11:00:00.000Z", s.started.?);
    try testing.expectEqualStrings("2026-11-11T11:02:03.000Z", s.ended.?);
    try testing.expectEqual(@as(u64, 123_000), s.durationMs());
}

test "report prices model ids with date and platform affixes and refuses unknown ones" {
    try testing.expectEqual(@as(f64, 4), priceOf("claude-opus-5-5").?.input);
    try testing.expectEqual(@as(f64, 5), priceOf("claude-opus-4-5-20251101").?.input);
    try testing.expectEqual(@as(f64, 15), priceOf("claude-opus-4-1-20250805").?.input);
    try testing.expectEqual(@as(f64, 3), priceOf("us.anthropic.claude-sonnet-4-5-20250929-v1:0").?.input);
    try testing.expectEqual(@as(f64, 0.20), priceOf("claude-fable-5-2").?.cache_read);
    try testing.expectEqual(@as(f64, 1.00), priceOf("claude-fable-5").?.cache_read);
    try testing.expectEqual(@as(f64, 2), priceOf("claude-sonnet-5-5[1m]").?.input);
    try testing.expect(priceOf("claude-opus-55") == null);
    try testing.expect(priceOf("gpt-5") == null);
    try testing.expect(priceOf("<synthetic>") == null);
}

test "report encodes a project path the way Claude Code names its transcript folder" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings("C--Users-ugur-Desktop-projects-claude-test-claude-emetgate", try encodeProjectDir(arena_state.allocator(), "C:\\Users\\ugur\\Desktop\\projects\\claude-test\\claude-emetgate"));
    try testing.expectEqualStrings("--wsl-localhost-a-b", try encodeProjectDir(arena_state.allocator(), "\\\\wsl.localhost\\a_b"));
}

test "report parses transcript timestamps to epoch milliseconds" {
    try testing.expectEqual(@as(?i64, 0), parseIsoMs("1970-01-01T00:00:00.000Z"));
    try testing.expectEqual(@as(?i64, 1794392981684), parseIsoMs("2026-11-11T10:29:41.684Z"));
    try testing.expectEqual(@as(?i64, 951782400000), parseIsoMs("2000-02-29T00:00:00Z"));
    try testing.expect(parseIsoMs("yesterday") == null);
}

test "report counts gate events and receipts inside the session window only" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const events =
        \\{"ts":999,"tool":"emetgate_change","gate":"full","result":"committed","reason":null}
        \\{"ts":1000,"tool":"emetgate_change","gate":"full","test_ms":1500,"result":"committed","reason":null}
        \\{"ts":2000,"tool":"emetgate_try","gate":"scoped","test_ms":500,"result":"rejected","reason":"tests_failed"}
        \\{"ts":3000,"tool":"emetgate_change","gate":null,"result":"rejected","reason":"rule_violation"}
        \\{"ts":4000,"tool":"emetgate_run","command":"npm test","exit_code":1,"gate":null,"result":"ok","reason":null}
        \\{"ts":4500,"tool":"emetgate_run","gate":null,"result":"rejected","reason":"outside_root"}
        \\{"ts":5000,"tool":"emetgate_commit","gate":"full","result":"committed","reason":null}
        \\{"ts":5500,"tool":"emetgate_commit","gate":null,"result":"rejected","reason":"nothing_pending"}
        \\{"ts":6000,"tool":"emetgate_read_file","gate":null,"result":"ok","reason":null}
        \\garbage
        \\{"ts":99999,"tool":"emetgate_change","gate":"full","result":"committed","reason":null}
        \\
    ;
    const log: GateLog = .{
        .events = try parseEvents(testing.allocator, arena, events),
        .receipts_ms = &.{ 500, 1000, 5000, 99999 },
    };
    try testing.expectEqual(@as(usize, 10), log.events.len);
    const g = log.within(1000, 1000);
    try testing.expectEqual(@as(u64, 8), g.events);
    try testing.expectEqual(@as(u64, 1), g.writes_applied);
    try testing.expectEqual(@as(u64, 2), g.writes_rejected);
    try testing.expectEqual(@as(u64, 1), g.rule_violations);
    try testing.expectEqual(@as(u64, 3), g.tests_run);
    try testing.expectEqual(@as(u64, 1), g.tests_failed);
    try testing.expectEqual(@as(u64, 2000), g.test_ms);
    try testing.expectEqual(@as(u64, 2), g.commands_run);
    try testing.expectEqual(@as(u64, 1), g.commits);
    try testing.expectEqual(@as(u64, 2), g.receipts);
    try testing.expectEqual(@as(u64, 0), log.within(null, null).events);
}

test "report reads receipt times from receipt file names" {
    try testing.expectEqual(@as(?i64, 1794395525945), receiptMs("01794395525945076100-241c4af7566c4e77.json"));
    try testing.expect(receiptMs("attached") == null);
    try testing.expect(receiptMs("notes.json") == null);
}

test "report options parse" {
    const a = parse(&.{ "--all", "--json" }).?;
    try testing.expect(a.all and a.json and a.session == null);
    const b = parse(&.{ "--session", "abc", "--root", "C:\\x" }).?;
    try testing.expectEqualStrings("abc", b.session.?);
    try testing.expectEqualStrings("C:\\x", b.root.?);
    try testing.expect(parse(&.{ "--all", "--session", "abc" }) == null);
    try testing.expect(parse(&.{"--session"}) == null);
    try testing.expect(parse(&.{"stray"}) == null);
    try testing.expect(parse(&.{ "--root", "a", "--root", "b" }) == null);
}

fn writeFixture(dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(testing.io, parent);
    try dir.writeFile(testing.io, .{ .sub_path = path, .data = data });
}

const fixture_plain =
    \\{"type":"user","timestamp":"2026-11-11T13:00:00.000Z","message":{"role":"user","content":"hi"}}
    \\{"type":"assistant","timestamp":"2026-11-11T13:00:10.000Z","message":{"id":"msg_p","model":"claude-sonnet-5-5","content":[{"type":"tool_use","id":"tu_p","name":"Bash","input":{}}],"usage":{"input_tokens":3,"output_tokens":4}}}
    \\
;

test "report picks the latest session with emetgate calls and attributes gate data by time" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const abs = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(abs);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const project = try std.fs.path.join(arena, &.{ abs, "work", "my.app" });
    const encoded = try encodeProjectDir(arena, project);
    const projects_rel = "config/projects";
    try writeFixture(tmp.dir, try std.fmt.allocPrint(arena, "{s}/{s}/gated-1.jsonl", .{ projects_rel, encoded }), fixture_main);
    try writeFixture(tmp.dir, try std.fmt.allocPrint(arena, "{s}/{s}/gated-1/subagents/agent-a.jsonl", .{ projects_rel, encoded }), fixture_sub);
    try writeFixture(tmp.dir, try std.fmt.allocPrint(arena, "{s}/{s}/plain-2.jsonl", .{ projects_rel, encoded }), fixture_plain);
    const start = parseIsoMs("2026-11-11T11:00:00.000Z").?;
    const events = try std.fmt.allocPrint(arena,
        \\{{"ts":{d},"tool":"emetgate_change","gate":"full","test_ms":2000,"result":"committed","reason":null}}
        \\{{"ts":{d},"tool":"emetgate_change","gate":null,"result":"rejected","reason":"rule_violation"}}
        \\{{"ts":{d},"tool":"emetgate_change","gate":"full","result":"committed","reason":null}}
        \\
    , .{ start + 60_000, start + 61_000, start + 7_200_000 });
    try writeFixture(tmp.dir, "work/my.app/.emetgate/events.ndjson", events);
    try writeFixture(tmp.dir, try std.fmt.allocPrint(arena, "work/my.app/.emetgate/receipts/{d:0>20}-00.json", .{@as(u128, @intCast(start + 60_000)) * std.time.ns_per_ms}), "{}");
    try writeFixture(tmp.dir, try std.fmt.allocPrint(arena, "work/my.app/.emetgate/receipts/attached/{d:0>20}-01.json", .{@as(u128, @intCast(start + 62_000)) * std.time.ns_per_ms}), "{}");

    const projects_abs = try std.fs.path.join(arena, &.{ abs, "config", "projects" });
    const project_dir = (try findProjectDir(arena, testing.io, projects_abs, project)).?;
    const upper = try arena.dupe(u8, project);
    for (upper) |*c| c.* = std.ascii.toUpper(c.*);
    try testing.expect((try findProjectDir(arena, testing.io, projects_abs, upper)) != null);
    try testing.expect((try findProjectDir(arena, testing.io, projects_abs, "C:\\nowhere")) == null);

    const gate_log = try loadGate(testing.allocator, arena, testing.io, project);
    const latest = try collect(testing.allocator, arena, testing.io, project_dir, gate_log, .latest);
    try testing.expectEqual(@as(usize, 1), latest.len);
    const s = latest[0];
    try testing.expectEqualStrings("gated-1", s.id);
    try testing.expectEqual(@as(u64, 4), s.turns);
    try testing.expectEqual(@as(u64, 1), s.gate.writes_applied);
    try testing.expectEqual(@as(u64, 1), s.gate.writes_rejected);
    try testing.expectEqual(@as(u64, 1), s.gate.rule_violations);
    try testing.expectEqual(@as(u64, 1), s.gate.tests_run);
    try testing.expectEqual(@as(u64, 2), s.gate.receipts);

    const one = try collect(testing.allocator, arena, testing.io, project_dir, gate_log, .{ .one = "plain" });
    try testing.expectEqualStrings("plain-2", one[0].id);
    try testing.expect(!one[0].gated);
    try testing.expectError(error.SessionNotFound, collect(testing.allocator, arena, testing.io, project_dir, gate_log, .{ .one = "zzz" }));

    const all = try collect(testing.allocator, arena, testing.io, project_dir, gate_log, .all);
    try testing.expectEqual(@as(usize, 2), all.len);
    try testing.expectEqualStrings("gated-1", all[0].id);
    try testing.expectEqualStrings("plain-2", all[1].id);

    var text: Writer.Allocating = .init(testing.allocator);
    defer text.deinit();
    try writeText(&text.writer, s);
    const t = text.written();
    for ([_][]const u8{ "session gated-1 (emetgate tools)", "started           2026-11-11 11:00:00 UTC", "duration          2m 03s", "model turns       4  (claude-opus-5-5 2, some-other-model 1, claude-haiku-4-5-20251001 1)", "cache read        1,000,000", "cost (estimate)   $", "+ 1 turns of unknown models", "tool calls        4: emetgate_read_file 2, Read 1, emetgate_change 1", "rule violations   1", "tests run         1 (0 failed, 2s in tests)", "receipts          2" }) |needle| {
        if (std.mem.indexOf(u8, t, needle) == null) {
            std.debug.print("missing \"{s}\" in:\n{s}\n", .{ needle, t });
            return error.TestExpectedContains;
        }
    }
    try testing.expect(std.mem.indexOf(u8, t, "saving") == null);
    try testing.expect(std.mem.indexOf(u8, t, "saved") == null);

    var table: Writer.Allocating = .init(testing.allocator);
    defer table.deinit();
    try writeTable(&table.writer, all);
    try testing.expect(std.mem.indexOf(u8, table.written(), "gated-1   2026-11-11 11:00") != null);
    try testing.expect(std.mem.indexOf(u8, table.written(), "\ntotal ") != null);

    var json: Writer.Allocating = .init(testing.allocator);
    defer json.deinit();
    try writeJson(&json.writer, all, true);
    const parsed = try std.json.parseFromSlice(Value, testing.allocator, json.written(), .{});
    defer parsed.deinit();
    const sessions = parsed.value.object.get("sessions").?.array.items;
    try testing.expectEqual(@as(usize, 2), sessions.len);
    try testing.expectEqual(@as(i64, 1), sessions[0].object.get("gate").?.object.get("rule_violations").?.integer);
    try testing.expectEqual(@as(i64, 2), sessions[0].object.get("tool_calls").?.object.get("emetgate_read_file").?.integer);
    try testing.expect(sessions[0].object.get("cost_usd_estimate").? == .float);
    try testing.expectEqual(@as(i64, 2), parsed.value.object.get("total").?.object.get("sessions").?.integer);

    var single: Writer.Allocating = .init(testing.allocator);
    defer single.deinit();
    try writeJson(&single.writer, latest, false);
    const one_parsed = try std.json.parseFromSlice(Value, testing.allocator, single.written(), .{});
    defer one_parsed.deinit();
    try testing.expectEqualStrings("gated-1", one_parsed.value.object.get("session").?.string);
    try testing.expect(one_parsed.value.object.get("models").?.array.items[1].object.get("cost_usd_estimate").? == .null);
}
