const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");
const file_move = emetgate.file_move;
const move_batch = emetgate.move_batch;
const symbol = emetgate.symbol;
const batch = emetgate.batch;
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

fn expectFile(case: *Case, rel: []const u8, expected: []const u8) !void {
    const text = try case.repo.read(rel);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(expected, text);
}

fn refuse(files: []const fixture.File, from: []const u8, to: []const u8, expected: anyerror) !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(files, false);
    defer case.deinit();
    const before = try case.repo.read(files[0].rel);
    defer testing.allocator.free(before);
    try testing.expectError(expected, moveFile(&case, from, to, false));
    try expectFile(&case, files[0].rel, before);
}

test "python move_file: every import form follows the module and the moved file keeps its own imports" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&.{
        .{ .rel = "pkg/__init__.py", .text = "" },
        .{ .rel = "pkg/app.py", .text = "from .cart import Cart\nfrom . import cart\nimport pkg.cart as pc\n\ndef run():\n    return Cart(), cart.make(), pc.make()\n" },
        .{ .rel = "pkg/cart.py", .text = "class Cart:\n    pass\n\ndef make():\n    return Cart()\n" },
        .{ .rel = "pkg/core/__init__.py", .text = "" },
        .{ .rel = "pkg/other.py", .text = "from .app import run\nfrom . import app\nfrom . import app as a2, cart\nimport pkg.app\nimport pkg.app as pa\n\ndef go():\n    return run(), app.run(), a2.run(), pkg.app.run(), pa.run(), cart.make()\n" },
        .{ .rel = "tests/test_app.py", .text = "from pkg.app import run\nfrom pkg import app\n\ndef test_run():\n    assert run() and app.run()\n" },
    }, false);
    defer case.deinit();
    const outcome = try moveFile(&case, "pkg/app.py", "pkg/core/app.py", false);
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try testing.expectEqual(file_move.Resolver.module_graph, outcome.plan.resolver);
    try testing.expectEqual(@as(usize, 2), outcome.plan.users);
    try expectFile(&case, "pkg/core/app.py", "from ..cart import Cart\nfrom .. import cart\nimport pkg.cart as pc\n\ndef run():\n    return Cart(), cart.make(), pc.make()\n");
    try expectFile(&case, "pkg/other.py", "from .core.app import run\nfrom .core import app\nfrom . import cart\nfrom .core import app as a2\nimport pkg.core.app\nimport pkg.core.app as pa\n\ndef go():\n    return run(), app.run(), a2.run(), pkg.core.app.run(), pa.run(), cart.make()\n");
    try expectFile(&case, "tests/test_app.py", "from pkg.core.app import run\nfrom pkg.core import app\n\ndef test_run():\n    assert run() and app.run()\n");
    try testing.expectError(error.FileNotFound, case.repo.read("pkg/app.py"));
}

test "python move_file: a rename keeps the local name through an alias" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&.{
        .{ .rel = "pkg/__init__.py", .text = "" },
        .{ .rel = "pkg/app.py", .text = "VALUE = 1\n" },
        .{ .rel = "pkg/use.py", .text = "from . import app\nfrom pkg import app as mine\n\nprint(app.VALUE, mine.VALUE)\n" },
    }, false);
    defer case.deinit();
    const outcome = try moveFile(&case, "pkg/app.py", "pkg/main.py", false);
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try expectFile(&case, "pkg/use.py", "from . import main as app\nfrom pkg import main as mine\n\nprint(app.VALUE, mine.VALUE)\n");
}

test "python move_file: a name the package __init__ binds is that binding, and the re-export follows the move" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&.{
        .{ .rel = "pkg/__init__.py", .text = "from .app import app\n" },
        .{ .rel = "pkg/app.py", .text = "def app():\n    return 1\n" },
        .{ .rel = "pkg/core/__init__.py", .text = "" },
        .{ .rel = "use.py", .text = "from pkg import app\n\nprint(app())\n" },
    }, false);
    defer case.deinit();
    const outcome = try moveFile(&case, "pkg/app.py", "pkg/core/app.py", false);
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try expectFile(&case, "pkg/__init__.py", "from .core.app import app\n");
    try expectFile(&case, "use.py", "from pkg import app\n\nprint(app())\n");
}

test "python move_file: leaving the package for the repo root turns a from-import into import" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&.{
        .{ .rel = "pkg/__init__.py", .text = "" },
        .{ .rel = "pkg/app.py", .text = "VALUE = 1\n" },
        .{ .rel = "use.py", .text = "from pkg import app\nimport pkg.app\n\nprint(app.VALUE, pkg.app.VALUE)\n" },
    }, false);
    defer case.deinit();
    const outcome = try moveFile(&case, "pkg/app.py", "top.py", false);
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try expectFile(&case, "use.py", "import top as app\nimport top\n\nprint(app.VALUE, top.VALUE)\n");
}

test "python move_file: a script's sibling import is rewritten when its script root changes" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&.{
        .{ .rel = "scripts/helpers.py", .text = "VALUE = 1\n" },
        .{ .rel = "scripts/run.py", .text = "import helpers\n\nprint(helpers.VALUE)\n" },
        .{ .rel = "tools/keep.py", .text = "" },
    }, false);
    defer case.deinit();
    const outcome = try moveFile(&case, "scripts/run.py", "tools/run.py", false);
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try expectFile(&case, "tools/run.py", "import scripts.helpers\n\nprint(scripts.helpers.VALUE)\n");
}

test "python move_file: reaching the module through its package attribute is refused" {
    try refuse(&.{
        .{ .rel = "use.py", .text = "import pkg\n\nprint(pkg.app.VALUE)\n" },
        .{ .rel = "pkg/__init__.py", .text = "" },
        .{ .rel = "pkg/app.py", .text = "VALUE = 1\n" },
    }, "pkg/app.py", "pkg/main.py", error.PyChainThroughPackage);
}

test "python move_file: a string naming the module is refused" {
    try refuse(&.{
        .{ .rel = "use.py", .text = "import unittest.mock as m\n\nm.patch(\"pkg.app.VALUE\")\n" },
        .{ .rel = "pkg/__init__.py", .text = "" },
        .{ .rel = "pkg/app.py", .text = "VALUE = 1\n" },
    }, "pkg/app.py", "pkg/main.py", error.DynamicPathUse);
}

test "python move_file: a computed import_module near the module's name is refused" {
    try refuse(&.{
        .{ .rel = "use.py", .text = "import importlib\n\nname = \"app\"\nimportlib.import_module(\"pkg.\" + name)\n" },
        .{ .rel = "pkg/__init__.py", .text = "" },
        .{ .rel = "pkg/app.py", .text = "VALUE = 1\n" },
    }, "pkg/app.py", "pkg/main.py", error.DynamicPathUse);
}

test "python move_file: a third-party import the moved file would capture is refused" {
    try refuse(&.{
        .{ .rel = "use.py", .text = "import requests\n\nprint(requests.get)\n" },
        .{ .rel = "pkg/requests2.py", .text = "VALUE = 1\n" },
    }, "pkg/requests2.py", "requests.py", error.PyNameCapture);
}

test "python move_file: a package __init__ with modules beside it is refused" {
    try refuse(&.{
        .{ .rel = "pkg/__init__.py", .text = "" },
        .{ .rel = "pkg/app.py", .text = "VALUE = 1\n" },
    }, "pkg/__init__.py", "lib/__init__.py", error.PyInitWithSiblings);
}

test "python move_file: a stub beside the module is refused" {
    try refuse(&.{
        .{ .rel = "app.py", .text = "VALUE = 1\n" },
        .{ .rel = "app.pyi", .text = "VALUE: int\n" },
    }, "app.py", "main.py", error.PyStubCompanion);
}

test "python move_file: a directory that is no identifier is refused when something imports the module" {
    try refuse(&.{
        .{ .rel = "use.py", .text = "import app\n\nprint(app.VALUE)\n" },
        .{ .rel = "app.py", .text = "VALUE = 1\n" },
    }, "app.py", "not-ident/app.py", error.PyTargetNotImportable);
}

test "python move_file: a module named in pyproject needs interface_change" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&.{
        .{ .rel = "pyproject.toml", .text = "[project.scripts]\ngo = \"pkg.app:main\"\n" },
        .{ .rel = "pkg/__init__.py", .text = "" },
        .{ .rel = "pkg/app.py", .text = "def main():\n    pass\n" },
    }, false);
    defer case.deinit();
    try testing.expectError(error.InterfaceChangeNeedsApproval, moveFile(&case, "pkg/app.py", "pkg/main.py", false));
    const outcome = try moveFile(&case, "pkg/app.py", "pkg/main.py", true);
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try testing.expect(outcome.plan.interface_change);
}

test "python move_file: a skipped user fails the proof" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&.{
        .{ .rel = "pkg/__init__.py", .text = "" },
        .{ .rel = "pkg/app.py", .text = "VALUE = 1\n" },
        .{ .rel = "use.py", .text = "from pkg.app import VALUE\n" },
    }, false);
    defer case.deinit();
    file_move.injected_fault = .skip_user;
    defer file_move.injected_fault = null;
    try testing.expectError(error.IncompleteMove, moveFile(&case, "pkg/app.py", "pkg/main.py", false));
}

fn hashOf(case: *Case, file: []const u8, ref_text: []const u8) !symbol.Hash {
    const snapshot = try Snapshot.load(case.runtime, testing.io, .cwd(), file);
    defer snapshot.destroy();
    const table = try snapshot.symbols();
    const ref = try symbol.Ref.parse(testing.allocator, ref_text);
    defer ref.deinit(testing.allocator);
    if (table.resolve(ref)) |found| return found.hash else |_| {}
    for (table.declarations) |d| if (d.ref.eql(ref)) return d.hash;
    return error.SymbolNotFound;
}

fn moveSymbol(case: *Case, rel: []const u8, name: []const u8, target_rel: []const u8, interface_change: bool, order_change: bool) !move_batch.Outcome {
    const file = try case.repo.abs(testing.allocator, rel);
    defer testing.allocator.free(file);
    const target = try case.repo.abs(testing.allocator, target_rel);
    defer testing.allocator.free(target);
    return move_batch.tryMove(testing.allocator, testing.io, case.runtime, .{
        .request = .{ .file_abs = file, .ref_text = name, .expected_hash = try hashOf(case, file, name), .target_abs = target, .interface_change = interface_change, .order_change = order_change },
        .test_command = "cmd /c exit 0",
        .language_service = &case.session,
    });
}

fn refuseSymbol(files: []const fixture.File, rel: []const u8, name: []const u8, target_rel: []const u8, expected: anyerror) !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(files, false);
    defer case.deinit();
    const before = try case.repo.read(rel);
    defer testing.allocator.free(before);
    try testing.expectError(expected, moveSymbol(&case, rel, name, target_rel, true, true));
    try expectFile(&case, rel, before);
}

fn expectHas(case: *Case, rel: []const u8, needle: []const u8) !void {
    const text = try case.repo.read(rel);
    defer testing.allocator.free(text);
    if (std.mem.indexOf(u8, text, needle) == null) {
        std.debug.print("{s} lacks {s}:\n{s}\n", .{ rel, needle, text });
        return error.TestExpectedEqual;
    }
}

fn expectLacks(case: *Case, rel: []const u8, needle: []const u8) !void {
    const text = try case.repo.read(rel);
    defer testing.allocator.free(text);
    if (std.mem.indexOf(u8, text, needle) != null) {
        std.debug.print("{s} has {s}:\n{s}\n", .{ rel, needle, text });
        return error.TestExpectedEqual;
    }
}

test "python move: importers of every form follow a function to its new module" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&.{
        .{ .rel = "pkg/__init__.py", .text = "" },
        .{ .rel = "pkg/cart.py", .text = "def make():\n    return 1\n\ndef keep():\n    return 2\n" },
        .{ .rel = "pkg/shop.py", .text = "def other():\n    return 3\n" },
        .{ .rel = "pkg/a.py", .text = "from .cart import make, keep\n\nprint(make(), keep())\n" },
        .{ .rel = "pkg/b.py", .text = "from pkg.cart import make as build\n\nprint(build())\n" },
        .{ .rel = "pkg/c.py", .text = "from . import cart\n\nprint(cart.make(), cart.keep())\n" },
        .{ .rel = "pkg/d.py", .text = "import pkg.cart\n\nprint(pkg.cart.make())\n" },
        .{ .rel = "pkg/e.py", .text = "import pkg.cart as c\n\nprint(c.make(), c.keep())\n" },
    }, false);
    defer case.deinit();
    const outcome = try moveSymbol(&case, "pkg/cart.py", "make", "pkg/shop.py", true, false);
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try testing.expectEqual(move_batch.Resolver.module_graph, outcome.plan.resolver);
    try expectFile(&case, "pkg/cart.py", "def keep():\n    return 2\n");
    try expectHas(&case, "pkg/shop.py", "def make():\n    return 1\n");
    try expectHas(&case, "pkg/a.py", "shop import make");
    try expectHas(&case, "pkg/a.py", "cart import keep");
    try expectHas(&case, "pkg/b.py", "from pkg.shop import make as build");
    try expectHas(&case, "pkg/c.py", "shop.make()");
    try expectHas(&case, "pkg/c.py", "cart.keep()");
    try expectHas(&case, "pkg/d.py", "pkg.shop.make()");
    try expectLacks(&case, "pkg/e.py", "c.make()");
    try expectHas(&case, "pkg/e.py", "c.keep()");
}

test "python move: what the moved code uses comes along and the source imports what it still needs" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&.{
        .{ .rel = "pkg/__init__.py", .text = "" },
        .{ .rel = "pkg/cart.py", .text = "import json\n\ndef make():\n    return json.dumps(1)\n\ndef keep():\n    return make()\n" },
    }, false);
    defer case.deinit();
    const outcome = try moveSymbol(&case, "pkg/cart.py", "make", "pkg/shop.py", true, false);
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try expectHas(&case, "pkg/shop.py", "import json");
    try expectHas(&case, "pkg/shop.py", "def make():");
    try expectHas(&case, "pkg/cart.py", "import make");
    try expectLacks(&case, "pkg/cart.py", "def make():");
}

test "python move: a docstring, a constant and calls inside functions are no module effect" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&.{
        .{ .rel = "pkg/__init__.py", .text = "" },
        .{ .rel = "pkg/cart.py", .text = "\"\"\"Cart.\"\"\"\n\nLIMIT = 3\n\ndef keep():\n    return print(LIMIT)\n\ndef make():\n    return print(2)\n" },
        .{ .rel = "pkg/shop.py", .text = "\"\"\"Shop.\"\"\"\n\ndef other():\n    return print(3)\n" },
    }, false);
    defer case.deinit();
    const outcome = try moveSymbol(&case, "pkg/cart.py", "make", "pkg/shop.py", true, false);
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try expectFile(&case, "pkg/cart.py", "\"\"\"Cart.\"\"\"\n\nLIMIT = 3\n\ndef keep():\n    return print(LIMIT)\n");
    try expectHas(&case, "pkg/shop.py", "def make():\n    return print(2)\n");
}

fn refuseOrder(cart: []const u8, name: []const u8) !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&.{
        .{ .rel = "pkg/__init__.py", .text = "" },
        .{ .rel = "pkg/cart.py", .text = cart },
        .{ .rel = "pkg/shop.py", .text = "def other():\n    return 3\n" },
    }, false);
    defer case.deinit();
    if (moveSymbol(&case, "pkg/cart.py", name, "pkg/shop.py", true, false)) |outcome| {
        outcome.deinit(testing.allocator);
        return error.TestExpectedError;
    } else |err| try testing.expectEqual(error.ModuleSideEffect, err);
    try expectFile(&case, "pkg/cart.py", cart);
}

test "python move: a cut between two declarations leaves one gap" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&.{
        .{ .rel = "pkg/__init__.py", .text = "" },
        .{ .rel = "pkg/cart.py", .text = "def keep():\n    return 1\n\n\ndef make():\n    return 2\n\n\ndef last():\n    return 3\n" },
        .{ .rel = "pkg/shop.py", .text = "def other():\n    return 3\n" },
    }, false);
    defer case.deinit();
    const outcome = try moveSymbol(&case, "pkg/cart.py", "make", "pkg/shop.py", true, false);
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.result == .committed);
    try expectFile(&case, "pkg/cart.py", "def keep():\n    return 1\n\n\ndef last():\n    return 3\n");
}

test "python move: code that runs at import needs order_change" {
    try refuseOrder("def make():\n    return 1\n\n@wrap\ndef other():\n    return 2\n", "make");
    try refuseOrder("def make():\n    return 1\n\ntotal = 0\ntotal += 1\n", "make");
    try refuseOrder("print(1)\n\ndef make():\n    return 1\n", "make");
    try refuseOrder("def make(x=print(1)):\n    return 1\n", "make");
    try refuseOrder("def other():\n    return 2\n\nclass Make:\n    x = print(1)\n", "Make");
    try refuseOrder("import os\n\nos.limit = 3\n\ndef make():\n    return 1\n", "make");
    try refuseOrder("def make():\n    return 1\n\nLIMIT = print(1)\n", "make");
}

test "python move: a dropped user import fails the proof" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&.{
        .{ .rel = "pkg/__init__.py", .text = "" },
        .{ .rel = "pkg/cart.py", .text = "def make():\n    return 1\n" },
        .{ .rel = "pkg/shop.py", .text = "def other():\n    return 3\n" },
        .{ .rel = "pkg/a.py", .text = "from .cart import make\n\nprint(make())\n" },
    }, false);
    defer case.deinit();
    move_batch.injected_fault = .drop_user_import;
    defer move_batch.injected_fault = null;
    try testing.expectError(error.IncompleteMove, moveSymbol(&case, "pkg/cart.py", "make", "pkg/shop.py", true, false));
    try expectFile(&case, "pkg/cart.py", "def make():\n    return 1\n");
}

test "python move: users to rewrite need interface_change" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init(&.{
        .{ .rel = "pkg/__init__.py", .text = "" },
        .{ .rel = "pkg/cart.py", .text = "def make():\n    return 1\n" },
        .{ .rel = "pkg/shop.py", .text = "def other():\n    return 3\n" },
        .{ .rel = "pkg/a.py", .text = "from .cart import make\n\nprint(make())\n" },
    }, false);
    defer case.deinit();
    try testing.expectError(error.InterfaceChangeNeedsApproval, moveSymbol(&case, "pkg/cart.py", "make", "pkg/shop.py", false, false));
}

test "python move: a name the target binds is refused" {
    try refuseSymbol(&.{
        .{ .rel = "pkg/__init__.py", .text = "" },
        .{ .rel = "pkg/cart.py", .text = "def make():\n    return 1\n" },
        .{ .rel = "pkg/shop.py", .text = "def make():\n    return 3\n" },
    }, "pkg/cart.py", "make", "pkg/shop.py", error.TargetNameTaken);
}

test "python move: a function touching module state through global is refused" {
    try refuseSymbol(&.{
        .{ .rel = "pkg/__init__.py", .text = "" },
        .{ .rel = "pkg/cart.py", .text = "count = 0\n\ndef make():\n    global count\n    count += 1\n" },
        .{ .rel = "pkg/shop.py", .text = "def other():\n    return 3\n" },
    }, "pkg/cart.py", "make", "pkg/shop.py", error.PyGlobalState);
}

test "python move: a function reading a module dunder is refused" {
    try refuseSymbol(&.{
        .{ .rel = "pkg/__init__.py", .text = "" },
        .{ .rel = "pkg/cart.py", .text = "def make():\n    return __file__\n" },
        .{ .rel = "pkg/shop.py", .text = "def other():\n    return 3\n" },
    }, "pkg/cart.py", "make", "pkg/shop.py", error.PyModuleDunder);
}

test "python move: a future import the target lacks is refused" {
    try refuseSymbol(&.{
        .{ .rel = "pkg/__init__.py", .text = "" },
        .{ .rel = "pkg/cart.py", .text = "from __future__ import annotations\n\ndef make(x: Later):\n    return 1\n" },
        .{ .rel = "pkg/shop.py", .text = "def other():\n    return 3\n" },
    }, "pkg/cart.py", "make", "pkg/shop.py", error.PyFutureMismatch);
}
