const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");
const rename_batch = emetgate.rename_batch;
const rename_graph = emetgate.rename_graph;
const symbol = emetgate.symbol;
const Runtime = emetgate.runtime.Runtime;
const Snapshot = emetgate.loader.Snapshot;
const fixture = @import("ts_fixture.zig");

const testing = std.testing;

const Case = struct {
    repo: fixture.TsRepo,
    runtime: *Runtime,

    fn init(files: []const fixture.File) !Case {
        const runtime = try Runtime.create(testing.allocator);
        errdefer runtime.destroy() catch {};
        return .{ .repo = try fixture.TsRepo.init(files), .runtime = runtime };
    }

    fn deinit(self: *Case) void {
        self.repo.deinit();
        self.runtime.destroy() catch @panic("live snapshots");
    }

    fn hashOf(self: *Case, file: []const u8, ref_text: []const u8) !symbol.Hash {
        const snapshot = try Snapshot.load(self.runtime, testing.io, .cwd(), file);
        defer snapshot.destroy();
        const table = try snapshot.symbols();
        const ref = try symbol.Ref.parse(testing.allocator, ref_text);
        defer ref.deinit(testing.allocator);
        if (table.resolve(ref)) |found| return found.hash else |_| {}
        for (table.declarations) |d| {
            if (d.ref.eql(ref)) return d.hash;
        }
        return error.DeclarationNotFound;
    }

    fn plan(self: *Case, rel: []const u8, ref_text: []const u8, new_name: []const u8, interface_change: bool) !rename_batch.Plan {
        return self.planWith(rel, ref_text, new_name, interface_change, null);
    }

    fn planWith(self: *Case, rel: []const u8, ref_text: []const u8, new_name: []const u8, interface_change: bool, unresolved: ?*rename_graph.Sites) !rename_batch.Plan {
        const file = try self.repo.abs(testing.allocator, rel);
        defer testing.allocator.free(file);
        const hash = try self.hashOf(file, ref_text);
        return rename_batch.plan(testing.allocator, testing.io, self.runtime, self.repo.root_abs, .{
            .file_abs = file,
            .ref_text = ref_text,
            .expected_hash = hash,
            .new_name = new_name,
            .interface_change = interface_change,
            .unresolved = unresolved,
        }, null);
    }
};

fn expectSource(planned: rename_batch.Plan, rel: []const u8, expected: []const u8) !void {
    for (planned.prepared) |p| {
        const slashed = try testing.allocator.dupe(u8, p.rel);
        defer testing.allocator.free(slashed);
        std.mem.replaceScalar(u8, slashed, '\\', '/');
        if (!std.mem.eql(u8, slashed, rel)) continue;
        return testing.expectEqualStrings(expected, p.snapshot.?.source);
    }
    return error.FileNotPlanned;
}

const helpers_cs =
    \\namespace Demo
    \\{
    \\    public class Helpers
    \\    {
    \\        public static int Helper(int x) { return x + 1; }
    \\        public int Twice(int x) { return Helper(x) + Helper(x); }
    \\    }
    \\}
    \\
;

const program_cs =
    \\namespace Demo
    \\{
    \\    public class Program
    \\    {
    \\        public int Main() { return Helpers.Helper(5); }
    \\    }
    \\}
    \\
;

test "rename facts: a C# static method called from another file is renamed at its declaration and every call" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{ .{ .rel = "src/Helpers.cs", .text = helpers_cs }, .{ .rel = "src/Program.cs", .text = program_cs } });
    defer case.deinit();
    try testing.expectError(error.InterfaceChangeNeedsApproval, case.plan("src/Helpers.cs", "Demo.Helpers.Helper@static", "Plus", false));
    const planned = try case.plan("src/Helpers.cs", "Demo.Helpers.Helper@static", "Plus", true);
    defer planned.deinit(testing.allocator);
    try testing.expectEqual(rename_batch.Resolver.facts, planned.resolver);
    try testing.expectEqual(@as(usize, 2), planned.prepared.len);
    try expectSource(planned, "src/Helpers.cs",
        \\namespace Demo
        \\{
        \\    public class Helpers
        \\    {
        \\        public static int Plus(int x) { return x + 1; }
        \\        public int Twice(int x) { return Plus(x) + Plus(x); }
        \\    }
        \\}
        \\
    );
    try expectSource(planned, "src/Program.cs",
        \\namespace Demo
        \\{
        \\    public class Program
        \\    {
        \\        public int Main() { return Helpers.Plus(5); }
        \\    }
        \\}
        \\
    );
}

test "rename facts: a C# method call on a type from a namespace the file does not import is refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const elsewhere =
        \\namespace Other
        \\{
        \\    public class Program
        \\    {
        \\        public int Main() { return Helpers.Helper(5); }
        \\    }
        \\}
        \\
    ;
    var case = try Case.init(&.{ .{ .rel = "src/Helpers.cs", .text = helpers_cs }, .{ .rel = "src/Program.cs", .text = elsewhere } });
    defer case.deinit();
    try testing.expectError(error.RenameUnresolved, case.plan("src/Helpers.cs", "Demo.Helpers.Helper@static", "Plus", true));
}

test "rename facts: a C# method call through a using directive is renamed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const imported =
        \\using Demo;
        \\
        \\namespace Other
        \\{
        \\    public class Program
        \\    {
        \\        public int Main() { return Helpers.Helper(5); }
        \\    }
        \\}
        \\
    ;
    var case = try Case.init(&.{ .{ .rel = "src/Helpers.cs", .text = helpers_cs }, .{ .rel = "src/Program.cs", .text = imported } });
    defer case.deinit();
    const planned = try case.plan("src/Helpers.cs", "Demo.Helpers.Helper@static", "Plus", true);
    defer planned.deinit(testing.allocator);
    try expectSource(planned, "src/Program.cs",
        \\using Demo;
        \\
        \\namespace Other
        \\{
        \\    public class Program
        \\    {
        \\        public int Main() { return Helpers.Plus(5); }
        \\    }
        \\}
        \\
    );
}

test "rename facts: a type alias with the class name in a using directive refuses the rename" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const aliased =
        \\using Demo;
        \\using Helpers = System.Text.StringBuilder;
        \\
        \\namespace Other
        \\{
        \\    public class Program
        \\    {
        \\        public int Main() { return Helpers.Helper(5); }
        \\    }
        \\}
        \\
    ;
    var case = try Case.init(&.{ .{ .rel = "src/Helpers.cs", .text = helpers_cs }, .{ .rel = "src/Program.cs", .text = aliased } });
    defer case.deinit();
    try testing.expectError(error.RenameUnresolved, case.plan("src/Helpers.cs", "Demo.Helpers.Helper@static", "Plus", true));
}

const shape_cs =
    \\namespace Demo
    \\{
    \\    public class Shape
    \\    {
    \\        public Shape() { }
    \\        public static Shape Make() { return new Shape(); }
    \\    }
    \\}
    \\
;

const user_cs =
    \\namespace Demo.App
    \\{
    \\    public class User
    \\    {
    \\        public int Area(Shape s) { return 0; }
    \\        public Shape Build() { return new Shape(); }
    \\        public Shape Again() { return Shape.Make(); }
    \\    }
    \\}
    \\
;

test "rename facts: a C# class is renamed at its declaration, constructor, new, parameter type, return type and static call in another file" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{ .{ .rel = "src/Shape.cs", .text = shape_cs }, .{ .rel = "src/User.cs", .text = user_cs } });
    defer case.deinit();
    const planned = try case.plan("src/Shape.cs", "Demo.Shape", "Figure", true);
    defer planned.deinit(testing.allocator);
    try testing.expectEqual(rename_batch.Resolver.facts, planned.resolver);
    try expectSource(planned, "src/Shape.cs",
        \\namespace Demo
        \\{
        \\    public class Figure
        \\    {
        \\        public Figure() { }
        \\        public static Figure Make() { return new Figure(); }
        \\    }
        \\}
        \\
    );
    try expectSource(planned, "src/User.cs",
        \\namespace Demo.App
        \\{
        \\    public class User
        \\    {
        \\        public int Area(Figure s) { return 0; }
        \\        public Figure Build() { return new Figure(); }
        \\        public Figure Again() { return Figure.Make(); }
        \\    }
        \\}
        \\
    );
}

test "rename facts: a C# class whose name another type also declares is refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const twin =
        \\namespace Other
        \\{
        \\    public class Shape { }
        \\}
        \\
    ;
    var case = try Case.init(&.{ .{ .rel = "src/Shape.cs", .text = shape_cs }, .{ .rel = "src/User.cs", .text = user_cs }, .{ .rel = "src/Twin.cs", .text = twin } });
    defer case.deinit();
    try testing.expectError(error.RenameUnresolved, case.plan("src/Shape.cs", "Demo.Shape", "Figure", true));
}

test "rename facts: a C# overloaded method is refused before any edit is planned" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const overloaded =
        \\namespace Demo
        \\{
        \\    class Calc
        \\    {
        \\        int Add(int a) { return a; }
        \\        int Add(int a, int b) { return a + b; }
        \\        int Use() { return Add(1); }
        \\    }
        \\}
        \\
    ;
    var case = try Case.init(&.{.{ .rel = "src/Calc.cs", .text = overloaded }});
    defer case.deinit();
    const file = try case.repo.abs(testing.allocator, "src/Calc.cs");
    defer testing.allocator.free(file);
    const snapshot = try Snapshot.load(case.runtime, testing.io, .cwd(), file);
    const hash = blk: {
        defer snapshot.destroy();
        const table = try snapshot.symbols();
        for (table.symbols) |s| if (std.mem.eql(u8, s.ref.name, "Add")) break :blk s.hash;
        return error.SymbolNotFound;
    };
    try testing.expectError(error.AmbiguousSymbol, rename_batch.plan(testing.allocator, testing.io, case.runtime, case.repo.root_abs, .{
        .file_abs = file,
        .ref_text = "Demo.Calc.Add",
        .expected_hash = hash,
        .new_name = "Plus",
        .interface_change = true,
    }, null));
}

test "rename facts: a C# class method implementing an interface method is refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const source =
        \\namespace Demo
        \\{
        \\    interface IRun
        \\    {
        \\        int Run() { return 0; }
        \\    }
        \\
        \\    class Runner : IRun
        \\    {
        \\        public int Run() { return 1; }
        \\    }
        \\}
        \\
    ;
    var case = try Case.init(&.{.{ .rel = "src/Run.cs", .text = source }});
    defer case.deinit();
    try testing.expectError(error.RenameUnresolved, case.plan("src/Run.cs", "Demo.Runner.Run", "Go", true));
}

test "rename facts: a C# interface method is refused even when no class declares it" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const source =
        \\namespace Demo
        \\{
        \\    interface IRun
        \\    {
        \\        int Run() { return 0; }
        \\    }
        \\
        \\    class Runner : IRun
        \\    {
        \\    }
        \\}
        \\
    ;
    var case = try Case.init(&.{.{ .rel = "src/Run.cs", .text = source }});
    defer case.deinit();
    try testing.expectError(error.RenameUnresolved, case.plan("src/Run.cs", "Demo.IRun.Run", "Go", true));
}

test "rename facts: a C# method that a derived class declares again is refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const source =
        \\namespace Demo
        \\{
        \\    class Base
        \\    {
        \\        public int Size() { return 1; }
        \\    }
        \\
        \\    class Derived : Base
        \\    {
        \\        public new int Size() { return 2; }
        \\    }
        \\}
        \\
    ;
    var case = try Case.init(&.{.{ .rel = "src/Base.cs", .text = source }});
    defer case.deinit();
    try testing.expectError(error.RenameUnresolved, case.plan("src/Base.cs", "Demo.Base.Size", "Width", true));
}

test "rename facts: a C# partial class declared in two files is refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const first =
        \\namespace Demo
        \\{
        \\    public partial class Shape
        \\    {
        \\        public int One() { return 1; }
        \\    }
        \\}
        \\
    ;
    const second =
        \\namespace Demo
        \\{
        \\    public partial class Shape
        \\    {
        \\        public int Two() { return 2; }
        \\    }
        \\}
        \\
    ;
    var case = try Case.init(&.{ .{ .rel = "src/Shape.cs", .text = first }, .{ .rel = "src/ShapeTwo.cs", .text = second } });
    defer case.deinit();
    try testing.expectError(error.RenameUnresolved, case.plan("src/Shape.cs", "Demo.Shape", "Figure", true));
}

test "rename facts: a C# call through a type name that the enclosing namespace also declares is refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const both =
        \\namespace Other
        \\{
        \\    public class Helpers
        \\    {
        \\        public static int Helper(int x) { return x; }
        \\    }
        \\}
        \\
        \\namespace Demo
        \\{
        \\    public class Helpers
        \\    {
        \\        public static int Helper(int x) { return x + 1; }
        \\    }
        \\}
        \\
    ;
    const caller =
        \\using Demo;
        \\
        \\namespace Other
        \\{
        \\    public class Program
        \\    {
        \\        public int Main() { return Helpers.Helper(5); }
        \\    }
        \\}
        \\
    ;
    var case = try Case.init(&.{ .{ .rel = "src/Helpers.cs", .text = both }, .{ .rel = "src/Program.cs", .text = caller } });
    defer case.deinit();
    const file = try case.repo.abs(testing.allocator, "src/Helpers.cs");
    defer testing.allocator.free(file);
    const snapshot = try Snapshot.load(case.runtime, testing.io, .cwd(), file);
    const hash = blk: {
        defer snapshot.destroy();
        const table = try snapshot.symbols();
        const ref = try symbol.Ref.parse(testing.allocator, "Demo.Helpers.Helper@static");
        defer ref.deinit(testing.allocator);
        break :blk (try table.resolve(ref)).hash;
    };
    try testing.expectError(error.RenameUnresolved, rename_batch.plan(testing.allocator, testing.io, case.runtime, case.repo.root_abs, .{
        .file_abs = file,
        .ref_text = "Demo.Helpers.Helper@static",
        .expected_hash = hash,
        .new_name = "Plus",
        .interface_change = true,
    }, null));
}

test "rename facts: a using directive inside another namespace block does not reach a call outside it" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const caller =
        \\namespace Side
        \\{
        \\    using Demo;
        \\}
        \\
        \\namespace Other
        \\{
        \\    public class Program
        \\    {
        \\        public int Main() { return Helpers.Helper(5); }
        \\    }
        \\}
        \\
    ;
    var case = try Case.init(&.{ .{ .rel = "src/Helpers.cs", .text = helpers_cs }, .{ .rel = "src/Program.cs", .text = caller } });
    defer case.deinit();
    try testing.expectError(error.RenameUnresolved, case.plan("src/Helpers.cs", "Demo.Helpers.Helper@static", "Plus", true));
}

test "rename facts: a C# class in the global namespace is renamed in another file" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{
        .{ .rel = "Tool.cs", .text = "public class Tool\n{\n    public static int Run() { return 1; }\n}\n" },
        .{ .rel = "Use.cs", .text = "public class Use\n{\n    public int Go() { return Tool.Run(); }\n}\n" },
    });
    defer case.deinit();
    const planned = try case.plan("Tool.cs", "Tool.Run@static", "Start", true);
    defer planned.deinit(testing.allocator);
    try expectSource(planned, "Use.cs", "public class Use\n{\n    public int Go() { return Tool.Start(); }\n}\n");
}

test "rename facts: a public C# method in one file still needs interface approval" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{.{ .rel = "src/Box.cs", .text = box_cs }});
    defer case.deinit();
    try testing.expectError(error.InterfaceChangeNeedsApproval, case.plan("src/Box.cs", "Demo.Box.Size", "Width", false));
    const planned = try case.plan("src/Box.cs", "Demo.Box.Size", "Width", true);
    defer planned.deinit(testing.allocator);
    try testing.expect(planned.interface_change);
}

test "rename facts: a Python function imported by another module is renamed at its import and its call" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{
        .{ .rel = "a.py", .text = "def helper(x):\n    return x + 1\n" },
        .{ .rel = "b.py", .text = "from a import helper\n\n\ndef main():\n    return helper(2)\n" },
    });
    defer case.deinit();
    const planned = try case.plan("a.py", "helper", "plus", true);
    defer planned.deinit(testing.allocator);
    try testing.expectEqual(rename_batch.Resolver.facts, planned.resolver);
    try expectSource(planned, "a.py", "def plus(x):\n    return x + 1\n");
    try expectSource(planned, "b.py", "from a import plus\n\n\ndef main():\n    return plus(2)\n");
}

test "rename facts: a Python function imported by another module is renamed where it is passed as a value" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{
        .{ .rel = "a.py", .text = "def helper(x):\n    return x + 1\n" },
        .{ .rel = "b.py", .text = "from a import helper\n\nhandlers = [helper]\n" },
    });
    defer case.deinit();
    const planned = try case.plan("a.py", "helper", "plus", true);
    defer planned.deinit(testing.allocator);
    try expectSource(planned, "b.py", "from a import plus\n\nhandlers = [plus]\n");
}

test "rename facts: a Python method called through self is renamed at its call" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{.{ .rel = "svc.py", .text = "class Svc:\n    def run(self):\n        return 1\n\n    def go(self):\n        return self.run()\n" }});
    defer case.deinit();
    const planned = try case.plan("svc.py", "Svc.run", "start", true);
    defer planned.deinit(testing.allocator);
    try expectSource(planned, "svc.py", "class Svc:\n    def start(self):\n        return 1\n\n    def go(self):\n        return self.start()\n");
}

test "rename facts: a Python method called on a receiver of unknown type is refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{
        .{ .rel = "svc.py", .text = "class Svc:\n    def run(self):\n        return 1\n" },
        .{ .rel = "use.py", .text = "def go(x):\n    return x.run()\n" },
    });
    defer case.deinit();
    try testing.expectError(error.RenameUnresolved, case.plan("svc.py", "Svc.run", "start", true));
}

const box_cs =
    \\namespace Demo
    \\{
    \\    public class Box
    \\    {
    \\        public int Size(int y) { return y * 2; }
    \\    }
    \\}
    \\
;

test "rename facts: a C# instance method called through a typed parameter in another file is renamed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const caller =
        \\namespace Demo
        \\{
        \\    public class Caller
        \\    {
        \\        public int Via(Box b) { return b.Size(3); }
        \\    }
        \\}
        \\
    ;
    var case = try Case.init(&.{ .{ .rel = "src/Box.cs", .text = box_cs }, .{ .rel = "src/Caller.cs", .text = caller } });
    defer case.deinit();
    const planned = try case.plan("src/Box.cs", "Demo.Box.Size", "Width", true);
    defer planned.deinit(testing.allocator);
    try expectSource(planned, "src/Caller.cs",
        \\namespace Demo
        \\{
        \\    public class Caller
        \\    {
        \\        public int Via(Box b) { return b.Width(3); }
        \\    }
        \\}
        \\
    );
}

test "rename facts: a C# member call on a receiver of unknown type refuses the rename" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const caller =
        \\namespace Demo
        \\{
        \\    public class Caller
        \\    {
        \\        public int Via(dynamic d) { return d.Size(3); }
        \\    }
        \\}
        \\
    ;
    var case = try Case.init(&.{ .{ .rel = "src/Box.cs", .text = box_cs }, .{ .rel = "src/Caller.cs", .text = caller } });
    defer case.deinit();
    try testing.expectError(error.RenameUnresolved, case.plan("src/Box.cs", "Demo.Box.Size", "Width", true));
}

test "rename facts: a Python function called inside an f-string interpolation is renamed there too" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{.{ .rel = "m.py", .text = "def helper(v):\n    return v\n\n\ndef show(x):\n    return f\"value={helper(x)!r:>4} {{helper}}\"\n" }});
    defer case.deinit();
    const planned = try case.plan("m.py", "helper", "double", true);
    defer planned.deinit(testing.allocator);
    try expectSource(planned, "m.py", "def double(v):\n    return v\n\n\ndef show(x):\n    return f\"value={double(x)!r:>4} {{helper}}\"\n");
}

test "rename facts: a C# method called inside an interpolated string is renamed there too" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const util =
        \\namespace Demo
        \\{
        \\    public static class Util
        \\    {
        \\        public static int Helper(int v) => v;
        \\        public static string Show(int x) => $"v={Helper(x),4:D} Helper";
        \\    }
        \\}
        \\
    ;
    var case = try Case.init(&.{.{ .rel = "src/Util.cs", .text = util }});
    defer case.deinit();
    const planned = try case.plan("src/Util.cs", "Demo.Util.Helper@static", "Twice", true);
    defer planned.deinit(testing.allocator);
    try expectSource(planned, "src/Util.cs",
        \\namespace Demo
        \\{
        \\    public static class Util
        \\    {
        \\        public static int Twice(int v) => v;
        \\        public static string Show(int x) => $"v={Twice(x),4:D} Helper";
        \\    }
        \\}
        \\
    );
}

test "rename facts: a Python class named inside a string annotation is a dynamic reference" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{
        .{ .rel = "m.py", .text = "class Box:\n    pass\n" },
        .{ .rel = "n.py", .text = "from m import Box\n\n\ndef f(xs: \"list[Box]\") -> Box:\n    return Box()\n" },
    });
    defer case.deinit();
    try testing.expectError(error.DynamicReference, case.plan("m.py", "Box", "Crate", true));
}

test "rename facts: an unproven reference refuses the rename and names every site it could not prove" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{
        .{ .rel = "svc.py", .text = "class Svc:\n    def run(self):\n        return 1\n" },
        .{ .rel = "use.py", .text = "def go(x):\n    return x.run()\n\n\ndef again(y):\n    return y.run()\n" },
    });
    defer case.deinit();
    var sites: rename_graph.Sites = .{};
    try testing.expectError(error.RenameUnresolved, case.planWith("svc.py", "Svc.run", "start", true, &sites));
    try testing.expectEqual(@as(usize, 2), sites.count);
    try testing.expectEqualStrings("use.py:2, use.py:6", sites.list());
}

test "rename facts: a Python method reached through a typed parameter, a constructed local or a constructor call is renamed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{
        .{ .rel = "m.py", .text = "class A:\n    def run(self):\n        return 1\n" },
        .{ .rel = "n.py", .text = "from m import A\n\n\ndef f(a: A, k: A = None):\n    return a.run() + k.run()\n\n\ndef g():\n    x = A()\n    return x.run()\n\n\ndef h():\n    return A().run()\n" },
    });
    defer case.deinit();
    const planned = try case.plan("m.py", "A.run", "go", true);
    defer planned.deinit(testing.allocator);
    try expectSource(planned, "n.py", "from m import A\n\n\ndef f(a: A, k: A = None):\n    return a.go() + k.go()\n\n\ndef g():\n    x = A()\n    return x.go()\n\n\ndef h():\n    return A().go()\n");
}

test "rename facts: every name of a Python from-import binds, not only the first" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{
        .{ .rel = "m.py", .text = "class A:\n    def run(self):\n        return 1\n\n\nclass B:\n    def run(self):\n        return 2\n" },
        .{ .rel = "n.py", .text = "from m import A, B\n\n\ndef g(b: B):\n    return b.run()\n" },
    });
    defer case.deinit();
    const planned = try case.plan("m.py", "B.run", "go", true);
    defer planned.deinit(testing.allocator);
    try expectSource(planned, "n.py", "from m import A, B\n\n\ndef g(b: B):\n    return b.go()\n");
}

test "rename facts: a Python local that is rebound, written through nonlocal or held at module level keeps no inferred type" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{.{ .rel = "m.py", .text = "class A:\n    def run(self):\n        return 1\n\n\nclass B:\n    def run(self):\n        return 2\n\n\ndef g(c):\n    x = A()\n    if c:\n        x = B()\n    return x.run()\n\n\ndef h():\n    y = A()\n    def inner():\n        nonlocal y\n        y = B()\n    inner()\n    return y.run()\n\n\nz = A()\nz.run()\n" }});
    defer case.deinit();
    var sites: rename_graph.Sites = .{};
    try testing.expectError(error.RenameUnresolved, case.planWith("m.py", "A.run", "go", true, &sites));
    try testing.expectEqualStrings("m.py:15, m.py:24, m.py:28", sites.list());
}

test "rename facts: a C# property reached bare, through var, target-typed new, a field or a parameter is renamed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const box =
        \\namespace App;
        \\public class Box
        \\{
        \\    public int Size { get; set; }
        \\    public int Twice() => Size * 2;
        \\}
        \\
    ;
    const user =
        \\namespace App;
        \\public class User
        \\{
        \\    private Box _b = new Box();
        \\    public int Get(Box p) { Box b = new(); var d = new Box(); b.Size = 4; return b.Size + d.Size + p.Size + _b.Size; }
        \\}
        \\
    ;
    var case = try Case.init(&.{ .{ .rel = "A.cs", .text = box }, .{ .rel = "B.cs", .text = user } });
    defer case.deinit();
    const planned = try case.plan("A.cs", "App.Box.Size", "Width", true);
    defer planned.deinit(testing.allocator);
    try expectSource(planned, "A.cs",
        \\namespace App;
        \\public class Box
        \\{
        \\    public int Width { get; set; }
        \\    public int Twice() => Width * 2;
        \\}
        \\
    );
    try expectSource(planned, "B.cs",
        \\namespace App;
        \\public class User
        \\{
        \\    private Box _b = new Box();
        \\    public int Get(Box p) { Box b = new(); var d = new Box(); b.Width = 4; return b.Width + d.Width + p.Width + _b.Width; }
        \\}
        \\
    );
}

test "rename facts: a Python function reached through a from-imported submodule or a package re-export is renamed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{
        .{ .rel = "p/__init__.py", .text = "from .m import helper\n" },
        .{ .rel = "p/m.py", .text = "def helper(v):\n    return v\n" },
        .{ .rel = "n.py", .text = "from p import m\n\nprint(m.helper(1))\n" },
        .{ .rel = "o.py", .text = "from p import helper\n\nprint(helper(2))\n" },
    });
    defer case.deinit();
    const planned = try case.plan("p/m.py", "helper", "double", true);
    defer planned.deinit(testing.allocator);
    try expectSource(planned, "p/__init__.py", "from .m import double\n");
    try expectSource(planned, "n.py", "from p import m\n\nprint(m.double(1))\n");
    try expectSource(planned, "o.py", "from p import double\n\nprint(double(2))\n");
}

test "rename facts: a Python submodule of a namespace package is reached, but a package attribute of the same name wins" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{
        .{ .rel = "q/m.py", .text = "def helper(v):\n    return v\n" },
        .{ .rel = "n.py", .text = "from q import m\n\nprint(m.helper(1))\n" },
    });
    defer case.deinit();
    const planned = try case.plan("q/m.py", "helper", "double", true);
    defer planned.deinit(testing.allocator);
    try expectSource(planned, "n.py", "from q import m\n\nprint(m.double(1))\n");

    var shadowed = try Case.init(&.{
        .{ .rel = "p/__init__.py", .text = "m = None\n" },
        .{ .rel = "p/m.py", .text = "def helper(v):\n    return v\n" },
        .{ .rel = "n.py", .text = "from p import m\n\nprint(m.helper(1))\n" },
    });
    defer shadowed.deinit();
    var sites: rename_graph.Sites = .{};
    try testing.expectError(error.RenameUnresolved, shadowed.planWith("p/m.py", "helper", "double", true, &sites));
    try testing.expectEqualStrings("n.py:3", sites.list());
}

test "rename facts: a Python import nested in if, try, def or a method is renamed with the function" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{
        .{ .rel = "m.py", .text = "def helper():\n    return 1\n" },
        .{ .rel = "a.py", .text = "import sys\nif sys.version_info >= (3, 8):\n    from m import helper\n\ndef use():\n    return helper()\n" },
        .{ .rel = "b.py", .text = "try:\n    from m import helper\nexcept ImportError:\n    raise\n" },
        .{ .rel = "c.py", .text = "def lazy():\n    from m import helper as h\n    return h()\n\nclass K:\n    def run(self):\n        import m\n        return m.helper()\n" },
    });
    defer case.deinit();
    const planned = try case.plan("m.py", "helper", "assist", true);
    defer planned.deinit(testing.allocator);
    try expectSource(planned, "a.py", "import sys\nif sys.version_info >= (3, 8):\n    from m import assist\n\ndef use():\n    return assist()\n");
    try expectSource(planned, "b.py", "try:\n    from m import assist\nexcept ImportError:\n    raise\n");
    try expectSource(planned, "c.py", "def lazy():\n    from m import assist as h\n    return h()\n\nclass K:\n    def run(self):\n        import m\n        return m.assist()\n");
}

test "rename facts: an import inside a Python function is not an attribute of its module" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{
        .{ .rel = "m.py", .text = "def helper():\n    return 1\n" },
        .{ .rel = "p/__init__.py", .text = "def f():\n    from m import helper\n    return helper()\n" },
        .{ .rel = "u.py", .text = "from p import helper\n" },
    });
    defer case.deinit();
    var sites: rename_graph.Sites = .{};
    try testing.expectError(error.RenameUnresolved, case.planWith("m.py", "helper", "assist", true, &sites));
    try testing.expectEqualStrings("u.py:1", sites.list());
}

test "rename facts: a Python absolute import inside a package reaches the root module, and two candidate roots refuse" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{
        .{ .rel = "m.py", .text = "def helper():\n    return 1\n" },
        .{ .rel = "p/__init__.py", .text = "" },
        .{ .rel = "p/m.py", .text = "VALUE = 3\n" },
        .{ .rel = "p/q.py", .text = "from m import helper\n\nhelper()\n" },
        .{ .rel = "src/s.py", .text = "from m import helper\n" },
    });
    defer case.deinit();
    const planned = try case.plan("m.py", "helper", "assist", true);
    defer planned.deinit(testing.allocator);
    try expectSource(planned, "p/q.py", "from m import assist\n\nassist()\n");
    try expectSource(planned, "src/s.py", "from m import assist\n");

    var ambiguous = try Case.init(&.{
        .{ .rel = "m.py", .text = "def helper():\n    return 1\n" },
        .{ .rel = "tools/m.py", .text = "VALUE = 2\n" },
        .{ .rel = "tools/run.py", .text = "from m import helper\n" },
    });
    defer ambiguous.deinit();
    var sites: rename_graph.Sites = .{};
    try testing.expectError(error.RenameUnresolved, ambiguous.planWith("m.py", "helper", "assist", true, &sites));
    try testing.expectEqualStrings("tools/run.py:1", sites.list());
}

test "rename facts: a C# property set in an object initializer or a with expression is renamed, and a same-named local on the right is kept" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{
        .{ .rel = "Pt.cs", .text = "namespace App;\npublic record Pt\n{\n    public int X { get; init; }\n}\n" },
        .{ .rel = "Use.cs", .text = "namespace App;\npublic static class Use\n{\n    public static Pt Move(Pt p) => p with { X = 4 };\n    public static Pt Make(int X) => new Pt() { X = X };\n    public static Pt Bare() => new Pt { X = 1 };\n}\n" },
    });
    defer case.deinit();
    const planned = try case.plan("Pt.cs", "App.Pt.X", "Left", true);
    defer planned.deinit(testing.allocator);
    try expectSource(planned, "Pt.cs", "namespace App;\npublic record Pt\n{\n    public int Left { get; init; }\n}\n");
    try expectSource(planned, "Use.cs", "namespace App;\npublic static class Use\n{\n    public static Pt Move(Pt p) => p with { Left = 4 };\n    public static Pt Make(int X) => new Pt() { Left = X };\n    public static Pt Bare() => new Pt { Left = 1 };\n}\n");
}

test "rename facts: a C# initializer whose type is not written at the new is refused at its line" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{
        .{ .rel = "Box.cs", .text = "namespace App;\npublic class Box\n{\n    public int Size { get; set; }\n}\n" },
        .{ .rel = "Use.cs", .text = "namespace App;\npublic static class Use\n{\n    public static Box Make() { Box b = new() { Size = 3 }; return b; }\n}\n" },
    });
    defer case.deinit();
    var sites: rename_graph.Sites = .{};
    try testing.expectError(error.RenameUnresolved, case.planWith("Box.cs", "App.Box.Size", "Width", true, &sites));
    try testing.expectEqualStrings("Use.cs:4", sites.list());
}

test "rename facts: a same-named C# property of another class is left alone beside the renamed one" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{
        .{ .rel = "Box.cs", .text = "namespace App;\npublic class Box\n{\n    public int Size { get; set; }\n}\npublic class Bag\n{\n    public int Size { get; set; }\n}\n" },
        .{ .rel = "Use.cs", .text = "namespace App;\npublic static class Use\n{\n    public static int Make(Box b, Bag g) => b.Size + g.Size + new Bag { Size = 2 }.Size;\n}\n" },
    });
    defer case.deinit();
    const planned = try case.plan("Box.cs", "App.Box.Size", "Width", true);
    defer planned.deinit(testing.allocator);
    try expectSource(planned, "Box.cs", "namespace App;\npublic class Box\n{\n    public int Width { get; set; }\n}\npublic class Bag\n{\n    public int Size { get; set; }\n}\n");
    try expectSource(planned, "Use.cs", "namespace App;\npublic static class Use\n{\n    public static int Make(Box b, Bag g) => b.Width + g.Size + new Bag { Size = 2 }.Size;\n}\n");
}

test "rename facts: a same-named C# property of a derived class is refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{
        .{ .rel = "Box.cs", .text = "namespace App;\npublic class Box\n{\n    public virtual int Size { get; set; }\n}\npublic class Bag : Box\n{\n    public override int Size { get; set; }\n}\n" },
        .{ .rel = "Use.cs", .text = "namespace App;\npublic static class Use\n{\n    public static int Make(Box b, Bag g) => b.Size + g.Size;\n}\n" },
    });
    defer case.deinit();
    try testing.expectError(error.RenameUnresolved, case.plan("Box.cs", "App.Box.Size", "Width", true));
}

test "rename facts: same-named Python methods of two classes on one line are told apart by their class" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{.{ .rel = "m.py", .text = "class A:\n    def run(self):\n        return 1\n\n\nclass B:\n    def run(self):\n        return 2\n\n\ndef main():\n    return A().run() + B().run()\n" }});
    defer case.deinit();
    const planned = try case.plan("m.py", "A.run", "go", true);
    defer planned.deinit(testing.allocator);
    try expectSource(planned, "m.py", "class A:\n    def go(self):\n        return 1\n\n\nclass B:\n    def run(self):\n        return 2\n\n\ndef main():\n    return A().go() + B().run()\n");
}
