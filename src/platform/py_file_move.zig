const std = @import("std");
const ts = @import("../engine/tree_sitter.zig");
const scope = @import("../engine/scope.zig");
const modules = @import("../engine/modules.zig");
const rename = @import("../engine/rename.zig");
const repo = @import("repo.zig");
const tsserver = @import("tsserver.zig");
const py = @import("py_modules.zig");
const paths = @import("module_paths.zig");
const Snapshot = @import("../engine/loader.zig").Snapshot;

const Allocator = std.mem.Allocator;
const Import = modules.Import;
const Named = modules.Named;
const Cx = py.Cx;
const Existing = py.Existing;
const TextEdit = py.TextEdit;

pub const Change = struct {
    abs: []const u8,
    snapshot: *Snapshot,
    edits: std.ArrayList(TextEdit) = .empty,
};

pub const Result = struct {
    changes: []Change,
    users: usize,
    rewritten: usize,
    note: ?[]const u8,
    interface_change: bool,
};

const Move = struct {
    cx: Cx,
    from: []const u8,
    to: []const u8,
    before: Existing,
    after: Existing,
    opened: *std.ArrayList(*Snapshot),
    snapshots: std.StringHashMapUnmanaged(*Snapshot) = .empty,

    fn mapped(self: *const Move, target: ?[]const u8) ?[]const u8 {
        const hit = target orelse return null;
        return if (tsserver.sameFile(hit, self.from)) self.to else hit;
    }

    fn afterImporter(self: *const Move, abs: []const u8) []const u8 {
        return if (tsserver.sameFile(abs, self.from)) self.to else abs;
    }
};

fn publicMention(cx: Cx, dotted: []const []const u8, from: []const u8) !bool {
    const rel = try repo.relativeUnder(cx.arena, cx.root, from);
    std.mem.replaceScalar(u8, rel, '\\', '/');
    for ([_][]const u8{ "pyproject.toml", "setup.cfg", "tox.ini", "pytest.ini", "MANIFEST.in" }) |name| {
        const path = try std.fmt.allocPrint(cx.arena, "{s}\\{s}", .{ cx.root, name });
        const bytes = std.Io.Dir.cwd().readFileAlloc(cx.io, path, cx.arena, .limited(4 * 1024 * 1024)) catch continue;
        if (std.mem.indexOf(u8, bytes, rel) != null) return true;
        for (dotted) |word| {
            if (std.mem.indexOfScalar(u8, word, '.') == null) continue;
            if (py.namesDotted(bytes, word)) return true;
        }
    }
    return false;
}

fn oldDottedNames(cx: Cx, existing: Existing, importer: []const u8, target: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try py.rootsOf(cx, existing, importer)) |base| {
        const logical = py.moduleLogical(target);
        if (logical.len <= base.len or !std.ascii.eqlIgnoreCase(logical[0..base.len], base) or logical[base.len] != '\\') continue;
        const dotted = try cx.arena.dupe(u8, logical[base.len + 1 ..]);
        std.mem.replaceScalar(u8, dotted, '\\', '.');
        var seen = false;
        for (out.items) |other| {
            if (std.mem.eql(u8, other, dotted)) seen = true;
        }
        if (!seen) try out.append(cx.arena, dotted);
    }
    return out.items;
}

fn subTarget(m: *Move, importer: []const u8, entry: Import, item: Named, module_target: ?[]const u8) !?[]const u8 {
    const joined = try py.joinSpec(m.cx.arena, entry.spec, item.name);
    const sub = (try py.resolve(m.cx, m.before, importer, joined)) orelse return null;
    const package = module_target orelse return sub;
    if (!py.isPackageInit(package)) return null;
    if (m.snapshots.get(package)) |init_snapshot| {
        if (try py.initBindsOther(m.cx, package, init_snapshot, item.name, sub, m.before)) return null;
    }
    return sub;
}

fn addEdit(edits: *std.ArrayList(TextEdit), arena: Allocator, start: u32, end: u32, text: []const u8) !void {
    for (edits.items) |e| if (e.start == start and e.end == end) return;
    try edits.append(arena, .{ .start = start, .end = end, .text = text });
}

fn rewritePlain(m: *Move, snapshot: *Snapshot, entries: []const Import, entry: Import, new_dotted: []const u8, edits: *std.ArrayList(TextEdit)) !void {
    const arena = m.cx.arena;
    const span = py.specSpan(snapshot.source, entry.spec);
    try addEdit(edits, arena, span.start, span.end, new_dotted);
    const old_root = py.firstSegment(entry.spec);
    const new_root = py.firstSegment(new_dotted);
    const tail = if (entry.spec.len > old_root.len) entry.spec[old_root.len + 1 ..] else "";
    const resolution = try scope.resolveName(arena, snapshot, old_root);
    var other_use = false;
    for (resolution.uses) |use| {
        const index = use.binder orelse continue;
        if (!resolution.binders[index].import) continue;
        const leaf = rename.leafAt(snapshot.tree.root(), use.span) orelse return error.PyImportUnprovable;
        const chain = py.climb(leaf, snapshot.source, tail) orelse {
            other_use = true;
            continue;
        };
        try addEdit(edits, arena, chain.startByte(), chain.endByte(), new_dotted);
    }
    if (std.mem.eql(u8, old_root, new_root)) return;
    if (other_use) {
        var bound = false;
        for (entries) |other| {
            if (py.isFromStatement(snapshot.source, other) or other.namespace == null) continue;
            if (py.isAliased(snapshot.source, other) or std.mem.eql(u8, other.spec, entry.spec)) continue;
            if (std.mem.eql(u8, other.namespace.?, old_root)) bound = true;
        }
        if (!bound) return error.PyRootStillUsed;
    }
    const capture = try scope.resolveName(arena, snapshot, new_root);
    for (capture.uses) |use| if (use.binder == null) return error.PyNameCapture;
    for (capture.binders) |binder| {
        if (!binder.import) return error.PyNameCapture;
        for (try py.bindingsOf(m.cx, snapshot.source, entries)) |binding| {
            if (std.mem.eql(u8, binding.local, new_root) and !binding.plain) return error.PyNameCapture;
        }
    }
}

fn newSpec(m: *Move, abs: []const u8, spec: []const u8, target_after: ?[]const u8, directory: ?[]const u8) ![]const u8 {
    const importer = m.afterImporter(abs);
    if (spec[0] == '.') {
        const strict = py.dotCount(spec) <= try py.packageDepth(m.cx, m.before, abs);
        var logical = (try py.logicalOf(m.cx, abs, spec)) orelse return error.PyImportUnprovable;
        if (target_after) |t| {
            if (tsserver.sameFile(t, m.to)) logical = py.moduleLogical(t);
        }
        if (try py.relativeOf(m.cx, m.after, importer, logical, strict)) |text| return text;
        if (target_after) |t| if (try py.absoluteOf(m.cx, m.after, importer, t)) |text| return text;
        if (directory) |d| if (try py.absoluteOfDir(m.cx, m.after, importer, d)) |text| return text;
        return error.PyImportUnprovable;
    }
    if (target_after) |t| if (try py.absoluteOf(m.cx, m.after, importer, t)) |text| return text;
    if (directory) |d| if (try py.absoluteOfDir(m.cx, m.after, importer, d)) |text| return text;
    return error.PyImportUnprovable;
}

fn itemText(arena: Allocator, leaf: []const u8, local: []const u8) ![]const u8 {
    if (std.mem.eql(u8, leaf, local)) return leaf;
    return std.fmt.allocPrint(arena, "{s} as {s}", .{ leaf, local });
}

fn fromLine(arena: Allocator, spec: []const u8, items: []const Named) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "from {s} import ", .{spec});
    for (items, 0..) |item, i| {
        if (i != 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, item.name);
        if (item.alias) |alias| try out.print(arena, " as {s}", .{alias});
    }
    return out.items;
}

fn scanFrom(m: *Move, abs: []const u8, snapshot: *Snapshot, entry: Import, edits: *std.ArrayList(TextEdit)) !void {
    const arena = m.cx.arena;
    const importer = m.afterImporter(abs);
    const source = snapshot.source;
    if (try py.ambiguous(m.cx, m.before, abs, entry.spec)) {
        const hit = try py.resolve(m.cx, m.before, abs, entry.spec);
        if (hit != null and tsserver.sameFile(hit.?, m.from)) return error.PyAmbiguousModule;
    }
    const module_target = try py.resolve(m.cx, m.before, abs, entry.spec);
    var moved_items: std.ArrayList(Named) = .empty;
    var other_items: std.ArrayList(Named) = .empty;
    var directory: ?[]const u8 = null;
    var others_fine = true;
    for (entry.named) |item| {
        const sub = try subTarget(m, abs, entry, item, module_target);
        if (sub != null and tsserver.sameFile(sub.?, m.from)) {
            try moved_items.append(arena, item);
            continue;
        }
        try other_items.append(arena, item);
        if (sub) |found| {
            directory = std.fs.path.dirname(py.moduleLogical(found));
            const now = try py.resolve(m.cx, m.after, importer, try py.joinSpec(arena, entry.spec, item.name));
            if (!py.sameOptional(now, m.mapped(found))) others_fine = false;
        }
    }
    const module_mapped = m.mapped(module_target);
    const module_now = try py.resolve(m.cx, m.after, importer, entry.spec);
    const module_fine = py.sameOptional(module_now, module_mapped);
    var keep_spec = entry.spec;
    if (!module_fine or !others_fine) {
        if (module_target == null and directory == null) return error.PyNameCapture;
        keep_spec = try newSpec(m, abs, entry.spec, module_mapped, directory);
    }
    const span = py.specSpan(source, entry.spec);
    if (moved_items.items.len == 0) {
        if (!std.mem.eql(u8, keep_spec, entry.spec)) try addEdit(edits, arena, span.start, span.end, keep_spec);
        return;
    }
    const to_logical = py.moduleLogical(m.to);
    const leaf = std.fs.path.basename(to_logical);
    if (!py.isIdentifier(leaf)) return error.PyTargetNotImportable;
    var parent: []const u8 = "";
    const to_dir = std.fs.path.dirname(to_logical) orelse return error.PyImportUnprovable;
    if (entry.spec[0] == '.') {
        const strict = py.dotCount(entry.spec) <= try py.packageDepth(m.cx, m.before, abs);
        if (try py.relativeOf(m.cx, m.after, importer, to_dir, strict)) |text| parent = text;
    }
    if (parent.len == 0) {
        const dotted = (try py.absoluteOf(m.cx, m.after, importer, m.to)) orelse return error.PyTargetNotImportable;
        if (std.mem.lastIndexOfScalar(u8, dotted, '.')) |dot| parent = dotted[0..dot];
    }
    if (std.mem.eql(u8, parent, keep_spec)) {
        for (moved_items.items) |item| try addEdit(edits, arena, item.span.start, item.span.end, try itemText(arena, leaf, item.local()));
        return;
    }
    if (other_items.items.len == 0 and moved_items.items.len == 1 and parent.len != 0) {
        try addEdit(edits, arena, span.start, span.end, parent);
        const item = moved_items.items[0];
        try addEdit(edits, arena, item.span.start, item.span.end, try itemText(arena, leaf, item.local()));
        return;
    }
    const statement_text = source[entry.statement.start..entry.statement.end];
    if (std.mem.indexOfScalar(u8, statement_text, '#') != null) return error.PyImportUnprovable;
    const indent = py.lineIndent(source, entry.statement.start) orelse return error.PyImportUnprovable;
    if (!py.endsStatementLine(source, entry.statement.end)) return error.PyImportUnprovable;
    var out: std.ArrayList(u8) = .empty;
    const newline = py.newlineOf(source);
    if (other_items.items.len != 0) {
        try out.appendSlice(arena, try fromLine(arena, keep_spec, other_items.items));
    }
    for (moved_items.items) |item| {
        if (out.items.len != 0) try out.print(arena, "{s}{s}", .{ newline, indent });
        if (parent.len == 0) {
            try out.print(arena, "import {s}", .{try itemText(arena, leaf, item.local())});
        } else {
            try out.print(arena, "from {s} import {s}", .{ parent, try itemText(arena, leaf, item.local()) });
        }
    }
    try addEdit(edits, arena, entry.statement.start, entry.statement.end, out.items);
}

fn scanImport(m: *Move, abs: []const u8, snapshot: *Snapshot, entries: []const Import, entry: Import, edits: *std.ArrayList(TextEdit)) !void {
    const target = try py.resolve(m.cx, m.before, abs, entry.spec);
    if (target != null and tsserver.sameFile(target.?, m.from) and try py.ambiguous(m.cx, m.before, abs, entry.spec)) return error.PyAmbiguousModule;
    const importer = m.afterImporter(abs);
    const target_after = m.mapped(target);
    const now = try py.resolve(m.cx, m.after, importer, entry.spec);
    if (py.sameOptional(now, target_after)) return;
    const wanted = target_after orelse return error.PyNameCapture;
    const dotted = (try py.absoluteOf(m.cx, m.after, importer, wanted)) orelse return if (tsserver.sameFile(wanted, m.to)) error.PyTargetNotImportable else error.PyImportUnprovable;
    if (py.isAliased(snapshot.source, entry)) {
        const span = py.specSpan(snapshot.source, entry.spec);
        try addEdit(edits, m.cx.arena, span.start, span.end, dotted);
        return;
    }
    try rewritePlain(m, snapshot, entries, entry, dotted, edits);
}

fn refuseChains(m: *Move, abs: []const u8, snapshot: *Snapshot, entries: []const Import) !void {
    const arena = m.cx.arena;
    const bindings = try py.bindingsOf(m.cx, snapshot.source, entries);
    if (bindings.len == 0) return;
    const leaf_name = std.fs.path.basename(py.moduleLogical(m.from));
    var stack: std.ArrayList(ts.Node) = .empty;
    try stack.append(arena, snapshot.tree.root());
    while (stack.pop()) |node| {
        var i: u32 = 0;
        while (node.child(i)) |child| : (i += 1) try stack.append(arena, child);
        if (!std.mem.eql(u8, node.kind(), "attribute")) continue;
        const attribute = node.childByField("attribute") orelse continue;
        if (!std.mem.eql(u8, snapshot.tree.text(attribute), leaf_name)) continue;
        var root_node = node;
        while (std.mem.eql(u8, root_node.kind(), "attribute")) root_node = root_node.childByField("object") orelse break;
        if (!std.mem.eql(u8, root_node.kind(), "identifier")) continue;
        const root_name = snapshot.tree.text(root_node);
        const chain = try py.segmentsAfter(arena, snapshot.tree.text(node));
        const tail = if (chain.len > root_name.len) chain[root_name.len + 1 ..] else "";
        var covered = false;
        for (entries) |entry| {
            if (py.isFromStatement(snapshot.source, entry) or entry.namespace == null or py.isAliased(snapshot.source, entry)) continue;
            if (std.mem.eql(u8, entry.spec, chain)) covered = true;
        }
        if (covered) continue;
        const resolution = try scope.resolveName(arena, snapshot, root_name);
        const use = resolution.useAt(.{ .start = root_node.startByte(), .end = root_node.endByte() }) orelse continue;
        const binder_index = use.binder orelse continue;
        if (!resolution.binders[binder_index].import) continue;
        for (bindings) |binding| {
            if (!std.mem.eql(u8, binding.local, root_name)) continue;
            const composed = try py.joinSpec(arena, binding.dotted, tail);
            const target = try py.resolve(m.cx, m.before, abs, composed);
            if (target != null and tsserver.sameFile(target.?, m.from)) return error.PyChainThroughPackage;
        }
    }
}

fn targetsOf(m: *Move, importer: []const u8, snapshot: *const Snapshot, existing: Existing, before_state: bool, out: *std.ArrayList(?[]const u8)) !void {
    const arena = m.cx.arena;
    for (try modules.imports(arena, snapshot)) |entry| {
        const module_target = try py.resolve(m.cx, existing, importer, entry.spec);
        if (!py.isFromStatement(snapshot.source, entry) or entry.form == .bare) {
            try out.append(arena, if (before_state) m.mapped(module_target) else module_target);
            continue;
        }
        for (entry.named) |item| {
            var sub = try py.resolve(m.cx, existing, importer, try py.joinSpec(arena, entry.spec, item.name));
            if (sub) |found| {
                if (module_target) |package| {
                    if (!py.isPackageInit(package)) {
                        sub = null;
                    } else if (before_state) {
                        if (m.snapshots.get(package)) |init_snapshot| {
                            if (try py.initBindsOther(m.cx, package, init_snapshot, item.name, found, existing)) sub = null;
                        }
                    }
                }
            }
            const hit = sub orelse module_target;
            try out.append(arena, if (before_state) m.mapped(hit) else hit);
        }
    }
}

fn lessTarget(_: void, a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null) return b != null;
    if (b == null) return false;
    return std.ascii.lessThanIgnoreCase(a.?, b.?);
}

fn proveTargets(m: *Move, abs: []const u8, before: *const Snapshot, after: *const Snapshot) !void {
    var was: std.ArrayList(?[]const u8) = .empty;
    var now: std.ArrayList(?[]const u8) = .empty;
    try targetsOf(m, abs, before, m.before, true, &was);
    try targetsOf(m, m.afterImporter(abs), after, m.after, false, &now);
    if (was.items.len != now.items.len) return error.IncompleteMove;
    std.mem.sort(?[]const u8, was.items, {}, lessTarget);
    std.mem.sort(?[]const u8, now.items, {}, lessTarget);
    for (was.items, now.items) |a, b| {
        if (!py.sameOptional(a, b)) return error.IncompleteMove;
    }
}

pub fn prove(cx: Cx, from: []const u8, to: []const u8, opened: *std.ArrayList(*Snapshot), all: []const Pair, changes: []const Change, afters: []const *Snapshot) !void {
    const virtual = try cx.arena.dupe([]const u8, &.{to});
    const removed = try cx.arena.dupe([]const u8, &.{from});
    var m: Move = .{ .cx = cx, .from = from, .to = to, .before = .{ .io = cx.io }, .after = .{ .io = cx.io, .virtual = virtual, .removed = removed }, .opened = opened };
    for (all) |pair| try m.snapshots.put(cx.arena, pair.abs, pair.snapshot);
    for (all) |pair| {
        var after: *const Snapshot = pair.snapshot;
        for (changes, afters) |change, snapshot| {
            if (tsserver.sameFile(change.abs, pair.abs)) after = snapshot;
        }
        try proveTargets(&m, pair.abs, pair.snapshot, after);
    }
}

pub const Pair = struct { abs: []const u8, snapshot: *Snapshot };

pub const Planned = struct {
    result: Result,
    all: []Pair,
};

pub fn plan(cx: Cx, from: []const u8, to: []const u8, moved: *Snapshot, opened: *std.ArrayList(*Snapshot)) !Planned {
    const arena = cx.arena;
    if (!paths.isPythonPath(to)) return error.UnsupportedLanguage;
    if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(from), std.fs.path.extension(to))) return error.UnsupportedLanguage;
    const virtual = try arena.dupe([]const u8, &.{to});
    const removed = try arena.dupe([]const u8, &.{from});
    var m: Move = .{ .cx = cx, .from = from, .to = to, .before = .{ .io = cx.io }, .after = .{ .io = cx.io, .virtual = virtual, .removed = removed }, .opened = opened };

    const companion_ext: []const u8 = if (std.ascii.eqlIgnoreCase(std.fs.path.extension(from), ".py")) ".pyi" else ".py";
    const bare = from[0 .. from.len - std.fs.path.extension(from).len];
    if (m.before.has(try std.fmt.allocPrint(arena, "{s}{s}", .{ bare, companion_ext }))) return error.PyStubCompanion;

    const tracked = try py.trackedPython(cx);
    if (py.isPackageInit(from)) {
        const dir = std.fs.path.dirname(from).?;
        for (tracked) |abs| {
            if (tsserver.sameFile(abs, from)) continue;
            if (abs.len > dir.len and std.ascii.eqlIgnoreCase(abs[0..dir.len], dir) and abs[dir.len] == '\\') return error.PyInitWithSiblings;
        }
    }

    const dotted = try oldDottedNames(cx, m.before, from, from);
    const interface_change = try publicMention(cx, dotted, from);

    const stem = std.fs.path.basename(py.moduleLogical(from));
    var snapshots: std.ArrayList(Pair) = .empty;
    try snapshots.append(arena, .{ .abs = from, .snapshot = moved });
    try m.snapshots.put(arena, from, moved);
    for (tracked) |abs| {
        if (tsserver.sameFile(abs, from)) continue;
        const snapshot = py.load(cx, abs, null) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        try opened.append(arena, snapshot);
        if (snapshot.tree.root().hasError()) {
            if (std.mem.indexOf(u8, snapshot.source, stem) != null) return error.SourceHasErrors;
            continue;
        }
        try snapshots.append(arena, .{ .abs = abs, .snapshot = snapshot });
        try m.snapshots.put(arena, abs, snapshot);
    }

    const exact_init: ?[]const u8 = if (py.isPackageInit(from)) null else stem;
    const package_dir = std.fs.path.dirname(from).?;
    var changes: std.ArrayList(Change) = .empty;
    var users: usize = 0;
    var rewritten: usize = 0;
    for (snapshots.items, 0..) |pair, index| {
        const snapshot = pair.snapshot;
        const entries = try modules.imports(arena, snapshot);
        var edits: std.ArrayList(TextEdit) = .empty;
        const same_package_init = py.isPackageInit(pair.abs) and std.ascii.eqlIgnoreCase(std.fs.path.dirname(pair.abs).?, package_dir);
        if (try py.stringNaming(snapshot, arena, dotted, if (same_package_init) exact_init else null)) return error.DynamicPathUse;
        for (try modules.dynamicSpecs(arena, snapshot)) |d| {
            const literal = d.literal orelse {
                if (std.mem.indexOf(u8, snapshot.source, stem) != null) return error.DynamicPathUse;
                continue;
            };
            const hit = try py.resolve(cx, m.before, pair.abs, literal);
            if (hit != null and tsserver.sameFile(hit.?, from)) return error.DynamicPathUse;
        }
        if (index != 0) try refuseChains(&m, pair.abs, snapshot, entries);
        for (entries) |entry| {
            if (py.isFromStatement(snapshot.source, entry)) {
                try scanFrom(&m, pair.abs, snapshot, entry, &edits);
            } else {
                try scanImport(&m, pair.abs, snapshot, entries, entry, &edits);
            }
        }
        if (index != 0 and edits.items.len == 0) continue;
        if (index != 0) users += 1;
        rewritten += edits.items.len;
        try changes.append(arena, .{ .abs = pair.abs, .snapshot = snapshot, .edits = edits });
    }

    var note: ?[]const u8 = null;
    const to_dir = std.fs.path.dirname(to).?;
    if (try py.hasInit(m.before, arena, package_dir) and !try py.hasInit(m.after, arena, to_dir)) {
        note = "the target directory has no __init__.py; it is imported as a namespace package";
    }
    return .{
        .result = .{ .changes = changes.items, .users = users, .rewritten = rewritten, .note = note, .interface_change = interface_change },
        .all = snapshots.items,
    };
}
