const std = @import("std");
const ts = @import("tree_sitter.zig");
const traversal = @import("traversal.zig");
const profile_mod = @import("lang/profile.zig");

const Allocator = std.mem.Allocator;
const Profile = profile_mod.Profile;
const Binding = profile_mod.Binding;

pub const FunctionKind = profile_mod.FunctionKind;

pub const Function = struct {
    node: ts.Node,
    kind: FunctionKind,
    body: ts.Node,
    name: ?ts.Node,
    nested: bool,
};

pub fn classify(profile: *const Profile, node: ts.Node) ?Function {
    const entry = profile.functionNode(node.kind()) orelse return null;
    const kind = entry.kind;
    const body = node.childByField(entry.body_field) orelse return null;
    if (entry.body_only) |only| if (!std.mem.eql(u8, only, body.kind())) return null;
    return .{
        .node = node,
        .kind = kind,
        .body = body,
        .name = resolveName(profile, node, kind),
        .nested = false,
    };
}

fn resolveName(profile: *const Profile, node: ts.Node, kind: FunctionKind) ?ts.Node {
    if (profile.functionName(node.kind())) |named| {
        const field = named.field orelse return if (named.token) |token| childOfKind(node, token) else null;
        var owner = node;
        for (0..named.owner_depth) |_| owner = owner.parent() orelse return null;
        return owner.childByField(field) orelse if (named.token) |token| childOfKind(owner, token) else null;
    }
    const own = node.childByField("name");
    return switch (kind) {
        .declaration, .generator_declaration, .method => own,
        else => bindingName(profile, node) orelse own,
    };
}

pub fn childOfKind(node: ts.Node, kind: []const u8) ?ts.Node {
    var i: u32 = 0;
    while (node.child(i)) |child| : (i += 1) {
        if (std.mem.eql(u8, child.kind(), kind)) return child;
    }
    return null;
}

pub fn bindingSite(profile: *const Profile, node: ts.Node) ?ts.Node {
    var value = node;
    var parent = node.parent() orelse return null;
    while (isOneOf(parent.kind(), profile.transparent_wrappers)) {
        value = parent;
        parent = parent.parent() orelse return null;
    }
    const binding = bindingFor(profile, parent) orelse return null;
    const bound = if (binding.value_field.len != 0) parent.childByField(binding.value_field) orelse return null else lastNamedChild(parent) orelse return null;
    return if (bound.eql(value)) parent else null;
}

fn lastNamedChild(node: ts.Node) ?ts.Node {
    const count = node.namedChildCount();
    if (count == 0) return null;
    return node.namedChild(count - 1);
}

pub fn bindingName(profile: *const Profile, node: ts.Node) ?ts.Node {
    const site = bindingSite(profile, node) orelse return null;
    return site.childByField(bindingFor(profile, site).?.name_field);
}

fn bindingFor(profile: *const Profile, node: ts.Node) ?Binding {
    for (profile.bindings) |binding| {
        if (std.mem.eql(u8, binding.parent, node.kind())) return binding;
    }
    return null;
}

pub fn isOneOf(kind: []const u8, kinds: []const []const u8) bool {
    for (kinds) |candidate| {
        if (std.mem.eql(u8, candidate, kind)) return true;
    }
    return false;
}

pub const Span = struct { start: u32, end: u32 };

pub fn collectFunctions(gpa: Allocator, profile: *const Profile, tree: ts.Tree) Allocator.Error![]Function {
    var found: std.ArrayList(Function) = .empty;
    errdefer found.deinit(gpa);
    var open_bodies: std.ArrayList(Span) = .empty;
    defer open_bodies.deinit(gpa);

    var walker = traversal.Walker.init(tree.root());
    defer walker.deinit();
    while (walker.next()) |entry| {
        if (!entry.node.isNamed()) continue;
        var function = classify(profile, entry.node) orelse continue;
        const start = entry.node.startByte();
        while (open_bodies.getLastOrNull()) |body| {
            if (start < body.end) break;
            _ = open_bodies.pop();
        }
        function.nested = insideAny(open_bodies.items, start);
        try open_bodies.append(gpa, .{ .start = function.body.startByte(), .end = function.body.endByte() });
        try found.append(gpa, function);
    }
    return found.toOwnedSlice(gpa);
}

fn insideAny(bodies: []const Span, offset: u32) bool {
    for (bodies) |body| {
        if (offset >= body.start and offset < body.end) return true;
    }
    return false;
}
