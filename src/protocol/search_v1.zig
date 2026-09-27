const std = @import("std");
const repo = @import("../platform/repo.zig");
const shadow = @import("../platform/shadow.zig");
const search_index = @import("../platform/search_index.zig");
const search_session = @import("../platform/search_session.zig");
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
    renderSearch(gpa, io, runtime, root, tree_cache, session, pattern, dir, is_regex, kinds, &buffer.writer) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err, event);
    };
    return success(gpa, &buffer);
}

fn renderSearch(gpa: Allocator, io: std.Io, runtime: *Runtime, root: ?[]const u8, tree_cache: ?*tree_cache_mod.TreeCache, session: ?*search_session.Session, pattern: []const u8, dir: []const u8, is_regex: bool, kinds: ?[]const Value, w: *Writer) !void {
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
        const previous_index: ?search_index.Index = if (index_path) |p| (search_index.load(gpa, io, p) catch null) else null;
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
                    if (index_path) |p| search_index.save(gpa, io, p, idx) catch {};
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

    var matcher: Matcher = if (is_regex) blk: {
        var diag: regex_mod.Diagnostic = .{};
        const re = regex_mod.Regex.compile(gpa, pattern, &diag) catch return error.InvalidRegex;
        break :blk .{ .regex = .{ .re = re, .budget = regex_budget } };
    } else .{ .literal = pattern };
    defer if (is_regex) matcher.regex.re.deinit(gpa);

    var groups: std.ArrayList(Group) = .empty;
    defer {
        for (groups.items) |*g| g.hits.deinit(gpa);
        groups.deinit(gpa);
    }
    var total_hits: usize = 0;
    var truncated = false;
    var files_scanned: usize = 0;
    var files_total: usize = 0;

    outer: for (files) |f| {
        if (!read_tools.inDirectory(f, place.rel)) continue;
        files_total += 1;
        const abs = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ place.root, f });
        defer gpa.free(abs);
        repo.refuseInternal(f) catch continue;

        if (gram_query) |needles| {
            if (fresh_index) |idx| {
                if (idx.find(f)) |entry| {
                    if (!search_index.isSupersetSorted(entry.trigrams, needles)) continue;
                }
            }
        }

        if (stats_sink) |s| s.files_candidates += 1;

        var read_timer: ?StageTimer = if (stats_sink != null) StageTimer.start(io) else null;
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, abs, gpa, .limited(max_file_bytes)) catch continue;
        defer gpa.free(bytes);
        if (read_timer) |*t| if (stats_sink) |s| {
            s.read_ns += t.lap();
            s.files_read += 1;
        };
        if (std.mem.indexOfScalar(u8, bytes, 0) != null) continue;

        var probe_timer: ?StageTimer = if (stats_sink != null) StageTimer.start(io) else null;
        var has_any_match = false;
        {
            var probe_offset: u32 = 0;
            var probe_lines = std.mem.splitScalar(u8, bytes, '\n');
            while (probe_lines.next()) |raw| {
                probe_offset += @intCast(raw.len + 1);
                if (try matcher.find(gpa, raw)) {
                    has_any_match = true;
                    break;
                }
            }
        }
        if (probe_timer) |*t| if (stats_sink) |s| {
            s.probe_ns += t.lap();
        };
        if (!has_any_match) continue;
        files_scanned += 1;

        const profile = registry.forPath(f);
        var snapshot: ?*Loader.Snapshot = null;
        var owned_snapshot = false;
        defer if (owned_snapshot) snapshot.?.destroy();
        var table: ?*const symbol.Table = null;
        var fast_spans: ?*const search_index.kind_spans.FileSpans = null;
        var fast_doc: ?search_index.doc_spans.DocSpans = null;
        var parse_timer: ?StageTimer = if (stats_sink != null) StageTimer.start(io) else null;
        if (fresh_index) |idx| {
            if (idx.find(f)) |entry| {
                if (entry.content_hash) |ch| {
                    const live_hash = symbol.fileHash(bytes);
                    if (std.mem.eql(u8, &ch, &live_hash)) {
                        if (entry.spans) |*spans_ptr| fast_spans = spans_ptr;
                        fast_doc = entry.doc;
                    }
                }
            }
        }
        if (profile) |p| {
            if (fast_spans == null) {
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
                if (snapshot) |snap| table = snap.symbols() catch null;
            }
        }

        var json_tree: ?ts.Tree = null;
        defer if (json_tree) |t| t.deinit();
        var md_tree: ?ts.Tree = null;
        defer if (md_tree) |t| t.deinit();
        if (fast_doc != null) {} else if (profile == null and std.ascii.endsWithIgnoreCase(f, ".json")) {
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
        if (parse_timer) |*t| if (stats_sink) |s| {
            s.parse_ns += t.lap();
            if (fast_spans != null or fast_doc != null) s.files_fast_classified += 1 else s.files_parsed += 1;
        };

        var offset: u32 = 0;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        var number: u32 = 0;
        while (lines.next()) |raw| {
            number += 1;
            const line_start = offset;
            offset += @intCast(raw.len + 1);
            if (!try matcher.find(gpa, raw)) continue;
            const match_at: u32 = line_start + @as(u32, @intCast(std.mem.indexOf(u8, raw, if (is_regex) raw else pattern) orelse 0));
            var classify_timer: ?StageTimer = if (stats_sink != null) StageTimer.start(io) else null;
            defer if (classify_timer) |*t| if (stats_sink) |s| {
                s.classify_ns += t.lap();
            };

            var kind: Kind = .code;
            var role: ?Role = null;
            var group_symbol: ?[]const u8 = null;
            var group_hash: ?symbol.Hash = null;
            var group_pointer: ?[]const u8 = null;
            var group_heading: ?[]const u8 = null;

            if (profile) |p| {
                if (fast_spans) |spans| {
                    kind = mapKind(search_index.kind_spans.classify(spans.kind_spans, match_at));
                    const enclosing = search_index.kind_spans.enclosing(spans.symbols, match_at);
                    if (enclosing) |sym| {
                        group_symbol = try gpa.dupe(u8, sym.ref_text);
                        group_hash = sym.hash;
                    }
                    role = mapRole(search_index.kind_spans.role(enclosing, spans.reference_spans, match_at, if (is_regex) "" else pattern));
                } else if (snapshot) |snap| {
                    kind = classify(p, snap.tree.root(), match_at);
                    if (table) |t| {
                        const enclosing = enclosingSymbol(t, match_at);
                        if (enclosing) |sym| {
                            group_symbol = try std.fmt.allocPrint(gpa, "{f}", .{sym.ref});
                            group_hash = sym.hash;
                        }
                        role = roleOf(p, snap.tree.root(), match_at, if (is_regex) "" else pattern, enclosing);
                    }
                }
            } else if (fast_doc) |doc| {
                if (search_index.doc_spans.at(doc, match_at)) |label| switch (doc.kind) {
                    .json => group_pointer = try gpa.dupe(u8, label),
                    .markdown => group_heading = label,
                };
            } else if (json_tree) |t| {
                group_pointer = json_pointer.pointerAt(gpa, t, match_at) catch null;
            } else if (md_tree) |t| {
                group_heading = markdown_heading.sectionAt(gpa, t, match_at) catch null;
            }
            defer if (group_symbol) |s| gpa.free(s);
            defer if (group_pointer) |s| gpa.free(s);

            if (!kindAllowed(kinds, kind)) continue;

            if (total_hits >= max_matches) {
                truncated = true;
                break :outer;
            }

            var target: ?*Group = null;
            for (groups.items) |*g| {
                if (!std.mem.eql(u8, g.file, f)) continue;
                const same = (group_symbol == null and g.symbol == null and group_pointer == null and g.pointer == null and group_heading == null and g.heading == null) or
                    (group_symbol != null and g.symbol != null and std.mem.eql(u8, group_symbol.?, g.symbol.?)) or
                    (group_pointer != null and g.pointer != null and std.mem.eql(u8, group_pointer.?, g.pointer.?)) or
                    (group_heading != null and g.heading != null and std.mem.eql(u8, group_heading.?, g.heading.?));
                if (same) {
                    target = g;
                    break;
                }
            }
            if (target == null) {
                try groups.append(gpa, .{
                    .file = try gpa.dupe(u8, f),
                    .symbol = if (group_symbol) |s| try gpa.dupe(u8, s) else null,
                    .pointer = if (group_pointer) |s| try gpa.dupe(u8, s) else null,
                    .heading = if (group_heading) |s| try gpa.dupe(u8, s) else null,
                    .hash = group_hash,
                    .hits = .empty,
                });
                target = &groups.items[groups.items.len - 1];
            }
            try target.?.hits.append(gpa, .{
                .line = number,
                .text = try gpa.dupe(u8, read_tools.utf8Prefix(std.mem.trim(u8, raw, " \t\r"), max_match_text)),
                .kind = kind,
                .role = role,
            });
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
        if (s.session) |r| {
            try js.objectField("refresh_mode");
            try js.write(@tagName(r.mode));
            try js.objectField("refresh_reason");
            try js.write(r.reason);
            try js.objectField("dirty_paths");
            try js.write(r.dirty_paths);
            try js.objectField("updated");
            try js.write(r.updated);
            try js.objectField("list_reused");
            try js.write(r.list_reused);
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
