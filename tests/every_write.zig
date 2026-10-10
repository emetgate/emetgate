const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");
const fixture = @import("ts_fixture.zig");
const common = @import("commit_batch.zig");

const symbol = emetgate.symbol;
const memory = emetgate.memory;

const testing = std.testing;
const Plain = common.Plain;
const Env = common.Env;
const Reply = common.Reply;
const green = common.green;
const ignore = common.ignore;

pub const message = "refactor: one step";
const helper_src = "function helper(x) {\n  return x + 1;\n}\nexport function main(y) {\n  return helper(y) + helper(helper(y));\n}\n";
const evil_query = "q:((identifier) @violation (#eq? @violation \"evil\"))";

fn skipOffWindows() !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

pub fn enforce(root: []const u8, check: []const u8, where: ?[]const u8) !void {
    const id = try memory.remember(testing.allocator, testing.io, root, .project, "kept by the gate", true, check, where);
    testing.allocator.free(id);
}

pub const Before = struct {
    head: []const u8,
    listing: []const u8,
};

pub fn capture(env: *Env) !Before {
    return .{ .head = try env.head(), .listing = try env.git(&.{ "ls-files", "-s" }) };
}

pub fn expectRefused(env: *Env, reply: Reply, before: Before, check: []const u8) !void {
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try testing.expect(contains(reply.text, "rule_violation"));
    try testing.expect(contains(reply.text, check));
    try testing.expectEqualStrings(before.head, try env.head());
    try testing.expectEqualStrings("", try env.git(&.{ "status", "--porcelain" }));
    try testing.expectEqualStrings(before.listing, try env.git(&.{ "ls-files", "-s" }));
}

pub fn body(env: *Env, rel: []const u8, name: []const u8, text: []const u8, commit: bool) !Reply {
    const file = try env.abs(rel);
    const hash = try env.hashOf(rel, name);
    if (commit) return env.call("emetgate_try", .{ .file = file, .symbol = name, .hash = hash, .body = text, .message = message }, green, true);
    return env.call("emetgate_try", .{ .file = file, .symbol = name, .hash = hash, .body = text }, green, false);
}

pub fn rename(env: *Env, rel: []const u8, name: []const u8, new_name: []const u8, commit: bool) !Reply {
    const file = try env.abs(rel);
    const hash = try env.hashOf(rel, name);
    if (commit) return env.call("emetgate_rename", .{ .file = file, .symbol = name, .hash = hash, .new_name = new_name, .message = message }, green, true);
    return env.call("emetgate_rename", .{ .file = file, .symbol = name, .hash = hash, .new_name = new_name }, green, false);
}

pub fn move(env: *Env, rel: []const u8, name: []const u8, target: []const u8) !Reply {
    return env.call("emetgate_move", .{ .file = try env.abs(rel), .symbol = name, .hash = try env.hashOf(rel, name), .target_file = try env.abs(target), .message = message }, green, true);
}

pub fn moveFile(env: *Env, from: []const u8, to: []const u8, commit: bool) !Reply {
    const from_abs = try env.abs(from);
    const to_abs = try env.abs(to);
    const hash = try env.fileHash(from);
    if (commit) return env.call("emetgate_move_file", .{ .from = from_abs, .to = to_abs, .from_hash = hash, .message = message }, green, true);
    return env.call("emetgate_move_file", .{ .from = from_abs, .to = to_abs, .from_hash = hash }, green, false);
}

test "every write: a rename to a forbidden name is refused and nothing is written" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ .{ .rel = "src/a.ts", .text = helper_src }, ignore });
    defer case.deinit();
    const env = &case.env;
    try enforce(case.repo.root_abs, "forbid:evil", null);
    const before = try capture(env);
    try expectRefused(env, try body(env, "src/a.ts", "main", "{ const evil = 1; return evil; }", true), before, "forbid:evil");
    try expectRefused(env, try rename(env, "src/a.ts", "helper", "evilName", true), before, "forbid:evil");
    try testing.expectEqualStrings(helper_src, try env.read("src/a.ts"));
}

test "every write: a rename that creates an identifier a query rule forbids is refused" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ .{ .rel = "src/a.ts", .text = helper_src }, ignore });
    defer case.deinit();
    const env = &case.env;
    try enforce(case.repo.root_abs, evil_query, null);
    const before = try capture(env);
    try expectRefused(env, try body(env, "src/a.ts", "main", "{ let evil = y; return evil; }", true), before, "@violation");
    try expectRefused(env, try rename(env, "src/a.ts", "helper", "evil", true), before, "@violation");
    try testing.expectEqualStrings(helper_src, try env.read("src/a.ts"));
}

const lonely_src = "import { HELPER } from \"../util\";\nfunction lonely() {\n  return HELPER + 1;\n}\n";
const inner_src = "export function base() { return 9; }\nexport function touch() { return 0; }\n";

test "every write: a move whose derived import is a forbidden text is refused" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{
        .{ .rel = "src/util.ts", .text = "export const HELPER = 1;\n" },
        .{ .rel = "src/outside/a.ts", .text = lonely_src },
        .{ .rel = "src/deep/inner/t.ts", .text = inner_src },
        ignore,
    });
    defer case.deinit();
    const env = &case.env;
    try enforce(case.repo.root_abs, "forbid:../../util", null);
    const before = try capture(env);
    try expectRefused(env, try body(env, "src/deep/inner/t.ts", "touch", "{ const p = \"../../util\"; return p.length; }", true), before, "forbid:../../util");
    try expectRefused(env, try move(env, "src/outside/a.ts", "lonely", "src/deep/inner/t.ts"), before, "forbid:../../util");
    try testing.expectEqualStrings(inner_src, try env.read("src/deep/inner/t.ts"));
    try testing.expectEqualStrings(lonely_src, try env.read("src/outside/a.ts"));
}

const token_src = "export const X = \"networkidle-token\";\n";
const keep_src = "export function already() {\n  return 1;\n}\n";

test "every write: a file move into the scope of a rule it breaks is refused" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ .{ .rel = "src/outside/mod.ts", .text = token_src }, .{ .rel = "src/inside/keep.ts", .text = keep_src }, ignore });
    defer case.deinit();
    const env = &case.env;
    try enforce(case.repo.root_abs, "forbid:networkidle", "src/inside/");
    const before = try capture(env);
    try expectRefused(env, try body(env, "src/inside/keep.ts", "already", "{ return \"networkidle\"; }", true), before, "forbid:networkidle");
    try expectRefused(env, try moveFile(env, "src/outside/mod.ts", "src/inside/mod.ts", true), before, "forbid:networkidle");
    try testing.expect(case.repo.exists("src/outside/mod.ts"));
    try testing.expect(!case.repo.exists("src/inside/mod.ts"));
}

const b_src = "export const B = 1;\nexport function touch() {\n  return B;\n}\n";
const a_src = "import { B } from \"./b\";\nexport const A = B + 1;\n";

test "every write: a file move whose rewritten import is a forbidden text is refused" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ .{ .rel = "src/b.ts", .text = b_src }, .{ .rel = "src/a.ts", .text = a_src }, ignore });
    defer case.deinit();
    const env = &case.env;
    try enforce(case.repo.root_abs, "forbid:../b", null);
    const before = try capture(env);
    try expectRefused(env, try body(env, "src/b.ts", "touch", "{ const p = \"../b\"; return p.length; }", true), before, "forbid:../b");
    try expectRefused(env, try moveFile(env, "src/a.ts", "src/sub/a.ts", true), before, "forbid:../b");
    try testing.expectEqualStrings(a_src, try env.read("src/a.ts"));
    try testing.expect(!case.repo.exists("src/sub/a.ts"));
}

const commented_src = "export function g() {\n  // a banned comment\n  return 1;\n}\n";

test "every write: a file move that carries a comment into a no_comment scope is refused" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ .{ .rel = "src/outside/c.ts", .text = commented_src }, .{ .rel = "src/inside/keep.ts", .text = keep_src }, ignore });
    defer case.deinit();
    const env = &case.env;
    try enforce(case.repo.root_abs, "no_comment", "src/inside/");
    const before = try capture(env);
    try expectRefused(env, try body(env, "src/inside/keep.ts", "already", "{ // nope\n  return 2; }", true), before, "no_comment");
    try expectRefused(env, try moveFile(env, "src/outside/c.ts", "src/inside/c.ts", true), before, "no_comment");
    try testing.expect(case.repo.exists("src/outside/c.ts"));
    try testing.expect(!case.repo.exists("src/inside/c.ts"));
}

test "every write: without commits a rename and a file move that break a rule are refused the same way" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ .{ .rel = "src/a.ts", .text = helper_src }, .{ .rel = "src/outside/mod.ts", .text = token_src }, ignore });
    defer case.deinit();
    const env = &case.env;
    try enforce(case.repo.root_abs, "forbid:evil", null);
    try enforce(case.repo.root_abs, "forbid:networkidle", "src/inside/");
    const before = try capture(env);
    try expectRefused(env, try rename(env, "src/a.ts", "helper", "evilName", false), before, "forbid:evil");
    try expectRefused(env, try moveFile(env, "src/outside/mod.ts", "src/inside/mod.ts", false), before, "forbid:networkidle");
    try testing.expectEqualStrings(helper_src, try env.read("src/a.ts"));
    try testing.expect(!case.repo.exists("src/inside/mod.ts"));
}

const z_src = "export function main(y) {\n  const z = y;\n  return z;\n}\n";

fn nodeAddress(env: *Env, rel: []const u8, name: []const u8, wanted: []const u8) ![]const u8 {
    const listing = try env.call("emetgate_read_symbol", .{ .file = try env.abs(rel), .symbol = name, .nodes = true }, green, false);
    try testing.expect(!listing.is_error);
    const text = (try listing.field(env.arena(), "nodes")).?.string;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |candidate| {
        const bar = std.mem.indexOfScalar(u8, candidate, '|') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, candidate[bar + 1 ..], " "), wanted)) return candidate[0..bar];
    }
    return error.NodeNotListed;
}

test "every write: a forbidden text is refused through a symbol edit, a node edit and a batch insert" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ .{ .rel = "src/a.ts", .text = z_src }, ignore });
    defer case.deinit();
    const env = &case.env;
    try enforce(case.repo.root_abs, "forbid:evil", null);
    const before = try capture(env);
    const file = try env.abs("src/a.ts");
    const address = try nodeAddress(env, "src/a.ts", "main", "const z = y;");
    try expectRefused(env, try env.call("emetgate_try", .{ .file = file, .node = address, .text = "const z = \"evil\";", .message = message }, green, true), before, "forbid:evil");
    const edits = .{.{ .file = file, .symbol = "evilFn", .hash = "absent", .body = "export function evilFn() { return 1; }" }};
    try expectRefused(env, try env.call("emetgate_try_batch", .{ .edits = edits, .message = message }, green, true), before, "forbid:evil");
    try expectRefused(env, try body(env, "src/a.ts", "main", "{ const evil = y; return evil; }", true), before, "forbid:evil");
    try testing.expectEqualStrings(z_src, try env.read("src/a.ts"));
}

const thing_src = "function doThing() {\n  return \"networkidle-here\";\n}\nexport function keep() {\n  return 1;\n}\n";

test "every write: a symbol move into the scope of a rule it breaks is refused" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ .{ .rel = "src/outside/a.ts", .text = thing_src }, .{ .rel = "src/inside/b.ts", .text = keep_src }, ignore });
    defer case.deinit();
    const env = &case.env;
    try enforce(case.repo.root_abs, "forbid:networkidle", "src/inside/");
    const before = try capture(env);
    try expectRefused(env, try move(env, "src/outside/a.ts", "doThing", "src/inside/b.ts"), before, "forbid:networkidle");
    try testing.expectEqualStrings(thing_src, try env.read("src/outside/a.ts"));
    try testing.expectEqualStrings(keep_src, try env.read("src/inside/b.ts"));
}

test "every write: a frozen path is refused through a symbol edit, a rename and a file move, with and without commits" {
    try skipOffWindows();
    for ([_]bool{ true, false }) |commit| {
        var case: Plain = undefined;
        try case.init(&.{ .{ .rel = "src/a.ts", .text = helper_src }, ignore });
        defer case.deinit();
        const env = &case.env;
        try enforce(case.repo.root_abs, "frozen", "src/a.ts");
        const before = try capture(env);
        try expectRefused(env, try body(env, "src/a.ts", "main", "{ return 0; }", commit), before, "frozen");
        try expectRefused(env, try rename(env, "src/a.ts", "helper", "helper2", commit), before, "frozen");
        try expectRefused(env, try moveFile(env, "src/a.ts", "src/moved.ts", commit), before, "frozen");
        try testing.expectEqualStrings(helper_src, try env.read("src/a.ts"));
        try testing.expect(!case.repo.exists("src/moved.ts"));
    }
}

test "every write: a message rule refuses the commit of a symbol edit, a rename and a file move" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ .{ .rel = "src/a.ts", .text = helper_src }, ignore });
    defer case.deinit();
    const env = &case.env;
    try enforce(case.repo.root_abs, "message:forbid:WIP", null);
    const before = try capture(env);
    const file = try env.abs("src/a.ts");
    try expectRefused(env, try env.call("emetgate_try", .{ .file = file, .symbol = "main", .hash = try env.hashOf("src/a.ts", "main"), .body = "{ return 0; }", .message = "WIP stuff" }, green, true), before, "message:forbid:WIP");
    try expectRefused(env, try env.call("emetgate_rename", .{ .file = file, .symbol = "helper", .hash = try env.hashOf("src/a.ts", "helper"), .new_name = "helper2", .message = "WIP rename" }, green, true), before, "message:forbid:WIP");
    try expectRefused(env, try env.call("emetgate_move_file", .{ .from = file, .to = try env.abs("src/b.ts"), .from_hash = try env.fileHash("src/a.ts"), .message = "WIP move" }, green, true), before, "message:forbid:WIP");
    try testing.expectEqualStrings(helper_src, try env.read("src/a.ts"));
    try testing.expect(!case.repo.exists("src/b.ts"));
}

const note_src = "# Title\n\nbody text\n";

test "every write: write_doc refuses a source file and a frozen document" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&.{ .{ .rel = "src/a.ts", .text = keep_src }, .{ .rel = "docs/note.md", .text = note_src }, ignore });
    defer case.deinit();
    const env = &case.env;
    try enforce(case.repo.root_abs, "frozen", "docs/note.md");
    try enforce(case.repo.root_abs, "forbid:evil", null);
    const before = try capture(env);
    const source = try env.call("emetgate_write_doc", .{ .file = try env.abs("src/a.ts"), .hash = try env.fileHash("src/a.ts"), .line_start = std.json.Value{ .integer = 1 }, .line_end = std.json.Value{ .integer = 3 }, .content = "export function already() {\n  const evil = 1; return evil;\n}\n", .message = message }, green, true);
    errdefer std.debug.print("{s}\n", .{source.text});
    try testing.expect(source.is_error);
    try testing.expect(contains(source.text, "UseSymbolToolsForSource"));
    const hash = try env.arena().dupe(u8, &symbol.formatHash(symbol.hashOf(note_src)));
    try expectRefused(env, try env.call("emetgate_write_doc", .{ .file = try env.abs("docs/note.md"), .heading = "Title", .hash = hash, .content = "# Title\n\nevil body\n", .message = message }, green, true), before, "frozen");
    try testing.expectEqualStrings(note_src, try env.read("docs/note.md"));
    try testing.expectEqualStrings(keep_src, try env.read("src/a.ts"));
}
