const std = @import("std");
const git_symbols = @import("git_symbols.zig");

const Allocator = std.mem.Allocator;

const Pair = struct { from: []const u8, to: []const u8 };

const Block = struct {
    new_start: u32,
    old: std.ArrayList([]const u8) = .empty,
    new: std.ArrayList([]const u8) = .empty,
};

const File = struct {
    path: []const u8,
    note: ?[]const u8 = null,
    added: usize = 0,
    removed: usize = 0,
    blocks: std.ArrayList(Block) = .empty,
};

const Parsed = struct {
    preamble: std.ArrayList([]const u8) = .empty,
    files: std.ArrayList(File) = .empty,
};

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

fn nextToken(text: []const u8, at: usize) usize {
    if (at >= text.len) return at;
    if (!isWord(text[at])) return at + 1;
    var end = at;
    while (end < text.len and isWord(text[end])) end += 1;
    return end;
}

pub fn substitution(old: []const u8, new: []const u8) ?Pair {
    var found: ?Pair = null;
    var i: usize = 0;
    var j: usize = 0;
    while (i < old.len and j < new.len) {
        const i_end = nextToken(old, i);
        const j_end = nextToken(new, j);
        const a = old[i..i_end];
        const b = new[j..j_end];
        i = i_end;
        j = j_end;
        if (std.mem.eql(u8, a, b)) continue;
        if (!isWord(a[0]) or !isWord(b[0])) return null;
        if (found) |pair| {
            if (!std.mem.eql(u8, pair.from, a) or !std.mem.eql(u8, pair.to, b)) return null;
        } else found = .{ .from = a, .to = b };
    }
    if (i != old.len or j != new.len) return null;
    return found;
}

fn hunkNewStart(line: []const u8) ?u32 {
    const plus = std.mem.indexOfScalar(u8, line, '+') orelse return null;
    var end = plus + 1;
    while (end < line.len and std.ascii.isDigit(line[end])) end += 1;
    return std.fmt.parseInt(u32, line[plus + 1 .. end], 10) catch null;
}

fn stripPrefix(path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, "a/") or std.mem.startsWith(u8, path, "b/")) return path[2..];
    return path;
}

fn gitPath(line: []const u8) []const u8 {
    const at = std.mem.lastIndexOf(u8, line, " b/") orelse return line;
    return line[at + 3 ..];
}

fn parse(arena: Allocator, text: []const u8) !Parsed {
    var out: Parsed = .{};
    var file: ?*File = null;
    var in_hunk = false;
    var new_line: u32 = 0;
    var block: ?*Block = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            try out.files.append(arena, .{ .path = gitPath(line) });
            file = &out.files.items[out.files.items.len - 1];
            in_hunk = false;
            block = null;
            continue;
        }
        const f = file orelse {
            if (line.len != 0) try out.preamble.append(arena, line);
            continue;
        };
        if (!in_hunk) {
            if (std.mem.startsWith(u8, line, "+++ ") and !std.mem.eql(u8, line[4..], "/dev/null")) f.path = stripPrefix(line[4..]);
            if (std.mem.startsWith(u8, line, "new file")) f.note = "new";
            if (std.mem.startsWith(u8, line, "deleted file")) f.note = "deleted";
            if (std.mem.startsWith(u8, line, "rename from ")) f.note = try std.fmt.allocPrint(arena, "renamed from {s}", .{line["rename from ".len..]});
            if (std.mem.startsWith(u8, line, "Binary files")) f.note = "binary";
        }
        if (std.mem.startsWith(u8, line, "@@")) {
            in_hunk = true;
            block = null;
            new_line = hunkNewStart(line) orelse 0;
            continue;
        }
        if (!in_hunk or line.len == 0) {
            block = null;
            continue;
        }
        switch (line[0]) {
            '-', '+' => {
                const adding = line[0] == '+';
                if (block == null or (!adding and block.?.new.items.len != 0)) {
                    try f.blocks.append(arena, .{ .new_start = new_line });
                    block = &f.blocks.items[f.blocks.items.len - 1];
                }
                if (adding) {
                    try block.?.new.append(arena, line[1..]);
                    f.added += 1;
                    new_line += 1;
                } else {
                    try block.?.old.append(arena, line[1..]);
                    f.removed += 1;
                }
            },
            '\\' => {},
            else => {
                block = null;
                new_line += 1;
            },
        }
    }
    return out;
}

fn pairKey(arena: Allocator, pair: Pair) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}\x00{s}", .{ pair.from, pair.to });
}

fn collapsible(block: Block) bool {
    if (block.old.items.len == 0 or block.old.items.len != block.new.items.len) return false;
    for (block.old.items, block.new.items) |a, b| {
        if (substitution(a, b) == null) return false;
    }
    return true;
}

const Group = struct { pair: Pair, lines: std.ArrayList(u32) = .empty };

fn writeLines(w: *std.Io.Writer, lines: []const u32) !void {
    var i: usize = 0;
    while (i < lines.len) {
        var j = i;
        while (j + 1 < lines.len and lines[j + 1] == lines[j] + 1) j += 1;
        if (i != 0) try w.writeByte(',');
        if (j == i) try w.print("{d}", .{lines[i]}) else try w.print("{d}-{d}", .{ lines[i], lines[j] });
        i = j + 1;
    }
}

fn reportOf(summary: ?*const git_symbols.Summary, path: []const u8) ?git_symbols.FileReport {
    const s = summary orelse return null;
    for (s.files) |file| {
        if (std.mem.eql(u8, file.path, path)) return file;
    }
    return null;
}

fn writeSymbols(w: *std.Io.Writer, report: git_symbols.FileReport) !void {
    for (report.symbols) |sym| {
        const mark: u8 = switch (sym.change) {
            .added => '+',
            .removed => '-',
            .changed => '~',
        };
        try w.print(" {c}{s}", .{ mark, sym.ref });
    }
}

pub fn condense(gpa: Allocator, text: []const u8, summary: ?*const git_symbols.Summary) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = try parse(arena, text);

    var counts: std.StringHashMapUnmanaged(usize) = .empty;
    for (parsed.files.items) |file| for (file.blocks.items) |block| {
        const paired = @min(block.old.items.len, block.new.items.len);
        for (block.old.items[0..paired], block.new.items[0..paired]) |a, b| {
            const pair = substitution(a, b) orelse continue;
            const gop = try counts.getOrPut(arena, try pairKey(arena, pair));
            gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
        }
    };

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    for (parsed.preamble.items) |line| try w.print("{s}\n", .{line});
    var added: usize = 0;
    var removed: usize = 0;
    for (parsed.files.items) |file| {
        added += file.added;
        removed += file.removed;
    }
    try w.print("{d} files +{d} -{d}\n", .{ parsed.files.items.len, added, removed });
    for (parsed.files.items) |file| {
        try w.print("{s} +{d} -{d}", .{ file.path, file.added, file.removed });
        if (file.note) |note| try w.print(" ({s})", .{note});
        if (reportOf(summary, file.path)) |report| try writeSymbols(w, report);
        try w.writeByte('\n');
        var groups: std.ArrayList(Group) = .empty;
        for (file.blocks.items) |block| {
            const repeated = collapsible(block) and for (block.old.items, block.new.items) |a, b| {
                if (counts.get(try pairKey(arena, substitution(a, b).?)).? < 2) break false;
            } else true;
            if (!repeated) {
                try w.print("@{d}\n", .{block.new_start});
                for (block.old.items) |line| try w.print("-{s}\n", .{line});
                for (block.new.items) |line| try w.print("+{s}\n", .{line});
                continue;
            }
            for (block.old.items, block.new.items, 0..) |a, b, i| {
                const pair = substitution(a, b).?;
                const line: u32 = block.new_start + @as(u32, @intCast(i));
                for (groups.items) |*g| {
                    if (std.mem.eql(u8, g.pair.from, pair.from) and std.mem.eql(u8, g.pair.to, pair.to)) {
                        try g.lines.append(arena, line);
                        break;
                    }
                } else {
                    try groups.append(arena, .{ .pair = pair });
                    try groups.items[groups.items.len - 1].lines.append(arena, line);
                }
            }
        }
        for (groups.items) |g| {
            try w.writeByte('@');
            try writeLines(w, g.lines.items);
            try w.print(" {s}->{s}\n", .{ g.pair.from, g.pair.to });
        }
    }
    const written = std.mem.trimEnd(u8, out.written(), "\n");
    return gpa.dupe(u8, written);
}

const testing = std.testing;

test "a word for word substitution is one pair, anything else is not" {
    const pair = substitution("\tif (isOld(x) && isOld(y)) {", "\tif (isNew(x) && isNew(y)) {").?;
    try testing.expectEqualStrings("isOld", pair.from);
    try testing.expectEqualStrings("isNew", pair.to);
    try testing.expect(substitution("a + isOld(x)", "a - isNew(x)") == null);
    try testing.expect(substitution("a + b", "a - b") == null);
    try testing.expect(substitution("isOld(x, y)", "isNew(y, x)") == null);
    try testing.expect(substitution("f(a, b)", "f(c, d)") == null);
    try testing.expect(substitution("same", "same") == null);
    try testing.expect(substitution("f(x)", "f(x, y)") == null);
}

test "a repeated rename across files collapses to line numbers, a one-off edit keeps its lines" {
    const diff =
        \\diff --git a/a.js b/a.js
        \\index 1..2 100644
        \\--- a/a.js
        \\+++ b/a.js
        \\@@ -9,7 +9,7 @@ function f() {
        \\ context
        \\ context
        \\-  return isOld(x);
        \\+  return isNew(x);
        \\ context
        \\@@ -20,3 +20,3 @@
        \\-  const k = 1;
        \\+  const k = 2;
        \\diff --git a/b.js b/b.js
        \\index 1..2 100644
        \\--- a/b.js
        \\+++ b/b.js
        \\@@ -1,2 +1,3 @@
        \\-const { isOld } = require("./a");
        \\+const { isNew } = require("./a");
        \\+const extra = true;
        \\ tail
        \\
    ;
    const text = try condense(testing.allocator, diff, null);
    defer testing.allocator.free(text);
    errdefer std.debug.print("{s}\n", .{text});
    try testing.expect(std.mem.indexOf(u8, text, "2 files +4 -3") != null);
    try testing.expect(std.mem.indexOf(u8, text, "@11 isOld->isNew") != null);
    try testing.expect(std.mem.indexOf(u8, text, "@20\n-  const k = 1;\n+  const k = 2;") != null);
    try testing.expect(std.mem.indexOf(u8, text, "+const extra = true;") != null);
    try testing.expect(std.mem.indexOf(u8, text, "-const { isOld } = require(\"./a\");") != null);
    try testing.expect(std.mem.indexOf(u8, text, "context") == null);
    try testing.expect(std.mem.indexOf(u8, text, "index 1..2") == null);
}

test "consecutive collapsed lines print as a range and a single substitution is shown raw" {
    var diff: std.ArrayList(u8) = .empty;
    defer diff.deinit(testing.allocator);
    try diff.appendSlice(testing.allocator, "diff --git a/x.txt b/x.txt\n--- a/x.txt\n+++ b/x.txt\n@@ -1,3 +1,3 @@\n");
    for (0..3) |i| try diff.print(testing.allocator, "-old {d}\n", .{i});
    for (0..3) |i| try diff.print(testing.allocator, "+new {d}\n", .{i});
    try diff.appendSlice(testing.allocator, "diff --git a/y.txt b/y.txt\n--- a/y.txt\n+++ b/y.txt\n@@ -1 +1 @@\n-one\n+two\n");
    const text = try condense(testing.allocator, diff.items, null);
    defer testing.allocator.free(text);
    errdefer std.debug.print("{s}\n", .{text});
    try testing.expect(std.mem.indexOf(u8, text, "@1-3 old->new") != null);
    try testing.expect(std.mem.indexOf(u8, text, "@1\n-one\n+two") != null);
}
