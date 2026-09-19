const std = @import("std");
const Ref = @import("../engine/ref.zig").Ref;
const shadow = @import("shadow.zig");

pub const max_where_bytes = 512;
pub const max_exclusions = 16;

pub const Error = error{
    WhereEmpty,
    WhereTooLong,
    WhereAbsolute,
    WhereParentSegment,
    WhereInternal,
    WhereGlob,
    WhereMalformed,
    WhereExclusionEmpty,
    WhereExclusionGlob,
    WhereExclusionAbsolute,
    WhereExclusionParentSegment,
    WhereExclusionMalformed,
    WhereTooManyExclusions,
};

const exclusion_marker = " !";

pub const Base = union(enum) {
    file: []const u8,
    dir: []const u8,
    symbol: struct { file: []const u8, ref: []const u8 },

    pub fn path(self: Base) []const u8 {
        return switch (self) {
            .file, .dir => |p| p,
            .symbol => |s| s.file,
        };
    }

    pub fn coversFile(self: Base, rel: []const u8) bool {
        return switch (self) {
            .file => |p| samePath(p, rel),
            .symbol => |s| samePath(s.file, rel),
            .dir => |p| rel.len > p.len and samePath(p, rel[0..p.len]),
        };
    }
};

pub const Exclusion = union(enum) {
    dir_name: []const u8,
    dir_prefix: []const u8,
    suffix: []const u8,
    file: []const u8,

    pub fn matches(self: Exclusion, rel: []const u8) bool {
        return switch (self) {
            .file => |f| samePath(f, rel),
            .dir_prefix => |p| rel.len > p.len and samePath(p, rel[0..p.len]),
            .suffix => |s| rel.len > s.len and samePath(s, rel[rel.len - s.len ..]),
            .dir_name => |name| hasDirComponent(rel, name),
        };
    }
};

pub const Where = struct {
    base: Base,
    exclusions: []const u8 = "",

    pub fn path(self: Where) []const u8 {
        return self.base.path();
    }

    pub fn coversFile(self: Where, rel: []const u8) bool {
        return self.base.coversFile(rel) and !self.excludes(rel);
    }

    pub fn excludes(self: Where, rel: []const u8) bool {
        var it = self.iterator();
        while (it.next()) |exclusion| {
            if (exclusion.matches(rel)) return true;
        }
        return false;
    }

    pub fn iterator(self: Where) Iterator {
        return .{ .rest = self.exclusions };
    }

    pub fn coversSymbol(self: Where, rel: []const u8, ref: Ref) bool {
        if (!self.coversFile(rel)) return false;
        const text = switch (self.base) {
            .symbol => |s| s.ref,
            else => return true,
        };
        var buffer: [ref_buffer_bytes]u8 = undefined;
        var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
        const scoped = Ref.parse(fixed.allocator(), text) catch return false;
        return scoped.eql(ref);
    }
};

pub const Iterator = struct {
    rest: []const u8,

    pub fn next(self: *Iterator) ?Exclusion {
        if (self.rest.len == 0) return null;
        const body = self.rest[exclusion_marker.len..];
        const end = std.mem.indexOf(u8, body, exclusion_marker) orelse body.len;
        self.rest = body[end..];
        return classify(body[0..end]);
    }
};

const ref_buffer_bytes = (max_where_bytes + 1) * @sizeOf([]const u8);

pub fn parse(text: []const u8) Error!Where {
    if (text.len > max_where_bytes) return error.WhereTooLong;
    const split = std.mem.indexOf(u8, text, exclusion_marker) orelse text.len;
    const base = try parseBase(text[0..split]);
    const exclusions = text[split..];
    var rest = exclusions;
    var count: usize = 0;
    while (rest.len != 0) {
        const body = rest[exclusion_marker.len..];
        const end = std.mem.indexOf(u8, body, exclusion_marker) orelse body.len;
        count += 1;
        if (count > max_exclusions) return error.WhereTooManyExclusions;
        try validateExclusion(body[0..end]);
        rest = body[end..];
    }
    return .{ .base = base, .exclusions = exclusions };
}

fn parseBase(text: []const u8) Error!Base {
    if (text.len == 0) return error.WhereEmpty;
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

fn validateExclusion(text: []const u8) Error!void {
    if (text.len == 0) return error.WhereExclusionEmpty;
    if (!std.unicode.utf8ValidateSlice(text)) return error.WhereExclusionMalformed;
    if (text[0] == '/' or text[0] == '\\' or std.mem.indexOfScalar(u8, text, ':') != null) return error.WhereExclusionAbsolute;
    if (std.mem.indexOfAny(u8, text, "?[]{}") != null) return error.WhereExclusionGlob;
    if (std.mem.indexOfScalar(u8, text, '#') != null) return error.WhereExclusionMalformed;
    if (std.mem.indexOfAny(u8, text, " \t") != null) return error.WhereExclusionMalformed;
    if (std.mem.indexOfScalar(u8, text, '*')) |star| {
        if (star != 0 or std.mem.indexOfScalarPos(u8, text, 1, '*') != null) return error.WhereExclusionGlob;
        const suffix = text[1..];
        if (suffix.len == 0 or std.mem.indexOfAny(u8, suffix, "/\\") != null) return error.WhereExclusionMalformed;
        if (std.mem.eql(u8, suffix, "..")) return error.WhereExclusionParentSegment;
        return;
    }
    validatePath(text) catch |err| return switch (err) {
        error.WhereParentSegment => error.WhereExclusionParentSegment,
        else => error.WhereExclusionMalformed,
    };
}

fn classify(text: []const u8) Exclusion {
    if (text[0] == '*') return .{ .suffix = text[1..] };
    if (text[text.len - 1] != '/') return .{ .file = text };
    const name = text[0 .. text.len - 1];
    if (std.mem.indexOfScalar(u8, name, '/') == null) return .{ .dir_name = name };
    return .{ .dir_prefix = text };
}

fn hasDirComponent(rel: []const u8, name: []const u8) bool {
    var start: usize = 0;
    var i: usize = 0;
    while (i < rel.len) : (i += 1) {
        if (!isSeparator(rel[i])) continue;
        if (samePath(rel[start..i], name)) return true;
        start = i + 1;
    }
    return false;
}

fn isSeparator(c: u8) bool {
    return c == '/' or c == '\\';
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
    try testing.expectEqualStrings("src/queue.js", (try parse("src/queue.js")).base.file);
    try testing.expectEqualStrings("extension/", (try parse("extension/")).base.dir);
    const s = (try parse("src/x.js#filterHealthy")).base.symbol;
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

test "a where without exclusions parses and covers exactly as before" {
    const dir = try parse("src/");
    try testing.expectEqualStrings("", dir.exclusions);
    try testing.expect(dir.coversFile("src/a/__tests__/x.ts"));
    try testing.expect(dir.coversFile("src/x.test.ts"));
}

test "exclusions are split off the scope and each keeps its form" {
    const w = try parse("packages/ !*.test.ts !__fixtures__/ !packages/gen/ !packages/a/b.ts");
    try testing.expectEqualStrings("packages/", w.base.dir);
    var it = w.iterator();
    try testing.expectEqualStrings(".test.ts", it.next().?.suffix);
    try testing.expectEqualStrings("__fixtures__", it.next().?.dir_name);
    try testing.expectEqualStrings("packages/gen/", it.next().?.dir_prefix);
    try testing.expectEqualStrings("packages/a/b.ts", it.next().?.file);
    try testing.expect(it.next() == null);
}

test "a directory name exclusion matches that component anywhere in the path" {
    const w = try parse("src/ !__tests__/");
    try testing.expect(!w.coversFile("src/a/__tests__/x.ts"));
    try testing.expect(!w.coversFile("src/b/c/__tests__/y.ts"));
    try testing.expect(!w.coversFile("src/__tests__/z.ts"));
    try testing.expect(!w.coversFile("src\\d\\__TESTS__\\z.ts"));
    try testing.expect(w.coversFile("src/a/x.ts"));
    try testing.expect(w.coversFile("src/a/__tests__.ts"));
    try testing.expect(w.coversFile("src/a/my__tests__/x.ts"));
}

test "an exclusion with a slash is a prefix, not a segment" {
    const w = try parse("packages/ !packages/gen/");
    try testing.expect(!w.coversFile("packages/gen/a.ts"));
    try testing.expect(!w.coversFile("packages/gen/deep/a.ts"));
    try testing.expect(w.coversFile("packages/core/gen/a.ts"));
    try testing.expect(w.coversFile("packages/generated/a.ts"));
}

test "a suffix exclusion matches the end of the file name only" {
    const w = try parse("packages/ !*.test-d.ts");
    try testing.expect(!w.coversFile("packages/a/types.test-d.ts"));
    try testing.expect(w.coversFile("packages/a/types.ts"));
    try testing.expect(w.coversFile("packages/a/types.test.ts"));
    try testing.expect(w.coversFile("packages/a/types.test-d.ts.map"));
}

test "a file exclusion removes exactly that file" {
    const w = try parse("src/ !src/legacy.ts");
    try testing.expect(!w.coversFile("src/legacy.ts"));
    try testing.expect(w.coversFile("src/legacy.tsx"));
    try testing.expect(w.coversFile("src/a/src/legacy.ts"));
}

test "exclusions apply to the file part of a symbol where" {
    const w = try parse("src/x.test.ts#f !*.test.ts");
    try testing.expect(!w.coversSymbol("src/x.test.ts", .{ .name = "f" }));
    try testing.expect((try parse("src/x.ts#f !*.test.ts")).coversSymbol("src/x.ts", .{ .name = "f" }));
}

test "every rejected exclusion is refused under its own name" {
    try testing.expectError(error.WhereExclusionEmpty, parse("src/ !"));
    try testing.expectError(error.WhereExclusionEmpty, parse("src/ ! !a/"));
    try testing.expectError(error.WhereExclusionGlob, parse("src/ !**.ts"));
    try testing.expectError(error.WhereExclusionGlob, parse("src/ !*.test.*"));
    try testing.expectError(error.WhereExclusionGlob, parse("src/ !a*.ts"));
    try testing.expectError(error.WhereExclusionGlob, parse("src/ !src/*.ts"));
    try testing.expectError(error.WhereExclusionGlob, parse("src/ !x?.ts"));
    try testing.expectError(error.WhereExclusionGlob, parse("src/ ![ab].ts"));
    try testing.expectError(error.WhereExclusionParentSegment, parse("src/ !../x/"));
    try testing.expectError(error.WhereExclusionParentSegment, parse("src/ !a/../b.ts"));
    try testing.expectError(error.WhereExclusionAbsolute, parse("src/ !/etc/"));
    try testing.expectError(error.WhereExclusionAbsolute, parse("src/ !C:/x/"));
    try testing.expectError(error.WhereExclusionAbsolute, parse("src/ !\\\\server\\x"));
    try testing.expectError(error.WhereExclusionMalformed, parse("src/ !*"));
    try testing.expectError(error.WhereExclusionMalformed, parse("src/ !*.ts/"));
    try testing.expectError(error.WhereExclusionMalformed, parse("src/ !a//b/"));
    try testing.expectError(error.WhereExclusionMalformed, parse("src/ !a/b.ts#f"));
    try testing.expectError(error.WhereExclusionMalformed, parse("src/ ! a/"));
    try testing.expectError(error.WhereGlob, parse("src/* !a/"));
}

test "more exclusions than the limit are refused" {
    const at_limit = "src/" ++ " !a/" ** max_exclusions;
    _ = try parse(at_limit);
    try testing.expectError(error.WhereTooManyExclusions, parse(at_limit ++ " !b/"));
}
