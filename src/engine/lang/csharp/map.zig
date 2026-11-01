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
    .test_segments = &.{ "test", "tests", "Test", "Tests" },
    .test_infixes = &.{},
    .decorators = &.{},
    .call_forms = &.{},
    .namespace_scoped = true,
    .test_name = isTestName,
    .test_segment = isTestSegment,
    .extract = extract,
};

const test_namespaces = [_][]const u8{ "Xunit", "NUnit.Framework", "Microsoft.VisualStudio.TestTools.UnitTesting", "TUnit.Core" };

const test_attributes = [_][]const u8{
    "Fact",
    "Theory",
    "Test",
    "TestCase",
    "TestCaseSource",
    "TestFixture",
    "TestClass",
    "TestMethod",
    "DataTestMethod",
    "SetUp",
    "TearDown",
    "OneTimeSetUp",
    "OneTimeTearDown",
    "TestInitialize",
    "TestCleanup",
    "ClassInitialize",
    "ClassCleanup",
};

pub fn isTestAttribute(name: []const u8) bool {
    return oneOf(attributeName(name), &test_attributes);
}

pub fn isTestNamespace(name: []const u8) bool {
    for (test_namespaces) |namespace| {
        if (dottedIs(name, namespace)) return true;
    }
    return false;
}

pub fn attributeName(name: []const u8) []const u8 {
    const last = lastSegment(name);
    if (last.len > "Attribute".len and std.mem.endsWith(u8, last, "Attribute")) return last[0 .. last.len - "Attribute".len];
    return last;
}

pub fn isTestName(base: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len;
    const stem = base[0..dot];
    return std.mem.endsWith(u8, stem, "Tests") or std.mem.endsWith(u8, stem, "Specs");
}

pub fn isTestSegment(segment: []const u8) bool {
    if (std.mem.endsWith(u8, segment, "Tests") and segment.len > "Tests".len) {
        const before = segment[segment.len - "Tests".len - 1];
        if (before == '.' or std.ascii.isLower(before) or std.ascii.isUpper(before)) {
            if (!std.ascii.isLower(segment[0]) or std.mem.indexOfScalar(u8, segment, '.') != null) return true;
        }
    }
    for ([_][]const u8{ ".Test", ".Tests", ".Spec", ".Specs" }) |ending| {
        if (std.mem.endsWith(u8, segment, ending)) return true;
        const inner = std.mem.indexOf(u8, segment, ending) orelse continue;
        if (inner + ending.len < segment.len and segment[inner + ending.len] == '.') return true;
    }
    return false;
}

const Verb = struct { name: []const u8, tag: []const u8 };

const http_attributes = [_]Verb{
    .{ .name = "HttpGet", .tag = "GET" },
    .{ .name = "HttpPost", .tag = "POST" },
    .{ .name = "HttpPut", .tag = "PUT" },
    .{ .name = "HttpDelete", .tag = "DELETE" },
    .{ .name = "HttpPatch", .tag = "PATCH" },
    .{ .name = "HttpHead", .tag = "HEAD" },
    .{ .name = "HttpOptions", .tag = "OPTIONS" },
};

const minimal_calls = [_]Verb{
    .{ .name = "MapGet", .tag = "GET" },
    .{ .name = "MapPost", .tag = "POST" },
    .{ .name = "MapPut", .tag = "PUT" },
    .{ .name = "MapDelete", .tag = "DELETE" },
    .{ .name = "MapPatch", .tag = "PATCH" },
    .{ .name = "Map", .tag = "ALL" },
    .{ .name = "MapHealthChecks", .tag = "GET" },
};

const event_attributes = [_][]const u8{ "CapSubscribe", "Subscribe", "Topic", "HubMethodName", "EventSubscription", "KafkaListener", "RabbitListener" };
const command_attributes = [_][]const u8{ "Command", "Verb" };
const handler_bases = [_][]const u8{ "INotificationHandler", "IConsumer", "IRequestHandler", "IEventHandler", "IIntegrationEventHandler", "IHandleMessages" };

fn verbOf(list: []const Verb, name: []const u8) ?[]const u8 {
    for (list) |v| {
        if (std.mem.eql(u8, v.name, name)) return v.tag;
    }
    return null;
}

const Attribute = struct {
    name: []const u8,
    node: ts.Node,
};

const Route = struct {
    tag: []const u8,
    template: ?ts.Node,
};

const Scan = struct {
    sink: Sink,
    usings: std.ArrayList([]const u8) = .empty,
    class_group: std.AutoHashMapUnmanaged(u32, u32) = .empty,

    fn text(self: *const Scan, node: ts.Node) []const u8 {
        return self.sink.text(node);
    }

    fn uses(self: *const Scan, namespace: []const u8) bool {
        for (self.usings.items) |u| {
            if (dottedIs(u, namespace)) return true;
        }
        return false;
    }

    fn scopeOf(self: *const Scan, node: ts.Node) Span {
        var current = node.parent();
        while (current) |p| : (current = p.parent()) {
            const kind = p.kind();
            if (std.mem.eql(u8, kind, "method_declaration") or std.mem.eql(u8, kind, "local_function_statement") or std.mem.eql(u8, kind, "constructor_declaration")) return .{ .start = p.startByte(), .end = p.endByte() };
        }
        return .{ .start = 0, .end = @intCast(self.sink.tree.source.len) };
    }

    fn enclosingMethod(_: *const Scan, node: ts.Node) ?ts.Node {
        var current = node.parent();
        while (current) |p| : (current = p.parent()) {
            const kind = p.kind();
            if (std.mem.eql(u8, kind, "method_declaration") or std.mem.eql(u8, kind, "local_function_statement")) return p;
        }
        return null;
    }

    fn literal(self: *const Scan, node: ts.Node) ?[]const u8 {
        const kind = node.kind();
        const source = self.sink.tree.source;
        if (std.mem.eql(u8, kind, "string_literal")) {
            if (node.endByte() - node.startByte() < 2) return null;
            const raw = source[node.startByte()..node.endByte()];
            const open = std.mem.indexOfScalar(u8, raw, '"') orelse return null;
            if (raw[raw.len - 1] != '"' or raw.len < open + 2) return null;
            return raw[open + 1 .. raw.len - 1];
        }
        if (std.mem.eql(u8, kind, "verbatim_string_literal")) {
            const raw = source[node.startByte()..node.endByte()];
            if (raw.len < 3) return null;
            return raw[2 .. raw.len - 1];
        }
        if (std.mem.eql(u8, kind, "raw_string_literal")) {
            const raw = source[node.startByte()..node.endByte()];
            const body = std.mem.trim(u8, raw, "\"");
            return std.mem.trim(u8, body, " \t\r\n");
        }
        return null;
    }

    fn pathText(self: *const Scan, node: ts.Node) Allocator.Error![]const u8 {
        if (self.literal(node)) |value| return value;
        if (!std.mem.eql(u8, node.kind(), "interpolated_string_expression")) return self.sink.dynamic(node);
        const arena = self.sink.arena;
        const source = self.sink.tree.source;
        var out: std.ArrayList(u8) = .empty;
        const raw = source[node.startByte()..node.endByte()];
        const open = std.mem.indexOfScalar(u8, raw, '"') orelse return self.sink.dynamic(node);
        var cursor: u32 = node.startByte() + @as(u32, @intCast(open)) + 1;
        const end: u32 = node.endByte() - 1;
        var i: u32 = 0;
        while (node.namedChild(i)) |child| : (i += 1) {
            if (!std.mem.eql(u8, child.kind(), "interpolation")) continue;
            if (child.startByte() > cursor) try out.appendSlice(arena, source[cursor..child.startByte()]);
            const whole = self.text(child);
            try out.appendSlice(arena, try self.sink.wrapped(std.mem.trim(u8, whole, "{}")));
            cursor = child.endByte();
        }
        if (cursor < end) try out.appendSlice(arena, source[cursor..end]);
        return out.items;
    }

    fn attributes(self: *const Scan, node: ts.Node, out: *std.ArrayList(Attribute)) Allocator.Error!void {
        out.clearRetainingCapacity();
        var i: u32 = 0;
        while (node.namedChild(i)) |child| : (i += 1) {
            if (!std.mem.eql(u8, child.kind(), "attribute_list")) continue;
            var j: u32 = 0;
            while (child.namedChild(j)) |attribute| : (j += 1) {
                if (!std.mem.eql(u8, attribute.kind(), "attribute")) continue;
                const name = attribute.childByField("name") orelse continue;
                try out.append(self.sink.arena, .{ .name = attributeName(self.text(name)), .node = attribute });
            }
        }
    }

    fn attributeArgument(self: *const Scan, attribute: ts.Node, index: u32) ?ts.Node {
        const args = attributeArguments(attribute) orelse return null;
        var seen: u32 = 0;
        var i: u32 = 0;
        while (args.namedChild(i)) |arg| : (i += 1) {
            if (!std.mem.eql(u8, arg.kind(), "attribute_argument")) continue;
            if (arg.childByField("name") != null) continue;
            if (self.isNamedAssign(arg)) continue;
            if (seen == index) return valueOf(arg);
            seen += 1;
        }
        return null;
    }

    fn isNamedAssign(_: *const Scan, arg: ts.Node) bool {
        const first = arg.namedChild(0) orelse return false;
        return std.mem.eql(u8, first.kind(), "assignment_expression");
    }

    fn attributeNamed(self: *const Scan, attribute: ts.Node, name: []const u8) ?ts.Node {
        const args = attributeArguments(attribute) orelse return null;
        var i: u32 = 0;
        while (args.namedChild(i)) |arg| : (i += 1) {
            if (!std.mem.eql(u8, arg.kind(), "attribute_argument")) continue;
            if (arg.childByField("name")) |key| {
                if (std.mem.eql(u8, self.text(key), name)) return valueOf(arg);
                continue;
            }
            const first = arg.namedChild(0) orelse continue;
            if (!std.mem.eql(u8, first.kind(), "assignment_expression")) continue;
            const left = first.childByField("left") orelse continue;
            if (std.mem.eql(u8, self.text(left), name)) return first.childByField("right");
        }
        return null;
    }

    fn typeName(self: *const Scan, node: ts.Node) []const u8 {
        const raw = self.text(node);
        const angle = std.mem.indexOfScalar(u8, raw, '<') orelse raw.len;
        return lastSegment(raw[0..angle]);
    }

    fn typeArgument(self: *const Scan, node: ts.Node) Allocator.Error![]const u8 {
        const raw = self.text(node);
        const open = std.mem.indexOfScalar(u8, raw, '<') orelse return "";
        const close = std.mem.lastIndexOfScalar(u8, raw, '>') orelse return "";
        if (close <= open + 1) return "";
        return map_sink.collapse(self.sink.arena, raw[open + 1 .. close]);
    }

    fn usingDirective(self: *Scan, node: ts.Node) !void {
        var last: ?ts.Node = null;
        var i: u32 = 0;
        while (node.namedChild(i)) |child| : (i += 1) {
            if (!std.mem.eql(u8, child.kind(), "comment")) last = child;
        }
        const name = last orelse return;
        const value = self.text(name);
        try self.usings.append(self.sink.arena, value);
        if (isTestNamespace(value)) self.sink.test_content = true;
    }

    fn firstBase(self: *const Scan, class: ts.Node) []const u8 {
        var i: u32 = 0;
        while (class.namedChild(i)) |child| : (i += 1) {
            if (!std.mem.eql(u8, child.kind(), "base_list")) continue;
            const first = child.namedChild(0) orelse return "";
            return self.typeName(first);
        }
        return "";
    }

    fn classGroup(self: *Scan, class: ts.Node) !void {
        var list: std.ArrayList(Attribute) = .empty;
        try self.attributes(class, &list);
        var area: []const u8 = "";
        for (list.items) |a| {
            if (std.mem.eql(u8, a.name, "Area")) {
                if (self.attributeArgument(a.node, 0)) |value| area = try self.pathText(value);
            }
        }
        const name_node = class.childByField("name") orelse return;
        const own = self.sink.defAt(name_node.startByte());
        const name = if (own != none) self.sink.defs[own].qname else self.text(name_node);
        const base = self.firstBase(class);
        const everywhere: Span = .{ .start = 0, .end = @intCast(self.sink.tree.source.len) };
        var first: u32 = none;
        for (list.items) |a| {
            if (!std.mem.eql(u8, a.name, "Route") and !std.mem.eql(u8, a.name, "RoutePrefix")) continue;
            const value = self.attributeArgument(a.node, 0) orelse self.attributeNamed(a.node, "template") orelse continue;
            const index = try self.sink.addGroup(.{ .name = name, .prefix = try self.pathText(value), .base = base, .area = area, .class_like = true }, class.startByte(), everywhere);
            if (first == none) first = index;
        }
        if (first == none) first = try self.sink.addGroup(.{ .name = name, .base = base, .area = area, .class_like = true }, class.startByte(), everywhere);
        try self.class_group.put(self.sink.arena, class.startByte(), first);
    }

    fn enclosingClass(_: *const Scan, node: ts.Node) ?ts.Node {
        var current = node.parent();
        while (current) |p| : (current = p.parent()) {
            const kind = p.kind();
            if (std.mem.eql(u8, kind, "class_declaration") or std.mem.eql(u8, kind, "record_declaration") or std.mem.eql(u8, kind, "struct_declaration")) return p;
        }
        return null;
    }

    fn classEntries(self: *Scan, class: ts.Node) !void {
        var list: std.ArrayList(Attribute) = .empty;
        try self.attributes(class, &list);
        const name_node = class.childByField("name") orelse return;
        const def = self.sink.defAt(name_node.startByte());
        for (list.items) |a| {
            if (!oneOf(a.name, &command_attributes)) continue;
            const value = self.attributeArgument(a.node, 0) orelse self.attributeNamed(a.node, "Name");
            try self.sink.entries.append(self.sink.arena, .{ .kind = .command, .tag = "cmd", .text = if (value) |v| try self.pathText(v) else "", .def = def, .line = lineOf(a.node) });
        }
        var i: u32 = 0;
        while (class.namedChild(i)) |child| : (i += 1) {
            if (!std.mem.eql(u8, child.kind(), "base_list")) continue;
            var j: u32 = 0;
            while (child.namedChild(j)) |base| : (j += 1) {
                if (!oneOf(self.typeName(base), &handler_bases)) continue;
                try self.sink.entries.append(self.sink.arena, .{ .kind = .event, .tag = "on", .text = try self.typeArgument(base), .def = def, .line = lineOf(base) });
            }
        }
    }

    fn method(self: *Scan, node: ts.Node) !void {
        var list: std.ArrayList(Attribute) = .empty;
        try self.attributes(node, &list);
        const name_node = node.childByField("name") orelse return;
        const def = self.sink.defAt(name_node.startByte());
        const class = self.enclosingClass(node);
        const group = if (class) |c| self.class_group.get(c.startByte()) orelse none else none;
        const line = lineOf(name_node);
        var routes: std.ArrayList(Route) = .empty;
        var templates: std.ArrayList(ts.Node) = .empty;
        var bare_verbs: std.ArrayList([]const u8) = .empty;
        var bare_route = false;
        for (list.items) |a| {
            if (std.mem.eql(u8, a.name, "Route")) {
                const value = self.attributeArgument(a.node, 0) orelse self.attributeNamed(a.node, "template");
                if (value) |v| {
                    try templates.append(self.sink.arena, v);
                } else bare_route = true;
                continue;
            }
            if (verbOf(&http_attributes, a.name)) |verb| {
                const value = self.attributeArgument(a.node, 0) orelse self.attributeNamed(a.node, "template");
                if (value) |v| {
                    try routes.append(self.sink.arena, .{ .tag = verb, .template = v });
                } else {
                    try bare_verbs.append(self.sink.arena, verb);
                }
                continue;
            }
            if (std.mem.eql(u8, a.name, "AcceptVerbs")) {
                const tag = try self.acceptVerbs(a.node);
                const stated = self.attributeNamed(a.node, "Route");
                if (stated) |v| {
                    try routes.append(self.sink.arena, .{ .tag = tag, .template = v });
                } else {
                    try bare_verbs.append(self.sink.arena, tag);
                }
                continue;
            }
            if (oneOf(a.name, &event_attributes)) {
                const value = self.lastLiteralArgument(a.node) orelse self.attributeArgument(a.node, 0);
                try self.sink.entries.append(self.sink.arena, .{ .kind = .event, .tag = "on", .text = if (value) |v| try self.pathText(v) else "", .def = def, .line = lineOf(a.node) });
                continue;
            }
            if (oneOf(a.name, &command_attributes)) {
                const value = self.attributeArgument(a.node, 0) orelse self.attributeNamed(a.node, "Name");
                try self.sink.entries.append(self.sink.arena, .{ .kind = .command, .tag = "cmd", .text = if (value) |v| try self.pathText(v) else "", .def = def, .line = lineOf(a.node) });
                continue;
            }
            if (std.mem.eql(u8, a.name, "Function") or std.mem.eql(u8, a.name, "FunctionName")) {
                try self.function(node, a.node, def, line);
            }
        }
        for (routes.items) |r| try self.controllerRoute(r.tag, r.template, def, group, line);
        if (bare_verbs.items.len != 0) {
            if (templates.items.len != 0) {
                for (bare_verbs.items) |verb| {
                    for (templates.items) |t| try self.controllerRoute(verb, t, def, group, line);
                }
            } else {
                for (bare_verbs.items) |verb| try self.controllerRoute(verb, null, def, group, line);
            }
        } else if (routes.items.len == 0) {
            for (templates.items) |t| try self.controllerRoute("ALL", t, def, group, line);
            if (bare_route and templates.items.len == 0) try self.controllerRoute("ALL", null, def, group, line);
        }
    }

    fn acceptVerbs(self: *const Scan, attribute: ts.Node) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var index: u32 = 0;
        while (self.attributeArgument(attribute, index)) |arg| : (index += 1) {
            const value = self.literal(arg) orelse return self.sink.dynamic(arg);
            if (out.items.len != 0) try out.append(self.sink.arena, ',');
            for (value) |c| try out.append(self.sink.arena, std.ascii.toUpper(c));
        }
        return if (out.items.len == 0) "ALL" else out.items;
    }

    fn lastLiteralArgument(self: *const Scan, attribute: ts.Node) ?ts.Node {
        var found: ?ts.Node = null;
        var index: u32 = 0;
        while (self.attributeArgument(attribute, index)) |arg| : (index += 1) {
            if (self.literal(arg) != null) found = arg;
        }
        return found;
    }

    fn controllerRoute(self: *Scan, tag: []const u8, template: ?ts.Node, def: u32, group: u32, line: u32) !void {
        var value = if (template) |t| try self.pathText(t) else "";
        var absolute = false;
        if (std.mem.startsWith(u8, value, "~/")) {
            value = value[1..];
            absolute = true;
        } else if (value.len != 0 and value[0] == '/') {
            absolute = true;
        }
        try self.sink.entries.append(self.sink.arena, .{ .kind = .route, .tag = tag, .text = value, .def = def, .group = group, .absolute = absolute, .stated = template != null, .line = line });
    }

    fn function(self: *Scan, node: ts.Node, attribute: ts.Node, def: u32, line: u32) !void {
        const name = self.attributeArgument(attribute, 0);
        const shown = if (name) |n| try self.pathText(n) else "";
        const parameters = node.childByField("parameters") orelse {
            return self.sink.entries.append(self.sink.arena, .{ .kind = .event, .tag = "on", .text = shown, .def = def, .line = line });
        };
        var list: std.ArrayList(Attribute) = .empty;
        var i: u32 = 0;
        while (parameters.namedChild(i)) |parameter| : (i += 1) {
            try self.attributes(parameter, &list);
            for (list.items) |a| {
                if (std.mem.eql(u8, a.name, "HttpTrigger")) {
                    const tag = try self.triggerVerbs(a.node);
                    const route = self.attributeNamed(a.node, "Route");
                    const text_value = if (route) |r| try self.pathText(r) else shown;
                    return self.sink.entries.append(self.sink.arena, .{ .kind = .route, .tag = tag, .text = text_value, .def = def, .line = line });
                }
                if (std.mem.eql(u8, a.name, "TimerTrigger")) {
                    const schedule = self.attributeArgument(a.node, 0);
                    return self.sink.entries.append(self.sink.arena, .{ .kind = .event, .tag = "cron", .text = if (schedule) |s| try self.pathText(s) else shown, .def = def, .line = line });
                }
            }
        }
        try self.sink.entries.append(self.sink.arena, .{ .kind = .event, .tag = "on", .text = shown, .def = def, .line = line });
    }

    fn triggerVerbs(self: *const Scan, attribute: ts.Node) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var index: u32 = 0;
        while (self.attributeArgument(attribute, index)) |arg| : (index += 1) {
            const value = self.literal(arg) orelse continue;
            if (out.items.len != 0) try out.append(self.sink.arena, ',');
            for (value) |c| try out.append(self.sink.arena, std.ascii.toUpper(c));
        }
        return if (out.items.len == 0) "ALL" else out.items;
    }

    fn argumentsOf(_: *const Scan, call: ts.Node) ?ts.Node {
        return call.childByField("arguments");
    }

    fn argument(self: *const Scan, call: ts.Node, index: u32) ?ts.Node {
        const args = self.argumentsOf(call) orelse return null;
        var seen: u32 = 0;
        var i: u32 = 0;
        while (args.namedChild(i)) |arg| : (i += 1) {
            if (!std.mem.eql(u8, arg.kind(), "argument")) continue;
            if (seen == index) return valueOf(arg);
            seen += 1;
        }
        return null;
    }

    fn memberCall(self: *const Scan, call: ts.Node) ?MemberCall {
        const function_node = call.childByField("function") orelse return null;
        if (!std.mem.eql(u8, function_node.kind(), "member_access_expression")) return null;
        const object = function_node.childByField("expression") orelse return null;
        const name = function_node.childByField("name") orelse return null;
        const raw = self.text(name);
        const angle = std.mem.indexOfScalar(u8, raw, '<') orelse raw.len;
        return .{ .object = object, .name = raw[0..angle], .generic = name };
    }

    const Chain = struct { root: ?ts.Node, prefix: []const u8 };

    fn chain(self: *const Scan, start: ts.Node) Allocator.Error!Chain {
        var node = start;
        var prefix: []const u8 = "";
        while (std.mem.eql(u8, node.kind(), "invocation_expression")) {
            const member = self.memberCall(node) orelse return .{ .root = null, .prefix = prefix };
            if (std.mem.eql(u8, member.name, "MapGroup")) {
                const stated = self.argument(node, 0) orelse return .{ .root = null, .prefix = prefix };
                prefix = try joined(self.sink.arena, try self.pathText(stated), prefix);
            }
            node = member.object;
        }
        return .{ .root = node, .prefix = prefix };
    }

    fn receiverPrefix(self: *const Scan, object: ts.Node, at: u32) Allocator.Error![]const u8 {
        const found = try self.chain(object);
        var prefix = found.prefix;
        const root = found.root orelse return prefix;
        const name = self.text(root);
        const group = self.sink.findGroup(name, at);
        if (group != none) return joined(self.sink.arena, self.sink.groups.items[group].prefix, prefix);
        if (std.mem.eql(u8, root.kind(), "identifier") and self.isGroupParameter(root)) prefix = try joined(self.sink.arena, try std.fmt.allocPrint(self.sink.arena, "<{s}>", .{name}), prefix);
        return prefix;
    }

    fn isGroupParameter(self: *const Scan, identifier: ts.Node) bool {
        const owner = self.enclosingMethod(identifier) orelse return false;
        const parameters = owner.childByField("parameters") orelse return false;
        var i: u32 = 0;
        while (parameters.namedChild(i)) |parameter| : (i += 1) {
            const name = parameter.childByField("name") orelse continue;
            if (!std.mem.eql(u8, self.text(name), self.text(identifier))) continue;
            const kind = parameter.childByField("type") orelse return false;
            return std.mem.eql(u8, self.typeName(kind), "RouteGroupBuilder");
        }
        return false;
    }

    fn declaredGroup(self: *Scan, node: ts.Node) !void {
        var name_node: ?ts.Node = null;
        var value: ?ts.Node = null;
        if (std.mem.eql(u8, node.kind(), "variable_declarator")) {
            name_node = node.childByField("name");
            var i: u32 = 0;
            while (node.namedChild(i)) |child| : (i += 1) {
                if (name_node) |n| if (child.eql(n)) continue;
                if (std.mem.eql(u8, child.kind(), "invocation_expression")) value = child;
            }
        } else {
            name_node = node.childByField("left");
            value = node.childByField("right");
        }
        const name = name_node orelse return;
        const right = value orelse return;
        if (!std.mem.eql(u8, right.kind(), "invocation_expression")) return;
        if (!self.chainHasGroup(right)) return;
        const prefix = try self.receiverPrefix(right, node.startByte());
        _ = try self.sink.addGroup(.{ .name = self.text(name), .prefix = prefix, .top = false }, node.endByte(), self.scopeOf(node));
    }

    fn chainHasGroup(self: *const Scan, start: ts.Node) bool {
        var node = start;
        while (std.mem.eql(u8, node.kind(), "invocation_expression")) {
            const member = self.memberCall(node) orelse return false;
            if (std.mem.eql(u8, member.name, "MapGroup")) return true;
            node = member.object;
        }
        return false;
    }

    fn invocation(self: *Scan, node: ts.Node) !void {
        const member = self.memberCall(node) orelse return;
        const at = node.startByte();
        const line = lineOf(node);
        const name = member.name;
        if (verbOf(&minimal_calls, name)) |verb| {
            const path = self.argument(node, 0) orelse return;
            const handler = self.argument(node, 1);
            if (std.mem.eql(u8, name, "Map")) {
                if (handler == null or self.literal(path) == null) return;
            }
            if (!std.mem.eql(u8, name, "MapHealthChecks") and handler == null) return;
            return self.minimal(node, member, verb, try self.pathText(path), handler, at, line);
        }
        if (std.mem.eql(u8, name, "MapMethods")) {
            const path = self.argument(node, 0) orelse return;
            const verbs_node = self.argument(node, 1);
            const tag = if (verbs_node) |v| try self.literalVerbs(v) else "ALL";
            return self.minimal(node, member, tag, try self.pathText(path), self.argument(node, 2), at, line);
        }
        if (std.mem.eql(u8, name, "MapFallback")) {
            const count = self.argument(node, 1);
            const path = if (count != null) self.argument(node, 0) else null;
            const handler = count orelse self.argument(node, 0);
            return self.minimal(node, member, "ALL", if (path) |p| try self.pathText(p) else "<fallback>", handler, at, line);
        }
        if (std.mem.eql(u8, name, "MapControllerRoute")) {
            const pattern = self.keywordArgument(node, "pattern") orelse self.argument(node, 1) orelse return;
            return self.sink.entries.append(self.sink.arena, .{ .kind = .route, .tag = "ALL", .text = try self.pathText(pattern), .line = line });
        }
        if (std.mem.eql(u8, name, "MapHub") or std.mem.eql(u8, name, "MapGrpcService")) {
            const hub = std.mem.eql(u8, name, "MapHub");
            const path = if (hub) self.argument(node, 0) else null;
            const prefix = try self.receiverPrefix(member.object, at);
            const shown = if (path) |p| try joined(self.sink.arena, prefix, try self.pathText(p)) else "";
            var entry: facts.MapEntry = .{ .kind = .route, .tag = if (hub) "WS" else "RPC", .text = shown, .line = line };
            entry.handler = try self.typeArgument(member.generic);
            entry.handler_start = member.generic.startByte();
            entry.handler_end = member.generic.endByte();
            return self.sink.entries.append(self.sink.arena, entry);
        }
        if (std.mem.eql(u8, name, "AddCommand")) {
            const stated = self.argument(node, 0);
            var entry: facts.MapEntry = .{ .kind = .command, .tag = "cmd", .text = if (stated) |s| try self.pathText(s) else "", .line = line };
            entry.handler = try self.typeArgument(member.generic);
            entry.handler_start = member.generic.startByte();
            entry.handler_end = member.generic.endByte();
            return self.sink.entries.append(self.sink.arena, entry);
        }
    }

    fn keywordArgument(self: *const Scan, call: ts.Node, name: []const u8) ?ts.Node {
        const args = self.argumentsOf(call) orelse return null;
        var i: u32 = 0;
        while (args.namedChild(i)) |arg| : (i += 1) {
            if (!std.mem.eql(u8, arg.kind(), "argument")) continue;
            const key = arg.childByField("name") orelse continue;
            if (std.mem.eql(u8, self.text(key), name)) return valueOf(arg);
        }
        return null;
    }

    fn literalVerbs(self: *const Scan, node: ts.Node) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var walker = traversal.Walker.init(node);
        defer walker.deinit();
        while (walker.next()) |entry| {
            const value = self.literal(entry.node) orelse continue;
            if (out.items.len != 0) try out.append(self.sink.arena, ',');
            for (value) |c| try out.append(self.sink.arena, std.ascii.toUpper(c));
            walker.skipChildren();
        }
        return if (out.items.len == 0) "ALL" else out.items;
    }

    fn minimal(self: *Scan, node: ts.Node, member: MemberCall, tag: []const u8, path: []const u8, handler: ?ts.Node, at: u32, line: u32) !void {
        _ = node;
        const prefix = try self.receiverPrefix(member.object, at);
        var entry: facts.MapEntry = .{ .kind = .route, .tag = tag, .text = try joined(self.sink.arena, prefix, path), .stated = true, .line = line };
        if (handler) |h| {
            if (!std.mem.endsWith(u8, h.kind(), "lambda_expression")) {
                entry.handler = try self.sink.shown(h);
                entry.handler_start = h.startByte();
                entry.handler_end = h.endByte();
            }
        }
        try self.sink.entries.append(self.sink.arena, entry);
    }

    fn creation(self: *Scan, node: ts.Node) !void {
        if (!self.uses("System.CommandLine")) return;
        const kind = node.childByField("type") orelse return;
        const name = self.typeName(kind);
        if (std.mem.eql(u8, name, "RootCommand")) {
            return self.sink.entries.append(self.sink.arena, .{ .kind = .command, .tag = "cmd", .text = "<root>", .line = lineOf(node) });
        }
        if (!std.mem.eql(u8, name, "Command")) return;
        const args = node.childByField("arguments") orelse return;
        const first = args.namedChild(0) orelse return;
        const value = valueOf(first) orelse return;
        try self.sink.entries.append(self.sink.arena, .{ .kind = .command, .tag = "cmd", .text = try self.pathText(value), .line = lineOf(node) });
    }

    fn run(self: *Scan) !void {
        var first = traversal.Walker.init(self.sink.tree.root());
        defer first.deinit();
        while (first.next()) |entry| {
            const node = entry.node;
            if (!node.isNamed()) continue;
            const kind = node.kind();
            if (std.mem.eql(u8, kind, "using_directive")) {
                try self.usingDirective(node);
                first.skipChildren();
            } else if (std.mem.eql(u8, kind, "attribute")) {
                const name = node.childByField("name") orelse continue;
                if (isTestAttribute(self.text(name))) self.sink.test_content = true;
            } else if (std.mem.eql(u8, kind, "class_declaration") or std.mem.eql(u8, kind, "record_declaration") or std.mem.eql(u8, kind, "struct_declaration")) {
                try self.classGroup(node);
                try self.classEntries(node);
            } else if (std.mem.eql(u8, kind, "variable_declarator") or std.mem.eql(u8, kind, "assignment_expression")) {
                try self.declaredGroup(node);
            }
        }
        var second = traversal.Walker.init(self.sink.tree.root());
        defer second.deinit();
        while (second.next()) |entry| {
            const node = entry.node;
            if (!node.isNamed()) continue;
            const kind = node.kind();
            if (std.mem.eql(u8, kind, "method_declaration") or std.mem.eql(u8, kind, "local_function_statement")) {
                try self.method(node);
            } else if (std.mem.eql(u8, kind, "invocation_expression")) {
                try self.invocation(node);
            } else if (std.mem.eql(u8, kind, "object_creation_expression")) {
                try self.creation(node);
            }
        }
    }
};

const MemberCall = struct {
    object: ts.Node,
    name: []const u8,
    generic: ts.Node,
};

fn attributeArguments(attribute: ts.Node) ?ts.Node {
    var i: u32 = 0;
    while (attribute.namedChild(i)) |child| : (i += 1) {
        if (std.mem.eql(u8, child.kind(), "attribute_argument_list")) return child;
    }
    return null;
}

fn valueOf(argument: ts.Node) ?ts.Node {
    const count = argument.namedChildCount();
    if (count == 0) return null;
    return argument.namedChild(count - 1);
}

fn joined(arena: Allocator, left: []const u8, right: []const u8) Allocator.Error![]const u8 {
    if (left.len == 0) return right;
    if (right.len == 0) return left;
    const a = std.mem.trimEnd(u8, left, "/");
    const b = std.mem.trimStart(u8, right, "/");
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ a, b });
}

pub fn extract(arena: Allocator, tree: ts.Tree, defs: []const facts.Def) Allocator.Error!facts.MapFacts {
    var scan: Scan = .{ .sink = .{ .arena = arena, .tree = tree, .defs = defs } };
    try scan.run();
    return scan.sink.finish();
}

const testing = std.testing;

test "csharp map: a file name marks tests when plural, a singular name needs more" {
    try testing.expect(isTestName("CartTests.cs"));
    try testing.expect(isTestName("Cart.Tests.cs"));
    try testing.expect(isTestName("CartSpecs.cs"));
    try testing.expect(!isTestName("ABTest.cs"));
    try testing.expect(!isTestName("Latest.cs"));
    try testing.expect(!isTestName("Contest.cs"));
}

test "csharp map: a project folder marks tests by its dotted or capital ending, not by the letters" {
    try testing.expect(isTestSegment("Shop.Tests"));
    try testing.expect(isTestSegment("Shop.UnitTests"));
    try testing.expect(isTestSegment("Shop.IntegrationTests"));
    try testing.expect(isTestSegment("Shop.Tests.Unit"));
    try testing.expect(isTestSegment("Shop.Specs"));
    try testing.expect(!isTestSegment("Contests"));
    try testing.expect(!isTestSegment("Shop.Contests"));
    try testing.expect(!isTestSegment("Shop.Testing"));
}

test "csharp map: an attribute is a test attribute with or without its suffix and qualifier" {
    try testing.expect(isTestAttribute("Fact"));
    try testing.expect(isTestAttribute("FactAttribute"));
    try testing.expect(isTestAttribute("NUnit.Framework.TestCase"));
    try testing.expect(!isTestAttribute("Route"));
    try testing.expect(isTestNamespace("Xunit.Abstractions"));
    try testing.expect(!isTestNamespace("XunitExtras"));
}
