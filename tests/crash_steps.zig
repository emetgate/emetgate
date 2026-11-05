const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");
const disk = emetgate.disk;
const shadow = emetgate.shadow;
const memory = emetgate.memory;
const change_watch = emetgate.change_watch;
const commit_record = emetgate.commit_record;

const testing = std.testing;
const windows = std.os.windows;
const Dir = std.Io.Dir;
const Blake3 = std.crypto.hash.Blake3;
const Digest = [Blake3.digest_length]u8;

const vanishing_files = [_][]const u8{
    shadow.workspace_dir ++ "/" ++ shadow.workspace_lock_name,
    shadow.workspace_dir ++ "/" ++ memory.lock_name,
};
const vanishing_dirs = [_][]const u8{change_watch.cookie_dir};

const appended_files = [_][]const u8{
    shadow.workspace_dir ++ "/" ++ memory.ledger_name,
    shadow.workspace_dir ++ "/" ++ emetgate.telemetry.events_file,
};
const git_dir = ".git";
const reflog_dir = "logs";

pub const StopAt = struct {
    target: usize,
    seen: usize = 0,

    pub fn step(self: *StopAt) disk.Step {
        return .{ .context = self, .reached = reached };
    }

    fn reached(context: *anyopaque) bool {
        const self: *StopAt = @ptrCast(@alignCast(context));
        self.seen += 1;
        return self.seen == self.target;
    }
};

const Times = struct { creation: windows.FILETIME, access: windows.FILETIME, write: windows.FILETIME };

const Entry = struct {
    path: []const u8,
    kind: union(enum) {
        directory: Times,
        file: struct { digest: Digest, copied: bool },
    },
};

pub const Snapshots = struct {
    roots: []const []const u8,
    store: testing.TmpDir,
    store_abs: []const u8,
    arena: std.heap.ArenaAllocator,
    saved: std.ArrayList([]const []const Entry) = .empty,
    failure: ?anyerror = null,

    pub fn init(roots: []const []const u8) !Snapshots {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        if (roots.len == 0) return error.NoRoots;
        var store = testing.tmpDir(.{});
        errdefer store.cleanup();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        errdefer arena.deinit();
        const store_abs = try store.dir.realPathFileAlloc(testing.io, ".", arena.allocator());
        const owned = try arena.allocator().alloc([]const u8, roots.len);
        for (roots, owned) |root, *slot_root| slot_root.* = try arena.allocator().dupe(u8, root);
        return .{ .roots = owned, .store = store, .store_abs = store_abs, .arena = arena };
    }

    pub fn deinit(self: *Snapshots) void {
        self.arena.deinit();
        self.store.cleanup();
    }

    pub fn taken(self: *const Snapshots) usize {
        return self.saved.items.len;
    }

    pub fn step(self: *Snapshots) disk.Step {
        return .{ .context = self, .reached = reached };
    }

    fn reached(context: *anyopaque) bool {
        const self: *Snapshots = @ptrCast(@alignCast(context));
        if (self.failure == null) self.save() catch |err| {
            std.debug.print("snapshot {d} failed: {t}\n", .{ self.saved.items.len + 1, err });
            self.failure = err;
        };
        return false;
    }

    fn slot(arena: std.mem.Allocator, store_abs: []const u8, number: usize, index: usize) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s}\\{d}\\{d}", .{ store_abs, number, index });
    }

    fn save(self: *Snapshots) !void {
        const arena = self.arena.allocator();
        const per_root = try arena.alloc([]const Entry, self.roots.len);
        for (self.roots, per_root, 0..) |root_abs, *entries, index| {
            entries.* = try saveRoot(arena, root_abs, try slot(arena, self.store_abs, self.saved.items.len + 1, index));
        }
        try self.saved.append(arena, per_root);
    }

    fn saveRoot(arena: std.mem.Allocator, root_abs: []const u8, dest_abs: []const u8) ![]const Entry {
        try Dir.cwd().createDirPath(testing.io, dest_abs);
        var root = try Dir.openDirAbsolute(testing.io, root_abs, .{ .iterate = true });
        defer root.close(testing.io);
        var entries: std.ArrayList(Entry) = .empty;
        var walker = try root.walk(testing.allocator);
        defer walker.deinit();
        while (try walker.next(testing.io)) |found| {
            const path = try arena.dupe(u8, found.path);
            const from = try join(arena, root_abs, path);
            const to = try join(arena, dest_abs, path);
            switch (found.kind) {
                .directory => {
                    try Dir.cwd().createDirPath(testing.io, to);
                    try entries.append(arena, .{ .path = path, .kind = .{ .directory = try timesOf(from) } });
                },
                .file => {
                    if (vanishes(path)) continue;
                    const copied = isAppended(path);
                    try place(from, to, copied);
                    try entries.append(arena, .{ .path = path, .kind = .{ .file = .{ .digest = try digestOf(to), .copied = copied } } });
                },
                else => {
                    std.debug.print("snapshot: {s} is a {t}, which a snapshot does not hold\n", .{ path, found.kind });
                    return error.UnexpectedEntryKind;
                },
            }
        }
        try entries.append(arena, .{ .path = ".", .kind = .{ .directory = try timesOf(root_abs) } });
        return entries.items;
    }

    pub fn restore(self: *Snapshots, number: usize) !void {
        if (number == 0 or number > self.saved.items.len) return error.NoSuchSnapshot;
        var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
        defer scratch.deinit();
        const arena = scratch.allocator();
        for (self.roots) |root_abs| {
            var root = try Dir.openDirAbsolute(testing.io, root_abs, .{ .iterate = true });
            defer root.close(testing.io);
            try clear(root);
        }
        for (self.roots, self.saved.items[number - 1], 0..) |root_abs, entries, index| {
            try restoreRoot(arena, root_abs, try slot(arena, self.store_abs, number, index), entries, number);
        }
    }

    fn restoreRoot(arena: std.mem.Allocator, root_abs: []const u8, source_abs: []const u8, entries: []const Entry, number: usize) !void {
        for (entries) |entry| {
            const to = try join(arena, root_abs, entry.path);
            switch (entry.kind) {
                .directory => try Dir.cwd().createDirPath(testing.io, to),
                .file => |file| {
                    try place(try join(arena, source_abs, entry.path), to, file.copied);
                    if (!std.mem.eql(u8, &file.digest, &try digestOf(to))) {
                        std.debug.print("snapshot {d}: {s} was changed in place after it was taken\n", .{ number, entry.path });
                        return error.SnapshotChanged;
                    }
                },
            }
        }
        var k = entries.len;
        while (k > 0) {
            k -= 1;
            switch (entries[k].kind) {
                .directory => |times| try setTimes(try join(arena, root_abs, entries[k].path), times),
                .file => {},
            }
        }
    }
};


pub fn expectEveryStep(comptime Case: type, params: Case.Params, min_steps: usize) !void {
    testing.allocator.free(try everyStepOutcomes(Case, params, min_steps));
}

pub fn everyStepOutcomes(comptime Case: type, params: Case.Params, min_steps: usize) ![]bool {
    const outcomes = try outcomesBySnapshots(Case, params);
    errdefer testing.allocator.free(outcomes);
    try testing.expect(outcomes.len >= min_steps);
    const steps = outcomes.len;
    for ([_]usize{ 1, (steps + 1) / 2, steps }) |stop| try testing.expectEqual(outcomes[stop - 1], try outcomeOfCut(Case, params, stop));
    return outcomes;
}

pub fn expectEveryCut(comptime Case: type, params: Case.Params, min_steps: usize) !void {
    try emetgate.test_util.slow();
    var stop: usize = 1;
    while (true) : (stop += 1) {
        _ = outcomeOfCut(Case, params, stop) catch |err| switch (err) {
            error.StepDidNotStop => break,
            else => |e| return e,
        };
    }
    try testing.expect(stop - 1 >= min_steps);
}

pub fn expectNoWayBack(outcomes: []const bool) !void {
    const first_new = std.mem.indexOfScalar(bool, outcomes, true) orelse return error.NeverRecoveredToNew;
    for (outcomes[first_new..]) |landed| try testing.expect(landed);
}

fn report(label: []const u8, stop: usize, landed: bool) void {
    std.debug.print("{s}: a crash after step {d} recovers to {s}\n", .{ label, stop, if (landed) "the commit" else "the old tree" });
}

fn outcomesBySnapshots(comptime Case: type, params: Case.Params) ![]bool {
    var case: Case = undefined;
    try case.init(params);
    defer case.deinit();
    var snapshots = try Snapshots.init(case.roots());
    defer snapshots.deinit();
    const step = snapshots.step();
    const stopped = try case.write(&step);
    if (snapshots.failure) |err| return err;
    try testing.expect(!stopped);
    try testing.expect(try case.settled());
    const outcomes = try testing.allocator.alloc(bool, snapshots.taken());
    errdefer testing.allocator.free(outcomes);
    for (outcomes, 1..) |*outcome, stop| {
        errdefer std.debug.print("{s}: snapshot after step {d} failed\n", .{ case.label(), stop });
        try snapshots.restore(stop);
        outcome.* = try case.recovered();
        report(case.label(), stop, outcome.*);
    }
    return outcomes;
}

fn outcomeOfCut(comptime Case: type, params: Case.Params, stop: usize) !bool {
    var case: Case = undefined;
    try case.init(params);
    defer case.deinit();
    var at: StopAt = .{ .target = stop };
    const step = at.step();
    if (!try case.write(&step)) return error.StepDidNotStop;
    errdefer std.debug.print("{s}: cut after step {d} failed\n", .{ case.label(), stop });
    const landed = try case.recovered();
    report(case.label(), stop, landed);
    return landed;
}

fn join(arena: std.mem.Allocator, base: []const u8, rel: []const u8) ![]const u8 {
    if (std.mem.eql(u8, rel, ".")) return base;
    return std.fmt.allocPrint(arena, "{s}\\{s}", .{ base, rel });
}

fn samePath(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const xs = x == '/' or x == '\\';
        const ys = y == '/' or y == '\\';
        if (xs != ys) return false;
        if (!xs and std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

fn vanishes(path: []const u8) bool {
    for (vanishing_files) |file| {
        if (samePath(path, file)) return true;
    }
    const parent = std.fs.path.dirnameWindows(path) orelse return false;
    for (vanishing_dirs) |dir| {
        if (samePath(parent, dir)) return true;
    }
    return false;
}

fn isAppended(path: []const u8) bool {
    for (appended_files) |file| {
        if (samePath(path, file)) return true;
    }
    var parts = std.mem.tokenizeAny(u8, path, "/\\");
    const first = parts.next() orelse return false;
    if (!std.ascii.eqlIgnoreCase(first, git_dir)) return false;
    var part = parts.next() orelse return false;
    while (parts.next()) |next| : (part = next) {
        if (std.ascii.eqlIgnoreCase(part, reflog_dir)) return true;
    }
    return false;
}

fn place(from_abs: []const u8, to_abs: []const u8, copied: bool) !void {
    if (!copied) return hardLink(from_abs, to_abs);
    Dir.copyFileAbsolute(from_abs, to_abs, testing.io, .{}) catch |err| {
        std.debug.print("snapshot: cannot copy {s}: {t}\n", .{ from_abs, err });
        return err;
    };
}

fn digestOf(path_abs: []const u8) !Digest {
    const bytes = try Dir.cwd().readFileAlloc(testing.io, path_abs, testing.allocator, .unlimited);
    defer testing.allocator.free(bytes);
    var digest: Digest = undefined;
    Blake3.hash(bytes, &digest, .{});
    return digest;
}

fn clear(root: Dir) !void {
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| testing.allocator.free(name);
        names.deinit(testing.allocator);
    }
    var it = root.iterate();
    while (try it.next(testing.io)) |entry| try names.append(testing.allocator, try testing.allocator.dupe(u8, entry.name));
    for (names.items) |name| try root.deleteTree(testing.io, name);
}

fn hardLink(existing_abs: []const u8, new_abs: []const u8) !void {
    var existing_w: commit_record.WidePath = undefined;
    var new_w: commit_record.WidePath = undefined;
    if (win.CreateHardLinkW(try commit_record.toWide(&new_w, new_abs), try commit_record.toWide(&existing_w, existing_abs), null) == .FALSE) {
        std.debug.print("snapshot: cannot link {s}: windows error {d}\n", .{ existing_abs, @intFromEnum(windows.GetLastError()) });
        return error.HardLinkFailed;
    }
}

fn openDirectory(path_abs: []const u8, access: windows.DWORD) !windows.HANDLE {
    var path_w: commit_record.WidePath = undefined;
    const handle = win.CreateFileW(try commit_record.toWide(&path_w, path_abs), access, win.file_share_all, null, win.open_existing, win.flag_backup_semantics, null);
    if (handle == windows.INVALID_HANDLE_VALUE) return error.DirectoryOpenFailed;
    return handle;
}

fn timesOf(path_abs: []const u8) !Times {
    const handle = try openDirectory(path_abs, win.file_read_attributes);
    defer windows.CloseHandle(handle);
    var times: Times = undefined;
    if (win.GetFileTime(handle, &times.creation, &times.access, &times.write) == .FALSE) return error.TimesUnreadable;
    return times;
}

fn setTimes(path_abs: []const u8, times: Times) !void {
    const handle = try openDirectory(path_abs, win.file_write_attributes);
    defer windows.CloseHandle(handle);
    if (win.SetFileTime(handle, &times.creation, &times.access, &times.write) == .FALSE) return error.TimesUnwritable;
}

const win = struct {
    const file_read_attributes: windows.DWORD = 0x0080;
    const file_write_attributes: windows.DWORD = 0x0100;
    const file_share_all: windows.DWORD = 0x7;
    const open_existing: windows.DWORD = 3;
    const flag_backup_semantics: windows.DWORD = 0x02000000;

    extern "kernel32" fn CreateHardLinkW(new_name: [*:0]const u16, existing: [*:0]const u16, security: ?*anyopaque) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: windows.DWORD, share: windows.DWORD, security: ?*anyopaque, disposition: windows.DWORD, flags: windows.DWORD, template: ?windows.HANDLE) callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn GetFileTime(file: windows.HANDLE, creation: *windows.FILETIME, access: *windows.FILETIME, write: *windows.FILETIME) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn SetFileTime(file: windows.HANDLE, creation: *const windows.FILETIME, access: *const windows.FILETIME, write: *const windows.FILETIME) callconv(.winapi) windows.BOOL;
};

test "crash steps: a path names a vanishing lock in either separator and any case" {
    try testing.expect(vanishes(".emetgate\\.lock"));
    try testing.expect(vanishes(".EMETGATE/Memory.lock"));
    try testing.expect(vanishes(".emetgate\\cookies\\c1"));
    try testing.expect(!vanishes(".emetgate\\cookies"));
    try testing.expect(!vanishes(".emetgate\\journal\\0123456789abcdef.json"));
    try testing.expect(!vanishes("src\\.lock"));
}

test "crash steps: reflogs and emetgate's own logs are copied, everything else is linked" {
    try testing.expect(isAppended(".git\\logs\\HEAD"));
    try testing.expect(isAppended(".git/logs/refs/heads/main"));
    try testing.expect(isAppended(".git\\worktrees\\linked\\logs\\HEAD"));
    try testing.expect(!isAppended(".git\\worktrees\\logs"));
    try testing.expect(!isAppended("src\\logs\\x.ts"));
    try testing.expect(isAppended(".emetgate\\ledger.ndjson"));
    try testing.expect(isAppended(".emetgate\\events.ndjson"));
    try testing.expect(!isAppended(".git\\logs"));
    try testing.expect(!isAppended(".git\\logsx\\HEAD"));
    try testing.expect(!isAppended(".git\\index"));
    try testing.expect(!isAppended("src\\a.ts"));
}
