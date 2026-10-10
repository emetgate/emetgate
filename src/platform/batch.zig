const std = @import("std");
const symbol = @import("../engine/symbol.zig");
const shadow = @import("shadow.zig");
const shadow_root = @import("shadow_root.zig");
const sandbox = @import("sandbox.zig");
const disk = @import("disk.zig");
const repo = @import("repo.zig");
const runner = @import("runner.zig");
const rules = @import("rules.zig");
const create = @import("create.zig");
const batch_plan = @import("batch_plan.zig");
const commit_plan = @import("commit_plan.zig");
const docnode = @import("../engine/docnode.zig");
const tsserver = @import("tsserver.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;

const Allocator = std.mem.Allocator;
const Trace = runner.Trace;
const gitToplevel = repo.gitToplevel;
const relativeUnder = repo.relativeUnder;

pub const Edit = batch_plan.Edit;
pub const EditOp = batch_plan.Op;
pub const DocEdit = batch_plan.DocEdit;
pub const Prepared = batch_plan.Prepared;

pub const Committed = struct {
    hash: symbol.Hash,
    evidence: ?create.Evidence = null,
    deleted: bool = false,
};

pub const BatchOptions = struct {
    edits: []const Edit = &.{},
    doc_edits: []const DocEdit = &.{},
    test_command: []const u8,
    typecheck_command: ?[]const u8 = null,
    linked: []const []const u8 = &.{"node_modules"},
    limits: sandbox.Limits = .{},
    allow_repo_memory: bool = false,
    shadow_root: ?[]const u8 = null,
    gate_tree: shadow.Choice = .{},
    trace: ?*Trace = null,
    commit_step: ?*const disk.Step = null,
    language_service: ?*tsserver.Session = null,
    created_dirs: []const []const u8 = &.{},
    commit: ?*commit_plan.Request = null,
};

pub const BatchResult = union(enum) {
    committed: []Committed,
    rejected: sandbox.Report,
    typecheck_failed: sandbox.Report,
    rule_violation: rules.Report,
    rule_check_failed: rules.Failure,

    pub fn deinit(self: BatchResult, gpa: Allocator) void {
        switch (self) {
            .committed => |edits| gpa.free(edits),
            .rejected, .typecheck_failed => |report| report.deinit(gpa),
            .rule_violation => |report| report.deinit(gpa),
            .rule_check_failed => |failure| failure.deinit(gpa),
        }
    }
};

pub const Planned = struct {
    root: []u8,
    lock: shadow.Lock,
    prepared: std.ArrayList(Prepared),

    pub fn deinit(self: *Planned, gpa: Allocator) void {
        for (self.prepared.items) |p| p.deinit(gpa);
        self.prepared.deinit(gpa);
        self.lock.release();
        gpa.free(self.root);
    }
};

pub fn planBatch(gpa: Allocator, io: std.Io, runtime: *Runtime, options: BatchOptions) !Planned {
    if (options.test_command.len == 0) return error.NoTestCommand;
    if (options.edits.len == 0 and options.doc_edits.len == 0) return error.EmptyBatch;
    for (options.doc_edits) |edit| try docnode.refuseSource(edit.file_abs);

    const first_file = if (options.edits.len != 0) options.edits[0].file_abs else options.doc_edits[0].file_abs;
    const dir0 = std.fs.path.dirname(first_file) orelse return error.InvalidPath;
    const root = try gitToplevel(gpa, io, dir0);
    errdefer gpa.free(root);
    const lock = try shadow.Lock.acquire(io, root);
    errdefer lock.release();

    var prepared: std.ArrayList(Prepared) = .empty;
    errdefer {
        for (prepared.items) |p| p.deinit(gpa);
        prepared.deinit(gpa);
    }

    for (options.edits) |edit| {
        const rel = try relativeUnder(gpa, root, edit.file_abs);
        var keep_rel = false;
        errdefer if (!keep_rel) gpa.free(rel);
        for (prepared.items) |p| {
            if (std.ascii.eqlIgnoreCase(p.rel, rel)) return error.DuplicateBatchFile;
        }
        const planned = try batch_plan.plan(gpa, io, runtime, root, edit, rel);
        keep_rel = true;
        errdefer planned.deinit(gpa);
        try prepared.append(gpa, planned);
    }
    try batch_plan.checkDeletions(gpa, io, root, prepared.items, options.edits, options.language_service);
    return .{ .root = root, .lock = lock, .prepared = prepared };
}

pub fn tryMutateBatch(gpa: Allocator, io: std.Io, runtime: *Runtime, options: BatchOptions) !BatchResult {
    var planned = try planBatch(gpa, io, runtime, options);
    defer planned.deinit(gpa);
    return commitPlanned(gpa, io, planned.root, planned.prepared.items, options.edits, options);
}

pub fn commitPlanned(gpa: Allocator, io: std.Io, root: []const u8, prepared: []const Prepared, edits: []const Edit, options: BatchOptions) !BatchResult {
    if (options.test_command.len == 0) return error.NoTestCommand;
    var session = switch (try openCommit(gpa, io, root, prepared, options)) {
        .ok => |opened| opened,
        .violated => |report| return .{ .rule_violation = report },
        .failed => |failure| return .{ .rule_check_failed = failure },
    };
    defer session.deinit(gpa);
    {
        const judged = try gpa.alloc(rules.Change, prepared.len);
        defer gpa.free(judged);
        for (prepared, judged) |p, *slot| slot.* = changeOf(p);
        switch (try rules.judge(gpa, io, root, judged, options.allow_repo_memory)) {
            .ok => {},
            .violated => |report| return .{ .rule_violation = report },
            .failed => |failure| return .{ .rule_check_failed = failure },
        }
    }

    var doc_prepared: std.ArrayList(Prepared) = .empty;
    defer {
        for (doc_prepared.items) |p| p.deinit(gpa);
        doc_prepared.deinit(gpa);
    }
    for (options.doc_edits) |edit| {
        const rel = try relativeUnder(gpa, root, edit.file_abs);
        var keep_rel = false;
        errdefer if (!keep_rel) gpa.free(rel);
        for (prepared) |p| {
            if (std.ascii.eqlIgnoreCase(p.rel, rel)) return error.DuplicateBatchFile;
        }
        for (doc_prepared.items) |p| {
            if (std.ascii.eqlIgnoreCase(p.rel, rel)) return error.DuplicateBatchFile;
        }
        const planned = try batch_plan.planDoc(gpa, io, edit, rel);
        keep_rel = true;
        errdefer planned.deinit(gpa);
        try doc_prepared.append(gpa, planned);
    }

    const location = try shadow_root.locate(gpa, root, options.shadow_root);
    defer location.deinit(gpa);

    if (options.trace) |t| {
        var new_total: usize = 0;
        for (prepared) |p| new_total += p.source().len;
        for (doc_prepared.items) |p| new_total += p.source().len;
        t.* = .{ .gate = .full, .new_len = new_total };
    }
    const report = switch (try runBatchInShadow(gpa, io, root, location, prepared, doc_prepared.items, edits, options, &session)) {
        .typecheck => |failed| return .{ .typecheck_failed = failed },
        .rule_violation => |violated| return .{ .rule_violation = violated },
        .rule_check_failed => |failure| return .{ .rule_check_failed = failure },
        .tests => |tests| tests,
    };
    if (!report.passed()) return .{ .rejected = report };
    if (options.trace) |t| t.test_ms = report.duration_ns / std.time.ns_per_ms;
    defer report.deinit(gpa);

    const committed = try classifyAll(gpa, io, root, prepared, edits, doc_prepared.items);
    errdefer gpa.free(committed);

    const changes = try commitChanges(gpa, prepared, doc_prepared.items);
    defer gpa.free(changes);
    try session.prepare(gpa, io, root, changes);

    const total = prepared.len + doc_prepared.items.len;
    const pendings = try gpa.alloc(disk.Pending, total);
    defer gpa.free(pendings);
    var count: usize = 0;
    var commit_entered = false;
    errdefer if (!commit_entered) {
        var i = count;
        while (i > 0) {
            i -= 1;
            pendings[i].discard(null);
        }
    };
    const journal_dir = try std.fmt.allocPrint(gpa, "{s}\\{s}\\journal", .{ root, shadow.workspace_dir });
    defer gpa.free(journal_dir);
    var batch = disk.Batch.init(gpa, io, journal_dir);
    if (options.commit == null) batch.root = root;
    batch.created_dirs = options.created_dirs;
    if (options.trace) |t| t.commit_attempted = true;
    for (prepared, 0..) |p, i| {
        const file_abs = edits[i].file_abs;
        pendings[i] = switch (p.action) {
            .write, .insert, .delete_symbol => try disk.prepare(gpa, io, file_abs, p.source(), p.base_hash.?),
            .create => try disk.stageCreate(gpa, io, file_abs, p.source()),
            .delete_file => try disk.stageDelete(gpa, io, file_abs, p.base_hash.?),
            .move_file => try disk.stageRename(gpa, io, edits[i].move_source.?, file_abs, p.source(), p.base_hash.?),
            .write_doc => unreachable,
        };
        count = i + 1;
    }
    for (doc_prepared.items, 0..) |p, i| {
        const file_abs = options.doc_edits[i].file_abs;
        pendings[prepared.len + i] = try disk.prepare(gpa, io, file_abs, p.source(), p.base_hash.?);
        count = prepared.len + i + 1;
    }
    commit_entered = true;
    try session.land(gpa, io, root, changes, pendings, &batch, options.commit_step);
    return .{ .committed = committed };
}

fn changeOf(p: Prepared) rules.Change {
    return .{ .rel = p.rel, .base = p.base, .after = p.snapshot, .holes = p.holes };
}

fn openCommit(gpa: Allocator, io: std.Io, root: []const u8, prepared: []const Prepared, options: BatchOptions) !commit_plan.Opened {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var rels: std.ArrayList([]const u8) = .empty;
    for (prepared) |p| {
        try rels.append(arena, p.rel);
        if (p.source_rel) |from| try rels.append(arena, from);
    }
    for (options.doc_edits) |edit| try rels.append(arena, try relativeUnder(arena, root, edit.file_abs));
    return commit_plan.Session.open(gpa, io, root, options.commit, rels.items);
}

fn commitChanges(gpa: Allocator, prepared: []const Prepared, doc_prepared: []const Prepared) ![]commit_plan.Change {
    var changes: std.ArrayList(commit_plan.Change) = .empty;
    errdefer changes.deinit(gpa);
    for (prepared) |p| {
        if (p.source_rel) |from| try changes.append(gpa, .{ .rel = from, .content = null });
        try changes.append(gpa, .{ .rel = p.rel, .content = if (p.action == .delete_file) null else p.source(), .mode_from = p.source_rel });
    }
    for (doc_prepared) |p| try changes.append(gpa, .{ .rel = p.rel, .content = p.source() });
    return changes.toOwnedSlice(gpa);
}

fn classifyAll(gpa: Allocator, io: std.Io, root: []const u8, prepared: []const Prepared, edits: []const Edit, doc_prepared: []const Prepared) ![]Committed {
    const sources = try gpa.alloc(create.Source, prepared.len);
    defer gpa.free(sources);
    for (prepared, 0..) |p, i| sources[i] = .{ .rel = p.rel, .text = p.source() };
    const committed = try gpa.alloc(Committed, prepared.len + doc_prepared.len);
    errdefer gpa.free(committed);
    for (prepared, 0..) |p, i| {
        committed[i] = .{ .hash = p.hash, .deleted = p.isDeletion() };
        if (p.action != .insert and p.action != .create) continue;
        if (edits[i].ref_text.len == 0) continue;
        const ref = try symbol.Ref.parse(gpa, edits[i].ref_text);
        defer ref.deinit(gpa);
        committed[i].evidence = try create.classify(gpa, io, root, sources, .{
            .index = i,
            .snapshot = p.snapshot.?,
            .slot = p.body,
            .name = ref.name,
            .creates = p.action == .create,
        });
    }
    for (doc_prepared, 0..) |p, i| {
        committed[prepared.len + i] = .{ .hash = p.hash, .deleted = false };
    }
    return committed;
}

fn runBatchInShadow(gpa: Allocator, io: std.Io, root: []const u8, location: shadow_root.Location, prepared: []const Prepared, doc_prepared: []const Prepared, edits: []const Edit, options: BatchOptions, session: *commit_plan.Session) !runner.ShadowRun {
    var workspace = try runner.openShadow(gpa, io, root, location, options.linked, options.gate_tree, options.trace, session);
    defer workspace.finish();
    if (try runner.runMessageRules(gpa, io, root, runner.gateDir(location, session), session.message(), options.limits, options.allow_repo_memory)) |gated| return gated;
    for (prepared) |p| {
        if (p.source_rel) |from| try workspace.deleteFile(from);
        if (p.action == .delete_file) try workspace.deleteFile(p.rel) else try workspace.writeFile(p.rel, p.source());
    }
    for (doc_prepared) |p| try workspace.writeFile(p.rel, p.source());
    {
        const changes = try commitChanges(gpa, prepared, doc_prepared);
        defer gpa.free(changes);
        try runner.deriveGate(gpa, io, root, location, session, changes);
    }

    var wanted: usize = prepared.len;
    for (prepared) |p| {
        if (p.nodes) |applied| wanted += applied.units.len;
    }
    const targets = try gpa.alloc(rules.Target, wanted);
    defer gpa.free(targets);
    var built: usize = 0;
    defer for (targets[0..built]) |target| target.ref.deinit(gpa);
    for (prepared, edits[0..prepared.len]) |p, edit| {
        if (p.nodes) |applied| {
            for (applied.units) |unit| {
                if (!unit.checked()) continue;
                targets[built] = .{ .file = p.rel, .ref = try unit.parseRef(gpa) };
                built += 1;
            }
            continue;
        }
        if (!p.addsCode() or edit.ref_text.len == 0) continue;
        targets[built] = .{ .file = p.rel, .ref = try symbol.Ref.parse(gpa, edit.ref_text) };
        built += 1;
    }
    if (try runner.runCommandRulesFor(gpa, io, root, runner.gateDir(location, session), targets[0..built], null, options.limits, options.allow_repo_memory)) |gated| return gated;

    return runner.runStages(gpa, io, runner.gateDir(location, session), options.typecheck_command, options.test_command, options.limits);
}
