const std = @import("std");
const ts = @import("tree_sitter.zig");
const traversal = @import("traversal.zig");

const Allocator = std.mem.Allocator;

pub const FunctionKind = enum {
    function_declaration,
    generator_function_declaration,
    function_expression,
    generator_function,
    arrow_function,
    method_definition,
    class_static_block,
};

pub const Function = struct {
    node: ts.Node,
    kind: FunctionKind,
    body: ts.Node,
    name: ?ts.Node,
    nested: bool,
};

const Binding = struct {
    parent: []const u8,
    value_field: []const u8,
    name_field: []const u8,
};

const bindings = [_]Binding{
    .{ .parent = "variable_declarator", .value_field = "value", .name_field = "name" },
    .{ .parent = "public_field_definition", .value_field = "value", .name_field = "name" },
    .{ .parent = "pair", .value_field = "value", .name_field = "key" },
    .{ .parent = "assignment_expression", .value_field = "right", .name_field = "left" },
    .{ .parent = "augmented_assignment_expression", .value_field = "right", .name_field = "left" },
};

const transparent_wrappers = [_][]const u8{
    "parenthesized_expression",
    "as_expression",
    "satisfies_expression",
    "non_null_expression",
};

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

pub fn classify(node: ts.Node) ?Function {
    const kind = std.meta.stringToEnum(FunctionKind, node.kind()) orelse return null;
    const body = node.childByField("body") orelse return null;
    return .{
        .node = node,
        .kind = kind,
        .body = body,
        .name = resolveName(node, kind),
        .nested = false,
    };
}

fn resolveName(node: ts.Node, kind: FunctionKind) ?ts.Node {
    const own = node.childByField("name");
    return switch (kind) {
        .function_declaration, .generator_function_declaration, .method_definition => own,
        else => bindingName(node) orelse own,
    };
}

fn bindingSite(node: ts.Node) ?ts.Node {
    var value = node;
    var parent = node.parent() orelse return null;
    while (isOneOf(parent.kind(), &transparent_wrappers)) {
        value = parent;
        parent = parent.parent() orelse return null;
    }
    const binding = bindingFor(parent) orelse return null;
    const bound = parent.childByField(binding.value_field) orelse return null;
    return if (bound.eql(value)) parent else null;
}

fn bindingName(node: ts.Node) ?ts.Node {
    const site = bindingSite(node) orelse return null;
    return site.childByField(bindingFor(site).?.name_field);
}

fn bindingFor(node: ts.Node) ?Binding {
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.parent, node.kind())) return binding;
    }
    return null;
}

fn isOneOf(kind: []const u8, kinds: []const []const u8) bool {
    for (kinds) |candidate| {
        if (std.mem.eql(u8, candidate, kind)) return true;
    }
    return false;
}

pub const Span = struct { start: u32, end: u32 };

pub fn collectFunctions(gpa: Allocator, tree: ts.Tree) Allocator.Error![]Function {
    var found: std.ArrayList(Function) = .empty;
    errdefer found.deinit(gpa);
    var open_bodies: std.ArrayList(Span) = .empty;
    defer open_bodies.deinit(gpa);

    var walker = traversal.Walker.init(tree.root());
    defer walker.deinit();
    while (walker.next()) |entry| {
        if (!entry.node.isNamed()) continue;
        var function = classify(entry.node) orelse continue;
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

pub const Accessor = enum { none, get, set };

pub const Ref = struct {
    container: []const []const u8 = &.{},
    name: []const u8,
    accessor: Accessor = .none,
    is_static: bool = false,

    pub const ParseError = error{InvalidRef} || Allocator.Error;

    pub fn parse(gpa: Allocator, text: []const u8) ParseError!Ref {
        const qualifier_start = std.mem.indexOfScalar(u8, text, '@') orelse text.len;
        var ref: Ref = .{ .name = undefined };
        if (qualifier_start < text.len) try ref.applyQualifiers(text[qualifier_start + 1 ..]);

        const path = text[0..qualifier_start];
        const container = try gpa.alloc([]const u8, std.mem.count(u8, path, "."));
        errdefer gpa.free(container);
        var segments = std.mem.splitScalar(u8, path, '.');
        for (container) |*segment| segment.* = try nonEmpty(segments.next().?);
        ref.name = try nonEmpty(segments.next().?);
        ref.container = container;
        return ref;
    }

    pub fn deinit(self: Ref, gpa: Allocator) void {
        gpa.free(self.container);
    }

    fn applyQualifiers(self: *Ref, text: []const u8) error{InvalidRef}!void {
        var qualifiers = std.mem.splitScalar(u8, text, '@');
        while (qualifiers.next()) |qualifier| {
            if (std.mem.eql(u8, qualifier, "static")) {
                if (self.is_static) return error.InvalidRef;
                self.is_static = true;
                continue;
            }
            const accessor = std.meta.stringToEnum(Accessor, qualifier) orelse return error.InvalidRef;
            if (accessor == .none or self.accessor != .none) return error.InvalidRef;
            self.accessor = accessor;
        }
    }

    pub fn format(self: Ref, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.container) |segment| try writer.print("{s}.", .{segment});
        try writer.writeAll(self.name);
        if (self.is_static) try writer.writeAll("@static");
        if (self.accessor != .none) try writer.print("@{t}", .{self.accessor});
    }

    pub fn eql(a: Ref, b: Ref) bool {
        if (a.accessor != b.accessor or a.is_static != b.is_static) return false;
        if (!std.mem.eql(u8, a.name, b.name) or a.container.len != b.container.len) return false;
        for (a.container, b.container) |x, y| {
            if (!std.mem.eql(u8, x, y)) return false;
        }
        return true;
    }
};

fn nonEmpty(segment: []const u8) error{InvalidRef}![]const u8 {
    return if (segment.len == 0) error.InvalidRef else segment;
}

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

    pub fn build(gpa: Allocator, tree: ts.Tree) BuildError!Table {
        if (tree.root().hasError()) return error.SourceHasErrors;

        const arena = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena);
        arena.* = .init(gpa);
        errdefer arena.deinit();

        const functions = try collectFunctions(gpa, tree);
        defer gpa.free(functions);

        var symbols: std.ArrayList(Symbol) = .empty;
        for (functions) |function| {
            const symbol = try describe(arena.allocator(), tree, function) orelse continue;
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

fn describe(arena: Allocator, tree: ts.Tree, function: Function) Allocator.Error!?Symbol {
    const kind = symbolKind(tree, function) orelse return null;
    const name = function.name orelse return null;
    if (!isOneOf(name.kind(), &addressable_name_kinds)) return null;
    const container = try containerPath(arena, tree, function.node) orelse return null;
    const declaration = declarationOf(function);
    return .{
        .ref = .{
            .container = container,
            .name = tree.text(name),
            .accessor = accessorOf(function),
            .is_static = isStatic(function),
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
        .function_declaration => .function,
        .generator_function_declaration, .generator_function => .generator,
        .function_expression => .function_expression,
        .arrow_function => .arrow,
        .class_static_block => null,
        .method_definition => switch (accessorOf(function)) {
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
    if (function.kind != .method_definition) return .none;
    if (keywordBeforeName(function.node, "get")) return .get;
    if (keywordBeforeName(function.node, "set")) return .set;
    return .none;
}

fn isStatic(function: Function) bool {
    if (function.kind == .method_definition) return keywordBeforeName(function.node, "static");
    const site = bindingSite(function.node) orelse return false;
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

fn containerRole(node: ts.Node) ContainerRole {
    const kind = node.kind();
    const name: ?ts.Node = if (classify(node)) |function|
        function.name
    else if (isOneOf(kind, &declared_containers))
        node.childByField("name")
    else if (std.mem.eql(u8, kind, "class"))
        node.childByField("name") orelse bindingName(node)
    else if (std.mem.eql(u8, kind, "object"))
        bindingName(node)
    else
        return .transparent;
    return if (name) |n| .{ .named = n } else .unnamed;
}

fn containerPath(arena: Allocator, tree: ts.Tree, node: ts.Node) Allocator.Error!?[]const []const u8 {
    var reversed: std.ArrayList([]const u8) = .empty;
    var current = node.parent();
    while (current) |ancestor| : (current = ancestor.parent()) {
        const name = switch (containerRole(ancestor)) {
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

fn declarationOf(function: Function) Declaration {
    const site = bindingSite(function.node);
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

