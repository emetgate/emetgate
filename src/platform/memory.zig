const std = @import("std");
const symbol = @import("../engine/symbol.zig");
const shadow = @import("shadow.zig");
const disk = @import("disk.zig");

const Allocator = std.mem.Allocator;

pub const ledger_name = "ledger.ndjson";
pub const state_name = "state.bin";
pub const max_ledger_bytes = 64 * 1024 * 1024;
pub const max_text_bytes = 16 * 1024;
pub const max_check_bytes = 4 * 1024;
pub const max_id_bytes = 64;

const state_magic = "SYNMEMv1";

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
    state: []const u8,

    fn init(arena: Allocator, root_abs: []const u8) !Paths {
        const workspace = try std.fmt.allocPrint(arena, "{s}\\{s}", .{ root_abs, shadow.workspace_dir });
        return .{
            .workspace = workspace,
            .ledger = try std.fmt.allocPrint(arena, "{s}\\{s}", .{ workspace, ledger_name }),
            .state = try std.fmt.allocPrint(arena, "{s}\\{s}", .{ workspace, state_name }),
        };
    }
};

pub fn remember(gpa: Allocator, io: std.Io, root_abs: []const u8, scope: Scope, text: []const u8, enforce: bool, check: ?[]const u8) ![]u8 {
    try validateInput(text, check);
    const lock = try acquireRepoLock(io, root_abs);
    defer lock.release();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.init(arena, root_abs);

    const ledger_bytes = try readLedger(arena, io, paths.ledger);
    const rows = try parseLedger(arena, ledger_bytes);
    _ = try fold(arena, rows);

    const id = try newId(arena, io, ledger_bytes.len, text);
    try appendRows(arena, io, paths, &.{.{
        .id = id,
        .scope = scope,
        .text = text,
        .enforce = enforce,
        .check = check,
        .status = .active,
        .ts = now(io),
    }});
    try refreshState(arena, gpa, io, paths);
    return gpa.dupe(u8, id);
}

pub fn supersede(gpa: Allocator, io: std.Io, root_abs: []const u8, id: []const u8, scope: Scope, text: []const u8, enforce: bool, check: ?[]const u8) ![]u8 {
    try validateInput(text, check);
    const lock = try acquireRepoLock(io, root_abs);
    defer lock.release();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.init(arena, root_abs);

    const ledger_bytes = try readLedger(arena, io, paths.ledger);
    const rows = try parseLedger(arena, ledger_bytes);
    const prior = try findActive(try fold(arena, rows), id);

    const stamp = now(io);
    const successor_id = try newId(arena, io, ledger_bytes.len, text);
    var tombstone = prior;
    tombstone.status = .superseded;
    tombstone.ts = stamp;
    try appendRows(arena, io, paths, &.{ tombstone, .{
        .id = successor_id,
        .scope = scope,
        .text = text,
        .enforce = enforce,
        .check = check,
        .status = .active,
        .supersedes = prior.id,
        .ts = stamp,
    } });
    try refreshState(arena, gpa, io, paths);
    return gpa.dupe(u8, successor_id);
}

pub fn forget(gpa: Allocator, io: std.Io, root_abs: []const u8, id: []const u8) !void {
    const lock = try acquireRepoLock(io, root_abs);
    defer lock.release();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.init(arena, root_abs);

    const ledger_bytes = try readLedger(arena, io, paths.ledger);
    const rows = try parseLedger(arena, ledger_bytes);
    var tombstone = try findActive(try fold(arena, rows), id);
    tombstone.status = .superseded;
    tombstone.ts = now(io);
    try appendRows(arena, io, paths, &.{tombstone});
    try refreshState(arena, gpa, io, paths);
}

pub fn recall(gpa: Allocator, io: std.Io, root_abs: []const u8) !Recall {
    const lock = try acquireRepoLock(io, root_abs);
    defer lock.release();
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    const paths = try Paths.init(arena.allocator(), root_abs);
    const decisions = try activeDecisions(arena.allocator(), gpa, io, paths);
    return .{ .arena = arena, .decisions = decisions };
}

pub fn compact(gpa: Allocator, io: std.Io, root_abs: []const u8) !void {
    const lock = try acquireRepoLock(io, root_abs);
    defer lock.release();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.init(arena, root_abs);

    const ledger_bytes = try readLedger(arena, io, paths.ledger);
    if (ledger_bytes.len == 0) return;
    const rows = try parseLedger(arena, ledger_bytes);
    _ = try fold(arena, rows);
    const compacted = try compactedLedger(arena, rows);
    if (!std.mem.eql(u8, compacted, ledger_bytes)) {
        try disk.replaceAtomically(gpa, io, paths.ledger, compacted, symbol.hashOf(ledger_bytes));
    }
    try refreshState(arena, gpa, io, paths);
}

fn acquireRepoLock(io: std.Io, root_abs: []const u8) !shadow.Lock {
    return shadow.Lock.acquire(io, root_abs);
}

fn validateInput(text: []const u8, check: ?[]const u8) error{InvalidDecision}!void {
    if (text.len == 0 or text.len > max_text_bytes) return error.InvalidDecision;
    if (check) |c| {
        if (c.len == 0 or c.len > max_check_bytes) return error.InvalidDecision;
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

fn readLedger(arena: Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_ledger_bytes)) catch |err| switch (err) {
        error.FileNotFound => return arena.dupe(u8, ""),
        else => return err,
    };
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
    if (d.text.len == 0 or d.text.len > max_text_bytes) return error.LedgerCorrupt;
    if (d.check) |c| {
        if (c.len == 0 or c.len > max_check_bytes) return error.LedgerCorrupt;
    }
}

pub fn fold(arena: Allocator, rows: []const Row) ![]const Decision {
    var order: std.ArrayList([]const u8) = .empty;
    var latest: std.StringHashMapUnmanaged(Decision) = .empty;
    for (rows) |row| {
        const d = row.decision;
        const existing = latest.get(d.id);
        switch (d.status) {
            .active => {
                if (existing != null) return error.LedgerCorrupt;
                if (d.supersedes) |prior_id| {
                    if (latest.get(prior_id)) |prior| {
                        if (prior.status == .active) return error.LedgerCorrupt;
                    }
                }
                try order.append(arena, d.id);
            },
            .superseded => {
                const current = existing orelse return error.LedgerCorrupt;
                if (current.status != .active) return error.LedgerCorrupt;
            },
        }
        try latest.put(arena, d.id, d);
    }
    var active: std.ArrayList(Decision) = .empty;
    for (order.items) |id| {
        const decision = latest.get(id).?;
        if (decision.status != .active) continue;
        try active.append(arena, decision);
    }
    return active.toOwnedSlice(arena);
}

fn compactedLedger(arena: Allocator, rows: []const Row) ![]u8 {
    var last_index: std.StringHashMapUnmanaged(usize) = .empty;
    for (rows, 0..) |row, index| try last_index.put(arena, row.decision.id, index);
    var out: std.ArrayList(u8) = .empty;
    for (rows, 0..) |row, index| {
        if (row.decision.status == .superseded) continue;
        if (last_index.get(row.decision.id).? != index) continue;
        try out.appendSlice(arena, row.line);
        try out.append(arena, '\n');
    }
    return out.toOwnedSlice(arena);
}

fn writeDecision(w: *std.Io.Writer, d: Decision) !void {
    var js: std.json.Stringify = .{ .writer = w };
    try js.write(d);
}

fn appendRows(arena: Allocator, io: std.Io, paths: Paths, rows: []const Decision) !void {
    var buffer: std.Io.Writer.Allocating = .init(arena);
    for (rows) |row| {
        try writeDecision(&buffer.writer, row);
        try buffer.writer.writeByte('\n');
    }
    const line = buffer.written();
    try std.Io.Dir.cwd().createDirPath(io, paths.workspace);
    const file = try std.Io.Dir.createFileAbsolute(io, paths.ledger, .{ .read = true, .truncate = false });
    defer file.close(io);
    const end = try file.length(io);
    if (end + line.len > max_ledger_bytes) return error.LedgerTooLarge;
    try file.writePositionalAll(io, line, try file.length(io));
    try file.sync(io);
}

fn activeDecisions(arena: Allocator, gpa: Allocator, io: std.Io, paths: Paths) ![]const Decision {
    const ledger_bytes = try readLedger(arena, io, paths.ledger);
    const ledger_hash = symbol.hashOf(ledger_bytes);
    const state_bytes = try readState(arena, io, paths.state);
    if (state_bytes) |bytes| {
        if (decodeState(arena, bytes, ledger_hash)) |decisions| return decisions;
    }
    const decisions = try fold(arena, try parseLedger(arena, ledger_bytes));
    try writeState(gpa, io, paths.state, state_bytes, try encodeState(arena, ledger_hash, decisions));
    return decisions;
}

fn refreshState(arena: Allocator, gpa: Allocator, io: std.Io, paths: Paths) !void {
    const ledger_bytes = try readLedger(arena, io, paths.ledger);
    const decisions = try fold(arena, try parseLedger(arena, ledger_bytes));
    const encoded = try encodeState(arena, symbol.hashOf(ledger_bytes), decisions);
    const existing = try readState(arena, io, paths.state);
    if (existing) |bytes| {
        if (std.mem.eql(u8, bytes, encoded)) return;
    }
    try writeState(gpa, io, paths.state, existing, encoded);
}

fn readState(arena: Allocator, io: std.Io, path: []const u8) !?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_ledger_bytes)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
}

fn writeState(gpa: Allocator, io: std.Io, path: []const u8, existing: ?[]const u8, encoded: []const u8) !void {
    if (existing) |bytes| {
        try disk.replaceAtomically(gpa, io, path, encoded, symbol.hashOf(bytes));
    } else {
        try disk.writeDurably(io, path, encoded);
    }
}

pub fn encodeState(arena: Allocator, ledger_hash: symbol.Hash, decisions: []const Decision) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll(state_magic);
    try w.writeAll(&ledger_hash);
    var count: [4]u8 = undefined;
    std.mem.writeInt(u32, &count, @intCast(decisions.len), .little);
    try w.writeAll(&count);
    for (decisions) |d| {
        var record: std.Io.Writer.Allocating = .init(arena);
        try writeDecision(&record.writer, d);
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(record.written().len), .little);
        try w.writeAll(&len);
        try w.writeAll(record.written());
    }
    return out.written();
}

pub fn decodeState(arena: Allocator, bytes: []const u8, ledger_hash: symbol.Hash) ?[]const Decision {
    const header_len = state_magic.len + @sizeOf(symbol.Hash) + 4;
    if (bytes.len < header_len) return null;
    if (!std.mem.eql(u8, bytes[0..state_magic.len], state_magic)) return null;
    const stored_hash = bytes[state_magic.len..][0..@sizeOf(symbol.Hash)];
    if (!std.mem.eql(u8, stored_hash, &ledger_hash)) return null;
    var pos: usize = state_magic.len + @sizeOf(symbol.Hash);
    const count = std.mem.readInt(u32, bytes[pos..][0..4], .little);
    pos += 4;
    if (count > bytes.len) return null;
    const decisions = arena.alloc(Decision, count) catch return null;
    for (decisions) |*d| {
        if (bytes.len - pos < 4) return null;
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .little);
        pos += 4;
        if (len > bytes.len - pos) return null;
        d.* = std.json.parseFromSliceLeaky(Decision, arena, bytes[pos..][0..len], .{}) catch return null;
        validateRow(d.*) catch return null;
        pos += len;
    }
    if (pos != bytes.len) return null;
    return decisions;
}
