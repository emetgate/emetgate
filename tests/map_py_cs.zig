const std = @import("std");
const emetgate = @import("emetgate");
const map = emetgate.map;
const map_tools = emetgate.map_tools;
const map_listing = emetgate.map_listing;
const fact_file = emetgate.fact_file;
const test_util = emetgate.test_util;
const git_fixture = @import("git_fixture.zig");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const File = struct { path: []const u8, data: []const u8 };

fn git(root: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(testing.allocator);
    try argv.append(testing.allocator, "git");
    try argv.appendSlice(testing.allocator, args);
    const result = try emetgate.bounded_run.run(testing.allocator, testing.io, .{ .argv = argv.items, .cwd = .{ .path = root } });
    testing.allocator.free(result.stdout);
    testing.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitFailed,
        else => return error.GitFailed,
    }
}

fn expectHas(text: []const u8, part: []const u8) !void {
    if (std.mem.indexOf(u8, text, part) != null) return;
    std.debug.print("missing: {s}\n--- text ---\n{s}\n", .{ part, text });
    return error.TestExpectedEqual;
}

fn expectLacks(text: []const u8, part: []const u8) !void {
    if (std.mem.indexOf(u8, text, part) == null) return;
    std.debug.print("unexpected: {s}\n--- text ---\n{s}\n", .{ part, text });
    return error.TestExpectedEqual;
}

const Project = struct {
    runtime: *emetgate.runtime.Runtime,
    tmp: std.testing.TmpDir,
    base: [:0]u8,
    root: []u8,
    store_path: []u8,
    session: *map_tools.Session,
    arena_state: std.heap.ArenaAllocator,

    fn open(files: []const File) !*Project {
        const self = try testing.allocator.create(Project);
        errdefer testing.allocator.destroy(self);
        const runtime = try test_util.openRuntime();
        var tmp = testing.tmpDir(.{});
        try tmp.dir.createDirPath(testing.io, "repo");
        for (files) |f| {
            const sub = try std.fmt.allocPrint(testing.allocator, "repo/{s}", .{f.path});
            defer testing.allocator.free(sub);
            if (std.fs.path.dirnamePosix(sub)) |d| try tmp.dir.createDirPath(testing.io, d);
            try tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = f.data });
        }
        const base = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        const root = try std.fmt.allocPrint(testing.allocator, "{s}\\repo", .{base});
        try git_fixture.initRepo(root);
        try git(root, &.{ "add", "." });
        const store_path = try std.fmt.allocPrint(testing.allocator, "{s}\\store\\facts.v{d}", .{ base, fact_file.version });
        const session = try map_tools.Session.create(testing.allocator, testing.io, runtime, root);
        session.store_override = store_path;
        try session.build();
        self.* = .{ .runtime = runtime, .tmp = tmp, .base = base, .root = root, .store_path = store_path, .session = session, .arena_state = std.heap.ArenaAllocator.init(testing.allocator) };
        return self;
    }

    fn close(self: *Project) void {
        self.arena_state.deinit();
        self.session.destroy();
        testing.allocator.free(self.store_path);
        testing.allocator.free(self.root);
        testing.allocator.free(self.base);
        self.tmp.cleanup();
        test_util.closeRuntime(self.runtime);
        testing.allocator.destroy(self);
    }

    fn arena(self: *Project) Allocator {
        return self.arena_state.allocator();
    }

    fn built(self: *Project) !map.Map {
        return map.buildMap(self.arena(), &self.session.repo.?.store, .{ .lines = .names });
    }

    fn family(self: *Project, path: []const u8) !map.Family {
        const m = try self.built();
        const id = m.regionOfPath(path) orelse return error.TestUnexpectedResult;
        return m.regions[id].family;
    }
};

test "map python: a file is a test by its name, its folder or what it imports and declares, and a word in a name is not enough" {
    const p = try Project.open(&.{
        .{ .path = "app/core.py", .data = "def run():\n    return 1\n" },
        .{ .path = "app/test_core.py", .data = "def check():\n    return 1\n" },
        .{ .path = "app/core_test.py", .data = "def check():\n    return 1\n" },
        .{ .path = "app/conftest.py", .data = "def fixture_one():\n    return 1\n" },
        .{ .path = "tests/helpers.py", .data = "def make():\n    return 1\n" },
        .{ .path = "app/check_math.py", .data = "import unittest\n\nclass Math(unittest.TestCase):\n    def test_add(self):\n        self.assertEqual(2, 1 + 1)\n" },
        .{ .path = "app/uses_pytest.py", .data = "import pytest\n\ndef test_x():\n    assert True\n" },
        .{ .path = "app/latest_news.py", .data = "def latest():\n    return 1\n\ndef test_connection():\n    return True\n\nclass TestCase:\n    pass\n" },
        .{ .path = "app/contest.py", .data = "def score():\n    return 1\n" },
    });
    defer p.close();
    for ([_][]const u8{ "app/test_core.py", "app/core_test.py", "app/conftest.py", "tests/helpers.py", "app/check_math.py", "app/uses_pytest.py" }) |path| {
        try testing.expectEqual(map.Family.tests, try p.family(path));
    }
    for ([_][]const u8{ "app/core.py", "app/latest_news.py", "app/contest.py" }) |path| {
        try testing.expectEqual(map.Family.code, try p.family(path));
    }
}

test "map python: a Blueprint route carries the prefix its registration states over the one it declares" {
    const p = try Project.open(&.{
        .{ .path = "web/__init__.py", .data = "from flask import Flask\nfrom .admin import admin_bp\nfrom .shop import views\n\napp = Flask(__name__)\napp.register_blueprint(admin_bp, url_prefix=\"/admin\")\napp.register_blueprint(views.shop_bp)\n\n@app.route(\"/health\")\ndef health():\n    return \"ok\"\n" },
        .{ .path = "web/admin.py", .data = "from flask import Blueprint\n\nadmin_bp = Blueprint(\"admin\", __name__, url_prefix=\"/replaced\")\n\n@admin_bp.route(\"/users\", methods=[\"GET\", \"POST\"])\ndef users():\n    return []\n" },
        .{ .path = "web/shop/__init__.py", .data = "" },
        .{ .path = "web/shop/views.py", .data = "from flask import Blueprint\n\nshop_bp = Blueprint(\"shop\", __name__, url_prefix=\"/shop\")\n\n@shop_bp.post(\"/items\")\ndef create():\n    return 2\n" },
    });
    defer p.close();
    const m = try p.built();
    try expectHas(m.text, "GET,POST /admin/users users");
    try expectLacks(m.text, "/replaced/users");
    try expectHas(m.text, "POST /shop/items create");
    try expectHas(m.text, "GET /health health");
}

test "map python: an APIRouter included twice shows both mounted paths and a computed path stays visibly computed" {
    const p = try Project.open(&.{
        .{ .path = "api/__init__.py", .data = "" },
        .{ .path = "api/main.py", .data = "from fastapi import FastAPI\nfrom .items import router as items_router\nfrom . import users\n\napp = FastAPI()\napp.include_router(items_router, prefix=\"/v1\")\napp.include_router(items_router, prefix=\"/v2\")\napp.include_router(users.router, prefix=\"/api\")\n" },
        .{ .path = "api/items.py", .data = "from fastapi import APIRouter\n\nrouter = APIRouter(prefix=\"/items\")\n\n@router.put(\"/{id}\")\ndef put_item(id):\n    return id\n" },
        .{ .path = "api/users.py", .data = "from fastapi import APIRouter\nfrom .conf import settings\n\nrouter = APIRouter(prefix=\"/users\")\n\n@router.get(\"\")\ndef list_users():\n    return []\n\n@router.get(settings.PATH + \"/x\")\ndef computed():\n    return []\n\n@router.get(f\"/n/{settings.N}\")\ndef formatted():\n    return []\n" },
        .{ .path = "api/conf.py", .data = "class settings:\n    PATH = \"/p\"\n    N = 1\n" },
    });
    defer p.close();
    const m = try p.built();
    try expectHas(m.text, "PUT /v1/items/{id} + PUT /v2/items/{id} put_item");
    try expectHas(m.text, "GET /api/users list_users");
    try expectHas(m.text, "GET /api/users/<settings.PATH + \"/x\"> computed");
    try expectHas(m.text, "GET /api/users/n/<settings.N> formatted");
}

test "map python: Django urlpatterns follow include to a dotted module and name a class view by its class" {
    const p = try Project.open(&.{
        .{ .path = "proj/__init__.py", .data = "" },
        .{ .path = "proj/urls.py", .data = "from django.urls import path, include, re_path\nfrom shop import views\n\nurlpatterns = [\n    path(\"app/\", include(\"shop.urls\")),\n    path(\"v/\", include([path(\"inner/\", views.home)])),\n    re_path(r\"^old/$\", views.home),\n]\n" },
        .{ .path = "shop/__init__.py", .data = "" },
        .{ .path = "shop/urls.py", .data = "from django.urls import path\nfrom . import views\n\nurlpatterns = [\n    path(\"home/\", views.home),\n    path(\"cls/\", views.Page.as_view()),\n]\n" },
        .{ .path = "shop/views.py", .data = "class Page:\n    @classmethod\n    def as_view(cls):\n        return cls\n\ndef home(request):\n    return 1\n" },
        .{ .path = "shop/management/__init__.py", .data = "" },
        .{ .path = "shop/management/commands/__init__.py", .data = "" },
        .{ .path = "shop/management/commands/import_books.py", .data = "from django.core.management.base import BaseCommand\n\nclass Command(BaseCommand):\n    def handle(self, *a, **k):\n        pass\n" },
    });
    defer p.close();
    const m = try p.built();
    try expectHas(m.text, "ALL /app/home/");
    try expectHas(m.text, "ALL /v/inner/");
    try expectHas(m.text, "ALL /app/cls/ Page");
    try expectHas(m.text, "cmd import_books Command");
}

test "map python: click and argparse commands are named by what the source states" {
    const p = try Project.open(&.{
        .{ .path = "cli.py", .data = "import click\n\n@click.group()\ndef cli():\n    pass\n\n@cli.command()\ndef greet():\n    print(\"hi\")\n\n@cli.command(\"bye-now\")\ndef bye():\n    print(\"bye\")\n" },
        .{ .path = "tool.py", .data = "import argparse\n\ndef run(args):\n    print(args)\n\ndef stop(args):\n    print(args)\n\ndef main():\n    parser = argparse.ArgumentParser(prog=\"tool\")\n    sub = parser.add_subparsers()\n    a = sub.add_parser(\"run\")\n    a.set_defaults(func=run)\n    sub.add_parser(\"stop\").set_defaults(func=stop)\n    return parser\n" },
        .{ .path = "plain.py", .data = "def command(name):\n    return name\n\n@command(\"x\")\ndef not_a_route():\n    return 1\n" },
    });
    defer p.close();
    const m = try p.built();
    try expectHas(m.text, "cmd greet");
    try expectHas(m.text, "cmd bye-now bye");
    try expectHas(m.text, "cmd run run");
    try expectHas(m.text, "cmd stop stop");
    try expectLacks(m.text, "cmd x");
}

test "map python: an inner class keeps its own place under the outer class" {
    const p = try Project.open(&.{
        .{ .path = "nesting.py", .data = "class Outer:\n    limit = 1\n\n    def method(self):\n        return 1\n\n    class Inner:\n        size = 2\n\n        def deep(self):\n            return 2\n" },
    });
    defer p.close();
    const m = try p.built();
    try expectHas(m.text, "Outer{method, Inner, limit}");
    try expectHas(m.text, "Outer.Inner{deep, size}");
    const store = &p.session.repo.?.store;
    const id = store.fileId("nesting.py") orelse return error.TestUnexpectedResult;
    var found = false;
    var sizes: usize = 0;
    for (store.file(id).facts.defs) |d| {
        if (std.mem.eql(u8, d.qname, "Outer.Inner.deep")) found = true;
        if (std.mem.eql(u8, d.name, "size")) sizes += 1;
        try testing.expect(!std.mem.eql(u8, d.qname, "Inner.deep"));
        try testing.expect(!std.mem.eql(u8, d.qname, "Inner"));
    }
    try testing.expect(found);
    try testing.expectEqual(@as(usize, 1), sizes);
}

const csharp_controllers = [_]File{
    .{ .path = "Api/BaseApi.cs", .data = "using Microsoft.AspNetCore.Mvc;\nnamespace Shop.Api;\n[ApiController]\n[Route(\"api/[controller]\")]\npublic class BaseApi : ControllerBase { }\n" },
    .{ .path = "Api/UsersController.cs", .data = "using Microsoft.AspNetCore.Mvc;\nnamespace Shop.Api;\npublic class UsersController : BaseApi\n{\n    [HttpGet]\n    public IActionResult List() => Ok();\n    [HttpGet(\"{id}\")]\n    public IActionResult One(int id) => Ok();\n    [HttpPost(\"[action]\")]\n    public IActionResult Create() => Ok();\n    [HttpDelete(\"/abs/{id}\")]\n    public IActionResult Del(int id) => Ok();\n    [AcceptVerbs(\"GET\", \"HEAD\", Route = \"probe\")]\n    public IActionResult Probe() => Ok();\n}\n" },
    .{ .path = "Api/Orders.cs", .data = "using Microsoft.AspNetCore.Mvc;\nnamespace Shop.Api;\n[Route(\"orders\")]\npublic partial class OrdersController : Controller\n{\n    [HttpGet(Routes.Dynamic)]\n    public IActionResult Dyn() => Ok();\n}\n" },
    .{ .path = "Api/Orders.More.cs", .data = "using Microsoft.AspNetCore.Mvc;\nnamespace Shop.Api;\npublic partial class OrdersController\n{\n    [HttpPut(\"{id}\")]\n    public IActionResult Put(int id) => Ok();\n}\n" },
    .{ .path = "Web/Home.cs", .data = "using Microsoft.AspNetCore.Mvc;\nnamespace Shop.Web;\npublic class HomeController : Controller\n{\n    [HttpGet]\n    public IActionResult Index() => View();\n    [HttpPost]\n    public IActionResult Index(int x) => View();\n}\n" },
};

test "map csharp: a controller's actions join its route, inherit a base route and fill the controller and action tokens" {
    const p = try Project.open(&csharp_controllers);
    defer p.close();
    const m = try p.built();
    try expectHas(m.text, "GET /api/Users List");
    try expectHas(m.text, "GET /api/Users/{id} One");
    try expectHas(m.text, "POST /api/Users/Create Create");
    try expectHas(m.text, "DELETE /abs/{id} Del");
    try expectHas(m.text, "GET,HEAD /api/Users/probe Probe");
}

test "map csharp: a partial class across files is one group with the route of the file that states it" {
    const p = try Project.open(&csharp_controllers);
    defer p.close();
    const m = try p.built();
    try expectHas(m.text, "PUT /orders/{id} Put");
    try expectHas(m.text, "GET /orders/<Routes.Dynamic> Dyn");
    const first = std.mem.indexOf(u8, m.text, "OrdersController{") orelse return error.TestUnexpectedResult;
    try expectLacks(m.text[first + 1 ..], "OrdersController{");
}

test "map csharp: overloads with different routes are both kept" {
    const p = try Project.open(&csharp_controllers);
    defer p.close();
    const m = try p.built();
    try expectHas(m.text, "POST Index");
    try expectHas(m.text, "GET Index");
}

test "map csharp: minimal API routes join their MapGroup chain, a lambda names its line and a computed part stays visibly computed" {
    const p = try Project.open(&.{
        .{ .path = "Program.cs", .data = "using Microsoft.AspNetCore.Builder;\nvar app = WebApplication.CreateBuilder(args).Build();\nvar api = app.MapGroup(\"/api\").RequireAuthorization();\nvar v1 = api.MapGroup(\"/v1\");\napp.MapGet(\"/ping\", () => \"pong\");\napi.MapPost(\"/items\", Handlers.Create);\nv1.MapDelete(\"/items/{id}\", Handlers.Remove);\nv1.MapGet($\"/d/{Config.Name}\", () => 1);\napp.MapHub<ChatHub>(\"/chat\");\napp.Run();\npublic static class Handlers\n{\n    public static int Create() => 1;\n    public static int Remove(int id) => 1;\n}\npublic class ChatHub { }\n" },
    });
    defer p.close();
    const m = try p.built();
    try expectHas(m.text, "POST /api/items Create");
    try expectHas(m.text, "DELETE /api/v1/items/{id} Remove");
    try expectHas(m.text, "WS /chat ChatHub");
    try expectHas(m.text, "GET /ping Program.cs:5");
    try expectHas(m.text, "GET /api/v1/d/<Config.Name> Program.cs:8");
}

test "map csharp: xUnit, NUnit and MSTest files are tests by their attributes, a project folder and a name, and a method name alone is not" {
    const p = try Project.open(&.{
        .{ .path = "Shop/Cart.cs", .data = "namespace Shop;\npublic class Cart { public int Total() => 1; }\n" },
        .{ .path = "Shop/Latest.cs", .data = "namespace Shop;\npublic class Latest { public void TestConnection() { } }\n" },
        .{ .path = "Shop/Xu.cs", .data = "using Xunit;\nnamespace Shop;\npublic class Xu { [Fact] public void A() { } [Theory] public void B() { } }\n" },
        .{ .path = "Shop/Nu.cs", .data = "using NUnit.Framework;\nnamespace Shop;\n[TestFixture] public class Nu { [Test] public void A() { } }\n" },
        .{ .path = "Shop/Ms.cs", .data = "namespace Shop;\n[Microsoft.VisualStudio.TestTools.UnitTesting.TestClass] public class Ms { [TestMethod] public void A() { } }\n" },
        .{ .path = "Shop.Tests/Helper.cs", .data = "namespace Shop.Tests;\npublic class Helper { public int Make() => 1; }\n" },
        .{ .path = "Shop/CartTests.cs", .data = "namespace Shop;\npublic class CartTests { public int Make() => 1; }\n" },
    });
    defer p.close();
    for ([_][]const u8{ "Shop/Xu.cs", "Shop/Nu.cs", "Shop/Ms.cs", "Shop.Tests/Helper.cs", "Shop/CartTests.cs" }) |path| {
        try testing.expectEqual(map.Family.tests, try p.family(path));
    }
    for ([_][]const u8{ "Shop/Cart.cs", "Shop/Latest.cs" }) |path| {
        try testing.expectEqual(map.Family.code, try p.family(path));
    }
}

test "map python and csharp: a saved store gives the same routes without extracting again" {
    const files = [_]File{
        .{ .path = "app.py", .data = "from flask import Flask\napp = Flask(__name__)\n\n@app.get(\"/health\")\ndef health():\n    return 1\n" },
        .{ .path = "Program.cs", .data = "var app = WebApplication.CreateBuilder(args).Build();\napp.MapGet(\"/ping\", Handlers.Ping);\npublic static class Handlers { public static int Ping() => 1; }\n" },
    };
    const p = try Project.open(&files);
    defer p.close();
    const first = try p.built();
    try expectHas(first.text, "GET /health health");
    try expectHas(first.text, "GET /ping Ping");
    const again = try map_tools.Session.create(testing.allocator, testing.io, p.runtime, p.root);
    defer again.destroy();
    again.store_override = p.store_path;
    try again.build();
    try testing.expectEqual(emetgate.fact_store.Load.loaded, again.repo.?.load);
    const second = try map.buildMap(p.arena(), &again.repo.?.store, .{ .lines = .names });
    try testing.expectEqualStrings(first.text, second.text);
}

test "map python: a region lists every route of its files with line, and the map stays inside its budget with many of them" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    try source.appendSlice(testing.allocator, "from flask import Flask\napp = Flask(__name__)\n\n");
    for (0..150) |i| {
        const part = try std.fmt.allocPrint(testing.allocator, "@app.get(\"/resource/number/{d}/with/long/path\")\ndef handler_{d}():\n    return {d}\n\n", .{ i, i, i });
        defer testing.allocator.free(part);
        try source.appendSlice(testing.allocator, part);
    }
    const p = try Project.open(&.{.{ .path = "web/app.py", .data = source.items }});
    defer p.close();
    const repo = p.session.repo.?;
    const options: map.MapOptions = .{ .lines = .names, .budget_tokens = 300, .chars_per_token = 3.3 };
    const small = try map.buildMap(p.arena(), &repo.store, options);
    try testing.expect(@as(f64, @floatFromInt(small.text.len)) <= @as(f64, @floatFromInt(options.budget_tokens)) * options.chars_per_token);
    const m = try p.built();
    const id = m.regionOfPath("web/app.py") orelse return error.TestUnexpectedResult;
    const listed = try map_listing.regionListing(p.arena(), &repo.store, &m, id, .{ .snapshot = repo.snapshot() }, .{ .budget = 200_000 });
    const text = switch (listed) {
        .complete => |c| c.value.text,
        .partial => |x| x.value.text,
        .refused => return error.TestUnexpectedResult,
    };
    try expectHas(text, "150 routes, commands and events:\n");
    try expectHas(text, "GET /resource/number/149/with/long/path handler_149 ");
}

test "map tools: explore leaves Python test code out as it does for TypeScript and reaches the handler of a route question" {
    const p = try Project.open(&.{
        .{ .path = "web/routes.py", .data = "from flask import Flask\napp = Flask(__name__)\n\n@app.get(\"/invoices\")\ndef invoices():\n    return []\n" },
        .{ .path = "web/check_invoices.py", .data = "import pytest\n\ndef test_invoices_listed():\n    assert True\n" },
        .{ .path = "web/test_more.py", .data = "def test_invoices_again():\n    assert True\n" },
    });
    defer p.close();
    const text = try p.session.answer(p.arena(), "which route lists invoices", &.{});
    try expectHas(text, "web/routes.py:5 invoices");
    try expectLacks(text, "test_invoices_listed");
    try expectLacks(text, "test_invoices_again");
    const named = try p.session.answer(p.arena(), "show it", &.{"test_invoices_listed"});
    try expectHas(named, "No symbol named test_invoices_listed.");
}

test "map tools: explore leaves C# test code out by its attributes and reaches the action of a route question" {
    const p = try Project.open(&.{
        .{ .path = "Api/Invoices.cs", .data = "using Microsoft.AspNetCore.Mvc;\nnamespace Shop;\n[Route(\"invoices\")]\npublic class InvoicesController : Controller\n{\n    [HttpGet]\n    public IActionResult ListInvoices() => Ok();\n}\n" },
        .{ .path = "Api/Check.cs", .data = "using Xunit;\nnamespace Shop;\npublic class Check { [Fact] public void InvoicesListed() { } }\n" },
    });
    defer p.close();
    const text = try p.session.answer(p.arena(), "which route lists invoices", &.{});
    try expectHas(text, "ListInvoices");
    try expectLacks(text, "InvoicesListed");
}
