const std = @import("std");
const display_path = @import("../platform/display_path.zig");
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
const sent_ledger = @import("../engine/sent_ledger.zig");
const Runtime = @import("../engine/runtime.zig").Runtime;
const Snapshot = @import("../engine/loader.zig").Snapshot;
const reply_contract = @import("reply_contract.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;
const ToolResult = tool_result.ToolResult;
const requireString = tool_result.requireString;
const getString = tool_result.getString;
const success = tool_result.success;
const failure = tool_result.failure;

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
    sent_ledger: ?*sent_ledger.Ledger = null,
};

/// Where a render notes the file bytes it put in a reply: the session's sent
/// ledger, under the repo-relative path. A null ledger notes nothing.
pub const Note = struct {
    ledger: ?*sent_ledger.Ledger = null,
    rel: []const u8 = "",

    pub fn shown(self: Note, bytes: []const u8, start: usize, end: usize, form: sent_ledger.Form) Allocator.Error!void {
        const ledger = self.ledger orelse return;
        try ledger.recordBytes(self.rel, bytes, .{ .start = @intCast(start), .end = @intCast(end) }, form);
    }
};

pub const max_many_files = 32;
pub const max_many_bytes = reply_contract.budget(.read_file_many);
pub const section_head = "== ";
pub const not_sent_fix = std.fmt.comptimePrint("these did not fit in the {d} KiB reply of one call; read them in another emetgate_read_file call, a file still over the cap alone or by line_start/line_end", .{max_many_bytes / 1024});

pub const Options = struct {
    raw: bool = false,
    force: bool = false,
    pointer: ?[]const u8 = null,
    heading: ?[]const u8 = null,
    line_start: ?i64 = null,
    line_end: ?i64 = null,
    /// Where a cut view resumes, copied from the trailer of the reply that cut
    /// it: a byte offset into line_start's line, into a pointer's value or a
    /// heading's section, or the first row of a key, heading or outline tree.
    offset: ?i64 = null,

    fn over(base: Options, value: Value) Options {
        const pointer = tool_result.getString(value, "pointer");
        const heading = tool_result.getString(value, "heading");
        const line_start = tool_result.getInt(value, "line_start");
        const line_end = tool_result.getInt(value, "line_end");
        // A range wins over heading and pointer only when it was asked for this
        // entry: an entry naming its own heading or pointer drops an inherited range.
        const own_selector = (pointer != null or heading != null) and line_start == null and line_end == null;
        return .{
            .raw = tool_result.getBool(value, "raw") orelse base.raw,
            .force = tool_result.getBool(value, "force") orelse base.force,
            .pointer = pointer orelse base.pointer,
            .heading = heading orelse base.heading,
            .line_start = line_start orelse if (own_selector) null else base.line_start,
            .line_end = line_end orelse if (own_selector) null else base.line_end,
            .offset = tool_result.getInt(value, "offset") orelse base.offset,
        };
    }
};

const Wanted = struct {
    file: []const u8,
    options: Options,
    /// The entry as given in files, or a string of the top-level file.
    item: Value,
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
        wanted[0] = .{ .file = f, .options = base, .item = .{ .string = f } };
        n = 1;
    }
    for (items, 0..) |item, i| {
        wanted[n] = switch (item) {
            .string => |f| .{ .file = f, .options = base, .item = item },
            .object => .{ .file = getString(item, "file") orelse return tool_result.missing("files[{d}].file (string)", .{i}), .options = Options.over(base, item), .item = item },
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
    var not_sent_items: std.ArrayList(Value) = .empty;
    defer not_sent_items.deinit(gpa);
    var sent: usize = 0;
    var full: usize = 0;
    // The tail that names files left out repeats each name three times (the
    // not_sent list, the trailer's text and its call), escaped. Before a file
    // is placed, room is kept for the tail of every file that could still be
    // left out: those already left out and those after it.
    var pending_cost: usize = 0;
    for (wanted) |want| pending_cost += tailCost(want.file);
    for (wanted) |want| {
        pending_cost -= tailCost(want.file);
        const tail_room = if (pending_cost == 0) 0 else 700 + not_sent_fix.len + pending_cost;
        const cap = max_many_bytes -| tail_room;
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
        if (out.written().len + size > cap) {
            if (mirror) |m| m.rollback(&journal);
            try not_sent.append(gpa, want.file);
            try not_sent_items.append(gpa, want.item);
            pending_cost += tailCost(want.file);
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
        try writeManyRest(gpa, &out.writer, args, not_sent.items, not_sent_items.items);
    }
    event.chars_emetgate = sent;
    event.chars_fullfile = full;
    return success(gpa, &out);
}

/// Reply bytes one left-out file adds to the tail: its name escaped in the
/// not_sent list and the trailer's call (with any options of its entry), and
/// plain in the trailer's text.
fn tailCost(file: []const u8) usize {
    return 6 * file.len + 96;
}

/// The trailer of a files call that left files out: the same call with files
/// narrowed to the entries not sent and no top-level file.
fn writeManyRest(gpa: Allocator, w: *Writer, args: Value, names: []const []const u8, items: []const Value) !void {
    var call: std.json.ObjectMap = .empty;
    defer call.deinit(gpa);
    if (args == .object) {
        var it = args.object.iterator();
        while (it.next()) |field| {
            if (std.mem.eql(u8, field.key_ptr.*, "file") or std.mem.eql(u8, field.key_ptr.*, "files")) continue;
            try call.put(gpa, field.key_ptr.*, field.value_ptr.*);
        }
    }
    var list: std.json.Array = .init(gpa);
    defer list.deinit();
    try list.appendSlice(items);
    try call.put(gpa, "files", .{ .array = list });
    var left: std.Io.Writer.Allocating = .init(gpa);
    defer left.deinit();
    for (names, 0..) |name, i| {
        if (i != 0) try left.writer.writeAll(", ");
        try left.writer.writeAll(name);
    }
    try reply_contract.writeTrailer(w, "{d} file(s) over the {d}-char reply: {s}", .{ names.len, max_many_bytes, left.written() }, "emetgate_read_file", Value{ .object = call });
}

/// The trailer of a cut line view. The view began at line `start`, byte
/// `offset` of that line, and was asked to run to line `end`; `line_len` is the
/// length of line `start` without its newline.
fn writeLinesRest(w: *Writer, file: []const u8, start: i64, end: i64, offset: usize, line_len: usize, c: reply_contract.Cut, rest_bytes: usize) !void {
    if (!c.split_line) {
        const next = start + @as(i64, @intCast(c.lines));
        return reply_contract.writeTrailer(w, "lines {d}-{d} ({d} bytes)", .{ next, end, rest_bytes }, "emetgate_read_file", .{ .file = file, .line_start = next, .line_end = end });
    }
    const resume_at = offset + c.kept.len;
    if (end > start) {
        return reply_contract.writeTrailer(w, "bytes {d}-{d} of line {d} (a line longer than the reply), and lines {d}-{d}", .{ resume_at, line_len, start, start + 1, end }, "emetgate_read_file", .{ .file = file, .line_start = start, .line_end = end, .offset = resume_at });
    }
    return reply_contract.writeTrailer(w, "bytes {d}-{d} of line {d} (a line longer than the reply)", .{ resume_at, line_len, start }, "emetgate_read_file", .{ .file = file, .line_start = start, .line_end = end, .offset = resume_at });
}

fn lineLen(bytes: []const u8, from: usize) usize {
    const nl = std.mem.indexOfScalarPos(u8, bytes, from, '\n') orelse bytes.len;
    const end = if (nl > from and bytes[nl - 1] == '\r') nl - 1 else nl;
    return end - from;
}

fn offsetOf(options: Options) !usize {
    const o = options.offset orelse return 0;
    if (o < 0) return error.InvalidOffset;
    return @intCast(o);
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
    const note: Note = .{ .ledger = if (source) |s| s.sent_ledger else null, .rel = place.rel };

    // One precedence for every file type: a line range wins, then heading
    // (Markdown) or pointer (JSON), then the type's default view.
    const offset = try offsetOf(options);
    if (options.line_start != null or options.line_end != null) {
        return renderRangeFrom(gpa, file, bytes, options.line_start, options.line_end, offset, force, mirror, note, w, event);
    }
    if (!options.raw and hasExtension(file, ".json")) {
        return renderJson(gpa, file, bytes, options.pointer, offset, force, mirror, note, w, event);
    }
    if (!options.raw and hasExtension(file, ".md")) {
        return renderMarkdown(gpa, file, bytes, options.heading, offset, force, mirror, note, w, event);
    }
    if (!options.raw and profile != null and bytes.len > outline.threshold) {
        if (source) |s| {
            if (try renderOutline(gpa, io, s, place.abs, file, bytes, offset, force, mirror, w, event)) return;
        }
    }

    // The default view: the file from its start, cut at a line end to the
    // reply budget, the rest named with the line range that returns it.
    const c = reply_contract.cut(bytes, reply_contract.room(.read_file), .json);
    const shown = c.kept;
    if (!std.unicode.utf8ValidateSlice(shown)) return error.NotUtf8;
    const file_hash = symbol.fileHash(bytes);
    const hash = symbol.hashOf(shown);
    event.chars_fullfile = bytes.len;
    if (try seenBefore(gpa, mirror, "file:{s}", .{file}, hash, file_hash, force)) |since| {
        event.chars_emetgate = 0;
        return wire.writeUnchangedSince(w, file, null, hash, file_hash, since);
    }
    if (shown.len == bytes.len) try read_cache.recordWhole(gpa, mirror, file, file_hash);
    try note.shown(bytes, 0, shown.len, .exact);
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
    if (!c.whole) try writeLinesRest(w, file, 1, lastLine(bytes), 0, lineLen(bytes, 0), c, bytes.len - shown.len);
}

fn renderOutline(gpa: Allocator, io: std.Io, source: Source, abs: []const u8, file: []const u8, bytes: []const u8, offset: usize, force: bool, mirror: ?*mirror_mod.Mirror, w: *Writer, event: *telemetry.Event) !bool {
    const snapshot = if (source.tree_cache) |cache| try cache.load(source.runtime, io, abs) else try Snapshot.load(source.runtime, io, .cwd(), abs);
    defer if (source.tree_cache == null) snapshot.destroy();
    const table = snapshot.symbols() catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.SourceHasErrors => return false,
    };
    const rendered = try outline.render(gpa, file, snapshot.source, table, .{ .offset = offset, .limit = reply_contract.room(.read_file) });
    defer gpa.free(rendered.text);
    const text = rendered.text;
    event.chars_fullfile = bytes.len;
    const file_hash = symbol.fileHash(snapshot.source);
    const hash = symbol.hashOf(text);
    if (try seenBefore(gpa, mirror, "outline:{s}@{d}", .{ file, offset }, hash, file_hash, force)) |since| {
        event.chars_emetgate = 0;
        try wire.writeUnchangedSince(w, file, null, hash, file_hash, since);
        return true;
    }
    event.chars_emetgate = text.len;
    try w.writeAll(text);
    if (rendered.next) |next| {
        try reply_contract.writeTrailer(w, "outline rows {d}-{d} of {d}", .{ next + 1, rendered.total, rendered.total }, "emetgate_read_file", .{ .file = file, .offset = next });
    }
    return true;
}

fn renderJson(gpa: Allocator, file: []const u8, bytes: []const u8, pointer: ?[]const u8, offset: usize, force: bool, mirror: ?*mirror_mod.Mirror, note: Note, w: *Writer, event: *telemetry.Event) !void {
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
        if (try seenBefore(gpa, mirror, "json:{s}#{s}@{d}", .{ file, p, offset }, entry.hash, file_hash, force)) |since| {
            event.chars_emetgate = 0;
            return wire.writeUnchangedSince(w, file, p, entry.hash, file_hash, since);
        }
        return writeSection(file, bytes, file_hash, "pointer", p, "value", entry.hash, entry.node.startByte(), entry.node.endByte(), offset, note, w, event);
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
    const first = @min(offset, entries.len);
    const shown = treeRows(entries.len, first, entries, struct {
        fn size(entry: anytype) usize {
            return reply_contract.encodedLen(entry.pointer, .json) + 96;
        }
    }.size);
    try writeTreeCount(&js, entries.len, first, shown);
    try js.objectField("keys");
    try js.beginArray();
    for (entries[first..shown]) |entry| {
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
    try sendTree(gpa, file, "keys", first, out.written(), file_hash, force, mirror, w, event);
    if (shown < entries.len) try reply_contract.writeTrailer(w, "keys {d}-{d} of {d}", .{ shown + 1, entries.len, entries.len }, "emetgate_read_file", .{ .file = file, .offset = shown });
}

/// How many rows of a tree fit the reply, starting at row `first`: returns the
/// index of the first row left out (or `total`). At least one row is shown.
fn treeRows(total: usize, first: usize, entries: anytype, comptime size: anytype) usize {
    var used: usize = 0;
    const limit = reply_contract.room(.read_file);
    var i = first;
    while (i < total) : (i += 1) {
        used += size(entries[i]);
        if (used > limit and i > first) return i;
    }
    return total;
}

fn writeTreeCount(js: *std.json.Stringify, total: usize, first: usize, shown: usize) !void {
    if (first == 0 and shown == total) return;
    try js.objectField("total");
    try js.write(total);
    try js.objectField("offset");
    try js.write(first);
    try js.objectField("status");
    try js.write("partial");
}

/// A JSON value or Markdown section, from byte `offset` of its text, cut to
/// the reply budget; a cut names the offset that resumes it.
fn writeSection(file: []const u8, bytes: []const u8, file_hash: symbol.Hash, comptime selector: []const u8, key: []const u8, comptime field: []const u8, hash: symbol.Hash, start: usize, end: usize, offset: usize, note: Note, w: *Writer, event: *telemetry.Event) !void {
    const whole = bytes[start..end];
    const from = reply_contract.charStart(whole, offset);
    const c = reply_contract.cut(whole[from..], reply_contract.room(.read_file) -| (2 * key.len), .json);
    try note.shown(bytes, start + from, start + from + c.kept.len, .exact);
    event.chars_emetgate = c.kept.len;
    const hex = symbol.formatHash(hash);
    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("file");
    try js.write(file);
    try wire.writeFileHash(&js, file_hash);
    try js.objectField(selector);
    try js.write(key);
    try js.objectField("hash");
    try js.write(hex[0..]);
    if (from != 0 or !c.whole) {
        try js.objectField("bytes");
        try js.write(whole.len);
        try js.objectField("offset");
        try js.write(from);
        try js.objectField("status");
        try js.write("partial");
    }
    try js.objectField(field);
    try js.write(c.kept);
    try js.endObject();
    try w.writeByte('\n');
    if (c.whole) return;
    const resume_at = from + c.kept.len;
    const left = "bytes {d}-{d} of the " ++ field ++ " at " ++ selector ++ " {s}";
    if (comptime std.mem.eql(u8, selector, "pointer")) {
        try reply_contract.writeTrailer(w, left, .{ resume_at, whole.len, key }, "emetgate_read_file", .{ .file = file, .pointer = key, .offset = resume_at });
    } else {
        try reply_contract.writeTrailer(w, left, .{ resume_at, whole.len, key }, "emetgate_read_file", .{ .file = file, .heading = key, .offset = resume_at });
    }
}

fn sendTree(gpa: Allocator, file: []const u8, comptime kind: []const u8, offset: usize, text: []const u8, file_hash: symbol.Hash, force: bool, mirror: ?*mirror_mod.Mirror, w: *Writer, event: *telemetry.Event) !void {
    const hash = symbol.hashOf(text);
    if (try seenBefore(gpa, mirror, kind ++ ":{s}@{d}", .{ file, offset }, hash, file_hash, force)) |since| {
        event.chars_emetgate = 0;
        return wire.writeUnchangedSince(w, file, null, hash, file_hash, since);
    }
    event.chars_emetgate = text.len;
    try w.writeAll(text);
    try w.writeByte('\n');
}

fn renderMarkdown(gpa: Allocator, file: []const u8, bytes: []const u8, heading: ?[]const u8, offset: usize, force: bool, mirror: ?*mirror_mod.Mirror, note: Note, w: *Writer, event: *telemetry.Event) !void {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.NotUtf8;
    const parser = ts.Parser.create();
    defer parser.deinit();
    const tree = try parser.parseIn(markdown_heading.grammar(), bytes);
    defer tree.deinit();
    const file_hash = symbol.fileHash(bytes);
    event.chars_fullfile = bytes.len;

    if (heading) |h| {
        const entry = try markdown_heading.resolve(gpa, tree, h);
        if (try seenBefore(gpa, mirror, "heading:{s}#{s}@{d}", .{ file, h, offset }, entry.hash, file_hash, force)) |since| {
            event.chars_emetgate = 0;
            return wire.writeUnchangedSince(w, file, h, entry.hash, file_hash, since);
        }
        return writeSection(file, bytes, file_hash, "heading", h, "section", entry.hash, entry.node.startByte(), entry.node.endByte(), offset, note, w, event);
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
    const first = @min(offset, entries.len);
    const shown = treeRows(entries.len, first, entries, struct {
        fn size(entry: anytype) usize {
            return reply_contract.encodedLen(entry.heading, .json) + 96;
        }
    }.size);
    try writeTreeCount(&js, entries.len, first, shown);
    try js.objectField("headings");
    try js.beginArray();
    for (entries[first..shown]) |entry| {
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
    try sendTree(gpa, file, "headings", first, out.written(), file_hash, force, mirror, w, event);
    if (shown < entries.len) try reply_contract.writeTrailer(w, "headings {d}-{d} of {d}", .{ shown + 1, entries.len, entries.len }, "emetgate_read_file", .{ .file = file, .offset = shown });
}

pub fn renderRange(gpa: Allocator, file: []const u8, bytes: []const u8, line_start: ?i64, line_end: ?i64, force: bool, mirror: ?*mirror_mod.Mirror, note: Note, w: *Writer, event: *telemetry.Event) !void {
    return renderRangeFrom(gpa, file, bytes, line_start, line_end, 0, force, mirror, note, w, event);
}

/// Lines line_start..line_end from byte `offset` of the first line, cut at a
/// line end to the reply budget; the trailer names the call for the rest.
pub fn renderRangeFrom(gpa: Allocator, file: []const u8, bytes: []const u8, line_start: ?i64, line_end: ?i64, offset: usize, force: bool, mirror: ?*mirror_mod.Mirror, note: Note, w: *Writer, event: *telemetry.Event) !void {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.NotUtf8;
    const start = line_start orelse return error.MissingArgument;
    const end = line_end orelse return error.MissingArgument;
    if (start < 1 or end < 1) return error.InvalidLineRange;
    if (start > end) return error.InvalidLineRange;
    const last = lastLine(bytes);
    if (start > last) return error.LineOutOfRange;
    const shown_end = @min(end, last);
    const span = try line_range.byteRangeForLines(bytes, @intCast(start), @intCast(shown_end));
    const first_len = lineLen(bytes, span.start);
    const from = span.start + reply_contract.charStart(bytes[span.start..span.end], @min(offset, first_len));
    const c = reply_contract.cut(bytes[from..span.end], reply_contract.room(.read_file) -| (2 * file.len), .json);
    const text = c.kept;
    const hash = symbol.hashOf(text);
    const file_hash = symbol.fileHash(bytes);
    event.chars_fullfile = bytes.len;
    if (try read_cache.wholeSince(gpa, mirror, file, file_hash, force)) |since| {
        event.chars_emetgate = 0;
        return read_cache.writeCoveredSince(w, file, null, file_hash, since);
    }
    if (try seenBefore(gpa, mirror, "range:{s}:{d}-{d}@{d}", .{ file, start, end, from - span.start }, hash, file_hash, force)) |since| {
        event.chars_emetgate = 0;
        return wire.writeUnchangedSince(w, file, null, hash, file_hash, since);
    }
    try note.shown(bytes, from, from + text.len, .exact);
    event.chars_emetgate = text.len;
    const hex = symbol.formatHash(hash);
    const last_shown: i64 = if (c.whole) shown_end else if (c.split_line) start else start + @as(i64, @intCast(c.lines)) - 1;
    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("file");
    try js.write(file);
    try wire.writeFileHash(&js, file_hash);
    try js.objectField("start_line");
    try js.write(start);
    try js.objectField("end_line");
    try js.write(last_shown);
    if (from != span.start) {
        try js.objectField("offset");
        try js.write(from - span.start);
    }
    if (!c.whole) {
        try js.objectField("status");
        try js.write("partial");
        try js.objectField("requested_end_line");
        try js.write(end);
    } else if (shown_end < end) {
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
    if (!c.whole) try writeLinesRest(w, file, start, shown_end, from - span.start, first_len, c, span.end - from - text.len);
}

fn lastLine(bytes: []const u8) i64 {
    if (bytes.len == 0) return 0;
    const newlines: i64 = @intCast(std.mem.count(u8, bytes, "\n"));
    return if (bytes[bytes.len - 1] == '\n') newlines else newlines + 1;
}

pub fn callList(gpa: Allocator, io: std.Io, args: ?Value, event: *telemetry.Event, root: ?[]const u8) !ToolResult {
    const dir = if (args) |a| getString(a, "dir") orelse "." else ".";
    const offset = if (args) |a| tool_result.getInt(a, "offset") orelse 0 else 0;
    event.label = "list";
    event.file = dir;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    renderList(gpa, io, root, dir, offset, &buffer.writer) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failure(gpa, &buffer, err, event);
    };
    return success(gpa, &buffer);
}

/// The file system folders directly under dir, as names, kept while they fit `limit`.
fn writeFolders(gpa: Allocator, io: std.Io, dir_abs: []const u8, limit: usize, js: *std.json.Stringify) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, dir_abs, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| gpa.free(name);
        names.deinit(gpa);
    }
    var entries = dir.iterate();
    while (entries.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (std.ascii.eqlIgnoreCase(entry.name, ".git") or std.ascii.eqlIgnoreCase(entry.name, shadow.workspace_dir)) continue;
        if (names.items.len == max_list_entries) break;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    if (names.items.len == 0) return;
    std.mem.sort([]u8, names.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    var used: usize = 0;
    var kept: usize = 0;
    for (names.items) |name| {
        used += reply_contract.encodedLen(name, .json) + 3;
        if (used > limit) break;
        kept += 1;
    }
    try js.objectField("folders");
    try js.write(names.items[0..kept]);
}

fn writeShownPath(gpa: Allocator, js: *std.json.Stringify, path: []const u8) !void {
    if (display_path.prefix.len == 0) return js.write(path);
    const shown = try std.fmt.allocPrint(gpa, "{s}{s}", .{ display_path.prefix, path });
    defer gpa.free(shown);
    try js.write(shown);
}

fn pathCost(path: []const u8) usize {
    return reply_contract.encodedLen(path, .json) + display_path.prefix.len + 3;
}

const Folder = struct { name: []const u8, files: usize };

/// Lists the files under dir. When every path fits the reply they come back
/// flat, as paths from the repository root. Otherwise the reply is a tree one
/// level deep: each subfolder with the number of files below it, then the
/// files directly in dir, paged by `offset` over that list; a cut ends with
/// the trailer naming the offset that continues it, and a subfolder's files
/// are listed by calling again with that folder as dir.
fn renderList(gpa: Allocator, io: std.Io, root: ?[]const u8, dir: []const u8, offset_arg: i64, w: *Writer) !void {
    if (offset_arg < 0) return error.InvalidOffset;
    const offset: usize = @intCast(offset_arg);
    const place = try repo.jail(gpa, io, root, dir);
    defer place.deinit(gpa);
    var outside: std.ArrayList([]u8) = .empty;
    defer {
        for (outside.items) |p| gpa.free(p);
        outside.deinit(gpa);
    }
    const files = try shadow.workingListing(gpa, io, place.root, &outside);
    defer gpa.free(files);
    defer shadow.freeFileList(gpa, files);
    var skipped: std.ArrayList([]const u8) = .empty;
    defer skipped.deinit(gpa);
    var skipped_cost: usize = 0;
    for (outside.items) |p| {
        if (!inDirectory(std.mem.trimEnd(u8, p, "/"), place.rel)) continue;
        try skipped.append(gpa, p);
        skipped_cost += pathCost(p);
    }

    var matched: std.ArrayList([]const u8) = .empty;
    defer matched.deinit(gpa);
    var flat_cost: usize = 0;
    for (files) |f| {
        if (!inDirectory(f, place.rel)) continue;
        try matched.append(gpa, f);
        flat_cost += pathCost(f);
    }
    const room = reply_contract.room(.list) -| (2 * dir.len) -| skipped_cost;

    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("dir");
    if (display_path.prefix.len != 0 and std.fs.path.isAbsolute(dir)) {
        const shown = try std.fmt.allocPrint(gpa, "{s}{s}", .{ display_path.prefix, place.rel });
        defer gpa.free(shown);
        try js.write(std.mem.trimEnd(u8, shown, "/"));
    } else {
        try js.write(dir);
    }
    try js.objectField("total");
    try js.write(matched.items.len);
    if (skipped.items.len != 0) {
        try js.objectField("skipped_outside");
        try js.beginArray();
        for (skipped.items) |p| try writeShownPath(gpa, &js, p);
        try js.endArray();
    }
    if (offset == 0 and flat_cost <= room) {
        try js.objectField("files");
        try js.beginArray();
        for (matched.items) |f| try writeShownPath(gpa, &js, f);
        try js.endArray();
        try writeFolders(gpa, io, place.abs, room - flat_cost, &js);
        try js.endObject();
        try w.writeByte('\n');
        return;
    }

    // The tree one level deep: subfolders with their counts, then direct files.
    var folders: std.StringArrayHashMapUnmanaged(usize) = .empty;
    defer folders.deinit(gpa);
    var direct: std.ArrayList([]const u8) = .empty;
    defer direct.deinit(gpa);
    const skip = if (place.rel.len == 0) 0 else place.rel.len + 1;
    for (matched.items) |f| {
        const rest = f[skip..];
        if (std.mem.indexOfAny(u8, rest, "/\\")) |sep| {
            const slot = try folders.getOrPut(gpa, f[0 .. skip + sep]);
            slot.value_ptr.* = if (slot.found_existing) slot.value_ptr.* + 1 else 1;
        } else {
            try direct.append(gpa, f);
        }
    }
    folders.sort(struct {
        keys: []const []const u8,
        pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            return std.mem.order(u8, ctx.keys[a], ctx.keys[b]) == .lt;
        }
    }{ .keys = folders.keys() });
    const entries = folders.count() + direct.items.len;
    const first = @min(offset, entries);
    var used: usize = 0;
    var next = first;
    while (next < entries) : (next += 1) {
        const path = if (next < folders.count()) folders.keys()[next] else direct.items[next - folders.count()];
        used += pathCost(path) + 24;
        if (used > room and next > first) break;
    }
    try js.objectField("offset");
    try js.write(first);
    try js.objectField("subfolders");
    try js.beginArray();
    var i = first;
    while (i < @min(next, folders.count())) : (i += 1) {
        try js.beginObject();
        try js.objectField("dir");
        try writeShownPath(gpa, &js, folders.keys()[i]);
        try js.objectField("files");
        try js.write(folders.values()[i]);
        try js.endObject();
    }
    try js.endArray();
    try js.objectField("files");
    try js.beginArray();
    while (i < next) : (i += 1) try writeShownPath(gpa, &js, direct.items[i - folders.count()]);
    try js.endArray();
    try js.objectField("hint");
    try js.write("files below a subfolder are counted, not listed: emetgate_list with that folder as dir lists them");
    if (next < entries) {
        try js.objectField("status");
        try js.write("partial");
    }
    try js.endObject();
    try w.writeByte('\n');
    if (next < entries) {
        try reply_contract.writeTrailer(w, "entries {d}-{d} of {d} (subfolders, then files directly in the folder)", .{ next + 1, entries, entries }, "emetgate_list", .{ .dir = dir, .offset = next });
    }
}
