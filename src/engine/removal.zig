const std = @import("std");
const ts = @import("tree_sitter.zig");
const symbol = @import("symbol.zig");
const cas = @import("cas.zig");
const Snapshot = @import("loader.zig").Snapshot;
const test_util = @import("test_util.zig");

const Span = symbol.Span;

pub const Error = error{
    SourceHasErrors,
    SymbolNotFound,
    AmbiguousSymbol,
    HashMismatch,
    NotTopLevel,
    SharedStatement,
    MutationSyntaxInvalid,
    BodyEscape,
} || std.mem.Allocator.Error || ts.Error;

pub const Removed = struct {
    snapshot: *Snapshot,
    cut: Span,
    span: Span,
    role: symbol.Item.Role,
};

pub fn remove(base: *Snapshot, ref: symbol.Ref, expected_hash: symbol.Hash) Error!Removed {
    const before = try base.symbols();
    const target = try before.item(ref);
    if (!std.mem.eql(u8, &target.hash, &expected_hash)) return error.HashMismatch;

    const statement = statementHolding(base.tree.root(), target.span.start) orelse return error.NotTopLevel;
    const whole = target.span.start <= statement.startByte() and target.span.end >= statement.endByte();
    const lines = if (whole) ownLines(base.source, .{ .start = statement.startByte(), .end = statement.endByte() }) else ownLines(base.source, target.span);
    const owned = lines orelse return error.SharedStatement;
    if (whole and topLevelSymbolsIn(before.*, owned) > 1) return error.SharedStatement;
    const cut = collapseBlanks(base.source, owned);

    const source = try std.mem.concat(base.runtime.gpa, u8, &.{ base.source[0..cut.start], base.source[cut.end..] });
    const next = try Snapshot.fromSource(base.runtime, base.profile, source);
    errdefer next.destroy();
    if (next.tree.root().hasError()) return error.MutationSyntaxInvalid;
    const after = next.symbols() catch |err| switch (err) {
        error.SourceHasErrors => return error.MutationSyntaxInvalid,
        error.OutOfMemory => return error.OutOfMemory,
    };
    try cas.expectSameShape(base.tree, next.tree, cut, .{ .start = cut.start, .end = cut.start });
    try expectOthersUntouched(before.*, after.*, cut);
    return .{ .snapshot = next, .cut = cut, .span = target.span, .role = target.role };
}

fn statementHolding(root: ts.Node, offset: u32) ?ts.Node {
    var i: u32 = 0;
    while (root.child(i)) |node| : (i += 1) {
        if (node.startByte() <= offset and offset < node.endByte()) return node;
    }
    return null;
}

fn blank(text: []const u8) bool {
    return std.mem.trim(u8, text, " \t\r\n").len == 0;
}

fn lineStartOf(source: []const u8, at: u32) u32 {
    const newline = std.mem.lastIndexOfScalar(u8, source[0..at], '\n') orelse return 0;
    return @intCast(newline + 1);
}

fn lineEndOf(source: []const u8, at: u32) u32 {
    const newline = std.mem.indexOfScalarPos(u8, source, at, '\n') orelse return @intCast(source.len);
    return @intCast(newline + 1);
}

fn ownLines(source: []const u8, span: Span) ?Span {
    const start = lineStartOf(source, span.start);
    if (!blank(source[start..span.start])) return null;
    const end = lineEndOf(source, span.end);
    var rest = std.mem.trim(u8, source[span.end..end], " \t\r\n");
    if (rest.len > 0 and (rest[0] == ',' or rest[0] == ';')) rest = std.mem.trim(u8, rest[1..], " \t\r\n");
    if (rest.len != 0) return null;
    return .{ .start = start, .end = end };
}

fn previousLine(source: []const u8, at: u32) ?Span {
    if (at == 0) return null;
    return .{ .start = lineStartOf(source, at - 1), .end = at };
}

fn collapseBlanks(source: []const u8, lines: Span) Span {
    var cut = lines;
    var top: ?u32 = null;
    while (previousLine(source, cut.start)) |line| {
        if (!blank(source[line.start..line.end])) break;
        top = line.end;
        cut.start = line.start;
    }
    var bottom: ?u32 = null;
    while (cut.end < source.len) {
        const end = lineEndOf(source, cut.end);
        if (!blank(source[cut.end..end])) break;
        bottom = cut.end;
        cut.end = end;
    }
    if (top == null and bottom == null) return cut;
    const above = if (previousLine(source, cut.start)) |line| std.mem.trim(u8, source[line.start..line.end], " \t\r\n") else "";
    const below = std.mem.trim(u8, source[cut.end..lineEndOf(source, cut.end)], " \t\r\n");
    if (above.len == 0 or below.len == 0) return cut;
    if (above[above.len - 1] == '{' or below[0] == '}') return cut;
    if (bottom) |at| cut.end = at else cut.start = top.?;
    return cut;
}

fn topLevelSymbolsIn(table: symbol.Table, cut: Span) usize {
    var count: usize = 0;
    for (table.symbols) |candidate| {
        if (candidate.ref.container.len != 0) continue;
        if (candidate.declaration.start >= cut.start and candidate.declaration.start < cut.end) count += 1;
    }
    return count;
}

fn expectOthersUntouched(before: symbol.Table, after: symbol.Table, cut: Span) error{BodyEscape}!void {
    var kept: usize = 0;
    for (before.symbols) |old| {
        if (old.declaration.start >= cut.start and old.declaration.start < cut.end) continue;
        kept += 1;
        if (!hasTwin(after, old)) return error.BodyEscape;
    }
    if (kept != after.symbols.len) return error.BodyEscape;
    for (before.declarations) |old| {
        if (old.declaration.start >= cut.start and old.declaration.start < cut.end) continue;
        if (old.declaration.start <= cut.start and old.declaration.end >= cut.end) continue;
        if (after.declarationMatching(old.ref, old.hash) == null) return error.BodyEscape;
    }
}

fn hasTwin(table: symbol.Table, wanted: symbol.Symbol) bool {
    for (table.symbols) |candidate| {
        if (candidate.ref.eql(wanted.ref) and std.mem.eql(u8, &candidate.hash, &wanted.hash)) return true;
    }
    return false;
}

const testing = std.testing;

fn hashOf(snapshot: *Snapshot, name: []const u8) !symbol.Hash {
    return (try (try snapshot.symbols()).resolve(.{ .name = name })).hash;
}

fn itemHash(snapshot: *Snapshot, ref_text: []const u8) !symbol.Hash {
    const ref = try symbol.Ref.parse(testing.allocator, ref_text);
    defer ref.deinit(testing.allocator);
    return (try (try snapshot.symbols()).item(ref)).hash;
}

fn removeIn(runtime: anytype, source: []const u8, ext: []const u8, ref_text: []const u8) ![]u8 {
    const base = try test_util.snapshotIn(runtime, source, ext);
    defer base.destroy();
    const ref = try symbol.Ref.parse(testing.allocator, ref_text);
    defer ref.deinit(testing.allocator);
    const removed = try remove(base, ref, try itemHash(base, ref_text));
    defer removed.snapshot.destroy();
    return testing.allocator.dupe(u8, removed.snapshot.source);
}

fn expectRemoved(runtime: anytype, source: []const u8, ext: []const u8, ref_text: []const u8, expected: []const u8) !void {
    const got = try removeIn(runtime, source, ext, ref_text);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "removal: statements, members, bindings and properties leave exactly one blank line between neighbours" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    try expectRemoved(runtime, "function a() { return 1; }\n\nfunction b() { return 2; }\n\nfunction c() { return 3; }\n", ".js", "b", "function a() { return 1; }\n\nfunction c() { return 3; }\n");
    try expectRemoved(runtime, "function a() { return 1; }\n\nfunction b() { return 2; }\n", ".js", "b", "function a() { return 1; }\n");
    try expectRemoved(runtime, "function a() { return 1; }\n\n\nfunction b() { return 2; }\n", ".js", "a", "function b() { return 2; }\n");
    try expectRemoved(runtime, "const fs = require('fs');\nconst os = require('os');\n\nfunction f() { return fs; }\n", ".js", "os", "const fs = require('fs');\n\nfunction f() { return fs; }\n");
    try expectRemoved(runtime, "class Cart {\n  size() {\n    return 0;\n  }\n\n  clear() {\n    return 1;\n  }\n}\n", ".js", "Cart.clear", "class Cart {\n  size() {\n    return 0;\n  }\n}\n");
    try expectRemoved(runtime, "class Cart {\n  clear() {\n    return 1;\n  }\n\n  size() {\n    return 0;\n  }\n}\n", ".js", "Cart.clear", "class Cart {\n  size() {\n    return 0;\n  }\n}\n");
    try expectRemoved(runtime, "module.exports = {\n  meta: {\n    type: 'problem',\n    schema: [],\n  },\n};\n", ".js", "module.exports.meta.schema", "module.exports = {\n  meta: {\n    type: 'problem',\n  },\n};\n");
    try expectRemoved(runtime, "'use strict';\n\nmodule.exports = { a: 1 };\n", ".js", "module.exports", "'use strict';\n");
}

test "removal: a top-level function is cut with its line and every other symbol keeps its hash" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try test_util.snapshotOf(runtime, "export function keep(): number { return 1; }\nfunction drop(): number { return 2; }\nclass C { m() { return keep(); } }\n");
    defer base.destroy();
    const removed = try remove(base, .{ .name = "drop" }, try hashOf(base, "drop"));
    defer removed.snapshot.destroy();
    try testing.expectEqualStrings("export function keep(): number { return 1; }\nclass C { m() { return keep(); } }\n", removed.snapshot.source);
    try testing.expectEqual(try hashOf(base, "keep"), try hashOf(removed.snapshot, "keep"));
}

test "removal: a stale hash, a member and a shared declaration are refused" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try test_util.snapshotOf(runtime, "const a = () => 1, b = () => 2;\nclass C { m() { return 1; } }\nfunction f() { return 3; }\n");
    defer base.destroy();
    try testing.expectError(error.HashMismatch, remove(base, .{ .name = "f" }, symbol.hashOf("stale")));
    try testing.expectError(error.SharedStatement, remove(base, .{ .name = "a" }, try hashOf(base, "a")));
    const member: symbol.Ref = .{ .container = &.{"C"}, .name = "m" };
    const member_hash = (try (try base.symbols()).resolve(member)).hash;
    try testing.expectError(error.SharedStatement, remove(base, member, member_hash));
}
