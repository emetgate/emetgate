const std = @import("std");
const symbol = @import("../engine/symbol.zig");
const cas = @import("../engine/cas.zig");
const shadow = @import("shadow.zig");
const sandbox = @import("sandbox.zig");
const disk = @import("disk.zig");
const repo = @import("repo.zig");
const runner = @import("runner.zig");
const rules = @import("rules.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;
const Snapshot = @import("../engine/loader.zig").Snapshot;

const Allocator = std.mem.Allocator;
const Trace = runner.Trace;
const gitToplevel = repo.gitToplevel;
const relativeUnder = repo.relativeUnder;

pub const Edit = struct {
    file_abs: []const u8,
    ref_text: []const u8,
    expected_hash: symbol.Hash,
    new_body: []const u8,
};

pub const BatchOptions = struct {
    edits: []const Edit,
    test_command: []const u8,
    typecheck_command: ?[]const u8 = null,
    linked: []const []const u8 = &.{"node_modules"},
    limits: sandbox.Limits = .{},
    allow_repo_memory: bool = false,
    trace: ?*Trace = null,
};

pub const BatchResult = union(enum) {
    committed: []symbol.Hash,
    rejected: sandbox.Report,
    typecheck_failed: sandbox.Report,
    rule_violation: rules.Report,
    rule_check_failed: rules.Failure,

    pub fn deinit(self: BatchResult, gpa: Allocator) void {
        switch (self) {
            .committed => |hashes| gpa.free(hashes),
            .rejected, .typecheck_failed => |report| report.deinit(gpa),
            .rule_violation => |report| report.deinit(gpa),
            .rule_check_failed => |failure| failure.deinit(gpa),
        }
    }
};

const Prepared = struct {
    rel: []u8,
    base_hash: symbol.Hash,
    applied: cas.Applied,
};

pub fn tryMutateBatch(gpa: Allocator, io: std.Io, runtime: *Runtime, options: BatchOptions) !BatchResult {
    if (options.test_command.len == 0) return error.NoTestCommand;
    if (options.edits.len == 0) return error.EmptyBatch;

    const dir0 = std.fs.path.dirname(options.edits[0].file_abs) orelse return error.InvalidPath;
    const root = try gitToplevel(gpa, io, dir0);
    defer gpa.free(root);
    const lock = try shadow.Lock.acquire(io, root);
    defer lock.release();

    var prepared: std.ArrayList(Prepared) = .empty;
    defer {
        for (prepared.items) |*p| {
            p.applied.snapshot.destroy();
            gpa.free(p.rel);
        }
        prepared.deinit(gpa);
    }

    for (options.edits) |edit| {
        const rel = try relativeUnder(gpa, root, edit.file_abs);
        var keep_rel = false;
        errdefer if (!keep_rel) gpa.free(rel);
        for (prepared.items) |p| {
            if (std.ascii.eqlIgnoreCase(p.rel, rel)) return error.DuplicateBatchFile;
        }

        var base_hash: symbol.Hash = undefined;
        const applied = blk: {
            const base = try Snapshot.load(runtime, io, .cwd(), edit.file_abs);
            defer base.destroy();
            if (base.tree.root().hasError()) return error.SourceHasErrors;
            base_hash = symbol.hashOf(base.source);
            const ref = try symbol.Ref.parse(gpa, edit.ref_text);
            defer ref.deinit(gpa);
            break :blk try cas.apply(base, .{ .ref = ref, .expected_hash = edit.expected_hash, .new_body = edit.new_body });
        };
        errdefer applied.snapshot.destroy();
        try prepared.append(gpa, .{ .rel = rel, .base_hash = base_hash, .applied = applied });
        keep_rel = true;
    }

    for (prepared.items, options.edits[0..prepared.items.len]) |p, edit| {
        const ref = try symbol.Ref.parse(gpa, edit.ref_text);
        defer ref.deinit(gpa);
        if (try rules.gate(gpa, io, root, p.rel, ref, p.applied.snapshot.profile, p.applied.snapshot.tree, p.applied.body)) |report| return .{ .rule_violation = report };
    }

    const shadow_abs = try std.fmt.allocPrint(gpa, "{s}\\{s}\\shadow", .{ root, shadow.workspace_dir });
    defer gpa.free(shadow_abs);

    if (options.trace) |t| {
        var new_total: usize = 0;
        for (prepared.items) |p| new_total += p.applied.snapshot.source.len;
        t.* = .{ .gate = .full, .new_len = new_total };
    }
    const report = switch (try runBatchInShadow(gpa, io, root, shadow_abs, prepared.items, options)) {
        .typecheck => |failed| return .{ .typecheck_failed = failed },
        .rule_violation => |violated| return .{ .rule_violation = violated },
        .rule_check_failed => |failure| return .{ .rule_check_failed = failure },
        .tests => |tests| tests,
    };
    if (!report.passed()) return .{ .rejected = report };
    defer report.deinit(gpa);

    const pendings = try gpa.alloc(disk.Pending, prepared.items.len);
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
    if (options.trace) |t| t.commit_attempted = true;
    for (prepared.items, 0..) |p, i| {
        pendings[i] = try disk.prepare(gpa, io, options.edits[i].file_abs, p.applied.snapshot.source, p.base_hash, journal_dir);
        count = i + 1;
    }
    commit_entered = true;
    try disk.commitBatch(pendings, null, null);

    const hashes = try gpa.alloc(symbol.Hash, prepared.items.len);
    for (prepared.items, 0..) |p, i| hashes[i] = p.applied.hash;
    return .{ .committed = hashes };
}

fn runBatchInShadow(gpa: Allocator, io: std.Io, root: []const u8, shadow_abs: []const u8, prepared: []const Prepared, options: BatchOptions) !runner.ShadowRun {
    const files = try shadow.trackedFiles(gpa, io, root);
    defer gpa.free(files);
    defer shadow.freeFileList(gpa, files);

    var workspace = try shadow.Shadow.prepare(io, .{
        .root_abs = root,
        .shadow_abs = shadow_abs,
        .files = files,
        .linked = options.linked,
    });
    defer {
        workspace.close();
        shadow.remove(io, root, shadow_abs) catch {};
    }
    for (prepared) |p| try workspace.writeFile(p.rel, p.applied.snapshot.source);

    const targets = try gpa.alloc(rules.Target, prepared.len);
    defer gpa.free(targets);
    var built: usize = 0;
    defer for (targets[0..built]) |target| target.ref.deinit(gpa);
    for (prepared, options.edits[0..prepared.len]) |p, edit| {
        targets[built] = .{ .file = p.rel, .ref = try symbol.Ref.parse(gpa, edit.ref_text) };
        built += 1;
    }
    if (try runner.runCommandRules(gpa, io, root, shadow_abs, targets, options.limits, options.allow_repo_memory)) |gated| return gated;

    return runner.runStages(gpa, io, shadow_abs, options.typecheck_command, options.test_command, options.limits);
}
