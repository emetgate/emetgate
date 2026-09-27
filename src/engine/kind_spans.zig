const std = @import("std");
const ts = @import("tree_sitter.zig");
const traversal = @import("traversal.zig");
const symbol = @import("symbol.zig");
const profile_mod = @import("lang/profile.zig");

const Allocator = std.mem.Allocator;
const Profile = profile_mod.Profile;

pub const Kind = enum { comment, string };
pub const Role = enum { definition, reference };

pub const Span = struct { start: u32, end: u32 };
pub const KindSpan = struct { start: u32, end: u32, kind: Kind };

pub const SymbolSpan = struct {
    ref_text: []const u8,
    name: []const u8,
    hash: symbol.Hash,
    node_start: u32,
    body_start: u32,
    node_end: u32,
};

pub const FileSpans = struct {
    symbols: []const SymbolSpan,
    kind_spans: []const KindSpan,
    reference_spans: []const Span,
};

pub fn build(a: Allocator, profile: *const Profile, tree: ts.Tree, table: *const symbol.Table) !FileSpans {
    var kinds: std.ArrayList(KindSpan) = .empty;
    var refs: std.ArrayList(Span) = .empty;

    var walker = traversal.Walker.init(tree.root());
    defer walker.deinit();
    while (walker.next()) |entry| {
        const n = entry.node;
        const k = n.kind();
        if (profile.isComment(k)) {
            try kinds.append(a, .{ .start = n.startByte(), .end = n.endByte(), .kind = .comment });
        } else {
            for (profile.strings) |sk| {
                if (std.mem.eql(u8, sk, k)) {
                    try kinds.append(a, .{ .start = n.startByte(), .end = n.endByte(), .kind = .string });
                    break;
                }
            }
        }
        if (std.mem.eql(u8, k, profile.call.node)) {
            if (n.childByField(profile.call.function_field)) |callee| {
                try refs.append(a, .{ .start = callee.startByte(), .end = callee.endByte() });
            }
        }
        if (n.childCount() == 0) {
            for (profile.reference_names) |rk| {
                if (std.mem.eql(u8, rk, k)) {
                    try refs.append(a, .{ .start = n.startByte(), .end = n.endByte() });
                    break;
                }
            }
        }
    }

    var syms: std.ArrayList(SymbolSpan) = .empty;
    for (table.symbols) |sym| {
        const ref_text = try std.fmt.allocPrint(a, "{f}", .{sym.ref});
        try syms.append(a, .{
            .ref_text = ref_text,
            .name = try a.dupe(u8, sym.ref.name),
            .hash = sym.hash,
            .node_start = sym.node.startByte(),
            .body_start = sym.body.startByte(),
            .node_end = sym.node.endByte(),
        });
    }

    return .{
        .symbols = try syms.toOwnedSlice(a),
        .kind_spans = try kinds.toOwnedSlice(a),
        .reference_spans = try refs.toOwnedSlice(a),
    };
}

pub fn classify(spans: []const KindSpan, offset: u32) ?Kind {
    var best: ?KindSpan = null;
    for (spans) |s| {
        if (offset < s.start or offset >= s.end) continue;
        if (best == null or (s.end - s.start) < (best.?.end - best.?.start)) best = s;
    }
    return if (best) |b| b.kind else null;
}

pub fn enclosing(symbols: []const SymbolSpan, offset: u32) ?*const SymbolSpan {
    var best: ?*const SymbolSpan = null;
    for (symbols) |*sym| {
        if (offset < sym.node_start or offset >= sym.node_end) continue;
        if (best == null or (sym.node_end - sym.node_start) < (best.?.node_end - best.?.node_start)) best = sym;
    }
    return best;
}

pub fn role(enclosing_sym: ?*const SymbolSpan, reference_spans: []const Span, offset: u32, matched_text: []const u8) ?Role {
    if (enclosing_sym) |sym| {
        if (offset >= sym.node_start and offset < sym.body_start and std.mem.eql(u8, matched_text, sym.name)) {
            return .definition;
        }
    }
    for (reference_spans) |s| {
        if (offset >= s.start and offset < s.end) return .reference;
    }
    return null;
}

const testing = std.testing;
const test_util = @import("test_util.zig");

test "build collects comment, string and call-reference spans and symbol boundaries from a small file" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);

    const source =
        \\// a comment
        \\function foo() {
        \\  return "a string";
        \\}
        \\function bar() {
        \\  foo();
        \\}
        \\
    ;
    const snapshot = try test_util.snapshotOf(runtime, source);
    defer snapshot.destroy();
    const table = try snapshot.symbols();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const spans = try build(arena.allocator(), test_util.language, snapshot.tree, table);

    try testing.expectEqual(@as(usize, 2), spans.symbols.len);

    var saw_comment = false;
    var saw_string = false;
    for (spans.kind_spans) |s| {
        if (s.kind == .comment) saw_comment = true;
        if (s.kind == .string) saw_string = true;
    }
    try testing.expect(saw_comment);
    try testing.expect(saw_string);
    try testing.expect(spans.reference_spans.len >= 1);
}

test "classify picks the smallest containing span and role finds a definition and a call reference" {
    const spans = [_]KindSpan{
        .{ .start = 0, .end = 20, .kind = .comment },
        .{ .start = 5, .end = 10, .kind = .string },
    };
    try testing.expectEqual(Kind.string, classify(&spans, 7).?);
    try testing.expectEqual(Kind.comment, classify(&spans, 15).?);
    try testing.expect(classify(&spans, 25) == null);

    const syms = [_]SymbolSpan{
        .{ .ref_text = "function#foo", .name = "foo", .hash = std.mem.zeroes(symbol.Hash), .node_start = 0, .body_start = 20, .node_end = 40 },
    };
    const encl = enclosing(&syms, 5);
    try testing.expect(encl != null);
    try testing.expectEqual(Role.definition, role(encl, &.{}, 5, "foo").?);

    const refs = [_]Span{.{ .start = 50, .end = 53 }};
    try testing.expectEqual(Role.reference, role(null, &refs, 51, "foo").?);
}
