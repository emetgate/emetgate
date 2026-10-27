const std = @import("std");
const symbol = @import("../engine/symbol.zig");
const docnode = @import("../engine/docnode.zig");
const registry = @import("../engine/lang/registry.zig");
const repo = @import("repo.zig");
const shadow = @import("shadow.zig");
const sandbox = @import("sandbox.zig");
const disk = @import("disk.zig");
const batch = @import("batch.zig");
const batch_plan = @import("batch_plan.zig");
const commit_plan = @import("commit_plan.zig");
const file_move = @import("file_move.zig");
const runner = @import("runner.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;
const Snapshot = @import("../engine/loader.zig").Snapshot;

const Allocator = std.mem.Allocator;

pub const max_code_bytes = 16 * 1024 * 1024;

pub const Change = union(enum) {
    replace: struct { old: []const u8, new: []const u8, all: bool = false },
    whole: []const u8,
};

pub const Target = struct {
    abs: []u8,
    created_dirs: [][]u8,

    pub fn deinit(self: Target, gpa: Allocator) void {
        for (self.created_dirs) |dir| gpa.free(dir);
        gpa.free(self.created_dirs);
        gpa.free(self.abs);
    }
};

pub fn jailWrite(gpa: Allocator, io: std.Io, served_root: ?[]const u8, given: []const u8, may_create: bool) !Target {
    const root = try repo.servedRoot(gpa, io, served_root);
    defer gpa.free(root);
    const path = try std.fs.path.resolve(gpa, &.{ root, given });
    defer gpa.free(path);
    return jailResolved(gpa, io, root, path, may_create);
}

fn jailResolved(gpa: Allocator, io: std.Io, served_root: []const u8, path: []const u8, may_create: bool) !Target {
    if (repo.jail(gpa, io, served_root, path)) |place| {
        defer place.deinit(gpa);
        try repo.refuseLinkAsWritten(gpa, io, path);
        return .{ .abs = try gpa.dupe(u8, place.abs), .created_dirs = &.{} };
    } else |err| switch (err) {
        error.FileNotFound => if (!may_create) return err,
        else => |e| return e,
    }
    const abs = try file_move.jailDestination(gpa, io, served_root, path);
    errdefer gpa.free(abs);
    const ancestor = existingAncestor(io, abs) orelse return error.ParentDirectoryMissing;
    const parent = try repo.jail(gpa, io, served_root, ancestor);
    parent.deinit(gpa);
    var dir = std.Io.Dir.openDirAbsolute(io, ancestor, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.ParentDirectoryMissing,
        else => |e| return e,
    };
    dir.close(io);
    return .{ .abs = abs, .created_dirs = try dirsBetween(gpa, ancestor, abs) };
}

pub fn existingAncestor(io: std.Io, path_abs: []const u8) ?[]const u8 {
    var dir: []const u8 = std.fs.path.dirname(path_abs) orelse return null;
    while (true) {
        std.Io.Dir.cwd().access(io, dir, .{}) catch {
            dir = std.fs.path.dirname(dir) orelse return null;
            continue;
        };
        return dir;
    }
}

fn dirsBetween(gpa: Allocator, ancestor: []const u8, abs: []const u8) ![][]u8 {
    var dirs: std.ArrayList([]u8) = .empty;
    errdefer {
        for (dirs.items) |d| gpa.free(d);
        dirs.deinit(gpa);
    }
    var dir: []const u8 = std.fs.path.dirname(abs) orelse return error.InvalidPath;
    while (dir.len > ancestor.len) {
        try dirs.append(gpa, try gpa.dupe(u8, dir));
        dir = std.fs.path.dirname(dir) orelse break;
    }
    std.mem.reverse([]u8, dirs.items);
    return dirs.toOwnedSlice(gpa);
}

pub fn replaceUnique(gpa: Allocator, source: []const u8, old: []const u8, new: []const u8, all: bool, matches: *usize) ![]u8 {
    if (old.len == 0) return error.EmptyOldString;
    if (std.mem.eql(u8, old, new)) return error.NoChange;
    matches.* = std.mem.count(u8, source, old);
    if (matches.* == 0 and std.mem.indexOf(u8, source, "\r\n") != null and std.mem.indexOfScalar(u8, old, '\n') != null and std.mem.indexOfScalar(u8, old, '\r') == null) {
        const crlf_old = try std.mem.replaceOwned(u8, gpa, old, "\n", "\r\n");
        defer gpa.free(crlf_old);
        const crlf_new = try std.mem.replaceOwned(u8, gpa, new, "\n", "\r\n");
        defer gpa.free(crlf_new);
        matches.* = std.mem.count(u8, source, crlf_old);
        if (matches.* != 0) return replaceCounted(gpa, source, crlf_old, crlf_new, all, matches.*);
    }
    return replaceCounted(gpa, source, old, new, all, matches.*);
}

fn replaceCounted(gpa: Allocator, source: []const u8, old: []const u8, new: []const u8, all: bool, matches: usize) ![]u8 {
    if (matches == 0) return error.OldStringNotFound;
    if (matches > 1 and !all) return error.OldStringNotUnique;
    return std.mem.replaceOwned(u8, gpa, source, old, new);
}

pub fn wholeHole(base: []const u8, after: []const u8) symbol.Hole {
    const shortest = @min(base.len, after.len);
    var prefix: usize = 0;
    while (prefix < shortest and base[prefix] == after[prefix]) prefix += 1;
    var suffix: usize = 0;
    while (suffix < shortest - prefix and base[base.len - 1 - suffix] == after[after.len - 1 - suffix]) suffix += 1;
    return .{
        .old = .{ .start = @intCast(prefix), .end = @intCast(base.len - suffix) },
        .new = .{ .start = @intCast(prefix), .end = @intCast(after.len - suffix) },
    };
}

pub fn prepare(gpa: Allocator, runtime: *Runtime, file_abs: []const u8, rel: []u8, base: ?[]const u8, after: []const u8) !batch_plan.Prepared {
    const action: batch_plan.Action = if (base == null) .create else .write;
    const base_hash: ?symbol.Hash = if (base) |b| symbol.hashOf(b) else null;
    const profile = registry.forPath(file_abs) orelse {
        if (!std.unicode.utf8ValidateSlice(after)) return error.NotUtf8;
        try docnode.checkReadable(after);
        return .{ .rel = rel, .action = action, .base_hash = base_hash, .hash = symbol.hashOf(after), .doc_source = try gpa.dupe(u8, after) };
    };
    if (after.len > max_code_bytes) return error.DocTooLarge;
    const next = try Snapshot.fromSource(runtime, profile, try gpa.dupe(u8, after));
    errdefer next.destroy();
    const old = if (base) |b| try Snapshot.fromSource(runtime, profile, try gpa.dupe(u8, b)) else null;
    const old_clean = if (old) |o| !o.tree.root().hasError() else false;
    if (old != null and !old_clean) old.?.destroy();
    const kept = if (old_clean) old else null;
    errdefer if (kept) |k| k.destroy();
    if (next.tree.root().hasError() and (base == null or old_clean)) return error.MutationSyntaxInvalid;
    const holes: ?[]symbol.Hole = if (kept != null) try gpa.dupe(symbol.Hole, &.{wholeHole(base.?, after)}) else null;
    return .{ .rel = rel, .action = action, .base_hash = base_hash, .hash = symbol.hashOf(after), .snapshot = next, .base = kept, .holes = holes };
}

pub const Options = struct {
    file_abs: []const u8,
    change: Change,
    created_dirs: []const []const u8 = &.{},
    test_command: []const u8,
    typecheck_command: ?[]const u8 = null,
    allow_repo_memory: bool = false,
    shadow_root: ?[]const u8 = null,
    gate_tree: shadow.Choice = .{},
    trace: ?*runner.Trace = null,
    commit_step: ?*const disk.Step = null,
    commit: ?*commit_plan.Request = null,
};

pub const Outcome = struct {
    root: []u8,
    rel: []u8,
    before: ?symbol.Hash,
    after: symbol.Hash,
    created: bool,
    unchanged: bool = false,
    matches: usize = 0,
    result: ?batch.BatchResult = null,

    pub fn deinit(self: Outcome, gpa: Allocator) void {
        if (self.result) |r| r.deinit(gpa);
        gpa.free(self.rel);
        gpa.free(self.root);
    }
};

fn readBase(gpa: Allocator, io: std.Io, file_abs: []const u8, code: bool) !?[]u8 {
    const limit: usize = if (code) max_code_bytes else docnode.max_bytes;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, file_abs, gpa, .limited(limit + 1)) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.StreamTooLong => return error.DocTooLarge,
        else => |e| return e,
    };
    errdefer gpa.free(bytes);
    if (!code) try docnode.checkReadable(bytes);
    return bytes;
}

pub fn apply(gpa: Allocator, io: std.Io, runtime: *Runtime, options: Options, matches: *usize) !Outcome {
    if (options.test_command.len == 0) return error.NoTestCommand;
    const anchor = existingAncestor(io, options.file_abs) orelse return error.InvalidPath;
    const root = try repo.gitToplevel(gpa, io, anchor);
    errdefer gpa.free(root);
    const lock = try shadow.Lock.acquire(io, root);
    defer lock.release();
    const rel = try repo.relativeUnder(gpa, root, options.file_abs);
    var rel_owned = true;
    errdefer if (rel_owned) gpa.free(rel);
    try repo.refuseInternal(rel);

    const code = registry.forPath(options.file_abs) != null;
    const base = try readBase(gpa, io, options.file_abs, code);
    defer if (base) |b| gpa.free(b);
    const after = switch (options.change) {
        .replace => |r| try replaceUnique(gpa, base orelse return error.FileNotFound, r.old, r.new, r.all, matches),
        .whole => |content| try gpa.dupe(u8, content),
    };
    defer gpa.free(after);
    const before_hash: ?symbol.Hash = if (base) |b| symbol.hashOf(b) else null;
    if (base) |b| if (std.mem.eql(u8, b, after)) return .{ .root = root, .rel = rel, .before = before_hash, .after = before_hash.?, .created = false, .unchanged = true, .matches = matches.* };
    if (base == null and try repo.isIgnored(gpa, io, root, rel)) return error.IgnoredPath;

    const rel_copy = try gpa.dupe(u8, rel);
    const prepared = [1]batch_plan.Prepared{prepare(gpa, runtime, options.file_abs, rel_copy, base, after) catch |err| {
        gpa.free(rel_copy);
        return err;
    }};
    defer prepared[0].deinit(gpa);
    const edits = [1]batch.Edit{.{ .file_abs = options.file_abs, .ref_text = "", .expected_hash = if (before_hash) |h| .{ .present = h } else .absent }};
    const result = try batch.commitPlanned(gpa, io, root, &prepared, &edits, .{
        .edits = &edits,
        .test_command = options.test_command,
        .typecheck_command = options.typecheck_command,
        .allow_repo_memory = options.allow_repo_memory,
        .shadow_root = options.shadow_root,
        .gate_tree = options.gate_tree,
        .trace = options.trace,
        .commit_step = options.commit_step,
        .commit = options.commit,
        .created_dirs = if (base == null) options.created_dirs else &.{},
    });
    rel_owned = false;
    return .{ .root = root, .rel = rel, .before = before_hash, .after = prepared[0].hash, .created = base == null, .matches = matches.*, .result = result };
}

const testing = std.testing;

test "replaceUnique replaces one exact match and refuses a missing or repeated old string with its count" {
    var matches: usize = 0;
    const once = try replaceUnique(testing.allocator, "a = 1;\nb = 2;\n", "b = 2", "b = 3", false, &matches);
    defer testing.allocator.free(once);
    try testing.expectEqualStrings("a = 1;\nb = 3;\n", once);
    try testing.expectEqual(@as(usize, 1), matches);
    try testing.expectError(error.OldStringNotFound, replaceUnique(testing.allocator, "abc", "x", "y", false, &matches));
    try testing.expectEqual(@as(usize, 0), matches);
    try testing.expectError(error.OldStringNotUnique, replaceUnique(testing.allocator, "x x x", "x", "y", false, &matches));
    try testing.expectEqual(@as(usize, 3), matches);
    const all = try replaceUnique(testing.allocator, "x x x", "x", "y", true, &matches);
    defer testing.allocator.free(all);
    try testing.expectEqualStrings("y y y", all);
    try testing.expectError(error.EmptyOldString, replaceUnique(testing.allocator, "abc", "", "y", false, &matches));
    try testing.expectError(error.NoChange, replaceUnique(testing.allocator, "abc", "b", "b", false, &matches));
}

test "replaceUnique matches a LF old string against a CRLF file and keeps CRLF" {
    var matches: usize = 0;
    const out = try replaceUnique(testing.allocator, "one\r\ntwo\r\nthree\r\n", "one\ntwo", "one\n2", false, &matches);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("one\r\n2\r\nthree\r\n", out);
}

test "wholeHole spans only the bytes between the common prefix and suffix" {
    const hole = wholeHole("abcXYdef", "abcQdef");
    try testing.expectEqual(@as(u32, 3), hole.old.start);
    try testing.expectEqual(@as(u32, 5), hole.old.end);
    try testing.expectEqual(@as(u32, 3), hole.new.start);
    try testing.expectEqual(@as(u32, 4), hole.new.end);
    const grown = wholeHole("aa", "aaa");
    try testing.expectEqual(@as(u32, 2), grown.old.start);
    try testing.expectEqual(@as(u32, 2), grown.old.end);
    try testing.expectEqual(@as(u32, 3), grown.new.end);
}
