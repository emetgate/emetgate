const std = @import("std");
const emetgate = @import("emetgate");
const facts = emetgate.facts;
const facts_extract = emetgate.facts_extract;
const rename = emetgate.rename;
const scope = emetgate.scope;
const symbol = emetgate.symbol;
const test_util = emetgate.test_util;
const Snapshot = emetgate.loader.Snapshot;
const Runtime = emetgate.runtime.Runtime;

const testing = std.testing;
const Span = symbol.Span;
const python = emetgate.lang_registry.forPath("a.py").?;

const Extracted = struct {
    arena: std.heap.ArenaAllocator,
    snapshot: *Snapshot,
    facts: facts.FileFacts,

    fn deinit(self: *Extracted) void {
        self.snapshot.destroy();
        self.arena.deinit();
    }

    fn def(self: *const Extracted, qname: []const u8) !u32 {
        for (self.facts.defs, 0..) |d, i| {
            if (std.mem.eql(u8, d.qname, qname)) return @intCast(i);
        }
        std.debug.print("no def {s}\n", .{qname});
        return error.DefNotFound;
    }

    fn ref(self: *const Extracted, kind: facts.RefKind, name: []const u8, nth: usize) !facts.Ref {
        var seen: usize = 0;
        for (self.facts.refs) |r| {
            if (r.kind != kind or !std.mem.eql(u8, r.name, name)) continue;
            if (seen == nth) return r;
            seen += 1;
        }
        std.debug.print("no {t} ref {s} #{d}\n", .{ kind, name, nth });
        return error.RefNotFound;
    }
};

fn snapshotOf(runtime: *Runtime, source: []const u8) !*Snapshot {
    return Snapshot.fromSource(runtime, python, try testing.allocator.dupe(u8, source));
}

test "python facts: a call to a module function binds to its definition and is owned by the caller" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const snapshot = try snapshotOf(runtime, "def helper(x):\n    return x + 1\n\ndef main():\n    return helper(5)\n");
    defer snapshot.destroy();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const x: Extracted = .{ .arena = arena, .snapshot = snapshot, .facts = try facts_extract.extract(arena.allocator(), snapshot) };

    const helper = try x.def("helper");
    const main = try x.def("main");
    const r = try x.ref(.call, "helper", 0);
    try testing.expectEqual(facts.Target{ .local = helper }, r.target);
    try testing.expectEqual(main, r.from);
    try testing.expectEqual(facts.DefKind.module, x.facts.defs[0].kind);
    try testing.expectEqual(facts.DefKind.function, x.facts.defs[helper].kind);
}

test "python facts: a method is a def under its class and a self-call targets that class" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const snapshot = try snapshotOf(runtime, "class S:\n    def run(self):\n        return self.helper()\n\n    def helper(self):\n        return 2\n");
    defer snapshot.destroy();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const x: Extracted = .{ .arena = arena, .snapshot = snapshot, .facts = try facts_extract.extract(arena.allocator(), snapshot) };

    const class = try x.def("S");
    const run = try x.def("S.run");
    try testing.expectEqual(facts.DefKind.class, x.facts.defs[class].kind);
    try testing.expectEqual(class, x.facts.defs[run].parent);
    const r = try x.ref(.call, "helper", 0);
    try testing.expectEqual(facts.Target{ .member_of_def = class }, r.target);
    try testing.expect(!r.static);
}

test "python facts: an imported name is a binding and a call to it targets that binding" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const snapshot = try snapshotOf(runtime, "from mod import helper\n\ndef use():\n    return helper(10)\n");
    defer snapshot.destroy();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const x: Extracted = .{ .arena = arena, .snapshot = snapshot, .facts = try facts_extract.extract(arena.allocator(), snapshot) };

    try testing.expectEqual(@as(usize, 1), x.facts.specs.len);
    try testing.expectEqualStrings("mod", x.facts.specs[0].text);
    try testing.expectEqual(@as(usize, 1), x.facts.bindings.len);
    try testing.expectEqualStrings("helper", x.facts.bindings[0].imported);
    const r = try x.ref(.call, "helper", 0);
    try testing.expectEqual(facts.Target{ .binding = 0 }, r.target);
}

test "python facts: an attribute property and a keyword argument name are not references" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const snapshot = try snapshotOf(runtime, "def total():\n    return 1\n\ndef go(obj):\n    return obj.total(total=total())\n");
    defer snapshot.destroy();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const x: Extracted = .{ .arena = arena, .snapshot = snapshot, .facts = try facts_extract.extract(arena.allocator(), snapshot) };

    const total = try x.def("total");
    var resolved: usize = 0;
    for (x.facts.refs) |r| {
        if (std.mem.eql(u8, r.name, "total") and r.target == .local and r.target.local == total) resolved += 1;
    }
    try testing.expectEqual(@as(usize, 1), resolved);
}

fn moduleSpans(gpa: std.mem.Allocator, snapshot: *Snapshot, name: []const u8) ![]Span {
    const resolution = try scope.resolveName(gpa, snapshot, name);
    defer resolution.deinit(gpa);
    var target: ?usize = null;
    for (resolution.binders, 0..) |b, i| {
        if (std.mem.eql(u8, b.scope.kind, "module")) target = i;
    }
    var out: std.ArrayList(Span) = .empty;
    try out.append(gpa, resolution.binders[target.?].span);
    for (resolution.uses) |u| {
        if (u.binder == target) try out.append(gpa, u.span);
    }
    return out.toOwnedSlice(gpa);
}

test "python rename: a module function and all its references are renamed together" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try snapshotOf(runtime, "def greet(name):\n    return name\n\ndef caller():\n    return greet(greet(\"x\"))\n");
    defer base.destroy();
    const spans = try moduleSpans(testing.allocator, base, "greet");
    defer testing.allocator.free(spans);
    try testing.expectEqual(@as(usize, 3), spans.len);
    const renamed = try rename.apply(testing.allocator, base, "greet", "hello", spans);
    defer renamed.deinit(testing.allocator);
    try testing.expectEqualStrings("def hello(name):\n    return name\n\ndef caller():\n    return hello(hello(\"x\"))\n", renamed.snapshot.source);
}

test "python rename: a same-named method and attribute are left alone when the module name is renamed" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try snapshotOf(runtime, "def run():\n    return 1\n\nclass S:\n    def run(self):\n        return self.run()\n");
    defer base.destroy();
    const spans = try moduleSpans(testing.allocator, base, "run");
    defer testing.allocator.free(spans);
    try testing.expectEqual(@as(usize, 1), spans.len);
    const renamed = try rename.apply(testing.allocator, base, "run", "start", spans);
    defer renamed.deinit(testing.allocator);
    try testing.expectEqualStrings("def start():\n    return 1\n\nclass S:\n    def run(self):\n        return self.run()\n", renamed.snapshot.source);
}

test "python rename: a shadowing parameter of the same name in another function is untouched" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try snapshotOf(runtime, "def add(a):\n    return a\n\ndef g(add):\n    return add\n\ndef h():\n    return add(2)\n");
    defer base.destroy();
    const spans = try moduleSpans(testing.allocator, base, "add");
    defer testing.allocator.free(spans);
    try testing.expectEqual(@as(usize, 2), spans.len);
    const renamed = try rename.apply(testing.allocator, base, "add", "plus", spans);
    defer renamed.deinit(testing.allocator);
    try testing.expectEqualStrings("def plus(a):\n    return a\n\ndef g(add):\n    return add\n\ndef h():\n    return plus(2)\n", renamed.snapshot.source);
}

fn extractOf(runtime: *Runtime, source: []const u8) !Extracted {
    const snapshot = try snapshotOf(runtime, source);
    errdefer snapshot.destroy();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    const extracted = try facts_extract.extract(arena.allocator(), snapshot);
    return .{ .arena = arena, .snapshot = snapshot, .facts = extracted };
}

test "python facts: a receiver reaches its class from a nested function, a classmethod receiver is static and a staticmethod has none" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var x = try extractOf(runtime, "class S:\n    def run(self):\n        def inner():\n            return self.one()\n        return inner\n\n    @classmethod\n    def make(cls):\n        return cls.two()\n\n    @staticmethod\n    def plain(other):\n        return other.three()\n\ndef free(self):\n    return self.four()\n");
    defer x.deinit();

    const class = try x.def("S");
    const one = try x.ref(.call, "one", 0);
    try testing.expectEqual(facts.Target{ .member_of_def = class }, one.target);
    try testing.expect(!one.static);
    const two = try x.ref(.call, "two", 0);
    try testing.expectEqual(facts.Target{ .member_of_def = class }, two.target);
    try testing.expect(two.static);
    try testing.expect((try x.ref(.call, "three", 0)).target == .unresolved);
    try testing.expect((try x.ref(.call, "four", 0)).target == .unresolved);
}

test "python facts: a receiver is only the first parameter of a method directly in the class body" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var x = try extractOf(runtime, "class S:\n    def run(self, other):\n        return other.one()\n\n    if True:\n        def odd(self):\n            return self.two()\n\nclass T:\n    x = lambda self: self.three()\n\nclass U(lambda self: self.five()):\n    pass\n");
    defer x.deinit();

    try testing.expect((try x.ref(.call, "one", 0)).target == .unresolved);
    try testing.expect((try x.ref(.call, "two", 0)).target == .unresolved);
    try testing.expect((try x.ref(.call, "three", 0)).target == .unresolved);
    try testing.expect((try x.ref(.call, "five", 0)).target == .unresolved);
}

test "python facts: test functions and test classes are test blocks, and conftest.py is a test file" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var x = try extractOf(runtime, "def test_add():\n    assert add(1) == 2\n\nclass TestMath:\n    def test_sub(self):\n        assert sub(2) == 1\n\n    def helper(self):\n        return 0\n\ndef build():\n    return 1\n");
    defer x.deinit();

    const blocks = x.facts.tests;
    try testing.expectEqual(@as(usize, 3), blocks.len);
    try testing.expectEqualStrings("test_add", blocks[0].title);
    try testing.expectEqual(facts.none, blocks[0].parent);
    try testing.expectEqualStrings("TestMath", blocks[1].title);
    try testing.expectEqualStrings("test_sub", blocks[2].title);
    try testing.expectEqual(@as(u32, 1), blocks[2].parent);

    const table = python.facts.?;
    try testing.expect(emetgate.facts_tests.isTestPath(table, "conftest.py"));
    try testing.expect(emetgate.facts_tests.isTestPath(table, "src/pkg/conftest.py"));
    try testing.expect(!emetgate.facts_tests.isTestPath(table, "src/pkg/myconftest.py"));
    try testing.expect(!emetgate.facts_tests.isTestPath(table, "src/pkg/config.py"));
}

fn wordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn shapeOf(runtime: *Runtime, source: []const u8, name: []const u8) ![]u8 {
    const snapshot = try snapshotOf(runtime, source);
    defer snapshot.destroy();
    const resolution = try scope.resolveName(testing.allocator, snapshot, name);
    defer resolution.deinit(testing.allocator);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    var letters: std.ArrayList(usize) = .empty;
    defer letters.deinit(testing.allocator);
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, source, from, name)) |at| {
        from = at + name.len;
        if (at != 0 and wordByte(source[at - 1])) continue;
        if (from < source.len and wordByte(source[from])) continue;
        const span: Span = .{ .start = @intCast(at), .end = @intCast(from) };
        const binder: usize = if (resolution.binderAt(span)) |b| b else if (resolution.useAt(span)) |u| u.binder orelse {
            try out.append(testing.allocator, '?');
            continue;
        } else {
            try out.append(testing.allocator, '.');
            continue;
        };
        const letter = std.mem.indexOfScalar(usize, letters.items, binder) orelse blk: {
            try letters.append(testing.allocator, binder);
            break :blk letters.items.len - 1;
        };
        try out.append(testing.allocator, @intCast('a' + letter));
    }
    return out.toOwnedSlice(testing.allocator);
}

fn expectShape(runtime: *Runtime, source: []const u8, name: []const u8, want: []const u8) !void {
    const got = try shapeOf(runtime, source, name);
    defer testing.allocator.free(got);
    if (!std.mem.eql(u8, got, want)) std.debug.print("{s}: want {s}, got {s}\n", .{ name, want, got });
    try testing.expectEqualStrings(want, got);
}

fn expectImport(runtime: *Runtime, source: []const u8, name: []const u8, want: bool) !void {
    const snapshot = try snapshotOf(runtime, source);
    defer snapshot.destroy();
    const resolution = try scope.resolveName(testing.allocator, snapshot, name);
    defer resolution.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), resolution.binders.len);
    try testing.expectEqual(want, resolution.binders[0].import);
}

fn expectSameAsEachName(runtime: *Runtime, source: []const u8) !void {
    const snapshot = try snapshotOf(runtime, source);
    defer snapshot.destroy();
    const every = try scope.resolveAll(testing.allocator, snapshot);
    defer every.deinit(testing.allocator);
    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer names.deinit(testing.allocator);
    for (every.binder_names) |name| try names.put(testing.allocator, name, {});
    for (every.use_names) |name| try names.put(testing.allocator, name, {});
    var it = names.keyIterator();
    while (it.next()) |name| {
        const alone = try scope.resolveName(testing.allocator, snapshot, name.*);
        defer alone.deinit(testing.allocator);
        var binders: usize = 0;
        for (every.binders, every.binder_names) |b, n| {
            if (!std.mem.eql(u8, n, name.*)) continue;
            binders += 1;
            const i = alone.binderAt(b.span) orelse return error.BinderMissing;
            try testing.expect(alone.binders[i].scope.same(b.scope));
        }
        try testing.expectEqual(alone.binders.len, binders);
        var uses: usize = 0;
        for (every.uses, every.use_names) |u, n| {
            if (!std.mem.eql(u8, n, name.*)) continue;
            uses += 1;
            const lone = alone.useAt(u.span) orelse return error.UseMissing;
            const want: ?Span = if (lone.binder) |i| alone.binders[i].span else null;
            const got: ?Span = if (u.binder) |i| every.binders[i].span else null;
            try testing.expectEqual(want, got);
        }
        try testing.expectEqual(alone.uses.len, uses);
    }
}

const global_source = "x = 1\ndef f():\n    global x\n    x = 2\n    return x\n\ndef g():\n    x = 3\n    return x\n";
const nonlocal_source = "def outer():\n    n = 0\n    def inner():\n        nonlocal n\n        n = 1\n    def other():\n        n = 2\n        return n\n    return n\n";
const class_source = "k = 0\nclass C:\n    k = 1\n    j = k\n    def m(self, d=k):\n        return k\n    g = lambda: k\n    h = [k for _ in r]\nBase = 1\nclass D(Base):\n    Base = 2\n";
const comprehension_source = "y = 1\nr = [y for y in ys if y]\ns = {y: 1 for y in ys}\ng = (y for y in ys)\ny\n";
const lambda_source = "q = 1\nf = lambda q: q\nq\nz = 1\nh = lambda z=z: z\n";
const default_source = "d = 1\ndef f(d=d):\n    return d\n";
const with_source = "with open(p) as fh:\n    fh.read()\ntry:\n    pass\nexcept E as err:\n    err\n";
const walrus_source = "def f():\n    if (n := 10) > 5:\n        n\n    [(w := x) for x in xs]\n    return w\n";
const unpack_source = "a, *rest = c\nfor i, (j, k) in z:\n    k\n[a, b] = rest\nrest\n";
const match_source = "match v:\n    case [first, *tail]:\n        tail\n    case Point(x=0, y=yy) as whole:\n        whole, yy, x\n    case cap:\n        cap\n    case Color.RED:\n        RED\n    case {\"k\": kv, **others}:\n        kv, others\n    case mod.Klass(z=Color.GREEN):\n        pass\n";
const import_source = "path = 1\nimport os.path\nimport a.b as c\nfrom m.n import q\nfrom . import r\nfrom .s import t\nos, path, c, q, r, t, n, s\ndef f():\n    import json\n    return json\njson\ndef g():\n    import u as al\n    return al\nal\n";

test "python scope: global and nonlocal statements make an assignment rebind the outer name" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    try expectShape(runtime, global_source, "x", "aaaabb");
    try expectShape(runtime, nonlocal_source, "n", "aaabba");
    try expectSameAsEachName(runtime, global_source);
    try expectSameAsEachName(runtime, nonlocal_source);
}

test "python scope: a class body name is not visible inside its methods but is in the class body and its defaults" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    try expectShape(runtime, class_source, "k", "abbbaaa");
    try expectShape(runtime, class_source, "Base", "aab");
    try expectSameAsEachName(runtime, class_source);
}

test "python scope: comprehension and lambda names stay inside them, and a default value is read outside the function" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    try expectShape(runtime, comprehension_source, "y", "abbbccdda");
    try expectShape(runtime, lambda_source, "q", "abba");
    try expectShape(runtime, lambda_source, "z", "abab");
    try expectShape(runtime, default_source, "d", "abab");
    try expectSameAsEachName(runtime, comprehension_source);
    try expectSameAsEachName(runtime, lambda_source);
    try expectSameAsEachName(runtime, default_source);
}

test "python scope: with-as, except-as, walrus, unpacking and match captures bind their names" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    try expectShape(runtime, with_source, "fh", "aa");
    try expectShape(runtime, with_source, "err", "aa");
    try expectShape(runtime, walrus_source, "n", "aa");
    try expectShape(runtime, walrus_source, "w", "aa");
    try expectShape(runtime, unpack_source, "rest", "aaa");
    try expectShape(runtime, unpack_source, "k", "aa");
    try expectShape(runtime, unpack_source, "b", "a");
    try expectShape(runtime, unpack_source, "i", "a");
    try expectShape(runtime, match_source, "tail", "aa");
    try expectShape(runtime, match_source, "first", "a");
    try expectShape(runtime, match_source, "yy", "aa");
    try expectShape(runtime, match_source, "whole", "aa");
    try expectShape(runtime, match_source, "x", ".?");
    try expectShape(runtime, match_source, "cap", "aa");
    try expectShape(runtime, match_source, "Color", "??");
    try expectShape(runtime, match_source, "Klass", ".");
    try expectShape(runtime, match_source, "GREEN", ".");
    try expectShape(runtime, match_source, "z", ".");
    try expectShape(runtime, match_source, "RED", ".?");
    try expectShape(runtime, match_source, "kv", "aa");
    try expectShape(runtime, match_source, "others", "aa");
    try expectSameAsEachName(runtime, with_source);
    try expectSameAsEachName(runtime, walrus_source);
    try expectSameAsEachName(runtime, unpack_source);
    try expectSameAsEachName(runtime, match_source);
}

test "python scope: only the bound name of an import binds, and an import inside a function stays there" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    try expectShape(runtime, import_source, "os", "aa");
    try expectShape(runtime, import_source, "path", "a.a");
    try expectShape(runtime, import_source, "a", ".");
    try expectShape(runtime, import_source, "b", ".");
    try expectShape(runtime, import_source, "c", "aa");
    try expectShape(runtime, import_source, "m", ".");
    try expectShape(runtime, import_source, "n", ".?");
    try expectShape(runtime, import_source, "q", "aa");
    try expectShape(runtime, import_source, "r", "aa");
    try expectShape(runtime, import_source, "s", ".?");
    try expectShape(runtime, import_source, "t", "aa");
    try expectShape(runtime, import_source, "json", "aa?");
    try expectShape(runtime, import_source, "al", "aa?");
    try expectImport(runtime, import_source, "os", true);
    try expectImport(runtime, import_source, "r", true);
    try expectImport(runtime, match_source, "cap", false);
    try expectSameAsEachName(runtime, import_source);
}

test "python rename: a module name is renamed through a global statement" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try snapshotOf(runtime, "count = 0\ndef bump():\n    global count\n    count = count + 1\n\ndef read():\n    count = 2\n    return count\n");
    defer base.destroy();
    const spans = try moduleSpans(testing.allocator, base, "count");
    defer testing.allocator.free(spans);
    try testing.expectEqual(@as(usize, 4), spans.len);
    const renamed = try rename.apply(testing.allocator, base, "count", "total", spans);
    defer renamed.deinit(testing.allocator);
    try testing.expectEqualStrings("total = 0\ndef bump():\n    global total\n    total = total + 1\n\ndef read():\n    count = 2\n    return count\n", renamed.snapshot.source);
}

test "python rename: a module name read in a method is refused when the class body shadows it" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const base = try snapshotOf(runtime, "count = 0\nclass C:\n    count = 5\n    def m(self):\n        return count\n");
    defer base.destroy();
    const spans = try moduleSpans(testing.allocator, base, "count");
    defer testing.allocator.free(spans);
    try testing.expectEqual(@as(usize, 2), spans.len);
    try testing.expectError(error.AlphaMismatch, rename.apply(testing.allocator, base, "count", "total", spans));
}

test "python declarations: a module-level assignment is a variable and an unpacking or attribute target is not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const snapshot = try snapshotOf(runtime, "LIMIT = 10\nname: str = \"x\"\na, b = 1, 2\nobj.attr = 3\ncount += 1\nhandler = lambda e: e\nclass C:\n    size = 4\n");
    defer snapshot.destroy();
    const found = try emetgate.declarations.collect(arena.allocator(), python, snapshot.tree);
    var names: std.ArrayList(u8) = .empty;
    for (found) |d| {
        try names.appendSlice(arena.allocator(), snapshot.tree.text(d.name));
        try names.append(arena.allocator(), ' ');
    }
    try testing.expectEqualStrings("LIMIT name C size ", names.items);
}

test "python declarations: a decorated class and its annotated fields are declared, and the class span starts at its decorator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const snapshot = try snapshotOf(runtime, "@dataclass\nclass P:\n    x: int = 0\n    y: int\n\n\n@deco\ndef f():\n    pass\n");
    defer snapshot.destroy();
    const found = try emetgate.declarations.collect(arena.allocator(), python, snapshot.tree);
    var names: std.ArrayList(u8) = .empty;
    for (found) |d| {
        try names.appendSlice(arena.allocator(), snapshot.tree.text(d.name));
        try names.append(arena.allocator(), ' ');
    }
    try testing.expectEqualStrings("P x y ", names.items);
    try testing.expectEqual(@as(u32, 0), found[0].declaration.start);
}
