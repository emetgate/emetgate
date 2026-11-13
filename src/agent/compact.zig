const std = @import("std");
const ledger_mod = @import("ledger.zig");
const wrap = @import("wrap.zig");
const reply_contract = @import("../protocol/reply_contract.zig");

const Allocator = std.mem.Allocator;
const Ledger = ledger_mod.Ledger;
const Handle = ledger_mod.Handle;
const Hash = ledger_mod.Hash;
const Target = ledger_mod.Target;

pub const Threshold = struct {
    max_chars: usize = 1200,
    head_chars: usize = 700,
};

pub const Outcome = struct {
    text: []u8,
    compacted: bool,
    handle: ?Handle,
};

pub fn compact(
    gpa: Allocator,
    ledger: *Ledger,
    tool_name: []const u8,
    targets: []const Target,
    args_json: []const u8,
    result_text: []const u8,
    is_error: bool,
    merkle_root: Hash,
    threshold: Threshold,
) !Outcome {
    if (is_error or result_text.len <= threshold.max_chars) {
        return .{ .text = try gpa.dupe(u8, result_text), .compacted = false, .handle = null };
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const claim = try wrap.claim(arena, tool_name, result_text, is_error);
    ledger.tick();
    const handle = try ledger.register(.{
        .claim = claim,
        .body = result_text,
        .merkle_root = merkle_root,
        .targets = targets,
        .tool_use_id = "",
        .tool = tool_name,
        .args = args_json,
        .msg_index = 0,
    });

    const text = try digest(gpa, tool_name, result_text, handle, threshold.head_chars);
    return .{ .text = text, .compacted = true, .handle = handle };
}

pub const max_map_files: usize = 80;

fn digest(gpa: Allocator, tool_name: []const u8, text: []const u8, handle: Handle, head_chars: usize) Allocator.Error![]u8 {
    if (std.mem.eql(u8, tool_name, "emetgate_search")) {
        if (try searchDigest(gpa, text, handle)) |d| return d;
    }
    return genericDigest(gpa, text, handle, head_chars);
}

fn genericDigest(gpa: Allocator, text: []const u8, handle: Handle, head_chars: usize) Allocator.Error![]u8 {
    const head = headOf(text, head_chars);
    const hidden = text.len - head.len;
    const foot = footerOf(text);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, head);
    const trailer = try std.fmt.allocPrint(gpa, "\n\u{2026} +{d} chars collapsed \u{00B7} emetgate_expand {{\"handle\":\"{s}\"}}\n", .{ hidden, &handle });
    defer gpa.free(trailer);
    try out.appendSlice(gpa, trailer);
    if (foot.len != 0 and @intFromPtr(foot.ptr) >= @intFromPtr(text.ptr) + head.len) {
        try out.appendSlice(gpa, foot);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

fn searchDigest(gpa: Allocator, text: []const u8, handle: Handle) Allocator.Error!?[]u8 {
    if (std.mem.indexOf(u8, text, "\n--- ") != null) return null;
    const foot = footerOf(text);
    var map: std.ArrayList(u8) = .empty;
    defer map.deinit(gpa);
    var files: usize = 0;
    var hits: usize = 0;
    var listed: usize = 0;
    var have_cur = false;
    var cur_name: []const u8 = "";
    var cur_count: usize = 0;

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (@intFromPtr(line.ptr) == @intFromPtr(foot.ptr)) continue;
        const c0 = line[0];
        const is_hit = (c0 >= '0' and c0 <= '9') or c0 == '|';
        if (is_hit) {
            if (have_cur) cur_count += 1;
            continue;
        }
        if (c0 == ' ' or c0 == '\t' or c0 == 0xE2) continue;
        if (have_cur) {
            try appendFile(gpa, &map, cur_name, cur_count, &listed);
            files += 1;
            hits += cur_count;
        }
        cur_name = line;
        cur_count = 0;
        have_cur = true;
    }
    if (have_cur) {
        try appendFile(gpa, &map, cur_name, cur_count, &listed);
        files += 1;
        hits += cur_count;
    }
    if (files == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const header = try std.fmt.allocPrint(gpa, "{d} file(s) matched, {d} hit(s); which file and how many:\n", .{ files, hits });
    defer gpa.free(header);
    try out.appendSlice(gpa, header);
    try out.appendSlice(gpa, map.items);
    if (files > listed) {
        const more = try std.fmt.allocPrint(gpa, "  \u{2026} {d} more file(s)\n", .{files - listed});
        defer gpa.free(more);
        try out.appendSlice(gpa, more);
    }
    const trailer = try std.fmt.allocPrint(gpa, "\u{2026} full hit lines collapsed \u{00B7} emetgate_expand {{\"handle\":\"{s}\"}}\n", .{&handle});
    defer gpa.free(trailer);
    try out.appendSlice(gpa, trailer);
    if (foot.len != 0) {
        try out.appendSlice(gpa, foot);
        try out.append(gpa, '\n');
    }
    return try out.toOwnedSlice(gpa);
}

fn appendFile(gpa: Allocator, map: *std.ArrayList(u8), name: []const u8, count: usize, listed: *usize) Allocator.Error!void {
    if (listed.* >= max_map_files) return;
    const line = try std.fmt.allocPrint(gpa, "  {s} ({d})\n", .{ name, count });
    defer gpa.free(line);
    try map.appendSlice(gpa, line);
    listed.* += 1;
}

fn footerOf(text: []const u8) []const u8 {
    var end = text.len;
    while (end > 0 and (text[end - 1] == '\n' or text[end - 1] == '\r')) end -= 1;
    const start = if (std.mem.lastIndexOfScalar(u8, text[0..end], '\n')) |nl| nl + 1 else 0;
    return text[start..end];
}

pub const Expansion = struct {
    text: []u8,
    found: bool,
    stale: bool,
};

pub fn parseHandle(handle_text: []const u8) ?Handle {
    const clean = if (handle_text.len != 0 and handle_text[0] == '#') handle_text[1..] else handle_text;
    if (clean.len != ledger_mod.handle_len) return null;
    var handle: Handle = undefined;
    @memcpy(&handle, clean[0..ledger_mod.handle_len]);
    return handle;
}

pub fn expand(gpa: Allocator, ledger: *Ledger, handle_text: []const u8, current_root: Hash, file: ?[]const u8) Allocator.Error!Expansion {
    return expandPage(gpa, ledger, handle_text, current_root, file, 0);
}

/// The stashed body from byte `offset`, cut at a line end to the expand reply
/// budget; a cut ends with the trailer naming the offset that continues it.
pub fn expandPage(gpa: Allocator, ledger: *Ledger, handle_text: []const u8, current_root: Hash, file: ?[]const u8, offset: usize) Allocator.Error!Expansion {
    const handle = parseHandle(handle_text) orelse {
        return .{ .text = try gpa.dupe(u8, "expand: malformed handle; copy the exact handle from the collapsed line"), .found = false, .stale = false };
    };
    const got = ledger.expand(handle, current_root) orelse {
        return .{ .text = try gpa.dupe(u8, "expand: unknown handle; it may be from an earlier server run, re-run the original tool"), .found = false, .stale = false };
    };
    const body = if (file) |f| sliceFile(got.body, f) else got.body;
    const missing = file != null and body.len == got.body.len and !fileHeaderPresent(got.body, file.?);
    const stale = got.state == .stale;
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    if (stale) {
        w.writeAll("(stale: the source changed since this was captured; re-run the tool for the current version)\n") catch return error.OutOfMemory;
    } else if (missing) {
        w.print("(no section for \"{s}\" in this result; returning the whole body)\n", .{file.?}) catch return error.OutOfMemory;
    }
    const from = reply_contract.charStart(body, offset);
    const cut = reply_contract.cut(body[from..], reply_contract.room(.expand), .plain);
    w.writeAll(cut.kept) catch return error.OutOfMemory;
    if (!cut.whole) {
        if (cut.kept.len != 0 and cut.kept[cut.kept.len - 1] != '\n') w.writeByte('\n') catch return error.OutOfMemory;
        const next = from + cut.kept.len;
        reply_contract.writeTrailer(w, "bytes {d}-{d} of {s}", .{ next, body.len, handle_text }, "emetgate_expand", .{ .handle = handle_text, .file = file, .offset = next }) catch return error.OutOfMemory;
    }
    return .{ .text = try out.toOwnedSlice(), .found = true, .stale = stale };
}

fn isHeaderLine(line: []const u8) bool {
    if (line.len == 0) return false;
    const c0 = line[0];
    return !((c0 >= '0' and c0 <= '9') or c0 == '|' or c0 == ' ' or c0 == '\t' or c0 == 0xE2);
}

fn matchesFile(line: []const u8, file: []const u8) bool {
    return std.mem.eql(u8, line, file) or std.mem.endsWith(u8, line, file);
}

fn fileHeaderPresent(body: []const u8, file: []const u8) bool {
    var pos: usize = 0;
    while (pos <= body.len) {
        const nl = std.mem.indexOfScalarPos(u8, body, pos, '\n') orelse body.len;
        if (isHeaderLine(body[pos..nl]) and matchesFile(body[pos..nl], file)) return true;
        if (nl == body.len) break;
        pos = nl + 1;
    }
    return false;
}

fn sliceFile(body: []const u8, file: []const u8) []const u8 {
    var pos: usize = 0;
    var target_start: ?usize = null;
    while (pos <= body.len) {
        const nl = std.mem.indexOfScalarPos(u8, body, pos, '\n') orelse body.len;
        const line = body[pos..nl];
        if (isHeaderLine(line)) {
            if (target_start != null) return body[target_start.?..pos];
            if (matchesFile(line, file)) target_start = pos;
        }
        if (nl == body.len) break;
        pos = nl + 1;
    }
    if (target_start) |ts| return body[ts..];
    return body;
}

fn headOf(text: []const u8, limit: usize) []const u8 {
    if (text.len <= limit) return text;
    var end = limit;
    if (std.mem.lastIndexOfScalar(u8, text[0..limit], '\n')) |nl| {
        if (nl > limit / 2) end = nl;
    }
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

const testing = std.testing;

fn root(tag: []const u8) Hash {
    return @import("../engine/symbol.zig").hashOf(tag);
}

test "a small result passes through unchanged and stores nothing" {
    var l: Ledger = .init(testing.allocator);
    defer l.deinit();
    const out = try compact(testing.allocator, &l, "emetgate_read_symbol", &.{}, "{}", "short body", false, root("r1"), .{});
    defer testing.allocator.free(out.text);
    try testing.expect(!out.compacted);
    try testing.expectEqualStrings("short body", out.text);
    try testing.expectEqual(@as(usize, 0), l.entries.items.len);
}

test "an error passes through even when large" {
    var l: Ledger = .init(testing.allocator);
    defer l.deinit();
    const big = "E" ** 5000;
    const out = try compact(testing.allocator, &l, "emetgate_try", &.{}, "{}", big, true, root("r1"), .{});
    defer testing.allocator.free(out.text);
    try testing.expect(!out.compacted);
    try testing.expectEqual(@as(usize, 0), l.entries.items.len);
}

test "a large result is compacted to a head plus an expand handle and the body is stored" {
    var l: Ledger = .init(testing.allocator);
    defer l.deinit();
    const big = "line\n" ** 2000;
    const out = try compact(testing.allocator, &l, "emetgate_search", &.{}, "{}", big, false, root("r1"), .{});
    defer testing.allocator.free(out.text);
    try testing.expect(out.compacted);
    try testing.expect(out.text.len < big.len);
    try testing.expect(std.mem.indexOf(u8, out.text, "emetgate_expand") != null);
    try testing.expect(std.mem.indexOf(u8, out.text, &out.handle.?) != null);
    try testing.expectEqual(@as(usize, 1), l.entries.items.len);
}

test "search compaction yields a file match-map and preserves the certificate footer" {
    var l: Ledger = .init(testing.allocator);
    defer l.deinit();
    const body =
        "|1 const Allocator = std.mem.Allocator;\n" ++
        "src/engine/alloc_bridge.zig\n" ++
        "104:fn backingAllocator() std.mem.Allocator {\n" ++
        "src/engine/checks.zig\n" ++
        "13|1\n" ++
        "23:pub const CollectError = Unrunnable || Allocator.Error;\n" ++
        "109:pub fn validate(gpa: Allocator, spec: []const u8) Error!void {\n" ++
        "partial: matches 1-42 of 520; next offset:42\n";
    const out = try compact(testing.allocator, &l, "emetgate_search", &.{}, "{}", body, false, root("r1"), .{ .max_chars = 100 });
    defer testing.allocator.free(out.text);
    try testing.expect(out.compacted);
    try testing.expect(std.mem.indexOf(u8, out.text, "src/engine/alloc_bridge.zig (1)") != null);
    try testing.expect(std.mem.indexOf(u8, out.text, "src/engine/checks.zig (3)") != null);
    try testing.expect(std.mem.indexOf(u8, out.text, "partial: matches 1-42 of 520") != null);
    try testing.expect(std.mem.indexOf(u8, out.text, "emetgate_expand") != null);
    try testing.expect(out.text.len < body.len);
}

test "a non-search large result keeps its certificate footer in the generic digest" {
    var l: Ledger = .init(testing.allocator);
    defer l.deinit();
    const body = ("x: body line\n" ** 400) ++ "CERTIFICATE: no edge is missing; unresolved 0\n";
    const out = try compact(testing.allocator, &l, "emetgate_evidence", &.{}, "{}", body, false, root("r1"), .{});
    defer testing.allocator.free(out.text);
    try testing.expect(out.compacted);
    try testing.expect(out.text.len < body.len);
    try testing.expect(std.mem.indexOf(u8, out.text, "CERTIFICATE: no edge is missing") != null);
}

test "expand returns the stored body fresh, and flags stale when the root changed" {
    var l: Ledger = .init(testing.allocator);
    defer l.deinit();
    const big = "data " ** 1000;
    const out = try compact(testing.allocator, &l, "emetgate_search", &.{}, "{}", big, false, root("r1"), .{});
    defer testing.allocator.free(out.text);

    var hbuf: [ledger_mod.handle_len]u8 = out.handle.?;
    const fresh = try expand(testing.allocator, &l, &hbuf, root("r1"), null);
    defer testing.allocator.free(fresh.text);
    try testing.expect(fresh.found and !fresh.stale);
    try testing.expectEqualStrings(big, fresh.text);

    const stale = try expand(testing.allocator, &l, &hbuf, root("r2"), null);
    defer testing.allocator.free(stale.text);
    try testing.expect(stale.found and stale.stale);
    try testing.expect(std.mem.indexOf(u8, stale.text, "stale") != null);
}

test "expand of an unknown or malformed handle is a helpful message, not a crash" {
    var l: Ledger = .init(testing.allocator);
    defer l.deinit();
    const unknown = try expand(testing.allocator, &l, "abcdef012345", root("r1"), null);
    defer testing.allocator.free(unknown.text);
    try testing.expect(!unknown.found);

    const malformed = try expand(testing.allocator, &l, "xyz", root("r1"), null);
    defer testing.allocator.free(malformed.text);
    try testing.expect(!malformed.found);
    try testing.expect(std.mem.indexOf(u8, malformed.text, "malformed") != null);
}

test "granular expand returns only the requested file's section" {
    var l: Ledger = .init(testing.allocator);
    defer l.deinit();
    const body =
        "src/a.zig\n" ++
        "10:fn one() void {}\n" ++
        "src/b.zig\n" ++
        "20:fn two() void {}\n" ++
        "30:fn three() void {}\n" ++
        "partial: matches 1-3 of 3\n";
    const h = try l.register(.{ .claim = "search", .body = body, .merkle_root = root("r1"), .msg_index = 0 });

    const one = try expand(testing.allocator, &l, &h, root("r1"), "src/a.zig");
    defer testing.allocator.free(one.text);
    try testing.expect(std.mem.indexOf(u8, one.text, "fn one") != null);
    try testing.expect(std.mem.indexOf(u8, one.text, "fn two") == null);

    const two = try expand(testing.allocator, &l, &h, root("r1"), "b.zig");
    defer testing.allocator.free(two.text);
    try testing.expect(std.mem.indexOf(u8, two.text, "fn two") != null);
    try testing.expect(std.mem.indexOf(u8, two.text, "fn three") != null);
    try testing.expect(std.mem.indexOf(u8, two.text, "fn one") == null);

    const missing = try expand(testing.allocator, &l, &h, root("r1"), "nope.zig");
    defer testing.allocator.free(missing.text);
    try testing.expect(std.mem.indexOf(u8, missing.text, "no section") != null);
}
