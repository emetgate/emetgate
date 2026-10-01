const std = @import("std");
const emetgate = @import("emetgate");
const facts = emetgate.facts;
const facts_extract = emetgate.facts_extract;
const test_util = emetgate.test_util;
const Snapshot = emetgate.loader.Snapshot;
const Runtime = emetgate.runtime.Runtime;

const testing = std.testing;
const javascript = emetgate.lang_registry.forPath("a.js").?;

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
        for (self.facts.refs) |r| std.debug.print("  have {t} {s} {any}\n", .{ r.kind, r.name, r.target });
        return error.RefNotFound;
    }

    fn count(self: *const Extracted, kind: facts.RefKind, name: []const u8) usize {
        var n: usize = 0;
        for (self.facts.refs) |r| {
            if (r.kind == kind and std.mem.eql(u8, r.name, name)) n += 1;
        }
        return n;
    }

    fn exported(self: *const Extracted, name: []const u8) ?facts.Export {
        for (self.facts.exports) |e| {
            if (std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }
};

fn extractTs(runtime: *Runtime, source: []const u8) !Extracted {
    const snapshot = try test_util.snapshotOf(runtime, source);
    errdefer snapshot.destroy();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    const found = try facts_extract.extract(arena.allocator(), snapshot);
    return .{ .arena = arena, .snapshot = snapshot, .facts = found };
}

fn extractJs(runtime: *Runtime, source: []const u8) !Extracted {
    const snapshot = try Snapshot.fromSource(runtime, javascript, try testing.allocator.dupe(u8, source));
    errdefer snapshot.destroy();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    const found = try facts_extract.extract(arena.allocator(), snapshot);
    return .{ .arena = arena, .snapshot = snapshot, .facts = found };
}

test "facts extract: a call to a function of the same file is bound to its definition and owned by the caller" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var x = try extractTs(runtime, "function helper(): number { return 1; }\nexport function main() {\n  return helper();\n}\n");
    defer x.deinit();
    const helper = try x.def("helper");
    const main = try x.def("main");
    const r = try x.ref(.call, "helper", 0);
    try testing.expectEqual(facts.Target{ .local = helper }, r.target);
    try testing.expectEqual(main, r.from);
    try testing.expectEqual(@as(u32, 3), r.line);
    try testing.expectEqual(facts.DefKind.module, x.facts.defs[0].kind);
    try testing.expectEqual(@as(u32, 0), x.facts.defs[main].parent);
    try testing.expect(x.facts.defs[main].exported);
    try testing.expect(!x.facts.defs[helper].exported);
}

test "facts extract: named, aliased, default and namespace imports become bindings, and calls through them point at the binding" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var x = try extractTs(runtime, "import d, { a, b as c } from \"./x\";\nimport * as ns from \"./y\";\nexport function f() { a(); c(); d(); ns.run(); }\n");
    defer x.deinit();
    try testing.expectEqual(@as(usize, 2), x.facts.specs.len);
    try testing.expectEqual(@as(usize, 4), x.facts.bindings.len);
    try testing.expectEqualStrings("default", x.facts.bindings[0].imported);
    try testing.expectEqualStrings("a", x.facts.bindings[1].imported);
    try testing.expectEqualStrings("b", x.facts.bindings[2].imported);
    try testing.expectEqualStrings("c", x.facts.bindings[2].local);
    try testing.expectEqualStrings("*", x.facts.bindings[3].imported);
    try testing.expectEqual(facts.Target{ .binding = 1 }, (try x.ref(.call, "a", 0)).target);
    try testing.expectEqual(facts.Target{ .binding = 2 }, (try x.ref(.call, "c", 0)).target);
    try testing.expectEqual(facts.Target{ .binding = 0 }, (try x.ref(.call, "d", 0)).target);
    try testing.expectEqual(facts.Target{ .member_of_binding = 3 }, (try x.ref(.call, "run", 0)).target);
    try testing.expectEqual(facts.Target{ .binding = 2 }, (try x.ref(.import, "b", 0)).target);
    try testing.expect(x.facts.module_mode);
}

test "facts extract: this and static members are owned by the class, a static method sees static members" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var x = try extractTs(runtime, "export class A {\n  m() { return this.n(); }\n  n() { return 1; }\n  static s() { return this.t(); }\n  static t() { return 2; }\n}\nA.s();\n");
    defer x.deinit();
    const a = try x.def("A");
    const n = try x.ref(.call, "n", 0);
    try testing.expectEqual(facts.Target{ .member_of_def = a }, n.target);
    try testing.expect(!n.static);
    try testing.expectEqual(try x.def("A.m"), n.from);
    const t = try x.ref(.call, "t", 0);
    try testing.expect(t.static);
    const s = try x.ref(.call, "s", 0);
    try testing.expectEqual(facts.Target{ .member_of_def = a }, s.target);
    try testing.expect(s.static);
    try testing.expectEqual(@as(u32, 0), s.from);
}

test "facts extract: declared parameter types, constructed constants and parameter properties type a member call" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var x = try extractTs(runtime, "class Foo { go() { return 1; } }\nfunction f(p: Foo) { return p.go(); }\nconst w = new Foo();\nw.go();\nclass S {\n  constructor(private readonly dep: Foo) {}\n  run() { return this.dep.go(); }\n}\n");
    defer x.deinit();
    const foo = try x.def("Foo");
    for (0..3) |i| {
        const r = try x.ref(.call, "go", i);
        const t = switch (r.target) {
            .member_of_type => |t| t,
            else => return error.NotTyped,
        };
        try testing.expectEqual(facts.Target{ .local = foo }, x.facts.types[t].target);
    }
    try testing.expectEqual(@as(usize, 1), x.facts.member_types.len);
    try testing.expectEqualStrings("dep", x.facts.member_types[0].name);
}

test "facts extract: a property of an unknown value, a computed callee, eval and a callback stay unresolved with a reason" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var x = try extractTs(runtime, "export function g(o: any, k: string, cb: () => void) {\n  o.m();\n  o[k]();\n  o[\"named\"]();\n  eval(\"1\");\n  cb();\n  return o.field + o[k];\n}\n");
    defer x.deinit();
    try testing.expectEqual(facts.Target{ .unresolved = .property_needs_type }, (try x.ref(.call, "m", 0)).target);
    try testing.expectEqual(facts.Target{ .unresolved = .dynamic_access }, (try x.ref(.call, "", 0)).target);
    try testing.expectEqual(facts.Target{ .unresolved = .dynamic_access }, (try x.ref(.call, "named", 0)).target);
    try testing.expectEqual(facts.Target{ .unresolved = .dynamic_call }, (try x.ref(.call, "eval", 0)).target);
    try testing.expectEqual(facts.Target{ .unresolved = .local_value }, (try x.ref(.call, "cb", 0)).target);
    try testing.expectEqual(@as(usize, 1), x.facts.loose.len);
    try testing.expectEqualStrings("field", x.facts.loose[0].name);
    try testing.expectEqual(@as(u32, 1), x.facts.dynamic_reads);
}

test "facts extract: a destructured name shadows an outer function, so its call is a local value, never the function" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var x = try extractTs(runtime, "function process() { return 1; }\nexport function run(args: any) {\n  const { process } = args;\n  return process();\n}\nexport function other() { return process(); }\n");
    defer x.deinit();
    try testing.expectEqual(facts.Target{ .unresolved = .local_value }, (try x.ref(.call, "process", 0)).target);
    try testing.expectEqual(facts.Target{ .local = try x.def("process") }, (try x.ref(.call, "process", 1)).target);
}

test "facts extract: exported declarations, clauses, defaults, star and named re-exports are listed" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var x = try extractTs(runtime, "export function a() { return 1; }\nfunction b() { return 2; }\nconst d = 3;\nexport { b as c };\nexport default d;\nexport * from \"./y\";\nexport { e as f } from \"./z\";\nexport * as tools from \"./w\";\n");
    defer x.deinit();
    try testing.expectEqual(facts.ExportKind.local, x.exported("a").?.kind);
    try testing.expectEqual(try x.def("b"), x.exported("c").?.index);
    try testing.expectEqual(try x.def("d"), x.exported("default").?.index);
    try testing.expectEqual(facts.ExportKind.star, x.exported("*").?.kind);
    const f = x.exported("f").?;
    try testing.expectEqual(facts.ExportKind.binding, f.kind);
    try testing.expectEqualStrings("e", x.facts.bindings[f.index].imported);
    const tools = x.exported("tools").?;
    try testing.expectEqualStrings("*", x.facts.bindings[tools.index].imported);
    try testing.expect(x.exported("b") == null);
}

test "facts extract: a name inside a syntax error is unresolved as a parse error, the rest of the file still resolves" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var x = try extractTs(runtime, "function ok() { return 1; }\nexport function a() { return ok(); }\nfunction broken() { ok(1) ok(2); }\n");
    defer x.deinit();
    try testing.expect(x.facts.parse_errors);
    try testing.expectEqual(facts.Target{ .local = try x.def("ok") }, (try x.ref(.call, "ok", 0)).target);
    var parse_errors: usize = 0;
    for (x.facts.refs) |r| {
        if (r.target == .unresolved and r.target.unresolved == .parse_error and std.mem.eql(u8, r.name, "ok")) parse_errors += 1;
    }
    try testing.expectEqual(@as(usize, 1), parse_errors);
}

test "facts extract: a JavaScript class records its base class without a type annotation table" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var x = try extractJs(runtime, "class Base { go() { return 1; } }\nclass Child extends Base { run() { return super.go(); } }\nconst c = new Child();\nc.run();\n");
    defer x.deinit();
    const child = try x.def("Child");
    var base: u32 = facts.none;
    for (x.facts.classes) |c| {
        if (c.def == child) base = c.base;
    }
    try testing.expect(base != facts.none);
    try testing.expectEqual(facts.Target{ .local = try x.def("Base") }, x.facts.types[base].target);
    try testing.expectEqual(facts.Target{ .member_of_super = child }, (try x.ref(.call, "go", 0)).target);
    try testing.expect((try x.ref(.call, "run", 0)).target == .member_of_type);
    try testing.expectEqual(facts.Target{ .local = child }, (try x.ref(.new, "Child", 0)).target);
}

test "facts extract: a qualified type through a namespace import is a type reference to that module's member" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var x = try extractTs(runtime, "import * as api from \"./api\";\ntype Local = { a: number };\nexport function f(x: api.Local, y: Local) { return [x, y]; }\n");
    defer x.deinit();
    try testing.expectEqual(facts.Target{ .member_of_binding = 0 }, (try x.ref(.type, "Local", 0)).target);
    try testing.expectEqual(facts.Target{ .local = try x.def("Local") }, (try x.ref(.type, "Local", 1)).target);
    try testing.expectEqual(@as(usize, 2), x.count(.type, "Local"));
}
