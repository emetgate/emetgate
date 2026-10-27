const std = @import("std");
const ts = @import("tree_sitter.zig");
const ref_mod = @import("ref.zig");
const functions_mod = @import("functions.zig");
const profile_mod = @import("lang/profile.zig");
const test_util = @import("test_util.zig");

const Allocator = std.mem.Allocator;
const Profile = profile_mod.Profile;
const Items = profile_mod.Items;
const Span = functions_mod.Span;
const Ref = ref_mod.Ref;
const isOneOf = functions_mod.isOneOf;

pub const Hash = [16]u8;

pub const Kind = enum { statement, import, binding, property };

pub const Statement = struct {
    ref: Ref,
    kind: Kind,
    node: ts.Node,
    declaration: Span,
    hash: Hash,
    ambiguous: bool = false,
};

const domain = "emetgate statement v1";
const empty: Span = .{ .start = 0, .end = 0 };

pub fn hashOf(kind: Kind, source: []const u8, prefix: Span, span: Span) Hash {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(domain);
    hasher.update(&.{0});
    hasher.update(@tagName(kind));
    hasher.update(&.{0});
    hasher.update(source[prefix.start..prefix.end]);
    hasher.update(source[span.start..span.end]);
    var out: Hash = undefined;
    hasher.final(&out);
    return out;
}

pub fn configured(profile: *const Profile) bool {
    const items = profile.declarations.items;
    return items.assignment != null or items.imports.len != 0;
}

fn is(kind: []const u8, wanted: ?[]const u8) bool {
    const w = wanted orelse return false;
    return std.mem.eql(u8, kind, w);
}

fn appendChain(arena: Allocator, items: Items, tree: ts.Tree, node: ts.Node, out: *std.ArrayList([]const u8)) Allocator.Error!bool {
    if (std.mem.eql(u8, node.kind(), items.chain_root)) {
        try out.append(arena, tree.text(node));
        return true;
    }
    if (!is(node.kind(), items.member_chain)) return false;
    const object = node.childByField(items.chain_object) orelse return false;
    const property = node.childByField(items.chain_property) orelse return false;
    if (!std.mem.eql(u8, property.kind(), items.chain_segment)) return false;
    if (!try appendChain(arena, items, tree, object, out)) return false;
    try out.append(arena, tree.text(property));
    return true;
}

pub fn chainNames(arena: Allocator, profile: *const Profile, tree: ts.Tree, node: ts.Node) Allocator.Error!?[]const []const u8 {
    if (!configured(profile)) return null;
    var out: std.ArrayList([]const u8) = .empty;
    if (!try appendChain(arena, profile.declarations.items, tree, node, &out)) return null;
    return out.items;
}

pub fn topLevelChain(arena: Allocator, profile: *const Profile, tree: ts.Tree, name: ts.Node) Allocator.Error!?[]const []const u8 {
    const assignment = name.parent() orelse return null;
    if (!is(assignment.kind(), profile.declarations.items.assignment)) return null;
    const statement = assignment.parent() orelse return null;
    if (!std.mem.eql(u8, statement.kind(), profile.expression_statement)) return null;
    const root = statement.parent() orelse return null;
    if (!std.mem.eql(u8, root.kind(), profile.root)) return null;
    const chain = try chainNames(arena, profile, tree, name) orelse return null;
    return if (chain.len >= 2) chain else null;
}

pub fn isFunctionValue(profile: *const Profile, node: ts.Node) bool {
    var value = node;
    while (isOneOf(value.kind(), profile.transparent_wrappers)) {
        value = value.namedChild(0) orelse return false;
    }
    return profile.functionKind(value.kind()) != null;
}

const Collector = struct {
    arena: Allocator,
    profile: *const Profile,
    items: Items,
    tree: ts.Tree,
    out: std.ArrayList(Statement) = .empty,

    fn add(self: *Collector, kind: Kind, node: ts.Node, container: []const []const u8, name: []const u8, prefix: Span, span: Span) !void {
        try self.out.append(self.arena, .{
            .ref = .{ .container = container, .name = name },
            .kind = kind,
            .node = node,
            .declaration = span,
            .hash = hashOf(kind, self.tree.source, prefix, span),
        });
    }

    fn top(self: *Collector, outer: ts.Node, inner: ts.Node) !void {
        const span: Span = .{ .start = outer.startByte(), .end = outer.endByte() };
        if (isOneOf(inner.kind(), self.items.imports)) return self.boundNames(.import, outer, inner, &.{}, empty, span);
        if (isOneOf(inner.kind(), self.profile.declarations.variable_statements)) return self.variables(outer, inner);
        if (!std.mem.eql(u8, inner.kind(), self.profile.expression_statement)) return;
        const expression = inner.namedChild(0) orelse return;
        if (is(expression.kind(), self.items.assignment)) return self.assignment(outer, expression, span);
        if (std.mem.eql(u8, expression.kind(), self.profile.call.node)) {
            const callee = expression.childByField(self.profile.call.function_field) orelse return;
            const chain = try chainNames(self.arena, self.profile, self.tree, callee) orelse return;
            return self.add(.statement, outer, chain[0 .. chain.len - 1], chain[chain.len - 1], empty, span);
        }
        const text = self.tree.text(expression);
        if (isOneOf(text, self.profile.directives) and text.len > 2) try self.add(.statement, outer, &.{}, text[1 .. text.len - 1], empty, span);
    }

    fn assignment(self: *Collector, outer: ts.Node, expression: ts.Node, span: Span) !void {
        const left = expression.childByField(self.items.assignment_left) orelse return;
        const right = expression.childByField(self.items.assignment_right) orelse return;
        if (isFunctionValue(self.profile, right)) return;
        const chain = try chainNames(self.arena, self.profile, self.tree, left) orelse return;
        if (chain.len < 2) return;
        try self.add(.statement, outer, chain[0 .. chain.len - 1], chain[chain.len - 1], empty, span);
        if (is(right.kind(), self.items.object)) try self.properties(right, chain);
    }

    fn variables(self: *Collector, outer: ts.Node, statement: ts.Node) !void {
        var declarators: u32 = 0;
        var first_start: u32 = statement.startByte();
        var i: u32 = 0;
        while (statement.namedChild(i)) |child| : (i += 1) {
            if (!std.mem.eql(u8, child.kind(), self.profile.declarator)) continue;
            if (declarators == 0) first_start = child.startByte();
            declarators += 1;
        }
        i = 0;
        while (statement.namedChild(i)) |child| : (i += 1) {
            if (!std.mem.eql(u8, child.kind(), self.profile.declarator)) continue;
            const name = child.childByField("name") orelse continue;
            if (isOneOf(name.kind(), self.profile.declarations.destructuring)) {
                if (declarators == 1) {
                    try self.boundNames(.binding, outer, name, &.{}, empty, .{ .start = outer.startByte(), .end = outer.endByte() });
                } else {
                    try self.boundNames(.binding, child, name, &.{}, .{ .start = outer.startByte(), .end = first_start }, .{ .start = child.startByte(), .end = child.endByte() });
                }
                continue;
            }
            const value = child.childByField(self.profile.declarations.value_field) orelse continue;
            if (is(value.kind(), self.items.object)) {
                const container = try self.arena.dupe([]const u8, &.{self.tree.text(name)});
                try self.properties(value, container);
            }
        }
    }

    fn boundNames(self: *Collector, kind: Kind, node: ts.Node, holder: ts.Node, container: []const []const u8, prefix: Span, span: Span) !void {
        var i: u32 = 0;
        while (holder.child(i)) |child| : (i += 1) {
            const field = holder.fieldNameForChild(i);
            if (field) |f| {
                if (std.mem.eql(u8, f, self.items.import_source)) continue;
                if (isOneOf(f, self.items.pattern_skip_fields)) continue;
                if (std.mem.eql(u8, f, "name") and holder.childByField(self.items.alias_field) != null) continue;
            }
            if (isOneOf(child.kind(), self.items.pattern_names)) {
                try self.add(kind, node, container, self.tree.text(child), prefix, span);
                continue;
            }
            try self.boundNames(kind, node, child, container, prefix, span);
        }
    }

    fn properties(self: *Collector, object: ts.Node, container: []const []const u8) Allocator.Error!void {
        var i: u32 = 0;
        while (object.namedChild(i)) |pair| : (i += 1) {
            if (!std.mem.eql(u8, pair.kind(), self.items.pair)) continue;
            const key = pair.childByField(self.items.pair_key) orelse continue;
            if (!isOneOf(key.kind(), self.items.property_keys)) continue;
            const value = pair.childByField(self.items.pair_value) orelse continue;
            if (isFunctionValue(self.profile, value)) continue;
            const name = unquote(self.tree.text(key));
            if (name.len == 0) continue;
            try self.add(.property, pair, container, name, empty, .{ .start = pair.startByte(), .end = pair.endByte() });
            if (!is(value.kind(), self.items.object)) continue;
            const inner = try self.arena.alloc([]const u8, container.len + 1);
            @memcpy(inner[0..container.len], container);
            inner[container.len] = name;
            try self.properties(value, inner);
        }
    }
};

fn unquote(text: []const u8) []const u8 {
    if (text.len >= 2 and (text[0] == '"' or text[0] == '\'') and text[text.len - 1] == text[0]) return text[1 .. text.len - 1];
    return text;
}

fn exported(profile: *const Profile, wrapper: ts.Node) ?ts.Node {
    var i: u32 = 0;
    while (wrapper.namedChild(i)) |child| : (i += 1) {
        if (isOneOf(child.kind(), profile.declarations.variable_statements)) return child;
    }
    return null;
}

pub fn collect(arena: Allocator, profile: *const Profile, tree: ts.Tree, taken: []const Ref) Allocator.Error![]Statement {
    if (!configured(profile)) return &.{};
    var collector: Collector = .{ .arena = arena, .profile = profile, .items = profile.declarations.items, .tree = tree };
    const root = tree.root();
    var i: u32 = 0;
    while (root.namedChild(i)) |child| : (i += 1) {
        if (profile.isComment(child.kind())) continue;
        if (isOneOf(child.kind(), profile.export_wrappers)) {
            if (exported(profile, child)) |inner| try collector.variables(child, inner);
            continue;
        }
        try collector.top(child, child);
    }
    try number(arena, collector.out.items, taken);
    return collector.out.items;
}

fn number(arena: Allocator, items: []Statement, taken: []const Ref) Allocator.Error!void {
    for (items, 0..) |*item, i| {
        var seen: usize = 0;
        for (taken) |ref| {
            if (ref.eql(item.ref)) seen += 1;
        }
        for (items[0..i]) |earlier| {
            if (earlier.ref.eql(item.ref) or std.mem.eql(u8, earlier.ref.name, item.ref.name) and sameContainer(earlier.ref, item.ref) and earlier.kind == .statement) seen += 1;
        }
        if (item.kind == .statement and seen != 0) {
            item.ref.name = try std.fmt.allocPrint(arena, "{s}#{d}", .{ item.ref.name, seen + 1 });
            continue;
        }
        if (seen == 0) continue;
        item.ambiguous = true;
        for (items[0..i]) |*earlier| {
            if (earlier.ref.eql(item.ref)) earlier.ambiguous = true;
        }
    }
}

fn sameContainer(a: Ref, b: Ref) bool {
    if (a.container.len != b.container.len) return false;
    for (a.container, b.container) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

const testing = std.testing;

fn refsOf(source: []const u8, ext: []const u8) ![]const u8 {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const snapshot = try test_util.snapshotIn(runtime, source, ext);
    defer snapshot.destroy();
    const table = try snapshot.symbols();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    for (table.statements) |s| {
        const text = try std.fmt.allocPrint(testing.allocator, "{t}:{f};", .{ s.kind, s.ref });
        defer testing.allocator.free(text);
        try out.appendSlice(testing.allocator, text);
    }
    return out.toOwnedSlice(testing.allocator);
}

test "statements: requires, destructuring, module.exports, calls, directives and object properties get refs" {
    const source =
        \\'use strict';
        \\const { join, resolve: res } = require('path');
        \\const fs = require('fs');
        \\const config = { port: 1, db: { host: 'h' }, run() {} };
        \\module.exports = { meta: { schema: [] }, create(context) { return {}; } };
        \\exports.helper = () => 1;
        \\app.use(fs);
        \\app.use(join);
        \\
    ;
    const refs = try refsOf(source, ".js");
    defer testing.allocator.free(refs);
    try testing.expectEqualStrings("statement:use strict;binding:join;binding:res;property:config.port;property:config.db;property:config.db.host;statement:module.exports;property:module.exports.meta;property:module.exports.meta.schema;statement:app.use;statement:app.use#2;", refs);
}

test "statements: imports bind their local names and a languages without items lists none" {
    const imports = try refsOf("import a, { b as c, d } from 'm';\nimport * as ns from 'n';\n", ".ts");
    defer testing.allocator.free(imports);
    try testing.expectEqualStrings("import:a;import:c;import:d;import:ns;", imports);
    const zig = try refsOf("const x = foo();\n", ".zig");
    defer testing.allocator.free(zig);
    try testing.expectEqualStrings("", zig);
}

test "statements: a top-level member-chain assignment of a function is a symbol, its object methods too" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const snapshot = try test_util.snapshotIn(runtime, "exports.helper = () => 1;\nmodule.exports = { create(context) { return {}; } };\nfunction f() { this.x = () => 2; }\n", ".js");
    defer snapshot.destroy();
    const table = try snapshot.symbols();
    const helper = try Ref.parse(testing.allocator, "exports.helper");
    defer helper.deinit(testing.allocator);
    _ = try table.resolve(helper);
    const create = try Ref.parse(testing.allocator, "module.exports.create");
    defer create.deinit(testing.allocator);
    _ = try table.resolve(create);
}
