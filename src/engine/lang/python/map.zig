const std = @import("std");
const ts = @import("../../tree_sitter.zig");
const traversal = @import("../../traversal.zig");
const facts = @import("../../facts.zig");
const profile_mod = @import("../profile.zig");
const map_sink = @import("../map_sink.zig");

const Allocator = std.mem.Allocator;
const Sink = map_sink.Sink;
const Span = map_sink.Span;
const oneOf = map_sink.oneOf;
const lineOf = map_sink.lineOf;
const dottedIs = map_sink.dottedIs;
const lastSegment = map_sink.lastSegment;
const none = facts.none;

pub const table: profile_mod.MapTable = .{
    .test_segments = &.{ "tests", "test", "testing", "fixtures", "e2e" },
    .test_infixes = &.{},
    .decorators = &.{},
    .call_forms = &.{},
    .test_name = isTestName,
    .extract = extract,
};

pub fn isTestName(base: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len;
    const stem = base[0..dot];
    if (oneOf(stem, &.{ "test", "tests", "conftest" })) return true;
    return std.mem.startsWith(u8, stem, "test_") or std.mem.endsWith(u8, stem, "_test");
}

const test_frameworks = [_][]const u8{ "pytest", "nose", "nose2", "hypothesis" };
const test_case_modules = [_][]const u8{ "unittest", "django.test", "rest_framework.test" };
const command_modules = [_][]const u8{ "click", "typer", "asyncclick", "rich_click", "cloup", "flask_script", "discord" };
const hook_modules = [_][]const u8{ "flask", "quart", "sanic" };

const Verb = struct { method: []const u8, tag: []const u8 };

const verbs = [_]Verb{
    .{ .method = "get", .tag = "GET" },
    .{ .method = "post", .tag = "POST" },
    .{ .method = "put", .tag = "PUT" },
    .{ .method = "patch", .tag = "PATCH" },
    .{ .method = "delete", .tag = "DELETE" },
    .{ .method = "head", .tag = "HEAD" },
    .{ .method = "options", .tag = "OPTIONS" },
    .{ .method = "trace", .tag = "TRACE" },
    .{ .method = "websocket", .tag = "WS" },
    .{ .method = "ws", .tag = "WS" },
    .{ .method = "route", .tag = "GET" },
    .{ .method = "api_route", .tag = "GET" },
};

const add_verbs = [_]Verb{
    .{ .method = "add_get", .tag = "GET" },
    .{ .method = "add_post", .tag = "POST" },
    .{ .method = "add_put", .tag = "PUT" },
    .{ .method = "add_patch", .tag = "PATCH" },
    .{ .method = "add_delete", .tag = "DELETE" },
};

const group_ctors = [_][]const u8{ "Blueprint", "APIBlueprint", "APIRouter", "DefaultRouter", "SimpleRouter", "Flask", "FastAPI", "Starlette", "Quart", "Sanic", "NinjaAPI", "Router", "Application" };

fn verbOf(list: []const Verb, method: []const u8) ?[]const u8 {
    for (list) |v| {
        if (std.mem.eql(u8, v.method, method)) return v.tag;
    }
    return null;
}

const Callee = struct {
    object: []const u8 = "",
    name: []const u8,
    object_node: ?ts.Node = null,
};

const Scan = struct {
    sink: Sink,
    imports: std.ArrayList([]const u8) = .empty,
    aliases: std.StringHashMapUnmanaged([]const u8) = .empty,
    parsers: std.StringHashMapUnmanaged(u32) = .empty,
    parser_handlers: std.AutoHashMapUnmanaged(u32, ts.Node) = .empty,
    programs: std.ArrayList(facts.MapEntry) = .empty,
    has_subparsers: bool = false,

    fn text(self: *const Scan, node: ts.Node) []const u8 {
        return self.sink.text(node);
    }

    fn imported(self: *const Scan, modules: []const []const u8) bool {
        for (self.imports.items) |spec| {
            for (modules) |m| {
                if (dottedIs(spec, m)) return true;
            }
        }
        return false;
    }

    fn importsWord(self: *const Scan, word: []const u8) bool {
        for (self.imports.items) |spec| {
            if (std.mem.indexOf(u8, spec, word) != null) return true;
        }
        return false;
    }

    fn realName(self: *const Scan, name: []const u8) []const u8 {
        return self.aliases.get(name) orelse name;
    }

    fn calleeOf(self: *const Scan, function: ts.Node) ?Callee {
        if (std.mem.eql(u8, function.kind(), "identifier")) return .{ .name = self.realName(self.text(function)) };
        if (!std.mem.eql(u8, function.kind(), "attribute")) return null;
        const object = function.childByField("object") orelse return null;
        const attribute = function.childByField("attribute") orelse return null;
        return .{ .object = self.text(object), .name = self.text(attribute), .object_node = object };
    }

    fn collectImport(self: *Scan, node: ts.Node) !void {
        const from = node.childByField("module_name");
        if (from) |module| try self.imports.append(self.sink.arena, self.text(module));
        var i: u32 = 0;
        while (node.namedChild(i)) |child| : (i += 1) {
            if (from) |module| if (child.eql(module)) continue;
            if (std.mem.eql(u8, child.kind(), "aliased_import")) {
                const name = child.childByField("name") orelse continue;
                const alias = child.childByField("alias") orelse continue;
                if (from == null) {
                    try self.imports.append(self.sink.arena, self.text(name));
                } else {
                    try self.aliases.put(self.sink.arena, self.text(alias), self.text(name));
                }
            } else if (std.mem.eql(u8, child.kind(), "dotted_name")) {
                if (from == null) {
                    try self.imports.append(self.sink.arena, self.text(child));
                } else if (try self.fromModule(from.?, child)) |full| {
                    try self.imports.append(self.sink.arena, full);
                }
            }
        }
    }

    fn fromModule(self: *Scan, module: ts.Node, name: ts.Node) !?[]const u8 {
        const base = self.text(module);
        if (base.len != 0 and base[0] == '.') return null;
        return try std.mem.concat(self.sink.arena, u8, &.{ base, ".", self.text(name) });
    }

    fn scopeOf(self: *const Scan, node: ts.Node) Span {
        var current = node.parent();
        while (current) |p| : (current = p.parent()) {
            if (std.mem.eql(u8, p.kind(), "function_definition")) return .{ .start = p.startByte(), .end = p.endByte() };
        }
        return .{ .start = 0, .end = @intCast(self.sink.tree.source.len) };
    }

    fn enclosingDef(self: *const Scan, node: ts.Node) u32 {
        var current = node.parent();
        while (current) |p| : (current = p.parent()) {
            if (!std.mem.eql(u8, p.kind(), "function_definition")) continue;
            const name = p.childByField("name") orelse return none;
            return self.sink.defAt(name.startByte());
        }
        return none;
    }

    fn firstPass(self: *Scan) !void {
        var walker = traversal.Walker.init(self.sink.tree.root());
        defer walker.deinit();
        while (walker.next()) |entry| {
            const node = entry.node;
            if (!node.isNamed()) continue;
            const kind = node.kind();
            if (std.mem.eql(u8, kind, "import_statement") or std.mem.eql(u8, kind, "import_from_statement")) {
                try self.collectImport(node);
                walker.skipChildren();
            }
        }
        if (self.imported(&test_frameworks)) self.sink.test_content = true;
        var groups = traversal.Walker.init(self.sink.tree.root());
        defer groups.deinit();
        while (groups.next()) |entry| {
            const node = entry.node;
            if (!node.isNamed()) continue;
            const kind = node.kind();
            if (std.mem.eql(u8, kind, "class_definition")) {
                try self.testClass(node);
            } else if (std.mem.eql(u8, kind, "assignment")) {
                try self.assignedGroup(node);
            } else if (std.mem.eql(u8, kind, "call")) {
                self.testMain(node);
            }
        }
    }

    fn testMain(self: *Scan, node: ts.Node) void {
        const function = node.childByField("function") orelse return;
        if (!std.mem.eql(u8, self.text(function), "unittest.main")) return;
        if (self.imported(&.{"unittest"})) self.sink.test_content = true;
    }

    fn testClass(self: *Scan, node: ts.Node) !void {
        const supers = node.childByField("superclasses") orelse return;
        var i: u32 = 0;
        var test_case = false;
        var command = false;
        while (supers.namedChild(i)) |base| : (i += 1) {
            const name = lastSegment(self.text(base));
            if (std.mem.endsWith(u8, name, "TestCase")) test_case = true;
            if (std.mem.eql(u8, name, "BaseCommand")) command = true;
        }
        const class_name = node.childByField("name") orelse return;
        if (command and std.mem.eql(u8, self.text(class_name), "Command")) {
            try self.sink.entries.append(self.sink.arena, .{ .kind = .command, .tag = "cmd", .def = self.sink.defAt(class_name.startByte()), .line = lineOf(class_name), .file_named = true });
        }
        if (test_case and (self.imported(&test_case_modules) or self.hasTestMethod(node))) self.sink.test_content = true;
    }

    fn hasTestMethod(self: *const Scan, class: ts.Node) bool {
        const body = class.childByField("body") orelse return false;
        var i: u32 = 0;
        while (body.namedChild(i)) |member| : (i += 1) {
            const function = if (std.mem.eql(u8, member.kind(), "decorated_definition")) member.childByField("definition") orelse continue else member;
            if (!std.mem.eql(u8, function.kind(), "function_definition")) continue;
            const name = function.childByField("name") orelse continue;
            if (std.mem.startsWith(u8, self.text(name), "test")) return true;
        }
        return false;
    }

    fn assignedGroup(self: *Scan, node: ts.Node) !void {
        const left = node.childByField("left") orelse return;
        const right = node.childByField("right") orelse return;
        const scope = self.scopeOf(node);
        const top = scope.start == 0 and scope.end == self.sink.tree.source.len;
        if (std.mem.eql(u8, right.kind(), "list")) {
            if (!self.imported(&.{ "django.urls", "django.conf.urls" })) return;
            if (std.mem.eql(u8, self.text(left), "urlpatterns")) return;
            _ = try self.sink.addGroup(.{ .name = self.text(left), .top = top }, node.startByte(), scope);
            return;
        }
        if (!std.mem.eql(u8, right.kind(), "call")) return;
        const function = right.childByField("function") orelse return;
        const callee = self.calleeOf(function) orelse return;
        if (!oneOf(self.realName(callee.name), &group_ctors)) return;
        const prefix_node = self.keyword(right, "url_prefix") orelse self.keyword(right, "prefix");
        const prefix = if (prefix_node) |p| try self.pathText(p) else "";
        _ = try self.sink.addGroup(.{ .name = self.text(left), .prefix = prefix, .top = top }, node.startByte(), scope);
    }

    fn keyword(self: *const Scan, call: ts.Node, name: []const u8) ?ts.Node {
        const args = call.childByField("arguments") orelse return null;
        var i: u32 = 0;
        while (args.namedChild(i)) |arg| : (i += 1) {
            if (!std.mem.eql(u8, arg.kind(), "keyword_argument")) continue;
            const key = arg.childByField("name") orelse continue;
            if (std.mem.eql(u8, self.text(key), name)) return arg.childByField("value");
        }
        return null;
    }

    fn positional(self: *const Scan, call: ts.Node, index: u32) ?ts.Node {
        _ = self;
        const args = call.childByField("arguments") orelse return null;
        var i: u32 = 0;
        var seen: u32 = 0;
        while (args.namedChild(i)) |arg| : (i += 1) {
            const kind = arg.kind();
            if (std.mem.eql(u8, kind, "keyword_argument") or std.mem.eql(u8, kind, "comment")) continue;
            if (seen == index) return arg;
            seen += 1;
        }
        return null;
    }

    fn literal(self: *const Scan, node: ts.Node) ?[]const u8 {
        if (!std.mem.eql(u8, node.kind(), "string")) return null;
        var i: u32 = 0;
        var start: u32 = node.startByte();
        var end: u32 = node.endByte();
        while (node.child(i)) |child| : (i += 1) {
            const kind = child.kind();
            if (std.mem.eql(u8, kind, "interpolation")) return null;
            if (std.mem.eql(u8, kind, "string_start")) start = child.endByte();
            if (std.mem.eql(u8, kind, "string_end")) end = child.startByte();
        }
        return self.sink.tree.source[start..end];
    }

    fn pathText(self: *const Scan, node: ts.Node) Allocator.Error![]const u8 {
        const arena = self.sink.arena;
        if (self.literal(node)) |value| return value;
        if (std.mem.eql(u8, node.kind(), "concatenated_string")) {
            var out: std.ArrayList(u8) = .empty;
            var i: u32 = 0;
            while (node.namedChild(i)) |part| : (i += 1) try out.appendSlice(arena, try self.pathText(part));
            return out.items;
        }
        if (!std.mem.eql(u8, node.kind(), "string")) return self.sink.dynamic(node);
        var out: std.ArrayList(u8) = .empty;
        var i: u32 = 0;
        var cursor: ?u32 = null;
        var end: u32 = node.endByte();
        while (node.child(i)) |child| : (i += 1) {
            const kind = child.kind();
            if (std.mem.eql(u8, kind, "string_start")) {
                cursor = child.endByte();
            } else if (std.mem.eql(u8, kind, "string_end")) {
                end = child.startByte();
            } else if (std.mem.eql(u8, kind, "interpolation")) {
                const from = cursor orelse child.startByte();
                try out.appendSlice(arena, self.sink.tree.source[from..child.startByte()]);
                try out.appendSlice(arena, try self.sink.wrapped(std.mem.trim(u8, self.text(child), "{}")));
                cursor = child.endByte();
            }
        }
        const from = cursor orelse node.startByte();
        if (from < end) try out.appendSlice(arena, self.sink.tree.source[from..end]);
        return out.items;
    }

    fn methodsTag(self: *const Scan, call: ts.Node, fallback: []const u8) Allocator.Error![]const u8 {
        const node = self.keyword(call, "methods") orelse return fallback;
        return self.verbList(node, fallback);
    }

    fn verbList(self: *const Scan, node: ts.Node, fallback: []const u8) Allocator.Error![]const u8 {
        const kind = node.kind();
        if (!std.mem.eql(u8, kind, "list") and !std.mem.eql(u8, kind, "tuple") and !std.mem.eql(u8, kind, "set")) return self.sink.dynamic(node);
        var out: std.ArrayList(u8) = .empty;
        var i: u32 = 0;
        while (node.namedChild(i)) |item| : (i += 1) {
            const value = self.literal(item) orelse return self.sink.dynamic(node);
            if (out.items.len != 0) try out.append(self.sink.arena, ',');
            for (value) |c| try out.append(self.sink.arena, std.ascii.toUpper(c));
        }
        return if (out.items.len == 0) fallback else out.items;
    }

    fn knownGroup(self: *const Scan, receiver: []const u8, at: u32) u32 {
        return self.sink.findGroup(receiver, at);
    }

    fn addEntry(self: *Scan, entry: facts.MapEntry, handler: ?ts.Node) !void {
        var e = entry;
        e.stated = e.kind == .route;
        if (e.receiver.len != 0 and e.group == none) {
            e.group = self.knownGroup(e.receiver, e.handler_start);
            if (e.group != none) e.receiver = "";
        }
        e.handler_start = 0;
        if (handler) |h| {
            if (!std.mem.eql(u8, h.kind(), "lambda")) {
                e.handler = try self.sink.shown(h);
                e.handler_start = h.startByte();
                e.handler_end = h.endByte();
            }
        }
        try self.sink.entries.append(self.sink.arena, e);
    }

    fn receiverOf(object: []const u8) []const u8 {
        if (std.mem.endsWith(u8, object, ".router")) return object[0 .. object.len - ".router".len];
        return object;
    }

    fn pathIsRoute(self: *const Scan, path: ?ts.Node, receiver: []const u8, at: u32) bool {
        if (receiver.len == 0) return false;
        const node = path orelse return false;
        if (self.literal(node)) |value| {
            if (value.len == 0 or value[0] == '/') return true;
        }
        return self.knownGroup(receiver, at) != none;
    }

    fn decorator(self: *Scan, expression: ts.Node, def: u32) !void {
        const call = std.mem.eql(u8, expression.kind(), "call");
        const function = if (call) expression.childByField("function") orelse return else expression;
        const callee = self.calleeOf(function) orelse return;
        const line = lineOf(expression);
        const at = expression.startByte();
        if (call) {
            if (verbOf(&verbs, callee.name)) |verb| {
                const receiver = receiverOf(callee.object);
                const path = self.positional(expression, 0) orelse self.keyword(expression, "path") orelse self.keyword(expression, "rule");
                if (self.pathIsRoute(path, receiver, at)) {
                    const tag = try self.methodsTag(expression, verb);
                    try self.addEntry(.{ .kind = .route, .tag = tag, .text = try self.pathText(path.?), .def = def, .receiver = receiver, .handler_start = at, .line = line }, null);
                    return;
                }
            }
            if (std.mem.eql(u8, callee.name, "api_view") and self.imported(&.{"rest_framework"})) {
                const first = self.positional(expression, 0);
                const tag = if (first) |f| try self.verbList(f, "GET") else "GET";
                try self.sink.entries.append(self.sink.arena, .{ .kind = .route, .tag = tag, .def = def, .line = line });
                return;
            }
        }
        if (self.isCommand(callee)) {
            const name = if (call) self.positional(expression, 0) orelse self.keyword(expression, "name") else null;
            const shown = if (name) |n| try self.pathText(n) else "";
            try self.addEntry(.{ .kind = .command, .tag = "cmd", .text = shown, .def = def, .line = line }, null);
            return;
        }
        if (self.eventName(callee)) |tag| {
            const stated = if (call) try self.statedEvent(expression) else "";
            try self.addEntry(.{ .kind = .event, .tag = tag, .text = stated, .def = def, .line = line }, null);
        }
    }

    fn statedEvent(self: *const Scan, call: ts.Node) Allocator.Error![]const u8 {
        const args = call.childByField("arguments") orelse return "";
        var last_literal: ?ts.Node = null;
        var first: ?ts.Node = null;
        var i: u32 = 0;
        while (args.namedChild(i)) |arg| : (i += 1) {
            if (std.mem.eql(u8, arg.kind(), "keyword_argument") or std.mem.eql(u8, arg.kind(), "comment")) continue;
            if (first == null) first = arg;
            if (self.literal(arg) != null) last_literal = arg;
        }
        if (last_literal) |l| return self.pathText(l);
        if (first) |f| return self.pathText(f);
        return "";
    }

    fn isCommand(self: *const Scan, callee: Callee) bool {
        if (!std.mem.eql(u8, callee.name, "command") and !std.mem.eql(u8, callee.name, "group")) return false;
        if (self.imported(&command_modules)) return true;
        if (callee.object.len == 0) return false;
        return std.mem.eql(u8, callee.object, "cli") or std.mem.endsWith(u8, callee.object, ".cli");
    }

    fn eventName(self: *const Scan, callee: Callee) ?[]const u8 {
        const name = callee.name;
        if (oneOf(name, &.{ "scheduled_job", "periodic_task", "crontab" })) return "cron";
        if (callee.object.len != 0 and oneOf(name, &.{ "on", "on_event", "subscribe", "listen", "listens_for", "exception_handler" })) return "on";
        if (std.mem.eql(u8, name, "shared_task")) return "on";
        if (std.mem.eql(u8, name, "task") and callee.object.len != 0 and (self.importsWord("celery") or std.mem.endsWith(u8, callee.object, "celery"))) return "on";
        if (std.mem.eql(u8, name, "receiver") and self.imported(&.{"django"})) return "on";
        if (oneOf(name, &.{ "before_request", "after_request", "teardown_request", "errorhandler" }) and self.imported(&hook_modules)) return "on";
        if (std.mem.eql(u8, name, "event") and callee.object.len != 0 and (self.imported(&.{"socketio"}) or self.imported(&.{"discord"}))) return "on";
        return null;
    }

    fn decorated(self: *Scan, node: ts.Node) !void {
        const definition = node.childByField("definition") orelse return;
        const name = definition.childByField("name") orelse return;
        const def = self.sink.defAt(name.startByte());
        var i: u32 = 0;
        while (node.namedChild(i)) |child| : (i += 1) {
            if (!std.mem.eql(u8, child.kind(), "decorator")) continue;
            const expression = child.namedChild(0) orelse continue;
            try self.decorator(expression, def);
        }
    }

    fn callExpr(self: *Scan, node: ts.Node) !void {
        const function = node.childByField("function") orelse return;
        const callee = self.calleeOf(function) orelse return;
        const at = node.startByte();
        const line = lineOf(node);
        const receiver = receiverOf(callee.object);
        const name = callee.name;
        if (receiver.len != 0 and oneOf(name, &.{ "add_url_rule", "add_api_route", "add_route", "add_api_websocket_route", "add_websocket_route" })) return self.addRoute(node, receiver, name);
        if (receiver.len != 0 and self.imported(&.{"aiohttp"})) {
            if (verbOf(&add_verbs, name)) |verb| {
                const path = self.positional(node, 0) orelse return;
                return self.addEntry(.{ .kind = .route, .tag = verb, .text = try self.pathText(path), .receiver = receiver, .handler_start = at, .line = line }, self.positional(node, 1));
            }
        }
        if (receiver.len != 0 and std.mem.eql(u8, name, "register_blueprint")) return self.mount(node, receiver, self.positional(node, 0), self.keyword(node, "url_prefix"), self.keyword(node, "url_prefix") != null);
        if (receiver.len != 0 and std.mem.eql(u8, name, "include_router")) return self.mount(node, receiver, self.positional(node, 0) orelse self.keyword(node, "router"), self.keyword(node, "prefix"), false);
        if (receiver.len != 0 and std.mem.eql(u8, name, "mount") and self.imported(&.{ "fastapi", "starlette" })) return self.mount(node, receiver, self.positional(node, 1) orelse self.keyword(node, "app"), self.positional(node, 0) orelse self.keyword(node, "path"), false);
        if (receiver.len != 0 and std.mem.eql(u8, name, "register") and self.imported(&.{"rest_framework"})) {
            const group = self.knownGroup(receiver, at);
            if (group == none) return;
            const path = self.positional(node, 0) orelse return;
            return self.addEntry(.{ .kind = .route, .tag = "ALL", .text = try self.pathText(path), .group = group, .line = line }, self.positional(node, 1));
        }
        if (oneOf(name, &.{ "path", "re_path", "url" }) and self.imported(&.{ "django.urls", "django.conf.urls" })) return self.djangoPath(node);
        if (oneOf(name, &.{ "Route", "WebSocketRoute" }) and self.imported(&.{"starlette"})) {
            const path = self.positional(node, 0) orelse return;
            const tag = if (std.mem.eql(u8, name, "Route")) try self.methodsTag(node, "GET") else "WS";
            return self.addEntry(.{ .kind = .route, .tag = tag, .text = try self.pathText(path), .line = line }, self.positional(node, 1) orelse self.keyword(node, "endpoint"));
        }
        if (self.imported(&.{"argparse"})) {
            if (std.mem.eql(u8, name, "add_parser")) return self.subParser(node);
            if (std.mem.eql(u8, name, "set_defaults")) return self.setDefaults(node, callee);
            if (std.mem.eql(u8, name, "ArgumentParser")) {
                const prog = self.keyword(node, "prog");
                try self.programs.append(self.sink.arena, .{ .kind = .command, .tag = "cmd", .text = if (prog) |p| try self.pathText(p) else "", .def = self.enclosingDef(node), .line = line });
            }
        }
    }

    fn addRoute(self: *Scan, node: ts.Node, receiver: []const u8, name: []const u8) !void {
        const at = node.startByte();
        const line = lineOf(node);
        const first = self.positional(node, 0) orelse self.keyword(node, "rule") orelse self.keyword(node, "path") orelse return;
        if (std.mem.eql(u8, name, "add_url_rule")) {
            const handler = self.keyword(node, "view_func") orelse self.positional(node, 2);
            return self.addEntry(.{ .kind = .route, .tag = try self.methodsTag(node, "GET"), .text = try self.pathText(first), .receiver = receiver, .handler_start = at, .line = line }, handler);
        }
        if (std.mem.eql(u8, name, "add_route")) {
            if (self.positional(node, 1)) |second| {
                if (self.literal(second)) |value| {
                    if (value.len != 0 and value[0] == '/') {
                        var upper: std.ArrayList(u8) = .empty;
                        for (self.literal(first) orelse "ALL") |c| try upper.append(self.sink.arena, std.ascii.toUpper(c));
                        return self.addEntry(.{ .kind = .route, .tag = upper.items, .text = value, .receiver = receiver, .handler_start = at, .line = line }, self.positional(node, 2));
                    }
                }
            }
        }
        const websocket = std.mem.indexOf(u8, name, "websocket") != null;
        if (std.mem.eql(u8, name, "add_route") and !self.pathIsRoute(first, receiver, at)) return;
        const tag = if (websocket) "WS" else try self.methodsTag(node, "GET");
        const handler = self.positional(node, 1) orelse self.keyword(node, "endpoint") orelse self.keyword(node, "route");
        try self.addEntry(.{ .kind = .route, .tag = tag, .text = try self.pathText(first), .receiver = receiver, .handler_start = at, .line = line }, handler);
    }

    fn mount(self: *Scan, node: ts.Node, receiver: []const u8, child: ?ts.Node, prefix: ?ts.Node, overrides: bool) !void {
        const target = child orelse return;
        const kind = target.kind();
        if (!std.mem.eql(u8, kind, "identifier") and !std.mem.eql(u8, kind, "attribute")) return;
        const parent = self.knownGroup(receiver, node.startByte());
        try self.sink.mounts.append(self.sink.arena, .{
            .parent = if (parent == none) receiver else "",
            .parent_group = parent,
            .child = self.text(target),
            .prefix = if (prefix) |p| try self.pathText(p) else "",
            .overrides = overrides,
        });
    }

    fn includeOf(self: *const Scan, node: ts.Node) ?ts.Node {
        if (!std.mem.eql(u8, node.kind(), "call")) return null;
        const function = node.childByField("function") orelse return null;
        const callee = self.calleeOf(function) orelse return null;
        return if (std.mem.eql(u8, callee.name, "include")) node else null;
    }

    fn outerPrefix(self: *const Scan, node: ts.Node) Allocator.Error![]const u8 {
        var prefix: []const u8 = "";
        var current = node.parent();
        while (current) |p| : (current = p.parent()) {
            if (self.includeOf(p) == null) continue;
            const args = p.parent() orelse break;
            const outer = args.parent() orelse break;
            const first = self.positional(outer, 0) orelse continue;
            prefix = try self.routeJoin(try self.patternText(outer, first), prefix);
        }
        return prefix;
    }

    fn routeJoin(self: *const Scan, left: []const u8, right: []const u8) Allocator.Error![]const u8 {
        return std.mem.concat(self.sink.arena, u8, &.{ left, right });
    }

    fn patternText(self: *const Scan, call_node: ts.Node, route: ts.Node) Allocator.Error![]const u8 {
        const value = try self.pathText(route);
        const function = call_node.childByField("function") orelse return value;
        const callee = self.calleeOf(function) orelse return value;
        if (std.mem.eql(u8, callee.name, "path") or self.literal(route) == null) return value;
        var pattern = value;
        if (std.mem.startsWith(u8, pattern, "^")) pattern = pattern[1..];
        if (std.mem.endsWith(u8, pattern, "$")) pattern = pattern[0 .. pattern.len - 1];
        return pattern;
    }

    fn listGroup(self: *const Scan, node: ts.Node) u32 {
        var current = node.parent();
        while (current) |p| : (current = p.parent()) {
            if (!std.mem.eql(u8, p.kind(), "assignment")) continue;
            const left = p.childByField("left") orelse return none;
            return self.sink.findGroup(self.text(left), node.startByte());
        }
        return none;
    }

    fn djangoPath(self: *Scan, node: ts.Node) !void {
        const route = self.positional(node, 0) orelse self.keyword(node, "route") orelse return;
        const view = self.positional(node, 1) orelse self.keyword(node, "view") orelse return;
        const text_value = try self.routeJoin(try self.outerPrefix(node), try self.patternText(node, route));
        const group = self.listGroup(node);
        if (self.includeOf(view)) |include| {
            const target = self.positional(include, 0) orelse return;
            return self.djangoInclude(target, text_value, group);
        }
        try self.addEntry(.{ .kind = .route, .tag = "ALL", .text = text_value, .group = group, .line = lineOf(node) }, view);
    }

    fn djangoInclude(self: *Scan, target: ts.Node, prefix: []const u8, group: u32) Allocator.Error!void {
        const kind = target.kind();
        if (std.mem.eql(u8, kind, "tuple")) {
            const first = target.namedChild(0) orelse return;
            return self.djangoInclude(first, prefix, group);
        }
        if (std.mem.eql(u8, kind, "list")) return;
        if (self.literal(target)) |module| {
            return self.sink.mounts.append(self.sink.arena, .{ .parent_group = group, .child = module, .prefix = prefix, .module = true });
        }
        if (!std.mem.eql(u8, kind, "identifier") and !std.mem.eql(u8, kind, "attribute")) return;
        var child = self.text(target);
        if (std.mem.endsWith(u8, child, ".urls")) child = child[0 .. child.len - ".urls".len];
        try self.sink.mounts.append(self.sink.arena, .{ .parent_group = group, .child = child, .prefix = prefix });
    }

    fn subParser(self: *Scan, node: ts.Node) !void {
        self.has_subparsers = true;
        const name = self.positional(node, 0) orelse return;
        const index: u32 = @intCast(self.sink.entries.items.len);
        const handler = self.parser_handlers.get(node.startByte());
        try self.addEntry(.{ .kind = .command, .tag = "cmd", .text = try self.pathText(name), .line = lineOf(node) }, handler);
        const holder = node.parent() orelse return;
        if (!std.mem.eql(u8, holder.kind(), "assignment")) return;
        const left = holder.childByField("left") orelse return;
        try self.parsers.put(self.sink.arena, self.text(left), index);
    }

    fn setDefaults(self: *Scan, node: ts.Node, callee: Callee) !void {
        const handler = self.keyword(node, "func") orelse return;
        const object = callee.object_node orelse return;
        if (std.mem.eql(u8, object.kind(), "call")) {
            try self.parser_handlers.put(self.sink.arena, object.startByte(), handler);
            return;
        }
        const index = self.parsers.get(callee.object) orelse return;
        const entry = &self.sink.entries.items[index];
        if (std.mem.eql(u8, handler.kind(), "lambda")) return;
        entry.handler = try self.sink.shown(handler);
        entry.handler_start = handler.startByte();
        entry.handler_end = handler.endByte();
    }

    fn secondPass(self: *Scan) !void {
        var walker = traversal.Walker.init(self.sink.tree.root());
        defer walker.deinit();
        while (walker.next()) |entry| {
            const node = entry.node;
            if (!node.isNamed()) continue;
            const kind = node.kind();
            if (std.mem.eql(u8, kind, "decorated_definition")) {
                try self.decorated(node);
            } else if (std.mem.eql(u8, kind, "call")) {
                try self.callExpr(node);
            }
        }
        if (!self.has_subparsers) try self.sink.entries.appendSlice(self.sink.arena, self.programs.items);
    }
};

pub fn extract(arena: Allocator, tree: ts.Tree, defs: []const facts.Def) Allocator.Error!facts.MapFacts {
    var scan: Scan = .{ .sink = .{ .arena = arena, .tree = tree, .defs = defs } };
    try scan.firstPass();
    try scan.secondPass();
    return scan.sink.finish();
}

const testing = std.testing;

test "python map: a name marks a test file only when it follows the convention" {
    try testing.expect(isTestName("test_app.py"));
    try testing.expect(isTestName("app_test.py"));
    try testing.expect(isTestName("conftest.py"));
    try testing.expect(isTestName("tests.py"));
    try testing.expect(!isTestName("latest_news.py"));
    try testing.expect(!isTestName("contest.py"));
    try testing.expect(!isTestName("testing_utils.py"));
}
