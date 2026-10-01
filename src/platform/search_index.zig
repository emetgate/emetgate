const std = @import("std");
const sandbox = @import("sandbox.zig");
const shadow_root = @import("shadow_root.zig");
const symbol = @import("../engine/symbol.zig");
const ts = @import("../engine/tree_sitter.zig");
const registry = @import("../engine/lang/registry.zig");
pub const kind_spans = @import("../engine/kind_spans.zig");
pub const doc_spans = @import("../engine/doc_spans.zig");
const span_codec = @import("../engine/span_codec.zig");
const trigram = @import("../engine/trigram.zig");
const index_file = @import("search_index_file.zig");
const index_map = @import("index_map.zig");
const stat_scan = @import("stat_scan.zig");
const worker_pool = @import("worker_pool.zig");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

pub const max_indexed_file_bytes: usize = 1 * 1024 * 1024;
pub const racy_window_ns: i64 = 3 * std.time.ns_per_s;

pub const Stamp = index_file.Stamp;
pub const GitStamp = index_file.GitStamp;
pub const FileState = index_file.FileState;
pub const Digest = index_file.Digest;
pub const Seen = stat_scan.Seen;
pub const LoadFailure = index_map.Failure;

pub const trigramsOfAlloc = trigram.setOfAlloc;
pub const isSupersetSorted = trigram.isSupersetSorted;

pub const Prepared = struct {
    path: []u8,
    stamp: Stamp,
    state: FileState,
    content: []u8 = &.{},
    digest: Digest = std.mem.zeroes(Digest),
    spans: []u8 = &.{},
    grams: []u24 = &.{},

    pub fn deinit(self: Prepared, gpa: Allocator) void {
        gpa.free(self.path);
        gpa.free(self.content);
        gpa.free(self.spans);
        gpa.free(self.grams);
    }

    pub fn input(self: Prepared) index_file.Input {
        return .{ .path = self.path, .stamp = self.stamp, .state = self.state, .content = self.content, .digest = self.digest, .spans = self.spans };
    }
};

pub fn indexDir(gpa: Allocator, root_abs: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const local = (try sandbox.environmentValue(arena_state.allocator(), std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA"))) orelse return error.LocalAppDataUnavailable;
    const key = shadow_root.repoKey(root_abs);
    return std.fmt.allocPrint(gpa, "{s}\\emetgate\\index\\{s}", .{ local, &key });
}

pub fn isRacy(stamp: Stamp, written_ns: i64) bool {
    const newest = @max(stamp.mtime_ns, stamp.ctime_ns);
    const delta = newest - written_ns;
    return delta > -racy_window_ns and delta < racy_window_ns;
}

pub const smudged_mtime_ns: i64 = std.math.minInt(i64);

pub fn smudgedIfRacy(stamp: Stamp, read_ns: i64) Stamp {
    if (!isRacy(stamp, read_ns)) return stamp;
    return .{ .mtime_ns = smudged_mtime_ns, .ctime_ns = stamp.ctime_ns, .size = stamp.size };
}

fn wallNow(io: std.Io) i64 {
    return @intCast(std.Io.Clock.real.now(io).nanoseconds);
}

pub fn sameStamp(a: Stamp, b: Stamp) bool {
    return a.mtime_ns == b.mtime_ns and a.ctime_ns == b.ctime_ns and a.size == b.size;
}

fn looksBinary(bytes: []const u8) bool {
    return std.mem.indexOfScalar(u8, bytes, 0) != null;
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

pub fn statOne(io: std.Io, abs: []const u8) ?Seen {
    const stat = Dir.cwd().statFile(io, abs, .{ .follow_symlinks = false }) catch return null;
    return .{
        .stamp = .{ .mtime_ns = @intCast(stat.mtime.nanoseconds), .ctime_ns = @intCast(stat.ctime.nanoseconds), .size = stat.size },
        .kind = switch (stat.kind) {
            .file => .file,
            .directory => .directory,
            else => .other,
        },
    };
}

pub fn prepareOne(gpa: Allocator, io: std.Io, root_abs: []const u8, rel: []const u8, seen: ?Seen, want_grams: bool) !Prepared {
    const path = try gpa.dupe(u8, rel);
    errdefer gpa.free(path);
    const abs = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ root_abs, rel });
    defer gpa.free(abs);
    const found = seen orelse statOne(io, abs) orelse return .{ .path = path, .stamp = .{ .mtime_ns = 0, .ctime_ns = 0, .size = 0 }, .state = .deleted };
    const stamp = found.stamp;
    switch (found.kind) {
        .file => {},
        .directory => return .{ .path = path, .stamp = stamp, .state = .unreadable },
        .other => return .{ .path = path, .stamp = stamp, .state = .link },
    }
    if (stamp.size > max_indexed_file_bytes) return .{ .path = path, .stamp = stamp, .state = .large };
    const bytes = Dir.cwd().readFileAlloc(io, abs, gpa, .limited(max_indexed_file_bytes + 1)) catch |err| return .{ .path = path, .stamp = stamp, .state = switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => .large,
        error.FileNotFound => .deleted,
        else => .unreadable,
    } };
    errdefer gpa.free(bytes);
    if (looksBinary(bytes)) {
        gpa.free(bytes);
        return .{ .path = path, .stamp = stamp, .state = .binary };
    }
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const blob = try span_codec.encode(gpa, spansFor(arena.allocator(), rel, bytes), doc_spans.build(arena.allocator(), rel, bytes));
    errdefer gpa.free(blob);
    const grams: []u24 = if (want_grams) try trigramsOfAlloc(gpa, bytes) else &.{};
    return .{ .path = path, .stamp = stamp, .state = .indexed, .content = bytes, .digest = index_file.contentDigest(bytes), .spans = blob, .grams = grams };
}

pub const Cancel = std.atomic.Value(bool);

pub fn prepareAll(gpa: Allocator, io: std.Io, root_abs: []const u8, paths: []const []const u8, seen: []const ?Seen, want_grams: bool, pool: ?*worker_pool.Pool, cancel: ?*Cancel) ![]Prepared {
    std.debug.assert(paths.len == seen.len);
    const out = try gpa.alloc(Prepared, paths.len);
    var job: PrepareJob = .{ .gpa = gpa, .io = io, .root = root_abs, .paths = paths, .seen = seen, .out = out, .want_grams = want_grams, .cancel = cancel, .done = try gpa.alloc(bool, paths.len) };
    defer gpa.free(job.done);
    @memset(job.done, false);
    if (pool) |p| p.run(worker_pool.max_threads, PrepareJob.run, &job) else PrepareJob.run(&job);
    if (job.failure != null or (cancel != null and cancel.?.load(.acquire))) {
        for (out, job.done) |p, d| if (d) p.deinit(gpa);
        gpa.free(out);
        return job.failure orelse error.Canceled;
    }
    return out;
}

const PrepareJob = struct {
    gpa: Allocator,
    io: std.Io,
    root: []const u8,
    paths: []const []const u8,
    seen: []const ?Seen,
    out: []Prepared,
    done: []bool,
    want_grams: bool,
    cancel: ?*Cancel,
    next: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,

    fn run(ctx: *anyopaque) void {
        const self: *PrepareJob = @ptrCast(@alignCast(ctx));
        while (!self.failed.load(.acquire)) {
            if (self.cancel) |c| if (c.load(.acquire)) return;
            const i = self.next.fetchAdd(1, .monotonic);
            if (i >= self.paths.len) return;
            var prepared = prepareOne(self.gpa, self.io, self.root, self.paths[i], self.seen[i], self.want_grams) catch |err| {
                if (!self.failed.swap(true, .acq_rel)) self.failure = err;
                return;
            };
            prepared.stamp = smudgedIfRacy(prepared.stamp, wallNow(self.io));
            self.out[i] = prepared;
            self.done[i] = true;
        }
    }
};

pub fn freeAll(gpa: Allocator, prepared: []Prepared) void {
    for (prepared) |p| p.deinit(gpa);
    gpa.free(prepared);
}

pub fn sortByPath(prepared: []Prepared) void {
    std.mem.sort(Prepared, prepared, {}, struct {
        fn less(_: void, a: Prepared, b: Prepared) bool {
            return index_file.foldedOrder(a.path, b.path) == .lt;
        }
    }.less);
}

const testing = std.testing;

test "prepareOne reads a source file into content, hash, grams and a span blob that decodes to its symbols" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.ts", .data = "export function loadPending() {\n  return 1;\n}\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.bin", .data = "a\x00b" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    const p = try prepareOne(testing.allocator, testing.io, root, "a.ts", null, true);
    defer p.deinit(testing.allocator);
    try testing.expectEqual(FileState.indexed, p.state);
    try testing.expect(std.mem.indexOf(u8, p.content, "loadPending") != null);
    try testing.expect(p.grams.len > 10);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const decoded = try span_codec.decode(arena.allocator(), p.spans);
    try testing.expectEqualStrings("loadPending", decoded.spans.?.symbols[0].name);

    const bin = try prepareOne(testing.allocator, testing.io, root, "b.bin", null, false);
    defer bin.deinit(testing.allocator);
    try testing.expectEqual(FileState.binary, bin.state);
    const gone = try prepareOne(testing.allocator, testing.io, root, "gone.ts", null, false);
    defer gone.deinit(testing.allocator);
    try testing.expectEqual(FileState.deleted, gone.state);
}

test "a stamp within three seconds of the index write time is racy and a later one is not" {
    const written: i64 = 100 * std.time.ns_per_s;
    try testing.expect(isRacy(.{ .mtime_ns = written - 1, .ctime_ns = 0, .size = 1 }, written));
    try testing.expect(isRacy(.{ .mtime_ns = 0, .ctime_ns = written + std.time.ns_per_s, .size = 1 }, written));
    try testing.expect(!isRacy(.{ .mtime_ns = written - 4 * std.time.ns_per_s, .ctime_ns = written - 5 * std.time.ns_per_s, .size = 1 }, written));
}
