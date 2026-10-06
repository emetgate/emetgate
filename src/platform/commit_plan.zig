const std = @import("std");
const symbol = @import("../engine/symbol.zig");
const git_commit = @import("git_commit.zig");
const commit_intent = @import("commit_intent.zig");
const commit_record = @import("commit_record.zig");
const disk = @import("disk.zig");
const rules = @import("rules.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;

const Allocator = std.mem.Allocator;

pub const Change = git_commit.Change;

const index_attempts = 3;

pub const Request = struct {
    message: []const u8,
    oid: ?[]u8 = null,
    base: ?[]u8 = null,
    unfinished: ?[]const u8 = null,
    left: usize = 0,
    receipt: ?[16]u8 = null,
    runtime: ?*Runtime = null,

    pub fn deinit(self: Request, gpa: Allocator) void {
        if (self.oid) |oid| gpa.free(oid);
        if (self.base) |base| gpa.free(base);
    }
};

pub const Opened = union(enum) {
    ok: Session,
    violated: rules.Report,
    failed: rules.Failure,
};

pub fn recoverPending(gpa: Allocator, io: std.Io, root: []const u8) !void {
    const pending = try commit_intent.recoverAll(gpa, io, root);
    if (pending.pending != 0 or pending.failed != 0) return error.CommitStillPending;
}

pub const Session = struct {
    request: ?*Request = null,
    head: ?git_commit.Head = null,
    prepared: ?git_commit.Prepared = null,

    pub fn open(gpa: Allocator, io: std.Io, root: []const u8, request: ?*Request, rels: []const []const u8) !Opened {
        const plan = request orelse return .{ .ok = .{} };
        switch (try rules.messageGate(gpa, io, root, plan.message)) {
            .ok => {},
            .violated => |report| return .{ .violated = report },
            .failed => |failure| return .{ .failed = failure },
        }
        try recoverPending(gpa, io, root);
        return .{ .ok = .{ .request = plan, .head = try git_commit.preflight(gpa, io, root, rels) } };
    }

    pub fn committing(self: *const Session) bool {
        return self.request != null;
    }

    pub fn message(self: *const Session) ?[]const u8 {
        return if (self.request) |plan| plan.message else null;
    }

    pub fn prepare(self: *Session, gpa: Allocator, io: std.Io, root: []const u8, changes: []const Change) !void {
        const plan = self.request orelse return;
        self.prepared = try git_commit.prepare(gpa, io, root, self.head.?, changes, plan.message);
    }

    pub fn land(self: *Session, gpa: Allocator, io: std.Io, root: []const u8, changes: []const Change, pendings: []disk.Pending, batch: ?*const disk.Batch, step: ?*const disk.Step) !void {
        const plan = self.request orelse return disk.commitBatch(pendings, null, null, batch, step);
        const prepared = self.prepared.?;
        const head = self.head.?;
        const tag = commit_record.newTag(io);
        var lock: ?git_commit.Digest = null;
        decide(gpa, io, root, head, prepared, changes, &tag, &lock, step) catch |err| {
            for (pendings) |*p| p.discard(null);
            if (err != error.Crashed) commit_intent.discard(gpa, io, root, &tag, lock);
            return err;
        };
        plan.oid = try gpa.dupe(u8, prepared.commit);
        plan.base = try gpa.dupe(u8, head.oid);
        if (disk.Step.stops(step)) return abandon(pendings);
        if (!try git_commit.publishIndex(gpa, io, root, lock.?)) {
            for (pendings) |*p| p.discard(null);
            plan.unfinished = commit_intent.index_not_published;
            return;
        }
        if (disk.Step.stops(step)) return abandon(pendings);
        disk.commitBatch(pendings, null, null, batch, step) catch |err| {
            if (err == error.Crashed or err == error.OutOfMemory) return err;
        };
        const report = commit_intent.complete(gpa, io, root, &tag, step) catch |err| {
            if (err == error.Crashed or err == error.OutOfMemory) return err;
            plan.unfinished = commit_intent.file_not_written;
            return;
        };
        plan.unfinished = report.reason;
        plan.left = report.left;
    }

    pub fn deinit(self: Session, gpa: Allocator) void {
        if (self.prepared) |prepared| prepared.deinit(gpa);
        if (self.head) |head| head.deinit(gpa);
    }
};

fn abandon(pendings: []disk.Pending) error{Crashed} {
    for (pendings) |*p| p.abandon();
    return error.Crashed;
}

fn hex(arena: Allocator, hash: ?symbol.Hash) ![]const u8 {
    const h = hash orelse return "";
    return arena.dupe(u8, &std.fmt.bytesToHex(h, .lower));
}

fn decide(gpa: Allocator, io: std.Io, root: []const u8, head: git_commit.Head, prepared: git_commit.Prepared, changes: []const Change, tag: []const u8, lock: *?git_commit.Digest, step: ?*const disk.Step) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try git_commit.remeasure(gpa, io, root, head, changes);
    const branch = try git_commit.currentBranch(arena, io, root);

    const items = try arena.alloc(commit_intent.Item, changes.len);
    const contents = try arena.alloc(?[]const u8, changes.len);
    for (changes, prepared.entries, items, contents) |change, entry, *item, *content| {
        const abs = try std.fmt.allocPrint(arena, "{s}\\{s}", .{ root, entry.path });
        std.mem.replaceScalar(u8, abs, '/', '\\');
        const base: ?symbol.Hash = disk.hashFile(gpa, io, abs) catch |err| switch (err) {
            error.FileNotFound => null,
            else => |e| return e,
        };
        content.* = change.content;
        item.* = .{
            .path = entry.path,
            .mode = try arena.dupe(u8, &entry.mode),
            .blob = entry.blob orelse "",
            .base = try hex(arena, base),
            .new = try hex(arena, if (change.content) |bytes| symbol.hashOf(bytes) else null),
        };
    }
    try commit_intent.stage(gpa, io, root, tag, contents);
    if (disk.Step.stops(step)) return error.Crashed;

    const dir = try commit_intent.dirOf(arena, root);
    const staged_index = try commit_intent.indexPath(arena, dir, tag);
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const staged = try git_commit.stageIndex(gpa, io, root, prepared.entries, staged_index);
        try commit_intent.write(gpa, io, root, tag, .{
            .commit = prepared.commit,
            .base = head.oid,
            .branch = branch,
            .lock = &std.fmt.bytesToHex(staged.digest, .lower),
            .items = items,
        });
        if (disk.Step.stops(step)) return error.Crashed;
        git_commit.acquireIndex(gpa, io, root, staged_index, staged) catch |err| {
            if (err == error.IndexChanged and attempt + 1 < index_attempts) continue;
            return err;
        };
        lock.* = staged.digest;
        break;
    }
    if (disk.Step.stops(step)) return error.Crashed;
    try git_commit.moveBranch(gpa, io, root, branch, prepared.commit, head.oid);
}
