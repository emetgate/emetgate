const std = @import("std");
const symbol = @import("../engine/symbol.zig");
const cas = @import("../engine/cas.zig");
const boundedness = @import("../engine/boundedness.zig");
const shadow = @import("shadow.zig");
const diagnostics = @import("../protocol/diagnostics.zig");
const gate_tree = @import("gate_tree.zig");
const shadow_root = @import("shadow_root.zig");
const cache_gc = @import("cache_gc.zig");
const sandbox = @import("sandbox.zig");
const test_outcome = @import("test_outcome.zig");
const disk = @import("disk.zig");
const repo = @import("repo.zig");
const exe_path = @import("exe_path.zig");
const test_command_mod = @import("test_command.zig");
const gate_mod = @import("gate.zig");
const batch = @import("batch.zig");
const rules = @import("rules.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;
const Snapshot = @import("../engine/loader.zig").Snapshot;
const create_mod = @import("create.zig");
const commit_plan = @import("commit_plan.zig");
const git_commit = @import("git_commit.zig");
const commit_store = @import("commit_store.zig");
const commit_refusal = @import("commit_refusal.zig");
const baseline = @import("baseline.zig");

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

pub fn ranTestCommand(trace: Trace, test_command: []const u8) []const u8 {
    return trace.scoped_command orelse test_command;
}

pub fn releaseTrace(gpa: Allocator, trace: *Trace) void {
    if (trace.scoped_command) |command| gpa.free(command);
    trace.scoped_command = null;
}
pub const Edit = batch.Edit;
pub const EditOp = batch.EditOp;
pub const DocEdit = batch.DocEdit;
pub const BatchOptions = batch.BatchOptions;
pub const BatchResult = batch.BatchResult;
pub const tryMutateBatch = batch.tryMutateBatch;
pub const prepareCreate = create_mod.prepareCreate;
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
    linked: []const []const u8 = &shadow.dependency_dirs,
    limits: sandbox.Limits = .{},
    allow_repo_memory: bool = false,
    guard_config: bool = false,
    shadow_root: ?[]const u8 = null,
    gate_tree: shadow.Choice = .{},
    trace: ?*Trace = null,
    commit: ?*GitCommit = null,
    commit_step: ?*const disk.Step = null,
};

pub const GitCommit = commit_plan.Request;

pub const Trace = struct {
    gate: ?Gate = null,
    confidence: ?boundedness.Confidence = null,
    provenance: ?boundedness.Provenance = null,
    class: ?boundedness.MutationClass = null,
    base_len: ?usize = null,
    new_len: ?usize = null,
    old_body_len: ?usize = null,
    commit_attempted: bool = false,
    shadow_dotted: bool = false,
    linked_files: usize = 0,
    copied_files: usize = 0,
    skipped_links: usize = 0,
    tree: ?shadow.TreeUse = null,
    test_ms: ?u64 = null,
    scoped_command: ?[]u8 = null,
    tests: test_outcome.Summary = .{},
    blocked: gate_tree.Report = .{},
    baseline: baseline.Note = .{},
};

pub fn noteSummary(trace: ?*Trace, report: sandbox.Report) void {
    const t = trace orelse return;
    t.tests = test_outcome.summarize(report);
}

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

pub fn runCommandRulesFor(gpa: Allocator, io: std.Io, root: []const u8, shadow_abs: []const u8, targets: []const []const u8, message: ?[]const u8, limits: sandbox.Limits, allow_repo_memory: bool) !?ShadowRun {
    const gated = try rules.commandGate(gpa, io, root, targets, .{ .shadow_abs = shadow_abs, .limits = limits, .allow_repo_memory = allow_repo_memory, .message = message });
    return switch (gated) {
        .ok => null,
        .violated => |report| .{ .rule_violation = report },
        .failed => |failure| .{ .rule_check_failed = failure },
    };
}

pub fn runMessageRules(gpa: Allocator, io: std.Io, root: []const u8, shadow_abs: []const u8, message: ?[]const u8, limits: sandbox.Limits, allow_repo_memory: bool) !?ShadowRun {
    return runCommandRulesFor(gpa, io, root, shadow_abs, &.{}, message, limits, allow_repo_memory);
}

pub fn runStages(gpa: Allocator, io: std.Io, cwd: []const u8, typecheck_command: ?[]const u8, test_command: []const u8, limits: sandbox.Limits) !ShadowRun {
    const cache = try cacheDir(gpa, cwd);
    defer gpa.free(cache);
    if (typecheck_command) |typecheck| {
        const checked = try runCommandWith(gpa, io, cwd, typecheck, limits, cache);
        if (!checked.passed()) return .{ .typecheck = try withoutGateDir(gpa, checked, cwd) };
        checked.deinit(gpa);
    }
    var report = try withoutGateDir(gpa, try runCommandWith(gpa, io, cwd, test_command, limits, cache), cwd);
    report.no_tests = test_outcome.noTests(report);
    return .{ .tests = report };
}

fn withoutGateDir(gpa: Allocator, report: sandbox.Report, dir: []const u8) !sandbox.Report {
    errdefer report.deinit(gpa);
    const stdout = try diagnostics.withoutDir(gpa, report.stdout, dir);
    errdefer gpa.free(stdout);
    const stderr = try diagnostics.withoutDir(gpa, report.stderr, dir);
    report.deinit(gpa);
    var clean = report;
    clean.stdout = stdout;
    clean.stderr = stderr;
    return clean;
}

pub fn cacheDir(gpa: Allocator, cwd: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}-cache", .{cwd});
}

pub fn runCommand(gpa: Allocator, io: std.Io, cwd: []const u8, command: []const u8, limits: sandbox.Limits) !sandbox.Report {
    return runCommandWith(gpa, io, cwd, command, limits, null);
}

pub fn runCommandWith(gpa: Allocator, io: std.Io, cwd: []const u8, command: []const u8, limits: sandbox.Limits, cache: ?[]const u8) !sandbox.Report {
    const cmd = try exe_path.system(gpa, "cmd.exe");
    defer gpa.free(cmd);
    const argv = [_][]const u8{ cmd, "/d", "/c", command };
    const temp = try std.fmt.allocPrint(gpa, "{s}-tmp", .{cwd});
    defer gpa.free(temp);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env: std.ArrayList(sandbox.EnvVar) = .empty;
    if (cache) |dir| {
        try shadow.ensureCache(io, dir);
        try env.appendSlice(arena, try sandbox.cacheEnvironment(arena, dir));
    }
    if (try test_command_mod.pythonPath(arena, io, cwd)) |path| try env.append(arena, path);
    try env.append(arena, .{ .name = "PYTHONDONTWRITEBYTECODE", .value = "1" });
    try env.append(arena, .{ .name = "PYTHONPYCACHEPREFIX", .value = try std.fmt.allocPrint(arena, "{s}\\pycache", .{temp}) });
    try shadow.freshTemp(io, temp);
    const report = startCommand(gpa, io, .{ .argv = &argv, .cwd = cwd, .limits = limits, .temp = temp, .env = env.items }) catch |err| {
        shadow.clearTemp(io, temp) catch {};
        return err;
    };
    shadow.clearTemp(io, temp) catch |err| {
        report.deinit(gpa);
        return err;
    };
    return report;
}

fn startCommand(gpa: Allocator, io: std.Io, command: sandbox.Command) !sandbox.Report {
    var attempt: usize = 1;
    while (true) : (attempt += 1) {
        const report = try sandbox.run(gpa, io, command);
        if (attempt == start_attempts or !neverStarted(report)) return report;
        report.deinit(gpa);
        try shadow.freshTemp(io, command.temp.?);
    }
}

const start_attempts = 3;
const status_dll_init_failed: u32 = 0xC0000142;

fn neverStarted(report: sandbox.Report) bool {
    return switch (report.outcome) {
        .crashed => |code| code == status_dll_init_failed,
        else => false,
    };
}

const toolchain_env = [_]sandbox.EnvVar{.{ .name = "NoDefaultCurrentDirectoryInExePath", .value = "1" }};

pub fn runToolchain(gpa: Allocator, io: std.Io, cwd: []const u8, command: []const u8, limits: sandbox.Limits) !sandbox.Report {
    const cmd = try exe_path.system(gpa, "cmd.exe");
    defer gpa.free(cmd);
    const argv = [_][]const u8{ cmd, "/d", "/c", command };
    var report = try sandbox.run(gpa, io, .{ .argv = &argv, .cwd = cwd, .limits = limits, .backend = .user, .env = &toolchain_env });
    report.no_tests = test_outcome.noTests(report);
    return report;
}

pub fn tryMutate(gpa: Allocator, io: std.Io, runtime: *Runtime, options: Options) !Result {
    const edit = [_]batch.Edit{.{ .file_abs = options.file_abs, .ref_text = options.ref_text, .expected_hash = options.expected_hash, .new_body = options.new_body }};
    const through: batch.BatchOptions = .{
        .edits = &edit,
        .test_command = options.test_command,
        .test_scoped_cmd = options.test_scoped_cmd,
        .typecheck_command = options.typecheck_command,
        .linked = options.linked,
        .limits = options.limits,
        .allow_repo_memory = options.allow_repo_memory,
        .guard_config = options.guard_config,
        .shadow_root = options.shadow_root,
        .gate_tree = options.gate_tree,
        .trace = options.trace,
        .commit_step = options.commit_step,
        .commit = options.commit,
    };
    var planned = try batch.planBatch(gpa, io, runtime, through);
    defer planned.deinit(gpa);
    const result = try batch.commitPlanned(gpa, io, planned.root, planned.prepared.items, &edit, through);
    return switch (result) {
        .committed => |written| blk: {
            defer gpa.free(written);
            break :blk .{ .committed = written[0].hash };
        },
        .rejected => |report| .{ .rejected = report },
        .typecheck_failed => |report| .{ .typecheck_failed = report },
        .rule_violation => |report| .{ .rule_violation = report },
        .rule_check_failed => |failure| .{ .rule_check_failed = failure },
    };
}

fn linkedPath(path: []const u8, linked: []const []const u8) bool {
    for (linked) |dir| {
        if (std.ascii.eqlIgnoreCase(path, dir)) return true;
        if (path.len > dir.len and std.ascii.startsWithIgnoreCase(path, dir) and path[dir.len] == 47) return true;
    }
    return false;
}

const Fresh = struct {
    gpa: Allocator,
    io: std.Io,
    root: []const u8,
    location: shadow_root.Location,
    head: git_commit.Head,

    fn sameAsFresh(raw: *anyopaque, paths: []const []const u8, same: []bool) anyerror!void {
        const self: *Fresh = @ptrCast(@alignCast(raw));
        try commit_store.restore(self.gpa, self.io, self.root, self.location.base, self.location.committed, self.head, paths);
        for (paths, same) |path, *slot| {
            const tested = try readUnder(self.gpa, self.io, self.location.committed_shadow, "", path);
            defer self.gpa.free(tested);
            const fresh = try readUnder(self.gpa, self.io, self.location.committed, commit_store.tree_name, path);
            defer self.gpa.free(fresh);
            slot.* = std.mem.eql(u8, tested, fresh);
        }
    }
};

fn readUnder(gpa: Allocator, io: std.Io, dir_abs: []const u8, sub: []const u8, path: []const u8) ![]u8 {
    const abs = try std.fs.path.join(gpa, &.{ dir_abs, sub, path });
    defer gpa.free(abs);
    std.mem.replaceScalar(u8, abs, '/', '\\');
    return std.Io.Dir.cwd().readFileAlloc(io, abs, gpa, .limited(git_commit.max_index_bytes));
}

pub fn deriveGate(gpa: Allocator, io: std.Io, root: []const u8, location: shadow_root.Location, session: *commit_plan.Session, changes: []const commit_plan.Change) !void {
    const head = session.head orelse return;
    var fresh: Fresh = .{ .gpa = gpa, .io = io, .root = root, .location = location, .head = head };
    const found = (try session.derive(gpa, io, root, location.committed_shadow, changes, .{ .ctx = &fresh, .same_as_fresh = Fresh.sameAsFresh })) orelse return;
    defer found.deinit(gpa);
    commit_refusal.note(found.paths, found.total);
    return error.GateTreeNotHead;
}

pub fn gateDir(location: shadow_root.Location, session: *const commit_plan.Session) []const u8 {
    return if (session.head != null) location.committed_shadow else location.shadow;
}

pub fn openShadow(gpa: Allocator, io: std.Io, root: []const u8, location: shadow_root.Location, linked: []const []const u8, choice: shadow.Choice, trace: ?*Trace, session: *const commit_plan.Session) !shadow.Shadow {
    const head = session.head orelse {
        const files = try shadow.workingFiles(gpa, io, root);
        defer gpa.free(files);
        defer shadow.freeFileList(gpa, files);
        return prepareShadow(gpa, io, root, location, location.shadow, files, linked, choice, trace, null);
    };
    const first = try commit_store.ensure(gpa, io, root, location.base, location.committed, head);
    try shadow_root.writeMarker(io, location, root);
    return prepareShadow(gpa, io, root, location, location.committed_shadow, &.{}, linked, choice, trace, .{ .dir = first.dir, .count = first.count }) catch |err| switch (err) {
        error.CommittedTreeIncomplete => {
            if (first.built == .rebuilt) return err;
            try commit_store.invalidate(gpa, io, location.committed);
            const again = try commit_store.ensure(gpa, io, root, location.base, location.committed, head);
            return prepareShadow(gpa, io, root, location, location.committed_shadow, &.{}, linked, choice, trace, .{ .dir = again.dir, .count = again.count });
        },
        else => |e| return e,
    };
}

pub fn prepareShadow(gpa: Allocator, io: std.Io, root: []const u8, location: shadow_root.Location, tree_abs: []const u8, files: []const []const u8, linked: []const []const u8, choice: shadow.Choice, trace: ?*Trace, committed: ?shadow.Committed) !shadow.Shadow {
    var stale_left = staleLeft(shadow_root.sweep(gpa, io, location.base, location.workspace));
    if (stale_left == null) stale_left = cache_gc.takeFailure();
    var workspace = try shadow.Shadow.prepare(io, .{
        .root_abs = root,
        .base_abs = location.base,
        .shadow_abs = tree_abs,
        .files = files,
        .linked = linked,
        .tree = choice.tree,
        .private = choice.private,
        .committed = committed,
        .blocked = if (trace) |t| &t.blocked else null,
    });
    if (trace) |t| {
        t.tree = workspace.use;
        workspace.reportTo(&t.tree.?);
        t.tree.?.stale_left = stale_left;
        t.shadow_dotted = location.dotted();
        t.linked_files = workspace.link_stats.linked;
        t.copied_files = workspace.link_stats.copied;
        t.skipped_links = workspace.link_stats.skipped_links;
    }
    return workspace;
}

fn staleLeft(swept: anyerror!shadow_root.Swept) ?anyerror {
    const done = swept catch |err| return err;
    return done.first_failure;
}

const testing = std.testing;

test "a gated command gets its own writable TEMP and TMP next to its directory, removed after the run" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "work");
    const top = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(top);
    const work = try std.fmt.allocPrint(testing.allocator, "{s}\\work", .{top});
    defer testing.allocator.free(work);
    const temp = try std.fmt.allocPrint(testing.allocator, "{s}-tmp", .{work});
    defer testing.allocator.free(temp);
    try shadow.grantLowIntegrityWrite(work);

    const report = try runCommand(testing.allocator, testing.io, work, "echo %TEMP%& echo %TMP%& echo written>%TEMP%\\probe.txt& type %TEMP%\\probe.txt", .{ .timeout_ms = 20_000 });
    defer report.deinit(testing.allocator);
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ report.stdout, report.stderr });
    try testing.expect(report.passed());
    const expected = try std.fmt.allocPrint(testing.allocator, "{s}\r\n{s}\r\nwritten\r\n", .{ temp, temp });
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, report.stdout);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, temp, .{}));
}

test "a gated command in a Python src layout imports the src packages through PYTHONPATH" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "work/src/wordstat");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "work/src/wordstat/__init__.py", .data = "" });
    const top = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(top);
    const work = try std.fmt.allocPrint(testing.allocator, "{s}\\work", .{top});
    defer testing.allocator.free(work);
    try shadow.grantLowIntegrityWrite(work);

    const report = try runCommand(testing.allocator, testing.io, work, "echo %PYTHONPATH%", .{ .timeout_ms = 20_000 });
    defer report.deinit(testing.allocator);
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ report.stdout, report.stderr });
    try testing.expect(report.passed());
    const src = try std.fmt.allocPrint(testing.allocator, "{s}\\src", .{work});
    defer testing.allocator.free(src);
    try testing.expect(std.mem.startsWith(u8, report.stdout, src));
}

test "a gated command runs Python with bytecode writes off and its bytecode cache under the fresh temp directory" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "work");
    const top = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(top);
    const work = try std.fmt.allocPrint(testing.allocator, "{s}\\work", .{top});
    defer testing.allocator.free(work);
    try shadow.grantLowIntegrityWrite(work);

    const report = try runCommand(testing.allocator, testing.io, work, "echo %PYTHONDONTWRITEBYTECODE% %PYTHONPYCACHEPREFIX%", .{ .timeout_ms = 20_000 });
    defer report.deinit(testing.allocator);
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ report.stdout, report.stderr });
    try testing.expect(report.passed());
    const expected = try std.fmt.allocPrint(testing.allocator, "1 {s}-tmp\\pycache", .{work});
    defer testing.allocator.free(expected);
    try testing.expect(std.mem.startsWith(u8, report.stdout, expected));
}

test "a stale temp directory that is a junction is removed without touching its target" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "target");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "target/keep.txt", .data = "keep\n" });
    const top = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(top);
    const temp = try std.fmt.allocPrint(testing.allocator, "{s}\\work-tmp", .{top});
    defer testing.allocator.free(temp);
    const target = try std.fmt.allocPrint(testing.allocator, "{s}\\target", .{top});
    defer testing.allocator.free(target);
    try shadow.createJunction(testing.io, temp, target);

    try shadow.freshTemp(testing.io, temp);
    try testing.expect(!try shadow.isReparsePoint(temp));
    try shadow.clearTemp(testing.io, temp);
    const kept = try tmp.dir.readFileAlloc(testing.io, "target/keep.txt", testing.allocator, .unlimited);
    defer testing.allocator.free(kept);
    try testing.expectEqualStrings("keep\n", kept);
}

test "a toolchain command writes into its real directory and never runs a same-named script from it" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "whoami.cmd", .data = "@echo off\r\necho planted> planted.txt\r\n" });
    const work = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(work);

    const report = try runToolchain(testing.allocator, testing.io, work, "echo kept> kept.txt", .{ .timeout_ms = 20_000 });
    defer report.deinit(testing.allocator);
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ report.stdout, report.stderr });
    try testing.expect(report.passed());
    try tmp.dir.access(testing.io, "kept.txt", .{});

    const planted = try runToolchain(testing.allocator, testing.io, work, "whoami", .{ .timeout_ms = 20_000 });
    defer planted.deinit(testing.allocator);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "planted.txt", .{}));
}

test "a gated command gets writable package caches next to its directory that survive the run" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "work");
    const top = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(top);
    const work = try std.fmt.allocPrint(testing.allocator, "{s}\\work", .{top});
    defer testing.allocator.free(work);
    try shadow.grantLowIntegrityWrite(work);

    const staged = try runStages(testing.allocator, testing.io, work, null, "echo %NUGET_PACKAGES%& mkdir %NUGET_PACKAGES%& echo cached>%NUGET_PACKAGES%\\probe.txt", .{ .timeout_ms = 20_000 });
    const report = staged.tests;
    defer report.deinit(testing.allocator);
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ report.stdout, report.stderr });
    try testing.expect(report.passed());
    const expected = try std.fmt.allocPrint(testing.allocator, "{s}-cache\\nuget\\packages\r\n", .{work});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, report.stdout);
    try tmp.dir.access(testing.io, "work-cache\\nuget\\packages\\probe.txt", .{});
}

test "a gated test run that collected no tests passes with a note instead of failing the write" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "work");
    const top = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(top);
    const work = try std.fmt.allocPrint(testing.allocator, "{s}\\work", .{top});
    defer testing.allocator.free(work);
    try shadow.grantLowIntegrityWrite(work);

    const staged = try runStages(testing.allocator, testing.io, work, null, "echo collected 0 items& echo no tests ran in 0.01s& exit /b 5", .{ .timeout_ms = 20_000 });
    const report = staged.tests;
    defer report.deinit(testing.allocator);
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ report.stdout, report.stderr });
    try testing.expectEqual(sandbox.Outcome{ .exited = 5 }, report.outcome);
    try testing.expect(report.no_tests);
    try testing.expect(report.passed());
    try testing.expect(std.mem.startsWith(u8, test_outcome.summarize(report).text(), test_outcome.no_tests_note));
}

test "a command's console output reaches the caller as UTF-8 text" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "work");
    const top = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(top);
    const work = try std.fmt.allocPrint(testing.allocator, "{s}\\work", .{top});
    defer testing.allocator.free(work);
    try shadow.grantLowIntegrityWrite(work);

    const report = try runCommand(testing.allocator, testing.io, work, "echo \u{e7}\u{e7}\u{e7}\u{e7}", .{ .timeout_ms = 20_000 });
    defer report.deinit(testing.allocator);
    errdefer std.debug.print("stdout: {any}\n", .{report.stdout});
    try testing.expect(std.unicode.utf8ValidateSlice(report.stdout));
    try testing.expectEqualStrings("\u{e7}\u{e7}\u{e7}\u{e7}\r\n", report.stdout);
}

test "a stale shadow that the sweep could not remove is named in the trace of the next gate" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "repo");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/a.ts", .data = "export const a = 1;\n" });
    const top = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(top);
    const root = try std.fmt.allocPrint(testing.allocator, "{s}\\repo", .{top});
    defer testing.allocator.free(root);
    const gone = try std.fmt.allocPrint(testing.allocator, "{s}\\gone", .{top});
    defer testing.allocator.free(gone);
    const base = try std.fmt.allocPrint(testing.allocator, "{s}\\base", .{top});
    defer testing.allocator.free(base);
    const gone_key = shadow_root.repoKey(gone);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try tmp.dir.createDirPath(testing.io, try std.fmt.bufPrint(&buf, "base/{s}/shadow", .{&gone_key}));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = try std.fmt.bufPrint(&buf, "base/{s}/{s}", .{ &gone_key, shadow_root.marker_name }), .data = gone });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = try std.fmt.bufPrint(&buf, "base/{s}/unknown.txt", .{&gone_key}), .data = "not ours\n" });

    const location = try shadow_root.locate(testing.allocator, root, base);
    defer location.deinit(testing.allocator);
    var trace: Trace = .{};
    var workspace = try prepareShadow(testing.allocator, testing.io, root, location, location.shadow, &.{"a.ts"}, &.{}, .{ .tree = .full_copy }, &trace, null);
    workspace.finish();
    try testing.expectEqual(@as(?anyerror, error.WorkspaceNotEmpty), trace.tree.?.stale_left);
    try testing.expectEqual(@as(?anyerror, null), trace.tree.?.left_behind);
}
