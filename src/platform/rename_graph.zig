const std = @import("std");
const ts = @import("../engine/tree_sitter.zig");
const symbol = @import("../engine/symbol.zig");
const rename = @import("../engine/rename.zig");
const scope = @import("../engine/scope.zig");
const traversal = @import("../engine/traversal.zig");
const facts = @import("../engine/facts.zig");
const facts_extract = @import("../engine/facts_extract.zig");
const facts_store = @import("../engine/facts_store.zig");
const registry = @import("../engine/lang/registry.zig");
const Profile = @import("../engine/lang/profile.zig").Profile;
const repo = @import("repo.zig");
const io_seam = @import("io_seam.zig");
const fact_modules = @import("fact_modules.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;
const Snapshot = @import("../engine/loader.zig").Snapshot;

const Allocator = std.mem.Allocator;
const Span = symbol.Span;
const none = facts.none;

pub const Proven = struct {
    abs: []u8,
    span: Span,
};

pub const Sites = struct {
    count: usize = 0,
    buf: [480]u8 = undefined,
    len: usize = 0,

    pub fn list(self: *const Sites) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn add(self: *Sites, rel: []const u8, source: []const u8, offset: u32) void {
        self.count += 1;
        const line = std.mem.count(u8, source[0..@min(offset, source.len)], "\n") + 1;
        const sep: []const u8 = if (self.len == 0) "" else ", ";
        const written = std.fmt.bufPrint(self.buf[self.len..], "{s}{s}:{d}", .{ sep, rel, line }) catch return;
        self.len += written.len;
    }
};

pub const Found = struct {
    proven: []Proven,
    member: bool,
    free_uses: bool,

    pub fn deinit(self: Found, gpa: Allocator) void {
        for (self.proven) |p| gpa.free(p.abs);
        gpa.free(self.proven);
    }
};

const Place = struct {
    file: u32,
    index: u32,

    fn eql(a: Place, b: Place) bool {
        return a.file == b.file and a.index == b.index;
    }
};

const Graph = struct {
    gpa: Allocator,
    profile: *const Profile,
    store: facts_store.Store,
    rels: std.ArrayList([]const u8) = .empty,
    snapshots: std.ArrayList(*Snapshot) = .empty,
    ids: std.ArrayList(facts_store.FileId) = .empty,

    fn init(gpa: Allocator, profile: *const Profile) Graph {
        return .{ .gpa = gpa, .profile = profile, .store = facts_store.Store.init(gpa) };
    }

    fn deinit(self: *Graph) void {
        for (self.snapshots.items) |s| s.destroy();
        self.snapshots.deinit(self.gpa);
        for (self.rels.items) |r| self.gpa.free(r);
        self.rels.deinit(self.gpa);
        self.ids.deinit(self.gpa);
        self.store.deinit();
    }

    fn indexOf(self: *const Graph, rel: []const u8) ?u32 {
        for (self.rels.items, 0..) |known, i| {
            if (std.ascii.eqlIgnoreCase(known, rel)) return @intCast(i);
        }
        return null;
    }

    fn addRel(self: *Graph, rel: []const u8) !void {
        const owned = try self.gpa.dupe(u8, rel);
        std.mem.replaceScalar(u8, owned, '\\', '/');
        if (self.indexOf(owned) != null) {
            self.gpa.free(owned);
            return;
        }
        errdefer self.gpa.free(owned);
        try self.rels.append(self.gpa, owned);
    }

    fn addMentioning(self: *Graph, io: std.Io, root: []const u8, word: []const u8) !void {
        const listing = try repo.filesMentioning(self.gpa, io, root, word);
        defer self.gpa.free(listing);
        var files = std.mem.tokenizeScalar(u8, listing, 0);
        while (files.next()) |rel| {
            if (registry.forPath(rel) != self.profile) continue;
            try self.addRel(rel);
        }
    }

    fn addPackageInits(self: *Graph, fs: io_seam.Fs, root: []const u8) !void {
        const modules = self.profile.modules orelse return;
        if (modules.package_init.len == 0) return;
        var i: usize = 0;
        while (i < self.rels.items.len) : (i += 1) {
            var dir = std.fs.path.dirnamePosix(self.rels.items[i]) orelse continue;
            while (true) {
                const init_rel = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ dir, modules.package_init });
                defer self.gpa.free(init_rel);
                const abs = try std.fmt.allocPrint(self.gpa, "{s}\\{s}", .{ root, init_rel });
                defer self.gpa.free(abs);
                std.mem.replaceScalar(u8, abs[root.len..], '/', '\\');
                if (fs.stat(abs, .follow)) |_| try self.addRel(init_rel) else |_| {}
                dir = std.fs.path.dirnamePosix(dir) orelse break;
            }
        }
    }

    fn absOf(self: *const Graph, gpa: Allocator, root: []const u8, file: u32) ![]u8 {
        const abs = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ root, self.rels.items[file] });
        std.mem.replaceScalar(u8, abs[root.len..], '/', '\\');
        return abs;
    }

    fn load(self: *Graph, io: std.Io, runtime: *Runtime, root: []const u8, from: usize) !void {
        for (self.rels.items[from..], from..) |rel, i| {
            const abs = try self.absOf(self.gpa, root, @intCast(i));
            defer self.gpa.free(abs);
            const snapshot = try Snapshot.load(runtime, io, .cwd(), abs);
            {
                errdefer snapshot.destroy();
                try self.snapshots.append(self.gpa, snapshot);
            }
            if (snapshot.tree.root().hasError()) return error.SourceHasErrors;
            var scratch = std.heap.ArenaAllocator.init(self.gpa);
            defer scratch.deinit();
            const found = try facts_extract.extract(scratch.allocator(), snapshot);
            const arena = try self.gpa.create(std.heap.ArenaAllocator);
            arena.* = std.heap.ArenaAllocator.init(self.gpa);
            const kept = facts.clone(arena.allocator(), found) catch |err| {
                arena.deinit();
                self.gpa.destroy(arena);
                return err;
            };
            const id = try self.store.ensureFile(rel);
            _ = try self.store.replace(id, snapshot.profile, symbol.fileHash(snapshot.source), arena, kept, &.{});
            try self.ids.append(self.gpa, id);
        }
    }

    fn state(self: *const Graph, file: u32) *const facts_store.FileState {
        return self.store.file(self.ids.items[file]);
    }

    fn def(self: *const Graph, at: Place) facts.Def {
        return self.state(at.file).facts.defs[at.index];
    }

    fn placeOf(self: *const Graph, id: facts_store.DefId) ?Place {
        for (self.ids.items, 0..) |known, file| {
            if (known != id.file) continue;
            const index = self.state(@intCast(file)).defIndex(id.slot) orelse return null;
            return .{ .file = @intCast(file), .index = index };
        }
        return null;
    }

    fn hasBase(self: *const Graph, at: Place) bool {
        for (self.state(at.file).facts.classes) |class| {
            if (class.def == at.index) return class.base != none;
        }
        return false;
    }
};

const Locator = struct {
    gpa: Allocator,
    graph: *Graph,
    old: []const u8,
    target: Place,
    parent: ?Place,
    sites: ?*Sites = null,
    proven: std.ArrayList(Place) = .empty,

    fn prove(self: *Locator, file: u32, start: u32) !void {
        const at: Place = .{ .file = file, .index = start };
        for (self.proven.items) |known| {
            if (known.eql(at)) return;
        }
        try self.proven.append(self.gpa, at);
    }

    fn isProven(self: *const Locator, file: u32, start: u32) bool {
        for (self.proven.items) |known| {
            if (known.file == file and known.index == start) return true;
        }
        return false;
    }

    fn refuseLookalikes(self: *const Locator) !void {
        const graph = self.graph;
        const target = graph.def(self.target);
        for (graph.ids.items, 0..) |_, f| {
            const file: u32 = @intCast(f);
            for (graph.state(file).facts.defs, 0..) |d, i| {
                const at: Place = .{ .file = file, .index = @intCast(i) };
                if (i == 0 or at.eql(self.target) or !std.mem.eql(u8, d.name, self.old)) continue;
                if (target.kind.isType()) {
                    if (file == self.target.file and d.parent == self.target.index and d.kind == .constructor) continue;
                    return error.RenameUnresolved;
                }
                if (self.parent != null and file == self.target.file and d.parent == target.parent) return error.RenameUnresolved;
                if (d.parent != 0 and graph.hasBase(.{ .file = file, .index = d.parent })) return error.RenameUnresolved;
            }
        }
    }

    fn proveLinked(self: *Locator) !void {
        const graph = self.graph;
        const target = graph.def(self.target);
        try self.prove(self.target.file, target.name_start);
        if (target.kind.isType()) {
            for (graph.state(self.target.file).facts.defs) |d| {
                if (d.parent == self.target.index and d.kind == .constructor and std.mem.eql(u8, d.name, self.old)) try self.prove(self.target.file, d.name_start);
            }
        }
        for (graph.ids.items, 0..) |_, f| {
            const file: u32 = @intCast(f);
            const st = graph.state(file);
            for (st.facts.refs, st.links) |ref, link| {
                if (!std.mem.eql(u8, ref.name, self.old)) continue;
                const linked = switch (link) {
                    .def => |d| graph.placeOf(d.id) orelse continue,
                    .unresolved => continue,
                };
                if (linked.eql(self.target)) try self.prove(file, ref.start);
            }
        }
    }

    fn proveBound(self: *Locator) !void {
        for (self.graph.snapshots.items, 0..) |snapshot, f| {
            const file: u32 = @intCast(f);
            const resolution = try scope.resolveName(self.gpa, snapshot, self.old);
            defer resolution.deinit(self.gpa);
            for (resolution.uses) |use| {
                const b = use.binder orelse continue;
                if (self.isProven(file, resolution.binders[b].span.start)) try self.prove(file, use.span.start);
            }
        }
    }

    fn proveGlobal(self: *Locator) !void {
        const graph = self.graph;
        const target = graph.def(self.target);
        for (graph.snapshots.items, 0..) |snapshot, f| {
            const file: u32 = @intCast(f);
            if (target.kind.isType() and target.parent == 0) {
                const resolution = try scope.resolveName(self.gpa, snapshot, self.old);
                defer resolution.deinit(self.gpa);
                for (resolution.uses) |use| {
                    if (use.binder != null) continue;
                    const node = rename.leafAt(snapshot.tree.root(), use.span) orelse continue;
                    const found = (try self.globalType(file, node, self.old)) orelse continue;
                    if (found.eql(self.target)) try self.prove(file, use.span.start);
                }
            }
            const parent_at = self.parent orelse continue;
            const parent = graph.def(parent_at);
            if (parent.parent != 0) continue;
            const st = graph.state(file);
            for (st.facts.refs) |ref| {
                if (!std.mem.eql(u8, ref.name, self.old) or ref.static != target.is_static) continue;
                const t = switch (ref.target) {
                    .member_of_type => |t| st.facts.types[t],
                    else => continue,
                };
                if (t.target != .unresolved or !std.mem.eql(u8, t.member, parent.name)) continue;
                const node = rename.leafAt(snapshot.tree.root(), .{ .start = ref.start, .end = ref.start + @as(u32, @intCast(self.old.len)) }) orelse continue;
                const found = (try self.globalType(file, node, parent.name)) orelse continue;
                if (found.eql(parent_at)) try self.prove(file, ref.start);
            }
        }
    }

    fn globalType(self: *const Locator, file: u32, node: ts.Node, name: []const u8) !?Place {
        const graph = self.graph;
        var found: ?Place = null;
        for (graph.ids.items, 0..) |_, f| {
            for (graph.state(@intCast(f)).facts.defs, 0..) |d, i| {
                if (i == 0 or d.kind == .constructor or !std.mem.eql(u8, d.name, name)) continue;
                if (found != null) return null;
                found = .{ .file = @intCast(f), .index = @intCast(i) };
            }
        }
        const at = found orelse return null;
        const d = graph.def(at);
        if (!d.kind.isType() or d.parent != 0) return null;
        if (self.aliased(name)) return null;
        if (!std.mem.endsWith(u8, d.qname, d.name)) return null;
        const prefix = d.qname[0 .. d.qname.len - d.name.len];
        if (prefix.len == 0) return at;
        if (prefix[prefix.len - 1] != '.') return null;
        const namespace = prefix[0 .. prefix.len - 1];
        if (try self.enclosedBy(file, node, namespace)) return at;
        if (self.imports(file, node, namespace)) return at;
        return null;
    }

    fn enclosedBy(self: *const Locator, file: u32, node: ts.Node, namespace: []const u8) !bool {
        const graph = self.graph;
        const snapshot = graph.snapshots.items[file];
        const f = graph.profile.facts.?;
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(self.gpa);
        var current = node.parent();
        while (current) |ancestor| : (current = ancestor.parent()) {
            if (!oneOf(ancestor.kind(), f.namespaces)) continue;
            const name = ancestor.childByField("name") orelse return false;
            try parts.append(self.gpa, snapshot.tree.text(name));
        }
        if (symbol.fileScopedName(graph.profile, node)) |name| try parts.append(self.gpa, snapshot.tree.text(name));
        std.mem.reverse([]const u8, parts.items);
        const joined = try std.mem.join(self.gpa, ".", parts.items);
        defer self.gpa.free(joined);
        if (std.mem.eql(u8, joined, namespace)) return true;
        return joined.len > namespace.len and std.mem.startsWith(u8, joined, namespace) and joined[namespace.len] == '.';
    }

    fn imports(self: *const Locator, file: u32, node: ts.Node, namespace: []const u8) bool {
        const graph = self.graph;
        const using = graph.profile.facts.?.using_directive orelse return false;
        const snapshot = graph.snapshots.items[file];
        var walker = traversal.Walker.init(snapshot.tree.root());
        defer walker.deinit();
        while (walker.next()) |entry| {
            const directive = entry.node;
            if (!std.mem.eql(u8, directive.kind(), using)) continue;
            walker.skipChildren();
            if (directive.childByField("name") != null) continue;
            const holder = directive.parent() orelse continue;
            if (node.startByte() < holder.startByte() or node.endByte() > holder.endByte()) continue;
            const imported = directive.namedChild(0) orelse continue;
            if (std.mem.eql(u8, snapshot.tree.text(imported), namespace)) return true;
        }
        return false;
    }

    fn aliased(self: *const Locator, name: []const u8) bool {
        const graph = self.graph;
        const using = graph.profile.facts.?.using_directive orelse return false;
        for (graph.snapshots.items) |snapshot| {
            var walker = traversal.Walker.init(snapshot.tree.root());
            defer walker.deinit();
            while (walker.next()) |entry| {
                if (!std.mem.eql(u8, entry.node.kind(), using)) continue;
                walker.skipChildren();
                const alias = entry.node.childByField("name") orelse continue;
                if (std.mem.eql(u8, snapshot.tree.text(alias), name)) return true;
            }
        }
        return false;
    }

    fn account(self: *const Locator) !void {
        const graph = self.graph;
        for (graph.snapshots.items, 0..) |snapshot, f| {
            const file: u32 = @intCast(f);
            const st = graph.state(file);
            const leaves = try rename.leavesNamed(self.gpa, snapshot, self.old);
            defer self.gpa.free(leaves);
            const resolution = try scope.resolveName(self.gpa, snapshot, self.old);
            defer resolution.deinit(self.gpa);
            for (leaves) |leaf| {
                if (self.isProven(file, leaf.span.start)) continue;
                if (declares(st.facts.defs, leaf.span.start)) continue;
                if (linkedElsewhere(st, leaf.span.start)) continue;
                if (resolution.binderAt(leaf.span)) |b| {
                    if (!resolution.binders[b].import) continue;
                }
                if (resolution.useAt(leaf.span)) |use| {
                    if (use.binder) |b| if (!resolution.binders[b].import and !self.isProven(file, resolution.binders[b].span.start)) continue;
                }
                const sites = self.sites orelse return error.RenameUnresolved;
                sites.add(graph.rels.items[file], snapshot.source, leaf.span.start);
            }
        }
        if (self.sites) |sites| if (sites.count != 0) return error.RenameUnresolved;
    }
};

fn declares(defs: []const facts.Def, start: u32) bool {
    for (defs[1..]) |d| {
        if (d.name_start == start) return true;
    }
    return false;
}

fn linkedElsewhere(st: *const facts_store.FileState, start: u32) bool {
    for (st.facts.refs, st.links) |ref, link| {
        if (ref.start != start) continue;
        if (link == .def) return true;
    }
    return false;
}

fn oneOf(kind: []const u8, kinds: []const []const u8) bool {
    for (kinds) |candidate| {
        if (std.mem.eql(u8, candidate, kind)) return true;
    }
    return false;
}

fn renameable(d: facts.Def) bool {
    return switch (d.kind) {
        .function, .generator, .method, .class, .interface, .enumeration, .field => true,
        .variable => d.parent == 0,
        else => false,
    };
}

pub fn supports(profile: *const Profile) bool {
    return facts_extract.supports(profile);
}

pub fn locate(gpa: Allocator, io: std.Io, runtime: *Runtime, root: []const u8, file_abs: []const u8, offset: u32, old: []const u8, sites: ?*Sites) !Found {
    const profile = registry.forPath(file_abs) orelse return error.UnsupportedLanguage;
    if (!supports(profile)) return error.UnsupportedLanguage;
    var graph = Graph.init(gpa, profile);
    defer graph.deinit();
    const declaring_rel = try repo.relativeUnder(gpa, root, file_abs);
    defer gpa.free(declaring_rel);
    try graph.addRel(declaring_rel);
    try graph.addMentioning(io, root, old);
    try graph.load(io, runtime, root, 0);

    const target_index = for (graph.state(0).facts.defs, 0..) |d, i| {
        if (i != 0 and d.name_start == offset and std.mem.eql(u8, d.name, old)) break @as(u32, @intCast(i));
    } else return error.RenameUnresolved;
    const target_place: Place = .{ .file = 0, .index = target_index };
    const target = graph.def(target_place);
    if (!renameable(target)) return error.RenameUnresolved;
    var parent: ?Place = null;
    if (target.parent != 0) {
        const holder: Place = .{ .file = 0, .index = target.parent };
        switch (graph.def(holder).kind) {
            .interface => return error.RenameUnresolved,
            .class => {
                if (graph.hasBase(holder)) return error.RenameUnresolved;
                parent = holder;
            },
            else => {},
        }
    }
    const global_types = profile.facts.?.global_types;
    if (global_types) if (parent) |p| {
        const loaded = graph.rels.items.len;
        try graph.addMentioning(io, root, graph.def(p).name);
        try graph.load(io, runtime, root, loaded);
    };

    var real = io_seam.Real.init(gpa, io);
    defer real.deinit();
    const before_inits = graph.rels.items.len;
    try graph.addPackageInits(real.seam().fs, root);
    try graph.load(io, runtime, root, before_inits);
    var workspace = try fact_modules.Workspace.build(gpa, real.seam().fs, root, graph.rels.items);
    defer workspace.deinit();
    try graph.store.linkAll(workspace.resolver());

    var locator: Locator = .{ .gpa = gpa, .graph = &graph, .old = old, .target = target_place, .parent = parent, .sites = sites };
    defer locator.proven.deinit(gpa);
    try locator.refuseLookalikes();
    try locator.proveLinked();
    if (global_types) try locator.proveGlobal();
    try locator.proveBound();
    try locator.account();

    var proven: std.ArrayList(Proven) = .empty;
    errdefer {
        for (proven.items) |p| gpa.free(p.abs);
        proven.deinit(gpa);
    }
    for (locator.proven.items) |at| {
        const abs = try graph.absOf(gpa, root, at.file);
        errdefer gpa.free(abs);
        try proven.append(gpa, .{ .abs = abs, .span = .{ .start = at.index, .end = at.index + @as(u32, @intCast(old.len)) } });
    }
    return .{ .proven = try proven.toOwnedSlice(gpa), .member = parent != null, .free_uses = global_types };
}
