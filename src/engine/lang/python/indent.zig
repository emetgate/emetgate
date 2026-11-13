//! Python's tokenizer rules for INDENT and DEDENT, which tree-sitter-python does not
//! enforce: an unindent that matches no outer level, an indent no block opened, a block
//! header with no indented body, and tabs and spaces that disagree (TabError). Lines inside
//! brackets, after a backslash and inside strings are continuation lines and are skipped,
//! as the tokenizer does; blank and comment-only lines carry no indentation.
const std = @import("std");
const source_check = @import("../../source_check.zig");

const Fault = source_check.Fault;

const max_levels = 100;
const tab_size = 8;

pub const inconsistent_dedent = "IndentationError: unindent does not match any outer indentation level";
pub const unexpected_indent = "IndentationError: unexpected indent";
pub const expected_block = "IndentationError: expected an indented block";
pub const tab_error = "TabError: inconsistent use of tabs and spaces in indentation";
pub const too_deep = "IndentationError: too many levels of indentation";

const Scanner = struct {
    src: []const u8,
    i: usize = 0,
    line: u32 = 1,

    fn atNewline(self: *Scanner) bool {
        return self.i < self.src.len and (self.src[self.i] == '\n' or self.src[self.i] == '\r');
    }

    /// Consumes one line break (\n, \r\n or \r).
    fn newline(self: *Scanner) void {
        if (self.src[self.i] == '\r' and self.i + 1 < self.src.len and self.src[self.i + 1] == '\n') self.i += 1;
        self.i += 1;
        self.line += 1;
    }

    /// Skips the string whose opening quote is at `i`; `format` for f- and t-strings,
    /// whose replacement fields may hold nested strings and line breaks.
    fn string(self: *Scanner, format: bool, nesting: u8) void {
        const quote = self.src[self.i];
        const triple = self.i + 2 < self.src.len and self.src[self.i + 1] == quote and self.src[self.i + 2] == quote;
        self.i += if (triple) 3 else 1;
        var braces: u32 = 0;
        while (self.i < self.src.len) {
            const c = self.src[self.i];
            if (c == '\\') {
                self.i += 1;
                if (self.i < self.src.len) {
                    if (self.atNewline()) self.newline() else self.i += 1;
                }
                continue;
            }
            if (self.atNewline()) {
                if (!triple and braces == 0) return; // unterminated: the grammar reports it
                self.newline();
                continue;
            }
            if (format and c == '{') {
                if (braces == 0 and self.i + 1 < self.src.len and self.src[self.i + 1] == '{') {
                    self.i += 2;
                    continue;
                }
                braces += 1;
                self.i += 1;
                continue;
            }
            if (format and c == '}' and braces > 0) {
                braces -= 1;
                self.i += 1;
                continue;
            }
            if (braces > 0 and (c == '\'' or c == '"') and nesting < 16) {
                self.string(stringPrefixIsFormat(self.src, self.i), nesting + 1);
                continue;
            }
            if (c == quote) {
                if (!triple) {
                    self.i += 1;
                    return;
                }
                if (self.i + 2 < self.src.len and self.src[self.i + 1] == quote and self.src[self.i + 2] == quote) {
                    self.i += 3;
                    return;
                }
            }
            self.i += 1;
        }
    }
};

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

/// Whether the letters right before the quote at `quote_at` make it an f- or t-string.
fn stringPrefixIsFormat(src: []const u8, quote_at: usize) bool {
    var start = quote_at;
    while (start > 0 and quote_at - start < 3 and std.mem.indexOfScalar(u8, "rRbBuUfFtT", src[start - 1]) != null) start -= 1;
    if (start > 0 and isWordByte(src[start - 1])) return false;
    for (src[start..quote_at]) |c| switch (c) {
        'f', 'F', 't', 'T' => return true,
        else => {},
    };
    return false;
}

/// Returns the first indentation fault in `source` by Python's tokenizer rules, or null.
pub fn check(source: []const u8) ?Fault {
    var s: Scanner = .{ .src = source };
    if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) s.i = 3;
    var cols: [max_levels]u32 = undefined;
    var alts: [max_levels]u32 = undefined;
    cols[0] = 0;
    alts[0] = 0;
    var depth: usize = 1;
    var brackets: u32 = 0;
    var joined = false; // the previous physical line ended with a backslash
    var opens_block = false; // the last logical line ended with ':'
    var header_line: u32 = 0; // the line of the last ':' seen
    var last: u8 = 0; // last significant byte of the current logical line

    while (s.i < source.len) {
        const logical_start = brackets == 0 and !joined;
        joined = false;
        var col: u32 = 0;
        var alt: u32 = 0;
        while (s.i < source.len) : (s.i += 1) switch (source[s.i]) {
            ' ' => {
                col += 1;
                alt += 1;
            },
            '\t' => {
                col = (col / tab_size + 1) * tab_size;
                alt += 1;
            },
            '\x0c' => {
                col = 0;
                alt = 0;
            },
            else => break,
        };
        if (s.i >= source.len) break;
        if (source[s.i] == '#' or s.atNewline()) {
            while (s.i < source.len and !s.atNewline()) s.i += 1;
            if (s.i < source.len) s.newline();
            continue;
        }
        if (logical_start) {
            // The tokenizer's checks first (TabError, unmatched unindent), then the
            // parser's (an indent no block opened, a block with no body), as CPython orders them.
            const top = depth - 1;
            if (col == cols[top]) {
                if (alt != alts[top]) return .{ .line = s.line, .reason = tab_error };
                if (opens_block) return .{ .line = s.line, .reason = expected_block };
            } else if (col > cols[top]) {
                if (alt <= alts[top]) return .{ .line = s.line, .reason = tab_error };
                if (!opens_block) return .{ .line = s.line, .reason = unexpected_indent };
                if (depth == max_levels) return .{ .line = s.line, .reason = too_deep };
                cols[depth] = col;
                alts[depth] = alt;
                depth += 1;
            } else {
                while (depth > 1 and col < cols[depth - 1]) depth -= 1;
                if (col != cols[depth - 1]) return .{ .line = s.line, .reason = inconsistent_dedent };
                if (alt != alts[depth - 1]) return .{ .line = s.line, .reason = tab_error };
                if (opens_block) return .{ .line = s.line, .reason = expected_block };
            }
            opens_block = false;
            last = 0;
        }
        // The rest of the physical line, and any line a string or bracket carries it to.
        while (s.i < source.len) {
            const c = source[s.i];
            if (s.atNewline()) {
                s.newline();
                break;
            }
            switch (c) {
                '#' => {
                    while (s.i < source.len and !s.atNewline()) s.i += 1;
                },
                '\\' => {
                    s.i += 1;
                    if (s.atNewline()) {
                        s.newline();
                        joined = true;
                        break;
                    }
                },
                '\'', '"' => {
                    s.string(stringPrefixIsFormat(source, s.i), 0);
                    last = 's';
                },
                '(', '[', '{' => {
                    brackets += 1;
                    last = c;
                    s.i += 1;
                },
                ')', ']', '}' => {
                    if (brackets > 0) brackets -= 1;
                    last = c;
                    s.i += 1;
                },
                ' ', '\t', '\x0c' => s.i += 1,
                else => {
                    last = c;
                    if (c == ':') header_line = s.line;
                    s.i += 1;
                },
            }
        }
        if (brackets == 0 and !joined and last == ':') {
            opens_block = true;
            last = 0;
        }
    }
    if (opens_block) return .{ .line = header_line, .reason = expected_block };
    return null;
}

const testing = std.testing;

fn expectFault(source: []const u8, line: u32, reason: []const u8) !void {
    const fault = check(source) orelse return error.TestExpectedFault;
    try testing.expectEqualStrings(reason, fault.reason);
    try testing.expectEqual(line, fault.line);
}

test "python indentation: an unindent that matches no outer level is refused at its line" {
    try expectFault("def f(s):\n    s = s + 1\n   return s\n", 3, inconsistent_dedent);
}

test "python indentation: an indent after a line that opens no block is refused" {
    try expectFault("x = 1\n    y = 2\n", 2, unexpected_indent);
    try expectFault("  x = 1\n", 1, unexpected_indent);
}

test "python indentation: a tab where the block used spaces is a TabError" {
    try expectFault("def f():\n        a = 1\n\tb = 2\n", 3, tab_error);
}

test "python indentation: a block header with no indented body is refused" {
    try expectFault("def f():\nreturn 1\n", 2, expected_block);
    try expectFault("if x:\n", 1, expected_block);
}

test "python indentation: valid code passes, with continuation lines, strings and comments" {
    const valid =
        \\import os
        \\
        \\
        \\class A:
        \\    """Doc
        \\  that dedents inside the string.
        \\    """
        \\
        \\    def f(self, a,
        \\  b):
        \\        x = [1,
        \\   2]  # comment
        \\# a comment at column 0
        \\        y = 1 + \
        \\  2
        \\        s = f"{a!r:>{b}} {'x' if a else "y"}"
        \\        if x: return y
        \\        return {k: v for k, v in
        \\            x}
        \\
        \\    async def g(self):
        \\        match self:
        \\            case 1:
        \\                pass
        \\            case _:
        \\                pass
        \\
        \\
        \\
    ++ "def h():\n\treturn 1\n";
    try testing.expect(check(valid) == null);
    try testing.expect(check("") == null);
    try testing.expect(check("\xEF\xBB\xBFx = 1\r\nif x:\r\n    y = 2\r\n") == null);
    try testing.expect(check("x = r'\\'' + '\\\\'\n") == null);
}
