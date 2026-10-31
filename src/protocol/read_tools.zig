const std = @import("std");
const telemetry = @import("telemetry.zig");
const tool_result = @import("tool_result.zig");
const runner = @import("../platform/runner.zig");
const repo = @import("../platform/repo.zig");
const shadow = @import("../platform/shadow.zig");
const open_nowait = @import("../platform/open_nowait.zig");
const lang_registry = @import("../engine/lang/registry.zig");
const symbol = @import("../engine/symbol.zig");
const wire = @import("wire.zig");
const mirror_mod = @import("mirror.zig");
const line_range = @import("../engine/line_range.zig");
const json_pointer = @import("../engine/lang/json/pointer.zig");
const markdown_heading = @import("../engine/lang/markdown/heading.zig");
const ts = @import("../engine/tree_sitter.zig");
const outline = @import("outline.zig");
const read_cache = @import("read_cache.zig");
const raw_reply = @import("raw_reply.zig");
const tool_names = @import("../engine/tool_names.zig");
const tree_cache_mod = @import("../engine/tree_cache.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;
const Snapshot = @import("../engine/loader.zig").Snapshot;

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
const max_match_text = 200;

pub const refuseInternal = repo.refuseInternal;

pub fn utf8Prefix(bytes: []const u8, limit: usize) []const u8 {
    if (bytes.len <= limit) return bytes;
    var end = limit;
    while (end > 0 and (bytes[end] & 0xC0) == 0x80) end -= 1;
    return bytes[0..end];
}

const docnode = @import("../engine/docnode.zig");
const looksBinary = docnode.looksBinary;

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

pub const Source = struct {
    runtime: *Runtime,
    tree_cache: ?*tree_cache_mod.TreeCache,
};

pub const max_many_files = 32;
pub const max_many_bytes = 64 * 1024;
pub const section_head = "== ";
pub const not_sent_fix = std.fmt.comptimePrint("these did not fit in the {d} KiB reply of one call; read them in another emetgate_read_file call, a file still over the cap alone or by line_start/line_end", .{max_many_bytes / 1024});

pub const Options = struct {
    raw: bool = false,
    force: bool = false,
    pointer: ?[]const u8 = null,
    heading: ?[]const u8 = null,
    line_start: ?i64 = null,
    line_end: ?i64 = null,

    fn over(base: Options, value: Value) Options {
        return .{
            .raw = tool_result.getBool(value, "raw") orelse base.raw,
            .force = tool_result.getBool(value, "force") orelse base.force,
            .pointer = tool_result.getString(value, "pointer") orelse base.pointer,
            .heading = tool_result.getString(value, "heading") orelse base.heading,
            .line_start = tool_result.getInt(value, "line_start") orelse base.line_start,
            .line_end = tool_result.getInt(value, "line_end") orelse base.line_end,
        };
    }
};

const Wanted = struct {
    file: []const u8,
    options: Options,
};

pub fn callReadFile(gpa: Allocator, io: std.Io, args: ?Value, event: *telemetry.Event, root: ?[]const u8, mirror: ?*mirror_mod.Mirror, source: ?Source, raw_code: bool) !ToolResult {
    event.label = "read_file";
    if (args) |a| {
        if (tool_result.getField(a, "files")) |list| return callReadMany(gpa, io, a, list, event, root, mirror, source, raw_code);
    }
    const file = try requireString(args, "file");
    event.file = file;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    renderReadFile(gpa, io, root, file, Options.over(.{}, args.?), mirror, source, &buffer.writer, event) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err, event);
    };
    return success(gpa, &buffer);
}

fn wantedFiles(gpa: Allocator, args: Value, list: Value) ![]Wanted {
    const items = switch (list) {
        .array => |a| a.items,
        else => return tool_result.missing("files (array of paths or {{file,...}} objects)", .{}),
    };
    const base = Options.over(.{}, args);
    const single = getString(args, "file");
    const count = items.len + @intFromBool(single != null);
    if (count == 0) return tool_result.missing("files (non-empty array of paths or {{file,...}} objects)", .{});
    if (count > max_many_files) return tool_result.missing("files (at most {d} per call; split the list)", .{max_many_files});
    const wanted = try gpa.alloc(Wanted, count);
    errdefer gpa.free(wanted);
    var n: usize = 0;
    if (single) |f| {
        wanted[0] = .{ .file = f, .options = base };
        n = 1;
    }
    for (items, 0..) |item, i| {
        wanted[n] = switch (item) {
            .string => |f| .{ .file = f, .options = base },
            .object => .{ .file = getString(item, "file") orelse return tool_result.missing("files[{d}].file (string)", .{i}), .options = Options.over(base, item) },
            else => return tool_result.missing("files[{d}] (path string or {{file,...}} object)", .{i}),
        };
        n += 1;
    }
    return wanted;
}

fn callReadMany(gpa: Allocator, io: std.Io, args: Value, list: Value, event: *telemetry.Event, root: ?[]const u8, mirror: ?*mirror_mod.Mirror, source: ?Source, raw_code: bool) !ToolResult {
    const wanted = try wantedFiles(gpa, args, list);
    defer gpa.free(wanted);
    event.file = wanted[0].file;
    var journal: mirror_mod.Journal = .empty;
    defer journal.deinit(gpa);
    if (mirror) |m| m.journal = &journal;
    defer if (mirror) |m| {
        m.settle(&journal);
        m.journal = null;
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var not_sent: std.ArrayList([]const u8) = .empty;
    defer not_sent.deinit(gpa);
    var sent: usize = 0;
    var full: usize = 0;
    for (wanted) |want| {
        var one: telemetry.Event = .{ .tool = event.tool };
        var section: std.Io.Writer.Allocating = .init(gpa);
        defer section.deinit();
        var failed = false;
        renderReadFile(gpa, io, root, want.file, want.options, mirror, source, &section.writer, &one) catch |err| {
            if (err == error.OutOfMemory) return err;
            failed = true;
            section.clearRetainingCapacity();
            try wire.writeFailure(&section.writer, err, &one.trace.blocked);
        };
        const converted: ?[]u8 = if (raw_code and !failed) try raw_reply.convert(gpa, section.written()) else null;
        defer if (converted) |c| gpa.free(c);
        const text = converted orelse section.written();
        const size = section_head.len + want.file.len + 1 + text.len + 1;
        if (out.written().len + size > max_many_bytes) {
            if (mirror) |m| m.rollback(&journal);
            try not_sent.append(gpa, want.file);
            continue;
        }
        if (mirror) |m| {
            if (failed) m.rollback(&journal) else m.settle(&journal);
        }
        try out.writer.print("{s}{s}\n", .{ section_head, want.file });
        try out.writer.writeAll(text);
        if (text.len == 0 or text[text.len - 1] != '\n') try out.writer.writeByte('\n');
        sent += one.chars_emetgate orelse 0;
        full += one.chars_fullfile orelse 0;
    }
    if (not_sent.items.len != 0) {
        var js: std.json.Stringify = .{ .writer = &out.writer };
        try js.beginObject();
        try js.objectField("status");
        try js.write("partial");
        try js.objectField("not_sent");
        try js.write(not_sent.items);
        try js.objectField("fix");
        try tool_names.writeJson(&js, not_sent_fix);
        try js.endObject();
        try out.writer.writeByte('\n');
    }
    event.chars_emetgate = sent;
    event.chars_fullfile = full;
    return success(gpa, &out);
}

fn seenBefore(gpa: Allocator, mirror: ?*mirror_mod.Mirror, comptime fmt: []const u8, args: anytype, hash: symbol.Hash, file_hash: symbol.Hash, force: bool) !?u32 {
    const m = mirror orelse return null;
    const key = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(key);
    return m.seen(key, hash, file_hash, force);
}

fn renderReadFile(gpa: Allocator, io: std.Io, root: ?[]const u8, file: []const u8, options: Options, mirror: ?*mirror_mod.Mirror, source: ?Source, w: *Writer, event: *telemetry.Event) !void {
    const place = try repo.jail(gpa, io, root, file);
    defer place.deinit(gpa);
    const profile = lang_registry.forPath(file);
    const bytes = try open_nowait.readFileAlloc(gpa, place.abs, max_read_source_bytes);
    defer gpa.free(bytes);
    if (looksBinary(bytes)) return error.BinaryFile;
    const force = options.force;

    if (!options.raw and hasExtension(file, ".json")) {
        return renderJson(gpa, file, bytes, options.pointer, force, mirror, w, event);
    }
    if (!options.raw and hasExtension(file, ".md")) {
        return renderMarkdown(gpa, file, bytes, options.heading, force, mirror, w, event);
    }
    if (options.line_start != null or options.line_end != null) {
        return renderRange(gpa, file, bytes, options.line_start, options.line_end, force, mirror, w, event);
    }
    if (profile != null and bytes.len > outline.threshold) {
        if (source) |s| {
            if (try renderOutline(gpa, io, s, place.abs, file, bytes, force, mirror, w, event)) return;
        }
    }

    const shown = utf8Prefix(bytes, max_read_bytes);
    if (!std.unicode.utf8ValidateSlice(shown)) return error.NotUtf8;
    const file_hash = symbol.fileHash(bytes);
    const hash = symbol.hashOf(shown);
    event.chars_fullfile = bytes.len;
    if (try seenBefore(gpa, mirror, "file:{s}", .{file}, hash, file_hash, force)) |since| {
        event.chars_emetgate = 0;
        return wire.writeUnchangedSince(w, file, null, hash, file_hash, since);
    }
    if (shown.len == bytes.len) try read_cache.recordWhole(gpa, mirror, file, file_hash);
    event.chars_emetgate = shown.len;
    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("file");
    try js.write(file);
    try wire.writeFileHash(&js, file_hash);
    if (shown.len < bytes.len) {
        try js.objectField("bytes");
        try js.write(bytes.len);
        try js.objectField("truncated");
        try js.write(true);
    }
    try js.objectField("content");
    try js.write(shown);
    try js.endObject();
    try w.writeByte('\n');
}

fn renderOutline(gpa: Allocator, io: std.Io, source: Source, abs: []const u8, file: []const u8, bytes: []const u8, force: bool, mirror: ?*mirror_mod.Mirror, w: *Writer, event: *telemetry.Event) !bool {
    const snapshot = if (source.tree_cache) |cache| try cache.load(source.runtime, io, abs) else try Snapshot.load(source.runtime, io, .cwd(), abs);
    defer if (source.tree_cache == null) snapshot.destroy();
    const table = snapshot.symbols() catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.SourceHasErrors => return false,
    };
    const text = try outline.render(gpa, file, snapshot.source, table);
    defer gpa.free(text);
    event.chars_fullfile = bytes.len;
    const file_hash = symbol.fileHash(snapshot.source);
    const hash = symbol.hashOf(text);
    if (try seenBefore(gpa, mirror, "outline:{s}", .{file}, hash, file_hash, force)) |since| {
        event.chars_emetgate = 0;
        try wire.writeUnchangedSince(w, file, null, hash, file_hash, since);
        return true;
    }
    event.chars_emetgate = text.len;
    try w.writeAll(text);
    return true;
}

fn renderJson(gpa: Allocator, file: []const u8, bytes: []const u8, pointer: ?[]const u8, force: bool, mirror: ?*mirror_mod.Mirror, w: *Writer, event: *telemetry.Event) !void {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.NotUtf8;
    const parser = ts.Parser.create();
    defer parser.deinit();
    const tree = parser.parseIn(json_pointer.grammar(), bytes) catch return error.InvalidJson;
    defer tree.deinit();
    if (tree.root().hasError()) return error.InvalidJson;
    const file_hash = symbol.fileHash(bytes);
    event.chars_fullfile = bytes.len;

    if (pointer) |p| {
        const entry = try json_pointer.resolve(gpa, tree, p);
        defer gpa.free(entry.pointer);
        if (try seenBefore(gpa, mirror, "json:{s}#{s}", .{ file, p }, entry.hash, file_hash, force)) |since| {
            event.chars_emetgate = 0;
            return wire.writeUnchangedSince(w, file, p, entry.hash, file_hash, since);
        }
        const text = tree.text(entry.node);
        event.chars_emetgate = text.len;
        const hex = symbol.formatHash(entry.hash);
        var js: std.json.Stringify = .{ .writer = w };
        try js.beginObject();
        try js.objectField("file");
        try js.write(file);
        try wire.writeFileHash(&js, file_hash);
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

    const entries = try json_pointer.topLevel(gpa, tree);
    defer json_pointer.freeTopLevel(gpa, entries);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer };
    try js.beginObject();
    try js.objectField("file");
    try js.write(file);
    try wire.writeFileHash(&js, file_hash);
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
        if (entry.child_count) |count| {
            try js.objectField("children");
            try js.write(count);
        }
        try js.endObject();
    }
    try js.endArray();
    try js.endObject();
    return sendTree(gpa, file, "keys:{s}", out.written(), file_hash, force, mirror, w, event);
}

fn sendTree(gpa: Allocator, file: []const u8, comptime fmt: []const u8, text: []const u8, file_hash: symbol.Hash, force: bool, mirror: ?*mirror_mod.Mirror, w: *Writer, event: *telemetry.Event) !void {
    const hash = symbol.hashOf(text);
    if (try seenBefore(gpa, mirror, fmt, .{file}, hash, file_hash, force)) |since| {
        event.chars_emetgate = 0;
        return wire.writeUnchangedSince(w, file, null, hash, file_hash, since);
    }
    event.chars_emetgate = text.len;
    try w.writeAll(text);
    try w.writeByte('\n');
}

fn renderMarkdown(gpa: Allocator, file: []const u8, bytes: []const u8, heading: ?[]const u8, force: bool, mirror: ?*mirror_mod.Mirror, w: *Writer, event: *telemetry.Event) !void {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.NotUtf8;
    const parser = ts.Parser.create();
    defer parser.deinit();
    const tree = try parser.parseIn(markdown_heading.grammar(), bytes);
    defer tree.deinit();
    const file_hash = symbol.fileHash(bytes);
    event.chars_fullfile = bytes.len;

    if (heading) |h| {
        const entry = try markdown_heading.resolve(gpa, tree, h);
        if (try seenBefore(gpa, mirror, "heading:{s}#{s}", .{ file, h }, entry.hash, file_hash, force)) |since| {
            event.chars_emetgate = 0;
            return wire.writeUnchangedSince(w, file, h, entry.hash, file_hash, since);
        }
        const text = tree.text(entry.node);
        event.chars_emetgate = text.len;
        const hex = symbol.formatHash(entry.hash);
        var js: std.json.Stringify = .{ .writer = w };
        try js.beginObject();
        try js.objectField("file");
        try js.write(file);
        try wire.writeFileHash(&js, file_hash);
        try js.objectField("heading");
        try js.write(h);
        try js.objectField("hash");
        try js.write(hex[0..]);
        try js.objectField("section");
        try js.write(text);
        try js.endObject();
        try w.writeByte('\n');
        return;
    }

    const entries = try markdown_heading.headingTree(gpa, tree);
    defer gpa.free(entries);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer };
    try js.beginObject();
    try js.objectField("file");
    try js.write(file);
    try wire.writeFileHash(&js, file_hash);
    try js.objectField("headings");
    try js.beginArray();
    for (entries) |entry| {
        const hex = symbol.formatHash(entry.hash);
        try js.beginObject();
        try js.objectField("heading");
        try js.write(entry.heading);
        try js.objectField("level");
        try js.write(entry.level);
        try js.objectField("line");
        try js.write(entry.line);
        try js.objectField("hash");
        try js.write(hex[0..]);
        try js.endObject();
    }
    try js.endArray();
    try js.endObject();
    return sendTree(gpa, file, "headings:{s}", out.written(), file_hash, force, mirror, w, event);
}

pub fn renderRange(gpa: Allocator, file: []const u8, bytes: []const u8, line_start: ?i64, line_end: ?i64, force: bool, mirror: ?*mirror_mod.Mirror, w: *Writer, event: *telemetry.Event) !void {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.NotUtf8;
    const start = line_start orelse return error.MissingArgument;
    const end = line_end orelse return error.MissingArgument;
    if (start < 1 or end < 1) return error.InvalidLineRange;
    if (start > end) return error.InvalidLineRange;
    const last = lastLine(bytes);
    if (start > last) return error.LineOutOfRange;
    const shown_end = @min(end, last);
    const span = try line_range.byteRangeForLines(bytes, @intCast(start), @intCast(shown_end));
    const text = bytes[span.start..span.end];
    const hash = symbol.hashOf(text);
    const file_hash = symbol.fileHash(bytes);
    event.chars_fullfile = bytes.len;
    if (try read_cache.wholeSince(gpa, mirror, file, file_hash, force)) |since| {
        event.chars_emetgate = 0;
        return read_cache.writeCoveredSince(w, file, null, file_hash, since);
    }
    if (try seenBefore(gpa, mirror, "range:{s}:{d}-{d}", .{ file, start, end }, hash, file_hash, force)) |since| {
        event.chars_emetgate = 0;
        return wire.writeUnchangedSince(w, file, null, hash, file_hash, since);
    }
    event.chars_emetgate = text.len;
    const hex = symbol.formatHash(hash);
    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("file");
    try js.write(file);
    try wire.writeFileHash(&js, file_hash);
    try js.objectField("start_line");
    try js.write(start);
    try js.objectField("end_line");
    try js.write(shown_end);
    if (shown_end < end) {
        try js.objectField("status");
        try js.write("partial");
        try js.objectField("requested_end_line");
        try js.write(end);
        try js.objectField("note");
        var note_buf: [128]u8 = undefined;
        try js.write(try std.fmt.bufPrint(&note_buf, "the file ends at line {d}; lines {d}-{d} do not exist", .{ last, last + 1, end }));
    }
    try js.objectField("hash");
    try js.write(hex[0..]);
    try js.objectField("content");
    try js.write(text);
    try js.endObject();
    try w.writeByte('\n');
}

fn lastLine(bytes: []const u8) i64 {
    if (bytes.len == 0) return 0;
    const newlines: i64 = @intCast(std.mem.count(u8, bytes, "\n"));
    return if (bytes[bytes.len - 1] == '\n') newlines else newlines + 1;
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
    const files = try shadow.workingFiles(gpa, io, place.root);
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
    if (truncated) {
        try js.objectField("truncated");
        try js.write(true);
    }
    try js.endObject();
    try w.writeByte('\n');
}
