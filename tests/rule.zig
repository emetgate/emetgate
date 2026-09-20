const std = @import("std");
const builtin = @import("builtin");
const memory = @import("../src/platform/memory.zig");
const rule_command = @import("../src/protocol/rule_command.zig");
const scan_command = @import("../src/protocol/scan_command.zig");
const wire = @import("../src/protocol/wire.zig");
const Runtime = @import("../src/engine/runtime.zig").Runtime;

const testing = std.testing;
const Allocating = std.Io.Writer.Allocating;

const File = struct { path: []const u8, data: []const u8 };

const Repo = struct {
    tmp: testing.TmpDir,
    root_abs: [:0]u8,

    fn init(files: []const File) !Repo {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo");
        for (files) |file| {
            if (std.fs.path.dirname(file.path)) |dir| {
                const sub = try std.fmt.allocPrint(testing.allocator, "repo/{s}", .{dir});
                defer testing.allocator.free(sub);
                try tmp.dir.createDirPath(testing.io, sub);
            }
            const sub = try std.fmt.allocPrint(testing.allocator, "repo/{s}", .{file.path});
            defer testing.allocator.free(sub);
            try tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = file.data });
        }
        const root_abs = try tmp.dir.realPathFileAlloc(testing.io, "repo", testing.allocator);
        errdefer testing.allocator.free(root_abs);
        try git(root_abs, &.{ "init", "-q" });
        try git(root_abs, &.{ "config", "user.email", "t@t" });
        try git(root_abs, &.{ "config", "user.name", "t" });
        try git(root_abs, &.{ "add", "." });
        try git(root_abs, &.{ "commit", "-q", "--allow-empty", "-m", "init" });
        return .{ .tmp = tmp, .root_abs = root_abs };
    }

    fn deinit(self: *Repo) void {
        testing.allocator.free(self.root_abs);
        self.tmp.cleanup();
    }

    fn ledger(self: *Repo) ![]u8 {
        return self.tmp.dir.readFileAlloc(testing.io, "repo/.emetgate/ledger.ndjson", testing.allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => try testing.allocator.dupe(u8, ""),
            else => return err,
        };
    }
};

fn git(cwd: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(testing.allocator);
    try argv.append(testing.allocator, "git");
    try argv.appendSlice(testing.allocator, args);
    const result = try std.process.run(testing.allocator, testing.io, .{ .argv = argv.items, .cwd = .{ .path = cwd } });
    testing.allocator.free(result.stdout);
    testing.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

fn runRule(repo: *Repo, args: []const [:0]const u8) ![]u8 {
    const request = rule_command.parse(args) orelse return error.UsageRefused;
    var out: Allocating = .init(testing.allocator);
    defer out.deinit();
    try rule_command.run(testing.allocator, testing.io, repo.root_abs, request, &out.writer);
    return testing.allocator.dupe(u8, out.written());
}

fn addRule(repo: *Repo, args: []const [:0]const u8) ![:0]u8 {
    const printed = try runRule(repo, args);
    errdefer testing.allocator.free(printed);
    if (printed.len < 2 or printed[printed.len - 1] != '\n') return error.NoIdPrinted;
    const id = try testing.allocator.dupeZ(u8, printed[0 .. printed.len - 1]);
    testing.allocator.free(printed);
    return id;
}

const ScanOutcome = struct {
    code: u8,
    out: []u8,
    err: []u8,

    fn deinit(self: ScanOutcome) void {
        testing.allocator.free(self.out);
        testing.allocator.free(self.err);
    }

    fn has(self: ScanOutcome, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.out, needle) != null;
    }
};

fn runScan(repo: *Repo) !ScanOutcome {
    const runtime = try Runtime.create(testing.allocator);
    defer runtime.destroy() catch |err| std.debug.panic("runtime closed with live allocations: {t}", .{err});
    var out: Allocating = .init(testing.allocator);
    defer out.deinit();
    var err: Allocating = .init(testing.allocator);
    defer err.deinit();
    const options = scan_command.Options.parse(&.{}) orelse return error.UsageRefused;
    const code = try scan_command.run(testing.allocator, testing.io, runtime, repo.root_abs, options, &out.writer, &err.writer);
    const out_bytes = try testing.allocator.dupe(u8, out.written());
    errdefer testing.allocator.free(out_bytes);
    return .{ .code = code, .out = out_bytes, .err = try testing.allocator.dupe(u8, err.written()) };
}

fn expectLedgerUntouched(repo: *Repo) !void {
    const bytes = try repo.ledger();
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("", bytes);
}

fn skipOffWindows() !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
}

fn lines(out: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, out[0 .. out.len - @intFromBool(out.len != 0)], '\n');
}

fn fieldOf(line: []const u8, index: usize) []const u8 {
    var it = std.mem.splitScalar(u8, line, '\t');
    var i: usize = 0;
    while (it.next()) |field| : (i += 1) {
        if (i == index) return field;
    }
    return "";
}

fn statusOf(out: []const u8, id: []const u8) ![]const u8 {
    var it = lines(out);
    while (it.next()) |line| {
        if (std.mem.eql(u8, fieldOf(line, 0), id)) return fieldOf(line, 1);
    }
    return error.NoSuchRow;
}

const with_networkidle ="export function open() {\n  return wait(\"networkidle\");\n}\n";

test "rule: a rule added from the command line is listed and enforced by the very next scan" {
    try skipOffWindows();
    var repo = try Repo.init(&.{.{ .path = "src/nav.ts", .data = with_networkidle }});
    defer repo.deinit();

    const id = try addRule(&repo, &.{ "add", "no networkidle", "--check", "forbid:networkidle", "--enforce" });
    defer testing.allocator.free(id);

    const listed = try runRule(&repo, &.{"list"});
    defer testing.allocator.free(listed);
    var it = lines(listed);
    const row = it.next().?;
    try testing.expectEqualStrings(id, fieldOf(row, 0));
    try testing.expectEqualStrings("active", fieldOf(row, 1));
    try testing.expectEqualStrings("enforce", fieldOf(row, 2));
    try testing.expectEqualStrings("forbid:networkidle", fieldOf(row, 3));
    try testing.expectEqualStrings("-", fieldOf(row, 4));
    try testing.expectEqualStrings("no networkidle", fieldOf(row, 5));
    try testing.expect(it.next() == null);

    const outcome = try runScan(&repo);
    defer outcome.deinit();
    try testing.expectEqual(scan_command.violations_exit_code, outcome.code);
    try testing.expect(outcome.has("src/nav.ts:2:16: "));
    try testing.expect(outcome.has(" (forbid:networkidle): networkidle\n"));
    try testing.expect(outcome.has(id));
    try testing.expect(outcome.has("1 violation(s) in 1 file(s), 1 rule(s)\n"));
}

test "rule: add prints the new id and nothing else" {
    try skipOffWindows();
    var repo = try Repo.init(&.{});
    defer repo.deinit();

    const printed = try runRule(&repo, &.{ "add", "use Money for amounts" });
    defer testing.allocator.free(printed);
    try testing.expectEqual(@as(usize, 18), printed.len);
    try testing.expectEqual(@as(u8, 'm'), printed[0]);
    try testing.expectEqual(@as(u8, '\n'), printed[printed.len - 1]);
}

test "rule: --enforce without --check is refused and writes nothing" {
    try skipOffWindows();
    var repo = try Repo.init(&.{});
    defer repo.deinit();

    try testing.expectError(error.EnforceWithoutCheck, runRule(&repo, &.{ "add", "no networkidle", "--enforce" }));
    try expectLedgerUntouched(&repo);
}

test "rule: an invalid --check is refused by name and writes nothing" {
    try skipOffWindows();
    var repo = try Repo.init(&.{});
    defer repo.deinit();

    try testing.expectError(error.UnknownCheck, runRule(&repo, &.{ "add", "typo", "--check", "frbid:x", "--enforce" }));
    try expectLedgerUntouched(&repo);
}

test "rule: an invalid --in is refused by name and writes nothing" {
    try skipOffWindows();
    var repo = try Repo.init(&.{});
    defer repo.deinit();

    try testing.expectError(error.WhereParentSegment, runRule(&repo, &.{ "add", "no fetch", "--check", "forbid:fetch(", "--in", "../outside.ts" }));
    try expectLedgerUntouched(&repo);
}

test "rule: empty text is refused and writes nothing" {
    try skipOffWindows();
    var repo = try Repo.init(&.{});
    defer repo.deinit();

    try testing.expectError(error.InvalidDecision, runRule(&repo, &.{ "add", "" }));
    try expectLedgerUntouched(&repo);
}

test "rule: list shows only the successor, list --all shows both" {
    try skipOffWindows();
    var repo = try Repo.init(&.{});
    defer repo.deinit();

    const first = try addRule(&repo, &.{ "add", "use Money for amounts" });
    defer testing.allocator.free(first);
    const second = try addRule(&repo, &.{ "supersede", first, "use integer cents" });
    defer testing.allocator.free(second);

    const active = try runRule(&repo, &.{"list"});
    defer testing.allocator.free(active);
    try testing.expect(std.mem.indexOf(u8, active, second) != null);
    try testing.expect(std.mem.indexOf(u8, active, first) == null);

    const all = try runRule(&repo, &.{ "list", "--all" });
    defer testing.allocator.free(all);
    try testing.expect(std.mem.indexOf(u8, all, first) != null);
    try testing.expect(std.mem.indexOf(u8, all, second) != null);
}

test "rule: the status column tells the superseded row from the active one" {
    try skipOffWindows();
    var repo = try Repo.init(&.{});
    defer repo.deinit();

    const first = try addRule(&repo, &.{ "add", "use Money for amounts" });
    defer testing.allocator.free(first);
    const second = try addRule(&repo, &.{ "supersede", first, "use integer cents" });
    defer testing.allocator.free(second);

    const all = try runRule(&repo, &.{ "list", "--all" });
    defer testing.allocator.free(all);
    try testing.expectEqualStrings("superseded", try statusOf(all, first));
    try testing.expectEqualStrings("active", try statusOf(all, second));

    const active = try runRule(&repo, &.{"list"});
    defer testing.allocator.free(active);
    try testing.expectEqualStrings("active", try statusOf(active, second));
    try testing.expectError(error.NoSuchRow, statusOf(active, first));
}

test "rule: after forget the rule is in neither the list nor the gate" {
    try skipOffWindows();
    var repo = try Repo.init(&.{.{ .path = "src/nav.ts", .data = with_networkidle }});
    defer repo.deinit();

    const id = try addRule(&repo, &.{ "add", "no networkidle", "--check", "forbid:networkidle", "--enforce" });
    defer testing.allocator.free(id);
    const before = try runScan(&repo);
    defer before.deinit();
    try testing.expectEqual(scan_command.violations_exit_code, before.code);

    const printed = try runRule(&repo, &.{ "forget", id });
    defer testing.allocator.free(printed);
    try testing.expectEqualStrings("", printed);

    const listed = try runRule(&repo, &.{"list"});
    defer testing.allocator.free(listed);
    try testing.expectEqualStrings("", listed);

    const after = try runScan(&repo);
    defer after.deinit();
    try testing.expectEqual(@as(u8, 0), after.code);
    try testing.expect(after.has("0 violation(s) in 0 file(s), 0 rule(s)\n"));
}

test "rule: list on an empty ledger prints nothing" {
    try skipOffWindows();
    var repo = try Repo.init(&.{});
    defer repo.deinit();

    const listed = try runRule(&repo, &.{"list"});
    defer testing.allocator.free(listed);
    try testing.expectEqualStrings("", listed);

    const all = try runRule(&repo, &.{ "list", "--all" });
    defer testing.allocator.free(all);
    try testing.expectEqualStrings("", all);
}

test "rule: list --json parses back into a Decision with the stored fields" {
    try skipOffWindows();
    var repo = try Repo.init(&.{});
    defer repo.deinit();

    const id = try addRule(&repo, &.{ "add", "no fetch here", "--check", "forbid:fetch(", "--in", "src/", "--enforce" });
    defer testing.allocator.free(id);

    const listed = try runRule(&repo, &.{ "list", "--json" });
    defer testing.allocator.free(listed);
    var it = lines(listed);
    const line = it.next().?;
    try testing.expect(it.next() == null);

    const parsed = try std.json.parseFromSlice(memory.Decision, testing.allocator, line, .{});
    defer parsed.deinit();
    const decision = parsed.value;
    try testing.expectEqualStrings(id, decision.id);
    try testing.expectEqual(memory.Scope.project, decision.scope);
    try testing.expectEqualStrings("no fetch here", decision.text);
    try testing.expect(decision.enforce);
    try testing.expectEqualStrings("forbid:fetch(", decision.check.?);
    try testing.expectEqualStrings("src/", decision.where.?);
    try testing.expectEqual(memory.Status.active, decision.status);
    try testing.expect(decision.supersedes == null);
}

test "rule: supersede and forget on an unknown id keep the memory error" {
    try skipOffWindows();
    var repo = try Repo.init(&.{});
    defer repo.deinit();

    try testing.expectError(error.DecisionNotActive, runRule(&repo, &.{ "forget", "mdeadbeefdeadbeef" }));
    try testing.expectError(error.DecisionNotActive, runRule(&repo, &.{ "supersede", "mdeadbeefdeadbeef", "replacement" }));
}

test "rule: the usage grammar refuses what it does not define" {
    try testing.expect(rule_command.parse(&.{}) == null);
    try testing.expect(rule_command.parse(&.{"adopt"}) == null);
    try testing.expect(rule_command.parse(&.{"add"}) == null);
    try testing.expect(rule_command.parse(&.{ "add", "t", "--check" }) == null);
    try testing.expect(rule_command.parse(&.{ "add", "t", "--enforce", "--enforce" }) == null);
    try testing.expect(rule_command.parse(&.{ "list", "--in", "src/" }) == null);
    try testing.expect(rule_command.parse(&.{ "supersede", "mx" }) == null);
    try testing.expect(rule_command.parse(&.{"forget"}) == null);
    try testing.expect(rule_command.parse(&.{ "forget", "mx", "my" }) == null);
    try testing.expect(rule_command.parse(&.{ "list", "--all", "--json" }) != null);
}

test "rule: every refusal the command owns has its own exit code" {
    const codes = [_]u8{
        wire.exitCode(error.EnforceWithoutCheck),
        wire.exitCode(error.InvalidDecision),
        wire.exitCode(error.DecisionNotActive),
        wire.exitCode(error.MemoryBusy),
    };
    try testing.expectEqualSlices(u8, &.{ 33, 34, 35, 36 }, &codes);
    for (codes) |code| try testing.expect(code != wire.exitCode(error.Unexpected));
}
