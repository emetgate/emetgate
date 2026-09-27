const std = @import("std");
const ts = @import("tree_sitter.zig");
const symbol = @import("symbol.zig");
const cas = @import("cas.zig");
const traversal = @import("traversal.zig");
const Snapshot = @import("loader.zig").Snapshot;
const Profile = @import("lang/profile.zig").Profile;
const test_util = @import("test_util.zig");

const Allocator = std.mem.Allocator;
const Span = symbol.Span;
const Hash = symbol.Hash;

pub const min_address_len = 12;
pub const max_edits = 64;

pub const Error = error{
    SourceHasErrors,
    InvalidHash,
    HashMismatch,
    AmbiguousNode,
    OverlappingNodes,
    NoNodeEdits,
    TooManyNodeEdits,
    MutationSyntaxInvalid,
    BodyEscape,
    PlaceholderBody,
} || Allocator.Error || ts.Error;

pub const Edit = struct {
    address: []const u8,
    text: []const u8,
};

pub const Placed = struct {
    old: Span,
    new: Span,
    nodes: []const []const u8,
};

pub const Unit = struct {
    ref: []const u8,
    before: ?Hash,
    after: ?Hash,
    span: Span,

    pub fn checked(self: Unit) bool {
        return self.ref.len == 0 or self.after != null;
    }

    pub fn parseRef(self: Unit, gpa: Allocator) symbol.Ref.ParseError!symbol.Ref {
        if (self.ref.len == 0) return top_level_ref;
        return symbol.Ref.parse(gpa, self.ref);
    }
};

pub const top_level_ref: symbol.Ref = .{ .name = "" };

pub const Applied = struct {
    snapshot: *Snapshot,
    arena: *std.heap.ArenaAllocator,
    placed: []const Placed,
    units: []const Unit,

    pub fn deinit(self: Applied) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self.arena);
        self.snapshot.destroy();
    }
};

pub fn nodeHash(tree: ts.Tree, node: ts.Node) Hash {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("emetgate/node/v1\x00");
    hasher.update(node.kind());
    hasher.update("\x00");
    hasher.update(tree.text(node));
    var out: Hash = undefined;
    hasher.final(&out);
    return out;
}

pub const Address = struct {
    hex: [symbol.hash_hex_len]u8 = undefined,
    len: u8,

    pub fn parse(text: []const u8) error{InvalidHash}!Address {
        if (text.len < min_address_len or text.len > symbol.hash_hex_len) return error.InvalidHash;
        var out: Address = .{ .len = @intCast(text.len) };
        for (text, 0..) |ch, i| {
            out.hex[i] = switch (ch) {
                '0'...'9', 'a'...'f' => ch,
                'A'...'F' => ch + ('a' - 'A'),
                else => return error.InvalidHash,
            };
        }
        return out;
    }

    pub fn matches(self: Address, hash: Hash) bool {
        const full = symbol.formatHash(hash);
        return std.mem.eql(u8, full[0..self.len], self.hex[0..self.len]);
    }
};

fn addressable(tree: ts.Tree, node: ts.Node) bool {
    return node.isNamed() and !node.eql(tree.root()) and node.endByte() > node.startByte();
}

pub const Index = struct {
    hashes: []Hash,

    pub fn build(gpa: Allocator, tree: ts.Tree) Allocator.Error!Index {
        var list: std.ArrayList(Hash) = .empty;
        errdefer list.deinit(gpa);
        var walker = traversal.Walker.init(tree.root());
        defer walker.deinit();
        while (walker.next()) |entry| {
            if (addressable(tree, entry.node)) try list.append(gpa, nodeHash(tree, entry.node));
        }
        const hashes = try list.toOwnedSlice(gpa);
        std.mem.sort(Hash, hashes, {}, lessHash);
        return .{ .hashes = hashes };
    }

    pub fn deinit(self: Index, gpa: Allocator) void {
        gpa.free(self.hashes);
    }

    fn lowerBound(self: Index, hash: Hash) usize {
        var lo: usize = 0;
        var hi: usize = self.hashes.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (lessHash({}, self.hashes[mid], hash)) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    pub fn count(self: Index, hash: Hash) usize {
        var i = self.lowerBound(hash);
        var n: usize = 0;
        while (i < self.hashes.len and std.mem.eql(u8, &self.hashes[i], &hash)) : (i += 1) n += 1;
        return n;
    }

    pub fn addressLen(self: Index, hash: Hash) u8 {
        const at = self.lowerBound(hash);
        var shared: usize = 0;
        if (at > 0) shared = @max(shared, sharedNibbles(self.hashes[at - 1], hash));
        var i = at;
        while (i < self.hashes.len and std.mem.eql(u8, &self.hashes[i], &hash)) : (i += 1) {}
        if (i < self.hashes.len) shared = @max(shared, sharedNibbles(self.hashes[i], hash));
        return @intCast(@min(symbol.hash_hex_len, @max(min_address_len, shared + 1)));
    }
};

fn lessHash(_: void, a: Hash, b: Hash) bool {
    return std.mem.order(u8, &a, &b) == .lt;
}

fn sharedNibbles(a: Hash, b: Hash) usize {
    const x = symbol.formatHash(a);
    const y = symbol.formatHash(b);
    var n: usize = 0;
    while (n < x.len and x[n] == y[n]) n += 1;
    return n;
}

fn resolve(tree: ts.Tree, addresses: []const Address, found: []?ts.Node) Error!void {
    var walker = traversal.Walker.init(tree.root());
    defer walker.deinit();
    while (walker.next()) |entry| {
        if (!addressable(tree, entry.node)) continue;
        const hash = nodeHash(tree, entry.node);
        for (addresses, found) |address, *slot| {
            if (!address.matches(hash)) continue;
            if (slot.* != null) return error.AmbiguousNode;
            slot.* = entry.node;
        }
    }
    for (found) |slot| {
        if (slot == null) return error.HashMismatch;
    }
}

const Hole = struct {
    index: usize,
    node: ts.Node,
    old: Span,
    new: Span = .{ .start = 0, .end = 0 },
    text: []const u8,
    run: []const ts.Node = &.{},
};

fn lessByStart(_: void, a: Hole, b: Hole) bool {
    return a.old.start < b.old.start;
}

pub fn apply(base: *Snapshot, edits: []const Edit) Error!Applied {
    if (edits.len == 0) return error.NoNodeEdits;
    if (edits.len > max_edits) return error.TooManyNodeEdits;
    if (base.tree.root().hasError()) return error.SourceHasErrors;
    const gpa = base.runtime.gpa;

    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const addresses = try a.alloc(Address, edits.len);
    for (edits, addresses) |edit, *address| address.* = try Address.parse(edit.address);
    const found = try a.alloc(?ts.Node, edits.len);
    @memset(found, null);
    try resolve(base.tree, addresses, found);

    const holes = try a.alloc(Hole, edits.len);
    for (edits, found, 0..) |edit, node, i| holes[i] = .{
        .index = i,
        .node = node.?,
        .old = .{ .start = node.?.startByte(), .end = node.?.endByte() },
        .text = cas.normalizeBody(edit.text),
    };
    std.mem.sort(Hole, holes, {}, lessByStart);
    for (holes[1..], holes[0 .. holes.len - 1]) |current, previous| {
        if (previous.old.end > current.old.start) return error.OverlappingNodes;
    }

    var total: usize = base.source.len;
    for (holes) |hole| total = total - (hole.old.end - hole.old.start) + hole.text.len;
    const source = try gpa.alloc(u8, total);
    var written: usize = 0;
    var cursor: usize = 0;
    for (holes) |*hole| {
        const before = base.source[cursor..hole.old.start];
        @memcpy(source[written..][0..before.len], before);
        written += before.len;
        @memcpy(source[written..][0..hole.text.len], hole.text);
        hole.new = .{ .start = @intCast(written), .end = @intCast(written + hole.text.len) };
        written += hole.text.len;
        cursor = hole.old.end;
    }
    @memcpy(source[written..], base.source[cursor..]);

    const next = try Snapshot.fromSource(base.runtime, base.profile, source);
    errdefer next.destroy();
    if (next.tree.root().hasError()) return error.MutationSyntaxInvalid;

    try sameOutside(a, base.tree, next.tree, holes);
    for (holes) |hole| try rejectPlaceholderRun(base.profile, hole.node, hole.run);

    const index = try Index.build(gpa, next.tree);
    defer index.deinit(gpa);
    const placed = try a.alloc(Placed, edits.len);
    for (holes) |hole| {
        var addresses_out: std.ArrayList([]const u8) = .empty;
        for (hole.run) |node| {
            if (!node.isNamed()) continue;
            const hash = nodeHash(next.tree, node);
            if (index.count(hash) != 1) continue;
            const hex = symbol.formatHash(hash);
            try addresses_out.append(a, try a.dupe(u8, hex[0..index.addressLen(hash)]));
        }
        placed[hole.index] = .{ .old = hole.old, .new = hole.new, .nodes = addresses_out.items };
    }

    const before_table = base.symbols() catch |err| switch (err) {
        error.SourceHasErrors => return error.SourceHasErrors,
        error.OutOfMemory => return error.OutOfMemory,
    };
    const after_table = next.symbols() catch |err| switch (err) {
        error.SourceHasErrors => return error.MutationSyntaxInvalid,
        error.OutOfMemory => return error.OutOfMemory,
    };
    const units = try changedUnits(a, before_table.*, after_table.*, holes);

    return .{ .snapshot = next, .arena = arena, .placed = placed, .units = units };
}

fn shift(holes: []const Hole, pos: u32) u32 {
    var out: i64 = pos;
    for (holes) |hole| {
        if (hole.old.end > pos) break;
        out += @as(i64, hole.new.end - hole.new.start) - @as(i64, hole.old.end - hole.old.start);
    }
    return @intCast(out);
}

fn sameNode(holes: []const Hole, old: traversal.Walker.Entry, new: traversal.Walker.Entry) bool {
    if (old.depth != new.depth) return false;
    if (old.node.isNamed() != new.node.isNamed()) return false;
    if (!std.mem.eql(u8, old.node.kind(), new.node.kind())) return false;
    if (old.depth == 0) return true;
    return shift(holes, old.node.startByte()) == new.node.startByte() and shift(holes, old.node.endByte()) == new.node.endByte();
}

fn sameOutside(a: Allocator, old_tree: ts.Tree, new_tree: ts.Tree, holes: []Hole) Error!void {
    var old_walker = traversal.Walker.init(old_tree.root());
    defer old_walker.deinit();
    var new_walker = traversal.Walker.init(new_tree.root());
    defer new_walker.deinit();

    var next_hole: usize = 0;
    var pending = new_walker.next();
    while (old_walker.next()) |old| {
        if (next_hole < holes.len and old.node.eql(holes[next_hole].node)) {
            old_walker.skipChildren();
            const hole = &holes[next_hole];
            var run: std.ArrayList(ts.Node) = .empty;
            while (pending) |new| {
                if (new.depth != old.depth) break;
                if (new.node.startByte() < hole.new.start or new.node.endByte() > hole.new.end) break;
                if (new.node.endByte() == new.node.startByte()) break;
                try run.append(a, new.node);
                new_walker.skipChildren();
                pending = new_walker.next();
            }
            if (run.items.len == 0 and hole.new.end > hole.new.start) return error.BodyEscape;
            hole.run = run.items;
            next_hole += 1;
            continue;
        }
        const new = pending orelse return error.BodyEscape;
        if (!sameNode(holes, old, new)) return error.BodyEscape;
        pending = new_walker.next();
    }
    if (pending != null or next_hole != holes.len) return error.BodyEscape;
}

fn rejectPlaceholderRun(profile: *const Profile, replaced: ts.Node, run: []const ts.Node) error{PlaceholderBody}!void {
    if (run.len == 0) return;
    if (!profile.isComment(replaced.kind())) {
        var only_comments = true;
        for (run) |node| {
            if (!profile.isComment(node.kind())) only_comments = false;
        }
        if (only_comments) return error.PlaceholderBody;
    }
    for (run) |node| try cas.rejectPlaceholder(profile, node);
}

fn bodySpan(s: symbol.Symbol) Span {
    return .{ .start = s.body.startByte(), .end = s.body.endByte() };
}

fn refText(a: Allocator, ref: symbol.Ref) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "{f}", .{ref});
}

fn changedUnits(a: Allocator, before: symbol.Table, after: symbol.Table, holes: []const Hole) Error![]const Unit {
    var units: std.ArrayList(Unit) = .empty;
    for (after.symbols) |new| {
        var twin: ?symbol.Symbol = null;
        var unchanged = false;
        for (before.symbols) |old| {
            if (!old.ref.eql(new.ref)) continue;
            if (std.mem.eql(u8, &old.hash, &new.hash)) unchanged = true;
            if (twin == null) twin = old;
        }
        if (unchanged) continue;
        try units.append(a, .{ .ref = try refText(a, new.ref), .before = if (twin) |t| t.hash else null, .after = new.hash, .span = bodySpan(new) });
    }
    for (before.symbols) |old| {
        var kept = false;
        for (after.symbols) |new| {
            if (old.ref.eql(new.ref)) kept = true;
        }
        if (!kept) try units.append(a, .{ .ref = try refText(a, old.ref), .before = old.hash, .after = null, .span = .{ .start = 0, .end = 0 } });
    }
    for (holes) |hole| {
        var inside = false;
        for (after.symbols) |new| {
            const body = bodySpan(new);
            if (body.start <= hole.new.start and hole.new.end <= body.end) inside = true;
        }
        if (!inside) try units.append(a, .{ .ref = "", .before = null, .after = null, .span = hole.new });
    }
    return units.items;
}

fn lineLeading(source: []const u8, pos: u32) bool {
    var i: usize = pos;
    while (i > 0) {
        i -= 1;
        switch (source[i]) {
            ' ', '\t' => {},
            '\n' => return true,
            else => return false,
        }
    }
    return true;
}

pub fn annotate(gpa: Allocator, tree: ts.Tree, region: Span) Allocator.Error![]u8 {
    const index = try Index.build(gpa, tree);
    defer index.deinit(gpa);

    var leading: std.AutoHashMapUnmanaged(u32, ts.Node) = .empty;
    defer leading.deinit(gpa);
    var walker = traversal.Walker.init(tree.root());
    defer walker.deinit();
    while (walker.next()) |entry| {
        const node = entry.node;
        if (node.endByte() <= region.start or node.startByte() >= region.end) {
            walker.skipChildren();
            continue;
        }
        if (!addressable(tree, node)) continue;
        if (node.startByte() < region.start or node.endByte() > region.end) continue;
        if (!lineLeading(tree.source, node.startByte())) continue;
        const slot = try leading.getOrPut(gpa, node.startByte());
        if (!slot.found_existing) slot.value_ptr.* = node;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var line_start: u32 = region.start;
    while (line_start < region.end) {
        const newline = std.mem.indexOfScalarPos(u8, tree.source[0..region.end], line_start, '\n');
        const line_end: u32 = if (newline) |n| @intCast(n + 1) else region.end;
        var first = line_start;
        while (first < line_end and (tree.source[first] == ' ' or tree.source[first] == '\t')) first += 1;
        if (leading.get(first)) |node| {
            const hash = nodeHash(tree, node);
            if (index.count(hash) == 1) {
                const hex = symbol.formatHash(hash);
                try out.appendSlice(gpa, hex[0..index.addressLen(hash)]);
                try out.append(gpa, '|');
            }
        }
        try out.appendSlice(gpa, tree.source[line_start..line_end]);
        line_start = line_end;
    }
    return out.toOwnedSlice(gpa);
}

const testing = std.testing;

fn addressOf(snapshot: *Snapshot, text: []const u8, kind: []const u8) ![symbol.hash_hex_len]u8 {
    const at: u32 = @intCast(std.mem.indexOf(u8, snapshot.source, text) orelse return error.TextNotInSource);
    var walker = traversal.Walker.init(snapshot.tree.root());
    defer walker.deinit();
    while (walker.next()) |entry| {
        const node = entry.node;
        if (node.startByte() == at and node.endByte() == at + text.len and std.mem.eql(u8, node.kind(), kind)) {
            return symbol.formatHash(nodeHash(snapshot.tree, node));
        }
    }
    return error.NodeNotInSource;
}

fn applyOne(base: *Snapshot, text: []const u8, kind: []const u8, replacement: []const u8) !Applied {
    const address = try addressOf(base, text, kind);
    return apply(base, &.{.{ .address = address[0..min_address_len], .text = replacement }});
}

test "a statement is replaced through its node hash and every byte outside it stays as it was" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try test_util.snapshotOf(runtime, "function f(a: number) {\n  const x = a + 1;\n  return x * 2;\n}\nfunction g() { return 1; }\n");
    defer base.destroy();

    const applied = try applyOne(base, "return x * 2;", "return_statement", "return x * 3;");
    defer applied.deinit();
    try testing.expectEqualStrings("function f(a: number) {\n  const x = a + 1;\n  return x * 3;\n}\nfunction g() { return 1; }\n", applied.snapshot.source);
    try testing.expectEqual(@as(usize, 1), applied.placed[0].nodes.len);
    try testing.expectEqual(@as(usize, 1), applied.units.len);
    try testing.expectEqualStrings("f", applied.units[0].ref);
    try testing.expect(applied.units[0].before != null and applied.units[0].after != null);
}

test "a node address stays valid after an edit elsewhere in the same body" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try test_util.snapshotOf(runtime, "function f(a: number) {\n  const x = a + 1;\n  return x * 2;\n}\n");
    defer base.destroy();
    const address = try addressOf(base, "return x * 2;", "return_statement");

    const first = try applyOne(base, "const x = a + 1;", "lexical_declaration", "const x = a + 10;");
    defer first.deinit();
    const second = try apply(first.snapshot, &.{.{ .address = address[0..min_address_len], .text = "return x * 4;" }});
    defer second.deinit();
    try testing.expectEqualStrings("function f(a: number) {\n  const x = a + 10;\n  return x * 4;\n}\n", second.snapshot.source);
}

test "a stale, unknown or malformed address is refused before anything is spliced" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try test_util.snapshotOf(runtime, "function f() {\n  return 1;\n}\n");
    defer base.destroy();

    try testing.expectError(error.HashMismatch, apply(base, &.{.{ .address = "000000000000", .text = "return 2;" }}));
    try testing.expectError(error.InvalidHash, apply(base, &.{.{ .address = "abc", .text = "return 2;" }}));
    try testing.expectError(error.InvalidHash, apply(base, &.{.{ .address = "zzzzzzzzzzzz", .text = "return 2;" }}));
    try testing.expectError(error.InvalidHash, apply(base, &.{.{ .address = "0123456789abcdef0123456789abcdef0", .text = "return 2;" }}));
    try testing.expectError(error.NoNodeEdits, apply(base, &.{}));

    const stale = try applyOne(base, "return 1;", "return_statement", "return 2;");
    defer stale.deinit();
    const old = try addressOf(base, "return 1;", "return_statement");
    try testing.expectError(error.HashMismatch, apply(stale.snapshot, &.{.{ .address = old[0..min_address_len], .text = "return 3;" }}));
}

test "a node whose content occurs twice is ambiguous" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try test_util.snapshotOf(runtime, "function f(a: boolean) {\n  if (a) {\n    return null;\n  }\n  return null;\n}\n");
    defer base.destroy();
    try testing.expectError(error.AmbiguousNode, applyOne(base, "return null;", "return_statement", "return 0;"));
}

test "text that spills outside its node or reshapes a neighbour is a BodyEscape or a syntax error" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try test_util.snapshotOf(runtime, "function f() {\n  let a = 1;\n  let b = 2;\n  return a + b;\n}\nfunction g() { return 7; }\n");
    defer base.destroy();

    const Case = struct { text: []const u8, kind: []const u8, replacement: []const u8, expected: anyerror };
    const cases = [_]Case{
        .{ .text = "1", .kind = "number", .replacement = "1; let c = 3", .expected = error.BodyEscape },
        .{ .text = "let a = 1;", .kind = "lexical_declaration", .replacement = "let a = 1;\n}\nfunction evil() {", .expected = error.BodyEscape },
        .{ .text = "a + b", .kind = "binary_expression", .replacement = "a + b; }\nfunction evil() { return 0", .expected = error.BodyEscape },
        .{ .text = "a + b", .kind = "binary_expression", .replacement = "a +", .expected = error.MutationSyntaxInvalid },
        .{ .text = "2", .kind = "number", .replacement = "2, c = 5", .expected = error.BodyEscape },
        .{ .text = "return 7;", .kind = "return_statement", .replacement = "return 7; }\nfunction h() { return 8;", .expected = error.BodyEscape },
    };
    for (cases) |case| {
        errdefer std.debug.print("accepted: {s} -> {s}\n", .{ case.text, case.replacement });
        try testing.expectError(case.expected, applyOne(base, case.text, case.kind, case.replacement));
        try testing.expectEqual(@as(usize, 1), runtime.live_snapshots);
    }
}

test "a placeholder comment cannot stand in for a node, a real comment edit is allowed" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try test_util.snapshotOf(runtime, "function f(a: number) {\n  // keep a positive\n  if (a < 0) {\n    a = -a;\n  }\n  return a;\n}\n");
    defer base.destroy();

    try testing.expectError(error.PlaceholderBody, applyOne(base, "if (a < 0) {\n    a = -a;\n  }", "if_statement", "// ...existing code..."));
    try testing.expectError(error.PlaceholderBody, applyOne(base, "{\n    a = -a;\n  }", "statement_block", "{\n    // ...existing code...\n  }"));
    const comment = try applyOne(base, "// keep a positive", "comment", "// a is never negative after this");
    defer comment.deinit();
    try testing.expect(std.mem.indexOf(u8, comment.snapshot.source, "// a is never negative after this\n  if (a < 0)") != null);
}

test "an empty text deletes a statement and several edits land in one call" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try test_util.snapshotOf(runtime, "function f(a: number) {\n  log(a);\n  const b = a * 2;\n  return b;\n}\n");
    defer base.destroy();

    const removed = try applyOne(base, "log(a);", "expression_statement", "");
    defer removed.deinit();
    try testing.expectEqualStrings("function f(a: number) {\n  \n  const b = a * 2;\n  return b;\n}\n", removed.snapshot.source);

    const one = try addressOf(base, "log(a);", "expression_statement");
    const two = try addressOf(base, "return b;", "return_statement");
    const both = try apply(base, &.{ .{ .address = two[0..min_address_len], .text = "return b + 1;" }, .{ .address = one[0..min_address_len], .text = "trace(a);" } });
    defer both.deinit();
    try testing.expectEqualStrings("function f(a: number) {\n  trace(a);\n  const b = a * 2;\n  return b + 1;\n}\n", both.snapshot.source);
    try testing.expectEqual(both.placed[0].old.start, @as(u32, @intCast(std.mem.indexOf(u8, base.source, "return b;").?)));

    const outer = try addressOf(base, "{\n  log(a);\n  const b = a * 2;\n  return b;\n}", "statement_block");
    try testing.expectError(error.OverlappingNodes, apply(base, &.{ .{ .address = outer[0..min_address_len], .text = "{ return 0; }" }, .{ .address = one[0..min_address_len], .text = "trace(a);" } }));
    try testing.expectError(error.OverlappingNodes, apply(base, &.{ .{ .address = one[0..min_address_len], .text = "a;" }, .{ .address = one[0..min_address_len], .text = "b;" } }));
}

test "a top-level statement outside every symbol is addressable and reported as a top-level unit" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try test_util.snapshotOf(runtime, "const limit = 10;\nexport function f() { return limit; }\n");
    defer base.destroy();

    const applied = try applyOne(base, "const limit = 10;", "lexical_declaration", "const limit = 20;");
    defer applied.deinit();
    try testing.expectEqualStrings("const limit = 20;\nexport function f() { return limit; }\n", applied.snapshot.source);
    try testing.expectEqual(@as(usize, 1), applied.units.len);
    try testing.expectEqualStrings("", applied.units[0].ref);
}

test "replacing a whole function node reports the symbol and the top-level region it sits in" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try test_util.snapshotOf(runtime, "function f() { return 1; }\nfunction g() { return 2; }\n");
    defer base.destroy();

    const applied = try applyOne(base, "function f() { return 1; }", "function_declaration", "function f() {\n  return 10;\n}");
    defer applied.deinit();
    try testing.expectEqualStrings("function f() {\n  return 10;\n}\nfunction g() { return 2; }\n", applied.snapshot.source);
    var saw_symbol = false;
    var saw_top_level = false;
    for (applied.units) |unit| {
        if (std.mem.eql(u8, unit.ref, "f")) saw_symbol = true;
        if (unit.ref.len == 0) saw_top_level = true;
        try testing.expect(!std.mem.eql(u8, unit.ref, "g"));
    }
    try testing.expect(saw_symbol and saw_top_level);

    const deleted = try applyOne(base, "function f() { return 1; }", "function_declaration", "");
    defer deleted.deinit();
    try testing.expectEqualStrings("\nfunction g() { return 2; }\n", deleted.snapshot.source);
    var removed_f = false;
    for (deleted.units) |unit| {
        if (std.mem.eql(u8, unit.ref, "f") and unit.after == null) removed_f = true;
    }
    try testing.expect(removed_f);
}

test "annotate prefixes each line that starts a unique node with its short hash" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try test_util.snapshotOf(runtime, "function f(a: boolean) {\n  if (a) {\n    return null;\n  }\n  return null;\n}\n");
    defer base.destroy();

    const text = try annotate(testing.allocator, base.tree, .{ .start = 0, .end = @intCast(base.source.len) });
    defer testing.allocator.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    const expected_plain = [_][]const u8{ "function f(a: boolean) {", "  if (a) {", "    return null;", "  }", "  return null;", "}", "" };
    const expected_marked = [_]bool{ true, true, false, false, false, false, false };
    for (expected_plain, expected_marked) |plain, marked| {
        const line = lines.next() orelse return error.MissingLine;
        if (marked) {
            try testing.expectEqual(@as(u8, '|'), line[min_address_len]);
            try testing.expectEqualStrings(plain, line[min_address_len + 1 ..]);
            const address = line[0..min_address_len];
            var walker = traversal.Walker.init(base.tree.root());
            defer walker.deinit();
            var hits: usize = 0;
            while (walker.next()) |entry| {
                if (addressable(base.tree, entry.node) and (try Address.parse(address)).matches(nodeHash(base.tree, entry.node))) hits += 1;
            }
            try testing.expectEqual(@as(usize, 1), hits);
        } else {
            try testing.expectEqualStrings(plain, line);
        }
    }
}

test "the node primitive works unchanged on another language's profile" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const zig_profile = &@import("lang/zig/profile.zig").profile;
    const base = try Snapshot.fromSource(runtime, zig_profile, try testing.allocator.dupe(u8, "fn add(a: u32, b: u32) u32 {\n    const sum = a + b;\n    return sum;\n}\n"));
    defer base.destroy();

    const text = try annotate(testing.allocator, base.tree, .{ .start = 0, .end = @intCast(base.source.len) });
    defer testing.allocator.free(text);
    const at = std.mem.indexOf(u8, text, "|    return sum;") orelse return error.NotAnnotated;
    const line_start = std.mem.lastIndexOfScalar(u8, text[0..at], '\n').? + 1;
    const applied = try apply(base, &.{.{ .address = text[line_start..at], .text = "return sum * 2;" }});
    defer applied.deinit();
    try testing.expectEqualStrings("fn add(a: u32, b: u32) u32 {\n    const sum = a + b;\n    return sum * 2;\n}\n", applied.snapshot.source);
}
