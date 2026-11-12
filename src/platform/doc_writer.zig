const std = @import("std");
const symbol = @import("../engine/symbol.zig");
const docnode = @import("../engine/docnode.zig");
const shadow = @import("shadow.zig");
const sandbox = @import("sandbox.zig");
const disk = @import("disk.zig");
const repo = @import("repo.zig");
const runner = @import("runner.zig");
const batch = @import("batch.zig");
const rules = @import("rules.zig");
const commit_plan = @import("commit_plan.zig");

const Allocator = std.mem.Allocator;
const gitToplevel = repo.gitToplevel;

pub const Selector = docnode.Selector;

pub const Options = struct {
    file_abs: []const u8,
    selector: Selector,
    expected_hash: symbol.Hash,
    new_text: []const u8,
    test_command: []const u8,
    typecheck_command: ?[]const u8 = null,
    linked: []const []const u8 = &shadow.dependency_dirs,
    limits: sandbox.Limits = .{},
    allow_repo_memory: bool = false,
    guard_config: bool = false,
    shadow_root: ?[]const u8 = null,
    gate_tree: shadow.Choice = .{},
    commit_step: ?*const disk.Step = null,
    commit: ?*commit_plan.Request = null,
};

pub const Trace = struct {
    gate: runner.Trace = .{},
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

pub fn tryWriteDoc(gpa: Allocator, io: std.Io, options: Options, trace: ?*Trace) !Result {
    if (options.test_command.len == 0) return error.NoTestCommand;
    try docnode.refuseSource(options.file_abs);
    const dir = std.fs.path.dirname(options.file_abs) orelse return error.InvalidPath;
    const root = try gitToplevel(gpa, io, dir);
    defer gpa.free(root);
    const lock = try shadow.Lock.acquire(io, root);
    defer lock.release();

    const edit = [_]batch.DocEdit{.{ .file_abs = options.file_abs, .selector = options.selector, .expected_hash = options.expected_hash, .new_text = options.new_text }};
    const result = try batch.commitPlanned(gpa, io, root, &.{}, &.{}, .{
        .doc_edits = &edit,
        .test_command = options.test_command,
        .typecheck_command = options.typecheck_command,
        .linked = options.linked,
        .limits = options.limits,
        .allow_repo_memory = options.allow_repo_memory,
        .guard_config = options.guard_config,
        .shadow_root = options.shadow_root,
        .gate_tree = options.gate_tree,
        .trace = if (trace) |t| &t.gate else null,
        .commit_step = options.commit_step,
        .commit = options.commit,
    });
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
