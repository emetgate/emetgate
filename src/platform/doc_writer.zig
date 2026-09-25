const std = @import("std");
const symbol = @import("../engine/symbol.zig");
const docnode = @import("../engine/docnode.zig");
const ts = @import("../engine/tree_sitter.zig");
const shadow = @import("shadow.zig");
const shadow_root = @import("shadow_root.zig");
const sandbox = @import("sandbox.zig");
const disk = @import("disk.zig");
const repo = @import("repo.zig");
const runner = @import("runner.zig");
const rules = @import("rules.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;

const Allocator = std.mem.Allocator;
const gitToplevel = repo.gitToplevel;
const relativeUnder = repo.relativeUnder;

pub const Selector = union(enum) {
    pointer: []const u8,
    heading: []const u8,
    line_range: struct { start: u32, end: u32 },
};

pub const Options = struct {
    file_abs: []const u8,
    selector: Selector,
    expected_hash: symbol.Hash,
    new_text: []const u8,
    test_command: []const u8,
    typecheck_command: ?[]const u8 = null,
    linked: []const []const u8 = &.{"node_modules"},
    limits: sandbox.Limits = .{},
    allow_repo_memory: bool = false,
    shadow_root: ?[]const u8 = null,
};

pub const Trace = struct {
    base_len: usize = 0,
    new_len: usize = 0,
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

fn applyDoc(gpa: Allocator, parser: ts.Parser, source: []const u8, options: Options) docnode.Error!docnode.Applied {
    return switch (options.selector) {
        .pointer => |p| docnode.applyJsonPointer(gpa, parser, source, p, options.expected_hash, options.new_text),
        .heading => |h| docnode.applyMarkdownHeading(gpa, parser, source, h, options.expected_hash, options.new_text),
        .line_range => |r| docnode.applyLineRange(gpa, source, r.start, r.end, options.expected_hash, options.new_text),
    };
}

pub fn tryWriteDoc(gpa: Allocator, io: std.Io, options: Options, trace: ?*Trace) !Result {
    if (options.test_command.len == 0) return error.NoTestCommand;
    const dir = std.fs.path.dirname(options.file_abs) orelse return error.InvalidPath;
    const root = try gitToplevel(gpa, io, dir);
    defer gpa.free(root);
    const lock = try shadow.Lock.acquire(io, root);
    defer lock.release();
    const rel = try relativeUnder(gpa, root, options.file_abs);
    defer gpa.free(rel);

    const source = try std.Io.Dir.cwd().readFileAlloc(io, options.file_abs, gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(source);
    const base_hash = symbol.hashOf(source);

    const parser = ts.Parser.create();
    defer parser.deinit();
    const applied = try applyDoc(gpa, parser, source, options);
    defer gpa.free(applied.source);

    if (trace) |t| t.* = .{ .base_len = source.len, .new_len = applied.source.len };

    const location = try shadow_root.locate(gpa, root, options.shadow_root);
    defer location.deinit(gpa);

    const files = try shadow.trackedFiles(gpa, io, root);
    defer gpa.free(files);
    defer shadow.freeFileList(gpa, files);

    var workspace = try runner.prepareShadow(gpa, io, root, location, files, options.linked, null);
    defer {
        workspace.close();
        shadow.remove(io, location.base, location.shadow) catch {};
    }
    try workspace.writeFile(rel, applied.source);

    if (try runner.runCommandRules(gpa, io, root, location.shadow, &.{}, options.limits, options.allow_repo_memory)) |gated| {
        return switch (gated) {
            .rule_violation => |report| .{ .rule_violation = report },
            .rule_check_failed => |failure| .{ .rule_check_failed = failure },
            else => unreachable,
        };
    }

    const staged = try runner.runStages(gpa, io, location.shadow, options.typecheck_command, options.test_command, options.limits);
    switch (staged) {
        .typecheck => |failed| return .{ .typecheck_failed = failed },
        .rule_violation, .rule_check_failed => unreachable,
        .tests => |report| {
            if (!report.passed()) return .{ .rejected = report };
            defer report.deinit(gpa);
            const journal_dir = try std.fmt.allocPrint(gpa, "{s}\\{s}\\journal", .{ root, shadow.workspace_dir });
            defer gpa.free(journal_dir);
            try disk.replaceReporting(gpa, io, options.file_abs, applied.source, base_hash, null, journal_dir);
            return .{ .committed = applied.hash };
        },
    }
}
