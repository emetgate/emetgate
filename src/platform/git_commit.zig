const std = @import("std");
const builtin = @import("builtin");
const exe_path = @import("exe_path.zig");
const shadow = @import("shadow.zig");
const disk = @import("disk.zig");
const commit_message = @import("commit_message.zig");
const own_dir = @import("own_dir.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const work_dir = "commit";
pub const max_git_output = 256 * 1024 * 1024;
pub const max_index_bytes = 1024 * 1024 * 1024;
pub const branch_prefix = "refs/heads/";
pub const Digest = [Sha256.digest_length]u8;

const paths_per_call = 64;
const publish_attempts = 10;
const publish_retry_ms = 50;

pub const Change = struct {
    rel: []const u8,
    content: ?[]const u8,
    mode_from: ?[]const u8 = null,
};

pub const Error = error{
    GitFailed,
    DetachedHead,
    NoCommitYet,
    OperationInProgress,
    SigningNotSupported,
    NoCommitIdentity,
    TargetHasUncommittedChanges,
    TargetNotInHead,
    TargetSkipWorktree,
    IndexLocked,
    IndexChanged,
    NothingToCommit,
    BranchMoved,
    BranchUpdateRefused,
};

pub const Head = struct {
    oid: []u8,
    tree: []u8,

    pub fn deinit(self: Head, gpa: Allocator) void {
        gpa.free(self.oid);
        gpa.free(self.tree);
    }
};

pub const Entry = struct {
    path: []u8,
    mode: [6]u8,
    blob: ?[]u8,
};

pub const Prepared = struct {
    commit: []u8,
    entries: []Entry,

    pub fn deinit(self: Prepared, gpa: Allocator) void {
        gpa.free(self.commit);
        freeEntries(gpa, self.entries);
    }
};

pub fn freeEntries(gpa: Allocator, entries: []Entry) void {
    for (entries) |entry| {
        gpa.free(entry.path);
        if (entry.blob) |blob| gpa.free(blob);
    }
    gpa.free(entries);
}

const in_progress = [_][]const u8{ "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG", "rebase-merge", "rebase-apply" };

const Git = struct {
    arena: Allocator,
    io: std.Io,
    root: []const u8,
    exe: []const u8,
    env: ?*const std.process.Environ.Map = null,

    fn init(arena: Allocator, io: std.Io, root: []const u8) !Git {
        return .{ .arena = arena, .io = io, .root = root, .exe = try exe_path.git(arena, root) };
    }

    fn raw(self: Git, argv: []const []const u8) !?[]const u8 {
        var full: std.ArrayList([]const u8) = .empty;
        try full.appendSlice(self.arena, &.{ self.exe, "-c", "core.longpaths=true", "-c", "core.fsmonitor=false" });
        try full.appendSlice(self.arena, argv);
        const result = std.process.run(self.arena, self.io, .{
            .argv = full.items,
            .cwd = .{ .path = self.root },
            .environ_map = self.env,
            .stdout_limit = .limited(max_git_output),
            .stderr_limit = .limited(max_git_output),
        }) catch return error.GitFailed;
        return switch (result.term) {
            .exited => |code| if (code == 0) result.stdout else null,
            else => error.GitFailed,
        };
    }

    fn run(self: Git, argv: []const []const u8) !?[]const u8 {
        const out = (try self.raw(argv)) orelse return null;
        return std.mem.trim(u8, out, " \r\n");
    }

    fn need(self: Git, argv: []const []const u8) ![]const u8 {
        return (try self.run(argv)) orelse error.GitFailed;
    }

    fn needRaw(self: Git, argv: []const []const u8) ![]const u8 {
        return (try self.raw(argv)) orelse error.GitFailed;
    }

    fn withIndex(self: Git, index_path: []const u8) !Git {
        const env = try self.arena.create(std.process.Environ.Map);
        env.* = std.process.Environ.createMap(.{ .block = .global }, self.arena) catch return error.GitFailed;
        try env.put("GIT_INDEX_FILE", index_path);
        var copy = self;
        copy.env = env;
        return copy;
    }
};

pub fn slashed(arena: Allocator, rel: []const u8) ![]u8 {
    const out = try arena.dupe(u8, rel);
    std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
}

fn absOf(arena: Allocator, root: []const u8, path: []const u8) ![]u8 {
    const out = try std.fmt.allocPrint(arena, "{s}\\{s}", .{ root, path });
    std.mem.replaceScalar(u8, out, '/', '\\');
    return out;
}

fn exists(io: std.Io, path_abs: []const u8) !bool {
    Dir.cwd().access(io, path_abs, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return error.GitFailed,
    };
    return true;
}

const Tracked = struct {
    path: []const u8,
    tag: u8,
    mode: []const u8,
    oid: []const u8,
    stage: u8,
};

const TreeEntry = struct {
    path: []const u8,
    mode: []const u8,
    kind: []const u8,
    oid: []const u8,
};

fn parseTracked(arena: Allocator, out: []const u8, list: *std.ArrayList(Tracked)) !void {
    var it = std.mem.tokenizeScalar(u8, out, 0);
    while (it.next()) |record| {
        const tab = std.mem.indexOfScalar(u8, record, '\t') orelse return error.GitFailed;
        var fields = std.mem.tokenizeScalar(u8, record[0..tab], ' ');
        const tag = fields.next() orelse return error.GitFailed;
        const mode = fields.next() orelse return error.GitFailed;
        const oid = fields.next() orelse return error.GitFailed;
        const stage = fields.next() orelse return error.GitFailed;
        if (tag.len != 1 or stage.len != 1) return error.GitFailed;
        try list.append(arena, .{ .path = record[tab + 1 ..], .tag = tag[0], .mode = mode, .oid = oid, .stage = stage[0] - '0' });
    }
}

fn parseTree(arena: Allocator, out: []const u8, list: *std.ArrayList(TreeEntry)) !void {
    var it = std.mem.tokenizeScalar(u8, out, 0);
    while (it.next()) |record| {
        const tab = std.mem.indexOfScalar(u8, record, '\t') orelse return error.GitFailed;
        var fields = std.mem.tokenizeScalar(u8, record[0..tab], ' ');
        const mode = fields.next() orelse return error.GitFailed;
        const kind = fields.next() orelse return error.GitFailed;
        const oid = fields.next() orelse return error.GitFailed;
        try list.append(arena, .{ .path = record[tab + 1 ..], .mode = mode, .kind = kind, .oid = oid });
    }
}

fn ignoresCase(git: Git) !bool {
    const value = (try git.run(&.{ "config", "--type=bool", "--get", "core.ignorecase" })) orelse return false;
    return std.mem.eql(u8, value, "true");
}

fn indexEntries(git: Git, paths: []const []const u8, icase: bool) ![]Tracked {
    var list: std.ArrayList(Tracked) = .empty;
    var at: usize = 0;
    while (at < paths.len) {
        const end = @min(paths.len, at + paths_per_call);
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(git.arena, &.{ "ls-files", "-z", "-s", "-v", "--" });
        for (paths[at..end]) |path| {
            try argv.append(git.arena, try std.fmt.allocPrint(git.arena, ":({s}){s}", .{ if (icase) "icase,literal" else "literal", path }));
        }
        try parseTracked(git.arena, try git.needRaw(argv.items), &list);
        at = end;
    }
    return list.items;
}

fn treeEntries(git: Git, rev: []const u8, paths: []const []const u8) ![]TreeEntry {
    var list: std.ArrayList(TreeEntry) = .empty;
    var at: usize = 0;
    while (at < paths.len) {
        const end = @min(paths.len, at + paths_per_call);
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(git.arena, &.{ "ls-tree", "-z", rev, "--" });
        try argv.appendSlice(git.arena, paths[at..end]);
        try parseTree(git.arena, try git.needRaw(argv.items), &list);
        at = end;
    }
    return list.items;
}

fn storedOids(git: Git, paths: []const []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var at: usize = 0;
    while (at < paths.len) {
        const end = @min(paths.len, at + paths_per_call);
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(git.arena, &.{ "hash-object", "--" });
        try argv.appendSlice(git.arena, paths[at..end]);
        var lines = std.mem.tokenizeAny(u8, try git.need(argv.items), "\r\n");
        while (lines.next()) |line| try list.append(git.arena, line);
        at = end;
    }
    if (list.items.len != paths.len) return error.GitFailed;
    return list.items;
}

fn tracked(entries: []const Tracked, path: []const u8) ?Tracked {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return entry;
    }
    return null;
}

fn inTree(entries: []const TreeEntry, path: []const u8) ?TreeEntry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.path, path) and std.mem.eql(u8, entry.kind, "blob")) return entry;
    }
    return null;
}

const Survey = struct {
    paths: []const []const u8,
    index: []const Tracked,
};

fn survey(git: Git, rels: []const []const u8) !Survey {
    const icase = try ignoresCase(git);
    const given = try git.arena.alloc([]const u8, rels.len);
    for (rels, given) |rel, *slot| slot.* = try slashed(git.arena, rel);
    const index = try indexEntries(git, given, icase);
    const paths = try git.arena.alloc([]const u8, rels.len);
    for (given, paths) |path, *slot| {
        slot.* = path;
        if (tracked(index, path) != null or !icase) continue;
        for (index) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.path, path)) {
                slot.* = entry.path;
                break;
            }
        }
    }
    return .{ .paths = paths, .index = index };
}

fn measure(git: Git, head_oid: []const u8, seen: Survey) !void {
    const tree = try treeEntries(git, head_oid, seen.paths);
    var present: std.ArrayList([]const u8) = .empty;
    for (seen.paths) |path| {
        var stages: usize = 0;
        for (seen.index) |entry| {
            if (!std.mem.eql(u8, entry.path, path)) continue;
            stages += 1;
            if (entry.tag == 'S' or entry.tag == 's') return error.TargetSkipWorktree;
            if (entry.stage != 0) return error.TargetHasUncommittedChanges;
        }
        if (stages > 1) return error.TargetHasUncommittedChanges;
        const in_index = tracked(seen.index, path);
        const in_head = inTree(tree, path);
        if (try exists(git.io, try absOf(git.arena, git.root, path))) {
            const head_entry = in_head orelse return error.TargetNotInHead;
            const index_entry = in_index orelse return error.TargetHasUncommittedChanges;
            if (!std.mem.eql(u8, index_entry.oid, head_entry.oid) or !std.mem.eql(u8, index_entry.mode, head_entry.mode)) return error.TargetHasUncommittedChanges;
            try present.append(git.arena, path);
        } else if (in_head != null or in_index != null) return error.TargetHasUncommittedChanges;
    }
    const stored = try storedOids(git, present.items);
    for (present.items, stored) |path, oid| {
        if (!std.mem.eql(u8, inTree(tree, path).?.oid, oid)) return error.TargetHasUncommittedChanges;
    }
}

fn indexPath(git: Git) ![]const u8 {
    const listed = try git.need(&.{ "rev-parse", "--git-path", "index" });
    if (std.fs.path.isAbsolute(listed)) {
        const out = try git.arena.dupe(u8, listed);
        std.mem.replaceScalar(u8, out, '/', '\\');
        return out;
    }
    return absOf(git.arena, git.root, listed);
}

fn lockPath(git: Git) ![]const u8 {
    return std.fmt.allocPrint(git.arena, "{s}.lock", .{try indexPath(git)});
}

pub fn currentBranch(gpa: Allocator, io: std.Io, root: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const git = try Git.init(arena_state.allocator(), io, root);
    return gpa.dupe(u8, try branchOf(git));
}

fn branchOf(git: Git) ![]const u8 {
    const ref = (try git.run(&.{ "symbolic-ref", "-q", "HEAD" })) orelse return error.DetachedHead;
    if (!std.mem.startsWith(u8, ref, branch_prefix)) return error.DetachedHead;
    return ref;
}

pub fn preflight(gpa: Allocator, io: std.Io, root: []const u8, rels: []const []const u8) !Head {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const git = try Git.init(arena, io, root);

    _ = try branchOf(git);
    const oid = (try git.run(&.{ "rev-parse", "--verify", "-q", "HEAD^{commit}" })) orelse return error.NoCommitYet;
    const tree = try git.need(&.{ "rev-parse", "--verify", "-q", "HEAD^{tree}" });

    const git_dir = try git.need(&.{ "rev-parse", "--absolute-git-dir" });
    for (in_progress) |name| {
        const path = try std.fs.path.join(arena, &.{ git_dir, name });
        if (try exists(io, path)) return error.OperationInProgress;
    }
    if (try exists(io, try lockPath(git))) return error.IndexLocked;

    if (try git.run(&.{ "config", "--type=bool", "--get", "commit.gpgsign" })) |value| {
        if (std.mem.eql(u8, value, "true")) return error.SigningNotSupported;
    }
    if (try git.run(&.{ "var", "GIT_COMMITTER_IDENT" }) == null) return error.NoCommitIdentity;

    try measure(git, oid, try survey(git, rels));

    const owned_oid = try gpa.dupe(u8, oid);
    errdefer gpa.free(owned_oid);
    return .{ .oid = owned_oid, .tree = try gpa.dupe(u8, tree) };
}

pub fn remeasure(gpa: Allocator, io: std.Io, root: []const u8, head: Head, changes: []const Change) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const git = try Git.init(arena, io, root);
    const rels = try arena.alloc([]const u8, changes.len);
    for (changes, rels) |change, *slot| slot.* = change.rel;
    try measure(git, head.oid, try survey(git, rels));
}

const Work = struct {
    io: std.Io,
    dir: []const u8,
    held: own_dir.Held,

    fn open(arena: Allocator, io: std.Io, root: []const u8) !Work {
        const dir = try std.fs.path.join(arena, &.{ root, shadow.workspace_dir, work_dir });
        const held = (try own_dir.hold(io, dir, .create)).?;
        const work: Work = .{ .io = io, .dir = dir, .held = held };
        work.sweep();
        return work;
    }

    fn sweep(self: Work) void {
        var names: [64][]const u8 = undefined;
        var buffer: [64 * 32]u8 = undefined;
        while (true) {
            var count: usize = 0;
            var used: usize = 0;
            var it = self.held.dir.iterate();
            while (it.next(self.io) catch return) |entry| {
                if (entry.kind != .file or !ours(entry.name)) continue;
                if (count == names.len or used + entry.name.len > buffer.len) break;
                @memcpy(buffer[used..][0..entry.name.len], entry.name);
                names[count] = buffer[used..][0..entry.name.len];
                used += entry.name.len;
                count += 1;
            }
            if (count == 0) return;
            var removed: usize = 0;
            for (names[0..count]) |name| {
                if (self.held.dir.deleteFile(self.io, name)) |_| removed += 1 else |_| {}
            }
            if (removed == 0) return;
        }
    }

    fn ours(name: []const u8) bool {
        for ([_][]const u8{ "index", "index.lock", "message" }) |known| {
            if (std.mem.eql(u8, name, known)) return true;
        }
        return name.len <= 24 and own_dir.numbered(name, "blob-", "");
    }

    fn done(self: Work) void {
        self.sweep();
        self.held.close();
        _ = own_dir.removeEmpty(self.dir);
    }
};

pub fn prepare(gpa: Allocator, io: std.Io, root: []const u8, head: Head, changes: []const Change, message: []const u8) !Prepared {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const git = try Git.init(arena, io, root);

    const work = try Work.open(arena, io, root);
    defer work.done();
    const dir = work.dir;

    var rels: std.ArrayList([]const u8) = .empty;
    for (changes) |change| try rels.append(arena, change.rel);
    for (changes) |change| try rels.append(arena, change.mode_from orelse change.rel);
    const seen = try survey(git, rels.items);
    const paths = seen.paths[0..changes.len];
    const mode_paths = seen.paths[changes.len..];
    const tree_before = try treeEntries(git, head.oid, seen.paths);

    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |entry| {
            gpa.free(entry.path);
            if (entry.blob) |blob| gpa.free(blob);
        }
        entries.deinit(gpa);
    }
    for (changes, paths, mode_paths, 0..) |change, path, mode_path, i| {
        var entry: Entry = .{ .path = try gpa.dupe(u8, path), .mode = "100644".*, .blob = null };
        errdefer gpa.free(entry.path);
        if (inTree(tree_before, mode_path)) |from| {
            if (from.mode.len == 6) @memcpy(&entry.mode, from.mode);
        }
        if (change.content) |content| {
            const blob_path = try std.fmt.allocPrint(arena, "{s}\\blob-{d}", .{ dir, i });
            try disk.writeDurably(io, blob_path, content);
            const path_arg = try std.fmt.allocPrint(arena, "--path={s}", .{path});
            entry.blob = try gpa.dupe(u8, try git.need(&.{ "hash-object", "-w", path_arg, "--", blob_path }));
        }
        errdefer if (entry.blob) |blob| gpa.free(blob);
        try entries.append(gpa, entry);
    }

    const private = try git.withIndex(try std.fs.path.join(arena, &.{ dir, "index" }));
    _ = try private.need(&.{ "read-tree", head.oid });
    try applyEntries(private, entries.items);
    const tree = try private.need(&.{"write-tree"});
    if (std.mem.eql(u8, tree, head.tree)) return error.NothingToCommit;

    const message_path = try std.fs.path.join(arena, &.{ dir, "message" });
    try disk.writeDurably(io, message_path, try commit_message.stored(arena, message));
    const commit = try gpa.dupe(u8, try git.need(&.{ "-c", "i18n.commitEncoding=UTF-8", "commit-tree", tree, "-p", head.oid, "-F", message_path }));
    errdefer gpa.free(commit);
    return .{ .commit = commit, .entries = try entries.toOwnedSlice(gpa) };
}

fn applyEntries(git: Git, entries: []const Entry) !void {
    var at: usize = 0;
    while (at < entries.len) {
        const end = @min(entries.len, at + paths_per_call);
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(git.arena, &.{ "update-index", "--add" });
        var removed: std.ArrayList([]const u8) = .empty;
        for (entries[at..end]) |*entry| {
            if (entry.blob) |blob| {
                try argv.appendSlice(git.arena, &.{ "--cacheinfo", &entry.mode, blob, entry.path });
            } else try removed.append(git.arena, entry.path);
        }
        if (removed.items.len != 0) {
            try argv.appendSlice(git.arena, &.{ "--force-remove", "--" });
            try argv.appendSlice(git.arena, removed.items);
        }
        _ = try git.need(argv.items);
        at = end;
    }
}

fn digestOf(arena: Allocator, io: std.Io, path: []const u8) !?Digest {
    const bytes = Dir.cwd().readFileAlloc(io, path, arena, .limited(max_index_bytes)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return error.GitFailed,
    };
    var out: Digest = undefined;
    Sha256.hash(bytes, &out, .{});
    return out;
}

pub const StagedIndex = struct {
    base: Digest,
    digest: Digest,
};

pub fn stageIndex(gpa: Allocator, io: std.Io, root: []const u8, entries: []const Entry, staged_abs: []const u8) !StagedIndex {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const git = try Git.init(arena, io, root);
    const index = try indexPath(git);
    const bytes = Dir.cwd().readFileAlloc(io, index, arena, .limited(max_index_bytes)) catch return error.GitFailed;
    var base: Digest = undefined;
    Sha256.hash(bytes, &base, .{});
    Dir.deleteFileAbsolute(io, staged_abs) catch {};
    disk.copyWithTimes(io, index, staged_abs) catch return error.GitFailed;
    errdefer Dir.deleteFileAbsolute(io, staged_abs) catch {};
    const copied = (try digestOf(arena, io, staged_abs)) orelse return error.GitFailed;
    if (!std.mem.eql(u8, &copied, &base)) return error.IndexChanged;
    try applyEntries(try git.withIndex(staged_abs), entries);
    const digest = (try digestOf(arena, io, staged_abs)) orelse return error.GitFailed;
    return .{ .base = base, .digest = digest };
}

pub fn acquireIndex(gpa: Allocator, io: std.Io, root: []const u8, staged_abs: []const u8, staged: StagedIndex) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const git = try Git.init(arena, io, root);
    const lock = try lockPath(git);
    disk.moveExclusive(gpa, staged_abs, lock) catch |err| switch (err) {
        error.PathAlreadyExists => return error.IndexLocked,
        else => return error.GitFailed,
    };
    const now = try digestOf(arena, io, try indexPath(git));
    if (now == null or !std.mem.eql(u8, &now.?, &staged.base)) {
        Dir.deleteFileAbsolute(io, lock) catch {};
        return error.IndexChanged;
    }
}

pub const LockState = enum { absent, ours, foreign };

pub fn lockState(gpa: Allocator, io: std.Io, root: []const u8, digest: Digest) !LockState {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const git = try Git.init(arena, io, root);
    const found = (try digestOf(arena, io, try lockPath(git))) orelse return .absent;
    return if (std.mem.eql(u8, &found, &digest)) .ours else .foreign;
}

pub fn releaseIndex(gpa: Allocator, io: std.Io, root: []const u8, digest: Digest) !void {
    if (try lockState(gpa, io, root, digest) != .ours) return;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const git = try Git.init(arena_state.allocator(), io, root);
    Dir.deleteFileAbsolute(io, try lockPath(git)) catch return error.GitFailed;
}

pub var publish_refusals: usize = 0;

pub fn publishIndex(gpa: Allocator, io: std.Io, root: []const u8, digest: Digest) !bool {
    if (try lockState(gpa, io, root, digest) != .ours) return false;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const git = try Git.init(arena_state.allocator(), io, root);
    const lock = try lockPath(git);
    const index = try indexPath(git);
    var attempt: usize = 0;
    while (attempt < publish_attempts) : (attempt += 1) {
        if (attempt != 0) io.sleep(.fromMilliseconds(publish_retry_ms), .awake) catch {};
        if (builtin.is_test and publish_refusals != 0) {
            publish_refusals -= 1;
            continue;
        }
        disk.moveOver(gpa, lock, index) catch continue;
        return true;
    }
    return false;
}

pub fn moveBranch(gpa: Allocator, io: std.Io, root: []const u8, branch: []const u8, commit: []const u8, base: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const git = try Git.init(arena_state.allocator(), io, root);
    if (try git.run(&.{ "update-ref", "-m", "emetgate: commit", branch, commit, base }) != null) return;
    const now = (try git.run(&.{ "rev-parse", "--verify", "-q", branch })) orelse return error.BranchMoved;
    if (std.mem.eql(u8, now, commit)) return;
    return if (std.mem.eql(u8, now, base)) error.BranchUpdateRefused else error.BranchMoved;
}

pub fn storesAs(gpa: Allocator, io: std.Io, root: []const u8, path: []const u8, file_abs: []const u8, blob: []const u8) !bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const git = try Git.init(arena, io, root);
    const path_arg = try std.fmt.allocPrint(arena, "--path={s}", .{path});
    return std.mem.eql(u8, try git.need(&.{ "hash-object", path_arg, "--", file_abs }), blob);
}

pub fn blobAt(gpa: Allocator, io: std.Io, root: []const u8, rev: []const u8, path: []const u8) !?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const git = try Git.init(arena, io, root);
    const paths = [_][]const u8{path};
    const found = inTree(try treeEntries(git, rev, &paths), path) orelse return null;
    return try gpa.dupe(u8, found.oid);
}

pub const Standing = struct {
    on_commit: bool,
    wanted: []bool,
    indexed: []bool,

    pub fn deinit(self: Standing, gpa: Allocator) void {
        gpa.free(self.wanted);
        gpa.free(self.indexed);
    }

    pub fn any(self: Standing) bool {
        for (self.wanted) |w| if (w) return true;
        return false;
    }
};

pub fn standing(gpa: Allocator, io: std.Io, root: []const u8, branch: []const u8, commit: []const u8, entries: []const Entry) !Standing {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const git = try Git.init(arena, io, root);
    const wanted = try gpa.alloc(bool, entries.len);
    errdefer gpa.free(wanted);
    const indexed = try gpa.alloc(bool, entries.len);
    errdefer gpa.free(indexed);
    @memset(wanted, false);
    @memset(indexed, false);

    const head_ref = try git.run(&.{ "symbolic-ref", "-q", "HEAD" });
    const head_oid = (try git.run(&.{ "rev-parse", "--verify", "-q", "HEAD^{commit}" })) orelse return .{ .on_commit = false, .wanted = wanted, .indexed = indexed };
    const on_commit = head_ref != null and std.mem.eql(u8, head_ref.?, branch) and std.mem.eql(u8, head_oid, commit);

    const paths = try arena.alloc([]const u8, entries.len);
    for (entries, paths) |entry, *slot| slot.* = entry.path;
    const tree = try treeEntries(git, head_oid, paths);
    const index = try indexEntries(git, paths, false);
    for (entries, wanted, indexed) |entry, *want, *have| {
        const in_head = inTree(tree, entry.path);
        const in_index = tracked(index, entry.path);
        if (entry.blob) |blob| {
            want.* = in_head != null and std.mem.eql(u8, in_head.?.oid, blob);
            have.* = in_index != null and in_index.?.stage == 0 and std.mem.eql(u8, in_index.?.oid, blob);
        } else {
            want.* = in_head == null;
            have.* = in_index == null;
        }
    }
    return .{ .on_commit = on_commit, .wanted = wanted, .indexed = indexed };
}

pub fn updateIndex(gpa: Allocator, io: std.Io, root: []const u8, entries: []const Entry) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const git = try Git.init(arena_state.allocator(), io, root);
    try applyEntries(git, entries);
}

pub const Delta = struct {
    files: [][]u8,
    restore: [][]u8,

    pub fn deinit(self: Delta, gpa: Allocator) void {
        for (self.files) |file| gpa.free(file);
        gpa.free(self.files);
        for (self.restore) |file| gpa.free(file);
        gpa.free(self.restore);
    }
};

fn putAll(arena: Allocator, set: *std.StringHashMapUnmanaged(void), out: []const u8) !void {
    var it = std.mem.tokenizeScalar(u8, out, 0);
    while (it.next()) |path| try set.put(arena, path, {});
}

pub fn committedTree(gpa: Allocator, io: std.Io, root: []const u8, head: Head) !Delta {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const git = try Git.init(arena, io, root);

    var listed: std.ArrayList(Tracked) = .empty;
    try parseTracked(arena, try git.needRaw(&.{ "ls-files", "-z", "-s", "-v" }), &listed);
    var in_head: std.StringHashMapUnmanaged(void) = .empty;
    try putAll(arena, &in_head, try git.needRaw(&.{ "ls-tree", "-r", "-z", "--name-only", head.oid }));

    var differs: std.StringHashMapUnmanaged(void) = .empty;
    var staged = std.mem.tokenizeScalar(u8, try git.needRaw(&.{ "diff-index", "--cached", "--no-renames", "--name-status", "-z", head.oid }), 0);
    while (staged.next()) |_| try differs.put(arena, staged.next() orelse return error.GitFailed, {});
    try putAll(arena, &differs, try git.needRaw(&.{ "diff-files", "--name-only", "-z" }));

    var flagged: std.ArrayList(Tracked) = .empty;
    for (listed.items) |entry| {
        if (entry.stage != 0) {
            try differs.put(arena, entry.path, {});
            continue;
        }
        if (entry.tag != 'S' and !std.ascii.isLower(entry.tag)) continue;
        if (try exists(io, try absOf(arena, root, entry.path))) try flagged.append(arena, entry) else try differs.put(arena, entry.path, {});
    }
    const flagged_paths = try arena.alloc([]const u8, flagged.items.len);
    for (flagged.items, flagged_paths) |entry, *slot| slot.* = entry.path;
    for (flagged.items, try storedOids(git, flagged_paths)) |entry, oid| {
        if (!std.mem.eql(u8, entry.oid, oid)) try differs.put(arena, entry.path, {});
    }

    var files: std.ArrayList([]u8) = .empty;
    errdefer {
        for (files.items) |file| gpa.free(file);
        files.deinit(gpa);
    }
    var restore: std.ArrayList([]u8) = .empty;
    errdefer {
        for (restore.items) |file| gpa.free(file);
        restore.deinit(gpa);
    }
    var last: []const u8 = "";
    for (listed.items) |entry| {
        if (std.mem.eql(u8, entry.path, last)) continue;
        last = entry.path;
        if (differs.contains(entry.path)) continue;
        const copy = try gpa.dupe(u8, entry.path);
        errdefer gpa.free(copy);
        try files.append(gpa, copy);
    }
    var it = differs.keyIterator();
    while (it.next()) |path| {
        if (!in_head.contains(path.*)) continue;
        const copy = try gpa.dupe(u8, path.*);
        errdefer gpa.free(copy);
        try restore.append(gpa, copy);
    }
    const owned_files = try files.toOwnedSlice(gpa);
    errdefer {
        for (owned_files) |file| gpa.free(file);
        gpa.free(owned_files);
    }
    return .{ .files = owned_files, .restore = try restore.toOwnedSlice(gpa) };
}

pub fn checkoutInto(gpa: Allocator, io: std.Io, root: []const u8, head: Head, paths: []const []const u8, target_abs: []const u8) !void {
    if (paths.len == 0) return;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const git = try Git.init(arena, io, root);
    const work = try Work.open(arena, io, root);
    defer work.done();
    const dir = work.dir;
    const private = try git.withIndex(try std.fs.path.join(arena, &.{ dir, "index" }));
    _ = try private.need(&.{ "read-tree", head.oid });
    const prefix = try std.fmt.allocPrint(arena, "--prefix={s}/", .{try slashed(arena, target_abs)});
    var at: usize = 0;
    while (at < paths.len) {
        const end = @min(paths.len, at + paths_per_call);
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ "checkout-index", "-f", "-q", prefix, "--" });
        try argv.appendSlice(arena, paths[at..end]);
        _ = try private.need(argv.items);
        at = end;
    }
}
