const std = @import("std");
const bounded_run = @import("../platform/bounded_run.zig");
const symbol = @import("../engine/symbol.zig");
const line_range = @import("../engine/line_range.zig");
const registry = @import("../engine/lang/registry.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;
const Snapshot = @import("../engine/loader.zig").Snapshot;

const Allocator = std.mem.Allocator;
const Profile = @import("../engine/lang/profile.zig").Profile;

// Symbol-level views over raw git output. The line-level diff and blame stay
// available to the caller; these functions add a summary of WHICH symbols
// changed, reusing the same tree-sitter symbol/declaration machinery the
// `emetgate_symbols` tool is built on. Everything is fail-closed: a side that
// cannot be mapped to symbols (unsupported language, a source the parser
// rejects, a binary blob) is reported as opaque rather than guessed at.

const max_files = 60;
const max_symbols_per_file = 200;
const max_blob_bytes = 4 * 1024 * 1024;

/// How to read the "before" and "after" bytes of each changed file. A null
/// `rev` on the new side means the working tree (read from disk); on either
/// side a blob git cannot produce (the file was added or deleted) is absent.
pub const Sides = struct {
    old_rev: []const u8,
    new_rev: ?[]const u8,
};

pub const Change = enum { added, removed, changed };

pub const SymbolChange = struct {
    ref: []const u8,
    kind: []const u8,
    change: Change,
};

pub const FileReport = struct {
    path: []const u8,
    status: []const u8,
    symbols: []const SymbolChange,
    // A changed line that fell outside every symbol/declaration: a comment,
    // import, whitespace or top-level statement edit.
    non_symbol_change: bool = false,
    // False when a side exists but could not be parsed into symbols; the raw
    // diff is then the only trustworthy view and we say so instead of labelling.
    mapped: bool = true,
    note: ?[]const u8 = null,
};

pub const Summary = struct {
    arena: std.heap.ArenaAllocator,
    files: []const FileReport,
    truncated: bool,

    pub fn deinit(self: *Summary) void {
        self.arena.deinit();
    }
};

const Range = struct { start: u32, end: u32 };

const SideKind = enum { absent, analyzed, unparsed };

const Unit = struct {
    ref: []const u8,
    kind: []const u8,
    hash: symbol.Hash,
    span: symbol.Span,
    touched: bool = false,
};

const Side = struct {
    kind: SideKind,
    units: []Unit = &.{},
    unmapped_change: bool = false,
};

const FileDiff = struct {
    old_path: ?[]const u8,
    new_path: ?[]const u8,
    old_ranges: std.ArrayList(Range) = .empty,
    new_ranges: std.ArrayList(Range) = .empty,
};

/// Parse a unified diff and, for every changed file in a supported language,
/// report which symbols were added, removed or changed. Caller owns the
/// returned Summary and must call `deinit`.
pub fn analyzeDiff(gpa: Allocator, io: std.Io, runtime: *Runtime, git: []const u8, root: []const u8, sides: Sides, diff_text: []const u8) !Summary {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var files = try parseDiff(arena, diff_text);
    const truncated = files.items.len > max_files;
    if (truncated) files.shrinkRetainingCapacity(max_files);

    var reports: std.ArrayList(FileReport) = .empty;
    for (files.items) |*fd| {
        const report = try reportFile(gpa, arena, io, runtime, git, root, sides, fd);
        try reports.append(arena, report);
    }

    return .{ .arena = arena_state, .files = try reports.toOwnedSlice(arena), .truncated = truncated };
}

fn reportFile(gpa: Allocator, arena: Allocator, io: std.Io, runtime: *Runtime, git: []const u8, root: []const u8, sides: Sides, fd: *FileDiff) !FileReport {
    const display = fd.new_path orelse fd.old_path orelse "(unknown)";
    const status = statusOf(fd);

    // Pick a language profile from whichever path exists; a file of no
    // registered language carries no symbols, so the raw diff is the view.
    // A binary file or a pure rename/mode change produces no --- / +++ lines,
    // so neither path is set. There is nothing textual to map; keep the raw
    // diff as the answer rather than crashing on the missing path.
    const lang_path = fd.new_path orelse (fd.old_path orelse
        return .{ .path = display, .status = status, .symbols = &.{}, .mapped = true, .non_symbol_change = false, .note = "no symbols: binary or rename-only change" });
    const profile = registry.forPath(lang_path) orelse
        return .{ .path = display, .status = status, .symbols = &.{}, .mapped = true, .non_symbol_change = fd.new_ranges.items.len + fd.old_ranges.items.len > 0, .note = "no symbols: unsupported language" };

    const old = try loadSide(gpa, arena, io, runtime, git, root, profile, sides.old_rev, fd.old_path, fd.old_ranges.items);
    const new = try loadSideNew(gpa, arena, io, runtime, git, root, profile, sides.new_rev, fd.new_path, fd.new_ranges.items);

    if (old.kind == .unparsed or new.kind == .unparsed) {
        return .{ .path = display, .status = status, .symbols = &.{}, .mapped = false, .note = "could not map to symbols: the source did not parse cleanly" };
    }

    const changes = try classify(arena, old, new);
    const truncated = changes.len > max_symbols_per_file;
    const shown = if (truncated) changes[0..max_symbols_per_file] else changes;
    return .{
        .path = display,
        .status = status,
        .symbols = shown,
        .mapped = true,
        .non_symbol_change = old.unmapped_change or new.unmapped_change,
        .note = if (truncated) "symbol list truncated" else null,
    };
}

fn statusOf(fd: *const FileDiff) []const u8 {
    if (fd.old_path == null) return "added";
    if (fd.new_path == null) return "deleted";
    if (!std.mem.eql(u8, fd.old_path.?, fd.new_path.?)) return "renamed";
    return "modified";
}

fn loadSideNew(gpa: Allocator, arena: Allocator, io: std.Io, runtime: *Runtime, git: []const u8, root: []const u8, profile: *const Profile, new_rev: ?[]const u8, path: ?[]const u8, ranges: []const Range) !Side {
    const rel = path orelse return .{ .kind = .absent };
    const bytes = if (new_rev) |rev|
        (try readRev(gpa, io, git, root, rev, rel)) orelse return .{ .kind = .absent }
    else
        (try readWorking(gpa, io, root, rel)) orelse return .{ .kind = .absent };
    return analyzeSource(arena, runtime, profile, bytes, ranges);
}

fn loadSide(gpa: Allocator, arena: Allocator, io: std.Io, runtime: *Runtime, git: []const u8, root: []const u8, profile: *const Profile, rev: []const u8, path: ?[]const u8, ranges: []const Range) !Side {
    const rel = path orelse return .{ .kind = .absent };
    const bytes = (try readRev(gpa, io, git, root, rev, rel)) orelse return .{ .kind = .absent };
    return analyzeSource(arena, runtime, profile, bytes, ranges);
}

/// Parse owned `bytes` into a symbol table and mark the units the changed line
/// ranges overlap. Takes ownership of `bytes` (frees it with the snapshot).
fn analyzeSource(arena: Allocator, runtime: *Runtime, profile: *const Profile, bytes: []u8, ranges: []const Range) !Side {
    const snapshot = Snapshot.fromSource(runtime, profile, bytes) catch return .{ .kind = .unparsed };
    defer snapshot.destroy();
    const table = snapshot.symbols() catch return .{ .kind = .unparsed };

    var units: std.ArrayList(Unit) = .empty;
    for (table.symbols) |*s| {
        try units.append(arena, .{
            .ref = try std.fmt.allocPrint(arena, "{f}", .{s.ref}),
            .kind = @tagName(s.kind),
            .hash = s.hash,
            .span = s.declaration,
        });
    }
    for (table.declarations) |*d| {
        try units.append(arena, .{
            .ref = try std.fmt.allocPrint(arena, "{f}", .{d.ref}),
            .kind = @tagName(d.kind),
            .hash = d.hash,
            .span = d.declaration,
        });
    }

    var unmapped = false;
    for (ranges) |r| {
        const bytes_range = line_range.byteRangeForLines(snapshot.source, r.start, r.end) catch continue;
        var hit = false;
        for (units.items) |*u| {
            if (line_range.overlaps(u.span, bytes_range)) {
                u.touched = true;
                hit = true;
            }
        }
        if (!hit) unmapped = true;
    }

    return .{ .kind = .analyzed, .units = units.items, .unmapped_change = unmapped };
}

fn findUnit(units: []const Unit, ref: []const u8) ?*const Unit {
    for (units) |*u| {
        if (std.mem.eql(u8, u.ref, ref)) return u;
    }
    return null;
}

fn classify(arena: Allocator, old: Side, new: Side) ![]const SymbolChange {
    var out: std.ArrayList(SymbolChange) = .empty;
    var seen: std.ArrayList([]const u8) = .empty;

    // Every unit touched on either side, compared by ref across the two
    // versions, yields exactly one verdict.
    for ([_]Side{ new, old }) |side| {
        for (side.units) |u| {
            if (!u.touched) continue;
            if (containsRef(seen.items, u.ref)) continue;
            try seen.append(arena, u.ref);

            const in_new = findUnit(new.units, u.ref);
            const in_old = findUnit(old.units, u.ref);
            if (in_new != null and in_old == null) {
                try out.append(arena, .{ .ref = u.ref, .kind = in_new.?.kind, .change = .added });
            } else if (in_new == null and in_old != null) {
                try out.append(arena, .{ .ref = u.ref, .kind = in_old.?.kind, .change = .removed });
            } else if (in_new != null and in_old != null) {
                if (!std.mem.eql(u8, &in_new.?.hash, &in_old.?.hash)) {
                    try out.append(arena, .{ .ref = u.ref, .kind = in_new.?.kind, .change = .changed });
                }
            }
        }
    }
    return out.toOwnedSlice(arena);
}

fn containsRef(list: []const []const u8, ref: []const u8) bool {
    for (list) |r| if (std.mem.eql(u8, r, ref)) return true;
    return false;
}

// --- blame ------------------------------------------------------------------

pub const BlameSymbol = struct {
    ref: []const u8,
    kind: []const u8,
    commit: []const u8,
    summary: []const u8,
    author: []const u8,
    start_line: u32,
    end_line: u32,
};

pub const BlameReport = struct {
    arena: std.heap.ArenaAllocator,
    file: []const u8,
    symbols: []const BlameSymbol,
    mapped: bool,
    note: ?[]const u8 = null,

    pub fn deinit(self: *BlameReport) void {
        self.arena.deinit();
    }
};

const LineInfo = struct {
    sha: []const u8,
    time: i64,
    summary: []const u8,
    author: []const u8,
};

/// Report which commit last changed each symbol in `rel`, by reading the
/// `git blame --line-porcelain` output over the working-tree source. The raw
/// per-line blame stays available to the caller. Caller owns the report.
pub fn analyzeBlame(gpa: Allocator, io: std.Io, runtime: *Runtime, root: []const u8, rel: []const u8, porcelain: []const u8) !BlameReport {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    const profile = registry.forPath(rel) orelse
        return .{ .arena = arena_state, .file = try arena.dupe(u8, rel), .symbols = &.{}, .mapped = false, .note = "no symbols: unsupported language" };

    const bytes = (try readWorking(gpa, io, root, rel)) orelse
        return .{ .arena = arena_state, .file = try arena.dupe(u8, rel), .symbols = &.{}, .mapped = false, .note = "could not read the working-tree file" };

    const snapshot = Snapshot.fromSource(runtime, profile, bytes) catch
        return .{ .arena = arena_state, .file = try arena.dupe(u8, rel), .symbols = &.{}, .mapped = false, .note = "could not map to symbols: the source did not parse cleanly" };
    defer snapshot.destroy();
    const table = snapshot.symbols() catch
        return .{ .arena = arena_state, .file = try arena.dupe(u8, rel), .symbols = &.{}, .mapped = false, .note = "could not map to symbols: the source did not parse cleanly" };

    const lines = try parsePorcelain(arena, porcelain);
    const newlines = try newlineOffsets(arena, snapshot.source);

    var out: std.ArrayList(BlameSymbol) = .empty;
    for (table.symbols) |*s| try blameUnit(arena, &out, newlines, lines, @tagName(s.kind), s.ref, s.declaration);
    for (table.declarations) |*d| try blameUnit(arena, &out, newlines, lines, @tagName(d.kind), d.ref, d.declaration);

    const truncated = out.items.len > max_symbols_per_file;
    if (truncated) out.shrinkRetainingCapacity(max_symbols_per_file);
    return .{
        .arena = arena_state,
        .file = try arena.dupe(u8, rel),
        .symbols = try out.toOwnedSlice(arena),
        .mapped = true,
        .note = if (truncated) "symbol list truncated" else null,
    };
}

fn newlineOffsets(arena: Allocator, source: []const u8) ![]const usize {
    var offsets: std.ArrayList(usize) = .empty;
    for (source, 0..) |c, i| if (c == '\n') try offsets.append(arena, i);
    return offsets.items;
}

fn lineAt(newlines: []const usize, offset: usize) u32 {
    var lo: usize = 0;
    var hi: usize = newlines.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (newlines[mid] < offset) lo = mid + 1 else hi = mid;
    }
    return @intCast(lo + 1);
}

fn blameUnit(arena: Allocator, out: *std.ArrayList(BlameSymbol), newlines: []const usize, lines: []const ?LineInfo, kind: []const u8, ref: anytype, span: symbol.Span) !void {
    const start_line = lineAt(newlines, span.start);
    const end_line = lineAt(newlines, span.end);
    var best: ?LineInfo = null;
    var line = start_line;
    while (line <= end_line) : (line += 1) {
        if (line == 0 or line > lines.len) continue;
        const info = lines[line - 1] orelse continue;
        if (best == null or info.time > best.?.time) best = info;
    }
    const chosen = best orelse return; // no blame line maps to this symbol
    try out.append(arena, .{
        .ref = try std.fmt.allocPrint(arena, "{f}", .{ref}),
        .kind = kind,
        .commit = chosen.sha,
        .summary = chosen.summary,
        .author = chosen.author,
        .start_line = start_line,
        .end_line = end_line,
    });
}

fn parsePorcelain(arena: Allocator, text: []const u8) ![]const ?LineInfo {
    var map: std.ArrayList(?LineInfo) = .empty;
    var sha: []const u8 = "";
    var final_line: u32 = 0;
    var time: i64 = 0;
    var summary: []const u8 = "";
    var author: []const u8 = "";

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (line[0] == '\t') {
            // Content line: this header block describes `final_line`.
            if (final_line > 0) {
                while (map.items.len < final_line) try map.append(arena, null);
                map.items[final_line - 1] = .{ .sha = try arena.dupe(u8, sha), .time = time, .summary = summary, .author = author };
            }
            summary = "";
            author = "";
            continue;
        }
        if (headerStart(line)) |h| {
            sha = h.sha;
            final_line = h.final_line;
        } else if (std.mem.startsWith(u8, line, "committer-time ")) {
            time = std.fmt.parseInt(i64, std.mem.trim(u8, line["committer-time ".len..], " \t"), 10) catch 0;
        } else if (std.mem.startsWith(u8, line, "summary ")) {
            summary = try arena.dupe(u8, line["summary ".len..]);
        } else if (std.mem.startsWith(u8, line, "author ")) {
            author = try arena.dupe(u8, line["author ".len..]);
        }
    }
    return map.items;
}

const PorcelainHeader = struct { sha: []const u8, final_line: u32 };

fn headerStart(line: []const u8) ?PorcelainHeader {
    // "<40-hex> <orig> <final>[ <group-size>]"
    if (line.len < 42) return null;
    for (line[0..40]) |c| {
        switch (c) {
            '0'...'9', 'a'...'f', 'A'...'F' => {},
            else => return null,
        }
    }
    if (line[40] != ' ') return null;
    var fields = std.mem.tokenizeScalar(u8, line[41..], ' ');
    _ = fields.next() orelse return null; // orig line
    const final_text = fields.next() orelse return null;
    const final_line = std.fmt.parseInt(u32, final_text, 10) catch return null;
    return .{ .sha = line[0..40], .final_line = final_line };
}

// --- blob readers -----------------------------------------------------------

fn readRev(gpa: Allocator, io: std.Io, git: []const u8, root: []const u8, rev: []const u8, rel: []const u8) !?[]u8 {
    const spec = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ rev, rel });
    defer gpa.free(spec);
    const argv = [_][]const u8{ git, "--no-pager", "show", spec };
    const result = bounded_run.run(gpa, io, .{
        .argv = &argv,
        .cwd = .{ .path = root },
        .stdout_limit = .limited(max_blob_bytes),
        .stderr_limit = .limited(64 * 1024),
    }) catch return null;
    defer gpa.free(result.stderr);
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        gpa.free(result.stdout);
        return null;
    }
    return result.stdout;
}

fn readWorking(gpa: Allocator, io: std.Io, root: []const u8, rel: []const u8) !?[]u8 {
    const abs = try std.fs.path.join(gpa, &.{ root, rel });
    defer gpa.free(abs);
    return std.Io.Dir.cwd().readFileAlloc(io, abs, gpa, .limited(max_blob_bytes)) catch null;
}

// --- unified diff parser ----------------------------------------------------

fn parseDiff(arena: Allocator, text: []const u8) !std.ArrayList(FileDiff) {
    var files: std.ArrayList(FileDiff) = .empty;
    var current: ?*FileDiff = null;
    var old_line: u32 = 0;
    var new_line: u32 = 0;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            try files.append(arena, .{ .old_path = null, .new_path = null });
            current = &files.items[files.items.len - 1];
        } else if (std.mem.startsWith(u8, line, "--- ")) {
            if (current) |fd| fd.old_path = pathOf(line[4..]);
        } else if (std.mem.startsWith(u8, line, "+++ ")) {
            if (current) |fd| fd.new_path = pathOf(line[4..]);
        } else if (std.mem.startsWith(u8, line, "@@")) {
            if (parseHunk(line)) |hunk| {
                old_line = hunk.old_start;
                new_line = hunk.new_start;
            }
        } else if (current) |fd| {
            if (line.len == 0) continue;
            switch (line[0]) {
                '+' => {
                    try extend(arena, &fd.new_ranges, new_line);
                    new_line += 1;
                },
                '-' => {
                    try extend(arena, &fd.old_ranges, old_line);
                    old_line += 1;
                },
                ' ' => {
                    old_line += 1;
                    new_line += 1;
                },
                else => {}, // "\ No newline at end of file", index lines, etc.
            }
        }
    }
    return files;
}

fn pathOf(raw: []const u8) ?[]const u8 {
    // Strip a trailing tab-delimited timestamp some diff variants append.
    const field = if (std.mem.indexOfScalar(u8, raw, '\t')) |t| raw[0..t] else raw;
    if (std.mem.eql(u8, field, "/dev/null")) return null;
    if (std.mem.startsWith(u8, field, "a/") or std.mem.startsWith(u8, field, "b/")) return field[2..];
    return field;
}

const Hunk = struct { old_start: u32, new_start: u32 };

fn parseHunk(line: []const u8) ?Hunk {
    // @@ -<os>[,<oc>] +<ns>[,<nc>] @@
    const minus = std.mem.indexOfScalar(u8, line, '-') orelse return null;
    const plus = std.mem.indexOfScalarPos(u8, line, minus, '+') orelse return null;
    const old_start = leadingNumber(line[minus + 1 ..]) orelse return null;
    const new_start = leadingNumber(line[plus + 1 ..]) orelse return null;
    // A hunk with zero lines on a side starts "counting" at the given line;
    // git reports start-1 for an empty side, but the first real line we read
    // is still numbered from the header, so no adjustment is needed here.
    return .{ .old_start = old_start, .new_start = new_start };
}

fn leadingNumber(text: []const u8) ?u32 {
    var end: usize = 0;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    if (end == 0) return null;
    return std.fmt.parseInt(u32, text[0..end], 10) catch null;
}

fn extend(arena: Allocator, ranges: *std.ArrayList(Range), line: u32) !void {
    if (line == 0) return;
    if (ranges.items.len > 0) {
        const last = &ranges.items[ranges.items.len - 1];
        if (line == last.end + 1) {
            last.end = line;
            return;
        }
        if (line >= last.start and line <= last.end) return;
    }
    try ranges.append(arena, .{ .start = line, .end = line });
}
