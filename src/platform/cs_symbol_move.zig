const std = @import("std");
const ts = @import("../engine/tree_sitter.zig");
const symbol = @import("../engine/symbol.zig");
const scope = @import("../engine/scope.zig");
const modules = @import("../engine/modules.zig");
const tsserver = @import("tsserver.zig");
const batch_plan = @import("batch_plan.zig");
const py = @import("py_modules.zig");
const cs = @import("cs_modules.zig");
const mb = @import("move_batch.zig");
const paths = @import("module_paths.zig");
const Snapshot = @import("../engine/loader.zig").Snapshot;

const Allocator = std.mem.Allocator;
const Span = symbol.Span;
const TextEdit = mb.TextEdit;
const PyEdit = cs.TextEdit;
const Unit = cs.Unit;
const Index = cs.Index;

const type_kinds = [_][]const u8{ "class_declaration", "struct_declaration", "record_declaration", "interface_declaration", "enum_declaration", "delegate_declaration" };
const member_kinds = [_][]const u8{ "method_declaration", "field_declaration", "property_declaration", "event_declaration", "event_field_declaration", "constructor_declaration", "destructor_declaration", "indexer_declaration", "operator_declaration", "conversion_operator_declaration" };

fn oneOf(kind: []const u8, kinds: []const []const u8) bool {
    for (kinds) |other| {
        if (std.mem.eql(u8, other, kind)) return true;
    }
    return false;
}

fn nodeAt(root: ts.Node, offset: u32) ts.Node {
    var current = root;
    descend: while (true) {
        var i: u32 = 0;
        while (current.child(i)) |child| : (i += 1) {
            if (child.startByte() <= offset and offset < child.endByte()) {
                current = child;
                continue :descend;
            }
        }
        return current;
    }
}

const Located = struct {
    declaration: ts.Node,
    name: []const u8,
    function: bool,
};

fn locate(arena: Allocator, base: *Snapshot, ref: symbol.Ref, expected: symbol.Hash) !Located {
    const table = try base.symbols();
    var offset: u32 = undefined;
    var function = false;
    if (table.resolve(ref)) |found| {
        if (!std.mem.eql(u8, &found.hash, &expected)) return error.HashMismatch;
        offset = (try batch_plan.nameOffset(arena, base, ref.name, found.declaration)) orelse return error.SymbolNotFound;
        function = true;
    } else |err| switch (err) {
        error.SymbolNotFound => {
            const found = table.declarationMatching(ref, expected) orelse return if (table.hasDeclaration(ref)) error.HashMismatch else error.SymbolNotFound;
            offset = found.name.startByte();
        },
        else => |e| return e,
    }
    var up: ?ts.Node = nodeAt(base.tree.root(), offset);
    while (up) |node| : (up = node.parent()) {
        if (oneOf(node.kind(), &type_kinds) or oneOf(node.kind(), &member_kinds)) return .{ .declaration = node, .name = ref.name, .function = function };
    }
    return error.NotTopLevel;
}

fn cutOf(base: *const Snapshot, declaration: ts.Node) Span {
    const source = base.source;
    var start = declaration.startByte();
    var prev = declaration.prevSibling();
    while (prev) |sibling| : (prev = sibling.prevSibling()) {
        if (!base.profile.isComment(sibling.kind())) break;
        const gap = source[sibling.endByte()..start];
        if (std.mem.count(u8, gap, "\n") > 1 or std.mem.trim(u8, gap, " \t\r\n").len != 0) break;
        start = sibling.startByte();
    }
    const line = cs.lineStart(source, start);
    if (std.mem.trim(u8, source[line..start], " \t").len == 0) start = line;
    var end = mb.lineEndAfter(source, declaration.endByte());
    const after_blank = mb.lineEndAfter(source, end);
    if (after_blank != end and (end == 0 or source[end - 1] == '\n')) {
        const before_blank = start == 0 or isBlankBefore(source, start);
        if (before_blank) end = after_blank;
    }
    return .{ .start = start, .end = end };
}

fn usingsAdded(edits: []const PyEdit) usize {
    var count: usize = 0;
    for (edits) |edit| {
        if (edit.start == edit.end and std.mem.startsWith(u8, std.mem.trimStart(u8, edit.text, " \t\r\n"), "using ")) count += 1;
    }
    return count;
}

fn tidiedCut(source: []const u8, cut: Span) Span {
    const blank = " \t\r\n";
    const kept = std.mem.trimEnd(u8, source[0..cut.start], blank);
    const rest = std.mem.trimStart(u8, source[cut.end..], blank);
    var tidy = cut;
    if (rest.len != 0 and rest[0] == '}') {
        var line_end: u32 = @intCast(kept.len);
        while (line_end < cut.start and source[line_end] != '\n') line_end += 1;
        if (line_end < cut.start) tidy.start = line_end + 1;
    }
    if (kept.len != 0 and kept[kept.len - 1] == '{') {
        var next = cut.end;
        while (next < source.len and std.mem.indexOfScalar(u8, blank, source[next]) != null) {
            if (source[next] == '\n') tidy.end = next + 1;
            next += 1;
        }
    }
    return tidy;
}

fn isBlankBefore(source: []const u8, start: u32) bool {
    if (start == 0) return true;
    const previous = cs.lineStart(source, start - 1);
    return std.mem.trim(u8, source[previous..start], " \t\r\n").len == 0;
}

fn toMoveEdits(arena: Allocator, edits: []const PyEdit) ![]TextEdit {
    const out = try arena.alloc(TextEdit, edits.len);
    for (edits, out) |e, *slot| slot.* = .{ .start = e.start, .end = e.end, .text = e.text };
    return out;
}

fn locateHash(after: *Snapshot, name: []const u8, expected: symbol.Hash, function: bool) !symbol.Hash {
    const table = after.symbols() catch return error.MutationSyntaxInvalid;
    if (function) {
        for (table.symbols) |s| {
            if (std.mem.eql(u8, s.ref.name, name) and std.mem.eql(u8, &s.hash, &expected)) return s.hash;
        }
    }
    for (table.declarations) |d| {
        if (std.mem.eql(u8, d.ref.name, name) and std.mem.eql(u8, &d.hash, &expected)) return d.hash;
    }
    return error.ContentHashMismatch;
}

const Needs = struct {
    lines: std.StringArrayHashMapUnmanaged(void) = .empty,
};

fn directiveText(unit: Unit, entry: modules.Import) []const u8 {
    return unit.snapshot.source[entry.statement.start..entry.statement.end];
}

fn targetHasDirective(target: ?Unit, line: []const u8) bool {
    const t = target orelse return false;
    for (t.usings) |entry| {
        if (std.mem.eql(u8, directiveText(t, entry), line)) return true;
    }
    return false;
}

fn movedNeeds(arena: Allocator, index: *const Index, source: Unit, cut: Span, target: ?Unit, target_namespace: []const u8, own_namespace: []const u8, own_name: []const u8) ![]const []const u8 {
    var needs: Needs = .{};
    const after_scopes = try cs.chainOf(arena, target_namespace);
    var external = false;
    for (try cs.mentions(arena, source, null)) |mention| {
        if (mention.node.startByte() < cut.start or mention.node.endByte() > cut.end) continue;
        const scopes = try cs.scopesAt(arena, source, mention.node);
        switch (try cs.lookup(index, source, scopes, mention.name)) {
            .none => external = true,
            .ambiguous => return error.CsAmbiguousType,
            .other => {
                for (source.usings) |entry| {
                    if (entry.spec_kind != .using_alias or !std.mem.eql(u8, entry.namespace orelse "", mention.name)) continue;
                    const line = directiveText(source, entry);
                    if (targetHasDirective(target, line)) continue;
                    if (target) |t| {
                        for (t.usings) |other| {
                            if (other.spec_kind == .using_alias and std.mem.eql(u8, other.namespace orelse "", mention.name)) return error.TargetCapture;
                        }
                    }
                    try needs.lines.put(arena, line, {});
                }
            },
            .ns => |namespace| {
                if (namespace.len == 0) continue;
                if (std.mem.eql(u8, namespace, own_namespace) and std.mem.eql(u8, mention.name, own_name)) continue;
                const seen = if (target) |t| try cs.visibleAnywhere(index, t, after_scopes, namespace) else blk: {
                    for (after_scopes) |current| {
                        if (std.mem.eql(u8, current, namespace)) break :blk true;
                    }
                    break :blk false;
                };
                if (!seen) try needs.lines.put(arena, try std.fmt.allocPrint(arena, "using {s};", .{namespace}), {});
            },
        }
    }
    if (external) {
        for (source.usings) |entry| {
            if (entry.global or entry.spec_kind == .using_alias) continue;
            const namespace = try index.usingNamespace(entry);
            if (entry.spec_kind == .using and index.namespaces.contains(namespace)) continue;
            const line = directiveText(source, entry);
            if (!targetHasDirective(target, line)) try needs.lines.put(arena, line, {});
        }
    }
    return needs.lines.keys();
}

fn namespaceBody(unit: Unit, namespace: []const u8) ?ts.Node {
    var stack: std.ArrayList(ts.Node) = .empty;
    stack.append(std.heap.page_allocator, unit.snapshot.tree.root()) catch return null;
    defer stack.deinit(std.heap.page_allocator);
    var last: ?ts.Node = null;
    while (stack.pop()) |node| {
        var i: u32 = 0;
        while (node.namedChild(i)) |child| : (i += 1) {
            if (!std.mem.eql(u8, child.kind(), "namespace_declaration")) continue;
            const body = child.childByField("body") orelse continue;
            stack.append(std.heap.page_allocator, body) catch return null;
            const name = child.childByField("name") orelse continue;
            const text = unit.snapshot.tree.text(name);
            if (std.mem.endsWith(u8, namespace, text)) last = body;
        }
    }
    return last;
}

fn closingLine(source: []const u8, body: ts.Node) u32 {
    const close = body.endByte() - 1;
    const line = cs.lineStart(source, close);
    if (std.mem.trim(u8, source[line..close], " \t").len == 0) return line;
    return close;
}

fn endOfFileEdit(arena: Allocator, source: []const u8, text: []const u8) !TextEdit {
    const newline = cs.newlineOf(source);
    const at: u32 = @intCast(source.len);
    var glue: []const u8 = newline;
    if (source.len == 0) {
        glue = "";
    } else if (!std.mem.endsWith(u8, source, "\n")) {
        glue = try std.mem.concat(arena, u8, &.{ newline, newline });
    }
    const closing: []const u8 = if (std.mem.endsWith(u8, text, "\n")) "" else newline;
    return .{ .start = at, .end = at, .text = try std.mem.concat(arena, u8, &.{ glue, text, closing }) };
}

fn declaredNamespaces(arena: Allocator, unit: Unit) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (unit.declared) |d| {
        if (d.name.len == 0) try out.append(arena, d.namespace);
    }
    return out.items;
}

fn newFileText(arena: Allocator, source: *const Snapshot, namespace: []const u8, lines: []const []const u8, moved: []const u8) ![]const u8 {
    const newline = cs.newlineOf(source.source);
    var out: std.ArrayList(u8) = .empty;
    for (lines) |line| {
        try out.appendSlice(arena, line);
        try out.appendSlice(arena, newline);
    }
    if (lines.len != 0) try out.appendSlice(arena, newline);
    if (namespace.len == 0) {
        try out.appendSlice(arena, moved);
    } else if (fileScoped(source)) {
        try out.print(arena, "namespace {s};{s}{s}", .{ namespace, newline, newline });
        try out.appendSlice(arena, moved);
    } else {
        try out.print(arena, "namespace {s}{s}{{{s}", .{ namespace, newline, newline });
        try out.appendSlice(arena, moved);
        if (!std.mem.endsWith(u8, moved, "\n")) try out.appendSlice(arena, newline);
        try out.print(arena, "}}{s}", .{newline});
    }
    if (!std.mem.endsWith(u8, out.items, "\n")) try out.appendSlice(arena, newline);
    return out.items;
}

fn fileScoped(source: *const Snapshot) bool {
    const root = source.tree.root();
    var i: u32 = 0;
    while (root.namedChild(i)) |child| : (i += 1) {
        if (std.mem.eql(u8, child.kind(), "file_scoped_namespace_declaration")) return true;
    }
    return false;
}

fn cxOf(w: mb.Work) cs.Cx {
    return .{ .arena = w.arena, .io = w.io, .runtime = w.runtime, .root = w.root };
}

pub fn plan(w: mb.Work, request: mb.Request, source: *Snapshot, target: ?*Snapshot, opened: *std.ArrayList(*Snapshot)) !mb.Plan {
    const arena = w.arena;
    if (!paths.isCsharpPath(request.target_abs)) return error.UnsupportedLanguage;
    const given = try symbol.Ref.parse(arena, request.ref_text);
    const ref = try (try source.symbols()).canonical(given);
    const located = try locate(arena, source, ref, request.expected_hash);
    if (oneOf(located.declaration.kind(), &type_kinds)) return planType(w, request, source, target, located, opened);
    return planMember(w, request, source, target, located, opened);
}

fn planType(w: mb.Work, request: mb.Request, source: *Snapshot, target: ?*Snapshot, located: Located, opened: *std.ArrayList(*Snapshot)) !mb.Plan {
    const arena = w.arena;
    if (tsserver.sameFile(request.file_abs, request.target_abs)) return error.SameFile;
    const cx = cxOf(w);
    const declaration = located.declaration;
    const holder = declaration.parent() orelse return error.NotTopLevel;
    const holder_kind = holder.kind();
    if (std.mem.eql(u8, holder_kind, "declaration_list")) {
        const owner = holder.parent() orelse return error.NotTopLevel;
        if (!std.mem.eql(u8, owner.kind(), "namespace_declaration")) return error.NotTopLevel;
    }
    if (cs.modifierOn(source, declaration, "file")) return error.CsFileScopedType;
    const partial = cs.modifierOn(source, declaration, "partial");
    const public = cs.modifierOn(source, declaration, "public");

    const name = located.name;
    const source_unit = try cs.unitOf(arena, request.file_abs, source);
    const old = (try cs.scopesAt(arena, source_unit, declaration))[0];
    var known: std.ArrayList(Unit) = .empty;
    try known.append(arena, source_unit);
    const target_unit: ?Unit = if (target) |t| try cs.unitOf(arena, request.target_abs, t) else null;
    if (target_unit) |t| try known.append(arena, t);
    const units = try cs.loadUnits(cx, known.items, opened, &.{ name, old });
    const index = try Index.init(arena, units);

    var new = old;
    if (target_unit) |t| {
        const namespaces = try declaredNamespaces(arena, t);
        if (namespaces.len == 1) {
            new = namespaces[0];
        } else if (namespaces.len == 0) {
            new = "";
        } else {
            var has_old = false;
            for (namespaces) |n| {
                if (std.mem.eql(u8, n, old)) has_old = true;
            }
            if (!has_old) return error.CsTargetNamespace;
        }
        if ((new.len == 0) != (old.len == 0)) return error.CsTargetNamespace;
        for (t.declared) |d| {
            if (!std.mem.eql(u8, d.name, name)) continue;
            if (!partial) return error.TargetNameTaken;
        }
    }
    const changes = !std.mem.eql(u8, old, new);
    if (changes and partial) return error.CsPartialType;
    if (changes and index.hasType(new, name)) return error.TargetNameTaken;
    const names: []const []const u8 = try arena.dupe([]const u8, &.{name});
    if (changes) try cs.refuseStrings(cx, units, old, names, error.DynamicReference);

    const cut = cutOf(source, declaration);
    const moved_text = source.source[cut.start..mb.lineEndAfter(source.source, declaration.endByte())];
    const r: cs.Retarget = .{ .old = old, .new = new, .names = names };
    const needed = try movedNeeds(arena, &index, source_unit, cut, target_unit, new, old, name);

    const tidy = tidiedCut(source.source, cut);
    var source_edits: std.ArrayList(PyEdit) = .empty;
    try source_edits.append(arena, .{ .start = tidy.start, .end = tidy.end, .text = "" });
    var target_edits: std.ArrayList(PyEdit) = .empty;
    var outputs: std.ArrayList(mb.Output) = .empty;
    try outputs.append(arena, undefined);
    try outputs.append(arena, undefined);
    var user_edits: std.ArrayList([]const TextEdit) = .empty;
    var users: usize = 0;
    var imports_added: usize = needed.len;
    if (changes) {
        try cs.rewriteUser(arena, &index, source_unit, r, cut, &source_edits);
        if (target_unit) |t| try cs.rewriteUser(arena, &index, t, r, null, &target_edits);
        imports_added += usingsAdded(source_edits.items) + usingsAdded(target_edits.items);
        for (units) |unit| {
            if (tsserver.sameFile(unit.abs, request.file_abs) or tsserver.sameFile(unit.abs, request.target_abs)) continue;
            var edits: std.ArrayList(PyEdit) = .empty;
            try cs.rewriteUser(arena, &index, unit, r, null, &edits);
            if (edits.items.len == 0) continue;
            imports_added += usingsAdded(edits.items);
            const moved_edits = try toMoveEdits(arena, edits.items);
            const text = try mb.applyEdits(arena, unit.snapshot.source, moved_edits);
            try outputs.append(arena, .{ .abs = unit.abs, .before = unit.snapshot, .text = text, .holes = try mb.holesOf(arena, moved_edits) });
            try user_edits.append(arena, moved_edits);
            users += 1;
        }
    }
    const interface_change = users != 0 or (changes and public);
    if (interface_change and !request.interface_change) return error.InterfaceChangeNeedsApproval;

    const source_moved = try toMoveEdits(arena, source_edits.items);
    const source_new = try mb.applyEdits(arena, source.source, source_moved);

    var target_new: []const u8 = undefined;
    var target_holes: ?[]const symbol.Hole = null;
    var moved_start: u32 = 0;
    if (target_unit) |t| {
        for (needed) |line| try cs.insertUsing(arena, t, line, &target_edits);
        var inserted: TextEdit = undefined;
        const text = t.snapshot.source;
        const body = if (new.len != 0) namespaceBody(t, new) else null;
        if (body) |list| {
            const at = closingLine(text, list);
            const newline = cs.newlineOf(text);
            const has_members = list.namedChildCount() != 0;
            const closing: []const u8 = if (std.mem.endsWith(u8, moved_text, "\n")) "" else newline;
            inserted = .{ .start = at, .end = at, .text = try std.mem.concat(arena, u8, &.{ if (has_members) newline else "", moved_text, closing }) };
        } else {
            inserted = try endOfFileEdit(arena, text, moved_text);
        }
        var all = try toMoveEdits(arena, target_edits.items);
        const combined = try arena.alloc(TextEdit, all.len + 1);
        @memcpy(combined[0..all.len], all);
        combined[all.len] = inserted;
        all = combined;
        target_new = try mb.applyEdits(arena, text, all);
        target_holes = try mb.holesOf(arena, all);
    } else {
        target_new = try newFileText(arena, source, new, needed, moved_text);
    }
    moved_start = @intCast(std.mem.lastIndexOf(u8, target_new, moved_text) orelse return error.IncompleteMove);
    const moved_span: Span = .{ .start = moved_start, .end = moved_start + @as(u32, @intCast(moved_text.len)) };

    outputs.items[0] = .{ .abs = request.file_abs, .before = source, .text = source_new, .holes = try mb.holesOf(arena, source_moved) };
    outputs.items[1] = .{ .abs = request.target_abs, .before = target, .text = target_new, .creates = target == null, .ref_text = name, .body = moved_span, .holes = target_holes };

    var afters: std.ArrayList(*Snapshot) = .empty;
    defer for (afters.items) |s| s.destroy();
    for (outputs.items) |o| {
        const after = try py.load(cx, o.abs, o.text);
        try afters.append(arena, after);
        if (after.tree.root().hasError()) return error.MutationSyntaxInvalid;
    }
    const moved_hash = try locateHash(afters.items[1], name, request.expected_hash, located.function);

    var after_units: std.ArrayList(Unit) = .empty;
    for (units) |unit| {
        var snapshot = unit.snapshot;
        for (outputs.items, afters.items) |o, after| {
            if (tsserver.sameFile(o.abs, unit.abs)) snapshot = after;
        }
        try after_units.append(arena, try cs.unitOf(arena, unit.abs, snapshot));
    }
    if (target == null) try after_units.append(arena, try cs.unitOf(arena, request.target_abs, afters.items[1]));
    const after_index = try Index.init(arena, after_units.items);
    const proof_names = try cs.universe(arena, &index, &after_index, r);
    for (units, after_units.items[0..units.len]) |before_unit, after_unit| {
        var before_filter: cs.Filter = .{};
        var after_filter: cs.Filter = .{};
        if (tsserver.sameFile(before_unit.abs, request.file_abs)) before_filter = .{ .span = cut };
        if (tsserver.sameFile(before_unit.abs, request.target_abs)) after_filter = .{ .span = moved_span };
        try cs.proveSame(arena, &index, before_unit, before_filter, &after_index, after_unit, after_filter, r, proof_names);
        if (changes) {
            for (try cs.qualifiedTo(arena, &after_index, after_unit, old, names)) |q| {
                if (tsserver.sameFile(before_unit.abs, request.target_abs) and q.qualifier.startByte() >= moved_span.start and q.qualifier.endByte() <= moved_span.end) return error.MoveMemberDependency;
                return error.IncompleteMove;
            }
        }
    }
    const moved_after = if (target == null) after_units.items[after_units.items.len - 1] else blk: {
        for (units, after_units.items[0..units.len]) |before_unit, after_unit| {
            if (tsserver.sameFile(before_unit.abs, request.target_abs)) break :blk after_unit;
        }
        return error.IncompleteMove;
    };
    try cs.proveSame(arena, &index, source_unit, .{ .span = cut, .inside = true }, &after_index, moved_after, .{ .span = moved_span, .inside = true }, r, proof_names);

    try cs.proveKept(source, afters.items[0], cut, source_edits.items);
    if (target) |t| try cs.proveKept(t, afters.items[1], null, target_edits.items);
    for (outputs.items[2..], afters.items[2..], user_edits.items) |o, after, edits| {
        const as_py = try arena.alloc(PyEdit, edits.len);
        for (edits, as_py) |e, *slot| slot.* = .{ .start = e.start, .end = e.end, .text = e.text };
        try cs.proveKept(o.before.?, after, null, as_py);
    }

    const result = try mb.buildFromGraph(w.gpa, w.root, outputs.items, afters.items, .{
        .resolver = .module_graph,
        .fallback = null,
        .interface_change = interface_change,
        .order_change = false,
        .creates_target = target == null,
        .users = users,
        .imports_added = imports_added,
        .moved_hash = moved_hash,
    }, opened);
    afters.clearRetainingCapacity();
    return result;
}

const Owner = struct {
    node: ts.Node,
    body: ts.Node,
    name: []const u8,
    namespace: []const u8,
};

fn memberNames(arena: Allocator, snapshot: *const Snapshot, body: ts.Node) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: u32 = 0;
    while (body.namedChild(i)) |child| : (i += 1) {
        if (child.childByField("name")) |name| {
            if (oneOf(child.kind(), &member_kinds) or oneOf(child.kind(), &type_kinds)) try out.append(arena, snapshot.tree.text(name));
            continue;
        }
        if (!oneOf(child.kind(), &member_kinds)) continue;
        var stack: std.ArrayList(ts.Node) = .empty;
        try stack.append(arena, child);
        while (stack.pop()) |node| {
            if (std.mem.eql(u8, node.kind(), "variable_declarator")) {
                if (node.childByField("name")) |name| try out.append(arena, snapshot.tree.text(name));
                continue;
            }
            var j: u32 = 0;
            while (node.namedChild(j)) |sub| : (j += 1) try stack.append(arena, sub);
        }
    }
    return out.items;
}

fn containsName(list: []const []const u8, word: []const u8) bool {
    for (list) |other| {
        if (std.mem.eql(u8, other, word)) return true;
    }
    return false;
}

fn findTargetType(arena: Allocator, unit: Unit, wanted_name: ?[]const u8, skip: ?ts.Node) !Owner {
    var found: ?Owner = null;
    var count: usize = 0;
    var stack: std.ArrayList(ts.Node) = .empty;
    try stack.append(arena, unit.snapshot.tree.root());
    while (stack.pop()) |node| {
        var i: u32 = 0;
        while (node.namedChild(i)) |child| : (i += 1) {
            const kind = child.kind();
            if (std.mem.eql(u8, kind, "namespace_declaration")) {
                if (child.childByField("body")) |body| try stack.append(arena, body);
                continue;
            }
            if (!oneOf(kind, &type_kinds)) continue;
            const name = child.childByField("name") orelse continue;
            const text = unit.snapshot.tree.text(name);
            if (wanted_name) |w| {
                if (!std.mem.eql(u8, w, text)) continue;
            }
            if (skip) |s| {
                if (s.eql(child)) continue;
            }
            const body = child.childByField("body") orelse continue;
            count += 1;
            found = .{ .node = child, .body = body, .name = text, .namespace = (try cs.scopesAt(arena, unit, child))[0] };
        }
    }
    if (count != 1) return error.MoveNeedsTargetType;
    return found.?;
}

const MemberRefs = struct {
    edits: std.ArrayList(PyEdit) = .empty,
    need_using: bool = false,
};

fn newOwnerText(arena: Allocator, index: *const Index, unit: Unit, scopes: []const []const u8, owner: Owner, refs: *MemberRefs) ![]const u8 {
    const found = try cs.lookup(index, unit, scopes, owner.name);
    if (found == .ns and std.mem.eql(u8, found.ns, owner.namespace)) return owner.name;
    if (found == .none and owner.namespace.len != 0) {
        refs.need_using = true;
        return owner.name;
    }
    if (owner.namespace.len == 0) return std.fmt.allocPrint(arena, "global::{s}", .{owner.name});
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ owner.namespace, owner.name });
}

fn refusals(arena: Allocator, index: *const Index, unit: Unit, full_owner: []const u8, owner_short: []const u8, member: []const u8, owner_namespace: []const u8) !void {
    const tree = &unit.snapshot.tree;
    for (unit.usings) |entry| {
        if (entry.spec_kind != .using_static) continue;
        const text = try cs.clean(arena, entry.spec);
        var hit = std.mem.eql(u8, text, full_owner);
        var current = entry.spec_scope;
        while (current.len != 0) : (current = cs.parentOf(current)) {
            if (std.mem.eql(u8, try cs.join(arena, current, text), full_owner)) hit = true;
        }
        if (hit and (try cs.mentions(arena, unit, &.{member})).len != 0) return error.MoveMemberDependency;
    }
    for (unit.usings) |entry| {
        if (entry.spec_kind != .using_alias) continue;
        if (!std.mem.eql(u8, try cs.clean(arena, entry.spec), full_owner)) continue;
        const alias = entry.namespace orelse continue;
        const word = try std.fmt.allocPrint(arena, "{s}.{s}", .{ alias, member });
        if (std.mem.indexOf(u8, unit.snapshot.source, word) != null) return error.MoveMemberDependency;
    }
    var stack: std.ArrayList(ts.Node) = .empty;
    try stack.append(arena, tree.root());
    while (stack.pop()) |node| {
        var i: u32 = 0;
        while (node.child(i)) |child| : (i += 1) try stack.append(arena, child);
        if (!std.mem.eql(u8, node.kind(), "base_list")) continue;
        var j: u32 = 0;
        while (node.namedChild(j)) |base| : (j += 1) {
            const text = try cs.clean(arena, tree.text(base));
            const scopes = try cs.scopesAt(arena, unit, base);
            const direct = std.mem.eql(u8, text, full_owner);
            var short = false;
            if (std.mem.eql(u8, text, owner_short)) {
                const found = try cs.lookup(index, unit, scopes, owner_short);
                short = found == .ns and std.mem.eql(u8, found.ns, owner_namespace);
            }
            if (!direct and !short) continue;
            const holder = node.parent() orelse continue;
            if (std.mem.indexOf(u8, tree.text(holder), member) != null) return error.MoveMemberDependency;
        }
    }
}

fn memberRefs(arena: Allocator, index: *const Index, unit: Unit, owner: Owner, target_owner: Owner, member: []const u8, skip: ?Span, name_span: ?Span, inside_owner: ?ts.Node) !MemberRefs {
    const tree = &unit.snapshot.tree;
    var refs: MemberRefs = .{};
    const full_owner = try cs.join(arena, owner.namespace, owner.name);
    var stack: std.ArrayList(ts.Node) = .empty;
    try stack.append(arena, tree.root());
    while (stack.pop()) |node| {
        var i: u32 = 0;
        while (node.child(i)) |child| : (i += 1) try stack.append(arena, child);
        if (skip) |span| {
            if (node.startByte() >= span.start and node.endByte() <= span.end) continue;
        }
        const kind = node.kind();
        if (std.mem.eql(u8, kind, "qualified_name") or std.mem.eql(u8, kind, "member_access_expression")) {
            const right = cs.rightName(node) orelse continue;
            if (!std.mem.eql(u8, tree.text(right), member)) continue;
            const left = node.childByField("qualifier") orelse node.childByField("expression") orelse continue;
            const text = try cs.clean(arena, tree.text(left));
            const scopes = try cs.scopesAt(arena, unit, node);
            var matched = false;
            var short = false;
            if (std.mem.eql(u8, text, owner.name)) {
                if (!localShadow(arena, unit, left)) {
                    const found = try cs.lookup(index, unit, scopes, owner.name);
                    if (found == .ns and std.mem.eql(u8, found.ns, owner.namespace)) {
                        matched = true;
                        short = true;
                    }
                }
            }
            if (!matched) {
                for (scopes) |current| {
                    if (std.mem.eql(u8, try cs.join(arena, current, text), full_owner)) matched = true;
                }
            }
            if (!matched) continue;
            const replacement = if (short) try newOwnerText(arena, index, unit, scopes, target_owner, &refs) else if (target_owner.namespace.len == 0) try std.fmt.allocPrint(arena, "global::{s}", .{target_owner.name}) else try cs.join(arena, target_owner.namespace, target_owner.name);
            try refs.edits.append(arena, .{ .start = left.startByte(), .end = left.endByte(), .text = replacement });
            continue;
        }
        if (!std.mem.eql(u8, kind, "identifier")) continue;
        const within = inside_owner orelse continue;
        if (node.startByte() < within.startByte() or node.endByte() > within.endByte()) continue;
        if (!std.mem.eql(u8, tree.text(node), member)) continue;
        if (cs.isQualifiedRight(node) or scope.siteOf(unit.snapshot.profile.rename.?, node) != null) continue;
        const resolution = try scope.resolveName(arena, unit.snapshot, member);
        if (resolution.useAt(.{ .start = node.startByte(), .end = node.endByte() })) |use| {
            if (use.binder) |binder| {
                const span = name_span orelse continue;
                const b = resolution.binders[binder].span;
                if (b.start != span.start or b.end != span.end) continue;
            }
        }
        const scopes = try cs.scopesAt(arena, unit, node);
        const owner_text = try newOwnerText(arena, index, unit, scopes, target_owner, &refs);
        try refs.edits.append(arena, .{ .start = node.startByte(), .end = node.startByte(), .text = try std.fmt.allocPrint(arena, "{s}.", .{owner_text}) });
    }
    return refs;
}

fn localShadow(arena: Allocator, unit: Unit, left: ts.Node) bool {
    if (!std.mem.eql(u8, left.kind(), "identifier")) return false;
    const resolution = scope.resolveName(arena, unit.snapshot, unit.snapshot.tree.text(left)) catch return true;
    const use = resolution.useAt(.{ .start = left.startByte(), .end = left.endByte() }) orelse return false;
    const binder = use.binder orelse return false;
    const root = unit.snapshot.tree.root();
    const b = resolution.binders[binder].scope;
    return b.start != root.startByte() or b.end != root.endByte();
}

fn memberName(snapshot: *const Snapshot, declaration: ts.Node, wanted_name: []const u8) ?Span {
    var stack: [32]ts.Node = undefined;
    var depth: usize = 1;
    stack[0] = declaration;
    while (depth != 0) {
        depth -= 1;
        const node = stack[depth];
        if (node.childByField("name")) |name| {
            if (std.mem.eql(u8, snapshot.tree.text(name), wanted_name)) return .{ .start = name.startByte(), .end = name.endByte() };
        }
        if (std.mem.eql(u8, node.kind(), "block") or std.mem.eql(u8, node.kind(), "arrow_expression_clause")) continue;
        var i: u32 = 0;
        while (node.namedChild(i)) |child| : (i += 1) {
            if (depth == stack.len) break;
            stack[depth] = child;
            depth += 1;
        }
    }
    return null;
}

fn fieldDeclarators(declaration: ts.Node) usize {
    var count: usize = 0;
    var i: u32 = 0;
    while (declaration.namedChild(i)) |child| : (i += 1) {
        if (!std.mem.eql(u8, child.kind(), "variable_declaration")) continue;
        var j: u32 = 0;
        while (child.namedChild(j)) |sub| : (j += 1) {
            if (std.mem.eql(u8, sub.kind(), "variable_declarator")) count += 1;
        }
    }
    return count;
}

fn hasInitializer(declaration: ts.Node) bool {
    if (declaration.childByField("value") != null) return true;
    var stack: [16]ts.Node = undefined;
    var depth: usize = 1;
    stack[0] = declaration;
    while (depth != 0) {
        depth -= 1;
        const node = stack[depth];
        const kind = node.kind();
        if (std.mem.eql(u8, kind, "equals_value_clause") or std.mem.eql(u8, kind, "=")) return true;
        if (std.mem.eql(u8, kind, "block") or std.mem.eql(u8, kind, "arrow_expression_clause")) continue;
        var i: u32 = 0;
        while (node.child(i)) |child| : (i += 1) {
            if (depth == stack.len) break;
            stack[depth] = child;
            depth += 1;
        }
    }
    return false;
}

fn isExtension(snapshot: *const Snapshot, declaration: ts.Node) bool {
    const parameters = declaration.childByField("parameters") orelse return false;
    const first = parameters.namedChild(0) orelse return false;
    var i: u32 = 0;
    while (first.child(i)) |child| : (i += 1) {
        if (std.mem.eql(u8, snapshot.tree.text(child), "this")) return true;
    }
    return false;
}

fn planMember(w: mb.Work, request: mb.Request, source: *Snapshot, target: ?*Snapshot, located: Located, opened: *std.ArrayList(*Snapshot)) !mb.Plan {
    const arena = w.arena;
    const cx = cxOf(w);
    const declaration = located.declaration;
    const kind = declaration.kind();
    const movable = std.mem.eql(u8, kind, "method_declaration") or std.mem.eql(u8, kind, "field_declaration") or std.mem.eql(u8, kind, "property_declaration");
    if (!movable) return error.NotTopLevel;
    const same_file = tsserver.sameFile(request.file_abs, request.target_abs);
    if (same_file and request.target_type == null) return error.SameFile;

    const static_member = cs.modifierOn(source, declaration, "static") or cs.modifierOn(source, declaration, "const");
    if (!static_member) return error.MoveNotStatic;
    for ([_][]const u8{ "override", "virtual", "abstract", "extern", "partial", "new" }) |word| {
        if (cs.modifierOn(source, declaration, word)) return error.MoveMemberDependency;
    }
    if (isExtension(source, declaration)) return error.MoveMemberDependency;
    if (std.mem.eql(u8, kind, "field_declaration") and fieldDeclarators(declaration) != 1) return error.SharedStatement;

    const body = declaration.parent() orelse return error.NotTopLevel;
    const owner_node = body.parent() orelse return error.NotTopLevel;
    if (!oneOf(owner_node.kind(), &type_kinds)) return error.NotTopLevel;
    const owner_holder = owner_node.parent() orelse return error.NotTopLevel;
    if (std.mem.eql(u8, owner_holder.kind(), "declaration_list")) {
        const up = owner_holder.parent() orelse return error.NotTopLevel;
        if (!std.mem.eql(u8, up.kind(), "namespace_declaration")) return error.NotTopLevel;
    }
    if (owner_node.childByField("type_parameters") != null or cs.modifierOn(source, owner_node, "partial")) return error.MoveMemberDependency;

    const member = located.name;
    const source_unit = try cs.unitOf(arena, request.file_abs, source);
    const owner_name = source.tree.text(owner_node.childByField("name") orelse return error.NotTopLevel);
    const owner: Owner = .{ .node = owner_node, .body = body, .name = owner_name, .namespace = (try cs.scopesAt(arena, source_unit, owner_node))[0] };
    const full_owner = try cs.join(arena, owner.namespace, owner.name);

    const target_snapshot = if (same_file) source else (target orelse return error.MoveNeedsTargetType);
    const target_unit = if (same_file) source_unit else try cs.unitOf(arena, request.target_abs, target_snapshot);
    const target_owner = try findTargetType(arena, target_unit, request.target_type, if (same_file) owner_node else null);
    if (std.mem.eql(u8, target_owner.node.kind(), "enum_declaration") or std.mem.eql(u8, target_owner.node.kind(), "delegate_declaration") or std.mem.eql(u8, target_owner.node.kind(), "interface_declaration")) return error.MoveNeedsTargetType;
    if (target_owner.node.childByField("type_parameters") != null) return error.MoveMemberDependency;
    if (same_file and target_owner.node.eql(owner_node)) return error.SameFile;

    var known: std.ArrayList(Unit) = .empty;
    try known.append(arena, source_unit);
    if (!same_file) try known.append(arena, target_unit);
    const units = try cs.loadUnits(cx, known.items, opened, &.{ member, owner.name });
    const index = try Index.init(arena, units);

    const own_members = try memberNames(arena, source, owner.body);
    var duplicates: usize = 0;
    for (own_members) |other| {
        if (std.mem.eql(u8, other, member)) duplicates += 1;
    }
    if (duplicates > 1) return error.MergedDeclaration;
    const target_members = try memberNames(arena, target_snapshot, target_owner.body);
    if (containsName(target_members, member)) return error.TargetNameTaken;

    const cut = cutOf(source, declaration);
    const moved_text = source.source[cut.start..mb.lineEndAfter(source.source, declaration.endByte())];
    for (try cs.mentions(arena, source_unit, null)) |mention| {
        if (mention.node.startByte() < cut.start or mention.node.endByte() > cut.end) continue;
        if (std.mem.eql(u8, mention.name, member)) continue;
        if (containsName(own_members, mention.name)) return error.MoveMemberDependency;
        if (containsName(target_members, mention.name)) return error.TargetCapture;
    }
    const is_field_like = !std.mem.eql(u8, kind, "method_declaration");
    const order_change = is_field_like and !cs.modifierOn(source, declaration, "const") and hasInitializer(declaration);
    if (order_change and !request.order_change) return error.ModuleSideEffect;

    try cs.refuseStrings(cx, units, full_owner, &.{member}, error.DynamicReference);
    const name_span = memberName(source, declaration, member);

    const tidy = tidiedCut(source.source, cut);
    var source_edits: std.ArrayList(PyEdit) = .empty;
    try source_edits.append(arena, .{ .start = tidy.start, .end = tidy.end, .text = "" });
    var outputs: std.ArrayList(mb.Output) = .empty;
    try outputs.append(arena, undefined);
    if (!same_file) try outputs.append(arena, undefined);
    var target_edits: std.ArrayList(PyEdit) = .empty;
    var user_edits: std.ArrayList([]const TextEdit) = .empty;
    var users: usize = 0;
    var references: usize = 0;
    var usings_added: usize = 0;
    const using_line = try std.fmt.allocPrint(arena, "using {s};", .{target_owner.namespace});
    for (units) |unit| {
        try refusals(arena, &index, unit, full_owner, owner.name, member, owner.namespace);
        const is_source = tsserver.sameFile(unit.abs, request.file_abs);
        const is_target = tsserver.sameFile(unit.abs, request.target_abs);
        var refs = try memberRefs(arena, &index, unit, owner, target_owner, member, if (is_source) cut else null, if (is_source) name_span else null, if (is_source) owner_node else null);
        references += refs.edits.items.len;
        if (refs.need_using) {
            try cs.insertUsing(arena, unit, using_line, &refs.edits);
            usings_added += 1;
        }
        if (is_source) {
            try source_edits.appendSlice(arena, refs.edits.items);
            continue;
        }
        if (is_target) {
            try target_edits.appendSlice(arena, refs.edits.items);
            continue;
        }
        if (refs.edits.items.len == 0) continue;
        const moved_edits = try toMoveEdits(arena, refs.edits.items);
        const text = try mb.applyEdits(arena, unit.snapshot.source, moved_edits);
        try outputs.append(arena, .{ .abs = unit.abs, .before = unit.snapshot, .text = text, .holes = try mb.holesOf(arena, moved_edits) });
        try user_edits.append(arena, moved_edits);
        users += 1;
    }
    const private_member = !cs.modifierOn(source, declaration, "public") and !cs.modifierOn(source, declaration, "internal");
    if (private_member and references != 0) return error.MoveMemberDependency;
    const public = cs.modifierOn(source, declaration, "public");
    const interface_change = public or users != 0;
    if (interface_change and !request.interface_change) return error.InterfaceChangeNeedsApproval;

    const needed = try movedNeeds(arena, &index, source_unit, cut, target_unit, target_owner.namespace, owner.namespace, member);
    const insert_at = closingLine(target_snapshot.source, target_owner.body);
    const newline = cs.newlineOf(target_snapshot.source);
    const closing: []const u8 = if (std.mem.endsWith(u8, moved_text, "\n")) "" else newline;
    const has_members = target_owner.body.namedChildCount() != 0;
    const insert_text = try std.mem.concat(arena, u8, &.{ if (has_members) newline else "", moved_text, closing });

    var after_source: []const u8 = undefined;
    var after_target: []const u8 = undefined;
    var moved_span: Span = undefined;
    if (same_file) {
        for (needed) |line| try cs.insertUsing(arena, source_unit, line, &source_edits);
        try source_edits.append(arena, .{ .start = insert_at, .end = insert_at, .text = insert_text });
        const edits = try toMoveEdits(arena, source_edits.items);
        after_source = try mb.applyEdits(arena, source.source, edits);
        after_target = after_source;
        const at = std.mem.indexOf(u8, after_source, insert_text) orelse return error.IncompleteMove;
        const from: u32 = @intCast(at + (if (has_members) newline.len else 0));
        moved_span = .{ .start = from, .end = from + @as(u32, @intCast(moved_text.len)) };
        outputs.items[0] = .{ .abs = request.file_abs, .before = source, .text = after_source, .ref_text = member, .holes = try mb.holesOf(arena, edits) };
    } else {
        const source_moved = try toMoveEdits(arena, source_edits.items);
        after_source = try mb.applyEdits(arena, source.source, source_moved);
        for (needed) |line| try cs.insertUsing(arena, target_unit, line, &target_edits);
        try target_edits.append(arena, .{ .start = insert_at, .end = insert_at, .text = insert_text });
        const target_moved = try toMoveEdits(arena, target_edits.items);
        after_target = try mb.applyEdits(arena, target_snapshot.source, target_moved);
        const at = std.mem.lastIndexOf(u8, after_target, moved_text) orelse return error.IncompleteMove;
        moved_span = .{ .start = @intCast(at), .end = @intCast(at + moved_text.len) };
        outputs.items[0] = .{ .abs = request.file_abs, .before = source, .text = after_source, .holes = try mb.holesOf(arena, source_moved) };
        outputs.items[1] = .{ .abs = request.target_abs, .before = target_snapshot, .text = after_target, .ref_text = member, .body = moved_span, .holes = try mb.holesOf(arena, target_moved) };
    }

    var afters: std.ArrayList(*Snapshot) = .empty;
    defer for (afters.items) |s| s.destroy();
    for (outputs.items) |o| {
        const after = try py.load(cx, o.abs, o.text);
        try afters.append(arena, after);
        if (after.tree.root().hasError()) return error.MutationSyntaxInvalid;
    }
    const target_after = if (same_file) afters.items[0] else afters.items[1];
    const moved_hash = try locateHash(target_after, member, request.expected_hash, located.function);

    var after_units: std.ArrayList(Unit) = .empty;
    for (units) |unit| {
        var snapshot = unit.snapshot;
        for (outputs.items, afters.items) |o, after| {
            if (tsserver.sameFile(o.abs, unit.abs)) snapshot = after;
        }
        try after_units.append(arena, try cs.unitOf(arena, unit.abs, snapshot));
    }
    const after_index = try Index.init(arena, after_units.items);
    const proof_names = try provenNames(arena, source_unit, cut);
    for (after_units.items) |after_unit| {
        const stale = try memberRefs(arena, &after_index, after_unit, owner, target_owner, member, null, null, null);
        if (stale.edits.items.len != 0) return error.IncompleteMove;
    }
    for (try cs.mentions(arena, source_unit, proof_names)) |mention| {
        if (mention.node.startByte() < cut.start or mention.node.endByte() > cut.end) continue;
        const was = try cs.lookup(&index, source_unit, try cs.scopesAt(arena, source_unit, mention.node), mention.name);
        const target_after_unit = for (after_units.items) |after_unit| {
            if (tsserver.sameFile(after_unit.abs, request.target_abs)) break after_unit;
        } else return error.IncompleteMove;
        const now = try cs.lookup(&after_index, target_after_unit, try cs.chainOf(arena, target_owner.namespace), mention.name);
        if (was == .ns and (now != .ns or !std.mem.eql(u8, was.ns, now.ns))) return error.CsAmbiguousType;
    }

    try cs.proveKept(source, afters.items[0], cut, source_edits.items);
    if (!same_file) try cs.proveKept(target_snapshot, afters.items[1], null, target_edits.items);
    const first_user: usize = if (same_file) 1 else 2;
    for (outputs.items[first_user..], afters.items[first_user..], user_edits.items) |o, after, edits| {
        const as_py = try arena.alloc(PyEdit, edits.len);
        for (edits, as_py) |e, *slot| slot.* = .{ .start = e.start, .end = e.end, .text = e.text };
        try cs.proveKept(o.before.?, after, null, as_py);
    }

    const result = try mb.buildFromGraph(w.gpa, w.root, outputs.items, afters.items, .{
        .resolver = .module_graph,
        .fallback = null,
        .interface_change = interface_change,
        .order_change = order_change,
        .creates_target = false,
        .users = users,
        .imports_added = needed.len + usings_added,
        .moved_hash = moved_hash,
    }, opened);
    afters.clearRetainingCapacity();
    return result;
}

fn provenNames(arena: Allocator, source: Unit, cut: Span) ![]const []const u8 {
    var out: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (try cs.mentions(arena, source, null)) |mention| {
        if (mention.node.startByte() < cut.start or mention.node.endByte() > cut.end) continue;
        try out.put(arena, mention.name, {});
    }
    return out.keys();
}
