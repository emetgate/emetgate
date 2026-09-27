const std = @import("std");
const shadow = @import("shadow.zig");
const search_index = @import("search_index.zig");
const change_watch = @import("change_watch.zig");
const worker_pool = @import("worker_pool.zig");

const Allocator = std.mem.Allocator;

pub const sync_timeout_ms: u32 = 250;
pub const compact_after_updates: usize = 4096;
pub const racy_list_ns: i96 = 2 * std.time.ns_per_s;

pub const Mode = enum { none, full, dirty };

pub const Report = struct {
    mode: Mode = .none,
    reason: []const u8 = "",
    dirty_paths: usize = 0,
    updated: usize = 0,
    list_reused: bool = false,
    sync_ns: u64 = 0,
    list_ns: u64 = 0,
    refresh_ns: u64 = 0,
    reused: usize = 0,
    recomputed: usize = 0,
    changed: bool = false,
    loaded_from_disk: bool = false,
    stamp_ns: u64 = 0,
    work_ns: u64 = 0,
};

const Stamp = search_index.Stamp;

pub const Session = struct {
    gpa: Allocator,
    io: std.Io,
    options: change_watch.Options = .{},
    root: ?[]u8 = null,
    watcher: ?*change_watch.Watcher = null,
    files: ?[][]u8 = null,
    git_index: ?[]u8 = null,
    git_stamp: ?Stamp = null,
    list_trusted: bool = false,
    index: ?search_index.Index = null,
    index_path: ?[]u8 = null,
    reconcile: bool = false,
    unsaved: bool = false,
    updates_since_full: usize = 0,
    watch_started_ns: i96 = 0,
    loaded_ns: i96 = 0,
    pool: worker_pool.Pool = .{},
    last: Report = .{},

    pub fn init(gpa: Allocator, io: std.Io, root_abs: ?[]const u8, options: change_watch.Options) Session {
        var self: Session = .{ .gpa = gpa, .io = io, .options = options };
        if (root_abs) |r| self.adopt(r) catch {};
        return self;
    }

    pub fn startPool(self: *Session) void {
        if (self.pool.helpers() == 0) self.pool.start(worker_pool.max_threads);
    }

    pub fn deinit(self: *Session) void {
        self.saveIfNeeded();
        self.reset();
        self.pool.deinit();
    }

    pub fn saveIfNeeded(self: *Session) void {
        if (!self.unsaved) return;
        const path = self.index_path orelse return;
        const index = self.index orelse return;
        const files = self.files orelse return;
        search_index.save(self.gpa, self.io, path, index, files, self.git_stamp) catch return;
        self.unsaved = false;
    }

    fn reset(self: *Session) void {
        if (self.watcher) |w| w.deinit();
        self.watcher = null;
        if (self.files) |f| {
            shadow.freeFileList(self.gpa, f);
            self.gpa.free(f);
        }
        self.files = null;
        if (self.index) |idx| idx.deinit();
        self.index = null;
        if (self.git_index) |g| self.gpa.free(g);
        self.git_index = null;
        if (self.index_path) |i| self.gpa.free(i);
        self.index_path = null;
        self.reconcile = false;
        self.unsaved = false;
        self.git_stamp = null;
        self.list_trusted = false;
        if (self.root) |r| self.gpa.free(r);
        self.root = null;
        self.updates_since_full = 0;
    }

    fn adopt(self: *Session, root_abs: []const u8) !void {
        self.saveIfNeeded();
        self.reset();
        self.root = try self.gpa.dupe(u8, root_abs);
        self.watcher = change_watch.Watcher.start(self.gpa, self.io, root_abs, self.options) catch null;
        self.watch_started_ns = std.Io.Clock.awake.now(self.io).nanoseconds;
        self.git_index = gitIndexPath(self.gpa, self.io, root_abs) catch null;
        self.index_path = search_index.indexPath(self.gpa, root_abs) catch null;
        const loaded = if (self.index_path) |path| search_index.load(self.gpa, self.io, path) catch null else null;
        self.loaded_ns = std.Io.Clock.awake.now(self.io).nanoseconds;
        const index = loaded orelse return;
        self.index = index;
        self.reconcile = true;
        const current = if (self.git_index) |g| statOf(self.io, g) else null;
        const saved = index.git_stamp orelse return;
        const now = std.Io.Clock.real.now(self.io).nanoseconds;
        if (current == null or current.?.mtime_ns != saved.mtime_ns or current.?.size != saved.size or now - saved.mtime_ns <= racy_list_ns) return;
        const files = try self.gpa.alloc([]u8, index.files.len);
        var made: usize = 0;
        errdefer {
            for (files[0..made]) |f| self.gpa.free(f);
            self.gpa.free(files);
        }
        for (index.files, files) |src, *dst| {
            dst.* = try self.gpa.dupe(u8, src);
            made += 1;
        }
        self.files = files;
        self.git_stamp = saved;
        self.list_trusted = true;
    }

    pub fn owns(self: *const Session, root_abs: []const u8) bool {
        const r = self.root orelse return false;
        return std.ascii.eqlIgnoreCase(r, root_abs);
    }

    pub fn prepare(self: *Session, root_abs: []const u8) !void {
        if (!self.owns(root_abs)) try self.adopt(root_abs);
        self.startPool();
        const root = self.root.?;
        self.last = .{};

        var timer = Timer.start(self.io);
        var dirty: ?change_watch.Dirty = null;
        defer if (dirty) |d| d.deinit(self.gpa);
        var reason: []const u8 = "";
        if (self.watcher) |w| {
            dirty = w.sync(sync_timeout_ms) catch |err| switch (err) {
                error.OutOfMemory => return err,
                error.Overflow => blk: {
                    reason = "overflow";
                    break :blk null;
                },
                error.Timeout => blk: {
                    reason = "timeout";
                    break :blk null;
                },
                error.NotWatching => blk: {
                    reason = "not_watching";
                    self.watcher.?.deinit();
                    self.watcher = change_watch.Watcher.start(self.gpa, self.io, root, self.options) catch null;
                    break :blk null;
                },
            };
        } else reason = "no_watcher";
        self.last.sync_ns = timer.lap();

        const listed = try self.refreshList(root);
        self.last.list_ns = timer.lap();
        self.last.list_reused = !listed;
        if (self.index == null and reason.len == 0) reason = "first_build";
        if (self.reconcile and reason.len == 0) reason = "loaded_from_disk";
        if (listed and reason.len == 0) reason = "file_list_changed";
        if (self.updates_since_full >= compact_after_updates and reason.len == 0) reason = "compact";

        if (reason.len == 0) {
            self.last.mode = .dirty;
            if (dirty) |d| {
                self.last.dirty_paths = d.files.len + d.subtrees.len;
                self.applyDirty(root, d) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    error.NeedsFullRefresh => reason = "entry_reappeared",
                };
            }
        }
        if (reason.len != 0) {
            self.last.mode = .full;
            self.last.reason = reason;
            try self.fullRefresh(root);
        }
        self.last.reason = reason;
        self.last.refresh_ns = timer.lap();
    }

    fn applyDirty(self: *Session, root: []const u8, dirty: change_watch.Dirty) search_index.UpdateError!void {
        const index = &self.index.?;
        const files = self.files.?;
        for (files) |rel| {
            if (!dirty.contains(rel)) continue;
            try search_index.updateEntry(self.gpa, self.io, index, root, rel);
            self.unsaved = true;
            self.last.updated += 1;
            self.updates_since_full += 1;
        }
    }

    fn fullRefresh(self: *Session, root: []const u8) !void {
        const first_build = self.index == null;
        const pool: ?*worker_pool.Pool = if (self.pool.helpers() != 0) &self.pool else null;
        self.last.loaded_from_disk = self.reconcile;
        const compact = std.mem.eql(u8, self.last.reason, "compact");
        const in_place: ?search_index.RefreshResult = if (compact) null else if (self.index) |*idx| try search_index.refreshInPlace(self.gpa, self.io, root, self.files.?, idx, pool) else null;
        const refreshed = in_place orelse try search_index.refreshWith(self.gpa, self.io, root, self.files.?, self.index, pool);
        if (in_place == null) {
            if (self.index) |old| old.deinit();
        }
        self.index = refreshed.index;
        self.reconcile = false;
        self.last.reused = refreshed.reused;
        self.last.recomputed = refreshed.recomputed;
        self.last.stamp_ns = refreshed.stamp_ns;
        self.last.work_ns = refreshed.work_ns;
        self.last.changed = refreshed.changed;
        self.updates_since_full = if (in_place != null) self.updates_since_full + refreshed.recomputed else 0;
        if (refreshed.changed or first_build) self.unsaved = true;
        if (first_build) self.saveIfNeeded();
    }

    fn refreshList(self: *Session, root: []const u8) !bool {
        const stamp: ?Stamp = if (self.git_index) |g| statOf(self.io, g) else null;
        if (self.files != null and self.list_trusted and stamp != null and self.git_stamp != null) {
            if (stamp.?.mtime_ns == self.git_stamp.?.mtime_ns and stamp.?.size == self.git_stamp.?.size) return false;
        }
        const files = try shadow.trackedFiles(self.gpa, self.io, root);
        if (self.files) |f| {
            shadow.freeFileList(self.gpa, f);
            self.gpa.free(f);
        }
        self.files = files;
        self.git_stamp = stamp;
        const now = std.Io.Clock.real.now(self.io).nanoseconds;
        self.list_trusted = if (stamp) |s| now - s.mtime_ns > racy_list_ns else false;
        return true;
    }
};

const Timer = struct {
    io: std.Io,
    last: i96,

    fn start(io: std.Io) Timer {
        return .{ .io = io, .last = std.Io.Clock.awake.now(io).nanoseconds };
    }

    fn lap(self: *Timer) u64 {
        const now = std.Io.Clock.awake.now(self.io).nanoseconds;
        defer self.last = now;
        return @intCast(now - self.last);
    }
};

fn statOf(io: std.Io, abs: []const u8) ?Stamp {
    const stat = std.Io.Dir.cwd().statFile(io, abs, .{}) catch return null;
    return .{ .mtime_ns = stat.mtime.nanoseconds, .size = stat.size };
}

fn gitIndexPath(gpa: Allocator, io: std.Io, root_abs: []const u8) ![]u8 {
    const dot_git = try std.fmt.allocPrint(gpa, "{s}\\.git", .{root_abs});
    defer gpa.free(dot_git);
    const stat = try std.Io.Dir.cwd().statFile(io, dot_git, .{});
    if (stat.kind == .directory) return std.fmt.allocPrint(gpa, "{s}\\index", .{dot_git});
    const text = try std.Io.Dir.cwd().readFileAlloc(io, dot_git, gpa, .limited(4096));
    defer gpa.free(text);
    const prefix = "gitdir:";
    const line = std.mem.trim(u8, text, " \r\n");
    if (!std.mem.startsWith(u8, line, prefix)) return error.GitFailed;
    const target = std.mem.trim(u8, line[prefix.len..], " ");
    const absolute = std.fs.path.isAbsolute(target);
    const out = if (absolute)
        try std.fmt.allocPrint(gpa, "{s}\\index", .{target})
    else
        try std.fmt.allocPrint(gpa, "{s}\\{s}\\index", .{ root_abs, target });
    std.mem.replaceScalar(u8, out, '/', '\\');
    return out;
}
