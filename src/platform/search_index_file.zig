const std = @import("std");
const symbol = @import("../engine/symbol.zig");
const postings = @import("../engine/postings.zig");
const trigram = @import("../engine/trigram.zig");
const worker_pool = @import("worker_pool.zig");

const Allocator = std.mem.Allocator;

pub const magic = "EMGIDX\x00\x04";
pub const version: u32 = 4;
pub const chunk_size: u32 = 4 * 1024 * 1024;
pub const alignment = 64;

pub const Stamp = struct { mtime_ns: i64, ctime_ns: i64, size: u64 };
pub const Digest = [32]u8;

pub fn contentDigest(bytes: []const u8) Digest {
    var out: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return out;
}
pub const GitStamp = struct { mtime_ns: i96, size: u64, id: u64 };

pub const FileState = enum(u8) { indexed = 0, binary = 1, large = 2, deleted = 3, unreadable = 4, link = 5 };

pub const Range = extern struct { offset: u64, len: u64 };

pub const Section = enum(u8) { files, paths, content, spans, grams, postings, sums };
const section_count = @typeInfo(Section).@"enum".fields.len;

pub const Header = extern struct {
    magic: [8]u8,
    version: u32,
    header_size: u32,
    file_count: u32,
    gram_count: u32,
    chunk_size: u32,
    chunk_count: u32,
    written_ns: i64,
    git_mtime_ns: i64,
    git_size: u64,
    git_id: u64,
    git_present: u32,
    reserved: u32,
    sections: [section_count]Range,
    header_sum: [16]u8,
};

pub const FileRec = extern struct {
    path_off: u32,
    path_len: u32,
    size: u64,
    mtime_ns: i64,
    ctime_ns: i64,
    content_off: u64,
    content_len: u32,
    spans_len: u32,
    spans_off: u64,
    digest: Digest,
    state: u8,
    pad: [7]u8 = [_]u8{0} ** 7,

    pub fn stamp(self: FileRec) Stamp {
        return .{ .mtime_ns = self.mtime_ns, .ctime_ns = self.ctime_ns, .size = self.size };
    }
};

pub const GramMeta = extern struct { gram: u32, count: u32, offset: u64 };

pub fn foldByte(c: u8) u8 {
    return if (c == '\\') '/' else std.ascii.toLower(c);
}

pub fn foldedOrder(a: []const u8, b: []const u8) std.math.Order {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        const fx = foldByte(x);
        const fy = foldByte(y);
        if (fx != fy) return std.math.order(fx, fy);
    }
    if (a.len != b.len) return std.math.order(a.len, b.len);
    return std.mem.order(u8, a, b);
}

pub fn foldedLess(_: void, a: []const u8, b: []const u8) bool {
    return foldedOrder(a, b) == .lt;
}

pub const Input = struct {
    path: []const u8,
    stamp: Stamp,
    state: FileState,
    content: []const u8 = "",
    digest: Digest = std.mem.zeroes(Digest),
    spans: []const u8 = "",
};

pub const Meta = struct {
    written_ns: i64,
    git_stamp: ?GitStamp,
};

pub const BuildError = error{ OutOfMemory, TooLarge, Unsorted };

pub fn build(gpa: Allocator, inputs: []const Input, meta: Meta, pool: ?*worker_pool.Pool) BuildError![]align(alignment) u8 {
    if (inputs.len > std.math.maxInt(u32)) return error.TooLarge;
    if (inputs.len > 1) for (inputs[1..], 0..) |in, i| {
        if (foldedOrder(inputs[i].path, in.path) != .lt) return error.Unsorted;
    };
    const grams_of = try extractGrams(gpa, inputs, pool);
    defer {
        for (grams_of.lists) |l| gpa.free(l);
        gpa.free(grams_of.lists);
        std.heap.page_allocator.free(grams_of.counts);
    }
    const universe: u32 = @intCast(inputs.len);

    var gram_list: std.ArrayList(GramMeta) = .empty;
    defer gram_list.deinit(gpa);
    var postings_words: usize = 0;
    for (grams_of.counts, 0..) |count, g| {
        if (count == 0) continue;
        const shape = postings.Shape.of(count, universe);
        try gram_list.append(gpa, .{ .gram = @intCast(g), .count = count, .offset = postings_words });
        postings_words += shape.words();
    }

    var sizes: [section_count]u64 = .{0} ** section_count;
    sizes[@intFromEnum(Section.files)] = @sizeOf(FileRec) * inputs.len;
    for (inputs) |in| {
        sizes[@intFromEnum(Section.paths)] += in.path.len;
        sizes[@intFromEnum(Section.content)] += in.content.len;
        sizes[@intFromEnum(Section.spans)] += in.spans.len;
    }
    sizes[@intFromEnum(Section.grams)] = @sizeOf(GramMeta) * gram_list.items.len;
    sizes[@intFromEnum(Section.postings)] = 8 * postings_words;
    if (sizes[@intFromEnum(Section.paths)] > std.math.maxInt(u32)) return error.TooLarge;

    var ranges: [section_count]Range = undefined;
    var at: u64 = std.mem.alignForward(u64, @sizeOf(Header), alignment);
    const body_start = at;
    for (0..section_count - 1) |i| {
        ranges[i] = .{ .offset = at, .len = sizes[i] };
        at = std.mem.alignForward(u64, at + sizes[i], alignment);
    }
    const body_len = at - body_start;
    const chunks: u64 = std.math.divCeil(u64, body_len, chunk_size) catch unreachable;
    if (chunks > std.math.maxInt(u32)) return error.TooLarge;
    ranges[@intFromEnum(Section.sums)] = .{ .offset = at, .len = 16 * chunks };
    const total = at + 16 * chunks;
    if (total > std.math.maxInt(usize)) return error.TooLarge;

    const image = try gpa.alignedAlloc(u8, .fromByteUnits(alignment), @intCast(total));
    errdefer gpa.free(image);
    @memset(image, 0);

    const records = std.mem.bytesAsSlice(FileRec, image[ranges[0].offset..][0..sizes[0]]);
    var path_at: u64 = 0;
    var content_at: u64 = 0;
    var spans_at: u64 = 0;
    for (inputs, records) |in, *rec| {
        rec.* = .{
            .path_off = @intCast(path_at),
            .path_len = @intCast(in.path.len),
            .size = in.stamp.size,
            .mtime_ns = in.stamp.mtime_ns,
            .ctime_ns = in.stamp.ctime_ns,
            .content_off = content_at,
            .content_len = @intCast(in.content.len),
            .spans_len = @intCast(in.spans.len),
            .spans_off = spans_at,
            .digest = in.digest,
            .state = @intFromEnum(in.state),
        };
        @memcpy(image[ranges[@intFromEnum(Section.paths)].offset + path_at ..][0..in.path.len], in.path);
        @memcpy(image[ranges[@intFromEnum(Section.content)].offset + content_at ..][0..in.content.len], in.content);
        @memcpy(image[ranges[@intFromEnum(Section.spans)].offset + spans_at ..][0..in.spans.len], in.spans);
        path_at += in.path.len;
        content_at += in.content.len;
        spans_at += in.spans.len;
    }

    const metas: []GramMeta = @alignCast(std.mem.bytesAsSlice(GramMeta, image[ranges[@intFromEnum(Section.grams)].offset..][0..sizes[@intFromEnum(Section.grams)]]));
    @memcpy(metas, gram_list.items);
    const words: []u64 = @alignCast(std.mem.bytesAsSlice(u64, image[ranges[@intFromEnum(Section.postings)].offset..][0..sizes[@intFromEnum(Section.postings)]]));
    try fillPostings(gpa, words, metas, grams_of, universe);

    const header: *Header = @ptrCast(image.ptr);
    header.* = .{
        .magic = magic.*,
        .version = version,
        .header_size = @sizeOf(Header),
        .file_count = universe,
        .gram_count = @intCast(gram_list.items.len),
        .chunk_size = chunk_size,
        .chunk_count = @intCast(chunks),
        .written_ns = meta.written_ns,
        .git_mtime_ns = if (meta.git_stamp) |g| @intCast(g.mtime_ns) else 0,
        .git_size = if (meta.git_stamp) |g| g.size else 0,
        .git_id = if (meta.git_stamp) |g| g.id else 0,
        .git_present = @intFromBool(meta.git_stamp != null),
        .reserved = 0,
        .sections = ranges,
        .header_sum = undefined,
    };
    const sums = std.mem.bytesAsSlice([16]u8, image[ranges[@intFromEnum(Section.sums)].offset..][0 .. 16 * chunks]);
    hashChunks(image[body_start..][0..body_len], sums, pool);
    header.header_sum = headerSum(image, ranges[@intFromEnum(Section.sums)]);
    return image;
}

const Grams = struct {
    counts: []u32,
    lists: [][]u32,
};

const ExtractJob = struct {
    inputs: []const Input,
    counts: []u32,
    lists: [][]u32,
    gpa: Allocator,
    next: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),

    fn run(ctx: *anyopaque) void {
        const self: *ExtractJob = @ptrCast(@alignCast(ctx));
        const seen = std.heap.page_allocator.alloc(u64, (1 << 24) / 64) catch {
            self.failed.store(true, .release);
            return;
        };
        defer std.heap.page_allocator.free(seen);
        @memset(seen, 0);
        var scratch: std.ArrayList(u32) = .empty;
        defer scratch.deinit(self.gpa);
        while (!self.failed.load(.acquire)) {
            const i = self.next.fetchAdd(1, .monotonic);
            if (i >= self.inputs.len) return;
            self.extractOne(i, seen, &scratch) catch {
                self.failed.store(true, .release);
                return;
            };
        }
    }

    fn extractOne(self: *ExtractJob, i: usize, seen: []u64, scratch: *std.ArrayList(u32)) !void {
        const text = self.inputs[i].content;
        scratch.clearRetainingCapacity();
        if (text.len >= 3) {
            var g: u32 = (@as(u32, text[0]) << 8) | text[1];
            for (text[2..]) |c| {
                g = ((g << 8) | c) & 0xFFFFFF;
                const word = g >> 6;
                const bit = @as(u64, 1) << @as(u6, @truncate(g));
                if (seen[word] & bit != 0) continue;
                seen[word] |= bit;
                try scratch.append(self.gpa, g);
            }
        }
        for (scratch.items) |g| {
            seen[g >> 6] &= ~(@as(u64, 1) << @as(u6, @truncate(g)));
            _ = @atomicRmw(u32, &self.counts[g], .Add, 1, .monotonic);
        }
        self.lists[i] = try self.gpa.dupe(u32, scratch.items);
    }
};

fn extractGrams(gpa: Allocator, inputs: []const Input, pool: ?*worker_pool.Pool) !Grams {
    const counts = try std.heap.page_allocator.alloc(u32, 1 << 24);
    errdefer std.heap.page_allocator.free(counts);
    @memset(counts, 0);
    const lists = try gpa.alloc([]u32, inputs.len);
    for (lists) |*l| l.* = &.{};
    errdefer {
        for (lists) |l| gpa.free(l);
        gpa.free(lists);
    }
    var job: ExtractJob = .{ .inputs = inputs, .counts = counts, .lists = lists, .gpa = gpa };
    if (pool) |p| p.run(worker_pool.max_threads, ExtractJob.run, &job) else ExtractJob.run(&job);
    if (job.failed.load(.acquire)) return error.OutOfMemory;
    return .{ .counts = counts, .lists = lists };
}

fn fillPostings(gpa: Allocator, words: []u64, metas: []const GramMeta, grams_of: Grams, universe: u32) !void {
    const writers = try gpa.alloc(postings.Writer, metas.len);
    defer gpa.free(writers);
    for (metas, writers, 0..) |m, *w, i| {
        const shape = postings.Shape.of(m.count, universe);
        w.* = .init(shape, words[m.offset..][0..shape.words()]);
        grams_of.counts[m.gram] = @intCast(i);
    }
    for (grams_of.lists, 0..) |list, id| {
        for (list) |g| writers[grams_of.counts[g]].push(@intCast(id));
    }
}

const HashJob = struct {
    body: []const u8,
    sums: [][16]u8,
    next: std.atomic.Value(usize) = .init(0),

    fn run(ctx: *anyopaque) void {
        const self: *HashJob = @ptrCast(@alignCast(ctx));
        while (true) {
            const i = self.next.fetchAdd(1, .monotonic);
            if (i >= self.sums.len) return;
            const start = i * chunk_size;
            const end = @min(self.body.len, start + chunk_size);
            self.sums[i] = symbol.hashOf(self.body[start..end]);
        }
    }
};

fn hashChunks(body: []const u8, sums: [][16]u8, pool: ?*worker_pool.Pool) void {
    var job: HashJob = .{ .body = body, .sums = sums };
    if (pool) |p| p.run(worker_pool.max_threads, HashJob.run, &job) else HashJob.run(&job);
}

const VerifyJob = struct {
    body: []const u8,
    sums: []const [16]u8,
    next: std.atomic.Value(usize) = .init(0),
    bad: std.atomic.Value(bool) = .init(false),

    fn run(ctx: *anyopaque) void {
        const self: *VerifyJob = @ptrCast(@alignCast(ctx));
        while (!self.bad.load(.monotonic)) {
            const i = self.next.fetchAdd(1, .monotonic);
            if (i >= self.sums.len) return;
            const start = i * chunk_size;
            const end = @min(self.body.len, start + chunk_size);
            const actual = symbol.hashOf(self.body[start..end]);
            if (!std.mem.eql(u8, &actual, &self.sums[i])) self.bad.store(true, .release);
        }
    }
};

fn headerSum(image: []const u8, sums: Range) [16]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(image[0..@offsetOf(Header, "header_sum")]);
    hasher.update(image[@sizeOf(Header)..body_offset]);
    hasher.update(image[sums.offset..][0..sums.len]);
    var out: [16]u8 = undefined;
    hasher.final(&out);
    return out;
}

const body_offset = std.mem.alignForward(usize, @sizeOf(Header), alignment);

pub const OpenError = error{ Corrupt, Version };

pub const View = struct {
    bytes: []align(alignment) const u8,
    header: *const Header,
    records: []const FileRec,
    paths: []const u8,
    content: []const u8,
    spans: []const u8,
    grams: []const GramMeta,
    words: []const u64,

    pub fn open(bytes: []align(alignment) const u8) OpenError!View {
        if (bytes.len >= 8 and std.mem.startsWith(u8, bytes, "EMGIDX\x00") and bytes[7] != magic[7]) return error.Version;
        if (bytes.len < @sizeOf(Header)) return error.Corrupt;
        const header: *const Header = @ptrCast(bytes.ptr);
        if (!std.mem.eql(u8, &header.magic, magic)) return error.Corrupt;
        if (header.version != version) return error.Version;
        if (header.header_size != @sizeOf(Header) or header.chunk_size != chunk_size) return error.Corrupt;
        var end: u64 = std.mem.alignForward(u64, @sizeOf(Header), alignment);
        for (header.sections, 0..) |r, i| {
            if (r.offset != end) return error.Corrupt;
            if (r.len > bytes.len or r.offset > bytes.len - r.len) return error.Corrupt;
            end = if (i == section_count - 1) r.offset + r.len else std.mem.alignForward(u64, r.offset + r.len, alignment);
        }
        if (end != bytes.len) return error.Corrupt;
        const sums = header.sections[@intFromEnum(Section.sums)];
        const body_len = sums.offset - std.mem.alignForward(u64, @sizeOf(Header), alignment);
        const chunks = std.math.divCeil(u64, body_len, chunk_size) catch unreachable;
        if (header.chunk_count != chunks or sums.len != 16 * chunks) return error.Corrupt;
        if (!std.mem.eql(u8, &headerSum(bytes, sums), &header.header_sum)) return error.Corrupt;
        const files = header.sections[@intFromEnum(Section.files)];
        const grams = header.sections[@intFromEnum(Section.grams)];
        if (files.len != @as(u64, header.file_count) * @sizeOf(FileRec)) return error.Corrupt;
        if (grams.len != @as(u64, header.gram_count) * @sizeOf(GramMeta)) return error.Corrupt;
        const post = header.sections[@intFromEnum(Section.postings)];
        if (post.len % 8 != 0) return error.Corrupt;
        return .{
            .bytes = bytes,
            .header = header,
            .records = @alignCast(std.mem.bytesAsSlice(FileRec, bytes[files.offset..][0..files.len])),
            .paths = section(bytes, header, .paths),
            .content = section(bytes, header, .content),
            .spans = section(bytes, header, .spans),
            .grams = @alignCast(std.mem.bytesAsSlice(GramMeta, bytes[grams.offset..][0..grams.len])),
            .words = @alignCast(std.mem.bytesAsSlice(u64, bytes[post.offset..][0..post.len])),
        };
    }

    fn section(bytes: []const u8, header: *const Header, which: Section) []const u8 {
        const r = header.sections[@intFromEnum(which)];
        return bytes[r.offset..][0..r.len];
    }

    pub fn verify(self: View, pool: ?*worker_pool.Pool) bool {
        const sums_range = self.header.sections[@intFromEnum(Section.sums)];
        const body_start = std.mem.alignForward(u64, @sizeOf(Header), alignment);
        const sums = std.mem.bytesAsSlice([16]u8, self.bytes[sums_range.offset..][0..sums_range.len]);
        var job: VerifyJob = .{ .body = self.bytes[body_start..sums_range.offset], .sums = sums };
        if (pool) |p| p.run(worker_pool.max_threads, VerifyJob.run, &job) else VerifyJob.run(&job);
        if (job.bad.load(.acquire)) return false;
        return self.checkRecords();
    }

    fn checkRecords(self: View) bool {
        var prev: ?[]const u8 = null;
        for (self.records) |rec| {
            if (@as(u64, rec.path_off) + rec.path_len > self.paths.len) return false;
            if (rec.content_off + rec.content_len > self.content.len) return false;
            if (rec.spans_off + rec.spans_len > self.spans.len) return false;
            if (rec.state > @intFromEnum(FileState.link)) return false;
            const p = self.paths[rec.path_off..][0..rec.path_len];
            if (prev) |q| if (foldedOrder(q, p) != .lt) return false;
            prev = p;
        }
        var prev_gram: ?u32 = null;
        for (self.grams) |g| {
            if (g.gram > 0xFFFFFF or g.count == 0 or g.count > self.header.file_count) return false;
            if (prev_gram) |pg| if (g.gram <= pg) return false;
            prev_gram = g.gram;
            const shape = postings.Shape.of(g.count, self.header.file_count);
            if (g.offset + shape.words() > self.words.len) return false;
        }
        return true;
    }

    pub fn count(self: View) u32 {
        return self.header.file_count;
    }

    pub fn path(self: View, id: u32) []const u8 {
        const rec = self.records[id];
        return self.paths[rec.path_off..][0..rec.path_len];
    }

    pub fn record(self: View, id: u32) *const FileRec {
        return &self.records[id];
    }

    pub fn contentOf(self: View, id: u32) []const u8 {
        const rec = self.records[id];
        return self.content[rec.content_off..][0..rec.content_len];
    }

    pub fn spansOf(self: View, id: u32) []const u8 {
        const rec = self.records[id];
        return self.spans[rec.spans_off..][0..rec.spans_len];
    }

    pub fn stateOf(self: View, id: u32) FileState {
        return @enumFromInt(self.records[id].state);
    }

    pub fn gitStamp(self: View) ?GitStamp {
        if (self.header.git_present == 0) return null;
        return .{ .mtime_ns = self.header.git_mtime_ns, .size = self.header.git_size, .id = self.header.git_id };
    }

    pub fn list(self: View, gram: u24) ?postings.List {
        var lo: usize = 0;
        var hi: usize = self.grams.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.grams[mid].gram < gram) lo = mid + 1 else hi = mid;
        }
        if (lo == self.grams.len or self.grams[lo].gram != gram) return null;
        const meta = self.grams[lo];
        const shape = postings.Shape.of(meta.count, self.header.file_count);
        return .{ .shape = shape, .words = self.words[meta.offset..][0..shape.words()] };
    }

    pub fn find(self: View, rel: []const u8) ?u32 {
        const at = self.lowerBound(rel);
        if (at < self.count() and std.mem.eql(u8, self.path(at), rel)) return at;
        var i = at;
        while (i > 0 and foldedEqual(self.path(i - 1), rel)) i -= 1;
        if (i < self.count() and foldedEqual(self.path(i), rel)) return i;
        return null;
    }

    pub fn lowerBound(self: View, key: []const u8) u32 {
        var lo: u32 = 0;
        var hi: u32 = self.count();
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (foldedOrder(self.path(mid), key) == .lt) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    pub fn dirRange(self: View, prefix: []const u8) [2]u32 {
        if (prefix.len == 0) return .{ 0, self.count() };
        var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        if (prefix.len >= buf.len) return .{ 0, 0 };
        @memcpy(buf[0..prefix.len], prefix);
        buf[prefix.len] = '/';
        const lo = self.lowerBound(buf[0 .. prefix.len + 1]);
        buf[prefix.len] = '/' + 1;
        const hi = self.lowerBound(buf[0 .. prefix.len + 1]);
        return .{ lo, @max(lo, hi) };
    }
};

fn foldedEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (foldByte(x) != foldByte(y)) return false;
    }
    return true;
}

pub fn underFolded(p: []const u8, prefix: []const u8) bool {
    if (p.len <= prefix.len) return false;
    for (p[0..prefix.len], prefix) |x, y| {
        if (foldByte(x) != foldByte(y)) return false;
    }
    return foldByte(p[prefix.len]) == '/';
}

const testing = std.testing;

fn sampleInputs() [4]Input {
    return .{
        .{ .path = "README.md", .stamp = .{ .mtime_ns = 1, .ctime_ns = 2, .size = 9 }, .state = .indexed, .content = "# needle\n", .digest = [_]u8{1} ** 32, .spans = "doc" },
        .{ .path = "src/a.ts", .stamp = .{ .mtime_ns = 3, .ctime_ns = 4, .size = 21 }, .state = .indexed, .content = "export const needle=1", .digest = [_]u8{2} ** 32 },
        .{ .path = "src/b.bin", .stamp = .{ .mtime_ns = 5, .ctime_ns = 6, .size = 4 }, .state = .binary },
        .{ .path = "src/c.ts", .stamp = .{ .mtime_ns = 7, .ctime_ns = 8, .size = 12 }, .state = .indexed, .content = "const other", .digest = [_]u8{3} ** 32 },
    };
}

test "index v4: a built image opens, verifies and answers paths, content and postings" {
    const inputs = sampleInputs();
    const image = try build(testing.allocator, &inputs, .{ .written_ns = 42, .git_stamp = .{ .mtime_ns = 7, .size = 8, .id = 9 } }, null);
    defer testing.allocator.free(image);
    const view = try View.open(image);
    try testing.expect(view.verify(null));
    try testing.expectEqual(@as(u32, 4), view.count());
    try testing.expectEqualStrings("src/a.ts", view.path(1));
    try testing.expectEqualStrings("export const needle=1", view.contentOf(1));
    try testing.expectEqualStrings("doc", view.spansOf(0));
    try testing.expectEqual(FileState.binary, view.stateOf(2));
    try testing.expectEqual(@as(u64, 9), view.gitStamp().?.id);
    try testing.expectEqual(@as(?u32, 3), view.find("SRC/C.TS"));
    try testing.expectEqual(@as(?u32, null), view.find("src/d.ts"));
    const range = view.dirRange("src");
    try testing.expectEqual([2]u32{ 1, 4 }, range);
    const list = view.list(trigram.of('e', 'e', 'd')).?;
    var it = list.iterator();
    try testing.expectEqual(@as(?u32, 0), it.next());
    try testing.expectEqual(@as(?u32, 1), it.next());
    try testing.expectEqual(@as(?u32, null), it.next());
    try testing.expect(view.list(trigram.of('z', 'z', 'z')) == null);
}

test "index v4: any flipped byte is refused at open or at verify, and another version is named" {
    const inputs = sampleInputs();
    const image = try build(testing.allocator, &inputs, .{ .written_ns = 1, .git_stamp = null }, null);
    defer testing.allocator.free(image);
    const copy = try testing.allocator.alignedAlloc(u8, .fromByteUnits(alignment), image.len);
    defer testing.allocator.free(copy);
    for (0..image.len) |i| {
        @memcpy(copy, image);
        copy[i] ^= 0x10;
        const refused = if (View.open(copy)) |view| !view.verify(null) else |_| true;
        errdefer std.debug.print("byte {d} of {d} was not refused\n", .{ i, image.len });
        try testing.expect(refused);
    }
    @memcpy(copy, image);
    copy[7] = 3;
    try testing.expectError(error.Version, View.open(copy));
}

test "index v4: inputs out of folded path order are refused" {
    var inputs = sampleInputs();
    std.mem.swap(Input, &inputs[1], &inputs[3]);
    try testing.expectError(error.Unsorted, build(testing.allocator, &inputs, .{ .written_ns = 1, .git_stamp = null }, null));
}

test "index v4: a directory range covers every path under it and no sibling with the same prefix" {
    const paths = [_][]const u8{ "a/x.ts", "ab/y.ts", "lib-extra/three.ts", "lib/one.ts", "lib/sub/two.ts", "libz.ts" };
    var inputs: [paths.len]Input = undefined;
    for (paths, &inputs) |p, *in| in.* = .{ .path = p, .stamp = .{ .mtime_ns = 0, .ctime_ns = 0, .size = 0 }, .state = .indexed };
    const image = try build(testing.allocator, &inputs, .{ .written_ns = 1, .git_stamp = null }, null);
    defer testing.allocator.free(image);
    const view = try View.open(image);
    try testing.expectEqual([2]u32{ 3, 5 }, view.dirRange("lib"));
    try testing.expectEqual([2]u32{ 3, 5 }, view.dirRange("LIB"));
    try testing.expectEqual([2]u32{ 3, 5 }, view.dirRange("lib\\"[0..3]));
    try testing.expectEqual([2]u32{ 0, 1 }, view.dirRange("a"));
    try testing.expectEqual([2]u32{ 4, 5 }, view.dirRange("lib\\sub"));
    const none = view.dirRange("zzz");
    try testing.expectEqual(none[0], none[1]);
}
