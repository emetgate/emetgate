const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");
const fixture = @import("ts_fixture.zig");
const common = @import("commit_batch.zig");
const first = @import("every_write.zig");

const symbol = emetgate.symbol;
const commit_intent = emetgate.commit_intent;

const testing = std.testing;
const Plain = common.Plain;
const Env = common.Env;
const Reply = common.Reply;
const green = common.green;
const ignore = common.ignore;
const message = first.message;
const enforce = first.enforce;
const capture = first.capture;
const expectRefused = first.expectRefused;
const body = first.body;
const rename = first.rename;
const move = first.move;
const moveFile = first.moveFile;

const a_src =
    "function helper(x) {\n  return x + 1;\n}\n" ++
    "export function main(y) {\n  return helper(y);\n}\n" ++
    "export function old(z) {\n  // kept from before\n  return z;\n}\n";
const c_src = "function lonely() {\n  return 5;\n}\nexport function gamma() {\n  return 3;\n}\n";
const note_src = "# Notes\n\n## Setup\n\nold\n";

fn skipOffWindows() !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn expectWritten(reply: Reply) !void {
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
}

test "old text: a symbol edit, a rename, a symbol move and a file move are written although the file already breaks the rule elsewhere" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ .{ .rel = "src/a.ts", .text = a_src }, .{ .rel = "src/c.ts", .text = c_src }, ignore });
    defer case.deinit();
    const env = &case.env;
    try enforce(case.repo.root_abs, "no_comment", null);
    try expectWritten(try body(env, "src/a.ts", "helper", "{\n  const one = 1;\n  const two = one + one;\n  return x + two - one;\n}", true));
    try expectWritten(try rename(env, "src/a.ts", "helper", "worker", true));
    try expectWritten(try move(env, "src/c.ts", "lonely", "src/a.ts"));
    try expectWritten(try moveFile(env, "src/a.ts", "src/b.ts", true));
    const moved = try env.read("src/b.ts");
    try testing.expect(contains(moved, "// kept from before"));
    try testing.expect(contains(moved, "function worker"));
    try testing.expect(contains(moved, "function lonely"));
}

test "old text: a body that keeps a text the rule forbids is refused, and a deleted symbol beside it is not held to it" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ .{ .rel = "src/a.ts", .text = a_src }, .{ .rel = "src/c.ts", .text = c_src }, ignore });
    defer case.deinit();
    const env = &case.env;
    try enforce(case.repo.root_abs, "no_comment", null);
    const before = try capture(env);
    try expectRefused(env, try body(env, "src/a.ts", "old", "{\n  // kept from before\n  return z;\n}", true), before, "no_comment");
    const edits = .{.{ .file = try env.abs("src/c.ts"), .op = "delete", .symbol = "lonely", .hash = try env.hashOf("src/c.ts", "lonely") }};
    try expectWritten(try env.call("emetgate_try_batch", .{ .edits = edits, .message = message }, green, true));
}

const call_src = "function good(s) {\n  return s;\n}\nexport function main() {\n  return good(\"x\");\n}\n";
const call_query = "q:((call_expression function: (identifier) @f arguments: (arguments (string) @violation)) (#eq? @f \"bad\"))";

test "old text: a rename that turns a node it did not touch into a match is refused" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ .{ .rel = "src/a.ts", .text = call_src }, ignore });
    defer case.deinit();
    const env = &case.env;
    try enforce(case.repo.root_abs, call_query, null);
    const before = try capture(env);
    try expectRefused(env, try body(env, "src/a.ts", "main", "{\n  return bad(\"x\");\n}", true), before, "@violation");
    try expectRefused(env, try rename(env, "src/a.ts", "good", "bad", true), before, "@violation");
    try testing.expectEqualStrings(call_src, try env.read("src/a.ts"));
}

const doc_command = "cmd:findstr /m /l /c:evil docs\\n.md >nul && exit 1 || exit 0";

fn docHash(env: *Env) ![]const u8 {
    return env.arena().dupe(u8, &symbol.formatHash(symbol.hashOf("## Setup\n\nold\n")));
}

test "documents: a command rule runs on write_doc and on a document edit of a batch, and the syntax forms do not" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ .{ .rel = "docs/n.md", .text = note_src }, .{ .rel = "src/c.ts", .text = c_src }, ignore });
    defer case.deinit();
    const env = &case.env;
    try enforce(case.repo.root_abs, doc_command, "docs/");
    try enforce(case.repo.root_abs, "forbid:wicked", null);
    const before = try capture(env);
    const file = try env.abs("docs/n.md");
    try expectRefused(env, try env.call("emetgate_write_doc", .{ .file = file, .heading = "Setup", .hash = try docHash(env), .content = "## Setup\n\nevil\n", .message = message }, green, true), before, "findstr");
    const edits = .{.{ .file = file, .kind = "doc", .heading = "Setup", .hash = try docHash(env), .content = "## Setup\n\nevil\n" }};
    try expectRefused(env, try env.call("emetgate_try_batch", .{ .edits = edits, .message = message }, green, true), before, "findstr");
    try testing.expectEqualStrings(note_src, try env.read("docs/n.md"));
    try expectWritten(try env.call("emetgate_write_doc", .{ .file = file, .heading = "Setup", .hash = try docHash(env), .content = "## Setup\n\nwicked\n", .message = message }, green, true));
}

const main_src = "export function main(y) {\n  return y;\n}\n";
const forged = "export function main(y) {\n  const evil = y;\n  return evil;\n}\n";
const tag = "0123456789abcdef";

fn hexOf(env: *Env, bytes: []const u8) ![]const u8 {
    return env.arena().dupe(u8, &symbol.formatHash(symbol.hashOf(bytes)));
}

test "recovery: a hand-made intent record is not applied when the staged bytes, the blob or the commit do not tie together" {
    try skipOffWindows();
    const Tie = enum { commit, blob, hash };
    for ([_]Tie{ .commit, .blob, .hash }) |broken| {
        errdefer std.debug.print("broken tie: {t}\n", .{broken});
        var case: Plain = undefined;
        try case.init(&.{ .{ .rel = "src/a.ts", .text = main_src }, ignore });
        defer case.deinit();
        const env = &case.env;
        const root = case.repo.root_abs;
        try enforce(root, "forbid:evil", null);
        try case.repo.write("src/other.ts", "export const other = 1;\n");
        _ = try env.git(&.{ "add", "src/other.ts" });
        _ = try env.git(&.{ "commit", "-q", "-m", "second" });
        const parent = std.mem.trim(u8, try env.git(&.{ "rev-parse", "HEAD^" }), " \r\n");
        const head = std.mem.trim(u8, try env.head(), " \r\n");
        const branch = std.mem.trim(u8, try env.git(&.{ "symbolic-ref", "HEAD" }), " \r\n");
        const held = std.mem.trim(u8, try env.git(&.{ "rev-parse", "HEAD:src/a.ts" }), " \r\n");
        try case.repo.write(".emetgate/forged.txt", forged);
        const made = std.mem.trim(u8, try env.git(&.{ "hash-object", "-w", ".emetgate/forged.txt" }), " \r\n");

        try commit_intent.stage(testing.allocator, testing.io, root, tag, &.{forged});
        try commit_intent.write(testing.allocator, testing.io, root, tag, .{
            .commit = head,
            .base = parent,
            .branch = branch,
            .lock = "00" ** 32,
            .items = &.{.{
                .path = "src/a.ts",
                .mode = "100644",
                .blob = if (broken == .commit) made else held,
                .base = try hexOf(env, main_src),
                .new = try hexOf(env, if (broken == .hash) "something else\n" else forged),
            }},
        });
        if (commit_intent.recoverAll(testing.allocator, testing.io, root)) |report| {
            try testing.expectEqual(@as(usize, 0), report.written);
            try testing.expectEqual(@as(usize, 0), report.landed);
        } else |_| {}
        try testing.expectEqualStrings(main_src, try env.read("src/a.ts"));
        _ = try body(env, "src/a.ts", "main", "{\n  return y + 1;\n}", true);
        try testing.expect(!contains(try env.read("src/a.ts"), "evil"));
    }
}
