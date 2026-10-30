const std = @import("std");
const sandbox = @import("sandbox.zig");
const shadow = @import("shadow.zig");
const runner = @import("runner.zig");
const test_outcome = @import("test_outcome.zig");
const output_digest = @import("../protocol/output_digest.zig");
const test_results = @import("test_results.zig");
const test_debt = @import("test_debt.zig");
const test_command_mod = @import("test_command.zig");

const Allocator = std.mem.Allocator;

pub const Note = struct {
    failing: bool = false,
    unverified: bool = false,
    skipped: bool = false,
    debt: bool = false,
    regressed: bool = false,
    buf: [600]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const Note) []const u8 {
        return self.buf[0..self.len];
    }

    fn keep(self: *Note, digest: []const u8) void {
        self.len = 0;
        self.append(digest);
    }

    fn append(self: *Note, text_part: []const u8) void {
        const room = self.buf.len - self.len;
        var end = @min(text_part.len, room);
        while (end > 0 and end < text_part.len and text_part[end] & 0xC0 == 0x80) end -= 1;
        @memcpy(self.buf[self.len..][0..end], text_part[0..end]);
        self.len += end;
    }
};

pub const unverified_prefix = "the test command could not run, so no test judged this edit: ";

pub const Change = struct {
    rel: []const u8,
    content: ?[]const u8,
};

pub const Stage = enum { typecheck, tests };

pub const Failures = struct {
    stage: ?Stage,
    keys: []const u64,
    cases: ?[]const test_results.Case = null,
};

pub fn inert(rel: []const u8) bool {
    const base = std.fs.path.basename(rel);
    if (std.mem.startsWith(u8, base, ".git")) return true;
    const dot = std.mem.lastIndexOfScalar(u8, base, '.');
    const stem = if (dot) |d| base[0..d] else base;
    const names = [_][]const u8{ "LICENSE", "LICENCE", "COPYING", "AUTHORS", "CHANGELOG", "NOTICE" };
    for (names) |name| if (std.ascii.eqlIgnoreCase(stem, name)) return true;
    const ext = if (dot) |d| base[d..] else "";
    const docs = [_][]const u8{ ".md", ".markdown", ".rst", ".adoc" };
    for (docs) |doc| if (std.ascii.eqlIgnoreCase(ext, doc)) return true;
    return false;
}

pub fn allInert(changes: []const Change) bool {
    if (changes.len == 0) return false;
    for (changes) |change| if (!inert(change.rel)) return false;
    return true;
}

pub fn noNewFailures(after: Failures, before: Failures) bool {
    const stage = before.stage orelse return false;
    if (after.stage == null or after.stage.? != stage) return false;
    if (after.keys.len == 0 or before.keys.len == 0) return false;
    var i: usize = 0;
    for (after.keys) |key| {
        while (i < before.keys.len and before.keys[i] < key) i += 1;
        if (i == before.keys.len or before.keys[i] != key) return false;
    }
    return true;
}

fn comparable(report: sandbox.Report) bool {
    return switch (report.outcome) {
        .exited => |code| code != 0 and !report.killed_leftovers,
        else => false,
    };
}

const Entry = struct {
    key: u64,
    stage: ?Stage,
    keys: []u64,
    results: ?test_results.Results,
};

const cache_size = 8;
var cache: [cache_size]?Entry = @splat(null);
var cache_next: usize = 0;

fn lookup(key: u64) ?Failures {
    for (cache) |slot| {
        const entry = slot orelse continue;
        if (entry.key == key) return .{ .stage = entry.stage, .keys = entry.keys, .cases = if (entry.results) |r| r.cases else null };
    }
    return null;
}

fn remember(key: u64, stage: ?Stage, keys: []const u64, results: ?test_results.Results) Failures {
    var held = results;
    const owned = std.heap.page_allocator.dupe(u64, keys) catch {
        if (held) |*r| r.deinit();
        return .{ .stage = stage, .keys = &.{} };
    };
    if (cache[cache_next]) |old| {
        std.heap.page_allocator.free(old.keys);
        var dropped = old.results;
        if (dropped) |*r| r.deinit();
    }
    cache[cache_next] = .{ .key = key, .stage = stage, .keys = owned, .results = held };
    cache_next = (cache_next + 1) % cache_size;
    return .{ .stage = stage, .keys = owned, .cases = if (held) |r| r.cases else null };
}

fn readOriginal(gpa: Allocator, io: std.Io, root: []const u8, rel: []const u8) !?[]u8 {
    const abs = try std.fs.path.join(gpa, &.{ root, rel });
    defer gpa.free(abs);
    return std.Io.Dir.cwd().readFileAlloc(io, abs, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| e,
    };
}

pub fn treeKey(gpa: Allocator, io: std.Io, root: []const u8, typecheck_command: ?[]const u8, test_command: []const u8) !u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(root);
    hasher.update(&.{0});
    hasher.update(typecheck_command orelse "");
    hasher.update(&.{0});
    hasher.update(test_command);
    const files = try shadow.workingFiles(gpa, io, root);
    defer gpa.free(files);
    defer shadow.freeFileList(gpa, files);
    for (files) |rel| {
        hasher.update(&.{0});
        hasher.update(rel);
        const bytes = (readOriginal(gpa, io, root, rel) catch null) orelse continue;
        defer gpa.free(bytes);
        var content: [8]u8 = undefined;
        std.mem.writeInt(u64, &content, std.hash.Wyhash.hash(0, bytes), .little);
        hasher.update(&content);
    }
    return hasher.final();
}

pub fn passReport(gpa: Allocator) !sandbox.Report {
    const out = try gpa.alloc(u8, 0);
    errdefer gpa.free(out);
    return .{ .outcome = .{ .exited = 0 }, .duration_ns = 0, .stdout = out, .stderr = try gpa.alloc(u8, 0), .truncated = false, .killed_leftovers = false };
}

pub const Gate = struct {
    root: []const u8,
    gate_dir: []const u8,
    typecheck_command: ?[]const u8,
    test_command: []const u8,
    limits: sandbox.Limits,
    note: ?*Note = null,
    commits: bool = false,
};

fn reporterFor(gpa: Allocator, gate_dir: []const u8, command: []const u8) !?test_results.Reporter {
    if (!test_command_mod.chosen(command)) return null;
    return test_results.Reporter.of(gpa, gate_dir, command);
}

fn runGate(gpa: Allocator, io: std.Io, gate: Gate, reporter: ?test_results.Reporter) !runner.ShadowRun {
    if (reporter) |r| r.clear(io);
    return runner.runStages(gpa, io, gate.gate_dir, gate.typecheck_command, if (reporter) |r| r.command else gate.test_command, gate.limits);
}

fn collected(gpa: Allocator, io: std.Io, reporter: ?test_results.Reporter, ran: runner.ShadowRun) !?test_results.Results {
    const r = reporter orelse return null;
    return switch (ran) {
        .tests => |report| r.collect(gpa, io, report),
        else => null,
    };
}

pub const Measured = struct {
    run: runner.ShadowRun,
    results: ?test_results.Results,
};

pub fn measured(gpa: Allocator, io: std.Io, gate: Gate) !Measured {
    const reporter = try reporterFor(gpa, gate.gate_dir, gate.test_command);
    defer if (reporter) |r| r.deinit(gpa);
    const ran = try runGate(gpa, io, gate, reporter);
    errdefer switch (ran) {
        .typecheck, .tests => |report| report.deinit(gpa),
        else => {},
    };
    return .{ .run = ran, .results = try collected(gpa, io, reporter, ran) };
}

pub fn run(gpa: Allocator, io: std.Io, workspace: anytype, changes: []const Change, gate: Gate) !runner.ShadowRun {
    if (allInert(changes)) {
        if (gate.note) |n| n.skipped = true;
        return .{ .tests = try passReport(gpa) };
    }
    const reporter = try reporterFor(gpa, gate.gate_dir, gate.test_command);
    defer if (reporter) |r| r.deinit(gpa);
    const after = try runGate(gpa, io, gate, reporter);
    const stage: Stage, const report = switch (after) {
        .typecheck => |r| .{ .typecheck, r },
        .tests => |r| .{ .tests, r },
        else => return after,
    };
    errdefer report.deinit(gpa);
    var now = try collected(gpa, io, reporter, after);
    defer if (now) |*results| results.deinit();
    if (report.passed()) {
        if (now != null) {
            try test_debt.begin(gpa, io, gate.root, &.{});
            test_debt.stage(gate.root, &.{});
        }
        return after;
    }
    if (!comparable(report)) return after;

    const key = try treeKey(gpa, io, gate.root, gate.typecheck_command, gate.test_command);
    const before = lookup(key) orelse try measure(gpa, io, workspace, changes, gate, key, reporter);
    if (now) |results| {
        if (before.cases) |cases| return judged(gpa, io, changes, gate, report, cases, results.cases);
    }
    const now_keys = try output_digest.failureKeys(gpa, report.stdout, report.stderr);
    defer gpa.free(now_keys);
    if (!noNewFailures(.{ .stage = stage, .keys = now_keys }, before)) return after;

    if (gate.note) |n| {
        if (test_outcome.envError(report)) |reason| {
            n.unverified = true;
            n.keep(unverified_prefix);
            n.append(reason);
        } else {
            n.failing = true;
            const digest = try output_digest.digest(gpa, report.stdout, report.stderr);
            defer gpa.free(digest.text);
            n.keep(digest.text);
        }
    }
    var accepted = report;
    accepted.outcome = .{ .exited = 0 };
    accepted.no_tests = false;
    return .{ .tests = accepted };
}

fn judged(gpa: Allocator, io: std.Io, changes: []const Change, gate: Gate, report: sandbox.Report, before: []const test_results.Case, now: []const test_results.Case) !runner.ShadowRun {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var text: std.Io.Writer.Allocating = .init(arena);
    const verdict = try test_results.judge(arena, before, now);
    var blocked: std.ArrayList([]const u8) = .empty;
    try blocked.appendSlice(arena, verdict.regressed);
    if (verdict.vanished.len != 0) {
        const touched = try arena.alloc(test_results.Touched, changes.len);
        for (touched, changes) |*slot, change| slot.* = .{ .rel = change.rel, .original = try readOriginal(arena, io, gate.root, change.rel) };
        try blocked.appendSlice(arena, try test_results.unexempt(arena, verdict.vanished, touched));
    }
    if (blocked.items.len != 0) {
        if (gate.note) |n| {
            try test_debt.names(&text.writer, blocked.items);
            n.regressed = true;
            n.keep(text.written());
        }
        return .{ .tests = report };
    }
    const failing = try test_results.failingOf(arena, now);
    try test_debt.begin(gpa, io, gate.root, try test_results.failingOf(arena, before));
    const owed = try test_debt.introduced(arena, try test_debt.startOf(arena, io, gate.root), failing);
    if (gate.note) |n| {
        try test_debt.summary(&text.writer, failing, owed.len);
        n.debt = true;
        n.keep(text.written());
    }
    if (gate.commits and owed.len != 0) return .{ .tests = report };
    test_debt.stage(gate.root, failing);
    var accepted = report;
    accepted.outcome = .{ .exited = 0 };
    accepted.no_tests = false;
    return .{ .tests = accepted };
}

fn measure(gpa: Allocator, io: std.Io, workspace: anytype, changes: []const Change, gate: Gate, key: u64, reporter: ?test_results.Reporter) !Failures {
    for (changes) |change| {
        const original = try readOriginal(gpa, io, gate.root, change.rel);
        defer if (original) |bytes| gpa.free(bytes);
        if (original) |bytes| try workspace.writeFile(change.rel, bytes) else if (change.content != null) try workspace.deleteFile(change.rel);
    }
    const base = try runGate(gpa, io, gate, reporter);
    for (changes) |change| {
        if (change.content) |bytes| try workspace.writeFile(change.rel, bytes) else try workspace.deleteFile(change.rel);
    }
    const stage: Stage, const report = switch (base) {
        .typecheck => |r| .{ .typecheck, r },
        .tests => |r| .{ .tests, r },
        else => return .{ .stage = null, .keys = &.{} },
    };
    defer report.deinit(gpa);
    const results = if (stage == .tests) try collected(std.heap.page_allocator, io, reporter, base) else null;
    if (report.passed() or !comparable(report)) return remember(key, null, &.{}, results);
    const keys = try output_digest.failureKeys(gpa, report.stdout, report.stderr);
    defer gpa.free(keys);
    return remember(key, stage, keys, results);
}

const testing = std.testing;

test "non-code files are never test-gated" {
    try testing.expect(inert(".gitignore"));
    try testing.expect(inert("docs/README.md"));
    try testing.expect(inert("LICENSE"));
    try testing.expect(inert("CHANGELOG.md"));
    try testing.expect(!inert("src/app.ts"));
    try testing.expect(!inert("requirements.txt"));
    try testing.expect(!inert("package.json"));
    try testing.expect(allInert(&.{ .{ .rel = "README.md", .content = "x" }, .{ .rel = ".gitignore", .content = "y" } }));
    try testing.expect(!allInert(&.{ .{ .rel = "README.md", .content = "x" }, .{ .rel = "src/a.ts", .content = "y" } }));
    try testing.expect(!allInert(&.{}));
}

test "an edit is accepted only when its failures were already failing before it, in the same stage" {
    const before: Failures = .{ .stage = .tests, .keys = &.{ 3, 7, 9 } };
    try testing.expect(noNewFailures(.{ .stage = .tests, .keys = &.{ 3, 9 } }, before));
    try testing.expect(noNewFailures(.{ .stage = .tests, .keys = &.{ 3, 7, 9 } }, before));
    try testing.expect(!noNewFailures(.{ .stage = .tests, .keys = &.{ 3, 8 } }, before));
    try testing.expect(!noNewFailures(.{ .stage = .typecheck, .keys = &.{3} }, before));
    try testing.expect(!noNewFailures(.{ .stage = .tests, .keys = &.{} }, before));
    try testing.expect(!noNewFailures(.{ .stage = .tests, .keys = &.{3} }, .{ .stage = null, .keys = &.{} }));
    try testing.expect(!noNewFailures(.{ .stage = .tests, .keys = &.{} }, .{ .stage = .tests, .keys = &.{} }));
}
