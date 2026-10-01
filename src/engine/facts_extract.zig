const std = @import("std");
const ts = @import("tree_sitter.zig");
const symbol = @import("symbol.zig");
const traversal = @import("traversal.zig");
const scope = @import("scope.zig");
const modules = @import("modules.zig");
const alpha = @import("alpha.zig");
const functions = @import("functions.zig");
const facts = @import("facts.zig");
const profile_mod = @import("lang/profile.zig");
const Snapshot = @import("loader.zig").Snapshot;

const Allocator = std.mem.Allocator;
const Profile = profile_mod.Profile;
const Rename = profile_mod.Rename;
const Facts = profile_mod.Facts;
const Modules = profile_mod.Modules;
const none = facts.none;

pub const Error = error{ UnsupportedLanguage, UseNotRevisited } || Allocator.Error;

fn oneOf(kind: []const u8, kinds: []const []const u8) bool {
    for (kinds) |candidate| {
        if (std.mem.eql(u8, candidate, kind)) return true;
    }
    return false;
}

fn lineOf(node: ts.Node) u32 {
    return node.startPoint().row + 1;
}

fn defKindOf(kind: symbol.Kind) facts.DefKind {
    return switch (kind) {
        .function => .function,
        .generator => .generator,
        .method => .method,
        .getter => .getter,
        .setter => .setter,
        .constructor => .constructor,
        .arrow => .arrow,
        .function_expression => .function_expression,
    };
}

fn declKindOf(kind: profile_mod.DeclarationKind) facts.DefKind {
    return switch (kind) {
        .class => .class,
        .variable => .variable,
        .interface => .interface,
        .type_alias => .type_alias,
        .enumeration => .enumeration,
        .field => .field,
        .enum_member => .enum_member,
    };
}

const Draft = struct {
    def: facts.Def,
    node_start: u32,
};

fn draftLess(_: void, a: Draft, b: Draft) bool {
    if (a.def.span.start != b.def.span.start) return a.def.span.start < b.def.span.start;
    return a.def.span.end > b.def.span.end;
}

const Step = struct {
    node: ts.Node,
    field: ?[]const u8,
    errors: u32,
};

const Enclosing = struct { def: u32, is_static: bool };

const Extractor = struct {
    arena: Allocator,
    snapshot: *const Snapshot,
    profile: *const Profile,
    g: *const Rename,
    f: *const Facts,
    m: *const Modules,
    defs: std.ArrayList(facts.Def) = .empty,
    refs: std.ArrayList(facts.Ref) = .empty,
    specs: std.ArrayList(facts.Spec) = .empty,
    bindings: std.ArrayList(facts.Binding) = .empty,
    exports: std.ArrayList(facts.Export) = .empty,
    types: std.ArrayList(facts.TypeRef) = .empty,
    classes: std.ArrayList(facts.Class) = .empty,
    member_types: std.ArrayList(facts.MemberType) = .empty,
    loose: std.StringArrayHashMapUnmanaged(u32) = .empty,
    dynamic_reads: u32 = 0,
    module_mode: bool = false,
    every: scope.Every = undefined,
    use_at: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    def_at_name: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    def_at_node: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    binding_at: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    typed_at: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    skipped_uses: std.AutoHashMapUnmanaged(u32, void) = .empty,
    path: std.ArrayList(Step) = .empty,
    owners: std.ArrayList(u32) = .empty,
    next_owner: usize = 1,
    strings: std.StringHashMapUnmanaged([]const u8) = .empty,
    line_starts: []const u32 = &.{},

    fn keep(self: *Extractor, slice: []const u8) Error![]const u8 {
        if (self.strings.get(slice)) |kept| return kept;
        const kept = try self.arena.dupe(u8, slice);
        try self.strings.put(self.arena, kept, kept);
        return kept;
    }

    fn raw(self: *const Extractor, node: ts.Node) []const u8 {
        return self.snapshot.source[node.startByte()..node.endByte()];
    }

    fn text(self: *Extractor, node: ts.Node) Error![]const u8 {
        return self.keep(self.raw(node));
    }

    fn indexLines(self: *Extractor) Error!void {
        var starts: std.ArrayList(u32) = .empty;
        try starts.append(self.arena, 0);
        for (self.snapshot.source, 0..) |byte, i| {
            if (byte == '\n') try starts.append(self.arena, @intCast(i + 1));
        }
        self.line_starts = starts.items;
    }

    fn lineAt(self: *const Extractor, offset: u32) u32 {
        var low: usize = 0;
        var high: usize = self.line_starts.len;
        while (high - low > 1) {
            const mid = low + (high - low) / 2;
            if (self.line_starts[mid] <= offset) low = mid else high = mid;
        }
        return @intCast(low + 1);
    }

    fn collectDefs(self: *Extractor) Error!void {
        const table = try symbol.Table.buildTolerant(self.arena, self.profile, self.snapshot.tree);
        var drafts: std.ArrayList(Draft) = .empty;
        for (table.symbols) |s| {
            const function = functions.classify(self.profile, s.node) orelse continue;
            const name = function.name orelse continue;
            try drafts.append(self.arena, .{ .node_start = s.node.startByte(), .def = .{
                .kind = defKindOf(s.kind),
                .name = try self.text(name),
                .qname = try std.fmt.allocPrint(self.arena, "{f}", .{s.ref}),
                .parent = none,
                .span = s.declaration,
                .name_start = name.startByte(),
                .line = lineOf(name),
                .hash = s.hash,
                .alpha = try alpha.hash(self.arena, self.snapshot, s.declaration),
                .is_static = s.ref.is_static,
            } });
        }
        for (table.declarations) |d| {
            try drafts.append(self.arena, .{ .node_start = d.node.startByte(), .def = .{
                .kind = declKindOf(d.kind),
                .name = try self.text(d.name),
                .qname = try std.fmt.allocPrint(self.arena, "{f}", .{d.ref}),
                .parent = none,
                .span = d.declaration,
                .name_start = d.name.startByte(),
                .line = lineOf(d.name),
                .hash = d.hash,
                .alpha = try alpha.hash(self.arena, self.snapshot, d.declaration),
                .is_static = d.ref.is_static,
            } });
        }
        std.mem.sort(Draft, drafts.items, {}, draftLess);
        const source = self.snapshot.source;
        try self.defs.append(self.arena, .{
            .kind = .module,
            .name = "",
            .qname = "",
            .parent = none,
            .span = .{ .start = 0, .end = @intCast(source.len) },
            .name_start = 0,
            .line = 1,
            .hash = symbol.fileHash(source),
            .alpha = std.mem.zeroes(facts.Hash),
        });
        var stack: std.ArrayList(u32) = .empty;
        for (drafts.items) |draft| {
            var def = draft.def;
            while (stack.items.len != 0) {
                const top = self.defs.items[stack.items[stack.items.len - 1]];
                if (def.span.start >= top.span.start and def.span.end <= top.span.end) break;
                _ = stack.pop();
            }
            def.parent = if (stack.items.len == 0) 0 else stack.items[stack.items.len - 1];
            const index: u32 = @intCast(self.defs.items.len);
            try self.defs.append(self.arena, def);
            try stack.append(self.arena, index);
            try self.def_at_name.put(self.arena, def.name_start, index);
            try self.def_at_node.put(self.arena, draft.node_start, index);
        }
    }

    fn indexUses(self: *Extractor) Error!void {
        for (self.every.uses, 0..) |use, i| try self.use_at.put(self.arena, use.span.start, @intCast(i));
    }

    fn binderOfUse(self: *const Extractor, start: u32) ?u32 {
        const at = self.use_at.get(start) orelse return null;
        const binder = self.every.uses[at].binder orelse return null;
        return self.every.binders[binder].span.start;
    }

    fn targetOfBinder(self: *const Extractor, binder_start: u32) ?facts.Target {
        if (self.binding_at.get(binder_start)) |b| return .{ .binding = b };
        if (self.def_at_name.get(binder_start)) |d| return .{ .local = d };
        return null;
    }

    fn collectImports(self: *Extractor) Error!void {
        const imported = try modules.imports(self.arena, self.snapshot);
        for (imported) |entry| {
            self.module_mode = true;
            const spec: u32 = @intCast(self.specs.items.len);
            try self.specs.append(self.arena, .{ .text = try self.keep(entry.spec), .line = self.lineAt(entry.statement.start), .kind = .static });
            switch (entry.form) {
                .bare => {},
                .import => {
                    if (entry.default_name) |name| {
                        const b = try self.addBinding(spec, self.m.default_keyword, name, entry.default_start, entry.type_only);
                        try self.addImportRef(self.m.default_keyword, entry.default_start, b);
                    }
                    if (entry.namespace) |name| _ = try self.addBinding(spec, facts.namespace_name, name, entry.namespace_start, entry.type_only);
                    for (entry.named) |named| {
                        const b = try self.addBinding(spec, named.name, named.local(), named.local_start, entry.type_only or named.type_only);
                        try self.addImportRef(named.name, named.name_start, b);
                    }
                },
                .reexport => for (entry.named) |named| {
                    const b = try self.addBinding(spec, named.name, "", named.name_start, entry.type_only or named.type_only);
                    try self.exports.append(self.arena, .{ .name = try self.keep(named.alias orelse named.name), .kind = .binding, .index = b });
                    try self.addImportRef(named.name, named.name_start, b);
                },
                .star_reexport => {
                    if (entry.namespace) |name| {
                        const b = try self.addBinding(spec, facts.namespace_name, "", entry.namespace_start, entry.type_only);
                        try self.exports.append(self.arena, .{ .name = try self.keep(name), .kind = .binding, .index = b });
                    } else {
                        try self.exports.append(self.arena, .{ .name = facts.namespace_name, .kind = .star, .index = spec });
                    }
                },
            }
        }
    }

    fn addBinding(self: *Extractor, spec: u32, imported: []const u8, local: []const u8, start: u32, type_only: bool) Error!u32 {
        const index: u32 = @intCast(self.bindings.items.len);
        try self.bindings.append(self.arena, .{ .spec = spec, .imported = try self.keep(imported), .local = try self.keep(local), .start = start, .type_only = type_only });
        if (local.len != 0) try self.binding_at.put(self.arena, start, index);
        return index;
    }

    fn addImportRef(self: *Extractor, name: []const u8, start: u32, binding: u32) Error!void {
        try self.refs.append(self.arena, .{
            .from = 0,
            .kind = .import,
            .name = try self.keep(name),
            .start = start,
            .line = self.lineAt(start),
            .target = .{ .binding = binding },
        });
    }

    fn addType(self: *Extractor, t: facts.TypeRef) Error!u32 {
        const index: u32 = @intCast(self.types.items.len);
        try self.types.append(self.arena, t);
        return index;
    }

    fn typeRefOfName(self: *Extractor, node: ts.Node) Error!?u32 {
        const kind = node.kind();
        if (std.mem.eql(u8, kind, self.profile.identifier) or oneOf(kind, self.g.type_kinds)) {
            const binder = self.binderOfUse(node.startByte()) orelse return null;
            const target = self.targetOfBinder(binder) orelse return null;
            return try self.addType(.{ .target = target });
        }
        if (self.f.qualified_type) |qualified| if (std.mem.eql(u8, kind, qualified)) {
            const module = node.childByField(self.f.qualified_module_field) orelse return null;
            const name = node.childByField(self.f.qualified_name_field) orelse return null;
            return try self.memberTypeRef(module, try self.text(name));
        };
        if (std.mem.eql(u8, kind, self.f.member)) {
            const object = node.childByField(self.f.object_field) orelse return null;
            const property = node.childByField(self.f.property_field) orelse return null;
            return try self.memberTypeRef(object, try self.text(property));
        }
        if (self.f.generic_type) |generic| if (std.mem.eql(u8, kind, generic)) {
            const name = node.childByField(self.f.generic_name_field) orelse return null;
            return self.typeRefOfName(name);
        };
        return null;
    }

    fn memberTypeRef(self: *Extractor, owner: ts.Node, member_name: []const u8) Error!?u32 {
        if (!std.mem.eql(u8, owner.kind(), self.profile.identifier)) return null;
        const binder = self.binderOfUse(owner.startByte()) orelse return null;
        const target = self.targetOfBinder(binder) orelse return null;
        return switch (target) {
            .binding => |b| try self.addType(.{ .target = .{ .member_of_binding = b }, .member = member_name }),
            .local => |d| try self.addType(.{ .target = .{ .member_of_def = d }, .member = member_name }),
            else => null,
        };
    }

    fn annotatedType(self: *Extractor, holder: ts.Node, type_field: []const u8) Error!?u32 {
        const annotation_kind = self.f.type_annotation orelse return null;
        const annotation = holder.childByField(type_field) orelse return null;
        if (!std.mem.eql(u8, annotation.kind(), annotation_kind)) return null;
        const inner = annotation.namedChild(0) orelse return null;
        return self.typeRefOfName(inner);
    }

    fn constructedType(self: *Extractor, declarator: ts.Node) Error!?u32 {
        var value = declarator.childByField("value") orelse return null;
        while (oneOf(value.kind(), self.profile.transparent_wrappers)) value = value.namedChild(0) orelse return null;
        if (!std.mem.eql(u8, value.kind(), self.g.new_expression)) return null;
        const constructor = value.childByField(self.g.new_constructor_field) orelse return null;
        return self.typeRefOfName(constructor);
    }

    fn collectShapes(self: *Extractor) Error!void {
        var walker = traversal.Walker.init(self.snapshot.tree.root());
        defer walker.deinit();
        while (walker.next()) |entry| {
            const node = entry.node;
            const kind = node.kind();
            if (self.profile.isComment(kind) or oneOf(kind, self.profile.strings)) {
                walker.skipChildren();
                continue;
            }
            for (self.f.typed_binders) |site| {
                if (!std.mem.eql(u8, site.node, kind)) continue;
                const name = node.childByField(site.name_field) orelse continue;
                if (!std.mem.eql(u8, name.kind(), self.profile.identifier)) continue;
                const declared = (try self.annotatedType(node, site.type_field)) orelse continue;
                try self.typed_at.put(self.arena, name.startByte(), declared);
            }
            if (std.mem.eql(u8, kind, self.profile.declarator)) {
                if (node.childByField("name")) |name| {
                    if (std.mem.eql(u8, name.kind(), self.profile.identifier) and !self.typed_at.contains(name.startByte())) {
                        if (try self.constructedType(node)) |constructed| try self.typed_at.put(self.arena, name.startByte(), constructed);
                    }
                }
            }
            if (node.isNamed() and oneOf(kind, self.f.classes)) try self.classShape(node);
        }
    }

    fn classShape(self: *Extractor, class: ts.Node) Error!void {
        const def = self.classDef(class) orelse return;
        var base: u32 = none;
        var i: u32 = 0;
        while (class.namedChild(i)) |child| : (i += 1) {
            if (!std.mem.eql(u8, child.kind(), self.f.heritage)) continue;
            const value = self.heritageValue(child) orelse continue;
            base = (try self.typeRefOfName(value)) orelse try self.addType(.{ .target = .{ .unresolved = .dynamic_call } });
        }
        try self.classes.append(self.arena, .{ .def = def, .base = base });
        const body = class.childByField("body") orelse return;
        var j: u32 = 0;
        while (body.namedChild(j)) |member_node| : (j += 1) {
            if (oneOf(member_node.kind(), self.f.class_fields)) {
                const name = member_node.childByField("name") orelse continue;
                const declared = (try self.annotatedType(member_node, "type")) orelse continue;
                try self.member_types.append(self.arena, .{ .class = def, .name = try self.text(name), .is_static = self.isStatic(member_node), .type = declared });
                continue;
            }
            if (self.profile.functionKind(member_node.kind()) == null) continue;
            const traits = self.profile.memberTraits(self.profile, self.snapshot.tree, member_node, .method);
            if (!traits.is_constructor) continue;
            try self.parameterProperties(def, member_node);
        }
    }

    fn parameterProperties(self: *Extractor, class_def: u32, constructor: ts.Node) Error!void {
        const parameters = constructor.childByField("parameters") orelse return;
        var i: u32 = 0;
        while (parameters.namedChild(i)) |parameter| : (i += 1) {
            if (!oneOf(parameter.kind(), self.f.parameter_properties)) continue;
            if (!self.hasPropertyMarker(parameter)) continue;
            const name = parameter.childByField("pattern") orelse continue;
            if (!std.mem.eql(u8, name.kind(), self.profile.identifier)) continue;
            const declared = (try self.annotatedType(parameter, "type")) orelse continue;
            try self.member_types.append(self.arena, .{ .class = class_def, .name = try self.text(name), .is_static = false, .type = declared });
        }
    }

    fn isStatic(self: *const Extractor, node: ts.Node) bool {
        const keyword = self.profile.declarations.static_keyword orelse return false;
        return hasToken(node, keyword);
    }

    fn hasPropertyMarker(self: *const Extractor, parameter: ts.Node) bool {
        var i: u32 = 0;
        while (parameter.child(i)) |child| : (i += 1) {
            if (oneOf(child.kind(), self.f.property_markers)) return true;
        }
        return false;
    }

    fn heritageValue(self: *const Extractor, heritage: ts.Node) ?ts.Node {
        const clause_kind = self.f.extends_clause orelse return heritage.namedChild(0);
        var i: u32 = 0;
        while (heritage.namedChild(i)) |child| : (i += 1) {
            if (std.mem.eql(u8, child.kind(), clause_kind)) return child.childByField(self.f.extends_value_field);
        }
        return null;
    }

    fn classDef(self: *const Extractor, class: ts.Node) ?u32 {
        if (self.def_at_node.get(class.startByte())) |d| {
            if (self.defs.items[d].kind == .class) return d;
        }
        const parent = class.parent() orelse return null;
        if (!std.mem.eql(u8, parent.kind(), self.profile.declarator)) return null;
        const name = parent.childByField("name") orelse return null;
        return self.def_at_name.get(name.startByte());
    }

    fn collectExports(self: *Extractor) Error!void {
        const root = self.snapshot.tree.root();
        var i: u32 = 0;
        while (root.namedChild(i)) |statement| : (i += 1) {
            if (!std.mem.eql(u8, statement.kind(), self.m.export_statement)) continue;
            self.module_mode = true;
            if (statement.childByField(self.m.source_field) != null) continue;
            const is_default = modules.exportsDefault(self.snapshot, statement);
            if (statement.childByField(self.f.export_declaration_field) != null) {
                for (self.defs.items, 0..) |*def, d| {
                    if (def.parent != 0) continue;
                    if (def.span.start < statement.startByte() or def.span.end > statement.endByte()) continue;
                    def.exported = true;
                    try self.exports.append(self.arena, .{ .name = if (is_default) self.m.default_keyword else def.name, .kind = .local, .index = @intCast(d) });
                }
                continue;
            }
            if (statement.childByField(self.f.export_value_field)) |value| {
                if (is_default) try self.exportName(self.m.default_keyword, value);
                continue;
            }
            var j: u32 = 0;
            while (statement.namedChild(j)) |clause| : (j += 1) {
                if (!std.mem.eql(u8, clause.kind(), self.m.export_clause)) continue;
                var k: u32 = 0;
                while (clause.namedChild(k)) |specifier| : (k += 1) {
                    if (!std.mem.eql(u8, specifier.kind(), self.m.export_specifier)) continue;
                    const name = specifier.childByField(self.m.name_field) orelse continue;
                    const exported = if (specifier.childByField(self.m.alias_field)) |a| try self.text(a) else try self.text(name);
                    try self.exportName(exported, name);
                }
            }
        }
    }

    fn exportName(self: *Extractor, exported: []const u8, local: ts.Node) Error!void {
        if (!std.mem.eql(u8, local.kind(), self.profile.identifier)) return;
        const binder = self.binderOfUse(local.startByte()) orelse return;
        const target = self.targetOfBinder(binder) orelse return;
        switch (target) {
            .local => |d| {
                self.defs.items[d].exported = true;
                try self.exports.append(self.arena, .{ .name = exported, .kind = .local, .index = d });
            },
            .binding => |b| try self.exports.append(self.arena, .{ .name = exported, .kind = .binding, .index = b }),
            else => {},
        }
    }

    fn ownerAt(self: *Extractor, position: u32) Error!u32 {
        const defs = self.defs.items;
        while (self.owners.items.len != 0 and defs[self.owners.items[self.owners.items.len - 1]].span.end <= position) _ = self.owners.pop();
        while (self.next_owner < defs.len and defs[self.next_owner].span.start <= position) {
            const next: u32 = @intCast(self.next_owner);
            self.next_owner += 1;
            while (self.owners.items.len != 0 and defs[self.owners.items[self.owners.items.len - 1]].span.end <= defs[next].span.start) _ = self.owners.pop();
            try self.owners.append(self.arena, next);
            while (self.owners.items.len != 0 and defs[self.owners.items[self.owners.items.len - 1]].span.end <= position) _ = self.owners.pop();
        }
        return if (self.owners.items.len == 0) 0 else self.owners.items[self.owners.items.len - 1];
    }

    fn roleAt(self: *const Extractor, depth: usize, field: ?[]const u8) facts.RefKind {
        var at = depth;
        var own_field = field;
        while (at > 0 and oneOf(self.path.items[at - 1].node.kind(), self.profile.transparent_wrappers)) {
            own_field = self.path.items[at - 1].field;
            at -= 1;
        }
        if (at == 0) return .read;
        const parent = self.path.items[at - 1].node.kind();
        const held = own_field orelse return .read;
        if (std.mem.eql(u8, parent, self.profile.call.node) and std.mem.eql(u8, held, self.profile.call.function_field)) return .call;
        if (std.mem.eql(u8, parent, self.g.new_expression) and std.mem.eql(u8, held, self.g.new_constructor_field)) return .new;
        for (self.f.writes) |site| {
            if (std.mem.eql(u8, parent, site.parent) and std.mem.eql(u8, held, site.field)) return .write;
        }
        for (self.f.call_like) |site| {
            if (std.mem.eql(u8, parent, site.parent) and std.mem.eql(u8, held, site.field)) return .call;
        }
        return .read;
    }

    fn inError(self: *const Extractor) bool {
        if (self.path.items.len == 0) return false;
        return self.path.items[self.path.items.len - 1].errors != 0;
    }

    fn enclosingClass(self: *const Extractor) ?Enclosing {
        var i = self.path.items.len;
        while (i > 0) : (i -= 1) {
            const node = self.path.items[i - 1].node;
            const kind = node.kind();
            if (self.profile.functionKind(kind)) |function_kind| {
                switch (function_kind) {
                    .arrow => continue,
                    .method, .static_block => {
                        if (i < 3) return null;
                        const def = self.classDef(self.path.items[i - 3].node) orelse return null;
                        const is_static = function_kind == .static_block or self.profile.memberTraits(self.profile, self.snapshot.tree, node, .method).is_static;
                        return .{ .def = def, .is_static = is_static };
                    },
                    else => return null,
                }
            }
            if (oneOf(kind, self.f.class_fields)) {
                if (i < 3) return null;
                const def = self.classDef(self.path.items[i - 3].node) orelse return null;
                return .{ .def = def, .is_static = self.isStatic(node) };
            }
        }
        return null;
    }

    fn addRef(self: *Extractor, ref: facts.Ref) Error!void {
        try self.refs.append(self.arena, ref);
    }

    fn addLoose(self: *Extractor, name: []const u8) Error!void {
        const slot = try self.loose.getOrPut(self.arena, name);
        if (!slot.found_existing) slot.value_ptr.* = 0;
        slot.value_ptr.* += 1;
    }

    fn strip(self: *const Extractor, node: ts.Node) ts.Node {
        var current = node;
        while (oneOf(current.kind(), self.profile.transparent_wrappers)) current = current.namedChild(0) orelse return current;
        return current;
    }

    fn memberTarget(self: *Extractor, object: ts.Node) Error!facts.Target {
        const kind = object.kind();
        if (std.mem.eql(u8, kind, self.g.new_expression)) {
            const constructor = object.childByField(self.g.new_constructor_field) orelse return .{ .unresolved = .property_needs_type };
            const constructed = (try self.typeRefOfName(constructor)) orelse return .{ .unresolved = .property_needs_type };
            return .{ .member_of_type = constructed };
        }
        if (std.mem.eql(u8, kind, self.f.this_keyword)) {
            const class = self.enclosingClass() orelse return .{ .unresolved = .dynamic_this };
            return .{ .member_of_def = class.def };
        }
        if (std.mem.eql(u8, kind, self.f.super_keyword)) {
            const class = self.enclosingClass() orelse return .{ .unresolved = .dynamic_this };
            return .{ .member_of_super = class.def };
        }
        if (std.mem.eql(u8, kind, self.profile.identifier)) {
            const at = self.use_at.get(object.startByte()) orelse return .{ .unresolved = .property_needs_type };
            const binder_index = self.every.uses[at].binder orelse return .{ .unresolved = .global };
            const binder = self.every.binders[binder_index].span.start;
            if (self.binding_at.get(binder)) |b| return .{ .member_of_binding = b };
            if (self.typed_at.get(binder)) |t| return .{ .member_of_type = t };
            if (self.def_at_name.get(binder)) |d| return .{ .member_of_def = d };
            return .{ .unresolved = .property_needs_type };
        }
        if (std.mem.eql(u8, kind, self.f.member)) {
            const inner = object.childByField(self.f.object_field) orelse return .{ .unresolved = .property_needs_type };
            const property = object.childByField(self.f.property_field) orelse return .{ .unresolved = .property_needs_type };
            if (!std.mem.eql(u8, self.strip(inner).kind(), self.f.this_keyword)) return .{ .unresolved = .property_needs_type };
            const class = self.enclosingClass() orelse return .{ .unresolved = .dynamic_this };
            const name = self.raw(property);
            for (self.member_types.items) |mt| {
                if (mt.class == class.def and std.mem.eql(u8, mt.name, name)) return .{ .member_of_type = mt.type };
            }
            return .{ .unresolved = .property_needs_type };
        }
        return .{ .unresolved = .property_needs_type };
    }

    fn member(self: *Extractor, node: ts.Node, depth: usize, field: ?[]const u8) Error!void {
        const object_node = node.childByField(self.f.object_field) orelse return;
        const property = node.childByField(self.f.property_field) orelse return;
        const role = self.roleAt(depth, field);
        const name = try self.text(property);
        const start = property.startByte();
        const from = try self.ownerAt(node.startByte());
        if (self.inError()) return self.addRef(.{ .from = from, .kind = role, .name = name, .start = start, .line = lineOf(property), .target = .{ .unresolved = .parse_error } });
        const object = self.strip(object_node);
        const target = try self.memberTarget(object);
        var is_static = false;
        const object_kind = object.kind();
        if (std.mem.eql(u8, object_kind, self.f.this_keyword) or std.mem.eql(u8, object_kind, self.f.super_keyword)) {
            if (self.enclosingClass()) |class| is_static = class.is_static;
        } else switch (target) {
            .member_of_def => |d| is_static = self.defs.items[d].kind == .class,
            else => {},
        }
        switch (target) {
            .unresolved => |reason| {
                if (reason == .global) return;
                if (role.invokes()) return self.addRef(.{ .from = from, .kind = role, .name = name, .start = start, .line = lineOf(property), .target = target });
                return self.addLoose(name);
            },
            else => return self.addRef(.{ .from = from, .kind = role, .name = name, .start = start, .line = lineOf(property), .target = target, .static = is_static }),
        }
    }

    fn qualifiedType(self: *Extractor, node: ts.Node) Error!void {
        const module = node.childByField(self.f.qualified_module_field) orelse return;
        const name = node.childByField(self.f.qualified_name_field) orelse return;
        const start = name.startByte();
        try self.skipped_uses.put(self.arena, start, {});
        const from = try self.ownerAt(node.startByte());
        if (!std.mem.eql(u8, module.kind(), self.profile.identifier)) return;
        const binder = self.binderOfUse(module.startByte()) orelse return;
        const target: facts.Target = if (self.binding_at.get(binder)) |b| .{ .member_of_binding = b } else if (self.def_at_name.get(binder)) |d| .{ .member_of_def = d } else return;
        try self.addRef(.{ .from = from, .kind = .type, .name = try self.text(name), .start = start, .line = lineOf(name), .target = target, .static = true });
    }

    fn call(self: *Extractor, node: ts.Node) Error!void {
        const callee = node.childByField(self.profile.call.function_field) orelse return;
        const kind = callee.kind();
        const start = callee.startByte();
        const from = try self.ownerAt(node.startByte());
        if (std.mem.eql(u8, kind, self.g.subscript)) {
            const index = callee.childByField(self.g.subscript_index_field);
            const name = if (index) |ix| (if (oneOf(ix.kind(), self.profile.strings)) try self.keep(unquote(self.raw(ix))) else "") else "";
            return self.addRef(.{ .from = from, .kind = .call, .name = name, .start = start, .line = lineOf(callee), .target = .{ .unresolved = .dynamic_access } });
        }
        if (!oneOf(self.raw(callee), self.g.module_callees)) return;
        if (std.mem.eql(u8, kind, self.profile.identifier) and self.binderOfUse(start) != null) return;
        const arguments = node.childByField(self.profile.call.arguments_field);
        const first = if (arguments) |a| a.namedChild(0) else null;
        if (first) |literal| {
            if (std.mem.eql(u8, literal.kind(), self.g.literal_argument) and arguments.?.namedChildCount() == 1) {
                self.module_mode = true;
                try self.specs.append(self.arena, .{ .text = try self.keep(unquote(self.raw(literal))), .line = lineOf(literal), .kind = .dynamic });
                return;
            }
        }
        try self.addRef(.{ .from = from, .kind = .call, .name = "", .start = start, .line = lineOf(callee), .target = .{ .unresolved = .computed_import } });
    }

    fn isExportSpecifier(self: *const Extractor, depth: usize, field: ?[]const u8) bool {
        if (depth == 0) return false;
        const parent = self.path.items[depth - 1].node.kind();
        const held = field orelse return false;
        return std.mem.eql(u8, parent, self.m.export_specifier) and std.mem.eql(u8, held, self.m.name_field);
    }

    fn identifier(self: *Extractor, node: ts.Node, depth: usize, field: ?[]const u8) Error!void {
        const start = node.startByte();
        const at = self.use_at.get(start) orelse return;
        if (self.skipped_uses.contains(start)) return;
        const use = self.every.uses[at];
        const name = try self.keep(self.every.use_names[at]);
        const is_type = oneOf(node.kind(), self.g.type_kinds);
        const role: facts.RefKind = if (is_type) .type else if (self.isExportSpecifier(depth, field)) .import else self.roleAt(depth, field);
        const from = try self.ownerAt(start);
        if (self.inError()) return self.addRef(.{ .from = from, .kind = role, .name = name, .start = start, .line = lineOf(node), .target = .{ .unresolved = .parse_error } });
        const binder_index = use.binder orelse {
            if (!role.invokes()) return;
            if (oneOf(name, self.g.module_callees)) return;
            const dynamic = oneOf(name, self.g.eval_callees) or (role == .new and oneOf(name, self.g.constructor_callees));
            return self.addRef(.{ .from = from, .kind = role, .name = name, .start = start, .line = lineOf(node), .target = .{ .unresolved = if (dynamic) .dynamic_call else .global } });
        };
        const binder = self.every.binders[binder_index].span.start;
        const target = self.targetOfBinder(binder) orelse {
            if (role.invokes()) try self.addRef(.{ .from = from, .kind = role, .name = name, .start = start, .line = lineOf(node), .target = .{ .unresolved = .local_value } });
            return;
        };
        try self.addRef(.{ .from = from, .kind = role, .name = name, .start = start, .line = lineOf(node), .target = target });
    }

    fn subscriptRead(self: *Extractor, node: ts.Node, depth: usize, field: ?[]const u8) void {
        if (self.roleAt(depth, field) == .call) return;
        const index = node.childByField(self.g.subscript_index_field) orelse return;
        if (oneOf(index.kind(), self.g.literal_index_kinds)) return;
        self.dynamic_reads += 1;
    }

    fn collectRefs(self: *Extractor) Error!void {
        var walker = traversal.Walker.init(self.snapshot.tree.root());
        defer walker.deinit();
        while (walker.next()) |entry| {
            const depth: usize = entry.depth;
            self.path.shrinkRetainingCapacity(depth);
            const node = entry.node;
            const kind = node.kind();
            if (self.profile.isComment(kind) or oneOf(kind, self.profile.strings)) {
                walker.skipChildren();
                continue;
            }
            if (std.mem.eql(u8, kind, self.f.member)) try self.member(node, depth, entry.field);
            if (self.f.qualified_type) |qualified| if (std.mem.eql(u8, kind, qualified)) try self.qualifiedType(node);
            if (std.mem.eql(u8, kind, self.profile.call.node)) try self.call(node);
            if (std.mem.eql(u8, kind, self.g.subscript)) self.subscriptRead(node, depth, entry.field);
            if (node.childCount() == 0) {
                if (oneOf(kind, self.g.free_kinds)) try self.identifier(node, depth, entry.field);
                continue;
            }
            const errors: u32 = (if (depth == 0) 0 else self.path.items[depth - 1].errors) + @intFromBool(std.mem.eql(u8, kind, self.f.error_node));
            try self.path.append(self.arena, .{ .node = node, .field = entry.field, .errors = errors });
        }
    }

    fn finish(self: *Extractor) Error!facts.FileFacts {
        const loose = try self.arena.alloc(facts.Loose, self.loose.count());
        for (self.loose.keys(), self.loose.values(), loose) |name, count, *slot| slot.* = .{ .name = name, .count = count };
        std.mem.sort(facts.Loose, loose, {}, looseLess);
        std.mem.sort(facts.Ref, self.refs.items, {}, refLess);
        return .{
            .defs = self.defs.items,
            .refs = self.refs.items,
            .specs = self.specs.items,
            .bindings = self.bindings.items,
            .exports = self.exports.items,
            .types = self.types.items,
            .classes = self.classes.items,
            .member_types = self.member_types.items,
            .loose = loose,
            .dynamic_reads = self.dynamic_reads,
            .module_mode = self.module_mode,
            .parse_errors = self.snapshot.tree.root().hasError(),
        };
    }
};

fn looseLess(_: void, a: facts.Loose, b: facts.Loose) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn refLess(_: void, a: facts.Ref, b: facts.Ref) bool {
    if (a.start != b.start) return a.start < b.start;
    return @intFromEnum(a.kind) < @intFromEnum(b.kind);
}

fn hasToken(node: ts.Node, token: []const u8) bool {
    var i: u32 = 0;
    while (node.child(i)) |child| : (i += 1) {
        if (!child.isNamed() and std.mem.eql(u8, child.kind(), token)) return true;
    }
    return false;
}

fn unquote(text: []const u8) []const u8 {
    if (text.len < 2) return text;
    return text[1 .. text.len - 1];
}

pub fn supports(profile: *const Profile) bool {
    return profile.facts != null and profile.rename != null and profile.modules != null;
}

pub fn extract(arena: Allocator, snapshot: *const Snapshot) Error!facts.FileFacts {
    const profile = snapshot.profile;
    if (!supports(profile)) return error.UnsupportedLanguage;
    var self: Extractor = .{ .arena = arena, .snapshot = snapshot, .profile = profile, .g = profile.rename.?, .f = profile.facts.?, .m = profile.modules.? };
    self.every = try scope.resolveAll(arena, snapshot);
    try self.indexLines();
    try self.collectDefs();
    try self.indexUses();
    try self.collectImports();
    try self.collectShapes();
    try self.collectExports();
    try self.collectRefs();
    return self.finish();
}
