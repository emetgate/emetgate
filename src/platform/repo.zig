const std = @import("std");
const bounded_run = @import("bounded_run.zig");
const shadow = @import("shadow.zig");
const sandbox = @import("sandbox.zig");
const exe_path = @import("exe_path.zig");
const open_nowait = @import("open_nowait.zig");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const max_git_output = 64 * 1024;

pub const Jailed = struct {
    root: []u8,
    abs: [:0]u8,
    rel: []u8,
    creates: bool = false,

    pub fn deinit(self: Jailed, gpa: Allocator) void {
        gpa.free(self.root);
        gpa.free(self.abs);
        gpa.free(self.rel);
    }
};

pub fn repoRoot(gpa: Allocator, io: std.Io) ![]u8 {
    return gitToplevel(gpa, io, ".");
}

pub fn servedRoot(gpa: Allocator, io: std.Io, root: ?[]const u8) ![]u8 {
    const spelled = if (root) |given| try gpa.dupe(u8, given) else try repoRoot(gpa, io);
    defer gpa.free(spelled);
    return finalOf(gpa, spelled);
}

pub fn finalOf(gpa: Allocator, path_abs: []const u8) ![]u8 {
    return try exe_path.finalDosPath(gpa, path_abs) orelse error.FileOutsideRepo;
}

pub fn finalPath(gpa: Allocator, io: std.Io, path: []const u8) ![:0]u8 {
    _ = io;
    // Resolve without waiting on a sharing conflict: the standard realpath
    // retries for seconds on a file another handle holds without sharing, which
    // would make read_file and a dir-as-file search stall instead of answering
    // at once. The no-wait resolver opens only for attributes, which does not
    // conflict, so a held file still resolves immediately.
    const opened = try open_nowait.realPath(gpa, path);
    defer gpa.free(opened);
    const final = try finalOf(gpa, opened);
    defer gpa.free(final);
    return gpa.dupeZ(u8, final);
}

pub fn jail(gpa: Allocator, io: std.Io, root: ?[]const u8, path: []const u8) !Jailed {
    const served = try servedRoot(gpa, io, root);
    errdefer gpa.free(served);
    try refuseInternalAsWritten(gpa, io, served, path);
    const abs = try finalPath(gpa, io, path);
    errdefer gpa.free(abs);
    const rel = try relativeTo(gpa, served, abs);
    errdefer gpa.free(rel);
    try refuseInternal(rel);
    if (rel.len != 0) try expectSameRepo(gpa, io, served, abs);
    return .{ .root = served, .abs = abs, .rel = rel };
}

pub fn refuseLinkAsWritten(gpa: Allocator, io: std.Io, path: []const u8) !void {
    const cwd_abs = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", gpa);
    defer gpa.free(cwd_abs);
    const resolved = try std.fs.path.resolve(gpa, &.{ cwd_abs, path });
    defer gpa.free(resolved);
    if (shadow.isReparsePoint(resolved) catch true) return error.ReparsePoint;
}

fn refuseInternalAsWritten(gpa: Allocator, io: std.Io, served: []const u8, path: []const u8) !void {
    const cwd_abs = try finalPath(gpa, io, ".");
    defer gpa.free(cwd_abs);
    const resolved = try std.fs.path.resolve(gpa, &.{ cwd_abs, path });
    defer gpa.free(resolved);
    const rel = relativeTo(gpa, served, resolved) catch |err| switch (err) {
        error.FileOutsideRepo => return,
        else => |e| return e,
    };
    defer gpa.free(rel);
    try refuseInternal(rel);
}

pub fn jailTarget(gpa: Allocator, io: std.Io, root: ?[]const u8, path: []const u8, may_create: bool) !Jailed {
    return jail(gpa, io, root, path) catch |err| switch (err) {
        error.FileNotFound => if (may_create) jailNew(gpa, io, root, path) else error.FileNotFound,
        else => |e| e,
    };
}

pub fn jailNew(gpa: Allocator, io: std.Io, root: ?[]const u8, path: []const u8) !Jailed {
    const name = std.fs.path.basename(path);
    if (name.len == 0 or std.mem.indexOfAny(u8, name, "/\\") != null) return error.InvalidPath;
    shadow.validateRelative(name) catch return error.InvalidPath;
    const parent = std.fs.path.dirname(path) orelse ".";

    const served = try servedRoot(gpa, io, root);
    errdefer gpa.free(served);
    const parent_abs = finalPath(gpa, io, parent) catch |err| switch (err) {
        error.FileNotFound => return error.ParentDirectoryMissing,
        else => |e| return e,
    };
    defer gpa.free(parent_abs);
    var parent_dir = std.Io.Dir.openDirAbsolute(io, parent_abs, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.ParentDirectoryMissing,
        else => |e| return e,
    };
    parent_dir.close(io);

    const joined = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ parent_abs, name });
    defer gpa.free(joined);
    const abs = try gpa.dupeZ(u8, joined);
    errdefer gpa.free(abs);
    const rel = try relativeTo(gpa, served, abs);
    errdefer gpa.free(rel);
    if (rel.len == 0) return error.InvalidPath;
    try refuseInternal(rel);
    try expectSameRepo(gpa, io, served, abs);
    std.Io.Dir.cwd().access(io, abs, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{ .root = served, .abs = abs, .rel = rel, .creates = true },
        else => |e| return e,
    };
    return error.FileExists;
}

pub fn isIgnored(gpa: Allocator, io: std.Io, root_abs: []const u8, rel: []const u8) !bool {
    const git = try exe_path.git(gpa, root_abs);
    defer gpa.free(git);
    const result = bounded_run.run(gpa, io, .{
        .argv = &.{ git, "check-ignore", "-q", "--no-index", "--", rel },
        .cwd = .{ .path = root_abs },
        .stdout_limit = .limited(max_git_output),
    }) catch return error.GitFailed;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return switch (result.term) {
        .exited => |code| switch (code) {
            0 => true,
            1 => false,
            else => error.GitFailed,
        },
        else => error.GitFailed,
    };
}

pub fn filesMentioning(gpa: Allocator, io: std.Io, root_abs: []const u8, word: []const u8) ![]u8 {
    const git = try exe_path.git(gpa, root_abs);
    defer gpa.free(git);
    const result = bounded_run.run(gpa, io, .{
        .argv = &.{ git, "grep", "-z", "-l", "-w", "-F", "-e", word, "--" },
        .cwd = .{ .path = root_abs },
        .stdout_limit = .limited(max_git_output),
    }) catch return error.GitFailed;
    defer gpa.free(result.stderr);
    errdefer gpa.free(result.stdout);
    switch (result.term) {
        .exited => |code| if (code != 0 and code != 1) return error.GitFailed,
        else => return error.GitFailed,
    }
    return result.stdout;
}

pub fn trackedListing(gpa: Allocator, io: std.Io, root_abs: []const u8, pathspec: []const u8) ![]u8 {
    if (try @import("git_native.zig").trackedUnder(gpa, io, root_abs, pathspec)) |listed| return listed;
    const git = try exe_path.git(gpa, root_abs);
    defer gpa.free(git);
    const result = bounded_run.run(gpa, io, .{
        .argv = &.{ git, "ls-files", "-z", "--", pathspec },
        .cwd = .{ .path = root_abs },
        .stdout_limit = .limited(max_git_output),
    }) catch return error.GitFailed;
    defer gpa.free(result.stderr);
    errdefer gpa.free(result.stdout);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitFailed,
        else => return error.GitFailed,
    }
    return result.stdout;
}

pub fn addToIndex(gpa: Allocator, io: std.Io, root_abs: []const u8, rel: []const u8) !void {
    const git = try exe_path.git(gpa, root_abs);
    defer gpa.free(git);
    var attempt: usize = 0;
    while (attempt < index_add_attempts) : (attempt += 1) {
        if (attempt != 0) io.sleep(.fromMilliseconds(index_retry_ms), .awake) catch {};
        const result = bounded_run.run(gpa, io, .{
            .argv = &.{ git, "add", "--", rel },
            .cwd = .{ .path = root_abs },
            .stdout_limit = .limited(max_git_output),
        }) catch continue;
        gpa.free(result.stdout);
        gpa.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code == 0) return,
            else => {},
        }
    }
    return error.WrittenButNotIndexed;
}

pub fn addAllToIndex(gpa: Allocator, io: std.Io, root_abs: []const u8, paths: []const []const u8) !void {
    return runOnPaths(gpa, io, root_abs, &.{ "-c", "core.longpaths=true", "add", "--" }, paths);
}

pub fn removeAllFromIndex(gpa: Allocator, io: std.Io, root_abs: []const u8, paths: []const []const u8) !void {
    return runOnPaths(gpa, io, root_abs, &.{ "-c", "core.longpaths=true", "rm", "--cached", "--ignore-unmatch", "-q", "--" }, paths);
}

pub fn indexEntriesOf(arena: Allocator, io: std.Io, root_abs: []const u8, rels: []const []const u8) ![]const []const u8 {
    const entries = try arena.alloc([]const u8, rels.len);
    @memset(entries, "");
    if (rels.len == 0) return entries;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ try exe_path.git(arena, root_abs), "--literal-pathspecs", "-c", "core.longpaths=true", "ls-files", "-s", "-z", "--" });
    try argv.appendSlice(arena, rels);
    const result = bounded_run.run(arena, io, .{
        .argv = argv.items,
        .cwd = .{ .path = root_abs },
        .stdout_limit = .limited(max_git_output),
    }) catch return error.GitFailed;
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitFailed,
        else => return error.GitFailed,
    }
    var records = std.mem.tokenizeScalar(u8, result.stdout, 0);
    while (records.next()) |record| {
        const tab = std.mem.indexOfScalar(u8, record, '\t') orelse continue;
        for (rels, entries) |rel, *entry| {
            if (!std.ascii.eqlIgnoreCase(rel, record[tab + 1 ..])) continue;
            entry.* = try std.mem.concat(arena, u8, &.{ entry.*, record, "\x00" });
            break;
        }
    }
    return entries;
}

pub fn putIndexEntry(gpa: Allocator, io: std.Io, root_abs: []const u8, rel: []const u8, entry: []const u8) !bool {
    var records = std.mem.tokenizeScalar(u8, entry, 0);
    const record = records.next() orelse {
        try runOnPaths(gpa, io, root_abs, &.{ "--literal-pathspecs", "-c", "core.longpaths=true", "rm", "--cached", "--ignore-unmatch", "-q", "--" }, &.{rel});
        return true;
    };
    if (records.next() != null) return false;
    const tab = std.mem.indexOfScalar(u8, record, '\t') orelse return false;
    var fields = std.mem.tokenizeScalar(u8, record[0..tab], ' ');
    const mode = fields.next() orelse return false;
    const oid = fields.next() orelse return false;
    const stage = fields.next() orelse return false;
    if (!std.mem.eql(u8, stage, "0")) return false;
    const info = try std.fmt.allocPrint(gpa, "{s},{s},{s}", .{ mode, oid, record[tab + 1 ..] });
    defer gpa.free(info);
    try runOnPaths(gpa, io, root_abs, &.{ "-c", "core.longpaths=true", "update-index", "--add", "--cacheinfo" }, &.{info});
    return true;
}

fn runOnPaths(gpa: Allocator, io: std.Io, root_abs: []const u8, command: []const []const u8, paths: []const []const u8) !void {
    const git = try exe_path.git(gpa, root_abs);
    defer gpa.free(git);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, git);
    try argv.appendSlice(gpa, command);
    try argv.appendSlice(gpa, paths);
    var attempt: usize = 0;
    while (attempt < index_add_attempts) : (attempt += 1) {
        if (attempt != 0) io.sleep(.fromMilliseconds(index_retry_ms), .awake) catch {};
        const result = bounded_run.run(gpa, io, .{
            .argv = argv.items,
            .cwd = .{ .path = root_abs },
            .stdout_limit = .limited(max_git_output),
        }) catch continue;
        gpa.free(result.stdout);
        gpa.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code == 0) return,
            else => {},
        }
    }
    return error.WrittenButNotIndexed;
}

const index_add_attempts = 3;
const index_retry_ms = 100;

fn expectSameRepo(gpa: Allocator, io: std.Io, root: []const u8, abs: []const u8) !void {
    if (try gitDiscoveryOverridden(gpa)) return expectSameRepoByGit(gpa, io, root, abs);
    var dir = std.fs.path.dirname(abs) orelse return error.FileOutsideRepo;
    while (dir.len > root.len) {
        if (try ownsRepository(gpa, io, dir)) return error.FileOutsideRepo;
        dir = std.fs.path.dirname(dir) orelse return error.FileOutsideRepo;
    }
    if (!std.ascii.eqlIgnoreCase(dir, root)) return error.FileOutsideRepo;
}

const discovery_variables = [_][:0]const u16{
    std.unicode.utf8ToUtf16LeStringLiteral("GIT_DIR"),
    std.unicode.utf8ToUtf16LeStringLiteral("GIT_WORK_TREE"),
    std.unicode.utf8ToUtf16LeStringLiteral("GIT_CEILING_DIRECTORIES"),
    std.unicode.utf8ToUtf16LeStringLiteral("GIT_DISCOVERY_ACROSS_FILESYSTEM"),
};

fn gitDiscoveryOverridden(gpa: Allocator) !bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    for (discovery_variables) |name| {
        if (try sandbox.environmentValue(arena_state.allocator(), name) != null) return true;
    }
    return false;
}

fn ownsRepository(gpa: Allocator, io: std.Io, dir: []const u8) !bool {
    if (try entryExists(gpa, io, dir, ".git")) return true;
    if (!try entryExists(gpa, io, dir, "HEAD")) return false;
    return try entryExists(gpa, io, dir, "objects") and try entryExists(gpa, io, dir, "refs");
}

fn entryExists(gpa: Allocator, io: std.Io, dir: []const u8, name: []const u8) !bool {
    const path = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ dir, name });
    defer gpa.free(path);
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return error.FileOutsideRepo,
    };
    return true;
}

fn expectSameRepoByGit(gpa: Allocator, io: std.Io, root: []const u8, abs: []const u8) !void {
    const dir = std.fs.path.dirname(abs) orelse return error.FileOutsideRepo;
    const own = gitToplevel(gpa, io, dir) catch |err| switch (err) {
        error.NotInRepo => return error.FileOutsideRepo,
        else => return err,
    };
    defer gpa.free(own);
    if (!std.ascii.eqlIgnoreCase(own, root)) return error.FileOutsideRepo;
}

pub fn nestedOwner(arena: Allocator, io: std.Io, root: []const u8, abs: []const u8, start_at_self: bool) !?[]const u8 {
    if (abs.len <= root.len or !std.ascii.eqlIgnoreCase(abs[0..root.len], root) or abs[root.len] != '\\') return null;
    var dir = if (start_at_self) abs else std.fs.path.dirname(abs) orelse return null;
    var found: ?[]const u8 = null;
    while (dir.len > root.len) {
        if (shadow.isReparsePoint(dir) catch false) return null;
        if (found == null and try ownsRepository(arena, io, dir)) found = dir;
        dir = std.fs.path.dirname(dir) orelse return null;
    }
    const candidate = found orelse return null;
    const final = finalOf(arena, candidate) catch return null;
    const owner = gitToplevel(arena, io, final) catch return null;
    if (!std.ascii.eqlIgnoreCase(owner, final)) return null;
    return final;
}

pub fn refuseInternal(rel: []const u8) error{InternalPath}!void {
    var segments = std.mem.tokenizeAny(u8, rel, "/\\");
    const first = segments.next() orelse return;
    if (std.ascii.eqlIgnoreCase(first, ".git") or std.ascii.eqlIgnoreCase(first, shadow.workspace_dir)) return error.InternalPath;
}

pub fn relativeTo(gpa: Allocator, root: []const u8, path_abs: []const u8) ![]u8 {
    const normalized = try gpa.dupe(u8, path_abs);
    defer gpa.free(normalized);
    std.mem.replaceScalar(u8, normalized, '/', '\\');
    if (std.ascii.eqlIgnoreCase(normalized, root)) return gpa.dupe(u8, "");
    return relativeUnder(gpa, root, normalized);
}

pub fn relativeUnder(gpa: Allocator, root: []const u8, file_abs: []const u8) ![]u8 {
    const normalized = try gpa.dupe(u8, file_abs);
    defer gpa.free(normalized);
    std.mem.replaceScalar(u8, normalized, '/', '\\');
    if (normalized.len <= root.len or !std.ascii.startsWithIgnoreCase(normalized, root) or normalized[root.len] != '\\') {
        return error.FileOutsideRepo;
    }
    return gpa.dupe(u8, normalized[root.len + 1 ..]);
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

pub fn toplevelOf(gpa: Allocator, io: std.Io, file_abs: []const u8) ![]u8 {
    return gitToplevel(gpa, io, existingAncestor(io, file_abs) orelse return error.InvalidPath);
}

pub fn gitToplevel(gpa: Allocator, io: std.Io, dir_abs: []const u8) ![]u8 {
    if (try rememberedToplevel(gpa, io, dir_abs)) |top| return top;
    const top = (try discoverToplevel(gpa, io, dir_abs)) orelse try askToplevel(gpa, io, dir_abs);
    rememberToplevel(gpa, io, dir_abs, top);
    return top;
}

pub var toplevels_discovered: std.atomic.Value(usize) = .init(0);

const ownership = struct {
    extern "advapi32" fn GetNamedSecurityInfoW(name: [*:0]const u16, object_type: c_int, info: u32, owner: ?*?*anyopaque, group: ?*?*anyopaque, dacl: ?*?*anyopaque, sacl: ?*?*anyopaque, descriptor: *?*anyopaque) callconv(.winapi) u32;
    extern "advapi32" fn EqualSid(a: *anyopaque, b: *anyopaque) callconv(.winapi) c_int;
    extern "advapi32" fn OpenProcessToken(process: *anyopaque, access: u32, token: *?*anyopaque) callconv(.winapi) c_int;
    extern "advapi32" fn GetTokenInformation(token: *anyopaque, class: c_int, info: ?*anyopaque, len: u32, needed: *u32) callconv(.winapi) c_int;
    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) *anyopaque;
    extern "kernel32" fn CloseHandle(handle: *anyopaque) callconv(.winapi) c_int;
    extern "kernel32" fn LocalFree(memory: ?*anyopaque) callconv(.winapi) ?*anyopaque;
    extern "advapi32" fn IsWellKnownSid(sid: *anyopaque, kind: c_int) callconv(.winapi) c_int;
    extern "advapi32" fn CheckTokenMembership(token: ?*anyopaque, sid: *anyopaque, is_member: *c_int) callconv(.winapi) c_int;

    const builtin_administrators = 26;

    const se_file_object = 1;
    const owner_security_information = 1;
    const token_query = 0x0008;
    const token_user = 1;

    fn ours(gpa: Allocator, path: []const u8) bool {
        const wide = std.unicode.utf8ToUtf16LeAllocZ(gpa, path) catch return false;
        defer gpa.free(wide);
        var owner: ?*anyopaque = null;
        var descriptor: ?*anyopaque = null;
        if (GetNamedSecurityInfoW(wide, se_file_object, owner_security_information, &owner, null, null, null, &descriptor) != 0) return false;
        defer _ = LocalFree(descriptor);
        var token: ?*anyopaque = null;
        if (OpenProcessToken(GetCurrentProcess(), token_query, &token) == 0) return false;
        defer _ = CloseHandle(token.?);
        var buffer: [256]u8 align(@alignOf(usize)) = undefined;
        var needed: u32 = 0;
        if (GetTokenInformation(token.?, token_user, &buffer, buffer.len, &needed) == 0) return false;
        const user: *anyopaque = @as(*const ?*anyopaque, @ptrCast(&buffer)).* orelse return false;
        const owned_by = owner orelse return false;
        if (EqualSid(owned_by, user) != 0) return true;
        if (IsWellKnownSid(owned_by, builtin_administrators) == 0) return false;
        var is_member: c_int = 0;
        return CheckTokenMembership(null, owned_by, &is_member) != 0 and is_member != 0;
    }
};

pub fn ownedByCurrentUser(gpa: Allocator, path: []const u8) bool {
    return builtin.os.tag == .windows and ownership.ours(gpa, path);
}

fn redirectsWorkTree(gpa: Allocator, io: std.Io, git_dir: []const u8) bool {
    const path = std.fmt.allocPrint(gpa, "{s}\\config", .{git_dir}) catch return true;
    defer gpa.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return true,
    };
    defer gpa.free(text);
    if (std.ascii.findIgnoreCase(text, "worktree") != null) return true;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        if (std.ascii.findIgnoreCase(line, "bare") != null and std.ascii.findIgnoreCase(line, "false") == null) return true;
    }
    return false;
}

fn discoverToplevel(gpa: Allocator, io: std.Io, dir_abs: []const u8) Allocator.Error!?[]u8 {
    if (builtin.os.tag != .windows or !std.fs.path.isAbsolute(dir_abs)) return null;
    if (gitDiscoveryOverridden(gpa) catch return null) return null;
    const final = finalOf(gpa, dir_abs) catch return null;
    defer gpa.free(final);
    if (!std.mem.eql(u8, final, dir_abs)) return null;
    var dir: []const u8 = dir_abs;
    while (true) {
        if (entryExists(gpa, io, dir, ".git") catch return null) break;
        if (entryExists(gpa, io, dir, "HEAD") catch return null) return null;
        const parent = std.fs.path.dirname(dir) orelse return null;
        if (parent.len >= dir.len) return null;
        dir = parent;
    }
    const git_dir = try std.fmt.allocPrint(gpa, "{s}\\.git", .{dir});
    defer gpa.free(git_dir);
    if (!(entryExists(gpa, io, git_dir, "HEAD") catch return null)) return null;
    if (!(entryExists(gpa, io, git_dir, "objects") catch return null)) return null;
    if (entryExists(gpa, io, git_dir, "commondir") catch return null) return null;
    if (redirectsWorkTree(gpa, io, git_dir)) return null;
    if (!ownership.ours(gpa, dir) or !ownership.ours(gpa, git_dir)) return null;
    _ = toplevels_discovered.fetchAdd(1, .monotonic);
    return try gpa.dupe(u8, dir);
}

const Remembered = struct { dir: []u8, top: []u8 };
const remembered_slots = 64;
var remembered: [remembered_slots]?Remembered = @splat(null);
var remembered_next: usize = 0;
var remembered_lock: std.Io.Mutex = .init;
const remembered_store = std.heap.page_allocator;

fn under(top: []const u8, dir: []const u8) bool {
    if (dir.len < top.len or !std.ascii.eqlIgnoreCase(dir[0..top.len], top)) return false;
    return dir.len == top.len or dir[top.len] == '\\';
}

fn stillTop(gpa: Allocator, io: std.Io, top: []const u8, dir_abs: []const u8) bool {
    if (gitDiscoveryOverridden(gpa) catch return false) return false;
    std.Io.Dir.cwd().access(io, dir_abs, .{}) catch return false;
    var dir = dir_abs;
    while (dir.len > top.len) {
        if (ownsRepository(gpa, io, dir) catch return false) return false;
        dir = std.fs.path.dirname(dir) orelse return false;
    }
    if (dir.len != top.len) return false;
    return entryExists(gpa, io, top, ".git") catch false;
}

fn rememberedToplevel(gpa: Allocator, io: std.Io, dir_abs: []const u8) Allocator.Error!?[]u8 {
    remembered_lock.lockUncancelable(io);
    defer remembered_lock.unlock(io);
    for (&remembered) |*slot| {
        const entry = slot.* orelse continue;
        if (!std.mem.eql(u8, entry.dir, dir_abs)) continue;
        if (stillTop(gpa, io, entry.top, dir_abs)) return try gpa.dupe(u8, entry.top);
        remembered_store.free(entry.dir);
        remembered_store.free(entry.top);
        slot.* = null;
        return null;
    }
    return null;
}

fn rememberToplevel(gpa: Allocator, io: std.Io, dir_abs: []const u8, top: []const u8) void {
    if (!std.fs.path.isAbsolute(dir_abs) or !under(top, dir_abs)) return;
    if (!stillTop(gpa, io, top, dir_abs)) return;
    const dir_copy = remembered_store.dupe(u8, dir_abs) catch return;
    const top_copy = remembered_store.dupe(u8, top) catch {
        remembered_store.free(dir_copy);
        return;
    };
    remembered_lock.lockUncancelable(io);
    defer remembered_lock.unlock(io);
    const slot = &remembered[remembered_next];
    remembered_next = (remembered_next + 1) % remembered_slots;
    if (slot.*) |old| {
        remembered_store.free(old.dir);
        remembered_store.free(old.top);
    }
    slot.* = .{ .dir = dir_copy, .top = top_copy };
}

fn askToplevel(gpa: Allocator, io: std.Io, dir_abs: []const u8) ![]u8 {
    const git = try exe_path.git(gpa, dir_abs);
    defer gpa.free(git);
    const result = bounded_run.run(gpa, io, .{
        .argv = &.{ git, "rev-parse", "--show-toplevel" },
        .cwd = .{ .path = dir_abs },
        .stdout_limit = .limited(max_git_output),
    }) catch return error.GitFailed;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.NotInRepo,
        else => return error.GitFailed,
    }
    const trimmed = std.mem.trim(u8, result.stdout, " \r\n");
    const owned = try gpa.dupe(u8, trimmed);
    std.mem.replaceScalar(u8, owned, '/', '\\');
    return owned;
}
