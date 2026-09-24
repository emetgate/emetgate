const std = @import("std");

const Allocator = std.mem.Allocator;

pub const max_source_bytes = 64 * 1024 * 1024;

pub const Kind = enum { unit, e2e };

pub const Status = enum { killed, survived, compile_error, no_tests, timeout, other_error };

pub const Summary = struct {
    passed: u32,
    total: u32,
    failed: u32 = 0,
    crashed: u32 = 0,
};

pub const Skip = enum { e2e, survivor };

pub fn skipReason(kind: Kind, expect_status: []const u8, selected: bool, include_e2e: bool, skip_survivors: bool) ?Skip {
    if (selected) return null;
    if (kind == .e2e and !include_e2e) return .e2e;
    if (skip_survivors and std.mem.eql(u8, expect_status, "survived")) return .survivor;
    return null;
}

pub fn timeoutFor(own: ?u64, global: u64) u64 {
    return own orelse global;
}

pub fn writeSummary(w: *std.Io.Writer, run: usize, failures: usize, skipped_e2e: usize, skipped_survivors: usize, rotation: usize) std.Io.Writer.Error!void {
    try w.print("{d} mutation(s) run, {d} as expected, {d} not as expected", .{ run, run - failures, failures });
    if (skipped_e2e != 0) try w.print(", {d} e2e mutation(s) skipped (pass --e2e)", .{skipped_e2e});
    if (skipped_survivors != 0) try w.print(", {d} expected survivor(s) skipped (drop --skip-survivors)", .{skipped_survivors});
    if (rotation != 0) try w.print(", {d} mutation(s) verified one at a time this run", .{rotation});
}

pub fn applyMutation(gpa: Allocator, source: []const u8, from: []const u8, to: []const u8, all: bool) ![]u8 {
    if (from.len == 0) return error.EmptyPattern;
    const count = std.mem.count(u8, source, from);
    if (count == 0) return error.PatternNotFound;
    if (count > 1 and !all) return error.PatternNotUnique;
    const out = try gpa.alloc(u8, source.len - count * from.len + count * to.len);
    _ = std.mem.replace(u8, source, from, to, out);
    return out;
}

pub fn parseSummary(output: []const u8) ?Summary {
    const marker = " tests passed";
    const at = std.mem.lastIndexOf(u8, output, marker) orelse return null;
    const line_start = if (std.mem.lastIndexOfScalar(u8, output[0..at], '\n')) |nl| nl + 1 else 0;
    const line_end = std.mem.indexOfScalarPos(u8, output, at, '\n') orelse output.len;
    const head = output[line_start..at];
    const token_start = if (std.mem.lastIndexOfAny(u8, head, " ;")) |i| i + 1 else 0;
    const ratio = head[token_start..];
    const slash = std.mem.indexOfScalar(u8, ratio, '/') orelse return null;
    const passed = std.fmt.parseInt(u32, ratio[0..slash], 10) catch return null;
    const total = std.fmt.parseInt(u32, ratio[slash + 1 ..], 10) catch return null;
    const tail = output[at..line_end];
    return .{ .passed = passed, .total = total, .failed = numberBefore(tail, " failed"), .crashed = numberBefore(tail, " crashed") };
}

fn numberBefore(text: []const u8, word: []const u8) u32 {
    const at = std.mem.indexOf(u8, text, word) orelse return 0;
    var start = at;
    while (start > 0 and std.ascii.isDigit(text[start - 1])) start -= 1;
    return std.fmt.parseInt(u32, text[start..at], 10) catch 0;
}

const failure_prefix = "error: '";
const failure_suffixes = [_][]const u8{ "' failed", "' exited with code" };

fn failedTestName(raw: []const u8) ?[]const u8 {
    const line = std.mem.trim(u8, raw, " \r");
    if (!std.mem.startsWith(u8, line, failure_prefix)) return null;
    for (failure_suffixes) |suffix| {
        const close = std.mem.lastIndexOf(u8, line, suffix) orelse continue;
        if (close > failure_prefix.len) return line[failure_prefix.len..close];
    }
    return null;
}

pub fn failedTests(gpa: Allocator, output: []const u8) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(gpa);
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const name = failedTestName(raw) orelse continue;
        for (names.items) |seen| {
            if (std.mem.eql(u8, seen, name)) break;
        } else try names.append(gpa, name);
    }
    return names.toOwnedSlice(gpa);
}

fn isTestPrefix(prefix: []const u8) bool {
    return std.mem.endsWith(u8, prefix, ".test.") or std.mem.endsWith(u8, prefix, ".decltest.");
}

pub fn missingKill(failed: []const []const u8, expected: []const []const u8) ?[]const u8 {
    outer: for (expected) |want| {
        for (failed) |got| {
            if (std.mem.eql(u8, got, want)) continue :outer;
            if (got.len > want.len and std.mem.endsWith(u8, got, want) and isTestPrefix(got[0 .. got.len - want.len])) continue :outer;
        }
        return want;
    }
    return null;
}

pub fn unexpectedKill(failed: []const []const u8, expected: []const []const u8) ?[]const u8 {
    for (failed) |got| {
        for (expected) |want| {
            if (std.mem.eql(u8, got, want)) break;
            if (got.len > want.len and std.mem.endsWith(u8, got, want) and isTestPrefix(got[0 .. got.len - want.len])) break;
        } else return got;
    }
    return null;
}

pub fn classify(kind: Kind, exit_code: u8, output: []const u8) Status {
    if (exit_code == 0) {
        if (kind == .e2e) return .survived;
        const summary = parseSummary(output) orelse return .no_tests;
        return if (summary.total == 0) .no_tests else .survived;
    }
    if (isCompileError(output)) return .compile_error;
    switch (kind) {
        .unit => {
            if (parseSummary(output)) |s| {
                if (s.failed + s.crashed > 0) return .killed;
            }
            if (hasFailedTestLine(output)) return .killed;
            return .other_error;
        },
        .e2e => {
            if (std.mem.indexOf(u8, output, "e2e-lockdown: ") != null and std.mem.indexOf(u8, output, " failure(s)") != null) return .killed;
            return .other_error;
        },
    }
}

fn isCompileError(output: []const u8) bool {
    return std.mem.indexOf(u8, output, " compilation error") != null;
}

fn hasFailedTestLine(output: []const u8) bool {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        if (failedTestName(raw) != null) return true;
    }
    return false;
}

pub const Candidate = struct {
    index: usize,
    file: []const u8,
    kills: []const []const u8,
    filter: []const []const u8,
    from: []const u8 = "",
    to: []const u8 = "",
    all: bool = false,
};

pub const Source = struct {
    file: []const u8,
    text: []const u8,
};

pub const max_pool_members = 64;

pub fn poolable(kind: Kind, expect_status: []const u8, has_own_timeout: bool, has_own_optimize: bool, kills_len: usize) bool {
    if (kind != .unit) return false;
    if (!std.mem.eql(u8, expect_status, "killed")) return false;
    if (has_own_timeout) return false;
    if (has_own_optimize) return false;
    return kills_len != 0;
}

fn namesOverlap(a: []const []const u8, b: []const []const u8) bool {
    for (a) |left| {
        for (b) |right| {
            if (std.mem.eql(u8, left, right)) return true;
        }
    }
    return false;
}

pub fn family(name: []const u8) ?[]const u8 {
    const colon = std.mem.indexOf(u8, name, ": ") orelse return null;
    if (colon == 0) return null;
    return name[0..colon];
}

fn familiesMeet(a: []const []const u8, b: []const []const u8) bool {
    for (a) |left| {
        const mine = family(left) orelse continue;
        for (b) |right| {
            const theirs = family(right) orelse continue;
            if (std.mem.eql(u8, mine, theirs)) return true;
        }
    }
    return false;
}

fn killsClash(pool: []const Candidate, c: Candidate) bool {
    for (pool) |member| {
        if (namesOverlap(member.kills, c.kills)) return true;
        if (familiesMeet(member.kills, c.kills)) return true;
    }
    return false;
}

fn shareAFile(a: []const Candidate, b: []const Candidate) bool {
    for (a) |left| {
        for (b) |right| {
            if (std.mem.eql(u8, left.file, right.file)) return true;
        }
    }
    return false;
}

pub fn modulesIn(pool: []const Candidate) usize {
    var count: usize = 0;
    for (pool, 0..) |member, i| {
        for (pool[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier.file, member.file)) break;
        } else count += 1;
    }
    return count;
}

fn sourceFor(sources: []const Source, file: []const u8) ?[]const u8 {
    for (sources) |source| {
        if (std.mem.eql(u8, source.file, file)) return source.text;
    }
    return null;
}

pub fn functionsHit(gpa: Allocator, file: []const u8, source: []const u8, from: []const u8) ![]const u32 {
    var starts: std.ArrayList(u32) = .empty;
    errdefer starts.deinit(gpa);
    if (!std.mem.endsWith(u8, file, ".zig") or from.len == 0) return starts.toOwnedSlice(gpa);

    const text = try gpa.dupeZ(u8, source);
    defer gpa.free(text);
    var tree = try std.zig.Ast.parse(gpa, text, .zig);
    defer tree.deinit(gpa);

    var at: usize = 0;
    while (std.mem.indexOfPos(u8, source, at, from)) |hit| : (at = hit + 1) {
        const end = hit + from.len;
        for (0..tree.nodes.len) |i| {
            const node: std.zig.Ast.Node.Index = @enumFromInt(i);
            switch (tree.nodeTag(node)) {
                .fn_decl, .test_decl => {},
                else => continue,
            }
            const first = tree.tokenStart(tree.firstToken(node));
            const last = tree.lastToken(node);
            const stop = tree.tokenStart(last) + tree.tokenSlice(last).len;
            if (first >= end or stop <= hit) continue;
            if (std.mem.indexOfScalar(u32, starts.items, first) == null) try starts.append(gpa, first);
        }
    }
    std.mem.sort(u32, starts.items, {}, std.sort.asc(u32));
    return starts.toOwnedSlice(gpa);
}

fn sharesFunction(hits: []const []const u32, taken: []const usize, own: []const u32) bool {
    for (taken) |i| {
        for (hits[i]) |start| {
            if (std.mem.indexOfScalar(u32, own, start) != null) return true;
        }
    }
    return false;
}

fn packOneFile(
    gpa: Allocator,
    pools: *std.ArrayList(std.ArrayList(Candidate)),
    members: []const Candidate,
    original: []const u8,
    pool_size: usize,
) !void {
    const hits = try gpa.alloc([]const u32, members.len);
    var filled: usize = 0;
    defer {
        for (hits[0..filled]) |h| gpa.free(h);
        gpa.free(hits);
    }
    for (members) |c| {
        hits[filled] = try functionsHit(gpa, c.file, original, c.from);
        filled += 1;
    }

    var pending: std.ArrayList(usize) = .empty;
    defer pending.deinit(gpa);
    for (0..members.len) |i| try pending.append(gpa, i);

    while (pending.items.len != 0) {
        var pool: std.ArrayList(Candidate) = .empty;
        errdefer pool.deinit(gpa);
        var taken: std.ArrayList(usize) = .empty;
        defer taken.deinit(gpa);
        var deferred: std.ArrayList(usize) = .empty;
        defer deferred.deinit(gpa);

        var text = try gpa.dupe(u8, original);
        defer gpa.free(text);

        for (pending.items) |i| {
            const c = members[i];
            if (pool.items.len >= pool_size or killsClash(pool.items, c) or sharesFunction(hits, taken.items, hits[i])) {
                try deferred.append(gpa, i);
                continue;
            }
            const next = applyMutation(gpa, text, c.from, c.to, c.all) catch {
                if (pool.items.len != 0) try deferred.append(gpa, i);
                continue;
            };
            gpa.free(text);
            text = next;
            try pool.append(gpa, c);
            try taken.append(gpa, i);
        }

        if (pool.items.len == 0) {
            pool.deinit(gpa);
            return;
        }
        try pools.append(gpa, pool);
        pending.clearRetainingCapacity();
        try pending.appendSlice(gpa, deferred.items);
    }
}

fn mergeResiduals(gpa: Allocator, pools: *std.ArrayList(std.ArrayList(Candidate)), pool_size: usize) !void {
    var at: usize = 0;
    while (at < pools.items.len) : (at += 1) {
        var other = at + 1;
        while (other < pools.items.len) {
            const host = &pools.items[at];
            const guest = pools.items[other];
            if (host.items.len + guest.items.len > pool_size or
                shareAFile(host.items, guest.items) or
                overlapAcross(host.items, guest.items))
            {
                other += 1;
                continue;
            }
            try host.appendSlice(gpa, guest.items);
            var removed = pools.orderedRemove(other);
            removed.deinit(gpa);
        }
    }
}

fn overlapAcross(a: []const Candidate, b: []const Candidate) bool {
    for (b) |c| {
        if (killsClash(a, c)) return true;
    }
    return false;
}

pub fn buildPools(gpa: Allocator, candidates: []const Candidate, pool_size: usize, sources: []const Source) ![]const []const Candidate {
    var pools: std.ArrayList(std.ArrayList(Candidate)) = .empty;
    defer {
        for (pools.items) |*pool| pool.deinit(gpa);
        pools.deinit(gpa);
    }

    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(gpa);
    for (candidates) |c| {
        for (seen.items) |file| {
            if (std.mem.eql(u8, file, c.file)) break;
        } else {
            try seen.append(gpa, c.file);
            const original = sourceFor(sources, c.file) orelse return error.MissingSource;
            var members: std.ArrayList(Candidate) = .empty;
            defer members.deinit(gpa);
            for (candidates) |other| {
                if (std.mem.eql(u8, other.file, c.file)) try members.append(gpa, other);
            }
            try packOneFile(gpa, &pools, members.items, original, pool_size);
        }
    }

    try mergeResiduals(gpa, &pools, pool_size);

    var out: std.ArrayList([]const Candidate) = .empty;
    errdefer {
        for (out.items) |pool| gpa.free(pool);
        out.deinit(gpa);
    }
    for (pools.items) |*pool| try out.append(gpa, try gpa.dupe(Candidate, pool.items));
    return out.toOwnedSlice(gpa);
}

pub fn unionNames(gpa: Allocator, pool: []const Candidate, comptime field: []const u8) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(gpa);
    for (pool) |member| {
        for (@field(member, field)) |name| {
            for (names.items) |seen| {
                if (std.mem.eql(u8, seen, name)) break;
            } else try names.append(gpa, name);
        }
    }
    return names.toOwnedSlice(gpa);
}

pub fn poolFilter(gpa: Allocator, pool: []const Candidate) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(gpa);
    for (pool) |member| {
        const own = if (member.filter.len != 0) member.filter else member.kills;
        for (own) |name| {
            for (names.items) |seen| {
                if (std.mem.eql(u8, seen, name)) break;
            } else try names.append(gpa, name);
        }
    }
    return names.toOwnedSlice(gpa);
}

pub fn rotationBuckets(share_percent: usize) usize {
    if (share_percent == 0) return 0;
    if (share_percent >= 100) return 1;
    return (100 + share_percent - 1) / share_percent;
}

pub fn rotationBucket(rotation: usize, buckets: usize) usize {
    if (buckets == 0) return 0;
    return rotation % buckets;
}

pub fn inRotation(ordinal: usize, bucket: usize, buckets: usize) bool {
    if (buckets == 0) return false;
    return ordinal % buckets == bucket;
}

pub const PoolVerdict = enum { killed, inconclusive };

pub fn poolVerdict(status: Status, failed: []const []const u8, expected: []const []const u8) PoolVerdict {
    if (status != .killed) return .inconclusive;
    if (missingKill(failed, expected) != null) return .inconclusive;
    if (unexpectedKill(failed, expected) != null) return .inconclusive;
    return .killed;
}

pub fn splitAt(pool: []const Candidate) usize {
    return pool.len / 2;
}

pub fn baselineIsGreen(exit_code: u8, output: []const u8) bool {
    if (exit_code != 0) return false;
    const summary = parseSummary(output) orelse return false;
    return summary.total != 0 and summary.failed == 0 and summary.crashed == 0 and summary.passed == summary.total;
}

pub const Backup = struct {
    path: []const u8,
    original: []const u8,
};

pub const legacy_manifest = "pending.manifest";

pub fn abandonLegacyRecord(gpa: Allocator, io: std.Io, work: std.Io.Dir) !?[]const []const u8 {
    const manifest = work.readFileAlloc(io, legacy_manifest, gpa, .limited(max_pool_members * std.fs.max_path_bytes)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer gpa.free(manifest);
    var named: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (named.items) |path| gpa.free(path);
        named.deinit(gpa);
    }
    var lines = std.mem.splitScalar(u8, manifest, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try named.append(gpa, try gpa.dupe(u8, line));
    }
    var buf: [64]u8 = undefined;
    for (0..max_pool_members) |i| {
        const name = std.fmt.bufPrint(&buf, "pending.{d}.orig", .{i}) catch unreachable;
        work.deleteFile(io, name) catch {};
    }
    try work.deleteFile(io, legacy_manifest);
    return try named.toOwnedSlice(gpa);
}

pub fn syncMirror(gpa: Allocator, io: std.Io, source: std.Io.Dir, mirror: std.Io.Dir, files: []const []const u8, previous: []const []const u8) !usize {
    var written: usize = 0;
    for (files) |path| {
        const want = try source.readFileAlloc(io, path, gpa, .limited(max_source_bytes));
        defer gpa.free(want);
        if (mirror.readFileAlloc(io, path, gpa, .limited(max_source_bytes))) |have| {
            defer gpa.free(have);
            if (std.mem.eql(u8, have, want)) continue;
        } else |_| {}
        if (std.fs.path.dirname(path)) |parent| try mirror.createDirPath(io, parent);
        try mirror.writeFile(io, .{ .sub_path = path, .data = want });
        written += 1;
    }
    for (previous) |path| {
        for (files) |kept| {
            if (std.mem.eql(u8, kept, path)) break;
        } else mirror.deleteFile(io, path) catch {};
    }
    return written;
}
