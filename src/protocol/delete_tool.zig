const std = @import("std");
const symbol = @import("../engine/symbol.zig");
const tool_names = @import("../engine/tool_names.zig");
const wire = @import("wire.zig");
const telemetry = @import("telemetry.zig");
const policy_mod = @import("policy.zig");
const tool_result = @import("tool_result.zig");
const repo = @import("../platform/repo.zig");
const handlers = @import("handlers.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Policy = policy_mod.Policy;
const ToolResult = tool_result.ToolResult;

pub const description = "Deletes files, gated and all or none; each leaves the git index too. files: [{file, file_hash}], or file and file_hash; a file this session wrote needs no file_hash. An empty folder is deleted, one with files refused.";

pub const files_missing = "files (array of {{file, file_hash}}) or file (string)";
pub const max_files = 256;
const max_known_bytes = 64 << 20;

const Request = struct { file: []const u8, hash: ?[]const u8 };

const Target = struct {
    file: []const u8,
    hash: ?[]const u8,
    abs: []const u8,
    rel: []const u8,
    folder: bool,
};

const Stop = struct { index: usize = 0, file: []const u8 = "", many: bool = false };

const Shape = enum { file, empty_folder, full_folder };

pub fn callDelete(gpa: Allocator, io: std.Io, runtime: *Runtime, args: ?Value, event: *telemetry.Event, policy: Policy) !ToolResult {
    const arguments = args orelse return tool_result.missing(files_missing, .{});
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const requests = try requested(arena, arguments);
    event.label = "delete";
    event.file = requests[0].file;
    event.mutating = true;
    var stop: Stop = .{};
    wire.clearFix();
    const targets = checked(gpa, arena, io, requests, policy, &stop) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return refusal(gpa, event, err, stop),
    };
    var files: usize = 0;
    for (targets) |target| files += @intFromBool(!target.folder);
    if (files == 0) return foldersOnly(gpa, arena, io, targets, event);
    const root = try repo.servedRoot(arena, io, policy.root);

    var edits = std.json.Array.init(arena);
    for (targets) |target| {
        if (target.folder) continue;
        var item: std.json.ObjectMap = .empty;
        try item.put(arena, "file", .{ .string = target.file });
        try item.put(arena, "hash", .{ .string = target.hash.? });
        try item.put(arena, "op", .{ .string = "delete" });
        try edits.append(.{ .object = item });
    }
    var batch: std.json.ObjectMap = .empty;
    try batch.put(arena, "edits", .{ .array = edits });
    if (tool_result.getField(arguments, "message")) |message| try batch.put(arena, "message", message);
    var unstaged = policy;
    unstaged.batch_stage = null;
    const reply = try handlers.callTryBatch(gpa, io, runtime, .{ .object = batch }, event, unstaged);
    if (reply.is_error) return reply;
    defer gpa.free(reply.text);
    var removed: std.ArrayList([]const u8) = .empty;
    var kept: std.ArrayList([]const u8) = .empty;
    for (targets) |target| {
        if (!target.folder) continue;
        std.Io.Dir.cwd().deleteDir(io, target.abs) catch {
            try kept.append(arena, target.file);
            continue;
        };
        try removed.append(arena, target.file);
    }
    const emptied = try removeEmptied(arena, io, root, targets, policy.session_dir);
    event.edits += removed.items.len;
    return .{ .text = try withFolders(gpa, arena, reply.text, removed.items, emptied, kept.items), .is_error = false };
}

fn requested(arena: Allocator, args: Value) ![]const Request {
    var out: std.ArrayList(Request) = .empty;
    if (tool_result.getField(args, "files")) |given| switch (given) {
        .array => |list| for (list.items, 0..) |item, i| try out.append(arena, try requestOf(item, i)),
        .null => {},
        else => return tool_result.missing(files_missing, .{}),
    };
    if (tool_result.getString(args, "file")) |file| {
        if (file.len == 0) return tool_result.missing("file (non-empty string)", .{});
        try out.append(arena, .{ .file = file, .hash = tool_result.getString(args, "file_hash") });
    }
    if (out.items.len == 0) return tool_result.missing(files_missing, .{});
    if (out.items.len > max_files) return tool_result.missing("files (at most {d} in one call)", .{max_files});
    return out.items;
}

fn requestOf(item: Value, index: usize) !Request {
    switch (item) {
        .string => |file| if (file.len != 0) return .{ .file = file, .hash = null },
        .object => if (tool_result.getString(item, "file")) |file| {
            if (file.len != 0) return .{ .file = file, .hash = tool_result.getString(item, "file_hash") };
        },
        else => {},
    }
    return tool_result.missing("files[{d}].file (non-empty string)", .{index});
}

fn checked(gpa: Allocator, arena: Allocator, io: std.Io, requests: []const Request, policy: Policy, stop: *Stop) ![]Target {
    const targets = try arena.alloc(Target, requests.len);
    for (requests, targets, 0..) |request, *target, i| {
        stop.* = .{ .index = i, .file = request.file, .many = requests.len > 1 };
        const place = try repo.jailTarget(gpa, io, policy.root, request.file, false);
        defer place.deinit(gpa);
        if (place.rel.len == 0) return error.InvalidPath;
        try repo.refuseLinkAsWritten(gpa, io, request.file);
        for (targets[0..i]) |earlier| {
            if (std.ascii.eqlIgnoreCase(earlier.abs, place.abs)) return error.DuplicateBatchFile;
        }
        const shape = try shapeOf(io, place.abs);
        if (shape == .full_folder) return error.IsDirectory;
        target.* = .{ .file = request.file, .hash = null, .abs = try arena.dupe(u8, place.abs), .rel = try arena.dupe(u8, place.rel), .folder = shape == .empty_folder };
        if (target.folder) continue;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, place.abs, arena, .unlimited);
        const current = symbol.fileHash(bytes);
        if (request.hash) |text| {
            const expected = switch (try symbol.parseExpected(text)) {
                .present => |hash| hash,
                .absent => return error.MissingFileHash,
            };
            if (!std.mem.eql(u8, &expected, &current)) return error.HashMismatch;
        } else if (!knownUnchanged(arena, policy, request.file, place.abs, current)) return error.MissingFileHash;
        const hex = symbol.formatHash(current);
        target.hash = try arena.dupe(u8, &hex);
    }
    return targets;
}

fn knownUnchanged(arena: Allocator, policy: Policy, file: []const u8, abs: []const u8, current: symbol.Hash) bool {
    const known = policy.known_files orelse return false;
    if (known.get(abs)) |hash| return std.mem.eql(u8, &hash, &current);
    const spelled = std.fs.path.resolve(arena, &.{ policy.root orelse ".", file }) catch return false;
    const hash = known.get(spelled) orelse return false;
    return std.mem.eql(u8, &hash, &current);
}

fn shapeOf(io: std.Io, abs: []const u8) !Shape {
    var dir = std.Io.Dir.cwd().openDir(io, abs, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.NotDir => return .file,
        else => |e| return e,
    };
    defer dir.close(io);
    var it = dir.iterate();
    return if (try it.next(io)) |_| .full_folder else .empty_folder;
}

fn refusal(gpa: Allocator, event: *telemetry.Event, err: anyerror, stop: Stop) !ToolResult {
    const prefix = tool_names.prefix();
    var field_buf: [48]u8 = undefined;
    const field = if (stop.many) std.fmt.bufPrint(&field_buf, "files[{d}].", .{stop.index}) catch "" else "";
    switch (err) {
        error.IsDirectory => wire.setFix("{s}emetgate_delete deletes a folder only when it is empty: list its files with {s}emetgate_list and send them as files; a folder its last file leaves empty is deleted with it", .{ prefix, prefix }),
        error.MissingFileHash => wire.setFix("send {s}file_hash: the file_hash {s}emetgate_read_file shows for it; only a file this session wrote, unchanged since, needs none", .{ field, prefix }),
        error.HashMismatch => wire.setFix("the file changed since that file_hash was read: read it again with {s}emetgate_read_file and send the file_hash it shows now if it should still be deleted", .{prefix}),
        error.FileNotFound => wire.setFix("nothing to delete: {s}emetgate_list shows what exists; if git status still lists the file as deleted because a command deleted it outside the gate, {s}emetgate_git_write args [\"rm\",\"--cached\",\"--\",\"{s}\"] takes it out of the index", .{ prefix, prefix, stop.file[0..@min(stop.file.len, 300)] }),
        error.DuplicateBatchFile => wire.setFix("name each file once in files", .{}),
        error.InvalidPath => wire.setFix("name a file or an empty folder inside the repository, relative to its root; the root itself cannot be deleted", .{}),
        else => {},
    }
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    var where_buf: [96]u8 = undefined;
    const where = if (stop.many) std.fmt.bufPrint(&where_buf, "files[{d}] ", .{stop.index}) catch "" else "";
    var message_buf: [768]u8 = undefined;
    const shown = stop.file[0..@min(stop.file.len, 400)];
    const message = std.fmt.bufPrint(&message_buf, "nothing was deleted: {s}{s} {s}", .{ where, shown, reasonOf(err) }) catch "nothing was deleted";
    return tool_result.failureMessage(gpa, &buffer, err, message, event);
}

fn reasonOf(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "does not exist",
        error.IsDirectory => "is a folder with files in it",
        error.MissingFileHash => "has no file_hash",
        error.HashMismatch => "does not have that file_hash now",
        error.InvalidHash => "has a file_hash that is not 32 hex characters",
        error.DuplicateBatchFile => "is named twice",
        error.InvalidPath => "is not a file or folder below the repository root",
        error.FileOutsideRepo, error.NotInRepo => "is outside the repository",
        error.InternalPath => "is inside .git or .emetgate",
        error.ReparsePoint => "is a junction or symbolic link",
        else => "cannot be deleted",
    };
}

fn foldersOnly(gpa: Allocator, arena: Allocator, io: std.Io, targets: []const Target, event: *telemetry.Event) !ToolResult {
    var removed: std.ArrayList([]const u8) = .empty;
    for (targets) |target| {
        std.Io.Dir.cwd().deleteDir(io, target.abs) catch |err| {
            var buffer: std.Io.Writer.Allocating = .init(gpa);
            defer buffer.deinit();
            const message = try std.fmt.allocPrint(arena, "{s} could not be deleted ({s}); deleted before it: {d} folders", .{ target.file, @errorName(err), removed.items.len });
            return tool_result.failureMessage(gpa, &buffer, err, message, event);
        };
        try removed.append(arena, target.file);
    }
    event.outcome = .committed;
    event.edits = removed.items.len;
    var out: std.Io.Writer.Allocating = .init(arena);
    var js: std.json.Stringify = .{ .writer = &out.writer };
    try js.beginObject();
    try js.objectField("status");
    try js.write(wire.written_status);
    try js.objectField("edits");
    try writeFolders(&js, removed.items);
    try js.endObject();
    return .{ .text = try gpa.dupe(u8, out.written()), .is_error = false };
}

fn writeFolders(js: *std.json.Stringify, folders: []const []const u8) !void {
    try js.beginArray();
    for (folders) |folder| {
        try js.beginObject();
        try js.objectField("file");
        try js.write(folder);
        try js.objectField("symbol");
        try js.write("");
        try js.objectField("deleted");
        try js.write(true);
        try js.objectField("folder");
        try js.write(true);
        try js.endObject();
    }
    try js.endArray();
}

fn removeEmptied(arena: Allocator, io: std.Io, root: []const u8, targets: []const Target, session: ?[]const u8) ![]const []const u8 {
    var emptied: std.ArrayList([]const u8) = .empty;
    for (targets) |target| {
        var dir = std.fs.path.dirname(target.abs) orelse continue;
        while (dir.len > root.len and std.ascii.startsWithIgnoreCase(dir, root) and (dir[root.len] == '\\' or dir[root.len] == '/')) {
            if (session) |cwd| if (std.ascii.startsWithIgnoreCase(cwd, dir)) break;
            std.Io.Dir.cwd().deleteDir(io, dir) catch break;
            const rel = try arena.dupe(u8, dir[root.len + 1 ..]);
            std.mem.replaceScalar(u8, rel, '\\', '/');
            try emptied.append(arena, rel);
            dir = std.fs.path.dirname(dir) orelse break;
        }
    }
    return emptied.items;
}

fn withFolders(gpa: Allocator, arena: Allocator, text: []const u8, removed: []const []const u8, emptied: []const []const u8, kept: []const []const u8) ![]u8 {
    if (removed.len == 0 and emptied.len == 0 and kept.len == 0) return gpa.dupe(u8, text);
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    var reply = std.json.parseFromSliceLeaky(Value, arena, text[0..end], .{}) catch return gpa.dupe(u8, text);
    if (reply != .object) return gpa.dupe(u8, text);
    if (reply.object.getPtr("edits")) |edits| if (edits.* == .array) for (removed) |folder| {
        var item: std.json.ObjectMap = .empty;
        try item.put(arena, "file", .{ .string = folder });
        try item.put(arena, "symbol", .{ .string = "" });
        try item.put(arena, "deleted", .{ .bool = true });
        try item.put(arena, "folder", .{ .bool = true });
        try edits.array.append(.{ .object = item });
    };
    if (emptied.len != 0) try reply.object.put(arena, "emptied_folders", try stringArray(arena, emptied));
    if (kept.len != 0) try reply.object.put(arena, "kept_folders", try stringArray(arena, kept));
    const line = try std.json.Stringify.valueAlloc(arena, reply, .{});
    return std.mem.concat(gpa, u8, &.{ line, text[end..] });
}

fn stringArray(arena: Allocator, items: []const []const u8) !Value {
    var list = std.json.Array.init(arena);
    for (items) |item| try list.append(.{ .string = item });
    return .{ .array = list };
}
