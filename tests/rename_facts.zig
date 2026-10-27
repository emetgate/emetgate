const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");
const rename_batch = emetgate.rename_batch;
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
        const file = try self.repo.abs(testing.allocator, rel);
        defer testing.allocator.free(file);
        const hash = try self.hashOf(file, ref_text);
        return rename_batch.plan(testing.allocator, testing.io, self.runtime, self.repo.root_abs, .{
            .file_abs = file,
            .ref_text = ref_text,
            .expected_hash = hash,
            .new_name = new_name,
            .interface_change = interface_change,
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
