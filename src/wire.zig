const std = @import("std");
const symbol = @import("symbol.zig");
const sandbox = @import("sandbox.zig");

const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

pub fn writeSymbols(gpa: Allocator, writer: *Writer, file: []const u8, table: symbol.Table) !void {
    var js: std.json.Stringify = .{ .writer = writer };
    try js.beginObject();
    try js.objectField("file");
    try js.write(file);
    try js.objectField("symbols");
    try js.beginArray();
    for (table.symbols) |entry| {
        const point = entry.node.startPoint();
        const hex = symbol.formatHash(entry.hash);
        const ref = try std.fmt.allocPrint(gpa, "{f}", .{entry.ref});
        defer gpa.free(ref);
        try js.beginObject();
        try js.objectField("hash");
        try js.write(hex[0..]);
        try js.objectField("kind");
        try js.write(entry.kind);
        try js.objectField("ref");
        try js.write(ref);
        try js.objectField("line");
        try js.write(point.row + 1);
        try js.objectField("col");
        try js.write(point.column + 1);
        try js.objectField("ambiguous");
        try js.write(entry.ambiguous);
        try js.endObject();
    }
    try js.endArray();
    try js.endObject();
    try writer.writeByte('\n');
}

pub fn writeSkeleton(writer: *Writer, file: []const u8, skeleton_text: []const u8) !void {
    var js: std.json.Stringify = .{ .writer = writer };
    try js.beginObject();
    try js.objectField("file");
    try js.write(file);
    try js.objectField("skeleton");
    try js.write(skeleton_text);
    try js.endObject();
    try writer.writeByte('\n');
}

pub fn writeSymbolBody(writer: *Writer, file: []const u8, ref: []const u8, hash: symbol.Hash, body: []const u8) !void {
    const hex = symbol.formatHash(hash);
    var js: std.json.Stringify = .{ .writer = writer };
    try js.beginObject();
    try js.objectField("file");
    try js.write(file);
    try js.objectField("symbol");
    try js.write(ref);
    try js.objectField("hash");
    try js.write(hex[0..]);
    try js.objectField("body");
    try js.write(body);
    try js.endObject();
    try writer.writeByte('\n');
}

pub fn writeCommitted(writer: *Writer, sym: []const u8, old_hash: symbol.Hash, new_hash: symbol.Hash) !void {
    const old_hex = symbol.formatHash(old_hash);
    const new_hex = symbol.formatHash(new_hash);
    var js: std.json.Stringify = .{ .writer = writer };
    try js.beginObject();
    try js.objectField("status");
    try js.write("committed");
    try js.objectField("symbol");
    try js.write(sym);
    try js.objectField("old_hash");
    try js.write(old_hex[0..]);
    try js.objectField("new_hash");
    try js.write(new_hex[0..]);
    try js.endObject();
    try writer.writeByte('\n');
}

pub const BatchEdit = struct {
    file: []const u8,
    symbol: []const u8,
    old_hash: symbol.Hash,
    new_hash: symbol.Hash,
};

pub fn writeBatchCommitted(writer: *Writer, edits: []const BatchEdit) !void {
    var js: std.json.Stringify = .{ .writer = writer };
    try js.beginObject();
    try js.objectField("status");
    try js.write("committed");
    try js.objectField("edits");
    try js.beginArray();
    for (edits) |edit| {
        const old_hex = symbol.formatHash(edit.old_hash);
        const new_hex = symbol.formatHash(edit.new_hash);
        try js.beginObject();
        try js.objectField("file");
        try js.write(edit.file);
        try js.objectField("symbol");
        try js.write(edit.symbol);
        try js.objectField("old_hash");
        try js.write(old_hex[0..]);
        try js.objectField("new_hash");
        try js.write(new_hex[0..]);
        try js.endObject();
    }
    try js.endArray();
    try js.endObject();
    try writer.writeByte('\n');
}

pub fn writeMutated(writer: *Writer, sym: []const u8, old_hash: symbol.Hash, new_hash: symbol.Hash, source: []const u8) !void {
    const old_hex = symbol.formatHash(old_hash);
    const new_hex = symbol.formatHash(new_hash);
    var js: std.json.Stringify = .{ .writer = writer };
    try js.beginObject();
    try js.objectField("status");
    try js.write("mutated");
    try js.objectField("symbol");
    try js.write(sym);
    try js.objectField("old_hash");
    try js.write(old_hex[0..]);
    try js.objectField("new_hash");
    try js.write(new_hex[0..]);
    try js.objectField("source");
    try js.write(source);
    try js.endObject();
    try writer.writeByte('\n');
}

pub fn writeRejected(writer: *Writer, test_cmd: []const u8, report: sandbox.Report) !void {
    var js: std.json.Stringify = .{ .writer = writer };
    try js.beginObject();
    try js.objectField("status");
    try js.write("rejected");
    try js.objectField("reason");
    try js.write(rejectionReason(report));
    try js.objectField("test_cmd");
    try js.write(test_cmd);
    try js.objectField("outcome");
    try js.write(outcomeTag(report.outcome));
    try js.objectField("stdout");
    try js.write(report.stdout);
    try js.objectField("stderr");
    try js.write(report.stderr);
    try js.endObject();
    try writer.writeByte('\n');
}

fn rejectionReason(report: sandbox.Report) []const u8 {
    return switch (report.outcome) {
        .exited => |code| if (code != 0) "tests_failed" else "leftover_processes",
        .timed_out => "timed_out",
        .output_limit => "output_limit",
    };
}

fn outcomeTag(outcome: sandbox.Outcome) []const u8 {
    return switch (outcome) {
        .exited => "exited",
        .timed_out => "timed_out",
        .output_limit => "output_limit",
    };
}

pub fn exitCode(err: anyerror) u8 {
    return switch (err) {
        error.InvalidRef, error.InvalidHash => 2,
        error.SourceHasErrors => 3,
        error.SymbolNotFound => 4,
        error.AmbiguousSymbol => 5,
        error.HashMismatch => 6,
        error.MutationSyntaxInvalid => 7,
        error.BodyEscape => 8,
        error.SkeletonInvalid => 9,
        error.PlaceholderBody => 13,
        error.NotInRepo, error.FileOutsideRepo, error.InvalidPath => 2,
        error.NoTestCommand, error.InvalidConfig => 2,
        error.UntrustedRepoConfig => 15,
        error.WorkspaceBusy, error.WorkspaceLockFailed => 14,
        error.Conflict => 11,
        error.WrittenButUnverified => 12,
        else => 1,
    };
}

pub fn writeError(writer: *Writer, name: []const u8, exit_code: u8) !void {
    var js: std.json.Stringify = .{ .writer = writer };
    try js.beginObject();
    try js.objectField("status");
    try js.write("error");
    try js.objectField("error");
    try js.write(name);
    try js.objectField("exit_code");
    try js.write(exit_code);
    try js.endObject();
    try writer.writeByte('\n');
}

const testing = std.testing;
const ts = @import("tree_sitter.zig");
const alloc_bridge = @import("alloc_bridge.zig");
const test_util = @import("test_util.zig");

fn renderSymbols(gpa: Allocator, file: []const u8, tree: ts.Tree) ![]u8 {
    const table = try symbol.Table.build(gpa, tree);
    defer table.deinit();
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    try writeSymbols(gpa, &buffer.writer, file, table);
    return gpa.dupe(u8, buffer.written());
}

test "symbols render as one NDJSON line with typed fields" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const t = try test_util.TestTree.init("export function add(a: number, b: number): number { return a + b; }\n");
    defer t.deinit();

    const json = try renderSymbols(testing.allocator, "src/math.ts", t.tree);
    defer testing.allocator.free(json);

    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, json, "\n"));
    try testing.expect(json[json.len - 1] == '\n');
    try testing.expect(std.mem.indexOf(u8, json, "\"file\":\"src/math.ts\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"ref\":\"add\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"function\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"line\":1") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"ambiguous\":false") != null);
}

test "file paths with backslashes and quotes are JSON-escaped" {
    try alloc_bridge.install(testing.allocator);
    defer alloc_bridge.uninstall();
    const t = try test_util.TestTree.init("function f() {}\n");
    defer t.deinit();

    const json = try renderSymbols(testing.allocator, "tests\\e2e\\a\"b.ts", t.tree);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "tests\\\\e2e\\\\a\\\"b.ts") != null);
}

test "skeleton payload embeds the outline as one JSON line" {
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    try writeSkeleton(&buffer.writer, "src/a.ts", "export function add(a: number, b: number): number;\n");

    const json = buffer.written();
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, json, "\n"));
    try testing.expect(std.mem.indexOf(u8, json, "\"file\":\"src/a.ts\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"skeleton\":\"export function add(a: number, b: number): number;\\n\"") != null);
}

test "symbol body payload carries ref, hash and the escaped body" {
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    try writeSymbolBody(&buffer.writer, "src/a.ts", "add", symbol.hashOf("x"), "{\n  return a + b;\n}");

    const json = buffer.written();
    try testing.expect(std.mem.indexOf(u8, json, "\"symbol\":\"add\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"hash\":\"" ++ &symbol.formatHash(symbol.hashOf("x")) ++ "\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"body\":\"{\\n  return a + b;\\n}\"") != null);
}

test "committed payload names the symbol and both hashes" {
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    try writeCommitted(&buffer.writer, "validateOrder", symbol.hashOf("a"), symbol.hashOf("b"));

    try testing.expectEqualStrings(
        "{\"status\":\"committed\",\"symbol\":\"validateOrder\"," ++
            "\"old_hash\":\"" ++ &symbol.formatHash(symbol.hashOf("a")) ++ "\"," ++
            "\"new_hash\":\"" ++ &symbol.formatHash(symbol.hashOf("b")) ++ "\"}\n",
        buffer.written(),
    );
}

test "mutated payload embeds the transformed source, escaped, on one line" {
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    try writeMutated(&buffer.writer, "add", symbol.hashOf("a"), symbol.hashOf("b"), "function add() {\n  return 0;\n}");

    const json = buffer.written();
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, json, "\n"));
    try testing.expect(std.mem.indexOf(u8, json, "\"status\":\"mutated\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"source\":\"function add() {\\n  return 0;\\n}\"") != null);
}

test "rejected reason reflects the real outcome, not always tests_failed" {
    const cases = [_]struct { outcome: sandbox.Outcome, leftovers: bool, reason: []const u8, tag: []const u8 }{
        .{ .outcome = .{ .exited = 1 }, .leftovers = false, .reason = "tests_failed", .tag = "exited" },
        .{ .outcome = .{ .exited = 0 }, .leftovers = true, .reason = "leftover_processes", .tag = "exited" },
        .{ .outcome = .timed_out, .leftovers = false, .reason = "timed_out", .tag = "timed_out" },
        .{ .outcome = .output_limit, .leftovers = false, .reason = "output_limit", .tag = "output_limit" },
    };
    for (cases) |case| {
        var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buffer.deinit();
        const report: sandbox.Report = .{
            .outcome = case.outcome,
            .duration_ns = 0,
            .stdout = @constCast("out"),
            .stderr = @constCast("err"),
            .truncated = false,
            .killed_leftovers = case.leftovers,
        };
        try writeRejected(&buffer.writer, "npm test", report);
        const json = buffer.written();
        errdefer std.debug.print("case {s}: {s}\n", .{ case.reason, json });
        try testing.expect(std.mem.indexOf(u8, json, "\"reason\":\"") != null);
        var reason_buf: [64]u8 = undefined;
        try testing.expect(std.mem.indexOf(u8, json, try std.fmt.bufPrint(&reason_buf, "\"reason\":\"{s}\"", .{case.reason})) != null);
        var tag_buf: [64]u8 = undefined;
        try testing.expect(std.mem.indexOf(u8, json, try std.fmt.bufPrint(&tag_buf, "\"outcome\":\"{s}\"", .{case.tag})) != null);
        try testing.expect(std.mem.indexOf(u8, json, "\"test_cmd\":\"npm test\"") != null);
    }
}

test "error payload carries the name and exit code on one line" {
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    try writeError(&buffer.writer, "PlaceholderBody", 13);

    try testing.expectEqualStrings(
        "{\"status\":\"error\",\"error\":\"PlaceholderBody\",\"exit_code\":13}\n",
        buffer.written(),
    );
}
