const std = @import("std");
const emetgate = @import("emetgate");
const map_tools = emetgate.map_tools;
const fact_file = emetgate.fact_file;
const test_util = emetgate.test_util;
const git_fixture = @import("git_fixture.zig");

const testing = std.testing;
const Value = std.json.Value;

const File = struct { path: []const u8, data: []const u8 };

const invoice_ts =
    \\import { taxRate } from './tax';
    \\
    \\/**
    \\ * Computes the invoice total with tax.
    \\ * @param lines the invoice lines
    \\ */
    \\export function invoiceTotal(lines: number[]): number {
    \\    // sum every invoice line first
    \\    let sum = 0;
    \\
    \\    for (const line of lines) {
    \\        // skip negative invoice lines
    \\        if (line < 0) {
    \\            continue;
    \\        }
    \\        sum += line;
    \\    }
    \\    /* block comment that
    \\       spans two lines */
    \\    const rate = taxRate(sum);
    \\
    \\    return sum + sum * rate;
    \\}
    \\
    \\export function invoiceDiscount(total: number): number {
    \\    // a plain body comment about the invoice discount
    \\    const cut = total * 0.1;
    \\
    \\    /* a block comment about the discount */
    \\    return total - cut;
    \\}
    \\
    \\export function invoiceReport(lines: number[]): string {
    \\    // build the invoice report
    \\
    \\    /** @type {string[]} */
    \\    const rows = [];
    \\    // formats one invoice line
    \\    function formatInvoiceLine(line: number): string {
    \\        return `invoice line ${line}`;
    \\    }
    \\    for (const line of lines) {
    \\        rows.push(formatInvoiceLine(line));
    \\    }
    \\    return rows.join('\n');
    \\}
    \\
;

const tax_ts =
    \\/** Rate of tax for an invoice sum. */
    \\export function taxRate(sum: number): number {
    \\    // high invoice sums pay more tax
    \\    if (sum > 1000) {
    \\        return 0.2;
    \\    }
    \\    return 0.1;
    \\}
    \\
;

const fixture_files = [_]File{
    .{ .path = "src/billing/invoice.ts", .data = invoice_ts },
    .{ .path = "src/billing/tax.ts", .data = tax_ts },
};

fn git(root: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(testing.allocator);
    try argv.append(testing.allocator, try git_fixture.git());
    try argv.appendSlice(testing.allocator, args);
    const result = try emetgate.bounded_run.run(testing.allocator, testing.io, .{ .argv = argv.items, .cwd = .{ .path = root } });
    testing.allocator.free(result.stdout);
    testing.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitFailed,
        else => return error.GitFailed,
    }
}

fn expectHas(text: []const u8, part: []const u8) !void {
    if (std.mem.indexOf(u8, text, part) != null) return;
    std.debug.print("missing: {s}\n--- reply ---\n{s}\n", .{ part, text });
    return error.TestExpectedEqual;
}

fn expectLacks(text: []const u8, part: []const u8) !void {
    if (std.mem.indexOf(u8, text, part) == null) return;
    std.debug.print("unexpected: {s}\n--- reply ---\n{s}\n", .{ part, text });
    return error.TestExpectedEqual;
}

const Fixture = struct {
    runtime: *emetgate.runtime.Runtime,
    tmp: std.testing.TmpDir,
    base: [:0]u8,
    root: []u8,
    store_path: []u8,
    session: *map_tools.Session,

    fn open(files: []const File) !Fixture {
        const runtime = try test_util.openRuntime();
        var tmp = testing.tmpDir(.{});
        try tmp.dir.createDirPath(testing.io, "repo");
        for (files) |f| {
            const sub = try std.fmt.allocPrint(testing.allocator, "repo/{s}", .{f.path});
            defer testing.allocator.free(sub);
            if (std.fs.path.dirnamePosix(sub)) |d| try tmp.dir.createDirPath(testing.io, d);
            try tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = f.data });
        }
        const base = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        const root = try std.fmt.allocPrint(testing.allocator, "{s}\\repo", .{base});
        try git_fixture.initRepo(root);
        try git(root, &.{ "add", "." });
        const store_path = try std.fmt.allocPrint(testing.allocator, "{s}\\store\\facts.v{d}", .{ base, fact_file.version });
        const session = try map_tools.Session.create(testing.allocator, testing.io, runtime, root);
        session.store_override = store_path;
        try session.build();
        return .{ .runtime = runtime, .tmp = tmp, .base = base, .root = root, .store_path = store_path, .session = session };
    }

    fn close(self: *Fixture) void {
        self.session.destroy();
        testing.allocator.free(self.store_path);
        testing.allocator.free(self.root);
        testing.allocator.free(self.base);
        self.tmp.cleanup();
        test_util.closeRuntime(self.runtime);
    }

    fn call(self: *Fixture, arena: std.mem.Allocator, tool: enum { explore, evidence }, json: []const u8) ![]const u8 {
        const args = try std.json.parseFromSliceLeaky(Value, arena, json, .{});
        const result = switch (tool) {
            .explore => try self.session.explore(testing.allocator, args),
            .evidence => try self.session.evidenceTool(testing.allocator, args),
        };
        defer testing.allocator.free(result.text);
        try testing.expect(!result.is_error);
        return arena.dupe(u8, result.text);
    }
};

const explore_args = "{\"question\":\"how is the invoice discount and tax report computed\",\"names\":[\"invoiceTotal\"]}";
const evidence_args = "{\"names\":[\"invoiceDiscount\",\"taxRate\"]}";

fn bigFixture() ![]const File {
    var text: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer text.deinit();
    var n: usize = 0;
    while (n < 120) : (n += 1) {
        try text.writer.print(
            \\export function ledgerInvoiceStep{d}(ledger: number[], invoice: number): number {{
            \\    // fold the invoice into the ledger, step {d}
            \\    let total = invoice;
            \\
            \\    for (const entry of ledger) {{
            \\        if (entry > {d}) {{
            \\            total += entry * {d};
            \\        }} else {{
            \\            total -= entry;
            \\        }}
            \\    }}
            \\    return total;
            \\}}
            \\
            \\
        , .{ n, n, n, n });
    }
    const files = try testing.allocator.alloc(File, 1);
    files[0] = .{ .path = "src/ledger/steps.ts", .data = try text.toOwnedSlice() };
    return files;
}

fn freeFixture(files: []const File) void {
    for (files) |f| testing.allocator.free(f.data);
    testing.allocator.free(files);
}

fn shownOnce(path: []const u8, start: u32, end: u32, hash: emetgate.facts.Hash) bool {
    _ = start;
    _ = end;
    _ = hash;
    return std.mem.eql(u8, path, "src/billing/tax.ts");
}

test "explore dense: without the flag explore and evidence reply byte for byte as before" {
    var f = try Fixture.open(&fixture_files);
    defer f.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(map_tools.ExploreMode.full, f.session.explore_mode);
    const explore_expected = @embedFile("fixtures/explore_dense/full_explore.txt");
    try testing.expectEqualStrings(explore_expected, try f.call(arena, .explore, explore_args));
    try testing.expectEqualStrings(explore_expected, try f.call(arena, .explore, explore_args));
    try testing.expectEqualStrings(@embedFile("fixtures/explore_dense/full_evidence.txt"), try f.call(arena, .evidence, evidence_args));
}

test "explore dense: the first reply of a session stays within 20,000 characters and later ones within 8,000" {
    const files = try bigFixture();
    defer freeFixture(files);
    var f = try Fixture.open(files);
    defer f.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = "{\"question\":\"how does a ledger invoice step fold an entry into the total\"}";

    const full = try f.call(arena, .explore, args);
    try testing.expect(full.len > map_tools.dense_first_budget);

    f.session.explore_mode = .dense;
    f.session.explore_calls = 0;
    try testing.expectEqual(map_tools.dense_first_budget, f.session.replyBudget());
    const first = try f.call(arena, .explore, args);
    try testing.expect(first.len <= map_tools.dense_first_budget);
    try testing.expect(first.len > map_tools.dense_later_budget);
    try expectHas(first, map_tools.dense_note);
    try expectHas(first, "-- closure\n");

    try testing.expectEqual(map_tools.dense_later_budget, f.session.replyBudget());
    const later = try f.call(arena, .explore, args);
    try testing.expect(later.len <= map_tools.dense_later_budget);
    try testing.expect(later.len > map_tools.dense_later_budget / 2);
    const again = try f.call(arena, .explore, args);
    try testing.expect(again.len <= map_tools.dense_later_budget);
}

test "explore dense: ranked code loses body comments, blank lines and indentation; doc comments, JSDoc and named definitions stay verbatim" {
    var f = try Fixture.open(&fixture_files);
    defer f.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    f.session.explore_mode = .dense;
    const text = try f.call(arena, .explore, explore_args);

    try testing.expect(std.mem.startsWith(u8, text, map_tools.dense_note));
    // Named: verbatim and unmarked, every comment and indent kept.
    try expectHas(text, "src/billing/invoice.ts:7 invoiceTotal\n7 export function invoiceTotal(lines: number[]): number {\n8     // sum every invoice line first\n9     let sum = 0;\n11     for (const line of lines) {\n12         // skip negative invoice lines\n");
    try expectHas(text, "18     /* block comment that\n19        spans two lines */\n");
    // Ranked: marked dense, body comments and blank lines dropped, one space per level.
    try expectHas(text, "src/billing/invoice.ts:25 invoiceDiscount [dense]\n25 export function invoiceDiscount(total: number): number {\n27  const cut = total * 0.1;\n30  return total - cut;\n31 }\n");
    try expectHas(text, "src/billing/invoice.ts:33 invoiceReport [dense]\n33 export function invoiceReport(lines: number[]): string {\n36  /** @type {string[]} */\n37  const rows = [];\n38  // formats one invoice line\n39  function formatInvoiceLine(line: number): string {\n40   return `invoice line ${line}`;\n41  }\n");
    try expectHas(text, "src/billing/tax.ts:2 taxRate [dense]\n2 export function taxRate(sum: number): number {\n4  if (sum > 1000) {\n5   return 0.2;\n");
    try expectLacks(text, "build the invoice report");
    try expectLacks(text, "high invoice sums pay more tax");
    try expectLacks(text, "plain body comment");
    try expectLacks(text, "a block comment about the discount");
    try expectHas(text, "-- closure\n");
}

test "explore dense: the seen seam names an unchanged body in one line instead of sending it" {
    var f = try Fixture.open(&fixture_files);
    defer f.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    f.session.seen = shownOnce;
    const text = try f.call(arena, .explore, explore_args);
    try expectHas(text, "src/billing/tax.ts:2 taxRate (already shown, unchanged)\n");
    try expectLacks(text, "return 0.2;");
    try expectHas(text, "src/billing/invoice.ts:25 invoiceDiscount\n");

    f.session.explore_mode = .dense;
    const dense = try f.call(arena, .explore, explore_args);
    try expectHas(dense, "src/billing/tax.ts:2 taxRate (already shown, unchanged)\n");
    try expectLacks(dense, "return 0.2;");
}

test "explore dense: the serve flag picks the mode and refuses an unknown or repeated value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const none = (try map_tools.splitExploreMode(arena, &[_][]const u8{ "--commit", "--compact" })).?;
    try testing.expectEqual(map_tools.ExploreMode.full, none.mode);
    try testing.expectEqual(@as(usize, 2), none.rest.len);
    const dense = (try map_tools.splitExploreMode(arena, &[_][]const u8{ "--commit", "--explore-mode", "dense", "--compact" })).?;
    try testing.expectEqual(map_tools.ExploreMode.dense, dense.mode);
    try testing.expectEqualStrings("--commit", dense.rest[0]);
    try testing.expectEqualStrings("--compact", dense.rest[1]);
    try testing.expect((try map_tools.splitExploreMode(arena, &[_][]const u8{ "--explore-mode", "sparse" })) == null);
    try testing.expect((try map_tools.splitExploreMode(arena, &[_][]const u8{"--explore-mode"})) == null);
    try testing.expect((try map_tools.splitExploreMode(arena, &[_][]const u8{ "--explore-mode", "full", "--explore-mode", "dense" })) == null);
    try testing.expect(emetgate.server.parsePolicy(dense.rest) != null);
}
