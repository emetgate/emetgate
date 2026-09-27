const std = @import("std");
const shadow = @import("shadow.zig");
const search_index = @import("search_index.zig");
const change_watch = @import("change_watch.zig");

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
};

const Stamp = struct { mtime_ns: i96, size: u64 };

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
    updates_since_full: usize = 0,
    last: Report = .{},

    pub fn init(gpa: Allocator, io: std.Io, root_abs: ?[]const u8, options: change_watch.Options) Session {
        var self: Session = .{ .gpa = gpa, .io = io, .options = options };
        if (root_abs) |r| self.adopt(r) catch {};
        return self;
    }

    pub fn deinit(self: *Session) void {
        self.reset();
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
        self.git_stamp = null;
        self.list_trusted = false;
        if (self.root) |r| self.gpa.free(r);
        self.root = null;
        self.updates_since_full = 0;
    }

    fn adopt(self: *Session, root_abs: []const u8) !void {
        self.reset();
        self.root = try self.gpa.dupe(u8, root_abs);
        self.watcher = change_watch.Watcher.start(self.gpa, self.io, root_abs, self.options) catch null;
        self.git_index = gitIndexPath(self.gpa, self.io, root_abs) catch null;
    }

    pub fn owns(self: *const Session, root_abs: []const u8) bool {
        const r = self.root orelse return false;
        return std.ascii.eqlIgnoreCase(r, root_abs);
    }

    pub fn prepare(self: *Session, root_abs: []const u8) !void {
        if (!self.owns(root_abs)) try self.adopt(root_abs);
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
        if (listed and reason.len == 0) reason = "file_list_changed";
        if (self.index == null and reason.len == 0) reason = "first_build";
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
            self.last.updated += 1;
            self.updates_since_full += 1;
        }
    }

    fn fullRefresh(self: *Session, root: []const u8) !void {
        const refreshed = try search_index.refresh(self.gpa, self.io, root, self.files.?, self.index);
        if (self.index) |old| old.deinit();
        self.index = refreshed.index;
        self.last.reused = refreshed.reused;
        self.last.recomputed = refreshed.recomputed;
        self.last.changed = refreshed.changed;
        self.updates_since_full = 0;
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
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "git", "rev-parse", "--path-format=absolute", "--git-path", "index" },
        .cwd = .{ .path = root_abs },
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitFailed,
        else => return error.GitFailed,
    }
    const trimmed = std.mem.trim(u8, result.stdout, " \r\n");
    if (trimmed.len == 0) return error.GitFailed;
    const out = try gpa.dupe(u8, trimmed);
    std.mem.replaceScalar(u8, out, '/', '\\');
    return out;
}
