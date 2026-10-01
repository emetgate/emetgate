const std = @import("std");
const facts = @import("facts.zig");
const Profile = @import("lang/profile.zig").Profile;

const Allocator = std.mem.Allocator;
const Blake3 = std.crypto.hash.Blake3;
const none = facts.none;

pub const FileId = u32;

pub const LinkError = Allocator.Error || error{SpecsNotResolved};

pub const DefId = struct {
    file: u32,
    slot: u32,

    pub fn key(self: DefId) u64 {
        return (@as(u64, self.file) << 32) | self.slot;
    }

    pub fn fromKey(value: u64) DefId {
        return .{ .file = @intCast(value >> 32), .slot = @truncate(value) };
    }
};

pub const RefKey = struct {
    file: u32,
    gen: u32,
    index: u32,
};

pub const Link = union(enum) {
    def: struct { id: DefId, certainty: facts.Certainty },
    unresolved: facts.Reason,
};

pub const SpecTarget = union(enum) {
    file: FileId,
    external,
    not_found,
    unindexed,
};

pub const Resolver = struct {
    ctx: *anyopaque,
    resolveFn: *const fn (ctx: *anyopaque, store: *const Store, importer: FileId, spec: []const u8) Allocator.Error!SpecTarget,

    pub fn resolve(self: Resolver, store: *const Store, importer: FileId, spec: []const u8) Allocator.Error!SpecTarget {
        return self.resolveFn(self.ctx, store, importer, spec);
    }
};

pub const Status = enum(u8) { indexed, unindexed, unreadable, too_large, removed };

pub const FileState = struct {
    path: []const u8,
    status: Status,
    content_hash: facts.Hash = std.mem.zeroes(facts.Hash),
    profile: ?*const Profile = null,
    arena: ?*std.heap.ArenaAllocator = null,
    facts: facts.FileFacts = empty_facts,
    slots: []u32 = &.{},
    slot_defs: std.ArrayList(u32) = .empty,
    links: []Link = &.{},
    spec_targets: []SpecTarget = &.{},
    deps: []FileId = &.{},
    signature: facts.Hash = std.mem.zeroes(facts.Hash),
    link_gen: u32 = 0,
    facts_gen: u32 = 0,
    tokens: [][]const u8 = &.{},
    dynamic: []u32 = &.{},
    note: []const u8 = "",
    members: ?std.AutoHashMapUnmanaged(u64, u32) = null,

    pub fn def(self: *const FileState, slot: u32) ?*const facts.Def {
        if (slot >= self.slot_defs.items.len) return null;
        const index = self.slot_defs.items[slot];
        if (index == none) return null;
        return &self.facts.defs[index];
    }

    pub fn defIndex(self: *const FileState, slot: u32) ?u32 {
        if (slot >= self.slot_defs.items.len) return null;
        const index = self.slot_defs.items[slot];
        return if (index == none) null else index;
    }
};

pub const empty_facts: facts.FileFacts = .{
    .defs = &.{},
    .refs = &.{},
    .specs = &.{},
    .bindings = &.{},
    .exports = &.{},
    .types = &.{},
    .classes = &.{},
    .member_types = &.{},
    .loose = &.{},
    .dynamic_reads = 0,
    .module_mode = false,
    .parse_errors = false,
};

pub const LooseKey = struct {
    file: u32,
    gen: u32,
    count: u32,
};

pub const Stats = struct {
    files: usize = 0,
    indexed: usize = 0,
    unindexed: usize = 0,
    unreadable: usize = 0,
    parse_errors: usize = 0,
    defs: usize = 0,
    refs: usize = 0,
    resolved: usize = 0,
    typed: usize = 0,
    unresolved: usize = 0,
};

const Resolved = union(enum) {
    def: DefId,
    namespace: FileId,
    unresolved: facts.Reason,
};

const max_chain = 64;

const Visit = struct {
    files: std.ArrayList(FileId) = .empty,
    path: std.ArrayList(FileId) = .empty,

    fn onPath(self: *const Visit, file: FileId) bool {
        for (self.path.items) |f| if (f == file) return true;
        return false;
    }

    fn reset(self: *Visit) void {
        self.files.clearRetainingCapacity();
        self.path.clearRetainingCapacity();
    }

    fn deinit(self: *Visit, gpa: Allocator) void {
        self.files.deinit(gpa);
        self.path.deinit(gpa);
    }
};

pub const Store = struct {
    gpa: Allocator,
    paths: std.heap.ArenaAllocator,
    files: std.ArrayList(FileState) = .empty,
    by_path: std.StringHashMapUnmanaged(FileId) = .empty,
    by_name: std.StringHashMapUnmanaged(std.ArrayList(DefId)) = .empty,
    incoming: std.AutoHashMapUnmanaged(u64, std.ArrayList(RefKey)) = .empty,
    unresolved_by_name: std.StringHashMapUnmanaged(std.ArrayList(RefKey)) = .empty,
    loose_by_name: std.StringHashMapUnmanaged(std.ArrayList(LooseKey)) = .empty,
    token_files: std.StringHashMapUnmanaged(std.ArrayList(LooseKey)) = .empty,
    rdeps: std.AutoHashMapUnmanaged(FileId, std.ArrayList(FileId)) = .empty,
    importers: std.AutoHashMapUnmanaged(FileId, std.ArrayList(FileId)) = .empty,
    root: facts.Hash = std.mem.zeroes(facts.Hash),

    pub fn init(gpa: Allocator) Store {
        return .{ .gpa = gpa, .paths = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Store) void {
        for (self.files.items) |*state| self.dropFile(state);
        self.files.deinit(self.gpa);
        self.by_path.deinit(self.gpa);
        deinitLists(DefId, self.gpa, &self.by_name);
        var incoming = self.incoming.valueIterator();
        while (incoming.next()) |list| list.deinit(self.gpa);
        self.incoming.deinit(self.gpa);
        deinitLists(RefKey, self.gpa, &self.unresolved_by_name);
        deinitLists(LooseKey, self.gpa, &self.loose_by_name);
        deinitLists(LooseKey, self.gpa, &self.token_files);
        deinitIdLists(self.gpa, &self.rdeps);
        deinitIdLists(self.gpa, &self.importers);
        self.paths.deinit();
        self.* = undefined;
    }

    fn dropFile(self: *Store, state: *FileState) void {
        if (state.arena) |arena| {
            arena.deinit();
            self.gpa.destroy(arena);
        }
        state.arena = null;
        self.gpa.free(state.slots);
        state.slot_defs.deinit(self.gpa);
        self.gpa.free(state.links);
        self.gpa.free(state.spec_targets);
        self.gpa.free(state.deps);
        self.gpa.free(state.dynamic);
        state.dynamic = &.{};
        if (state.members) |*members| members.deinit(self.gpa);
        state.members = null;
        state.slots = &.{};
        state.links = &.{};
        state.spec_targets = &.{};
        state.deps = &.{};
        state.tokens = &.{};
        state.facts = empty_facts;
    }

    pub fn intern(self: *Store, text: []const u8) ![]const u8 {
        return self.paths.allocator().dupe(u8, text);
    }

    pub fn fileId(self: *const Store, path: []const u8) ?FileId {
        return self.by_path.get(path);
    }

    pub fn file(self: *const Store, id: FileId) *const FileState {
        return &self.files.items[id];
    }

    pub fn ensureFile(self: *Store, path: []const u8) !FileId {
        if (self.by_path.get(path)) |id| return id;
        const owned = try self.intern(path);
        const id: FileId = @intCast(self.files.items.len);
        try self.files.append(self.gpa, .{ .path = owned, .status = .removed });
        try self.by_path.put(self.gpa, owned, id);
        return id;
    }

    pub fn defOf(self: *const Store, id: DefId) ?*const facts.Def {
        if (id.file >= self.files.items.len) return null;
        return self.files.items[id.file].def(id.slot);
    }

    pub fn refAt(self: *const Store, key: RefKey) ?struct { ref: *const facts.Ref, link: Link } {
        if (key.file >= self.files.items.len) return null;
        const state = &self.files.items[key.file];
        if (state.status != .indexed or state.link_gen != key.gen or key.index >= state.links.len) return null;
        return .{ .ref = &state.facts.refs[key.index], .link = state.links[key.index] };
    }

    pub fn replace(self: *Store, id: FileId, profile: *const Profile, content_hash: facts.Hash, arena: *std.heap.ArenaAllocator, found: facts.FileFacts, tokens: []const []const u8) !bool {
        const state = &self.files.items[id];
        const old_signature = state.signature;
        const was_indexed = state.status == .indexed;
        const slots = try self.gpa.alloc(u32, found.defs.len);
        errdefer self.gpa.free(slots);
        var next_slots: std.ArrayList(u32) = .empty;
        errdefer next_slots.deinit(self.gpa);
        try self.assignSlots(state, found, slots, &next_slots);
        if (state.arena) |old| {
            old.deinit();
            self.gpa.destroy(old);
        }
        self.gpa.free(state.slots);
        state.slot_defs.deinit(self.gpa);
        if (state.members) |*members| members.deinit(self.gpa);
        state.members = null;
        state.arena = arena;
        state.facts = found;
        state.profile = profile;
        state.content_hash = content_hash;
        state.status = .indexed;
        state.note = "";
        state.slots = slots;
        state.slot_defs = next_slots;
        state.facts_gen +%= 1;
        state.signature = signatureOf(found);
        self.gpa.free(state.links);
        state.links = &.{};
        self.gpa.free(state.spec_targets);
        state.spec_targets = &.{};
        state.link_gen +%= 1;
        const kept = try self.paths.allocator().alloc([]const u8, tokens.len);
        for (tokens, kept) |t, *slot| slot.* = try self.internName(t);
        state.tokens = kept;
        self.gpa.free(state.dynamic);
        state.dynamic = &.{};
        try self.registerFacts(id);
        return !was_indexed or !std.mem.eql(u8, &old_signature, &state.signature);
    }

    fn registerFacts(self: *Store, id: FileId) !void {
        const state = &self.files.items[id];
        var dynamic: std.ArrayList(u32) = .empty;
        errdefer dynamic.deinit(self.gpa);
        for (state.facts.refs, 0..) |r, i| {
            if (!r.kind.invokes()) continue;
            switch (r.target) {
                .unresolved => |reason| switch (reason) {
                    .dynamic_access, .dynamic_call, .computed_import => try dynamic.append(self.gpa, @intCast(i)),
                    else => {},
                },
                else => {},
            }
        }
        state.dynamic = try dynamic.toOwnedSlice(self.gpa);
        for (state.facts.defs, state.slots) |d, slot| {
            if (d.kind == .module) continue;
            try self.addName(d.name, .{ .file = id, .slot = slot });
        }
        for (state.facts.loose) |l| {
            const name = try self.internName(l.name);
            const slot = try self.loose_by_name.getOrPut(self.gpa, name);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            try slot.value_ptr.append(self.gpa, .{ .file = id, .gen = state.facts_gen, .count = l.count });
        }
        for (state.tokens) |t| {
            const entry = try self.token_files.getOrPut(self.gpa, t);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(self.gpa, .{ .file = id, .gen = state.facts_gen, .count = 0 });
        }
    }

    pub fn markUnindexed(self: *Store, id: FileId, status: Status, note: []const u8, tokens: []const []const u8) !bool {
        const state = &self.files.items[id];
        const was_indexed = state.status == .indexed;
        self.dropFile(state);
        state.slot_defs = .empty;
        state.status = status;
        state.note = try self.internName(note);
        state.facts_gen +%= 1;
        state.link_gen +%= 1;
        state.signature = std.mem.zeroes(facts.Hash);
        const kept = try self.paths.allocator().alloc([]const u8, tokens.len);
        for (tokens, kept) |t, *slot| slot.* = try self.internName(t);
        state.tokens = kept;
        try self.registerFacts(id);
        return was_indexed;
    }

    pub const Restored = struct {
        path: []const u8,
        status: Status,
        note: []const u8,
        content_hash: facts.Hash,
        profile: ?*const Profile,
        arena: ?*std.heap.ArenaAllocator,
        facts: facts.FileFacts,
        slots: []u32,
        slot_defs: []const u32,
        links: []Link,
        spec_targets: []SpecTarget,
        deps: []FileId,
        signature: facts.Hash,
        link_gen: u32,
        facts_gen: u32,
        tokens: [][]const u8,
    };

    pub fn restore(self: *Store, r: Restored) !FileId {
        const id: FileId = @intCast(self.files.items.len);
        if (self.by_path.contains(r.path)) return error.DuplicatePath;
        var slot_defs: std.ArrayList(u32) = .empty;
        errdefer slot_defs.deinit(self.gpa);
        try slot_defs.appendSlice(self.gpa, r.slot_defs);
        try self.files.append(self.gpa, .{
            .path = r.path,
            .status = r.status,
            .note = r.note,
            .content_hash = r.content_hash,
            .profile = r.profile,
            .arena = r.arena,
            .facts = r.facts,
            .slots = r.slots,
            .slot_defs = slot_defs,
            .links = r.links,
            .spec_targets = r.spec_targets,
            .deps = r.deps,
            .signature = r.signature,
            .link_gen = r.link_gen,
            .facts_gen = r.facts_gen,
            .tokens = r.tokens,
        });
        try self.by_path.put(self.gpa, r.path, id);
        try self.registerFacts(id);
        try self.registerLinks(id);
        return id;
    }

    fn internName(self: *Store, name: []const u8) ![]const u8 {
        if (self.by_name.getKey(name)) |k| return k;
        if (self.unresolved_by_name.getKey(name)) |k| return k;
        if (self.loose_by_name.getKey(name)) |k| return k;
        if (self.token_files.getKey(name)) |k| return k;
        return self.paths.allocator().dupe(u8, name);
    }

    fn addName(self: *Store, name: []const u8, id: DefId) !void {
        const slot = try self.by_name.getOrPut(self.gpa, name);
        if (!slot.found_existing) {
            slot.key_ptr.* = try self.internName(name);
            slot.value_ptr.* = .empty;
        }
        for (slot.value_ptr.items) |existing| {
            if (existing.file == id.file and existing.slot == id.slot) return;
        }
        try slot.value_ptr.append(self.gpa, id);
    }

    fn assignSlots(self: *Store, state: *const FileState, found: facts.FileFacts, slots: []u32, next_slots: *std.ArrayList(u32)) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var old_keys: std.StringHashMapUnmanaged(u32) = .empty;
        var ordinals: std.StringHashMapUnmanaged(u32) = .empty;
        for (state.facts.defs, 0..) |d, i| {
            if (i >= state.slots.len) break;
            const k = try slotKey(arena, &ordinals, d);
            try old_keys.put(arena, k, state.slots[i]);
        }
        var used: u32 = @intCast(state.slot_defs.items.len);
        try next_slots.appendNTimes(self.gpa, none, used);
        ordinals.clearRetainingCapacity();
        for (found.defs, 0..) |d, i| {
            const k = try slotKey(arena, &ordinals, d);
            const slot = old_keys.get(k) orelse blk: {
                used += 1;
                try next_slots.append(self.gpa, none);
                break :blk used - 1;
            };
            slots[i] = slot;
            next_slots.items[slot] = @intCast(i);
        }
    }

    pub fn remove(self: *Store, id: FileId) !bool {
        return self.markUnindexed(id, .removed, "", &.{});
    }

    pub fn exportIndex(self: *const Store, id: FileId, name: []const u8) ?u32 {
        const state = &self.files.items[id];
        for (state.facts.exports, 0..) |e, i| {
            if (e.kind != .star and std.mem.eql(u8, e.name, name)) return @intCast(i);
        }
        return null;
    }

    fn resolveExport(self: *Store, id: FileId, name: []const u8, visit: *Visit) LinkError!Resolved {
        if (visit.onPath(id) or visit.path.items.len >= max_chain) return .{ .unresolved = .reexport_cycle };
        try visit.files.append(self.gpa, id);
        try visit.path.append(self.gpa, id);
        defer _ = visit.path.pop();
        const state = &self.files.items[id];
        if (state.status != .indexed) return .{ .unresolved = .unindexed_module };
        if (self.exportIndex(id, name)) |at| {
            const e = state.facts.exports[at];
            return switch (e.kind) {
                .local => .{ .def = .{ .file = id, .slot = state.slots[e.index] } },
                .binding => self.resolveBinding(id, e.index, visit),
                .star => unreachable,
            };
        }
        const default_name = if (state.profile) |p| (if (p.modules) |m| m.default_keyword else "") else "";
        if (std.mem.eql(u8, name, default_name)) return .{ .unresolved = .export_not_found };
        var first_failure: ?facts.Reason = null;
        if (state.spec_targets.len != state.facts.specs.len) return error.SpecsNotResolved;
        for (state.facts.exports) |e| {
            if (e.kind != .star) continue;
            const target = switch (state.spec_targets[e.index]) {
                .file => |f| f,
                .external => {
                    if (first_failure == null) first_failure = .external_module;
                    continue;
                },
                .not_found => {
                    if (first_failure == null) first_failure = .module_not_found;
                    continue;
                },
                .unindexed => {
                    if (first_failure == null) first_failure = .unindexed_module;
                    continue;
                },
            };
            const found = try self.resolveExport(target, name, visit);
            switch (found) {
                .unresolved => |reason| {
                    if (reason != .export_not_found and first_failure == null) first_failure = reason;
                },
                else => return found,
            }
        }
        return .{ .unresolved = first_failure orelse .export_not_found };
    }

    fn resolveBinding(self: *Store, id: FileId, binding_index: u32, visit: *Visit) LinkError!Resolved {
        const state = &self.files.items[id];
        if (state.spec_targets.len != state.facts.specs.len) return error.SpecsNotResolved;
        const binding = state.facts.bindings[binding_index];
        const target = switch (state.spec_targets[binding.spec]) {
            .file => |f| f,
            .external => return .{ .unresolved = .external_module },
            .not_found => return .{ .unresolved = .module_not_found },
            .unindexed => return .{ .unresolved = .unindexed_module },
        };
        if (std.mem.eql(u8, binding.imported, facts.namespace_name)) {
            try visit.files.append(self.gpa, target);
            return .{ .namespace = target };
        }
        return self.resolveExport(target, binding.imported, visit);
    }

    fn memberIndex(self: *Store, id: FileId) !*std.AutoHashMapUnmanaged(u64, u32) {
        const state = &self.files.items[id];
        if (state.members) |*members| return members;
        var members: std.AutoHashMapUnmanaged(u64, u32) = .empty;
        for (state.facts.defs, 0..) |d, i| {
            if (d.parent == none) continue;
            const k = memberKey(d.parent, d.name, d.is_static);
            const slot = try members.getOrPut(self.gpa, k);
            if (!slot.found_existing) slot.value_ptr.* = @intCast(i);
        }
        state.members = members;
        return &state.members.?;
    }

    fn findMember(self: *Store, owner: DefId, name: []const u8, is_static: bool, visit: *Visit) LinkError!Resolved {
        const state = &self.files.items[owner.file];
        const owner_index = state.defIndex(owner.slot) orelse return .{ .unresolved = .member_not_found };
        const owner_def = state.facts.defs[owner_index];
        if (visit.path.items.len >= max_chain) return .{ .unresolved = .reexport_cycle };
        try visit.files.append(self.gpa, owner.file);
        try visit.path.append(self.gpa, owner.file);
        defer _ = visit.path.pop();
        const lookup_static = is_static and owner_def.kind == .class;
        const members = try self.memberIndex(owner.file);
        if (members.get(memberKey(owner_index, name, lookup_static))) |i| return .{ .def = .{ .file = owner.file, .slot = state.slots[i] } };
        switch (owner_def.kind) {
            .class => {},
            .interface => return .{ .unresolved = .interface_member },
            .type_alias => return .{ .unresolved = .property_needs_type },
            else => return .{ .unresolved = .member_not_found },
        }
        for (state.facts.classes) |c| {
            if (c.def != owner_index) continue;
            if (c.base == none) return .{ .unresolved = .member_not_found };
            const base = try self.resolveType(owner.file, c.base, visit);
            return switch (base) {
                .def => |b| if (b.file == owner.file and b.slot == owner.slot) .{ .unresolved = .reexport_cycle } else self.findMember(b, name, is_static, visit),
                .namespace => .{ .unresolved = .member_not_found },
                .unresolved => |reason| .{ .unresolved = if (reason == .external_module) .external_base else reason },
            };
        }
        return .{ .unresolved = .member_not_found };
    }

    fn resolveType(self: *Store, id: FileId, type_index: u32, visit: *Visit) LinkError!Resolved {
        const state = &self.files.items[id];
        const t = state.facts.types[type_index];
        return switch (t.target) {
            .local => |d| .{ .def = .{ .file = id, .slot = state.slots[d] } },
            .binding => |b| self.resolveBinding(id, b, visit),
            .member_of_binding => |b| switch (try self.resolveBinding(id, b, visit)) {
                .namespace => |target| self.resolveExport(target, t.member, visit),
                .def => |owner| self.findMember(owner, t.member, true, visit),
                .unresolved => |reason| .{ .unresolved = reason },
            },
            .member_of_def => |d| self.findMember(.{ .file = id, .slot = state.slots[d] }, t.member, true, visit),
            .member_of_super, .member_of_type => .{ .unresolved = .property_needs_type },
            .unresolved => |reason| .{ .unresolved = reason },
        };
    }

    fn moduleDef(self: *const Store, target: FileId) Resolved {
        const state = &self.files.items[target];
        if (state.status != .indexed or state.slots.len == 0) return .{ .unresolved = .unindexed_module };
        return .{ .def = .{ .file = target, .slot = state.slots[0] } };
    }

    fn linkRef(self: *Store, id: FileId, ref: facts.Ref, visit: *Visit) LinkError!Link {
        const state = &self.files.items[id];
        var certainty: facts.Certainty = .proven;
        const found: Resolved = switch (ref.target) {
            .local => |d| .{ .def = .{ .file = id, .slot = state.slots[d] } },
            .binding => |b| switch (try self.resolveBinding(id, b, visit)) {
                .namespace => |target| self.moduleDef(target),
                else => |r| r,
            },
            .member_of_def => |d| try self.findMember(.{ .file = id, .slot = state.slots[d] }, ref.name, ref.static, visit),
            .member_of_binding => |b| switch (try self.resolveBinding(id, b, visit)) {
                .namespace => |target| try self.resolveExport(target, ref.name, visit),
                .def => |owner| try self.findMember(owner, ref.name, true, visit),
                .unresolved => |reason| .{ .unresolved = reason },
            },
            .member_of_super => |d| blk: {
                for (state.facts.classes) |c| {
                    if (c.def != d) continue;
                    if (c.base == none) break :blk .{ .unresolved = .member_not_found };
                    break :blk switch (try self.resolveType(id, c.base, visit)) {
                        .def => |b| try self.findMember(b, ref.name, ref.static, visit),
                        .namespace => .{ .unresolved = .member_not_found },
                        .unresolved => |reason| .{ .unresolved = if (reason == .external_module) .external_base else reason },
                    };
                }
                break :blk .{ .unresolved = .member_not_found };
            },
            .member_of_type => |t| blk: {
                certainty = .typed;
                break :blk switch (try self.resolveType(id, t, visit)) {
                    .def => |owner| try self.findMember(owner, ref.name, false, visit),
                    .namespace => .{ .unresolved = .property_needs_type },
                    .unresolved => |reason| .{ .unresolved = reason },
                };
            },
            .unresolved => |reason| .{ .unresolved = reason },
        };
        return switch (found) {
            .def => |d| .{ .def = .{ .id = d, .certainty = certainty } },
            .namespace => .{ .unresolved = .member_not_found },
            .unresolved => |reason| .{ .unresolved = reason },
        };
    }

    fn resolveSpecs(self: *Store, id: FileId, resolver: Resolver) !void {
        const state = &self.files.items[id];
        if (state.status != .indexed) return;
        const spec_targets = try self.gpa.alloc(SpecTarget, state.facts.specs.len);
        errdefer self.gpa.free(spec_targets);
        for (state.facts.specs, spec_targets) |spec, *slot| slot.* = try resolver.resolve(self, id, spec.text);
        self.gpa.free(state.spec_targets);
        state.spec_targets = spec_targets;
    }

    pub fn link(self: *Store, id: FileId, resolver: Resolver) !void {
        try self.resolveSpecs(id, resolver);
        try self.linkRefs(id);
    }

    fn linkRefs(self: *Store, id: FileId) !void {
        const state = &self.files.items[id];
        if (state.status != .indexed) return;
        const spec_targets = state.spec_targets;
        if (spec_targets.len != state.facts.specs.len) return error.SpecsNotResolved;

        const links = try self.gpa.alloc(Link, state.facts.refs.len);
        errdefer self.gpa.free(links);
        var deps: std.AutoArrayHashMapUnmanaged(FileId, void) = .empty;
        defer deps.deinit(self.gpa);
        var visit: Visit = .{};
        defer visit.deinit(self.gpa);
        for (state.facts.refs, links) |ref, *slot| {
            visit.reset();
            slot.* = try self.linkRef(id, ref, &visit);
            for (visit.files.items) |f| if (f != id) try deps.put(self.gpa, f, {});
        }
        for (state.facts.classes) |c| {
            if (c.base == none) continue;
            visit.reset();
            _ = try self.resolveType(id, c.base, &visit);
            for (visit.files.items) |f| if (f != id) try deps.put(self.gpa, f, {});
        }
        for (spec_targets) |t| switch (t) {
            .file => |f| if (f != id) try deps.put(self.gpa, f, {}),
            else => {},
        };

        const owned_deps = try self.gpa.dupe(FileId, deps.keys());
        const fresh = &self.files.items[id];
        self.gpa.free(fresh.links);
        fresh.links = links;
        self.gpa.free(fresh.deps);
        fresh.deps = owned_deps;
        fresh.link_gen +%= 1;
        try self.registerLinks(id);
    }

    fn registerLinks(self: *Store, id: FileId) !void {
        const state = &self.files.items[id];
        if (state.status != .indexed) return;
        for (state.facts.refs, state.links, 0..) |ref, l, i| {
            const key: RefKey = .{ .file = id, .gen = state.link_gen, .index = @intCast(i) };
            switch (l) {
                .def => |d| {
                    const entry = try self.incoming.getOrPut(self.gpa, d.id.key());
                    if (!entry.found_existing) entry.value_ptr.* = .empty;
                    try entry.value_ptr.append(self.gpa, key);
                },
                .unresolved => {
                    const name = try self.internName(ref.name);
                    const entry = try self.unresolved_by_name.getOrPut(self.gpa, name);
                    if (!entry.found_existing) entry.value_ptr.* = .empty;
                    try entry.value_ptr.append(self.gpa, key);
                },
            }
        }
        for (state.deps) |d| try appendId(self.gpa, &self.rdeps, d, id);
        for (state.spec_targets) |t| switch (t) {
            .file => |f| if (f != id) try appendId(self.gpa, &self.importers, f, id),
            else => {},
        };
    }

    pub fn linkAll(self: *Store, resolver: Resolver) !void {
        for (0..self.files.items.len) |i| try self.resolveSpecs(@intCast(i), resolver);
        for (0..self.files.items.len) |i| try self.linkRefs(@intCast(i));
        try self.computeRoot();
    }

    pub fn relink(self: *Store, changed: []const FileId, reshaped: []const FileId, resolver: Resolver) !usize {
        var todo: std.AutoArrayHashMapUnmanaged(FileId, void) = .empty;
        defer todo.deinit(self.gpa);
        for (changed) |id| try todo.put(self.gpa, id, {});
        for (reshaped) |id| {
            const more = try self.dependents(self.gpa, id);
            defer self.gpa.free(more);
            for (more) |d| try todo.put(self.gpa, d, {});
        }
        for (todo.keys()) |id| try self.resolveSpecs(id, resolver);
        for (todo.keys()) |id| try self.linkRefs(id);
        try self.computeRoot();
        return todo.count();
    }

    pub fn dependents(self: *const Store, gpa: Allocator, id: FileId) ![]FileId {
        var out: std.AutoArrayHashMapUnmanaged(FileId, void) = .empty;
        defer out.deinit(gpa);
        if (self.rdeps.get(id)) |list| {
            for (list.items) |d| {
                if (d == id) continue;
                const state = &self.files.items[d];
                if (state.status != .indexed) continue;
                if (std.mem.indexOfScalar(FileId, state.deps, id) == null) continue;
                try out.put(gpa, d, {});
            }
        }
        return gpa.dupe(FileId, out.keys());
    }

    pub fn computeRoot(self: *Store) !void {
        const order = try self.gpa.alloc(FileId, self.files.items.len);
        defer self.gpa.free(order);
        for (order, 0..) |*slot, i| slot.* = @intCast(i);
        std.mem.sort(FileId, order, self, pathLess);
        var hasher = Blake3.init(.{});
        for (order) |i| {
            const state = &self.files.items[i];
            if (state.status == .removed) continue;
            hasher.update(state.path);
            hasher.update(&.{ 0, @intFromEnum(state.status) });
            hasher.update(&state.content_hash);
        }
        hasher.final(&self.root);
    }

    pub fn stats(self: *const Store) Stats {
        var s: Stats = .{};
        for (self.files.items) |*state| {
            switch (state.status) {
                .removed => continue,
                .indexed => s.indexed += 1,
                .unindexed => s.unindexed += 1,
                .unreadable, .too_large => s.unreadable += 1,
            }
            s.files += 1;
            if (state.facts.parse_errors) s.parse_errors += 1;
            s.defs += state.facts.defs.len;
            s.refs += state.facts.refs.len;
            for (state.links) |l| switch (l) {
                .def => |d| {
                    s.resolved += 1;
                    if (d.certainty == .typed) s.typed += 1;
                },
                .unresolved => s.unresolved += 1,
            };
        }
        return s;
    }
};

fn pathLess(store: *const Store, a: FileId, b: FileId) bool {
    return std.mem.order(u8, store.files.items[a].path, store.files.items[b].path) == .lt;
}

fn memberKey(parent: u32, name: []const u8, is_static: bool) u64 {
    var h = std.hash.Wyhash.init(@as(u64, parent) * 2 + @intFromBool(is_static));
    h.update(name);
    return h.final();
}

fn slotKey(arena: Allocator, ordinals: *std.StringHashMapUnmanaged(u32), d: facts.Def) ![]const u8 {
    const base = try std.fmt.allocPrint(arena, "{t}\x00{s}", .{ d.kind, d.qname });
    const entry = try ordinals.getOrPut(arena, base);
    if (!entry.found_existing) entry.value_ptr.* = 0;
    const ordinal = entry.value_ptr.*;
    entry.value_ptr.* += 1;
    return std.fmt.allocPrint(arena, "{s}\x00{d}", .{ base, ordinal });
}

fn signatureOf(found: facts.FileFacts) facts.Hash {
    var hasher = Blake3.init(.{});
    for (found.defs) |d| {
        hasher.update(&.{ @intFromEnum(d.kind), @intFromBool(d.exported), @intFromBool(d.is_static) });
        hasher.update(d.qname);
        hasher.update(&.{0});
        var parent: [4]u8 = undefined;
        std.mem.writeInt(u32, &parent, d.parent, .little);
        hasher.update(&parent);
    }
    hasher.update("\x01exports");
    for (found.exports) |e| {
        hasher.update(&.{@intFromEnum(e.kind)});
        hasher.update(e.name);
        hasher.update(&.{0});
        var index: [4]u8 = undefined;
        std.mem.writeInt(u32, &index, e.index, .little);
        hasher.update(&index);
    }
    hasher.update("\x01specs");
    for (found.specs) |s| {
        hasher.update(s.text);
        hasher.update(&.{ 0, @intFromEnum(s.kind) });
    }
    hasher.update("\x01bindings");
    for (found.bindings) |b| {
        var spec: [4]u8 = undefined;
        std.mem.writeInt(u32, &spec, b.spec, .little);
        hasher.update(&spec);
        hasher.update(b.imported);
        hasher.update(&.{0});
        hasher.update(b.local);
        hasher.update(&.{0});
    }
    hasher.update("\x01types");
    for (found.types) |t| {
        hasher.update(&.{@intFromEnum(std.meta.activeTag(t.target))});
        var index: [4]u8 = undefined;
        const value: u32 = switch (t.target) {
            .unresolved => |r| @intFromEnum(r),
            inline else => |v| v,
        };
        std.mem.writeInt(u32, &index, value, .little);
        hasher.update(&index);
        hasher.update(t.member);
        hasher.update(&.{0});
    }
    hasher.update("\x01classes");
    for (found.classes) |c| {
        var pair: [8]u8 = undefined;
        std.mem.writeInt(u32, pair[0..4], c.def, .little);
        std.mem.writeInt(u32, pair[4..8], c.base, .little);
        hasher.update(&pair);
    }
    var out: facts.Hash = undefined;
    hasher.final(&out);
    return out;
}

fn appendId(gpa: Allocator, map: *std.AutoHashMapUnmanaged(FileId, std.ArrayList(FileId)), key: FileId, value: FileId) !void {
    const entry = try map.getOrPut(gpa, key);
    if (!entry.found_existing) entry.value_ptr.* = .empty;
    const items = entry.value_ptr.items;
    if (items.len != 0 and items[items.len - 1] == value) return;
    try entry.value_ptr.append(gpa, value);
}

fn deinitLists(comptime T: type, gpa: Allocator, map: *std.StringHashMapUnmanaged(std.ArrayList(T))) void {
    var it = map.valueIterator();
    while (it.next()) |list| list.deinit(gpa);
    map.deinit(gpa);
}

fn deinitIdLists(gpa: Allocator, map: *std.AutoHashMapUnmanaged(FileId, std.ArrayList(FileId))) void {
    var it = map.valueIterator();
    while (it.next()) |list| list.deinit(gpa);
    map.deinit(gpa);
}
