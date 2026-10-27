const std = @import("std");
const emetgate = @import("emetgate");
const facts = emetgate.facts;
const rename = emetgate.rename;
const symbol = emetgate.symbol;
const registry = emetgate.lang_registry;
const Snapshot = emetgate.loader.Snapshot;
const Runtime = emetgate.runtime.Runtime;
const Repo = @import("../facts_repo.zig").Repo;

const testing = std.testing;
const Span = symbol.Span;

fn csharp() *const emetgate.lang_profile.Profile {
    return registry.forPath("x.cs").?;
}

fn snapshotOf(runtime: *Runtime, source: []const u8) !*Snapshot {
    return Snapshot.fromSource(runtime, csharp(), try testing.allocator.dupe(u8, source));
}

const demo =
    \\namespace Demo
    \\{
    \\    class Helpers
    \\    {
    \\        public static int Helper(int x) { return x + 1; }
    \\        public int Instance(int y) { return y * 2; }
    \\    }
    \\
    \\    class Program
    \\    {
    \\        public int Main() { return Helpers.Helper(5); }
    \\        public int ViaParam(Helpers h) { return h.Instance(3); }
    \\        public int ViaNew() { return new Helpers().Instance(9); }
    \\    }
    \\}
    \\
;

test "csharp facts: a static call across classes resolves caller and callee as proven" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var repo = Repo.init(runtime);
    defer repo.deinit();

    _ = try repo.put("Demo.cs", demo);
    try repo.linkAll();

    const helper = try repo.def("Demo.cs", "Demo.Helpers.Helper@static");
    const main = try repo.def("Demo.cs", "Demo.Program.Main");

    try testing.expectEqual(@as(usize, 1), repo.incomingCount(helper, .call));
    const link = try repo.linkOf("Demo.cs", .call, "Helper");
    switch (link) {
        .def => |d| {
            try testing.expectEqual(main.file, d.id.file);
            try testing.expectEqual(main.file, helper.file);
            try testing.expectEqual(facts.Certainty.proven, d.certainty);
        },
        .unresolved => return error.CallNotResolved,
    }
}

test "csharp facts: an instance call through a typed parameter and through a constructor both resolve" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var repo = Repo.init(runtime);
    defer repo.deinit();

    _ = try repo.put("Demo.cs", demo);
    try repo.linkAll();

    const instance = try repo.def("Demo.cs", "Demo.Helpers.Instance");
    try testing.expectEqual(@as(usize, 2), repo.incomingCount(instance, .call));
}

test "csharp rename: renaming a type rewrites its every reference and leaves a same-named member alone" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const source =
        \\namespace Demo
        \\{
        \\    class Helpers
        \\    {
        \\        public static int Helper(int x) { return x + 1; }
        \\    }
        \\
        \\    class Program
        \\    {
        \\        public int Main() { return Helpers.Helper(5); }
        \\        public int Make(Helpers h) { return 0; }
        \\        public Helpers Build() { return new Helpers(); }
        \\    }
        \\}
        \\
    ;
    const base = try snapshotOf(runtime, source);
    defer base.destroy();

    const leaves = try rename.leavesNamed(testing.allocator, base, "Helpers");
    defer testing.allocator.free(leaves);
    const spans = try testing.allocator.alloc(Span, leaves.len);
    defer testing.allocator.free(spans);
    for (leaves, spans) |leaf, *slot| slot.* = leaf.span;
    try testing.expectEqual(@as(usize, 5), spans.len);

    const renamed = try rename.apply(testing.allocator, base, "Helpers", "Utils", spans);
    defer renamed.deinit(testing.allocator);

    const expected =
        \\namespace Demo
        \\{
        \\    class Utils
        \\    {
        \\        public static int Helper(int x) { return x + 1; }
        \\    }
        \\
        \\    class Program
        \\    {
        \\        public int Main() { return Utils.Helper(5); }
        \\        public int Make(Utils h) { return 0; }
        \\        public Utils Build() { return new Utils(); }
        \\    }
        \\}
        \\
    ;
    try testing.expectEqualStrings(expected, renamed.snapshot.source);
}

test "csharp rename: a method and its unqualified sibling call rename together" {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const source =
        \\namespace Demo
        \\{
        \\    class C
        \\    {
        \\        public int Helper(int x) { return x + 1; }
        \\        public int Caller() { return Helper(1); }
        \\    }
        \\}
        \\
    ;
    const base = try snapshotOf(runtime, source);
    defer base.destroy();
    const leaves = try rename.leavesNamed(testing.allocator, base, "Helper");
    defer testing.allocator.free(leaves);
    const spans = try testing.allocator.alloc(Span, leaves.len);
    defer testing.allocator.free(spans);
    for (leaves, spans) |leaf, *slot| slot.* = leaf.span;
    try testing.expectEqual(@as(usize, 2), spans.len);

    const renamed = try rename.apply(testing.allocator, base, "Helper", "Plus", spans);
    defer renamed.deinit(testing.allocator);
    const expected =
        \\namespace Demo
        \\{
        \\    class C
        \\    {
        \\        public int Plus(int x) { return x + 1; }
        \\        public int Caller() { return Plus(1); }
        \\    }
        \\}
        \\
    ;
    try testing.expectEqualStrings(expected, renamed.snapshot.source);
}
