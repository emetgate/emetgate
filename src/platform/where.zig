const std = @import("std");
const Ref = @import("../engine/ref.zig").Ref;
const shadow = @import("shadow.zig");

pub const max_where_bytes = 512;

pub const Error = error{
    WhereEmpty,
    WhereTooLong,
    WhereAbsolute,
    WhereParentSegment,
    WhereInternal,
    WhereGlob,
    WhereMalformed,
};

pub const Where = union(enum) {
    file: []const u8,
    dir: []const u8,
    symbol: struct { file: []const u8, ref: []const u8 },

    pub fn path(self: Where) []const u8 {
        return switch (self) {
            .file, .dir => |p| p,
            .symbol => |s| s.file,
        };
    }

    pub fn coversFile(self: Where, rel: []const u8) bool {
        return switch (self) {
            .file => |p| samePath(p, rel),
            .symbol => |s| samePath(s.file, rel),
            .dir => |p| rel.len > p.len and samePath(p, rel[0..p.len]),
        };
    }

    pub fn coversSymbol(self: Where, rel: []const u8, ref: Ref) bool {
        if (!self.coversFile(rel)) return false;
        const text = switch (self) {
            .symbol => |s| s.ref,
            else => return true,
        };
        var buffer: [ref_buffer_bytes]u8 = undefined;
        var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
        const scoped = Ref.parse(fixed.allocator(), text) catch return false;
        return scoped.eql(ref);
    }
};

const ref_buffer_bytes = (max_where_bytes + 1) * @sizeOf([]const u8);

pub fn parse(text: []const u8) Error!Where {
    if (text.len == 0) return error.WhereEmpty;
    if (text.len > max_where_bytes) return error.WhereTooLong;
    if (std.mem.indexOfAny(u8, text, "*?[]{}") != null) return error.WhereGlob;
    if (text[0] == '/' or text[0] == '\\' or std.mem.indexOfScalar(u8, text, ':') != null) return error.WhereAbsolute;
    if (!std.unicode.utf8ValidateSlice(text)) return error.WhereMalformed;

    const hash = std.mem.indexOfScalar(u8, text, '#');
    const path_part = if (hash) |h| text[0..h] else text;
    try validatePath(path_part);

    if (hash) |h| {
        const ref_text = text[h + 1 ..];
        if (path_part[path_part.len - 1] == '/') return error.WhereMalformed;
        var buffer: [ref_buffer_bytes]u8 = undefined;
        var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
        _ = Ref.parse(fixed.allocator(), ref_text) catch return error.WhereMalformed;
        if (std.mem.indexOfScalar(u8, ref_text, '#') != null) return error.WhereMalformed;
        return .{ .symbol = .{ .file = path_part, .ref = ref_text } };
    }
    if (path_part[path_part.len - 1] == '/') return .{ .dir = path_part };
    return .{ .file = path_part };
}

pub fn validate(text: ?[]const u8) Error!void {
    if (text) |t| _ = try parse(t);
}

fn validatePath(path: []const u8) Error!void {
    if (path.len == 0) return error.WhereMalformed;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return error.WhereMalformed;
    const body = if (path[path.len - 1] == '/') path[0 .. path.len - 1] else path;
    var segments = std.mem.splitScalar(u8, body, '/');
    var first = true;
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, "..")) return error.WhereParentSegment;
        if (first and (std.ascii.eqlIgnoreCase(segment, ".git") or std.ascii.eqlIgnoreCase(segment, shadow.workspace_dir))) return error.WhereInternal;
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) return error.WhereMalformed;
        first = false;
    }
    shadow.validateRelative(body) catch return error.WhereMalformed;
}

fn samePath(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const nx = if (x == '\\') '/' else std.ascii.toLower(x);
        const ny = if (y == '\\') '/' else std.ascii.toLower(y);
        if (nx != ny) return false;
    }
    return true;
}

const testing = std.testing;

test "the three accepted forms parse to file, directory and symbol" {
    try testing.expectEqualStrings("src/queue.js", (try parse("src/queue.js")).file);
    try testing.expectEqualStrings("extension/", (try parse("extension/")).dir);
    const s = (try parse("src/x.js#filterHealthy")).symbol;
    try testing.expectEqualStrings("src/x.js", s.file);
    try testing.expectEqualStrings("filterHealthy", s.ref);
}

test "every rejected where is refused under its own name" {
    try testing.expectError(error.WhereEmpty, parse(""));
    try testing.expectError(error.WhereAbsolute, parse("/etc/passwd"));
    try testing.expectError(error.WhereAbsolute, parse("C:/Users/x.js"));
    try testing.expectError(error.WhereAbsolute, parse("\\\\server\\share\\x.js"));
    try testing.expectError(error.WhereParentSegment, parse("../outside.js"));
    try testing.expectError(error.WhereParentSegment, parse("src/../x.js"));
    try testing.expectError(error.WhereInternal, parse(".git/config"));
    try testing.expectError(error.WhereInternal, parse(".emetgate/"));
    try testing.expectError(error.WhereInternal, parse(".GIT/"));
    try testing.expectError(error.WhereGlob, parse("src/*.js"));
    try testing.expectError(error.WhereGlob, parse("src/**/x.js"));
    try testing.expectError(error.WhereGlob, parse("src/x?.js"));
    try testing.expectError(error.WhereMalformed, parse("src\\x.js"));
    try testing.expectError(error.WhereMalformed, parse("src//x.js"));
    try testing.expectError(error.WhereMalformed, parse("./x.js"));
    try testing.expectError(error.WhereMalformed, parse("src/CON.js"));
    try testing.expectError(error.WhereMalformed, parse("a~1/x.js"));
    try testing.expectError(error.WhereMalformed, parse("src/\xff.js"));
    try testing.expectError(error.WhereMalformed, parse("#f"));
    try testing.expectError(error.WhereMalformed, parse("src/#f"));
    try testing.expectError(error.WhereMalformed, parse("src/x.js#"));
    try testing.expectError(error.WhereMalformed, parse("src/x.js#a#b"));
    try testing.expectError(error.WhereTooLong, parse("a" ** (max_where_bytes + 1)));
}

test "a file where covers only that file and a directory where covers what is under it" {
    const file = try parse("src/queue.js");
    try testing.expect(file.coversFile("src/queue.js"));
    try testing.expect(file.coversFile("src\\queue.js"));
    try testing.expect(!file.coversFile("src/queue.jsx"));
    try testing.expect(!file.coversFile("lib/src/queue.js"));
    const dir = try parse("extension/");
    try testing.expect(dir.coversFile("extension/content.js"));
    try testing.expect(dir.coversFile("extension\\deep\\a.js"));
    try testing.expect(!dir.coversFile("extensions/a.js"));
    try testing.expect(!dir.coversFile("src/extension/a.js"));
}

test "a symbol where covers only proposals to that symbol" {
    const scoped = try parse("src/x.js#f");
    try testing.expect(scoped.coversSymbol("src/x.js", .{ .name = "f" }));
    try testing.expect(!scoped.coversSymbol("src/x.js", .{ .name = "g" }));
    try testing.expect(!scoped.coversSymbol("src/y.js", .{ .name = "f" }));
    try testing.expect((try parse("src/x.js")).coversSymbol("src/x.js", .{ .name = "g" }));
}
