const std = @import("std");
const telemetry = @import("telemetry.zig");
const tool_result = @import("tool_result.zig");
const runner = @import("../platform/runner.zig");
const repo = @import("../platform/repo.zig");
const shadow = @import("../platform/shadow.zig");
const lang_registry = @import("../engine/lang/registry.zig");
const symbol = @import("../engine/symbol.zig");
const wire = @import("wire.zig");
const mirror_mod = @import("mirror.zig");
const line_range = @import("../engine/line_range.zig");
const json_pointer = @import("../engine/lang/json/pointer.zig");
const ts = @import("../engine/tree_sitter.zig");

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

fn hasExtension(file: []const u8, ext: []const u8) bool {
    if (file.len < ext.len) return false;
    return std.ascii.eqlIgnoreCase(file[file.len - ext.len ..], ext);
}

pub fn callReadFile(gpa: Allocator, io: std.Io, args: ?Value, event: *telemetry.Event, root: ?[]const u8, mirror: ?*mirror_mod.Mirror) !ToolResult {
    const file = try requireString(args, "file");
    const raw = if (args) |a| tool_result.getBool(a, "raw") orelse false else false;
    const force = if (args) |a| tool_result.getBool(a, "force") orelse false else false;
    const pointer = if (args) |a| tool_result.getString(a, "pointer") else null;
    const line_start = if (args) |a| tool_result.getInt(a, "line_start") else null;
    const line_end = if (args) |a| tool_result.getInt(a, "line_end") else null;
    event.label = "read_file";
    event.file = file;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    renderReadFile(gpa, io, root, file, raw, force, pointer, line_start, line_end, mirror, &buffer.writer, event) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err, event);
    };
    return success(gpa, &buffer);
}

fn renderReadFile(gpa: Allocator, io: std.Io, root: ?[]const u8, file: []const u8, raw: bool, force: bool, pointer: ?[]const u8, line_start: ?i64, line_end: ?i64, mirror: ?*mirror_mod.Mirror, w: *Writer, event: *telemetry.Event) !void {
    const place = try repo.jail(gpa, io, root, file);
    defer place.deinit(gpa);
    if (!raw and lang_registry.forPath(file) != null) return error.UseSymbolToolsForSource;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, place.abs, gpa, .limited(max_read_source_bytes));
    defer gpa.free(bytes);
    if (looksBinary(bytes)) return error.BinaryFile;

    if (!raw and hasExtension(file, ".json")) {
        return renderJson(gpa, file, bytes, pointer, force, mirror, w, event);
    }
    if (!raw and (line_start != null or line_end != null)) {
        return renderRange(gpa, file, bytes, line_start, line_end, force, mirror, w, event);
    }

    const shown = utf8Prefix(bytes, max_read_bytes);
    if (!std.unicode.utf8ValidateSlice(shown)) return error.NotUtf8;
    if (mirror) |m| {
        const hash = symbol.hashOf(shown);
        const key = try std.fmt.allocPrint(gpa, "file:{s}", .{file});
        defer gpa.free(key);
        if (try m.check(key, hash, force) == .unchanged) {
            event.chars_emetgate = 0;
            event.chars_fullfile = bytes.len;
            return wire.writeUnchanged(w, file, null, hash);
        }
    }
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

fn renderJson(gpa: Allocator, file: []const u8, bytes: []const u8, pointer: ?[]const u8, force: bool, mirror: ?*mirror_mod.Mirror, w: *Writer, event: *telemetry.Event) !void {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.NotUtf8;
    const parser = ts.Parser.create();
    defer parser.deinit();
    const tree = parser.parseIn(json_pointer.grammar(), bytes) catch return error.InvalidJson;
    defer tree.deinit();
    if (tree.root().hasError()) return error.InvalidJson;

    if (pointer) |p| {
        const entry = try json_pointer.resolve(gpa, tree, p);
        defer gpa.free(entry.pointer);
        if (mirror) |m| {
            const key = try std.fmt.allocPrint(gpa, "json:{s}#{s}", .{ file, p });
            defer gpa.free(key);
            if (try m.check(key, entry.hash, force) == .unchanged) {
                event.chars_emetgate = 0;
                event.chars_fullfile = bytes.len;
                return wire.writeUnchanged(w, file, p, entry.hash);
            }
        }
        const text = tree.text(entry.node);
        event.chars_emetgate = text.len;
        event.chars_fullfile = bytes.len;
        const hex = symbol.formatHash(entry.hash);
        var js: std.json.Stringify = .{ .writer = w };
        try js.beginObject();
        try js.objectField("file");
        try js.write(file);
        try js.objectField("pointer");
        try js.write(p);
        try js.objectField("hash");
        try js.write(hex[0..]);
        try js.objectField("value");
        try js.write(text);
        try js.endObject();
        try w.writeByte('\n');
        return;
    }

    const entries = try json_pointer.keyTree(gpa, tree);
    defer json_pointer.freeKeyTree(gpa, entries);
    event.chars_emetgate = bytes.len;
    event.chars_fullfile = bytes.len;
    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("file");
    try js.write(file);
    try js.objectField("keys");
    try js.beginArray();
    for (entries) |entry| {
        const hex = symbol.formatHash(entry.hash);
        try js.beginObject();
        try js.objectField("pointer");
        try js.write(entry.pointer);
        try js.objectField("type");
        try js.write(@tagName(entry.ty));
        try js.objectField("hash");
        try js.write(hex[0..]);
        try js.endObject();
    }
    try js.endArray();
    try js.endObject();
    try w.writeByte('\n');
}

fn renderRange(gpa: Allocator, file: []const u8, bytes: []const u8, line_start: ?i64, line_end: ?i64, force: bool, mirror: ?*mirror_mod.Mirror, w: *Writer, event: *telemetry.Event) !void {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.NotUtf8;
    const start = line_start orelse return error.MissingArgument;
    const end = line_end orelse return error.MissingArgument;
    if (start < 1 or end < 1) return error.InvalidLineRange;
    const span = try line_range.byteRangeForLines(bytes, @intCast(start), @intCast(end));
    const text = bytes[span.start..span.end];
    const hash = symbol.hashOf(text);
    if (mirror) |m| {
        const key = try std.fmt.allocPrint(gpa, "range:{s}:{d}-{d}", .{ file, start, end });
        defer gpa.free(key);
        if (try m.check(key, hash, force) == .unchanged) {
            event.chars_emetgate = 0;
            event.chars_fullfile = bytes.len;
            return wire.writeUnchanged(w, file, null, hash);
        }
    }
    event.chars_emetgate = text.len;
    event.chars_fullfile = bytes.len;
    const hex = symbol.formatHash(hash);
    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("file");
    try js.write(file);
    try js.objectField("start_line");
    try js.write(start);
    try js.objectField("end_line");
    try js.write(end);
    try js.objectField("hash");
    try js.write(hex[0..]);
    try js.objectField("content");
    try js.write(text);
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
