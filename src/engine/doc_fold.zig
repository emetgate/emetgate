const std = @import("std");
const ts = @import("tree_sitter.zig");
const traversal = @import("traversal.zig");
const Profile = @import("lang/profile.zig").Profile;
const test_util = @import("test_util.zig");

const Allocator = std.mem.Allocator;

pub const LineSpan = struct { first: u32, last: u32 };

pub const Folded = struct {
    text: []u8,
    spans: []LineSpan,

    pub fn deinit(self: Folded, gpa: Allocator) void {
        gpa.free(self.text);
        gpa.free(self.spans);
    }
};

const Kind = enum { comment, docstring };

const Piece = struct { start: u32, end: u32, kind: Kind };

const Group = struct { start: u32, end: u32, short: []const u8 };

const Groups = struct {
    source: []const u8,
    pieces: std.ArrayList(Piece) = .empty,
    i: usize = 0,
    buf: [512]u8 = undefined,

    fn init(gpa: Allocator, profile: *const Profile, tree: ts.Tree, start: u32, end: u32) Allocator.Error!Groups {
        var groups: Groups = .{ .source = tree.source };
        errdefer groups.pieces.deinit(gpa);
        var walker = traversal.Walker.init(tree.root());
        defer walker.deinit();
        while (walker.next()) |entry| {
            const node = entry.node;
            if (node.endByte() <= start or node.startByte() >= end) {
                walker.skipChildren();
                continue;
            }
            if (profile.isComment(node.kind())) {
                walker.skipChildren();
                if (node.startByte() >= start and node.endByte() <= end) try groups.pieces.append(gpa, .{ .start = node.startByte(), .end = node.endByte(), .kind = .comment });
                continue;
            }
            if (isDocstring(profile, tree.source, node)) {
                walker.skipChildren();
                if (node.startByte() >= start and node.endByte() <= end) try groups.pieces.append(gpa, .{ .start = node.startByte(), .end = node.endByte(), .kind = .docstring });
            }
        }
        return groups;
    }

    fn deinit(self: *Groups, gpa: Allocator) void {
        self.pieces.deinit(gpa);
    }

    fn next(self: *Groups) ?Group {
        const source = self.source;
        const pieces = self.pieces.items;
        while (self.i < pieces.len) {
            const first = pieces[self.i];
            var last = first;
            self.i += 1;
            var license = false;
            if (first.kind == .comment and isBlank(source[0..first.start])) {
                var j = self.i;
                var top = first;
                while (j < pieces.len and pieces[j].kind == .comment and isBlank(source[top.end..pieces[j].start])) : (j += 1) top = pieces[j];
                if (mentionsLicense(source[first.start..top.end])) {
                    license = true;
                    last = top;
                    self.i = j;
                }
            }
            if (first.kind == .comment and !license) {
                while (self.i < pieces.len and pieces[self.i].kind == .comment and isBlank(source[last.end..pieces[self.i].start]) and sameDocStyle(source[first.start..first.end], source[pieces[self.i].start..pieces[self.i].end])) : (self.i += 1) last = pieces[self.i];
            }
            const whole = source[first.start..last.end];
            if (std.mem.indexOfScalar(u8, whole, '\n') == null) continue;
            const short = (if (first.kind == .docstring)
                docstringLine(&self.buf, whole)
            else if (license)
                licenseLine(&self.buf, source[first.start..first.end])
            else
                docCommentLine(&self.buf, source[first.start..first.end])) orelse continue;
            return .{ .start = first.start, .end = last.end, .short = short };
        }
        return null;
    }
};

pub fn fold(gpa: Allocator, profile: *const Profile, tree: ts.Tree, start: u32, end: u32) Allocator.Error!Folded {
    const source = tree.source;
    var groups = try Groups.init(gpa, profile, tree, start, end);
    defer groups.deinit(gpa);
    var out: std.ArrayList(u8) = try .initCapacity(gpa, end - start);
    errdefer out.deinit(gpa);
    var spans: std.ArrayList(LineSpan) = .empty;
    errdefer spans.deinit(gpa);
    var copied: u32 = start;
    var line: u32 = 1 + @as(u32, @intCast(std.mem.count(u8, source[0..start], "\n")));
    var line_at: u32 = start;
    while (groups.next()) |group| {
        try out.appendSlice(gpa, source[copied..group.start]);
        try out.appendSlice(gpa, group.short);
        copied = group.end;
        line += @intCast(std.mem.count(u8, source[line_at..group.start], "\n"));
        line_at = group.start;
        const span_last = line + @as(u32, @intCast(std.mem.count(u8, source[group.start..group.end], "\n")));
        try spans.append(gpa, .{ .first = line, .last = span_last });
    }
    try out.appendSlice(gpa, source[copied..end]);
    const text = try out.toOwnedSlice(gpa);
    errdefer gpa.free(text);
    return .{ .text = text, .spans = try spans.toOwnedSlice(gpa) };
}

pub fn restore(gpa: Allocator, profile: *const Profile, tree: ts.Tree, start: u32, end: u32, submitted: []const u8) Allocator.Error!?[]u8 {
    const source = tree.source;
    var groups = try Groups.init(gpa, profile, tree, start, end);
    defer groups.deinit(gpa);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var copied: usize = 0;
    var restored = false;
    while (groups.next()) |group| {
        const full = source[group.start..group.end];
        if (std.mem.indexOf(u8, submitted[copied..], full) != null) continue;
        const at = copied + (std.mem.indexOf(u8, submitted[copied..], group.short) orelse continue);
        try out.appendSlice(gpa, submitted[copied..at]);
        try out.appendSlice(gpa, full);
        copied = at + group.short.len;
        restored = true;
    }
    if (!restored) {
        out.deinit(gpa);
        return null;
    }
    try out.appendSlice(gpa, submitted[copied..]);
    return try out.toOwnedSlice(gpa);
}

fn isDocstring(profile: *const Profile, source: []const u8, node: ts.Node) bool {
    const wrapped = std.mem.eql(u8, profile.expression_statement, node.kind()) and node.namedChildCount() == 1;
    if (!wrapped and !isString(profile, node.kind())) return false;
    const parent = node.parent() orelse return false;
    if (!std.mem.eql(u8, profile.block, parent.kind()) and !std.mem.eql(u8, profile.root, parent.kind())) return false;
    var prev = node.prevNamedSibling();
    while (prev) |sibling| : (prev = sibling.prevNamedSibling()) {
        if (!profile.isComment(sibling.kind())) return false;
    }
    const text = source[node.startByte()..node.endByte()];
    return quoteOf(text) != null and std.mem.endsWith(u8, text, text[quoteStart(text)..][0..3]);
}

fn isString(profile: *const Profile, kind: []const u8) bool {
    for (profile.strings) |string| if (std.mem.eql(u8, string, kind)) return true;
    return false;
}

fn quoteStart(text: []const u8) usize {
    var i: usize = 0;
    while (i < text.len and std.ascii.isAlphabetic(text[i])) i += 1;
    return i;
}

fn quoteOf(text: []const u8) ?[]const u8 {
    const at = quoteStart(text);
    if (at > 2) return null;
    const rest = text[at..];
    if (std.mem.startsWith(u8, rest, "\"\"\"")) return "\"\"\"";
    if (std.mem.startsWith(u8, rest, "'''")) return "'''";
    return null;
}

fn sameDocStyle(a: []const u8, b: []const u8) bool {
    for ([_][]const u8{ "///", "//!" }) |prefix| {
        if (std.mem.startsWith(u8, a, prefix) and std.mem.startsWith(u8, b, prefix)) return true;
    }
    return false;
}

fn docPrefix(comment: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, comment, "/**/")) return null;
    for ([_][]const u8{ "/**", "/*!", "///", "//!" }) |prefix| {
        if (std.mem.startsWith(u8, comment, prefix)) return prefix;
    }
    return null;
}

fn mentionsLicense(text: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(text, "copyright") != null or std.ascii.indexOfIgnoreCase(text, "license") != null;
}

fn firstText(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "/*")) line = line[2..];
        if (std.mem.endsWith(u8, line, "*/")) line = line[0 .. line.len - 2];
        line = std.mem.trimStart(u8, line, "/*!#");
        line = std.mem.trim(u8, line, " \t\r");
        if (line.len != 0) return line;
    }
    return null;
}

fn sentence(text: []const u8) []const u8 {
    const stop = std.mem.indexOf(u8, text, ". ") orelse return text;
    return text[0 .. stop + 1];
}

fn docCommentLine(buf: []u8, comment: []const u8) ?[]const u8 {
    const prefix = docPrefix(comment) orelse return null;
    const inner = if (std.mem.startsWith(u8, prefix, "/*") and std.mem.endsWith(u8, comment, "*/")) comment[0 .. comment.len - 2] else comment;
    const text = sentence(firstText(inner) orelse return null);
    const close = if (std.mem.startsWith(u8, prefix, "/*")) " */" else "";
    return std.fmt.bufPrint(buf, "{s} {s}{s}", .{ prefix, text, close }) catch null;
}

fn licenseLine(buf: []u8, comment: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, comment, "/*")) {
        const newline = std.mem.indexOfScalar(u8, comment, '\n') orelse comment.len;
        return std.fmt.bufPrint(buf, "{s}", .{std.mem.trimEnd(u8, comment[0..newline], " \t\r")}) catch null;
    }
    const inner = if (std.mem.endsWith(u8, comment, "*/")) comment[0 .. comment.len - 2] else comment;
    return std.fmt.bufPrint(buf, "/* {s} */", .{firstText(inner) orelse return null}) catch null;
}

fn docstringLine(buf: []u8, text: []const u8) ?[]const u8 {
    const quote = quoteOf(text) orelse return null;
    const at = quoteStart(text);
    if (text.len < at + 6) return null;
    const inner = text[at + 3 .. text.len - 3];
    var line = sentence(firstText(inner) orelse return null);
    line = std.mem.trimEnd(u8, line, "\"'\\");
    if (line.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}{s}{s}{s}", .{ text[0..at], quote, line, quote }) catch null;
}

fn isBlank(bytes: []const u8) bool {
    for (bytes) |c| if (!std.ascii.isWhitespace(c)) return false;
    return true;
}

fn foldTs(source: []const u8) !Folded {
    const t = try test_util.TestTree.init(source);
    defer t.deinit();
    return fold(std.testing.allocator, test_util.language, t.tree, 0, @intCast(source.len));
}

test "a multi-line JSDoc folds to its first sentence and reports the original lines" {
    const source = "const a = 1;\n/**\n * Adds two numbers. Very fast.\n * @param a left\n */\nexport function add(a: number): number {\n  return a;\n}\n";
    const folded = try foldTs(source);
    defer folded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("const a = 1;\n/** Adds two numbers. */\nexport function add(a: number): number {\n  return a;\n}\n", folded.text);
    try std.testing.expectEqual(@as(usize, 1), folded.spans.len);
    try std.testing.expectEqual(@as(u32, 2), folded.spans[0].first);
    try std.testing.expectEqual(@as(u32, 5), folded.spans[0].last);
}

test "plain comments and one-line docs stay byte for byte" {
    const source = "// keep me\n// and me\n/** one line */\nfunction f() {\n  /* inner\n     block */\n  return 1;\n}\n";
    const folded = try foldTs(source);
    defer folded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(source, folded.text);
    try std.testing.expectEqual(@as(usize, 0), folded.spans.len);
}

test "a license header at the top of the file collapses to its first line" {
    const source = "/*\n * Copyright 2020 Someone\n * Licensed under MIT\n */\nexport const x = 1;\n";
    const folded = try foldTs(source);
    defer folded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/* Copyright 2020 Someone */\nexport const x = 1;\n", folded.text);
}

test "a fold limited to a byte range returns only that range" {
    const source = "/**\n * Outer doc.\n */\nclass A {\n  /**\n   * Method doc.\n   * more\n   */\n  m() {}\n}\n";
    const open = std.mem.indexOfScalar(u8, source, '{').?;
    const t = try test_util.TestTree.init(source);
    defer t.deinit();
    const folded = try fold(std.testing.allocator, test_util.language, t.tree, @intCast(open), @intCast(source.len - 1));
    defer folded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("{\n  /** Method doc. */\n  m() {}\n}", folded.text);
    try std.testing.expectEqual(@as(u32, 5), folded.spans[0].first);
    try std.testing.expectEqual(@as(u32, 8), folded.spans[0].last);
}

test "a python docstring folds to a one-line docstring with the same quotes" {
    const profile = &@import("lang/python/profile.zig").profile;
    const source = "def f(a):\n    \"\"\"Return a. Twice.\n\n    Longer text.\n    \"\"\"\n    x = \"\"\"not\n    doc\"\"\"\n    return a\n";
    const parser = try ts.Parser.init(profile.grammar());
    defer parser.deinit();
    const tree = try parser.parse(source);
    defer tree.deinit();
    const folded = try fold(std.testing.allocator, profile, tree, 0, @intCast(source.len));
    defer folded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("def f(a):\n    \"\"\"Return a.\"\"\"\n    x = \"\"\"not\n    doc\"\"\"\n    return a\n", folded.text);
    try std.testing.expectEqual(@as(u32, 2), folded.spans[0].first);
    try std.testing.expectEqual(@as(u32, 5), folded.spans[0].last);
}
