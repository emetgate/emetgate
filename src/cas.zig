const std = @import("std");
const ts = @import("tree_sitter.zig");
const symbol = @import("symbol.zig");
const Snapshot = @import("loader.zig").Snapshot;
const test_util = @import("test_util.zig");

const Allocator = std.mem.Allocator;
const Span = symbol.Span;

pub const Error = error{
    SourceHasErrors,
    SymbolNotFound,
    AmbiguousSymbol,
    HashMismatch,
    MutationSyntaxInvalid,
    BodyEscape,
} || Allocator.Error || ts.Error;

pub const Mutation = struct {
    ref: symbol.Ref,
    expected_hash: symbol.Hash,
    new_body: []const u8,
};

pub const Applied = struct {
    snapshot: *Snapshot,
    hash: symbol.Hash,
};

const utf8_bom = "\xEF\xBB\xBF";

pub fn normalizeBody(body: []const u8) []const u8 {
    const without_bom = if (std.mem.startsWith(u8, body, utf8_bom)) body[utf8_bom.len..] else body;
    return std.mem.trim(u8, without_bom, " \t\r\n");
}

pub fn apply(base: *Snapshot, mutation: Mutation) Error!Applied {
    const new_body = normalizeBody(mutation.new_body);
    const before = try base.symbols();
    const target = try before.resolve(mutation.ref);
    if (!std.mem.eql(u8, &target.hash, &mutation.expected_hash)) return error.HashMismatch;

    const cut: Span = .{ .start = target.body.startByte(), .end = target.body.endByte() };
    const source = try std.mem.concat(base.runtime.gpa, u8, &.{ base.source[0..cut.start], new_body, base.source[cut.end..] });
    const next = try Snapshot.fromSource(base.runtime, source);
    errdefer next.destroy();
    if (next.tree.root().hasError()) return error.MutationSyntaxInvalid;

    const after = next.symbols() catch |err| switch (err) {
        error.SourceHasErrors => return error.MutationSyntaxInvalid,
        error.OutOfMemory => return error.OutOfMemory,
    };

    const slot: Span = .{ .start = cut.start, .end = cut.start + @as(u32, @intCast(new_body.len)) };
    const patched_target = after.resolve(mutation.ref) catch return error.BodyEscape;
    try expectExactSlot(patched_target.body, slot);
    try expectUntouchedOutside(before.*, after.*, cut, slot);

    return .{ .snapshot = next, .hash = patched_target.hash };
}

fn expectExactSlot(body: ts.Node, slot: Span) error{BodyEscape}!void {
    if (body.startByte() != slot.start or body.endByte() != slot.end) return error.BodyEscape;
    if (isComment(edgeToken(body, .first)) or isComment(edgeToken(body, .last))) return error.BodyEscape;
}

fn edgeToken(node: ts.Node, comptime side: enum { first, last }) ts.Node {
    var current = node;
    while (current.childCount() > 0) {
        current = current.child(if (side == .first) 0 else current.childCount() - 1).?;
    }
    return current;
}

fn isComment(node: ts.Node) bool {
    return std.mem.eql(u8, "comment", node.kind());
}

fn expectUntouchedOutside(before: symbol.Table, after: symbol.Table, cut: Span, slot: Span) error{BodyEscape}!void {
    var outside_before: usize = 0;
    for (before.symbols) |old| {
        if (!isOutside(old.declaration, cut)) continue;
        outside_before += 1;
        if (!hasTwinOutside(after, old, slot)) return error.BodyEscape;
    }
    var outside_after: usize = 0;
    for (after.symbols) |new| {
        if (isOutside(new.declaration, slot)) outside_after += 1;
    }
    if (outside_before != outside_after) return error.BodyEscape;
}

fn hasTwinOutside(table: symbol.Table, wanted: symbol.Symbol, slot: Span) bool {
    for (table.symbols) |candidate| {
        if (!isOutside(candidate.declaration, slot)) continue;
        if (candidate.ref.eql(wanted.ref) and std.mem.eql(u8, &candidate.hash, &wanted.hash)) return true;
    }
    return false;
}

fn isOutside(span: Span, region: Span) bool {
    return span.end <= region.start or span.start >= region.end;
}

const testing = std.testing;

const HashSource = enum { current, stale };

fn currentHash(snapshot: *Snapshot, ref: symbol.Ref) !symbol.Hash {
    return (try (try snapshot.symbols()).resolve(ref)).hash;
}

fn mutate(base: *Snapshot, ref_text: []const u8, new_body: []const u8, hash: HashSource) !Applied {
    const ref = try symbol.Ref.parse(testing.allocator, ref_text);
    defer ref.deinit(testing.allocator);
    const expected = switch (hash) {
        .current => currentHash(base, ref) catch std.mem.zeroes(symbol.Hash),
        .stale => symbol.hashOf("stale view"),
    };
    return apply(base, .{ .ref = ref, .expected_hash = expected, .new_body = new_body });
}

fn hashOfRef(snapshot: *Snapshot, ref_text: []const u8) !symbol.Hash {
    const ref = try symbol.Ref.parse(testing.allocator, ref_text);
    defer ref.deinit(testing.allocator);
    return currentHash(snapshot, ref);
}

test "replaces exactly one body in memory and leaves the file on disk untouched" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const doc = try test_util.loadFixture(runtime,"functions.ts");
    defer doc.destroy();

    const old_body = "{\n  return a + b;\n}";
    const new_body = "{\n  return a - b;\n}";
    const patched = try mutate(doc, "add", new_body, .current);
    defer patched.snapshot.destroy();
    const out = patched.snapshot.source;

    const at = std.mem.indexOf(u8, doc.source, old_body) orelse return error.FixtureChanged;
    try testing.expectEqualStrings(doc.source[0..at], out[0..at]);
    try testing.expectEqualStrings(new_body, out[at..][0..new_body.len]);
    try testing.expectEqualStrings(doc.source[at + old_body.len ..], out[at + new_body.len ..]);
    try testing.expect(!patched.snapshot.tree.root().hasError());
    try testing.expectEqual(try hashOfRef(patched.snapshot, "add"), patched.hash);

    const on_disk = try std.Io.Dir.cwd().readFileAlloc(testing.io, test_util.fixture_dir ++ "functions.ts", testing.allocator, .unlimited);
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(doc.source, on_disk);
}

test "a source with syntax errors is refused before resolution" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const doc = try test_util.loadFixture(runtime,"broken.ts");
    defer doc.destroy();

    try testing.expectError(error.SourceHasErrors, mutate(doc, "broken", "{ return a; }", .current));

    const broken_sources = [_][]const u8{
        "export function broken(a: number {\n  return a;\n}\nfunction ok() { return 1; }\n",
        "function ok() { return 1; }\nfunction open() {\n  return 2;\n",
        "function ok() { return 1; }\nconst s = `unterminated ${ok()}\n",
        "function ok() { return (1; }\n",
        "function ok() { return 1; }}\n",
    };
    for (broken_sources) |source| {
        errdefer std.debug.print("accepted broken source: \"{s}\"\n", .{source});
        const base = try test_util.snapshotOf(runtime,source);
        defer base.destroy();
        try testing.expectError(error.SourceHasErrors, mutate(base, "ok", "{ return 2; }", .current));
    }
}

test "error precedence: each check wins over every later one" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const broken = try test_util.snapshotOf(runtime,"function ok() { return 1; }\nfunction bad( {\n");
    defer broken.destroy();
    const valid = try test_util.snapshotOf(runtime,"function dup() {}\nfunction dup() {}\nfunction f() { return 1; }\nfunction g() { return 2; }\n");
    defer valid.destroy();

    try testing.expectError(error.SourceHasErrors, mutate(broken, "missing", "{ oops", .stale));
    try testing.expectError(error.SymbolNotFound, mutate(valid, "missing", "{ oops", .stale));
    try testing.expectError(error.AmbiguousSymbol, mutate(valid, "dup", "{ oops", .stale));
    try testing.expectError(error.HashMismatch, mutate(valid, "f", "{ oops", .stale));
    try testing.expectError(error.MutationSyntaxInvalid, mutate(valid, "f", "{ } function evil() { oops", .current));
    try testing.expectError(error.BodyEscape, mutate(valid, "f", "{ } function evil() {}", .current));
}

test "unknown, under-qualified and ambiguous targets are refused" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try test_util.snapshotOf(runtime,
        \\function dup() {}
        \\function dup() {}
        \\class Box { get size(): number { return 1; } set size(v: number) {} }
    );
    defer base.destroy();

    try testing.expectError(error.AmbiguousSymbol, mutate(base, "dup", "{ return 1; }", .current));
    try testing.expectError(error.SymbolNotFound, mutate(base, "nope", "{}", .current));
    try testing.expectError(error.SymbolNotFound, mutate(base, "Box.size", "{ return 2; }", .current));
    try testing.expectError(error.SymbolNotFound, mutate(base, "Box.size@static@get", "{ return 2; }", .current));
}

test "a stale hash is refused, an unrelated edit elsewhere is not" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const original = try test_util.snapshotOf(runtime,"function f() { return 1; }\nfunction g() { return 2; }\n");
    defer original.destroy();
    const elsewhere = try test_util.snapshotOf(runtime,"function f() { return 1; }\nfunction g() { return 20; }\n");
    defer elsewhere.destroy();

    try testing.expectError(error.HashMismatch, mutate(original, "f", "{ return 3; }", .stale));

    const ref = try symbol.Ref.parse(testing.allocator, "f");
    defer ref.deinit(testing.allocator);
    const seen = try currentHash(original, ref);
    const patched = try apply(elsewhere, .{ .ref = ref, .expected_hash = seen, .new_body = "{ return 3; }" });
    defer patched.snapshot.destroy();
    try testing.expectEqualStrings("function f() { return 3; }\nfunction g() { return 20; }\n", patched.snapshot.source);
}

test "broken replacement bodies are refused and never spliced" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const doc = try test_util.loadFixture(runtime,"functions.ts");
    defer doc.destroy();

    const broken_bodies = [_][]const u8{
        "{ return a + ; }",
        "{\n  return a;\n",
        "return a;",
        "{ return a; }}",
        "{ return (a; }",
    };
    for (broken_bodies) |body| {
        errdefer std.debug.print("accepted broken body: \"{s}\"\n", .{body});
        try testing.expectError(error.MutationSyntaxInvalid, mutate(doc, "add", body, .current));
    }
}

test "a body that parses but spills outside its slot is a BodyEscape" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try test_util.snapshotOf(runtime,"function f() { return 1; }\nfunction g() { return 2; }\n");
    defer base.destroy();

    const escapes = [_][]const u8{
        "{ } function evil() { return 0; }",
        "{ return 1; } // trailing",
        "{ return 1; } /* trailing */",
        "/* leading */ { return 1; }",
        "{ return 1; }\nfunction f() { return 3; }",
        "",
    };
    for (escapes) |body| {
        errdefer std.debug.print("accepted escaping body: \"{s}\"\n", .{body});
        try testing.expectError(error.BodyEscape, mutate(base, "f", body, .current));
    }
}

test "only the addressed accessor changes when getter and setter share a name" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const doc = try test_util.loadFixture(runtime,"functions.ts");
    defer doc.destroy();

    const getter_before = try hashOfRef(doc, "Repository.label@get");
    const setter_before = try hashOfRef(doc, "Repository.label@set");

    const patched = try mutate(doc, "Repository.label@set", "{\n    console.info(value);\n  }", .current);
    defer patched.snapshot.destroy();

    try testing.expectEqual(getter_before, try hashOfRef(patched.snapshot, "Repository.label@get"));
    try testing.expect(!std.mem.eql(u8, &setter_before, &patched.hash));
    try testing.expect(std.mem.indexOf(u8, patched.snapshot.source, "set label(value: string) {\n    console.info(value);\n  }") != null);
}

test "an expression-bodied arrow accepts an expression or a block" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try test_util.snapshotOf(runtime,"export const square = (n: number) => n * n;\n");
    defer base.destroy();

    const as_expression = try mutate(base, "square", "n ** 2", .current);
    defer as_expression.snapshot.destroy();
    try testing.expectEqualStrings("export const square = (n: number) => n ** 2;\n", as_expression.snapshot.source);

    const as_block = try mutate(base, "square", "{ return n * n; }", .current);
    defer as_block.snapshot.destroy();
    try testing.expectEqualStrings("export const square = (n: number) => { return n * n; };\n", as_block.snapshot.source);
}

test "outside-symbol lock rejects a renamed, re-hashed, added or removed neighbour" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const before_snapshot = try test_util.snapshotOf(runtime,"function f() { return 1; }\nfunction g() { return 2; }\n");
    defer before_snapshot.destroy();
    const before = try before_snapshot.symbols();
    const f_body = (try before.resolve(.{ .name = "f" })).body;
    const cut: Span = .{ .start = f_body.startByte(), .end = f_body.endByte() };

    const same_shape = [_][]const u8{
        "function f() { return 1; }\nfunction h() { return 2; }\n",
        "function f() { return 1; }\nfunction g() { return 3; }\n",
        "function f() { return 1; }\nfunction g() { return 2; }\nfunction extra() {}\n",
        "function f() { return 1; }\n",
    };
    for (same_shape) |source| {
        errdefer std.debug.print("lock accepted: \"{s}\"\n", .{source});
        const after_snapshot = try test_util.snapshotOf(runtime,source);
        defer after_snapshot.destroy();
        try testing.expectError(error.BodyEscape, expectUntouchedOutside(before.*, (try after_snapshot.symbols()).*, cut, cut));
    }

    try expectUntouchedOutside(before.*, before.*, cut, cut);
}

test "regression: attacks from the adversarial review stay refused" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);

    const Attack = struct {
        name: []const u8,
        source: []const u8,
        ref: []const u8,
        body: []const u8,
        expected: anyerror,
    };
    const arrow_source = "export const square = (n: number) => n * n;\nafter();\n";
    const class_source = "class C {\n  a() { return 1; }\n  b() { return 2; }\n}\n";
    const object_source = "const o = {\n  m() { return 1; },\n  n() { return 2; },\n};\n";
    const attacks = [_]Attack{
        .{ .name = "static injection into the next member", .source = class_source, .ref = "C.a", .body = "{ } static", .expected = error.BodyEscape },
        .{ .name = "extra property injected into an object literal", .source = object_source, .ref = "o.m", .body = "{ return 1; }, z() { return 3; }", .expected = error.BodyEscape },
        .{ .name = "statement smuggled after an arrow expression", .source = arrow_source, .ref = "square", .body = "n; evil()", .expected = error.BodyEscape },
        .{ .name = "comma expression appended to an arrow body", .source = arrow_source, .ref = "square", .body = "n * n, sideEffect()", .expected = error.MutationSyntaxInvalid },
        .{ .name = "U+2028 line separator after an arrow body", .source = arrow_source, .ref = "square", .body = "n * n\u{2028}", .expected = error.BodyEscape },
        .{ .name = "U+2029 paragraph separator after an arrow body", .source = arrow_source, .ref = "square", .body = "n * n\u{2029}", .expected = error.BodyEscape },
        .{ .name = "trailing block comment on an arrow body", .source = arrow_source, .ref = "square", .body = "n * n /* c */", .expected = error.BodyEscape },
        .{ .name = "NUL byte inside a block body", .source = class_source, .ref = "C.a", .body = "{ return 1;\x00 }", .expected = error.MutationSyntaxInvalid },
        .{ .name = "NUL byte after an arrow body", .source = arrow_source, .ref = "square", .body = "n * n\x00", .expected = error.MutationSyntaxInvalid },
    };
    for (attacks) |attack| {
        errdefer std.debug.print("attack not refused as expected: {s}\n", .{attack.name});
        const base = try test_util.snapshotOf(runtime,attack.source);
        defer base.destroy();
        try testing.expectError(attack.expected, mutate(base, attack.ref, attack.body, .current));
    }
}

test "replacement bodies are normalised: a BOM and surrounding whitespace are ignored" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try test_util.snapshotOf(runtime,"function f() { return 1; }\n");
    defer base.destroy();

    const bodies = [_][]const u8{
        "{ return 2; }\n",
        "\xEF\xBB\xBF{ return 2; }\r\n",
        "\n\t { return 2; }  \n\n",
    };
    for (bodies) |body| {
        errdefer std.debug.print("body not normalised: \"{s}\"\n", .{body});
        const patched = try mutate(base, "f", body, .current);
        defer patched.snapshot.destroy();
        try testing.expectEqualStrings("function f() { return 2; }\n", patched.snapshot.source);
    }
    try testing.expectError(error.BodyEscape, mutate(base, "f", " \r\n\t", .current));
}

test "mutating one declarator leaves a sibling declarator's hash intact" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try test_util.snapshotOf(runtime,"export const a = () => 1, b = () => 2;\n");
    defer base.destroy();

    const b_before = try hashOfRef(base, "b");
    const patched = try mutate(base, "a", "10", .current);
    defer patched.snapshot.destroy();
    try testing.expectEqualStrings("export const a = () => 10, b = () => 2;\n", patched.snapshot.source);
    try testing.expectEqual(b_before, try hashOfRef(patched.snapshot, "b"));
}

test "chained mutations: the returned hash is the next expected hash" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try test_util.snapshotOf(runtime,"function f() { return 1; }\n");
    defer base.destroy();

    const first = try mutate(base, "f", "{ return 2; }", .current);
    defer first.snapshot.destroy();

    const ref = try symbol.Ref.parse(testing.allocator, "f");
    defer ref.deinit(testing.allocator);
    const second = try apply(first.snapshot, .{ .ref = ref, .expected_hash = first.hash, .new_body = "{ return 3; }" });
    defer second.snapshot.destroy();
    try testing.expectEqualStrings("function f() { return 3; }\n", second.snapshot.source);

    try testing.expectError(error.HashMismatch, apply(second.snapshot, .{ .ref = ref, .expected_hash = first.hash, .new_body = "{ return 4; }" }));
}

test "ownership: every failed apply leaves exactly the base alive, a success adds one snapshot" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try test_util.snapshotOf(runtime,"function dup() {}\nfunction dup() {}\nfunction f() { return 1; }\n");
    defer base.destroy();

    const Failure = struct { ref: []const u8, body: []const u8, hash: HashSource };
    const failures = [_]Failure{
        .{ .ref = "nope", .body = "{}", .hash = .current },
        .{ .ref = "dup", .body = "{}", .hash = .current },
        .{ .ref = "f", .body = "{ return 2; }", .hash = .stale },
        .{ .ref = "f", .body = "{ return (2; }", .hash = .current },
        .{ .ref = "f", .body = "{ } function evil() {}", .hash = .current },
    };
    for (failures) |failure| {
        errdefer std.debug.print("leaked or freed a snapshot on: {s} {s}\n", .{ failure.ref, failure.body });
        try testing.expect(std.meta.isError(mutate(base, failure.ref, failure.body, failure.hash)));
        try testing.expectEqual(@as(usize, 1), runtime.live_snapshots);
    }

    const patched = try mutate(base, "f", "{ return 2; }", .current);
    try testing.expectEqual(@as(usize, 2), runtime.live_snapshots);
    patched.snapshot.destroy();
    try testing.expectEqual(@as(usize, 1), runtime.live_snapshots);
}

test "ownership: a patched snapshot owns its memory and outlives the base it came from" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try test_util.snapshotOf(runtime,"function f() { return 1; }\nfunction g() { return 2; }\n");
    const patched = try mutate(base, "f", "{ return 10; }", .current);
    base.destroy();
    defer patched.snapshot.destroy();

    try testing.expectEqualStrings("function f() { return 10; }\nfunction g() { return 2; }\n", patched.snapshot.source);
    try testing.expectEqual(patched.hash, try hashOfRef(patched.snapshot, "f"));
    const second = try mutate(patched.snapshot, "g", "{ return 20; }", .current);
    defer second.snapshot.destroy();
    try testing.expectEqualStrings("function f() { return 10; }\nfunction g() { return 20; }\n", second.snapshot.source);
}
