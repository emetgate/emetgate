const std = @import("std");
const ts = @import("tree_sitter.zig");
const traversal = @import("traversal.zig");
const functions_mod = @import("functions.zig");
const ref_mod = @import("ref.zig");
const profile_mod = @import("lang/profile.zig");

const Allocator = std.mem.Allocator;
const Profile = profile_mod.Profile;
const MemberTraits = profile_mod.MemberTraits;

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
    const traits = profile.memberTraits(profile, tree, function.node, function.kind);
    const kind = symbolKind(function.kind, traits) orelse return null;
    const name = function.name orelse return null;
    if (!isOneOf(name.kind(), profile.addressable_names)) return null;
    const container = try containerPath(arena, profile, tree, function.node) orelse return null;
    const declaration = declarationOf(profile, function);
    return .{
        .ref = .{
            .container = container,
            .name = tree.text(name),
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

fn symbolKind(kind: FunctionKind, traits: MemberTraits) ?Kind {
    return switch (kind) {
        .declaration => .function,
        .generator_declaration, .generator_expression => .generator,
        .expression => .function_expression,
        .arrow => .arrow,
        .static_block => null,
        .method => switch (traits.accessor) {
            .get => .getter,
            .set => .setter,
            .none => if (traits.is_constructor) .constructor else .method,
        },
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
    var current = node.parent();
    while (current) |ancestor| : (current = ancestor.parent()) {
        const name = switch (containerRole(profile, ancestor)) {
            .transparent => continue,
            .unnamed => return null,
            .named => |name| name,
        };
        if (!isOneOf(name.kind(), profile.addressable_names) and !profile.isDottedName(name.kind())) return null;
        const first = reversed.items.len;
        try appendNameSegments(arena, profile, tree, name, &reversed);
        std.mem.reverse([]const u8, reversed.items[first..]);
    }
    std.mem.reverse([]const u8, reversed.items);
    return reversed.items;
}

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
        if (isOneOf(parent.kind(), profile.declaration_statements)) statement = parent;
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
    }
    return count;
}

fn firstDeclaratorStart(profile: *const Profile, statement: ts.Node) u32 {
    var i: u32 = 0;
    while (statement.namedChild(i)) |child| : (i += 1) {
        if (std.mem.eql(u8, profile.declarator, child.kind())) return child.startByte();
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
