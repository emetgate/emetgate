const std = @import("std");
const rule_catalog = @import("rule_catalog.zig");

const Writer = std.Io.Writer;

pub const max_prompt_bytes = 600;
pub const event_name = "UserPromptSubmit";

pub const Suggestion = union(enum) {
    any_check,
    pick: struct { num: u8, path: ?[]const u8 = null },
    forbid: []const u8,
    forbid_import: []const u8,
};

const max_tokens = max_prompt_bytes;
const Tokens = struct {
    items: [max_tokens][]const u8 = undefined,
    len: usize = 0,

    fn of(clause: []const u8) Tokens {
        var tokens: Tokens = .{};
        var it = std.mem.tokenizeAny(u8, clause, " \t\r\n,()\"`!?;");
        while (it.next()) |raw| {
            const word = std.mem.trim(u8, raw, ".:'");
            if (word.len == 0 or tokens.len == max_tokens) continue;
            tokens.items[tokens.len] = word;
            tokens.len += 1;
        }
        return tokens;
    }

    fn slice(self: *const Tokens) []const []const u8 {
        return self.items[0..self.len];
    }
};

const english_cues = [_][]const []const u8{
    &.{ "from", "now", "on" },
    &.{ "going", "forward" },
    &.{ "don't", "ever" },
    &.{ "don\u{2019}t", "ever" },
    &.{ "dont", "ever" },
    &.{ "do", "not", "ever" },
    &.{"never"},
    &.{"always"},
};

const english_lead = [_][]const u8{ "please", "and", "but", "also", "so", "ok", "okay", "just" };
const english_filler = [_][]const u8{ "please", "you", "we", "should", "must" };
const english_negations = [_][]const []const u8{
    &.{ "do", "not" }, &.{"don't"}, &.{"don\u{2019}t"}, &.{"dont"}, &.{"never"}, &.{"always"},
};

const english_verbs = [_][]const u8{
    "add",      "answer",  "ask",     "be",      "call",    "change",   "check",    "comment",
    "commit",   "create",  "delete",  "depend",  "disable", "edit",     "emit",     "enable",
    "export",   "format",  "generate", "hardcode", "ignore", "import",   "include",  "install",
    "introduce", "keep",   "leave",   "log",     "make",    "merge",    "mock",     "modify",
    "name",     "prefer",  "print",   "push",    "put",     "rebase",   "refactor", "remove",
    "rename",   "reply",   "respond", "return",  "run",     "send",     "skip",     "speak",
    "store",    "test",    "throw",   "touch",   "update",  "use",      "write",    "wrap",
};

const turkish_cues = [_][]const []const u8{
    &.{ "bundan", "sonra" },
    &.{ "artık", "hiç" },
    &.{ "hiçbir", "zaman" },
    &.{ "her", "zaman" },
    &.{"asla"},
    &.{"daima"},
};

const turkish_lasting = [_][]const u8{ "hep", "hiç", "artık", "asla", "daima" };

const turkish_verbs = [_][]const u8{
    "kullan", "ekle",      "yaz",    "yap",     "sil",      "koy",    "çalıştır", "değiştir",
    "dokun",  "ver",       "tut",    "oku",     "kaldır",   "gönder", "sor",      "et",
    "ol",     "bırak",     "uygula", "düzelt",  "oluştur",  "yanıtla", "cevapla", "konuş",
    "kullanın", "yazın",   "yapın",  "ekleyin", "çalıştırın", "silin", "koyun",   "edin",
};

const turkish_negative_endings = [_][]const u8{
    "mamalısınız", "memelisiniz", "mamalısın", "memelisin", "mamalı", "memeli",
    "mayınız",     "meyiniz",     "mayın",     "meyin",     "masın",  "mesin",
    "ma",          "me",
};

const turkish_positive_endings = [_][]const u8{
    "malısınız", "melisiniz", "malısın", "melisin", "malı", "meli", "yınız", "yiniz", "yın", "yin", "yun", "yün",
};

const not_verbs = [_][]const u8{
    "ama",    "tema",  "şema",  "firma",  "forma", "karma",   "drama",   "koma",   "plazma", "panorama",
    "readme", "name",  "time",  "theme",  "frame", "home",    "some",    "same",   "come",   "become",
    "game",   "scheme", "runtime", "lame", "acme",  "prime",
};

const question_words = [_][]const u8{
    "mı",    "mi",    "mu",    "mü",    "mısın", "misin", "musun", "müsün", "mıyım", "miyim",
    "muyum", "müyüm", "mıdır", "midir", "mudur", "müdür", "mıyız", "miyiz", "muyuz", "müyüz",
};

const folder_words = [_][]const u8{ "folder", "directory", "dir" };
const folder_stems = [_][]const u8{ "klasör", "dizin" };
const change_words = [_][]const u8{ "touch", "edit", "modify", "change", "dokunma", "değiştirme", "elleme", "düzenleme" };

const Found = struct { clause: []const u8, negative: bool };

pub fn detect(prompt: []const u8) ?Suggestion {
    const found = lasting(prompt) orelse return null;
    return suggest(found.clause, found.negative);
}

fn lasting(prompt: []const u8) ?Found {
    const text = std.mem.trim(u8, prompt, " \t\r\n");
    if (text.len == 0 or text.len > max_prompt_bytes) return null;
    if (text[0] == '/') return null;
    if (std.mem.indexOfScalar(u8, text, '?') != null) return null;
    const all = Tokens.of(text);
    for (all.slice()) |word| if (inList(&question_words, word)) return null;

    var start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        const at_end = i == text.len;
        if (!at_end and !endsClause(text, i)) continue;
        const clause = text[start..i];
        start = i + 1;
        const tokens = Tokens.of(clause);
        if (english(tokens.slice())) |negative| return .{ .clause = clause, .negative = negative };
        if (turkish(tokens.slice())) |negative| return .{ .clause = clause, .negative = negative };
    }
    return null;
}

fn endsClause(text: []const u8, i: usize) bool {
    return switch (text[i]) {
        '\n', '\r', ';', '!' => true,
        '.' => i + 1 == text.len or std.ascii.isWhitespace(text[i + 1]),
        else => false,
    };
}

fn english(words: []const []const u8) ?bool {
    var at: usize = 0;
    while (at < words.len and inList(&english_lead, words[at])) at += 1;
    for (english_cues) |cue| {
        if (!startsWith(words[at..], cue)) continue;
        var next = at + cue.len;
        const opener = std.mem.eql(u8, cue[0], "from") or std.mem.eql(u8, cue[0], "going");
        var negative = !opener and !std.mem.eql(u8, cue[0], "always");
        while (next < words.len and inList(&english_filler, words[next])) next += 1;
        if (opener) for (english_negations) |neg| {
            if (!startsWith(words[next..], neg)) continue;
            next += neg.len;
            negative = !std.mem.eql(u8, neg[0], "always");
            break;
        };
        if (next < words.len and inList(&english_verbs, words[next])) return negative;
        return null;
    }
    return null;
}

fn turkish(words: []const []const u8) ?bool {
    if (words.len < 2) return null;
    var cue_at: ?usize = null;
    var cue: []const []const u8 = undefined;
    for (0..words.len) |i| {
        for (turkish_cues) |candidate| if (startsWith(words[i..], candidate)) {
            cue_at = i;
            cue = candidate;
            break;
        };
        if (cue_at != null) break;
    }
    const at = cue_at orelse return null;
    const after = at + cue.len;
    if (after < words.len and (eqlFold(words[after], "olduğu") or eqlFold(words[after], "ki"))) return null;
    const last = words[words.len - 1];
    if (after >= words.len) return null;
    const negative_verb = negativeImperative(last);
    if (!negative_verb and !positiveImperative(last)) return null;
    if (std.mem.eql(u8, cue[0], "bundan") and !negative_verb) {
        var stated = false;
        for (words[after..], after..) |word, i| {
            stated = stated or inList(&turkish_lasting, word) or startsWith(words[i..], &.{ "her", "zaman" }) or startsWith(words[i..], &.{ "hiçbir", "zaman" });
        }
        if (!stated) return null;
    }
    const negative_cue = std.mem.eql(u8, cue[0], "asla") or std.mem.eql(u8, cue[0], "hiçbir") or std.mem.eql(u8, cue[0], "artık");
    return negative_cue or negative_verb;
}

fn negativeImperative(word: []const u8) bool {
    if (inList(&not_verbs, word)) return false;
    for (turkish_negative_endings) |ending| {
        if (word.len >= ending.len + 2 and endsWithFold(word, ending)) return true;
    }
    return false;
}

fn positiveImperative(word: []const u8) bool {
    if (inList(&turkish_verbs, word)) return true;
    for (turkish_positive_endings) |ending| {
        if (word.len >= ending.len + 2 and endsWithFold(word, ending)) return true;
    }
    return false;
}

const Named = struct { needle: []const u8, num: u8 };
const named = [_]Named{
    .{ .needle = "dangerouslysetinnerhtml", .num = 8 },
    .{ .needle = "innerhtml", .num = 7 },
    .{ .needle = "document.write", .num = 6 },
    .{ .needle = "console.writeline", .num = 16 },
    .{ .needle = "debug.writeline", .num = 17 },
    .{ .needle = "thread.sleep", .num = 18 },
    .{ .needle = "console.log", .num = 1 },
    .{ .needle = "@ts-ignore", .num = 10 },
    .{ .needle = "co-authored-by", .num = 26 },
    .{ .needle = "http://", .num = 25 },
};

const named_words = [_]Named{
    .{ .needle = "debugger", .num = 2 },
    .{ .needle = "pickle", .num = 15 },
    .{ .needle = "eval", .num = 23 },
    .{ .needle = "wip", .num = 28 },
    .{ .needle = "todo", .num = 22 },
    .{ .needle = "fixme", .num = 22 },
};

fn suggest(clause: []const u8, negative: bool) Suggestion {
    const tokens = Tokens.of(clause);
    const words = tokens.slice();
    if (std.ascii.indexOfIgnoreCase(clause, "conventional commit") != null and !negative) return .{ .pick = .{ .num = 29 } };
    if (negative) {
        for (named) |entry| if (std.ascii.indexOfIgnoreCase(clause, entry.needle) != null) return .{ .pick = .{ .num = entry.num } };
        for (named_words) |entry| for (words) |word| if (eqlFold(word, entry.needle) or (eqlFold(entry.needle, "eval") and std.ascii.startsWithIgnoreCase(word, "eval("))) return .{ .pick = .{ .num = entry.num } };
    }
    for (words) |word| if (std.ascii.startsWithIgnoreCase(word, "comment") or std.ascii.startsWithIgnoreCase(word, "yorum")) {
        return .{ .pick = .{ .num = if (negative) 19 else 20 } };
    };
    if (!negative) return .any_check;
    if (pathOf(words)) |path| for (words) |word| if (inList(&change_words, word)) return .{ .pick = .{ .num = 30, .path = path } };
    for (words, 0..) |word, i| if (eqlFold(word, "import") and i + 1 < words.len and plain(words[i + 1])) return .{ .forbid_import = words[i + 1] };
    if (quoted(clause)) |target| return .{ .forbid = target };
    return .any_check;
}

fn pathOf(words: []const []const u8) ?[]const u8 {
    for (words) |word| if (plain(word) and (std.mem.indexOfAny(u8, word, "/\\") != null)) return word;
    for (words, 0..) |word, i| {
        const folder = inList(&folder_words, word) or for (folder_stems) |stem| {
            if (std.mem.startsWith(u8, word, stem)) break true;
        } else false;
        if (folder and i > 0 and plain(words[i - 1]) and !inList(&.{ "the", "this", "that", "bu", "şu" }, words[i - 1])) return words[i - 1];
    }
    return null;
}

fn quoted(clause: []const u8) ?[]const u8 {
    const open = std.mem.indexOfScalar(u8, clause, '`') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, clause, open + 1, '`') orelse return null;
    const target = clause[open + 1 .. close];
    if (target.len == 0 or target.len > 60 or !plain(target)) return null;
    return target;
}

fn plain(word: []const u8) bool {
    if (word.len == 0) return false;
    for (word) |c| if (c < 0x21 or c > 0x7e or c == '"' or c == '\'' or c == '`') return false;
    return true;
}

fn startsWith(words: []const []const u8, cue: []const []const u8) bool {
    if (words.len < cue.len) return false;
    for (cue, words[0..cue.len]) |want, word| if (!eqlFold(word, want)) return false;
    return true;
}

fn inList(list: []const []const u8, word: []const u8) bool {
    for (list) |item| if (eqlFold(word, item)) return true;
    return false;
}

fn eqlFold(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn endsWithFold(word: []const u8, ending: []const u8) bool {
    return word.len >= ending.len and std.ascii.eqlIgnoreCase(word[word.len - ending.len ..], ending);
}

const lead = "emetgate: the user stated a lasting instruction, which compaction will lose. After handling the request, offer once to make it an enforced emetgate rule";

pub fn writeContext(suggestion: Suggestion, out: *Writer) Writer.Error!void {
    try out.writeAll(lead);
    switch (suggestion) {
        .pick => |pick| {
            const entry = rule_catalog.find(pick.num).?;
            try out.print(" the user types: /rule pick {d}", .{pick.num});
            if (pick.path) |path| try out.print(" {s}", .{path});
            try out.print(" (catalog rule {d}, {s}, check {s}).", .{ pick.num, entry.label, entry.check });
        },
        .forbid => |target| try out.print(" the user types: /rule add \"no {s}\" --check forbid:{s} --enforce", .{ target, target }),
        .forbid_import => |target| try out.print(" the user types: /rule add \"no import of {s}\" --check forbid_import:{s} --enforce", .{ target, target }),
        .any_check => try out.writeAll(
            "; if a check fits (forbid:<text>, forbid_import:<module>, added:no_comment, frozen with --in <path>, message:forbid_any_case:<text>), show the line to type: /rule add \"<rule>\" --check <check> --enforce",
        ),
    }
}

pub fn respond(prompt: []const u8, out: *Writer) Writer.Error!bool {
    const suggestion = detect(prompt) orelse return false;
    var buffer: [2048]u8 = undefined;
    var context: Writer = .fixed(&buffer);
    try writeContext(suggestion, &context);
    var js: std.json.Stringify = .{ .writer = out, .options = .{ .escape_unicode = true } };
    try js.beginObject();
    try js.objectField("hookSpecificOutput");
    try js.beginObject();
    try js.objectField("hookEventName");
    try js.write(event_name);
    try js.objectField("additionalContext");
    try js.write(context.buffered());
    try js.endObject();
    try js.endObject();
    try out.writeByte('\n');
    return true;
}
