//! The reply contract test: every served read tool, on a fixture built to
//! break unbounded replies (a 20 MB log, a minified file, a 5,000-file tree, a
//! big JSON and a big Markdown file), answers within its budget from
//! reply_contract, and every reply that leaves something out ends with the
//! standard trailer whose call returns the next part.
//!
//! The case table is data: a read-only tool served in tools/list without a
//! case here fails the test, so a new read tool must be added to it.
const std = @import("std");
const git_fixture = @import("git_fixture.zig");
const server = @import("emetgate").server;
const reply_contract = @import("emetgate").reply_contract;
const agent_ledger = @import("emetgate").agent_ledger;
const Runtime = @import("emetgate").runtime.Runtime;

const testing = std.testing;
const Value = std.json.Value;

const Case = struct {
    tool: []const u8,
    /// JSON arguments; `@/` stands for the fixture root and `$H` for the
    /// handle of a stashed 500 KB reply.
    args: []const u8,
    budget: reply_contract.Tool,
    /// The fixture makes this reply leave something out.
    cut: bool,
    /// False only for a tool whose bound is owned by another change; the case
    /// stays listed so that the table names every read tool.
    enforced: bool = true,
};

const cases = [_]Case{
    .{ .tool = "emetgate_read_file", .args = "{\"file\":\"@/huge.log\",\"line_start\":1,\"line_end\":400000}", .budget = .read_file, .cut = true },
    .{ .tool = "emetgate_read_file", .args = "{\"file\":\"@/huge.log\"}", .budget = .read_file, .cut = true },
    .{ .tool = "emetgate_read_file", .args = "{\"file\":\"@/min.js\",\"line_start\":1,\"line_end\":1}", .budget = .read_file, .cut = true },
    .{ .tool = "emetgate_read_file", .args = "{\"file\":\"@/min.js\"}", .budget = .read_file, .cut = true },
    .{ .tool = "emetgate_read_file", .args = "{\"file\":\"@/min.js\",\"raw\":true}", .budget = .read_file, .cut = true },
    .{ .tool = "emetgate_read_file", .args = "{\"file\":\"@/big.ts\"}", .budget = .read_file, .cut = true },
    .{ .tool = "emetgate_read_file", .args = "{\"file\":\"@/big.json\"}", .budget = .read_file, .cut = true },
    .{ .tool = "emetgate_read_file", .args = "{\"file\":\"@/big.json\",\"pointer\":\"\"}", .budget = .read_file, .cut = true },
    .{ .tool = "emetgate_read_file", .args = "{\"file\":\"@/min.json\",\"pointer\":\"\"}", .budget = .read_file, .cut = true },
    .{ .tool = "emetgate_read_file", .args = "{\"file\":\"@/big.md\"}", .budget = .read_file, .cut = true },
    .{ .tool = "emetgate_read_file", .args = "{\"file\":\"@/big.md\",\"heading\":\"Root\"}", .budget = .read_file, .cut = true },
    .{ .tool = "emetgate_read_file", .args = "{\"files\":[\"@/huge.log\",\"@/min.json\",\"@/flat/file_0001.txt\",\"@/big.md\",{\"file\":\"@/huge.log\",\"line_start\":9,\"line_end\":400000}]}", .budget = .read_file_many, .cut = true },
    .{ .tool = "emetgate_list", .args = "{\"dir\":\"@/.\"}", .budget = .list, .cut = false },
    .{ .tool = "emetgate_list", .args = "{\"dir\":\"@/tree\"}", .budget = .list, .cut = false },
    .{ .tool = "emetgate_list", .args = "{\"dir\":\"@/flat\"}", .budget = .list, .cut = true },
    .{ .tool = "emetgate_read_symbol", .args = "{\"file\":\"@/big.ts\",\"line_start\":1,\"line_end\":6000}", .budget = .read_symbol, .cut = true },
    .{ .tool = "emetgate_read_symbol", .args = "{\"file\":\"@/big.ts\",\"line_start\":1,\"line_end\":6000,\"nodes\":true}", .budget = .read_symbol, .cut = true },
    .{ .tool = "emetgate_read_symbol", .args = "{\"file\":\"@/bigfn.ts\",\"line_start\":1,\"line_end\":20010}", .budget = .read_symbol, .cut = true },
    .{ .tool = "emetgate_read_symbol", .args = "{\"file\":\"@/bigfn.ts\",\"line_start\":3,\"line_end\":20010}", .budget = .read_symbol, .cut = true },
    .{ .tool = "emetgate_read_symbol", .args = "{\"file\":\"@/bigfn.ts\",\"symbol\":\"big\",\"nodes\":true}", .budget = .read_symbol, .cut = true },
    .{ .tool = "emetgate_read_symbol", .args = "{\"file\":\"@/bigfn.ts\",\"symbol\":\"big\",\"detail\":\"full\"}", .budget = .read_symbol, .cut = true },
    .{ .tool = "emetgate_read_symbol", .args = "{\"file\":\"@/bigfn.ts\",\"symbols\":[\"big\",\"small\"],\"detail\":\"full\"}", .budget = .read_symbol, .cut = true },
    .{ .tool = "emetgate_read_symbol", .args = "{\"file\":\"@/big.ts\",\"symbols\":[" ++ symbolList(400) ++ "],\"detail\":\"full\"}", .budget = .read_symbol, .cut = true },
    .{ .tool = "emetgate_skeleton", .args = "{\"file\":\"@/big.ts\"}", .budget = .skeleton, .cut = true },
    .{ .tool = "emetgate_symbols", .args = "{\"file\":\"@/big.ts\"}", .budget = .symbols, .cut = false },
    .{ .tool = "emetgate_symbols", .args = "{\"file\":\"@/big.ts\",\"detail\":\"full\"}", .budget = .symbols, .cut = true },
    .{ .tool = "emetgate_expand", .args = "{\"handle\":\"$H\"}", .budget = .expand, .cut = true },
    .{ .tool = "emetgate_git", .args = "{\"sub\":\"diff\",\"path\":\"@/diffme.txt\",\"detail\":\"full\"}", .budget = .git, .cut = true },
    // Bounded by their own changes, which use reply_contract; flip `enforced`
    // when they land.
    .{ .tool = "emetgate_search", .args = "{\"pattern\":\"id=\"}", .budget = .search, .cut = true, .enforced = false },
    .{ .tool = "emetgate_find", .args = "{\"pattern\":\"id=\"}", .budget = .find, .cut = true, .enforced = false },
    .{ .tool = "emetgate_explore", .args = "{\"question\":\"what does f1 return\"}", .budget = .explore, .cut = false, .enforced = false },
    .{ .tool = "emetgate_evidence", .args = "{\"names\":[\"big\"]}", .budget = .evidence, .cut = true, .enforced = false },
    .{ .tool = "emetgate_scan", .args = "{}", .budget = .scan, .cut = true, .enforced = false },
    .{ .tool = "emetgate_git", .args = "{\"subcommand\":\"show\"}", .budget = .git, .cut = true, .enforced = false },
    .{ .tool = "emetgate_mutate", .args = "{}", .budget = .mutate, .cut = false, .enforced = false },
};

fn symbolList(comptime n: usize) []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var text: []const u8 = "";
        for (0..n) |i| text = text ++ (if (i == 0) "" else ",") ++ std.fmt.comptimePrint("\"f{d}\"", .{i});
        return text;
    }
}

const Fixture = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,

    fn write(self: *Fixture, name: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = data });
    }

    fn build(self: *Fixture, comptime name: []const u8, count: usize, comptime line: []const u8, unused: anytype, head: []const u8, tail: []const u8) !void {
        _ = unused;
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try out.writer.writeAll(head);
        for (0..count) |i| try out.writer.print(line, .{ i, i });
        try out.writer.writeAll(tail);
        try self.write(name, out.written());
    }

    fn init() !Fixture {
        var self: Fixture = .{ .tmp = testing.tmpDir(.{}), .root = undefined };
        errdefer self.tmp.cleanup();
        try self.build("huge.log", 400_000, "line {d:0>6} id={d:0>6} lorem ipsum dolor sit amet\n", .{}, "", "");
        try self.build("min.js", 4_000, "function f{d}(){{return {d}}};", .{}, "", "\n");
        try self.build("big.ts", 2_000, "export function f{d}(a: number): number {{\n  return a + {d};\n}}\n", .{}, "", "");
        try self.build("bigfn.ts", 20_000, "  total += {d} * {d};\n", .{}, "export function big(): number {\n  let total = 0;\n", "  return total;\n}\nexport function small(): number {\n  return 1;\n}\n");
        try self.build("big.json", 6_000, "  \"k{d}\": {{ \"a\": {d}, \"b\": \"value\" }},\n", .{}, "{\n", "  \"end\": 0\n}\n");
        try self.build("min.json", 8_000, "\"k{d}\":{d},", .{}, "{", "\"end\":0}");
        try self.build("diffme.txt", 20_000, "line {d} of {d}\n", .{}, "", "");
        try self.build("big.md", 1_500, "## Section {d}\n\nParagraph {d} of the document, long enough to matter.\n\n", .{}, "# Root\n\n", "");
        var name_buf: [64]u8 = undefined;
        for (0..35) |d| {
            for (0..100) |f| {
                const name = try std.fmt.bufPrint(&name_buf, "tree/d{d:0>2}/f{d:0>3}.txt", .{ d, f });
                try self.tmp.dir.createDirPath(testing.io, std.fs.path.dirname(name).?);
                try self.write(name, "x\n");
            }
        }
        try self.tmp.dir.createDirPath(testing.io, "flat");
        for (0..1500) |f| try self.write(try std.fmt.bufPrint(&name_buf, "flat/file_{d:0>4}.txt", .{f}), "y\n");
        self.root = try self.tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        errdefer testing.allocator.free(self.root);
        try git_fixture.initRepo(self.root);
        try git_fixture.commitInit(self.root, false);
        try self.build("diffme.txt", 20_000, "changed line {d} of {d}\n", .{}, "", "");
        return self;
    }

    fn deinit(self: *Fixture) void {
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    /// The case's arguments with the placeholders filled in.
    fn args(self: *const Fixture, text: []const u8, handle: []const u8) ![]u8 {
        var root_json: std.Io.Writer.Allocating = .init(testing.allocator);
        defer root_json.deinit();
        for (self.root) |c| {
            if (c == '\\') try root_json.writer.writeAll("\\\\") else try root_json.writer.writeByte(c);
        }
        try root_json.writer.writeAll("\\\\");
        const with_root = try std.mem.replaceOwned(u8, testing.allocator, text, "@/", root_json.written());
        defer testing.allocator.free(with_root);
        return std.mem.replaceOwned(u8, testing.allocator, with_root, "$H", handle);
    }
};

const Reply = struct {
    parsed: std.json.Parsed(Value),
    is_error: bool,
    text: []const u8,
};

fn call(runtime: *Runtime, policy: server.Policy, tool: []const u8, args_json: []const u8) !Reply {
    var line: std.Io.Writer.Allocating = .init(testing.allocator);
    defer line.deinit();
    try line.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}", .{ tool, args_json });
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    _ = try server.handleMessageObserved(testing.allocator, testing.io, runtime, line.written(), &out.writer, null, policy);
    const parsed = try std.json.parseFromSlice(Value, testing.allocator, out.written(), .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    const result = parsed.value.object.get("result") orelse return error.NotAToolResult;
    const content = result.object.get("content").?.array.items[0];
    return .{ .parsed = parsed, .is_error = result.object.get("isError").?.bool, .text = content.object.get("text").?.string };
}

/// Checks one reply against the contract: within the budget, and a cut names
/// the rest with the trailer. Returns the trailer's call, if any.
fn expectBounded(case: Case, reply: Reply) !?[]const u8 {
    errdefer std.debug.print("case {s} {s}: {d} chars, error {}, tail: {s}\n", .{ case.tool, case.args[0..@min(case.args.len, 120)], reply.text.len, reply.is_error, reply.text[reply.text.len -| 400..] });
    try testing.expect(!reply.is_error);
    try testing.expect(reply_contract.within(case.budget, reply.text));
    const trailer = reply_contract.findTrailer(reply.text);
    if (case.cut) try testing.expect(trailer != null);
    const line = trailer orelse return null;
    return line[std.mem.indexOf(u8, line, reply_contract.trailer_join).? + reply_contract.trailer_join.len .. line.len - 1];
}

test "reply contract: every served read tool answers within its budget and names what it left out with the call that returns it" {
    for (server.tool_defs) |def| {
        if (!def.read_only) continue;
        var listed = false;
        for (cases) |case| listed = listed or std.mem.eql(u8, case.tool, def.name);
        errdefer std.debug.print("read tool {s} has no case in tests/reply_contract.zig\n", .{def.name});
        try testing.expect(listed);
    }

    var fixture = try Fixture.init();
    defer fixture.deinit();
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch @panic("live snapshots");
    var stash = agent_ledger.Ledger.init(testing.allocator);
    defer stash.deinit();
    const policy: server.Policy = .{ .root = fixture.root, .stash = &stash };

    // A stashed 500 KB reply for expand.
    var compact_policy = server.parsePolicy(&[_][]const u8{"--compact"}).?;
    compact_policy.stash = &stash;
    const big = try testing.allocator.alloc(u8, 500_000);
    defer testing.allocator.free(big);
    for (big, 0..) |*c, i| c.* = if (i % 80 == 79) '\n' else 'a' + @as(u8, @intCast(i % 26));
    const folded = (try server.compactReply(testing.allocator, testing.io, compact_policy, "emetgate_search", null, big, false)).?;
    defer testing.allocator.free(folded);
    const key = "{\"handle\":\"";
    const at = std.mem.indexOf(u8, folded, key).? + key.len;
    const handle = folded[at..std.mem.indexOfScalarPos(u8, folded, at, '"').?];

    for (cases) |case| {
        if (!case.enforced) continue;
        const args = try fixture.args(case.args, handle);
        defer testing.allocator.free(args);
        const reply = try call(runtime, policy, case.tool, args);
        defer reply.parsed.deinit();
        const next = try expectBounded(case, reply) orelse continue;
        // The continuation is one call, and it too keeps the contract.
        const space = std.mem.indexOfScalar(u8, next, ' ').?;
        const next_tool = next[0..space];
        const next_case: Case = .{ .tool = next_tool, .args = next[space + 1 ..], .budget = if (std.mem.indexOf(u8, next, "\"files\"") != null) .read_file_many else budgetOf(next_tool), .cut = false };
        const again = try call(runtime, policy, next_tool, next[space + 1 ..]);
        defer again.parsed.deinit();
        errdefer std.debug.print("continuation of {s}: {s}\n", .{ case.tool, next });
        _ = try expectBounded(next_case, again);
        try testing.expect(!std.mem.eql(u8, again.text, reply.text));
    }
}

fn budgetOf(tool: []const u8) reply_contract.Tool {
    const prefix = "emetgate_";
    return std.meta.stringToEnum(reply_contract.Tool, tool[prefix.len..]) orelse .read_file;
}
