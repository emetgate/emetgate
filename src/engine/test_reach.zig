//! Whether any test reaches a definition through the static reference graph.
//! The walk goes backwards over incoming references (callers, then their callers)
//! and answers `untested` only when every path ends without a test; a reference it
//! cannot follow, or a walk that grows past its limit, answers `unknown` instead.
const std = @import("std");
const facts = @import("facts.zig");
const facts_store = @import("facts_store.zig");
const facts_query = @import("facts_query.zig");
const map = @import("map.zig");

const Allocator = std.mem.Allocator;
const Store = facts_store.Store;
const DefId = facts_store.DefId;
const FileState = facts_store.FileState;

pub const Reach = enum { tested, untested, unknown };

pub const max_visits: usize = 4000;

pub fn isTestFile(state: *const FileState) bool {
    return map.isTestFile(state, null);
}

pub fn reach(arena: Allocator, store: *const Store, start: DefId) Allocator.Error!Reach {
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    var queue: std.ArrayList(DefId) = .empty;
    try seen.put(arena, start.key(), {});
    try queue.append(arena, start);
    var uncertain = false;
    var next: usize = 0;
    while (next < queue.items.len) : (next += 1) {
        if (next >= max_visits) return .unknown;
        const id = queue.items[next];
        const def = store.defOf(id) orelse {
            uncertain = true;
            continue;
        };
        if (def.kind == .module) {
            uncertain = true;
            continue;
        }
        if (byName(store, facts_query.simpleName(def.qname), &uncertain)) return .tested;
        const list = store.incoming.get(id.key()) orelse continue;
        for (list.items) |key| {
            const found = store.refAt(key) orelse continue;
            const link = switch (found.link) {
                .def => |d| d,
                .unresolved => continue,
            };
            if (link.id.key() != id.key()) continue;
            const state = store.file(key.file);
            if (isTestFile(state)) {
                if (found.ref.kind != .type) return .tested;
                continue;
            }
            switch (found.ref.kind) {
                .call, .new, .read => {},
                .import, .type, .write => continue,
            }
            if (found.ref.from >= state.slots.len) {
                uncertain = true;
                continue;
            }
            const caller: DefId = .{ .file = key.file, .slot = state.slots[found.ref.from] };
            const entry = try seen.getOrPut(arena, caller.key());
            if (!entry.found_existing) try queue.append(arena, caller);
        }
    }
    return if (uncertain) .unknown else .untested;
}

fn byName(store: *const Store, name: []const u8, uncertain: *bool) bool {
    const list = store.unresolved_by_name.get(name) orelse return false;
    for (list.items) |key| {
        const found = store.refAt(key) orelse continue;
        const reason = switch (found.link) {
            .unresolved => |why| why,
            .def => continue,
        };
        if (!found.ref.kind.invokes() or !facts_query.bindable(reason)) continue;
        if (isTestFile(store.file(key.file))) return true;
        uncertain.* = true;
    }
    return false;
}

/// Indexes of the innermost callable definitions that overlap [start, end).
pub fn changedDefs(arena: Allocator, state: *const FileState, start: u32, end: u32) Allocator.Error![]const u32 {
    var overlapping: std.ArrayList(u32) = .empty;
    for (state.facts.defs, 0..) |d, i| {
        if (!d.kind.callable()) continue;
        if (d.span.end <= start or d.span.start >= @max(end, start + 1)) continue;
        try overlapping.append(arena, @intCast(i));
    }
    var out: std.ArrayList(u32) = .empty;
    for (overlapping.items) |i| {
        const outer = state.facts.defs[i].span;
        var holds_inner = false;
        for (overlapping.items) |j| {
            if (i == j) continue;
            const inner = state.facts.defs[j].span;
            if (inner.start >= outer.start and inner.end <= outer.end and (inner.start != outer.start or inner.end != outer.end)) {
                holds_inner = true;
                break;
            }
        }
        if (!holds_inner) try out.append(arena, i);
    }
    return out.items;
}
