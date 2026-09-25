const std = @import("std");
const symbol = @import("../engine/symbol.zig");
const cas = @import("../engine/cas.zig");
const symmetry = @import("../engine/symmetry.zig");
const repo = @import("repo.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;
const Snapshot = @import("../engine/loader.zig").Snapshot;
const registry = @import("../engine/lang/registry.zig");

const Allocator = std.mem.Allocator;

pub const Evidence = symmetry.Evidence;

pub fn prepareCreate(gpa: Allocator, io: std.Io, runtime: *Runtime, root: []const u8, file_abs: []const u8, rel: []const u8, ref: symbol.Ref, new_body: []const u8) !cas.Applied {
    const profile = registry.forPath(file_abs) orelse return error.UnsupportedLanguage;
    if (try repo.isIgnored(gpa, io, root, rel)) return error.IgnoredPath;
    return cas.create(runtime, profile, .{ .ref = ref, .new_body = new_body });
}

pub const Plan = struct {
    applied: cas.Applied,
    base_hash: ?symbol.Hash,
};

pub fn planAbsent(gpa: Allocator, io: std.Io, runtime: *Runtime, root: []const u8, file_abs: []const u8, rel: []const u8, ref: symbol.Ref, new_body: []const u8) !Plan {
    try repo.refuseInternal(rel);
    if (!try exists(io, file_abs)) return .{ .applied = try prepareCreate(gpa, io, runtime, root, file_abs, rel, ref, new_body), .base_hash = null };
    const base = try Snapshot.load(runtime, io, .cwd(), file_abs);
    defer base.destroy();
    if (base.tree.root().hasError()) return error.SourceHasErrors;
    return .{ .applied = try cas.insert(base, .{ .ref = ref, .new_body = new_body }), .base_hash = symbol.hashOf(base.source) };
}

fn exists(io: std.Io, path_abs: []const u8) !bool {
    std.Io.Dir.cwd().access(io, path_abs, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    return true;
}

pub const Source = struct {
    rel: []const u8,
    text: []const u8,
};

pub const Subject = struct {
    index: usize,
    snapshot: *const Snapshot,
    slot: symbol.Span,
    name: []const u8,
    creates: bool,
};

pub fn classify(gpa: Allocator, io: std.Io, root: []const u8, sources: []const Source, subject: Subject) !Evidence {
    const local = symmetry.inspect(subject.snapshot, subject.slot);
    const stem = moduleStem(sources[subject.index].rel);
    const observable = subject.creates or local.exported;
    return .{
        .parses = local.parses,
        .no_top_level_effect = local.no_top_level_effect,
        .unreferenced = !try mentionedAnywhere(gpa, io, root, sources, subject.index, subject.name, subject.slot),
        .module_unobserved = !observable or !try mentionedAnywhere(gpa, io, root, sources, subject.index, stem, null),
    };
}

fn moduleStem(rel: []const u8) []const u8 {
    const base = std.fs.path.basename(rel);
    const dot = std.mem.indexOfScalar(u8, base, '.') orelse return base;
    return base[0..dot];
}

fn mentionedAnywhere(gpa: Allocator, io: std.Io, root: []const u8, sources: []const Source, own: usize, word: []const u8, own_skip: ?symbol.Span) !bool {
    for (sources, 0..) |source, i| {
        const skip = if (i == own) own_skip else null;
        if (i == own and skip == null) continue;
        if (symmetry.mentions(source.text, word, skip)) return true;
    }
    const listing = try repo.filesMentioning(gpa, io, root, word);
    defer gpa.free(listing);
    var files = std.mem.tokenizeScalar(u8, listing, 0);
    while (files.next()) |file| {
        if (!inBatch(sources, file)) return true;
    }
    return false;
}

fn inBatch(sources: []const Source, git_path: []const u8) bool {
    for (sources) |source| {
        if (source.rel.len != git_path.len) continue;
        var same = true;
        for (source.rel, git_path) |a, b| {
            const x: u8 = if (a == '\\') '/' else std.ascii.toLower(a);
            const y: u8 = if (b == '\\') '/' else std.ascii.toLower(b);
            if (x != y) {
                same = false;
                break;
            }
        }
        if (same) return true;
    }
    return false;
}
