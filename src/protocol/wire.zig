const std = @import("std");
const symbol = @import("../engine/symbol.zig");
const sandbox = @import("../platform/sandbox.zig");
const diagnostics = @import("diagnostics.zig");
const rules = @import("../platform/rules.zig");
const scan = @import("../platform/scan.zig");

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

pub fn writeCommitted(writer: *Writer, sym: []const u8, old_hash: symbol.Expected, new_hash: symbol.Hash) !void {
    var old_buf: [symbol.hash_hex_len]u8 = undefined;
    const old_hex = old_hash.text(&old_buf);
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

pub fn writeMutated(writer: *Writer, sym: []const u8, old_hash: symbol.Expected, new_hash: symbol.Hash, source: []const u8) !void {
    var old_buf: [symbol.hash_hex_len]u8 = undefined;
    const old_hex = old_hash.text(&old_buf);
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

pub fn writeRejected(gpa: Allocator, writer: *Writer, test_cmd: []const u8, report: sandbox.Report) !void {
    return writeStageRejected(gpa, writer, rejectionReason(report), "test_cmd", test_cmd, report);
}

pub fn writeTypecheckRejected(gpa: Allocator, writer: *Writer, typecheck_cmd: []const u8, report: sandbox.Report) !void {
    return writeStageRejected(gpa, writer, typecheckReason(report), "typecheck_cmd", typecheck_cmd, report);
}

pub fn writeRuleViolation(writer: *Writer, report: rules.Report) !void {
    var js: std.json.Stringify = .{ .writer = writer };
    try js.beginObject();
    try js.objectField("status");
    try js.write("rejected");
    try js.objectField("reason");
    try js.write("rule_violation");
    try js.objectField("violations");
    try js.beginArray();
    for (report.violations) |v| try writeViolation(&js, v);
    try js.endArray();
    try js.endObject();
    try writer.writeByte('\n');
}

fn writeViolation(js: *std.json.Stringify, v: rules.Violation) !void {
    try js.beginObject();
    try js.objectField("rule");
    try js.write(v.rule);
    try js.objectField("check");
    try js.write(v.check);
    try js.objectField("file");
    try js.write(v.file);
    try js.objectField("line");
    try js.write(v.line);
    try js.objectField("col");
    try js.write(v.col);
    try js.objectField("text");
    try js.write(v.text);
    try js.endObject();
}

pub fn writeScan(writer: *Writer, result: scan.Result) !void {
    var js: std.json.Stringify = .{ .writer = writer };
    try js.beginObject();
    try js.objectField("status");
    try js.write(if (result.violations.len == 0) "clean" else "violations");
    try js.objectField("rules");
    try js.write(result.rules);
    try js.objectField("scanned");
    try js.write(result.scanned);
    try js.objectField("unsupported");
    try js.write(result.unsupported);
    try js.objectField("unreadable");
    try js.beginArray();
    for (result.unreadable) |u| {
        try js.beginObject();
        try js.objectField("file");
        try js.write(u.file);
        try js.objectField("error");
        try js.write(@errorName(u.reason));
        try js.endObject();
    }
    try js.endArray();
    try js.objectField("parse_errors");
    try js.beginArray();
    for (result.parse_errors) |file| try js.write(file);
    try js.endArray();
    try js.objectField("violations");
    try js.beginArray();
    for (result.violations) |v| try writeViolation(&js, v);
    try js.endArray();
    try js.endObject();
    try writer.writeByte('\n');
}

pub fn writeMalformedRule(writer: *Writer, rule: []const u8, check: []const u8, name: []const u8, exit_code: u8) !void {
    var js: std.json.Stringify = .{ .writer = writer };
    try js.beginObject();
    try js.objectField("status");
    try js.write("error");
    try js.objectField("error");
    try js.write(name);
    try js.objectField("exit_code");
    try js.write(exit_code);
    try js.objectField("rule");
    try js.write(rule);
    try js.objectField("check");
    try js.write(check);
    try js.endObject();
    try writer.writeByte('\n');
}

pub fn writeErrorMessage(writer: *Writer, name: []const u8, exit_code: u8, message: []const u8) !void {
    var js: std.json.Stringify = .{ .writer = writer };
    try js.beginObject();
    try js.objectField("status");
    try js.write("error");
    try js.objectField("error");
    try js.write(name);
    try js.objectField("exit_code");
    try js.write(exit_code);
    try js.objectField("message");
    try js.write(message);
    try js.endObject();
    try writer.writeByte('\n');
}

fn writeStageRejected(gpa: Allocator, writer: *Writer, reason: []const u8, command_field: []const u8, command: []const u8, report: sandbox.Report) !void {
    const from_out = try diagnostics.parse(gpa, report.stdout);
    defer gpa.free(from_out);
    const from_err = try diagnostics.parse(gpa, report.stderr);
    defer gpa.free(from_err);

    var js: std.json.Stringify = .{ .writer = writer };
    try js.beginObject();
    try js.objectField("status");
    try js.write("rejected");
    try js.objectField("reason");
    try js.write(reason);
    try js.objectField(command_field);
    try js.write(command);
    try js.objectField("outcome");
    try js.write(outcomeTag(report.outcome));
    try js.objectField("diagnostics");
    try js.beginArray();
    for (from_out) |d| try writeDiagnostic(&js, d);
    for (from_err) |d| try writeDiagnostic(&js, d);
    try js.endArray();
    try js.objectField("stdout");
    try js.write(report.stdout);
    try js.objectField("stderr");
    try js.write(report.stderr);
    try js.endObject();
    try writer.writeByte('\n');
}

fn writeDiagnostic(js: *std.json.Stringify, d: diagnostics.Diagnostic) !void {
    try js.beginObject();
    try js.objectField("file");
    try js.write(d.file);
    try js.objectField("line");
    try js.write(d.line);
    try js.objectField("col");
    try js.write(d.col);
    try js.objectField("message");
    try js.write(d.message);
    try js.endObject();
}

pub fn rejectionReason(report: sandbox.Report) []const u8 {
    return switch (report.outcome) {
        .exited => |code| if (code != 0) "tests_failed" else "leftover_processes",
        .timed_out => "timed_out",
        .output_limit => "output_limit",
    };
}

pub fn typecheckReason(report: sandbox.Report) []const u8 {
    return switch (report.outcome) {
        .exited => |code| if (code != 0) "typecheck_failed" else "leftover_processes",
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
        error.UnknownCheck, error.UnexpectedCheckArgument, error.MissingCheckArgument, error.EmptyCheckArgument => 19,
        error.SymbolExists => 20,
        error.MissingTrailingNewline => 21,
        error.NoTopLevelSymbol => 22,
        error.MultipleTopLevelSymbols => 23,
        error.ExtraTopLevelCode => 24,
        error.SymbolNameMismatch => 25,
        error.AbsentInBatch => 26,
        error.FileExists => 27,
        error.ParentDirectoryMissing => 28,
        error.IgnoredPath => 29,
        error.WrittenButNotIndexed => 30,
        error.NotInRepo, error.FileOutsideRepo, error.InvalidPath => 2,
        error.NoTestCommand, error.InvalidConfig => 2,
        error.UntrustedRepoConfig => 15,
        error.ModelSuppliedTestPolicy => 17,
        error.UnsupportedLanguage, error.InternalPath, error.BinaryFile, error.NotUtf8, error.EmptyPattern => 18,
        error.WorkspaceBusy, error.WorkspaceLockFailed => 14,
        error.Conflict => 11,
        error.WrittenButUnverified => 12,
        else => 1,
    };
}

pub fn writeNotIndexed(writer: *Writer, file: []const u8) !void {
    const command = "git add -- ";
    var js: std.json.Stringify = .{ .writer = writer };
    try js.beginObject();
    try js.objectField("status");
    try js.write("error");
    try js.objectField("error");
    try js.write("WrittenButNotIndexed");
    try js.objectField("exit_code");
    try js.write(exitCode(error.WrittenButNotIndexed));
    try js.objectField("file");
    try js.write(file);
    try js.objectField("message");
    try js.write(not_indexed_message);
    try js.objectField("fix");
    try js.beginWriteRaw();
    try js.writer.writeByte('"');
    try std.json.Stringify.encodeJsonStringChars(command, .{}, js.writer);
    try std.json.Stringify.encodeJsonStringChars(file, .{}, js.writer);
    try js.writer.writeByte('"');
    js.endWriteRaw();
    try js.endObject();
    try writer.writeByte('\n');
}

pub const not_indexed_message = "the file was written to disk but was not added to the git index; until it is, proposals to other files run in a shadow copy that does not contain it";

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
const ts = @import("../engine/tree_sitter.zig");
const alloc_bridge = @import("../engine/alloc_bridge.zig");
const test_util = @import("../engine/test_util.zig");

fn renderSymbols(gpa: Allocator, file: []const u8, tree: ts.Tree) ![]u8 {
    const table = try symbol.Table.build(gpa, test_util.language, tree);
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
    try writeCommitted(&buffer.writer, "validateOrder", .{ .present = symbol.hashOf("a") }, symbol.hashOf("b"));

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
    try writeMutated(&buffer.writer, "add", .{ .present = symbol.hashOf("a") }, symbol.hashOf("b"), "function add() {\n  return 0;\n}");

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
        try writeRejected(testing.allocator, &buffer.writer, "npm test", report);
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

test "rejected payload surfaces parsed diagnostics and escapes control bytes" {
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    const report: sandbox.Report = .{
        .outcome = .{ .exited = 2 },
        .duration_ns = 0,
        .stdout = @constCast("src/x.ts(3,5): error TS2322: bad \x1b[31mred\x1b[0m type\n"),
        .stderr = @constCast(""),
        .truncated = false,
        .killed_leftovers = false,
    };
    try writeRejected(testing.allocator, &buffer.writer, "npx tsc", report);
    const json = buffer.written();

    try testing.expect(std.mem.indexOf(u8, json, "\"diagnostics\":[{\"file\":\"src/x.ts\",\"line\":3,\"col\":5,\"message\":") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\\u001b") != null);
    try testing.expect(std.mem.indexOfScalar(u8, json, 0x1b) == null);
}

test "a typecheck rejection names its own reason and command, not the test command" {
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    const report: sandbox.Report = .{
        .outcome = .{ .exited = 2 },
        .duration_ns = 0,
        .stdout = @constCast("src/x.ts(3,5): error TS2322: bad type\n"),
        .stderr = @constCast(""),
        .truncated = false,
        .killed_leftovers = false,
    };
    try writeTypecheckRejected(testing.allocator, &buffer.writer, "npx tsc --noEmit", report);
    const json = buffer.written();

    try testing.expect(std.mem.indexOf(u8, json, "\"reason\":\"typecheck_failed\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"typecheck_cmd\":\"npx tsc --noEmit\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"test_cmd\"") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"diagnostics\":[{\"file\":\"src/x.ts\",\"line\":3,\"col\":5,") != null);
}

test "a rule violation payload lists every violation with its rule and position" {
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    var violations = [_]rules.Violation{.{
        .rule = @constCast("r7"),
        .check = @constCast("no_comment"),
        .file = @constCast("src\\a.ts"),
        .line = 2,
        .col = 3,
        .text = @constCast("// \"why\""),
    }};
    try writeRuleViolation(&buffer.writer, .{ .violations = &violations });

    try testing.expectEqualStrings(
        "{\"status\":\"rejected\",\"reason\":\"rule_violation\",\"violations\":[{\"rule\":\"r7\",\"check\":\"no_comment\",\"file\":\"src\\\\a.ts\",\"line\":2,\"col\":3,\"text\":\"// \\\"why\\\"\"}]}\n",
        buffer.written(),
    );
    try testing.expectEqual(@as(u8, 19), exitCode(error.UnknownCheck));
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
