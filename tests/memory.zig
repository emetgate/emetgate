const std = @import("std");
const builtin = @import("builtin");
const memory = @import("../src/platform/memory.zig");
const shadow = @import("../src/platform/shadow.zig");

const testing = std.testing;

const a_active = "{\"id\":\"ma\",\"scope\":\"project\",\"text\":\"use Money for amounts\",\"enforce\":true,\"check\":null,\"status\":\"active\",\"supersedes\":null,\"ts\":1}\n";
const b_active = "{\"id\":\"mb\",\"scope\":\"file\",\"text\":\"no comments\",\"enforce\":false,\"check\":\"no_comment\",\"status\":\"active\",\"supersedes\":null,\"ts\":2}\n";
const a_forgotten = "{\"id\":\"ma\",\"scope\":\"project\",\"text\":\"use Money for amounts\",\"enforce\":true,\"check\":null,\"status\":\"superseded\",\"supersedes\":null,\"ts\":3}\n";
const c_supersedes_a = "{\"id\":\"mc\",\"scope\":\"project\",\"text\":\"use Money and Currency\",\"enforce\":true,\"check\":null,\"status\":\"active\",\"supersedes\":\"ma\",\"ts\":4}\n";

const Store = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,

    fn init() !Store {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        return .{ .tmp = tmp, .root = root };
    }

    fn deinit(self: *Store) void {
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn path(name: []const u8) ![]u8 {
        return std.fmt.allocPrint(testing.allocator, ".emetgate/{s}", .{name});
    }

    fn put(self: *Store, name: []const u8, bytes: []const u8) !void {
        try self.tmp.dir.createDirPath(testing.io, ".emetgate");
        const p = try path(name);
        defer testing.allocator.free(p);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = p, .data = bytes });
    }

    fn get(self: *Store, name: []const u8) ![]u8 {
        const p = try path(name);
        defer testing.allocator.free(p);
        return self.tmp.dir.readFileAlloc(testing.io, p, testing.allocator, .unlimited);
    }

    fn exists(self: *Store, name: []const u8) bool {
        const p = path(name) catch return false;
        defer testing.allocator.free(p);
        self.tmp.dir.access(testing.io, p, .{}) catch return false;
        return true;
    }
};

fn expectIds(decisions: []const memory.Decision, ids: []const []const u8) !void {
    try testing.expectEqual(ids.len, decisions.len);
    for (ids, decisions) |want, got| try testing.expectEqualStrings(want, got.id);
}

test "memory: recall returns only active decisions" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var store = try Store.init();
    defer store.deinit();
    try store.put(memory.ledger_name, a_active ++ b_active ++ a_forgotten);

    const recalled = try memory.recall(testing.allocator, testing.io, store.root);
    defer recalled.deinit();
    try expectIds(recalled.decisions, &.{"mb"});
}

test "memory: operations append rows and never rewrite earlier ledger bytes" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var store = try Store.init();
    defer store.deinit();

    const first = try memory.remember(testing.allocator, testing.io, store.root, .project, "first", true, null, null);
    defer testing.allocator.free(first);
    const after_first = try store.get(memory.ledger_name);
    defer testing.allocator.free(after_first);

    const second = try memory.remember(testing.allocator, testing.io, store.root, .file, "second", false, "no_comment", null);
    defer testing.allocator.free(second);
    const after_second = try store.get(memory.ledger_name);
    defer testing.allocator.free(after_second);

    const replacement = try memory.supersede(testing.allocator, testing.io, store.root, first, .project, "first v2", true, null, null);
    defer testing.allocator.free(replacement);
    try memory.forget(testing.allocator, testing.io, store.root, second);
    const final = try store.get(memory.ledger_name);
    defer testing.allocator.free(final);

    try testing.expect(std.mem.startsWith(u8, after_second, after_first));
    try testing.expect(std.mem.startsWith(u8, final, after_second));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rows = try memory.parseLedger(arena.allocator(), final);
    try testing.expectEqual(@as(usize, 4), rows.len);
    try testing.expectEqualStrings(replacement, rows[2].decision.id);
    try testing.expectEqual(memory.Status.active, rows[2].decision.status);
    try testing.expectEqualStrings(first, rows[2].decision.supersedes.?);
    try testing.expectEqualStrings(second, rows[3].decision.id);
    try testing.expectEqual(memory.Status.superseded, rows[3].decision.status);
}

test "memory: a corrupt ledger line before the end is refused, not skipped" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const bad = [_][]const u8{
        a_active ++ "{not json\n" ++ b_active,
        a_active ++ "{\"id\":\"mx\",\"scope\":\"team\",\"text\":\"t\",\"enforce\":true,\"check\":null,\"status\":\"active\",\"supersedes\":null,\"ts\":9}\n" ++ b_active,
        a_active ++ "\n" ++ b_active,
        a_forgotten,
    };
    for (bad) |ledger| {
        var store = try Store.init();
        defer store.deinit();
        try store.put(memory.ledger_name, ledger);
        try testing.expectError(error.LedgerCorrupt, memory.recall(testing.allocator, testing.io, store.root));
        try testing.expectError(error.LedgerCorrupt, memory.remember(testing.allocator, testing.io, store.root, .global, "x", false, null, null));
        const after = try store.get(memory.ledger_name);
        defer testing.allocator.free(after);
        try testing.expectEqualStrings(ledger, after);
    }
}

test "memory: supersede retires the prior decision in the same row" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var store = try Store.init();
    defer store.deinit();
    try store.put(memory.ledger_name, a_active ++ c_supersedes_a);

    try testing.expectError(error.DecisionNotActive, memory.forget(testing.allocator, testing.io, store.root, "ma"));
    try testing.expectError(error.DecisionNotActive, memory.supersede(testing.allocator, testing.io, store.root, "ma", .project, "again", true, null, null));
    const after = try store.get(memory.ledger_name);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(a_active ++ c_supersedes_a, after);
}

test "memory: compact drops retired history and never an active decision" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var store = try Store.init();
    defer store.deinit();
    try store.put(memory.ledger_name, a_active ++ b_active ++ a_forgotten);

    try memory.compact(testing.allocator, testing.io, store.root);
    const compacted = try store.get(memory.ledger_name);
    defer testing.allocator.free(compacted);
    try testing.expectEqualStrings(b_active, compacted);

    const recalled = try memory.recall(testing.allocator, testing.io, store.root);
    defer recalled.deinit();
    try expectIds(recalled.decisions, &.{"mb"});
}

test "memory: compact collapses a supersede chain without leaving a dangling pointer" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var store = try Store.init();
    defer store.deinit();
    try store.put(memory.ledger_name, a_active ++ c_supersedes_a);

    try memory.compact(testing.allocator, testing.io, store.root);
    const recalled = try memory.recall(testing.allocator, testing.io, store.root);
    defer recalled.deinit();

    const compacted = try store.get(memory.ledger_name);
    defer testing.allocator.free(compacted);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for (try memory.parseLedger(arena.allocator(), compacted)) |row| try testing.expect(row.decision.supersedes == null);
}

test "memory: a held memory lock blocks every operation and the repo lock does not" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var store = try Store.init();
    defer store.deinit();
    try store.tmp.dir.createDirPath(testing.io, ".emetgate");
    const lock_path = try std.fmt.allocPrint(testing.allocator, "{s}\\.emetgate\\{s}", .{ store.root, memory.lock_name });
    defer testing.allocator.free(lock_path);

    const held = try shadow.FileLock.acquire(lock_path);
    try testing.expectError(error.MemoryBusy, memory.remember(testing.allocator, testing.io, store.root, .global, "blocked", false, null, null));
    try testing.expectError(error.MemoryBusy, memory.recall(testing.allocator, testing.io, store.root));
    try testing.expectError(error.MemoryBusy, memory.compact(testing.allocator, testing.io, store.root));
    held.release();

    const repo = try shadow.Lock.acquire(testing.io, store.root);
    defer repo.release();
    const id = try memory.remember(testing.allocator, testing.io, store.root, .global, "repo lock is separate", false, null, null);
    defer testing.allocator.free(id);
}

const Branch = struct {
    tag: u8,
    next: usize = 0,
    active: std.ArrayList([]const u8) = .empty,
    rows: std.ArrayList(memory.Decision) = .empty,

    fn fork(self: Branch, arena: std.mem.Allocator, tag: u8) !Branch {
        var child: Branch = .{ .tag = tag };
        try child.active.appendSlice(arena, self.active.items);
        return child;
    }

    fn run(self: *Branch, arena: std.mem.Allocator, random: std.Random, clock: *i64, ops: usize) !void {
        for (0..ops) |_| {
            clock.* += 1;
            const pick = random.uintLessThan(u8, 3);
            if (self.active.items.len == 0 or pick == 0) {
                try self.append(arena, clock.*, null);
                continue;
            }
            const prior = self.active.swapRemove(random.uintLessThan(usize, self.active.items.len));
            if (pick == 1) {
                try self.append(arena, clock.*, prior);
            } else {
                try self.rows.append(arena, .{ .id = prior, .scope = .project, .text = prior, .enforce = false, .status = .superseded, .ts = clock.* });
            }
        }
    }

    fn append(self: *Branch, arena: std.mem.Allocator, ts: i64, supersedes: ?[]const u8) !void {
        const id = try std.fmt.allocPrint(arena, "m{c}{d}", .{ self.tag, self.next });
        self.next += 1;
        try self.rows.append(arena, .{ .id = id, .scope = .project, .text = id, .enforce = false, .status = .active, .supersedes = supersedes, .ts = ts });
        try self.active.append(arena, id);
    }
};

fn renderLines(arena: std.mem.Allocator, rows: []const memory.Decision) ![]const []const u8 {
    const lines = try arena.alloc([]const u8, rows.len);
    for (rows, lines) |row, *line| {
        const body = try std.json.Stringify.valueAlloc(arena, row, .{});
        line.* = try std.mem.concat(arena, u8, &.{ body, "\n" });
    }
    return lines;
}

fn foldSummary(arena: std.mem.Allocator, lines: []const []const u8) ![]const u8 {
    const bytes = try std.mem.concat(arena, u8, lines);
    const folded = try memory.foldRows(arena, try memory.parseLedger(arena, bytes));
    var out: std.Io.Writer.Allocating = .init(arena);
    for (folded.active) |d| try out.writer.print("{s} ", .{d.id});
    try out.writer.writeAll("|");
    for (folded.conflicts) |c| {
        try out.writer.print(" {s}>", .{c.prior});
        for (c.successors) |id| try out.writer.print("{s},", .{id});
    }
    return out.written();
}

fn oracleSummary(arena: std.mem.Allocator, rows: []const memory.Decision) ![]const u8 {
    var retired: std.StringHashMapUnmanaged(void) = .empty;
    var successors: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
    for (rows) |row| {
        if (row.status == .superseded) {
            try retired.put(arena, row.id, {});
        } else if (row.supersedes) |prior| {
            try retired.put(arena, prior, {});
            const slot = try successors.getOrPut(arena, prior);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            try slot.value_ptr.append(arena, row.id);
        }
    }
    var out: std.Io.Writer.Allocating = .init(arena);
    for (rows) |row| {
        if (row.status == .active and !retired.contains(row.id)) try out.writer.print("{s} ", .{row.id});
    }
    try out.writer.writeAll("|");
    var priors: std.ArrayList([]const u8) = .empty;
    var it = successors.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.items.len > 1) try priors.append(arena, entry.key_ptr.*);
    }
    std.mem.sort([]const u8, priors.items, {}, lessThanString);
    for (priors.items) |prior| {
        const ids = successors.get(prior).?.items;
        std.mem.sort([]const u8, ids, {}, lessThanString);
        try out.writer.print(" {s}>", .{prior});
        for (ids) |id| try out.writer.print("{s},", .{id});
    }
    return out.written();
}

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

test "memory: fold converges for every merge order, permutation and duplication of branch histories" {
    var conflicts_seen: usize = 0;
    var seed: u64 = 0;
    while (seed < 300) : (seed += 1) {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        var clock: i64 = 0;

        var base: Branch = .{ .tag = 'o' };
        try base.run(arena, random, &clock, random.uintLessThan(usize, 8));
        var left = try base.fork(arena, 'a');
        var right = try base.fork(arena, 'b');
        try left.run(arena, random, &clock, 1 + random.uintLessThan(usize, 8));
        try right.run(arena, random, &clock, 1 + random.uintLessThan(usize, 8));

        const left_first = try std.mem.concat(arena, memory.Decision, &.{ base.rows.items, left.rows.items, right.rows.items });
        const right_first = try std.mem.concat(arena, memory.Decision, &.{ base.rows.items, right.rows.items, left.rows.items });
        const want = try oracleSummary(arena, left_first);
        if (std.mem.indexOfScalar(u8, want, '>') != null) conflicts_seen += 1;

        const lines = try renderLines(arena, left_first);
        try testing.expectEqualStrings(want, try foldSummary(arena, lines));
        try testing.expectEqualStrings(want, try foldSummary(arena, try renderLines(arena, right_first)));

        for (0..4) |_| {
            var mixed: std.ArrayList([]const u8) = .empty;
            try mixed.appendSlice(arena, lines);
            for (lines) |line| {
                if (random.boolean()) try mixed.append(arena, line);
            }
            random.shuffle([]const u8, mixed.items);
            try testing.expectEqualStrings(want, try foldSummary(arena, mixed.items));
        }
    }
    try testing.expect(conflicts_seen > 0);
}

test "memory: recall folds the ledger and never creates state.bin" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var store = try Store.init();
    defer store.deinit();
    try store.put(memory.ledger_name, a_active ++ b_active ++ a_forgotten);

    const recalled = try memory.recall(testing.allocator, testing.io, store.root);
    recalled.deinit();
    try memory.compact(testing.allocator, testing.io, store.root);
    try testing.expect(!store.exists("state.bin"));
}

test "where: a ledger row written before where existed reads back with where null" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var store = try Store.init();
    defer store.deinit();
    try store.put(memory.ledger_name, a_active ++ b_active);

    const recalled = try memory.recall(testing.allocator, testing.io, store.root);
    defer recalled.deinit();
    try testing.expectEqual(@as(usize, 2), recalled.decisions.len);
    for (recalled.decisions) |d| try testing.expect(d.where == null);
}

test "where: remember and supersede store where, and an unscoped row carries no where field" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var store = try Store.init();
    defer store.deinit();

    const plain = try memory.remember(testing.allocator, testing.io, store.root, .project, "plain", true, "no_comment", null);
    defer testing.allocator.free(plain);
    const scoped = try memory.remember(testing.allocator, testing.io, store.root, .file, "queue never scrapes", true, "forbid:resolveAndScrape", "src/queue.js");
    defer testing.allocator.free(scoped);
    const moved = try memory.supersede(testing.allocator, testing.io, store.root, scoped, .symbol, "only in f", true, "forbid:x", "src/x.js#f");
    defer testing.allocator.free(moved);

    const bytes = try store.get(memory.ledger_name);
    defer testing.allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    try testing.expect(std.mem.indexOf(u8, lines.next().?, "where") == null);
    try testing.expect(std.mem.indexOf(u8, lines.next().?, "\"where\":\"src/queue.js\"") != null);

    const recalled = try memory.recall(testing.allocator, testing.io, store.root);
    defer recalled.deinit();
    try expectIds(recalled.decisions, &.{ plain, moved });
    try testing.expectEqualStrings("src/x.js#f", recalled.decisions[1].where.?);
}

test "where: remember and supersede refuse an invalid where by name and write nothing" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var store = try Store.init();
    defer store.deinit();
    const id = try memory.remember(testing.allocator, testing.io, store.root, .project, "base", true, "no_comment", null);
    defer testing.allocator.free(id);
    const before = try store.get(memory.ledger_name);
    defer testing.allocator.free(before);

    const cases = [_]struct { where: []const u8, err: anyerror }{
        .{ .where = "C:/Users/x.js", .err = error.WhereAbsolute },
        .{ .where = "/abs.js", .err = error.WhereAbsolute },
        .{ .where = "src/../x.js", .err = error.WhereParentSegment },
        .{ .where = ".git/hooks/", .err = error.WhereInternal },
        .{ .where = ".emetgate/ledger.ndjson", .err = error.WhereInternal },
        .{ .where = "src/*.js", .err = error.WhereGlob },
        .{ .where = "src/**/", .err = error.WhereGlob },
        .{ .where = "", .err = error.WhereEmpty },
    };
    for (cases) |c| {
        try testing.expectError(c.err, memory.remember(testing.allocator, testing.io, store.root, .file, "x", true, "no_comment", c.where));
        try testing.expectError(c.err, memory.supersede(testing.allocator, testing.io, store.root, id, .file, "x", true, "no_comment", c.where));
    }
    const after = try store.get(memory.ledger_name);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
}

test "where: a ledger row carrying an invalid where is corrupt" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const row = "{\"id\":\"mw\",\"scope\":\"file\",\"text\":\"t\",\"enforce\":true,\"check\":null,\"status\":\"active\",\"supersedes\":null,\"ts\":1,\"where\":\"../x.js\"}\n";
    try testing.expectError(error.LedgerCorrupt, memory.parseLedger(arena.allocator(), row));
}

test "where: two rows for one id that differ only in where are corrupt" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scoped = "{\"id\":\"ma\",\"scope\":\"project\",\"text\":\"use Money for amounts\",\"enforce\":true,\"check\":null,\"status\":\"active\",\"supersedes\":null,\"ts\":1,\"where\":\"src/\"}\n";
    const rows = try memory.parseLedger(arena.allocator(), a_active ++ scoped);
    try testing.expectError(error.LedgerCorrupt, memory.foldRows(arena.allocator(), rows));
}

fn expectExclusionRefused(where: []const u8, err: anyerror) !void {
    var store = try Store.init();
    defer store.deinit();
    const id = try memory.remember(testing.allocator, testing.io, store.root, .project, "base", true, "no_comment", null);
    defer testing.allocator.free(id);
    const before = try store.get(memory.ledger_name);
    defer testing.allocator.free(before);
    try testing.expectError(err, memory.remember(testing.allocator, testing.io, store.root, .file, "x", true, "no_comment", where));
    try testing.expectError(err, memory.supersede(testing.allocator, testing.io, store.root, id, .file, "x", true, "no_comment", where));
    const after = try store.get(memory.ledger_name);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
}

test "where: remember and supersede refuse an empty exclusion" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try expectExclusionRefused("src/ !", error.WhereExclusionEmpty);
}

test "where: remember and supersede refuse an exclusion with two stars" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try expectExclusionRefused("src/ !**.ts", error.WhereExclusionGlob);
}

test "where: remember and supersede refuse an exclusion whose star is not first" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try expectExclusionRefused("src/ !a*.ts", error.WhereExclusionGlob);
}

test "where: remember and supersede refuse an exclusion with another glob character" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try expectExclusionRefused("src/ !x?.ts", error.WhereExclusionGlob);
}

test "where: remember and supersede refuse an exclusion with a parent segment" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try expectExclusionRefused("src/ !../x/", error.WhereExclusionParentSegment);
}

test "where: remember and supersede refuse an absolute exclusion" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try expectExclusionRefused("src/ !/etc/", error.WhereExclusionAbsolute);
    try expectExclusionRefused("src/ !C:/x/", error.WhereExclusionAbsolute);
}

test "where: remember and supersede refuse a malformed exclusion" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try expectExclusionRefused("src/ !*", error.WhereExclusionMalformed);
    try expectExclusionRefused("src/ !a//b/", error.WhereExclusionMalformed);
}

test "where: remember and supersede refuse more exclusions than the limit" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try expectExclusionRefused("src/" ++ " !a/" ** 17, error.WhereTooManyExclusions);
}

test "where: a where with exclusions is remembered and recalled verbatim" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var store = try Store.init();
    defer store.deinit();
    const id = try memory.remember(testing.allocator, testing.io, store.root, .file, "x", true, "forbid:as any", "src/ !__tests__/ !*.test.ts");
    defer testing.allocator.free(id);
    const recalled = try memory.recall(testing.allocator, testing.io, store.root);
    defer recalled.deinit();
    try testing.expectEqualStrings("src/ !__tests__/ !*.test.ts", recalled.decisions[0].where.?);
}
