const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Error = error{UnterminatedQuote} || Allocator.Error;

const whitespace = " \t\r\n";

const Quote = enum { none, single, double };

pub fn split(arena: Allocator, text: []const u8) Error![]const [:0]const u8 {
    var words: std.ArrayList([:0]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    var in_word = false;
    var quote: Quote = .none;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        switch (quote) {
            .none => {
                if (std.mem.indexOfScalar(u8, whitespace, c) != null) {
                    if (in_word) try words.append(arena, try word.toOwnedSliceSentinel(arena, 0));
                    in_word = false;
                    continue;
                }
                in_word = true;
                switch (c) {
                    '"' => quote = .double,
                    '\'' => quote = .single,
                    else => try word.append(arena, c),
                }
            },
            .single => {
                if (c == '\'') quote = .none else try word.append(arena, c);
            },
            .double => {
                if (c == '"') {
                    quote = .none;
                } else if (c == '\\' and i + 1 < text.len and text[i + 1] == '"') {
                    try word.append(arena, '"');
                    i += 1;
                } else try word.append(arena, c);
            },
        }
    }
    if (quote != .none) return error.UnterminatedQuote;
    if (in_word) try words.append(arena, try word.toOwnedSliceSentinel(arena, 0));
    return words.toOwnedSlice(arena);
}
