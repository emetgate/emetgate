const std = @import("std");
const ts = @import("tree_sitter.zig");
const symbol = @import("symbol.zig");
const scope = @import("scope.zig");
const symmetry = @import("symmetry.zig");
const profile_mod = @import("lang/profile.zig");
const Snapshot = @import("loader.zig").Snapshot;
const test_util = @import("test_util.zig");

const Allocator = std.mem.Allocator;
const Span = symbol.Span;
const Modules = profile_mod.Modules;
const Namespace = profile_mod.Namespace;

pub const Named = struct {
    name: []const u8,
    alias: ?[]const u8,
    span: Span,
    type_only: bool,

    pub fn local(self: Named) []const u8 {
        return self.alias orelse self.name;
    }
};

pub const Form = enum { import, reexport, star_reexport, bare };

pub const Import = struct {
    statement: Span,
    spec: []const u8,
    form: Form,
    type_only: bool,
    default_name: ?[]const u8 = null,
    namespace: ?[]const u8 = null,
    named: []const Named = &.{},
};

fn oneOf(kind: []const u8, kinds: []const []const u8) bool {
    for (kinds) |candidate| {
        if (std.mem.eql(u8, candidate, kind)) return true;
    }
    return false;
}

fn span(node: ts.Node) Span {
    return .{ .start = node.startByte(), .end = node.endByte() };
}

fn unquoted(text: []const u8) []const u8 {
    if (text.len < 2) return text;
    return text[1 .. text.len - 1];
}

fn hasToken(node: ts.Node, tokens: []const []const u8) bool {
    var i: u32 = 0;
    while (node.child(i)) |child| : (i += 1) {
        if (!child.isNamed() and oneOf(child.kind(), tokens)) return true;
    }
    return false;
}

pub fn exportsDefault(snapshot: *const Snapshot, statement: ts.Node) bool {
    const m = snapshot.profile.modules orelse return false;
    var node = statement;
    if (node.parent()) |parent| {
        if (std.mem.eql(u8, parent.kind(), m.export_statement)) node = parent;
    }
    if (!std.mem.eql(u8, node.kind(), m.export_statement)) return false;
    return hasToken(node, &.{m.default_keyword});
}

fn namedList(arena: Allocator, snapshot: *const Snapshot, m: *const Modules, list: ts.Node, item_kind: []const u8) ![]const Named {
    var out: std.ArrayList(Named) = .empty;
    var i: u32 = 0;
    while (list.namedChild(i)) |item| : (i += 1) {
        if (!std.mem.eql(u8, item.kind(), item_kind)) continue;
        const name = item.childByField(m.name_field) orelse continue;
        const alias: ?[]const u8 = if (item.childByField(m.alias_field)) |a| snapshot.tree.text(a) else null;
        try out.append(arena, .{ .name = snapshot.tree.text(name), .alias = alias, .span = span(item), .type_only = hasToken(item, m.type_keywords) });
    }
    return out.items;
}

pub fn imports(arena: Allocator, snapshot: *const Snapshot) ![]Import {
    const m = snapshot.profile.modules orelse return error.UnsupportedLanguage;
    var out: std.ArrayList(Import) = .empty;
    const root = snapshot.tree.root();
    var i: u32 = 0;
    while (root.namedChild(i)) |statement| : (i += 1) {
        const kind = statement.kind();
        const source = statement.childByField(m.source_field) orelse continue;
        const spec = unquoted(snapshot.tree.text(source));
        if (std.mem.eql(u8, kind, m.import_statement)) {
            var entry: Import = .{ .statement = span(statement), .spec = spec, .form = .bare, .type_only = hasToken(statement, m.type_keywords) };
            var j: u32 = 0;
            while (statement.namedChild(j)) |clause| : (j += 1) {
                if (!std.mem.eql(u8, clause.kind(), m.import_clause)) continue;
                entry.form = .import;
                var k: u32 = 0;
                while (clause.namedChild(k)) |part| : (k += 1) {
                    if (std.mem.eql(u8, part.kind(), m.named_imports)) {
                        entry.named = try namedList(arena, snapshot, m, part, m.import_specifier);
                    } else if (std.mem.eql(u8, part.kind(), m.namespace_import)) {
                        const name = part.namedChild(0) orelse continue;
                        entry.namespace = snapshot.tree.text(name);
                    } else {
                        entry.default_name = snapshot.tree.text(part);
                    }
                }
            }
            try out.append(arena, entry);
        } else if (std.mem.eql(u8, kind, m.export_statement)) {
            var entry: Import = .{ .statement = span(statement), .spec = spec, .form = .star_reexport, .type_only = hasToken(statement, m.type_keywords) };
            var j: u32 = 0;
            while (statement.namedChild(j)) |clause| : (j += 1) {
                if (!std.mem.eql(u8, clause.kind(), m.export_clause)) continue;
                entry.form = .reexport;
                entry.named = try namedList(arena, snapshot, m, clause, m.export_specifier);
            }
            try out.append(arena, entry);
        }
    }
    return out.items;
}

pub fn hasModuleEffects(snapshot: *const Snapshot) bool {
    const root = snapshot.tree.root();
    var i: u32 = 0;
    while (root.namedChild(i)) |statement| : (i += 1) {
        if (snapshot.profile.isComment(statement.kind())) continue;
        if (symmetry.statementHasEffect(snapshot.profile, statement)) return true;
    }
    return false;
}

pub const Free = struct {
    name: []const u8,
    namespace: Namespace,
    import: bool,
    binder: ?Span,
};

fn contains(region: Span, inner: Span) bool {
    return inner.start >= region.start and inner.end <= region.end;
}

pub fn freeNames(arena: Allocator, snapshot: *const Snapshot, region: Span) ![]Free {
    const g = snapshot.profile.rename orelse return error.UnsupportedLanguage;
    var names: std.StringArrayHashMapUnmanaged(void) = .empty;
    const root = snapshot.tree.root();
    var stack: std.ArrayList(ts.Node) = .empty;
    try stack.append(arena, root);
    while (stack.pop()) |node| {
        if (node.endByte() <= region.start or node.startByte() >= region.end) continue;
        if (snapshot.profile.isComment(node.kind()) or oneOf(node.kind(), snapshot.profile.strings)) continue;
        if (node.childCount() == 0) {
            if (oneOf(node.kind(), g.free_kinds) and scope.siteOf(g, node) == null) try names.put(arena, snapshot.tree.text(node), {});
            continue;
        }
        var i: u32 = 0;
        while (node.child(i)) |child| : (i += 1) try stack.append(arena, child);
    }
    var out: std.ArrayList(Free) = .empty;
    for (names.keys()) |name| {
        const resolution = try scope.resolveName(arena, snapshot, name);
        var seen_value = false;
        var seen_type = false;
        for (resolution.uses) |use| {
            if (!contains(region, use.span)) continue;
            const index = use.binder orelse {
                try appendOnce(arena, &out, &seen_value, &seen_type, .{ .name = name, .namespace = use.namespace, .import = false, .binder = null });
                continue;
            };
            const binder = resolution.binders[index];
            if (contains(region, binder.span)) continue;
            try appendOnce(arena, &out, &seen_value, &seen_type, .{ .name = name, .namespace = use.namespace, .import = binder.import, .binder = binder.span });
        }
    }
    return out.items;
}

fn appendOnce(arena: Allocator, out: *std.ArrayList(Free), seen_value: *bool, seen_type: *bool, free: Free) !void {
    const seen = if (free.namespace == .type) seen_type else seen_value;
    if (seen.*) return;
    seen.* = true;
    try out.append(arena, free);
}

const testing = std.testing;

test "modules: named, aliased, default, namespace, type-only, bare and re-export forms are read" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const source = "import { a, b as c } from \"./x\";\nimport d, * as ns from \"lib\";\nimport type { T } from \"./t\";\nimport \"./side\";\nexport { e } from \"./y\";\nexport * from \"./z\";\nexport function f() { return 1; }\n";
    const snapshot = try test_util.snapshotOf(runtime, source);
    defer snapshot.destroy();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const found = try imports(arena_state.allocator(), snapshot);
    try testing.expectEqual(@as(usize, 6), found.len);
    try testing.expectEqualStrings("./x", found[0].spec);
    try testing.expectEqual(Form.import, found[0].form);
    try testing.expectEqual(@as(usize, 2), found[0].named.len);
    try testing.expectEqualStrings("c", found[0].named[1].local());
    try testing.expectEqualStrings("d", found[1].default_name.?);
    try testing.expectEqualStrings("ns", found[1].namespace.?);
    try testing.expect(found[2].type_only);
    try testing.expectEqual(Form.bare, found[3].form);
    try testing.expectEqual(Form.reexport, found[4].form);
    try testing.expectEqualStrings("e", found[4].named[0].name);
    try testing.expectEqual(Form.star_reexport, found[5].form);
}

test "modules: a call or an expression at module level is an effect, declarations and imports are not" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const quiet = try test_util.snapshotOf(runtime, "import { a } from \"./a\";\nexport function f() { return a(); }\nexport const x = 1;\nexport class C { m() { return 2; } }\n");
    defer quiet.destroy();
    try testing.expect(!hasModuleEffects(quiet));
    const loud = try test_util.snapshotOf(runtime, "export const x = start();\n");
    defer loud.destroy();
    try testing.expect(hasModuleEffects(loud));
    const statement = try test_util.snapshotOf(runtime, "console.log(1);\n");
    defer statement.destroy();
    try testing.expect(hasModuleEffects(statement));
}

test "modules: the free names of a declaration are its imports, other declarations and globals, not its locals" {
    const runtime = try test_util.openRuntime();
    defer test_util.closeRuntime(runtime);
    const source = "import { helper } from \"./h\";\ntype Id = string;\nconst limit = 3;\nexport function f(x: Id): number { const y = helper(x); return y + limit + Math.max(1, 2); }\n";
    const snapshot = try test_util.snapshotOf(runtime, source);
    defer snapshot.destroy();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const start: u32 = @intCast(std.mem.indexOf(u8, source, "export function").?);
    const free = try freeNames(arena_state.allocator(), snapshot, .{ .start = start, .end = @intCast(source.len) });
    try testing.expectEqual(@as(usize, 4), free.len);
    for (free) |f| {
        if (std.mem.eql(u8, f.name, "helper")) try testing.expect(f.import);
        if (std.mem.eql(u8, f.name, "Id")) try testing.expectEqual(Namespace.type, f.namespace);
        if (std.mem.eql(u8, f.name, "limit")) try testing.expect(!f.import and f.binder != null);
        if (std.mem.eql(u8, f.name, "Math")) try testing.expect(f.binder == null);
    }
}
