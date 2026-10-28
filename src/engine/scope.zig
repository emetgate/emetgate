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

const sites = @import("sites.zig");
const oneOf = sites.oneOf;
pub const TreeUp = sites.TreeUp;
pub const PathUp = sites.PathUp;
pub const siteOf = sites.siteOf;
pub const siteIn = sites.siteIn;
pub const isProperty = sites.isProperty;
pub const isPropertyIn = sites.isPropertyIn;
pub const isExternal = sites.isExternal;
pub const externalIn = sites.externalIn;

pub fn useNamespace(g: *const Rename, kind: []const u8) Namespace {
    return if (oneOf(kind, g.type_kinds)) .type else .value;
}

fn rootOf(up: anytype, node: ts.Node) ts.Node {
    var current = node;
    while (up.parent(current)) |parent| current = parent;
    return current;
}

fn blockAbove(g: *const Rename, up: anytype, node: ts.Node) ts.Node {
    var current = up.parent(node);
    while (current) |ancestor| : (current = up.parent(ancestor)) {
        if (oneOf(ancestor.kind(), g.block_scopes)) return ancestor;
    }
    return rootOf(up, node);
}

fn functionAbove(profile: *const Profile, up: anytype, node: ts.Node) ts.Node {
    var current = up.parent(node);
    while (current) |ancestor| : (current = up.parent(ancestor)) {
        if (profile.functionKind(ancestor.kind()) != null) return ancestor;
    }
    return rootOf(up, node);
}

fn declaratorScope(profile: *const Profile, g: *const Rename, up: anytype, declarator: ts.Node) ts.Node {
    const statement = up.parent(declarator) orelse return rootOf(up, declarator);
    if (oneOf(statement.kind(), g.function_scoped_statements)) return functionAbove(profile, up, statement);
    return blockAbove(g, up, declarator);
}

fn patternScope(profile: *const Profile, g: *const Rename, up: anytype, node: ts.Node) ts.Node {
    var current = up.parent(node);
    while (current) |ancestor| : (current = up.parent(ancestor)) {
        const holder = up.parent(ancestor) orelse break;
        if (siteIn(g, up, ancestor)) |site| {
            if (site.scope != .pattern) return scopeFor(profile, g, up, ancestor, site);
        }
        if (std.mem.eql(u8, holder.kind(), profile.declarator)) return declaratorScope(profile, g, up, holder);
    }
    return rootOf(up, node);
}

fn scopeFor(profile: *const Profile, g: *const Rename, up: anytype, node: ts.Node, site: BinderSite) ts.Node {
    const parent = up.parent(node).?;
    return switch (site.scope) {
        .block => blockAbove(g, up, parent),
        .function => functionAbove(profile, up, node),
        .own => parent,
        .owner => up.parent(up.parent(parent) orelse parent) orelse parent,
        .pattern => patternScope(profile, g, up, node),
        .declarator => declaratorScope(profile, g, up, parent),
        .program => rootOf(up, node),
    };
}

fn isImport(g: *const Rename, up: anytype, node: ts.Node) bool {
    const parent = up.parent(node) orelse return false;
    if (!oneOf(parent.kind(), g.import_binders)) return false;
    var current = up.parent(parent);
    while (current) |ancestor| : (current = up.parent(ancestor)) {
        if (oneOf(ancestor.kind(), g.import_statements)) return true;
    }
    return false;
}

pub fn resolveName(gpa: Allocator, snapshot: *const Snapshot, name: []const u8) !Resolution {
    const g = snapshot.profile.rename orelse return error.UnsupportedLanguage;
    const up: TreeUp = .{};
    var binders: std.ArrayList(Binder) = .empty;
    errdefer binders.deinit(gpa);
    var uses: std.ArrayList(Use) = .empty;
    errdefer uses.deinit(gpa);
    var pending: std.ArrayList(ts.Node) = .empty;
    defer pending.deinit(gpa);
    var externals: std.ArrayList(Span) = .empty;
    errdefer externals.deinit(gpa);
    const rebound = try collectRebound(gpa, snapshot, g);
    defer gpa.free(rebound);

    var walker = traversal.Walker.init(snapshot.tree.root());
    defer walker.deinit();
    while (walker.next()) |entry| {
        const node = entry.node;
        const kind = node.kind();
        if (snapshot.profile.opaqueText(node)) {
            walker.skipChildren();
            continue;
        }
        if (node.childCount() != 0) continue;
        if (!std.mem.eql(u8, snapshot.source[node.startByte()..node.endByte()], name)) continue;
        const span: Span = .{ .start = node.startByte(), .end = node.endByte() };
        if (externalIn(g, up, node)) {
            try externals.append(gpa, span);
            continue;
        }
        if (siteIn(g, up, node)) |site| {
            const scope_node = scopeFor(snapshot.profile, g, up, node, site);
            if (!isRebound(rebound, scope_node, name)) {
                try binders.append(gpa, .{ .span = span, .namespace = site.namespace, .scope = .of(scope_node), .import = isImport(g, up, node) });
                continue;
            }
        } else if (isPropertyIn(g, up, node)) continue;
        if (oneOf(kind, g.free_kinds)) try pending.append(gpa, node);
    }
    for (pending.items) |node| {
        const namespace = useNamespace(g, node.kind());
        try uses.append(gpa, .{ .span = .{ .start = node.startByte(), .end = node.endByte() }, .namespace = namespace, .binder = lookup(g, binders.items, up, node, namespace) });
    }
    const owned_binders = try binders.toOwnedSlice(gpa);
    errdefer gpa.free(owned_binders);
    const owned_uses = try uses.toOwnedSlice(gpa);
    errdefer gpa.free(owned_uses);
    return .{ .binders = owned_binders, .uses = owned_uses, .externals = try externals.toOwnedSlice(gpa) };
}

fn lookup(g: *const Rename, binders: []const Binder, up: anytype, node: ts.Node, namespace: Namespace) ?usize {
    var from = node;
    var crossed = false;
    var current = up.parent(node);
    while (current) |ancestor| : ({
        from = ancestor;
        current = up.parent(ancestor);
    }) {
        if (!inScopeBody(g, ancestor, from)) continue;
        const class_scope = oneOf(ancestor.kind(), g.class_scopes);
        if (!class_scope or !crossed) {
            for (binders, 0..) |b, i| {
                if (b.scope.eql(ancestor) and b.namespace.overlaps(namespace)) return i;
            }
        }
        if (!class_scope and oneOf(ancestor.kind(), g.block_scopes)) crossed = true;
    }
    return null;
}

fn inScopeBody(g: *const Rename, scope_node: ts.Node, from: ts.Node) bool {
    for (g.scope_bodies) |site| {
        if (!std.mem.eql(u8, site.parent, scope_node.kind())) continue;
        const body = scope_node.childByField(site.field) orelse return false;
        return body.eql(from);
    }
    return true;
}

const Rebound = struct { scope: Region, name: []const u8 };

fn collectRebound(gpa: Allocator, snapshot: *const Snapshot, g: *const Rename) ![]Rebound {
    if (g.rebinding_statements.len == 0) return &.{};
    var out: std.ArrayList(Rebound) = .empty;
    errdefer out.deinit(gpa);
    var walker = traversal.Walker.init(snapshot.tree.root());
    defer walker.deinit();
    while (walker.next()) |entry| {
        const node = entry.node;
        if (!oneOf(node.kind(), g.rebinding_statements)) continue;
        const scope_node = blockAbove(g, TreeUp{}, node);
        var i: u32 = 0;
        while (node.namedChild(i)) |child| : (i += 1) {
            try out.append(gpa, .{ .scope = .of(scope_node), .name = snapshot.source[child.startByte()..child.endByte()] });
        }
    }
    return out.toOwnedSlice(gpa);
}

fn isRebound(rebound: []const Rebound, scope_node: ts.Node, name: []const u8) bool {
    for (rebound) |r| {
        if (r.scope.eql(scope_node) and std.mem.eql(u8, r.name, name)) return true;
    }
    return false;
}

pub const NamedSpan = struct {
    name: []const u8,
    span: Span,
};

pub const Every = struct {
    binders: []Binder,
    binder_names: [][]const u8,
    uses: []Use,
    use_names: [][]const u8,
    externals: []NamedSpan,

    pub fn deinit(self: Every, gpa: Allocator) void {
        gpa.free(self.binders);
        gpa.free(self.binder_names);
        gpa.free(self.uses);
        gpa.free(self.use_names);
        gpa.free(self.externals);
    }
};

const Group = struct { start: u32, len: u32 };

const Pass = struct {
    walker: traversal.Walker,
    path: std.ArrayList(ts.Node) = .empty,

    fn init(root: ts.Node) Pass {
        return .{ .walker = traversal.Walker.init(root) };
    }

    fn deinit(self: *Pass, gpa: Allocator) void {
        self.walker.deinit();
        self.path.deinit(gpa);
    }

    fn nextLeaf(self: *Pass, gpa: Allocator, snapshot: *const Snapshot, g: *const Rename) !?ts.Node {
        while (self.walker.next()) |entry| {
            self.path.shrinkRetainingCapacity(entry.depth);
            const node = entry.node;
            const kind = node.kind();
            if (snapshot.profile.opaqueText(node)) {
                self.walker.skipChildren();
                continue;
            }
            if (node.childCount() != 0) {
                try self.path.append(gpa, node);
                continue;
            }
            if (oneOf(kind, g.name_kinds)) return node;
        }
        return null;
    }

    fn up(self: *const Pass, leaf: ts.Node) PathUp {
        return .{ .path = self.path.items, .leaf = leaf };
    }
};

const PendingBinder = struct { name: []const u8, binder: Binder, order: u32 };

fn pendingLess(_: void, a: PendingBinder, b: PendingBinder) bool {
    const order = std.mem.order(u8, a.name, b.name);
    if (order != .eq) return order == .lt;
    return a.order < b.order;
}

pub fn resolveAll(gpa: Allocator, snapshot: *const Snapshot) !Every {
    const g = snapshot.profile.rename orelse return error.UnsupportedLanguage;
    var pending: std.ArrayList(PendingBinder) = .empty;
    defer pending.deinit(gpa);
    var uses: std.ArrayList(Use) = .empty;
    defer uses.deinit(gpa);
    var use_names: std.ArrayList([]const u8) = .empty;
    defer use_names.deinit(gpa);
    var externals: std.ArrayList(NamedSpan) = .empty;
    defer externals.deinit(gpa);
    const rebound = try collectRebound(gpa, snapshot, g);
    defer gpa.free(rebound);

    {
        var pass: Pass = .init(snapshot.tree.root());
        defer pass.deinit(gpa);
        while (try pass.nextLeaf(gpa, snapshot, g)) |node| {
            const up = pass.up(node);
            const span: Span = .{ .start = node.startByte(), .end = node.endByte() };
            const name = snapshot.source[span.start..span.end];
            if (externalIn(g, up, node)) {
                try externals.append(gpa, .{ .name = name, .span = span });
                continue;
            }
            if (siteIn(g, up, node)) |site| {
                const scope_node = scopeFor(snapshot.profile, g, up, node, site);
                if (!isRebound(rebound, scope_node, name)) {
                    const binder: Binder = .{ .span = span, .namespace = site.namespace, .scope = .of(scope_node), .import = isImport(g, up, node) };
                    try pending.append(gpa, .{ .name = name, .binder = binder, .order = @intCast(pending.items.len) });
                    continue;
                }
            } else if (isPropertyIn(g, up, node)) continue;
            if (!oneOf(node.kind(), g.free_kinds)) continue;
            try uses.append(gpa, .{ .span = span, .namespace = useNamespace(g, node.kind()), .binder = null });
            try use_names.append(gpa, name);
        }
    }

    std.mem.sort(PendingBinder, pending.items, {}, pendingLess);
    const binders = try gpa.alloc(Binder, pending.items.len);
    errdefer gpa.free(binders);
    const binder_names = try gpa.alloc([]const u8, pending.items.len);
    errdefer gpa.free(binder_names);
    var groups: std.StringHashMapUnmanaged(Group) = .empty;
    defer groups.deinit(gpa);
    for (pending.items, 0..) |p, i| {
        binders[i] = p.binder;
        binder_names[i] = p.name;
        const slot = try groups.getOrPut(gpa, p.name);
        if (!slot.found_existing) slot.value_ptr.* = .{ .start = @intCast(i), .len = 0 };
        slot.value_ptr.len += 1;
    }

    if (uses.items.len != 0) {
        var pass: Pass = .init(snapshot.tree.root());
        defer pass.deinit(gpa);
        var next: usize = 0;
        while (next < uses.items.len) {
            const node = (try pass.nextLeaf(gpa, snapshot, g)) orelse return error.UseNotRevisited;
            const use = &uses.items[next];
            if (node.startByte() != use.span.start or node.endByte() != use.span.end) continue;
            const name = use_names.items[next];
            next += 1;
            const group = groups.get(name) orelse continue;
            const slice = binders[group.start .. group.start + group.len];
            if (lookup(g, slice, pass.up(node), node, use.namespace)) |at| use.binder = group.start + at;
        }
    }

    const owned_uses = try uses.toOwnedSlice(gpa);
    errdefer gpa.free(owned_uses);
    const owned_use_names = try use_names.toOwnedSlice(gpa);
    errdefer gpa.free(owned_use_names);
    return .{ .binders = binders, .binder_names = binder_names, .uses = owned_uses, .use_names = owned_use_names, .externals = try externals.toOwnedSlice(gpa) };
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

fn expectSameAsEachName(runtime: anytype, source: []const u8) !void {
    const snapshot = try test_util.snapshotOf(runtime, source);
    defer snapshot.destroy();
    const every = try resolveAll(testing.allocator, snapshot);
    defer every.deinit(testing.allocator);
    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer names.deinit(testing.allocator);
    for (every.binder_names) |name| try names.put(testing.allocator, name, {});
    for (every.use_names) |name| try names.put(testing.allocator, name, {});
    var it = names.keyIterator();
    while (it.next()) |name| {
        const alone = try resolveName(testing.allocator, snapshot, name.*);
        defer alone.deinit(testing.allocator);
        var binders: usize = 0;
        for (every.binders, every.binder_names) |b, n| {
            if (!std.mem.eql(u8, n, name.*)) continue;
            binders += 1;
            const i = alone.binderAt(b.span) orelse return error.BinderMissing;
            try testing.expect(alone.binders[i].scope.same(b.scope));
            try testing.expectEqual(alone.binders[i].import, b.import);
        }
        try testing.expectEqual(alone.binders.len, binders);
        var uses: usize = 0;
        for (every.uses, every.use_names) |u, n| {
            if (!std.mem.eql(u8, n, name.*)) continue;
            uses += 1;
            const lone = alone.useAt(u.span) orelse return error.UseMissing;
            const want: ?Span = if (lone.binder) |i| alone.binders[i].span else null;
            const got: ?Span = if (u.binder) |i| every.binders[i].span else null;
            try testing.expectEqual(want, got);
        }
        try testing.expectEqual(alone.uses.len, uses);
    }
}

test "scope: resolving every name in one walk agrees with resolving each name alone" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    try expectSameAsEachName(runtime, "function add(a: number) { return a; }\nfunction g(add: number) { return add; }\nconst r = add(1);\n");
    try expectSameAsEachName(runtime, "let x = 1;\nfunction f() { { const x = 2; x; } x; { var x = 3; } }\n");
    try expectSameAsEachName(runtime, "type Foo = { a: number };\nconst Foo = { a: 1 };\nfunction f(x: Foo) { return Foo.a + x.a; }\nclass Bar {}\nconst b: Bar = new Bar();\n");
    try expectSameAsEachName(runtime, "import { add as plus } from \"./a\";\nexport { add } from \"./b\";\nexport { plus as add };\nfunction h<T>(v: T): T { try { return v; } catch (e) { return e as T; } }\nfor (const [k, { v = 1 }] of []) { k; v; }\n");
}

test "scope: a destructured shorthand binds its own name, so a use inside its block does not reach the outer function" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const source = "function process() { return 1; }\nfunction run(args: any) { const { process } = args; return process(); }\nfunction other({ process = 2 }: any) { return process; }\n";
    const r = try resolutionOf(runtime, source, "process");
    defer r.snapshot.destroy();
    defer r.resolution.deinit(testing.allocator);
    const outer = r.resolution.binderAt(offset(source, "function process", "process")).?;
    const local = r.resolution.binderAt(offset(source, "{ process }", "process")).?;
    const defaulted = r.resolution.binderAt(offset(source, "{ process = 2 }", "process")).?;
    try testing.expectEqual(@as(?usize, local), r.resolution.useAt(offset(source, "return process()", "process")).?.binder);
    try testing.expectEqual(@as(?usize, defaulted), r.resolution.useAt(offset(source, "return process; }", "process")).?.binder);
    try testing.expect(outer != local);
    try expectSameAsEachName(runtime, source);
}
