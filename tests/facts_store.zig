const std = @import("std");
const emetgate = @import("emetgate");
const facts = emetgate.facts;
const facts_store = emetgate.facts_store;
const test_util = emetgate.test_util;
const Repo = @import("facts_repo.zig").Repo;

const testing = std.testing;

fn expectDef(link: facts_store.Link, want: facts_store.DefId, certainty: facts.Certainty) !void {
    switch (link) {
        .def => |d| {
            try testing.expectEqual(want.file, d.id.file);
            try testing.expectEqual(want.slot, d.id.slot);
            try testing.expectEqual(certainty, d.certainty);
        },
        .unresolved => |reason| {
            std.debug.print("unresolved: {t}\n", .{reason});
            return error.Unresolved;
        },
    }
}

fn expectUnresolved(link: facts_store.Link, reason: facts.Reason) !void {
    switch (link) {
        .def => return error.Resolved,
        .unresolved => |got| try testing.expectEqual(reason, got),
    }
}

test "facts store: an imported call, a re-exported name and a namespace member all reach the defining file" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    _ = try repo.put("a.ts", "export function f() { return 1; }\n");
    _ = try repo.put("index.ts", "export * from \"./a\";\n");
    _ = try repo.put("b.ts", "import { f } from \"./a\";\nexport function g() { return f(); }\n");
    _ = try repo.put("c.ts", "import { f } from \"./index\";\nimport * as ns from \"./a\";\nexport function h() { return f() + ns.f(); }\n");
    try repo.linkAll();
    const f = try repo.def("a.ts", "f");
    try expectDef(try repo.linkOf("b.ts", .call, "f"), f, .proven);
    try expectDef(try repo.linkOf("c.ts", .call, "f"), f, .proven);
    try testing.expectEqual(@as(usize, 3), repo.incomingCount(f, .call));
    try testing.expectEqual(@as(usize, 2), repo.incomingCount(f, .import));
}

test "facts store: an inherited method is found through the base class of another file, a typed receiver is labelled typed" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    _ = try repo.put("base.ts", "export class Base { go() { return 1; } }\n");
    _ = try repo.put("child.ts", "import { Base } from \"./base\";\nexport class Child extends Base { run() { return this.go() + super.go(); } }\nexport function use(x: Base) { return x.go(); }\nexport function make() { return new Child().run(); }\n");
    try repo.linkAll();
    const go = try repo.def("base.ts", "Base.go");
    const child = repo.store.fileId("child.ts").?;
    const state = repo.store.file(child);
    var proven: usize = 0;
    var typed: usize = 0;
    for (state.facts.refs, state.links) |r, l| {
        if (!std.mem.eql(u8, r.name, "go")) continue;
        try testing.expect(l == .def);
        try testing.expectEqual(go.slot, l.def.id.slot);
        if (l.def.certainty == .proven) proven += 1 else typed += 1;
    }
    try testing.expectEqual(@as(usize, 2), proven);
    try testing.expectEqual(@as(usize, 1), typed);
}

test "facts store: an external package, a missing module and a missing export each stay unresolved with their reason" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    _ = try repo.put("a.ts", "export function f() { return 1; }\n");
    _ = try repo.put("b.ts", "import { y } from \"lodash\";\nimport { z } from \"./missing\";\nimport { nope } from \"./a\";\nexport function g() { return y() + z() + nope(); }\n");
    try repo.linkAll();
    try expectUnresolved(try repo.linkOf("b.ts", .call, "y"), .external_module);
    try expectUnresolved(try repo.linkOf("b.ts", .call, "z"), .module_not_found);
    try expectUnresolved(try repo.linkOf("b.ts", .call, "nope"), .export_not_found);
}

test "facts store: a changed caller leaves no stale edge, a removed export turns the importer's edge unresolved" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    const a = try repo.put("a.ts", "export function f() { return 1; }\nexport function k() { return 2; }\n");
    const b = try repo.put("b.ts", "import { f } from \"./a\";\nexport function g() { return f(); }\n");
    try repo.linkAll();
    const f = try repo.def("a.ts", "f");
    try testing.expectEqual(@as(usize, 1), repo.incomingCount(f, .call));

    const b_reshaped = try repo.putReporting("b.ts", "import { f } from \"./a\";\nexport function g() { return 0; }\n");
    _ = try repo.store.relink(&.{b}, if (b_reshaped) &.{b} else &.{}, repo.resolver());
    try testing.expectEqual(@as(usize, 0), repo.incomingCount(f, .call));

    _ = try repo.put("b.ts", "import { f } from \"./a\";\nexport function g() { return f(); }\n");
    _ = try repo.store.relink(&.{b}, &.{b}, repo.resolver());
    try testing.expectEqual(@as(usize, 1), repo.incomingCount(f, .call));

    const a_reshaped = try repo.putReporting("a.ts", "export function k() { return 2; }\n");
    try testing.expect(a_reshaped);
    const relinked = try repo.store.relink(&.{a}, &.{a}, repo.resolver());
    try testing.expectEqual(@as(usize, 2), relinked);
    try testing.expectEqual(@as(usize, 0), repo.incomingCount(f, null));
    try expectUnresolved(try repo.linkOf("b.ts", .call, "f"), .export_not_found);
}

test "facts store: a body edit keeps every definition's identity and does not relink the importers" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    const a = try repo.put("a.ts", "export function f() { return 1; }\nexport class C { m() { return 2; } }\n");
    _ = try repo.put("b.ts", "import { f, C } from \"./a\";\nexport function g() { return f() + new C().m(); }\n");
    try repo.linkAll();
    const f_before = try repo.def("a.ts", "f");
    const m_before = try repo.def("a.ts", "C.m");
    const reshaped = try repo.putReporting("a.ts", "\nexport function f() {\n  return 10;\n}\nexport class C { m() { return 20; } }\n");
    try testing.expect(!reshaped);
    const relinked = try repo.store.relink(&.{a}, &.{}, repo.resolver());
    try testing.expectEqual(@as(usize, 1), relinked);
    try testing.expectEqual(f_before.slot, (try repo.def("a.ts", "f")).slot);
    try testing.expectEqual(m_before.slot, (try repo.def("a.ts", "C.m")).slot);
    try testing.expectEqual(@as(usize, 1), repo.incomingCount(f_before, .call));
    try testing.expectEqual(@as(usize, 1), repo.incomingCount(m_before, .call));
    try testing.expectEqual(@as(u32, 2), repo.store.defOf(f_before).?.line);
}

test "facts store: a re-export cycle ends as unresolved instead of looping" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    _ = try repo.put("x.ts", "export * from \"./y\";\n");
    _ = try repo.put("y.ts", "export * from \"./x\";\n");
    _ = try repo.put("z.ts", "import { q } from \"./x\";\nexport function g() { return q(); }\n");
    try repo.linkAll();
    try expectUnresolved(try repo.linkOf("z.ts", .call, "q"), .reexport_cycle);
}

test "facts store: the snapshot root changes with any file's content and not with the order files were added" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var first = Repo.init(runtime);
    defer first.deinit();
    _ = try first.put("a.ts", "export const a = 1;\n");
    _ = try first.put("b.ts", "export const b = 2;\n");
    try first.linkAll();
    var second = Repo.init(runtime);
    defer second.deinit();
    _ = try second.put("b.ts", "export const b = 2;\n");
    _ = try second.put("a.ts", "export const a = 1;\n");
    try second.linkAll();
    try testing.expectEqualSlices(u8, &first.store.root, &second.store.root);
    _ = try second.put("a.ts", "export const a = 3;\n");
    try second.store.computeRoot();
    try testing.expect(!std.mem.eql(u8, &first.store.root, &second.store.root));
}

test "facts store: a member the class does not declare stays unresolved and is never counted as the class" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    _ = try repo.put("a.ts", "export class C {\n  run() { return this.missing(); }\n}\n");
    try repo.linkAll();
    try expectUnresolved(try repo.linkOf("a.ts", .call, "missing"), .member_not_found);
    try testing.expectEqual(@as(usize, 0), repo.incomingCount(try repo.def("a.ts", "C"), null));
}

test "facts store: an edit that keeps a reference at the same index does not count the old edge twice" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    _ = try repo.put("a.ts", "export function f() { return 1; }\n");
    const b = try repo.put("b.ts", "import { f } from \"./a\";\nexport function g() { return f(); }\n");
    try repo.linkAll();
    const f = try repo.def("a.ts", "f");
    try testing.expectEqual(@as(usize, 2), repo.incomingCount(f, null));
    _ = try repo.put("b.ts", "import { f } from \"./a\";\nexport function g() { return f; }\n");
    _ = try repo.store.relink(&.{b}, &.{}, repo.resolver());
    try testing.expectEqual(@as(usize, 2), repo.incomingCount(f, null));
    try testing.expectEqual(@as(usize, 0), repo.incomingCount(f, .call));
}

test "facts store: linking through a file whose imports are not resolved yet is an error, never an empty answer" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    var repo = Repo.init(runtime);
    defer repo.deinit();
    _ = try repo.put("a.ts", "export function f() { return 1; }\n");
    _ = try repo.put("index.ts", "export * from \"./a\";\n");
    const c = try repo.put("c.ts", "import { f } from \"./index\";\nexport function g() { return f(); }\n");
    try testing.expectError(error.SpecsNotResolved, repo.store.link(c, repo.resolver()));
}
