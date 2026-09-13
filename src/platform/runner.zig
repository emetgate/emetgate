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
const Runtime = @import("../engine/runtime.zig").Runtime;
const Snapshot = @import("../engine/loader.zig").Snapshot;

const Allocator = std.mem.Allocator;

pub const config_file = test_command_mod.config_file;
pub const repoRoot = repo.repoRoot;
pub const assertUnderCwdRepo = repo.assertUnderCwdRepo;
pub const repoRelative = repo.repoRelative;
pub const relativeUnder = repo.relativeUnder;
pub const resolveTestCommand = test_command_mod.resolveTestCommand;
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
