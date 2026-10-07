const std = @import("std");
const builtin = @import("builtin");
const exe_path = @import("exe_path.zig");
const shadow = @import("shadow.zig");
const disk = @import("disk.zig");
const commit_message = @import("commit_message.zig");
const symbol = @import("../engine/symbol.zig");
const own_dir = @import("own_dir.zig");
const sandbox = @import("sandbox.zig");
const commit_names = @import("commit_names.zig");
const commit_refusal = @import("commit_refusal.zig");

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
    TrackedNamesDifferOnlyInCase,
    GateTreeNotHead,
    GateTreeNotDerived,
};

pub const Measured = struct {
    path: []u8,
    mode: ?[6]u8 = null,
    oid: ?[]u8 = null,
    raw: ?symbol.Hash = null,
};

pub const Conversion = [32]u8;

pub const Head = struct {
    oid: []u8,
    tree: []u8,
    branch: []u8 = &.{},
    git_dir: []u8 = &.{},
    index: []u8 = &.{},
    icase: bool = false,
    conversion: Conversion = @splat('0'),
    measured: []Measured = &.{},
    listing: []u8 = &.{},

    pub fn deinit(self: Head, gpa: Allocator) void {
        gpa.free(self.listing);
        gpa.free(self.oid);
        gpa.free(self.tree);
        gpa.free(self.branch);
        gpa.free(self.git_dir);
        gpa.free(self.index);
        for (self.measured) |m| {
            gpa.free(m.path);
            if (m.oid) |oid| gpa.free(oid);
        }
        gpa.free(self.measured);
    }

    pub fn find(self: Head, path: []const u8) ?Measured {
        for (self.measured) |m| {
            if (samePath(m.path, path, self.icase)) return m;
        }
        return null;
    }
};

fn samePath(a: []const u8, b: []const u8, icase: bool) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const nx: u8 = if (x == '\\') '/' else if (icase) std.ascii.toLower(x) else x;
        const ny: u8 = if (y == '\\') '/' else if (icase) std.ascii.toLower(y) else y;
        if (nx != ny) return false;
    }
    return true;
}

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

pub const Git = struct {
    arena: Allocator,
    io: std.Io,
    root: []const u8,
    exe: []const u8,
    env: ?*const std.process.Environ.Map = null,
    hex: usize = 40,

    pub fn init(arena: Allocator, io: std.Io, root: []const u8) !Git {
        return .{ .arena = arena, .io = io, .root = root, .exe = try exe_path.git(arena, root) };
    }

    pub fn raw(self: Git, argv: []const []const u8) !?[]const u8 {
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

    pub fn run(self: Git, argv: []const []const u8) !?[]const u8 {
        const out = (try self.raw(argv)) orelse return null;
        return std.mem.trim(u8, out, " \r\n");
    }

    pub fn need(self: Git, argv: []const []const u8) ![]const u8 {
        return (try self.run(argv)) orelse error.GitFailed;
    }

    pub fn needRaw(self: Git, argv: []const []const u8) ![]const u8 {
        return (try self.raw(argv)) orelse error.GitFailed;
    }

    pub fn feed(self: Git, argv: []const []const u8, input: []const u8) !?[]const u8 {
        var full: std.ArrayList([]const u8) = .empty;
        try full.appendSlice(self.arena, &.{ self.exe, "-c", "core.longpaths=true", "-c", "core.fsmonitor=false" });
        try full.appendSlice(self.arena, argv);
        var child = std.process.spawn(self.io, .{
            .argv = full.items,
            .cwd = .{ .path = self.root },
            .environ_map = self.env,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .create_no_window = true,
        }) catch return error.GitFailed;
        defer child.kill(self.io);
        {
            const stdin = child.stdin.?;
            child.stdin = null;
            defer stdin.close(self.io);
            stdin.writeStreamingAll(self.io, input) catch return error.GitFailed;
        }
        var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
        var reader: std.Io.File.MultiReader = undefined;
        reader.init(self.arena, self.io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
        defer reader.deinit();
        while (reader.fill(64, .none)) |_| {
            if (reader.reader(0).buffered().len > max_git_output) return error.GitFailed;
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => return error.GitFailed,
        }
        reader.checkAnyError() catch return error.GitFailed;
        const term = child.wait(self.io) catch return error.GitFailed;
        const out = reader.toOwnedSlice(0) catch return error.GitFailed;
        return switch (term) {
            .exited => |code| if (code == 0) out else null,
            else => error.GitFailed,
        };
    }

    pub fn fed(self: Git, argv: []const []const u8, input: []const u8) ![]const u8 {
        const out = (try self.feed(argv, input)) orelse return error.GitFailed;
        return std.mem.trim(u8, out, " \r\n");
    }

    pub fn withIndex(self: Git, index_path: []const u8) !Git {
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

pub fn absOf(arena: Allocator, root: []const u8, path: []const u8) ![]u8 {
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

pub const TreeEntry = struct {
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

pub fn parseTree(arena: Allocator, out: []const u8, list: *std.ArrayList(TreeEntry)) !void {
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

pub fn inTree(entries: []const TreeEntry, path: []const u8) ?TreeEntry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.path, path) and std.mem.eql(u8, entry.kind, "blob")) return entry;
    }
    return null;
}

const Survey = struct {
    paths: []const []const u8,
    index: []const Tracked,
};

fn surveyWith(git: Git, rels: []const []const u8, icase: bool) !Survey {
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

fn measure(git: Git, tree: []const TreeEntry, seen: Survey, out: ?*std.ArrayList(Measured), gpa: Allocator) !void {
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
        var raw: ?symbol.Hash = null;
        if (try contentOf(git, path)) |bytes| {
            const head_entry = in_head orelse return error.TargetNotInHead;
            const index_entry = in_index orelse return error.TargetHasUncommittedChanges;
            if (!std.mem.eql(u8, index_entry.oid, head_entry.oid) or !std.mem.eql(u8, index_entry.mode, head_entry.mode)) return error.TargetHasUncommittedChanges;
            const path_arg = try std.fmt.allocPrint(git.arena, "--path={s}", .{path});
            const stored = try git.fed(&.{ "hash-object", "--stdin", path_arg }, bytes);
            if (!std.mem.eql(u8, head_entry.oid, stored)) return error.TargetHasUncommittedChanges;
            raw = symbol.hashOf(bytes);
        } else if (in_head != null or in_index != null) return error.TargetHasUncommittedChanges;
        const list = out orelse continue;
        var one: Measured = .{ .path = try gpa.dupe(u8, path), .raw = raw };
        errdefer gpa.free(one.path);
        if (in_head) |entry| {
            if (entry.mode.len == 6) one.mode = entry.mode[0..6].*;
            one.oid = try gpa.dupe(u8, entry.oid);
        }
        errdefer if (one.oid) |oid| gpa.free(oid);
        try list.append(gpa, one);
    }
}

fn contentOf(git: Git, path: []const u8) !?[]const u8 {
    return Dir.cwd().readFileAlloc(git.io, try absOf(git.arena, git.root, path), git.arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => null,
        error.OutOfMemory => error.OutOfMemory,
        else => error.GitFailed,
    };
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

const Facts = struct {
    git_dir: []const u8,
    index: []const u8,
    attributes: []const u8,
    oid: []const u8,
    tree: []const u8,
    branch: []const u8,
};

fn facts(git: Git) !Facts {
    const out = (try git.run(&.{ "rev-parse", "--absolute-git-dir", "--git-path", "index", "--git-path", "info/attributes", "HEAD^{commit}", "HEAD^{tree}", "--symbolic-full-name", "HEAD" })) orelse {
        if (try git.run(&.{ "rev-parse", "--verify", "-q", "HEAD^{commit}" }) == null) return error.NoCommitYet;
        return error.GitFailed;
    };
    var lines = std.mem.tokenizeAny(u8, out, "\r\n");
    const git_dir = lines.next() orelse return error.GitFailed;
    const listed = lines.next() orelse return error.GitFailed;
    const attributes_listed = lines.next() orelse return error.GitFailed;
    const oid = lines.next() orelse return error.GitFailed;
    const tree = lines.next() orelse return error.GitFailed;
    const branch = lines.next() orelse return error.DetachedHead;
    if (!std.mem.startsWith(u8, branch, branch_prefix)) return error.DetachedHead;
    return .{ .git_dir = git_dir, .index = try listedPath(git, listed), .attributes = try listedPath(git, attributes_listed), .oid = oid, .tree = tree, .branch = branch };
}

fn listedPath(git: Git, listed: []const u8) ![]const u8 {
    if (!std.fs.path.isAbsolute(listed)) return absOf(git.arena, git.root, listed);
    const copy = try git.arena.dupe(u8, listed);
    std.mem.replaceScalar(u8, copy, '/', '\\');
    return copy;
}

const Settings = struct {
    signing: bool = false,
    icase: bool = false,
    attributes_file: ?[]const u8 = null,
    conversion: std.crypto.hash.Blake3 = std.crypto.hash.Blake3.init(.{}),
};

const conversion_keys = [_][]const u8{ "core.autocrlf", "core.eol", "core.symlinks", "core.attributesfile" };

fn shapesCheckout(key: []const u8) bool {
    if (std.ascii.startsWithIgnoreCase(key, "filter.")) return true;
    for (conversion_keys) |known| {
        if (std.ascii.eqlIgnoreCase(key, known)) return true;
    }
    return false;
}

fn homeFile(arena: Allocator, rest: []const u8) !?[]const u8 {
    if (builtin.os.tag != .windows) return null;
    const names = [_][:0]const u16{ std.unicode.utf8ToUtf16LeStringLiteral("HOME"), std.unicode.utf8ToUtf16LeStringLiteral("USERPROFILE") };
    for (names) |name| {
        const home = (try sandbox.environmentValue(arena, name)) orelse continue;
        return try std.fs.path.join(arena, &.{ home, rest });
    }
    return null;
}

fn userAttributes(arena: Allocator, named: ?[]const u8) !?[]const u8 {
    if (named) |path| {
        if (std.mem.startsWith(u8, path, "~/")) return homeFile(arena, path[2..]);
        return path;
    }
    if (builtin.os.tag != .windows) return null;
    if (try sandbox.environmentValue(arena, std.unicode.utf8ToUtf16LeStringLiteral("XDG_CONFIG_HOME"))) |base| return try std.fs.path.join(arena, &.{ base, "git", "attributes" });
    return homeFile(arena, ".config/git/attributes");
}

fn mixFile(git: Git, hasher: *std.crypto.hash.Blake3, path: ?[]const u8) !void {
    const bytes: []const u8 = if (path) |abs| blk: {
        if (!std.fs.path.isAbsolute(abs)) break :blk "";
        break :blk std.Io.Dir.cwd().readFileAlloc(git.io, abs, git.arena, .limited(max_index_bytes)) catch |err| switch (err) {
            error.FileNotFound => "",
            else => return error.GitFailed,
        };
    } else "";
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, bytes.len, .little);
    hasher.update(&length);
    hasher.update(bytes);
}

fn conversionOf(git: Git, set: *Settings, info_attributes: []const u8) !Conversion {
    try mixFile(git, &set.conversion, info_attributes);
    try mixFile(git, &set.conversion, try userAttributes(git.arena, set.attributes_file));
    var digest: [16]u8 = undefined;
    set.conversion.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn truthy(value: ?[]const u8) bool {
    const text = value orelse return true;
    for ([_][]const u8{ "true", "yes", "on", "1" }) |word| {
        if (std.ascii.eqlIgnoreCase(text, word)) return true;
    }
    return false;
}

fn settings(git: Git) !Settings {
    const out = try git.needRaw(&.{ "config", "--list", "-z" });
    var found: Settings = .{};
    var entries = std.mem.tokenizeScalar(u8, out, 0);
    while (entries.next()) |entry| {
        const cut = std.mem.indexOfScalar(u8, entry, '\n');
        const key = if (cut) |at| entry[0..at] else entry;
        const value: ?[]const u8 = if (cut) |at| entry[at + 1 ..] else null;
        if (std.ascii.eqlIgnoreCase(key, "commit.gpgsign")) found.signing = truthy(value);
        if (std.ascii.eqlIgnoreCase(key, "core.ignorecase")) found.icase = truthy(value);
        if (std.ascii.eqlIgnoreCase(key, "core.attributesfile")) found.attributes_file = value;
        if (shapesCheckout(key)) {
            found.conversion.update(entry);
            found.conversion.update(&.{0});
        }
    }
    return found;
}

pub fn preflight(gpa: Allocator, io: std.Io, root: []const u8, rels: []const []const u8) !Head {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const git = try Git.init(arena, io, root);

    const known = try facts(git);
    for (in_progress) |name| {
        const path = try std.fs.path.join(arena, &.{ known.git_dir, name });
        if (try exists(io, path)) return error.OperationInProgress;
    }
    if (try exists(io, try std.fmt.allocPrint(arena, "{s}.lock", .{known.index}))) return error.IndexLocked;

    const listing = try git.needRaw(&.{ "ls-tree", "-r", "-z", known.oid });
    var held: std.ArrayList(TreeEntry) = .empty;
    try parseTree(arena, listing, &held);
    if (try caseClash(arena, held.items)) |pair| {
        commit_refusal.note(&.{ pair.first, pair.second }, 2);
        return error.TrackedNamesDifferOnlyInCase;
    }

    var set = try settings(git);
    if (set.signing) return error.SigningNotSupported;
    const conversion = try conversionOf(git, &set, known.attributes);
    if (try git.run(&.{ "var", "GIT_COMMITTER_IDENT" }) == null) return error.NoCommitIdentity;

    var measured: std.ArrayList(Measured) = .empty;
    errdefer {
        for (measured.items) |m| {
            gpa.free(m.path);
            if (m.oid) |oid| gpa.free(oid);
        }
        measured.deinit(gpa);
    }
    try measure(git, held.items, try surveyWith(git, rels, set.icase), &measured, gpa);

    const oid = try gpa.dupe(u8, known.oid);
    errdefer gpa.free(oid);
    const tree = try gpa.dupe(u8, known.tree);
    errdefer gpa.free(tree);
    const branch = try gpa.dupe(u8, known.branch);
    errdefer gpa.free(branch);
    const git_dir = try gpa.dupe(u8, known.git_dir);
    errdefer gpa.free(git_dir);
    const index = try gpa.dupe(u8, known.index);
    errdefer gpa.free(index);
    const kept = try gpa.dupe(u8, listing);
    errdefer gpa.free(kept);
    return .{ .oid = oid, .tree = tree, .branch = branch, .git_dir = git_dir, .index = index, .icase = set.icase, .conversion = conversion, .measured = try measured.toOwnedSlice(gpa), .listing = kept };
}

fn caseClash(arena: Allocator, held: []const TreeEntry) !?commit_names.Clash {
    if (builtin.os.tag != .windows) return null;
    const names = try arena.alloc(commit_names.Name, held.len);
    for (held, names) |entry, *name| name.* = .{ .path = entry.path, .directory = !std.mem.eql(u8, entry.kind, "blob") };
    return commit_names.clash(arena, names);
}

pub fn branchNow(arena: Allocator, io: std.Io, root: []const u8, head: Head) ![]const u8 {
    const file = try std.fs.path.join(arena, &.{ head.git_dir, "HEAD" });
    if (Dir.cwd().readFileAlloc(io, file, arena, .limited(4096))) |bytes| {
        const text = std.mem.trim(u8, bytes, " \r\n");
        const prefix = "ref: ";
        if (std.mem.startsWith(u8, text, prefix) and std.mem.eql(u8, text[prefix.len..], head.branch)) return head.branch;
    } else |_| {}
    return branchOf(try Git.init(arena, io, root));
}

pub const Work = struct {
    io: std.Io,
    dir: []const u8,
    held: own_dir.Held,

    pub fn open(arena: Allocator, io: std.Io, root: []const u8) !Work {
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
        if (name.len > 24) return false;
        return own_dir.numbered(name, "blob-", "") or own_dir.numbered(name, "paths-", "") or own_dir.numbered(name, "oids-", "");
    }

    pub fn done(self: Work) void {
        self.sweep();
        self.held.close();
        _ = own_dir.removeEmpty(self.dir);
    }
};

pub fn prepare(gpa: Allocator, io: std.Io, root: []const u8, head: Head, lines: []const u8, derived: []const Entry, message: []const u8) !Prepared {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const git = try Git.init(arena, io, root);

    const work = try Work.open(arena, io, root);
    defer work.done();
    const dir = work.dir;

    var private = try git.withIndex(try std.fs.path.join(arena, &.{ dir, "index" }));
    private.hex = head.oid.len;
    _ = (try private.feed(&.{ "update-index", "-z", "--index-info" }, lines)) orelse return error.GitFailed;
    const tree = try private.need(&.{"write-tree"});
    if (std.mem.eql(u8, tree, head.tree)) return error.NothingToCommit;

    const entries = try gpa.alloc(Entry, derived.len);
    var made: usize = 0;
    errdefer {
        for (entries[0..made]) |entry| {
            gpa.free(entry.path);
            if (entry.blob) |blob| gpa.free(blob);
        }
        gpa.free(entries);
    }
    for (derived, entries) |from, *entry| {
        const path = try gpa.dupe(u8, from.path);
        errdefer gpa.free(path);
        entry.* = .{ .path = path, .mode = from.mode, .blob = if (from.blob) |blob| try gpa.dupe(u8, blob) else null };
        made += 1;
    }

    const commit = try gpa.dupe(u8, try git.fed(&.{ "-c", "i18n.commitEncoding=UTF-8", "commit-tree", tree, "-p", head.oid, "-F", "-" }, try commit_message.stored(arena, message)));
    return .{ .commit = commit, .entries = entries };
}

pub fn applyEntries(git: Git, entries: []const Entry) !void {
    if (entries.len == 0) return;
    var lines: std.ArrayList(u8) = .empty;
    for (entries) |*entry| {
        if (entry.blob) |blob| {
            try lines.appendSlice(git.arena, try std.fmt.allocPrint(git.arena, "{s} {s}\t{s}", .{ &entry.mode, blob, entry.path }));
        } else {
            try lines.appendSlice(git.arena, "0 ");
            try lines.appendNTimes(git.arena, '0', zeroLength(entries) orelse git.hex);
            try lines.append(git.arena, '\t');
            try lines.appendSlice(git.arena, entry.path);
        }
        try lines.append(git.arena, 0);
    }
    _ = (try git.feed(&.{ "update-index", "-z", "--index-info" }, lines.items)) orelse return error.GitFailed;
}

fn zeroLength(entries: []const Entry) ?usize {
    for (entries) |entry| {
        if (entry.blob) |blob| return blob.len;
    }
    return null;
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

pub fn stageChecked(gpa: Allocator, io: std.Io, root: []const u8, head: Head, entries: []const Entry, staged_abs: []const u8) !StagedIndex {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const git = try Git.init(arena, io, root);
    const bytes = Dir.cwd().readFileAlloc(io, head.index, arena, .limited(max_index_bytes)) catch return error.GitFailed;
    var base: Digest = undefined;
    Sha256.hash(bytes, &base, .{});
    Dir.deleteFileAbsolute(io, staged_abs) catch {};
    disk.copyWithTimes(io, head.index, staged_abs) catch return error.GitFailed;
    errdefer Dir.deleteFileAbsolute(io, staged_abs) catch {};
    const copied = (try digestOf(arena, io, staged_abs)) orelse return error.GitFailed;
    if (!std.mem.eql(u8, &copied, &base)) return error.IndexChanged;

    var private = try git.withIndex(staged_abs);
    private.hex = head.oid.len;
    const paths = try arena.alloc([]const u8, entries.len);
    for (entries, paths) |entry, *slot| slot.* = entry.path;
    const copy = try indexEntries(private, paths, false);
    for (entries) |entry| {
        const was = head.find(entry.path) orelse return error.TargetHasUncommittedChanges;
        var seen: usize = 0;
        for (copy) |found| {
            if (!std.mem.eql(u8, found.path, entry.path)) continue;
            seen += 1;
            const oid = was.oid orelse return error.TargetHasUncommittedChanges;
            const mode = was.mode orelse return error.TargetHasUncommittedChanges;
            if (found.stage != 0 or found.tag == 'S' or found.tag == 's') return error.TargetHasUncommittedChanges;
            if (!std.mem.eql(u8, found.oid, oid) or !std.mem.eql(u8, found.mode, &mode)) return error.TargetHasUncommittedChanges;
        }
        if (seen > 1 or (seen == 0) != (was.oid == null)) return error.TargetHasUncommittedChanges;
    }
    try applyEntries(private, entries);
    const digest = (try digestOf(arena, io, staged_abs)) orelse return error.GitFailed;
    return .{ .base = base, .digest = digest };
}

pub fn acquireHeld(gpa: Allocator, io: std.Io, head: Head, staged_abs: []const u8, staged: StagedIndex) !disk.Guard {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lock = try std.fmt.allocPrint(arena, "{s}.lock", .{head.index});
    const guard = disk.Guard.freeze(staged_abs) catch return error.GitFailed;
    errdefer guard.close();
    guard.renameTo(gpa, lock) catch |err| switch (err) {
        error.PathAlreadyExists => return error.IndexLocked,
        else => return error.GitFailed,
    };
    const now = try digestOf(arena, io, head.index);
    if (now == null or !std.mem.eql(u8, &now.?, &staged.base)) {
        guard.deleteSelf() catch {};
        return error.IndexChanged;
    }
    return guard;
}

pub fn publishHeld(gpa: Allocator, io: std.Io, head: Head, lock: disk.Guard) bool {
    var attempt: usize = 0;
    while (attempt < publish_attempts) : (attempt += 1) {
        if (attempt != 0) io.sleep(.fromMilliseconds(publish_retry_ms), .awake) catch {};
        if (builtin.is_test and publish_refusals != 0) {
            publish_refusals -= 1;
            continue;
        }
        lock.renameReplacing(gpa, head.index) catch continue;
        return true;
    }
    return false;
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

const batch_request_bytes = 1536;

pub fn blobs(arena: Allocator, io: std.Io, root: []const u8, specs: []const []const u8) ![]?[]const u8 {
    const git = try Git.init(arena, io, root);
    const found = try arena.alloc(?[]const u8, specs.len);
    var at: usize = 0;
    while (at < specs.len) {
        var request: std.ArrayList(u8) = .empty;
        var end = at;
        while (end < specs.len and (end == at or request.items.len + specs[end].len + 1 <= batch_request_bytes)) : (end += 1) {
            if (std.mem.indexOfAny(u8, specs[end], "\r\n") != null) return error.GitFailed;
            try request.appendSlice(arena, specs[end]);
            try request.append(arena, '\n');
        }
        const out = (try git.feed(&.{ "cat-file", "--batch" }, request.items)) orelse return error.GitFailed;
        var rest = out;
        for (found[at..end]) |*slot| {
            const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse return error.GitFailed;
            const line = rest[0..line_end];
            rest = rest[line_end + 1 ..];
            if (std.mem.endsWith(u8, line, " missing")) {
                slot.* = null;
                continue;
            }
            var fields = std.mem.tokenizeScalar(u8, line, ' ');
            _ = fields.next() orelse return error.GitFailed;
            const kind = fields.next() orelse return error.GitFailed;
            const size = std.fmt.parseInt(usize, fields.next() orelse return error.GitFailed, 10) catch return error.GitFailed;
            if (rest.len < size + 1) return error.GitFailed;
            slot.* = if (std.mem.eql(u8, kind, "blob")) rest[0..size] else null;
            rest = rest[size + 1 ..];
        }
        at = end;
    }
    return found;
}

pub fn storedForm(gpa: Allocator, io: std.Io, root: []const u8, path: []const u8, bytes: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const git = try Git.init(arena, io, root);
    const path_arg = try std.fmt.allocPrint(arena, "--path={s}", .{path});
    return gpa.dupe(u8, try git.fed(&.{ "hash-object", "--stdin", path_arg }, bytes));
}

pub const Lineage = struct {
    base: [][]u8,
    after: [][]u8,

    pub fn deinit(self: Lineage, gpa: Allocator) void {
        for (self.base) |oid| gpa.free(oid);
        gpa.free(self.base);
        for (self.after) |oid| gpa.free(oid);
        gpa.free(self.after);
    }
};

pub fn lineage(gpa: Allocator, io: std.Io, root: []const u8, commit: []const u8, base: []const u8, paths: []const []const u8) !?Lineage {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const git = try Git.init(arena, io, root);
    const listed = (try git.run(&.{ "rev-list", "--parents", "-n", "1", commit })) orelse return null;
    var ids = std.mem.tokenizeAny(u8, listed, " \r\n");
    const self_id = ids.next() orelse return null;
    const parent = ids.next() orelse return null;
    if (ids.next() != null) return null;
    if (!std.mem.eql(u8, self_id, commit) or !std.mem.eql(u8, parent, base)) return null;
    const before = try treeEntries(git, base, paths);
    const after = try treeEntries(git, commit, paths);
    const base_oids = try gpa.alloc([]u8, paths.len);
    var made: usize = 0;
    errdefer {
        for (base_oids[0..made]) |oid| gpa.free(oid);
        gpa.free(base_oids);
    }
    for (paths, base_oids) |path, *slot| {
        slot.* = try gpa.dupe(u8, if (inTree(before, path)) |entry| entry.oid else "");
        made += 1;
    }
    const after_oids = try gpa.alloc([]u8, paths.len);
    var done: usize = 0;
    errdefer {
        for (after_oids[0..done]) |oid| gpa.free(oid);
        gpa.free(after_oids);
    }
    for (paths, after_oids) |path, *slot| {
        slot.* = try gpa.dupe(u8, if (inTree(after, path)) |entry| entry.oid else "");
        done += 1;
    }
    return .{ .base = base_oids, .after = after_oids };
}

pub fn indexDigest(gpa: Allocator, io: std.Io, root: []const u8) !?Digest {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const git = try Git.init(arena, io, root);
    return digestOf(arena, io, try indexPath(git));
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

pub fn advanceIndex(gpa: Allocator, io: std.Io, root: []const u8, entries: []const Entry, staged_abs: []const u8, expected: Digest) !void {
    const staged = try stageIndex(gpa, io, root, entries, staged_abs);
    errdefer Dir.deleteFileAbsolute(io, staged_abs) catch {};
    if (!std.mem.eql(u8, &staged.base, &expected)) return error.IndexChanged;
    try acquireIndex(gpa, io, root, staged_abs, staged);
    if (!try publishIndex(gpa, io, root, staged.digest)) {
        try releaseIndex(gpa, io, root, staged.digest);
        return error.IndexLocked;
    }
}

pub fn updateIndex(gpa: Allocator, io: std.Io, root: []const u8, entries: []const Entry) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const git = try Git.init(arena_state.allocator(), io, root);
    try applyEntries(git, entries);
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

pub const gitlink_mode = "160000";
const absent_mode = "000000";

pub const TreeChange = struct {
    path: []const u8,
    mode: [6]u8,
    oid: []const u8,
    was: bool,
    now: bool,
};

fn holdsFile(mode: []const u8) bool {
    return !std.mem.eql(u8, mode, absent_mode) and !std.mem.eql(u8, mode, gitlink_mode);
}

pub fn treeChanges(arena: Allocator, io: std.Io, root: []const u8, from: []const u8, to: []const u8) ![]TreeChange {
    const git = try Git.init(arena, io, root);
    const out = try git.needRaw(&.{ "diff-tree", "-r", "-z", "--no-renames", "--raw", from, to });
    var list: std.ArrayList(TreeChange) = .empty;
    var it = std.mem.tokenizeScalar(u8, out, 0);
    while (it.next()) |meta| {
        const path = it.next() orelse return error.GitFailed;
        if (meta.len == 0 or meta[0] != ':') return error.GitFailed;
        var fields = std.mem.tokenizeScalar(u8, meta[1..], ' ');
        const old_mode = fields.next() orelse return error.GitFailed;
        const new_mode = fields.next() orelse return error.GitFailed;
        _ = fields.next() orelse return error.GitFailed;
        const oid = fields.next() orelse return error.GitFailed;
        if (old_mode.len != 6 or new_mode.len != 6) return error.GitFailed;
        try list.append(arena, .{ .path = path, .mode = new_mode[0..6].*, .oid = oid, .was = holdsFile(old_mode), .now = holdsFile(new_mode) });
    }
    return list.items;
}

fn checkoutAll(git: Git, private: Git, tree: []const u8, target_abs: []const u8) !void {
    const source = try std.fmt.allocPrint(git.arena, "--attr-source={s}", .{tree});
    const prefix = try std.fmt.allocPrint(git.arena, "--prefix={s}/", .{try slashed(git.arena, target_abs)});
    _ = try private.need(&.{ source, "-c", "checkout.workers=0", "checkout-index", "-f", "-q", "-a", prefix });
}

pub fn checkoutTree(gpa: Allocator, io: std.Io, root: []const u8, tree: []const u8, target_abs: []const u8) !usize {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const git = try Git.init(arena, io, root);
    const work = try Work.open(arena, io, root);
    defer work.done();
    const private = try git.withIndex(try std.fs.path.join(arena, &.{ work.dir, "index" }));
    _ = try private.need(&.{ "read-tree", tree });
    var count: usize = 0;
    var entries = std.mem.tokenizeScalar(u8, try private.needRaw(&.{ "ls-files", "-s", "-z" }), 0);
    while (entries.next()) |entry| {
        if (entry.len < 6) return error.GitFailed;
        if (holdsFile(entry[0..6])) count += 1;
    }
    try checkoutAll(git, private, tree, target_abs);
    return count;
}

pub fn checkoutChanges(gpa: Allocator, io: std.Io, root: []const u8, tree: []const u8, changes: []const TreeChange, target_abs: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const git = try Git.init(arena, io, root);
    var lines: std.ArrayList(u8) = .empty;
    for (changes) |change| {
        if (!change.now) continue;
        try lines.appendSlice(arena, try std.fmt.allocPrint(arena, "{s} {s}\t{s}", .{ &change.mode, change.oid, change.path }));
        try lines.append(arena, 0);
    }
    if (lines.items.len == 0) return;
    const work = try Work.open(arena, io, root);
    defer work.done();
    const private = try git.withIndex(try std.fs.path.join(arena, &.{ work.dir, "index" }));
    _ = (try private.feed(&.{ "update-index", "-z", "--index-info" }, lines.items)) orelse return error.GitFailed;
    try checkoutAll(git, private, tree, target_abs);
}
