const std = @import("std");
const builtin = @import("builtin");
const ts = @import("../engine/tree_sitter.zig");
const symbol = @import("../engine/symbol.zig");
const rename = @import("../engine/rename.zig");
const scope = @import("../engine/scope.zig");
const modules = @import("../engine/modules.zig");
const symmetry = @import("../engine/symmetry.zig");
const registry = @import("../engine/lang/registry.zig");
const repo = @import("repo.zig");
const shadow = @import("shadow.zig");
const tsserver = @import("tsserver.zig");
const batch = @import("batch.zig");
const batch_plan = @import("batch_plan.zig");
const sandbox = @import("sandbox.zig");
const disk = @import("disk.zig");
const runner = @import("runner.zig");
const paths = @import("module_paths.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;
const Snapshot = @import("../engine/loader.zig").Snapshot;

const Allocator = std.mem.Allocator;
const Span = symbol.Span;
const Prepared = batch_plan.Prepared;
const Edit = batch_plan.Edit;
const Import = modules.Import;
const Named = modules.Named;

pub const Request = struct {
    file_abs: []const u8,
    ref_text: []const u8,
    expected_hash: symbol.Hash,
    target_abs: []const u8,
    interface_change: bool = false,
    order_change: bool = false,
};

pub const Resolver = enum { language_service, text };

pub const Fault = enum { alter_moved_text, drop_user_import, alter_other_symbol };
pub var injected_fault: ?Fault = null;

fn faulted(fault: Fault) bool {
    return builtin.is_test and injected_fault == fault;
}

pub const Options = struct {
    request: Request,
    test_command: []const u8,
    typecheck_command: ?[]const u8 = null,
    linked: []const []const u8 = &.{"node_modules"},
    limits: sandbox.Limits = .{},
    allow_repo_memory: bool = false,
    shadow_root: ?[]const u8 = null,
    trace: ?*runner.Trace = null,
    commit_step: ?*const disk.Step = null,
    language_service: ?*tsserver.Session = null,
};

pub const Plan = struct {
    prepared: []Prepared,
    edits: []Edit,
    resolver: Resolver,
    fallback: ?anyerror,
    interface_change: bool,
    order_change: bool,
    creates_target: bool,
    users: usize,
    imports_added: usize,
    moved_hash: symbol.Hash,

    pub fn deinit(self: Plan, gpa: Allocator) void {
        for (self.prepared) |p| p.deinit(gpa);
        for (self.edits) |e| {
            gpa.free(e.file_abs);
            gpa.free(e.ref_text);
        }
        gpa.free(self.prepared);
        gpa.free(self.edits);
    }
};

const TextEdit = struct {
    start: u32,
    end: u32,
    text: []const u8,
};

fn lessEdit(_: void, a: TextEdit, b: TextEdit) bool {
    return a.start < b.start;
}

fn applyEdits(arena: Allocator, source: []const u8, edits: []TextEdit) ![]u8 {
    std.mem.sort(TextEdit, edits, {}, lessEdit);
    var out: std.ArrayList(u8) = .empty;
    var cursor: u32 = 0;
    for (edits) |e| {
        if (e.start < cursor) return error.OverlappingEdit;
        try out.appendSlice(arena, source[cursor..e.start]);
        try out.appendSlice(arena, e.text);
        cursor = e.end;
    }
    try out.appendSlice(arena, source[cursor..]);
    return out.items;
}

fn lineEndAfter(source: []const u8, end: u32) u32 {
    var at: usize = end;
    while (at < source.len and (source[at] == ' ' or source[at] == '\t')) at += 1;
    if (at < source.len and source[at] == '\r') at += 1;
    if (at < source.len and source[at] == '\n') at += 1;
    return @intCast(at);
}

fn quoteOf(source: []const u8, spec: []const u8) u8 {
    const at = @intFromPtr(spec.ptr) - @intFromPtr(source.ptr);
    if (at == 0) return '"';
    return source[at - 1];
}

const ImportShape = struct {
    type_only: bool = false,
    default_name: ?[]const u8 = null,
    namespace: ?[]const u8 = null,
    named: []const Named = &.{},
    spec: []const u8,
    quote: u8 = '"',
};

fn importText(arena: Allocator, shape: ImportShape, keep_bare: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const has_bindings = shape.default_name != null or shape.namespace != null or shape.named.len != 0;
    if (!has_bindings) {
        if (!keep_bare) return "";
        try out.print(arena, "import {c}{s}{c};\n", .{ shape.quote, shape.spec, shape.quote });
        return out.items;
    }
    try out.appendSlice(arena, if (shape.type_only) "import type " else "import ");
    var parts: usize = 0;
    if (shape.default_name) |d| {
        try out.appendSlice(arena, d);
        parts += 1;
    }
    if (shape.namespace) |n| {
        if (parts != 0) try out.appendSlice(arena, ", ");
        try out.print(arena, "* as {s}", .{n});
        parts += 1;
    }
    if (shape.named.len != 0) {
        if (parts != 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, "{ ");
        for (shape.named, 0..) |item, i| {
            if (i != 0) try out.appendSlice(arena, ", ");
            if (item.type_only) try out.appendSlice(arena, "type ");
            try out.appendSlice(arena, item.name);
            if (item.alias) |alias| try out.print(arena, " as {s}", .{alias});
        }
        try out.appendSlice(arena, " }");
    }
    try out.print(arena, " from {c}{s}{c};\n", .{ shape.quote, shape.spec, shape.quote });
    return out.items;
}

fn shapeOf(source: []const u8, entry: Import) ImportShape {
    return .{ .type_only = entry.type_only, .default_name = entry.default_name, .namespace = entry.namespace, .named = entry.named, .spec = entry.spec, .quote = quoteOf(source, entry.spec) };
}

fn importInsertPoint(source: []const u8, found: []const Import) u32 {
    var point: u32 = 0;
    for (found) |entry| {
        if (entry.form != .import and entry.form != .bare) continue;
        point = @max(point, lineEndAfter(source, entry.statement.end));
    }
    return point;
}

fn without(arena: Allocator, named: []const Named, drop: []const u8) ![]const Named {
    var out: std.ArrayList(Named) = .empty;
    for (named) |item| {
        if (std.mem.eql(u8, item.name, drop)) continue;
        try out.append(arena, item);
    }
    return out.items;
}

fn withoutLocals(arena: Allocator, named: []const Named, drop: []const []const u8) ![]const Named {
    var out: std.ArrayList(Named) = .empty;
    outer: for (named) |item| {
        for (drop) |d| if (std.mem.eql(u8, item.local(), d)) continue :outer;
        try out.append(arena, item);
    }
    return out.items;
}

const Moved = struct {
    name: []const u8,
    offset: u32,
    cut: Span,
    statement: ts.Node,
    exported: bool,
    function: bool,
};

fn locateMoved(gpa: Allocator, base: *Snapshot, ref: symbol.Ref, expected: symbol.Hash) !Moved {
    if (ref.container.len != 0) return error.NotTopLevel;
    const table = try base.symbols();
    var offset: u32 = undefined;
    var function = false;
    if (table.resolve(ref)) |found| {
        if (!std.mem.eql(u8, &found.hash, &expected)) return error.HashMismatch;
        offset = (try batch_plan.nameOffset(gpa, base, ref.name, found.declaration)) orelse return error.SymbolNotFound;
        function = true;
    } else |err| switch (err) {
        error.SymbolNotFound => {
            const found = table.declarationMatching(ref, expected) orelse return if (table.hasDeclaration(ref)) error.HashMismatch else error.SymbolNotFound;
            offset = found.name.startByte();
        },
        else => |e| return e,
    }
    const root = base.tree.root();
    var i: u32 = 0;
    const statement = while (root.child(i)) |child| : (i += 1) {
        if (child.startByte() <= offset and offset < child.endByte()) break child;
    } else return error.NotTopLevel;
    if (modules.exportsDefault(base, statement)) return error.ExportDefault;
    var inside: usize = 0;
    for (table.symbols) |s| {
        if (s.ref.container.len == 0 and s.declaration.start >= statement.startByte() and s.declaration.start < statement.endByte()) inside += 1;
    }
    for (table.declarations) |d| {
        if (d.ref.container.len == 0 and d.name.startByte() >= statement.startByte() and d.name.startByte() < statement.endByte()) inside += 1;
    }
    if (inside != 1) return error.SharedStatement;
    const m = base.profile.modules.?;
    var start = statement.startByte();
    var prev = statement.prevSibling();
    while (prev) |sibling| : (prev = sibling.prevSibling()) {
        if (!base.profile.isComment(sibling.kind())) break;
        const gap = base.source[sibling.endByte()..start];
        if (std.mem.count(u8, gap, "\n") > 1 or std.mem.trim(u8, gap, " \t\r\n").len != 0) break;
        start = sibling.startByte();
    }
    return .{
        .name = ref.name,
        .offset = offset,
        .cut = .{ .start = start, .end = lineEndAfter(base.source, statement.endByte()) },
        .statement = statement,
        .exported = std.mem.eql(u8, statement.kind(), m.export_statement),
        .function = function,
    };
}

fn topBinders(resolution: scope.Resolution, root: ts.Node) usize {
    var count: usize = 0;
    for (resolution.binders) |b| {
        if (b.scope.start == root.startByte() and b.scope.end == root.endByte()) count += 1;
    }
    return count;
}

const User = struct {
    abs: []const u8,
    snapshot: *Snapshot,
    entry: Import,
    item: Named,
};

const Work = struct {
    gpa: Allocator,
    arena: Allocator,
    io: std.Io,
    runtime: *Runtime,
    root: []const u8,
    existing: paths.Existing,
};

fn loadSnapshot(w: Work, abs: []const u8) !*Snapshot {
    const snapshot = try Snapshot.load(w.runtime, w.io, .cwd(), abs);
    errdefer snapshot.destroy();
    if (snapshot.tree.root().hasError()) return error.SourceHasErrors;
    return snapshot;
}

fn resolvesTo(w: Work, importer: []const u8, spec: []const u8, file: []const u8) !bool {
    const resolved = (try paths.resolveSpec(w.arena, w.existing, importer, spec)) orelse return false;
    return tsserver.sameFile(resolved, file);
}

fn findUsers(w: Work, source_abs: []const u8, target_abs: []const u8, name: []const u8, exported: bool, users: *std.ArrayList(User), opened: *std.ArrayList(*Snapshot)) !void {
    const listing = try repo.filesMentioning(w.arena, w.io, w.root, name);
    var files = std.mem.tokenizeScalar(u8, listing, 0);
    while (files.next()) |rel| {
        const profile = registry.forPath(rel) orelse continue;
        if (profile.modules == null) continue;
        const abs = try std.fmt.allocPrint(w.arena, "{s}\\{s}", .{ w.root, rel });
        std.mem.replaceScalar(u8, abs, '/', '\\');
        if (tsserver.sameFile(abs, source_abs) or tsserver.sameFile(abs, target_abs)) continue;
        const snapshot = try loadSnapshot(w, abs);
        try opened.append(w.arena, snapshot);
        if (rename.dynamicAccess(snapshot, name, false) != null) return error.DynamicReference;
        for (try modules.imports(w.arena, snapshot)) |entry| {
            if (!try resolvesTo(w, abs, entry.spec, source_abs)) continue;
            switch (entry.form) {
                .bare => {},
                .star_reexport => if (exported) return error.ReExported,
                .reexport => for (entry.named) |item| {
                    if (std.mem.eql(u8, item.name, name)) return error.ReExported;
                },
                .import => {
                    if (entry.namespace != null) return error.NamespaceImportUse;
                    for (entry.named) |item| {
                        if (!std.mem.eql(u8, item.name, name)) continue;
                        try users.append(w.arena, .{ .abs = abs, .snapshot = snapshot, .entry = entry, .item = item });
                    }
                },
            }
        }
    }
}

const ServiceCheck = union(enum) { ok, unavailable: anyerror };

fn crossCheck(w: Work, session: *tsserver.Session, source_abs: []const u8, target_abs: []const u8, offset: u32, users: []const User) !ServiceCheck {
    const client = session.get() catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{ .unavailable = err },
    };
    const file = try w.arena.dupe(u8, source_abs);
    std.mem.replaceScalar(u8, file, '\\', '/');
    const answer = client.references(file, offset) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{ .unavailable = err },
    };
    defer answer.deinit();
    for (answer.value.references) |reference| {
        if (tsserver.sameFile(reference.file, source_abs) or tsserver.sameFile(reference.file, target_abs)) continue;
        var known = false;
        for (users) |u| {
            if (tsserver.sameFile(reference.file, u.abs)) known = true;
        }
        if (!known) return error.UnhandledReference;
    }
    for (users) |u| {
        var seen = false;
        for (answer.value.references) |reference| {
            if (tsserver.sameFile(reference.file, u.abs)) seen = true;
        }
        if (!seen) return error.ResolutionMismatch;
    }
    return .ok;
}

const Needed = struct {
    shape: ImportShape,
    resolved: ?[]const u8,
};

fn addNeeded(arena: Allocator, needed: *std.ArrayList(Needed), spec: []const u8, resolved: ?[]const u8, type_only: bool, kind: enum { named, default, namespace }, name: []const u8, alias: ?[]const u8) !void {
    for (needed.items) |*n| {
        if (!std.mem.eql(u8, n.shape.spec, spec) or n.shape.type_only != type_only or kind != .named or n.shape.named.len == 0) continue;
        var list: std.ArrayList(Named) = .empty;
        try list.appendSlice(arena, n.shape.named);
        for (list.items) |item| if (std.mem.eql(u8, item.name, name)) return;
        try list.append(arena, .{ .name = name, .alias = alias, .span = .{ .start = 0, .end = 0 }, .type_only = false });
        n.shape.named = list.items;
        return;
    }
    var shape: ImportShape = .{ .spec = spec, .type_only = type_only };
    switch (kind) {
        .named => shape.named = try arena.dupe(Named, &.{.{ .name = name, .alias = alias, .span = .{ .start = 0, .end = 0 }, .type_only = false }}),
        .default => shape.default_name = name,
        .namespace => shape.namespace = name,
    }
    try needed.append(arena, .{ .shape = shape, .resolved = resolved });
}

fn importOwning(found: []const Import, binder: Span) ?struct { entry: Import, kind: enum { named, default, namespace }, name: []const u8, alias: ?[]const u8 } {
    for (found) |entry| {
        if (entry.form != .import) continue;
        if (binder.start < entry.statement.start or binder.end > entry.statement.end) continue;
        for (entry.named) |item| {
            if (binder.start >= item.span.start and binder.end <= item.span.end) return .{ .entry = entry, .kind = .named, .name = item.name, .alias = item.alias };
        }
        if (entry.namespace) |n| return .{ .entry = entry, .kind = .namespace, .name = n, .alias = null };
        if (entry.default_name) |d| return .{ .entry = entry, .kind = .default, .name = d, .alias = null };
    }
    return null;
}

fn targetBinds(w: Work, target: ?*Snapshot, name: []const u8) !bool {
    const t = target orelse return false;
    const resolution = try scope.resolveName(w.arena, t, name);
    return resolution.binders.len != 0;
}

pub fn plan(gpa: Allocator, io: std.Io, runtime: *Runtime, root: []const u8, request: Request, session: ?*tsserver.Session) !Plan {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (tsserver.sameFile(request.file_abs, request.target_abs)) return error.SameFile;
    const target_profile = registry.forPath(request.target_abs) orelse return error.UnsupportedLanguage;
    if (target_profile.modules == null) return error.UnsupportedLanguage;
    const target_exists = blk: {
        std.Io.Dir.cwd().access(io, request.target_abs, .{}) catch break :blk false;
        break :blk true;
    };
    var w: Work = .{ .gpa = gpa, .arena = arena, .io = io, .runtime = runtime, .root = root, .existing = .{ .io = io } };
    if (!target_exists) w.existing.virtual = try arena.dupe([]const u8, &.{request.target_abs});

    var opened: std.ArrayList(*Snapshot) = .empty;
    defer for (opened.items) |s| s.destroy();

    const source = try loadSnapshot(w, request.file_abs);
    try opened.append(arena, source);
    if (source.profile.modules == null or source.profile.rename == null) return error.UnsupportedLanguage;
    const target: ?*Snapshot = if (target_exists) try loadSnapshot(w, request.target_abs) else null;
    if (target) |t| try opened.append(arena, t);

    const ref = try symbol.Ref.parse(arena, request.ref_text);
    const moved = try locateMoved(arena, source, ref, request.expected_hash);
    const name = moved.name;
    const source_resolution = try scope.resolveName(arena, source, name);
    if (topBinders(source_resolution, source.tree.root()) != 1) return error.MergedDeclaration;
    if (rename.dynamicAccess(source, name, false) != null) return error.DynamicReference;
    for (source_resolution.externals) |_| return error.LocalExportClause;
    const source_imports = try modules.imports(arena, source);
    for (source_imports) |entry| {
        if (entry.form != .reexport) continue;
        for (entry.named) |item| if (std.mem.eql(u8, item.local(), name)) return error.LocalExportClause;
    }

    var users: std.ArrayList(User) = .empty;
    try findUsers(w, request.file_abs, request.target_abs, name, moved.exported, &users, &opened);

    var resolver: Resolver = .text;
    var fallback: ?anyerror = error.NoLanguageService;
    if (session) |s| {
        switch (try crossCheck(w, s, request.file_abs, request.target_abs, moved.offset, users.items)) {
            .ok => {
                resolver = .language_service;
                fallback = null;
            },
            .unavailable => |err| {
                s.last_error = err;
                fallback = err;
            },
        }
    }
    if (resolver == .text) {
        if (moved.exported) return error.MoveUnresolved;
        const listing = try repo.filesMentioning(arena, io, root, name);
        var files = std.mem.tokenizeScalar(u8, listing, 0);
        while (files.next()) |rel| {
            const abs = try std.fmt.allocPrint(arena, "{s}\\{s}", .{ root, rel });
            if (!tsserver.sameFile(abs, request.file_abs)) return error.MoveUnresolved;
        }
    }

    const interface_change = moved.exported or users.items.len != 0;
    if (interface_change and !request.interface_change) return error.InterfaceChangeNeedsApproval;

    var needs_order = false;
    if (modules.hasModuleEffects(source) or symmetry.statementHasEffect(source.profile, moved.statement)) needs_order = true;
    if (target) |t| {
        if (modules.hasModuleEffects(t)) needs_order = true;
    }
    if (needs_order and !request.order_change) return error.ModuleSideEffect;
    const declared = try paths.declaredSideEffects(arena, io, root, request.file_abs) or try paths.declaredSideEffects(arena, io, root, request.target_abs);
    if (declared and !request.order_change) return error.DeclaredSideEffect;

    var target_imports: []const Import = &.{};
    var target_self_import: ?Import = null;
    if (target) |t| {
        target_imports = try modules.imports(arena, t);
        for (target_imports) |entry| {
            if (entry.form != .import or !try resolvesTo(w, request.target_abs, entry.spec, request.file_abs)) continue;
            for (entry.named) |item| {
                if (!std.mem.eql(u8, item.name, name)) continue;
                if (item.alias != null) return error.TargetAliasUse;
                target_self_import = entry;
            }
        }
        const t_resolution = try scope.resolveName(arena, t, name);
        const allowed: usize = if (target_self_import != null) 1 else 0;
        if (t_resolution.binders.len != allowed or t_resolution.externals.len != 0) return error.TargetNameTaken;
    }

    var needed: std.ArrayList(Needed) = .empty;
    var from_target: std.ArrayList([]const u8) = .empty;
    var source_dropped: std.ArrayList([]const u8) = .empty;
    const free = try modules.freeNames(arena, source, moved.cut);
    for (free) |f| {
        const binder = f.binder orelse {
            if (try targetBinds(w, target, f.name)) return error.TargetCapture;
            continue;
        };
        if (f.import) {
            const owner = importOwning(source_imports, binder) orelse return error.UnsupportedImport;
            var spec = owner.entry.spec;
            var resolved: ?[]const u8 = null;
            if (paths.isRelative(spec)) {
                const file = (try paths.resolveSpec(arena, w.existing, request.file_abs, spec)) orelse return error.UnresolvedImport;
                if (tsserver.sameFile(file, request.target_abs)) {
                    try from_target.append(arena, f.name);
                    continue;
                }
                spec = try paths.relativeSpec(arena, request.target_abs, file, paths.emittedExtension(paths.specExtension(owner.entry.spec), file));
                if (!try resolvesTo(w, request.target_abs, spec, file)) return error.UnresolvedImport;
                resolved = file;
            }
            if (try targetBinds(w, target, f.name)) {
                if (!try targetImportsSame(w, target_imports, request.target_abs, f.name, owner.name, resolved, spec)) return error.TargetCapture;
                continue;
            }
            try addNeeded(arena, &needed, spec, resolved, owner.entry.type_only, switch (owner.kind) {
                .named => .named,
                .default => .default,
                .namespace => .namespace,
            }, owner.name, owner.alias);
            const uses_left = try usesOutside(arena, source, f.name, moved.cut, binder);
            if (!uses_left) try source_dropped.append(arena, f.name);
            continue;
        }
        if (!try rename.exportedName(arena, source, f.name)) return error.SourceDependencyNotExported;
        if (try targetBinds(w, target, f.name)) return error.TargetCapture;
        const spec = try paths.relativeSpec(arena, request.target_abs, request.file_abs, paths.emittedExtension(styleOf(source_imports), request.file_abs));
        if (!try resolvesTo(w, request.target_abs, spec, request.file_abs)) return error.UnresolvedImport;
        try addNeeded(arena, &needed, spec, request.file_abs, f.namespace == .type and typeOnlyBinder(source, binder), .named, f.name, null);
    }

    const source_still_uses = try usesOutside(arena, source, name, moved.cut, null);
    if (source_still_uses and !moved.exported) return error.MoveNeedsExport;

    var imports_added: usize = needed.items.len;
    var source_edits: std.ArrayList(TextEdit) = .empty;
    try source_edits.append(arena, .{ .start = moved.cut.start, .end = moved.cut.end, .text = "" });
    for (source_imports) |entry| {
        if (entry.form != .import) continue;
        var drop_default = false;
        var drop_namespace = false;
        for (source_dropped.items) |d| {
            if (entry.default_name) |dn| if (std.mem.eql(u8, dn, d)) {
                drop_default = true;
            };
            if (entry.namespace) |ns| if (std.mem.eql(u8, ns, d)) {
                drop_namespace = true;
            };
        }
        const kept = try withoutLocals(arena, entry.named, source_dropped.items);
        if (kept.len == entry.named.len and !drop_default and !drop_namespace) continue;
        var shape = shapeOf(source.source, entry);
        shape.named = kept;
        if (drop_default) shape.default_name = null;
        if (drop_namespace) shape.namespace = null;
        try source_edits.append(arena, .{ .start = entry.statement.start, .end = lineEndAfter(source.source, entry.statement.end), .text = try importText(arena, shape, true) });
    }
    const source_ext = styleOf(source_imports);
    if (source_still_uses) {
        const spec = try paths.relativeSpec(arena, request.file_abs, request.target_abs, paths.emittedExtension(source_ext, request.target_abs));
        if (!try resolvesTo(w, request.file_abs, spec, request.target_abs)) return error.UnresolvedImport;
        const shape: ImportShape = .{ .spec = spec, .named = try arena.dupe(Named, &.{.{ .name = name, .alias = null, .span = .{ .start = 0, .end = 0 }, .type_only = false }}) };
        const at = importInsertPoint(source.source, source_imports);
        try source_edits.append(arena, .{ .start = at, .end = at, .text = try importText(arena, shape, false) });
        imports_added += 1;
    }
    if (faulted(.alter_other_symbol)) {
        const at: u32 = @intCast(std.mem.lastIndexOfScalar(u8, source.source, '}').?);
        if (at >= moved.cut.end or at < moved.cut.start) try source_edits.append(arena, .{ .start = at, .end = at, .text = ";" });
    }
    const source_new = try applyEdits(arena, source.source, source_edits.items);

    var target_edits: std.ArrayList(TextEdit) = .empty;
    const target_text: []const u8 = if (target) |t| t.source else "";
    if (target_self_import) |entry| {
        var shape = shapeOf(target_text, entry);
        shape.named = try without(arena, entry.named, name);
        try target_edits.append(arena, .{ .start = entry.statement.start, .end = lineEndAfter(target_text, entry.statement.end), .text = try importText(arena, shape, false) });
    }
    const target_at = importInsertPoint(target_text, target_imports);
    for (needed.items) |n| try target_edits.append(arena, .{ .start = target_at, .end = target_at, .text = try importText(arena, n.shape, false) });
    const moved_text = if (faulted(.alter_moved_text)) try std.mem.replaceOwned(u8, arena, source.source[moved.cut.start..moved.cut.end], "{", "{ ;") else source.source[moved.cut.start..moved.cut.end];
    const tail_end: u32 = @intCast(target_text.len);
    const separator: []const u8 = if (target_text.len == 0) "" else if (std.mem.endsWith(u8, target_text, "\n")) "\n" else "\n\n";
    const newline: []const u8 = if (std.mem.endsWith(u8, moved_text, "\n")) "" else "\n";
    try target_edits.append(arena, .{ .start = tail_end, .end = tail_end, .text = try std.mem.concat(arena, u8, &.{ separator, moved_text, newline }) });
    const target_new = try applyEdits(arena, target_text, target_edits.items);

    var outputs: std.ArrayList(Output) = .empty;
    try outputs.append(arena, .{ .abs = request.file_abs, .before = source, .text = source_new });
    const moved_start: u32 = @intCast(std.mem.lastIndexOf(u8, target_new, moved_text).?);
    const moved_span: Span = .{ .start = moved_start, .end = moved_start + @as(u32, @intCast(moved_text.len)) };
    try outputs.append(arena, .{ .abs = request.target_abs, .before = target, .text = target_new, .creates = !target_exists, .ref_text = request.ref_text, .body = moved_span });
    var index: usize = 0;
    while (index < users.items.len) : (index += 1) {
        const user = users.items[index];
        var duplicate = false;
        for (outputs.items) |o| {
            if (tsserver.sameFile(o.abs, user.abs)) duplicate = true;
        }
        if (duplicate) continue;
        var edits_u: std.ArrayList(TextEdit) = .empty;
        for (users.items) |other| {
            if (!tsserver.sameFile(other.abs, user.abs)) continue;
            var shape = shapeOf(user.snapshot.source, other.entry);
            shape.named = try without(arena, other.entry.named, name);
            const replaced = try importText(arena, shape, false);
            const spec = try paths.relativeSpec(arena, user.abs, request.target_abs, paths.emittedExtension(paths.specExtension(other.entry.spec), request.target_abs));
            if (!try resolvesTo(w, user.abs, spec, request.target_abs)) return error.UnresolvedImport;
            const added: ImportShape = .{ .spec = spec, .quote = shape.quote, .type_only = other.entry.type_only, .named = try arena.dupe(Named, &.{.{ .name = name, .alias = other.item.alias, .span = .{ .start = 0, .end = 0 }, .type_only = other.item.type_only }}) };
            const added_text = if (faulted(.drop_user_import)) "" else try importText(arena, added, false);
            try edits_u.append(arena, .{ .start = other.entry.statement.start, .end = lineEndAfter(user.snapshot.source, other.entry.statement.end), .text = try std.mem.concat(arena, u8, &.{ replaced, added_text }) });
            imports_added += 1;
        }
        try outputs.append(arena, .{ .abs = user.abs, .before = user.snapshot, .text = try applyEdits(arena, user.snapshot.source, edits_u.items) });
    }

    var afters: std.ArrayList(*Snapshot) = .empty;
    defer for (afters.items) |s| s.destroy();
    for (outputs.items) |o| {
        const profile = registry.forPath(o.abs).?;
        const after = try Snapshot.fromSource(runtime, profile, try runtime.gpa.dupe(u8, o.text));
        try afters.append(arena, after);
        if (after.tree.root().hasError()) return error.MutationSyntaxInvalid;
    }
    const moved_hash = try proveMoved(afters.items[1], ref, request.expected_hash, moved.function);
    try proveUnchanged(source, afters.items[0], moved.cut, false);
    if (target) |t| try proveUnchanged(t, afters.items[1], .{ .start = 0, .end = 0 }, true);
    for (outputs.items[2..], afters.items[2..]) |o, after| try proveUnchanged(o.before.?, after, .{ .start = 0, .end = 0 }, false);
    for (afters.items) |after| {
        const resolution = try scope.resolveName(arena, after, name);
        for (resolution.uses) |use| if (use.binder == null) return error.IncompleteMove;
    }
    for (try modules.freeNames(arena, afters.items[1], moved_span)) |f| {
        const before_global = for (free) |g| {
            if (std.mem.eql(u8, g.name, f.name) and g.namespace == f.namespace) break g.binder == null;
        } else false;
        if (f.binder == null and !before_global) return error.IncompleteMove;
        var own = false;
        for (from_target.items) |t| {
            if (std.mem.eql(u8, t, f.name)) own = true;
        }
        if (f.binder != null and !f.import and !own) return error.TargetCapture;
    }

    var overrides: std.ArrayList(paths.Override) = .empty;
    for (outputs.items) |o| try overrides.append(arena, .{ .abs = o.abs, .source = o.text });
    const cycle = try paths.reaches(arena, runtime, w.existing, request.target_abs, request.target_abs, overrides.items) or
        (try paths.reaches(arena, runtime, w.existing, request.file_abs, request.file_abs, overrides.items) and
            !try paths.reaches(arena, runtime, w.existing, request.file_abs, request.file_abs, &.{}));
    if (cycle) return error.ImportCycle;

    const result = try build(gpa, root, outputs.items, afters.items, .{
        .resolver = resolver,
        .fallback = fallback,
        .interface_change = interface_change,
        .order_change = needs_order or declared,
        .creates_target = !target_exists,
        .users = users.items.len,
        .imports_added = imports_added,
        .moved_hash = moved_hash,
    });
    afters.clearRetainingCapacity();
    return result;
}

const Output = struct {
    abs: []const u8,
    before: ?*Snapshot,
    text: []const u8,
    creates: bool = false,
    ref_text: []const u8 = "",
    body: Span = .{ .start = 0, .end = 0 },
};

const Summary = struct {
    resolver: Resolver,
    fallback: ?anyerror,
    interface_change: bool,
    order_change: bool,
    creates_target: bool,
    users: usize,
    imports_added: usize,
    moved_hash: symbol.Hash,
};

fn styleOf(found: []const Import) ?[]const u8 {
    for (found) |entry| {
        if (!paths.isRelative(entry.spec)) continue;
        return paths.specExtension(entry.spec);
    }
    return null;
}

fn typeOnlyBinder(snapshot: *const Snapshot, binder: Span) bool {
    const g = snapshot.profile.rename.?;
    const node = rename.leafAt(snapshot.tree.root(), binder) orelse return false;
    const site = scope.siteOf(g, node) orelse return false;
    return site.namespace == .type;
}

fn usesOutside(arena: Allocator, snapshot: *Snapshot, name: []const u8, cut: Span, binder: ?Span) !bool {
    const resolution = try scope.resolveName(arena, snapshot, name);
    for (resolution.uses) |use| {
        if (use.span.start >= cut.start and use.span.end <= cut.end) continue;
        const index = use.binder orelse continue;
        const b = resolution.binders[index].span;
        if (binder) |wanted| {
            if (b.start == wanted.start and b.end == wanted.end) return true;
        } else if (b.start >= cut.start and b.end <= cut.end) return true;
    }
    return false;
}

fn targetImportsSame(w: Work, found: []const Import, target_abs: []const u8, local: []const u8, imported: []const u8, resolved: ?[]const u8, spec: []const u8) !bool {
    for (found) |entry| {
        if (entry.form != .import) continue;
        const same_module = if (resolved) |file| try resolvesTo(w, target_abs, entry.spec, file) else std.mem.eql(u8, entry.spec, spec);
        if (!same_module) continue;
        for (entry.named) |item| {
            if (std.mem.eql(u8, item.local(), local) and std.mem.eql(u8, item.name, imported)) return true;
        }
        if (entry.default_name) |d| if (std.mem.eql(u8, d, local) and std.mem.eql(u8, d, imported)) return true;
        if (entry.namespace) |n| if (std.mem.eql(u8, n, local) and std.mem.eql(u8, n, imported)) return true;
    }
    return false;
}

fn proveMoved(after: *Snapshot, ref: symbol.Ref, expected: symbol.Hash, function: bool) !symbol.Hash {
    const table = after.symbols() catch return error.MutationSyntaxInvalid;
    if (function) {
        const found = table.resolve(ref) catch return error.ContentHashMismatch;
        if (!std.mem.eql(u8, &found.hash, &expected)) return error.ContentHashMismatch;
        return found.hash;
    }
    const found = table.declarationMatching(ref, expected) orelse return error.ContentHashMismatch;
    return found.hash;
}

fn proveUnchanged(before: *Snapshot, after: *Snapshot, cut: Span, allow_moved: bool) !void {
    const a = try before.symbols();
    const b = after.symbols() catch return error.MutationSyntaxInvalid;
    var kept: usize = 0;
    for (a.symbols) |s| {
        if (cut.end > cut.start and s.declaration.start >= cut.start and s.declaration.start < cut.end) continue;
        kept += 1;
        var found = false;
        for (b.symbols) |t| {
            if (t.ref.eql(s.ref) and std.mem.eql(u8, &t.hash, &s.hash)) found = true;
        }
        if (!found) return error.BodyChanged;
    }
    var kept_declarations: usize = 0;
    for (a.declarations) |d| {
        if (cut.end > cut.start and d.name.startByte() >= cut.start and d.name.startByte() < cut.end) continue;
        kept_declarations += 1;
        var found = false;
        for (b.declarations) |t| {
            if (t.ref.eql(d.ref) and std.mem.eql(u8, &t.hash, &d.hash)) found = true;
        }
        if (!found) return error.BodyChanged;
    }
    if (allow_moved) return;
    if (b.symbols.len != kept or b.declarations.len != kept_declarations) return error.BodyChanged;
}

fn build(gpa: Allocator, root: []const u8, outputs: []const Output, afters: []const *Snapshot, summary: Summary) !Plan {
    const prepared = try gpa.alloc(Prepared, outputs.len);
    errdefer gpa.free(prepared);
    const edits = try gpa.alloc(Edit, outputs.len);
    errdefer gpa.free(edits);
    var built: usize = 0;
    errdefer for (prepared[0..built], edits[0..built]) |p, e| {
        gpa.free(p.rel);
        gpa.free(e.file_abs);
        gpa.free(e.ref_text);
    };
    for (outputs, afters, 0..) |o, after, i| {
        const rel = try repo.relativeUnder(gpa, root, o.abs);
        errdefer gpa.free(rel);
        const abs = try gpa.dupe(u8, o.abs);
        errdefer gpa.free(abs);
        const ref_text = try gpa.dupe(u8, o.ref_text);
        errdefer gpa.free(ref_text);
        const base_hash: ?symbol.Hash = if (o.before) |b| symbol.hashOf(b.source) else null;
        prepared[i] = .{
            .rel = rel,
            .action = if (o.creates) .create else .write,
            .base_hash = base_hash,
            .hash = symbol.hashOf(after.source),
            .snapshot = after,
            .body = o.body,
        };
        edits[i] = .{ .file_abs = abs, .ref_text = ref_text, .expected_hash = if (base_hash) |h| .{ .present = h } else .absent };
        built = i + 1;
    }
    return .{
        .prepared = prepared,
        .edits = edits,
        .resolver = summary.resolver,
        .fallback = summary.fallback,
        .interface_change = summary.interface_change,
        .order_change = summary.order_change,
        .creates_target = summary.creates_target,
        .users = summary.users,
        .imports_added = summary.imports_added,
        .moved_hash = summary.moved_hash,
    };
}

pub const Outcome = struct {
    plan: Plan,
    result: batch.BatchResult,

    pub fn deinit(self: Outcome, gpa: Allocator) void {
        self.result.deinit(gpa);
        self.plan.deinit(gpa);
    }
};

pub fn tryMove(gpa: Allocator, io: std.Io, runtime: *Runtime, options: Options) !Outcome {
    if (options.test_command.len == 0) return error.NoTestCommand;
    const dir = std.fs.path.dirname(options.request.file_abs) orelse return error.InvalidPath;
    const root = try repo.gitToplevel(gpa, io, dir);
    defer gpa.free(root);
    const lock = try shadow.Lock.acquire(io, root);
    defer lock.release();
    const planned = try plan(gpa, io, runtime, root, options.request, options.language_service);
    errdefer planned.deinit(gpa);
    const result = try batch.commitPlanned(gpa, io, root, planned.prepared, planned.edits, .{
        .edits = planned.edits,
        .test_command = options.test_command,
        .typecheck_command = options.typecheck_command,
        .linked = options.linked,
        .limits = options.limits,
        .allow_repo_memory = options.allow_repo_memory,
        .shadow_root = options.shadow_root,
        .trace = options.trace,
        .commit_step = options.commit_step,
    });
    return .{ .plan = planned, .result = result };
}
