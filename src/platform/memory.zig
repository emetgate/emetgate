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

pub const Conflict = struct {
    prior: []const u8,
    successors: []const []const u8,
};

pub const Folded = struct {
    latest: std.StringHashMapUnmanaged(Decision),
    active: []const Decision,
    conflicts: []const Conflict,
};

pub const Recall = struct {
    arena: *std.heap.ArenaAllocator,
    decisions: []const Decision,
    conflicts: []const Conflict,

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
    return .{ .arena = arena, .decisions = ledger.folded.active, .conflicts = ledger.folded.conflicts };
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
    if (ledger.folded.conflicts.len != 0) return error.LedgerConflict;
    const compacted = try compactedLedger(arena, ledger.folded);
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
    const bytes = try readLedger(arena, io, paths);
    const keep = tornTailStart(arena, bytes);
    const kept = if (keep) |k| bytes[0..k] else bytes;
    const rows = try parseLedger(arena, kept);
    const folded = try foldRows(arena, rows);
    if (keep) |k| try quarantineTornTail(arena, io, paths, bytes, k);
    return .{ .bytes = kept, .rows = rows, .folded = folded };
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

pub fn tornTailStart(arena: Allocator, bytes: []const u8) ?usize {
    var start: usize = 0;
    while (start < bytes.len) {
        const newline = std.mem.indexOfScalarPos(u8, bytes, start, '\n');
        const end = newline orelse bytes.len;
        const complete = newline != null;
        if (!complete or !lineIsRow(arena, bytes[start..end])) {
            if (end + 1 < bytes.len) return null;
            return start;
        }
        start = end + 1;
    }
    return null;
}

fn lineIsRow(arena: Allocator, line: []const u8) bool {
    if (line.len == 0) return false;
    const decision = std.json.parseFromSliceLeaky(Decision, arena, line, .{}) catch return false;
    validateRow(decision) catch return false;
    return true;
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
    var latest: std.StringHashMapUnmanaged(Decision) = .empty;
    for (rows) |row| {
        const d = row.decision;
        if (d.status != .active) continue;
        const slot = try latest.getOrPut(arena, d.id);
        if (slot.found_existing and !sameDecision(slot.value_ptr.*, d)) return error.LedgerCorrupt;
        slot.value_ptr.* = d;
    }

    var retired: std.StringHashMapUnmanaged(void) = .empty;
    var successors: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
    var heads = latest.valueIterator();
    while (heads.next()) |d| {
        const prior_id = d.supersedes orelse continue;
        if (!latest.contains(prior_id)) return error.LedgerCorrupt;
        try retired.put(arena, prior_id, {});
        const slot = try successors.getOrPut(arena, prior_id);
        if (!slot.found_existing) slot.value_ptr.* = .empty;
        try slot.value_ptr.append(arena, d.id);
    }
    try refuseSupersedeCycles(arena, latest);

    for (rows) |row| {
        const d = row.decision;
        if (d.status != .superseded) continue;
        if (d.supersedes != null) return error.LedgerCorrupt;
        if (!latest.contains(d.id)) return error.LedgerCorrupt;
        try retired.put(arena, d.id, {});
    }

    var active: std.ArrayList(Decision) = .empty;
    var values = latest.valueIterator();
    while (values.next()) |d| {
        if (retired.contains(d.id)) {
            d.status = .superseded;
            continue;
        }
        try active.append(arena, d.*);
    }
    std.mem.sort(Decision, active.items, {}, decisionBefore);

    var conflicts: std.ArrayList(Conflict) = .empty;
    var edges = successors.iterator();
    while (edges.next()) |edge| {
        const ids = edge.value_ptr.items;
        if (ids.len < 2) continue;
        std.mem.sort([]const u8, ids, {}, idBefore);
        try conflicts.append(arena, .{ .prior = edge.key_ptr.*, .successors = ids });
    }
    std.mem.sort(Conflict, conflicts.items, {}, conflictBefore);

    return .{ .latest = latest, .active = try active.toOwnedSlice(arena), .conflicts = try conflicts.toOwnedSlice(arena) };
}

fn refuseSupersedeCycles(arena: Allocator, latest: std.StringHashMapUnmanaged(Decision)) !void {
    var done: std.StringHashMapUnmanaged(void) = .empty;
    var path: std.StringHashMapUnmanaged(void) = .empty;
    var starts = latest.keyIterator();
    while (starts.next()) |start| {
        path.clearRetainingCapacity();
        var cursor: ?[]const u8 = start.*;
        while (cursor) |id| {
            if (done.contains(id)) break;
            if ((try path.getOrPut(arena, id)).found_existing) return error.LedgerCorrupt;
            cursor = if (latest.get(id)) |d| d.supersedes else null;
        }
        var walked = path.keyIterator();
        while (walked.next()) |id| try done.put(arena, id.*, {});
    }
}

fn sameDecision(a: Decision, b: Decision) bool {
    return std.mem.eql(u8, a.id, b.id) and a.scope == b.scope and std.mem.eql(u8, a.text, b.text) and
        a.enforce == b.enforce and sameOptional(a.check, b.check) and a.status == b.status and
        sameOptional(a.supersedes, b.supersedes) and a.ts == b.ts;
}

fn sameOptional(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn idBefore(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn decisionBefore(_: void, a: Decision, b: Decision) bool {
    if (a.ts != b.ts) return a.ts < b.ts;
    return idBefore({}, a.id, b.id);
}

fn conflictBefore(_: void, a: Conflict, b: Conflict) bool {
    return idBefore({}, a.prior, b.prior);
}

pub fn fold(arena: Allocator, rows: []const Row) ![]const Decision {
    return (try foldRows(arena, rows)).active;
}

fn compactedLedger(arena: Allocator, folded: Folded) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    for (folded.active) |decision| {
        var head = decision;
        head.supersedes = null;
        try writeDecision(&out.writer, head);
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
