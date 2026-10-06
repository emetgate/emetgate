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
    left_names: [commit_intent.Report.named_bytes]u8 = undefined,
    left_names_len: usize = 0,
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

pub const Found = struct {
    reason: []const u8,
    named: [commit_intent.Report.named_bytes]u8 = undefined,
    named_len: usize = 0,

    pub fn names(self: *const Found) []const u8 {
        return self.named[0..self.named_len];
    }
};

threadlocal var last_found: ?Found = null;

pub fn noteFound(report: commit_intent.Report) void {
    if (report.left == 0) return;
    var found: Found = .{ .reason = report.reason orelse "" };
    found.named_len = report.names().len;
    @memcpy(found.named[0..found.named_len], report.names());
    last_found = found;
}

pub fn takeFound() ?Found {
    const found = last_found;
    last_found = null;
    return found;
}

pub fn recoverPending(gpa: Allocator, io: std.Io, root: []const u8) !void {
    _ = try recoverFound(gpa, io, root);
}

pub fn recoverFound(gpa: Allocator, io: std.Io, root: []const u8) !commit_intent.Report {
    _ = disk.recoverJournal(gpa, io, root) catch |err| switch (err) {
        error.OutOfMemory, error.Crashed, error.WorkspaceIsLink => |e| return e,
        else => {},
    };
    const found = try commit_intent.recoverAll(gpa, io, root);
    if (found.pending != 0 or found.failed != 0) return error.CommitStillPending;
    return found;
}

pub const Session = struct {
    request: ?*Request = null,
    head: ?git_commit.Head = null,
    prepared: ?git_commit.Prepared = null,

    pub fn open(gpa: Allocator, io: std.Io, root: []const u8, request: ?*Request, rels: []const []const u8) !Opened {
        switch (try rules.frozenGate(gpa, io, root, rels)) {
            .ok => {},
            .violated => |touched| return .{ .violated = touched },
            .failed => |unrunnable| return .{ .failed = unrunnable },
        }
        const plan = request orelse return .{ .ok = .{} };
        switch (try rules.messageGate(gpa, io, root, plan.message)) {
            .ok => {},
            .violated => |report| return .{ .violated = report },
            .failed => |failure| return .{ .failed = failure },
        }
        const found = try recoverFound(gpa, io, root);
        noteFound(found);
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
        var lock: ?disk.Guard = null;
        defer if (lock) |guard| guard.close();
        var staged = false;
        decide(gpa, io, root, head, prepared, changes, pendings, &tag, &lock, &staged, step) catch |err| {
            for (pendings) |*p| p.discard(null);
            if (err == error.Crashed) return err;
            if (lock) |guard| guard.deleteSelf() catch {};
            if (staged) commit_intent.discard(gpa, io, root, &tag, null);
            return err;
        };
        plan.oid = try gpa.dupe(u8, prepared.commit);
        plan.base = try gpa.dupe(u8, head.oid);
        if (disk.Step.stops(step)) return abandon(pendings);
        if (!git_commit.publishHeld(gpa, io, head, lock.?)) {
            for (pendings) |*p| p.discard(null);
            plan.unfinished = commit_intent.index_not_published;
            return;
        }
        lock.?.close();
        lock = null;
        if (disk.Step.stops(step)) return abandon(pendings);
        if (disk.commitBatch(pendings, null, null, batch, step)) |_| {
            commit_intent.finish(gpa, io, root, &tag) catch {
                plan.unfinished = commit_intent.file_not_written;
            };
            return;
        } else |err| {
            if (err == error.Crashed or err == error.OutOfMemory) return err;
        }
        const report = commit_intent.complete(gpa, io, root, &tag, step) catch |err| {
            if (err == error.Crashed or err == error.OutOfMemory) return err;
            plan.unfinished = commit_intent.file_not_written;
            return;
        };
        plan.unfinished = report.reason;
        plan.left = report.left;
        plan.left_names_len = report.names().len;
        @memcpy(plan.left_names[0..plan.left_names_len], report.names());
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

fn sameFile(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const nx: u8 = if (x == '/') '\\' else std.ascii.toLower(x);
        const ny: u8 = if (y == '/') '\\' else std.ascii.toLower(y);
        if (nx != ny) return false;
    }
    return true;
}

fn measuredFor(arena: Allocator, root: []const u8, head: git_commit.Head, file_abs: []const u8) !?git_commit.Measured {
    for (head.measured) |m| {
        const abs = try std.fmt.allocPrint(arena, "{s}\\{s}", .{ root, m.path });
        if (sameFile(abs, file_abs)) return m;
    }
    return null;
}

fn sameHash(a: ?symbol.Hash, b: ?symbol.Hash) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, &a.?, &b.?);
}

fn decide(gpa: Allocator, io: std.Io, root: []const u8, head: git_commit.Head, prepared: git_commit.Prepared, changes: []const Change, pendings: []disk.Pending, tag: []const u8, lock: *?disk.Guard, staged_any: *bool, step: ?*const disk.Step) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (pendings) |*p| {
        const held_path = if (p.kind == .rename) p.source else p.path;
        if (p.kind != .create) {
            const was = (try measuredFor(arena, root, head, held_path)) orelse return error.TargetHasUncommittedChanges;
            if (!sameHash(was.raw, p.base_hash)) return error.TargetHasUncommittedChanges;
            p.base_in_history = true;
        }
    }

    const items = try arena.alloc(commit_intent.Item, changes.len);
    const contents = try arena.alloc(?[]const u8, changes.len);
    for (changes, prepared.entries, items, contents) |change, entry, *item, *content| {
        const was = head.find(entry.path) orelse return error.TargetHasUncommittedChanges;
        content.* = change.content;
        item.* = .{
            .path = entry.path,
            .mode = try arena.dupe(u8, &entry.mode),
            .blob = entry.blob orelse "",
            .base = try hex(arena, was.raw),
            .new = try hex(arena, if (change.content) |bytes| symbol.hashOf(bytes) else null),
        };
    }
    staged_any.* = true;
    try commit_intent.stage(gpa, io, root, tag, contents);
    if (disk.Step.stops(step)) return error.Crashed;

    const dir = try commit_intent.dirOf(arena, root);
    const staged_index = try commit_intent.indexPath(arena, dir, tag);
    const branch = try git_commit.branchNow(arena, io, root, head);
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const staged = try git_commit.stageChecked(gpa, io, root, head, prepared.entries, staged_index);
        try commit_intent.write(gpa, io, root, tag, .{
            .commit = prepared.commit,
            .base = head.oid,
            .branch = branch,
            .lock = &std.fmt.bytesToHex(staged.digest, .lower),
            .index_base = &std.fmt.bytesToHex(staged.base, .lower),
            .items = items,
        });
        if (disk.Step.stops(step)) return error.Crashed;
        lock.* = git_commit.acquireHeld(gpa, io, head, staged_index, staged) catch |err| {
            if (err == error.IndexChanged and attempt + 1 < index_attempts) continue;
            return err;
        };
        break;
    }
    if (disk.Step.stops(step)) return error.Crashed;
    if (!std.mem.eql(u8, branch, try git_commit.branchNow(arena, io, root, head))) return error.BranchMoved;
    try git_commit.moveBranch(gpa, io, root, branch, prepared.commit, head.oid);
}
