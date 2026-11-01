const std = @import("std");
const output_digest = @import("output_digest.zig");
const diagnostics = @import("diagnostics.zig");

const Allocator = std.mem.Allocator;

pub const per_test_lines: usize = 40;
pub const per_test_bytes: usize = 2048;
pub const cap: usize = 6144;
const label_reserve: usize = 360;
const max_line: usize = 300;
const marker_bytes: usize = 28;
const shown_names = 5;
const max_name: usize = 60;

pub const Stage = enum { tests, typecheck };

pub const Rendered = struct {
    text: []u8,
    blocks: usize,
    shown: usize,
};

const Block = struct {
    id: []const u8,
    title: []const u8,
    body: []const []const u8,
};

const Blocks = std.ArrayList(Block);

const Lines = []const []const u8;

fn trimLeft(line: []const u8) []const u8 {
    return std.mem.trimStart(u8, line, " \t");
}

fn indentOf(line: []const u8) usize {
    return line.len - trimLeft(line).len;
}

fn containsAny(text: []const u8, marks: []const []const u8) bool {
    for (marks) |mark| if (std.mem.indexOf(u8, text, mark) != null) return true;
    return false;
}

fn startsAny(text: []const u8, marks: []const []const u8) bool {
    for (marks) |mark| if (std.mem.startsWith(u8, text, mark)) return true;
    return false;
}

fn cleanLines(arena: Allocator, streams: []const []const u8) !Lines {
    var lines: std.ArrayList([]const u8) = .empty;
    for (streams) |stream| {
        var it = std.mem.splitScalar(u8, stream, '\n');
        while (it.next()) |raw| try lines.append(arena, try output_digest.stripAnsi(arena, raw));
    }
    return lines.items;
}

fn add(arena: Allocator, out: *Blocks, id: []const u8, title: []const u8, body: Lines) !void {
    try out.append(arena, .{ .id = id, .title = title, .body = body });
}

fn pytestHeader(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "___") or !std.mem.endsWith(u8, line, "___")) return null;
    const name = std.mem.trim(u8, line, "_ ");
    return if (name.len == 0) null else name;
}

fn equalsRule(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "==") and std.mem.endsWith(u8, line, "==");
}

fn dottedTailIs(id: []const u8, key: []const u8) bool {
    const sep = std.mem.indexOf(u8, id, "::") orelse return false;
    var tail = id[sep + 2 ..];
    var rest = key;
    while (tail.len != 0) {
        if (std.mem.startsWith(u8, tail, "::")) {
            if (rest.len == 0 or rest[0] != '.') return false;
            tail = tail[2..];
            rest = rest[1..];
            continue;
        }
        if (rest.len == 0 or rest[0] != tail[0]) return false;
        tail = tail[1..];
        rest = rest[1..];
    }
    return rest.len == 0;
}

fn pytestKey(name: []const u8) []const u8 {
    const prefixes = [_][]const u8{ "ERROR collecting ", "ERROR at setup of ", "ERROR at teardown of " };
    for (prefixes) |prefix| if (std.mem.startsWith(u8, name, prefix)) return name[prefix.len..];
    return name;
}

fn pytest(arena: Allocator, lines: Lines, out: *Blocks) !void {
    var ids: std.ArrayList([]const u8) = .empty;
    for (lines) |line| {
        const rest = if (std.mem.startsWith(u8, line, "FAILED ")) line[7..] else if (std.mem.startsWith(u8, line, "ERROR ")) line[6..] else continue;
        const end = std.mem.indexOf(u8, rest, " - ") orelse rest.len;
        try ids.append(arena, std.mem.trimEnd(u8, rest[0..end], " "));
    }
    const used = try arena.alloc(bool, ids.items.len);
    @memset(used, false);
    var in_section = false;
    var name: ?[]const u8 = null;
    var start: usize = 0;
    for (lines, 0..) |line, i| {
        const header = if (in_section) pytestHeader(line) else null;
        const rule = equalsRule(line);
        if (header == null and !rule) continue;
        if (name) |open| try pytestBlock(arena, out, open, lines[start..i], ids.items, used);
        name = null;
        if (rule) {
            in_section = std.mem.indexOf(u8, line, " FAILURES ") != null or std.mem.indexOf(u8, line, " ERRORS ") != null;
            continue;
        }
        name = header;
        start = i + 1;
    }
    if (name) |open| try pytestBlock(arena, out, open, lines[start..], ids.items, used);
}

fn pytestBlock(arena: Allocator, out: *Blocks, name: []const u8, raw: Lines, ids: []const []const u8, used: []bool) !void {
    var body: std.ArrayList([]const u8) = .empty;
    for (raw) |line| {
        if (std.mem.startsWith(u8, line, "-") and std.mem.indexOf(u8, line, "generated xml file") != null) continue;
        try body.append(arena, line);
    }
    const key = pytestKey(name);
    var id = key;
    for (ids, used) |candidate, *taken| {
        if (taken.*) continue;
        if (std.mem.eql(u8, candidate, key) or dottedTailIs(candidate, key)) {
            taken.* = true;
            id = candidate;
            break;
        }
    }
    const errored = std.mem.startsWith(u8, name, "ERROR ");
    const title = if (errored) try std.fmt.allocPrint(arena, "ERROR {s}", .{id}) else id;
    try add(arena, out, id, title, body.items);
}

fn dotnetSummaryWord(line: []const u8) ?[]const u8 {
    const bang = std.mem.indexOfScalar(u8, line, '!') orelse return null;
    const head = std.mem.trim(u8, line[0..bang], " ");
    if (head.len == 0 or std.mem.indexOfScalar(u8, head, ' ') != null) return null;
    const tail = trimLeft(line[bang + 1 ..]);
    if (!std.mem.startsWith(u8, tail, "- ")) return null;
    const after = trimLeft(tail[2..]);
    const colon = std.mem.indexOfScalar(u8, after, ':') orelse return null;
    const word = after[0..colon];
    if (word.len == 0 or std.mem.indexOfScalar(u8, word, ' ') != null) return null;
    const count = trimLeft(after[colon + 1 ..]);
    if (count.len == 0 or !std.ascii.isDigit(count[0]) or std.mem.indexOfScalar(u8, count, ',') == null) return null;
    return word;
}

const DotnetHeader = struct { word: []const u8, name: []const u8 };

fn dotnetHeader(line: []const u8) ?DotnetHeader {
    if (line.len < 4 or !std.mem.startsWith(u8, line, "  ") or line[2] == ' ' or line[line.len - 1] != ']') return null;
    const rest = line[2..];
    const space = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    const open = std.mem.lastIndexOf(u8, rest, " [") orelse return null;
    if (open <= space) return null;
    const duration = rest[open + 2 .. rest.len - 1];
    if (duration.len < 2 or !std.ascii.isAlphabetic(duration[duration.len - 1])) return null;
    if (std.mem.indexOfAny(u8, duration, "0123456789") == null) return null;
    const name = std.mem.trim(u8, rest[space + 1 .. open], " ");
    if (name.len == 0) return null;
    return .{ .word = rest[0..space], .name = name };
}

fn dotnet(arena: Allocator, lines: Lines, out: *Blocks) !void {
    var word: []const u8 = "Failed";
    for (lines) |line| if (dotnetSummaryWord(line)) |found| {
        word = found;
        break;
    };
    var name: ?[]const u8 = null;
    var start: usize = 0;
    for (lines, 0..) |line, i| {
        const header = dotnetHeader(line);
        const ends = header != null or line.len == 0 or dotnetSummaryWord(line) != null;
        if (!ends) continue;
        if (name) |open| try add(arena, out, open, open, lines[start..i]);
        name = null;
        const h = header orelse continue;
        if (!std.mem.eql(u8, h.word, word)) continue;
        name = h.name;
        start = i + 1;
    }
    if (name) |open| try add(arena, out, open, open, lines[start..]);
}

fn jest(arena: Allocator, lines: Lines, out: *Blocks) !void {
    var name: ?[]const u8 = null;
    var start: usize = 0;
    for (lines, 0..) |line, i| {
        const t = trimLeft(line);
        const header = indentOf(line) <= 4 and std.mem.startsWith(u8, t, "\u{25cf} ");
        const ends = header or (line.len != 0 and indentOf(line) == 0);
        if (!ends) continue;
        if (name) |open| try add(arena, out, open, open, lines[start..i]);
        name = null;
        if (!header) continue;
        const found = std.mem.trim(u8, t["\u{25cf} ".len..], " ");
        if (found.len == 0 or std.mem.eql(u8, found, "Console")) continue;
        name = found;
        start = i + 1;
    }
    if (name) |open| try add(arena, out, open, open, lines[start..]);
}

fn vitest(arena: Allocator, lines: Lines, out: *Blocks) !void {
    var in_section = false;
    var name: ?[]const u8 = null;
    var start: usize = 0;
    for (lines, 0..) |line, i| {
        const t = trimLeft(line);
        const banner = std.mem.startsWith(u8, t, "\u{23af}");
        const summary = std.mem.startsWith(u8, t, "Test Files ");
        const header = in_section and std.mem.startsWith(u8, t, "FAIL ");
        if (!banner and !summary and !header) continue;
        if (name) |open| try add(arena, out, open, open, lines[start..i]);
        name = null;
        if (banner) {
            if (std.mem.indexOf(u8, t, "Failed Tests") != null or std.mem.indexOf(u8, t, "Failed Suites") != null) in_section = true;
            continue;
        }
        if (summary) {
            in_section = false;
            continue;
        }
        name = std.mem.trim(u8, t[5..], " ");
        start = i + 1;
    }
    if (name) |open| try add(arena, out, open, open, lines[start..]);
}

fn withoutDuration(text: []const u8) []const u8 {
    const t = std.mem.trimEnd(u8, text, " ");
    if (!std.mem.endsWith(u8, t, ")")) return t;
    const open = std.mem.lastIndexOf(u8, t, " (") orelse return t;
    const inside = t[open + 2 .. t.len - 1];
    if (inside.len == 0 or !std.ascii.isDigit(inside[0])) return t;
    return t[0..open];
}

fn onlySubtests(body: Lines) bool {
    var any = false;
    for (body) |line| {
        const t = trimLeft(line);
        if (t.len == 0 or std.mem.startsWith(u8, t, "test at ")) continue;
        if (std.mem.indexOf(u8, t, "subtest") == null or std.mem.indexOf(u8, t, "failed") == null) return false;
        any = true;
    }
    return any;
}

fn nodeSpec(arena: Allocator, lines: Lines, out: *Blocks) !void {
    var section: ?usize = null;
    for (lines, 0..) |line, i| if (std.mem.eql(u8, line, "\u{2716} failing tests:")) {
        section = i + 1;
        break;
    };
    const from = section orelse return;
    var name: ?[]const u8 = null;
    var start: usize = 0;
    var location: ?usize = null;
    for (lines[from..], from..) |line, i| {
        const at = std.mem.startsWith(u8, line, "test at ");
        const header = std.mem.startsWith(u8, line, "\u{2716} ");
        if (!at and !header and !(line.len != 0 and indentOf(line) == 0)) continue;
        if (name) |open| try nodeBlock(arena, out, open, lines[start..i]);
        name = null;
        if (at) {
            location = i;
            continue;
        }
        if (!header) {
            location = null;
            continue;
        }
        name = withoutDuration(line["\u{2716} ".len..]);
        start = location orelse i + 1;
        location = null;
    }
    if (name) |open| try nodeBlock(arena, out, open, lines[start..]);
}

fn nodeBlock(arena: Allocator, out: *Blocks, name: []const u8, raw: Lines) !void {
    var body: std.ArrayList([]const u8) = .empty;
    for (raw) |line| {
        if (std.mem.startsWith(u8, line, "\u{2716} ")) continue;
        try body.append(arena, line);
    }
    if (onlySubtests(body.items)) return;
    try add(arena, out, name, name, body.items);
}

fn tap(arena: Allocator, lines: Lines, out: *Blocks) !void {
    var i: usize = 0;
    while (i < lines.len) : (i += 1) {
        const t = trimLeft(lines[i]);
        if (!std.mem.startsWith(u8, t, "not ok ")) continue;
        const dash = std.mem.indexOf(u8, t, " - ") orelse continue;
        var name = std.mem.trim(u8, t[dash + 3 ..], " ");
        if (std.mem.indexOf(u8, name, " # ")) |hash| name = name[0..hash];
        if (i + 1 >= lines.len or !std.mem.eql(u8, trimLeft(lines[i + 1]), "---")) {
            try add(arena, out, name, name, &.{});
            continue;
        }
        var end = i + 2;
        while (end < lines.len and !std.mem.eql(u8, trimLeft(lines[end]), "...")) end += 1;
        const body = lines[i + 2 .. end];
        i = end;
        var parent = false;
        for (body) |line| if (std.mem.indexOf(u8, line, "subtestsFailed") != null) {
            parent = true;
        };
        if (parent) continue;
        try add(arena, out, name, name, body);
    }
}

fn mochaHeader(line: []const u8) ?[]const u8 {
    if (indentOf(line) != 2) return null;
    const t = line[2..];
    var i: usize = 0;
    while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
    if (i == 0 or i + 1 >= t.len or t[i] != ')' or t[i + 1] != ' ') return null;
    return std.mem.trim(u8, t[i + 2 ..], " ");
}

fn mocha(arena: Allocator, lines: Lines, out: *Blocks) !void {
    var from: ?usize = null;
    for (lines, 0..) |line, i| {
        const t = std.mem.trim(u8, line, " ");
        const space = std.mem.indexOfScalar(u8, t, ' ') orelse continue;
        if (!std.mem.eql(u8, t[space..], " failing")) continue;
        _ = std.fmt.parseInt(usize, t[0..space], 10) catch continue;
        from = i + 1;
        break;
    }
    var i = from orelse return;
    while (i < lines.len) {
        const head = mochaHeader(lines[i]) orelse {
            i += 1;
            continue;
        };
        var name: std.ArrayList(u8) = .empty;
        try name.appendSlice(arena, head);
        i += 1;
        while (i < lines.len and lines[i].len != 0 and indentOf(lines[i]) > 2 and mochaHeader(lines[i]) == null) : (i += 1) {
            try name.append(arena, ' ');
            try name.appendSlice(arena, trimLeft(lines[i]));
        }
        const title = std.mem.trimEnd(u8, name.items, ":");
        const start = i;
        while (i < lines.len and mochaHeader(lines[i]) == null) i += 1;
        try add(arena, out, title, title, lines[start..i]);
    }
}

fn goVendor(line: []const u8) bool {
    return containsAny(line, &.{ "/src/runtime/", "/src/testing/", "\\src\\runtime\\", "\\src\\testing\\" }) or output_digest.isVendorFrame(line);
}

fn blank(body: Lines) bool {
    for (body) |line| if (trimLeft(line).len != 0) return false;
    return true;
}

fn go(arena: Allocator, lines: Lines, out: *Blocks) !void {
    const Found = struct { name: []const u8, body: Lines };
    var found: std.ArrayList(Found) = .empty;
    var i: usize = 0;
    while (i < lines.len) {
        const t = trimLeft(lines[i]);
        if (!std.mem.startsWith(u8, t, "--- FAIL: ")) {
            i += 1;
            continue;
        }
        const indent = indentOf(lines[i]);
        const rest = t["--- FAIL: ".len..];
        const name = withoutDuration(rest);
        i += 1;
        var body: std.ArrayList([]const u8) = .empty;
        var panicked = false;
        while (i < lines.len) : (i += 1) {
            const line = lines[i];
            const lt = trimLeft(line);
            if (panicked) {
                if (std.mem.startsWith(u8, line, "FAIL") or std.mem.startsWith(u8, line, "exit status") or std.mem.startsWith(u8, line, "ok ")) break;
                if (i + 1 < lines.len and lines[i + 1].len != 0 and lines[i + 1][0] == '\t' and goVendor(lines[i + 1])) {
                    i += 1;
                    continue;
                }
                try body.append(arena, line);
                continue;
            }
            if (std.mem.startsWith(u8, lt, "--- ")) break;
            if (std.mem.startsWith(u8, line, "panic: ")) {
                panicked = true;
                try body.append(arena, line);
                continue;
            }
            if (line.len != 0 and indentOf(line) <= indent) break;
            try body.append(arena, line);
        }
        try found.append(arena, .{ .name = name, .body = body.items });
    }
    for (found.items) |f| {
        var parent = false;
        if (std.mem.trim(u8, std.mem.join(arena, "", f.body) catch "", " \t").len == 0) {
            for (found.items) |other| {
                if (other.name.len > f.name.len and std.mem.startsWith(u8, other.name, f.name) and other.name[f.name.len] == '/') parent = true;
            }
        }
        if (parent) continue;
        try add(arena, out, f.name, f.name, f.body);
    }
}

fn cargo(arena: Allocator, lines: Lines, out: *Blocks) !void {
    var name: ?[]const u8 = null;
    var start: usize = 0;
    for (lines, 0..) |line, i| {
        const header = std.mem.startsWith(u8, line, "---- ") and std.mem.endsWith(u8, line, " ----") and line.len > 10;
        const ends = header or std.mem.eql(u8, line, "failures:") or std.mem.startsWith(u8, line, "test result:");
        if (!ends) continue;
        if (name) |open| try add(arena, out, open, open, lines[start..i]);
        name = null;
        if (!header) continue;
        var inner = line[5 .. line.len - 5];
        if (std.mem.endsWith(u8, inner, " stdout")) inner = inner[0 .. inner.len - 7];
        if (std.mem.endsWith(u8, inner, " stderr")) inner = inner[0 .. inner.len - 7];
        name = std.mem.trim(u8, inner, " ");
        start = i + 1;
    }
    if (name) |open| try add(arena, out, open, open, lines[start..]);
}

fn zigBuild(arena: Allocator, lines: Lines, out: *Blocks) !void {
    var i: usize = 0;
    while (i < lines.len) {
        const line = lines[i];
        i += 1;
        if (!std.mem.startsWith(u8, line, "error: '")) continue;
        const close = std.mem.indexOf(u8, line[8..], "' failed") orelse continue;
        const name = line[8..][0..close];
        const start = i;
        while (i < lines.len and (lines[i].len == 0 or lines[i][0] == ' ')) i += 1;
        try add(arena, out, name, name, lines[start..i]);
    }
}

const ZigTest = struct { name: []const u8, rest: []const u8 };

fn zigTestHeader(line: []const u8) ?ZigTest {
    var i: usize = 0;
    while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
    if (i == 0 or i >= line.len or line[i] != '/') return null;
    i += 1;
    const total = i;
    while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
    if (i == total or i >= line.len or line[i] != ' ') return null;
    const after = line[i + 1 ..];
    const dots = std.mem.indexOf(u8, after, "...") orelse return null;
    if (dots == 0) return null;
    return .{ .name = after[0..dots], .rest = after[dots + 3 ..] };
}

fn zigSummary(line: []const u8) bool {
    return (std.mem.indexOf(u8, line, " passed; ") != null and std.mem.endsWith(u8, line, " failed.")) or std.mem.startsWith(u8, line, "error: the following test command");
}

fn zigTest(arena: Allocator, lines: Lines, out: *Blocks) !void {
    var open: ?ZigTest = null;
    var start: usize = 0;
    for (lines, 0..) |line, i| {
        const header = zigTestHeader(line);
        if (header == null and !zigSummary(line)) continue;
        if (open) |o| try zigTestBlock(arena, out, o, lines[start..i]);
        open = header;
        start = i + 1;
    }
    if (open) |o| try zigTestBlock(arena, out, o, lines[start..]);
}

fn zigTestBlock(arena: Allocator, out: *Blocks, header: ZigTest, raw: Lines) !void {
    var failed = std.mem.startsWith(u8, header.rest, "FAIL");
    for (raw) |line| if (std.mem.startsWith(u8, line, "FAIL")) {
        failed = true;
    };
    if (!failed) return;
    var body: std.ArrayList([]const u8) = .empty;
    if (header.rest.len != 0) try body.append(arena, header.rest);
    try body.appendSlice(arena, raw);
    try add(arena, out, header.name, header.name, body.items);
}

fn located(line: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] == '(' and i != 0) {
            const close = std.mem.indexOfScalarPos(u8, line, i, ')') orelse return null;
            const inside = line[i + 1 .. close];
            if (inside.len == 0 or !std.ascii.isDigit(inside[0])) continue;
            if (std.mem.startsWith(u8, line[close + 1 ..], ": ")) return line[close + 3 ..];
            continue;
        }
        if (line[i] != ':' or i == 0 or i + 1 >= line.len or !std.ascii.isDigit(line[i + 1])) continue;
        var j = i + 1;
        while (j < line.len and (std.ascii.isDigit(line[j]) or line[j] == ':')) j += 1;
        if (j < line.len and line[j] == ' ' and line[j - 1] == ':') return line[j + 1 ..];
        if (j + 2 < line.len and std.mem.startsWith(u8, line[j..], " - ")) return line[j + 3 ..];
    }
    return null;
}

const excluded_errors = [_][]const u8{ "error: could not compile", "error: aborting due to", "error: the following", "error: Recipe", "error: script ", "error: process didn't exit", "error: test failed", "error: build failed", "error: Command failed" };

fn compileHeader(raw: []const u8, stage: Stage) bool {
    const line = if (std.mem.indexOf(u8, raw, " - error: ") != null) trimLeft(raw) else raw;
    if (line.len == 0 or line[0] == ' ' or line[0] == '\t') return false;
    if (startsAny(line, &excluded_errors)) return false;
    if (std.mem.startsWith(u8, line, "Traceback (most recent call last)")) return true;
    if (std.mem.startsWith(u8, line, "error[") or std.mem.startsWith(u8, line, "error: ")) return true;
    if (std.mem.indexOf(u8, line, ": 0x") != null) return false;
    const message = located(line) orelse return false;
    if (std.mem.startsWith(u8, message, "warning") or std.mem.startsWith(u8, message, "note") or std.mem.indexOf(u8, message, " warning ") != null) return false;
    if (std.ascii.indexOfIgnoreCase(message, "error") != null) return true;
    return stage == .typecheck;
}

fn continues(line: []const u8) bool {
    if (line.len == 0 or line[0] == ' ' or line[0] == '\t' or line[0] == '|') return true;
    if (startsAny(line, &.{ "note:", "help:", "= ", "referenced by:" })) return true;
    if (std.mem.indexOf(u8, line, ": note:") != null) return true;
    var i: usize = 0;
    while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
    if (i == 0) return false;
    while (i < line.len and line[i] == ' ') i += 1;
    return i < line.len and line[i] == '|';
}

fn pythonError(line: []const u8) bool {
    if (line.len == 0 or !std.ascii.isUpper(line[0])) return false;
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return false;
    const word = line[0..colon];
    if (std.mem.indexOfScalar(u8, word, ' ') != null) return false;
    return std.mem.endsWith(u8, word, "Error") or std.mem.endsWith(u8, word, "Exception");
}

fn compile(arena: Allocator, lines: Lines, stage: Stage, out: *Blocks) !void {
    var i: usize = 0;
    while (i < lines.len) {
        const line = lines[i];
        if (pythonError(line) and i != 0 and lines[i - 1].len != 0 and indentOf(lines[i - 1]) != 0) {
            var start = i;
            while (start > 0 and lines[start - 1].len != 0 and indentOf(lines[start - 1]) != 0) start -= 1;
            if (std.mem.startsWith(u8, trimLeft(lines[start]), "File \"")) try add(arena, out, line, line, lines[start..i]);
            i += 1;
            continue;
        }
        if (!compileHeader(line, stage)) {
            i += 1;
            continue;
        }
        const start = i + 1;
        i += 1;
        if (std.mem.startsWith(u8, line, "Traceback")) {
            while (i < lines.len and (lines[i].len == 0 or indentOf(lines[i]) != 0)) i += 1;
            if (i < lines.len) i += 1;
            try add(arena, out, line, line, lines[start..i]);
            continue;
        }
        while (i < lines.len and continues(lines[i]) and !compileHeader(lines[i], stage)) i += 1;
        var end = i;
        while (end > start and lines[end - 1].len == 0) end -= 1;
        if (end == start) {
            const one = try diagnostics.parse(arena, line);
            if (one.len != 0) continue;
        }
        try add(arena, out, line, line, lines[start..end]);
    }
}

fn isZigFrame(t: []const u8) bool {
    return std.mem.indexOf(u8, t, ": 0x") != null and std.mem.indexOf(u8, t, " in ") != null;
}

fn isPytestFrame(t: []const u8) bool {
    const at = std.mem.indexOf(u8, t, ": in ") orelse return false;
    var i = at;
    while (i > 0 and std.ascii.isDigit(t[i - 1])) i -= 1;
    return i != at and i > 1 and t[i - 1] == ':';
}

fn isFrame(t: []const u8) bool {
    return std.mem.startsWith(u8, t, "at ") or std.mem.startsWith(u8, t, "File \"") or isZigFrame(t) or isPytestFrame(t);
}

fn vendorFrame(t: []const u8) bool {
    return output_digest.isVendorFrame(t) or std.mem.indexOf(u8, t, "(node:") != null or std.mem.startsWith(u8, t, "at node:");
}

fn isNumbered(t: []const u8) bool {
    var s = t;
    if (std.mem.startsWith(u8, s, ">")) s = trimLeft(s[1..]);
    var i: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    while (i < s.len and s[i] == ' ') i += 1;
    return i < s.len and s[i] == '|' and (i == 0 or std.ascii.isDigit(s[0]));
}

fn underscoreRule(t: []const u8) bool {
    if (t.len < 3) return false;
    for (t) |c| if (c != '_' and c != ' ') return false;
    return true;
}

const essential_marks = [_][]const u8{ "Error", "error", "Exception", "exception", "assert", "Assert", "Expected", "expected", "Received", "received", "Actual", "actual", "panicked", "left:", "right:", "!==", "FAIL", "Failure", "failure", "want", "got " };

fn essential(t: []const u8) bool {
    if (std.mem.eql(u8, t, "E") or std.mem.startsWith(u8, t, "E ") or std.mem.startsWith(u8, t, ">")) return true;
    return containsAny(t, &essential_marks);
}

fn clipLine(arena: Allocator, line: []const u8) ![]const u8 {
    if (line.len <= max_line) return line;
    var end = max_line;
    while (end > 0 and line[end] & 0xC0 == 0x80) end -= 1;
    return std.fmt.allocPrint(arena, "{s}\u{2026}", .{line[0..end]});
}

const Shaped = struct { text: []const u8, dropped: usize };

fn filtered(arena: Allocator, body: Lines) ![]const []const u8 {
    var marked = false;
    for (body) |line| {
        const t = trimLeft(line);
        if (std.mem.startsWith(u8, t, ">") and isNumbered(t)) marked = true;
    }
    var kept: std.ArrayList([]const u8) = .empty;
    var skip_deeper: ?usize = null;
    for (body) |line| {
        const ind = indentOf(line);
        const t = line[ind..];
        if (skip_deeper) |k| {
            if (t.len == 0 or ind > k) continue;
            skip_deeper = null;
        }
        if (isFrame(t) and vendorFrame(t)) {
            if (!std.mem.startsWith(u8, t, "at ")) skip_deeper = ind;
            continue;
        }
        if (marked and isNumbered(t) and !std.mem.startsWith(u8, t, ">") and std.mem.indexOfScalar(u8, t, '^') == null) continue;
        if (underscoreRule(t)) continue;
        if (std.mem.startsWith(u8, t, "note: run with `RUST_BACKTRACE")) continue;
        if (t.len == 0 and (kept.items.len == 0 or kept.items[kept.items.len - 1].len == 0)) continue;
        try kept.append(arena, if (t.len == 0) "" else try clipLine(arena, line));
    }
    while (kept.items.len != 0 and kept.items[kept.items.len - 1].len == 0) kept.items.len -= 1;
    var least: usize = std.math.maxInt(usize);
    for (kept.items) |line| if (line.len != 0) {
        least = @min(least, indentOf(line));
    };
    if (least != std.math.maxInt(usize) and least != 0) {
        for (kept.items) |*line| if (line.len != 0) {
            line.* = line.*[least..];
        };
    }
    return kept.items;
}

fn shape(arena: Allocator, block: Block) !Shaped {
    const lines = try filtered(arena, block.body);
    const n = lines.len;
    const weights = try arena.alloc(u8, n);
    const kept = try arena.alloc(bool, n);
    @memset(kept, true);
    var size: usize = block.title.len;
    var seen_frame = false;
    for (lines, weights) |line, *w| {
        size += line.len + 1;
        const t = trimLeft(line);
        if (isFrame(t)) {
            w.* = if (seen_frame) 0 else 2;
            seen_frame = true;
        } else {
            w.* = if (essential(t)) 2 else 1;
        }
    }
    var count: usize = n + 1;
    var gaps: usize = 0;
    var dropped: usize = 0;
    for ([_]u8{ 0, 1, 2 }) |weight| {
        var i = n;
        while (i > 0) {
            if (count + gaps <= per_test_lines and size + gaps * marker_bytes <= per_test_bytes) break;
            i -= 1;
            if (weights[i] != weight or !kept[i]) continue;
            kept[i] = false;
            size -= lines[i].len + 1;
            count -= 1;
            dropped += 1;
            const left = i > 0 and !kept[i - 1];
            const right = i + 1 < n and !kept[i + 1];
            if (left and right) gaps -= 1 else if (!left and !right) gaps += 1;
        }
    }
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(arena, block.title);
    var i: usize = 0;
    while (i < n) {
        try text.append(arena, '\n');
        if (kept[i]) {
            try text.appendSlice(arena, lines[i]);
            i += 1;
            continue;
        }
        var run: usize = 0;
        while (i < n and !kept[i]) : (i += 1) run += 1;
        try text.print(arena, "\u{2026} {d} line{s} left out", .{ run, if (run == 1) "" else "s" });
    }
    return .{ .text = text.items, .dropped = dropped };
}

fn endsWithPart(long: []const u8, short: []const u8) bool {
    if (long.len <= short.len or !std.mem.endsWith(u8, long, short)) return false;
    return std.mem.indexOfScalar(u8, ":./\\ ", long[long.len - short.len - 1]) != null;
}

fn sameTest(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b) or endsWithPart(a, b) or endsWithPart(b, a);
}

fn ordered(arena: Allocator, blocks: []const Block, first: []const []const u8) ![]const Block {
    var unique: std.ArrayList(Block) = .empty;
    outer: for (blocks) |block| {
        for (unique.items) |held| if (std.mem.eql(u8, held.title, block.title)) continue :outer;
        try unique.append(arena, block);
    }
    const picked = try arena.alloc(bool, unique.items.len);
    @memset(picked, false);
    var result: std.ArrayList(Block) = .empty;
    for (first) |id| for (unique.items, picked) |block, *taken| {
        if (taken.* or !sameTest(block.id, id)) continue;
        taken.* = true;
        try result.append(arena, block);
    };
    for (unique.items, picked) |block, taken| if (!taken) try result.append(arena, block);
    return result.items;
}

fn clipName(name: []const u8) []const u8 {
    if (name.len <= max_name) return name;
    var end = max_name;
    while (end > 0 and name[end] & 0xC0 == 0x80) end -= 1;
    return name[0..end];
}

fn parsed(arena: Allocator, stage: Stage, lines: Lines) ![]const Block {
    var blocks: Blocks = .empty;
    if (stage == .tests) {
        try pytest(arena, lines, &blocks);
        try dotnet(arena, lines, &blocks);
        try jest(arena, lines, &blocks);
        try vitest(arena, lines, &blocks);
        try nodeSpec(arena, lines, &blocks);
        try tap(arena, lines, &blocks);
        try mocha(arena, lines, &blocks);
        try go(arena, lines, &blocks);
        try cargo(arena, lines, &blocks);
        try zigBuild(arena, lines, &blocks);
        try zigTest(arena, lines, &blocks);
    }
    if (blocks.items.len == 0) try compile(arena, lines, stage, &blocks);
    return blocks.items;
}

pub fn render(gpa: Allocator, stage: Stage, stdout: []const u8, stderr: []const u8, first: []const []const u8) !Rendered {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lines = try cleanLines(arena, &.{ stdout, stderr });
    const blocks = try ordered(arena, try parsed(arena, stage, lines), first);
    if (blocks.len == 0) return .{ .text = try gpa.alloc(u8, 0), .blocks = 0, .shown = 0 };
    var out: std.ArrayList(u8) = .empty;
    var shown: usize = 0;
    var cut: usize = 0;
    var left: std.ArrayList([]const u8) = .empty;
    for (blocks) |block| {
        if (left.items.len != 0) {
            try left.append(arena, block.id);
            continue;
        }
        const shaped = try shape(arena, block);
        if (shown != 0 and out.items.len + 2 + shaped.text.len > cap - label_reserve) {
            try left.append(arena, block.id);
            continue;
        }
        if (shown != 0) try out.appendSlice(arena, "\n\n");
        try out.appendSlice(arena, shaped.text);
        shown += 1;
        cut += shaped.dropped;
    }
    if (left.items.len != 0 or cut != 0) {
        const noun = if (stage == .tests) "failing test" else "error";
        try out.appendSlice(arena, "\n\nleft out: ");
        if (left.items.len != 0) {
            try out.print(arena, "{d} more {s}{s} (", .{ left.items.len, noun, if (left.items.len == 1) "" else "s" });
            for (left.items[0..@min(left.items.len, shown_names)], 0..) |id, i| {
                if (i != 0) try out.appendSlice(arena, ", ");
                try out.appendSlice(arena, clipName(id));
            }
            if (left.items.len > shown_names) try out.print(arena, " +{d} more", .{left.items.len - shown_names});
            try out.appendSlice(arena, ")");
            if (cut != 0) try out.appendSlice(arena, " and ");
        }
        if (cut != 0) try out.print(arena, "{d} line{s} cut from the ones above", .{ cut, if (cut == 1) "" else "s" });
    }
    return .{ .text = try gpa.dupe(u8, out.items), .blocks = blocks.len, .shown = shown };
}

const testing = std.testing;

fn rendered(stage: Stage, stdout: []const u8, stderr: []const u8, first: []const []const u8) ![]u8 {
    const r = try render(testing.allocator, stage, stdout, stderr, first);
    return r.text;
}

fn expectHas(text: []const u8, part: []const u8) !void {
    if (std.mem.indexOf(u8, text, part) == null) {
        std.debug.print("missing {s}\n--- in ---\n{s}\n", .{ part, text });
        return error.TestExpectedEqual;
    }
}

fn expectLacks(text: []const u8, part: []const u8) !void {
    if (std.mem.indexOf(u8, text, part) != null) {
        std.debug.print("unexpected {s}\n--- in ---\n{s}\n", .{ part, text });
        return error.TestExpectedEqual;
    }
}

pub const pytest_run =
    \\============================= test session starts =============================
    \\platform win32 -- Python 3.14.4, pytest-8.3.4, pluggy-1.6.0
    \\collected 7 items / 1 error
    \\
    \\tests\test_a.py .FF.F                                                    [ 71%]
    \\tests\test_c.py EF                                                       [100%]
    \\
    \\=================================== ERRORS ====================================
    \\______________________ ERROR collecting tests/test_b.py _______________________
    \\ImportError while importing test module 'C:\w\py\tests\test_b.py'.
    \\Hint: make sure your test modules/packages have valid Python names.
    \\Traceback:
    \\tests\test_b.py:1: in <module>
    \\    import nonexistent_mod
    \\E   ModuleNotFoundError: No module named 'nonexistent_mod'
    \\_________________________ ERROR at setup of test_uses _________________________
    \\
    \\    @pytest.fixture
    \\    def broken():
    \\>       raise RuntimeError("fixture broke")
    \\E       RuntimeError: fixture broke
    \\
    \\tests\test_c.py:4: RuntimeError
    \\================================== FAILURES ===================================
    \\___________________________________ test_eq ___________________________________
    \\
    \\    def test_eq():
    \\        got = {"a": 1, "b": 2}
    \\>       assert got == {"a": 1, "b": 3}
    \\E       AssertionError: assert {'a': 1, 'b': 2} == {'a': 1, 'b': 3}
    \\E
    \\E         Omitting 1 identical items, use -vv to show
    \\E         Differing items:
    \\E         {'b': 2} != {'b': 3}
    \\E         Use -v to get more diff
    \\
    \\tests\test_a.py:11: AssertionError
    \\____________________________ TestThing.test_raise _____________________________
    \\
    \\self = <test_a.TestThing object at 0x0000018C6A154B90>
    \\
    \\    def test_raise(self):
    \\>       int("nope")
    \\E       ValueError: invalid literal for int() with base 10: 'nope'
    \\
    \\tests\test_a.py:15: ValueError
    \\_________________________________ test_prints _________________________________
    \\
    \\    def test_prints():
    \\        print("debug value 42")
    \\>       assert False, "with message"
    \\E       AssertionError: with message
    \\E       assert False
    \\
    \\tests\test_c.py:9: AssertionError
    \\---------------------------- Captured stdout call -----------------------------
    \\debug value 42
    \\- generated xml file: C:\w\py-cache\emetgate-junit.xml -
    \\=========================== short test summary info ===========================
    \\FAILED tests/test_a.py::test_eq - AssertionError: assert {'a': 1, 'b': 2} == ...
    \\FAILED tests/test_a.py::TestThing::test_raise - ValueError: invalid literal f...
    \\FAILED tests/test_c.py::test_prints - AssertionError: with message
    \\ERROR tests/test_b.py
    \\ERROR tests/test_c.py::test_uses - RuntimeError: fixture broke
    \\==================== 3 failed, 2 passed, 2 errors in 0.22s ====================
    \\
;

test "pytest failures carry each test id, its E lines and location, collection and setup errors and captured output" {
    const text = try rendered(.tests, pytest_run, "", &.{});
    defer testing.allocator.free(text);
    try expectHas(text, "tests/test_a.py::test_eq\n");
    try expectHas(text, ">       assert got == {\"a\": 1, \"b\": 3}");
    try expectHas(text, "E       AssertionError: assert {'a': 1, 'b': 2} == {'a': 1, 'b': 3}");
    try expectHas(text, "E         {'b': 2} != {'b': 3}");
    try expectHas(text, "tests\\test_a.py:11: AssertionError");
    try expectHas(text, "tests/test_a.py::TestThing::test_raise\n");
    try expectHas(text, "E       ValueError: invalid literal for int() with base 10: 'nope'");
    try expectHas(text, "ERROR tests/test_b.py\n");
    try expectHas(text, "E   ModuleNotFoundError: No module named 'nonexistent_mod'");
    try expectHas(text, "ERROR tests/test_c.py::test_uses\n");
    try expectHas(text, "E       RuntimeError: fixture broke");
    try expectHas(text, "debug value 42");
    try expectLacks(text, "generated xml file");
    try expectLacks(text, "short test summary");
    try expectLacks(text, "test session starts");
    try expectLacks(text, "left out");
}

test "pytest frames from the standard library and installed packages are left out with their source line" {
    const run =
        \\================================== FAILURES ===================================
        \\___________________________________ test_x ____________________________________
        \\/usr/lib/python3.14/importlib/__init__.py:88: in import_module
        \\    return _bootstrap._gcd_import(name[level:], package, level)
        \\.venv/lib/site-packages/lib/core.py:12: in call
        \\    return inner()
        \\test_x.py:3: in test_x
        \\    use()
        \\E   KeyError: 'k'
        \\=========================== short test summary info ===========================
        \\FAILED test_x.py::test_x - KeyError: 'k'
        \\============================== 1 failed in 0.05s ==============================
        \\
    ;
    const text = try rendered(.tests, run, "", &.{});
    defer testing.allocator.free(text);
    try expectHas(text, "test_x.py::test_x\n");
    try expectHas(text, "test_x.py:3: in test_x\n    use()");
    try expectHas(text, "E   KeyError: 'k'");
    try expectLacks(text, "importlib");
    try expectLacks(text, "_gcd_import");
    try expectLacks(text, "site-packages");
    try expectLacks(text, "inner()");
}

test "the tests named first lead the failures" {
    const text = try rendered(.tests, pytest_run, "", &.{"tests/test_c.py::test_prints"});
    defer testing.allocator.free(text);
    try testing.expect(std.mem.startsWith(u8, text, "tests/test_c.py::test_prints\n"));
}

pub const dotnet_run_localized =
    "  Geri y\xc3\xbcklenecek projeler belirleniyor...\r\n" ++
    "[xUnit.net 00:00:01.11]     Calc.Tests.CalcTests.Subtracts [FAIL]\r\n" ++
    "[xUnit.net 00:00:01.12]     Calc.Tests.CalcTests.IsOne(n: 2) [FAIL]\r\n" ++
    "  Ba\xc5\x9far\xc4\xb1s\xc4\xb1z Calc.Tests.CalcTests.Subtracts [5 ms]\r\n" ++
    "  Hata \xc4\xb0letisi:\r\n" ++
    "   Assert.Equal() Failure\r\n" ++
    "Expected: 1\r\n" ++
    "Actual:   2\r\n" ++
    "  Y\xc4\xb1\xc4\x9f\xc4\xb1n \xc4\xb0zleme:\r\n" ++
    "     at Calc.Tests.CalcTests.Subtracts() in C:\\w\\cs\\UnitTest1.cs:line 7\r\n" ++
    "  Ba\xc5\x9far\xc4\xb1s\xc4\xb1z Calc.Tests.CalcTests.IsOne(n: 2) [< 1 ms]\r\n" ++
    "  Hata \xc4\xb0letisi:\r\n" ++
    "   n should be one\r\n" ++
    "Expected: True\r\n" ++
    "Actual:   False\r\n" ++
    "  Y\xc4\xb1\xc4\x9f\xc4\xb1n \xc4\xb0zleme:\r\n" ++
    "     at Calc.Tests.CalcTests.IsOne(Int32 n) in C:\\w\\cs\\UnitTest1.cs:line 9\r\n" ++
    "  Ba\xc5\x9far\xc4\xb1l\xc4\xb1 Calc.Tests.CalcTests.Adds [1 ms]\r\n" ++
    "  Ba\xc5\x9far\xc4\xb1s\xc4\xb1z Calc.Tests.CalcTests.Throws [< 1 ms]\r\n" ++
    "  Hata \xc4\xb0letisi:\r\n" ++
    "   System.InvalidOperationException : boom here\r\n" ++
    "  Y\xc4\xb1\xc4\x9f\xc4\xb1n \xc4\xb0zleme:\r\n" ++
    "     at Calc.Tests.CalcTests.Throws() in C:\\w\\cs\\UnitTest1.cs:line 8\r\n" ++
    "\r\n" ++
    "Ba\xc5\x9far\xc4\xb1s\xc4\xb1z! - Ba\xc5\x9far\xc4\xb1s\xc4\xb1z:     3, Ba\xc5\x9far\xc4\xb1l\xc4\xb1:     2, Atlanan:     0, Toplam:     5, S\xc3\xbcre: 5 ms - T.dll (net6.0)\r\n";

pub const dotnet_run_english =
    \\  Failed Calc.Tests.CalcTests.Subtracts [5 ms]
    \\  Error Message:
    \\   Assert.Equal() Failure
    \\Expected: 1
    \\Actual:   2
    \\  Stack Trace:
    \\     at Calc.Tests.CalcTests.Subtracts() in C:\w\cs\UnitTest1.cs:line 7
    \\     at System.RuntimeMethodHandle.InvokeMethod(Object target, Void** arguments, Signature sig, Boolean isConstructor)
    \\  Passed Calc.Tests.CalcTests.Adds [1 ms]
    \\
    \\Failed!  - Failed:     1, Passed:     1, Skipped:     0, Total:     2, Duration: 5 ms - T.dll (net8.0)
    \\
;

test "dotnet failures carry the message, expected and actual and the test frame in any console language" {
    const localized = try rendered(.tests, dotnet_run_localized, "", &.{});
    defer testing.allocator.free(localized);
    try expectHas(localized, "Calc.Tests.CalcTests.Subtracts\n");
    try expectHas(localized, "Assert.Equal() Failure");
    try expectHas(localized, "Expected: 1\nActual:   2");
    try expectHas(localized, "at Calc.Tests.CalcTests.Subtracts() in C:\\w\\cs\\UnitTest1.cs:line 7");
    try expectHas(localized, "Calc.Tests.CalcTests.IsOne(n: 2)\n");
    try expectHas(localized, "n should be one");
    try expectHas(localized, "System.InvalidOperationException : boom here");
    try expectLacks(localized, "Adds");
    try expectLacks(localized, "xUnit.net");

    const english = try rendered(.tests, dotnet_run_english, "", &.{});
    defer testing.allocator.free(english);
    try expectHas(english, "Calc.Tests.CalcTests.Subtracts\n");
    try expectHas(english, "Expected: 1\nActual:   2");
    try expectHas(english, "UnitTest1.cs:line 7");
    try expectLacks(english, "RuntimeMethodHandle");
    try expectLacks(english, "Adds");
}

pub const jest_run =
    "FAIL __tests__/a.test.js\n" ++
    "  \u{25cf} sum \u{203a} adds\n" ++
    "\n" ++
    "    expect(received).toBe(expected) // Object.is equality\n" ++
    "\n" ++
    "    Expected: 3\n" ++
    "    Received: 4\n" ++
    "\n" ++
    "    \x1b[0m \x1b[90m 1 |\x1b[39m \x1b[36mfunction\x1b[39m sum(a, b) { return a + b + 1; }\n" ++
    "     \x1b[90m 2 |\x1b[39m describe('sum', () => {\n" ++
    "    \x1b[31m\x1b[1m>\x1b[22m\x1b[39m\x1b[90m 3 |\x1b[39m   test('adds', () => { expect(sum(1, 2)).toBe(3); });\n" ++
    "     \x1b[90m   |\x1b[39m                                          \x1b[31m\x1b[1m^\x1b[22m\x1b[39m\n" ++
    "     \x1b[90m 4 |\x1b[39m   test('objects', () => {});\x1b[0m\n" ++
    "\n" ++
    "      at Object.toBe (__tests__/a.test.js:3:42)\n" ++
    "      at Promise.then.completed (node_modules/jest-circus/build/utils.js:298:28)\n" ++
    "\n" ++
    "  \u{25cf} throws\n" ++
    "\n" ++
    "    kaput\n" ++
    "\n" ++
    "      at Object.<anonymous> (__tests__/a.test.js:6:30)\n" ++
    "\n" ++
    "Test Suites: 1 failed, 1 total\n" ++
    "Tests:       2 failed, 1 passed, 3 total\n";

test "jest failures carry expected and received, the marked source line and the first project frame" {
    const text = try rendered(.tests, "", jest_run, &.{});
    defer testing.allocator.free(text);
    try expectHas(text, "sum \u{203a} adds\n");
    try expectHas(text, "expect(received).toBe(expected)");
    try expectHas(text, "Expected: 3\nReceived: 4");
    try expectHas(text, "> 3 |   test('adds'");
    try expectHas(text, "  |                                          ^");
    try expectHas(text, "at Object.toBe (__tests__/a.test.js:3:42)");
    try expectHas(text, "throws\n");
    try expectHas(text, "kaput");
    try expectLacks(text, " 1 | function");
    try expectLacks(text, "node_modules");
    try expectLacks(text, "\x1b");
    try expectLacks(text, "Test Suites");
}

pub const node_test_run =
    \\✔ adds (0.6568ms)
    \\▶ math
    \\  ✖ subtracts (1.7493ms)
    \\✖ math (4.4191ms)
    \\✖ throws (0.5859ms)
    \\ℹ tests 3
    \\ℹ fail 2
    \\
    \\✖ failing tests:
    \\
    \\test at test\a.test.js:5:3
    \\✖ subtracts (1.7493ms)
    \\  AssertionError [ERR_ASSERTION]: Expected values to be strictly equal:
    \\
    \\  2 !== 1
    \\
    \\      at TestContext.<anonymous> (C:\w\nt\test\a.test.js:5:36)
    \\      at Test.runInAsyncScope (node:async_hooks:227:14)
    \\      at Test.run (node:internal/test_runner/test:1382:25)
    \\      at new Promise (<anonymous>)
    \\      at Array.map (<anonymous>) {
    \\    generatedMessage: true,
    \\    code: 'ERR_ASSERTION',
    \\    actual: 2,
    \\    expected: 1,
    \\    operator: 'strictEqual'
    \\  }
    \\
    \\test at test\a.test.js:8:1
    \\✖ throws (0.5859ms)
    \\  TypeError: bad input
    \\      at TestContext.<anonymous> (C:\w\nt\test\a.test.js:8:30)
    \\      at Test.run (node:internal/test_runner/test:1382:25)
    \\
;

test "node --test failures carry the location, the assertion and the project frame" {
    const text = try rendered(.tests, node_test_run, "", &.{});
    defer testing.allocator.free(text);
    try expectHas(text, "subtracts\ntest at test\\a.test.js:5:3\n");
    try expectHas(text, "AssertionError [ERR_ASSERTION]: Expected values to be strictly equal:");
    try expectHas(text, "2 !== 1");
    try expectHas(text, "at TestContext.<anonymous> (C:\\w\\nt\\test\\a.test.js:5:36)");
    try expectHas(text, "throws\ntest at test\\a.test.js:8:1\n");
    try expectHas(text, "TypeError: bad input");
    try expectLacks(text, "node:");
    try expectLacks(text, "math");
    try expectLacks(text, "\u{2139}");
}

test "node --test tap output keeps each failing test's yaml block and skips parents of failing subtests" {
    const run =
        \\TAP version 13
        \\# Subtest: math
        \\    # Subtest: subtracts
        \\    not ok 1 - subtracts
        \\      ---
        \\      duration_ms: 1.2
        \\      failureType: 'testCodeFailure'
        \\      error: |-
        \\        Expected values to be strictly equal:
        \\
        \\        2 !== 1
        \\      code: 'ERR_ASSERTION'
        \\      ...
        \\not ok 1 - math
        \\  ---
        \\  failureType: 'subtestsFailed'
        \\  error: '1 subtest failed'
        \\  ...
        \\1..1
        \\
    ;
    const text = try rendered(.tests, run, "", &.{});
    defer testing.allocator.free(text);
    try expectHas(text, "subtracts\n");
    try expectHas(text, "2 !== 1");
    try expectLacks(text, "math");
}

test "vitest and mocha failures carry each test's message" {
    const vitest_run =
        \\ ❯ src/a.test.ts (2 tests | 1 failed) 4ms
        \\   × sum > adds 3ms
        \\
        \\⎯⎯⎯⎯⎯⎯⎯ Failed Tests 1 ⎯⎯⎯⎯⎯⎯⎯
        \\
        \\ FAIL  src/a.test.ts > sum > adds
        \\AssertionError: expected 4 to be 3 // Object.is equality
        \\
        \\- Expected
        \\+ Received
        \\
        \\- 3
        \\+ 4
        \\
        \\ ❯ src/a.test.ts:4:22
        \\
        \\⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯[1/1]⎯
        \\
        \\ Test Files  1 failed (1)
        \\      Tests  1 failed | 1 passed (2)
        \\
    ;
    const vt = try rendered(.tests, vitest_run, "", &.{});
    defer testing.allocator.free(vt);
    try expectHas(vt, "src/a.test.ts > sum > adds\n");
    try expectHas(vt, "AssertionError: expected 4 to be 3");
    try expectHas(vt, "src/a.test.ts:4:22");
    try expectLacks(vt, "Test Files");

    const mocha_run =
        \\  sum
        \\    1) adds
        \\
        \\  0 passing (5ms)
        \\  1 failing
        \\
        \\  1) sum
        \\       adds:
        \\
        \\      AssertionError [ERR_ASSERTION]: 4 == 3
        \\      + expected - actual
        \\
        \\      at Context.<anonymous> (test/a.js:5:14)
        \\      at process.processImmediate (node:internal/timers:483:21)
        \\
        \\
    ;
    const mo = try rendered(.tests, mocha_run, "", &.{});
    defer testing.allocator.free(mo);
    try expectHas(mo, "sum adds\n");
    try expectHas(mo, "AssertionError [ERR_ASSERTION]: 4 == 3");
    try expectHas(mo, "at Context.<anonymous> (test/a.js:5:14)");
    try expectLacks(mo, "node:internal");
}

pub const go_run =
    "--- FAIL: TestAdd (0.00s)\n" ++
    "    calc_test.go:10: Add(1, 2) = 4, want 3\n" ++
    "--- FAIL: TestTable (0.00s)\n" ++
    "    --- FAIL: TestTable/negative (0.00s)\n" ++
    "        calc_test.go:22: Add(-1, -2) = -4, want -3\n" ++
    "    --- PASS: TestTable/positive (0.00s)\n" ++
    "--- FAIL: TestDiv (0.00s)\n" ++
    "panic: runtime error: integer divide by zero [recovered]\n" ++
    "\tpanic: runtime error: integer divide by zero\n" ++
    "\n" ++
    "goroutine 7 [running]:\n" ++
    "testing.tRunner.func1.2({0x5a3f40, 0x6b8c30})\n" ++
    "\t/usr/local/go/src/testing/testing.go:1631 +0x24a\n" ++
    "panic({0x5a3f40?, 0x6b8c30?})\n" ++
    "\t/usr/local/go/src/runtime/panic.go:770 +0x132\n" ++
    "example.com/calc.Div(...)\n" ++
    "\t/w/calc/calc.go:8\n" ++
    "example.com/calc.TestDiv(0xc000007860?)\n" ++
    "\t/w/calc/calc_test.go:28 +0x1d\n" ++
    "FAIL\texample.com/calc\t0.004s\n" ++
    "FAIL\n";

test "go failures carry each test's log lines, subtests on their own and a panic with its project frames" {
    const text = try rendered(.tests, go_run, "", &.{});
    defer testing.allocator.free(text);
    try expectHas(text, "TestAdd\ncalc_test.go:10: Add(1, 2) = 4, want 3");
    try expectHas(text, "TestTable/negative\ncalc_test.go:22: Add(-1, -2) = -4, want -3");
    try expectLacks(text, "TestTable\n");
    try expectHas(text, "TestDiv\npanic: runtime error: integer divide by zero");
    try expectHas(text, "example.com/calc.TestDiv(0xc000007860?)\n\t/w/calc/calc_test.go:28 +0x1d");
    try expectLacks(text, "testing.go");
    try expectLacks(text, "runtime/panic.go");
    try expectLacks(text, "positive");
}

pub const cargo_run =
    \\running 3 tests
    \\test tests::fine ... ok
    \\test tests::adds ... FAILED
    \\test tests::strings ... FAILED
    \\
    \\failures:
    \\
    \\---- tests::adds stdout ----
    \\
    \\thread 'tests::adds' panicked at src/lib.rs:10:9:
    \\assertion `left == right` failed
    \\  left: 4
    \\ right: 3
    \\note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
    \\
    \\---- tests::strings stdout ----
    \\thread 'tests::strings' panicked at src/lib.rs:15:9:
    \\assertion `left == right` failed: names differ
    \\  left: "help"
    \\ right: "hello"
    \\
    \\
    \\failures:
    \\    tests::adds
    \\    tests::strings
    \\
    \\test result: FAILED. 1 passed; 2 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
    \\
;

test "cargo failures carry the panic location and left and right" {
    const text = try rendered(.tests, cargo_run, "", &.{});
    defer testing.allocator.free(text);
    try expectHas(text, "tests::adds\nthread 'tests::adds' panicked at src/lib.rs:10:9:\nassertion `left == right` failed\n  left: 4\n right: 3");
    try expectHas(text, "tests::strings\n");
    try expectHas(text, "right: \"hello\"");
    try expectLacks(text, "RUST_BACKTRACE");
    try expectLacks(text, "test result");
}

pub const zig_test_run =
    \\1/3 t.test.adds...expected 3, found 4
    \\FAIL (TestExpectedEqual)
    \\C:\tools\zig\lib\std\testing.zig:118:17: 0x7ff627ad6e63 in expectEqualInner__anon_67026 (test_zcu.obj)
    \\                return error.TestExpectedEqual;
    \\                ^
    \\C:\tools\zig\lib\std\testing.zig:83: 0x7ff627ad6eda in expectEqual (test_zcu.obj)
    \\    return expectEqualInner(T, expected, actual);
    \\
    \\C:\w\zg\t.zig:6:5: 0x7ff627ad6f05 in test.adds (test_zcu.obj)
    \\    try std.testing.expectEqual(@as(i32, 3), add(1, 2));
    \\    ^
    \\2/3 t.test.fine...OK
    \\3/3 t.test.strings...FAIL (TestUnexpectedResult)
    \\C:\w\zg\t.zig:9:5: 0x7ff627ad4e23 in test.strings (test_zcu.obj)
    \\    try std.testing.expect(false);
    \\    ^
    \\1 passed; 0 skipped; 2 failed.
    \\
;

pub const zig_build_run =
    \\test
    \\+- run test 1 pass, 1 fail (2 total)
    \\error: 't.test.adds' failed:
    \\       expected 3, found 4
    \\       C:\tools\zig\lib\std\testing.zig:118:17: 0x7ff680586e63 in expectEqualInner__anon_67026 (test_zcu.obj)
    \\                       return error.TestExpectedEqual;
    \\                       ^
    \\       C:\tools\zig\lib\std\testing.zig:83: 0x7ff680586eda in expectEqual (test_zcu.obj)
    \\           return expectEqualInner(T, expected, actual);
    \\
    \\       C:\w\zg\t.zig:6:5: 0x7ff680586f05 in test.adds (test_zcu.obj)
    \\           try std.testing.expectEqual(@as(i32, 3), add(1, 2));
    \\           ^
    \\failed command: ".\\.zig-cache\\o\\de79\\test.exe" --seed=0xeec5079a --listen=-
    \\
    \\Build Summary: 1/3 steps succeeded (1 failed); 1/2 tests passed (1 failed)
    \\
;

test "zig test and zig build test failures carry the message and the project frame without std frames" {
    const direct = try rendered(.tests, zig_test_run, "", &.{});
    defer testing.allocator.free(direct);
    try expectHas(direct, "t.test.adds\nexpected 3, found 4\nFAIL (TestExpectedEqual)");
    try expectHas(direct, "C:\\w\\zg\\t.zig:6:5: 0x7ff627ad6f05 in test.adds (test_zcu.obj)\n    try std.testing.expectEqual(@as(i32, 3), add(1, 2));");
    try expectHas(direct, "t.test.strings\nFAIL (TestUnexpectedResult)");
    try expectLacks(direct, "lib\\std");
    try expectLacks(direct, "t.test.fine");

    const built = try rendered(.tests, "", zig_build_run, &.{});
    defer testing.allocator.free(built);
    try expectHas(built, "t.test.adds\nexpected 3, found 4\n");
    try expectHas(built, "C:\\w\\zg\\t.zig:6:5:");
    try expectHas(built, "    try std.testing.expectEqual(@as(i32, 3), add(1, 2));\n    ^");
    try expectLacks(built, "lib\\std");
    try expectLacks(built, "Build Summary");
}

test "each test is cut to its line and byte budget and the whole reply to its cap, with a label saying what was left out" {
    var run: std.ArrayList(u8) = .empty;
    defer run.deinit(testing.allocator);
    try run.appendSlice(testing.allocator, "================================== FAILURES ===================================\n");
    for (0..30) |t| {
        try run.print(testing.allocator, "_____ test_case_{d} _____\n\n    def test_case_{d}():\n", .{ t, t });
        for (0..60) |l| try run.print(testing.allocator, "        value_{d} = compute({d})\n", .{ l, l });
        try run.print(testing.allocator, ">       assert value_0 == {d}\nE       assert 0 == {d}\n\ntests\\test_big.py:{d}: AssertionError\n", .{ t + 1, t + 1, t });
    }
    try run.appendSlice(testing.allocator, "=========================== short test summary info ===========================\n");
    for (0..30) |t| try run.print(testing.allocator, "FAILED tests/test_big.py::test_case_{d} - assert 0 == {d}\n", .{ t, t + 1 });
    try run.appendSlice(testing.allocator, "30 failed in 0.50s\n");
    const r = try render(testing.allocator, .tests, run.items, "", &.{});
    defer testing.allocator.free(r.text);
    try testing.expect(r.text.len <= cap);
    try testing.expectEqual(@as(usize, 30), r.blocks);
    try testing.expect(r.shown >= 2 and r.shown < 30);
    var blocks = std.mem.splitSequence(u8, r.text, "\n\n");
    const block = blocks.next().?;
    try testing.expect(block.len <= per_test_bytes + marker_bytes);
    try testing.expect(std.mem.count(u8, block, "\n") < per_test_lines);
    try expectHas(block, "tests/test_big.py::test_case_0\n");
    try expectHas(block, "E       assert 0 == 1");
    try expectHas(block, "tests\\test_big.py:0: AssertionError");
    try expectHas(block, " lines left out");
    var label_buf: [96]u8 = undefined;
    try expectHas(r.text, try std.fmt.bufPrint(&label_buf, "left out: {d} more failing tests (tests/test_big.py::test_case_{d}, ", .{ 30 - r.shown, r.shown }));
    try expectHas(r.text, " more) and ");
    try expectHas(r.text, " lines cut from the ones above");
}

test "a passing run gives no failure text" {
    const passing =
        \\..........                                                               [100%]
        \\10 passed in 0.10s
        \\
    ;
    const r = try render(testing.allocator, .tests, passing, "", &.{});
    defer testing.allocator.free(r.text);
    try testing.expectEqual(@as(usize, 0), r.text.len);
    try testing.expectEqual(@as(usize, 0), r.blocks);
}

test "compiler errors keep their source line, caret and notes, and one-line tsc errors are left to diagnostics" {
    const zig_errors =
        \\install
        \\+- install app
        \\   +- compile exe app Debug native 1 errors
        \\src\main.zig:3:5: error: use of undeclared identifier 'foo'
        \\    foo();
        \\    ^~~
        \\src\main.zig:1:1: note: struct declared here
        \\error: the following command failed with 1 compilation errors:
        \\C:\tools\zig\zig.exe build-exe src\main.zig
        \\
    ;
    const zt = try rendered(.typecheck, "", zig_errors, &.{});
    defer testing.allocator.free(zt);
    try expectHas(zt, "src\\main.zig:3:5: error: use of undeclared identifier 'foo'\n    foo();\n    ^~~\nsrc\\main.zig:1:1: note: struct declared here");
    try expectLacks(zt, "the following command");

    const rust_errors =
        \\   Compiling calc v0.1.0 (C:\w\calc)
        \\error[E0308]: mismatched types
        \\ --> src/lib.rs:2:18
        \\  |
        \\2 |     let x: i32 = "a";
        \\  |            ---   ^^^ expected `i32`, found `&str`
        \\  |            |
        \\  |            expected due to this
        \\
        \\error: could not compile `calc` (lib) due to 1 previous error
        \\
    ;
    const rt = try rendered(.tests, "", rust_errors, &.{});
    defer testing.allocator.free(rt);
    try expectHas(rt, "error[E0308]: mismatched types\n --> src/lib.rs:2:18");
    try expectHas(rt, "2 |     let x: i32 = \"a\";");
    try expectHas(rt, "^^^ expected `i32`, found `&str`");
    try expectLacks(rt, "could not compile");

    const tsc_errors = "src/x.ts(1,7): error TS2322: Type 'string' is not assignable to type 'number'.\n";
    const tt = try rendered(.typecheck, tsc_errors, "", &.{});
    defer testing.allocator.free(tt);
    try testing.expectEqual(@as(usize, 0), tt.len);

    const py_error =
        \\  File "app.py", line 3
        \\    def f(:
        \\          ^
        \\SyntaxError: invalid syntax
        \\
    ;
    const pt = try rendered(.typecheck, "", py_error, &.{});
    defer testing.allocator.free(pt);
    try expectHas(pt, "SyntaxError: invalid syntax\nFile \"app.py\", line 3\n  def f(:\n        ^");
}
