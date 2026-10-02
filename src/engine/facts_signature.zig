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
        for ([_][]const u8{ "/**", "/*", "//", "*" }) |marker| {
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

pub fn docOf(arena: Allocator, profile: *const Profile, source: []const u8, lines: facts_spine.Lines, node: ts.Node, span: facts.Span) ![]const u8 {
    const directives: []const []const u8 = if (profile.facts) |table| table.doc_directives else &.{};
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
        next_line = lines.lineAt(comment.startByte());
        if (!std.mem.startsWith(u8, text, "//")) break;
    }
    const comment = found orelse return "";
    return firstLine(arena, source[comment.startByte()..comment.endByte()], directives);
}
