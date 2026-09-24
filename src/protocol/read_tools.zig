const std = @import("std");
const telemetry = @import("telemetry.zig");
const tool_result = @import("tool_result.zig");
const runner = @import("../platform/runner.zig");
const repo = @import("../platform/repo.zig");
const shadow = @import("../platform/shadow.zig");
const lang_registry = @import("../engine/lang/registry.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;
const ToolResult = tool_result.ToolResult;
const requireString = tool_result.requireString;
const getString = tool_result.getString;
const success = tool_result.success;
const failure = tool_result.failure;

const max_read_bytes = 16 * 1024;
const max_read_source_bytes = 64 * 1024 * 1024;
const max_list_entries = 2000;
const max_search_matches = 200;
const max_search_file_bytes = 1024 * 1024;
const max_match_text = 200;
const binary_probe_bytes = 8000;

pub const refuseInternal = repo.refuseInternal;

pub fn utf8Prefix(bytes: []const u8, limit: usize) []const u8 {
    if (bytes.len <= limit) return bytes;
    var end = limit;
    while (end > 0 and (bytes[end] & 0xC0) == 0x80) end -= 1;
    return bytes[0..end];
}

fn looksBinary(bytes: []const u8) bool {
    return std.mem.indexOfScalar(u8, bytes[0..@min(bytes.len, binary_probe_bytes)], 0) != null;
}

pub fn inDirectory(path: []const u8, prefix: []const u8) bool {
    if (prefix.len == 0) return true;
    if (path.len <= prefix.len) return false;
    for (prefix, path[0..prefix.len]) |a, b| {
        const na: u8 = if (a == '/') '\\' else std.ascii.toLower(a);
        const nb: u8 = if (b == '/') '\\' else std.ascii.toLower(b);
        if (na != nb) return false;
    }
    return path[prefix.len] == '/' or path[prefix.len] == '\\';
}

pub fn callReadFile(gpa: Allocator, io: std.Io, args: ?Value, event: *telemetry.Event, root: ?[]const u8) !ToolResult {
    const file = try requireString(args, "file");
    const raw = if (args) |a| tool_result.getBool(a, "raw") orelse false else false;
    event.label = "read_file";
    event.file = file;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    renderReadFile(gpa, io, root, file, raw, &buffer.writer, event) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err, event);
    };
    return success(gpa, &buffer);
}

fn renderReadFile(gpa: Allocator, io: std.Io, root: ?[]const u8, file: []const u8, raw: bool, w: *Writer, event: *telemetry.Event) !void {
    const place = try repo.jail(gpa, io, root, file);
    defer place.deinit(gpa);
    if (!raw and lang_registry.forPath(file) != null) return error.UseSymbolToolsForSource;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, place.abs, gpa, .limited(max_read_source_bytes));
    defer gpa.free(bytes);
    if (looksBinary(bytes)) return error.BinaryFile;
    const shown = utf8Prefix(bytes, max_read_bytes);
    if (!std.unicode.utf8ValidateSlice(shown)) return error.NotUtf8;
    event.chars_emetgate = shown.len;
    event.chars_fullfile = bytes.len;
    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("file");
    try js.write(file);
    try js.objectField("bytes");
    try js.write(bytes.len);
    try js.objectField("truncated");
    try js.write(shown.len < bytes.len);
    try js.objectField("content");
    try js.write(shown);
    try js.endObject();
    try w.writeByte('\n');
}

pub fn callList(gpa: Allocator, io: std.Io, args: ?Value, event: *telemetry.Event, root: ?[]const u8) !ToolResult {
    const dir = if (args) |a| getString(a, "dir") orelse "." else ".";
    event.label = "list";
    event.file = dir;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    renderList(gpa, io, root, dir, &buffer.writer) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err, event);
    };
    return success(gpa, &buffer);
}

fn renderList(gpa: Allocator, io: std.Io, root: ?[]const u8, dir: []const u8, w: *Writer) !void {
    const place = try repo.jail(gpa, io, root, dir);
    defer place.deinit(gpa);
    const files = try shadow.trackedFiles(gpa, io, place.root);
    defer gpa.free(files);
    defer shadow.freeFileList(gpa, files);

    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("dir");
    try js.write(dir);
    try js.objectField("files");
    try js.beginArray();
    var count: usize = 0;
    var truncated = false;
    for (files) |f| {
        if (!inDirectory(f, place.rel)) continue;
        if (count == max_list_entries) {
            truncated = true;
            break;
        }
        try js.write(f);
        count += 1;
    }
    try js.endArray();
    try js.objectField("truncated");
    try js.write(truncated);
    try js.endObject();
    try w.writeByte('\n');
}

pub fn callSearch(gpa: Allocator, io: std.Io, args: ?Value, event: *telemetry.Event, root: ?[]const u8) !ToolResult {
    const pattern = try requireString(args, "pattern");
    const dir = if (args) |a| getString(a, "dir") orelse "." else ".";
    event.label = "search";
    event.file = dir;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    renderSearch(gpa, io, root, pattern, dir, &buffer.writer) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err, event);
    };
    return success(gpa, &buffer);
}

pub const SearchLimits = struct {
    file_bytes: usize = max_search_file_bytes,
    matches: usize = max_search_matches,
};

fn renderSearch(gpa: Allocator, io: std.Io, root: ?[]const u8, pattern: []const u8, dir: []const u8, w: *Writer) !void {
    if (pattern.len == 0) return error.EmptyPattern;
    const place = try repo.jail(gpa, io, root, dir);
    defer place.deinit(gpa);
    try searchIn(gpa, io, place.root, place.rel, pattern, .{}, w);
}

pub fn searchIn(gpa: Allocator, io: std.Io, root: []const u8, prefix: []const u8, pattern: []const u8, limits: SearchLimits, w: *Writer) !void {
    const files = try shadow.trackedFiles(gpa, io, root);
    defer gpa.free(files);
    defer shadow.freeFileList(gpa, files);

    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("pattern");
    try js.write(pattern);
    try js.objectField("matches");
    try js.beginArray();
    var count: usize = 0;
    var truncated = false;
    outer: for (files) |f| {
        if (!inDirectory(f, prefix)) continue;
        const joined = try std.fmt.allocPrint(gpa, "{s}\\{s}", .{ root, f });
        defer gpa.free(joined);
        const real = std.Io.Dir.cwd().realPathFileAlloc(io, joined, gpa) catch continue;
        defer gpa.free(real);
        const rel = runner.relativeUnder(gpa, root, real) catch continue;
        defer gpa.free(rel);
        refuseInternal(rel) catch continue;
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, real, gpa, .limited(limits.file_bytes)) catch continue;
        defer gpa.free(bytes);
        if (looksBinary(bytes)) continue;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        var number: usize = 0;
        while (lines.next()) |raw| {
            number += 1;
            if (std.mem.indexOf(u8, raw, pattern) == null) continue;
            const text = utf8Prefix(std.mem.trim(u8, raw, " \t\r"), max_match_text);
            if (!std.unicode.utf8ValidateSlice(text)) continue;
            if (count == limits.matches) {
                truncated = true;
                break :outer;
            }
            try js.beginObject();
            try js.objectField("file");
            try js.write(f);
            try js.objectField("line");
            try js.write(number);
            try js.objectField("text");
            try js.write(text);
            try js.endObject();
            count += 1;
        }
    }
    try js.endArray();
    try js.objectField("truncated");
    try js.write(truncated);
    try js.endObject();
    try w.writeByte('\n');
}
