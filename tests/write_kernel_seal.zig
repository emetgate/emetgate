const std = @import("std");

const testing = std.testing;
const gpa = testing.allocator;

const Writer = struct {
    call: []const u8,
    allowed: []const []const u8,
};

const disk_writers = [_]Writer{
    .{ .call = "prepare", .allowed = &.{ "src/platform/batch.zig", "src/platform/commit_intent.zig" } },
    .{ .call = "stageCreate", .allowed = &.{ "src/platform/batch.zig", "src/platform/commit_intent.zig" } },
    .{ .call = "stageDelete", .allowed = &.{ "src/platform/batch.zig", "src/platform/commit_intent.zig" } },
    .{ .call = "stageRename", .allowed = &.{ "src/platform/batch.zig", "src/platform/commit_intent.zig" } },
    .{ .call = "create", .allowed = &.{"src/platform/commit_intent.zig"} },
    .{ .call = "commitBatch", .allowed = &.{ "src/platform/commit_plan.zig", "src/platform/commit_intent.zig" } },
    .{ .call = "replaceAtomically", .allowed = &.{} },
    .{ .call = "replaceReporting", .allowed = &.{} },
};

const land_allowed = [_][]const u8{ "src/platform/batch.zig", "src/platform/commit_group.zig" };

const Found = struct { file: []const u8, call: []const u8 };

fn allowedIn(file: []const u8, allowed: []const []const u8) bool {
    for (allowed) |path| if (std.mem.eql(u8, file, path)) return true;
    return false;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn diskAliases(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const at = std.mem.indexOf(u8, line, "@import(\"") orelse continue;
        const rest = line[at + "@import(\"".len ..];
        const close = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
        const path = rest[0..close];
        if (!std.mem.eql(u8, std.fs.path.basenamePosix(path), "disk.zig")) continue;
        const decl = std.mem.indexOf(u8, line[0..at], "const ") orelse return error.DiskImportedWithoutAName;
        const name_start = decl + "const ".len;
        var name_end = name_start;
        while (name_end < line.len and isIdentChar(line[name_end])) name_end += 1;
        if (name_end == name_start) return error.DiskImportedWithoutAName;
        try names.append(arena, line[name_start..name_end]);
    }
    return names.items;
}

fn callsOf(text: []const u8, receiver: []const u8, call: []const u8) bool {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, text, at, call)) |hit| : (at = hit + call.len) {
        const after = hit + call.len;
        if (after >= text.len or text[after] != '(') continue;
        if (hit == 0 or text[hit - 1] != '.') continue;
        const end = hit - 1;
        var start = end;
        while (start > 0 and isIdentChar(text[start - 1])) start -= 1;
        if (std.mem.eql(u8, text[start..end], receiver)) return true;
    }
    return false;
}

fn landsOutsideTheKernel(text: []const u8) bool {
    return std.mem.indexOf(u8, text, ".land(gpa") != null;
}

fn scan(arena: std.mem.Allocator, found: *std.ArrayList(Found)) !usize {
    var src = try std.Io.Dir.cwd().openDir(testing.io, "src", .{ .iterate = true });
    defer src.close(testing.io);
    var walker = try src.walk(arena);
    defer walker.deinit();
    var files: usize = 0;
    while (try walker.next(testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const rel = try std.mem.concat(arena, u8, &.{ "src/", entry.path });
        std.mem.replaceScalar(u8, rel, '\\', '/');
        if (std.mem.eql(u8, rel, "src/platform/disk.zig")) continue;
        const text = try src.readFileAlloc(testing.io, entry.path, arena, .limited(16 * 1024 * 1024));
        files += 1;
        for (try diskAliases(arena, text)) |alias| {
            for (disk_writers) |writer| {
                if (allowedIn(rel, writer.allowed)) continue;
                if (callsOf(text, alias, writer.call)) try found.append(arena, .{ .file = rel, .call = writer.call });
            }
        }
        if (!allowedIn(rel, &land_allowed) and !std.mem.eql(u8, rel, "src/platform/commit_plan.zig") and landsOutsideTheKernel(text)) {
            try found.append(arena, .{ .file = rel, .call = "land" });
        }
    }
    return files;
}

test "write kernel seal: only the kernel and crash recovery write the working tree" {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var found: std.ArrayList(Found) = .empty;
    const files = try scan(arena, &found);
    try testing.expect(files > 100);
    for (found.items) |f| std.debug.print("{s} calls {s}, which writes the working tree outside the gate kernel (src/platform/batch.zig)\n", .{ f.file, f.call });
    try testing.expectEqual(@as(usize, 0), found.items.len);
}

test "write kernel seal: a call is found through any name the file gives disk.zig" {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text =
        \\const store = @import("../platform/disk.zig");
        \\fn bypass() !void {
        \\    var p = try store.prepare(gpa, io, path, bytes, base);
        \\    _ = &p;
        \\}
    ;
    const aliases = try diskAliases(arena, text);
    try testing.expectEqual(@as(usize, 1), aliases.len);
    try testing.expectEqualStrings("store", aliases[0]);
    try testing.expect(callsOf(text, "store", "prepare"));
    try testing.expect(!callsOf(text, "store", "create"));
    try testing.expect(!callsOf("other.prepare(x)", "store", "prepare"));
    try testing.expect(!callsOf("store.prepared(x)", "store", "prepare"));
    try testing.expect(!callsOf("restore.prepare(x)", "store", "prepare"));
    try testing.expect(landsOutsideTheKernel("try session.land(gpa, io, root, changes, pendings, null, null);"));
}

test "write kernel seal: disk.zig used without a name is refused, so no call can hide from the scan" {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    try testing.expectError(error.DiskImportedWithoutAName, diskAliases(arena_state.allocator(), "    try @import(\"disk.zig\").prepare(gpa, io, p, b, h);"));
}
