const std = @import("std");
const cache_lease = @import("../platform/cache_lease.zig");
const emet_file = @import("../platform/emet_file.zig");
const change_watch = @import("../platform/change_watch.zig");
const sandbox = @import("../platform/sandbox.zig");
const shadow_root = @import("../platform/shadow_root.zig");
const telemetry = @import("telemetry.zig");
const tool_result = @import("tool_result.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Value = std.json.Value;
const ToolResult = tool_result.ToolResult;
const Index = emet_file.Index;
const Set = std.StringArrayHashMapUnmanaged(void);

pub const description = "Finds a case-folded literal in all project files: counts, top 20 files, first 40 hits.";

pub const waited_note = "waited for the find index build";
pub const index_suffix = ".emet";

pub const Job = enum { load, build };

const max_changed = 256;
const max_changed_bytes = 4 << 20;
const patch_wait_ms = 250;
const fence_timeout_ms = 1000;

pub fn indexDir(gpa: Allocator, root_abs: []const u8) ![]u8 {
    return cache_lease.entryDir(gpa, root_abs, "find");
}

fn putOwned(gpa: Allocator, set: *Set, p: []const u8) !void {
    if (set.contains(p)) return;
    const key = try gpa.dupe(u8, p);
    errdefer gpa.free(key);
    try set.put(gpa, key, {});
}

fn freeSet(gpa: Allocator, set: *Set) void {
    for (set.keys()) |p| gpa.free(p);
    set.deinit(gpa);
    set.* = .empty;
}

const Dirt = struct {
    files: Set = .empty,
    subtrees: Set = .empty,
    all: bool = false,

    fn deinit(d: *Dirt, gpa: Allocator) void {
        freeSet(gpa, &d.files);
        freeSet(gpa, &d.subtrees);
        d.all = false;
    }

    fn isEmpty(d: *const Dirt) bool {
        return !d.all and d.files.count() == 0 and d.subtrees.count() == 0;
    }

    fn absorb(d: *Dirt, gpa: Allocator, dirty: change_watch.Dirty) !void {
        for (dirty.files) |p| {
            if (std.ascii.eqlIgnoreCase(std.fs.path.basename(p), ".gitignore")) d.all = true;
            try putOwned(gpa, &d.files, p);
        }
        for (dirty.subtrees) |p| try putOwned(gpa, &d.subtrees, p);
    }

    fn merge(d: *Dirt, gpa: Allocator, other: *const Dirt) !void {
        d.all = d.all or other.all;
        for (other.files.keys()) |p| try putOwned(gpa, &d.files, p);
        for (other.subtrees.keys()) |p| try putOwned(gpa, &d.subtrees, p);
    }

    fn take(d: *Dirt) Dirt {
        defer d.* = .{};
        return d.*;
    }
};

const Base = struct {
    ix: Index,
    path: []u8,
};

const Worker = struct {
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),

    fn busy(w: *const Worker) bool {
        return w.thread != null or w.done.load(.acquire);
    }

    fn finished(w: *const Worker) bool {
        return w.done.load(.acquire);
    }

    fn wait(w: *Worker) void {
        if (w.thread) |t| t.join();
        w.thread = null;
    }

    fn join(w: *Worker) void {
        w.wait();
        w.done.store(false, .release);
    }
};

const PatchJob = struct {
    against: *const Index,
    swap: bool,
    dirt: Dirt,
    settled: Set,
    overlay: ?*const Index,
};

const Patch = struct {
    overlay: ?Index = null,
    reuse: bool = false,
    hidden: []u32 = &.{},
    hidden_bits: []u64 = &.{},
    settled: Set = .empty,
    full: bool = false,

    fn deinit(p: *Patch, gpa: Allocator, io: std.Io) void {
        if (p.overlay) |*o| if (!p.reuse) o.close(io);
        gpa.free(p.hidden);
        gpa.free(p.hidden_bits);
        freeSet(gpa, &p.settled);
    }
};

const Wait = enum { patch, settle, all };

pub const Session = struct {
    gpa: Allocator,
    io: std.Io,
    root: []const u8,
    scratch: *emet_file.Scratch,
    dir: ?[]u8 = null,
    watcher: ?*change_watch.Watcher = null,
    base: ?*Base = null,
    overlay: ?Index = null,
    hidden: []u32 = &.{},
    hidden_bits: []u64 = &.{},
    settled: Set = .empty,
    outside: Set = .empty,
    incoming: Dirt = .{},
    pending: Dirt = .{},
    builder: Worker = .{},
    build_job: Job = .load,
    want_build: bool = false,
    retry: bool = false,
    fresh: ?*Base = null,
    fresh_loaded: bool = false,
    built: anyerror!?*Base = null,
    patcher: Worker = .{},
    patch_job: ?PatchJob = null,
    patched: anyerror!Patch = .{},
    reaper: ?std.Thread = null,
    warmer: ?std.Thread = null,
    ready: std.Io.Event = .unset,
    cancel: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    waited: bool = false,
    stale: std.atomic.Value(bool) = .init(false),
    patch_failure: ?anyerror = null,

    pub fn create(gpa: Allocator, io: std.Io, root: []const u8) !*Session {
        const self = try gpa.create(Session);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .root = root, .scratch = try gpa.create(emet_file.Scratch) };
        self.dir = indexDir(gpa, root) catch null;
        return self;
    }

    pub fn destroy(self: *Session) void {
        self.cancel.store(true, .release);
        self.builder.wait();
        self.patcher.wait();
        self.collect();
        if (self.reaper) |t| t.join();
        if (self.warmer) |t| t.join();
        if (self.watcher) |w| w.deinit();
        if (self.fresh) |b| self.close(b);
        if (self.base) |b| self.close(b);
        if (self.overlay) |*o| o.close(self.io);
        self.gpa.free(self.hidden);
        self.gpa.free(self.hidden_bits);
        freeSet(self.gpa, &self.settled);
        freeSet(self.gpa, &self.outside);
        self.incoming.deinit(self.gpa);
        self.pending.deinit(self.gpa);
        if (self.dir) |d| self.gpa.free(d);
        self.gpa.destroy(self.scratch);
        self.gpa.destroy(self);
    }

    pub fn start(self: *Session) void {
        self.watcher = change_watch.Watcher.start(self.gpa, self.io, self.root, .{}) catch null;
        self.want_build = true;
        self.build_job = .load;
        self.schedule();
    }

    pub fn prepare(self: *Session, job: Job) !void {
        self.want_build = true;
        self.build_job = job;
        self.refresh(.all);
        if (self.base == null) return self.failure orelse error.Unexpected;
    }

    pub fn invalidate(self: *Session) void {
        self.stale.store(true, .release);
    }

    pub fn find(self: *Session, pattern: []const u8) !emet_file.Answer {
        if (self.stale.swap(false, .acq_rel)) {
            self.refresh(.settle);
            if (self.patch_failure) |err| {
                self.stale.store(true, .release);
                return err;
            }
        } else self.refresh(.patch);
        return self.search(pattern);
    }

    pub fn search(self: *Session, pattern: []const u8) !emet_file.Answer {
        const base = self.base orelse return self.failure orelse error.Unexpected;
        emet_file.setPriority(.critical);
        defer emet_file.setPriority(.normal);
        return emet_file.search(.{
            .base = &base.ix,
            .overlay = if (self.overlay) |*o| o else null,
            .hidden = self.hidden,
            .hidden_bits = self.hidden_bits,
        }, self.scratch, pattern);
    }

    pub fn current(self: *const Session) ?*const Index {
        return if (self.base) |b| &b.ix else null;
    }

    pub fn takeNote(self: *Session) ?[]const u8 {
        defer self.waited = false;
        if (self.base == null) {
            if (self.failure) |err| return @errorName(err);
        }
        return if (self.waited) waited_note else null;
    }

    fn refresh(self: *Session, wait: Wait) void {
        self.patch_failure = null;
        self.absorb(wait == .settle);
        self.want_build = self.want_build or self.retry;
        self.retry = false;
        const deadline = std.Io.Clock.Timestamp.fromNow(self.io, .{ .raw = .fromMilliseconds(patch_wait_ms), .clock = .awake });
        while (true) {
            self.ready.reset();
            self.collect();
            if (wait == .settle and self.patch_failure != null) return;
            self.schedule();
            if (!self.builder.busy() and !self.patcher.busy()) return;
            if (self.base == null or wait == .all) {
                if (self.base == null) self.waited = true;
                self.ready.waitUncancelable(self.io);
            } else if (wait == .settle and self.patcher.busy()) {
                self.ready.waitUncancelable(self.io);
            } else if (self.patcher.busy()) {
                self.ready.waitTimeout(self.io, .{ .deadline = deadline }) catch return;
            } else return;
        }
    }

    fn absorb(self: *Session, fence: bool) void {
        const w = self.watcher orelse {
            if (fence) self.dirtyAll();
            return;
        };
        const dirty = (if (fence) w.sync(fence_timeout_ms) else w.drain()) catch {
            self.dirtyAll();
            return;
        };
        defer dirty.deinit(self.gpa);
        self.incoming.absorb(self.gpa, dirty) catch {
            self.incoming.all = true;
        };
        if (self.builder.busy()) self.pending.absorb(self.gpa, dirty) catch {
            self.pending.all = true;
        };
    }

    fn dirtyAll(self: *Session) void {
        self.incoming.all = true;
        if (self.builder.busy()) self.pending.all = true;
    }

    fn collect(self: *Session) void {
        if (self.builder.finished()) {
            self.builder.join();
            if (self.built) |fresh| {
                self.fresh = fresh;
                if (self.fresh_loaded) self.pending.all = true;
            } else |err| {
                self.failure = err;
                self.retry = !self.cancel.load(.acquire);
            }
            self.built = null;
        }
        if (self.patcher.finished()) {
            self.patcher.join();
            var job = self.patch_job.?;
            self.patch_job = null;
            freeSet(self.gpa, &job.settled);
            if (self.patched) |patch| {
                job.dirt.deinit(self.gpa);
                self.apply(patch, job.swap);
            } else |err| {
                self.failure = err;
                self.patch_failure = err;
                self.incoming.merge(self.gpa, &job.dirt) catch {
                    self.incoming.all = true;
                };
                job.dirt.deinit(self.gpa);
            }
            self.patched = .{};
        }
    }

    fn apply(self: *Session, patch: Patch, swap: bool) void {
        if (swap) {
            if (self.base) |old| self.retire(old);
            self.base = self.fresh;
            self.fresh = null;
            if (self.base) |b| self.warmer = std.Thread.spawn(.{}, Index.warm, .{ &b.ix, &self.cancel }) catch null;
        }
        if (!patch.reuse) {
            if (self.overlay) |*o| o.close(self.io);
            self.overlay = patch.overlay;
        }
        self.gpa.free(self.hidden);
        self.gpa.free(self.hidden_bits);
        self.hidden = patch.hidden;
        self.hidden_bits = patch.hidden_bits;
        freeSet(self.gpa, &self.settled);
        self.settled = patch.settled;
        self.failure = null;
        self.want_build = patch.full;
        if (patch.full) self.build_job = .build;
    }

    fn schedule(self: *Session) void {
        if (!self.patcher.busy()) {
            if (self.fresh) |fresh| {
                self.launchPatch(&fresh.ix, true);
            } else if (self.base) |base| {
                if (!self.incoming.isEmpty()) self.launchPatch(&base.ix, false);
            }
        }
        if (self.want_build and !self.builder.busy() and self.fresh == null) {
            self.want_build = false;
            self.pending.deinit(self.gpa);
            self.launch(&self.builder, buildJob);
        }
    }

    fn launchPatch(self: *Session, against: *const Index, swap: bool) void {
        var dirt = self.incoming.take();
        if (swap) {
            dirt.merge(self.gpa, &self.pending) catch {
                dirt.all = true;
            };
            self.pending.deinit(self.gpa);
        }
        var settled: Set = .empty;
        for (self.settled.keys()) |p| putOwned(self.gpa, &settled, p) catch {
            dirt.all = true;
        };
        self.patch_job = .{
            .against = against,
            .swap = swap,
            .dirt = dirt,
            .settled = settled,
            .overlay = if (self.overlay) |*o| o else null,
        };
        self.launch(&self.patcher, patchJob);
    }

    fn launch(self: *Session, w: *Worker, comptime job: fn (*Session) void) void {
        w.done.store(false, .release);
        w.thread = std.Thread.spawn(.{}, job, .{self}) catch null;
        if (w.thread == null) job(self);
    }

    fn finish(self: *Session, w: *Worker) void {
        w.done.store(true, .release);
        self.ready.set(self.io);
    }

    fn buildJob(self: *Session) void {
        emet_file.setPriority(.background);
        defer emet_file.setPriority(.foreground);
        self.built = self.produce(self.build_job);
        self.finish(&self.builder);
    }

    fn patchJob(self: *Session) void {
        emet_file.setPriority(.background);
        defer emet_file.setPriority(.foreground);
        self.patched = self.resolve(&self.patch_job.?);
        self.finish(&self.patcher);
    }

    fn retire(self: *Session, old: *Base) void {
        if (self.reaper) |t| t.join();
        const warming = self.warmer;
        self.warmer = null;
        self.reaper = std.Thread.spawn(.{}, reap, .{ self, old, warming }) catch null;
        if (self.reaper == null) self.reap(old, warming);
    }

    fn reap(self: *Session, old: *Base, warming: ?std.Thread) void {
        if (warming) |t| t.join();
        old.ix.close(self.io);
        Dir.cwd().deleteFile(self.io, old.path) catch {};
        self.gpa.free(old.path);
        self.gpa.destroy(old);
    }

    fn close(self: *Session, b: *Base) void {
        b.ix.close(self.io);
        self.gpa.free(b.path);
        self.gpa.destroy(b);
    }

    fn produce(self: *Session, job: Job) !?*Base {
        const dir_path = self.dir orelse return error.LocalAppDataUnavailable;
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        try Dir.cwd().createDirPath(self.io, dir_path);
        var dir = try Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true });
        defer dir.close(self.io);

        var names: std.ArrayList([]const u8) = .empty;
        var generations: std.ArrayList(u64) = .empty;
        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            const name = try arena.dupe(u8, entry.name);
            try names.append(arena, name);
            if (generationOf(name)) |g| try generations.append(arena, g);
        }
        std.mem.sort(u64, generations.items, {}, std.sort.desc(u64));

        const b = try self.gpa.create(Base);
        errdefer self.gpa.destroy(b);
        self.fresh_loaded = false;
        if (job == .load) {
            for (generations.items) |g| {
                const path = try self.generationPath(g);
                b.* = .{ .ix = Index.open(self.io, path) catch {
                    self.gpa.free(path);
                    continue;
                }, .path = path };
                self.fresh_loaded = true;
                break;
            }
            for (names.items) |name| {
                if (self.fresh_loaded and std.mem.eql(u8, std.fs.path.basename(b.path), name)) continue;
                dir.deleteFile(self.io, name) catch {};
            }
        }
        if (!self.fresh_loaded) {
            const next = if (generations.items.len == 0) 1 else generations.items[0] + 1;
            const path = try self.generationPath(next);
            errdefer self.gpa.free(path);
            const paths = try emet_file.list(self.io, self.gpa, arena, self.root);
            b.* = .{ .ix = try emet_file.build(self.io, self.gpa, arena, self.root, paths, .{ .file = path }, &self.cancel), .path = path };
        }
        return b;
    }

    fn resolve(self: *Session, job: *PatchJob) !Patch {
        const gpa = self.gpa;
        const io = self.io;
        const base = job.against;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var root = try Dir.cwd().openDir(io, self.root, .{});
        defer root.close(io);

        var candidates: Set = .empty;
        var listed: Set = .empty;
        for (job.settled.keys()) |p| try candidates.put(arena, p, {});
        for (job.dirt.files.keys()) |p| try candidates.put(arena, p, {});
        const subtrees = job.dirt.subtrees.keys();
        var relisted: std.ArrayList([]const u8) = .empty;
        for (subtrees) |d| {
            if (outsideOf(&self.outside, d)) continue;
            _ = root.statFile(io, d, .{}) catch continue;
            try relisted.append(arena, d);
        }
        if (job.dirt.all) {
            freeSet(gpa, &self.outside);
            for (try emet_file.list(io, gpa, arena, self.root)) |p| {
                try listed.put(arena, p, {});
                try candidates.put(arena, p, {});
            }
            for (0..base.h.n_files) |f| try candidates.put(arena, base.path(@intCast(f)), {});
        } else {
            for (try emet_file.listUnder(io, gpa, arena, self.root, relisted.items)) |p| {
                try listed.put(arena, p, {});
                try candidates.put(arena, p, {});
            }
            if (subtrees.len != 0) for (0..base.h.n_files) |f| {
                const p = base.path(@intCast(f));
                if (within(subtrees, p)) try candidates.put(arena, p, {});
            };
            for (job.settled.keys()) |p| {
                if (base.lookup(p) == null) try listed.put(arena, p, {});
            }
            var unknown: std.ArrayList([]const u8) = .empty;
            for (job.dirt.files.keys()) |p| {
                if (base.lookup(p) == null and !listed.contains(p) and !outsideOf(&self.outside, p)) try unknown.append(arena, p);
            }
            for (try emet_file.listUnder(io, gpa, arena, self.root, unknown.items)) |p| {
                try listed.put(arena, p, {});
                try candidates.put(arena, p, {});
            }
            var asks: Set = .empty;
            for (unknown.items) |p| {
                if (listed.contains(p)) continue;
                try asks.put(arena, p, {});
                var i: usize = 0;
                while (std.mem.indexOfScalarPos(u8, p, i, '/')) |k| : (i = k + 1) try asks.put(arena, try std.fmt.allocPrint(arena, "{s}/", .{p[0..k]}), {});
            }
            for (try emet_file.ignored(io, gpa, arena, self.root, asks.keys())) |p| try putOwned(gpa, &self.outside, std.mem.trimEnd(u8, p, "/"));
        }

        var hidden: std.ArrayList(u32) = .empty;
        var shown: std.ArrayList([]const u8) = .empty;
        var stamps: std.ArrayList(emet_file.Stamp) = .empty;
        var bytes: u64 = 0;
        const keys = candidates.keys();
        const found = if (job.dirt.all) try emet_file.stampTree(io, arena, self.root, keys) else try emet_file.stampEach(io, arena, self.root, keys);
        for (keys, found) |p, stamp| {
            if (base.lookup(p)) |f| {
                const gone = stamp == null or ((job.dirt.all or within(relisted.items, p)) and !listed.contains(p));
                if (!gone and stamp.?.eql(base.stamps[f])) continue;
                try hidden.append(arena, f);
                if (gone) continue;
            } else if (stamp == null or !listed.contains(p)) continue;
            try shown.append(arena, p);
            try stamps.append(arena, stamp.?);
            bytes += stamp.?.size;
        }

        var patch: Patch = .{ .full = hidden.items.len + shown.items.len > max_changed or bytes > max_changed_bytes };
        errdefer patch.deinit(gpa, io);
        for (hidden.items) |f| try putOwned(gpa, &patch.settled, base.path(f));
        for (shown.items) |p| try putOwned(gpa, &patch.settled, p);
        std.mem.sort(u32, hidden.items, {}, std.sort.asc(u32));
        patch.hidden = try gpa.dupe(u32, hidden.items);
        if (hidden.items.len != 0) {
            patch.hidden_bits = try gpa.alloc(u64, (base.h.n_files + 63) / 64);
            @memset(patch.hidden_bits, 0);
            for (hidden.items) |f| patch.hidden_bits[f / 64] |= @as(u64, 1) << @intCast(f % 64);
        }
        if (job.overlay) |o| {
            if (unchanged(o, shown.items, stamps.items)) {
                patch.overlay = o.*;
                patch.reuse = true;
                return patch;
            }
        }
        if (shown.items.len != 0) patch.overlay = try emet_file.build(io, gpa, arena, self.root, shown.items, .memory, &self.cancel);
        return patch;
    }

    fn generationPath(self: *Session, generation: u64) ![]u8 {
        return std.fmt.allocPrint(self.gpa, "{s}\\{d}{s}", .{ self.dir.?, generation, index_suffix });
    }
};

fn within(subtrees: []const []const u8, p: []const u8) bool {
    for (subtrees) |d| {
        if (change_watch.under(d, p)) return true;
    }
    return false;
}

fn outsideOf(outside: *const Set, p: []const u8) bool {
    if (outside.contains(p)) return true;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, p, i, '/')) |k| : (i = k + 1) {
        if (outside.contains(p[0..k])) return true;
    }
    return false;
}

fn unchanged(overlay: *const Index, paths: []const []const u8, stamps: []const emet_file.Stamp) bool {
    if (overlay.h.n_files != paths.len) return false;
    for (paths, stamps) |p, stamp| {
        const f = overlay.lookup(p) orelse return false;
        if (!stamp.eql(overlay.stamps[f])) return false;
    }
    return true;
}

fn generationOf(name: []const u8) ?u64 {
    if (!std.mem.endsWith(u8, name, index_suffix)) return null;
    return std.fmt.parseInt(u64, name[0 .. name.len - index_suffix.len], 10) catch null;
}

pub fn callFind(gpa: Allocator, args: ?Value, event: *telemetry.Event, session: ?*Session) !ToolResult {
    const pattern = try tool_result.requireString(args, "pattern");
    event.label = "find";
    const s = session orelse return .{ .text = try gpa.dupe(u8, "find is not available outside a git repository"), .is_error = true };
    defer if (s.takeNote()) |note| {
        event.reason = note;
    };
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    const answer = s.find(pattern) catch |err| return tool_result.failure(gpa, &buffer, err, event);
    try buffer.writer.writeAll(answer.text);
    return tool_result.success(gpa, &buffer);
}
