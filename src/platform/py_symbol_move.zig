const std = @import("std");
const ts = @import("../engine/tree_sitter.zig");
const symbol = @import("../engine/symbol.zig");
const scope = @import("../engine/scope.zig");
const modules = @import("../engine/modules.zig");
const rename = @import("../engine/rename.zig");
const symmetry = @import("../engine/symmetry.zig");
const registry = @import("../engine/lang/registry.zig");
const repo = @import("repo.zig");
const tsserver = @import("tsserver.zig");
const py = @import("py_modules.zig");
const mb = @import("move_batch.zig");
const file_move = @import("file_move.zig");
const py_file_move = @import("py_file_move.zig");
const paths = @import("module_paths.zig");
const Snapshot = @import("../engine/loader.zig").Snapshot;
const Span = symbol.Span;

const Allocator = std.mem.Allocator;
const Import = modules.Import;
const Named = modules.Named;
const Cx = py.Cx;
const TextEdit = mb.TextEdit;

const Move = struct {
    w: mb.Work,
    cx: Cx,
    source_abs: []const u8,
    target_abs: []const u8,
    name: []const u8,
    source_snapshot: *const Snapshot,
    imports_added: usize = 0,

    fn isSource(self: *const Move, hit: ?[]const u8) bool {
        return hit != null and tsserver.sameFile(hit.?, self.source_abs);
    }

    fn isTarget(self: *const Move, hit: ?[]const u8) bool {
        return hit != null and tsserver.sameFile(hit.?, self.target_abs);
    }
};

const dunders = std.StaticStringMap(void).initComptime(.{ .{"__file__"}, .{"__path__"}, .{"__package__"}, .{"__spec__"}, .{"__name__"}, .{"__doc__"}, .{"__cached__"}, .{"__loader__"} });

fn lineEnd(source: []const u8, at: u32) u32 {
    var i: usize = at;
    while (i < source.len and source[i] != '\n') i += 1;
    if (i < source.len) i += 1;
    return @intCast(i);
}

fn tidiedCut(source: []const u8, cut: Span) Span {
    const blank = " \t\r\n";
    var start = cut.start;
    var end = cut.end;
    if (std.mem.trim(u8, source[0..start], blank).len == 0) {
        while (end < source.len and std.mem.indexOfScalar(u8, blank, source[end]) != null) end += 1;
        start = 0;
    } else if (std.mem.trim(u8, source[end..], blank).len == 0) {
        const kept = std.mem.trimEnd(u8, source[0..start], blank);
        var line_end: u32 = @intCast(kept.len);
        while (line_end < start and source[line_end] != '\n') line_end += 1;
        if (line_end < start) line_end += 1;
        start = line_end;
        end = @intCast(source.len);
    } else {
        var next = end;
        while (next < source.len and std.mem.indexOfScalar(u8, blank, source[next]) != null) {
            if (source[next] == '\n') end = next + 1;
            next += 1;
        }
    }
    return .{ .start = start, .end = end };
}

fn insertAfter(arena: Allocator, edits: *std.ArrayList(TextEdit), source: []const u8, statement_end: u32, indent: []const u8, text: []const u8) !void {
    const at = lineEnd(source, statement_end);
    const newline = py.newlineOf(source);
    if (at != 0 and source[at - 1] == '\n') {
        try edits.append(arena, .{ .start = at, .end = at, .text = try std.mem.concat(arena, u8, &.{ indent, text, newline }) });
    } else {
        try edits.append(arena, .{ .start = at, .end = at, .text = try std.mem.concat(arena, u8, &.{ newline, indent, text, newline }) });
    }
}

pub fn importPoint(snapshot: *const Snapshot) u32 {
    const root = snapshot.tree.root();
    var at: u32 = 0;
    var i: u32 = 0;
    var first = true;
    while (root.namedChild(i)) |node| : (i += 1) {
        const kind = node.kind();
        if (std.mem.eql(u8, kind, "comment")) {
            const text = snapshot.tree.text(node);
            if (at == 0 and node.startByte() < 2 or (at != 0 and first)) {
                if (std.mem.startsWith(u8, text, "#!") or std.mem.indexOf(u8, text, "coding") != null) {
                    at = lineEnd(snapshot.source, node.endByte());
                }
            }
            continue;
        }
        const docstring = first and std.mem.eql(u8, kind, "expression_statement") and node.namedChild(0) != null and std.mem.eql(u8, node.namedChild(0).?.kind(), "string");
        first = false;
        if (docstring or std.mem.eql(u8, kind, "future_import_statement") or std.mem.eql(u8, kind, "import_statement") or std.mem.eql(u8, kind, "import_from_statement")) {
            at = lineEnd(snapshot.source, node.endByte());
            continue;
        }
        break;
    }
    return at;
}

fn specFor(m: *const Move, importer: []const u8, relative: bool, target: []const u8) ![]const u8 {
    const logical = py.moduleLogical(target);
    if (relative) {
        if (try py.relativeOf(m.cx, m.w.existing, importer, logical, true)) |text| {
            if (py.sameOptional(try py.resolve(m.cx, m.w.existing, importer, text), target)) return text;
        }
    }
    if (try py.absoluteOf(m.cx, m.w.existing, importer, target)) |text| return text;
    if (!relative) {
        if (try py.relativeOf(m.cx, m.w.existing, importer, logical, true)) |text| {
            if (py.sameOptional(try py.resolve(m.cx, m.w.existing, importer, text), target)) return text;
        }
    }
    return error.PyTargetNotImportable;
}

fn itemLine(arena: Allocator, spec: []const u8, item: Named) ![]const u8 {
    if (item.alias) |alias| return std.fmt.allocPrint(arena, "from {s} import {s} as {s}", .{ spec, item.name, alias });
    return std.fmt.allocPrint(arena, "from {s} import {s}", .{ spec, item.name });
}

fn itemsLine(arena: Allocator, spec: []const u8, items: []const Named) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "from {s} import ", .{spec});
    for (items, 0..) |item, i| {
        if (i != 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, item.name);
        if (item.alias) |alias| try out.print(arena, " as {s}", .{alias});
    }
    return out.items;
}

fn rewriteFrom(m: *Move, abs: []const u8, source: []const u8, entry: Import, edits: *std.ArrayList(TextEdit)) !void {
    const arena = m.cx.arena;
    var moving: ?Named = null;
    var others: std.ArrayList(Named) = .empty;
    for (entry.named) |item| {
        if (moving == null and std.mem.eql(u8, item.name, m.name)) {
            moving = item;
        } else if (std.mem.eql(u8, item.name, m.name)) {
            return error.PyImportUnprovable;
        } else {
            try others.append(arena, item);
        }
    }
    const item = moving orelse return;
    const spec = try specFor(m, abs, entry.spec[0] == '.', m.target_abs);
    m.imports_added += 1;
    if (mb.faulted(.drop_user_import)) {
        try edits.append(arena, .{ .start = entry.statement.start, .end = entry.statement.end, .text = if (others.items.len == 0) "pass" else try itemsLine(arena, entry.spec, others.items) });
        return;
    }
    if (others.items.len == 0) {
        const span = py.specSpan(source, entry.spec);
        try edits.append(arena, .{ .start = span.start, .end = span.end, .text = spec });
        return;
    }
    if (std.mem.indexOfScalar(u8, source[entry.statement.start..entry.statement.end], '#') != null) return error.PyImportUnprovable;
    const indent = py.lineIndent(source, entry.statement.start) orelse return error.PyImportUnprovable;
    if (!py.endsStatementLine(source, entry.statement.end)) return error.PyImportUnprovable;
    try edits.append(arena, .{ .start = entry.statement.start, .end = entry.statement.end, .text = try itemsLine(arena, entry.spec, others.items) });
    try insertAfter(arena, edits, source, entry.statement.end, indent, try itemLine(arena, spec, item));
}

fn binderIsSoleImports(cx: Cx, snapshot: *Snapshot, entries: []const Import, name: []const u8, allow_from_of: ?[]const u8) !bool {
    const resolution = try scope.resolveName(cx.arena, snapshot, name);
    for (resolution.binders) |binder| if (!binder.import) return false;
    for (resolution.uses) |use| if (use.binder == null) return false;
    for (try py.bindingsOf(cx, snapshot.source, entries)) |binding| {
        if (!std.mem.eql(u8, binding.local, name)) continue;
        if (binding.plain) continue;
        if (allow_from_of) |wanted| {
            if (std.mem.eql(u8, binding.dotted, wanted)) continue;
        }
        return false;
    }
    return true;
}

fn addImportOnce(m: *Move, source: []const u8, edits: *std.ArrayList(TextEdit), added: *std.StringHashMapUnmanaged(void), entry: Import, text: []const u8) !void {
    const arena = m.cx.arena;
    const key = try std.fmt.allocPrint(arena, "{d}:{s}", .{ entry.statement.start, text });
    if (added.contains(key)) return;
    try added.put(arena, key, {});
    const indent = py.lineIndent(source, entry.statement.start) orelse return error.PyImportUnprovable;
    if (!py.endsStatementLine(source, entry.statement.end)) return error.PyImportUnprovable;
    try insertAfter(arena, edits, source, entry.statement.end, indent, text);
    m.imports_added += 1;
}

fn hasPlainImport(source: []const u8, entries: []const Import, entry: Import, dotted: []const u8) bool {
    for (entries) |other| {
        if (py.isFromStatement(source, other) or py.isAliased(source, other)) continue;
        if (other.scoped != entry.scoped) continue;
        if (std.mem.eql(u8, other.spec, dotted)) return true;
    }
    return false;
}

fn moduleBinding(m: *Move, abs: []const u8, bindings: []const py.Binding, snapshots: *const std.StringHashMapUnmanaged(*Snapshot), root_name: []const u8, tail: []const u8, wanted: []const u8) !?py.Binding {
    for (bindings) |binding| {
        if (!std.mem.eql(u8, binding.local, root_name)) continue;
        const composed = try py.joinSpec(m.cx.arena, binding.dotted, tail);
        const hit = try py.resolve(m.cx, m.w.existing, abs, composed);
        if (hit == null or !tsserver.sameFile(hit.?, wanted)) continue;
        if (binding.item != null) {
            const package = try py.resolve(m.cx, m.w.existing, abs, binding.entry.spec);
            if (package) |init_path| {
                if (!py.isPackageInit(init_path)) continue;
                if (snapshots.get(init_path)) |init_snapshot| {
                    if (try py.initBindsOther(m.cx, init_path, init_snapshot, binding.item.?.name, hit.?, m.w.existing)) continue;
                }
            }
        }
        return binding;
    }
    return null;
}

fn rewriteChains(m: *Move, abs: []const u8, snapshot: *Snapshot, entries: []const Import, snapshots: *const std.StringHashMapUnmanaged(*Snapshot), edits: *std.ArrayList(TextEdit), added: *std.StringHashMapUnmanaged(void)) !usize {
    const arena = m.cx.arena;
    const bindings = try py.bindingsOf(m.cx, snapshot.source, entries);
    if (bindings.len == 0) return 0;
    var count: usize = 0;
    var stack: std.ArrayList(ts.Node) = .empty;
    try stack.append(arena, snapshot.tree.root());
    while (stack.pop()) |node| {
        var i: u32 = 0;
        while (node.child(i)) |child| : (i += 1) try stack.append(arena, child);
        if (!std.mem.eql(u8, node.kind(), "attribute")) continue;
        const attribute = node.childByField("attribute") orelse continue;
        if (!std.mem.eql(u8, snapshot.tree.text(attribute), m.name)) continue;
        const object = node.childByField("object") orelse continue;
        var root_node = object;
        while (std.mem.eql(u8, root_node.kind(), "attribute")) root_node = root_node.childByField("object") orelse break;
        if (!std.mem.eql(u8, root_node.kind(), "identifier")) continue;
        const root_name = snapshot.tree.text(root_node);
        const dotted = try py.segmentsAfter(arena, snapshot.tree.text(object));
        const tail = if (dotted.len > root_name.len) dotted[root_name.len + 1 ..] else "";
        const resolution = try scope.resolveName(arena, snapshot, root_name);
        const use = resolution.useAt(.{ .start = root_node.startByte(), .end = root_node.endByte() }) orelse continue;
        const binder_index = use.binder orelse continue;
        if (!resolution.binders[binder_index].import) continue;
        const binding = (try moduleBinding(m, abs, bindings, snapshots, root_name, tail, m.source_abs)) orelse continue;
        count += 1;
        const logical = py.moduleLogical(m.target_abs);
        const stem = std.fs.path.basename(logical);
        if (!py.isIdentifier(stem)) return error.PyTargetNotImportable;
        if (binding.item != null and tail.len == 0) {
            const relative = binding.entry.spec[0] == '.';
            const dir = std.fs.path.dirname(logical).?;
            var parent: []const u8 = "";
            if (relative) {
                if (try py.relativeOf(m.cx, m.w.existing, abs, dir, true)) |text| parent = text;
            }
            if (parent.len == 0) {
                const absolute = (try py.absoluteOf(m.cx, m.w.existing, abs, m.target_abs)) orelse return error.PyTargetNotImportable;
                if (std.mem.lastIndexOfScalar(u8, absolute, '.')) |dot| parent = absolute[0..dot];
            }
            const wanted = try py.joinSpec(arena, parent, stem);
            if (!try binderIsSoleImports(m.cx, snapshot, entries, stem, wanted)) return error.TargetNameTaken;
            var present = false;
            for (bindings) |other| {
                if (std.mem.eql(u8, other.local, stem) and std.mem.eql(u8, other.dotted, wanted)) present = true;
            }
            if (!present) {
                const text = if (parent.len == 0)
                    try std.fmt.allocPrint(arena, "import {s}", .{stem})
                else
                    try std.fmt.allocPrint(arena, "from {s} import {s}", .{ parent, stem });
                try addImportOnce(m, snapshot.source, edits, added, binding.entry, text);
            }
            try edits.append(arena, .{ .start = object.startByte(), .end = object.endByte(), .text = stem });
            continue;
        }
        const absolute = (try py.absoluteOf(m.cx, m.w.existing, abs, m.target_abs)) orelse return error.PyTargetNotImportable;
        if (!try binderIsSoleImports(m.cx, snapshot, entries, py.firstSegment(absolute), null)) return error.PyNameCapture;
        if (!hasPlainImport(snapshot.source, entries, binding.entry, absolute)) {
            try addImportOnce(m, snapshot.source, edits, added, binding.entry, try std.fmt.allocPrint(arena, "import {s}", .{absolute}));
        }
        try edits.append(arena, .{ .start = object.startByte(), .end = object.endByte(), .text = absolute });
    }
    return count;
}

fn unboundUses(arena: Allocator, snapshot: *Snapshot, name: []const u8) !usize {
    const resolution = try scope.resolveName(arena, snapshot, name);
    var count: usize = 0;
    for (resolution.uses) |use| {
        if (use.binder == null) count += 1;
    }
    return count;
}

fn scanUser(m: *Move, abs: []const u8, snapshot: *Snapshot, snapshots: *const std.StringHashMapUnmanaged(*Snapshot), stars: *std.ArrayList([]const u8)) !std.ArrayList(TextEdit) {
    const arena = m.cx.arena;
    var edits: std.ArrayList(TextEdit) = .empty;
    var added: std.StringHashMapUnmanaged(void) = .empty;
    const entries = try modules.imports(arena, snapshot);
    for (entries) |entry| {
        if (!py.isFromStatement(snapshot.source, entry)) continue;
        const module_target = try py.resolve(m.cx, m.w.existing, abs, entry.spec);
        if (!m.isSource(module_target)) continue;
        if (entry.form == .bare) {
            if (py.isPackageInit(abs)) return error.ReExported;
            try stars.append(arena, abs);
            if (try unboundUses(arena, snapshot, m.name) != 0) {
                const spec = try specFor(m, abs, entry.spec[0] == '.', m.target_abs);
                try addImportOnce(m, snapshot.source, &edits, &added, entry, try std.fmt.allocPrint(arena, "from {s} import {s}", .{ spec, m.name }));
            }
            continue;
        }
        try rewriteFrom(m, abs, snapshot.source, entry, &edits);
    }
    _ = try rewriteChains(m, abs, snapshot, entries, snapshots, &edits, &added);
    return edits;
}

fn futuresOf(arena: Allocator, snapshot: *const Snapshot) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const root = snapshot.tree.root();
    var i: u32 = 0;
    while (root.namedChild(i)) |node| : (i += 1) {
        if (!std.mem.eql(u8, node.kind(), "future_import_statement")) continue;
        const text = snapshot.tree.text(node);
        const at = std.mem.indexOf(u8, text, "import") orelse continue;
        var names = std.mem.tokenizeAny(u8, text[at + 6 ..], ", ()\r\n\t");
        while (names.next()) |word| try out.append(arena, word);
    }
    std.mem.sort([]const u8, out.items, {}, lessString);
    return out.items;
}

fn lessString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn sameWords(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

fn namesGlobal(arena: Allocator, snapshot: *const Snapshot, within: ?symbol.Span, name: ?[]const u8) !bool {
    var stack: std.ArrayList(ts.Node) = .empty;
    try stack.append(arena, snapshot.tree.root());
    while (stack.pop()) |node| {
        var i: u32 = 0;
        while (node.child(i)) |child| : (i += 1) try stack.append(arena, child);
        if (!std.mem.eql(u8, node.kind(), "global_statement")) continue;
        if (within) |span| {
            if (node.startByte() < span.start or node.endByte() > span.end) continue;
        }
        const wanted = name orelse return true;
        var j: u32 = 0;
        while (node.namedChild(j)) |child| : (j += 1) {
            if (std.mem.eql(u8, snapshot.tree.text(child), wanted)) return true;
        }
    }
    return false;
}

fn sameBindingInTarget(m: *const Move, target: *Snapshot, local: []const u8, wanted: ?[]const u8, plain_spec: ?[]const u8) !bool {
    const entries = try modules.imports(m.cx.arena, target);
    for (try py.bindingsOf(m.cx, target.source, entries)) |binding| {
        if (!std.mem.eql(u8, binding.local, local)) continue;
        if (plain_spec) |spec| {
            if (binding.plain and std.mem.eql(u8, binding.entry.spec, spec)) return true;
            continue;
        }
        const hit = try py.resolve(m.cx, m.w.existing, m.target_abs, binding.dotted);
        if (wanted) |file| {
            if (py.sameOptional(hit, file)) return true;
        }
    }
    return false;
}

const Dependency = struct {
    needed: std.ArrayList([]const u8) = .empty,
    dropped: std.ArrayList([]const u8) = .empty,
    from_target: std.ArrayList([]const u8) = .empty,
    from_source: bool = false,
};

fn textBinds(arena: Allocator, target: ?*Snapshot, name: []const u8) !bool {
    const t = target orelse return false;
    return (try scope.resolveName(arena, t, name)).binders.len != 0;
}

fn dependencies(m: *Move, source: *Snapshot, target: ?*Snapshot, moved: mb.Moved, mentioned: []const py_file_move.Pair) !Dependency {
    const arena = m.cx.arena;
    var dep: Dependency = .{};
    const free = try modules.freeNames(arena, source, moved.cut);
    const source_entries = try modules.imports(arena, source);
    const source_bindings = try py.bindingsOf(m.cx, source.source, source_entries);
    for (free) |f| {
        const binder = f.binder orelse {
            if (dunders.has(f.name)) return error.PyModuleDunder;
            if (try textBinds(arena, target, f.name)) return error.TargetCapture;
            continue;
        };
        const resolution = try scope.resolveName(arena, source, f.name);
        if (mb.topBinders(resolution, source.tree.root()) > 1 and !f.import) return error.PyGlobalState;
        if (try namesGlobal(arena, source, null, f.name)) return error.PyGlobalState;
        if (!f.import) {
            if (try textBinds(arena, target, f.name)) return error.TargetCapture;
            const spec = try specFor(m, m.target_abs, try py.packageDepth(m.cx, m.w.existing, m.source_abs) != 0, m.source_abs);
            try dep.needed.append(arena, try std.fmt.allocPrint(arena, "from {s} import {s}", .{ spec, f.name }));
            dep.from_source = true;
            continue;
        }
        var kept_plain = false;
        for (source_bindings) |binding| {
            if (!std.mem.eql(u8, binding.local, f.name)) continue;
            const line = try importLineFor(m, target, f.name, binding, &dep);
            if (line) |text| {
                var seen = false;
                for (dep.needed.items) |other| {
                    if (std.mem.eql(u8, other, text)) seen = true;
                }
                if (!seen) try dep.needed.append(arena, text);
            }
            kept_plain = true;
        }
        if (!kept_plain) return error.UnsupportedImport;
        if (!try mb.usesOutside(arena, source, f.name, moved.cut, binder) and !py.isPackageInit(m.source_abs)) {
            var mentioned_elsewhere = false;
            for (mentioned) |pair| {
                if (tsserver.sameFile(pair.abs, m.source_abs)) continue;
                if (std.mem.indexOf(u8, pair.snapshot.source, f.name) != null) mentioned_elsewhere = true;
            }
            if (!mentioned_elsewhere) try dep.dropped.append(arena, f.name);
        }
    }
    return dep;
}

fn importLineFor(m: *Move, target: ?*Snapshot, local: []const u8, binding: py.Binding, dep: *Dependency) !?[]const u8 {
    const arena = m.cx.arena;
    const spec = binding.entry.spec;
    if (binding.item) |item| {
        const module_target = try py.resolve(m.cx, m.w.existing, m.source_abs, spec);
        const sub = try py.resolve(m.cx, m.w.existing, m.source_abs, binding.dotted);
        if (m.isTarget(module_target) or m.isTarget(sub)) {
            try dep.from_target.append(arena, local);
            return null;
        }
        var new_spec = spec;
        if (spec[0] == '.') {
            const logical = (try py.logicalOf(m.cx, m.source_abs, spec)) orelse return error.UnresolvedImport;
            new_spec = (try py.relativeOf(m.cx, m.w.existing, m.target_abs, logical, true)) orelse
                (if (module_target) |file| try py.absoluteOf(m.cx, m.w.existing, m.target_abs, file) else null) orelse
                (try py.absoluteOfDir(m.cx, m.w.existing, m.target_abs, logical)) orelse return error.UnresolvedImport;
        }
        const now = try py.resolve(m.cx, m.w.existing, m.target_abs, new_spec);
        if (!py.sameOptional(now, module_target)) return error.UnresolvedImport;
        const now_sub = try py.resolve(m.cx, m.w.existing, m.target_abs, try py.joinSpec(arena, new_spec, item.name));
        if (!py.sameOptional(now_sub, sub)) return error.UnresolvedImport;
        if (try textBinds(arena, target, local)) {
            if (try targetHasFrom(m, target.?, local, item.name, module_target, sub, new_spec)) return null;
            return error.TargetCapture;
        }
        return try itemLine(arena, new_spec, item);
    }
    const before = try py.resolve(m.cx, m.w.existing, m.source_abs, spec);
    const now = try py.resolve(m.cx, m.w.existing, m.target_abs, spec);
    if (!py.sameOptional(before, now)) return error.UnresolvedImport;
    if (m.isTarget(before)) return error.TargetAliasUse;
    if (try textBinds(arena, target, local)) {
        if (try sameBindingInTarget(m, target.?, local, before, if (binding.plain) spec else null)) return null;
        if (binding.plain) {
            const resolution = try scope.resolveName(arena, target.?, local);
            for (resolution.binders) |b| if (!b.import) return error.TargetCapture;
            for (try py.bindingsOf(m.cx, target.?.source, try modules.imports(arena, target.?))) |other| {
                if (std.mem.eql(u8, other.local, local) and !other.plain) return error.TargetCapture;
            }
        } else return error.TargetCapture;
    }
    if (py.isAliased(m.source_snapshot.source, binding.entry)) return try std.fmt.allocPrint(arena, "import {s} as {s}", .{ spec, local });
    return try std.fmt.allocPrint(arena, "import {s}", .{spec});
}

fn targetHasFrom(m: *const Move, target: *Snapshot, local: []const u8, name: []const u8, module_target: ?[]const u8, sub: ?[]const u8, spec: []const u8) !bool {
    const arena = m.cx.arena;
    for (try modules.imports(arena, target)) |entry| {
        if (!py.isFromStatement(target.source, entry)) continue;
        for (entry.named) |item| {
            if (!std.mem.eql(u8, item.local(), local) or !std.mem.eql(u8, item.name, name)) continue;
            if (std.mem.eql(u8, entry.spec, spec)) return true;
            const hit = try py.resolve(m.cx, m.w.existing, m.target_abs, entry.spec);
            if (module_target != null and py.sameOptional(hit, module_target)) return true;
            const hit_sub = try py.resolve(m.cx, m.w.existing, m.target_abs, try py.joinSpec(arena, entry.spec, name));
            if (sub != null and py.sameOptional(hit_sub, sub)) return true;
        }
    }
    return false;
}

fn dropBindings(m: *const Move, source: *Snapshot, dropped: []const []const u8, edits: *std.ArrayList(TextEdit)) !void {
    if (dropped.len == 0) return;
    const arena = m.cx.arena;
    const entries = try modules.imports(arena, source);
    var done: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (entries) |entry| {
        if (entry.scoped) continue;
        const text = source.source;
        if ((try done.getOrPut(arena, entry.statement.start)).found_existing) continue;
        if (std.mem.indexOfScalar(u8, text[entry.statement.start..entry.statement.end], '#') != null) continue;
        if (py.lineIndent(text, entry.statement.start) == null or !py.endsStatementLine(text, entry.statement.end)) continue;
        if (py.isFromStatement(text, entry)) {
            if (entry.form == .bare) continue;
            var kept: std.ArrayList(Named) = .empty;
            for (entry.named) |item| {
                if (!contains(dropped, item.local())) try kept.append(arena, item);
            }
            if (kept.items.len == entry.named.len) continue;
            if (kept.items.len == 0) {
                try edits.append(arena, .{ .start = entry.statement.start, .end = mb.lineEndAfter(text, entry.statement.end), .text = "" });
            } else {
                try edits.append(arena, .{ .start = entry.statement.start, .end = entry.statement.end, .text = try itemsLine(arena, entry.spec, kept.items) });
            }
            continue;
        }
        var kept: std.ArrayList(u8) = .empty;
        var removed = false;
        for (entries) |other| {
            if (other.statement.start != entry.statement.start) continue;
            if (other.namespace) |local| {
                if (contains(dropped, local)) {
                    removed = true;
                    continue;
                }
            }
            if (kept.items.len != 0) try kept.appendSlice(arena, ", ");
            try kept.appendSlice(arena, other.spec);
            if (py.isAliased(text, other)) try kept.print(arena, " as {s}", .{other.namespace.?});
        }
        if (!removed) continue;
        if (kept.items.len == 0) {
            try edits.append(arena, .{ .start = entry.statement.start, .end = mb.lineEndAfter(text, entry.statement.end), .text = "" });
        } else {
            try edits.append(arena, .{ .start = entry.statement.start, .end = entry.statement.end, .text = try std.fmt.allocPrint(arena, "import {s}", .{kept.items}) });
        }
    }
}

fn contains(list: []const []const u8, word: []const u8) bool {
    for (list) |other| if (std.mem.eql(u8, other, word)) return true;
    return false;
}

const Graph = struct {
    m: *const Move,
    afters: *const std.StringHashMapUnmanaged(*const Snapshot),
    opened: *std.ArrayList(*Snapshot),
    use_after: bool,

    fn snapshotOf(self: Graph, abs: []const u8) !?*const Snapshot {
        if (self.use_after) {
            var it = self.afters.iterator();
            while (it.next()) |hit| {
                if (tsserver.sameFile(hit.key_ptr.*, abs)) return hit.value_ptr.*;
            }
        }
        const snapshot = py.load(self.m.cx, abs, null) catch return null;
        try self.opened.append(self.m.cx.arena, snapshot);
        return snapshot;
    }

    fn reaches(self: Graph, start: []const u8, goal: []const u8) !bool {
        const arena = self.m.cx.arena;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var stack: std.ArrayList([]const u8) = .empty;
        try stack.append(arena, start);
        while (stack.pop()) |abs| {
            const snapshot = (try self.snapshotOf(abs)) orelse continue;
            for (try modules.imports(arena, snapshot)) |entry| {
                if (entry.scoped) continue;
                var hits: std.ArrayList(?[]const u8) = .empty;
                try hits.append(arena, try py.resolve(self.m.cx, self.m.w.existing, abs, entry.spec));
                for (entry.named) |item| try hits.append(arena, try py.resolve(self.m.cx, self.m.w.existing, abs, try py.joinSpec(arena, entry.spec, item.name)));
                for (hits.items) |hit| {
                    const file = hit orelse continue;
                    if (tsserver.sameFile(file, goal)) return true;
                    const key = try std.ascii.allocLowerString(arena, file);
                    if ((try seen.getOrPut(arena, key)).found_existing) continue;
                    try stack.append(arena, file);
                }
            }
        }
        return false;
    }
};

pub fn plan(w: mb.Work, request: mb.Request, source: *Snapshot, target: ?*Snapshot, opened: *std.ArrayList(*Snapshot)) !mb.Plan {
    const arena = w.arena;
    if (!paths.isPythonPath(request.target_abs)) return error.UnsupportedLanguage;
    const cx: Cx = .{ .arena = arena, .io = w.io, .runtime = w.runtime, .root = w.root };
    const ref = try symbol.Ref.parse(arena, request.ref_text);
    const moved = try mb.locateMoved(arena, source, ref, request.expected_hash);
    const name = moved.name;
    var m: Move = .{ .w = w, .cx = cx, .source_abs = request.file_abs, .target_abs = request.target_abs, .name = name, .source_snapshot = source };

    const source_resolution = try scope.resolveName(arena, source, name);
    if (mb.topBinders(source_resolution, source.tree.root()) != 1) return error.MergedDeclaration;
    if (rename.dynamicAccess(source, name, false) != null) return error.DynamicReference;
    if (try py.stringNaming(source, arena, &.{}, name)) return error.DynamicReference;
    if (try namesGlobal(arena, source, moved.cut, null) or try namesGlobal(arena, source, null, name)) return error.PyGlobalState;

    const source_futures = try futuresOf(arena, source);
    if (target) |t| {
        if (!sameWords(source_futures, try futuresOf(arena, t))) return error.PyFutureMismatch;
    }

    const source_dotted = try dottedNames(cx, w.existing, request.file_abs, name);
    var mentioned: std.ArrayList(py_file_move.Pair) = .empty;
    var snapshots: std.StringHashMapUnmanaged(*Snapshot) = .empty;
    const listing = try repo.filesMentioning(arena, w.io, w.root, name);
    var listed = std.mem.tokenizeScalar(u8, listing, 0);
    while (listed.next()) |rel| {
        if (!paths.isPythonPath(rel)) continue;
        const abs = try std.fmt.allocPrint(arena, "{s}\\{s}", .{ w.root, rel });
        std.mem.replaceScalar(u8, abs, '/', '\\');
        if (tsserver.sameFile(abs, request.file_abs) or tsserver.sameFile(abs, request.target_abs)) continue;
        const snapshot = try mb.loadSnapshot(w, abs);
        try opened.append(arena, snapshot);
        try mentioned.append(arena, .{ .abs = abs, .snapshot = snapshot });
        try snapshots.put(arena, abs, snapshot);
    }
    for (try py.trackedPython(cx)) |abs| {
        if (!py.isPackageInit(abs) or snapshots.contains(abs)) continue;
        const snapshot = py.load(cx, abs, null) catch continue;
        try opened.append(arena, snapshot);
        try snapshots.put(arena, abs, snapshot);
    }

    var stars: std.ArrayList([]const u8) = .empty;
    var outputs: std.ArrayList(mb.Output) = .empty;
    try outputs.append(arena, undefined);
    try outputs.append(arena, undefined);
    var user_edits: std.ArrayList(std.ArrayList(TextEdit)) = .empty;
    for (mentioned.items) |pair| {
        if (rename.dynamicAccess(pair.snapshot, name, false) != null) return error.DynamicReference;
        if (try py.stringNaming(pair.snapshot, arena, source_dotted, null)) return error.DynamicReference;
        for (try modules.dynamicSpecs(arena, pair.snapshot)) |d| {
            const literal = d.literal orelse continue;
            if (m.isSource(try py.resolve(cx, w.existing, pair.abs, literal))) return error.DynamicReference;
        }
        const edits = try scanUser(&m, pair.abs, pair.snapshot, &snapshots, &stars);
        if (edits.items.len == 0) continue;
        const text = try mb.applyEdits(arena, pair.snapshot.source, edits.items);
        try outputs.append(arena, .{ .abs = pair.abs, .before = pair.snapshot, .text = text, .holes = try mb.holesOf(arena, edits.items) });
        try user_edits.append(arena, edits);
    }
    for (stars.items) |star_abs| {
        for (mentioned.items) |pair| {
            for (try modules.imports(arena, pair.snapshot)) |entry| {
                if (!py.sameOptional(try py.resolve(cx, w.existing, pair.abs, entry.spec), star_abs)) continue;
                for (entry.named) |item| {
                    if (std.mem.eql(u8, item.name, name)) return error.ReExported;
                }
            }
        }
    }
    const users = outputs.items.len - 2;
    const interface_change = users != 0;
    if (interface_change and !request.interface_change) return error.InterfaceChangeNeedsApproval;

    var needs_order = symmetry.statementHasEffect(source.profile, moved.statement) or modules.hasModuleEffects(source);
    if (target) |t| {
        if (modules.hasModuleEffects(t)) needs_order = true;
    }
    if (needs_order and !request.order_change) return error.ModuleSideEffect;

    var target_self: ?Import = null;
    if (target) |t| {
        const entries = try modules.imports(arena, t);
        for (entries) |entry| {
            if (!py.isFromStatement(t.source, entry)) {
                continue;
            }
            if (!m.isSource(try py.resolve(cx, w.existing, request.target_abs, entry.spec))) continue;
            for (entry.named) |item| {
                if (!std.mem.eql(u8, item.name, name)) continue;
                if (item.alias != null) return error.TargetAliasUse;
                target_self = entry;
            }
        }
        var chain_edits: std.ArrayList(TextEdit) = .empty;
        var chain_added: std.StringHashMapUnmanaged(void) = .empty;
        if (try rewriteChains(&m, request.target_abs, t, entries, &snapshots, &chain_edits, &chain_added) != 0) return error.TargetAliasUse;
        const resolution = try scope.resolveName(arena, t, name);
        const allowed: usize = if (target_self != null) 1 else 0;
        if (resolution.binders.len != allowed) return error.TargetNameTaken;
        if (target_self == null and resolution.uses.len != 0) return error.TargetNameTaken;
    }

    const dep = try dependencies(&m, source, target, moved, mentioned.items);

    var source_edits: std.ArrayList(TextEdit) = .empty;
    const tidy = tidiedCut(source.source, moved.cut);
    try source_edits.append(arena, .{ .start = tidy.start, .end = tidy.end, .text = "" });
    try dropBindings(&m, source, dep.dropped.items, &source_edits);
    var imports_added: usize = dep.needed.items.len;
    if (try mb.usesOutside(arena, source, name, moved.cut, null)) {
        const spec = try specFor(&m, request.file_abs, try py.packageDepth(cx, w.existing, request.file_abs) != 0, request.target_abs);
        const at = importPoint(source);
        try source_edits.append(arena, .{ .start = at, .end = at, .text = try std.fmt.allocPrint(arena, "from {s} import {s}{s}", .{ spec, name, py.newlineOf(source.source) }) });
        imports_added += 1;
    }
    const source_new = try mb.applyEdits(arena, source.source, source_edits.items);

    const target_text: []const u8 = if (target) |t| t.source else "";
    const newline: []const u8 = if (target) |t| py.newlineOf(t.source) else py.newlineOf(source.source);
    var target_edits: std.ArrayList(TextEdit) = .empty;
    if (target_self) |entry| {
        var kept: std.ArrayList(Named) = .empty;
        for (entry.named) |item| {
            if (!std.mem.eql(u8, item.name, name)) try kept.append(arena, item);
        }
        if (kept.items.len == 0) {
            try target_edits.append(arena, .{ .start = entry.statement.start, .end = mb.lineEndAfter(target_text, entry.statement.end), .text = "" });
        } else {
            try target_edits.append(arena, .{ .start = entry.statement.start, .end = entry.statement.end, .text = try itemsLine(arena, entry.spec, kept.items) });
        }
    }
    const at: u32 = if (target) |t| importPoint(t) else 0;
    if (target == null and source_futures.len != 0) {
        var line: std.ArrayList(u8) = .empty;
        try line.appendSlice(arena, "from __future__ import ");
        for (source_futures, 0..) |word, i| {
            if (i != 0) try line.appendSlice(arena, ", ");
            try line.appendSlice(arena, word);
        }
        try line.appendSlice(arena, newline);
        try target_edits.append(arena, .{ .start = at, .end = at, .text = line.items });
    }
    for (dep.needed.items) |text| try target_edits.append(arena, .{ .start = at, .end = at, .text = try std.mem.concat(arena, u8, &.{ text, newline }) });
    const moved_text = source.source[moved.cut.start..moved.cut.end];
    const tail: u32 = @intCast(target_text.len);
    var separator: []const u8 = newline;
    if (target == null) {
        separator = if (target_edits.items.len == 0) "" else newline;
    } else if (target_text.len == 0) {
        separator = "";
    } else if (!std.mem.endsWith(u8, target_text, "\n")) {
        separator = try std.mem.concat(arena, u8, &.{ newline, newline });
    }
    const closing: []const u8 = if (std.mem.endsWith(u8, moved_text, "\n")) "" else newline;
    try target_edits.append(arena, .{ .start = tail, .end = tail, .text = try std.mem.concat(arena, u8, &.{ separator, moved_text, closing }) });
    const target_new = try mb.applyEdits(arena, target_text, target_edits.items);
    const moved_start: u32 = @intCast(std.mem.lastIndexOf(u8, target_new, moved_text).?);

    outputs.items[0] = .{ .abs = request.file_abs, .before = source, .text = source_new, .holes = try mb.holesOf(arena, source_edits.items) };
    outputs.items[1] = .{ .abs = request.target_abs, .before = target, .text = target_new, .creates = target == null, .ref_text = request.ref_text, .body = .{ .start = moved_start, .end = moved_start + @as(u32, @intCast(moved_text.len)) }, .holes = try mb.holesOf(arena, target_edits.items) };

    var afters: std.ArrayList(*Snapshot) = .empty;
    defer for (afters.items) |s| s.destroy();
    for (outputs.items) |o| {
        const after = try py.load(cx, o.abs, o.text);
        try afters.append(arena, after);
        if (after.tree.root().hasError()) return error.MutationSyntaxInvalid;
    }
    const moved_hash = try mb.proveMoved(afters.items[1], ref, request.expected_hash, moved.function);
    try mb.proveUnchanged(source, afters.items[0], moved.cut, false);
    if (target) |t| try mb.proveUnchanged(t, afters.items[1], .{ .start = 0, .end = 0 }, true);
    for (outputs.items[2..], afters.items[2..], user_edits.items) |o, after, edits| {
        try file_move.proveOnlyRewritten(o.before.?, after, edits.items, false);
        if (try unboundUses(arena, after, name) > try unboundUses(arena, o.before.?, name)) return error.IncompleteMove;
        if (try stillNamesSource(&m, o.abs, after, &snapshots)) return error.IncompleteMove;
    }
    if (try unboundUses(arena, afters.items[0], name) != 0) return error.IncompleteMove;
    for (mentioned.items) |pair| {
        var rewritten = false;
        for (outputs.items[2..]) |o| {
            if (tsserver.sameFile(o.abs, pair.abs)) rewritten = true;
        }
        if (rewritten) continue;
        if (try stillNamesSource(&m, pair.abs, pair.snapshot, &snapshots)) return error.IncompleteMove;
    }
    for (try modules.freeNames(arena, afters.items[1], outputs.items[1].body)) |f| {
        if (dunders.has(f.name)) return error.PyModuleDunder;
    }
    var after_map: std.StringHashMapUnmanaged(*const Snapshot) = .empty;
    for (outputs.items, afters.items) |o, after| try after_map.put(arena, o.abs, after);
    const graph_after: Graph = .{ .m = &m, .afters = &after_map, .opened = opened, .use_after = true };
    const graph_before: Graph = .{ .m = &m, .afters = &after_map, .opened = opened, .use_after = false };
    if (try graph_after.reaches(request.target_abs, request.target_abs)) {
        if (target == null or !try graph_before.reaches(request.target_abs, request.target_abs)) return error.ImportCycle;
    }
    if (try graph_after.reaches(request.file_abs, request.file_abs) and !try graph_before.reaches(request.file_abs, request.file_abs)) return error.ImportCycle;

    const result = try mb.buildFromGraph(w.gpa, w.root, outputs.items, afters.items, .{
        .resolver = .module_graph,
        .fallback = null,
        .interface_change = interface_change,
        .order_change = needs_order,
        .creates_target = target == null,
        .users = users,
        .imports_added = imports_added + m.imports_added,
        .moved_hash = moved_hash,
    }, opened);
    afters.clearRetainingCapacity();
    return result;
}

fn stillNamesSource(m: *Move, abs: []const u8, snapshot: *Snapshot, snapshots: *const std.StringHashMapUnmanaged(*Snapshot)) !bool {
    const arena = m.cx.arena;
    const entries = try modules.imports(arena, snapshot);
    for (entries) |entry| {
        if (!py.isFromStatement(snapshot.source, entry)) continue;
        if (!m.isSource(try py.resolve(m.cx, m.w.existing, abs, entry.spec))) continue;
        for (entry.named) |item| {
            if (std.mem.eql(u8, item.name, m.name)) return true;
        }
    }
    var edits: std.ArrayList(TextEdit) = .empty;
    var added: std.StringHashMapUnmanaged(void) = .empty;
    const saved = m.imports_added;
    defer m.imports_added = saved;
    return (try rewriteChains(m, abs, snapshot, entries, snapshots, &edits, &added)) != 0;
}

fn dottedNames(cx: Cx, existing: py.Existing, source_abs: []const u8, name: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try py.rootsOf(cx, existing, source_abs)) |base| {
        const logical = py.moduleLogical(source_abs);
        if (logical.len <= base.len or !std.ascii.eqlIgnoreCase(logical[0..base.len], base) or logical[base.len] != '\\') continue;
        const dotted = try cx.arena.dupe(u8, logical[base.len + 1 ..]);
        std.mem.replaceScalar(u8, dotted, '\\', '.');
        try out.append(cx.arena, try std.fmt.allocPrint(cx.arena, "{s}.{s}", .{ dotted, name }));
    }
    return out.items;
}
