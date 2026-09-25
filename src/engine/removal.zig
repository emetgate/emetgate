const std = @import("std");
const ts = @import("tree_sitter.zig");
const symbol = @import("symbol.zig");
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
};

pub fn remove(base: *Snapshot, ref: symbol.Ref, expected_hash: symbol.Hash) Error!Removed {
    const before = try base.symbols();
    const target = try before.resolve(ref);
    if (ref.container.len != 0) return error.NotTopLevel;
    if (!std.mem.eql(u8, &target.hash, &expected_hash)) return error.HashMismatch;

    const statement = statementHolding(base.tree.root(), target.declaration.start) orelse return error.NotTopLevel;
    const cut: Span = .{ .start = statement.startByte(), .end = lineEndAfter(base.source, statement.endByte()) };
    if (topLevelSymbolsIn(before.*, cut) != 1) return error.SharedStatement;

    const source = try std.mem.concat(base.runtime.gpa, u8, &.{ base.source[0..cut.start], base.source[cut.end..] });
    const next = try Snapshot.fromSource(base.runtime, base.profile, source);
    errdefer next.destroy();
    const after = next.symbols() catch |err| switch (err) {
        error.SourceHasErrors => return error.MutationSyntaxInvalid,
        error.OutOfMemory => return error.OutOfMemory,
    };
    try expectOthersUntouched(before.*, after.*, cut);
    return .{ .snapshot = next, .cut = cut };
}

fn statementHolding(root: ts.Node, offset: u32) ?ts.Node {
    var i: u32 = 0;
    while (root.child(i)) |node| : (i += 1) {
        if (node.startByte() <= offset and offset < node.endByte()) return node;
    }
    return null;
}

fn lineEndAfter(source: []const u8, end: u32) u32 {
    var at: usize = end;
    if (at < source.len and source[at] == '\r') at += 1;
    if (at < source.len and source[at] == '\n') at += 1;
    return @intCast(at);
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
    try testing.expectError(error.NotTopLevel, remove(base, member, member_hash));
}
