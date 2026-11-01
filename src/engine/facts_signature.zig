const std = @import("std");
const ts = @import("tree_sitter.zig");
const facts = @import("facts.zig");
const facts_spine = @import("facts_spine.zig");
const Profile = @import("lang/profile.zig").Profile;

const Allocator = std.mem.Allocator;
const none = facts.none;

pub const max_signature_chars: usize = 200;
pub const max_doc_chars: usize = 160;

fn blank(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn collapse(arena: Allocator, text: []const u8, limit: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var space = false;
    var cut = false;
    for (text) |c| {
        if (blank(c)) {
            space = out.items.len != 0;
            continue;
        }
        if (out.items.len >= limit) {
            cut = true;
            break;
        }
        if (space) try out.append(arena, ' ');
        space = false;
        try out.append(arena, c);
    }
    var end = out.items.len;
    while (end > 0 and !std.unicode.utf8ValidateSlice(out.items[0..end])) end -= 1;
    out.items.len = end;
    if (cut) try out.appendSlice(arena, "...");
    return out.items;
}

pub fn signatureOf(arena: Allocator, source: []const u8, span: facts.Span, body_start: u32) ![]const u8 {
    const start = span.start;
    var end = span.end;
    if (body_start != none and body_start > start and body_start <= span.end) {
        end = body_start;
    } else if (std.mem.indexOfScalarPos(u8, source[0..span.end], start, '\n')) |newline| {
        end = @intCast(newline);
    }
    return collapse(arena, source[start..end], max_signature_chars);
}

fn directive(line: []const u8, directives: []const []const u8) bool {
    for (directives) |d| {
        if (std.mem.startsWith(u8, line, d)) return true;
    }
    return false;
}

fn firstLine(arena: Allocator, text: []const u8, directives: []const []const u8) ![]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.endsWith(u8, line, "*/")) line = line[0 .. line.len - 2];
        for ([_][]const u8{ "/**", "/*", "//", "*", "#" }) |marker| {
            if (std.mem.startsWith(u8, line, marker)) {
                line = line[marker.len..];
                break;
            }
        }
        line = std.mem.trim(u8, line, " \t*/");
        if (line.len == 0 or line[0] == '@' or directive(line, directives)) continue;
        return collapse(arena, line, max_doc_chars);
    }
    return "";
}

fn isXmlDoc(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "///") or std.mem.startsWith(u8, text, "/**");
}

fn docstringOf(arena: Allocator, source: []const u8, node: ts.Node, directives: []const []const u8) !?[]const u8 {
    const body = node.childByField("body") orelse return null;
    const string = body.namedChild(0) orelse return null;
    if (!std.mem.eql(u8, string.kind(), "string")) return null;
    const text = try firstLine(arena, stringContent(source[string.startByte()..string.endByte()]), directives);
    return if (text.len == 0) null else text;
}

fn stringContent(text: []const u8) []const u8 {
    var start: usize = 0;
    while (start < text.len and std.ascii.isAlphabetic(text[start])) start += 1;
    const rest = text[start..];
    for ([_][]const u8{ "\"\"\"", "'''", "\"", "'" }) |quote| {
        if (!std.mem.startsWith(u8, rest, quote)) continue;
        const inner = rest[quote.len..];
        return if (std.mem.endsWith(u8, inner, quote)) inner[0 .. inner.len - quote.len] else inner;
    }
    return rest;
}

fn xmlDoc(arena: Allocator, source: []const u8, run: []const ts.Node) ![]const u8 {
    var joined: std.ArrayList(u8) = .empty;
    for (run) |comment| {
        var raw = std.mem.splitScalar(u8, source[comment.startByte()..comment.endByte()], '\n');
        while (raw.next()) |piece| {
            var line = std.mem.trim(u8, piece, " \t\r");
            if (std.mem.endsWith(u8, line, "*/")) line = line[0 .. line.len - 2];
            for ([_][]const u8{ "///", "/**", "*" }) |marker| {
                if (std.mem.startsWith(u8, line, marker)) {
                    line = line[marker.len..];
                    break;
                }
            }
            try joined.appendSlice(arena, line);
            try joined.append(arena, '\n');
        }
    }
    const plain = try xmlText(arena, summaryOf(joined.items));
    var rows = std.mem.splitScalar(u8, plain, '\n');
    while (rows.next()) |row| {
        const line = std.mem.trim(u8, row, " \t\r");
        if (line.len != 0) return collapse(arena, line, max_doc_chars);
    }
    return "";
}

fn summaryOf(text: []const u8) []const u8 {
    const open = "<summary>";
    const start = std.mem.indexOf(u8, text, open) orelse return text;
    const inner = text[start + open.len..];
    return inner[0 .. std.mem.indexOf(u8, inner, "</summary>") orelse inner.len];
}

fn xmlText(arena: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '<') {
            const close = std.mem.indexOfScalarPos(u8, text, i, '>') orelse break;
            if (tagName(text[i + 1 .. close])) |name| try out.appendSlice(arena, name);
            i = close + 1;
            continue;
        }
        if (text[i] == '&') if (entityAt(text[i..])) |entity| {
            try out.append(arena, entity.byte);
            i += entity.len;
            continue;
        };
        try out.append(arena, text[i]);
        i += 1;
    }
    return out.items;
}

fn tagName(tag: []const u8) ?[]const u8 {
    for ([_][]const u8{ "cref", "name", "langword" }) |attribute| {
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, tag, at, attribute)) |found| : (at = found + attribute.len) {
            const value = tag[found + attribute.len..];
            if (value.len < 2 or value[0] != '=' or (value[1] != '"' and value[1] != '\'')) continue;
            const end = std.mem.indexOfScalarPos(u8, value, 2, value[1]) orelse continue;
            const raw = value[2..end];
            if (raw.len > 2 and raw[1] == ':') return raw[2..];
            return raw;
        }
    }
    return null;
}

const Entity = struct { byte: u8, len: usize };

fn entityAt(text: []const u8) ?Entity {
    for ([_]struct { []const u8, u8 }{ .{ "&lt;", '<' }, .{ "&gt;", '>' }, .{ "&amp;", '&' }, .{ "&quot;", '"' }, .{ "&apos;", '\'' } }) |entry| {
        if (std.mem.startsWith(u8, text, entry[0])) return .{ .byte = entry[1], .len = entry[0].len };
    }
    return null;
}

pub fn docOf(arena: Allocator, profile: *const Profile, source: []const u8, lines: facts_spine.Lines, node: ts.Node, span: facts.Span) ![]const u8 {
    const directives: []const []const u8 = if (profile.facts) |table| table.doc_directives else &.{};
    const docstrings = if (profile.facts) |table| table.docstrings else false;
    const xml = if (profile.facts) |table| table.xml_docs else false;
    if (docstrings) if (try docstringOf(arena, source, node, directives)) |text| return text;
    var run: std.ArrayList(ts.Node) = .empty;
    var anchor = node;
    while (anchor.parent()) |up| {
        if (up.startByte() < span.start or up.endByte() > span.end) break;
        anchor = up;
    }
    var next_line = lines.lineAt(anchor.startByte());
    var found: ?ts.Node = null;
    var previous = anchor.prevNamedSibling();
    while (previous) |comment| : (previous = comment.prevNamedSibling()) {
        if (std.mem.eql(u8, comment.kind(), profile.decorator)) {
            next_line = lines.lineAt(comment.startByte());
            continue;
        }
        if (!profile.isComment(comment.kind())) break;
        if (lines.lineAt(comment.endByte() -| 1) + 1 < next_line) break;
        const text = source[comment.startByte()..comment.endByte()];
        found = comment;
        if (xml) try run.insert(arena, 0, comment);
        next_line = lines.lineAt(comment.startByte());
        if (!std.mem.startsWith(u8, text, "//")) break;
    }
    const comment = found orelse return "";
    if (xml and isXmlDoc(source[comment.startByte()..comment.endByte()])) return xmlDoc(arena, source, run.items);
    return firstLine(arena, source[comment.startByte()..comment.endByte()], directives);
}
