const std = @import("std");
const module_paths = @import("module_paths.zig");
const facts_store = @import("../engine/facts_store.zig");
const io_seam = @import("io_seam.zig");

const Allocator = std.mem.Allocator;
const Store = facts_store.Store;
const SpecTarget = facts_store.SpecTarget;
const Value = std.json.Value;

pub const max_config_bytes = 1024 * 1024;
const max_extends_depth = 8;

const Rule = struct {
    pattern: []const u8,
    targets: []const []const u8,
};

const Config = struct {
    base: ?[]const u8 = null,
    paths_base: []const u8 = "",
    rules: []const Rule = &.{},
    out_dir: ?[]const u8 = null,
    root_dir: ?[]const u8 = null,
};

const OutMap = struct {
    out: []const u8,
    root: []const u8,
};

const Subpath = struct {
    key: []const u8,
    targets: []const []const u8,
};

const Package = struct {
    name: []const u8,
    dir: []const u8,
    entry: []const []const u8,
    subpaths: []const Subpath,
    out_maps: []const OutMap,
};

pub const Note = struct {
    path: []const u8,
    problem: []const u8,
};

pub const FoldedPath = struct {
    pub fn hash(_: FoldedPath, key: []const u8) u64 {
        var h = std.hash.Wyhash.init(0);
        var buf: [64]u8 = undefined;
        var at: usize = 0;
        while (at < key.len) {
            const n = @min(buf.len, key.len - at);
            for (key[at .. at + n], buf[0..n]) |c, *o| o.* = std.ascii.toLower(c);
            h.update(buf[0..n]);
            at += n;
        }
        return h.final();
    }

    pub fn eql(_: FoldedPath, a: []const u8, b: []const u8) bool {
        return std.ascii.eqlIgnoreCase(a, b);
    }
};

pub const TrackedMap = std.HashMapUnmanaged([]const u8, void, FoldedPath, std.hash_map.default_max_load_percentage);

const Tracked = struct {
    map: *const TrackedMap,

    pub fn has(self: Tracked, path: []const u8) bool {
        return self.map.contains(path);
    }
};

fn join(a: Allocator, base: []const u8, rel: []const u8) Allocator.Error!?[]const u8 {
    return joinNormalized(a, base, rel) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.OutsideRepo => return null,
    };
}

pub const Workspace = struct {
    arena_state: std.heap.ArenaAllocator,
    tracked: TrackedMap = .empty,
    packages: std.StringHashMapUnmanaged(Package) = .empty,
    configs: std.StringHashMapUnmanaged(Config) = .empty,
    raw_configs: std.StringHashMapUnmanaged(Value) = .empty,
    notes: std.ArrayList(Note) = .empty,
    resolve_scratch: std.heap.ArenaAllocator,
    signature: [16]u8 = std.mem.zeroes([16]u8),

    pub fn deinit(self: *Workspace) void {
        self.resolve_scratch.deinit();
        self.arena_state.deinit();
    }

    fn arena(self: *Workspace) Allocator {
        return self.arena_state.allocator();
    }

    pub fn build(gpa: Allocator, fs: io_seam.Fs, root_abs: []const u8, files: []const []const u8) !Workspace {
        var self: Workspace = .{ .arena_state = std.heap.ArenaAllocator.init(gpa), .resolve_scratch = std.heap.ArenaAllocator.init(gpa) };
        errdefer self.deinit();
        const a = self.arena();
        for (files) |rel| try self.tracked.put(a, try a.dupe(u8, rel), {});
        var hasher = std.crypto.hash.Blake3.init(.{});
        for (files) |rel| {
            const base = std.fs.path.basenamePosix(rel);
            if (!isConfigName(base)) continue;
            if (std.mem.indexOf(u8, rel, "node_modules/") != null) continue;
            const commented = !std.mem.eql(u8, base, "package.json");
            hasher.update(rel);
            hasher.update(&.{0});
            const parsed = (try self.readJson(gpa, fs, root_abs, rel, commented, &hasher)) orelse continue;
            try self.raw_configs.put(a, try a.dupe(u8, rel), parsed);
        }
        hasher.final(&self.signature);
        var raw = self.raw_configs.iterator();
        while (raw.next()) |entry| {
            if (std.mem.eql(u8, std.fs.path.basenamePosix(entry.key_ptr.*), "package.json")) try self.addPackage(entry.key_ptr.*, entry.value_ptr.*);
        }
        raw = self.raw_configs.iterator();
        while (raw.next()) |entry| {
            const rel = entry.key_ptr.*;
            const base = std.fs.path.basenamePosix(rel);
            if (!std.mem.eql(u8, base, "tsconfig.json") and !std.mem.eql(u8, base, "jsconfig.json")) continue;
            const dir = std.fs.path.dirnamePosix(rel) orelse "";
            if (self.configs.contains(dir)) continue;
            try self.configs.put(a, dir, try self.loadConfig(rel, 0));
        }
        try self.collectOutMaps();
        return self;
    }

    fn isConfigName(base: []const u8) bool {
        if (std.mem.eql(u8, base, "package.json")) return true;
        if (!std.mem.endsWith(u8, base, ".json")) return false;
        return std.mem.startsWith(u8, base, "tsconfig") or std.mem.startsWith(u8, base, "jsconfig");
    }

    fn readJson(self: *Workspace, gpa: Allocator, fs: io_seam.Fs, root_abs: []const u8, rel: []const u8, commented: bool, hasher: *std.crypto.hash.Blake3) !?Value {
        const a = self.arena();
        const abs = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ root_abs, rel });
        defer gpa.free(abs);
        const bytes = fs.readFile(abs, gpa, max_config_bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                hasher.update(@errorName(err));
                try self.notes.append(a, .{ .path = try a.dupe(u8, rel), .problem = @errorName(err) });
                return null;
            },
        };
        defer gpa.free(bytes);
        hasher.update(bytes);
        const text = if (commented) try stripJsonc(a, bytes) else bytes;
        return std.json.parseFromSliceLeaky(Value, a, text, .{ .allocate = .alloc_always }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try self.notes.append(a, .{ .path = try a.dupe(u8, rel), .problem = "invalid json" });
                return null;
            },
        };
    }

    fn addPackage(self: *Workspace, rel: []const u8, value: Value) !void {
        if (value != .object) return;
        const name = stringField(value, "name") orelse return;
        const a = self.arena();
        const dir = std.fs.path.dirnamePosix(rel) orelse "";
        var entry: std.ArrayList([]const u8) = .empty;
        var subpaths: std.ArrayList(Subpath) = .empty;
        if (value.object.get("exports")) |exports| try collectExports(a, exports, &entry, &subpaths);
        for ([_][]const u8{ "types", "typings", "module", "main" }) |field| {
            if (stringField(value, field)) |target| try entry.append(a, target);
        }
        try entry.append(a, "index");
        if (self.packages.contains(name)) {
            try self.notes.append(a, .{ .path = rel, .problem = "package name declared twice" });
            return;
        }
        try self.packages.put(a, name, .{ .name = name, .dir = dir, .entry = entry.items, .subpaths = subpaths.items, .out_maps = &.{} });
    }

    fn collectOutMaps(self: *Workspace) !void {
        const a = self.arena();
        var it = self.packages.valueIterator();
        while (it.next()) |pkg| {
            var maps: std.ArrayList(OutMap) = .empty;
            var raw = self.raw_configs.iterator();
            while (raw.next()) |entry| {
                const rel = entry.key_ptr.*;
                const dir = std.fs.path.dirnamePosix(rel) orelse "";
                if (!std.mem.eql(u8, dir, pkg.dir)) continue;
                if (std.mem.eql(u8, std.fs.path.basenamePosix(rel), "package.json")) continue;
                const config = try self.loadConfig(rel, 0);
                const out = config.out_dir orelse continue;
                const root = config.root_dir orelse continue;
                try maps.append(a, .{ .out = out, .root = root });
            }
            pkg.out_maps = maps.items;
        }
    }

    fn loadConfig(self: *Workspace, rel: []const u8, depth: usize) Allocator.Error!Config {
        const a = self.arena();
        var config: Config = .{};
        if (depth >= max_extends_depth) {
            try self.notes.append(a, .{ .path = rel, .problem = "extends chain too deep" });
            return config;
        }
        const value = self.raw_configs.get(rel) orelse return config;
        if (value != .object) return config;
        const dir = std.fs.path.dirnamePosix(rel) orelse "";
        if (value.object.get("extends")) |extends| {
            switch (extends) {
                .string => |text| config = try self.mergeExtended(config, dir, text, depth),
                .array => |list| for (list.items) |item| {
                    if (item == .string) config = try self.mergeExtended(config, dir, item.string, depth);
                },
                else => {},
            }
        }
        const options = value.object.get("compilerOptions") orelse return config;
        if (options != .object) return config;
        if (stringField(options, "baseUrl")) |base| {
            config.base = try join(a, dir, base);
            if (config.base) |b| config.paths_base = b;
        }
        if (options.object.get("paths")) |paths| {
            if (paths == .object) {
                var rules: std.ArrayList(Rule) = .empty;
                var it = paths.object.iterator();
                while (it.next()) |p| {
                    if (p.value_ptr.* != .array) continue;
                    var targets: std.ArrayList([]const u8) = .empty;
                    for (p.value_ptr.array.items) |t| if (t == .string) try targets.append(a, t.string);
                    try rules.append(a, .{ .pattern = p.key_ptr.*, .targets = targets.items });
                }
                config.rules = rules.items;
                config.paths_base = config.base orelse dir;
            }
        }
        if (stringField(options, "outDir")) |out| config.out_dir = try join(a, dir, out);
        if (stringField(options, "rootDir")) |root| config.root_dir = try join(a, dir, root);
        return config;
    }

    fn mergeExtended(self: *Workspace, current: Config, dir: []const u8, target: []const u8, depth: usize) Allocator.Error!Config {
        const a = self.arena();
        const rel = blk: {
            if (std.mem.startsWith(u8, target, "./") or std.mem.startsWith(u8, target, "../")) {
                const joined = (try join(a, dir, target)) orelse return current;
                break :blk if (std.mem.endsWith(u8, joined, ".json")) joined else try std.fmt.allocPrint(a, "{s}.json", .{joined});
            }
            const pkg = self.packageOf(target) orelse return current;
            const sub = if (target.len > pkg.name.len) target[pkg.name.len + 1 ..] else "tsconfig.json";
            break :blk (try join(a, pkg.dir, sub)) orelse return current;
        };
        if (!self.raw_configs.contains(rel)) return current;
        var merged = try self.loadConfig(rel, depth + 1);
        if (current.base) |b| merged.base = b;
        if (current.rules.len != 0) {
            merged.rules = current.rules;
            merged.paths_base = current.paths_base;
        }
        if (current.out_dir) |o| merged.out_dir = o;
        if (current.root_dir) |r| merged.root_dir = r;
        return merged;
    }

    fn packageOf(self: *const Workspace, spec: []const u8) ?Package {
        var end = spec.len;
        while (true) {
            if (self.packages.get(spec[0..end])) |pkg| return pkg;
            end = std.mem.lastIndexOfScalar(u8, spec[0..end], '/') orelse return null;
        }
    }

    fn configFor(self: *const Workspace, importer: []const u8) ?Config {
        var dir: []const u8 = std.fs.path.dirnamePosix(importer) orelse "";
        while (true) {
            if (self.configs.get(dir)) |config| return config;
            if (dir.len == 0) return null;
            dir = std.fs.path.dirnamePosix(dir) orelse "";
        }
    }

    fn found(self: *Workspace, store: *const Store, joined: []const u8) Allocator.Error!?SpecTarget {
        const scratch = self.resolve_scratch.allocator();
        const lookup: Tracked = .{ .map = &self.tracked };
        const hit = (try module_paths.resolveJoined(scratch, lookup, joined, '/')) orelse return null;
        const original = self.tracked.getKey(hit) orelse return null;
        const id = store.fileId(original) orelse return .unindexed;
        return switch (store.file(id).status) {
            .indexed => .{ .file = id },
            else => .unindexed,
        };
    }

    pub fn resolve(self: *Workspace, store: *const Store, importer: []const u8, spec: []const u8) Allocator.Error!SpecTarget {
        defer _ = self.resolve_scratch.reset(.retain_capacity);
        const scratch = self.resolve_scratch.allocator();
        if (module_paths.isRelative(spec)) {
            const dir = std.fs.path.dirnamePosix(importer) orelse "";
            const joined = (try join(scratch, dir, spec)) orelse return .external;
            return (try self.found(store, joined)) orelse .not_found;
        }
        if (spec.len == 0 or spec[0] == '/') return .not_found;
        if (self.configFor(importer)) |config| {
            for (config.rules) |rule| {
                const rest = matchPattern(rule.pattern, spec) orelse continue;
                for (rule.targets) |target| {
                    const substituted = try substitute(scratch, target, rest);
                    const joined = (try join(scratch, config.paths_base, substituted)) orelse continue;
                    if (try self.found(store, joined)) |t| return t;
                }
            }
            if (config.base) |base| {
                if (try join(scratch, base, spec)) |joined| {
                    if (try self.found(store, joined)) |t| return t;
                }
            }
        }
        const pkg = self.packageOf(spec) orelse return .external;
        const sub = if (spec.len > pkg.name.len) spec[pkg.name.len + 1 ..] else "";
        if (sub.len == 0) {
            for (pkg.entry) |target| if (try self.packageTarget(store, pkg, target)) |t| return t;
            return .not_found;
        }
        for (pkg.subpaths) |s| {
            const rest = matchPattern(s.key[@min(2, s.key.len)..], sub) orelse continue;
            for (s.targets) |target| {
                const substituted = try substitute(scratch, target, rest);
                if (try self.packageTarget(store, pkg, substituted)) |t| return t;
            }
        }
        if (try self.packageTarget(store, pkg, sub)) |t| return t;
        return .not_found;
    }

    fn packageTarget(self: *Workspace, store: *const Store, pkg: Package, target: []const u8) Allocator.Error!?SpecTarget {
        const scratch = self.resolve_scratch.allocator();
        const plain = (try join(scratch, pkg.dir, target)) orelse return null;
        if (try self.found(store, plain)) |t| return t;
        const stem = stripEmitted(plain);
        if (stem.len != plain.len) {
            if (try self.found(store, stem)) |t| return t;
        }
        for (pkg.out_maps) |map| {
            if (!underDir(stem, map.out)) continue;
            const mapped = try std.fmt.allocPrint(scratch, "{s}{s}", .{ map.root, stem[map.out.len..] });
            if (try self.found(store, mapped)) |t| return t;
        }
        return null;
    }

    pub fn resolver(self: *Workspace) facts_store.Resolver {
        return .{ .ctx = self, .resolveFn = resolveThunk };
    }

    fn resolveThunk(ctx: *anyopaque, store: *const Store, importer: facts_store.FileId, spec: []const u8) Allocator.Error!SpecTarget {
        const self: *Workspace = @ptrCast(@alignCast(ctx));
        return self.resolve(store, store.file(importer).path, spec);
    }
};

fn underDir(path: []const u8, dir: []const u8) bool {
    if (dir.len == 0) return true;
    if (path.len <= dir.len or !std.mem.startsWith(u8, path, dir)) return false;
    return path[dir.len] == '/';
}

fn stripEmitted(path: []const u8) []const u8 {
    for ([_][]const u8{ ".d.mts", ".d.cts", ".d.ts", ".mjs", ".cjs", ".js" }) |ext| {
        if (std.mem.endsWith(u8, path, ext)) return path[0 .. path.len - ext.len];
    }
    return path;
}

fn stringField(value: Value, name: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(name) orelse return null;
    return if (field == .string) field.string else null;
}

fn collectExports(a: Allocator, exports: Value, entry: *std.ArrayList([]const u8), subpaths: *std.ArrayList(Subpath)) !void {
    switch (exports) {
        .string => |text| try entry.append(a, text),
        .object => |object| {
            var keyed = false;
            var it = object.iterator();
            while (it.next()) |kv| {
                if (!std.mem.startsWith(u8, kv.key_ptr.*, ".")) continue;
                keyed = true;
                var targets: std.ArrayList([]const u8) = .empty;
                try conditionTargets(a, kv.value_ptr.*, &targets);
                if (std.mem.eql(u8, kv.key_ptr.*, ".")) {
                    try entry.appendSlice(a, targets.items);
                } else {
                    try subpaths.append(a, .{ .key = kv.key_ptr.*, .targets = targets.items });
                }
            }
            if (!keyed) try conditionTargets(a, exports, entry);
        },
        else => {},
    }
}

fn conditionTargets(a: Allocator, value: Value, out: *std.ArrayList([]const u8)) !void {
    switch (value) {
        .string => |text| try out.append(a, text),
        .array => |list| for (list.items) |item| try conditionTargets(a, item, out),
        .object => |object| {
            for ([_][]const u8{ "types", "import", "require", "node", "default" }) |condition| {
                if (object.get(condition)) |inner| try conditionTargets(a, inner, out);
            }
        },
        else => {},
    }
}

fn matchPattern(pattern: []const u8, spec: []const u8) ?[]const u8 {
    const star = std.mem.indexOfScalar(u8, pattern, '*') orelse {
        return if (std.mem.eql(u8, pattern, spec)) "" else null;
    };
    const prefix = pattern[0..star];
    const suffix = pattern[star + 1 ..];
    if (spec.len < prefix.len + suffix.len) return null;
    if (!std.mem.startsWith(u8, spec, prefix) or !std.mem.endsWith(u8, spec, suffix)) return null;
    return spec[prefix.len .. spec.len - suffix.len];
}

fn substitute(a: Allocator, target: []const u8, rest: []const u8) ![]const u8 {
    const star = std.mem.indexOfScalar(u8, target, '*') orelse return target;
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ target[0..star], rest, target[star + 1 ..] });
}

pub fn joinNormalized(a: Allocator, base: []const u8, rel: []const u8) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var base_it = std.mem.tokenizeAny(u8, base, "/\\");
    while (base_it.next()) |p| try parts.append(a, p);
    var rel_it = std.mem.tokenizeAny(u8, rel, "/\\");
    while (rel_it.next()) |p| {
        if (std.mem.eql(u8, p, ".")) continue;
        if (std.mem.eql(u8, p, "..")) {
            if (parts.items.len == 0) return error.OutsideRepo;
            _ = parts.pop();
            continue;
        }
        try parts.append(a, p);
    }
    return std.mem.join(a, "/", parts.items);
}

pub fn stripJsonc(a: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var in_string = false;
    while (i < text.len) {
        const c = text[i];
        if (in_string) {
            try out.append(a, c);
            if (c == '\\' and i + 1 < text.len) {
                try out.append(a, text[i + 1]);
                i += 2;
                continue;
            }
            if (c == '"') in_string = false;
            i += 1;
            continue;
        }
        if (c == '"') {
            in_string = true;
            try out.append(a, c);
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < text.len and text[i + 1] == '/') {
            while (i < text.len and text[i] != '\n') i += 1;
            continue;
        }
        if (c == '/' and i + 1 < text.len and text[i + 1] == '*') {
            i += 2;
            while (i + 1 < text.len and !(text[i] == '*' and text[i + 1] == '/')) i += 1;
            i += 2;
            continue;
        }
        if (c == ',') {
            var j = i + 1;
            while (j < text.len and std.ascii.isWhitespace(text[j])) j += 1;
            if (j < text.len and (text[j] == '}' or text[j] == ']')) {
                i += 1;
                continue;
            }
        }
        try out.append(a, c);
        i += 1;
    }
    return out.items;
}

const testing = std.testing;

test "fact modules: a tsconfig with comments and trailing commas reads as json" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text = try stripJsonc(arena.allocator(), "{\n // note\n \"a\": \"x//y\", /* block */ \"b\": [1, 2,],\n}\n");
    const parsed = try std.json.parseFromSliceLeaky(Value, arena.allocator(), text, .{});
    try testing.expectEqualStrings("x//y", parsed.object.get("a").?.string);
    try testing.expectEqual(@as(usize, 2), parsed.object.get("b").?.array.items.len);
}

test "fact modules: a path pattern captures the star and a joined path never climbs out of the repo" {
    try testing.expectEqualStrings("foo/bar", matchPattern("@/*", "@/foo/bar").?);
    try testing.expect(matchPattern("@/*", "lodash") == null);
    try testing.expectEqualStrings("", matchPattern("exact", "exact").?);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("packages/core/src/x", try joinNormalized(arena.allocator(), "packages/core", "./src/./x"));
    try testing.expectEqualStrings("packages/x", try joinNormalized(arena.allocator(), "packages/core/src", "../../x"));
    try testing.expectError(error.OutsideRepo, joinNormalized(arena.allocator(), "a", "../../x"));
    try testing.expectEqualStrings("src/index", stripEmitted("src/index.d.ts"));
}
