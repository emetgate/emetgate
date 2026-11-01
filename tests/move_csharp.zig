const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");
const file_move = emetgate.file_move;
const move_batch = emetgate.move_batch;
const symbol = emetgate.symbol;
const Snapshot = emetgate.loader.Snapshot;
const fixture = @import("ts_fixture.zig");
const tool = @import("rename_tool.zig");

const testing = std.testing;
const Case = tool.Case;

fn moveFile(case: *Case, from_rel: []const u8, to_rel: []const u8, interface_change: bool) !file_move.Outcome {
    const from = try case.repo.abs(testing.allocator, from_rel);
    defer testing.allocator.free(from);
    const to = try case.repo.abs(testing.allocator, to_rel);
    defer testing.allocator.free(to);
    const text = try case.repo.read(from_rel);
    defer testing.allocator.free(text);
    return file_move.tryMoveFile(testing.allocator, testing.io, case.runtime, .{
        .request = .{ .from_abs = from, .to_abs = to, .from_hash = symbol.fileHash(text), .interface_change = interface_change },
        .test_command = "cmd /c exit 0",
    });
}

const Named = struct { ref_text: []u8, hash: symbol.Hash };

fn endsIn(ref: symbol.Ref, chain: []const u8) bool {
    var parts = std.mem.splitBackwardsScalar(u8, chain, '.');
    if (!std.mem.eql(u8, parts.first(), ref.name)) return false;
    var i = ref.container.len;
    while (parts.next()) |part| {
        if (i == 0) return false;
        i -= 1;
        if (!std.mem.eql(u8, part, ref.container[i])) return false;
    }
    return true;
}

fn named(case: *Case, file: []const u8, chain: []const u8) !Named {
    const snapshot = try Snapshot.load(case.runtime, testing.io, .cwd(), file);
    defer snapshot.destroy();
    const table = try snapshot.symbols();
    for (table.symbols) |s| {
        if (endsIn(s.ref, chain)) return .{ .ref_text = try std.fmt.allocPrint(testing.allocator, "{f}", .{s.ref}), .hash = s.hash };
    }
    for (table.declarations) |d| {
        if (endsIn(d.ref, chain)) return .{ .ref_text = try std.fmt.allocPrint(testing.allocator, "{f}", .{d.ref}), .hash = d.hash };
    }
    return error.SymbolNotFound;
}

const MoveArgs = struct {
    target_type: ?[]const u8 = null,
    interface_change: bool = true,
    order_change: bool = false,
};

fn move(case: *Case, rel: []const u8, chain: []const u8, target_rel: []const u8, args: MoveArgs) !move_batch.Outcome {
    const file = try case.repo.abs(testing.allocator, rel);
    defer testing.allocator.free(file);
    const target = try case.repo.abs(testing.allocator, target_rel);
    defer testing.allocator.free(target);
    const found = try named(case, file, chain);
    defer testing.allocator.free(found.ref_text);
    return move_batch.tryMove(testing.allocator, testing.io, case.runtime, .{
        .request = .{ .file_abs = file, .ref_text = found.ref_text, .expected_hash = found.hash, .target_abs = target, .target_type = args.target_type, .interface_change = args.interface_change, .order_change = args.order_change },
        .test_command = "cmd /c exit 0",
        .language_service = &case.session,
    });
}

fn expectFile(case: *Case, rel: []const u8, expected: []const u8) !void {
    const text = try case.repo.read(rel);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(expected, text);
}

fn refuseFile(files: []const fixture.File, from: []const u8, to: []const u8, expected: anyerror) !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(files, false);
    defer case.deinit();
    const before = try case.repo.read(from);
    defer testing.allocator.free(before);
    try testing.expectError(expected, moveFile(&case, from, to, true));
    try expectFile(&case, from, before);
}

fn refuseMove(files: []const fixture.File, rel: []const u8, ref_text: []const u8, target_rel: []const u8, args: MoveArgs, expected: anyerror) !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(files, false);
    defer case.deinit();
    const before = try case.repo.read(rel);
    defer testing.allocator.free(before);
    try testing.expectError(expected, move(&case, rel, ref_text, target_rel, args));
    try expectFile(&case, rel, before);
}

const cart_project = [_]fixture.File{
    .{ .rel = "src/Shop.csproj", .text = "<Project Sdk=\"Microsoft.NET.Sdk\"><PropertyGroup><RootNamespace>Shop</RootNamespace></PropertyGroup></Project>\n" },
    .{ .rel = "src/Models/Cart.cs", .text = "namespace Shop.Models;\n\npublic class Cart\n{\n    public int Total() => 1;\n}\n" },
    .{ .rel = "src/Models/Item.cs", .text = "namespace Shop.Models;\n\npublic class Item\n{\n}\n" },
    .{ .rel = "src/Program.cs", .text = "using Shop.Models;\n\nnamespace Shop;\n\npublic class Program\n{\n    public int Run() => new Cart().Total() + (new Item() == null ? 0 : 1);\n    public int Full() => new Shop.Models.Cart().Total();\n}\n" },
};

test "csharp move_file: a namespace that follows the folders follows the file, and users gain the using" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&cart_project, false);
    defer case.deinit();
    const outcome = try moveFile(&case, "src/Models/Cart.cs", "src/Billing/Cart.cs", true);
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try testing.expectEqual(file_move.Resolver.module_graph, outcome.plan.resolver);
    try testing.expect(std.mem.indexOf(u8, outcome.plan.note.?, "Shop.Billing") != null);
    try expectFile(&case, "src/Billing/Cart.cs", "namespace Shop.Billing;\n\npublic class Cart\n{\n    public int Total() => 1;\n}\n");
    try expectFile(&case, "src/Program.cs", "using Shop.Models;\nusing Shop.Billing;\n\nnamespace Shop;\n\npublic class Program\n{\n    public int Run() => new Cart().Total() + (new Item() == null ? 0 : 1);\n    public int Full() => new Shop.Billing.Cart().Total();\n}\n");
}

test "csharp move_file: moving the last file of a namespace replaces the old using" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&.{
        .{ .rel = "src/Shop.csproj", .text = "<Project Sdk=\"Microsoft.NET.Sdk\"><PropertyGroup><RootNamespace>Shop</RootNamespace></PropertyGroup></Project>\n" },
        .{ .rel = "src/Models/Cart.cs", .text = "namespace Shop.Models\n{\n    public class Cart\n    {\n    }\n}\n" },
        .{ .rel = "src/Program.cs", .text = "using Shop.Models;\n\nnamespace Shop;\n\npublic class Program\n{\n    public Cart Make() => new Cart();\n}\n" },
    }, false);
    defer case.deinit();
    const outcome = try moveFile(&case, "src/Models/Cart.cs", "src/Billing/Cart.cs", true);
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try expectFile(&case, "src/Billing/Cart.cs", "namespace Shop.Billing\n{\n    public class Cart\n    {\n    }\n}\n");
    try expectFile(&case, "src/Program.cs", "using Shop.Billing;\n\nnamespace Shop;\n\npublic class Program\n{\n    public Cart Make() => new Cart();\n}\n");
}

test "csharp move_file: the moved file gains a using for a neighbour it no longer sits beside" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&.{
        .{ .rel = "src/Shop.csproj", .text = "<Project Sdk=\"Microsoft.NET.Sdk\"><PropertyGroup><RootNamespace>Shop</RootNamespace></PropertyGroup></Project>\n" },
        .{ .rel = "src/Models/Cart.cs", .text = "using System;\n\nnamespace Shop.Models;\n\npublic class Cart\n{\n    public Item First() => new Item();\n}\n" },
        .{ .rel = "src/Models/Item.cs", .text = "namespace Shop.Models;\n\npublic class Item\n{\n}\n" },
    }, false);
    defer case.deinit();
    const outcome = try moveFile(&case, "src/Models/Cart.cs", "src/Billing/Cart.cs", true);
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try expectFile(&case, "src/Billing/Cart.cs", "using System;\nusing Shop.Models;\n\nnamespace Shop.Billing;\n\npublic class Cart\n{\n    public Item First() => new Item();\n}\n");
}

test "csharp move_file: a folder rename inside a namespace with its own prefix keeps the prefix" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&.{
        .{ .rel = "lib/Models/Cart.cs", .text = "namespace Acme.Core.Models;\n\npublic class Cart\n{\n}\n" },
    }, false);
    defer case.deinit();
    const outcome = try moveFile(&case, "lib/Models/Cart.cs", "lib/Billing/Cart.cs", true);
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try expectFile(&case, "lib/Billing/Cart.cs", "namespace Acme.Core.Billing;\n\npublic class Cart\n{\n}\n");
}

test "csharp move_file: moving into a subfolder extends a namespace named after the folder" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&.{
        .{ .rel = "lib/Models/Cart.cs", .text = "namespace Acme.Models;\n\npublic class Cart\n{\n}\n" },
    }, false);
    defer case.deinit();
    const outcome = try moveFile(&case, "lib/Models/Cart.cs", "lib/Models/Paid/Cart.cs", true);
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try expectFile(&case, "lib/Models/Paid/Cart.cs", "namespace Acme.Models.Paid;\n\npublic class Cart\n{\n}\n");
}

test "csharp move_file: a namespace that ignores the folders stays and the reply says so" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&.{
        .{ .rel = "lib/Models/Cart.cs", .text = "namespace Commerce;\n\npublic class Cart\n{\n}\n" },
        .{ .rel = "lib/Use.cs", .text = "using Commerce;\n\npublic class Use\n{\n    public Cart Make() => new Cart();\n}\n" },
    }, false);
    defer case.deinit();
    const outcome = try moveFile(&case, "lib/Models/Cart.cs", "lib/Billing/Cart.cs", false);
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try testing.expect(std.mem.indexOf(u8, outcome.plan.note.?, "does not follow the folders") != null);
    try expectFile(&case, "lib/Billing/Cart.cs", "namespace Commerce;\n\npublic class Cart\n{\n}\n");
    try expectFile(&case, "lib/Use.cs", "using Commerce;\n\npublic class Use\n{\n    public Cart Make() => new Cart();\n}\n");
}

test "csharp move_file: a type spread over two files keeps its namespace and the reply says so" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&.{
        .{ .rel = "src/Shop.csproj", .text = "<Project Sdk=\"Microsoft.NET.Sdk\"><PropertyGroup><RootNamespace>Shop</RootNamespace></PropertyGroup></Project>\n" },
        .{ .rel = "src/Models/Cart.cs", .text = "namespace Shop.Models;\n\npublic partial class Cart\n{\n}\n" },
        .{ .rel = "src/Models/CartExtra.cs", .text = "namespace Shop.Models;\n\npublic partial class Cart\n{\n}\n" },
    }, false);
    defer case.deinit();
    const outcome = try moveFile(&case, "src/Models/Cart.cs", "src/Billing/Cart.cs", false);
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try testing.expect(std.mem.indexOf(u8, outcome.plan.note.?, "another file") != null);
    try expectFile(&case, "src/Billing/Cart.cs", "namespace Shop.Models;\n\npublic partial class Cart\n{\n}\n");
}

test "csharp move_file: users to rewrite need interface_change" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&cart_project, false);
    defer case.deinit();
    try testing.expectError(error.InterfaceChangeNeedsApproval, moveFile(&case, "src/Models/Cart.cs", "src/Billing/Cart.cs", false));
    try expectFile(&case, "src/Models/Cart.cs", cart_project[1].text);
}

test "csharp move_file: a using alias of the emptied namespace is refused" {
    try refuseFile(&.{
        .{ .rel = "src/Shop.csproj", .text = "<Project Sdk=\"Microsoft.NET.Sdk\"><PropertyGroup><RootNamespace>Shop</RootNamespace></PropertyGroup></Project>\n" },
        .{ .rel = "src/Models/Cart.cs", .text = "namespace Shop.Models;\n\npublic class Cart\n{\n}\n" },
        .{ .rel = "src/Use.cs", .text = "using M = Shop.Models;\n\nnamespace Shop;\n\npublic class Use\n{\n    public M.Cart Make() => new M.Cart();\n}\n" },
    }, "src/Models/Cart.cs", "src/Billing/Cart.cs", error.CsNamespaceAlias);
}

test "csharp move_file: a type name the new namespace already holds is refused" {
    try refuseFile(&.{
        .{ .rel = "src/Shop.csproj", .text = "<Project Sdk=\"Microsoft.NET.Sdk\"><PropertyGroup><RootNamespace>Shop</RootNamespace></PropertyGroup></Project>\n" },
        .{ .rel = "src/Models/Cart.cs", .text = "namespace Shop.Models;\n\npublic class Cart\n{\n}\n" },
        .{ .rel = "src/Models/Other.cs", .text = "namespace Shop.Models;\n\npublic class Other\n{\n}\n" },
        .{ .rel = "src/Billing/Taken.cs", .text = "namespace Shop.Billing;\n\npublic class Cart\n{\n}\n" },
    }, "src/Models/Cart.cs", "src/Billing/Cart.cs", error.TargetNameTaken);
}

test "csharp move_file: a using that would make another name ambiguous is refused" {
    try refuseFile(&.{
        .{ .rel = "src/Shop.csproj", .text = "<Project Sdk=\"Microsoft.NET.Sdk\"><PropertyGroup><RootNamespace>Shop</RootNamespace></PropertyGroup></Project>\n" },
        .{ .rel = "src/Models/Cart.cs", .text = "namespace Shop.Models;\n\npublic class Cart\n{\n}\n" },
        .{ .rel = "src/Models/Other.cs", .text = "namespace Shop.Models;\n\npublic class Other\n{\n}\n" },
        .{ .rel = "src/Billing/Helper.cs", .text = "namespace Shop.Billing;\n\npublic class Helper\n{\n}\n" },
        .{ .rel = "src/Lib/Helper.cs", .text = "namespace Lib;\n\npublic class Helper\n{\n}\n" },
        .{ .rel = "src/Use.cs", .text = "using Lib;\nusing Shop.Models;\n\nnamespace App;\n\npublic class Use\n{\n    public Cart A() => new Cart();\n    public Helper B() => new Helper();\n}\n" },
    }, "src/Models/Cart.cs", "src/Billing/Cart.cs", error.CsAmbiguousType);
}

test "csharp move_file: a string naming the type is refused" {
    try refuseFile(&.{
        .{ .rel = "src/Shop.csproj", .text = "<Project Sdk=\"Microsoft.NET.Sdk\"><PropertyGroup><RootNamespace>Shop</RootNamespace></PropertyGroup></Project>\n" },
        .{ .rel = "src/Models/Cart.cs", .text = "namespace Shop.Models;\n\npublic class Cart\n{\n}\n" },
        .{ .rel = "src/Use.cs", .text = "namespace Shop;\n\npublic class Use\n{\n    public object Make() => System.Type.GetType(\"Shop.Models.Cart\");\n}\n" },
    }, "src/Models/Cart.cs", "src/Billing/Cart.cs", error.DynamicPathUse);
}

test "csharp move_file: a file listed by name in the project is refused" {
    try refuseFile(&.{
        .{ .rel = "src/Shop.csproj", .text = "<Project>\n  <ItemGroup>\n    <Compile Include=\"Models\\Cart.cs\" />\n  </ItemGroup>\n</Project>\n" },
        .{ .rel = "src/Models/Cart.cs", .text = "namespace Shop.Models;\n\npublic class Cart\n{\n}\n" },
    }, "src/Models/Cart.cs", "src/Billing/Cart.cs", error.CsCompileInclude);
}

test "csharp move_file: a skipped user fails the proof" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&cart_project, false);
    defer case.deinit();
    file_move.injected_fault = .skip_user;
    defer file_move.injected_fault = null;
    try testing.expectError(error.IncompleteMove, moveFile(&case, "src/Models/Cart.cs", "src/Billing/Cart.cs", true));
    try expectFile(&case, "src/Models/Cart.cs", cart_project[1].text);
}

test "csharp move: a type moves into another namespace and its users follow" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&.{
        .{ .rel = "src/Models/Cart.cs", .text = "using System;\n\nnamespace Shop.Models\n{\n    public class Item\n    {\n    }\n\n    public class Cart\n    {\n        public Item First() => new Item();\n        public DateTime When() => DateTime.Now;\n    }\n}\n" },
        .{ .rel = "src/Billing/Invoice.cs", .text = "namespace Shop.Billing\n{\n    public class Invoice\n    {\n    }\n}\n" },
        .{ .rel = "src/Use.cs", .text = "using Shop.Models;\n\nnamespace Shop\n{\n    public class Use\n    {\n        public Cart Make() => new Cart();\n        public Shop.Models.Cart Full() => new Shop.Models.Cart();\n        public Item Other() => new Item();\n    }\n}\n" },
    }, false);
    defer case.deinit();
    const outcome = try move(&case, "src/Models/Cart.cs", "Cart", "src/Billing/Invoice.cs", .{});
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try testing.expectEqual(move_batch.Resolver.module_graph, outcome.plan.resolver);
    try expectFile(&case, "src/Models/Cart.cs", "using System;\n\nnamespace Shop.Models\n{\n    public class Item\n    {\n    }\n}\n");
    try expectFile(&case, "src/Billing/Invoice.cs", "using Shop.Models;\nusing System;\n\nnamespace Shop.Billing\n{\n    public class Invoice\n    {\n    }\n\n    public class Cart\n    {\n        public Item First() => new Item();\n        public DateTime When() => DateTime.Now;\n    }\n}\n");
    try expectFile(&case, "src/Use.cs", "using Shop.Models;\nusing Shop.Billing;\n\nnamespace Shop\n{\n    public class Use\n    {\n        public Cart Make() => new Cart();\n        public Shop.Billing.Cart Full() => new Shop.Billing.Cart();\n        public Item Other() => new Item();\n    }\n}\n");
}

test "csharp move: a type moves to a new file and keeps its namespace" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&.{
        .{ .rel = "src/All.cs", .text = "using System;\n\nnamespace Shop;\n\npublic class Keep\n{\n}\n\npublic class Cart\n{\n    public DateTime When() => DateTime.Now;\n}\n" },
        .{ .rel = "src/Use.cs", .text = "namespace Shop;\n\npublic class Use\n{\n    public Cart Make() => new Cart();\n}\n" },
    }, false);
    defer case.deinit();
    const outcome = try move(&case, "src/All.cs", "Cart", "src/Cart.cs", .{ .interface_change = false });
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try testing.expectEqual(@as(usize, 0), outcome.plan.users);
    try expectFile(&case, "src/Cart.cs", "using System;\n\nnamespace Shop;\n\npublic class Cart\n{\n    public DateTime When() => DateTime.Now;\n}\n");
    try expectFile(&case, "src/Use.cs", "namespace Shop;\n\npublic class Use\n{\n    public Cart Make() => new Cart();\n}\n");
}

test "csharp move: a short type name the read tools accept moves too" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&.{
        .{ .rel = "src/Models/All.cs", .text = "namespace Shop.Models\n{\n    public class Cart\n    {\n    }\n\n    public class Line\n    {\n    }\n}\n" },
        .{ .rel = "src/Other/Holder.cs", .text = "namespace Shop.Other\n{\n    public class Holder\n    {\n    }\n}\n" },
        .{ .rel = "src/Use.cs", .text = "using Shop.Models;\n\nnamespace Shop\n{\n    public class Use\n    {\n        public Line Make() => new Line();\n    }\n}\n" },
    }, false);
    defer case.deinit();
    const file = try case.repo.abs(testing.allocator, "src/Models/All.cs");
    defer testing.allocator.free(file);
    const target = try case.repo.abs(testing.allocator, "src/Other/Holder.cs");
    defer testing.allocator.free(target);
    const found = try named(&case, file, "Line");
    defer testing.allocator.free(found.ref_text);
    const outcome = try move_batch.tryMove(testing.allocator, testing.io, case.runtime, .{
        .request = .{ .file_abs = file, .ref_text = "Line", .expected_hash = found.hash, .target_abs = target, .interface_change = true },
        .test_command = "cmd /c exit 0",
        .language_service = &case.session,
    });
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try testing.expectEqual(@as(usize, 1), outcome.plan.imports_added);
    try expectFile(&case, "src/Other/Holder.cs", "namespace Shop.Other\n{\n    public class Holder\n    {\n    }\n\n    public class Line\n    {\n    }\n}\n");
    try expectFile(&case, "src/Use.cs", "using Shop.Models;\nusing Shop.Other;\n\nnamespace Shop\n{\n    public class Use\n    {\n        public Line Make() => new Line();\n    }\n}\n");
}

test "csharp move: a type or member taken from the middle of a block brings no blank line along" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&.{
        .{ .rel = "src/All.cs", .text = "namespace Shop\n{\n    public class Z\n    {\n    }\n\n    public class A\n    {\n    }\n\n    public class B\n    {\n    }\n}\n" },
        .{ .rel = "src/Calc.cs", .text = "namespace Shop\n{\n    public static class Calc\n    {\n        public const int Base = 1;\n\n        public static int One() { return 1; }\n\n        public static int Two() { return One() + 1; }\n    }\n\n    public static class Target\n    {\n        public static int Zero() { return 0; }\n    }\n}\n" },
        .{ .rel = "src/To.cs", .text = "namespace Shop\n{\n    public class C\n    {\n    }\n}\n" },
    }, false);
    defer case.deinit();
    const moved_type = try move(&case, "src/All.cs", "A", "src/To.cs", .{});
    defer moved_type.deinit(testing.allocator);
    try testing.expect(moved_type.result == .committed);
    try expectFile(&case, "src/To.cs", "namespace Shop\n{\n    public class C\n    {\n    }\n\n    public class A\n    {\n    }\n}\n");
    const moved_member = try move(&case, "src/Calc.cs", "Calc.One", "src/Calc.cs", .{ .target_type = "Target" });
    defer moved_member.deinit(testing.allocator);
    try testing.expect(moved_member.result == .committed);
    try expectFile(&case, "src/Calc.cs", "namespace Shop\n{\n    public static class Calc\n    {\n        public const int Base = 1;\n\n        public static int Two() { return Target.One() + 1; }\n    }\n\n    public static class Target\n    {\n        public static int Zero() { return 0; }\n\n        public static int One() { return 1; }\n    }\n}\n");
}

fn expectTidyCut(moved: []const u8, left: []const u8) !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&.{
        .{ .rel = "src/Shop.csproj", .text = "<Project Sdk=\"Microsoft.NET.Sdk\"></Project>\n" },
        .{ .rel = "src/All.cs", .text = "namespace Shop\n{\n    public class A\n    {\n    }\n\n    public class B\n    {\n    }\n}\n" },
    }, false);
    defer case.deinit();
    const outcome = try move(&case, "src/All.cs", moved, "src/Moved.cs", .{});
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try expectFile(&case, "src/All.cs", left);
}

test "csharp move: a cut at either end of a block leaves no blank line" {
    try expectTidyCut("A", "namespace Shop\n{\n    public class B\n    {\n    }\n}\n");
    try expectTidyCut("B", "namespace Shop\n{\n    public class A\n    {\n    }\n}\n");
}

test "csharp move: a nested type is refused" {
    try refuseMove(&.{
        .{ .rel = "src/A.cs", .text = "namespace Shop;\n\npublic class Outer\n{\n    public class Inner\n    {\n    }\n}\n" },
        .{ .rel = "src/B.cs", .text = "namespace Shop;\n\npublic class B\n{\n}\n" },
    }, "src/A.cs", "Outer.Inner", "src/B.cs", .{}, error.NotTopLevel);
}

test "csharp move: a partial type crossing namespaces is refused" {
    try refuseMove(&.{
        .{ .rel = "src/A.cs", .text = "namespace Shop;\n\npublic partial class Cart\n{\n}\n" },
        .{ .rel = "src/B.cs", .text = "namespace Other;\n\npublic class B\n{\n}\n" },
    }, "src/A.cs", "Cart", "src/B.cs", .{}, error.CsPartialType);
}

test "csharp move: a name the target already has is refused" {
    try refuseMove(&.{
        .{ .rel = "src/A.cs", .text = "namespace Shop;\n\npublic class Cart\n{\n}\n" },
        .{ .rel = "src/B.cs", .text = "namespace Other;\n\npublic class Cart\n{\n}\n" },
    }, "src/A.cs", "Cart", "src/B.cs", .{}, error.TargetNameTaken);
}

test "csharp move: a public type changing namespace needs interface_change" {
    try refuseMove(&.{
        .{ .rel = "src/A.cs", .text = "namespace Shop;\n\npublic class Cart\n{\n}\n" },
        .{ .rel = "src/B.cs", .text = "namespace Other;\n\npublic class B\n{\n}\n" },
    }, "src/A.cs", "Cart", "src/B.cs", .{ .interface_change = false }, error.InterfaceChangeNeedsApproval);
}

const static_files = [_]fixture.File{
    .{ .rel = "src/Tools.cs", .text = "namespace Shop.Tools;\n\npublic static class Tools\n{\n    public static int Twice(int x) => x * 2;\n\n    public static int Four() => Twice(2);\n}\n" },
    .{ .rel = "src/Math.cs", .text = "namespace Shop.Numbers;\n\npublic static class Numbers\n{\n    public static int One() => 1;\n}\n" },
    .{ .rel = "src/Use.cs", .text = "using Shop.Tools;\n\nnamespace Shop;\n\npublic class Use\n{\n    public int A() => Tools.Twice(1);\n    public int B() => Tools.Tools.Four();\n}\n" },
};

test "csharp move: a static method moves between types and references follow" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&static_files, false);
    defer case.deinit();
    const outcome = try move(&case, "src/Tools.cs", "Tools.Twice", "src/Math.cs", .{ .target_type = "Numbers" });
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try testing.expectEqual(@as(usize, 1), outcome.plan.users);
    try expectFile(&case, "src/Math.cs", "namespace Shop.Numbers;\n\npublic static class Numbers\n{\n    public static int One() => 1;\n\n    public static int Twice(int x) => x * 2;\n}\n");
    const tools = try case.repo.read("src/Tools.cs");
    defer testing.allocator.free(tools);
    try testing.expect(std.mem.indexOf(u8, tools, "Twice(int") == null);
    try testing.expect(std.mem.indexOf(u8, tools, ".Twice(2)") != null);
    const use = try case.repo.read("src/Use.cs");
    defer testing.allocator.free(use);
    try testing.expect(std.mem.indexOf(u8, use, "Numbers.Twice(1)") != null);
    try testing.expect(std.mem.indexOf(u8, use, "Tools.Twice") == null);
}

test "csharp move: a static method moves between two types of one file" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&.{
        .{ .rel = "src/A.cs", .text = "namespace Shop;\n\npublic static class A\n{\n    internal static int One() => 1;\n}\n\npublic static class B\n{\n    public static int Two() => A.One() + 1;\n}\n" },
    }, false);
    defer case.deinit();
    const outcome = try move(&case, "src/A.cs", "A.One", "src/A.cs", .{ .target_type = "B" });
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try expectFile(&case, "src/A.cs", "namespace Shop;\n\npublic static class A\n{\n}\n\npublic static class B\n{\n    public static int Two() => B.One() + 1;\n\n    internal static int One() => 1;\n}\n");
}

test "csharp move: an instance member is refused" {
    try refuseMove(&.{
        .{ .rel = "src/A.cs", .text = "namespace Shop;\n\npublic class A\n{\n    public int One() => 1;\n}\n" },
        .{ .rel = "src/B.cs", .text = "namespace Shop;\n\npublic class B\n{\n}\n" },
    }, "src/A.cs", "A.One", "src/B.cs", .{}, error.MoveNotStatic);
}

test "csharp move: a target file with two types needs target_type" {
    try refuseMove(&.{
        .{ .rel = "src/A.cs", .text = "namespace Shop;\n\npublic static class A\n{\n    public static int One() => 1;\n}\n" },
        .{ .rel = "src/B.cs", .text = "namespace Shop;\n\npublic class B\n{\n}\n\npublic class C\n{\n}\n" },
    }, "src/A.cs", "A.One", "src/B.cs", .{}, error.MoveNeedsTargetType);
}

test "csharp move: a member using another member of its type is refused" {
    try refuseMove(&.{
        .{ .rel = "src/A.cs", .text = "namespace Shop;\n\npublic static class A\n{\n    private static int Base() => 1;\n    public static int One() => Base() + 1;\n}\n" },
        .{ .rel = "src/B.cs", .text = "namespace Shop;\n\npublic class B\n{\n}\n" },
    }, "src/A.cs", "A.One", "src/B.cs", .{}, error.MoveMemberDependency);
}

test "csharp move: a member reached through using static is refused" {
    try refuseMove(&.{
        .{ .rel = "src/A.cs", .text = "namespace Shop;\n\npublic static class A\n{\n    public static int One() => 1;\n}\n" },
        .{ .rel = "src/B.cs", .text = "namespace Shop;\n\npublic class B\n{\n}\n" },
        .{ .rel = "src/C.cs", .text = "using static Shop.A;\n\nnamespace Shop;\n\npublic class C\n{\n    public int Go() => One();\n}\n" },
    }, "src/A.cs", "A.One", "src/B.cs", .{}, error.MoveMemberDependency);
}

test "csharp move: a name the receiving type has is refused" {
    try refuseMove(&.{
        .{ .rel = "src/A.cs", .text = "namespace Shop;\n\npublic static class A\n{\n    public static int One() => 1;\n}\n" },
        .{ .rel = "src/B.cs", .text = "namespace Shop;\n\npublic static class B\n{\n    public static int One() => 2;\n}\n" },
    }, "src/A.cs", "A.One", "src/B.cs", .{}, error.TargetNameTaken);
}

test "csharp move: a string naming the member is refused" {
    try refuseMove(&.{
        .{ .rel = "src/A.cs", .text = "namespace Shop;\n\npublic static class A\n{\n    public static int One() => 1;\n}\n" },
        .{ .rel = "src/B.cs", .text = "namespace Shop;\n\npublic static class B\n{\n}\n" },
        .{ .rel = "src/C.cs", .text = "namespace Shop;\n\npublic class C\n{\n    public string Name = \"Shop.A.One\";\n}\n" },
    }, "src/A.cs", "A.One", "src/B.cs", .{}, error.DynamicReference);
}
