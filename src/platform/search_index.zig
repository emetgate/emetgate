const std = @import("std");
const windows = std.os.windows;
const sandbox = @import("sandbox.zig");
const shadow_root = @import("shadow_root.zig");
const disk = @import("disk.zig");
const symbol = @import("../engine/symbol.zig");
const ts = @import("../engine/tree_sitter.zig");
const registry = @import("../engine/lang/registry.zig");
pub const kind_spans = @import("../engine/kind_spans.zig");
pub const doc_spans = @import("../engine/doc_spans.zig");
const index_file = @import("search_index_file.zig");
const worker_pool = @import("worker_pool.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const WidePath = [std.fs.max_path_bytes:0]u16;

pub const max_indexed_file_bytes: usize = 1 * 1024 * 1024;
const max_index_file_bytes: u64 = 4 * 1024 * 1024 * 1024;

pub const racy_window_ns: i96 = 3 * std.time.ns_per_s;

pub const Stamp = index_file.Stamp;
pub const GitStamp = index_file.GitStamp;

pub const Entry = struct {
    path: []const u8,
    stamp: Stamp,
    trigrams: []const u24,
    content_hash: ?symbol.Hash = null,
    spans: ?kind_spans.FileSpans = null,
    doc: ?doc_spans.DocSpans = null,
};

fn dupeSpans(a: Allocator, spans: ?kind_spans.FileSpans) !?kind_spans.FileSpans {
    const s = spans orelse return null;
    const symbols = try a.alloc(kind_spans.SymbolSpan, s.symbols.len);
    for (s.symbols, 0..) |sym, i| {
        symbols[i] = .{
            .ref_text = try a.dupe(u8, sym.ref_text),
            .name = try a.dupe(u8, sym.name),
            .hash = sym.hash,
            .node_start = sym.node_start,
            .body_start = sym.body_start,
            .node_end = sym.node_end,
        };
    }
    return .{
        .symbols = symbols,
        .kind_spans = try a.dupe(kind_spans.KindSpan, s.kind_spans),
        .reference_spans = try a.dupe(kind_spans.Span, s.reference_spans),
    };
}

fn spansFor(a: Allocator, rel: []const u8, bytes: []const u8) ?kind_spans.FileSpans {
    const profile = registry.forPath(rel) orelse return null;
    var parser = ts.Parser.init(profile.grammar()) catch return null;
    defer parser.deinit();
    const tree = parser.parse(bytes) catch return null;
    defer tree.deinit();
    if (tree.root().hasError()) return null;
    var table = symbol.Table.build(a, profile, tree) catch return null;
    defer table.deinit();
    return kind_spans.build(a, profile, tree, &table) catch null;
}

pub const Index = struct {
    arena: *std.heap.ArenaAllocator,
    entries: []Entry,
    written_ns: ?i96 = null,
    lookup: std.StringHashMapUnmanaged(u32) = .empty,
    files: []const []const u8 = &.{},
    git_stamp: ?GitStamp = null,

    fn finish(arena: *std.heap.ArenaAllocator, entries: []Entry, written_ns: ?i96) !Index {
        var lookup: std.StringHashMapUnmanaged(u32) = .empty;
        try lookup.ensureTotalCapacity(arena.allocator(), @intCast(entries.len));
        for (entries, 0..) |entry, i| lookup.putAssumeCapacity(entry.path, @intCast(i));
        return .{ .arena = arena, .entries = entries, .written_ns = written_ns, .lookup = lookup };
    }

    pub fn deinit(self: Index) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self.arena);
    }

    pub fn find(self: Index, path: []const u8) ?*const Entry {
        if (self.lookup.count() != 0 or self.entries.len == 0) {
            const at = self.lookup.get(path) orelse return null;
            return &self.entries[at];
        }
        for (self.entries) |*entry| {
            if (std.mem.eql(u8, entry.path, path)) return entry;
        }
        return null;
    }

    fn isRacy(self: Index, stamp: Stamp) bool {
        const written = self.written_ns orelse return false;
        const delta = stamp.mtime_ns - written;
        return delta > -racy_window_ns and delta < racy_window_ns;
    }
};

pub fn indexPath(gpa: Allocator, root_abs: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const local = (try sandbox.environmentValue(arena_state.allocator(), std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA"))) orelse return error.LocalAppDataUnavailable;
    const key = shadow_root.repoKey(root_abs);
    return std.fmt.allocPrint(gpa, "{s}\\emetgate\\index\\{s}\\index.v3", .{ local, &key });
}

fn statOf(io: std.Io, abs_path: []const u8) ?Stamp {
    const stat = Dir.cwd().statFile(io, abs_path, .{}) catch return null;
    return .{ .mtime_ns = stat.mtime.nanoseconds, .size = stat.size };
}

fn looksBinary(bytes: []const u8) bool {
    return std.mem.indexOfScalar(u8, bytes, 0) != null;
}

pub fn trigramsOfAlloc(gpa: Allocator, text: []const u8) ![]u24 {
    var set: std.AutoArrayHashMapUnmanaged(u24, void) = .empty;
    defer set.deinit(gpa);
    if (text.len >= 3) {
        var i: usize = 0;
        while (i + 3 <= text.len) : (i += 1) {
            const t: u24 = (@as(u24, text[i]) << 16) | (@as(u24, text[i + 1]) << 8) | text[i + 2];
            try set.put(gpa, t, {});
        }
    }
    const owned = try gpa.dupe(u24, set.keys());
    std.mem.sort(u24, owned, {}, std.sort.asc(u24));
    return owned;
}

pub fn isSupersetSorted(haystack: []const u24, needles: []const u24) bool {
    var hi: usize = 0;
    for (needles) |needle| {
        while (hi < haystack.len and haystack[hi] < needle) hi += 1;
        if (hi >= haystack.len or haystack[hi] != needle) return false;
    }
    return true;
}

pub fn build(gpa: Allocator, io: std.Io, root_abs: []const u8, files: []const []const u8) !Index {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var entries: std.ArrayList(Entry) = .empty;
    for (files) |rel| {
        const abs = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ root_abs, rel });
        defer gpa.free(abs);
        const stamp = statOf(io, abs) orelse continue;
        if (stamp.size > max_indexed_file_bytes) continue;
        const bytes = Dir.cwd().readFileAlloc(io, abs, gpa, .limited(max_indexed_file_bytes)) catch continue;
        defer gpa.free(bytes);
        if (looksBinary(bytes)) continue;
        const trigrams = try trigramsOfAlloc(gpa, bytes);
        defer gpa.free(trigrams);
        try entries.append(a, .{
            .path = try a.dupe(u8, rel),
            .stamp = stamp,
            .trigrams = try a.dupe(u24, trigrams),
            .content_hash = symbol.fileHash(bytes),
            .spans = spansFor(a, rel, bytes),
            .doc = doc_spans.build(a, rel, bytes),
        });
    }
    return Index.finish(arena, try entries.toOwnedSlice(a), null);
}

pub const UpdateError = error{ NeedsFullRefresh, OutOfMemory };

pub fn updateEntry(gpa: Allocator, io: std.Io, index: *Index, root_abs: []const u8, rel: []const u8) UpdateError!void {
    const slot = index.lookup.get(rel);
    const abs = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ root_abs, rel });
    defer gpa.free(abs);
    const stamp = statOf(io, abs) orelse {
        _ = index.lookup.remove(rel);
        return;
    };
    if (stamp.size > max_indexed_file_bytes) {
        _ = index.lookup.remove(rel);
        return;
    }
    const bytes = Dir.cwd().readFileAlloc(io, abs, gpa, .limited(max_indexed_file_bytes)) catch {
        _ = index.lookup.remove(rel);
        return;
    };
    defer gpa.free(bytes);
    if (looksBinary(bytes)) {
        _ = index.lookup.remove(rel);
        return;
    }
    const at = slot orelse return error.NeedsFullRefresh;
    const a = index.arena.allocator();
    const trigrams = try trigramsOfAlloc(gpa, bytes);
    defer gpa.free(trigrams);
    index.entries[at] = .{
        .path = index.entries[at].path,
        .stamp = stamp,
        .trigrams = try a.dupe(u24, trigrams),
        .content_hash = symbol.fileHash(bytes),
        .spans = spansFor(a, rel, bytes),
        .doc = doc_spans.build(a, rel, bytes),
    };
}

pub const RefreshResult = struct {
    index: Index,
    changed: bool,
    reused: usize,
    recomputed: usize,
    stamp_ns: u64 = 0,
    work_ns: u64 = 0,
};

pub fn refresh(gpa: Allocator, io: std.Io, root_abs: []const u8, files: []const []const u8, previous: ?Index) !RefreshResult {
    return refreshWith(gpa, io, root_abs, files, previous, null);
}

pub fn refreshInPlace(gpa: Allocator, io: std.Io, root_abs: []const u8, files: []const []const u8, index: *Index, pool: ?*worker_pool.Pool) !?RefreshResult {
    return reconcile(gpa, io, root_abs, files, index, pool, true);
}

pub fn addMissing(gpa: Allocator, io: std.Io, root_abs: []const u8, files: []const []const u8, index: *Index, pool: ?*worker_pool.Pool) !RefreshResult {
    var missing: std.ArrayList([]const u8) = .empty;
    defer missing.deinit(gpa);
    for (files) |rel| {
        if (index.lookup.get(rel) == null) try missing.append(gpa, rel);
    }
    if (missing.items.len == 0) return .{ .index = index.*, .changed = false, .reused = 0, .recomputed = 0 };
    return (try reconcile(gpa, io, root_abs, missing.items, index, pool, false)).?;
}

fn reconcile(gpa: Allocator, io: std.Io, root_abs: []const u8, files: []const []const u8, index: *Index, pool: ?*worker_pool.Pool, prune: bool) !?RefreshResult {
    const slots = try gpa.alloc(Pending, files.len);
    defer gpa.free(slots);
    for (slots, files) |*slot, rel| slot.* = .{ .rel = rel };
    const t0 = std.Io.Clock.awake.now(io).nanoseconds;
    try prefillStamps(gpa, root_abs, slots, pool);
    const t1 = std.Io.Clock.awake.now(io).nanoseconds;

    const count = workerCount(files.len);
    const workers = try gpa.alloc(Worker, count);
    defer gpa.free(workers);
    var job: Job = .{ .gpa = gpa, .io = io, .root = root_abs, .previous = index.*, .slots = slots, .workers = workers };
    for (workers) |*w| w.* = .{ .job = &job, .arena = .init(gpa) };
    defer for (workers) |*w| w.arena.deinit();
    if (pool) |p| p.run(count - 1, Job.runOne, &job) else Job.runOne(&job);
    if (job.failure) |err| return err;
    const t2 = std.Io.Clock.awake.now(io).nanoseconds;

    const a = index.arena.allocator();
    var reused: usize = 0;
    var recomputed: usize = 0;
    var removed: usize = 0;
    var added: std.ArrayList(Entry) = .empty;
    defer added.deinit(gpa);
    for (slots) |slot| {
        const at = index.lookup.get(slot.rel);
        switch (slot.state) {
            .reuse => reused += 1,
            .skip => if (at != null) {
                _ = index.lookup.remove(slot.rel);
                removed += 1;
            },
            .fresh => {
                recomputed += 1;
                const e = slot.fresh;
                const entry: Entry = .{
                    .path = if (at) |i| index.entries[i].path else try a.dupe(u8, slot.rel),
                    .stamp = slot.stamp,
                    .trigrams = try a.dupe(u24, e.trigrams),
                    .content_hash = e.content_hash,
                    .spans = try dupeSpans(a, e.spans),
                    .doc = try doc_spans.dupe(a, e.doc),
                };
                if (at) |i| index.entries[i] = entry else try added.append(gpa, entry);
            },
        }
    }
    if (added.items.len != 0) {
        const grown = try a.alloc(Entry, index.entries.len + added.items.len);
        @memcpy(grown[0..index.entries.len], index.entries);
        @memcpy(grown[index.entries.len..], added.items);
        for (grown[index.entries.len..], index.entries.len..) |e, i| try index.lookup.put(a, e.path, @intCast(i));
        index.entries = grown;
    }
    if (prune and index.lookup.count() > files.len) {
        var tracked: std.StringHashMapUnmanaged(void) = .empty;
        defer tracked.deinit(gpa);
        for (files) |rel| try tracked.put(gpa, rel, {});
        for (index.entries) |e| {
            if (!tracked.contains(e.path)) {
                if (index.lookup.remove(e.path)) removed += 1;
            }
        }
    }
    return .{ .index = index.*, .changed = recomputed != 0 or removed != 0 or added.items.len != 0, .reused = reused, .recomputed = recomputed, .stamp_ns = @intCast(t1 - t0), .work_ns = @intCast(t2 - t1) };
}

pub fn refreshWith(gpa: Allocator, io: std.Io, root_abs: []const u8, files: []const []const u8, previous: ?Index, pool: ?*worker_pool.Pool) !RefreshResult {
    const slots = try gpa.alloc(Pending, files.len);
    defer gpa.free(slots);
    for (slots, files) |*slot, rel| slot.* = .{ .rel = rel };
    if (previous != null) try prefillStamps(gpa, root_abs, slots, pool);

    const count = workerCount(files.len);
    const workers = try gpa.alloc(Worker, count);
    defer gpa.free(workers);
    var job: Job = .{ .gpa = gpa, .io = io, .root = root_abs, .previous = previous, .slots = slots, .workers = workers };
    for (workers) |*w| w.* = .{ .job = &job, .arena = .init(gpa) };
    defer for (workers) |*w| w.arena.deinit();
    if (pool) |p| {
        p.run(count - 1, Job.runOne, &job);
    } else {
        var threads: [max_workers]std.Thread = undefined;
        var spawned: usize = 0;
        defer for (threads[0..spawned]) |t| t.join();
        while (spawned + 1 < count) : (spawned += 1) {
            threads[spawned] = std.Thread.spawn(.{}, Job.runOne, .{@as(*anyopaque, &job)}) catch break;
        }
        Job.runOne(&job);
    }
    if (job.failure) |err| return err;

    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var entries: std.ArrayList(Entry) = .empty;
    var reused: usize = 0;
    var recomputed: usize = 0;
    for (slots) |slot| {
        const source = switch (slot.state) {
            .skip => continue,
            .reuse => blk: {
                reused += 1;
                break :blk slot.reuse.?.*;
            },
            .fresh => blk: {
                recomputed += 1;
                break :blk slot.fresh;
            },
        };
        try entries.append(a, .{
            .path = try a.dupe(u8, slot.rel),
            .stamp = slot.stamp,
            .trigrams = try a.dupe(u24, source.trigrams),
            .content_hash = source.content_hash,
            .spans = try dupeSpans(a, source.spans),
            .doc = try doc_spans.dupe(a, source.doc),
        });
    }
    const changed = recomputed != 0 or entries.items.len != if (previous) |p| p.entries.len else 0;
    return .{
        .index = try Index.finish(arena, try entries.toOwnedSlice(a), null),
        .changed = changed,
        .reused = reused,
        .recomputed = recomputed,
    };
}

pub const max_workers = 8;
const min_files_per_worker = 16;

fn workerCount(files: usize) usize {
    if (files <= min_files_per_worker) return 1;
    const cpus = std.Thread.getCpuCount() catch 1;
    return @max(1, @min(@min(cpus, max_workers), files / min_files_per_worker));
}

const DirGroup = struct {
    dir: []const u8,
    slots: std.ArrayList(u32) = .empty,
};

const StampJob = struct {
    gpa: Allocator,
    root: []const u8,
    slots: []Pending,
    groups: []DirGroup,
    next: std.atomic.Value(usize) = .init(0),

    fn run(ctx: *anyopaque) void {
        const self: *StampJob = @ptrCast(@alignCast(ctx));
        while (true) {
            const i = self.next.fetchAdd(1, .monotonic);
            if (i >= self.groups.len) return;
            self.enumerate(&self.groups[i]) catch continue;
        }
    }

    fn enumerate(self: *StampJob, group: *DirGroup) !void {
        var names: std.StringHashMapUnmanaged(u32) = .empty;
        defer names.deinit(self.gpa);
        for (group.slots.items) |at| try names.put(self.gpa, std.fs.path.basenamePosix(self.slots[at].rel), at);
        var pattern_buf: [std.fs.max_path_bytes]u8 = undefined;
        const pattern = if (group.dir.len == 0)
            try std.fmt.bufPrint(&pattern_buf, "{s}\\*", .{self.root})
        else
            try std.fmt.bufPrint(&pattern_buf, "{s}\\{s}\\*", .{ self.root, group.dir });
        std.mem.replaceScalar(u8, pattern, '/', '\\');
        var wide: WidePath = undefined;
        const w = try toWide(&wide, pattern);
        var data: win.FindData = undefined;
        const handle = win.FindFirstFileExW(w, win.find_ex_info_basic, &data, 0, null, win.find_first_ex_large_fetch);
        if (handle == windows.INVALID_HANDLE_VALUE) return;
        defer _ = win.FindClose(handle);
        var name_buf: [1024]u8 = undefined;
        while (true) {
            const skip = data.attributes & (win.file_attribute_directory | win.file_attribute_reparse_point) != 0;
            if (!skip) {
                const len = std.mem.indexOfScalar(u16, &data.name, 0) orelse data.name.len;
                const n = std.unicode.wtf16LeToWtf8(&name_buf, data.name[0..len]);
                if (names.get(name_buf[0..n])) |at| {
                    const slot = &self.slots[at];
                    const hns: i64 = @bitCast((@as(u64, data.last_write.high) << 32) | data.last_write.low);
                    slot.stamp = .{ .mtime_ns = windows.fromSysTime(hns).nanoseconds, .size = (@as(u64, data.size_high) << 32) | data.size_low };
                    slot.prestat = true;
                }
            }
            if (win.FindNextFileW(handle, &data) == .FALSE) return;
        }
    }
};

fn prefillStamps(gpa: Allocator, root_abs: []const u8, slots: []Pending, pool: ?*worker_pool.Pool) !void {
    var by_dir: std.StringArrayHashMapUnmanaged(DirGroup) = .empty;
    defer {
        for (by_dir.values()) |*g| g.slots.deinit(gpa);
        by_dir.deinit(gpa);
    }
    for (slots, 0..) |slot, i| {
        const dir = std.fs.path.dirnamePosix(slot.rel) orelse "";
        const got = try by_dir.getOrPut(gpa, dir);
        if (!got.found_existing) got.value_ptr.* = .{ .dir = dir };
        try got.value_ptr.slots.append(gpa, @intCast(i));
    }
    var job: StampJob = .{ .gpa = gpa, .root = root_abs, .slots = slots, .groups = by_dir.values() };
    if (pool) |p| p.run(workerCount(slots.len) - 1, StampJob.run, &job) else StampJob.run(&job);
}

const Pending = struct {
    rel: []const u8,
    state: enum { skip, reuse, fresh } = .skip,
    prestat: bool = false,
    stamp: Stamp = .{ .mtime_ns = 0, .size = 0 },
    reuse: ?*const Entry = null,
    fresh: Entry = undefined,
};

const Job = struct {
    gpa: Allocator,
    io: std.Io,
    root: []const u8,
    previous: ?Index,
    slots: []Pending,
    workers: []Worker,
    next: std.atomic.Value(usize) = .init(0),
    next_worker: std.atomic.Value(usize) = .init(0),
    failure: ?anyerror = null,
    failed: std.atomic.Value(bool) = .init(false),

    fn runOne(ctx: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(ctx));
        const i = self.next_worker.fetchAdd(1, .monotonic);
        if (i >= self.workers.len) return;
        self.workers[i].run();
    }

    fn fail(self: *Job, err: anyerror) void {
        if (self.failed.swap(true, .acq_rel)) return;
        self.failure = err;
    }
};

const Worker = struct {
    job: *Job,
    arena: std.heap.ArenaAllocator,

    fn run(self: *Worker) void {
        const job = self.job;
        while (!job.failed.load(.acquire)) {
            const i = job.next.fetchAdd(1, .monotonic);
            if (i >= job.slots.len) return;
            self.fill(&job.slots[i]) catch |err| {
                job.fail(err);
                return;
            };
        }
    }

    fn fill(self: *Worker, slot: *Pending) !void {
        const job = self.job;
        const gpa = job.gpa;
        const abs = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ job.root, slot.rel });
        defer gpa.free(abs);
        const stamp = if (slot.prestat) slot.stamp else statOf(job.io, abs) orelse return;
        if (stamp.size > max_indexed_file_bytes) return;
        slot.stamp = stamp;
        if (job.previous) |p| {
            if (p.find(slot.rel)) |old| {
                if (old.stamp.mtime_ns == stamp.mtime_ns and old.stamp.size == stamp.size and !p.isRacy(stamp)) {
                    slot.reuse = old;
                    slot.state = .reuse;
                    return;
                }
            }
        }
        const bytes = Dir.cwd().readFileAlloc(job.io, abs, gpa, .limited(max_indexed_file_bytes)) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return,
        };
        defer gpa.free(bytes);
        if (looksBinary(bytes)) return;
        const a = self.arena.allocator();
        const trigrams = try trigramsOfAlloc(gpa, bytes);
        defer gpa.free(trigrams);
        slot.fresh = .{
            .path = slot.rel,
            .stamp = stamp,
            .trigrams = try a.dupe(u24, trigrams),
            .content_hash = symbol.fileHash(bytes),
            .spans = spansFor(a, slot.rel, bytes),
            .doc = doc_spans.build(a, slot.rel, bytes),
        };
        slot.state = .fresh;
    }
};

pub fn save(gpa: Allocator, io: std.Io, path: []const u8, index: Index, files: []const []const u8, git_stamp: ?GitStamp) !void {
    if (std.fs.path.dirname(path)) |dir| try Dir.cwd().createDirPath(io, dir);
    const entries = try gpa.alloc(index_file.Entry, index.lookup.count());
    defer gpa.free(entries);
    var n: usize = 0;
    for (index.entries, 0..) |e, i| {
        const at = index.lookup.get(e.path) orelse continue;
        if (at != i or n == entries.len) continue;
        entries[n] = .{ .path = e.path, .stamp = e.stamp, .trigrams = e.trigrams, .content_hash = e.content_hash, .spans = e.spans, .doc = e.doc };
        n += 1;
    }
    const written_ns = std.Io.Clock.real.now(io).nanoseconds;
    const bytes = try index_file.encode(gpa, .{ .written_ns = written_ns, .git_stamp = git_stamp, .files = files, .entries = entries[0..n] });
    defer gpa.free(bytes);

    var random: [8]u8 = undefined;
    io.random(&random);
    const tag = std.fmt.bytesToHex(random, .lower);
    const temp = try std.fmt.allocPrint(gpa, "{s}.emetgate-{s}.tmp", .{ path, &tag });
    defer gpa.free(temp);
    try disk.writeDurably(io, temp, bytes);
    moveDurablyReplacing(temp, path) catch |err| {
        _ = Dir.deleteFileAbsolute(io, temp) catch {};
        return err;
    };
}

fn moveDurablyReplacing(from: []const u8, to: []const u8) !void {
    var from_wide: WidePath = undefined;
    var to_wide: WidePath = undefined;
    const from_ptr = try toWide(&from_wide, from);
    const to_ptr = try toWide(&to_wide, to);
    if (win.MoveFileExW(from_ptr, to_ptr, win.movefile_replace_existing | win.movefile_write_through) == .FALSE) return error.RenameFailed;
}

fn toWide(buffer: *WidePath, path: []const u8) ![*:0]const u16 {
    const len = std.unicode.wtf8ToWtf16Le(buffer, path) catch return error.InvalidWtf8;
    if (len >= buffer.len) return error.NameTooLong;
    buffer[len] = 0;
    return buffer;
}

const win = struct {
    const FileTime = extern struct { low: u32, high: u32 };
    const FindData = extern struct {
        attributes: u32,
        creation: FileTime,
        last_access: FileTime,
        last_write: FileTime,
        size_high: u32,
        size_low: u32,
        reserved0: u32,
        reserved1: u32,
        name: [260]u16,
        alternate: [14]u16,
    };
    const find_ex_info_basic: c_int = 1;
    const find_first_ex_large_fetch: windows.DWORD = 2;
    const file_attribute_directory: u32 = 0x10;
    const file_attribute_reparse_point: u32 = 0x400;
    extern "kernel32" fn FindFirstFileExW(name: [*:0]const u16, level: c_int, data: *FindData, search: c_int, filter: ?*anyopaque, flags: windows.DWORD) callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn FindNextFileW(handle: windows.HANDLE, data: *FindData) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn FindClose(handle: windows.HANDLE) callconv(.winapi) windows.BOOL;
    const movefile_replace_existing: windows.DWORD = 0x00000001;
    const movefile_write_through: windows.DWORD = 0x00000008;

    extern "kernel32" fn MoveFileExW(from: [*:0]const u16, to: [*:0]const u16, flags: windows.DWORD) callconv(.winapi) windows.BOOL;
};

pub const LoadFailure = enum { missing, too_large, io, corrupt, version };

pub const Loaded = union(enum) {
    index: Index,
    failed: LoadFailure,
};

pub fn load(gpa: Allocator, io: std.Io, path: []const u8) Loaded {
    const bytes = readWhole(gpa, io, path) catch |err| return .{ .failed = switch (err) {
        error.FileNotFound => .missing,
        error.TooLarge => .too_large,
        else => .io,
    } };
    defer gpa.free(bytes);
    return parse(gpa, bytes) catch |err| .{ .failed = switch (err) {
        error.OutOfMemory => .too_large,
        error.Version => .version,
        error.Corrupt => .corrupt,
    } };
}

fn readWhole(gpa: Allocator, io: std.Io, path: []const u8) ![]u8 {
    const file = try Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const size = try file.length(io);
    if (size > max_index_file_bytes) return error.TooLarge;
    const bytes = gpa.alloc(u8, @intCast(size)) catch return error.TooLarge;
    errdefer gpa.free(bytes);
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.Truncated;
    return bytes;
}

fn parse(gpa: Allocator, bytes: []const u8) index_file.DecodeError!Loaded {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const contents = try index_file.decode(a, bytes);
    const entries = try a.alloc(Entry, contents.entries.len);
    for (contents.entries, entries) |e, *out| out.* = .{ .path = e.path, .stamp = e.stamp, .trigrams = e.trigrams, .content_hash = e.content_hash, .spans = e.spans, .doc = e.doc };
    var index = try Index.finish(arena, entries, contents.written_ns);
    index.files = contents.files;
    index.git_stamp = contents.git_stamp;
    return .{ .index = index };
}

const testing = std.testing;

test "build then save then load round-trips the same entries" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export const value = 1;\n" });
    const root_abs = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root_abs);

    const built = try build(testing.allocator, testing.io, root_abs, &.{"a.ts"});
    defer built.deinit();
    try testing.expectEqual(@as(usize, 1), built.entries.len);

    const path = try std.fmt.allocPrint(testing.allocator, "{s}\\idx", .{root_abs});
    defer testing.allocator.free(path);
    try save(testing.allocator, testing.io, path, built, &.{}, null);

    const loaded = switch (load(testing.allocator, testing.io, path)) {
        .index => |index| index,
        .failed => return error.TestUnexpectedResult,
    };
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 1), loaded.entries.len);
    try testing.expectEqualStrings("a.ts", loaded.entries[0].path);
    try testing.expectEqual(built.entries[0].stamp.size, loaded.entries[0].stamp.size);
    try testing.expectEqualSlices(u24, built.entries[0].trigrams, loaded.entries[0].trigrams);
}

test "a corrupted index file is rejected instead of trusted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export const value = 1;\n" });
    const root_abs = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root_abs);

    const built = try build(testing.allocator, testing.io, root_abs, &.{"a.ts"});
    defer built.deinit();

    const path = try std.fmt.allocPrint(testing.allocator, "{s}\\idx", .{root_abs});
    defer testing.allocator.free(path);
    try save(testing.allocator, testing.io, path, built, &.{}, null);

    const original = try tmp.dir.readFileAlloc(testing.io, "idx", testing.allocator, .unlimited);
    defer testing.allocator.free(original);
    const tampered = try testing.allocator.dupe(u8, original);
    defer testing.allocator.free(tampered);
    tampered[tampered.len / 2] = tampered[tampered.len / 2] +% 1;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "idx", .data = tampered });

    try testing.expectEqual(Loaded{ .failed = .corrupt }, load(testing.allocator, testing.io, path));
}

test "an index file larger than 64 MiB is read whole and judged by its bytes, not refused by its size" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const big = try testing.allocator.alloc(u8, 65 * 1024 * 1024);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "idx", .data = big });
    const root_abs = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root_abs);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}\\idx", .{root_abs});
    defer testing.allocator.free(path);
    try testing.expectEqual(Loaded{ .failed = .corrupt }, load(testing.allocator, testing.io, path));
    const absent = try std.fmt.allocPrint(testing.allocator, "{s}\\absent", .{root_abs});
    defer testing.allocator.free(absent);
    try testing.expectEqual(Loaded{ .failed = .missing }, load(testing.allocator, testing.io, absent));
}

test "isSupersetSorted matches a subset regardless of order in the query" {
    const haystack = [_]u24{ 1, 5, 9, 20 };
    try testing.expect(isSupersetSorted(&haystack, &.{ 5, 9 }));
    try testing.expect(!isSupersetSorted(&haystack, &.{ 5, 6 }));
    try testing.expect(isSupersetSorted(&haystack, &.{}));
}

test "trigramsOfAlloc is empty for text shorter than three bytes" {
    const empty = try trigramsOfAlloc(testing.allocator, "ab");
    defer testing.allocator.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);

    const one = try trigramsOfAlloc(testing.allocator, "abcabc");
    defer testing.allocator.free(one);
    try testing.expectEqual(@as(usize, 3), one.len);
}

test "refresh reuses unchanged entries and recomputes a file that changed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export const value = 1;\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.ts", .data = "export const other = 2;\n" });
    const root_abs = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root_abs);

    const first = try build(testing.allocator, testing.io, root_abs, &.{ "a.ts", "b.ts" });
    defer first.deinit();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export const value = 999999;\n" });

    const refreshed = try refresh(testing.allocator, testing.io, root_abs, &.{ "a.ts", "b.ts" }, first);
    const second = refreshed.index;
    defer second.deinit();
    try testing.expect(refreshed.changed);
    try testing.expectEqual(@as(usize, 1), refreshed.reused);
    try testing.expectEqual(@as(usize, 1), refreshed.recomputed);

    const a_entry = second.find("a.ts").?;
    const b_entry = second.find("b.ts").?;
    try testing.expect(!std.mem.eql(u24, a_entry.trigrams, first.find("a.ts").?.trigrams));
    try testing.expectEqualSlices(u24, first.find("b.ts").?.trigrams, b_entry.trigrams);
}

test "refresh reports unchanged when every entry is reused and no file was added or removed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export const value = 1;\n" });
    const root_abs = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root_abs);

    const first = try build(testing.allocator, testing.io, root_abs, &.{"a.ts"});
    defer first.deinit();

    const refreshed = try refresh(testing.allocator, testing.io, root_abs, &.{"a.ts"}, first);
    defer refreshed.index.deinit();
    try testing.expect(!refreshed.changed);
    try testing.expectEqual(@as(usize, 1), refreshed.reused);
    try testing.expectEqual(@as(usize, 0), refreshed.recomputed);
}

test "a racy mtime collision around the index write time forces a recompute instead of trusting the stale gram set" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export const value = 1;\n" });
    const root_abs = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root_abs);
    const abs = try std.fmt.allocPrint(testing.allocator, "{s}\\a.ts", .{root_abs});
    defer testing.allocator.free(abs);

    const stale_trigrams = try trigramsOfAlloc(testing.allocator, "export const value = 1;\n");
    defer testing.allocator.free(stale_trigrams);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export const zzzneedle = 2;\n" });
    const current_stamp = statOf(testing.io, abs).?;

    var fake_arena = std.heap.ArenaAllocator.init(testing.allocator);
    var fake_entries = [_]Entry{.{
        .path = "a.ts",
        .stamp = current_stamp,
        .trigrams = stale_trigrams,
    }};
    const fake_previous = Index{
        .arena = &fake_arena,
        .entries = fake_entries[0..],
        .written_ns = current_stamp.mtime_ns,
    };
    defer fake_arena.deinit();

    const refreshed = try refresh(testing.allocator, testing.io, root_abs, &.{"a.ts"}, fake_previous);
    defer refreshed.index.deinit();

    const fresh_trigrams = try trigramsOfAlloc(testing.allocator, "export const zzzneedle = 2;\n");
    defer testing.allocator.free(fresh_trigrams);
    try testing.expectEqualSlices(u24, fresh_trigrams, refreshed.index.find("a.ts").?.trigrams);
    try testing.expect(refreshed.changed);
}
