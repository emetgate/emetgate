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
    try testing.expectError(error.IncompleteRename, rename_batch.plan(testing.allocator, testing.io, case.runtime, case.repo.root_abs, .{
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

test "rename facts: a C# class named only as a parameter type in another file is renamed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    {
        var case = try Case.init(&.{
            .{ .rel = "Tool.cs", .text = "public class Tool\n{\n    public int Run() { return 1; }\n}\n" },
            .{ .rel = "Use.cs", .text = "public class Use\n{\n    public int Go(Tool t) { return 1; }\n}\n" },
        });
        defer case.deinit();
        const planned = try case.plan("Tool.cs", "Tool", "Device", true);
        defer planned.deinit(testing.allocator);
        try expectSource(planned, "Use.cs", "public class Use\n{\n    public int Go(Device t) { return 1; }\n}\n");
    }
    {
        var case = try Case.init(&.{
            .{ .rel = "Tool.cs", .text = "namespace Shop\n{\npublic class Tool\n{\n    public int Run() { return 1; }\n}\n}\n" },
            .{ .rel = "Use.cs", .text = "namespace Shop.Sub\n{\npublic class Use\n{\n    public int Go(Tool t) { return 1; }\n}\n}\n" },
        });
        defer case.deinit();
        const planned = try case.plan("Tool.cs", "Shop.Tool", "Device", true);
        defer planned.deinit(testing.allocator);
        try expectSource(planned, "Use.cs", "namespace Shop.Sub\n{\npublic class Use\n{\n    public int Go(Device t) { return 1; }\n}\n}\n");
    }
    {
        var case = try Case.init(&.{
            .{ .rel = "Tool.cs", .text = "namespace Shop\n{\npublic class Tool\n{\n    public int Run() { return 1; }\n}\n}\n" },
            .{ .rel = "Use.cs", .text = "using Shop;\n\npublic class Use\n{\n    public int Go(Tool t) { return 1; }\n}\n" },
        });
        defer case.deinit();
        const planned = try case.plan("Tool.cs", "Shop.Tool", "Device", true);
        defer planned.deinit(testing.allocator);
        try expectSource(planned, "Use.cs", "using Shop;\n\npublic class Use\n{\n    public int Go(Device t) { return 1; }\n}\n");
    }
}

test "rename facts: a Python method through a local built by a factory in a file that never names the method is renamed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{
        .{ .rel = "models.py", .text = "class Cart:\n    def total(self):\n        return 1\n" },
        .{ .rel = "factory.py", .text = "from models import Cart\n\n\ndef make_cart():\n    return Cart()\n" },
        .{ .rel = "use.py", .text = "from factory import make_cart as mk\n\n\ndef first():\n    c = mk()\n    return c.total()\n" },
    });
    defer case.deinit();
    const planned = try case.plan("models.py", "Cart.total", "grand", true);
    defer planned.deinit(testing.allocator);
    try expectSource(planned, "use.py", "from factory import make_cart as mk\n\n\ndef first():\n    c = mk()\n    return c.grand()\n");
}

test "rename facts: a C# method through var built by a factory in a file that never names the method is renamed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{
        .{ .rel = "Models.cs", .text = "namespace Shop.Models\n{\n    public class Cart\n    {\n        public int Total() { return 1; }\n    }\n}\n" },
        .{ .rel = "Factory.cs", .text = "namespace Shop.Models\n{\n    public static class Factory\n    {\n        public static Cart Make() { return new Cart(); }\n    }\n}\n" },
        .{ .rel = "Use.cs", .text = "namespace App\n{\n    public class Use\n    {\n        public int Go() { var c = Shop.Models.Factory.Make(); return c.Total(); }\n    }\n}\n" },
    });
    defer case.deinit();
    const planned = try case.plan("Models.cs", "Shop.Models.Cart.Total", "Grand", true);
    defer planned.deinit(testing.allocator);
    try expectSource(planned, "Use.cs", "namespace App\n{\n    public class Use\n    {\n        public int Go() { var c = Shop.Models.Factory.Make(); return c.Grand(); }\n    }\n}\n");
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
    {
        var case = try Case.init(&.{
            .{ .rel = "q/m.py", .text = "def helper(v):\n    return v\n" },
            .{ .rel = "n.py", .text = "from q import m\n\nprint(m.helper(1))\n" },
        });
        defer case.deinit();
        const planned = try case.plan("q/m.py", "helper", "double", true);
        defer planned.deinit(testing.allocator);
        try expectSource(planned, "n.py", "from q import m\n\nprint(m.double(1))\n");
    }
    {
        var case = try Case.init(&.{
            .{ .rel = "r/__init__.py", .text = "x = None\n" },
            .{ .rel = "r/m.py", .text = "def helper(v):\n    return v\n" },
            .{ .rel = "n.py", .text = "from r import m\n\nprint(m.helper(1))\n" },
        });
        defer case.deinit();
        const planned = try case.plan("r/m.py", "helper", "double", true);
        defer planned.deinit(testing.allocator);
        try expectSource(planned, "n.py", "from r import m\n\nprint(m.double(1))\n");
    }

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
    {
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
    }

    var ambiguous = try Case.init(&.{
        .{ .rel = "m.py", .text = "def helper():\n    return 1\n" },
        .{ .rel = "tools/m.py", .text = "def helper():\n    return 2\n" },
        .{ .rel = "tools/run.py", .text = "from m import helper\n" },
    });
    defer ambiguous.deinit();
    var sites: rename_graph.Sites = .{};
    try testing.expectError(error.RenameUnresolved, ambiguous.planWith("m.py", "helper", "assist", true, &sites));
    try testing.expectEqualStrings("tools/run.py:1", sites.list());
}

test "rename facts: a Python import that a same-named module never loaded for the rename could answer is refused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{
        .{ .rel = "m.py", .text = "def helper():\n    return 1\n" },
        .{ .rel = "tools/m.py", .text = "VALUE = 2\n" },
        .{ .rel = "tools/run.py", .text = "from m import helper\n" },
    });
    defer case.deinit();
    var sites: rename_graph.Sites = .{};
    try testing.expectError(error.RenameUnresolved, case.planWith("m.py", "helper", "assist", true, &sites));
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

test "rename facts: a member read through a class that has no such member and no base is left alone" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{
        .{ .rel = "Box.cs", .text = "namespace App;\npublic class Box\n{\n    public int Size { get; set; }\n}\npublic class Bag\n{\n}\n" },
        .{ .rel = "Use.cs", .text = "namespace App;\npublic static class Use\n{\n    public static int Make(Box b) => b.Size + new Bag().Size;\n}\n" },
    });
    defer case.deinit();
    const planned = try case.plan("Box.cs", "App.Box.Size", "Width", true);
    defer planned.deinit(testing.allocator);
    try expectSource(planned, "Use.cs", "namespace App;\npublic static class Use\n{\n    public static int Make(Box b) => b.Width + new Bag().Size;\n}\n");
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

test "rename facts: a Python __all__ entry naming the renamed module function is renamed with it" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{.{ .rel = "m.py", .text = "__all__ = [\"helper\", \"other\"]\n\n\ndef helper():\n    return 1\n\n\ndef other():\n    return helper()\n" }});
    defer case.deinit();
    const planned = try case.plan("m.py", "helper", "assist", true);
    defer planned.deinit(testing.allocator);
    try expectSource(planned, "m.py", "__all__ = [\"assist\", \"other\"]\n\n\ndef assist():\n    return 1\n\n\ndef other():\n    return assist()\n");
}

test "rename facts: a package __all__ built by assignment, augmented assignment, append and extend is renamed with its re-export" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{
        .{ .rel = "pkg/__init__.py", .text = "from .m import helper\n\n__all__ = (\"helper\",)\n__all__ += [\"helper\"]\n__all__.append('helper')\n__all__.extend([\"helper\"])\n" },
        .{ .rel = "pkg/m.py", .text = "def helper():\n    return 1\n" },
        .{ .rel = "main.py", .text = "from pkg import helper\n\nprint(helper())\n" },
    });
    defer case.deinit();
    const planned = try case.plan("pkg/m.py", "helper", "assist", true);
    defer planned.deinit(testing.allocator);
    try expectSource(planned, "pkg/__init__.py", "from .m import assist\n\n__all__ = (\"assist\",)\n__all__ += [\"assist\"]\n__all__.append('assist')\n__all__.extend([\"assist\"])\n");
    try expectSource(planned, "main.py", "from pkg import assist\n\nprint(assist())\n");
}

test "rename facts: an __all__ entry whose module binds the name under an alias is still a dynamic reference" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{
        .{ .rel = "pkg/__init__.py", .text = "from .m import helper as h\n\n__all__ = [\"helper\", \"h\"]\n" },
        .{ .rel = "pkg/m.py", .text = "def helper():\n    return 1\n" },
    });
    defer case.deinit();
    try testing.expectError(error.DynamicReference, case.plan("pkg/m.py", "helper", "assist", true));
}

test "rename facts: a string naming the function outside a top-level __all__ is still a dynamic reference" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const sources = [_][]const u8{
        "__all__ = [\"helper\"] + []\n\n\ndef helper():\n    return 1\n",
        "names = [\"helper\"]\n\n\ndef helper():\n    return 1\n",
        "def helper():\n    __all__ = [\"helper\"]\n    return __all__\n",
        "__all__ = [r\"helper\"]\n\n\ndef helper():\n    return 1\n",
        "key = f\"helper\"\n\n\ndef helper():\n    return 1\n",
        "other.__all__.append(\"helper\")\n\n\ndef helper():\n    return 1\n",
        "__all__ = [\"helper\"]\n\n\ndef helper():\n    return 1\n\n\ndef via(mod):\n    return getattr(mod, \"helper\")\n",
    };
    for (sources) |source| {
        var case = try Case.init(&.{.{ .rel = "m.py", .text = source }});
        defer case.deinit();
        try testing.expectError(error.DynamicReference, case.plan("m.py", "helper", "assist", true));
    }
}

test "rename facts: a top-level __all__ entry naming a nested function of the same name is still a dynamic reference" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{.{ .rel = "m.py", .text = "__all__ = [\"helper\"]\n\n\ndef outer():\n    def helper():\n        return 1\n    return helper()\n" }});
    defer case.deinit();
    try testing.expectError(error.DynamicReference, case.plan("m.py", "outer.helper", "assist", true));
}

test "rename facts: a Python method through a local built by a function with one provable return type is renamed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{
        .{ .rel = "cart.py", .text = "class Cart:\n    def total(self):\n        return 1\n\n\ndef make_cart():\n    return Cart()\n\n\ndef relay():\n    c = make_cart()\n    return c\n\n\ndef annotated() -> Cart:\n    return make_cart()\n\n\ndef both(x):\n    if x:\n        return Cart()\n    return Cart()\n\n\nclass Factory:\n    def make(self) -> Cart:\n        return Cart()\n\n    @staticmethod\n    def fresh() -> Cart:\n        return Cart()\n\n\nclass Sub(Factory):\n    pass\n" },
        .{ .rel = "use.py", .text = "import cart\nfrom cart import Factory, Sub, annotated, both, make_cart, relay\n\n\ndef a():\n    c = make_cart()\n    return c.total()\n\n\ndef b():\n    c = annotated()\n    return c.total()\n\n\ndef d():\n    f = Factory()\n    c = f.make()\n    return c.total()\n\n\ndef e():\n    return make_cart().total()\n\n\ndef g():\n    c = cart.make_cart()\n    return c.total()\n\n\ndef h():\n    c = relay()\n    return c.total()\n\n\ndef i():\n    c = both(1)\n    return c.total()\n\n\ndef j():\n    c = Sub().make()\n    return c.total()\n\n\ndef k(f: Factory):\n    c = f.make()\n    return c.total()\n\n\ndef l():\n    c = Factory.fresh()\n    return c.total()\n" },
    });
    defer case.deinit();
    var sites: rename_graph.Sites = .{};
    const planned = try case.planWith("cart.py", "Cart.total", "grand", true, &sites);
    defer planned.deinit(testing.allocator);
    try expectSource(planned, "use.py", "import cart\nfrom cart import Factory, Sub, annotated, both, make_cart, relay\n\n\ndef a():\n    c = make_cart()\n    return c.grand()\n\n\ndef b():\n    c = annotated()\n    return c.grand()\n\n\ndef d():\n    f = Factory()\n    c = f.make()\n    return c.grand()\n\n\ndef e():\n    return make_cart().grand()\n\n\ndef g():\n    c = cart.make_cart()\n    return c.grand()\n\n\ndef h():\n    c = relay()\n    return c.grand()\n\n\ndef i():\n    c = both(1)\n    return c.grand()\n\n\ndef j():\n    c = Sub().make()\n    return c.grand()\n\n\ndef k(f: Factory):\n    c = f.make()\n    return c.grand()\n\n\ndef l():\n    c = Factory.fresh()\n    return c.grand()\n");
}

test "rename facts: a Python method through a local whose type cannot be proven refuses and names every site" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{.{ .rel = "m.py", .text = "import outside\nfrom outside import wrap\n\n\nclass Cart:\n    def total(self):\n        return 1\n\n\nclass Other:\n    def total(self):\n        return 2\n\n\nasync def later():\n    return Cart()\n\n\n@wrap\ndef decorated():\n    return Cart()\n\n\ndef gen():\n    yield Cart()\n\n\ndef either(x):\n    if x:\n        return Cart()\n    return Other()\n\n\ndef nothing():\n    return None\n\n\ndef bare():\n    return\n\n\ndef param(x):\n    return x\n\n\ndef spelled() -> \"Cart\":\n    return Cart()\n\n\ndef swapped():\n    return Cart()\n\n\nswapped = param\n\n\ndef rebound():\n    return Cart()\n\n\ndef rebind():\n    global rebound\n    rebound = param\n\n\ndef twice():\n    return Cart()\n\n\ndef twice():\n    return Other()\n\n\ndef nested():\n    def inner():\n        return Other()\n    return inner\n\n\ndef rebound_local(x):\n    y = Cart()\n    if x:\n        y = Other()\n    return y\n\n\nclass Builder:\n    def build(self):\n        return Cart()\n\n\ndef go1():\n    c = later()\n    return c.total()\n\n\ndef go2():\n    c = decorated()\n    return c.total()\n\n\ndef go3():\n    c = gen()\n    return c.total()\n\n\ndef go4():\n    c = either(1)\n    return c.total()\n\n\ndef go5():\n    c = nothing()\n    return c.total()\n\n\ndef go6():\n    c = bare()\n    return c.total()\n\n\ndef go7():\n    c = param(1)\n    return c.total()\n\n\ndef go8():\n    c = spelled()\n    return c.total()\n\n\ndef go9():\n    c = swapped()\n    return c.total()\n\n\ndef go10():\n    c = rebound()\n    return c.total()\n\n\ndef go11():\n    c = twice()\n    return c.total()\n\n\ndef go12():\n    c = nested()\n    return c.total()\n\n\ndef go13():\n    c = rebound_local(1)\n    return c.total()\n\n\ndef go14():\n    c = Builder().build()\n    return c.total()\n\n\ndef go15(make):\n    c = make()\n    return c.total()\n\n\ndef go16():\n    c = outside.make()\n    return c.total()\n\n\ndef go17():\n    c = Cart()\n    c = Other()\n    return c.total()\n\n\ndef go18():\n    other = Cart()\n    c = other.total()\n    d = c\n    return d.total()\n" }});
    defer case.deinit();
    var sites: rename_graph.Sites = .{};
    try testing.expectError(error.RenameUnresolved, case.planWith("m.py", "Cart.total", "grand", true, &sites));
    try testing.expectEqual(@as(usize, 18), sites.count);
    try testing.expectEqualStrings("m.py:94, m.py:99, m.py:104, m.py:109, m.py:114, m.py:119, m.py:124, m.py:129, m.py:134, m.py:139", sites.list()[0..@min(sites.list().len, 96)]);
}

test "rename facts: a Python local stops being typed when the function it was built from is rebound" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{.{ .rel = "m.py", .text = "class Cart:\n    def total(self):\n        return 1\n\n\ndef make():\n    return Cart()\n\n\ndef go(x):\n    y = make()\n    if x:\n        y = x\n    c = y\n    return y.total()\n" }});
    defer case.deinit();
    var sites: rename_graph.Sites = .{};
    try testing.expectError(error.RenameUnresolved, case.planWith("m.py", "Cart.total", "grand", true, &sites));
    try testing.expectEqualStrings("m.py:15", sites.list());
}

test "rename facts: a Python local built through a rebound local stays unproven" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{.{ .rel = "m.py", .text = "class Cart:\n    def total(self):\n        return 1\n\n\nclass Box:\n    def cart(self) -> Cart:\n        return Cart()\n\n\ndef make():\n    return Box()\n\n\ndef go(x):\n    y = make()\n    if x:\n        y = x\n    c = y.cart()\n    return c.total()\n" }});
    defer case.deinit();
    var sites: rename_graph.Sites = .{};
    try testing.expectError(error.RenameUnresolved, case.planWith("m.py", "Cart.total", "grand", true, &sites));
    try testing.expectEqualStrings("m.py:20", sites.list());
}

test "rename facts: a Python generator that also returns a constructor gives no type" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{ .{ .rel = "m.py", .text = "class Cart:\n    def total(self):\n        return 1\n\n\ndef gen():\n    yield 1\n    return Cart()\n\n\ndef go():\n    c = gen()\n    return c.total()\n" } });
    defer case.deinit();
    var sites: rename_graph.Sites = .{};
    try testing.expectError(error.RenameUnresolved, case.planWith("m.py", "Cart.total", "grand", true, &sites));
    try testing.expectEqualStrings("m.py:13", sites.list());
}

test "rename facts: a Python call of a name its own file rebinds gives no type" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{ .{ .rel = "cart.py", .text = "class Cart:\n    def total(self):\n        return 1\n\n\ndef make():\n    return Cart()\n" }, .{ .rel = "use.py", .text = "from cart import make\n\nmake = print\n\n\ndef go():\n    c = make()\n    return c.total()\n" } });
    defer case.deinit();
    var sites: rename_graph.Sites = .{};
    try testing.expectError(error.RenameUnresolved, case.planWith("cart.py", "Cart.total", "grand", true, &sites));
    try testing.expectEqualStrings("use.py:8", sites.list());
}

test "rename facts: a Python function its module rebinds gives no type to an importer" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{ .{ .rel = "cart.py", .text = "class Cart:\n    def total(self):\n        return 1\n\n\ndef make():\n    return Cart()\n\n\nmake = print\n" }, .{ .rel = "use.py", .text = "from cart import make\n\n\ndef go():\n    c = make()\n    return c.total()\n" } });
    defer case.deinit();
    var sites: rename_graph.Sites = .{};
    try testing.expectError(error.RenameUnresolved, case.planWith("cart.py", "Cart.total", "grand", true, &sites));
    try testing.expectEqualStrings("use.py:6", sites.list());
}

test "rename facts: a C# method through var from a call with a declared return type is renamed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{
        .{ .rel = "Cart.cs", .text = "namespace Shop.Models\n{\n    public class Cart\n    {\n        public int Total() { return 1; }\n        public Cart Self() { return this; }\n    }\n\n    public static class Factory\n    {\n        public static Cart Make() { return new Cart(); }\n        public static Cart Maybe() { return null; }\n    }\n\n    public class Builder\n    {\n        public Cart Build() { return new Cart(); }\n        public Cart? Nullable() { return null; }\n    }\n\n    public class G<T>\n    {\n        public int Size() { return 1; }\n        public Cart Item() { return new Cart(); }\n    }\n}\n" },
        .{ .rel = "Use.cs", .text = "using Shop.Models;\nusing static Shop.Models.Factory;\n\nnamespace Shop.App\n{\n    public class Use\n    {\n        private Cart Local() { return new Cart(); }\n\n        public int A() { var c = Shop.Models.Factory.Make(); return c.Total(); }\n        public int B() { var c = Factory.Make(); return c.Total(); }\n        public int D() { var f = new Builder(); var c = f.Build(); return c.Total(); }\n        public int E() { var c = new Builder().Nullable(); return c.Total(); }\n        public int F() { var c = Make(); return c.Total(); }\n        public int H() { var c = Local(); return c.Total(); }\n        public int I() { return Factory.Make().Total(); }\n        public int J() { var g = new G<int>(); var c = g.Item(); return c.Total(); }\n        public int K() { var c = Factory.Make().Self(); return c.Total(); }\n        public int L() { var c = new Shop.Models.Cart(); return c.Total(); }\n    }\n}\n" },
    });
    defer case.deinit();
    var sites: rename_graph.Sites = .{};
    const planned = try case.planWith("Cart.cs", "Shop.Models.Cart.Total", "Grand", true, &sites);
    defer planned.deinit(testing.allocator);
    try expectSource(planned, "Use.cs", "using Shop.Models;\nusing static Shop.Models.Factory;\n\nnamespace Shop.App\n{\n    public class Use\n    {\n        private Cart Local() { return new Cart(); }\n\n        public int A() { var c = Shop.Models.Factory.Make(); return c.Grand(); }\n        public int B() { var c = Factory.Make(); return c.Grand(); }\n        public int D() { var f = new Builder(); var c = f.Build(); return c.Grand(); }\n        public int E() { var c = new Builder().Nullable(); return c.Grand(); }\n        public int F() { var c = Make(); return c.Grand(); }\n        public int H() { var c = Local(); return c.Grand(); }\n        public int I() { return Factory.Make().Grand(); }\n        public int J() { var g = new G<int>(); var c = g.Item(); return c.Grand(); }\n        public int K() { var c = Factory.Make().Self(); return c.Grand(); }\n        public int L() { var c = new Shop.Models.Cart(); return c.Grand(); }\n    }\n}\n");
}

test "rename facts: a C# method through var whose type cannot be proven refuses and names every site" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{
        .{ .rel = "Models.cs", .text = "using System.Threading.Tasks;\n\nnamespace Shop.Models\n{\n    public class Cart\n    {\n        public int Total() { return 1; }\n    }\n\n    public class T\n    {\n        public int Total() { return 1; }\n    }\n\n    public static class Maker\n    {\n        public static Cart Two() { return new Cart(); }\n        public static Cart Two(int x) { return new Cart(); }\n        public static U Pick<U>() { return default(U); }\n        public static dynamic Loose() { return null; }\n        public static async Task<Cart> Later() { await Task.Yield(); return new Cart(); }\n    }\n\n    public class G<T>\n    {\n        public T Get() { return default(T); }\n    }\n\n    public class Mixed\n    {\n        public static Cart Mix() { return new Cart(); }\n        public T Mix(int x) { return new T(); }\n        public int Go() { var c = Mix(1); return c.Total(); }\n    }\n\n    public class Base { }\n}\n" },
        .{ .rel = "Use.cs", .text = "using Shop.Models;\nusing Elsewhere;\n\nnamespace Shop.App\n{\n    public class Use : Outside\n    {\n        public int A() { var c = Maker.Two(); return c.Total(); }\n        public int B() { var c = Maker.Pick<Cart>(); return c.Total(); }\n        public int D() { var c = Maker.Loose(); return c.Total(); }\n        public int E() { var c = Maker.Later(); return c.Total(); }\n        public int F() { var c = new G<Cart>().Get(); return c.Total(); }\n        public int H() { dynamic c = new Cart(); return c.Total(); }\n        public int I() { var c = Unknown(); return c.Total(); }\n        public int J() { var c = Missing.Make(); return c.Total(); }\n    }\n}\n" },
    });
    defer case.deinit();
    var sites: rename_graph.Sites = .{};
    try testing.expectError(error.RenameUnresolved, case.planWith("Models.cs", "Shop.Models.Cart.Total", "Grand", true, &sites));
    try testing.expectEqual(@as(usize, 9), sites.count);
}

test "rename facts: a C# call in a partial class whose other part may overload it gives no type" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{
        .{ .rel = "P1.cs", .text = "public class Cart\n{\n    public int Total() { return 1; }\n}\n\npublic class Box\n{\n    public int Total() { return 2; }\n}\n\npublic partial class Maker\n{\n    public Cart Make() { return new Cart(); }\n    public int Go() { var c = Make(); return c.Total(); }\n}\n" },
        .{ .rel = "P2.cs", .text = "public partial class Maker\n{\n    public Box Make(int x) { return new Box(); }\n}\n" },
    });
    defer case.deinit();
    var sites: rename_graph.Sites = .{};
    try testing.expectError(error.RenameUnresolved, case.planWith("P1.cs", "Cart.Total", "Grand", true, &sites));
    try testing.expectEqualStrings("P1.cs:14", sites.list());
}

test "rename facts: a qualified C# call in a partial class whose other part may overload it gives no type" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var qualified = try Case.init(&.{
        .{ .rel = "Q1.cs", .text = "namespace Shop\n{\n    public class Cart\n    {\n        public int Total() { return 1; }\n    }\n\n    public partial class Maker\n    {\n        public static Cart Make() { return new Cart(); }\n    }\n}\n" },
        .{ .rel = "Q2.cs", .text = "namespace Shop\n{\n    public class Box\n    {\n        public int Size() { return 2; }\n    }\n\n    public partial class Maker\n    {\n        public static Box Make(int x) { return new Box(); }\n    }\n}\n" },
        .{ .rel = "Use.cs", .text = "public class Use\n{\n    public int Go() { var c = Shop.Maker.Make(1); return c.Total(); }\n}\n" },
    });
    defer qualified.deinit();
    var through: rename_graph.Sites = .{};
    try testing.expectError(error.RenameUnresolved, qualified.planWith("Q1.cs", "Shop.Cart.Total", "Grand", true, &through));
    try testing.expectEqualStrings("Use.cs:3", through.list());
}

test "rename facts: a C# type parameter is never the class of the same name" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{
        .{ .rel = "T.cs", .text = "public class T\n{\n    public static T Make() { return null; }\n    public int Total() { return 1; }\n}\n" },
        .{ .rel = "G.cs", .text = "public class G<T>\n{\n    public T Get() { return default(T); }\n    public T Fresh() { return T.Make(); }\n}\n" },
        .{ .rel = "Use.cs", .text = "public class Use\n{\n    public int A() { var c = new G<int>().Get(); return c.Total(); }\n}\n" },
    });
    defer case.deinit();
    var sites: rename_graph.Sites = .{};
    try testing.expectError(error.RenameUnresolved, case.planWith("T.cs", "T.Total", "Grand", true, &sites));
    try testing.expectEqualStrings("Use.cs:3", sites.list());
}

test "rename facts: a C# type parameter hides a class of the same name in its own file" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case = try Case.init(&.{.{ .rel = "T.cs", .text = "public class T\n{\n    public static T Make() { return null; }\n    public int Total() { return 1; }\n}\n\npublic class G<T>\n{\n    public T Get() { return default(T); }\n    public int Viewed(T item) { return item.Total(); }\n    public T Built() { return T.Make(); }\n}\n\npublic class H\n{\n    public static T Pick<T>() { return default(T); }\n    public int A() { var c = new G<int>().Get(); return c.Total(); }\n    public int B() { var c = Pick<int>(); return c.Total(); }\n}\n" }});
    defer case.deinit();
    var sites: rename_graph.Sites = .{};
    try testing.expectError(error.RenameUnresolved, case.planWith("T.cs", "T.Total", "Grand", true, &sites));
    try testing.expectEqualStrings("T.cs:10, T.cs:17, T.cs:18", sites.list());
}
