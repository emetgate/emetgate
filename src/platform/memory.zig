const std = @import("std");
const symbol = @import("../engine/symbol.zig");
const shadow = @import("shadow.zig");
const disk = @import("disk.zig");

const Allocator = std.mem.Allocator;

pub const ledger_name = "ledger.ndjson";
pub const lock_name = "memory.lock";
pub const sidecar_prefix = ledger_name ++ ".synapse-";
pub const torn_prefix = ledger_name ++ ".torn-";
pub const max_ledger_bytes = 64 * 1024 * 1024;
pub const max_text_bytes = 16 * 1024;
pub const max_check_bytes = 4 * 1024;
pub const max_id_bytes = 64;

pub const Scope = enum { global, project, file, symbol };
pub const Status = enum { active, superseded };

pub const Decision = struct {
    id: []const u8,
    scope: Scope,
    text: []const u8,
    enforce: bool,
    check: ?[]const u8 = null,
    status: Status,
    supersedes: ?[]const u8 = null,
    ts: i64,
};

pub const Row = struct {
    decision: Decision,
    line: []const u8,
};

pub const Folded = struct {
    latest: std.StringHashMapUnmanaged(Decision),
    active: []const Decision,
};

pub const Recall = struct {
    arena: *std.heap.ArenaAllocator,
    decisions: []const Decision,

    pub fn deinit(self: Recall) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self.arena);
    }
};

const Paths = struct {
    workspace: []const u8,
    ledger: []const u8,
    lock: []const u8,

    fn init(arena: Allocator, root_abs: []const u8) !Paths {
        const workspace = try std.fmt.allocPrint(arena, "{s}\\{s}", .{ root_abs, shadow.workspace_dir });
        return .{
            .workspace = workspace,
            .ledger = try std.fmt.allocPrint(arena, "{s}\\{s}", .{ workspace, ledger_name }),
            .lock = try std.fmt.allocPrint(arena, "{s}\\{s}", .{ workspace, lock_name }),
        };
    }
};

const Loaded = struct {
    bytes: []const u8,
    rows: []const Row,
    folded: Folded,
};

pub fn remember(gpa: Allocator, io: std.Io, root_abs: []const u8, scope: Scope, text: []const u8, enforce: bool, check: ?[]const u8) ![]u8 {
    try validateInput(text, check);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.init(arena, root_abs);
    const lock = try acquireMemoryLock(io, paths);
    defer lock.release();

    const ledger = try loadLedger(arena, io, paths);
    const id = try newId(arena, io, ledger.bytes.len, text);
    try appendRow(arena, io, paths, .{
        .id = id,
        .scope = scope,
        .text = text,
        .enforce = enforce,
        .check = check,
        .status = .active,
        .ts = now(io),
    });
    return gpa.dupe(u8, id);
}

pub fn supersede(gpa: Allocator, io: std.Io, root_abs: []const u8, id: []const u8, scope: Scope, text: []const u8, enforce: bool, check: ?[]const u8) ![]u8 {
    try validateInput(text, check);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.init(arena, root_abs);
    const lock = try acquireMemoryLock(io, paths);
    defer lock.release();

    const ledger = try loadLedger(arena, io, paths);
    const prior = try findActive(ledger.folded.active, id);
    const successor_id = try newId(arena, io, ledger.bytes.len, text);
    try appendRow(arena, io, paths, .{
        .id = successor_id,
        .scope = scope,
        .text = text,
        .enforce = enforce,
        .check = check,
        .status = .active,
        .supersedes = prior.id,
        .ts = now(io),
    });
    return gpa.dupe(u8, successor_id);
}

pub fn forget(gpa: Allocator, io: std.Io, root_abs: []const u8, id: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.init(arena, root_abs);
    const lock = try acquireMemoryLock(io, paths);
    defer lock.release();

    const ledger = try loadLedger(arena, io, paths);
    var tombstone = try findActive(ledger.folded.active, id);
    tombstone.status = .superseded;
    tombstone.supersedes = null;
    tombstone.ts = now(io);
    try appendRow(arena, io, paths, tombstone);
}

pub fn recall(gpa: Allocator, io: std.Io, root_abs: []const u8) !Recall {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    const paths = try Paths.init(arena.allocator(), root_abs);
    const lock = try acquireMemoryLock(io, paths);
    defer lock.release();

    const ledger = try loadLedger(arena.allocator(), io, paths);
    return .{ .arena = arena, .decisions = ledger.folded.active };
}

pub fn compact(gpa: Allocator, io: std.Io, root_abs: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.init(arena, root_abs);
    const lock = try acquireMemoryLock(io, paths);
    defer lock.release();

    const ledger = try loadLedger(arena, io, paths);
    if (ledger.bytes.len == 0) return;
    const compacted = try compactedLedger(arena, ledger.rows, ledger.folded);
    if (std.mem.eql(u8, compacted, ledger.bytes)) return;
    try disk.replaceByRename(gpa, io, paths.ledger, compacted, symbol.hashOf(ledger.bytes));
}

fn acquireMemoryLock(io: std.Io, paths: Paths) !shadow.FileLock {
    try std.Io.Dir.cwd().createDirPath(io, paths.workspace);
    return shadow.FileLock.acquire(paths.lock) catch |err| switch (err) {
        error.Busy => error.MemoryBusy,
        else => err,
    };
}

fn validateInput(text: []const u8, check: ?[]const u8) error{InvalidDecision}!void {
    if (text.len == 0 or text.len > max_text_bytes) return error.InvalidDecision;
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidDecision;
    if (check) |c| {
        if (c.len == 0 or c.len > max_check_bytes) return error.InvalidDecision;
        if (!std.unicode.utf8ValidateSlice(c)) return error.InvalidDecision;
    }
}

fn findActive(active: []const Decision, id: []const u8) error{DecisionNotActive}!Decision {
    for (active) |d| {
        if (d.status == .active and std.mem.eql(u8, d.id, id)) return d;
    }
    return error.DecisionNotActive;
}

fn now(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

fn newId(arena: Allocator, io: std.Io, ledger_len: usize, text: []const u8) ![]const u8 {
    var random: [8]u8 = undefined;
    io.random(&random);
    const seed = try std.fmt.allocPrint(arena, "{d}\x00{s}\x00{s}", .{ ledger_len, &random, text });
    const digest = symbol.hashOf(seed);
    const hex = std.fmt.bytesToHex(digest[0..8].*, .lower);
    return std.fmt.allocPrint(arena, "m{s}", .{&hex});
}

fn loadLedger(arena: Allocator, io: std.Io, paths: Paths) !Loaded {
    var bytes = try readLedger(arena, io, paths);
    if (tornTailStart(bytes)) |keep| {
        try quarantineTornTail(arena, io, paths, bytes, keep);
        bytes = bytes[0..keep];
    }
    const rows = try parseLedger(arena, bytes);
    return .{ .bytes = bytes, .rows = rows, .folded = try foldRows(arena, rows) };
}

fn readLedger(arena: Allocator, io: std.Io, paths: Paths) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, paths.ledger, arena, .limited(max_ledger_bytes)) catch |err| switch (err) {
        error.FileNotFound => {
            if (try hasLedgerSidecars(io, paths)) return error.LedgerMissingWithSidecars;
            return arena.dupe(u8, "");
        },
        else => return err,
    };
}

fn hasLedgerSidecars(io: std.Io, paths: Paths) !bool {
    var dir = std.Io.Dir.openDirAbsolute(io, paths.workspace, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, sidecar_prefix)) return true;
    }
    return false;
}

pub fn tornTailStart(bytes: []const u8) ?usize {
    if (bytes.len == 0) return null;
    if (bytes[bytes.len - 1] != '\n') {
        return if (std.mem.lastIndexOfScalar(u8, bytes, '\n')) |nl| nl + 1 else 0;
    }
    const body = bytes[0 .. bytes.len - 1];
    const start = if (std.mem.lastIndexOfScalar(u8, body, '\n')) |nl| nl + 1 else 0;
    const last = body[start..];
    if (last.len != 0 and std.mem.allEqual(u8, last, 0)) return start;
    return null;
}

fn quarantineTornTail(arena: Allocator, io: std.Io, paths: Paths, bytes: []const u8, keep: usize) !void {
    const torn_path = try std.fmt.allocPrint(arena, "{s}\\{s}{d}", .{ paths.workspace, torn_prefix, now(io) });
    try disk.writeDurably(io, torn_path, bytes[keep..]);
    const file = try std.Io.Dir.createFileAbsolute(io, paths.ledger, .{ .read = true, .truncate = false });
    defer file.close(io);
    try file.setLength(io, keep);
    try file.sync(io);
}

pub fn parseLedger(arena: Allocator, bytes: []const u8) ![]const Row {
    if (bytes.len != 0 and bytes[bytes.len - 1] != '\n') return error.LedgerCorrupt;
    var rows: std.ArrayList(Row) = .empty;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) {
            if (lines.peek() == null) break;
            return error.LedgerCorrupt;
        }
        const decision = std.json.parseFromSliceLeaky(Decision, arena, line, .{}) catch return error.LedgerCorrupt;
        try validateRow(decision);
        try rows.append(arena, .{ .decision = decision, .line = line });
    }
    return rows.toOwnedSlice(arena);
}

fn validateRow(d: Decision) error{LedgerCorrupt}!void {
    if (d.id.len == 0 or d.id.len > max_id_bytes) return error.LedgerCorrupt;
    for (d.id) |c| {
        if (c < 0x21 or c > 0x7e) return error.LedgerCorrupt;
    }
    if (d.text.len == 0 or d.text.len > max_text_bytes) return error.LedgerCorrupt;
    if (!std.unicode.utf8ValidateSlice(d.text)) return error.LedgerCorrupt;
    if (d.check) |c| {
        if (c.len == 0 or c.len > max_check_bytes) return error.LedgerCorrupt;
        if (!std.unicode.utf8ValidateSlice(c)) return error.LedgerCorrupt;
    }
}

pub fn foldRows(arena: Allocator, rows: []const Row) !Folded {
    var order: std.ArrayList([]const u8) = .empty;
    var latest: std.StringHashMapUnmanaged(Decision) = .empty;
    for (rows) |row| {
        const d = row.decision;
        switch (d.status) {
            .active => {
                if (latest.get(d.id) != null) return error.LedgerCorrupt;
                if (d.supersedes) |prior_id| {
                    const prior = latest.getPtr(prior_id) orelse return error.LedgerCorrupt;
                    if (prior.status != .active) return error.LedgerCorrupt;
                    prior.status = .superseded;
                }
                try order.append(arena, d.id);
                try latest.put(arena, d.id, d);
            },
            .superseded => {
                if (d.supersedes != null) return error.LedgerCorrupt;
                const current = latest.getPtr(d.id) orelse return error.LedgerCorrupt;
                if (current.status != .active) return error.LedgerCorrupt;
                current.status = .superseded;
            },
        }
    }
    var active: std.ArrayList(Decision) = .empty;
    for (order.items) |id| {
        const decision = latest.get(id).?;
        if (decision.status != .active) continue;
        try active.append(arena, decision);
    }
    return .{ .latest = latest, .active = try active.toOwnedSlice(arena) };
}

pub fn fold(arena: Allocator, rows: []const Row) ![]const Decision {
    return (try foldRows(arena, rows)).active;
}

fn compactedLedger(arena: Allocator, rows: []const Row, folded: Folded) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    for (rows) |row| {
        if (row.decision.status == .superseded) continue;
        if (folded.latest.get(row.decision.id).?.status != .active) continue;
        if (row.decision.supersedes == null) {
            try out.writer.writeAll(row.line);
        } else {
            var head = row.decision;
            head.supersedes = null;
            try writeDecision(&out.writer, head);
        }
        try out.writer.writeByte('\n');
    }
    return out.written();
}

fn writeDecision(w: *std.Io.Writer, d: Decision) !void {
    var js: std.json.Stringify = .{ .writer = w };
    try js.write(d);
}

fn appendRow(arena: Allocator, io: std.Io, paths: Paths, row: Decision) !void {
    var buffer: std.Io.Writer.Allocating = .init(arena);
    try writeDecision(&buffer.writer, row);
    try buffer.writer.writeByte('\n');
    const line = buffer.written();
    const file = try std.Io.Dir.createFileAbsolute(io, paths.ledger, .{ .read = true, .truncate = false });
    defer file.close(io);
    const end = try file.length(io);
    if (end + line.len >= max_ledger_bytes) return error.LedgerTooLarge;
    try file.writePositionalAll(io, line, end);
    try file.sync(io);
}
