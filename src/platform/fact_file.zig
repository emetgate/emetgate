const std = @import("std");
const facts = @import("../engine/facts.zig");
const facts_store = @import("../engine/facts_store.zig");
const registry = @import("../engine/lang/registry.zig");
const Profile = @import("../engine/lang/profile.zig").Profile;
const fact_store = @import("fact_store.zig");

const Allocator = std.mem.Allocator;
const Store = facts_store.Store;
const none = facts.none;

pub const magic = "EMGFACTS";
pub const version: u32 = 2;
pub const checksum_len = 16;
pub const max_store_bytes: usize = std.math.maxInt(u32);

pub const DecodeError = error{ Corrupt, OutOfMemory, DuplicatePath };

const Encoder = struct {
    gpa: Allocator,
    body: std.ArrayList(u8) = .empty,
    ids: std.StringHashMapUnmanaged(u32) = .empty,
    strings: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *Encoder) void {
        self.body.deinit(self.gpa);
        self.ids.deinit(self.gpa);
        self.strings.deinit(self.gpa);
    }

    fn byte(self: *Encoder, value: u8) !void {
        try self.body.append(self.gpa, value);
    }

    fn varint(self: *Encoder, value: u64) !void {
        var v = value;
        while (v >= 0x80) : (v >>= 7) try self.body.append(self.gpa, @as(u8, @truncate(v)) | 0x80);
        try self.body.append(self.gpa, @truncate(v));
    }

    fn index(self: *Encoder, value: u32) !void {
        try self.varint(if (value == none) 0 else @as(u64, value) + 1);
    }

    fn raw(self: *Encoder, bytes: []const u8) !void {
        try self.body.appendSlice(self.gpa, bytes);
    }

    fn time(self: *Encoder, value: i96) !void {
        var buf: [16]u8 = undefined;
        std.mem.writeInt(i128, &buf, value, .little);
        try self.raw(&buf);
    }

    fn str(self: *Encoder, text: []const u8) !void {
        const entry = try self.ids.getOrPut(self.gpa, text);
        if (!entry.found_existing) {
            entry.value_ptr.* = @intCast(self.strings.items.len);
            try self.strings.append(self.gpa, text);
        }
        try self.varint(entry.value_ptr.*);
    }

    fn target(self: *Encoder, value: facts.Target) !void {
        try self.byte(@intFromEnum(std.meta.activeTag(value)));
        switch (value) {
            .unresolved => |reason| try self.byte(@intFromEnum(reason)),
            inline else => |v| try self.varint(v),
        }
    }
};

const Decoder = struct {
    bytes: []const u8,
    at: usize = 0,
    strings: []const []const u8 = &.{},

    fn byte(self: *Decoder) DecodeError!u8 {
        if (self.at >= self.bytes.len) return error.Corrupt;
        defer self.at += 1;
        return self.bytes[self.at];
    }

    fn varint(self: *Decoder) DecodeError!u64 {
        var out: u64 = 0;
        var shift: u7 = 0;
        while (true) {
            const b = try self.byte();
            if (shift > 63) return error.Corrupt;
            out |= @as(u64, b & 0x7f) << @intCast(shift);
            if (b & 0x80 == 0) return out;
            shift += 7;
        }
    }

    fn int(self: *Decoder) DecodeError!u32 {
        return std.math.cast(u32, try self.varint()) orelse error.Corrupt;
    }

    fn count(self: *Decoder, unit: usize) DecodeError!usize {
        const n = try self.varint();
        if (n > (self.bytes.len - self.at) / @max(unit, 1) + 1) return error.Corrupt;
        return @intCast(n);
    }

    fn index(self: *Decoder) DecodeError!u32 {
        const v = try self.varint();
        if (v == 0) return none;
        return std.math.cast(u32, v - 1) orelse error.Corrupt;
    }

    fn raw(self: *Decoder, n: usize) DecodeError![]const u8 {
        if (self.bytes.len - self.at < n) return error.Corrupt;
        defer self.at += n;
        return self.bytes[self.at .. self.at + n];
    }

    fn hash16(self: *Decoder) DecodeError!facts.Hash {
        return (try self.raw(16))[0..16].*;
    }

    fn time(self: *Decoder) DecodeError!i96 {
        const value = std.mem.readInt(i128, (try self.raw(16))[0..16], .little);
        return std.math.cast(i96, value) orelse error.Corrupt;
    }

    fn str(self: *Decoder) DecodeError![]const u8 {
        const id = try self.varint();
        if (id >= self.strings.len) return error.Corrupt;
        return self.strings[@intCast(id)];
    }

    fn flag(self: *Decoder) DecodeError!bool {
        return switch (try self.byte()) {
            0 => false,
            1 => true,
            else => error.Corrupt,
        };
    }

    fn enumOf(self: *Decoder, comptime E: type) DecodeError!E {
        return std.enums.fromInt(E, try self.byte()) orelse error.Corrupt;
    }

    fn target(self: *Decoder) DecodeError!facts.Target {
        const tag = try self.enumOf(std.meta.Tag(facts.Target));
        return switch (tag) {
            .local => .{ .local = try self.int() },
            .binding => .{ .binding = try self.int() },
            .member_of_def => .{ .member_of_def = try self.int() },
            .member_of_binding => .{ .member_of_binding = try self.int() },
            .member_of_super => .{ .member_of_super = try self.int() },
            .member_of_type => .{ .member_of_type = try self.int() },
            .unresolved => .{ .unresolved = try self.enumOf(facts.Reason) },
        };
    }
};

fn encodeFacts(e: *Encoder, f: facts.FileFacts) !void {
    try e.varint(f.defs.len);
    for (f.defs) |d| {
        try e.byte(@intFromEnum(d.kind));
        try e.str(d.name);
        try e.str(d.qname);
        try e.index(d.parent);
        try e.varint(d.span.start);
        try e.varint(d.span.end);
        try e.varint(d.name_start);
        try e.varint(d.line);
        try e.raw(&d.hash);
        try e.raw(&d.alpha);
        try e.byte(@as(u8, @intFromBool(d.exported)) | (@as(u8, @intFromBool(d.is_static)) << 1));
    }
    try e.varint(f.refs.len);
    for (f.refs) |r| {
        try e.varint(r.from);
        try e.byte(@intFromEnum(r.kind));
        try e.str(r.name);
        try e.varint(r.start);
        try e.varint(r.line);
        try e.target(r.target);
        try e.byte(@intFromBool(r.static));
    }
    try e.varint(f.specs.len);
    for (f.specs) |s| {
        try e.str(s.text);
        try e.varint(s.line);
        try e.byte(@intFromEnum(s.kind));
    }
    try e.varint(f.bindings.len);
    for (f.bindings) |b| {
        try e.varint(b.spec);
        try e.str(b.imported);
        try e.str(b.local);
        try e.varint(b.start);
        try e.byte(@intFromBool(b.type_only));
    }
    try e.varint(f.exports.len);
    for (f.exports) |x| {
        try e.str(x.name);
        try e.byte(@intFromEnum(x.kind));
        try e.varint(x.index);
    }
    try e.varint(f.types.len);
    for (f.types) |t| {
        try e.target(t.target);
        try e.str(t.member);
    }
    try e.varint(f.classes.len);
    for (f.classes) |c| {
        try e.varint(c.def);
        try e.index(c.base);
    }
    try e.varint(f.member_types.len);
    for (f.member_types) |m| {
        try e.varint(m.class);
        try e.str(m.name);
        try e.byte(@intFromBool(m.is_static));
        try e.varint(m.type);
    }
    try e.varint(f.loose.len);
    for (f.loose) |l| {
        try e.str(l.name);
        try e.varint(l.count);
    }
    try e.varint(f.dynamic_reads);
    try e.byte(@intFromBool(f.module_mode));
    try e.byte(@intFromBool(f.parse_errors));
}

fn decodeFacts(d: *Decoder, a: Allocator) DecodeError!facts.FileFacts {
    const defs = try a.alloc(facts.Def, try d.count(40));
    for (defs) |*def| {
        def.kind = try d.enumOf(facts.DefKind);
        def.name = try d.str();
        def.qname = try d.str();
        def.parent = try d.index();
        def.span = .{ .start = try d.int(), .end = try d.int() };
        def.name_start = try d.int();
        def.line = try d.int();
        def.hash = try d.hash16();
        def.alpha = try d.hash16();
        const flags = try d.byte();
        if (flags > 3) return error.Corrupt;
        def.exported = flags & 1 != 0;
        def.is_static = flags & 2 != 0;
    }
    const refs = try a.alloc(facts.Ref, try d.count(7));
    for (refs) |*r| {
        r.from = try d.int();
        if (r.from >= defs.len) return error.Corrupt;
        r.kind = try d.enumOf(facts.RefKind);
        r.name = try d.str();
        r.start = try d.int();
        r.line = try d.int();
        r.target = try d.target();
        r.static = try d.flag();
    }
    const specs = try a.alloc(facts.Spec, try d.count(3));
    for (specs) |*s| {
        s.text = try d.str();
        s.line = try d.int();
        s.kind = try d.enumOf(facts.SpecKind);
    }
    const bindings = try a.alloc(facts.Binding, try d.count(5));
    for (bindings) |*b| {
        b.spec = try d.int();
        if (b.spec >= specs.len) return error.Corrupt;
        b.imported = try d.str();
        b.local = try d.str();
        b.start = try d.int();
        b.type_only = try d.flag();
    }
    const exports = try a.alloc(facts.Export, try d.count(3));
    for (exports) |*x| {
        x.name = try d.str();
        x.kind = try d.enumOf(facts.ExportKind);
        x.index = try d.int();
        const bound: usize = switch (x.kind) {
            .local => defs.len,
            .binding => bindings.len,
            .star => specs.len,
        };
        if (x.index >= bound) return error.Corrupt;
    }
    const types = try a.alloc(facts.TypeRef, try d.count(3));
    for (types) |*t| {
        t.target = try d.target();
        t.member = try d.str();
    }
    const classes = try a.alloc(facts.Class, try d.count(2));
    for (classes) |*c| {
        c.def = try d.int();
        c.base = try d.index();
        if (c.def >= defs.len or (c.base != none and c.base >= types.len)) return error.Corrupt;
    }
    const member_types = try a.alloc(facts.MemberType, try d.count(4));
    for (member_types) |*m| {
        m.class = try d.int();
        m.name = try d.str();
        m.is_static = try d.flag();
        m.type = try d.int();
        if (m.class >= defs.len or m.type >= types.len) return error.Corrupt;
    }
    const loose = try a.alloc(facts.Loose, try d.count(2));
    for (loose) |*l| {
        l.name = try d.str();
        l.count = try d.int();
    }
    const found: facts.FileFacts = .{
        .defs = defs,
        .refs = refs,
        .specs = specs,
        .bindings = bindings,
        .exports = exports,
        .types = types,
        .classes = classes,
        .member_types = member_types,
        .loose = loose,
        .dynamic_reads = try d.int(),
        .module_mode = try d.flag(),
        .parse_errors = try d.flag(),
    };
    try checkTargets(found);
    return found;
}

fn checkTarget(found: facts.FileFacts, target: facts.Target) DecodeError!void {
    const ok = switch (target) {
        .local, .member_of_def, .member_of_super => |v| v < found.defs.len,
        .binding, .member_of_binding => |v| v < found.bindings.len,
        .member_of_type => |v| v < found.types.len,
        .unresolved => true,
    };
    if (!ok) return error.Corrupt;
}

fn checkTargets(found: facts.FileFacts) DecodeError!void {
    for (found.refs) |r| try checkTarget(found, r.target);
    for (found.types) |t| try checkTarget(found, t.target);
}

fn profileByName(name: []const u8) ?*const Profile {
    for (registry.profiles) |profile| {
        if (std.mem.eql(u8, profile.name, name)) return profile;
    }
    return null;
}

pub fn encode(gpa: Allocator, repo: *fact_store.Repo) ![]u8 {
    var e: Encoder = .{ .gpa = gpa };
    defer e.deinit();
    try e.time(repo.written_ns);
    try e.varint(repo.barrier);
    try e.raw(&repo.config_signature);
    try e.raw(&repo.store.root);
    const files = repo.store.files.items;
    try e.varint(files.len);
    for (files, 0..) |*state, id| {
        const m = try repo.meta(@intCast(id));
        try e.str(state.path);
        try e.byte(@intFromEnum(state.status));
        try e.str(state.note);
        try e.time(m.stamp.mtime_ns);
        try e.varint(m.stamp.size);
        try e.raw(&state.content_hash);
        try e.raw(&m.digest);
        try e.varint(state.facts_gen);
        try e.varint(state.link_gen);
        try e.raw(&state.signature);
        try e.str(if (state.profile) |p| p.name else "");
        switch (state.status) {
            .indexed => {
                try encodeFacts(&e, state.facts);
                for (state.slots) |slot| try e.varint(slot);
                try e.varint(state.slot_defs.items.len);
                for (state.slot_defs.items) |d| try e.index(d);
                try e.varint(state.links.len);
                for (state.links) |l| switch (l) {
                    .def => |d| {
                        try e.byte(0);
                        try e.varint(d.id.file);
                        try e.varint(d.id.slot);
                        try e.byte(@intFromEnum(d.certainty));
                    },
                    .unresolved => |reason| {
                        try e.byte(1);
                        try e.byte(@intFromEnum(reason));
                    },
                };
                try e.varint(state.spec_targets.len);
                for (state.spec_targets) |t| switch (t) {
                    .file => |f| {
                        try e.byte(0);
                        try e.varint(f);
                    },
                    .external => try e.byte(1),
                    .not_found => try e.byte(2),
                    .unindexed => try e.byte(3),
                };
                try e.varint(state.deps.len);
                for (state.deps) |dep| try e.varint(dep);
            },
            else => {},
        }
        try e.varint(state.tokens.len);
        for (state.tokens) |t| try e.str(t);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, magic);
    var version_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &version_bytes, version, .little);
    try out.appendSlice(gpa, &version_bytes);
    var head: Encoder = .{ .gpa = gpa };
    defer head.deinit();
    try head.varint(e.strings.items.len);
    for (e.strings.items) |s| {
        try head.varint(s.len);
        try head.raw(s);
    }
    try out.appendSlice(gpa, head.body.items);
    try out.appendSlice(gpa, e.body.items);
    var sum: [checksum_len]u8 = undefined;
    std.crypto.hash.Blake3.hash(out.items, &sum, .{});
    try out.appendSlice(gpa, &sum);
    return out.toOwnedSlice(gpa);
}

pub fn verified(bytes: []const u8) error{ Corrupt, Version }![]const u8 {
    if (bytes.len < magic.len + 4 + checksum_len) return error.Corrupt;
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.Corrupt;
    const body = bytes[0 .. bytes.len - checksum_len];
    var sum: [checksum_len]u8 = undefined;
    std.crypto.hash.Blake3.hash(body, &sum, .{});
    if (!std.mem.eql(u8, &sum, bytes[bytes.len - checksum_len ..])) return error.Corrupt;
    if (std.mem.readInt(u32, bytes[magic.len..][0..4], .little) != version) return error.Version;
    return body[magic.len + 4 ..];
}

pub fn decode(repo: *fact_store.Repo, body: []const u8) DecodeError!void {
    const gpa = repo.gpa;
    var d: Decoder = .{ .bytes = body };
    const string_count = try d.count(1);
    const strings = try repo.store.paths.allocator().alloc([]const u8, string_count);
    for (strings) |*s| {
        const len = try d.count(1);
        s.* = try repo.store.paths.allocator().dupe(u8, try d.raw(len));
    }
    d.strings = strings;
    repo.written_ns = try d.time();
    repo.barrier = try d.varint();
    repo.config_signature = try d.hash16();
    const root = try d.hash16();
    const file_count = try d.count(60);
    for (0..file_count) |id| {
        const path = try d.str();
        const status = try d.enumOf(facts_store.Status);
        const note = try d.str();
        const mtime = try d.time();
        const size = try d.varint();
        const content_hash = try d.hash16();
        const digest = (try d.raw(32))[0..32].*;
        const facts_gen = try d.int();
        const link_gen = try d.int();
        const signature = try d.hash16();
        const profile_name = try d.str();
        var restored: facts_store.Store.Restored = .{
            .path = path,
            .status = status,
            .note = note,
            .content_hash = content_hash,
            .profile = null,
            .arena = null,
            .facts = facts_store.empty_facts,
            .slots = &.{},
            .slot_defs = &.{},
            .links = &.{},
            .spec_targets = &.{},
            .deps = &.{},
            .signature = signature,
            .link_gen = link_gen,
            .facts_gen = facts_gen,
            .tokens = &.{},
        };
        if (status == .indexed) {
            restored.profile = profileByName(profile_name) orelse return error.Corrupt;
            const arena = try gpa.create(std.heap.ArenaAllocator);
            arena.* = std.heap.ArenaAllocator.init(gpa);
            var owned = true;
            defer if (owned) {
                arena.deinit();
                gpa.destroy(arena);
            };
            const a = arena.allocator();
            restored.facts = try decodeFacts(&d, a);
            const slots = try gpa.alloc(u32, restored.facts.defs.len);
            defer if (owned) gpa.free(slots);
            for (slots) |*s| s.* = try d.int();
            const slot_defs = try a.alloc(u32, try d.count(1));
            for (slot_defs) |*s| {
                s.* = try d.index();
                if (s.* != none and s.* >= restored.facts.defs.len) return error.Corrupt;
            }
            for (slots) |s| if (s >= slot_defs.len) return error.Corrupt;
            const links = try gpa.alloc(facts_store.Link, try d.count(2));
            defer if (owned) gpa.free(links);
            if (links.len != restored.facts.refs.len) return error.Corrupt;
            for (links) |*l| {
                l.* = switch (try d.byte()) {
                    0 => .{ .def = .{ .id = .{ .file = try d.int(), .slot = try d.int() }, .certainty = try d.enumOf(facts.Certainty) } },
                    1 => .{ .unresolved = try d.enumOf(facts.Reason) },
                    else => return error.Corrupt,
                };
            }
            const spec_targets = try gpa.alloc(facts_store.SpecTarget, try d.count(1));
            defer if (owned) gpa.free(spec_targets);
            if (spec_targets.len != restored.facts.specs.len) return error.Corrupt;
            for (spec_targets) |*t| {
                t.* = switch (try d.byte()) {
                    0 => .{ .file = try d.int() },
                    1 => .external,
                    2 => .not_found,
                    3 => .unindexed,
                    else => return error.Corrupt,
                };
            }
            const deps = try gpa.alloc(facts_store.FileId, try d.count(1));
            defer if (owned) gpa.free(deps);
            for (deps) |*dep| dep.* = try d.int();
            restored.arena = arena;
            restored.slots = slots;
            restored.slot_defs = slot_defs;
            restored.links = links;
            restored.spec_targets = spec_targets;
            restored.deps = deps;
            restored.tokens = try readTokens(repo, &d);
            _ = try repo.store.restore(restored);
            owned = false;
        } else {
            restored.tokens = try readTokens(repo, &d);
            _ = try repo.store.restore(restored);
        }
        const m = try repo.meta(@intCast(id));
        m.* = .{ .stamp = .{ .mtime_ns = mtime, .size = size }, .digest = digest };
    }
    if (d.at != body.len) return error.Corrupt;
    for (repo.store.files.items) |*state| {
        for (state.links) |l| switch (l) {
            .def => |x| if (x.id.file >= file_count) return error.Corrupt,
            .unresolved => {},
        };
        for (state.spec_targets) |t| switch (t) {
            .file => |f| if (f >= file_count) return error.Corrupt,
            else => {},
        };
        for (state.deps) |dep| if (dep >= file_count) return error.Corrupt;
    }
    try repo.store.computeRoot();
    if (!std.mem.eql(u8, &root, &repo.store.root)) return error.Corrupt;
    repo.linked = true;
}

fn readTokens(repo: *fact_store.Repo, d: *Decoder) DecodeError![][]const u8 {
    const tokens = try repo.store.paths.allocator().alloc([]const u8, try d.count(1));
    for (tokens) |*t| t.* = try d.str();
    return tokens;
}

pub fn load(repo: *fact_store.Repo, path: []const u8) !fact_store.Load {
    const bytes = repo.fs.readFile(path, repo.gpa, max_store_bytes) catch |err| switch (err) {
        error.FileNotFound => return .absent,
        error.OutOfMemory => return error.OutOfMemory,
        error.TooLarge => return .{ .rebuilt = "too_large" },
        else => return .{ .rebuilt = @errorName(err) },
    };
    defer repo.gpa.free(bytes);
    const body = verified(bytes) catch |err| return .{ .rebuilt = switch (err) {
        error.Corrupt => "corrupt",
        error.Version => "version",
    } };
    decode(repo, body) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Corrupt, error.DuplicatePath => {
            repo.resetStore();
            return .{ .rebuilt = "corrupt" };
        },
    };
    return .loaded;
}

pub fn save(repo: *fact_store.Repo, path: []const u8) !usize {
    const bytes = try encode(repo.gpa, repo);
    defer repo.gpa.free(bytes);
    if (std.fs.path.dirname(path)) |dir| try repo.fs.makePath(dir);
    var random: [8]u8 = undefined;
    repo.seam.entropy.fill(&random);
    const tag = std.fmt.bytesToHex(random, .lower);
    const temp = try std.fmt.allocPrint(repo.gpa, "{s}.emetgate-{s}.tmp", .{ path, &tag });
    defer repo.gpa.free(temp);
    try repo.fs.createFile(temp, bytes, .{ .durable = true });
    repo.fs.renameReplace(temp, path) catch |err| {
        repo.fs.deleteFile(temp) catch |cleanup| return cleanup;
        return err;
    };
    return bytes.len;
}
