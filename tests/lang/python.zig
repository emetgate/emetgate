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

test "python facts: a method is a def under its class and a self-call stays unresolved" {
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
    switch (r.target) {
        .unresolved => {},
        else => return error.ExpectedUnresolved,
    }
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
