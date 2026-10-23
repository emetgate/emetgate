const std = @import("std");
const repo = @import("../platform/repo.zig");
const search_index = @import("../platform/search_index.zig");
const index_file = @import("../platform/search_index_file.zig");
const search_session = @import("../platform/search_session.zig");
const change_watch = @import("../platform/change_watch.zig");
const worker_pool = @import("../platform/worker_pool.zig");
const open_nowait = @import("../platform/open_nowait.zig");
const rg_search = @import("../platform/rg_search.zig");
const search_text = @import("search_text.zig");
const tree_cache_mod = @import("../engine/tree_cache.zig");
const symbol = @import("../engine/symbol.zig");
const registry = @import("../engine/lang/registry.zig");
const profile_mod = @import("../engine/lang/profile.zig");
const json_pointer = @import("../engine/lang/json/pointer.zig");
const markdown_heading = @import("../engine/lang/markdown/heading.zig");
const postings = @import("../engine/postings.zig");
const span_codec = @import("../engine/span_codec.zig");
const text_query = @import("../engine/text_query.zig");
const answer = @import("../engine/answer.zig");
const trigram = @import("../engine/trigram.zig");
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
const View = index_file.View;
const FileState = index_file.FileState;
const requireString = tool_result.requireString;
const getString = tool_result.getString;
const getBool = tool_result.getBool;
const getStringArray = tool_result.getStringArray;
const success = tool_result.success;
const failure = tool_result.failure;

pub const max_file_bytes = search_index.max_indexed_file_bytes;
pub const max_matches = 200;
pub const reply_budget = 5000;
pub const max_offset = 100_000;
pub const max_match_text = 200;
pub const max_missing_listed = 20;
const chunk_files = 64;

pub const Stats = struct {
    session: ?search_session.Report = null,
    filter_ns: u64 = 0,
    candidate_bytes: usize = 0,
    sync_ns: u64 = 0,
    jail_ns: u64 = 0,
    list_ns: u64 = 0,
    total_ns: u64 = 0,
    index_refresh_ns: u64 = 0,
    match_ns: u64 = 0,
    parse_ns: u64 = 0,
    json_ns: u64 = 0,
    root_ns: u64 = 0,
    files_candidates: usize = 0,
    files_parsed: usize = 0,
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
    return @tagName(role);
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
        for (self.hits.items) |h| {
            if (h.role == .definition) return 0;
        }
        return 1;
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

fn classifyLive(profile: *const profile_mod.Profile, root: ts.Node, offset: u32) Kind {
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
    heading: ?[]u8 = null,

    fn deinit(self: *Pending, gpa: Allocator) void {
        gpa.free(self.text);
        if (self.symbol) |x| gpa.free(x);
        if (self.pointer) |x| gpa.free(x);
        if (self.heading) |x| gpa.free(x);
        self.* = undefined;
    }
};

const FileWork = struct {
    path: []const u8,
    content: []const u8,
    spans: []const u8,
    hits: std.ArrayList(Pending) = .empty,
    matched_lines: u32 = 0,
    over_budget_lines: u32 = 0,
    filtered: std.EnumArray(Kind, u32) = .initFill(0),
    needs_live_parse: bool = false,
    corrupt_spans: bool = false,
    unclassified: bool = false,
    most_steps: u64 = 0,
    extra_matches: u32 = 0,
    capped: bool = false,

    fn deinit(self: *FileWork, gpa: Allocator) void {
        for (self.hits.items) |*h| h.deinit(gpa);
        self.hits.deinit(gpa);
    }
};

const Shared = struct {
    gpa: Allocator,
    query: *const Query,
    kinds: ?KindSet,
    hit_limit: usize,
    width: usize,
    count_only: bool = false,
    work: []FileWork,
    next: std.atomic.Value(usize) = .init(0),
    failure: ?anyerror = null,
    failure_lock: std.atomic.Value(bool) = .init(false),

    fn fail(self: *Shared, err: anyerror) void {
        if (self.failure_lock.swap(true, .acq_rel)) return;
        self.failure = err;
    }
};

fn workerTask(ctx: *anyopaque) void {
    const shared: *Shared = @ptrCast(@alignCast(ctx));
    const scratch = shared.gpa.alloc(u32, shared.query.scratchLen()) catch {
        shared.fail(error.OutOfMemory);
        return;
    };
    defer shared.gpa.free(scratch);
    while (true) {
        const i = shared.next.fetchAdd(1, .monotonic);
        if (i >= shared.work.len) return;
        if (shared.failure_lock.load(.acquire)) return;
        matchFile(shared, &shared.work[i], scratch) catch |err| {
            shared.fail(err);
            return;
        };
    }
}

const Line = struct { text: []const u8, start: u32, number: u32 };

const LineCursor = struct {
    bytes: []const u8,
    query: *const Query,
    pos: usize = 0,
    counted_to: usize = 0,
    number: u32 = 1,

    fn next(self: *LineCursor) ?Line {
        if (self.pos > self.bytes.len) return null;
        var start = self.pos;
        if (self.query.literals.len != 0) {
            var first: ?usize = null;
            for (self.query.literals) |lit| {
                const at = std.mem.indexOfPos(u8, self.bytes, self.pos, lit) orelse continue;
                if (first == null or at < first.?) first = at;
            }
            const at = first orelse {
                self.pos = self.bytes.len + 1;
                return null;
            };
            start = if (std.mem.lastIndexOfScalar(u8, self.bytes[0..at], '\n')) |nl| nl + 1 else 0;
            if (start < self.pos) start = self.pos;
        } else if (start == self.bytes.len and start != 0) {
            self.pos = self.bytes.len + 1;
            return null;
        }
        const end = std.mem.indexOfScalarPos(u8, self.bytes, start, '\n') orelse self.bytes.len;
        self.number += @intCast(std.mem.count(u8, self.bytes[self.counted_to..start], "\n"));
        self.counted_to = start;
        self.pos = end + 1;
        const text_end = if (end > start and self.bytes[end - 1] == '\r') end - 1 else end;
        return .{ .text = self.bytes[start..text_end], .start = @intCast(start), .number = self.number };
    }
};

fn matchFile(shared: *Shared, item: *FileWork, scratch: []u32) !void {
    const gpa = shared.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var decoded: ?span_codec.Decoded = null;
    var cursor: LineCursor = .{ .bytes = item.content, .query = shared.query };
    while (cursor.next()) |line| {
        const counting = shared.count_only or item.hits.items.len > shared.hit_limit;
        if (counting and shared.kinds != null) {
            item.capped = true;
            return;
        }
        const found = switch (shared.query.matchLineCounting(scratch, line.text, &item.most_steps)) {
            .none => continue,
            .over_budget => {
                item.over_budget_lines += 1;
                continue;
            },
            .hit => |h| h,
        };
        item.matched_lines += 1;
        if (counting) {
            item.extra_matches += 1;
            continue;
        }
        if (decoded == null) {
            decoded = if (item.spans.len == 0) .{ .spans = null, .doc = null } else span_codec.decode(arena_state.allocator(), item.spans) catch |err| switch (err) {
                error.OutOfMemory => return err,
                error.Corrupt => blk: {
                    item.corrupt_spans = true;
                    break :blk .{ .spans = null, .doc = null };
                },
            };
            const parsed = item.content.len <= search_index.max_parsed_file_bytes;
            const wants_spans = registry.forPath(item.path) != null and decoded.?.spans == null;
            const wants_doc = search_index.doc_spans.kindFor(item.path) != null and decoded.?.doc == null;
            if (!parsed and wants_spans) item.unclassified = true;
            if (parsed and (wants_spans or wants_doc)) {
                item.needs_live_parse = true;
                item.matched_lines = 0;
                item.over_budget_lines = 0;
                return;
            }
        }
        const at = line.start + found.col;
        var pending: Pending = .{ .line = line.number, .text = undefined, .kind = .code, .role = null };
        errdefer {
            if (pending.symbol) |x| gpa.free(x);
            if (pending.pointer) |x| gpa.free(x);
            if (pending.heading) |x| gpa.free(x);
        }
        if (decoded.?.spans) |sp| {
            pending.kind = mapKind(search_index.kind_spans.classify(sp.kind_spans, at));
            const enclosing = search_index.kind_spans.enclosing(sp.symbols, at);
            if (enclosing) |sym| pending.hash = sym.hash;
            pending.role = mapRole(search_index.kind_spans.role(enclosing, sp.reference_spans, at, found.text));
            if (kindAllowed(shared.kinds, pending.kind)) {
                if (enclosing) |sym| pending.symbol = try gpa.dupe(u8, sym.ref_text);
            }
        } else if (decoded.?.doc) |d| {
            if (search_index.doc_spans.at(d, at)) |label| switch (d.kind) {
                .json => pending.pointer = try gpa.dupe(u8, label),
                .markdown => pending.heading = try gpa.dupe(u8, label),
            };
        }
        if (!kindAllowed(shared.kinds, pending.kind)) {
            item.filtered.getPtr(pending.kind).* += 1;
            if (pending.symbol) |x| gpa.free(x);
            if (pending.pointer) |x| gpa.free(x);
            if (pending.heading) |x| gpa.free(x);
            continue;
        }
        pending.text = try search_text.snippet(gpa, line.text, found.col, shared.width);
        try item.hits.append(gpa, pending);
    }
}

fn liveFile(gpa: Allocator, io: std.Io, runtime: *Runtime, tree_cache: ?*tree_cache_mod.TreeCache, root: []const u8, query: *const Query, kinds: ?KindSet, hit_limit: usize, width: usize, item: *FileWork) !void {
    const bytes = item.content;
    const f = item.path;
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
        if (snapshot) |snap| table = snap.symbols() catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => null,
        };
        item.unclassified = snapshot == null or snapshot.?.tree.root().hasError();
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
    var cursor: LineCursor = .{ .bytes = bytes, .query = query };
    while (cursor.next()) |line| {
        const counting = item.hits.items.len > hit_limit;
        if (counting and kinds != null) {
            item.capped = true;
            break;
        }
        const found = switch (query.matchLineCounting(scratch, line.text, &item.most_steps)) {
            .none => continue,
            .over_budget => {
                item.over_budget_lines += 1;
                continue;
            },
            .hit => |h| h,
        };
        item.matched_lines += 1;
        if (counting) {
            item.extra_matches += 1;
            continue;
        }
        const at = line.start + found.col;
        var pending: Pending = .{ .line = line.number, .text = undefined, .kind = .code, .role = null };
        errdefer {
            if (pending.symbol) |x| gpa.free(x);
            if (pending.pointer) |x| gpa.free(x);
            if (pending.heading) |x| gpa.free(x);
        }
        if (profile) |p| {
            if (snapshot) |snap| {
                pending.kind = classifyLive(p, snap.tree.root(), at);
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
            pending.pointer = json_pointer.pointerAt(gpa, t, at) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => null,
            };
        } else if (md_tree) |t| {
            if (try markdown_heading.sectionAt(gpa, t, at)) |h| pending.heading = try gpa.dupe(u8, h);
        }
        if (!kindAllowed(kinds, pending.kind)) {
            item.filtered.getPtr(pending.kind).* += 1;
            if (pending.symbol) |x| gpa.free(x);
            if (pending.pointer) |x| gpa.free(x);
            if (pending.heading) |x| gpa.free(x);
            continue;
        }
        pending.text = try search_text.snippet(gpa, line.text, found.col, width);
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

pub const Format = enum { json, text };

pub const Face = struct {
    format: Format = .json,
    internals: bool = true,
};

pub fn callSearch(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, root: ?[]const u8, tree_cache: ?*tree_cache_mod.TreeCache, session: ?*search_session.Session) !ToolResult {
    return callSearchAs(gpa, io, runtime, args, event, root, tree_cache, session, .{});
}

pub fn callSearchAs(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, root: ?[]const u8, tree_cache: ?*tree_cache_mod.TreeCache, session: ?*search_session.Session, face: Face) !ToolResult {
    const format = if (face.internals) parseFormat(args, face.format) catch |err| return failAs(gpa, face.format, err, event) else face.format;
    event.footer = format != .text;
    const pattern = requireString(args, "pattern") catch |err| return failAs(gpa, format, err, event);
    const dir = if (args) |a| getString(a, "dir") orelse "." else ".";
    const is_regex = if (args) |a| getBool(a, "regex") orelse false else false;
    const kinds = if (args) |a| getStringArray(a, "kinds") else null;
    const want_stats = face.internals and flag(args, "stats");
    const want_certificate = face.internals and flag(args, "certificate");
    event.label = "search";
    event.file = dir;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    const full = parseDetail(args) catch |err| return failAs(gpa, format, err, event);
    const offset = parseOffset(args) catch |err| return failAs(gpa, format, err, event);
    var stats: Stats = .{};
    if (want_stats) stats_sink = &stats;
    defer if (want_stats) {
        stats_sink = null;
    };
    var outcome: Outcome = .{ .detail = .init(gpa) };
    defer outcome.detail.deinit();
    const request: Request = .{ .pattern = pattern, .dir = dir, .is_regex = is_regex, .kinds = kinds, .certificate = want_certificate or want_stats, .full = full, .offset = offset, .format = format };
    renderSearch(gpa, io, runtime, root, tree_cache, session, request, &outcome, &buffer.writer) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (outcome.refusal.len != 0) event.reason = outcome.refusal;
        if (format == .text) return textFailure(gpa, err, outcome.detail.written(), event);
        return failure(gpa, &buffer, err, event);
    };
    if (outcome.refusal.len != 0) {
        event.fail("InconsistentCertificate");
        event.reason = outcome.refusal;
        return .{ .text = try tool_result.dupTrim(gpa, buffer.written()), .is_error = true };
    }
    if (outcome.event_count != 0) event.reason = outcome.events[0].what;
    if (outcome.index_load) |why| event.reason = search_session.rebuildNote(why);
    if (outcome.partial) event.outcome = .partial;
    return success(gpa, &buffer);
}

const Request = struct {
    pattern: []const u8,
    dir: []const u8,
    is_regex: bool,
    kinds: ?[]const Value,
    certificate: bool,
    full: bool = false,
    offset: usize = 0,
    format: Format = .json,

    fn width(self: Request) usize {
        return if (self.format == .text) search_text.text_width else search_text.json_width;
    }
};

fn parseFormat(args: ?Value, default_format: Format) !Format {
    const a = args orelse return default_format;
    const field = tool_result.getField(a, "format") orelse {
        if (flag(args, "certificate") or flag(args, "stats")) return .json;
        return default_format;
    };
    if (field != .string) return error.UnknownFormat;
    return std.meta.stringToEnum(Format, field.string) orelse error.UnknownFormat;
}

fn flag(args: ?Value, name: []const u8) bool {
    const a = args orelse return false;
    return getBool(a, name) orelse false;
}

fn failAs(gpa: Allocator, format: Format, err: anyerror, event: *telemetry.Event) !ToolResult {
    if (format == .text) return textFailure(gpa, err, "", event);
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    return failure(gpa, &buffer, err, event);
}

fn textFailure(gpa: Allocator, err: anyerror, detail: []const u8, event: *telemetry.Event) !ToolResult {
    event.fail(@errorName(err));
    event.footer = false;
    const text = if (detail.len != 0)
        try std.fmt.allocPrint(gpa, "error: {s}: {s}", .{ @errorName(err), detail })
    else
        try std.fmt.allocPrint(gpa, "error: {s}", .{@errorName(err)});
    return .{ .text = text, .is_error = true };
}

fn parseDetail(args: ?Value) !bool {
    const a = args orelse return false;
    const field = tool_result.getField(a, "detail") orelse return false;
    if (field != .string) return error.UnknownDetail;
    if (std.mem.eql(u8, field.string, "full")) return true;
    if (std.mem.eql(u8, field.string, "compact")) return false;
    return error.UnknownDetail;
}

fn parseOffset(args: ?Value) !usize {
    const a = args orelse return 0;
    const field = tool_result.getField(a, "offset") orelse return 0;
    if (field != .integer or field.integer < 0 or field.integer > max_offset) return error.InvalidOffset;
    return @intCast(field.integer);
}

const Outcome = struct {
    index_load: ?search_index.LoadFailure = null,
    partial: bool = false,
    refusal: []const u8 = "",
    events: [4]Event = undefined,
    event_count: usize = 0,
    detail: std.Io.Writer.Allocating,

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

const Result = struct {
    groups: std.ArrayList(Group) = .empty,
    missing: std.ArrayList(answer.Missing) = .empty,
    excluded_paths: std.ArrayList(answer.Excluded) = .empty,
    listed: u32 = 0,
    indexed: u32 = 0,
    excluded: answer.Exclusions = .initFill(0),
    hits: usize = 0,
    matched_lines: usize = 0,
    filtered: std.EnumArray(Kind, usize) = .initFill(0),
    truncated: bool = false,
    cut_file: ?[]const u8 = null,
    unrepresented: u32 = 0,
    largest_file: u64 = 0,
    most_steps: u64 = 0,
    total: usize = 0,
    total_exact: bool = true,
    delegated: bool = false,

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
        self.excluded_paths.deinit(gpa);
    }

    fn partial(self: Result) bool {
        return self.missing.items.len != 0;
    }

    fn hidden(self: Result) usize {
        var total: usize = 0;
        for (std.enums.values(Kind)) |k| total += self.filtered.get(k);
        return total;
    }

    fn missingFiles(self: Result) u32 {
        var total: u32 = 0;
        for (self.missing.items) |m| total += m.files;
        return total;
    }

    fn evaluated(self: Result) ?u32 {
        var lost: u32 = 0;
        for (self.missing.items) |m| switch (m.reason) {
            .budget, .match_limit, .unclassified => lost += m.files,
            .too_large, .unreadable, .vanished, .unresolved, .changed_since_snapshot => {},
        };
        return std.math.sub(u32, self.indexed, lost) catch null;
    }

    fn account(self: *Result, gpa: Allocator, path: []const u8, state: FileState, size: u64, want_paths: bool) !bool {
        const rule: ?answer.Rule = switch (state) {
            .indexed => {
                self.largest_file = @max(self.largest_file, size);
                self.indexed += 1;
                return false;
            },
            .binary => .binary,
            .large => .too_large,
            .deleted => {
                try self.missing.append(gpa, .{ .path = path, .reason = .vanished });
                return true;
            },
            .unreadable, .link => {
                try self.missing.append(gpa, .{ .path = path, .reason = .unreadable });
                return true;
            },
        };
        self.excluded.getPtr(rule.?).* += 1;
        if (want_paths) try self.excluded_paths.append(gpa, .{ .path = path, .rule = rule.? });
        return true;
    }

    fn internal(self: *Result, gpa: Allocator, path: []const u8, want_paths: bool) !void {
        self.excluded.getPtr(.internal).* += 1;
        if (want_paths) try self.excluded_paths.append(gpa, .{ .path = path, .rule = .internal });
    }
};

const Corpus = struct {
    gpa: Allocator,
    io: std.Io,
    runtime: *Runtime,
    tree_cache: ?*tree_cache_mod.TreeCache,
    pool: ?*worker_pool.Pool,
    root: []const u8,
    view: ?*const View,
    delta: *const search_session.Delta,
    scope: Scope,
    kinds: ?KindSet,
    want_paths: bool,
    hit_limit: usize,
    width: usize,
};

fn renderSearch(gpa: Allocator, io: std.Io, runtime: *Runtime, root: ?[]const u8, tree_cache: ?*tree_cache_mod.TreeCache, session: ?*search_session.Session, request: Request, outcome: *Outcome, w: *Writer) !void {
    const pattern = request.pattern;
    if (pattern.len == 0) return error.EmptyPattern;
    const kind_set = try parseKinds(request.kinds);
    var total_timer: ?StageTimer = if (stats_sink != null) StageTimer.start(io) else null;
    var timer: ?StageTimer = if (stats_sink != null) StageTimer.start(io) else null;
    const place = try repo.jail(gpa, io, root, request.dir);
    defer place.deinit(gpa);
    const scope: Scope = .{ .rel = place.rel, .file = isFile(place.abs) };
    if (timer) |*t| if (stats_sink) |s| {
        s.jail_ns += t.lap();
    };

    var temporary: ?search_session.Session = null;
    defer if (temporary) |*t| t.deinit();
    const sess: *search_session.Session = blk: {
        if (session) |s| if (s.owns(place.root) or s.root == null) break :blk s;
        temporary = search_session.Session.init(gpa, io, place.root, .{});
        break :blk &temporary.?;
    };
    try sess.prepare(place.root);
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

    var root_key_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const root_key = rootKey(&root_key_buf, scope);

    const corpus: Corpus = .{
        .gpa = gpa,
        .io = io,
        .runtime = runtime,
        .tree_cache = tree_cache,
        .pool = sess.poolPtr(),
        .root = place.root,
        .view = sess.view(),
        .delta = &sess.delta,
        .scope = scope,
        .kinds = kind_set,
        .want_paths = request.certificate,
        .hit_limit = max_matches + request.offset,
        .width = request.width(),
    };

    var compiled: ?Query = if (request.is_regex) Query.regex(gpa, pattern, null) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => null,
    } else try Query.literal(gpa, pattern);
    defer if (compiled) |q| q.deinit(gpa);
    const delegated: Query = .{ .mode = .regex, .pattern = pattern, .literals = &.{}, .grams = &.{} };
    const query: *const Query = if (compiled) |*q| q else &delegated;
    var result = if (compiled != null) try runQuery(&corpus, query, &timer) else try delegateQuery(&corpus, pattern, &outcome.detail.writer);
    defer result.deinit(gpa);

    var alternatives: ?Query = null;
    defer if (alternatives) |q| q.deinit(gpa);
    if (!request.is_regex and result.matched_lines == 0 and !result.partial()) {
        alternatives = try Query.alternatives(gpa, pattern);
        if (alternatives) |*alt| {
            var second = try runQuery(&corpus, alt, &timer);
            std.mem.swap(Result, &result, &second);
            second.deinit(gpa);
        }
    }
    const used_query: *const Query = if (alternatives) |*alt| alt else query;

    var root_timer: ?StageTimer = if (stats_sink != null) StageTimer.start(io) else null;
    const snapshot_root = try sess.scopeRoot(root_key, place.rel, scope.file);
    if (root_timer) |*t| if (stats_sink) |s| {
        s.root_ns += t.lap();
    };
    std.mem.sort(answer.Excluded, result.excluded_paths.items, {}, struct {
        fn less(_: void, a: answer.Excluded, b: answer.Excluded) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.less);

    try rankGroups(gpa, result.groups.items, used_query);
    var shown: std.ArrayList(Shown) = .empty;
    defer shown.deinit(gpa);
    const page = try pageGroups(gpa, result.groups.items, request.offset, if (request.full) null else reply_budget, request.format, &shown);
    const cut = try cutFiles(gpa, &result, shown.items);
    if (cut != 0) try addMatchLimit(gpa, &result, cut);

    const evaluated = result.evaluated() orelse return error.InconsistentCertificate;
    var prefix_buf: [std.fs.max_path_bytes]u8 = undefined;
    const prefix = slashed(&prefix_buf, place.rel);
    var budgets_buf: [3]answer.Budget = undefined;
    var budget_count: usize = 0;
    budgets_buf[budget_count] = .{ .limit = .file_bytes, .max = search_index.max_indexed_file_bytes, .used = @min(result.largest_file, search_index.max_indexed_file_bytes) };
    budget_count += 1;
    budgets_buf[budget_count] = .{ .limit = .matches, .max = corpus.hit_limit, .used = result.hits };
    budget_count += 1;
    if (used_query.re != null) {
        budgets_buf[budget_count] = .{ .limit = .steps, .max = text_query.line_budget, .used = @min(result.most_steps, text_query.line_budget) };
        budget_count += 1;
    }
    const cert: answer.Certificate = .{
        .snapshot = .{ .barrier = sess.barrier, .root = snapshot_root },
        .scope = .{ .prefix = prefix, .listed = result.listed, .excluded = result.excluded, .evaluated = evaluated },
        .semantics = .{ .text = .{
            .pattern = pattern,
            .mode = if (request.is_regex) .regex else .literal,
            .kinds = if (kind_set) |set| answerKinds(set) else .initFull(),
            .filtered = @intCast(result.hidden()),
        } },
        .budgets = budgets_buf[0..budget_count],
        .excluded_paths = if (request.certificate) result.excluded_paths.items else &.{},
    };
    const SearchAnswer = answer.Answer(void);
    const verdict = SearchAnswer.finish({}, cert, result.missing.items);
    var line: std.Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    try verdict.writeStatus(&line.writer, page.shown, "matches");
    switch (verdict) {
        .refused => |r| {
            outcome.refusal = r.detail;
            if (request.format == .text) {
                try w.print("refused: {s}", .{line.written()});
                return;
            }
            var refusal: std.json.Stringify = .{ .writer = w };
            try refusal.beginObject();
            try refusal.objectField("answer");
            try refusal.write(line.written());
            try refusal.objectField("status");
            try refusal.write("refused");
            try refusal.objectField("error");
            try refusal.write(@errorName(r.code));
            try refusal.endObject();
            try w.writeByte('\n');
            return;
        },
        .complete, .partial => {},
    }
    outcome.partial = verdict.status() == .partial;

    if (request.format == .text) {
        var note_buf: [512]u8 = undefined;
        const note: []const u8 = if (result.groups.items.len == 0) emptyNote(&note_buf, result, scope, place.rel, query.*, request.kinds, alternatives != null) else "";
        try writeText(gpa, w, &result, shown.items, page, verdict, request, if (alternatives) |alt| alt.literals else null, outcome, note);
        return;
    }

    var json_timer: ?StageTimer = if (stats_sink != null) StageTimer.start(io) else null;
    defer if (json_timer) |*t| if (stats_sink) |s| {
        s.json_ns += t.lap();
    };
    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("answer");
    try js.write(line.written());
    try js.objectField("status");
    try js.write(@tagName(verdict.status()));
    if (alternatives) |alt| {
        try js.objectField("read_as");
        try js.write("literal alternatives");
        try js.objectField("alternatives");
        try js.write(alt.literals);
    }
    try js.objectField("groups");
    try writeShown(&js, result.groups.items, shown.items);
    try js.objectField("truncated");
    try js.write(result.truncated or page.hidden != 0 or page.skipped != 0);
    try js.objectField("total");
    try js.write(result.total);
    if (!result.total_exact) {
        try js.objectField("total_exact");
        try js.write(false);
    }
    if (result.delegated) {
        try js.objectField("delegated");
        try js.write("rg");
    }
    if (page.hidden != 0 or result.truncated) {
        var more_buf: [256]u8 = undefined;
        try js.objectField("more");
        try js.write(moreLine(&more_buf, page, result.truncated));
    }
    const missing = verdict.missingList();
    if (missing.len != 0) {
        try js.objectField("missing");
        try js.beginArray();
        for (missing[0..@min(missing.len, max_missing_listed)]) |m| {
            try js.beginObject();
            if (m.path) |p| {
                try js.objectField("path");
                try js.write(p);
            } else {
                try js.objectField("files");
                try js.write(m.files);
            }
            try js.objectField("reason");
            try js.write(@tagName(m.reason));
            try js.endObject();
        }
        try js.endArray();
        if (missing.len > max_missing_listed) {
            try js.objectField("missing_more");
            try js.write(missing.len - max_missing_listed);
        }
    }
    if (result.groups.items.len == 0) {
        var note_buf: [512]u8 = undefined;
        try js.objectField("note");
        try js.write(emptyNote(&note_buf, result, scope, place.rel, query.*, request.kinds, alternatives != null));
    } else if (shown.items.len == 0) {
        var note_buf: [128]u8 = undefined;
        try js.objectField("note");
        try js.write(std.fmt.bufPrint(&note_buf, "offset {d} is past the last of the {d} hits", .{ request.offset, result.hits }) catch "offset is past the last hit");
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
    if (request.certificate) {
        try js.objectField("sees");
        try js.write("writes closed or flushed before this search");
        try js.objectField("certificate");
        try verdict.writeCertificate(&js);
    }
    if (stats_sink) |s| {
        if (total_timer) |*t| s.total_ns += t.lap();
        try writeStats(&js, s, if (sess.view()) |v| v.count() else 0);
    }
    try js.endObject();
    try w.writeByte('\n');
}

const Shown = struct { group: usize, lo: usize, hi: usize };

fn writeText(gpa: Allocator, w: *Writer, result: *const Result, shown: []const Shown, page: Page, verdict: anytype, request: Request, alternatives: ?[]const []const u8, outcome: *const Outcome, note: []const u8) !void {
    var lines: std.ArrayList(search_text.Line) = .empty;
    defer lines.deinit(gpa);
    for (shown) |s| {
        const g = result.groups.items[s.group];
        for (g.hits.items[s.lo..s.hi]) |hit| try lines.append(gpa, .{ .file = g.file, .line = hit.line, .text = hit.text, .definition = hit.role == .definition });
    }
    try search_text.writeLines(gpa, w, lines.items);

    const more = page.hidden != 0 or result.truncated;
    const paged = more or page.skipped != 0;
    var missing_count: usize = 0;
    for (verdict.missingList()) |m| {
        if (m.reason != .match_limit) missing_count += 1;
    }
    if (!paged and missing_count == 0 and verdict.status() == .complete) {
        try w.writeAll("\u{2713}");
        if (note.len != 0) try w.print(" {s}", .{note});
    } else {
        try w.writeAll("partial:");
        var first = true;
        if (paged) {
            const plus: []const u8 = if (result.total_exact) "" else "+";
            if (page.shown == 0) {
                try w.print(" offset {d} is past the last of {d}{s} matches", .{ request.offset, result.total, plus });
            } else {
                try w.print(" matches {d}-{d} of {d}{s}", .{ page.skipped + 1, page.skipped + page.shown, result.total, plus });
            }
            first = false;
        }
        var listed: usize = 0;
        for (verdict.missingList()) |m| {
            if (m.reason == .match_limit) continue;
            if (listed == max_missing_listed) {
                try w.print(", {d} more", .{missing_count - listed});
                break;
            }
            try w.writeAll(if (first) " " else ", ");
            first = false;
            if (m.path) |p| {
                try w.print("{s} {s}", .{ p, @tagName(m.reason) });
            } else {
                try w.print("{d} files {s}", .{ m.files, @tagName(m.reason) });
            }
            listed += 1;
        }
        if (note.len != 0) try w.print("; {s}", .{note});
    }
    if (alternatives) |alts| {
        try w.writeAll("; read as literal alternatives: ");
        for (alts, 0..) |a, i| try w.print("{s}{s}", .{ if (i == 0) "" else "|", a });
    }
    if (result.hidden() != 0) try w.print("; {d} hidden by kinds", .{result.hidden()});
    if (outcome.index_load) |why| if (why != .missing) try w.print("; index {s}", .{search_session.rebuildNote(why)});
    for (outcome.events[0..outcome.event_count]) |e| try w.print("; {s} {s}", .{ e.what, e.err });
    if (more) try w.print("; next offset:{d}", .{page.skipped + page.shown});
}

fn delegateQuery(corpus: *const Corpus, pattern: []const u8, diagnostic: *Writer) !Result {
    const gpa = corpus.gpa;
    if (corpus.kinds != null) return error.KindsNeedAnIndexedPattern;
    var result: Result = .{ .delegated = true };
    errdefer result.deinit(gpa);
    const all: Query = .{ .mode = .literal, .pattern = pattern, .literals = &.{}, .grams = &.{} };
    var sources: std.ArrayList(Source) = .empty;
    defer sources.deinit(gpa);
    try collectSources(corpus, &all, &result, &sources);
    const paths = try gpa.alloc([]const u8, sources.items.len);
    defer gpa.free(paths);
    for (sources.items, paths) |src, *path| path.* = src.path;
    if (paths.len == 0) return result;
    const rg = rg_search.find(gpa, corpus.root) catch |err| switch (err) {
        error.RgNotFound => return error.RegexNeedsRipgrep,
        else => |e| return e,
    };
    defer gpa.free(rg);
    var found = try rg_search.search(gpa, corpus.io, rg, corpus.root, pattern, paths, diagnostic);
    defer found.deinit();
    for (found.failed) |index| {
        try result.missing.append(gpa, .{ .path = paths[index], .reason = .unreadable });
        result.indexed -|= 1;
    }
    var represented = try std.DynamicBitSetUnmanaged.initEmpty(gpa, paths.len);
    defer represented.deinit(gpa);
    var unrepresented = try std.DynamicBitSetUnmanaged.initEmpty(gpa, paths.len);
    defer unrepresented.deinit(gpa);
    for (found.hits) |hit| {
        result.total += 1;
        result.matched_lines += 1;
        if (result.hits >= corpus.hit_limit) {
            result.truncated = true;
            if (represented.isSet(hit.file)) result.cut_file = paths[hit.file] else unrepresented.set(hit.file);
            continue;
        }
        var pending: Pending = .{ .line = hit.line, .text = try search_text.snippet(gpa, hit.text, hit.col, corpus.width), .kind = .code, .role = null };
        defer pending.deinit(gpa);
        try addHit(gpa, &result.groups, paths[hit.file], &pending);
        result.hits += 1;
        represented.set(hit.file);
    }
    result.unrepresented = @intCast(unrepresented.count());
    return result;
}

const Page = struct { shown: usize, hidden: usize, skipped: usize, hidden_files: usize };

const GroupKey = struct {
    index: usize,
    rank: u8,
    code: bool,
    file_hits: usize,
    file: []const u8,
    line: u32,

    fn less(_: void, a: GroupKey, b: GroupKey) bool {
        if (a.rank != b.rank) return a.rank < b.rank;
        if (a.code != b.code) return a.code;
        if (a.file_hits != b.file_hits) return a.file_hits > b.file_hits;
        switch (std.mem.order(u8, a.file, b.file)) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
        if (a.line != b.line) return a.line < b.line;
        return a.index < b.index;
    }
};

fn groupRank(g: Group, query: *const Query) u8 {
    if (g.priority() == 0) return 0;
    if (g.symbol) |name| {
        for (query.literals) |lit| {
            if (lit.len != 0 and std.mem.indexOf(u8, name, lit) != null) return 1;
        }
    }
    return 2;
}

fn hasCode(g: Group) bool {
    for (g.hits.items) |h| {
        if (h.kind == .code) return true;
    }
    return false;
}

fn rankGroups(gpa: Allocator, groups: []Group, query: *const Query) !void {
    if (groups.len < 2) return;
    var per_file: std.StringHashMapUnmanaged(usize) = .empty;
    defer per_file.deinit(gpa);
    for (groups) |g| {
        const got = try per_file.getOrPut(gpa, g.file);
        if (!got.found_existing) got.value_ptr.* = 0;
        got.value_ptr.* += g.hits.items.len;
    }
    const keys = try gpa.alloc(GroupKey, groups.len);
    defer gpa.free(keys);
    for (groups, keys, 0..) |g, *k, i| k.* = .{
        .index = i,
        .rank = groupRank(g, query),
        .code = hasCode(g),
        .file_hits = per_file.get(g.file).?,
        .file = g.file,
        .line = if (g.hits.items.len != 0) g.hits.items[0].line else 0,
    };
    std.mem.sort(GroupKey, keys, {}, GroupKey.less);
    const sorted = try gpa.alloc(Group, groups.len);
    defer gpa.free(sorted);
    for (keys, sorted) |k, *s| s.* = groups[k.index];
    @memcpy(groups, sorted);
}

fn pageGroups(gpa: Allocator, groups: []const Group, offset: usize, budget: ?usize, format: Format, shown: *std.ArrayList(Shown)) !Page {
    var sizer: std.Io.Writer.Allocating = .init(gpa);
    defer sizer.deinit();
    var hidden_files: std.StringHashMapUnmanaged(void) = .empty;
    defer hidden_files.deinit(gpa);
    var skip = offset;
    var page: Page = .{ .shown = 0, .hidden = 0, .skipped = 0, .hidden_files = 0 };
    var used: usize = 2;
    var full = false;
    for (groups, 0..) |g, gi| {
        const n = g.hits.items.len;
        if (skip >= n) {
            skip -= n;
            page.skipped += n;
            continue;
        }
        const lo = skip;
        page.skipped += skip;
        skip = 0;
        if (full) {
            page.hidden += n - lo;
            try hidden_files.put(gpa, g.file, {});
            continue;
        }
        const limit = budget orelse {
            try shown.append(gpa, .{ .group = gi, .lo = lo, .hi = n });
            page.shown += n - lo;
            continue;
        };
        var hi = lo;
        var size = if (format == .text) g.file.len + 1 else try groupSize(&sizer, g, lo, lo) + 1;
        while (hi < n) {
            const cost = if (format == .text) textCost(g.hits.items[hi]) else try hitSize(&sizer, g.hits.items[hi]) + @intFromBool(hi != lo);
            const grown = size + cost;
            if (used + grown > limit and !(page.shown == 0 and hi == lo)) break;
            size = grown;
            hi += 1;
        }
        if (hi > lo) {
            try shown.append(gpa, .{ .group = gi, .lo = lo, .hi = hi });
            page.shown += hi - lo;
            used += size;
        }
        if (hi < n) {
            page.hidden += n - hi;
            try hidden_files.put(gpa, g.file, {});
            full = true;
        }
    }
    page.hidden_files = hidden_files.count();
    return page;
}

fn groupSize(sizer: *std.Io.Writer.Allocating, g: Group, lo: usize, hi: usize) !usize {
    sizer.clearRetainingCapacity();
    var js: std.json.Stringify = .{ .writer = &sizer.writer };
    try writeGroupSlice(&js, g, lo, hi);
    return sizer.written().len;
}

fn textCost(hit: Hit) usize {
    return search_text.lineCost(.{ .file = "", .line = hit.line, .text = hit.text, .definition = hit.role == .definition }) + 1;
}

fn hitSize(sizer: *std.Io.Writer.Allocating, hit: Hit) !usize {
    sizer.clearRetainingCapacity();
    var js: std.json.Stringify = .{ .writer = &sizer.writer };
    try writeHit(&js, hit);
    return sizer.written().len;
}

fn cutFiles(gpa: Allocator, result: *const Result, shown: []const Shown) !u32 {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);
    for (result.missing.items) |m| {
        if (m.path) |p| try seen.put(gpa, p, {});
    }
    var cut: std.StringHashMapUnmanaged(void) = .empty;
    defer cut.deinit(gpa);
    var whole = try gpa.alloc(bool, result.groups.items.len);
    defer gpa.free(whole);
    @memset(whole, false);
    for (shown) |s| {
        if (s.lo == 0 and s.hi == result.groups.items[s.group].hits.items.len) whole[s.group] = true;
    }
    for (result.groups.items, whole) |g, all| {
        if (!all and !seen.contains(g.file)) try cut.put(gpa, g.file, {});
    }
    if (result.cut_file) |f| {
        if (!seen.contains(f)) try cut.put(gpa, f, {});
    }
    return @intCast(cut.count() + result.unrepresented);
}

fn addMatchLimit(gpa: Allocator, result: *Result, files: u32) !void {
    for (result.missing.items) |*m| {
        if (m.path == null and m.reason == .match_limit) {
            m.files += files;
            return;
        }
    }
    try result.missing.append(gpa, .{ .path = null, .reason = .match_limit, .files = files });
}

fn moreLine(buf: []u8, page: Page, capped: bool) []const u8 {
    const plus: []const u8 = if (capped) "+" else "";
    return std.fmt.bufPrint(buf, "\u{2026} {d}{s} more hits in {d}{s} files; narrow with dir, kinds or a longer pattern, or pass offset:{d}", .{ page.hidden, plus, page.hidden_files, plus, page.skipped + page.shown }) catch "more hits; narrow with dir, kinds or a longer pattern";
}

fn answerKinds(set: KindSet) answer.Kinds {
    var out: answer.Kinds = .initEmpty();
    var it = set.iterator();
    while (it.next()) |k| out.insert(switch (k) {
        .code => .code,
        .comment => .comment,
        .string => .string,
    });
    return out;
}

fn slashed(buf: []u8, rel: []const u8) []const u8 {
    const n = @min(buf.len, rel.len);
    for (rel[0..n], buf[0..n]) |c, *o| o.* = if (c == '\\') '/' else c;
    return buf[0..n];
}

fn rootKey(buf: []u8, scope: Scope) ?[]const u8 {
    if (scope.rel.len + 1 > buf.len) return null;
    buf[0] = if (scope.file) 'f' else 'd';
    for (scope.rel, buf[1 .. scope.rel.len + 1]) |c, *o| o.* = index_file.foldByte(c);
    return buf[0 .. scope.rel.len + 1];
}

fn isFile(abs: []const u8) bool {
    const stat = open_nowait.stat(abs) catch return false;
    return stat.kind == .file;
}

const Source = struct { path: []const u8, content: []const u8, spans: []const u8 };

fn baseRange(view: *const View, scope: Scope) [2]u32 {
    if (scope.file) {
        const id = view.find(scope.rel) orelse return .{ 0, 0 };
        return .{ id, id + 1 };
    }
    return view.dirRange(scope.rel);
}

fn baseCandidates(gpa: Allocator, view: *const View, query: *const Query, range: [2]u32, out: *std.ArrayList(u32)) !void {
    for (query.literals) |lit| {
        if (lit.len < 3) {
            var id = range[0];
            while (id < range[1]) : (id += 1) try out.append(gpa, id);
            return;
        }
    }
    if (query.literals.len == 0) {
        var id = range[0];
        while (id < range[1]) : (id += 1) try out.append(gpa, id);
        return;
    }
    var lists: std.ArrayList(postings.List) = .empty;
    defer lists.deinit(gpa);
    var union_ids: std.ArrayList(u32) = .empty;
    defer union_ids.deinit(gpa);
    for (query.grams) |grams| {
        lists.clearRetainingCapacity();
        var absent = false;
        for (grams) |g| {
            const l = view.list(g) orelse {
                absent = true;
                break;
            };
            try lists.append(gpa, l);
        }
        if (absent) continue;
        const before = union_ids.items.len;
        try postings.intersect(gpa, lists.items, range[0], range[1], &union_ids);
        if (before != 0 and union_ids.items.len != before) std.mem.sort(u32, union_ids.items, {}, std.sort.asc(u32));
    }
    var last: ?u32 = null;
    for (union_ids.items) |id| {
        if (last != null and last.? == id) continue;
        try out.append(gpa, id);
        last = id;
    }
}

fn internalRange(view: *const View, name: []const u8) [2]u32 {
    return view.dirRange(name);
}

fn collectSources(corpus: *const Corpus, query: *const Query, result: *Result, sources: *std.ArrayList(Source)) !void {
    const gpa = corpus.gpa;
    if (corpus.view) |view| {
        const range = baseRange(view, corpus.scope);
        const git_range = internalRange(view, ".git");
        const own_range = internalRange(view, ".emetgate");
        var id = range[0];
        while (id < range[1]) : (id += 1) {
            if (corpus.delta.isRemoved(id)) continue;
            const p = view.path(id);
            result.listed += 1;
            if ((id >= git_range[0] and id < git_range[1]) or (id >= own_range[0] and id < own_range[1])) {
                try result.internal(gpa, p, corpus.want_paths);
                continue;
            }
            const rec = view.record(id);
            _ = try result.account(gpa, p, view.stateOf(id), rec.size, corpus.want_paths);
        }
        var ids: std.ArrayList(u32) = .empty;
        defer ids.deinit(gpa);
        try baseCandidates(gpa, view, query, range, &ids);
        for (ids.items) |cid| {
            if (corpus.delta.isRemoved(cid) or view.stateOf(cid) != .indexed) continue;
            if ((cid >= git_range[0] and cid < git_range[1]) or (cid >= own_range[0] and cid < own_range[1])) continue;
            try sources.append(gpa, .{ .path = view.path(cid), .content = view.contentOf(cid), .spans = view.spansOf(cid) });
        }
    }
    const base_sources = sources.items.len;
    for (corpus.delta.entries.values()) |*entry| {
        if (!corpus.scope.contains(entry.path)) continue;
        result.listed += 1;
        repo.refuseInternal(entry.path) catch {
            try result.internal(gpa, entry.path, corpus.want_paths);
            continue;
        };
        if (try result.account(gpa, entry.path, entry.state, entry.stamp.size, corpus.want_paths)) continue;
        if (!query.mayMatchFile(entry.grams)) continue;
        try sources.append(gpa, .{ .path = entry.path, .content = entry.content, .spans = entry.spans });
    }
    if (sources.items.len != base_sources) {
        std.mem.sort(Source, sources.items[base_sources..], {}, struct {
            fn less(_: void, a: Source, b: Source) bool {
                return index_file.foldedOrder(a.path, b.path) == .lt;
            }
        }.less);
        mergeSorted(sources.items, base_sources);
    }
}

fn runQuery(corpus: *const Corpus, query: *const Query, timer: *?StageTimer) !Result {
    const gpa = corpus.gpa;
    var result: Result = .{};
    errdefer result.deinit(gpa);
    var sources: std.ArrayList(Source) = .empty;
    defer sources.deinit(gpa);
    try collectSources(corpus, query, &result, &sources);
    if (stats_sink) |s| s.files_candidates += sources.items.len;
    if (timer.*) |*t| if (stats_sink) |s| {
        s.filter_ns += t.lap();
    };

    var at: usize = 0;
    var unrepresented: u32 = 0;
    while (at < sources.items.len) {
        const counting = result.truncated;
        if (counting and corpus.kinds != null) {
            unrepresented += @intCast(sources.items.len - at);
            result.total_exact = false;
            break;
        }
        const end = @min(sources.items.len, at + chunk_files);
        var work = try gpa.alloc(FileWork, end - at);
        var made: usize = 0;
        defer {
            for (work[0..made]) |*item| item.deinit(gpa);
            gpa.free(work);
        }
        for (sources.items[at..end], work) |src, *item| {
            item.* = .{ .path = src.path, .content = src.content, .spans = src.spans };
            made += 1;
            if (stats_sink) |s| s.candidate_bytes += src.content.len;
        }
        var shared: Shared = .{ .gpa = gpa, .query = query, .kinds = corpus.kinds, .hit_limit = corpus.hit_limit, .width = corpus.width, .count_only = counting, .work = work };
        const helpers: usize = if (work.len < 4) 0 else worker_pool.max_threads;
        if (corpus.pool) |p| p.run(helpers, workerTask, &shared) else workerTask(&shared);
        if (shared.failure) |err| return err;
        if (timer.*) |*t| if (stats_sink) |s| {
            s.match_ns += t.lap();
        };
        for (work) |*item| {
            if (!counting and item.needs_live_parse) {
                try liveFile(gpa, corpus.io, corpus.runtime, corpus.tree_cache, corpus.root, query, corpus.kinds, corpus.hit_limit, corpus.width, item);
                if (stats_sink) |s| s.files_parsed += 1;
            }
            result.most_steps = @max(result.most_steps, item.most_steps);
            result.matched_lines += item.matched_lines;
            for (std.enums.values(Kind)) |k| result.filtered.getPtr(k).* += item.filtered.get(k);
            const declared = item.over_budget_lines != 0 or (item.unclassified and corpus.kinds != null and item.matched_lines != 0);
            if (item.over_budget_lines != 0) {
                try result.missing.append(gpa, .{ .path = item.path, .reason = .budget });
            } else if (item.unclassified and corpus.kinds != null and item.matched_lines != 0) {
                try result.missing.append(gpa, .{ .path = item.path, .reason = .unclassified });
            }
            if (item.capped) result.total_exact = false;
            const found_here = item.hits.items.len + item.extra_matches;
            result.total += found_here;
            if (counting or result.truncated) {
                if (found_here != 0 and !declared) unrepresented += 1;
                continue;
            }
            var kept: usize = 0;
            for (item.hits.items) |*pending| {
                if (result.hits >= corpus.hit_limit) {
                    result.truncated = true;
                    break;
                }
                try addHit(gpa, &result.groups, item.path, pending);
                result.hits += 1;
                kept += 1;
            }
            if (kept < found_here and !declared) {
                if (kept == 0) unrepresented += 1 else result.cut_file = item.path;
            }
        }
        if (timer.*) |*t| if (stats_sink) |s| {
            s.parse_ns += t.lap();
        };
        at = end;
    }
    result.unrepresented = unrepresented;
    return result;
}

fn mergeSorted(items: []Source, split: usize) void {
    var i: usize = split;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0 and index_file.foldedOrder(items[j].path, items[j - 1].path) == .lt) : (j -= 1) {
            std.mem.swap(Source, &items[j], &items[j - 1]);
        }
    }
}

fn emptyNote(buf: []u8, result: Result, scope: Scope, rel: []const u8, query: Query, kinds: ?[]const Value, tried_alternatives: bool) []const u8 {
    const where: []const u8 = if (rel.len == 0) "." else rel;
    if (result.listed == 0) {
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
    const evaluated = result.evaluated() orelse 0;
    if (result.partial()) return std.fmt.bufPrint(buf, "no match in the {d} evaluated file(s); {d} file(s) could not be fully evaluated, see missing", .{ evaluated, result.missingFiles() }) catch where;
    if (tried_alternatives) return std.fmt.bufPrint(buf, "no match in {d} file(s) for the literal text, nor for its |-separated parts read as literal alternatives; pass regex:true for a regular expression", .{evaluated}) catch where;
    if (query.mode == .literal) {
        if (text_query.regexSyntax(query.pattern)) |token| {
            return std.fmt.bufPrint(buf, "no match in {d} file(s) for the literal text; it contains regex syntax ({s}), pass regex:true to search it as a regular expression", .{ evaluated, token }) catch where;
        }
    }
    return std.fmt.bufPrint(buf, "no match in {d} file(s)", .{evaluated}) catch where;
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

fn writeShown(js: *std.json.Stringify, groups: []const Group, shown: []const Shown) !void {
    try js.beginArray();
    for (shown) |s| try writeGroupSlice(js, groups[s.group], s.lo, s.hi);
    try js.endArray();
}

fn writeGroupSlice(js: *std.json.Stringify, g: Group, lo: usize, hi: usize) !void {
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
    for (g.hits.items[lo..hi]) |hit| try writeHit(js, hit);
    try js.endArray();
    try js.endObject();
}

fn writeHit(js: *std.json.Stringify, hit: Hit) !void {
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

fn writeStats(js: *std.json.Stringify, s: *const Stats, indexed: usize) !void {
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
        try js.objectField("warm_wait_ms");
        try js.write(nsToMs(r.warm_wait_ns));
        try js.objectField("warmup_ms");
        try js.write(nsToMs(r.warmup_ns));
        try js.objectField("verify_ms");
        try js.write(nsToMs(r.verify_ns));
    }
    try js.objectField("total_ms");
    try js.write(nsToMs(s.total_ns));
    try js.objectField("pid");
    try js.write(currentPid());
    try js.objectField("indexed_files");
    try js.write(indexed);
    try js.objectField("files_candidates");
    try js.write(s.files_candidates);
    try js.objectField("files_parsed");
    try js.write(s.files_parsed);
    try js.objectField("index_reused");
    try js.write(s.files_index_reused);
    try js.objectField("index_recomputed");
    try js.write(s.files_index_recomputed);
    try js.objectField("index_refresh_ms");
    try js.write(nsToMs(s.index_refresh_ns));
    try js.objectField("match_ms");
    try js.write(nsToMs(s.match_ns));
    try js.objectField("parse_ms");
    try js.write(nsToMs(s.parse_ns));
    try js.objectField("json_ms");
    try js.write(nsToMs(s.json_ns));
    try js.objectField("root_ms");
    try js.write(nsToMs(s.root_ns));
    try js.endObject();
}
