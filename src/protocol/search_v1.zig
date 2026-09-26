const std = @import("std");
const repo = @import("../platform/repo.zig");
const shadow = @import("../platform/shadow.zig");
const search_index = @import("../platform/search_index.zig");
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

pub fn callSearch(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, root: ?[]const u8, tree_cache: ?*tree_cache_mod.TreeCache) !ToolResult {
    const pattern = try requireString(args, "pattern");
    const dir = if (args) |a| getString(a, "dir") orelse "." else ".";
    const is_regex = if (args) |a| getBool(a, "regex") orelse false else false;
    const kinds = if (args) |a| getStringArray(a, "kinds") else null;
    event.label = "search";
    event.file = dir;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    renderSearch(gpa, io, runtime, root, tree_cache, pattern, dir, is_regex, kinds, &buffer.writer) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err, event);
    };
    return success(gpa, &buffer);
}

fn renderSearch(gpa: Allocator, io: std.Io, runtime: *Runtime, root: ?[]const u8, tree_cache: ?*tree_cache_mod.TreeCache, pattern: []const u8, dir: []const u8, is_regex: bool, kinds: ?[]const Value, w: *Writer) !void {
    if (pattern.len == 0) return error.EmptyPattern;
    const place = try repo.jail(gpa, io, root, dir);
    defer place.deinit(gpa);

    const files = try shadow.trackedFiles(gpa, io, place.root);
    defer gpa.free(files);
    defer shadow.freeFileList(gpa, files);

    const index_path = search_index.indexPath(gpa, place.root) catch null;
    defer if (index_path) |p| gpa.free(p);
    const previous_index: ?search_index.Index = if (index_path) |p| (search_index.load(gpa, io, p) catch null) else null;
    defer if (previous_index) |idx| idx.deinit();
    const fresh_index: ?search_index.Index = search_index.refresh(gpa, io, place.root, files, previous_index) catch null;
    defer if (fresh_index) |idx| idx.deinit();
    if (fresh_index) |idx| {
        if (index_path) |p| search_index.save(gpa, io, p, idx) catch {};
    }

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

        const bytes = std.Io.Dir.cwd().readFileAlloc(io, abs, gpa, .limited(max_file_bytes)) catch continue;
        defer gpa.free(bytes);
        if (std.mem.indexOfScalar(u8, bytes, 0) != null) continue;
        files_scanned += 1;

        const profile = registry.forPath(f);
        var snapshot: ?*Loader.Snapshot = null;
        var owned_snapshot = false;
        defer if (owned_snapshot) snapshot.?.destroy();
        var table: ?*const symbol.Table = null;
        if (profile) |p| {
            snapshot = if (tree_cache) |cache|
                cache.load(runtime, io, abs) catch |err| blk2: {
                    if (err == error.OutOfMemory) return err;
                    break :blk2 null;
                }
            else blk: {
                owned_snapshot = true;
                break :blk Loader.Snapshot.load(runtime, io, .cwd(), abs) catch null;
            };
            if (snapshot) |snap| table = snap.symbols() catch null;
            _ = p;
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

        var offset: u32 = 0;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        var number: u32 = 0;
        while (lines.next()) |raw| {
            number += 1;
            const line_start = offset;
            offset += @intCast(raw.len + 1);
            if (!try matcher.find(gpa, raw)) continue;
            const match_at: u32 = line_start + @as(u32, @intCast(std.mem.indexOf(u8, raw, if (is_regex) raw else pattern) orelse 0));

            var kind: Kind = .code;
            var role: ?Role = null;
            var group_symbol: ?[]const u8 = null;
            var group_hash: ?symbol.Hash = null;
            var group_pointer: ?[]const u8 = null;
            var group_heading: ?[]const u8 = null;

            if (profile) |p| {
                if (snapshot) |snap| {
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
