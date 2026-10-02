const std = @import("std");

const Allocator = std.mem.Allocator;

pub const default_text = @embedFile("question_lexicon.txt");

pub const Intent = @import("evidence_request.zig").Intent;

pub const Class = enum(u2) { noun, verb, any };

pub const none: u32 = std.math.maxInt(u32);

pub const max_word = 64;

pub const suffix_cost: u8 = 2;
pub const single_cost: u8 = 3;

pub const Stem = struct {
    class: Class,
    entry: u32 = none,
    stop: bool = false,
};

pub const Entry = struct {
    key: []const u8,
    class: Class,
    values: []const []const u8,
};

pub const Fold = struct {
    from: []const u8,
    to: []const u8,
};

pub const Soften = struct {
    from: u8,
    to: u8,
};

pub const EnRule = struct {
    suffix: []const u8,
    replacement: []const u8,
    min_stem: usize,
};

pub const Alternative = struct {
    text: []const u8,
    prefix: bool,
};

pub const PatternToken = struct {
    alternatives: []const Alternative,
};

pub const Pattern = struct {
    intent: Intent,
    tokens: []const PatternToken,
};

pub const Check = union(enum) {
    stem: struct { word: []const u8, key: []const u8 },
    term: struct { phrase: []const u8, value: []const u8 },
    intent: struct { intent: Intent, sentence: []const u8 },
};

pub const Template = struct {
    language: []const u8,
    text: []const u8,
};

pub const Analysis = struct {
    stem: []const u8,
    info: Stem,
    cost: u8,
    consumed: usize,
};

pub const Error = Allocator.Error || error{InvalidLexicon};

pub const Lexicon = struct {
    arena: std.heap.ArenaAllocator,
    folds: []const Fold = &.{},
    soften: []const Soften = &.{},
    suffixes: std.StringHashMapUnmanaged(Class) = .empty,
    max_suffix: usize = 0,
    stems: std.StringHashMapUnmanaged(Stem) = .empty,
    phrases: std.StringHashMapUnmanaged(u32) = .empty,
    max_phrase: usize = 1,
    entries: []const Entry = &.{},
    compound: []const []const u8 = &.{},
    en_rules: []const EnRule = &.{},
    en_stop: std.StringHashMapUnmanaged(void) = .empty,
    test_paths: []const []const u8 = &.{},
    path_extensions: []const []const u8 = &.{},
    patterns: []const Pattern = &.{},
    checks: []const Check = &.{},
    templates: []const Template = &.{},

    pub fn parse(gpa: Allocator, text: []const u8) Error!*Lexicon {
        const self = try gpa.create(Lexicon);
        self.* = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
        errdefer self.deinit();
        try Loader.run(self, text);
        return self;
    }

    pub fn deinit(self: *Lexicon) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self);
    }

    pub fn fold(self: *const Lexicon, arena: Allocator, text: []const u8) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.ensureTotalCapacity(arena, text.len);
        var i: usize = 0;
        while (i < text.len) {
            const c = text[i];
            if (c < 0x80) {
                try out.append(arena, std.ascii.toLower(c));
                i += 1;
                continue;
            }
            const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
            const end = @min(text.len, i + len);
            const seq = text[i..end];
            const mapped = for (self.folds) |f| {
                if (std.mem.eql(u8, f.from, seq)) break f.to;
            } else seq;
            try out.appendSlice(arena, mapped);
            i = end;
        }
        return out.items;
    }

    pub fn stem(self: *const Lexicon, word: []const u8) ?Stem {
        return self.stems.get(word);
    }

    pub fn suffixChain(self: *const Lexicon, rest: []const u8, stem_class: Class) ?u8 {
        if (rest.len == 0) return 0;
        if (rest.len > max_word) return null;
        const unreachable_cost: u8 = std.math.maxInt(u8);
        var best: [max_word + 1]u8 = @splat(unreachable_cost);
        best[rest.len] = 0;
        var i: usize = rest.len;
        while (i > 0) {
            i -= 1;
            var len: usize = 1;
            while (len <= self.max_suffix and i + len <= rest.len) : (len += 1) {
                const class = self.suffixes.get(rest[i .. i + len]) orelse continue;
                if (i == 0 and !compatible(class, stem_class)) continue;
                const tail = best[i + len];
                if (tail == unreachable_cost) continue;
                const step: u8 = if (len == 1) single_cost else suffix_cost;
                best[i] = @min(best[i], tail +| step);
            }
        }
        return if (best[0] == unreachable_cost) null else best[0];
    }

    pub fn analyze(self: *const Lexicon, word: []const u8) ?Analysis {
        if (word.len < 2 or word.len > max_word) return null;
        var best: ?Analysis = null;
        var buf: [max_word]u8 = undefined;
        var p: usize = word.len;
        while (p >= 2) : (p -= 1) {
            const rest = word[p..];
            const plain = word[0..p];
            self.consider(plain, rest, p, &best);
            const last = plain[plain.len - 1];
            for (self.soften) |s| {
                if (s.from != last) continue;
                @memcpy(buf[0..p], plain);
                buf[p - 1] = s.to;
                self.consider(buf[0..p], rest, p, &best);
            }
        }
        return best;
    }

    fn consider(self: *const Lexicon, candidate: []const u8, rest: []const u8, consumed: usize, best: *?Analysis) void {
        const entry = self.stems.getEntry(candidate) orelse return;
        const info = entry.value_ptr.*;
        const cost = self.suffixChain(rest, info.class) orelse return;
        if (best.*) |b| {
            if (cost > b.cost) return;
            if (cost == b.cost and consumed <= b.consumed) return;
        }
        best.* = .{ .stem = entry.key_ptr.*, .info = info, .cost = cost, .consumed = consumed };
    }

    pub fn suffixedPrefix(self: *const Lexicon, word: []const u8, min_stem: usize, known: anytype) ?[]const u8 {
        if (word.len > max_word) return null;
        var best: ?[]const u8 = null;
        var best_cost: u8 = std.math.maxInt(u8);
        var p: usize = word.len;
        while (p >= min_stem) : (p -= 1) {
            const candidate = word[0..p];
            if (!known.has(candidate)) continue;
            const cost = self.suffixChain(word[p..], .any) orelse continue;
            if (cost < best_cost) {
                best = candidate;
                best_cost = cost;
            }
        }
        return best;
    }

    pub fn entryOf(self: *const Lexicon, info: Stem) ?*const Entry {
        if (info.entry == none) return null;
        return &self.entries[info.entry];
    }

    pub fn phrase(self: *const Lexicon, key: []const u8) ?u32 {
        return self.phrases.get(key);
    }

    pub fn enStem(self: *const Lexicon, word: []const u8, buf: []u8) []const u8 {
        if (word.len > buf.len) return word;
        @memcpy(buf[0..word.len], word);
        var len = word.len;
        var pass: usize = 0;
        while (pass < 3) : (pass += 1) {
            const current = buf[0..len];
            const rule = for (self.en_rules) |r| {
                if (current.len >= r.suffix.len + r.min_stem and std.mem.endsWith(u8, current, r.suffix)) break r;
            } else break;
            if (std.mem.eql(u8, rule.suffix, rule.replacement)) break;
            const base = len - rule.suffix.len;
            if (base + rule.replacement.len > buf.len) break;
            @memcpy(buf[base .. base + rule.replacement.len], rule.replacement);
            len = base + rule.replacement.len;
        }
        return buf[0..len];
    }

    pub fn isEnStop(self: *const Lexicon, word: []const u8) bool {
        return self.en_stop.contains(word);
    }

    pub fn isTestPath(self: *const Lexicon, path: []const u8) bool {
        var segments = std.mem.splitScalar(u8, path, '/');
        while (segments.next()) |segment| {
            for (self.test_paths) |marker| {
                if (marker.len != 0 and marker[0] == '.') {
                    if (std.mem.indexOf(u8, segment, marker) != null) return true;
                } else if (std.mem.eql(u8, segment, marker)) return true;
            }
        }
        return false;
    }

    pub fn hasPathExtension(self: *const Lexicon, token: []const u8) bool {
        const dot = std.mem.lastIndexOfScalar(u8, token, '.') orelse return false;
        if (dot == 0) return false;
        const ext = token[dot + 1 ..];
        for (self.path_extensions) |known| {
            if (std.ascii.eqlIgnoreCase(known, ext)) return true;
        }
        return false;
    }
};

fn compatible(suffix: Class, stem_class: Class) bool {
    return suffix == .any or stem_class == .any or suffix == stem_class;
}

const Variant = struct {
    words: []const []const u8,
    entry: u32,
};

const Loader = struct {
    lex: *Lexicon,
    arena: Allocator,
    folds: std.ArrayList(Fold) = .empty,
    soften: std.ArrayList(Soften) = .empty,
    entries: std.ArrayList(Entry) = .empty,
    multi: std.ArrayList(Variant) = .empty,
    compound: std.ArrayList([]const u8) = .empty,
    en_rules: std.ArrayList(EnRule) = .empty,
    test_paths: std.ArrayList([]const u8) = .empty,
    path_extensions: std.ArrayList([]const u8) = .empty,
    patterns: std.ArrayList(Pattern) = .empty,
    checks: std.ArrayList(Check) = .empty,
    templates: std.ArrayList(Template) = .empty,

    fn run(lex: *Lexicon, text: []const u8) Error!void {
        var loader: Loader = .{ .lex = lex, .arena = lex.arena.allocator() };
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (!std.mem.startsWith(u8, line, "fold ")) continue;
            var fields = std.mem.tokenizeAny(u8, line["fold ".len..], " \t");
            const from = fields.next() orelse return error.InvalidLexicon;
            const to = fields.next() orelse return error.InvalidLexicon;
            if (fields.next() != null) return error.InvalidLexicon;
            try loader.folds.append(loader.arena, .{ .from = try loader.arena.dupe(u8, from), .to = try loader.arena.dupe(u8, to) });
        }
        lex.folds = loader.folds.items;
        lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const text_line = std.mem.trim(u8, raw, " \t\r");
            if (text_line.len == 0) continue;
            const space = std.mem.indexOfScalar(u8, text_line, ' ') orelse return error.InvalidLexicon;
            try loader.entry(text_line[0..space], std.mem.trim(u8, text_line[space + 1 ..], " \t"));
        }
        try loader.finish();
    }

    fn folded(self: *Loader, text: []const u8) Allocator.Error![]const u8 {
        return self.lex.fold(self.arena, text);
    }

    fn entry(self: *Loader, kind: []const u8, rest: []const u8) Error!void {
        if (std.mem.eql(u8, kind, "fold")) return;
        if (std.mem.eql(u8, kind, "soften")) {
            var fields = std.mem.tokenizeAny(u8, rest, " \t");
            const from = try self.folded(fields.next() orelse return error.InvalidLexicon);
            const to = try self.folded(fields.next() orelse return error.InvalidLexicon);
            if (from.len != 1 or to.len != 1 or fields.next() != null) return error.InvalidLexicon;
            try self.soften.append(self.arena, .{ .from = from[0], .to = to[0] });
            return;
        }
        if (std.mem.eql(u8, kind, "suffix")) return self.suffixLine(rest);
        if (std.mem.eql(u8, kind, "stop")) return self.stopLine(rest, .noun);
        if (std.mem.eql(u8, kind, "stopverb")) return self.stopLine(rest, .verb);
        if (std.mem.eql(u8, kind, "noun")) return self.entryLine(rest, .noun);
        if (std.mem.eql(u8, kind, "verb")) return self.entryLine(rest, .verb);
        if (std.mem.eql(u8, kind, "compound")) return self.wordList(rest, &self.compound);
        if (std.mem.eql(u8, kind, "testpath")) return self.wordList(rest, &self.test_paths);
        if (std.mem.eql(u8, kind, "pathext")) return self.wordList(rest, &self.path_extensions);
        if (std.mem.eql(u8, kind, "en")) return self.enRule(rest);
        if (std.mem.eql(u8, kind, "enstop")) {
            var words = std.mem.tokenizeAny(u8, rest, " \t");
            while (words.next()) |w| try self.lex.en_stop.put(self.arena, try self.folded(w), {});
            return;
        }
        if (std.mem.eql(u8, kind, "intent")) return self.intentLine(rest);
        if (std.mem.eql(u8, kind, "check")) return self.checkLine(rest);
        if (std.mem.eql(u8, kind, "template")) {
            const gap = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.InvalidLexicon;
            const text = std.mem.trim(u8, rest[gap + 1 ..], " \t");
            if (std.mem.indexOf(u8, text, "{phrase}") == null) return error.InvalidLexicon;
            try self.templates.append(self.arena, .{ .language = try self.arena.dupe(u8, rest[0..gap]), .text = try self.arena.dupe(u8, text) });
            return;
        }
        return error.InvalidLexicon;
    }

    fn wordList(self: *Loader, rest: []const u8, list: *std.ArrayList([]const u8)) Error!void {
        var words = std.mem.tokenizeAny(u8, rest, " \t");
        while (words.next()) |w| try list.append(self.arena, try self.folded(w));
    }

    fn suffixLine(self: *Loader, rest: []const u8) Error!void {
        var fields = std.mem.tokenizeAny(u8, rest, " \t");
        const class_text = fields.next() orelse return error.InvalidLexicon;
        const class: Class = if (std.mem.eql(u8, class_text, "n")) .noun else if (std.mem.eql(u8, class_text, "v")) .verb else if (std.mem.eql(u8, class_text, "x")) .any else return error.InvalidLexicon;
        while (fields.next()) |w| {
            const s = try self.folded(w);
            const slot = try self.lex.suffixes.getOrPut(self.arena, s);
            slot.value_ptr.* = if (slot.found_existing and slot.value_ptr.* != class) .any else class;
            self.lex.max_suffix = @max(self.lex.max_suffix, s.len);
        }
    }

    fn stopLine(self: *Loader, rest: []const u8, class: Class) Error!void {
        var words = std.mem.tokenizeAny(u8, rest, " \t");
        while (words.next()) |w| {
            const s = try self.folded(w);
            const slot = try self.lex.stems.getOrPut(self.arena, s);
            if (slot.found_existing) {
                if (!slot.value_ptr.stop) return error.InvalidLexicon;
                if (slot.value_ptr.class != class) slot.value_ptr.class = .any;
                continue;
            }
            slot.value_ptr.* = .{ .class = class, .stop = true };
        }
    }

    fn entryLine(self: *Loader, rest: []const u8, class: Class) Error!void {
        const eq = std.mem.indexOfScalar(u8, rest, '=') orelse return error.InvalidLexicon;
        const keys = std.mem.trim(u8, rest[0..eq], " \t");
        const values_text = std.mem.trim(u8, rest[eq + 1 ..], " \t");
        var values: std.ArrayList([]const u8) = .empty;
        var value_parts = std.mem.tokenizeAny(u8, values_text, ", \t");
        while (value_parts.next()) |v| try values.append(self.arena, try self.folded(v));
        if (values.items.len == 0) return error.InvalidLexicon;
        const index: u32 = @intCast(self.entries.items.len);
        var first: ?[]const u8 = null;
        var variants = std.mem.splitScalar(u8, keys, '|');
        while (variants.next()) |variant_raw| {
            const variant = std.mem.trim(u8, variant_raw, " \t");
            var words: std.ArrayList([]const u8) = .empty;
            var parts = std.mem.tokenizeAny(u8, variant, " \t");
            while (parts.next()) |w| try words.append(self.arena, try self.folded(w));
            if (words.items.len == 0) return error.InvalidLexicon;
            const joined = try std.mem.join(self.arena, " ", words.items);
            if (first == null) first = joined;
            if (words.items.len == 1) {
                const slot = try self.lex.stems.getOrPut(self.arena, words.items[0]);
                if (slot.found_existing) return error.InvalidLexicon;
                slot.value_ptr.* = .{ .class = class, .entry = index };
            } else {
                try self.multi.append(self.arena, .{ .words = words.items, .entry = index });
            }
        }
        try self.entries.append(self.arena, .{ .key = first.?, .class = class, .values = values.items });
    }

    fn enRule(self: *Loader, rest: []const u8) Error!void {
        var fields = std.mem.tokenizeAny(u8, rest, " \t");
        const suffix = fields.next() orelse return error.InvalidLexicon;
        const replacement = fields.next() orelse return error.InvalidLexicon;
        const min_text = fields.next() orelse return error.InvalidLexicon;
        if (fields.next() != null) return error.InvalidLexicon;
        const min_stem = std.fmt.parseInt(usize, min_text, 10) catch return error.InvalidLexicon;
        try self.en_rules.append(self.arena, .{
            .suffix = try self.arena.dupe(u8, suffix),
            .replacement = if (std.mem.eql(u8, replacement, "-")) "" else try self.arena.dupe(u8, replacement),
            .min_stem = min_stem,
        });
    }

    fn intentOf(name: []const u8) Error!Intent {
        return std.meta.stringToEnum(Intent, name) orelse error.InvalidLexicon;
    }

    fn intentLine(self: *Loader, rest: []const u8) Error!void {
        var fields = std.mem.tokenizeAny(u8, rest, " \t");
        const intent = try intentOf(fields.next() orelse return error.InvalidLexicon);
        var tokens: std.ArrayList(PatternToken) = .empty;
        while (fields.next()) |w| {
            var alternatives: std.ArrayList(Alternative) = .empty;
            var options = std.mem.splitScalar(u8, w, '|');
            while (options.next()) |option| {
                const prefix = std.mem.endsWith(u8, option, "*");
                const word = if (prefix) option[0 .. option.len - 1] else option;
                if (word.len == 0) return error.InvalidLexicon;
                try alternatives.append(self.arena, .{ .text = try self.folded(word), .prefix = prefix });
            }
            try tokens.append(self.arena, .{ .alternatives = alternatives.items });
        }
        if (tokens.items.len == 0) return error.InvalidLexicon;
        try self.patterns.append(self.arena, .{ .intent = intent, .tokens = tokens.items });
    }

    fn checkLine(self: *Loader, rest: []const u8) Error!void {
        const space = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.InvalidLexicon;
        const kind = rest[0..space];
        const body = std.mem.trim(u8, rest[space + 1 ..], " \t");
        if (std.mem.eql(u8, kind, "stem")) {
            var fields = std.mem.tokenizeAny(u8, body, " \t");
            const word = fields.next() orelse return error.InvalidLexicon;
            const key = fields.next() orelse return error.InvalidLexicon;
            if (fields.next() != null) return error.InvalidLexicon;
            try self.checks.append(self.arena, .{ .stem = .{ .word = try self.arena.dupe(u8, word), .key = try self.arena.dupe(u8, key) } });
            return;
        }
        if (std.mem.eql(u8, kind, "term")) {
            const eq = std.mem.indexOfScalar(u8, body, '=') orelse return error.InvalidLexicon;
            try self.checks.append(self.arena, .{ .term = .{
                .phrase = try self.arena.dupe(u8, std.mem.trim(u8, body[0..eq], " \t")),
                .value = try self.arena.dupe(u8, std.mem.trim(u8, body[eq + 1 ..], " \t")),
            } });
            return;
        }
        if (std.mem.eql(u8, kind, "intent")) {
            const gap = std.mem.indexOfScalar(u8, body, ' ') orelse return error.InvalidLexicon;
            try self.checks.append(self.arena, .{ .intent = .{
                .intent = try intentOf(body[0..gap]),
                .sentence = try self.arena.dupe(u8, std.mem.trim(u8, body[gap + 1 ..], " \t")),
            } });
            return;
        }
        return error.InvalidLexicon;
    }

    fn reduceLast(self: *Loader, word: []const u8) Allocator.Error![]const u8 {
        for (self.compound.items) |marker| {
            if (word.len < marker.len + 3 or !std.mem.endsWith(u8, word, marker)) continue;
            const base = word[0 .. word.len - marker.len];
            if (self.lex.stems.contains(base) or (marker.len > 1 and marker[0] == 's')) return base;
            for (self.soften.items) |s| {
                if (base[base.len - 1] != s.from) continue;
                const softened = try self.arena.dupe(u8, base);
                softened[softened.len - 1] = s.to;
                if (self.lex.stems.contains(softened)) return softened;
            }
        }
        return word;
    }

    fn finish(self: *Loader) Error!void {
        const lex = self.lex;
        lex.soften = self.soften.items;
        lex.entries = self.entries.items;
        lex.compound = self.compound.items;
        lex.test_paths = self.test_paths.items;
        lex.path_extensions = self.path_extensions.items;
        std.mem.sort(EnRule, self.en_rules.items, {}, longerSuffix);
        lex.en_rules = self.en_rules.items;
        for (self.multi.items) |variant| {
            const words = try self.arena.dupe([]const u8, variant.words);
            const last = words.len - 1;
            words[last] = try self.reduceLast(words[last]);
            for (words) |w| {
                const slot = try lex.stems.getOrPut(self.arena, w);
                if (!slot.found_existing) slot.value_ptr.* = .{ .class = .noun };
            }
            const key = try std.mem.join(self.arena, " ", words);
            const slot = try lex.phrases.getOrPut(self.arena, key);
            if (slot.found_existing) return error.InvalidLexicon;
            slot.value_ptr.* = variant.entry;
            lex.max_phrase = @max(lex.max_phrase, words.len);
        }
        lex.patterns = self.patterns.items;
        lex.checks = self.checks.items;
        lex.templates = self.templates.items;
        if (lex.suffixes.count() == 0 or lex.entries.len == 0) return error.InvalidLexicon;
    }
};

fn longerSuffix(_: void, a: EnRule, b: EnRule) bool {
    if (a.suffix.len != b.suffix.len) return a.suffix.len > b.suffix.len;
    return std.mem.order(u8, a.suffix, b.suffix) == .lt;
}

const testing = std.testing;

test "question lexicon: the shipped lexicon parses and holds stems, phrases, rules and patterns" {
    const lex = try Lexicon.parse(testing.allocator, default_text);
    defer lex.deinit();
    try testing.expect(lex.entries.len >= 300);
    try testing.expect(lex.phrases.count() >= 20);
    try testing.expect(lex.patterns.len >= 20);
    try testing.expect(lex.en_rules.len >= 10);
    try testing.expect(lex.checks.len >= 40);
    try testing.expect(lex.templates.len >= 2);
}

test "question lexicon: a duplicate key, an unknown section and a rule without a minimum stem are refused" {
    try testing.expectError(error.InvalidLexicon, Lexicon.parse(testing.allocator, "suffix n s\nnoun cat = feline\nnoun cat = kitty\n"));
    try testing.expectError(error.InvalidLexicon, Lexicon.parse(testing.allocator, "suffix n s\nnoun cat = feline\nwhatever x\n"));
    try testing.expectError(error.InvalidLexicon, Lexicon.parse(testing.allocator, "suffix n s\nnoun cat = feline\nen s -\n"));
    try testing.expectError(error.InvalidLexicon, Lexicon.parse(testing.allocator, "suffix n s\nnoun cat feline\n"));
}

test "question lexicon: english rules strip the longest matching suffix and keep a protected ending" {
    const lex = try Lexicon.parse(testing.allocator, "suffix n s\nnoun cat = feline\nen s - 2\nen ss ss 2\nen ion - 3\nen e - 3\nen ing - 3\n");
    defer lex.deinit();
    var buf: [max_word]u8 = undefined;
    try testing.expectEqualStrings("connect", lex.enStem("connections", &buf));
    try testing.expectEqualStrings("process", lex.enStem("process", &buf));
    try testing.expectEqualStrings("execut", lex.enStem("executes", &buf));
    try testing.expectEqualStrings("execut", lex.enStem("executing", &buf));
    try testing.expectEqualStrings("id", lex.enStem("ids", &buf));
}

test "question lexicon: a suffix chain costs more for one-letter suffixes and its first suffix must suit the stem class" {
    const lex = try Lexicon.parse(testing.allocator, "suffix n lar de\nsuffix v yor\nsuffix x i\nnoun kitap = book\nverb oku = read\n");
    defer lex.deinit();
    try testing.expectEqual(@as(?u8, 2 * suffix_cost), lex.suffixChain("larde", .noun));
    try testing.expectEqual(@as(?u8, suffix_cost + single_cost), lex.suffixChain("lari", .noun));
    try testing.expectEqual(@as(?u8, null), lex.suffixChain("yor", .noun));
    try testing.expectEqual(@as(?u8, suffix_cost), lex.suffixChain("yor", .verb));
    try testing.expectEqual(@as(?u8, null), lex.suffixChain("larx", .noun));
    const a = lex.analyze("okuyor").?;
    try testing.expectEqualStrings("oku", a.stem);
    try testing.expectEqual(suffix_cost, a.cost);
}
