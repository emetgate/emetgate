const std = @import("std");

const testing = std.testing;

pub const settings = "[user]\n\temail = t@t\n\tname = t\n[maintenance]\n\tauto = false\n[gc]\n\tauto = 0\n";

const Template = struct {
    head: []const u8,
    config: []const u8,
};

var template: ?Template = null;

var git_exe: ?[]const u8 = null;

pub fn git() error{ GitNotFound, OutOfMemory }![]const u8 {
    if (git_exe) |found| return found;
    const found = try @import("emetgate").exe_path.git(std.heap.page_allocator, null);
    git_exe = found;
    return found;
}

const layout = [_][]const u8{ "objects/info", "objects/pack", "refs/heads", "refs/tags" };

pub fn initRepo(root_abs: []const u8) !void {
    const t = template orelse try makeTemplate();
    var root = try std.Io.Dir.cwd().openDir(testing.io, root_abs, .{});
    defer root.close(testing.io);
    for (layout) |dir| {
        const sub = try std.fmt.allocPrint(testing.allocator, ".git/{s}", .{dir});
        defer testing.allocator.free(sub);
        try root.createDirPath(testing.io, sub);
    }
    try root.writeFile(testing.io, .{ .sub_path = ".git/HEAD", .data = t.head });
    const config = try std.mem.concat(testing.allocator, u8, &.{ t.config, settings });
    defer testing.allocator.free(config);
    try root.writeFile(testing.io, .{ .sub_path = ".git/config", .data = config });
}

fn makeTemplate() !Template {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir_abs);
    const result = try @import("emetgate").bounded_run.run(testing.allocator, testing.io, .{ .argv = &.{ try git(), "init", "-q", "--template=" }, .cwd = .{ .path = dir_abs } });
    testing.allocator.free(result.stdout);
    testing.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitSetupFailed,
        else => return error.GitSetupFailed,
    }
    const keep = std.heap.page_allocator;
    const made: Template = .{
        .head = try tmp.dir.readFileAlloc(testing.io, ".git/HEAD", keep, .limited(4096)),
        .config = try tmp.dir.readFileAlloc(testing.io, ".git/config", keep, .limited(64 * 1024)),
    };
    template = made;
    return made;
}

fn runGit(root_abs: []const u8, args: []const []const u8) !void {
    var argv: [8][]const u8 = undefined;
    argv[0] = try git();
    @memcpy(argv[1..][0..args.len], args);
    const result = try @import("emetgate").bounded_run.run(testing.allocator, testing.io, .{ .argv = argv[0 .. args.len + 1], .cwd = .{ .path = root_abs } });
    testing.allocator.free(result.stdout);
    testing.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitSetupFailed,
        else => return error.GitSetupFailed,
    }
}

pub var native_commits: usize = 0;

const Stamp = struct { seconds: u32, nanos: u32 };

const Tracked = struct {
    rel: []const u8,
    bytes: []const u8,
    oid: [20]u8 = undefined,
    created: Stamp = undefined,
    written: Stamp = undefined,
};

const Ignore = struct {
    text: []const u8,
    rooted: bool,
    only_dir: bool,
};

const file_times = struct {
    const FILETIME = extern struct { low: u32, high: u32 };
    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, disposition: u32, flags: u32, template: ?*anyopaque) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetFileTime(handle: *anyopaque, creation: ?*FILETIME, access: ?*FILETIME, write: ?*FILETIME) callconv(.winapi) c_int;
    extern "kernel32" fn CloseHandle(handle: *anyopaque) callconv(.winapi) c_int;

    fn stamp(time: FILETIME) ?Stamp {
        const ticks = (@as(u64, time.high) << 32) | time.low;
        const epoch = 116444736000000000;
        if (ticks < epoch) return null;
        const since = ticks - epoch;
        return .{ .seconds = @truncate(since / 10_000_000), .nanos = @intCast((since % 10_000_000) * 100) };
    }

    fn read(arena: std.mem.Allocator, path: []const u8, created: *Stamp, written: *Stamp) !bool {
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(arena, path);
        const invalid: usize = std.math.maxInt(usize);
        const handle = CreateFileW(wide, 0x80, 7, null, 3, 0x02000000, null) orelse return false;
        if (@intFromPtr(handle) == invalid) return false;
        defer _ = CloseHandle(handle);
        var creation: FILETIME = undefined;
        var write: FILETIME = undefined;
        if (GetFileTime(handle, &creation, null, &write) == 0) return false;
        created.* = stamp(creation) orelse return false;
        written.* = stamp(write) orelse return false;
        return true;
    }
};

fn ignoreRules(arena: std.mem.Allocator, root: std.Io.Dir) !?[]const Ignore {
    const bytes = root.readFileAlloc(testing.io, ".gitignore", arena, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return null,
    };
    var out: std.ArrayList(Ignore) = .empty;
    var lines = std.mem.tokenizeAny(u8, bytes, "\r\n");
    while (lines.next()) |raw| {
        var text = std.mem.trim(u8, raw, " \t");
        if (text.len == 0 or text[0] == '#') continue;
        if (std.mem.indexOfAny(u8, text, "![]?\\*") != null) return null;
        var rooted = false;
        var only_dir = false;
        if (text[0] == '/') {
            rooted = true;
            text = text[1..];
        }
        if (text.len != 0 and text[text.len - 1] == '/') {
            only_dir = true;
            text = text[0 .. text.len - 1];
        }
        if (text.len == 0) return null;
        if (std.mem.indexOfScalar(u8, text, '/') != null) rooted = true;
        try out.append(arena, .{ .text = text, .rooted = rooted, .only_dir = only_dir });
    }
    return out.items;
}

fn ignoredBy(rules: []const Ignore, rel: []const u8, is_dir: bool) bool {
    var end: usize = 0;
    while (end < rel.len) {
        const next = std.mem.indexOfScalarPos(u8, rel, end, '/') orelse rel.len;
        const prefix_is_dir = next != rel.len or is_dir;
        for (rules) |rule| {
            if (rule.only_dir and !prefix_is_dir) continue;
            const candidate = if (rule.rooted) rel[0..next] else rel[end..next];
            if (std.mem.eql(u8, rule.text, candidate)) return true;
        }
        end = next + 1;
    }
    return false;
}

fn gather(arena: std.mem.Allocator, dir: std.Io.Dir, prefix: []const u8, rules: []const Ignore, out: *std.ArrayList(Tracked)) !bool {
    var it = dir.iterate();
    while (try it.next(testing.io)) |entry| {
        const rel = if (prefix.len == 0) try arena.dupe(u8, entry.name) else try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, entry.name });
        switch (entry.kind) {
            .directory => {
                if (std.ascii.eqlIgnoreCase(entry.name, ".git")) {
                    if (prefix.len == 0) continue;
                    return false;
                }
                if (ignoredBy(rules, rel, true)) continue;
                var sub = try dir.openDir(testing.io, entry.name, .{ .iterate = true });
                defer sub.close(testing.io);
                if (!try gather(arena, sub, rel, rules, out)) return false;
            },
            .file => {
                if (std.ascii.eqlIgnoreCase(entry.name, ".gitattributes") or std.ascii.eqlIgnoreCase(entry.name, ".gitmodules")) return false;
                if (std.ascii.eqlIgnoreCase(entry.name, ".git")) return false;
                if (prefix.len != 0 and std.mem.eql(u8, entry.name, ".gitignore")) return false;
                if (ignoredBy(rules, rel, false)) continue;
                if (rel.len >= 0xfff) return false;
                const bytes = dir.readFileAlloc(testing.io, entry.name, arena, .limited(16 * 1024 * 1024)) catch return false;
                if (std.mem.indexOfScalar(u8, bytes, '\r') != null) return false;
                try out.append(arena, .{ .rel = rel, .bytes = bytes });
            },
            else => return false,
        }
    }
    return true;
}

fn byRel(_: void, a: Tracked, b: Tracked) bool {
    return std.mem.lessThan(u8, a.rel, b.rel);
}

fn commitNatively(root_abs: []const u8) !bool {
    if (@import("builtin").os.tag != .windows) return false;
    const git_objects = @import("emetgate").git_objects;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var root = try std.Io.Dir.cwd().openDir(testing.io, root_abs, .{ .iterate = true });
    defer root.close(testing.io);
    const rules = (try ignoreRules(arena, root)) orelse return false;
    var files: std.ArrayList(Tracked) = .empty;
    if (!try gather(arena, root, "", rules, &files)) return false;
    if (files.items.len == 0) return false;
    std.mem.sort(Tracked, files.items, {}, byRel);

    const git_dir = try std.fmt.allocPrint(arena, "{s}\\.git", .{root_abs});
    const head = root.readFileAlloc(testing.io, ".git/HEAD", arena, .limited(4096)) catch return false;
    const head_line = std.mem.trimEnd(u8, head, "\r\n");
    if (!std.mem.startsWith(u8, head_line, "ref: refs/heads/")) return false;
    const branch = head_line["ref: ".len..];
    var store = (git_objects.Store.open(arena, testing.io, git_dir, null) catch return false) orelse return false;

    var lines: std.ArrayList(u8) = .empty;
    for (files.items) |*file| {
        file.oid = store.putObject(.blob, file.bytes) catch return false;
        const abs = try std.fmt.allocPrint(arena, "{s}\\{s}", .{ root_abs, file.rel });
        std.mem.replaceScalar(u8, abs[root_abs.len..], '/', '\\');
        if (!try file_times.read(arena, abs, &file.created, &file.written)) return false;
        try lines.print(arena, "100644 blob {s}\t{s}\x00", .{ std.fmt.bytesToHex(file.oid, .lower), file.rel });
    }
    const tree = (store.writeTree(lines.items) catch return false) orelse return false;
    const commit_text = try std.fmt.allocPrint(arena, "tree {s}\nauthor t <t@t> 1700000000 +0000\ncommitter t <t@t> 1700000000 +0000\n\ninit\n", .{tree});
    const commit = store.putObject(.commit, commit_text) catch return false;

    var index: std.ArrayList(u8) = .empty;
    try index.appendSlice(arena, "DIRC");
    var word: [4]u8 = undefined;
    const put = struct {
        fn int(list: *std.ArrayList(u8), a: std.mem.Allocator, buffer: *[4]u8, value: u32) !void {
            std.mem.writeInt(u32, buffer, value, .big);
            try list.appendSlice(a, buffer);
        }
    };
    try put.int(&index, arena, &word, 2);
    try put.int(&index, arena, &word, @intCast(files.items.len));
    for (files.items) |file| {
        const start = index.items.len;
        for ([_]u32{ file.created.seconds, file.created.nanos, file.written.seconds, file.written.nanos, 0, 0, 0o100644, 0, 0, @truncate(file.bytes.len) }) |value| {
            try put.int(&index, arena, &word, value);
        }
        try index.appendSlice(arena, &file.oid);
        var flags: [2]u8 = undefined;
        std.mem.writeInt(u16, &flags, @intCast(file.rel.len), .big);
        try index.appendSlice(arena, &flags);
        try index.appendSlice(arena, file.rel);
        const padded = (index.items.len - start + 8) & ~@as(usize, 7);
        try index.appendNTimes(arena, 0, start + padded - index.items.len);
    }
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(index.items, &digest, .{});
    try index.appendSlice(arena, &digest);

    const ref_sub = try std.fmt.allocPrint(arena, ".git/{s}", .{branch});
    if (std.fs.path.dirname(ref_sub)) |parent| root.createDirPath(testing.io, parent) catch return false;
    const ref_text = try std.fmt.allocPrint(arena, "{s}\n", .{std.fmt.bytesToHex(commit, .lower)});
    root.writeFile(testing.io, .{ .sub_path = ".git/index", .data = index.items }) catch return false;
    root.writeFile(testing.io, .{ .sub_path = ref_sub, .data = ref_text }) catch {
        root.deleteFile(testing.io, ".git/index") catch {};
        return false;
    };
    return true;
}

pub fn commitInit(root_abs: []const u8, allow_empty: bool) !void {
    if (try commitNatively(root_abs)) {
        native_commits += 1;
        return;
    }
    try runGit(root_abs, &.{ "add", "." });
    if (allow_empty) try runGit(root_abs, &.{ "commit", "-q", "--allow-empty", "-m", "init" }) else try runGit(root_abs, &.{ "commit", "-q", "-m", "init" });
}
