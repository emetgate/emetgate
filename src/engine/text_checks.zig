const std = @import("std");

const Allocator = std.mem.Allocator;

pub const prefix = "message:";

pub const Hit = struct { start: usize, end: usize };

pub const Error = error{ UnknownCheck, MissingCheckArgument, EmptyCheckArgument, UnexpectedCheckArgument };

const Kind = enum { forbid, forbid_any_case, require, require_any_case, max_lines, max_subject, max_line, conventional };

const Named = struct { name: []const u8, kind: Kind };

pub const registry = [_]Named{
    .{ .name = "forbid", .kind = .forbid },
    .{ .name = "forbid_any_case", .kind = .forbid_any_case },
    .{ .name = "require", .kind = .require },
    .{ .name = "require_any_case", .kind = .require_any_case },
    .{ .name = "max_lines", .kind = .max_lines },
    .{ .name = "max_subject", .kind = .max_subject },
    .{ .name = "max_line", .kind = .max_line },
    .{ .name = "conventional", .kind = .conventional },
};

/// The commit types Conventional Commits recognises for the subject line.
const conventional_types = [_][]const u8{ "feat", "fix", "docs", "style", "refactor", "perf", "test", "build", "ci", "chore", "revert" };

const Resolved = struct { kind: Kind, arg: []const u8, limit: usize = 0 };

pub fn of(spec: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, spec, prefix)) return null;
    return spec[prefix.len..];
}

fn takesNumber(kind: Kind) bool {
    return switch (kind) {
        .max_lines, .max_subject, .max_line => true,
        .forbid, .forbid_any_case, .require, .require_any_case, .conventional => false,
    };
}

fn takesArgument(kind: Kind) bool {
    return kind != .conventional;
}

fn resolve(inner: []const u8) Error!Resolved {
    const colon = std.mem.indexOfScalar(u8, inner, ':');
    const name = if (colon) |at| inner[0..at] else inner;
    const kind = for (registry) |entry| {
        if (std.mem.eql(u8, entry.name, name)) break entry.kind;
    } else return error.UnknownCheck;
    if (!takesArgument(kind)) {
        if (colon != null) return error.UnexpectedCheckArgument;
        return .{ .kind = kind, .arg = "" };
    }
    const arg = if (colon) |at| inner[at + 1 ..] else return error.MissingCheckArgument;
    if (arg.len == 0) return error.EmptyCheckArgument;
    if (!takesNumber(kind)) return .{ .kind = kind, .arg = arg };
    const limit = std.fmt.parseInt(usize, arg, 10) catch return error.UnexpectedCheckArgument;
    if (limit == 0) return error.UnexpectedCheckArgument;
    return .{ .kind = kind, .arg = arg, .limit = limit };
}

pub fn validate(inner: []const u8) Error!void {
    _ = try resolve(inner);
}

fn body(text: []const u8) []const u8 {
    return std.mem.trimEnd(u8, text, "\r\n");
}

fn lineEnd(text: []const u8, start: usize) usize {
    const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    if (end > start and text[end - 1] == '\r') return end - 1;
    return end;
}

fn afterCodepoints(line: []const u8, limit: usize) ?usize {
    var seen: usize = 0;
    for (line, 0..) |byte, i| {
        if (byte & 0xC0 == 0x80) continue;
        if (seen == limit) return i;
        seen += 1;
    }
    return null;
}

fn find(text: []const u8, needle: []const u8, from: usize, any_case: bool) ?usize {
    if (!any_case) return std.mem.indexOfPos(u8, text, from, needle);
    return std.ascii.indexOfIgnoreCasePos(text, from, needle);
}

pub fn run(gpa: Allocator, inner: []const u8, text: []const u8) (Error || Allocator.Error)![]Hit {
    const resolved = try resolve(inner);
    var hits: std.ArrayList(Hit) = .empty;
    errdefer hits.deinit(gpa);
    switch (resolved.kind) {
        .forbid, .forbid_any_case => {
            var from: usize = 0;
            while (find(text, resolved.arg, from, resolved.kind == .forbid_any_case)) |at| {
                try hits.append(gpa, .{ .start = at, .end = at + resolved.arg.len });
                from = at + resolved.arg.len;
            }
        },
        .require, .require_any_case => {
            if (find(text, resolved.arg, 0, resolved.kind == .require_any_case) == null) try hits.append(gpa, .{ .start = 0, .end = 0 });
        },
        .max_lines => {
            const kept = body(text);
            var line: usize = 1;
            var start: usize = 0;
            while (std.mem.indexOfScalarPos(u8, kept, start, '\n')) |nl| {
                line += 1;
                start = nl + 1;
                if (line > resolved.limit) {
                    try hits.append(gpa, .{ .start = start, .end = kept.len });
                    break;
                }
            }
        },
        .max_subject => {
            const end = lineEnd(text, 0);
            if (afterCodepoints(text[0..end], resolved.limit)) |over| try hits.append(gpa, .{ .start = over, .end = end });
        },
        .max_line => {
            const kept = body(text);
            var start: usize = 0;
            while (start <= kept.len) {
                const end = lineEnd(kept, start);
                if (afterCodepoints(kept[start..end], resolved.limit)) |over| try hits.append(gpa, .{ .start = start + over, .end = end });
                const nl = std.mem.indexOfScalarPos(u8, kept, start, '\n') orelse break;
                start = nl + 1;
            }
        },
        .conventional => {
            const end = lineEnd(text, 0);
            if (!isConventionalSubject(text[0..end])) try hits.append(gpa, .{ .start = 0, .end = end });
        },
    }
    return hits.toOwnedSlice(gpa);
}

// A Conventional Commits subject: `type(scope)?!?: description`, where type is one
// of the recognised set, an optional scope is any non-empty text in parentheses, an
// optional `!` marks a breaking change, and a non-empty description follows ": ".
fn isConventionalSubject(subject: []const u8) bool {
    var i: usize = 0;
    while (i < subject.len and std.ascii.isAlphabetic(subject[i])) i += 1;
    const kind = subject[0..i];
    const known = for (conventional_types) |t| {
        if (std.mem.eql(u8, t, kind)) break true;
    } else false;
    if (!known) return false;
    if (i < subject.len and subject[i] == '(') {
        const close = std.mem.indexOfScalarPos(u8, subject, i + 1, ')') orelse return false;
        if (close == i + 1) return false; // an empty scope "()" is not allowed
        i = close + 1;
    }
    if (i < subject.len and subject[i] == '!') i += 1;
    if (i + 1 >= subject.len or subject[i] != ':' or subject[i + 1] != ' ') return false;
    i += 2;
    return i < subject.len; // the description must not be empty
}

const testing = std.testing;

fn expectHits(inner: []const u8, text: []const u8, want: []const Hit) !void {
    const got = try run(testing.allocator, inner, text);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(Hit, want, got);
}

test "text checks: the message prefix marks a rule that judges a commit message" {
    try testing.expectEqualStrings("forbid:x", of("message:forbid:x").?);
    try testing.expectEqual(@as(?[]const u8, null), of("forbid:x"));
    try testing.expectEqual(@as(?[]const u8, null), of("added:message:forbid:x"));
}

test "text checks: an unknown name, a missing or empty argument and a bad number are refused" {
    try testing.expectError(error.UnknownCheck, validate("no_comment"));
    try testing.expectError(error.UnknownCheck, validate("cmd:echo"));
    try testing.expectError(error.MissingCheckArgument, validate("forbid"));
    try testing.expectError(error.EmptyCheckArgument, validate("require:"));
    try testing.expectError(error.UnexpectedCheckArgument, validate("max_lines:one"));
    try testing.expectError(error.UnexpectedCheckArgument, validate("max_subject:0"));
    for (registry) |entry| {
        if (!takesArgument(entry.kind)) continue;
        var buf: [64]u8 = undefined;
        try validate(try std.fmt.bufPrint(&buf, "{s}:1", .{entry.name}));
    }
}

test "text checks: conventional takes no argument and is refused one" {
    try validate("conventional");
    try testing.expectError(error.UnexpectedCheckArgument, validate("conventional:x"));
}

test "text checks: conventional accepts well-formed subjects and rejects the rest" {
    try expectHits("conventional", "feat: add thing", &.{});
    try expectHits("conventional", "fix(parser): handle x", &.{});
    try expectHits("conventional", "feat!: breaking change", &.{});
    try expectHits("conventional", "chore(ci)!: bump deps", &.{});
    try expectHits("conventional", "feat: ok\n\na longer body line", &.{});
    try expectHits("conventional", "added a thing", &.{.{ .start = 0, .end = 13 }});
    try expectHits("conventional", "feat add thing", &.{.{ .start = 0, .end = 14 }});
    try expectHits("conventional", "feat:no space", &.{.{ .start = 0, .end = 13 }});
    try expectHits("conventional", "feat: ", &.{.{ .start = 0, .end = 6 }});
    try expectHits("conventional", "feat(): empty scope", &.{.{ .start = 0, .end = 19 }});
    try expectHits("conventional", "Feat: capitalised type", &.{.{ .start = 0, .end = 22 }});
}

test "text checks: forbid reports every place the exact text stands" {
    try expectHits("forbid:WIP", "WIP: half done, still WIP", &.{ .{ .start = 0, .end = 3 }, .{ .start = 22, .end = 25 } });
    try expectHits("forbid:WIP", "wip: lower case is another text", &.{});
    try expectHits("forbid:Signed-off-by:", "fix: one\n\nSigned-off-by: A <a@example.com>", &.{.{ .start = 10, .end = 24 }});
}

test "text checks: forbid_any_case also finds the text in another letter case" {
    try expectHits("forbid_any_case:signed-off-by", "fix: one\n\nSIGNED-OFF-BY: A", &.{.{ .start = 10, .end = 23 }});
    try expectHits("forbid_any_case:wip", "fix: done", &.{});
}

test "text checks: require reports one hit at the start when the text is missing and none when it stands" {
    try expectHits("require:Signed-off-by:", "fix: one", &.{.{ .start = 0, .end = 0 }});
    try expectHits("require:Signed-off-by:", "fix: one\n\nSigned-off-by: A <a@example.com>", &.{});
    try expectHits("require:signed-off-by:", "fix: one\n\nSigned-off-by: A", &.{.{ .start = 0, .end = 0 }});
    try expectHits("require_any_case:signed-off-by:", "fix: one\n\nSigned-off-by: A", &.{});
}

test "text checks: max_lines counts lines without the trailing line ends and reports the lines over the limit" {
    try expectHits("max_lines:1", "fix: one", &.{});
    try expectHits("max_lines:1", "fix: one\n", &.{});
    try expectHits("max_lines:1", "fix: one\r\n\r\n", &.{});
    try expectHits("max_lines:1", "fix: one\n\nbody", &.{.{ .start = 9, .end = 14 }});
    try expectHits("max_lines:3", "a\nb\nc", &.{});
    try expectHits("max_lines:3", "a\nb\nc\nd\ne", &.{.{ .start = 6, .end = 9 }});
}

test "text checks: max_subject counts characters of the first line, not bytes, and ignores later lines" {
    try expectHits("max_subject:8", "fix: one", &.{});
    try expectHits("max_subject:7", "fix: one", &.{.{ .start = 7, .end = 8 }});
    try expectHits("max_subject:4", "çğış", &.{});
    try expectHits("max_subject:3", "çğış", &.{.{ .start = 6, .end = 8 }});
    try expectHits("max_subject:3", "fix\n\na much longer body line", &.{});
    try expectHits("max_subject:3", "fix\r\nbody", &.{});
}

test "text checks: max_line reports every line longer than the limit" {
    try expectHits("max_line:5", "short\nlonger line\nok\nalso long", &.{ .{ .start = 11, .end = 17 }, .{ .start = 26, .end = 30 } });
    try expectHits("max_line:5", "short\nfive5\n", &.{});
}
