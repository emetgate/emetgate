const std = @import("std");
const facts = @import("facts.zig");
const facts_store = @import("facts_store.zig");
const map = @import("map.zig");
const profile_mod = @import("lang/profile.zig");

const Allocator = std.mem.Allocator;
const Store = facts_store.Store;
const FileId = facts_store.FileId;
const FileState = facts_store.FileState;
const MapTable = profile_mod.MapTable;
const none = facts.none;

const max_variants: usize = 4;
const max_depth: u32 = 8;

pub const Row = struct {
    kind: facts.MapKind,
    display: []const u8,
    handler: []const u8,
    file: FileId,
    line: u32,
    def_file: u32 = none,
    def: u32 = none,
};

const Key = struct {
    file: FileId,
    group: u32,
};

const Target = struct {
    file: FileId,
    def: u32,
};

const Incoming = struct {
    parent: ?Key,
    prefix: []const u8,
    overrides: bool,
};

const Prefixes = []const []const u8;

const Resolver = struct {
    arena: Allocator,
    store: *const Store,
    fallback: ?*const MapTable,
    incoming: std.AutoHashMapUnmanaged(Key, std.ArrayList(Incoming)) = .empty,
    memo: std.AutoHashMapUnmanaged(Key, Prefixes) = .empty,
    visiting: std.AutoHashMapUnmanaged(Key, void) = .empty,

    fn state(self: *const Resolver, file: FileId) *const FileState {
        return &self.store.files.items[file];
    }

    fn live(self: *const Resolver, file: FileId) bool {
        const s = self.state(file);
        return s.status == .indexed and !map.isTestFile(s, self.fallback);
    }

    fn specTarget(self: *const Resolver, s: *const FileState, spec: u32) ?FileId {
        _ = self;
        if (spec == none or spec >= s.spec_targets.len) return null;
        return switch (s.spec_targets[spec]) {
            .file => |f| f,
            else => null,
        };
    }

    fn moduleOf(self: *const Resolver, file: FileId, name: []const u8) ?FileId {
        const s = self.state(file);
        for (s.facts.bindings) |b| {
            if (!std.mem.eql(u8, b.local, name)) continue;
            if (b.submodule != none) return self.specTarget(s, b.submodule);
            if (b.imported.len != 0 and !std.mem.eql(u8, b.imported, "*")) continue;
            return self.specTarget(s, b.spec);
        }
        for (s.facts.specs, 0..) |spec, i| {
            if (std.mem.eql(u8, spec.text, name)) return self.specTarget(s, @intCast(i));
        }
        return null;
    }

    fn resolveName(self: *const Resolver, file: FileId, name: []const u8, depth: u32) ?Key {
        if (depth > max_depth) return null;
        const s = self.state(file);
        if (s.status != .indexed) return null;
        if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
            const module = self.moduleOf(file, name[0..dot]) orelse return null;
            return self.resolveName(module, name[dot + 1 ..], depth + 1);
        }
        for (s.facts.map.groups, 0..) |g, i| {
            if (g.top and !g.class_like and std.mem.eql(u8, g.name, name)) return .{ .file = file, .group = @intCast(i) };
        }
        for (s.facts.bindings) |b| {
            if (!std.mem.eql(u8, b.local, name) or self.specTarget(s, b.submodule) != null) continue;
            const target = self.specTarget(s, b.spec) orelse continue;
            return self.resolveName(target, b.imported, depth + 1);
        }
        return null;
    }

    fn moduleByPath(self: *const Resolver, dotted: []const u8) Allocator.Error!?FileId {
        const slashed = try self.arena.dupe(u8, dotted);
        std.mem.replaceScalar(u8, slashed, '.', '/');
        const plain = try std.mem.concat(self.arena, u8, &.{ "/", slashed, ".py" });
        const package = try std.mem.concat(self.arena, u8, &.{ "/", slashed, "/__init__.py" });
        var found: ?FileId = null;
        for (self.store.files.items, 0..) |*s, id| {
            if (s.status != .indexed) continue;
            if (!endsAtSegment(s.path, plain) and !endsAtSegment(s.path, package)) continue;
            if (found != null) return null;
            found = @intCast(id);
        }
        return found;
    }

    fn gatherMounts(self: *Resolver) Allocator.Error!void {
        for (self.store.files.items, 0..) |*s, id| {
            const file: FileId = @intCast(id);
            if (!self.live(file)) continue;
            for (s.facts.map.mounts) |m| {
                const child: ?Key = blk: {
                    if (m.module) {
                        const target = try self.moduleByPath(m.child) orelse break :blk null;
                        break :blk .{ .file = target, .group = none };
                    }
                    if (self.resolveName(file, m.child, 0)) |key| break :blk key;
                    const module = self.moduleOf(file, m.child) orelse break :blk null;
                    break :blk .{ .file = module, .group = none };
                };
                const key = child orelse continue;
                const parent: ?Key = if (m.parent_group != none)
                    .{ .file = file, .group = m.parent_group }
                else if (m.parent.len == 0)
                    .{ .file = file, .group = none }
                else
                    self.resolveName(file, m.parent, 0);
                const slot = try self.incoming.getOrPut(self.arena, key);
                if (!slot.found_existing) slot.value_ptr.* = .empty;
                try slot.value_ptr.append(self.arena, .{ .parent = parent, .prefix = m.prefix, .overrides = m.overrides });
            }
        }
    }

    fn ownPrefix(self: *const Resolver, key: Key) []const u8 {
        if (key.group == none) return "";
        return self.state(key.file).facts.map.groups[key.group].prefix;
    }

    fn prefixes(self: *Resolver, key: Key) Allocator.Error!Prefixes {
        if (self.memo.get(key)) |known| return known;
        const own = self.ownPrefix(key);
        const list = self.incoming.getPtr(key);
        if (list == null or self.visiting.contains(key)) return self.single(own);
        try self.visiting.put(self.arena, key, {});
        defer _ = self.visiting.remove(key);
        var out: std.ArrayList([]const u8) = .empty;
        for (list.?.items) |m| {
            const parents: Prefixes = if (m.parent) |p| try self.prefixes(p) else try self.single("");
            for (parents) |parent| {
                const mounted = try join(self.arena, parent, m.prefix);
                const variant = if (m.overrides) mounted else try join(self.arena, mounted, own);
                if (!contains(out.items, variant)) try out.append(self.arena, variant);
            }
        }
        var result: Prefixes = out.items;
        if (out.items.len > max_variants) {
            const many = try std.fmt.allocPrint(self.arena, "<{d} mounts>", .{out.items.len});
            result = try self.single(try join(self.arena, many, own));
        }
        try self.memo.put(self.arena, key, result);
        return result;
    }

    fn single(self: *const Resolver, value: []const u8) Allocator.Error!Prefixes {
        const out = try self.arena.alloc([]const u8, 1);
        out[0] = value;
        return out;
    }

    fn classPrefixes(self: *const Resolver, key: Key) Allocator.Error!Prefixes {
        const group = self.state(key.file).facts.map.groups[key.group];
        var out: std.ArrayList([]const u8) = .empty;
        for (self.store.files.items, 0..) |*s, id| {
            if (!self.live(@intCast(id))) continue;
            for (s.facts.map.groups) |g| {
                if (!g.class_like or g.prefix.len == 0 or !std.mem.eql(u8, g.name, group.name)) continue;
                if (!contains(out.items, g.prefix)) try out.append(self.arena, g.prefix);
            }
        }
        if (out.items.len != 0) return out.items;
        return self.basePrefixes(group.base, 0);
    }

    fn basePrefixes(self: *const Resolver, base: []const u8, depth: u32) Allocator.Error!Prefixes {
        if (base.len == 0 or depth > max_depth) return self.single("");
        var routes: std.ArrayList([]const u8) = .empty;
        var next: []const u8 = "";
        for (self.store.files.items, 0..) |*s, id| {
            if (!self.live(@intCast(id))) continue;
            for (s.facts.map.groups) |g| {
                if (!g.class_like or !std.mem.eql(u8, shortName(g.name), base)) continue;
                if (g.prefix.len == 0) {
                    if (next.len == 0) next = g.base;
                } else if (!contains(routes.items, g.prefix)) try routes.append(self.arena, g.prefix);
            }
        }
        if (routes.items.len == 1) return self.single(routes.items[0]);
        if (routes.items.len > 1) return self.single(try std.fmt.allocPrint(self.arena, "<base route: {s}>", .{base}));
        return self.basePrefixes(next, depth + 1);
    }

    fn targetByLink(self: *const Resolver, file: FileId, start: u32, end: u32) ?Target {
        const s = self.state(file);
        if (s.links.len != s.facts.refs.len) return null;
        var found: ?Target = null;
        for (s.facts.refs, s.links) |r, l| {
            if (r.kind == .import or r.start < start or r.start >= end) continue;
            const d = switch (l) {
                .def => |d| d.id,
                .unresolved => continue,
            };
            if (d.file >= self.store.files.items.len) continue;
            const di = self.state(d.file).defIndex(d.slot) orelse continue;
            found = .{ .file = d.file, .def = di };
        }
        return found;
    }

    fn defNamed(self: *const Resolver, file: FileId, name: []const u8) ?u32 {
        for (self.state(file).facts.defs, 0..) |d, i| {
            if (d.kind != .module and std.mem.eql(u8, d.qname, name)) return @intCast(i);
        }
        return null;
    }

    fn targetByName(self: *const Resolver, file: FileId, name: []const u8, depth: u32) ?Target {
        if (depth > max_depth or self.state(file).status != .indexed) return null;
        if (self.defNamed(file, name)) |di| return .{ .file = file, .def = di };
        const s = self.state(file);
        if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
            const head = name[0..dot];
            if (self.moduleOf(file, head)) |module| return self.targetByName(module, name[dot + 1 ..], depth + 1);
            const first = std.mem.indexOfScalar(u8, name, '.').?;
            for (s.facts.bindings) |b| {
                if (!std.mem.eql(u8, b.local, name[0..first]) or self.specTarget(s, b.submodule) != null) continue;
                const target = self.specTarget(s, b.spec) orelse continue;
                const qualified = std.mem.concat(self.arena, u8, &.{ b.imported, name[first..] }) catch return null;
                return self.targetByName(target, qualified, depth + 1);
            }
            return null;
        }
        for (s.facts.bindings) |b| {
            if (!std.mem.eql(u8, b.local, name) or self.specTarget(s, b.submodule) != null) continue;
            const target = self.specTarget(s, b.spec) orelse continue;
            return self.targetByName(target, b.imported, depth + 1);
        }
        return null;
    }

    fn targetByTypeName(self: *const Resolver, name: []const u8) ?Target {
        var found: ?Target = null;
        for (self.store.files.items, 0..) |*s, id| {
            if (s.status != .indexed) continue;
            for (s.facts.defs, 0..) |d, di| {
                if (d.kind == .module or !endsAtDot(d.qname, name)) continue;
                if (found != null) return null;
                found = .{ .file = @intCast(id), .def = @intCast(di) };
            }
        }
        return found;
    }

    fn handlerTarget(self: *const Resolver, file: FileId, entry: facts.MapEntry, table: ?*const MapTable) ?Target {
        if (entry.handler_end <= entry.handler_start) return null;
        if (self.targetByLink(file, entry.handler_start, entry.handler_end)) |t| return t;
        const name = handlerName(entry.handler);
        if (name.len == 0) return null;
        if (self.targetByName(file, name, 0)) |t| return t;
        const scoped = if (table) |t| t.namespace_scoped else false;
        return if (scoped) self.targetByTypeName(name) else null;
    }

    fn entryPrefixes(self: *Resolver, file: FileId, entry: facts.MapEntry) Allocator.Error!Prefixes {
        if (entry.group != none) {
            const key: Key = .{ .file = file, .group = entry.group };
            if (self.state(file).facts.map.groups[entry.group].class_like) return self.classPrefixes(key);
            return self.prefixes(key);
        }
        if (entry.receiver.len == 0) return self.prefixes(.{ .file = file, .group = none });
        const key = self.resolveName(file, entry.receiver, 0) orelse return self.single("");
        return self.prefixes(key);
    }

    fn tokens(self: *const Resolver, path: []const u8, file: FileId, entry: facts.MapEntry, action: []const u8) Allocator.Error![]const u8 {
        if (entry.group == none or std.mem.indexOfScalar(u8, path, '[') == null) return path;
        const group = self.state(file).facts.map.groups[entry.group];
        if (!group.class_like) return path;
        var controller = shortName(group.name);
        if (controller.len > "Controller".len and std.mem.endsWith(u8, controller, "Controller")) controller = controller[0 .. controller.len - "Controller".len];
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < path.len) {
            if (path[i] == '[') {
                if (std.mem.indexOfScalarPos(u8, path, i, ']')) |close| {
                    const token = path[i + 1 .. close];
                    const value: ?[]const u8 = if (std.ascii.eqlIgnoreCase(token, "controller"))
                        controller
                    else if (std.ascii.eqlIgnoreCase(token, "action") and action.len != 0)
                        action
                    else if (std.ascii.eqlIgnoreCase(token, "area") and group.area.len != 0)
                        group.area
                    else
                        null;
                    if (value) |v| {
                        try out.appendSlice(self.arena, v);
                        i = close + 1;
                        continue;
                    }
                }
            }
            try out.append(self.arena, path[i]);
            i += 1;
        }
        return out.items;
    }

    fn fileNamed(self: *const Resolver, file: FileId) ?[]const u8 {
        const path = self.state(file).path;
        const marker = "management/commands/";
        const at = std.mem.indexOf(u8, path, marker) orelse return null;
        if (at != 0 and path[at - 1] != '/') return null;
        const base = path[at + marker.len ..];
        if (std.mem.indexOfScalar(u8, base, '/') != null) return null;
        const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len;
        return base[0..dot];
    }

    fn addRows(self: *Resolver, file: FileId, entry: facts.MapEntry, out: *std.ArrayList(Row)) Allocator.Error!void {
        const s = self.state(file);
        var def = entry.def;
        var def_file: u32 = if (def == none) none else file;
        if (def == none) {
            if (self.handlerTarget(file, entry, map.tableOf(s, self.fallback))) |t| {
                def_file = t.file;
                def = t.def;
            }
        }
        const action = if (entry.def != none) s.facts.defs[entry.def].name else "";
        const row: Row = .{ .kind = entry.kind, .display = "", .handler = entry.handler, .file = file, .line = entry.line, .def_file = def_file, .def = def };
        if (entry.kind != .route) {
            var value = entry.text;
            if (entry.file_named) value = self.fileNamed(file) orelse return;
            var copy = row;
            copy.display = if (value.len == 0) entry.tag else try std.fmt.allocPrint(self.arena, "{s} {s}", .{ entry.tag, value });
            return out.append(self.arena, copy);
        }
        const list = if (entry.absolute) try self.single("") else try self.entryPrefixes(file, entry);
        var seen: std.ArrayList([]const u8) = .empty;
        for (list) |prefix| {
            const path = try self.tokens(try join(self.arena, prefix, entry.text), file, entry, action);
            if (contains(seen.items, path)) continue;
            try seen.append(self.arena, path);
            var copy = row;
            if (path.len == 0 and !entry.stated) {
                copy.display = entry.tag;
            } else {
                copy.display = try std.fmt.allocPrint(self.arena, "{s} {s}", .{ entry.tag, try rooted(self.arena, path) });
            }
            try out.append(self.arena, copy);
        }
    }
};

fn shortName(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    return name[dot + 1 ..];
}

fn endsAtSegment(path: []const u8, suffix: []const u8) bool {
    if (std.mem.endsWith(u8, path, suffix)) return true;
    return std.mem.eql(u8, path, suffix[1..]);
}

fn endsAtDot(qname: []const u8, name: []const u8) bool {
    if (!std.mem.endsWith(u8, qname, name)) return false;
    return qname.len == name.len or qname[qname.len - name.len - 1] == '.';
}

fn contains(list: []const []const u8, value: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, value)) return true;
    }
    return false;
}

fn handlerName(raw: []const u8) []const u8 {
    var name = raw;
    if (std.mem.indexOfAny(u8, name, "(<[ ")) |cut| name = name[0..cut];
    const view = ".as_view";
    if (std.mem.endsWith(u8, name, view)) name = name[0 .. name.len - view.len];
    return name;
}

pub fn join(arena: Allocator, left: []const u8, right: []const u8) Allocator.Error![]const u8 {
    if (left.len == 0) return right;
    if (right.len == 0) return left;
    const a = std.mem.trimEnd(u8, left, "/");
    const b = std.mem.trimStart(u8, right, "/");
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ a, b });
}

fn rooted(arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    if (path.len == 0) return "/";
    if (path[0] == '/' or path[0] == '<') return path;
    return std.fmt.allocPrint(arena, "/{s}", .{path});
}

pub fn collect(arena: Allocator, store: *const Store, fallback: ?*const MapTable) Allocator.Error![]const Row {
    var resolver: Resolver = .{ .arena = arena, .store = store, .fallback = fallback };
    var any = false;
    for (store.files.items) |*s| {
        if (s.status == .indexed and (s.facts.map.entries.len != 0 or s.facts.map.mounts.len != 0)) any = true;
    }
    if (!any) return &.{};
    try resolver.gatherMounts();
    var rows: std.ArrayList(Row) = .empty;
    for (store.files.items, 0..) |*s, id| {
        const file: FileId = @intCast(id);
        if (!resolver.live(file)) continue;
        for (s.facts.map.entries) |entry| try resolver.addRows(file, entry, &rows);
    }
    return rows.items;
}

const testing = std.testing;

test "map routes: joining keeps exactly one slash and an empty side adds none" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("/api/users", try join(arena, "/api/", "/users"));
    try testing.expectEqualStrings("/api", try join(arena, "/api", ""));
    try testing.expectEqualStrings("/users", try join(arena, "", "/users"));
    try testing.expectEqualStrings("/", try rooted(arena, ""));
    try testing.expectEqualStrings("/api", try rooted(arena, "api"));
    try testing.expectEqualStrings("<PREFIX>/x", try rooted(arena, "<PREFIX>/x"));
}

test "map routes: a handler source reduces to the name it refers to" {
    try testing.expectEqualStrings("views.UsersView", handlerName("views.UsersView.as_view()"));
    try testing.expectEqualStrings("Handlers.GetUser", handlerName("Handlers.GetUser"));
    try testing.expectEqualStrings("index", handlerName("index"));
}
