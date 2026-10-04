const std = @import("std");
const facts = @import("facts.zig");
const facts_store = @import("facts_store.zig");
const answer = @import("answer.zig");
const map = @import("map.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Store = facts_store.Store;
const FileState = facts_store.FileState;
const none = facts.none;

pub const default_budget: usize = 8_000;
pub const min_budget: usize = 600;
pub const max_detail_chars: usize = 100;
const reserve: usize = 360;

pub const Level = enum { full, signatures, names };

pub const Context = struct {
    snapshot: answer.Snapshot,
    max_file_bytes: u64 = 0,
    largest_file_bytes: u64 = 0,
};

pub const Options = struct {
    budget: usize = default_budget,
    offset: u32 = 0,
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

fn clip(text: []const u8, limit: usize) []const u8 {
    if (text.len <= limit) return text;
    var end = limit;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

pub fn paramsOf(signature: []const u8, name: []const u8) []const u8 {
    if (name.len == 0) return "";
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, signature, from, name)) |at| {
        from = at + 1;
        if (at > 0 and (isIdentByte(signature[at - 1]) or signature[at - 1] == '"' or signature[at - 1] == '\'')) continue;
        const end = at + name.len;
        if (end < signature.len and isIdentByte(signature[end])) continue;
        var rest = std.mem.trim(u8, signature[end..], " ");
        if (std.mem.startsWith(u8, rest, "=")) rest = std.mem.trim(u8, rest[1..], " ");
        if (std.mem.endsWith(u8, rest, "=>")) rest = std.mem.trimEnd(u8, rest[0 .. rest.len - 2], " ");
        return clip(rest, max_detail_chars);
    }
    return "";
}

fn spaced(signature: []const u8) bool {
    return signature.len != 0 and signature[0] != '(' and signature[0] != '<';
}

fn detailChars(signature: []const u8) usize {
    return signature.len + @intFromBool(spaced(signature));
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

fn dirOf(rel: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, rel, '/') orelse return "";
    return rel[0 .. slash + 1];
}

fn headChars(region: *const map.Region, files: []const File, rows: []const Row, r: usize, first: usize) usize {
    if (!startsFile(rows, r, first)) return 0;
    const rel = relative(region, files[rows[r].file].path);
    const dir = dirOf(rel);
    var chars: usize = rel.len - dir.len + 1;
    const new_dir = r == first or !std.mem.eql(u8, dir, dirOf(relative(region, files[rows[r - 1].file].path)));
    if (new_dir and dir.len != 0) chars += dir.len + 1;
    return chars;
}

fn rowChars(level: Level, region: *const map.Region, files: []const File, rows: []const Row, r: usize, first: usize) usize {
    const row = rows[r];
    const f = files[row.file];
    const head = headChars(region, files, rows, r, first);
    if (row.def == none) return head + 3 + whyNot(f.state).len;
    const d = f.state.?.facts.defs[row.def];
    const base = 2 + digitsOf(d.line) + 1 + map.kindTag(d.kind).len + 1 + d.qname.len + 1;
    return head + switch (level) {
        .names => base,
        .signatures => base + detailChars(row.signature),
        .full => base + detailChars(row.signature) + (if (row.doc.len != 0) row.doc.len + 3 else 0),
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
        const levels: []const Level = if (details) &.{ .full, .signatures, .names } else &.{.names};
        for (levels) |level| {
            const chars = rangeChars(level, region, files, rows, 0, rows.len);
            if (chars <= body) return .{ .level = level, .first = 0, .end = total, .chars = chars };
        }
    }
    var chars: usize = 0;
    var end: u32 = offset;
    while (end < total) {
        const line = rowChars(.names, region, files, rows, end, offset);
        if (end > offset and chars + line > body) break;
        chars += line;
        end += 1;
    }
    return .{ .level = .names, .first = offset, .end = end, .chars = chars };
}

fn writeBody(w: *Writer, region: *const map.Region, files: []const File, rows: []const Row, p: Plan) !void {
    var r: usize = p.first;
    while (r < p.end) : (r += 1) {
        const row = rows[r];
        const f = files[row.file];
        if (startsFile(rows, r, p.first)) {
            const rel = relative(region, f.path);
            const dir = dirOf(rel);
            const new_dir = r == p.first or !std.mem.eql(u8, dir, dirOf(relative(region, files[rows[r - 1].file].path)));
            if (new_dir and dir.len != 0) try w.print("{s}\n", .{dir});
            try w.writeAll(rel[dir.len..]);
            if (row.def == none) {
                try w.print(" ({s})\n", .{whyNot(f.state)});
                continue;
            }
            try w.writeByte('\n');
        }
        const d = f.state.?.facts.defs[row.def];
        try w.print("  {d} {s} {s}", .{ d.line, map.kindTag(d.kind), d.qname });
        if (p.level != .names and row.signature.len != 0) {
            if (spaced(row.signature)) try w.writeByte(' ');
            try w.writeAll(row.signature);
        }
        if (p.level == .full and row.doc.len != 0) try w.print(" - {s}", .{row.doc});
        try w.writeByte('\n');
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
                    try rows.append(arena, .{ .file = @intCast(k), .def = @intCast(di), .signature = if (d.kind.callable()) paramsOf(d.signature, d.name) else "", .doc = clip(d.doc, max_detail_chars) });
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
    const p = plan(region, files, rows.items, body, options.offset, true);

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
        try w.print("... entries {d} to {d} of {d} not shown (budget {d} characters), so the listing is partial; next page: emetgate_region r{d} offset {d}\n", .{ next + 1, total, total, budget, region_id + 1, next });
    }
    switch (result) {
        .complete => |*c| c.value.text = out.written(),
        .partial => |*pt| pt.value.text = out.written(),
        .refused => {},
    }
    return result;
}
