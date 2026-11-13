//! The fallback for an old_string that is not in the file byte for byte: both the file and
//! old_string are normalised the same way (blank lines and comments dropped, runs of
//! whitespace collapsed to one space, string literals kept verbatim), and when the normalised
//! old_string occurs exactly once in the normalised file, the smallest original byte range
//! covering that occurrence is the match. It is consulted only after the exact search found
//! nothing, never to break a tie between several exact matches.
const std = @import("std");

const Allocator = std.mem.Allocator;

/// What a reply says when the fallback chose the replaced range.
pub const note = "ignoring whitespace and comments";

/// The sentence the not-found fix text gains, since the fallback always ran before that error.
pub const also_tried = "a whitespace- and comment-insensitive search also found no single match";

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
};

const c_like: Syntax = .{ .line = "//", .block_open = "/*", .block_close = "*/", .quotes = "\"'`", .multiline_quotes = "`" };
const rust: Syntax = .{ .line = "//", .block_open = "/*", .block_close = "*/", .quotes = "\"" };
const zig: Syntax = .{ .line = "//", .quotes = "\"'", .line_string = "\\\\" };
const css: Syntax = .{ .block_open = "/*", .block_close = "*/", .quotes = "\"'" };
const hash: Syntax = .{ .line = "#", .quotes = "\"'", .triple = true };
const plain: Syntax = .{};

const by_extension = [_]struct { []const u8, Syntax }{
    .{ ".zig", zig },
    .{ ".ts", c_like },    .{ ".tsx", c_like },  .{ ".mts", c_like },  .{ ".cts", c_like },
    .{ ".js", c_like },    .{ ".jsx", c_like },  .{ ".mjs", c_like },  .{ ".cjs", c_like },
    .{ ".cs", c_like },    .{ ".c", c_like },    .{ ".h", c_like },    .{ ".cc", c_like },
    .{ ".cpp", c_like },   .{ ".hpp", c_like },  .{ ".java", c_like }, .{ ".go", c_like },
    .{ ".kt", c_like },    .{ ".swift", c_like }, .{ ".scala", c_like }, .{ ".rs", rust },
    .{ ".css", css },      .{ ".scss", c_like }, .{ ".less", c_like },
    .{ ".py", hash },      .{ ".pyi", hash },    .{ ".sh", hash },     .{ ".bash", hash },
    .{ ".rb", hash },      .{ ".yml", hash },    .{ ".yaml", hash },   .{ ".toml", hash },
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
    var b: Builder = .{ .gpa = gpa };
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
            b.space(i);
            i = std.mem.indexOfScalarPos(u8, source, i, '\n') orelse source.len;
        } else if (syntax.block_open.len != 0 and std.mem.startsWith(u8, rest, syntax.block_open)) {
            b.space(i);
            const close = std.mem.indexOfPos(u8, source, i + syntax.block_open.len, syntax.block_close);
            i = if (close) |at| at + syntax.block_close.len else source.len;
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
    count.* = 0;
    const needle = try normalize(gpa, old, syntax);
    defer needle.deinit(gpa);
    if (needle.text.len == 0) return null;
    const hay = try normalize(gpa, source, syntax);
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

threadlocal var used: bool = false;

/// Forgets whether the fallback chose a range; a tool calls it before it applies edits.
pub fn reset() void {
    used = false;
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
