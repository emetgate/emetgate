const std = @import("std");
const builtin = @import("builtin");
const symbol = @import("../engine/symbol.zig");
const modules = @import("../engine/modules.zig");
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
const Prepared = batch_plan.Prepared;
const Edit = batch_plan.Edit;

pub const Request = struct {
    from_abs: []const u8,
    to_abs: []const u8,
    from_hash: symbol.Hash,
    interface_change: bool = false,
};

pub const Resolver = enum { language_service, text };

pub const Fault = enum { skip_user, skip_own_import };
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
    created_dirs: [][]u8,
    resolver: Resolver,
    fallback: ?anyerror,
    users: usize,
    rewritten: usize,
    interface_change: bool,

    pub fn deinit(self: Plan, gpa: Allocator) void {
        for (self.prepared) |p| p.deinit(gpa);
        for (self.edits) |e| {
            gpa.free(e.file_abs);
            if (e.move_source) |s| gpa.free(s);
        }
        for (self.created_dirs) |d| gpa.free(d);
        gpa.free(self.prepared);
        gpa.free(self.edits);
        gpa.free(self.created_dirs);
    }
};

const Rewrite = struct {
    file: []const u8,
    start: u32,
    end: u32,
    text: []const u8,
    resolved: []const u8,
};

const Work = struct {
    gpa: Allocator,
    arena: Allocator,
    io: std.Io,
    runtime: *Runtime,
    root: []const u8,
};

fn specSpan(source: []const u8, spec: []const u8) struct { start: u32, end: u32 } {
    const at: u32 = @intCast(@intFromPtr(spec.ptr) - @intFromPtr(source.ptr));
    return .{ .start = at, .end = at + @as(u32, @intCast(spec.len)) };
}

fn loadSnapshot(w: Work, abs: []const u8, text: ?[]const u8) !*Snapshot {
    const profile = registry.forPath(abs) orelse return error.UnsupportedLanguage;
    if (profile.modules == null) return error.UnsupportedLanguage;
    const source = if (text) |t| try w.runtime.gpa.dupe(u8, t) else try std.Io.Dir.cwd().readFileAlloc(w.io, abs, w.runtime.gpa, .limited(64 * 1024 * 1024));
    const snapshot = try Snapshot.fromSource(w.runtime, profile, source);
    errdefer snapshot.destroy();
    if (snapshot.tree.root().hasError()) return error.SourceHasErrors;
    return snapshot;
}

fn trackedSources(w: Work) ![][]const u8 {
    const files = try tsserver.programFiles(w.arena, w.io, w.root);
    for (files) |f| std.mem.replaceScalar(u8, f, '/', '\\');
    return @ptrCast(files);
}

fn stemOf(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const dot = std.mem.indexOfScalar(u8, base, '.') orelse return base;
    return base[0..dot];
}

pub fn jailDestination(gpa: Allocator, io: std.Io, root: []const u8, path: []const u8) ![]u8 {
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", gpa);
    defer gpa.free(cwd);
    const resolved = try std.fs.path.resolve(gpa, &.{ cwd, path });
    defer gpa.free(resolved);
    std.mem.replaceScalar(u8, resolved, '/', '\\');
    const rel = repo.relativeUnder(gpa, root, resolved) catch return error.FileOutsideRepo;
    defer gpa.free(rel);
    try repo.refuseInternal(rel);
    try shadow.validateRelative(rel);
    var dir: []const u8 = std.fs.path.dirname(resolved) orelse return error.InvalidPath;
    while (dir.len > root.len) {
        std.Io.Dir.cwd().access(io, dir, .{}) catch {
            dir = std.fs.path.dirname(dir) orelse break;
            continue;
        };
        if (shadow.isReparsePoint(dir) catch true) return error.ReparsePoint;
        const real = try std.Io.Dir.cwd().realPathFileAlloc(io, dir, gpa);
        defer gpa.free(real);
        if (!tsserver.sameFile(real, dir)) return error.ReparsePoint;
        dir = std.fs.path.dirname(dir) orelse break;
    }
    return gpa.dupe(u8, resolved);
}

fn missingDirs(w: Work, to_abs: []const u8) ![][]u8 {
    var reversed: std.ArrayList([]u8) = .empty;
    var dir: []const u8 = std.fs.path.dirname(to_abs) orelse return error.InvalidPath;
    while (dir.len > w.root.len) {
        std.Io.Dir.cwd().access(w.io, dir, .{}) catch {
            try reversed.append(w.arena, try w.arena.dupe(u8, dir));
            dir = std.fs.path.dirname(dir) orelse break;
            continue;
        };
        break;
    }
    std.mem.reverse([]u8, reversed.items);
    return reversed.items;
}

fn publicPath(w: Work, from_abs: []const u8) !bool {
    const rel = try repo.relativeUnder(w.arena, w.root, from_abs);
    std.mem.replaceScalar(u8, rel, '\\', '/');
    const manifest = std.fmt.allocPrint(w.arena, "{s}\\package.json", .{w.root}) catch return false;
    if (std.Io.Dir.cwd().readFileAlloc(w.io, manifest, w.arena, .limited(4 * 1024 * 1024))) |bytes| {
        const parsed = std.json.parseFromSlice(std.json.Value, w.arena, bytes, .{}) catch return true;
        if (parsed.value == .object) {
            for ([_][]const u8{ "main", "module", "types", "typings", "exports", "bin", "browser" }) |field| {
                if (parsed.value.object.get(field)) |value| if (mentionsPath(value, rel)) return true;
            }
        }
    } else |_| {}
    const config = std.fmt.allocPrint(w.arena, "{s}\\tsconfig.json", .{w.root}) catch return false;
    if (std.Io.Dir.cwd().readFileAlloc(w.io, config, w.arena, .limited(4 * 1024 * 1024))) |bytes| {
        const parsed = std.json.parseFromSlice(std.json.Value, w.arena, bytes, .{}) catch return true;
        if (parsed.value == .object) {
            const options = parsed.value.object.get("compilerOptions") orelse return false;
            if (options != .object) return false;
            const table = options.object.get("paths") orelse return false;
            if (mentionsPath(table, rel)) return true;
        }
    } else |_| {}
    return false;
}

fn mentionsPath(value: std.json.Value, rel: []const u8) bool {
    switch (value) {
        .string => |text| {
            const trimmed = std.mem.trimStart(u8, text, "./");
            if (std.mem.indexOfScalar(u8, trimmed, '*')) |star| {
                return std.mem.startsWith(u8, rel, trimmed[0..star]) and std.mem.endsWith(u8, rel, trimmed[star + 1 ..]);
            }
            const stem_rel = rel[0 .. rel.len - std.fs.path.extension(rel).len];
            const stem_text = trimmed[0 .. trimmed.len - std.fs.path.extension(trimmed).len];
            return std.ascii.eqlIgnoreCase(stem_rel, stem_text);
        },
        .array => |list| {
            for (list.items) |item| if (mentionsPath(item, rel)) return true;
            return false;
        },
        .object => |object| {
            for (object.values()) |item| if (mentionsPath(item, rel)) return true;
            return false;
        },
        else => return false,
    }
}

const FileEdits = struct {
    abs: []const u8,
    snapshot: *Snapshot,
    rewrites: std.ArrayList(Rewrite) = .empty,
};

fn lessRewrite(_: void, a: Rewrite, b: Rewrite) bool {
    return a.start < b.start;
}

fn applyRewrites(arena: Allocator, source: []const u8, rewrites: []Rewrite) ![]u8 {
    std.mem.sort(Rewrite, rewrites, {}, lessRewrite);
    var out: std.ArrayList(u8) = .empty;
    var cursor: u32 = 0;
    for (rewrites) |r| {
        try out.appendSlice(arena, source[cursor..r.start]);
        try out.appendSlice(arena, r.text);
        cursor = r.end;
    }
    try out.appendSlice(arena, source[cursor..]);
    return out.items;
}

fn crossCheck(w: Work, session: *tsserver.Session, from_abs: []const u8, to_abs: []const u8, files: []const FileEdits) !void {
    const client = try session.get();
    const from = try w.arena.dupe(u8, from_abs);
    std.mem.replaceScalar(u8, from, '\\', '/');
    const to = try w.arena.dupe(u8, to_abs);
    std.mem.replaceScalar(u8, to, '\\', '/');
    const answer = try client.fileRename(from, to);
    defer answer.deinit();
    var kernel: usize = 0;
    for (files) |f| kernel += f.rewrites.items.len;
    if (answer.value.changes.len != kernel) return error.ServiceMismatch;
    for (answer.value.changes) |change| {
        var found = false;
        for (files) |f| {
            if (!tsserver.sameFile(f.abs, change.file)) continue;
            for (f.rewrites.items) |r| {
                if (r.start == change.start and r.end == change.end and std.mem.eql(u8, r.text, change.text)) found = true;
            }
        }
        if (!found) return error.ServiceMismatch;
    }
}

pub fn plan(gpa: Allocator, io: std.Io, runtime: *Runtime, root: []const u8, request: Request, session: ?*tsserver.Session) !Plan {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const w: Work = .{ .gpa = gpa, .arena = arena, .io = io, .runtime = runtime, .root = root };
    if (std.mem.eql(u8, request.from_abs, request.to_abs)) return error.SameFile;
    if (tsserver.sameFile(request.from_abs, request.to_abs)) return error.CaseOnlyRename;
    if (blk: {
        std.Io.Dir.cwd().access(io, request.to_abs, .{}) catch break :blk false;
        break :blk true;
    }) return error.NoClobber;
    const to_profile = registry.forPath(request.to_abs) orelse return error.UnsupportedLanguage;
    if (to_profile.modules == null) return error.UnsupportedLanguage;
    if (shadow.isReparsePoint(request.from_abs) catch true) return error.ReparsePoint;

    var opened: std.ArrayList(*Snapshot) = .empty;
    defer for (opened.items) |s| s.destroy();
    const moved = try loadSnapshot(w, request.from_abs, null);
    try opened.append(arena, moved);
    if (!std.mem.eql(u8, &symbol.fileHash(moved.source), &request.from_hash)) return error.HashMismatch;

    const interface_change = try publicPath(w, request.from_abs);
    if (interface_change and !request.interface_change) return error.InterfaceChangeNeedsApproval;

    const before: paths.Existing = .{ .io = io };
    const after: paths.Existing = .{ .io = io, .virtual = &.{request.to_abs}, .removed = &.{request.from_abs} };
    var files: std.ArrayList(FileEdits) = .empty;
    try files.append(arena, .{ .abs = request.from_abs, .snapshot = moved });
    const own_style_source = moved.source;
    for (try modules.imports(arena, moved)) |entry| {
        if (!paths.isRelative(entry.spec)) continue;
        const target = (try paths.resolveSpec(arena, before, request.from_abs, entry.spec)) orelse continue;
        const spec = try paths.relativeSpec(arena, request.to_abs, target, paths.emittedExtension(paths.specExtension(entry.spec), target));
        if (std.mem.eql(u8, spec, entry.spec)) continue;
        if (faulted(.skip_own_import)) continue;
        const span = specSpan(own_style_source, entry.spec);
        try files.items[0].rewrites.append(arena, .{ .file = request.from_abs, .start = span.start, .end = span.end, .text = spec, .resolved = target });
    }
    for (try modules.dynamicSpecs(arena, moved)) |d| {
        const literal = d.literal orelse return error.DynamicPathUse;
        if (paths.isRelative(literal)) return error.DynamicPathUse;
    }

    var users: usize = 0;
    var skipped_user = false;
    const stem = stemOf(request.from_abs);
    for (try trackedSources(w)) |abs| {
        if (tsserver.sameFile(abs, request.from_abs)) continue;
        const snapshot = loadSnapshot(w, abs, null) catch |err| switch (err) {
            error.SourceHasErrors => {
                const bytes = std.Io.Dir.cwd().readFileAlloc(io, abs, arena, .limited(64 * 1024 * 1024)) catch continue;
                if (std.mem.indexOf(u8, bytes, stem) != null) return error.SourceHasErrors;
                continue;
            },
            else => |e| return e,
        };
        try opened.append(arena, snapshot);
        var edits: FileEdits = .{ .abs = abs, .snapshot = snapshot };
        for (try modules.imports(arena, snapshot)) |entry| {
            if (!paths.isRelative(entry.spec)) continue;
            const target = (try paths.resolveSpec(arena, before, abs, entry.spec)) orelse continue;
            if (!tsserver.sameFile(target, request.from_abs)) continue;
            const spec = try paths.relativeSpec(arena, abs, request.to_abs, paths.emittedExtension(paths.specExtension(entry.spec), request.to_abs));
            const span = specSpan(snapshot.source, entry.spec);
            try edits.rewrites.append(arena, .{ .file = abs, .start = span.start, .end = span.end, .text = spec, .resolved = request.to_abs });
        }
        for (try modules.dynamicSpecs(arena, snapshot)) |d| {
            if (d.literal) |literal| {
                if (!paths.isRelative(literal)) continue;
                const target = (try paths.resolveSpec(arena, before, abs, literal)) orelse continue;
                if (tsserver.sameFile(target, request.from_abs)) return error.DynamicPathUse;
            } else if (std.mem.indexOf(u8, snapshot.source, stem) != null) return error.DynamicPathUse;
        }
        if (edits.rewrites.items.len == 0) continue;
        users += 1;
        if (faulted(.skip_user) and !skipped_user) {
            skipped_user = true;
            continue;
        }
        try files.append(arena, edits);
    }

    var resolver: Resolver = .text;
    var fallback: ?anyerror = error.NoLanguageService;
    if (session) |s| {
        if (crossCheck(w, s, request.from_abs, request.to_abs, files.items)) {
            resolver = .language_service;
            fallback = null;
        } else |err| switch (err) {
            error.OutOfMemory, error.ServiceMismatch => return err,
            else => {
                s.last_error = err;
                fallback = err;
            },
        }
    }
    if (resolver == .text and users != 0) return error.FileMoveUnresolved;

    var texts: std.ArrayList([]const u8) = .empty;
    var afters: std.ArrayList(*Snapshot) = .empty;
    defer for (afters.items) |s| s.destroy();
    var rewritten: usize = 0;
    for (files.items, 0..) |f, i| {
        const text = try applyRewrites(arena, f.snapshot.source, f.rewrites.items);
        rewritten += f.rewrites.items.len;
        try texts.append(arena, text);
        const where = if (i == 0) request.to_abs else f.abs;
        const snapshot = loadSnapshot(w, where, text) catch |err| switch (err) {
            error.SourceHasErrors => return error.MutationSyntaxInvalid,
            else => |e| return e,
        };
        try afters.append(arena, snapshot);
        try proveUnchanged(f.snapshot, snapshot);
        for (f.rewrites.items) |r| {
            const importer = if (i == 0) request.to_abs else f.abs;
            const resolved = (try paths.resolveSpec(arena, after, importer, r.text)) orelse return error.UnresolvedImport;
            if (!tsserver.sameFile(resolved, r.resolved)) return error.UnresolvedImport;
        }
    }
    try proveNoStaleImport(w, after, request, files.items, texts.items);
    try proveOwnImports(w, before, after, request, moved, afters.items[0]);

    const created = try missingDirs(w, request.to_abs);
    return build(gpa, root, request, files.items, afters.items, created, .{ .resolver = resolver, .fallback = fallback, .users = users, .rewritten = rewritten, .interface_change = interface_change }, &afters);
}

fn proveUnchanged(before: *Snapshot, after: *Snapshot) !void {
    const a = try before.symbols();
    const b = after.symbols() catch return error.MutationSyntaxInvalid;
    if (a.symbols.len != b.symbols.len or a.declarations.len != b.declarations.len) return error.BodyChanged;
    for (a.symbols, b.symbols) |x, y| {
        if (!x.ref.eql(y.ref) or !std.mem.eql(u8, &x.hash, &y.hash)) return error.BodyChanged;
    }
    for (a.declarations, b.declarations) |x, y| {
        if (!x.ref.eql(y.ref) or !std.mem.eql(u8, &x.hash, &y.hash)) return error.BodyChanged;
    }
}

fn proveNoStaleImport(w: Work, after: paths.Existing, request: Request, files: []const FileEdits, texts: []const []const u8) !void {
    for (try trackedSources(w)) |abs| {
        if (tsserver.sameFile(abs, request.from_abs)) continue;
        var text: ?[]const u8 = null;
        for (files, texts) |f, t| {
            if (tsserver.sameFile(f.abs, abs)) text = t;
        }
        const snapshot = loadSnapshot(w, abs, text) catch continue;
        defer snapshot.destroy();
        for (try modules.imports(w.arena, snapshot)) |entry| {
            if (!paths.isRelative(entry.spec)) continue;
            const was = (try paths.resolveSpec(w.arena, .{ .io = w.io, .virtual = after.virtual }, abs, entry.spec)) orelse continue;
            if (tsserver.sameFile(was, request.from_abs)) return error.IncompleteMove;
            _ = (try paths.resolveSpec(w.arena, after, abs, entry.spec)) orelse return error.UnresolvedImport;
        }
    }
}

fn proveOwnImports(w: Work, before: paths.Existing, after: paths.Existing, request: Request, old: *Snapshot, new: *Snapshot) !void {
    const was = try modules.imports(w.arena, old);
    const now = try modules.imports(w.arena, new);
    if (was.len != now.len) return error.MovedImportBroken;
    for (was, now) |a, b| {
        if (!paths.isRelative(a.spec)) {
            if (!std.mem.eql(u8, a.spec, b.spec)) return error.MovedImportBroken;
            continue;
        }
        const target = (try paths.resolveSpec(w.arena, before, request.from_abs, a.spec)) orelse continue;
        const resolved = (try paths.resolveSpec(w.arena, after, request.to_abs, b.spec)) orelse return error.MovedImportBroken;
        if (!tsserver.sameFile(target, resolved)) return error.MovedImportBroken;
    }
}

const Summary = struct {
    resolver: Resolver,
    fallback: ?anyerror,
    users: usize,
    rewritten: usize,
    interface_change: bool,
};

fn build(gpa: Allocator, root: []const u8, request: Request, files: []const FileEdits, afters: []const *Snapshot, created: []const []u8, summary: Summary, owned: *std.ArrayList(*Snapshot)) !Plan {
    const prepared = try gpa.alloc(Prepared, files.len);
    errdefer gpa.free(prepared);
    const edits = try gpa.alloc(Edit, files.len);
    errdefer gpa.free(edits);
    const dirs = try gpa.alloc([]u8, created.len);
    errdefer gpa.free(dirs);
    var dirs_built: usize = 0;
    errdefer for (dirs[0..dirs_built]) |d| gpa.free(d);
    for (created, 0..) |d, i| {
        dirs[i] = try gpa.dupe(u8, d);
        dirs_built = i + 1;
    }
    var built: usize = 0;
    errdefer for (prepared[0..built], edits[0..built]) |p, e| {
        gpa.free(p.rel);
        if (p.source_rel) |s| gpa.free(s);
        gpa.free(e.file_abs);
        if (e.move_source) |s| gpa.free(s);
    };
    for (files, afters, 0..) |f, after, i| {
        const moved = i == 0;
        const target = if (moved) request.to_abs else f.abs;
        const rel = try repo.relativeUnder(gpa, root, target);
        errdefer gpa.free(rel);
        const source_rel: ?[]u8 = if (moved) try repo.relativeUnder(gpa, root, request.from_abs) else null;
        errdefer if (source_rel) |s| gpa.free(s);
        const abs = try gpa.dupe(u8, target);
        errdefer gpa.free(abs);
        const move_source: ?[]const u8 = if (moved) try gpa.dupe(u8, request.from_abs) else null;
        const base = symbol.hashOf(f.snapshot.source);
        prepared[i] = .{
            .rel = rel,
            .action = if (moved) .move_file else .write,
            .base_hash = base,
            .hash = symbol.hashOf(after.source),
            .snapshot = after,
            .source_rel = source_rel,
        };
        edits[i] = .{ .file_abs = abs, .ref_text = "", .expected_hash = .{ .present = base }, .move_source = move_source };
        built = i + 1;
    }
    owned.clearRetainingCapacity();
    return .{
        .prepared = prepared,
        .edits = edits,
        .created_dirs = dirs,
        .resolver = summary.resolver,
        .fallback = summary.fallback,
        .users = summary.users,
        .rewritten = summary.rewritten,
        .interface_change = summary.interface_change,
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

pub fn tryMoveFile(gpa: Allocator, io: std.Io, runtime: *Runtime, options: Options) !Outcome {
    if (options.test_command.len == 0) return error.NoTestCommand;
    const dir = std.fs.path.dirname(options.request.from_abs) orelse return error.InvalidPath;
    const root = try repo.gitToplevel(gpa, io, dir);
    defer gpa.free(root);
    const lock = try shadow.Lock.acquire(io, root);
    defer lock.release();
    const planned = try plan(gpa, io, runtime, root, options.request, options.language_service);
    errdefer planned.deinit(gpa);
    const created: []const []const u8 = @ptrCast(planned.created_dirs);
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
        .created_dirs = created,
    });
    return .{ .plan = planned, .result = result };
}
