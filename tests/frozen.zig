const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");
const fixture = @import("ts_fixture.zig");
const common = @import("commit_batch.zig");
const rename_case = @import("rename_tool.zig");
const move_case = @import("move_tool.zig");
const move_file_case = @import("move_file_tool.zig");

const symbol = emetgate.symbol;
const memory = emetgate.memory;
const rules = emetgate.rules;
const checks = emetgate.checks;
const rule_command = emetgate.rule_command;

const testing = std.testing;
const Plain = common.Plain;
const Env = common.Env;
const Reply = common.Reply;
const green = common.green;
const ignore = common.ignore;

const util_src = "export function add(a: number, b: number): number {\n  return a + b;\n}\n";
const other_src = "export function sub(a: number, b: number): number {\n  return a - b;\n}\n";
const clamp_src = "export function clamp(x: number): number {\n  if (x < 0) {\n    return 0;\n  }\n  return x;\n}\n";
const notes_src = "# Notes\n\n## Setup\n\nold\n";
const swapped = "{\n  return b + a;\n}";
const message = "fix: change";
const files = [_]fixture.File{
    .{ .rel = "src/util.ts", .text = util_src },
    .{ .rel = "src/other.ts", .text = other_src },
    .{ .rel = "src/math.ts", .text = clamp_src },
    .{ .rel = "src/old.ts", .text = "export const unused = 1;\n" },
    .{ .rel = "notes.md", .text = notes_src },
    .{ .rel = "docs/guide.md", .text = notes_src },
    ignore,
};

fn skipOffWindows() !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn freeze(root: []const u8, where: ?[]const u8) !void {
    const id = try memory.remember(testing.allocator, testing.io, root, .project, "not through the gate", true, checks.frozen_name, where);
    testing.allocator.free(id);
}

fn expectFrozen(env: *Env, reply: Reply, before: []const u8, path: []const u8) !void {
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try testing.expect(contains(reply.text, "rule_violation"));
    try testing.expect(contains(reply.text, "\"check\":\"frozen\""));
    try testing.expect(contains(reply.text, path));
    try testing.expectEqualStrings(before, try env.head());
    try testing.expectEqualStrings("", try env.git(&.{ "status", "--porcelain" }));
}

fn expectLanded(env: *Env, reply: Reply, before: []const u8) !void {
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(!reply.is_error);
    try testing.expectEqualStrings(before, try env.git(&.{ "rev-parse", "HEAD^" }));
}

fn swap(env: *Env, rel: []const u8, name: []const u8, commit: bool) !Reply {
    const file = try env.abs(rel);
    const hash = try env.hashOf(rel, name);
    if (commit) return env.call("emetgate_try", .{ .file = file, .symbol = name, .hash = hash, .body = swapped, .message = message }, green, true);
    return env.call("emetgate_try", .{ .file = file, .symbol = name, .hash = hash, .body = swapped }, green, false);
}

fn docCall(env: *Env, rel: []const u8, commit: bool) !Reply {
    const hash = try env.arena().dupe(u8, &symbol.formatHash(symbol.hashOf("## Setup\n\nold\n")));
    const file = try env.abs(rel);
    if (commit) return env.call("emetgate_write_doc", .{ .file = file, .heading = "Setup", .hash = hash, .content = "## Setup\n\nnew\n", .message = message }, green, true);
    return env.call("emetgate_write_doc", .{ .file = file, .heading = "Setup", .hash = hash, .content = "## Setup\n\nnew\n" }, green, false);
}

test "frozen: a symbol edit of a frozen file is refused with and without commits, and a file outside the scope is written" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    try freeze(case.repo.root_abs, "src/util.ts");
    const before = try env.head();

    try expectFrozen(env, try swap(env, "src/util.ts", "add", true), before, "src/util.ts");
    try expectFrozen(env, try swap(env, "src/util.ts", "add", false), before, "src/util.ts");
    try testing.expectEqualStrings(util_src, try env.read("src/util.ts"));
    try expectLanded(env, try swap(env, "src/other.ts", "sub", true), before);
}

test "frozen: with no scope every path is frozen, and with no such rule nothing is" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    const before = try env.head();
    try expectLanded(env, try swap(env, "src/other.ts", "sub", true), before);
    const after = try env.head();
    try freeze(case.repo.root_abs, null);
    try expectFrozen(env, try swap(env, "src/util.ts", "add", true), after, "src/util.ts");
    try expectFrozen(env, try docCall(env, "notes.md", true), after, "notes.md");
}

test "frozen: a node edit of a frozen file is refused" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    const file = try env.abs("src/math.ts");
    const listing = try env.call("emetgate_read_symbol", .{ .file = file, .symbol = "clamp", .nodes = true }, green, false);
    try testing.expect(!listing.is_error);
    const text = (try listing.field(env.arena(), "nodes")).?.string;
    var address: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |candidate| {
        const bar = std.mem.indexOfScalar(u8, candidate, '|') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, candidate[bar + 1 ..], " "), "return x;")) address = candidate[0..bar];
    }
    try freeze(case.repo.root_abs, "src/math.ts");
    const before = try env.head();
    try expectFrozen(env, try env.call("emetgate_try", .{ .file = file, .node = address.?, .text = "return Math.max(x, 0);", .message = message }, green, true), before, "src/math.ts");
    try testing.expectEqualStrings(clamp_src, try env.read("src/math.ts"));
}

fn batchCall(env: *Env, commit: bool) !Reply {
    const edits = .{
        .{ .file = try env.abs("src/other.ts"), .symbol = "sub", .hash = try env.hashOf("src/other.ts", "sub"), .body = swapped },
        .{ .file = try env.abs("src/old.ts"), .op = "delete", .hash = try env.fileHash("src/old.ts") },
    };
    if (commit) return env.call("emetgate_try_batch", .{ .edits = edits, .message = message }, green, true);
    return env.call("emetgate_try_batch", .{ .edits = edits }, green, false);
}

test "frozen: a batch that deletes a frozen file is refused whole, and the same batch lands when the scope is elsewhere" {
    try skipOffWindows();
    {
        var case: Plain = undefined;
        try case.init(&files);
        defer case.deinit();
        const env = &case.env;
        try freeze(case.repo.root_abs, "src/old.ts");
        const before = try env.head();
        try expectFrozen(env, try batchCall(env, true), before, "src/old.ts");
        try expectFrozen(env, try batchCall(env, false), before, "src/old.ts");
        try testing.expect(case.repo.exists("src/old.ts"));
        try testing.expectEqualStrings(other_src, try env.read("src/other.ts"));
    }
    {
        var case: Plain = undefined;
        try case.init(&files);
        defer case.deinit();
        const env = &case.env;
        try freeze(case.repo.root_abs, "docs/");
        const before = try env.head();
        try expectLanded(env, try batchCall(env, true), before);
        try testing.expect(!case.repo.exists("src/old.ts"));
    }
}

test "frozen: a batch whose doc edit is in a frozen directory is refused" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    try freeze(case.repo.root_abs, "docs/");
    const before = try env.head();
    const hash = try env.arena().dupe(u8, &symbol.formatHash(symbol.hashOf("## Setup\n\nold\n")));
    const edits = .{
        .{ .file = try env.abs("src/other.ts"), .symbol = "sub", .hash = try env.hashOf("src/other.ts", "sub"), .body = swapped },
        .{ .file = try env.abs("docs/guide.md"), .kind = "doc", .heading = "Setup", .hash = hash, .content = "## Setup\n\nnew\n" },
    };
    try expectFrozen(env, try env.call("emetgate_try_batch", .{ .edits = edits, .message = message }, green, true), before, "docs/guide.md");
    try testing.expectEqualStrings(other_src, try env.read("src/other.ts"));
}

test "frozen: write_doc on a frozen file is refused with and without commits, and another doc is written" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    try freeze(case.repo.root_abs, "notes.md");
    const before = try env.head();
    try expectFrozen(env, try docCall(env, "notes.md", true), before, "notes.md");
    try expectFrozen(env, try docCall(env, "notes.md", false), before, "notes.md");
    try testing.expectEqualStrings(notes_src, try env.read("notes.md"));
    try expectLanded(env, try docCall(env, "docs/guide.md", true), before);
}

const Served = struct {
    case: rename_case.Case,
    env: Env,

    fn deinit(self: *Served) void {
        self.env.deinit();
        self.case.deinit();
    }
};

test "frozen: a rename that would rewrite a frozen file in another module is refused" {
    try skipOffWindows();
    var served: Served = undefined;
    try served.case.init(&.{ .{ .rel = "src/a.ts", .text = rename_case.a_src }, .{ .rel = "src/b.ts", .text = rename_case.b_src }, .{ .rel = "src/c.ts", .text = rename_case.c_src }, ignore }, true);
    served.env = Env.init(&served.case.repo, served.case.runtime, &served.case.session);
    defer served.deinit();
    const env = &served.env;
    try freeze(served.case.repo.root_abs, "src/c.ts");
    const before = try env.head();
    try served.case.plan(&rename_case.all_locations);
    const reply = try env.call("emetgate_rename", .{ .file = try env.abs("src/a.ts"), .symbol = "add", .hash = try env.hashOf("src/a.ts", "add"), .new_name = "sum", .interface_change = true, .message = message }, green, true);
    try expectFrozen(env, reply, before, "src/c.ts");
    try testing.expectEqualStrings(rename_case.a_src, try env.read("src/a.ts"));
}

fn moveCall(served: *Served) !Reply {
    const env = &served.env;
    try move_case.plan(&served.case, &move_case.area_refs);
    return env.call("emetgate_move", .{ .file = try env.abs("src/math.ts"), .symbol = "area", .hash = try env.hashOf("src/math.ts", "area"), .target_file = try env.abs("src/shapes.ts"), .interface_change = true, .message = message }, green, true);
}

test "frozen: a move is refused when the file it leaves or the file it enters is frozen" {
    try skipOffWindows();
    for ([_][]const u8{ "src/math.ts", "src/shapes.ts" }) |frozen_path| {
        var served: Served = undefined;
        try move_case.initMath(&served.case, move_case.math_src, move_case.app_src, &.{ignore}, true);
        served.env = Env.init(&served.case.repo, served.case.runtime, &served.case.session);
        defer served.deinit();
        try freeze(served.case.repo.root_abs, frozen_path);
        const before = try served.env.head();
        try expectFrozen(&served.env, try moveCall(&served), before, frozen_path);
        try testing.expectEqualStrings(move_case.math_src, try served.env.read("src/math.ts"));
    }
}

fn moveFileCall(served: *Served) !Reply {
    const env = &served.env;
    try move_file_case.plan(&served.case, &move_file_case.changes);
    return env.call("emetgate_move_file", .{ .from = try env.abs("src/util.ts"), .to = try env.abs("src/core/tools/util.ts"), .from_hash = try env.fileHash("src/util.ts"), .message = message }, green, true);
}

test "frozen: a file move out of a frozen path and a file move into a frozen directory are both refused" {
    try skipOffWindows();
    const cases = [_]struct { scope: []const u8, named: []const u8 }{
        .{ .scope = "src/util.ts", .named = "src/util.ts" },
        .{ .scope = "src/core/", .named = "src/core/tools/util.ts" },
    };
    for (cases) |one| {
        var served: Served = undefined;
        try move_file_case.initFiles(&served.case, &.{ignore}, true);
        served.env = Env.init(&served.case.repo, served.case.runtime, &served.case.session);
        defer served.deinit();
        try freeze(served.case.repo.root_abs, one.scope);
        const before = try served.env.head();
        try expectFrozen(&served.env, try moveFileCall(&served), before, one.named);
        try testing.expect(served.case.repo.exists("src/util.ts"));
        try testing.expect(!served.case.repo.exists("src/core/tools/util.ts"));
    }
}

fn runRule(root: []const u8, args: []const [:0]const u8) !void {
    const request = rule_command.parse(args) orelse return error.UsageRefused;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer err_out.deinit();
    try rule_command.run(testing.allocator, testing.io, root, request, &out.writer, &err_out.writer);
}

test "frozen: the rule command adds it with a scope, takes no argument and no added form, and the gate then refuses the path" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    const root = case.repo.root_abs;
    try testing.expectError(error.UnexpectedCheckArgument, runRule(root, &.{ "add", "config", "--check", "frozen:x", "--in", "src/util.ts", "--enforce" }));
    try testing.expectError(error.UnknownCheck, runRule(root, &.{ "add", "config", "--check", "added:frozen", "--in", "src/util.ts", "--enforce" }));
    try runRule(root, &.{ "add", "the lint config is edited by hand", "--check", "frozen", "--in", "src/util.ts", "--enforce" });
    const before = try env.head();
    try expectFrozen(env, try swap(env, "src/util.ts", "add", true), before, "src/util.ts");
}

test "frozen: an advisory rule refuses nothing" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    const id = try memory.remember(testing.allocator, testing.io, case.repo.root_abs, .project, "only a note", false, checks.frozen_name, "src/util.ts");
    testing.allocator.free(id);
    const before = try env.head();
    try expectLanded(env, try swap(env, "src/util.ts", "add", true), before);
}

test "frozen: from a ledger committed to the repository it is applied without --allow-repo-memory, as the other checks that run nothing are" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;
    try freeze(case.repo.root_abs, "src/util.ts");
    _ = try env.git(&.{ "add", "-f", "--", ".emetgate/ledger.ndjson" });
    _ = try env.git(&.{ "commit", "-q", "-m", "ship a ledger" });
    const before = try env.head();
    const reply = try swap(env, "src/util.ts", "add", true);
    errdefer std.debug.print("{s}\n", .{reply.text});
    try testing.expect(reply.is_error);
    try testing.expect(contains(reply.text, "rule_violation"));
    try testing.expect(!contains(reply.text, "UntrustedRepoMemory"));
    try testing.expectEqualStrings(before, try env.head());
}

test "frozen: scan and the code gate skip it, and it is listed among the rules of the file it covers" {
    try skipOffWindows();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    try freeze(case.repo.root_abs, "src/util.ts");
    const adopted = try rules.adoptedFor(testing.allocator, testing.io, case.repo.root_abs, "src/util.ts");
    defer adopted.deinit();
    try testing.expectEqual(@as(usize, 1), adopted.items.len);
    try testing.expectEqualStrings("frozen", adopted.items[0].check.?);
    const elsewhere = try rules.adoptedFor(testing.allocator, testing.io, case.repo.root_abs, "src/other.ts");
    defer elsewhere.deinit();
    try testing.expectEqual(@as(usize, 0), elsewhere.items.len);
    try testing.expect(try rules.evaluateFrozen(testing.allocator, &.{.{ .id = "r", .check = "frozen", .where = "src/util.ts" }}, &.{ "src\\other.ts", "docs/guide.md" }) == .ok);
    const gated = try rules.evaluateFrozen(testing.allocator, &.{.{ .id = "r", .check = "frozen", .where = "src/" }}, &.{ "src\\other.ts", "docs/guide.md", "SRC/util.ts" });
    defer gated.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), gated.violated.violations.len);
    try testing.expectEqualStrings("src/other.ts", gated.violated.violations[0].file);
}

test "frozen: the code rules that read a tree take a frozen rule as nothing to check" {
    const runtime = try emetgate.runtime.Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    const snapshot = try emetgate.loader.Snapshot.fromSource(runtime, emetgate.lang_registry.forPath("src/util.ts").?, try testing.allocator.dupe(u8, util_src));
    defer snapshot.destroy();
    const span: symbol.Span = .{ .start = 0, .end = @intCast(util_src.len) };
    const gated = try rules.evaluate(testing.allocator, "src/util.ts", snapshot.profile, snapshot.tree, span, &.{.{ .id = "r", .check = "frozen", .where = "src/util.ts" }});
    try testing.expect(gated == .ok);
    try emetgate.checks.validateStatic(testing.allocator, "frozen");
}
