const std = @import("std");
const ts = @import("../engine/tree_sitter.zig");
const symbol = @import("../engine/symbol.zig");
const scope = @import("../engine/scope.zig");
const modules = @import("../engine/modules.zig");
const facts = @import("../engine/facts.zig");
const repo = @import("repo.zig");
const tsserver = @import("tsserver.zig");
const py = @import("py_modules.zig");
const Snapshot = @import("../engine/loader.zig").Snapshot;

const Allocator = std.mem.Allocator;
const Import = modules.Import;
const Span = symbol.Span;

pub const Cx = py.Cx;
pub const TextEdit = py.TextEdit;

pub const Unit = struct {
    abs: []const u8,
    snapshot: *Snapshot,
    usings: []const Import,
    declared: []const facts.Declared,
};

pub fn unitOf(arena: Allocator, abs: []const u8, snapshot: *Snapshot) !Unit {
    const found = try modules.csharpModule(arena, snapshot);
    return .{ .abs = abs, .snapshot = snapshot, .usings = found.imports, .declared = found.declared };
}

pub fn tracked(cx: Cx) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const listing = try repo.trackedListing(cx.arena, cx.io, cx.root, "*.cs");
    var files = std.mem.tokenizeScalar(u8, listing, 0);
    while (files.next()) |rel| {
        const abs = try std.fmt.allocPrint(cx.arena, "{s}\\{s}", .{ cx.root, rel });
        std.mem.replaceScalar(u8, abs, '/', '\\');
        try out.append(cx.arena, abs);
    }
    return out.items;
}

pub fn loadUnits(cx: Cx, known: []const Unit, opened: *std.ArrayList(*Snapshot), words: []const []const u8) ![]Unit {
    var out: std.ArrayList(Unit) = .empty;
    try out.appendSlice(cx.arena, known);
    for (try tracked(cx)) |abs| {
        var have = false;
        for (known) |unit| {
            if (tsserver.sameFile(unit.abs, abs)) have = true;
        }
        if (have) continue;
        const snapshot = py.load(cx, abs, null) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        try opened.append(cx.arena, snapshot);
        if (snapshot.tree.root().hasError()) {
            for (words) |word| {
                if (std.mem.indexOf(u8, snapshot.source, word) != null) return error.SourceHasErrors;
            }
            continue;
        }
        try out.append(cx.arena, try unitOf(cx.arena, abs, snapshot));
    }
    return out.items;
}

const Names = std.StringHashMapUnmanaged(usize);

pub const Index = struct {
    arena: Allocator,
    units: []const Unit,
    types: std.StringHashMapUnmanaged(Names) = .empty,
    namespaces: std.StringHashMapUnmanaged(void) = .empty,
    globals: std.ArrayList([]const u8) = .empty,

    pub fn init(arena: Allocator, units: []const Unit) !Index {
        var self: Index = .{ .arena = arena, .units = units };
        for (units) |unit| {
            for (unit.declared) |d| {
                var prefix = d.namespace;
                while (prefix.len != 0) : (prefix = parentOf(prefix)) try self.namespaces.put(arena, prefix, {});
                if (d.name.len == 0 or std.mem.indexOfScalar(u8, d.name, '.') != null) continue;
                const slot = try self.types.getOrPutValue(arena, d.namespace, .empty);
                const count = try slot.value_ptr.getOrPutValue(arena, d.name, 0);
                count.value_ptr.* += 1;
            }
        }
        for (units) |unit| {
            for (unit.usings) |entry| {
                if (entry.global and entry.spec_kind == .using) try self.globals.append(arena, try self.usingNamespace(entry));
            }
        }
        return self;
    }

    pub fn hasType(self: *const Index, namespace: []const u8, name: []const u8) bool {
        const names = self.types.get(namespace) orelse return false;
        return names.contains(name);
    }

    pub fn typeNames(self: *const Index, namespace: []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        const names = self.types.get(namespace) orelse return out.items;
        var it = names.keyIterator();
        while (it.next()) |key| try out.append(self.arena, key.*);
        return out.items;
    }

    pub fn usingNamespace(self: *const Index, entry: Import) ![]const u8 {
        const spec = try clean(self.arena, entry.spec);
        var enclosing = entry.spec_scope;
        while (enclosing.len != 0) : (enclosing = parentOf(enclosing)) {
            const joined = try join(self.arena, enclosing, spec);
            if (self.namespaces.contains(joined)) return joined;
        }
        return spec;
    }
};

pub fn parentOf(namespace: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, namespace, '.') orelse return "";
    return namespace[0..dot];
}

pub fn join(arena: Allocator, a: []const u8, b: []const u8) ![]const u8 {
    if (a.len == 0) return b;
    if (b.len == 0) return a;
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ a, b });
}

pub fn clean(arena: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |byte| {
        if (!std.ascii.isWhitespace(byte)) try out.append(arena, byte);
    }
    const whole = out.items;
    if (std.mem.startsWith(u8, whole, "global::")) return whole["global::".len..];
    return whole;
}

pub fn scopesAt(arena: Allocator, unit: Unit, node: ts.Node) ![]const []const u8 {
    const tree = &unit.snapshot.tree;
    var parts: std.ArrayList([]const u8) = .empty;
    var up: ?ts.Node = node;
    while (up) |current| : (up = current.parent()) {
        if (!std.mem.eql(u8, current.kind(), "namespace_declaration")) continue;
        const name = current.childByField("name") orelse continue;
        try parts.insert(arena, 0, try clean(arena, tree.text(name)));
    }
    const root = tree.root();
    var i: u32 = 0;
    while (root.namedChild(i)) |child| : (i += 1) {
        if (!std.mem.eql(u8, child.kind(), "file_scoped_namespace_declaration")) continue;
        if (child.startByte() > node.startByte()) continue;
        const name = child.childByField("name") orelse continue;
        try parts.insert(arena, 0, try clean(arena, tree.text(name)));
    }
    var full: []const u8 = "";
    for (parts.items) |part| full = try join(arena, full, part);
    return chainOf(arena, full);
}

pub fn chainOf(arena: Allocator, namespace: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var current = namespace;
    while (current.len != 0) : (current = parentOf(current)) try out.append(arena, current);
    try out.append(arena, "");
    return out.items;
}

pub const Found = union(enum) {
    none,
    ns: []const u8,
    other,
    ambiguous,

    fn eql(a: Found, b: Found) bool {
        return switch (a) {
            .ns => |x| b == .ns and std.mem.eql(u8, x, b.ns),
            .none => b == .none,
            .other => b == .other,
            .ambiguous => b == .ambiguous,
        };
    }
};

pub fn lookup(index: *const Index, unit: Unit, scopes: []const []const u8, name: []const u8) !Found {
    for (scopes) |current| {
        if (index.hasType(current, name)) return .{ .ns = current };
        var found: ?[]const u8 = null;
        for (unit.usings) |entry| {
            if (!std.mem.eql(u8, entry.spec_scope, current)) continue;
            if (entry.spec_kind == .using_alias and std.mem.eql(u8, entry.namespace orelse "", name)) return .other;
            if (entry.spec_kind != .using) continue;
            const namespace = try index.usingNamespace(entry);
            if (!index.hasType(namespace, name)) continue;
            if (found) |seen| {
                if (!std.mem.eql(u8, seen, namespace)) return .ambiguous;
            }
            found = namespace;
        }
        if (current.len == 0) {
            for (index.globals.items) |namespace| {
                if (!index.hasType(namespace, name)) continue;
                if (found) |seen| {
                    if (!std.mem.eql(u8, seen, namespace)) return .ambiguous;
                }
                found = namespace;
            }
        }
        if (found) |namespace| return .{ .ns = namespace };
    }
    return .none;
}

pub fn visible(index: *const Index, unit: Unit, scopes: []const []const u8, namespace: []const u8, also_global: bool) !bool {
    for (scopes) |current| {
        if (std.mem.eql(u8, current, namespace)) return true;
    }
    if (also_global) return true;
    for (index.globals.items) |other| {
        if (std.mem.eql(u8, other, namespace)) return true;
    }
    for (unit.usings) |entry| {
        if (entry.spec_kind != .using) continue;
        for (scopes) |current| {
            if (!std.mem.eql(u8, entry.spec_scope, current)) continue;
            if (std.mem.eql(u8, try index.usingNamespace(entry), namespace)) return true;
        }
    }
    return false;
}

fn isPlainUsing(unit: Unit, node: ts.Node) bool {
    for (unit.usings) |entry| {
        if (entry.statement.start == node.startByte()) return entry.spec_kind == .using;
    }
    return false;
}

pub fn rightName(node: ts.Node) ?ts.Node {
    const name = node.childByField("name") orelse return null;
    if (std.mem.eql(u8, name.kind(), "generic_name")) return name.namedChild(0);
    return name;
}

fn isQualifier(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "qualified_name") or std.mem.eql(u8, kind, "member_access_expression") or std.mem.eql(u8, kind, "member_binding_expression") or std.mem.eql(u8, kind, "alias_qualified_name");
}

pub fn isQualifiedRight(node: ts.Node) bool {
    var current = node;
    var up = node.parent() orelse return false;
    if (std.mem.eql(u8, up.kind(), "generic_name")) {
        current = up;
        up = up.parent() orelse return false;
    }
    if (!isQualifier(up.kind())) return false;
    const name = up.childByField("name") orelse return false;
    return name.eql(current);
}

fn attributeName(arena: Allocator, node: ts.Node, text: []const u8) !?[]const u8 {
    var up = node.parent() orelse return null;
    if (isQualifier(up.kind())) up = up.parent() orelse return null;
    if (!std.mem.eql(u8, up.kind(), "attribute")) return null;
    return try std.fmt.allocPrint(arena, "{s}Attribute", .{text});
}

fn walkChildren(arena: Allocator, stack: *std.ArrayList(ts.Node), node: ts.Node) !void {
    var i = node.childCount();
    while (i != 0) {
        i -= 1;
        try stack.append(arena, node.child(i).?);
    }
}

pub const Mention = struct {
    node: ts.Node,
    name: []const u8,
};

fn wanted(names: ?[]const []const u8, name: []const u8) bool {
    const list = names orelse return true;
    for (list) |other| {
        if (std.mem.eql(u8, other, name)) return true;
    }
    return false;
}

pub fn mentions(arena: Allocator, unit: Unit, names: ?[]const []const u8) ![]Mention {
    const tree = &unit.snapshot.tree;
    const g = unit.snapshot.profile.rename.?;
    var out: std.ArrayList(Mention) = .empty;
    var stack: std.ArrayList(ts.Node) = .empty;
    try stack.append(arena, tree.root());
    while (stack.pop()) |node| {
        const kind = node.kind();
        if (std.mem.eql(u8, kind, "using_directive") and isPlainUsing(unit, node)) continue;
        if (std.mem.eql(u8, kind, "identifier")) {
            if (isQualifiedRight(node) or scope.siteOf(g, node) != null) continue;
            const text = tree.text(node);
            if (try attributeName(arena, node, text)) |long| {
                if (wanted(names, long)) try out.append(arena, .{ .node = node, .name = long });
            }
            if (wanted(names, text)) try out.append(arena, .{ .node = node, .name = text });
            continue;
        }
        if (std.mem.eql(u8, kind, "namespace_declaration") or std.mem.eql(u8, kind, "file_scoped_namespace_declaration")) {
            const name = node.childByField("name");
            var i = node.childCount();
            while (i != 0) {
                i -= 1;
                const child = node.child(i).?;
                if (name != null and child.eql(name.?)) continue;
                try stack.append(arena, child);
            }
            continue;
        }
        try walkChildren(arena, &stack, node);
    }
    return out.items;
}

pub const Qualified = struct {
    qualifier: ts.Node,
    name: []const u8,
    global: bool,
};

fn firstIdentifier(node: ts.Node) ts.Node {
    var current = node;
    while (true) {
        const kind = current.kind();
        if (std.mem.eql(u8, kind, "qualified_name")) {
            current = current.childByField("qualifier") orelse return current;
        } else if (std.mem.eql(u8, kind, "member_access_expression")) {
            current = current.childByField("expression") orelse return current;
        } else if (std.mem.eql(u8, kind, "alias_qualified_name")) {
            current = current.childByField("name") orelse return current;
        } else return current;
    }
}

fn boundLocally(arena: Allocator, unit: Unit, identifier: ts.Node) !bool {
    if (!std.mem.eql(u8, identifier.kind(), "identifier")) return false;
    const resolution = try scope.resolveName(arena, unit.snapshot, unit.snapshot.tree.text(identifier));
    const use = resolution.useAt(.{ .start = identifier.startByte(), .end = identifier.endByte() }) orelse return false;
    const binder = use.binder orelse return false;
    const root = unit.snapshot.tree.root();
    const b = resolution.binders[binder].scope;
    return b.start != root.startByte() or b.end != root.endByte();
}

pub fn qualifiedTo(arena: Allocator, index: *const Index, unit: Unit, namespace: []const u8, names: []const []const u8) ![]Qualified {
    const tree = &unit.snapshot.tree;
    var out: std.ArrayList(Qualified) = .empty;
    var stack: std.ArrayList(ts.Node) = .empty;
    try stack.append(arena, tree.root());
    while (stack.pop()) |node| {
        const kind = node.kind();
        if (std.mem.eql(u8, kind, "using_directive") and isPlainUsing(unit, node)) continue;
        if (std.mem.eql(u8, kind, "namespace_declaration") or std.mem.eql(u8, kind, "file_scoped_namespace_declaration")) {
            const name = node.childByField("name");
            var i = node.childCount();
            while (i != 0) {
                i -= 1;
                const child = node.child(i).?;
                if (name != null and child.eql(name.?)) continue;
                try stack.append(arena, child);
            }
            continue;
        }
        try walkChildren(arena, &stack, node);
        if (std.mem.eql(u8, kind, "alias_qualified_name")) {
            const alias = node.childByField("alias") orelse continue;
            const alias_text = tree.text(alias);
            if (std.mem.eql(u8, alias_text, "global")) continue;
            const right = rightName(node) orelse continue;
            if (!wanted(names, tree.text(right))) continue;
            for (unit.usings) |entry| {
                if (entry.spec_kind != .using_alias or !std.mem.eql(u8, entry.namespace orelse "", alias_text)) continue;
                if (std.mem.eql(u8, try index.usingNamespace(entry), namespace)) return error.CsNamespaceAlias;
            }
            continue;
        }
        if (!std.mem.eql(u8, kind, "qualified_name") and !std.mem.eql(u8, kind, "member_access_expression")) continue;
        const right = rightName(node) orelse continue;
        var name = tree.text(right);
        if (!wanted(names, name)) {
            const long = (try attributeName(arena, right, name)) orelse continue;
            if (!wanted(names, long)) continue;
            name = long;
        }
        const left = node.childByField("qualifier") orelse node.childByField("expression") orelse continue;
        const raw = tree.text(left);
        const text = try clean(arena, raw);
        const first = firstIdentifier(left);
        const first_text = tree.text(first);
        for (unit.usings) |entry| {
            if (entry.spec_kind != .using_alias or !std.mem.eql(u8, entry.namespace orelse "", first_text)) continue;
            const rest = text[@min(text.len, first_text.len)..];
            const composed = try std.fmt.allocPrint(arena, "{s}{s}", .{ try index.usingNamespace(entry), rest });
            if (std.mem.eql(u8, composed, namespace)) return error.CsNamespaceAlias;
        }
        var matched = false;
        const global = std.mem.startsWith(u8, std.mem.trim(u8, raw, " \t\r\n"), "global::");
        if (global) {
            matched = std.mem.eql(u8, text, namespace);
        } else {
            for (try scopesAt(arena, unit, node)) |current| {
                if (std.mem.eql(u8, try join(arena, current, text), namespace)) matched = true;
            }
        }
        if (!matched or try boundLocally(arena, unit, first)) continue;
        try out.append(arena, .{ .qualifier = left, .name = name, .global = global });
    }
    return out.items;
}

pub fn lineStart(source: []const u8, at: u32) u32 {
    var i: usize = at;
    while (i != 0 and source[i - 1] != '\n') i -= 1;
    return @intCast(i);
}

pub fn lineEnd(source: []const u8, at: u32) u32 {
    var i: usize = at;
    while (i < source.len and source[i] != '\n') i += 1;
    if (i < source.len) i += 1;
    return @intCast(i);
}

pub fn newlineOf(source: []const u8) []const u8 {
    return if (std.mem.indexOf(u8, source, "\r\n") != null) "\r\n" else "\n";
}

pub fn insertUsing(arena: Allocator, unit: Unit, line: []const u8, edits: *std.ArrayList(TextEdit)) !void {
    const source = unit.snapshot.source;
    const newline = newlineOf(source);
    const root = unit.snapshot.tree.root();
    var after: ?u32 = null;
    var first: ?u32 = null;
    var i: u32 = 0;
    while (root.namedChild(i)) |child| : (i += 1) {
        const kind = child.kind();
        if (unit.snapshot.profile.isComment(kind)) continue;
        if (std.mem.eql(u8, kind, "using_directive") or std.mem.eql(u8, kind, "extern_alias_directive")) {
            after = lineEnd(source, child.endByte());
            continue;
        }
        first = child.startByte();
        break;
    }
    if (after) |at| {
        if (joinedInsert(edits, at)) |earlier| {
            earlier.text = try std.mem.concat(arena, u8, &.{ earlier.text, line, newline });
            return;
        }
        const glue: []const u8 = if (at != 0 and source[at - 1] == '\n') "" else newline;
        try edits.append(arena, .{ .start = at, .end = at, .text = try std.mem.concat(arena, u8, &.{ glue, line, newline }) });
        return;
    }
    const at = first orelse @as(u32, @intCast(source.len));
    const tail: []const u8 = if (first != null) newline else "";
    if (joinedInsert(edits, at)) |earlier| {
        const lines = earlier.text[0 .. earlier.text.len - tail.len];
        earlier.text = try std.mem.concat(arena, u8, &.{ lines, line, newline, tail });
        return;
    }
    try edits.append(arena, .{ .start = at, .end = at, .text = try std.mem.concat(arena, u8, &.{ line, newline, tail }) });
}

fn joinedInsert(edits: *std.ArrayList(TextEdit), at: u32) ?*TextEdit {
    for (edits.items) |*edit| {
        if (edit.start == at and edit.end == at) return edit;
    }
    return null;
}

pub const Retarget = struct {
    old: []const u8,
    new: []const u8,
    names: []const []const u8,
    old_empties: bool = false,
    global_new: bool = false,

    fn moved(self: Retarget, namespace: []const u8, name: []const u8) bool {
        return std.mem.eql(u8, namespace, self.old) and wanted(self.names, name);
    }
};

fn outside(node: ts.Node, skip: ?Span) bool {
    const span = skip orelse return true;
    return node.endByte() <= span.start or node.startByte() >= span.end;
}

fn rewriteQualified(arena: Allocator, index: *const Index, unit: Unit, r: Retarget, skip: ?Span, edits: *std.ArrayList(TextEdit)) !void {
    for (try qualifiedTo(arena, index, unit, r.old, r.names)) |q| {
        if (!outside(q.qualifier, skip)) continue;
        const text = if (q.global) try std.fmt.allocPrint(arena, "global::{s}", .{r.new}) else r.new;
        try edits.append(arena, .{ .start = q.qualifier.startByte(), .end = q.qualifier.endByte(), .text = text });
    }
}

fn handleOldUsings(arena: Allocator, index: *const Index, unit: Unit, r: Retarget, need_using: *bool, edits: *std.ArrayList(TextEdit)) !void {
    if (!r.old_empties) return;
    const source = unit.snapshot.source;
    for (unit.usings) |entry| {
        if (entry.spec_kind == .using_alias) {
            if (std.mem.eql(u8, try index.usingNamespace(entry), r.old)) return error.CsNamespaceAlias;
            continue;
        }
        if (entry.spec_kind != .using or !std.mem.eql(u8, try index.usingNamespace(entry), r.old)) continue;
        const at = entry.spec_start;
        if (entry.global or need_using.*) {
            try edits.append(arena, .{ .start = at, .end = at + @as(u32, @intCast(entry.spec.len)), .text = r.new });
            if (!entry.global) need_using.* = false;
        } else {
            try edits.append(arena, .{ .start = lineStart(source, entry.statement.start), .end = lineEnd(source, entry.statement.end), .text = "" });
        }
    }
}

pub fn rewriteUser(arena: Allocator, index: *const Index, unit: Unit, r: Retarget, skip: ?Span, edits: *std.ArrayList(TextEdit)) !void {
    try rewriteQualified(arena, index, unit, r, skip, edits);
    var need = false;
    for (try mentions(arena, unit, r.names)) |mention| {
        if (!outside(mention.node, skip)) continue;
        const scopes = try scopesAt(arena, unit, mention.node);
        const found = try lookup(index, unit, scopes, mention.name);
        if (found != .ns or !r.moved(found.ns, mention.name)) continue;
        if (!try visible(index, unit, scopes, r.new, r.global_new)) need = true;
    }
    try handleOldUsings(arena, index, unit, r, &need, edits);
    if (need) try insertUsing(arena, unit, try std.fmt.allocPrint(arena, "using {s};", .{r.new}), edits);
}

pub fn rewriteMovedFile(arena: Allocator, index: *const Index, unit: Unit, name_node: ts.Node, r: Retarget, edits: *std.ArrayList(TextEdit)) !void {
    try edits.append(arena, .{ .start = name_node.startByte(), .end = name_node.endByte(), .text = r.new });
    try rewriteQualified(arena, index, unit, r, null, edits);
    var ignored = false;
    try handleOldUsings(arena, index, unit, r, &ignored, edits);
    const after_scopes = try chainOf(arena, r.new);
    var needed: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (try mentions(arena, unit, null)) |mention| {
        const scopes = try scopesAt(arena, unit, mention.node);
        const found = try lookup(index, unit, scopes, mention.name);
        if (found != .ns or found.ns.len == 0 or r.moved(found.ns, mention.name)) continue;
        if (try visibleAnywhere(index, unit, after_scopes, found.ns)) continue;
        try needed.put(arena, found.ns, {});
    }
    for (needed.keys()) |namespace| try insertUsing(arena, unit, try std.fmt.allocPrint(arena, "using {s};", .{namespace}), edits);
}

pub fn visibleAnywhere(index: *const Index, unit: Unit, scopes: []const []const u8, namespace: []const u8) !bool {
    for (scopes) |current| {
        if (std.mem.eql(u8, current, namespace)) return true;
    }
    for (index.globals.items) |other| {
        if (std.mem.eql(u8, other, namespace)) return true;
    }
    for (unit.usings) |entry| {
        if (entry.spec_kind == .using and std.mem.eql(u8, try index.usingNamespace(entry), namespace)) return true;
    }
    return false;
}

pub const Filter = struct {
    span: ?Span = null,
    inside: bool = false,

    fn keeps(self: Filter, node: ts.Node) bool {
        const span = self.span orelse return true;
        const within = node.startByte() >= span.start and node.endByte() <= span.end;
        return within == self.inside;
    }
};

pub fn universe(arena: Allocator, before: *const Index, after: *const Index, r: Retarget) ![]const []const u8 {
    var out: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (r.names) |name| try out.put(arena, name, {});
    for (try before.typeNames(r.old)) |name| try out.put(arena, name, {});
    for (try before.typeNames(r.new)) |name| try out.put(arena, name, {});
    for (try after.typeNames(r.new)) |name| try out.put(arena, name, {});
    return out.keys();
}

pub fn proveSame(arena: Allocator, before: *const Index, before_unit: Unit, before_filter: Filter, after: *const Index, after_unit: Unit, after_filter: Filter, r: Retarget, names: []const []const u8) !void {
    const a = try mentions(arena, before_unit, names);
    const b = try mentions(arena, after_unit, names);
    var j: usize = 0;
    for (a) |left| {
        if (!before_filter.keeps(left.node)) continue;
        while (j < b.len and !after_filter.keeps(b[j].node)) j += 1;
        if (j == b.len or !std.mem.eql(u8, left.name, b[j].name)) return error.IncompleteMove;
        const was = try lookup(before, before_unit, try scopesAt(arena, before_unit, left.node), left.name);
        const now = try lookup(after, after_unit, try scopesAt(arena, after_unit, b[j].node), left.name);
        var expected = was;
        if (was == .ns and r.moved(was.ns, left.name)) expected = .{ .ns = r.new };
        if (!expected.eql(now)) return if (now == .ns or now == .ambiguous) error.CsAmbiguousType else error.IncompleteMove;
        j += 1;
    }
    while (j < b.len) : (j += 1) {
        if (after_filter.keeps(b[j].node)) return error.IncompleteMove;
    }
}

pub fn proveKept(before: *Snapshot, after: *Snapshot, cut: ?Span, edits: []const TextEdit) !void {
    const a = try before.symbols();
    const b = after.symbols() catch return error.MutationSyntaxInvalid;
    for (a.symbols) |x| {
        if (cut) |span| {
            if (x.declaration.start >= span.start and x.declaration.start < span.end) continue;
        }
        var ok = false;
        for (b.symbols) |y| {
            if (!std.mem.eql(u8, x.ref.name, y.ref.name)) continue;
            if (std.mem.eql(u8, &x.hash, &y.hash) or touched(x.declaration, edits)) ok = true;
        }
        if (!ok) return error.BodyChanged;
    }
    for (a.declarations) |x| {
        if (cut) |span| {
            if (x.name.startByte() >= span.start and x.name.startByte() < span.end) continue;
        }
        var ok = false;
        for (b.declarations) |y| {
            if (!std.mem.eql(u8, x.ref.name, y.ref.name)) continue;
            if (std.mem.eql(u8, &x.hash, &y.hash) or touched(x.declaration, edits)) ok = true;
        }
        if (!ok) return error.BodyChanged;
    }
}

fn touched(span: Span, edits: []const TextEdit) bool {
    for (edits) |e| {
        if (e.start < span.end and span.start < e.end) return true;
        if (e.start == e.end and span.start <= e.start and e.start < span.end) return true;
    }
    return false;
}

pub fn refuseStrings(cx: Cx, units: []const Unit, namespace: []const u8, names: []const []const u8, refused: anyerror) !void {
    for (names) |name| {
        const word = try std.fmt.allocPrint(cx.arena, "{s}.{s}", .{ namespace, name });
        const listing = try repo.filesMentioning(cx.arena, cx.io, cx.root, word);
        var files = std.mem.tokenizeScalar(u8, listing, 0);
        while (files.next()) |rel| {
            if (!std.ascii.endsWithIgnoreCase(rel, ".cs")) return refused;
        }
        for (units) |unit| {
            if (std.mem.indexOf(u8, unit.snapshot.source, word) == null) continue;
            var stack: std.ArrayList(ts.Node) = .empty;
            try stack.append(cx.arena, unit.snapshot.tree.root());
            while (stack.pop()) |node| {
                if (isStringKind(unit.snapshot, node.kind())) {
                    if (std.mem.indexOf(u8, unit.snapshot.tree.text(node), word) != null) return refused;
                    continue;
                }
                var i: u32 = 0;
                while (node.child(i)) |child| : (i += 1) try stack.append(cx.arena, child);
            }
        }
    }
}

fn isStringKind(snapshot: *const Snapshot, kind: []const u8) bool {
    for (snapshot.profile.strings) |other| {
        if (std.mem.eql(u8, other, kind)) return true;
    }
    return false;
}

pub const Project = struct {
    dir: []const u8,
    csproj: ?[]const u8,
    root_namespace: []const u8,
};

fn dirOf(abs: []const u8) []const u8 {
    return std.fs.path.dirname(abs) orelse "";
}

fn under(dir: []const u8, abs: []const u8) bool {
    return abs.len > dir.len and std.ascii.eqlIgnoreCase(abs[0..dir.len], dir) and (abs[dir.len] == '\\' or abs[dir.len] == '/');
}

pub fn projectOf(cx: Cx, abs: []const u8) !Project {
    var best: Project = .{ .dir = cx.root, .csproj = null, .root_namespace = "" };
    var length: usize = 0;
    const listing = try repo.trackedListing(cx.arena, cx.io, cx.root, "*.csproj");
    var files = std.mem.tokenizeScalar(u8, listing, 0);
    while (files.next()) |rel| {
        const path = try std.fmt.allocPrint(cx.arena, "{s}\\{s}", .{ cx.root, rel });
        std.mem.replaceScalar(u8, path, '/', '\\');
        const dir = dirOf(path);
        if (!under(dir, abs) or (best.csproj != null and dir.len <= length)) continue;
        length = dir.len;
        best = .{ .dir = dir, .csproj = path, .root_namespace = try rootNamespace(cx, path) };
    }
    return best;
}

fn rootNamespace(cx: Cx, csproj: []const u8) ![]const u8 {
    const text = std.Io.Dir.cwd().readFileAlloc(cx.io, csproj, cx.arena, .limited(16 * 1024 * 1024)) catch "";
    const open = "<RootNamespace>";
    if (std.mem.indexOf(u8, text, open)) |at| {
        const start = at + open.len;
        if (std.mem.indexOfPos(u8, text, start, "</RootNamespace>")) |end| {
            const value = std.mem.trim(u8, text[start..end], " \t\r\n");
            if (value.len != 0 and std.mem.indexOfScalar(u8, value, '$') == null) return value;
        }
    }
    const base = std.fs.path.basename(csproj);
    return base[0 .. base.len - ".csproj".len];
}

pub fn explicitCompile(cx: Cx, project: Project, abs: []const u8) !bool {
    const csproj = project.csproj orelse return false;
    const text = std.Io.Dir.cwd().readFileAlloc(cx.io, csproj, cx.arena, .limited(16 * 1024 * 1024)) catch return false;
    const base = std.fs.path.basename(abs);
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "<Compile") == null) continue;
        if (std.ascii.indexOfIgnoreCase(line, base) != null) return true;
    }
    return false;
}

fn segments(arena: Allocator, dir: []const u8, abs: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const parent = dirOf(abs);
    if (parent.len <= dir.len) return out.items;
    var parts = std.mem.tokenizeAny(u8, parent[dir.len..], "\\/");
    while (parts.next()) |part| try out.append(arena, part);
    return out.items;
}

fn dotted(arena: Allocator, base: []const u8, parts: []const []const u8) ![]const u8 {
    var out = base;
    for (parts) |part| out = try join(arena, out, part);
    return out;
}

const cs_keywords = std.StaticStringMap(void).initComptime(.{
    .{"abstract"}, .{"as"},        .{"base"},    .{"bool"},      .{"break"},   .{"byte"},     .{"case"},      .{"catch"},
    .{"char"},     .{"checked"},   .{"class"},   .{"const"},     .{"continue"}, .{"decimal"}, .{"default"},   .{"delegate"},
    .{"do"},       .{"double"},    .{"else"},    .{"enum"},      .{"event"},   .{"explicit"}, .{"extern"},    .{"false"},
    .{"finally"},  .{"fixed"},     .{"float"},   .{"for"},       .{"foreach"}, .{"goto"},     .{"if"},        .{"implicit"},
    .{"in"},       .{"int"},       .{"interface"}, .{"internal"}, .{"is"},     .{"lock"},     .{"long"},      .{"namespace"},
    .{"new"},      .{"null"},      .{"object"},  .{"operator"},  .{"out"},     .{"override"}, .{"params"},    .{"private"},
    .{"protected"}, .{"public"},   .{"readonly"}, .{"ref"},      .{"return"},  .{"sbyte"},    .{"sealed"},    .{"short"},
    .{"sizeof"},   .{"stackalloc"}, .{"static"}, .{"string"},    .{"struct"},  .{"switch"},   .{"this"},      .{"throw"},
    .{"true"},     .{"try"},       .{"typeof"},  .{"uint"},      .{"ulong"},   .{"unchecked"}, .{"unsafe"},   .{"ushort"},
    .{"using"},    .{"virtual"},   .{"void"},    .{"volatile"},  .{"while"},
});

pub fn validNamespace(namespace: []const u8) bool {
    if (namespace.len == 0) return false;
    var parts = std.mem.splitScalar(u8, namespace, '.');
    while (parts.next()) |part| {
        if (part.len == 0 or cs_keywords.has(part)) return false;
        for (part, 0..) |byte, i| {
            if (i == 0 and std.ascii.isDigit(byte)) return false;
            if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
        }
    }
    return true;
}

pub fn followingNamespace(arena: Allocator, namespace: []const u8, project: Project, from_abs: []const u8, to_abs: []const u8) !?[]const u8 {
    const from_dirs = try segments(arena, project.dir, from_abs);
    const to_dirs = try segments(arena, project.dir, to_abs);
    if (project.root_namespace.len != 0 and std.mem.eql(u8, namespace, try dotted(arena, project.root_namespace, from_dirs))) {
        return try dotted(arena, project.root_namespace, to_dirs);
    }
    var common: usize = 0;
    while (common < from_dirs.len and common < to_dirs.len and std.mem.eql(u8, from_dirs[common], to_dirs[common])) common += 1;
    const from_rest = from_dirs[common..];
    const to_rest = to_dirs[common..];
    if (from_rest.len != 0) {
        const tail = try dotted(arena, "", from_rest);
        if (std.mem.eql(u8, namespace, tail)) return try dotted(arena, "", to_rest);
        if (std.mem.endsWith(u8, namespace, try std.fmt.allocPrint(arena, ".{s}", .{tail}))) {
            return try dotted(arena, namespace[0 .. namespace.len - tail.len - 1], to_rest);
        }
        return null;
    }
    if (common == 0 or to_rest.len == 0) return null;
    const last = from_dirs[common - 1];
    if (std.mem.eql(u8, namespace, last) or std.mem.endsWith(u8, namespace, try std.fmt.allocPrint(arena, ".{s}", .{last}))) {
        return try dotted(arena, namespace, to_rest);
    }
    return null;
}

pub const Change = struct {
    abs: []const u8,
    snapshot: *Snapshot,
    edits: std.ArrayList(TextEdit) = .empty,
};

pub const FilePlan = struct {
    changes: []Change,
    users: usize,
    rewritten: usize,
    note: ?[]const u8,
    interface_change: bool,
    container_changes: bool,
    retarget: ?Retarget,
    units: []const Unit,
};

fn hasModifier(tree: anytype, declaration: ts.Node, word: []const u8) bool {
    var i: u32 = 0;
    while (declaration.child(i)) |child| : (i += 1) {
        if (!std.mem.eql(u8, child.kind(), "modifier")) continue;
        if (std.mem.eql(u8, tree.text(child), word)) return true;
    }
    return false;
}

pub fn modifierOn(snapshot: *const Snapshot, declaration: ts.Node, word: []const u8) bool {
    return hasModifier(&snapshot.tree, declaration, word);
}

fn partialElsewhere(units: []const Unit, moved_abs: []const u8, namespace: []const u8, names: []const []const u8) ?[]const u8 {
    for (units) |unit| {
        if (tsserver.sameFile(unit.abs, moved_abs)) continue;
        for (unit.declared) |d| {
            if (!std.mem.eql(u8, d.namespace, namespace)) continue;
            if (wanted(names, d.name)) return d.name;
        }
    }
    return null;
}

fn namespaceNode(unit: Unit) ?ts.Node {
    const root = unit.snapshot.tree.root();
    var i: u32 = 0;
    while (root.namedChild(i)) |child| : (i += 1) {
        const kind = child.kind();
        if (std.mem.eql(u8, kind, "namespace_declaration") or std.mem.eql(u8, kind, "file_scoped_namespace_declaration")) {
            return child.childByField("name");
        }
    }
    return null;
}

pub fn planFile(cx: Cx, from_abs: []const u8, to_abs: []const u8, moved: *Snapshot, opened: *std.ArrayList(*Snapshot)) !FilePlan {
    const arena = cx.arena;
    const moved_unit = try unitOf(arena, from_abs, moved);
    const from_project = try projectOf(cx, from_abs);
    const to_project = try projectOf(cx, to_abs);
    if (try explicitCompile(cx, from_project, from_abs)) return error.CsCompileInclude;

    var namespaces: std.ArrayList([]const u8) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    var mixed = false;
    for (moved_unit.declared) |d| {
        if (d.name.len == 0) try namespaces.append(arena, d.namespace);
    }
    const namespace: []const u8 = if (namespaces.items.len == 1) namespaces.items[0] else "";
    for (moved_unit.declared) |d| {
        if (d.name.len == 0 or std.mem.indexOfScalar(u8, d.name, '.') != null) continue;
        if (!std.mem.eql(u8, d.namespace, namespace)) mixed = true;
        try names.append(arena, d.name);
    }
    var changes: std.ArrayList(Change) = .empty;
    try changes.append(arena, .{ .abs = from_abs, .snapshot = moved });
    const leave = struct {
        fn plan(list: []Change, note: []const u8, units: []const Unit) FilePlan {
            return .{ .changes = list, .users = 0, .rewritten = 0, .note = note, .interface_change = false, .container_changes = false, .retarget = null, .units = units };
        }
    }.plan;

    if (namespaces.items.len == 0) return leave(changes.items, "no namespace declared, nothing to update", &.{});
    if (namespaces.items.len > 1 or mixed) return leave(changes.items, "the file declares several namespaces, left as they are", &.{});
    if (!std.ascii.eqlIgnoreCase(from_project.dir, to_project.dir)) {
        return leave(changes.items, try std.fmt.allocPrint(arena, "moved into another project, namespace {s} left as it is: check the project references", .{namespace}), &.{});
    }
    const wanted_new = (try followingNamespace(arena, namespace, from_project, from_abs, to_abs)) orelse {
        return leave(changes.items, try std.fmt.allocPrint(arena, "namespace {s} does not follow the folders, left as it is", .{namespace}), &.{});
    };
    if (std.mem.eql(u8, wanted_new, namespace)) return leave(changes.items, try std.fmt.allocPrint(arena, "namespace {s} kept: it does not depend on this path", .{namespace}), &.{});
    if (!validNamespace(wanted_new)) {
        return leave(changes.items, try std.fmt.allocPrint(arena, "the folders do not spell a valid namespace ({s}), {s} left as it is", .{ wanted_new, namespace }), &.{});
    }

    var words: std.ArrayList([]const u8) = .empty;
    try words.appendSlice(arena, names.items);
    try words.append(arena, namespace);
    const units = try loadUnits(cx, &.{moved_unit}, opened, words.items);
    if (partialElsewhere(units, from_abs, namespace, names.items)) |shared| {
        return leave(changes.items, try std.fmt.allocPrint(arena, "type {s} is also declared in another file, namespace {s} left as it is", .{ shared, namespace }), units);
    }
    const index = try Index.init(arena, units);
    for (names.items) |name| {
        if (index.hasType(wanted_new, name)) return error.TargetNameTaken;
    }
    try refuseStrings(cx, units, namespace, names.items, error.DynamicPathUse);

    var old_empties = true;
    var global_old = false;
    for (units) |unit| {
        for (unit.usings) |entry| {
            if (entry.global and entry.spec_kind == .using and std.mem.eql(u8, try index.usingNamespace(entry), namespace)) global_old = true;
        }
        if (tsserver.sameFile(unit.abs, from_abs)) continue;
        for (unit.declared) |d| {
            if (std.mem.eql(u8, d.namespace, namespace) or std.mem.startsWith(u8, d.namespace, try std.fmt.allocPrint(arena, "{s}.", .{namespace}))) old_empties = false;
        }
    }
    const r: Retarget = .{ .old = namespace, .new = wanted_new, .names = names.items, .old_empties = old_empties, .global_new = old_empties and global_old };

    try rewriteMovedFile(arena, &index, moved_unit, namespaceNode(moved_unit) orelse return error.SymbolNotFound, r, &changes.items[0].edits);
    var users: usize = 0;
    var rewritten: usize = changes.items[0].edits.items.len - 1;
    for (units) |unit| {
        if (tsserver.sameFile(unit.abs, from_abs)) continue;
        var edits: std.ArrayList(TextEdit) = .empty;
        try rewriteUser(arena, &index, unit, r, null, &edits);
        if (edits.items.len == 0) continue;
        users += 1;
        rewritten += edits.items.len;
        try changes.append(arena, .{ .abs = unit.abs, .snapshot = unit.snapshot, .edits = edits });
    }
    return .{
        .changes = changes.items,
        .users = users,
        .rewritten = rewritten,
        .note = try std.fmt.allocPrint(arena, "namespace {s} became {s} because it follows the folders", .{ namespace, wanted_new }),
        .interface_change = false,
        .container_changes = true,
        .retarget = r,
        .units = units,
    };
}

pub fn proveFile(cx: Cx, plan_result: FilePlan, from_abs: []const u8, to_abs: []const u8, afters: []const *Snapshot) !void {
    const r = plan_result.retarget orelse return;
    const arena = cx.arena;
    var after_units: std.ArrayList(Unit) = .empty;
    var pairs: std.ArrayList(Unit) = .empty;
    for (plan_result.units) |unit| {
        var snapshot = unit.snapshot;
        var abs = unit.abs;
        for (plan_result.changes, afters) |change, after| {
            if (tsserver.sameFile(change.abs, unit.abs)) snapshot = after;
        }
        if (tsserver.sameFile(unit.abs, from_abs)) abs = to_abs;
        const fresh = try unitOf(arena, abs, snapshot);
        try after_units.append(arena, fresh);
        try pairs.append(arena, unit);
    }
    const before_index = try Index.init(arena, plan_result.units);
    const after_index = try Index.init(arena, after_units.items);
    const names = try universe(arena, &before_index, &after_index, r);
    for (pairs.items, after_units.items) |before_unit, after_unit| {
        try proveSame(arena, &before_index, before_unit, .{}, &after_index, after_unit, .{}, r, names);
        if ((try qualifiedTo(arena, &after_index, after_unit, r.old, r.names)).len != 0) return error.IncompleteMove;
    }
}
