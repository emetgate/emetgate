const std = @import("std");
const facts = @import("facts.zig");
const facts_store = @import("facts_store.zig");

const Allocator = std.mem.Allocator;
const Store = facts_store.Store;
const FileId = facts_store.FileId;
const DefId = facts_store.DefId;
const none = facts.none;

pub const max_keys_per_seed = 4;

pub const Seed = struct {
    file: FileId,
    def: u32,
};

pub const User = struct {
    file: FileId,
    def: u32,
    path: []const u8,
    qname: []const u8,
    line: u32,
    links: u32,
    through_key: bool,
};

pub const Options = struct {
    skip: ?*const fn (path: []const u8) bool = null,
};

fn defIdOf(store: *const Store, file: FileId, def: u32) ?DefId {
    const state = store.file(file);
    if (state.status != .indexed or def >= state.facts.defs.len or def >= state.slots.len) return null;
    return .{ .file = file, .slot = state.slots[def] };
}

fn within(defs: []const facts.Def, outer: u32, inner: u32) bool {
    if (outer >= defs.len or inner >= defs.len) return false;
    const a = defs[outer].span;
    const b = defs[inner].span;
    return b.start >= a.start and b.end <= a.end;
}

fn isKey(d: facts.Def) bool {
    return d.kind == .variable and d.parent == 0;
}

const Collector = struct {
    arena: Allocator,
    store: *const Store,
    options: Options,
    seed: Seed,
    index: std.AutoHashMapUnmanaged(u64, usize) = .empty,
    out: *std.ArrayList(User),

    fn add(self: *Collector, file: FileId, def: u32, through_key: bool) !void {
        if (def == 0 or def == none) return;
        const state = self.store.file(file);
        if (state.status != .indexed or def >= state.facts.defs.len) return;
        if (file == self.seed.file and within(state.facts.defs, self.seed.def, def)) return;
        const d = state.facts.defs[def];
        if (d.kind == .module) return;
        if (self.options.skip) |skip| {
            if (skip(state.path)) return;
        }
        const k = (@as(u64, file) << 32) | def;
        const entry = try self.index.getOrPut(self.arena, k);
        if (entry.found_existing) {
            const u = &self.out.items[entry.value_ptr.*];
            u.links += 1;
            if (through_key) u.through_key = true;
            return;
        }
        entry.value_ptr.* = self.out.items.len;
        try self.out.append(self.arena, .{ .file = file, .def = def, .path = state.path, .qname = d.qname, .line = d.line, .links = 1, .through_key = through_key });
    }

    fn incoming(self: *Collector, target: DefId, through_key: bool) !void {
        const list = self.store.incoming.get(target.key()) orelse return;
        for (list.items) |key| {
            const found = self.store.refAt(key) orelse continue;
            const link = switch (found.link) {
                .def => |d| d,
                .unresolved => continue,
            };
            if (link.id.file != target.file or link.id.slot != target.slot) continue;
            if (found.ref.kind == .import) continue;
            try self.add(key.file, found.ref.from, through_key);
        }
    }
};

pub fn users(arena: Allocator, store: *const Store, seeds: []const Seed, options: Options) ![]User {
    var out: std.ArrayList(User) = .empty;
    var global: std.AutoHashMapUnmanaged(u64, usize) = .empty;
    for (seeds) |seed| {
        const id = defIdOf(store, seed.file, seed.def) orelse continue;
        var c: Collector = .{ .arena = arena, .store = store, .options = options, .seed = seed, .out = &out };
        c.index = global;
        try c.incoming(id, false);
        const state = store.file(seed.file);
        const defs = state.facts.defs;
        if (defs[seed.def].kind.callable() and state.links.len == state.facts.refs.len) {
            var keys: std.ArrayList(DefId) = .empty;
            for (state.facts.refs, state.links) |r, l| {
                if (keys.items.len >= max_keys_per_seed) break;
                if (r.kind != .read or !within(defs, seed.def, r.from)) continue;
                const target = switch (l) {
                    .def => |d| d.id,
                    .unresolved => continue,
                };
                const t_state = store.file(target.file);
                const di = t_state.defIndex(target.slot) orelse continue;
                if (!isKey(t_state.facts.defs[di])) continue;
                for (keys.items) |k| {
                    if (k.file == target.file and k.slot == target.slot) break;
                } else try keys.append(arena, target);
            }
            for (keys.items) |k| try c.incoming(k, true);
        }
        global = c.index;
    }
    return out.items;
}

const testing = std.testing;

test "map usage: a definition inside its own seed is never its own user" {
    const defs = [_]facts.Def{
        .{ .kind = .module, .name = "", .qname = "", .parent = none, .span = .{ .start = 0, .end = 100 }, .name_start = 0, .line = 1, .hash = std.mem.zeroes(facts.Hash), .alpha = std.mem.zeroes(facts.Hash) },
        .{ .kind = .function, .name = "Catch", .qname = "Catch", .parent = 0, .span = .{ .start = 10, .end = 60 }, .name_start = 19, .line = 2, .hash = std.mem.zeroes(facts.Hash), .alpha = std.mem.zeroes(facts.Hash) },
        .{ .kind = .arrow, .name = "", .qname = "Catch.<arrow>", .parent = 1, .span = .{ .start = 30, .end = 55 }, .name_start = 30, .line = 3, .hash = std.mem.zeroes(facts.Hash), .alpha = std.mem.zeroes(facts.Hash) },
        .{ .kind = .variable, .name = "KEY", .qname = "KEY", .parent = 0, .span = .{ .start = 70, .end = 90 }, .name_start = 76, .line = 5, .hash = std.mem.zeroes(facts.Hash), .alpha = std.mem.zeroes(facts.Hash) },
    };
    try testing.expect(within(&defs, 1, 2));
    try testing.expect(!within(&defs, 1, 3));
    try testing.expect(isKey(defs[3]));
    try testing.expect(!isKey(defs[2]));
}
