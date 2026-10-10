const std = @import("std");
const builtin = @import("builtin");
const emetgate = @import("emetgate");
const fixture = @import("ts_fixture.zig");
const common = @import("commit_batch.zig");
const first = @import("every_write.zig");

const symbol = emetgate.symbol;
const scan = emetgate.scan;
const server = emetgate.server;
const lockdown = emetgate.lockdown;

const testing = std.testing;
const Allocator = std.mem.Allocator;
const Plain = common.Plain;
const Env = common.Env;
const Reply = common.Reply;
const green = common.green;
const ignore = common.ignore;

const a_src =
    "function helper(x) {\n  return x + 1;\n}\n" ++
    "export function alpha(y) {\n  return helper(y);\n}\n" ++
    "export function old(z) {\n  // legacy note\n  const legacy = z;\n  return legacy;\n}\n";
const b_src = "function spare() {\n  return 7;\n}\nexport function beta() {\n  return 2;\n}\n";
const c_src = "function lonely() {\n  return 5;\n}\nexport function gamma() {\n  const three = 3;\n  return three;\n}\n";
const dead_src = "export const unusedThing = 1;\n";
const far_src = "function villain() {\n  // evil plan\n  return \"evil\";\n}\nexport function far() {\n  // far away\n  return \"evil-far\";\n}\n";
const note_src = "# Notes\n\n## Setup\n\nold\n";

const files = [_]fixture.File{
    .{ .rel = "src/core/a.ts", .text = a_src },
    .{ .rel = "src/core/b.ts", .text = b_src },
    .{ .rel = "src/util/c.ts", .text = c_src },
    .{ .rel = "src/util/dead.ts", .text = dead_src },
    .{ .rel = "src/util/far.ts", .text = far_src },
    .{ .rel = "docs/n.md", .text = note_src },
    ignore,
};

const RuleSpec = struct { check: []const u8, where: ?[]const u8 };

const rule_pool = [_]RuleSpec{
    .{ .check = "forbid:evil", .where = "src/core/" },
    .{ .check = "no_comment", .where = "src/core/" },
    .{ .check = "q:((identifier) @violation (#eq? @violation \"evil\"))", .where = "src/core/a.ts" },
    .{ .check = "forbid:legacy", .where = "src/core/a.ts#alpha" },
    .{ .check = "no_comment", .where = null },
    .{ .check = "forbid:evil", .where = null },
};

const poison = "{\n  // evil\n  const evil = \"legacy\";\n  return evil;\n}";
const clean = "{\n  return 11;\n}";

fn skipOffWindows() !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
}

fn servedTools(arena: Allocator) ![]const []const u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    _ = try server.handleMessage(testing.allocator, testing.io, undefined, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}", &out.writer);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    var names: std.ArrayList([]const u8) = .empty;
    for (parsed.object.get("result").?.object.get("tools").?.array.items) |tool| {
        try names.append(arena, try arena.dupe(u8, tool.object.get("name").?.string));
    }
    return names.items;
}

fn readOnly(name: []const u8) bool {
    for (lockdown.read_only_tools) |tool| {
        if (std.mem.eql(u8, tool, name)) return true;
    }
    return false;
}

const Counts = std.StringHashMap(usize);

fn violationsOf(case: *Plain) !Counts {
    const arena = case.env.arena();
    var counts = Counts.init(arena);
    const enforced = try scan.load(testing.allocator, testing.io, case.repo.root_abs, .ledger, .{});
    defer enforced.deinit();
    const result = try scan.scan(testing.allocator, testing.io, case.runtime, case.repo.root_abs, enforced.rules, null, null);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), result.check_failures.len);
    try testing.expectEqual(@as(usize, 0), result.unreadable.len);
    try testing.expectEqual(@as(usize, 0), result.parse_errors.len);
    for (result.violations) |v| {
        const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ v.rule, v.text });
        const slot = try counts.getOrPut(key);
        if (!slot.found_existing) slot.value_ptr.* = 0;
        slot.value_ptr.* += 1;
    }
    return counts;
}

fn treeOf(env: *Env) ![]const u8 {
    const listing = try env.git(&.{ "ls-files", "-s" });
    const status = try env.git(&.{ "status", "--porcelain" });
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(env.arena(), listing);
    try out.appendSlice(env.arena(), status);
    var lines = std.mem.tokenizeScalar(u8, try env.git(&.{"ls-files"}), '\n');
    while (lines.next()) |raw| {
        const rel = std.mem.trim(u8, raw, "\r");
        if (!env.repo.exists(rel)) continue;
        try out.appendSlice(env.arena(), rel);
        try out.appendSlice(env.arena(), try env.read(rel));
    }
    return out.items;
}

const Op = struct {
    random: std.Random,
    env: *Env,
    commit: bool,

    fn pick(self: Op, comptime T: type, items: []const T) T {
        return items[self.random.uintLessThan(usize, items.len)];
    }

    fn send(self: Op, tool: []const u8, args: std.json.Value) !Reply {
        var object = args.object;
        if (self.commit) try object.put(self.env.arena(), "message", .{ .string = first.message });
        return self.env.call(tool, std.json.Value{ .object = object }, green, self.commit);
    }

    fn value(self: Op, given: anytype) !std.json.Value {
        return common.toValue(self.env.arena(), given);
    }

    fn text(self: Op) []const u8 {
        return if (self.random.boolean()) poison else clean;
    }

    const Site = struct { rel: []const u8, name: []const u8 };
    const sites = [_]Site{
        .{ .rel = "src/core/a.ts", .name = "alpha" },
        .{ .rel = "src/core/a.ts", .name = "helper" },
        .{ .rel = "src/core/a.ts", .name = "old" },
        .{ .rel = "src/core/b.ts", .name = "beta" },
        .{ .rel = "src/util/c.ts", .name = "gamma" },
        .{ .rel = "src/util/far.ts", .name = "far" },
    };

    fn symbolEdit(self: Op) !?std.json.Value {
        const site = self.pick(Site, &sites);
        if (!self.env.repo.exists(site.rel)) return null;
        const hash = self.env.hashOf(site.rel, site.name) catch return null;
        return try self.value(.{ .file = try self.env.abs(site.rel), .symbol = site.name, .hash = hash, .body = self.text() });
    }

    fn insertEdit(self: Op) !?std.json.Value {
        const rel = self.pick([]const u8, &.{ "src/core/a.ts", "src/core/fresh.ts", "src/util/c.ts", "src/util/fresh.ts" });
        const name = try std.fmt.allocPrint(self.env.arena(), "made{d}", .{self.random.uintLessThan(u32, 1000)});
        const body = try std.fmt.allocPrint(self.env.arena(), "export function {s}() {s}", .{ name, self.text() });
        return try self.value(.{ .file = try self.env.abs(rel), .symbol = name, .hash = "absent", .body = body });
    }

    fn deleteEdit(self: Op) !?std.json.Value {
        if (self.random.boolean()) {
            const rel = self.pick([]const u8, &.{ "src/util/dead.ts", "src/core/b.ts", "src/util/far.ts" });
            if (!self.env.repo.exists(rel)) return null;
            return try self.value(.{ .file = try self.env.abs(rel), .op = "delete", .hash = try self.env.fileHash(rel) });
        }
        const site = self.pick(Site, &.{ .{ .rel = "src/core/b.ts", .name = "spare" }, .{ .rel = "src/util/c.ts", .name = "lonely" } });
        if (!self.env.repo.exists(site.rel)) return null;
        const hash = self.env.hashOf(site.rel, site.name) catch return null;
        return try self.value(.{ .file = try self.env.abs(site.rel), .op = "delete", .symbol = site.name, .hash = hash });
    }

    fn docArgs(self: Op, batch: bool) !?std.json.Value {
        const source = try self.env.read("docs/n.md");
        const at = std.mem.indexOf(u8, source, "## Setup") orelse return null;
        const hash = try self.env.arena().dupe(u8, &symbol.formatHash(symbol.hashOf(source[at..])));
        const content = if (self.random.boolean()) "## Setup\n\nevil legacy // text\n" else "## Setup\n\nnewer\n";
        if (batch) return try self.value(.{ .file = try self.env.abs("docs/n.md"), .kind = "doc", .heading = "Setup", .hash = hash, .content = content });
        return try self.value(.{ .file = try self.env.abs("docs/n.md"), .heading = "Setup", .hash = hash, .content = content });
    }

    fn nodeEdit(self: Op) !?std.json.Value {
        if (!self.env.repo.exists("src/util/c.ts")) return null;
        const address = first.nodeAddress(self.env, "src/util/c.ts", "gamma", "const three = 3;") catch return null;
        const statement = if (self.random.boolean()) "const three = \"evil\"; // evil" else "const three = 4;";
        return try self.value(.{ .file = try self.env.abs("src/util/c.ts"), .node = address, .text = statement });
    }

    fn run(self: Op, tool: []const u8) !?Reply {
        const env = self.env;
        if (std.mem.eql(u8, tool, "emetgate_try")) {
            const args = switch (self.random.uintLessThan(u8, 3)) {
                0 => try self.symbolEdit(),
                1 => try self.insertEdit(),
                else => try self.nodeEdit(),
            } orelse return null;
            return try self.send(tool, args);
        }
        if (std.mem.eql(u8, tool, "emetgate_try_batch")) {
            var edits = std.json.Array.init(env.arena());
            var taken: [4]bool = @splat(false);
            var wanted = 1 + self.random.uintLessThan(u8, 2);
            while (wanted != 0) : (wanted -= 1) {
                const kind = self.random.uintLessThan(u8, 4);
                if (taken[kind]) continue;
                taken[kind] = true;
                const edit = switch (kind) {
                    0 => try self.symbolEdit(),
                    1 => try self.insertEdit(),
                    2 => try self.deleteEdit(),
                    else => try self.docArgs(true),
                } orelse continue;
                try edits.append(edit);
            }
            if (edits.items.len == 0) return null;
            var object: std.json.ObjectMap = .empty;
            try object.put(env.arena(), "edits", .{ .array = edits });
            return try self.send(tool, .{ .object = object });
        }
        if (std.mem.eql(u8, tool, "emetgate_write_doc")) {
            return try self.send(tool, (try self.docArgs(false)) orelse return null);
        }
        if (std.mem.eql(u8, tool, "emetgate_rename")) {
            const site = self.pick(Site, &.{ .{ .rel = "src/core/a.ts", .name = "helper" }, .{ .rel = "src/core/b.ts", .name = "spare" }, .{ .rel = "src/util/c.ts", .name = "lonely" } });
            if (!env.repo.exists(site.rel)) return null;
            const hash = env.hashOf(site.rel, site.name) catch return null;
            const new_name = self.pick([]const u8, &.{ "evil", "legacyName", "worker", "evilWorker" });
            return try self.send(tool, try self.value(.{ .file = try env.abs(site.rel), .symbol = site.name, .hash = hash, .new_name = new_name }));
        }
        if (std.mem.eql(u8, tool, "emetgate_move")) {
            const Route = struct { from: Site, to: []const u8 };
            const route = self.pick(Route, &.{
                .{ .from = .{ .rel = "src/util/c.ts", .name = "lonely" }, .to = "src/core/b.ts" },
                .{ .from = .{ .rel = "src/core/b.ts", .name = "spare" }, .to = "src/util/c.ts" },
                .{ .from = .{ .rel = "src/util/c.ts", .name = "lonely" }, .to = "src/util/fresh.ts" },
                .{ .from = .{ .rel = "src/util/far.ts", .name = "villain" }, .to = "src/core/b.ts" },
                .{ .from = .{ .rel = "src/util/far.ts", .name = "villain" }, .to = "src/core/a.ts" },
            });
            if (!env.repo.exists(route.from.rel)) return null;
            const hash = env.hashOf(route.from.rel, route.from.name) catch return null;
            return try self.send(tool, try self.value(.{ .file = try env.abs(route.from.rel), .symbol = route.from.name, .hash = hash, .target_file = try env.abs(route.to), .interface_change = true }));
        }
        if (std.mem.eql(u8, tool, "emetgate_move_file")) {
            const Route = struct { from: []const u8, to: []const u8 };
            const route = self.pick(Route, &.{
                .{ .from = "src/util/far.ts", .to = "src/core/far.ts" },
                .{ .from = "src/util/c.ts", .to = "src/core/c.ts" },
                .{ .from = "src/core/b.ts", .to = "src/util/b.ts" },
                .{ .from = "src/core/a.ts", .to = "src/core/sub/a.ts" },
                .{ .from = "src/util/dead.ts", .to = "src/util/gone/dead.ts" },
            });
            if (!env.repo.exists(route.from) or env.repo.exists(route.to)) return null;
            return try self.send(tool, try self.value(.{ .from = try env.abs(route.from), .to = try env.abs(route.to), .from_hash = try env.fileHash(route.from), .interface_change = true }));
        }
        if (std.mem.eql(u8, tool, "emetgate_run")) {
            return try env.call(tool, .{}, green, false);
        }
        return error.WriteToolWithoutGenerator;
    }
};

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

const Tally = struct { accepted: usize = 0, refused_by_rule: usize = 0, other: usize = 0 };

fn exercise(tool: []const u8, seed: u64, tally: *Tally) !void {
    errdefer std.debug.print("write invariant: tool {s} seed {d}\n", .{ tool, seed });
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var case: Plain = undefined;
    try case.init(&files);
    defer case.deinit();
    const env = &case.env;

    var chosen: usize = 0;
    for (rule_pool) |rule| {
        if (random.uintLessThan(u8, 3) == 0) continue;
        try first.enforce(case.repo.root_abs, rule.check, rule.where);
        chosen += 1;
    }
    if (chosen == 0) try first.enforce(case.repo.root_abs, rule_pool[0].check, rule_pool[0].where);

    const op: Op = .{ .random = random, .env = env, .commit = random.boolean() };
    {
        const before = try treeOf(env);
        const live = try op.send("emetgate_try", try op.value(.{ .file = try env.abs("src/core/a.ts"), .symbol = "alpha", .hash = try env.hashOf("src/core/a.ts", "alpha"), .body = poison }));
        errdefer std.debug.print("{s}\n", .{live.text});
        try testing.expect(live.is_error and contains(live.text, "rule_violation"));
        try testing.expectEqualStrings(before, try treeOf(env));
    }

    var step: usize = 0;
    while (step < 4) : (step += 1) {
        const found = try violationsOf(&case);
        const before = try treeOf(env);
        const reply = (try op.run(tool)) orelse continue;
        errdefer std.debug.print("step {d}: {s}\n", .{ step, reply.text });
        if (reply.is_error) {
            try testing.expectEqualStrings(before, try treeOf(env));
            if (contains(reply.text, "rule_violation")) tally.refused_by_rule += 1 else tally.other += 1;
            continue;
        }
        tally.accepted += 1;
        if (std.mem.eql(u8, tool, "emetgate_run")) try testing.expectEqualStrings(before, try treeOf(env));
        var after = try violationsOf(&case);
        var it = after.iterator();
        while (it.next()) |entry| {
            const was = found.get(entry.key_ptr.*) orelse 0;
            errdefer std.debug.print("rule and text: {s}\n", .{entry.key_ptr.*});
            try testing.expect(entry.value_ptr.* <= was);
        }
    }
}

const seeds_per_tool = 6;

test "write invariant: after any accepted write through a served write tool a scan finds no violation it did not find before" {
    try skipOffWindows();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var write_tools: usize = 0;
    for (try servedTools(arena)) |tool| {
        if (readOnly(tool)) continue;
        write_tools += 1;
        var tally: Tally = .{};
        var seed: u64 = 1;
        while (seed <= seeds_per_tool) : (seed += 1) try exercise(tool, seed * 7919 + tool.len, &tally);
        errdefer std.debug.print("write invariant: tool {s} accepted {d} refused {d} other {d}\n", .{ tool, tally.accepted, tally.refused_by_rule, tally.other });
        try testing.expect(tally.accepted != 0);
        const writes_source = !std.mem.eql(u8, tool, "emetgate_run") and !std.mem.eql(u8, tool, "emetgate_write_doc");
        if (writes_source) try testing.expect(tally.refused_by_rule != 0);
    }
    try testing.expect(write_tools >= 7);
}

test "write invariant: the served list holds a write tool that the tool table does not, and no read-only tool is exercised as a writer" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const served = try servedTools(arena_state.allocator());
    var batch_served = false;
    for (served) |tool| {
        if (std.mem.eql(u8, tool, "emetgate_try_batch")) batch_served = true;
    }
    try testing.expect(batch_served);
    for (server.tool_defs) |tool| try testing.expect(!std.mem.eql(u8, tool.name, "emetgate_try_batch"));
    try testing.expect(readOnly("emetgate_scan"));
    try testing.expect(!readOnly("emetgate_try_batch"));
}
