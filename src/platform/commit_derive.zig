const std = @import("std");
const builtin = @import("builtin");
const git_commit = @import("git_commit.zig");
const symbol = @import("../engine/symbol.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Git = git_commit.Git;
const Head = git_commit.Head;
const Change = git_commit.Change;
const Entry = git_commit.Entry;

pub const paths_per_process = 4096;
pub const max_processes = 8;
const max_listing_bytes = 256 * 1024 * 1024;
const default_mode = "100644";

pub const Derived = struct {
    lines: []u8,
    entries: []Entry,
    proposed: []?symbol.Hash,

    pub fn deinit(self: Derived, gpa: Allocator) void {
        gpa.free(self.lines);
        gpa.free(self.proposed);
        git_commit.freeEntries(gpa, self.entries);
    }
};

pub const Foreign = struct {
    paths: [][]const u8,
    total: usize,

    pub fn deinit(self: Foreign, gpa: Allocator) void {
        for (self.paths) |path| gpa.free(path);
        gpa.free(self.paths);
    }
};

pub const Outcome = union(enum) {
    derived: Derived,
    foreign: Foreign,
};

pub const Judge = struct {
    ctx: *anyopaque,
    same_as_fresh: *const fn (ctx: *anyopaque, paths: []const []const u8, same: []bool) anyerror!void,
};

pub const Probe = struct {
    before_reading: ?*const fn (gate_abs: []const u8) void = null,
    processes: usize = 0,
};

pub var probe: Probe = .{};

const Target = struct {
    path: []const u8,
    mode: [6]u8,
    content: ?[]const u8,
    in_head: bool = false,
    oid: ?[]const u8 = null,
    same_as: ?usize = null,
};

fn speakable(path: []const u8) bool {
    for (path) |byte| {
        if (byte < 32 or byte == '"') return false;
    }
    return path.len != 0;
}

fn gateEnv(git: Git, head: Head, gate_abs: []const u8, index_abs: []const u8) !Git {
    const env = try git.arena.create(std.process.Environ.Map);
    env.* = std.process.Environ.createMap(.{ .block = .global }, git.arena) catch return error.GitFailed;
    try env.put("GIT_DIR", head.git_dir);
    try env.put("GIT_WORK_TREE", gate_abs);
    try env.put("GIT_INDEX_FILE", index_abs);
    var inside = git;
    inside.env = env;
    inside.root = gate_abs;
    return inside;
}

const Run = struct {
    child: ?std.process.Child = null,
    input: ?std.Io.File = null,
    output: ?std.Io.File = null,
    out_abs: []const u8 = "",
    first: usize = 0,
    count: usize = 0,
};

fn start(git: Git, work_dir: []const u8, number: usize, paths: []const []const u8, write: bool, run: *Run) !void {
    var list: std.ArrayList(u8) = .empty;
    for (paths) |path| {
        try list.appendSlice(git.arena, path);
        try list.append(git.arena, '\n');
    }
    const in_abs = try std.fmt.allocPrint(git.arena, "{s}\\paths-{d}", .{ work_dir, number });
    run.out_abs = try std.fmt.allocPrint(git.arena, "{s}\\oids-{d}", .{ work_dir, number });
    Dir.cwd().writeFile(git.io, .{ .sub_path = in_abs, .data = list.items }) catch return error.GitFailed;
    run.input = Dir.cwd().openFile(git.io, in_abs, .{}) catch return error.GitFailed;
    run.output = Dir.cwd().createFile(git.io, run.out_abs, .{}) catch return error.GitFailed;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(git.arena, &.{ git.exe, "-c", "core.longpaths=true", "-c", "core.fsmonitor=false", "hash-object" });
    if (write) try argv.append(git.arena, "-w");
    try argv.append(git.arena, "--stdin-paths");
    run.child = std.process.spawn(git.io, .{
        .argv = argv.items,
        .cwd = .{ .path = git.root },
        .environ_map = git.env,
        .stdin = .{ .file = run.input.? },
        .stdout = .{ .file = run.output.? },
        .stderr = .ignore,
        .create_no_window = true,
    }) catch return error.GitFailed;
    if (builtin.is_test) probe.processes += 1;
}

fn finish(git: Git, run: *Run) ![]const []const u8 {
    defer closeRun(git, run);
    var child = run.child orelse return error.GitFailed;
    run.child = null;
    _ = child.wait(git.io) catch return error.GitFailed;
    if (run.output) |file| {
        file.close(git.io);
        run.output = null;
    }
    const text = Dir.cwd().readFileAlloc(git.io, run.out_abs, git.arena, .limited(max_listing_bytes)) catch return error.GitFailed;
    var oids: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| try oids.append(git.arena, line);
    return oids.items;
}

fn closeRun(git: Git, run: *Run) void {
    if (run.child) |*child| child.kill(git.io);
    run.child = null;
    if (run.input) |file| file.close(git.io);
    run.input = null;
    if (run.output) |file| file.close(git.io);
    run.output = null;
}

fn addLine(arena: Allocator, lines: *std.ArrayList(u8), mode: []const u8, kind: []const u8, oid: []const u8, path: []const u8) !void {
    try lines.ensureUnusedCapacity(arena, mode.len + kind.len + oid.len + path.len + 4);
    lines.appendSliceAssumeCapacity(mode);
    lines.appendAssumeCapacity(' ');
    lines.appendSliceAssumeCapacity(kind);
    lines.appendAssumeCapacity(' ');
    lines.appendSliceAssumeCapacity(oid);
    lines.appendAssumeCapacity('\t');
    lines.appendSliceAssumeCapacity(path);
    lines.appendAssumeCapacity(0);
}

fn sameBytes(git: Git, gate_abs: []const u8, path: []const u8, content: ?[]const u8) !bool {
    const abs = try git_commit.absOf(git.arena, gate_abs, path);
    const limit = if (content) |bytes| bytes.len + 1 else 1;
    const found = Dir.cwd().readFileAlloc(git.io, abs, git.arena, .limited(limit)) catch |err| switch (err) {
        error.FileNotFound => return content == null,
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    const want = content orelse return false;
    return std.mem.eql(u8, found, want);
}

pub fn derive(gpa: Allocator, io: std.Io, root: []const u8, head: Head, gate_abs: []const u8, changes: []const Change, judge: ?Judge) !Outcome {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const git = try Git.init(arena, io, root);

    var held: std.ArrayList(git_commit.TreeEntry) = .empty;
    try git_commit.parseTree(arena, head.listing, &held);

    var by_path: std.StringHashMapUnmanaged(usize) = .empty;
    const targets = try arena.alloc(Target, changes.len);
    for (changes, targets, 0..) |change, *target, index| {
        const measured = head.find(change.rel) orelse return error.TargetHasUncommittedChanges;
        const from = head.find(change.mode_from orelse change.rel) orelse return error.TargetHasUncommittedChanges;
        if (!speakable(measured.path)) return error.CommittedTreeIncomplete;
        target.* = .{ .path = measured.path, .mode = from.mode orelse default_mode.*, .content = change.content };
        const slot = try by_path.getOrPut(arena, measured.path);
        if (slot.found_existing) targets[slot.value_ptr.*].same_as = index;
        slot.value_ptr.* = index;
    }
    for (targets) |*target| {
        while (target.same_as) |later| {
            const next = targets[later].same_as orelse break;
            target.same_as = next;
        }
    }

    var bulk: std.ArrayList([]const u8) = .empty;
    var bulk_entry: std.ArrayList(usize) = .empty;
    for (held.items, 0..) |entry, index| {
        if (!std.mem.eql(u8, entry.kind, "blob")) continue;
        if (by_path.get(entry.path)) |at| {
            targets[at].in_head = true;
            continue;
        }
        if (!speakable(entry.path)) return error.CommittedTreeIncomplete;
        try bulk.append(arena, entry.path);
        try bulk_entry.append(arena, index);
    }

    if (builtin.is_test) {
        if (probe.before_reading) |hook| hook(gate_abs);
    }

    var foreign: std.ArrayList([]const u8) = .empty;
    var unreadable = false;
    for (targets) |target| {
        if (target.same_as != null) continue;
        if (!try sameBytes(git, gate_abs, target.path, target.content)) try foreign.append(arena, target.path);
    }

    const work = try git_commit.Work.open(arena, io, root);
    defer work.done();
    const index_abs = try std.fs.path.join(arena, &.{ work.dir, "index" });
    var private = try git.withIndex(index_abs);
    private.hex = head.oid.len;
    _ = try private.need(&.{ "read-tree", head.oid });
    var gone: std.ArrayList(Entry) = .empty;
    for (targets) |target| {
        if (target.same_as != null) continue;
        if (target.content == null and target.in_head) try gone.append(arena, .{ .path = @constCast(target.path), .mode = target.mode, .blob = null });
    }
    try git_commit.applyEntries(private, gone.items);
    const inside = try gateEnv(git, head, gate_abs, index_abs);

    var written: std.ArrayList([]const u8) = .empty;
    var written_target: std.ArrayList(usize) = .empty;
    for (targets, 0..) |target, index| {
        if (target.content == null or target.same_as != null) continue;
        try written.append(arena, target.path);
        try written_target.append(arena, index);
    }

    const share = @max(paths_per_process, (bulk.items.len + max_processes - 1) / max_processes);
    var runs: [max_processes + 1]Run = @splat(.{});
    var used: usize = 0;
    defer for (runs[0..used]) |*run| closeRun(inside, run);
    if (foreign.items.len == 0) {
        var at: usize = 0;
        while (at < bulk.items.len) {
            const end = @min(bulk.items.len, at + share);
            runs[used] = .{ .first = at, .count = end - at };
            used += 1;
            try start(inside, work.dir, used, bulk.items[at..end], false, &runs[used - 1]);
            at = end;
        }
        const reading = used;
        if (written.items.len != 0) {
            runs[used] = .{ .count = written.items.len };
            used += 1;
            try start(inside, work.dir, used, written.items, true, &runs[used - 1]);
        }
        const oids = try arena.alloc([]const u8, bulk.items.len);
        for (runs[0..reading]) |*run| {
            const got = try finish(inside, run);
            if (got.len < run.count) {
                unreadable = true;
                try foreign.append(arena, bulk.items[run.first + got.len]);
                continue;
            }
            if (got.len != run.count) return error.GitFailed;
            @memcpy(oids[run.first..][0..run.count], got);
        }
        if (reading != used) {
            const got = try finish(inside, &runs[reading]);
            if (got.len != written.items.len) return error.GitFailed;
            for (got, written_target.items) |oid, at_target| targets[at_target].oid = oid;
        }
        if (!unreadable) {
            var other: std.ArrayList([]const u8) = .empty;
            var other_at: std.ArrayList(usize) = .empty;
            for (oids, bulk_entry.items, 0..) |oid, entry_index, at_bulk| {
                const entry = held.items[entry_index];
                if (!std.mem.eql(u8, oid, entry.oid)) {
                    try other.append(arena, entry.path);
                    try other_at.append(arena, at_bulk);
                }
            }
            if (other.items.len != 0) {
                const same = try arena.alloc(bool, other.items.len);
                @memset(same, false);
                if (judge) |asked| asked.same_as_fresh(asked.ctx, other.items, same) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => @memset(same, false),
                };
                for (other.items, other_at.items, same) |path, at_bulk, checked_out| {
                    if (!checked_out) try foreign.append(arena, path);
                    oids[at_bulk] = held.items[bulk_entry.items[at_bulk]].oid;
                }
            }
        }
        if (foreign.items.len == 0) {
            var lines: std.ArrayList(u8) = .empty;
            var next: usize = 0;
            for (held.items) |entry| {
                if (!std.mem.eql(u8, entry.kind, "blob")) {
                    try addLine(arena, &lines, entry.mode, entry.kind, entry.oid, entry.path);
                    continue;
                }
                if (by_path.contains(entry.path)) continue;
                try addLine(arena, &lines, entry.mode, "blob", oids[next], entry.path);
                next += 1;
            }
            for (targets) |*target| {
                if (target.same_as) |last| target.oid = targets[last].oid;
            }
            for (targets) |target| {
                if (target.same_as != null) continue;
                const oid = target.oid orelse continue;
                try addLine(arena, &lines, &target.mode, "blob", oid, target.path);
            }
            const entries = try gpa.alloc(Entry, targets.len);
            var made: usize = 0;
            errdefer {
                for (entries[0..made]) |entry| {
                    gpa.free(entry.path);
                    if (entry.blob) |blob| gpa.free(blob);
                }
                gpa.free(entries);
            }
            for (targets, entries) |target, *entry| {
                const path = try gpa.dupe(u8, target.path);
                errdefer gpa.free(path);
                entry.* = .{ .path = path, .mode = target.mode, .blob = if (target.oid) |oid| try gpa.dupe(u8, oid) else null };
                made += 1;
            }
            const proposed = try gpa.alloc(?symbol.Hash, targets.len);
            errdefer gpa.free(proposed);
            for (targets, proposed) |target, *slot| slot.* = if (target.content) |bytes| symbol.hashOf(bytes) else null;
            const kept = try gpa.dupe(u8, lines.items);
            return .{ .derived = .{ .lines = kept, .entries = entries, .proposed = proposed } };
        }
    }

    const shown = @min(foreign.items.len, 64);
    const paths = try gpa.alloc([]const u8, shown);
    var copied: usize = 0;
    errdefer {
        for (paths[0..copied]) |path| gpa.free(path);
        gpa.free(paths);
    }
    for (foreign.items[0..shown], paths) |path, *slot| {
        slot.* = try gpa.dupe(u8, path);
        copied += 1;
    }
    return .{ .foreign = .{ .paths = paths, .total = foreign.items.len } };
}
