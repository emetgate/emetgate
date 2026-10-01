const std = @import("std");
const emetgate = @import("emetgate");
const facts = emetgate.facts;
const facts_extract = emetgate.facts_extract;
const facts_store = emetgate.facts_store;
const symbol = emetgate.symbol;
const test_util = emetgate.test_util;
const Snapshot = emetgate.loader.Snapshot;
const Runtime = emetgate.runtime.Runtime;

const testing = std.testing;

pub const File = struct { path: []const u8, source: []const u8 };

pub const Repo = struct {
    runtime: *Runtime,
    store: facts_store.Store,
    sources: std.StringHashMapUnmanaged([]u8) = .empty,

    pub fn init(runtime: *Runtime) Repo {
        return .{ .runtime = runtime, .store = facts_store.Store.init(testing.allocator) };
    }

    pub fn deinit(self: *Repo) void {
        self.store.deinit();
        var it = self.sources.iterator();
        while (it.next()) |entry| {
            testing.allocator.free(entry.key_ptr.*);
            testing.allocator.free(entry.value_ptr.*);
        }
        self.sources.deinit(testing.allocator);
    }

    pub fn put(self: *Repo, path: []const u8, source: []const u8) !facts_store.FileId {
        const profile = emetgate.lang_registry.forPath(path) orelse return error.UnsupportedLanguage;
        const snapshot = try Snapshot.fromSource(self.runtime, profile, try testing.allocator.dupe(u8, source));
        defer snapshot.destroy();
        var scratch = std.heap.ArenaAllocator.init(testing.allocator);
        defer scratch.deinit();
        const found = try facts_extract.extract(scratch.allocator(), snapshot);
        const arena = try testing.allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(testing.allocator);
        const kept = facts.clone(arena.allocator(), found) catch |err| {
            arena.deinit();
            testing.allocator.destroy(arena);
            return err;
        };
        const id = try self.store.ensureFile(path);
        _ = try self.store.replace(id, profile, symbol.fileHash(source), arena, kept, &.{});
        try self.remember(path, source);
        return id;
    }

    pub fn putReporting(self: *Repo, path: []const u8, source: []const u8) !bool {
        const before = if (self.store.fileId(path)) |id| self.store.file(id).signature else std.mem.zeroes(facts.Hash);
        const id = try self.put(path, source);
        return !std.mem.eql(u8, &before, &self.store.file(id).signature);
    }

    fn remember(self: *Repo, path: []const u8, source: []const u8) !void {
        const entry = try self.sources.getOrPut(testing.allocator, path);
        if (entry.found_existing) {
            testing.allocator.free(entry.value_ptr.*);
        } else {
            entry.key_ptr.* = try testing.allocator.dupe(u8, path);
        }
        entry.value_ptr.* = try testing.allocator.dupe(u8, source);
    }

    pub fn resolver(self: *Repo) facts_store.Resolver {
        return .{ .ctx = self, .resolveFn = resolve };
    }

    fn resolve(ctx: *anyopaque, store: *const facts_store.Store, importer: facts_store.FileId, spec: []const u8) std.mem.Allocator.Error!facts_store.SpecTarget {
        _ = ctx;
        if (!std.mem.startsWith(u8, spec, "./")) return .external;
        const importer_path = store.file(importer).path;
        const dir = std.fs.path.dirnamePosix(importer_path) orelse "";
        var buf: [512]u8 = undefined;
        for ([_][]const u8{ ".ts", ".js", "/index.ts" }) |ext| {
            const candidate = (if (dir.len == 0)
                std.fmt.bufPrint(&buf, "{s}{s}", .{ spec[2..], ext })
            else
                std.fmt.bufPrint(&buf, "{s}/{s}{s}", .{ dir, spec[2..], ext })) catch return .not_found;
            if (store.fileId(candidate)) |id| {
                if (store.file(id).status == .indexed) return .{ .file = id };
            }
        }
        return .not_found;
    }

    pub fn linkAll(self: *Repo) !void {
        try self.store.linkAll(self.resolver());
    }

    pub fn def(self: *const Repo, path: []const u8, qname: []const u8) !facts_store.DefId {
        const id = self.store.fileId(path) orelse return error.FileNotFound;
        const state = self.store.file(id);
        for (state.facts.defs, 0..) |d, i| {
            if (std.mem.eql(u8, d.qname, qname)) return .{ .file = id, .slot = state.slots[i] };
        }
        return error.DefNotFound;
    }

    pub fn incomingCount(self: *const Repo, id: facts_store.DefId, kind: ?facts.RefKind) usize {
        const list = self.store.incoming.get(id.key()) orelse return 0;
        var n: usize = 0;
        for (list.items) |key| {
            const found = self.store.refAt(key) orelse continue;
            const target = switch (found.link) {
                .def => |d| d.id,
                .unresolved => continue,
            };
            if (target.file != id.file or target.slot != id.slot) continue;
            if (kind) |k| if (found.ref.kind != k) continue;
            n += 1;
        }
        return n;
    }

    pub fn linkOf(self: *const Repo, path: []const u8, kind: facts.RefKind, name: []const u8) !facts_store.Link {
        const id = self.store.fileId(path) orelse return error.FileNotFound;
        const state = self.store.file(id);
        for (state.facts.refs, state.links) |r, l| {
            if (r.kind == kind and std.mem.eql(u8, r.name, name)) return l;
        }
        return error.RefNotFound;
    }
};
