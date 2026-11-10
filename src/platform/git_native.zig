const std = @import("std");
const builtin = @import("builtin");
const git_objects = @import("git_objects.zig");
const git_index = @import("git_index.zig");
const sandbox = @import("sandbox.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

pub var answered: std.atomic.Value(usize) = .init(0);

const max_ref_bytes = 64 * 1024 * 1024;
const max_symbolic_depth = 5;

const index_variables = [_][:0]const u16{
    std.unicode.utf8ToUtf16LeStringLiteral("GIT_DIR"),
    std.unicode.utf8ToUtf16LeStringLiteral("GIT_INDEX_FILE"),
    std.unicode.utf8ToUtf16LeStringLiteral("GIT_WORK_TREE"),
    std.unicode.utf8ToUtf16LeStringLiteral("GIT_COMMON_DIR"),
    std.unicode.utf8ToUtf16LeStringLiteral("GIT_NAMESPACE"),
};

fn overridden(arena: Allocator) bool {
    for (index_variables) |name| {
        if ((sandbox.environmentValue(arena, name) catch return true) != null) return true;
    }
    return false;
}

fn isHex(text: []const u8) bool {
    if (text.len != 40) return false;
    for (text) |c| {
        if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return false;
    }
    return true;
}

fn readSmall(arena: Allocator, io: std.Io, path: []const u8, limit: usize) error{ OutOfMemory, Unreadable }!?[]u8 {
    return Dir.cwd().readFileAlloc(io, path, arena, .limited(limit)) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound => null,
        else => error.Unreadable,
    };
}

const Lookup = union(enum) {
    oid: []const u8,
    absent,
};

pub const Head = struct {
    commit: []const u8,
    branch: ?[]const u8,
};

pub const Repo = struct {
    arena: Allocator,
    io: std.Io,
    git_dir: []const u8,
    store: git_objects.Store,

    pub fn open(arena: Allocator, io: std.Io, root: []const u8) !?Repo {
        if (builtin.os.tag != .windows) return null;
        if (!std.fs.path.isAbsolute(root) or overridden(arena)) return null;
        const git_dir = try std.fmt.allocPrint(arena, "{s}\\.git", .{root});
        const head_path = try std.fmt.allocPrint(arena, "{s}\\HEAD", .{git_dir});
        Dir.cwd().access(io, head_path, .{}) catch return null;
        const common = try std.fmt.allocPrint(arena, "{s}\\commondir", .{git_dir});
        if (Dir.cwd().access(io, common, .{})) |_| return null else |_| {}
        const store = (git_objects.Store.open(arena, io, git_dir, null) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        }) orelse return null;
        return .{ .arena = arena, .io = io, .git_dir = git_dir, .store = store };
    }

    fn plainRefName(name: []const u8) bool {
        if (!std.mem.startsWith(u8, name, "refs/") or name[name.len - 1] == '/') return false;
        if (std.mem.indexOf(u8, name, "..") != null or std.mem.indexOf(u8, name, "//") != null) return false;
        for (name) |c| {
            if (c <= ' ' or c == 0x7f or std.mem.indexOfScalar(u8, "\\:?*[~^@{", c) != null) return false;
        }
        return true;
    }

    fn ref(self: *Repo, name: []const u8, depth: usize) error{OutOfMemory}!?Lookup {
        if (depth > max_symbolic_depth or !plainRefName(name)) return null;
        const loose = try std.fmt.allocPrint(self.arena, "{s}\\{s}", .{ self.git_dir, name });
        std.mem.replaceScalar(u8, loose[self.git_dir.len..], '/', '\\');
        const text = readSmall(self.arena, self.io, loose, 4096) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unreadable => return null,
        };
        if (text) |bytes| {
            const line = std.mem.trimEnd(u8, bytes, "\r\n");
            if (std.mem.startsWith(u8, line, "ref: ")) return self.ref(line["ref: ".len..], depth + 1);
            return if (isHex(line)) .{ .oid = line } else null;
        }
        const packed_path = try std.fmt.allocPrint(self.arena, "{s}\\packed-refs", .{self.git_dir});
        const packed_refs = readSmall(self.arena, self.io, packed_path, max_ref_bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unreadable => return null,
        };
        const listed = packed_refs orelse return .absent;
        var lines = std.mem.tokenizeAny(u8, listed, "\r\n");
        while (lines.next()) |line| {
            if (line[0] == '#' or line[0] == '^') continue;
            if (line.len < 42 or line[40] != ' ') return null;
            if (!std.mem.eql(u8, line[41..], name)) continue;
            return if (isHex(line[0..40])) .{ .oid = line[0..40] } else null;
        }
        return .absent;
    }

    pub fn head(self: *Repo) !?Head {
        const path = try std.fmt.allocPrint(self.arena, "{s}\\HEAD", .{self.git_dir});
        const text = (readSmall(self.arena, self.io, path, 4096) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unreadable => return null,
        }) orelse return null;
        const line = std.mem.trimEnd(u8, text, "\r\n");
        if (isHex(line)) return .{ .commit = line, .branch = null };
        if (!std.mem.startsWith(u8, line, "ref: ")) return null;
        const branch = line["ref: ".len..];
        const found = (try self.ref(branch, 0)) orelse return null;
        return switch (found) {
            .oid => |oid| .{ .commit = oid, .branch = branch },
            .absent => null,
        };
    }

    pub fn resolve(self: *Repo, rev: []const u8) !?[]const u8 {
        if (isHex(rev)) return rev;
        if (std.mem.eql(u8, rev, "HEAD")) return if (try self.head()) |found| found.commit else null;
        if (std.mem.startsWith(u8, rev, "refs/")) {
            const found = (try self.ref(rev, 0)) orelse return null;
            return switch (found) {
                .oid => |oid| oid,
                .absent => null,
            };
        }
        return null;
    }

    fn commit(self: *Repo, rev: []const u8) !?[]const u8 {
        const hex = (try self.resolve(rev)) orelse return null;
        const object = (try self.store.read(hex)) orelse return null;
        return if (object.kind == .commit) hex else null;
    }
};

pub const HeadState = union(enum) {
    oid: []const u8,
    unborn,
};

pub fn headOid(arena: Allocator, io: std.Io, root: []const u8) !?HeadState {
    var repo = (try Repo.open(arena, io, root)) orelse return null;
    const path = try std.fmt.allocPrint(arena, "{s}\\HEAD", .{repo.git_dir});
    const text = (readSmall(arena, io, path, 4096) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unreadable => return null,
    }) orelse return null;
    const line = std.mem.trimEnd(u8, text, "\r\n");
    const state: HeadState = if (isHex(line)) .{ .oid = line } else blk: {
        if (!std.mem.startsWith(u8, line, "ref: ")) return null;
        const found = (try repo.ref(line["ref: ".len..], 0)) orelse return null;
        break :blk switch (found) {
            .oid => |oid| .{ .oid = oid },
            .absent => .unborn,
        };
    };
    switch (state) {
        .oid => |oid| if ((try repo.store.read(oid)) == null) return null,
        .unborn => {},
    }
    _ = answered.fetchAdd(1, .monotonic);
    return state;
}

pub fn parents(arena: Allocator, io: std.Io, root: []const u8, rev: []const u8) !?[]const []const u8 {
    var repo = (try Repo.open(arena, io, root)) orelse return null;
    const hex = (try repo.commit(rev)) orelse return null;
    const found = (try repo.store.parents(hex)) orelse return null;
    _ = answered.fetchAdd(1, .monotonic);
    return found;
}

pub const Blob = union(enum) {
    found: []u8,
    absent,
};

const OneEntry = struct {
    mode: u32 = 0,
    oid: ?git_objects.Oid = null,

    pub fn add(self: *OneEntry, _: []const u8, mode: u32, oid: git_objects.Oid) !void {
        self.mode = mode;
        self.oid = oid;
    }
};

fn blobIn(repo: *Repo, rev: []const u8, path: []const u8) !?Blob {
    const hex = (try repo.commit(rev)) orelse return null;
    var entry: OneEntry = .{};
    if (!try repo.store.entriesAt(hex, &.{path}, &entry)) return null;
    const oid = entry.oid orelse return .absent;
    if (entry.mode == 0o040000 or entry.mode == 0o160000) return .absent;
    const id = std.fmt.bytesToHex(oid, .lower);
    const object = (try repo.store.read(&id)) orelse return null;
    if (object.kind != .blob) return null;
    return .{ .found = try repo.arena.dupe(u8, object.data) };
}

pub fn blobAt(arena: Allocator, io: std.Io, root: []const u8, spec: []const u8) !?Blob {
    const colon = std.mem.indexOfScalar(u8, spec, ':') orelse return null;
    if (colon == 0 or colon + 1 == spec.len) return null;
    var repo = (try Repo.open(arena, io, root)) orelse return null;
    const found = (try blobIn(&repo, spec[0..colon], spec[colon + 1 ..])) orelse return null;
    _ = answered.fetchAdd(1, .monotonic);
    return found;
}

const Listed = struct {
    path: []const u8,
    what: []const u8,
};

fn parseListing(arena: Allocator, listing: []const u8) !?[]Listed {
    var out: std.ArrayList(Listed) = .empty;
    var entries = std.mem.tokenizeScalar(u8, listing, 0);
    while (entries.next()) |entry| {
        const tab = std.mem.indexOfScalar(u8, entry, '\t') orelse return null;
        try out.append(arena, .{ .path = entry[tab + 1 ..], .what = entry[0..tab] });
    }
    return out.items;
}

fn holdsUnder(entries: []const Listed, path: []const u8) bool {
    for (entries) |entry| {
        if (entry.path.len > path.len and entry.path[path.len] == '/' and std.mem.startsWith(u8, entry.path, path)) return true;
    }
    return false;
}

pub fn changedPaths(arena: Allocator, io: std.Io, root: []const u8, rev: []const u8) !?[]const []const u8 {
    var repo = (try Repo.open(arena, io, root)) orelse return null;
    const hex = (try repo.commit(rev)) orelse return null;
    const before = (try repo.store.parents(hex)) orelse return null;
    var out: std.ArrayList([]const u8) = .empty;
    if (before.len > 1) {
        _ = answered.fetchAdd(1, .monotonic);
        return out.items;
    }
    const new = (try parseListing(arena, (try repo.store.listing(hex)) orelse return null)) orelse return null;
    const old: []const Listed = if (before.len == 1)
        (try parseListing(arena, (try repo.store.listing(before[0])) orelse return null)) orelse return null
    else
        &.{};
    var i: usize = 0;
    var j: usize = 0;
    while (i < old.len or j < new.len) {
        const order: std.math.Order = if (i == old.len) .gt else if (j == new.len) .lt else std.mem.order(u8, old[i].path, new[j].path);
        switch (order) {
            .lt => {
                if (holdsUnder(new, old[i].path)) return null;
                try out.append(arena, old[i].path);
                i += 1;
            },
            .gt => {
                if (holdsUnder(old, new[j].path)) return null;
                try out.append(arena, new[j].path);
                j += 1;
            },
            .eq => {
                if (!std.mem.eql(u8, old[i].what, new[j].what)) try out.append(arena, new[j].path);
                i += 1;
                j += 1;
            },
        }
    }
    _ = answered.fetchAdd(1, .monotonic);
    return out.items;
}

pub fn note(arena: Allocator, io: std.Io, root: []const u8, notes_name: []const u8, rev: []const u8) !?Blob {
    var repo = (try Repo.open(arena, io, root)) orelse return null;
    const target = (try repo.resolve(rev)) orelse return null;
    const ref_name = try std.fmt.allocPrint(arena, "refs/notes/{s}", .{notes_name});
    const found = (try repo.ref(ref_name, 0)) orelse return null;
    const notes_commit = switch (found) {
        .oid => |oid| oid,
        .absent => {
            _ = answered.fetchAdd(1, .monotonic);
            return .absent;
        },
    };
    const shapes = [_][]const u8{
        target,
        try std.fmt.allocPrint(arena, "{s}/{s}", .{ target[0..2], target[2..] }),
        try std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ target[0..2], target[2..4], target[4..] }),
    };
    for (shapes) |path| {
        const blob = (try blobIn(&repo, notes_commit, path)) orelse return null;
        switch (blob) {
            .found => {
                _ = answered.fetchAdd(1, .monotonic);
                return blob;
            },
            .absent => {},
        }
    }
    return null;
}

pub const Facts = struct {
    git_dir: []const u8,
    index: []const u8,
    attributes: []const u8,
    commit: []const u8,
    tree: []const u8,
    branch: []const u8,
};

pub fn facts(arena: Allocator, io: std.Io, root: []const u8) !?Facts {
    var repo = (try Repo.open(arena, io, root)) orelse return null;
    const head = (try repo.head()) orelse return null;
    const branch = head.branch orelse return null;
    const hex = (try repo.commit(head.commit)) orelse return null;
    const tree = (try repo.store.treeOf(hex)) orelse return null;
    const git_dir = try std.fmt.allocPrint(arena, "{s}/.git", .{root});
    std.mem.replaceScalar(u8, git_dir, '\\', '/');
    _ = answered.fetchAdd(1, .monotonic);
    return .{
        .git_dir = git_dir,
        .index = ".git/index",
        .attributes = ".git/info/attributes",
        .commit = hex,
        .tree = try arena.dupe(u8, &std.fmt.bytesToHex(tree, .lower)),
        .branch = branch,
    };
}

fn starMatch(pattern: []const u8, text: []const u8) bool {
    const star = std.mem.indexOfScalar(u8, pattern, '*') orelse return std.mem.eql(u8, pattern, text);
    if (!std.mem.startsWith(u8, text, pattern[0..star])) return false;
    var at: usize = star;
    while (at <= text.len) : (at += 1) {
        if (starMatch(pattern[star + 1 ..], text[at..])) return true;
    }
    return false;
}

const Spec = struct {
    text: []const u8,
    literal: bool,
    icase: bool,

    fn covers(self: Spec, name: []const u8, fold: bool) bool {
        if (self.text.len == 0) return true;
        if (!self.literal and std.mem.indexOfScalar(u8, self.text, '*') != null) return !fold and starMatch(self.text, name);
        if (name.len < self.text.len) return false;
        const head = name[0..self.text.len];
        const same = if (fold) std.ascii.eqlIgnoreCase(head, self.text) else std.mem.eql(u8, head, self.text);
        return same and (name.len == self.text.len or name[self.text.len] == '/');
    }
};

fn parseSpec(arena: Allocator, pathspec: []const u8) !?Spec {
    var text = pathspec;
    var literal = false;
    var icase = false;
    if (std.mem.startsWith(u8, text, ":(")) {
        const close = std.mem.indexOfScalar(u8, text, ')') orelse return null;
        var magic = std.mem.tokenizeScalar(u8, text[2..close], ',');
        while (magic.next()) |word| {
            if (std.mem.eql(u8, word, "literal")) literal = true else if (std.mem.eql(u8, word, "icase")) icase = true else return null;
        }
        text = text[close + 1 ..];
    } else if (text.len != 0 and text[0] == ':') return null;
    if (std.mem.indexOfAny(u8, text, "[]?\\") != null) return null;
    if (!literal and std.mem.indexOfScalar(u8, text, '*') != null and icase) return null;
    const copy = try arena.dupe(u8, std.mem.trimEnd(u8, text, "/"));
    if (std.mem.eql(u8, copy, ".")) return .{ .text = "", .literal = literal, .icase = icase };
    if (std.mem.startsWith(u8, copy, "./") or std.mem.startsWith(u8, copy, "../") or std.mem.indexOf(u8, copy, "/../") != null or std.mem.indexOf(u8, copy, "/./") != null or std.mem.indexOf(u8, copy, "//") != null) return null;
    if (copy.len != 0 and copy[0] == '/') return null;
    return .{ .text = copy, .literal = literal, .icase = icase };
}

pub fn trackedUnder(gpa: Allocator, io: std.Io, root: []const u8, pathspec: []const u8) !?[]u8 {
    if (builtin.os.tag != .windows) return null;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!std.fs.path.isAbsolute(root) or overridden(arena)) return null;
    const head = try std.fmt.allocPrint(arena, "{s}\\.git\\HEAD", .{root});
    Dir.cwd().access(io, head, .{}) catch return null;
    const spec = (try parseSpec(arena, pathspec)) orelse return null;
    const index_path = try std.fmt.allocPrint(arena, "{s}\\.git\\index", .{root});
    const all = (try git_index.readEntries(arena, io, index_path)) orelse return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var folded_only = false;
    for (all) |entry| {
        if (spec.covers(entry.name, spec.icase)) {
            try out.appendSlice(gpa, entry.name);
            try out.append(gpa, 0);
        } else if (!spec.icase and spec.covers(entry.name, true)) folded_only = true;
    }
    if (folded_only) {
        out.deinit(gpa);
        return null;
    }
    _ = answered.fetchAdd(1, .monotonic);
    return try out.toOwnedSlice(gpa);
}

test "git native: a pathspec is a prefix on a path boundary, a star pattern, or the whole tree" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const plain = (try parseSpec(arena, "src/util")).?;
    try std.testing.expect(plain.covers("src/util", false));
    try std.testing.expect(plain.covers("src/util/a.ts", false));
    try std.testing.expect(!plain.covers("src/utility.ts", false));
    try std.testing.expect(!plain.covers("SRC/util", false));
    try std.testing.expect(plain.covers("SRC/util", true));
    const star = (try parseSpec(arena, "*.cs")).?;
    try std.testing.expect(star.covers("a.cs", false));
    try std.testing.expect(star.covers("src/deep/b.cs", false));
    try std.testing.expect(!star.covers("src/b.csx", false));
    const literal = (try parseSpec(arena, ":(icase,literal).emetgate")).?;
    try std.testing.expect(literal.covers(".EmetGate/ledger.ndjson", true));
    try std.testing.expect((try parseSpec(arena, ".")).?.covers("anything/at/all", false));
    for ([_][]const u8{ ":(glob)**/a", ":!src", "a[bc]", "a?", "../x", "/abs", ":(icase)*.cs" }) |refused| {
        try std.testing.expect((try parseSpec(arena, refused)) == null);
    }
}
