const std = @import("std");
const lexicon_mod = @import("question_lexicon.zig");

const Allocator = std.mem.Allocator;
const Lexicon = lexicon_mod.Lexicon;
const max_word = lexicon_mod.max_word;

pub const Kind = enum { word, identifier, path, number };

pub const Token = struct {
    text: []const u8,
    folded: []const u8,
    kind: Kind,
    quoted: bool = false,
};

pub const Origin = enum { identifier, path, number, lexicon, word };

pub const Concept = struct {
    alternatives: []const []const u8,
    display: []const u8,
    origin: Origin,
    weight: f32,
};

pub const Query = struct {
    tokens: []const Token,
    concepts: []const Concept,
    turkish: bool,
};

pub const Vocabulary = struct {
    ctx: *const anyopaque,
    hasFn: *const fn (ctx: *const anyopaque, term: []const u8) bool,

    pub fn has(self: Vocabulary, term: []const u8) bool {
        return self.hasFn(self.ctx, term);
    }
};

pub const Options = struct {
    lexicon: bool = true,
    stemming: bool = true,
    keep_unknown: bool = false,
};

pub const PieceKind = enum { part, pair, whole };

pub const weight_whole: f32 = 2.0;
pub const weight_part: f32 = 1.0;
pub const weight_pair: f32 = 0.8;
pub const weight_path_whole: f32 = 1.5;
pub const weight_number: f32 = 0.5;
pub const weight_lexicon: f32 = 1.0;
pub const weight_word: f32 = 1.0;

fn isUpper(c: u8) bool {
    return c >= 'A' and c <= 'Z';
}

fn isLower(c: u8) bool {
    return (c >= 'a' and c <= 'z') or c >= 0x80;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isWordByte(c: u8) bool {
    return isUpper(c) or isLower(c) or isDigit(c);
}

fn hardSeparator(c: u8) bool {
    return c == '.' or c == '/' or c == '\\' or c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == ':';
}

fn boundary(run: []const u8, i: usize) bool {
    const prev = run[i - 1];
    const cur = run[i];
    if ((isLower(prev) or isDigit(prev)) and isUpper(cur)) return true;
    if ((isUpper(prev) or isLower(prev)) and isDigit(cur)) return true;
    if (isDigit(prev) and (isUpper(cur) or isLower(cur))) return true;
    if (isUpper(prev) and isUpper(cur) and i + 1 < run.len and isLower(run[i + 1])) {
        const plural = run[i + 1] == 's' and (i + 2 == run.len or !isLower(run[i + 2]));
        return !plural;
    }
    return false;
}

pub fn eachPiece(lex: *const Lexicon, text: []const u8, ctx: anytype) !void {
    var lower: [max_word]u8 = undefined;
    var stemmed: [max_word]u8 = undefined;
    var joined: [max_word]u8 = undefined;
    var seg_start: usize = 0;
    while (seg_start < text.len) {
        while (seg_start < text.len and hardSeparator(text[seg_start])) seg_start += 1;
        var seg_end = seg_start;
        while (seg_end < text.len and !hardSeparator(text[seg_end])) seg_end += 1;
        if (seg_end == seg_start) break;
        const segment = text[seg_start..seg_end];
        seg_start = seg_end;
        var joined_len: usize = 0;
        var joined_ok = true;
        var parts_total: usize = 0;
        var run_start: usize = 0;
        while (run_start < segment.len) {
            while (run_start < segment.len and !isWordByte(segment[run_start])) run_start += 1;
            var run_end = run_start;
            while (run_end < segment.len and isWordByte(segment[run_end])) run_end += 1;
            if (run_end == run_start) break;
            const run = segment[run_start..run_end];
            run_start = run_end;
            var prev: ?[]const u8 = null;
            var part_start: usize = 0;
            var i: usize = 1;
            while (i <= run.len) : (i += 1) {
                if (i < run.len and !boundary(run, i)) continue;
                const part = run[part_start..i];
                part_start = i;
                parts_total += 1;
                if (part.len > max_word) {
                    joined_ok = false;
                    prev = null;
                    continue;
                }
                for (part, 0..) |c, k| lower[k] = std.ascii.toLower(c);
                const low = lower[0..part.len];
                if (joined_ok and joined_len + low.len <= max_word) {
                    @memcpy(joined[joined_len .. joined_len + low.len], low);
                    joined_len += low.len;
                } else joined_ok = false;
                if (low.len >= 2 or isDigit(low[0])) try ctx.piece(lex.enStem(low, &stemmed), .part, low);
                if (prev) |p| {
                    if ((p.len <= 2 or low.len <= 2) and p.len + low.len <= max_word) {
                        var pair: [max_word]u8 = undefined;
                        for (p, 0..) |c, k| pair[k] = std.ascii.toLower(c);
                        @memcpy(pair[p.len .. p.len + low.len], low);
                        try ctx.piece(lex.enStem(pair[0 .. p.len + low.len], &stemmed), .pair, pair[0 .. p.len + low.len]);
                    }
                }
                prev = part;
            }
        }
        if (joined_ok and parts_total >= 2) try ctx.piece(lex.enStem(joined[0..joined_len], &stemmed), .whole, joined[0..joined_len]);
    }
}

fn trimPunct(text: []const u8) []const u8 {
    const set = ",;:?!()[]{}<>\"'`*";
    var t = std.mem.trim(u8, text, set);
    while (t.len > 0 and t[t.len - 1] == '.') t = t[0 .. t.len - 1];
    while (true) {
        if (std.mem.startsWith(u8, t, "\u{201C}") or std.mem.startsWith(u8, t, "\u{201D}") or std.mem.startsWith(u8, t, "\u{2018}") or std.mem.startsWith(u8, t, "\u{2019}")) {
            t = t[3..];
            continue;
        }
        if (std.mem.endsWith(u8, t, "\u{201C}") or std.mem.endsWith(u8, t, "\u{201D}") or std.mem.endsWith(u8, t, "\u{2018}") or std.mem.endsWith(u8, t, "\u{2019}")) {
            t = t[0 .. t.len - 3];
            continue;
        }
        break;
    }
    return std.mem.trim(u8, t, set);
}

fn apostropheBase(text: []const u8) []const u8 {
    var i: usize = 1;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\'' and i + 1 < text.len) return text[0..i];
        if (std.mem.startsWith(u8, text[i..], "\u{2019}") and i + 3 < text.len) return text[0..i];
    }
    return text;
}

fn looksIdentifier(text: []const u8) bool {
    var lower = false;
    var upper: usize = 0;
    var digit = false;
    var letter = false;
    for (text, 0..) |c, i| {
        if (c >= 0x80) return false;
        if (isLower(c)) {
            lower = true;
            letter = true;
        } else if (isUpper(c)) {
            if (lower and i > 0) return true;
            upper += 1;
            letter = true;
        } else if (isDigit(c)) {
            digit = true;
        } else if (c == '_' or c == '$' or c == '.' or c == '-') {
            if (i > 0 and i + 1 < text.len) return letter;
        } else return false;
    }
    if (letter and digit) return true;
    return upper >= 2 and !lower;
}

fn allDigits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (!isDigit(c)) return false;
    return true;
}

fn classify(lex: *const Lexicon, text: []const u8) Kind {
    if (std.mem.indexOfAny(u8, text, "/\\") != null) return .path;
    if (lex.hasPathExtension(text)) return .path;
    if (allDigits(text)) return .number;
    if (looksIdentifier(text)) return .identifier;
    return .word;
}

fn quoteAt(text: []const u8, i: usize) ?u8 {
    const c = text[i];
    if (c == '"' or c == '`') return c;
    if (c != '\'') return null;
    if (i > 0 and isWordByte(text[i - 1])) return null;
    return c;
}

pub fn tokenize(arena: Allocator, lex: *const Lexicon, question: []const u8) ![]Token {
    var out: std.ArrayList(Token) = .empty;
    try tokenizeInto(arena, lex, question, false, &out);
    return out.items;
}

fn tokenizeInto(arena: Allocator, lex: *const Lexicon, text: []const u8, quoted: bool, out: *std.ArrayList(Token)) !void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            i += 1;
            continue;
        }
        if (!quoted) {
            if (quoteAt(text, i)) |q| {
                if (std.mem.indexOfScalarPos(u8, text, i + 1, q)) |close| {
                    const after_ok = close + 1 >= text.len or !isWordByte(text[close + 1]);
                    if (after_ok and close > i + 1) {
                        try tokenizeInto(arena, lex, text[i + 1 .. close], true, out);
                        i = close + 1;
                        continue;
                    }
                }
            }
        }
        var end = i;
        while (end < text.len and text[end] != ' ' and text[end] != '\t' and text[end] != '\n' and text[end] != '\r') end += 1;
        const raw = text[i..end];
        i = end;
        const trimmed = trimPunct(raw);
        if (trimmed.len == 0) continue;
        const base = trimPunct(apostropheBase(trimmed));
        if (base.len == 0) continue;
        const kind = classify(lex, base);
        if (kind == .word and std.mem.indexOfScalar(u8, base, '-') != null) {
            var pieces = std.mem.tokenizeScalar(u8, base, '-');
            while (pieces.next()) |piece| {
                const clean = trimPunct(piece);
                if (clean.len == 0) continue;
                try out.append(arena, .{ .text = clean, .folded = try lex.fold(arena, clean), .kind = classify(lex, clean), .quoted = quoted });
            }
            continue;
        }
        try out.append(arena, .{ .text = base, .folded = try lex.fold(arena, base), .kind = kind, .quoted = quoted });
    }
}

const Builder = struct {
    arena: Allocator,
    lex: *const Lexicon,
    vocab: ?Vocabulary,
    options: Options,
    concepts: std.ArrayList(Concept) = .empty,
    seen: std.StringHashMapUnmanaged(usize) = .empty,

    fn add(self: *Builder, alternatives: []const []const u8, display: []const u8, origin: Origin, weight: f32) !void {
        if (alternatives.len == 0) return;
        const key = try std.mem.join(self.arena, "|", alternatives);
        const slot = try self.seen.getOrPut(self.arena, key);
        if (slot.found_existing) {
            const existing = &self.concepts.items[slot.value_ptr.*];
            existing.weight = @max(existing.weight, weight);
            return;
        }
        slot.value_ptr.* = self.concepts.items.len;
        try self.concepts.append(self.arena, .{ .alternatives = alternatives, .display = display, .origin = origin, .weight = weight });
    }

    fn stemmed(self: *Builder, word: []const u8) ![]const u8 {
        var buf: [max_word]u8 = undefined;
        const s = if (self.options.stemming) self.lex.enStem(word, &buf) else word;
        return self.arena.dupe(u8, s);
    }

    fn known(self: *const Builder, term: []const u8) bool {
        const v = self.vocab orelse return true;
        return v.has(term);
    }

    const PieceSink = struct {
        b: *Builder,
        display: []const u8,
        origin: Origin,
        whole: f32,

        fn piece(self: *PieceSink, term: []const u8, kind: PieceKind, raw: []const u8) !void {
            const owned = try self.b.arena.dupe(u8, term);
            const alternatives = try self.b.arena.dupe([]const u8, &.{owned});
            const weight: f32 = switch (kind) {
                .part => weight_part,
                .pair => weight_pair,
                .whole => self.whole,
            };
            const display = if (kind == .whole) self.display else try self.b.arena.dupe(u8, raw);
            try self.b.add(alternatives, display, self.origin, weight);
        }
    };

    fn identifier(self: *Builder, token: Token, origin: Origin, whole: f32) !void {
        var sink: PieceSink = .{ .b = self, .display = token.text, .origin = origin, .whole = whole };
        try eachPiece(self.lex, token.text, &sink);
        var single = true;
        for (token.text) |c| if (!isWordByte(c)) {
            single = false;
        };
        if (single) {
            var low: [max_word]u8 = undefined;
            if (token.text.len <= max_word) {
                for (token.text, 0..) |c, k| low[k] = std.ascii.toLower(c);
                var buf: [max_word]u8 = undefined;
                const s = self.lex.enStem(low[0..token.text.len], &buf);
                const owned = try self.arena.dupe(u8, s);
                try self.add(try self.arena.dupe([]const u8, &.{owned}), token.text, origin, whole);
            }
        }
    }

    fn lexiconConcept(self: *Builder, entry: *const lexicon_mod.Entry) !void {
        var alternatives: std.ArrayList([]const u8) = .empty;
        for (entry.values) |v| {
            const s = try self.stemmed(v);
            for (alternatives.items) |a| {
                if (std.mem.eql(u8, a, s)) break;
            } else try alternatives.append(self.arena, s);
        }
        try self.add(alternatives.items, entry.values[0], .lexicon, weight_lexicon);
    }

    fn englishWord(self: *Builder, folded: []const u8, display: []const u8) !void {
        if (self.lex.isEnStop(folded)) return;
        const s = try self.stemmed(folded);
        if (!self.options.keep_unknown and !self.known(s)) return;
        try self.add(try self.arena.dupe([]const u8, &.{s}), display, .word, weight_word);
    }

    const StemmedKnown = struct {
        b: *const Builder,

        pub fn has(self: StemmedKnown, candidate: []const u8) bool {
            var buf: [max_word]u8 = undefined;
            const s = if (self.b.options.stemming) self.b.lex.enStem(candidate, &buf) else candidate;
            if (self.b.lex.isEnStop(candidate)) return false;
            return self.b.vocab != null and self.b.vocab.?.has(s);
        }
    };

    fn turkishWord(self: *Builder, token: Token) !void {
        const folded = token.folded;
        var info: ?lexicon_mod.Stem = null;
        if (self.options.stemming) {
            if (self.lex.analyze(folded)) |a| {
                info = a.info;
                const plain = std.ascii.eqlIgnoreCase(folded, token.text);
                if (a.cost != 0 and plain and self.vocab != null and !self.lex.isEnStop(folded)) {
                    var buf: [max_word]u8 = undefined;
                    if (self.vocab.?.has(self.lex.enStem(folded, &buf))) return self.englishWord(folded, token.text);
                }
            }
        } else info = self.lex.stem(folded);
        if (info) |found| {
            if (found.stop) return;
            if (self.options.lexicon) {
                if (self.lex.entryOf(found)) |entry| return self.lexiconConcept(entry);
            }
        }
        if (self.lex.isEnStop(folded)) return;
        var buf: [max_word]u8 = undefined;
        const direct = if (self.options.stemming) self.lex.enStem(folded, &buf) else folded;
        if (self.known(direct)) return self.englishWord(folded, token.text);
        if (self.options.stemming and self.vocab != null) {
            const checker: StemmedKnown = .{ .b = self };
            if (self.lex.suffixedPrefix(folded, 3, checker)) |prefix| return self.englishWord(prefix, prefix);
        }
        if (self.options.keep_unknown) return self.englishWord(folded, token.text);
    }

    fn phraseStem(self: *const Builder, token: Token) []const u8 {
        if (self.options.stemming) {
            if (self.lex.analyze(token.folded)) |a| return a.stem;
        }
        return token.folded;
    }

    fn phraseAt(self: *Builder, tokens: []const Token, at: usize) !usize {
        if (!self.options.lexicon) return 0;
        var n = @min(self.lex.max_phrase, tokens.len - at);
        while (n >= 2) : (n -= 1) {
            var parts: std.ArrayList([]const u8) = .empty;
            for (tokens[at .. at + n]) |t| {
                if (t.kind != .word) break;
                try parts.append(self.arena, self.phraseStem(t));
            } else {
                const key = try std.mem.join(self.arena, " ", parts.items);
                if (self.lex.phrase(key)) |index| {
                    const entry = &self.lex.entries[index];
                    try self.lexiconConcept(entry);
                    return n;
                }
            }
        }
        return 0;
    }
};

fn isTurkish(lex: *const Lexicon, tokens: []const Token) bool {
    var tr: usize = 0;
    var en: usize = 0;
    for (tokens) |t| {
        if (t.kind != .word) continue;
        if (!std.mem.eql(u8, t.folded, t.text) and !std.ascii.eqlIgnoreCase(t.folded, t.text)) tr += 2;
        if (lex.analyze(t.folded)) |a| {
            if (a.info.stop or a.info.entry != lexicon_mod.none) tr += 1;
        }
        if (lex.isEnStop(t.folded)) en += 1;
    }
    return tr > en;
}

pub fn build(arena: Allocator, lex: *const Lexicon, question: []const u8, vocab: ?Vocabulary, options: Options) !Query {
    const tokens = try tokenize(arena, lex, question);
    var b: Builder = .{ .arena = arena, .lex = lex, .vocab = vocab, .options = options };
    const turkish = isTurkish(lex, tokens);
    var i: usize = 0;
    while (i < tokens.len) {
        const t = tokens[i];
        switch (t.kind) {
            .identifier => try b.identifier(t, .identifier, weight_whole),
            .path => {
                const dot = std.mem.lastIndexOfScalar(u8, t.text, '.');
                const slash = std.mem.lastIndexOfAny(u8, t.text, "/\\") orelse 0;
                var stripped = t;
                if (dot) |d| if (d > slash and lex.hasPathExtension(t.text)) {
                    stripped.text = t.text[0..d];
                };
                try b.identifier(stripped, .path, weight_path_whole);
            },
            .number => {
                const owned = try arena.dupe(u8, t.text);
                try b.add(try arena.dupe([]const u8, &.{owned}), t.text, .number, weight_number);
            },
            .word => {
                if (turkish) {
                    const used = try b.phraseAt(tokens, i);
                    if (used != 0) {
                        i += used;
                        continue;
                    }
                    try b.turkishWord(t);
                } else {
                    try b.englishWord(t.folded, t.text);
                }
            },
        }
        i += 1;
    }
    return .{ .tokens = tokens, .concepts = b.concepts.items, .turkish = turkish };
}

const testing = std.testing;

const Collect = struct {
    list: std.ArrayList([]const u8) = .empty,
    kinds: std.ArrayList(PieceKind) = .empty,
    arena: Allocator,

    fn piece(self: *Collect, term: []const u8, kind: PieceKind, raw: []const u8) !void {
        _ = raw;
        try self.list.append(self.arena, try self.arena.dupe(u8, term));
        try self.kinds.append(self.arena, kind);
    }

    fn has(self: *const Collect, term: []const u8) bool {
        for (self.list.items) |t| if (std.mem.eql(u8, t, term)) return true;
        return false;
    }
};

const english_only = "suffix n s\nnoun cat = feline\nen s - 2\nen ss ss 2\nen ion - 3\nen e - 3\nen er - 3\nen or - 3\npathext ts js\nenstop the which who is a of\n";

test "question terms: an identifier is split on case, digits and separators, and its whole form is kept" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lex = try Lexicon.parse(testing.allocator, english_only);
    defer lex.deinit();
    var c: Collect = .{ .arena = arena };
    try eachPiece(lex, "handleNodeExecutionError", &c);
    try testing.expect(c.has("handl") and c.has("nod") and c.has("execut") and c.has("err"));
    try testing.expect(c.has("handlenodeexecutionerr"));
    c = .{ .arena = arena };
    try eachPiece(lex, "OAuth2", &c);
    try testing.expect(c.has("auth") and c.has("2") and c.has("oauth") and c.has("oauth2"));
    try testing.expect(!c.has("o"));
    c = .{ .arena = arena };
    try eachPiece(lex, "getIDs", &c);
    try testing.expect(c.has("get") and c.has("id"));
    c = .{ .arena = arena };
    try eachPiece(lex, "PLACEHOLDER_PREFIX", &c);
    try testing.expect(c.has("placehold") and c.has("prefix") and c.has("placeholderprefix"));
    c = .{ .arena = arena };
    try eachPiece(lex, "XMLHttpRequest", &c);
    try testing.expect(c.has("xml") and c.has("http") and c.has("request"));
}

test "question terms: quotes, paths, apostrophe suffixes and numbers become typed tokens" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lex = try Lexicon.parse(testing.allocator, english_only);
    defer lex.deinit();
    const tokens = try tokenize(arena, lex, "Where does WorkflowExecute's runNode read `retry count` from packages/core/a-b.ts and 404?");
    var kinds: std.ArrayList(Kind) = .empty;
    var texts: std.ArrayList([]const u8) = .empty;
    for (tokens) |t| {
        try kinds.append(arena, t.kind);
        try texts.append(arena, t.text);
    }
    try testing.expectEqualStrings("WorkflowExecute", texts.items[2]);
    try testing.expectEqual(Kind.identifier, kinds.items[2]);
    try testing.expectEqualStrings("runNode", texts.items[3]);
    try testing.expectEqualStrings("retry", texts.items[5]);
    try testing.expect(tokens[5].quoted and tokens[6].quoted);
    try testing.expectEqual(Kind.path, kinds.items[8]);
    try testing.expectEqualStrings("packages/core/a-b.ts", texts.items[8]);
    try testing.expectEqual(Kind.number, kinds.items[10]);
}

test "question terms: an english question keeps content words, drops stop words and weighs identifiers above words" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lex = try Lexicon.parse(testing.allocator, english_only);
    defer lex.deinit();
    const q = try build(arena, lex, "Which code in WorkflowExecute retries the connections?", null, .{});
    try testing.expect(!q.turkish);
    var whole: ?Concept = null;
    var connection: ?Concept = null;
    for (q.concepts) |c| {
        if (std.mem.eql(u8, c.alternatives[0], "workflowexecut")) whole = c;
        if (std.mem.eql(u8, c.alternatives[0], "connect")) connection = c;
        try testing.expect(!std.mem.eql(u8, c.alternatives[0], "the"));
    }
    try testing.expect(whole != null and connection != null);
    try testing.expect(whole.?.weight > connection.?.weight);
    try testing.expectEqualStrings("WorkflowExecute", whole.?.display);
}

fn canonical(lex: *const Lexicon, a: lexicon_mod.Analysis) []const u8 {
    if (lex.entryOf(a.info)) |entry| return entry.key;
    return a.stem;
}

test "question lexicon checks: every stem check maps its inflected word to the listed key" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lex = try Lexicon.parse(testing.allocator, lexicon_mod.default_text);
    defer lex.deinit();
    var checked: usize = 0;
    for (lex.checks) |check| {
        const c = switch (check) {
            .stem => |s| s,
            else => continue,
        };
        const word = try lex.fold(arena, c.word);
        const key = try lex.fold(arena, c.key);
        const a = lex.analyze(word) orelse {
            std.debug.print("no analysis for {s}\n", .{c.word});
            return error.TestUnexpectedResult;
        };
        if (!std.mem.eql(u8, canonical(lex, a), key)) {
            std.debug.print("{s}: expected {s}, got {s}\n", .{ c.word, key, canonical(lex, a) });
            return error.TestUnexpectedResult;
        }
        checked += 1;
    }
    try testing.expect(checked >= 30);
}

test "question lexicon checks: every term check translates its turkish phrase to the listed english term" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lex = try Lexicon.parse(testing.allocator, lexicon_mod.default_text);
    defer lex.deinit();
    var checked: usize = 0;
    for (lex.checks) |check| {
        const c = switch (check) {
            .term => |t| t,
            else => continue,
        };
        const q = try build(arena, lex, c.phrase, null, .{});
        var buf: [max_word]u8 = undefined;
        const want = lex.enStem(try lex.fold(arena, c.value), &buf);
        var found = false;
        for (q.concepts) |concept| {
            if (concept.origin != .lexicon) continue;
            for (concept.alternatives) |alt| {
                if (std.mem.eql(u8, alt, want)) found = true;
            }
        }
        if (!found) {
            std.debug.print("{s}: no lexicon concept with {s}\n", .{ c.phrase, want });
            return error.TestUnexpectedResult;
        }
        checked += 1;
    }
    try testing.expect(checked >= 15);
}

test "question lexicon checks: with stemming off an inflected word no longer reaches its lexicon entry" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lex = try Lexicon.parse(testing.allocator, lexicon_mod.default_text);
    defer lex.deinit();
    var lost: usize = 0;
    var total: usize = 0;
    for (lex.checks) |check| {
        const c = switch (check) {
            .term => |t| t,
            else => continue,
        };
        total += 1;
        const q = try build(arena, lex, c.phrase, null, .{ .stemming = false });
        const any = for (q.concepts) |concept| {
            if (concept.origin == .lexicon) break true;
        } else false;
        if (!any) lost += 1;
    }
    try testing.expect(total != 0 and lost * 2 > total);
}
