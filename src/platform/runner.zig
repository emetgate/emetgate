const std = @import("std");
const symbol = @import("../engine/symbol.zig");
const cas = @import("../engine/cas.zig");
const boundedness = @import("../engine/boundedness.zig");
const shadow = @import("shadow.zig");
const sandbox = @import("sandbox.zig");
const disk = @import("disk.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;
const Snapshot = @import("../engine/loader.zig").Snapshot;

const Allocator = std.mem.Allocator;
const max_git_output = 64 * 1024;

pub const Options = struct {
    file_abs: []const u8,
    ref_text: []const u8,
    expected_hash: symbol.Hash,
    new_body: []const u8,
    test_command: []const u8,
    test_scoped_cmd: ?[]const u8 = null,
    linked: []const []const u8 = &.{"node_modules"},
    limits: sandbox.Limits = .{},
    trace: ?*Trace = null,
};

pub const Trace = struct {
    gate: ?Gate = null,
    confidence: ?boundedness.Confidence = null,
    provenance: ?boundedness.Provenance = null,
    class: ?boundedness.MutationClass = null,
    base_len: ?usize = null,
    new_len: ?usize = null,
    old_body_len: ?usize = null,
    commit_attempted: bool = false,
};

pub const Result = union(enum) {
    committed: symbol.Hash,
    rejected: sandbox.Report,

    pub fn deinit(self: Result, gpa: Allocator) void {
        switch (self) {
            .committed => {},
            .rejected => |report| report.deinit(gpa),
        }
    }
};

pub const config_file = ".synapserc.json";

pub fn repoRoot(gpa: Allocator, io: std.Io) ![]u8 {
    return gitToplevel(gpa, io, ".");
}

pub fn assertUnderCwdRepo(gpa: Allocator, io: std.Io, file_abs: []const u8) !void {
    const root = try gitToplevel(gpa, io, ".");
    defer gpa.free(root);
    const rel = try relativeUnder(gpa, root, file_abs);
    gpa.free(rel);
}

pub fn repoRelative(gpa: Allocator, io: std.Io, path_abs: []const u8) ![]u8 {
    const root = try gitToplevel(gpa, io, ".");
    defer gpa.free(root);
    const normalized = try gpa.dupe(u8, path_abs);
    defer gpa.free(normalized);
    std.mem.replaceScalar(u8, normalized, '/', '\\');
    if (std.ascii.eqlIgnoreCase(normalized, root)) return gpa.dupe(u8, "");
    return relativeUnder(gpa, root, normalized);
}

pub fn resolveTestCommand(gpa: Allocator, io: std.Io, file_abs: []const u8, given: []const u8, allow_repo_config: bool) ![]u8 {
    if (given.len != 0) return gpa.dupe(u8, given);

    const dir = std.fs.path.dirname(file_abs) orelse return error.InvalidPath;
    const root = try gitToplevel(gpa, io, dir);
    defer gpa.free(root);
    const repo_path = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ root, config_file });
    defer gpa.free(repo_path);

    if (!allow_repo_config) {
        if (try fileExists(io, repo_path)) return error.UntrustedRepoConfig;
        return error.NoTestCommand;
    }
    return (try readConfigCommand(gpa, io, repo_path)) orelse error.NoTestCommand;
}

fn readConfigCommand(gpa: Allocator, io: std.Io, path: []const u8) !?[]u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer gpa.free(bytes);
    const parsed = std.json.parseFromSlice(struct { test_cmd: ?[]const u8 = null }, gpa, bytes, .{ .ignore_unknown_fields = true }) catch return error.InvalidConfig;
    defer parsed.deinit();
    const cmd = parsed.value.test_cmd orelse return null;
    if (cmd.len == 0) return null;
    return try gpa.dupe(u8, cmd);
}

fn fileExists(io: std.Io, path: []const u8) !bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

pub const Gate = enum { full, scoped };

// Safety-valve default (no scoped cmd): boundedness is telemetry, not control —
// BOUNDED and UNBOUNDED both run the full test_command, behavior unchanged; teeth
// come only from the scoped path. The scoped path is a softer guarantee: it trusts
// the runner's related-test (import-graph) heuristic, blind to dynamic import / DI /
// reflection. Prefer the full command when tests reach code dynamically; scoped is
// a trade-off the user opts into explicitly. Fast-path opens only for BOUNDED.
pub fn chooseGate(confidence: boundedness.Confidence, has_scoped: bool) Gate {
    if (confidence == .bounded and has_scoped) return .scoped;
    return .full;
}

fn substituteFile(gpa: Allocator, template: []const u8, rel: []const u8) ![]u8 {
    const needle = "{file}";
    const count = std.mem.count(u8, template, needle);
    if (count == 0) return gpa.dupe(u8, template);
    const out = try gpa.alloc(u8, template.len - count * needle.len + count * rel.len);
    _ = std.mem.replace(u8, template, needle, rel, out);
    return out;
}

pub fn tryMutate(gpa: Allocator, io: std.Io, runtime: *Runtime, options: Options) !Result {
    if (options.test_command.len == 0) return error.NoTestCommand;
    const dir = std.fs.path.dirname(options.file_abs) orelse return error.InvalidPath;
    const root = try gitToplevel(gpa, io, dir);
    defer gpa.free(root);
    const lock = try shadow.Lock.acquire(io, root);
    defer lock.release();
    const rel = try relativeUnder(gpa, root, options.file_abs);
    defer gpa.free(rel);

    const base = try Snapshot.load(runtime, io, .cwd(), options.file_abs);
    defer base.destroy();
    if (base.tree.root().hasError()) return error.SourceHasErrors;
    const base_hash = symbol.hashOf(base.source);

    const ref = try symbol.Ref.parse(gpa, options.ref_text);
    defer ref.deinit(gpa);
    const applied = try cas.apply(base, .{ .ref = ref, .expected_hash = options.expected_hash, .new_body = options.new_body });
    defer applied.snapshot.destroy();

    const shadow_abs = try std.fmt.allocPrint(gpa, "{s}\\{s}\\shadow", .{ root, shadow.workspace_dir });
    defer gpa.free(shadow_abs);

    const analysis_target = try (try base.symbols()).resolve(ref);
    const cut: symbol.Span = .{ .start = analysis_target.body.startByte(), .end = analysis_target.body.endByte() };
    const frame = boundedness.analyze(gpa, base, ref, cut);
    defer frame.deinit();
    const gate = chooseGate(frame.confidence, options.test_scoped_cmd != null);
    if (options.trace) |t| t.* = .{
        .gate = gate,
        .confidence = frame.confidence,
        .provenance = frame.provenance,
        .class = frame.mutation_class,
        .base_len = base.source.len,
        .new_len = applied.snapshot.source.len,
        .old_body_len = cut.end - cut.start,
    };
    const scoped_owned: ?[]u8 = if (gate == .scoped)
        try substituteFile(gpa, options.test_scoped_cmd.?, rel)
    else
        null;
    defer if (scoped_owned) |s| gpa.free(s);
    const command = scoped_owned orelse options.test_command;

    const report = try runInShadow(gpa, io, root, shadow_abs, rel, applied.snapshot.source, options, command);

    if (!report.passed()) return .{ .rejected = report };
    defer report.deinit(gpa);
    const journal_dir = try std.fmt.allocPrint(gpa, "{s}\\{s}\\journal", .{ root, shadow.workspace_dir });
    defer gpa.free(journal_dir);
    if (options.trace) |t| t.commit_attempted = true;
    try disk.replaceReporting(gpa, io, options.file_abs, applied.snapshot.source, base_hash, null, journal_dir);
    return .{ .committed = applied.hash };
}

pub const Edit = struct {
    file_abs: []const u8,
    ref_text: []const u8,
    expected_hash: symbol.Hash,
    new_body: []const u8,
};

pub const BatchOptions = struct {
    edits: []const Edit,
    test_command: []const u8,
    linked: []const []const u8 = &.{"node_modules"},
    limits: sandbox.Limits = .{},
    trace: ?*Trace = null,
};

pub const BatchResult = union(enum) {
    committed: []symbol.Hash,
    rejected: sandbox.Report,

    pub fn deinit(self: BatchResult, gpa: Allocator) void {
        switch (self) {
            .committed => |hashes| gpa.free(hashes),
            .rejected => |report| report.deinit(gpa),
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

    const shadow_abs = try std.fmt.allocPrint(gpa, "{s}\\{s}\\shadow", .{ root, shadow.workspace_dir });
    defer gpa.free(shadow_abs);

    if (options.trace) |t| {
        var new_total: usize = 0;
        for (prepared.items) |p| new_total += p.applied.snapshot.source.len;
        t.* = .{ .gate = .full, .new_len = new_total };
    }
    const report = try runBatchInShadow(gpa, io, root, shadow_abs, prepared.items, options);
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

fn runBatchInShadow(gpa: Allocator, io: std.Io, root: []const u8, shadow_abs: []const u8, prepared: []const Prepared, options: BatchOptions) !sandbox.Report {
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

    const argv = [_][]const u8{ "cmd.exe", "/d", "/c", options.test_command };
    return sandbox.run(gpa, io, .{ .argv = &argv, .cwd = shadow_abs, .limits = options.limits });
}

fn runInShadow(gpa: Allocator, io: std.Io, root: []const u8, shadow_abs: []const u8, rel: []const u8, patched: []const u8, options: Options, command: []const u8) !sandbox.Report {
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
    try workspace.writeFile(rel, patched);

    const argv = [_][]const u8{ "cmd.exe", "/d", "/c", command };
    return sandbox.run(gpa, io, .{ .argv = &argv, .cwd = shadow_abs, .limits = options.limits });
}

pub fn relativeUnder(gpa: Allocator, root: []const u8, file_abs: []const u8) ![]u8 {
    const normalized = try gpa.dupe(u8, file_abs);
    defer gpa.free(normalized);
    std.mem.replaceScalar(u8, normalized, '/', '\\');
    if (normalized.len <= root.len or !std.ascii.startsWithIgnoreCase(normalized, root) or normalized[root.len] != '\\') {
        return error.FileOutsideRepo;
    }
    return gpa.dupe(u8, normalized[root.len + 1 ..]);
}

fn gitToplevel(gpa: Allocator, io: std.Io, dir_abs: []const u8) ![]u8 {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "git", "rev-parse", "--show-toplevel" },
        .cwd = .{ .path = dir_abs },
        .stdout_limit = .limited(max_git_output),
    }) catch return error.GitFailed;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.NotInRepo,
        else => return error.GitFailed,
    }
    const trimmed = std.mem.trim(u8, result.stdout, " \r\n");
    const owned = try gpa.dupe(u8, trimmed);
    std.mem.replaceScalar(u8, owned, '/', '\\');
    return owned;
}

