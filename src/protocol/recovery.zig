const std = @import("std");
const symbol = @import("../engine/symbol.zig");
const node_cas = @import("../engine/node_cas.zig");
const repo = @import("../platform/repo.zig");
const wire = @import("wire.zig");
const tool_result = @import("tool_result.zig");
const Snapshot = @import("../engine/loader.zig").Snapshot;
const Runtime = @import("../engine/runtime.zig").Runtime;

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const max_read = 64 * 1024 * 1024;

pub fn symbolHash(gpa: Allocator, io: std.Io, runtime: *Runtime, root: ?[]const u8, file: []const u8, sym: []const u8) ?symbol.Hash {
    const place = repo.jail(gpa, io, root, file) catch return null;
    defer place.deinit(gpa);
    const snapshot = Snapshot.load(runtime, io, .cwd(), place.abs) catch return null;
    defer snapshot.destroy();
    const table = snapshot.symbols() catch return null;
    const ref = symbol.Ref.parse(gpa, sym) catch return null;
    defer ref.deinit(gpa);
    const found = table.resolve(ref) catch return null;
    return found.hash;
}

pub fn fileHash(gpa: Allocator, io: std.Io, root: ?[]const u8, file: []const u8) ?symbol.Hash {
    const place = repo.jail(gpa, io, root, file) catch return null;
    defer place.deinit(gpa);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, place.abs, gpa, .limited(max_read)) catch return null;
    defer gpa.free(bytes);
    return symbol.fileHash(bytes);
}

pub fn staleSymbol(gpa: Allocator, io: std.Io, runtime: *Runtime, root: ?[]const u8, label: []const u8, file: []const u8, sym: []const u8, given: []const u8) bool {
    const current = symbolHash(gpa, io, runtime, root, file, sym) orelse return false;
    const hex = symbol.formatHash(current);
    if (std.mem.eql(u8, &hex, given)) return false;
    wire.setFix("{s}the current hash of {s} is {s}; re-read it with emetgate_read_symbol if you have not seen this version, then retry with that hash", .{ label, sym, &hex });
    return true;
}

pub fn staleFile(gpa: Allocator, io: std.Io, root: ?[]const u8, label: []const u8, file: []const u8, given: ?[]const u8) bool {
    const current = fileHash(gpa, io, root, file) orelse return false;
    const hex = symbol.formatHash(current);
    if (given) |text| if (std.mem.eql(u8, &hex, text)) return false;
    wire.setFix("{s}{s} has file_hash {s}; pass it as hash to delete the file", .{ label, file, &hex });
    return true;
}

pub fn braceBalance(text: []const u8) i64 {
    var balance: i64 = 0;
    for (text) |c| switch (c) {
        '{' => balance += 1,
        '}' => balance -= 1,
        else => {},
    };
    return balance;
}

fn unbalanced(label: []const u8, what: []const u8, text: []const u8) bool {
    const balance = braceBalance(text);
    if (balance == 0) return false;
    if (balance > 0) {
        wire.setFix("{s}{s} opens {d} more \"{{\" than it closes; send it with balanced braces", .{ label, what, @abs(balance) });
    } else {
        wire.setFix("{s}{s} closes {d} more \"}}\" than it opens; send it with balanced braces", .{ label, what, @abs(balance) });
    }
    return true;
}

pub fn afterSymbolEdit(gpa: Allocator, io: std.Io, runtime: *Runtime, root: ?[]const u8, file: []const u8, sym: []const u8, given: []const u8, body: []const u8, err: anyerror) void {
    symbolHint(gpa, io, runtime, root, "", file, sym, given, body, err);
}

fn symbolHint(gpa: Allocator, io: std.Io, runtime: *Runtime, root: ?[]const u8, label: []const u8, file: []const u8, sym: []const u8, given: []const u8, body: []const u8, err: anyerror) void {
    if (err == error.HashMismatch) {
        _ = staleSymbol(gpa, io, runtime, root, label, file, sym, given);
        return;
    }
    if (err != error.BodyEscape and err != error.MutationSyntaxInvalid) return;
    var what_buf: [160]u8 = undefined;
    const what = std.fmt.bufPrint(&what_buf, "the body of {s}", .{sym}) catch "the body";
    if (unbalanced(label, what, body)) return;
    if (err != error.BodyEscape or std.mem.eql(u8, given, symbol.absent_text)) return;
    wire.setFix("{s}the body of {s} must be only its block, from its opening brace to its closing brace; anything before or after it reaches outside the symbol", .{ label, sym });
}

const Pair = struct { node: []const u8, text: []const u8, label: []const u8 };

fn nodePairs(args: Value, buffer: []Pair, labels: [][24]u8) []Pair {
    var count: usize = 0;
    if (tool_result.getString(args, "node")) |address| {
        buffer[0] = .{ .node = address, .text = tool_result.getString(args, "text") orelse "", .label = "" };
        count = 1;
    }
    if (tool_result.getStringArray(args, "nodes")) |entries| for (entries, 0..) |entry, i| {
        if (count == buffer.len) break;
        const label = std.fmt.bufPrint(&labels[count], "nodes[{d}] ", .{i}) catch "";
        buffer[count] = .{ .node = tool_result.getString(entry, "node") orelse continue, .text = tool_result.getString(entry, "text") orelse "", .label = label };
        count += 1;
    };
    return buffer[0..count];
}

pub fn afterNodeEdit(gpa: Allocator, io: std.Io, runtime: *Runtime, root: ?[]const u8, file: []const u8, args: Value, err: anyerror) void {
    nodeHint(gpa, io, runtime, root, "", file, args, err);
}

fn nodeHint(gpa: Allocator, io: std.Io, runtime: *Runtime, root: ?[]const u8, label: []const u8, file: []const u8, args: Value, err: anyerror) void {
    var buffer: [64]Pair = undefined;
    var labels: [64][24]u8 = undefined;
    const pairs = nodePairs(args, &buffer, &labels);
    if (err == error.BodyEscape or err == error.MutationSyntaxInvalid) {
        for (pairs) |pair| {
            var what_buf: [96]u8 = undefined;
            const what = std.fmt.bufPrint(&what_buf, "{s}the text for node {s}", .{ pair.label, pair.node }) catch "the text";
            if (unbalanced(label, what, pair.text)) return;
        }
        return;
    }
    if (err != error.HashMismatch) return;
    const place = repo.jail(gpa, io, root, file) catch return;
    defer place.deinit(gpa);
    const snapshot = Snapshot.load(runtime, io, .cwd(), place.abs) catch return;
    defer snapshot.destroy();
    if (snapshot.symbols()) |table| {
        for (pairs) |pair| for (table.symbols) |*entry| {
            const hex = symbol.formatHash(entry.hash);
            if (pair.node.len < node_cas.min_address_len or !std.mem.startsWith(u8, &hex, pair.node)) continue;
            wire.setFix("{s}{s}{s} is the symbol hash of {f}, not a node id; node ids come from emetgate_read_symbol nodes:true, or edit the whole symbol with symbol+hash+body", .{ label, pair.label, pair.node, entry.ref });
            return;
        };
    } else |_| {}
    const annotated = node_cas.annotateSnapshot(gpa, snapshot, .{ .start = 0, .end = @intCast(snapshot.source.len) }) catch return;
    defer gpa.free(annotated);
    for (pairs) |pair| {
        if (std.mem.indexOf(u8, annotated, pair.node) != null) continue;
        wire.setFix("{s}{s}node {s} is not in {s} now; node ids change after every edit, so read them again with emetgate_read_symbol nodes:true and resend only this one", .{ label, pair.label, pair.node, file });
        return;
    }
}

pub fn afterBatch(gpa: Allocator, io: std.Io, runtime: *Runtime, root: ?[]const u8, items: []const Value, err: anyerror) void {
    if (err == error.FileExists or err == error.HashMismatch) if (wholeFileHint(gpa, io, root, items)) return;
    if (err == error.FileExists) if (absentSectionHint(items)) return;
    if (err != error.HashMismatch and err != error.MissingFileHash and err != error.BodyEscape and err != error.MutationSyntaxInvalid) return;
    for (items, 0..) |item, i| {
        var label_buf: [24]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "edits[{d}]: ", .{i}) catch "";
        const file = tool_result.getString(item, "file") orelse continue;
        const given = tool_result.getString(item, "hash");
        const op = tool_result.getString(item, "op") orelse "write";
        const sym = tool_result.getString(item, "symbol");
        if (std.mem.eql(u8, op, "delete") and sym == null) {
            if (err != error.HashMismatch and err != error.MissingFileHash) continue;
            const stated = if (given) |text| if (std.mem.eql(u8, text, symbol.absent_text)) null else text else null;
            if (staleFile(gpa, io, root, label, file, stated)) return;
            continue;
        }
        if (err == error.MissingFileHash) continue;
        if (tool_result.getField(item, "node") != null or tool_result.getField(item, "nodes") != null) {
            nodeHint(gpa, io, runtime, root, label, file, item, err);
            if (wire.hasFix()) return;
            continue;
        }
        const name = sym orelse continue;
        const text = given orelse continue;
        if (err == error.HashMismatch and std.mem.eql(u8, text, symbol.absent_text)) continue;
        symbolHint(gpa, io, runtime, root, label, file, name, text, tool_result.getString(item, "body") orelse "", err);
        if (wire.hasFix()) return;
    }
}

fn wholeFileHint(gpa: Allocator, io: std.Io, root: ?[]const u8, items: []const Value) bool {
    for (items, 0..) |item, i| {
        if (tool_result.getString(item, "symbol") != null or tool_result.getString(item, "old_string") != null) continue;
        if (tool_result.getField(item, "node") != null or tool_result.getField(item, "nodes") != null) continue;
        if (tool_result.getField(item, "line_start") != null or tool_result.getField(item, "pointer") != null or tool_result.getField(item, "heading") != null) continue;
        if (tool_result.getString(item, "op")) |op| if (!std.mem.eql(u8, op, "write")) continue;
        if (tool_result.getString(item, "content") == null and tool_result.getString(item, "body") == null) continue;
        const file = tool_result.getString(item, "file") orelse continue;
        const current = fileHash(gpa, io, root, file) orelse continue;
        const hex = symbol.formatHash(current);
        if (tool_result.getString(item, "hash")) |given| if (std.mem.eql(u8, given, &hex)) continue;
        wire.setFix("edits[{d}]: {s} exists with file_hash {s}; pass it as hash to overwrite the whole file", .{ i, file, &hex });
        return true;
    }
    return false;
}

const write_doc_absent_fix = "write_doc only edits an existing file with the hash read by emetgate_read_file; create a new file with emetgate_write";

fn absentSectionHint(items: []const Value) bool {
    for (items, 0..) |item, i| {
        const given = tool_result.getString(item, "hash") orelse continue;
        if (!std.mem.eql(u8, given, symbol.absent_text)) continue;
        if (tool_result.getField(item, "line_start") == null and tool_result.getField(item, "pointer") == null and tool_result.getField(item, "heading") == null) continue;
        wire.setFix("edits[{d}]: " ++ write_doc_absent_fix, .{i});
        return true;
    }
    return false;
}

pub fn afterWriteDoc(hash_hex: []const u8, err: anyerror) void {
    if (err != error.InvalidHash) return;
    if (!std.mem.eql(u8, hash_hex, symbol.absent_text)) return;
    wire.setFix(write_doc_absent_fix, .{});
}
