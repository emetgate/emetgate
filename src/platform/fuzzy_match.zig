//! The fallback for an old_string that is not in the file byte for byte: both the file and
//! old_string are normalised the same way (blank lines and comments dropped, runs of
//! whitespace collapsed to one space, string literals kept verbatim), and when the normalised
//! old_string occurs exactly once in the normalised file, the smallest original byte range
//! covering that occurrence is the match. It is consulted only after the exact search found
//! nothing, never to break a tie between several exact matches.
//!
//! The match is used only when replacing it loses nothing the caller did not send: the range's
//! comments must be old_string's comments, and new_string is shifted by the one indentation
//! difference between old_string's lines and the range's. When the range holds a comment
//! old_string leaves out, or no single shift maps old_string's lines onto the range's (or, in a
//! language where indentation is syntax, the lines do not pair up), the fallback refuses and the
//! edit stays OldStringNotFound with a fix that says why.
const std = @import("std");

const Allocator = std.mem.Allocator;

/// What a reply says when the fallback chose the replaced range.
pub const note = "ignoring whitespace and comments";

/// The sentence the not-found fix text gains, since the fallback always ran before that error.
pub const also_tried = "a whitespace- and comment-insensitive search also found no single match";

const refused_comments = "a whitespace- and comment-insensitive search found one place, but it holds comments old_string leaves out and replacing it would delete them, so it was not used; send the exact text, comments included (emetgate_read_symbol or emetgate_read_file raw:true gives it)";
const refused_indentation = "a whitespace- and comment-insensitive search found one place, but its lines are indented differently from old_string's in a way one shift cannot carry over to new_string, so it was not used; send the exact text with its indentation (emetgate_read_symbol or emetgate_read_file raw:true gives it)";

/// Why the fallback found one place and did not use it.
pub const Refusal = enum { comments, indentation };

/// How comments and string literals are written in one language family.
pub const Syntax = struct {
    line: []const u8 = "",
    block_open: []const u8 = "",
    block_close: []const u8 = "",
    quotes: []const u8 = "",
    /// Python's ''' and """ strings, which may span lines.
    triple: bool = false,
    /// Zig's \\ multiline string lines, which run to the end of the line.
    line_string: []const u8 = "",
    /// Quotes whose strings may span lines (a JavaScript template literal).
    multiline_quotes: []const u8 = "",
    /// Indentation is syntax (Python, YAML, or a file of no known language): a range whose
    /// lines do not pair up one to one with old_string's is refused, not rewritten.
    indentation: bool = false,
};

const c_like: Syntax = .{ .line = "//", .block_open = "/*", .block_close = "*/", .quotes = "\"'`", .multiline_quotes = "`" };
const rust: Syntax = .{ .line = "//", .block_open = "/*", .block_close = "*/", .quotes = "\"" };
const zig: Syntax = .{ .line = "//", .quotes = "\"'", .line_string = "\\\\" };
const css: Syntax = .{ .block_open = "/*", .block_close = "*/", .quotes = "\"'" };
const hash: Syntax = .{ .line = "#", .quotes = "\"'", .triple = true };
const python: Syntax = .{ .line = "#", .quotes = "\"'", .triple = true, .indentation = true };
const yaml: Syntax = .{ .line = "#", .quotes = "\"'", .indentation = true };
const plain: Syntax = .{ .indentation = true };

const by_extension = [_]struct { []const u8, Syntax }{
    .{ ".zig", zig },
    .{ ".ts", c_like },    .{ ".tsx", c_like },  .{ ".mts", c_like },  .{ ".cts", c_like },
    .{ ".js", c_like },    .{ ".jsx", c_like },  .{ ".mjs", c_like },  .{ ".cjs", c_like },
    .{ ".cs", c_like },    .{ ".c", c_like },    .{ ".h", c_like },    .{ ".cc", c_like },
    .{ ".cpp", c_like },   .{ ".hpp", c_like },  .{ ".java", c_like }, .{ ".go", c_like },
    .{ ".kt", c_like },    .{ ".swift", c_like }, .{ ".scala", c_like }, .{ ".rs", rust },
    .{ ".css", css },      .{ ".scss", c_like }, .{ ".less", c_like },
    .{ ".py", python },    .{ ".pyi", python },  .{ ".sh", hash },     .{ ".bash", hash },
    .{ ".rb", hash },      .{ ".yml", yaml },    .{ ".yaml", yaml },   .{ ".toml", hash },
    .{ ".ps1", hash },
};

/// The comment and string syntax for a path, by its extension; a file of no known language
/// only has its whitespace and blank lines ignored.
pub fn syntaxFor(path: []const u8) Syntax {
    const ext = std.fs.path.extension(path);
    for (by_extension) |entry| {
        if (std.ascii.eqlIgnoreCase(entry[0], ext)) return entry[1];
    }
    return plain;
}

pub const Normalized = struct {
    text: []u8,
    /// origin[i] is the byte offset in the source that text[i] came from.
    origin: []u32,

    pub fn deinit(self: Normalized, gpa: Allocator) void {
        gpa.free(self.text);
        gpa.free(self.origin);
    }
};

const Builder = struct {
    gpa: Allocator,
    text: std.ArrayList(u8) = .empty,
    origin: std.ArrayList(u32) = .empty,
    gap: ?u32 = null,
    /// Where each dropped comment lies in the source, when the caller asks.
    comments: ?*std.ArrayList(Span) = null,

    fn comment(self: *Builder, start: usize, end: usize) !void {
        self.space(start);
        if (self.comments) |list| try list.append(self.gpa, .{ .start = start, .end = end });
    }

    fn byte(self: *Builder, c: u8, at: usize) !void {
        if (self.gap) |space_at| {
            if (self.text.items.len != 0) {
                try self.text.append(self.gpa, ' ');
                try self.origin.append(self.gpa, space_at);
            }
            self.gap = null;
        }
        try self.text.append(self.gpa, c);
        try self.origin.append(self.gpa, @intCast(at));
    }

    fn verbatim(self: *Builder, source: []const u8, start: usize, end: usize) !void {
        for (source[start..end], start..) |c, at| try self.byte(c, at);
    }

    fn space(self: *Builder, at: usize) void {
        if (self.gap == null) self.gap = @intCast(at);
    }
};

fn isSpace(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\r', '\n', 0x0b, 0x0c => true,
        else => false,
    };
}

/// Where a string literal opened at `start` by `q` ends (exclusive): at its unescaped closing
/// quote, or at the end of its line when it does not close there and may not span lines.
fn stringEnd(source: []const u8, start: usize, q: u8, multiline: bool) usize {
    var i = start + 1;
    while (i < source.len) : (i += 1) {
        const c = source[i];
        if (c == '\\') {
            i += 1;
            continue;
        }
        if (c == q) return i + 1;
        if (c == '\n' and !multiline) return i;
    }
    return source.len;
}

fn tripleEnd(source: []const u8, start: usize) usize {
    const quote = source[start .. start + 3];
    var i = start + 3;
    while (i < source.len) : (i += 1) {
        if (source[i] == '\\') {
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, source[i..], quote)) return i + 3;
    }
    return source.len;
}

/// Drops comments and blank lines and collapses whitespace outside string literals to one
/// space, with no space at either end; every kept byte remembers where it came from.
pub fn normalize(gpa: Allocator, source: []const u8, syntax: Syntax) !Normalized {
    return normalizeNoting(gpa, source, syntax, null);
}

fn normalizeNoting(gpa: Allocator, source: []const u8, syntax: Syntax, comments: ?*std.ArrayList(Span)) !Normalized {
    var b: Builder = .{ .gpa = gpa, .comments = comments };
    errdefer {
        b.text.deinit(gpa);
        b.origin.deinit(gpa);
    }
    var i: usize = 0;
    while (i < source.len) {
        const c = source[i];
        const rest = source[i..];
        if (isSpace(c)) {
            b.space(i);
            i += 1;
        } else if (syntax.line.len != 0 and std.mem.startsWith(u8, rest, syntax.line)) {
            const end = std.mem.indexOfScalarPos(u8, source, i, '\n') orelse source.len;
            try b.comment(i, end);
            i = end;
        } else if (syntax.block_open.len != 0 and std.mem.startsWith(u8, rest, syntax.block_open)) {
            const close = std.mem.indexOfPos(u8, source, i + syntax.block_open.len, syntax.block_close);
            const end = if (close) |at| at + syntax.block_close.len else source.len;
            try b.comment(i, end);
            i = end;
        } else if (syntax.line_string.len != 0 and std.mem.startsWith(u8, rest, syntax.line_string)) {
            const end = std.mem.indexOfScalarPos(u8, source, i, '\n') orelse source.len;
            try b.verbatim(source, i, end);
            i = end;
        } else if (std.mem.indexOfScalar(u8, syntax.quotes, c) != null) {
            const triple = syntax.triple and rest.len >= 3 and rest[1] == c and rest[2] == c;
            const end = if (triple) tripleEnd(source, i) else stringEnd(source, i, c, std.mem.indexOfScalar(u8, syntax.multiline_quotes, c) != null);
            try b.verbatim(source, i, end);
            i = end;
        } else {
            try b.byte(c, i);
            i += 1;
        }
    }
    const text = try b.text.toOwnedSlice(gpa);
    errdefer gpa.free(text);
    return .{ .text = text, .origin = try b.origin.toOwnedSlice(gpa) };
}

pub const Span = struct { start: usize, end: usize };

/// The one original byte range old matches once whitespace and comments are ignored, or null
/// when its normalised form is empty or occurs zero or several times; `count` is how many.
pub fn locate(gpa: Allocator, source: []const u8, old: []const u8, syntax: Syntax, count: *usize) !?Span {
    return locateNoting(gpa, source, old, syntax, count, null, null);
}

fn locateNoting(gpa: Allocator, source: []const u8, old: []const u8, syntax: Syntax, count: *usize, source_comments: ?*std.ArrayList(Span), old_comments: ?*std.ArrayList(Span)) !?Span {
    count.* = 0;
    const needle = try normalizeNoting(gpa, old, syntax, old_comments);
    defer needle.deinit(gpa);
    if (needle.text.len == 0) return null;
    const hay = try normalizeNoting(gpa, source, syntax, source_comments);
    defer hay.deinit(gpa);
    var found: ?usize = null;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, hay.text, from, needle.text)) |at| {
        count.* += 1;
        if (count.* > 1) return null;
        found = at;
        from = at + 1;
    }
    const at = found orelse return null;
    const last = at + needle.text.len - 1;
    return .{ .start = hay.origin[at], .end = hay.origin[last] + 1 };
}

/// What the fallback writes: source[start..end] becomes text (owned by the caller).
pub const Replacement = struct { start: usize, end: usize, text: []u8 };

/// The fallback for old -> new in source at path: null when no single place matches once
/// whitespace and comments are ignored; error.OldStringNotFound with `refusal` set when one
/// place matches but replacing it would drop a comment the caller did not send, or the
/// indentation cannot be carried over exactly; otherwise the range, widened to whole lines
/// where old_string has them, and new shifted to the range's indentation.
pub fn replacementFor(gpa: Allocator, path: []const u8, source: []const u8, old: []const u8, new: []const u8) !?Replacement {
    refused = null;
    const syntax = syntaxFor(path);
    var source_comments: std.ArrayList(Span) = .empty;
    defer source_comments.deinit(gpa);
    var old_comments: std.ArrayList(Span) = .empty;
    defer old_comments.deinit(gpa);
    var count: usize = 0;
    const span = (try locateNoting(gpa, source, old, syntax, &count, &source_comments, &old_comments)) orelse return null;

    // Every comment inside the range must be one old_string sends, in the same order.
    var sent_count: usize = 0;
    for (source_comments.items) |c| {
        if (c.start < span.start or c.start >= span.end) continue;
        if (sent_count >= old_comments.items.len) return refuse(.comments);
        const sent = old_comments.items[sent_count];
        if (!eqlCollapsed(source[c.start..c.end], old[sent.start..sent.end])) return refuse(.comments);
        sent_count += 1;
    }
    if (sent_count != old_comments.items.len) return refuse(.comments);

    var start = span.start;
    var end = span.end;
    const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..start], '\n')) |nl| nl + 1 else 0;
    const lead = old[0 .. old.len - std.mem.trimStart(u8, old, whitespace).len];
    const first_indent = lead[if (std.mem.lastIndexOfScalar(u8, lead, '\n')) |nl| nl + 1 else 0..];
    // old_string starts with indentation: the range starts at its line's start, so new_string's
    // own first-line indentation replaces the file's instead of following it.
    const widened = first_indent.len != 0;
    if (widened) {
        if (!isIndent(source[line_start..start])) return refuse(.indentation);
        start = line_start;
    }
    // old_string ends with a line break: so does the range.
    if (std.mem.indexOfScalar(u8, old[std.mem.trimEnd(u8, old, whitespace).len..], '\n') != null) {
        var at = end;
        while (at < source.len and (source[at] == ' ' or source[at] == '\t' or source[at] == '\r')) at += 1;
        if (at < source.len and source[at] == '\n') end = at + 1;
    }
    // The range's first line has an indentation to compare only when the range starts at the
    // line's start; otherwise old_string's first line follows the file's indentation as it is.
    const first_known = widened or start == line_start;

    const old_lines = try indents(gpa, old);
    defer gpa.free(old_lines);
    const range_lines = try indents(gpa, source[start..end]);
    defer gpa.free(range_lines);
    var add: []const u8 = "";
    var remove: []const u8 = "";
    if (old_lines.len != range_lines.len) {
        if (syntax.indentation) return refuse(.indentation);
    } else {
        var set = false;
        for (old_lines, range_lines, 0..) |sent, there, i| {
            if (i == 0 and !first_known) continue;
            var a: []const u8 = "";
            var r: []const u8 = "";
            if (std.mem.endsWith(u8, there, sent)) {
                a = there[0 .. there.len - sent.len];
            } else if (std.mem.endsWith(u8, sent, there)) {
                r = sent[0 .. sent.len - there.len];
            } else return refuse(.indentation);
            if (!set) {
                add = a;
                remove = r;
                set = true;
            } else if (!std.mem.eql(u8, a, add) or !std.mem.eql(u8, r, remove)) return refuse(.indentation);
        }
    }

    const shift = if (add.len != 0) add else remove;
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    var lines = std.mem.splitScalar(u8, new, '\n');
    var index: usize = 0;
    while (lines.next()) |line| : (index += 1) {
        if (index != 0) try text.append(gpa, '\n');
        const at_line_start = index != 0 or widened;
        const blank = std.mem.trim(u8, line, " \t\r").len == 0;
        if (!at_line_start or shift.len == 0 or blank) {
            try text.appendSlice(gpa, line);
            continue;
        }
        const own = line[0 .. line.len - std.mem.trimStart(u8, line, " \t").len];
        if (syntax.indentation and !oneChar(shift, own)) return refuse(.indentation);
        if (add.len != 0) {
            try text.appendSlice(gpa, add);
            try text.appendSlice(gpa, line);
        } else {
            if (!std.mem.startsWith(u8, line, remove)) return refuse(.indentation);
            try text.appendSlice(gpa, line[remove.len..]);
        }
    }
    return .{ .start = start, .end = end, .text = try text.toOwnedSlice(gpa) };
}

const whitespace = " \t\r\n\x0b\x0c";

fn refuse(why: Refusal) error{OldStringNotFound} {
    refused = why;
    return error.OldStringNotFound;
}

fn isIndent(text: []const u8) bool {
    for (text) |c| if (c != ' ' and c != '\t') return false;
    return true;
}

/// Whether the shift and a line's own indentation are one character repeated, so shifting
/// never mixes tabs and spaces where indentation is syntax.
fn oneChar(shift: []const u8, own: []const u8) bool {
    const c = shift[0];
    for (shift) |x| if (x != c) return false;
    for (own) |x| if (x != c) return false;
    return true;
}

/// The leading spaces and tabs of every line of text that is not blank.
fn indents(gpa: Allocator, text: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const body = std.mem.trimStart(u8, line, " \t");
        if (std.mem.trim(u8, body, whitespace).len == 0) continue;
        try list.append(gpa, line[0 .. line.len - body.len]);
    }
    return list.toOwnedSlice(gpa);
}

/// Whether a and b are equal once each run of whitespace is one space and both ends are trimmed.
fn eqlCollapsed(a: []const u8, b: []const u8) bool {
    var x = std.mem.tokenizeAny(u8, a, whitespace);
    var y = std.mem.tokenizeAny(u8, b, whitespace);
    while (true) {
        const p = x.next();
        const q = y.next();
        if (p == null or q == null) return p == null and q == null;
        if (!std.mem.eql(u8, p.?, q.?)) return false;
    }
}

threadlocal var used: bool = false;
threadlocal var refused: ?Refusal = null;

/// Forgets whether the fallback chose or refused a range; a tool calls it before it applies edits.
pub fn reset() void {
    used = false;
    refused = null;
}

/// Why the last fallback that found one place did not use it, if it did not.
pub fn refusal() ?Refusal {
    return refused;
}

/// The sentence the not-found fix text gains: that no single place matched, or why the one
/// place that did was not used.
pub fn notFoundReason() []const u8 {
    const why = refused orelse return also_tried;
    return refusalText(why);
}

/// The sentence that says why the fallback did not use the one place it found.
pub fn refusalText(why: Refusal) []const u8 {
    return switch (why) {
        .comments => refused_comments,
        .indentation => refused_indentation,
    };
}

/// The refusal, forgotten once taken, so a later not-found error never repeats it.
pub fn takeRefusal() ?Refusal {
    defer refused = null;
    return refused;
}

pub fn markUsed() void {
    used = true;
}

pub fn wasUsed() bool {
    return used;
}

/// The reply with "matched" added as the first field of its leading JSON object, so a range
/// the fallback chose is never written silently. Text that is not a JSON object is returned as is.
pub fn annotate(gpa: Allocator, text: []const u8) ![]u8 {
    if (text.len == 0 or text[0] != '{') return gpa.dupe(u8, text);
    const field = "\"matched\":\"" ++ note ++ "\"";
    const empty = text.len > 1 and text[1] == '}';
    return std.mem.concat(gpa, u8, &.{ "{", field, if (empty) "" else ",", text[1..] });
}
