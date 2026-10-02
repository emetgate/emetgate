const std = @import("std");
const facts = @import("facts.zig");
const facts_store = @import("facts_store.zig");
const answer = @import("answer.zig");
const facts_evidence = @import("facts_evidence.zig");
const profile_mod = @import("lang/profile.zig");
const map = @import("map.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Store = facts_store.Store;
const FileState = facts_store.FileState;
const MapTable = profile_mod.MapTable;
const none = facts.none;

pub const default_budget: usize = 8_000;
pub const min_budget: usize = 600;
pub const max_detail_chars: usize = 100;
const reserve: usize = 360;

pub const Level = enum { full, signatures, names, compact };

pub const Context = struct {
    snapshot: answer.Snapshot,
    max_file_bytes: u64 = 0,
    largest_file_bytes: u64 = 0,
};

pub const Options = struct {
    budget: usize = default_budget,
    offset: u32 = 0,
    source: ?facts_evidence.Source = null,
};

pub const RegionListing = struct {
    region: map.RegionId,
    path: []const u8,
    symbols: u32,
    files: u32,
    first: u32,
    shown: u32,
    next: ?u32,
    level: Level,
    text: []const u8,
};

pub const ListingAnswer = answer.Answer(RegionListing);

const File = struct {
    path: []const u8,
    state: ?*const FileState,
    first_row: u32 = 0,
    rows: u32 = 0,
    bytes: ?[]const u8 = null,
};

const Row = struct {
    file: u32,
    def: u32,
    signature: []const u8 = "",
    doc: []const u8 = "",
};

fn fileLess(_: void, a: File, b: File) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

fn currentFiles(arena: Allocator, store: *const Store, m: *const map.Map, region: *const map.Region) ![]File {
    var files: std.ArrayList(File) = .empty;
    for (region.files) |k| {
        const snap = m.snapshot.files[k];
        const id = store.fileId(snap.path) orelse {
            try files.append(arena, .{ .path = snap.path, .state = null });
            continue;
        };
        const state = store.file(id);
        try files.append(arena, .{ .path = snap.path, .state = if (state.status == .removed) null else state });
    }
    for (store.files.items, 0..) |*state, id| {
        if (state.status == .removed) continue;
        if (id < m.snapshot.by_store_id.len and m.snapshot.by_store_id[id] != none) continue;
        const owner = m.regionOfPath(state.path) orelse continue;
        if (owner != region.id) continue;
        try files.append(arena, .{ .path = state.path, .state = state });
    }
    std.mem.sort(File, files.items, {}, fileLess);
    return files.items;
}

fn isIdentByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$' or c >= 0x80;
}

fn collapse(arena: Allocator, text: []const u8, limit: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var space = false;
    for (text) |c| {
        if (std.ascii.isWhitespace(c)) {
            space = out.items.len != 0;
            continue;
        }
        if (space) try out.append(arena, ' ');
        space = false;
        try out.append(arena, c);
    }
    if (out.items.len <= limit) return out.items;
    var end = limit;
    while (end > 0 and (out.items[end] & 0xC0) == 0x80) end -= 1;
    out.shrinkRetainingCapacity(end);
    try out.appendSlice(arena, "...");
    return out.items;
}

fn isOpen(table: *const MapTable, c: u8) bool {
    return std.mem.indexOfScalar(u8, table.open_brackets, c) != null;
}

fn isClose(table: *const MapTable, bytes: []const u8, k: usize) bool {
    const c = bytes[k];
    if (std.mem.indexOfScalar(u8, table.close_brackets, c) == null) return false;
    if (k > 0 and c == '>' and bytes[k - 1] == '=') return false;
    return true;
}

fn stopsAt(table: *const MapTable, bytes: []const u8, k: usize) bool {
    const c = bytes[k];
    if (c == table.body_open or c == table.statement_end) return true;
    return std.mem.startsWith(u8, bytes[k..], table.arrow);
}

pub fn signatureOf(arena: Allocator, bytes: []const u8, d: facts.Def, table: *const MapTable) ![]const u8 {
    if (!d.kind.callable()) return "";
    const end_limit = @min(bytes.len, d.span.end);
    var i: usize = d.name_start;
    if (i >= end_limit) return "";
    while (i < end_limit and isIdentByte(bytes[i])) i += 1;
    const limit = @min(end_limit, i + 600);
    if (d.kind == .class) {
        var k = i;
        while (k < limit and bytes[k] != table.body_open) k += 1;
        if (k >= limit) return "";
        return collapse(arena, bytes[i..k], max_detail_chars);
    }
    var k = i;
    while (k < limit and bytes[k] != '(') : (k += 1) {
        if (stopsAt(table, bytes, k) and bytes[k] != '<') return "";
    }
    if (k >= limit) return "";
    const start = k;
    var depth: u32 = 0;
    while (k < limit) : (k += 1) {
        if (isOpen(table, bytes[k])) depth += 1 else if (isClose(table, bytes, k)) {
            depth -|= 1;
            if (depth == 0) {
                k += 1;
                break;
            }
        }
    }
    if (depth != 0) return collapse(arena, bytes[start..limit], max_detail_chars);
    var end = k;
    var j = k;
    while (j < limit and (bytes[j] == ' ' or bytes[j] == '\t' or bytes[j] == '\n' or bytes[j] == '\r')) j += 1;
    if (j < limit and bytes[j] == ':') {
        depth = 0;
        while (j < limit) : (j += 1) {
            if (depth == 0 and stopsAt(table, bytes, j)) break;
            if (isOpen(table, bytes[j])) depth += 1 else if (isClose(table, bytes, j)) depth -|= 1;
        }
        end = j;
    }
    return collapse(arena, bytes[start..end], max_detail_chars);
}

pub fn docOf(arena: Allocator, bytes: []const u8, d: facts.Def, table: *const MapTable) ![]const u8 {
    var i: usize = @min(d.span.start, bytes.len);
    while (i > 0 and std.ascii.isWhitespace(bytes[i - 1])) i -= 1;
    const before = bytes[0..i];
    if (std.mem.endsWith(u8, before, table.doc_close)) {
        const close = i - table.doc_close.len;
        const open = std.mem.lastIndexOf(u8, before[0..close], table.doc_open) orelse return "";
        var lines = std.mem.splitScalar(u8, before[open + table.doc_open.len .. close], '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r*");
            if (line.len == 0 or line[0] == '@') continue;
            return collapse(arena, line, max_detail_chars);
        }
        return "";
    }
    var first: ?[]const u8 = null;
    var end = i;
    while (end > 0) {
        const line_start = if (std.mem.lastIndexOfScalar(u8, bytes[0..end], '\n')) |nl| nl + 1 else 0;
        const line = std.mem.trim(u8, bytes[line_start..end], " \t\r");
        if (!std.mem.startsWith(u8, line, table.line_comment)) break;
        const text = std.mem.trim(u8, line[table.line_comment.len..], " \t/");
        if (text.len != 0) first = text;
        if (line_start == 0) break;
        end = line_start - 1;
    }
    if (first) |text| return collapse(arena, text, max_detail_chars);
    return "";
}

fn relative(region: *const map.Region, path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, region.dir)) return path[region.dir.len..];
    return path;
}

const Plan = struct {
    level: Level,
    first: u32,
    end: u32,
    chars: usize,
};

fn digitsOf(value: u64) usize {
    var n: usize = 1;
    var v = value;
    while (v >= 10) : (v /= 10) n += 1;
    return n;
}

fn whyNot(state: ?*const FileState) []const u8 {
    const s = state orelse return "gone since the map was built";
    return switch (s.status) {
        .unindexed => "not parsed: unsupported language",
        .unreadable => "unreadable",
        .too_large => "over the file size limit",
        .removed => "gone since the map was built",
        .indexed => "no symbols",
    };
}

fn startsFile(rows: []const Row, r: usize, first: usize) bool {
    return r == first or rows[r - 1].file != rows[r].file;
}

fn rowChars(level: Level, region: *const map.Region, files: []const File, rows: []const Row, r: usize, first: usize) usize {
    const row = rows[r];
    const f = files[row.file];
    const rel = relative(region, f.path);
    if (row.def == none) return rel.len + 4 + whyNot(f.state).len + 1;
    const head: usize = if (level == .compact and startsFile(rows, r, first)) rel.len + 1 else 0;
    const d = f.state.?.facts.defs[row.def];
    const base = digitsOf(d.line) + 1 + map.kindTag(d.kind).len + 1 + d.qname.len + 1;
    return head + switch (level) {
        .compact => 2 + base,
        .names => rel.len + 1 + base,
        .signatures => rel.len + 1 + base + row.signature.len,
        .full => rel.len + 1 + base + row.signature.len + (if (row.doc.len != 0) row.doc.len + 3 else 0),
    };
}

fn rangeChars(level: Level, region: *const map.Region, files: []const File, rows: []const Row, first: usize, end: usize) usize {
    var total: usize = 0;
    var r = first;
    while (r < end) : (r += 1) total += rowChars(level, region, files, rows, r, first);
    return total;
}

fn plan(region: *const map.Region, files: []const File, rows: []const Row, body: usize, offset: u32, details: bool) Plan {
    const total: u32 = @intCast(rows.len);
    if (offset == 0) {
        const levels: []const Level = if (details) &.{ .full, .signatures, .names, .compact } else &.{ .names, .compact };
        for (levels) |level| {
            const chars = rangeChars(level, region, files, rows, 0, rows.len);
            if (chars <= body) return .{ .level = level, .first = 0, .end = total, .chars = chars };
        }
    }
    var chars: usize = 0;
    var end: u32 = offset;
    while (end < total) {
        const line = rowChars(.compact, region, files, rows, end, offset);
        if (end > offset and chars + line > body) break;
        chars += line;
        end += 1;
    }
    return .{ .level = .compact, .first = offset, .end = end, .chars = chars };
}

fn writeBody(w: *Writer, region: *const map.Region, files: []const File, rows: []const Row, p: Plan) !void {
    var r: usize = p.first;
    while (r < p.end) : (r += 1) {
        const row = rows[r];
        const f = files[row.file];
        const rel = relative(region, f.path);
        if (row.def == none) {
            try w.print("{s}  ({s})\n", .{ rel, whyNot(f.state) });
            continue;
        }
        if (p.level == .compact and startsFile(rows, r, p.first)) try w.print("{s}\n", .{rel});
        const d = f.state.?.facts.defs[row.def];
        switch (p.level) {
            .compact => try w.print("  {d} {s} {s}\n", .{ d.line, map.kindTag(d.kind), d.qname }),
            .names => try w.print("{s}:{d} {s} {s}\n", .{ rel, d.line, map.kindTag(d.kind), d.qname }),
            .signatures => try w.print("{s}:{d} {s} {s}{s}\n", .{ rel, d.line, map.kindTag(d.kind), d.qname, row.signature }),
            .full => {
                try w.print("{s}:{d} {s} {s}{s}", .{ rel, d.line, map.kindTag(d.kind), d.qname, row.signature });
                if (row.doc.len != 0) try w.print(" - {s}", .{row.doc});
                try w.writeByte('\n');
            },
        }
    }
}

fn fillDetails(arena: Allocator, files: []File, rows: []Row, source: facts_evidence.Source) !void {
    var r: usize = 0;
    while (r < rows.len) {
        const k = rows[r].file;
        var end = r;
        while (end < rows.len and rows[end].file == k) end += 1;
        defer r = end;
        const f = &files[k];
        const state = f.state orelse continue;
        if (rows[r].def == none) continue;
        const profile = state.profile orelse continue;
        const table = profile.map orelse continue;
        const got = source.file(f.path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unavailable => continue,
        };
        for (rows[r..end]) |*row| {
            const d = state.facts.defs[row.def];
            row.signature = try signatureOf(arena, got.bytes, d, table);
            row.doc = try docOf(arena, got.bytes, d, table);
        }
    }
}

pub fn regionListing(arena: Allocator, store: *const Store, m: *const map.Map, region_id: map.RegionId, context: Context, options: Options) !ListingAnswer {
    if (region_id >= m.regions.len) return ListingAnswer.refuse(error.UnknownRegion, try std.fmt.allocPrint(arena, "no region r{d}; the map has r1 to r{d}", .{ region_id + 1, m.regions.len }));
    const budget = @max(options.budget, min_budget);
    const region = &m.regions[region_id];
    const files = try currentFiles(arena, store, m, region);
    var rows: std.ArrayList(Row) = .empty;
    var total_symbols: u32 = 0;
    for (files, 0..) |*f, k| {
        f.first_row = @intCast(rows.items.len);
        if (f.state) |state| {
            if (state.status == .indexed) {
                for (state.facts.defs, 0..) |d, di| {
                    if (d.kind == .module) continue;
                    try rows.append(arena, .{ .file = @intCast(k), .def = @intCast(di) });
                    total_symbols += 1;
                }
            }
        }
        if (rows.items.len == f.first_row) try rows.append(arena, .{ .file = @intCast(k), .def = none });
        f.rows = @as(u32, @intCast(rows.items.len)) - f.first_row;
    }
    const total: u32 = @intCast(rows.items.len);
    if (options.offset > 0 and options.offset >= total) return ListingAnswer.refuse(error.OffsetOutOfRange, try std.fmt.allocPrint(arena, "offset {d} is past the {d} entries of r{d}", .{ options.offset, total, region_id + 1 }));
    const body = budget -| reserve;
    var details = false;
    if (options.source) |source| {
        if (options.offset == 0 and rangeChars(.names, region, files, rows.items, 0, rows.items.len) <= body) {
            try fillDetails(arena, files, rows.items, source);
            details = true;
        }
    }
    const p = plan(region, files, rows.items, body, options.offset, details);

    var missing: std.ArrayList(answer.Missing) = .empty;
    var evaluated: u32 = 0;
    var cut: u32 = 0;
    var too_large = false;
    var shown_symbols: u32 = 0;
    for (rows.items[p.first..p.end]) |row| {
        if (row.def != none) shown_symbols += 1;
    }
    for (files) |f| {
        const shown = f.first_row >= p.first and f.first_row + f.rows <= p.end;
        if (!shown) {
            cut += 1;
            continue;
        }
        const state = f.state orelse {
            try missing.append(arena, .{ .path = f.path, .reason = .vanished });
            continue;
        };
        switch (state.status) {
            .indexed => {
                if (state.facts.parse_errors) {
                    try missing.append(arena, .{ .path = f.path, .reason = .unclassified });
                } else evaluated += 1;
            },
            .unindexed => try missing.append(arena, .{ .path = f.path, .reason = .unclassified }),
            .unreadable => try missing.append(arena, .{ .path = f.path, .reason = .unreadable }),
            .too_large => {
                too_large = true;
                try missing.append(arena, .{ .path = f.path, .reason = .too_large });
            },
            .removed => try missing.append(arena, .{ .path = f.path, .reason = .vanished }),
        }
    }
    var budgets: std.ArrayList(answer.Budget) = .empty;
    if (too_large) try budgets.append(arena, .{ .limit = .file_bytes, .max = context.max_file_bytes, .used = @min(context.largest_file_bytes, context.max_file_bytes) });
    if (cut != 0) {
        try missing.append(arena, .{ .path = null, .reason = .budget, .files = cut });
        try budgets.append(arena, .{ .limit = .steps, .max = budget, .used = @min(p.chars + reserve, budget) });
    }
    const value: RegionListing = .{
        .region = region_id,
        .path = region.path,
        .symbols = total_symbols,
        .files = @intCast(files.len),
        .first = p.first,
        .shown = shown_symbols,
        .next = if (p.end < total) p.end else null,
        .level = p.level,
        .text = "",
    };
    const cert: answer.Certificate = .{
        .snapshot = context.snapshot,
        .scope = .{ .prefix = region.dir, .listed = @intCast(files.len), .evaluated = evaluated },
        .semantics = .listing,
        .budgets = budgets.items,
    };
    var result = ListingAnswer.finish(value, cert, missing.items);
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.print("region r{d} {s} ({t}): {d} symbols in {d} files; paths below are relative to {s}\n", .{ region_id + 1, region.path, region.family, total_symbols, files.len, if (region.dir.len == 0) "the repository root" else region.dir });
    try result.writeStatus(w, shown_symbols, "symbols");
    try w.writeByte('\n');
    try writeBody(w, region, files, rows.items, p);
    if (value.next) |next| {
        try w.print("... entries {d} to {d} of {d} not shown (budget {d} characters), so the listing is partial; next page: emetgate_region {{\"region\":\"r{d}\",\"offset\":{d}}}\n", .{ next + 1, total, total, budget, region_id + 1, next });
    }
    switch (result) {
        .complete => |*c| c.value.text = out.written(),
        .partial => |*pt| pt.value.text = out.written(),
        .refused => {},
    }
    return result;
}
