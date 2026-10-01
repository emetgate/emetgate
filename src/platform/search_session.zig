const std = @import("std");
const shadow = @import("shadow.zig");
const search_index = @import("search_index.zig");
const index_file = @import("search_index_file.zig");
const index_map = @import("index_map.zig");
const stat_scan = @import("stat_scan.zig");
const change_watch = @import("change_watch.zig");
const worker_pool = @import("worker_pool.zig");
const git_index = @import("git_index.zig");
const answer = @import("../engine/answer.zig");
const merkle_tree = @import("../engine/merkle_tree.zig");

const Allocator = std.mem.Allocator;
const Prepared = search_index.Prepared;
const Seen = search_index.Seen;
const Stamp = search_index.Stamp;
pub const GitStamp = search_index.GitStamp;
pub const LoadFailure = search_index.LoadFailure;

pub const sync_timeout_ms: u32 = 250;
pub const persist_after: usize = 64;

pub const Mode = enum { none, full, dirty };

pub const Options = struct {
    buffer_bytes: u32 = change_watch.default_buffer_bytes,
    workers: ?usize = null,
    index_dir: ?[]const u8 = null,

    fn watch(self: Options) change_watch.Options {
        return .{ .buffer_bytes = self.buffer_bytes };
    }
};

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
    index_load: ?LoadFailure = null,
    save_failure: ?anyerror = null,
    warm_wait_ns: u64 = 0,
    warmup_ns: u64 = 0,
    verify_ns: u64 = 0,
};

pub fn rebuildNote(why: LoadFailure) []const u8 {
    return switch (why) {
        .missing => "built: no saved index",
        .too_large => "rebuilt: the saved index was too large to load",
        .io => "rebuilt: the saved index could not be read",
        .corrupt => "rebuilt: the saved index was damaged",
        .version => "rebuilt: the saved index was written by another version",
    };
}

pub const FoldedContext = struct {
    pub fn hash(_: FoldedContext, key: []const u8) u32 {
        var hasher = std.hash.Wyhash.init(0);
        var buf: [64]u8 = undefined;
        var at: usize = 0;
        while (at < key.len) {
            const n = @min(buf.len, key.len - at);
            for (key[at..][0..n], buf[0..n]) |c, *o| o.* = index_file.foldByte(c);
            hasher.update(buf[0..n]);
            at += n;
        }
        return @truncate(hasher.final());
    }

    pub fn eql(_: FoldedContext, a: []const u8, b: []const u8, _: usize) bool {
        return index_file.foldedEqual(a, b);
    }
};

pub const FoldedSet = std.ArrayHashMapUnmanaged([]const u8, void, FoldedContext, true);

pub const max_journal: usize = 8192;

pub const Delta = struct {
    entries: std.ArrayHashMapUnmanaged([]const u8, Prepared, FoldedContext, true) = .empty,
    removed: std.DynamicBitSetUnmanaged = .{},
    version: u64 = 0,
    journal: std.ArrayList(Change) = .empty,
    journal_from: u64 = 0,

    pub const Change = struct { version: u64, path: []u8 };

    pub fn deinit(self: *Delta, gpa: Allocator) void {
        for (self.entries.values()) |v| v.deinit(gpa);
        self.entries.deinit(gpa);
        self.removed.deinit(gpa);
        for (self.journal.items) |c| gpa.free(c.path);
        self.journal.deinit(gpa);
        const next = self.version + 1;
        self.* = .{ .version = next, .journal_from = next };
    }

    pub fn get(self: *const Delta, rel: []const u8) ?*const Prepared {
        return self.entries.getPtr(rel);
    }

    fn reserve(self: *Delta, gpa: Allocator, path: []const u8) ![]u8 {
        try self.journal.ensureUnusedCapacity(gpa, 1);
        return gpa.dupe(u8, path);
    }

    fn commit(self: *Delta, gpa: Allocator, copy: []u8) void {
        self.version += 1;
        self.journal.appendAssumeCapacity(.{ .version = self.version, .path = copy });
        if (self.journal.items.len <= max_journal) return;
        const cut = self.journal.items.len / 2;
        for (self.journal.items[0..cut]) |c| gpa.free(c.path);
        self.journal_from = self.journal.items[cut - 1].version;
        std.mem.copyForwards(Change, self.journal.items[0..], self.journal.items[cut..]);
        self.journal.shrinkRetainingCapacity(self.journal.items.len - cut);
    }

    pub fn changesSince(self: *const Delta, version: u64) ?[]const Change {
        if (version < self.journal_from) return null;
        var lo: usize = 0;
        var hi: usize = self.journal.items.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (self.journal.items[mid].version <= version) lo = mid + 1 else hi = mid;
        }
        return self.journal.items[lo..];
    }

    pub fn put(self: *Delta, gpa: Allocator, prepared: Prepared) !void {
        const copy = try self.reserve(gpa, prepared.path);
        errdefer gpa.free(copy);
        const got = try self.entries.getOrPut(gpa, prepared.path);
        if (got.found_existing) got.value_ptr.deinit(gpa);
        got.key_ptr.* = prepared.path;
        got.value_ptr.* = prepared;
        self.commit(gpa, copy);
    }

    pub fn drop(self: *Delta, gpa: Allocator, rel: []const u8) !void {
        const index = self.entries.getIndex(rel) orelse return;
        const copy = try self.reserve(gpa, self.entries.values()[index].path);
        const value = self.entries.values()[index];
        self.entries.orderedRemoveAt(index);
        value.deinit(gpa);
        self.commit(gpa, copy);
    }

    pub fn isRemoved(self: *const Delta, id: u32) bool {
        return id < self.removed.bit_length and self.removed.isSet(id);
    }

    pub fn markRemoved(self: *Delta, gpa: Allocator, id: u32, universe: u32, path: []const u8) !void {
        if (self.removed.bit_length < universe) try self.removed.resize(gpa, universe, false);
        if (self.removed.isSet(id)) return;
        const copy = try self.reserve(gpa, path);
        self.removed.set(id);
        self.commit(gpa, copy);
    }
};

pub const ScopeTree = struct {
    version: u64,
    paths: [][]const u8,
    owned: [][]u8,
    digests: []search_index.Digest,
    tree: merkle_tree.Tree,

    fn deinit(self: *ScopeTree, gpa: Allocator) void {
        for (self.owned) |path| gpa.free(path);
        gpa.free(self.owned);
        gpa.free(self.paths);
        gpa.free(self.digests);
        self.tree.deinit(gpa);
    }

    fn find(self: *const ScopeTree, path: []const u8) ?usize {
        var lo: usize = 0;
        var hi: usize = self.paths.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            switch (std.mem.order(u8, self.paths[mid], path)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return mid,
            }
        }
        return null;
    }
};

pub const max_scope_trees: usize = 16;

pub const Session = struct {
    gpa: Allocator,
    io: std.Io,
    options: Options = .{},
    root: ?[]u8 = null,
    watcher: ?*change_watch.Watcher = null,
    git_index: ?[]u8 = null,
    git_stamp: ?GitStamp = null,
    index_dir: ?[]u8 = null,
    base: ?index_map.Image = null,
    delta: Delta = .{},
    pool: worker_pool.Pool = .{},
    last: Report = .{},
    barrier: u64 = 0,
    trees: std.StringHashMapUnmanaged(*ScopeTree) = .empty,
    base_unreadable: ?[]u32 = null,
    base_order: ?[]u32 = null,
    base_leaves: ?[]search_index.Digest = null,
    publish_thread: ?std.Thread = null,
    publish_error: ?anyerror = null,
    pending: Report = .{},
    load_failure: ?LoadFailure = null,
    save_failure: ?anyerror = null,
    watch_started_ns: i96 = 0,
    loaded_ns: i96 = 0,
    warm_thread: ?std.Thread = null,
    warmed: bool = false,
    warm_error: ?anyerror = null,
    cancel: search_index.Cancel = .init(false),
    publish_due: bool = false,

    pub fn init(gpa: Allocator, io: std.Io, root_abs: ?[]const u8, options: Options) Session {
        var self: Session = .{ .gpa = gpa, .io = io, .options = options };
        if (root_abs) |r| self.root = gpa.dupe(u8, r) catch null;
        return self;
    }

    pub fn start(self: *Session) void {
        if (self.root == null or self.warmed or self.warm_thread != null) return;
        self.startWatcher();
        self.warm_thread = std.Thread.spawn(.{}, warmTask, .{self}) catch null;
    }

    fn startWatcher(self: *Session) void {
        if (self.watcher != null) return;
        self.watcher = change_watch.Watcher.start(self.gpa, self.io, self.root.?, self.options.watch()) catch null;
        self.watch_started_ns = self.now();
    }

    fn warmTask(self: *Session) void {
        self.warm_error = if (self.warmup()) |_| null else |err| err;
    }

    pub fn warm(self: *Session) !void {
        if (self.warm_thread) |t| {
            const started = std.Io.Clock.awake.now(self.io).nanoseconds;
            t.join();
            self.warm_thread = null;
            self.warmed = true;
            self.pending.warm_wait_ns = @intCast(std.Io.Clock.awake.now(self.io).nanoseconds - started);
        } else if (!self.warmed) {
            self.warm_error = if (self.warmup()) |_| null else |err| err;
            self.warmed = true;
        }
        if (self.warm_error) |err| return err;
    }

    pub fn deinit(self: *Session) void {
        if (self.warm_thread) |t| {
            t.join();
            self.warmed = true;
        }
        self.warm_thread = null;
        self.persistIfDue();
        self.reset();
        self.clearRoots();
        self.trees.deinit(self.gpa);
        self.pool.deinit();
    }

    pub fn persistIfDue(self: *Session) void {
        if (!self.warmed or self.warm_error != null) return;
        if (!self.publish_due and self.delta.entries.count() < persist_after) return;
        self.persist() catch |err| {
            self.save_failure = err;
        };
    }

    fn reset(self: *Session) void {
        self.joinPublish();
        if (self.watcher) |w| w.deinit();
        self.watcher = null;
        if (self.base) |b| b.deinit(self.gpa);
        self.base = null;
        self.delta.deinit(self.gpa);
        self.clearRoots();
        self.forgetBaseCaches();
        if (self.git_index) |g| self.gpa.free(g);
        self.git_index = null;
        if (self.index_dir) |d| self.gpa.free(d);
        self.index_dir = null;
        if (self.root) |r| self.gpa.free(r);
        self.root = null;
        self.git_stamp = null;
        self.load_failure = null;
        self.save_failure = null;
        self.warmed = false;
        self.warm_error = null;
        self.publish_due = false;
    }

    fn clearRoots(self: *Session) void {
        var it = self.trees.iterator();
        while (it.next()) |kv| {
            self.gpa.free(kv.key_ptr.*);
            kv.value_ptr.*.deinit(self.gpa);
            self.gpa.destroy(kv.value_ptr.*);
        }
        self.trees.clearRetainingCapacity();
    }

    pub fn scopeRoot(self: *Session, key: ?[]const u8, rel: []const u8, file: bool) !search_index.Digest {
        if (key) |k| {
            if (self.trees.get(k)) |tree| {
                if (tree.version == self.delta.version) return tree.tree.root();
                if (try self.advanceTree(tree, rel, file)) return tree.tree.root();
            }
        }
        const built = try self.gpa.create(ScopeTree);
        errdefer self.gpa.destroy(built);
        built.* = try self.buildTree(rel, file);
        const digest = built.tree.root();
        const k = key orelse {
            built.deinit(self.gpa);
            self.gpa.destroy(built);
            return digest;
        };
        if (self.trees.fetchRemove(k)) |old| {
            self.gpa.free(old.key);
            old.value.deinit(self.gpa);
            self.gpa.destroy(old.value);
        }
        if (self.trees.count() >= max_scope_trees) self.clearRoots();
        const owned = self.gpa.dupe(u8, k) catch |err| {
            built.deinit(self.gpa);
            return err;
        };
        self.trees.put(self.gpa, owned, built) catch |err| {
            self.gpa.free(owned);
            built.deinit(self.gpa);
            return err;
        };
        return digest;
    }

    fn inScope(path: []const u8, rel: []const u8, file: bool) bool {
        if (file) return change_watch.samePath(path, rel);
        if (rel.len == 0) return true;
        return change_watch.under(rel, path) and path.len > rel.len;
    }

    fn isInternal(path: []const u8) bool {
        var segments = std.mem.tokenizeAny(u8, path, "/\\");
        const first = segments.next() orelse return false;
        return std.ascii.eqlIgnoreCase(first, ".git") or std.ascii.eqlIgnoreCase(first, shadow.workspace_dir);
    }

    fn leafDigest(self: *Session, path: []const u8) ?search_index.Digest {
        if (self.delta.get(path)) |p| return if (p.state == .indexed) p.digest else null;
        const v = self.view() orelse return null;
        const id = v.find(path) orelse return null;
        if (self.delta.isRemoved(id) or v.stateOf(id) != .indexed) return null;
        return v.record(id).digest;
    }

    fn advanceTree(self: *Session, tree: *ScopeTree, rel: []const u8, file: bool) !bool {
        const changes = self.delta.changesSince(tree.version) orelse return false;
        for (changes) |change| {
            if (!inScope(change.path, rel, file) or isInternal(change.path)) continue;
            const current = self.leafDigest(change.path);
            const at = tree.find(change.path) orelse {
                if (current != null) return false;
                continue;
            };
            const digest = current orelse return false;
            if (std.mem.eql(u8, &digest, &tree.digests[at])) continue;
            tree.digests[at] = digest;
            tree.tree.update(at, answer.pathLeafHash(.{ .path = tree.paths[at], .digest = digest }));
        }
        tree.version = self.delta.version;
        return true;
    }

    const TreeLeaf = struct { path: []const u8, digest: search_index.Digest, hash: search_index.Digest, owned: bool };

    fn buildTree(self: *Session, rel: []const u8, file: bool) !ScopeTree {
        var extra: std.ArrayList(TreeLeaf) = .empty;
        defer extra.deinit(self.gpa);
        for (self.delta.entries.values()) |p| {
            if (p.state != .indexed or !inScope(p.path, rel, file) or isInternal(p.path)) continue;
            try extra.append(self.gpa, .{ .path = p.path, .digest = p.digest, .hash = answer.pathLeafHash(.{ .path = p.path, .digest = p.digest }), .owned = true });
        }
        std.mem.sort(TreeLeaf, extra.items, {}, struct {
            fn less(_: void, a: TreeLeaf, b: TreeLeaf) bool {
                return std.mem.order(u8, a.path, b.path) == .lt;
            }
        }.less);

        var leaves: std.ArrayList(TreeLeaf) = .empty;
        defer leaves.deinit(self.gpa);
        var e: usize = 0;
        if (self.view()) |v| {
            const range: [2]u32 = if (file) blk: {
                const id = v.find(rel) orelse break :blk .{ 0, 0 };
                break :blk .{ id, id + 1 };
            } else v.dirRange(rel);
            const order = try self.baseOrder();
            const hashes = try self.baseLeaves();
            for (order) |id| {
                if (id < range[0] or id >= range[1]) continue;
                if (self.delta.isRemoved(id) or v.stateOf(id) != .indexed) continue;
                const path = v.path(id);
                if (isInternal(path)) continue;
                while (e < extra.items.len and std.mem.order(u8, extra.items[e].path, path) == .lt) : (e += 1) try leaves.append(self.gpa, extra.items[e]);
                try leaves.append(self.gpa, .{ .path = path, .digest = v.record(id).digest, .hash = hashes[id], .owned = false });
            }
        }
        while (e < extra.items.len) : (e += 1) try leaves.append(self.gpa, extra.items[e]);

        const hashes = try self.gpa.alloc(search_index.Digest, leaves.items.len);
        defer self.gpa.free(hashes);
        var owned_count: usize = 0;
        for (leaves.items, hashes, 0..) |leaf, *h, i| {
            if (i != 0 and std.mem.order(u8, leaves.items[i - 1].path, leaf.path) != .lt) return error.InconsistentCertificate;
            h.* = leaf.hash;
            if (leaf.owned) owned_count += 1;
        }
        var tree = try merkle_tree.Tree.build(self.gpa, hashes);
        errdefer tree.deinit(self.gpa);
        const paths = try self.gpa.alloc([]const u8, leaves.items.len);
        errdefer self.gpa.free(paths);
        const owned = try self.gpa.alloc([]u8, owned_count);
        var made: usize = 0;
        errdefer {
            for (owned[0..made]) |path| self.gpa.free(path);
            self.gpa.free(owned);
        }
        for (leaves.items, paths) |leaf, *path| {
            if (leaf.owned) {
                owned[made] = try self.gpa.dupe(u8, leaf.path);
                path.* = owned[made];
                made += 1;
            } else path.* = leaf.path;
        }
        const digests = try self.gpa.alloc(search_index.Digest, leaves.items.len);
        for (leaves.items, digests) |leaf, *d| d.* = leaf.digest;
        return .{ .version = self.delta.version, .paths = paths, .owned = owned, .digests = digests, .tree = tree };
    }

    pub fn owns(self: *const Session, root_abs: []const u8) bool {
        const r = self.root orelse return false;
        return std.ascii.eqlIgnoreCase(r, root_abs);
    }

    pub fn view(self: *const Session) ?*const index_file.View {
        return if (self.base) |*b| &b.view else null;
    }

    pub fn startPool(self: *Session) void {
        if (self.pool.helpers() != 0) return;
        const wanted = self.options.workers orelse worker_pool.max_threads;
        if (wanted > 1) self.pool.start(wanted);
    }

    pub fn poolPtr(self: *Session) ?*worker_pool.Pool {
        return if (self.pool.helpers() != 0) &self.pool else null;
    }

    fn now(self: *Session) i96 {
        return std.Io.Clock.awake.now(self.io).nanoseconds;
    }

    fn warmup(self: *Session) !void {
        const root = self.root orelse return error.NoRoot;
        const started = self.now();
        var report: Report = .{};
        self.startWatcher();
        self.git_index = gitIndexPath(self.gpa, self.io, root) catch null;
        self.index_dir = if (self.options.index_dir) |dir| try self.gpa.dupe(u8, dir) else search_index.indexDir(self.gpa, root) catch null;
        self.startPool();
        if (self.index_dir) |dir| switch (index_map.open(self.gpa, self.io, dir)) {
            .image => |image| {
                const verify_started = self.now();
                if (image.view.verify(self.poolPtr())) {
                    self.base = image;
                    self.forgetBaseCaches();
                } else {
                    image.deinit(self.gpa);
                    self.load_failure = .corrupt;
                }
                report.verify_ns = @intCast(self.now() - verify_started);
            },
            .failed => |why| self.load_failure = why,
        } else self.load_failure = .io;
        self.loaded_ns = self.now();

        var timer = Timer.start(self.io);
        const current = if (self.git_index) |g| gitStampOf(self.io, g) else null;
        var from_base = false;
        if (self.base) |b| if (b.view.gitStamp()) |saved| {
            from_base = sameGitStamp(current, saved);
        };
        var listed: ?[][]u8 = null;
        defer if (listed) |l| freeList(self.gpa, l);
        if (!from_base) listed = try self.readTracked(root);
        self.git_stamp = current;
        report.list_ns = timer.lap();
        report.list_reused = from_base;

        if (self.base != null) {
            report.reason = "loaded_from_disk";
            report.loaded_from_disk = true;
            try self.reconcile(root, listed, &report);
        } else {
            report.reason = "first_build";
            report.index_load = self.load_failure orelse .missing;
            try self.buildBase(root, listed.?, &report);
        }
        report.mode = .full;
        report.refresh_ns = timer.lap();
        if (self.publish_due) self.publishInBackground();
        _ = try self.baseOrder();
        _ = try self.baseLeaves();
        report.warmup_ns = @intCast(self.now() - started);
        self.pending = report;
    }

    fn readTracked(self: *Session, root: []const u8) ![][]u8 {
        if (self.git_index) |g| {
            if (try git_index.readTracked(self.gpa, self.io, g)) |names| return names;
        }
        const listed = try shadow.trackedFiles(self.gpa, self.io, root);
        defer self.gpa.free(listed);
        var out = std.ArrayList([]u8).initCapacity(self.gpa, listed.len) catch |err| {
            shadow.freeFileList(self.gpa, listed);
            return err;
        };
        for (listed) |name| {
            if (out.items.len != 0 and std.mem.eql(u8, out.items[out.items.len - 1], name)) {
                self.gpa.free(name);
                continue;
            }
            out.appendAssumeCapacity(name);
        }
        return out.toOwnedSlice(self.gpa) catch |err| {
            for (out.items) |n| self.gpa.free(n);
            out.deinit(self.gpa);
            return err;
        };
    }

    fn buildBase(self: *Session, root: []const u8, paths: []const []const u8, report: *Report) !void {
        const written_ns: i64 = @intCast(std.Io.Clock.real.now(self.io).nanoseconds);
        var timer = Timer.start(self.io);
        const seen = try self.gpa.alloc(?Seen, paths.len);
        defer self.gpa.free(seen);
        try stat_scan.stampAll(self.gpa, root, paths, seen, self.poolPtr());
        report.stamp_ns = timer.lap();
        const prepared = try search_index.prepareAll(self.gpa, self.io, root, paths, seen, false, true, self.poolPtr(), &self.cancel);
        defer search_index.freeAll(self.gpa, prepared);
        search_index.sortByPath(prepared);
        const inputs = try self.gpa.alloc(index_file.Input, prepared.len);
        defer self.gpa.free(inputs);
        for (prepared, inputs) |p, *in| in.* = p.input();
        const image = try index_file.build(self.gpa, inputs, .{ .written_ns = written_ns, .git_stamp = self.git_stamp }, self.poolPtr());
        errdefer self.gpa.free(image);
        self.base = try index_map.fromHeap(image, index_map.newTag(self.io));
        self.forgetBaseCaches();
        self.publish_due = true;
        report.recomputed = prepared.len;
        report.changed = true;
        report.work_ns = timer.lap();
    }

    fn reconcile(self: *Session, root: []const u8, listed: ?[]const []const u8, report: *Report) !void {
        const v = &self.base.?.view;
        var timer = Timer.start(self.io);
        var base_paths: ?[][]const u8 = null;
        defer if (base_paths) |b| self.gpa.free(b);
        const paths: []const []const u8 = listed orelse blk: {
            const all = try self.gpa.alloc([]const u8, v.count());
            for (all, 0..) |*p, i| p.* = v.path(@intCast(i));
            base_paths = all;
            break :blk all;
        };
        const seen = try self.gpa.alloc(?Seen, paths.len);
        defer self.gpa.free(seen);
        try stat_scan.stampAll(self.gpa, root, paths, seen, self.poolPtr());
        report.stamp_ns = timer.lap();

        var matched = try std.DynamicBitSetUnmanaged.initEmpty(self.gpa, v.count());
        defer matched.deinit(self.gpa);
        var todo_paths: std.ArrayList([]const u8) = .empty;
        defer todo_paths.deinit(self.gpa);
        var todo_seen: std.ArrayList(?Seen) = .empty;
        defer todo_seen.deinit(self.gpa);
        for (paths, seen, 0..) |p, s, i| {
            const id: ?u32 = if (listed == null) @intCast(i) else v.find(p);
            if (id) |b| {
                matched.set(b);
                if (s) |live| {
                    if (live.kind == .file and search_index.sameStamp(v.record(b).stamp(), live.stamp)) {
                        report.reused += 1;
                        continue;
                    }
                }
            }
            try todo_paths.append(self.gpa, p);
            try todo_seen.append(self.gpa, s);
        }
        var id: u32 = 0;
        while (id < v.count()) : (id += 1) {
            if (!matched.isSet(id)) try self.delta.markRemoved(self.gpa, id, v.count(), v.path(id));
        }
        try self.applyPrepared(root, todo_paths.items, todo_seen.items, true);
        report.recomputed = todo_paths.items.len;
        report.changed = todo_paths.items.len != 0 or matched.count() != v.count();
        report.work_ns = timer.lap();
    }

    fn applyPrepared(self: *Session, root: []const u8, paths: []const []const u8, seen: []const ?Seen, with_spans: bool) !void {
        if (paths.len == 0) return;
        const prepared = try search_index.prepareAll(self.gpa, self.io, root, paths, seen, true, with_spans, self.poolPtr(), null);
        defer self.gpa.free(prepared);
        var moved: usize = 0;
        errdefer for (prepared[moved..]) |p| p.deinit(self.gpa);
        for (prepared) |p| {
            if (self.view()) |v| if (v.find(p.path)) |b| try self.delta.markRemoved(self.gpa, b, v.count(), v.path(b));
            moved += 1;
            try self.delta.put(self.gpa, p);
        }
    }

    pub fn prepare(self: *Session, root_abs: []const u8) !void {
        if (!self.owns(root_abs)) {
            if (self.warm_thread) |t| {
                t.join();
                self.warmed = true;
            }
            self.warm_thread = null;
            self.persistIfDue();
            self.reset();
            self.root = try self.gpa.dupe(u8, root_abs);
        }
        try self.warm();
        self.last = self.pending;
        self.pending = .{};
        const warmed_reason = self.last.reason;
        const root = self.root.?;
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
                    self.watcher = change_watch.Watcher.start(self.gpa, self.io, root, self.options.watch()) catch null;
                    break :blk null;
                },
            };
        } else reason = "no_watcher";
        self.last.sync_ns = timer.lap();
        self.barrier += 1;

        const current = if (self.git_index) |g| gitStampOf(self.io, g) else null;
        const list_changed = !(if (self.git_stamp) |saved| sameGitStamp(current, saved) else false);
        var listed: ?[][]u8 = null;
        defer if (listed) |l| freeList(self.gpa, l);
        if (list_changed) {
            listed = try self.readTracked(root);
            self.git_stamp = current;
        }
        self.last.list_ns = timer.lap();
        self.last.list_reused = !list_changed;

        if (reason.len != 0) {
            self.last.mode = .full;
            try self.fullCheck(root, listed, &self.last);
            self.last.reason = reason;
        } else {
            if (warmed_reason.len == 0) self.last.mode = .dirty;
            if (dirty) |d| {
                self.last.dirty_paths = d.files.len + d.subtrees.len;
                try self.applyDirty(root, d);
            }
            if (listed) |l| try self.applyList(root, l);
            self.last.reason = warmed_reason;
        }
        try self.retryUnreadable(root);
        self.last.refresh_ns += timer.lap();
        self.last.save_failure = self.last.save_failure orelse self.save_failure;
        self.save_failure = null;
    }

    fn fullCheck(self: *Session, root: []const u8, listed: ?[]const []const u8, report: *Report) !void {
        if (listed) |l| try self.applyList(root, l);
        var paths: std.ArrayList([]const u8) = .empty;
        defer paths.deinit(self.gpa);
        try self.collectTracked(&paths);
        var timer = Timer.start(self.io);
        const seen = try self.gpa.alloc(?Seen, paths.items.len);
        defer self.gpa.free(seen);
        try stat_scan.stampAll(self.gpa, root, paths.items, seen, self.poolPtr());
        report.stamp_ns = timer.lap();
        var todo_paths: std.ArrayList([]const u8) = .empty;
        defer todo_paths.deinit(self.gpa);
        var todo_seen: std.ArrayList(?Seen) = .empty;
        defer todo_seen.deinit(self.gpa);
        for (paths.items, seen) |p, s| {
            const known = self.stampOf(p) orelse {
                try todo_paths.append(self.gpa, p);
                try todo_seen.append(self.gpa, s);
                continue;
            };
            if (s) |live| {
                if (live.kind == .file and search_index.sameStamp(known, live.stamp)) {
                    report.reused += 1;
                    continue;
                }
            } else if (self.stateOf(p) == .deleted) {
                report.reused += 1;
                continue;
            }
            try todo_paths.append(self.gpa, p);
            try todo_seen.append(self.gpa, s);
        }
        const owned = try self.gpa.alloc([]const u8, todo_paths.items.len);
        defer {
            for (owned) |o| self.gpa.free(o);
            self.gpa.free(owned);
        }
        for (todo_paths.items, owned) |p, *o| o.* = try self.gpa.dupe(u8, p);
        try self.applyPrepared(root, owned, todo_seen.items, false);
        report.recomputed = owned.len;
        report.changed = owned.len != 0;
        report.work_ns = timer.lap();
    }

    fn stampOf(self: *Session, rel: []const u8) ?Stamp {
        if (self.delta.get(rel)) |p| return p.stamp;
        const v = self.view() orelse return null;
        const id = v.find(rel) orelse return null;
        if (self.delta.isRemoved(id)) return null;
        return v.record(id).stamp();
    }

    fn stateOf(self: *Session, rel: []const u8) ?search_index.FileState {
        if (self.delta.get(rel)) |p| return p.state;
        const v = self.view() orelse return null;
        const id = v.find(rel) orelse return null;
        if (self.delta.isRemoved(id)) return null;
        return v.stateOf(id);
    }

    pub fn tracks(self: *Session, rel: []const u8) bool {
        if (self.delta.get(rel) != null) return true;
        const v = self.view() orelse return false;
        const id = v.find(rel) orelse return false;
        return !self.delta.isRemoved(id);
    }

    fn collectTracked(self: *Session, out: *std.ArrayList([]const u8)) !void {
        if (self.view()) |v| {
            var id: u32 = 0;
            while (id < v.count()) : (id += 1) {
                if (!self.delta.isRemoved(id)) try out.append(self.gpa, v.path(id));
            }
        }
        for (self.delta.entries.values()) |p| try out.append(self.gpa, p.path);
    }

    fn applyDirty(self: *Session, root: []const u8, dirty: change_watch.Dirty) !void {
        var todo: std.ArrayList([]const u8) = .empty;
        defer {
            for (todo.items) |t| self.gpa.free(t);
            todo.deinit(self.gpa);
        }
        var queued: std.StringHashMapUnmanaged(void) = .empty;
        defer queued.deinit(self.gpa);
        for (dirty.files) |rel| {
            const tracked = self.trackedName(rel) orelse continue;
            try self.queue(&todo, &queued, tracked);
        }
        for (dirty.subtrees) |sub| {
            if (self.view()) |v| {
                const range = v.dirRange(sub);
                var id = range[0];
                while (id < range[1]) : (id += 1) {
                    if (!self.delta.isRemoved(id)) try self.queue(&todo, &queued, v.path(id));
                }
            }
            for (self.delta.entries.values()) |p| {
                if (change_watch.under(sub, p.path)) try self.queue(&todo, &queued, p.path);
            }
        }
        const seen = try self.gpa.alloc(?Seen, todo.items.len);
        defer self.gpa.free(seen);
        @memset(seen, null);
        try self.applyPrepared(root, todo.items, seen, false);
        self.last.updated = todo.items.len;
    }

    fn retryUnreadable(self: *Session, root: []const u8) !void {
        var todo: std.ArrayList([]const u8) = .empty;
        defer {
            for (todo.items) |t| self.gpa.free(t);
            todo.deinit(self.gpa);
        }
        if (self.view()) |v| {
            for (try self.baseUnreadable()) |id| {
                if (!self.delta.isRemoved(id)) try todo.append(self.gpa, try self.gpa.dupe(u8, v.path(id)));
            }
        }
        for (self.delta.entries.values()) |p| {
            if (p.state == .unreadable) try todo.append(self.gpa, try self.gpa.dupe(u8, p.path));
        }
        if (todo.items.len == 0) return;
        const seen = try self.gpa.alloc(?Seen, todo.items.len);
        defer self.gpa.free(seen);
        @memset(seen, null);
        try self.applyPrepared(root, todo.items, seen, false);
        self.last.updated += todo.items.len;
    }

    fn baseUnreadable(self: *Session) ![]const u32 {
        if (self.base_unreadable) |ids| return ids;
        var ids: std.ArrayList(u32) = .empty;
        defer ids.deinit(self.gpa);
        if (self.view()) |v| {
            var id: u32 = 0;
            while (id < v.count()) : (id += 1) {
                if (v.stateOf(id) == .unreadable) try ids.append(self.gpa, id);
            }
        }
        self.base_unreadable = try ids.toOwnedSlice(self.gpa);
        return self.base_unreadable.?;
    }

    fn forgetBaseCaches(self: *Session) void {
        if (self.base_unreadable) |ids| self.gpa.free(ids);
        self.base_unreadable = null;
        if (self.base_order) |ids| self.gpa.free(ids);
        self.base_order = null;
        if (self.base_leaves) |hashes| self.gpa.free(hashes);
        self.base_leaves = null;
    }

    fn baseOrder(self: *Session) ![]const u32 {
        if (self.base_order) |ids| return ids;
        const v = self.view() orelse return &.{};
        const ids = try self.gpa.alloc(u32, v.count());
        for (ids, 0..) |*id, i| id.* = @intCast(i);
        std.mem.sort(u32, ids, v, struct {
            fn less(view_ptr: *const index_file.View, a: u32, b: u32) bool {
                return std.mem.order(u8, view_ptr.path(a), view_ptr.path(b)) == .lt;
            }
        }.less);
        self.base_order = ids;
        return ids;
    }

    fn baseLeaves(self: *Session) ![]const search_index.Digest {
        if (self.base_leaves) |hashes| return hashes;
        const v = self.view() orelse return &.{};
        const hashes = try self.gpa.alloc(search_index.Digest, v.count());
        var job: LeafJob = .{ .view = v, .out = hashes };
        if (self.poolPtr()) |p| p.run(worker_pool.max_threads, LeafJob.run, &job) else LeafJob.run(&job);
        self.base_leaves = hashes;
        return hashes;
    }

    const LeafJob = struct {
        view: *const index_file.View,
        out: []search_index.Digest,
        next: std.atomic.Value(usize) = .init(0),

        const chunk: usize = 1024;

        fn run(ctx: *anyopaque) void {
            const self: *LeafJob = @ptrCast(@alignCast(ctx));
            while (true) {
                const first = self.next.fetchAdd(chunk, .monotonic);
                if (first >= self.out.len) return;
                const last = @min(self.out.len, first + chunk);
                for (first..last) |i| {
                    const id: u32 = @intCast(i);
                    self.out[i] = answer.pathLeafHash(.{ .path = self.view.path(id), .digest = self.view.record(id).digest });
                }
            }
        }
    };

    fn publishInBackground(self: *Session) void {
        const dir = self.index_dir orelse return;
        const base = self.base orelse return;
        const image = switch (base.backing) {
            .heap => |bytes| bytes,
            .mapped => return,
        };
        self.publish_error = null;
        self.publish_thread = std.Thread.spawn(.{}, publishTask, .{ self, dir, image, base.generation }) catch null;
    }

    fn publishTask(self: *Session, dir: []const u8, image: []const u8, tag: [16]u8) void {
        index_map.publish(self.gpa, self.io, dir, image, tag) catch |err| {
            self.publish_error = err;
        };
    }

    fn joinPublish(self: *Session) void {
        const thread = self.publish_thread orelse return;
        thread.join();
        self.publish_thread = null;
        if (self.publish_error) |err| {
            self.save_failure = err;
        } else {
            self.publish_due = false;
        }
    }

    fn queue(self: *Session, todo: *std.ArrayList([]const u8), queued: *std.StringHashMapUnmanaged(void), rel: []const u8) !void {
        const copy = try self.gpa.dupe(u8, rel);
        errdefer self.gpa.free(copy);
        const got = try queued.getOrPut(self.gpa, copy);
        if (got.found_existing) {
            self.gpa.free(copy);
            return;
        }
        try todo.append(self.gpa, copy);
    }

    fn trackedName(self: *Session, rel: []const u8) ?[]const u8 {
        if (self.delta.get(rel)) |p| return p.path;
        const v = self.view() orelse return null;
        const id = v.find(rel) orelse return null;
        if (self.delta.isRemoved(id)) return null;
        return v.path(id);
    }

    fn applyList(self: *Session, root: []const u8, listed: []const []const u8) !void {
        var sorted: ?[][]const u8 = null;
        defer if (sorted) |list| self.gpa.free(list);
        const wanted: []const []const u8 = for (listed, 0..) |name, i| {
            if (i != 0 and std.mem.order(u8, listed[i - 1], name) != .lt) {
                const copy = try self.gpa.dupe([]const u8, listed);
                std.mem.sort([]const u8, copy, {}, struct {
                    fn less(_: void, a: []const u8, b: []const u8) bool {
                        return std.mem.order(u8, a, b) == .lt;
                    }
                }.less);
                sorted = copy;
                break copy;
            }
        } else listed;

        var current: std.ArrayList([]const u8) = .empty;
        defer current.deinit(self.gpa);
        var extra: std.ArrayList([]const u8) = .empty;
        defer extra.deinit(self.gpa);
        for (self.delta.entries.values()) |p| try extra.append(self.gpa, p.path);
        std.mem.sort([]const u8, extra.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);
        var e: usize = 0;
        if (self.view()) |v| {
            for (try self.baseOrder()) |id| {
                if (self.delta.isRemoved(id)) continue;
                const path = v.path(id);
                while (e < extra.items.len and std.mem.order(u8, extra.items[e], path) == .lt) : (e += 1) try current.append(self.gpa, extra.items[e]);
                try current.append(self.gpa, path);
            }
        }
        while (e < extra.items.len) : (e += 1) try current.append(self.gpa, extra.items[e]);

        var fresh: std.ArrayList([]const u8) = .empty;
        defer fresh.deinit(self.gpa);
        var gone: std.ArrayList([]u8) = .empty;
        defer {
            for (gone.items) |g| self.gpa.free(g);
            gone.deinit(self.gpa);
        }
        var i: usize = 0;
        var j: usize = 0;
        while (i < wanted.len or j < current.items.len) {
            const order: std.math.Order = if (i == wanted.len) .gt else if (j == current.items.len) .lt else std.mem.order(u8, wanted[i], current.items[j]);
            switch (order) {
                .lt => {
                    try fresh.append(self.gpa, wanted[i]);
                    i += 1;
                },
                .gt => {
                    try gone.append(self.gpa, try self.gpa.dupe(u8, current.items[j]));
                    j += 1;
                },
                .eq => {
                    i += 1;
                    j += 1;
                },
            }
        }
        for (gone.items) |g| {
            if (self.delta.get(g) != null) {
                try self.delta.drop(self.gpa, g);
            } else if (self.view()) |v| {
                if (v.find(g)) |id| try self.delta.markRemoved(self.gpa, id, v.count(), v.path(id));
            }
        }
        const seen = try self.gpa.alloc(?Seen, fresh.items.len);
        defer self.gpa.free(seen);
        @memset(seen, null);
        try self.applyPrepared(root, fresh.items, seen, false);
        self.last.recomputed += fresh.items.len;
    }

    pub fn persist(self: *Session) !void {
        self.joinPublish();
        if (!self.publish_due and self.delta.entries.count() == 0 and self.delta.removed.count() == 0) return;
        const dir = self.index_dir orelse return error.NoIndexDir;
        const base = self.base orelse return;
        const merged = self.delta.entries.count() != 0 or self.delta.removed.count() != 0;
        if (!merged) {
            switch (base.backing) {
                .heap => |image| try self.publishImage(dir, image, base.generation),
                .mapped => {},
            }
            self.publish_due = false;
            return;
        }
        const image = try self.mergedImage();
        errdefer self.gpa.free(image);
        const tag = index_map.newTag(self.io);
        try self.publishImage(dir, image, tag);
        self.gpa.free(image);
        self.publish_due = false;
    }

    fn publishImage(self: *Session, dir: []const u8, image: []const u8, tag: [16]u8) !void {
        try index_map.publish(self.gpa, self.io, dir, image, tag);
        switch (index_map.open(self.gpa, self.io, dir)) {
            .image => |mapped| {
                if (self.base) |b| b.deinit(self.gpa);
                self.base = mapped;
                self.delta.deinit(self.gpa);
                self.clearRoots();
                self.forgetBaseCaches();
            },
            .failed => return error.PublishedIndexUnreadable,
        }
    }

    fn mergedImage(self: *Session) ![]align(index_file.alignment) u8 {
        const v = &self.base.?.view;
        var inputs: std.ArrayList(index_file.Input) = .empty;
        defer inputs.deinit(self.gpa);
        var blobs: std.ArrayList([]u8) = .empty;
        defer {
            for (blobs.items) |b| self.gpa.free(b);
            blobs.deinit(self.gpa);
        }
        const extra = try self.gpa.alloc(*const Prepared, self.delta.entries.count());
        defer self.gpa.free(extra);
        for (self.delta.entries.values(), extra) |*p, *e| e.* = p;
        std.mem.sort(*const Prepared, extra, {}, struct {
            fn less(_: void, a: *const Prepared, b: *const Prepared) bool {
                return index_file.foldedOrder(a.path, b.path) == .lt;
            }
        }.less);
        var id: u32 = 0;
        var e: usize = 0;
        while (id < v.count() or e < extra.len) {
            const take_base = id < v.count() and (e == extra.len or index_file.foldedOrder(v.path(id), extra[e].path) == .lt);
            if (take_base) {
                if (!self.delta.isRemoved(id)) {
                    const rec = v.record(id);
                    try inputs.append(self.gpa, .{ .path = v.path(id), .stamp = rec.stamp(), .state = v.stateOf(id), .content = v.contentOf(id), .digest = rec.digest, .spans = v.spansOf(id) });
                }
                id += 1;
            } else {
                var input = extra[e].input();
                if (input.state == .indexed and input.spans.len == 0) {
                    try blobs.ensureUnusedCapacity(self.gpa, 1);
                    const blob = try search_index.spanBlob(self.gpa, input.path, input.content);
                    blobs.appendAssumeCapacity(blob);
                    input.spans = blob;
                }
                try inputs.append(self.gpa, input);
                e += 1;
            }
        }
        const written_ns: i64 = @intCast(std.Io.Clock.real.now(self.io).nanoseconds);
        return index_file.build(self.gpa, inputs.items, .{ .written_ns = written_ns, .git_stamp = self.git_stamp }, self.poolPtr());
    }
};

fn freeList(gpa: Allocator, names: [][]u8) void {
    for (names) |n| gpa.free(n);
    gpa.free(names);
}

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

fn gitStampOf(io: std.Io, abs: []const u8) ?GitStamp {
    const stat = std.Io.Dir.cwd().statFile(io, abs, .{}) catch return null;
    return .{ .mtime_ns = stat.mtime.nanoseconds, .size = stat.size, .id = @intCast(stat.inode) };
}

fn sameGitStamp(current: ?GitStamp, saved: GitStamp) bool {
    const c = current orelse return false;
    if (c.id == 0 or saved.id == 0) return false;
    return c.mtime_ns == saved.mtime_ns and c.size == saved.size and c.id == saved.id;
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
