const std = @import("std");

pub const all = [_][]const u8{
    "emetgate_explore",
    "emetgate_evidence",
    "emetgate_symbols",
    "emetgate_skeleton",
    "emetgate_read_symbol",
    "emetgate_try",
    "emetgate_rename",
    "emetgate_move",
    "emetgate_move_file",
    "emetgate_read_file",
    "emetgate_list",
    "emetgate_search",
    "emetgate_find",
    "emetgate_scan",
    "emetgate_commit",
    "emetgate_git",
    "emetgate_git_write",
    "emetgate_run",
    "emetgate_edit",
    "emetgate_write",
    "emetgate_write_doc",
    "emetgate_mutate",
    "emetgate_try_batch",
};

pub const max_prefix = 96;
const stem = "emetgate_";

var prefix_buffer: [max_prefix]u8 = undefined;
var prefix_len: usize = 0;

pub fn validPrefix(text: []const u8) bool {
    if (text.len == 0 or text.len > max_prefix) return false;
    for (text) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    }
    return true;
}

pub fn setPrefix(text: []const u8) error{ToolPrefixInvalid}!void {
    if (text.len != 0 and !validPrefix(text)) return error.ToolPrefixInvalid;
    @memcpy(prefix_buffer[0..text.len], text);
    prefix_len = text.len;
}

pub fn prefix() []const u8 {
    return prefix_buffer[0..prefix_len];
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn known(name: []const u8) bool {
    for (all) |tool| {
        if (std.mem.eql(u8, tool, name)) return true;
    }
    return false;
}

fn nextName(prose: []const u8, from: usize) ?struct { start: usize, end: usize } {
    var at = from;
    while (std.mem.indexOfPos(u8, prose, at, stem)) |start| {
        var end = start + stem.len;
        while (end < prose.len and isIdent(prose[end])) end += 1;
        if ((start == 0 or !isIdent(prose[start - 1])) and known(prose[start..end])) return .{ .start = start, .end = end };
        at = end;
    }
    return null;
}

pub fn write(w: *std.Io.Writer, prose: []const u8) std.Io.Writer.Error!void {
    var done: usize = 0;
    while (nextName(prose, done)) |name| {
        try w.writeAll(prose[done..name.start]);
        try w.writeAll(prefix());
        try w.writeAll(prose[name.start..name.end]);
        done = name.end;
    }
    try w.writeAll(prose[done..]);
}

pub fn writeJsonChars(w: *std.Io.Writer, prose: []const u8) std.Io.Writer.Error!void {
    var done: usize = 0;
    while (nextName(prose, done)) |name| {
        try std.json.Stringify.encodeJsonStringChars(prose[done..name.start], .{}, w);
        try w.writeAll(prefix());
        try w.writeAll(prose[name.start..name.end]);
        done = name.end;
    }
    try std.json.Stringify.encodeJsonStringChars(prose[done..], .{}, w);
}

pub fn writeJson(js: *std.json.Stringify, prose: []const u8) std.Io.Writer.Error!void {
    try js.beginWriteRaw();
    try js.writer.writeByte('"');
    try writeJsonChars(js.writer, prose);
    try js.writer.writeByte('"');
    js.endWriteRaw();
}

const testing = std.testing;

fn qualified(prose: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try write(&out.writer, prose);
    return out.toOwnedSlice();
}

test "tool names: every known tool name is prefixed, the longest name wins and other words stay" {
    try setPrefix("mcp__emetgate__");
    defer setPrefix("") catch unreachable;
    const got = try qualified("edit with emetgate_try, several files with emetgate_try_batch; emetgate_region r1 and my_emetgate_try stay");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("edit with mcp__emetgate__emetgate_try, several files with mcp__emetgate__emetgate_try_batch; emetgate_region r1 and my_emetgate_try stay", got);
}

test "tool names: without a prefix the prose is written as it is" {
    const got = try qualified("read it with emetgate_read_symbol");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("read it with emetgate_read_symbol", got);
}

test "tool names: a name already written with the prefix is not prefixed twice" {
    try setPrefix("mcp__emetgate__");
    defer setPrefix("") catch unreachable;
    const got = try qualified("call mcp__emetgate__emetgate_run");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("call mcp__emetgate__emetgate_run", got);
}

test "tool names: a prefix with characters a tool name cannot hold is refused" {
    try testing.expectError(error.ToolPrefixInvalid, setPrefix("mcp emetgate"));
    try testing.expectError(error.ToolPrefixInvalid, setPrefix("x" ** (max_prefix + 1)));
    try testing.expectEqualStrings("", prefix());
}
