const std = @import("std");
const ts = @import("tree_sitter.zig");
const traversal = @import("traversal.zig");
const functions_mod = @import("functions.zig");
const ref_mod = @import("ref.zig");
const profile_mod = @import("lang/profile.zig");
const declarations_mod = @import("declarations.zig");
const statements_mod = @import("statements.zig");

const Allocator = std.mem.Allocator;
const Profile = profile_mod.Profile;
const MemberTraits = profile_mod.MemberTraits;

pub const FunctionKind = functions_mod.FunctionKind;
pub const Function = functions_mod.Function;
pub const Span = functions_mod.Span;

pub const Hole = struct {
    old: Span,
    new: Span,
};
pub const classify = functions_mod.classify;
pub const collectFunctions = functions_mod.collectFunctions;
pub const Accessor = ref_mod.Accessor;
pub const Ref = ref_mod.Ref;
const bindingSite = functions_mod.bindingSite;
const bindingName = functions_mod.bindingName;
const isOneOf = functions_mod.isOneOf;

pub const Hash = [16]u8;
pub const hash_hex_len = @sizeOf(Hash) * 2;

pub fn fileHash(bytes: []const u8) Hash {
    return hashOf(bytes);
}

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

pub const absent_text = "absent";

pub const Expected = union(enum) {
    present: Hash,
    absent,

    pub fn text(self: *const Expected, buffer: *[hash_hex_len]u8) []const u8 {
        switch (self.*) {
            .present => |hash| {
                buffer.* = formatHash(hash);
                return buffer;
            },
            .absent => return absent_text,
        }
    }
};

pub fn parseExpected(text: []const u8) error{InvalidHash}!Expected {
    if (std.mem.eql(u8, text, absent_text)) return .absent;
    return .{ .present = try parseHash(text) };
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
    signature: []const u8 = "",
};

pub const Declaration = declarations_mod.Declaration;
pub const DeclarationKind = profile_mod.DeclarationKind;
pub const Statement = statements_mod.Statement;

pub const Item = struct {
    ref: Ref,
    role: Role,
    node: ts.Node,
    span: Span,
    hash: Hash,
    body: ?ts.Node = null,

    pub const Role = enum { symbol, declaration, statement, import, binding, property };
};

pub const Table = struct {
    arena: *std.heap.ArenaAllocator,
    symbols: []Symbol,
    declarations: []Declaration = &.{},
    statements: []Statement = &.{},
    short_refs: bool = false,

    pub const BuildError = error{SourceHasErrors} || Allocator.Error;
    pub const ResolveError = error{ SymbolNotFound, AmbiguousSymbol };

    pub fn build(gpa: Allocator, profile: *const Profile, tree: ts.Tree) BuildError!Table {
        if (tree.root().hasError()) return error.SourceHasErrors;
        return buildTolerant(gpa, profile, tree);
    }

    pub fn buildTolerant(gpa: Allocator, profile: *const Profile, tree: ts.Tree) Allocator.Error!Table {
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
        try settleRefs(arena.allocator(), profile, tree, symbols.items);
        const declarations = try declarations_mod.collect(arena.allocator(), profile, tree);
        try settleRefs(arena.allocator(), profile, tree, declarations);
        const taken = try arena.allocator().alloc(Ref, symbols.items.len + declarations.len);
        for (symbols.items, 0..) |symbol, i| taken[i] = symbol.ref;
        for (declarations, 0..) |declaration, i| taken[symbols.items.len + i] = declaration.ref;
        const statements = try statements_mod.collect(arena.allocator(), profile, tree, taken);
        return .{ .arena = arena, .symbols = symbols.items, .declarations = declarations, .statements = statements, .short_refs = profile.short_refs };
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
        if (found) |symbol| return symbol;
        for (self.declarations) |declaration| {
            if (declaration.ref.eql(ref)) return error.SymbolNotFound;
        }
        for (self.statements) |statement| {
            if (statement.ref.eql(ref)) return error.SymbolNotFound;
        }
        return switch (try self.shortMatch(ref)) {
            .symbol => |symbol| symbol,
            .declaration => error.SymbolNotFound,
        };
    }

    pub fn canonical(self: Table, given: Ref) ResolveError!Ref {
        if (!self.short_refs) return given;
        const found = self.item(given) catch |err| switch (err) {
            error.SymbolNotFound => return given,
            error.AmbiguousSymbol => return err,
        };
        return found.ref;
    }

    pub fn declarationMatching(self: Table, ref: Ref, hash: Hash) ?*const Declaration {
        for (self.declarations) |*declaration| {
            if (declaration.ref.eql(ref) and std.mem.eql(u8, &declaration.hash, &hash)) return declaration;
        }
        return null;
    }

    pub fn item(self: Table, ref: Ref) ResolveError!Item {
        return self.itemExact(ref) catch |err| switch (err) {
            error.AmbiguousSymbol => err,
            error.SymbolNotFound => switch (try self.shortMatch(ref)) {
                .symbol => |symbol| symbolItem(symbol),
                .declaration => |declaration| declarationItem(declaration),
            },
        };
    }

    pub fn memberAt(self: Table, ref: Ref, span: Span) ?Item {
        for (self.symbols) |*symbol| {
            if (self.sameOccupant(symbol.ref, ref) and sameSpan(symbol.declaration, span)) return symbolItem(symbol);
        }
        for (self.declarations) |*declaration| {
            if (self.sameOccupant(declaration.ref, ref) and sameSpan(declaration.declaration, span)) return declarationItem(declaration);
        }
        return null;
    }

    fn sameOccupant(self: Table, placed: Ref, ref: Ref) bool {
        return if (self.short_refs) placed.sameName(ref) else placed.sameMember(ref);
    }

    pub fn candidates(self: Table, gpa: Allocator, ref: Ref) Allocator.Error![]Candidate {
        var out: std.ArrayList(Candidate) = .empty;
        errdefer out.deinit(gpa);
        for (self.symbols) |*symbol| {
            if (symbol.ref.eql(ref)) try out.append(gpa, .{ .ref = symbol.ref, .line = symbol.node.startPoint().row + 1 });
        }
        for (self.declarations) |*declaration| {
            if (declaration.ref.eql(ref)) try out.append(gpa, .{ .ref = declaration.ref, .line = declaration.node.startPoint().row + 1 });
        }
        for (self.statements) |*statement| {
            if (statement.ref.eql(ref)) try out.append(gpa, .{ .ref = statement.ref, .line = statement.node.startPoint().row + 1 });
        }
        if (out.items.len != 0 or !self.short_refs) return out.toOwnedSlice(gpa);
        const tier = self.tierOf(ref);
        const class = self.classMatches(ref);
        for (self.symbols) |*symbol| {
            if (shortHit(ref, symbol, tier) and !(class and symbol.kind == .constructor)) try out.append(gpa, .{ .ref = symbol.ref, .line = symbol.node.startPoint().row + 1 });
        }
        for (self.declarations) |*declaration| {
            if (shortHit(ref, declaration, tier)) try out.append(gpa, .{ .ref = declaration.ref, .line = declaration.node.startPoint().row + 1 });
        }
        return out.toOwnedSlice(gpa);
    }

    const Hit = union(enum) {
        symbol: *const Symbol,
        declaration: *const Declaration,
    };

    fn shortMatch(self: Table, ref: Ref) ResolveError!Hit {
        if (!self.short_refs) return error.SymbolNotFound;
        const tier = self.tierOf(ref);
        const class = self.classMatches(ref);
        var found: ?Hit = null;
        for (self.symbols) |*symbol| {
            if (!shortHit(ref, symbol, tier) or (class and symbol.kind == .constructor)) continue;
            if (found != null) return error.AmbiguousSymbol;
            found = .{ .symbol = symbol };
        }
        for (self.declarations) |*declaration| {
            if (!shortHit(ref, declaration, tier)) continue;
            if (found != null) return error.AmbiguousSymbol;
            found = .{ .declaration = declaration };
        }
        return found orelse error.SymbolNotFound;
    }

    fn tierOf(self: Table, ref: Ref) Tier {
        for (self.declarations) |declaration| {
            if (ref.abbreviates(declaration.ref) and declaration.ref.accessor == ref.accessor) return .same_accessor;
        }
        for (self.symbols) |symbol| {
            if (ref.abbreviates(symbol.ref) and symbol.ref.accessor == ref.accessor) return .same_accessor;
        }
        return .any_accessor;
    }

    fn classMatches(self: Table, ref: Ref) bool {
        for (self.declarations) |declaration| {
            if (declaration.kind == .class and ref.abbreviates(declaration.ref)) return true;
        }
        return false;
    }

    pub fn itemExact(self: Table, ref: Ref) ResolveError!Item {
        var found: ?Item = null;
        for (self.symbols) |*symbol| {
            if (!symbol.ref.eql(ref)) continue;
            if (found) |_| return error.AmbiguousSymbol;
            found = symbolItem(symbol);
        }
        if (found) |f| return f;
        for (self.declarations) |*declaration| {
            if (!declaration.ref.eql(ref)) continue;
            if (found) |_| return error.AmbiguousSymbol;
            found = declarationItem(declaration);
        }
        if (found) |f| return f;
        for (self.statements) |*statement| {
            if (!statement.ref.eql(ref)) continue;
            if (found != null or statement.ambiguous) return error.AmbiguousSymbol;
            found = .{ .ref = statement.ref, .role = switch (statement.kind) {
                .statement => .statement,
                .import => .import,
                .binding => .binding,
                .property => .property,
            }, .node = statement.node, .span = statement.declaration, .hash = statement.hash };
        }
        return found orelse error.SymbolNotFound;
    }

    pub fn hasDeclaration(self: Table, ref: Ref) bool {
        for (self.declarations) |declaration| {
            if (declaration.ref.eql(ref)) return true;
        }
        return false;
    }
};

pub const Candidate = struct { ref: Ref, line: u32 };

const Tier = enum { same_accessor, any_accessor };

fn shortHit(short: Ref, entry: anytype, tier: Tier) bool {
    var full = entry.ref;
    if (full.overload.len == 0) full.overload = entry.signature;
    if (!short.abbreviates(full)) return false;
    return tier == .any_accessor or short.accessor == full.accessor;
}

fn symbolItem(symbol: *const Symbol) Item {
    return .{ .ref = symbol.ref, .role = .symbol, .node = symbol.node, .span = symbol.declaration, .hash = symbol.hash, .body = symbol.body };
}

fn declarationItem(declaration: *const Declaration) Item {
    return .{ .ref = declaration.ref, .role = .declaration, .node = declaration.node, .span = declaration.declaration, .hash = declaration.hash };
}

fn sameSpan(a: Span, b: Span) bool {
    return a.start == b.start and a.end == b.end;
}

fn settleRefs(arena: Allocator, profile: *const Profile, tree: ts.Tree, items: anytype) Allocator.Error!void {
    if (profile.parameterKey) |key| {
        for (items) |*item| {
            if (item.ref.overload.len == 0) item.signature = try key(arena, tree, item.node, false) orelse "";
        }
        for ([_]bool{ false, true }) |full| {
            const clashing = try arena.alloc(bool, items.len);
            markClashes(items, clashing);
            for (items, clashing) |*item, clash| {
                if (!clash) continue;
                if (try key(arena, tree, item.node, full)) |text| item.ref.overload = text;
            }
        }
    }
    const clashing = try arena.alloc(bool, items.len);
    markClashes(items, clashing);
    for (items, clashing) |*item, clash| item.ambiguous = clash;
}

fn markClashes(items: anytype, clashing: []bool) void {
    @memset(clashing, false);
    for (items, 0..) |a, i| {
        for (items[i + 1 ..], i + 1..) |b, j| {
            if (!a.ref.eql(b.ref)) continue;
            clashing[i] = true;
            clashing[j] = true;
        }
    }
}

fn describe(arena: Allocator, profile: *const Profile, tree: ts.Tree, function: Function) Allocator.Error!?Symbol {
    const traits = profile.memberTraits(profile, tree, function.node, function.kind);
    const kind = symbolKind(function.kind, traits) orelse return null;
    const name = function.name orelse return null;
    const label = try labelOf(arena, profile, tree, nameOwner(profile, function.node));
    const chain = try statements_mod.topLevelChain(arena, profile, tree, name);
    if (label == null and chain == null and !isOneOf(name.kind(), profile.addressable_names)) return null;
    const outer = try containerPath(arena, profile, tree, function.node) orelse return null;
    const container = if (chain) |c| try std.mem.concat(arena, []const u8, &.{ outer, c[0 .. c.len - 1] }) else try qualifiedContainer(arena, profile, tree, function.node, outer);
    const declaration = declarationOf(profile, function);
    const overload: []const u8 = if (traits.overload_stub) stub: {
        const key = profile.parameterKey orelse break :stub "";
        break :stub try key(arena, tree, function.node, false) orelse "";
    } else "";
    return .{
        .ref = .{
            .container = container,
            .name = label orelse if (chain) |c| c[c.len - 1] else tree.text(name),
            .overload = overload,
            .accessor = traits.accessor,
            .is_static = traits.is_static,
        },
        .kind = kind,
        .node = function.node,
        .body = function.body,
        .declaration = declaration.span,
        .hash = declaration.hash(tree.source),
    };
}

fn nameOwner(profile: *const Profile, node: ts.Node) ts.Node {
    const named = profile.functionName(node.kind()) orelse return node;
    var owner = node;
    for (0..named.owner_depth) |_| owner = owner.parent() orelse return node;
    return owner;
}

fn labelOf(arena: Allocator, profile: *const Profile, tree: ts.Tree, node: ts.Node) Allocator.Error!?[]const u8 {
    const label = profile.memberLabel orelse return null;
    return label(arena, tree, node);
}

fn qualifiedContainer(arena: Allocator, profile: *const Profile, tree: ts.Tree, node: ts.Node, container: []const []const u8) Allocator.Error![]const []const u8 {
    const qualifier = profile.memberQualifier orelse return container;
    const named = qualifier(node) orelse return container;
    return std.mem.concat(arena, []const u8, &.{ container, &.{try profile_mod.compactSpelling(arena, tree.text(named))} });
}

fn memberKind(traits: MemberTraits) Kind {
    return switch (traits.accessor) {
        .get => .getter,
        .set => .setter,
        .delete, .add, .remove => .method,
        .none => if (traits.is_constructor) .constructor else .method,
    };
}

fn symbolKind(kind: FunctionKind, traits: MemberTraits) ?Kind {
    return switch (kind) {
        .declaration => if (traits.is_member) memberKind(traits) else .function,
        .generator_declaration, .generator_expression => .generator,
        .expression => .function_expression,
        .arrow => .arrow,
        .static_block => null,
        .method => memberKind(traits),
    };
}

const ContainerRole = union(enum) {
    transparent,
    unnamed,
    named: ts.Node,
};

fn containerRole(profile: *const Profile, node: ts.Node) ContainerRole {
    const name: ?ts.Node = if (classify(profile, node)) |function|
        function.name
    else if (profile.containerName(node.kind())) |source| switch (source) {
        .field => node.childByField("name"),
        .field_or_binding => node.childByField("name") orelse bindingName(profile, node),
        .binding => bindingName(profile, node),
    } else return .transparent;
    return if (name) |n| .{ .named = n } else .unnamed;
}

fn containerPath(arena: Allocator, profile: *const Profile, tree: ts.Tree, node: ts.Node) Allocator.Error!?[]const []const u8 {
    var reversed: std.ArrayList([]const u8) = .empty;
    var current = nameOwner(profile, node).parent();
    while (current) |ancestor| : (current = ancestor.parent()) {
        if (try labelOf(arena, profile, tree, ancestor)) |label| {
            try reversed.append(arena, label);
            continue;
        }
        const name = switch (containerRole(profile, ancestor)) {
            .transparent => continue,
            .unnamed => return null,
            .named => |name| name,
        };
        const first = reversed.items.len;
        if (try statements_mod.topLevelChain(arena, profile, tree, name)) |chain| {
            try reversed.appendSlice(arena, chain);
        } else {
            if (!isOneOf(name.kind(), profile.addressable_names) and !profile.isDottedName(name.kind())) return null;
            try appendNameSegments(arena, profile, tree, name, &reversed);
        }
        std.mem.reverse([]const u8, reversed.items[first..]);
    }
    if (fileScopedName(profile, node)) |name| {
        if (!isOneOf(name.kind(), profile.addressable_names) and !profile.isDottedName(name.kind())) return null;
        const first = reversed.items.len;
        try appendNameSegments(arena, profile, tree, name, &reversed);
        std.mem.reverse([]const u8, reversed.items[first..]);
    }
    std.mem.reverse([]const u8, reversed.items);
    return reversed.items;
}

pub fn fileScopedName(profile: *const Profile, node: ts.Node) ?ts.Node {
    if (profile.file_scoped_containers.len == 0) return null;
    var top = node;
    while (top.parent()) |parent| {
        if (parent.parent() == null) break;
        top = parent;
    }
    var prev = top.prevNamedSibling();
    while (prev) |sibling| : (prev = sibling.prevNamedSibling()) {
        if (isOneOf(sibling.kind(), profile.file_scoped_containers)) return sibling.childByField("name");
    }
    return null;
}

const Extent = struct {
    span: Span,
    prefix: Span = .{ .start = 0, .end = 0 },

    fn hash(self: Extent, source: []const u8) Hash {
        var hasher = std.crypto.hash.Blake3.init(.{});
        hasher.update(source[self.prefix.start..self.prefix.end]);
        hasher.update(source[self.span.start..self.span.end]);
        var out: Hash = undefined;
        hasher.final(&out);
        return out;
    }
};

fn declarationOf(profile: *const Profile, function: Function) Extent {
    const site = bindingSite(profile, function.node);
    const own = site orelse function.node;
    var statement: ?ts.Node = null;
    var above = own.parent();
    while (above) |parent| : (above = parent.parent()) {
        if (!isOneOf(parent.kind(), profile.declaration_statements)) break;
        statement = parent;
    }
    var outer = statement orelse own;
    if (outer.parent()) |parent| {
        if (isOneOf(parent.kind(), profile.export_wrappers)) outer = parent;
    }

    const shared = if (statement) |s| site != null and declaratorCount(profile, s) > 1 else false;
    if (!shared) return .{ .span = .{ .start = leadingDecoratorStart(profile, outer), .end = outer.endByte() } };
    return .{
        .span = .{ .start = own.startByte(), .end = own.endByte() },
        .prefix = .{ .start = outer.startByte(), .end = firstDeclaratorStart(profile, statement.?) },
    };
}

fn declaratorCount(profile: *const Profile, statement: ts.Node) u32 {
    var count: u32 = 0;
    var i: u32 = 0;
    while (statement.namedChild(i)) |child| : (i += 1) {
        if (std.mem.eql(u8, profile.declarator, child.kind())) count += 1;
        if (isOneOf(child.kind(), profile.declaration_statements)) count += declaratorCount(profile, child);
    }
    return count;
}

fn firstDeclaratorStart(profile: *const Profile, statement: ts.Node) u32 {
    var i: u32 = 0;
    while (statement.namedChild(i)) |child| : (i += 1) {
        if (std.mem.eql(u8, profile.declarator, child.kind())) return child.startByte();
        if (isOneOf(child.kind(), profile.declaration_statements)) return firstDeclaratorStart(profile, child);
    }
    return statement.startByte();
}

fn leadingDecoratorStart(profile: *const Profile, node: ts.Node) u32 {
    var start = node.startByte();
    var prev = node.prevNamedSibling();
    while (prev) |sibling| : (prev = sibling.prevNamedSibling()) {
        if (profile.isComment(sibling.kind())) continue;
        if (!std.mem.eql(u8, profile.decorator, sibling.kind())) break;
        start = sibling.startByte();
    }
    return start;
}

fn appendNameSegments(arena: Allocator, profile: *const Profile, tree: ts.Tree, name: ts.Node, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    if (!profile.isDottedName(name.kind())) return out.append(arena, tree.text(name));
    var walker = traversal.Walker.init(name);
    defer walker.deinit();
    while (walker.next()) |entry| {
        const node = entry.node;
        if (node.childCount() == 0 and isOneOf(node.kind(), profile.name_segments)) {
            try out.append(arena, tree.text(node));
        }
    }
}
