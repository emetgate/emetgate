const std = @import("std");
const facts = @import("facts.zig");
const facts_store = @import("facts_store.zig");
const answer = @import("answer.zig");

const Allocator = std.mem.Allocator;
const Store = facts_store.Store;
const FileId = facts_store.FileId;
const DefId = facts_store.DefId;
const none = facts.none;

pub const Relation = enum {
    callers,
    callees,
    defined_at,
    refs,

    pub fn noun(self: Relation) []const u8 {
        return switch (self) {
            .callers => "callers",
            .callees => "callees",
            .defined_at => "definitions",
            .refs => "references",
        };
    }
};

pub const max_depth = 4;

pub const Request = struct {
    relation: Relation,
    subject: []const u8,
    path: ?[]const u8 = null,
    depth: u32 = 1,
};

pub const Context = struct {
    snapshot: answer.Snapshot,
    max_file_bytes: u64,
    largest_file_bytes: u64,
};

pub const Owner = struct {
    qname: []const u8,
    kind: facts.DefKind,
    hash: facts.Hash,
    line: u32,
};

pub const Subject = struct {
    id: DefId,
    path: []const u8,
    qname: []const u8,
    kind: facts.DefKind,
    line: u32,
    hash: facts.Hash,
    span: facts.Span,
};

pub const Site = struct {
    path: []const u8,
    line: u32,
    start: u32,
    kind: facts.RefKind,
    name: []const u8,
    certainty: facts.Certainty,
    owner: Owner,
    target: Subject,
    depth: u32,
};

pub const Rule = enum { same_name, dynamic_key, own_body };

pub const Unknown = struct {
    path: []const u8,
    line: u32,
    start: u32,
    kind: facts.RefKind,
    name: []const u8,
    reason: facts.Reason,
    owner: Owner,
    rule: Rule,
};

pub const Outside = struct {
    path: []const u8,
    line: u32,
    start: u32,
    name: []const u8,
    reason: facts.Reason,
    owner: Owner,
};

pub const Unread = struct {
    path: []const u8,
    status: facts_store.Status,
    parse_errors: bool,
};

pub const Edges = struct {
    relation: Relation,
    subjects: []const Subject = &.{},
    sites: []const Site = &.{},
    unknown: []const Unknown = &.{},
    outside: []const Outside = &.{},
    unread: []const Unread = &.{},
};

pub const FactsAnswer = answer.Answer(Edges);

pub const same_name_reasons = [_]facts.Reason{
    .property_needs_type,
    .dynamic_this,
    .interface_member,
    .member_not_found,
    .local_value,
    .parse_error,
    .dynamic_access,
    .module_not_found,
    .unindexed_module,
    .export_not_found,
    .reexport_cycle,
};

pub fn bindable(reason: facts.Reason) bool {
    for (same_name_reasons) |r| if (r == reason) return true;
    return false;
}

pub fn simpleName(subject: []const u8) []const u8 {
    const plain = subject[0 .. std.mem.indexOfScalar(u8, subject, '@') orelse subject.len];
    const dot = std.mem.lastIndexOfScalar(u8, plain, '.') orelse return plain;
    return plain[dot + 1 ..];
}

fn ownerOf(store: *const Store, file: FileId, def_index: u32) Owner {
    const d = store.file(file).facts.defs[def_index];
    return .{ .qname = d.qname, .kind = d.kind, .hash = d.hash, .line = d.line };
}

fn subjectOf(store: *const Store, id: DefId) ?Subject {
    const d = store.defOf(id) orelse return null;
    return .{ .id = id, .path = store.file(id.file).path, .qname = d.qname, .kind = d.kind, .line = d.line, .hash = d.hash, .span = d.span };
}

fn sameDef(a: DefId, b: DefId) bool {
    return a.file == b.file and a.slot == b.slot;
}

pub fn findSubjects(arena: Allocator, store: *const Store, subject: []const u8, path: ?[]const u8) ![]Subject {
    var out: std.ArrayList(Subject) = .empty;
    const name = simpleName(subject);
    const exact = name.len != subject.len;
    const list = store.by_name.get(name) orelse return out.items;
    for (list.items) |id| {
        const s = subjectOf(store, id) orelse continue;
        if (s.kind == .module) continue;
        if (exact and !std.mem.eql(u8, s.qname, subject)) continue;
        if (path) |p| if (!std.mem.eql(u8, p, s.path)) continue;
        try out.append(arena, s);
    }
    std.mem.sort(Subject, out.items, {}, subjectLess);
    return out.items;
}

fn subjectLess(_: void, a: Subject, b: Subject) bool {
    const order = std.mem.order(u8, a.path, b.path);
    if (order != .eq) return order == .lt;
    return a.line < b.line;
}

fn siteLess(_: void, a: Site, b: Site) bool {
    if (a.depth != b.depth) return a.depth < b.depth;
    const order = std.mem.order(u8, a.path, b.path);
    if (order != .eq) return order == .lt;
    if (a.start != b.start) return a.start < b.start;
    return @intFromEnum(a.kind) < @intFromEnum(b.kind);
}

fn unknownLess(_: void, a: Unknown, b: Unknown) bool {
    const order = std.mem.order(u8, a.path, b.path);
    if (order != .eq) return order == .lt;
    return a.start < b.start;
}

fn outsideLess(_: void, a: Outside, b: Outside) bool {
    const order = std.mem.order(u8, a.path, b.path);
    if (order != .eq) return order == .lt;
    return a.start < b.start;
}

fn unreadLess(_: void, a: Unread, b: Unread) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

const Builder = struct {
    arena: Allocator,
    store: *const Store,
    request: Request,
    sites: std.ArrayList(Site) = .empty,
    unknown: std.ArrayList(Unknown) = .empty,
    outside: std.ArrayList(Outside) = .empty,
    unread: std.AutoArrayHashMapUnmanaged(FileId, void) = .empty,
    seen_unknown: std.AutoHashMapUnmanaged(u64, void) = .empty,
    scope_files: std.AutoArrayHashMapUnmanaged(FileId, void) = .empty,

    fn addUnknown(self: *Builder, file: FileId, index: u32, rule: Rule) !void {
        const k = (@as(u64, file) << 32) | index;
        const entry = try self.seen_unknown.getOrPut(self.arena, k);
        if (entry.found_existing) return;
        const state = self.store.file(file);
        const r = state.facts.refs[index];
        const reason = switch (state.links[index]) {
            .unresolved => |why| why,
            .def => return,
        };
        try self.unknown.append(self.arena, .{
            .path = state.path,
            .line = r.line,
            .start = r.start,
            .kind = r.kind,
            .name = r.name,
            .reason = reason,
            .owner = ownerOf(self.store, file, r.from),
            .rule = rule,
        });
    }

    fn unreadFor(self: *Builder, name: []const u8) !void {
        const list = self.store.token_files.get(name) orelse return;
        for (list.items) |key| {
            const state = self.store.file(key.file);
            if (state.facts_gen != key.gen) continue;
            const hides = state.status == .unindexed or (state.status == .indexed and state.facts.parse_errors);
            if (hides) try self.unread.put(self.arena, key.file, {});
        }
    }

    fn unreadable(self: *Builder) !void {
        for (self.store.files.items, 0..) |*state, id| {
            if (state.status == .unreadable or state.status == .too_large) try self.unread.put(self.arena, @intCast(id), {});
        }
    }

    fn sameName(self: *Builder, name: []const u8, invoking_only: bool, script_global: bool) !void {
        const list = self.store.unresolved_by_name.get(name) orelse return;
        for (list.items) |key| {
            const found = self.store.refAt(key) orelse continue;
            const reason = switch (found.link) {
                .unresolved => |why| why,
                .def => continue,
            };
            if (invoking_only and !found.ref.kind.invokes()) continue;
            if (!bindable(reason) and !(script_global and reason == .global)) continue;
            try self.addUnknown(key.file, key.index, .same_name);
        }
    }

    fn reachingFiles(self: *Builder, start: FileId) !void {
        try self.scope_files.put(self.arena, start, {});
        var head: usize = 0;
        while (head < self.scope_files.count()) : (head += 1) {
            const current = self.scope_files.keys()[head];
            const importers = self.store.importers.get(current) orelse continue;
            for (importers.items) |importer| {
                if (self.scope_files.contains(importer)) continue;
                const state = self.store.file(importer);
                if (state.status != .indexed) continue;
                var still = false;
                for (state.spec_targets) |t| switch (t) {
                    .file => |f| if (f == current) {
                        still = true;
                    },
                    else => {},
                };
                if (still) try self.scope_files.put(self.arena, importer, {});
            }
        }
    }

    fn dynamicKeys(self: *Builder, name: []const u8) !void {
        for (self.scope_files.keys()) |file| {
            const state = self.store.file(file);
            for (state.dynamic) |index| {
                if (index >= state.links.len) continue;
                const r = state.facts.refs[index];
                const reason = switch (r.target) {
                    .unresolved => |why| why,
                    else => continue,
                };
                if (reason == .computed_import) continue;
                if (r.name.len != 0 and !std.mem.eql(u8, r.name, name)) continue;
                try self.addUnknown(file, index, .dynamic_key);
            }
        }
    }

    fn incomingOf(self: *Builder, target: Subject, depth: u32, invoking_only: bool, next: *std.ArrayList(DefId), seen: *std.AutoHashMapUnmanaged(u64, void)) !void {
        const list = self.store.incoming.get(target.id.key()) orelse return;
        for (list.items) |key| {
            const found = self.store.refAt(key) orelse continue;
            const link = switch (found.link) {
                .def => |d| d,
                .unresolved => continue,
            };
            if (!sameDef(link.id, target.id)) continue;
            if (invoking_only and !found.ref.kind.invokes()) continue;
            const state = self.store.file(key.file);
            try self.sites.append(self.arena, .{
                .path = state.path,
                .line = found.ref.line,
                .start = found.ref.start,
                .kind = found.ref.kind,
                .name = found.ref.name,
                .certainty = link.certainty,
                .owner = ownerOf(self.store, key.file, found.ref.from),
                .target = target,
                .depth = depth,
            });
            const caller: DefId = .{ .file = key.file, .slot = state.slots[found.ref.from] };
            const entry = try seen.getOrPut(self.arena, caller.key());
            if (!entry.found_existing) try next.append(self.arena, caller);
        }
    }

    fn outgoingOf(self: *Builder, source: Subject, depth: u32, next: *std.ArrayList(DefId), seen: *std.AutoHashMapUnmanaged(u64, void)) !void {
        const state = self.store.file(source.id.file);
        const index = state.defIndex(source.id.slot) orelse return;
        try self.scope_files.put(self.arena, source.id.file, {});
        for (state.facts.refs, state.links, 0..) |r, l, i| {
            if (r.from != index or !r.kind.invokes()) continue;
            switch (l) {
                .def => |d| {
                    const target = subjectOf(self.store, d.id) orelse continue;
                    try self.sites.append(self.arena, .{
                        .path = state.path,
                        .line = r.line,
                        .start = r.start,
                        .kind = r.kind,
                        .name = r.name,
                        .certainty = d.certainty,
                        .owner = ownerOf(self.store, source.id.file, r.from),
                        .target = target,
                        .depth = depth,
                    });
                    const entry = try seen.getOrPut(self.arena, d.id.key());
                    if (!entry.found_existing) try next.append(self.arena, d.id);
                },
                .unresolved => |reason| {
                    if (reason.outsideRepo()) {
                        try self.outside.append(self.arena, .{ .path = state.path, .line = r.line, .start = r.start, .name = r.name, .reason = reason, .owner = ownerOf(self.store, source.id.file, r.from) });
                    } else {
                        try self.addUnknown(source.id.file, @intCast(i), .own_body);
                    }
                },
            }
        }
    }
};

fn scriptGlobal(store: *const Store, s: Subject) bool {
    const state = store.file(s.id.file);
    if (state.facts.module_mode) return false;
    const index = state.defIndex(s.id.slot) orelse return false;
    return state.facts.defs[index].parent == 0;
}

fn listedFiles(store: *const Store) u32 {
    var n: u32 = 0;
    for (store.files.items) |state| {
        if (state.status != .removed) n += 1;
    }
    return n;
}

pub fn run(arena: Allocator, store: *const Store, context: Context, request: Request) !FactsAnswer {
    if (request.depth == 0 or request.depth > max_depth) return FactsAnswer.refuse(error.DepthOutOfRange, "depth must be between 1 and 4");
    const subjects = try findSubjects(arena, store, request.subject, request.path);
    var b: Builder = .{ .arena = arena, .store = store, .request = request };
    const name = simpleName(request.subject);
    if (request.relation != .defined_at and subjects.len == 0) {
        return FactsAnswer.refuse(error.SubjectNotFound, try std.fmt.allocPrint(arena, "no indexed definition named {s}", .{request.subject}));
    }

    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    if (request.relation != .callees) try b.unreadable();
    switch (request.relation) {
        .defined_at => try b.unreadFor(name),
        .callers, .refs => {
            const invoking = request.relation == .callers;
            var frontier: std.ArrayList(DefId) = .empty;
            for (subjects) |s| {
                try frontier.append(arena, s.id);
                try seen.put(arena, s.id.key(), {});
            }
            var depth: u32 = 1;
            while (depth <= request.depth and frontier.items.len != 0) : (depth += 1) {
                var next: std.ArrayList(DefId) = .empty;
                for (frontier.items) |id| {
                    const target = subjectOf(store, id) orelse continue;
                    try b.incomingOf(target, depth, invoking, &next, &seen);
                    try b.sameName(simpleName(target.qname), invoking, scriptGlobal(store, target));
                    try b.reachingFiles(id.file);
                    try b.dynamicKeys(simpleName(target.qname));
                    try b.unreadFor(simpleName(target.qname));
                }
                if (request.relation == .refs) break;
                frontier = next;
            }
        },
        .callees => {
            var frontier: std.ArrayList(DefId) = .empty;
            for (subjects) |s| {
                try frontier.append(arena, s.id);
                try seen.put(arena, s.id.key(), {});
            }
            var depth: u32 = 1;
            while (depth <= request.depth and frontier.items.len != 0) : (depth += 1) {
                var next: std.ArrayList(DefId) = .empty;
                for (frontier.items) |id| {
                    const source = subjectOf(store, id) orelse continue;
                    try b.outgoingOf(source, depth, &next, &seen);
                }
                frontier = next;
            }
        },
    }
    return finish(arena, store, context, request, subjects, &b);
}

fn finish(arena: Allocator, store: *const Store, context: Context, request: Request, subjects: []const Subject, b: *Builder) !FactsAnswer {
    std.mem.sort(Site, b.sites.items, {}, siteLess);
    std.mem.sort(Outside, b.outside.items, {}, outsideLess);
    var unread: std.ArrayList(Unread) = .empty;
    for (b.unread.keys()) |file| {
        const state = store.file(file);
        try unread.append(arena, .{ .path = state.path, .status = state.status, .parse_errors = state.facts.parse_errors });
    }
    std.mem.sort(Unread, unread.items, {}, unreadLess);
    var kept: std.ArrayList(Unknown) = .empty;
    for (b.unknown.items) |u| {
        const hidden = for (unread.items) |f| {
            if (std.mem.eql(u8, f.path, u.path)) break true;
        } else false;
        if (!hidden) try kept.append(arena, u);
    }
    std.mem.sort(Unknown, kept.items, {}, unknownLess);

    var missing: std.ArrayList(answer.Missing) = .empty;
    var too_large = false;
    for (unread.items) |f| {
        const reason: answer.Reason = switch (f.status) {
            .too_large => blk: {
                too_large = true;
                break :blk .too_large;
            },
            .unreadable => .unreadable,
            .unindexed, .indexed => .unclassified,
            .removed => continue,
        };
        try missing.append(arena, .{ .path = f.path, .reason = reason });
    }
    for (kept.items) |u| try missing.append(arena, .{ .path = u.path, .reason = .unresolved, .line = u.line });

    const listed: u32 = switch (request.relation) {
        .callees => @intCast(b.scope_files.count()),
        else => listedFiles(store),
    };
    const file_missing: u32 = @intCast(unread.items.len);
    const budgets: []const answer.Budget = if (too_large) try arena.dupe(answer.Budget, &.{.{ .limit = .file_bytes, .max = context.max_file_bytes, .used = @min(context.largest_file_bytes, context.max_file_bytes) }}) else &.{};
    const value: Edges = .{
        .relation = request.relation,
        .subjects = subjects,
        .sites = b.sites.items,
        .unknown = kept.items,
        .outside = b.outside.items,
        .unread = unread.items,
    };
    const resolved: u32 = @intCast(switch (request.relation) {
        .defined_at => subjects.len,
        else => b.sites.items.len,
    });
    const cert: answer.Certificate = .{
        .snapshot = context.snapshot,
        .scope = .{ .listed = listed, .evaluated = listed -| file_missing },
        .semantics = .{ .facts = .{ .relation = @tagName(request.relation), .subject = request.subject, .resolved = resolved, .unresolved = @intCast(kept.items.len) } },
        .budgets = budgets,
    };
    return FactsAnswer.finish(value, cert, missing.items);
}
