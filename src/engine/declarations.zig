const std = @import("std");
const ts = @import("tree_sitter.zig");
const ref_mod = @import("ref.zig");
const functions_mod = @import("functions.zig");
const profile_mod = @import("lang/profile.zig");

const Allocator = std.mem.Allocator;
const Profile = profile_mod.Profile;
const DeclarationKind = profile_mod.DeclarationKind;
const DeclarationShape = profile_mod.DeclarationShape;
const Span = functions_mod.Span;
const Ref = ref_mod.Ref;

pub const Hash = [16]u8;

pub const Declaration = struct {
    ref: Ref,
    kind: DeclarationKind,
    node: ts.Node,
    name: ts.Node,
    declaration: Span,
    hash: Hash,
    ambiguous: bool = false,
};

const domain = "emetgate declaration v1";

pub fn hashOf(kind: DeclarationKind, source: []const u8, prefix: Span, span: Span) Hash {
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

fn oneOf(kind: []const u8, kinds: []const []const u8) bool {
    for (kinds) |candidate| {
        if (std.mem.eql(u8, candidate, kind)) return true;
    }
    return false;
}

fn shapeOf(shapes: []const DeclarationShape, kind: []const u8) ?DeclarationShape {
    for (shapes) |shape| {
        if (std.mem.eql(u8, shape.node, kind)) return shape;
    }
    return null;
}

const Collector = struct {
    arena: Allocator,
    profile: *const Profile,
    tree: ts.Tree,
    out: std.ArrayList(Declaration) = .empty,

    fn text(self: *Collector, node: ts.Node) []const u8 {
        return self.tree.text(node);
    }

    fn outerOf(self: *Collector, node: ts.Node) ts.Node {
        const parent = node.parent() orelse return node;
        return if (oneOf(parent.kind(), self.profile.export_wrappers)) parent else node;
    }

    fn decoratedStart(self: *Collector, node: ts.Node) u32 {
        var start = node.startByte();
        var prev = node.prevNamedSibling();
        while (prev) |sibling| : (prev = sibling.prevNamedSibling()) {
            if (self.profile.isComment(sibling.kind())) continue;
            if (!std.mem.eql(u8, self.profile.decorator, sibling.kind())) break;
            start = sibling.startByte();
        }
        return start;
    }

    fn add(self: *Collector, kind: DeclarationKind, node: ts.Node, name: ts.Node, container: []const []const u8, is_static: bool, prefix: Span, span: Span) !void {
        try self.out.append(self.arena, .{
            .ref = .{ .container = container, .name = self.text(name), .is_static = is_static },
            .kind = kind,
            .node = node,
            .name = name,
            .declaration = span,
            .hash = hashOf(kind, self.tree.source, prefix, span),
        });
    }

    fn statement(self: *Collector, node: ts.Node) !void {
        const shapes = self.profile.declarations;
        if (shapeOf(shapes.types, node.kind())) |shape| return self.typeDeclaration(node, shape);
        if (oneOf(node.kind(), shapes.variable_statements)) return self.variables(node);
    }

    fn typeDeclaration(self: *Collector, node: ts.Node, shape: DeclarationShape) !void {
        const name = node.childByField(shape.name_field) orelse return;
        const outer = self.outerOf(node);
        const empty: Span = .{ .start = 0, .end = 0 };
        try self.add(shape.kind, node, name, &.{}, false, empty, .{ .start = self.decoratedStart(outer), .end = outer.endByte() });
        const container = try self.arena.dupe([]const u8, &.{self.text(name)});
        switch (shape.kind) {
            .class => try self.fields(node, container),
            .enumeration => try self.enumMembers(node, container),
            else => {},
        }
    }

    fn isFunctionValue(self: *Collector, node: ts.Node) bool {
        var value = node.childByField(self.profile.declarations.value_field) orelse return false;
        while (oneOf(value.kind(), self.profile.transparent_wrappers)) {
            value = value.namedChild(0) orelse return false;
        }
        return self.profile.functionKind(value.kind()) != null;
    }

    fn hasKeywordBefore(self: *Collector, holder: ts.Node, name: ts.Node) bool {
        const keyword = self.profile.declarations.static_keyword orelse return false;
        var i: u32 = 0;
        while (holder.child(i)) |child| : (i += 1) {
            if (child.eql(name)) return false;
            if (!child.isNamed() and std.mem.eql(u8, keyword, child.kind())) return true;
        }
        return false;
    }

    fn fields(self: *Collector, class: ts.Node, container: []const []const u8) !void {
        const body = class.childByField("body") orelse return;
        var i: u32 = 0;
        while (body.namedChild(i)) |member| : (i += 1) {
            const shape = shapeOf(self.profile.declarations.fields, member.kind()) orelse continue;
            if (self.isFunctionValue(member)) continue;
            const name = member.childByField(shape.name_field) orelse continue;
            if (!oneOf(name.kind(), self.profile.addressable_names)) continue;
            const empty: Span = .{ .start = 0, .end = 0 };
            try self.add(.field, member, name, container, self.hasKeywordBefore(member, name), empty, .{ .start = self.decoratedStart(member), .end = member.endByte() });
        }
    }

    fn enumMembers(self: *Collector, enumeration: ts.Node, container: []const []const u8) !void {
        const shapes = self.profile.declarations;
        const body_kind = shapes.enum_body orelse return;
        var i: u32 = 0;
        const body = while (enumeration.namedChild(i)) |child| : (i += 1) {
            if (std.mem.eql(u8, child.kind(), body_kind)) break child;
        } else return;
        const empty: Span = .{ .start = 0, .end = 0 };
        var j: u32 = 0;
        while (body.namedChild(j)) |member| : (j += 1) {
            if (shapes.enum_bare_member) |bare| if (std.mem.eql(u8, bare, member.kind())) {
                try self.add(.enum_member, member, member, container, false, empty, .{ .start = member.startByte(), .end = member.endByte() });
                continue;
            };
            const shape = shapeOf(shapes.enum_members, member.kind()) orelse continue;
            const name = member.childByField(shape.name_field) orelse continue;
            try self.add(.enum_member, member, name, container, false, empty, .{ .start = member.startByte(), .end = member.endByte() });
        }
    }

    fn variables(self: *Collector, statement_node: ts.Node) !void {
        const outer = self.outerOf(statement_node);
        var declarators: u32 = 0;
        var i: u32 = 0;
        while (statement_node.namedChild(i)) |child| : (i += 1) {
            if (std.mem.eql(u8, child.kind(), self.profile.declarator)) declarators += 1;
        }
        i = 0;
        var first_start: ?u32 = null;
        while (statement_node.namedChild(i)) |child| : (i += 1) {
            if (!std.mem.eql(u8, child.kind(), self.profile.declarator)) continue;
            if (first_start == null) first_start = child.startByte();
            const name = child.childByField("name") orelse continue;
            if (oneOf(name.kind(), self.profile.declarations.destructuring)) continue;
            if (self.isFunctionValue(child)) continue;
            if (declarators == 1) {
                const empty: Span = .{ .start = 0, .end = 0 };
                try self.add(.variable, child, name, &.{}, false, empty, .{ .start = self.decoratedStart(outer), .end = outer.endByte() });
            } else {
                try self.add(.variable, child, name, &.{}, false, .{ .start = outer.startByte(), .end = first_start.? }, .{ .start = child.startByte(), .end = child.endByte() });
            }
        }
    }
};

pub fn collect(arena: Allocator, profile: *const Profile, tree: ts.Tree) Allocator.Error![]Declaration {
    var collector: Collector = .{ .arena = arena, .profile = profile, .tree = tree };
    const root = tree.root();
    var i: u32 = 0;
    while (root.namedChild(i)) |child| : (i += 1) {
        if (oneOf(child.kind(), profile.export_wrappers)) {
            var j: u32 = 0;
            while (child.namedChild(j)) |inner| : (j += 1) try collector.statement(inner);
            continue;
        }
        try collector.statement(child);
    }
    markAmbiguous(collector.out.items);
    return collector.out.items;
}

fn markAmbiguous(items: []Declaration) void {
    for (items, 0..) |*a, i| {
        for (items[i + 1 ..]) |*b| {
            if (!a.ref.eql(b.ref)) continue;
            a.ambiguous = true;
            b.ambiguous = true;
        }
    }
}
