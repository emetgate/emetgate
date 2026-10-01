const std = @import("std");
const repo = @import("../platform/repo.zig");
const shadow = @import("../platform/shadow.zig");
const search_index = @import("../platform/search_index.zig");
const search_session = @import("../platform/search_session.zig");
const change_watch = @import("../platform/change_watch.zig");
const worker_pool = @import("../platform/worker_pool.zig");
const tree_cache_mod = @import("../engine/tree_cache.zig");
const symbol = @import("../engine/symbol.zig");
const registry = @import("../engine/lang/registry.zig");
const profile_mod = @import("../engine/lang/profile.zig");
const json_pointer = @import("../engine/lang/json/pointer.zig");
const markdown_heading = @import("../engine/lang/markdown/heading.zig");
const regex_mod = @import("../engine/regex.zig");
const text_query = @import("../engine/text_query.zig");
const ts = @import("../engine/tree_sitter.zig");
const tool_result = @import("tool_result.zig");
const telemetry = @import("telemetry.zig");
const read_tools = @import("read_tools.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;
const Loader = @import("../engine/loader.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;
const ToolResult = tool_result.ToolResult;
const Query = text_query.Query;
const requireString = tool_result.requireString;
const getString = tool_result.getString;
const getBool = tool_result.getBool;
const getStringArray = tool_result.getStringArray;
const success = tool_result.success;
const failure = tool_result.failure;

pub const max_file_bytes = 1024 * 1024;
pub const max_matches = 200;
pub const max_match_text = 200;
pub const max_missing_listed = 20;

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
    return @tagName(kind);
}

const KindSet = std.EnumSet(Kind);

fn parseKinds(kinds: ?[]const Value) !?KindSet {
    const list = kinds orelse return null;
    var set: KindSet = .initEmpty();
    for (list) |v| {
        if (v != .string) return error.UnknownKind;
        set.insert(std.meta.stringToEnum(Kind, v.string) orelse return error.UnknownKind);
    }
    return set;
}

fn kindAllowed(kinds: ?KindSet, kind: Kind) bool {
    const set = kinds orelse return true;
    return set.contains(kind);
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

const Skip = enum { none, large, binary, deleted, unreadable };

const FileWork = struct {
    rel: []const u8,
    entry: ?*const search_index.Entry,
    state: enum { skipped, no_match, fast, slow } = .skipped,
    skip: Skip = .none,
    read: bool = false,
    size: usize = 0,
    bytes: []u8 = &.{},
    hits: std.ArrayList(Pending) = .empty,
    matched_lines: u32 = 0,
    over_budget_lines: u32 = 0,
    filtered: std.EnumArray(Kind, u32) = .initFill(0),
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
    query: *const Query,
    kinds: ?KindSet,
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
    const scratch = shared.gpa.alloc(u32, shared.query.scratchLen()) catch {
        shared.fail(error.OutOfMemory);
        return;
    };
    defer shared.gpa.free(scratch);
    while (true) {
        const i = shared.next.fetchAdd(1, .monotonic);
        if (i >= shared.work.len) return;
        if (shared.failure_lock.load(.acquire)) return;
        scanFile(shared, &shared.work[i], scratch) catch |err| {
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

fn scanFile(shared: *Shared, item: *FileWork, scratch: []u32) !void {
    const gpa = shared.gpa;
    var since: i96 = if (shared.timed) std.Io.Clock.awake.now(shared.io).nanoseconds else 0;
    const abs = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ shared.root, item.rel });
    defer gpa.free(abs);
    const bytes = std.Io.Dir.cwd().readFileAlloc(shared.io, abs, gpa, .limited(max_file_bytes)) catch |err| {
        item.skip = switch (err) {
            error.OutOfMemory => return err,
            error.StreamTooLong => .large,
            error.FileNotFound => .deleted,
            else => .unreadable,
        };
        return;
    };
    item.read = true;
    item.size = bytes.len;
    item.read_ns = lap(shared.io, shared.timed, &since);
    var keep = false;
    defer if (!keep) gpa.free(bytes);
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) {
        item.skip = .binary;
        return;
    }

    const probed = probe(shared.query, scratch, bytes);
    item.probe_ns = lap(shared.io, shared.timed, &since);
    if (!probed.hit) {
        item.over_budget_lines = probed.over_budget;
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

    try collectHits(shared, item, bytes, scratch, fast_spans, fast_doc);
    item.state = .fast;
    item.classify_ns = lap(shared.io, shared.timed, &since);
}

const Probe = struct { hit: bool = false, over_budget: u32 = 0 };

fn probe(query: *const Query, scratch: []u32, bytes: []const u8) Probe {
    var out: Probe = .{};
    if (!query.mayMatchText(bytes)) return out;
    var it = LineIter.init(bytes);
    while (it.next()) |line| {
        switch (query.matchLine(scratch, line.text)) {
            .hit => {
                out.hit = true;
                return out;
            },
            .over_budget => out.over_budget += 1,
            .none => {},
        }
    }
    return out;
}

fn collectHits(shared: *Shared, item: *FileWork, bytes: []const u8, scratch: []u32, spans: ?*const search_index.kind_spans.FileSpans, doc: ?search_index.doc_spans.DocSpans) !void {
    const gpa = shared.gpa;
    var it = LineIter.init(bytes);
    while (it.next()) |line| {
        if (item.hits.items.len > max_matches) return;
        const found = switch (shared.query.matchLine(scratch, line.text)) {
            .none => continue,
            .over_budget => {
                item.over_budget_lines += 1;
                continue;
            },
            .hit => |h| h,
        };
        item.matched_lines += 1;
        const at = line.start + found.col;
        var pending: Pending = .{ .line = line.number, .text = undefined, .kind = .code, .role = null };
        if (spans) |sp| {
            pending.kind = mapKind(search_index.kind_spans.classify(sp.kind_spans, at));
            const enclosing = search_index.kind_spans.enclosing(sp.symbols, at);
            if (enclosing) |sym| pending.hash = sym.hash;
            pending.role = mapRole(search_index.kind_spans.role(enclosing, sp.reference_spans, at, found.text));
            if (!kindAllowed(shared.kinds, pending.kind)) {
                item.filtered.getPtr(pending.kind).* += 1;
                continue;
            }
            if (enclosing) |sym| pending.symbol = try gpa.dupe(u8, sym.ref_text);
        } else if (doc) |d| {
            if (search_index.doc_spans.at(d, at)) |label| switch (d.kind) {
                .json => pending.pointer = try gpa.dupe(u8, label),
                .markdown => pending.heading = label,
            };
        }
        if (!kindAllowed(shared.kinds, pending.kind)) {
            item.filtered.getPtr(pending.kind).* += 1;
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

fn slowFile(gpa: Allocator, io: std.Io, runtime: *Runtime, tree_cache: ?*tree_cache_mod.TreeCache, root: []const u8, query: *const Query, kinds: ?KindSet, item: *FileWork) !void {
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

    const scratch = try gpa.alloc(u32, query.scratchLen());
    defer gpa.free(scratch);
    var it = LineIter.init(bytes);
    while (it.next()) |line| {
        if (item.hits.items.len > max_matches) break;
        const found = switch (query.matchLine(scratch, line.text)) {
            .none => continue,
            .over_budget => {
                item.over_budget_lines += 1;
                continue;
            },
            .hit => |h| h,
        };
        item.matched_lines += 1;
        const at = line.start + found.col;
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
                    pending.role = roleOf(p, snap.tree.root(), at, found.text, enclosing);
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
            item.filtered.getPtr(pending.kind).* += 1;
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
    if (outcome.event_count != 0) event.reason = outcome.events[0].what;
    if (outcome.index_load) |why| event.reason = search_session.rebuildNote(why);
    if (outcome.partial) event.outcome = .partial;
    return success(gpa, &buffer);
}

const Outcome = struct {
    index_load: ?search_index.LoadFailure = null,
    partial: bool = false,
    events: [4]Event = undefined,
    event_count: usize = 0,

    const Event = struct { what: []const u8, err: []const u8 };

    fn record(self: *Outcome, what: []const u8, err: anyerror) void {
        if (self.event_count == self.events.len) return;
        self.events[self.event_count] = .{ .what = what, .err = @errorName(err) };
        self.event_count += 1;
    }
};

const Scope = struct {
    rel: []const u8,
    file: bool,

    fn contains(self: Scope, f: []const u8) bool {
        if (self.file) return change_watch.samePath(f, self.rel);
        return read_tools.inDirectory(f, self.rel);
    }
};

const Missing = struct { path: []const u8, reason: []const u8, lines: u32 = 0 };

const Result = struct {
    groups: std.ArrayList(Group) = .empty,
    missing: std.ArrayList(Missing) = .empty,
    files: usize = 0,
    matched_files: usize = 0,
    matched_lines: usize = 0,
    skipped: std.EnumArray(Skip, usize) = .initFill(0),
    filtered: std.EnumArray(Kind, usize) = .initFill(0),
    truncated: bool = false,

    fn deinit(self: *Result, gpa: Allocator) void {
        for (self.groups.items) |*g| {
            for (g.hits.items) |hit| gpa.free(hit.text);
            gpa.free(g.file);
            if (g.symbol) |s| gpa.free(s);
            if (g.pointer) |s| gpa.free(s);
            if (g.heading) |s| gpa.free(s);
            g.hits.deinit(gpa);
        }
        self.groups.deinit(gpa);
        self.missing.deinit(gpa);
    }

    fn partial(self: Result) bool {
        return self.truncated or self.missing.items.len != 0;
    }

    fn evaluated(self: Result) usize {
        var out = self.files;
        for ([_]Skip{ .large, .binary, .deleted }) |s| out -= self.skipped.get(s);
        return out - self.missing.items.len;
    }
};

const Corpus = struct {
    gpa: Allocator,
    io: std.Io,
    runtime: *Runtime,
    tree_cache: ?*tree_cache_mod.TreeCache,
    pool: ?*worker_pool.Pool,
    root: []const u8,
    files: []const []u8,
    index: ?search_index.Index,
    scope: Scope,
    kinds: ?KindSet,
};

fn renderSearch(gpa: Allocator, io: std.Io, runtime: *Runtime, root: ?[]const u8, tree_cache: ?*tree_cache_mod.TreeCache, session: ?*search_session.Session, pattern: []const u8, dir: []const u8, is_regex: bool, kinds: ?[]const Value, outcome: *Outcome, w: *Writer) !void {
    if (pattern.len == 0) return error.EmptyPattern;
    const kind_set = try parseKinds(kinds);
    var total_timer: ?StageTimer = if (stats_sink != null) StageTimer.start(io) else null;
    var timer: ?StageTimer = if (stats_sink != null) StageTimer.start(io) else null;
    const place = try repo.jail(gpa, io, root, dir);
    defer place.deinit(gpa);
    const scope: Scope = .{ .rel = place.rel, .file = isFile(io, place.abs) };
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
            if (sess.last.save_failure) |err| outcome.record("index_save_failed", err);
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
        const refreshed: ?search_index.RefreshResult = search_index.refresh(gpa, io, place.root, files, previous_index) catch |err| blk: {
            if (err == error.OutOfMemory) return err;
            outcome.record("index_refresh_failed", err);
            break :blk null;
        };
        if (refreshed) |r| owned_index = r.index;
        if (timer) |*t| if (stats_sink) |s| {
            s.index_refresh_ns += t.lap();
            if (refreshed) |r| {
                s.files_index_reused += r.reused;
                s.files_index_recomputed += r.recomputed;
            }
        };
        if (refreshed) |r| if (r.changed) if (index_path) |p| {
            search_index.save(gpa, io, p, r.index, files, null) catch |err| {
                if (err == error.OutOfMemory) return err;
                outcome.record("index_save_failed", err);
            };
        };
        if (timer) |*t| if (stats_sink) |s| {
            s.index_save_ns += t.lap();
        };
    }

    const corpus: Corpus = .{
        .gpa = gpa,
        .io = io,
        .runtime = runtime,
        .tree_cache = tree_cache,
        .pool = if (session) |sess| if (sess.pool.helpers() != 0) &sess.pool else null else null,
        .root = place.root,
        .files = files,
        .index = session_index orelse owned_index,
        .scope = scope,
        .kinds = kind_set,
    };

    var query = if (is_regex) Query.regex(gpa, pattern, null) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidRegex,
    } else try Query.literal(gpa, pattern);
    defer query.deinit(gpa);
    if (timer) |*t| _ = t.lap();
    var result = try runQuery(&corpus, &query, &timer);
    defer result.deinit(gpa);

    var alternatives: ?Query = null;
    defer if (alternatives) |q| q.deinit(gpa);
    if (!is_regex and result.matched_lines == 0 and !result.partial()) {
        alternatives = try Query.alternatives(gpa, pattern);
        if (alternatives) |*alt| {
            var second = try runQuery(&corpus, alt, &timer);
            std.mem.swap(Result, &result, &second);
            second.deinit(gpa);
        }
    }
    outcome.partial = result.partial();

    std.mem.sort(Group, result.groups.items, {}, struct {
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
    try js.objectField("status");
    try js.write(if (result.partial()) "partial" else "complete");
    try js.objectField("pattern");
    try js.write(pattern);
    try js.objectField("regex");
    try js.write(is_regex);
    if (alternatives) |alt| {
        try js.objectField("read_as");
        try js.write("literal alternatives");
        try js.objectField("alternatives");
        try js.write(alt.literals);
    }
    if (kinds) |k| {
        try js.objectField("kinds");
        try js.write(k);
    }
    try js.objectField("scope");
    try js.beginObject();
    try js.objectField("path");
    try js.write(if (place.rel.len == 0) "." else place.rel);
    if (scope.file) {
        try js.objectField("is_file");
        try js.write(true);
    }
    try js.objectField("files");
    try js.write(result.files);
    try js.objectField("evaluated");
    try js.write(result.evaluated());
    for ([_]Skip{ .large, .binary, .deleted }) |s| {
        const n = result.skipped.get(s);
        if (n == 0) continue;
        try js.objectField(switch (s) {
            .large => "skipped_large",
            .binary => "skipped_binary",
            .deleted => "deleted_on_disk",
            else => unreachable,
        });
        try js.write(n);
    }
    try js.endObject();
    try js.objectField("matched_files");
    try js.write(result.matched_files);
    try js.objectField("groups");
    try writeGroups(&js, result.groups.items);
    try js.objectField("truncated");
    try js.write(result.truncated);
    if (result.missing.items.len != 0) {
        try js.objectField("missing");
        try js.beginArray();
        for (result.missing.items[0..@min(result.missing.items.len, max_missing_listed)]) |m| {
            try js.beginObject();
            try js.objectField("path");
            try js.write(m.path);
            try js.objectField("reason");
            try js.write(m.reason);
            if (m.lines != 0) {
                try js.objectField("lines");
                try js.write(m.lines);
            }
            try js.endObject();
        }
        try js.endArray();
        if (result.missing.items.len > max_missing_listed) {
            try js.objectField("missing_more");
            try js.write(result.missing.items.len - max_missing_listed);
        }
    }
    if (result.groups.items.len == 0) {
        var note_buf: [512]u8 = undefined;
        try js.objectField("note");
        try js.write(emptyNote(&note_buf, result, scope, place.rel, query, kinds, alternatives != null));
    }
    if (outcome.index_load) |why| {
        try js.objectField("index");
        try js.write(search_session.rebuildNote(why));
    }
    if (outcome.event_count != 0) {
        try js.objectField("events");
        try js.beginArray();
        for (outcome.events[0..outcome.event_count]) |e| {
            try js.beginObject();
            try js.objectField("what");
            try js.write(e.what);
            try js.objectField("error");
            try js.write(e.err);
            try js.endObject();
        }
        try js.endArray();
    }
    if (stats_sink) |s| {
        if (total_timer) |*t| s.total_ns += t.lap();
        try writeStats(&js, s, files.len);
    }
    try js.endObject();
    try w.writeByte('\n');
}

fn isFile(io: std.Io, abs: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, abs, .{}) catch return false;
    return stat.kind == .file;
}

fn runQuery(corpus: *const Corpus, query: *const Query, timer: *?StageTimer) !Result {
    const gpa = corpus.gpa;
    var result: Result = .{};
    errdefer result.deinit(gpa);
    var work: std.ArrayList(FileWork) = .empty;
    defer {
        for (work.items) |*item| item.deinit(gpa);
        work.deinit(gpa);
    }
    for (corpus.files) |f| {
        if (!corpus.scope.contains(f)) continue;
        repo.refuseInternal(f) catch continue;
        result.files += 1;
        const entry: ?*const search_index.Entry = if (corpus.index) |idx| idx.find(f) else null;
        if (entry) |e| {
            if (!query.mayMatchFile(e.trigrams)) continue;
        }
        try work.append(gpa, .{ .rel = f, .entry = entry });
    }
    if (stats_sink) |s| s.files_candidates += work.items.len;
    if (timer.*) |*t| if (stats_sink) |s| {
        s.filter_ns += t.lap();
    };

    var shared: Shared = .{
        .gpa = gpa,
        .root = corpus.root,
        .query = query,
        .kinds = corpus.kinds,
        .work = work.items,
        .io = corpus.io,
        .timed = stats_sink != null,
    };
    try runWorkers(&shared, corpus.pool);
    if (shared.failure) |err| return err;

    var total_hits: usize = 0;
    for (work.items) |*item| {
        if (stats_sink) |s| {
            s.read_ns += item.read_ns;
            s.probe_ns += item.probe_ns;
            s.classify_ns += item.classify_ns;
            if (item.read) s.files_read += 1;
            s.candidate_bytes += item.size;
        }
        switch (item.skip) {
            .none => {},
            .unreadable => {
                try result.missing.append(gpa, .{ .path = item.rel, .reason = "unreadable" });
                continue;
            },
            else => |s| {
                result.skipped.getPtr(s).* += 1;
                continue;
            },
        }
        switch (item.state) {
            .skipped, .no_match => {},
            .fast => {
                if (stats_sink) |s| s.files_fast_classified += 1;
            },
            .slow => {
                var parse_timer: ?StageTimer = if (stats_sink != null) StageTimer.start(corpus.io) else null;
                try slowFile(gpa, corpus.io, corpus.runtime, corpus.tree_cache, corpus.root, query, corpus.kinds, item);
                if (parse_timer) |*t| if (stats_sink) |s| {
                    s.parse_ns += t.lap();
                    s.files_parsed += 1;
                };
            },
        }
        if (item.over_budget_lines != 0) try result.missing.append(gpa, .{ .path = item.rel, .reason = "regex_step_budget", .lines = item.over_budget_lines });
        if (item.matched_lines != 0) result.matched_files += 1;
        result.matched_lines += item.matched_lines;
        for (std.enums.values(Kind)) |k| result.filtered.getPtr(k).* += item.filtered.get(k);
        if (result.truncated) continue;
        for (item.hits.items) |*pending| {
            if (total_hits >= max_matches) {
                result.truncated = true;
                break;
            }
            try addHit(gpa, &result.groups, item.rel, pending);
            total_hits += 1;
        }
    }
    return result;
}

fn emptyNote(buf: []u8, result: Result, scope: Scope, rel: []const u8, query: Query, kinds: ?[]const Value, tried_alternatives: bool) []const u8 {
    const where: []const u8 = if (rel.len == 0) "." else rel;
    if (result.files == 0) {
        if (scope.file) return std.fmt.bufPrint(buf, "{s} is not a file git tracks, so nothing was searched", .{where}) catch where;
        return std.fmt.bufPrint(buf, "no file git tracks is under {s}, so nothing was searched", .{where}) catch where;
    }
    if (result.matched_lines != 0) {
        var kinds_text: [64]u8 = undefined;
        return std.fmt.bufPrint(buf, "{d} matching line(s) ({d} code, {d} comment, {d} string) were all removed by kinds {s}", .{
            result.matched_lines,
            result.filtered.get(.code),
            result.filtered.get(.comment),
            result.filtered.get(.string),
            kindsList(&kinds_text, kinds),
        }) catch where;
    }
    if (result.partial()) return std.fmt.bufPrint(buf, "no match in the {d} evaluated file(s); {d} file(s) could not be fully evaluated, see missing", .{ result.evaluated(), result.missing.items.len }) catch where;
    if (tried_alternatives) return std.fmt.bufPrint(buf, "no match in {d} file(s) for the literal text, nor for its |-separated parts read as literal alternatives; pass regex:true for a regular expression", .{result.evaluated()}) catch where;
    if (query.mode == .literal) {
        if (text_query.regexSyntax(query.pattern)) |token| {
            return std.fmt.bufPrint(buf, "no match in {d} file(s) for the literal text; it contains regex syntax ({s}), pass regex:true to search it as a regular expression", .{ result.evaluated(), token }) catch where;
        }
    }
    return std.fmt.bufPrint(buf, "no match in {d} file(s)", .{result.evaluated()}) catch where;
}

fn kindsList(buf: []u8, kinds: ?[]const Value) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.writeByte('[') catch return "[...]";
    if (kinds) |list| {
        for (list, 0..) |v, i| {
            if (i != 0) w.writeAll(",") catch return "[...]";
            w.writeAll(if (v == .string) v.string else "?") catch return "[...]";
        }
    }
    w.writeByte(']') catch return "[...]";
    return w.buffered();
}

fn writeGroups(js: *std.json.Stringify, groups: []const Group) !void {
    try js.beginArray();
    for (groups) |g| {
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
}

fn writeStats(js: *std.json.Stringify, s: *const Stats, tracked: usize) !void {
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
    try js.write(tracked);
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
