const std = @import("std");
const ts = @import("../engine/tree_sitter.zig");
const symbol = @import("../engine/symbol.zig");
const facts = @import("../engine/facts.zig");
const facts_extract = @import("../engine/facts_extract.zig");
const facts_store = @import("../engine/facts_store.zig");
const facts_query = @import("../engine/facts_query.zig");
const facts_evidence = @import("../engine/facts_evidence.zig");
const answer = @import("../engine/answer.zig");
const facts_merkle = @import("../engine/facts_merkle.zig");
const evidence_api = @import("../engine/evidence.zig");
const registry = @import("../engine/lang/registry.zig");
const Profile = @import("../engine/lang/profile.zig").Profile;
const Snapshot = @import("../engine/loader.zig").Snapshot;
const Runtime = @import("../engine/runtime.zig").Runtime;
const worker_pool = @import("worker_pool.zig");
const io_seam = @import("io_seam.zig");
const fact_modules = @import("fact_modules.zig");
const fact_file = @import("fact_file.zig");
const shadow_root = @import("shadow_root.zig");
const sandbox = @import("sandbox.zig");

const Allocator = std.mem.Allocator;
const Store = facts_store.Store;
const FileId = facts_store.FileId;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Digest = [Sha256.digest_length]u8;

pub const default_max_file_bytes = 4 * 1024 * 1024;
pub const racy_window_ns: i96 = 2 * std.time.ns_per_s;

pub const unindexed_code = [_][]const u8{ ".vue", ".svelte", ".astro", ".mts", ".cts" };

pub const Stamp = struct {
    mtime_ns: i96 = 0,
    size: u64 = 0,
};

pub const Meta = struct {
    stamp: Stamp = .{},
    digest: Digest = std.mem.zeroes(Digest),
};

pub const Load = union(enum) {
    absent,
    loaded,
    rebuilt: []const u8,
};

pub const Report = struct {
    listed: usize = 0,
    in_scope: usize = 0,
    extracted: usize = 0,
    reused: usize = 0,
    rehashed: usize = 0,
    removed: usize = 0,
    relinked: usize = 0,
    full_link: bool = false,
    saved: bool = false,
    load: Load = .absent,
    stat_failures: usize = 0,
    config_notes: usize = 0,
    load_ms: u64 = 0,
    list_ms: u64 = 0,
    stat_ms: u64 = 0,
    extract_ms: u64 = 0,
    link_ms: u64 = 0,
    save_ms: u64 = 0,
    store_bytes: usize = 0,
    read_cpu_ms: u64 = 0,
    parse_cpu_ms: u64 = 0,
    extract_cpu_ms: u64 = 0,
    clone_cpu_ms: u64 = 0,
};

pub const Options = struct {
    root_abs: []const u8,
    store_path: ?[]const u8 = null,
    threads: usize = worker_pool.max_threads,
    max_file_bytes: usize = default_max_file_bytes,
};

pub fn defaultStorePath(gpa: Allocator, root_abs: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const local = (try sandbox.environmentValue(arena_state.allocator(), std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA"))) orelse return error.LocalAppDataUnavailable;
    const key = shadow_root.repoKey(root_abs);
    return std.fmt.allocPrint(gpa, "{s}\\emetgate\\facts\\{s}\\facts.v{d}", .{ local, &key, fact_file.version });
}

fn hasUnindexedExtension(path: []const u8) bool {
    for (unindexed_code) |ext| {
        if (std.ascii.endsWithIgnoreCase(path, ext)) return true;
    }
    return false;
}

pub fn inScope(path: []const u8) bool {
    if (std.mem.indexOf(u8, path, "node_modules/") != null) return false;
    if (registry.forPath(path)) |profile| {
        if (facts_extract.supports(profile)) return true;
    }
    return hasUnindexedExtension(path);
}

fn elapsedMs(clock: io_seam.Clock, from: i96) u64 {
    const ns = clock.monotonic() - from;
    return @intCast(@divTrunc(@max(ns, 0), std.time.ns_per_ms));
}

pub fn tokensOf(arena: Allocator, bytes: []const u8) ![]const []const u8 {
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    var i: usize = 0;
    while (i < bytes.len) {
        const c = bytes[i];
        if (!(std.ascii.isAlphabetic(c) or c == '_' or c == '$')) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < bytes.len and (std.ascii.isAlphanumeric(bytes[i]) or bytes[i] == '_' or bytes[i] == '$')) i += 1;
        const entry = try seen.getOrPut(arena, bytes[start..i]);
        if (!entry.found_existing) entry.key_ptr.* = try arena.dupe(u8, bytes[start..i]);
    }
    return seen.keys();
}

const Outcome = union(enum) {
    pending,
    same,
    indexed: struct { profile: *const Profile, arena: *std.heap.ArenaAllocator, found: facts.FileFacts, hash: facts.Hash, tokens: []const []const u8 },
    unindexed: struct { arena: *std.heap.ArenaAllocator, tokens: []const []const u8, hash: facts.Hash },
    failed: struct { status: facts_store.Status, note: []const u8 },
};

const Phase = enum { read, parse, extract, clone };

const Job = struct {
    gpa: Allocator,
    clock: io_seam.Clock,
    fs: io_seam.Fs,
    runtime: *Runtime,
    root_abs: []const u8,
    max_file_bytes: usize,
    paths: []const []const u8,
    previous: []const ?facts.Hash,
    outcomes: []Outcome,
    metas: []Meta,
    next: std.atomic.Value(usize) = .init(0),
    failure: std.atomic.Value(u16) = .init(0),
    phase_ns: [4]std.atomic.Value(u64) = @splat(.init(0)),

    fn spent(self: *Job, phase: Phase, from: i96) i96 {
        const now = self.clock.monotonic();
        _ = self.phase_ns[@intFromEnum(phase)].fetchAdd(@intCast(@max(now - from, 0)), .monotonic);
        return now;
    }

    fn phaseMs(self: *const Job, phase: Phase) u64 {
        return self.phase_ns[@intFromEnum(phase)].load(.monotonic) / std.time.ns_per_ms;
    }

    fn run(ctx: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(ctx));
        var parser: ?ts.Parser = null;
        defer if (parser) |p| p.deinit();
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        while (true) {
            const i = self.next.fetchAdd(1, .monotonic);
            if (i >= self.paths.len) return;
            self.one(i, &parser, &scratch) catch |err| {
                _ = self.failure.cmpxchgStrong(0, @intFromError(err), .acq_rel, .monotonic);
                self.next.store(self.paths.len, .monotonic);
                return;
            };
            _ = scratch.reset(.retain_capacity);
        }
    }

    fn failed(self: *const Job) ?anyerror {
        const code = self.failure.load(.acquire);
        if (code == 0) return null;
        return @errorFromInt(code);
    }

    fn one(self: *Job, i: usize, parser: *?ts.Parser, scratch: *std.heap.ArenaAllocator) !void {
        const rel = self.paths[i];
        var mark = self.clock.monotonic();
        const abs = try std.fmt.allocPrint(scratch.allocator(), "{s}\\{s}", .{ self.root_abs, rel });
        const bytes = self.fs.readFile(abs, self.gpa, self.max_file_bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TooLarge => {
                self.outcomes[i] = .{ .failed = .{ .status = .too_large, .note = "too_large" } };
                return;
            },
            else => {
                self.outcomes[i] = .{ .failed = .{ .status = .unreadable, .note = @errorName(err) } };
                return;
            },
        };
        defer self.gpa.free(bytes);
        Sha256.hash(bytes, &self.metas[i].digest, .{});
        const hash = symbol.fileHash(bytes);
        mark = self.spent(.read, mark);
        if (self.previous[i]) |known| {
            if (std.mem.eql(u8, &known, &hash)) {
                self.outcomes[i] = .same;
                return;
            }
        }
        const arena = try self.gpa.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(self.gpa);
        errdefer {
            arena.deinit();
            self.gpa.destroy(arena);
        }
        const profile = registry.forPath(rel) orelse return self.unindexed(i, arena, bytes, hash);
        if (!facts_extract.supports(profile)) return self.unindexed(i, arena, bytes, hash);
        if (parser.* == null) parser.* = ts.Parser.create();
        const tree = try parser.*.?.parseIn(profile.grammar(), bytes);
        defer tree.deinit();
        mark = self.spent(.parse, mark);
        const snapshot: Snapshot = .{ .runtime = self.runtime, .profile = profile, .source = bytes, .tree = tree };
        const found = try facts_extract.extract(scratch.allocator(), &snapshot);
        mark = self.spent(.extract, mark);
        const tokens: []const []const u8 = if (found.parse_errors) try tokensOf(arena.allocator(), bytes) else &.{};
        self.outcomes[i] = .{ .indexed = .{ .profile = profile, .arena = arena, .found = try facts.clone(arena.allocator(), found), .hash = hash, .tokens = tokens } };
        _ = self.spent(.clone, mark);
    }

    fn unindexed(self: *Job, i: usize, arena: *std.heap.ArenaAllocator, bytes: []const u8, hash: facts.Hash) !void {
        self.outcomes[i] = .{ .unindexed = .{ .arena = arena, .tokens = try tokensOf(arena.allocator(), bytes), .hash = hash } };
    }
};

const NameMap = std.HashMapUnmanaged([]const u8, usize, fact_modules.FoldedPath, std.hash_map.default_max_load_percentage);

const DirGroup = struct {
    dir: []const u8,
    names: NameMap = .empty,
};

const StampJob = struct {
    root_abs: []const u8,
    fs: io_seam.Fs,
    stamps: []?Stamp,
    groups: []DirGroup,
    next: std.atomic.Value(usize) = .init(0),
    failures: std.atomic.Value(usize) = .init(0),

    const Visit = struct {
        job: *StampJob,
        group: *const DirGroup,

        fn visit(context: *anyopaque, entry: io_seam.Entry) void {
            const self: *Visit = @ptrCast(@alignCast(context));
            if (entry.kind != .file) return;
            const i = self.group.names.get(entry.name) orelse return;
            self.job.stamps[i] = .{ .mtime_ns = entry.mtime_ns, .size = entry.size };
        }
    };

    fn run(ctx: *anyopaque) void {
        const self: *StampJob = @ptrCast(@alignCast(ctx));
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        while (true) {
            const g = self.next.fetchAdd(1, .monotonic);
            if (g >= self.groups.len) return;
            const group = &self.groups[g];
            const dir = (if (group.dir.len == 0)
                std.fmt.bufPrint(&buf, "{s}", .{self.root_abs})
            else
                std.fmt.bufPrint(&buf, "{s}\\{s}", .{ self.root_abs, group.dir })) catch {
                _ = self.failures.fetchAdd(1, .monotonic);
                continue;
            };
            var visit: Visit = .{ .job = self, .group = group };
            self.fs.list(dir, .{ .context = &visit, .visit = Visit.visit }) catch {
                _ = self.failures.fetchAdd(1, .monotonic);
                continue;
            };
        }
    }
};

pub const Repo = struct {
    gpa: Allocator,
    seam: io_seam.Seam,
    fs: io_seam.Fs,
    runtime: *Runtime,
    options: Options,
    store: Store,
    metas: std.ArrayList(Meta) = .empty,
    workspace: ?fact_modules.Workspace = null,
    config_signature: [16]u8 = std.mem.zeroes([16]u8),
    linked: bool = false,
    barrier: u64 = 0,
    written_ns: i96 = 0,
    pool: worker_pool.Pool = .{},
    load: Load = .absent,
    load_ms: u64 = 0,
    root_digest: answer.Digest = std.mem.zeroes(answer.Digest),
    merkle: ?facts_merkle.Tree = null,

    pub fn open(gpa: Allocator, seam: io_seam.Seam, runtime: *Runtime, options: Options) !*Repo {
        const self = try gpa.create(Repo);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .seam = seam, .fs = seam.fs, .runtime = runtime, .options = options, .store = Store.init(gpa) };
        errdefer self.store.deinit();
        if (options.threads > 1) self.pool.start(options.threads);
        errdefer self.pool.deinit();
        const started = seam.clock.monotonic();
        if (options.store_path) |path| self.load = try fact_file.load(self, path);
        self.load_ms = elapsedMs(seam.clock, started);
        return self;
    }

    pub fn deinit(self: *Repo) void {
        if (self.merkle) |*tree| tree.deinit();
        if (self.workspace) |*w| w.deinit();
        self.pool.deinit();
        self.metas.deinit(self.gpa);
        self.store.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    pub fn computeSnapshot(self: *Repo) !void {
        var leaves: std.ArrayList(answer.Leaf) = .empty;
        defer leaves.deinit(self.gpa);
        for (self.store.files.items, 0..) |state, id| {
            switch (state.status) {
                .indexed, .unindexed => {},
                else => continue,
            }
            const m = try self.meta(@intCast(id));
            try leaves.append(self.gpa, .{ .path = state.path, .digest = m.digest });
        }
        std.mem.sort(answer.Leaf, leaves.items, {}, leafLess);
        if (self.merkle) |*tree| tree.deinit();
        self.merkle = null;
        self.merkle = try facts_merkle.Tree.build(self.gpa, leaves.items);
        self.root_digest = try self.merkle.?.root();
    }

    fn updateSnapshot(self: *Repo, path: []const u8, digest: answer.Digest) !void {
        const tree = if (self.merkle) |*t| t else return self.computeSnapshot();
        tree.update(path, digest) catch |err| switch (err) {
            error.NotALeaf => return self.computeSnapshot(),
        };
        self.root_digest = try tree.root();
    }

    pub fn snapshot(self: *const Repo) answer.Snapshot {
        return .{ .barrier = self.barrier, .root = self.root_digest };
    }

    pub fn largestFile(self: *const Repo) u64 {
        var largest: u64 = 0;
        for (self.store.files.items, 0..) |state, id| {
            if (state.status != .indexed and state.status != .unindexed) continue;
            if (id >= self.metas.items.len) continue;
            largest = @max(largest, self.metas.items[id].stamp.size);
        }
        return largest;
    }

    pub fn query(self: *Repo, arena: Allocator, request: facts_query.Request) !facts_query.FactsAnswer {
        return facts_query.run(arena, &self.store, .{
            .snapshot = self.snapshot(),
            .max_file_bytes = self.options.max_file_bytes,
            .largest_file_bytes = self.largestFile(),
        }, request);
    }

    pub fn factStore(self: *Repo, arena: Allocator) !evidence_api.FactStore {
        const lines = try arena.create(SourceLines);
        lines.* = .{ .repo = self, .arena = arena };
        return self.viewWith(arena, lines);
    }

    fn viewWith(self: *Repo, arena: Allocator, lines: *SourceLines) evidence_api.FactStore {
        return .{
            .arena = arena,
            .store = &self.store,
            .source = lines.source(),
            .snapshot = self.snapshot(),
            .max_file_bytes = self.options.max_file_bytes,
            .largest_file_bytes = self.largestFile(),
        };
    }

    pub const max_refresh_rounds = 2;

    pub fn evidence(self: *Repo, arena: Allocator, request: evidence_api.EvidenceRequest, budget: usize) !evidence_api.EvidenceAnswer {
        const lines = try arena.create(SourceLines);
        lines.* = .{ .repo = self, .arena = arena };
        var round: usize = 0;
        while (true) : (round += 1) {
            const view = self.viewWith(arena, lines);
            const result = evidence_api.evidence(&view, request, budget);
            if (round == max_refresh_rounds) return result;
            if (try lines.refreshChanged() == 0) return result;
        }
    }

    pub fn updateSource(self: *Repo, rel: []const u8, bytes: []const u8) !Update {
        const profile = registry.forPath(rel) orelse return error.UnsupportedLanguage;
        if (!facts_extract.supports(profile)) return error.UnsupportedLanguage;
        const id = self.store.fileId(rel) orelse return error.FileNotInStore;
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const parser = ts.Parser.create();
        defer parser.deinit();
        const tree = try parser.parseIn(profile.grammar(), bytes);
        defer tree.deinit();
        const view: Snapshot = .{ .runtime = self.runtime, .profile = profile, .source = bytes, .tree = tree };
        const found = try facts_extract.extract(scratch.allocator(), &view);
        const arena = try self.gpa.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(self.gpa);
        var owned = true;
        defer if (owned) {
            arena.deinit();
            self.gpa.destroy(arena);
        };
        const kept = try facts.clone(arena.allocator(), found);
        const tokens: []const []const u8 = if (kept.parse_errors) try tokensOf(arena.allocator(), bytes) else &.{};
        const reshaped = try self.store.replace(id, profile, symbol.fileHash(bytes), arena, kept, tokens);
        owned = false;
        const m = try self.meta(id);
        Sha256.hash(bytes, &m.digest, .{});
        m.stamp = .{};
        const relinked = try self.store.relink(&.{id}, if (reshaped) &.{id} else &.{}, self.workspace.?.resolver());
        self.barrier += 1;
        try self.updateSnapshot(self.store.file(id).path, m.digest);
        return .{ .reshaped = reshaped, .relinked = relinked };
    }

    pub fn resetStore(self: *Repo) void {
        self.store.deinit();
        self.store = Store.init(self.gpa);
        self.metas.clearRetainingCapacity();
        self.linked = false;
        self.barrier = 0;
        self.written_ns = 0;
        self.config_signature = std.mem.zeroes([16]u8);
    }

    pub fn meta(self: *Repo, id: FileId) !*Meta {
        while (self.metas.items.len <= id) try self.metas.append(self.gpa, .{});
        return &self.metas.items[id];
    }

    fn collectStamps(self: *Repo, arena: Allocator, paths: []const []const u8) !struct { stamps: []?Stamp, failures: usize } {
        const stamps = try arena.alloc(?Stamp, paths.len);
        @memset(stamps, null);
        var by_dir: std.StringArrayHashMapUnmanaged(DirGroup) = .empty;
        for (paths, 0..) |rel, i| {
            const dir = std.fs.path.dirnamePosix(rel) orelse "";
            const entry = try by_dir.getOrPut(arena, dir);
            if (!entry.found_existing) entry.value_ptr.* = .{ .dir = dir };
            try entry.value_ptr.names.put(arena, std.fs.path.basenamePosix(rel), i);
        }
        var job: StampJob = .{ .root_abs = self.options.root_abs, .fs = self.fs, .stamps = stamps, .groups = by_dir.values() };
        self.runJob(&job, StampJob.run, by_dir.count());
        return .{ .stamps = stamps, .failures = job.failures.load(.acquire) };
    }

    fn runJob(self: *Repo, ctx: anytype, task: worker_pool.Task, items: usize) void {
        if (self.pool.helpers() == 0 or items < 2) return task(ctx);
        self.pool.run(@min(items - 1, self.pool.helpers()), task, ctx);
    }

    fn racy(self: *const Repo, stamp: Stamp) bool {
        if (self.written_ns == 0) return true;
        const delta = stamp.mtime_ns - self.written_ns;
        return delta > -racy_window_ns and delta < racy_window_ns;
    }

    pub fn refresh(self: *Repo) !Report {
        var report: Report = .{ .load = self.load, .load_ms = self.load_ms };
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var started = self.seam.clock.monotonic();
        const tracked = try self.fs.tracked(self.options.root_abs, self.gpa);
        defer io_seam.freeTracked(self.gpa, tracked);
        var scoped: std.ArrayList([]const u8) = .empty;
        for (tracked) |rel| {
            if (inScope(rel)) try scoped.append(arena, rel);
        }
        std.mem.sort([]const u8, scoped.items, {}, lessPath);
        const paths = scoped.items;
        report.listed = tracked.len;
        report.in_scope = paths.len;
        if (self.workspace) |*w| w.deinit();
        self.workspace = null;
        self.workspace = try fact_modules.Workspace.build(self.gpa, self.fs, self.options.root_abs, @ptrCast(tracked));
        const workspace = &self.workspace.?;
        report.config_notes = workspace.notes.items.len;
        const configs_changed = !std.mem.eql(u8, &workspace.signature, &self.config_signature);
        self.config_signature = workspace.signature;
        report.list_ms = elapsedMs(self.seam.clock, started);

        started = self.seam.clock.monotonic();
        const stamped = try self.collectStamps(arena, paths);
        report.stat_failures = stamped.failures;
        var present: std.StringHashMapUnmanaged(void) = .empty;
        var todo: std.ArrayList(usize) = .empty;
        var set_changed = false;
        for (paths, stamped.stamps, 0..) |rel, stamp, i| {
            try present.put(arena, rel, {});
            const known = self.store.fileId(rel) orelse {
                set_changed = true;
                try todo.append(arena, i);
                continue;
            };
            const state = self.store.file(known);
            if (state.status == .removed) set_changed = true;
            const m = try self.meta(known);
            if (stamp) |s| {
                if (state.status != .removed and sameStamp(m.stamp, s) and !self.racy(s)) {
                    report.reused += 1;
                    continue;
                }
            }
            try todo.append(arena, i);
        }
        for (self.store.files.items, 0..) |state, id| {
            if (state.status == .removed or present.contains(state.path)) continue;
            _ = try self.store.remove(@intCast(id));
            set_changed = true;
            report.removed += 1;
        }
        report.stat_ms = elapsedMs(self.seam.clock, started);

        started = self.seam.clock.monotonic();
        const todo_paths = try arena.alloc([]const u8, todo.items.len);
        const previous = try arena.alloc(?facts.Hash, todo.items.len);
        const outcomes = try arena.alloc(Outcome, todo.items.len);
        const metas = try arena.alloc(Meta, todo.items.len);
        for (todo.items, todo_paths, previous, outcomes, metas) |i, *path, *prior, *outcome, *m| {
            path.* = paths[i];
            prior.* = null;
            if (self.store.fileId(paths[i])) |id| {
                const state = self.store.file(id);
                if (state.status == .indexed or state.status == .unindexed) prior.* = state.content_hash;
            }
            outcome.* = .pending;
            m.* = .{ .stamp = stamped.stamps[i] orelse .{} };
        }
        var job: Job = .{ .gpa = self.gpa, .clock = self.seam.clock, .fs = self.fs, .runtime = self.runtime, .root_abs = self.options.root_abs, .max_file_bytes = self.options.max_file_bytes, .paths = todo_paths, .previous = previous, .outcomes = outcomes, .metas = metas };
        self.runJob(&job, Job.run, todo_paths.len);
        if (job.failed()) |err| {
            discardOutcomes(self.gpa, outcomes);
            return err;
        }
        report.extract_ms = elapsedMs(self.seam.clock, started);
        report.read_cpu_ms = job.phaseMs(.read);
        report.parse_cpu_ms = job.phaseMs(.parse);
        report.extract_cpu_ms = job.phaseMs(.extract);
        report.clone_cpu_ms = job.phaseMs(.clone);

        started = self.seam.clock.monotonic();
        var changed: std.ArrayList(FileId) = .empty;
        var reshaped: std.ArrayList(FileId) = .empty;
        defer discardOutcomes(self.gpa, outcomes);
        for (todo_paths, outcomes, metas) |rel, *outcome, m| {
            const id = try self.store.ensureFile(rel);
            const slot = try self.meta(id);
            const before = self.store.file(id);
            const same_content = before.status == .indexed and std.mem.eql(u8, &slot.digest, &m.digest);
            slot.* = m;
            switch (outcome.*) {
                .pending => return error.ExtractionIncomplete,
                .same => report.rehashed += 1,
                .indexed => |x| {
                    if (same_content and std.mem.eql(u8, &before.content_hash, &x.hash)) {
                        report.rehashed += 1;
                        continue;
                    }
                    outcome.* = .pending;
                    if (try self.store.replace(id, x.profile, x.hash, x.arena, x.found, x.tokens)) try reshaped.append(arena, id);
                    try changed.append(arena, id);
                    report.extracted += 1;
                },
                .unindexed => |x| {
                    if (try self.store.markUnindexed(id, .unindexed, "", x.tokens)) try reshaped.append(arena, id);
                    self.store.files.items[id].content_hash = x.hash;
                    report.extracted += 1;
                },
                .failed => |x| {
                    if (x.status == .unreadable) slot.stamp = .{};
                    if (try self.store.markUnindexed(id, x.status, x.note, &.{})) try reshaped.append(arena, id);
                    report.extracted += 1;
                },
            }
        }
        const resolver = workspace.resolver();
        if (!self.linked or set_changed or configs_changed) {
            try self.store.linkAll(resolver);
            self.linked = true;
            report.full_link = true;
            report.relinked = self.store.files.items.len;
        } else if (changed.items.len != 0 or reshaped.items.len != 0) {
            report.relinked = try self.store.relink(changed.items, reshaped.items, resolver);
        }
        report.link_ms = elapsedMs(self.seam.clock, started);
        self.barrier += 1;
        try self.computeSnapshot();

        const dirty = report.full_link or report.relinked != 0 or report.rehashed != 0 or report.removed != 0 or report.extracted != 0;
        if (self.options.store_path) |path| {
            if (dirty or self.load != .loaded) {
                started = self.seam.clock.monotonic();
                self.written_ns = self.seam.clock.realtime();
                report.store_bytes = try fact_file.save(self, path);
                report.saved = true;
                report.save_ms = elapsedMs(self.seam.clock, started);
                self.load = .loaded;
            }
        }
        return report;
    }
};

pub const Update = struct {
    reshaped: bool,
    relinked: usize,
};

fn leafLess(_: void, a: answer.Leaf, b: answer.Leaf) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

pub fn readSource(repo: *const Repo, arena: Allocator, abs: []const u8) io_seam.ReadError![]u8 {
    return repo.fs.readFile(abs, arena, repo.options.max_file_bytes);
}

pub const SourceLines = struct {
    repo: *Repo,
    arena: Allocator,
    files: std.StringArrayHashMapUnmanaged(Cached) = .empty,

    pub const Cached = union(enum) { bytes: []const u8, changed: []const u8, vanished, too_large, unreadable };

    pub fn source(self: *SourceLines) facts_evidence.Source {
        return .{ .ctx = self, .fileFn = fileOf };
    }

    fn fileOf(ctx: *anyopaque, path: []const u8) facts_evidence.SourceError!facts_evidence.File {
        const self: *SourceLines = @ptrCast(@alignCast(ctx));
        const id = self.repo.store.fileId(path) orelse return error.Vanished;
        const profile = self.repo.store.file(id).profile orelse return error.Vanished;
        const cached = self.files.get(path) orelse blk: {
            const loaded = try self.load(path, id);
            try self.files.put(self.arena, path, loaded);
            break :blk loaded;
        };
        return switch (cached) {
            .bytes => |bytes| .{ .bytes = bytes, .profile = profile },
            .changed => error.Changed,
            .vanished => error.Vanished,
            .too_large => error.TooLarge,
            .unreadable => error.Unreadable,
        };
    }

    fn load(self: *SourceLines, path: []const u8, id: FileId) Allocator.Error!Cached {
        const abs = try std.fmt.allocPrint(self.arena, "{s}\\{s}", .{ self.repo.options.root_abs, path });
        const bytes = readSource(self.repo, self.arena, abs) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.FileNotFound, error.IsDirectory => .vanished,
            error.TooLarge => .too_large,
            error.Busy, error.AccessDenied, error.NameTooLong, error.BadPathName, error.InputOutput => .unreadable,
        };
        if (!std.mem.eql(u8, &symbol.fileHash(bytes), &self.repo.store.file(id).content_hash)) return .{ .changed = bytes };
        return .{ .bytes = bytes };
    }

    pub fn refreshChanged(self: *SourceLines) !usize {
        var refreshed: usize = 0;
        if (self.repo.workspace == null) return 0;
        for (self.files.keys(), self.files.values()) |path, *cached| {
            const bytes = switch (cached.*) {
                .changed => |b| b,
                else => continue,
            };
            _ = self.repo.updateSource(path, bytes) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            cached.* = .{ .bytes = bytes };
            refreshed += 1;
        }
        return refreshed;
    }
};

fn sameStamp(a: Stamp, b: Stamp) bool {
    return a.mtime_ns == b.mtime_ns and a.size == b.size;
}

fn lessPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn discardOutcomes(gpa: Allocator, outcomes: []Outcome) void {
    for (outcomes) |*o| {
        switch (o.*) {
            .indexed => |x| {
                x.arena.deinit();
                gpa.destroy(x.arena);
            },
            .unindexed => |x| {
                x.arena.deinit();
                gpa.destroy(x.arena);
            },
            .pending, .same, .failed => {},
        }
        o.* = .pending;
    }
}
