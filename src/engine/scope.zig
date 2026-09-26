const std = @import("std");
const ts = @import("tree_sitter.zig");
const symbol = @import("symbol.zig");
const traversal = @import("traversal.zig");
const profile_mod = @import("lang/profile.zig");
const Snapshot = @import("loader.zig").Snapshot;
const test_util = @import("test_util.zig");

const Allocator = std.mem.Allocator;
const Span = symbol.Span;
const Profile = profile_mod.Profile;
const Rename = profile_mod.Rename;
const Namespace = profile_mod.Namespace;
const BinderSite = profile_mod.BinderSite;

pub const Region = struct {
    start: u32,
    end: u32,
    kind: []const u8,

    fn of(node: ts.Node) Region {
        return .{ .start = node.startByte(), .end = node.endByte(), .kind = node.kind() };
    }

    pub fn same(self: Region, other: Region) bool {
        return self.start == other.start and self.end == other.end and std.mem.eql(u8, self.kind, other.kind);
    }

    fn eql(self: Region, node: ts.Node) bool {
        return self.start == node.startByte() and self.end == node.endByte() and std.mem.eql(u8, self.kind, node.kind());
    }
};

pub const Binder = struct {
    span: Span,
    namespace: Namespace,
    scope: Region,
    import: bool,
};

pub const Use = struct {
    span: Span,
    namespace: Namespace,
    binder: ?usize,
};

pub const Resolution = struct {
    binders: []Binder,
    uses: []Use,
    externals: []Span,

    pub fn deinit(self: Resolution, gpa: Allocator) void {
        gpa.free(self.binders);
        gpa.free(self.uses);
        gpa.free(self.externals);
    }

    pub fn binderAt(self: Resolution, span: Span) ?usize {
        for (self.binders, 0..) |b, i| {
            if (b.span.start == span.start and b.span.end == span.end) return i;
        }
        return null;
    }

    pub fn useAt(self: Resolution, span: Span) ?Use {
        for (self.uses) |u| {
            if (u.span.start == span.start and u.span.end == span.end) return u;
        }
        return null;
    }
};

fn oneOf(kind: []const u8, kinds: []const []const u8) bool {
    for (kinds) |candidate| {
        if (std.mem.eql(u8, candidate, kind)) return true;
    }
    return false;
}

pub fn siteOf(g: *const Rename, node: ts.Node) ?BinderSite {
    const parent = node.parent() orelse return null;
    const kind = parent.kind();
    for (g.binder_sites) |site| {
        if (!std.mem.eql(u8, site.parent, kind)) continue;
        const field = site.field orelse return site;
        if (site.unless) |unless| if (parent.childByField(unless) != null) continue;
        const held = parent.childByField(field) orelse continue;
        if (held.eql(node)) return site;
    }
    return null;
}

pub fn isExternal(g: *const Rename, node: ts.Node) bool {
    const parent = node.parent() orelse return false;
    for (g.external_sites) |site| {
        if (!std.mem.eql(u8, site.parent, parent.kind())) continue;
        const held = parent.childByField(site.field) orelse continue;
        if (!held.eql(node)) continue;
        if (site.when) |when| if (parent.childByField(when) == null) continue;
        if (site.statement_field) |field| if (!statementHas(parent, field)) continue;
        return true;
    }
    return false;
}

fn statementHas(node: ts.Node, field: []const u8) bool {
    var current = node.parent();
    while (current) |ancestor| : (current = ancestor.parent()) {
        if (ancestor.childByField(field) != null) return true;
    }
    return false;
}

pub fn useNamespace(g: *const Rename, kind: []const u8) Namespace {
    return if (oneOf(kind, g.type_kinds)) .type else .value;
}

fn rootOf(node: ts.Node) ts.Node {
    var current = node;
    while (current.parent()) |parent| current = parent;
    return current;
}

fn blockAbove(g: *const Rename, node: ts.Node) ts.Node {
    var current = node.parent();
    while (current) |ancestor| : (current = ancestor.parent()) {
        if (oneOf(ancestor.kind(), g.block_scopes)) return ancestor;
    }
    return rootOf(node);
}

fn functionAbove(profile: *const Profile, node: ts.Node) ts.Node {
    var current = node.parent();
    while (current) |ancestor| : (current = ancestor.parent()) {
        if (profile.functionKind(ancestor.kind()) != null) return ancestor;
    }
    return rootOf(node);
}

fn declaratorScope(profile: *const Profile, g: *const Rename, declarator: ts.Node) ts.Node {
    const statement = declarator.parent() orelse return rootOf(declarator);
    if (oneOf(statement.kind(), g.function_scoped_statements)) return functionAbove(profile, statement);
    return blockAbove(g, declarator);
}

fn patternScope(profile: *const Profile, g: *const Rename, node: ts.Node) ts.Node {
    var current = node.parent();
    while (current) |ancestor| : (current = ancestor.parent()) {
        const holder = ancestor.parent() orelse break;
        if (siteOf(g, ancestor)) |site| {
            if (site.scope != .pattern) return scopeFor(profile, g, ancestor, site);
        }
        if (std.mem.eql(u8, holder.kind(), profile.declarator)) return declaratorScope(profile, g, holder);
    }
    return rootOf(node);
}

fn scopeFor(profile: *const Profile, g: *const Rename, node: ts.Node, site: BinderSite) ts.Node {
    const parent = node.parent().?;
    return switch (site.scope) {
        .block => blockAbove(g, parent),
        .function => functionAbove(profile, node),
        .own => parent,
        .owner => (parent.parent() orelse parent).parent() orelse parent,
        .pattern => patternScope(profile, g, node),
        .declarator => declaratorScope(profile, g, parent),
        .program => rootOf(node),
    };
}

fn isImport(g: *const Rename, node: ts.Node) bool {
    const parent = node.parent() orelse return false;
    return oneOf(parent.kind(), g.import_binders);
}

pub fn resolveName(gpa: Allocator, snapshot: *const Snapshot, name: []const u8) !Resolution {
    const g = snapshot.profile.rename orelse return error.UnsupportedLanguage;
    var binders: std.ArrayList(Binder) = .empty;
    errdefer binders.deinit(gpa);
    var uses: std.ArrayList(Use) = .empty;
    errdefer uses.deinit(gpa);
    var pending: std.ArrayList(ts.Node) = .empty;
    defer pending.deinit(gpa);
    var externals: std.ArrayList(Span) = .empty;
    errdefer externals.deinit(gpa);

    var walker = traversal.Walker.init(snapshot.tree.root());
    defer walker.deinit();
    while (walker.next()) |entry| {
        const node = entry.node;
        const kind = node.kind();
        if (snapshot.profile.isComment(kind) or oneOf(kind, snapshot.profile.strings)) {
            walker.skipChildren();
            continue;
        }
        if (node.childCount() != 0) continue;
        if (!std.mem.eql(u8, snapshot.source[node.startByte()..node.endByte()], name)) continue;
        const span: Span = .{ .start = node.startByte(), .end = node.endByte() };
        if (isExternal(g, node)) {
            try externals.append(gpa, span);
            continue;
        }
        if (siteOf(g, node)) |site| {
            try binders.append(gpa, .{ .span = span, .namespace = site.namespace, .scope = .of(scopeFor(snapshot.profile, g, node, site)), .import = isImport(g, node) });
            continue;
        }
        if (oneOf(kind, g.free_kinds)) try pending.append(gpa, node);
    }
    for (pending.items) |node| {
        const namespace = useNamespace(g, node.kind());
        try uses.append(gpa, .{ .span = .{ .start = node.startByte(), .end = node.endByte() }, .namespace = namespace, .binder = lookup(binders.items, node, namespace) });
    }
    const owned_binders = try binders.toOwnedSlice(gpa);
    errdefer gpa.free(owned_binders);
    const owned_uses = try uses.toOwnedSlice(gpa);
    errdefer gpa.free(owned_uses);
    return .{ .binders = owned_binders, .uses = owned_uses, .externals = try externals.toOwnedSlice(gpa) };
}

fn lookup(binders: []const Binder, node: ts.Node, namespace: Namespace) ?usize {
    var current = node.parent();
    while (current) |ancestor| : (current = ancestor.parent()) {
        for (binders, 0..) |b, i| {
            if (b.scope.eql(ancestor) and b.namespace.overlaps(namespace)) return i;
        }
    }
    return null;
}

const testing = std.testing;

fn resolutionOf(runtime: anytype, source: []const u8, name: []const u8) !struct { snapshot: *Snapshot, resolution: Resolution } {
    const snapshot = try test_util.snapshotOf(runtime, source);
    errdefer snapshot.destroy();
    return .{ .snapshot = snapshot, .resolution = try resolveName(testing.allocator, snapshot, name) };
}

fn offset(source: []const u8, needle: []const u8, name: []const u8) Span {
    const at = std.mem.indexOf(u8, source, needle).? + std.mem.indexOf(u8, needle, name).?;
    return .{ .start = @intCast(at), .end = @intCast(at + name.len) };
}

test "scope: a use resolves to the nearest enclosing binder, a shadowing parameter wins inside its function" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const source = "function add(a: number) { return a; }\nfunction g(add: number) { return add; }\nconst r = add(1);\n";
    const r = try resolutionOf(runtime, source, "add");
    defer r.snapshot.destroy();
    defer r.resolution.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), r.resolution.binders.len);
    const outer = r.resolution.binderAt(offset(source, "function add", "add")).?;
    const param = r.resolution.binderAt(offset(source, "g(add", "add")).?;
    try testing.expectEqual(@as(?usize, param), r.resolution.useAt(offset(source, "return add;", "add")).?.binder);
    try testing.expectEqual(@as(?usize, outer), r.resolution.useAt(offset(source, "= add(1)", "add")).?.binder);
}

test "scope: a block-scoped const hides the outer name only inside its block, a var is function-scoped" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const source = "let x = 1;\nfunction f() { { const x = 2; x; } x; { var x = 3; } }\n";
    const r = try resolutionOf(runtime, source, "x");
    defer r.snapshot.destroy();
    defer r.resolution.deinit(testing.allocator);
    const inner = r.resolution.binderAt(offset(source, "const x", "x")).?;
    const hoisted = r.resolution.binderAt(offset(source, "var x", "x")).?;
    try testing.expectEqual(@as(?usize, inner), r.resolution.useAt(offset(source, "x; }", "x")).?.binder);
    try testing.expectEqual(@as(?usize, hoisted), r.resolution.useAt(offset(source, "} x;", "x")).?.binder);
}

test "scope: types and values live in separate namespaces, a class is both" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const source = "type Foo = { a: number };\nconst Foo = { a: 1 };\nfunction f(x: Foo) { return Foo.a + x.a; }\nclass Bar {}\nconst b: Bar = new Bar();\n";
    const r = try resolutionOf(runtime, source, "Foo");
    defer r.snapshot.destroy();
    defer r.resolution.deinit(testing.allocator);
    const alias = r.resolution.binderAt(offset(source, "type Foo", "Foo")).?;
    const value = r.resolution.binderAt(offset(source, "const Foo", "Foo")).?;
    try testing.expectEqual(@as(?usize, alias), r.resolution.useAt(offset(source, "x: Foo", "Foo")).?.binder);
    try testing.expectEqual(@as(?usize, value), r.resolution.useAt(offset(source, "Foo.a", "Foo")).?.binder);

    const c = try resolutionOf(runtime, source, "Bar");
    defer c.snapshot.destroy();
    defer c.resolution.deinit(testing.allocator);
    const class = c.resolution.binderAt(offset(source, "class Bar", "Bar")).?;
    try testing.expectEqual(@as(?usize, class), c.resolution.useAt(offset(source, "b: Bar", "Bar")).?.binder);
    try testing.expectEqual(@as(?usize, class), c.resolution.useAt(offset(source, "new Bar", "Bar")).?.binder);
}

test "scope: an import binds at module level and a name with no binder stays unresolved" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const source = "import { add } from \"./a\";\nexport function g() { return add(1) + other(2); }\n";
    const r = try resolutionOf(runtime, source, "add");
    defer r.snapshot.destroy();
    defer r.resolution.deinit(testing.allocator);
    const imported = r.resolution.binderAt(offset(source, "{ add }", "add")).?;
    try testing.expect(r.resolution.binders[imported].import);
    try testing.expectEqual(@as(?usize, imported), r.resolution.useAt(offset(source, "add(1)", "add")).?.binder);
    const o = try resolutionOf(runtime, source, "other");
    defer o.snapshot.destroy();
    defer o.resolution.deinit(testing.allocator);
    try testing.expectEqual(@as(?usize, null), o.resolution.uses[0].binder);
}

test "scope: an imported or re-exported name of another module is external, a local export is a use" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const source = "import { add as plus } from \"./a\";\nexport { add } from \"./b\";\nexport { plus as add };\n";
    const r = try resolutionOf(runtime, source, "add");
    defer r.snapshot.destroy();
    defer r.resolution.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), r.resolution.externals.len);
    try testing.expectEqual(@as(usize, 0), r.resolution.binders.len);
    try testing.expectEqual(@as(usize, 0), r.resolution.uses.len);
    const p = try resolutionOf(runtime, source, "plus");
    defer p.snapshot.destroy();
    defer p.resolution.deinit(testing.allocator);
    try testing.expectEqual(@as(?usize, 0), p.resolution.useAt(offset(source, "{ plus as add }", "plus")).?.binder);
}
