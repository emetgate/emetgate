const std = @import("std");
const bounded_run = @import("bounded_run.zig");
const commit_guard = @import("commit_guard.zig");
const exe_path = @import("exe_path.zig");
const receipts = @import("receipts.zig");
const rules = @import("rules.zig");
const registry = @import("../engine/lang/registry.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;
const receipt = @import("../verify/receipt.zig");

const Allocator = std.mem.Allocator;

pub const max_commits = 64;
pub const max_findings = 64;
const max_file_bytes = 16 * 1024 * 1024;
const max_list_bytes = 16 * 1024 * 1024;
const short_oid = 12;

pub const Finding = struct {
    commit: ?[]const u8 = null,
    file: []const u8,
    line: u32,
    col: u32,
    rule: []const u8,
    rule_text: []const u8,
    text: []const u8,
};

const Seen = std.StringArrayHashMapUnmanaged(?receipt.Hash);

const Repo = struct {
    root: []const u8,
    label: []const u8,
    enforced: rules.Enforced,
    head: ?[]const u8,
    refs: []const u8,
    dirty: Seen,
};

const Working = union(enum) { missing, too_big, bytes: []const u8 };

pub const Audit = struct {
    gpa: Allocator,
    io: std.Io,
    runtime: *Runtime,
    allow_repo_memory: bool,
    started_s: i64,
    arena_state: std.heap.ArenaAllocator,
    repos: std.ArrayList(Repo),
    findings: std.ArrayList(Finding),
    unchecked: std.ArrayList([]const u8),
    more_findings: usize,

    pub fn begin(self: *Audit, gpa: Allocator, io: std.Io, runtime: *Runtime, root_abs: []const u8, nested: []const []const u8, allow_repo_memory: bool) !void {
        self.* = .{
            .gpa = gpa,
            .io = io,
            .runtime = runtime,
            .allow_repo_memory = allow_repo_memory,
            .started_s = @intCast(@divFloor(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s)),
            .arena_state = .init(gpa),
            .repos = .empty,
            .findings = .empty,
            .unchecked = .empty,
            .more_findings = 0,
        };
        errdefer self.deinit();
        try self.watch(root_abs, "");
        for (nested) |other| {
            const label = std.mem.trimStart(u8, other[@min(root_abs.len, other.len)..], "\\/");
            try self.watch(other, label);
        }
    }

    pub fn deinit(self: *Audit) void {
        for (self.repos.items) |item| item.enforced.deinit();
        self.arena_state.deinit();
    }

    pub fn finish(self: *Audit) !void {
        for (self.repos.items) |*item| {
            self.settle(item) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                try self.note(item.label, @errorName(err));
            };
        }
    }

    fn arena(self: *Audit) Allocator {
        return self.arena_state.allocator();
    }

    fn note(self: *Audit, label: []const u8, reason: []const u8) !void {
        const shown = if (label.len == 0) "." else label;
        try self.unchecked.append(self.arena(), try std.fmt.allocPrint(self.arena(), "{s}: {s}", .{ shown, reason }));
    }

    fn watch(self: *Audit, root: []const u8, label: []const u8) !void {
        const enforced = rules.peek(self.gpa, self.io, root) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return self.note(label, @errorName(err));
        };
        if (enforced.rules.len == 0) {
            enforced.deinit();
            return;
        }
        errdefer enforced.deinit();
        const a = self.arena();
        const head = try self.headOf(root);
        const refs = (receipts.git(a, self.io, root, &.{ "for-each-ref", "--format=%(objectname)", "refs/heads" }) catch null) orelse "";
        var dirty: Seen = .empty;
        const listed = self.dirtyFiles(root) catch null;
        if (listed) |rels| {
            for (rels) |rel| switch (try self.readWorking(root, rel)) {
                .missing => try dirty.put(a, rel, null),
                .too_big => {},
                .bytes => |bytes| try dirty.put(a, rel, receipt.blake3(bytes)),
            };
        } else {
            enforced.deinit();
            return;
        }
        try self.repos.append(a, .{ .root = try a.dupe(u8, root), .label = try a.dupe(u8, label), .enforced = enforced, .head = head, .refs = refs, .dirty = dirty });
    }

    fn headOf(self: *Audit, root: []const u8) !?[]const u8 {
        const text = (receipts.git(self.arena(), self.io, root, &.{ "rev-parse", "-q", "--verify", "HEAD" }) catch return null) orelse return null;
        return std.mem.trim(u8, text, " \t\r\n");
    }

    fn dirtyFiles(self: *Audit, root: []const u8) !?[][]const u8 {
        const a = self.arena();
        const text = (try receipts.git(a, self.io, root, &.{ "status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames", "--ignore-submodules=all" })) orelse return null;
        var found: std.ArrayList([]const u8) = .empty;
        var tokens = std.mem.splitScalar(u8, text, 0);
        while (tokens.next()) |token| {
            if (token.len < 4) continue;
            const rel = token[3..];
            if (rel[rel.len - 1] == '/' or registry.forPath(rel) == null) continue;
            var known = false;
            for (found.items) |other| {
                if (std.mem.eql(u8, other, rel)) known = true;
            }
            if (!known) try found.append(a, rel);
        }
        return found.items;
    }

    fn readWorking(self: *Audit, root: []const u8, rel: []const u8) !Working {
        const a = self.arena();
        const abs = try std.fmt.allocPrint(a, "{s}\\{s}", .{ root, rel });
        std.mem.replaceScalar(u8, abs, '/', '\\');
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, abs, a, .limited(max_file_bytes)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FileNotFound, error.NotDir => return .missing,
            else => return .too_big,
        };
        return .{ .bytes = bytes };
    }

    fn settle(self: *Audit, item: *Repo) !void {
        try self.judgeCommits(item);
        try self.judgeWorking(item);
    }

    fn newCommits(self: *Audit, item: *Repo) ![]const []const u8 {
        const a = self.arena();
        const now_head = try self.headOf(item.root);
        const now_refs = (try receipts.git(a, self.io, item.root, &.{ "for-each-ref", "--format=%(objectname)", "refs/heads" })) orelse "";
        var input: std.ArrayList(u8) = .empty;
        var moved = false;
        if (now_head) |oid| {
            if (item.head == null or !std.mem.eql(u8, item.head.?, oid)) {
                try input.print(a, "{s}\n", .{oid});
                moved = true;
            }
        }
        var after = std.mem.tokenizeAny(u8, now_refs, "\r\n");
        while (after.next()) |oid| {
            if (hasLine(item.refs, oid)) continue;
            try input.print(a, "{s}\n", .{oid});
            moved = true;
        }
        if (!moved) return &.{};
        if (item.head) |oid| try input.print(a, "^{s}\n", .{oid});
        var before = std.mem.tokenizeAny(u8, item.refs, "\r\n");
        while (before.next()) |oid| try input.print(a, "^{s}\n", .{oid});
        const since = try std.fmt.allocPrint(a, "--max-age={d}", .{self.started_s});
        const argv = [_][]const u8{ try exe_path.git(a, item.root), "rev-list", "--reverse", "--parents", since, "--stdin" };
        const result = try bounded_run.runFed(a, self.io, .{ .argv = &argv, .cwd = .{ .path = item.root }, .stdout_limit = .limited(max_list_bytes) }, input.items);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.GitFailed,
            else => return error.GitFailed,
        }
        var lines: std.ArrayList([]const u8) = .empty;
        var split = std.mem.tokenizeAny(u8, result.stdout, "\r\n");
        while (split.next()) |line| try lines.append(a, line);
        return lines.items;
    }

    fn judgeCommits(self: *Audit, item: *Repo) !void {
        const lines = try self.newCommits(item);
        const kept = lines[0..@min(lines.len, max_commits)];
        if (lines.len > kept.len) {
            try self.note(item.label, try std.fmt.allocPrint(self.arena(), "{d} commits past the first {d} were not checked", .{ lines.len - kept.len, max_commits }));
        }
        for (kept) |line| {
            var words = std.mem.tokenizeScalar(u8, line, ' ');
            const oid = words.next() orelse continue;
            _ = words.next();
            const merge = words.next() != null;
            self.judgeCommit(item, oid, merge) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                try self.note(item.label, try std.fmt.allocPrint(self.arena(), "commit {s}: {t}", .{ oid[0..@min(oid.len, short_oid)], err }));
            };
        }
    }

    fn judgeCommit(self: *Audit, item: *Repo, oid: []const u8, merge: bool) !void {
        const a = self.arena();
        const short = oid[0..@min(oid.len, short_oid)];
        const message = (try receipts.git(a, self.io, item.root, &.{ "log", "-1", "--format=%B", oid })) orelse return error.GitFailed;
        try self.keep(item, short, try rules.evaluateMessage(self.gpa, item.enforced.rules, message));
        if (merge) return;
        var changes: commit_guard.Staged = .{};
        defer changes.deinit(self.gpa);
        try commit_guard.readCommit(a, self.gpa, self.io, self.runtime, item.root, oid, &changes);
        try self.keepChanges(item, short, changes.changes.items);
    }

    fn judgeWorking(self: *Audit, item: *Repo) !void {
        const a = self.arena();
        const rels = (try self.dirtyFiles(item.root)) orelse return;
        var changes: commit_guard.Staged = .{};
        defer changes.deinit(self.gpa);
        for (rels) |rel| {
            const now = try self.readWorking(item.root, rel);
            if (now == .too_big) {
                try self.note(item.label, try std.fmt.allocPrint(a, "{s}: larger than {d} bytes", .{ rel, max_file_bytes }));
                continue;
            }
            if (item.dirty.get(rel)) |was| {
                const same = switch (now) {
                    .missing => was == null,
                    .bytes => |bytes| was != null and std.mem.eql(u8, &was.?, &receipt.blake3(bytes)),
                    .too_big => unreachable,
                };
                if (same) continue;
            }
            try commit_guard.addWorking(a, self.gpa, self.io, self.runtime, item.root, rel, if (now == .bytes) now.bytes else null, &changes);
        }
        try self.keepChanges(item, null, changes.changes.items);
    }

    fn keepChanges(self: *Audit, item: *Repo, commit: ?[]const u8, changes: []const rules.Change) !void {
        for (changes) |change| {
            const single = [_]rules.Change{change};
            try self.keep(item, commit, try rules.judgeUnder(self.gpa, self.io, item.root, item.enforced.rules, &single, self.allow_repo_memory));
        }
    }

    fn keep(self: *Audit, item: *Repo, commit: ?[]const u8, gate: rules.Gate) !void {
        defer gate.deinit(self.gpa);
        const a = self.arena();
        switch (gate) {
            .ok => {},
            .failed => |failure| try self.note(item.label, try std.fmt.allocPrint(a, "rule {s} could not run on {s}: {s} {s}", .{ failure.rule, failure.file, failure.detail, failure.text })),
            .violated => |report| for (report.violations) |v| {
                if (self.findings.items.len == max_findings) {
                    self.more_findings += 1;
                    continue;
                }
                const message = std.mem.eql(u8, v.file, rules.message_label);
                try self.findings.append(a, .{
                    .commit = if (commit) |text| try a.dupe(u8, text) else null,
                    .file = if (item.label.len == 0 or message) try a.dupe(u8, v.file) else try std.fmt.allocPrint(a, "{s}/{s}", .{ item.label, v.file }),
                    .line = v.line,
                    .col = v.col,
                    .rule = try a.dupe(u8, v.rule),
                    .rule_text = try a.dupe(u8, v.rule_text),
                    .text = try a.dupe(u8, v.text),
                });
            },
        }
    }
};

fn hasLine(text: []const u8, wanted: []const u8) bool {
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, wanted)) return true;
    }
    return false;
}
