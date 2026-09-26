const std = @import("std");
const ts = @import("tree_sitter.zig");
const symbol = @import("symbol.zig");
const traversal = @import("traversal.zig");
const symmetry = @import("symmetry.zig");
const grammar = @import("lang/ecma/rename.zig");
const Snapshot = @import("loader.zig").Snapshot;
const Profile = @import("lang/profile.zig").Profile;
const test_util = @import("test_util.zig");

const Allocator = std.mem.Allocator;
const Span = symbol.Span;
const Blake3 = std.crypto.hash.Blake3;

pub const Error = error{
    UnsupportedLanguage,
    InvalidName,
    NotAnIdentifier,
    DuplicateLocation,
    ShorthandReference,
    IncompleteRename,
    NameTaken,
    MutationSyntaxInvalid,
    AlphaMismatch,
    SourceHasErrors,
} || Allocator.Error || ts.Error;

fn oneOf(kind: []const u8, kinds: []const []const u8) bool {
    for (kinds) |candidate| {
        if (std.mem.eql(u8, candidate, kind)) return true;
    }
    return false;
}

pub fn supports(profile: *const Profile) bool {
    return oneOf(profile.name, &grammar.languages);
}

pub fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name, 0..) |c, i| {
        const ok = std.ascii.isAlphabetic(c) or c == '_' or c == '$' or (i > 0 and std.ascii.isDigit(c));
        if (!ok) return false;
    }
    return true;
}

pub const Leaf = struct {
    span: Span,
    shorthand: bool,
    binder: bool,
    free: bool,
};

pub fn isBinder(node: ts.Node) bool {
    const parent = node.parent() orelse return false;
    const kind = parent.kind();
    for (grammar.binder_sites) |site| {
        if (!std.mem.eql(u8, site.parent, kind)) continue;
        const field = site.field orelse return true;
        if (site.unless) |unless| if (parent.childByField(unless) != null) continue;
        const held = parent.childByField(field) orelse continue;
        if (held.eql(node)) return true;
    }
    return false;
}

pub fn leavesNamed(gpa: Allocator, snapshot: *const Snapshot, name: []const u8) ![]Leaf {
    var out: std.ArrayList(Leaf) = .empty;
    errdefer out.deinit(gpa);
    var walker = traversal.Walker.init(snapshot.tree.root());
    defer walker.deinit();
    while (walker.next()) |entry| {
        const node = entry.node;
        const kind = node.kind();
        if (snapshot.profile.isComment(kind) or oneOf(kind, snapshot.profile.strings)) {
            walker.skipChildren();
            continue;
        }
        if (node.childCount() != 0 or !oneOf(kind, &grammar.name_kinds)) continue;
        const span: Span = .{ .start = node.startByte(), .end = node.endByte() };
        if (!std.mem.eql(u8, snapshot.source[span.start..span.end], name)) continue;
        try out.append(gpa, .{
            .span = span,
            .shorthand = oneOf(kind, &grammar.shorthand_kinds),
            .binder = isBinder(node),
            .free = oneOf(kind, &grammar.free_kinds),
        });
    }
    return out.toOwnedSlice(gpa);
}

fn exportedDeclaration(profile: *const Profile, node: ts.Node) bool {
    var current = node.parent();
    while (current) |ancestor| : (current = ancestor.parent()) {
        const kind = ancestor.kind();
        if (oneOf(kind, profile.export_wrappers)) return true;
        if (oneOf(kind, &grammar.scope_kinds)) return false;
    }
    return false;
}

fn leafAt(root: ts.Node, span: Span) ?ts.Node {
    var node = root;
    outer: while (node.childCount() != 0) {
        var i: u32 = 0;
        while (node.child(i)) |child| : (i += 1) {
            if (child.startByte() <= span.start and span.end <= child.endByte()) {
                node = child;
                continue :outer;
            }
        }
        return null;
    }
    if (node.startByte() != span.start or node.endByte() != span.end) return null;
    return node;
}

pub fn exportedName(gpa: Allocator, snapshot: *const Snapshot, name: []const u8) !bool {
    const leaves = try leavesNamed(gpa, snapshot, name);
    defer gpa.free(leaves);
    const root = snapshot.tree.root();
    for (leaves) |leaf| {
        const node = leafAt(root, leaf.span) orelse continue;
        const parent = node.parent() orelse continue;
        if (oneOf(parent.kind(), &grammar.export_specifiers)) return true;
        if (leaf.binder and exportedDeclaration(snapshot.profile, node)) return true;
    }
    return false;
}

pub fn binderCount(gpa: Allocator, snapshot: *const Snapshot, name: []const u8) !usize {
    const leaves = try leavesNamed(gpa, snapshot, name);
    defer gpa.free(leaves);
    var count: usize = 0;
    for (leaves) |leaf| {
        if (leaf.binder) count += 1;
    }
    return count;
}

pub const Dynamic = enum { string_mention, eval, computed_module, computed_member };

fn calleeName(snapshot: *const Snapshot, call: ts.Node) ?[]const u8 {
    const callee = call.childByField(snapshot.profile.call.function_field) orelse return null;
    return snapshot.source[callee.startByte()..callee.endByte()];
}

fn literalArgument(snapshot: *const Snapshot, call: ts.Node) bool {
    const arguments = call.childByField(snapshot.profile.call.arguments_field) orelse return false;
    if (arguments.namedChildCount() != 1) return false;
    const first = arguments.namedChild(0) orelse return false;
    return std.mem.eql(u8, first.kind(), grammar.literal_argument);
}

pub fn dynamicAccess(snapshot: *const Snapshot, name: []const u8, member: bool) ?Dynamic {
    var walker = traversal.Walker.init(snapshot.tree.root());
    defer walker.deinit();
    while (walker.next()) |entry| {
        const node = entry.node;
        const kind = node.kind();
        const text = snapshot.source[node.startByte()..node.endByte()];
        if (snapshot.profile.isComment(kind)) {
            walker.skipChildren();
            continue;
        }
        if (oneOf(kind, snapshot.profile.strings) or std.mem.eql(u8, kind, "string_fragment")) {
            walker.skipChildren();
            if (symmetry.mentions(text, name, null)) return .string_mention;
            continue;
        }
        if (std.mem.eql(u8, kind, snapshot.profile.call.node)) {
            const callee = calleeName(snapshot, node) orelse continue;
            if (oneOf(callee, &grammar.eval_callees)) return .eval;
            if (oneOf(callee, &grammar.module_callees) and !literalArgument(snapshot, node)) return .computed_module;
            continue;
        }
        if (std.mem.eql(u8, kind, grammar.new_expression)) {
            const constructor = node.childByField(grammar.new_constructor_field) orelse continue;
            if (oneOf(snapshot.source[constructor.startByte()..constructor.endByte()], &grammar.constructor_callees)) return .eval;
            continue;
        }
        if (std.mem.eql(u8, kind, grammar.subscript)) {
            const index = node.childByField(grammar.subscript_index_field) orelse continue;
            if (oneOf(index.kind(), &grammar.literal_index_kinds)) continue;
            if (member or oneOf(index.kind(), &grammar.constructed_index_kinds)) return .computed_member;
        }
    }
    return null;
}

fn lessThan(_: void, a: Span, b: Span) bool {
    return a.start < b.start;
}

pub fn alphaHash(gpa: Allocator, snapshot: *const Snapshot, region: Span) !symbol.Hash {
    var names: std.StringHashMapUnmanaged(u32) = .empty;
    defer names.deinit(gpa);
    var hasher = Blake3.init(.{});
    var walker = traversal.Walker.init(snapshot.tree.root());
    defer walker.deinit();
    while (walker.next()) |entry| {
        const node = entry.node;
        if (node.endByte() <= region.start or node.startByte() >= region.end) {
            walker.skipChildren();
            continue;
        }
        if (node.childCount() != 0) continue;
        const kind = node.kind();
        const text = snapshot.source[node.startByte()..node.endByte()];
        hasher.update(kind);
        hasher.update(&.{0});
        if (oneOf(kind, &grammar.name_kinds)) {
            const slot = try names.getOrPut(gpa, text);
            if (!slot.found_existing) slot.value_ptr.* = names.count() - 1;
            var index: [4]u8 = undefined;
            std.mem.writeInt(u32, &index, slot.value_ptr.*, .little);
            hasher.update(&.{1});
            hasher.update(&index);
        } else {
            hasher.update(&.{2});
            hasher.update(text);
        }
        hasher.update(&.{0});
    }
    var out: symbol.Hash = undefined;
    hasher.final(&out);
    return out;
}

pub const Renamed = struct {
    snapshot: *Snapshot,
    spans: []Span,
    regions_checked: usize,
    symbols_checked: usize,

    pub fn deinit(self: Renamed, gpa: Allocator) void {
        self.snapshot.destroy();
        gpa.free(self.spans);
    }
};

fn regionOf(root: ts.Node, offset: u32) ?u32 {
    var i: u32 = 0;
    while (root.child(i)) |node| : (i += 1) {
        if (node.startByte() <= offset and offset < node.endByte()) return i;
    }
    return null;
}

fn nodeSpan(node: ts.Node) Span {
    return .{ .start = node.startByte(), .end = node.endByte() };
}

fn findLeaf(leaves: []const Leaf, span: Span) ?Leaf {
    for (leaves) |leaf| {
        if (leaf.span.start == span.start and leaf.span.end == span.end) return leaf;
    }
    return null;
}

pub fn apply(gpa: Allocator, base: *Snapshot, old: []const u8, new: []const u8, proposed: []const Span) Error!Renamed {
    if (!supports(base.profile)) return error.UnsupportedLanguage;
    if (!validName(old) or !validName(new) or std.mem.eql(u8, old, new)) return error.InvalidName;
    if (base.tree.root().hasError()) return error.SourceHasErrors;
    const spans = try gpa.dupe(Span, proposed);
    defer gpa.free(spans);
    std.mem.sort(Span, spans, {}, lessThan);
    for (spans[1..], spans[0 .. spans.len -| 1]) |span, previous| {
        if (span.start < previous.end) return error.DuplicateLocation;
    }

    const leaves = try leavesNamed(gpa, base, old);
    defer gpa.free(leaves);
    for (spans) |span| {
        const leaf = findLeaf(leaves, span) orelse return error.NotAnIdentifier;
        if (leaf.shorthand) return error.ShorthandReference;
    }
    const taken = try leavesNamed(gpa, base, new);
    defer gpa.free(taken);
    if (taken.len != 0) return error.NameTaken;

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    const moved = try gpa.alloc(Span, spans.len);
    defer gpa.free(moved);
    var cursor: usize = 0;
    for (spans, moved) |span, *slot| {
        try text.appendSlice(gpa, base.source[cursor..span.start]);
        const start: u32 = @intCast(text.items.len);
        try text.appendSlice(gpa, new);
        slot.* = .{ .start = start, .end = start + @as(u32, @intCast(new.len)) };
        cursor = span.end;
    }
    try text.appendSlice(gpa, base.source[cursor..]);

    const source = try base.runtime.gpa.dupe(u8, text.items);
    const next = try Snapshot.fromSource(base.runtime, base.profile, source);
    errdefer next.destroy();
    if (next.tree.root().hasError()) return error.MutationSyntaxInvalid;

    const regions = try compareRegions(gpa, base, next, spans);
    try checkSurvivors(gpa, next, old);
    const symbols_checked = try compareSymbols(gpa, base, next, old, new);

    return .{ .snapshot = next, .spans = try gpa.dupe(Span, moved), .regions_checked = regions, .symbols_checked = symbols_checked };
}

fn compareRegions(gpa: Allocator, base: *Snapshot, next: *Snapshot, spans: []const Span) Error!usize {
    const before = base.tree.root();
    const after = next.tree.root();
    if (before.childCount() != after.childCount()) return error.AlphaMismatch;
    var checked: usize = 0;
    var i: u32 = 0;
    while (before.child(i)) |statement| : (i += 1) {
        var touched = false;
        for (spans) |span| {
            if (regionOf(before, span.start) == i) touched = true;
        }
        if (!touched) continue;
        const twin = after.child(i).?;
        if (!std.mem.eql(u8, statement.kind(), twin.kind())) return error.AlphaMismatch;
        const a = try alphaHash(gpa, base, nodeSpan(statement));
        const b = try alphaHash(gpa, next, nodeSpan(twin));
        if (!std.mem.eql(u8, &a, &b)) return error.AlphaMismatch;
        checked += 1;
    }
    return checked;
}

fn checkSurvivors(gpa: Allocator, next: *Snapshot, old: []const u8) Error!void {
    const leaves = try leavesNamed(gpa, next, old);
    defer gpa.free(leaves);
    const root = next.tree.root();
    for (leaves) |leaf| {
        if (!leaf.free or leaf.binder) continue;
        const region = regionOf(root, leaf.span.start);
        var bound = false;
        for (leaves) |other| {
            if (other.binder and regionOf(root, other.span.start) == region) bound = true;
        }
        if (!bound) return error.IncompleteRename;
    }
}

fn mapped(part: []const u8, old: []const u8, new: []const u8) []const u8 {
    return if (std.mem.eql(u8, part, old)) new else part;
}

fn sameRef(before: symbol.Ref, after: symbol.Ref, old: []const u8, new: []const u8) bool {
    if (!std.mem.eql(u8, mapped(before.name, old, new), after.name)) return false;
    if (before.container.len != after.container.len) return false;
    for (before.container, after.container) |a, b| {
        if (!std.mem.eql(u8, mapped(a, old, new), b)) return false;
    }
    return before.accessor == after.accessor and before.is_static == after.is_static;
}

fn compareSymbols(gpa: Allocator, base: *Snapshot, next: *Snapshot, old: []const u8, new: []const u8) Error!usize {
    const before = try base.symbols();
    const after = next.symbols() catch |err| switch (err) {
        error.SourceHasErrors => return error.MutationSyntaxInvalid,
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (before.symbols.len != after.symbols.len) return error.AlphaMismatch;
    for (before.symbols) |b| {
        const b_hash = try alphaHash(gpa, base, b.declaration);
        var matched = false;
        for (after.symbols) |a| {
            if (!sameRef(b.ref, a.ref, old, new)) continue;
            if (std.mem.eql(u8, &b_hash, &try alphaHash(gpa, next, a.declaration))) matched = true;
        }
        if (!matched) return error.AlphaMismatch;
    }
    return before.symbols.len;
}

const testing = std.testing;

fn spansOf(gpa: Allocator, snapshot: *Snapshot, name: []const u8) ![]Span {
    const leaves = try leavesNamed(gpa, snapshot, name);
    defer gpa.free(leaves);
    const out = try gpa.alloc(Span, leaves.len);
    for (leaves, out) |leaf, *slot| slot.* = leaf.span;
    return out;
}

fn spanOf(source: []const u8, needle: []const u8, nth: usize, name: []const u8) Span {
    var from: usize = 0;
    var at: usize = 0;
    var seen: usize = 0;
    while (true) : (from = at + 1) {
        at = std.mem.indexOfPos(u8, source, from, needle).?;
        if (seen == nth) break;
        seen += 1;
    }
    const offset = std.mem.indexOf(u8, needle, name).?;
    const start: u32 = @intCast(at + offset);
    return .{ .start = start, .end = start + @as(u32, @intCast(name.len)) };
}

test "rename: every code occurrence is renamed, comments and strings stay, and every symbol keeps its alpha hash" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try test_util.snapshotOf(runtime, "// add is documented here\nexport function add(a: number): number { return a + 1; }\nexport function twice(x: number): number { const label = \"add\"; return add(add(x)); }\n");
    defer base.destroy();
    const spans = try spansOf(testing.allocator, base, "add");
    defer testing.allocator.free(spans);
    try testing.expectEqual(@as(usize, 3), spans.len);
    const renamed = try apply(testing.allocator, base, "add", "increment", spans);
    defer renamed.deinit(testing.allocator);
    try testing.expectEqualStrings("// add is documented here\nexport function increment(a: number): number { return a + 1; }\nexport function twice(x: number): number { const label = \"add\"; return increment(increment(x)); }\n", renamed.snapshot.source);
    try testing.expectEqual(@as(usize, 2), renamed.regions_checked);
    try testing.expectEqual(@as(usize, 2), renamed.symbols_checked);
}

test "rename: the alpha hash abstracts names but keeps which leaves share a name" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const a = try test_util.snapshotOf(runtime, "function f(x: number) { return g(x, y); }\n");
    defer a.destroy();
    const b = try test_util.snapshotOf(runtime, "function h(z: number) { return k(z, w); }\n");
    defer b.destroy();
    const c = try test_util.snapshotOf(runtime, "function h(z: number) { return k(z, z); }\n");
    defer c.destroy();
    const d = try test_util.snapshotOf(runtime, "function h(z: number) { return k(z, w) + 1; }\n");
    defer d.destroy();
    const whole = Span{ .start = 0, .end = 1000 };
    const ha = try alphaHash(testing.allocator, a, whole);
    try testing.expectEqual(ha, try alphaHash(testing.allocator, b, whole));
    try testing.expect(!std.mem.eql(u8, &ha, &try alphaHash(testing.allocator, c, whole)));
    try testing.expect(!std.mem.eql(u8, &ha, &try alphaHash(testing.allocator, d, whole)));
}

test "rename: leaving one occurrence behind in a renamed statement breaks its alpha hash" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const source = "function add(a: number): number { return a; }\nfunction g(): number { return add(add(1)); }\n";
    const base = try test_util.snapshotOf(runtime, source);
    defer base.destroy();
    const partial = [_]Span{ spanOf(source, "function add", 0, "add"), spanOf(source, "add(add", 0, "add") };
    try testing.expectError(error.AlphaMismatch, apply(testing.allocator, base, "add", "plus", &partial));
}

test "rename: an occurrence left free in an untouched statement is refused as incomplete" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const source = "function add(a: number): number { return a; }\nfunction g(): number { return add(1); }\n";
    const base = try test_util.snapshotOf(runtime, source);
    defer base.destroy();
    const only_declaration = [_]Span{spanOf(source, "function add", 0, "add")};
    try testing.expectError(error.IncompleteRename, apply(testing.allocator, base, "add", "plus", &only_declaration));
}

test "rename: a shadowing parameter of the same name in another function stays and is accepted" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const source = "function add(a: number): number { return a; }\nfunction g(add: number): number { return add; }\nfunction h(): number { return add(2); }\n";
    const base = try test_util.snapshotOf(runtime, source);
    defer base.destroy();
    const outer = [_]Span{ spanOf(source, "function add", 0, "add"), spanOf(source, "return add(2)", 0, "add") };
    const renamed = try apply(testing.allocator, base, "add", "plus", &outer);
    defer renamed.deinit(testing.allocator);
    try testing.expectEqualStrings("function plus(a: number): number { return a; }\nfunction g(add: number): number { return add; }\nfunction h(): number { return plus(2); }\n", renamed.snapshot.source);
}

test "rename: a shadowed inner name in the same statement as a renamed one is refused" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const source = "function add(a: number): number { return a; }\nfunction g(): number { const r = add(1); { const add = 2; return r + add; } }\n";
    const base = try test_util.snapshotOf(runtime, source);
    defer base.destroy();
    const outer = [_]Span{ spanOf(source, "function add", 0, "add"), spanOf(source, "= add(1)", 0, "add") };
    try testing.expectError(error.AlphaMismatch, apply(testing.allocator, base, "add", "plus", &outer));
}

test "rename: a span that is not an occurrence, a taken name, a bad name, a duplicate and a shorthand are refused" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const source = "// add\nfunction add(a: number): number { return a; }\nconst plus = 1;\n";
    const base = try test_util.snapshotOf(runtime, source);
    defer base.destroy();
    const spans = try spansOf(testing.allocator, base, "add");
    defer testing.allocator.free(spans);
    try testing.expectError(error.NotAnIdentifier, apply(testing.allocator, base, "add", "sum", &.{ spans[0], .{ .start = 3, .end = 6 } }));
    try testing.expectError(error.NameTaken, apply(testing.allocator, base, "add", "plus", spans));
    try testing.expectError(error.InvalidName, apply(testing.allocator, base, "add", "not-a-name", spans));
    try testing.expectError(error.DuplicateLocation, apply(testing.allocator, base, "add", "sum", &.{ spans[0], spans[0] }));

    const shorthand = try test_util.snapshotOf(runtime, "function add(): number { return 1; }\nconst api = { add };\n");
    defer shorthand.destroy();
    const short_spans = try spansOf(testing.allocator, shorthand, "add");
    defer testing.allocator.free(short_spans);
    try testing.expectError(error.ShorthandReference, apply(testing.allocator, shorthand, "add", "sum", short_spans));
}

test "rename: string mentions, eval, computed requires and constructed keys are dynamic access" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const cases = [_]struct { source: []const u8, member: bool, expected: ?Dynamic }{
        .{ .source = "function add() { return 1; }\nconst f = (globalThis as any)[\"add\"];\n", .member = false, .expected = .string_mention },
        .{ .source = "function add() { return 1; }\nconst t = `call add`;\n", .member = false, .expected = .string_mention },
        .{ .source = "function add() { return 1; }\neval(\"1\");\n", .member = false, .expected = .eval },
        .{ .source = "function add() { return 1; }\nconst f = new Function(\"return 1\");\n", .member = false, .expected = .eval },
        .{ .source = "function add() { return 1; }\nconst m = require(\"./\" + \"x\");\n", .member = false, .expected = .computed_module },
        .{ .source = "function add() { return 1; }\nconst o: any = {};\nconst v = o[\"a\" + \"dd\"];\n", .member = false, .expected = .computed_member },
        .{ .source = "function add() { return 1; }\nconst o: any = {};\nconst k = \"x\";\nconst v = o[k];\n", .member = true, .expected = .computed_member },
        .{ .source = "function add() { return 1; }\nconst o: any = {};\nconst k = \"x\";\nconst v = o[k] + o[0];\nconst m = require(\"./m\");\n// add in a comment\nconst t = `${add()}`;\n", .member = false, .expected = null },
    };
    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.source});
        const snapshot = try test_util.snapshotOf(runtime, case.source);
        defer snapshot.destroy();
        try testing.expectEqual(case.expected, dynamicAccess(snapshot, "add", case.member));
    }
}

test "rename: an export statement or an export clause marks the name exported" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const direct = try test_util.snapshotOf(runtime, "export function add() { return 1; }\n");
    defer direct.destroy();
    const clause = try test_util.snapshotOf(runtime, "function add() { return 1; }\nexport { add };\n");
    defer clause.destroy();
    const local = try test_util.snapshotOf(runtime, "function add() { return 1; }\nexport function g() { return add(); }\n");
    defer local.destroy();
    try testing.expect(try exportedName(testing.allocator, direct, "add"));
    try testing.expect(try exportedName(testing.allocator, clause, "add"));
    try testing.expect(!try exportedName(testing.allocator, local, "add"));
    try testing.expectEqual(@as(usize, 1), try binderCount(testing.allocator, local, "add"));
}
