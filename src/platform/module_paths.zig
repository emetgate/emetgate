const std = @import("std");
const modules = @import("../engine/modules.zig");
const registry = @import("../engine/lang/registry.zig");
const tsserver = @import("tsserver.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;
const Snapshot = @import("../engine/loader.zig").Snapshot;

const Allocator = std.mem.Allocator;

const source_extensions = [_][]const u8{ ".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs" };
const emitted = [_]struct { from: []const u8, to: []const []const u8 }{
    .{ .from = ".js", .to = &.{ ".ts", ".tsx" } },
    .{ .from = ".jsx", .to = &.{".tsx"} },
    .{ .from = ".mjs", .to = &.{".mts"} },
    .{ .from = ".cjs", .to = &.{".cts"} },
};

pub fn isRelative(spec: []const u8) bool {
    return std.mem.startsWith(u8, spec, "./") or std.mem.startsWith(u8, spec, "../") or std.mem.eql(u8, spec, ".") or std.mem.eql(u8, spec, "..");
}

pub fn specExtension(spec: []const u8) ?[]const u8 {
    for (source_extensions) |ext| {
        if (std.mem.endsWith(u8, spec, ext)) return ext;
    }
    return null;
}

fn stem(path: []const u8) []const u8 {
    for (source_extensions) |ext| {
        if (std.ascii.endsWithIgnoreCase(path, ext)) return path[0 .. path.len - ext.len];
    }
    return path;
}

pub const Existing = struct {
    io: std.Io,
    virtual: []const []const u8 = &.{},
    removed: []const []const u8 = &.{},

    fn has(self: Existing, path: []const u8) bool {
        for (self.removed) |r| if (tsserver.sameFile(r, path)) return false;
        for (self.virtual) |v| if (tsserver.sameFile(v, path)) return true;
        std.Io.Dir.cwd().access(self.io, path, .{}) catch return false;
        const profile = registry.forPath(path);
        return profile != null;
    }
};

pub fn resolveSpec(gpa: Allocator, existing: Existing, importer_abs: []const u8, spec: []const u8) !?[]u8 {
    if (!isRelative(spec)) return null;
    const dir = std.fs.path.dirname(importer_abs) orelse return null;
    const joined = try std.fs.path.resolve(gpa, &.{ dir, spec });
    defer gpa.free(joined);
    std.mem.replaceScalar(u8, joined, '/', '\\');
    if (existing.has(joined)) return try gpa.dupe(u8, joined);
    if (specExtension(joined)) |ext| {
        for (emitted) |e| {
            if (!std.mem.eql(u8, e.from, ext)) continue;
            for (e.to) |to| {
                const candidate = try std.fmt.allocPrint(gpa, "{s}{s}", .{ joined[0 .. joined.len - ext.len], to });
                if (existing.has(candidate)) return candidate;
                gpa.free(candidate);
            }
        }
        return null;
    }
    for (source_extensions) |ext| {
        const candidate = try std.fmt.allocPrint(gpa, "{s}{s}", .{ joined, ext });
        if (existing.has(candidate)) return candidate;
        gpa.free(candidate);
    }
    for (source_extensions) |ext| {
        const candidate = try std.fmt.allocPrint(gpa, "{s}\\index{s}", .{ joined, ext });
        if (existing.has(candidate)) return candidate;
        gpa.free(candidate);
    }
    return null;
}

pub fn relativeSpec(gpa: Allocator, from_abs: []const u8, to_abs: []const u8, extension: ?[]const u8) ![]u8 {
    const from_dir = std.fs.path.dirname(from_abs) orelse return error.InvalidPath;
    const rel = try std.fs.path.relative(gpa, from_dir, null, from_dir, to_abs);
    defer gpa.free(rel);
    std.mem.replaceScalar(u8, rel, '\\', '/');
    const base = stem(rel);
    const prefix: []const u8 = if (std.mem.startsWith(u8, base, "../")) "" else "./";
    return std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ prefix, base, extension orelse "" });
}

pub fn emittedExtension(spec_ext: ?[]const u8, target_abs: []const u8) ?[]const u8 {
    const ext = spec_ext orelse return null;
    for (emitted) |e| {
        if (!std.mem.eql(u8, e.from, ext)) continue;
        for (e.to) |to| if (std.ascii.endsWithIgnoreCase(target_abs, to)) return e.from;
    }
    for (source_extensions) |own| if (std.ascii.endsWithIgnoreCase(target_abs, own)) return own;
    return ext;
}

pub const Override = struct {
    abs: []const u8,
    source: []const u8,
};

pub fn reaches(gpa: Allocator, runtime: *Runtime, existing: Existing, start: []const u8, goal: []const u8, overrides: []const Override) !bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var queue: std.ArrayList([]const u8) = .empty;
    var seen: std.ArrayList([]const u8) = .empty;
    try queue.append(arena, start);
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const file = queue.items[head];
        for (try importsOf(arena, runtime, existing, file, overrides)) |next| {
            if (tsserver.sameFile(next, goal)) return true;
            var known = false;
            for (seen.items) |s| {
                if (tsserver.sameFile(s, next)) known = true;
            }
            if (known) continue;
            try seen.append(arena, next);
            try queue.append(arena, next);
        }
    }
    return false;
}

fn importsOf(arena: Allocator, runtime: *Runtime, existing: Existing, file: []const u8, overrides: []const Override) ![]const []const u8 {
    const profile = registry.forPath(file) orelse return &.{};
    if (profile.modules == null) return &.{};
    var text: ?[]const u8 = null;
    for (overrides) |o| {
        if (tsserver.sameFile(o.abs, file)) text = o.source;
    }
    const source = text orelse (std.Io.Dir.cwd().readFileAlloc(existing.io, file, arena, .limited(64 * 1024 * 1024)) catch return &.{});
    const snapshot = try Snapshot.fromSource(runtime, profile, try runtime.gpa.dupe(u8, source));
    defer snapshot.destroy();
    var out: std.ArrayList([]const u8) = .empty;
    for (try modules.imports(arena, snapshot)) |entry| {
        if (entry.type_only) continue;
        const resolved = (try resolveSpec(arena, existing, file, entry.spec)) orelse continue;
        try out.append(arena, resolved);
    }
    return out.items;
}

pub fn declaredSideEffects(gpa: Allocator, io: std.Io, root: []const u8, file_abs: []const u8) !bool {
    var dir: []const u8 = std.fs.path.dirname(file_abs) orelse return false;
    while (dir.len >= root.len) {
        const manifest = try std.fmt.allocPrint(gpa, "{s}\\package.json", .{dir});
        defer gpa.free(manifest);
        if (std.Io.Dir.cwd().readFileAlloc(io, manifest, gpa, .limited(4 * 1024 * 1024))) |bytes| {
            defer gpa.free(bytes);
            return sideEffectsFor(gpa, bytes, dir, file_abs);
        } else |_| {}
        dir = std.fs.path.dirname(dir) orelse break;
    }
    return false;
}

fn sideEffectsFor(gpa: Allocator, bytes: []const u8, package_dir: []const u8, file_abs: []const u8) !bool {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return true;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const field = parsed.value.object.get("sideEffects") orelse return false;
    switch (field) {
        .bool => |b| return b,
        .array => |list| {
            const rel = std.fs.path.relative(gpa, package_dir, null, package_dir, file_abs) catch return true;
            defer gpa.free(rel);
            std.mem.replaceScalar(u8, rel, '\\', '/');
            for (list.items) |item| {
                if (item != .string) return true;
                if (globMatch(std.mem.trimStart(u8, item.string, "./"), rel)) return true;
                if (std.mem.indexOfScalar(u8, item.string, '/') == null and globMatch(item.string, std.fs.path.basename(rel))) return true;
            }
            return false;
        },
        else => return true,
    }
}

pub fn globMatch(pattern: []const u8, text: []const u8) bool {
    if (pattern.len == 0) return text.len == 0;
    if (std.mem.startsWith(u8, pattern, "**")) {
        const rest = std.mem.trimStart(u8, pattern[2..], "/");
        var i: usize = 0;
        while (i <= text.len) : (i += 1) {
            if (globMatch(rest, text[i..])) return true;
        }
        return false;
    }
    if (pattern[0] == '*') {
        var i: usize = 0;
        while (i <= text.len) : (i += 1) {
            if (globMatch(pattern[1..], text[i..])) return true;
            if (i < text.len and text[i] == '/') return false;
        }
        return false;
    }
    if (text.len == 0 or pattern[0] != text[0]) return false;
    return globMatch(pattern[1..], text[1..]);
}

const testing = std.testing;

test "module paths: a relative spec is written from the importer's directory with the importer's extension style" {
    const a = try relativeSpec(testing.allocator, "C:\\r\\src\\a.ts", "C:\\r\\src\\lib\\b.ts", null);
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("./lib/b", a);
    const b = try relativeSpec(testing.allocator, "C:\\r\\src\\lib\\b.ts", "C:\\r\\src\\a.ts", ".js");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("../a.js", b);
    try testing.expectEqualStrings(".js", emittedExtension(".js", "C:\\r\\x.ts").?);
    try testing.expectEqual(@as(?[]const u8, null), emittedExtension(null, "C:\\r\\x.ts"));
}

test "module paths: sideEffects globs match a file by path or by name" {
    try testing.expect(globMatch("src/*.ts", "src/a.ts"));
    try testing.expect(!globMatch("src/*.ts", "src/x/a.ts"));
    try testing.expect(globMatch("**/*.css", "src/x/a.css"));
    try testing.expect(globMatch("src/polyfill.ts", "src/polyfill.ts"));
    try testing.expect(try sideEffectsFor(testing.allocator, "{\"sideEffects\":[\"./src/setup.ts\"]}", "C:\\r", "C:\\r\\src\\setup.ts"));
    try testing.expect(!try sideEffectsFor(testing.allocator, "{\"sideEffects\":[\"./src/setup.ts\"]}", "C:\\r", "C:\\r\\src\\a.ts"));
    try testing.expect(!try sideEffectsFor(testing.allocator, "{\"sideEffects\":false}", "C:\\r", "C:\\r\\src\\a.ts"));
    try testing.expect(try sideEffectsFor(testing.allocator, "{\"sideEffects\":true}", "C:\\r", "C:\\r\\src\\a.ts"));
    try testing.expect(!try sideEffectsFor(testing.allocator, "{\"name\":\"x\"}", "C:\\r", "C:\\r\\src\\a.ts"));
}
