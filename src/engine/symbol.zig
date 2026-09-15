const std = @import("std");
const ts = @import("tree_sitter.zig");
const traversal = @import("traversal.zig");
const functions_mod = @import("functions.zig");
const ref_mod = @import("ref.zig");
const Profile = @import("lang/profile.zig").Profile;

const Allocator = std.mem.Allocator;

pub const FunctionKind = functions_mod.FunctionKind;
pub const Function = functions_mod.Function;
pub const Span = functions_mod.Span;
pub const classify = functions_mod.classify;
pub const collectFunctions = functions_mod.collectFunctions;
pub const Accessor = ref_mod.Accessor;
pub const Ref = ref_mod.Ref;
const bindingSite = functions_mod.bindingSite;
const bindingName = functions_mod.bindingName;
const isOneOf = functions_mod.isOneOf;

const addressable_name_kinds = [_][]const u8{
    "identifier",
    "property_identifier",
    "private_property_identifier",
    "type_identifier",
};

const container_name_kinds = addressable_name_kinds ++ [_][]const u8{"nested_identifier"};

const declared_containers = [_][]const u8{
    "class_declaration",
    "abstract_class_declaration",
    "internal_module",
    "module",
};

pub const Hash = [16]u8;
pub const hash_hex_len = @sizeOf(Hash) * 2;

pub fn hashOf(text: []const u8) Hash {
    var out: Hash = undefined;
    std.crypto.hash.Blake3.hash(text, &out, .{});
    return out;
}

pub fn formatHash(hash: Hash) [hash_hex_len]u8 {
    return std.fmt.bytesToHex(hash, .lower);
}

pub fn parseHash(hex: []const u8) error{InvalidHash}!Hash {
    if (hex.len != hash_hex_len) return error.InvalidHash;
    var out: Hash = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch return error.InvalidHash;
    return out;
}

pub const Kind = enum {
    function,
    generator,
    method,
    getter,
    setter,
    constructor,
    arrow,
    function_expression,
};

pub const Symbol = struct {
    ref: Ref,
    kind: Kind,
    node: ts.Node,
    body: ts.Node,
    declaration: Span,
    hash: Hash,
    ambiguous: bool = false,
};

pub const Table = struct {
    arena: *std.heap.ArenaAllocator,
    symbols: []Symbol,

    pub const BuildError = error{SourceHasErrors} || Allocator.Error;
    pub const ResolveError = error{ SymbolNotFound, AmbiguousSymbol };

    pub fn build(gpa: Allocator, profile: *const Profile, tree: ts.Tree) BuildError!Table {
        if (tree.root().hasError()) return error.SourceHasErrors;

        const arena = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena);
        arena.* = .init(gpa);
        errdefer arena.deinit();

        const functions = try collectFunctions(gpa, profile, tree);
        defer gpa.free(functions);

        var symbols: std.ArrayList(Symbol) = .empty;
        for (functions) |function| {
            const symbol = try describe(arena.allocator(), profile, tree, function) orelse continue;
            try symbols.append(arena.allocator(), symbol);
        }
        markAmbiguous(symbols.items);
        return .{ .arena = arena, .symbols = symbols.items };
    }

    pub fn deinit(self: Table) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self.arena);
    }

    pub fn resolve(self: Table, ref: Ref) ResolveError!*const Symbol {
        var found: ?*const Symbol = null;
        for (self.symbols) |*symbol| {
            if (!symbol.ref.eql(ref)) continue;
            if (found != null) return error.AmbiguousSymbol;
            found = symbol;
        }
        return found orelse error.SymbolNotFound;
    }
};

fn markAmbiguous(symbols: []Symbol) void {
    for (symbols, 0..) |*a, i| {
        for (symbols[i + 1 ..]) |*b| {
            if (!a.ref.eql(b.ref)) continue;
            a.ambiguous = true;
            b.ambiguous = true;
        }
    }
}

fn describe(arena: Allocator, profile: *const Profile, tree: ts.Tree, function: Function) Allocator.Error!?Symbol {
    const kind = symbolKind(tree, function) orelse return null;
    const name = function.name orelse return null;
    if (!isOneOf(name.kind(), &addressable_name_kinds)) return null;
    const container = try containerPath(arena, profile, tree, function.node) orelse return null;
    const declaration = declarationOf(profile, function);
    return .{
        .ref = .{
            .container = container,
            .name = tree.text(name),
            .accessor = accessorOf(function),
            .is_static = isStatic(profile, function),
        },
        .kind = kind,
        .node = function.node,
        .body = function.body,
        .declaration = declaration.span,
        .hash = declaration.hash(tree.source),
    };
}

fn symbolKind(tree: ts.Tree, function: Function) ?Kind {
    return switch (function.kind) {
        .declaration => .function,
        .generator_declaration, .generator_expression => .generator,
        .expression => .function_expression,
        .arrow => .arrow,
        .static_block => null,
        .method => switch (accessorOf(function)) {
            .get => .getter,
            .set => .setter,
            .none => if (isConstructor(tree, function)) .constructor else .method,
        },
    };
}

fn isConstructor(tree: ts.Tree, function: Function) bool {
    const name = function.name orelse return false;
    const parent = function.node.parent() orelse return false;
    return std.mem.eql(u8, "class_body", parent.kind()) and std.mem.eql(u8, "constructor", tree.text(name));
}

fn accessorOf(function: Function) Accessor {
    if (function.kind != .method) return .none;
    if (keywordBeforeName(function.node, "get")) return .get;
    if (keywordBeforeName(function.node, "set")) return .set;
    return .none;
}

fn isStatic(profile: *const Profile, function: Function) bool {
    if (function.kind == .method) return keywordBeforeName(function.node, "static");
    const site = bindingSite(profile, function.node) orelse return false;
    return std.mem.eql(u8, "public_field_definition", site.kind()) and keywordBeforeName(site, "static");
}

fn keywordBeforeName(holder: ts.Node, keyword: []const u8) bool {
    const name = holder.childByField("name") orelse return false;
    var i: u32 = 0;
    while (holder.child(i)) |child| : (i += 1) {
        if (child.eql(name)) return false;
        if (!child.isNamed() and std.mem.eql(u8, keyword, child.kind())) return true;
    }
    return false;
}

const ContainerRole = union(enum) {
    transparent,
    unnamed,
    named: ts.Node,
};

fn containerRole(profile: *const Profile, node: ts.Node) ContainerRole {
    const kind = node.kind();
    const name: ?ts.Node = if (classify(profile, node)) |function|
        function.name
    else if (isOneOf(kind, &declared_containers))
        node.childByField("name")
    else if (std.mem.eql(u8, kind, "class"))
        node.childByField("name") orelse bindingName(profile, node)
    else if (std.mem.eql(u8, kind, "object"))
        bindingName(profile, node)
    else
        return .transparent;
    return if (name) |n| .{ .named = n } else .unnamed;
}

fn containerPath(arena: Allocator, profile: *const Profile, tree: ts.Tree, node: ts.Node) Allocator.Error!?[]const []const u8 {
    var reversed: std.ArrayList([]const u8) = .empty;
    var current = node.parent();
    while (current) |ancestor| : (current = ancestor.parent()) {
        const name = switch (containerRole(profile, ancestor)) {
            .transparent => continue,
            .unnamed => return null,
            .named => |name| name,
        };
        if (!isOneOf(name.kind(), &container_name_kinds)) return null;
        const first = reversed.items.len;
        try appendNameSegments(arena, tree, name, &reversed);
        std.mem.reverse([]const u8, reversed.items[first..]);
    }
    std.mem.reverse([]const u8, reversed.items);
    return reversed.items;
}

const declaration_statements = [_][]const u8{
    "lexical_declaration",
    "variable_declaration",
    "expression_statement",
};

const Declaration = struct {
    span: Span,
    prefix: Span = .{ .start = 0, .end = 0 },

    fn hash(self: Declaration, source: []const u8) Hash {
        var hasher = std.crypto.hash.Blake3.init(.{});
        hasher.update(source[self.prefix.start..self.prefix.end]);
        hasher.update(source[self.span.start..self.span.end]);
        var out: Hash = undefined;
        hasher.final(&out);
        return out;
    }
};

fn declarationOf(profile: *const Profile, function: Function) Declaration {
    const site = bindingSite(profile, function.node);
    const own = site orelse function.node;
    var statement: ?ts.Node = null;
    if (own.parent()) |parent| {
        if (isOneOf(parent.kind(), &declaration_statements)) statement = parent;
    }
    var outer = statement orelse own;
    if (outer.parent()) |parent| {
        if (std.mem.eql(u8, "export_statement", parent.kind())) outer = parent;
    }

    const shared = if (statement) |s| site != null and declaratorCount(s) > 1 else false;
    if (!shared) return .{ .span = .{ .start = leadingDecoratorStart(outer), .end = outer.endByte() } };
    return .{
        .span = .{ .start = own.startByte(), .end = own.endByte() },
        .prefix = .{ .start = outer.startByte(), .end = firstDeclaratorStart(statement.?) },
    };
}

fn declaratorCount(statement: ts.Node) u32 {
    var count: u32 = 0;
    var i: u32 = 0;
    while (statement.namedChild(i)) |child| : (i += 1) {
        if (std.mem.eql(u8, "variable_declarator", child.kind())) count += 1;
    }
    return count;
}

fn firstDeclaratorStart(statement: ts.Node) u32 {
    var i: u32 = 0;
    while (statement.namedChild(i)) |child| : (i += 1) {
        if (std.mem.eql(u8, "variable_declarator", child.kind())) return child.startByte();
    }
    return statement.startByte();
}

fn leadingDecoratorStart(node: ts.Node) u32 {
    var start = node.startByte();
    var prev = node.prevNamedSibling();
    while (prev) |sibling| : (prev = sibling.prevNamedSibling()) {
        if (std.mem.eql(u8, "comment", sibling.kind())) continue;
        if (!std.mem.eql(u8, "decorator", sibling.kind())) break;
        start = sibling.startByte();
    }
    return start;
}

const identifier_segment_kinds = [_][]const u8{ "identifier", "property_identifier", "type_identifier" };

fn appendNameSegments(arena: Allocator, tree: ts.Tree, name: ts.Node, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    if (!std.mem.eql(u8, "nested_identifier", name.kind())) return out.append(arena, tree.text(name));
    var walker = traversal.Walker.init(name);
    defer walker.deinit();
    while (walker.next()) |entry| {
        const node = entry.node;
        if (node.childCount() == 0 and isOneOf(node.kind(), &identifier_segment_kinds)) {
            try out.append(arena, tree.text(node));
        }
    }
}
