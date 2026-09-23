const std = @import("std");
const symbol = @import("../engine/symbol.zig");
const cas = @import("../engine/cas.zig");
const boundedness = @import("../engine/boundedness.zig");
const shadow = @import("shadow.zig");
const sandbox = @import("sandbox.zig");
const disk = @import("disk.zig");
const repo = @import("repo.zig");
const test_command_mod = @import("test_command.zig");
const gate_mod = @import("gate.zig");
const batch = @import("batch.zig");
const rules = @import("rules.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;
const Snapshot = @import("../engine/loader.zig").Snapshot;
const registry = @import("../engine/lang/registry.zig");

const Allocator = std.mem.Allocator;

pub const config_file = test_command_mod.config_file;
pub const repoRoot = repo.repoRoot;
pub const relativeUnder = repo.relativeUnder;
pub const Jailed = repo.Jailed;
pub const jailNew = repo.jailNew;
pub const resolveTestCommand = test_command_mod.resolveTestCommand;
pub const resolveTypecheckCommand = test_command_mod.resolveTypecheckCommand;
pub const Gate = gate_mod.Gate;
pub const chooseGate = gate_mod.chooseGate;
pub const Edit = batch.Edit;
pub const BatchOptions = batch.BatchOptions;
pub const BatchResult = batch.BatchResult;
pub const tryMutateBatch = batch.tryMutateBatch;
const gitToplevel = repo.gitToplevel;
const substituteFile = gate_mod.substituteFile;

pub const Options = struct {
    file_abs: []const u8,
    ref_text: []const u8,
    expected_hash: symbol.Expected,
    new_body: []const u8,
    test_command: []const u8,
    test_scoped_cmd: ?[]const u8 = null,
    typecheck_command: ?[]const u8 = null,
    linked: []const []const u8 = &.{"node_modules"},
    limits: sandbox.Limits = .{},
    allow_repo_memory: bool = false,
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
    typecheck_failed: sandbox.Report,
    rule_violation: rules.Report,
    rule_check_failed: rules.Failure,

    pub fn deinit(self: Result, gpa: Allocator) void {
        switch (self) {
            .committed => {},
            .rejected, .typecheck_failed => |report| report.deinit(gpa),
            .rule_violation => |report| report.deinit(gpa),
            .rule_check_failed => |failure| failure.deinit(gpa),
        }
    }
};

pub const ShadowRun = union(enum) {
    typecheck: sandbox.Report,
    tests: sandbox.Report,
    rule_violation: rules.Report,
    rule_check_failed: rules.Failure,
};

pub fn runCommandRules(gpa: Allocator, io: std.Io, root: []const u8, shadow_abs: []const u8, targets: []const rules.Target, limits: sandbox.Limits, allow_repo_memory: bool) !?ShadowRun {
    const gated = try rules.commandGate(gpa, io, root, targets, .{ .shadow_abs = shadow_abs, .limits = limits, .allow_repo_memory = allow_repo_memory });
    return switch (gated) {
        .ok => null,
        .violated => |report| .{ .rule_violation = report },
        .failed => |failure| .{ .rule_check_failed = failure },
    };
}

pub fn runStages(gpa: Allocator, io: std.Io, cwd: []const u8, typecheck_command: ?[]const u8, test_command: []const u8, limits: sandbox.Limits) !ShadowRun {
    if (typecheck_command) |typecheck| {
        const checked = try runCommand(gpa, io, cwd, typecheck, limits);
        if (!checked.passed()) return .{ .typecheck = checked };
        checked.deinit(gpa);
    }
    return .{ .tests = try runCommand(gpa, io, cwd, test_command, limits) };
}

fn runCommand(gpa: Allocator, io: std.Io, cwd: []const u8, command: []const u8, limits: sandbox.Limits) !sandbox.Report {
    const argv = [_][]const u8{ "cmd.exe", "/d", "/c", command };
    return sandbox.run(gpa, io, .{ .argv = &argv, .cwd = cwd, .limits = limits });
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
    if (options.expected_hash == .absent and !try fileExists(io, options.file_abs)) return tryCreate(gpa, io, runtime, options, root, rel);

    const base = try Snapshot.load(runtime, io, .cwd(), options.file_abs);
    defer base.destroy();
    if (base.tree.root().hasError()) return error.SourceHasErrors;
    const base_hash = symbol.hashOf(base.source);

    const ref = try symbol.Ref.parse(gpa, options.ref_text);
    defer ref.deinit(gpa);
    const applied = try cas.propose(base, ref, options.expected_hash, options.new_body);
    defer applied.snapshot.destroy();
    if (try rules.gate(gpa, io, root, rel, ref, applied.snapshot.profile, applied.snapshot.tree, applied.body)) |report| return .{ .rule_violation = report };

    const shadow_abs = try std.fmt.allocPrint(gpa, "{s}\\{s}\\shadow", .{ root, shadow.workspace_dir });
    defer gpa.free(shadow_abs);

    var gate: Gate = .full;
    if (options.expected_hash == .present) {
        const analysis_target = try (try base.symbols()).resolve(ref);
        const cut: symbol.Span = .{ .start = analysis_target.body.startByte(), .end = analysis_target.body.endByte() };
        const frame = boundedness.analyze(gpa, base, ref, cut);
        defer frame.deinit();
        gate = chooseGate(frame.confidence, options.test_scoped_cmd != null);
        if (options.trace) |t| t.* = .{
            .gate = gate,
            .confidence = frame.confidence,
            .provenance = frame.provenance,
            .class = frame.mutation_class,
            .base_len = base.source.len,
            .new_len = applied.snapshot.source.len,
            .old_body_len = cut.end - cut.start,
        };
    } else if (options.trace) |t| t.* = .{
        .gate = gate,
        .base_len = base.source.len,
        .new_len = applied.snapshot.source.len,
    };
    const scoped_owned: ?[]u8 = if (gate == .scoped)
        try substituteFile(gpa, options.test_scoped_cmd.?, rel)
    else
        null;
    defer if (scoped_owned) |s| gpa.free(s);
    const command = scoped_owned orelse options.test_command;

    const report = switch (try runInShadow(gpa, io, root, shadow_abs, rel, applied.snapshot.source, options, command, &.{.{ .file = rel, .ref = ref }})) {
        .typecheck => |failed| return .{ .typecheck_failed = failed },
        .rule_violation => |report| return .{ .rule_violation = report },
        .rule_check_failed => |failure| return .{ .rule_check_failed = failure },
        .tests => |tests| tests,
    };

    if (!report.passed()) return .{ .rejected = report };
    defer report.deinit(gpa);
    const journal_dir = try std.fmt.allocPrint(gpa, "{s}\\{s}\\journal", .{ root, shadow.workspace_dir });
    defer gpa.free(journal_dir);
    if (options.trace) |t| t.commit_attempted = true;
    try disk.replaceReporting(gpa, io, options.file_abs, applied.snapshot.source, base_hash, null, journal_dir);
    return .{ .committed = applied.hash };
}

pub fn prepareCreate(gpa: Allocator, io: std.Io, runtime: *Runtime, root: []const u8, file_abs: []const u8, rel: []const u8, ref: symbol.Ref, new_body: []const u8) !cas.Applied {
    const profile = registry.forPath(file_abs) orelse return error.UnsupportedLanguage;
    if (try repo.isIgnored(gpa, io, root, rel)) return error.IgnoredPath;
    return cas.create(runtime, profile, .{ .ref = ref, .new_body = new_body });
}

fn tryCreate(gpa: Allocator, io: std.Io, runtime: *Runtime, options: Options, root: []const u8, rel: []const u8) !Result {
    const ref = try symbol.Ref.parse(gpa, options.ref_text);
    defer ref.deinit(gpa);
    const created = try prepareCreate(gpa, io, runtime, root, options.file_abs, rel, ref, options.new_body);
    defer created.snapshot.destroy();
    if (try rules.gate(gpa, io, root, rel, ref, created.snapshot.profile, created.snapshot.tree, created.body)) |report| return .{ .rule_violation = report };

    const shadow_abs = try std.fmt.allocPrint(gpa, "{s}\\{s}\\shadow", .{ root, shadow.workspace_dir });
    defer gpa.free(shadow_abs);
    if (options.trace) |t| t.* = .{ .gate = .full, .base_len = 0, .new_len = created.snapshot.source.len };

    const report = switch (try runInShadow(gpa, io, root, shadow_abs, rel, created.snapshot.source, options, options.test_command, &.{.{ .file = rel, .ref = ref }})) {
        .typecheck => |failed| return .{ .typecheck_failed = failed },
        .rule_violation => |report| return .{ .rule_violation = report },
        .rule_check_failed => |failure| return .{ .rule_check_failed = failure },
        .tests => |tests| tests,
    };
    if (!report.passed()) return .{ .rejected = report };
    defer report.deinit(gpa);

    if (options.trace) |t| t.commit_attempted = true;
    try disk.create(gpa, io, options.file_abs, created.snapshot.source);
    try repo.addToIndex(gpa, io, root, rel);
    return .{ .committed = created.hash };
}

fn fileExists(io: std.Io, path_abs: []const u8) !bool {
    std.Io.Dir.cwd().access(io, path_abs, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    return true;
}

fn runInShadow(gpa: Allocator, io: std.Io, root: []const u8, shadow_abs: []const u8, rel: []const u8, patched: []const u8, options: Options, command: []const u8, targets: []const rules.Target) !ShadowRun {
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

    if (try runCommandRules(gpa, io, root, shadow_abs, targets, options.limits, options.allow_repo_memory)) |gated| return gated;
    return runStages(gpa, io, shadow_abs, options.typecheck_command, command, options.limits);
}
