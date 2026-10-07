const std = @import("std");

pub const named_bytes = 512;
pub const separator = '\n';

pub const Named = struct {
    buf: [named_bytes]u8 = undefined,
    len: usize = 0,
    shown: usize = 0,
    total: usize = 0,

    pub fn text(self: *const Named) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn paths(self: *const Named) std.mem.SplitIterator(u8, .scalar) {
        return std.mem.splitScalar(u8, self.text(), separator);
    }

    pub fn more(self: *const Named) usize {
        return self.total - self.shown;
    }
};

threadlocal var last: ?Named = null;

pub fn note(paths: []const []const u8, total: usize) void {
    var named: Named = .{ .total = @max(total, paths.len) };
    for (paths) |path| {
        const gap: usize = if (named.shown == 0) 0 else 1;
        if (named.len + gap + path.len > named.buf.len) break;
        if (gap != 0) {
            named.buf[named.len] = separator;
            named.len += 1;
        }
        for (path, named.buf[named.len..][0..path.len]) |byte, *slot| slot.* = if (byte == separator) '?' else byte;
        named.len += path.len;
        named.shown += 1;
    }
    last = named;
}

pub fn take() ?Named {
    const found = last;
    last = null;
    return found;
}

const testing = std.testing;

test "commit refusal: the paths a refusal names are kept in order and taken once" {
    _ = take();
    note(&.{ "src/a.ts", "src/A.ts" }, 2);
    const named = take().?;
    var it = named.paths();
    try testing.expectEqualStrings("src/a.ts", it.next().?);
    try testing.expectEqualStrings("src/A.ts", it.next().?);
    try testing.expect(it.next() == null);
    try testing.expectEqual(@as(usize, 0), named.more());
    try testing.expect(take() == null);
}

test "commit refusal: paths that do not fit are counted, never cut in the middle" {
    _ = take();
    const long = "d/" ++ "x" ** 300;
    note(&.{ long, long, "short" }, 9);
    const named = take().?;
    try testing.expectEqual(@as(usize, 1), named.shown);
    try testing.expectEqual(@as(usize, 8), named.more());
    try testing.expectEqualStrings(long, named.text());
}
