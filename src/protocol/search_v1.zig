const std = @import("std");
const repo = @import("../platform/repo.zig");
const shadow = @import("../platform/shadow.zig");
const search_index = @import("../platform/search_index.zig");
const search_session = @import("../platform/search_session.zig");
const worker_pool = @import("../platform/worker_pool.zig");
const tree_cache_mod = @import("../engine/tree_cache.zig");
const symbol = @import("../engine/symbol.zig");
const registry = @import("../engine/lang/registry.zig");
const profile_mod = @import("../engine/lang/profile.zig");
const json_pointer = @import("../engine/lang/json/pointer.zig");
const markdown_heading = @import("../engine/lang/markdown/heading.zig");
const regex_mod = @import("../engine/regex.zig");
const regex_hint = @import("../engine/regex_hint.zig");
const ts = @import("../engine/tree_sitter.zig");
const wire = @import("wire.zig");
const tool_result = @import("tool_result.zig");
const telemetry = @import("telemetry.zig");
const read_tools = @import("read_tools.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;
const Loader = @import("../engine/loader.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;
const ToolResult = tool_result.ToolResult;
const requireString = tool_result.requireString;
const getString = tool_result.getString;
const getBool = tool_result.getBool;
const getStringArray = tool_result.getStringArray;
const success = tool_result.success;
const failure = tool_result.failure;

pub const max_file_bytes = 1024 * 1024;
pub const max_matches = 200;
pub const max_match_text = 200;
pub const min_gram_len = 3;
pub const regex_budget: u64 = 2_000_000;

pub const Stats = struct {
    session: ?search_session.Report = null,
    filter_ns: u64 = 0,
    candidate_bytes: usize = 0,
    sync_ns: u64 = 0,
    jail_ns: u64 = 0,
    list_ns: u64 = 0,
    total_ns: u64 = 0,
    index_load_ns: u64 = 0,
    index_refresh_ns: u64 = 0,
    index_save_ns: u64 = 0,
    read_ns: u64 = 0,
    probe_ns: u64 = 0,
    parse_ns: u64 = 0,
    classify_ns: u64 = 0,
    json_ns: u64 = 0,
    files_candidates: usize = 0,
    files_read: usize = 0,
    files_parsed: usize = 0,
    files_fast_classified: usize = 0,
    files_index_reused: usize = 0,
    files_index_recomputed: usize = 0,
};

pub threadlocal var stats_sink: ?*Stats = null;

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
}

fn currentPid() u32 {
    return switch (@import("builtin").os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        else => 0,
    };
}

const StageTimer = struct {
    io: std.Io,
    last_ns: i96,

    fn start(io: std.Io) StageTimer {
        return .{ .io = io, .last_ns = std.Io.Clock.awake.now(io).nanoseconds };
    }

    fn lap(self: *StageTimer) u64 {
        const now_ns = std.Io.Clock.awake.now(self.io).nanoseconds;
        const delta = now_ns - self.last_ns;
        self.last_ns = now_ns;
        return @intCast(delta);
    }
};

pub const Kind = enum { code, comment, string };

fn kindName(kind: Kind) []const u8 {
    return switch (kind) {
        .code => "code",
        .comment => "comment",
        .string => "string",
    };
}

fn kindAllowed(kinds: ?[]const Value, kind: Kind) bool {
    const list = kinds orelse return true;
    for (list) |v| {
        if (v != .string) continue;
        if (std.mem.eql(u8, v.string, kindName(kind))) return true;
    }
    return false;
}

const Role = enum { definition, reference };

fn roleName(role: Role) []const u8 {
    return switch (role) {
        .definition => "definition",
        .reference => "reference",
    };
}

const Hit = struct {
    line: u32,
    text: []const u8,
    kind: Kind,
    role: ?Role,
};

const Group = struct {
    file: []const u8,
    symbol: ?[]const u8,
    pointer: ?[]const u8,
    heading: ?[]const u8,
    hash: ?symbol.Hash,
    hits: std.ArrayList(Hit),

    fn priority(self: Group) u8 {
        var has_definition = false;
        for (self.hits.items) |h| {
            if (h.role == .definition) has_definition = true;
        }
        return if (has_definition) 0 else 1;
    }
};

fn nodeAt(root: ts.Node, offset: u32) ts.Node {
    var current = root;
    while (true) {
        var next: ?ts.Node = null;
        var i: u32 = 0;
        while (current.child(i)) |c| : (i += 1) {
            if (offset >= c.startByte() and offset < c.endByte()) {
                next = c;
                break;
            }
        }
        current = next orelse return current;
    }
}

fn mapKind(k: ?search_index.kind_spans.Kind) Kind {
    return switch (k orelse return .code) {
        .comment => .comment,
        .string => .string,
    };
}

fn mapRole(r: ?search_index.kind_spans.Role) ?Role {
    return switch (r orelse return null) {
        .definition => .definition,
        .reference => .reference,
    };
}

fn classify(profile: *const profile_mod.Profile, root: ts.Node, offset: u32) Kind {
    var node: ?ts.Node = nodeAt(root, offset);
    while (node) |n| : (node = n.parent()) {
        if (profile.isComment(n.kind())) return .comment;
        for (profile.strings) |k| {
            if (std.mem.eql(u8, k, n.kind())) return .string;
        }
    }
    return .code;
}

fn enclosingSymbol(table: *const symbol.Table, offset: u32) ?*const symbol.Symbol {
    var best: ?*const symbol.Symbol = null;
    for (table.symbols) |*sym| {
        if (offset < sym.node.startByte() or offset >= sym.node.endByte()) continue;
        if (best == null or (sym.node.endByte() - sym.node.startByte()) < (best.?.node.endByte() - best.?.node.startByte())) {
            best = sym;
        }
    }
    return best;
}

fn roleOf(profile: *const profile_mod.Profile, root: ts.Node, offset: u32, matched_text: []const u8, enclosing: ?*const symbol.Symbol) ?Role {
    if (enclosing) |sym| {
        if (offset >= sym.node.startByte() and offset < sym.body.startByte() and std.mem.eql(u8, matched_text, sym.ref.name)) {
            return .definition;
        }
    }
    var node: ?ts.Node = nodeAt(root, offset);
    while (node) |n| : (node = n.parent()) {
        if (std.mem.eql(u8, n.kind(), profile.call.node)) {
            if (n.childByField(profile.call.function_field)) |callee| {
                if (offset >= callee.startByte() and offset < callee.endByte()) return .reference;
            }
        }
    }
    const leaf = nodeAt(root, offset);
    for (profile.reference_names) |k| {
        if (std.mem.eql(u8, k, leaf.kind())) return .reference;
    }
    return null;
}

const Matcher = union(enum) {
    literal: []const u8,
    regex: struct { re: regex_mod.Regex, budget: u64 },

    fn find(self: *Matcher, gpa: Allocator, line: []const u8) !bool {
        switch (self.*) {
            .literal => |pat| return std.mem.indexOf(u8, line, pat) != null,
            .regex => |*r| return r.re.isMatch(gpa, line, &r.budget) catch |err| switch (err) {
                error.BudgetExceeded => false,
                else => |e| return e,
            },
        }
    }
};

const Pending = struct {
    line: u32,
    text: []u8,
    kind: Kind,
    role: ?Role,
    symbol: ?[]u8 = null,
    hash: ?symbol.Hash = null,
    pointer: ?[]u8 = null,
    heading: ?[]const u8 = null,
    heading_owned: bool = false,

    fn deinit(self: *Pending, gpa: Allocator) void {
        gpa.free(self.text);
        if (self.symbol) |x| gpa.free(x);
        if (self.pointer) |x| gpa.free(x);
        if (self.heading_owned) if (self.heading) |x| gpa.free(x);
        self.* = undefined;
    }
};

const FileWork = struct {
    rel: []const u8,
    entry: ?*const search_index.Entry,
    state: enum { skipped, no_match, fast, slow } = .skipped,
    read: bool = false,
    size: usize = 0,
    bytes: []u8 = &.{},
    hits: std.ArrayList(Pending) = .empty,
    read_ns: u64 = 0,
    probe_ns: u64 = 0,
    classify_ns: u64 = 0,

    fn deinit(self: *FileWork, gpa: Allocator) void {
        for (self.hits.items) |*h| h.deinit(gpa);
        self.hits.deinit(gpa);
        if (self.bytes.len != 0) gpa.free(self.bytes);
        self.bytes = &.{};
    }
};

const Shared = struct {
    gpa: Allocator,
    io: std.Io,
    root: []const u8,
    pattern: []const u8,
    hint: []const u8,
    re: ?*const regex_mod.Regex,
    kinds: ?[]const Value,
    work: []FileWork,
    timed: bool,
    next: std.atomic.Value(usize) = .init(0),
    failure: ?anyerror = null,
    failure_lock: std.atomic.Value(bool) = .init(false),

    fn fail(self: *Shared, err: anyerror) void {
        if (self.failure_lock.swap(true, .acq_rel)) return;
        self.failure = err;
    }
};

pub const max_workers = 8;
const min_files_per_worker = 4;

fn workerCount(files: usize) usize {
    if (files <= min_files_per_worker) return 1;
    const cpus = std.Thread.getCpuCount() catch 1;
    return @max(1, @min(@min(cpus, max_workers), files / min_files_per_worker));
}

fn workerTask(ctx: *anyopaque) void {
    workerLoop(@ptrCast(@alignCast(ctx)));
}

fn runWorkers(shared: *Shared, pool: ?*worker_pool.Pool) !void {
    const count = workerCount(shared.work.len);
    if (pool) |p| {
        p.run(count - 1, workerTask, shared);
        return;
    }
    var threads: [max_workers]std.Thread = undefined;
    var spawned: usize = 0;
    defer for (threads[0..spawned]) |t| t.join();
    while (spawned + 1 < count) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{}, workerLoop, .{shared}) catch break;
    }
    workerLoop(shared);
}

fn workerLoop(shared: *Shared) void {
    var scratch: []u32 = &.{};
    defer if (scratch.len != 0) shared.gpa.free(scratch);
    if (shared.re) |re| {
        scratch = shared.gpa.alloc(u32, re.scratchLen()) catch {
            shared.fail(error.OutOfMemory);
            return;
        };
    }
    var budget: u64 = regex_budget;
    while (true) {
        const i = shared.next.fetchAdd(1, .monotonic);
        if (i >= shared.work.len) return;
        if (shared.failure_lock.load(.acquire)) return;
        scanFile(shared, &shared.work[i], scratch, &budget) catch |err| {
            shared.fail(err);
            return;
        };
    }
}

fn lap(io: std.Io, timed: bool, since: *i96) u64 {
    if (!timed) return 0;
    const now = std.Io.Clock.awake.now(io).nanoseconds;
    defer since.* = now;
    return @intCast(now - since.*);
}

fn lineMatches(shared: *Shared, line: []const u8, scratch: []u32, budget: *u64) bool {
    const re = shared.re orelse return std.mem.indexOf(u8, line, shared.pattern) != null;
    if (shared.hint.len != 0 and std.mem.indexOf(u8, line, shared.hint) == null) return false;
    return re.isMatchIn(scratch, line, budget) catch false;
}

fn scanFile(shared: *Shared, item: *FileWork, scratch: []u32, budget: *u64) !void {
    const gpa = shared.gpa;
    var since: i96 = if (shared.timed) std.Io.Clock.awake.now(shared.io).nanoseconds else 0;
    const abs = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ shared.root, item.rel });
    defer gpa.free(abs);
    const bytes = std.Io.Dir.cwd().readFileAlloc(shared.io, abs, gpa, .limited(max_file_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    item.read = true;
    item.size = bytes.len;
    item.read_ns = lap(shared.io, shared.timed, &since);
    var keep = false;
    defer if (!keep) gpa.free(bytes);
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return;

    const any = if (shared.re == null) std.mem.indexOf(u8, bytes, shared.pattern) != null else blk: {
        if (shared.hint.len != 0 and std.mem.indexOf(u8, bytes, shared.hint) == null) break :blk false;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (lineMatches(shared, line, scratch, budget)) break :blk true;
        }
        break :blk false;
    };
    item.probe_ns = lap(shared.io, shared.timed, &since);
    if (!any) {
        item.state = .no_match;
        return;
    }

    var fast_spans: ?*const search_index.kind_spans.FileSpans = null;
    var fast_doc: ?search_index.doc_spans.DocSpans = null;
    var hash_ok = false;
    if (item.entry) |entry| {
        if (entry.content_hash) |ch| {
            const live = symbol.fileHash(bytes);
            if (std.mem.eql(u8, &ch, &live)) {
                hash_ok = true;
                if (entry.spans) |*sp| fast_spans = sp;
                fast_doc = entry.doc;
            }
        }
    }
    const profile = registry.forPath(item.rel);
    const needs_structure = profile != null or search_index.doc_spans.kindFor(item.rel) != null;
    const structured = fast_spans != null or fast_doc != null;
    if (needs_structure and !(hash_ok and structured)) {
        item.state = .slow;
        item.bytes = bytes;
        keep = true;
        return;
    }

    try collectHits(shared, item, bytes, scratch, budget, fast_spans, fast_doc);
    item.state = .fast;
    item.classify_ns = lap(shared.io, shared.timed, &since);
}

fn collectHits(shared: *Shared, item: *FileWork, bytes: []const u8, scratch: []u32, budget: *u64, spans: ?*const search_index.kind_spans.FileSpans, doc: ?search_index.doc_spans.DocSpans) !void {
    const gpa = shared.gpa;
    const literal = if (shared.re == null) shared.pattern else "";
    var it = LineIter.init(bytes);
    while (it.next()) |line| {
        if (item.hits.items.len > max_matches) return;
        if (!lineMatches(shared, line.text, scratch, budget)) continue;
        const col: u32 = if (literal.len != 0) @intCast(std.mem.indexOf(u8, line.text, literal) orelse 0) else 0;
        const at = line.start + col;
        var pending: Pending = .{ .line = line.number, .text = undefined, .kind = .code, .role = null };
        if (spans) |sp| {
            pending.kind = mapKind(search_index.kind_spans.classify(sp.kind_spans, at));
            const enclosing = search_index.kind_spans.enclosing(sp.symbols, at);
            if (enclosing) |sym| pending.hash = sym.hash;
            pending.role = mapRole(search_index.kind_spans.role(enclosing, sp.reference_spans, at, literal));
            if (!kindAllowed(shared.kinds, pending.kind)) continue;
            if (enclosing) |sym| pending.symbol = try gpa.dupe(u8, sym.ref_text);
        } else if (doc) |d| {
            if (search_index.doc_spans.at(d, at)) |label| switch (d.kind) {
                .json => pending.pointer = try gpa.dupe(u8, label),
                .markdown => pending.heading = label,
            };
        }
        if (!kindAllowed(shared.kinds, pending.kind)) {
            if (pending.pointer) |x| gpa.free(x);
            continue;
        }
        pending.text = try gpa.dupe(u8, read_tools.utf8Prefix(std.mem.trim(u8, line.text, " \t\r"), max_match_text));
        try item.hits.append(gpa, pending);
    }
}

const LineIter = struct {
    bytes: []const u8,
    pos: usize = 0,
    number: u32 = 0,
    done: bool = false,

    const Line = struct { text: []const u8, start: u32, number: u32 };

    fn init(bytes: []const u8) LineIter {
        return .{ .bytes = bytes };
    }

    fn next(self: *LineIter) ?Line {
        if (self.done) return null;
        const start = self.pos;
        const end = std.mem.indexOfScalarPos(u8, self.bytes, start, '\n') orelse blk: {
            self.done = true;
            break :blk self.bytes.len;
        };
        self.pos = end + 1;
        self.number += 1;
        return .{ .text = self.bytes[start..end], .start = @intCast(start), .number = self.number };
    }
};

fn slowFile(gpa: Allocator, io: std.Io, runtime: *Runtime, tree_cache: ?*tree_cache_mod.TreeCache, root: []const u8, pattern: []const u8, is_regex: bool, compiled: ?regex_mod.Regex, kinds: ?[]const Value, item: *FileWork) !void {
    const bytes = item.bytes;
    const f = item.rel;
    const abs = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ root, f });
    defer gpa.free(abs);
    const profile = registry.forPath(f);
    var snapshot: ?*Loader.Snapshot = null;
    var owned_snapshot = false;
    defer if (owned_snapshot) snapshot.?.destroy();
    var table: ?*const symbol.Table = null;
    if (profile) |p| {
        snapshot = if (tree_cache) |cache|
            cache.loadWithSource(runtime, io, abs, bytes) catch |err| blk2: {
                if (err == error.OutOfMemory) return err;
                break :blk2 null;
            }
        else blk: {
            owned_snapshot = true;
            const owned_source = gpa.dupe(u8, bytes) catch |err| break :blk (if (err == error.OutOfMemory) return err else null);
            break :blk Loader.Snapshot.fromSource(runtime, p, owned_source) catch null;
        };
        if (snapshot == null) owned_snapshot = false;
        if (snapshot) |snap| table = snap.symbols() catch null;
    }

    var json_tree: ?ts.Tree = null;
    defer if (json_tree) |t| t.deinit();
    var md_tree: ?ts.Tree = null;
    defer if (md_tree) |t| t.deinit();
    if (profile == null and std.ascii.endsWithIgnoreCase(f, ".json")) {
        const parser = ts.Parser.create();
        defer parser.deinit();
        json_tree = parser.parseIn(json_pointer.grammar(), bytes) catch null;
        if (json_tree) |t| if (t.root().hasError()) {
            t.deinit();
            json_tree = null;
        };
    } else if (profile == null and std.ascii.endsWithIgnoreCase(f, ".md")) {
        const parser = ts.Parser.create();
        defer parser.deinit();
        md_tree = parser.parseIn(markdown_heading.grammar(), bytes) catch null;
    }

    const scratch: []u32 = if (compiled) |re| try gpa.alloc(u32, re.scratchLen()) else &.{};
    defer if (compiled != null) gpa.free(scratch);
    var budget: u64 = regex_budget;
    const hint = if (is_regex) regex_hint.longestLiteralChunk(pattern) else pattern;
    const literal = if (is_regex) "" else pattern;
    var it = LineIter.init(bytes);
    while (it.next()) |line| {
        if (item.hits.items.len > max_matches) break;
        const matched = if (compiled) |re| blk: {
            if (hint.len != 0 and std.mem.indexOf(u8, line.text, hint) == null) break :blk false;
            break :blk re.isMatchIn(scratch, line.text, &budget) catch false;
        } else std.mem.indexOf(u8, line.text, pattern) != null;
        if (!matched) continue;
        const col: u32 = if (literal.len != 0) @intCast(std.mem.indexOf(u8, line.text, literal) orelse 0) else 0;
        const at = line.start + col;
        var pending: Pending = .{ .line = line.number, .text = undefined, .kind = .code, .role = null };
        errdefer {
            if (pending.symbol) |x| gpa.free(x);
            if (pending.pointer) |x| gpa.free(x);
        }
        if (profile) |p| {
            if (snapshot) |snap| {
                pending.kind = classify(p, snap.tree.root(), at);
                if (table) |t| {
                    const enclosing = enclosingSymbol(t, at);
                    if (enclosing) |sym| {
                        pending.symbol = try std.fmt.allocPrint(gpa, "{f}", .{sym.ref});
                        pending.hash = sym.hash;
                    }
                    pending.role = roleOf(p, snap.tree.root(), at, literal, enclosing);
                }
            }
        } else if (json_tree) |t| {
            pending.pointer = json_pointer.pointerAt(gpa, t, at) catch null;
        } else if (md_tree) |t| {
            if (markdown_heading.sectionAt(gpa, t, at) catch null) |h| {
                pending.heading = try gpa.dupe(u8, h);
                pending.heading_owned = true;
            }
        }
        if (!kindAllowed(kinds, pending.kind)) {
            if (pending.symbol) |x| gpa.free(x);
            if (pending.pointer) |x| gpa.free(x);
            if (pending.heading_owned) gpa.free(pending.heading.?);
            continue;
        }
        pending.text = try gpa.dupe(u8, read_tools.utf8Prefix(std.mem.trim(u8, line.text, " \t\r"), max_match_text));
        try item.hits.append(gpa, pending);
    }
}

fn addHit(gpa: Allocator, groups: *std.ArrayList(Group), f: []const u8, pending: *Pending) !void {
    var target: ?*Group = null;
    for (groups.items) |*g| {
        if (!std.mem.eql(u8, g.file, f)) continue;
        const same = (pending.symbol == null and g.symbol == null and pending.pointer == null and g.pointer == null and pending.heading == null and g.heading == null) or
            (pending.symbol != null and g.symbol != null and std.mem.eql(u8, pending.symbol.?, g.symbol.?)) or
            (pending.pointer != null and g.pointer != null and std.mem.eql(u8, pending.pointer.?, g.pointer.?)) or
            (pending.heading != null and g.heading != null and std.mem.eql(u8, pending.heading.?, g.heading.?));
        if (same) {
            target = g;
            break;
        }
    }
    if (target == null) {
        try groups.append(gpa, .{
            .file = try gpa.dupe(u8, f),
            .symbol = if (pending.symbol) |x| try gpa.dupe(u8, x) else null,
            .pointer = if (pending.pointer) |x| try gpa.dupe(u8, x) else null,
            .heading = if (pending.heading) |x| try gpa.dupe(u8, x) else null,
            .hash = pending.hash,
            .hits = .empty,
        });
        target = &groups.items[groups.items.len - 1];
    }
    try target.?.hits.append(gpa, .{ .line = pending.line, .text = pending.text, .kind = pending.kind, .role = pending.role });
    pending.text = pending.text[0..0];
}

pub fn callSearch(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, root: ?[]const u8, tree_cache: ?*tree_cache_mod.TreeCache, session: ?*search_session.Session) !ToolResult {
    const pattern = try requireString(args, "pattern");
    const dir = if (args) |a| getString(a, "dir") orelse "." else ".";
    const is_regex = if (args) |a| getBool(a, "regex") orelse false else false;
    const kinds = if (args) |a| getStringArray(a, "kinds") else null;
    const want_stats = if (args) |a| getBool(a, "stats") orelse false else false;
    event.label = "search";
    event.file = dir;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    var stats: Stats = .{};
    if (want_stats) stats_sink = &stats;
    defer if (want_stats) {
        stats_sink = null;
    };
    var outcome: Outcome = .{};
    renderSearch(gpa, io, runtime, root, tree_cache, session, pattern, dir, is_regex, kinds, &outcome, &buffer.writer) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err, event);
    };
    if (outcome.index_load) |why| event.reason = search_session.rebuildNote(why);
    return success(gpa, &buffer);
}

const Outcome = struct {
    index_load: ?search_index.LoadFailure = null,
};

fn renderSearch(gpa: Allocator, io: std.Io, runtime: *Runtime, root: ?[]const u8, tree_cache: ?*tree_cache_mod.TreeCache, session: ?*search_session.Session, pattern: []const u8, dir: []const u8, is_regex: bool, kinds: ?[]const Value, outcome: *Outcome, w: *Writer) !void {
    if (pattern.len == 0) return error.EmptyPattern;
    var total_timer: ?StageTimer = if (stats_sink != null) StageTimer.start(io) else null;
    var timer: ?StageTimer = if (stats_sink != null) StageTimer.start(io) else null;
    const place = try repo.jail(gpa, io, root, dir);
    defer place.deinit(gpa);
    if (timer) |*t| if (stats_sink) |s| {
        s.jail_ns += t.lap();
    };

    var session_files: ?[]const []u8 = null;
    var session_index: ?search_index.Index = null;
    if (session) |sess| {
        if (sess.owns(place.root) or sess.root == null) {
            try sess.prepare(place.root);
            session_files = sess.files.?;
            session_index = sess.index;
            outcome.index_load = sess.last.index_load;
            if (stats_sink) |s| {
                s.session = sess.last;
                s.list_ns += sess.last.list_ns;
                s.index_refresh_ns += sess.last.refresh_ns;
                s.sync_ns += sess.last.sync_ns;
                s.files_index_reused += sess.last.reused;
                s.files_index_recomputed += sess.last.recomputed;
            }
            if (timer) |*t| _ = t.lap();
        }
    }

    const owned_files: ?[][]u8 = if (session_files == null) try shadow.trackedFiles(gpa, io, place.root) else null;
    defer if (owned_files) |f| {
        shadow.freeFileList(gpa, f);
        gpa.free(f);
    };
    const files: []const []u8 = session_files orelse owned_files.?;
    if (session_files == null) if (timer) |*t| if (stats_sink) |s| {
        s.list_ns += t.lap();
    };

    var owned_index: ?search_index.Index = null;
    defer if (owned_index) |idx| idx.deinit();
    if (session_files == null) {
        const index_path = search_index.indexPath(gpa, place.root) catch null;
        defer if (index_path) |p| gpa.free(p);
        const loaded: search_index.Loaded = if (index_path) |p| search_index.load(gpa, io, p) else .{ .failed = .io };
        const previous_index: ?search_index.Index = switch (loaded) {
            .index => |index| index,
            .failed => |why| blk: {
                outcome.index_load = why;
                break :blk null;
            },
        };
        defer if (previous_index) |idx| idx.deinit();
        if (timer) |*t| if (stats_sink) |s| {
            s.index_load_ns += t.lap();
        };
        const refreshed: ?search_index.RefreshResult = search_index.refresh(gpa, io, place.root, files, previous_index) catch null;
        if (refreshed) |r| owned_index = r.index;
        if (timer) |*t| if (stats_sink) |s| {
            s.index_refresh_ns += t.lap();
            if (refreshed) |r| {
                s.files_index_reused += r.reused;
                s.files_index_recomputed += r.recomputed;
            }
        };
        if (refreshed) |r| {
            if (r.changed) {
                if (owned_index) |idx| {
                    if (index_path) |p| search_index.save(gpa, io, p, idx, files, null) catch {};
                }
            }
        }
        if (timer) |*t| if (stats_sink) |s| {
            s.index_save_ns += t.lap();
        };
    }
    const fresh_index: ?search_index.Index = session_index orelse owned_index;

    const gram_query: ?[]u24 = blk: {
        const literal_hint = if (is_regex) regex_hint.longestLiteralChunk(pattern) else pattern;
        if (literal_hint.len < min_gram_len) break :blk null;
        break :blk try search_index.trigramsOfAlloc(gpa, literal_hint);
    };
    defer if (gram_query) |g| gpa.free(g);

    var compiled: ?regex_mod.Regex = if (is_regex) blk: {
        var diag: regex_mod.Diagnostic = .{};
        break :blk regex_mod.Regex.compile(gpa, pattern, &diag) catch return error.InvalidRegex;
    } else null;
    defer if (compiled) |re| re.deinit(gpa);

    var groups: std.ArrayList(Group) = .empty;
    defer {
        for (groups.items) |*g| g.hits.deinit(gpa);
        groups.deinit(gpa);
    }
    var total_hits: usize = 0;
    var truncated = false;
    var files_scanned: usize = 0;
    var files_total: usize = 0;

    if (timer) |*t| _ = t.lap();
    var work: std.ArrayList(FileWork) = .empty;
    defer {
        for (work.items) |*item| item.deinit(gpa);
        work.deinit(gpa);
    }
    for (files) |f| {
        if (!read_tools.inDirectory(f, place.rel)) continue;
        files_total += 1;
        repo.refuseInternal(f) catch continue;
        const entry: ?*const search_index.Entry = if (fresh_index) |idx| idx.find(f) else null;
        if (gram_query) |needles| {
            if (entry) |e| {
                if (!search_index.isSupersetSorted(e.trigrams, needles)) continue;
            }
        }
        try work.append(gpa, .{ .rel = f, .entry = entry });
    }
    if (stats_sink) |s| s.files_candidates += work.items.len;
    if (timer) |*t| if (stats_sink) |s| {
        s.filter_ns += t.lap();
    };

    var shared: Shared = .{
        .gpa = gpa,
        .root = place.root,
        .pattern = pattern,
        .hint = if (is_regex) regex_hint.longestLiteralChunk(pattern) else pattern,
        .re = if (compiled) |*re| re else null,
        .kinds = kinds,
        .work = work.items,
        .io = io,
        .timed = stats_sink != null,
    };
    try runWorkers(&shared, if (session) |sess| if (sess.pool.helpers() != 0) &sess.pool else null else null);
    if (shared.failure) |err| return err;

    outer: for (work.items) |*item| {
        if (stats_sink) |s| {
            s.read_ns += item.read_ns;
            s.probe_ns += item.probe_ns;
            s.classify_ns += item.classify_ns;
            if (item.read) s.files_read += 1;
            s.candidate_bytes += item.size;
        }
        switch (item.state) {
            .skipped, .no_match => continue,
            .fast => {
                if (stats_sink) |s| s.files_fast_classified += 1;
            },
            .slow => {
                var parse_timer: ?StageTimer = if (stats_sink != null) StageTimer.start(io) else null;
                try slowFile(gpa, io, runtime, tree_cache, place.root, pattern, is_regex, compiled, kinds, item);
                if (parse_timer) |*t| if (stats_sink) |s| {
                    s.parse_ns += t.lap();
                    s.files_parsed += 1;
                };
            },
        }
        files_scanned += 1;
        for (item.hits.items) |*pending| {
            if (total_hits >= max_matches) {
                truncated = true;
                break :outer;
            }
            try addHit(gpa, &groups, item.rel, pending);
            total_hits += 1;
        }
    }

    std.mem.sort(Group, groups.items, {}, struct {
        fn lessThan(_: void, a: Group, b: Group) bool {
            return a.priority() < b.priority();
        }
    }.lessThan);

    var json_timer: ?StageTimer = if (stats_sink != null) StageTimer.start(io) else null;
    defer if (json_timer) |*t| if (stats_sink) |s| {
        s.json_ns += t.lap();
    };
    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("pattern");
    try js.write(pattern);
    try js.objectField("regex");
    try js.write(is_regex);
    try js.objectField("files_total");
    try js.write(files_total);
    try js.objectField("files_scanned");
    try js.write(files_scanned);
    try js.objectField("groups");
    try js.beginArray();
    for (groups.items) |g| {
        try js.beginObject();
        try js.objectField("file");
        try js.write(g.file);
        if (g.symbol) |s| {
            try js.objectField("symbol");
            try js.write(s);
            try js.objectField("hash");
            const hex = symbol.formatHash(g.hash.?);
            try js.write(hex[0..]);
        }
        if (g.pointer) |p| {
            try js.objectField("pointer");
            try js.write(p);
        }
        if (g.heading) |h| {
            try js.objectField("heading");
            try js.write(h);
        }
        try js.objectField("hits");
        try js.beginArray();
        for (g.hits.items) |hit| {
            try js.beginObject();
            try js.objectField("line");
            try js.write(hit.line);
            try js.objectField("kind");
            try js.write(kindName(hit.kind));
            if (hit.role) |role| {
                try js.objectField("role");
                try js.write(roleName(role));
            }
            try js.objectField("text");
            try js.write(hit.text);
            try js.endObject();
        }
        try js.endArray();
        try js.endObject();
    }
    try js.endArray();
    try js.objectField("truncated");
    try js.write(truncated);
    if (outcome.index_load) |why| {
        try js.objectField("index");
        try js.write(search_session.rebuildNote(why));
    }
    if (stats_sink) |s| {
        if (total_timer) |*t| s.total_ns += t.lap();
        try js.objectField("stats");
        try js.beginObject();
        try js.objectField("jail_ms");
        try js.write(nsToMs(s.jail_ns));
        try js.objectField("list_ms");
        try js.write(nsToMs(s.list_ns));
        try js.objectField("sync_ms");
        try js.write(nsToMs(s.sync_ns));
        try js.objectField("filter_ms");
        try js.write(nsToMs(s.filter_ns));
        try js.objectField("candidate_bytes");
        try js.write(s.candidate_bytes);
        if (s.session) |r| {
            try js.objectField("refresh_mode");
            try js.write(@tagName(r.mode));
            try js.objectField("refresh_reason");
            try js.write(r.reason);
            if (r.index_load) |why| {
                try js.objectField("index_load");
                try js.write(@tagName(why));
            }
            try js.objectField("dirty_paths");
            try js.write(r.dirty_paths);
            try js.objectField("updated");
            try js.write(r.updated);
            try js.objectField("list_reused");
            try js.write(r.list_reused);
            try js.objectField("refresh_stamp_ms");
            try js.write(nsToMs(r.stamp_ns));
            try js.objectField("refresh_work_ms");
            try js.write(nsToMs(r.work_ns));
        }
        try js.objectField("total_ms");
        try js.write(nsToMs(s.total_ns));
        try js.objectField("pid");
        try js.write(currentPid());
        try js.objectField("tracked_files");
        try js.write(files.len);
        try js.objectField("files_candidates");
        try js.write(s.files_candidates);
        try js.objectField("files_read");
        try js.write(s.files_read);
        try js.objectField("files_parsed");
        try js.write(s.files_parsed);
        try js.objectField("files_fast_classified");
        try js.write(s.files_fast_classified);
        try js.objectField("index_reused");
        try js.write(s.files_index_reused);
        try js.objectField("index_recomputed");
        try js.write(s.files_index_recomputed);
        try js.objectField("index_load_ms");
        try js.write(nsToMs(s.index_load_ns));
        try js.objectField("index_refresh_ms");
        try js.write(nsToMs(s.index_refresh_ns));
        try js.objectField("index_save_ms");
        try js.write(nsToMs(s.index_save_ns));
        try js.objectField("read_ms");
        try js.write(nsToMs(s.read_ns));
        try js.objectField("probe_ms");
        try js.write(nsToMs(s.probe_ns));
        try js.objectField("parse_ms");
        try js.write(nsToMs(s.parse_ns));
        try js.objectField("classify_ms");
        try js.write(nsToMs(s.classify_ns));
        try js.objectField("json_ms");
        try js.write(nsToMs(s.json_ns));
        try js.endObject();
    }
    try js.endObject();
    try w.writeByte('\n');

    for (groups.items) |*g| {
        for (g.hits.items) |hit| gpa.free(hit.text);
        gpa.free(g.file);
        if (g.symbol) |s| gpa.free(s);
        if (g.pointer) |s| gpa.free(s);
        if (g.heading) |s| gpa.free(s);
    }
}
