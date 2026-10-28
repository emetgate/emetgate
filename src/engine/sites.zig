const std = @import("std");
const ts = @import("tree_sitter.zig");
const profile_mod = @import("lang/profile.zig");

const Rename = profile_mod.Rename;
const BinderSite = profile_mod.BinderSite;

pub fn oneOf(kind: []const u8, kinds: []const []const u8) bool {
    for (kinds) |candidate| {
        if (std.mem.eql(u8, candidate, kind)) return true;
    }
    return false;
}

pub const TreeUp = struct {
    pub fn parent(_: TreeUp, node: ts.Node) ?ts.Node {
        return node.parent();
    }
};

pub const PathUp = struct {
    path: []const ts.Node,
    leaf: ts.Node,

    pub fn parent(self: PathUp, node: ts.Node) ?ts.Node {
        if (node.eql(self.leaf)) return if (self.path.len == 0) null else self.path[self.path.len - 1];
        var i = self.path.len;
        while (i > 0) : (i -= 1) {
            if (self.path[i - 1].eql(node)) return if (i >= 2) self.path[i - 2] else null;
        }
        return node.parent();
    }
};

pub fn siteOf(g: *const Rename, node: ts.Node) ?BinderSite {
    return siteIn(g, TreeUp{}, node);
}

pub fn siteIn(g: *const Rename, up: anytype, node: ts.Node) ?BinderSite {
    return matchingSite(g.binder_sites, up, node);
}

fn atPosition(parent: ts.Node, node: ts.Node, position: profile_mod.Position) bool {
    return switch (position) {
        .any => true,
        .first => if (parent.namedChild(0)) |first| first.eql(node) else false,
        .rest => if (parent.namedChild(0)) |first| !first.eql(node) else false,
        .sole => parent.namedChildCount() == 1,
    };
}

fn matchingSite(sites: []const BinderSite, up: anytype, node: ts.Node) ?BinderSite {
    const parent = up.parent(node) orelse return null;
    const kind = parent.kind();
    for (sites) |site| {
        if (!std.mem.eql(u8, site.parent, kind)) continue;
        if (site.parent_field) |pf| {
            const grand = up.parent(parent) orelse continue;
            if (site.grandparent) |gk| if (!std.mem.eql(u8, grand.kind(), gk)) continue;
            if (!holdsInField(grand, pf, parent)) continue;
        } else if (site.grandparent) |gk| {
            const grand = up.parent(parent) orelse continue;
            if (!std.mem.eql(u8, grand.kind(), gk)) continue;
        }
        if (!atPosition(parent, node, site.position)) continue;
        const field = site.field orelse return site;
        if (site.unless) |unless| if (parent.childByField(unless) != null) continue;
        const held = parent.childByField(field) orelse continue;
        if (held.eql(node)) return site;
    }
    return null;
}

fn holdsInField(holder: ts.Node, field: []const u8, node: ts.Node) bool {
    var i: u32 = 0;
    while (holder.child(i)) |child| : (i += 1) {
        if (!child.eql(node)) continue;
        const name = holder.fieldNameForChild(i) orelse return false;
        return std.mem.eql(u8, name, field);
    }
    return false;
}

pub fn isProperty(g: *const Rename, node: ts.Node) bool {
    return isPropertyIn(g, TreeUp{}, node);
}

pub fn isPropertyIn(g: *const Rename, up: anytype, node: ts.Node) bool {
    if (matchingSite(g.inert_sites, up, node) != null) return true;
    if (g.property_sites.len == 0) return false;
    const parent = up.parent(node) orelse return false;
    const kind = parent.kind();
    for (g.property_sites) |site| {
        if (!std.mem.eql(u8, site.parent, kind)) continue;
        const held = parent.childByField(site.field) orelse continue;
        if (held.eql(node)) return true;
    }
    return false;
}

pub fn isExternal(g: *const Rename, node: ts.Node) bool {
    return externalIn(g, TreeUp{}, node);
}

pub fn externalIn(g: *const Rename, up: anytype, node: ts.Node) bool {
    const parent = up.parent(node) orelse return false;
    for (g.external_sites) |site| {
        if (!std.mem.eql(u8, site.parent, parent.kind())) continue;
        const held = parent.childByField(site.field) orelse continue;
        if (!held.eql(node)) continue;
        if (site.when) |when| if (parent.childByField(when) == null) continue;
        if (site.statement_field) |field| if (!statementHas(up, parent, field)) continue;
        return true;
    }
    return false;
}

fn statementHas(up: anytype, node: ts.Node, field: []const u8) bool {
    var current = up.parent(node);
    while (current) |ancestor| : (current = up.parent(ancestor)) {
        if (ancestor.childByField(field) != null) return true;
    }
    return false;
}
