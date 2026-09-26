const std = @import("std");
const symbol = @import("../engine/symbol.zig");
const cas = @import("../engine/cas.zig");
const removal = @import("../engine/removal.zig");
const symmetry = @import("../engine/symmetry.zig");
const repo = @import("repo.zig");
const create = @import("create.zig");
const tsserver = @import("tsserver.zig");
const rename = @import("../engine/rename.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;
const Snapshot = @import("../engine/loader.zig").Snapshot;

const Allocator = std.mem.Allocator;

pub const Op = enum { write, delete };

pub const Edit = struct {
    file_abs: []const u8,
    ref_text: []const u8,
    expected_hash: symbol.Expected,
    new_body: []const u8 = "",
    op: Op = .write,
    move_source: ?[]const u8 = null,
};

pub const Action = enum { write, insert, create, delete_symbol, delete_file, move_file };

pub const Prepared = struct {
    rel: []u8,
    action: Action,
    base_hash: ?symbol.Hash,
    hash: symbol.Hash,
    snapshot: ?*Snapshot = null,
    body: symbol.Span = .{ .start = 0, .end = 0 },
    removed: ?symmetry.Local = null,
    source_rel: ?[]u8 = null,
    removed_span: symbol.Span = .{ .start = 0, .end = 0 },
    name_offset: ?u32 = null,

    pub fn deinit(self: Prepared, gpa: Allocator) void {
        if (self.source_rel) |s| gpa.free(s);
        if (self.snapshot) |s| s.destroy();
        gpa.free(self.rel);
    }

    pub fn source(self: Prepared) []const u8 {
        const s = self.snapshot orelse return "";
        return s.source;
    }

    pub fn addsCode(self: Prepared) bool {
        return switch (self.action) {
            .write, .insert, .create, .move_file => true,
            .delete_symbol, .delete_file => false,
        };
    }
};

pub fn plan(gpa: Allocator, io: std.Io, runtime: *Runtime, root: []const u8, edit: Edit, rel: []u8) !Prepared {
    return switch (edit.op) {
        .write => planWrite(gpa, io, runtime, root, edit, rel),
        .delete => if (edit.ref_text.len == 0) planFileDeletion(gpa, io, edit, rel) else planSymbolDeletion(gpa, io, runtime, edit, rel),
    };
}

fn planWrite(gpa: Allocator, io: std.Io, runtime: *Runtime, root: []const u8, edit: Edit, rel: []u8) !Prepared {
    const ref = try symbol.Ref.parse(gpa, edit.ref_text);
    defer ref.deinit(gpa);
    switch (edit.expected_hash) {
        .present => |expected| {
            const base = try Snapshot.load(runtime, io, .cwd(), edit.file_abs);
            defer base.destroy();
            if (base.tree.root().hasError()) return error.SourceHasErrors;
            const applied = try cas.apply(base, .{ .ref = ref, .expected_hash = expected, .new_body = edit.new_body });
            return .{ .rel = rel, .action = .write, .base_hash = symbol.hashOf(base.source), .hash = applied.hash, .snapshot = applied.snapshot, .body = applied.body };
        },
        .absent => {
            const p = try create.planAbsent(gpa, io, runtime, root, edit.file_abs, rel, ref, edit.new_body);
            return .{ .rel = rel, .action = if (p.base_hash == null) .create else .insert, .base_hash = p.base_hash, .hash = p.applied.hash, .snapshot = p.applied.snapshot, .body = p.applied.body };
        },
    }
}

fn planFileDeletion(gpa: Allocator, io: std.Io, edit: Edit, rel: []u8) !Prepared {
    try repo.refuseInternal(rel);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, edit.file_abs, gpa, .unlimited);
    defer gpa.free(bytes);
    const current = symbol.fileHash(bytes);
    const expected = switch (edit.expected_hash) {
        .present => |hash| hash,
        .absent => return error.MissingFileHash,
    };
    if (!std.mem.eql(u8, &expected, &current)) return error.HashMismatch;
    return .{ .rel = rel, .action = .delete_file, .base_hash = current, .hash = current };
}

fn planSymbolDeletion(gpa: Allocator, io: std.Io, runtime: *Runtime, edit: Edit, rel: []u8) !Prepared {
    const expected = switch (edit.expected_hash) {
        .present => |hash| hash,
        .absent => return error.MissingHash,
    };
    const ref = try symbol.Ref.parse(gpa, edit.ref_text);
    defer ref.deinit(gpa);
    const base = try Snapshot.load(runtime, io, .cwd(), edit.file_abs);
    defer base.destroy();
    if (base.tree.root().hasError()) return error.SourceHasErrors;
    const removed = try removal.remove(base, ref, expected);
    errdefer removed.snapshot.destroy();
    const declaration = (try (try base.symbols()).resolve(ref)).declaration;
    return .{
        .rel = rel,
        .action = .delete_symbol,
        .base_hash = symbol.hashOf(base.source),
        .hash = expected,
        .snapshot = removed.snapshot,
        .removed = symmetry.inspect(base, removed.cut),
        .removed_span = declaration,
        .name_offset = try nameOffset(gpa, base, ref.name, declaration),
    };
}

pub fn nameOffset(gpa: Allocator, snapshot: *const Snapshot, name: []const u8, declaration: symbol.Span) !?u32 {
    if (!rename.supports(snapshot.profile)) return null;
    const leaves = try rename.leavesNamed(gpa, snapshot, name);
    defer gpa.free(leaves);
    for (leaves) |leaf| {
        if (leaf.span.start >= declaration.start and leaf.span.start < declaration.end) return leaf.span.start;
    }
    return null;
}

pub fn checkDeletions(gpa: Allocator, io: std.Io, root: []const u8, prepared: []const Prepared, edits: []const Edit, session: ?*tsserver.Session) !void {
    const sources = try gpa.alloc(create.Source, prepared.len);
    defer gpa.free(sources);
    for (prepared, sources) |p, *slot| slot.* = .{ .rel = p.rel, .text = p.source() };
    for (prepared, edits[0..prepared.len], 0..) |p, edit, i| {
        const local = p.removed orelse continue;
        const ref = try symbol.Ref.parse(gpa, edit.ref_text);
        defer ref.deinit(gpa);
        if (!local.no_top_level_effect) return error.TopLevelEffect;
        if (try serviceSaysReferenced(gpa, io, root, session, sources, i, edit.file_abs, p, ref.name)) |referenced| {
            if (referenced) return error.SymbolReferenced;
            continue;
        }
        if (try create.mentionedAnywhere(gpa, io, root, sources, null, ref.name, null)) return error.SymbolReferenced;
        if (local.exported and try create.mentionedAnywhere(gpa, io, root, sources, i, create.moduleStem(p.rel), null)) return error.SymbolReferenced;
    }
}

fn serviceSaysReferenced(gpa: Allocator, io: std.Io, root: []const u8, session: ?*tsserver.Session, sources: []const create.Source, own: usize, file_abs: []const u8, p: Prepared, name: []const u8) !?bool {
    const s = session orelse return null;
    const offset = p.name_offset orelse return null;
    const client = s.get() catch |err| {
        s.last_error = err;
        return null;
    };
    const file = try gpa.dupe(u8, file_abs);
    defer gpa.free(file);
    std.mem.replaceScalar(u8, file, '\\', '/');
    const answer = client.references(file, offset) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            s.last_error = err;
            return null;
        },
    };
    defer answer.deinit();
    for (answer.value.references) |reference| {
        if (tsserver.sameFile(reference.file, file_abs)) {
            if (reference.start >= p.removed_span.start and reference.start < p.removed_span.end) continue;
            return true;
        }
        if (inBatch(root, sources, reference.file)) continue;
        return true;
    }
    for (sources, 0..) |source, i| {
        if (i == own) continue;
        if (symmetry.mentions(source.text, name, null)) return true;
    }
    if (try quotedAnywhere(gpa, io, root, name)) return true;
    return false;
}

fn inBatch(root: []const u8, sources: []const create.Source, file: []const u8) bool {
    for (sources) |source| {
        if (file.len != root.len + 1 + source.rel.len) continue;
        if (tsserver.sameFile(file[0..root.len], root) and tsserver.sameFile(file[root.len + 1 ..], source.rel)) return true;
    }
    return false;
}

pub fn quotedAnywhere(gpa: Allocator, io: std.Io, root: []const u8, name: []const u8) !bool {
    const listing = try repo.filesMentioning(gpa, io, root, name);
    defer gpa.free(listing);
    var files = std.mem.tokenizeScalar(u8, listing, 0);
    while (files.next()) |rel| {
        const path = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ root, rel });
        defer gpa.free(path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024)) catch continue;
        defer gpa.free(bytes);
        for ([_]u8{ '"', '\'', '`' }) |quote| {
            var from: usize = 0;
            while (std.mem.indexOfPos(u8, bytes, from, name)) |at| : (from = at + 1) {
                const end = at + name.len;
                if (at > 0 and end < bytes.len and bytes[at - 1] == quote and bytes[end] == quote) return true;
            }
        }
    }
    return false;
}
