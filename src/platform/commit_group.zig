//! Manual, verified commit of the pending gated changes.
//!
//! Every gated write already leaves a stored receipt under `.emetgate/receipts/`
//! (see `receipts.write`), even when the server runs with commits off. This
//! module groups those pending receipts into ONE commit: it reads the files they
//! attest, checks the working tree still matches each receipt byte for byte
//! (fail-closed on drift — never silently re-gate), builds a single commit from
//! HEAD with the already-gated content, and chains + attaches the pending
//! receipts as its note. It reuses the evidence; it never re-runs the typecheck
//! or tests. `emetgate verify --branch` then replays that note and returns
//! "verified".

const std = @import("std");
const receipt = @import("../verify/receipt.zig");
const receipts = @import("receipts.zig");
const jcs = @import("../verify/jcs.zig");
const shadow = @import("shadow.zig");
const shadow_root = @import("shadow_root.zig");
const runner = @import("runner.zig");
const commit_plan = @import("commit_plan.zig");
const commit_refusal = @import("commit_refusal.zig");
const disk = @import("disk.zig");
const repo = @import("repo.zig");
const rules = @import("rules.zig");
const own_dir = @import("own_dir.zig");
const git_commit = @import("git_commit.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;

const Allocator = std.mem.Allocator;
const Hash = receipt.Hash;

const max_receipt_bytes = 16 * 1024 * 1024;
const shown_paths = 64;

pub const Options = struct {
    message: []const u8,
    shadow_root: ?[]const u8 = null,
    gate_tree: shadow.Choice = .{},
    linked: []const []const u8 = &shadow.dependency_dirs,
    runtime: ?*Runtime = null,
};

pub const Committed = struct {
    oid: []u8,
    base: []u8,
    files: usize,
    receipts: usize,

    pub fn deinit(self: Committed, gpa: Allocator) void {
        gpa.free(self.oid);
        gpa.free(self.base);
    }
};

/// The files whose working-tree content no longer matches the receipt that
/// last attested them — edited outside the gate. The commit is refused.
pub const Drift = struct {
    paths: [][]u8,
    total: usize,

    pub fn deinit(self: Drift, gpa: Allocator) void {
        for (self.paths) |p| gpa.free(p);
        gpa.free(self.paths);
    }
};

pub const Result = union(enum) {
    committed: Committed,
    nothing_pending,
    drift: Drift,
    rule_violation: rules.Report,
    rule_check_failed: rules.Failure,

    pub fn deinit(self: Result, gpa: Allocator) void {
        switch (self) {
            .committed => |c| c.deinit(gpa),
            .nothing_pending => {},
            .drift => |d| d.deinit(gpa),
            .rule_violation => |r| r.deinit(gpa),
            .rule_check_failed => |f| f.deinit(gpa),
        }
    }
};

/// One file the pending receipts attest, with the digest the latest receipt
/// claims for it. `after == null` means the receipts attest a deletion.
const Attested = struct {
    rel: []u8,
    after: ?Hash,
};

/// Gather the distinct files the pending (not-yet-attached) receipts attest,
/// keeping the digest claimed by the last receipt (in filename/time order) to
/// touch each path — that is the tip of the chain for the file.
fn attested(arena: Allocator, io: std.Io, root: []const u8) !?[]Attested {
    const dir_abs = try std.fmt.allocPrint(arena, "{s}\\{s}\\{s}", .{ root, shadow.workspace_dir, receipts.receipts_dir });
    var names: std.ArrayList([]const u8) = .empty;
    const held = (try own_dir.hold(io, dir_abs, .existing)) orelse return null;
    defer held.close();
    {
        var it = held.dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
            try names.append(arena, try arena.dupe(u8, entry.name));
        }
    }
    if (names.items.len == 0) return null;
    std.mem.sort([]const u8, names.items, {}, lessString);

    var list: std.ArrayList(Attested) = .empty;
    for (names.items) |name| {
        const bytes = held.dir.readFileAlloc(io, name, arena, .limited(max_receipt_bytes)) catch continue;
        const parsed = jcs.parse(arena, bytes) catch continue;
        const r = receipt.fromValue(arena, parsed.value) catch continue;
        for (r.files) |f| {
            const rel = try backslashed(arena, f.path);
            try put(arena, &list, rel, f.after);
        }
    }
    if (list.items.len == 0) return null;
    return list.items;
}

fn put(arena: Allocator, list: *std.ArrayList(Attested), rel: []u8, after: ?Hash) !void {
    for (list.items) |*item| {
        if (eqlPath(item.rel, rel)) {
            item.after = after;
            return;
        }
    }
    try list.append(arena, .{ .rel = rel, .after = after });
}

fn eqlPath(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const nx: u8 = if (x == '/') '\\' else x;
        const ny: u8 = if (y == '/') '\\' else y;
        if (nx != ny) return false;
    }
    return true;
}

fn backslashed(arena: Allocator, rel: []const u8) ![]u8 {
    const out = try arena.dupe(u8, rel);
    std.mem.replaceScalar(u8, out, '/', '\\');
    return out;
}

/// Build one commit from the pending gated changes.
pub fn commit(gpa: Allocator, io: std.Io, root: []const u8, options: Options) !Result {
    const lock = try shadow.Lock.acquire(io, root);
    defer lock.release();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const items = (try attested(arena, io, root)) orelse return .nothing_pending;

    // Drift check (fail-closed): the working tree must still equal every digest
    // the latest receipt attests. Collect the files that do not, and refuse.
    var changes: std.ArrayList(commit_plan.Change) = .empty;
    var rels: std.ArrayList([]const u8) = .empty;
    var drifted: std.ArrayList([]const u8) = .empty;
    for (items) |item| {
        const abs = try std.fs.path.join(arena, &.{ root, item.rel });
        const bytes: ?[]u8 = std.Io.Dir.cwd().readFileAlloc(io, abs, arena, .limited(git_commit.max_index_bytes)) catch |err| switch (err) {
            error.FileNotFound => null,
            error.OutOfMemory => return error.OutOfMemory,
            else => return err,
        };
        const matches = if (item.after) |want|
            bytes != null and std.mem.eql(u8, &receipt.blake3(bytes.?), &want)
        else
            bytes == null;
        if (!matches) {
            try drifted.append(arena, try receipts.slashed(arena, item.rel));
            continue;
        }
        try changes.append(arena, .{ .rel = item.rel, .content = bytes });
        try rels.append(arena, item.rel);
    }
    if (drifted.items.len != 0) {
        commit_refusal.note(drifted.items, drifted.items.len);
        const shown = @min(drifted.items.len, shown_paths);
        const paths = try gpa.alloc([]u8, shown);
        var copied: usize = 0;
        errdefer {
            for (paths[0..copied]) |p| gpa.free(p);
            gpa.free(paths);
        }
        for (paths, drifted.items[0..shown]) |*slot, rel| {
            slot.* = try gpa.dupe(u8, rel);
            copied += 1;
        }
        return .{ .drift = .{ .paths = paths, .total = drifted.items.len } };
    }
    if (changes.items.len == 0) return .nothing_pending;

    var request: commit_plan.Request = .{ .message = options.message, .runtime = options.runtime };
    defer request.deinit(gpa);

    // Mirror commit_plan.Session.open, but admit the gate-written working tree:
    // the frozen-file and commit-message rule gates still run, and the commit is
    // built from HEAD, yet preflight tolerates the already-written content.
    switch (try rules.frozenGate(gpa, io, root, rels.items)) {
        .ok => {},
        .violated => |report| return .{ .rule_violation = report },
        .failed => |failure| return .{ .rule_check_failed = failure },
    }
    switch (try rules.messageGate(gpa, io, root, options.message)) {
        .ok => {},
        .violated => |report| return .{ .rule_violation = report },
        .failed => |failure| return .{ .rule_check_failed = failure },
    }
    commit_plan.noteFound(try commit_plan.recoverFound(gpa, io, root));
    var session: commit_plan.Session = .{ .request = &request, .head = try git_commit.preflightWritten(gpa, io, root, rels.items) };
    defer session.deinit(gpa);

    // Rebuild the HEAD tree in the shadow, lay the gated content on top of it,
    // and derive the committed tree from there. Reuses the GateTreeNotHead drift
    // guard: if HEAD moved or a tracked file no longer matches HEAD, this fails.
    const location = try shadow_root.locate(gpa, root, options.shadow_root);
    defer location.deinit(gpa);
    var workspace = try runner.openShadow(gpa, io, root, location, options.linked, options.gate_tree, null, &session);
    defer workspace.finish();
    for (changes.items) |change| {
        if (change.content) |bytes| try workspace.writeFile(change.rel, bytes) else try workspace.deleteFile(change.rel);
    }
    try runner.deriveGate(gpa, io, root, location, &session, changes.items);
    try session.prepare(gpa, io, root, changes.items);
    // The working tree already holds the gated content, so the commit moves only
    // HEAD/branch/index — no file pendings to replay.
    try session.land(gpa, io, root, changes.items, &.{}, null, null);

    const oid = request.oid orelse return error.CommitNotLanded;
    const base = request.base.?;

    // Chain + attach every pending receipt whose files this commit carries.
    const attached = try receipts.attach(gpa, io, root, oid);

    return .{ .committed = .{
        .oid = try gpa.dupe(u8, oid),
        .base = try gpa.dupe(u8, base),
        .files = changes.items.len,
        .receipts = attached.count,
    } };
}

fn lessString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}
