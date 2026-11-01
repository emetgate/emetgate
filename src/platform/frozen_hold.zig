const std = @import("std");
const bounded_run = @import("bounded_run.zig");
const exe_path = @import("exe_path.zig");
const rules = @import("rules.zig");
const shadow = @import("shadow.zig");
const where_mod = @import("where.zig");

const Allocator = std.mem.Allocator;
const Blake3 = std.crypto.hash.Blake3;
const Dir = std.Io.Dir;
const Digest = [Blake3.digest_length]u8;
const Map = std.StringArrayHashMapUnmanaged([]const u8);

pub const hold_dir = "frozen-hold";
const max_git_output = 256 * 1024 * 1024;
const op_files = [_][]const u8{ "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD" };
const op_dirs = [_][]const u8{ "rebase-merge", "rebase-apply" };

pub const Restored = struct { path: []const u8, rules: []const []const u8 };
pub const Committed = struct { commit: []const u8, subject: []const u8, paths: []const []const u8, rules: []const []const u8 };
pub const Failed = struct { path: []const u8, reason: []const u8 };

pub const Report = struct {
    state: ?*std.heap.ArenaAllocator = null,
    restored: []const Restored = &.{},
    committed: []const Committed = &.{},
    in_merge: []const []const u8 = &.{},
    failed: []const Failed = &.{},
    failure: ?anyerror = null,

    pub fn held(self: Report) bool {
        return self.failed.len == 0 and self.failure == null;
    }

    pub fn deinit(self: Report, gpa: Allocator) void {
        const state = self.state orelse return;
        state.deinit();
        gpa.destroy(state);
    }
};

const Scope = struct { id: []const u8, where: ?where_mod.Where };
const Seen = union(enum) { absent, other, file: Digest };
const Held = struct { seen: Seen = .absent, copy: []const u8 = "", index: []const u8 = "" };
const Touched = struct { path: []const u8, pre: Held, seen: Seen, index: []const u8, work_changed: bool, index_changed: bool };
const Work = enum { keep, pre, head, delete };
const Plan = struct {
    path: []const u8,
    pre: Held,
    work: Work = .keep,
    index: ?[]const u8 = null,
    oid_len: usize = 0,
    failed: bool = false,
};

pub const Hold = struct {
    io: std.Io,
    root_abs: []const u8,
    state: *std.heap.ArenaAllocator,
    git_exe: []const u8 = "",
    prefix: []const u8 = "",
    git_dir: []const u8 = "",
    parent_abs: []const u8 = "",
    scopes: []const Scope = &.{},
    head: ?[]const u8 = null,
    refs: []const u8 = "",
    op: []const u8 = "",
    started_s: i64 = 0,
    files: std.StringArrayHashMapUnmanaged(Held) = .empty,

    fn arena(self: *Hold) Allocator {
        return self.state.allocator();
    }

    fn git(self: *Hold, argv: []const []const u8, input: ?[]const u8) ![]const u8 {
        const result = try self.gitRun(argv, input);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.GitFailed,
            else => return error.GitFailed,
        }
        return result.stdout;
    }

    fn gitRun(self: *Hold, argv: []const []const u8, input: ?[]const u8) !std.process.RunResult {
        var full: std.ArrayList([]const u8) = .empty;
        try full.append(self.arena(), self.git_exe);
        try full.appendSlice(self.arena(), argv);
        const options: std.process.RunOptions = .{
            .argv = full.items,
            .cwd = .{ .path = self.root_abs },
            .stdout_limit = .limited(max_git_output),
        };
        if (input) |bytes| return bounded_run.runFed(self.arena(), self.io, options, bytes);
        return bounded_run.run(self.arena(), self.io, options);
    }

    fn headOid(self: *Hold) !?[]const u8 {
        const result = try self.gitRun(&.{ "rev-parse", "--verify", "-q", "HEAD" }, null);
        switch (result.term) {
            .exited => |code| {
                if (code == 0) return std.mem.trim(u8, result.stdout, " \t\r\n");
                if (code == 1) return null;
                return error.GitFailed;
            },
            else => return error.GitFailed,
        }
    }

    fn listRefs(self: *Hold) ![]const u8 {
        return self.git(&.{ "for-each-ref", "--format=%(objectname) %(refname)", "refs/heads" }, null);
    }

    fn covers(self: *Hold, path: []const u8) bool {
        for (self.scopes) |scope| {
            const where = scope.where orelse return true;
            if (where.coversFile(path)) return true;
        }
        return false;
    }

    fn rulesOf(self: *Hold, path: []const u8) ![]const []const u8 {
        var ids: std.ArrayList([]const u8) = .empty;
        for (self.scopes) |scope| {
            if (scope.where) |where| {
                if (!where.coversFile(path)) continue;
            }
            try ids.append(self.arena(), scope.id);
        }
        return ids.items;
    }

    fn listIndex(self: *Hold) !Map {
        const text = try self.git(&.{ "ls-files", "-s", "-z", "--", ".", ":(exclude,icase)" ++ shadow.workspace_dir }, null);
        var entries: Map = .empty;
        var records = std.mem.tokenizeScalar(u8, text, 0);
        while (records.next()) |record| {
            const tab = std.mem.indexOfScalar(u8, record, '\t') orelse continue;
            const path = record[tab + 1 ..];
            if (!self.covers(path)) continue;
            const slot = try entries.getOrPutValue(self.arena(), path, "");
            slot.value_ptr.* = try std.fmt.allocPrint(self.arena(), "{s}{s}\n", .{ slot.value_ptr.*, record[0..tab] });
        }
        return entries;
    }

    fn listTree(self: *Hold, commit: ?[]const u8) !Map {
        var entries: Map = .empty;
        const oid = commit orelse return entries;
        const text = try self.git(&.{ "ls-tree", "-r", "-z", oid }, null);
        var records = std.mem.tokenizeScalar(u8, text, 0);
        while (records.next()) |record| {
            const tab = std.mem.indexOfScalar(u8, record, '\t') orelse continue;
            const path = record[tab + 1 ..];
            if (!self.covers(path)) continue;
            var fields = std.mem.tokenizeScalar(u8, record[0..tab], ' ');
            const mode = fields.next() orelse continue;
            _ = fields.next() orelse continue;
            const blob = fields.next() orelse continue;
            try entries.put(self.arena(), path, try std.fmt.allocPrint(self.arena(), "{s} {s} 0\n", .{ mode, blob }));
        }
        return entries;
    }

    fn readOp(self: *Hold) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (op_files) |name| {
            const path = try std.fmt.allocPrint(self.arena(), "{s}\\{s}", .{ self.git_dir, name });
            const bytes = Dir.cwd().readFileAlloc(self.io, path, self.arena(), .limited(4096)) catch continue;
            try out.print(self.arena(), "{s}={s}\n", .{ name, bytes });
        }
        for (op_dirs) |name| {
            const path = try std.fmt.allocPrint(self.arena(), "{s}\\{s}", .{ self.git_dir, name });
            Dir.cwd().access(self.io, path, .{}) catch continue;
            try out.print(self.arena(), "{s}\n", .{name});
        }
        return out.items;
    }

    fn abs(self: *Hold, rel: []const u8) ![]u8 {
        const path = try std.fmt.allocPrint(self.arena(), "{s}\\{s}", .{ self.root_abs, rel });
        std.mem.replaceScalar(u8, path, '/', '\\');
        return path;
    }

    fn seenAt(self: *Hold, rel: []const u8) !Seen {
        const path = try self.abs(rel);
        const stat = Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return .absent,
            else => return err,
        };
        if (stat.kind != .file) return .other;
        return .{ .file = try hashFile(self.io, path) };
    }

    fn keepCopies(self: *Hold, dir_abs: []const u8) !void {
        const entries = try self.listIndex();
        for (entries.keys(), entries.values()) |path, lines| try self.files.put(self.arena(), path, .{ .index = lines });
        for (try shadow.workingFiles(self.arena(), self.io, self.root_abs)) |path| {
            if (self.covers(path)) _ = try self.files.getOrPutValue(self.arena(), path, .{});
        }
        for (self.files.keys(), self.files.values(), 0..) |path, *file, n| {
            file.seen = try self.seenAt(path);
            if (file.seen != .file) continue;
            const copy = try std.fmt.allocPrint(self.arena(), "{s}\\{d}", .{ dir_abs, n });
            try Dir.cwd().copyFile(try self.abs(path), Dir.cwd(), copy, self.io, .{});
            file.copy = copy;
            file.seen = .{ .file = try hashFile(self.io, copy) };
        }
    }

    fn removeFile(self: *Hold, rel: []const u8) !void {
        const path = try self.abs(rel);
        const stat = Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return,
            else => return err,
        };
        if (stat.kind == .directory) try Dir.cwd().deleteDir(self.io, path) else try Dir.cwd().deleteFile(self.io, path);
        var parent = rel;
        while (std.mem.lastIndexOfScalar(u8, parent, '/')) |slash| {
            parent = parent[0..slash];
            Dir.cwd().deleteDir(self.io, try self.abs(parent)) catch break;
        }
    }

    fn putBack(self: *Hold, rel: []const u8, file: Held) !void {
        const digest = switch (file.seen) {
            .file => |d| d,
            else => return error.NothingHeld,
        };
        const copied = try hashFile(self.io, file.copy);
        if (!std.mem.eql(u8, &digest, &copied)) return error.HeldCopyChanged;
        const path = try self.abs(rel);
        if (Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = false })) |stat| {
            if (stat.kind == .directory) try Dir.cwd().deleteDir(self.io, path);
        } else |_| {}
        if (std.fs.path.dirname(path)) |parent| try Dir.cwd().createDirPath(self.io, parent);
        try Dir.cwd().copyFile(file.copy, Dir.cwd(), path, self.io, .{});
    }

    fn workingOids(self: *Hold, touched: []const Touched) !Map {
        var oids: Map = .empty;
        var input: std.ArrayList(u8) = .empty;
        var asked: std.ArrayList([]const u8) = .empty;
        for (touched) |item| {
            if (item.seen != .file) continue;
            try input.print(self.arena(), "{s}\n", .{item.path});
            try asked.append(self.arena(), item.path);
        }
        if (asked.items.len == 0) return oids;
        const text = try self.git(&.{ "hash-object", "--stdin-paths" }, input.items);
        var lines = std.mem.tokenizeAny(u8, text, "\r\n");
        for (asked.items) |path| {
            try oids.put(self.arena(), path, lines.next() orelse return error.GitFailed);
        }
        return oids;
    }

    fn commitsMade(self: *Hold, now_head: ?[]const u8, now_refs: []const u8) ![]const Committed {
        var input: std.ArrayList(u8) = .empty;
        var moved = false;
        if (now_head) |oid| {
            if (!sameOpt(self.head, now_head)) {
                try input.print(self.arena(), "{s}\n", .{oid});
                moved = true;
            }
        }
        var after = std.mem.tokenizeAny(u8, now_refs, "\r\n");
        while (after.next()) |line| {
            if (hasLine(self.refs, line)) continue;
            try input.print(self.arena(), "{s}\n", .{firstWord(line)});
            moved = true;
        }
        if (!moved) return &.{};
        if (self.head) |oid| try input.print(self.arena(), "^{s}\n", .{oid});
        var before = std.mem.tokenizeAny(u8, self.refs, "\r\n");
        while (before.next()) |line| try input.print(self.arena(), "^{s}\n", .{firstWord(line)});
        const since = try std.fmt.allocPrint(self.arena(), "--max-age={d}", .{self.started_s});
        const text = try self.git(&.{ "log", "-z", "--format=%H%x1f%s", "--name-only", "--no-renames", "--relative", "--diff-merges=combined", since, "--stdin" }, input.items);
        var found: std.ArrayList(Committed) = .empty;
        var commit: []const u8 = "";
        var subject: []const u8 = "";
        var paths: std.ArrayList([]const u8) = .empty;
        var tokens = std.mem.splitScalar(u8, text, 0);
        while (tokens.next()) |raw| {
            const token = std.mem.trimStart(u8, raw, "\r\n");
            if (std.mem.indexOfScalar(u8, token, 0x1f)) |mark| {
                try self.appendCommit(&found, commit, subject, paths.items);
                commit = token[0..mark];
                subject = token[mark + 1 ..];
                paths = .empty;
            } else if (token.len != 0 and self.covers(token)) {
                try paths.append(self.arena(), token);
            }
        }
        try self.appendCommit(&found, commit, subject, paths.items);
        return found.items;
    }

    fn appendCommit(self: *Hold, found: *std.ArrayList(Committed), commit: []const u8, subject: []const u8, paths: []const []const u8) !void {
        if (paths.len == 0) return;
        var ids: std.ArrayList([]const u8) = .empty;
        for (paths) |path| {
            for (try self.rulesOf(path)) |id| {
                for (ids.items) |known| {
                    if (std.mem.eql(u8, known, id)) break;
                } else try ids.append(self.arena(), id);
            }
        }
        try found.append(self.arena(), .{ .commit = commit, .subject = subject, .paths = paths, .rules = ids.items });
    }

    fn failPlan(self: *Hold, plan: *Plan, failed: *std.ArrayList(Failed), err: anyerror) !void {
        if (plan.failed) return;
        plan.failed = true;
        try failed.append(self.arena(), .{ .path = plan.path, .reason = @errorName(err) });
    }

    fn settle(self: *Hold, report: *Report) !void {
        const a = self.arena();
        var failed: std.ArrayList(Failed) = .empty;
        defer report.failed = failed.items;
        var git_ok = true;
        var now_head = self.head;
        var now_refs = self.refs;
        var now_op = self.op;
        var index: Map = .empty;
        var listed: []const []u8 = &.{};
        read: {
            const problem: anyerror = found: {
                now_head = self.headOid() catch |err| break :found err;
                now_refs = self.listRefs() catch |err| break :found err;
                now_op = self.readOp() catch |err| break :found err;
                index = self.listIndex() catch |err| break :found err;
                listed = shadow.workingFiles(a, self.io, self.root_abs) catch |err| break :found err;
                break :read;
            };
            git_ok = false;
            now_head = self.head;
            now_refs = self.refs;
            now_op = self.op;
            try failed.append(a, .{ .path = "(git)", .reason = try std.fmt.allocPrint(a, "git could not read the repository after the command, so the index and commits were not checked: {t}", .{problem}) });
        }

        var paths: std.StringArrayHashMapUnmanaged(void) = .empty;
        for (self.files.keys()) |path| try paths.put(a, path, {});
        for (index.keys()) |path| try paths.put(a, path, {});
        for (listed) |path| {
            if (self.covers(path)) try paths.put(a, path, {});
        }

        var touched: std.ArrayList(Touched) = .empty;
        for (paths.keys()) |path| {
            const pre = self.files.get(path) orelse Held{};
            if (pre.seen == .other) continue;
            const seen = self.seenAt(path) catch |err| {
                try failed.append(a, .{ .path = path, .reason = @errorName(err) });
                continue;
            };
            const now_index = index.get(path) orelse "";
            const work_changed = !sameSeen(pre.seen, seen);
            const index_changed = git_ok and !std.mem.eql(u8, pre.index, now_index);
            if (!work_changed and !index_changed) continue;
            try touched.append(a, .{ .path = path, .pre = pre, .seen = seen, .index = now_index, .work_changed = work_changed, .index_changed = index_changed });
        }

        const moved = !sameOpt(self.head, now_head);
        const in_op = now_op.len != 0 or (self.op.len != 0 and !moved);
        var oids: Map = .empty;
        var head_tree: Map = .empty;
        var old_tree: Map = .empty;
        var compared = true;
        if (touched.items.len != 0 and (moved or in_op)) {
            const problem: ?anyerror = found: {
                oids = self.workingOids(touched.items) catch |err| break :found err;
                head_tree = self.listTree(now_head) catch |err| break :found err;
                old_tree = self.listTree(self.head) catch |err| break :found err;
                break :found null;
            };
            if (problem) |err| {
                compared = false;
                for (touched.items) |item| {
                    try failed.append(a, .{ .path = item.path, .reason = try std.fmt.allocPrint(a, "could not compare it with the commit git moved to: {t}", .{err}) });
                }
            }
        }

        var plans: std.ArrayList(Plan) = .empty;
        var in_merge: std.ArrayList([]const u8) = .empty;
        if (compared) for (touched.items) |item| {
            const oid = oids.get(item.path);
            const conflicted = item.index.len != 0 and std.mem.indexOf(u8, item.index, " 0\n") == null;
            if (in_op and (conflicted or matchesEntry(item.seen, oid, item.index))) {
                try in_merge.append(a, item.path);
                continue;
            }
            var plan: Plan = .{ .path = item.path, .pre = item.pre };
            if (moved) {
                const in_head = head_tree.get(item.path) orelse "";
                const in_old = old_tree.get(item.path) orelse "";
                const path_moved = !std.mem.eql(u8, in_head, in_old);
                if (item.work_changed and !matchesEntry(item.seen, oid, in_head)) {
                    plan.work = if (!path_moved) restoreKind(item.pre) else if (in_head.len == 0) .delete else .head;
                }
                if (item.index_changed and !std.mem.eql(u8, item.index, in_head)) {
                    plan.index = if (path_moved) in_head else item.pre.index;
                    plan.oid_len = oidLen(item.index, item.pre.index, in_head);
                }
            } else {
                if (item.work_changed) plan.work = restoreKind(item.pre);
                if (item.index_changed) {
                    plan.index = item.pre.index;
                    plan.oid_len = oidLen(item.index, item.pre.index, "");
                }
            }
            if (plan.work != .keep or plan.index != null) try plans.append(a, plan);
        };

        for (plans.items) |*plan| {
            if (plan.work != .delete) continue;
            self.removeFile(plan.path) catch |err| try self.failPlan(plan, &failed, err);
        }
        for (plans.items) |*plan| {
            switch (plan.work) {
                .pre => self.putBack(plan.path, plan.pre) catch |err| try self.failPlan(plan, &failed, err),
                .head => {
                    const spec = try std.fmt.allocPrint(a, ":(literal){s}", .{plan.path});
                    _ = self.git(&.{ "restore", "--source=HEAD", "--worktree", "--", spec }, null) catch |err| try self.failPlan(plan, &failed, err);
                },
                else => {},
            }
        }
        var info: std.ArrayList(u8) = .empty;
        for (plans.items) |plan| {
            const target = plan.index orelse continue;
            try info.appendSlice(a, "0 ");
            try info.appendNTimes(a, '0', plan.oid_len);
            try info.print(a, "\t{s}{s}\x00", .{ self.prefix, plan.path });
            var lines = std.mem.tokenizeScalar(u8, target, '\n');
            while (lines.next()) |line| try info.print(a, "{s}\t{s}{s}\x00", .{ line, self.prefix, plan.path });
        }
        if (info.items.len != 0) {
            _ = self.git(&.{ "update-index", "-z", "--index-info" }, info.items) catch |err| {
                for (plans.items) |*plan| {
                    if (plan.index != null) try self.failPlan(plan, &failed, err);
                }
            };
        }

        var restored: std.ArrayList(Restored) = .empty;
        for (plans.items) |plan| {
            if (plan.failed) continue;
            try restored.append(a, .{ .path = plan.path, .rules = try self.rulesOf(plan.path) });
        }
        report.restored = restored.items;
        report.in_merge = in_merge.items;
        if (git_ok) {
            report.committed = self.commitsMade(now_head, now_refs) catch |err| none: {
                try failed.append(a, .{ .path = "(commits)", .reason = try std.fmt.allocPrint(a, "could not list what the command committed: {t}", .{err}) });
                break :none &.{};
            };
        }
    }

    pub fn finish(self: *Hold) Report {
        var report: Report = .{ .state = self.state };
        self.settle(&report) catch |err| {
            report.failure = err;
        };
        Dir.cwd().deleteTree(self.io, self.parent_abs) catch {};
        return report;
    }
};

fn restoreKind(pre: Held) Work {
    return if (pre.seen == .file) .pre else .delete;
}

fn sameOpt(a: ?[]const u8, b: ?[]const u8) bool {
    const left = a orelse return b == null;
    const right = b orelse return false;
    return std.mem.eql(u8, left, right);
}

fn sameSeen(a: Seen, b: Seen) bool {
    return switch (a) {
        .absent => b == .absent,
        .other => b == .other,
        .file => |digest| b == .file and std.mem.eql(u8, &digest, &b.file),
    };
}

fn hasLine(text: []const u8, wanted: []const u8) bool {
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, wanted)) return true;
    }
    return false;
}

fn firstWord(line: []const u8) []const u8 {
    return line[0 .. std.mem.indexOfScalar(u8, line, ' ') orelse line.len];
}

fn entryOid(lines: []const u8) []const u8 {
    var fields = std.mem.tokenizeAny(u8, lines, " \n");
    _ = fields.next() orelse return "";
    return fields.next() orelse "";
}

fn oidLen(a: []const u8, b: []const u8, c: []const u8) usize {
    return @max(entryOid(a).len, entryOid(b).len, entryOid(c).len);
}

fn matchesEntry(seen: Seen, oid: ?[]const u8, entry: []const u8) bool {
    return switch (seen) {
        .absent => entry.len == 0,
        .other => entry.len != 0,
        .file => if (oid) |text| std.mem.eql(u8, text, entryOid(entry)) else false,
    };
}

fn hashFile(io: std.Io, path: []const u8) !Digest {
    const file = try Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var hasher = Blake3.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const count = try file.readPositional(io, &.{&buffer}, offset);
        if (count == 0) break;
        hasher.update(buffer[0..count]);
        offset += count;
    }
    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

pub fn begin(gpa: Allocator, io: std.Io, root_abs: []const u8) !?*Hold {
    const enforced = try rules.peek(gpa, io, root_abs);
    defer enforced.deinit();
    for (enforced.rules) |rule| {
        if (rules.isFrozen(rule)) break;
    } else return null;

    const state = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(state);
    state.* = .init(gpa);
    errdefer state.deinit();
    const a = state.allocator();

    const hold = try a.create(Hold);
    hold.* = .{ .io = io, .root_abs = root_abs, .state = state };
    var scopes: std.ArrayList(Scope) = .empty;
    for (enforced.rules) |rule| {
        if (!rules.isFrozen(rule)) continue;
        const where: ?where_mod.Where = if (rule.where) |text| try where_mod.parse(try a.dupe(u8, text)) else null;
        try scopes.append(a, .{ .id = try a.dupe(u8, rule.id), .where = where });
    }
    hold.scopes = scopes.items;
    hold.git_exe = try exe_path.git(a, root_abs);
    hold.prefix = std.mem.trim(u8, try hold.git(&.{ "rev-parse", "--show-prefix" }, null), "\r\n");
    const git_dir = try a.dupe(u8, std.mem.trim(u8, try hold.git(&.{ "rev-parse", "--absolute-git-dir" }, null), " \r\n"));
    std.mem.replaceScalar(u8, git_dir, '/', '\\');
    hold.git_dir = git_dir;
    hold.head = try hold.headOid();
    hold.refs = try hold.listRefs();
    hold.op = try hold.readOp();

    const now_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    hold.started_s = @intCast(@divFloor(now_ns, std.time.ns_per_s));
    hold.parent_abs = try std.fmt.allocPrint(a, "{s}\\{s}\\{s}", .{ root_abs, shadow.workspace_dir, hold_dir });
    Dir.cwd().deleteTree(io, hold.parent_abs) catch {};
    const dir_abs = try std.fmt.allocPrint(a, "{s}\\{d}", .{ hold.parent_abs, now_ns });
    try Dir.cwd().createDirPath(io, dir_abs);
    errdefer Dir.cwd().deleteTree(io, hold.parent_abs) catch {};
    try Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}\\.gitignore", .{hold.parent_abs}), .data = "*\n" });
    try hold.keepCopies(dir_abs);
    return hold;
}
